from __future__ import annotations

import io
import json
import plistlib
import threading
from pathlib import Path
from unittest.mock import patch

import debug_logging
from debug_logging import DebugEventLogger, protocol_summary, sanitize_fields


class _TTYBuffer(io.StringIO):
    def isatty(self) -> bool:
        return True


class _UnreadableStroke(dict):
    def get(self, key, default=None):
        if key == "points":
            raise AssertionError("protocol summary walked nested stroke points")
        return super().get(key, default)


class _PausedWriterLogger(DebugEventLogger):
    def __init__(self, *args, **kwargs) -> None:
        self.writer_gate = threading.Event()
        super().__init__(*args, **kwargs)

    def _writer(self) -> None:
        self.writer_gate.wait(2.0)


def _read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def test_disabled_logger_creates_no_directory_and_skips_protocol_summary(tmp_path: Path) -> None:
    logs_dir = tmp_path / "logs"
    logger = DebugEventLogger(enabled=False, logs_dir=logs_dir)

    with patch.object(debug_logging, "protocol_summary", side_effect=AssertionError("called")):
        logger.protocol("rx", {"type": "snapshot", "state": {}}, byte_count=1_000_000)
    logger.event("sync", "ignored", stateToken="token")
    logger.close()

    assert logger.session_id is None
    assert not logs_dir.exists()


def test_session_id_and_sequence_are_stable_and_close_records_session_end(tmp_path: Path) -> None:
    logger = DebugEventLogger(enabled=True, logs_dir=tmp_path)
    session_id = logger.session_id
    logger.event("lifecycle", "session_started")
    logger.event("sync", "request_completed", stateToken="server:2")
    logger.close()

    assert session_id is not None
    assert len(session_id) == 32
    assert logger.jsonl_path is not None
    records = _read_jsonl(logger.jsonl_path)
    assert [record["eventSequence"] for record in records] == list(range(1, len(records) + 1))
    assert {record["sessionId"] for record in records} == {session_id}
    assert records[-1]["event"] == "session_ended"


def test_sanitization_never_descends_into_content_containers() -> None:
    secret = "PRIVATE-NOTE-CONTENT"
    sanitized = sanitize_fields(
        {
            "safe": "ok",
            "text": secret,
            "sessionId": "attacker-controlled",
            "eventSequence": 999,
            "metadata": {"nested": {"text": secret}},
            "items": [{"content": secret}, "visible"],
            "binary": secret.encode(),
        }
    )

    encoded = json.dumps(sanitized)
    assert sanitized["safe"] == "ok"
    assert "text" not in sanitized
    assert "sessionId" not in sanitized
    assert "eventSequence" not in sanitized
    assert secret not in encoded
    assert sanitized["metadata"] == "<redacted:object>"
    assert sanitized["items"] == ["<redacted:item>", "visible"]
    assert sanitized["binary"] == "<redacted:binary>"


def test_protocol_summary_uses_counts_without_walking_nested_points() -> None:
    message = {
        "type": "reconcile_strokes",
        "operationId": "operation-7",
        "strokes": [_UnreadableStroke({"id": "stroke-1", "points": [1, 2, 3]})],
    }

    assert protocol_summary(message) == {
        "messageType": "reconcile_strokes",
        "operationId": "operation-7",
        "strokeCount": 1,
    }
    assert protocol_summary({
        "type": "stroke_points",
        "id": "s",
        "points": [1, 2],
        "documentId": "de305d54-75b4-431b-adb2-eb6b9e546014",
        "documentRevision": 7,
    }) == {
        "messageType": "stroke_points",
        "strokeId": "s",
        "pointCount": 2,
        "documentId": "de305d54-75b4-431b-adb2-eb6b9e546014",
        "documentRevision": 7,
    }
    assert protocol_summary(None) == {"messageType": "invalid"}


def test_protocol_summary_does_not_stringify_hostile_containers() -> None:
    secret = "PRIVATE-NOTE-CONTENT"
    summary = protocol_summary(
        {
            "type": {"text": secret},
            "id": {"content": secret},
            "reason": [secret],
            "points": [1, 2, 3],
        }
    )

    assert summary == {"messageType": "unknown", "pointCount": 3}
    assert secret not in json.dumps(summary)


