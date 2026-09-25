"""Isolated storage tests; never use the server's configured notebook path."""

import copy
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

import server
from persistence import NotebookStore


def sample_state():
    value = server.empty_state()
    value["documentId"] = "8c1c613c-7970-4168-9b94-9d779464a15a"
    value["documentRevision"] = 19
    value["document"]["filename"] = "test.pdf"
    value["customMetadata"] = {"retained": [1, "two"]}
    value["strokes"] = {
        "first": {"id": "first", "points": [{"x": 1.5, "y": 2.0}]},
        "second": {"id": "second", "points": [{"x": 4.0, "y": 8.5}]},
    }
    return value


def test_legacy_migration_is_equivalent_and_never_reimports_stale_json(monkeypatch, tmp_path):
    legacy = tmp_path / "state.json"
    original = sample_state()
    original_bytes = json.dumps(original, indent=2).encode()
    legacy.write_bytes(original_bytes)
    monkeypatch.setattr(server, "STATE_FILE", legacy)
    monkeypatch.setattr(server, "DATABASE_FILE", tmp_path / "notebook.sqlite3")

    first_store, loaded = server.load_authoritative_state()
    assert loaded == original
    assert legacy.read_bytes() == original_bytes
    first_store.close()

    legacy.write_text(json.dumps(server.empty_state()))
    second_store, loaded_again = server.load_authoritative_state()
    assert loaded_again == original
    second_store.close()


def test_interrupted_initialization_retries_from_legacy(monkeypatch, tmp_path):
    legacy = tmp_path / "state.json"
    original = sample_state()
    legacy.write_text(json.dumps(original))
    database = tmp_path / "notebook.sqlite3"
    partial = NotebookStore(database)
    partial.connection.execute("INSERT INTO strokes(id,value) VALUES ('partial','{}')")
    partial.connection.commit()
    partial.close()
    monkeypatch.setattr(server, "STATE_FILE", legacy)
    monkeypatch.setattr(server, "DATABASE_FILE", database)

    store, loaded = server.load_authoritative_state()
    assert loaded == original
    assert "partial" not in loaded["strokes"]
    store.close()


def test_uninitialized_database_without_source_fails(monkeypatch, tmp_path):
    database = tmp_path / "notebook.sqlite3"
    NotebookStore(database).close()
    monkeypatch.setattr(server, "STATE_FILE", tmp_path / "state.json")
    monkeypatch.setattr(server, "DATABASE_FILE", database)
    with pytest.raises(ValueError, match="uninitialized"):
        server.load_authoritative_state()


def test_invalid_legacy_source_is_preserved(monkeypatch, tmp_path):
    legacy = tmp_path / "state.json"
    legacy.write_bytes(b"{ invalid json")
    monkeypatch.setattr(server, "STATE_FILE", legacy)
    monkeypatch.setattr(server, "DATABASE_FILE", tmp_path / "notebook.sqlite3")
    with pytest.raises(json.JSONDecodeError):
        server.load_authoritative_state()
    assert legacy.read_bytes() == b"{ invalid json"


def test_incremental_commit_changes_only_touched_rows_and_no_json(tmp_path):
    database = tmp_path / "notebook.sqlite3"
    legacy = tmp_path / "state.json"
    legacy.write_bytes(b"migration backup")
    original = sample_state()
    store = NotebookStore(database)
    store.initialize(original)
    assert store.connection.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    assert store.connection.execute("PRAGMA synchronous").fetchone()[0] == 2
    before = dict(store.connection.execute("SELECT id,value FROM strokes"))

    updated = copy.deepcopy(original["strokes"]["first"])
    updated["points"].append({"x": 9.0, "y": 10.0})
    metadata = {key: copy.deepcopy(value) for key, value in original.items() if key != "strokes"}
    metadata["documentRevision"] += 1
    statements = []
    store.connection.set_trace_callback(statements.append)
    store.commit_batch([{"replace_all": False, "deletes": set(),
                         "upserts": {"first": updated}, "metadata": metadata}])
    store.connection.set_trace_callback(None)

    after = dict(store.connection.execute("SELECT id,value FROM strokes"))
    assert after["second"] == before["second"]
    assert json.loads(after["first"]) == updated
    change_record = store.connection.execute(
        "SELECT value FROM revision_changes WHERE revision=20"
    ).fetchone()[0]
    assert json.loads(change_record)["upsertIds"] == ["first"]
    assert "points" not in change_record
    assert not any("DELETE FROM strokes" in statement for statement in statements)
    assert not any("second" in statement for statement in statements)
    assert legacy.read_bytes() == b"migration backup"
    store.close()


