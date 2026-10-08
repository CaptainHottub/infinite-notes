"""Reusable one-page vector PDFs, addressed by their exact content hash."""
import hashlib
import re
from pathlib import Path

import fitz


def asset_path(directory: Path, digest: str) -> Path:
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("Invalid PDF page hash")
    return directory / f"page-{digest}.pdf"


def extract_page(document: fitz.Document, index: int) -> bytes:
    with fitz.open() as single:
        single.insert_pdf(document, from_page=index, to_page=index)
        return single.tobytes(garbage=4, deflate=True, no_new_id=True)


def write_asset(directory: Path, content: bytes) -> dict:
    digest = hashlib.sha256(content).hexdigest()
    path = asset_path(directory, digest)
    if not path.exists() or path.read_bytes() != content:
        # Callers serialize creation with the document lock or use a private
        # preparation directory, never expose partially written PDF responses.
        temporary = path.with_suffix(".pdf.tmp")
        temporary.write_bytes(content)
        temporary.replace(path)
    return {"pdfUrl": f"/api/pdf/page/{digest}", "pdfSha256": digest, "pdfBytes": len(content)}


def reusable_asset(directory: Path, metadata: dict) -> bytes | None:
    try:
        path = asset_path(directory, metadata["pdfSha256"])
        content = path.read_bytes()
        if len(content) == metadata["pdfBytes"] and hashlib.sha256(content).hexdigest() == metadata["pdfSha256"]:
            return content
    except (KeyError, ValueError, OSError):
        pass
    return None
