"""Desktop file selection and machine-local export destinations (never archived)."""

import asyncio
import errno
import json
import logging
import os
from pathlib import Path
import shutil
import tempfile


def picker_program():
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return None
    return shutil.which("kdialog") or shutil.which("zenity")


async def choose_path(kind):
    program = picker_program()
    if not program:
        raise RuntimeError("A desktop file picker (kdialog or zenity) is required")
    title = "Choose the original import folder for exports" if kind == "folder" else "Open PDF" if kind == "pdf" else "Import Infinite Notes project"
    pattern = "*.pdf" if kind == "pdf" else "*.inotes *.zip"
    if Path(program).name == "kdialog":
        args = [program, "--title", title, "--getexistingdirectory" if kind == "folder" else "--getopenfilename", str(Path.home())]
        if kind != "folder":
            args.append(pattern)
    else:
        args = [program, "--file-selection", "--title", title]
        args += ["--directory"] if kind == "folder" else ["--file-filter", pattern]
    process = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=300)
    except BaseException:
        if process.returncode is None:
            process.kill()
        await process.communicate()
        raise
    if process.returncode == 1:  # User cancelled.
        return None
    if process.returncode != 0:
        raise RuntimeError("Desktop file picker failed")
    selected = stdout.decode().rstrip("\r\n")
    return Path(selected).absolute() if selected else None


def clear_origin(data_dir):
    (data_dir / "export-origin.json").unlink(missing_ok=True)


def set_origin(data_dir, document_id, folder):
    folder = Path(folder).absolute()
    if not folder.is_dir():
        raise ValueError("Export folder does not exist")
    fd, name = tempfile.mkstemp(prefix="export-origin-", dir=data_dir)
    try:
        with os.fdopen(fd, "w") as file:
            json.dump({"documentId": document_id, "folder": str(folder)}, file)
            file.flush()
            os.fsync(file.fileno())
        os.replace(name, data_dir / "export-origin.json")
    finally:
        Path(name).unlink(missing_ok=True)


def get_origin(data_dir, document_id):
    try:
        value = json.loads((data_dir / "export-origin.json").read_text())
        if not isinstance(value, dict):
            raise ValueError("Invalid saved export folder record")
        if value.get("documentId") != document_id:
            return None
        folder = Path(value["folder"])
        if not folder.is_absolute():
            raise ValueError("Saved export folder must be absolute")
        return folder
    except FileNotFoundError:
        return None
    except (OSError, ValueError, KeyError, TypeError):
        logging.getLogger(__name__).warning("Could not read saved export folder; select it again", exc_info=True)
        return None


def save_export(source, folder, filename):
    """Publish a complete file without overwriting originals or earlier exports."""
    filename = Path(filename).name
    fd, temporary = tempfile.mkstemp(prefix=".infinite-notes-export-", dir=folder)
    try:
        with os.fdopen(fd, "wb") as output, Path(source).open("rb") as input_file:
            shutil.copyfileobj(input_file, output)
            output.flush()
            os.fsync(output.fileno())
        base = Path(filename)
        for number in range(10000):
            name = filename if number == 0 else f"{base.stem} ({number}){base.suffix}"
            destination = folder / name
            try:
                # Atomic no-clobber publication in the same filesystem.
                os.link(temporary, destination)
                return destination
            except FileExistsError:
                continue
            except OSError as exc:
                if exc.errno not in {errno.EPERM, errno.ENOTSUP, errno.EOPNOTSUPP}:
                    raise
                # FAT/exFAT and some network drives do not support hard links.
                # Reserve a new filename exclusively before replacing that placeholder.
                try:
                    reserved = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                except FileExistsError:
                    continue
                os.close(reserved)
                try:
                    os.replace(temporary, destination)
                except BaseException:
                    destination.unlink(missing_ok=True)
                    raise
                return destination
        raise OSError("Too many exports with the same name")
    finally:
        Path(temporary).unlink(missing_ok=True)
