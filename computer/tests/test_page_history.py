import asyncio
import copy
import json

import fitz
import pytest
from fastapi.testclient import TestClient

import server
from test_server import isolated_state, prepare_page_management_test


def connect(client):
    return client.websocket_connect("/ws?role=ipad&clientId=native-page-history&pageLayoutVersion=1")


def initial(socket):
    assert socket.receive_json()["type"] == "state_refresh"
    assert socket.receive_json()["type"] == "history_state"


def page_request(client, socket, path):
    response = client.post(path)
    assert response.status_code == 200, response.text
    assert socket.receive_json() == response.json()
    assert socket.receive_json()["type"] == "history_state"
    return response.json()


def page_history(socket, kind, *, ink=False):
    socket.send_json({"type": kind})
    layout = socket.receive_json()
    assert layout["type"] == "page_layout", layout
    restored = socket.receive_json() if ink else None
    if ink:
        assert restored["type"] == "restore_strokes"
    assert socket.receive_json()["type"] == "history_state"
    return layout, restored


def test_insert_ink_and_page_undo_redo_share_one_ordered_history(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    before = copy.deepcopy(server.state["strokes"])
    with TestClient(server.app) as client, connect(client) as socket:
        initial(socket)
        inserted = page_request(client, socket, "/api/pages/insert?afterPageNumber=1&kind=template&presetId=square-grid")
        pages = inserted["document"]["pages"]
        added = pages[1]
        stroke = {"id": "new-ink", "pageId": added["id"], "pageIndex": 1,
                  "points": [{"x": -40, "y": added["y"] + 30, "x_raw": -41, "y_raw": added["y"] + 31, "p": 0.8, "t": 1}]}
        socket.send_json({"type": "add_strokes", "strokes": [stroke]})
        assert socket.receive_json()["type"] == "history_state"
        socket.send_json({"type": "undo"})
        assert socket.receive_json() == {"type": "delete_strokes", "ids": ["new-ink"]}
        assert socket.receive_json()["type"] == "history_state"
        undone, _ = page_history(socket, "undo")
        assert len(undone["document"]["pages"]) == 3
        assert server.state["strokes"]["last"]["points"][0]["y"] == before["last"]["points"][0]["y"]
        redone, _ = page_history(socket, "redo")
        assert redone["document"]["pages"] == pages
        assert client.get(added["pdfUrl"]).content == server.history[-1]["pdf"]
        socket.send_json({"type": "redo"})
        restored = socket.receive_json()
        assert restored["type"] == "restore_strokes"
        assert restored["strokes"][0]["pageId"] == added["id"]
        assert restored["strokes"][0]["points"][0]["y"] == stroke["points"][0]["y"]
        assert restored["strokes"][0]["points"][0]["x"] == -40
        assert socket.receive_json()["type"] == "history_state"
        assert server.notebook_store.load()["strokes"] == server.state["strokes"]


def test_deleted_page_restores_background_ink_and_prior_ink_history(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    # Include rotated vector/text content, not just blank-page counts.
    with fitz.open(server.CURRENT_PDF) as pdf:
        page = pdf[1]
        page.draw_line((20, 20), (170, 170), color=(0, 0, 1), width=2)
        page.insert_text((20, 40), "Restored page")
        page.set_rotation(90)
        source_pixels = page.get_pixmap().samples
        content = pdf.tobytes()
    server.CURRENT_PDF.write_bytes(content)
    with TestClient(server.app) as client, connect(client) as socket:
        initial(socket)
        deleted = page_request(client, socket, "/api/pages/delete?pageNumber=2")
        action = server.history[-1]
        saved_pdf = action["pdf"]
        assert len(action["deletedInk"]) == 1
        assert action["deletedInk"][0]["points"][0]["y"] == 20
        rows = dict(server.notebook_store.connection.execute("SELECT id,value FROM strokes"))
        restored, ink = page_history(socket, "undo", ink=True)
        restored_page = restored["document"]["pages"][1]
        assert restored_page["id"] == action["pageId"]
        assert client.get(restored_page["pdfUrl"]).content == saved_pdf
        (tmp_path / "restored-vector-page.pdf").write_bytes(saved_pdf)
        assert ink["strokes"][0]["id"] == "middle"
        assert ink["strokes"][0]["points"][0]["y"] == 170
        with fitz.open(server.CURRENT_PDF) as pdf:
            assert pdf[1].get_pixmap().samples == source_pixels
            assert "Restored page" in pdf[1].get_text()
            assert pdf[1].get_images() == []
        restored_rows = dict(server.notebook_store.connection.execute("SELECT id,value FROM strokes"))
        assert all(restored_rows[key] == value for key, value in rows.items())
        assert server.notebook_store.load()["strokes"] == server.state["strokes"]
        # Undo the earlier ink addition after restoring its page.
        socket.send_json({"type": "undo"})
        assert socket.receive_json() == {"type": "delete_strokes", "ids": ["last"]}
        assert socket.receive_json()["type"] == "history_state"
        socket.send_json({"type": "undo"})
        assert socket.receive_json() == {"type": "delete_strokes", "ids": ["middle"]}
        assert socket.receive_json()["type"] == "history_state"
        for identifier in ("middle", "last"):
            socket.send_json({"type": "redo"})
            assert socket.receive_json()["strokes"][0]["id"] == identifier
            assert socket.receive_json()["type"] == "history_state"
        redone, _ = page_history(socket, "redo")
        assert redone["document"] == deleted["document"]
        assert "middle" not in server.state["strokes"]
        assert server.state["strokes"]["last"]["points"][0]["y"] == 170


@pytest.mark.parametrize("path", ["/api/pages/append", "/api/pages/insert?afterPageNumber=3", "/api/pages/delete?pageNumber=1", "/api/pages/delete?pageNumber=3"])
def test_page_history_edges_and_repeated_cycles(monkeypatch, tmp_path, path):
    prepare_page_management_test(monkeypatch, tmp_path)
    original_points = {key: copy.deepcopy(stroke["points"]) for key, stroke in server.state["strokes"].items()}
    with TestClient(server.app) as client, connect(client) as socket:
        initial(socket)
        final = page_request(client, socket, path)
        deleting = "/delete" in path
        for _ in range(3):
            restored, _ = page_history(socket, "undo", ink=deleting)
            assert len(restored["document"]["pages"]) == 3
            for key, original in original_points.items():
                point = server.state["strokes"][key]["points"][0]
                assert point["x"] == original[0]["x"] and point["y"] == original[0]["y"]
            redone, _ = page_history(socket, "redo")
            assert redone["document"] == final["document"]
            assert server.notebook_store.load()["strokes"] == server.state["strokes"]


def test_new_edit_after_page_undo_discards_redo_branch(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    with TestClient(server.app) as client, connect(client) as socket:
        initial(socket)
        page_request(client, socket, "/api/pages/append")
        page_history(socket, "undo")
        assert server.redo_history[-1]["type"] == "page"
        socket.send_json({"type": "add_strokes", "strokes": [{"id": "branch", "pageIndex": 0, "points": [{"x": 30, "y": 40}]}]})
        assert socket.receive_json() == {"type": "history_state", "canUndo": True, "canRedo": False}
        assert server.redo_history == []


def test_page_history_rejects_live_ink_without_consuming_action(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    with TestClient(server.app) as client, connect(client) as socket:
        initial(socket)
        page_request(client, socket, "/api/pages/append")
        before = copy.deepcopy(server.history)
        server.pending_stroke_history.add("live")
        socket.send_json({"type": "undo"})
        assert socket.receive_json()["type"] == "error"
        assert server.history == before and server.redo_history == []


def test_page_history_prepare_failure_leaves_pdf_state_and_stack_unchanged(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    client = TestClient(server.app)
    assert client.post("/api/pages/delete?pageNumber=2").status_code == 200
    action = server.history[-1]
    before_state = copy.deepcopy(server.state)
    before_pdf = server.CURRENT_PDF.read_bytes()
    def fail(*args, **kwargs):
        raise ValueError("injected prepare failure")
    monkeypatch.setattr(server, "prepare_pdf", fail)
    with pytest.raises(ValueError, match="injected prepare failure"):
        asyncio.run(server.replay_page_history(action, undo=True))
    assert server.state == before_state
    assert server.CURRENT_PDF.read_bytes() == before_pdf
    assert server.history[-1] is action and not server.redo_history


def test_page_history_memory_cap_discards_oldest_actions(monkeypatch):
    monkeypatch.setattr(server, "MAX_PAGE_HISTORY_BYTES", 10)
    server.history.clear()
    for i in range(4):
        server.push_history({"type": "page", "pageId": str(i), "historyBytes": 6})
    assert [action["pageId"] for action in server.history] == ["3"]


def test_large_deleted_page_ink_restores_in_bounded_native_batches(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    server.history.clear()
    server.redo_history.clear()
    for i in range(600):
        server.state["strokes"][f"dense-{i}"] = {"id": f"dense-{i}", "pageIndex": 1,
            "points": [{"x": j * 0.2, "y": 170 + j * 0.1, "x_raw": j * 0.2 - 1,
                        "y_raw": 171 + j * 0.1, "p": 0.8, "t": j} for j in range(80)]}
    with TestClient(server.app) as client, connect(client) as socket:
        initial(socket)
        page_request(client, socket, "/api/pages/delete?pageNumber=2")
        socket.send_json({"type": "undo"})
        layout = socket.receive_json()
        assert layout["type"] == "page_layout"
        batches, restored = 0, set()
        while True:
            message = socket.receive_json()
            if message["type"] == "history_state":
                break
            assert message["type"] == "restore_strokes", message
            assert len(json.dumps(message, separators=(",", ":")).encode()) <= server.MAX_NATIVE_WS_MESSAGE_BYTES
            batches += 1
            restored.update(stroke["id"] for stroke in message["strokes"])
        assert batches > 1
        assert restored == {"middle"} | {f"dense-{i}" for i in range(600)}
        assert server.notebook_store.load()["strokes"] == server.state["strokes"]


def test_page_undo_storage_failure_recovers_matching_assets_and_durable_state(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    with TestClient(server.app) as client, connect(client) as socket:
        initial(socket)
        page_request(client, socket, "/api/pages/delete?pageNumber=2")
        durable = server.notebook_store.load()
        pdf_before = server.CURRENT_PDF.read_bytes()
        def fail(_operations):
            raise RuntimeError("injected SQLite failure")
        monkeypatch.setattr(server.notebook_store, "commit_batch", fail)
        socket.send_json({"type": "undo"})
        assert socket.receive_json()["type"] == "error"
        assert server.persistence_failed
        assert server.state == durable
        assert server.CURRENT_PDF.read_bytes() == pdf_before
        assert not server.history and not server.redo_history
        assert not (server.DATA_DIR / "asset-transition").exists()


def test_multiple_page_operations_undo_and_redo_in_exact_order(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    with TestClient(server.app) as client, connect(client) as socket:
        initial(socket)
        inserted = page_request(client, socket, "/api/pages/insert?afterPageNumber=1&kind=copy")
        deleted = page_request(client, socket, "/api/pages/delete?pageNumber=3")
        appended = page_request(client, socket, "/api/pages/append?kind=template&presetId=dot-grid")
        undone_append, _ = page_history(socket, "undo")
        assert undone_append["document"] == deleted["document"]
        undone_delete, _ = page_history(socket, "undo", ink=True)
        assert undone_delete["document"] == inserted["document"]
        undone_insert, _ = page_history(socket, "undo")
        assert len(undone_insert["document"]["pages"]) == 3
        assert server.state["strokes"]["middle"]["points"][0]["y"] == 170
        for expected in (inserted, deleted, appended):
            restored, _ = page_history(socket, "redo")
            assert restored["document"] == expected["document"]
        assert server.notebook_store.load()["strokes"] == server.state["strokes"]


def test_cross_page_move_remains_undoable_after_page_restoration(monkeypatch, tmp_path):
    prepare_page_management_test(monkeypatch, tmp_path)
    before = copy.deepcopy(server.state["strokes"]["middle"])
    after = copy.deepcopy(before)
    after["pageIndex"] = 2
    after["points"][0]["y"] = after["points"][0]["y_raw"] = 390
    server.state["strokes"]["middle"] = after
    server.history.append({"type": "replace", "before": [before], "after": [after]})
    with TestClient(server.app) as client, connect(client) as socket:
        initial(socket)
        page_request(client, socket, "/api/pages/delete?pageNumber=2")
        page_history(socket, "undo")  # no ink currently resides on that page
        socket.send_json({"type": "undo"})
        move = socket.receive_json()
        assert move["type"] == "replace_strokes"
        assert move["strokes"][0]["points"][0]["y"] == 170
        assert move["strokes"][0]["pageIndex"] == 1
        assert socket.receive_json()["type"] == "history_state"
        socket.send_json({"type": "redo"})
        assert socket.receive_json()["strokes"][0]["points"][0]["y"] == 390
        assert socket.receive_json()["type"] == "history_state"
        page_history(socket, "redo")
        assert server.state["strokes"]["middle"]["points"][0]["y"] == 190
