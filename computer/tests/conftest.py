"""Keep every server test isolated before importing the application module."""

import os
import sys
import tempfile
from pathlib import Path


COMPUTER_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(COMPUTER_DIR))

# Collection imports server.py, which opens the configured notebook immediately.
# Set the path here, before importing any test module, even if the caller had a
# data-dir override in their shell.
TEST_DATA_DIR = tempfile.TemporaryDirectory(prefix="infinite-notes-tests-")
os.environ["INFINITE_NOTES_DATA_DIR"] = TEST_DATA_DIR.name
