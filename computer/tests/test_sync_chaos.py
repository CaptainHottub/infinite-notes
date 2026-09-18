import pytest

from tools.sync_chaos import run_scenario


@pytest.mark.parametrize("seed", [17, 23])
def test_real_process_reconnect_and_crash_recovery(tmp_path, seed):
    result = run_scenario(tmp_path, seed=seed, initial_strokes=16, cycles=2, points=4)
    assert result["restarts"] == 3
    assert result["deltaChecks"] == 2
    assert result["lostAckReplays"] == 2
    assert result["liveObserverChecks"] == 2
    assert result["finalStrokes"] == 16 + 2 * 77
    assert result["legacyUnchanged"]


def test_harness_refuses_to_reuse_existing_notebook(tmp_path):
    notebook = tmp_path / "notebook"
    notebook.mkdir()
    sentinel = notebook / "state.json"
    sentinel.write_text("existing notebook")
    with pytest.raises(FileExistsError):
        run_scenario(tmp_path, initial_strokes=1, cycles=1, points=1)
    assert sentinel.read_text() == "existing notebook"
