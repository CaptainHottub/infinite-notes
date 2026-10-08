# Coordinated page layout

Page insert, append, and delete commit one layout transaction. The server sends
the same `page_layout` event through WebSocket and the HTTP response. It contains
the old/new page layouts, one-time ID mapping, document revision/token, and focus
page, but **no stroke points**. Updated clients apply it once. An unfamiliar base
layout recovers through an authoritative snapshot instead of guessing.
Updated clients advertise `pageLayoutVersion=1`. Older installed clients receive
a compatible snapshot/refresh instead of an event they cannot understand.

## Stable ownership and storage

Each page has a permanent UUID, independent of its page number. Strokes belong
to `pageId`; `pageIndex` and world coordinates are derived compatibility views.
The SQLite stroke row uses `coordinateSpace: "page-local"`, with `x`/`y` and raw
coordinates relative to that page. Page order/offsets live in notebook metadata.
Inserting/reordering pages leaves existing stroke rows unchanged. Deletion
removes only the deleted page's strokes. World views remain available to the
existing browser, renderer, eraser, export, and older project-format readers.

The iPad's authoritative ink store also uses fixed page-local points. World
coordinates are projected only for rendering, editing, and wire compatibility;
only mounted pages retain cached world views. Streaming converts new samples
without re-converting the stored prefix. Layout application rebinds ownership
and page membership metadata, preserving existing workspace extents without
walking ink points. Eraser geometry is rebuilt lazily for the page being erased.
Resizing an existing page requires recomputing that page's workspace bounds.
The `layout_applied` log includes localized/projected point counts (normally
both zero). It does not download ink again during a normal page operation.

## Existing notebooks

The first page operation migrates existing ink to stable page ownership and
local-coordinate rows. It may therefore take longer than later operations.
The previous SQLite metadata/ink rows are retained in `page_identity_backup`,
keyed by document ID, in the same transaction; legacy `state.json` is untouched.
The `pageIdentityVersion` marker is committed only with the conversion. A failed
commit rolls back the conversion, and the existing PDF asset transition restores
the matching asset generation. The retained backup is not automatically deleted.

`legacyPageIds` retains the initial mapping for offline clients with old page IDs.
Local-coordinate strokes can be reconciled against their page's new position;
strokes referring to a deleted page are rejected rather than moved elsewhere.
Project export/import preserves stable page IDs and ownership.

## Reusable PDF page backgrounds

Only a new page needs SVG/vector-PDF generation; unchanged pages keep their
cached assets and URLs. Each one-page PDF has `pdfUrl`, `pdfSha256`, and `pdfBytes`
in its page metadata. The iPad checks its independent page-file cache and
downloads only missing hashes, verifying byte count, SHA-256, PDF header, and
single-page parsing before showing the new layout. Inserting a distinct page
downloads one page; deleting pages downloads none. Duplicate backgrounds may
share one hash. Pages retain their crop boxes, rotation, text, and vector paths.
Only mounted pages retain Core Graphics document references. The iPad does not
serialize a combined PDF locally; removed cached backgrounds are pruned after
a successful page sync. Partial failed downloads cannot enter the cache.

Older notebooks obtain a small `/api/pdf/pages?documentId=...` manifest lazily,
without modifying their ink or document revision. Older servers fall back to
`/api/pdf/source`. The combined server source PDF is still rebuilt/recoverably
staged for export and compatibility; this change reduces iPad transfers and
local writes, not that server-side rebuild. PDF page assets participate in the
same recoverable asset transition as SVGs and the source PDF.

The `pdf_pages_completed` iPad log reports downloaded/reused page counts and
downloaded bytes. Sync progress counts ready pages (cached or downloaded) and
actual transfer bytes. The first load downloads all uncached page backgrounds.
The iPad blocks writing during a page update until backgrounds are ready.

## Page undo/redo

Page additions and deletions share the ordered server history with ink edits.
An entry retains only the affected one-page vector PDF, SVG, deleted page-local
ink, and before/after layout metadata, not a copy of the full notebook. Undoing
deletion restores the page's stable ID, exact background asset identities, ink,
and workspace extents. Undoing addition removes that page; subsequent ink edits
must be undone first. Redo restores operations in their original order. A new
edit or page operation clears the redo branch, as normal undo/redo does.

Ink history stores stable page-local records rather than moving all historical
points after a page operation. Older ink history touching a deleted page remains
available after the deletion is undone, including both halves of cross-page moves.
One recoverable PDF/SQLite layout transaction commits each page undo/redo; only
the restored/deleted page's ink rows are inserted/deleted. Clients receive a
compact layout event followed by bounded restored-ink batches when needed.
Native restored-ink batches refresh workspace bounds/rendering once per batch.
Active Pencil/erase operations must finish before undoing a page operation.

History remains session-local, like existing ink history: server restart or
opening/importing another notebook clears it. It retains at most 250 actions;
page-entry payloads have a 128 MiB aggregate retention budget, dropping oldest
actions while retaining at least the latest operation. Persistence failure
restores durable state/assets and clears potentially dependent history, as in
the existing storage failure path.

## Validation

Run `./scripts/test-all.sh` and `cd ipad && xtool dev build`. The tests cover
unchanged persisted stroke bytes after page moves, targeted deletion, migration
backup retention, restart projection, export/import, off-page ink, browser/native
layout mapping, existing ink history, cached SVG/PDF reuse, exact vector-page
rendering equivalence, cache integrity/restart/pruning, and a 2,400-stroke notebook.
Physical iPad frame rate and network transfer time still require device testing.
