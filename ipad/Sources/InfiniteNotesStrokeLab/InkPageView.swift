import UIKit

@MainActor
private final class PencilInputGestureRecognizer: UIGestureRecognizer {
    var onBegan: ((Set<UITouch>, UIEvent?) -> Void)?
    var onMoved: ((Set<UITouch>, UIEvent?) -> Void)?
    var onEnded: ((Set<UITouch>, UIEvent?) -> Void)?
    var onCancelled: ((Set<UITouch>, UIEvent?) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let pencilTouches = Set(touches.filter { $0.type == .pencil })
        guard !pencilTouches.isEmpty else {
            state = .failed
            return
        }
        onBegan?(pencilTouches, event)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        let pencilTouches = Set(touches.filter { $0.type == .pencil })
        guard !pencilTouches.isEmpty else { return }
        onMoved?(pencilTouches, event)
        if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        let pencilTouches = Set(touches.filter { $0.type == .pencil })
        guard !pencilTouches.isEmpty else { return }
        onEnded?(pencilTouches, event)
        if state == .began || state == .changed {
            state = .ended
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        let pencilTouches = Set(touches.filter { $0.type == .pencil })
        guard !pencilTouches.isEmpty else { return }
        onCancelled?(pencilTouches, event)
        state = .cancelled
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

@MainActor
final class InkPageView: UIView, UIGestureRecognizerDelegate {
    private struct ShapeGesture {
        var startWorld: CGPoint
        var preview: NoteStroke
        var changed: Bool
    }

    let pageIndex: Int
    private weak var model: AppModel?
    private var activeTouch: UITouch?
    private var activeStrokeID: String?
    private var contactTool: NoteTool?
    private var pipelineState = StrokePipelineState()
    private var predictedPoints: [NotePoint] = []
    private var eraseOperationID: String?
    private var erasedIDs: Set<String> = []
    private var eraserCursorWorld: CGPoint?
    private var shapeGesture: ShapeGesture?
    private var selectionGesture: SelectionTransformGesture?
    private var recognitionWorkItem: DispatchWorkItem?

    private var committedImage: UIImage?
    private var committedImageSize: CGSize = .zero
    private var committedContentDirty = true
    private var committedRenderScale: CGFloat = UIScreen.main.scale
    private var committedRebuildScheduled = false
    private var pendingPDFScale: CGFloat = 1
    private var committedExclusions: Set<String> = []
    private var pendingCommitOverlayIDs: Set<String> = []

    // Pencil ink, geometry previews, selection handles and lasso paths all use
    // reusable vector-backed CAShapeLayers. Only completed content is flattened
    // into the per-page committed cache.
    private let liveLayerHost = CALayer()
    private var liveShapeLayers: [CAShapeLayer] = []
    private var liveDisplayScale: CGFloat = UIScreen.main.scale
    private var liveRefreshScheduled = false

    private var interactionZoomScale: CGFloat {
        max(0.05, pendingPDFScale)
    }

    private weak var interactionHost: UIView?

    private lazy var pencilInputRecognizer: PencilInputGestureRecognizer = {
        let gesture = PencilInputGestureRecognizer(target: nil, action: nil)
        gesture.onBegan = { [weak self] touches, event in
            self?.touchesBegan(touches, with: event)
        }
        gesture.onMoved = { [weak self] touches, event in
            self?.touchesMoved(touches, with: event)
        }
        gesture.onEnded = { [weak self] touches, event in
            self?.touchesEnded(touches, with: event)
        }
        gesture.onCancelled = { [weak self] touches, event in
            self?.touchesCancelled(touches, with: event)
        }
        return gesture
    }()

    private lazy var fingerGeometryPan: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleFingerGeometryPan(_:)))
        gesture.minimumNumberOfTouches = 1
        gesture.maximumNumberOfTouches = 1
        gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        gesture.cancelsTouchesInView = true
        gesture.delegate = self
        return gesture
    }()

