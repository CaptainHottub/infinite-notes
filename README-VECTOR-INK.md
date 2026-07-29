# Retained vector ink patch

This patch is based on the latest off-page workspace + viewport-bounds project bundle.
It does not require the previous work to be committed to Git.

## What changed

### Native iPad renderer

- Removed the page-sized `UIImage` committed-ink cache.
- Finished ink is retained as `CAShapeLayer` paths.
- A normal ink stroke uses one vector path layer; sample points are path vertices, not separate layers.
- Erasing deletes only the affected stroke layers.
- Moving and transforming selected items hides their committed layers and draws the live replacement vectors.
- Text uses retained `CATextLayer` content instead of being baked into the page image.
- Shapes, X-Y plane grids, and labels remain separate retained vector layers.
- Core Animation raster caching is explicitly disabled for the ink layer hosts.
- The obsolete bitmap-cache sliders were replaced by a vector-rendering status section.

### Computer server

- PDF page previews are generated as SVG files instead of full-page PNG pixmaps.
- Existing PDF export already drew notes with PDF vector operations; regression coverage now verifies that exported ink is drawing content, not an embedded page bitmap.
- Browser HTML, CSS, and JavaScript are unchanged. The browser still composites the SVG into an HTML canvas for display.

## Sample-point performance

Normal rendering does **not** draw a dot for every sample. Samples are vertices in a single path or pressure ribbon.

Diagnostic raw/filtered/computed point markers are combined into compound paths rather than one layer per point. They can still become expensive when enabled for every saved stroke. Keep **Only visualize active stroke** enabled during normal use.

## Known issues deliberately not addressed

- Slow synchronization.
- Repeated Sync requests can backlog and risk replacing newer progress with older state.
- Slow page insertion / append.
- The computer viewer remains an HTML canvas and will be rebuilt separately.

## Validation performed

- Swift syntax parsing for all native source files.
- Python server compilation.
- Six server tests, including SVG page generation and vector PDF ink verification.
- Source scan confirming the iPad ink view no longer uses `UIGraphicsImageRenderer`, `committedImage`, or a page `cgImage` cache.
