#!/usr/bin/env bash
set -u

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

connection="${NOTES_HOTSPOT_CONNECTION:-NotesHotspot}"
port="8000"
failures=0

usage() {
  cat <<'USAGE'
Usage: ./diagnose.sh [options]

Options:
  --connection NAME  NetworkManager connection profile (default: NotesHotspot)
  --port PORT        Server port to inspect (default: 8000)
  -h, --help         Show this help
USAGE
}

while (($#)); do
  case "$1" in
    --connection)
      [[ $# -ge 2 ]] || { echo "--connection requires a name" >&2; exit 2; }
      connection="$2"
      shift
      ;;
    --port)
      [[ $# -ge 2 ]] || { echo "--port requires a value" >&2; exit 2; }
      port="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

warn() { printf 'WARN: %s\n' "$*"; }
pass() { printf ' OK : %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }

echo "Infinite Notes diagnostics"
echo "=========================="

if command -v python3 >/dev/null 2>&1; then
  version="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
  if python3 - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
  then
    pass "Python $version"
  else
    fail "Python $version is too old; Python 3.10+ is required"
  fi
else
  fail "python3 is not installed"
fi

if [[ -x .venv/bin/python ]]; then
  pass "Virtual environment exists"
  if .venv/bin/python - <<'PY' >/dev/null 2>&1
import fastapi
import fitz
import multipart
import uvicorn
PY
  then
    pass "Application dependencies import successfully"
  else
    fail "Python dependencies are incomplete; run ./setup.sh"
  fi
else
  warn "Virtual environment is missing; run ./setup.sh"
fi

if [[ -d data && -w data ]]; then
  pass "Data directory is writable"
else
  fail "Data directory is missing or not writable"
fi

if command -v nmcli >/dev/null 2>&1; then
  pass "NetworkManager/nmcli is available"

  if nmcli -t -f NAME connection show | grep -Fxq "$connection"; then
    pass "Connection profile '$connection' exists"

    autoconnect="$(nmcli -g connection.autoconnect connection show "$connection" 2>/dev/null || true)"
    if [[ "$autoconnect" == "no" ]]; then
      pass "Autoconnect is disabled for '$connection'"
    elif [[ -n "$autoconnect" ]]; then
      warn "Autoconnect for '$connection' is '$autoconnect'; expected 'no'"
    fi

    if nmcli -t -f NAME connection show --active | grep -Fxq "$connection"; then
      warn "'$connection' is currently active; ./run.sh will stop it when exiting"
    else
      pass "'$connection' is currently inactive"
    fi
  else
    fail "Connection profile '$connection' does not exist"
  fi
else
  fail "nmcli is unavailable; default ./run.sh hotspot mode cannot work"
fi

if command -v ss >/dev/null 2>&1; then
  if ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
    warn "TCP port $port is currently in use"
  else
    pass "TCP port $port is available"
  fi
else
  warn "ss is unavailable; port $port was not checked"
fi

echo
if ((failures)); then
  echo "$failures blocking problem(s) found."
  exit 1
fi

echo "No blocking problems found."
