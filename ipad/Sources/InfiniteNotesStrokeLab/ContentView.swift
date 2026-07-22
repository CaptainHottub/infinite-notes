import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var navigator = PDFNavigator()
    @AppStorage("native.serverAddress") private var serverAddress = "http://10.42.0.1:8000"
    @State private var showingSettings = false
    @State private var didAutoConnect = false
    @State private var editingPreset: PresetEditorTarget?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                if model.pdfDocument != nil {
                    PDFKitNotebookView(model: model, navigator: navigator)
                } else {
                    emptyState
                }
            }
            if model.appSettings.configuration.showStatusBar { statusBar }
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                model: model,
                strokeSettings: model.strokeSettings,
                appSettings: model.appSettings,
                serverAddress: $serverAddress
            )
        }
        .popover(item: $editingPreset) { target in
            presetEditor(for: target)
        }
        .alert("Infinite Notes", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "Unknown error")
        }
        .onAppear {
            guard !didAutoConnect else { return }
            didAutoConnect = true
            model.connect(address: serverAddress)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!model.canUndo)
                        .accessibilityLabel("Undo")
                    Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!model.canRedo)
                        .accessibilityLabel("Redo")

                    Divider().frame(height: 30)

                    ForEach(NoteTool.allCases) { tool in
                        ToolButton(tool: tool, selected: model.selectedTool == tool) {
                            model.selectedTool = tool
                            if tool != .selector { model.clearSelection() }
                            if tool == .highlighter, model.inkWidth < 8 { model.inkWidth = 18 }
                            if tool == .pressurePen, model.inkWidth > 12 { model.inkWidth = 3 }
                        }
                    }

                    if model.selectedTool == .shape {
                        Menu {
                            Section("Geometry") {
                                ForEach(GeometryShapeType.allCases.filter { $0 != .xyPlane }) { type in
                                    Button {
                                        model.selectedShapeType = type
                                    } label: {
                                        Label(type.title, systemImage: type.symbolName)
                                    }
                                }
                            }
                            Divider()
                            Button {
                                model.insertXYPlane()
                            } label: {
                                Label("Insert X–Y plane", systemImage: GeometryShapeType.xyPlane.symbolName)
                            }
                        } label: {
                            Label(model.selectedShapeType.title, systemImage: model.selectedShapeType.symbolName)
                                .font(.callout)
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider().frame(height: 30)
                    toolControls

                    if model.hasSelection || model.canPaste {
                        Divider().frame(height: 30)
                        selectionControls
                    }

                    Divider().frame(height: 30)

                    Button(action: navigator.previousPage) { Image(systemName: "chevron.up") }
                        .disabled(model.currentPageNumber <= 1)
                        .accessibilityLabel("Previous page")

                    Text(model.pageCount == 0 ? "—" : "\(model.currentPageNumber)/\(model.pageCount)")
                        .font(.callout.monospacedDigit())
                        .frame(minWidth: 58)

                    Button(action: navigator.nextPage) { Image(systemName: "chevron.down") }
                        .disabled(model.currentPageNumber == 0 || model.currentPageNumber >= model.pageCount)
                        .accessibilityLabel("Next page")

                    Button(action: navigator.fitPage) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel("Fit page")

                    Divider().frame(height: 30)

                    Button(action: model.syncNow) { Image(systemName: "arrow.triangle.2.circlepath") }
                        .disabled(!model.isConnected)
                        .accessibilityLabel("Sync now")
                }
                .font(.title3)
                .padding(.leading, 14)
                .padding(.vertical, 8)
            }

            Divider().frame(height: 34)

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Settings")
            .padding(.trailing, 12)
        }
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var toolControls: some View {
        if model.selectedTool == .eraser {
            HStack(spacing: 5) {
                ForEach(model.eraserWidthPresets.indices, id: \.self) { index in
                    Button {
                        if abs(model.eraserSize - model.eraserWidthPresets[index]) < 0.1 {
                            editingPreset = PresetEditorTarget(kind: .eraserWidth, index: index)
                        } else {
                            model.selectEraserWidthPreset(index)
                        }
                    } label: {
                        EraserPresetPreview(
                            value: model.eraserWidthPresets[index],
                            selected: abs(model.eraserSize - model.eraserWidthPresets[index]) < 0.1
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit eraser preset") {
                            editingPreset = PresetEditorTarget(kind: .eraserWidth, index: index)
                        }
                    }
                    .accessibilityLabel("Eraser width preset \(index + 1), \(Int(model.eraserWidthPresets[index]))")
                }
            }

            Text("\(Int(model.eraserSize))")
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
            Slider(value: $model.eraserSize, in: 8...120, step: 2)
                .frame(width: 135)
                .accessibilityLabel("Eraser diameter")
        } else if model.selectedTool != .selector {
            HStack(spacing: 5) {
                ForEach(model.inkColorPresets.indices, id: \.self) { index in
                    Button {
                        if !model.hasSelection, model.activeColorPresetIndex == index {
                            editingPreset = PresetEditorTarget(kind: .color, index: index)
                        } else {
                            model.selectColorPreset(index)
                        }
                    } label: {
                        Circle()
                            .fill(Color(hex: model.inkColorPresets[index]))
                            .frame(width: 23, height: 23)
                            .overlay {
                                Circle().stroke(
                                    model.activeColorPresetIndex == index ? Color.primary : Color.secondary.opacity(0.35),
                                    lineWidth: model.activeColorPresetIndex == index ? 2.2 : 1
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit colour") {
                            editingPreset = PresetEditorTarget(kind: .color, index: index)
                        }
                    }
                    .accessibilityLabel("Ink colour preset \(index + 1)")
                }
            }

            HStack(spacing: 5) {
                ForEach(model.penWidthPresets.indices, id: \.self) { index in
                    Button {
                        if !model.hasSelection, abs(model.inkWidth - model.penWidthPresets[index]) < 0.05 {
                            editingPreset = PresetEditorTarget(kind: .penWidth, index: index)
                        } else {
                            model.selectPenWidthPreset(index)
                        }
                    } label: {
                        PenWidthPresetPreview(
                            value: model.penWidthPresets[index],
                            selected: abs(model.inkWidth - model.penWidthPresets[index]) < 0.05,
                            color: Color(hex: model.inkColorHex)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit width preset") {
                            editingPreset = PresetEditorTarget(kind: .penWidth, index: index)
                        }
                    }
                    .accessibilityLabel("Line width preset \(index + 1), \(model.penWidthPresets[index], specifier: "%.1f")")
                }
            }

            Text(String(format: "%.1f", model.inkWidth))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
            Slider(
                value: $model.inkWidth,
                in: 0.5...30,
                step: 0.5,
                onEditingChanged: { editing in
                    if !editing { model.applyCurrentWidthToSelection() }
                }
            )
            .frame(width: 125)
            .accessibilityLabel("Ink width")

            Menu {
                ForEach(GeometryLineStyle.allCases) { style in
                    Button {
                        model.applyLineStyle(style)
                    } label: {
                        if model.activeLineStyle == style {
                            Label(style.title, systemImage: "checkmark")
                        } else {
                            Text(style.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    LineStylePreview(style: model.activeLineStyle)
                        .frame(width: 34, height: 16)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .frame(height: 29)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Line style: \(model.activeLineStyle.title)")

            if model.selectedTool == .pressurePen {
                Button {
                    model.penPressureEnabled.toggle()
                } label: {
                    Image(systemName: model.penPressureEnabled ? "waveform.path.ecg" : "minus")
                        .frame(width: 28, height: 28)
                        .background(
                            model.penPressureEnabled ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(model.penPressureEnabled ? "Pressure sensitivity on" : "Pressure sensitivity off")
            }
        }
    }

    private var selectionControls: some View {
        HStack(spacing: 6) {
            Text(model.selectionSummary)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 120)

            Button(action: model.toggleSelectionLock) {
                Image(systemName: model.selectionAllLocked ? "lock.open" : "lock")
            }
            .disabled(!model.hasSelection)
            .accessibilityLabel(model.selectionAllLocked ? "Unlock selection" : "Lock selection")

            Button(action: model.copySelection) { Image(systemName: "doc.on.doc") }
                .disabled(!model.hasSelection)
                .accessibilityLabel("Copy selection")
            Button(action: model.pasteSelection) { Image(systemName: "doc.on.clipboard") }
                .disabled(!model.canPaste)
                .accessibilityLabel("Paste")
            Button(role: .destructive, action: model.deleteSelection) { Image(systemName: "trash") }
                .disabled(!model.hasSelection)
                .accessibilityLabel("Delete selection")
            Button(action: model.clearSelection) { Image(systemName: "xmark") }
                .disabled(!model.hasSelection)
                .accessibilityLabel("Clear selection")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func presetEditor(for target: PresetEditorTarget) -> some View {
        switch target.kind {
        case .color:
            ColorPresetEditor(initialHex: model.inkColorPresets[target.index]) { hex in
                model.updateColorPreset(target.index, hex: hex)
                editingPreset = nil
            } onCancel: {
                editingPreset = nil
            }
        case .penWidth:
            WidthPresetEditor(
                title: "Pen width \(target.index + 1)",
                initialValue: model.penWidthPresets[target.index],
                range: 0.5...30,
                step: 0.5,
                suffix: "pt"
            ) { value in
                model.updatePenWidthPreset(target.index, value: value)
                editingPreset = nil
            } onCancel: {
                editingPreset = nil
            }
        case .eraserWidth:
            WidthPresetEditor(
                title: "Eraser width \(target.index + 1)",
                initialValue: model.eraserWidthPresets[target.index],
                range: 8...120,
                step: 2,
                suffix: "pt"
            ) { value in
                model.updateEraserWidthPreset(target.index, value: value)
                editingPreset = nil
            } onCancel: {
                editingPreset = nil
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No PDF loaded")
                .font(.title2.weight(.semibold))
            Text(model.isConnected
                 ? "Open a PDF from the laptop interface. The app will download the original file automatically."
                 : "Connect to the Infinite Notes laptop server in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Button("Open Settings") { showingSettings = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(30)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(model.connectionLabel)
            if let filename = model.document.filename {
                Text("•")
                Text(filename).lineLimit(1)
            }
            Text("• Native 0.5.2 • Vector PDF • large-state sync")
                .foregroundStyle(.secondary)
            Spacer()
            if !model.mountedPageIndices.isEmpty {
                Text("Pages: \(model.mountedPageIndices.map { String($0 + 1) }.sorted().joined(separator: ", "))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )
    }
}

private enum PresetEditorKind {
    case color
    case penWidth
    case eraserWidth
}

private struct PresetEditorTarget: Identifiable {
    let id = UUID()
    let kind: PresetEditorKind
    let index: Int
}

private struct ColorPresetEditor: View {
    @State private var color: Color
    let onSave: (String) -> Void
    let onCancel: () -> Void

    init(initialHex: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _color = State(initialValue: Color(hex: initialHex))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit ink colour").font(.headline)
            ColorPicker("Colour", selection: $color, supportsOpacity: false)
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save") { onSave(color.noteHex ?? "#111111") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 300)
    }
}

private struct WidthPresetEditor: View {
    let title: String
    @State private var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    let onSave: (Double) -> Void
    let onCancel: () -> Void

    init(
        title: String,
        initialValue: Double,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String,
        onSave: @escaping (Double) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        _value = State(initialValue: initialValue)
        self.range = range
        self.step = step
        self.suffix = suffix
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text("\(value, specifier: "%.1f") \(suffix)")
                .font(.title3.monospacedDigit())
            Slider(value: $value, in: range, step: step)
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save") { onSave(value) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 320)
    }
}

private struct PenWidthPresetPreview: View {
    let value: Double
    let selected: Bool
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
            Capsule()
                .fill(color)
                .frame(width: 24, height: max(1.5, min(8, value * 0.9)))
        }
        .frame(width: 34, height: 28)
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.28), lineWidth: selected ? 1.5 : 1)
        }
    }
}

private struct EraserPresetPreview: View {
    let value: Double
    let selected: Bool

    var body: some View {
        let diameter = max(8, min(22, value * 0.34))
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
            Circle()
                .fill(Color.secondary.opacity(0.08))
                .overlay(Circle().stroke(Color.primary.opacity(0.75), lineWidth: 1.2))
                .frame(width: diameter, height: diameter)
        }
        .frame(width: 34, height: 28)
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.28), lineWidth: selected ? 1.5 : 1)
        }
    }
}

private struct LineStylePreview: View {
    let style: GeometryLineStyle

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 1, y: geometry.size.height / 2))
                path.addLine(to: CGPoint(x: geometry.size.width - 1, y: geometry.size.height / 2))
            }
            .stroke(
                Color.primary,
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashPattern)
            )
        }
    }

    private var dashPattern: [CGFloat] {
        switch style {
        case .solid: return []
        case .dashed: return [8, 5]
        case .dotted: return [1, 5]
        }
    }
}

private struct ToolButton: View {
    let tool: NoteTool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tool.symbolName)
                Text(tool.title).font(.caption2)
            }
            .frame(minWidth: 46)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.17) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
