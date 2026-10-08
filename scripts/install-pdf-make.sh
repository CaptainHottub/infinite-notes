#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
launcher="$project_root/scripts/pdf-make"
bin_dir="${PDF_MAKE_BIN_DIR:-$HOME/.local/bin}"
target="$bin_dir/pdf-make"

mkdir -p -- "$bin_dir"
if [[ -L "$target" && "$(readlink -f -- "$target")" == "$launcher" ]]; then
  echo "pdf-make already uses the vector generator: $target"
  exit 0
fi
if [[ -e "$target" || -L "$target" ]]; then
  backup="$target.raster-backup-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mv -- "$target" "$backup"
  echo "Previous pdf-make preserved at: $backup"
fi
ln -s -- "$launcher" "$target"
echo "Installed vector pdf-make: $target"
