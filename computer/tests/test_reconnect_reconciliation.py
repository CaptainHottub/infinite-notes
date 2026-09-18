from pathlib import Path
import importlib.util
import pytest

from fastapi.testclient import TestClient
import uuid

COMPUTER_DIR = Path(__file__).resolve().parents[1]
(COMPUTER_DIR / "data" / "pdf_pages").mkdir(parents=True, exist_ok=True)
SPEC = importlib.util.spec_from_file_location("infinite_notes_server_reconnect", COMPUTER_DIR / "server.py")
assert SPEC and SPEC.loader
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


def _sample_stroke(stroke_id: str = "native-reconnect-1") -> dict:
    return {
        "id": stroke_id,
        "tool": "pen",
        "color": "#111111",
        "width": 1.0,
        "opacity": 1.0,
        "smoothing": 0.0,
        "strokeDetail": 100.0,
        "lineStyle": "solid",
        "owner": "native-reconnect-test",
        "locked": False,
        "pageIndex": 0,
        "points": [
            {"x": 10.0, "y": 10.0, "p": 0.5, "t": 1.0, "x_raw": 10.0, "y_raw": 10.0},
            {"x": 20.0, "y": 20.0, "p": 0.5, "t": 2.0, "x_raw": 20.0, "y_raw": 20.0},
        ],
    }


def _reset_server(monkeypatch, tmp_path: Path) -> None:
    data_dir = tmp_path / "data"
    pages_dir = data_dir / "pdf_pages"
    pages_dir.mkdir(parents=True)
    monkeypatch.setattr(server, "DATA_DIR", data_dir)
    monkeypatch.setattr(server, "PDF_PAGES_DIR", pages_dir)
    monkeypatch.setattr(server, "STATE_FILE", data_dir / "state.json")
    monkeypatch.setattr(server, "CURRENT_PDF", data_dir / "current.pdf")
    server.state = server.empty_state()
    store = server.NotebookStore(data_dir / "notebook.sqlite3")
    store.initialize(server.state)
    monkeypatch.setattr(server, "notebook_store", store)
    server.stored_metadata = server.copy.deepcopy({key: value for key, value in server.state.items() if key != "strokes"})
    server.persistence_failed = False
    server.history.clear()
    server.redo_history.clear()
    server.pending_stroke_history.clear()
    server.pending_delete_operations.clear()


def test_reconcile_restores_a_completed_native_stroke(monkeypatch, tmp_path):
    _reset_server(monkeypatch, tmp_path)
    stroke = _sample_stroke()

    client = TestClient(server.app)
    with client.websocket_connect("/ws?role=ipad&clientId=native-reconnect-test") as websocket:
        assert websocket.receive_json()["type"] == "state_refresh"
        assert websocket.receive_json()["type"] == "history_state"

        websocket.send_json({"type": "reconcile_strokes", "strokes": [stroke]})
        ack = websocket.receive_json()
        assert ack["type"] == "reconcile_ack"
        assert ack["ids"] == [stroke["id"]]
        assert ack["stateToken"]
        assert ack["documentRevision"] == 1
        history_state = websocket.receive_json()
        assert history_state["type"] == "history_state"
        assert history_state["canUndo"] is True

    assert server.state["strokes"][stroke["id"]]["points"][-1]["x"] == 20.0
    assert server.history[-1]["type"] == "add"


def test_reconcile_is_idempotent(monkeypatch, tmp_path):
    _reset_server(monkeypatch, tmp_path)
    stroke = _sample_stroke()
    client = TestClient(server.app)

    with client.websocket_connect("/ws?role=ipad&clientId=native-reconnect-test") as websocket:
        websocket.receive_json()
        websocket.receive_json()
        websocket.send_json({"type": "reconcile_strokes", "strokes": [stroke]})
        websocket.receive_json()
        websocket.receive_json()

        history_count = len(server.history)
        websocket.send_json({"type": "reconcile_strokes", "strokes": [stroke]})
        ack = websocket.receive_json()
        assert ack["type"] == "reconcile_ack"
        assert ack["ids"] == [stroke["id"]]
        assert ack["stateToken"]

    assert len(server.state["strokes"]) == 1
    assert len(server.history) == history_count


def test_reconcile_rejects_another_document_without_mutation(monkeypatch, tmp_path):
    _reset_server(monkeypatch, tmp_path)
    client = TestClient(server.app)
    with client.websocket_connect("/ws?role=ipad&clientId=native-journal-test") as websocket:
        summary = websocket.receive_json()
        websocket.receive_json()
        websocket.send_json({"type": "reconcile_strokes", "documentId": "another-notebook",
                             "strokes": [_sample_stroke()]})
        error = websocket.receive_json()
        assert error["type"] == "error"
        assert server.state["strokes"] == {}
        assert server.history == []
        assert server.current_document_revision() == summary["documentRevision"]
        websocket.send_json({"type": "reconcile_strokes", "documentId": summary["documentId"],
                             "strokes": [_sample_stroke()]})
        ack = websocket.receive_json()
        assert ack["type"] == "reconcile_ack"
        assert ack["documentId"] == summary["documentId"]
        websocket.receive_json()


