import copy
import asyncio
import json
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest
from fastapi.testclient import TestClient

import server
from server import app, client_kinds, client_roles, clients, history, pending_delete_operations, pending_stroke_history, redo_history, state


@pytest.fixture(autouse=True)
def isolated_state(monkeypatch, tmp_path):
    state_backup = copy.deepcopy(state)
    history_backup = copy.deepcopy(history)
    redo_backup = copy.deepcopy(redo_history)
    pending_backup = set(pending_stroke_history)
    client_roles.clear()
    client_kinds.clear()
    clients.clear()
    pending_delete_operations.clear()
    state["strokes"] = {}
    server.state_revision = 0
    server.persistence_failed = False
    server.stored_metadata = {key: copy.deepcopy(value) for key, value in state.items() if key != "strokes"}
    store = server.NotebookStore(tmp_path / "notebook.sqlite3")
    store.initialize(copy.deepcopy(state))
    monkeypatch.setattr(server, "notebook_store", store)
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
    store.close()


def test_root_and_state():
    client = TestClient(app)
    assert client.get("/").status_code == 200
    response = client.get("/api/state")
    assert response.status_code == 200
    assert "document" in response.json()
    assert "strokes" in response.json()
    assert int(response.headers["x-infinite-notes-state-bytes"]) == len(response.content)
    assert int(response.headers["x-infinite-notes-page-count"]) == len(response.json()["document"]["pages"])
    assert int(response.headers["x-infinite-notes-ink-count"]) == len(response.json()["strokes"])


def test_state_progress_headers_survive_gzip(monkeypatch, tmp_path):
    source_pdf = tmp_path / "source.pdf"
    source_pdf.write_bytes(b"%PDF-test")
    monkeypatch.setattr(server, "CURRENT_PDF", source_pdf)
    for index in range(200):
        state["strokes"][f"ink-{index}"] = {"id": f"ink-{index}", "points": [{"x": index, "y": 2}]}
    response = TestClient(app).get("/api/state", headers={"Accept-Encoding": "gzip"})
    assert response.status_code == 200
    assert int(response.headers["x-infinite-notes-state-bytes"]) == len(response.content)
    assert int(response.headers["x-infinite-notes-ink-count"]) == 200
    assert int(response.headers["x-infinite-notes-source-pdf-bytes"]) == len(b"%PDF-test")


def test_http_state_does_not_advertise_uncommitted_live_stroke():
    state["strokes"]["still-drawing"] = {"id": "still-drawing", "points": []}
    pending_stroke_history.add("still-drawing")
    response = TestClient(app).get("/api/state")
    assert response.status_code == 200
    assert "still-drawing" not in response.json()["strokes"]
    assert "still-drawing" in state["strokes"]


def test_repeated_identical_stroke_does_not_commit_or_advance_revision(monkeypatch):
    calls = []
    original_commit = server.notebook_store.commit_batch

    def count_commit(operations):
        calls.append(len(operations))
        return original_commit(operations)

    monkeypatch.setattr(server.notebook_store, "commit_batch", count_commit)
    state["strokes"]["same"] = {"id": "same", "points": [{"x": 1, "y": 2}]}

    async def exercise():
        first = await server.save_state_atomic(upsert_ids={"same"})
        second = await server.save_state_atomic(upsert_ids={"same"})
        return first, second

    assert asyncio.run(exercise()) == (1, 1)
    assert calls == [1]
    assert server.notebook_store.load()["documentRevision"] == 1


def test_explicit_mutation_flushes_without_waiting_for_long_stroke_window(monkeypatch):
    monkeypatch.setattr(server, "BATCH_MAX_DELAY_SECONDS", 30.0)
    state["strokes"]["immediate"] = {"id": "immediate", "points": []}

    async def exercise():
        return await asyncio.wait_for(
            server.save_state_atomic(upsert_ids={"immediate"}), timeout=1.0
        )

    assert asyncio.run(exercise()) == 1
    assert "immediate" in server.notebook_store.load()["strokes"]


@pytest.mark.parametrize("fail_commit", [False, True])
def test_identical_edit_waits_for_inflight_commit(monkeypatch, fail_commit):
    monkeypatch.setattr(server, "BATCH_MAX_DELAY_SECONDS", 30.0)
    started = threading.Event()
    release = threading.Event()
    original = server.notebook_store.commit_batch

    def held_commit(operations):
        started.set()
        assert release.wait(5)
        if fail_commit:
            raise OSError("held commit failed")
        original(operations)

    monkeypatch.setattr(server.notebook_store, "commit_batch", held_commit)

    async def exercise():
        writer = server.notebook_writer()
        state["strokes"]["duplicate"] = {"id": "duplicate", "points": []}
        first = writer.enqueue(upsert_ids={"duplicate"})
        flushing = asyncio.create_task(writer.flush())
        try:
            assert await asyncio.to_thread(started.wait, 2)
            duplicate = writer.enqueue(upsert_ids={"duplicate"})
            acknowledged_early = duplicate.done()
        finally:
            release.set()
            await flushing
        outcomes = await asyncio.gather(first, duplicate, return_exceptions=True)
        await writer.shutdown()
        assert not acknowledged_early, "duplicate was acknowledged before its data committed"
        if fail_commit:
            assert all(isinstance(outcome, OSError) for outcome in outcomes)
        else:
            assert outcomes == [1, 1]

    asyncio.run(exercise())


