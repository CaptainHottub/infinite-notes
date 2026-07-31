# Known issues — iPad experimental branch

## Sync is slow

- Full/manual synchronization is still slow.
- Do not optimize it in this patch; handle it later when this work is brought to `develop`.
- Pressing Sync repeatedly can queue overlapping state transfers. Avoid pressing it again until the current request has completed because older responses have previously overwritten newer progress.

## Undo is slow

- Undo and redo can still take a noticeable amount of time on larger notebooks.
- Leave the history/performance overhaul for later work on `develop`.

## Adding a page is slow

- Adding a page below the current page or at the end remains slow.
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
