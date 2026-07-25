import CoreGraphics
import PDFKit
import QuartzCore
import SwiftUI
import UIKit

/// Navigation bridge used by the SwiftUI toolbar.
///
/// The first preview attached this to PDFView. The current renderer uses PDFKit
/// for PDF parsing but performs page drawing itself with CGPDFPage + CATiledLayer
/// so each zoom level requests fresh vector-rendered tiles.
@MainActor
final class PDFNavigator: ObservableObject {
    weak var viewer: VectorPDFScrollView?

    func previousPage() {
        viewer?.goToRelativePage(-1)
    }

    func nextPage() {
        viewer?.goToRelativePage(1)
    }

    func go(toPageNumber pageNumber: Int) {
        viewer?.goToPage(index: pageNumber - 1, animated: true)
    }

    func fitPage() {
        viewer?.fitCurrentPage(animated: true)
    }
}

/// SwiftUI wrapper retaining the old type name so the rest of the v24-compatible
/// client does not need to change.
struct PDFKitNotebookView: UIViewRepresentable {
    @ObservedObject var model: AppModel
    @ObservedObject var navigator: PDFNavigator

    func makeUIView(context: Context) -> VectorPDFScrollView {
        let viewer = VectorPDFScrollView(model: model)
        navigator.viewer = viewer
        viewer.setDocument(model.pdfDocument, sourceURL: model.pdfFileURL)
        return viewer
    }

    func updateUIView(_ viewer: VectorPDFScrollView, context: Context) {
        viewer.model = model
        if viewer.sourceURL != model.pdfFileURL || viewer.pdfDocument !== model.pdfDocument {
            viewer.setDocument(model.pdfDocument, sourceURL: model.pdfFileURL)
        }
        viewer.applySettings(settingsRevision: model.settingsRevision, workspaceRevision: model.workspaceRevision)
        if navigator.viewer !== viewer {
            navigator.viewer = viewer
        }
    }

    static func dismantleUIView(_ uiView: VectorPDFScrollView, coordinator: ()) {
        uiView.prepareForRemoval()
    }
}

/// A vertically scrolling, zoomable PDF notebook.
///
/// Only five page containers are mounted at once: the current page and two on
/// either side. Every page background is a CATiledLayer that asks Core Graphics
/// to draw the original PDF page at the tile's actual zoom resolution.
@MainActor
final class VectorPDFScrollView: UIScrollView, UIScrollViewDelegate {
    var model: AppModel
    private(set) var pdfDocument: PDFDocument?
    private(set) var sourceURL: URL?

    private let documentView = UIView(frame: .zero)
    private var coreDocument: CGPDFDocument?
    private var workspaceFrames: [CGRect] = []
    private var pdfFrames: [CGRect] = []
    private var mountedPages: [Int: VectorPDFPageContainer] = [:]
    private var currentPageIndex = -1
    private var needsInitialFit = false
    private var lastViewportSize: CGSize = .zero
    private var lastSettingsRevision = -1
    private var lastWorkspaceRevision = -1
    private var appliedPageGap: CGFloat = 18