def test_cancelled_waiter_does_not_break_other_commit_completions(monkeypatch):
    monkeypatch.setattr(server, "BATCH_MAX_DELAY_SECONDS", 30.0)

    async def exercise():
        writer = server.notebook_writer()
        state["strokes"]["a"] = {"id": "a", "points": []}
        abandoned = writer.enqueue(upsert_ids={"a"})
        duplicate = writer.enqueue(upsert_ids={"a"})
        state["strokes"]["b"] = {"id": "b", "points": []}
        other = writer.enqueue(upsert_ids={"b"})
        abandoned.cancel()
        try:
            await writer.flush()
            assert await asyncio.wait_for(duplicate, 1) == 1
            assert await asyncio.wait_for(other, 1) == 2
            assert set(server.notebook_store.load()["strokes"]) == {"a", "b"}
        finally:
            await writer.shutdown()

    asyncio.run(exercise())


def test_cancelled_flush_keeps_durable_state_and_memory_in_agreement(monkeypatch):
    monkeypatch.setattr(server, "BATCH_MAX_DELAY_SECONDS", 30.0)
    started = threading.Event()
    release = threading.Event()
    original = server.notebook_store.commit_batch

    def held_commit(operations):
        started.set()
        assert release.wait(5)
        original(operations)

    monkeypatch.setattr(server.notebook_store, "commit_batch", held_commit)

    async def exercise():
        writer = server.notebook_writer()
        state["strokes"]["a"] = {"id": "a", "points": []}
        committed = writer.enqueue(upsert_ids={"a"})
        request = asyncio.create_task(writer.flush())
        try:
            assert await asyncio.to_thread(started.wait, 2)
            request.cancel()
            with pytest.raises(asyncio.CancelledError):
                await request
        finally:
            release.set()
        try:
            assert await asyncio.wait_for(committed, 1) == 1
            assert server.current_document_revision() == 1
            assert server.notebook_store.load()["documentRevision"] == 1
        finally:
            await writer.shutdown()

    asyncio.run(exercise())


def test_batch_deadline_starts_with_first_edit_and_idle_does_not_commit(monkeypatch):
    monkeypatch.setattr(server, "BATCH_MAX_DELAY_SECONDS", 5.0)
    calls = []
    original_commit = server.notebook_store.commit_batch

    def count_commit(operations):
        calls.append(len(operations))
        return original_commit(operations)

    monkeypatch.setattr(server.notebook_store, "commit_batch", count_commit)

    async def exercise():
        writer = server.notebook_writer()
        state["strokes"]["a"] = {"id": "a", "points": []}
        first = writer.enqueue(upsert_ids={"a"})
        deadline = writer.timer
        state["strokes"]["b"] = {"id": "b", "points": []}
        second = writer.enqueue(upsert_ids={"b"})
        assert writer.timer is deadline
        await writer.flush()
        assert await first == 1
        assert await second == 2
        await asyncio.sleep(0)
        assert writer.timer is None

    asyncio.run(exercise())
    assert calls == [2]


def test_large_wal_checkpoint_runs_off_the_event_loop(monkeypatch):
    monkeypatch.setattr(server, "WAL_CHECKPOINT_MIN_BYTES", 1)
    monkeypatch.setattr(server, "BATCH_MAX_DELAY_SECONDS", 0.0)
    called = []
    original_checkpoint = server.notebook_store.checkpoint

    def record_checkpoint():
        called.append(threading.current_thread().name)
        return original_checkpoint()

    monkeypatch.setattr(server.notebook_store, "checkpoint", record_checkpoint)
    state["strokes"]["checkpoint"] = {"id": "checkpoint", "points": []}

    async def exercise():
        await server.save_state_atomic(upsert_ids={"checkpoint"})
        task = server.notebook_writer().checkpoint_task
        assert task is not None
        await task

    asyncio.run(exercise())
    assert called and called[0].startswith("notebook-writer")


def test_graceful_shutdown_drains_accepted_edit(monkeypatch):
    monkeypatch.setattr(server, "BATCH_MAX_DELAY_SECONDS", 30.0)
    with TestClient(app) as client:
        async def enqueue_without_waiting():
            state["strokes"]["shutdown-stroke"] = {"id": "shutdown-stroke", "points": []}
            server.notebook_writer().enqueue(upsert_ids={"shutdown-stroke"})

        assert client.portal is not None
        client.portal.call(enqueue_without_waiting)
        assert "shutdown-stroke" not in server.notebook_store.load()["strokes"]
    assert "shutdown-stroke" in server.notebook_store.load()["strokes"]


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
        "documentId": server.current_document_id(),
        "documentRevision": server.current_document_revision(),
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
    from urllib.parse import urlsplit
    preview = server.PDF_PAGES_DIR / Path(urlsplit(restored["document"]["pages"][0]["imageUrl"]).path).name
    assert preview.exists()
    assert "<svg" in preview.read_text(encoding="utf-8")[:1000]
    assert not (server.PDF_PAGES_DIR / "page-0001.png").exists()
    assert restored["document"]["pages"][0]["imageUrl"].split("?", 1)[0].endswith("/" + preview.name)


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


def test_insert_copy_duplicates_pdf_page_but_not_ink(monkeypatch, tmp_path):
    import fitz

    configure_temp_document_paths(monkeypatch, tmp_path)
    document = fitz.open()
    first = document.new_page(width=320, height=480)
    first.insert_text((30, 40), "Printed PDF content")
    document.new_page(width=400, height=500)
    server.CURRENT_PDF.write_bytes(document.tobytes())
    document.close()
    state["document"] = {"filename": "notes.pdf", "pages": [
        {"id": "page-1", "pageNumber": 1, "x": 0, "y": 0, "width": 320, "height": 480},
        {"id": "page-2", "pageNumber": 2, "x": 0, "y": 480, "width": 400, "height": 500},
    ]}
    state["strokes"] = {"ink": {"id": "ink", "points": [{"x": 40, "y": 50}]}}

    response = TestClient(app).post("/api/pages/insert?afterPageNumber=1&kind=copy")
    assert response.status_code == 200, response.text
    assert response.json()["pageNumber"] == 2
    assert len(state["strokes"]) == 1
    assert state["strokes"]["ink"]["points"][0]["y"] == 50
    result = fitz.open(server.CURRENT_PDF)
    try:
        assert result.page_count == 3
        assert "Printed PDF content" in result[0].get_text()
        assert "Printed PDF content" in result[1].get_text()
        assert result[1].rect == result[0].rect
    finally:
        result.close()


