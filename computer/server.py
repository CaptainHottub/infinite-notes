from __future__ import annotations

import argparse
import asyncio
import copy
import io
import json
import math
import os
import re
import shutil
import socket
import tempfile
import time
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import fitz  # PyMuPDF
import uvicorn
from fastapi import FastAPI, File, HTTPException, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from starlette.background import BackgroundTask
from starlette.middleware.gzip import GZipMiddleware

ROOT = Path(__file__).resolve().parent
STATIC_DIR = ROOT / "static"
DATA_DIR = ROOT / "data"
PDF_PAGES_DIR = DATA_DIR / "pdf_pages"
STATE_FILE = DATA_DIR / "state.json"
CURRENT_PDF = DATA_DIR / "current.pdf"

MAX_PDF_BYTES = 100 * 1024 * 1024
MAX_PDF_PAGES = 150
MAX_PROJECT_BYTES = 256 * 1024 * 1024
MAX_PROJECT_UNCOMPRESSED_BYTES = 320 * 1024 * 1024
MAX_PROJECT_STATE_BYTES = 128 * 1024 * 1024
MAX_PROJECT_STROKES = 50_000
MAX_PROJECT_POINTS = 2_000_000
MAX_NATIVE_WS_MESSAGE_BYTES = 2 * 1024 * 1024
PROJECT_FORMAT = "infinite-notes-project"
PROJECT_FORMAT_VERSION = 1
APP_VERSION = 24
RENDER_SCALE = 2.0
PAGE_GAP = 0.0

app = FastAPI(title="Infinite Notes Prototype")
app.add_middleware(GZipMiddleware, minimum_size=1024)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
app.mount("/pdf-pages", StaticFiles(directory=PDF_PAGES_DIR), name="pdf-pages")


def empty_state() -> dict[str, Any]:
    return {
        "version": 1,
        "document": {
            "filename": None,
            "pages": [],
        },
        "strokes": {},
    }


def pages_without_gaps(raw_pages: Any) -> list[dict[str, Any]]:
    if not isinstance(raw_pages, list):
        return []
    pages: list[dict[str, Any]] = []
    y = 0.0
    for raw_page in raw_pages:
        if not isinstance(raw_page, dict):
            continue
        page = copy.deepcopy(raw_page)
        try:
            height = float(page.get("height", 0.0))
        except (TypeError, ValueError):
            height = 0.0
        if not (0.0 < height < 1e7):
            continue
        page["y"] = y
        pages.append(page)
        y += height
    return pages


def reflow_strokes_between_page_layouts(
    strokes: Any,
    old_pages: list[dict[str, Any]],
    new_pages: list[dict[str, Any]],
) -> int:
    if not isinstance(strokes, dict) or not old_pages or len(old_pages) != len(new_pages):
        return 0

    layouts: list[tuple[float, float, float]] = []
    for old_page, new_page in zip(old_pages, new_pages):
        try:
            old_y = float(old_page.get("y", 0.0))
            height = float(old_page.get("height", 0.0))
            new_y = float(new_page.get("y", 0.0))
        except (TypeError, ValueError):
            return 0
        if not (0.0 < height < 1e7):
            return 0
        layouts.append((old_y, old_y + height, new_y - old_y))

    shifted = 0
    for stroke in strokes.values():
        if not isinstance(stroke, dict):
            continue
        points = stroke.get("points")
        if not isinstance(points, list) or not points:
            continue
        y_values: list[float] = []
        for point in points:
            if not isinstance(point, dict):
                continue
            try:
                y_values.append(float(point.get("y", 0.0)))
            except (TypeError, ValueError):
                continue
        if not y_values:
            continue

        center_y = (min(y_values) + max(y_values)) / 2.0
        page_index = min(
            range(len(layouts)),
            key=lambda index: (
                0.0
                if layouts[index][0] <= center_y <= layouts[index][1]
                else min(abs(center_y - layouts[index][0]), abs(center_y - layouts[index][1]))
            ),
        )
        delta = layouts[page_index][2]
        if abs(delta) < 1e-9:
            continue
        for point in points:
            if isinstance(point, dict):
                try:
                    point["y"] = float(point.get("y", 0.0)) + delta
                    if "y_raw" in point:
                        point["y_raw"] = float(point.get("y_raw", point["y"])) + delta
                except (TypeError, ValueError):
                    pass
        shifted += 1
    return shifted


def normalize_state_page_layout(value: dict[str, Any]) -> bool:
    document = value.setdefault("document", {"filename": None, "pages": []})
    if not isinstance(document, dict):
        value["document"] = {"filename": None, "pages": []}
        return True
    old_pages = document.get("pages", [])
    new_pages = pages_without_gaps(old_pages)
    if len(new_pages) != len(old_pages):
        document["pages"] = new_pages
        return True
    changed = any(abs(float(old.get("y", 0.0)) - float(new.get("y", 0.0))) > 1e-6
                  for old, new in zip(old_pages, new_pages))
    if changed:
        reflow_strokes_between_page_layouts(value.get("strokes", {}), old_pages, new_pages)
        document["pages"] = new_pages
    return changed


def write_state_atomic(value: dict[str, Any]) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix="state-", suffix=".json", dir=DATA_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(value, f, ensure_ascii=False, separators=(",", ":"))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_name, STATE_FILE)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def load_state() -> dict[str, Any]:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    PDF_PAGES_DIR.mkdir(parents=True, exist_ok=True)
    if not STATE_FILE.exists():
        return empty_state()
    try:
        with STATE_FILE.open("r", encoding="utf-8") as f:
            value = json.load(f)
        if not isinstance(value, dict):
            raise ValueError("state root is not an object")
        value.setdefault("version", 1)
        value.setdefault("document", {"filename": None, "pages": []})
        value.setdefault("strokes", {})
        if normalize_state_page_layout(value):
            write_state_atomic(value)
        return value
    except Exception as exc:
        backup = STATE_FILE.with_suffix(f".broken-{uuid.uuid4().hex[:8]}.json")
        STATE_FILE.replace(backup)
        print(f"Warning: state file was invalid and moved to {backup}: {exc}")
        return empty_state()


state: dict[str, Any] = load_state()
state_lock = asyncio.Lock()
clients: set[WebSocket] = set()
client_roles: dict[WebSocket, str] = {}
client_kinds: dict[WebSocket, str] = {}
history: list[dict[str, Any]] = []
redo_history: list[dict[str, Any]] = []
pending_stroke_history: set[str] = set()
MAX_HISTORY_ACTIONS = 250
MAX_SELECTION_STROKES = 50_000
pending_delete_operations: dict[str, dict[str, Any]] = {}
DELETE_OPERATION_STALE_SECONDS = 60.0


def save_state_atomic() -> None:
    write_state_atomic(state)


async def broadcast(
    message: dict[str, Any],
    *,
    exclude: WebSocket | None = None,
    exclude_kinds: set[str] | None = None,
) -> None:
    if not clients:
        return
    encoded = json.dumps(message, separators=(",", ":"))
    encoded_size = len(encoded.encode("utf-8"))
    native_refresh = json.dumps(
        state_refresh_message(reason=f"oversized_{message.get('type', 'update')}"),
        separators=(",", ":"),
    )
    dead: list[WebSocket] = []
    for ws in list(clients):
        if ws is exclude:
            continue
        if exclude_kinds and client_kinds.get(ws) in exclude_kinds:
            continue
        try:
            if client_kinds.get(ws) == "native" and encoded_size > MAX_NATIVE_WS_MESSAGE_BYTES:
                await ws.send_text(native_refresh)
            else:
                await ws.send_text(encoded)
        except Exception:
            dead.append(ws)
    for ws in dead:
        clients.discard(ws)
        client_roles.pop(ws, None)
        client_kinds.pop(ws, None)


async def send_to_role(role: str, message: dict[str, Any]) -> int:
    encoded = json.dumps(message, separators=(",", ":"))
    delivered = 0
    dead: list[WebSocket] = []
    for ws, client_role in list(client_roles.items()):
        if client_role != role:
            continue
        try:
            await ws.send_text(encoded)
            delivered += 1
        except Exception:
            dead.append(ws)
    for ws in dead:
        clients.discard(ws)
        client_roles.pop(ws, None)
        client_kinds.pop(ws, None)
    return delivered


async def send_to_kind(kind: str, message: dict[str, Any]) -> int:
    encoded = json.dumps(message, separators=(",", ":"))
    delivered = 0
    dead: list[WebSocket] = []
    for ws, client_kind in list(client_kinds.items()):
        if client_kind != kind:
            continue
        try:
            await ws.send_text(encoded)
            delivered += 1
        except Exception:
            dead.append(ws)
    for ws in dead:
        clients.discard(ws)
        client_roles.pop(ws, None)
        client_kinds.pop(ws, None)
    return delivered




def history_status_message() -> dict[str, Any]:
    return {
        "type": "history_state",
        "canUndo": bool(history),
        "canRedo": bool(redo_history),
    }


def snapshot_message(*, reason: str = "sync") -> dict[str, Any]:
    return {
        "type": "snapshot",
        "state": copy.deepcopy(state),
        "liveStrokeIds": sorted(pending_stroke_history),
        "reason": reason,
        "serverTime": datetime.now(timezone.utc).isoformat(),
    }


