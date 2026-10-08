import SwiftUI

private struct PageCheckbox: View {
    let title: String
    @Binding var value: Bool

    var body: some View {
        Button { value.toggle() } label: {
            HStack {
                Image(systemName: value ? "checkmark.square.fill" : "square")
                Text(title).foregroundStyle(.primary)
            }
        }
        .accessibilityValue(value ? "Checked" : "Unchecked")
    }
}

struct AddPageSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var belowCurrent = true
    @State private var source = "blank"
    @State private var selectedPresetID: String?
    @State private var settings = PageTemplateOption()
    @State private var useCurrentSize = true
    @State private var widthPt = 612.0
    @State private var heightPt = 792.0
    @State private var units = "in"
    @State private var pageFormat = "Current"
    @State private var showingSave = false
    @State private var savedName = ""
    @State private var saving = false

    private let formats: [(String, Double, Double)] = [
        ("Letter", 612, 792), ("Legal", 612, 1008), ("Tabloid", 792, 1224),
        ("A3", 841.8898, 1190.5512), ("A4", 595.2756, 841.8898), ("A5", 419.5276, 595.2756)
    ]
    private var pointsPerUnit: Double { units == "in" ? 72 : 72 / 25.4 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Position") {
                    PageCheckbox(title: "Insert below current page", value: $belowCurrent)
                    Text(belowCurrent ? "The new page follows the current page." : "The new page is added at the end.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Page source") {
                    sourceRow("Blank", selected: source == "blank") { selectBlank() }
                    sourceRow("Copy PDF page", selected: source == "copy") {
                        source = "copy"
                        selectedPresetID = nil
                        useCurrentSize = true
                        setCurrentDimensions()
                    }
                    Text("Saved Templates").font(.headline)
                    if model.pageTemplatesLoading { ProgressView("Loading…") }
                    ForEach(model.pageTemplatePresets) { preset in
                        sourceRow(preset.name, detail: sizeDescription(preset), selected: source == "template" && selectedPresetID == preset.id) {
                            source = "template"
                            selectedPresetID = preset.id
                            settings = preset
                            useCurrentSize = preset.pageWidthPt == nil
                            widthPt = preset.pageWidthPt ?? model.currentPageDimensions.width
                            heightPt = preset.pageHeightPt ?? model.currentPageDimensions.height
                            pageFormat = useCurrentSize ? "Current" : "Custom"
                        }
                    }
                    sourceRow("New Template", selected: source == "template" && selectedPresetID == nil) {
                        source = "template"
                        selectedPresetID = nil
                        settings.id = "new-template"
                        settings.name = "New Template"
                    }
                    if let error = model.pageTemplateError { Text(error).foregroundStyle(.red) }
                    Button("Refresh templates") { model.loadPageTemplates() }
                }
                Section("Template settings") {
                    HStack { Text("Title"); TextField("Page title", text: edit(\.title)) }
                    pageSizeEditor
                    ColorPicker("Background color", selection: color(\.background), supportsOpacity: false)
                    PageCheckbox(title: "Minor lines", value: edit(\.minorLinesEnabled))
                    if settings.minorLinesEnabled {
                        number("Minor spacing (mm)", value: millimetres(\.minorSpacingCm))
                        ColorPicker("Minor line color", selection: color(\.minorColor), supportsOpacity: false)
                        number("Minor line width (mm)", value: edit(\.minorWidthMm))
                    }
                    PageCheckbox(title: "Major lines", value: edit(\.majorLinesEnabled))
                    if settings.majorLinesEnabled {
                        number("Major spacing (mm)", value: millimetres(\.majorSpacingCm))
                        ColorPicker("Major line color", selection: color(\.majorColor), supportsOpacity: false)
                        number("Major line width (mm)", value: edit(\.majorWidthMm))
                    }
                    PageCheckbox(title: "Dots", value: edit(\.dotsEnabled))
                    if settings.dotsEnabled {
                        number("Dot spacing (mm)", value: millimetres(\.dotSpacingCm))
                        ColorPicker("Dot color", selection: color(\.dotColor), supportsOpacity: false)
                        number("Dot radius (mm)", value: edit(\.dotRadiusMm))
                    }
                    number("Margin (mm)", value: millimetres(\.marginCm))
                    PageCheckbox(title: "Date", value: edit(\.date))
                    if !settings.title.isEmpty || settings.date {
                        number("Header height (mm)", value: millimetres(\.headerCm))
                    }
                    Button(saving ? "Saving…" : "Save template…") {
                        savedName = selectedPresetID == nil ? settings.title : settings.name
                        showingSave = true
                    }
                    .disabled(saving)
                }
                .disabled(source == "copy")
            }
            .navigationTitle("Add page")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") {
                        var template = settings
                        if (!template.title.isEmpty || template.date) && template.headerCm == 0 { template.headerCm = 1.2 }
                        let options = PageInsertionOptions(useCurrentSize: useCurrentSize, pageWidthPt: widthPt,
                                                           pageHeightPt: heightPt, template: source == "template" ? template : nil)
                        model.addPage(kind: source, belowCurrent: belowCurrent, presetID: selectedPresetID, options: options)
                        dismiss()
                    }
                    .disabled(!model.isConnected || widthPt < 20 || heightPt < 20 || widthPt > 20000 || heightPt > 20000)
                }
            }
            .alert("Save template", isPresented: $showingSave) {
                TextField("Template name", text: $savedName)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    var preset = settings
                    preset.id = UUID().uuidString.lowercased()
                    preset.name = savedName
                    preset.pageWidthPt = useCurrentSize ? nil : widthPt
                    preset.pageHeightPt = useCurrentSize ? nil : heightPt
                    if (!preset.title.isEmpty || preset.date) && preset.headerCm == 0 { preset.headerCm = 1.2 }
                    saving = true
                    Task {
                        if await model.savePageTemplate(preset) {
                            settings = preset
                            source = "template"
                            selectedPresetID = preset.id
                        }
                        saving = false
                    }
                }
                .disabled(savedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { selectBlank(); model.loadPageTemplates() }
    }

    private var pageSizeEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Page size").font(.headline)
                Spacer()
                Picker("Units", selection: $units) { Text("in").tag("in"); Text("mm").tag("mm") }
                    .pickerStyle(.segmented).frame(width: 130)
            }
            HStack {
                PageCheckbox(title: "Current", value: Binding(get: { useCurrentSize }, set: { value in
                    useCurrentSize = value
                    if value { setCurrentDimensions() }
                    pageFormat = value ? "Current" : "Custom"
                    makeCustom()
                }))
                number("Width", value: dimension(width: true))
                number("Height", value: dimension(width: false))
                Menu(pageFormat) {
                    ForEach(formats, id: \.0) { format in
                        Button(format.0) {
                            widthPt = format.1
                            heightPt = format.2
                            useCurrentSize = false
                            pageFormat = format.0
                            makeCustom()
                        }
                    }
                }
            }
        }
    }

    private func number(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...3)))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        }
    }

    private func sourceRow(_ title: String, detail: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func sizeDescription(_ preset: PageTemplateOption) -> String {
        let width = preset.pageWidthPt ?? model.currentPageDimensions.width
        let height = preset.pageHeightPt ?? model.currentPageDimensions.height
        return String(format: "%.2f × %.2f %@", width / pointsPerUnit, height / pointsPerUnit, units)
    }

    private func setCurrentDimensions() {
        widthPt = model.currentPageDimensions.width
        heightPt = model.currentPageDimensions.height
    }

    private func selectBlank() {
        source = "blank"
        selectedPresetID = nil
        settings = PageTemplateOption()
        settings.minorLinesEnabled = false
        settings.majorLinesEnabled = false
        settings.dotsEnabled = false
        useCurrentSize = true
        pageFormat = "Current"
        setCurrentDimensions()
    }

    private func makeCustom() {
        if source != "blank" { source = "template" }
        selectedPresetID = nil
        settings.id = "new-template"
        settings.name = "New Template"
    }

    private func edit<T>(_ key: WritableKeyPath<PageTemplateOption, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: key] }, set: { value in
            settings[keyPath: key] = value
            if (!settings.title.isEmpty || settings.date) && settings.headerCm == 0 { settings.headerCm = 1.2 }
            source = "template"
            makeCustom()
        })
    }

    private func millimetres(_ key: WritableKeyPath<PageTemplateOption, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: key] * 10 }, set: { edit(key).wrappedValue = $0 / 10 })
    }

    private func color(_ key: WritableKeyPath<PageTemplateOption, String>) -> Binding<Color> {
        Binding(get: { Color(hex: settings[keyPath: key]) }, set: { edit(key).wrappedValue = $0.noteHex ?? "#ffffff" })
    }

    private func dimension(width: Bool) -> Binding<Double> {
        Binding(get: { (width ? widthPt : heightPt) / pointsPerUnit }, set: { value in
            if width { widthPt = value * pointsPerUnit } else { heightPt = value * pointsPerUnit }
            useCurrentSize = false
            pageFormat = "Custom"
            makeCustom()
        })
    }
}
