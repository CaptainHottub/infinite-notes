"""Synthetic SQLite persistence benchmark; uses only temporary directories."""

from __future__ import annotations

import copy
import json
import os
import statistics
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from persistence import NotebookStore


def process_write_bytes() -> int | None:
    try:
        for line in Path("/proc/self/io").read_text().splitlines():
            if line.startswith("write_bytes:"):
                return int(line.split()[1])
    except OSError:
        pass
    return None


def metadata(revision: int) -> dict:
    return {
        "version": 1,
        "documentId": "8c1c613c-7970-4168-9b94-9d779464a15a",
        "documentRevision": revision,
        "document": {"filename": "synthetic.pdf", "pages": []},
    }


def stroke(index: int) -> dict:
    return {"id": f"stroke-{index}", "points": [{"x": index, "y": index}],
            "payload": "x" * 11800}


def run(count: int) -> None:
    with tempfile.TemporaryDirectory(prefix="infinite-notes-persistence-bench-") as name:
        root = Path(name)
        source = {**metadata(0), "strokes": {f"stroke-{i}": stroke(i) for i in range(count)}}
        legacy = root / "state.json"
        legacy.write_text(json.dumps(source, separators=(",", ":")))
        legacy_size = legacy.stat().st_size
        store = NotebookStore(root / "notebook.sqlite3")
        started = time.perf_counter()
        store.initialize(source)
        migration_ms = (time.perf_counter() - started) * 1000
        revision = 0

        def measure(operations):
            before_io = process_write_bytes()
            before_wal = (root / "notebook.sqlite3-wal").stat().st_size
            started_commit = time.perf_counter()
            store.commit_batch(operations)
            elapsed = (time.perf_counter() - started_commit) * 1000
            after_io = process_write_bytes()
            after_wal = (root / "notebook.sqlite3-wal").stat().st_size
            return elapsed, after_wal - before_wal, (
                after_io - before_io if before_io is not None and after_io is not None else None
            )

        single_times = []
        single_wal = []
        single_os = []
        for index in range(10):
            revision += 1
            changed = copy.deepcopy(source["strokes"][f"stroke-{index}"])
            changed["points"].append({"x": index + 1, "y": index + 1})
            elapsed, wal, os_bytes = measure([{"upserts": {changed["id"]: changed},
                                               "deletes": set(), "replace_all": False,
                                               "metadata": metadata(revision)}])
            single_times.append(elapsed)
            single_wal.append(wal)
            single_os.append(os_bytes)

        burst = []
        for index in range(10, 74):
            revision += 1
            changed = copy.deepcopy(source["strokes"][f"stroke-{index}"])
            changed["points"].append({"x": index + 1, "y": index + 1})
            burst.append({"upserts": {changed["id"]: changed}, "deletes": set(),
                          "replace_all": False, "metadata": metadata(revision)})
        burst_ms, burst_wal, burst_os = measure(burst)

        revision += 1
        delete_ms, delete_wal, delete_os = measure([{
            "upserts": {}, "deletes": {f"stroke-{i}" for i in range(20)},
            "replace_all": False, "metadata": metadata(revision),
        }])
        assert legacy.stat().st_size == legacy_size
        assert len(store.load()["strokes"]) == count - 20
        store.close()
        print(json.dumps({
            "strokes": count, "legacyBytes": legacy_size, "migrationMs": round(migration_ms, 1),
            "singleCommitCount": 10,
            "singleCommitP50Ms": round(statistics.median(single_times), 2),
            "singleCommitP95Ms": round(sorted(single_times)[-1], 2),
            "singleWalGrowthMedianBytes": statistics.median(single_wal),
            "singleOsWriteMedianBytes": statistics.median(single_os) if None not in single_os else None,
            "burstOperations": 64, "burstCommitCount": 1,
            "burstCommitMs": round(burst_ms, 2), "burstWalGrowthBytes": burst_wal,
            "burstOsWriteBytes": burst_os,
            "deleteCount": 20, "deleteCommitMs": round(delete_ms, 2),
            "deleteWalGrowthBytes": delete_wal, "deleteOsWriteBytes": delete_os,
        }))


if __name__ == "__main__":
    for size in (2400, 4800):
        run(size)
