# Infinite Notes — Implementation Vector

## Purpose

This document defines the implementation direction for Infinite Notes going forward.

All substantial development work should move into **ChatGPT Work / Codex**, using:

- **Astra** as the primary planning, architecture, review, and approval agent.
- **Qwen** as a delegated implementation sub-agent for code changes, repetitive edits, testing, repository inspection, and web research where useful.
- The human developer as the final authority for approvals, merges, architecture changes, and device acceptance testing.

The immediate priority is **stability and data safety**, not adding more surface features.

---

# 1. Non-Negotiable Requirements

## 1.1 User work must never disappear

No user-created work may be lost because of:

- Wi-Fi loss.
- WebSocket disconnect.
- Reconnect.
- Manual sync.
- Automatic sync.
- Server restart.
- iPad sleep/wake.
- Page insertion/deletion/reordering.
- Undo/redo.
- Stale server state.
- Duplicate or out-of-order network messages.

A stale server snapshot must never overwrite newer local work.

When local and remote state differ, the system must reconcile operations before applying an authoritative replacement state.

## 1.2 Normal editing must remain local and responsive

Drawing, erasing, selecting, moving geometry, and panning/zooming should not depend on network round trips.

The iPad should continue operating while disconnected.

Network synchronization should happen around local editing without blocking the Pencil pipeline.

## 1.3 Avoid whole-document work for local edits

Ordinary editing operations should not require:

- Re-rendering every stroke on a page.
- Rebuilding the entire document.
- Sending the entire notebook state.
- Re-downloading the entire PDF.
- Re-indexing every page unless the document structure actually changed.

Prefer local, incremental operations.

---

# 2. Current Architecture Direction

```text
                         Infinite Notes Server
                       /          |          \
                      /           |           \
                   iPad        Okular       CLI/Admin
                 Native App    Integration    Tools
```

## iPad

The iPad remains the primary handwriting and annotation device.

Responsibilities:

- Apple Pencil input.
- Vector ink rendering.
- Geometry.
- Erasing.
- Selection and transformations.
- Off-PDF workspace.
- Local offline operation journal.
- Reconciliation with server.
- Page navigation.
- Diagnostic tools.

The iPad should not require a constant server connection to continue editing.

## Server

The server should become a **headless document and synchronization authority**.

Responsibilities:

- Document state.
- Operation history.
- Revision tracking.
- WebSocket synchronization.
- Offline-operation reconciliation.
- PDF import/export.
- Infinite Notes project import/export.
- Page structure operations.
- Persistent storage.
- Debug/session logging.

The server should not depend on a specific GUI implementation.

## Okular Integration

Once the server and iPad synchronization layer are stable, the existing browser viewer should be deprecated in favor of Okular integration.

Initial desired desktop controls:

- View PDF.
- View Infinite Notes ink.
- Erase ink.
- Move ink.
- Type text.
- Undo/redo.

Additional desktop features can be added later.

The Okular work should consume the same server protocol and document model as the iPad rather than introducing a parallel notebook format.

## Browser GUI

The browser GUI is temporary.

Its current useful responsibilities are primarily:

- Import PDF.
- Export flattened PDF.
- Export Infinite Notes project.
- Import Infinite Notes project.

The browser drawing/viewing architecture should **not** constrain future server architecture.

Do not spend significant development effort polishing or optimizing the browser canvas unless needed for data compatibility or transition work.

Eventually, the browser GUI can be removed or reduced to a minimal administration page.

---

# 3. Development Workflow: Astra + Qwen

## 3.1 Astra responsibilities

Astra owns:

- Understanding the requested change.
- Inspecting relevant repository architecture.
- Producing the implementation plan.
- Defining data invariants.
- Deciding protocol changes.
- Defining acceptance criteria.
- Breaking large work into safe phases.
- Delegating implementation to Qwen.
- Reviewing Qwen's changes.
- Rejecting incomplete or unsafe implementations.
- Requesting corrections.
- Running or requesting final validation.
- Updating documentation and known issues.
- Deciding when a task is ready for human device testing.

Astra should avoid doing large amounts of implementation directly unless:

- A framework or critical architecture skeleton must be created.
- Qwen is repeatedly failing at a specific change.
- The change is small enough that delegation would add unnecessary complexity.

## 3.2 Qwen responsibilities

Qwen should be used for:

- Repository exploration.
- Reading full source files.
- Implementing defined changes.
- Refactoring.
- Adding tests.
- Running tests.
- Fixing compiler/test failures.
- Repetitive edits.
- Searching documentation or the web when required.
- Producing diffs.
- Returning implementation results to Astra.

Each Qwen task should return:

```text
Files changed:
Tests run:
Tests passed:
Tests failed:
Known limitations:
Questions / blockers:
```