    private let horizontalMargin: CGFloat = 18
    private let verticalMargin: CGFloat = 18
    private var pageGap: CGFloat { CGFloat(model.appSettings.configuration.pageGap) }
    private var workingRadius: Int { max(0, min(6, model.appSettings.configuration.pageWorkingRadius)) }

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)

        delegate = self
        backgroundColor = .secondarySystemBackground
        alwaysBounceVertical = true
        alwaysBounceHorizontal = true
        bouncesZoom = true
        isDirectionalLockEnabled = false
        delaysContentTouches = false
        canCancelContentTouches = true
        decelerationRate = .fast
        showsVerticalScrollIndicator = true
        showsHorizontalScrollIndicator = true
        // Prevent taps in the app's top chrome/status area from invoking
        // UIKit's automatic "scroll to top" behaviour on this document view.
        scrollsToTop = false
        maximumZoomScale = CGFloat(model.appSettings.configuration.maximumZoom)
        applyBackgroundStyle()

        panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        pinchGestureRecognizer?.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
        ]

        documentView.backgroundColor = .clear
        addSubview(documentView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }

        if lastViewportSize != bounds.size {
            lastViewportSize = bounds.size
            updateZoomLimits()
            if needsInitialFit {
                needsInitialFit = false
                fitCurrentPage(animated: false)
            } else {
                updateContentInsets()
            }
        }
        updateWorkingSet()
    }

    func applySettings(settingsRevision: Int, workspaceRevision: Int) {
        let settingsChanged = settingsRevision != lastSettingsRevision
        let workspaceChanged = workspaceRevision != lastWorkspaceRevision
        guard settingsChanged || workspaceChanged else { return }
        lastSettingsRevision = settingsRevision
        lastWorkspaceRevision = workspaceRevision

        applyBackgroundStyle()
        maximumZoomScale = max(minimumZoomScale, CGFloat(model.appSettings.configuration.maximumZoom))
        let gapChanged = abs(appliedPageGap - pageGap) > 0.01
        appliedPageGap = pageGap
        for page in mountedPages.values { page.applyAppearance() }

        guard (gapChanged || workspaceChanged),
              let document = pdfDocument, let coreDocument,
              document.pageCount > 0, coreDocument.numberOfPages > 0 else {
            mountWorkingSet(around: max(0, currentPageIndex))
            return
        }

        let target = min(max(0, currentPageIndex), max(0, pdfFrames.count - 1))
        let sourceAnchor: CGPoint?
        if pdfFrames.indices.contains(target), zoomScale > 0 {
            let oldPDF = pdfFrames[target]
            let viewportCenter = CGPoint(
                x: (contentOffset.x + contentInset.left + bounds.width / 2) / zoomScale,
                y: (contentOffset.y + contentInset.top + bounds.height / 2) / zoomScale
            )
            sourceAnchor = CGPoint(x: viewportCenter.x - oldPDF.minX, y: viewportCenter.y - oldPDF.minY)
        } else {
            sourceAnchor = nil
        }

        unmountAllPages()
        buildPageLayout(pageCount: min(document.pageCount, coreDocument.numberOfPages))
        currentPageIndex = min(target, max(0, workspaceFrames.count - 1))
        model.setCurrentPage(index: currentPageIndex)
        mountWorkingSet(around: currentPageIndex)

        if let sourceAnchor, pdfFrames.indices.contains(currentPageIndex) {
            let newPDF = pdfFrames[currentPageIndex]
            restoreViewportCenter(
                CGPoint(x: newPDF.minX + sourceAnchor.x, y: newPDF.minY + sourceAnchor.y),
                animated: false
            )
        } else {
            goToPage(index: currentPageIndex, animated: false)
        }
    }


    private func applyBackgroundStyle() {
        switch model.appSettings.configuration.backgroundStyle {
        case .system: backgroundColor = .secondarySystemBackground
        case .lightGray: backgroundColor = UIColor(white: 0.86, alpha: 1)
        case .darkGray: backgroundColor = UIColor(white: 0.20, alpha: 1)
        case .black: backgroundColor = .black
        }
    }

    func setDocument(_ document: PDFDocument?, sourceURL: URL?) {
        unmountAllPages()
        pdfDocument = document
        self.sourceURL = sourceURL
        coreDocument = sourceURL.flatMap { CGPDFDocument($0 as CFURL) }
        workspaceFrames.removeAll(keepingCapacity: false)
        pdfFrames.removeAll(keepingCapacity: false)
        currentPageIndex = -1

        guard let document, let coreDocument, document.pageCount > 0, coreDocument.numberOfPages > 0 else {
            documentView.frame = .zero
            contentSize = .zero
            model.setCurrentPage(index: -1)
            return
        }

        buildPageLayout(pageCount: min(document.pageCount, coreDocument.numberOfPages))
        let requestedPage = min(
            max(0, model.currentPageNumber - 1),
            max(0, workspaceFrames.count - 1)
        )
        currentPageIndex = requestedPage
        model.setCurrentPage(index: requestedPage)
        mountWorkingSet(around: requestedPage)
        needsInitialFit = true
        setNeedsLayout()
    }

    func prepareForRemoval() {
        unmountAllPages()
        if model.mountedPageIndices.isEmpty == false {
            for index in model.mountedPageIndices {
                model.pageDidUnmount(index)
            }
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        documentView
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateWorkingSet()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateContentInsets()
        updateMountedInkScales(settle: false)
        updateWorkingSet()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        // Invalidate visible PDF tiles after a pinch settles. This discards any
        // transitional low-resolution tile and requests a tile at the final CTM.
        for page in mountedPages.values { page.refreshPDFTiles() }
        updateMountedInkScales(settle: true)
    }

    func goToRelativePage(_ delta: Int) {
        guard !workspaceFrames.isEmpty else { return }
        let base = currentPageIndex >= 0 ? currentPageIndex : 0
        goToPage(index: min(max(base + delta, 0), workspaceFrames.count - 1), animated: true)
    }

    func goToPage(index: Int, animated: Bool) {
        guard workspaceFrames.indices.contains(index) else { return }
        currentPageIndex = index
        model.setCurrentPage(index: index)
        mountWorkingSet(around: index)
        updateMountedInkScales(settle: true)

        let pageFrame = workspaceFrames[index]
        let targetY = pageFrame.minY * zoomScale - contentInset.top - 8
        let minY = -contentInset.top
        let maxY = max(minY, contentSize.height - bounds.height + contentInset.bottom)
        setContentOffset(
            CGPoint(x: contentOffset.x, y: min(max(targetY, minY), maxY)),
            animated: animated
        )
    }

    func fitCurrentPage(animated: Bool) {
        guard pdfFrames.indices.contains(max(0, currentPageIndex)), bounds.width > 0, bounds.height > 0 else { return }
        let index = max(0, currentPageIndex)
        let page = pdfFrames[index]
        let usableWidth = max(1, bounds.width - 24)
        let usableHeight = max(1, bounds.height - 24)
        let scale = min(usableWidth / page.width, usableHeight / page.height)
        let clamped = min(maximumZoomScale, max(minimumZoomScale, scale))
        setZoomScale(clamped, animated: animated)

        let targetX = page.midX * clamped - bounds.width / 2 - contentInset.left
        let targetY = page.midY * clamped - bounds.height / 2 - contentInset.top
        let minX = -contentInset.left
        let minY = -contentInset.top
        let maxX = max(minX, contentSize.width - bounds.width + contentInset.right)
        let maxY = max(minY, contentSize.height - bounds.height + contentInset.bottom)
        setContentOffset(
            CGPoint(x: min(max(targetX, minX), maxX), y: min(max(targetY, minY), maxY)),
            animated: animated
        )
    }

    private func buildPageLayout(pageCount: Int) {
        var pageSizes: [CGSize] = []
        pageSizes.reserveCapacity(pageCount)

        for index in 0..<pageCount {
            guard let page = coreDocument?.page(at: index + 1) else {
                pageSizes.append(CGSize(width: 612, height: 792))
                continue
            }
            var bounds = page.getBoxRect(.cropBox)
            if bounds.isEmpty { bounds = page.getBoxRect(.mediaBox) }
            let rotation = ((page.rotationAngle % 360) + 360) % 360
            if rotation == 90 || rotation == 270 {
                pageSizes.append(CGSize(width: abs(bounds.height), height: abs(bounds.width)))
            } else {
                pageSizes.append(CGSize(width: abs(bounds.width), height: abs(bounds.height)))
            }
        }

        let workspaceWidths = pageSizes.enumerated().map { index, size in
            let state = model.workspaceState(at: index)
            return CGFloat(state.leftPageWidths + 1 + state.rightPageWidths) * max(1, size.width)
        }
        let maximumWorkspaceWidth = max(1, workspaceWidths.max() ?? 1836)
        var y = verticalMargin
        workspaceFrames.removeAll(keepingCapacity: true)
        pdfFrames.removeAll(keepingCapacity: true)

        for (index, size) in pageSizes.enumerated() {
            let state = model.workspaceState(at: index)
            let pageWidth = max(1, size.width)
            let workspaceWidth = workspaceWidths[index]
            let workspaceX = horizontalMargin + (maximumWorkspaceWidth - workspaceWidth) / 2
            let workspace = CGRect(x: workspaceX, y: y, width: workspaceWidth, height: max(1, size.height))
            let pdf = CGRect(
                x: workspace.minX + CGFloat(state.leftPageWidths) * pageWidth,
                y: workspace.minY,
                width: pageWidth,
                height: max(1, size.height)
            )
            workspaceFrames.append(workspace)
            pdfFrames.append(pdf)
            y = workspace.maxY + pageGap
        }

        let width = maximumWorkspaceWidth + horizontalMargin * 2
        let height = max(1, y - pageGap + verticalMargin)
        documentView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        contentSize = documentView.bounds.size
        updateZoomLimits()
        mountWorkingSet(around: min(max(0, currentPageIndex), max(0, workspaceFrames.count - 1)))
    }


    private func updateZoomLimits() {
        guard documentView.bounds.width > 0, bounds.width > 0 else {
            minimumZoomScale = 0.1
            return
        }
        let widestPDF = max(1, pdfFrames.map(\.width).max() ?? documentView.bounds.width)
        let widthFit = max(0.05, (bounds.width - 24) / widestPDF)
        minimumZoomScale = min(1, widthFit)
        maximumZoomScale = max(CGFloat(model.appSettings.configuration.maximumZoom), minimumZoomScale)
        if zoomScale < minimumZoomScale {
            zoomScale = minimumZoomScale
        }
        updateContentInsets()
    }

    private func updateContentInsets() {
        let scaledWidth = documentView.bounds.width * zoomScale
        let scaledHeight = documentView.bounds.height * zoomScale
        let horizontal = max(0, (bounds.width - scaledWidth) / 2)
        let vertical = max(0, (bounds.height - scaledHeight) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    private func restoreViewportCenter(_ documentPoint: CGPoint, animated: Bool) {
        let targetX = documentPoint.x * zoomScale - bounds.width / 2 - contentInset.left
        let targetY = documentPoint.y * zoomScale - bounds.height / 2 - contentInset.top
        let minX = -contentInset.left
        let minY = -contentInset.top
        let maxX = max(minX, contentSize.width - bounds.width + contentInset.right)
        let maxY = max(minY, contentSize.height - bounds.height + contentInset.bottom)
        setContentOffset(
            CGPoint(x: min(max(targetX, minX), maxX), y: min(max(targetY, minY), maxY)),
            animated: animated
        )
    }

    private func updateWorkingSet() {
        guard !workspaceFrames.isEmpty, zoomScale > 0 else { return }
        let visibleMidY = (contentOffset.y + contentInset.top + bounds.height / 2) / zoomScale
        let index = nearestPage(toDocumentY: visibleMidY)
        if index != currentPageIndex {
            currentPageIndex = index
            model.setCurrentPage(index: index)
        }
        mountWorkingSet(around: index)
        updateMountedInkScales(settle: false)
    }

    private func nearestPage(toDocumentY y: CGFloat) -> Int {
        var low = 0
        var high = workspaceFrames.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let frame = workspaceFrames[mid]
            if y < frame.minY {
                high = mid - 1
            } else if y > frame.maxY {
                low = mid + 1
            } else {
                return mid
            }
        }
        if low >= workspaceFrames.count { return workspaceFrames.count - 1 }
        if high < 0 { return 0 }
        let lowDistance = abs(workspaceFrames[low].midY - y)
        let highDistance = abs(workspaceFrames[high].midY - y)
        return lowDistance < highDistance ? low : high
    }

    private func mountWorkingSet(around current: Int) {
        guard !workspaceFrames.isEmpty else { return }
        let lower = max(0, current - workingRadius)
        let upper = min(workspaceFrames.count - 1, current + workingRadius)
        let desired = Set(lower...upper)

        for index in Array(mountedPages.keys) where !desired.contains(index) {
            guard let page = mountedPages.removeValue(forKey: index) else { continue }
            page.prepareForEviction()
            page.removeFromSuperview()
            model.pageDidUnmount(index)
        }

        for index in desired.sorted() where mountedPages[index] == nil {
            guard let corePage = coreDocument?.page(at: index + 1), model.pageInfo(at: index) != nil else { continue }
            let page = VectorPDFPageContainer(
                pageIndex: index,
                pdfPage: corePage,
                sourcePDFFrame: pdfFrames[index].offsetBy(dx: -workspaceFrames[index].minX, dy: -workspaceFrames[index].minY),
                model: model
            )
            page.frame = workspaceFrames[index]
            let scale = (!model.appSettings.configuration.reduceNeighbourInkQuality || index == currentPageIndex) ? zoomScale : 1
            page.updateZoomScale(scale)
            documentView.addSubview(page)
            mountedPages[index] = page
            model.pageDidMount(index)
        }
    }

    private func updateMountedInkScales(settle: Bool) {
        for (index, page) in mountedPages {
            // Only the current page receives a zoom-scaled committed ink cache.
            // Neighbour pages stay at base resolution until they become current.
            let scale = (!model.appSettings.configuration.reduceNeighbourInkQuality || index == currentPageIndex) ? zoomScale : 1
            page.updateZoomScale(scale)
            if settle { page.settleInkScale() }
        }
    }

    private func unmountAllPages() {
        for (index, page) in mountedPages {
            page.prepareForEviction()
            page.removeFromSuperview()
            model.pageDidUnmount(index)
        }
        mountedPages.removeAll(keepingCapacity: false)
    }
}

/// One mounted notebook page: vector PDF background plus the v24-compatible ink
/// overlay. The PDF layer never stores a whole-page bitmap.
@MainActor
private final class VectorPDFPageContainer: UIView {
    private let pageIndex: Int
    private let sourcePDFFrame: CGRect
    private let gridView = OffPageGridView(frame: .zero)
    private let pdfSurface = UIView(frame: .zero)
    private let pdfBackground: TiledPDFPageView
    private let inkOverlay: InkPageView
    private weak var model: AppModel?

    init(pageIndex: Int, pdfPage: CGPDFPage, sourcePDFFrame: CGRect, model: AppModel) {
        self.pageIndex = pageIndex
        self.sourcePDFFrame = sourcePDFFrame
        self.model = model
        pdfBackground = TiledPDFPageView(page: pdfPage)
        inkOverlay = InkPageView(pageIndex: pageIndex, model: model)
        super.init(frame: .zero)

        backgroundColor = .clear
        clipsToBounds = false
        pdfSurface.backgroundColor = .white
        pdfSurface.layer.borderColor = UIColor.separator.cgColor
        pdfSurface.layer.borderWidth = 0.5
        pdfSurface.addSubview(pdfBackground)
        addSubview(gridView)
        addSubview(pdfSurface)
        addSubview(inkOverlay)
        applyAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyAppearance() {
        guard let model else { return }
        let settings = model.appSettings.configuration
        let state = model.workspaceState(at: pageIndex)
        gridView.sourcePDFFrame = sourcePDFFrame
        gridView.isGridActive = state.hasOffPageContent
        gridView.gridStyle = settings.resolvedOffPageGridStyle
        gridView.gridSpacing = CGFloat(settings.resolvedOffPageGridSpacing)

        pdfSurface.layer.shadowColor = UIColor.black.cgColor
        pdfSurface.layer.shadowOpacity = settings.showPageShadow ? 0.16 : 0
        pdfSurface.layer.shadowRadius = settings.showPageShadow ? 3 : 0
        pdfSurface.layer.shadowOffset = CGSize(width: 0, height: 1)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gridView.frame = bounds
        pdfSurface.frame = sourcePDFFrame
        pdfBackground.frame = pdfSurface.bounds
        inkOverlay.frame = bounds
        inkOverlay.settleDisplayScale()
        pdfSurface.layer.shadowPath = UIBezierPath(rect: pdfSurface.bounds).cgPath
    }

    func updateZoomScale(_ scale: CGFloat) {
        inkOverlay.updateDisplayScale(scale)
    }

    func refreshPDFTiles() {
        pdfBackground.refreshTiles()
    }

    func settleInkScale() {
        inkOverlay.settleDisplayScale()
    }

    func prepareForEviction() {
        inkOverlay.prepareForEviction()
        pdfBackground.releaseTiles()
    }
}

/// A genuinely zoom-aware PDF background. CATiledLayer supplies small regions
/// at the current CTM; each region is drawn directly from the original CGPDFPage.
/// There is no fixed-resolution PNG or whole-page UIImage in this class.
private final class TiledPDFPageView: UIView {
    private let page: CGPDFPage

    override class var layerClass: AnyClass {
        CATiledLayer.self
    }

    private var tiledLayer: CATiledLayer {
        layer as! CATiledLayer
    }

    init(page: CGPDFPage) {
        self.page = page
        super.init(frame: .zero)

        isOpaque = true
        backgroundColor = .white
        contentMode = .redraw
        tiledLayer.tileSize = CGSize(width: 1024, height: 1024)
        tiledLayer.levelsOfDetail = 4
        tiledLayer.levelsOfDetailBias = 6
        tiledLayer.contentsScale = UIScreen.main.scale
        layer.drawsAsynchronously = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), bounds.width > 0, bounds.height > 0 else { return }
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high
        context.setRenderingIntent(.relativeColorimetric)

        // UIKit drawing contexts use a top-left origin with Y increasing
        // downward. PDF pages use the Quartz/PDF bottom-left coordinate system.
        // Flip the context once before applying the page's crop-box transform;
        // otherwise the native PDF content appears upside-down/180° rotated.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let transform = page.getDrawingTransform(
            .cropBox,
            rect: bounds,
            rotate: 0,
            preserveAspectRatio: false
        )
        context.concatenate(transform)
        context.drawPDFPage(page)
        context.restoreGState()
    }

    func refreshTiles() {
        tiledLayer.setNeedsDisplay()
    }

    func releaseTiles() {
        // Removing the layer from the hierarchy releases its tile cache. Mark it
        // dirty as well so a reused view can never expose a stale low-LOD tile.
        tiledLayer.setNeedsDisplay()
    }
}
