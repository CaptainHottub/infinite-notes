"""Synthetic native-WebSocket ACK benchmark; never accesses live notebook data."""

from __future__ import annotations

import json
import os
import statistics
import sys
import tempfile
import time
import uuid
from pathlib import Path


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round((len(ordered) - 1) * fraction))]


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="infinite-notes-server-bench-") as name:
        root = Path(name)
        state = {
            "version": 1, "documentId": str(uuid.uuid4()), "documentRevision": 0,
            "document": {"filename": None, "pages": []},
            "strokes": {
                f"old-{index}": {"id": f"old-{index}", "points": [{"x": index, "y": index}],
                                 "payload": "x" * 11800}
                for index in range(2400)
            },
        }
        legacy = root / "state.json"
        legacy.write_text(json.dumps(state, separators=(",", ":")))
        os.environ["INFINITE_NOTES_DATA_DIR"] = str(root)
        os.environ.pop("INFINITE_NOTES_DEBUG", None)

        sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        import server
        from fastapi.testclient import TestClient

        commits = []
        original_commit = server.notebook_store.commit_batch

        def recorded_commit(operations):
            commits.append(len(operations))
            return original_commit(operations)

        server.notebook_store.commit_batch = recorded_commit
        sent_at = {}
        latencies = []
        with TestClient(server.app) as client:
            with client.websocket_connect("/ws?role=ipad&clientId=native-benchmark") as socket:
                assert socket.receive_json()["type"] == "state_refresh"
                assert socket.receive_json()["type"] == "history_state"
                for index in range(64):
                    stroke_id = f"new-{index}"
                    stroke = {
                        "id": stroke_id, "owner": "native-benchmark", "tool": "pen",
                        "color": "#111111", "width": 1, "opacity": 1,
                        "smoothing": 0, "points": [{"x": index, "y": index, "p": 0.5, "t": index}],
                    }
                    socket.send_json({"type": "stroke_begin", "stroke": stroke})
                    sent_at[stroke_id] = time.perf_counter()
                    socket.send_json({"type": "stroke_end", "id": stroke_id})
                while len(latencies) < 64:
                    message = socket.receive_json()
                    if message["type"] == "stroke_ack":
                        latencies.append((time.perf_counter() - sent_at[message["ids"][0]]) * 1000)
                single = {
                    "id": "single-after-burst", "owner": "native-benchmark", "tool": "pen",
                    "color": "#111111", "width": 1, "opacity": 1,
                    "smoothing": 0, "points": [{"x": 1, "y": 1, "p": 0.5, "t": 1}],
                }
                socket.send_json({"type": "stroke_begin", "stroke": single})
                single_started = time.perf_counter()
                socket.send_json({"type": "stroke_end", "id": single["id"]})
                while True:
                    message = socket.receive_json()
                    if message["type"] == "stroke_ack" and single["id"] in message["ids"]:
                        single_ack_ms = (time.perf_counter() - single_started) * 1000
                        break

        print(json.dumps({
            "legacyBytes": legacy.stat().st_size,
            "strokeCountBefore": 2400,
            "burstStrokeCount": 64,
            "commitCount": len(commits),
            "operationsPerCommit": commits,
            "ackP50Ms": round(percentile(latencies, 0.5), 2),
            "ackP95Ms": round(percentile(latencies, 0.95), 2),
            "singleAckMs": round(single_ack_ms, 2),
            "legacyFileUnchanged": legacy.read_text() == json.dumps(state, separators=(",", ":")),
        }))


if __name__ == "__main__":
    main()
