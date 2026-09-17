"""Recoverable pairing of PDF assets with a SQLite document revision.

Only document-changing operations use this staging area. Stroke commits never
copy or rewrite a PDF or page cache.
"""

from __future__ import annotations

import json
import os
import shutil
import tempfile
from pathlib import Path


TRANSITION_NAME = "asset-transition"


def _sync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _copy_file(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as input_file, target.open("wb") as output_file:
        shutil.copyfileobj(input_file, output_file)
        output_file.flush()
        os.fsync(output_file.fileno())


def _copy_asset_set(current_pdf: Path, pages_dir: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    if current_pdf.exists():
        _copy_file(current_pdf, destination / "current.pdf")
    if pages_dir.exists():
        for pattern in ("page-*.png", "page-*.svg"):
            for page in pages_dir.glob(pattern):
                _copy_file(page, destination / "pdf_pages" / page.name)
    if (destination / "pdf_pages").exists():
        _sync_directory(destination / "pdf_pages")
    _sync_directory(destination)


def begin_transition(
    data_dir: Path,
    current_pdf: Path,
    pages_dir: Path,
    prepared_root: Path | None,
    target_revision: int,
) -> Path:
    """Stage both generations before exposing any new live asset."""
    data_dir.mkdir(parents=True, exist_ok=True)
    transition = data_dir / TRANSITION_NAME
    if transition.exists():
        raise RuntimeError(f"Unresolved PDF asset transition at {transition}")
    staging = Path(tempfile.mkdtemp(prefix="asset-transition-preparing-", dir=data_dir))
    try:
        _copy_asset_set(current_pdf, pages_dir, staging / "old")
        if prepared_root is not None:
            prepared_pdf = prepared_root / "current.pdf"
            if not prepared_pdf.is_file():
                raise ValueError("Prepared PDF is missing")
            _copy_asset_set(prepared_pdf, prepared_root / "pdf_pages", staging / "new")
        else:
            (staging / "new").mkdir()
            _sync_directory(staging / "new")
        marker = staging / "manifest.json"
        with marker.open("w", encoding="utf-8") as output:
            json.dump({"targetRevision": target_revision}, output)
            output.flush()
            os.fsync(output.fileno())
        _sync_directory(staging)
        os.replace(staging, transition)
        _sync_directory(data_dir)
        return transition
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def install_asset_set(source: Path, current_pdf: Path, pages_dir: Path) -> None:
    """Idempotent install; the staged copy survives interruption for retry."""
    current_pdf.parent.mkdir(parents=True, exist_ok=True)
    pages_dir.mkdir(parents=True, exist_ok=True)
    source_pdf = source / "current.pdf"
    if source_pdf.exists():
        temporary_pdf = current_pdf.with_name(".current-installing.pdf")
        _copy_file(source_pdf, temporary_pdf)
        os.replace(temporary_pdf, current_pdf)
    else:
        current_pdf.unlink(missing_ok=True)
    for pattern in ("page-*.png", "page-*.svg"):
        for old in pages_dir.glob(pattern):
            old.unlink()
    source_pages = source / "pdf_pages"
    if source_pages.exists():
        for pattern in ("page-*.png", "page-*.svg"):
            for page in source_pages.glob(pattern):
                _copy_file(page, pages_dir / page.name)
    _sync_directory(pages_dir)
    _sync_directory(current_pdf.parent)


def recover_transition(
    data_dir: Path, current_pdf: Path, pages_dir: Path, committed_revision: int
) -> bool:
    transition = data_dir / TRANSITION_NAME
    if not transition.exists():
        return False
    marker = transition / "manifest.json"
    if not marker.is_file():
        raise RuntimeError(f"Incomplete PDF asset transition at {transition}; inspect before restarting")
    manifest = json.loads(marker.read_text(encoding="utf-8"))
    target_revision = manifest["targetRevision"]
    if type(target_revision) is not int or target_revision < 0:
        raise ValueError(f"Invalid PDF asset transition at {transition}")
    generation = "new" if committed_revision >= target_revision else "old"
    install_asset_set(transition / generation, current_pdf, pages_dir)
    shutil.rmtree(transition)
    _sync_directory(data_dir)
    return True


def finish_transition(data_dir: Path) -> None:
    transition = data_dir / TRANSITION_NAME
    shutil.rmtree(transition)
    _sync_directory(data_dir)
