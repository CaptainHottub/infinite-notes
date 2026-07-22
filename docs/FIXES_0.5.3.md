# Infinite Notes 0.5.3 fixes

This develop update groups eight native-client reliability fixes.

## Rendering

A completed stroke stays in the live vector overlay until the rebuilt committed page image is installed. The overlay is then removed in the same main-thread hand-off, preventing the stroke from disappearing for a frame.

## Input routing

Apple Pencil Pen and Highlighter contacts always begin ink. Existing unlocked geometry can be selected and manipulated directly with one finger, while locked geometry remains available only through lasso selection. The eraser continues to ignore locked objects.

## Zoom-independent interaction

Selection handles, endpoint controls, rotation handles, lasso sample spacing, selector hit radius, snap markers, and overlay line widths are converted from screen points using the current PDF zoom.

## Large notebook synchronization

Full notebook state remains on compressed HTTP. Any unexpectedly large WebSocket update sent to a native client is replaced with a small `state_refresh` notification. Project import responses no longer repeat the full restored state.
