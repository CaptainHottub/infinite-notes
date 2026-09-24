"""Whiteboard export geometry and durable creation, isolated from live data."""

import copy
from pathlib import Path

import fitz
import pytest
from fastapi.testclient import TestClient
from fastapi import HTTPException

import server


def stroke(stroke_id: str, x: float, y: float) -> dict:
    return {
        "id": stroke_id, "tool": "pen", "color": "#222222", "width": 2.0,
        "opacity": 1.0, "points": [{"x": x, "y": y, "p": 0.5}],
        "pageIndex": 0,
    }


def snapshot() -> dict:
    return {
        "document": {"whiteboard": {"sectionWidth": 612, "sectionHeight": 792,
                                     "gridSpacing": 20, "gridThickness": 0.55}},
        "strokes": {
            "top-right": stroke("top-right", 620, 100),
            "bottom-left": stroke("bottom-left", -10, 810),
        },
    }


def test_paged_export_uses_shared_width_and_intervening_sections():
    rects = server.whiteboard_export_rects(snapshot(), "paged", "sections", 0)
    assert rects == [(-612, 0, 1224, 792), (-612, 792, 1224, 1584)]


def test_paged_export_does_not_include_uninked_origin_section():
    document = snapshot()
    document["strokes"] = {"remote": stroke("remote", 1400, 1700)}
    assert server.whiteboard_export_rects(document, "paged", "sections", 0) == [
        (1224, 1584, 1836, 2376)
    ]


def test_single_export_bounds_and_buffer():
    document = snapshot()
    assert server.whiteboard_export_rects(document, "single", "sections", 10) == [
        (-622, -10, 1234, 1594)
    ]
    tight = server.whiteboard_export_rects(document, "single", "ink", 10)[0]
    assert tight[0] > -612 and tight[2] < 1224


def test_sparse_paged_export_flags_empty_middle_row():
    document = snapshot()
    document["strokes"]["bottom-left"]["points"][0]["y"] = 1600
    info = server.whiteboard_paged_export_info(document)
    assert info["pageCount"] == 3
    assert info["pages"][1]["strokeCount"] == 0
    assert 2 in info["sparsePages"]