Qwen must not claim code was changed or tests passed unless it actually performed those actions.

## 3.3 Iteration loop

```text
Human request
    ↓
Astra investigates
    ↓
Astra creates scoped implementation task
    ↓
Qwen implements
    ↓
Qwen returns changes + tests
    ↓
Astra reviews diff and architecture
    ↓
        ├── Reject → Qwen corrects
        └── Approve
              ↓
Astra runs/reviews final validation
              ↓
Human performs iPad / real-world test
```

Repeat until the acceptance criteria are satisfied.

---

# 4. Immediate Priority: Synchronization Stability

Synchronization is currently the largest architectural risk.

Observed problems include:

- Desync during long class sessions.
- Slow manual sync.
- Slow automatic sync.
- Repeated sync actions can backlog.
- Connection loss followed by reconnect has previously restored stale server state over newer iPad work.
- Reconnect loops have occurred.
- WebSocket acknowledgements have raced with closed connections.
- Full state/PDF refreshes are expensive.

The synchronization layer should move away from whole-state replacement as the normal mechanism.

---

# 5. Sync Redesign Direction

## 5.1 Prefer operation/revision synchronization

Do not rely primarily on wall-clock timestamps.

Use explicit monotonic identifiers such as:

```text
documentRevision
pageRevision
operationId
clientSequence
serverSequence
```

Potential state summary:

```json
{
  "documentRevision": 1524,
  "pages": {
    "0": {
      "revision": 310,
      "lastOperation": "op-..."
    },
    "1": {
      "revision": 488,
      "lastOperation": "op-..."
    }
  }
}
```

A reconnect should first determine **what changed**, not immediately download the full notebook.

## 5.2 Offline operation journal

The iPad should maintain a persistent journal of operations that are not yet confirmed by the server.

Examples:

```text
add_stroke
replace_stroke
delete_strokes
move_strokes
insert_page
delete_page
```

Each operation should have:

```text
operationId
clientId
clientSequence
documentId
pageId
baseRevision
payload
createdAt
```

The journal should survive:

- WebSocket loss.
- App backgrounding.
- App termination.
- iPad restart.

An operation is removed only after an explicit server acknowledgement confirms it has been durably stored.

## 5.3 Reconnect sequence

```text
WebSocket reconnect
      ↓
Exchange document/revision summary
      ↓
Are there unacknowledged local operations?
      ↓ yes
Replay/reconcile local operations in bounded batches
      ↓
Server acknowledges durable operations
      ↓
Compare revisions
      ↓
Request only missing remote operations
      ↓
Resume normal live synchronization
```

A full `/api/state` replacement should be an exceptional recovery mechanism, not the default reconnect path.

## 5.4 Duplicate-safe operations

Operations must be idempotent.

Receiving the same `operationId` twice should not:

- Duplicate a stroke.
- Delete twice.
- Create duplicate history entries.
- Shift pages twice.

The server should remember recently committed operation IDs.

## 5.5 Bounded network messages

No synchronization path should create an unbounded WebSocket frame.

Use limits based on:

- Serialized byte size.
- Operation count.
- Stroke count.
- Point count.

Large reconciliations should be split into acknowledged batches.

---

# 6. Debug Mode

Use one comprehensive debug mode rather than multiple debug levels.

Command-line interface:

```bash
./run-computer --debug
```

The same mode should enable all useful diagnostics needed to diagnose synchronization, rendering, page-layout, and protocol failures.

## 6.1 Output

Debug mode should:

- Print useful events to Konsole.
- Write the full session to a log file.
- Use readable event categories.
- Use terminal colors where appropriate.
- Include function/source context when practical.

Suggested log path:

```text
logs/infinite-notes-debug-YYYY-MM-DD_HHMMSS.log
```

Use log rotation or maximum file sizes.

## 6.2 Shared session ID

Every debug run should generate a session ID.

Example:

```text
session=20260910-134218-a83f
```

The server should provide this ID to connected clients.

iPad and server logs should include the same session identifier so a failure can be traced across both devices.

## 6.3 Events to record

### WebSocket

Record:

- Connect.
- Disconnect.
- Close code.
- Close reason.
- Ping.
- Pong.
- Reconnect attempt.
- Client ID.
- Client role.
- Session ID.
- Message type.
- Payload byte size.
- Operation ID.
- Stroke ID.
- Page ID/index.
- Relevant revision numbers.

Do not normally dump every Pencil point into the text log.

For high-frequency point messages, log summaries:

```text
RX stroke_points
stroke=abc123
page=4
count=18
bytes=2314
clientSequence=9012
```

### Sync

Record:

- Reconciliation start/end.
- Pending operation count.
- Batch number.
- Batch byte size.
- Local revision.
- Remote revision.
- State replacement.
- State-token/revision comparison.
- ACK timing.
- Duplicate-operation detection.
- Conflict detection.
- Manual sync requested.
- Automatic sync requested.
- Sync duration.

