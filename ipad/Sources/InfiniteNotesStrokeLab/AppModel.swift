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
    @Published private(set) var savedNotebooks: [SavedNotebook] = []
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
    private var syncMutationGeneration = 0
    private var deferredFetchWorkItem: DispatchWorkItem?
    private var strokes: [String: NoteStroke] = [:]
    private var pageStrokeIDs: [Int: Set<String>] = [:]
    private var eraserIndex = EraserSpatialIndex()
    private var eraserDirtyIDs: Set<String> = []
    private var eraserPreviousPoints: [String: CGPoint] = [:]
    private var deferredEraseWorkspacePages: Set<Int> = []
    private var eraserPerformance: [String: EraserPerformance] = [:]
    private var strokeMembership: [String: Set<Int>] = [:]
    private var pageWorkspaceStates: [Int: PageWorkspaceState] = [:]
    private var workspaceSettingsSignature: [Int] = []
    private var whiteboardVisibleSections = (left: 2, right: 2, top: 2, bottom: 2)
    private var liveStrokes = LiveStrokeTracker()
    private var liveStrokeIDs: Set<String> { liveStrokes.ids }
    // Completed local strokes remain here until the server acknowledges them.
    // If the socket drops after Pencil input was accepted locally, these final
    // vector strokes are replayed before a reconnect snapshot is allowed to
    // replace the iPad's state.
    private var pendingCommitStrokes: [String: NoteStroke] = [:]
    private let pendingJournal = PendingStrokeJournal<NoteStroke>(root:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InfiniteNotes/PendingStrokes", isDirectory: true))
    private var pendingErases = PendingEraseQueue(root:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InfiniteNotes/PendingErases", isDirectory: true))
    private var activeEraseOperations: Set<String> = []
    private var eraseBatchInFlight: PendingEraseQueue.Batch?
    private var hasPendingEdits: Bool { !pendingCommitStrokes.isEmpty || !pendingErases.isEmpty }
    private var pendingDocumentID: String?
    private var connectedDocumentID: String?
    private var journalBlocked = false
    private var isReconcilingPendingStrokes = false
    private var deferredStateRefreshReason: String?
    // Only a fully applied snapshot or a complete, contiguous revision delta
    // may advance this value. An operation ACK alone cannot prove that all
    // concurrent remote edits through its revision reached this client.
    private var lastAppliedDocumentID: String?
    private var lastAppliedDocumentRevision: Int?
    private var lastAppliedStateToken: String?
    // Keep reconnect payloads comfortably below common WebSocket frame limits.
    // Sending the entire offline queue in one JSON message can create a permanent
    // reconnect loop: the peer closes the oversized socket, then the client sends
    // the exact same oversized message on the replacement socket.
    private static let maximumReconciliationBatchStrokes = 12
    private static let maximumReconciliationBatchBytes = 512 * 1024
    private static let syncMutatingMessageTypes: Set<String> = [
        "snapshot", "document_changed", "stroke_begin", "stroke_points", "stroke_end",
        "restore_strokes", "replace_strokes", "delete_strokes", "clear_strokes",
    ]
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
            range: 1...120
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

        workspaceSettingsSignature = [
            appSettings.configuration.resolvedWorkspaceInitialLeftSections,
            appSettings.configuration.resolvedWorkspaceInitialRightSections,
            appSettings.configuration.resolvedWorkspaceExtraSections,
        ]
        appSettings.$configuration
            .dropFirst()
            .sink { [weak self] configuration in
                guard let self else { return }
                let signature = [
                    configuration.resolvedWorkspaceInitialLeftSections,
                    configuration.resolvedWorkspaceInitialRightSections,
                    configuration.resolvedWorkspaceExtraSections,
                ]
                if signature != self.workspaceSettingsSignature {
                    self.workspaceSettingsSignature = signature
                    self.rebuildAllWorkspaceStates(settings: configuration)
                }
                self.settingsRevision &+= 1
                self.invalidateAllPages()
            }
            .store(in: &cancellables)

        client.onStatus = { [weak self] status in
            guard let self else { return }
            self.connectionStatus = status
            DebugSessionLogger.shared.event(
                "connection",
                "status_changed",
                fields: ["status": status.label, "pendingStrokeCount": self.pendingCommitStrokes.count]
            )
            switch status {
            case .connected:
                self.lastError = nil
                self.reconnectWorkItem?.cancel()
                self.reconnectWorkItem = nil
            case .disconnected, .failed:
                self.discardInterruptedRemoteStrokes()
                self.connectedDocumentID = nil
                self.isReconcilingPendingStrokes = false
                self.eraseBatchInFlight = nil
                self.deferredStateRefreshReason = nil
                self.deferredFetchWorkItem?.cancel()
                self.deferredFetchWorkItem = nil
                self.stateFetchTask?.cancel()
                self.stateFetchTask = nil
                self.stateFetchGeneration &+= 1
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
        updated[index] = max(1, min(120, value))
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
        discardInterruptedRemoteStrokes()
        eraseBatchInFlight = nil
        isReconcilingPendingStrokes = false
        connectedDocumentID = nil
        deferredStateRefreshReason = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        stateFetchTask?.cancel()
        stateFetchTask = nil
        stateFetchGeneration &+= 1
        deferredFetchWorkItem?.cancel()
        deferredFetchWorkItem = nil
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
        deferredStateRefreshReason = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        stateFetchTask?.cancel()
        stateFetchTask = nil
        stateFetchGeneration &+= 1
        deferredFetchWorkItem?.cancel()
        deferredFetchWorkItem = nil
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
        downloadPDF(path: "/api/pdf/export", queryItems: [
                URLQueryItem(name: "overflowMargin", value: "20"),
                URLQueryItem(name: "outerGridStyle", value: appSettings.configuration.resolvedOffPageGridStyle.rawValue),
                URLQueryItem(name: "outerGridSpacing", value: String(appSettings.configuration.resolvedOffPageGridSpacing)),
            ])
    }

    func createWhiteboard(name: String) {
        guard isConnected, !hasPendingEdits else {
            lastError = "Connect and synchronize pending edits before creating a whiteboard"
            return
        }
        postWhiteboard(path: "/api/whiteboard", settings: appSettings.configuration.whiteboardDefaults,
                       documentID: nil, name: name)
    }

    func updateWhiteboardSettings(_ settings: WhiteboardInfo) {
        guard isConnected, document.whiteboard != nil, let documentID = lastAppliedDocumentID else {
            lastError = "Connect to the whiteboard before saving its settings"
            return
        }
        postWhiteboard(path: "/api/whiteboard/settings", settings: settings, documentID: documentID, name: nil)
    }

    func refreshSavedNotebooks() {
        guard let url = endpoint(path: "/api/notebooks") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, let data,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let decoded = try? JSONDecoder().decode(SavedNotebookList.self, from: data) else { return }
            Task { @MainActor in self.savedNotebooks = decoded.notebooks }
        }.resume()
    }

    func openSavedNotebook(_ notebook: SavedNotebook) {
        guard isConnected, !hasPendingEdits,
              let url = endpoint(path: "/api/notebooks/\(notebook.documentId)/open") else {
            lastError = "Connect and synchronize pending edits before switching notebooks"
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.lastError = "Could not open notebook: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let detail = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["detail"] as? String
                    self.lastError = detail ?? "Could not open notebook (HTTP \(http.statusCode))"
                } else {
                    self.notice = "Opened \(notebook.name)"
                    self.refreshSavedNotebooks()
                }
            }
        }.resume()
    }

    private func postWhiteboard(path: String, settings: WhiteboardInfo, documentID: String?, name: String?) {
        guard let url = endpoint(path: path) else {
            lastError = "The computer server address is invalid"
            return
        }
        do {
            let encoded = try JSONEncoder().encode(settings)
            var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
            if let documentID { object["documentId"] = documentID }
            if let name { object["name"] = name }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
            request.timeoutInterval = 120
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                Task { @MainActor in
                    if let error {
                        self.lastError = "Whiteboard update failed: \(error.localizedDescription)"
                    } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        let detail = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["detail"] as? String
                        self.lastError = detail ?? "Whiteboard update failed (HTTP \(http.statusCode))"
                    } else {
                        self.notice = documentID == nil ? "Whiteboard ready" : "Whiteboard settings saved"
                        self.refreshSavedNotebooks()
                    }
                }
            }.resume()
        } catch {
            lastError = "Could not prepare whiteboard settings: \(error.localizedDescription)"
        }
    }

    func exportWhiteboardPDF(mode: String, bounds: String, margin: Double,
                             backgroundColor: String, gridColor: String, includeGrid: Bool) {
        guard document.whiteboard != nil else { return }
        downloadPDF(path: "/api/whiteboard/export", queryItems: [
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "bounds", value: bounds),
            URLQueryItem(name: "margin", value: String(margin)),
            URLQueryItem(name: "backgroundColor", value: backgroundColor),
            URLQueryItem(name: "gridColor", value: gridColor),
            URLQueryItem(name: "includeGrid", value: includeGrid ? "true" : "false"),
        ])
    }

    func checkWhiteboardPagedExport(_ completion: @escaping ([Int]) -> Void) {
        guard let url = endpoint(path: "/api/whiteboard/export-info") else {
            lastError = "The computer server address is invalid"
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, let data,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pages = value["sparsePages"] as? [Int] else {
                Task { @MainActor in self.lastError = "Could not check whiteboard pages before export" }
                return
            }
            Task { @MainActor in completion(pages) }
        }.resume()
    }

    private func downloadPDF(path: String, queryItems: [URLQueryItem]) {
        guard let url = endpoint(path: path, queryItems: queryItems) else {
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
            guard let http = response as? HTTPURLResponse else {
                Task { @MainActor in self.lastError = "The computer did not return an export response" }
                return
            }
            guard (200..<300).contains(http.statusCode), let temporaryURL else {
                let detail = temporaryURL.flatMap { try? Data(contentsOf: $0) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["detail"] as? String
                Task { @MainActor in self.lastError = detail ?? "The computer could not export the PDF" }
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
        guard canUndo, isConnected, pendingErases.isEmpty else { return }
        client.sendJSONObject(["type": "undo"])
    }

    func redo() {
        guard canRedo, isConnected, pendingErases.isEmpty else { return }
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

        liveStrokes.begin(strokeID, local: true)
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
        if document.whiteboard != nil,
           newStrokes.contains(where: { stroke in
               guard let firstPoint = stroke.points.first else { return true }
               return !mayStartWhiteboardStroke(firstPoint)
           }) {
            notice = "Move closer to existing ink to add an item"
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

    private func calculatedWorkspaceState(at index: Int, strokes values: [NoteStroke],
                                          settings: NativeAppConfiguration) -> PageWorkspaceState {
        let source = document.pages[index]
        if document.whiteboard != nil {
            return OffPageWorkspaceGeometry.whiteboardState(
                sourcePage: source, strokes: values,
                visibleLeft: whiteboardVisibleSections.left,
                visibleRight: whiteboardVisibleSections.right,
                visibleTop: whiteboardVisibleSections.top,
                visibleBottom: whiteboardVisibleSections.bottom
            )
        }
        return OffPageWorkspaceGeometry.state(
            sourcePage: source, strokes: values,
            initialLeft: settings.resolvedWorkspaceInitialLeftSections,
            initialRight: settings.resolvedWorkspaceInitialRightSections,
            extra: settings.resolvedWorkspaceExtraSections
        )
    }

    func extendWhiteboardView(near center: CGPoint) {
        guard let board = document.whiteboard, let source = document.pages.first else { return }
        let state = workspaceState(at: 0)
        let column = Int(floor((Double(center.x) - source.x) / board.sectionWidth))
        let row = Int(floor((Double(center.y) - source.y) / board.sectionHeight))
        var changed = false
        if column <= -state.leftPageWidths + 1 {
            whiteboardVisibleSections.left = max(whiteboardVisibleSections.left, -column + 5)
            changed = true
        }
        if column >= state.rightPageWidths - 1 {
            whiteboardVisibleSections.right = max(whiteboardVisibleSections.right, column + 5)
            changed = true
        }
        if row <= -state.topPageHeights + 1 {
            whiteboardVisibleSections.top = max(whiteboardVisibleSections.top, -row + 5)
            changed = true
        }
        if row >= state.bottomPageHeights - 1 {
            whiteboardVisibleSections.bottom = max(whiteboardVisibleSections.bottom, row + 5)
            changed = true
        }
        if changed { rebuildAllWorkspaceStates() }
    }

    private func mayStartWhiteboardStroke(_ point: NotePoint) -> Bool {
        guard let board = document.whiteboard else { return true }
        let column = Int(floor(point.x / board.sectionWidth))
        let row = Int(floor(point.y / board.sectionHeight))
        let halo = max(1, min(10, board.halo))
        if max(abs(column), abs(row)) <= halo { return true }
        return workspaceState(at: 0).occupiedSections.contains { section in
            max(abs(column - section.column), abs(row - section.row)) <= halo
        }
    }

    func pageInfo(at index: Int) -> PageInfo? {
        guard let source = sourcePageInfo(at: index) else { return nil }
        return workspaceState(at: index).workspacePage(from: source)
    }

    func sourcePDFFrame(inWorkspaceAt index: Int) -> CGRect? {
        guard let source = sourcePageInfo(at: index), let workspace = pageInfo(at: index) else { return nil }
        return workspaceState(at: index).sourcePDFFrame(source: source, workspace: workspace)
    }

    func rebuildAllWorkspaceStates(settings override: NativeAppConfiguration? = nil) {
        var rebuilt: [Int: PageWorkspaceState] = [:]
        rebuilt.reserveCapacity(document.pages.count)
        let settings = override ?? appSettings.configuration
        for index in document.pages.indices {
            rebuilt[index] = calculatedWorkspaceState(at: index, strokes: strokesForPage(index), settings: settings)
        }
        guard rebuilt != pageWorkspaceStates else { return }
        pageWorkspaceStates = rebuilt
        workspaceRevision &+= 1
    }

    private func refreshWorkspaceStates(for pages: Set<Int>) {
        if !activeEraseOperations.isEmpty {
            deferredEraseWorkspacePages.formUnion(pages)
            return
        }
        var changed = false
        let settings = appSettings.configuration
        for index in pages where document.pages.indices.contains(index) {
            let next = calculatedWorkspaceState(at: index, strokes: strokesForPage(index), settings: settings)
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
        let settings = appSettings.configuration
        for index in pages where document.pages.indices.contains(index) {
            let required = calculatedWorkspaceState(at: index, strokes: [stroke], settings: settings)
            let current = workspaceState(at: index)
            let expanded = PageWorkspaceState(
                leftPageWidths: max(current.leftPageWidths, required.leftPageWidths),
                rightPageWidths: max(current.rightPageWidths, required.rightPageWidths),
                topPageHeights: max(current.topPageHeights, required.topPageHeights),
                bottomPageHeights: max(current.bottomPageHeights, required.bottomPageHeights),
                hasLeftContent: current.hasLeftContent || required.hasLeftContent,
                hasRightContent: current.hasRightContent || required.hasRightContent,
                occupiedSections: current.occupiedSections.union(required.occupiedSections)
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
        liveStrokeIDs.compactMap { id in
            strokeMembership[id]?.contains(index) == true ? strokes[id] : nil
        }.sorted { lhs, rhs in
            if lhs.tool == "shape", lhs.shapeType == "xy-plane", lhs.isLocked,
               !(rhs.tool == "shape" && rhs.shapeType == "xy-plane" && rhs.isLocked) { return true }
            return lhs.id < rhs.id
        }
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
        if !isConnected {
            notice = "Drawing offline — Pencil strokes will upload after reconnecting"
        }
        guard document.pages.indices.contains(pageIndex) else { return nil }
        guard mayStartWhiteboardStroke(firstPoint) else {
            notice = "Move closer to existing ink to start a stroke"
            return nil
        }
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
        liveStrokes.begin(stroke.id, local: true)
        insertOrReplace(stroke, committedChange: false)

        do {
            let object = try JSONHelpers.object(from: stroke)
            if let documentID = pendingDocumentID, connectedDocumentID == documentID {
                client.sendJSONObject(["type": "stroke_begin", "stroke": object, "documentId": documentID])
            }
        } catch {
            removeStroke(id: stroke.id)
            lastError = "Could not encode the new stroke"
            return nil
        }
        return stroke.id
    }

    func appendPoints(strokeID: String, points: [NotePoint]) {
        guard !points.isEmpty, var stroke = strokes[strokeID] else { return }
        syncMutationGeneration &+= 1
        stroke.points.append(contentsOf: points)
        strokes[strokeID] = stroke
        eraserIndex.remove(strokeID)
        eraserDirtyIDs.insert(strokeID)
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
        liveStrokes.end(strokeID)
        guard let finalStroke = strokes[strokeID] else { return }
        insertOrReplace(finalStroke)
        pendingCommitStrokes[strokeID] = finalStroke
        if let documentID = pendingDocumentID ?? lastAppliedDocumentID {
            pendingDocumentID = documentID
            do {
                try pendingJournal.save(finalStroke, id: strokeID, documentID: documentID)
            } catch {
                journalBlocked = true
                lastError = "Could not save offline stroke: \(error.localizedDescription)"
                return
            }
        }

        // WebSocket delivery is ordered and reliable while this connection is
        // alive, so ordinary ink does not need to repeat every sample again in
        // stroke_end. If the connection dies before acknowledgement, the final
        // local stroke remains in pendingCommitStrokes and is replayed in bounded
        // batches after reconnecting. Recognized geometry must still replace the
        // streamed freehand stroke, but its final payload contains only 2–3 points.
        var message: [String: Any] = ["type": "stroke_end", "id": strokeID]
        guard let documentID = pendingDocumentID, connectedDocumentID == documentID else { return }
        message["documentId"] = documentID
        if finalStroke.tool == "shape" || finalStroke.tool == "text" {
            guard let encoded = try? JSONHelpers.object(from: finalStroke) else {
                lastError = "Could not encode the completed stroke"
                return
            }
            message["stroke"] = encoded
        }
        client.sendJSONObject(message)
    }

    func beginEraseOperation() -> String {
        let id = "erase-\(clientID)-\(UUID().uuidString.lowercased())"
        activeEraseOperations.insert(id)
        eraserPerformance[id] = EraserPerformance()
        return id
    }

    func erase(at worldPoint: CGPoint, pageIndex: Int, operationID: String, alreadyDeleted: inout Set<String>) {
        erase(along: [worldPoint], pageIndex: pageIndex, operationID: operationID, alreadyDeleted: &alreadyDeleted)
    }

    func erase(along points: [CGPoint], pageIndex: Int, operationID: String, alreadyDeleted: inout Set<String>) {
        guard let first = points.first, let last = points.last else { return }
        guard !journalBlocked, let documentID = lastAppliedDocumentID ?? pendingDocumentID else { return }
        guard !hasPendingEdits || pendingDocumentID == documentID else {
            lastError = "Pending edits belong to another notebook. Reopen that notebook to restore them."
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let sweep = [eraserPreviousPoints[operationID] ?? first] + points
        eraserPreviousPoints[operationID] = last
        let radius = CGFloat(eraserSize / 2)
        // Live/preview strokes are rebuilt only when queried, never on every point frame.
        for id in eraserDirtyIDs {
            if let stroke = strokes[id], !stroke.isLocked,
               let geometry = GeometryEngine.eraserGeometry(stroke) {
                eraserIndex.update(id: id, geometry: geometry, pages: strokeMembership[id] ?? [])
            } else { eraserIndex.remove(id) }
        }
        eraserDirtyIDs.removeAll(keepingCapacity: true)
        let candidates = eraserIndex.candidates(sweep: sweep, radius: radius, page: pageIndex)
        var hitIDs: [String] = []
        for id in candidates where !alreadyDeleted.contains(id) {
            if eraserIndex.geometry(for: id)?.intersects(sweep: sweep, radius: radius) == true {
                hitIDs.append(id)
            }
        }
        let tested = ProcessInfo.processInfo.systemUptime
        eraserPerformance[operationID]?.recordQuery(samples: points.count, candidates: candidates.count,
                                                  hits: hitIDs.count, seconds: tested - started)
        guard !hitIDs.isEmpty else { return }
        do {
            // Save the deletion first, so a crash cannot replay an erased local stroke.
            try pendingErases.append(hitIDs, operationID: operationID, documentID: documentID)
            pendingDocumentID = documentID
            for id in hitIDs where pendingCommitStrokes[id] != nil {
                try pendingJournal.acknowledge(id, documentID: documentID)
                pendingCommitStrokes.removeValue(forKey: id)
            }
        } catch {
            journalBlocked = true
            lastError = "Could not save offline erasing: \(error.localizedDescription)"
            return
        }
        let saved = ProcessInfo.processInfo.systemUptime
        alreadyDeleted.formUnion(hitIDs)
        removeStrokes(ids: hitIDs)
        let removed = ProcessInfo.processInfo.systemUptime
        eraserPerformance[operationID]?.recordMutation(journal: saved - tested, removal: removed - saved,
                                                      total: removed - started)
    }

    func finishEraseOperation(_ operationID: String) {
        activeEraseOperations.remove(operationID)
        eraserPreviousPoints.removeValue(forKey: operationID)
        let workspaceStarted = ProcessInfo.processInfo.systemUptime
        if activeEraseOperations.isEmpty {
            let pages = deferredEraseWorkspacePages
            deferredEraseWorkspacePages.removeAll()
            refreshWorkspaceStates(for: pages)
        }
        if let performance = eraserPerformance.removeValue(forKey: operationID) {
            DebugSessionLogger.shared.event("performance", "erase_gesture", fields:
                performance.fields(workspaceSeconds: ProcessInfo.processInfo.systemUptime - workspaceStarted))
        }
        guard let documentID = pendingDocumentID else { return }
        do {
            try pendingErases.finish(operationID, documentID: documentID)
            beginPendingStrokeReconciliationIfNeeded()
        } catch {
            journalBlocked = true
            lastError = "Could not save offline erasing: \(error.localizedDescription)"
        }
    }

    private func replayPendingErases() {
        guard isConnected, !journalBlocked,
              let documentID = pendingDocumentID, connectedDocumentID == documentID,
              pendingCommitStrokes.isEmpty, !isReconcilingPendingStrokes,
              eraseBatchInFlight == nil, let batch = pendingErases.nextBatch() else { return }
        eraseBatchInFlight = batch
        client.sendJSONObject([
            "type": "delete_strokes", "documentId": documentID,
            "ids": batch.ids, "operationId": batch.operationID, "final": batch.final,
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
                if let documentID = pendingDocumentID, connectedDocumentID == documentID {
                    client.sendJSONObject(["type": "stroke_points", "id": id, "points": encoded, "documentId": documentID])
                }
            } catch {
                lastError = "Could not encode Pencil samples"
            }
        }
    }

    private func handleServerText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let message = try JSONHelpers.decoder.decode(ServerEnvelope.self, from: data)
            if message.type == "state_refresh", message.reason == "initial" {
                DebugSessionLogger.shared.configure(
                    enabled: message.debugEnabled == true,
                    sessionID: message.sessionId
                )
            }
            DebugSessionLogger.shared.protocolEvent(
                direction: "rx",
                envelope: message,
                byteCount: data.count
            )
            handle(message)
        } catch {
            lastError = "The server sent an unsupported message"
        }
    }

    private func handle(_ message: ServerEnvelope) {
        if Self.syncMutatingMessageTypes.contains(message.type) {
            syncMutationGeneration &+= 1
            if deferredStateRefreshReason != nil { scheduleDeferredStateFetch() }
        }
        switch message.type {
        case "snapshot":
            // Compatibility with older computer servers. New servers only send
            // small state_refresh messages to native clients.
            guard let snapshot = message.state else { return }
            guard applySnapshot(snapshot, liveIDs: Set(message.liveStrokeIds ?? [])) else { return }
            if !snapshot.document.pages.isEmpty {
                fetchSourcePDF()
            }
        case "state_refresh":
            let reason = message.reason ?? "sync"
            connectedDocumentID = message.documentId
            if let documentID = message.documentId {
                if hasPendingEdits, let pendingID = pendingDocumentID,
                   pendingID != documentID {
                    lastError = "Pending edits belong to another notebook. Reopen that notebook to restore them."
                    return
                }
                do {
                    let recovered = try pendingJournal.load(documentID: documentID)
                    try pendingErases.load(documentID: documentID, activeOperationIDs: activeEraseOperations)
                    // Erase records win over pending adds, including a crash between
                    // recording the erase and deleting the completed-stroke record.
                    for id in pendingErases.erasedIDs {
                        try pendingJournal.acknowledge(id, documentID: documentID)
                        pendingCommitStrokes.removeValue(forKey: id)
                        removeStroke(id: id)
                    }
                    journalBlocked = false
                    pendingDocumentID = documentID
                    for (id, stroke) in recovered where pendingCommitStrokes[id] == nil && !pendingErases.erasedIDs.contains(id) {
                        pendingCommitStrokes[id] = stroke
                    }
                } catch {
                    journalBlocked = true
                    lastError = "Could not read saved offline edits: \(error.localizedDescription)"
                    DebugSessionLogger.shared.event(
                        "journal", "load_failed",
                        fields: ["documentId": documentID,
                                 "errorType": String(describing: type(of: error)),
                                 "detail": error.localizedDescription]
                    )
                    return
                }
            }
            DebugSessionLogger.shared.event(
                "sync",
                "state_refresh_received",
                fields: [
                    "reason": reason,
                    "pendingStrokeCount": pendingCommitStrokes.count,
                    "reconciling": isReconcilingPendingStrokes,
                    "stateToken": message.stateToken ?? "",
                    "documentRevision": message.documentRevision ?? 0,
                ]
            )
            if hasPendingEdits || isReconcilingPendingStrokes || !liveStrokeIDs.isEmpty {
                DebugSessionLogger.shared.event("sync", "state_refresh_deferred", fields: ["reason": reason])
                deferredStateRefreshReason = reason
                beginPendingStrokeReconciliationIfNeeded()
                scheduleDeferredStateFetch()
            } else if reason == "initial",
                      let incomingDocumentID = message.documentId,
                      let incomingRevision = message.documentRevision,
                      let incomingToken = message.stateToken,
                      incomingToken == lastAppliedStateToken,
                      liveStrokeIDs.isEmpty,
                      incomingDocumentID == lastAppliedDocumentID,
                      incomingRevision == lastAppliedDocumentRevision {
                // A campus-Wi-Fi transport reconnect should not automatically
                // re-download and reapply the complete notebook/PDF when the
                // durable document revision did not change while the socket was
                // away. lastAppliedDocumentRevision only comes from a complete
                // snapshot or contiguous delta, never a mutation acknowledgement.
                notice = "Reconnected"
                DebugSessionLogger.shared.event(
                    "sync",
                    "state_fetch_skipped_matching_revision",
                    fields: [
                        "documentId": incomingDocumentID,
                        "documentRevision": incomingRevision,
                        "stateToken": message.stateToken ?? "",
                    ]
                )
            } else {
                if reason == "initial",
                   let incomingDocumentID = message.documentId,
                   let incomingRevision = message.documentRevision,
                   let incomingToken = message.stateToken,
                   let appliedRevision = lastAppliedDocumentRevision,
                   incomingDocumentID == lastAppliedDocumentID,
                   incomingRevision > appliedRevision,
                   RevisionDeltaSafety.sameServerInstance(incomingToken, lastAppliedStateToken),
                   liveStrokeIDs.isEmpty {
                    fetchRevisionChanges(
                        documentID: incomingDocumentID,
                        sinceRevision: appliedRevision,
                        serverToken: incomingToken
                    )
                } else {
                    fetchNotebookState(reason: reason)
                }
            }
        case "history_state":
            canUndo = message.canUndo ?? false
            canRedo = message.canRedo ?? false
        case "document_changed":
            if let changed = message.document {
                connectedDocumentID = message.documentId
                pendingDocumentID = message.documentId
                document = changed
                lastAppliedDocumentID = message.documentId
                lastAppliedDocumentRevision = nil
                lastAppliedStateToken = nil
                if message.clearStrokes == true {
                    whiteboardVisibleSections = (left: 2, right: 2, top: 2, bottom: 2)
                    strokes.removeAll()
                    liveStrokes.reset()
                    selectedStrokeIDs.removeAll()
                    // Pending commits belong to the previous document. Replaying
                    // them into a newly opened PDF is both incorrect and can keep
                    // a previously oversized reconnect payload alive forever.
                    pendingCommitStrokes.removeAll()
                    pendingErases.reset()
                    activeEraseOperations.removeAll()
                    eraserPreviousPoints.removeAll()
                    eraserPerformance.removeAll()
                    deferredEraseWorkspacePages.removeAll()
                    eraseBatchInFlight = nil
                    pendingPointBatches.removeAll()
                    isReconcilingPendingStrokes = false
                    deferredStateRefreshReason = nil
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
                liveStrokes.begin(stroke.id, local: false)
                insertOrReplace(stroke, committedChange: false)
            }
        case "stroke_points":
            if let id = message.id, let points = message.points, var stroke = strokes[id] {
                stroke.points.append(contentsOf: points)
                strokes[id] = stroke
                eraserIndex.remove(id)
                eraserDirtyIDs.insert(id)
                let pages = strokeMembership[id] ?? []
                expandWorkspaceStates(for: stroke, pages: pages)
                invalidatePages(pages, committedChange: false)
            }
        case "stroke_end":
            if let id = message.id {
                let pages = strokeMembership[id] ?? []
                beginCommitTransition(strokeID: id, pages: pages)
                liveStrokes.end(id)
                if let stroke = strokes[id] { insertOrReplace(stroke) }
                else {
                    // A reconnect can miss stroke_begin and point frames. Fetch
                    // the committed stroke instead of leaving an invisible gap.
                    deferredStateRefreshReason = "missing_remote_stroke"
                }
                if liveStrokeIDs.isEmpty { scheduleDeferredStateFetch() }
            }
        case "restore_strokes", "replace_strokes":
            for stroke in message.strokes ?? [] {
                insertOrReplace(stroke)
            }
        case "delete_strokes":
            removeStrokes(ids: message.ids ?? [])
        case "clear_strokes":
            strokes.removeAll()
            eraserIndex = EraserSpatialIndex()
            eraserDirtyIDs.removeAll()
            liveStrokes.reset()
            pageStrokeIDs.removeAll()
            strokeMembership.removeAll()
            selectedStrokeIDs.removeAll()
            rebuildAllWorkspaceStates()
            invalidateAllPages()
        case "stroke_ack":
            guard message.documentId == pendingDocumentID else { return }
            let acknowledgedIDs = message.ids ?? []
            for id in acknowledgedIDs {
                if acknowledgedIDs.count == 1,
                   let expected = pendingCommitStrokes[id],
                   let serverPointCount = message.pointCount,
                   serverPointCount != expected.points.count {
                    // Never discard the local authoritative final stroke when
                    // the server only received a partial streamed version.
                    notice = "Repairing an incomplete stroke after reconnect…"
                    continue
                }
                acknowledgePendingStroke(id)
            }
            if acknowledgedIDs.contains(where: { pendingCommitStrokes[$0] != nil }) {
                beginPendingStrokeReconciliationIfNeeded()
            }
            DebugSessionLogger.shared.event(
                "ack",
                "stroke_ack_applied",
                fields: [
                    "idCount": acknowledgedIDs.count,
                    "pendingStrokeCount": pendingCommitStrokes.count,
                    "stateToken": message.stateToken ?? "",
                    "documentRevision": message.documentRevision ?? 0,
                ]
            )
            if pendingCommitStrokes.isEmpty {
                replayPendingErases()
                scheduleDeferredStateFetch()
            }
        case "reconcile_ack":
            guard message.documentId == pendingDocumentID else { return }
            for id in message.ids ?? [] {
                acknowledgePendingStroke(id)
            }
            isReconcilingPendingStrokes = false
            DebugSessionLogger.shared.event(
                "reconciliation",
                "batch_acknowledged",
                fields: [
                    "idCount": message.ids?.count ?? 0,
                    "pendingStrokeCount": pendingCommitStrokes.count,
                    "stateToken": message.stateToken ?? "",
                    "documentRevision": message.documentRevision ?? 0,
                ]
            )
            if pendingCommitStrokes.isEmpty {
                replayPendingErases()
                let reason = deferredStateRefreshReason ?? "reconnect_reconciled"
                deferredStateRefreshReason = reason
                scheduleDeferredStateFetch()
            } else {
                beginPendingStrokeReconciliationIfNeeded()
            }
        case "error":
            eraseBatchInFlight = nil
            if isReconcilingPendingStrokes {
                isReconcilingPendingStrokes = false
            }
            lastError = message.message ?? "Server error"
        case "delete_ack":
            guard message.documentId == pendingDocumentID,
                  let documentID = pendingDocumentID,
                  let batch = eraseBatchInFlight,
                  message.operationId == batch.operationID,
                  message.final == batch.final,
                  Set(message.ids ?? []) == Set(batch.ids) else { return }
            do {
                try pendingErases.acknowledge(batch, documentID: documentID)
                eraseBatchInFlight = nil
                replayPendingErases()
                scheduleDeferredStateFetch()
            } catch {
                journalBlocked = true
                lastError = "Could not update saved erasing: \(error.localizedDescription)"
            }
        case "pong":
            break
        default:
            break
        }
    }

    private func acknowledgePendingStroke(_ id: String) {
        do {
            if let documentID = pendingDocumentID {
                try pendingJournal.acknowledge(id, documentID: documentID)
            }
            pendingCommitStrokes.removeValue(forKey: id)
        } catch {
            journalBlocked = true
            lastError = "Could not update saved offline strokes: \(error.localizedDescription)"
        }
    }

    private func beginPendingStrokeReconciliationIfNeeded() {
        if pendingCommitStrokes.isEmpty {
            replayPendingErases()
            return
        }
        guard isConnected,
              !journalBlocked,
              let documentID = connectedDocumentID,
              documentID == pendingDocumentID,
              !isReconcilingPendingStrokes,
              !pendingCommitStrokes.isEmpty else { return }

        let ordered = pendingCommitStrokes.values.sorted { lhs, rhs in
            let leftTime = lhs.points.first?.t ?? 0
            let rightTime = rhs.points.first?.t ?? 0
            if leftTime == rightTime { return lhs.id < rhs.id }
            return leftTime < rightTime
        }

        var batch: [NoteStroke] = []
        var estimatedBytes = 96 // envelope and JSON punctuation
        for stroke in ordered {
            guard let strokeData = try? JSONHelpers.encoder.encode(stroke) else {
                lastError = "Could not encode disconnected Pencil progress"
                return
            }
            let projectedBytes = estimatedBytes + strokeData.count + (batch.isEmpty ? 0 : 1)
            if !batch.isEmpty,
               (batch.count >= Self.maximumReconciliationBatchStrokes ||
                projectedBytes > Self.maximumReconciliationBatchBytes) {
                break
            }
            batch.append(stroke)
            estimatedBytes = projectedBytes
        }

        guard !batch.isEmpty,
              let encoded = try? JSONHelpers.object(from: batch) else {
            lastError = "Could not encode disconnected Pencil progress"
            return
        }
        isReconcilingPendingStrokes = true
        DebugSessionLogger.shared.event(
            "reconciliation",
            "batch_started",
            fields: [
                "batchStrokeCount": batch.count,
                "pendingStrokeCount": pendingCommitStrokes.count,
                "estimatedByteCount": estimatedBytes,
            ]
        )
        notice = pendingCommitStrokes.count == batch.count
            ? "Restoring disconnected Pencil progress…"
            : "Restoring disconnected Pencil progress (\(batch.count) of \(pendingCommitStrokes.count))…"
        client.sendJSONObject([
            "type": "reconcile_strokes",
            "documentId": documentID,
            "strokes": encoded,
        ])
    }

    private func fetchRevisionChanges(documentID: String, sinceRevision: Int, serverToken: String) {
        stateFetchTask?.cancel()
        stateFetchGeneration &+= 1
        let generation = stateFetchGeneration
        let mutationGeneration = syncMutationGeneration
        DebugSessionLogger.shared.event(
            "sync", "delta_fetch_started",
            fields: ["documentId": documentID, "sinceRevision": sinceRevision]
        )
        requestRevisionPage(
            documentID: documentID, baseRevision: sinceRevision, cursor: sinceRevision,
            serverToken: serverToken,
            generation: generation, mutationGeneration: mutationGeneration,
            remainingPages: 8, delta: RevisionDeltaAccumulator<NoteStroke>()
        )
    }

    private func requestRevisionPage(
        documentID: String,
        baseRevision: Int,
        cursor: Int,
        serverToken: String,
        generation: Int,
        mutationGeneration: Int,
        remainingPages: Int,
        delta: RevisionDeltaAccumulator<NoteStroke>
    ) {
        guard let url = endpoint(path: "/api/changes", queryItems: [
            URLQueryItem(name: "documentId", value: documentID),
            URLQueryItem(name: "sinceRevision", value: String(cursor)),
        ]) else {
            fetchNotebookState(reason: "delta_invalid_url")
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if (error as NSError?)?.code == NSURLErrorCancelled { return }
            let page: RevisionDeltaResponse?
            if error == nil, let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode), let data {
                page = try? JSONDecoder().decode(RevisionDeltaResponse.self, from: data)
            } else {
                page = nil
            }
            Task { @MainActor in
                guard generation == self.stateFetchGeneration else { return }
                guard self.connectedDocumentID == documentID,
                      self.lastAppliedDocumentID == documentID,
                      self.lastAppliedDocumentRevision == baseRevision,
                      !self.hasPendingEdits,
                      self.liveStrokeIDs.isEmpty,
                      self.syncMutationGeneration == mutationGeneration else {
                    self.fallbackRevisionChanges(reason: "local_or_live_edit")
                    return
                }
                guard let page, page.documentId == documentID,
                      page.fromRevision == cursor,
                      let nextRevision = page.nextRevision,
                      nextRevision > cursor,
                      nextRevision <= page.documentRevision,
                      let stateToken = page.stateToken,
                      RevisionDeltaSafety.sameServerInstance(stateToken, serverToken),
                      let pageUpserts = page.upserts,
                      let pageDeletes = page.deletes,
                      (page.status == "more" || page.status == "complete") else {
                    self.fallbackRevisionChanges(reason: "missing_or_invalid_delta")
                    return
                }
                var merged = delta
                guard merged.append(upserts: pageUpserts, deletes: pageDeletes) else {
                    self.fallbackRevisionChanges(reason: "invalid_stroke_delta")
                    return
                }
                if page.status == "more" {
                    guard nextRevision < page.documentRevision, remainingPages > 1 else {
                        self.fallbackRevisionChanges(reason: "delta_page_limit")
                        return
                    }
                    self.requestRevisionPage(
                        documentID: documentID, baseRevision: baseRevision,
                        cursor: nextRevision, serverToken: serverToken,
                        generation: generation,
                        mutationGeneration: mutationGeneration,
                        remainingPages: remainingPages - 1,
                        delta: merged
                    )
                    return
                }
                guard nextRevision == page.documentRevision else {
                    self.fallbackRevisionChanges(reason: "incomplete_delta")
                    return
                }
                for id in merged.deletes { self.removeStroke(id: id) }
                for stroke in merged.upserts.values { self.insertOrReplace(stroke) }
                self.lastAppliedDocumentID = documentID
                self.lastAppliedDocumentRevision = nextRevision
                self.lastAppliedStateToken = stateToken
                self.notice = "Notebook synchronized"
                self.lastError = nil
                self.stateFetchTask = nil
                DebugSessionLogger.shared.event(
                    "sync", "delta_fetch_completed",
                    fields: ["documentRevision": nextRevision,
                             "upsertCount": merged.upserts.count,
                             "deleteCount": merged.deletes.count]
                )
            }
        }
        stateFetchTask = task
        task.resume()
    }

    private func fallbackRevisionChanges(reason: String) {
        DebugSessionLogger.shared.event("sync", "delta_fetch_fallback", fields: ["reason": reason])
        fetchNotebookState(reason: "delta_fallback")
    }

    private func scheduleDeferredStateFetch() {
        guard deferredStateRefreshReason != nil else { return }
        deferredFetchWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deferredFetchWorkItem = nil
            guard let reason = self.deferredStateRefreshReason,
                  self.connectedDocumentID != nil,
                  !self.hasPendingEdits,
                  !self.isReconcilingPendingStrokes,
                  self.liveStrokeIDs.isEmpty else { return }
            self.deferredStateRefreshReason = nil
            self.fetchNotebookState(reason: reason)
        }
        deferredFetchWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func fetchNotebookState(reason: String) {
        guard let stateURL = endpoint(path: "/api/state") else {
            lastError = "The computer server address is invalid"
            return
        }

        deferredFetchWorkItem?.cancel()
        deferredFetchWorkItem = nil
        deferredStateRefreshReason = nil
        stateFetchTask?.cancel()
        stateFetchGeneration &+= 1
        let generation = stateFetchGeneration
        let mutationGeneration = syncMutationGeneration
        let startedAt = ProcessInfo.processInfo.systemUptime
        DebugSessionLogger.shared.event(
            "sync",
            "state_fetch_started",
            fields: ["reason": reason, "generation": generation, "pendingStrokeCount": pendingCommitStrokes.count]
        )

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
                    DebugSessionLogger.shared.event(
                        "sync",
                        "state_fetch_failed",
                        fields: ["reason": reason, "generation": generation, "error": error.localizedDescription]
                    )
                    self.lastError = "Notebook sync failed: \(error.localizedDescription)"
                }
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                Task { @MainActor in
                    guard generation == self.stateFetchGeneration else { return }
                    DebugSessionLogger.shared.event("sync", "state_fetch_failed", fields: ["reason": reason, "generation": generation])
                    self.lastError = "The computer did not return the notebook state"
                }
                return
            }

            do {
                let snapshot = try JSONDecoder().decode(NotebookState.self, from: data)
                Task { @MainActor in
                    guard generation == self.stateFetchGeneration else { return }
                    guard self.syncMutationGeneration == mutationGeneration,
                          self.liveStrokeIDs.isEmpty,
                          !self.hasPendingEdits else {
                        self.deferredStateRefreshReason = reason
                        self.scheduleDeferredStateFetch()
                        DebugSessionLogger.shared.event(
                            "sync", "state_fetch_deferred_after_edit",
                            fields: ["reason": reason, "generation": generation]
                        )
                        return
                    }
                    guard self.applySnapshot(snapshot, liveIDs: []) else { return }
                    DebugSessionLogger.shared.event(
                        "sync",
                        "state_fetch_completed",
                        fields: [
                            "reason": reason,
                            "generation": generation,
                            "byteCount": data.count,
                            "durationMs": (ProcessInfo.processInfo.systemUptime - startedAt) * 1000,
                            "strokeCount": snapshot.strokes.count,
                            "pageCount": snapshot.document.pages.count,
                            "pendingStrokeCount": self.pendingCommitStrokes.count,
                            "stateToken": snapshot.stateToken ?? "",
                            "documentRevision": snapshot.documentRevision ?? 0,
                        ]
                    )
                    if reason == "project_import" {
                        self.notice = "Project loaded"
                    } else if reason == "page_mutation" {
                        self.notice = "Page updated"
                    } else {
                        self.notice = "Notebook synchronized"
                    }
                    self.lastError = nil
                    if !snapshot.document.pages.isEmpty {
                        self.fetchSourcePDF()
                    }
                }
            } catch {
                Task { @MainActor in
                    guard generation == self.stateFetchGeneration else { return }
                    DebugSessionLogger.shared.event(
                        "sync",
                        "state_decode_failed",
                        fields: ["reason": reason, "generation": generation, "byteCount": data.count]
                    )
                    self.lastError = "Could not decode the notebook state: \(error.localizedDescription)"
                }
            }
        }
        stateFetchTask = task
        task.resume()
    }

    private func applySnapshot(_ snapshot: NotebookState, liveIDs: Set<String>) -> Bool {
        if hasPendingEdits, pendingDocumentID != snapshot.documentId {
            lastError = "Pending edits belong to another notebook. Reopen that notebook to restore them."
            return false
        }
        if lastAppliedDocumentID != snapshot.documentId {
            whiteboardVisibleSections = (left: 2, right: 2, top: 2, bottom: 2)
        }
        document = snapshot.document
        if !hasPendingEdits { pendingDocumentID = snapshot.documentId }
        lastAppliedDocumentID = snapshot.documentId
        lastAppliedDocumentRevision = snapshot.documentRevision
        lastAppliedStateToken = snapshot.stateToken
        var mergedStrokes = snapshot.strokes
        for (id, stroke) in pendingCommitStrokes {
            mergedStrokes[id] = stroke
        }
        for id in pendingErases.erasedIDs { mergedStrokes.removeValue(forKey: id) }
        strokes = mergedStrokes
        liveStrokes.reset(remoteIDs: liveIDs)
        selectedStrokeIDs = Set(selectedStrokeIDs.filter { strokes[$0] != nil })
        rebuildPageIndex()
        rebuildAllWorkspaceStates()
        invalidateAllPages()
        return true
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
        let startedAt = ProcessInfo.processInfo.systemUptime
        DebugSessionLogger.shared.event("page", "mutation_started", fields: ["path": path])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    DebugSessionLogger.shared.event("page", "mutation_failed", fields: ["path": path, "error": error.localizedDescription])
                    self.lastError = "Page update failed: \(error.localizedDescription)"
                }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                Task { @MainActor in self.lastError = "The computer did not return a page-update response" }
                return
            }
            if !(200..<300).contains(http.statusCode) {
                let detail = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["detail"] as? String
                Task { @MainActor in self.lastError = detail ?? "Page update failed (HTTP \(http.statusCode))" }
                return
            }

            // The HTTP mutation response is authoritative. Previously the iPad
            // waited for document_changed over WebSocket; if that notification
            // was delayed or missed, Add Page Below appeared to do nothing even
            // though the server had already modified the PDF. Refresh the state
            // after every successful page mutation and preserve the returned page
            // as the navigation target.
            let payload = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let pageNumber = (payload?["pageNumber"] as? NSNumber)?.intValue
            Task { @MainActor in
                if let pageNumber, pageNumber > 0 {
                    self.currentPageNumber = pageNumber
                }
                self.lastError = nil
                DebugSessionLogger.shared.event(
                    "page",
                    "mutation_completed",
                    fields: [
                        "path": path,
                        "pageNumber": pageNumber ?? 0,
                        "durationMs": (ProcessInfo.processInfo.systemUptime - startedAt) * 1000,
                    ]
                )
                self.fetchNotebookState(reason: "page_mutation")
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

    private func discardInterruptedRemoteStrokes() {
        let interrupted = liveStrokes.disconnect()
        guard !interrupted.isEmpty else { return }
        for id in interrupted { removeStroke(id: id) }
        // These previews were not part of a fully applied durable snapshot.
        lastAppliedDocumentRevision = nil
    }

    private func insertOrReplace(_ stroke: NoteStroke, committedChange: Bool = true) {
        guard !pendingErases.erasedIDs.contains(stroke.id) else { return }
        syncMutationGeneration &+= 1
        let oldPages = strokeMembership[stroke.id] ?? []
        for page in oldPages { pageStrokeIDs[page]?.remove(stroke.id) }
        strokes[stroke.id] = stroke
        let pages = membership(for: stroke)
        strokeMembership[stroke.id] = pages
        for page in pages { pageStrokeIDs[page, default: []].insert(stroke.id) }
        if committedChange {
            updateEraserIndex(stroke, pages: pages)
        } else {
            eraserIndex.remove(stroke.id)
            eraserDirtyIDs.insert(stroke.id)
        }
        let affectedPages = oldPages.union(pages)
        if committedChange || !oldPages.subtracting(pages).isEmpty {
            refreshWorkspaceStates(for: affectedPages)
        } else {
            expandWorkspaceStates(for: stroke, pages: pages)
        }
        invalidatePages(affectedPages, committedChange: committedChange)
    }

    private func removeStroke(id: String) {
        removeStrokes(ids: [id])
    }

    private func removeStrokes(ids: [String]) {
        guard !ids.isEmpty else { return }
        syncMutationGeneration &+= 1
        var pages: Set<Int> = []
        for id in ids {
            let membership = strokeMembership.removeValue(forKey: id) ?? []
            pages.formUnion(membership)
            strokes.removeValue(forKey: id)
            eraserIndex.remove(id)
            eraserDirtyIDs.remove(id)
            liveStrokes.end(id)
            pendingPointBatches.removeValue(forKey: id)
            for page in membership { pageStrokeIDs[page]?.remove(id) }
        }
        let removed = Set(ids)
        if !selectedStrokeIDs.isDisjoint(with: removed) { selectedStrokeIDs.subtract(removed) }
        refreshWorkspaceStates(for: pages)
        for page in pages {
            cleanupWeakViews(pageIndex: page)
            for view in weakPageViews[page] ?? [] { view.value?.removeCommittedStrokes(removed) }
        }
    }

    private func updateEraserIndex(_ stroke: NoteStroke, pages: Set<Int>) {
        eraserDirtyIDs.remove(stroke.id)
        if !stroke.isLocked, let geometry = GeometryEngine.eraserGeometry(stroke) {
            eraserIndex.update(id: stroke.id, geometry: geometry, pages: pages)
        } else { eraserIndex.remove(stroke.id) }
    }

    private func rebuildPageIndex() {
        pageStrokeIDs.removeAll(keepingCapacity: true)
        strokeMembership.removeAll(keepingCapacity: true)
        eraserIndex = EraserSpatialIndex()
        eraserDirtyIDs.removeAll()
        for stroke in strokes.values {
            let pages = membership(for: stroke)
            strokeMembership[stroke.id] = pages
            for page in pages { pageStrokeIDs[page, default: []].insert(stroke.id) }
            updateEraserIndex(stroke, pages: pages)
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

}

private final class WeakPageView {
    weak var value: InkPageView?
    init(_ value: InkPageView) { self.value = value }
}
