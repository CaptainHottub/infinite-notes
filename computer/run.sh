#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

connection="${NOTES_HOTSPOT_CONNECTION:-NotesHotspot}"
host="0.0.0.0"
port="8000"
open_browser=true
use_hotspot=true
reload=false
server_pid=""
hotspot_started=false
cleanup_done=false

usage() {
  cat <<'USAGE'
Usage: ./run.sh [options]

Starts the NetworkManager hotspot, runs Infinite Notes, and shuts both down
when the server exits or you press Ctrl+C.

Options:
  --connection NAME  NetworkManager connection profile (default: NotesHotspot)
  --host ADDRESS     Server bind address (default: 0.0.0.0)
  --port PORT        Server port (default: 8000)
  --no-hotspot       Run the notes server without changing NetworkManager
  --no-open          Do not automatically open the desktop browser
  --reload           Enable Uvicorn development auto-reload
  -h, --help         Show this help

Environment:
  NOTES_HOTSPOT_CONNECTION may also set the default connection profile.
USAGE
}

while (($#)); do
  case "$1" in
    --connection)
      [[ $# -ge 2 ]] || { echo "--connection requires a name" >&2; exit 2; }
      connection="$2"
      shift
      ;;
    --host)
      [[ $# -ge 2 ]] || { echo "--host requires an address" >&2; exit 2; }
      host="$2"
      shift
      ;;
    --port)
      [[ $# -ge 2 ]] || { echo "--port requires a value" >&2; exit 2; }
      port="$2"
      shift
      ;;
    --no-hotspot) use_hotspot=false ;;
    --no-open) open_browser=false ;;
    --reload) reload=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || {
  echo "Invalid port: $port" >&2
  exit 2
}

cleanup() {
  local status=$?

  if [[ "$cleanup_done" == true ]]; then
    return
  fi
  cleanup_done=true
  trap - EXIT INT TERM HUP

  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    echo
    echo "Stopping Infinite Notes..."

    # Ctrl+C is delivered to both this shell and the server process group.
    # Give Uvicorn a brief chance to finish its own graceful shutdown before
    # sending another signal.
    for _ in {1..5}; do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.1
    done

    if kill -0 "$server_pid" 2>/dev/null; then
      kill -INT "$server_pid" 2>/dev/null || true
    fi

    for _ in {1..20}; do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.1
    done

    if kill -0 "$server_pid" 2>/dev/null; then
      kill -TERM "$server_pid" 2>/dev/null || true
    fi
    wait "$server_pid" 2>/dev/null || true
  fi

  if [[ "$hotspot_started" == true ]]; then
    echo "Stopping hotspot '$connection'..."
    nmcli connection down "$connection" >/dev/null 2>&1 || {
      echo "Warning: NetworkManager could not stop '$connection'." >&2
    }
  fi

  if [[ "$use_hotspot" == true ]]; then
    echo "Infinite Notes and hotspot stopped."
  else
    echo "Infinite Notes stopped."
  fi

  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ ! -x .venv/bin/python ]]; then
  echo "First launch: preparing the Python environment..."
  ./setup.sh
fi

if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
  echo "TCP port $port is already in use." >&2
  echo "Use another port, for example: ./run.sh --port 8080" >&2
  exit 1
fi

hotspot_device=""
hotspot_address=""

if [[ "$use_hotspot" == true ]]; then
  command -v nmcli >/dev/null 2>&1 || {
    echo "nmcli is required to start '$connection'." >&2
    echo "Install/enable NetworkManager, or use ./run.sh --no-hotspot." >&2
    exit 1
  }

  if ! nmcli -t -f NAME connection show | grep -Fxq "$connection"; then
    echo "NetworkManager connection '$connection' does not exist." >&2
    echo "Create that hotspot profile first, or select another profile with:" >&2
    echo "  ./run.sh --connection OTHER_NAME" >&2
    exit 1
  fi

  echo "Starting hotspot '$connection'..."
  nmcli connection up "$connection"
  hotspot_started=true

  hotspot_device="$(nmcli -g GENERAL.DEVICES connection show "$connection" 2>/dev/null | head -n1 | xargs || true)"
  if [[ -n "$hotspot_device" && "$hotspot_device" != "--" ]]; then
    hotspot_address="$(ip -4 -o address show dev "$hotspot_device" scope global 2>/dev/null \
      | awk 'NR == 1 { split($4, address, "/"); print address[1] }')"
  fi
fi

desktop_url="http://127.0.0.1:${port}/?mode=desktop"

echo
echo "Infinite Notes"
echo "Desktop: $desktop_url"
if [[ -n "$hotspot_address" ]]; then
  echo "iPad:   http://${hotspot_address}:${port}/?mode=ipad"
elif [[ "$use_hotspot" == true ]]; then
  echo "iPad:   hotspot is active, but its IPv4 address could not be detected"
else
  echo "iPad:   use the laptop's LAN address with port $port"
fi
if [[ "$use_hotspot" == true ]]; then
  echo "Press Ctrl+C to stop the app and hotspot."
else
  echo "Press Ctrl+C to stop the app."
fi
echo

if [[ "$open_browser" == true ]] && command -v xdg-open >/dev/null 2>&1; then
  (
    for _ in {1..60}; do
      if .venv/bin/python - "$port" <<'PY' >/dev/null 2>&1
import socket
import sys

with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.15):
    pass
PY
      then
        xdg-open "$desktop_url" >/dev/null 2>&1 || true
        exit 0
      fi
      sleep 0.2
    done
  ) &
fi

server_args=(server.py --host "$host" --port "$port")
if [[ "$reload" == true ]]; then
  server_args+=(--reload)
fi

.venv/bin/python "${server_args[@]}" &
server_pid=$!

set +e
wait "$server_pid"
server_status=$?
set -e
server_pid=""
exit "$server_status"
