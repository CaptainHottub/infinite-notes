import copy
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest
from fastapi.testclient import TestClient

import server
from server import app, client_kinds, client_roles, clients, history, pending_delete_operations, pending_stroke_history, redo_history, state


@pytest.fixture(autouse=True)
def isolated_state(monkeypatch):
    state_backup = copy.deepcopy(state)
    history_backup = copy.deepcopy(history)
    redo_backup = copy.deepcopy(redo_history)
    pending_backup = set(pending_stroke_history)
    client_roles.clear()
    client_kinds.clear()
    clients.clear()
    pending_delete_operations.clear()
    monkeypatch.setattr(server, "save_state_atomic", lambda: None)
    state["strokes"] = {}
    history.clear()
    redo_history.clear()
    pending_stroke_history.clear()
    yield
    state.clear()
    state.update(state_backup)
    history[:] = history_backup
    redo_history[:] = redo_backup
    pending_stroke_history.clear()
    pending_stroke_history.update(pending_backup)
    client_roles.clear()
    client_kinds.clear()
    clients.clear()
    pending_delete_operations.clear()


def test_root_and_state():
    client = TestClient(app)
    assert client.get("/").status_code == 200
    response = client.get("/api/state")
    assert response.status_code == 200
    assert "document" in response.json()
    assert "strokes" in response.json()


def test_websocket_snapshot():
    client = TestClient(app)
    with client.websocket_connect("/ws") as websocket:
        message = websocket.receive_json()
        assert message["type"] == "snapshot"
        assert "state" in message
        history_state = websocket.receive_json()
        assert history_state == {"type": "history_state", "canUndo": False, "canRedo": False}



def test_native_websocket_uses_small_http_refresh_message():
    # A native client must never receive the full notebook as one WebSocket frame.
    state["strokes"] = {
        "large": {
            "id": "large",
            "owner": "test",
            "tool": "pen",
            "color": "#111111",
            "width": 3,
            "opacity": 1,
            "smoothing": 35,
            "points": [
                {"x": index, "y": index, "p": 0.5, "t": index}
                for index in range(20_000)
            ],
        }
    }

    client = TestClient(app)
    with client.websocket_connect("/ws?role=ipad&clientId=native-test") as websocket:
        message = websocket.receive_json()
        assert message["type"] == "state_refresh"
        assert message["reason"] == "initial"
        assert "state" not in message
        assert len(str(message)) < 1_000
        assert websocket.receive_json()["type"] == "history_state"


def test_native_manual_sync_uses_http_refresh_message():
    client = TestClient(app)
    with client.websocket_connect("/ws?role=ipad&clientId=native-test") as websocket:
        websocket.receive_json()
        websocket.receive_json()
        websocket.send_json({"type": "sync_request"})
        message = websocket.receive_json()
        assert message["type"] == "state_refresh"
        assert message["reason"] == "manual_sync"
        assert "state" not in message
        assert websocket.receive_json()["type"] == "history_state"



def test_project_import_notifies_native_client_with_small_refresh(monkeypatch, tmp_path):
    configure_temp_document_paths(monkeypatch, tmp_path)
    project_state = {
        "version": 1,
        "document": {"filename": None, "pages": []},
        "strokes": {
            "restored": {
                "id": "restored",
                "owner": "backup",
                "tool": "pen",
                "color": "#111111",
                "width": 3,
                "opacity": 1,
                "smoothing": 35,
                "points": [{"x": 1, "y": 2, "p": 0.5, "t": 1}],
            }
        },
    }
    archive = build_project_archive(project_state)
    client = TestClient(app)

    with client.websocket_connect("/ws?role=ipad&clientId=native-import-test") as websocket:
        websocket.receive_json()
        websocket.receive_json()
        response = client.post(
            "/api/project/import",
            files={"file": ("lecture.inotes", archive, "application/zip")},
        )
        assert response.status_code == 200
        message = websocket.receive_json()
        assert message["type"] == "state_refresh"
        assert message["reason"] == "project_import"
        assert "state" not in message
        assert websocket.receive_json()["type"] == "history_state"

def test_state_endpoint_supports_compressed_large_notebook():
    state["strokes"] = {
        "large": {
            "id": "large",
            "owner": "test",
            "tool": "pen",
            "color": "#111111",
            "width": 3,
            "opacity": 1,
            "smoothing": 35,
            "points": [
                {"x": index, "y": index, "p": 0.5, "t": index}
                for index in range(20_000)
            ],
        }
    }
    client = TestClient(app)
    response = client.get("/api/state", headers={"Accept-Encoding": "gzip"})
    assert response.status_code == 200
    assert response.headers.get("content-encoding") == "gzip"
    assert len(response.json()["strokes"]["large"]["points"]) == 20_000


@pytest.mark.asyncio
async def test_oversized_native_broadcast_falls_back_to_state_refresh():
    class FakeWebSocket:
        def __init__(self):
            self.messages = []

        async def send_text(self, text):
            self.messages.append(__import__("json").loads(text))

    websocket = FakeWebSocket()
    clients.add(websocket)
    client_roles[websocket] = "ipad"
    client_kinds[websocket] = "native"

    await server.broadcast({
        "type": "replace_strokes",
        "strokes": [{"id": "huge", "payload": "x" * (server.MAX_NATIVE_WS_MESSAGE_BYTES + 100)}],
    })

    assert websocket.messages == [{
        "type": "state_refresh",
        "reason": "oversized_replace_strokes",
        "serverTime": websocket.messages[0]["serverTime"],
    }]