def test_revision_feed_is_contiguous_bounded_and_survives_reopen(tmp_path):
    database = tmp_path / "notebook.sqlite3"
    original = sample_state()
    store = NotebookStore(database)
    store.initialize(original)
    for revision in range(20, 24):
        metadata = {key: copy.deepcopy(value) for key, value in original.items() if key != "strokes"}
        metadata["documentRevision"] = revision
        store.commit_batch([{
            "replace_all": False, "deletes": set(),
            "upserts": {"first": {"id": "first", "points": [{"x": revision}]}},
            "metadata": metadata,
        }])
    store.close()
    store = NotebookStore(database)
    store.CHANGE_PAGE_LIMIT = 2
    first = store.changes_since(original["documentId"], 19)
    assert first["status"] == "more"
    assert first["nextRevision"] == 21
    assert first["upserts"]["first"]["points"] == [{"x": 23}]
    second = store.changes_since(original["documentId"], first["nextRevision"])
    assert second["status"] == "complete"
    assert second["nextRevision"] == 23
    no_changes = store.changes_since(original["documentId"], 23)
    assert no_changes["status"] == "complete"
    assert no_changes["nextRevision"] == 23
    assert no_changes["upserts"] == {}
    assert store.changes_since("different", 19)["status"] == "snapshot_required"
    assert store.changes_since(original["documentId"], 24)["status"] == "snapshot_required"
    store.close()


def test_revision_feed_splits_large_delta_before_byte_limit(tmp_path):
    store = NotebookStore(tmp_path / "notebook.sqlite3")
    original = sample_state()
    store.initialize(original)
    for revision in (20, 21):
        stroke_id = f"large-{revision}"
        stroke = {"id": stroke_id, "points": [{"data": "x" * 100}]}
        metadata = {key: copy.deepcopy(value) for key, value in original.items() if key != "strokes"}
        metadata["documentRevision"] = revision
        store.commit_batch([{"replace_all": False, "deletes": set(),
                             "upserts": {stroke_id: stroke}, "metadata": metadata}])
    store.CHANGE_BYTE_LIMIT = len(json.dumps(stroke, separators=(",", ":")).encode()) + len(stroke_id) + 8
    first = store.changes_since(original["documentId"], 19)
    assert first["status"] == "more"
    assert first["nextRevision"] == 20
    assert set(first["upserts"]) == {"large-20"}
    second = store.changes_since(original["documentId"], first["nextRevision"])
    assert second["status"] == "complete"
    assert second["nextRevision"] == 21
    assert set(second["upserts"]) == {"large-21"}
    store.close()


def test_revision_feed_falls_back_on_metadata_reset_gap_and_oversize(tmp_path):
    store = NotebookStore(tmp_path / "notebook.sqlite3")
    original = sample_state()
    store.initialize(original)
    metadata = {key: copy.deepcopy(value) for key, value in original.items() if key != "strokes"}
    metadata["documentRevision"] = 20
    store.commit_batch([{
        "replace_all": False, "deletes": {"second"}, "upserts": {}, "metadata": metadata,
    }])
    assert store.changes_since(original["documentId"], 19)["deletes"] == ["second"]
    store.CHANGE_BYTE_LIMIT = 5
    assert store.changes_since(original["documentId"], 19)["status"] == "snapshot_required"
    store.CHANGE_BYTE_LIMIT = 512 * 1024
    store.CHANGE_RETENTION = 1
    metadata = copy.deepcopy(metadata)
    metadata["documentRevision"] = 21
    metadata["document"]["filename"] = "changed.pdf"
    store.commit_batch([{"replace_all": False, "deletes": set(), "upserts": {}, "metadata": metadata}])
    assert store.changes_since(original["documentId"], 20)["status"] == "snapshot_required"
    metadata["documentRevision"] = 22
    store.commit_batch([{"replace_all": True, "deletes": set(), "upserts": {}, "metadata": metadata}])
    assert store.changes_since(original["documentId"], 21)["status"] == "snapshot_required"
    assert store.changes_since(original["documentId"], 19)["status"] == "snapshot_required"
    store.close()


