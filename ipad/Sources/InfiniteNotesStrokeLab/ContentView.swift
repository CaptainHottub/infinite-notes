import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var navigator = PDFNavigator()
    @AppStorage("native.serverAddress") private var serverAddress = "http://10.42.0.1:8000"
    @State private var showingSettings = false
    @State private var didAutoConnect = false
    @State private var editingColorIndex: Int?
    @State private var showingToolSettings = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack(alignment: .trailing) {
                if model.pdfDocument != nil {
                    PDFKitNotebookView(model: model, navigator: navigator)
                } else {
                    emptyState
                }

                if model.appSettings.configuration.resolvedShowPipelineDiagnosticsSidebar {
                    PipelineDiagnosticsSidebar(
                        strokeSettings: model.strokeSettings,
                        appSettings: model.appSettings
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(20)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: model.appSettings.configuration.resolvedShowPipelineDiagnosticsSidebar)
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
        .sheet(isPresented: Binding(
            get: { model.exportedPDFURL != nil },
            set: { presented in if !presented { model.exportedPDFURL = nil } }
        )) {
            if let url = model.exportedPDFURL {
                ExportActivityView(url: url)
            }
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
                            showingToolSettings = false
                            editingColorIndex = nil
                            if tool != .selector { model.clearSelection() }
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

                    Menu {
                        Button(action: model.addPageBelowCurrent) {
                            Label("Add page below current", systemImage: "rectangle.badge.plus")
                        }
                        .disabled(!model.isConnected || model.currentPageNumber == 0)

                        Button(action: model.addPageAtEnd) {
                            Label("Add page at end", systemImage: "doc.badge.plus")
                        }
                        .disabled(!model.isConnected || model.pageCount == 0)

                        Divider()

                        Button(action: model.exportFlattenedPDF) {
                            Label("Export PDF", systemImage: "square.and.arrow.up")
                        }
                        .disabled(!model.isConnected || model.pageCount == 0)
                    } label: {
                        Image(systemName: "doc.badge.plus")
                    }
                    .accessibilityLabel("Page and export actions")

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
        .contentShape(Rectangle())
        // Consume taps in empty toolbar space instead of allowing them to be
        // interpreted by the document scroll view underneath.
        .onTapGesture { }
    }

    @ViewBuilder
    private var toolControls: some View {
        if model.selectedTool == .eraser {
            HStack(spacing: 5) {
                ForEach(model.eraserWidthPresets.indices, id: \.self) { index in
                    Button {
                        if model.activeEraserWidthPresetIndex == index {
                            showingToolSettings = true
                        } else {
                            model.selectEraserWidthPreset(index)
                        }
                    } label: {
                        EraserPresetPreview(
                            value: model.eraserWidthPresets[index],
                            selected: model.activeEraserWidthPresetIndex == index
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Eraser width preset \(index + 1), \(Int(model.eraserWidthPresets[index]))")
                }

                // Button {
                //     showingToolSettings = true
                // } label: {
                //     Image(systemName: "slider.horizontal.3")
                //         .frame(width: 28, height: 28)
                // }
                // .buttonStyle(.bordered)
                // .accessibilityLabel("Eraser settings")
            }
            .popover(
                isPresented: $showingToolSettings,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                EraserToolSettingsPopover(model: model)
            }
        } else if model.selectedTool != .selector {
            // Width presets come first. All detailed width, pressure and pattern
            // controls live in the popover anchored directly below this group.
            HStack(spacing: 5) {
                ForEach(model.penWidthPresets.indices, id: \.self) { index in
                    Button {
                        if model.activePenWidthPresetIndex == index {
                            showingToolSettings = true
                        } else {
                            model.selectPenWidthPreset(index)
                        }
                    } label: {
                        PenWidthPresetPreview(
                            value: model.penWidthPresets[index],
                            selected: model.activePenWidthPresetIndex == index,
                            color: Color(hex: model.inkColorHex)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Line width preset \(index + 1), \(model.penWidthPresets[index], specifier: "%.1f")")
                }
                // Setting button for Pen and highligter width
                // Button {
                //     showingToolSettings = false
                // } label: {
                //     Image(systemName: "slider.horizontal.3")
                //         .frame(width: 28, height: 28)
                // }
                // .buttonStyle(.bordered)
                // .accessibilityLabel("\(toolSettingsTitle) settings")
            }
            .popover(
                isPresented: $showingToolSettings,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                InkToolSettingsPopover(model: model, tool: model.selectedTool)
            }

            Divider().frame(height: 28)

            // Colours follow line settings. Selecting a colour applies it
            // immediately; opening its popover edits and auto-saves it.
            HStack(spacing: 5) {
                ForEach(model.inkColorPresets.indices, id: \.self) { index in
                    Button {
                        if !model.hasSelection, model.activeColorPresetIndex == index {
                            editingColorIndex = index
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
                        Button("Edit colour") { editingColorIndex = index }
                        if model.inkColorPresets.count > 1 {
                            Button("Remove colour", role: .destructive) {
                                model.removeColorPreset(index)
                                editingColorIndex = nil
                            }
                        }
                    }
                    .popover(
                        isPresented: colorEditorBinding(for: index),
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: .top
                    ) {
                        ColorPresetEditor(
                            initialHex: model.inkColorPresets[index],
                            canRemove: model.inkColorPresets.count > 1,
                            onChange: { model.updateColorPreset(index, hex: $0) },
                            onRemove: {
                                model.removeColorPreset(index)
                                editingColorIndex = nil
                            }
                        )
                    }
                    .accessibilityLabel("Ink colour preset \(index + 1)")
                }

                Button {
                    editingColorIndex = model.addColorPreset()
                } label: {
                    Image(systemName: "plus")
                        .font(.callout.weight(.semibold))
                        .frame(width: 24, height: 24)
                        .background(Color.secondary.opacity(0.08), in: Circle())
                        .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add ink colour")
            }
        }
    }

    private var toolSettingsTitle: String {
        switch model.selectedTool {
        case .pressurePen, .fixedPen: return "Pen"
        case .highlighter: return "Highlighter"
        case .shape: return "Geometry"
        case .eraser: return "Eraser"
        case .selector: return "Tool"
        }
    }

    private func colorEditorBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { editingColorIndex == index },
            set: { isPresented in
                if isPresented {
                    editingColorIndex = index
                } else if editingColorIndex == index {
                    editingColorIndex = nil
                }
            }
        )
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
            Text("• Native 0.5.3 • Vector PDF • stable ink hand-off")
                .foregroundStyle(.secondary)
            if model.appSettings.configuration.resolvedShowFPSInStatusBar {
                Text("• \(Int(model.displayFPS.rounded())) FPS")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            Spacer()
            if !model.mountedPageIndices.isEmpty {
                let sortedPages = model.mountedPageIndices.sorted()
                HStack(spacing: 0) {
                    Text("Pages: ")
                    ForEach(sortedPages.indices, id: \.self) { offset in
                        let index = sortedPages[offset]
                        Text("\(index + 1)")
                            .fontWeight(index + 1 == model.currentPageNumber ? .bold : .regular)
                        if offset < sortedPages.count - 1 {
                            Text(", ")
                        }
                    }
                }
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

private struct ColorPresetEditor: View {
    @State private var color: Color
    let canRemove: Bool
    let onChange: (String) -> Void
    let onRemove: () -> Void

    init(
        initialHex: String,
        canRemove: Bool,
        onChange: @escaping (String) -> Void,
        onRemove: @escaping () -> Void
    ) {
        _color = State(initialValue: Color(hex: initialHex))
        self.canRemove = canRemove
        self.onChange = onChange
        self.onRemove = onRemove
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ink colour").font(.headline)
            ColorPicker("Colour", selection: $color, supportsOpacity: false)
                .onChange(of: color) { newColor in
                    onChange(newColor.noteHex ?? "#111111")
                }

            Label("Changes save automatically", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            if canRemove {
                Divider()
                Button("Remove colour", role: .destructive, action: onRemove)
            }
        }
        .padding(18)
        .frame(width: 300)
    }
}

private struct InkToolSettingsPopover: View {
    @ObservedObject var model: AppModel
    let tool: NoteTool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Line width")
                    Spacer()
                    Text("\(model.inkWidth, specifier: "%.1f") pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: widthBinding, in: 0.1...30, step: 0.1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Saved widths")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach(model.penWidthPresets.indices, id: \.self) { index in
                        Button {
                            model.selectPenWidthPreset(index)
                        } label: {
                            VStack(spacing: 5) {
                                PenWidthPresetPreview(
                                    value: model.penWidthPresets[index],
                                    selected: model.activePenWidthPresetIndex == index,
                                    color: Color(hex: model.inkColorHex)
                                )
                                Text(model.penWidthPresets[index], format: .number.precision(.fractionLength(1)))
                                    .font(.caption2.monospacedDigit())
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Line pattern")
                    .font(.subheadline.weight(.semibold))
                Picker("Line pattern", selection: lineStyleBinding) {
                    ForEach(GeometryLineStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }

            if tool == .pressurePen || tool == .fixedPen {
                Toggle("Pressure-sensitive width", isOn: $model.penPressureEnabled)
            }

            Label("Changes save automatically", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 360)
    }

    private var title: String {
        switch tool {
        case .pressurePen, .fixedPen: return "Pen settings"
        case .highlighter: return "Highlighter settings"
        case .shape: return "Geometry line settings"
        case .eraser: return "Eraser settings"
        case .selector: return "Tool settings"
        }
    }

    private var widthBinding: Binding<Double> {
        Binding(
            get: { model.inkWidth },
            set: { model.updateActivePenWidth($0) }
        )
    }

    private var lineStyleBinding: Binding<GeometryLineStyle> {
        Binding(
            get: { model.activeLineStyle },
            set: { model.applyLineStyle($0) }
        )
    }
}

private struct EraserToolSettingsPopover: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Eraser settings").font(.headline)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Diameter")
                    Spacer()
                    Text("\(Int(model.eraserSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: diameterBinding, in: 8...120, step: 2)
            }

            HStack(spacing: 8) {
                ForEach(model.eraserWidthPresets.indices, id: \.self) { index in
                    Button {
                        model.selectEraserWidthPreset(index)
                    } label: {
                        VStack(spacing: 5) {
                            EraserPresetPreview(
                                value: model.eraserWidthPresets[index],
                                selected: model.activeEraserWidthPresetIndex == index
                            )
                            Text("\(Int(model.eraserWidthPresets[index]))")
                                .font(.caption2.monospacedDigit())
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Label("Changes save automatically", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 340)
    }

    private var diameterBinding: Binding<Double> {
        Binding(
            get: { model.eraserSize },
            set: { model.updateActiveEraserWidth($0) }
        )
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

private struct ExportActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
