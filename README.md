# Infinite Notes

Infinite Notes is a local-first PDF notebook with a native iPad client for Apple Pencil and a general computer server for storage, synchronization, PDF import/export, testing, and the fallback browser interface.

## Repository layout

```text
infinite-notes/
├── computer/   Linux/general-computer server and fallback web client
├── ipad/       SwiftPM + xtool native iPad application
├── scripts/    Setup, test, branch, backup, and transfer helpers
├── docs/       Architecture and version-control documentation
└── VERSION     Current stable project version
```

Notebook data is intentionally excluded from Git. The active PDF, ink state, page renders, `.inotes` exports, virtual environments, and build products remain local.

## First setup

### Computer

```bash
./scripts/setup-computer.sh
./scripts/run-computer.sh
```

The normal native-client address is usually `http://10.42.0.1:8000` when using the existing `NotesHotspot` profile. Use `./scripts/run-computer.sh --no-hotspot` on an existing LAN.

### iPad

Install xtool, connect and trust the iPad, then run:

```bash
./scripts/build-ipad.sh
```

The iPad app source is in `ipad/` and uses the existing bundle identifier so development installs update the same app.

## Development workflow

- `main` contains stable, tested releases.
- `develop` is the integration branch for completed work before release.
- `prototype/<name>` is for experiments that may be discarded.
- `feature/<name>` and `fix/<name>` are for focused production work.

Create a prototype from the current branch:

```bash
./scripts/new-prototype.sh pdf-cache-test
```

Run every available validation step:

```bash
./scripts/test-all.sh
```

See [docs/VERSION_CONTROL.md](docs/VERSION_CONTROL.md) for GitHub/GitLab setup, offline transfer, releases, and recovery commands.

## Current release

The repository starts at **v0.5.1**, including:

- Native vector PDF rendering
- Configurable Pencil pipeline and smooth pressure ribbons
- Pen pressure toggle, colour and width presets, line styles
- Geometry, snapping, X–Y planes and hold recognition
- Lasso selection, transforms, copy/paste and locking
- Eraser cursor and configurable eraser widths
- Patched v24-compatible computer server

## License

MIT. See [LICENSE](LICENSE).
