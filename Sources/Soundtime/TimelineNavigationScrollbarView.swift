import AppKit
import Metal

final class TimelineNavigationScrollbarView: TimelineMetalLayerView {
    private struct ScrollbarVertex {
        let position: SIMD2<Float>
    }

    private struct ScrollbarUniforms {
        let geometry: SIMD4<Float>
        let metrics: SIMD4<Float>
    }

    private struct RendererResources: @unchecked Sendable {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        let pipelineState: MTLRenderPipelineState
    }

    var onValueChanged: ((Float) -> Void)?
    var onEditingEnded: (() -> Void)?

    let axis: TimelineScrollbarAxis

    private var value: Float = 0
    private var visibleFraction: Float = 1
    private var hoverAmount: Float = 0
    private var hoverSource: Float = 0
    private var hoverTarget: Float = 0
    private var hoverStartTime = CACurrentMediaTime()
    private let hoverDuration: CFTimeInterval = 0.06
    private var hoverTimer: Timer?
    private var trackingArea: NSTrackingArea?
    private var dragOffset: CGFloat?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var rendererInitializationID = UUID()
    private var isRendererInitializationScheduled = false
    private let vertices: [ScrollbarVertex] = [
        ScrollbarVertex(position: SIMD2<Float>(0, 0)),
        ScrollbarVertex(position: SIMD2<Float>(1, 0)),
        ScrollbarVertex(position: SIMD2<Float>(0, 1)),
        ScrollbarVertex(position: SIMD2<Float>(1, 0)),
        ScrollbarVertex(position: SIMD2<Float>(1, 1)),
        ScrollbarVertex(position: SIMD2<Float>(0, 1)),
    ]

    init(axis: TimelineScrollbarAxis) {
        self.axis = axis
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        axis = .horizontal
        super.init(coder: coder)
        configure()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    func display(value: Float, visibleFraction: Float) {
        let nextValue = min(max(value, 0), 1)
        let nextVisibleFraction = min(max(visibleFraction, 0), 1)
        guard self.value != nextValue || self.visibleFraction != nextVisibleFraction else {
            return
        }
        self.value = nextValue
        self.visibleFraction = nextVisibleFraction
        window?.invalidateCursorRects(for: self)
        render()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) * 0.5
        layer?.masksToBounds = true
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        trackingArea = nextTrackingArea
        addTrackingArea(nextTrackingArea)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isScrollable else {
            return
        }
        addCursorRect(handleRect.insetBy(dx: -3, dy: -3), cursor: dragOffset == nil ? .openHand : .closedHand)
    }

    override func mouseEntered(with event: NSEvent) {
        transitionHover(to: 1)
    }

    override func mouseExited(with event: NSEvent) {
        guard dragOffset == nil else {
            return
        }
        transitionHover(to: 0)
    }

