from __future__ import annotations

import importlib.util
import io
import json
import zipfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient


COMPUTER_DIR = Path(__file__).resolve().parents[1]
(COMPUTER_DIR / "data" / "pdf_pages").mkdir(parents=True, exist_ok=True)
SPEC = importlib.util.spec_from_file_location(
    "infinite_notes_server_document_revision",
    COMPUTER_DIR / "server.py",
)
assert SPEC and SPEC.loader
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


def _reset_server(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    data_dir = tmp_path / "data"
    pages_dir = data_dir / "pdf_pages"
    pages_dir.mkdir(parents=True)
    monkeypatch.setattr(server, "DATA_DIR", data_dir)
    monkeypatch.setattr(server, "PDF_PAGES_DIR", pages_dir)
    monkeypatch.setattr(server, "STATE_FILE", data_dir / "state.json")
    monkeypatch.setattr(server, "CURRENT_PDF", data_dir / "current.pdf")
    server.state = server.empty_state()
    server.state_revision = 0
    server.history.clear()
    server.redo_history.clear()
    server.pending_stroke_history.clear()
    server.pending_delete_operations.clear()


def test_legacy_state_migrates_revision_without_changing_content(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _reset_server(monkeypatch, tmp_path)
    legacy = {
        "version": 1,
        "document": {"filename": None, "pages": []},
        "strokes": {"kept": {"id": "kept"}},
    }
    server.STATE_FILE.write_text(json.dumps(legacy), encoding="utf-8")

    loaded = server.load_state()

    assert loaded["documentRevision"] == 0
    assert loaded["strokes"] == legacy["strokes"]
    assert json.loads(server.STATE_FILE.read_text(encoding="utf-8"))["documentRevision"] == 0


@pytest.mark.parametrize("malformed", [-1, True, "3", None])
def test_malformed_revision_is_not_accepted_as_authoritative(malformed: object) -> None:
    candidate = {"documentRevision": malformed}

    assert server.normalize_document_revision(candidate) is True
    assert candidate["documentRevision"] == 0


def test_revision_advances_once_per_successful_save_and_survives_reload(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _reset_server(monkeypatch, tmp_path)

    assert server.save_state_atomic() == 1
    assert server.current_document_revision() == 1
    server.state = server.load_state()
    assert server.current_document_revision() == 1
    assert server.save_state_atomic() == 2
    assert json.loads(server.STATE_FILE.read_text(encoding="utf-8"))["documentRevision"] == 2


def test_failed_atomic_write_does_not_publish_advanced_revision(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _reset_server(monkeypatch, tmp_path)
    server.state["documentRevision"] = 7
    state_token_before = server.current_state_token()

    def fail_write(_value: dict) -> None:
        raise OSError("simulated disk failure")

    monkeypatch.setattr(server, "write_state_atomic", fail_write)
    with pytest.raises(OSError, match="simulated disk failure"):
        server.save_state_atomic()

    assert server.current_document_revision() == 7
    assert server.current_state_token() == state_token_before


def test_native_summary_and_durable_ack_include_document_revision(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _reset_server(monkeypatch, tmp_path)
    stroke = {
        "id": "revision-stroke",
        "owner": "native-revision-test",
        "tool": "pen",
        "color": "#111111",
        "width": 1,
        "opacity": 1,
        "smoothing": 0,
        "strokeDetail": 100,
        "points": [{"x": 1, "y": 2, "p": 0.5, "t": 1}],
    }
    client = TestClient(server.app)

    with client.websocket_connect("/ws?role=ipad&clientId=native-revision-test") as websocket:
        initial = websocket.receive_json()
        websocket.receive_json()
        assert initial["documentRevision"] == 0

        websocket.send_json({"type": "stroke_begin", "stroke": stroke})
        websocket.send_json({"type": "stroke_end", "id": stroke["id"]})
        websocket.receive_json()
        ack = websocket.receive_json()

    assert ack["type"] == "stroke_ack"
    assert ack["documentRevision"] == 1
    assert client.get("/api/state").json()["documentRevision"] == 1


def test_project_import_cannot_roll_back_authority_revision() -> None:
    raw_project = {
        "version": 1,
        "documentRevision": 999_999,
        "document": {"filename": None, "pages": []},
        "strokes": {},
    }

    sanitized = server.sanitize_project_state(raw_project, has_pdf=False)

    assert "documentRevision" not in sanitized


def test_project_import_advances_local_revision_instead_of_trusting_archive(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _reset_server(monkeypatch, tmp_path)
    server.state["documentRevision"] = 41
    project_state = {
        "version": 1,
        "documentRevision": 999_999,
        "document": {"filename": None, "pages": []},
        "strokes": {},
    }
    manifest = {
        "format": server.PROJECT_FORMAT,
        "formatVersion": server.PROJECT_FORMAT_VERSION,
        "appVersion": server.APP_VERSION,
        "hasPdf": False,
    }
    archive_data = io.BytesIO()
    with zipfile.ZipFile(archive_data, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest))
        archive.writestr("state.json", json.dumps(project_state))

    response = TestClient(server.app).post(
        "/api/project/import",
        files={"file": ("revision.inotes", archive_data.getvalue(), "application/zip")},
    )

    assert response.status_code == 200
    assert server.current_document_revision() == 42
    persisted = json.loads(server.STATE_FILE.read_text(encoding="utf-8"))
    assert persisted["documentRevision"] == 42