def state_refresh_message(*, reason: str = "sync") -> dict[str, Any]:
    """Small WebSocket notification telling native clients to fetch /api/state."""
    return {
        "type": "state_refresh",
        "reason": reason,
        "serverTime": datetime.now(timezone.utc).isoformat(),
    }


def push_history(action: dict[str, Any]) -> None:
    history.append(action)
    if len(history) > MAX_HISTORY_ACTIONS:
        del history[: len(history) - MAX_HISTORY_ACTIONS]
    redo_history.clear()


def apply_history_action(action: dict[str, Any], *, undo: bool) -> dict[str, Any]:
    action_type = action.get("type")
    strokes = copy.deepcopy(action.get("strokes", []))
    ids = [str(stroke.get("id", "")) for stroke in strokes if stroke.get("id")]

    if action_type == "add":
        if undo:
            for stroke_id in ids:
                state["strokes"].pop(stroke_id, None)
            return {"type": "delete_strokes", "ids": ids}
        for stroke in strokes:
            state["strokes"][stroke["id"]] = stroke
        return {"type": "restore_strokes", "strokes": strokes}

    if action_type == "delete":
        if undo:
            for stroke in strokes:
                state["strokes"][stroke["id"]] = stroke
            return {"type": "restore_strokes", "strokes": strokes}
        for stroke_id in ids:
            state["strokes"].pop(stroke_id, None)
        return {"type": "delete_strokes", "ids": ids}

    if action_type == "replace":
        replacements = copy.deepcopy(action.get("before" if undo else "after", []))
        for stroke in replacements:
            state["strokes"][stroke["id"]] = stroke
        return {"type": "replace_strokes", "strokes": replacements}

    raise ValueError("unsupported history action")


