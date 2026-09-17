# Execution brief for GPT-Sol: incremental server persistence

## Objective and scope

Implement SQLite persistence with bounded group commits so ordinary editing no longer rewrites the complete `state.json` or forces a separate disk flush for every edit. Minimize disk writes while preserving durable acknowledgements and keeping network processing responsive.

Continue from the current working tree, including its uncommitted changes. The user explicitly accepts that the current code has other bugs. Preserve unrelated changes. Do not repair the iPad offline-journal problem, redesign synchronization, add desktop features, or require another iPad stress test as part of this task.

This document is a handoff specification, not a claim that the implementation exists. Read applicable repository instructions before starting. Inspect, give a short implementation plan, implement, validate, and inspect the final diff. Do not migrate or benchmark against the user's live notebook as a development step; use isolated copies and temporary directories.

## Evidence and entry points

Line numbers below refer to the source at handoff creation; locate symbols again before editing.

- `computer/server.py:218`, `write_state_atomic`: serializes the full state, flushes, calls `fsync`, and replaces `state.json`.
- `computer/server.py:232`, `load_state`: loads/migrates the legacy JSON at startup. Module-level initialization currently calls it.
- `computer/server.py:315`, `save_state_atomic`: advances revision metadata around the full save.
- `computer/server.py:2084`: stroke completion calls the synchronous save inside `state_lock` before sending its ACK.
- `computer/server.py:2331`: deletion saves unconditionally, including deletes that remove nothing.
- `computer/server.py:1581`, `/api/state`: copies and serializes the complete in-memory state under the lock. This is a separate performance issue; preserve the endpoint's format.
- `computer/server.py:1888`, `export_project`: preserve the existing portable project format.
- `computer/tests/test_server.py:24`: many existing tests bypass persistence by monkeypatching `save_state_atomic`. Such tests cannot establish the new durability guarantees.
- `computer/tests/test_document_revision.py:17`: this test module imports the server before its temporary paths are configured. Audit import-time data access before executing a suite that could trigger migration.
- `docs/sync-revisions.md:22`: revisions and server-instance tokens participate in reconnect decisions. ACK metadata proves persistence of an operation, not application of an entire snapshot by the client.

The recorded session `computer/logs/infinite-notes-debug-20260916T203719Z-d2feb45e9c8d4a5b9f15152d1b442db2.jsonl` contains 27 completed saves totaling 771,843,335 serialized bytes, averaging 1,089.75 ms each. Lines 17–22 show one save delaying a stroke ACK; lines 505–508 show a full save for a deletion that deleted zero strokes. These are logical serialized bytes, not measurements of physical SSD writes.

## Storage design

Use Python's standard-library `sqlite3`, with a database under the configured data directory, provisionally `notebook.sqlite3`.

- Store each stroke as a separate row keyed by its identity. Its existing JSON representation can be the row payload; do not store the entire notebook as a single JSON blob.
- Store document identity, format version, committed revision, and document/page metadata separately from stroke payloads. Preserve supported metadata during migration and export.
- Use WAL mode and `synchronous=FULL`. Verify settings on the actual writer connection. Do not disable synchronization or select a weaker durability mode to improve benchmark numbers.
- A transaction changes only the affected stroke rows and necessary metadata. Whole-document import/reset and page changes may legitimately affect many rows.
- Use one dedicated writer with one owned connection. Pass immutable, bounded mutation payloads to it; never give it the concurrently mutated global `state` dictionary.
- Keep database writes, commits, and checkpoints off the asyncio event-loop thread. Maintain a single ordered stream of mutations.
- Retain compatible in-memory representations and wire payloads where practical. Separate committed state from live/provisional editing sufficiently to prevent unsaved mutations from appearing as durable state.

WAL is SQLite's recovery mechanism. It is not the future application-level operation history for reconnect synchronization. Do not add an unbounded duplicate operation log in this task.

## Batching and minimizing writes

Start a commit deadline when the first pending mutation arrives. Default maximum collection window: **250 ms**. Commit sooner on a bounded operation-count or payload-byte threshold. Choose and document conservative limits; they must accommodate existing valid large operations without creating unbounded queues.

