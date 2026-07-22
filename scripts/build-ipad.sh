#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/ipad"
rm -rf .build xtool
./validate-package.sh
exec xtool dev "$@"
