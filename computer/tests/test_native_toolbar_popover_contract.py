from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTENT = (ROOT / "ipad/Sources/InfiniteNotesStrokeLab/ContentView.swift").read_text()
MODEL = (ROOT / "ipad/Sources/InfiniteNotesStrokeLab/AppModel.swift").read_text()
MODELS = (ROOT / "ipad/Sources/InfiniteNotesStrokeLab/Models.swift").read_text()


def test_tool_order_places_eraser_before_highlighter():
    assert "[.pressurePen, .eraser, .highlighter, .selector, .shape]" in MODELS


def test_tool_details_are_moved_into_anchored_popovers():
    assert "InkToolSettingsPopover" in CONTENT
    assert "EraserToolSettingsPopover" in CONTENT
    assert "attachmentAnchor: .rect(.bounds)" in CONTENT
    assert 'Image(systemName: "slider.horizontal.3")' in CONTENT
    assert "Slider(value: widthBinding" in CONTENT
    assert "Slider(value: diameterBinding" in CONTENT


def test_line_presets_appear_before_colours_and_colours_can_expand():
    width_group = CONTENT.index("Width presets come first")
    colour_group = CONTENT.index("Colours follow line settings")
    assert width_group < colour_group
    assert 'Image(systemName: "plus")' in CONTENT
    assert "model.addColorPreset()" in CONTENT
    assert "func addColorPreset()" in MODEL


def test_colour_and_tool_changes_auto_save():
    assert '.onChange(of: color)' in CONTENT
    assert 'Text("Changes save automatically")' not in CONTENT  # rendered through Label instead
    assert 'Label("Changes save automatically"' in CONTENT
    assert "updateActivePenWidth" in MODEL
    assert "updateActiveEraserWidth" in MODEL
    assert 'UserDefaults.standard.set(inkColorPresets' in MODEL
    assert 'UserDefaults.standard.set(penWidthPresets' in MODEL
    assert 'UserDefaults.standard.set(eraserWidthPresets' in MODEL
