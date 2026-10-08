"""Named paper presets and resolution-independent PDF page generation."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import tempfile
from datetime import date
from pathlib import Path
from typing import Any

import fitz


POINTS_PER_CM = 72.0 / 2.54
POINTS_PER_MM = 72.0 / 25.4
DEFAULT_DATA_DIR = Path(__file__).resolve().parent / "data"
STYLES = {"none", "grid", "eng", "dot", "lined"}
STYLE_ALIASES = {"dots": "dot", "dotgrid": "dot", "ruled": "lined"}
COLOR_NAMES = {
    "white": "#ffffff", "black": "#000000", "gray": "#808080",
    "grey": "#808080", "lightgray": "#d3d3d3", "lightgrey": "#d3d3d3",
    "red": "#ff0000", "blue": "#0000ff", "green": "#008000",
}
DEFAULTS: dict[str, Any] = {
    "style": "none", "spacingCm": 0.5, "minorSpacingCm": 0.25,
    "majorSpacingCm": 1.0, "background": "#ffffff",
    "lineColor": "#cccccc", "minorColor": "#dddddd",
    "majorColor": "#999999", "lineWidthMm": 0.1,
    "minorWidthMm": 0.05, "majorWidthMm": 0.1,
    "marginCm": 0.0, "headerCm": 0.0, "title": "", "date": False,
}
BUILTIN_PRESETS: list[dict[str, Any]] = [
    {"id": "square-grid", "name": "Square grid", "style": "grid"},
    {"id": "engineering-grid", "name": "Engineering grid", "style": "eng"},
    {"id": "dot-grid", "name": "Dot grid", "style": "dot"},
    {"id": "ruled-paper", "name": "Ruled paper", "style": "lined", "spacingCm": 0.8},
]


def manifest_path(data_dir: Path) -> Path:
    return data_dir / "page-templates" / "presets.json"


def _number(value: Any, name: str, *, minimum: float, maximum: float) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be a number")
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be a number") from exc
    if not math.isfinite(result) or not minimum <= result <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return result


def _color(value: Any, name: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{name} must be a color")
    color = COLOR_NAMES.get(value.lower(), value.lower())
    if re.fullmatch(r"#[0-9a-f]{3}", color):
        color = "#" + "".join(character * 2 for character in color[1:])
    if not re.fullmatch(r"#[0-9a-f]{6}", color):
        raise ValueError(f"{name} must be a #RRGGBB color or a supported color name")
    return color


def _rgb(color: str) -> tuple[float, float, float]:
    return tuple(int(color[index:index + 2], 16) / 255 for index in (1, 3, 5))


def validate_preset(raw: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("A template preset must be an object")
    preset = {**DEFAULTS, **raw}
    style = preset.get("style")
    preset.setdefault("minorLinesEnabled", style in {"grid", "eng", "lined"} if isinstance(style, str) else False)
    preset.setdefault("majorLinesEnabled", style == "eng")
    preset.setdefault("dotsEnabled", style == "dot")
    preset.setdefault("dotSpacingCm", preset["spacingCm"])
    preset.setdefault("dotColor", preset["lineColor"])
    preset.setdefault("dotRadiusMm", 0.4)
    if style in ("grid", "lined") and "minorLinesEnabled" not in raw:
        preset["minorSpacingCm"] = preset["spacingCm"]
        preset["minorColor"] = preset["lineColor"]
        preset["minorWidthMm"] = preset["lineWidthMm"]
    identifier = preset.get("id")
    name = preset.get("name")
    if not isinstance(identifier, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", identifier):
        raise ValueError("Preset id must be a short lowercase identifier")
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 100:
        raise ValueError("Preset name must contain 1 to 100 characters")
    preset["name"] = name.strip()
    if not isinstance(preset["style"], str) or preset["style"] not in STYLES:
        raise ValueError(f"Unknown template style: {preset['style']}")
    for key in ("spacingCm", "minorSpacingCm", "majorSpacingCm", "dotSpacingCm"):
        preset[key] = _number(preset[key], key, minimum=0.1, maximum=20)
    for key in ("lineWidthMm", "minorWidthMm", "majorWidthMm"):
        preset[key] = _number(preset[key], key, minimum=0.01, maximum=3)
    preset["marginCm"] = _number(preset["marginCm"], "marginCm", minimum=0, maximum=10)
    preset["headerCm"] = _number(preset["headerCm"], "headerCm", minimum=0, maximum=10)
    preset["dotRadiusMm"] = _number(preset["dotRadiusMm"], "dotRadiusMm", minimum=0.01, maximum=3)
    for key in ("background", "lineColor", "minorColor", "majorColor", "dotColor"):
        preset[key] = _color(preset[key], key)
    for key in ("minorLinesEnabled", "majorLinesEnabled", "dotsEnabled"):
        if not isinstance(preset[key], bool):
            raise ValueError(f"{key} must be true or false")
    for key in ("pageWidthPt", "pageHeightPt"):
        if preset.get(key) is not None:
            preset[key] = _number(preset[key], key, minimum=20, maximum=20_000)
    if (preset.get("pageWidthPt") is None) != (preset.get("pageHeightPt") is None):
        raise ValueError("Both page dimensions must be provided")
    if not isinstance(preset["title"], str) or len(preset["title"]) > 120:
        raise ValueError("Preset title must be at most 120 characters")
    if not isinstance(preset["date"], bool):
        raise ValueError("Preset date must be true or false")
    return preset


def load_presets(data_dir: Path = DEFAULT_DATA_DIR) -> list[dict[str, Any]]:
    path = manifest_path(data_dir)
    if path.exists():
        manifest = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(manifest, dict) or manifest.get("version") != 1 or not isinstance(manifest.get("presets"), list):
            raise ValueError("Template manifest must contain version 1 and a presets list")
        raw_presets = manifest["presets"]
    else:
        raw_presets = BUILTIN_PRESETS
    presets = [validate_preset(raw) for raw in raw_presets]
    ids = [preset["id"] for preset in presets]
    if len(ids) != len(set(ids)):
        raise ValueError("Template preset ids must be unique")
    return presets


def save_preset(preset: dict[str, Any], data_dir: Path = DEFAULT_DATA_DIR) -> Path:
    validated = validate_preset(preset)
    presets = load_presets(data_dir)
    presets = [item for item in presets if item["id"] != validated["id"]] + [validated]
    path = manifest_path(data_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix="presets-", suffix=".json", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump({"version": 1, "presets": presets}, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
    finally:
        Path(temporary_name).unlink(missing_ok=True)
    return path


def _positions(start: float, end: float, step: float) -> list[float]:
    count = math.floor((end - start + 0.0001) / step) + 1
    if count > 20_000:
        raise ValueError("Template grid has too many elements")
    return [start + index * step for index in range(max(0, count))]


def render_page(preset: dict[str, Any], width_pt: float, height_pt: float) -> bytes:
    """Generate one PDF page with vector drawing commands, never raster images."""
    preset = validate_preset(preset)
    width = _number(width_pt, "page width", minimum=20, maximum=20_000)
    height = _number(height_pt, "page height", minimum=20, maximum=20_000)
    inset = preset["marginCm"] * POINTS_PER_CM
    left, right = inset, width - inset
    top = inset + preset["headerCm"] * POINTS_PER_CM
    bottom = height - inset
    if left >= right or top >= bottom:
        raise ValueError("Template margin and header leave no drawable area")

    document = fitz.open()
    try:
        page = document.new_page(width=width, height=height)
        if preset["background"] != "#ffffff":
            page.draw_rect(page.rect, color=None, fill=_rgb(preset["background"]), overlay=False)

        def lines(spacing_cm: float, color: str, width_mm: float, *, vertical: bool) -> None:
            step = spacing_cm * POINTS_PER_CM
            shape = page.new_shape()
            if vertical:
                for x in _positions(left, right, step):
                    shape.draw_line((x, top), (x, bottom))
                for y in _positions(top, bottom, step):
                    shape.draw_line((left, y), (right, y))
            else:
                for y in _positions(top, bottom, step):
                    shape.draw_line((left, y), (right, y))
            shape.finish(color=_rgb(color), width=width_mm * POINTS_PER_MM)
            shape.commit()

        style = preset["style"]
        if preset["minorLinesEnabled"]:
            lines(preset["minorSpacingCm"], preset["minorColor"], preset["minorWidthMm"], vertical=style != "lined")
        if preset["majorLinesEnabled"]:
            lines(preset["majorSpacingCm"], preset["majorColor"], preset["majorWidthMm"], vertical=True)
        if preset["dotsEnabled"]:
            xs = _positions(left, right, preset["dotSpacingCm"] * POINTS_PER_CM)
            ys = _positions(top, bottom, preset["dotSpacingCm"] * POINTS_PER_CM)
            if len(xs) * len(ys) > 20_000:
                raise ValueError("Template dot grid has too many dots")
            shape = page.new_shape()
            for y in ys:
                for x in xs:
                    shape.draw_circle((x, y), preset["dotRadiusMm"] * POINTS_PER_MM)
            shape.finish(color=None, fill=_rgb(preset["dotColor"]))
            shape.commit()

        heading = preset["title"]
        if preset["date"]:
            heading = f"{heading}    {date.today().isoformat()}" if heading else date.today().isoformat()
        if heading:
            if not preset["headerCm"]:
                raise ValueError("A title or date requires a nonzero header")
            baseline = inset + min(preset["headerCm"] * POINTS_PER_CM * 0.7, 18)
            page.insert_text((left + 0.2 * POINTS_PER_CM, baseline), heading, fontsize=11, color=(0, 0, 0))
        return document.tobytes(garbage=4, deflate=True)
    finally:
        document.close()


def _interactive_args() -> list[str]:
    def ask(label: str, default: str) -> str:
        return input(f"{label} ({default}): ").strip() or default

    print("\npdf-make - vector paper")
    page = ask("Page size [a4/letter]", "a4")
    orientation = ask("Orientation [portrait/landscape]", "portrait")
    print("Paper style: 1) Blank  2) Grid  3) Engineering grid  4) Dot grid  5) Lined")
    style = {"1": "none", "2": "grid", "3": "eng", "4": "dot", "5": "lined"}.get(
        ask("Style [1-5]", "1")
    )
    if style is None:
        raise ValueError("Choose a paper style from 1 to 5")
    args = ["--page", page, "--style", style]
    if orientation == "landscape":
        args.append("--landscape")
    elif orientation != "portrait":
        raise ValueError("Orientation must be portrait or landscape")
    if style in {"grid", "dot", "lined"}:
        args += ["--spacing", ask("Spacing in cm", "0.5")]
    elif style == "eng":
        args += ["--minor", ask("Minor spacing in cm", "0.25")]
        args += ["--major", ask("Major spacing in cm", "1")]
        args += ["--minor-width", ask("Minor line width (legacy pixels)", "0.5")]
        args += ["--major-width", ask("Major line width (legacy pixels)", "1")]
    args += ["--color", ask("Page color", "white")]
    args += ["--margin", ask("Margin in cm", "0")]
    title = input("Title (leave blank for none): ").strip()
    if title:
        args += ["--title", title, "--header", ask("Header height in cm", "1.2")]
    if ask("Add current date? [y/N]", "n").lower() in {"y", "yes"}:
        args.append("--date")
    args += ["--pages", ask("Number of pages", "1")]
    output = ask("Output file", "output.pdf")
    args += ["--out", output]
    save = input("Save this design in the iPad template library? [y/N]: ").strip().lower()
    if save in {"y", "yes"}:
        args += ["--save-preset", ask("Template name", Path(output).stem)]
    return args


def _cli() -> int:
    parser = argparse.ArgumentParser(prog="pdf-make", description="Create vector paper PDFs and save reusable presets")
    parser.add_argument("--eng", action="store_true", help="Use the engineering-grid defaults")
    parser.add_argument("--page", choices=("a4", "letter", "us-letter", "us_letter"), default="a4")
    parser.add_argument("--width-pt", type=float, help="Exact PDF page width in points")
    parser.add_argument("--height-pt", type=float, help="Exact PDF page height in points")
    orientation = parser.add_mutually_exclusive_group()
    orientation.add_argument("--landscape", action="store_true")
    orientation.add_argument("--portrait", action="store_true")
    parser.add_argument("--pages", type=int, default=1)
    parser.add_argument("--style", "--grid", choices=sorted(STYLES | set(STYLE_ALIASES)), default="none")
    parser.add_argument("--spacing", type=float, default=0.5)
    parser.add_argument("--minor", type=float, default=0.25)
    parser.add_argument("--major", type=float, default=1.0)
    parser.add_argument("--color", default="white")
    parser.add_argument("--line-color", default="#cccccc")
    parser.add_argument("--minor-color", default="#dddddd")
    parser.add_argument("--major-color", default="#999999")
    parser.add_argument("--density", type=int, default=100,
                        help="Accepted for compatibility; vector output has no pixel density")
    parser.add_argument("--minor-width", type=float, default=0.5,
                        help="Legacy pixel width; converted to a physical width")
    parser.add_argument("--major-width", type=float, default=1.0,
                        help="Legacy pixel width; converted to a physical width")
    parser.add_argument("--margin", type=float, default=0)
    parser.add_argument("--header", type=float, default=0)
    parser.add_argument("--title", default="")
    parser.add_argument("--date", action="store_true")
    parser.add_argument("--out", "-o", type=Path, default=Path("output.pdf"))
    parser.add_argument("--save-preset", metavar="NAME", help="Add/update this design in the server template library")
    parser.add_argument("--preset-id", help="Stable library id (defaults to a slug of the name)")
    try:
        cli_args = _interactive_args() if len(sys.argv) == 1 else sys.argv[1:]
    except ValueError as exc:
        parser.error(str(exc))
    args = parser.parse_args(cli_args)
    if args.pages < 1 or args.pages > 150 or args.density < 1:
        parser.error("Pages must be 1–150 and density must be positive")
    if (args.width_pt is None) != (args.height_pt is None):
        parser.error("--width-pt and --height-pt must be supplied together")
    if args.width_pt is None:
        width, height = (595.2756, 841.8898) if args.page == "a4" else (612.0, 792.0)
    else:
        width, height = args.width_pt, args.height_pt
    if args.landscape:
        width, height = height, width
    style = "eng" if args.eng else STYLE_ALIASES.get(args.style, args.style)
    if args.eng and args.out == Path("output.pdf"):
        args.out = Path("grid.pdf")
    name = args.save_preset or args.out.stem
    identifier = args.preset_id or re.sub(r"[^a-z0-9_-]+", "-", name.lower()).strip("-")
    preset = validate_preset({
        "id": identifier, "name": name, "style": style,
        "spacingCm": args.spacing, "minorSpacingCm": args.minor,
        "majorSpacingCm": args.major, "background": args.color,
        "lineColor": args.line_color, "minorColor": args.minor_color,
        "majorColor": args.major_color,
        "minorWidthMm": args.minor_width * 10 / args.density,
        "majorWidthMm": args.major_width * 10 / args.density,
        "marginCm": args.margin,
        "headerCm": args.header or (1.2 if args.title or args.date else 0),
        "title": args.title, "date": args.date,
    })
    single_page = render_page(preset, width, height)
    if args.pages == 1:
        output = single_page
    else:
        source = fitz.open(stream=single_page, filetype="pdf")
        target = fitz.open()
        try:
            for _ in range(args.pages):
                target.insert_pdf(source)
            output = target.tobytes(garbage=4, deflate=True)
        finally:
            source.close()
            target.close()
    out = args.out if args.out.suffix.lower() == ".pdf" else args.out.with_suffix(".pdf")
    out.write_bytes(output)
    print(f"Created vector PDF: {out} ({args.pages} page{'s' if args.pages != 1 else ''})")
    if args.save_preset:
        data_dir = Path(os.environ.get("INFINITE_NOTES_DATA_DIR", DEFAULT_DATA_DIR))
        print(f"Saved template preset: {save_preset(preset, data_dir)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
