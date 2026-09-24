# Workspace and whiteboard design notes

Discussion record, 2026-09-23. The implementation is in this worktree; automated
server tests and a native iPad build cover it, but device interaction and visual
export checks are still pending.

## 4. Workspace beside imported PDFs

- Render writable workspace on both sides of every PDF page before any ink is present.
- Each workspace section is exactly one source PDF-page width. The iPad has
  separate settings for the number of sections initially visible on the left
  and right; start with one left and two right.
- A further iPad setting controls how many empty workspace sections remain
  visible beyond the outermost inked section on each side as writing expands.
  Each side keeps at least its independently configured initial count. For
  example, with two initially visible sections on the right and two extra
  sections after ink, writing in the third right section makes five right
  sections visible. Left and right expand independently. After erasing the last
  ink in a far-out section, shrink unused sections when the erase gesture ends;
  preserve the user's visible position while relaying out the workspace.
- The extension in this feature is horizontal only. Keep panning and writing in
  the workspace possible; preserve the PDF and ink coordinates as it expands.
- Outline each side workspace region. Let the user configure its appearance,
  including width and separate outline colours for an empty region and one
  containing ink.
- Future iPad workspace presets should include custom background colour, grid
  colour, grid spacing, and grid line thickness. Record this as a future feature.

## 5. Standalone whiteboard

- Create a whiteboard without an imported PDF. New boards copy global default
  settings; each board can then have its own appearance and export settings.
  There is one tiled-section whiteboard model, with one section size, ink
  coordinate system, and writing-halo rule. There is no separate persistent
  sized/limitless whiteboard mode.
- Choose a page-section format and orientation when creating a board. Offer a
  format picker with multiple paper sizes (including Letter and A4), plus a
  custom size. The section size of an existing board cannot be changed.
- Panning is free in all directions. Restrict where a stroke may start to a
  configurable writing halo of 1–10 sections around the initial section or
  any section containing ink. There is no overall expansion limit:
  writing in a newly reached section extends the eligible area. A distant
  accidental mark should not create a remote exported page. The halo is square:
  a diagonally adjacent section counts as one step.
- Let each whiteboard show or hide section outlines independently of export.
  When shown, use configurable colours for vertical boundaries between inked
  sections, horizontal boundaries between inked sections, and boundaries next
  to empty sections. The empty-side colour takes priority regardless of
  boundary direction. Section outlines do not appear in exported PDFs.
- At export, offer a paged PDF. It uses one page per section row from the
  topmost inked row to the bottommost inked row, with each page one section
  tall. Horizontal expansion widens the page in section-width increments.
  Every exported page has the width of the widest row; the initial section
  aligns horizontally across pages. Include intervening empty sections.
- Before paged export, optionally warn about empty or very sparse pages using
  stroke count and/or total stroke length. Ask the user to confirm; do not
  silently discard pages. The current heuristic flags a page with no strokes,
  or at most one stroke shorter than 30 points.
- At export, also offer a single large PDF page/vector item. This choice is
  independent of whether section outlines are visible on the iPad. Offer two
  bounds options: fit tightly around the ink, or use the rectangular
  bounds of sections containing ink, including empty sections inside that
  rectangle. Merely panning over an empty section or having it available within
  the writing halo does not expand the export. Both options should offer a
  configurable border buffer outside the calculated bounds at export.
- The iPad may use a system-adaptive workspace palette. PDF export should allow
  explicit background and grid-line colours. Background and grid are optionally
  included in export; section boundary guides are not.

## Implementation notes and remaining validation

- The iPad stores defaults for new boards, while each board stores its own
  appearance, halo, and immutable section size. Export colour and layout
  choices are selected at export time. Reusable presets remain a future feature.
- The computer keeps one active notebook and archives it as an `.inotes` file
  when another notebook is created or opened. This is a switch-time archive,
  not a full rewrite on each stroke. Saved notebooks can be reopened from the
  iPad's Whiteboard settings tab.
- Verify side-workspace expansion and shrink, guide colours, free panning,
  halo behavior, notebook switching, and both PDF export modes on the iPad.
  No iPad installation or live notebook modification was done in this pass.