def test_large_mutation_records_small_snapshot_marker(tmp_path):
    store = NotebookStore(tmp_path / "notebook.sqlite3")
    original = sample_state()
    store.initialize(original)
    metadata = {key: copy.deepcopy(value) for key, value in original.items() if key != "strokes"}
    metadata["documentRevision"] = 20
    upserts = {f"stroke-{index}": {"id": f"stroke-{index}"} for index in range(129)}
    store.commit_batch([{
        "replace_all": False, "deletes": set(), "upserts": upserts, "metadata": metadata,
    }])
    row = json.loads(store.connection.execute(
        "SELECT value FROM revision_changes WHERE revision=20"
    ).fetchone()[0])
    assert row["snapshotRequired"] is True
    assert row["upsertIds"] == []
    assert store.changes_since(original["documentId"], 19)["status"] == "snapshot_required"
    assert len(store.load()["strokes"]) == 131
    store.close()


def test_revision_delta_reconstructs_current_strokes(tmp_path):
    store = NotebookStore(tmp_path / "notebook.sqlite3")
    original = sample_state()
    store.initialize(original)
    metadata = {key: copy.deepcopy(value) for key, value in original.items() if key != "strokes"}
    metadata["documentRevision"] = 20
    store.commit_batch([{
        "replace_all": False, "deletes": {"second"},
        "upserts": {"third": {"id": "third", "points": [{"x": 7}]}},
        "metadata": metadata,
    }])
    metadata = copy.deepcopy(metadata)
    metadata["documentRevision"] = 21
    store.commit_batch([{
        "replace_all": False, "deletes": set(),
        "upserts": {"first": {"id": "first", "points": [{"x": 9}]}},
        "metadata": metadata,
    }])
    delta = store.changes_since(original["documentId"], 19)
    assert delta["status"] == "complete"
    reconstructed = copy.deepcopy(original["strokes"])
    for stroke_id in delta["deletes"]:
        reconstructed.pop(stroke_id, None)
    reconstructed.update(delta["upserts"])
    assert reconstructed == store.load()["strokes"]
    store.close()


def test_process_kill_after_durable_completion_recovers_stroke(tmp_path):
    computer_dir = Path(__file__).resolve().parents[1]
    environment = os.environ.copy()
    environment["INFINITE_NOTES_DATA_DIR"] = str(tmp_path)
    code = """
import asyncio, os
import server
server.state['strokes']['acknowledged'] = {'id': 'acknowledged', 'points': [{'x': 1, 'y': 2}]}
asyncio.run(server.save_state_atomic(upsert_ids={'acknowledged'}))
os.write(1, b'COMMITTED\\n')
os._exit(0)
"""
    completed = subprocess.run(
        [sys.executable, "-c", code], cwd=computer_dir, env=environment,
        capture_output=True, timeout=20,
    )
    assert completed.returncode == 0, completed.stderr.decode()
    assert completed.stdout == b"COMMITTED\n"
    store = NotebookStore(tmp_path / "notebook.sqlite3")
    assert "acknowledged" in store.load()["strokes"]
    assert store.load()["documentRevision"] == 1
    store.close()


def test_process_kill_before_commit_does_not_publish_edit(tmp_path):
    computer_dir = Path(__file__).resolve().parents[1]
    environment = os.environ.copy()
    environment["INFINITE_NOTES_DATA_DIR"] = str(tmp_path)
    code = """
import asyncio, os
import server
async def accept_then_crash():
    server.state['strokes']['uncommitted'] = {'id': 'uncommitted', 'points': [{'x': 1, 'y': 2}]}
    server.notebook_writer().enqueue(upsert_ids={'uncommitted'})
    os.write(1, b'ACCEPTED_NOT_COMMITTED\\n')
    os._exit(0)
asyncio.run(accept_then_crash())
"""
    completed = subprocess.run(
        [sys.executable, "-c", code], cwd=computer_dir, env=environment,
        capture_output=True, timeout=20,
    )
    assert completed.returncode == 0, completed.stderr.decode()
    assert completed.stdout == b"ACCEPTED_NOT_COMMITTED\n"
    store = NotebookStore(tmp_path / "notebook.sqlite3")
    assert "uncommitted" not in store.load()["strokes"]
    assert store.load()["documentRevision"] == 0
    store.close()
