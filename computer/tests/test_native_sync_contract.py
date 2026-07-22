from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP_MODEL = (ROOT / "ipad" / "Sources" / "InfiniteNotesStrokeLab" / "AppModel.swift").read_text(encoding="utf-8")
SERVER_CLIENT = (ROOT / "ipad" / "Sources" / "InfiniteNotesStrokeLab" / "ServerClient.swift").read_text(encoding="utf-8")
SERVER = (ROOT / "computer" / "server.py").read_text(encoding="utf-8")


def test_native_full_state_uses_http_not_websocket():
    assert 'case "state_refresh"' in APP_MODEL
    assert 'endpoint(path: "/api/state")' in APP_MODEL
    assert 'Accept-Encoding' in APP_MODEL
    assert 'GZipMiddleware' in SERVER
    assert 'client_id.startswith("native-")' in SERVER
    assert 'state_refresh_message(reason="initial")' in SERVER
    assert 'state_refresh_message(reason="project_import")' in SERVER


def test_websocket_has_defensive_legacy_size_limit():
    assert 'task.maximumMessageSize = 256 * 1024 * 1024' in SERVER_CLIENT
    assert 'MAX_NATIVE_WS_MESSAGE_BYTES' in SERVER
    assert 'oversized_' in SERVER
