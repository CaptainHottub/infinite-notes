# Synchronization revisions

The server persists a UUID `documentId` and a non-negative `documentRevision`
beside the notebook state. Legacy state files receive a generated identity and
revision `0` without changing document or stroke content. Each effective
accepted mutation advances the revision once; content and the final revision
for a batch are committed together in SQLite. See [server notebook storage](server-persistence.md)
for migration, backup, and rollback details.

The server exposes `documentRevision` as additive metadata in:

- `/api/state` responses;
- native `state_refresh` messages;
- native `stroke_ack`, `reconcile_ack`, and `delete_ack` messages.

Imported project archives are treated as document content, not as synchronization
authority. Their revision metadata is discarded, and importing advances the
server's existing revision instead of replacing or decreasing it. A valid project
identity is preserved across export/import; legacy projects receive a new one.
Opening a new PDF creates a new identity, while page insertion and append preserve
the current notebook identity.

On reconnect, the iPad compares the server's initial document identity, revision,
and `stateToken` with the last complete state it applied. All three must match,
and there must be no unacknowledged or live strokes, before it skips downloading
the notebook and source PDF. The token distinguishes server instances: two copies
of an exported project may share an identity and revision while containing
different edits. A server restart changes the token and still requires a fresh
snapshot; deltas are used only within the same server instance.
Snapshots missing comparison metadata clear the previous values. A revision received in a mutation ACK is deliberately not
enough to advance this comparison: that ACK proves the local operation is
durable, but not that every concurrent remote operation through the same revision
has already reached the iPad.

Pending local strokes are still reconciled before any reconnect state decision.
The server now records a bounded, durable index of changed stroke IDs with each
revision in the same SQLite transaction as the stroke rows. `GET /api/changes`
accepts `documentId` and `sinceRevision` and returns at most 64 revisions and
512 KiB of current stroke values per response. It returns `more` with a
`nextRevision` cursor for another page, or `snapshot_required` if the requested
history was pruned, a document/metadata reset intervened, or the response is
too large. Only the IDs are duplicated on disk, not full stroke payloads.
On an initial reconnect with the same notebook and server instance, and no
pending/live strokes, the iPad requests up to eight pages of deltas and applies
them only after a complete, contiguous response. If a local or WebSocket edit
occurs while pages are loading,
or any page is missing, invalid, or too large, it falls back to `/api/state`.
Page/PDF metadata changes also require the full snapshot. Persistent operation
IDs and broader offline operation replay remain later scoped changes.
Full-state HTTP responses are not applied if local or WebSocket ink changed
while the download was in flight. The client waits for pending acknowledgements
and live strokes to finish, then retries after a short quiet interval. A refresh
deferred for a pending stroke also resumes after its ordinary stroke ACK; it no
longer depends on receiving a separate reconciliation ACK.
On disconnect, incomplete remote stroke previews are discarded and force a new
snapshot; an active local Pencil stroke is retained. If a remote stroke finishes
without its start having reached this client, the client requests its durable
state. WebSocket frames are applied serially, and queued frames from a replaced
connection are ignored.

## Completed-stroke recovery journal

The native app saves each completed Pencil stroke in its Application Support
`InfiniteNotes/PendingStrokes/<document UUID>/` directory before sending its final
commit message. Each stroke has its own atomically replaced JSON file. An ACK
with the matching document identity removes that record. A new app process loads
the matching notebook's records after receiving the server's identity summary,
then replays them through the existing bounded `reconcile_strokes` protocol.

Records for other notebooks remain on disk. An identity mismatch with pending
in-memory strokes blocks reconciliation and snapshot replacement. The server
checks supplied document identities under its state lock for replay and streamed
Pencil messages. Legacy clients may omit identity; updated native clients require
the updated server's identity-bearing ACKs for journal cleanup.

Storage errors are shown in the app and block automatic replay. Corrupt records
are retained for recovery. The loader accepts equivalent UUID letter casing and
checks the encoded stroke filename independently of absolute URL spelling.
Genuinely mismatched records still block replay; the error and debug log name
the offending file and validation reason without deleting it. This journal covers completed strokes, not a full
offline notebook cache: restarting the app still requires reconnecting to load
the notebook. Erases, transforms, page changes, interrupted live strokes, and
conflict resolution against later remote edits are not covered. In particular,
the existing stroke replay protocol does not yet prevent replay of an unacknowledged
stroke that another client subsequently deleted. Full operation history and
duplicate-operation tracking are still required for that guarantee.

Storage tests (from the repository root):

```sh
swiftc ipad/Sources/InfiniteNotesStrokeLab/PendingStrokeJournal.swift ipad/Tests/PendingStrokeJournalTests.swift -o /tmp/infinite-notes-journal-tests
/tmp/infinite-notes-journal-tests
```
