import QuartzCore
import SwiftUI
import UIKit

struct PipelineDiagnosticsSidebar: View {
    @ObservedObject var strokeSettings: StrokeSettingsStore
    @ObservedObject var appSettings: AppSettingsStore
    @State private var clearToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            PipelineDiagnosticsCanvas(
                configuration: strokeSettings.configuration,
                clearToken: clearToken
            )
            .frame(height: 245)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.32), lineWidth: 1)
            }
            .padding(12)

            HStack {
                Label("Local test pad", systemImage: "ipad.and.iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { clearToken = UUID() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(
                        "Only active notebook stroke",
                        isOn: $strokeSettings.configuration.debugLiveStrokeOnly
                    )

                    diagnosticGroup(
                        title: "Raw Pencil samples",
                        color: .red,
                        points: $strokeSettings.configuration.showRawPoints,
                        connections: $strokeSettings.configuration.showRawConnections,
                        diameter: rawDiameterBinding
                    )

                    diagnosticGroup(
                        title: "Filtered samples",
                        color: .orange,
                        points: $strokeSettings.configuration.showFilteredPoints,
                        connections: $strokeSettings.configuration.showFilteredConnections,
                        diameter: filteredDiameterBinding
                    )

                    diagnosticGroup(
                        title: "Computed spline",
                        color: .blue,
                        points: $strokeSettings.configuration.showComputedPoints,
                        connections: $strokeSettings.configuration.showComputedConnections,
                        diameter: computedDiameterBinding
                    )

                    Toggle(
                        "Computed centreline — purple",
                        isOn: $strokeSettings.configuration.showComputedCenterline
                    )

                    Text("The pad uses the same filtering and spline pipeline as notebook ink. Test strokes stay local and are never sent to the server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
        .frame(width: 380)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        }
        .shadow(radius: 12, x: -3, y: 3)
        .padding(10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
            VStack(alignment: .leading, spacing: 1) {
                Text("Pipeline visualization")
                    .font(.headline)
                Text("Draw below, then toggle overlays")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                appSettings.configuration.showPipelineDiagnosticsSidebar = false
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Close pipeline visualization")
        }
        .padding(12)
    }

    @ViewBuilder
    private func diagnosticGroup(
        title: String,
        color: Color,
        points: Binding<Bool>,
        connections: Binding<Bool>,
        diameter: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(title).font(.subheadline.weight(.semibold))
            }
            Toggle("Points", isOn: points)
            Toggle("Connections", isOn: connections)
            HStack {
                Text("Point diameter")
                Spacer()
                Text("\(diameter.wrappedValue, specifier: "%.1f") pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: diameter, in: 0.1...12, step: 0.1)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var rawDiameterBinding: Binding<Double> {
        Binding(
            get: { strokeSettings.configuration.resolvedRawPointDiameter },
            set: { strokeSettings.configuration.rawPointDiameter = $0 }
        )
    }

    private var filteredDiameterBinding: Binding<Double> {
        Binding(
            get: { strokeSettings.configuration.resolvedFilteredPointDiameter },
            set: { strokeSettings.configuration.filteredPointDiameter = $0 }
        )
    }

    private var computedDiameterBinding: Binding<Double> {
        Binding(
            get: { strokeSettings.configuration.resolvedComputedPointDiameter },
            set: { strokeSettings.configuration.computedPointDiameter = $0 }
        )
    }
}

private struct PipelineDiagnosticsCanvas: UIViewRepresentable {
    var configuration: StrokePipelineConfiguration
    var clearToken: UUID

    func makeUIView(context: Context) -> PipelineDiagnosticsPadView {
        let view = PipelineDiagnosticsPadView(frame: .zero)
        view.configuration = configuration
        view.clearToken = clearToken
        return view
    }

    func updateUIView(_ view: PipelineDiagnosticsPadView, context: Context) {
        view.configuration = configuration
        view.clearToken = clearToken
    }
}

@MainActor
private final class PipelineDiagnosticsPadView: UIView {
    var configuration = StrokePipelineConfiguration.default {
        didSet {
            guard oldValue != configuration else { return }
            rebuildLayers()
        }
    }

    var clearToken = UUID() {
        didSet {
            guard oldValue != clearToken else { return }
            clear()
        }
    }

    private let vectorHost = CALayer()
    private var renderedLayers: [CALayer] = []
    private var completedStrokes: [NoteStroke] = []
    private var activeStroke: NoteStroke?
    private var pipelineState = StrokePipelineState()
    private weak var activeTouch: UITouch?
    private var sequence = 0
    private var lastBoundsSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isMultipleTouchEnabled = false
        backgroundColor = .secondarySystemBackground
        layer.addSublayer(vectorHost)

        let grid = CAShapeLayer()
        grid.name = "diagnostic-grid"
        grid.strokeColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        grid.lineWidth = 0.5
        vectorHost.addSublayer(grid)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        vectorHost.frame = bounds
        guard bounds.size != lastBoundsSize else { return }
        lastBoundsSize = bounds.size
        rebuildLayers()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = preferredTouch(from: touches) else { return }
        activeTouch = touch
        pipelineState.reset()
        sequence += 1
        activeStroke = makeStroke(id: "diagnostic-\(sequence)")
        appendSamples(for: touch, event: event, forceAcceptFirst: true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        appendSamples(for: activeTouch, event: event, forceAcceptFirst: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        appendSamples(for: activeTouch, event: event, forceAcceptFirst: true)
        finishStroke()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        finishStroke()
    }

    private func preferredTouch(from touches: Set<UITouch>) -> UITouch? {
        touches.first(where: { $0.type == .pencil }) ?? touches.first(where: { $0.type == .direct })
    }

    private func appendSamples(for touch: UITouch, event: UIEvent?, forceAcceptFirst: Bool) {
        let coalesced = configuration.useCoalescedTouches
            ? (event?.coalescedTouches(for: touch) ?? [touch])
            : [touch]
        var force = forceAcceptFirst
        for sampleTouch in coalesced {
            append(sampleTouch, forceAccept: force)
            force = false
        }
        rebuildLayers()
    }

    private func append(_ touch: UITouch, forceAccept: Bool) {
        guard var stroke = activeStroke, bounds.width > 0, bounds.height > 0 else { return }
        let viewPoint = touch.location(in: self)
        let maximumForce = touch.maximumPossibleForce
        let pressure = maximumForce > 0
            ? max(0, min(1, Double(touch.force / maximumForce)))
            : 0.5
        let sample = PencilInputSample(
            viewPoint: viewPoint,
            rawWorldPoint: viewPoint,
            rawPagePoint: viewPoint,
            pressure: pressure,
            timestampMS: touch.timestamp * 1000,
            altitude: touch.type == .pencil ? Double(touch.altitudeAngle) : nil,
            azimuth: touch.type == .pencil ? Double(touch.azimuthAngle(in: self)) : nil
        )
        guard let point = pipelineState.process(
            sample,
            page: diagnosticPage,
            viewBounds: bounds,
            configuration: configuration,
            forceAccept: forceAccept
        ) else { return }
        stroke.points.append(point)
        activeStroke = stroke
    }

    private func finishStroke() {
        if let activeStroke, !activeStroke.points.isEmpty {
            completedStrokes.append(activeStroke)
            if completedStrokes.count > 24 {
                completedStrokes.removeFirst(completedStrokes.count - 24)
            }
        }
        activeStroke = nil
        activeTouch = nil
        pipelineState.reset()
        rebuildLayers()
    }

    private func clear() {
        completedStrokes.removeAll(keepingCapacity: false)
        activeStroke = nil
        activeTouch = nil
        pipelineState.reset()
        rebuildLayers()
    }

    private var diagnosticPage: PageInfo {
        PageInfo(
            id: "pipeline-diagnostics",
            pageNumber: 1,
            imageUrl: nil,
            x: 0,
            y: 0,
            width: Double(max(1, bounds.width)),
            height: Double(max(1, bounds.height))
        )
    }

    private func makeStroke(id: String) -> NoteStroke {
        NoteStroke(
            id: id,
            tool: "pen",
            color: "#111111",
            width: 2.0,
            opacity: 1,
            smoothing: max(0, min(100, configuration.smoothingStrength * 100)),
            strokeDetail: 100,
            lineStyle: "solid",
            points: [],
            owner: "pipeline-diagnostics",
            locked: false,
            pageIndex: 0,
            pipeline: StrokePipelineSnapshot(configuration: configuration),
            shapeType: nil,
            gridColor: nil,
            recognitionSource: nil,
            recognitionError: nil,
            snapKind: nil,
            text: nil,
            textAlign: nil,
            fontFamily: nil
        )
    }

    private func rebuildLayers() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        renderedLayers.forEach { $0.removeFromSuperlayer() }
        renderedLayers.removeAll(keepingCapacity: true)
        vectorHost.sublayers?.filter { $0.name == "diagnostic-grid" }.forEach { $0.removeFromSuperlayer() }
        addGridLayer()

        var localConfiguration = configuration
        localConfiguration.debugLiveStrokeOnly = false
        let strokes = completedStrokes + (activeStroke.map { [$0] } ?? [])
        for stroke in strokes {
            let descriptors = StrokeRenderer.vectorLayerDescriptors(
                stroke: stroke,
                page: diagnosticPage,
                viewBounds: bounds,
                configuration: localConfiguration,
                includeDiagnostics: true
            )
            for descriptor in descriptors {
                let layer = CAShapeLayer()
                layer.frame = bounds
                layer.contentsScale = UIScreen.main.scale
                layer.shouldRasterize = false
                layer.path = descriptor.path
                layer.fillColor = descriptor.fillColor
                layer.strokeColor = descriptor.strokeColor
                layer.lineWidth = descriptor.lineWidth
                layer.lineDashPattern = descriptor.lineDashPattern
                layer.lineCap = descriptor.lineCap
                layer.lineJoin = descriptor.lineJoin
                vectorHost.addSublayer(layer)
                renderedLayers.append(layer)
            }
        }
    }

    private func addGridLayer() {
        let grid = CAShapeLayer()
        grid.name = "diagnostic-grid"
        grid.frame = bounds
        grid.contentsScale = UIScreen.main.scale
        grid.strokeColor = UIColor.separator.withAlphaComponent(0.28).cgColor
        grid.lineWidth = 0.5
        let path = CGMutablePath()
        let spacing: CGFloat = 20
        var x: CGFloat = spacing
        while x < bounds.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: bounds.height))
            x += spacing
        }
        var y: CGFloat = spacing
        while y < bounds.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: bounds.width, y: y))
            y += spacing
        }
        grid.path = path
        vectorHost.addSublayer(grid)
    }
}
