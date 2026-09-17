# Server notebook storage

The server now stores notebook metadata and individual strokes in
`computer/data/notebook.sqlite3` (or `INFINITE_NOTES_DATA_DIR/notebook.sqlite3`).
Ordinary completed strokes, erases, and transforms update only affected rows.
The writer collects ordinary completed Pencil strokes for up to 2.5 seconds,
or until 64 operations / 2 MiB of stroke payload are pending, then commits them
together. Undo/redo, import, reset, and other explicit actions flush promptly;
a final eraser message flushes its group. A queued producer
waits once the queue reaches 256 operations / 8 MiB. `stroke_ack`, `delete_ack`,
and successful HTTP mutation responses follow the durable transaction, never
precede it. SQLite runs in WAL mode with `synchronous=FULL`; a single worker
thread performs commits and checkpoints. An idle batch triggers a passive
checkpoint check only if the WAL is at least 32 MiB. Debug logging is separate
and off by default.

Repeated identical edits wait for an in-flight commit as well as queued edits.
Cancelling a request or ACK waiter does not cancel the underlying commit or
prevent other edits in its batch from receiving their durable completions.

On first startup, an existing `state.json` is imported transactionally and left
byte-for-byte unchanged. After that, SQLite is authoritative; `state.json` is a
**migration backup**, not a current copy. Restarting does not re-import it.
An unreadable legacy source or corrupt database aborts startup rather than
silently creating an empty notebook. An uninitialized database can be retried
from the original JSON. Do not use an older server build against this data
directory: it would read the stale JSON and lose post-migration edits. Export a
fresh project archive from the new server before any intentional downgrade.

For a consistent backup while the server is running, use SQLite's online backup
API rather than copying only the main database file. For example, stop other
changes or choose a quiet moment, then run (with the correct data directory):

```python
import sqlite3
source = sqlite3.connect("computer/data/notebook.sqlite3")
target = sqlite3.connect("/safe/backup/notebook.sqlite3")
source.backup(target)
target.close()
source.close()
```

Also copy `current.pdf` and `pdf_pages/` for a full notebook backup, or use the
project export endpoint, which packages notebook content and PDF. A direct file
backup requires coordinating those assets with the database revision. PDF/page
changes stage old and new asset generations under `asset-transition/`; startup
uses the committed revision to finish or roll back an interrupted install.
Keep that directory if recovery reports an error rather than deleting it.

The iPad offline-journal filename validation fix is separate from this server storage change.
An unacknowledged edit can still be lost on a crash, and the server does not yet
provide persistent undo history or a general operation-ID deduplication scheme.
The bounded `revision_changes` table stores only touched stroke IDs and reset
markers, in the same commit as each mutation. It retains at most 512 revisions
for the server-side delta endpoint; pruning does not alter notebook contents.

## Synthetic measurements

Run `computer/.venv/bin/python computer/benchmarks/persistence_bench.py` and
`computer/.venv/bin/python computer/benchmarks/server_bench.py` from the
repository root. Both create and remove their own temporary notebooks. On the
development machine, a 2,400-stroke / 28.5 MB synthetic state produced about
28.8 KB of WAL growth per ordinary single-stroke commit; a 64-stroke burst used
one transaction and about 808 KB of WAL growth. A 4,800-stroke / 57.0 MB state
showed similar single-stroke WAL growth. The WebSocket benchmark on the 2,400-
stroke state yielded 64 ACKs from one transaction with p50/p95 latencies of
about 23/29 ms. A lone stroke waited about 2,504 ms for the new collection
deadline. Explicit undo/redo and final eraser actions bypass that wait.
These are local temporary-filesystem results, not iPad measurements or estimates
of physical SSD wear. `/proc/self/io` did not report useful additional write
bytes for the temporary-filesystem run.