def validate_point(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("point must be an object")
    point: dict[str, Any] = {
        "x": float(value["x"]),
        "y": float(value["y"]),
        "p": max(0.0, min(1.0, float(value.get("p", 0.5)))),
        "t": float(value.get("t", 0.0)),
    }
    for key in ("x", "y", "p", "t"):
        if not (-1e9 < point[key] < 1e12):
            raise ValueError(f"invalid point field: {key}")

    # Native stroke-pipeline diagnostics. Keep these optional so old v24
    # browser points remain valid and compact.
    optional_coordinates = (
        "x_raw", "y_raw", "x_local", "y_local",
        "x_raw_local", "y_raw_local", "altitude", "azimuth",
    )
    for key in optional_coordinates:
        if key not in value or value[key] is None:
            continue
        parsed = float(value[key])
        if not (-1e9 < parsed < 1e12):
            raise ValueError(f"invalid point field: {key}")
        point[key] = parsed
    return point


def sanitize_pipeline(raw: Any) -> dict[str, Any] | None:
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise ValueError("pipeline must be an object")

    spline = str(raw.get("splineAlgorithm", "catmull-rom-centripetal"))
    allowed_splines = {
        "polyline", "quadratic-midpoint", "catmull-rom-uniform",
        "catmull-rom-centripetal", "cubic-bezier",
    }
    if spline not in allowed_splines:
        spline = "catmull-rom-centripetal"

    def bounded(name: str, default: float, low: float, high: float) -> float:
        return max(low, min(high, float(raw.get(name, default))))

    return {
        "resamplingEnabled": bool(raw.get("resamplingEnabled", True)),
        "resampleSpacing": bounded("resampleSpacing", 1.05, 0.05, 100.0),
        "splineAlgorithm": spline,
        "splineSampleSpacing": bounded("splineSampleSpacing", 0.9, 0.05, 100.0),
        "splineTension": bounded("splineTension", 0.12, 0.0, 1.0),
        "computedPressureSmoothing": bounded("computedPressureSmoothing", 0.18, 0.0, 1.0),
        "variableWidthRibbon": bool(raw.get("variableWidthRibbon", True)),
        "minimumPressureScale": bounded("minimumPressureScale", 0.24, 0.01, 5.0),
        "maximumPressureScale": bounded("maximumPressureScale", 1.22, 0.01, 5.0),
        "pressureGamma": bounded("pressureGamma", 0.72, 0.05, 10.0),
        "startTaperLength": bounded("startTaperLength", 1.5, 0.0, 1000.0),
        "endTaperLength": bounded("endTaperLength", 2.0, 0.0, 1000.0),
        "taperMinimumScale": bounded("taperMinimumScale", 0.18, 0.0, 1.0),
    }


def sanitize_stroke(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("stroke must be an object")
    stroke_id = str(raw.get("id", ""))[:128]
    if not stroke_id:
        raise ValueError("stroke id is required")
    tool = str(raw.get("tool", "pen"))
    if tool not in {"pen", "fixed-pen", "highlighter", "text", "shape"}:
        raise ValueError("unsupported tool")
    color = str(raw.get("color", "#111111"))[:32]
    width = max(0.25, min(100.0, float(raw.get("width", 3.0))))
    opacity = max(0.01, min(1.0, float(raw.get("opacity", 1.0))))
    points_raw = raw.get("points", [])
    if not isinstance(points_raw, list) or len(points_raw) > 100000:
        raise ValueError("invalid points")
    points = [validate_point(p) for p in points_raw]
    if tool == "text" and len(points) != 4:
        raise ValueError("text boxes require four corner points")
    shape_type = str(raw.get("shapeType", ""))
    shape_point_counts = {
        "rectangle": 4, "square": 4, "ellipse": 4, "circle": 4,
        "triangle": 4, "diamond": 4, "xy-plane": 4,
        "line": 2, "arrow": 2, "curve": 3,
    }
    if tool == "shape":
        if shape_type not in shape_point_counts:
            raise ValueError("unsupported shape type")
        if len(points) != shape_point_counts[shape_type]:
            raise ValueError("invalid shape point count")
    stroke = {
        "id": stroke_id,
        "tool": tool,
        "color": color,
        "width": width,
        "opacity": opacity,
        "smoothing": max(0.0, min(100.0, float(raw.get("smoothing", 35.0)))),
        "strokeDetail": max(0.0, min(100.0, float(raw.get("strokeDetail", 80.0)))),
        "lineStyle": (
            str(raw.get("lineStyle", "solid"))
            if str(raw.get("lineStyle", "solid")) in {"solid", "dashed", "dotted"}
            else "solid"
        ),
        "points": points,
        "owner": str(raw.get("owner", ""))[:128],
        "locked": bool(raw.get("locked", False)),
    }
    if raw.get("pageIndex") is not None:
        page_index = int(raw.get("pageIndex"))
        if not (0 <= page_index <= MAX_PDF_PAGES):
            raise ValueError("invalid page index")
        stroke["pageIndex"] = page_index
    pipeline = sanitize_pipeline(raw.get("pipeline"))
    if pipeline is not None:
        stroke["pipeline"] = pipeline
    if tool == "shape":
        snap_kind = str(raw.get("snapKind", ""))
        stroke.update({
            "shapeType": shape_type,
            "gridColor": str(raw.get("gridColor", "#7a7f89"))[:32],
            "recognitionSource": str(raw.get("recognitionSource", ""))[:32],
            "recognitionError": max(0.0, min(100.0, float(raw.get("recognitionError", 0.0)))),
            "snapKind": snap_kind if snap_kind in {"", "endpoint", "horizontal", "vertical", "tangent", "normal"} else "",
        })
    if tool == "text":
        text = str(raw.get("text", ""))
        if len(text) > 20_000:
            raise ValueError("text box content is too long")
        alignment = str(raw.get("textAlign", "left"))
        family = str(raw.get("fontFamily", "sans-serif"))
        stroke.update({
            "text": text,
            "textAlign": alignment if alignment in {"left", "center", "right"} else "left",
            "fontFamily": family if family in {"sans-serif", "serif", "monospace"} else "sans-serif",
        })
    return stroke


def sanitize_authoritative_strokes(raw: Any) -> dict[str, dict[str, Any]]:
    if isinstance(raw, dict):
        values = list(raw.values())
    elif isinstance(raw, list):
        values = raw
    else:
        raise ValueError("authoritative strokes must be an object or list")
    if len(values) > MAX_PROJECT_STROKES:
        raise ValueError("authoritative state contains too many strokes")

    result: dict[str, dict[str, Any]] = {}
    total_points = 0
    for raw_stroke in values:
        stroke = sanitize_stroke(raw_stroke)
        total_points += len(stroke["points"])
        if total_points > MAX_PROJECT_POINTS:
            raise ValueError("authoritative state contains too many points")
        if stroke["id"] in result:
            raise ValueError("authoritative state contains duplicate stroke ids")
        result[stroke["id"]] = stroke
    return result



def safe_filename(value: Any, fallback: str, *, extension: str | None = None) -> str:
    name = Path(str(value or fallback)).name.strip() or fallback
    name = re.sub(r"[^A-Za-z0-9._() -]+", "_", name)[:180].strip(" .") or fallback
    if extension and not name.lower().endswith(extension.lower()):
        name = f"{Path(name).stem or Path(fallback).stem}{extension}"
    return name


def prepare_pdf(content: bytes) -> tuple[Path, list[dict[str, Any]]]:
    if len(content) > MAX_PDF_BYTES:
        raise HTTPException(status_code=413, detail="PDF is larger than 100 MB")

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    temp_root = Path(tempfile.mkdtemp(prefix="pdf-prepare-", dir=DATA_DIR))
    temp_pages = temp_root / "pdf_pages"
    temp_pages.mkdir(parents=True, exist_ok=True)
    (temp_root / "current.pdf").write_bytes(content)

    try:
        document = fitz.open(stream=content, filetype="pdf")
    except Exception as exc:
        shutil.rmtree(temp_root, ignore_errors=True)
        raise HTTPException(status_code=400, detail=f"Could not open PDF: {exc}") from exc

    if document.page_count > MAX_PDF_PAGES:
        document.close()
        shutil.rmtree(temp_root, ignore_errors=True)
        raise HTTPException(
            status_code=400,
            detail=f"Prototype limit is {MAX_PDF_PAGES} pages",
        )

    pages: list[dict[str, Any]] = []
    y = 0.0
    matrix = fitz.Matrix(RENDER_SCALE, RENDER_SCALE)
    cache_token = uuid.uuid4().hex[:8]
    try:
        for index in range(document.page_count):
            page = document.load_page(index)
            rect = page.rect
            pixmap = page.get_pixmap(matrix=matrix, alpha=False)
            output_name = f"page-{index + 1:04d}.png"
            pixmap.save(temp_pages / output_name)
            pages.append(
                {
                    "id": f"page-{index + 1}",
                    "pageNumber": index + 1,
                    "imageUrl": f"/pdf-pages/{output_name}?v={cache_token}",
                    "x": 0.0,
                    "y": y,
                    "width": float(rect.width),
                    "height": float(rect.height),
                }
            )
            y += float(rect.height) + PAGE_GAP
    except Exception as exc:
        shutil.rmtree(temp_root, ignore_errors=True)
        raise HTTPException(status_code=400, detail=f"Could not render PDF: {exc}") from exc
    finally:
        document.close()

    return temp_root, pages


def commit_prepared_pdf(temp_root: Path) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    PDF_PAGES_DIR.mkdir(parents=True, exist_ok=True)

    for old in PDF_PAGES_DIR.glob("page-*.png"):
        old.unlink(missing_ok=True)
    for rendered in sorted((temp_root / "pdf_pages").glob("page-*.png")):
        os.replace(rendered, PDF_PAGES_DIR / rendered.name)
    os.replace(temp_root / "current.pdf", CURRENT_PDF)
    shutil.rmtree(temp_root, ignore_errors=True)


def clear_document_files() -> None:
    CURRENT_PDF.unlink(missing_ok=True)
    PDF_PAGES_DIR.mkdir(parents=True, exist_ok=True)
    for old in PDF_PAGES_DIR.glob("page-*.png"):
        old.unlink(missing_ok=True)


def sanitize_project_pages(raw_pages: Any) -> list[dict[str, Any]]:
    if raw_pages is None:
        return []
    if not isinstance(raw_pages, list) or len(raw_pages) > MAX_PDF_PAGES:
        raise HTTPException(status_code=400, detail="Project page layout is invalid")
    pages: list[dict[str, Any]] = []
    for index, raw_page in enumerate(raw_pages):
        if not isinstance(raw_page, dict):
            raise HTTPException(status_code=400, detail="Project page layout is invalid")
        try:
            x = float(raw_page.get("x", 0.0))
            y = float(raw_page.get("y", 0.0))
            width = float(raw_page["width"])
            height = float(raw_page["height"])
        except (KeyError, TypeError, ValueError) as exc:
            raise HTTPException(status_code=400, detail="Project page layout is invalid") from exc
        if not (-1e7 < x < 1e7 and -1e7 < y < 1e9 and 0.0 < width < 1e7 and 0.0 < height < 1e7):
            raise HTTPException(status_code=400, detail="Project page layout is invalid")
        pages.append(
            {
                "id": f"page-{index + 1}",
                "pageNumber": index + 1,
                "x": x,
                "y": y,
                "width": width,
                "height": height,
            }
        )
    return pages


def sanitize_project_state(raw: Any, *, has_pdf: bool) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise HTTPException(status_code=400, detail="Project state must be an object")

    raw_document = raw.get("document", {})
    if not isinstance(raw_document, dict):
        raise HTTPException(status_code=400, detail="Project document metadata is invalid")

    raw_strokes = raw.get("strokes", {})
    if isinstance(raw_strokes, list):
        stroke_values = raw_strokes
    elif isinstance(raw_strokes, dict):
        stroke_values = list(raw_strokes.values())
    else:
        raise HTTPException(status_code=400, detail="Project strokes must be an object or list")

    if len(stroke_values) > MAX_PROJECT_STROKES:
        raise HTTPException(status_code=400, detail="Project contains too many strokes")

    sanitized_strokes: dict[str, dict[str, Any]] = {}
    total_points = 0
    try:
        for raw_stroke in stroke_values:
            stroke = sanitize_stroke(raw_stroke)
            total_points += len(stroke["points"])
            if total_points > MAX_PROJECT_POINTS:
                raise HTTPException(status_code=400, detail="Project contains too many points")
            sanitized_strokes[stroke["id"]] = stroke
    except HTTPException:
        raise
    except (ValueError, KeyError, TypeError) as exc:
        raise HTTPException(status_code=400, detail=f"Invalid project stroke: {exc}") from exc

    filename = None
    source_pages: list[dict[str, Any]] = []
    if has_pdf:
        filename = safe_filename(raw_document.get("filename"), "document.pdf", extension=".pdf")
        source_pages = sanitize_project_pages(raw_document.get("pages", []))

    return {
        "version": 1,
        "document": {"filename": filename, "pages": source_pages},
        "strokes": sanitized_strokes,
    }


def read_project_archive(content: bytes) -> tuple[dict[str, Any], bytes | None]:
    try:
        archive = zipfile.ZipFile(io.BytesIO(content), "r")
    except zipfile.BadZipFile as exc:
        raise HTTPException(status_code=400, detail="The selected file is not a valid Infinite Notes project") from exc

    with archive:
        infos = archive.infolist()
        names = {info.filename for info in infos}
        allowed_names = {"manifest.json", "state.json", "document.pdf"}
        if not {"manifest.json", "state.json"}.issubset(names):
            raise HTTPException(status_code=400, detail="Project archive is missing manifest.json or state.json")
        if any(name not in allowed_names for name in names):
            raise HTTPException(status_code=400, detail="Project archive contains unsupported files")
        if any(info.is_dir() or info.filename.startswith(("/", "\\")) or ".." in Path(info.filename).parts for info in infos):
            raise HTTPException(status_code=400, detail="Project archive contains unsafe paths")

        total_uncompressed = sum(info.file_size for info in infos)
        if total_uncompressed > MAX_PROJECT_UNCOMPRESSED_BYTES:
            raise HTTPException(status_code=413, detail="Project expands beyond the supported size")

        info_by_name = {info.filename: info for info in infos}
        if info_by_name["manifest.json"].file_size > 64 * 1024:
            raise HTTPException(status_code=400, detail="Project manifest is too large")
        if info_by_name["state.json"].file_size > MAX_PROJECT_STATE_BYTES:
            raise HTTPException(status_code=413, detail="Project state is too large")
        if "document.pdf" in info_by_name and info_by_name["document.pdf"].file_size > MAX_PDF_BYTES:
            raise HTTPException(status_code=413, detail="Project PDF is larger than 100 MB")

        try:
            manifest = json.loads(archive.read("manifest.json"))
            raw_state = json.loads(archive.read("state.json"))
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise HTTPException(status_code=400, detail="Project metadata is invalid JSON") from exc

        if not isinstance(manifest, dict) or manifest.get("format") != PROJECT_FORMAT:
            raise HTTPException(status_code=400, detail="This is not an Infinite Notes project")
        version = manifest.get("formatVersion")
        if not isinstance(version, int) or version < 1 or version > PROJECT_FORMAT_VERSION:
            raise HTTPException(status_code=400, detail="Project version is not supported")

        pdf_content = archive.read("document.pdf") if "document.pdf" in names else None
        sanitized_state = sanitize_project_state(raw_state, has_pdf=pdf_content is not None)
        return sanitized_state, pdf_content



def stroke_world_bounds(stroke: dict[str, Any]) -> tuple[float, float, float, float] | None:
    points = stroke.get("points", [])
    if not points:
        return None
    xs = [float(point["x"]) for point in points]
    ys = [float(point["y"]) for point in points]
    # Pressure pen can reach 1.2x its configured width. Include a small safety
    # margin so the export warning never understates the required page size.
    width_scale = 1.2 if stroke.get("tool") == "pen" else 1.0
    pad = (0.75 if stroke.get("tool") == "text"
           else max(0.5, float(stroke.get("width", 3.0)) * width_scale / 2.0 + 0.75))
    return min(xs) - pad, min(ys) - pad, max(xs) + pad, max(ys) + pad


def page_distance_squared(x: float, y: float, page: dict[str, Any]) -> float:
    left = float(page.get("x", 0.0))
    top = float(page.get("y", 0.0))
    right = left + float(page.get("width", 0.0))
    bottom = top + float(page.get("height", 0.0))
    dx = 0.0 if left <= x <= right else min(abs(x - left), abs(x - right))
    dy = 0.0 if top <= y <= bottom else min(abs(y - top), abs(y - bottom))
    return dx * dx + dy * dy


def stroke_page_index(
    stroke: dict[str, Any],
    pages: list[dict[str, Any]],
    bounds: tuple[float, float, float, float] | None = None,
) -> int | None:
    if not pages:
        return None
    raw_index = stroke.get("pageIndex")
    if isinstance(raw_index, int) and 0 <= raw_index < len(pages):
        return raw_index
    if bounds is None:
        bounds = stroke_world_bounds(stroke)
    if bounds is None:
        return None
    min_x, min_y, max_x, max_y = bounds
    center_x = (min_x + max_x) / 2.0
    center_y = (min_y + max_y) / 2.0
    return min(
        range(len(pages)),
        key=lambda index: page_distance_squared(center_x, center_y, pages[index]),
    )


def build_pdf_export_layout(
    snapshot: dict[str, Any],
    overflow_margin: float = 0.0,
) -> list[dict[str, Any]]:
    pages = snapshot.get("document", {}).get("pages", [])
    if not pages:
        return []
    overflow_margin = max(0.0, min(200.0, float(overflow_margin)))

    layouts: list[dict[str, Any]] = []
    for page in pages:
        width = float(page["width"])
        height = float(page["height"])
        layouts.append(
            {
                "page": page,
                "strokes": [],
                "minX": 0.0,
                "minY": 0.0,
                "maxX": width,
                "maxY": height,
            }
        )

    for stroke in snapshot.get("strokes", {}).values():
        bounds = stroke_world_bounds(stroke)
        page_index = stroke_page_index(stroke, pages, bounds)
        if bounds is None or page_index is None:
            continue
        min_x, min_y, max_x, max_y = bounds
        page = pages[page_index]
        local_min_x = min_x - float(page.get("x", 0.0))
        local_min_y = min_y - float(page.get("y", 0.0))
        local_max_x = max_x - float(page.get("x", 0.0))
        local_max_y = max_y - float(page.get("y", 0.0))
        layout = layouts[page_index]
        layout["strokes"].append(stroke)
        layout["minX"] = min(layout["minX"], local_min_x)
        layout["minY"] = min(layout["minY"], local_min_y)
        layout["maxX"] = max(layout["maxX"], local_max_x)
        layout["maxY"] = max(layout["maxY"], local_max_y)

    for layout in layouts:
        layout["strokes"].sort(
            key=lambda stroke: 0
            if stroke.get("tool") == "shape"
            and stroke.get("shapeType") == "xy-plane"
            and stroke.get("locked")
            else 1
        )

    for index, layout in enumerate(layouts):
        page = layout["page"]
        original_width = float(page["width"])
        original_height = float(page["height"])
        raw_left = max(0.0, -float(layout["minX"]))
        raw_top = max(0.0, -float(layout["minY"]))
        raw_right = max(0.0, float(layout["maxX"]) - original_width)
        raw_bottom = max(0.0, float(layout["maxY"]) - original_height)

        margins = {
            "left": raw_left + (overflow_margin if raw_left > 0.01 else 0.0),
            "top": raw_top + (overflow_margin if raw_top > 0.01 else 0.0),
            "right": raw_right + (overflow_margin if raw_right > 0.01 else 0.0),
            "bottom": raw_bottom + (overflow_margin if raw_bottom > 0.01 else 0.0),
        }
        offset_x = margins["left"]
        offset_y = margins["top"]
        new_width = original_width + margins["left"] + margins["right"]
        new_height = original_height + margins["top"] + margins["bottom"]
        layout.update(
            {
                "pageNumber": index + 1,
                "originalWidth": original_width,
                "originalHeight": original_height,
                "offsetX": offset_x,
                "offsetY": offset_y,
                "newWidth": new_width,
                "newHeight": new_height,
                "margins": margins,
                "overflow": any(value > 0.01 for value in (raw_left, raw_top, raw_right, raw_bottom)),
            }
        )
    return layouts


def export_layout_summary(layouts: list[dict[str, Any]]) -> dict[str, Any]:
    pages = []
    for layout in layouts:
        pages.append(
            {
                "pageNumber": layout["pageNumber"],
                "overflow": layout["overflow"],
                "originalWidth": round(layout["originalWidth"], 2),
                "originalHeight": round(layout["originalHeight"], 2),
                "newWidth": round(layout["newWidth"], 2),
                "newHeight": round(layout["newHeight"], 2),
                "newWidthInches": round(layout["newWidth"] / 72.0, 2),
                "newHeightInches": round(layout["newHeight"] / 72.0, 2),
                "margins": {key: round(value, 2) for key, value in layout["margins"].items()},
            }
        )
    return {"hasOverflow": any(page["overflow"] for page in pages), "pages": pages}


def color_to_pdf(value: Any) -> tuple[float, float, float]:
    text = str(value or "#111111").strip().lower()
    if re.fullmatch(r"#[0-9a-f]{3}", text):
        text = "#" + "".join(character * 2 for character in text[1:])
    if not re.fullmatch(r"#[0-9a-f]{6}", text):
        text = "#111111"
    return tuple(int(text[index:index + 2], 16) / 255.0 for index in (1, 3, 5))


def pressure_width_scale(pressure: Any) -> float:
    try:
        value = max(0.0, min(1.0, float(pressure)))
    except (TypeError, ValueError):
        value = 0.5
    return 0.3 + value * 0.9


def pdf_font_name(family: Any) -> str:
    value = str(family or "sans-serif")
    if value == "serif":
        return "tiro"
    if value == "monospace":
        return "cour"
    return "helv"


def wrap_pdf_text(text: str, *, font_name: str, font_size: float, max_width: float) -> list[str]:
    lines: list[str] = []
    for paragraph in str(text or "").replace("\r", "").split("\n"):
        if paragraph == "":
            lines.append("")
            continue
        words = re.split(r"(\s+)", paragraph)
        line = ""
        for word in words:
            if not word:
                continue
            candidate = line + word
            if line and fitz.get_text_length(candidate, fontname=font_name, fontsize=font_size) > max_width:
                lines.append(line.rstrip())
                line = word.lstrip()
                if fitz.get_text_length(line, fontname=font_name, fontsize=font_size) > max_width:
                    fragment = ""
                    for character in line:
                        if fragment and fitz.get_text_length(fragment + character, fontname=font_name, fontsize=font_size) > max_width:
                            lines.append(fragment)
                            fragment = character
                        else:
                            fragment += character
                    line = fragment
            else:
                line = candidate
        lines.append(line.rstrip())
    return lines


def draw_text_on_pdf_page(
    page: fitz.Page,
    stroke: dict[str, Any],
    source_page: dict[str, Any],
    offset_x: float,
    offset_y: float,
) -> None:
    raw_points = stroke.get("points", [])
    if len(raw_points) < 4 or not str(stroke.get("text", "")):
        return
    page_x = float(source_page.get("x", 0.0))
    page_y = float(source_page.get("y", 0.0))
    points = [
        fitz.Point(float(point["x"]) - page_x + offset_x, float(point["y"]) - page_y + offset_y)
        for point in raw_points[:4]
    ]
    top_left, top_right, _, bottom_left = points
    width = math.hypot(top_right.x - top_left.x, top_right.y - top_left.y)
    height = math.hypot(bottom_left.x - top_left.x, bottom_left.y - top_left.y)
    if width < 0.01 or height < 0.01:
        return
    unit_x = ((top_right.x - top_left.x) / width, (top_right.y - top_left.y) / width)
    unit_y = ((bottom_left.x - top_left.x) / height, (bottom_left.y - top_left.y) / height)
    angle_degrees = math.degrees(math.atan2(unit_x[1], unit_x[0]))
    font_size = max(1.0, min(100.0, float(stroke.get("width", 24.0))))
    padding = max(2.0, font_size * 0.16)
    line_height = font_size * 1.25
    max_width = max(1.0, width - padding * 2.0)
    font_name = pdf_font_name(stroke.get("fontFamily"))
    color = color_to_pdf(stroke.get("color"))
    opacity = max(0.01, min(1.0, float(stroke.get("opacity", 1.0))))
    alignment = str(stroke.get("textAlign", "left"))
    lines = wrap_pdf_text(str(stroke.get("text", "")), font_name=font_name, font_size=font_size, max_width=max_width)
    baseline_y = padding + font_size
    rotation = fitz.Matrix(angle_degrees)
    for line in lines:
        if baseline_y + (line_height - font_size) > height:
            break
        line_width = fitz.get_text_length(line, fontname=font_name, fontsize=font_size)
        if alignment == "center":
            local_x = max(padding, (width - line_width) / 2.0)
        elif alignment == "right":
            local_x = max(padding, width - padding - line_width)
        else:
            local_x = padding
        insertion = fitz.Point(
            top_left.x + unit_x[0] * local_x + unit_y[0] * baseline_y,
            top_left.y + unit_x[1] * local_x + unit_y[1] * baseline_y,
        )
        page.insert_text(
            insertion,
            line,
            fontsize=font_size,
            fontname=font_name,
            color=color,
            fill_opacity=opacity,
            morph=(insertion, rotation),
            overlay=True,
        )
        baseline_y += line_height



def quadratic_point(a: fitz.Point, c: fitz.Point, b: fitz.Point, t: float) -> fitz.Point:
    u = 1.0 - t
    return fitz.Point(
        u * u * a.x + 2.0 * u * t * c.x + t * t * b.x,
        u * u * a.y + 2.0 * u * t * c.y + t * t * b.y,
    )


def shape_box_points(stroke: dict[str, Any], source_page: dict[str, Any], offset_x: float, offset_y: float) -> list[fitz.Point]:
    page_x = float(source_page.get("x", 0.0))
    page_y = float(source_page.get("y", 0.0))
    return [
        fitz.Point(float(point["x"]) - page_x + offset_x, float(point["y"]) - page_y + offset_y)
        for point in stroke.get("points", [])
    ]


def draw_pdf_arrow_head(page: fitz.Page, a: fitz.Point, b: fitz.Point, *, color: tuple[float, float, float], width: float, opacity: float) -> None:
    angle = math.atan2(b.y - a.y, b.x - a.x)
    size = max(7.0, width * 4.5)
    left = fitz.Point(b.x - math.cos(angle - math.pi / 6.0) * size, b.y - math.sin(angle - math.pi / 6.0) * size)
    right = fitz.Point(b.x - math.cos(angle + math.pi / 6.0) * size, b.y - math.sin(angle + math.pi / 6.0) * size)
    page.draw_polyline([left, b, right], color=color, width=width, lineCap=1, lineJoin=1, stroke_opacity=opacity, overlay=True)


def draw_shape_on_pdf_page(
    page: fitz.Page,
    stroke: dict[str, Any],
    source_page: dict[str, Any],
    offset_x: float,
    offset_y: float,
) -> None:
    points = shape_box_points(stroke, source_page, offset_x, offset_y)
    shape_type = str(stroke.get("shapeType", ""))
    if not points:
        return
    color = color_to_pdf(stroke.get("color"))
    grid_color = color_to_pdf(stroke.get("gridColor", "#7a7f89"))
    opacity = max(0.01, min(1.0, float(stroke.get("opacity", 1.0))))
    width = max(0.25, float(stroke.get("width", 3.0)))
    style = str(stroke.get("lineStyle", "solid"))
    dashes = None
    if style == "dashed":
        dashes = f"[{max(4.0, width * 3.2):.2f} {max(3.0, width * 2.0):.2f}] 0"
    elif style == "dotted":
        dashes = f"[{max(0.2, width * 0.15):.2f} {max(3.0, width * 2.1):.2f}] 0"

    if shape_type in {"line", "arrow"} and len(points) >= 2:
        page.draw_polyline(points[:2], color=color, width=width, dashes=dashes, lineCap=1, lineJoin=1, stroke_opacity=opacity, overlay=True)
        if shape_type == "arrow":
            draw_pdf_arrow_head(page, points[0], points[1], color=color, width=width, opacity=opacity)
        return
    if shape_type == "curve" and len(points) >= 3:
        samples = [quadratic_point(points[0], points[1], points[2], index / 64.0) for index in range(65)]
        page.draw_polyline(samples, color=color, width=width, dashes=dashes, lineCap=1, lineJoin=1, stroke_opacity=opacity, overlay=True)
        return
    if len(points) < 4:
        return

    top_left, top_right, bottom_right, bottom_left = points[:4]
    box_width = math.hypot(top_right.x - top_left.x, top_right.y - top_left.y)
    box_height = math.hypot(bottom_left.x - top_left.x, bottom_left.y - top_left.y)
    if box_width < 0.01 or box_height < 0.01:
        return
    ux = ((top_right.x - top_left.x) / box_width, (top_right.y - top_left.y) / box_width)
    uy = ((bottom_left.x - top_left.x) / box_height, (bottom_left.y - top_left.y) / box_height)

    def local(x: float, y: float) -> fitz.Point:
        return fitz.Point(top_left.x + ux[0] * x + uy[0] * y, top_left.y + ux[1] * x + uy[1] * y)

    if shape_type in {"ellipse", "circle"}:
        samples = []
        for index in range(97):
            angle = index / 96.0 * math.tau
            samples.append(local(box_width / 2.0 + math.cos(angle) * box_width / 2.0, box_height / 2.0 + math.sin(angle) * box_height / 2.0))
        page.draw_polyline(samples, color=color, width=width, dashes=dashes, lineCap=1, lineJoin=1, stroke_opacity=opacity, overlay=True)
        return
    if shape_type == "triangle":
        outline = [local(box_width / 2.0, 0.0), local(box_width, box_height), local(0.0, box_height), local(box_width / 2.0, 0.0)]
        page.draw_polyline(outline, color=color, width=width, dashes=dashes, lineCap=1, lineJoin=1, stroke_opacity=opacity, overlay=True)
        return
    if shape_type == "diamond":
        outline = [local(box_width / 2.0, 0.0), local(box_width, box_height / 2.0), local(box_width / 2.0, box_height), local(0.0, box_height / 2.0), local(box_width / 2.0, 0.0)]
        page.draw_polyline(outline, color=color, width=width, dashes=dashes, lineCap=1, lineJoin=1, stroke_opacity=opacity, overlay=True)
        return
    if shape_type == "xy-plane":
        grid_width = max(0.25, width * 0.34)
        for index in range(1, 10):
            x = box_width * index / 10.0
            y = box_height * index / 10.0
            page.draw_line(local(x, 0.0), local(x, box_height), color=grid_color, width=grid_width, stroke_opacity=min(0.45, opacity), overlay=True)
            page.draw_line(local(0.0, y), local(box_width, y), color=grid_color, width=grid_width, stroke_opacity=min(0.45, opacity), overlay=True)
        x_start, x_end = local(0.0, box_height / 2.0), local(box_width, box_height / 2.0)
        y_start, y_end = local(box_width / 2.0, box_height), local(box_width / 2.0, 0.0)
        page.draw_line(x_start, x_end, color=color, width=width, stroke_opacity=opacity, overlay=True)
        page.draw_line(y_start, y_end, color=color, width=width, stroke_opacity=opacity, overlay=True)
        draw_pdf_arrow_head(page, local(max(0.0, box_width - 20.0), box_height / 2.0), x_end, color=color, width=width, opacity=opacity)
        draw_pdf_arrow_head(page, local(box_width / 2.0, min(20.0, box_height)), y_end, color=color, width=width, opacity=opacity)
        return

    page.draw_polyline([top_left, top_right, bottom_right, bottom_left, top_left], color=color, width=width, dashes=dashes, lineCap=1, lineJoin=1, stroke_opacity=opacity, overlay=True)


def draw_stroke_on_pdf_page(
    page: fitz.Page,
    stroke: dict[str, Any],
    source_page: dict[str, Any],
    offset_x: float,
    offset_y: float,
) -> None:
    raw_points = stroke.get("points", [])
    if not raw_points:
        return
    if stroke.get("tool") == "text":
        draw_text_on_pdf_page(page, stroke, source_page, offset_x, offset_y)
        return
    if stroke.get("tool") == "shape":
        draw_shape_on_pdf_page(page, stroke, source_page, offset_x, offset_y)
        return
    page_x = float(source_page.get("x", 0.0))
    page_y = float(source_page.get("y", 0.0))
    points = [
        fitz.Point(
            float(point["x"]) - page_x + offset_x,
            float(point["y"]) - page_y + offset_y,
        )
        for point in raw_points
    ]
    color = color_to_pdf(stroke.get("color"))
    opacity = max(0.01, min(1.0, float(stroke.get("opacity", 1.0))))
    base_width = max(0.25, float(stroke.get("width", 3.0)))
    style = str(stroke.get("lineStyle", "solid"))
    tool = str(stroke.get("tool", "pen"))

    if len(points) == 1:
        scale = pressure_width_scale(raw_points[0].get("p", 0.5)) if tool == "pen" else 1.0
        radius = max(0.25, base_width * scale / 2.0)
        page.draw_circle(
            points[0], radius, color=color, fill=color, width=0,
            stroke_opacity=opacity, fill_opacity=opacity, overlay=True,
        )
        return

    if style != "solid":
        average_scale = 1.0
        if tool == "pen":
            average_scale = sum(pressure_width_scale(point.get("p", 0.5)) for point in raw_points) / len(raw_points)
        width = max(0.25, base_width * average_scale)
        if style == "dashed":
            dashes = f"[{max(4.0, width * 3.2):.2f} {max(3.0, width * 1.9):.2f}] 0"
        else:
            dashes = f"[{max(0.2, width * 0.12):.2f} {max(3.0, width * 2.05):.2f}] 0"
        page.draw_polyline(
            points, color=color, width=width, dashes=dashes,
            lineCap=1, lineJoin=1, stroke_opacity=opacity, overlay=True,
        )
        return

    if tool != "pen":
        page.draw_polyline(
            points, color=color, width=base_width, lineCap=1, lineJoin=1,
            stroke_opacity=opacity, overlay=True,
        )
        return

    # Pressure-sensitive pen: render short round-capped segments with the
    # width averaged from each endpoint. Input points are already densely
    # sampled by the Pencil pipeline, so this preserves the handwriting shape.
    for index in range(1, len(points)):
        p0 = raw_points[index - 1].get("p", 0.5)
        p1 = raw_points[index].get("p", 0.5)
        width = max(0.25, base_width * (pressure_width_scale(p0) + pressure_width_scale(p1)) / 2.0)
        page.draw_line(
            points[index - 1], points[index], color=color, width=width,
            lineCap=1, lineJoin=1, stroke_opacity=opacity, overlay=True,
        )


def outer_grid_palette(style: str) -> tuple[tuple[float, float, float], tuple[float, float, float]]:
    normalized = style.strip().lower()
    palettes = {
        "system": ((0.95, 0.95, 0.96), (0.72, 0.72, 0.75)),
        "white": ((1.0, 1.0, 1.0), (0.72, 0.72, 0.72)),
        "light-gray": ((0.86, 0.86, 0.86), (0.60, 0.60, 0.60)),
        "dark-gray": ((0.20, 0.20, 0.20), (0.48, 0.48, 0.48)),
        "black": ((0.0, 0.0, 0.0), (0.38, 0.38, 0.38)),
    }
    if normalized not in palettes:
        raise HTTPException(status_code=422, detail="outerGridStyle is not supported")
    return palettes[normalized]


def draw_outer_grid(
    page: fitz.Page,
    layout: dict[str, Any],
    style: str,
    spacing: float,
) -> None:
    if not layout.get("overflow"):
        return
    background, line = outer_grid_palette(style)
    spacing = max(4.0, min(200.0, float(spacing)))
    left = float(layout["offsetX"])
    top = float(layout["offsetY"])
    original_width = float(layout["originalWidth"])
    original_height = float(layout["originalHeight"])
    new_width = float(layout["newWidth"])
    new_height = float(layout["newHeight"])
    right_start = left + original_width
    bottom_start = top + original_height

    regions = [
        fitz.Rect(0, 0, left, new_height),
        fitz.Rect(right_start, 0, new_width, new_height),
        fitz.Rect(left, 0, right_start, top),
        fitz.Rect(left, bottom_start, right_start, new_height),
    ]
    for region in regions:
        if region.width <= 0.01 or region.height <= 0.01:
            continue
        page.draw_rect(region, color=None, fill=background, overlay=False)
        x = math.floor(region.x0 / spacing) * spacing
        while x <= region.x1 + 0.01:
            page.draw_line(
                fitz.Point(x, region.y0), fitz.Point(x, region.y1),
                color=line, width=0.55, stroke_opacity=0.72, overlay=False,
            )
            x += spacing
        y = math.floor(region.y0 / spacing) * spacing
        while y <= region.y1 + 0.01:
            page.draw_line(
                fitz.Point(region.x0, y), fitz.Point(region.x1, y),
                color=line, width=0.55, stroke_opacity=0.72, overlay=False,
            )
            y += spacing


def create_flattened_pdf(
    snapshot: dict[str, Any],
    pdf_content: bytes,
    *,
    overflow_margin: float = 0.0,
    outer_grid_style: str | None = None,
    outer_grid_spacing: float = 20.0,
) -> tuple[Path, dict[str, Any]]:
    layouts = build_pdf_export_layout(snapshot, overflow_margin=overflow_margin)
    if not layouts:
        raise HTTPException(status_code=400, detail="Open a PDF before exporting notes")
    try:
        source = fitz.open(stream=pdf_content, filetype="pdf")
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Could not open the current PDF: {exc}") from exc

    output = fitz.open()
    try:
        if source.page_count != len(layouts):
            raise HTTPException(status_code=409, detail="The saved page layout does not match the current PDF")
        for index, layout in enumerate(layouts):
            output_page = output.new_page(width=layout["newWidth"], height=layout["newHeight"])
            if outer_grid_style is not None:
                draw_outer_grid(output_page, layout, outer_grid_style, outer_grid_spacing)
            original_rect = fitz.Rect(
                layout["offsetX"],
                layout["offsetY"],
                layout["offsetX"] + layout["originalWidth"],
                layout["offsetY"] + layout["originalHeight"],
            )
            output_page.show_pdf_page(original_rect, source, index, keep_proportion=False, overlay=True)
            for stroke in layout["strokes"]:
                draw_stroke_on_pdf_page(
                    output_page,
                    stroke,
                    layout["page"],
                    layout["offsetX"],
                    layout["offsetY"],
                )

        DATA_DIR.mkdir(parents=True, exist_ok=True)
        fd, temp_name = tempfile.mkstemp(prefix="notes-export-", suffix=".pdf", dir=DATA_DIR)
        os.close(fd)
        output.save(temp_name, garbage=4, deflate=True)
        return Path(temp_name), export_layout_summary(layouts)
    finally:
        output.close()
        source.close()


@app.get("/")
async def root() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/state")
async def get_state() -> JSONResponse:
    async with state_lock:
        return JSONResponse(state)


@app.get("/api/pdf/source")
async def get_source_pdf() -> FileResponse:
    """Return the unchanged source PDF for the native iPad client.

    The browser client continues using the existing PNG page cache. The native
    client ignores that cache and draws this file through Core Graphics tiles.
    """
    async with state_lock:
        if not CURRENT_PDF.exists() or not state.get("document", {}).get("pages"):
            raise HTTPException(status_code=404, detail="No PDF is currently open")
        filename = safe_filename(
            state.get("document", {}).get("filename"),
            "document.pdf",
            extension=".pdf",
        )

    return FileResponse(
        CURRENT_PDF,
        media_type="application/pdf",
        filename=filename,
        headers={"Cache-Control": "no-store, max-age=0", "X-Infinite-Notes-PDF-Source": "original"},
    )


@app.post("/api/pdf")
async def upload_pdf(file: UploadFile = File(...)) -> JSONResponse:
    filename = safe_filename(file.filename, "document.pdf", extension=".pdf")
    content = await file.read(MAX_PDF_BYTES + 1)
    if len(content) > MAX_PDF_BYTES:
        raise HTTPException(status_code=413, detail="PDF is larger than 100 MB")

    temp_root, pages = prepare_pdf(content)
    try:
        async with state_lock:
            commit_prepared_pdf(temp_root)
            state["document"] = {"filename": filename, "pages": pages}
            state["strokes"] = {}
            history.clear()
            redo_history.clear()
            pending_stroke_history.clear()
            save_state_atomic()
            snapshot = copy.deepcopy(state["document"])
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)

    await broadcast({"type": "document_changed", "document": snapshot, "clearStrokes": True})
    await broadcast(history_status_message())
    return JSONResponse({"ok": True, "document": snapshot})


def remap_strokes_after_page_insert(
    strokes: Any,
    old_pages: list[dict[str, Any]],
    new_pages: list[dict[str, Any]],
    after_page_index: int,
) -> list[dict[str, Any]]:
    if not isinstance(strokes, dict):
        return []
    shifted: list[dict[str, Any]] = []
    for stroke in strokes.values():
        if not isinstance(stroke, dict):
            continue
        old_index = stroke_page_index(stroke, old_pages)
        if old_index is None or old_index <= after_page_index:
            continue
        new_index = old_index + 1
        if not (0 <= new_index < len(new_pages)):
            continue
        delta_y = float(new_pages[new_index].get("y", 0.0)) - float(old_pages[old_index].get("y", 0.0))
        points = stroke.get("points", [])
        if isinstance(points, list):
            for point in points:
                if not isinstance(point, dict):
                    continue
                try:
                    point["y"] = float(point.get("y", 0.0)) + delta_y
                    if "y_raw" in point:
                        point["y_raw"] = float(point.get("y_raw", point["y"])) + delta_y
                except (TypeError, ValueError):
                    continue
        stroke["pageIndex"] = new_index
        shifted.append(copy.deepcopy(stroke))
    return shifted


@app.post("/api/pages/insert")
async def insert_blank_page(afterPageNumber: int) -> JSONResponse:
    async with state_lock:
        old_pages = copy.deepcopy(state.get("document", {}).get("pages", []))
        if not CURRENT_PDF.exists() or not old_pages:
            raise HTTPException(status_code=400, detail="Open a PDF before inserting a page")
        if not (1 <= afterPageNumber <= len(old_pages)):
            raise HTTPException(status_code=422, detail="afterPageNumber must refer to an existing page")
        pdf_content = CURRENT_PDF.read_bytes()
        filename = state["document"].get("filename") or "document.pdf"

    try:
        document = fitz.open(stream=pdf_content, filetype="pdf")
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Could not open the current PDF: {exc}") from exc

    try:
        if document.page_count >= MAX_PDF_PAGES:
            raise HTTPException(status_code=400, detail=f"Prototype limit is {MAX_PDF_PAGES} pages")
        reference_index = afterPageNumber - 1
        reference_rect = document.load_page(reference_index).rect
        # PyMuPDF inserts before pno. A one-based page N therefore inserts
        # directly below it at zero-based index N.
        document.new_page(
            pno=afterPageNumber,
            width=float(reference_rect.width),
            height=float(reference_rect.height),
        )
        updated_pdf = document.tobytes(garbage=4, deflate=True)
    finally:
        document.close()

    temp_root, pages = prepare_pdf(updated_pdf)
    try:
        async with state_lock:
            if state.get("document", {}).get("pages", []) != old_pages:
                raise HTTPException(status_code=409, detail="The document changed while the page was being inserted")
            updated_strokes = copy.deepcopy(state.get("strokes", {}))
            shifted_strokes = remap_strokes_after_page_insert(
                updated_strokes, old_pages, pages, afterPageNumber - 1
            )
            commit_prepared_pdf(temp_root)
            state["document"] = {"filename": filename, "pages": pages}
            state["strokes"] = updated_strokes
            history.clear()
            redo_history.clear()
            pending_stroke_history.clear()
            save_state_atomic()
            snapshot = copy.deepcopy(state["document"])
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)

    inserted_page_number = afterPageNumber + 1
    message = {
        "type": "document_changed",
        "document": snapshot,
        "clearStrokes": False,
        "focusPageNumber": inserted_page_number,
        "notice": f"Blank page {inserted_page_number} inserted",
    }
    await broadcast(message)
    if shifted_strokes:
        await broadcast({"type": "replace_strokes", "strokes": shifted_strokes})
    await broadcast(history_status_message())
    return JSONResponse({
        "ok": True,
        "document": snapshot,
        "pageNumber": inserted_page_number,
        "shiftedStrokeCount": len(shifted_strokes),
    })