def test_undo_and_redo_stroke():
    client = TestClient(app)
    stroke = {
        "id": "test-stroke",
        "owner": "test",
        "tool": "pen",
        "color": "#111111",
        "width": 3,
        "opacity": 1,
        "smoothing": 35,
        "strokeDetail": 80,
        "points": [{"x": 1, "y": 2, "p": 0.5, "t": 1}],
    }

    with client.websocket_connect("/ws") as websocket:
        websocket.receive_json()
        websocket.receive_json()
        websocket.send_json({"type": "stroke_begin", "stroke": stroke})
        websocket.send_json({"type": "stroke_end", "id": stroke["id"]})
        history_message = websocket.receive_json()
        assert history_message["type"] == "history_state"
        assert history_message["canUndo"] is True

        websocket.send_json({"type": "undo"})
        assert websocket.receive_json() == {"type": "delete_strokes", "ids": [stroke["id"]]}
        assert websocket.receive_json() == {"type": "history_state", "canUndo": False, "canRedo": True}

        websocket.send_json({"type": "redo"})
        restored = websocket.receive_json()
        assert restored["type"] == "restore_strokes"
        assert restored["strokes"][0]["id"] == stroke["id"]
        assert websocket.receive_json() == {"type": "history_state", "canUndo": True, "canRedo": False}


def test_fixed_pen_is_accepted():
    client = TestClient(app)
    stroke = {
        "id": "fixed-pen-stroke",
        "owner": "test",
        "tool": "fixed-pen",
        "color": "#111111",
        "width": 4,
        "opacity": 1,
        "smoothing": 35,
        "points": [{"x": 1, "y": 2, "p": 0.1, "t": 1}],
    }
    with client.websocket_connect("/ws") as websocket:
        websocket.receive_json()
        websocket.receive_json()
        websocket.send_json({"type": "stroke_begin", "stroke": stroke})
        websocket.send_json({"type": "stroke_end", "id": stroke["id"]})
        message = websocket.receive_json()
        assert message["type"] == "history_state"
        assert state["strokes"][stroke["id"]]["tool"] == "fixed-pen"


def test_stroke_detail_is_preserved_and_clamped():
    stroke = {
        "id": "detail-stroke",
        "owner": "test",
        "tool": "pen",
        "color": "#111111",
        "width": 3,
        "opacity": 1,
        "smoothing": 35,
        "strokeDetail": 140,
        "points": [{"x": 1, "y": 2, "p": 0.5, "t": 1}],
    }
    sanitized = server.sanitize_stroke(stroke)
    assert sanitized["strokeDetail"] == 100


def configure_temp_document_paths(monkeypatch, tmp_path):
    data_dir = tmp_path / "data"
    pages_dir = data_dir / "pdf_pages"
    data_dir.mkdir()
    pages_dir.mkdir()
    monkeypatch.setattr(server, "DATA_DIR", data_dir)
    monkeypatch.setattr(server, "PDF_PAGES_DIR", pages_dir)
    monkeypatch.setattr(server, "STATE_FILE", data_dir / "state.json")
    monkeypatch.setattr(server, "CURRENT_PDF", data_dir / "current.pdf")
    return data_dir, pages_dir


def build_project_archive(project_state, pdf_content=None, *, format_name=server.PROJECT_FORMAT):
    import io
    import json
    import zipfile

    output = io.BytesIO()
    manifest = {
        "format": format_name,
        "formatVersion": server.PROJECT_FORMAT_VERSION,
        "appVersion": server.APP_VERSION,
        "hasPdf": pdf_content is not None,
    }
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest))
        archive.writestr("state.json", json.dumps(project_state))
        if pdf_content is not None:
            archive.writestr("document.pdf", pdf_content)
    return output.getvalue()


def test_project_export_contains_pdf_and_strokes(monkeypatch, tmp_path):
    import io
    import json
    import zipfile

    configure_temp_document_paths(monkeypatch, tmp_path)
    server.CURRENT_PDF.write_bytes(b"example-pdf-bytes")
    state["document"] = {"filename": "lecture.pdf", "pages": []}
    state["strokes"] = {
        "stroke-1": {
            "id": "stroke-1",
            "owner": "test",
            "tool": "pen",
            "color": "#111111",
            "width": 3,
            "opacity": 1,
            "smoothing": 35,
            "strokeDetail": 80,
            "lineStyle": "solid",
            "points": [{"x": 1, "y": 2, "p": 0.5, "t": 1}],
        }
    }

    client = TestClient(app)
    response = client.get("/api/project/export")
    assert response.status_code == 200
    assert "lecture.inotes" in response.headers["content-disposition"]

    with zipfile.ZipFile(io.BytesIO(response.content), "r") as archive:
        assert set(archive.namelist()) == {"manifest.json", "state.json", "document.pdf"}
        assert json.loads(archive.read("manifest.json"))["format"] == server.PROJECT_FORMAT
        exported_state = json.loads(archive.read("state.json"))
        assert exported_state["strokes"]["stroke-1"]["strokeDetail"] == 80
        assert archive.read("document.pdf") == b"example-pdf-bytes"