def test_oversized_paged_export_is_refused_without_creating_pdf(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(server, "DATA_DIR", tmp_path)
    document = snapshot()
    document["strokes"]["bottom-left"]["points"][0]["y"] = 792 * (server.MAX_PDF_PAGES + 1)
    with pytest.raises(HTTPException, match="Paged export exceeds"):
        server.create_whiteboard_pdf(document, mode="paged", bounds_mode="sections",
                                     margin=0, background_color="#FFFFFF",
                                     grid_color="#CCCCCC", include_grid=True)
    assert not list(tmp_path.glob("whiteboard-export-*.pdf"))


def test_export_pages_are_vector_and_have_requested_layout(monkeypatch, tmp_path: Path):
    monkeypatch.setattr(server, "DATA_DIR", tmp_path)
    document = snapshot()
    paged = server.create_whiteboard_pdf(document, mode="paged", bounds_mode="sections",
                                         margin=0, background_color="#FFFFFF",
                                         grid_color="#CCCCCC", include_grid=False)
    single = server.create_whiteboard_pdf(document, mode="single", bounds_mode="sections",
                                          margin=10, background_color="#FFFFFF",
                                          grid_color="#CCCCCC", include_grid=True)
    with fitz.open(paged) as pdf:
        assert pdf.page_count == 2
        assert all(page.rect.width == 1836 and page.rect.height == 792 for page in pdf)
        assert all(len(page.get_drawings()) > 1 for page in pdf)
    with fitz.open(single) as pdf:
        assert pdf.page_count == 1
        assert pdf[0].rect.width == 1856


def test_create_whiteboard_persists_section_settings(monkeypatch, tmp_path: Path):
    original_state = copy.deepcopy(server.state)
    data = tmp_path / "data"
    data.mkdir()
    pages = data / "pdf_pages"
    pages.mkdir()
    monkeypatch.setattr(server, "DATA_DIR", data)
    monkeypatch.setattr(server, "PDF_PAGES_DIR", pages)
    monkeypatch.setattr(server, "CURRENT_PDF", data / "current.pdf")
    server.state = server.empty_state()
    store = server.NotebookStore(data / "notebook.sqlite3")
    store.initialize(server.state)
    monkeypatch.setattr(server, "notebook_store", store)
    server.stored_metadata = copy.deepcopy({key: value for key, value in server.state.items() if key != "strokes"})
    try:
        with TestClient(server.app) as client:
            response = client.post("/api/whiteboard", json={"sectionWidth": 612, "sectionHeight": 792,
                                                            "halo": 3, "showOutlines": False})
            assert response.status_code == 200, response.text
            board = response.json()["document"]["whiteboard"]
            assert board["halo"] == 3
            assert board["showOutlines"] is False
            assert store.load()["document"]["whiteboard"] == board
            assert (data / "current.pdf").exists()
            first_id = response.json()["documentId"]
            with client.websocket_connect("/ws?role=ipad&clientId=native-whiteboard-test") as websocket:
                assert websocket.receive_json()["type"] == "state_refresh"
                assert websocket.receive_json()["type"] == "history_state"
                websocket.send_json({
                    "type": "stroke_end", "id": "saved-ink", "documentId": first_id,
                    "stroke": stroke("saved-ink", 50, 60),
                })
                assert websocket.receive_json()["type"] == "history_state"
                assert websocket.receive_json()["type"] == "stroke_ack"
            export = client.get("/api/whiteboard/export", params={"mode": "single", "includeGrid": "false"})
            assert export.status_code == 200, export.text
            with fitz.open(stream=export.content, filetype="pdf") as pdf:
                assert pdf.page_count == 1
                assert len(pdf[0].get_drawings()) >= 2
            settings = client.post("/api/whiteboard/settings", json={
                "documentId": first_id, "sectionWidth": 1000,
                "sectionHeight": 1000, "halo": 4,
            })
            assert settings.status_code == 200, settings.text
            assert settings.json()["document"]["whiteboard"]["sectionWidth"] == 612
            assert settings.json()["document"]["whiteboard"]["halo"] == 4
            board = settings.json()["document"]["whiteboard"]
            second = client.post("/api/whiteboard", json={"sectionWidth": 595.28,
                                                          "sectionHeight": 841.89})
            assert second.status_code == 200, second.text
            assert (data / "notebooks" / f"{first_id}.inotes").exists()
            listed = client.get("/api/notebooks").json()["notebooks"]
            assert {entry["documentId"] for entry in listed} == {
                first_id, second.json()["documentId"]
            }
            reopened = client.post(f"/api/notebooks/{first_id}/open")
            assert reopened.status_code == 200, reopened.text
            assert reopened.json()["document"]["whiteboard"] == board
            assert store.load()["document"]["whiteboard"] == board
            assert "saved-ink" in store.load()["strokes"]
            original_pdf = fitz.open()
            original_pdf.new_page().insert_text((72, 72), "Original PDF retained")
            original_content = original_pdf.tobytes()
            original_pdf.close()
            uploaded = client.post("/api/pdf", files={"file": ("lecture.pdf", original_content, "application/pdf")})
            assert uploaded.status_code == 200, uploaded.text
            imported_id = uploaded.json()["documentId"]
            assert (data / "notebooks" / f"{first_id}.inotes").exists()
            another_board = client.post("/api/whiteboard", json={"name": "Other board"})
            assert another_board.status_code == 200, another_board.text
            assert (data / "notebooks" / f"{imported_id}.inotes").exists()
            restored_pdf = client.post(f"/api/notebooks/{imported_id}/open")
            assert restored_pdf.status_code == 200, restored_pdf.text
            with fitz.open(stream=client.get("/api/pdf/source").content, filetype="pdf") as pdf:
                assert "Original PDF retained" in pdf[0].get_text()
    finally:
        server.state = original_state
        store.close()
