# Large Notebook Synchronization

Version 0.5.2 changes how the native iPad app receives complete notebook state.

## Previous behavior

The computer server serialized the entire notebook into one WebSocket `snapshot` message. As the notebook grew, that message could exceed the native WebSocket receive limit. The iPad then reported `Message too long`, disconnected, and repeatedly reconnected.

The same full-state message was used for:

- Initial connection
- Manual synchronization
- Project import notifications

## Current behavior

WebSockets continue to carry small real-time operations such as new points, completed strokes, erasures, replacements, undo, and redo.

A complete notebook refresh now uses this flow:

1. The server sends a small `state_refresh` WebSocket notification.
2. The native app downloads `/api/state` over HTTP.
3. The server compresses large JSON responses with gzip.
4. The app decodes the state off the main thread and applies it on the main actor.
5. The original PDF is refreshed separately through `/api/pdf/source`.

Browser clients retain the original snapshot protocol for compatibility. Native clients are identified by their `native-` client ID prefix.