def test_project_import_restores_blank_canvas_strokes(monkeypatch, tmp_path):
    configure_temp_document_paths(monkeypatch, tmp_path)
    project_state = {
        "version": 1,
        "document": {"filename": None, "pages": []},
        "strokes": {
            "restored": {
                "id": "restored",
                "owner": "backup",
                "tool": "fixed-pen",
                "color": "#222222",
                "width": 4,
                "opacity": 1,
                "smoothing": 20,
                "strokeDetail": 90,
                "lineStyle": "dashed",
                "points": [{"x": 8, "y": 9, "p": 0.1, "t": 2}],
            }
        },
    }
    archive = build_project_archive(project_state)

    client = TestClient(app)
    response = client.post(
        "/api/project/import",
        files={"file": ("backup.inotes", archive, "application/zip")},
    )
    assert response.status_code == 200
    payload = response.json()
    assert payload["strokeCount"] == 1
    assert payload["document"] == {"filename": None, "pages": []}
    assert state["strokes"]["restored"]["tool"] == "fixed-pen"
    assert state["strokes"]["restored"]["lineStyle"] == "dashed"


def test_project_import_renders_embedded_pdf(monkeypatch, tmp_path):
    import fitz

    configure_temp_document_paths(monkeypatch, tmp_path)
    document = fitz.open()
    page = document.new_page(width=300, height=400)
    page.insert_text((40, 60), "Infinite Notes import test")
    pdf_content = document.tobytes()
    document.close()

    project_state = {
        "version": 1,
        "document": {"filename": "restored.pdf", "pages": []},
        "strokes": {},
    }
    archive = build_project_archive(project_state, pdf_content)

    client = TestClient(app)
    response = client.post(
        "/api/project/import",
        files={"file": ("restored.inotes", archive, "application/zip")},
    )
    assert response.status_code == 200
    restored = client.get("/api/state").json()
    assert restored["document"]["filename"] == "restored.pdf"
    assert len(restored["document"]["pages"]) == 1
    assert server.CURRENT_PDF.read_bytes() == pdf_content
    assert (server.PDF_PAGES_DIR / "page-0001.png").exists()


def test_project_import_rejects_wrong_format(monkeypatch, tmp_path):
    configure_temp_document_paths(monkeypatch, tmp_path)
    archive = build_project_archive(
        {"version": 1, "document": {"filename": None, "pages": []}, "strokes": {}},
        format_name="some-other-format",
    )
    client = TestClient(app)
    response = client.post(
        "/api/project/import",
        files={"file": ("bad.inotes", archive, "application/zip")},
    )
    assert response.status_code == 400
    assert "not an Infinite Notes project" in response.json()["detail"]



def test_prepare_pdf_places_pages_without_gap(monkeypatch, tmp_path):
    import fitz
    import shutil

    configure_temp_document_paths(monkeypatch, tmp_path)
    document = fitz.open()
    document.new_page(width=300, height=400)
    document.new_page(width=300, height=500)
    pdf_content = document.tobytes()
    document.close()

    temp_root, pages = server.prepare_pdf(pdf_content)
    try:
        assert pages[0]["y"] == 0
        assert pages[1]["y"] == 400
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def test_old_page_gap_migration_keeps_strokes_aligned():
    value = {
        "document": {
            "filename": "old.pdf",
            "pages": [
                {"id": "page-1", "pageNumber": 1, "x": 0, "y": 0, "width": 300, "height": 400},
                {"id": "page-2", "pageNumber": 2, "x": 0, "y": 500, "width": 300, "height": 400},
            ],
        },
        "strokes": {
            "first": {"points": [{"x": 10, "y": 100}]},
            "second": {"points": [{"x": 10, "y": 550}, {"x": 20, "y": 570}]},
        },
    }

    assert server.normalize_state_page_layout(value) is True
    assert value["document"]["pages"][1]["y"] == 400
    assert value["strokes"]["first"]["points"][0]["y"] == 100
    assert value["strokes"]["second"]["points"][0]["y"] == 450
    assert value["strokes"]["second"]["points"][1]["y"] == 470
    assert server.normalize_state_page_layout(value) is False


def test_append_matching_page_preserves_strokes(monkeypatch, tmp_path):
    import fitz

    configure_temp_document_paths(monkeypatch, tmp_path)
    document = fitz.open()
    document.new_page(width=320, height=480)
    document.new_page(width=320, height=480)
    server.CURRENT_PDF.write_bytes(document.tobytes())
    document.close()

    state["document"] = {
        "filename": "notes.pdf",
        "pages": [
            {"id": "page-1", "pageNumber": 1, "imageUrl": "/old-1", "x": 0, "y": 0, "width": 320, "height": 480},
            {"id": "page-2", "pageNumber": 2, "imageUrl": "/old-2", "x": 0, "y": 480, "width": 320, "height": 480},
        ],
    }
    state["strokes"] = {
        "kept": {
            "id": "kept",
            "owner": "test",
            "tool": "pen",
            "color": "#111111",
            "width": 3,
            "opacity": 1,
            "smoothing": 35,
            "strokeDetail": 80,
            "lineStyle": "solid",
            "points": [{"x": 50, "y": 600, "p": 0.5, "t": 1}],
        }
    }

    client = TestClient(app)
    response = client.post("/api/pages/append")
    assert response.status_code == 200
    payload = response.json()
    assert payload["pageNumber"] == 3
    assert [page["y"] for page in payload["document"]["pages"]] == [0, 480, 960]
    assert payload["document"]["pages"][2]["width"] == 320
    assert payload["document"]["pages"][2]["height"] == 480
    assert state["strokes"]["kept"]["points"][0]["y"] == 600

    restored = fitz.open(server.CURRENT_PDF)
    try:
        assert restored.page_count == 3
        assert restored.load_page(2).rect.width == 320
        assert restored.load_page(2).rect.height == 480
    finally:
        restored.close()


