#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 1 ]] || { echo "Usage: $0 /path/to/infinite-notes-data.tar.gz" >&2; exit 2; }
archive="$(realpath "$1")"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$archive" ]] || { echo "Archive not found: $archive" >&2; exit 1; }
mkdir -p "$ROOT/backups"
if [[ -d "$ROOT/computer/data" ]]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  tar -C "$ROOT/computer" -czf "$ROOT/backups/pre-restore-data-$stamp.tar.gz" data
fi
rm -rf "$ROOT/computer/data"
tar -C "$ROOT/computer" -xzf "$archive"
mkdir -p "$ROOT/computer/data/pdf_pages"
touch "$ROOT/computer/data/.gitkeep" "$ROOT/computer/data/pdf_pages/.gitkeep"
echo "Restored notebook data from: $archive"
