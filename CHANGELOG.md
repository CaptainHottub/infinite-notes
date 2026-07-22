# Changelog

## 0.5.3 — Interaction and synchronization reliability

- Removed the visible gap when a completed vector stroke is committed to the page cache.
- Disabled accidental document scroll-to-top from taps in the top interface area.
- Tool switching no longer forces Pen and Highlighter back to hard-coded widths.
- Apple Pencil drawing tools no longer select or move existing geometry.
- Added direct one-finger selection and manipulation for unlocked geometry.
- Added a stronger, zoom-independent eraser perimeter.
- Large native WebSocket updates now fall back to compressed HTTP state refreshes.
- Project imports return a small acknowledgement and retrieve restored state separately.
- Mounted-page status is sorted numerically and bolds the current page.
- Selection handles, endpoint controls, lasso sampling, and hit distances remain constant on screen while zooming.

## 0.5.2 — Large notebook synchronization fix

- Native clients no longer receive the complete notebook as one WebSocket frame.
- Initial connection, manual sync, and `.inotes` import now trigger a compressed HTTP state download.
- Added a defensive 64 MB WebSocket receive limit for compatibility with older computer servers.
- Prevented large projects from causing a “Message too long” reconnect loop.
- Added regression tests for large notebooks and native import notifications.

## 0.5.1 — Git baseline

- Fixed geometry timestamps rejected as `Invalid point field: t`.
- Merged pressure and fixed-width Pen into one tool with a pressure toggle.
- Added editable colour, pen-width and eraser-width presets.
- Added solid, dashed and dotted styles for ink and geometry.
- Added selection restyling and a visible eraser diameter cursor.

## 0.5.0

- Ported geometry, lasso, locking, snapping and X–Y planes to the native client.
- Added hold-to-recognize lines and quadratic curves.
- Added move, scale, rotation and geometry control-point editing.
- Consolidated settings under a tabbed three-dot menu.
- Retained vector PDF rendering and zoom-independent live Pencil rendering.