def test_append_page_requires_pdf(monkeypatch, tmp_path):
    configure_temp_document_paths(monkeypatch, tmp_path)
    state["document"] = {"filename": None, "pages": []}
    client = TestClient(app)
    response = client.post("/api/pages/append")
    assert response.status_code == 400
    assert "Open a PDF" in response.json()["detail"]



def test_import_v12_gap_layout_reflows_strokes(monkeypatch, tmp_path):
    import fitz

    configure_temp_document_paths(monkeypatch, tmp_path)
    document = fitz.open()
    document.new_page(width=300, height=400)
    document.new_page(width=300, height=400)
    pdf_content = document.tobytes()
    document.close()

    project_state = {
        "version": 1,
        "document": {
            "filename": "v12-notes.pdf",
            "pages": [
                {"id": "page-1", "pageNumber": 1, "x": 0, "y": 0, "width": 300, "height": 400},
                {"id": "page-2", "pageNumber": 2, "x": 0, "y": 500, "width": 300, "height": 400},
            ],
        },
        "strokes": {
            "page-two-ink": {
                "id": "page-two-ink",
                "owner": "backup",
                "tool": "pen",
                "color": "#111111",
                "width": 3,
                "opacity": 1,
                "smoothing": 35,
                "strokeDetail": 80,
                "lineStyle": "solid",
                "points": [{"x": 20, "y": 550, "p": 0.5, "t": 1}],
            }
        },
    }
    archive = build_project_archive(project_state, pdf_content)
    client = TestClient(app)
    response = client.post(
        "/api/project/import",
        files={"file": ("v12.inotes", archive, "application/zip")},
    )
    assert response.status_code == 200
    restored = client.get("/api/state").json()
    assert restored["document"]["pages"][1]["y"] == 400
    assert restored["strokes"]["page-two-ink"]["points"][0]["y"] == 450


def test_selector_add_replace_is_undoable():
    client = TestClient(app)
    stroke = {
        "id": "selected-stroke",
        "owner": "test",
        "tool": "pen",
        "color": "#111111",
        "width": 3,
        "opacity": 1,
        "smoothing": 35,
        "strokeDetail": 80,
        "lineStyle": "solid",
        "points": [
            {"x": 10, "y": 20, "p": 0.5, "t": 1},
            {"x": 30, "y": 40, "p": 0.5, "t": 2},
        ],
    }
    moved = copy.deepcopy(stroke)
    for point in moved["points"]:
        point["x"] += 50
        point["y"] += 25

    with client.websocket_connect("/ws") as websocket:
        websocket.receive_json()
        websocket.receive_json()

        websocket.send_json({"type": "add_strokes", "strokes": [stroke]})
        assert websocket.receive_json() == {
            "type": "history_state",
            "canUndo": True,
            "canRedo": False,
        }
        assert state["strokes"][stroke["id"]]["points"][0]["x"] == 10

        websocket.send_json({"type": "replace_strokes", "strokes": [moved]})
        assert websocket.receive_json() == {
            "type": "history_state",
            "canUndo": True,
            "canRedo": False,
        }
        assert state["strokes"][stroke["id"]]["points"][0]["x"] == 60

        websocket.send_json({"type": "undo"})
        replacement = websocket.receive_json()
        assert replacement["type"] == "replace_strokes"
        assert replacement["strokes"][0]["points"][0]["x"] == 10
        assert websocket.receive_json() == {
            "type": "history_state",
            "canUndo": True,
            "canRedo": True,
        }

        websocket.send_json({"type": "redo"})
        replacement = websocket.receive_json()
        assert replacement["type"] == "replace_strokes"
        assert replacement["strokes"][0]["points"][0]["x"] == 60
        assert websocket.receive_json() == {
            "type": "history_state",
            "canUndo": True,
            "canRedo": False,
        }


def test_pdf_export_warns_and_expands_for_out_of_bounds_ink(monkeypatch, tmp_path):
    import fitz

    configure_temp_document_paths(monkeypatch, tmp_path)
    source = fitz.open()
    page = source.new_page(width=200, height=300)
    page.insert_text((20, 30), "Homework source")
    server.CURRENT_PDF.write_bytes(source.tobytes())
    source.close()

    state["document"] = {
        "filename": "homework.pdf",
        "pages": [
            {
                "id": "page-1",
                "pageNumber": 1,
                "imageUrl": "/pdf-pages/page-0001.png",
                "x": 0,
                "y": 0,
                "width": 200,
                "height": 300,
            }
        ],
    }
    state["strokes"] = {
        "overflow": {
            "id": "overflow",
            "owner": "test",
            "tool": "fixed-pen",
            "color": "#111111",
            "width": 8,
            "opacity": 1,
            "smoothing": 0,
            "strokeDetail": 80,
            "lineStyle": "solid",
            "points": [
                {"x": 190, "y": 100, "p": 0.5, "t": 1},
                {"x": 235, "y": 100, "p": 0.5, "t": 2},
            ],
        }
    }

    client = TestClient(app)
    info_response = client.get("/api/pdf/export-info")
    assert info_response.status_code == 200
    info = info_response.json()
    assert info["hasOverflow"] is True
    assert info["pages"][0]["overflow"] is True
    assert info["pages"][0]["newWidth"] > 239
    assert info["pages"][0]["newHeight"] == 300

    export_response = client.get("/api/pdf/export")
    assert export_response.status_code == 200
    assert "homework-notes.pdf" in export_response.headers["content-disposition"]

    exported = fitz.open(stream=export_response.content, filetype="pdf")
    try:
        assert exported.page_count == 1
        exported_page = exported.load_page(0)
        assert exported_page.rect.width == pytest.approx(info["pages"][0]["newWidth"], abs=0.1)
        assert exported_page.rect.height == pytest.approx(300, abs=0.1)
        assert "Homework source" in exported_page.get_text()
        pixmap = exported_page.get_pixmap(matrix=fitz.Matrix(1, 1), alpha=False)
        # The exported ink remains visible in the newly added area to the right
        # of the original 200-point page boundary.
        sample_x = min(pixmap.width - 1, 225)
        sample_y = min(pixmap.height - 1, 100)
        offset = (sample_y * pixmap.width + sample_x) * pixmap.n
        pixel = pixmap.samples[offset:offset + 3]
        assert tuple(pixel) != (255, 255, 255)
    finally:
        exported.close()