def test_insert_template_uses_current_page_size_and_vector_lines(monkeypatch, tmp_path):
    import fitz
    from page_templates import save_preset

    configure_temp_document_paths(monkeypatch, tmp_path)
    document = fitz.open()
    document.new_page(width=317, height=499)
    server.CURRENT_PDF.write_bytes(document.tobytes())
    document.close()
    state["document"] = {"filename": "notes.pdf", "pages": [
        {"id": "page-1", "pageNumber": 1, "x": 0, "y": 0, "width": 317, "height": 499},
    ]}
    save_preset({"id": "science", "name": "Science grid", "style": "eng"}, server.DATA_DIR)
    client = TestClient(app)
    listed = client.get("/api/page-templates")
    assert listed.status_code == 200
    assert any(item["id"] == "science" for item in listed.json()["presets"])
    response = client.post("/api/pages/insert?afterPageNumber=1&kind=template&presetId=science")
    assert response.status_code == 200, response.text
    result = fitz.open(server.CURRENT_PDF)
    try:
        page = result[1]
        assert page.rect.width == 317
        assert page.rect.height == 499
        assert page.get_images(full=True) == []
        assert page.get_drawings()
    finally:
        result.close()


def test_append_copy_uses_selected_reference_page_not_last(monkeypatch, tmp_path):
    import fitz

    configure_temp_document_paths(monkeypatch, tmp_path)
    document = fitz.open()
    document.new_page(width=317, height=499).insert_text((30, 40), "Selected page")
    document.new_page(width=400, height=600)
    server.CURRENT_PDF.write_bytes(document.tobytes())
    document.close()
    state["document"] = {"filename": "notes.pdf", "pages": [
        {"id": "page-1", "pageNumber": 1, "x": 0, "y": 0, "width": 317, "height": 499},
        {"id": "page-2", "pageNumber": 2, "x": 0, "y": 499, "width": 400, "height": 600},
    ]}
    response = TestClient(app).post("/api/pages/append?kind=copy&referencePageNumber=1")
    assert response.status_code == 200, response.text
    result = fitz.open(server.CURRENT_PDF)
    try:
        assert result.page_count == 3
        assert result[2].rect.width == 317
        assert "Selected page" in result[2].get_text()
    finally:
        result.close()


def test_missing_template_does_not_change_document(monkeypatch, tmp_path):
    import fitz

    configure_temp_document_paths(monkeypatch, tmp_path)
    document = fitz.open()
    document.new_page(width=317, height=499)
    original_bytes = document.tobytes()
    server.CURRENT_PDF.write_bytes(original_bytes)
    document.close()
    state["document"] = {"filename": "notes.pdf", "pages": [
        {"id": "page-1", "pageNumber": 1, "x": 0, "y": 0, "width": 317, "height": 499},
    ]}
    response = TestClient(app).post("/api/pages/insert?afterPageNumber=1&kind=template&presetId=missing")
    assert response.status_code == 404
    assert server.CURRENT_PDF.read_bytes() == original_bytes
    assert len(state["document"]["pages"]) == 1


def prepare_page_management_test(monkeypatch, tmp_path):
    import fitz
    configure_temp_document_paths(monkeypatch, tmp_path)
    document = fitz.open()
    for height in (150, 200, 300):
        document.new_page(width=200, height=height)
    server.CURRENT_PDF.write_bytes(document.tobytes())
    document.close()
    state["document"] = {"filename": "pages.pdf", "pages": [
        {"id": "page-1", "pageNumber": 1, "x": 0, "y": 0, "width": 200, "height": 150},
        {"id": "page-2", "pageNumber": 2, "x": 0, "y": 150, "width": 200, "height": 200},
        {"id": "page-3", "pageNumber": 3, "x": 0, "y": 350, "width": 200, "height": 300},
    ]}
    state["strokes"] = {
        name: {"id": name, "pageIndex": index, "points": [{"x": 20, "y": y, "y_raw": y}]}
        for name, index, y in (("first", 0, 20), ("middle", 1, 170), ("last", 2, 370))
    }
    history[:] = [{"type": "add", "strokes": [copy.deepcopy(stroke)]} for stroke in state["strokes"].values()]
    redo_history[:] = [{"type": "delete", "strokes": [copy.deepcopy(state["strokes"]["last"])]}]


