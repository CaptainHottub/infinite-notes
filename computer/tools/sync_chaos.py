"""Real-process reconnect/crash exercise using only generated temporary notebooks."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import random
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.error import URLError
from urllib.request import ProxyHandler, build_opener
import uuid

from websockets.sync.client import connect


COMPUTER_DIR = Path(__file__).resolve().parents[1]
LOCAL_HTTP = build_opener(ProxyHandler({}))


class TemporaryServer:
    def __init__(self, root: Path):
        self.root = root
        self.process = None
        self.log = (root / "server.log").open("w+b")
        self.url = ""

    def start(self):
        environment = os.environ.copy()
        environment["INFINITE_NOTES_DATA_DIR"] = str(self.root / "notebook")
        environment.pop("INFINITE_NOTES_DEBUG", None)
        environment.pop("INFINITE_NOTES_DISCOVERY_PORT", None)
        # Inherit the bound socket so another process cannot take its port.
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(128)
            self.url = f"http://127.0.0.1:{listener.getsockname()[1]}"
            self.process = subprocess.Popen(
                [sys.executable, "-m", "uvicorn", "server:app", "--fd", str(listener.fileno()),
                 "--log-level", "warning", "--no-access-log"],
                cwd=COMPUTER_DIR, env=environment, pass_fds=(listener.fileno(),),
                stdout=self.log, stderr=self.log,
            )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                break
            try:
                with LOCAL_HTTP.open(self.url + "/", timeout=0.25) as response:
                    if response.status == 200:
                        return
            except (URLError, TimeoutError):
                time.sleep(0.05)
        self.log.flush()
        self.log.seek(0)
        raise RuntimeError("Test server did not start: " + self.log.read().decode(errors="replace")[-4000:])

    def stop(self, *, crash=False):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.kill() if crash else self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
            self.process = None

    def state(self):
        return self.get("/api/state")

    def get(self, path):
        with LOCAL_HTTP.open(self.url + path, timeout=10) as response:
            return json.load(response)

    def client(self):
        ws = connect(self.url.replace("http://", "ws://") + "/ws?role=ipad&clientId=native-chaos",
                     open_timeout=5, close_timeout=0.2, max_size=2 * 1024 * 1024, proxy=None)
        initial = receive(ws, "state_refresh")
        receive(ws, "history_state")
        return ws, initial


def receive(ws, kind):
    deadline = time.monotonic() + 10
    for _ in range(1024):
        message = json.loads(ws.recv(timeout=max(0.01, deadline - time.monotonic())))
        if message["type"] == "error":
            raise AssertionError(message)
        if message["type"] == kind:
            return message
    raise AssertionError(f"Too many messages while waiting for {kind}")


def send(ws, kind, **fields):
    ws.send(json.dumps({"type": kind, **fields}))


def stroke(stroke_id, rng, point_count):
    return {
        "id": stroke_id, "owner": "native-chaos", "tool": "pen", "color": "#111111",
        "width": 1.0, "opacity": 1.0, "smoothing": 0.0, "strokeDetail": 100.0,
        "lineStyle": "solid", "locked": False,
        "points": [{"x": float(rng.randrange(1000)), "y": float(rng.randrange(1000)),
                    "p": 0.5, "t": float(index)} for index in range(point_count)],
    }


class LiveObserver:
    """Independent replica driven only by live frames, never repaired by snapshots."""
    def __init__(self, server, initial_strokes):
        self.ws, _ = server.client()
        self.strokes = copy.deepcopy(initial_strokes)
        self.condition = threading.Condition()
        self.failure = None
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def read(self):
        try:
            for text in self.ws:
                message = json.loads(text)
                with self.condition:
                    kind = message["type"]
                    if kind == "stroke_begin":
                        self.strokes[message["stroke"]["id"]] = message["stroke"]
                    elif kind == "stroke_points":
                        self.strokes[message["id"]]["points"].extend(message["points"])
                    elif kind in {"restore_strokes", "replace_strokes"}:
                        self.strokes.update({value["id"]: value for value in message["strokes"]})
                    elif kind == "delete_strokes":
                        for stroke_id in message["ids"]:
                            self.strokes.pop(stroke_id, None)
                    elif kind == "clear_strokes":
                        self.strokes.clear()
                    elif kind in {"error", "state_refresh"}:
                        raise AssertionError(f"Unexpected observer message: {message}")
                    self.condition.notify_all()
        except Exception as exc:
            with self.condition:
                self.failure = exc
                self.condition.notify_all()

    def check(self, expected):
        with self.condition:
            assert self.condition.wait_for(
                lambda: self.failure is not None or self.strokes == expected, timeout=10
            ), "Live observer diverged from the expected notebook"
            if self.failure is not None:
                raise self.failure

    def close(self):
        self.ws.close()
        self.thread.join(timeout=3)
        assert not self.thread.is_alive(), "Observer did not stop"


def reconcile(ws, document_id, strokes):
    send(ws, "reconcile_strokes", documentId=document_id, strokes=strokes)
    ack = receive(ws, "reconcile_ack")
    assert ack["documentId"] == document_id
    assert ack["ids"] == [value["id"] for value in strokes]
    return ack


def check_delta(server, before, expected):
    reconstructed = copy.deepcopy(before["strokes"])
    cursor = before["documentRevision"]
    for _ in range(9):
        page = server.get(f"/api/changes?documentId={before['documentId']}&sinceRevision={cursor}")
        if page["status"] == "snapshot_required":
            assert server.state()["strokes"] == expected
            return False
        assert page["fromRevision"] == cursor
        for stroke_id in page["deletes"]:
            reconstructed.pop(stroke_id, None)
        reconstructed.update(page["upserts"])
        if page["status"] == "complete":
            assert reconstructed == expected
            return True
        assert page["nextRevision"] > cursor
        cursor = page["nextRevision"]
    raise AssertionError("Delta pagination did not terminate")


def run_scenario(root: Path, *, seed=17, initial_strokes=2400, cycles=12, points=192):
    rng = random.Random(seed)
    data_dir = root / "notebook"
    data_dir.mkdir()  # Refuse to reuse an existing notebook directory.
    document_id = str(uuid.uuid4())
    expected = {f"seed-{index}": stroke(f"seed-{index}", rng, points)
                for index in range(initial_strokes)}
    legacy = data_dir / "state.json"
    legacy.write_text(json.dumps({
        "version": 1, "documentId": document_id, "documentRevision": 0,
        "document": {"filename": None, "pages": []}, "strokes": expected,
    }), encoding="utf-8")
    legacy_digest = hashlib.sha256(legacy.read_bytes()).digest()
    server = TemporaryServer(root)
    observer = None
    started = time.monotonic()
    counts = {"cycles": cycles, "restarts": 0, "deltaChecks": 0, "lostAckReplays": 0,
              "liveObserverChecks": 0, "snapshotFallbacks": 0}
    try:
        server.start()
        baseline = server.state()
        for cycle in range(cycles):
            before = server.state()
            assert before["strokes"] == expected
            observer = LiveObserver(server, expected)
            ws, _ = server.client()
            with ws:
                # A full batch exercises the ordinary 2.5 s writer, without
                # sleeping through the collection window for every stroke.
                batch = [stroke(f"burst-{cycle}-{index}", rng, points) for index in range(64)]
                for value in batch:
                    send(ws, "stroke_begin", stroke={**value, "points": value["points"][:1]},
                         documentId=document_id)
                    for start in range(1, len(value["points"]), 32):
                        send(ws, "stroke_points", id=value["id"],
                             points=value["points"][start:start + 32], documentId=document_id)
                    send(ws, "stroke_end", id=value["id"], documentId=document_id)
                acknowledged = set()
                for _ in batch:
                    ack = receive(ws, "stroke_ack")
                    acknowledged.update(ack["ids"])
                assert acknowledged == {value["id"] for value in batch}
                expected.update({value["id"]: value for value in batch})

                # Lose an ACK at the application boundary, retaining the same
                # completed-stroke journal for replay on the next connection.
                offline = [stroke(f"offline-{cycle}-{index}", rng, points) for index in range(12)]
                ignored_ack = reconcile(ws, document_id, offline)
                expected.update({value["id"]: value for value in offline})
            ws, _ = server.client()
            with ws:
                replay = reconcile(ws, document_id, offline)
                assert replay["documentRevision"] == ignored_ack["documentRevision"]
                counts["lostAckReplays"] += 1

                partial = stroke(f"interrupted-{cycle}", rng, points)
                send(ws, "stroke_begin", stroke={**partial, "points": partial["points"][:1]},
                     documentId=document_id)
                send(ws, "ping", clientTime=cycle)
                receive(ws, "pong")
            ws, _ = server.client()
            with ws:
                reconcile(ws, document_id, [partial])
                expected[partial["id"]] = partial
                victim = rng.choice(list(expected))
                send(ws, "delete_strokes", ids=[victim], final=True)
                receive(ws, "delete_ack")
                removed = expected.pop(victim)
                send(ws, "undo")
                restored = receive(ws, "restore_strokes")
                assert restored["strokes"] == [removed]
                send(ws, "redo")
                assert receive(ws, "delete_strokes")["ids"] == [victim]
            assert server.state()["strokes"] == expected
            if check_delta(server, before, expected):
                counts["deltaChecks"] += 1
            else:
                counts["snapshotFallbacks"] += 1
            observer.check(expected)
            counts["liveObserverChecks"] += 1
            observer.close()
            observer = None

            # Kill the real process after accepting stroke_end but without
            # waiting for an ACK. Either durable outcome must replay correctly.
            ws, old_summary = server.client()
            unacknowledged = stroke(f"crash-{cycle}", rng, points)
            try:
                send(ws, "stroke_begin", stroke=unacknowledged, documentId=document_id)
                send(ws, "stroke_end", id=unacknowledged["id"], documentId=document_id)
                send(ws, "ping", clientTime=cycle)
                receive(ws, "pong")
                server.stop(crash=True)
            finally:
                ws.close()
            server.start()
            counts["restarts"] += 1
            ws, summary = server.client()
            with ws:
                assert summary["documentId"] == document_id
                assert summary["stateToken"].split(":")[0] != old_summary["stateToken"].split(":")[0]
                reconcile(ws, document_id, [unacknowledged])
            expected[unacknowledged["id"]] = unacknowledged
            after = server.state()
            assert after["strokes"] == expected
            assert after["documentRevision"] > before["documentRevision"]

        durable = server.state()
        server.stop(crash=True)
        server.start()
        counts["restarts"] += 1
        recovered = server.state()
        assert recovered["strokes"] == expected
        assert recovered["documentRevision"] == durable["documentRevision"]
        counts["snapshotFallbacks"] += int(not check_delta(server, baseline, expected))
        assert hashlib.sha256(legacy.read_bytes()).digest() == legacy_digest
        return {**counts, "seed": seed, "initialStrokes": initial_strokes,
                "finalStrokes": len(expected), "revision": recovered["documentRevision"],
                "legacyBytes": legacy.stat().st_size, "legacyUnchanged": True,
                "elapsedSeconds": round(time.monotonic() - started, 2)}
    finally:
        try:
            if observer is not None:
                observer.close()
        finally:
            server.stop()
            server.log.close()


def positive(raw):
    value = int(raw)
    if value < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--initial-strokes", type=positive, default=2400)
    parser.add_argument("--cycles", type=positive, default=12)
    parser.add_argument("--points", type=positive, default=192)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="infinite-notes-chaos-") as directory:
        print(json.dumps(run_scenario(Path(directory), seed=args.seed,
            initial_strokes=args.initial_strokes, cycles=args.cycles, points=args.points)))


if __name__ == "__main__":
    main()
