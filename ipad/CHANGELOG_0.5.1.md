# 0.5.1

- Fixed geometry creation failing with `Invalid point field: t` by storing geometry timestamps as device-uptime milliseconds, matching live Pencil samples and the v24 server range.
- Merged Pen and Fixed Pen into one visible **Pen** tool.
- Added an adjacent pressure-sensitivity toggle; disabled pressure stores new strokes as the existing v24 `fixed-pen` type.
- Added selectable solid, dashed and dotted styles for ink and geometry.
- Added five persistent, editable ink-colour presets.
- Applying a colour, width or line style while ink/geometry is selected now restyles the selected objects.
- Added three persistent, editable pen-width presets beside the width slider.
- Added three persistent, editable eraser-width presets beside the eraser slider.
- Added a visible eraser-diameter circle while erasing.
- Added preset and appearance controls to the Stroke settings tab.
- Retained the 0.5.0 geometry, lasso, locking, snapping, X-Y plane and smooth-stroke pipeline.
