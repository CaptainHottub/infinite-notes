# Eraser appearance, size, and desktop exports

## iPad

Open **Settings → Stroke → Eraser**. Set **Outline on PDF** and **Outline outside
PDF** independently. Defaults are dark on the PDF and white on the outer workspace.
The eraser centre determines which colour is used. The translucent grey fill is
unchanged. Existing saved app settings remain readable.

Eraser presets and the toolbar eraser popover now allow **1–120 pt**, in 1 pt
steps. The drawn cursor follows that diameter without the previous 4 pt visual
minimum; the outline becomes thinner for very small erasers.

## Computer browser

Open the desktop interface on the computer running the server:
`http://127.0.0.1:8000/?mode=desktop` (substitute your configured port).

**Open PDF** and **Import project** use a desktop file picker and remember the
selected file's folder. **Export project** and **Export notes PDF** then save
there and report the saved path. Existing files are never overwritten: repeated
exports receive suffixes such as `lecture (1).inotes` and `lecture-notes (1).pdf`.
An imported project is also preserved rather than replaced by its export.

For a notebook opened before this change, the first export asks you to select the
original import folder once. You can change it with **Export folder…**. This does
not re-import the notebook or discard ink/history. The folder is remembered across
server restarts in the machine-local `computer/data/export-origin.json`, tied to
the notebook identity. It is excluded from portable project archives. A new
ordinary browser upload clears the previous destination rather than guessing.

This integration requires a graphical Linux session with `kdialog` or `zenity`;
both are present on the development desktop. Remote browsers, iPad exports, and
servers without a desktop picker retain their existing download/share behavior.
Normal browser uploads do not expose the original folder to the server, which is
why the local desktop picker is used. See [MDN file input documentation](https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input/file).

If the remembered folder is removed or no longer writable, export reports an
error. Select another folder rather than silently saving elsewhere. Cancellation
leaves the notebook and previous destination intact. The destination can be on a
filesystem without hard-link support, including a removable drive.

## Verification and remaining device check

Validation on 2026-09-17: `./scripts/test-all.sh` passed 170 Python tests, iPad
package validation, and all four native Swift test programs. `xtool dev build`
successfully built the iPad app against the iOS SDK. JavaScript syntax validation
(`node --check computer/static/app.js`) and `git diff --check` passed. Interactive
browser validation could not run because no browser connection was available.

Automated tests cover PDF/project import, both exports, collisions, preservation
of originals, destination reload, clearing a stale destination, cancelled pickers,
failed saves, filesystems without hard links, and restricted desktop-file access.
The desktop picker is stubbed in these tests; they do not exercise the OS dialog.

After updating the server and installing the built iPad app:

1. Set distinct eraser colours, move across the PDF edge, and try a 1–7 pt size.
   Relaunch the app and confirm the settings remain.
2. Open a disposable PDF in the computer browser and export both formats.
   Confirm they land beside the PDF. Repeat and confirm the originals remain.
3. Import the exported project from another folder and verify exports follow it.

The 90-minute lecture report and the dense-page/offline eraser failures are
preserved in [known issues](../KNOWN-ISSUES.md). This feature work does not repair
those failures or implement the proposed workspace and whiteboard features.
