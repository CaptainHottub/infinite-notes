"""Best-effort, privacy-preserving diagnostics for Infinite Notes.

Callers enqueue small, sanitized event records. A daemon thread owns terminal
and file output so diagnostics never perform I/O on sync or persistence paths.
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from itertools import islice
from pathlib import Path
from typing import Any

MAX_LOG_BYTES = 5 * 1024 * 1024
MAX_LOG_BACKUPS = 2
MAX_QUEUED_EVENTS = 4096
MAX_FIELDS = 50
MAX_LIST_ITEMS = 50
MAX_FIELD_LENGTH = 512
_STOP = object()

_FORBIDDEN_FIELDS = {
    "category",
    "content",
    "data",
    "document",
    "event",
    "eventsequence",
    "payload",
    "pdf",
    "points",
    "project",
    "sessionid",
    "state",
    "stroke",
    "strokes",
    "text",
    "timestamp",
}

_CATEGORY_COLORS = {
    "ack": "\033[36m",
    "conflict": "\033[31m",
    "connection": "\033[34m",
    "lifecycle": "\033[35m",
    "page": "\033[33m",
    "persistence": "\033[32m",
    "protocol": "\033[90m",
    "reconciliation": "\033[36m",
    "sync": "\033[33m",
}
_COLOR_RESET = "\033[0m"


def _utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def _safe_value(value: Any) -> Any:
    """Return bounded scalar metadata without descending into containers."""
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, str):
        return value[:MAX_FIELD_LENGTH]
    if isinstance(value, (bytes, bytearray, memoryview)):
        return "<redacted:binary>"
    if isinstance(value, dict):
        return "<redacted:object>"
    if isinstance(value, (list, tuple, set, frozenset)):
        result: list[Any] = []
        for item in islice(value, MAX_LIST_ITEMS):
            if item is None or isinstance(item, (bool, int, float, str)):
                result.append(_safe_value(item))
            else:
                result.append("<redacted:item>")
        return result
    return "<redacted:unsupported>"


def sanitize_fields(fields: dict[str, Any]) -> dict[str, Any]:
    """Drop content-bearing keys and bound all remaining metadata."""
    sanitized: dict[str, Any] = {}
    for key, value in islice(fields.items(), MAX_FIELDS):
        safe_key = str(key)[:64]
        if safe_key.lower() in _FORBIDDEN_FIELDS:
            continue
        sanitized[safe_key] = _safe_value(value)
    return sanitized


def _bounded_string(value: Any, limit: int) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        return value[:limit]
    if isinstance(value, (bool, int, float)):
        return str(value)[:limit]
    return None


def _bounded_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError, OverflowError):
        return None


def protocol_summary(message: Any) -> dict[str, Any]:
    """Summarize one wire message without retaining content or walking points."""
    if not isinstance(message, dict):
        return {"messageType": "invalid"}

    message_type = _bounded_string(message.get("type"), 64) or "unknown"
    summary: dict[str, Any] = {"messageType": message_type}
    stroke_id = _bounded_string(message.get("id"), 128)
    if stroke_id is not None:
        summary["strokeId"] = stroke_id

    ids = message.get("ids")
    if isinstance(ids, list):
        summary["idCount"] = len(ids)

    for source_key, result_key, limit in (
        ("operationId", "operationId", 128),
        ("documentId", "documentId", 128),
        ("stateToken", "stateToken", 256),
        ("reason", "reason", 128),
    ):
        value = _bounded_string(message.get(source_key), limit)
        if value is not None:
            summary[result_key] = value

    if "final" in message:
        summary["final"] = bool(message["final"])

    explicit_point_count = _bounded_int(message.get("pointCount"))
    if explicit_point_count is not None:
        summary["pointCount"] = max(0, explicit_point_count)

    document_revision = _bounded_int(message.get("documentRevision"))
    if document_revision is not None and document_revision >= 0:
        summary["documentRevision"] = document_revision

    points = message.get("points")
    if isinstance(points, list):
        summary["pointCount"] = len(points)

    strokes = message.get("strokes")
    if isinstance(strokes, (list, dict)):
        summary["strokeCount"] = len(strokes)

    stroke = message.get("stroke")
    if isinstance(stroke, dict):
        summary["strokeCount"] = 1
        nested_id = _bounded_string(stroke.get("id"), 128)
        if nested_id is not None:
            summary.setdefault("strokeId", nested_id)

    state = message.get("state")
    if isinstance(state, dict):
        state_document_id = _bounded_string(state.get("documentId"), 128)
        if state_document_id is not None:
            summary["documentId"] = state_document_id
        state_strokes = state.get("strokes")
        if isinstance(state_strokes, (list, dict)):
            summary["strokeCount"] = len(state_strokes)
        document = state.get("document")
        if isinstance(document, dict):
            pages = document.get("pages")
            if isinstance(pages, list):
                summary["pageCount"] = len(pages)

    return summary


class DebugEventLogger:
    """Bounded asynchronous writer for terminal, text, and JSONL events."""

    def __init__(
        self,
        *,
        enabled: bool,
        logs_dir: Path,
        session_id: str | None = None,
        max_bytes: int = MAX_LOG_BYTES,
        backup_count: int = MAX_LOG_BACKUPS,
        queue_capacity: int = MAX_QUEUED_EVENTS,
    ) -> None:
        self.enabled = bool(enabled)
        self.session_id = (
            str(session_id)[:128]
            if self.enabled and session_id
            else uuid.uuid4().hex if self.enabled else None
        )
        self.logs_dir = Path(logs_dir)
        self.max_bytes = max(128, int(max_bytes))
        self.backup_count = max(1, int(backup_count))
        self._queue: queue.Queue[object] = queue.Queue(maxsize=max(1, int(queue_capacity)))
        self._state_lock = threading.Lock()
        self._close_lock = threading.Lock()
        self._sequence = 0
        self._dropped_events = 0
        self._failed = False
        self._closed = False
        self._thread: threading.Thread | None = None
        self.text_path: Path | None = None
        self.jsonl_path: Path | None = None

        if self.enabled:
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            safe_session = "".join(
                character if character.isalnum() or character in "-_" else "_"
                for character in self.session_id or "unknown"
            )[:64]
            prefix = f"infinite-notes-debug-{stamp}-{safe_session}"
            self.text_path = self.logs_dir / f"{prefix}.log"
            self.jsonl_path = self.logs_dir / f"{prefix}.jsonl"
            self._thread = threading.Thread(
                target=self._writer,
                name="InfiniteNotesDebugWriter",
                daemon=True,
            )
            self._thread.start()

    @classmethod
    def from_environment(cls, logs_dir: Path) -> "DebugEventLogger":
        enabled = os.environ.get("INFINITE_NOTES_DEBUG", "").lower() in {"1", "true", "yes"}
        return cls(enabled=enabled, logs_dir=logs_dir)

    @property
    def dropped_event_count(self) -> int:
        with self._state_lock:
            return self._dropped_events

    def event(self, category: str, event: str, **fields: Any) -> None:
        if not self.enabled:
            return
        try:
            sanitized = sanitize_fields(fields)
            with self._state_lock:
                if self._failed or self._closed:
                    return
                record = self._record_locked(category, event, sanitized)
                try:
                    self._queue.put_nowait(record)
                except queue.Full:
                    self._dropped_events += 1
        except Exception:
            self._mark_failed(announce=False)

    def protocol(
        self,
        direction: str,
        message: Any,
        *,
        byte_count: int,
        **fields: Any,
    ) -> None:
        # This guard deliberately precedes protocol_summary: normal operation must
        # not inspect large snapshots or stroke batches for diagnostic purposes.
        if not self.enabled:
            return
        with self._state_lock:
            if self._failed or self._closed:
                return
        metadata = {
            "direction": direction,
            "byteCount": max(0, byte_count),
            **protocol_summary(message),
        }
        metadata.update(fields)
        self.event("protocol", "message", **metadata)

    def flush(self, timeout: float = 2.0) -> bool:
        if not self.enabled or self._thread is None or not self._thread.is_alive():
            return True
        done = threading.Event()
        try:
            self._queue.put(done, timeout=max(0.0, timeout))
            return done.wait(max(0.0, timeout))
        except queue.Full:
            return False

    def close(self, timeout: float = 2.0) -> None:
        if not self.enabled:
            return
        with self._close_lock:
            with self._state_lock:
                if self._closed:
                    return
                if not self._failed:
                    record = self._record_locked(
                        "lifecycle",
                        "session_ended",
                        {"droppedEventCount": self._dropped_events},
                    )
                    try:
                        self._queue.put_nowait(record)
                    except queue.Full:
                        self._dropped_events += 1
                self._closed = True
            thread = self._thread
            if thread is None or not thread.is_alive():
                return
            deadline = time.monotonic() + max(0.0, timeout)
            try:
                self._queue.put(_STOP, timeout=max(0.0, timeout))
            except queue.Full:
                return
            thread.join(max(0.0, deadline - time.monotonic()))

    def _record_locked(
        self,
        category: str,
        event: str,
        fields: dict[str, Any],
    ) -> dict[str, Any]:
        self._sequence += 1
        return {
            "timestamp": _utc_timestamp(),
            "sessionId": self.session_id,
            "eventSequence": self._sequence,
            "category": str(category)[:64],
            "event": str(event)[:128],
            **fields,
        }

    def _format_text(self, record: dict[str, Any], *, color: bool = False) -> str:
        fixed = {"timestamp", "sessionId", "eventSequence", "category", "event"}
        details = " ".join(
            f"{key}={value}" for key, value in record.items() if key not in fixed
        )
        category = str(record["category"]).upper()
        label = f"[{category}]"
        if color:
            escape = _CATEGORY_COLORS.get(str(record["category"]).lower(), "\033[37m")
            label = f"{escape}{label}{_COLOR_RESET}"
        suffix = f" {details}" if details else ""
        return (
            f"{record['timestamp']} session={record['sessionId']} {label} "
            f"#{record['eventSequence']} {record['event']}{suffix}"
        )

    def _writer(self) -> None:
        try:
            self.logs_dir.mkdir(parents=True, exist_ok=True)
            while True:
                item = self._queue.get()
                if item is _STOP:
                    return
                if isinstance(item, threading.Event):
                    item.set()
                    continue
                if not isinstance(item, dict):
                    continue

                plain = self._format_text(item)
                try:
                    is_tty = bool(getattr(sys.stdout, "isatty", lambda: False)())
                    print(self._format_text(item, color=is_tty), flush=True)
                except Exception:
                    pass
                self._append(self.text_path, plain + "\n")
                self._append(
                    self.jsonl_path,
                    json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n",
                )
        except Exception:
            self._mark_failed(announce=True)

    def _append(self, path: Path | None, value: str) -> None:
        if path is None:
            return
        encoded_size = len(value.encode("utf-8"))
        if path.exists() and path.stat().st_size + encoded_size > self.max_bytes:
            self._rotate(path)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(value)
            handle.flush()

    def _rotate(self, path: Path) -> None:
        oldest = path.with_name(f"{path.name}.{self.backup_count}")
        if oldest.exists():
            oldest.unlink()
        for index in range(self.backup_count - 1, 0, -1):
            source = path.with_name(f"{path.name}.{index}")
            if source.exists():
                shutil.move(source, path.with_name(f"{path.name}.{index + 1}"))
        if path.exists():
            shutil.move(path, path.with_name(f"{path.name}.1"))

    def _mark_failed(self, *, announce: bool) -> None:
        with self._state_lock:
            already_failed = self._failed
            self._failed = True
        if announce and not already_failed:
            try:
                print(
                    "Infinite Notes debug logging failed; product operation will continue.",
                    file=sys.stderr,
                    flush=True,
                )
            except Exception:
                pass
