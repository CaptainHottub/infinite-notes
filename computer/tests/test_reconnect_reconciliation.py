from pathlib import Path
import importlib.util

from fastapi.testclient import TestClient

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
        assert websocket.receive_json() == {
            "type": "reconcile_ack",
            "ids": [stroke["id"]],
        }
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
        assert websocket.receive_json() == {
            "type": "reconcile_ack",
            "ids": [stroke["id"]],
        }

    assert len(server.state["strokes"]) == 1
    assert len(server.history) == history_count



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
        assert websocket.receive_json() == {
            "type": "stroke_ack",
            "ids": [stroke["id"]],
        }

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
