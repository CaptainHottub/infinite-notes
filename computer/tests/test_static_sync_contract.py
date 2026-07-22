from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP_JS = (ROOT / "static" / "app.js").read_text(encoding="utf-8")
INDEX_HTML = (ROOT / "static" / "index.html").read_text(encoding="utf-8")


def test_sync_is_incremental_and_forceful_ipad_state_push_is_removed():
    assert 'type: "ipad_state_push"' not in APP_JS
    assert 'case "authoritative_state_request"' not in APP_JS
    assert "indexedDB.open" not in APP_JS
    assert 'type: "sync_request"' in APP_JS
    assert "Ink changes sync incrementally" in APP_JS
    assert "Automatic server refresh" in INDEX_HTML
    assert '<option value="0" selected>Off</option>' in INDEX_HTML


def test_project_import_fetches_restored_state_separately():
    import_start = APP_JS.index('projectImportInput?.addEventListener')
    import_end = APP_JS.index('window.addEventListener("resize"', import_start)
    block = APP_JS[import_start:import_end]
    assert 'fetch(`/api/state?import=${Date.now()}`' in block
    assert 'state: data.state' not in block


def test_rapid_erasures_use_persisted_acknowledged_operations():
    assert 'pendingDeleteOperations: loadPendingDeleteOperations()' in APP_JS
    assert 'operationId: operation.id' in APP_JS
    assert 'final: Boolean(operation.final)' in APP_JS
    assert 'queueReliableDeletes(deleted' in APP_JS
    assert 'operation.final = true' in APP_JS


def test_ipad_view_is_persisted_and_snapshot_preserves_camera():
    assert 'IPAD_VIEW_KEY = "infiniteNotes.ipadView.v1"' in APP_JS
    assert "restoreSavedIpadView" in APP_JS
    assert "persistIpadView" in APP_JS
    snapshot_start = APP_JS.index('case "snapshot"')
    snapshot_end = APP_JS.index('case "document_changed"', snapshot_start)
    snapshot_block = APP_JS[snapshot_start:snapshot_end]
    assert 'preserveView: mode === "ipad"' in snapshot_block
    assert 'mode !== "ipad"' in snapshot_block


def test_text_box_tool_is_available_on_both_clients_and_uses_synced_strokes():
    assert 'id="textModeButton"' in INDEX_HTML
    assert 'id="textEditorInput"' in INDEX_HTML
    assert 'tool: "text"' in APP_JS
    assert 'type: "add_strokes"' in APP_JS
    assert 'type: "replace_strokes"' in APP_JS
    assert "drawTextStroke" in APP_JS
    assert "positionTextEditor" in APP_JS


def test_geometry_toolbar_recognition_snapping_and_plane_contract():
    for element_id in [
        'shapeModeButton', 'planeModeButton', 'shapeContextRow',
        'lineRecognitionTolerance', 'curveRecognitionTolerance',
        'recognitionHoldMs', 'geometrySnapDistance',
        'endpointSnapToggle', 'axisSnapToggle',
        'tangentSnapToggle', 'normalSnapToggle',
    ]:
        assert f'id="{element_id}"' in INDEX_HTML
    for shape_type in [
        'rectangle', 'square', 'ellipse', 'circle', 'triangle',
        'diamond', 'line', 'arrow', 'curve',
    ]:
        assert f'data-shape-type="{shape_type}"' in INDEX_HTML
    for function_name in [
        'drawShapeStroke', 'beginShapePointer', 'recognizeActiveInk',
        'snapGeometryPoint', 'nearestEllipseSnap', 'insertXYPlane',
    ]:
        assert f'function {function_name}' in APP_JS
    assert 'shapeType:"xy-plane"' in APP_JS
    assert 'recognitionSource' in APP_JS
    assert 'state.tool === "shape"' in APP_JS


def test_geometry_lock_and_committed_recognition_contract():
    assert 'id="selectionPlaneLockButton"' in INDEX_HTML
    assert 'max="60"' in INDEX_HTML
    assert 'min="150"' in INDEX_HTML
    assert 'function toggleSelectedGeometryLock' in APP_JS
    assert 'if (stroke.locked) continue;' in APP_JS
    assert 'line committed' not in APP_JS  # message is generated dynamically
    assert 'Recognition is a committed mode' in APP_JS
    assert 'stroke.tool = stroke.recognitionSource' not in APP_JS


