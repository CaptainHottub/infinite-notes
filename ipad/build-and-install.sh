#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
rm -rf .build xtool
./validate-package.sh
exec xtool dev
