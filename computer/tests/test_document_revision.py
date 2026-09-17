from __future__ import annotations

import asyncio
import importlib.util
import io
import json
import uuid
import zipfile
from pathlib import Path

import pytest
import fitz
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
    store = server.NotebookStore(data_dir / "notebook.sqlite3")
    store.initialize(server.state)
    monkeypatch.setattr(server, "notebook_store", store)
    server.stored_metadata = server.copy.deepcopy({key: value for key, value in server.state.items() if key != "strokes"})
    server.persistence_failed = False
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
    original_bytes = server.STATE_FILE.read_bytes()
    monkeypatch.setattr(server, "DATABASE_FILE", server.DATA_DIR / "migrated.sqlite3")

    migrated_store, loaded = server.load_authoritative_state()

    assert loaded["documentRevision"] == 0
    assert str(uuid.UUID(loaded["documentId"])) == loaded["documentId"]
    assert loaded["strokes"] == legacy["strokes"]
    assert server.STATE_FILE.read_bytes() == original_bytes
    assert migrated_store.load() == loaded
    migrated_store.close()


@pytest.mark.parametrize("malformed", [None, True, "", "not-a-uuid"])
def test_malformed_document_identity_is_replaced(malformed: object) -> None:
    candidate = {"documentId": malformed}

    assert server.normalize_document_id(candidate) is True
    assert str(uuid.UUID(candidate["documentId"])) == candidate["documentId"]


def test_document_identity_is_canonicalized_without_replacement() -> None:
    document_id = uuid.uuid4()
    candidate = {"documentId": str(document_id).upper()}

    assert server.normalize_document_id(candidate) is True
    assert candidate["documentId"] == str(document_id)
    assert server.normalize_document_id(candidate) is False


def test_native_state_summary_includes_document_identity() -> None:
    message = server.state_refresh_message(reason="initial")

    assert message["documentId"] == server.current_document_id()
    assert str(uuid.UUID(message["documentId"])) == message["documentId"]


def test_changes_endpoint_exposes_durable_revision_without_full_state(monkeypatch, tmp_path) -> None:
    _reset_server(monkeypatch, tmp_path)
    document_id = server.current_document_id()
    with TestClient(server.app) as client:
        initial = client.get("/api/changes", params={
            "documentId": document_id, "sinceRevision": 0,
        })
        assert initial.status_code == 200
        assert initial.json()["status"] == "complete"
        assert initial.json()["upserts"] == {}
        server.state["strokes"]["delta-stroke"] = {"id": "delta-stroke", "points": []}
        assert asyncio.run(server.save_state_atomic(upsert_ids={"delta-stroke"})) == 1
        response = client.get("/api/changes", params={
            "documentId": document_id, "sinceRevision": 0,
        })
        assert response.status_code == 200
        payload = response.json()
        assert payload["status"] == "complete"
        assert payload["nextRevision"] == 1
        assert payload["upserts"]["delta-stroke"]["id"] == "delta-stroke"
        assert "strokes" not in payload
        assert client.get("/api/changes", params={
            "documentId": document_id, "sinceRevision": -1,
        }).status_code == 400


