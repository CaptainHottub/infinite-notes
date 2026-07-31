# Geometry eraser and reconnect recovery

This patch targets the latest experimental iPad branch containing:

- off-page workspaces;
- viewport relayout fix;
- retained vector ink;
- diagnostics side panel and FPS display.

## Fix 1: geometry eraser

`GeometryEngine.eraserHitTest` performs distance-to-rendered-path testing. Selection bounds remain available for selection/move UI, but are no longer used by the eraser.

## Fix 2: connection-loss recovery

The native client now allows Pencil strokes to continue while disconnected, sends the complete final vector stroke in every `stroke_end` message, and retains it until `stroke_ack`.

If the connection drops before acknowledgement:

1. the local completed stroke remains visible;
2. reconnect begins with `reconcile_strokes`;
3. the server idempotently inserts or finalizes those strokes;
4. the server returns `reconcile_ack`;
5. only then does the iPad fetch and apply the full state.

The server accepts repeated reconciliation safely, so an acknowledgement being lost does not duplicate a stroke.

## Out of scope

This patch intentionally does not optimize:

- sync;
- undo/redo;
- add-page performance;
- the computer viewer.