def test_pdf_export_keeps_default_size_when_ink_is_inside(monkeypatch, tmp_path):
    import fitz

    configure_temp_document_paths(monkeypatch, tmp_path)
    source = fitz.open()
    source.new_page(width=612, height=792)
    server.CURRENT_PDF.write_bytes(source.tobytes())
    source.close()

    state["document"] = {
        "filename": "letter.pdf",
        "pages": [
            {
                "id": "page-1",
                "pageNumber": 1,
                "imageUrl": "/pdf-pages/page-0001.png",
                "x": 0,
                "y": 0,
                "width": 612,
                "height": 792,
            }
        ],
    }
    state["strokes"] = {
        "inside": {
            "id": "inside",
            "owner": "test",
            "tool": "highlighter",
            "color": "#ffff00",
            "width": 18,
            "opacity": 0.28,
            "smoothing": 0,
            "strokeDetail": 80,
            "lineStyle": "solid",
            "points": [
                {"x": 100, "y": 100, "p": 0.5, "t": 1},
                {"x": 200, "y": 100, "p": 0.5, "t": 2},
            ],
        }
    }

    client = TestClient(app)
    info = client.get("/api/pdf/export-info").json()
    assert info["hasOverflow"] is False
    assert info["pages"][0]["newWidth"] == 612
    assert info["pages"][0]["newHeight"] == 792



def test_sync_request_returns_the_server_snapshot_without_full_state_push():
    client = TestClient(app)
    stroke = {
        "id": "sync-stroke",
        "owner": "test",
        "tool": "pen",
        "color": "#111111",
        "width": 3,
        "opacity": 1,
        "smoothing": 35,
        "strokeDetail": 80,
        "lineStyle": "solid",
        "points": [{"x": 1, "y": 2, "p": 0.5, "t": 1}],
    }
    state["strokes"] = {stroke["id"]: copy.deepcopy(stroke)}
    history.append({"type": "add", "strokes": [copy.deepcopy(stroke)]})

    with client.websocket_connect("/ws?role=ipad") as ipad:
        ipad.receive_json()
        ipad.receive_json()
        ipad.send_json({"type": "sync_request", "clientTime": 123})
        snapshot = ipad.receive_json()
        assert snapshot["type"] == "snapshot"
        assert snapshot["reason"] == "manual_sync"
        assert snapshot["state"]["strokes"][stroke["id"]]["id"] == stroke["id"]
        assert ipad.receive_json() == {"type": "history_state", "canUndo": True, "canRedo": False}

    assert len(history) == 1


def test_full_ipad_state_push_is_no_longer_supported():
    client = TestClient(app)
    with client.websocket_connect("/ws?role=ipad") as ipad:
        ipad.receive_json()
        ipad.receive_json()
        ipad.send_json({"type": "ipad_state_push", "strokes": {}})
        error = ipad.receive_json()
        assert error["type"] == "error"
        assert error["message"] == "Unknown message type"


def test_delete_is_acknowledged_even_when_retried():
    client = TestClient(app)
    stroke = {
        "id": "erase-me",
        "owner": "test",
        "tool": "pen",
        "color": "#111111",
        "width": 3,
        "opacity": 1,
        "smoothing": 35,
        "strokeDetail": 80,
        "lineStyle": "solid",
        "points": [{"x": 1, "y": 2, "p": 0.5, "t": 1}],
    }
    state["strokes"] = {stroke["id"]: copy.deepcopy(stroke)}
    with client.websocket_connect("/ws") as websocket:
        websocket.receive_json()
        websocket.receive_json()
        websocket.send_json({"type": "delete_strokes", "ids": [stroke["id"]], "reliable": True})
        assert websocket.receive_json() == {"type": "delete_ack", "ids": [stroke["id"]], "final": True}
        assert stroke["id"] not in state["strokes"]
        history_message = websocket.receive_json()
        assert history_message["type"] == "history_state"

        websocket.send_json({"type": "delete_strokes", "ids": [stroke["id"]], "reliable": True})
        assert websocket.receive_json() == {"type": "delete_ack", "ids": [stroke["id"]], "final": True}


