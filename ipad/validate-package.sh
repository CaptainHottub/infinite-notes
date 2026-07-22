#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

swift package dump-package >/dev/null
for file in Sources/InfiniteNotesStrokeLab/*.swift; do
  swiftc -parse "$file"
done
plutil -lint Info.plist

[[ $(grep -R '^@main' Sources/InfiniteNotesStrokeLab | wc -l) -eq 1 ]]
grep -q 'case selector' Sources/InfiniteNotesStrokeLab/Models.swift
grep -q 'case xyPlane' Sources/InfiniteNotesStrokeLab/Models.swift
grep -q 'recognizeActiveInk' Sources/InfiniteNotesStrokeLab/AppModel.swift
grep -q 'nearestEllipseSnap' Sources/InfiniteNotesStrokeLab/AppModel.swift
grep -q 'selectionHandleHit' Sources/InfiniteNotesStrokeLab/InkPageView.swift
grep -q 'rotationEffect(.degrees(90))' Sources/InfiniteNotesStrokeLab/ContentView.swift
grep -q 'TabView' Sources/InfiniteNotesStrokeLab/SettingsView.swift
grep -q 'penPressureEnabled' Sources/InfiniteNotesStrokeLab/AppModel.swift
grep -q 'eraserCursor' Sources/InfiniteNotesStrokeLab/InteractionOverlayRenderer.swift
grep -q 'ProcessInfo.processInfo.systemUptime' Sources/InfiniteNotesStrokeLab/GeometryEngine.swift
grep -q 'PenWidthPresetPreview' Sources/InfiniteNotesStrokeLab/ContentView.swift

echo "Infinite Notes 0.5.2 package validation passed."
