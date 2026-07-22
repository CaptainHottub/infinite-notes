#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(git rev-parse --show-toplevel)"
mkdir -p "$ROOT/transfer"
out="$ROOT/transfer/infinite-notes-all.bundle"
git bundle create "$out" --all
git bundle verify "$out"
echo "Created: $out"
