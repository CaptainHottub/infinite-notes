#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/existing/infinite-notes-folder" >&2
  exit 2
fi

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
SOURCE="$(cd "$1" && pwd)"

if [[ ! -d "$SOURCE/data" ]]; then
  echo "No data/ directory found in: $SOURCE" >&2
  exit 1
fi

stamp="$(date +%Y%m%d-%H%M%S)"
if [[ -e data/state.json || -e data/current.pdf ]]; then
  mkdir -p "data-backups/$stamp"
  cp -a data/. "data-backups/$stamp/"
  echo "Backed up current data to data-backups/$stamp/"
fi

mkdir -p data
cp -a "$SOURCE/data/." data/
mkdir -p data/pdf_pages

echo "Copied notebook data from: $SOURCE/data"
echo "Run ./setup.sh --test, then ./run-native.sh"
