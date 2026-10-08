import json
import subprocess
from pathlib import Path

import pytest

from page_layout import reflow_stroke, stored_stroke, world_stroke
from persistence import NotebookStore


def layouts():
    old = [{"id": "a", "x": 0, "y": 0, "width": 200, "height": 150},
           {"id": "b", "x": 0, "y": 150, "width": 200, "height": 200}]
    new = [old[0], {"id": "added", "x": 0, "y": 150, "width": 400, "height": 180},
           {**old[1], "y": 330}]
    stroke = {"id": "ink", "pageId": "b", "pageIndex": 1,
              "points": [{"x": -100, "y": 170, "x_raw": -101, "y_raw": 171, "p": 0.8, "t": 1}]}
    return old, new, stroke


def test_page_local_record_is_identical_across_layouts_and_offpage_ink():
    old, new, stroke = layouts()
    shifted = reflow_stroke(stroke, old, new)
    assert shifted["points"][0]["y"] == 350
    assert shifted["points"][0]["x_local"] == -100
    assert stored_stroke(stroke, old) == stored_stroke(shifted, new)
    assert world_stroke(stored_stroke(shifted, new), new) == shifted
    assert reflow_stroke(shifted, new, [old[0]]) is None
    assert stroke["points"][0]["y"] == 170


def test_local_storage_reopens_and_projects_changes_using_current_layout(tmp_path):
    old, new, stroke = layouts()
    metadata = {"documentId": "doc", "documentRevision": 1, "pageIdentityVersion": 1,
                "document": {"filename": "notes.pdf", "pages": old}}
    path = tmp_path / "notebook.sqlite3"
    store = NotebookStore(path)
    store.initialize({**metadata, "strokes": {"ink": stroke}})
    original = store.connection.execute("SELECT value FROM strokes WHERE id='ink'").fetchone()[0]
    assert json.loads(original)["points"][0]["y"] == 20
    updated_metadata = {**metadata, "documentRevision": 2, "document": {"filename": "notes.pdf", "pages": new}}
    store.commit(upserts={}, deletes=set(), metadata=updated_metadata)
    assert store.connection.execute("SELECT value FROM strokes WHERE id='ink'").fetchone()[0] == original
    store.close()
    store = NotebookStore(path)
    assert store.load()["strokes"]["ink"]["points"][0]["y"] == 350
    shifted = reflow_stroke(stroke, old, new)
    store.commit(upserts={"ink": shifted}, deletes=set(), metadata={**updated_metadata, "documentRevision": 3})
    delta = store.changes_since("doc", 2)
    assert delta["upserts"]["ink"]["points"][0]["y"] == 350
    store.close()


def test_browser_layout_projection_matches_server_and_does_not_mutate_input():
    old, new, stroke = layouts()
    source = Path(__file__).resolve().parents[1] / "static/page-layout.js"
    script = """
      const { reflow } = require(process.argv[1]);
      const value = JSON.parse(process.argv[2]);
      const input = new Map([[value.stroke.id, value.stroke]]);
      const inserted = reflow(input, value.old, value.new);
      const deleted = reflow(inserted, value.new, [value.old[0]]);
      console.log(JSON.stringify({inserted: inserted.get('ink'), remaining: deleted.size, original: value.stroke}));
    """
    result = subprocess.run(["node", "-e", script, str(source), json.dumps({"old": old, "new": new, "stroke": stroke})],
                            check=True, capture_output=True, text=True)
    actual = json.loads(result.stdout)
    assert actual["inserted"] == reflow_stroke(stroke, old, new)
    assert actual["original"] == stroke
    assert actual["remaining"] == 0


def test_unknown_local_page_fails_instead_of_reassigning_ink():
    old, _, stroke = layouts()
    local = stored_stroke(stroke, old)
    with pytest.raises(ValueError, match="missing page"):
        world_stroke(local, [old[0]])


def test_failed_local_conversion_rolls_back_rows_metadata_and_backup(tmp_path):
    old, _, stroke = layouts()
    metadata = {"documentId": "doc", "documentRevision": 1, "document": {"pages": old}}
    store = NotebookStore(tmp_path / "notebook.sqlite3")
    store.initialize({**metadata, "strokes": {"ink": stroke}})
    original_rows = dict(store.connection.execute("SELECT id,value FROM strokes"))
    bad = {**stroke, "points": [{"x": None, "y": 170}]}
    with pytest.raises(TypeError):
        store.commit(upserts={"ink": bad}, deletes=set(), metadata={**metadata, "pageIdentityVersion": 1, "documentRevision": 2})
    assert dict(store.connection.execute("SELECT id,value FROM strokes")) == original_rows
    assert store.load()["documentRevision"] == 1
    assert "pageIdentityVersion" not in store.load()
    tables = {row[0] for row in store.connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if "page_identity_backup" in tables:
        assert store.connection.execute("SELECT COUNT(*) FROM page_identity_backup").fetchone()[0] == 0
    store.close()