def test_inserting_custom_size_keeps_and_remaps_ink_history(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    response = TestClient(app).post("/api/pages/insert?afterPageNumber=1", json={
        "useCurrentSize": False, "pageWidthPt": 400, "pageHeightPt": 180,
    })
    assert response.status_code == 200, response.text
    assert len(history) == 4 and history[-1]["type"] == "page"
    assert state["document"]["pages"][1]["width"] == 400
    assert state["document"]["pages"][1]["height"] == 180
    assert history[-2]["strokes"][0]["coordinateSpace"] == "page-local"
    assert history[-2]["strokes"][0]["points"][0]["y"] == 20
    assert redo_history == []  # a new page operation starts a new history branch
    action = history[-2]
    server.apply_history_action(action, undo=True)
    assert "last" not in state["strokes"]
    server.apply_history_action(action, undo=False)
    assert state["strokes"]["last"]["points"][0]["y"] == 550


def test_delete_page_removes_its_ink_and_remaps_remaining_history(monkeypatch, tmp_path):
    import fitz
    prepare_page_management_test(monkeypatch, tmp_path)
    response = TestClient(app).post("/api/pages/delete?pageNumber=2")
    assert response.status_code == 200, response.text
    assert "middle" not in state["strokes"]
    assert state["strokes"]["last"]["points"][0]["y"] == 170
    assert state["strokes"]["last"]["pageIndex"] == 1
    assert len(history) == 4 and history[-1]["type"] == "page"
    assert history[-2]["strokes"][0]["points"][0]["y"] == 20
    assert history[-1]["deletedInk"][0]["id"] == "middle"
    assert redo_history == []
    document = fitz.open(server.CURRENT_PDF)
    try:
        assert document.page_count == 2
        assert document[1].rect.height == 300
    finally:
        document.close()


def test_delete_last_page_is_rejected(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    client = TestClient(app)
    assert client.post("/api/pages/delete?pageNumber=3").status_code == 200
    assert client.post("/api/pages/delete?pageNumber=2").status_code == 200
    assert client.post("/api/pages/delete?pageNumber=1").status_code == 400
    assert len(state["document"]["pages"]) == 1


def test_delete_page_preserves_both_halves_and_earlier_history_of_cross_page_moves(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    before = copy.deepcopy(state["strokes"]["middle"])
    after = copy.deepcopy(before)
    after["pageIndex"] = 2
    after["points"][0]["y"] = after["points"][0]["y_raw"] = 390
    state["strokes"]["middle"] = after
    history.append({"type": "replace", "before": [before], "after": [after]})
    redo_history.append({"type": "add", "strokes": [copy.deepcopy(after)]})
    response = TestClient(app).post("/api/pages/delete?pageNumber=2")
    assert response.status_code == 200, response.text
    assert state["strokes"]["middle"]["points"][0]["y"] == 190
    replace = history[-2]
    assert replace["type"] == "replace"
    assert replace["before"][0]["pageId"] != replace["after"][0]["pageId"]
    assert replace["before"][0]["points"][0]["y"] == 20
    assert replace["after"][0]["points"][0]["y"] == 40
    assert history[1]["strokes"][0]["id"] == "middle"
    assert redo_history == []


def test_invalid_custom_template_leaves_pdf_and_history_unchanged(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    original_pdf = server.CURRENT_PDF.read_bytes()
    original_history = copy.deepcopy(history)
    response = TestClient(app).post("/api/pages/insert?afterPageNumber=1&kind=template", json={
        "template": {"id": "bad", "name": "Bad", "minorWidthMm": -1},
    })
    assert response.status_code == 422, response.text
    assert server.CURRENT_PDF.read_bytes() == original_pdf
    assert history == original_history


@pytest.mark.parametrize("operation, expected_y", [("insert", 520), ("delete", 170)])
def test_page_changes_remap_unfinished_eraser_history(monkeypatch, tmp_path, operation, expected_y):
    prepare_page_management_test(monkeypatch, tmp_path)
    pending_delete_operations["erase"] = {
        "updatedAt": time.monotonic(), "strokes": copy.deepcopy(state["strokes"]),
    }
    path = "/api/pages/insert?afterPageNumber=1" if operation == "insert" else "/api/pages/delete?pageNumber=2"
    response = TestClient(app).post(path)
    assert response.status_code == 200, response.text
    grouped = pending_delete_operations["erase"]["strokes"]
    assert grouped["last"]["points"][0]["y"] == expected_y
    if operation == "delete":
        assert "middle" not in grouped


def test_custom_template_can_be_saved_and_inserted_with_combined_vector_patterns(monkeypatch, tmp_path):
    import fitz
    prepare_page_management_test(monkeypatch, tmp_path)
    preset = {"id": "custom", "name": "Custom", "style": "eng", "title": "Study",
              "headerCm": 1.2, "background": "#eeeedd", "minorLinesEnabled": False,
              "majorLinesEnabled": True, "dotsEnabled": True, "dotSpacingCm": 0.5}
    client = TestClient(app)
    assert client.post("/api/page-templates", json=preset).status_code == 200
    listed = client.get("/api/page-templates").json()["presets"]
    assert next(item for item in listed if item["id"] == "custom")["minorLinesEnabled"] is False
    response = client.post("/api/pages/append?kind=template&referencePageNumber=1", json={
        "useCurrentSize": False, "pageWidthPt": 612, "pageHeightPt": 792, "template": preset,
    })
    assert response.status_code == 200, response.text
    document = fitz.open(server.CURRENT_PDF)
    try:
        page = document[-1]
        assert page.rect.width == 612
        assert page.rect.height == 792
        assert "Study" in page.get_text()
        assert len(page.get_drawings()) == 3  # background, major grid, dots
        assert page.get_images(full=True) == []
    finally:
        document.close()


def test_page_layout_keeps_surviving_database_rows_and_assets_unchanged(monkeypatch, tmp_path):
    import fitz
    rendered = []
    render_svg = fitz.Page.get_svg_image
    def count_render(page, *args, **kwargs):
        rendered.append(page.number)
        return render_svg(page, *args, **kwargs)
    monkeypatch.setattr(fitz.Page, "get_svg_image", count_render)
    prepare_page_management_test(monkeypatch, tmp_path)
    original = copy.deepcopy(state)
    server.notebook_store.commit(upserts=state["strokes"], deletes=set(),
                                metadata={key: value for key, value in state.items() if key != "strokes"})
    original_rows = dict(server.notebook_store.connection.execute("SELECT id,value FROM strokes"))
    client = TestClient(app)
    first = client.post("/api/pages/insert?afterPageNumber=1")
    assert first.status_code == 200, first.text
    migrated = dict(server.notebook_store.connection.execute("SELECT id,value FROM strokes"))
    local_last = json.loads(migrated["last"])
    assert local_last["coordinateSpace"] == "page-local"
    assert local_last["points"][0]["y"] == 20
    assert "pageIndex" not in local_last
    identities = [page["id"] for page in state["document"]["pages"]]
    assets = {page["id"]: page["imageUrl"] for page in state["document"]["pages"]}
    rendered.clear()
    statements = []
    server.notebook_store.connection.set_trace_callback(statements.append)
    second = client.post("/api/pages/insert?afterPageNumber=1")
    assert second.status_code == 200, second.text
    assert len(rendered) == 1  # only the new page, not the existing PDF pages
    assert dict(server.notebook_store.connection.execute("SELECT id,value FROM strokes")) == migrated
    assert not any("INSERT INTO strokes" in sql or "DELETE FROM strokes" in sql for sql in statements)
    assert [p["id"] for p in state["document"]["pages"] if p["id"] in identities] == identities
    for page in state["document"]["pages"]:
        if page["id"] in assets:
            assert page["imageUrl"] == assets[page["id"]]
    server.notebook_store.connection.set_trace_callback(None)
    rendered.clear()
    deleted = client.post("/api/pages/delete?pageNumber=4")  # original middle page
    assert deleted.status_code == 200, deleted.text
    assert rendered == []
    final_rows = dict(server.notebook_store.connection.execute("SELECT id,value FROM strokes"))
    assert final_rows == {key: value for key, value in migrated.items() if key != "middle"}
    restored = server.notebook_store.load()
    assert restored["strokes"] == state["strokes"]
    backup = dict(server.notebook_store.connection.execute(
        "SELECT id,value FROM page_identity_backup WHERE kind='stroke' AND document_id=?", (original["documentId"],)))
    assert backup == original_rows


def test_page_pdf_upgrade_reuses_survivors_and_transfers_only_inserted_page(monkeypatch, tmp_path):
    import hashlib
    import fitz
    prepare_page_management_test(monkeypatch, tmp_path)
    # Real imported notebooks already have generation-specific preview URLs;
    # the page-management fixture starts with bare geometry metadata instead.
    for page in state["document"]["pages"]:
        page["imageUrl"] = f'/pdf-pages/page-{page["id"]}.svg?v=legacy-test'
    original = copy.deepcopy(state)
    extracted = []
    extract = server.extract_page
    def track(document, index):
        extracted.append(index)
        return extract(document, index)
    monkeypatch.setattr(server, "extract_page", track)
    client = TestClient(app)
    assert client.get("/api/pdf/pages?documentId=another-notebook").status_code == 409
    response = client.get("/api/pdf/pages", params={"documentId": state["documentId"]})
    assert response.status_code == 200, response.text
    manifest = response.json()["pages"]
    assert len(manifest) == 3 and len(extracted) == 3
    assert state == original  # lazy background upgrade never mutates ink/revisions
    cache = set()
    original_mtimes = {}
    for page in manifest:
        resource = client.get(page["pdfUrl"])
        assert resource.status_code == 200
        assert resource.headers["content-type"] == "application/pdf"
        assert resource.headers["cache-control"].endswith("immutable")
        assert len(resource.content) == page["pdfBytes"]
        assert hashlib.sha256(resource.content).hexdigest() == page["pdfSha256"]
        with fitz.open(stream=resource.content, filetype="pdf") as single:
            assert single.page_count == 1
            assert single[0].rect.width == page["width"] and single[0].rect.height == page["height"]
        cache.add(page["pdfSha256"])
        path = server.asset_path(server.PDF_PAGES_DIR, page["pdfSha256"])
        original_mtimes[path] = path.stat().st_mtime_ns
    extracted.clear()
    assert client.get("/api/pdf/pages", params={"documentId": state["documentId"]}).json()["pages"] == manifest
    assert extracted == []
    assert all(path.stat().st_mtime_ns == before for path, before in original_mtimes.items())
    inserted = client.post("/api/pages/insert?afterPageNumber=1&kind=template&presetId=square-grid")
    assert inserted.status_code == 200, inserted.text
    assert len(extracted) == 1
    inserted_pages = inserted.json()["document"]["pages"]
    missing = [page for page in inserted_pages if page["pdfSha256"] not in cache]
    assert len(missing) == 1
    assert sum(page["pdfBytes"] for page in missing) < server.CURRENT_PDF.stat().st_size
    assert {page["pdfSha256"] for page in inserted_pages} >= cache
    cache.update(page["pdfSha256"] for page in missing)
    extracted.clear()
    deleted = client.post("/api/pages/delete?pageNumber=2")
    assert deleted.status_code == 200, deleted.text
    assert extracted == []
    assert all(page["pdfSha256"] in cache for page in deleted.json()["document"]["pages"])
    # Combined-PDF compatibility/export source remains available.
    assert client.get("/api/pdf/source").status_code == 200
    assert client.get("/api/pdf/page/not-a-hash").status_code == 400
    assert client.get("/api/pdf/page/" + "0" * 64).status_code == 404


def test_large_page_layout_broadcast_contains_no_ink(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    state["strokes"] = {
        f"ink-{i}": {"id": f"ink-{i}", "pageIndex": 2, "points": [
            {"x": j * 0.1, "y": 370 + j * 0.1, "p": 0.5, "t": j} for j in range(80)
        ]} for i in range(2400)
    }
    history.clear(); redo_history.clear()
    messages = []
    async def capture(message, **kwargs):
        messages.append(copy.deepcopy(message))
    monkeypatch.setattr(server, "broadcast", capture)
    with TestClient(app) as client:
        assert client.post("/api/pages/insert?afterPageNumber=1").status_code == 200
        messages.clear()
        started = time.perf_counter()
        response = client.post("/api/pages/insert?afterPageNumber=1")
        elapsed = time.perf_counter() - started
    assert response.status_code == 200, response.text
    assert [message["type"] for message in messages] == ["page_layout", "history_state"]
    assert "strokes" not in response.json()
    assert len(response.content) < 10_000
    assert len(state["strokes"]) == 2400
    assert server.notebook_store.load()["strokes"]["ink-0"]["points"][0]["y"] == 670
    print(f"2400 strokes / 192000 points: layout event {len(response.content)} bytes, server operation {elapsed:.3f}s")


def test_migrated_project_export_import_retains_page_ownership(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    client = TestClient(app)
    assert client.post("/api/pages/insert?afterPageNumber=1").status_code == 200
    # Fill normal wire defaults so the test exercises the real project sanitizer.
    original_y = state["strokes"]["last"]["points"][0]["y"]
    archive = client.get("/api/project/export")
    assert archive.status_code == 200
    response = client.post("/api/project/import", files={"file": ("roundtrip.inotes", archive.content, "application/zip")})
    assert response.status_code == 200, response.text
    stroke = state["strokes"]["last"]
    assert stroke["points"][0]["y"] == original_y
    assert stroke["pageId"] == state["document"]["pages"][stroke["pageIndex"]]["id"]
    assert client.post("/api/pages/delete?pageNumber=2").status_code == 200
    assert state["strokes"]["last"]["points"][0]["y"] == 370


def test_page_layout_is_one_identical_event_for_native_browser_and_http(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    with TestClient(app) as client:
        with client.websocket_connect("/ws?role=ipad&clientId=native-layout-test&pageLayoutVersion=1") as ipad:
            assert ipad.receive_json()["type"] == "state_refresh"
            assert ipad.receive_json()["type"] == "history_state"
            with client.websocket_connect("/ws?role=desktop&pageLayoutVersion=1") as desktop:
                assert desktop.receive_json()["type"] == "snapshot"
                assert desktop.receive_json()["type"] == "history_state"
                for path in ("/api/pages/insert?afterPageNumber=1", "/api/pages/delete?pageNumber=2"):
                    response = client.post(path)
                    assert response.status_code == 200, response.text
                    for socket in (ipad, desktop):
                        message = socket.receive_json()
                        assert message == response.json()
                        assert message["type"] == "page_layout"
                        assert "strokes" not in message
                        assert socket.receive_json()["type"] == "history_state"
                        socket.send_json({"type": "ping", "clientTime": 123})
                        assert socket.receive_json()["type"] == "pong"  # no queued replacement ink or refresh


def test_legacy_offline_page_id_reconciles_locally_and_deleted_page_is_rejected(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    raw = {**copy.deepcopy(state["strokes"]["last"]), "pageId": "page-3"}
    raw["points"][0]["x_local"] = 20
    raw["points"][0]["y_local"] = 20
    client = TestClient(app)
    assert client.post("/api/pages/insert?afterPageNumber=1").status_code == 200
    recovered = server.sanitize_live_stroke(raw)
    assert recovered["pageIndex"] == 3
    assert recovered["pageId"] == state["document"]["pages"][3]["id"]
    assert recovered["points"][0]["y"] == 520
    assert client.post("/api/pages/delete?pageNumber=4").status_code == 200
    with pytest.raises(ValueError, match="no longer exists"):
        server.sanitize_live_stroke(raw)


@pytest.mark.parametrize("query, expected", [("role=ipad&clientId=native-old-layout", "state_refresh"), ("role=desktop", "snapshot")])
def test_older_clients_receive_compatible_layout_recovery(monkeypatch, tmp_path, query, expected):
    prepare_page_management_test(monkeypatch, tmp_path)
    with TestClient(app) as client:
        with client.websocket_connect("/ws?" + query) as socket:
            socket.receive_json(); socket.receive_json()
            response = client.post("/api/pages/insert?afterPageNumber=1")
            assert response.status_code == 200
            message = socket.receive_json()
            assert message["type"] == expected
            assert message["reason"] == "page_layout"
            assert socket.receive_json()["type"] == "history_state"
            socket.send_json({"type": "ping", "clientTime": 123})
            assert socket.receive_json()["type"] == "pong"


@pytest.mark.parametrize("identifiers", [("../../unsafe",), ("duplicate", "duplicate")])
def test_project_page_ids_cannot_traverse_asset_paths_or_duplicate(identifiers):
    from fastapi import HTTPException
    pages = [{"id": identifier, "width": 200, "height": 150} for identifier in identifiers]
    with pytest.raises(HTTPException) as error:
        server.sanitize_project_pages(pages)
    assert error.value.status_code == 400



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
        time.sleep(0.1)

        ipad.send_json({"type": "delete_strokes", "ids": [stroke["id"]], "reliable": True})
        time.sleep(0.1)
        assert laptop.receive_json() == {"type": "delete_strokes", "ids": [stroke["id"]]}
        assert ipad.receive_json() == {"type": "delete_ack", "ids": [stroke["id"]], "final": True}
        assert laptop.receive_json()["type"] == "history_state"
        assert ipad.receive_json()["type"] == "history_state"


def test_one_native_socket_batches_two_completed_strokes_before_ack(monkeypatch):
    monkeypatch.setattr(server, "BATCH_MAX_DELAY_SECONDS", 5.0)
    commits = []
    original_commit = server.notebook_store.commit_batch

    def record_commit(operations):
        commits.append(len(operations))
        return original_commit(operations)

    monkeypatch.setattr(server.notebook_store, "commit_batch", record_commit)
    with TestClient(app) as client:
        with client.websocket_connect("/ws?role=ipad&clientId=native-batch-test") as websocket:
            assert websocket.receive_json()["type"] == "state_refresh"
            assert websocket.receive_json()["type"] == "history_state"
            for index in range(2):
                stroke = {
                    "id": f"batch-stroke-{index}",
                    "owner": "native-batch-test",
                    "tool": "pen",
                    "color": "#111111",
                    "width": 1,
                    "opacity": 1,
                    "smoothing": 0,
                    "points": [{"x": index, "y": index, "p": 0.5, "t": index}],
                }
                websocket.send_json({"type": "stroke_begin", "stroke": stroke})
                websocket.send_json({"type": "stroke_end", "id": stroke["id"]})

            async def flush_both():
                async def both_enqueued():
                    while len(server.notebook_writer().pending) < 2:
                        await asyncio.sleep(0.001)

                await asyncio.wait_for(both_enqueued(), timeout=2)
                await server.notebook_writer().flush()

            assert client.portal is not None
            client.portal.call(flush_both)
            acknowledgements = []
            while len(acknowledgements) < 2:
                message = websocket.receive_json()
                if message["type"] == "stroke_ack":
                    acknowledgements.append(message)
            assert [ack["documentRevision"] for ack in acknowledgements] == [1, 2]
            assert [ack["stateToken"].rsplit(":", 1)[1] for ack in acknowledgements] == ["1", "2"]
    assert commits == [2]
    assert set(server.notebook_store.load()["strokes"]) == {"batch-stroke-0", "batch-stroke-1"}


def test_failed_stroke_commit_sends_error_and_restores_durable_state(monkeypatch):
    monkeypatch.setattr(server, "BATCH_MAX_DELAY_SECONDS", 0.0)

    def fail_commit(_operations):
        raise OSError("simulated disk failure")

    monkeypatch.setattr(server.notebook_store, "commit_batch", fail_commit)
    stroke = {
        "id": "failed-stroke", "owner": "native-failure", "tool": "pen",
        "color": "#111111", "width": 1, "opacity": 1, "smoothing": 0,
        "points": [{"x": 1, "y": 2, "p": 0.5, "t": 0}],
    }
    with TestClient(app) as client:
        with client.websocket_connect("/ws?role=ipad&clientId=native-failure") as websocket:
            websocket.receive_json()
            websocket.receive_json()
            websocket.send_json({"type": "stroke_begin", "stroke": stroke})
            websocket.send_json({"type": "stroke_end", "id": stroke["id"]})
            reply = websocket.receive_json()
            assert reply == {"type": "error", "message": "Notebook save failed"}
            websocket.send_json({"type": "stroke_begin", "stroke": {**stroke, "id": "later-stroke"}})
            assert websocket.receive_json() == {
                "type": "error", "message": "Notebook storage failed; restart the server before editing",
            }

    assert server.persistence_failed
    assert "failed-stroke" not in state["strokes"]
    assert "later-stroke" not in state["strokes"]
    assert "failed-stroke" not in server.notebook_store.load()["strokes"]
    assert not history


def test_slow_commit_does_not_block_websocket_heartbeat(monkeypatch):
    monkeypatch.setattr(server, "BATCH_MAX_DELAY_SECONDS", 0.0)
    commit_started = threading.Event()
    release_commit = threading.Event()
    original_commit = server.notebook_store.commit_batch

    def delayed_commit(operations):
        commit_started.set()
        assert release_commit.wait(3)
        return original_commit(operations)

    monkeypatch.setattr(server.notebook_store, "commit_batch", delayed_commit)
    stroke = {
        "id": "slow-stroke", "owner": "native-slow", "tool": "pen",
        "color": "#111111", "width": 1, "opacity": 1, "smoothing": 0,
        "points": [{"x": 1, "y": 2, "p": 0.5, "t": 0}],
    }
    with TestClient(app) as client:
        with client.websocket_connect("/ws?role=ipad&clientId=native-slow") as websocket:
            websocket.receive_json()
            websocket.receive_json()
            websocket.send_json({"type": "stroke_begin", "stroke": stroke})
            websocket.send_json({"type": "stroke_end", "id": stroke["id"]})
            assert commit_started.wait(2)
            websocket.send_json({"type": "ping", "clientTime": 123})
            received = []
            reader = threading.Thread(target=lambda: received.append(websocket.receive_json()), daemon=True)
            reader.start()
            try:
                reader.join(1)
                responsive = bool(received)
            finally:
                release_commit.set()
                reader.join(3)
            assert responsive
            assert received[0] == {"type": "pong", "clientTime": 123}


def test_pdf_assets_restore_old_generation_when_database_commit_fails(monkeypatch, tmp_path):
    configure_temp_document_paths(monkeypatch, tmp_path)
    server.CURRENT_PDF.write_bytes(b"old-pdf")
    (server.PDF_PAGES_DIR / "page-0001.svg").write_text("<svg>old</svg>")
    prepared = tmp_path / "prepared"
    (prepared / "pdf_pages").mkdir(parents=True)
    (prepared / "current.pdf").write_bytes(b"new-pdf")
    (prepared / "pdf_pages" / "page-0001.svg").write_text("<svg>new</svg>")
    pages = [{"id": "page-1", "pageNumber": 1, "imageUrl": "/pdf-pages/page-0001.svg",
              "x": 0, "y": 0, "width": 100, "height": 100}]
    monkeypatch.setattr(server, "prepare_pdf", lambda _content: (prepared, pages))

    def fail_commit(_operations):
        raise OSError("simulated database failure")

    monkeypatch.setattr(server.notebook_store, "commit_batch", fail_commit)
    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.post("/api/pdf", files={"file": ("new.pdf", b"%PDF-new", "application/pdf")})
    assert response.status_code == 500
    assert server.CURRENT_PDF.read_bytes() == b"old-pdf"
    assert (server.PDF_PAGES_DIR / "page-0001.svg").read_text() == "<svg>old</svg>"
    assert not (server.DATA_DIR / "asset-transition").exists()
    assert server.notebook_store.load()["document"]["filename"] != "new.pdf"


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


def test_desktop_import_and_both_exports_use_source_folder_without_overwrite(monkeypatch, tmp_path):
    import fitz
    from urllib.parse import unquote
    import local_files

    configure_temp_document_paths(monkeypatch, tmp_path)
    source_folder = tmp_path / 'Lecture notes — originals'
    source_folder.mkdir()
    source = source_folder / 'lecture.pdf'
    with fitz.open() as pdf:
        pdf.new_page(width=300, height=400)
        source.write_bytes(pdf.tobytes())
    original = source.read_bytes()

    async def choose(kind):
        assert kind == 'pdf'
        return source

    monkeypatch.setattr(local_files, 'choose_path', choose)
    headers = {'X-Infinite-Notes-Local': '1', 'Origin': 'http://127.0.0.1:8000'}
    with TestClient(app, base_url='http://127.0.0.1:8000', client=('127.0.0.1', 42000)) as client:
        response = client.post('/api/local-files/pdf', headers=headers)
        assert response.status_code == 200, response.text
        assert local_files.get_origin(server.DATA_DIR, response.json()['documentId']) == source_folder
        for kind in ('pdf', 'project'):
            response = client.get(f'/api/{kind}/export?saveBesideSource=true', headers=headers)
            assert response.status_code == 200, response.text
            exported = Path(unquote(response.headers['X-Infinite-Notes-Saved-Path']))
            assert exported.parent == source_folder
            assert exported.read_bytes() == response.content
            repeated = client.get(f'/api/{kind}/export?saveBesideSource=true', headers=headers)
            second = Path(unquote(repeated.headers['X-Infinite-Notes-Saved-Path']))
            assert second != exported
            assert second.name.endswith(f' (1){exported.suffix}')
        assert source.read_bytes() == original
        assert not list(source_folder.glob('.infinite-notes-export-*'))
        # Choosing an exported project remembers its directory, not its embedded PDF name.
        project = source_folder / 'lecture.inotes'
        async def choose_project(kind):
            assert kind == 'project'
            return project
        monkeypatch.setattr(local_files, 'choose_path', choose_project)
        imported = client.post('/api/local-files/project', headers=headers)
        assert imported.status_code == 200, imported.text
        project_bytes = project.read_bytes()
        response = client.get('/api/project/export?saveBesideSource=true', headers=headers)
        assert Path(unquote(response.headers['X-Infinite-Notes-Saved-Path'])) != project
        assert project.read_bytes() == project_bytes
        # A normal browser upload does not inherit the previous file's folder.
        response = client.post('/api/pdf', files={'file': ('other.pdf', original, 'application/pdf')})
        assert response.status_code == 200
        assert local_files.get_origin(server.DATA_DIR, response.json()['documentId']) is None


def test_desktop_file_access_rejects_remote_cross_origin_and_missing_header(monkeypatch, tmp_path):
    import local_files
    configure_temp_document_paths(monkeypatch, tmp_path)
    async def must_not_open(kind):
        raise AssertionError('Forbidden request opened desktop picker')
    monkeypatch.setattr(local_files, 'choose_path', must_not_open)
    with TestClient(app, base_url='http://127.0.0.1:8000', client=('10.0.0.2', 1234)) as client:
        assert client.post('/api/local-files/pdf', headers={'X-Infinite-Notes-Local': '1'}).status_code == 403
    with TestClient(app, base_url='http://127.0.0.1:8000', client=('127.0.0.1', 1234)) as client:
        assert client.post('/api/local-files/pdf').status_code == 403
        assert client.post('/api/local-files/pdf', headers={
            'X-Infinite-Notes-Local': '1', 'Origin': 'https://example.com'}).status_code == 403
        assert client.get('/api/project/export?saveBesideSource=true').status_code == 403
    with TestClient(app, base_url='http://example.com', client=('127.0.0.1', 1234)) as client:
        assert client.post('/api/local-files/pdf', headers={'X-Infinite-Notes-Local': '1'}).status_code == 403


def test_desktop_picker_cancel_preserves_notebook_and_destination(monkeypatch, tmp_path):
    import local_files
    configure_temp_document_paths(monkeypatch, tmp_path)
    local_files.set_origin(server.DATA_DIR, server.current_document_id(), tmp_path)
    before = copy.deepcopy(state)
    async def cancelled(kind):
        return None
    monkeypatch.setattr(local_files, 'choose_path', cancelled)
    with TestClient(app, base_url='http://127.0.0.1', client=('127.0.0.1', 1234)) as client:
        response = client.post('/api/local-files/pdf', headers={'X-Infinite-Notes-Local': '1'})
        assert response.json() == {'cancelled': True}
    assert state == before
    assert local_files.get_origin(server.DATA_DIR, server.current_document_id()) == tmp_path
