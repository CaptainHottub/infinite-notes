# Known issues — iPad experimental branch

## Lecture report and requested work — 2026-09-17

- A 90-minute lecture had zero observed desync, undo, or queued-stroke problems.
  Preserve this successful longer-session report alongside the earlier short test.
- Dense-page erasing can drop to 0 FPS. The user suspects eraser/stroke hit testing.
  Record for later profiling; do not optimize it in the current feature work.
- Offline erasing is still broken on device: with iPad Wi-Fi off, the first hit
  erases one stroke, sometimes resets the viewport, then further erasing stops.
  Explicitly disconnecting also prevents erasing. Reconnection does not reliably
  upload the local erase; Undo/Redo or Sync repairs the resulting discrepancy.
  Conversely, desktop deletions made while iPad Wi-Fi is off appear correctly on
  the iPad after reconnect. Do not mark the offline erase fix accepted.
- User hypothesis: the first failed send changes connection state and blocks
  further erasing. Proposed direction for discussion: persist every modification,
  then exchange buffered edits and server changes in a reconnect handshake.
  Neither the diagnosis nor a replacement protocol is established yet.
- Current scope: configurable eraser cursor colours on/off the PDF, eraser
  diameters below 8 pt, and exports beside the imported PDF/project.
- Explicitly defer offline-erase repairs and dense-page eraser performance work.
  After these features, discuss offline erasing first, then clarify workspace
  and whiteboard requirements before implementing them.
- Deferred workspace idea: always-visible outer workspace spanning roughly 2–3
  page widths; subtle vertical separators; pan until it fills half the viewport;
  configurable border colour/width appears only when it contains ink.
- Deferred canvas idea: detailed appearance settings; either a configurable export
  page outline that expands to include outside ink, or a limitless canvas exported
  as one large PDF page/vector item bounded by content. Requirements remain open.

## User test notes — 2026-09-17 (preliminary)

These observations come from a short initial device test, not extensive testing.
Retain them when planning further work; do not treat older performance reports
below as confirmed current behavior or these observations as release acceptance.

- Offline erasing: the new fix still needs the user's device test.
- Replay conflicts: the user suspects the SQLite backend has fixed them. This
  remains a hypothesis to verify with targeted replay/conflict tests; durable
  storage alone does not establish duplicate-operation or conflict handling.
- Undo: feels very responsive now, but has not been extensively tested.
- Sync: feels good in the initial test.
- Page operations: have not been tested in this initial device test.
- Immediate direction: add the user's requested features while retaining these
  observations and outstanding validation tasks. See the newer scoped list above.

## Pre-Okular stability gate

The user initially reported that the checks tried worked except for offline
erasing; the notes above clarify the limited test coverage.
Offline erasing has a durable replay queue, but the newer device report above
shows it still fails. Keep the failure open; repair is explicitly deferred.

Automated reconnect/crash coverage and the remaining device acceptance steps
are recorded in [sync chaos testing](docs/sync-chaos-testing.md). Passing those
automated checks does not close the viewport or campus Wi-Fi issues below.
The completed-stroke journal also still has a replay conflict: an unacknowledged
stroke can reappear if another client deleted it before reconciliation. See
[sync revisions](docs/sync-revisions.md#completed-stroke-recovery-journal).
Keep Okular integration blocked until these stability requirements are met.

## Historical report: sync is slow

- Earlier report: full/manual synchronization was slow. The latest short test
  feels good; broader validation is still pending.
- Do not optimize it in this patch; handle it later when this work is brought to `develop`.
- Pressing Sync repeatedly can queue overlapping state transfers. Avoid pressing it again until the current request has completed because older responses have previously overwritten newer progress.

## Historical report: undo is slow

- Earlier report: undo and redo could take noticeable time on larger notebooks.
  The latest short test finds undo very responsive; extensive testing is pending.
- Leave the history/performance overhaul for later work on `develop`.

## Historical report: adding a page is slow

- Earlier report: adding a page below the current page or at the end was slow.
  Page operations have not been tested in the latest initial device test.
- It currently rebuilds computer-side PDF/page assets and rebroadcasts document state.
- Defer this until the computer-side viewer and PDF pipeline are rebuilt.

## Networking note

- A dedicated hotspot is not always required.
- Infinite Notes was confirmed to work on the university Wi-Fi when the iPad and laptop could reach the laptop server directly.
- Keep the hotspot option for networks that isolate clients or block local peer traffic.

## Fixed in this patch

### Geometry eraser false positives

The eraser now follows the rendered geometry path. It no longer treats the selection/bounding rectangle of a diagonal line as erasable ink.

### Reconnect rollback of Pencil progress

Native Pencil strokes can continue while disconnected and remain in a local pending-commit collection until the server acknowledges them. After reconnection, pending strokes are reconciled with the server before the initial state refresh is applied, preventing a stale server snapshot from rolling the iPad back to the moment the connection was lost.

## Previously applied viewport fix

The off-page workspace relayout now resets the zoom view before changing the document frame/content size, suppresses callbacks during the transient layout, and restores the PDF-relative viewport anchor afterward. This still needs continued on-device observation.


## Campus Wi-Fi reconnect loop — fix under test

- On the university Wi-Fi, the native iPad WebSocket could periodically drop and reconnect.
- Every native reconnect previously triggered a full `/api/state` and source-PDF refresh, even when notebook state had not changed.
- A dropped socket could also close between committing a stroke and `stroke_ack`, causing the server to log `Unexpected ASGI message 'websocket.send', after sending 'websocket.close'`.
- The current fix adds WebSocket heartbeats, safe acknowledgements, reconnect state tokens, and server point-count verification before the iPad discards locally pending ink.
- Continue testing this on the university Wi-Fi before considering the networking issue closed.
