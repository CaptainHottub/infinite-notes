# Vector page templates

The iPad's **Add page** action offers a blank page, a copy of the current
underlying PDF page without ink, or a saved paper template. Each can be
inserted below the current page or appended at the end. Blank and generated
pages default to the current page's dimensions. The editor also accepts custom
width/height in inches or millimetres and offers standard paper sizes.
Template grid spacing stays in physical units; no PDF page is stretched to fit.

Choose Blank, Copy PDF page, or a saved template directly in the Page source
section. Below it, editable settings include title, background, independent
minor/major lines, and dots. Editing a saved design selects New Template;
the original stays in the library. Use Save template to keep the new design.
The position checkbox inserts below the current page when checked and appends
at the end when unchecked.

Delete current page is available in the page menu with confirmation. It removes
that page and its ink, and keeps at least one page. Inserting or deleting pages
shares the ordered undo/redo history with ink edits. Undoing a deletion restores
its PDF page, ink, workspace content, and earlier ink history. New page changes
clear the redo branch, just like new ink edits. History is server-session-local.
Page changes use a coordinated layout update and stable page-local ink storage;
see [page-layout.md](page-layout.md) for migration and synchronization details.

The template library is one JSON file at
`computer/data/page-templates/presets.json` (or under
`INFINITE_NOTES_DATA_DIR/page-templates/`). It is local to each computer and
is excluded from Git. Four basic presets are available before the file is
created. The iPad lists preset names and the dimensions of the page it will
generate. Tap **Refresh templates** after changing the file.

The repository's `scripts/pdf-make` uses the same PyMuPDF vector generator
as the server. To replace an existing `pdf-make` command safely, run
`./scripts/install-pdf-make.sh` on each computer; the installer keeps the old
script as a timestamped backup. The computer setup must have installed the
project's Python requirements first.

Examples:

```sh
./scripts/pdf-make --eng --save-preset "Engineering paper" --out engineering.pdf
./scripts/pdf-make --style dot --spacing 0.5 --line-color '#bbbbbb' \
  --save-preset "Five-millimetre dots" --out dots.pdf
./scripts/pdf-make --style grid --spacing 0.5 --width-pt 612 --height-pt 792 \
  --out letter-grid.pdf
```

`--save-preset` stores the design, not the CLI page dimensions: when selected
on the iPad, the server generates a fresh page at the current PDF page's exact
width and height. Existing raster PDFs without saved settings cannot be
regenerated as vector templates automatically. The CLI accepts the old
`--density` option for compatibility, but vector PDF resolution is independent
of it; legacy line-width values are converted to physical widths.