def test_rapid_eraser_batches_form_one_reliable_history_action():
    client = TestClient(app)
    strokes = {}
    for index in range(3):
        stroke_id = f"erase-{index}"
        strokes[stroke_id] = {
            "id": stroke_id,
            "owner": "ipad",
            "tool": "pen",
            "color": "#111111",
            "width": 3,
            "opacity": 1,
            "smoothing": 35,
            "strokeDetail": 80,
            "lineStyle": "solid",
            "points": [{"x": index, "y": 2, "p": 0.5, "t": index}],
        }
    state["strokes"] = copy.deepcopy(strokes)

    with client.websocket_connect("/ws?role=ipad") as ipad:
        ipad.receive_json()
        ipad.receive_json()
        ipad.send_json({
            "type": "delete_strokes",
            "operationId": "erase-gesture-1",
            "ids": ["erase-0", "erase-1"],
            "final": False,
            "reliable": True,
        })
        assert ipad.receive_json() == {
            "type": "delete_ack",
            "operationId": "erase-gesture-1",
            "ids": ["erase-0", "erase-1"],
            "final": False,
        }
        assert history == []

        ipad.send_json({
            "type": "delete_strokes",
            "operationId": "erase-gesture-1",
            "ids": ["erase-2"],
            "final": False,
            "reliable": True,
        })
        assert ipad.receive_json() == {
            "type": "delete_ack",
            "operationId": "erase-gesture-1",
            "ids": ["erase-2"],
            "final": False,
        }
        assert history == []

        # The fast batches can all be acknowledged before Pencil-up. The final
        # empty message must still commit one grouped undo action.
        ipad.send_json({
            "type": "delete_strokes",
            "operationId": "erase-gesture-1",
            "ids": [],
            "final": True,
            "reliable": True,
        })
        assert ipad.receive_json() == {
            "type": "delete_ack",
            "operationId": "erase-gesture-1",
            "ids": [],
            "final": True,
        }
        assert ipad.receive_json() == {"type": "history_state", "canUndo": True, "canRedo": False}

    assert state["strokes"] == {}
    assert len(history) == 1
    assert history[0]["type"] == "delete"
    assert {stroke["id"] for stroke in history[0]["strokes"]} == set(strokes)


def test_snapshot_marks_in_progress_strokes_live():
    client = TestClient(app)
    stroke = {
        "id": "live-stroke",
        "owner": "test",
        "tool": "pen",
        "color": "#111111",
        "width": 3,
        "opacity": 1,
        "smoothing": 35,
        "strokeDetail": 80,
        "lineStyle": "solid",
        "points": [{"x": 1, "y": 2, "p": 0.5, "t": 1}],
    }
    with client.websocket_connect("/ws") as writer:
        writer.receive_json()
        writer.receive_json()
        writer.send_json({"type": "stroke_begin", "stroke": stroke})
        with client.websocket_connect("/ws") as reader:
            snapshot = reader.receive_json()
            assert snapshot["type"] == "snapshot"
            assert stroke["id"] in snapshot["liveStrokeIds"]
            reader.receive_json()
        writer.send_json({"type": "stroke_end", "id": stroke["id"]})
        writer.receive_json()


def test_delete_broadcast_reaches_other_connected_client():
    client = TestClient(app)
    stroke = {
        "id": "broadcast-erase",
        "owner": "ipad",
        "tool": "highlighter",
        "color": "#ffff00",
        "width": 20,
        "opacity": 0.28,
        "smoothing": 35,
        "strokeDetail": 80,
        "lineStyle": "solid",
        "points": [{"x": 4, "y": 5, "p": 0.5, "t": 1}],
    }
    state["strokes"] = {stroke["id"]: copy.deepcopy(stroke)}
    with client.websocket_connect("/ws") as ipad, client.websocket_connect("/ws") as laptop:
        ipad.receive_json()
        ipad.receive_json()
        laptop.receive_json()
        laptop.receive_json()

        ipad.send_json({"type": "delete_strokes", "ids": [stroke["id"]], "reliable": True})
        assert laptop.receive_json() == {"type": "delete_strokes", "ids": [stroke["id"]]}
        assert ipad.receive_json() == {"type": "delete_ack", "ids": [stroke["id"]], "final": True}
        assert laptop.receive_json()["type"] == "history_state"
        assert ipad.receive_json()["type"] == "history_state"


def test_static_renderer_uses_single_continuous_capsule_path():
    source = (Path(__file__).resolve().parents[1] / "static" / "app.js").read_text()
    assert "Build one continuous capsule path" in source
    assert "arc(first.x" not in source
    assert "arc(last.x" not in source
    assert "front.x - lastNormal.x" in source


def test_pointerover_recovery_is_merged_into_pointerdown():
    source = (Path(__file__).resolve().parents[1] / "static" / "app.js").read_text()
    assert 'state.activeInputSource === "recovered-pointer"' in source
    assert "MERGE recovered pointerover into pointerdown" in source


def make_text_stroke(stroke_id="text-1", *, text="Typed homework note", x=40, y=50, width=180, height=80):
    return {
        "id": stroke_id,
        "owner": "test",
        "tool": "text",
        "color": "#1a2b3c",
        "width": 18,
        "opacity": 1,
        "smoothing": 0,
        "strokeDetail": 100,
        "lineStyle": "solid",
        "text": text,
        "textAlign": "left",
        "fontFamily": "sans-serif",
        "points": [
            {"x": x, "y": y, "p": 0.5, "t": 1},
            {"x": x + width, "y": y, "p": 0.5, "t": 1},
            {"x": x + width, "y": y + height, "p": 0.5, "t": 1},
            {"x": x, "y": y + height, "p": 0.5, "t": 1},
        ],
    }


