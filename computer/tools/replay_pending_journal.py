"""One-time, verified replay of backed-up iPad strokes into a stopped server.

Dry-run by default. Never reads the iPad directly or removes journal files.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sqlite3
import sys
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--journal-root", type=Path, required=True)
    parser.add_argument("--expected-revision", type=int, required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    database = args.data_dir / "notebook.sqlite3"
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        metadata = json.loads(connection.execute(
            "SELECT value FROM metadata WHERE key='state'"
        ).fetchone()[0])
        document_id = metadata["documentId"]
        revision = metadata["documentRevision"]
        if revision != args.expected_revision:
            raise SystemExit(f"Expected revision {args.expected_revision}, found {revision}; no changes made")
        folder = args.journal_root / document_id
        files = sorted(folder.glob("*.json"))
        if not files:
            raise SystemExit(f"No saved strokes found for document {document_id}; no changes made")
        strokes = []
        seen: set[str] = set()
        for file in files:
            record = json.loads(file.read_text(encoding="utf-8"))
            stroke_id = record["id"]
            expected_name = base64.urlsafe_b64encode(stroke_id.encode()).decode() + ".json"
            if (record["version"] != 1 or record["documentID"] != document_id
                    or file.name != expected_name or record["value"]["id"] != stroke_id
                    or stroke_id in seen):
                raise SystemExit(f"Inconsistent backed-up journal record {file.name}; no changes made")
            seen.add(stroke_id)
            strokes.append(record["value"])
        already_present = connection.execute(
            f"SELECT COUNT(*) FROM strokes WHERE id IN ({','.join('?' for _ in seen)})",
            tuple(seen),
        ).fetchone()[0]
        if already_present:
            raise SystemExit(f"{already_present} journal strokes already exist; no changes made")
    finally:
        connection.close()

    print(f"Preflight: {len(strokes)} valid saved strokes, document {document_id}, revision {revision}")
    if not args.apply:
        print("Dry run only; pass --apply to commit the backed-up strokes")
        return

    os.environ["INFINITE_NOTES_DATA_DIR"] = str(args.data_dir.resolve())
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from fastapi.testclient import TestClient
    from server import app

    strokes.sort(key=lambda stroke: (
        stroke.get("points", [{}])[0].get("t", 0) if stroke.get("points") else 0,
        stroke["id"],
    ))
    with TestClient(app) as client:
        with client.websocket_connect("/ws?role=ipad&clientId=native-journal-recovery") as socket:
            initial = socket.receive_json()
            socket.receive_json()  # history state
            if initial.get("documentId") != document_id:
                raise RuntimeError("Server document changed during recovery")
            for start in range(0, len(strokes), 12):
                batch = strokes[start:start + 12]
                ids = [stroke["id"] for stroke in batch]
                socket.send_json({
                    "type": "reconcile_strokes", "documentId": document_id, "strokes": batch,
                })
                while True:
                    reply = socket.receive_json()
                    if reply.get("type") == "error":
                        raise RuntimeError(f"Server rejected recovery batch: {reply.get('message')}")
                    if reply.get("type") == "reconcile_ack":
                        if reply.get("ids") != ids:
                            raise RuntimeError("Server acknowledged the wrong recovery IDs")
                        break

    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        restored = connection.execute(
            f"SELECT COUNT(*) FROM strokes WHERE id IN ({','.join('?' for _ in seen)})",
            tuple(seen),
        ).fetchone()[0]
        final_revision = json.loads(connection.execute(
            "SELECT value FROM metadata WHERE key='state'"
        ).fetchone()[0])["documentRevision"]
    finally:
        connection.close()
    if restored != len(strokes):
        raise RuntimeError(f"Recovery incomplete: {restored}/{len(strokes)} strokes present")
    print(f"Recovered {restored} strokes; document revision is now {final_revision}")


if __name__ == "__main__":
    main()
