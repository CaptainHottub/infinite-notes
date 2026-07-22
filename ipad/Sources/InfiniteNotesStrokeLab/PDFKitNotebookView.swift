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
        viewer.applySettings(revision: model.settingsRevision)
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
    private var pageFrames: [CGRect] = []
    private var mountedPages: [Int: VectorPDFPageContainer] = [:]
    private var currentPageIndex = -1
    private var needsInitialFit = false
    private var lastViewportSize: CGSize = .zero
    private var lastSettingsRevision = -1
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

    func applySettings(revision: Int) {
        guard revision != lastSettingsRevision else { return }
        lastSettingsRevision = revision
        applyBackgroundStyle()
        maximumZoomScale = max(minimumZoomScale, CGFloat(model.appSettings.configuration.maximumZoom))
        let gapChanged = abs(appliedPageGap - pageGap) > 0.01
        appliedPageGap = pageGap
        for page in mountedPages.values { page.applyAppearance() }
        if gapChanged, let document = pdfDocument, let coreDocument, document.pageCount > 0, coreDocument.numberOfPages > 0 {
            let target = max(0, currentPageIndex)
            unmountAllPages()
            buildPageLayout(pageCount: min(document.pageCount, coreDocument.numberOfPages))
            goToPage(index: min(target, pageFrames.count - 1), animated: false)
        } else {
            mountWorkingSet(around: max(0, currentPageIndex))
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
        pageFrames.removeAll(keepingCapacity: false)
        currentPageIndex = -1

        guard let document, let coreDocument, document.pageCount > 0, coreDocument.numberOfPages > 0 else {
            documentView.frame = .zero
            contentSize = .zero
            model.setCurrentPage(index: -1)
            return
        }

        buildPageLayout(pageCount: min(document.pageCount, coreDocument.numberOfPages))
        currentPageIndex = 0
        model.setCurrentPage(index: 0)
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
        guard !pageFrames.isEmpty else { return }
        let base = currentPageIndex >= 0 ? currentPageIndex : 0
        goToPage(index: min(max(base + delta, 0), pageFrames.count - 1), animated: true)
    }

    func goToPage(index: Int, animated: Bool) {
        guard pageFrames.indices.contains(index) else { return }
        currentPageIndex = index
        model.setCurrentPage(index: index)
        mountWorkingSet(around: index)
        updateMountedInkScales(settle: true)

        let pageFrame = pageFrames[index]
        let targetY = pageFrame.minY * zoomScale - contentInset.top - 8
        let minY = -contentInset.top
        let maxY = max(minY, contentSize.height - bounds.height + contentInset.bottom)
        setContentOffset(
            CGPoint(x: contentOffset.x, y: min(max(targetY, minY), maxY)),
            animated: animated
        )
    }

    func fitCurrentPage(animated: Bool) {
        guard pageFrames.indices.contains(max(0, currentPageIndex)), bounds.width > 0, bounds.height > 0 else { return }
        let index = max(0, currentPageIndex)
        let page = pageFrames[index]
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

        let maximumWidth = max(1, pageSizes.map(\.width).max() ?? 612)
        var y = verticalMargin
        pageFrames = pageSizes.map { size in
            let x = horizontalMargin + (maximumWidth - size.width) / 2
            let frame = CGRect(x: x, y: y, width: max(1, size.width), height: max(1, size.height))
            y = frame.maxY + pageGap
            return frame
        }

        let width = maximumWidth + horizontalMargin * 2
        let height = max(1, y - pageGap + verticalMargin)
        documentView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        contentSize = documentView.bounds.size
        updateZoomLimits()
        mountWorkingSet(around: 0)
    }

    private func updateZoomLimits() {
        guard documentView.bounds.width > 0, bounds.width > 0 else {
            minimumZoomScale = 0.1
            return
        }
        let widthFit = max(0.05, (bounds.width - 24) / documentView.bounds.width)
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

    private func updateWorkingSet() {
        guard !pageFrames.isEmpty, zoomScale > 0 else { return }
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
        var high = pageFrames.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let frame = pageFrames[mid]
            if y < frame.minY {
                high = mid - 1
            } else if y > frame.maxY {
                low = mid + 1
            } else {
                return mid
            }
        }
        if low >= pageFrames.count { return pageFrames.count - 1 }
        if high < 0 { return 0 }
        let lowDistance = abs(pageFrames[low].midY - y)
        let highDistance = abs(pageFrames[high].midY - y)
        return lowDistance < highDistance ? low : high
    }

    private func mountWorkingSet(around current: Int) {
        guard !pageFrames.isEmpty else { return }
        let lower = max(0, current - workingRadius)
        let upper = min(pageFrames.count - 1, current + workingRadius)
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
                model: model
            )
            page.frame = pageFrames[index]
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
    private let pdfBackground: TiledPDFPageView
    private let inkOverlay: InkPageView
    private weak var model: AppModel?

    init(pageIndex: Int, pdfPage: CGPDFPage, model: AppModel) {
        self.model = model
        pdfBackground = TiledPDFPageView(page: pdfPage)
        inkOverlay = InkPageView(pageIndex: pageIndex, model: model)
        super.init(frame: .zero)

        backgroundColor = .white
        layer.borderColor = UIColor.separator.cgColor
        layer.borderWidth = 0.5
        addSubview(pdfBackground)
        addSubview(inkOverlay)
        applyAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyAppearance() {
        let showShadow = model?.appSettings.configuration.showPageShadow ?? true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = showShadow ? 0.16 : 0
        layer.shadowRadius = showShadow ? 3 : 0
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pdfBackground.frame = bounds
        inkOverlay.frame = bounds
        inkOverlay.settleDisplayScale()
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
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
