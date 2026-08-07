from __future__ import annotations

import asyncio
import importlib.util
from pathlib import Path

from fastapi.testclient import TestClient

COMPUTER_DIR = Path(__file__).resolve().parents[1]
(COMPUTER_DIR / "data" / "pdf_pages").mkdir(parents=True, exist_ok=True)
SPEC = importlib.util.spec_from_file_location("infinite_notes_server_campus", COMPUTER_DIR / "server.py")
assert SPEC and SPEC.loader
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


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
    server.state_revision = 0


def test_native_initial_refresh_and_http_state_share_token(monkeypatch, tmp_path):
    _reset_server(monkeypatch, tmp_path)
    client = TestClient(server.app)
    with client.websocket_connect("/ws?role=ipad&clientId=native-campus-test") as websocket:
        initial = websocket.receive_json()
        websocket.receive_json()
        assert initial["type"] == "state_refresh"
        token = initial["stateToken"]

    snapshot = client.get("/api/state").json()
    assert snapshot["stateToken"] == token


def test_state_token_changes_after_saved_mutation(monkeypatch, tmp_path):
    _reset_server(monkeypatch, tmp_path)
    before = server.current_state_token()
    server.state["strokes"]["x"] = {"id": "x"}
    server.save_state_atomic()
    assert server.current_state_token() != before


def test_safe_send_json_swallows_send_after_close_runtime_error():
    class ClosedSocket:
        async def send_json(self, message):
            raise RuntimeError("Unexpected ASGI message 'websocket.send', after sending 'websocket.close'.")

    result = asyncio.run(server.safe_send_json(ClosedSocket(), {"type": "stroke_ack"}))
    assert result is False


def test_native_ack_reports_server_point_count(monkeypatch, tmp_path):
    _reset_server(monkeypatch, tmp_path)
    stroke = {
        "id": "campus-count",
        "owner": "native-campus-test",
        "tool": "pen",
        "color": "#111111",
        "width": 1,
        "opacity": 1,
        "smoothing": 0,
        "strokeDetail": 100,
        "points": [
            {"x": 1, "y": 2, "p": 0.5, "t": 1},
            {"x": 2, "y": 3, "p": 0.5, "t": 2},
            {"x": 3, "y": 4, "p": 0.5, "t": 3},
        ],
    }
    client = TestClient(server.app)
    with client.websocket_connect("/ws?role=ipad&clientId=native-campus-test") as websocket:
        websocket.receive_json()
        websocket.receive_json()
        websocket.send_json({"type": "stroke_begin", "stroke": stroke})
        websocket.send_json({"type": "stroke_end", "id": stroke["id"]})
        history = websocket.receive_json()
        assert history["type"] == "history_state"
        ack = websocket.receive_json()
        assert ack["type"] == "stroke_ack"
        assert ack["pointCount"] == len(stroke["points"])
        assert ack["stateToken"] == server.current_state_token()


def test_native_client_source_contains_websocket_heartbeat_and_token_guard():
    repo_root = COMPUTER_DIR.parent
    server_client = (repo_root / "ipad/Sources/InfiniteNotesStrokeLab/ServerClient.swift").read_text()
    app_model = (repo_root / "ipad/Sources/InfiniteNotesStrokeLab/AppModel.swift").read_text()
    assert "targetTask.sendPing" in server_client
    assert "heartbeatInterval: TimeInterval = 8" in server_client
    assert 'incomingToken == lastAppliedStateToken' in app_model
    assert 'serverPointCount != expected.points.count' in app_model