@pytest.mark.parametrize("kind", ["stroke_begin", "stroke_points", "stroke_end"])
def test_streamed_stroke_rejects_another_document(monkeypatch, tmp_path, kind):
    _reset_server(monkeypatch, tmp_path)
    stroke = _sample_stroke()
    with TestClient(server.app).websocket_connect("/ws?role=ipad&clientId=native-journal-test") as websocket:
        websocket.receive_json()
        websocket.receive_json()
        websocket.send_json({"type": kind, "documentId": "wrong-document", "id": stroke["id"],
                             "stroke": stroke, "points": stroke["points"]})
        assert websocket.receive_json()["type"] == "error"
    assert server.state["strokes"] == {}
    assert server.current_document_revision() == 0



def test_complete_stroke_end_recovers_a_missing_stroke_begin(monkeypatch, tmp_path):
    _reset_server(monkeypatch, tmp_path)
    stroke = _sample_stroke("native-offline-final")
    client = TestClient(server.app)

    with client.websocket_connect("/ws?role=ipad&clientId=native-reconnect-test") as websocket:
        websocket.receive_json()
        websocket.receive_json()
        websocket.send_json({
            "type": "stroke_end",
            "id": stroke["id"],
            "stroke": stroke,
        })
        history_state = websocket.receive_json()
        assert history_state["type"] == "history_state"
        assert history_state["canUndo"] is True
        ack = websocket.receive_json()
        assert ack["type"] == "stroke_ack"
        assert ack["ids"] == [stroke["id"]]
        assert ack["pointCount"] == len(stroke["points"])
        assert ack["stateToken"]

    assert stroke["id"] in server.state["strokes"]
    assert server.history[-1]["type"] == "add"

def test_native_eraser_uses_rendered_geometry_path():
    repo_root = Path(__file__).resolve().parents[2]
    geometry = (repo_root / "ipad/Sources/InfiniteNotesStrokeLab/GeometryEngine.swift").read_text()
    app_model = (repo_root / "ipad/Sources/InfiniteNotesStrokeLab/AppModel.swift").read_text()

    assert "static func eraserHitTest" in geometry
    assert "polyline(for: stroke, segments: 96)" in geometry
    assert "GeometryEngine.eraserHitTest" in app_model
    assert "Drawing offline — Pencil strokes will upload after reconnecting" in app_model


def _receive_type(websocket, kind):
    for _ in range(20):
        message = websocket.receive_json()
        if message['type'] == kind:
            return message
        assert message['type'] != 'error', message
    raise AssertionError(f'Missing {kind}')


def test_offline_erase_replay_is_durable_grouped_and_noop_on_lost_ack(monkeypatch, tmp_path):
    _reset_server(monkeypatch, tmp_path)
    strokes = [_sample_stroke('erase-one'), _sample_stroke('erase-two')]
    with TestClient(server.app) as client:
        with client.websocket_connect('/ws?role=ipad&clientId=native-offline-erase') as ws:
            document_id = ws.receive_json()['documentId']
            ws.receive_json()
            ws.send_json({'type': 'reconcile_strokes', 'documentId': document_id, 'strokes': strokes})
            _receive_type(ws, 'reconcile_ack')
            ws.send_json({'type': 'delete_strokes', 'documentId': document_id,
                          'operationId': 'offline-gesture', 'ids': ['erase-one'], 'final': False})
            first = _receive_type(ws, 'delete_ack')
            assert first['documentId'] == document_id
            assert not first['final']
            ws.send_json({'type': 'delete_strokes', 'documentId': document_id,
                          'operationId': 'offline-gesture', 'ids': ['erase-two'], 'final': True})
            ack = _receive_type(ws, 'delete_ack')
            assert ack['documentId'] == document_id
            assert ack['final']
            assert server.notebook_store.load()['strokes'] == {}
        # Simulate retaining the final batch after losing its ACK, then reconnect.
        with client.websocket_connect('/ws?role=ipad&clientId=native-offline-erase') as ws:
            ws.receive_json()
            ws.receive_json()
            ws.send_json({'type': 'delete_strokes', 'documentId': document_id,
                          'operationId': 'offline-gesture', 'ids': ['erase-two'], 'final': True})
            replay = _receive_type(ws, 'delete_ack')
            assert replay['ids'] == ['erase-two']
            assert replay['documentId'] == document_id
            assert replay['documentRevision'] == ack['documentRevision']
            ws.send_json({'type': 'undo'})
            restored = _receive_type(ws, 'restore_strokes')
            assert {s['id'] for s in restored['strokes']} == {'erase-one', 'erase-two'}
            assert set(server.notebook_store.load()['strokes']) == {'erase-one', 'erase-two'}


def test_offline_erase_rejects_another_notebook_before_mutation(monkeypatch, tmp_path):
    _reset_server(monkeypatch, tmp_path)
    with TestClient(server.app) as client:
        with client.websocket_connect('/ws?role=ipad&clientId=native-offline-erase') as ws:
            document_id = ws.receive_json()['documentId']
            ws.receive_json()
            ws.send_json({'type': 'reconcile_strokes', 'documentId': document_id,
                          'strokes': [_sample_stroke('preserve')]})
            _receive_type(ws, 'reconcile_ack')
            before = server.notebook_store.load()
            ws.send_json({'type': 'delete_strokes', 'documentId': str(uuid.uuid4()),
                          'operationId': 'wrong-notebook', 'ids': ['preserve'], 'final': True})
            error = _receive_type(ws, 'error')
            assert 'different document' in error['message']
            assert server.notebook_store.load() == before
            assert 'preserve' in server.state['strokes']
            assert 'wrong-notebook' not in server.pending_delete_operations
