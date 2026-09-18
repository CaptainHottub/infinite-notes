# Reconnect and crash testing

The automated harness starts actual server subprocesses on temporary loopback
ports. It generates its own notebook and never opens `computer/data`, connects
to the running notebook server, or installs anything on the iPad.

Run the short regression case with the normal suite:

```sh
./scripts/test-all.sh
```

Run a larger generated notebook and repeated interruption cycles:

```sh
computer/.venv/bin/python computer/tools/sync_chaos.py
# Longer run, with a different reproducible operation sequence:
computer/.venv/bin/python computer/tools/sync_chaos.py --seed 23 --cycles 30
```

The default starts with 2,400 strokes of 192 points each and runs twelve cycles.
`--initial-strokes`, `--points`, `--cycles`, and `--seed` control its size and
operation sequence. Each cycle streams 64 strokes in point batches, replays
twelve completed strokes twice, disconnects during a stroke, and checks erase,
undo, and redo. A second client independently reconstructs the live notebook
from WebSocket updates and is compared with the expected content. The harness
also reconstructs the same content from the paginated revision endpoint.

For lost-ACK coverage, the harness receives but deliberately ignores an ACK at
the application boundary, retaining the stroke payload for reconnect replay.
It kills the real server after stroke acceptance without waiting for an ACK,
restarts against the same temporary database, and replays the pending stroke.
A final kill/restart verifies acknowledged content and the durable revision.
Runs exceeding retained revision history also exercise full-snapshot fallback.
The legacy JSON migration source must remain byte-for-byte unchanged throughout.

On success, stdout reports JSON with cycle, replay, observer, delta, restart,
and fallback counts, final stroke count, revision, and elapsed seconds. Any
content mismatch or protocol error fails the run. Socket and process waits
have timeouts; the subprocesses and generated files are cleaned up afterward.

The initial default run passed with seed 17: 22,268,923 bytes of legacy JSON,
2,400 initial strokes, 3,324 final strokes, revision 840, twelve live-observer
checks, twelve delta checks, twelve lost-ACK replays, thirteen restarts, and one
history-retention fallback. It took 112.66 seconds on the development machine.

This exercises the server and simulated native-protocol clients. It does not
measure Pencil rendering, execute the iPad UI, or simulate packet-level Wi-Fi
loss. It does not yet resolve the documented conflict where a pending stroke is
replayed after another client deleted it; persistent operation identities remain
separate work. Duration is reported as measured, not as equivalent classroom time.

## Pre-Okular validation checkpoint (2026-09-17)

`timeout 240 ./scripts/test-all.sh` passed with 155 Python tests, iPad package
validation, and the PendingStrokeJournal, RevisionDeltaAccumulator, and
LiveStrokeTracker Swift test programs. Python reported one upstream Starlette
TestClient deprecation warning. The suite required execution outside the
socket-restricted sandbox; the sandboxed attempt stalled and was stopped.
Package validation parses Swift sources; it is not an iPad SDK build or a
device rendering test.

The longer run, `computer/.venv/bin/python computer/tools/sync_chaos.py --seed 23
--cycles 30`, also passed: 2,400 initial strokes, 4,710 final strokes, revision
2,100, thirty delta checks, thirty live-observer checks, thirty lost-ACK replays,
31 server restarts, and one history-retention fallback. The 22,268,793-byte
legacy migration file remained unchanged. Elapsed time was 325.98 seconds;
the run used generated temporary notebook data.

## Device acceptance gate

Use matching server and iPad builds and a disposable notebook for these checks:

1. Draw ordinary Pencil strokes and geometry. Pan and zoom across page edges;
   confirm ink stays aligned and the viewport does not jump.
2. Disconnect Wi-Fi, finish several strokes, then reconnect. Confirm every
   completed stroke remains on both the iPad and computer, without duplicates
   or rollback. Repeat on campus Wi-Fi when available.
3. While disconnected, finish a stroke and then close/relaunch the app.
   Reconnect to the same notebook and confirm the completed stroke recovers.
   This checks completed-stroke recovery, not offline notebook loading.
4. Once synchronized, erase, undo, and redo. Confirm both views agree. Add a
   page and confirm existing ink remains correctly positioned after reconnect.
5. Restart the server after synchronization and reconnect. Confirm the notebook
   is unchanged and drawing can continue.

Record the step and any visible error if a check fails; retain debug logs from
both devices. These are focused acceptance checks, not a request for another
large manual stress test. Okular remains gated on device results and resolution
of the replay-after-deletion conflict above; passing automated tests alone does
not establish a stable release.