    override func mouseDown(with event: NSEvent) {
        guard isScrollable else {
            return
        }
        window?.makeFirstResponder(self)
        let primary = primaryPosition(for: convert(event.locationInWindow, from: nil))
        let start = handleStart
        let length = handleLength
        if primary >= start, primary <= start + length {
            dragOffset = primary - start
        } else {
            dragOffset = length * 0.5
            updateValue(primaryPosition: primary)
        }
        transitionHover(to: 1)
        NSCursor.closedHand.set()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragOffset != nil else {
            return
        }
        updateValue(primaryPosition: primaryPosition(for: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOffset != nil else {
            return
        }
        updateValue(primaryPosition: primaryPosition(for: convert(event.locationInWindow, from: nil)))
        dragOffset = nil
        onEditingEnded?()
        let localPoint = convert(event.locationInWindow, from: nil)
        transitionHover(to: bounds.contains(localPoint) ? 1 : 0)
        NSCursor.openHand.set()
        window?.invalidateCursorRects(for: self)
    }

    override func cancelOperation(_ sender: Any?) {
        guard dragOffset != nil else {
            return
        }
        dragOffset = nil
        onEditingEnded?()
        transitionHover(to: 0)
        NSCursor.arrow.set()
        window?.invalidateCursorRects(for: self)
    }

    private var isScrollable: Bool {
        visibleFraction < 0.999
    }

    private var handleLength: CGFloat {
        let dimension = primaryDimension
        guard dimension > 0 else {
            return 1
        }
        let minimumLength = min(max(30 / dimension, 0), 1)
        return min(max(CGFloat(visibleFraction), minimumLength), 1)
    }

    private var handleStart: CGFloat {
        CGFloat(value) * max(1 - handleLength, 0)
    }

    private var primaryDimension: CGFloat {
        axis == .horizontal ? bounds.width : bounds.height
    }

    private var handleRect: CGRect {
        let start = handleStart
        let length = handleLength
        if axis == .horizontal {
            return CGRect(
                x: start * bounds.width,
                y: 0,
                width: length * bounds.width,
                height: bounds.height
            )
        }
        return CGRect(
            x: 0,
            y: bounds.height - (start + length) * bounds.height,
            width: bounds.width,
            height: length * bounds.height
        )
    }

    private func primaryPosition(for point: CGPoint) -> CGFloat {
        if axis == .horizontal {
            return min(max(point.x / max(bounds.width, 1), 0), 1)
        }
        return min(max((bounds.height - point.y) / max(bounds.height, 1), 0), 1)
    }

    private func updateValue(primaryPosition: CGFloat) {
        guard let dragOffset else {
            return
        }
        let travel = max(1 - handleLength, 0.000_001)
        let nextValue = Float(min(max((primaryPosition - dragOffset) / travel, 0), 1))
        guard value != nextValue else {
            return
        }
        value = nextValue
        onValueChanged?(nextValue)
        render()
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.045, green: 0.047, blue: 0.048, alpha: 1)
        scheduleRendererInitializationIfNeeded()
    }

    private func transitionHover(to target: Float) {
        let now = CACurrentMediaTime()
        hoverAmount = currentHoverAmount(at: now)
        hoverSource = hoverAmount
        hoverTarget = min(max(target, 0), 1)
        hoverStartTime = now
        hoverTimer?.invalidate()
        guard abs(hoverTarget - hoverAmount) > 0.001 else {
            hoverAmount = hoverTarget
            render()
            return
        }
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceHoverTransition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func currentHoverAmount(at timestamp: CFTimeInterval) -> Float {
        let progress = Float(min(max((timestamp - hoverStartTime) / hoverDuration, 0), 1))
        let eased = progress < 0.5 ?
            4 * progress * progress * progress :
            1 - pow(-2 * progress + 2, 3) * 0.5
        return hoverSource + (hoverTarget - hoverSource) * eased
    }

    private func advanceHoverTransition() {
        hoverAmount = currentHoverAmount(at: CACurrentMediaTime())
        render()
        if abs(hoverAmount - hoverTarget) < 0.001 {
            hoverAmount = hoverTarget
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    private func scheduleRendererInitializationIfNeeded() {
        guard pipelineState == nil, !isRendererInitializationScheduled else {
            return
        }
        isRendererInitializationScheduled = true
        let initializationID = UUID()
        rendererInitializationID = initializationID
        MetalRendererInitialization.auxiliaryQueue.async {
            let result = Result {
                guard let device = MTLCreateSystemDefaultDevice() else {
                    throw NSError(
                        domain: "Soundtime.TimelineNavigationScrollbarView",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Metal device unavailable"]
                    )
                }
                return try Self.makeRendererResources(device: device)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.rendererInitializationID == initializationID else {
                    return
                }
                self.isRendererInitializationScheduled = false
                switch result {
                case let .success(resources):
                    self.installMetalDevice(resources.device)
                    self.commandQueue = resources.commandQueue
                    self.pipelineState = resources.pipelineState
                    self.render()
                case let .failure(error):
                    Swift.print("Soundtime could not create timeline scrollbar renderer: \(error)")
                }
            }
        }
    }

    nonisolated private static func makeRendererResources(device: MTLDevice) throws -> RendererResources {
        guard let commandQueue = device.makeCommandQueue() else {
            throw NSError(
                domain: "Soundtime.TimelineNavigationScrollbarView",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Metal command queue unavailable"]
            )
        }
        let library = try BundledMetalLibrary.load(
            named: "TimelineNavigationScrollbarShaders",
            device: device,
            developmentSource: shaderSource
        )
        guard
            let vertexFunction = library.makeFunction(name: "timeline_navigation_scrollbar_vertex"),
            let fragmentFunction = library.makeFunction(name: "timeline_navigation_scrollbar_fragment")
        else {
            throw NSError(
                domain: "Soundtime.TimelineNavigationScrollbarView",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Timeline scrollbar shader functions unavailable"]
            )
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return RendererResources(
            device: device,
            commandQueue: commandQueue,
            pipelineState: try device.makeRenderPipelineState(descriptor: descriptor)
        )
    }

    private func render() {
        guard
            let renderTarget = makeTimelineRenderTarget(),
            let commandQueue,
            let pipelineState,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderTarget.renderPassDescriptor)
        else {
            return
        }

        var uniforms = ScrollbarUniforms(
            geometry: SIMD4<Float>(
                Float(handleStart),
                Float(handleLength),
                hoverAmount,
                axis == .horizontal ? 0 : 1
            ),
            metrics: SIMD4<Float>(
                Float(renderTarget.viewportSize.width),
                Float(renderTarget.viewportSize.height),
                isScrollable ? 1 : 0,
                0
            )
        )
        encoder.setRenderPipelineState(pipelineState)
        vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            encoder.setVertexBytes(baseAddress, length: bytes.count, index: 0)
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ScrollbarUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        commandBuffer.present(renderTarget.drawable)
        commandBuffer.commit()
    }

    nonisolated private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct ScrollbarVertex { float2 position; };
    struct RasterizedVertex {
        float4 position [[position]];
        float2 uv;
    };
    struct ScrollbarUniforms {
        float4 geometry;
        float4 metrics;
    };

    vertex RasterizedVertex timeline_navigation_scrollbar_vertex(
        uint vertexID [[vertex_id]],
        constant ScrollbarVertex *vertices [[buffer(0)]]
    ) {
        float2 position = vertices[vertexID].position;
        RasterizedVertex out;
        out.position = float4(position.x * 2.0 - 1.0, position.y * 2.0 - 1.0, 0.0, 1.0);
        out.uv = position;
        return out;
    }

    static float rounded_rect_alpha(float2 point, float2 center, float2 halfSize, float radius) {
        float2 q = abs(point - center) - halfSize + radius;
        float distance = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
        float aa = max(fwidth(distance), 0.75);
        return 1.0 - smoothstep(0.0, aa, distance);
    }

    fragment float4 timeline_navigation_scrollbar_fragment(
        RasterizedVertex in [[stage_in]],
        constant ScrollbarUniforms &uniforms [[buffer(0)]]
    ) {
        float2 uv = in.uv;
        bool vertical = uniforms.geometry.w > 0.5;
        float primary = vertical ? 1.0 - uv.y : uv.x;
        float cross = vertical ? uv.x : uv.y;
        float handleStart = uniforms.geometry.x;
        float handleLength = uniforms.geometry.y;
        float hover = clamp(uniforms.geometry.z, 0.0, 1.0);
        float enabled = clamp(uniforms.metrics.z, 0.0, 1.0);
        float primarySize = vertical ? uniforms.metrics.y : uniforms.metrics.x;
        float crossSize = vertical ? uniforms.metrics.x : uniforms.metrics.y;
        float2 scrollbarPoint = float2(primary * primarySize, cross * crossSize);
        float crossCenter = crossSize * 0.5;

        float containerRadius = min(primarySize, crossSize) * 0.5;
        float container = rounded_rect_alpha(
            scrollbarPoint,
            float2(primarySize * 0.5, crossCenter),
            float2(primarySize * 0.5, crossCenter),
            containerRadius
        );
        float railCrossHalf = max(crossSize * 0.24, 1.0);
        float rail = rounded_rect_alpha(
            scrollbarPoint,
            float2(primarySize * 0.5, crossCenter),
            float2(max(primarySize * 0.5 - 2.0, railCrossHalf), railCrossHalf),
            railCrossHalf
        );
        float handleCrossHalf = max(crossSize * 0.31, 1.0);
        float handlePrimaryHalf = max(handleLength * primarySize * 0.5 - 1.0, handleCrossHalf);
        float handle = rounded_rect_alpha(
            scrollbarPoint,
            float2((handleStart + handleLength * 0.5) * primarySize, crossCenter),
            float2(handlePrimaryHalf, handleCrossHalf),
            handleCrossHalf
        );

        float3 color = float3(0.045, 0.047, 0.048);
        color = mix(color, float3(0.095, 0.105, 0.108), rail * 0.72);
        float3 neutral = float3(0.58, 0.61, 0.62);
        float3 teal = float3(0.23, 0.53, 0.55);
        float3 handleColor = mix(neutral, teal, hover);
        float stripe = 0.5 + 0.5 * sin(primary * 96.0 + cross * 7.0);
        float centerGlow = exp(-pow((cross - 0.42) / 0.23, 2.0));
        handleColor *= 0.82 + stripe * 0.07 + centerGlow * 0.13;
        handleColor += float3(0.10, 0.13, 0.13) * centerGlow * (0.35 + hover * 0.35);
        color = mix(color, handleColor, handle * mix(0.56, 0.92, enabled));
        color += float3(0.09, 0.11, 0.11) * container * (1.0 - rail) * 0.18;
        return float4(color, 1.0);
    }
    """
}
