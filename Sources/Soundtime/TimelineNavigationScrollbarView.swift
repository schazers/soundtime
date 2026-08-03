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
    private var visibilityAmount: Float = 0
    private var visibilitySource: Float = 0
    private var visibilityTarget: Float = 0
    private var visibilityStartTime = CACurrentMediaTime()
    private var visibilityDuration: CFTimeInterval = 0
    private var visibilityDismissTimer: Timer?
    private var isPointerInside = false
    private var trackingArea: NSTrackingArea?
    private var dragOffset: CGFloat?
    private var dragDisplayLink: TimelineDisplayLink?
    private var hasPendingRender = false
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

    func display(
        value: Float,
        visibleFraction: Float
    ) {
        let nextValue = min(max(value, 0), 1)
        let nextVisibleFraction = min(max(visibleFraction, 0), 1)
        guard self.value != nextValue ||
            self.visibleFraction != nextVisibleFraction
        else {
            return
        }
        self.value = nextValue
        self.visibleFraction = nextVisibleFraction
        if !isScrollable {
            hideImmediately()
        }
        requestRender()
    }

    func noteScrollActivity() {
        guard isScrollable else {
            return
        }
        showScrollbar()
        scheduleVisibilityDismissal()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) * 0.5
        layer?.masksToBounds = true
        requestRender()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hoverTimer?.invalidate()
            hoverTimer = nil
            visibilityDismissTimer?.invalidate()
            visibilityDismissTimer = nil
            abandonDragSession()
            visibilityAmount = 0
            visibilityTarget = 0
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isScrollable, bounds.contains(point) else {
            return nil
        }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isScrollable else {
            return
        }
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        showScrollbar()
        transitionHover(to: 1)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        guard dragOffset == nil else {
            return
        }
        transitionHover(to: 0)
        scheduleVisibilityDismissal()
    }

    override func mouseDown(with event: NSEvent) {
        guard isScrollable else {
            return
        }
        abandonDragSession()
        showScrollbar()
        window?.makeFirstResponder(self)
        let primary = primaryPosition(for: convert(event.locationInWindow, from: nil))
        let start = baseHandleStart
        let length = baseHandleLength
        if primary >= start, primary <= start + length {
            dragOffset = primary - start
        } else {
            dragOffset = length * 0.5
            updateValue(primaryPosition: primary)
        }
        startDragDisplayLink()
        transitionHover(to: 1)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragOffset != nil else {
            return
        }
        // Event delivery is the authoritative input path. Display-link sampling fills
        // the gaps between uneven AppKit drag events, but never owns the drag itself.
        updateValue(primaryPosition: primaryPosition(for: convert(event.locationInWindow, from: nil)))
        startDragDisplayLink()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOffset != nil else {
            return
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        updateValue(primaryPosition: primaryPosition(for: localPoint))
        finishDragSession(pointerIsInside: bounds.contains(localPoint), notifiesEditingEnded: true)
    }

    override func cancelOperation(_ sender: Any?) {
        guard dragOffset != nil else {
            return
        }
        finishDragSession(pointerIsInside: false, notifiesEditingEnded: true)
    }

    private var isScrollable: Bool {
        visibleFraction < 0.999
    }

    private var baseHandleLength: CGFloat {
        let dimension = primaryDimension
        guard dimension > 0 else {
            return 1
        }
        let minimumLength = min(max(30 / dimension, 0), 1)
        return min(max(CGFloat(visibleFraction), minimumLength), 1)
    }

    private var baseHandleStart: CGFloat {
        CGFloat(value) * max(1 - baseHandleLength, 0)
    }

    private var handleLength: CGFloat {
        baseHandleLength
    }

    private var handleStart: CGFloat {
        baseHandleStart
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
            return point.x / max(bounds.width, 1)
        }
        return (bounds.height - point.y) / max(bounds.height, 1)
    }

    private func updateValue(primaryPosition: CGFloat) {
        guard let dragOffset else {
            return
        }
        let nextValue = TimelineNavigationScrollbarDragGeometry.normalizedValue(
            primaryPosition: primaryPosition,
            dragOffset: dragOffset,
            handleLength: baseHandleLength
        )
        if value != nextValue {
            value = nextValue
            onValueChanged?(nextValue)
        }
        showScrollbar()
        requestRender()
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        preferredFramesPerSecond = TimelineNavigationScrollbarDragGeometry.interactionFramesPerSecond
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        timelineMetalLayer?.isOpaque = false
        alphaValue = 1
        scheduleRendererInitializationIfNeeded()
    }

    private func showScrollbar() {
        visibilityDismissTimer?.invalidate()
        visibilityDismissTimer = nil
        transitionVisibility(
            to: 1,
            duration: TimelineNavigationScrollbarVisibilityTiming.fadeInDuration
        )
    }

    private func scheduleVisibilityDismissal() {
        visibilityDismissTimer?.invalidate()
        visibilityDismissTimer = nil
        guard dragOffset == nil, !isPointerInside else {
            return
        }
        let timer = Timer(timeInterval: TimelineNavigationScrollbarVisibilityTiming.lingerDuration, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.fadeOutIfIdle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        visibilityDismissTimer = timer
    }

    private func fadeOutIfIdle() {
        visibilityDismissTimer?.invalidate()
        visibilityDismissTimer = nil
        guard dragOffset == nil, !isPointerInside else {
            return
        }
        transitionVisibility(
            to: 0,
            duration: TimelineNavigationScrollbarVisibilityTiming.fadeOutDuration
        )
    }

    private func hideImmediately() {
        visibilityDismissTimer?.invalidate()
        visibilityDismissTimer = nil
        visibilityAmount = 0
        visibilitySource = 0
        visibilityTarget = 0
        visibilityDuration = 0
        requestRender()
    }

    private var isVisibilityTransitionActive: Bool {
        abs(visibilityAmount - visibilityTarget) > 0.001
    }

    private func transitionVisibility(to target: Float, duration: CFTimeInterval) {
        let clampedTarget = min(max(target, 0), 1)
        guard clampedTarget != visibilityTarget else {
            requestRender()
            return
        }
        let now = CACurrentMediaTime()
        visibilityAmount = currentVisibilityAmount(at: now)
        visibilitySource = visibilityAmount
        visibilityTarget = clampedTarget
        visibilityStartTime = now
        visibilityDuration = duration * CFTimeInterval(abs(visibilityTarget - visibilitySource))
        requestRender()
    }

    private func currentVisibilityAmount(at timestamp: CFTimeInterval) -> Float {
        guard visibilityDuration > 0 else {
            return visibilityTarget
        }
        let progress = Float(min(max((timestamp - visibilityStartTime) / visibilityDuration, 0), 1))
        let eased = progress * progress * (3 - 2 * progress)
        return visibilitySource + (visibilityTarget - visibilitySource) * eased
    }

    private func advanceVisibilityTransition() {
        visibilityAmount = currentVisibilityAmount(at: CACurrentMediaTime())
        if abs(visibilityAmount - visibilityTarget) < 0.001 {
            visibilityAmount = visibilityTarget
        }
        requestRender()
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
            requestRender()
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
        requestRender()
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
                    self.requestRender()
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
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return RendererResources(
            device: device,
            commandQueue: commandQueue,
            pipelineState: try device.makeRenderPipelineState(descriptor: descriptor)
        )
    }

    private func requestRender() {
        hasPendingRender = true
        startDragDisplayLink()
    }

    private func startDragDisplayLink() {
        guard window != nil, let timelineMetalLayer else {
            return
        }
        if dragDisplayLink == nil {
            let displayLink = TimelineDisplayLink(
                metalLayer: timelineMetalLayer,
                preferredFramesPerSecond: TimelineNavigationScrollbarDragGeometry.interactionFramesPerSecond
            )
            displayLink.onFrame = { [weak self] frame in
                MainActor.assumeIsolated {
                    self?.dragDisplayLinkDidTick(frame)
                }
            }
            dragDisplayLink = displayLink
        }
        dragDisplayLink?.start()
    }

    private func stopDragDisplayLink() {
        dragDisplayLink?.invalidate()
        dragDisplayLink = nil
    }

    private func dragDisplayLinkDidTick(_ frame: TimelineDisplayLinkFrame) {
        if dragOffset != nil {
            guard TimelineNavigationScrollbarDragGeometry.shouldContinueDisplayPacedDrag(
                hasDragOffset: true,
                pressedMouseButtons: NSEvent.pressedMouseButtons
            ) else {
                finishDragSession(pointerIsInside: pointerIsInsideBounds(), notifiesEditingEnded: true)
                return
            }
            sampleActiveDragFromCurrentMouse()
        }

        if isVisibilityTransitionActive {
            advanceVisibilityTransition()
        }

        if hasPendingRender || dragOffset != nil || hoverTimer != nil || isVisibilityTransitionActive {
            hasPendingRender = false
            render(frame: frame)
        }
        if dragOffset == nil, hoverTimer == nil, !hasPendingRender, !isVisibilityTransitionActive {
            stopDragDisplayLink()
        }
    }

    private func finishDragSession(pointerIsInside: Bool, notifiesEditingEnded: Bool) {
        guard dragOffset != nil else {
            stopDragDisplayLink()
            return
        }
        dragOffset = nil
        requestRender()
        if notifiesEditingEnded {
            onEditingEnded?()
        }
        transitionHover(to: pointerIsInside ? 1 : 0)
        if !pointerIsInside {
            scheduleVisibilityDismissal()
        }
    }

    private func abandonDragSession() {
        dragOffset = nil
        hasPendingRender = false
        stopDragDisplayLink()
    }

    private func pointerIsInsideBounds() -> Bool {
        guard let window else {
            return false
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return bounds.contains(convert(windowPoint, from: nil))
    }

    private func sampleActiveDragFromCurrentMouse() {
        guard dragOffset != nil, let window else {
            return
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)
        updateValue(primaryPosition: primaryPosition(for: localPoint))
    }

    private func render(frame: TimelineDisplayLinkFrame? = nil) {
        let target = frame.flatMap(makeTimelineRenderTarget(frame:)) ?? makeTimelineRenderTarget()
        guard
            let renderTarget = target,
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
                isScrollable ? visibilityAmount : 0,
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

        float handleCrossHalf = max(crossSize * 0.31, 1.0);
        float handlePrimaryHalf = max(handleLength * primarySize * 0.5 - 1.0, handleCrossHalf);
        float handle = rounded_rect_alpha(
            scrollbarPoint,
            float2((handleStart + handleLength * 0.5) * primarySize, crossCenter),
            float2(handlePrimaryHalf, handleCrossHalf),
            handleCrossHalf
        );

        float3 neutral = float3(0.50, 0.51, 0.52);
        float3 hovered = float3(0.64, 0.65, 0.66);
        float3 handleColor = mix(neutral, hovered, hover);
        float stripe = 0.5 + 0.5 * sin(primary * 96.0 + cross * 7.0);
        float centerGlow = exp(-pow((cross - 0.42) / 0.23, 2.0));
        handleColor *= 0.90 + stripe * 0.025 + centerGlow * 0.075;
        float alpha = handle * enabled * mix(0.84, 0.95, hover);
        return float4(handleColor, alpha);
    }
    """
}