### Persistence

Record:

- State save start/end.
- Save duration.
- Bytes written.
- History operation.
- Current document revision.

This is important for diagnosing slow sync and undo.

### Rendering/performance

Record periodically:

- iPad FPS.
- Mounted page count.
- Vector layer/stroke count.
- Memory where available.
- Current page.
- Zoom.
- Workspace dimensions.
- Long frame events.

Avoid logging every render callback.

### Page operations

Record:

- Insert.
- Append.
- Delete.
- Restore.
- Reorder.
- Undo.
- Redo.
- Page revision changes.

## 6.4 Optional protocol recorder

Debug mode should optionally write a machine-readable JSONL event stream.

Example:

```json
{"t":1789062138.22,"event":"ws_rx","type":"stroke_end","strokeId":"abc","page":4}
{"t":1789062138.24,"event":"state_revision","from":928,"to":929}
{"t":1789062138.25,"event":"ws_tx","type":"stroke_ack","strokeId":"abc"}
```

This will allow Astra to inspect exact protocol sequences after a failed class session.

---

# 7. Performance Direction

## 7.1 Vector ink

The iPad should continue using vector-backed committed ink.

Do not return to a single full-page ink bitmap.

Desired behavior:

```text
Stroke
  ↓
Vector path
  ↓
Retained vector rendering
```

Erasing one stroke should remove or invalidate only the affected vector content.

## 7.2 Spatial indexing

As notebooks grow, introduce a per-page spatial index for strokes.

Use it for:

- Eraser hit testing.
- Selection.
- Rendering.
- Export bounds.
- Workspace expansion.
- Geometry snapping.

Avoid scanning every stroke on a page for every Pencil movement.

Possible structures:

- R-tree.
- Quadtree.
- Uniform spatial grid.

A simple uniform grid may be sufficient initially.

## 7.3 Performance targets

Suggested targets:

```text
Normal handwriting:       60 FPS minimum target
Pencil latency:           visually immediate
Eraser:                   never full-page redraw
Typical erasing:          >= 30 FPS
Reconnect unchanged doc:  no full PDF reload
Normal edit:              no whole-notebook operation
```

Use the diagnostics FPS display and debug logs to measure regressions.

---

# 8. PDF Rendering

Current known issue:

- Changing zoom can cause the PDF to flash.

Target behavior:

- Existing rendered tile remains visible until its higher-resolution replacement is ready.
- Panning and zooming should never temporarily reveal a blank page if valid lower-resolution content already exists.
- PDF rendering remains vector/tiled.
- Ink remains independent from the source PDF renderer.

Do not flatten the PDF and ink merely to hide flashing.

---

# 9. Off-PDF Workspace

The expanded workspace should become a first-class part of the page model rather than a rendering exception.

Each page conceptually contains:

```text
workspace
 ├── source PDF rectangle
 ├── left extension
 └── right extension
```

The workspace can grow horizontally in bounded increments as needed.

Future customization should include:

- Background color.
- Grid color.
- Grid spacing.
- Grid vs dot matrix.
- System-aware appearance.

Workspace expansion must not break:

- Viewport bounds.
- Current zoom.
- Current page.
- Selection coordinates.
- Ink coordinates.
- Export coordinates.

---

# 10. Page Operations

Desired page functionality:

- Append page.
- Insert below current.
- Delete page.
- Undo page deletion.
- Redo page deletion.
- Eventually reorder pages.

Adding or deleting pages should **not wipe unrelated history**.

Page identity should eventually be separated from array index.

Prefer:

```text
pageId = persistent UUID
pageIndex = current presentation order
```

This avoids having annotation ownership depend entirely on indices that shift after insertion/deletion.

---

# 11. Computer-Side Transition to Okular

Do not begin the Okular overhaul until:

- iPad drawing is stable.
- Offline reconciliation is reliable.
- Long-session desync is under control.
- Server document operations are stable.
- Protocol logging exists.

Then begin the Okular integration as a separate major phase.

## 11.1 Phase A — Read-only Okular integration

Goal:

- Open the source PDF.
- Fetch/display Infinite Notes annotations.
- Track current document/page.
- Keep annotation coordinates aligned.

No editing initially.

## 11.2 Phase B — Basic desktop editing

Add:

- Erase.
- Move/select.
- Text.
- Undo.
- Redo.

All operations should go through the same operation protocol used by the iPad.

## 11.3 Phase C — Page/document operations

Add as appropriate:

- Insert page.
- Delete page.
- Restore page.
- Export.

## 11.4 Browser retirement

Once Okular and CLI/admin workflows replace the remaining browser use cases:

