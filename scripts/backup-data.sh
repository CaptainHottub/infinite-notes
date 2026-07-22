#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$ROOT/computer/data"
mkdir -p "$ROOT/backups"
stamp="$(date +%Y%m%d-%H%M%S)"
out="$ROOT/backups/infinite-notes-data-$stamp.tar.gz"
if [[ ! -d "$DATA" ]]; then
  echo "No computer/data directory found." >&2
  exit 1
fi
tar -C "$ROOT/computer" -czf "$out" data
echo "Created private notebook backup: $out"
echo "This file is ignored by Git; transfer it separately and securely."
