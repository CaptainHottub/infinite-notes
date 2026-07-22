# Computer setup

```bash
cd /path/to/infinite-notes
./scripts/setup-computer.sh
./scripts/run-computer.sh
```

The setup script creates `computer/.venv`, installs Python dependencies and runs the server tests.

To copy data from an older standalone server folder:

```bash
computer/copy-data-from-existing.sh /path/to/old/infinite-notes
```

The script backs up existing destination data before copying.
