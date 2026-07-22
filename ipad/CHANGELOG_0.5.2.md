# 0.5.2

## Fixed

- Large notebooks no longer arrive as a single native WebSocket message.
- Initial load, manual synchronization, and `.inotes` imports now refresh state over compressed HTTP.
- The native client no longer enters a rapid reconnect loop after a `Message too long` failure.
- Added a defensive WebSocket receive limit for compatibility with older servers.

Both the computer server and iPad client should be updated together for this fix.
