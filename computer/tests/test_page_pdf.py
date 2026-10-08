import hashlib

import fitz
import pytest

from page_pdf import asset_path, extract_page, reusable_asset, write_asset


def test_extracted_page_preserves_vectors_text_crop_rotation_and_appearance(tmp_path):
    with fitz.open() as source:
        page = source.new_page(width=612, height=792)
        page.draw_line((40, 50), (500, 700), color=(0.1, 0.3, 0.8), width=2)
        page.insert_text((60, 100), "Vector page template", fontsize=24)
        page.set_cropbox(fitz.Rect(20, 30, 590, 760))
        page.set_rotation(90)
        content = extract_page(source, 0)
        with fitz.open(stream=content, filetype="pdf") as single:
            assert single.page_count == 1
            assert single[0].rect == page.rect
            assert single[0].rotation == 90
            assert single[0].cropbox == page.cropbox
            assert single[0].get_text() == page.get_text()
            assert single[0].get_drawings() == page.get_drawings()
            assert single[0].get_pixmap().samples == page.get_pixmap().samples
        metadata = write_asset(tmp_path, content)
        assert metadata["pdfSha256"] == hashlib.sha256(content).hexdigest()
        path = asset_path(tmp_path, metadata["pdfSha256"])
        before = path.stat().st_mtime_ns
        assert write_asset(tmp_path, content) == metadata
        assert path.stat().st_mtime_ns == before
        assert reusable_asset(tmp_path, metadata) == content
        path.write_bytes(b"corrupt")
        assert reusable_asset(tmp_path, metadata) is None
        write_asset(tmp_path, content)
        assert reusable_asset(tmp_path, metadata) == content


def test_asset_names_cannot_escape_directory(tmp_path):
    for digest in ("../current", "a" * 63, "A" * 64, "g" * 64, None):
        with pytest.raises(ValueError):
            asset_path(tmp_path, digest)
