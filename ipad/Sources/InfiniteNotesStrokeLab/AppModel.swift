import Combine
import Foundation
import PDFKit
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var connectionStatus: ServerClient.Status = .disconnected
    @Published private(set) var document: DocumentInfo = .empty
    @Published private(set) var pdfDocument: PDFDocument?
    @Published private(set) var pdfFileURL: URL?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var currentPageNumber = 0
    @Published private(set) var mountedPageIndices: Set<Int> = []
    @Published var lastError: String?
    @Published var notice: String?
    @Published private(set) var selectedStrokeIDs: Set<String> = []
    @Published private(set) var clipboardCount = 0
    @Published var snapGuide: GeometrySnapResult?
    @Published private(set) var settingsRevision = 0
    @Published private(set) var workspaceRevision = 0
    @Published var exportedPDFURL: URL?
    @Published private(set) var displayFPS = 0.0

    @Published var selectedTool: NoteTool {
        didSet { UserDefaults.standard.set(selectedTool.rawValue, forKey: "native.selectedTool") }
    }
    @Published var inkColorHex: String {
        didSet { UserDefaults.standard.set(inkColorHex, forKey: "native.inkColorHex") }
    }
    @Published var inkWidth: Double {
        didSet { UserDefaults.standard.set(inkWidth, forKey: "native.inkWidth") }
    }
    @Published var eraserSize: Double {
        didSet { UserDefaults.standard.set(eraserSize, forKey: "native.eraserSize") }
    }
    @Published var selectedShapeType: GeometryShapeType {
        didSet { UserDefaults.standard.set(selectedShapeType.rawValue, forKey: "native.selectedShapeType") }
    }
    @Published var penPressureEnabled: Bool {
        didSet { UserDefaults.standard.set(penPressureEnabled, forKey: "native.penPressureEnabled") }
    }
    @Published var inkLineStyle: GeometryLineStyle {
        didSet { UserDefaults.standard.set(inkLineStyle.rawValue, forKey: "native.inkLineStyle") }
    }
    @Published var inkColorPresets: [String] {
        didSet { UserDefaults.standard.set(inkColorPresets, forKey: "native.inkColorPresets") }
    }
    @Published var activeColorPresetIndex: Int {
        didSet { UserDefaults.standard.set(activeColorPresetIndex, forKey: "native.activeColorPresetIndex") }
    }
    @Published var penWidthPresets: [Double] {
        didSet { UserDefaults.standard.set(penWidthPresets, forKey: "native.penWidthPresets") }
    }
    @Published var activePenWidthPresetIndex: Int {
        didSet { UserDefaults.standard.set(activePenWidthPresetIndex, forKey: "native.activePenWidthPresetIndex") }
    }
    @Published var eraserWidthPresets: [Double] {
        didSet { UserDefaults.standard.set(eraserWidthPresets, forKey: "native.eraserWidthPresets") }
    }
    @Published var activeEraserWidthPresetIndex: Int {
        didSet { UserDefaults.standard.set(activeEraserWidthPresetIndex, forKey: "native.activeEraserWidthPresetIndex") }
    }

    let clientID: String
    let strokeSettings: StrokeSettingsStore
    let appSettings: AppSettingsStore

    private let client = ServerClient()
    private var baseURL: URL?
    private var shouldReconnect = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var stateFetchTask: URLSessionDataTask?
    private var stateFetchGeneration = 0
    private var strokes: [String: NoteStroke] = [:]
    private var pageStrokeIDs: [Int: Set<String>] = [:]
    private var strokeMembership: [String: Set<Int>] = [:]
    private var pageWorkspaceStates: [Int: PageWorkspaceState] = [:]
    private var liveStrokeIDs: Set<String> = []
    private var selectionClipboard: [NoteStroke] = []
    private var selectionPasteSerial = 0

    private var pendingPointBatches: [String: [NotePoint]] = [:]
    private var pointFlushWorkItem: DispatchWorkItem?
    private var weakPageViews: [Int: [WeakPageView]] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let defaults = UserDefaults.standard
        strokeSettings = StrokeSettingsStore()
        appSettings = AppSettingsStore()
        if let savedID = defaults.string(forKey: "native.clientID") {
            clientID = savedID
        } else {
            let newID = "native-\(UUID().uuidString.lowercased())"
            defaults.set(newID, forKey: "native.clientID")
            clientID = newID
        }

        let savedTool = NoteTool(rawValue: defaults.string(forKey: "native.selectedTool") ?? "pen") ?? .pressurePen
        let initialInkColorHex = defaults.string(forKey: "native.inkColorHex") ?? "#111111"
        let initialInkWidth = max(0.1, min(30, defaults.object(forKey: "native.inkWidth") as? Double ?? 3.0))
        let initialEraserSize = defaults.object(forKey: "native.eraserSize") as? Double ?? 30.0

        selectedTool = savedTool == .fixedPen ? .pressurePen : savedTool
        inkColorHex = initialInkColorHex
        inkWidth = initialInkWidth
        eraserSize = initialEraserSize
        selectedShapeType = GeometryShapeType(rawValue: defaults.string(forKey: "native.selectedShapeType") ?? "line") ?? .line
        penPressureEnabled = defaults.object(forKey: "native.penPressureEnabled") as? Bool ?? true
        inkLineStyle = GeometryLineStyle(rawValue: defaults.string(forKey: "native.inkLineStyle") ?? "solid") ?? .solid
        let savedColorPresets = Self.loadStringPresets(
            defaults.array(forKey: "native.inkColorPresets") as? [String],
            fallback: ["#111111", "#2457D6", "#D52B2B", "#16834A", "#E2871B"]
        )
        inkColorPresets = savedColorPresets
        activeColorPresetIndex = max(
            0,
            min(savedColorPresets.count - 1, defaults.object(forKey: "native.activeColorPresetIndex") as? Int ?? 0)
        )

        let savedPenWidths = Self.loadWidthPresets(
            defaults.array(forKey: "native.penWidthPresets") as? [Double],
            fallback: [1.5, 3.0, 6.0],
            range: 0.1...30
        )
        penWidthPresets = savedPenWidths

        let storedPenPresetIndex =
            defaults.object(forKey: "native.activePenWidthPresetIndex") as? Int

        let fallbackPenPresetIndex = Self.nearestPresetIndex(
            to: initialInkWidth,
            in: savedPenWidths
        )

        activePenWidthPresetIndex = max(
            0,
            min(
                savedPenWidths.count - 1,
                storedPenPresetIndex ?? fallbackPenPresetIndex
            )
        )

        let savedEraserWidths = Self.loadWidthPresets(
            defaults.array(forKey: "native.eraserWidthPresets") as? [Double],
            fallback: [18, 32, 56],
            range: 8...120
        )
        eraserWidthPresets = savedEraserWidths

        let storedEraserPresetIndex =
            defaults.object(forKey: "native.activeEraserWidthPresetIndex") as? Int

        let fallbackEraserPresetIndex = Self.nearestPresetIndex(
            to: initialEraserSize,
            in: savedEraserWidths
        )

        activeEraserWidthPresetIndex = max(
            0,
            min(
                savedEraserWidths.count - 1,
                storedEraserPresetIndex ?? fallbackEraserPresetIndex
            )
        )

        strokeSettings.$configuration
            .dropFirst()
            .sink { [weak self] _ in
                self?.invalidateAllPages()
            }
            .store(in: &cancellables)

        appSettings.$configuration
            .dropFirst()
            .sink { [weak self] _ in
                self?.settingsRevision &+= 1
                self?.invalidateAllPages()
            }
            .store(in: &cancellables)

        client.onStatus = { [weak self] status in
            guard let self else { return }
            self.connectionStatus = status
            switch status {
            case .connected:
                self.lastError = nil
                self.reconnectWorkItem?.cancel()
                self.reconnectWorkItem = nil
            case .disconnected, .failed:
                if self.shouldReconnect { self.scheduleReconnect() }
            case .connecting:
                break
            }
        }
        client.onTextMessage = { [weak self] text in
            self?.handleServerText(text)
        }
    }

    var isConnected: Bool {
        if case .connected = connectionStatus { return true }
        return false
    }

    var pageCount: Int { document.pages.count }

    var connectionLabel: String { connectionStatus.label }
    var selectionCount: Int { selectedStrokeIDs.count }
    var hasSelection: Bool { !selectedStrokeIDs.isEmpty }
    var canPaste: Bool { !selectionClipboard.isEmpty }
    var selectedStrokes: [NoteStroke] { selectedStrokeIDs.compactMap { strokes[$0] } }
    var selectionAllLocked: Bool { !selectedStrokeIDs.isEmpty && selectedStrokes.allSatisfy(\.isLocked) }
    var selectionSummary: String {
        if selectedStrokeIDs.count == 1, let stroke = selectedStrokes.first {
            let name = GeometryEngine.isGeometry(stroke) ? GeometryEngine.displayName(stroke) : (stroke.isInk ? "Ink" : "Item")
            return stroke.isLocked ? "\(name) · locked" : name
        }
        return selectedStrokeIDs.isEmpty ? "Lasso items to select" : "\(selectedStrokeIDs.count) selected"
    }

    var activeLineStyle: GeometryLineStyle {
        selectedTool == .shape ? appSettings.configuration.geometryLineStyle : inkLineStyle
    }

    func selectColorPreset(_ index: Int) {
        guard inkColorPresets.indices.contains(index) else { return }
        activeColorPresetIndex = index
        applyInkColor(inkColorPresets[index])
    }

    func updateColorPreset(_ index: Int, hex: String) {
        guard inkColorPresets.indices.contains(index) else { return }
        var updated = inkColorPresets
        updated[index] = Self.normalizedHex(hex)
        inkColorPresets = updated
        activeColorPresetIndex = index
        applyInkColor(updated[index])
    }

    @discardableResult
    func addColorPreset() -> Int {
        let suggestedColors = ["#7B2CBF", "#00A6A6", "#E83E8C", "#6B7280", "#8B5CF6", "#14B8A6"]
        let newHex = suggestedColors.first { !inkColorPresets.contains($0) } ?? inkColorHex
        var updated = inkColorPresets
        updated.append(newHex)
        inkColorPresets = updated
        activeColorPresetIndex = updated.count - 1
        applyInkColor(newHex)
        return activeColorPresetIndex
    }

    func removeColorPreset(_ index: Int) {
        guard inkColorPresets.count > 1, inkColorPresets.indices.contains(index) else { return }
        let previousActive = activeColorPresetIndex
        var updated = inkColorPresets
        updated.remove(at: index)
        inkColorPresets = updated

        let nextActive: Int
        if previousActive > index {
            nextActive = previousActive - 1
        } else if previousActive == index {
            nextActive = min(index, updated.count - 1)
        } else {
            nextActive = previousActive
        }
        activeColorPresetIndex = max(0, min(updated.count - 1, nextActive))
        applyInkColor(updated[activeColorPresetIndex])
    }

    func applyInkColor(_ hex: String) {
        let normalized = Self.normalizedHex(hex)
        inkColorHex = normalized
        applyAppearanceToSelection { stroke in
            var changed = stroke
            changed.color = normalized
            return changed
        }
    }

    func selectPenWidthPreset(_ index: Int) {
        guard penWidthPresets.indices.contains(index) else { return }
        activePenWidthPresetIndex = index
        applyInkWidth(penWidthPresets[index])
    }

    func updatePenWidthPreset(_ index: Int, value: Double) {
        guard penWidthPresets.indices.contains(index) else { return }
        var updated = penWidthPresets
        updated[index] = max(0.1, min(30, value))
        penWidthPresets = updated
        activePenWidthPresetIndex = index
        applyInkWidth(updated[index])
    }

    func updateActivePenWidth(_ value: Double) {
        updatePenWidthPreset(activePenWidthPresetIndex, value: value)
    }

    func selectEraserWidthPreset(_ index: Int) {
        guard eraserWidthPresets.indices.contains(index) else { return }
        activeEraserWidthPresetIndex = index
        eraserSize = eraserWidthPresets[index]
    }

    func updateEraserWidthPreset(_ index: Int, value: Double) {
        guard eraserWidthPresets.indices.contains(index) else { return }
        var updated = eraserWidthPresets
        updated[index] = max(8, min(120, value))
        eraserWidthPresets = updated
        activeEraserWidthPresetIndex = index
        eraserSize = updated[index]
    }

    func updateActiveEraserWidth(_ value: Double) {
        updateEraserWidthPreset(activeEraserWidthPresetIndex, value: value)
    }

    func applyInkWidth(_ width: Double) {
        inkWidth = max(0.1, min(30, width))
        applyCurrentWidthToSelection()
    }

    func applyCurrentWidthToSelection() {
        let width = max(0.1, min(100, inkWidth))
        applyAppearanceToSelection { stroke in
            guard stroke.isInk || GeometryEngine.isGeometry(stroke) else { return stroke }
            var changed = stroke
            changed.width = width
            return changed
        }
    }

    func applyLineStyle(_ style: GeometryLineStyle) {
        inkLineStyle = style
        appSettings.configuration.geometryLineStyle = style
        applyAppearanceToSelection { stroke in
            guard stroke.isInk || GeometryEngine.isGeometry(stroke) else { return stroke }
            var changed = stroke
            changed.lineStyle = style.rawValue
            return changed
        }
    }

    private func applyAppearanceToSelection(_ transform: (NoteStroke) -> NoteStroke) {
        guard hasSelection, isConnected else { return }
        let originals = selectedStrokes
        let replacements = originals.map(transform)
        guard replacements != originals else { return }
        previewReplaceStrokes(replacements)
        if !sendReplacementStrokes(replacements) {
            restorePreviewStrokes(originals)
        }
    }

    func connect(address: String) {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        stateFetchTask?.cancel()
        stateFetchTask = nil
        stateFetchGeneration &+= 1
        guard let normalized = Self.normalizedBaseURL(address) else {
            lastError = "Enter a server address such as http://10.42.0.1:8000"
            return
        }
        baseURL = normalized
        shouldReconnect = true
        client.connect(baseURL: normalized, clientID: clientID)
    }

    func disconnect() {
        shouldReconnect = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        stateFetchTask?.cancel()
        stateFetchTask = nil
        stateFetchGeneration &+= 1
        client.disconnect()
    }

    func syncNow() {
        guard isConnected else {
            lastError = "Connect to the computer before synchronizing"
            return
        }
        notice = "Synchronizing notebook…"
        fetchNotebookState(reason: "manual_sync")
    }

    func addPageAtEnd() {
        performPageMutation(path: "/api/pages/append", queryItems: [], pendingNotice: "Adding a page…")
    }

    func addPageBelowCurrent() {
        guard currentPageNumber > 0 else {
            lastError = "Open a page before inserting below it"
            return
        }
        performPageMutation(
            path: "/api/pages/insert",
            queryItems: [URLQueryItem(name: "afterPageNumber", value: String(currentPageNumber))],
            pendingNotice: "Inserting a page…"
        )
    }

    func exportFlattenedPDF() {
        guard let url = endpoint(
            path: "/api/pdf/export",
            queryItems: [
                URLQueryItem(name: "overflowMargin", value: "20"),
                URLQueryItem(name: "outerGridStyle", value: appSettings.configuration.resolvedOffPageGridStyle.rawValue),
                URLQueryItem(name: "outerGridSpacing", value: String(appSettings.configuration.resolvedOffPageGridSpacing)),
            ]
        ) else {
            lastError = "The computer server address is invalid"
            return
        }
        notice = "Preparing PDF export…"
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 180
        URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.lastError = "PDF export failed: \(error.localizedDescription)" }
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let temporaryURL else {
                Task { @MainActor in self.lastError = "The computer could not export the PDF" }
                return
            }
            do {
                let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("InfiniteNotesNative/Exports", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let destination = root.appendingPathComponent("notes-\(UUID().uuidString).pdf")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: temporaryURL, to: destination)
                Task { @MainActor in
                    self.exportedPDFURL = destination
                    self.notice = "PDF export ready"
                    self.lastError = nil
                }
            } catch {
                Task { @MainActor in self.lastError = "Could not save the exported PDF: \(error.localizedDescription)" }
            }
        }.resume()
    }

    func undo() {
        guard canUndo else { return }
        client.sendJSONObject(["type": "undo"])
    }

    func redo() {
        guard canRedo else { return }
        client.sendJSONObject(["type": "redo"])
    }


    func stroke(withID id: String) -> NoteStroke? {
        strokes[id]
    }

    func selectedStrokesForPage(_ pageIndex: Int) -> [NoteStroke] {
        selectedStrokeIDs.compactMap { id in
            guard strokeMembership[id]?.contains(pageIndex) == true else { return nil }
            return strokes[id]
        }
    }

    func setSelection(_ ids: Set<String>) {
        selectedStrokeIDs = Set(ids.filter { strokes[$0] != nil })
        snapGuide = nil
        invalidateAllPages(committedChange: false)
    }

    func clearSelection() {
        guard !selectedStrokeIDs.isEmpty || snapGuide != nil else { return }
        selectedStrokeIDs.removeAll()
        snapGuide = nil
        invalidateAllPages(committedChange: false)
    }

    func selectByLasso(pageIndex: Int, polygon: [CGPoint], additive: Bool = false) {
        var result = additive ? selectedStrokeIDs : []
        for stroke in strokesForPage(pageIndex) where GeometryEngine.selectedByLasso(stroke, polygon: polygon) {
            result.insert(stroke.id)
        }
        setSelection(result)
    }

    func directHitStroke(pageIndex: Int, worldPoint: CGPoint, threshold: CGFloat, includeLocked: Bool = false) -> String? {
        var bestID: String?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        // Reverse the stable draw order so visually topmost items win.
        for stroke in strokesForPage(pageIndex).reversed() {
            if stroke.isLocked && !includeLocked { continue }
            guard let distance = GeometryEngine.hitTest(stroke, point: worldPoint, threshold: threshold) else { continue }
            if distance < bestDistance {
                bestDistance = distance
                bestID = stroke.id
            }
        }
        return bestID
    }

    func directHitGeometry(pageIndex: Int, worldPoint: CGPoint, threshold: CGFloat, includeLocked: Bool = false) -> String? {
        var bestID: String?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for stroke in strokesForPage(pageIndex).reversed() where GeometryEngine.isGeometry(stroke) {
            if stroke.isLocked && !includeLocked { continue }
            guard let distance = GeometryEngine.hitTest(stroke, point: worldPoint, threshold: threshold) else { continue }
            if distance < bestDistance {
                bestDistance = distance
                bestID = stroke.id
            }
        }
        return bestID
    }

    func selectionWorldBounds(pageIndex: Int) -> CGRect? {
        GeometryEngine.selectionBounds(selectedStrokesForPage(pageIndex))
    }

    func copySelection() {
        selectionClipboard = selectedStrokes
        selectionPasteSerial = 0
        clipboardCount = selectionClipboard.count
        notice = selectionClipboard.isEmpty ? nil : "Copied \(selectionClipboard.count) item\(selectionClipboard.count == 1 ? "" : "s")"
    }

    func pasteSelection() {
        guard isConnected, !selectionClipboard.isEmpty else {
            notice = "Paste requires a server connection"
            return
        }
        selectionPasteSerial += 1
        let offset = CGFloat(appSettings.configuration.pasteOffset * Double(selectionPasteSerial))
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let pasted = selectionClipboard.enumerated().map { index, source -> NoteStroke in
            let page = source.pageIndex.flatMap { pageInfo(at: $0) }
            var result = GeometryEngine.translated(source, dx: offset, dy: offset, page: page)
            result.id = "\(clientID)-copy-\(stamp)-\(index)-\(UUID().uuidString.prefix(8).lowercased())"
            result.owner = clientID
            return result
        }
        guard addStrokes(pasted) else { return }
        setSelection(Set(pasted.map(\.id)))
        notice = "Pasted \(pasted.count) item\(pasted.count == 1 ? "" : "s")"
    }

    func deleteSelection() {
        let ids = Array(selectedStrokeIDs)
        guard !ids.isEmpty, isConnected else { return }
        for id in ids { removeStroke(id: id) }
        selectedStrokeIDs.removeAll()
        client.sendJSONObject(["type": "delete_strokes", "ids": ids])
        invalidateAllPages()
    }

    func toggleSelectionLock() {
        let current = selectedStrokes
        guard !current.isEmpty, isConnected else { return }
        let lock = !current.allSatisfy(\.isLocked)
        let replacements = current.map { stroke -> NoteStroke in
            var result = stroke
            result.locked = lock
            return result
        }
        previewReplaceStrokes(replacements)
        if sendReplacementStrokes(replacements) {
            notice = "\(replacements.count == 1 ? "Item" : "Items") \(lock ? "locked" : "unlocked")"
        }
    }

    @discardableResult
    func recognizeActiveInk(strokeID: String, pageIndex: Int) -> Bool {
        guard let page = pageInfo(at: pageIndex), var stroke = strokes[strokeID],
              stroke.isInk, stroke.points.count >= 4 else { return false }
        let settings = appSettings.configuration
        guard settings.holdRecognitionEnabled else { return false }
        let raw = stroke.points.map { CGPoint(x: $0.xRaw, y: $0.yRaw) }
        guard let first = raw.first, let last = raw.last,
              hypot(last.x - first.x, last.y - first.y) >= 24 else { return false }

        let lineError = GeometryEngine.lineFitError(raw)
        if lineError <= settings.lineRecognitionTolerance {
            let snapped = snapGeometryPoint(last, pageIndex: pageIndex, excluding: strokeID, otherPoint: first)
            stroke.recognitionSource = stroke.tool
            stroke.tool = "shape"
            stroke.shapeType = GeometryShapeType.line.rawValue
            stroke.points = [GeometryEngine.makePoint(first, page: page), GeometryEngine.makePoint(snapped.point, page: page)]
            stroke.recognitionError = lineError
            stroke.snapKind = snapped.kind
        } else if let fit = GeometryEngine.quadraticFit(stroke.points, page: page),
                  fit.error <= settings.curveRecognitionTolerance {
            stroke.recognitionSource = stroke.tool
            stroke.tool = "shape"
            stroke.shapeType = GeometryShapeType.curve.rawValue
            stroke.points = fit.points
            stroke.recognitionError = fit.error
            stroke.snapKind = nil
        } else {
            notice = String(format: "Geometry rejected · %.1f%% line error", lineError)
            return false
        }

        liveStrokeIDs.insert(strokeID)
        insertOrReplace(stroke, committedChange: false)
        notice = String(format: "%@ recognized · %.1f%%", GeometryEngine.displayName(stroke), stroke.recognitionError ?? 0)
        return true
    }

    func updateRecognizedGeometry(strokeID: String, pageIndex: Int, endPoint: CGPoint) {
        guard let page = pageInfo(at: pageIndex), var stroke = strokes[strokeID],
              stroke.tool == "shape", stroke.recognitionSource != nil else { return }
        switch stroke.shapeType {
        case GeometryShapeType.line.rawValue:
            guard let start = stroke.points.first?.cgPoint else { return }
            let snapped = snapGeometryPoint(endPoint, pageIndex: pageIndex, excluding: strokeID, otherPoint: start)
            if stroke.points.count >= 2 {
                stroke.points[1] = GeometryEngine.replacingPoint(stroke.points[1], with: snapped.point, page: page)
            }
            stroke.snapKind = snapped.kind
        case GeometryShapeType.curve.rawValue:
            guard stroke.points.count >= 3 else { return }
            stroke.points[2] = GeometryEngine.replacingPoint(stroke.points[2], with: endPoint, page: page)
        default:
            return
        }
        insertOrReplace(stroke, committedChange: false)
    }

    func makeGeometryStroke(type: GeometryShapeType, pageIndex: Int, start: CGPoint, end: CGPoint) -> NoteStroke? {
        guard let page = pageInfo(at: pageIndex) else { return nil }
        let points = GeometryEngine.makeShapePoints(type: type, start: start, end: end, page: page)
        return NoteStroke(
            id: "\(clientID)-shape-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8).lowercased())",
            tool: "shape",
            color: inkColorHex,
            width: max(0.1, min(100, inkWidth)),
            opacity: 1,
            smoothing: 0,
            strokeDetail: 100,
            lineStyle: appSettings.configuration.geometryLineStyle.rawValue,
            points: points,
            owner: clientID,
            locked: type == .xyPlane ? appSettings.configuration.lockNewXYPlanes : false,
            pageIndex: pageIndex,
            pipeline: nil,
            shapeType: type.rawValue,
            gridColor: "#7a7f89",
            recognitionSource: nil,
            recognitionError: nil,
            snapKind: nil,
            text: nil,
            textAlign: nil,
            fontFamily: nil
        )
    }

    func insertXYPlane(pageIndex: Int? = nil) {
        let index = pageIndex ?? max(0, currentPageNumber - 1)
        guard let page = sourcePageInfo(at: index) else { return }
        let settings = appSettings.configuration
        let width = min(page.width * settings.xyPlaneWidthFraction, 520)
        let height = min(page.height * settings.xyPlaneHeightFraction, 420)
        let center = CGPoint(x: CGFloat(page.x + page.width / 2), y: CGFloat(page.y + page.height / 2))
        let start = CGPoint(x: center.x - CGFloat(width / 2), y: center.y - CGFloat(height / 2))
        let end = CGPoint(x: center.x + CGFloat(width / 2), y: center.y + CGFloat(height / 2))
        guard let plane = makeGeometryStroke(type: .xyPlane, pageIndex: index, start: start, end: end),
              addStrokes([plane]) else { return }
        selectedTool = .selector
        setSelection([plane.id])
        notice = "X–Y plane added\(plane.isLocked ? " and locked" : "")"
    }

    @discardableResult
    func addStrokes(_ newStrokes: [NoteStroke]) -> Bool {
        guard isConnected, !newStrokes.isEmpty else {
            notice = "Adding items requires a server connection"
            return false
        }
        for stroke in newStrokes { insertOrReplace(stroke) }
        do {
            let objects = try JSONHelpers.object(from: newStrokes)
            client.sendJSONObject(["type": "add_strokes", "strokes": objects])
            return true
        } catch {
            for stroke in newStrokes { removeStroke(id: stroke.id) }
            lastError = "Could not encode geometry"
            return false
        }
    }

    func previewReplaceStrokes(_ replacements: [NoteStroke]) {
        for stroke in replacements { insertOrReplace(stroke, committedChange: false) }
    }

    func restorePreviewStrokes(_ originals: [NoteStroke]) {
        for stroke in originals { insertOrReplace(stroke, committedChange: false) }
    }

    @discardableResult
    func sendReplacementStrokes(_ replacements: [NoteStroke]) -> Bool {
        guard isConnected, !replacements.isEmpty else { return false }
        do {
            let objects = try JSONHelpers.object(from: replacements)
            client.sendJSONObject(["type": "replace_strokes", "strokes": objects])
            for stroke in replacements { insertOrReplace(stroke) }
            return true
        } catch {
            lastError = "Could not encode the selection change"
            return false
        }
    }

    func snapGeometryPoint(
        _ point: CGPoint,
        pageIndex: Int,
        excluding strokeID: String? = nil,
        otherPoint: CGPoint? = nil
    ) -> GeometrySnapResult {
        let settings = appSettings.configuration
        let limit = CGFloat(settings.geometrySnapDistance)
        var result = point
        var kind: String?

        if let otherPoint, settings.tangentSnap || settings.normalSnap,
           let ellipse = nearestEllipseSnap(
               pointer: point,
               otherPoint: otherPoint,
               pageIndex: pageIndex,
               excluding: strokeID,
               settings: settings
           ) {
            result = ellipse.point
            kind = ellipse.kind
        }

        if kind == nil, settings.endpointSnap {
            var bestDistance = limit
            for stroke in strokesForPage(pageIndex) where stroke.id != strokeID && GeometryEngine.isGeometry(stroke) {
                for candidate in GeometryEngine.endpoints(of: stroke) {
                    let distance = hypot(candidate.x - result.x, candidate.y - result.y)
                    if distance < bestDistance {
                        bestDistance = distance
                        result = candidate
                        kind = "endpoint"
                    }
                }
            }
        }

        if kind == nil, settings.axisSnap, let otherPoint {
            let dx = abs(result.x - otherPoint.x)
            let dy = abs(result.y - otherPoint.y)
            if dx <= limit {
                result.x = otherPoint.x
                kind = "vertical"
            }
            if dy <= limit {
                result.y = otherPoint.y
                kind = "horizontal"
            }
        }

        if kind == nil, settings.axisSnap {
            for stroke in strokesForPage(pageIndex) where stroke.id != strokeID && stroke.shapeType == "xy-plane" {
                guard let box = GeometryEngine.shapeBox(stroke) else { continue }
                let local = box.worldToLocal(result)
                guard local.x >= -limit, local.y >= -limit,
                      local.x <= box.width + limit, local.y <= box.height + limit else { continue }
                if abs(local.y - box.height / 2) <= limit {
                    result = box.localToWorld(x: max(0, min(box.width, local.x)), y: box.height / 2)
                    kind = "x-axis"
                }
                if abs(local.x - box.width / 2) <= limit {
                    result = box.localToWorld(x: box.width / 2, y: max(0, min(box.height, local.y)))
                    kind = "y-axis"
                }
            }
        }

        let snap = GeometrySnapResult(point: result, kind: kind, from: otherPoint)
        snapGuide = settings.showSnapGuides && kind != nil ? snap : nil
        invalidatePages([pageIndex], committedChange: false)
        return snap
    }

    private func nearestEllipseSnap(
        pointer: CGPoint,
        otherPoint: CGPoint,
        pageIndex: Int,
        excluding strokeID: String?,
        settings: NativeAppConfiguration
    ) -> (point: CGPoint, kind: String, score: CGFloat)? {
        let capture = CGFloat(max(18, settings.geometrySnapDistance * 2.25))
        let maximumAngle = CGFloat.pi / 6
        var best: (point: CGPoint, kind: String, score: CGFloat)?

        for stroke in strokesForPage(pageIndex) where stroke.id != strokeID && GeometryEngine.isGeometry(stroke) {
            guard stroke.shapeType == GeometryShapeType.ellipse.rawValue || stroke.shapeType == GeometryShapeType.circle.rawValue,
                  let box = GeometryEngine.shapeBox(stroke) else { continue }
            let rx = box.width / 2
            let ry = box.height / 2
            guard rx > 0.001, ry > 0.001 else { continue }

            for index in 0..<180 {
                let angle = CGFloat(index) / 180 * .pi * 2
                let cosine = cos(angle)
                let sine = sin(angle)
                let boundary = box.localToWorld(x: rx + cosine * rx, y: ry + sine * ry)
                let pointerDistance = hypot(boundary.x - pointer.x, boundary.y - pointer.y)
                guard pointerDistance <= capture else { continue }

                let normalLocal = CGPoint(x: cosine / rx, y: sine / ry)
                var normal = CGPoint(
                    x: box.ux.x * normalLocal.x + box.uy.x * normalLocal.y,
                    y: box.ux.y * normalLocal.x + box.uy.y * normalLocal.y
                )
                let normalLength = max(0.000_001, hypot(normal.x, normal.y))
                normal.x /= normalLength
                normal.y /= normalLength
                let tangent = CGPoint(x: -normal.y, y: normal.x)

                let vx = boundary.x - otherPoint.x
                let vy = boundary.y - otherPoint.y
                let lineLength = hypot(vx, vy)
                guard lineLength > 0.001 else { continue }
                let direction = CGPoint(x: vx / lineLength, y: vy / lineLength)

                var candidates: [(String, CGPoint)] = []
                if settings.tangentSnap { candidates.append(("tangent", tangent)) }
                if settings.normalSnap { candidates.append(("normal", normal)) }
                for (candidateKind, vector) in candidates {
                    let dot = max(-1, min(1, abs(direction.x * vector.x + direction.y * vector.y)))
                    let angleDifference = acos(dot)
                    guard angleDifference <= maximumAngle else { continue }
                    let score = pointerDistance + angleDifference / maximumAngle * capture * 0.65
                    if best == nil || score < best!.score {
                        best = (point: boundary, kind: candidateKind, score: score)
                    }
                }
            }
        }
        return best
    }

    func clearSnapGuide(pageIndex: Int? = nil) {
        guard snapGuide != nil else { return }
        snapGuide = nil
        if let pageIndex { invalidatePages([pageIndex], committedChange: false) }
        else { invalidateAllPages(committedChange: false) }
    }

    func sourcePageInfo(at index: Int) -> PageInfo? {
        guard document.pages.indices.contains(index) else { return nil }
        return document.pages[index]
    }

    func workspaceState(at index: Int) -> PageWorkspaceState {
        pageWorkspaceStates[index] ?? PageWorkspaceState()
    }

    func pageInfo(at index: Int) -> PageInfo? {
        guard let source = sourcePageInfo(at: index) else { return nil }
        return workspaceState(at: index).workspacePage(from: source)
    }

    func sourcePDFFrame(inWorkspaceAt index: Int) -> CGRect? {
        guard let source = sourcePageInfo(at: index), let workspace = pageInfo(at: index) else { return nil }
        return workspaceState(at: index).sourcePDFFrame(source: source, workspace: workspace)
    }

    func rebuildAllWorkspaceStates() {
        var rebuilt: [Int: PageWorkspaceState] = [:]
        rebuilt.reserveCapacity(document.pages.count)
        for index in document.pages.indices {
            rebuilt[index] = OffPageWorkspaceGeometry.state(
                sourcePage: document.pages[index],
                strokes: strokesForPage(index)
            )
        }
        guard rebuilt != pageWorkspaceStates else { return }
        pageWorkspaceStates = rebuilt
        workspaceRevision &+= 1
    }

    private func refreshWorkspaceStates(for pages: Set<Int>) {
        var changed = false
        for index in pages where document.pages.indices.contains(index) {
            let next = OffPageWorkspaceGeometry.state(
                sourcePage: document.pages[index],
                strokes: strokesForPage(index)
            )
            if pageWorkspaceStates[index] != next {
                pageWorkspaceStates[index] = next
                changed = true
            }
        }
        let stale = pageWorkspaceStates.keys.filter { !document.pages.indices.contains($0) }
        for index in stale {
            pageWorkspaceStates.removeValue(forKey: index)
            changed = true
        }
        if changed { workspaceRevision &+= 1 }
    }

    private func expandWorkspaceStates(for stroke: NoteStroke, pages: Set<Int>) {
        var changed = false
        for index in pages where document.pages.indices.contains(index) {
            let required = OffPageWorkspaceGeometry.state(
                sourcePage: document.pages[index],
                strokes: [stroke]
            )
            let current = workspaceState(at: index)
            let expanded = PageWorkspaceState(
                leftPageWidths: max(current.leftPageWidths, required.leftPageWidths),
                rightPageWidths: max(current.rightPageWidths, required.rightPageWidths),
                hasOffPageContent: current.hasOffPageContent || required.hasOffPageContent
            )
            if expanded != current {
                pageWorkspaceStates[index] = expanded
                changed = true
            }
        }
        if changed { workspaceRevision &+= 1 }
    }

    func strokesForPage(_ index: Int) -> [NoteStroke] {
        let ids = pageStrokeIDs[index] ?? []
        return ids.compactMap { strokes[$0] }.sorted { lhs, rhs in
            if lhs.tool == "shape", lhs.shapeType == "xy-plane", lhs.isLocked,
               !(rhs.tool == "shape" && rhs.shapeType == "xy-plane" && rhs.isLocked) {
                return true
            }
            return lhs.id < rhs.id
        }
    }

    func committedStrokesForPage(_ index: Int) -> [NoteStroke] {
        strokesForPage(index).filter { !liveStrokeIDs.contains($0.id) }
    }

    func liveStrokesForPage(_ index: Int) -> [NoteStroke] {
        strokesForPage(index).filter { liveStrokeIDs.contains($0.id) }
    }

    func register(pageView: InkPageView, pageIndex: Int) {
        cleanupWeakViews(pageIndex: pageIndex)
        weakPageViews[pageIndex, default: []].append(WeakPageView(pageView))
    }

    func unregister(pageView: InkPageView, pageIndex: Int) {
        weakPageViews[pageIndex]?.removeAll { $0.value == nil || $0.value === pageView }
    }

    func pageDidMount(_ index: Int) {
        mountedPageIndices.insert(index)
    }

    func pageDidUnmount(_ index: Int) {
        mountedPageIndices.remove(index)
    }

    func updateDisplayFPS(_ fps: Double) {
        let clamped = max(0, min(240, fps))
        if abs(displayFPS - clamped) >= 0.25 {
            displayFPS = clamped
        }
    }

    func setCurrentPage(index: Int) {
        currentPageNumber = document.pages.indices.contains(index) ? index + 1 : 0
    }

    func beginStroke(pageIndex: Int, firstPoint: NotePoint, tool contactTool: NoteTool? = nil) -> String? {
        guard isConnected else {
            notice = "Drawing is disabled while disconnected"
            return nil
        }
        guard document.pages.indices.contains(pageIndex) else { return nil }
        let drawingTool = contactTool ?? selectedTool
        guard drawingTool != .eraser else { return nil }

        let pipelineConfiguration = strokeSettings.configuration
        let storedTool: String
        switch drawingTool {
        case .pressurePen, .fixedPen:
            storedTool = penPressureEnabled ? NoteTool.pressurePen.rawValue : NoteTool.fixedPen.rawValue
        default:
            storedTool = drawingTool.rawValue
        }
        let stroke = NoteStroke(
            id: "\(clientID)-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8).lowercased())",
            tool: storedTool,
            color: inkColorHex,
            width: max(0.1, min(100, inkWidth)),
            opacity: drawingTool == .highlighter ? 0.28 : 1,
            smoothing: max(0, min(100, pipelineConfiguration.smoothingStrength * 100)),
            strokeDetail: 100,
            lineStyle: inkLineStyle.rawValue,
            points: [firstPoint],
            owner: clientID,
            locked: false,
            pageIndex: pageIndex,
            pipeline: StrokePipelineSnapshot(configuration: pipelineConfiguration),
            shapeType: nil,
            gridColor: nil,
            recognitionSource: nil,
            recognitionError: nil,
            snapKind: nil,
            text: nil,
            textAlign: nil,
            fontFamily: nil
        )
        liveStrokeIDs.insert(stroke.id)
        insertOrReplace(stroke, committedChange: false)

        do {
            let object = try JSONHelpers.object(from: stroke)
            client.sendJSONObject(["type": "stroke_begin", "stroke": object])
        } catch {
            removeStroke(id: stroke.id)
            lastError = "Could not encode the new stroke"
            return nil
        }
        return stroke.id
    }

    func appendPoints(strokeID: String, points: [NotePoint]) {
        guard !points.isEmpty, var stroke = strokes[strokeID] else { return }
        stroke.points.append(contentsOf: points)
        strokes[strokeID] = stroke
        let pages = strokeMembership[strokeID] ?? []
        expandWorkspaceStates(for: stroke, pages: pages)
        invalidatePages(pages, committedChange: false)
        pendingPointBatches[strokeID, default: []].append(contentsOf: points)

        if pendingPointBatches[strokeID, default: []].count >= max(1, strokeSettings.configuration.networkBatchSize) {
            flushPendingPoints(strokeID: strokeID)
        } else {
            schedulePointFlush()
        }
    }

    func endStroke(strokeID: String) {
        flushPendingPoints(strokeID: strokeID)
        let pages = strokeMembership[strokeID] ?? []
        beginCommitTransition(strokeID: strokeID, pages: pages)
        liveStrokeIDs.remove(strokeID)
        let finalStroke = strokes[strokeID]
        if let finalStroke { insertOrReplace(finalStroke) }
        if let finalStroke, finalStroke.tool == "shape", finalStroke.recognitionSource != nil,
           let encoded = try? JSONHelpers.object(from: finalStroke) {
            client.sendJSONObject(["type": "stroke_end", "id": strokeID, "stroke": encoded])
        } else {
            client.sendJSONObject(["type": "stroke_end", "id": strokeID])
        }
    }

    func beginEraseOperation() -> String {
        "erase-\(clientID)-\(UUID().uuidString.lowercased())"
    }

    func erase(at worldPoint: CGPoint, pageIndex: Int, operationID: String, alreadyDeleted: inout Set<String>) {
        guard isConnected else { return }
        let radius = eraserSize / 2
        let candidates = pageStrokeIDs[pageIndex] ?? []
        var hitIDs: [String] = []
        for id in candidates where !alreadyDeleted.contains(id) {
            guard let stroke = strokes[id], !stroke.isLocked else { continue }
            if Self.stroke(stroke, isWithin: radius, of: worldPoint) {
                hitIDs.append(id)
                alreadyDeleted.insert(id)
            }
        }
        guard !hitIDs.isEmpty else { return }
        for id in hitIDs { removeStroke(id: id) }
        client.sendJSONObject([
            "type": "delete_strokes",
            "ids": hitIDs,
            "operationId": operationID,
            "final": false,
        ])
    }

    func finishEraseOperation(_ operationID: String) {
        guard isConnected else { return }
        client.sendJSONObject([
            "type": "delete_strokes",
            "ids": [],
            "operationId": operationID,
            "final": true,
        ])
    }

    private func schedulePointFlush() {
        guard pointFlushWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.pointFlushWorkItem = nil
            self?.flushPendingPoints(strokeID: nil)
        }
        pointFlushWorkItem = workItem
        let delay = max(1, strokeSettings.configuration.networkFlushIntervalMS) / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func flushPendingPoints(strokeID: String?) {
        pointFlushWorkItem?.cancel()
        pointFlushWorkItem = nil
        let ids = strokeID.map { [$0] } ?? Array(pendingPointBatches.keys)
        for id in ids {
            guard let points = pendingPointBatches[id], !points.isEmpty else { continue }
            pendingPointBatches.removeValue(forKey: id)
            do {
                let encoded = try JSONHelpers.object(from: points)
                client.sendJSONObject(["type": "stroke_points", "id": id, "points": encoded])
            } catch {
                lastError = "Could not encode Pencil samples"
            }
        }
    }

    private func handleServerText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let message = try JSONHelpers.decoder.decode(ServerEnvelope.self, from: data)
            handle(message)
        } catch {
            lastError = "The server sent an unsupported message"
        }
    }

    private func handle(_ message: ServerEnvelope) {
        switch message.type {
        case "snapshot":
            // Compatibility with older computer servers. New servers only send
            // small state_refresh messages to native clients.
            guard let snapshot = message.state else { return }
            applySnapshot(snapshot, liveIDs: Set(message.liveStrokeIds ?? []))
            if !snapshot.document.pages.isEmpty {
                fetchSourcePDF()
            }
        case "state_refresh":
            fetchNotebookState(reason: message.reason ?? "sync")
        case "history_state":
            canUndo = message.canUndo ?? false
            canRedo = message.canRedo ?? false
        case "document_changed":
            if let changed = message.document {
                document = changed
                if message.clearStrokes == true {
                    strokes.removeAll()
                    liveStrokeIDs.removeAll()
                    selectedStrokeIDs.removeAll()
                }
                rebuildPageIndex()
                rebuildAllWorkspaceStates()
                invalidateAllPages()
                fetchSourcePDF()
                if let focus = message.focusPageNumber {
                    currentPageNumber = focus
                }
                notice = message.notice ?? "PDF updated"
            }
        case "stroke_begin":
            if let stroke = message.stroke {
                liveStrokeIDs.insert(stroke.id)
                insertOrReplace(stroke, committedChange: false)
            }
        case "stroke_points":
            if let id = message.id, let points = message.points, var stroke = strokes[id] {
                stroke.points.append(contentsOf: points)
                strokes[id] = stroke
                let pages = strokeMembership[id] ?? []
                expandWorkspaceStates(for: stroke, pages: pages)
                invalidatePages(pages, committedChange: false)
            }
        case "stroke_end":
            if let id = message.id {
                let pages = strokeMembership[id] ?? []
                beginCommitTransition(strokeID: id, pages: pages)
                liveStrokeIDs.remove(id)
                if let stroke = strokes[id] { insertOrReplace(stroke) }
                else { invalidatePages(strokeMembership[id] ?? []) }
            }
        case "restore_strokes", "replace_strokes":
            for stroke in message.strokes ?? [] {
                insertOrReplace(stroke)
            }
        case "delete_strokes":
            for id in message.ids ?? [] {
                removeStroke(id: id)
            }
        case "clear_strokes":
            strokes.removeAll()
            pageStrokeIDs.removeAll()
            strokeMembership.removeAll()
            selectedStrokeIDs.removeAll()
            rebuildAllWorkspaceStates()
            invalidateAllPages()
        case "error":
            lastError = message.message ?? "Server error"
        case "pong", "delete_ack":
            break
        default:
            break
        }
    }

    private func fetchNotebookState(reason: String) {
        guard let stateURL = endpoint(path: "/api/state") else {
            lastError = "The computer server address is invalid"
            return
        }

        stateFetchTask?.cancel()
        stateFetchGeneration &+= 1
        let generation = stateFetchGeneration

        var request = URLRequest(url: stateURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 120
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                if (error as NSError).code == NSURLErrorCancelled { return }
                Task { @MainActor in
                    guard generation == self.stateFetchGeneration else { return }
                    self.lastError = "Notebook sync failed: \(error.localizedDescription)"
                }
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                Task { @MainActor in
                    guard generation == self.stateFetchGeneration else { return }
                    self.lastError = "The computer did not return the notebook state"
                }
                return
            }

            do {
                let snapshot = try JSONDecoder().decode(NotebookState.self, from: data)
                Task { @MainActor in
                    guard generation == self.stateFetchGeneration else { return }
                    self.applySnapshot(snapshot, liveIDs: [])
                    self.notice = reason == "project_import" ? "Project loaded" : "Notebook synchronized"
                    self.lastError = nil
                    if !snapshot.document.pages.isEmpty {
                        self.fetchSourcePDF()
                    }
                }
            } catch {
                Task { @MainActor in
                    guard generation == self.stateFetchGeneration else { return }
                    self.lastError = "Could not decode the notebook state: \(error.localizedDescription)"
                }
            }
        }
        stateFetchTask = task
        task.resume()
    }

    private func applySnapshot(_ snapshot: NotebookState, liveIDs: Set<String>) {
        document = snapshot.document
        strokes = snapshot.strokes
        liveStrokeIDs = liveIDs
        selectedStrokeIDs = Set(selectedStrokeIDs.filter { strokes[$0] != nil })
        rebuildPageIndex()
        rebuildAllWorkspaceStates()
        invalidateAllPages()
    }

    private func fetchSourcePDF() {
        guard let sourceURL = endpoint(path: "/api/pdf/source") else { return }
        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.lastError = "PDF download failed: \(error.localizedDescription)" }
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data,
                  data.starts(with: Data("%PDF-".utf8)) else {
                Task { @MainActor in self.lastError = "The laptop did not return the original PDF file" }
                return
            }

            do {
                let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("InfiniteNotesNative/PDF", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let localURL = root.appendingPathComponent("source-\(UUID().uuidString).pdf")
                try data.write(to: localURL, options: .atomic)

                Task { @MainActor in
                    guard let pdf = PDFDocument(url: localURL) else {
                        try? FileManager.default.removeItem(at: localURL)
                        self.lastError = "PDFKit could not open the downloaded source PDF"
                        return
                    }
                    let previousURL = self.pdfFileURL
                    self.pdfFileURL = localURL
                    self.pdfDocument = pdf
                    if let previousURL, previousURL != localURL {
                        try? FileManager.default.removeItem(at: previousURL)
                    }
                    if pdf.pageCount != self.document.pages.count {
                        self.notice = "PDF has \(pdf.pageCount) pages; server metadata has \(self.document.pages.count)"
                    } else {
                        self.notice = "Using original PDF with zoom-aware vector tiles"
                    }
                }
            } catch {
                Task { @MainActor in self.lastError = "Could not cache the source PDF: \(error.localizedDescription)" }
            }
        }.resume()
    }

    private func endpoint(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        guard let baseURL, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = path
        components.queryItems = queryItems + [
            URLQueryItem(name: "native", value: String(Int(Date().timeIntervalSince1970)))
        ]
        return components.url
    }

    private func performPageMutation(path: String, queryItems: [URLQueryItem], pendingNotice: String) {
        guard isConnected else {
            lastError = "Connect to the computer before changing pages"
            return
        }
        guard let url = endpoint(path: path, queryItems: queryItems) else {
            lastError = "The computer server address is invalid"
            return
        }
        notice = pendingNotice
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.lastError = "Page update failed: \(error.localizedDescription)" }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                Task { @MainActor in self.lastError = "The computer did not return a page-update response" }
                return
            }
            if !(200..<300).contains(http.statusCode) {
                let detail = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["detail"] as? String
                Task { @MainActor in self.lastError = detail ?? "Page update failed (HTTP \(http.statusCode))" }
            }
        }.resume()
    }

    private func scheduleReconnect() {
        guard shouldReconnect, let baseURL else { return }
        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.client.connect(baseURL: baseURL, clientID: self.clientID)
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    private func insertOrReplace(_ stroke: NoteStroke, committedChange: Bool = true) {
        let oldPages = strokeMembership[stroke.id] ?? []
        for page in oldPages { pageStrokeIDs[page]?.remove(stroke.id) }
        strokes[stroke.id] = stroke
        let pages = membership(for: stroke)
        strokeMembership[stroke.id] = pages
        for page in pages { pageStrokeIDs[page, default: []].insert(stroke.id) }
        let affectedPages = oldPages.union(pages)
        if committedChange || !oldPages.subtracting(pages).isEmpty {
            refreshWorkspaceStates(for: affectedPages)
        } else {
            expandWorkspaceStates(for: stroke, pages: pages)
        }
        invalidatePages(affectedPages, committedChange: committedChange)
    }

    private func removeStroke(id: String) {
        let pages = strokeMembership.removeValue(forKey: id) ?? []
        strokes.removeValue(forKey: id)
        liveStrokeIDs.remove(id)
        pendingPointBatches.removeValue(forKey: id)
        selectedStrokeIDs.remove(id)
        for page in pages { pageStrokeIDs[page]?.remove(id) }
        refreshWorkspaceStates(for: pages)
        invalidatePages(pages)
    }

    private func rebuildPageIndex() {
        pageStrokeIDs.removeAll(keepingCapacity: true)
        strokeMembership.removeAll(keepingCapacity: true)
        for stroke in strokes.values {
            let pages = membership(for: stroke)
            strokeMembership[stroke.id] = pages
            for page in pages { pageStrokeIDs[page, default: []].insert(stroke.id) }
        }
    }

    private func membership(for stroke: NoteStroke) -> Set<Int> {
        guard !document.pages.isEmpty, !stroke.points.isEmpty else { return [] }
        if let pageIndex = stroke.pageIndex, document.pages.indices.contains(pageIndex) {
            return [pageIndex]
        }
        let xs = stroke.points.map(\.x)
        let ys = stroke.points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return [] }
        let pad = max(2, stroke.width * 2)
        let bounds = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
        var result: Set<Int> = []
        for (index, page) in document.pages.enumerated() where page.worldRect.intersects(bounds) {
            result.insert(index)
        }
        if result.isEmpty, let nearest = nearestPageIndex(toWorldY: Double(bounds.midY)) {
            result.insert(nearest)
        }
        return result
    }

    private func nearestPageIndex(toWorldY y: Double) -> Int? {
        guard !document.pages.isEmpty else { return nil }
        var low = 0
        var high = document.pages.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let page = document.pages[mid]
            if y < page.y {
                high = mid - 1
            } else if y > page.y + page.height {
                low = mid + 1
            } else {
                return mid
            }
        }
        return min(max(low, 0), document.pages.count - 1)
    }

    private func invalidatePages(_ pages: Set<Int>, committedChange: Bool = true) {
        for page in pages {
            cleanupWeakViews(pageIndex: page)
            for weakView in weakPageViews[page] ?? [] {
                if committedChange { weakView.value?.invalidateCommittedContent() }
                // Live Pencil updates only rebuild reusable vector paths. They
                // no longer repaint the page-sized high-resolution ink cache.
                weakView.value?.scheduleLiveRefresh()
            }
        }
    }

    private func beginCommitTransition(strokeID: String, pages: Set<Int>) {
        for page in pages {
            cleanupWeakViews(pageIndex: page)
            for weakView in weakPageViews[page] ?? [] {
                weakView.value?.beginCommitTransition(strokeID: strokeID)
            }
        }
    }

    private func invalidateAllPages(committedChange: Bool = true) {
        invalidatePages(Set(weakPageViews.keys), committedChange: committedChange)
    }

    private func cleanupWeakViews(pageIndex: Int) {
        weakPageViews[pageIndex]?.removeAll { $0.value == nil }
    }

    private static func normalizedHex(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        guard cleaned.count == 6, cleaned.allSatisfy({ $0.isHexDigit }) else { return "#111111" }
        return "#\(cleaned)"
    }

    private static func loadStringPresets(_ stored: [String]?, fallback: [String]) -> [String] {
        let source = stored?.isEmpty == false ? stored! : fallback
        return source.map(normalizedHex)
    }

    private static func nearestPresetIndex(to value: Double, in presets: [Double]) -> Int {
        guard let best = presets.indices.min(by: {
            abs(presets[$0] - value) < abs(presets[$1] - value)
        }) else { return 0 }
        return best
    }

    private static func loadWidthPresets(
        _ stored: [Double]?,
        fallback: [Double],
        range: ClosedRange<Double>
    ) -> [Double] {
        let source = stored?.count == fallback.count ? stored! : fallback
        return source.map { max(range.lowerBound, min(range.upperBound, $0)) }
    }

    private static func normalizedBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              components.host != nil else { return nil }
        if components.port == nil { components.port = 8000 }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func stroke(_ stroke: NoteStroke, isWithin radius: Double, of point: CGPoint) -> Bool {
        let threshold = radius + max(1, stroke.width / 2)
        let thresholdSquared = threshold * threshold
        let points = stroke.points.map { CGPoint(x: $0.x, y: $0.y) }
        guard let first = points.first else { return false }
        if points.count == 1 {
            return Self.distanceSquared(first, point) <= thresholdSquared
        }
        for index in 1..<points.count {
            if Self.segmentDistanceSquared(point, points[index - 1], points[index]) <= thresholdSquared {
                return true
            }
        }
        if stroke.tool == "text" || stroke.tool == "shape" {
            let rect = points.reduce(CGRect.null) { partial, next in
                partial.union(CGRect(x: next.x, y: next.y, width: 0.1, height: 0.1))
            }.insetBy(dx: -threshold, dy: -threshold)
            return rect.contains(point)
        }
        return false
    }

    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return dx * dx + dy * dy
    }

    private static func segmentDistanceSquared(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let vx = Double(b.x - a.x)
        let vy = Double(b.y - a.y)
        let wx = Double(point.x - a.x)
        let wy = Double(point.y - a.y)
        let lengthSquared = vx * vx + vy * vy
        if lengthSquared <= 0.000_001 { return wx * wx + wy * wy }
        let t = max(0, min(1, (wx * vx + wy * vy) / lengthSquared))
        let dx = Double(point.x) - (Double(a.x) + t * vx)
        let dy = Double(point.y) - (Double(a.y) + t * vy)
        return dx * dx + dy * dy
    }
}

private final class WeakPageView {
    weak var value: InkPageView?
    init(_ value: InkPageView) { self.value = value }
}