def test_text_box_is_sanitized_and_preserves_formatting():
    sanitized = server.sanitize_stroke(make_text_stroke())
    assert sanitized["tool"] == "text"
    assert sanitized["text"] == "Typed homework note"
    assert sanitized["textAlign"] == "left"
    assert sanitized["fontFamily"] == "sans-serif"
    assert len(sanitized["points"]) == 4


def test_text_box_add_edit_and_undo_over_websocket():
    client = TestClient(app)
    original = make_text_stroke()
    edited = copy.deepcopy(original)
    edited["text"] = "Edited text"
    edited["textAlign"] = "center"

    with client.websocket_connect("/ws") as websocket:
        websocket.receive_json()
        websocket.receive_json()
        websocket.send_json({"type": "add_strokes", "strokes": [original]})
        assert websocket.receive_json() == {"type": "history_state", "canUndo": True, "canRedo": False}
        assert state["strokes"][original["id"]]["text"] == "Typed homework note"

        websocket.send_json({"type": "replace_strokes", "strokes": [edited]})
        assert websocket.receive_json() == {"type": "history_state", "canUndo": True, "canRedo": False}
        assert state["strokes"][original["id"]]["text"] == "Edited text"

        websocket.send_json({"type": "undo"})
        replacement = websocket.receive_json()
        assert replacement["type"] == "replace_strokes"
        assert replacement["strokes"][0]["text"] == "Typed homework note"
        assert websocket.receive_json()["type"] == "history_state"


def test_project_round_trip_preserves_text_boxes(monkeypatch, tmp_path):
    import json
    import zipfile
    import io

    configure_temp_document_paths(monkeypatch, tmp_path)
    state["document"] = {"filename": None, "pages": []}
    text_stroke = make_text_stroke()
    state["strokes"] = {text_stroke["id"]: copy.deepcopy(text_stroke)}

    export_response = TestClient(app).get("/api/project/export")
    assert export_response.status_code == 200
    with zipfile.ZipFile(io.BytesIO(export_response.content)) as archive:
        exported = json.loads(archive.read("state.json"))
    assert exported["strokes"][text_stroke["id"]]["text"] == text_stroke["text"]

    state["strokes"] = {}
    import_response = TestClient(app).post(
        "/api/project/import",
        files={"file": ("notes.inotes", export_response.content, "application/zip")},
    )
    assert import_response.status_code == 200
    assert state["strokes"][text_stroke["id"]]["text"] == text_stroke["text"]


def test_pdf_export_flattens_text_box(monkeypatch, tmp_path):
    import fitz

    configure_temp_document_paths(monkeypatch, tmp_path)
    source = fitz.open()
    page = source.new_page(width=300, height=300)
    page.insert_text((30, 30), "Original PDF", fontsize=12)
    source.save(server.CURRENT_PDF)
    source.close()

    state["document"] = {
        "filename": "homework.pdf",
        "pages": [{
            "id": "page-1",
            "pageNumber": 1,
            "x": 0,
            "y": 0,
            "width": 300,
            "height": 300,
            "imageUrl": "/pdf-pages/page-1.png",
        }],
    }
    text_stroke = make_text_stroke(text="Typed answer")
    state["strokes"] = {text_stroke["id"]: text_stroke}

    response = TestClient(app).get("/api/pdf/export")
    assert response.status_code == 200
    exported = fitz.open(stream=response.content, filetype="pdf")
    try:
        page_text = exported.load_page(0).get_text()
        assert "Original PDF" in page_text
        assert "Typed answer" in page_text
    finally:
        exported.close()


def shape_stroke(shape_type, points, stroke_id="shape-1"):
    return {
        "id": stroke_id,
        "owner": "test",
        "tool": "shape",
        "shapeType": shape_type,
        "color": "#123456",
        "width": 2.5,
        "opacity": 1,
        "smoothing": 0,
        "strokeDetail": 100,
        "lineStyle": "solid",
        "points": [dict(point, p=0.5, t=index) for index, point in enumerate(points)],
    }


def test_geometry_shapes_are_sanitized_with_expected_point_counts():
    rectangle = shape_stroke("rectangle", [
        {"x": 0, "y": 0}, {"x": 100, "y": 0},
        {"x": 100, "y": 60}, {"x": 0, "y": 60},
    ])
    line = shape_stroke("line", [{"x": 0, "y": 0}, {"x": 80, "y": 20}], "line-1")
    curve = shape_stroke("curve", [
        {"x": 0, "y": 0}, {"x": 40, "y": -30}, {"x": 80, "y": 0},
    ], "curve-1")
    assert server.sanitize_stroke(rectangle)["shapeType"] == "rectangle"
    assert len(server.sanitize_stroke(line)["points"]) == 2
    assert len(server.sanitize_stroke(curve)["points"]) == 3

    invalid = shape_stroke("circle", [{"x": 0, "y": 0}, {"x": 10, "y": 10}], "bad-circle")
    with pytest.raises(ValueError, match="shape point count"):
        server.sanitize_stroke(invalid)


