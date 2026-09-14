# Unified debug logging

Start the computer service with the normal launcher and one additional flag:

```bash
./scripts/run-computer.sh --debug
```

The wrapper forwards `--debug` through `computer/run-native.sh` and
`computer/run.sh` to `computer/server.py`. Debug logging is off by default.

## Session correlation

Each debug server process generates a 32-character hexadecimal session ID, for
example `f8fa9a1b3c2d4e5f8a6b7d9e0f1a2b3c`. The server includes `debugEnabled` and
`sessionId` only in the initial `state_refresh` sent to a native iPad client.
Both devices then put that ID on their diagnostic records. A transport reconnect
to the same process keeps the ID; restarting the server creates a new one.

These fields are optional protocol metadata. They do not change notebook state,
state tokens, operation acknowledgements, or reconciliation behavior.

## Server output

Debug mode writes the same bounded event metadata to:

- the server terminal, with category colors when the output is a TTY;
- `computer/logs/infinite-notes-debug-<UTC>-<session>.log`;
- `computer/logs/infinite-notes-debug-<UTC>-<session>.jsonl`.

Each file rotates at 5 MiB and retains two backups. The event queue is bounded;
when producers outpace the writer, diagnostics are dropped instead of delaying
WebSocket or persistence work.

Recorded categories currently include lifecycle, connection, protocol,
persistence, sync, reconciliation, acknowledgement, conflict, and page-operation
events. Protocol records contain metadata such as direction, message type, byte
count, IDs, and collection counts. They do not contain complete messages.

Example JSONL record:

```json
{"timestamp":"2026-09-14T18:10:00.123+00:00","sessionId":"f8fa9a1b3c2d4e5f8a6b7d9e0f1a2b3c","eventSequence":12,"category":"protocol","event":"message","direction":"rx","byteCount":2314,"messageType":"stroke_points","strokeId":"abc123","pointCount":18}
```

## iPad output

After receiving an enabled initial debug handshake, the native app writes
metadata to unified logging and to a rotating JSONL file inside its container:

```text
Library/Logs/InfiniteNotes/session-<session-id>.jsonl
Library/Logs/InfiniteNotes/session-<session-id>.jsonl.1
```

The active file rotates at 2 MiB and retains one backup. The in-memory queue is
also bounded. Repeated reconnect handshakes for the same server session preserve
the iPad event sequence.

To retrieve the file from a physical iPad, use Xcode's Devices and Simulators
window to download the Infinite Notes app container, then inspect
`AppData/Library/Logs/InfiniteNotes`. Simulator containers can be inspected from
the simulator's app data container.

## Privacy and failure behavior

Neither logger records raw Pencil coordinates, complete strokes, document
snapshots, note text, PDF data, or project archives. Container-valued diagnostic
fields are rejected rather than recursively serialized. Identifiers and other
strings are length-limited.

Terminal and file I/O run on background writers. Logger failures and full queues
may lose diagnostics, but must not change application behavior. Starting without
`--debug` creates no debug session or log directory.
