# Architecture

## Computer

`computer/server.py` owns the authoritative notebook state, PDF import/export, WebSocket synchronization, undo/redo persistence and the fallback browser client in `computer/static/`.

Runtime notebook files live under `computer/data/` and are ignored by Git.

## iPad

`ipad/` is a SwiftPM package built and installed with xtool. It uses native PDF rendering, page-local overlays, the configurable Pencil pipeline, geometry tools and the v24-compatible WebSocket protocol.

## Shared protocol

The computer and iPad communicate over the local network. The computer remains authoritative; the iPad stores application preferences locally and streams note operations to the server.

The two source trees live in one repository so a protocol change can be implemented, reviewed and tagged atomically.
