# Synchronization revisions

The server persists a non-negative `documentRevision` beside the notebook state.
Legacy state files are migrated to revision `0` without changing document or
stroke content. Each successful atomic state save advances the revision once and
writes the new revision in the same atomic replacement as the notebook data.

The server exposes `documentRevision` as additive metadata in:

- `/api/state` responses;
- native `state_refresh` messages;
- native `stroke_ack`, `reconcile_ack`, and `delete_ack` messages.

Imported project archives are treated as document content, not as synchronization
authority. Their revision metadata is discarded, and importing advances the
server's existing revision instead of replacing or decreasing it.

This is a protocol foundation only. The iPad decodes and logs the revision but
continues using the existing `stateToken` and pending-stroke reconciliation
guards until operation replay and missing-operation fetch are implemented in
later scoped changes.
