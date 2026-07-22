import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var strokeSettings: StrokeSettingsStore
    @ObservedObject var appSettings: AppSettingsStore
    @Binding var serverAddress: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            connectionTab
                .tabItem { Label("Connection", systemImage: "network") }
            displayTab
                .tabItem { Label("Display", systemImage: "display") }
            strokeTab
                .tabItem { Label("Stroke", systemImage: "pencil.tip") }
            geometryTab
                .tabItem { Label("Geometry", systemImage: "square.on.circle") }
            selectionTab
                .tabItem { Label("Selection", systemImage: "lasso") }
            diagnosticsTab
                .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
        }
    }

    private var connectionTab: some View {
        settingsNavigation(title: "Connection") {
            Section("Laptop server") {
                TextField("http://10.42.0.1:8000", text: $serverAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                HStack {
                    Button("Connect") { model.connect(address: serverAddress) }
                        .buttonStyle(.borderedProminent)
                    Button("Disconnect") { model.disconnect() }
                        .buttonStyle(.bordered)
                    Button("Sync") { model.syncNow() }
                        .buttonStyle(.bordered)
                        .disabled(!model.isConnected)
                }
                LabeledContent("Status", value: model.connectionLabel)
                LabeledContent("Client ID", value: model.clientID)
                    .textSelection(.enabled)
            }

            Section("Document") {
                LabeledContent("PDF renderer", value: "Core Graphics vector tiles")
                LabeledContent("Pages", value: "\(model.pageCount)")
                LabeledContent("Current page", value: model.currentPageNumber == 0 ? "—" : "\(model.currentPageNumber)")
                LabeledContent("Mounted", value: model.mountedPageIndices.isEmpty
                               ? "None"
                               : model.mountedPageIndices.map { String($0 + 1) }.sorted().joined(separator: ", "))
            }

            Section("Compatibility") {
                Text("The native client uses the existing v24 stroke, shape, locking, undo and WebSocket formats. New Pencil samples also retain raw and page-local coordinates when the patched server is used.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayTab: some View {
        settingsNavigation(title: "Display") {
            Section("Notebook") {
                Picker("Background", selection: $appSettings.configuration.backgroundStyle) {
                    ForEach(NotebookBackgroundStyle.allCases) { style in Text(style.title).tag(style) }
                }
                Toggle("Page shadows", isOn: $appSettings.configuration.showPageShadow)
                Toggle("Status bar", isOn: $appSettings.configuration.showStatusBar)
                valueSlider("Page gap", value: $appSettings.configuration.pageGap, range: 0...60, step: 1, format: "%.0f pt")
                Stepper("Mounted page radius: ±\(appSettings.configuration.pageWorkingRadius)",
                        value: $appSettings.configuration.pageWorkingRadius, in: 0...6)
                valueSlider("Maximum zoom", value: $appSettings.configuration.maximumZoom, range: 4...24, step: 1, format: "%.0f×")
                Toggle("Lower-quality neighbouring ink", isOn: $appSettings.configuration.reduceNeighbourInkQuality)
            }

            Section("Committed ink cache") {
                valueSlider("Maximum backing scale", value: $strokeSettings.configuration.maximumInkCacheScale,
                            range: 2...12, step: 0.5, format: "%.1f×")
                valueSlider("Per-page pixel budget", value: $strokeSettings.configuration.maximumInkCacheMegapixels,
                            range: 4...64, step: 1, format: "%.0f MP")
                Text("Live writing remains vector-backed. These limits affect only completed page ink after zooming settles.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var strokeTab: some View {
        settingsNavigation(title: "Stroke Pipeline", reset: strokeSettings.resetToDefaults) {
            Section("Pen appearance") {
                Toggle("Pressure-sensitive pen width", isOn: $model.penPressureEnabled)
                Picker("Line style", selection: Binding(
                    get: { model.inkLineStyle },
                    set: { model.applyLineStyle($0) }
                )) {
                    ForEach(GeometryLineStyle.allCases) { style in Text(style.title).tag(style) }
                }

                ForEach(model.inkColorPresets.indices, id: \.self) { index in
                    ColorPicker(
                        "Colour preset \(index + 1)",
                        selection: Binding(
                            get: { Color(hex: model.inkColorPresets[index]) },
                            set: { color in model.updateColorPreset(index, hex: color.noteHex ?? "#111111") }
                        ),
                        supportsOpacity: false
                    )
                }

                ForEach(model.penWidthPresets.indices, id: \.self) { index in
                    valueSlider(
                        "Width preset \(index + 1)",
                        value: Binding(
                            get: { model.penWidthPresets[index] },
                            set: { model.updatePenWidthPreset(index, value: $0) }
                        ),
                        range: 0.5...30,
                        step: 0.5,
                        format: "%.1f pt"
                    )
                }
                Text("Tap a toolbar preset to apply it. Tap the active colour again, or press and hold a width preset, to edit it without opening Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Eraser") {
                ForEach(model.eraserWidthPresets.indices, id: \.self) { index in
                    valueSlider(
                        "Eraser preset \(index + 1)",
                        value: Binding(
                            get: { model.eraserWidthPresets[index] },
                            set: { model.updateEraserWidthPreset(index, value: $0) }
                        ),
                        range: 8...120,
                        step: 2,
                        format: "%.0f pt"
                    )
                }
                Text("The eraser outline shows the exact whole-object erase diameter while the Pencil is touching the page.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("1. Pencil capture") {
                Toggle("Coalesced Pencil samples", isOn: $strokeSettings.configuration.useCoalescedTouches)
                Toggle("Predicted live-preview samples", isOn: $strokeSettings.configuration.usePredictedTouches)
                valueSlider("Pressure threshold", value: $strokeSettings.configuration.pressureThreshold,
                            range: 0...0.35, step: 0.005, format: "%.3f")
                valueSlider("Minimum accepted spacing", value: $strokeSettings.configuration.minimumSampleSpacing,
                            range: 0.05...5, step: 0.05, format: "%.2f pt")
                valueSlider("Pressure-change acceptance", value: $strokeSettings.configuration.pressureDeltaThreshold,
                            range: 0...0.2, step: 0.005, format: "%.3f")
                Stepper("Network batch: \(strokeSettings.configuration.networkBatchSize) points",
                        value: $strokeSettings.configuration.networkBatchSize, in: 1...128)
                valueSlider("Network flush interval", value: $strokeSettings.configuration.networkFlushIntervalMS,
                            range: 1...40, step: 1, format: "%.0f ms")
            }

            Section("2. Input filtering") {
                Picker("Position filter", selection: $strokeSettings.configuration.inputSmoothingAlgorithm) {
                    ForEach(InputSmoothingAlgorithm.allCases) { algorithm in Text(algorithm.title).tag(algorithm) }
                }
                valueSlider("Filter strength", value: $strokeSettings.configuration.smoothingStrength,
                            range: 0...1, step: 0.01, format: "%.2f")
                Toggle("Adaptive filtering", isOn: $strokeSettings.configuration.adaptiveSmoothing)
                valueSlider("Input pressure smoothing", value: $strokeSettings.configuration.pressureSmoothing,
                            range: 0...1, step: 0.01, format: "%.2f")
                if strokeSettings.configuration.inputSmoothingAlgorithm == .oneEuro {
                    valueSlider("One Euro minimum cutoff", value: $strokeSettings.configuration.oneEuroMinCutoff,
                                range: 0.05...8, step: 0.05, format: "%.2f Hz")
                    valueSlider("One Euro speed coefficient", value: $strokeSettings.configuration.oneEuroBeta,
                                range: 0...0.25, step: 0.001, format: "%.3f")
                    valueSlider("Derivative cutoff", value: $strokeSettings.configuration.oneEuroDerivativeCutoff,
                                range: 0.05...8, step: 0.05, format: "%.2f Hz")
                }
            }

            Section("3. Resampling and spline") {
                Toggle("Uniform distance resampling", isOn: $strokeSettings.configuration.resamplingEnabled)
                if strokeSettings.configuration.resamplingEnabled {
                    valueSlider("Input resample spacing", value: $strokeSettings.configuration.resampleSpacing,
                                range: 0.2...6, step: 0.05, format: "%.2f pt")
                }
                Picker("Spline algorithm", selection: $strokeSettings.configuration.splineAlgorithm) {
                    ForEach(SplineAlgorithm.allCases) { algorithm in Text(algorithm.title).tag(algorithm) }
                }
                valueSlider("Computed point spacing", value: $strokeSettings.configuration.splineSampleSpacing,
                            range: 0.2...6, step: 0.05, format: "%.2f pt")
                if strokeSettings.configuration.splineAlgorithm == .cubicBezier {
                    valueSlider("Bézier tension", value: $strokeSettings.configuration.splineTension,
                                range: 0...1, step: 0.01, format: "%.2f")
                }
                valueSlider("Computed pressure smoothing", value: $strokeSettings.configuration.computedPressureSmoothing,
                            range: 0...1, step: 0.01, format: "%.2f")
            }

            Section("4. Pressure ribbon") {
                Toggle("Continuous variable-width ribbon", isOn: $strokeSettings.configuration.variableWidthRibbon)
                valueSlider("Minimum width multiplier", value: $strokeSettings.configuration.minimumPressureScale,
                            range: 0.05...1, step: 0.01, format: "%.2f×")
                valueSlider("Maximum width multiplier", value: $strokeSettings.configuration.maximumPressureScale,
                            range: 0.25...2.5, step: 0.01, format: "%.2f×")
                valueSlider("Pressure response gamma", value: $strokeSettings.configuration.pressureGamma,
                            range: 0.1...3, step: 0.02, format: "%.2f")
                valueSlider("Start taper length", value: $strokeSettings.configuration.startTaperLength,
                            range: 0...30, step: 0.25, format: "%.2f pt")
                valueSlider("End taper length", value: $strokeSettings.configuration.endTaperLength,
                            range: 0...30, step: 0.25, format: "%.2f pt")
                valueSlider("Minimum taper multiplier", value: $strokeSettings.configuration.taperMinimumScale,
                            range: 0.01...1, step: 0.01, format: "%.2f×")
            }
        }
    }

    private var geometryTab: some View {
        settingsNavigation(title: "Geometry", reset: appSettings.resetToDefaults) {
            Section("Creation") {
                Picker("Default shape", selection: $model.selectedShapeType) {
                    ForEach(GeometryShapeType.allCases.filter { $0 != .xyPlane }) { type in
                        Label(type.title, systemImage: type.symbolName).tag(type)
                    }
                }
                Picker("Line style", selection: Binding(
                    get: { model.activeLineStyle },
                    set: { model.applyLineStyle($0) }
                )) {
                    ForEach(GeometryLineStyle.allCases) { style in Text(style.title).tag(style) }
                }
                Button {
                    model.insertXYPlane()
                } label: {
                    Label("Insert X–Y plane on current page", systemImage: "chart.xyaxis.line")
                }
                Toggle("Lock new X–Y planes", isOn: $appSettings.configuration.lockNewXYPlanes)
                Stepper("Grid divisions: \(appSettings.configuration.xyPlaneGridDivisions)",
                        value: $appSettings.configuration.xyPlaneGridDivisions, in: 2...40)
                valueSlider("Plane width", value: $appSettings.configuration.xyPlaneWidthFraction,
                            range: 0.2...0.95, step: 0.05, format: "%.0f%%", multiplier: 100)
                valueSlider("Plane height", value: $appSettings.configuration.xyPlaneHeightFraction,
                            range: 0.2...0.95, step: 0.05, format: "%.0f%%", multiplier: 100)
            }

            Section("Hold recognition") {
                Toggle("Recognize held ink", isOn: $appSettings.configuration.holdRecognitionEnabled)
                if appSettings.configuration.holdRecognitionEnabled {
                    valueSlider("Hold duration", value: $appSettings.configuration.recognitionHoldMS,
                                range: 150...1600, step: 25, format: "%.0f ms")
                    valueSlider("Line tolerance", value: $appSettings.configuration.lineRecognitionTolerance,
                                range: 1...60, step: 0.5, format: "%.1f%%")
                    valueSlider("Curve tolerance", value: $appSettings.configuration.curveRecognitionTolerance,
                                range: 2...35, step: 0.5, format: "%.1f%%")
                }
                Text("Draw with Pen, stop moving while keeping the Pencil down, and the stroke can become an editable line or quadratic curve.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Snapping") {
                Toggle("Endpoint snapping", isOn: $appSettings.configuration.endpointSnap)
                Toggle("Horizontal and vertical snapping", isOn: $appSettings.configuration.axisSnap)
                Toggle("Tangent snapping to ellipses", isOn: $appSettings.configuration.tangentSnap)
                Toggle("Normal snapping to ellipses", isOn: $appSettings.configuration.normalSnap)
                Toggle("Show snap guides", isOn: $appSettings.configuration.showSnapGuides)
                valueSlider("Snap distance", value: $appSettings.configuration.geometrySnapDistance,
                            range: 4...40, step: 1, format: "%.0f pt")
                Text("Line and arrow endpoints can snap to nearby endpoints, horizontal/vertical alignment, X–Y plane axes, and tangent or normal points on circles and ellipses.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectionTab: some View {
        settingsNavigation(title: "Selection") {
            Section("Lasso and hit testing") {
                valueSlider("Lasso sample spacing", value: $appSettings.configuration.lassoSampleSpacing,
                            range: 0.5...10, step: 0.5, format: "%.1f pt")
                valueSlider("Direct hit radius", value: $appSettings.configuration.selectorHitRadius,
                            range: 4...30, step: 1, format: "%.0f pt")
                Toggle("Locked items require lasso", isOn: $appSettings.configuration.selectLockedItemsOnlyByLasso)
                Toggle("Show selection bounds", isOn: $appSettings.configuration.showSelectionBounds)
                valueSlider("Handle size", value: $appSettings.configuration.selectionHandleSize,
                            range: 7...24, step: 1, format: "%.0f pt")
                valueSlider("Paste offset", value: $appSettings.configuration.pasteOffset,
                            range: 4...80, step: 2, format: "%.0f pt")
            }

            Section("Behaviour") {
                Toggle("Selection haptics", isOn: $appSettings.configuration.hapticsEnabled)
                Text("Locked ink and geometry are protected from erasing and direct dragging. Surround them with the lasso, then use the lock button to unlock them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Current selection") {
                LabeledContent("Selected", value: model.selectionSummary)
                HStack {
                    Button(model.selectionAllLocked ? "Unlock" : "Lock") { model.toggleSelectionLock() }
                        .disabled(!model.hasSelection)
                    Button("Copy") { model.copySelection() }.disabled(!model.hasSelection)
                    Button("Paste") { model.pasteSelection() }.disabled(!model.canPaste)
                    Button("Delete", role: .destructive) { model.deleteSelection() }.disabled(!model.hasSelection)
                }
            }
        }
    }

    private var diagnosticsTab: some View {
        settingsNavigation(title: "Diagnostics") {
            Section("Pipeline visualization") {
                Toggle("Only visualize active stroke", isOn: $strokeSettings.configuration.debugLiveStrokeOnly)
                Toggle("Raw Pencil points — red", isOn: $strokeSettings.configuration.showRawPoints)
                Toggle("Raw connections — light gray", isOn: $strokeSettings.configuration.showRawConnections)
                Toggle("Filtered points — orange", isOn: $strokeSettings.configuration.showFilteredPoints)
                Toggle("Filtered connections — orange", isOn: $strokeSettings.configuration.showFilteredConnections)
                Toggle("Computed spline points — blue", isOn: $strokeSettings.configuration.showComputedPoints)
                Toggle("Computed connections — blue", isOn: $strokeSettings.configuration.showComputedConnections)
                Toggle("Computed centreline — purple", isOn: $strokeSettings.configuration.showComputedCenterline)
                valueSlider("Debug dot diameter", value: $strokeSettings.configuration.debugPointDiameter,
                            range: 1...12, step: 0.5, format: "%.1f pt")
            }

            Section("Runtime") {
                LabeledContent("Build", value: "0.5.3")
                LabeledContent("PDF", value: model.pdfDocument == nil ? "Not loaded" : "Loaded")
                LabeledContent("Connection", value: model.connectionLabel)
                LabeledContent("Mounted pages", value: "\(model.mountedPageIndices.count)")
                if let notice = model.notice { Text(notice).font(.footnote) }
            }
        }
    }

    private func settingsNavigation<Content: View>(
        title: String,
        reset: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            Form { content() }
                .navigationTitle(title)
                .toolbar {
                    if let reset {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Reset", role: .destructive, action: reset)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String,
        multiplier: Double = 1
    ) -> some View {
        LabeledContent(title) {
            Text(String(format: format, value.wrappedValue * multiplier)).monospacedDigit()
        }
        Slider(value: value, in: range, step: step)
    }
}
