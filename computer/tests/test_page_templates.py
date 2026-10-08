"""Template tests use isolated directories, never the live notebook."""

import json
import sys

import fitz
import pytest

from page_templates import _cli, _interactive_args, load_presets, manifest_path, render_page, save_preset


def test_saved_presets_share_one_manifest_and_survive_reopen(tmp_path):
    assert any(item["id"] == "engineering-grid" for item in load_presets(tmp_path))
    path = save_preset({"id": "custom-blue", "name": "Custom blue", "style": "grid",
                        "spacingCm": 0.7, "lineColor": "#4682b4"}, tmp_path)
    assert path == manifest_path(tmp_path)
    raw = json.loads(path.read_text())
    assert raw["version"] == 1
    assert len([item for item in raw["presets"] if item["id"] == "custom-blue"]) == 1
    save_preset({"id": "custom-blue", "name": "Revised blue", "style": "dot"}, tmp_path)
    presets = load_presets(tmp_path)
    assert len([item for item in presets if item["id"] == "custom-blue"]) == 1
    assert next(item for item in presets if item["id"] == "custom-blue")["style"] == "dot"


@pytest.mark.parametrize("style", ["none", "grid", "eng", "dot", "lined"])
def test_generated_page_is_exact_size_and_has_no_raster_images(style):
    preset = {"id": "check", "name": "Check", "style": style,
              "spacingCm": 0.5, "title": "Vector paper", "headerCm": 1.2}
    content = render_page(preset, 612.0, 792.0)
    document = fitz.open(stream=content, filetype="pdf")
    try:
        page = document[0]
        assert page.rect.width == 612.0
        assert page.rect.height == 792.0
        assert page.get_images(full=True) == []
        assert "Vector paper" in page.get_text()
        if style != "none":
            assert page.get_drawings(), f"{style} did not produce vector drawing commands"
    finally:
        document.close()


def test_generated_page_rejects_unbounded_dots():
    with pytest.raises(ValueError, match="too many dots"):
        render_page({"id": "dense", "name": "Dense", "style": "dot", "spacingCm": 0.1},
                    2000, 2000)


def test_grid_spacing_remains_physical_when_page_size_changes():
    preset = {"id": "measured", "name": "Measured", "style": "grid", "spacingCm": 0.5}
    for width, height in ((317, 499), (612, 792)):
        document = fitz.open(stream=render_page(preset, width, height), filetype="pdf")
        try:
            lines = document[0].get_drawings()[0]["items"]
            first_x = lines[0][1].x
            second_x = lines[1][1].x
            assert second_x - first_x == pytest.approx(72 / 2.54 * 0.5, abs=0.01)
        finally:
            document.close()


def test_interactive_command_still_prompts_for_paper_settings(monkeypatch):
    answers = iter(["letter", "portrait", "2", "0.5", "white", "0", "", "n",
                    "1", "grid.pdf", "y", "Lecture grid"])
    monkeypatch.setattr("builtins.input", lambda _prompt: next(answers))
    args = _interactive_args()
    assert args[:4] == ["--page", "letter", "--style", "grid"]
    assert args[-2:] == ["--save-preset", "Lecture grid"]


def test_eng_command_keeps_output_name_and_writes_vector_pdf(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", ["pdf-make", "--eng"])
    assert _cli() == 0
    document = fitz.open(tmp_path / "grid.pdf")
    try:
        assert document.page_count == 1
        assert document[0].get_images(full=True) == []
        assert len(document[0].get_drawings()) >= 2
    finally:
        document.close()
