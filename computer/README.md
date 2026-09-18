# Infinite Notes computer server

This directory contains the general-computer side of Infinite Notes:

- FastAPI and WebSocket server
- Authoritative notebook state
- Original PDF endpoint used by the native iPad app
- PDF import and export
- Undo and redo persistence
- Fallback Safari/browser client
- Tests and diagnostics

## Setup

From the repository root:

```bash
./scripts/setup-computer.sh
```

Or directly:

```bash
cd computer
./setup.sh --test
```

## Run

```bash
./scripts/run-computer.sh
```

Use `--no-hotspot` to stay on the current network:

```bash
./scripts/run-computer.sh --no-hotspot
```

Runtime notebook data is stored under `computer/data/` and intentionally ignored by Git.

The iPad can find either computer under **Settings → Connection → Nearby
servers** using Bonjour. See [server discovery](../docs/server-discovery.md)
for updating dependencies, selecting a computer, and manual-address fallback.

From the local desktop browser, exports can be saved beside the imported file.
See [eraser and export settings](../docs/eraser-and-export-settings.md) for the
source-folder workflow and its setup requirements.