- Continuous input must not reset the deadline indefinitely.
- No pending changes means no periodic commit or disk write.
- Pencil point streaming stays provisional; persist completed strokes, not every point frame.
- Multiple mutations may share one durable transaction. Preserve their logical order, undo grouping, and per-request completion results.
- Skip actual data writes and revision increments for true no-ops. A duplicate request may still need an ACK after the original durable result is known.
- Compare with committed/pending persistence state, not just the live drawing dictionary: a newly finished stroke can already exist in that dictionary while still requiring its first durable write.
- Do not add disk writes solely to report metrics or update unchanged metadata. Debug logging remains opt-in and should be accounted for separately in measurements.

**Critical batching trap:** awaiting a 250 ms commit inside the WebSocket receive loop before accepting the next message from that same socket defeats batching for a single iPad and stalls live input. Design receipt, ordered mutation processing, and commit completion so one busy client can contribute multiple edits to a batch. Use bounded queues and managed completion tasks, not unbounded detached tasks. Likewise, do not hold a global lock across the batching delay so every producer is prevented from enqueueing.

A 250 ms window bounds intentional collection delay, not total ACK latency under disk stalls or backpressure. Log both separately.

## Durability, ordering, and failure rules

1. Never send a durable-success ACK or HTTP mutation-success response before its database transaction commits.
2. Persist content and the corresponding document revision atomically. Prefer one logical revision increment per effective accepted mutation, even when several mutations share a physical commit. Document any necessary compatibility adjustment explicitly.
3. Return ACK metadata describing the committed result. Preserve existing client message ordering requirements, including history notifications relative to stroke ACKs. Prevent completion callbacks from publishing older committed state after newer results.
4. Keep server-instance token behavior across restarts. No-op mutations must not falsely advertise a new durable document version.
5. A failed commit rolls back the transaction, sends no success ACK, and does not leave failed data advertised as authoritative in memory. Explicitly design how queued dependent edits, undo/redo state, and provisional broadcasts recover or stop after failure; rolling back only the revision number is insufficient.
6. Client disconnection after acceptance must not cancel a transaction or discard already accepted work. Failure to deliver an ACK does not undo a committed edit.
7. A crash can lose unacknowledged work. Every acknowledged edit must be recoverable after restart, subject to the storage device honoring durability requests. Handle the commit-before-ACK crash window without claiming a new general duplicate-operation protocol exists.
8. Snapshots, project/PDF export, document switches, imports, reset, and shutdown need explicit ordering barriers. A snapshot must not label queued/uncommitted edits as durable. A document switch must not let an old document's queued edits reach the new document.
9. Graceful shutdown stops intake, drains accepted work, and closes the worker/connection with bounded error handling. Startup and shutdown must also work in isolated tests with multiple application instances/event loops.

PDF assets live outside SQLite. Inspect `commit_prepared_pdf` and import/page handlers: a database transaction alone cannot roll back filesystem replacements. Preserve a recoverable old/new asset pairing using staging and a documented recovery mechanism where needed. Include failure tests; do not claim whole-notebook atomicity merely because database rows are transactional. This does not authorize a wider PDF rendering redesign.

## Migration, backups, and checkpoints

- On first successful startup with no established database, import the legacy JSON transactionally. Preserve stroke content, document identity, revision, and supported metadata; normalize legacy metadata only according to existing compatibility rules.
- Leave the original `state.json` byte-for-byte intact. Record successful migration/schema initialization in the database transaction. Verify content equivalence, not only stroke count.
- An interrupted initialization must be detected and safely retried or reported. An existing valid database becomes authoritative; subsequent starts must never re-import the now-stale JSON.
- Corrupt/unreadable databases or legacy files must produce an actionable failure while preserving originals. Do not silently create an empty notebook or fall back to a stale JSON copy.
- After migration, ordinary edits never update the legacy JSON. JSON remains an on-demand export/API representation. Document clearly that the retained file is a migration backup, not current state.
- Avoid maintaining a second continuously rewritten JSON backup. Document a consistent SQLite backup procedure; copying only the main database while WAL is active is insufficient.
- Bound WAL growth with a deliberate checkpoint policy. Prefer idle/size-based work on the storage worker; prevent checkpoint-per-edit behavior and account for long readers/checkpoint stalls. No automatic full vacuum per edit or periodic whole-notebook rewrite.
- Explain downgrade/rollback: returning to the old JSON would discard post-migration edits unless a fresh compatible export is produced first. Preserve the user's source data and do not perform a downgrade automatically.

## Mutation coverage

Search every `save_state_atomic`, `write_state_atomic`, `STATE_FILE`, and mutation of authoritative state. Explicitly cover:

