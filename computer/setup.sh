#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

install_system_packages=true
run_tests=false

usage() {
  cat <<'USAGE'
Usage: ./setup.sh [options]

Options:
  --no-system-packages  Do not use the OS package manager when Python is missing
  --test                Install development dependencies and run all tests
  -h, --help            Show this help
USAGE
}

while (($#)); do
  case "$1" in
    --no-system-packages) install_system_packages=false ;;
    --test) run_tests=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

have_usable_python() {
  command -v python3 >/dev/null 2>&1 && python3 - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
}

install_python() {
  local distro_id="" distro_like=""

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    distro_id="${ID:-}"
    distro_like="${ID_LIKE:-}"
  fi

  if [[ "$distro_id" == "fedora" || "$distro_like" == *"fedora"* || "$distro_like" == *"rhel"* ]]; then
    sudo dnf install -y python3 python3-pip
  elif [[ "$distro_id" == "ubuntu" || "$distro_id" == "debian" || "$distro_like" == *"debian"* ]]; then
    sudo apt-get update
    sudo apt-get install -y python3 python3-venv python3-pip
  elif [[ "$distro_id" == "arch" || "$distro_like" == *"arch"* ]]; then
    sudo pacman -S --needed python python-pip
  elif [[ "$distro_id" == "opensuse-tumbleweed" || "$distro_id" == "opensuse-leap" || "$distro_like" == *"suse"* ]]; then
    sudo zypper install -y python3 python3-pip
  else
    echo "Could not identify a supported package manager." >&2
    echo "Install Python 3.10+, pip, and venv support, then rerun ./setup.sh." >&2
    exit 1
  fi
}

if ! have_usable_python; then
  if [[ "$install_system_packages" == true ]]; then
    echo "Python 3.10+ was not found. Installing it..."
    install_python
  else
    echo "Python 3.10+ is required." >&2
    exit 1
  fi
fi

if ! python3 -m venv --help >/dev/null 2>&1; then
  if [[ "$install_system_packages" == true ]]; then
    echo "Python venv support is missing. Installing it..."
    install_python
  else
    echo "Python venv support is required." >&2
    exit 1
  fi
fi

if [[ ! -d .venv ]]; then
  echo "Creating the Python virtual environment..."
  python3 -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt

if [[ "$run_tests" == true ]]; then
  python -m pip install -r requirements-dev.txt
  python -m pytest -q
else
  python -m compileall -q server.py
fi

mkdir -p data/pdf_pages
chmod +x run.sh setup.sh diagnose.sh install-desktop-shortcut.sh

if ! command -v nmcli >/dev/null 2>&1; then
  echo
  echo "Warning: nmcli was not found."
  echo "The default ./run.sh mode requires NetworkManager to start NotesHotspot."
  echo "You may still run the server with ./run.sh --no-hotspot."
fi

echo
echo "Infinite Notes is ready."
echo "Start app + NotesHotspot: ./run.sh"
echo "Start server only:          ./run.sh --no-hotspot"
echo "Check configuration:        ./diagnose.sh"
