(() => {
  "use strict";

  const params = new URLSearchParams(location.search);
  const mode = params.get("mode") || (navigator.maxTouchPoints > 1 ? "ipad" : "desktop");
  document.body.classList.add(mode);

  const sceneCanvas = document.getElementById("sceneCanvas");
  const canvas = document.getElementById("canvas");
  const sceneCtx = sceneCanvas.getContext("2d", { alpha: false, desynchronized: true });
  const liveCtx = canvas.getContext("2d", { alpha: true, desynchronized: true });
  const statusEl = document.getElementById("status");
  const pressureEl = document.getElementById("pressure");
  const dotEl = document.getElementById("connectionDot");
  const nameEl = document.getElementById("documentName");
  const widthEl = document.getElementById("width");
  const colorEl = document.getElementById("color");
  const toastEl = document.getElementById("toast");
  const widthValueEl = document.getElementById("widthValue");
  const smoothingEl = document.getElementById("smoothing");
  const smoothingValueEl = document.getElementById("smoothingValue");
  const strokeDetailEl = document.getElementById("strokeDetail");
  const strokeDetailValueEl = document.getElementById("strokeDetailValue");
  const eraserSizeEl = document.getElementById("eraserSize");
  const eraserSizeValueEl = document.getElementById("eraserSizeValue");
  const eraserCursorEl = document.getElementById("eraserCursor");
  const sampleStatusEl = document.getElementById("sampleStatus");
  const inputPathStatusEl = document.getElementById("inputPathStatus");
  const inputEventStatusEl = document.getElementById("inputEventStatus");
  const undoButton = document.getElementById("undoButton");
  const redoButton = document.getElementById("redoButton");
  const settingsButton = document.getElementById("settingsButton");
  const closeSettingsButton = document.getElementById("closeSettingsButton");
  const settingsScrim = document.getElementById("settingsScrim");
  const connectionButton = document.getElementById("connectionButton");
  const debugToggle = document.getElementById("debugToggle");
  const debugPanel = document.getElementById("debugPanel");
  const closeDebugButton = document.getElementById("closeDebugButton");
  const projectImportInput = document.getElementById("projectImportInput");
  const projectExportButton = document.getElementById("projectExportButton");
  const pdfExportButton = document.getElementById("pdfExportButton");
  const addPageButton = document.getElementById("addPageButton");
  const syncNowButton = document.getElementById("syncNowButton");
  const autoSyncIntervalEl = document.getElementById("autoSyncInterval");
  const lastSyncStatusEl = document.getElementById("lastSyncStatus");
  const pendingSyncStatusEl = document.getElementById("pendingSyncStatus");
  const syncSummaryEl = document.getElementById("syncSummary");
  const recognitionHoldMsEl = document.getElementById("recognitionHoldMs");
  const recognitionHoldMsValueEl = document.getElementById("recognitionHoldMsValue");
  const lineRecognitionToleranceEl = document.getElementById("lineRecognitionTolerance");
  const lineRecognitionToleranceValueEl = document.getElementById("lineRecognitionToleranceValue");
  const curveRecognitionToleranceEl = document.getElementById("curveRecognitionTolerance");
  const curveRecognitionToleranceValueEl = document.getElementById("curveRecognitionToleranceValue");
  const geometrySnapDistanceEl = document.getElementById("geometrySnapDistance");
  const geometrySnapDistanceValueEl = document.getElementById("geometrySnapDistanceValue");
  const endpointSnapToggle = document.getElementById("endpointSnapToggle");
  const axisSnapToggle = document.getElementById("axisSnapToggle");
  const tangentSnapToggle = document.getElementById("tangentSnapToggle");
  const normalSnapToggle = document.getElementById("normalSnapToggle");

  const drawModeButton = document.getElementById("drawModeButton");
  const eraserModeButton = document.getElementById("eraserModeButton");
  const selectorModeButton = document.getElementById("selectorModeButton");
  const textModeButton = document.getElementById("textModeButton");
  const shapeModeButton = document.getElementById("shapeModeButton");
  const planeModeButton = document.getElementById("planeModeButton");
  const drawContextRow = document.getElementById("drawContextRow");
  const eraserContextRow = document.getElementById("eraserContextRow");
  const selectionContextRow = document.getElementById("selectionContextRow");
  const textContextRow = document.getElementById("textContextRow");
  const shapeContextRow = document.getElementById("shapeContextRow");
  const textFontSizeEl = document.getElementById("textFontSize");
  const textFontSizeValueEl = document.getElementById("textFontSizeValue");
  const textColorEl = document.getElementById("textColor");
  const textAlignSelector = document.getElementById("textAlignSelector");
  const textEditorLayer = document.getElementById("textEditorLayer");
  const textEditorInput = document.getElementById("textEditorInput");
  const textEditorDone = document.getElementById("textEditorDone");
  const textEditorCancel = document.getElementById("textEditorCancel");
  const selectionCount = document.getElementById("selectionCount");
  const selectionCopyButton = document.getElementById("selectionCopyButton");
  const selectionPasteButton = document.getElementById("selectionPasteButton");
  const selectionDeleteButton = document.getElementById("selectionDeleteButton");
  const selectionPlaneLockButton = document.getElementById("selectionPlaneLockButton");
  const drawPresetStrip = document.getElementById("drawPresetStrip");
  const eraserPresetStrip = document.getElementById("eraserPresetStrip");
  const colorStrip = document.getElementById("colorStrip");
  const addColorButton = document.getElementById("addColorButton");
  const eraserOptionsButton = document.getElementById("eraserOptionsButton");

  const presetPopover = document.getElementById("presetPopover");
  const presetPopoverTitle = document.getElementById("presetPopoverTitle");
  const presetPopoverSubtitle = document.getElementById("presetPopoverSubtitle");
  const closePresetPopover = document.getElementById("closePresetPopover");
  const presetWidthInput = document.getElementById("presetWidthInput");
  const presetWidthOutput = document.getElementById("presetWidthOutput");
  const presetWidthLabel = document.getElementById("presetWidthLabel");
  const lineStyleEditor = document.getElementById("lineStyleEditor");
  const pressurePresetField = document.getElementById("pressurePresetField");
  const presetPressureToggle = document.getElementById("presetPressureToggle");

  const colorPopover = document.getElementById("colorPopover");
  const closeColorPopover = document.getElementById("closeColorPopover");
  const savedColorEditor = document.getElementById("savedColorEditor");
  const deleteColorButton = document.getElementById("deleteColorButton");
  const doneColorButton = document.getElementById("doneColorButton");

  const eraserOptionsPopover = document.getElementById("eraserOptionsPopover");
  const closeEraserOptions = document.getElementById("closeEraserOptions");
  const eraserHighlighterOnlyToggle =
    document.getElementById("eraserHighlighterOnlyToggle");
  const debugEls = {
    tool: document.getElementById("debugTool"),
    inputPath: document.getElementById("debugInputPath"),
    pointer: document.getElementById("debugPointer"),
    pressure: document.getElementById("debugPressure"),
    strokeSamples: document.getElementById("debugStrokeSamples"),
    lastInput: document.getElementById("debugLastInput"),
    acceptedRate: document.getElementById("debugAcceptedRate"),
    pointerRate: document.getElementById("debugPointerRate"),
    touchRate: document.getElementById("debugTouchRate"),
    coalesced: document.getElementById("debugCoalesced"),
    emptyCoalesced: document.getElementById("debugEmptyCoalesced"),
    duplicates: document.getElementById("debugDuplicates"),
    strokeDetail: document.getElementById("debugStrokeDetail"),
    lineThreshold: document.getElementById("debugLineThreshold"),
    curveThreshold: document.getElementById("debugCurveThreshold"),
    recognitionHold: document.getElementById("debugRecognitionHold"),
    recognitionResult: document.getElementById("debugRecognitionResult"),
    snapResult: document.getElementById("debugSnapResult"),
    starts: document.getElementById("debugStarts"),
    fallbacks: document.getElementById("debugFallbacks"),
    cancels: document.getElementById("debugCancels"),
    lostCapture: document.getElementById("debugLostCapture"),
    pointerMoves: document.getElementById("debugPointerMoves"),
    touchMoves: document.getElementById("debugTouchMoves"),
    deferredTouchEnds: document.getElementById("debugDeferredTouchEnds"),
    forcedRestarts: document.getElementById("debugForcedRestarts"),
    capturedDowns: document.getElementById("debugCapturedDowns"),
    recoveredStarts: document.getElementById("debugRecoveredStarts"),
    contactMovesNoDown: document.getElementById("debugContactMovesNoDown"),
    staleReleases: document.getElementById("debugStaleReleases"),
    socket: document.getElementById("debugSocket"),
    buffered: document.getElementById("debugBuffered"),
    queued: document.getElementById("debugQueued"),
    fps: document.getElementById("debugFps"),
    zoom: document.getElementById("debugZoom"),
    viewport: document.getElementById("debugViewport"),
    eventLog: document.getElementById("debugEventLog"),
  };

  function storedNumber(key, fallback, minimum, maximum) {
    try {
      const raw = localStorage.getItem(key);
      if (raw === null) return fallback;
      const value = Number(raw);
      return Number.isFinite(value) ? Math.max(minimum, Math.min(maximum, value)) : fallback;
    } catch {
      return fallback;
    }
  }

  function storeSetting(key, value) {
    try { localStorage.setItem(key, String(value)); }
    catch {}
  }


  function storedString(key, fallback) {
    try {
      const value = localStorage.getItem(key);
      return value === null ? fallback : value;
    } catch {
      return fallback;
    }
  }

  function storedJson(key, fallback) {
    try {
      const value = localStorage.getItem(key);
      if (value === null) return structuredClone(fallback);
      return JSON.parse(value);
    } catch {
      return structuredClone(fallback);
    }
  }

  function storeJson(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); }
    catch {}
  }

  const IPAD_VIEW_KEY = "infiniteNotes.ipadView.v1";
  let cameraSaveTimer = null;
  let lastCameraSignature = "";

  function documentStateKey(documentState) {
    const documentValue = documentState || {};
    const pages = Array.isArray(documentValue.pages) ? documentValue.pages : [];
    return JSON.stringify({
      filename: documentValue.filename || null,
      pages: pages.map(page => [
        Number(page.pageNumber) || 0,
        Number(page.x) || 0,
        Number(page.y) || 0,
        Number(page.width) || 0,
        Number(page.height) || 0,
      ]),
    });
  }

  function validCamera(value) {
    if (!value || typeof value !== "object") return null;
    const x = Number(value.x);
    const y = Number(value.y);
    const zoom = Number(value.zoom);
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(zoom)) return null;
    return { x, y, zoom: Math.max(0.08, Math.min(8, zoom)) };
  }

  const DEFAULT_PEN_PRESETS = [
    { width: 1.5, style: "solid", pressure: true },
    { width: 3.0, style: "solid", pressure: true },
    { width: 5.5, style: "solid", pressure: true },
  ];

  const DEFAULT_HIGHLIGHTER_PRESETS = [
    { width: 12, style: "solid", pressure: false },
    { width: 20, style: "solid", pressure: false },
    { width: 28, style: "solid", pressure: false },
  ];

  const DEFAULT_ERASER_PRESETS = [
    { size: 20 },
    { size: 36 },
    { size: 56 },
  ];

  const DEFAULT_COLORS = [
    { id: "default-black", value: "#111111" },
  ];

  function newOperationId(prefix = "delete") {
    const suffix = crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`;
    return `${prefix}-${suffix}`;
  }

  function loadPendingDeleteOperations() {
    const operations = new Map();
    const raw = storedJson("infiniteNotes.pendingDeleteOperations.v2", []);
    if (Array.isArray(raw)) {
      for (const item of raw) {
        if (!item || typeof item !== "object") continue;
        const id = String(item.id || "").slice(0, 128);
        const ids = Array.isArray(item.ids)
          ? [...new Set(item.ids.map(value => String(value || "")).filter(Boolean))]
          : [];
        if (!id) continue;
        // A browser reload ends any in-progress eraser contact. Mark restored
        // operations final so the server can commit the grouped undo action,
        // even when every deleted ID was already acknowledged before Safari froze.
        operations.set(id, {
          id,
          ids: new Set(ids),
          final: true,
          createdAt: Number(item.createdAt) || Date.now(),
        });
      }
    }

    // Migrate v15-v17's per-ID queue into one finalized retryable operation.
    const legacy = storedJson("infiniteNotes.pendingDeleteIds", []);
    if (Array.isArray(legacy) && legacy.length) {
      const ids = [...new Set(legacy.map(value => String(value || "")).filter(Boolean))];
      if (ids.length) {
        const id = newOperationId("legacy-delete");
        operations.set(id, { id, ids: new Set(ids), final: true, createdAt: Date.now() });
      }
      try { localStorage.removeItem("infiniteNotes.pendingDeleteIds"); } catch {}
    }
    return operations;
  }

  const clientId = crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`;
  let socket = null;
  let reconnectTimer = null;
  let toastTimer = null;
  let autoSyncTimer = null;
  const handledPenDownEvents = new WeakSet();

  const state = {
    document: { filename: null, pages: [] },
    strokes: new Map(),
    images: new Map(),
    liveStrokeIds: new Set(),
    tool: "pen",
    camera: { x: -150, y: -100, zoom: 0.9 },
    activeStrokeId: null,
    activePointerId: null,
    mousePanning: false,
    lastMouse: null,
    touches: new Map(),
    gesture: null,
    lastPenEventAt: -Infinity,
    sceneDirty: true,
    liveDirty: true,
    fitDone: false,
    dpr: 1,
    pendingPointBatches: new Map(),
    pointFlushTimer: null,
    canUndo: false,
    canRedo: false,
    activePointerDownTimestamp: -Infinity,
    activeFilterPoint: null,
    eraserDeletedIds: new Set(),
    activeEraseOperationId: null,
    pendingDeleteOperations: loadPendingDeleteOperations(),
    deleteFlushTimer: null,
    awaitingInitialSnapshot: true,
    manualSyncPending: false,
    lastSyncAt: null,
    autoSyncSeconds: storedNumber("infiniteNotes.autoSyncSeconds", 0, 0, 3600),
    selectionIds: new Set(),
    selectionGesture: null,
    selectionClipboard: [],
    selectionPasteSerial: 0,
    temporarySelectionReturnMode: null,
    pendingFingerInteraction: null,
    textEdit: null,
    textFontSize: storedNumber("infiniteNotes.textFontSize", 24, 8, 100),
    textColor: storedString("infiniteNotes.textColor", "#111111"),
    textAlign: storedString("infiniteNotes.textAlign", "left"),
    shapeType: storedString("infiniteNotes.shapeType", "rectangle"),
    shapeGesture: null,
    snapGuide: null,
    recognitionTimer: null,
    activeRawPoints: [],
    activeOriginalTool: null,
    recognitionHoldMs: storedNumber("infiniteNotes.recognitionHoldMs", 700, 150, 1600),
    lineRecognitionTolerance: storedNumber("infiniteNotes.lineRecognitionTolerance", 7, 1, 60),
    curveRecognitionTolerance: storedNumber("infiniteNotes.curveRecognitionTolerance", 13, 2, 35),
    geometrySnapDistance: storedNumber("infiniteNotes.geometrySnapDistance", 14, 4, 32),
    endpointSnap: storedNumber("infiniteNotes.endpointSnap", 1, 0, 1) === 1,
    axisSnap: storedNumber("infiniteNotes.axisSnap", 1, 0, 1) === 1,
    tangentSnap: storedNumber("infiniteNotes.tangentSnap", 1, 0, 1) === 1,
    normalSnap: storedNumber("infiniteNotes.normalSnap", 1, 0, 1) === 1,
    lastRecognitionResult: "None",
    lastSnapResult: "None",
    smoothing: storedNumber("infiniteNotes.smoothing", 35, 0, 100),
    strokeDetail: storedNumber("infiniteNotes.strokeDetail", 80, 0, 100),
    panFingers: storedNumber("infiniteNotes.panFingers", 1, 1, 2),
    eraserSize: storedNumber("infiniteNotes.eraserSize", 30, 12, 80),

    toolbarMode: storedString("infiniteNotes.toolbarMode", "draw"),
    drawTool: storedString("infiniteNotes.drawTool", "pen"),
    penPresetIndex: storedNumber("infiniteNotes.penPresetIndex", 1, 0, 2),
    highlighterPresetIndex: storedNumber("infiniteNotes.highlighterPresetIndex", 1, 0, 2),
    eraserPresetIndex: storedNumber("infiniteNotes.eraserPresetIndex", 1, 0, 2),
    penPresets: storedJson("infiniteNotes.penPresets", DEFAULT_PEN_PRESETS),
    highlighterPresets: storedJson(
      "infiniteNotes.highlighterPresets",
      DEFAULT_HIGHLIGHTER_PRESETS
    ),
    eraserPresets: storedJson(
      "infiniteNotes.eraserPresets",
      DEFAULT_ERASER_PRESETS
    ),
    colors: storedJson("infiniteNotes.colors", DEFAULT_COLORS),
    activeColorId: storedString(
      "infiniteNotes.activeColorId",
      "default-black"
    ),
    lineStyle: "solid",
    eraserHighlighterOnly:
      storedNumber("infiniteNotes.eraserHighlighterOnly", 0, 0, 1) === 1,
    sampleCount: 0,
    activeInputSource: null,
    activeTouchIdentifier: null,
    contactGeneration: 0,
    stylusTouches: new Map(),
    lastPointerSampleAt: -Infinity,
    lastStylusTouchAt: -Infinity,
    inputPath: "Waiting",
    debugEnabled: storedNumber("infiniteNotes.debugEnabled", 0, 0, 1) === 1,
    debugLog: [],
    debugRates: {
      acceptedTotal: 0,
      pointerEventTotal: 0,
      touchEventTotal: 0,
      lastAcceptedTotal: 0,
      lastPointerEventTotal: 0,
      lastTouchEventTotal: 0,
      acceptedHz: 0,
      pointerHz: 0,
      touchHz: 0,
      lastRateAt: performance.now(),
    },
    renderStats: {
      frames: 0,
      fps: 0,
      lastAt: performance.now(),
    },
    inputStats: {
      starts: 0,
      pointerMoves: 0,
      touchMoves: 0,
      fallbacks: 0,
      cancels: 0,
      lostCapture: 0,
      duplicates: 0,
      coalescedCalls: 0,
      coalescedSamples: 0,
      emptyCoalesced: 0,
      deferredTouchEnds: 0,
      forcedRestarts: 0,
      capturedDowns: 0,
      recoveredStarts: 0,
      contactMovesNoDown: 0,
      staleReleases: 0,
    },
  };

  if (!/^#[0-9a-f]{6}$/i.test(state.textColor)) state.textColor = "#111111";
  if (!["left", "center", "right"].includes(state.textAlign)) state.textAlign = "left";
  if (!["draw", "eraser", "select", "text", "shape"].includes(state.toolbarMode)) state.toolbarMode = "draw";
  if (!["rectangle", "square", "ellipse", "circle", "triangle", "diamond", "line", "arrow", "curve"].includes(state.shapeType)) state.shapeType = "rectangle";

  if (storedString("infiniteNotes.syncModelVersion", "") !== "v18") {
    state.autoSyncSeconds = 0;
    storeSetting("infiniteNotes.autoSyncSeconds", 0);
    storeSetting("infiniteNotes.syncModelVersion", "v18");
  }

  // v20 deliberately keeps synchronization incremental. The v17 full-state
  // IndexedDB snapshot copied every stroke on the main thread and could stall
  // Safari on large notebooks. View persistence remains separate below.
  function markIpadStateDirty() {}
  function flushIpadCache() {}

  function restoreSavedIpadView(documentState) {
    if (mode !== "ipad") return false;
    const saved = storedJson(IPAD_VIEW_KEY, null);
    if (!saved || saved.documentKey !== documentStateKey(documentState)) return false;
    const camera = validCamera(saved.camera);
    if (!camera) return false;
    state.camera = camera;
    state.fitDone = true;
    return true;
  }

  function persistIpadView() {
    if (mode !== "ipad" || !state.document.pages?.length) return;
    storeJson(IPAD_VIEW_KEY, {
      documentKey: documentStateKey(state.document),
      camera: state.camera,
      savedAt: new Date().toISOString(),
    });
  }

  function scheduleIpadViewSave() {
    if (mode !== "ipad") return;
    if (cameraSaveTimer !== null) clearTimeout(cameraSaveTimer);
    cameraSaveTimer = setTimeout(() => {
      cameraSaveTimer = null;
      persistIpadView();
    }, 350);
  }

  function showToast(message, ms = 2200) {
    toastEl.textContent = message;
    toastEl.classList.add("visible");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toastEl.classList.remove("visible"), ms);
  }

  function setStatus(text, type = "") {
    statusEl.textContent = text;
    dotEl.className = `status-dot ${type}`;
    connectionButton?.setAttribute("aria-label", `Connection: ${text}`);
    connectionButton?.setAttribute("title", `Connection: ${text}`);
  }

  function updateHistoryButtons() {
    undoButton.disabled = !state.canUndo;
    redoButton.disabled = !state.canRedo;
  }

  function updateInputDiagnostics(path = null) {
    if (path) state.inputPath = path;
    if (inputPathStatusEl) inputPathStatusEl.textContent = state.inputPath;
    const stats = state.inputStats;
    if (inputEventStatusEl) {
      inputEventStatusEl.textContent = `${stats.starts} starts · ${stats.pointerMoves + stats.touchMoves} moves · ${stats.fallbacks} fallbacks`;
      inputEventStatusEl.title = `Pointer moves: ${stats.pointerMoves}; touch moves: ${stats.touchMoves}; captured downs: ${stats.capturedDowns}; recovered starts: ${stats.recoveredStarts}; cancels: ${stats.cancels}; lost capture: ${stats.lostCapture}; duplicate samples rejected: ${stats.duplicates}`;
    }
  }

  function toolLabel(tool) {
    if (tool === "pen") return "Pressure pen";
    if (tool === "fixed-pen") return "Fixed-width pen";
    if (tool === "highlighter") return "Highlighter";
    if (tool === "eraser") return "Eraser";
    if (tool === "selector") return "Ink selector";
    if (tool === "text") return "Text box";
    if (tool === "shape") return "Geometry";
    return tool || "—";
  }

  function socketLabel() {
    if (!socket) return "Not created";
    if (socket.readyState === WebSocket.CONNECTING) return "Connecting";
    if (socket.readyState === WebSocket.OPEN) return "Open";
    if (socket.readyState === WebSocket.CLOSING) return "Closing";
    return "Closed";
  }

  function formatBytes(value) {
    const bytes = Math.max(0, Number(value) || 0);
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
  }

  function debugLog(message) {
    const stamp = new Date().toLocaleTimeString([], { hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit" });
    state.debugLog.unshift(`${stamp}.${String(Math.floor(performance.now() % 1000)).padStart(3, "0")}  ${message}`);
    if (state.debugLog.length > 28) state.debugLog.length = 28;
  }

  function setDebugOpen(open) {
    const enabled = Boolean(open && mode === "ipad");
    state.debugEnabled = enabled;
    document.body.classList.toggle("debug-open", enabled);
    debugPanel?.setAttribute("aria-hidden", String(!enabled));
    if (debugToggle) debugToggle.checked = enabled;
    storeSetting("infiniteNotes.debugEnabled", enabled ? 1 : 0);
    if (enabled) {
      debugLog("Debug panel opened");
      updateDebugPanel(true);
    }
  }

  function pendingPointCount() {
    let total = 0;
    for (const points of state.pendingPointBatches.values()) total += points.length;
    return total;
  }

  function updateDebugRates(now = performance.now()) {
    const rates = state.debugRates;
    const elapsed = now - rates.lastRateAt;
    if (elapsed < 400) return;
    const seconds = elapsed / 1000;
    rates.acceptedHz = (rates.acceptedTotal - rates.lastAcceptedTotal) / seconds;
    rates.pointerHz = (rates.pointerEventTotal - rates.lastPointerEventTotal) / seconds;
    rates.touchHz = (rates.touchEventTotal - rates.lastTouchEventTotal) / seconds;
    rates.lastAcceptedTotal = rates.acceptedTotal;
    rates.lastPointerEventTotal = rates.pointerEventTotal;
    rates.lastTouchEventTotal = rates.touchEventTotal;
    rates.lastRateAt = now;
  }

  function updateDebugPanel(force = false) {
    if (!state.debugEnabled && !force) return;
    const now = performance.now();
    updateDebugRates(now);
    const stats = state.inputStats;
    const rates = state.debugRates;
    const lastInputAt = Math.max(state.lastPointerSampleAt, state.lastStylusTouchAt, state.lastPenEventAt);
    const lastInputAge = Number.isFinite(lastInputAt) && lastInputAt > 0 ? `${Math.max(0, now - lastInputAt).toFixed(0)} ms` : "—";
    const pointer = state.activePointerId !== null ? String(state.activePointerId) : "none";
    const source = state.activeInputSource || "idle";

    if (debugEls.tool) debugEls.tool.textContent = toolLabel(state.tool);
    if (debugEls.inputPath) debugEls.inputPath.textContent = state.inputPath;
    if (debugEls.pointer) debugEls.pointer.textContent = `${pointer} / ${source}`;
    if (debugEls.pressure) debugEls.pressure.textContent = pressureEl.textContent || "—";
    if (debugEls.strokeSamples) debugEls.strokeSamples.textContent = String(state.sampleCount || 0);
    if (debugEls.lastInput) debugEls.lastInput.textContent = lastInputAge;
    if (debugEls.acceptedRate) debugEls.acceptedRate.textContent = `${rates.acceptedHz.toFixed(1)} Hz`;
    if (debugEls.pointerRate) debugEls.pointerRate.textContent = `${rates.pointerHz.toFixed(1)} Hz`;
    if (debugEls.touchRate) debugEls.touchRate.textContent = `${rates.touchHz.toFixed(1)} Hz`;
    if (debugEls.coalesced) debugEls.coalesced.textContent = `${stats.coalescedSamples} / ${stats.coalescedCalls} calls`;
    if (debugEls.emptyCoalesced) debugEls.emptyCoalesced.textContent = String(stats.emptyCoalesced);
    if (debugEls.duplicates) debugEls.duplicates.textContent = String(stats.duplicates);
    if (debugEls.strokeDetail) {
      const spacing = retainedPointSpacingPx();
      const sampling = curveSamplingSettings();
      debugEls.strokeDetail.textContent = `${state.strokeDetail} · ${spacing.toFixed(2)} px input · ${sampling.screenStepPx.toFixed(2)} px curve`;
    }
    if (debugEls.lineThreshold) debugEls.lineThreshold.textContent = `${state.lineRecognitionTolerance}%`;
    if (debugEls.curveThreshold) debugEls.curveThreshold.textContent = `${state.curveRecognitionTolerance}%`;
    if (debugEls.recognitionHold) debugEls.recognitionHold.textContent = `${state.recognitionHoldMs} ms`;
    if (debugEls.recognitionResult) debugEls.recognitionResult.textContent = state.lastRecognitionResult;
    if (debugEls.snapResult) debugEls.snapResult.textContent = state.lastSnapResult;
    if (debugEls.starts) debugEls.starts.textContent = String(stats.starts);
    if (debugEls.fallbacks) debugEls.fallbacks.textContent = String(stats.fallbacks);
    if (debugEls.cancels) debugEls.cancels.textContent = String(stats.cancels);
    if (debugEls.lostCapture) debugEls.lostCapture.textContent = String(stats.lostCapture);
    if (debugEls.pointerMoves) debugEls.pointerMoves.textContent = String(stats.pointerMoves);
    if (debugEls.touchMoves) debugEls.touchMoves.textContent = String(stats.touchMoves);
    if (debugEls.deferredTouchEnds) debugEls.deferredTouchEnds.textContent = String(stats.deferredTouchEnds);
    if (debugEls.forcedRestarts) debugEls.forcedRestarts.textContent = String(stats.forcedRestarts);
    if (debugEls.capturedDowns) debugEls.capturedDowns.textContent = String(stats.capturedDowns);
    if (debugEls.recoveredStarts) debugEls.recoveredStarts.textContent = String(stats.recoveredStarts);
    if (debugEls.contactMovesNoDown) debugEls.contactMovesNoDown.textContent = String(stats.contactMovesNoDown);
    if (debugEls.staleReleases) debugEls.staleReleases.textContent = String(stats.staleReleases);
    if (debugEls.socket) debugEls.socket.textContent = socketLabel();
    if (debugEls.buffered) debugEls.buffered.textContent = formatBytes(socket?.bufferedAmount || 0);
    if (debugEls.queued) debugEls.queued.textContent = String(pendingPointCount());
    if (debugEls.fps) debugEls.fps.textContent = `${state.renderStats.fps.toFixed(1)} fps`;
    if (debugEls.zoom) debugEls.zoom.textContent = `${state.camera.zoom.toFixed(3)}×`;
    if (debugEls.viewport) debugEls.viewport.textContent = `${innerWidth}×${innerHeight} @ ${state.dpr.toFixed(2)} dpr`;
    if (debugEls.eventLog) debugEls.eventLog.textContent = state.debugLog.length ? state.debugLog.join("\n") : "Waiting for Pencil input…";
  }

  function setSettingsOpen(open) {
    document.body.classList.toggle("settings-open", open);
    settingsButton?.setAttribute("aria-expanded", String(open));
    document.getElementById("settingsPanel")?.setAttribute("aria-hidden", String(!open));
  }

  function pendingDeleteCount() {
    let total = 0;
    for (const operation of state.pendingDeleteOperations.values()) total += operation.ids.size;
    return total;
  }

  function persistPendingDeletes() {
    const value = [...state.pendingDeleteOperations.values()].map(operation => ({
      id: operation.id,
      ids: [...operation.ids],
      final: Boolean(operation.final),
      createdAt: operation.createdAt,
    }));
    storeJson("infiniteNotes.pendingDeleteOperations.v2", value);
    updateSyncUI();
  }

  function formatSyncTime(value) {
    if (!value) return "Not yet";
    try {
      return new Intl.DateTimeFormat([], {
        hour: "numeric",
        minute: "2-digit",
        second: "2-digit",
      }).format(value);
    } catch {
      return value.toLocaleTimeString();
    }
  }

  function updateSyncUI() {
    const pending = pendingDeleteCount();
    const operationCount = state.pendingDeleteOperations.size;
    if (lastSyncStatusEl) lastSyncStatusEl.textContent = formatSyncTime(state.lastSyncAt);
    if (pendingSyncStatusEl) {
      pendingSyncStatusEl.textContent = operationCount
        ? `${pending} deletion${pending === 1 ? "" : "s"} in ${operationCount} operation${operationCount === 1 ? "" : "s"} awaiting confirmation`
        : "None";
    }
    if (syncSummaryEl) {
      const interval = state.autoSyncSeconds === 0
        ? "Automatic refresh is off"
        : `Refresh every ${state.autoSyncSeconds < 60 ? `${state.autoSyncSeconds} seconds` : `${state.autoSyncSeconds / 60} minute${state.autoSyncSeconds === 60 ? "" : "s"}`}`;
      syncSummaryEl.textContent = `Ink changes sync incrementally. ${interval}. Last server refresh: ${formatSyncTime(state.lastSyncAt)}.`;
    }
  }

  function recordSuccessfulSync() {
    state.lastSyncAt = new Date();
    updateSyncUI();
  }

  function flushDeleteOperation(operation) {
    if (!operation || state.awaitingInitialSnapshot) return false;
    if (!operation.ids.size && !operation.final) return false;
    return send({
      type: "delete_strokes",
      operationId: operation.id,
      ids: [...operation.ids],
      final: Boolean(operation.final),
      reliable: true,
    });
  }

  function flushPendingDeletes() {
    if (state.awaitingInitialSnapshot || !state.pendingDeleteOperations.size) return false;
    let sent = false;
    for (const operation of state.pendingDeleteOperations.values()) {
      sent = flushDeleteOperation(operation) || sent;
    }
    updateSyncUI();
    return sent;
  }

  function scheduleDeleteFlush(delay = 24) {
    if (state.deleteFlushTimer !== null) return;
    state.deleteFlushTimer = setTimeout(() => {
      state.deleteFlushTimer = null;
      flushPendingDeletes();
    }, delay);
  }

  function ensureDeleteOperation(operationId = null) {
    const id = operationId || newOperationId("delete");
    let operation = state.pendingDeleteOperations.get(id);
    if (!operation) {
      operation = { id, ids: new Set(), final: false, createdAt: Date.now() };
      state.pendingDeleteOperations.set(id, operation);
    }
    return operation;
  }

  function queueReliableDeletes(ids, { operationId = null, final = true, defer = false } = {}) {
    const operation = ensureDeleteOperation(operationId);
    for (const rawId of ids || []) {
      const id = String(rawId || "");
      if (id) operation.ids.add(id);
    }
    operation.final = operation.final || Boolean(final);
    if (!operation.ids.size && !operation.final) {
      state.pendingDeleteOperations.delete(operation.id);
      return operation.id;
    }
    persistPendingDeletes();
    if (defer) scheduleDeleteFlush();
    else flushDeleteOperation(operation);
    return operation.id;
  }

  async function requestSync(manual = false) {
    if (state.textEdit) commitTextEdit();
    if (state.activeStrokeId || state.selectionGesture || state.activePointerId !== null) {
      if (manual) showToast("Finish the current Pencil gesture before refreshing", 3500);
      return false;
    }

    flushPendingPoints();
    flushPendingDeletes();
    state.manualSyncPending = state.manualSyncPending || manual;
    if (send({ type: "sync_request", clientTime: Date.now() })) {
      if (manual) showToast("Refreshing from the laptop's saved state…", 3000);
      return true;
    }
    state.manualSyncPending = false;
    if (manual) showToast("Could not reach the laptop server", 4500);
    return false;
  }

  function scheduleAutoSync() {
    if (autoSyncTimer !== null) {
      clearInterval(autoSyncTimer);
      autoSyncTimer = null;
    }
    if (state.autoSyncSeconds > 0) {
      autoSyncTimer = setInterval(() => {
        if (document.visibilityState === "visible") requestSync(false);
      }, state.autoSyncSeconds * 1000);
    }
    updateSyncUI();
  }

  function connect() {
    clearTimeout(reconnectTimer);
    const protocol = location.protocol === "https:" ? "wss:" : "ws:";
    state.awaitingInitialSnapshot = true;
    const websocketUrl = new URL(`${protocol}//${location.host}/ws`);
    websocketUrl.searchParams.set("role", mode === "ipad" ? "ipad" : "desktop");
    websocketUrl.searchParams.set("clientId", clientId);
    socket = new WebSocket(websocketUrl);
    socket.binaryType = "arraybuffer";
    setStatus("Connecting…");

    socket.addEventListener("open", () => {
      setStatus("Connected", "connected");
      flushPendingPoints();
    });
    socket.addEventListener("close", () => {
      setStatus("Disconnected", "disconnected");
      reconnectTimer = setTimeout(connect, 1200);
    });
    socket.addEventListener("error", () => socket.close());
    socket.addEventListener("message", event => {
      if (typeof event.data !== "string") return;
      let message;
      try { message = JSON.parse(event.data); }
      catch { return; }
      handleServerMessage(message);
    });
  }

  function send(message) {
    if (socket?.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify(message));
      return true;
    }
    return false;
  }

  function queueStrokePoints(strokeId, points) {
    if (!points.length) return;
    const batch = state.pendingPointBatches.get(strokeId) || [];
    batch.push(...points);
    state.pendingPointBatches.set(strokeId, batch);

    if (batch.length >= 24) {
      flushPendingPoints(strokeId);
      return;
    }

    if (state.pointFlushTimer === null) {
      state.pointFlushTimer = setTimeout(() => flushPendingPoints(), 4);
    }
  }

  function flushPendingPoints(onlyStrokeId = null) {
    if (state.pointFlushTimer !== null) {
      clearTimeout(state.pointFlushTimer);
      state.pointFlushTimer = null;
    }

    const entries = onlyStrokeId === null
      ? [...state.pendingPointBatches.entries()]
      : [[onlyStrokeId, state.pendingPointBatches.get(onlyStrokeId) || []]];

    for (const [strokeId, points] of entries) {
      if (!points.length) continue;
      if (send({ type: "stroke_points", id: strokeId, points })) {
        state.pendingPointBatches.delete(strokeId);
      }
    }

    if (state.pendingPointBatches.size && state.pointFlushTimer === null) {
      state.pointFlushTimer = setTimeout(() => flushPendingPoints(), 12);
    }
  }

  function handleServerMessage(message) {
    switch (message.type) {
      case "snapshot": {
        if (state.textEdit) commitTextEdit();
        const incoming = message.state || {};
        const incomingDocument = incoming.document || { filename: null, pages: [] };
        const projectImport = message.reason === "project_import";

        if (projectImport) {
          state.pendingDeleteOperations.clear();
          persistPendingDeletes();
        }

        setDocument(incomingDocument, {
          preserveView: mode === "ipad" && !projectImport,
          restoreSavedView: mode === "ipad",
        });
        state.strokes.clear();
        state.liveStrokeIds.clear();
        clearSelection(false);
        for (const stroke of Object.values(incoming.strokes || {})) {
          state.strokes.set(stroke.id, stroke);
        }
        for (const id of message.liveStrokeIds || []) {
          if (state.strokes.has(id)) state.liveStrokeIds.add(id);
        }

        // Locally erased strokes remain hidden until their reliable operation is
        // acknowledged. WebSocket ordering then applies those deletes to the
        // server before any later manual refresh.
        for (const operation of state.pendingDeleteOperations.values()) {
          for (const id of operation.ids) {
            state.strokes.delete(id);
            state.liveStrokeIds.delete(id);
          }
        }

        state.awaitingInitialSnapshot = false;
        recordSuccessfulSync();
        flushPendingDeletes();
        markAllDirty();
        if (mode !== "ipad" && !state.fitDone && state.document.pages.length) fitPages();
        if (mode === "ipad" && !state.fitDone && state.document.pages.length) {
          if (!restoreSavedIpadView(state.document)) fitPages();
        }
        if (state.manualSyncPending) {
          state.manualSyncPending = false;
          showToast("Refreshed from the laptop server");
        }
        break;
      }
      case "document_changed":
        if (state.textEdit) cancelTextEdit();
        setDocument(message.document);
        if (message.clearStrokes) {
          state.strokes.clear();
          state.liveStrokeIds.clear();
          state.pendingDeleteOperations.clear();
          persistPendingDeletes();
          clearSelection(false);
        }
        if (message.focusPageNumber) fitPageNumber(message.focusPageNumber);
        else fitPages();
        markIpadStateDirty();
        markAllDirty();
        showToast(message.notice || "PDF loaded");
        break;
      case "stroke_begin":
        state.strokes.set(message.stroke.id, message.stroke);
        state.liveStrokeIds.add(message.stroke.id);
        state.liveDirty = true;
        markIpadStateDirty();
        break;
      case "stroke_points": {
        const stroke = state.strokes.get(message.id);
        if (stroke) stroke.points.push(...message.points);
        state.liveDirty = true;
        markIpadStateDirty();
        break;
      }
      case "stroke_end":
        state.liveStrokeIds.delete(message.id);
        markIpadStateDirty();
        markAllDirty();
        break;
      case "delete_strokes":
        if (state.textEdit && (message.ids || []).includes(state.textEdit.id)) closeTextEditor();
        for (const id of message.ids || []) {
          state.strokes.delete(id);
          state.liveStrokeIds.delete(id);
          state.selectionIds.delete(id);
        }
        updateSelectionUI();
        restoreTemporarySelectionTool();
        markIpadStateDirty();
        markAllDirty();
        break;
      case "delete_ack": {
        const operationId = String(message.operationId || "");
        const operation = state.pendingDeleteOperations.get(operationId);
        if (operation) {
          for (const id of message.ids || []) operation.ids.delete(String(id));
          if (message.final) state.pendingDeleteOperations.delete(operationId);
        } else {
          // Compatibility with acknowledgements from an older server.
          const acknowledged = new Set((message.ids || []).map(String));
          for (const pending of state.pendingDeleteOperations.values()) {
            for (const id of acknowledged) pending.ids.delete(id);
            if (pending.final && !pending.ids.size) state.pendingDeleteOperations.delete(pending.id);
          }
        }
        persistPendingDeletes();
        if (state.pendingDeleteOperations.size) scheduleDeleteFlush(80);
        break;
      }
      case "replace_strokes":
        for (const stroke of message.strokes || []) {
          state.strokes.set(stroke.id, stroke);
          state.liveStrokeIds.delete(stroke.id);
        }
        updateSelectionUI();
        markIpadStateDirty();
        markAllDirty();
        break;
      case "restore_strokes":
        for (const stroke of message.strokes || []) {
          state.strokes.set(stroke.id, stroke);
          state.liveStrokeIds.delete(stroke.id);
        }
        markIpadStateDirty();
        markAllDirty();
        break;
      case "history_state":
        state.canUndo = Boolean(message.canUndo);
        state.canRedo = Boolean(message.canRedo);
        updateHistoryButtons();
        break;
      case "clear_strokes":
        if (state.textEdit) closeTextEditor();
        state.strokes.clear();
        state.liveStrokeIds.clear();
        state.pendingDeleteOperations.clear();
        persistPendingDeletes();
        clearSelection(false);
        markIpadStateDirty();
        markAllDirty();
        break;
      case "error":
        showToast(`Server: ${message.message}`);
        break;
    }
  }

  function markAllDirty() {
    state.sceneDirty = true;
    state.liveDirty = true;
  }

  function setDocument(documentState, { preserveView = false, restoreSavedView = false } = {}) {
    const previousKey = documentStateKey(state.document);
    const previousFitDone = state.fitDone;
    state.document = documentState || { filename: null, pages: [] };
    const nextKey = documentStateKey(state.document);
    const documentChanged = previousKey !== nextKey;
    nameEl.textContent = state.document.filename || "No PDF loaded";
    if (addPageButton) addPageButton.disabled = !(state.document.pages?.length);
    if (pdfExportButton) pdfExportButton.disabled = !(state.document.pages?.length);
    state.images.clear();
    for (const page of state.document.pages || []) {
      const image = new Image();
      image.decoding = "async";
      image.addEventListener("load", markAllDirty);
      image.addEventListener("error", () => showToast(`Could not load page ${page.pageNumber}`));
      image.src = page.imageUrl;
      state.images.set(page.id, image);
    }
    if (restoreSavedView && (documentChanged || !previousFitDone) && restoreSavedIpadView(state.document)) {
      state.fitDone = true;
    } else if (!documentChanged || preserveView) {
      state.fitDone = previousFitDone;
    } else {
      state.fitDone = false;
    }
  }

  function resizeCanvas() {
    const dpr = Math.min(devicePixelRatio || 1, 2.5);
    const width = Math.max(1, Math.floor(innerWidth * dpr));
    const height = Math.max(1, Math.floor(innerHeight * dpr));
    let changed = false;

    for (const target of [sceneCanvas, canvas]) {
      if (target.width !== width || target.height !== height) {
        target.width = width;
        target.height = height;
        target.style.width = `${innerWidth}px`;
        target.style.height = `${innerHeight}px`;
        changed = true;
      }
    }

    if (changed || state.dpr !== dpr) {
      state.dpr = dpr;
      sceneCtx.setTransform(dpr, 0, 0, dpr, 0, 0);
      liveCtx.setTransform(dpr, 0, 0, dpr, 0, 0);
      markAllDirty();
    }
  }

  function screenToWorld(x, y) {
    return {
      x: state.camera.x + x / state.camera.zoom,
      y: state.camera.y + y / state.camera.zoom,
    };
  }

  function worldToScreen(x, y) {
    return {
      x: (x - state.camera.x) * state.camera.zoom,
      y: (y - state.camera.y) * state.camera.zoom,
    };
  }

  function zoomAround(screenX, screenY, factor) {
    const before = screenToWorld(screenX, screenY);
    const nextZoom = Math.max(0.08, Math.min(8, state.camera.zoom * factor));
    state.camera.zoom = nextZoom;
    state.camera.x = before.x - screenX / nextZoom;
    state.camera.y = before.y - screenY / nextZoom;
    markAllDirty();
  }

  function fitPage(page) {
    if (!page) {
      state.camera = { x: -500, y: -400, zoom: 0.8 };
      markAllDirty();
      return;
    }
    const margin = mode === "ipad" ? 28 : 70;
    const toolbarAllowance = mode === "ipad" ? 76 : 110;
    const availableWidth = Math.max(200, innerWidth - margin * 2);
    const availableHeight = Math.max(200, innerHeight - margin * 2 - toolbarAllowance);
    const zoom = Math.max(0.08, Math.min(2.0, Math.min(availableWidth / page.width, availableHeight / page.height)));
    state.camera.zoom = zoom;
    state.camera.x = page.x - (innerWidth / zoom - page.width) / 2;
    state.camera.y = page.y - ((innerHeight - toolbarAllowance) / zoom - page.height) / 2 - toolbarAllowance / zoom;
    state.fitDone = true;
    markAllDirty();
  }

  function fitPages() {
    fitPage(state.document.pages?.[0]);
  }

  function fitPageNumber(pageNumber) {
    const page = state.document.pages?.find(candidate => candidate.pageNumber === Number(pageNumber));
    fitPage(page || state.document.pages?.[0]);
  }

  function adaptiveGridSpacing() {
    const desiredPixels = 70;
    const raw = desiredPixels / state.camera.zoom;
    const power = 10 ** Math.floor(Math.log10(raw));
    const normalized = raw / power;
    const step = normalized < 2 ? 1 : normalized < 5 ? 2 : 5;
    return step * power;
  }

  function drawGrid() {
    const spacing = adaptiveGridSpacing();
    const left = state.camera.x;
    const top = state.camera.y;
    const right = left + innerWidth / state.camera.zoom;
    const bottom = top + innerHeight / state.camera.zoom;
    const startX = Math.floor(left / spacing) * spacing;
    const startY = Math.floor(top / spacing) * spacing;

    sceneCtx.save();
    sceneCtx.lineWidth = 1;
    sceneCtx.strokeStyle = "rgba(85, 88, 95, 0.11)";
    sceneCtx.beginPath();
    for (let x = startX; x <= right; x += spacing) {
      const sx = worldToScreen(x, 0).x;
      sceneCtx.moveTo(Math.round(sx) + 0.5, 0);
      sceneCtx.lineTo(Math.round(sx) + 0.5, innerHeight);
    }
    for (let y = startY; y <= bottom; y += spacing) {
      const sy = worldToScreen(0, y).y;
      sceneCtx.moveTo(0, Math.round(sy) + 0.5);
      sceneCtx.lineTo(innerWidth, Math.round(sy) + 0.5);
    }
    sceneCtx.stroke();
    sceneCtx.restore();
  }

  function visibleWorldRect() {
    return {
      left: state.camera.x,
      top: state.camera.y,
      right: state.camera.x + innerWidth / state.camera.zoom,
      bottom: state.camera.y + innerHeight / state.camera.zoom,
    };
  }

  function rectIntersects(a, b) {
    return a.x < b.right && a.x + a.width > b.left && a.y < b.bottom && a.y + a.height > b.top;
  }

  function drawPages() {
    const visible = visibleWorldRect();
    for (const page of state.document.pages || []) {
      if (!rectIntersects(page, visible)) continue;
      const pos = worldToScreen(page.x, page.y);
      const w = page.width * state.camera.zoom;
      const h = page.height * state.camera.zoom;

      sceneCtx.save();
      sceneCtx.fillStyle = "white";
      sceneCtx.fillRect(pos.x, pos.y, w, h);
      sceneCtx.strokeStyle = "rgba(0,0,0,0.12)";
      sceneCtx.lineWidth = 1;
      sceneCtx.strokeRect(Math.round(pos.x) + 0.5, Math.round(pos.y) + 0.5, Math.max(0, w - 1), Math.max(0, h - 1));
      sceneCtx.restore();

      const image = state.images.get(page.id);
      if (image?.complete && image.naturalWidth) {
        sceneCtx.drawImage(image, pos.x, pos.y, w, h);
      }

      if (state.camera.zoom > 0.22) {
        sceneCtx.save();
        sceneCtx.fillStyle = "rgba(0,0,0,0.45)";
        sceneCtx.font = "12px system-ui";
        sceneCtx.fillText(`${page.pageNumber}`, pos.x + 8, pos.y + 18);
        sceneCtx.restore();
      }
    }
  }

  function strokeScreenBounds(stroke) {
    if (!stroke.points?.length) return null;
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const p of stroke.points) {
      minX = Math.min(minX, p.x);
      minY = Math.min(minY, p.y);
      maxX = Math.max(maxX, p.x);
      maxY = Math.max(maxY, p.y);
    }
    const pad = stroke.width * 2;
    return {
      x: (minX - state.camera.x - pad) * state.camera.zoom,
      y: (minY - state.camera.y - pad) * state.camera.zoom,
      width: (maxX - minX + pad * 2) * state.camera.zoom,
      height: (maxY - minY + pad * 2) * state.camera.zoom,
    };
  }

  function normalizedStrokeDetail(stroke = null) {
    const raw = Number(stroke?.strokeDetail ?? state.strokeDetail);
    return Math.max(0, Math.min(100, Number.isFinite(raw) ? raw : 80)) / 100;
  }

  function retainedPointSpacingPx(stroke = null) {
    const detail = normalizedStrokeDetail(stroke);
    // Low detail intentionally reduces retained traffic. High detail keeps
    // extremely close Pencil samples so short cross-strokes remain faithful.
    return 0.06 + 1.1 * Math.pow(1 - detail, 2);
  }

  function curveSamplingSettings(stroke = null) {
    const detail = normalizedStrokeDetail(stroke);
    return {
      screenStepPx: Math.max(0.45, 3.0 - 2.55 * Math.sqrt(detail)),
      maxSteps: Math.round(8 + 64 * detail),
    };
  }

  function pressureScale(pressure) {
    const p = Number.isFinite(pressure) ? Math.max(0, Math.min(1, pressure)) : 0.5;
    return 0.3 + p * 0.9;
  }

  function strokeWidthScale(stroke, pressure) {
    if (stroke.tool === "pen") return pressureScale(pressure);
    // Fixed pen and highlighter deliberately ignore pressure.
    return 1;
  }

  function catmullRom(a, b, c, d, t) {
    const t2 = t * t;
    const t3 = t2 * t;
    return 0.5 * (
      (2 * b) +
      (-a + c) * t +
      (2 * a - 5 * b + 4 * c - d) * t2 +
      (-a + 3 * b - 3 * c + d) * t3
    );
  }

  function smoothedScreenSamples(stroke) {
    const points = stroke.points || [];
    if (!points.length) return [];
    if (points.length === 1) {
      const p = worldToScreen(points[0].x, points[0].y);
      return [{ ...p, pressure: points[0].p }];
    }

    const samples = [];
    for (let i = 0; i < points.length - 1; i++) {
      const p0 = points[Math.max(0, i - 1)];
      const p1 = points[i];
      const p2 = points[i + 1];
      const p3 = points[Math.min(points.length - 1, i + 2)];
      const screenDistance = Math.hypot(p2.x - p1.x, p2.y - p1.y) * state.camera.zoom;
      const sampling = curveSamplingSettings(stroke);
      const steps = Math.max(
        1,
        Math.min(sampling.maxSteps, Math.ceil(screenDistance / sampling.screenStepPx))
      );

      for (let step = 0; step < steps; step++) {
        const t = step / steps;
        const x = catmullRom(p0.x, p1.x, p2.x, p3.x, t);
        const y = catmullRom(p0.y, p1.y, p2.y, p3.y, t);
        const pressure = p1.p + (p2.p - p1.p) * t;
        const screen = worldToScreen(x, y);
        samples.push({ ...screen, pressure });
      }
    }

    const last = points.at(-1);
    const lastScreen = worldToScreen(last.x, last.y);
    samples.push({ ...lastScreen, pressure: last.p });
    return samples;
  }


  function drawPatternedStroke(targetCtx, stroke, samples) {
    const style = stroke.lineStyle || "solid";
    if (style === "solid" || samples.length < 2) return false;

    let pressureTotal = 0;
    for (const sample of samples) {
      pressureTotal += strokeWidthScale(stroke, sample.pressure);
    }

    const averageScale = pressureTotal / samples.length;
    const lineWidth = Math.max(
      0.6,
      stroke.width * averageScale * state.camera.zoom
    );

    targetCtx.strokeStyle = stroke.color;
    targetCtx.lineWidth = lineWidth;
    targetCtx.lineCap = "round";
    targetCtx.lineJoin = "round";

    if (style === "dashed") {
      targetCtx.setLineDash([
        Math.max(4, lineWidth * 3.2),
        Math.max(3, lineWidth * 1.9),
      ]);
    } else {
      targetCtx.setLineDash([
        Math.max(0.1, lineWidth * 0.08),
        Math.max(3, lineWidth * 2.05),
      ]);
    }

    targetCtx.beginPath();
    targetCtx.moveTo(samples[0].x, samples[0].y);

    for (let i = 1; i < samples.length - 1; i++) {
      const current = samples[i];
      const next = samples[i + 1];
      const midX = (current.x + next.x) / 2;
      const midY = (current.y + next.y) / 2;
      targetCtx.quadraticCurveTo(current.x, current.y, midX, midY);
    }

    const last = samples.at(-1);
    targetCtx.lineTo(last.x, last.y);
    targetCtx.stroke();
    targetCtx.setLineDash([]);
    return true;
  }

  function textBoxGeometry(stroke) {
    const points = stroke?.points || [];
    if (points.length < 4) return null;
    const topLeft = points[0];
    const topRight = points[1];
    const bottomLeft = points[3];
    const width = Math.hypot(topRight.x - topLeft.x, topRight.y - topLeft.y);
    const height = Math.hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y);
    if (width < 0.001 || height < 0.001) return null;
    return {
      topLeft,
      topRight,
      bottomLeft,
      width,
      height,
      angle: Math.atan2(topRight.y - topLeft.y, topRight.x - topLeft.x),
    };
  }

  function wrapCanvasText(targetCtx, text, maxWidth) {
    const lines = [];
    for (const paragraph of String(text || "").replace(/\r/g, "").split("\n")) {
      if (!paragraph) {
        lines.push("");
        continue;
      }
      const words = paragraph.split(/(\s+)/).filter(Boolean);
      let line = "";
      for (const word of words) {
        const candidate = line + word;
        if (line && targetCtx.measureText(candidate).width > maxWidth) {
          lines.push(line.trimEnd());
          line = word.trimStart();
          if (targetCtx.measureText(line).width > maxWidth) {
            let fragment = "";
            for (const character of line) {
              if (fragment && targetCtx.measureText(fragment + character).width > maxWidth) {
                lines.push(fragment);
                fragment = character;
              } else {
                fragment += character;
              }
            }
            line = fragment;
          }
        } else {
          line = candidate;
        }
      }
      lines.push(line.trimEnd());
    }
    return lines;
  }

  function drawTextStroke(targetCtx, stroke) {
    const geometry = textBoxGeometry(stroke);
    if (!geometry || !String(stroke.text || "")) return;
    const topLeft = worldToScreen(geometry.topLeft.x, geometry.topLeft.y);
    const width = geometry.width * state.camera.zoom;
    const height = geometry.height * state.camera.zoom;
    const fontSize = Math.max(1, Number(stroke.width || 24) * state.camera.zoom);
    const padding = Math.max(2, fontSize * 0.16);
    const lineHeight = fontSize * 1.25;

    targetCtx.save();
    targetCtx.translate(topLeft.x, topLeft.y);
    targetCtx.rotate(geometry.angle);
    targetCtx.beginPath();
    targetCtx.rect(0, 0, width, height);
    targetCtx.clip();
    targetCtx.globalAlpha = stroke.opacity ?? 1;
    targetCtx.fillStyle = stroke.color || "#111111";
    targetCtx.font = `${fontSize}px ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`;
    targetCtx.textBaseline = "top";
    targetCtx.textAlign = ["left", "center", "right"].includes(stroke.textAlign) ? stroke.textAlign : "left";
    const maxTextWidth = Math.max(1, width - padding * 2);
    const lines = wrapCanvasText(targetCtx, stroke.text, maxTextWidth);
    const align = targetCtx.textAlign;
    const x = align === "center" ? width / 2 : align === "right" ? width - padding : padding;
    let y = padding;
    for (const line of lines) {
      if (y + lineHeight > height + 0.01) break;
      targetCtx.fillText(line, x, y, maxTextWidth);
      y += lineHeight;
    }
    targetCtx.restore();
  }


  const GEOMETRY_TYPES = new Set(["rectangle", "square", "ellipse", "circle", "triangle", "diamond", "line", "arrow", "curve", "xy-plane"]);

  function isGeometryStroke(stroke) {
    return stroke?.tool === "shape" && GEOMETRY_TYPES.has(stroke.shapeType);
  }

  function shapeBoxGeometry(stroke) {
    const points = stroke?.points || [];
    if (points.length < 4) return null;
    const topLeft = points[0];
    const topRight = points[1];
    const bottomRight = points[2];
    const bottomLeft = points[3];
    const width = Math.hypot(topRight.x - topLeft.x, topRight.y - topLeft.y);
    const height = Math.hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y);
    if (width < 0.001 || height < 0.001) return null;
    return { topLeft, topRight, bottomRight, bottomLeft, width, height,
      ux: { x:(topRight.x-topLeft.x)/width, y:(topRight.y-topLeft.y)/width },
      uy: { x:(bottomLeft.x-topLeft.x)/height, y:(bottomLeft.y-topLeft.y)/height } };
  }

  function localToWorld(box, x, y) {
    return { x: box.topLeft.x + box.ux.x*x + box.uy.x*y,
      y: box.topLeft.y + box.ux.y*x + box.uy.y*y, p:0.5, t:performance.now() };
  }

  function worldToLocal(box, point) {
    const dx=point.x-box.topLeft.x, dy=point.y-box.topLeft.y;
    return { x:dx*box.ux.x+dy*box.ux.y, y:dx*box.uy.x+dy*box.uy.y };
  }

  function applyShapeLineStyle(targetCtx, stroke) {
    const width=Math.max(.75, Number(stroke.width||3)*state.camera.zoom);
    targetCtx.strokeStyle=stroke.color||"#111111";
    targetCtx.fillStyle=stroke.color||"#111111";
    targetCtx.globalAlpha=stroke.opacity??1;
    targetCtx.lineWidth=width;
    targetCtx.lineCap="round";
    targetCtx.lineJoin="round";
    if (stroke.lineStyle==="dashed") targetCtx.setLineDash([Math.max(5,width*3.2),Math.max(4,width*2)]);
    else if (stroke.lineStyle==="dotted") targetCtx.setLineDash([Math.max(.5,width*.18),Math.max(4,width*2.1)]);
    else targetCtx.setLineDash([]);
    return width;
  }

  function drawArrowHead(targetCtx, a, b, width) {
    const angle=Math.atan2(b.y-a.y,b.x-a.x);
    const size=Math.max(9,width*4.5);
    targetCtx.setLineDash([]);
    targetCtx.beginPath();
    targetCtx.moveTo(b.x,b.y);
    targetCtx.lineTo(b.x-Math.cos(angle-Math.PI/6)*size,b.y-Math.sin(angle-Math.PI/6)*size);
    targetCtx.moveTo(b.x,b.y);
    targetCtx.lineTo(b.x-Math.cos(angle+Math.PI/6)*size,b.y-Math.sin(angle+Math.PI/6)*size);
    targetCtx.stroke();
  }

  function drawShapeStroke(targetCtx, stroke) {
    const points=stroke.points||[];
    if (!points.length) return;
    targetCtx.save();
    const lineWidth=applyShapeLineStyle(targetCtx,stroke);
    const type=stroke.shapeType;
    if ((type==="line"||type==="arrow") && points.length>=2) {
      const a=worldToScreen(points[0].x,points[0].y), b=worldToScreen(points[1].x,points[1].y);
      targetCtx.beginPath(); targetCtx.moveTo(a.x,a.y); targetCtx.lineTo(b.x,b.y); targetCtx.stroke();
      if (type==="arrow") drawArrowHead(targetCtx,a,b,lineWidth);
      targetCtx.restore(); return;
    }
    if (type==="curve" && points.length>=3) {
      const a=worldToScreen(points[0].x,points[0].y), c=worldToScreen(points[1].x,points[1].y), b=worldToScreen(points[2].x,points[2].y);
      targetCtx.beginPath(); targetCtx.moveTo(a.x,a.y); targetCtx.quadraticCurveTo(c.x,c.y,b.x,b.y); targetCtx.stroke(); targetCtx.restore(); return;
    }
    const box=shapeBoxGeometry(stroke); if(!box){targetCtx.restore();return;}
    const tl=worldToScreen(box.topLeft.x,box.topLeft.y);
    const angle=Math.atan2(box.ux.y,box.ux.x), w=box.width*state.camera.zoom, h=box.height*state.camera.zoom;
    targetCtx.translate(tl.x,tl.y); targetCtx.rotate(angle);
    if(type==="ellipse"||type==="circle") {
      targetCtx.beginPath(); targetCtx.ellipse(w/2,h/2,w/2,h/2,0,0,Math.PI*2); targetCtx.stroke();
    } else if(type==="triangle") {
      targetCtx.beginPath(); targetCtx.moveTo(w/2,0); targetCtx.lineTo(w,h); targetCtx.lineTo(0,h); targetCtx.closePath(); targetCtx.stroke();
    } else if(type==="diamond") {
      targetCtx.beginPath(); targetCtx.moveTo(w/2,0); targetCtx.lineTo(w,h/2); targetCtx.lineTo(w/2,h); targetCtx.lineTo(0,h/2); targetCtx.closePath(); targetCtx.stroke();
    } else if(type==="xy-plane") {
      targetCtx.save(); targetCtx.globalAlpha=Math.min(.45,stroke.opacity??1); targetCtx.lineWidth=Math.max(.5,lineWidth*.34); targetCtx.strokeStyle=stroke.gridColor||"#7a7f89";
      targetCtx.beginPath();
      for(let i=1;i<10;i++){ const x=w*i/10; targetCtx.moveTo(x,0); targetCtx.lineTo(x,h); const y=h*i/10; targetCtx.moveTo(0,y); targetCtx.lineTo(w,y); }
      targetCtx.stroke(); targetCtx.restore();
      targetCtx.setLineDash([]); targetCtx.strokeStyle=stroke.color||"#111111"; targetCtx.lineWidth=Math.max(1,lineWidth);
      targetCtx.beginPath(); targetCtx.moveTo(0,h/2); targetCtx.lineTo(w,h/2); targetCtx.moveTo(w/2,h); targetCtx.lineTo(w/2,0); targetCtx.stroke();
      drawArrowHead(targetCtx,{x:w-20,y:h/2},{x:w,y:h/2},lineWidth);
      drawArrowHead(targetCtx,{x:w/2,y:20},{x:w/2,y:0},lineWidth);
      targetCtx.globalAlpha=.75; targetCtx.fillStyle=stroke.color||"#111111"; targetCtx.font=`${Math.max(10,lineWidth*4)}px system-ui`; targetCtx.fillText("x",w-14,h/2-8); targetCtx.fillText("y",w/2+8,14);
    } else {
      targetCtx.strokeRect(0,0,w,h);
    }
    targetCtx.restore();
  }

  function quadraticAt(a,c,b,t){const u=1-t;return{x:u*u*a.x+2*u*t*c.x+t*t*b.x,y:u*u*a.y+2*u*t*c.y+t*t*b.y};}

  function geometryPolyline(stroke, segments=48) {
    const pts=stroke?.points||[], type=stroke?.shapeType;
    if ((type==="line"||type==="arrow")&&pts.length>=2) return pts.slice(0,2);
    if(type==="curve"&&pts.length>=3){const out=[];for(let i=0;i<=segments;i++)out.push(quadraticAt(pts[0],pts[1],pts[2],i/segments));return out;}
    const box=shapeBoxGeometry(stroke); if(!box)return pts;
    if(type==="ellipse"||type==="circle") {const out=[];for(let i=0;i<=segments;i++){const a=i/segments*Math.PI*2;out.push(localToWorld(box,box.width/2+Math.cos(a)*box.width/2,box.height/2+Math.sin(a)*box.height/2));}return out;}
    if(type==="triangle") return [localToWorld(box,box.width/2,0),localToWorld(box,box.width,box.height),localToWorld(box,0,box.height),localToWorld(box,box.width/2,0)];
    if(type==="diamond") return [localToWorld(box,box.width/2,0),localToWorld(box,box.width,box.height/2),localToWorld(box,box.width/2,box.height),localToWorld(box,0,box.height/2),localToWorld(box,box.width/2,0)];
    if(type==="xy-plane") return [box.topLeft,box.topRight,box.bottomRight,box.bottomLeft,box.topLeft,localToWorld(box,0,box.height/2),localToWorld(box,box.width,box.height/2),localToWorld(box,box.width/2,0),localToWorld(box,box.width/2,box.height)];
    return [box.topLeft,box.topRight,box.bottomRight,box.bottomLeft,box.topLeft];
  }

  function makeShapePoints(type,start,end) {
    let dx=end.x-start.x,dy=end.y-start.y;
    if(type==="square"||type==="circle"){const side=Math.max(Math.abs(dx),Math.abs(dy));dx=(dx<0?-1:1)*side;dy=(dy<0?-1:1)*side;}
    if(type==="line"||type==="arrow") return [{...start},{...end}];
    if(type==="curve") {const length=Math.hypot(dx,dy)||1;const nx=-dy/length,ny=dx/length;const bend=Math.min(length*.24,80/state.camera.zoom);return [{...start},{x:(start.x+end.x)/2+nx*bend,y:(start.y+end.y)/2+ny*bend,p:.5,t:performance.now()},{...end}];}
    const p0={...start},p1={x:start.x+dx,y:start.y,p:.5,t:performance.now()},p2={x:start.x+dx,y:start.y+dy,p:.5,t:performance.now()},p3={x:start.x,y:start.y+dy,p:.5,t:performance.now()};
    return [p0,p1,p2,p3];
  }

  function shapeStrokeAt(world) {
    let best = null;
    let bestD = Infinity;
    const threshold = 12 / state.camera.zoom;
    for (const [id, stroke] of state.strokes) {
      if (!isGeometryStroke(stroke)) continue;
      // Locked geometry can only be recovered by surrounding it with the
      // selector lasso. Direct Pencil/finger taps pass through every locked
      // shape so drawing and navigation are never interrupted.
      if (stroke.locked) continue;
      const type = stroke.shapeType;
      const box = shapeBoxGeometry(stroke);
      if (box && !["line", "arrow", "curve", "xy-plane"].includes(type)) {
        const local = worldToLocal(box, world);
        let inside = false;
        if (["rectangle", "square"].includes(type)) {
          inside = local.x >= -threshold && local.y >= -threshold
            && local.x <= box.width + threshold && local.y <= box.height + threshold;
        } else if (["ellipse", "circle"].includes(type)) {
          const rx = Math.max(box.width / 2, 0.001);
          const ry = Math.max(box.height / 2, 0.001);
          const nx = (local.x - rx) / (rx + threshold);
          const ny = (local.y - ry) / (ry + threshold);
          inside = nx * nx + ny * ny <= 1;
        } else if (["triangle", "diamond"].includes(type)) {
          inside = pointInPolygon(world, geometryPolyline(stroke, 8).slice(0, -1));
        }
        if (inside) return id;
      }
      // Coordinate planes deliberately do not claim their whole interior.
      // They are background geometry, so only the border and main axes are
      // directly draggable; users can still pan or draw in the grid cells.
      if (type === "xy-plane" && box) {
        const segments = [
          [box.topLeft, box.topRight], [box.topRight, box.bottomRight],
          [box.bottomRight, box.bottomLeft], [box.bottomLeft, box.topLeft],
          [localToWorld(box, 0, box.height / 2), localToWorld(box, box.width, box.height / 2)],
          [localToWorld(box, box.width / 2, 0), localToWorld(box, box.width / 2, box.height)],
        ];
        for (const [a, b] of segments) {
          const d = pointSegmentDistanceSquared(world, a, b);
          if (d < bestD && d <= threshold * threshold) {
            best = id;
            bestD = d;
          }
        }
        continue;
      }
      const poly = geometryPolyline(stroke, 64);
      for (let i = 1; i < poly.length; i++) {
        const d = pointSegmentDistanceSquared(world, poly[i - 1], poly[i]);
        if (d < bestD && d <= threshold * threshold) {
          best = id;
          bestD = d;
        }
      }
    }
    return best;
  }

  function nearestEllipseSnap(point, excludeId, otherPoint) {
    // Search the actual ellipse boundary for the best tangent/normal candidate.
    // The previous radial-only approximation frequently missed valid snaps on
    // ovals and when the pointer was slightly past the ideal contact point.
    if (!otherPoint) return null;
    const capture = Math.max(18, state.geometrySnapDistance * 2.25) / state.camera.zoom;
    const maxAngle = 30 * Math.PI / 180;
    let best = null;

    for (const [id, stroke] of state.strokes) {
      if (id === excludeId || !isGeometryStroke(stroke)
          || !["ellipse", "circle"].includes(stroke.shapeType)) continue;
      const box = shapeBoxGeometry(stroke);
      if (!box) continue;
      const rx = box.width / 2;
      const ry = box.height / 2;
      if (rx < 0.001 || ry < 0.001) continue;

      const segments = 180;
      for (let index = 0; index < segments; index++) {
        const angle = index / segments * Math.PI * 2;
        const cosine = Math.cos(angle);
        const sine = Math.sin(angle);
        const boundary = localToWorld(box, rx + cosine * rx, ry + sine * ry);
        const pointerDistance = Math.hypot(boundary.x - point.x, boundary.y - point.y);
        if (pointerDistance > capture) continue;

        const normalLocal = { x: cosine / rx, y: sine / ry };
        const normalWorld = {
          x: box.ux.x * normalLocal.x + box.uy.x * normalLocal.y,
          y: box.ux.y * normalLocal.x + box.uy.y * normalLocal.y,
        };
        const normalLength = Math.hypot(normalWorld.x, normalWorld.y) || 1;
        const normal = { x: normalWorld.x / normalLength, y: normalWorld.y / normalLength };
        const tangent = { x: -normal.y, y: normal.x };

        const vx = boundary.x - otherPoint.x;
        const vy = boundary.y - otherPoint.y;
        const lineLength = Math.hypot(vx, vy);
        if (lineLength < 0.001) continue;
        const direction = { x: vx / lineLength, y: vy / lineLength };
        const candidates = [];
        if (state.tangentSnap) candidates.push({ kind: "tangent", angle: angleDifference(direction, tangent) });
        if (state.normalSnap) candidates.push({ kind: "normal", angle: angleDifference(direction, normal) });

        for (const candidate of candidates) {
          if (candidate.angle > maxAngle) continue;
          const score = pointerDistance + candidate.angle / maxAngle * capture * 0.65;
          if (!best || score < best.score) {
            best = { point: boundary, kind: candidate.kind, distance: pointerDistance, angle: candidate.angle, score };
          }
        }
      }
    }
    return best;
  }

  function angleDifference(a, b) {
    const dot = Math.max(-1, Math.min(1, Math.abs(a.x * b.x + a.y * b.y)));
    return Math.acos(dot);
  }

  function geometrySnapEndpoints(stroke) {
    if (!isGeometryStroke(stroke)) return [];
    const points = stroke.points || [];
    if (["ellipse", "circle"].includes(stroke.shapeType)) return [];
    if (stroke.shapeType === "curve") return points.length >= 3 ? [points[0], points[2]] : [];
    if (["line", "arrow"].includes(stroke.shapeType)) return points.slice(0, 2);
    return points;
  }

  function snapGeometryPoint(point, { strokeId = null, otherPoint = null } = {}) {
    const limit = state.geometrySnapDistance / state.camera.zoom;
    const original = { ...point };
    let result = { ...point };
    let kind = "none";

    // Tangent/normal snaps have priority over ordinary endpoint and axis snaps.
    // Previously the endpoint pass could pull a line onto an ellipse's bounding
    // box corner before the tangent/normal calculation saw the real pointer.
    if (otherPoint && (state.tangentSnap || state.normalSnap)) {
      const ellipse = nearestEllipseSnap(original, strokeId, otherPoint);
      if (ellipse) {
        result = { ...result, x: ellipse.point.x, y: ellipse.point.y };
        kind = ellipse.kind;
      }
    }

    if (kind === "none" && state.endpointSnap) {
      let bestDistance = limit;
      for (const [id, stroke] of state.strokes) {
        if (id === strokeId || !isGeometryStroke(stroke)) continue;
        for (const candidate of geometrySnapEndpoints(stroke)) {
          const distance = Math.hypot(candidate.x - result.x, candidate.y - result.y);
          if (distance < bestDistance) {
            bestDistance = distance;
            result = { ...result, x: candidate.x, y: candidate.y };
            kind = "endpoint";
          }
        }
      }
    }

    if (kind === "none" && otherPoint && state.axisSnap) {
      const dx = Math.abs(result.x - otherPoint.x);
      const dy = Math.abs(result.y - otherPoint.y);
      if (dx <= limit) {
        result.x = otherPoint.x;
        kind = "vertical";
      }
      if (dy <= limit) {
        result.y = otherPoint.y;
        kind = "horizontal";
      }
    }

    if (kind === "none" && state.axisSnap) {
      for (const [id, stroke] of state.strokes) {
        if (id === strokeId || stroke.tool !== "shape" || stroke.shapeType !== "xy-plane") continue;
        const box = shapeBoxGeometry(stroke);
        if (!box) continue;
        const local = worldToLocal(box, result);
        if (local.x < -limit || local.y < -limit || local.x > box.width + limit || local.y > box.height + limit) continue;
        if (Math.abs(local.y - box.height / 2) <= limit) {
          const snapped = localToWorld(box, Math.max(0, Math.min(box.width, local.x)), box.height / 2);
          result = { ...result, x: snapped.x, y: snapped.y };
          kind = "x-axis";
        }
        if (Math.abs(local.x - box.width / 2) <= limit) {
          const snapped = localToWorld(box, box.width / 2, Math.max(0, Math.min(box.height, local.y)));
          result = { ...result, x: snapped.x, y: snapped.y };
          kind = "y-axis";
        }
      }
    }

    state.lastSnapResult = kind === "none" ? "None" : kind;
    state.snapGuide = kind === "none" ? null : {
      kind,
      point: { x: result.x, y: result.y },
      from: otherPoint ? { ...otherPoint } : null,
    };
    return result;
  }

  function drawSnapGuide(targetCtx){const guide=state.snapGuide;if(!guide)return;const p=worldToScreen(guide.point.x,guide.point.y);targetCtx.save();targetCtx.strokeStyle="#ff8a00";targetCtx.fillStyle="#ff8a00";targetCtx.lineWidth=1.5;targetCtx.setLineDash([5,4]);if(guide.from){const a=worldToScreen(guide.from.x,guide.from.y);targetCtx.beginPath();targetCtx.moveTo(a.x,a.y);targetCtx.lineTo(p.x,p.y);targetCtx.stroke();}targetCtx.setLineDash([]);targetCtx.beginPath();targetCtx.arc(p.x,p.y,6,0,Math.PI*2);targetCtx.stroke();targetCtx.font="11px system-ui";targetCtx.fillText(guide.kind,p.x+9,p.y-8);targetCtx.restore();}

  function lineFitError(points){if(points.length<2)return Infinity;const a=points[0],b=points.at(-1),length=Math.hypot(b.x-a.x,b.y-a.y);if(length<1e-6)return Infinity;let max=0;for(const p of points)max=Math.max(max,Math.sqrt(pointSegmentDistanceSquared(p,a,b)));return max/length*100;}

  function quadraticFit(points){if(points.length<3)return null;const a=points[0],b=points.at(-1);let total=0;const distances=[0];for(let i=1;i<points.length;i++){total+=Math.hypot(points[i].x-points[i-1].x,points[i].y-points[i-1].y);distances.push(total);}if(total<1e-6)return null;let sx=0,sy=0,w=0;for(let i=1;i<points.length-1;i++){const t=distances[i]/total,u=1-t,den=2*u*t;if(den<.05)continue;sx+=(points[i].x-u*u*a.x-t*t*b.x)/den;sy+=(points[i].y-u*u*a.y-t*t*b.y)/den;w++;}const c=w?{x:sx/w,y:sy/w,p:.5,t:performance.now()}:{x:(a.x+b.x)/2,y:(a.y+b.y)/2,p:.5,t:performance.now()};let max=0;for(let i=0;i<points.length;i++){const q=quadraticAt(a,c,b,distances[i]/total);max=Math.max(max,Math.hypot(q.x-points[i].x,q.y-points[i].y));}return{points:[{...a},c,{...b}],error:max/Math.hypot(b.x-a.x,b.y-a.y)*100};}

  function scheduleGeometryRecognition(){if(state.recognitionTimer!==null)clearTimeout(state.recognitionTimer);const stroke=state.strokes.get(state.activeStrokeId);if(!stroke||!["pen","fixed-pen"].includes(stroke.tool)||state.activeRawPoints.length<4)return;state.recognitionTimer=setTimeout(recognizeActiveInk,state.recognitionHoldMs);}

  function recognizeActiveInk(){state.recognitionTimer=null;const stroke=state.strokes.get(state.activeStrokeId),raw=state.activeRawPoints;if(!stroke||raw.length<4||!["pen","fixed-pen"].includes(stroke.tool))return;const chord=Math.hypot(raw.at(-1).x-raw[0].x,raw.at(-1).y-raw[0].y)*state.camera.zoom;if(chord<24)return;const lineError=lineFitError(raw);let type=null,points=null,error=lineError;if(lineError<=state.lineRecognitionTolerance){type="line";points=[{...raw[0]},snapGeometryPoint({...raw.at(-1)},{strokeId:stroke.id,otherPoint:raw[0]})];}else{const fit=quadraticFit(raw);if(fit&&fit.error<=state.curveRecognitionTolerance){type="curve";points=fit.points;error=fit.error;}}
    if(!type){state.lastRecognitionResult=`Rejected · ${lineError.toFixed(1)}% line`;updateDebugPanel(true);return;}stroke.recognitionSource=stroke.tool;stroke.tool="shape";stroke.shapeType=type;stroke.points=points;stroke.recognitionError=error;state.lastRecognitionResult=`${type} · ${error.toFixed(1)}%`;navigator.vibrate?.(8);debugLog(`RECOGNIZE ${type} error=${error.toFixed(2)}%`);markAllDirty();updateDebugPanel(true);}

  function beginShapePointer(event){event.preventDefault?.();const world=screenToWorld(event.clientX,event.clientY);const stroke={id:`${clientId}-shape-${Date.now()}-${Math.random().toString(16).slice(2)}`,owner:clientId,tool:"shape",shapeType:state.shapeType,color:colorEl.value,width:Number(widthEl.value)||3,opacity:1,lineStyle:state.lineStyle||"solid",smoothing:0,strokeDetail:100,locked:false,points:makeShapePoints(state.shapeType,world,world)};state.strokes.set(stroke.id,stroke);state.shapeGesture={pointerId:event.pointerId,start:world,strokeId:stroke.id,changed:false};state.activePointerId=event.pointerId;try{canvas.setPointerCapture(event.pointerId);}catch{}markAllDirty();return true;}

  function updateShapePointer(event){const g=state.shapeGesture;if(!g||event.pointerId!==g.pointerId)return false;event.preventDefault?.();const stroke=state.strokes.get(g.strokeId);if(!stroke)return false;let end=screenToWorld(event.clientX,event.clientY);if(["line","arrow"].includes(stroke.shapeType))end=snapGeometryPoint(end,{strokeId:stroke.id,otherPoint:g.start});stroke.points=makeShapePoints(stroke.shapeType,g.start,end);g.changed=g.changed||Math.hypot(end.x-g.start.x,end.y-g.start.y)*state.camera.zoom>5;markAllDirty();return true;}

  function finishShapePointer(event,cancelled=false){const g=state.shapeGesture;if(!g||(event&&event.pointerId!==g.pointerId))return false;if(event&&!cancelled)updateShapePointer(event);const stroke=state.strokes.get(g.strokeId);if(cancelled||!g.changed||!stroke){state.strokes.delete(g.strokeId);}else if(!send({type:"add_strokes",strokes:[cloneValue(stroke)]})){state.strokes.delete(g.strokeId);showToast("Shape was not sent because the server is disconnected",5000);}else{state.selectionIds=new Set([stroke.id]);showToast(`${stroke.shapeType.replace("xy-plane","x-y plane")} added`);}try{if(event)canvas.releasePointerCapture(event.pointerId);}catch{}state.shapeGesture=null;state.activePointerId=null;state.snapGuide=null;updateSelectionUI();markAllDirty();return true;}

  function insertXYPlane(){const page=state.document.pages?.find(p=>p.x<=state.camera.x+innerWidth/state.camera.zoom/2&&p.x+p.width>=state.camera.x+innerWidth/state.camera.zoom/2&&p.y<=state.camera.y+innerHeight/state.camera.zoom/2&&p.y+p.height>=state.camera.y+innerHeight/state.camera.zoom/2)||state.document.pages?.[0];const center=page?{x:page.x+page.width/2,y:page.y+page.height/2}:{x:state.camera.x+innerWidth/(2*state.camera.zoom),y:state.camera.y+innerHeight/(2*state.camera.zoom)};const w=Math.min(page?.width*.7||500,520),h=Math.min(page?.height*.55||360,420);const start={x:center.x-w/2,y:center.y-h/2,p:.5,t:performance.now()},end={x:center.x+w/2,y:center.y+h/2,p:.5,t:performance.now()};const stroke={id:`${clientId}-plane-${Date.now()}-${Math.random().toString(16).slice(2)}`,owner:clientId,tool:"shape",shapeType:"xy-plane",locked:false,color:colorEl.value,width:Math.max(1.2,Number(widthEl.value)||2),opacity:1,lineStyle:"solid",smoothing:0,strokeDetail:100,points:makeShapePoints("xy-plane",start,end)};state.strokes.set(stroke.id,stroke);if(send({type:"add_strokes",strokes:[cloneValue(stroke)]})){state.selectionIds=new Set([stroke.id]);state.toolbarMode="select";applyToolbarSelection();updateSelectionUI();showToast("x-y plane added");}else{state.strokes.delete(stroke.id);showToast("Plane was not sent because the server is disconnected",5000);}markAllDirty();}

  function drawStroke(targetCtx, stroke) {
    const points = stroke.points || [];
    if (!points.length) return;
    const bounds = strokeScreenBounds(stroke);
    if (bounds && (bounds.x > innerWidth || bounds.y > innerHeight || bounds.x + bounds.width < 0 || bounds.y + bounds.height < 0)) return;

    if (stroke.tool === "text") {
      drawTextStroke(targetCtx, stroke);
      return;
    }
    if (stroke.tool === "shape") {
      drawShapeStroke(targetCtx, stroke);
      return;
    }

    const samples = smoothedScreenSamples(stroke);
    if (!samples.length) return;

    targetCtx.save();
    targetCtx.fillStyle = stroke.color;
    targetCtx.globalAlpha = stroke.opacity ?? 1;

    if (drawPatternedStroke(targetCtx, stroke, samples)) {
      targetCtx.restore();
      return;
    }

    if (samples.length === 1) {
      const scale = strokeWidthScale(stroke, samples[0].pressure);
      const radius = Math.max(0.5, stroke.width * scale * state.camera.zoom / 2);
      targetCtx.beginPath();
      targetCtx.arc(samples[0].x, samples[0].y, radius, 0, Math.PI * 2);
      targetCtx.fill();
      targetCtx.restore();
      return;
    }

    const left = [];
    const right = [];
    const radii = [];
    const tangents = [];
    const normals = [];
    let previousTangent = { x: 1, y: 0 };
    let previousNormal = { x: 0, y: 1 };

    for (let i = 0; i < samples.length; i++) {
      const previous = samples[Math.max(0, i - 1)];
      const next = samples[Math.min(samples.length - 1, i + 1)];
      const dx = next.x - previous.x;
      const dy = next.y - previous.y;
      const length = Math.hypot(dx, dy);
      const tangent = length > 0.001
        ? { x: dx / length, y: dy / length }
        : previousTangent;
      const normal = length > 0.001
        ? { x: -tangent.y, y: tangent.x }
        : previousNormal;
      previousTangent = tangent;
      previousNormal = normal;
      tangents.push(tangent);
      normals.push(normal);

      const scale = strokeWidthScale(stroke, samples[i].pressure);
      const radius = Math.max(0.35, stroke.width * scale * state.camera.zoom / 2);
      radii.push(radius);
      left.push({ x: samples[i].x + normal.x * radius, y: samples[i].y + normal.y * radius });
      right.push({ x: samples[i].x - normal.x * radius, y: samples[i].y - normal.y * radius });
    }

    // Build one continuous capsule path. Earlier versions filled the ribbon
    // and two complete circles separately. Transparent highlighter caps then
    // overlapped the ribbon and became half-dark, while Safari could expose a
    // seam on pressure-pen caps. One path gives every pixel exactly one fill.
    const kappa = 0.5522847498307936;
    const first = samples[0];
    const last = samples.at(-1);
    const firstRadius = radii[0];
    const lastRadius = radii.at(-1);
    const firstTangent = tangents[0];
    const lastTangent = tangents.at(-1);
    const firstNormal = normals[0];
    const lastNormal = normals.at(-1);

    targetCtx.beginPath();
    targetCtx.moveTo(left[0].x, left[0].y);
    for (let i = 1; i < left.length; i++) targetCtx.lineTo(left[i].x, left[i].y);

    const front = {
      x: last.x + lastTangent.x * lastRadius,
      y: last.y + lastTangent.y * lastRadius,
    };
    targetCtx.bezierCurveTo(
      left.at(-1).x + lastTangent.x * kappa * lastRadius,
      left.at(-1).y + lastTangent.y * kappa * lastRadius,
      front.x + lastNormal.x * kappa * lastRadius,
      front.y + lastNormal.y * kappa * lastRadius,
      front.x,
      front.y,
    );
    targetCtx.bezierCurveTo(
      front.x - lastNormal.x * kappa * lastRadius,
      front.y - lastNormal.y * kappa * lastRadius,
      right.at(-1).x + lastTangent.x * kappa * lastRadius,
      right.at(-1).y + lastTangent.y * kappa * lastRadius,
      right.at(-1).x,
      right.at(-1).y,
    );

    for (let i = right.length - 2; i >= 0; i--) targetCtx.lineTo(right[i].x, right[i].y);

    const back = {
      x: first.x - firstTangent.x * firstRadius,
      y: first.y - firstTangent.y * firstRadius,
    };
    targetCtx.bezierCurveTo(
      right[0].x - firstTangent.x * kappa * firstRadius,
      right[0].y - firstTangent.y * kappa * firstRadius,
      back.x - firstNormal.x * kappa * firstRadius,
      back.y - firstNormal.y * kappa * firstRadius,
      back.x,
      back.y,
    );
    targetCtx.bezierCurveTo(
      back.x + firstNormal.x * kappa * firstRadius,
      back.y + firstNormal.y * kappa * firstRadius,
      left[0].x - firstTangent.x * kappa * firstRadius,
      left[0].y - firstTangent.y * kappa * firstRadius,
      left[0].x,
      left[0].y,
    );
    targetCtx.closePath();
    targetCtx.fill();
    targetCtx.restore();
  }


  function cloneValue(value) {
    if (typeof structuredClone === "function") return structuredClone(value);
    return JSON.parse(JSON.stringify(value));
  }

  function strokeWorldBounds(stroke) {
    const points = stroke?.points || [];
    if (!points.length) return null;
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const point of points) {
      minX = Math.min(minX, point.x);
      minY = Math.min(minY, point.y);
      maxX = Math.max(maxX, point.x);
      maxY = Math.max(maxY, point.y);
    }
    const pressurePad = stroke.tool === "pen" ? 1.2 : 1;
    const pad = stroke.tool === "text"
      ? 0.75
      : Math.max(0.5, Number(stroke.width || 3) * pressurePad / 2 + 0.75);
    return { left: minX - pad, top: minY - pad, right: maxX + pad, bottom: maxY + pad };
  }

  function selectedWorldBounds() {
    let bounds = null;
    for (const id of state.selectionIds) {
      const strokeBounds = strokeWorldBounds(state.strokes.get(id));
      if (!strokeBounds) continue;
      if (!bounds) bounds = { ...strokeBounds };
      else {
        bounds.left = Math.min(bounds.left, strokeBounds.left);
        bounds.top = Math.min(bounds.top, strokeBounds.top);
        bounds.right = Math.max(bounds.right, strokeBounds.right);
        bounds.bottom = Math.max(bounds.bottom, strokeBounds.bottom);
      }
    }
    return bounds;
  }

  function selectionScreenGeometry() {
    const bounds = selectedWorldBounds();
    if (!bounds) return null;
    const topLeft = worldToScreen(bounds.left, bounds.top);
    const bottomRight = worldToScreen(bounds.right, bounds.bottom);
    const left = Math.min(topLeft.x, bottomRight.x);
    const right = Math.max(topLeft.x, bottomRight.x);
    const top = Math.min(topLeft.y, bottomRight.y);
    const bottom = Math.max(topLeft.y, bottomRight.y);
    const rotation = { x: (left + right) / 2, y: top - 30 };
    return {
      bounds,
      left, top, right, bottom,
      center: { x: (left + right) / 2, y: (top + bottom) / 2 },
      rotation,
      handles: {
        nw: { x: left, y: top },
        ne: { x: right, y: top },
        sw: { x: left, y: bottom },
        se: { x: right, y: bottom },
      },
    };
  }

  function geometryDisplayName(stroke) {
    if (!isGeometryStroke(stroke)) return "item";
    return stroke.shapeType === "xy-plane"
      ? "x-y plane"
      : stroke.shapeType.replace("ellipse", "oval");
  }

  function updateSelectionUI() {
    const count = state.selectionIds.size;
    const selectedItems = [...state.selectionIds]
      .map(id => state.strokes.get(id))
      .filter(Boolean);
    const allLocked = count > 0 && selectedItems.every(stroke => Boolean(stroke.locked));
    const selected = count === 1 ? selectedItems[0] : null;

    if (selectionCount) {
      selectionCount.textContent = selected && isGeometryStroke(selected)
        ? `${geometryDisplayName(selected)} selected${selected.locked ? " · locked" : ""}`
        : count ? `${count} selected` : "Lasso items to select";
    }
    if (selectionCopyButton) selectionCopyButton.disabled = count === 0;
    if (selectionDeleteButton) selectionDeleteButton.disabled = count === 0;
    if (selectionPasteButton) selectionPasteButton.disabled = state.selectionClipboard.length === 0;
    if (selectionPlaneLockButton) {
      selectionPlaneLockButton.hidden = count === 0;
      selectionPlaneLockButton.classList.toggle("active", allLocked);
      selectionPlaneLockButton.title = allLocked ? "Unlock selected items" : "Lock selected items";
      selectionPlaneLockButton.setAttribute("aria-label", selectionPlaneLockButton.title);
    }
  }

  function toggleSelectedGeometryLock() {
    const selected = [...state.selectionIds]
      .map(id => state.strokes.get(id))
      .filter(Boolean);
    if (!selected.length) return;

    const originals = selected.map(cloneValue);
    const lock = !selected.every(stroke => Boolean(stroke.locked));
    for (const stroke of selected) stroke.locked = lock;
    const replacements = selected.map(cloneValue);
    if (!send({ type: "replace_strokes", strokes: replacements })) {
      for (const original of originals) state.strokes.set(original.id, original);
      showToast("Lock change was not sent because the server is disconnected", 5000);
    } else {
      markIpadStateDirty();
      const label = selected.length === 1 ? (isGeometryStroke(selected[0]) ? geometryDisplayName(selected[0]) : "Item") : `${selected.length} items`;
      showToast(`${label} ${lock ? "locked" : "unlocked"}`);
    }
    updateSelectionUI();
    markAllDirty();
  }

  function restoreTemporarySelectionTool() {
    if (state.selectionIds.size || state.temporarySelectionReturnMode === null) return;
    const returnMode = state.temporarySelectionReturnMode;
    state.temporarySelectionReturnMode = null;
    state.toolbarMode = returnMode;
    applyToolbarSelection();
  }

  function beginTemporaryGeometrySelection(id) {
    const stroke = state.strokes.get(id);
    if (!isGeometryStroke(stroke) || stroke.locked) return false;
    if (state.toolbarMode !== "select" && state.temporarySelectionReturnMode === null) {
      state.temporarySelectionReturnMode = state.toolbarMode;
    }
    state.selectionIds = new Set([id]);
    state.toolbarMode = "select";
    applyToolbarSelection();
    updateSelectionUI();
    markAllDirty();
    return true;
  }

  function clearSelection(render = true) {
    state.selectionIds.clear();
    state.selectionGesture = null;
    state.activeTouchIdentifier = null;
    document.body.classList.remove("selection-dragging");
    updateSelectionUI();
    if (render) markAllDirty();
  }

  function drawSelectionOverlay(targetCtx) {
    const gesture = state.selectionGesture;
    if (gesture?.mode === "lasso" && gesture.points.length) {
      targetCtx.save();
      targetCtx.strokeStyle = "#377cf6";
      targetCtx.fillStyle = "rgba(55,124,246,0.08)";
      targetCtx.lineWidth = 1.5;
      targetCtx.setLineDash([6, 4]);
      targetCtx.beginPath();
      const first = worldToScreen(gesture.points[0].x, gesture.points[0].y);
      targetCtx.moveTo(first.x, first.y);
      for (const point of gesture.points.slice(1)) {
        const screen = worldToScreen(point.x, point.y);
        targetCtx.lineTo(screen.x, screen.y);
      }
      targetCtx.stroke();
      targetCtx.setLineDash([]);
      targetCtx.restore();
    }

    const geometry = selectionScreenGeometry();
    if (!geometry) return;
    targetCtx.save();
    targetCtx.strokeStyle = "#377cf6";
    targetCtx.fillStyle = "rgba(55,124,246,0.10)";
    targetCtx.lineWidth = 1.5;
    targetCtx.setLineDash([7, 4]);
    targetCtx.strokeRect(
      geometry.left,
      geometry.top,
      Math.max(1, geometry.right - geometry.left),
      Math.max(1, geometry.bottom - geometry.top),
    );
    targetCtx.setLineDash([]);
    targetCtx.beginPath();
    targetCtx.moveTo(geometry.center.x, geometry.top);
    targetCtx.lineTo(geometry.rotation.x, geometry.rotation.y);
    targetCtx.stroke();

    for (const handle of Object.values(geometry.handles)) {
      targetCtx.fillStyle = "white";
      targetCtx.strokeStyle = "#377cf6";
      targetCtx.lineWidth = 2;
      targetCtx.fillRect(handle.x - 5, handle.y - 5, 10, 10);
      targetCtx.strokeRect(handle.x - 5, handle.y - 5, 10, 10);
    }
    targetCtx.beginPath();
    targetCtx.arc(geometry.rotation.x, geometry.rotation.y, 6, 0, Math.PI * 2);
    targetCtx.fillStyle = "white";
    targetCtx.fill();
    targetCtx.strokeStyle = "#377cf6";
    targetCtx.lineWidth = 2;
    targetCtx.stroke();
    if (state.selectionIds.size === 1) {
      const selected = state.strokes.get([...state.selectionIds][0]);
      if (isGeometryStroke(selected) && ["line", "arrow", "curve"].includes(selected.shapeType)) {
        selected.points.forEach((point, index) => {
          const screen = worldToScreen(point.x, point.y);
          targetCtx.beginPath();
          targetCtx.arc(screen.x, screen.y, index === 1 && selected.shapeType === "curve" ? 5 : 7, 0, Math.PI * 2);
          targetCtx.fillStyle = index === 1 && selected.shapeType === "curve" ? "#fff4c4" : "white";
          targetCtx.fill(); targetCtx.strokeStyle = "#377cf6"; targetCtx.stroke();
        });
      }
    }
    targetCtx.restore();
    drawSnapGuide(targetCtx);
  }

  function pointInPolygon(point, polygon) {
    let inside = false;
    for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      const a = polygon[i];
      const b = polygon[j];
      const intersects = ((a.y > point.y) !== (b.y > point.y))
        && point.x < (b.x - a.x) * (point.y - a.y) / ((b.y - a.y) || 1e-12) + a.x;
      if (intersects) inside = !inside;
    }
    return inside;
  }

  function strokeSelectedByLasso(stroke, polygon) {
    const points = stroke.points || [];
    if (!points.length || polygon.length < 3) return false;
    const bounds = strokeWorldBounds(stroke);
    const center = bounds ? { x: (bounds.left + bounds.right) / 2, y: (bounds.top + bounds.bottom) / 2 } : points[0];
    if (pointInPolygon(center, polygon)) return true;
    const stride = Math.max(1, Math.floor(points.length / 160));
    let sampled = 0;
    let inside = 0;
    for (let index = 0; index < points.length; index += stride) {
      sampled += 1;
      if (pointInPolygon(points[index], polygon)) inside += 1;
    }
    return sampled > 0 && inside / sampled >= 0.5;
  }

  function hitStrokeAt(world, thresholdWorld) {
    // Direct selector taps may select unlocked geometry. Locked geometry is
    // intentionally available only to a surrounding lasso.
    const geometryHit = shapeStrokeAt(world);
    if (geometryHit) return geometryHit;

    let best = null;
    let bestDistance = Infinity;
    for (const [id, stroke] of state.strokes.entries()) {
      if (isGeometryStroke(stroke) || stroke.locked) continue;
      const points = stroke.points || [];
      if (!points.length) continue;
      if (stroke.tool === "text" && points.length >= 4 && pointInPolygon(world, points.slice(0, 4))) {
        return id;
      }
      const extra = stroke.tool === "text"
        ? thresholdWorld
        : Math.max(thresholdWorld, Number(stroke.width || 3) / 2);
      const limit2 = extra * extra;
      if (points.length === 1) {
        const distance2 = (world.x - points[0].x) ** 2 + (world.y - points[0].y) ** 2;
        if (distance2 <= limit2 && distance2 < bestDistance) {
          best = id;
          bestDistance = distance2;
        }
        continue;
      }
      for (let index = 1; index < points.length; index++) {
        const distance2 = pointSegmentDistanceSquared(world, points[index - 1], points[index]);
        if (distance2 <= limit2 && distance2 < bestDistance) {
          best = id;
          bestDistance = distance2;
        }
      }
    }
    return best;
  }

  function selectionHit(clientX, clientY) {
    const geometry = selectionScreenGeometry();
    if (!geometry) return null;
    if (state.selectionIds.size === 1) {
      const selected = state.strokes.get([...state.selectionIds][0]);
      if (isGeometryStroke(selected) && ["line", "arrow", "curve"].includes(selected.shapeType)) {
        for (let index = 0; index < selected.points.length; index++) {
          const handle = worldToScreen(selected.points[index].x, selected.points[index].y);
          if (Math.hypot(clientX - handle.x, clientY - handle.y) <= 15) return { type: "point", pointIndex: index, geometry };
        }
      }
    }
    if (Math.hypot(clientX - geometry.rotation.x, clientY - geometry.rotation.y) <= 14) {
      return { type: "rotate", geometry };
    }
    for (const [name, handle] of Object.entries(geometry.handles)) {
      if (Math.abs(clientX - handle.x) <= 12 && Math.abs(clientY - handle.y) <= 12) {
        return { type: "scale", handle: name, geometry };
      }
    }
    if (clientX >= geometry.left && clientX <= geometry.right && clientY >= geometry.top && clientY <= geometry.bottom) {
      return { type: "move", geometry };
    }
    return null;
  }


  function transformPointWithNativeMetadata(point, transform) {
    const filtered = transform({ x: point.x, y: point.y });
    const hasRaw = Number.isFinite(point.x_raw) && Number.isFinite(point.y_raw);
    const raw = hasRaw ? transform({ x: point.x_raw, y: point.y_raw }) : filtered;
    return { ...point, x: filtered.x, y: filtered.y, x_raw: raw.x, y_raw: raw.y };
  }

  function refreshNativePageMetadata(stroke) {
    if (!stroke?.points?.length || !state.document.pages?.length) return stroke;
    let pageIndex = Number.isInteger(stroke.pageIndex) ? stroke.pageIndex : -1;
    if (pageIndex < 0 || pageIndex >= state.document.pages.length) {
      const centerY = stroke.points.reduce((sum, point) => sum + Number(point.y || 0), 0) / stroke.points.length;
      pageIndex = state.document.pages.reduce((best, page, index) => {
        const bestPage = state.document.pages[best];
        const distance = Math.abs(centerY - (page.y + page.height / 2));
        const bestDistance = Math.abs(centerY - (bestPage.y + bestPage.height / 2));
        return distance < bestDistance ? index : best;
      }, 0);
    }
    const page = state.document.pages[pageIndex];
    stroke.pageIndex = pageIndex;
    stroke.points = stroke.points.map(point => ({
      ...point,
      x_local: point.x - page.x,
      y_local: point.y - page.y,
      x_raw_local: Number.isFinite(point.x_raw) ? point.x_raw - page.x : point.x - page.x,
      y_raw_local: Number.isFinite(point.y_raw) ? point.y_raw - page.y : point.y - page.y,
    }));
    return stroke;
  }

  function transformSelectionFromOriginals(gesture, currentWorld) {
    if (!gesture.originals?.length) return;
    const start = gesture.startWorld;
    let transformPoint;
    let widthScale = 1;

    if (gesture.mode === "point") {
      const original = gesture.originals[0];
      if (!original) return;
      const transformed = cloneValue(original);
      const otherIndex = gesture.pointIndex === 0 ? transformed.points.length - 1 : 0;
      // The middle point of a quadratic curve is its bend/control handle, not
      // an endpoint. Endpoint/axis/tangent snapping would make curve editing
      // unexpectedly jump, so only the two curve ends participate in snaps.
      const shouldSnap = !(original.shapeType === "curve" && gesture.pointIndex === 1);
      const snapped = shouldSnap
        ? snapGeometryPoint(currentWorld, { strokeId: original.id, otherPoint: transformed.points[otherIndex] })
        : currentWorld;
      transformed.points[gesture.pointIndex] = transformPointWithNativeMetadata(
        transformed.points[gesture.pointIndex],
        () => ({ x: snapped.x, y: snapped.y }),
      );
      refreshNativePageMetadata(transformed);
      state.strokes.set(transformed.id, transformed);
      gesture.changed = true;
      markAllDirty();
      return;
    }

    if (gesture.mode === "move") {
      const dx = currentWorld.x - start.x;
      const dy = currentWorld.y - start.y;
      gesture.changed = gesture.changed || Math.hypot(dx, dy) * state.camera.zoom > 0.5;
      transformPoint = point => transformPointWithNativeMetadata(point, value => ({ x: value.x + dx, y: value.y + dy }));
    } else if (gesture.mode === "rotate") {
      const center = gesture.center;
      const angle = Math.atan2(currentWorld.y - center.y, currentWorld.x - center.x);
      const delta = angle - gesture.startAngle;
      const cosine = Math.cos(delta);
      const sine = Math.sin(delta);
      gesture.changed = gesture.changed || Math.abs(delta) > 0.003;
      transformPoint = point => transformPointWithNativeMetadata(point, value => {
        const dx = value.x - center.x;
        const dy = value.y - center.y;
        return { x: center.x + dx * cosine - dy * sine, y: center.y + dx * sine + dy * cosine };
      });
    } else {
      const anchor = gesture.anchor;
      const distance = Math.hypot(currentWorld.x - anchor.x, currentWorld.y - anchor.y);
      widthScale = Math.max(0.05, Math.min(20, distance / Math.max(0.001, gesture.startDistance)));
      gesture.changed = gesture.changed || Math.abs(widthScale - 1) > 0.003;
      transformPoint = point => transformPointWithNativeMetadata(point, value => ({
        x: anchor.x + (value.x - anchor.x) * widthScale,
        y: anchor.y + (value.y - anchor.y) * widthScale,
      }));
    }

    for (const original of gesture.originals) {
      const transformed = cloneValue(original);
      transformed.points = original.points.map(transformPoint);
      if (gesture.mode === "scale") transformed.width = Math.max(0.25, Math.min(100, original.width * widthScale));
      refreshNativePageMetadata(transformed);
      state.strokes.set(transformed.id, transformed);
    }
    markIpadStateDirty();
    markAllDirty();
  }

  function beginSelectionPointer(event) {
    event.preventDefault?.();
    const startWorld = screenToWorld(event.clientX, event.clientY);
    let hit = selectionHit(event.clientX, event.clientY);

    // In the selector, an unlocked geometry object can be picked up in one
    // Pencil/finger gesture. Locked geometry deliberately falls through to the
    // lasso path, so it must be surrounded before it can be edited.
    if (!hit && state.selectionIds.size === 0) {
      const directId = hitStrokeAt(startWorld, 10 / state.camera.zoom);
      const directStroke = directId ? state.strokes.get(directId) : null;
      if (isGeometryStroke(directStroke) && !directStroke.locked) {
        state.selectionIds = new Set([directId]);
        updateSelectionUI();
        const directGeometry = selectionScreenGeometry();
        if (directGeometry) hit = { type: "move", geometry: directGeometry };
      }
    }

    if (hit && state.selectionIds.size) {
      const originals = [...state.selectionIds]
        .map(id => state.strokes.get(id))
        .filter(Boolean)
        .map(cloneValue);
      const bounds = hit.geometry.bounds;
      const center = { x: (bounds.left + bounds.right) / 2, y: (bounds.top + bounds.bottom) / 2 };
      const gesture = {
        mode: hit.type,
        pointerId: event.pointerId,
        startWorld,
        originals,
        changed: false,
        center,
      };
      if (hit.type === "point") {
        gesture.pointIndex = hit.pointIndex;
      } else if (hit.type === "rotate") {
        gesture.startAngle = Math.atan2(startWorld.y - center.y, startWorld.x - center.x);
      } else if (hit.type === "scale") {
        const opposite = { nw: "se", ne: "sw", sw: "ne", se: "nw" }[hit.handle];
        const anchorScreen = hit.geometry.handles[opposite];
        gesture.anchor = screenToWorld(anchorScreen.x, anchorScreen.y);
        gesture.startDistance = Math.hypot(startWorld.x - gesture.anchor.x, startWorld.y - gesture.anchor.y);
      }
      state.selectionGesture = gesture;
      document.body.classList.add("selection-dragging");
    } else {
      if (!event.shiftKey) state.selectionIds.clear();
      state.selectionGesture = {
        mode: "lasso",
        pointerId: event.pointerId,
        additive: Boolean(event.shiftKey),
        points: [startWorld],
        startScreen: { x: event.clientX, y: event.clientY },
      };
      updateSelectionUI();
    }
    try { canvas.setPointerCapture(event.pointerId); } catch {}
    markAllDirty();
  }

  function updateSelectionPointer(event) {
    const gesture = state.selectionGesture;
    if (!gesture || event.pointerId !== gesture.pointerId) return false;
    event.preventDefault?.();
    const world = screenToWorld(event.clientX, event.clientY);
    if (gesture.mode === "lasso") {
      const last = gesture.points.at(-1);
      if (!last || Math.hypot(world.x - last.x, world.y - last.y) * state.camera.zoom >= 2) {
        gesture.points.push(world);
        state.liveDirty = true;
      }
    } else {
      transformSelectionFromOriginals(gesture, world);
    }
    return true;
  }

  function finishSelectionPointer(event, cancelled = false) {
    const gesture = state.selectionGesture;
    if (!gesture || (event && event.pointerId !== gesture.pointerId)) return false;
    if (event && !cancelled) updateSelectionPointer(event);

    if (gesture.mode === "lasso") {
      if (!cancelled) {
        const moved = event
          ? Math.hypot(event.clientX - gesture.startScreen.x, event.clientY - gesture.startScreen.y)
          : 0;
        if (gesture.points.length >= 3 && moved >= 8) {
          const selected = new Set(gesture.additive ? state.selectionIds : []);
          for (const [id, stroke] of state.strokes.entries()) {
            if (strokeSelectedByLasso(stroke, gesture.points)) selected.add(id);
          }
          state.selectionIds = selected;
        } else {
          const point = gesture.points[0];
          const hitId = hitStrokeAt(point, 10 / state.camera.zoom);
          state.selectionIds = new Set(hitId ? [hitId] : []);
        }
      }
    } else if (cancelled) {
      for (const original of gesture.originals || []) state.strokes.set(original.id, original);
    } else if (gesture.changed) {
      const replacements = [...state.selectionIds]
        .map(id => state.strokes.get(id))
        .filter(Boolean)
        .map(cloneValue);
      if (!send({ type: "replace_strokes", strokes: replacements })) {
        for (const original of gesture.originals || []) state.strokes.set(original.id, original);
        showToast("Selection change was not sent because the server is disconnected", 5000);
      } else {
        markIpadStateDirty();
      }
    }

    try { if (event) canvas.releasePointerCapture(event.pointerId); } catch {}
    state.selectionGesture = null;
    document.body.classList.remove("selection-dragging");
    updateSelectionUI();
    restoreTemporarySelectionTool();
    markAllDirty();
    return true;
  }

  function copySelectedItems() {
    state.selectionClipboard = [...state.selectionIds]
      .map(id => state.strokes.get(id))
      .filter(Boolean)
      .map(cloneValue);
    state.selectionPasteSerial = 0;
    updateSelectionUI();
    if (state.selectionClipboard.length) showToast(`${state.selectionClipboard.length} item${state.selectionClipboard.length === 1 ? "" : "s"} copied`);
  }

  function pasteSelectedItems() {
    if (!state.selectionClipboard.length) return;
    state.selectionPasteSerial += 1;
    const offset = 24 * state.selectionPasteSerial / state.camera.zoom;
    const stamp = Date.now();
    const strokes = state.selectionClipboard.map((source, index) => {
      const stroke = cloneValue(source);
      stroke.id = `${clientId}-copy-${stamp}-${index}-${Math.random().toString(16).slice(2)}`;
      stroke.owner = clientId;
      stroke.points = stroke.points.map(point => ({
        ...transformPointWithNativeMetadata(point, value => ({ x: value.x + offset, y: value.y + offset })),
        t: performance.now(),
      }));
      refreshNativePageMetadata(stroke);
      return stroke;
    });
    if (!send({ type: "add_strokes", strokes })) {
      showToast("Paste requires a server connection", 4000);
      return;
    }
    state.selectionIds.clear();
    for (const stroke of strokes) {
      state.strokes.set(stroke.id, stroke);
      state.selectionIds.add(stroke.id);
    }
    markIpadStateDirty();
    updateSelectionUI();
    markAllDirty();
    showToast(`${strokes.length} item${strokes.length === 1 ? "" : "s"} pasted`);
  }

  function deleteSelectedItems() {
    const ids = [...state.selectionIds].filter(id => state.strokes.has(id));
    if (!ids.length) return;
    for (const id of ids) {
      state.strokes.delete(id);
      state.liveStrokeIds.delete(id);
    }
    markIpadStateDirty();
    queueReliableDeletes(ids);
    clearSelection(false);
    restoreTemporarySelectionTool();
    markAllDirty();
    showToast(`${ids.length} item${ids.length === 1 ? "" : "s"} deleted`);
  }

  function renderScene() {
    sceneCtx.setTransform(state.dpr, 0, 0, state.dpr, 0, 0);
    sceneCtx.fillStyle = "#d9d9dc";
    sceneCtx.fillRect(0, 0, innerWidth, innerHeight);
    drawGrid();
    drawPages();
    // Locked coordinate planes are a dedicated background layer immediately
    // above the PDF and below every other note object, regardless of creation
    // order or later edits.
    for (const [id, stroke] of state.strokes.entries()) {
      if (state.textEdit?.id === id || state.liveStrokeIds.has(id)) continue;
      if (stroke.tool === "shape" && stroke.shapeType === "xy-plane" && stroke.locked) drawStroke(sceneCtx, stroke);
    }
    for (const [id, stroke] of state.strokes.entries()) {
      if (state.textEdit?.id === id || state.liveStrokeIds.has(id)) continue;
      if (stroke.tool === "shape" && stroke.shapeType === "xy-plane" && stroke.locked) continue;
      drawStroke(sceneCtx, stroke);
    }
    state.sceneDirty = false;
  }

  function renderLive() {
    liveCtx.setTransform(state.dpr, 0, 0, state.dpr, 0, 0);
    liveCtx.clearRect(0, 0, innerWidth, innerHeight);
    for (const id of state.liveStrokeIds) {
      if (state.textEdit?.id === id) continue;
      const stroke = state.strokes.get(id);
      if (stroke) drawStroke(liveCtx, stroke);
    }
    if (state.tool === "selector" || state.selectionIds.size || state.shapeGesture || state.snapGuide) drawSelectionOverlay(liveCtx);
    state.liveDirty = false;
  }

  function render() {
    resizeCanvas();
    if (mode === "ipad") {
      const cameraSignature = `${state.camera.x.toFixed(4)}:${state.camera.y.toFixed(4)}:${state.camera.zoom.toFixed(6)}:${documentStateKey(state.document)}`;
      if (cameraSignature !== lastCameraSignature) {
        lastCameraSignature = cameraSignature;
        scheduleIpadViewSave();
      }
    }
    positionTextEditor();
    const sceneWasDirty = state.sceneDirty;
    if (sceneWasDirty) renderScene();
    if (state.liveDirty || sceneWasDirty) renderLive();

    const now = performance.now();
    state.renderStats.frames += 1;
    const elapsed = now - state.renderStats.lastAt;
    if (elapsed >= 500) {
      state.renderStats.fps = state.renderStats.frames * 1000 / elapsed;
      state.renderStats.frames = 0;
      state.renderStats.lastAt = now;
      updateDebugPanel();
    }
    requestAnimationFrame(render);
  }

  function normalizedPressure(value, fallbackPressure = null) {
    const reported = Number(value);
    if (Number.isFinite(reported) && reported > 0) return Math.max(0.01, Math.min(1, reported));
    return Number.isFinite(fallbackPressure) ? fallbackPressure : 0.5;
  }

  function pointFromEvent(event, fallbackPressure = null) {
    const world = screenToWorld(event.clientX, event.clientY);
    const pressure = event.pointerType === "mouse"
      ? 0.5
      : normalizedPressure(event.pressure, fallbackPressure);
    return { x: world.x, y: world.y, p: pressure, t: performance.now() };
  }

  function pointFromTouch(touch, fallbackPressure = null) {
    const world = screenToWorld(touch.clientX, touch.clientY);
    return {
      x: world.x,
      y: world.y,
      p: normalizedPressure(touch.force, fallbackPressure),
      t: performance.now(),
    };
  }

  function pointerLikeFromTouch(touch) {
    return {
      clientX: touch.clientX,
      clientY: touch.clientY,
      pressure: normalizedPressure(touch.force, 0.5),
      pointerType: "pen",
      pointerId: `stylus-touch-${touch.identifier}`,
      timeStamp: performance.now(),
    };
  }

  function filterNewPoints(stroke, candidatePoints) {
    const accepted = [];
    let previous = stroke.points.at(-1);
    const minimumDistance = retainedPointSpacingPx(stroke) / state.camera.zoom;
    const minimumDistanceSquared = minimumDistance * minimumDistance;

    for (const point of candidatePoints) {
      if (!previous) {
        accepted.push(point);
        previous = point;
        continue;
      }
      const dx = point.x - previous.x;
      const dy = point.y - previous.y;
      const distanceSquared = dx * dx + dy * dy;
      const pressureChanged = Math.abs(point.p - previous.p) >= 0.02;
      // Release and compatibility events often repeat the last sample. Keep
      // genuine pressure/position changes but reject exact duplicates.
      if (distanceSquared >= minimumDistanceSquared || pressureChanged) {
        accepted.push(point);
        previous = point;
      } else {
        state.inputStats.duplicates += 1;
      }
    }
    return accepted;
  }

  function makeStroke(firstPoint) {
    const isHighlighter = state.tool === "highlighter";
    return {
      id: `${clientId}-${Date.now()}-${Math.random().toString(16).slice(2)}`,
      owner: clientId,
      tool: state.tool,
      color: colorEl.value,
      width: Number(widthEl.value),
      opacity: isHighlighter ? 0.28 : 1,
      lineStyle: state.lineStyle || "solid",
      smoothing: state.smoothing,
      strokeDetail: state.strokeDetail,
      points: [firstPoint],
    };
  }

  function startStrokeAt(point, { pointerId = null, touchIdentifier = null, source = "pointer", timestamp = performance.now() } = {}) {
    if (state.activeStrokeId !== null) {
      state.inputStats.forcedRestarts += 1;
      debugLog(`RAPID RESTART closed previous stroke ${state.activeStrokeId}`);
      finishActiveStroke(null, false);
    }
    state.contactGeneration += 1;

    // Finger contacts already resting on the screen are palms once Pencil ink
    // begins. Stop navigating without relying on WebKit to cancel those touches.
    state.touches.clear();
    state.gesture = null;

    const stroke = makeStroke(point);
    state.strokes.set(stroke.id, stroke);
    state.liveStrokeIds.add(stroke.id);
    state.activeStrokeId = stroke.id;
    state.activePointerId = pointerId;
    state.activeTouchIdentifier = touchIdentifier;
    state.activeInputSource = source;
    state.activePointerDownTimestamp = Number(timestamp) || performance.now();
    state.activeFilterPoint = point;
    state.activeRawPoints = [{ ...point }];
    state.activeOriginalTool = stroke.tool;
    state.sampleCount = 1;
    state.inputStats.starts += 1;
    state.debugRates.acceptedTotal += 1;
    state.lastPenEventAt = performance.now();
    state.lastPointerSampleAt = source === "touch" ? -Infinity : performance.now();
    state.lastStylusTouchAt = source === "touch" ? performance.now() : -Infinity;
    pressureEl.textContent = point.p.toFixed(2);
    sampleStatusEl.textContent = "1 accepted";
    updateInputDiagnostics(source === "touch" ? "Touch fallback" : "Pointer Events");
    debugLog(`START ${toolLabel(stroke.tool)} via ${source}; p=${point.p.toFixed(3)} id=${pointerId ?? touchIdentifier ?? "none"}`);
    send({ type: "stroke_begin", stroke });
    markIpadStateDirty();
    state.liveDirty = true;
  }

  function beginStroke(event) {
    // WebKit can send an in-contact pointerover immediately before pointerdown.
    // That recovery path has already opened the correct stroke, so promote it
    // instead of finalizing a one-point stroke and leaving a permanent start dot.
    const eventTime = Number(event.timeStamp) || performance.now();
    const recoveredIsSameContact = state.activeStrokeId
      && state.activeInputSource === "recovered-pointer"
      && (state.activePointerId === event.pointerId
        || Math.abs(eventTime - state.activePointerDownTimestamp) < 120);
    if (recoveredIsSameContact) {
      state.activePointerId = event.pointerId;
      state.activeInputSource = "pointer";
      state.activePointerDownTimestamp = eventTime;
      state.lastPenEventAt = performance.now();
      state.lastPointerSampleAt = performance.now();
      try { canvas.setPointerCapture(event.pointerId); } catch {}
      appendStrokeEvents(event);
      updateInputDiagnostics("Pointer Events");
      debugLog(`MERGE recovered pointerover into pointerdown id=${event.pointerId}`);
      return;
    }

    // If the TouchEvent fallback started first, merge the real PointerEvent into
    // that same stroke rather than creating a duplicate or ending the contact.
    if (state.activeStrokeId && state.activeInputSource === "touch" && event.pointerType === "pen") {
      state.activePointerId = event.pointerId;
      state.activeInputSource = "hybrid";
      state.activePointerDownTimestamp = eventTime;
      state.lastPenEventAt = performance.now();
      state.lastPointerSampleAt = performance.now();
      try { canvas.setPointerCapture(event.pointerId); } catch {}
      appendStrokeEvents(event);
      updateInputDiagnostics("Pointer + touch backup");
      return;
    }

    const point = pointFromEvent(event);
    startStrokeAt(point, {
      pointerId: event.pointerId,
      source: "pointer",
      timestamp: event.timeStamp,
    });
    try { canvas.setPointerCapture(event.pointerId); } catch {}
  }

  function stabilizePoints(candidatePoints, amount) {
    const strength = Math.max(0, Math.min(1, Number(amount) / 100));
    if (strength <= 0) {
      if (candidatePoints.length) state.activeFilterPoint = candidatePoints.at(-1);
      return candidatePoints;
    }

    const output = [];
    let previous = state.activeFilterPoint || candidatePoints[0];
    for (const raw of candidatePoints) {
      const screenDistance = Math.hypot(raw.x - previous.x, raw.y - previous.y) * state.camera.zoom;
      const baseAlpha = 1 - strength * 0.82;
      const adaptiveBoost = Math.min(1, screenDistance / 14) * strength * 0.58;
      const alpha = Math.min(1, baseAlpha + adaptiveBoost);
      const filtered = {
        x: previous.x + (raw.x - previous.x) * alpha,
        y: previous.y + (raw.y - previous.y) * alpha,
        p: previous.p + (raw.p - previous.p) * Math.max(alpha, 0.35),
        t: raw.t,
      };
      output.push(filtered);
      previous = filtered;
    }
    state.activeFilterPoint = previous;
    return output;
  }

  function eventSamples(event) {
    if (typeof event.getCoalescedEvents !== "function") return [event];
    state.inputStats.coalescedCalls += 1;
    const coalesced = [...(event.getCoalescedEvents() || [])];
    if (!coalesced.length) {
      state.inputStats.emptyCoalesced += 1;
      return [event];
    }
    state.inputStats.coalescedSamples += coalesced.length;

    // Some implementations include a clone of the parent event and some do
    // not. Add it only when its final coordinates/time are not already present.
    const last = coalesced.at(-1);
    const parentAlreadyIncluded = last
      && Math.abs(last.clientX - event.clientX) < 0.01
      && Math.abs(last.clientY - event.clientY) < 0.01
      && Math.abs(Number(last.timeStamp) - Number(event.timeStamp)) < 0.01;
    if (!parentAlreadyIncluded) coalesced.push(event);
    coalesced.sort((a, b) => Number(a.timeStamp) - Number(b.timeStamp));
    return coalesced;
  }

  function appendCandidatePoints(rawPoints, inputPath) {
    const stroke = state.strokes.get(state.activeStrokeId);
    if (!stroke || !rawPoints.length) return;
    const candidatePoints = stabilizePoints(rawPoints, stroke.smoothing ?? state.smoothing);

    // Recognition is a committed mode for the rest of this Pencil contact.
    // Continued motion edits the recognized line/curve instead of reverting it
    // to freehand ink. The raw samples are still streamed so the server can
    // safely replace the in-progress ink with the final geometry on Pencil-up.
    if (stroke.tool === "shape" && stroke.recognitionSource) {
      const rawProxy = { ...stroke, points: state.activeRawPoints };
      const points = filterNewPoints(rawProxy, candidatePoints);
      if (!points.length) {
        updateInputDiagnostics(inputPath);
        return;
      }
      state.activeRawPoints.push(...points.map(cloneValue));
      if (stroke.shapeType === "line") {
        const start = cloneValue(state.activeRawPoints[0]);
        const end = snapGeometryPoint(cloneValue(state.activeRawPoints.at(-1)), {
          strokeId: stroke.id,
          otherPoint: start,
        });
        stroke.points = [start, end];
        stroke.recognitionError = lineFitError(state.activeRawPoints);
      } else if (stroke.shapeType === "curve") {
        const fit = quadraticFit(state.activeRawPoints);
        if (fit) {
          stroke.points = fit.points;
          stroke.recognitionError = fit.error;
        } else {
          stroke.points[stroke.points.length - 1] = cloneValue(state.activeRawPoints.at(-1));
        }
      }
      state.lastRecognitionResult = `${stroke.shapeType} committed · ${Number(stroke.recognitionError || 0).toFixed(1)}%`;
      markIpadStateDirty();
      queueStrokePoints(stroke.id, points);
      state.sampleCount += points.length;
      state.debugRates.acceptedTotal += points.length;
      pressureEl.textContent = points.at(-1).p.toFixed(2);
      sampleStatusEl.textContent = `${state.sampleCount} accepted`;
      updateInputDiagnostics(inputPath);
      state.liveDirty = true;
      updateDebugPanel(true);
      return;
    }

    const points = filterNewPoints(stroke, candidatePoints);
    if (!points.length) {
      updateInputDiagnostics(inputPath);
      return;
    }
    stroke.points.push(...points);
    state.activeRawPoints.push(...points.map(cloneValue));
    scheduleGeometryRecognition();
    markIpadStateDirty();
    queueStrokePoints(stroke.id, points);
    state.sampleCount += points.length;
    state.debugRates.acceptedTotal += points.length;
    pressureEl.textContent = points.at(-1).p.toFixed(2);
    sampleStatusEl.textContent = `${state.sampleCount} accepted`;
    updateInputDiagnostics(inputPath);
    state.liveDirty = true;
  }

  function appendStrokeEvents(event) {
    const stroke = state.strokes.get(state.activeStrokeId);
    if (!stroke) return;
    state.lastPenEventAt = performance.now();
    state.lastPointerSampleAt = performance.now();
    state.inputStats.pointerMoves += 1;
    state.debugRates.pointerEventTotal += 1;
    const fallbackPressure = stroke.points.at(-1)?.p ?? 0.5;
    const rawPoints = eventSamples(event).map(sample => pointFromEvent(sample, fallbackPressure));
    appendCandidatePoints(rawPoints, activePointerPathLabel());
  }

  function appendStylusTouch(touch, forceBackup = false) {
    const stroke = state.strokes.get(state.activeStrokeId);
    if (!stroke) return;
    state.lastStylusTouchAt = performance.now();
    state.inputStats.touchMoves += 1;
    state.debugRates.touchEventTotal += 1;

    // Pointer Events remain the preferred path. Use TouchEvent samples only if
    // Pointer Events never started, were cancelled, or have gone quiet long
    // enough that this sample can fill a genuine gap.
    const pointerQuietFor = performance.now() - state.lastPointerSampleAt;
    const shouldUse = forceBackup
      || state.activeInputSource === "touch"
      || state.activePointerId === null
      || pointerQuietFor > 34;
    if (!shouldUse) {
      updateInputDiagnostics("Pointer + touch backup");
      return;
    }

    if (state.activeInputSource !== "touch") {
      state.activeInputSource = "hybrid";
      state.inputStats.fallbacks += 1;
      debugLog(`FALLBACK touch sample after ${pointerQuietFor.toFixed(1)} ms pointer gap`);
    }
    const fallbackPressure = stroke.points.at(-1)?.p ?? 0.5;
    appendCandidatePoints([pointFromTouch(touch, fallbackPressure)], "Pointer + touch backup");
  }

  function finishActiveStroke(event = null, includeFinalPoint = true) {
    const id = state.activeStrokeId;
    const pointerId = state.activePointerId;
    if (!id) return;

    if (event && includeFinalPoint && pointerId !== null && event.pointerId === pointerId) {
      const currentStroke = state.strokes.get(id);
      if (currentStroke?.tool === "shape" && currentStroke.recognitionSource) {
        // A pointerup often repeats or slightly jitters the last Pencil sample.
        // Treating that release coordinate as resumed movement would undo the
        // recognized preview exactly when the Pencil is lifted. Real resumed
        // drawing is already handled by pointermove before the release.
      } else {
        appendStrokeEvents(event);
      }
    }

    // WebSocket messages are ordered. Flush the final batch before the end
    // marker so another stroke can start immediately with no cooldown.
    flushPendingPoints(id);
    if (state.recognitionTimer !== null) { clearTimeout(state.recognitionTimer); state.recognitionTimer = null; }
    const completedStroke = state.strokes.get(id) ? cloneValue(state.strokes.get(id)) : null;
    const finalStroke = completedStroke?.tool === "shape" && completedStroke.recognitionSource
      ? completedStroke
      : null;
    state.activeStrokeId = null;
    state.activePointerId = null;
    state.activeTouchIdentifier = null;
    state.activeInputSource = null;
    state.activePointerDownTimestamp = -Infinity;
    state.activeFilterPoint = null;
    state.liveStrokeIds.delete(id);
    if (pointerId !== null) {
      try { canvas.releasePointerCapture(pointerId); } catch {}
    }
    send({ type: "stroke_end", id, stroke: finalStroke });
    state.activeRawPoints = [];
    state.activeOriginalTool = null;
    state.snapGuide = null;
    markIpadStateDirty();
    debugLog(`END stroke; ${state.sampleCount} accepted samples`);
    pressureEl.textContent = "—";
    markAllDirty();
  }

  function endStroke(event, includeFinalPoint = true) {
    if (event.pointerId !== state.activePointerId || !state.activeStrokeId) return;
    const eventTime = Number(event.timeStamp) || performance.now();
    // Ignore a delayed release from an older contact when Safari has already
    // reused the Pencil pointer id for a newer stroke.
    if (eventTime <= state.activePointerDownTimestamp + 0.25) {
      state.inputStats.staleReleases += 1;
      debugLog(`IGNORE stale pointer release t=${eventTime.toFixed(2)} down=${state.activePointerDownTimestamp.toFixed(2)}`);
      return;
    }
    state.lastPenEventAt = performance.now();
    finishActiveStroke(event, includeFinalPoint);
  }

  function pointSegmentDistanceSquared(p, a, b) {
    const vx = b.x - a.x;
    const vy = b.y - a.y;
    const wx = p.x - a.x;
    const wy = p.y - a.y;
    const len2 = vx * vx + vy * vy;
    if (len2 === 0) return wx * wx + wy * wy;
    const t = Math.max(0, Math.min(1, (wx * vx + wy * vy) / len2));
    const dx = p.x - (a.x + t * vx);
    const dy = p.y - (a.y + t * vy);
    return dx * dx + dy * dy;
  }

  function eraseAt(event) {
    const world = pointFromEvent(event);
    const threshold = (state.eraserSize / 2) / state.camera.zoom;
    const threshold2 = threshold * threshold;
    const deleted = [];
    for (const [id, stroke] of state.strokes.entries()) {
      // Every locked geometry object is protected from the eraser. A locked
      // object can only be recovered by surrounding it with the selector lasso.
      if (stroke.locked) {
        continue;
      }
      if (state.eraserHighlighterOnly && stroke.tool !== "highlighter") {
        continue;
      }
      const points = stroke.points || [];
      let hit = false;
      if (stroke.tool === "text" && points.length >= 4) {
        const box = points.slice(0, 4);
        hit = pointInPolygon(world, box);
        for (let i = 0; !hit && i < box.length; i++) {
          if (pointSegmentDistanceSquared(world, box[i], box[(i + 1) % box.length]) < threshold2) hit = true;
        }
      } else if (isGeometryStroke(stroke)) {
        const geometryPoints = geometryPolyline(stroke, 72);
        if (stroke.shapeType === "xy-plane") {
          const box = shapeBoxGeometry(stroke);
          if (box) {
            const local = worldToLocal(box, world);
            hit = local.x >= 0 && local.y >= 0 && local.x <= box.width && local.y <= box.height;
          }
        }
        for (let i = 1; !hit && i < geometryPoints.length; i++) {
          if (pointSegmentDistanceSquared(world, geometryPoints[i - 1], geometryPoints[i]) < threshold2) hit = true;
        }
      } else if (points.length === 1) {
        const dx = world.x - points[0].x;
        const dy = world.y - points[0].y;
        hit = dx * dx + dy * dy < threshold2;
      } else {
        for (let i = 1; i < points.length; i++) {
          if (pointSegmentDistanceSquared(world, points[i - 1], points[i]) < threshold2) {
            hit = true;
            break;
          }
        }
      }
      if (hit) {
        state.strokes.delete(id);
        state.liveStrokeIds.delete(id);
        state.eraserDeletedIds.add(id);
        deleted.push(id);
      }
    }
    if (deleted.length) {
      if (!state.activeEraseOperationId) {
        state.activeEraseOperationId = newOperationId("erase");
      }
      queueReliableDeletes(deleted, {
        operationId: state.activeEraseOperationId,
        final: false,
        defer: true,
      });
      markAllDirty();
    }
  }

  function finishEraserGesture() {
    const operationId = state.activeEraseOperationId;
    state.activeEraseOperationId = null;
    state.eraserDeletedIds.clear();
    if (!operationId) return;
    const operation = state.pendingDeleteOperations.get(operationId);
    if (!operation) return;
    operation.final = true;
    persistPendingDeletes();
    flushDeleteOperation(operation);
  }

  function updateEraserCursor(event, visible = true) {
    if (state.tool !== "eraser" || event.pointerType === "touch" || !visible) {
      eraserCursorEl.classList.remove("visible");
      return;
    }
    eraserCursorEl.style.width = `${state.eraserSize}px`;
    eraserCursorEl.style.height = `${state.eraserSize}px`;
    eraserCursorEl.style.left = `${event.clientX}px`;
    eraserCursorEl.style.top = `${event.clientY}px`;
    eraserCursorEl.classList.add("visible");
  }

  function beginEraserInput(eventLike, { pointerId = null, touchIdentifier = null, source = "pointer", timestamp = performance.now() } = {}) {
    if (state.activeStrokeId !== null) {
      state.inputStats.forcedRestarts += 1;
      finishActiveStroke(null, false);
    }
    state.contactGeneration += 1;
    state.activePointerId = pointerId;
    state.activeTouchIdentifier = touchIdentifier;
    state.activeInputSource = source;
    state.activePointerDownTimestamp = Number(timestamp) || performance.now();
    if (!state.activeEraseOperationId) {
      state.activeEraseOperationId = newOperationId("erase");
      state.eraserDeletedIds.clear();
    }
    state.inputStats.starts += 1;
    state.lastPenEventAt = performance.now();
    if (source === "touch") state.lastStylusTouchAt = performance.now();
    else state.lastPointerSampleAt = performance.now();
    updateEraserCursor(eventLike);
    eraseAt(eventLike);
    updateInputDiagnostics(source === "touch" ? "Touch fallback" : "Pointer Events");
  }

  function finishEraserInput() {
    finishEraserGesture();
    const pointerId = state.activePointerId;
    if (pointerId !== null) {
      try { canvas.releasePointerCapture(pointerId); } catch {}
    }
    state.activePointerId = null;
    state.activeTouchIdentifier = null;
    state.activeInputSource = null;
    state.activePointerDownTimestamp = -Infinity;
  }

  function isStylusTouch(touch) {
    return touch && touch.touchType === "stylus";
  }

  function stylusTouchesIn(touchList) {
    return Array.from(touchList || []).filter(isStylusTouch);
  }

  function beginPendingFingerInteraction(event, action, geometryId = null) {
    state.pendingFingerInteraction = {
      pointerId: event.pointerId,
      action,
      geometryId,
      startX: event.clientX,
      startY: event.clientY,
      x: event.clientX,
      y: event.clientY,
    };
    try { canvas.setPointerCapture(event.pointerId); } catch {}
  }

  function promotePendingFingerToNavigation(event = null) {
    const pending = state.pendingFingerInteraction;
    if (!pending) return false;
    state.pendingFingerInteraction = null;
    state.touches.set(pending.pointerId, {
      pointerId: pending.pointerId,
      x: pending.startX,
      y: pending.startY,
    });
    beginTouchGesture();
    if (event) {
      state.touches.set(pending.pointerId, {
        pointerId: pending.pointerId,
        x: event.clientX,
        y: event.clientY,
      });
      updateTouchGesture();
    }
    return true;
  }

  function updatePendingFingerInteraction(event) {
    const pending = state.pendingFingerInteraction;
    if (!pending || event.pointerId !== pending.pointerId) return false;
    pending.x = event.clientX;
    pending.y = event.clientY;
    if (Math.hypot(pending.x - pending.startX, pending.y - pending.startY) >= 10) {
      promotePendingFingerToNavigation(event);
    }
    return true;
  }

  function finishPendingFingerInteraction(event, cancelled = false) {
    const pending = state.pendingFingerInteraction;
    if (!pending || event.pointerId !== pending.pointerId) return false;
    state.pendingFingerInteraction = null;
    try { canvas.releasePointerCapture(event.pointerId); } catch {}
    if (cancelled) return true;

    if (pending.action === "select" && pending.geometryId) {
      beginTemporaryGeometrySelection(pending.geometryId);
    } else if (pending.action === "deselect") {
      clearSelection(false);
      restoreTemporarySelectionTool();
      markAllDirty();
    }
    return true;
  }

  function beginTouchGesture() {
    if (state.touches.size === 1) {
      if (state.panFingers !== 1) {
        state.gesture = null;
        return;
      }
      const [touch] = state.touches.values();
      state.gesture = {
        mode: "pan",
        pointerId: touch.pointerId,
        x: touch.x,
        y: touch.y,
      };
      return;
    }

    if (state.touches.size === 2) {
      const [a, b] = [...state.touches.values()];
      state.gesture = {
        mode: "pinch",
        centroidX: (a.x + b.x) / 2,
        centroidY: (a.y + b.y) / 2,
        distance: Math.hypot(b.x - a.x, b.y - a.y),
      };
      return;
    }

    state.gesture = null;
  }

  function updateTouchGesture() {
    if (state.touches.size === 1) {
      if (state.panFingers !== 1) {
        state.gesture = null;
        return;
      }
      const [touch] = state.touches.values();
      if (!state.gesture || state.gesture.mode !== "pan" || state.gesture.pointerId !== touch.pointerId) {
        beginTouchGesture();
        return;
      }
      const dx = touch.x - state.gesture.x;
      const dy = touch.y - state.gesture.y;
      state.camera.x -= dx / state.camera.zoom;
      state.camera.y -= dy / state.camera.zoom;
      state.gesture = { mode: "pan", pointerId: touch.pointerId, x: touch.x, y: touch.y };
      markAllDirty();
      return;
    }

    if (state.touches.size !== 2) return;
    const [a, b] = [...state.touches.values()];
    const centroidX = (a.x + b.x) / 2;
    const centroidY = (a.y + b.y) / 2;
    const distance = Math.max(1, Math.hypot(b.x - a.x, b.y - a.y));
    if (!state.gesture || state.gesture.mode !== "pinch") {
      beginTouchGesture();
      return;
    }

    const dx = centroidX - state.gesture.centroidX;
    const dy = centroidY - state.gesture.centroidY;
    state.camera.x -= dx / state.camera.zoom;
    state.camera.y -= dy / state.camera.zoom;
    const factor = distance / Math.max(1, state.gesture.distance);
    zoomAround(centroidX, centroidY, factor);
    state.gesture = { mode: "pinch", centroidX, centroidY, distance };
    markAllDirty();
  }

  // iPad Safari may attempt text selection, image dragging, callouts, or its own
  // pinch gesture during a long press. The canvas owns these interactions.
  for (const eventName of ["selectstart", "dragstart", "gesturestart", "gesturechange", "gestureend"]) {
    document.addEventListener(eventName, event => {
      if (event.target?.closest?.("#textEditorLayer")) return;
      event.preventDefault();
    }, { passive: false });
  }
  document.addEventListener("contextmenu", event => {
    if (mode === "ipad") event.preventDefault();
  }, { passive: false });
  document.addEventListener("selectionchange", () => {
    if (state.textEdit || document.activeElement === textEditorInput) return;
    const selection = window.getSelection?.();
    if (selection && !selection.isCollapsed) selection.removeAllRanges();
  });

  canvas.addEventListener("contextmenu", event => event.preventDefault());

  function eventTargetsCanvas(event) {
    const path = typeof event.composedPath === "function" ? event.composedPath() : [];
    return event.target === canvas || path.includes(canvas);
  }

  function drawingSurfaceAt(clientX, clientY) {
    const target = document.elementFromPoint(clientX, clientY);
    return target === canvas || target === sceneCanvas;
  }

  function makeTextBoxAt(world) {
    const boxWidth = Math.max(120, Math.min(360, 260 / state.camera.zoom));
    const boxHeight = Math.max(56, Math.min(180, 110 / state.camera.zoom));
    const timestamp = performance.now();
    return {
      id: `${clientId}-text-${Date.now()}-${Math.random().toString(16).slice(2)}`,
      owner: clientId,
      tool: "text",
      color: state.textColor,
      width: state.textFontSize,
      opacity: 1,
      lineStyle: "solid",
      smoothing: 0,
      strokeDetail: 100,
      text: "",
      textAlign: state.textAlign,
      fontFamily: "sans-serif",
      points: [
        { x: world.x, y: world.y, p: 0.5, t: timestamp },
        { x: world.x + boxWidth, y: world.y, p: 0.5, t: timestamp },
        { x: world.x + boxWidth, y: world.y + boxHeight, p: 0.5, t: timestamp },
        { x: world.x, y: world.y + boxHeight, p: 0.5, t: timestamp },
      ],
    };
  }

  function textStrokeAt(world) {
    const entries = [...state.strokes.entries()].reverse();
    for (const [id, stroke] of entries) {
      if (stroke.tool !== "text" || (stroke.points?.length || 0) < 4) continue;
      if (pointInPolygon(world, stroke.points.slice(0, 4))) return id;
    }
    return null;
  }

  function positionTextEditor() {
    if (!state.textEdit || textEditorLayer.hidden) return;
    const stroke = state.strokes.get(state.textEdit.id);
    const geometry = textBoxGeometry(stroke);
    if (!geometry) return;
    const topLeft = worldToScreen(geometry.topLeft.x, geometry.topLeft.y);
    const width = Math.max(80, geometry.width * state.camera.zoom);
    const height = Math.max(42, geometry.height * state.camera.zoom);
    const fontSize = Math.max(8, Number(stroke.width || 24) * state.camera.zoom);
    textEditorLayer.style.width = `${width}px`;
    textEditorLayer.style.height = `${height}px`;
    textEditorLayer.style.transform = `translate(${topLeft.x}px, ${topLeft.y}px) rotate(${geometry.angle}rad)`;
    textEditorLayer.style.setProperty("--text-editor-font-size", `${fontSize}px`);
    textEditorLayer.style.setProperty("--text-editor-color", stroke.color || "#111111");
    textEditorLayer.style.setProperty("--text-editor-align", stroke.textAlign || "left");
  }

  function updateTextEditorFromStroke(stroke) {
    if (!stroke) return;
    textFontSizeEl.value = String(Math.round(Number(stroke.width || 24)));
    textFontSizeValueEl.value = String(Math.round(Number(stroke.width || 24)));
    textColorEl.value = /^#[0-9a-f]{6}$/i.test(stroke.color || "") ? stroke.color : "#111111";
    for (const button of textAlignSelector.querySelectorAll("[data-text-align]")) {
      button.classList.toggle("active", button.dataset.textAlign === (stroke.textAlign || "left"));
    }
  }

  function openTextEditor(stroke, { isNew = false } = {}) {
    if (!stroke) return;
    if (state.textEdit && state.textEdit.id !== stroke.id) commitTextEdit();
    state.textEdit = {
      id: stroke.id,
      isNew,
      original: isNew ? null : cloneValue(stroke),
    };
    state.textFontSize = Number(stroke.width || 24);
    state.textColor = stroke.color || "#111111";
    state.textAlign = stroke.textAlign || "left";
    updateTextEditorFromStroke(stroke);
    textEditorInput.value = String(stroke.text || "");
    textEditorLayer.hidden = false;
    document.body.classList.add("text-editing");
    positionTextEditor();
    try {
      textEditorInput.focus({ preventScroll: true });
      textEditorInput.setSelectionRange(textEditorInput.value.length, textEditorInput.value.length);
    } catch {}
    markAllDirty();
  }

  function closeTextEditor() {
    state.textEdit = null;
    textEditorLayer.hidden = true;
    document.body.classList.remove("text-editing");
    markAllDirty();
  }

  function commitTextEdit() {
    const edit = state.textEdit;
    if (!edit) return true;
    const stroke = state.strokes.get(edit.id);
    if (!stroke) {
      closeTextEditor();
      return false;
    }
    stroke.text = String(textEditorInput.value || "").slice(0, 20000);
    if (!stroke.text.trim()) {
      if (edit.isNew) {
        state.strokes.delete(stroke.id);
        closeTextEditor();
        return true;
      }
      state.strokes.delete(stroke.id);
      queueReliableDeletes([stroke.id]);
      closeTextEditor();
      showToast("Empty text box removed");
      return true;
    }
    const message = edit.isNew
      ? { type: "add_strokes", strokes: [cloneValue(stroke)] }
      : { type: "replace_strokes", strokes: [cloneValue(stroke)] };
    if (!send(message)) {
      if (edit.isNew) state.strokes.delete(stroke.id);
      else state.strokes.set(stroke.id, edit.original);
      showToast("Text change was not saved because the server is disconnected", 5000);
      closeTextEditor();
      return false;
    }
    closeTextEditor();
    showToast(edit.isNew ? "Text box added" : "Text box updated");
    return true;
  }

  function cancelTextEdit() {
    const edit = state.textEdit;
    if (!edit) return;
    if (edit.isNew) state.strokes.delete(edit.id);
    else if (edit.original) state.strokes.set(edit.id, edit.original);
    closeTextEditor();
  }

  function beginTextPointer(event) {
    event.preventDefault?.();
    const world = screenToWorld(event.clientX, event.clientY);
    const hitId = textStrokeAt(world);
    if (hitId) {
      if (state.textEdit?.id === hitId) {
        try { textEditorInput.focus({ preventScroll: true }); } catch {}
        return true;
      }
      openTextEditor(state.strokes.get(hitId), { isNew: false });
      return true;
    }
    const stroke = makeTextBoxAt(world);
    state.strokes.set(stroke.id, stroke);
    openTextEditor(stroke, { isNew: true });
    return true;
  }

  function penIsInContact(event) {
    if (event.pointerType !== "pen") return false;
    const pressure = Number(event.pressure) || 0;
    const buttons = Number(event.buttons) || 0;
    return pressure > 0.001 || buttons !== 0;
  }

  function activePointerPathLabel() {
    if (state.activeInputSource === "hybrid") return "Pointer + touch backup";
    if (state.activeInputSource === "recovered-pointer") return "Recovered pointer move";
    return "Pointer Events";
  }

  function beginPenPointerContact(event, origin = "canvas") {
    if (event.pointerType !== "pen" || !eventTargetsCanvas(event)) return false;
    if (handledPenDownEvents.has(event)) return true;
    handledPenDownEvents.add(event);
    event.preventDefault();
    state.inputStats.capturedDowns += 1;
    debugLog(`DOWN captured at ${origin}; id=${event.pointerId} p=${Number(event.pressure || 0).toFixed(3)}`);

    state.lastPenEventAt = performance.now();
    if (state.tool === "text") {
      beginTextPointer(event);
      return true;
    }
    if (state.tool === "shape") {
      beginShapePointer(event);
      return true;
    }
    if (state.tool === "selector") {
      if (state.selectionGesture && state.activeTouchIdentifier !== null) {
        state.selectionGesture.pointerId = event.pointerId;
        try { canvas.setPointerCapture(event.pointerId); } catch {}
        debugLog(`SELECTOR merged TouchEvent fallback with pointer ${event.pointerId}`);
      } else {
        beginSelectionPointer(event);
      }
      return true;
    }
    if (state.tool === "eraser") {
      if (state.activeInputSource === "touch" && state.activeTouchIdentifier !== null) {
        state.activePointerId = event.pointerId;
        state.activeInputSource = "hybrid";
        state.activePointerDownTimestamp = Number(event.timeStamp) || performance.now();
        state.lastPointerSampleAt = performance.now();
        try { canvas.setPointerCapture(event.pointerId); } catch {}
        updateEraserCursor(event);
        eraseAt(event);
        updateInputDiagnostics("Pointer + touch backup");
      } else {
        beginEraserInput(event, {
          pointerId: event.pointerId,
          source: "pointer",
          timestamp: event.timeStamp,
        });
        try { canvas.setPointerCapture(event.pointerId); } catch {}
      }
      return true;
    }

    beginStroke(event);
    return true;
  }

  function recoverPenContactFromMotion(event, origin = "pointermove") {
    if (!penIsInContact(event) || !drawingSurfaceAt(event.clientX, event.clientY)) return false;
    if (state.tool === "text") return false;
    if (state.tool === "shape") {
      state.inputStats.recoveredStarts += 1;
      beginShapePointer(event);
      return true;
    }
    if (state.tool === "selector") {
      state.inputStats.recoveredStarts += 1;
      debugLog(`RECOVER selector from ${origin}; id=${event.pointerId}`);
      beginSelectionPointer(event);
      return true;
    }
    event.preventDefault();

    state.inputStats.contactMovesNoDown += 1;
    state.inputStats.pointerMoves += 1;
    state.debugRates.pointerEventTotal += 1;
    state.inputStats.recoveredStarts += 1;
    debugLog(`RECOVER start from ${origin}; id=${event.pointerId} buttons=${event.buttons} p=${Number(event.pressure || 0).toFixed(3)}`);

    const samples = eventSamples(event);
    const firstSample = samples[0] || event;
    if (state.tool === "eraser") {
      beginEraserInput(firstSample, {
        pointerId: event.pointerId,
        source: "recovered-pointer",
        timestamp: event.timeStamp,
      });
      for (const sample of samples.slice(1)) eraseAt(sample);
    } else {
      const firstPoint = pointFromEvent(firstSample);
      startStrokeAt(firstPoint, {
        pointerId: event.pointerId,
        source: "recovered-pointer",
        timestamp: event.timeStamp,
      });
      if (samples.length > 1) {
        const stroke = state.strokes.get(state.activeStrokeId);
        const fallbackPressure = stroke?.points.at(-1)?.p ?? 0.5;
        const rawPoints = samples.slice(1).map(sample => pointFromEvent(sample, fallbackPressure));
        appendCandidatePoints(rawPoints, "Recovered pointer move");
      }
      try { canvas.setPointerCapture(event.pointerId); } catch {}
    }
    updateInputDiagnostics("Recovered pointer move");
    return true;
  }

  // Capture Pencil contact before the event reaches the canvas. This protects
  // rapid contacts from target/capture changes inside WebKit.
  window.addEventListener("pointerdown", event => {
    if (event.pointerType === "pen") beginPenPointerContact(event, "window capture");
  }, { passive: false, capture: true });

  // If WebKit omits pointerdown but delivers an in-contact pointerover, recover
  // the stroke immediately instead of waiting for a later movement.
  window.addEventListener("pointerover", event => {
    if (state.tool === "text") return;
    if (event.pointerType !== "pen" || state.activePointerId !== null || state.selectionGesture) return;
    recoverPenContactFromMotion(event, "pointerover");
  }, { passive: false, capture: true });

  canvas.addEventListener("pointerdown", event => {
    event.preventDefault();

    if (event.pointerType === "touch") {
      if (state.activeStrokeId !== null || state.activeInputSource === "touch" || state.activeInputSource === "hybrid") return;

      // A second finger always converts a pending one-finger tap into normal
      // pan/pinch navigation instead of selecting geometry.
      if (state.pendingFingerInteraction && state.pendingFingerInteraction.pointerId !== event.pointerId) {
        promotePendingFingerToNavigation();
        state.touches.set(event.pointerId, {
          pointerId: event.pointerId,
          x: event.clientX,
          y: event.clientY,
        });
        try { canvas.setPointerCapture(event.pointerId); } catch {}
        beginTouchGesture();
        return;
      }

      const world = screenToWorld(event.clientX, event.clientY);
      const geometryId = shapeStrokeAt(world);

      if (state.tool === "selector" && state.temporarySelectionReturnMode !== null) {
        // While a temporary geometry selection is active, dragging the selected
        // object edits it. A plain tap elsewhere deselects and restores the
        // previous pen/eraser/text/shape tool.
        if (geometryId && state.selectionIds.has(geometryId)) {
          beginSelectionPointer(event);
        } else if (geometryId) {
          beginPendingFingerInteraction(event, "select", geometryId);
        } else {
          beginPendingFingerInteraction(event, "deselect");
        }
        return;
      }

      if (state.tool === "selector") {
        beginSelectionPointer(event);
        return;
      }

      // In every non-selector tool, an unlocked geometry object is selected
      // only after a true one-finger tap. Moving the finger instead pans, so a
      // shape can never steal a navigation gesture on pointerdown.
      if (geometryId) {
        beginPendingFingerInteraction(event, "select", geometryId);
        return;
      }

      state.touches.set(event.pointerId, {
        pointerId: event.pointerId,
        x: event.clientX,
        y: event.clientY,
      });
      try { canvas.setPointerCapture(event.pointerId); } catch {}
      beginTouchGesture();
      return;
    }

    const panButton = event.button === 1 || event.button === 2 || event.buttons === 4;
    if (panButton) {
      state.mousePanning = true;
      state.lastMouse = { x: event.clientX, y: event.clientY };
      try { canvas.setPointerCapture(event.pointerId); } catch {}
      canvas.style.cursor = "grabbing";
      return;
    }

    if (event.pointerType === "pen") {
      beginPenPointerContact(event, "canvas bubble");
      return;
    }

    if (state.tool === "selector"
        && mode !== "ipad"
        && event.pointerType === "mouse"
        && event.button === 0
        && performance.now() - state.lastPenEventAt >= 750) {
      beginSelectionPointer(event);
      return;
    }

    // On iPad, fingers navigate and only Pencil input draws. Reject Safari's
    // compatibility mouse event that can follow a Pencil event.
    const syntheticMouseAfterPen = event.pointerType === "mouse" && performance.now() - state.lastPenEventAt < 750;
    const canDraw = mode !== "ipad" && event.pointerType === "mouse" && event.button === 0;
    if (syntheticMouseAfterPen || !canDraw) return;

    // Do not mark ordinary desktop mouse input as Pencil input. Otherwise the
    // next mouse gesture inside 750 ms is discarded as a synthetic post-Pencil
    // event.
    if (state.tool === "text") {
      beginTextPointer(event);
      return;
    }
    if (state.tool === "shape") {
      beginShapePointer(event);
      return;
    }
    if (state.tool === "eraser") {
      beginEraserInput(event, {
        pointerId: event.pointerId,
        source: "pointer",
        timestamp: event.timeStamp,
      });
      try { canvas.setPointerCapture(event.pointerId); } catch {}
      return;
    }

    beginStroke(event);
  }, { passive: false });

  canvas.addEventListener("dblclick", event => {
    if (mode === "ipad" || state.textEdit) return;
    const world = screenToWorld(event.clientX, event.clientY);
    const id = textStrokeAt(world);
    if (!id) return;
    event.preventDefault();
    openTextEditor(state.strokes.get(id), { isNew: false });
  });

  canvas.addEventListener("pointermove", event => {
    event.preventDefault();
    updateEraserCursor(event);

    if (event.pointerType === "touch") {
      if (state.selectionGesture && updateSelectionPointer(event)) return;
      if (updatePendingFingerInteraction(event)) return;
      if (state.touches.has(event.pointerId)) {
        state.touches.set(event.pointerId, {
          pointerId: event.pointerId,
          x: event.clientX,
          y: event.clientY,
        });
        updateTouchGesture();
      }
      return;
    }

    // Active Pencil movement is handled once at window capture level. Keeping
    // one ordered PointerEvent stream avoids duplicate/out-of-order samples
    // from processing both pointermove and pointerrawupdate.
    if (event.pointerType === "pen") return;

    if (state.tool === "shape" && updateShapePointer(event)) return;
    if (state.tool === "selector" && updateSelectionPointer(event)) return;

    if (state.mousePanning && state.lastMouse) {
      const dx = event.clientX - state.lastMouse.x;
      const dy = event.clientY - state.lastMouse.y;
      state.camera.x -= dx / state.camera.zoom;
      state.camera.y -= dy / state.camera.zoom;
      state.lastMouse = { x: event.clientX, y: event.clientY };
      markAllDirty();
      return;
    }

    if (state.tool === "eraser" && event.pointerId === state.activePointerId) {
      eraseAt(event);
      return;
    }

    if (event.pointerId === state.activePointerId && state.activeStrokeId) appendStrokeEvents(event);
  }, { passive: false });

  window.addEventListener("pointermove", event => {
    if (event.pointerType !== "pen") return;
    if (state.tool === "shape") {
      if (!updateShapePointer(event)) recoverPenContactFromMotion(event, "pointermove");
      return;
    }
    if (state.tool === "selector") {
      if (!updateSelectionPointer(event)) recoverPenContactFromMotion(event, "pointermove");
      return;
    }

    if (event.pointerId !== state.activePointerId) {
      if (!recoverPenContactFromMotion(event, "pointermove")) return;
      // The recovery function consumed this event's coalesced samples.
      return;
    }

    event.preventDefault();
    state.lastPointerSampleAt = performance.now();
    updateEraserCursor(event);
    if (state.tool === "eraser") {
      state.inputStats.pointerMoves += 1;
      state.debugRates.pointerEventTotal += 1;
      eraseAt(event);
      updateInputDiagnostics(activePointerPathLabel());
    } else if (state.activeStrokeId) {
      appendStrokeEvents(event);
    }
  }, { passive: false, capture: true });

  // Legacy TouchEvent stylus input is retained as a safety net for WebKit.
  // It can recover a contact when the corresponding PointerEvent is missing or
  // when PointerEvents go quiet/cancel mid-stroke.
  canvas.addEventListener("touchstart", event => {
    const stylusTouches = stylusTouchesIn(event.changedTouches);
    if (!stylusTouches.length) return;
    event.preventDefault();

    for (const touch of stylusTouches) {
      state.stylusTouches.set(touch.identifier, touch);
      state.lastStylusTouchAt = performance.now();

      if (state.activeStrokeId || state.activePointerId !== null) {
        if (state.activeTouchIdentifier === null) state.activeTouchIdentifier = touch.identifier;
        if (state.activeInputSource === "pointer") state.activeInputSource = "hybrid";
        updateInputDiagnostics("Pointer + touch backup");
        continue;
      }

      state.inputStats.fallbacks += 1;
      debugLog(`FALLBACK stylus touchstart id=${touch.identifier}`);
      const eventLike = pointerLikeFromTouch(touch);
      if (state.tool === "text") {
        if (!state.textEdit) beginTextPointer(eventLike);
        continue;
      }
      if (state.tool === "shape") {
        state.activeTouchIdentifier = touch.identifier;
        beginShapePointer(eventLike);
        continue;
      }
      if (state.tool === "selector") {
        if (!state.selectionGesture) {
          state.activeTouchIdentifier = touch.identifier;
          beginSelectionPointer(eventLike);
          updateInputDiagnostics("Touch fallback");
        }
        continue;
      }
      if (state.tool === "eraser") {
        beginEraserInput(eventLike, {
          touchIdentifier: touch.identifier,
          source: "touch",
          timestamp: event.timeStamp,
        });
      } else {
        startStrokeAt(pointFromTouch(touch), {
          touchIdentifier: touch.identifier,
          source: "touch",
          timestamp: event.timeStamp,
        });
      }
    }
  }, { passive: false });

  canvas.addEventListener("touchmove", event => {
    const stylusTouches = stylusTouchesIn(event.changedTouches);
    if (!stylusTouches.length) return;
    event.preventDefault();

    for (const touch of stylusTouches) {
      state.stylusTouches.set(touch.identifier, touch);
      if (touch.identifier !== state.activeTouchIdentifier) continue;

      if (state.tool === "text") continue;

      if (state.tool === "shape") {
        const eventLike = pointerLikeFromTouch(touch);
        updateShapePointer(eventLike);
        continue;
      }

      if (state.tool === "selector") {
        const eventLike = pointerLikeFromTouch(touch);
        if (state.selectionGesture?.pointerId === eventLike.pointerId) updateSelectionPointer(eventLike);
        continue;
      }

      if (state.tool === "eraser") {
        const pointerQuietFor = performance.now() - state.lastPointerSampleAt;
        const shouldUse = state.activeInputSource === "touch"
          || state.activePointerId === null
          || pointerQuietFor > 34;
        if (shouldUse) {
          if (state.activeInputSource !== "touch") {
            state.activeInputSource = "hybrid";
            state.inputStats.fallbacks += 1;
            debugLog(`FALLBACK eraser touch after ${pointerQuietFor.toFixed(1)} ms pointer gap`);
          }
          const eventLike = pointerLikeFromTouch(touch);
          updateEraserCursor(eventLike);
          eraseAt(eventLike);
          state.inputStats.touchMoves += 1;
          state.debugRates.touchEventTotal += 1;
          updateInputDiagnostics("Pointer + touch backup");
        }
      } else {
        appendStylusTouch(touch);
      }
    }
  }, { passive: false });

  function finishStylusTouch(event, cancelled = false) {
    const stylusTouches = stylusTouchesIn(event.changedTouches);
    if (stylusTouches.length) event.preventDefault();
    for (const touch of stylusTouches) {
      state.stylusTouches.delete(touch.identifier);
      if (touch.identifier !== state.activeTouchIdentifier) continue;

      // Pointer Events are authoritative whenever a Pencil pointer is still
      // active. Safari can deliver the legacy stylus touchend late, sometimes
      // after the next rapid pointerdown with the same touch identifier. Letting
      // that stale touchend finish the active stroke caused the third mark in a
      // quick "t" / "+" sequence to be closed immediately and appear skipped.
      // The next pointerup, pointercancel, new pointerdown, or window blur will
      // finish the stroke safely. TouchEvent endings only own pure fallback
      // strokes after Pointer Events have actually disappeared.
      const pointerOwnsContact = state.activePointerId !== null
        && state.activeInputSource !== "touch";
      if (state.tool === "shape") {
        const eventLike = pointerLikeFromTouch(touch);
        if (pointerOwnsContact) {
          state.activeTouchIdentifier = null;
          state.inputStats.deferredTouchEnds += 1;
          debugLog(`DEFER shape ${cancelled ? "touchcancel" : "touchend"}; pointer owns contact`);
        } else {
          finishShapePointer(eventLike, cancelled);
          state.activeTouchIdentifier = null;
        }
        continue;
      }
      if (state.tool === "selector") {
        const eventLike = pointerLikeFromTouch(touch);
        if (typeof state.selectionGesture?.pointerId === "number") {
          state.activeTouchIdentifier = null;
          state.inputStats.deferredTouchEnds += 1;
          debugLog(`DEFER selector ${cancelled ? "touchcancel" : "touchend"}; pointer owns contact`);
        } else {
          finishSelectionPointer(eventLike, cancelled);
          state.activeTouchIdentifier = null;
        }
        continue;
      }

      if (pointerOwnsContact) {
        state.activeTouchIdentifier = null;
        state.inputStats.deferredTouchEnds += 1;
        if (state.activeInputSource === "hybrid") state.activeInputSource = "pointer";
        debugLog(`DEFER ${cancelled ? "touchcancel" : "touchend"}; pointer ${state.activePointerId} owns contact`);
        updateInputDiagnostics("Pointer Events");
        continue;
      }

      if (state.tool === "eraser") {
        if (!cancelled) {
          const eventLike = pointerLikeFromTouch(touch);
          updateEraserCursor(eventLike);
          eraseAt(eventLike);
        }
        finishEraserInput();
      } else if (state.activeStrokeId) {
        if (!cancelled) appendStylusTouch(touch, true);
        finishActiveStroke(null, false);
      }
    }
  }

  canvas.addEventListener("touchend", event => finishStylusTouch(event, false), { passive: false });
  canvas.addEventListener("touchcancel", event => finishStylusTouch(event, true), { passive: false });

  canvas.addEventListener("pointerleave", event => {
    if (event.pointerId !== state.activePointerId) updateEraserCursor(event, false);
  });

  function finishPointer(event, includeFinalPoint = event.type !== "pointercancel") {
    if (state.shapeGesture && event.pointerId === state.shapeGesture.pointerId) {
      finishShapePointer(event, !includeFinalPoint);
      return;
    }
    if (state.selectionGesture && event.pointerId === state.selectionGesture.pointerId) {
      finishSelectionPointer(event, !includeFinalPoint);
      return;
    }
    if (event.pointerType === "touch") {
      if (finishPendingFingerInteraction(event, !includeFinalPoint)) return;
      state.touches.delete(event.pointerId);
      beginTouchGesture();
      return;
    }
    if (state.mousePanning) {
      state.mousePanning = false;
      state.lastMouse = null;
      canvas.style.cursor = "crosshair";
      return;
    }
    if (state.tool === "eraser" && event.pointerId === state.activePointerId) {
      if (includeFinalPoint) eraseAt(event);
      finishEraserInput();
      return;
    }
    endStroke(event, includeFinalPoint);
  }

  canvas.addEventListener("pointerup", finishPointer, { passive: false });
  canvas.addEventListener("pointercancel", event => {
    state.inputStats.cancels += 1;
    debugLog(`CANCEL pointer ${event.pointerId} on canvas`);
    // If WebKit cancelled Pointer Events but the stylus TouchEvent contact is
    // still alive, keep the stroke open and continue through the backup path.
    if (event.pointerId === state.activePointerId
        && state.activeTouchIdentifier !== null
        && state.stylusTouches.has(state.activeTouchIdentifier)) {
      state.activePointerId = null;
      state.activeInputSource = "touch";
      state.inputStats.fallbacks += 1;
      debugLog("FALLBACK continued by TouchEvent after cancel");
      updateInputDiagnostics("Touch fallback after cancel");
      return;
    }
    finishPointer(event, false);
  }, { passive: false });

  canvas.addEventListener("lostpointercapture", event => {
    if (event.pointerId !== state.activePointerId) return;
    // Do not end the stroke here. WebKit can lose capture while still delivering
    // events to window; the global handlers continue tracking the contact.
    state.inputStats.lostCapture += 1;
    debugLog(`LOST CAPTURE pointer ${event.pointerId}`);
    updateInputDiagnostics(state.activeInputSource === "hybrid" ? "Pointer + touch backup" : "Pointer Events");
  });

  // Safety net for iPadOS delivering movement/release outside the original
  // canvas target or after pointer capture is lost.
  window.addEventListener("pointerup", event => {
    if (event.pointerId === state.activePointerId
        || state.touches.has(event.pointerId)
        || event.pointerId === state.selectionGesture?.pointerId) {
      finishPointer(event, true);
    }
  }, { passive: false, capture: true });
  window.addEventListener("pointercancel", event => {
    if (event.pointerId !== state.activePointerId
        && !state.touches.has(event.pointerId)
        && event.pointerId !== state.selectionGesture?.pointerId) return;
    state.inputStats.cancels += 1;
    debugLog(`CANCEL pointer ${event.pointerId} on window`);
    if (event.pointerId === state.activePointerId
        && state.activeTouchIdentifier !== null
        && state.stylusTouches.has(state.activeTouchIdentifier)) {
      state.activePointerId = null;
      state.activeInputSource = "touch";
      state.inputStats.fallbacks += 1;
      debugLog("FALLBACK continued by TouchEvent after window cancel");
      updateInputDiagnostics("Touch fallback after cancel");
      return;
    }
    finishPointer(event, false);
  }, { passive: false, capture: true });

  canvas.addEventListener("wheel", event => {
    event.preventDefault();
    const factor = Math.exp(-event.deltaY * 0.0015);
    zoomAround(event.clientX, event.clientY, factor);
  }, { passive: false });


  let editingPreset = null;
  let editingColorId = null;
  let colorPress = null;
  let colorDrag = null;
  let suppressColorClickUntil = 0;

  function clampNumber(value, minimum, maximum, fallback) {
    const number = Number(value);
    if (!Number.isFinite(number)) return fallback;
    return Math.max(minimum, Math.min(maximum, number));
  }

  function normalizeDrawPresets(input, defaults, allowPressure) {
    const source = Array.isArray(input) ? input : defaults;
    return defaults.map((fallback, index) => {
      const candidate = source[index] || fallback;
      const style = ["solid", "dashed", "dotted"].includes(candidate.style)
        ? candidate.style
        : fallback.style;
      return {
        width: clampNumber(candidate.width, 0.5, 60, fallback.width),
        style,
        pressure: allowPressure
          ? candidate.pressure !== false
          : false,
      };
    });
  }

  function normalizeEraserPresets(input) {
    const source = Array.isArray(input) ? input : DEFAULT_ERASER_PRESETS;
    return DEFAULT_ERASER_PRESETS.map((fallback, index) => ({
      size: clampNumber(
        source[index]?.size,
        8,
        120,
        fallback.size
      ),
    }));
  }

  function normalizeColors(input) {
    const output = [];
    for (const candidate of Array.isArray(input) ? input : []) {
      const value = String(candidate?.value || "").toLowerCase();
      if (!/^#[0-9a-f]{6}$/.test(value)) continue;
      output.push({
        id: String(candidate.id || crypto.randomUUID()),
        value,
      });
    }
    return output.length ? output : structuredClone(DEFAULT_COLORS);
  }

  function persistToolbarSettings() {
    storeSetting("infiniteNotes.toolbarMode", state.toolbarMode);
    storeSetting("infiniteNotes.drawTool", state.drawTool);
    storeSetting("infiniteNotes.penPresetIndex", state.penPresetIndex);
    storeSetting(
      "infiniteNotes.highlighterPresetIndex",
      state.highlighterPresetIndex
    );
    storeSetting(
      "infiniteNotes.eraserPresetIndex",
      state.eraserPresetIndex
    );
    storeSetting(
      "infiniteNotes.eraserHighlighterOnly",
      state.eraserHighlighterOnly ? 1 : 0
    );
    storeSetting("infiniteNotes.activeColorId", state.activeColorId);
    storeSetting("infiniteNotes.textFontSize", state.textFontSize);
    storeSetting("infiniteNotes.textColor", state.textColor);
    storeSetting("infiniteNotes.textAlign", state.textAlign);
    storeSetting("infiniteNotes.shapeType", state.shapeType);
    storeSetting("infiniteNotes.recognitionHoldMs", state.recognitionHoldMs);
    storeSetting("infiniteNotes.lineRecognitionTolerance", state.lineRecognitionTolerance);
    storeSetting("infiniteNotes.curveRecognitionTolerance", state.curveRecognitionTolerance);
    storeSetting("infiniteNotes.geometrySnapDistance", state.geometrySnapDistance);
    storeSetting("infiniteNotes.endpointSnap", state.endpointSnap ? 1 : 0);
    storeSetting("infiniteNotes.axisSnap", state.axisSnap ? 1 : 0);
    storeSetting("infiniteNotes.tangentSnap", state.tangentSnap ? 1 : 0);
    storeSetting("infiniteNotes.normalSnap", state.normalSnap ? 1 : 0);
    storeJson("infiniteNotes.penPresets", state.penPresets);
    storeJson(
      "infiniteNotes.highlighterPresets",
      state.highlighterPresets
    );
    storeJson("infiniteNotes.eraserPresets", state.eraserPresets);
    storeJson("infiniteNotes.colors", state.colors);
  }

  function presetArrayFor(tool) {
    return tool === "highlighter"
      ? state.highlighterPresets
      : state.penPresets;
  }

  function currentDrawPresetIndex() {
    return state.drawTool === "highlighter"
      ? state.highlighterPresetIndex
      : state.penPresetIndex;
  }

  function setCurrentDrawPresetIndex(index) {
    if (state.drawTool === "highlighter") {
      state.highlighterPresetIndex = index;
    } else {
      state.penPresetIndex = index;
    }
  }

  function currentDrawPreset() {
    return presetArrayFor(state.drawTool)[currentDrawPresetIndex()];
  }

  function currentColor() {
    let colour = state.colors.find(item => item.id === state.activeColorId);
    if (!colour) {
      colour = state.colors[0];
      state.activeColorId = colour.id;
    }
    return colour;
  }

  function positionPopover(popover, anchor) {
    if (!popover || !anchor) return;
    popover.hidden = false;

    requestAnimationFrame(() => {
      const anchorRect = anchor.getBoundingClientRect();
      const popoverRect = popover.getBoundingClientRect();
      const margin = 8;

      let left =
        anchorRect.left + anchorRect.width / 2 - popoverRect.width / 2;
      left = Math.max(
        margin,
        Math.min(innerWidth - popoverRect.width - margin, left)
      );

      let top = anchorRect.bottom + 8;
      if (top + popoverRect.height > innerHeight - margin) {
        top = Math.max(margin, anchorRect.top - popoverRect.height - 8);
      }

      popover.style.left = `${left}px`;
      popover.style.top = `${top}px`;
    });
  }

  function closeToolPopovers() {
    presetPopover.hidden = true;
    colorPopover.hidden = true;
    eraserOptionsPopover.hidden = true;
    editingPreset = null;
    editingColorId = null;
  }

  function setActualTool(tool) {
    if (state.tool === "text" && tool !== "text" && state.textEdit) commitTextEdit();
    if (state.tool !== tool) {
      state.tool = tool;
      debugLog(`TOOL ${toolLabel(tool)}`);
    }

    canvas.style.cursor = tool === "eraser" ? "none" : tool === "text" ? "text" : tool === "shape" ? "crosshair" : "crosshair";
    document.body.classList.toggle("selection-active", tool === "selector");
    document.body.classList.toggle("geometry-editing", tool === "shape" || tool === "selector");
    document.body.classList.toggle("text-tool-active", tool === "text");
    if (tool !== "eraser") eraserCursorEl.classList.remove("visible");
    if (tool !== "selector") {
      state.temporarySelectionReturnMode = null;
      state.pendingFingerInteraction = null;
    }
    if (tool !== "selector" && tool !== "shape") clearSelection(false);
  }

  function applyToolbarSelection() {
    if (state.toolbarMode === "select") {
      setActualTool("selector");
    } else if (state.toolbarMode === "shape") {
      const preset = currentDrawPreset();
      const colour = currentColor();
      widthEl.value = String(preset.width);
      widthValueEl.value = Number(preset.width).toFixed(2);
      colorEl.value = colour.value;
      state.lineStyle = preset.style;
      setActualTool("shape");
    } else if (state.toolbarMode === "text") {
      textFontSizeEl.value = String(state.textFontSize);
      textFontSizeValueEl.value = String(Math.round(state.textFontSize));
      textColorEl.value = state.textColor;
      for (const button of textAlignSelector.querySelectorAll("[data-text-align]")) {
        button.classList.toggle("active", button.dataset.textAlign === state.textAlign);
      }
      setActualTool("text");
    } else if (state.toolbarMode === "eraser") {
      const preset =
        state.eraserPresets[state.eraserPresetIndex]
        || state.eraserPresets[0];

      state.eraserSize = preset.size;
      eraserSizeEl.value = String(preset.size);
      eraserSizeValueEl.value = String(preset.size);
      eraserCursorEl.style.width = `${preset.size}px`;
      eraserCursorEl.style.height = `${preset.size}px`;
      setActualTool("eraser");
    } else {
      const preset = currentDrawPreset();
      const colour = currentColor();

      widthEl.value = String(preset.width);
      widthValueEl.value = Number(preset.width).toFixed(2);
      colorEl.value = colour.value;
      state.lineStyle = preset.style;

      const actualTool =
        state.drawTool === "highlighter"
          ? "highlighter"
          : preset.pressure === false
            ? "fixed-pen"
            : "pen";

      setActualTool(actualTool);
    }

    persistToolbarSettings();
    syncToolbarUI();
  }

  function renderDrawPresets() {
    drawPresetStrip.replaceChildren();
    const presets = presetArrayFor(state.drawTool);
    const selected = currentDrawPresetIndex();

    presets.forEach((preset, index) => {
      const button = document.createElement("button");
      button.className = "preset-button";
      button.dataset.presetIndex = String(index);
      button.classList.toggle("active", index === selected);
      button.title = `Preset ${index + 1}: ${preset.width}px, ${preset.style}`;

      const previewWidth = Math.max(
        1.25,
        Math.min(8, Number(preset.width) * 0.38)
      );

      button.innerHTML = `
        <span class="preset-line ${preset.style}"
              style="--preview-width:${previewWidth}px"></span>
        <small>${Number(preset.width).toFixed(
          Number(preset.width) % 1 ? 1 : 0
        )}</small>
      `;

      button.addEventListener("click", () => {
        setCurrentDrawPresetIndex(index);
        applyToolbarSelection();

        requestAnimationFrame(() => {
          const updated = drawPresetStrip.querySelector(
            `[data-preset-index="${index}"]`
          );
          openPresetEditor("draw", index, updated);
        });
      });

      drawPresetStrip.append(button);
    });
  }

  function renderEraserPresets() {
    eraserPresetStrip.replaceChildren();

    state.eraserPresets.forEach((preset, index) => {
      const button = document.createElement("button");
      button.className = "preset-button";
      button.dataset.eraserPresetIndex = String(index);
      button.classList.toggle(
        "active",
        index === state.eraserPresetIndex
      );
      button.title = `Eraser preset ${index + 1}: ${preset.size}px`;

      const previewSize = Math.max(
        10,
        Math.min(27, preset.size * 0.48)
      );

      button.innerHTML = `
        <span class="eraser-size-preview"
              style="--eraser-preview:${previewSize}px"></span>
        <small>${Math.round(preset.size)}</small>
      `;

      button.addEventListener("click", () => {
        state.eraserPresetIndex = index;
        applyToolbarSelection();

        requestAnimationFrame(() => {
          const updated = eraserPresetStrip.querySelector(
            `[data-eraser-preset-index="${index}"]`
          );
          openPresetEditor("eraser", index, updated);
        });
      });

      eraserPresetStrip.append(button);
    });
  }

  function beginColorPress(event, id, button) {
    if (event.pointerType === "pen") return;

    clearTimeout(colorPress?.timer);

    colorPress = {
      id,
      button,
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      timer: setTimeout(() => {
        colorDrag = {
          id,
          pointerId: event.pointerId,
        };
        suppressColorClickUntil = performance.now() + 650;
        button.classList.add("dragging");
        navigator.vibrate?.(10);
      }, 380),
    };
  }

  function cancelPendingColorPress() {
    if (colorPress?.timer) clearTimeout(colorPress.timer);
    colorPress = null;
  }

  function renderColors() {
    colorStrip.replaceChildren();

    for (const colour of state.colors) {
      const button = document.createElement("button");
      button.className = "color-chip";
      button.dataset.colorId = colour.id;
      button.style.setProperty("--saved-color", colour.value);
      button.classList.toggle(
        "active",
        colour.id === state.activeColorId
      );
      button.title =
        colour.id === state.activeColorId
          ? "Tap again to edit; hold and drag to reorder"
          : "Select colour; hold and drag to reorder";

      button.addEventListener("pointerdown", event => {
        beginColorPress(event, colour.id, button);
      });

      button.addEventListener("click", () => {
        if (performance.now() < suppressColorClickUntil) return;

        if (state.activeColorId === colour.id) {
          openColorEditor(colour.id, button);
          return;
        }

        state.activeColorId = colour.id;
        applyToolbarSelection();
      });

      colorStrip.append(button);
    }
  }

  function syncToolbarUI() {
    const drawing = state.toolbarMode === "draw";
    const erasing = state.toolbarMode === "eraser";
    const selecting = state.toolbarMode === "select";
    const texting = state.toolbarMode === "text";
    const shaping = state.toolbarMode === "shape";

    drawModeButton.classList.toggle("active", drawing);
    eraserModeButton.classList.toggle("active", erasing);
    textModeButton?.classList.toggle("active", texting);
    shapeModeButton?.classList.toggle("active", shaping);
    selectorModeButton?.classList.toggle("active", selecting);
    drawContextRow.hidden = !drawing;
    eraserContextRow.hidden = !erasing;
    if (textContextRow) textContextRow.hidden = !texting;
    if (shapeContextRow) shapeContextRow.hidden = !shaping;
    if (selectionContextRow) selectionContextRow.hidden = !selecting;
    document.querySelectorAll("[data-shape-type]").forEach(button => button.classList.toggle("active", button.dataset.shapeType === state.shapeType));

    document.querySelectorAll("[data-draw-tool]").forEach(button => {
      button.classList.toggle(
        "active",
        button.dataset.drawTool === state.drawTool
      );
    });

    eraserHighlighterOnlyToggle.checked =
      state.eraserHighlighterOnly;

    renderDrawPresets();
    renderEraserPresets();
    renderColors();
    updateSelectionUI();
  }

  function openPresetEditor(kind, index, anchor) {
    if (!anchor) return;

    editingPreset = {
      kind,
      index,
      tool: state.drawTool,
    };

    if (kind === "eraser") {
      const preset = state.eraserPresets[index];
      presetPopoverTitle.textContent = `Eraser preset ${index + 1}`;
      presetPopoverSubtitle.textContent =
        "Customize the eraser diameter.";
      presetWidthLabel.textContent = "Diameter";
      presetWidthInput.min = "8";
      presetWidthInput.max = "120";
      presetWidthInput.step = "1";
      presetWidthInput.value = String(preset.size);
      presetWidthOutput.value = String(Math.round(preset.size));
      lineStyleEditor.hidden = true;
      pressurePresetField.hidden = true;
    } else {
      const presets = presetArrayFor(editingPreset.tool);
      const preset = presets[index];

      presetPopoverTitle.textContent =
        `${editingPreset.tool === "highlighter"
          ? "Highlighter"
          : "Pen"} preset ${index + 1}`;

      presetPopoverSubtitle.textContent =
        "Customize thickness and line style.";

      presetWidthLabel.textContent = "Thickness";
      presetWidthInput.min = "0.5";
      presetWidthInput.max =
        editingPreset.tool === "highlighter" ? "60" : "30";
      presetWidthInput.step = "0.25";
      presetWidthInput.value = String(preset.width);
      presetWidthOutput.value = Number(preset.width).toFixed(2);
      lineStyleEditor.hidden = false;
      pressurePresetField.hidden =
        editingPreset.tool !== "pen";
      presetPressureToggle.checked = preset.pressure !== false;

      document.querySelectorAll("[data-line-style]").forEach(button => {
        button.classList.toggle(
          "active",
          button.dataset.lineStyle === preset.style
        );
      });
    }

    positionPopover(presetPopover, anchor);
  }

  function updateEditingPreset() {
    if (!editingPreset) return;

    if (editingPreset.kind === "eraser") {
      const preset = state.eraserPresets[editingPreset.index];
      preset.size = clampNumber(
        presetWidthInput.value,
        8,
        120,
        preset.size
      );
      presetWidthOutput.value = String(Math.round(preset.size));
    } else {
      const presets = presetArrayFor(editingPreset.tool);
      const preset = presets[editingPreset.index];
      preset.width = clampNumber(
        presetWidthInput.value,
        0.5,
        editingPreset.tool === "highlighter" ? 60 : 30,
        preset.width
      );
      presetWidthOutput.value = Number(preset.width).toFixed(2);
    }

    applyToolbarSelection();
  }

  function openColorEditor(id, anchor) {
    const colour = state.colors.find(item => item.id === id);
    if (!colour) return;

    editingColorId = id;
    savedColorEditor.value = colour.value;
    deleteColorButton.disabled = state.colors.length <= 1;
    positionPopover(colorPopover, anchor);
  }

  function initializeToolbarV10() {
    state.penPresets = normalizeDrawPresets(
      state.penPresets,
      DEFAULT_PEN_PRESETS,
      true
    );

    state.highlighterPresets = normalizeDrawPresets(
      state.highlighterPresets,
      DEFAULT_HIGHLIGHTER_PRESETS,
      false
    );

    state.eraserPresets = normalizeEraserPresets(
      state.eraserPresets
    );

    state.colors = normalizeColors(state.colors);

    if (!state.colors.some(item => item.id === state.activeColorId)) {
      state.activeColorId = state.colors[0].id;
    }

    if (!["pen", "highlighter"].includes(state.drawTool)) {
      state.drawTool = "pen";
    }

    if (!["draw", "eraser", "select", "text", "shape"].includes(state.toolbarMode)) {
      state.toolbarMode = "draw";
    }

    drawModeButton.addEventListener("click", () => {
      closeToolPopovers();
      state.toolbarMode = "draw";
      applyToolbarSelection();
    });

    eraserModeButton.addEventListener("click", () => {
      closeToolPopovers();
      state.toolbarMode = "eraser";
      applyToolbarSelection();
    });

    textModeButton?.addEventListener("click", () => {
      closeToolPopovers();
      state.toolbarMode = "text";
      applyToolbarSelection();
    });

    shapeModeButton?.addEventListener("click", () => {
      closeToolPopovers();
      state.toolbarMode = "shape";
      applyToolbarSelection();
    });

    planeModeButton?.addEventListener("click", () => {
      closeToolPopovers();
      insertXYPlane();
    });

    selectorModeButton?.addEventListener("click", () => {
      closeToolPopovers();
      state.toolbarMode = "select";
      applyToolbarSelection();
    });

    document.querySelectorAll("[data-shape-type]").forEach(button => {
      button.addEventListener("click", () => {
        state.shapeType = button.dataset.shapeType;
        state.toolbarMode = "shape";
        applyToolbarSelection();
      });
    });


    document.querySelectorAll("[data-draw-tool]").forEach(button => {
      button.addEventListener("click", () => {
        closeToolPopovers();
        state.toolbarMode = "draw";
        state.drawTool = button.dataset.drawTool;
        applyToolbarSelection();
      });
    });

    presetWidthInput.addEventListener("input", updateEditingPreset);

    document.querySelectorAll("[data-line-style]").forEach(button => {
      button.addEventListener("click", () => {
        if (!editingPreset || editingPreset.kind !== "draw") return;

        const presets = presetArrayFor(editingPreset.tool);
        const preset = presets[editingPreset.index];
        preset.style = button.dataset.lineStyle;

        document.querySelectorAll("[data-line-style]").forEach(
          candidate => {
            candidate.classList.toggle(
              "active",
              candidate === button
            );
          }
        );

        applyToolbarSelection();
      });
    });

    presetPressureToggle.addEventListener("change", () => {
      if (
        !editingPreset
        || editingPreset.kind !== "draw"
        || editingPreset.tool !== "pen"
      ) return;

      state.penPresets[editingPreset.index].pressure =
        presetPressureToggle.checked;

      applyToolbarSelection();
    });

    closePresetPopover.addEventListener(
      "click",
      () => { presetPopover.hidden = true; }
    );

    addColorButton.addEventListener("click", () => {
      closeToolPopovers();

      const colour = {
        id: crypto.randomUUID
          ? crypto.randomUUID()
          : `${Date.now()}-${Math.random()}`,
        value: "#377cf6",
      };

      state.colors.push(colour);
      state.activeColorId = colour.id;
      applyToolbarSelection();

      requestAnimationFrame(() => {
        const anchor = colorStrip.querySelector(
          `[data-color-id="${colour.id}"]`
        );
        openColorEditor(colour.id, anchor);
      });
    });

    savedColorEditor.addEventListener("input", () => {
      const colour = state.colors.find(
        item => item.id === editingColorId
      );
      if (!colour) return;

      colour.value = savedColorEditor.value.toLowerCase();
      state.activeColorId = colour.id;
      applyToolbarSelection();
    });

    deleteColorButton.addEventListener("click", () => {
      if (state.colors.length <= 1 || !editingColorId) return;

      state.colors = state.colors.filter(
        item => item.id !== editingColorId
      );

      if (state.activeColorId === editingColorId) {
        state.activeColorId = state.colors[0].id;
      }

      colorPopover.hidden = true;
      editingColorId = null;
      applyToolbarSelection();
    });

    doneColorButton.addEventListener(
      "click",
      () => { colorPopover.hidden = true; }
    );

    closeColorPopover.addEventListener(
      "click",
      () => { colorPopover.hidden = true; }
    );

    eraserOptionsButton.addEventListener("click", () => {
      eraserHighlighterOnlyToggle.checked =
        state.eraserHighlighterOnly;
      positionPopover(eraserOptionsPopover, eraserOptionsButton);
    });

    eraserHighlighterOnlyToggle.addEventListener("change", () => {
      state.eraserHighlighterOnly =
        eraserHighlighterOnlyToggle.checked;
      persistToolbarSettings();
      showToast(
        state.eraserHighlighterOnly
          ? "Eraser: highlighter strokes only"
          : "Eraser: all stroke types"
      );
    });

    closeEraserOptions.addEventListener(
      "click",
      () => { eraserOptionsPopover.hidden = true; }
    );

    window.addEventListener("pointermove", event => {
      if (colorPress && !colorDrag) {
        const distance = Math.hypot(
          event.clientX - colorPress.startX,
          event.clientY - colorPress.startY
        );

        if (distance > 10) cancelPendingColorPress();
      }

      if (!colorDrag || event.pointerId !== colorDrag.pointerId) {
        return;
      }

      const target = document
        .elementFromPoint(event.clientX, event.clientY)
        ?.closest?.(".color-chip");

      const targetId = target?.dataset.colorId;
      if (!targetId || targetId === colorDrag.id) return;

      const from = state.colors.findIndex(
        item => item.id === colorDrag.id
      );
      const to = state.colors.findIndex(
        item => item.id === targetId
      );

      if (from < 0 || to < 0) return;

      const [moved] = state.colors.splice(from, 1);
      state.colors.splice(to, 0, moved);
      storeJson("infiniteNotes.colors", state.colors);
      renderColors();
    }, { passive: true });

    window.addEventListener("pointerup", event => {
      if (colorDrag && event.pointerId === colorDrag.pointerId) {
        suppressColorClickUntil = performance.now() + 500;
        colorDrag = null;
        persistToolbarSettings();
        renderColors();
      }
      cancelPendingColorPress();
    }, { passive: true });

    window.addEventListener("pointercancel", () => {
      colorDrag = null;
      cancelPendingColorPress();
      renderColors();
    }, { passive: true });

    window.addEventListener("resize", closeToolPopovers);

    document.addEventListener("pointerdown", event => {
      if (
        event.target.closest?.(".tool-popover")
        || event.target.closest?.(".preset-button")
        || event.target.closest?.(".color-chip")
        || event.target.closest?.("#addColorButton")
        || event.target.closest?.("#eraserOptionsButton")
      ) {
        return;
      }

      closeToolPopovers();
    }, { capture: true });

    applyToolbarSelection();
  }

  function setTool(tool) {
    if (tool === "selector") {
      state.toolbarMode = "select";
    } else if (tool === "text") {
      state.toolbarMode = "text";
    } else if (tool === "eraser") {
      state.toolbarMode = "eraser";
    } else {
      state.toolbarMode = "draw";
      state.drawTool = tool === "highlighter" ? "highlighter" : "pen";

      if (tool === "fixed-pen") {
        const preset = state.penPresets[state.penPresetIndex];
        if (preset) preset.pressure = false;
      } else if (tool === "pen") {
        const preset = state.penPresets[state.penPresetIndex];
        if (preset) preset.pressure = true;
      }
    }

    applyToolbarSelection();
  }

  textEditorInput?.addEventListener("input", () => {
    const stroke = state.textEdit ? state.strokes.get(state.textEdit.id) : null;
    if (!stroke) return;
    stroke.text = String(textEditorInput.value || "").slice(0, 20000);
    markAllDirty();
  });
  textEditorInput?.addEventListener("keydown", event => {
    if (event.key === "Escape") {
      event.preventDefault();
      cancelTextEdit();
    } else if ((event.ctrlKey || event.metaKey) && event.key === "Enter") {
      event.preventDefault();
      commitTextEdit();
    }
  });
  textEditorDone?.addEventListener("click", commitTextEdit);
  textEditorCancel?.addEventListener("click", cancelTextEdit);
  textFontSizeEl?.addEventListener("input", () => {
    state.textFontSize = Math.max(8, Math.min(100, Number(textFontSizeEl.value) || 24));
    textFontSizeValueEl.value = String(Math.round(state.textFontSize));
    const stroke = state.textEdit ? state.strokes.get(state.textEdit.id) : null;
    if (stroke) stroke.width = state.textFontSize;
    persistToolbarSettings();
    positionTextEditor();
    markAllDirty();
  });
  textColorEl?.addEventListener("input", () => {
    state.textColor = textColorEl.value;
    const stroke = state.textEdit ? state.strokes.get(state.textEdit.id) : null;
    if (stroke) stroke.color = state.textColor;
    persistToolbarSettings();
    positionTextEditor();
    markAllDirty();
  });
  textAlignSelector?.addEventListener("click", event => {
    const button = event.target.closest?.("[data-text-align]");
    if (!button) return;
    state.textAlign = button.dataset.textAlign;
    for (const candidate of textAlignSelector.querySelectorAll("[data-text-align]")) {
      candidate.classList.toggle("active", candidate === button);
    }
    const stroke = state.textEdit ? state.strokes.get(state.textEdit.id) : null;
    if (stroke) stroke.textAlign = state.textAlign;
    persistToolbarSettings();
    positionTextEditor();
    markAllDirty();
  });

  function bindGeometryRange(input, output, stateKey, suffix = "") {
    if (!input || !output) return;
    input.value = String(state[stateKey]);
    output.value = `${state[stateKey]}${suffix}`;
    input.addEventListener("input", () => {
      state[stateKey] = Number(input.value);
      output.value = `${state[stateKey]}${suffix}`;
      persistToolbarSettings(); updateDebugPanel(true);
    });
  }
  bindGeometryRange(recognitionHoldMsEl, recognitionHoldMsValueEl, "recognitionHoldMs", " ms");
  bindGeometryRange(lineRecognitionToleranceEl, lineRecognitionToleranceValueEl, "lineRecognitionTolerance", "%");
  bindGeometryRange(curveRecognitionToleranceEl, curveRecognitionToleranceValueEl, "curveRecognitionTolerance", "%");
  bindGeometryRange(geometrySnapDistanceEl, geometrySnapDistanceValueEl, "geometrySnapDistance", " px");
  [[endpointSnapToggle,"endpointSnap"],[axisSnapToggle,"axisSnap"],[tangentSnapToggle,"tangentSnap"],[normalSnapToggle,"normalSnap"]].forEach(([toggle,key]) => {
    if (!toggle) return; toggle.checked=state[key]; toggle.addEventListener("change",()=>{state[key]=toggle.checked;persistToolbarSettings();});
  });

  undoButton.addEventListener("click", () => send({ type: "undo" }));
  redoButton.addEventListener("click", () => send({ type: "redo" }));
  selectionCopyButton?.addEventListener("click", copySelectedItems);
  selectionPasteButton?.addEventListener("click", pasteSelectedItems);
  selectionDeleteButton?.addEventListener("click", deleteSelectedItems);
  selectionPlaneLockButton?.addEventListener("click", toggleSelectedGeometryLock);
  document.addEventListener("keydown", event => {
    const target = event.target;
    if (target?.matches?.("input, textarea, select") || target?.isContentEditable) return;
    const command = event.ctrlKey || event.metaKey;
    if (command && event.key.toLowerCase() === "c" && state.selectionIds.size) {
      event.preventDefault();
      copySelectedItems();
    } else if (command && event.key.toLowerCase() === "v" && state.selectionClipboard.length) {
      event.preventDefault();
      pasteSelectedItems();
    } else if ((event.key === "Delete" || event.key === "Backspace") && state.selectionIds.size) {
      event.preventDefault();
      deleteSelectedItems();
    } else if (event.key === "Escape" && state.selectionIds.size) {
      event.preventDefault();
      clearSelection();
    }
  });
  connectionButton?.addEventListener("click", () => requestSync(true));
  settingsButton?.addEventListener("click", () => setSettingsOpen(!document.body.classList.contains("settings-open")));
  closeSettingsButton?.addEventListener("click", () => setSettingsOpen(false));
  settingsScrim?.addEventListener("click", () => setSettingsOpen(false));
  debugToggle?.addEventListener("change", () => {
    setDebugOpen(debugToggle.checked);
    if (debugToggle.checked) setSettingsOpen(false);
  });
  closeDebugButton?.addEventListener("click", () => setDebugOpen(false));
  syncNowButton?.addEventListener("click", () => requestSync(true));
  if (autoSyncIntervalEl) {
    const allowedIntervals = new Set([0, 10, 30, 60, 300]);
    if (!allowedIntervals.has(state.autoSyncSeconds)) state.autoSyncSeconds = 0;
    autoSyncIntervalEl.value = String(state.autoSyncSeconds);
    autoSyncIntervalEl.addEventListener("change", () => {
      const requested = Number(autoSyncIntervalEl.value);
      state.autoSyncSeconds = allowedIntervals.has(requested) ? requested : 0;
      storeSetting("infiniteNotes.autoSyncSeconds", state.autoSyncSeconds);
      scheduleAutoSync();
      showToast(state.autoSyncSeconds
        ? `Automatic refresh set to ${state.autoSyncSeconds < 60 ? `${state.autoSyncSeconds} seconds` : `${state.autoSyncSeconds / 60} minute${state.autoSyncSeconds === 60 ? "" : "s"}`}`
        : "Automatic refresh disabled");
    });
  }
  updateSyncUI();
  scheduleAutoSync();

  widthEl.addEventListener("input", () => {
    widthValueEl.value = Number(widthEl.value).toFixed(1);
  });

  smoothingEl.value = String(state.smoothing);
  smoothingValueEl.value = String(state.smoothing);
  smoothingEl.addEventListener("input", () => {
    state.smoothing = Number(smoothingEl.value);
    smoothingValueEl.value = String(state.smoothing);
    storeSetting("infiniteNotes.smoothing", state.smoothing);
  });

  strokeDetailEl.value = String(state.strokeDetail);
  strokeDetailValueEl.value = String(state.strokeDetail);
  strokeDetailEl.addEventListener("input", () => {
    state.strokeDetail = Number(strokeDetailEl.value);
    strokeDetailValueEl.value = String(state.strokeDetail);
    storeSetting("infiniteNotes.strokeDetail", state.strokeDetail);
    markAllDirty();
    updateDebugPanel(true);
  });

  eraserSizeEl.value = String(state.eraserSize);
  eraserSizeValueEl.value = String(state.eraserSize);
  eraserSizeEl.addEventListener("input", () => {
    state.eraserSize = Number(eraserSizeEl.value);
    eraserSizeValueEl.value = String(state.eraserSize);
    eraserCursorEl.style.width = `${state.eraserSize}px`;
    eraserCursorEl.style.height = `${state.eraserSize}px`;
    storeSetting("infiniteNotes.eraserSize", state.eraserSize);
  });

  document.querySelectorAll("[data-pan-fingers]").forEach(button => {
    const count = Number(button.dataset.panFingers);
    button.classList.toggle("active", count === state.panFingers);
    button.addEventListener("click", () => {
      state.panFingers = count;
      storeSetting("infiniteNotes.panFingers", count);
      document.querySelectorAll("[data-pan-fingers]").forEach(candidate => {
        candidate.classList.toggle("active", Number(candidate.dataset.panFingers) === count);
      });
      state.touches.clear();
      state.gesture = null;
    });
  });

  document.getElementById("fitButton")?.addEventListener("click", fitPages);
  document.getElementById("hideHelp")?.addEventListener("click", () => document.getElementById("help").remove());

  const standaloneMode = window.matchMedia?.("(display-mode: standalone)")?.matches || navigator.standalone === true;
  document.body.classList.toggle("standalone", standaloneMode);
  document.getElementById("fullscreenButton")?.addEventListener("click", async () => {
    if (standaloneMode) {
      showToast("Already running in app mode");
      return;
    }
    if (document.fullscreenEnabled && document.documentElement.requestFullscreen) {
      try {
        await document.documentElement.requestFullscreen({ navigationUI: "hide" });
        return;
      } catch {}
    }
    showToast("Safari: Share → Add to Home Screen, then open Infinite Notes from the icon", 6500);
  });

  document.getElementById("clearButton")?.addEventListener("click", () => {
    if (!confirm("Clear all ink from this document?")) return;
    state.strokes.clear();
    state.liveStrokeIds.clear();
    send({ type: "clear_strokes" });
    markIpadStateDirty();
    markAllDirty();
  });

  document.getElementById("pdfInput")?.addEventListener("change", async event => {
    const file = event.target.files?.[0];
    if (!file) return;
    const formData = new FormData();
    formData.append("file", file);
    showToast("Rendering PDF…", 10000);
    try {
      const response = await fetch("/api/pdf", { method: "POST", body: formData });
      const data = await response.json();
      if (!response.ok) throw new Error(data.detail || "Upload failed");
      setDocument(data.document);
      state.strokes.clear();
      state.liveStrokeIds.clear();
      markIpadStateDirty();
      fitPages();
      showToast("PDF ready");
    } catch (error) {
      showToast(error.message, 5000);
    } finally {
      event.target.value = "";
    }
  });


  addPageButton?.addEventListener("click", async () => {
    if (!state.document.pages?.length) {
      showToast("Open a PDF first");
      return;
    }
    addPageButton.disabled = true;
    showToast("Adding matching page…", 12000);
    try {
      const response = await fetch("/api/pages/append", { method: "POST" });
      const data = await response.json();
      if (!response.ok) throw new Error(data.detail || "Could not add page");
      setDocument(data.document);
      markIpadStateDirty();
      fitPageNumber(data.pageNumber);
      showToast(`Blank page ${data.pageNumber} added`);
    } catch (error) {
      showToast(error.message || "Could not add page", 6000);
    } finally {
      addPageButton.disabled = !(state.document.pages?.length);
    }
  });

  pdfExportButton?.addEventListener("click", async () => {
    if (!state.document.pages?.length) {
      showToast("Open a PDF first");
      return;
    }
    pdfExportButton.disabled = true;
    showToast("Checking page bounds…", 10000);
    try {
      const infoResponse = await fetch("/api/pdf/export-info");
      const info = await infoResponse.json();
      if (!infoResponse.ok) throw new Error(info.detail || "Could not inspect the PDF export");
      if (info.hasOverflow) {
        const affected = info.pages
          .filter(page => page.overflow)
          .map(page => `Page ${page.pageNumber}: ${page.newWidth.toFixed(1)} × ${page.newHeight.toFixed(1)} pt (${page.newWidthInches.toFixed(2)} × ${page.newHeightInches.toFixed(2)} in)`)
          .join("\n");
        const proceed = confirm(
          `Some ink crosses the original page boundary.\n\nThe affected exported page size will expand to:\n${affected}\n\nContinue with the PDF export?`
        );
        if (!proceed) return;
      }

      showToast("Flattening PDF and ink…", 20000);
      const response = await fetch("/api/pdf/export");
      if (!response.ok) {
        let message = "PDF export failed";
        try { message = (await response.json()).detail || message; } catch {}
        throw new Error(message);
      }
      const blob = await response.blob();
      const disposition = response.headers.get("content-disposition") || "";
      const filenameMatch = disposition.match(/filename\*=UTF-8''([^;]+)|filename="?([^";]+)"?/i);
      const fallbackStem = (state.document.filename || "infinite-notes").replace(/\.pdf$/i, "");
      const filename = decodeURIComponent(filenameMatch?.[1] || filenameMatch?.[2] || `${fallbackStem}-notes.pdf`);
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = filename;
      document.body.append(anchor);
      anchor.click();
      anchor.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      showToast("Notes PDF exported");
    } catch (error) {
      showToast(error.message || "PDF export failed", 6000);
    } finally {
      pdfExportButton.disabled = !(state.document.pages?.length);
    }
  });

  projectExportButton?.addEventListener("click", async () => {
    projectExportButton.disabled = true;
    showToast("Preparing project file…", 10000);
    try {
      const response = await fetch("/api/project/export");
      if (!response.ok) {
        let message = "Export failed";
        try {
          const data = await response.json();
          message = data.detail || message;
        } catch {}
        throw new Error(message);
      }

      const blob = await response.blob();
      const disposition = response.headers.get("content-disposition") || "";
      const filenameMatch = disposition.match(/filename\*=UTF-8''([^;]+)|filename="?([^";]+)"?/i);
      const fallbackStem = (state.document.filename || "infinite-notes").replace(/\.pdf$/i, "");
      const filename = decodeURIComponent(filenameMatch?.[1] || filenameMatch?.[2] || `${fallbackStem}.inotes`);
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = filename;
      document.body.append(anchor);
      anchor.click();
      anchor.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      showToast("Project exported");
    } catch (error) {
      showToast(error.message || "Export failed", 5000);
    } finally {
      projectExportButton.disabled = false;
    }
  });

  projectImportInput?.addEventListener("change", async event => {
    const file = event.target.files?.[0];
    if (!file) return;
    if (!confirm("Import this project? It will replace the currently open PDF and all ink.")) {
      event.target.value = "";
      return;
    }

    const formData = new FormData();
    formData.append("file", file);
    showToast("Importing project…", 15000);
    try {
      const response = await fetch("/api/project/import", { method: "POST", body: formData });
      const data = await response.json();
      if (!response.ok) throw new Error(data.detail || "Import failed");
      const stateResponse = await fetch(`/api/state?import=${Date.now()}`, { cache: "no-store" });
      if (!stateResponse.ok) throw new Error("Project imported, but the restored notebook could not be downloaded");
      const restoredState = await stateResponse.json();
      handleServerMessage({ type: "snapshot", state: restoredState, reason: "project_import" });
      fitPages();
      showToast("Project imported");
    } catch (error) {
      showToast(error.message || "Import failed", 6000);
    } finally {
      event.target.value = "";
    }
  });

  window.addEventListener("resize", markAllDirty);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") {
      persistIpadView();
      flushIpadCache(true);
    }
  });
  window.addEventListener("pagehide", () => {
    persistIpadView();
    flushIpadCache(true);
  });
  window.addEventListener("blur", () => {
    if (state.selectionGesture) finishSelectionPointer(null, true);
    if (state.shapeGesture) finishShapePointer(null, true);
    finishActiveStroke(null, false);
    if (state.activeInputSource && state.tool === "eraser") finishEraserInput();
    else finishEraserGesture();
    eraserCursorEl.classList.remove("visible");
    state.mousePanning = false;
    state.lastMouse = null;
    state.touches.clear();
    state.stylusTouches.clear();
    state.gesture = null;
  });

  widthValueEl.value = Number(widthEl.value).toFixed(1);
  eraserCursorEl.style.width = `${state.eraserSize}px`;
  eraserCursorEl.style.height = `${state.eraserSize}px`;
  updateHistoryButtons();
  updateSelectionUI();
  updateInputDiagnostics();
  initializeToolbarV10();
  setDebugOpen(state.debugEnabled);
  function startApplication() {
    connect();
    resizeCanvas();
    requestAnimationFrame(render);
  }
  startApplication();
})();
