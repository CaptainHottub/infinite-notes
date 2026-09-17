"""Incremental, transactional storage for the server's notebook state.

The legacy JSON file is an import source only. SQLite is authoritative once
initialized; a failed migration leaves the JSON file untouched.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any


class NotebookStore:
    CHANGE_RETENTION = 512
    CHANGE_PAGE_LIMIT = 64
    CHANGE_BYTE_LIMIT = 512 * 1024
    CHANGE_ID_LIMIT = 128

    def __init__(self, path: Path) -> None:
        self.path = path
        self.existed_before_open = path.exists()
        path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path, check_same_thread=False)
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA synchronous=FULL")
        self.connection.execute("PRAGMA busy_timeout=5000")
        self.connection.execute("PRAGMA wal_autocheckpoint=0")
        if self.connection.execute("PRAGMA journal_mode").fetchone()[0].lower() != "wal":
            raise RuntimeError("Notebook database could not enable WAL mode")
        if self.connection.execute("PRAGMA synchronous").fetchone()[0] != 2:
            raise RuntimeError("Notebook database could not enable FULL synchronization")
        self._schema()

    def _schema(self) -> None:
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
        )
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS strokes (id TEXT PRIMARY KEY, value TEXT NOT NULL)"
        )
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS revision_changes ("
            "revision INTEGER PRIMARY KEY, document_id TEXT NOT NULL, value TEXT NOT NULL)"
        )
        self.connection.commit()

    def initialized(self) -> bool:
        return self.connection.execute(
            "SELECT 1 FROM metadata WHERE key='initialized'"
        ).fetchone() is not None

    def initialize(self, state: dict[str, Any]) -> None:
        if self.initialized():
            return
        metadata = {key: value for key, value in state.items() if key != "strokes"}
        with self.connection:
            # A previous initialization may have stopped before its marker was
            # committed. Retry from the intact legacy source as one transaction.
            self.connection.execute("DELETE FROM strokes")
            self.connection.execute("DELETE FROM metadata")
            self.connection.execute("DELETE FROM revision_changes")
            for stroke_id, stroke in state["strokes"].items():
                self.connection.execute(
                    "INSERT INTO strokes(id,value) VALUES (?,?)",
                    (stroke_id, json.dumps(stroke, ensure_ascii=False, separators=(",", ":"))),
                )
            self.connection.execute(
                "INSERT INTO metadata(key,value) VALUES ('state',?)",
                (json.dumps(metadata, ensure_ascii=False, separators=(",", ":")),),
            )
            self.connection.execute(
                "INSERT INTO metadata(key,value) VALUES ('initialized','1')"
            )

    def load(self) -> dict[str, Any]:
        row = self.connection.execute(
            "SELECT value FROM metadata WHERE key='state'"
        ).fetchone()
        if row is None or not self.initialized():
            raise ValueError("Notebook database is not initialized")
        state = json.loads(row[0])
        state["strokes"] = {
            stroke_id: json.loads(value)
            for stroke_id, value in self.connection.execute("SELECT id,value FROM strokes")
        }
        return state

    def commit(
        self,
        *,
        upserts: dict[str, dict[str, Any]],
        deletes: set[str],
        metadata: dict[str, Any],
        replace_all: bool = False,
    ) -> None:
        self.commit_batch([{
            "upserts": upserts, "deletes": deletes,
            "metadata": metadata, "replace_all": replace_all,
        }])

    def commit_batch(self, operations: list[dict[str, Any]]) -> None:
        """Apply ordered logical mutations with one durable SQLite commit."""
        with self.connection:
            previous_metadata = json.loads(self.connection.execute(
                "SELECT value FROM metadata WHERE key='state'"
            ).fetchone()[0])
            for operation in operations:
                if operation["replace_all"]:
                    self.connection.execute("DELETE FROM strokes")
                for stroke_id in operation["deletes"]:
                    self.connection.execute("DELETE FROM strokes WHERE id=?", (stroke_id,))
                for stroke_id, stroke in operation["upserts"].items():
                    self.connection.execute(
                        "INSERT INTO strokes(id,value) VALUES (?,?) "
                        "ON CONFLICT(id) DO UPDATE SET value=excluded.value",
                        (stroke_id, json.dumps(stroke, ensure_ascii=False, separators=(",", ":"))),
                    )
                metadata = operation["metadata"]
                before = {key: value for key, value in previous_metadata.items() if key != "documentRevision"}
                after = {key: value for key, value in metadata.items() if key != "documentRevision"}
                snapshot_required = (
                    operation["replace_all"] or before != after or
                    len(operation["upserts"]) + len(operation["deletes"]) > self.CHANGE_ID_LIMIT
                )
                change = {
                    "revision": metadata["documentRevision"],
                    "snapshotRequired": snapshot_required,
                    "upsertIds": [] if snapshot_required else sorted(operation["upserts"]),
                    "deletes": [] if snapshot_required else sorted(operation["deletes"]),
                }
                self.connection.execute(
                    "INSERT INTO revision_changes(revision,document_id,value) VALUES (?,?,?)",
                    (metadata["documentRevision"], metadata["documentId"],
                     json.dumps(change, ensure_ascii=False, separators=(",", ":"))),
                )
                previous_metadata = metadata
            self.connection.execute(
                "UPDATE metadata SET value=? WHERE key='state'",
                (json.dumps(operations[-1]["metadata"], ensure_ascii=False, separators=(",", ":")),),
            )
            self.connection.execute(
                "DELETE FROM revision_changes WHERE revision <= ?",
                (operations[-1]["metadata"]["documentRevision"] - self.CHANGE_RETENTION,),
            )

    def changes_since(self, document_id: str, since_revision: int) -> dict[str, Any]:
        """Return one bounded, contiguous durable page or require a full snapshot."""
        metadata = json.loads(self.connection.execute(
            "SELECT value FROM metadata WHERE key='state'"
        ).fetchone()[0])
        current = metadata["documentRevision"]
        result: dict[str, Any] = {
            "documentId": metadata["documentId"], "documentRevision": current,
            "fromRevision": since_revision,
        }
        if document_id != metadata["documentId"] or since_revision > current:
            return {**result, "status": "snapshot_required"}
        if since_revision == current:
            return {**result, "status": "complete", "upserts": {}, "deletes": [], "nextRevision": current}
        rows = self.connection.execute(
            "SELECT revision,value FROM revision_changes WHERE revision > ? "
            "ORDER BY revision LIMIT ?",
            (since_revision, self.CHANGE_PAGE_LIMIT + 1),
        ).fetchall()
        touched_ids: set[str] = set()
        expected_revision = since_revision + 1
        for revision, encoded in rows[:self.CHANGE_PAGE_LIMIT]:
            if revision != expected_revision:
                return {**result, "status": "snapshot_required"}
            change = json.loads(encoded)
            if change["snapshotRequired"]:
                if expected_revision == since_revision + 1:
                    return {**result, "status": "snapshot_required"}
                break
            touched_ids.update(change["upsertIds"])
            touched_ids.update(change["deletes"])
            expected_revision += 1
        if expected_revision == since_revision + 1:
            return {**result, "status": "snapshot_required"}
        upserts: dict[str, dict[str, Any]] = {}
        deletes: list[str] = []
        byte_count = 0
        for stroke_id in sorted(touched_ids):
            row = self.connection.execute(
                "SELECT value FROM strokes WHERE id=?", (stroke_id,)
            ).fetchone()
            if row is None:
                deletes.append(stroke_id)
                byte_count += len(stroke_id.encode("utf-8")) + 4
            else:
                upserts[stroke_id] = json.loads(row[0])
                byte_count += len(stroke_id.encode("utf-8")) + len(row[0].encode("utf-8")) + 8
            if byte_count > self.CHANGE_BYTE_LIMIT:
                return {**result, "status": "snapshot_required"}
        next_revision = expected_revision - 1
        return {
            **result, "status": "complete" if next_revision == current else "more",
            "upserts": upserts, "deletes": deletes, "nextRevision": next_revision,
        }

    def checkpoint(self) -> None:
        self.connection.execute("PRAGMA wal_checkpoint(PASSIVE)")

    def close(self) -> None:
        self.connection.close()