def test_all_locked_items_are_ignored_by_eraser_and_direct_hits():
    erase_start = APP_JS.index("function eraseAt(event)")
    erase_end = APP_JS.index("function finishEraserGesture", erase_start)
    erase_block = APP_JS[erase_start:erase_end]
    assert 'if (stroke.locked)' in erase_block

    geometry_hit_start = APP_JS.index("function shapeStrokeAt(world)")
    geometry_hit_end = APP_JS.index("function nearestEllipseSnap", geometry_hit_start)
    assert 'if (stroke.locked) continue;' in APP_JS[geometry_hit_start:geometry_hit_end]

    selector_hit_start = APP_JS.index("function hitStrokeAt(world")
    selector_hit_end = APP_JS.index("function selectionHit", selector_hit_start)
    selector_hit_block = APP_JS[selector_hit_start:selector_hit_end]
    assert 'isGeometryStroke(stroke) || stroke.locked' in selector_hit_block


def test_drawing_tools_do_not_directly_select_geometry():
    pen_start = APP_JS.index("function beginPenPointerContact")
    pen_end = APP_JS.index("function recoverPenContactFromMotion", pen_start)
    assert "shapeStrokeAt" not in APP_JS[pen_start:pen_end]

    shape_start = APP_JS.index("function beginShapePointer")
    shape_end = APP_JS.index("function updateShapePointer", shape_start)
    assert "shapeStrokeAt" not in APP_JS[shape_start:shape_end]


def test_finger_geometry_selection_waits_for_a_real_tap_and_restores_previous_tool():
    assert "temporarySelectionReturnMode" in APP_JS
    assert "pendingFingerInteraction" in APP_JS
    assert "function beginTemporaryGeometrySelection" in APP_JS
    assert "function restoreTemporarySelectionTool" in APP_JS
    assert "function beginPendingFingerInteraction" in APP_JS
    assert "function updatePendingFingerInteraction" in APP_JS
    assert "function finishPendingFingerInteraction" in APP_JS
    assert 'pending.action === "select"' in APP_JS
    assert 'pending.action === "deselect"' in APP_JS
    assert 'promotePendingFingerToNavigation' in APP_JS


def test_tangent_and_normal_snap_precede_endpoint_and_use_ellipse_normal():
    snap_start = APP_JS.index("function snapGeometryPoint")
    snap_end = APP_JS.index("function drawSnapGuide", snap_start)
    snap_block = APP_JS[snap_start:snap_end]
    tangent_index = snap_block.index('state.tangentSnap || state.normalSnap')
    endpoint_index = snap_block.index('state.endpointSnap')
    assert tangent_index < endpoint_index
    assert 'geometrySnapEndpoints' in snap_block
    assert 'nearestEllipseSnap(original, strokeId, otherPoint)' in snap_block
    ellipse_start = APP_JS.index("function nearestEllipseSnap")
    ellipse_end = APP_JS.index("function angleDifference", ellipse_start)
    ellipse_block = APP_JS[ellipse_start:ellipse_end]
    assert 'cosine / rx' in ellipse_block
    assert 'sine / ry' in ellipse_block
    assert '30 * Math.PI / 180' in ellipse_block
    assert 'const segments = 180' in ellipse_block



def test_selector_can_pick_up_unlocked_geometry_in_one_gesture():
    begin_start = APP_JS.index("function beginSelectionPointer")
    begin_end = APP_JS.index("function updateSelectionPointer", begin_start)
    block = APP_JS[begin_start:begin_end]
    assert "const directId = hitStrokeAt" in block
    assert "isGeometryStroke(directStroke) && !directStroke.locked" in block
    assert 'hit = { type: "move", geometry: directGeometry }' in block


def test_pencil_geometry_editing_requires_the_selector_tool():
    pen_start = APP_JS.index("function beginPenPointerContact")
    pen_end = APP_JS.index("function recoverPenContactFromMotion", pen_start)
    block = APP_JS[pen_start:pen_end]
    assert 'if (state.tool === "selector")' in block
    selector_branch = block[block.index('if (state.tool === "selector")'):]
    assert 'beginSelectionPointer(event)' in selector_branch
    draw_branch = block[block.rindex('beginStroke(event)') - 80:]
    assert 'shapeStrokeAt' not in draw_branch


def test_lock_button_applies_to_any_selected_item():
    ui_start = APP_JS.index("function updateSelectionUI")
    ui_end = APP_JS.index("function toggleSelectedGeometryLock", ui_start)
    ui_block = APP_JS[ui_start:ui_end]
    assert 'selectionPlaneLockButton.hidden = count === 0' in ui_block
    lock_start = APP_JS.index("function toggleSelectedGeometryLock")
    lock_end = APP_JS.index("function restoreTemporarySelectionTool", lock_start)
    lock_block = APP_JS[lock_start:lock_end]
    assert '.filter(Boolean)' in lock_block
    assert '.filter(isGeometryStroke)' not in lock_block