- Mark browser drawing/viewer code deprecated.
- Remove unused browser editing code.
- Keep only a minimal admin page if it remains useful.
- Eventually remove the browser frontend entirely if CLI/desktop controls cover everything.

---

# 12. CLI / Admin Direction

Long-term, document operations should also be available without the browser.

Possible commands:

```bash
infinite-notes import lecture.pdf
infinite-notes export-pdf lecture-output.pdf
infinite-notes export-project lecture.inotes
infinite-notes import-project lecture.inotes
infinite-notes status
infinite-notes debug-log
```

This will allow the browser GUI to be retired cleanly.

---

# 13. Testing Strategy

## 13.1 Standard 90-minute soak test

Create a repeatable test approximating a real lecture.

During the test:

- Write continuously.
- Erase frequently.
- Draw geometry.
- Select/move objects.
- Pan.
- Zoom.
- Switch pages.
- Write off the side of PDFs.
- Trigger workspace expansion.
- Let iPad sleep and wake.
- Disconnect Wi-Fi briefly.
- Restart the server once.
- Reconnect.

Measure:

- FPS.
- Memory.
- Number of strokes.
- Pending operations.
- Sync duration.
- Reconnect count.
- WebSocket failures.
- State-save duration.

At the end:

- No missing work.
- No duplicate work.
- No stale-state rollback.
- No broken viewport.
- No permanent reconnect loop.

## 13.2 Network chaos tests

Automate or manually test:

- 5-second disconnect.
- 30-second disconnect.
- Multi-minute disconnect.
- Server unavailable.
- Server restart.
- Duplicate messages.
- Out-of-order ACKs.
- Lost ACK.
- Duplicate ACK.
- Very large pending operation set.
- iPad app background/foreground.
- Socket closes immediately after `stroke_end`.

## 13.3 Large notebook test

Maintain a dedicated stress notebook containing:

- Many pages.
- Thousands of strokes.
- Long Pencil strokes.
- Geometry.
- Off-PDF ink.
- Several workspace expansions.

Use this notebook for performance and reconnect regression testing.

A small clean PDF is not sufficient to validate long-session behavior.

---

# 14. Known Issues to Preserve in the Backlog

Current known issues include:

- Desync can still occur in long sessions.
- Manual sync is slow.
- Automatic sync is slow.
- Undo/redo is slow.
- Page insertion/addition is slow.
- PDF can flash while zooming.
- Additional performance work may be needed as vector-layer count increases.
- Browser viewer is temporary and will be deprecated.
- Campus Wi-Fi can work directly without using the laptop hotspot when peer communication is allowed.

Do not casually mix fixes for these issues into unrelated feature work.

Each should become a scoped task with its own tests.

---

# 15. Feature Backlog

## Pages

- Delete pages.
- Undo page deletion.
- Preserve history when pages are added or removed.
- Reorder pages.

## Workspace appearance

- Background color.
- Grid color.
- Grid spacing.
- Grid/dot-matrix mode.

## Drawing controls

- Eraser cursor color.
- Smaller minimum eraser size.
- Continue fine-grained pen-width controls.

## Diagnostics

- `--debug`.
- Unified server/WebSocket/session logging.
- JSONL protocol recorder.
- Shared session ID.
- Performance statistics.

---

# 16. Definition of Done

A feature is not complete merely because the code compiles.

Before Astra marks a task ready for human approval:

1. Required source changes are implemented.
2. Existing computer tests pass.
3. New regression tests are included.
4. Swift source parses/builds in the available environment.
5. Protocol compatibility is reviewed.
6. No stale-state/data-loss path is introduced.
7. Performance-sensitive code is checked for whole-page/whole-document work.
8. Relevant documentation is updated.
9. Known issues are updated.
10. A manual iPad acceptance checklist is provided.

For synchronization or persistence changes, the task also requires:

11. Disconnect/reconnect testing.
12. Duplicate-operation testing.
13. Lost-ACK testing.
14. Server restart testing.
15. Verification that newer local work cannot be overwritten by older remote state.

---

# 17. Recommended Implementation Order

```text
1. Stabilize current iPad + server
        ↓
2. Unified --debug + protocol/session logging
        ↓
3. Operation/revision-based synchronization
        ↓
4. Persistent iPad offline operation journal
        ↓
5. Long-session + network-chaos test harness
        ↓
6. Fix remaining rendering/performance problems
        ↓
7. Complete page identity/history model
        ↓
8. Freeze/deprecate browser editing viewer
        ↓
9. Build read-only Okular integration
        ↓
10. Add Okular editing controls
        ↓
11. Add CLI/admin import/export
        ↓
12. Retire browser viewer
```

The guiding principle is:

> **Make Infinite Notes impossible to lose work in first. Make it fast second. Expand the desktop experience third.**
