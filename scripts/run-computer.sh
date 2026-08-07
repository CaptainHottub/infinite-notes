#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v systemd-inhibit >/dev/null 2>&1; then
  exec systemd-inhibit --what=sleep --who="Infinite Notes" --why="Keep the Infinite Notes server available" "$ROOT/computer/run-native.sh" "$@"
else
  exec "$ROOT/computer/run-native.sh" "$@"
fi
