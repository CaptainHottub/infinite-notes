from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "ipad" / "Sources" / "InfiniteNotesStrokeLab"
APP_MODEL = (SOURCE / "AppModel.swift").read_text(encoding="utf-8")
CONTENT = (SOURCE / "ContentView.swift").read_text(encoding="utf-8")
INK_VIEW = (SOURCE / "InkPageView.swift").read_text(encoding="utf-8")
OVERLAYS = (SOURCE / "InteractionOverlayRenderer.swift").read_text(encoding="utf-8")
PDF_VIEW = (SOURCE / "PDFKitNotebookView.swift").read_text(encoding="utf-8")


def test_finished_strokes_have_a_no_flash_commit_handoff():
    assert "pendingCommitOverlayIDs" in INK_VIEW
    assert "beginCommitTransition(strokeID:" in APP_MODEL
    assert "beginCommitTransition(strokeID:" in INK_VIEW
    assert "The committed image is already installed" in INK_VIEW


def test_top_chrome_cannot_trigger_document_scroll_to_top():
    assert "scrollsToTop = false" in PDF_VIEW
    assert ".contentShape(Rectangle())" in CONTENT
    assert ".onTapGesture { }" in CONTENT


def test_tool_switching_does_not_force_default_widths():
    assert "model.inkWidth = 18" not in CONTENT
    assert "model.inkWidth = 3" not in CONTENT


def test_page_geometry_recognizers_do_not_block_document_scrolling():
    assert "panGestureRecognizer.require(toFail: fingerGeometryPan)" not in INK_VIEW
    assert "enclosingScrollView" not in INK_VIEW


def test_pencil_drawing_does_not_grab_geometry_but_finger_can():
    pencil_start = INK_VIEW.index("override func touchesBegan")
    pencil_end = INK_VIEW.index("override func touchesMoved", pencil_start)
    pencil_block = INK_VIEW[pencil_start:pencil_end]
    assert "directHitStroke" not in pencil_block
    assert "Pencil ink tools never grab existing geometry" in pencil_block
    assert "fingerGeometryPan" in INK_VIEW
    assert "fingerGeometryTap" in INK_VIEW
    assert "directHitGeometry" in APP_MODEL


def test_eraser_cursor_has_fill_and_explicit_perimeter():
    start = OVERLAYS.index("static func eraserCursor")
    end = OVERLAYS.index("static func lasso", start)
    block = OVERLAYS[start:end]
    assert "systemGray.withAlphaComponent" in block
    assert "label.withAlphaComponent(0.92)" in block
    assert "lineWidth: 2.0 * inverseZoom" in block


def test_status_pages_are_sorted_numerically_and_current_page_is_bold():
    assert "mountedPageIndices.sorted()" in CONTENT
    assert "index + 1 == model.currentPageNumber" in CONTENT
    assert ".fontWeight(" in CONTENT


def test_selection_and_lasso_sizes_are_screen_space():
    assert "screenPointsToWorld" in INK_VIEW
    assert "screenPointsToLocal" in INK_VIEW
    assert "lassoSampleSpacing" in INK_VIEW
    assert "selectionHandleSize" in INK_VIEW
    assert "zoomScale: interactionZoomScale" in INK_VIEW
    assert "inverseZoom" in OVERLAYS