def test_event_queue_is_bounded_and_drops_diagnostics_instead_of_blocking(tmp_path: Path) -> None:
    logger = _PausedWriterLogger(enabled=True, logs_dir=tmp_path, queue_capacity=2)
    logger.event("protocol", "one")
    logger.event("protocol", "two")
    logger.event("protocol", "three")

    assert logger._queue.maxsize == 2
    assert logger._queue.qsize() == 2
    assert logger.dropped_event_count == 1

    logger.writer_gate.set()
    assert logger._thread is not None
    logger._thread.join(2.0)
    logger.close()


def test_text_and_jsonl_logs_rotate_with_bounded_backups(tmp_path: Path) -> None:
    logger = DebugEventLogger(
        enabled=True,
        logs_dir=tmp_path,
        max_bytes=512,
        backup_count=2,
    )
    for index in range(80):
        logger.event("sync", "rotation_probe", index=index, detail="x" * 80)
    logger.close(timeout=5.0)

    assert logger.text_path is not None
    assert logger.jsonl_path is not None
    for path in (logger.text_path, logger.jsonl_path):
        related = sorted(tmp_path.glob(f"{path.name}*"))
        assert path in related
        assert path.with_name(f"{path.name}.1") in related
        assert len(related) <= 3
        assert not path.with_name(f"{path.name}.3").exists()


def test_terminal_colors_are_tty_only_and_files_remain_plain(tmp_path: Path) -> None:
    terminal = _TTYBuffer()
    with patch.object(debug_logging.sys, "stdout", terminal):
        logger = DebugEventLogger(enabled=True, logs_dir=tmp_path)
        logger.event("connection", "connected")
        logger.close()

    assert "\033[" in terminal.getvalue()
    assert logger.text_path is not None
    assert "\033[" not in logger.text_path.read_text(encoding="utf-8")


def test_logger_io_failure_never_escapes_to_product_code(tmp_path: Path) -> None:
    not_a_directory = tmp_path / "blocked"
    not_a_directory.write_text("file", encoding="utf-8")
    logger = DebugEventLogger(enabled=True, logs_dir=not_a_directory)

    for _ in range(20):
        logger.event("sync", "still_safe")
    logger.close()


def test_ipad_debug_contract_avoids_second_decode_and_unbounded_dispatch() -> None:
    root = Path(__file__).resolve().parents[2]
    app_model = (root / "ipad/Sources/InfiniteNotesStrokeLab/AppModel.swift").read_text()
    logger = (root / "ipad/Sources/InfiniteNotesStrokeLab/DebugSessionLogger.swift").read_text()
    handler = app_model.split("private func handleServerText", 1)[1].split(
        "private func handle(", 1
    )[0]

    assert "JSONSerialization.jsonObject" not in handler
    assert "DebugSessionLogger.shared.protocolEvent(" in handler
    assert 'direction: "rx"' in handler
    assert "envelope: message" in handler
    assert "maximumPendingEvents" in logger
    assert "pendingEvents.count < maximumPendingEvents" in logger
    assert "strokes.reduce" not in logger


def test_ipad_debug_logs_are_in_shared_documents_without_sharing_journal() -> None:
    root = Path(__file__).resolve().parents[2] / "ipad"
    plist = plistlib.loads((root / "Info.plist").read_bytes())
    logger = (root / "Sources/InfiniteNotesStrokeLab/DebugSessionLogger.swift").read_text()
    journal = (root / "Sources/InfiniteNotesStrokeLab/AppModel.swift").read_text()

    assert plist["UIFileSharingEnabled"] is True
    assert plist["LSSupportsOpeningDocumentsInPlace"] is True
    append = logger.split("private func append(record:", 1)[1]
    assert "for: .documentDirectory" in append
    assert '.appendingPathComponent("InfiniteNotes", isDirectory: true)' in append
    assert '.appendingPathComponent("Logs", isDirectory: true)' in append
    assert "for: .applicationSupportDirectory" in journal
