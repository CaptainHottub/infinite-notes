from __future__ import annotations

from pathlib import Path

import server


def test_parse_args_defaults_to_debug_disabled() -> None:
    args = server.parse_args([])
    assert args.host == "0.0.0.0"
    assert args.port == 8000
    assert args.reload is False
    assert args.debug is False


def test_parse_args_accepts_debug_with_existing_options() -> None:
    args = server.parse_args(["--debug", "--reload", "--host", "127.0.0.1", "--port", "9000"])
    assert args.debug is True
    assert args.reload is True
    assert args.host == "127.0.0.1"
    assert args.port == 9000


def test_launch_scripts_forward_debug_without_special_case_in_wrapper() -> None:
    root = Path(__file__).resolve().parents[2]
    launcher = (root / "computer/run.sh").read_text(encoding="utf-8")
    wrapper = (root / "scripts/run-computer.sh").read_text(encoding="utf-8")

    assert "--debug) debug=true" in launcher
    assert "server_args+=(--debug)" in launcher
    assert '"$ROOT/computer/run-native.sh" "$@"' in wrapper


def test_debug_metadata_is_only_added_to_initial_native_refresh(monkeypatch) -> None:
    class StubDebugLog:
        enabled = True
        session_id = "a" * 32

    monkeypatch.setattr(server, "debug_log", StubDebugLog())

    initial = server.state_refresh_message(reason="initial")
    later = server.state_refresh_message(reason="manual_sync")

    assert initial["debugEnabled"] is True
    assert initial["sessionId"] == "a" * 32
    assert "debugEnabled" not in later
    assert "sessionId" not in later


def test_initial_refresh_explicitly_disables_debug_when_server_is_not_debugging(
    monkeypatch,
) -> None:
    class StubDebugLog:
        enabled = False
        session_id = None

    monkeypatch.setattr(server, "debug_log", StubDebugLog())

    initial = server.state_refresh_message(reason="initial")
    assert initial["debugEnabled"] is False
    assert "sessionId" not in initial