def test_stroke_end_can_replace_streamed_ink_with_recognized_line():
    client = TestClient(app)
    ink = {
        "id": "recognized-line",
        "owner": "test",
        "tool": "pen",
        "color": "#111111",
        "width": 3,
        "opacity": 1,
        "smoothing": 35,
        "strokeDetail": 80,
        "lineStyle": "solid",
        "points": [{"x": 0, "y": 0, "p": 0.5, "t": 1}],
    }
    final_line = shape_stroke(
        "line",
        [{"x": 0, "y": 0}, {"x": 120, "y": 1}],
        "recognized-line",
    )
    final_line["recognitionSource"] = "pen"
    final_line["recognitionError"] = 0.8

    with client.websocket_connect("/ws") as websocket:
        websocket.receive_json()
        websocket.receive_json()
        websocket.send_json({"type": "stroke_begin", "stroke": ink})
        websocket.send_json({"type": "stroke_points", "id": ink["id"], "points": [
            {"x": 60, "y": 1, "p": 0.5, "t": 2},
            {"x": 120, "y": 1, "p": 0.5, "t": 3},
        ]})
        websocket.send_json({"type": "stroke_end", "id": ink["id"], "stroke": final_line})
        history_message = websocket.receive_json()
        assert history_message == {"type": "history_state", "canUndo": True, "canRedo": False}

    saved = state["strokes"][ink["id"]]
    assert saved["tool"] == "shape"
    assert saved["shapeType"] == "line"
    assert len(saved["points"]) == 2
    assert history[-1]["strokes"][0]["shapeType"] == "line"


def test_shape_pdf_drawing_supports_plane_line_curve_and_ellipse():
    import fitz

    document = fitz.open()
    page = document.new_page(width=300, height=400)
    source_page = {"x": 0, "y": 0, "width": 300, "height": 400}
    shapes = [
        shape_stroke("xy-plane", [
            {"x": 20, "y": 30}, {"x": 220, "y": 30},
            {"x": 220, "y": 180}, {"x": 20, "y": 180},
        ], "plane"),
        shape_stroke("line", [{"x": 30, "y": 210}, {"x": 250, "y": 210}], "line"),
        shape_stroke("curve", [
            {"x": 30, "y": 250}, {"x": 140, "y": 190}, {"x": 250, "y": 250},
        ], "curve"),
        shape_stroke("ellipse", [
            {"x": 60, "y": 280}, {"x": 220, "y": 280},
            {"x": 220, "y": 360}, {"x": 60, "y": 360},
        ], "ellipse"),
    ]
    for stroke in shapes:
        server.draw_shape_on_pdf_page(page, stroke, source_page, 0, 0)
    output = document.tobytes()
    document.close()
    assert output.startswith(b"%PDF")
    assert len(output) > 1000


def test_locked_xy_plane_is_sanitized_and_exported_on_background_layer():
    plane = shape_stroke("xy-plane", [
        {"x": 20, "y": 30}, {"x": 220, "y": 30},
        {"x": 220, "y": 180}, {"x": 20, "y": 180},
    ], "locked-plane")
    plane["locked"] = True
    line = shape_stroke("line", [{"x": 30, "y": 210}, {"x": 250, "y": 210}], "front-line")
    sanitized = server.sanitize_stroke(plane)
    assert sanitized["locked"] is True

    snapshot = {
        "document": {"pages": [{"id": "p1", "pageNumber": 1, "x": 0, "y": 0, "width": 300, "height": 400}]},
        "strokes": {line["id"]: line, plane["id"]: plane},
    }
    layouts = server.build_pdf_export_layout(snapshot)
    assert layouts[0]["strokes"][0]["id"] == "locked-plane"


def test_lock_flag_is_preserved_for_every_item_type():
    rectangle = shape_stroke("rectangle", [
        {"x": 0, "y": 0}, {"x": 100, "y": 0},
        {"x": 100, "y": 60}, {"x": 0, "y": 60},
    ], "locked-rectangle")
    rectangle["locked"] = True
    line = shape_stroke("line", [
        {"x": 0, "y": 0}, {"x": 100, "y": 20},
    ], "locked-line")
    line["locked"] = True
    assert server.sanitize_stroke(rectangle)["locked"] is True
    assert server.sanitize_stroke(line)["locked"] is True


def test_lock_flag_is_preserved_for_ink_and_text():
    pen = {
        "id": "locked-pen", "owner": "test", "tool": "pen",
        "color": "#111111", "width": 3, "opacity": 1,
        "smoothing": 35, "strokeDetail": 80, "lineStyle": "solid",
        "locked": True,
        "points": [{"x": 10, "y": 10, "p": 0.5, "t": 1}, {"x": 20, "y": 20, "p": 0.5, "t": 2}],
    }
    text = {
        "id": "locked-text", "owner": "test", "tool": "text",
        "color": "#111111", "width": 3, "opacity": 1,
        "smoothing": 0, "strokeDetail": 100, "lineStyle": "solid",
        "locked": True, "text": "locked", "textAlign": "left", "fontFamily": "sans-serif",
        "points": [
            {"x": 0, "y": 0, "p": 0.5, "t": 1}, {"x": 100, "y": 0, "p": 0.5, "t": 1},
            {"x": 100, "y": 40, "p": 0.5, "t": 1}, {"x": 0, "y": 40, "p": 0.5, "t": 1},
        ],
    }
    assert server.sanitize_stroke(pen)["locked"] is True
    assert server.sanitize_stroke(text)["locked"] is True