    private lazy var fingerGeometryTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleFingerGeometryTap(_:)))
        gesture.numberOfTouchesRequired = 1
        gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        return gesture
    }()

    init(pageIndex: Int, model: AppModel) {
        self.pageIndex = pageIndex
        self.model = model
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        // This full-page view is rendering-only. If it participates in
        // hit-testing, finger touches land here instead of in the PDF scroll
        // view. Pencil and geometry recognizers are installed on the page
        // container in didMoveToSuperview().
        isUserInteractionEnabled = false
        isMultipleTouchEnabled = true
        contentMode = .redraw
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        liveLayerHost.masksToBounds = true
        layer.addSublayer(liveLayerHost)
        fingerGeometryTap.require(toFail: fingerGeometryPan)
        model.register(pageView: self, pageIndex: pageIndex)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        installInteractionRecognizers(on: superview)
    }

    private func installInteractionRecognizers(on host: UIView?) {
        guard interactionHost !== host else { return }

        if let oldHost = interactionHost {
            oldHost.removeGestureRecognizer(pencilInputRecognizer)
            oldHost.removeGestureRecognizer(fingerGeometryPan)
            oldHost.removeGestureRecognizer(fingerGeometryTap)
        }

        interactionHost = host

        if let host {
            host.addGestureRecognizer(pencilInputRecognizer)
            host.addGestureRecognizer(fingerGeometryPan)
            host.addGestureRecognizer(fingerGeometryTap)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        liveLayerHost.frame = bounds
        for shapeLayer in liveShapeLayers { shapeLayer.frame = bounds }
        if committedImageSize != bounds.size {
            committedContentDirty = true
            settleDisplayScale()
            scheduleCommittedRebuild()
            refreshLiveContent()
        }
    }

    func invalidateCommittedContent() {
        committedContentDirty = true
        scheduleCommittedRebuild()
    }

    func beginCommitTransition(strokeID: String) {
        pendingCommitOverlayIDs.insert(strokeID)
        scheduleLiveRefresh()
    }

    private func setCommittedExclusions(_ ids: Set<String>) {
        guard ids != committedExclusions else { return }
        committedExclusions = ids
        committedContentDirty = true
        scheduleCommittedRebuild()
    }

    private func scheduleCommittedRebuild() {
        guard !committedRebuildScheduled else { return }
        committedRebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.committedRebuildScheduled = false
            guard self.committedContentDirty,
                  let model = self.model,
                  let page = model.pageInfo(at: self.pageIndex),
                  self.bounds.width > 0, self.bounds.height > 0 else { return }
            self.rebuildCommittedImage(
                model: model,
                page: page,
                configuration: model.strokeSettings.configuration
            )
        }
    }

    func scheduleLiveRefresh() {
        guard !liveRefreshScheduled else { return }
        liveRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.liveRefreshScheduled = false
            self.refreshLiveContent()
        }
    }

    func refreshLiveContent() {
        guard let model,
              let page = model.pageInfo(at: pageIndex),
              bounds.width > 0, bounds.height > 0 else {
            hideUnusedLiveLayers(from: 0)
            return
        }
        let strokeConfiguration = model.strokeSettings.configuration
        let appConfiguration = model.appSettings.configuration
        var descriptors: [LiveStrokeLayerDescriptor] = []

        for stroke in model.liveStrokesForPage(pageIndex) {
            if GeometryEngine.isGeometry(stroke) {
                descriptors.append(contentsOf: InteractionOverlayRenderer.shapePreview(
                    stroke: stroke,
                    page: page,
                    bounds: bounds
                ))
                continue
            }
            var renderedStroke = stroke
            if stroke.id == activeStrokeID, !predictedPoints.isEmpty {
                renderedStroke.points.append(contentsOf: predictedPoints)
            }
            descriptors.append(contentsOf: StrokeRenderer.liveLayerDescriptors(
                stroke: renderedStroke,
                page: page,
                viewBounds: bounds,
                configuration: strokeConfiguration
            ))
        }

        // Keep a just-finished stroke visible as a vector until the new
        // committed page image has actually been installed. Without this
        // hand-off the live layer disappears one run-loop turn before the
        // raster cache is ready, producing a visible flash.
        for id in pendingCommitOverlayIDs.sorted() {
            guard let stroke = model.stroke(withID: id) else { continue }
            if GeometryEngine.isGeometry(stroke) {
                descriptors.append(contentsOf: InteractionOverlayRenderer.shapePreview(
                    stroke: stroke,
                    page: page,
                    bounds: bounds
                ))
            } else if stroke.isInk {
                descriptors.append(contentsOf: StrokeRenderer.liveLayerDescriptors(
                    stroke: stroke,
                    page: page,
                    viewBounds: bounds,
                    configuration: strokeConfiguration
                ))
            }
        }

        if let shapeGesture {
            descriptors.append(contentsOf: InteractionOverlayRenderer.shapePreview(
                stroke: shapeGesture.preview,
                page: page,
                bounds: bounds
            ))
        }

        if let selectionGesture {
            if selectionGesture.mode == .lasso {
                descriptors.append(contentsOf: InteractionOverlayRenderer.lasso(
                    points: selectionGesture.lassoPoints,
                    page: page,
                    bounds: bounds,
                    zoomScale: interactionZoomScale
                ))
            } else {
                // During transforms, selected originals are excluded from the
                // committed page image and their current replacements are drawn
                // as live vectors. This avoids both ghosting and repeated
                // high-resolution bitmap rebuilds while dragging.
                for stroke in model.selectedStrokesForPage(pageIndex) {
                    if GeometryEngine.isGeometry(stroke) {
                        descriptors.append(contentsOf: InteractionOverlayRenderer.shapePreview(
                            stroke: stroke,
                            page: page,
                            bounds: bounds
                        ))
                    } else if stroke.isInk {
                        descriptors.append(contentsOf: StrokeRenderer.liveLayerDescriptors(
                            stroke: stroke,
                            page: page,
                            viewBounds: bounds,
                            configuration: strokeConfiguration
                        ))
                    }
                }
            }
        }

        descriptors.append(contentsOf: InteractionOverlayRenderer.selection(
            strokes: model.selectedStrokesForPage(pageIndex),
            page: page,
            bounds: bounds,
            settings: appConfiguration,
            zoomScale: interactionZoomScale
        ))

        if let snap = model.snapGuide, appConfiguration.showSnapGuides {
            descriptors.append(contentsOf: InteractionOverlayRenderer.snapGuide(
                snap,
                page: page,
                bounds: bounds,
                zoomScale: interactionZoomScale
            ))
        }

        if let eraserCursorWorld, contactTool == .eraser {
            descriptors.append(contentsOf: InteractionOverlayRenderer.eraserCursor(
                center: eraserCursorWorld,
                diameter: model.eraserSize,
                page: page,
                bounds: bounds,
                zoomScale: interactionZoomScale
            ))
        }

        ensureLiveLayerCapacity(descriptors.count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, descriptor) in descriptors.enumerated() {
            let shapeLayer = liveShapeLayers[index]
            shapeLayer.isHidden = false
            shapeLayer.frame = bounds
            shapeLayer.contentsScale = liveDisplayScale
            shapeLayer.path = descriptor.path
            shapeLayer.fillColor = descriptor.fillColor
            shapeLayer.strokeColor = descriptor.strokeColor
            shapeLayer.lineWidth = descriptor.lineWidth
            shapeLayer.lineDashPattern = descriptor.lineDashPattern
            shapeLayer.lineCap = descriptor.lineCap
            shapeLayer.lineJoin = descriptor.lineJoin
        }
        hideUnusedLiveLayers(from: descriptors.count)
        CATransaction.commit()
    }

    private func ensureLiveLayerCapacity(_ count: Int) {
        guard count > liveShapeLayers.count else { return }
        for _ in liveShapeLayers.count..<count {
            let shapeLayer = CAShapeLayer()
            shapeLayer.frame = bounds
            shapeLayer.contentsScale = liveDisplayScale
            liveLayerHost.addSublayer(shapeLayer)
            liveShapeLayers.append(shapeLayer)
        }
    }

    private func hideUnusedLiveLayers(from index: Int) {
        guard index < liveShapeLayers.count else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shapeLayer in liveShapeLayers[index...] {
            shapeLayer.isHidden = true
            shapeLayer.path = nil
        }
        CATransaction.commit()
    }

    func updateDisplayScale(_ pdfScale: CGFloat) {
        let previousScale = pendingPDFScale
        pendingPDFScale = max(0.05, pdfScale)
        liveDisplayScale = UIScreen.main.scale * min(max(1, pendingPDFScale), 4)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shapeLayer in liveShapeLayers { shapeLayer.contentsScale = liveDisplayScale }
        CATransaction.commit()
        if abs(previousScale - pendingPDFScale) > 0.001 {
            scheduleLiveRefresh()
        }
    }

    func settleDisplayScale() {
        guard let model else { return }
        let configuration = model.strokeSettings.configuration
        let screenScale = UIScreen.main.scale
        let requested = screenScale * max(1, pendingPDFScale)
        let maxScale = CGFloat(max(screenScale, configuration.maximumInkCacheScale))
        let area = max(1, bounds.width * bounds.height)
        let pixelBudget = CGFloat(max(1, configuration.maximumInkCacheMegapixels) * 1_000_000)
        let budgetScale = sqrt(pixelBudget / area)
        let desired = max(screenScale, min(requested, maxScale, budgetScale))

        if abs(committedRenderScale - desired) > 0.08 {
            committedRenderScale = desired
            committedContentDirty = true
            scheduleCommittedRebuild()
        }
    }

    private func rebuildCommittedImage(
        model: AppModel,
        page: PageInfo,
        configuration: StrokePipelineConfiguration
    ) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = committedRenderScale
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        committedImage = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.clear(bounds)
            context.clip(to: bounds)
            for stroke in model.committedStrokesForPage(pageIndex) where !committedExclusions.contains(stroke.id) {
                StrokeRenderer.draw(
                    stroke: stroke,
                    page: page,
                    in: context,
                    viewBounds: bounds,
                    configuration: configuration,
                    appConfiguration: model.appSettings.configuration,
                    isLive: false
                )
            }
        }
        committedImageSize = bounds.size
        committedContentDirty = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = committedImage?.cgImage
        layer.contentsScale = committedRenderScale
        CATransaction.commit()

        if !pendingCommitOverlayIDs.isEmpty {
            pendingCommitOverlayIDs.removeAll(keepingCapacity: true)
            // The committed image is already installed, so removing the live
            // duplicate here cannot expose an empty frame.
            refreshLiveContent()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil,
              let pencil = touches.first(where: { $0.type == .pencil }),
              let model,
              let page = model.pageInfo(at: pageIndex) else { return }

        activeTouch = pencil
        contactTool = model.selectedTool
        pipelineState.reset()
        predictedPoints.removeAll(keepingCapacity: true)

        switch contactTool {
        case .eraser:
            eraseOperationID = model.beginEraseOperation()
            erasedIDs.removeAll(keepingCapacity: true)
            eraserCursorWorld = worldPoint(from: pencil.location(in: self))
            erase(with: pencil)
            scheduleLiveRefresh()
        case .selector:
            beginSelection(at: pencil.location(in: self), page: page)
        case .shape:
            beginShape(at: pencil.location(in: self), page: page)
        case .pressurePen, .fixedPen, .highlighter:
            // Pencil ink tools never grab existing geometry. Geometry can be
            // manipulated with a finger, the eraser, or the explicit lasso tool.
            model.clearSelection()
            beginInk(with: pencil, page: page)
        case .none:
            break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch,
              touches.contains(touch),
              let model,
              let page = model.pageInfo(at: pageIndex) else { return }

        switch contactTool {
        case .eraser:
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            for sample in samples { erase(with: sample) }
            eraserCursorWorld = worldPoint(from: touch.location(in: self))
            scheduleLiveRefresh()
        case .selector:
            updateSelection(at: touch.location(in: self), page: page)
        case .shape:
            updateShape(at: touch.location(in: self), page: page)
        case .pressurePen, .fixedPen, .highlighter:
            updateInk(with: touch, event: event, model: model, page: page)
        case .none:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch,
              touches.contains(touch),
              let model,
              let page = model.pageInfo(at: pageIndex) else { return }

        switch contactTool {
        case .eraser:
            eraserCursorWorld = worldPoint(from: touch.location(in: self))
            erase(with: touch)
            if let operation = eraseOperationID { model.finishEraseOperation(operation) }
        case .selector:
            finishSelection(at: touch.location(in: self), page: page, cancelled: false)
        case .shape:
            updateShape(at: touch.location(in: self), page: page)
            finishShape(cancelled: false)
        case .pressurePen, .fixedPen, .highlighter:
            finishInk(with: touch, model: model, page: page)
        case .none:
            break
        }
        finishContact()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let model else { return }
        switch contactTool {
        case .eraser:
            if let operation = eraseOperationID { model.finishEraseOperation(operation) }
        case .selector:
            finishSelection(at: touch.location(in: self), page: model.pageInfo(at: pageIndex), cancelled: true)
        case .shape:
            finishShape(cancelled: true)
        case .pressurePen, .fixedPen, .highlighter:
            if let id = activeStrokeID { model.endStroke(strokeID: id) }
        case .none:
            break
        }
        finishContact()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === fingerGeometryPan || gestureRecognizer === fingerGeometryTap,
              activeTouch == nil,
              let model,
              let page = model.pageInfo(at: pageIndex) else { return false }

        let viewPoint = gestureRecognizer.location(in: self)
        let selected = model.selectedStrokesForPage(pageIndex)
        if !selected.isEmpty,
           selected.allSatisfy({ !$0.isLocked }),
           selectionHandleHit(
                at: viewPoint,
                strokes: selected,
                page: page,
                settings: model.appSettings.configuration
           ) != nil {
            return true
        }

        let world = worldPoint(from: viewPoint)
        let threshold = screenPointsToWorld(
            CGFloat(model.appSettings.configuration.selectorHitRadius),
            page: page
        )
        return model.directHitGeometry(
            pageIndex: pageIndex,
            worldPoint: world,
            threshold: threshold
        ) != nil
    }

    @objc private func handleFingerGeometryTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let model,
              let page = model.pageInfo(at: pageIndex) else { return }
        let viewPoint = gesture.location(in: self)
        let world = worldPoint(from: viewPoint)
        let threshold = screenPointsToWorld(
            CGFloat(model.appSettings.configuration.selectorHitRadius),
            page: page
        )
        guard let id = model.directHitGeometry(
            pageIndex: pageIndex,
            worldPoint: world,
            threshold: threshold
        ), let stroke = model.stroke(withID: id), !stroke.isLocked else { return }
        model.setSelection([id])
        performHaptic()
    }

    @objc private func handleFingerGeometryPan(_ gesture: UIPanGestureRecognizer) {
        guard let model, let page = model.pageInfo(at: pageIndex) else { return }
        let viewPoint = gesture.location(in: self)
        switch gesture.state {
        case .began:
            let world = worldPoint(from: viewPoint)
            let selected = model.selectedStrokesForPage(pageIndex)
            if !selected.isEmpty,
               selected.allSatisfy({ !$0.isLocked }),
               let mode = selectionHandleHit(
                    at: viewPoint,
                    strokes: selected,
                    page: page,
                    settings: model.appSettings.configuration
               ) {
                beginSelectionTransform(mode: mode, startWorld: world, originals: selected, page: page)
                return
            }

            let threshold = screenPointsToWorld(
                CGFloat(model.appSettings.configuration.selectorHitRadius),
                page: page
            )
            guard let id = model.directHitGeometry(
                pageIndex: pageIndex,
                worldPoint: world,
                threshold: threshold
            ), let stroke = model.stroke(withID: id), !stroke.isLocked else {
                gesture.isEnabled = false
                gesture.isEnabled = true
                return
            }
            model.setSelection([id])
            beginSelectionTransform(mode: .move, startWorld: world, originals: [stroke], page: page)
        case .changed:
            updateSelection(at: viewPoint, page: page)
        case .ended:
            finishSelection(at: viewPoint, page: page, cancelled: false)
        case .cancelled, .failed:
            finishSelection(at: viewPoint, page: page, cancelled: true)
        default:
            break
        }
    }

    func prepareForEviction() {
        installInteractionRecognizers(on: nil)
        guard let model else { return }
        if let operation = eraseOperationID {
            model.finishEraseOperation(operation)
        } else if let gesture = selectionGesture, gesture.mode != .lasso {
            model.restorePreviewStrokes(gesture.originals)
        } else if let id = activeStrokeID {
            model.endStroke(strokeID: id)
        }
        committedImage = nil
        layer.contents = nil
        committedContentDirty = true
        for shapeLayer in liveShapeLayers { shapeLayer.removeFromSuperlayer() }
        liveShapeLayers.removeAll(keepingCapacity: false)
        finishContact()
        model.unregister(pageView: self, pageIndex: pageIndex)
    }

    private func beginInk(with pencil: UITouch, page: PageInfo) {
        guard let model else { return }
        let configuration = model.strokeSettings.configuration
        let sample = makeInputSample(from: pencil, page: page)
        guard sample.pressure >= configuration.pressureThreshold,
              let point = pipelineState.process(
                sample,
                page: page,
                viewBounds: bounds,
                configuration: configuration,
                forceAccept: true
              ) else { return }
        activeStrokeID = model.beginStroke(pageIndex: pageIndex, firstPoint: point, tool: contactTool)
        scheduleGeometryRecognitionIfNeeded()
    }

    private func updateInk(with touch: UITouch, event: UIEvent?, model: AppModel, page: PageInfo) {
        let configuration = model.strokeSettings.configuration
        if let id = activeStrokeID, let stroke = model.stroke(withID: id),
           stroke.tool == "shape", stroke.recognitionSource != nil {
            recognitionWorkItem?.cancel()
            recognitionWorkItem = nil
            predictedPoints.removeAll(keepingCapacity: true)
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            if let latest = samples.max(by: { $0.timestamp < $1.timestamp }) {
                model.updateRecognizedGeometry(strokeID: id, pageIndex: pageIndex, endPoint: worldPoint(from: latest.location(in: self)))
            }
            scheduleLiveRefresh()
            return
        }
        let touchSamples: [UITouch]
        if configuration.useCoalescedTouches {
            touchSamples = (event?.coalescedTouches(for: touch) ?? [touch]).sorted { $0.timestamp < $1.timestamp }
        } else {
            touchSamples = [touch]
        }

        predictedPoints.removeAll(keepingCapacity: true)
        var accepted: [NotePoint] = []
        for touchSample in touchSamples {
            let input = makeInputSample(from: touchSample, page: page)
            if activeStrokeID == nil {
                guard input.pressure >= configuration.pressureThreshold else { continue }
                pipelineState.reset()
                guard let firstPoint = pipelineState.process(
                    input,
                    page: page,
                    viewBounds: bounds,
                    configuration: configuration,
                    forceAccept: true
                ) else { continue }
                activeStrokeID = model.beginStroke(pageIndex: pageIndex, firstPoint: firstPoint, tool: contactTool)
                continue
            }
            if let point = pipelineState.process(input, page: page, viewBounds: bounds, configuration: configuration) {
                accepted.append(point)
            }
        }
        if let id = activeStrokeID, !accepted.isEmpty {
            model.appendPoints(strokeID: id, points: accepted)
            scheduleGeometryRecognitionIfNeeded()
        }
        updatePredictedPreview(for: touch, event: event, page: page, configuration: configuration)
    }

    private func finishInk(with touch: UITouch, model: AppModel, page: PageInfo) {
        recognitionWorkItem?.cancel()
        recognitionWorkItem = nil
        predictedPoints.removeAll(keepingCapacity: true)
        guard let id = activeStrokeID else { return }
        if let stroke = model.stroke(withID: id), stroke.tool == "shape", stroke.recognitionSource != nil {
            // Preserve the held preview exactly; Pencil-up often contains a
            // repeated or slightly jittered final coordinate.
            model.endStroke(strokeID: id)
            return
        }
        let configuration = model.strokeSettings.configuration
        let input = makeInputSample(from: touch, page: page)
        if let point = pipelineState.process(
            input,
            page: page,
            viewBounds: bounds,
            configuration: configuration,
            forceAccept: true
        ) {
            model.appendPoints(strokeID: id, points: [point])
        }
        model.endStroke(strokeID: id)
    }

    private func beginShape(at viewPoint: CGPoint, page: PageInfo) {
        guard let model else { return }
        let world = worldPoint(from: viewPoint)
        guard let preview = model.makeGeometryStroke(
            type: model.selectedShapeType,
            pageIndex: pageIndex,
            start: world,
            end: world
        ) else { return }
        shapeGesture = ShapeGesture(startWorld: world, preview: preview, changed: false)
        model.clearSnapGuide(pageIndex: pageIndex)
        scheduleLiveRefresh()
    }

    private func updateShape(at viewPoint: CGPoint, page: PageInfo) {
        guard let model, var gesture = shapeGesture else { return }
        var end = worldPoint(from: viewPoint)
        let type = GeometryShapeType(rawValue: gesture.preview.shapeType ?? "line") ?? .line
        if type == .line || type == .arrow {
            let snap = model.snapGeometryPoint(end, pageIndex: pageIndex, excluding: gesture.preview.id, otherPoint: gesture.startWorld)
            end = snap.point
        }
        gesture.preview.points = GeometryEngine.makeShapePoints(type: type, start: gesture.startWorld, end: end, page: page)
        gesture.changed = gesture.changed || hypot(viewPoint.x - self.viewPoint(from: gesture.startWorld, page: page).x,
                                                     viewPoint.y - self.viewPoint(from: gesture.startWorld, page: page).y) > 5
        shapeGesture = gesture
        scheduleLiveRefresh()
    }

    private func finishShape(cancelled: Bool) {
        guard let model, let gesture = shapeGesture else { return }
        defer {
            shapeGesture = nil
            model.clearSnapGuide(pageIndex: pageIndex)
            scheduleLiveRefresh()
        }
        guard !cancelled, gesture.changed else { return }
        if model.addStrokes([gesture.preview]) {
            model.setSelection([gesture.preview.id])
            model.notice = "\(GeometryShapeType(rawValue: gesture.preview.shapeType ?? "")?.title ?? "Geometry") added"
            performHaptic()
        }
    }

    private func beginSelection(at viewPoint: CGPoint, page: PageInfo) {
        guard let model else { return }
        let world = worldPoint(from: viewPoint)
        let settings = model.appSettings.configuration
        let selected = model.selectedStrokesForPage(pageIndex)
        let selectedUnlocked = !selected.isEmpty && selected.allSatisfy { !$0.isLocked }

        if selectedUnlocked,
           let hit = selectionHandleHit(at: viewPoint, strokes: selected, page: page, settings: settings) {
            beginSelectionTransform(mode: hit, startWorld: world, originals: selected, page: page)
            return
        }

        if let directID = model.directHitStroke(
            pageIndex: pageIndex,
            worldPoint: world,
            threshold: screenPointsToWorld(CGFloat(settings.selectorHitRadius), page: page),
            includeLocked: !settings.selectLockedItemsOnlyByLasso
        ), let stroke = model.stroke(withID: directID), !stroke.isLocked {
            if !model.selectedStrokeIDs.contains(directID) || model.selectedStrokes.contains(where: { $0.isLocked }) {
                model.setSelection([directID])
            }
            let originals = model.selectedStrokesForPage(pageIndex)
            beginSelectionTransform(mode: .move, startWorld: world, originals: originals, page: page)
            return
        }

        model.clearSnapGuide(pageIndex: pageIndex)
        selectionGesture = SelectionTransformGesture(
            mode: .lasso,
            startWorld: world,
            originals: [],
            lassoPoints: [world],
            startViewPoint: viewPoint
        )
        scheduleLiveRefresh()
    }

    private func beginSelectionTransform(
        mode: SelectionTransformMode,
        startWorld: CGPoint,
        originals: [NoteStroke],
        page: PageInfo
    ) {
        guard let model,
              let bounds = GeometryEngine.selectionBounds(originals) else { return }
        var gesture = SelectionTransformGesture(
            mode: mode,
            startWorld: startWorld,
            originals: originals,
            center: bounds.center
        )
        switch mode {
        case .rotate:
            gesture.startAngle = atan2(startWorld.y - bounds.midY, startWorld.x - bounds.midX)
        case .scale(let handle):
            let opposite: CGPoint
            switch handle {
            case "nw": opposite = CGPoint(x: bounds.maxX, y: bounds.maxY)
            case "ne": opposite = CGPoint(x: bounds.minX, y: bounds.maxY)
            case "sw": opposite = CGPoint(x: bounds.maxX, y: bounds.minY)
            default: opposite = CGPoint(x: bounds.minX, y: bounds.minY)
            }
            gesture.anchor = opposite
            gesture.startDistance = max(0.001, hypot(startWorld.x - opposite.x, startWorld.y - opposite.y))
        default:
            break
        }
        selectionGesture = gesture
        setCommittedExclusions(model.selectedStrokeIDs)
        scheduleLiveRefresh()
    }

    private func updateSelection(at viewPoint: CGPoint, page: PageInfo) {
        guard let model, var gesture = selectionGesture else { return }
        let world = worldPoint(from: viewPoint)
        let settings = model.appSettings.configuration

        switch gesture.mode {
        case .lasso:
            let lastView = gesture.lassoPoints.last.map { self.viewPoint(from: $0, page: page) }
            if lastView == nil || hypot(viewPoint.x - lastView!.x, viewPoint.y - lastView!.y) >= screenPointsToLocal(CGFloat(settings.lassoSampleSpacing)) {
                gesture.lassoPoints.append(world)
                gesture.changed = true
            }
        case .move:
            let dx = world.x - gesture.startWorld.x
            let dy = world.y - gesture.startWorld.y
            gesture.changed = gesture.changed || hypot(dx, dy) > 0.1
            model.previewReplaceStrokes(gesture.originals.map {
                GeometryEngine.translated($0, dx: dx, dy: dy, page: page)
            })
        case .rotate:
            let angle = atan2(world.y - gesture.center.y, world.x - gesture.center.x)
            let delta = angle - gesture.startAngle
            gesture.changed = gesture.changed || abs(delta) > 0.003
            model.previewReplaceStrokes(gesture.originals.map {
                GeometryEngine.rotated($0, around: gesture.center, angle: delta, page: page)
            })
        case .scale:
            let distance = hypot(world.x - gesture.anchor.x, world.y - gesture.anchor.y)
            let scale = max(0.05, min(20, distance / max(0.001, gesture.startDistance)))
            gesture.changed = gesture.changed || abs(scale - 1) > 0.003
            model.previewReplaceStrokes(gesture.originals.map {
                GeometryEngine.scaled($0, around: gesture.anchor, factor: scale, page: page)
            })
        case .point(let index):
            guard let original = gesture.originals.first else { break }
            let otherIndex: Int
            if original.shapeType == "curve" { otherIndex = index == 0 ? 2 : 0 }
            else { otherIndex = index == 0 ? max(0, original.points.count - 1) : 0 }
            let shouldSnap = !(original.shapeType == "curve" && index == 1)
            let other = original.points.indices.contains(otherIndex) ? original.points[otherIndex].cgPoint : nil
            let target = shouldSnap
                ? model.snapGeometryPoint(world, pageIndex: pageIndex, excluding: original.id, otherPoint: other).point
                : world
            gesture.changed = true
            model.previewReplaceStrokes([GeometryEngine.withPoint(original, index: index, point: target, page: page)])
        }
        selectionGesture = gesture
        scheduleLiveRefresh()
    }

    private func finishSelection(at viewPoint: CGPoint, page: PageInfo?, cancelled: Bool) {
        guard let model, var gesture = selectionGesture else { return }
        if let page, !cancelled { updateSelection(at: viewPoint, page: page); gesture = selectionGesture ?? gesture }

        defer {
            selectionGesture = nil
            setCommittedExclusions([])
            model.clearSnapGuide(pageIndex: pageIndex)
            scheduleLiveRefresh()
        }

        if gesture.mode == .lasso {
            guard !cancelled else { return }
            let moved = hypot(viewPoint.x - gesture.startViewPoint.x, viewPoint.y - gesture.startViewPoint.y)
            if gesture.lassoPoints.count >= 3, moved >= screenPointsToLocal(8) {
                model.selectByLasso(pageIndex: pageIndex, polygon: gesture.lassoPoints)
            } else {
                guard let currentPage = page ?? model.pageInfo(at: pageIndex) else { return }
                let threshold = screenPointsToWorld(
                    CGFloat(model.appSettings.configuration.selectorHitRadius),
                    page: currentPage
                )
                let hit = model.directHitStroke(pageIndex: pageIndex, worldPoint: gesture.startWorld, threshold: threshold)
                model.setSelection(hit.map { Set([$0]) } ?? [])
            }
            performHaptic()
            return
        }

        if cancelled {
            model.restorePreviewStrokes(gesture.originals)
            return
        }
        guard gesture.changed else { return }
        let replacements = model.selectedStrokesForPage(pageIndex)
        if !model.sendReplacementStrokes(replacements) {
            model.restorePreviewStrokes(gesture.originals)
        } else {
            performHaptic()
        }
    }

    private func selectionHandleHit(
        at viewPoint: CGPoint,
        strokes: [NoteStroke],
        page: PageInfo,
        settings: NativeAppConfiguration
    ) -> SelectionTransformMode? {
        guard let geometry = InteractionOverlayRenderer.selectionScreenGeometry(
            strokes: strokes,
            page: page,
            bounds: bounds,
            zoomScale: interactionZoomScale
        ) else { return nil }
        let radius = screenPointsToLocal(CGFloat(max(12, settings.selectionHandleSize + 4)))

        if strokes.count == 1, let stroke = strokes.first,
           GeometryEngine.isGeometry(stroke),
           ["line", "arrow", "curve"].contains(stroke.shapeType ?? "") {
            for (index, point) in stroke.points.enumerated() {
                let handle = self.viewPoint(from: point.cgPoint, page: page)
                if hypot(viewPoint.x - handle.x, viewPoint.y - handle.y) <= radius { return .point(index: index) }
            }
        }
        if hypot(viewPoint.x - geometry.rotation.x, viewPoint.y - geometry.rotation.y) <= radius { return .rotate }
        for (name, handle) in geometry.handles where hypot(viewPoint.x - handle.x, viewPoint.y - handle.y) <= radius {
            return .scale(handle: name)
        }
        let moveInset = screenPointsToLocal(4)
        if geometry.view.insetBy(dx: -moveInset, dy: -moveInset).contains(viewPoint) { return .move }
        return nil
    }

    private func finishContact() {
        recognitionWorkItem?.cancel()
        recognitionWorkItem = nil
        activeTouch = nil
        activeStrokeID = nil
        contactTool = nil
        pipelineState.reset()
        predictedPoints.removeAll(keepingCapacity: true)
        eraseOperationID = nil
        erasedIDs.removeAll(keepingCapacity: true)
        eraserCursorWorld = nil
        shapeGesture = nil
        selectionGesture = nil
        setCommittedExclusions([])
        refreshLiveContent()
    }

    private func scheduleGeometryRecognitionIfNeeded() {
        recognitionWorkItem?.cancel()
        recognitionWorkItem = nil
        guard let model, let id = activeStrokeID,
              let stroke = model.stroke(withID: id),
              stroke.points.count >= 4,
              stroke.tool == NoteTool.pressurePen.rawValue || stroke.tool == NoteTool.fixedPen.rawValue,
              model.appSettings.configuration.holdRecognitionEnabled else { return }
        let delay = max(0.15, model.appSettings.configuration.recognitionHoldMS / 1000)
        let work = DispatchWorkItem { [weak self, weak model] in
            guard let self, let model, self.activeStrokeID == id else { return }
            if model.recognizeActiveInk(strokeID: id, pageIndex: self.pageIndex) {
                self.predictedPoints.removeAll(keepingCapacity: true)
                self.performHaptic()
                self.scheduleLiveRefresh()
            }
        }
        recognitionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updatePredictedPreview(
        for touch: UITouch,
        event: UIEvent?,
        page: PageInfo,
        configuration: StrokePipelineConfiguration
    ) {
        guard activeStrokeID != nil, configuration.usePredictedTouches else {
            predictedPoints.removeAll(keepingCapacity: true)
            scheduleLiveRefresh()
            return
        }
        let predictedTouches = (event?.predictedTouches(for: touch) ?? []).sorted { $0.timestamp < $1.timestamp }
        var previewState = pipelineState
        predictedPoints = predictedTouches.compactMap { predicted in
            previewState.process(
                makeInputSample(from: predicted, page: page),
                page: page,
                viewBounds: bounds,
                configuration: configuration
            )
        }
        scheduleLiveRefresh()
    }

    private func erase(with touch: UITouch) {
        guard let model, let operation = eraseOperationID else { return }
        let world = worldPoint(from: touch.location(in: self))
        model.erase(at: world, pageIndex: pageIndex, operationID: operation, alreadyDeleted: &erasedIDs)
    }

    private func makeInputSample(from touch: UITouch, page: PageInfo) -> PencilInputSample {
        let localView = touch.location(in: self)
        let pagePoint = CGPoint(
            x: bounds.width > 0 ? localView.x / bounds.width * CGFloat(page.width) : 0,
            y: bounds.height > 0 ? localView.y / bounds.height * CGFloat(page.height) : 0
        )
        let world = CGPoint(x: CGFloat(page.x) + pagePoint.x, y: CGFloat(page.y) + pagePoint.y)
        let pressure: Double
        if touch.maximumPossibleForce > 0 {
            pressure = max(0, min(1, Double(touch.force / touch.maximumPossibleForce)))
        } else {
            pressure = 0.5
        }
        return PencilInputSample(
            viewPoint: localView,
            rawWorldPoint: world,
            rawPagePoint: pagePoint,
            pressure: pressure,
            timestampMS: touch.timestamp * 1000,
            altitude: Double(touch.altitudeAngle),
            azimuth: Double(touch.azimuthAngle(in: self))
        )
    }

    private func worldPoint(from local: CGPoint) -> CGPoint {
        guard let page = model?.pageInfo(at: pageIndex), bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(
            x: CGFloat(page.x) + local.x / bounds.width * CGFloat(page.width),
            y: CGFloat(page.y) + local.y / bounds.height * CGFloat(page.height)
        )
    }

    private func viewPoint(from world: CGPoint, page: PageInfo) -> CGPoint {
        CGPoint(
            x: (world.x - CGFloat(page.x)) / max(0.001, CGFloat(page.width)) * bounds.width,
            y: (world.y - CGFloat(page.y)) / max(0.001, CGFloat(page.height)) * bounds.height
        )
    }

    private func screenPointsToLocal(_ points: CGFloat) -> CGFloat {
        points / interactionZoomScale
    }

    private func screenPointsToWorld(_ points: CGFloat, page: PageInfo) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return points }
        let localPoints = screenPointsToLocal(points)
        let xScale = CGFloat(page.width) / bounds.width
        let yScale = CGFloat(page.height) / bounds.height
        return localPoints * (xScale + yScale) / 2
    }

    private func performHaptic() {
        guard model?.appSettings.configuration.hapticsEnabled == true else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