- Normal `stroke_end`, including a missing streamed stroke restored from its final payload.
- `reconcile_strokes`, including unchanged/repeated strokes and batches containing changed and unchanged entries.
- `add_strokes`, `replace_strokes`, grouped erasure, and empty/final erase messages.
- Undo, redo, clear, and the HTTP reset endpoint.
- PDF open, page insertion/append, and project import.
- Snapshot reads and PDF/project exports while edits are queued.

The initial durable implementation must cover these paths. Do not ship a partial replacement that leaves ordinary edits invoking a full JSON save. Full operation IDs, conflict resolution, persistent undo history across restarts, and the iPad journal repair remain separate work.

## Implementation sequence

1. Inspect the dirty tree and applicable rules; run safe baseline checks with temporary data paths. Make test configuration isolate all startup/migration IO before importing the server.
2. Build the storage layer, migration, and failure-safe transaction API with focused tests.
3. Implement the ordered writer, bounded batch scheduler, completion handling, and lifecycle. Test genuine batching from one WebSocket client.
4. Integrate all mutation and read-barrier paths. Preserve current protocol compatibility and update fixtures that assumed JSON persistence.
5. Add crash/failure and performance evidence, then update storage/debug/revision documentation and known limitations.
6. Inspect the full diff for unrelated changes and accidental writes to real notebook data. Hand off concrete results and remaining risks.

## Required validation

Use temporary directories and subprocesses for storage/restart tests. Use deterministic scheduler controls where possible instead of fragile timing assertions.

- **Migration:** content-equivalent import, unchanged legacy file, correct ID/revision, restart, interrupted import, invalid input, and a pre-existing database alongside stale JSON.
- **Incremental writes:** finishing one stroke does not serialize or rewrite unrelated strokes or the legacy JSON. Erasing touches affected rows only. No-ops cause no data transaction/revision advance.
- **Batching:** a burst from one actual WebSocket client yields fewer commits than mutations. Continuous drawing does not indefinitely postpone commit. Idle periods cause no commits. Size limits and backpressure work.
- **Durability:** ACK/HTTP-success withheld until commit; force-kill after an ACK and recover that edit. Kill before commit and verify consistency. Exercise commit-before-ACK, rollback, disk/write errors, and reconnect after ACK delivery failure.
- **Ordering:** multiple clients, undo/redo following queued edits, grouped erase, snapshot/export barriers, reset/import/document switches, and failed transactions with later queued work.
- **Responsiveness:** delayed database commits do not block heartbeat processing or other event-loop callbacks. A slow disk does not create unbounded tasks or memory growth.
- **Lifecycle:** shutdown drains work; separate test app instances do not share workers, event loops, connections, or notebook data.
- **Assets:** inject failure around PDF replacement/database commit and demonstrate the documented recovery behavior.
- **Compatibility:** existing server, revision, reconciliation, debug, and native/browser contract tests remain meaningful and pass after justified fixture updates.

The current server test command from repository root is:

```sh
computer/.venv/bin/python -m pytest -q computer/tests
```

Run it only after ensuring all data access is isolated. `scripts/test-all.sh` also invokes iPad package validation; this server-only task need not alter the iPad package. Report exact commands and observed results. Never describe mocked persistence tests as crash/durability validation.

Benchmark a synthetic or safely copied notebook around 2,400 strokes / 28.5 MB, and a larger one. Measure ordinary single strokes, a rapid burst, and grouped erasing. Report commits, operations per commit, changed payload bytes, WAL/checkpoint IO where measurable, ACK p50/p95, event-loop delay, and peak queue depth. Distinguish logical payload bytes, WAL growth, and OS-observed writes; none alone establishes physical SSD wear. Run storage comparisons with debug logging disabled, then verify diagnostics separately.

Acceptance is evidence that normal edit IO scales with changed content instead of whole-notebook size, bursts share durable commits, and the approximately one-second server stall is removed on the measured workload. Do not promise a fixed latency before measuring or require device stress testing to complete automated validation.

## Final report expected from GPT-Sol

- Files changed and the implemented transaction/batching design.
- Migration and backup behavior, including recovery and downgrade instructions.
- Tests executed with results and benchmark measurements.
- Remaining limitations, especially separate PDF asset handling and the existing iPad offline-journal bug.
- Any acceptance criterion not met, with a concrete blocker rather than a completion claim.

The user is currently pausing device stress tests. Complete server-side verification and leave any later device acceptance test as a clearly identified follow-up.
