# Eraser performance — 2026-09-18

The dense-page performance pass is ready for device testing. It does not close
the reported 0 FPS issue until the original notebook is tested on the iPad.
The offline erase failure remains open and outside this patch.

## Changes

- Cache stroke hit geometry in a 128-point spatial grid. Bounds only select
  candidates; squared-distance path tests decide hits. Locked strokes are excluded.
  Shape paths retain the existing 96-segment approximation; text retains filled
  box hit testing. Oversized strokes/queries fall back to bounded index storage
  and broader searches instead of allocating arbitrarily large grids.
- Maintain the cache for insertion, replacement, point updates, deletion and full
  state rebuilds. Live geometry is refreshed lazily before the next erase query.
- Batch coalesced Pencil samples and test the swept path between samples, including
  consecutive touch events, so fast movement does not skip intervening ink.
- Save each hit batch before removing its ink, retaining the existing journal and
  replay ordering. There is no asynchronous durability change.
- Remove affected retained drawing layers directly; avoid sorting/rechecking all
  committed strokes for each deletion. Cursor refresh sorts only live strokes.
- Recompute workspace shrink once when the final active erase gesture ends.
  Workspace growth from new ink remains immediate.
- Emit one `performance/erase_gesture` diagnostic when existing debug logging is
  enabled: samples, candidates, hits, query/journal/removal/workspace milliseconds
  and maximum batch duration. Journal timing covers hit-batch saves; it excludes
  the final gesture-completion save. Rendering on the next UI frame is not timed.

## Reproducible host benchmark

From the repository root:

```sh
swiftc -O \
  ipad/Sources/InfiniteNotesStrokeLab/EraserSpatialIndex.swift \
  ipad/Sources/InfiniteNotesStrokeLab/PendingEraseQueue.swift \
  ipad/Sources/InfiniteNotesStrokeLab/PendingStrokeJournal.swift \
  ipad/Tests/EraserBenchmark.swift -o /tmp/infinite-notes-eraser-benchmark
/tmp/infinite-notes-eraser-benchmark
```

Fedora x86_64, Swift 6.3.3; 300 deterministic queries over synthetic handwriting
paths, 192 points per stroke, an 8-point eraser, 600 × 800-point page. The reference
scans every segment using the previous nearest-distance calculation; both runs
use cached input points, so this does not include the old point-array allocation.
The benchmark asserts identical hit sets for every query.

| Strokes | Full scan p50 / p95 | Indexed p50 / p95 | Mean candidates | Index build |
| --- | --- | --- | --- | --- |
| 2,400 | 2.035 / 2.134 ms | 0.036 / 0.069 ms | 4.3 | 2.45 ms |
| 6,000 | 5.916 / 6.485 ms | 0.113 / 0.214 ms | 10.8 | 6.34 ms |

Synchronous journal writes for 100 batches of 16 IDs (1,600 total) measured
0.504 / 0.836 ms p50 / p95. Reload restored all IDs. These are host measurements,
not iPad frame times or storage guarantees. Highly overlapping strokes can still
produce many candidates; the index is not a constant-time guarantee. Cached
geometry adds memory proportional to stroke points. Full document/index rebuild
and the final workspace recomputation remain proportional to document/page size.

## Validation and remaining acceptance

`./scripts/test-all.sh` covers the computer suite, package validation, existing
native replay/journal checks and new executable spatial-index tests. The latter
compare randomized point queries against an independent distance reference and
indexed sweeps against exhaustive swept tests, plus crossings, parallel paths,
tangencies, negative coordinates, hollow shapes, text, page membership, replacement,
reinsertion after deletion and oversized fallbacks. `xtool dev build` in `ipad/`
checks the actual iOS target.

On the iPad, with the computer connected:

1. Erase slowly and quickly through the original dense lecture page. Check cursor
   responsiveness and that fast sweeps remove every crossed stroke.
2. Check a 1-point eraser, hollow shapes, text, locked objects, and ink near page
   boundaries; strokes merely inside a shape's bounding box must survive.
3. Undo and redo several erase gestures, then erase restored strokes. Check both
   clients and a manual sync for matching results.
4. Erase the last off-page ink. The workspace should stay steady during the gesture
   and shrink after lift without losing the PDF-relative viewport position.
5. Navigate away/back and reopen the notebook; confirm deleted ink stays deleted
   and remaining ink renders correctly.

If stalls remain, collect the gesture diagnostics to distinguish candidate tests,
journal I/O, removal, and final workspace work. Offline reconnection acceptance
is tracked separately in `KNOWN-ISSUES.md`; these checks do not certify it.