@app.post("/api/pages/append")
async def append_blank_page() -> JSONResponse:
    async with state_lock:
        if not CURRENT_PDF.exists() or not state.get("document", {}).get("pages"):
            raise HTTPException(status_code=400, detail="Open a PDF before adding a matching page")
        pdf_content = CURRENT_PDF.read_bytes()
        filename = state["document"].get("filename") or "document.pdf"

    try:
        document = fitz.open(stream=pdf_content, filetype="pdf")
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Could not open the current PDF: {exc}") from exc

    try:
        if document.page_count >= MAX_PDF_PAGES:
            raise HTTPException(status_code=400, detail=f"Prototype limit is {MAX_PDF_PAGES} pages")
        reference_rect = document.load_page(document.page_count - 1).rect
        document.new_page(width=float(reference_rect.width), height=float(reference_rect.height))
        updated_pdf = document.tobytes(garbage=4, deflate=True)
    finally:
        document.close()

    temp_root, pages = prepare_pdf(updated_pdf)
    try:
        async with state_lock:
            commit_prepared_pdf(temp_root)
            state["document"] = {"filename": filename, "pages": pages}
            save_state_atomic()
            snapshot = copy.deepcopy(state["document"])
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)

    page_number = len(pages)
    message = {
        "type": "document_changed",
        "document": snapshot,
        "clearStrokes": False,
        "focusPageNumber": page_number,
        "notice": f"Blank page {page_number} added",
    }
    await broadcast(message)
    return JSONResponse({"ok": True, "document": snapshot, "pageNumber": page_number})