def test_new_pdf_rotates_document_identity(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _reset_server(monkeypatch, tmp_path)
    previous_id = server.current_document_id()
    prepared_root = tmp_path / "prepared"
    prepared_root.mkdir()
    (prepared_root / "current.pdf").write_bytes(b"%PDF-test")
    pages = [{
        "id": "page-1",
        "pageNumber": 1,
        "imageUrl": "/pdf-pages/page-0001.svg",
        "x": 0.0,
        "y": 0.0,
        "width": 320.0,
        "height": 480.0,
    }]
    monkeypatch.setattr(server, "prepare_pdf", lambda _content: (prepared_root, pages))

    class StubUpload:
        filename = "identity.pdf"

        async def read(self, _limit: int) -> bytes:
            return b"%PDF-test"

    response = asyncio.run(server.upload_pdf(StubUpload()))

    assert response.status_code == 200
    document_id = server.current_document_id()
    assert document_id != previous_id
    assert str(uuid.UUID(document_id)) == document_id
    assert json.loads(response.body)["documentId"] == document_id
    assert server.notebook_store.load()["documentId"] == document_id


def test_pdf_and_page_identity_lifecycle(monkeypatch, tmp_path) -> None:
    _reset_server(monkeypatch, tmp_path)
    client = TestClient(server.app)
    with fitz.open() as pdf:
        pdf.new_page(width=320, height=480)
        content = pdf.tobytes()
    old_id = server.current_document_id()
    response = client.post("/api/pdf", files={"file": ("notes.pdf", content, "application/pdf")})
    assert response.status_code == 200
    document_id = response.json()["documentId"]
    assert document_id != old_id
    for endpoint in ("/api/pages/append", "/api/pages/insert?afterPageNumber=1"):
        assert client.post(endpoint).status_code == 200
        assert client.get("/api/state").json()["documentId"] == document_id
        assert server.notebook_store.load()["documentId"] == document_id


def test_empty_notebook_identity_survives_restart(monkeypatch, tmp_path) -> None:
    _reset_server(monkeypatch, tmp_path)
    first = server.notebook_store.load()
    assert server.notebook_store.load() == first
    assert first["documentRevision"] == 0


def test_restart_changes_token_even_with_identical_document_metadata(monkeypatch, tmp_path) -> None:
    _reset_server(monkeypatch, tmp_path)
    before = server.state_refresh_message(reason="initial")
    monkeypatch.setattr(server, "SERVER_INSTANCE_ID", uuid.uuid4().hex)
    after = server.state_refresh_message(reason="initial")
    assert after["documentId"] == before["documentId"]
    assert after["documentRevision"] == before["documentRevision"]
    assert after["stateToken"] != before["stateToken"]


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

    server.state["document"]["filename"] = "first.pdf"
    assert asyncio.run(server.save_state_atomic()) == 1
    assert server.current_document_revision() == 1
    server.state = server.notebook_store.load()
    assert server.current_document_revision() == 1
    server.state["document"]["filename"] = "second.pdf"
    assert asyncio.run(server.save_state_atomic()) == 2
    assert server.notebook_store.load()["documentRevision"] == 2


def test_failed_atomic_write_does_not_publish_advanced_revision(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _reset_server(monkeypatch, tmp_path)
    server.state["document"]["filename"] = "unsaved.pdf"
    state_token_before = server.current_state_token()

    def fail_write(**_kwargs) -> None:
        raise OSError("simulated disk failure")

    monkeypatch.setattr(server.notebook_store, "commit_batch", lambda _batch: fail_write())
    with pytest.raises(OSError, match="simulated disk failure"):
        asyncio.run(server.save_state_atomic())

    assert server.current_document_revision() == 0
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
        assert initial["documentId"] == server.current_document_id()

        websocket.send_json({"type": "stroke_begin", "stroke": stroke})
        websocket.send_json({"type": "stroke_end", "id": stroke["id"]})
        websocket.receive_json()
        ack = websocket.receive_json()

    assert ack["type"] == "stroke_ack"
    assert ack["documentRevision"] == 1
    snapshot = client.get("/api/state").json()
    assert snapshot["documentRevision"] == 1
    assert snapshot["documentId"] == initial["documentId"]


def test_project_import_cannot_roll_back_authority_revision() -> None:
    raw_project = {
        "version": 1,
        "documentRevision": 999_999,
        "document": {"filename": None, "pages": []},
        "strokes": {},
    }

    sanitized = server.sanitize_project_state(raw_project, has_pdf=False)

    assert "documentRevision" not in sanitized


def test_project_identity_survives_export_sanitization() -> None:
    document_id = str(uuid.uuid4())
    sanitized = server.sanitize_project_state({
        "documentId": document_id,
        "document": {"filename": None, "pages": []},
        "strokes": {},
    }, has_pdf=False)

    assert sanitized["documentId"] == document_id


def test_project_import_advances_local_revision_instead_of_trusting_archive(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _reset_server(monkeypatch, tmp_path)
    server.state["documentRevision"] = 41
    server.notebook_store.commit(
        upserts={}, deletes=set(),
        metadata={key: value for key, value in server.state.items() if key != "strokes"},
    )
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
    persisted = server.notebook_store.load()
    assert persisted["documentRevision"] == 42
