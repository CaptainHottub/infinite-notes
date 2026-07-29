from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

import fitz

COMPUTER_DIR = Path(__file__).resolve().parents[1]
(COMPUTER_DIR / "data" / "pdf_pages").mkdir(parents=True, exist_ok=True)
SPEC = importlib.util.spec_from_file_location("infinite_notes_server", COMPUTER_DIR / "server.py")
assert SPEC and SPEC.loader
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


class OffPageWorkspaceServerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.pages = [
            {"id": "page-1", "pageNumber": 1, "x": 0.0, "y": 0.0, "width": 100.0, "height": 150.0},
            {"id": "page-2", "pageNumber": 2, "x": 0.0, "y": 150.0, "width": 100.0, "height": 150.0},
        ]

    def test_no_overflow_keeps_original_size(self) -> None:
        snapshot = {"document": {"pages": self.pages[:1]}, "strokes": {}}
        layout = server.build_pdf_export_layout(snapshot, overflow_margin=20)[0]
        self.assertEqual(layout["newWidth"], 100.0)
        self.assertEqual(layout["newHeight"], 150.0)
        self.assertFalse(layout["overflow"])

    def test_native_margin_is_twenty_points_beyond_stroke_edge(self) -> None:
        stroke = {
            "id": "left",
            "tool": "pen",
            "width": 2.0,
            "pageIndex": 0,
            "points": [{"x": -10.0, "y": 20.0, "x_raw": -10.0, "y_raw": 20.0}],
        }
        snapshot = {"document": {"pages": self.pages[:1]}, "strokes": {"left": stroke}}
        layout = server.build_pdf_export_layout(snapshot, overflow_margin=20)[0]
        # Pen bounds include 1.95 pt of rendering safety padding, then the requested 20 pt.
        self.assertAlmostEqual(layout["margins"]["left"], 31.95, places=2)
        self.assertAlmostEqual(layout["newWidth"], 131.95, places=2)

    def test_insert_remaps_only_later_pages(self) -> None:
        new_pages = [
            self.pages[0],
            {"id": "page-2", "pageNumber": 2, "x": 0.0, "y": 150.0, "width": 100.0, "height": 150.0},
            {"id": "page-3", "pageNumber": 3, "x": 0.0, "y": 300.0, "width": 100.0, "height": 150.0},
        ]
        early = {
            "id": "early",
            "tool": "pen",
            "width": 2.0,
            "pageIndex": 0,
            "points": [{"x": 5.0, "y": 20.0, "x_raw": 5.0, "y_raw": 20.0, "y_local": 20.0}],
        }
        late = {
            "id": "late",
            "tool": "pen",
            "width": 2.0,
            "pageIndex": 1,
            "points": [{"x": 5.0, "y": 180.0, "x_raw": 5.0, "y_raw": 181.0, "y_local": 30.0}],
        }
        shifted = server.remap_strokes_after_page_insert(
            {"early": early, "late": late}, self.pages, new_pages, 0
        )
        self.assertEqual(len(shifted), 1)
        self.assertEqual(early["pageIndex"], 0)
        self.assertEqual(early["points"][0]["y"], 20.0)
        self.assertEqual(late["pageIndex"], 2)
        self.assertEqual(late["points"][0]["y"], 330.0)
        self.assertEqual(late["points"][0]["y_raw"], 331.0)
        self.assertEqual(late["points"][0]["y_local"], 30.0)

    def test_flattened_pdf_uses_expanded_dimensions(self) -> None:
        source = fitz.open()
        source.new_page(width=100, height=150)
        source_bytes = source.tobytes()
        source.close()
        stroke = {
            "id": "left",
            "tool": "pen",
            "width": 2.0,
            "pageIndex": 0,
            "points": [{"x": -10.0, "y": 20.0, "x_raw": -10.0, "y_raw": 20.0}],
        }
        snapshot = {
            "document": {"filename": "source.pdf", "pages": self.pages[:1]},
            "strokes": {"left": stroke},
        }
        output_path, _ = server.create_flattened_pdf(
            snapshot,
            source_bytes,
            overflow_margin=20,
            outer_grid_style="dark-gray",
            outer_grid_spacing=20,
        )
        try:
            output = fitz.open(output_path)
            self.assertAlmostEqual(output[0].rect.width, 131.95, places=2)
            self.assertAlmostEqual(output[0].rect.height, 150.0, places=2)
            output.close()
        finally:
            output_path.unlink(missing_ok=True)

    def test_prepare_pdf_creates_vector_svg_pages(self) -> None:
        source = fitz.open()
        page = source.new_page(width=100, height=150)
        page.insert_text((10, 20), "Vector page")
        page.draw_line((10, 30), (90, 30))
        source_bytes = source.tobytes()
        source.close()

        old_data_dir = server.DATA_DIR
        old_pages_dir = server.PDF_PAGES_DIR
        old_state_file = server.STATE_FILE
        old_current_pdf = server.CURRENT_PDF
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            server.DATA_DIR = root / "data"
            server.PDF_PAGES_DIR = server.DATA_DIR / "pdf_pages"
            server.STATE_FILE = server.DATA_DIR / "state.json"
            server.CURRENT_PDF = server.DATA_DIR / "current.pdf"
            try:
                prepared, pages = server.prepare_pdf(source_bytes)
                rendered = list((prepared / "pdf_pages").iterdir())
                self.assertEqual([path.suffix for path in rendered], [".svg"])
                self.assertTrue(pages[0]["imageUrl"].split("?", 1)[0].endswith(".svg"))
                svg = rendered[0].read_text(encoding="utf-8")
                self.assertIn("<svg", svg)
                self.assertNotIn("<canvas", svg)
            finally:
                server.DATA_DIR = old_data_dir
                server.PDF_PAGES_DIR = old_pages_dir
                server.STATE_FILE = old_state_file
                server.CURRENT_PDF = old_current_pdf

    def test_exported_ink_is_pdf_vector_content_not_a_page_bitmap(self) -> None:
        source = fitz.open()
        source.new_page(width=100, height=150)
        source_bytes = source.tobytes()
        source.close()
        stroke = {
            "id": "line",
            "tool": "pen",
            "color": "#111111",
            "opacity": 1.0,
            "width": 3.0,
            "pageIndex": 0,
            "points": [
                {"x": 10.0, "y": 20.0, "p": 0.5, "x_raw": 10.0, "y_raw": 20.0},
                {"x": 80.0, "y": 100.0, "p": 0.7, "x_raw": 80.0, "y_raw": 100.0},
            ],
        }
        snapshot = {
            "document": {"filename": "source.pdf", "pages": self.pages[:1]},
            "strokes": {"line": stroke},
        }
        output_path, _ = server.create_flattened_pdf(snapshot, source_bytes)
        try:
            output = fitz.open(output_path)
            page = output[0]
            self.assertGreater(len(page.get_drawings()), 0)
            self.assertEqual(page.get_images(full=True), [])
            output.close()
        finally:
            output_path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