@app.get("/api/pdf/export-info")
async def pdf_export_info(overflowMargin: float = 0.0) -> JSONResponse:
    if not (0.0 <= overflowMargin <= 200.0):
        raise HTTPException(status_code=422, detail="overflowMargin must be between 0 and 200")
    async with state_lock:
        if not CURRENT_PDF.exists() or not state.get("document", {}).get("pages"):
            raise HTTPException(status_code=400, detail="Open a PDF before exporting notes")
        snapshot = copy.deepcopy(state)
    return JSONResponse(export_layout_summary(
        build_pdf_export_layout(snapshot, overflow_margin=overflowMargin)
    ))


@app.get("/api/pdf/export")
async def export_flattened_pdf(
    overflowMargin: float = 0.0,
    outerGridStyle: str | None = None,
    outerGridSpacing: float = 20.0,
) -> FileResponse:
    if not (0.0 <= overflowMargin <= 200.0):
        raise HTTPException(status_code=422, detail="overflowMargin must be between 0 and 200")
    if not (4.0 <= outerGridSpacing <= 200.0):
        raise HTTPException(status_code=422, detail="outerGridSpacing must be between 4 and 200")
    if outerGridStyle is not None:
        outer_grid_palette(outerGridStyle)

    async with state_lock:
        if not CURRENT_PDF.exists() or not state.get("document", {}).get("pages"):
            raise HTTPException(status_code=400, detail="Open a PDF before exporting notes")
        snapshot = copy.deepcopy(state)
        pdf_content = CURRENT_PDF.read_bytes()

    temp_path, _summary = create_flattened_pdf(
        snapshot,
        pdf_content,
        overflow_margin=overflowMargin,
        outer_grid_style=outerGridStyle,
        outer_grid_spacing=outerGridSpacing,
    )
    document_name = snapshot.get("document", {}).get("filename") or "infinite-notes.pdf"
    export_name = safe_filename(
        f"{Path(document_name).stem}-notes.pdf",
        "infinite-notes.pdf",
        extension=".pdf",
    )
    return FileResponse(
        temp_path,
        media_type="application/pdf",
        filename=export_name,
        background=BackgroundTask(temp_path.unlink, missing_ok=True),
    )


@app.get("/api/project/export")
async def export_project() -> FileResponse:
    async with state_lock:
        snapshot = copy.deepcopy(state)
        pdf_content = CURRENT_PDF.read_bytes() if CURRENT_PDF.exists() else None

    document_name = snapshot.get("document", {}).get("filename") or "infinite-notes"
    project_name = safe_filename(f"{Path(document_name).stem}.inotes", "infinite-notes.inotes", extension=".inotes")
    manifest = {
        "format": PROJECT_FORMAT,
        "formatVersion": PROJECT_FORMAT_VERSION,
        "appVersion": APP_VERSION,
        "exportedAt": datetime.now(timezone.utc).isoformat(),
        "hasPdf": pdf_content is not None,
    }

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix="project-export-", suffix=".inotes", dir=DATA_DIR)
    os.close(fd)
    try:
        with zipfile.ZipFile(temp_name, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            archive.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2))
            archive.writestr("state.json", json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")))
            if pdf_content is not None:
                archive.writestr("document.pdf", pdf_content)
    except Exception:
        Path(temp_name).unlink(missing_ok=True)
        raise

    return FileResponse(
        temp_name,
        media_type="application/vnd.infinite-notes.project+zip",
        filename=project_name,
        background=BackgroundTask(Path(temp_name).unlink, missing_ok=True),
    )


@app.post("/api/project/import")
async def import_project(file: UploadFile = File(...)) -> JSONResponse:
    content = await file.read(MAX_PROJECT_BYTES + 1)
    if len(content) > MAX_PROJECT_BYTES:
        raise HTTPException(status_code=413, detail="Project file is larger than 256 MB")

    imported_state, pdf_content = read_project_archive(content)
    temp_root: Path | None = None
    pages: list[dict[str, Any]] = []
    if pdf_content is not None:
        source_pages = imported_state["document"].get("pages", [])
        temp_root, pages = prepare_pdf(pdf_content)
        reflow_strokes_between_page_layouts(imported_state["strokes"], source_pages, pages)
        imported_state["document"]["pages"] = pages

    try:
        async with state_lock:
            if temp_root is not None:
                commit_prepared_pdf(temp_root)
            else:
                clear_document_files()

            state.clear()
            state.update(imported_state)
            history.clear()
            redo_history.clear()
            pending_stroke_history.clear()
            save_state_atomic()
            snapshot = copy.deepcopy(state)
    finally:
        if temp_root is not None:
            shutil.rmtree(temp_root, ignore_errors=True)

    imported_snapshot_message = {
        "type": "snapshot",
        "state": snapshot,
        "liveStrokeIds": [],
        "reason": "project_import",
        "serverTime": datetime.now(timezone.utc).isoformat(),
    }
    # Browser clients still understand the legacy snapshot message. Native clients
    # fetch the same state over compressed HTTP so a large notebook is never sent
    # as one WebSocket frame.
    await broadcast(imported_snapshot_message, exclude_kinds={"native"})
    await send_to_kind("native", state_refresh_message(reason="project_import"))
    await broadcast(history_status_message())
    return JSONResponse({
        "ok": True,
        "reason": "project_import",
        "strokeCount": len(snapshot.get("strokes", {})),
        "document": snapshot.get("document", {}),
    })


@app.post("/api/reset")
async def reset_canvas() -> JSONResponse:
    async with state_lock:
        deleted = copy.deepcopy(list(state["strokes"].values()))
        state["strokes"] = {}
        if deleted:
            push_history({"type": "delete", "strokes": deleted})
        save_state_atomic()
    await broadcast({"type": "clear_strokes"})
    await broadcast(history_status_message())
    return JSONResponse({"ok": True})


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    await websocket.accept()
    role = str(websocket.query_params.get("role", "desktop")).lower()
    if role not in {"ipad", "desktop"}:
        role = "desktop"
    client_id = str(websocket.query_params.get("clientId", ""))[:256]
    client_kind = "native" if role == "ipad" and client_id.startswith("native-") else "browser"
    clients.add(websocket)
    client_roles[websocket] = role
    client_kinds[websocket] = client_kind
    try:
        async with state_lock:
            initial_history = history_status_message()
            initial_message = (
                state_refresh_message(reason="initial")
                if client_kind == "native"
                else snapshot_message(reason="initial")
            )
        initial_message["clientRole"] = role
        await websocket.send_json(initial_message)
        await websocket.send_json(initial_history)

        while True:
            raw_text = await websocket.receive_text()
            try:
                message = json.loads(raw_text)
                message_type = message.get("type")

                if message_type == "stroke_begin":
                    stroke = sanitize_stroke(message.get("stroke"))
                    async with state_lock:
                        state["strokes"][stroke["id"]] = stroke
                        pending_stroke_history.add(stroke["id"])
                    await broadcast({"type": "stroke_begin", "stroke": stroke}, exclude=websocket)

                elif message_type == "stroke_points":
                    stroke_id = str(message.get("id", ""))[:128]
                    points_raw = message.get("points", [])
                    if not isinstance(points_raw, list) or len(points_raw) > 1000:
                        raise ValueError("invalid point batch")
                    points = [validate_point(p) for p in points_raw]
                    async with state_lock:
                        stroke = state["strokes"].get(stroke_id)
                        if stroke is None:
                            continue
                        if len(stroke["points"]) + len(points) > 100000:
                            raise ValueError("stroke is too large")
                        stroke["points"].extend(points)
                    await broadcast(
                        {"type": "stroke_points", "id": stroke_id, "points": points},
                        exclude=websocket,
                    )

                elif message_type == "stroke_end":
                    stroke_id = str(message.get("id", ""))[:128]
                    final_raw = message.get("stroke")
                    final_stroke: dict[str, Any] | None = None
                    if final_raw is not None:
                        final_stroke = sanitize_stroke(final_raw)
                        if final_stroke["id"] != stroke_id:
                            raise ValueError("final stroke id does not match")
                    history_changed = False
                    replaced_live = False
                    async with state_lock:
                        stroke = state["strokes"].get(stroke_id)
                        if stroke is not None:
                            if final_stroke is not None:
                                state["strokes"][stroke_id] = final_stroke
                                stroke = final_stroke
                                replaced_live = True
                            if stroke_id in pending_stroke_history:
                                pending_stroke_history.discard(stroke_id)
                                push_history({"type": "add", "strokes": [copy.deepcopy(stroke)]})
                                history_changed = True
                            save_state_atomic()
                    if replaced_live and final_stroke is not None:
                        await broadcast({"type": "replace_strokes", "strokes": [final_stroke]}, exclude=websocket)
                    await broadcast({"type": "stroke_end", "id": stroke_id}, exclude=websocket)
                    if history_changed:
                        await broadcast(history_status_message())

                elif message_type == "add_strokes":
                    strokes_raw = message.get("strokes", [])
                    if not isinstance(strokes_raw, list) or len(strokes_raw) > MAX_SELECTION_STROKES:
                        raise ValueError("invalid stroke collection")
                    strokes = [sanitize_stroke(raw_stroke) for raw_stroke in strokes_raw]
                    ids = [stroke["id"] for stroke in strokes]
                    if len(ids) != len(set(ids)):
                        raise ValueError("duplicate stroke ids")
                    async with state_lock:
                        if any(stroke_id in state["strokes"] for stroke_id in ids):
                            raise ValueError("stroke id already exists")
                        for stroke in strokes:
                            state["strokes"][stroke["id"]] = stroke
                        if strokes:
                            push_history({"type": "add", "strokes": copy.deepcopy(strokes)})
                        save_state_atomic()
                    if strokes:
                        await broadcast({"type": "restore_strokes", "strokes": strokes}, exclude=websocket)
                        await broadcast(history_status_message())

                elif message_type == "replace_strokes":
                    strokes_raw = message.get("strokes", [])
                    if not isinstance(strokes_raw, list) or len(strokes_raw) > MAX_SELECTION_STROKES:
                        raise ValueError("invalid stroke collection")
                    replacements = [sanitize_stroke(raw_stroke) for raw_stroke in strokes_raw]
                    ids = [stroke["id"] for stroke in replacements]
                    if len(ids) != len(set(ids)):
                        raise ValueError("duplicate stroke ids")
                    async with state_lock:
                        missing = [stroke_id for stroke_id in ids if stroke_id not in state["strokes"]]
                        if missing:
                            raise ValueError("cannot replace a missing stroke")
                        before = [copy.deepcopy(state["strokes"][stroke_id]) for stroke_id in ids]
                        for stroke in replacements:
                            state["strokes"][stroke["id"]] = stroke
                        if replacements:
                            push_history({
                                "type": "replace",
                                "before": before,
                                "after": copy.deepcopy(replacements),
                            })
                        save_state_atomic()
                    if replacements:
                        await broadcast({"type": "replace_strokes", "strokes": replacements}, exclude=websocket)
                        await broadcast(history_status_message())

                elif message_type == "delete_strokes":
                    ids_raw = message.get("ids", [])
                    if not isinstance(ids_raw, list):
                        raise ValueError("ids must be a list")
                    if len(ids_raw) > MAX_SELECTION_STROKES:
                        raise ValueError("too many stroke ids")
                    ids = list(dict.fromkeys(str(value)[:128] for value in ids_raw if str(value)))
                    operation_id = str(message.get("operationId", ""))[:128]
                    final = bool(message.get("final", not operation_id))
                    deleted: list[dict[str, Any]] = []
                    history_changed = False
                    async with state_lock:
                        now = time.monotonic()
                        stale_ids = [
                            key for key, value in pending_delete_operations.items()
                            if now - float(value.get("updatedAt", now)) >= DELETE_OPERATION_STALE_SECONDS
                        ]
                        for stale_id in stale_ids:
                            stale = pending_delete_operations.pop(stale_id, None)
                            stale_strokes = list((stale or {}).get("strokes", {}).values())
                            if stale_strokes:
                                push_history({"type": "delete", "strokes": copy.deepcopy(stale_strokes)})
                                history_changed = True

                        for stroke_id in ids:
                            stroke = state["strokes"].pop(stroke_id, None)
                            pending_stroke_history.discard(stroke_id)
                            if stroke is not None:
                                deleted.append(copy.deepcopy(stroke))

                        if operation_id:
                            transaction = pending_delete_operations.setdefault(
                                operation_id,
                                {"strokes": {}, "updatedAt": now},
                            )
                            transaction["updatedAt"] = now
                            for stroke in deleted:
                                transaction["strokes"][stroke["id"]] = stroke
                            if final:
                                transaction = pending_delete_operations.pop(operation_id, transaction)
                                grouped = list(transaction["strokes"].values())
                                if grouped:
                                    push_history({"type": "delete", "strokes": copy.deepcopy(grouped)})
                                    history_changed = True
                        elif deleted:
                            push_history({"type": "delete", "strokes": copy.deepcopy(deleted)})
                            history_changed = True

                        save_state_atomic()

                    acknowledgement = {"type": "delete_ack", "ids": ids, "final": final}
                    if operation_id:
                        acknowledgement["operationId"] = operation_id
                    await websocket.send_json(acknowledgement)
                    if ids:
                        await broadcast({"type": "delete_strokes", "ids": ids}, exclude=websocket)
                    if history_changed:
                        await broadcast(history_status_message())

                elif message_type == "sync_request":
                    async with state_lock:
                        requested_history = history_status_message()
                        requested_message = (
                            state_refresh_message(reason="manual_sync")
                            if client_kind == "native"
                            else snapshot_message(reason="manual_sync")
                        )
                    await websocket.send_json(requested_message)
                    await websocket.send_json(requested_history)

                elif message_type == "clear_strokes":
                    async with state_lock:
                        deleted = copy.deepcopy(list(state["strokes"].values()))
                        state["strokes"] = {}
                        pending_stroke_history.clear()
                        if deleted:
                            push_history({"type": "delete", "strokes": deleted})
                        save_state_atomic()
                    await broadcast({"type": "clear_strokes"}, exclude=websocket)
                    if deleted:
                        await broadcast(history_status_message())

                elif message_type in {"undo", "redo"}:
                    source = history if message_type == "undo" else redo_history
                    destination = redo_history if message_type == "undo" else history
                    change: dict[str, Any] | None = None
                    async with state_lock:
                        if source:
                            action = source.pop()
                            change = apply_history_action(action, undo=message_type == "undo")
                            destination.append(action)
                            save_state_atomic()
                    if change is not None:
                        await broadcast(change)
                    await broadcast(history_status_message())

                elif message_type == "ping":
                    await websocket.send_json({"type": "pong", "clientTime": message.get("clientTime")})

                else:
                    await websocket.send_json({"type": "error", "message": "Unknown message type"})

            except (ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
                await websocket.send_json({"type": "error", "message": str(exc)})

    except WebSocketDisconnect:
        pass
    finally:
        clients.discard(websocket)
        client_roles.pop(websocket, None)
        client_kinds.pop(websocket, None)


def local_ipv4_addresses() -> list[str]:
    addresses: set[str] = set()
    try:
        hostname = socket.gethostname()
        for item in socket.getaddrinfo(hostname, None, family=socket.AF_INET):
            address = item[4][0]
            if not address.startswith("127."):
                addresses.add(address)
    except OSError:
        pass

    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("8.8.8.8", 80))
        addresses.add(probe.getsockname()[0])
        probe.close()
    except OSError:
        pass
    return sorted(addresses)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the Infinite Notes prototype")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--reload", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    print("\nInfinite Notes Prototype")
    print(f"Desktop: http://127.0.0.1:{args.port}/?mode=desktop")
    for address in local_ipv4_addresses():
        print(f"iPad:   http://{address}:{args.port}/?mode=ipad")
    print("\nThe iPad and laptop must be on the same private network.\n")
    uvicorn.run("server:app", host=args.host, port=args.port, reload=args.reload)
