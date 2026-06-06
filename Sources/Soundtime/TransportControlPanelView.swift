import AppKit
import Metal
import QuartzCore

final class TransportControlPanelView: TimelineMetalLayerView {
    enum TransportAction {
        case togglePlayback
    }

    var onAction: ((TransportAction) -> Void)?

    var isPlaying = false {
        didSet {
            guard oldValue != isPlaying else {
                return
            }
            previousIsPlaying = oldValue
            lastPlaybackStateChangeTime = CACurrentMediaTime()
            render()
        }
    }

    var isTransportEnabled = false {
        didSet {
            guard oldValue != isTransportEnabled else {
                return
            }
            render()
        }
    }

    private var renderer: TransportControlPanelRenderer?
    private var displayLink: TimelineDisplayLink?
    private var animationWatchdogTimer: Timer?
    private var lastDisplayLinkFrameTime = CACurrentMediaTime()
    private var trackingArea: NSTrackingArea?
    private var hoveredButtonIndex: Int?
    private var pressedButtonIndex: Int?
    private var hoveredPoint: CGPoint?
    private var pressedPoint: CGPoint?
    private var lastPressTime = CACurrentMediaTime() - 10
    private var lastPlaybackStateChangeTime = CACurrentMediaTime()
    private var previousIsPlaying = false
    private var outputActivity: Float = 0

    override var acceptsFirstResponder: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.isOpaque = false
        (layer as? CAMetalLayer)?.isOpaque = false
        return layer
    }

    override init(frame frameRect: NSRect = .zero, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        super.init(frame: frameRect, device: device)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else {
            startDisplayLink()
            render()
        }
    }

    override func layout() {
        super.layout()
        render()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        trackingArea = nextTrackingArea
        addTrackingArea(nextTrackingArea)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isTransportEnabled ? .pointingHand : .arrow)
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredButtonIndex = nil
        pressedButtonIndex = nil
        hoveredPoint = nil
        pressedPoint = nil
        render()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard isTransportEnabled else {
            return
        }

        pressedButtonIndex = buttonIndex(at: convert(event.locationInWindow, from: nil))
        pressedPoint = convert(event.locationInWindow, from: nil)
        lastPressTime = CACurrentMediaTime()
        render()
    }

    override func mouseDragged(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTransportEnabled else {
            pressedButtonIndex = nil
            render()
            return
        }

        let releasedButtonIndex = buttonIndex(at: convert(event.locationInWindow, from: nil))
        let action = pressedButtonIndex == releasedButtonIndex ? action(for: releasedButtonIndex) : nil
        pressedButtonIndex = nil
        render()
        if let action {
            onAction?(action)
        }
    }

    func refresh() {
        render()
    }

    func displayOutputActivity(levels: LoudnessMeterLevels) {
        let peak = max(levels.leftPeak, levels.rightPeak)
        let rms = max(levels.leftRMS, levels.rightRMS)
        let targetActivity = min(max(peak * 0.70 + rms * 1.15, 0), 1)
        outputActivity += (targetActivity - outputActivity) * 0.28
        render()
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        timelineMetalLayer?.isOpaque = false
        preferredFramesPerSecond = 144
        guard let metalDevice else {
            return
        }

        do {
            renderer = try TransportControlPanelRenderer(device: metalDevice, pixelFormat: colorPixelFormat)
        } catch {
            Swift.print("Soundtime could not create the transport control renderer: \(error)")
        }
    }

    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let nextHover = buttonIndex(at: point)
        hoveredPoint = nextHover == nil ? nil : point
        guard hoveredButtonIndex != nextHover else {
            return
        }

        hoveredButtonIndex = nextHover
        render()
    }

    private func startDisplayLink() {
        startAnimationWatchdogTimer()

        if displayLink == nil, let timelineMetalLayer {
            let displayLink = TimelineDisplayLink(
                metalLayer: timelineMetalLayer,
                preferredFramesPerSecond: preferredFramesPerSecond
            )
            displayLink.onFrame = { [weak self] frame in
                MainActor.assumeIsolated {
                    self?.displayLinkDidTick(frame)
                }
            }
            self.displayLink = displayLink
        }

        displayLink?.start()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        animationWatchdogTimer?.invalidate()
        animationWatchdogTimer = nil
    }

    private func displayLinkDidTick(_ frame: TimelineDisplayLinkFrame) {
        lastDisplayLinkFrameTime = CACurrentMediaTime()
        guard
            let renderer,
            let renderTarget = makeTimelineRenderTarget(frame: frame)
        else {
            return
        }

        renderer.render(
            target: renderTarget,
            state: transportRenderState()
        )
    }

    private func startAnimationWatchdogTimer() {
        guard animationWatchdogTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }

            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                guard displayLink == nil || now - lastDisplayLinkFrameTime > 0.05 else {
                    return
                }

                render(force: true)
            }
        }
        timer.tolerance = 1 / 240
        RunLoop.main.add(timer, forMode: .common)
        animationWatchdogTimer = timer
    }

    private func action(for buttonIndex: Int?) -> TransportAction? {
        guard let buttonIndex else {
            return nil
        }

        switch buttonIndex {
        case 0:
            return .togglePlayback
        default:
            return nil
        }
    }

    private func buttonIndex(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else {
            return nil
        }

        let layout = buttonLayout()
        for index in layout.indices where layout[index].contains(point) {
            return index
        }
        return nil
    }

    private func buttonLayout() -> [NSRect] {
        let buttonSize: CGFloat = 34
        let y = bounds.midY - buttonSize * 0.5
        return [
            NSRect(
                x: bounds.midX - buttonSize * 0.5,
                y: y,
                width: buttonSize,
                height: buttonSize
            )
        ]
    }

    private func render() {
        render(force: false)
    }

    private func render(force: Bool) {
        guard force || displayLink == nil else {
            return
        }

        guard
            let renderer,
            let renderTarget = makeTimelineRenderTarget()
        else {
            return
        }

        renderer.render(
            target: renderTarget,
            state: transportRenderState()
        )
    }

    private func transportRenderState() -> TransportControlPanelRenderer.State {
        TransportControlPanelRenderer.State(
            isPlaying: isPlaying,
            isEnabled: isTransportEnabled,
            hoveredButtonIndex: hoveredButtonIndex ?? -1,
            pressedButtonIndex: pressedButtonIndex ?? -1,
            hoveredPoint: hoveredPoint,
            pressedPoint: pressedPoint,
            lastPressTime: lastPressTime,
            lastPlaybackStateChangeTime: lastPlaybackStateChangeTime,
            previousIsPlaying: previousIsPlaying,
            outputActivity: outputActivity
        )
    }
}

private final class TransportControlPanelRenderer {
    struct State {
        let isPlaying: Bool
        let isEnabled: Bool
        let hoveredButtonIndex: Int
        let pressedButtonIndex: Int
        let hoveredPoint: CGPoint?
        let pressedPoint: CGPoint?
        let lastPressTime: CFTimeInterval
        let lastPlaybackStateChangeTime: CFTimeInterval
        let previousIsPlaying: Bool
        let outputActivity: Float
    }

    private struct QuadVertex {
        var position: SIMD4<Float>
    }

    private struct Uniform {
        var metrics: SIMD4<Float>
        var state: SIMD4<Float>
        var accent: SIMD4<Float>
        var dynamics: SIMD4<Float>
        var transition: SIMD4<Float>
    }

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let quadBuffer: MTLBuffer

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw RendererError.commandQueueUnavailable
        }

        let vertices = [
            QuadVertex(position: SIMD4<Float>(0, 0, 0, 1)),
            QuadVertex(position: SIMD4<Float>(1, 0, 0, 1)),
            QuadVertex(position: SIMD4<Float>(0, 1, 0, 1)),
            QuadVertex(position: SIMD4<Float>(1, 0, 0, 1)),
            QuadVertex(position: SIMD4<Float>(1, 1, 0, 1)),
            QuadVertex(position: SIMD4<Float>(0, 1, 0, 1)),
        ]
        guard let quadBuffer = vertices.withUnsafeBytes({ bytes -> MTLBuffer? in
            guard let baseAddress = bytes.baseAddress else {
                return nil
            }
            return device.makeBuffer(bytes: baseAddress, length: bytes.count, options: [.storageModeShared])
        }) else {
            throw RendererError.quadBufferUnavailable
        }

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard
            let vertexFunction = library.makeFunction(name: "transport_vertex"),
            let fragmentFunction = library.makeFunction(name: "transport_fragment")
        else {
            throw RendererError.shaderFunctionUnavailable
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        self.commandQueue = commandQueue
        self.quadBuffer = quadBuffer
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func render(target: TimelineRenderTarget, state: State) {
        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: target.renderPassDescriptor)
        else {
            return
        }

        let displayTime = target.displayTimestamp
        let hoverPoint = state.hoveredPoint ?? CGPoint(x: -10_000, y: -10_000)
        let pressedPoint = state.pressedPoint ?? CGPoint(x: -10_000, y: -10_000)
        var uniform = Uniform(
            metrics: SIMD4<Float>(
                Float(target.viewportSize.width),
                Float(target.viewportSize.height),
                target.backingScale,
                Float(displayTime.truncatingRemainder(dividingBy: 1_000))
            ),
            state: SIMD4<Float>(
                state.isPlaying ? 1 : 0,
                state.isEnabled ? 1 : 0,
                Float(state.hoveredButtonIndex),
                Float(state.pressedButtonIndex)
            ),
            accent: SIMD4<Float>(0.24, 0.92, 0.98, 1),
            dynamics: SIMD4<Float>(
                Float(hoverPoint.x),
                Float(hoverPoint.y),
                Float(max(displayTime - state.lastPressTime, 0)),
                state.outputActivity
            ),
            transition: SIMD4<Float>(
                Float(pressedPoint.x),
                Float(pressedPoint.y),
                Float(max(displayTime - state.lastPlaybackStateChangeTime, 0)),
                state.previousIsPlaying ? 1 : 0
            )
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<Uniform>.stride, index: 1)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<Uniform>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(target.drawable)
        commandBuffer.commit()
    }

    private enum RendererError: Error {
        case commandQueueUnavailable
        case quadBufferUnavailable
        case shaderFunctionUnavailable
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadVertex {
        float4 position;
    };

    struct Uniform {
        float4 metrics;
        float4 state;
        float4 accent;
        float4 dynamics;
        float4 transition;
    };

    struct RasterizedVertex {
        float4 position [[position]];
        float2 uv;
        float4 metrics;
        float4 state;
        float4 accent;
        float4 dynamics;
        float4 transition;
    };

    static float rounded_box_sdf(float2 p, float2 halfSize, float radius) {
        float2 q = abs(p) - halfSize + radius;
        return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    }

    static float coverage_from_sdf(float sdf, float aa) {
        return 1.0 - smoothstep(-aa, aa, sdf);
    }

    static float ease_out_cubic(float t) {
        t = clamp(t, 0.0, 1.0);
        float inv = 1.0 - t;
        return 1.0 - inv * inv * inv;
    }

    static float ease_in_out(float t) {
        t = clamp(t, 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    static float gaussian(float x, float width) {
        return exp(-(x * x) / max(width, 0.0001));
    }

    static float source_over_alpha(float destinationAlpha, float sourceAlpha) {
        return sourceAlpha + destinationAlpha * (1.0 - sourceAlpha);
    }

    static float4 source_over(float4 destination, float4 source) {
        float sourceAlpha = clamp(source.a, 0.0, 1.0);
        float destinationAlpha = clamp(destination.a, 0.0, 1.0);
        float outAlpha = source_over_alpha(destinationAlpha, sourceAlpha);
        if (outAlpha <= 0.000001) {
            return float4(0.0);
        }
        float3 outColor = (
            source.rgb * sourceAlpha +
            destination.rgb * destinationAlpha * (1.0 - sourceAlpha)
        ) / outAlpha;
        return float4(outColor, outAlpha);
    }

    static float edge_distance(float2 p, float2 a, float2 b) {
        float2 edge = b - a;
        return ((p.x - a.x) * edge.y - (p.y - a.y) * edge.x) / max(length(edge), 0.0001);
    }

    static float triangle_coverage(float2 p, float2 a, float2 b, float2 c, float aa) {
        float d0 = edge_distance(p, a, b);
        float d1 = edge_distance(p, b, c);
        float d2 = edge_distance(p, c, a);
        bool positive = d0 >= 0.0 && d1 >= 0.0 && d2 >= 0.0;
        bool negative = d0 <= 0.0 && d1 <= 0.0 && d2 <= 0.0;
        if (!(positive || negative)) {
            return 0.0;
        }
        float edgeDistance = min(min(abs(d0), abs(d1)), abs(d2));
        return smoothstep(0.0, aa, edgeDistance);
    }

    static float rect_coverage(float2 p, float2 center, float2 halfSize, float radius, float aa) {
        return coverage_from_sdf(rounded_box_sdf(p - center, halfSize, radius), aa);
    }

    static float play_icon_coverage(float2 p, float2 center, float aa, float grow) {
        return triangle_coverage(
            p,
            center + float2(7.0 + grow, 0.0),
            center + float2(-5.0 - grow * 0.35, -8.4 - grow),
            center + float2(-5.0 - grow * 0.35, 8.4 + grow),
            aa
        );
    }

    static float pause_icon_coverage(float2 p, float2 center, float aa, float grow) {
        float leftPause = rect_coverage(
            p,
            center + float2(-4.6 - grow * 0.12, 0.0),
            float2(2.1 + grow * 0.18, 8.2 + grow),
            1.6,
            aa
        );
        float rightPause = rect_coverage(
            p,
            center + float2(4.6 + grow * 0.12, 0.0),
            float2(2.1 + grow * 0.18, 8.2 + grow),
            1.6,
            aa
        );
        return max(leftPause, rightPause);
    }

    static float2 rotate2(float2 p, float angle) {
        float s = sin(angle);
        float c = cos(angle);
        return float2(c * p.x - s * p.y, s * p.x + c * p.y);
    }

    static float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    static float value_noise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }

    static float fbm(float2 p) {
        float value = 0.0;
        float amplitude = 0.5;
        float2 shift = float2(8.19, 3.71);
        for (int octave = 0; octave < 4; ++octave) {
            value += amplitude * value_noise(p);
            p = rotate2(p * 2.04 + shift, 0.72);
            amplitude *= 0.52;
        }
        return value;
    }

    static float fluid_caustic(float2 q, float time) {
        float angle = atan2(q.y, q.x);
        float radius = length(q);
        float field = fbm(rotate2(q * 3.6, time * 0.10) + float2(time * 0.055, -time * 0.034));
        float waveA = sin(angle * 2.7 + radius * 12.0 - time * 0.92 + field * 5.8);
        float waveB = sin(q.x * 9.0 - q.y * 5.5 + time * 0.72 + field * 4.0);
        float vein = smoothstep(0.72, 1.0, abs(waveA * 0.66 + waveB * 0.34));
        return pow(vein, 2.8) * smoothstep(1.0, 0.05, radius);
    }

    static float3 fluid_color(
        float2 q,
        float time,
        float hot,
        float pressed,
        float enabled,
        float activeEnergy,
        float audioEnergy,
        float2 hoverLocal,
        float pressPulse,
        float3 accent
    ) {
        float radius = length(q);
        float core = smoothstep(1.02, 0.05, radius);

        float2 toHover = hoverLocal - q;
        float hoverWell = hot * exp(-dot(toHover, toHover) * 1.75);
        q += normalize(toHover + float2(0.0001, -0.0002)) * hoverWell * 0.050;

        float motionTime = time * (0.25 + activeEnergy * 0.70 + audioEnergy * 0.28);
        float2 flow = rotate2(q, 0.23 * sin(motionTime * 0.82) + pressed * 0.42 + pressPulse * 0.22);
        flow += 0.13 * float2(
            sin(motionTime * 1.35 + q.y * 5.4 + audioEnergy * 1.8),
            cos(motionTime * 1.08 - q.x * 4.9)
        );
        float smoke = fbm(flow * (2.30 + activeEnergy * 0.20 + audioEnergy * 0.30) + float2(motionTime * 0.135, -motionTime * 0.105));
        float filament = fbm(rotate2(flow * (5.0 + activeEnergy * 0.55), smoke * 2.7 + motionTime * 0.18));
        float caustic = fluid_caustic(q + (smoke - 0.5) * 0.10 + hoverWell * 0.018, motionTime);
        float shimmer = 0.5 + 0.5 * sin(motionTime * 2.15 + smoke * 8.0 + filament * 4.0);

        float3 deepCyan = float3(0.020, 0.250, 0.310);
        float3 teal = float3(0.060, 0.620, 0.700);
        float3 cyan = float3(0.170, 0.950, 1.000);
        float3 ice = float3(0.760, 1.000, 0.960);
        float3 blueViolet = float3(0.110, 0.420, 0.850);

        float energy = enabled * (0.74 + 0.13 * hot + 0.17 * pressed + 0.18 * activeEnergy + 0.13 * audioEnergy);
        float3 color = mix(deepCyan, teal, clamp(core * 0.46 + smoke * 0.52 + hoverWell * 0.16, 0.0, 1.0));
        color = mix(color, cyan, clamp(pow(core, 1.38) * 0.30 + filament * 0.42 + pressed * 0.10 + activeEnergy * 0.08, 0.0, 1.0));
        color = mix(color, blueViolet, clamp((1.0 - core) * smoke * 0.23 + audioEnergy * smoke * 0.10, 0.0, 1.0));
        color = mix(color, ice, clamp(caustic * (0.34 + pressed * 0.13 + audioEnergy * 0.13) + shimmer * core * 0.09, 0.0, 0.58));
        color += accent * (0.055 * core + 0.13 * caustic + 0.040 * pressed + 0.035 * audioEnergy);
        return mix(float3(0.085, 0.105, 0.114), color, clamp(energy, 0.0, 1.0));
    }

    vertex RasterizedVertex transport_vertex(
        uint vertexID [[vertex_id]],
        constant QuadVertex *vertices [[buffer(0)]],
        constant Uniform &uniform [[buffer(1)]]
    ) {
        float2 uv = vertices[vertexID].position.xy;
        RasterizedVertex out;
        out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
        out.uv = uv;
        out.metrics = uniform.metrics;
        out.state = uniform.state;
        out.accent = uniform.accent;
        out.dynamics = uniform.dynamics;
        out.transition = uniform.transition;
        return out;
    }

    fragment float4 transport_fragment(RasterizedVertex in [[stage_in]]) {
        float2 size = max(in.metrics.xy, float2(1.0));
        float scale = max(in.metrics.z, 1.0);
        float2 p = in.uv * size;
        float aa = max(1.0 / scale, 0.65);
        float enabled = clamp(in.state.y, 0.0, 1.0);
        float hovered = in.state.z;
        float pressedPointer = in.state.w;
        float isPlaying = clamp(in.state.x, 0.0, 1.0);
        float3 accent = in.accent.rgb;
        float time = in.metrics.w;
        float2 hoverPoint = in.dynamics.xy;
        float pressAge = clamp(in.dynamics.z, 0.0, 8.0);
        float audioEnergy = smoothstep(0.015, 0.82, clamp(in.dynamics.w, 0.0, 1.0));
        float2 pressPoint = in.transition.xy;
        float playbackChangeAge = clamp(in.transition.z, 0.0, 8.0);
        float previousPlaying = clamp(in.transition.w, 0.0, 1.0);
        float playRamp = isPlaying * ease_out_cubic(playbackChangeAge / 0.34);
        float pauseQuiet = 1.0 - ease_out_cubic(playbackChangeAge / 0.50);
        float pauseTail = (1.0 - isPlaying) * previousPlaying * pauseQuiet;
        float activeEnergy = max(playRamp, pauseTail);
        float statePulse = isPlaying * (0.5 + 0.5 * sin(time * 2.15)) * 0.028;

        float4 color = float4(0.0);
        float2 center = size * 0.5;
        float panelSDF = rounded_box_sdf(p - center, float2(26.0, 21.0), 17.0);
        float panelCoverage = coverage_from_sdf(panelSDF, aa);
        float panelStroke = smoothstep(2.2, 0.0, abs(panelSDF));
        color = source_over(color, float4(0.077, 0.084, 0.089, 0.27 * panelCoverage));
        color = source_over(color, float4(accent * 0.30, 0.060 * panelStroke));

        for (int buttonIndex = 0; buttonIndex < 1; ++buttonIndex) {
            float selected = isPlaying;
            float pointerPressed = abs(pressedPointer - float(buttonIndex)) < 0.5 ? 1.0 : 0.0;
            float hot = abs(hovered - float(buttonIndex)) < 0.5 ? 1.0 : 0.0;
            float pressed = max(selected, pointerPressed);
            float disabled = 1.0 - enabled;
            float pressPulse = exp(-pressAge / 0.24) * pointerPressed;
            float depth = enabled * (0.08 * activeEnergy + 0.13 * pressed + 0.13 * pointerPressed);

            float2 buttonCenter = center + float2(0.0, depth * 0.95);
            float buttonRadius = 18.0 - depth * 0.45;
            float2 halfSize = float2(buttonRadius - depth * 0.55, buttonRadius - depth * 0.35);
            float buttonSDF = rounded_box_sdf(p - buttonCenter, halfSize, buttonRadius);
            float buttonCoverage = coverage_from_sdf(buttonSDF, aa);
            float glowDistance = max(buttonSDF, 0.0);
            float glow = exp(-glowDistance * glowDistance / (pressed > 0.0 ? 96.0 : 62.0));
            float broadGlow = exp(-glowDistance * glowDistance / 190.0);
            float pulse = 0.5 + 0.5 * sin(time * 1.45 + activeEnergy * 2.1);
            float bloom = glow * (0.028 + 0.040 * hot + 0.050 * pressed + 0.020 * audioEnergy + statePulse) * enabled;
            float broadBloom = broadGlow * (0.004 + 0.008 * hot + 0.009 * pressed + 0.006 * pulse * activeEnergy) * enabled;
            color = source_over(color, float4(mix(accent, float3(0.68, 0.98, 0.92), 0.22), broadBloom));
            color = source_over(color, float4(mix(accent, float3(0.78, 1.0, 0.96), 0.28), bloom));

            float innerShine = exp(-length(p - buttonCenter) * length(p - buttonCenter) / 940.0);
            float2 local = (p - buttonCenter) / max(buttonRadius, 0.001);
            float hasHoverPoint = step(-1000.0, hoverPoint.x) * hot;
            float2 hoverLocal = mix(float2(0.0), (hoverPoint - buttonCenter) / max(buttonRadius, 0.001), hasHoverPoint);
            float3 substance = fluid_color(
                local,
                time,
                hot,
                pressed,
                enabled,
                activeEnergy,
                audioEnergy,
                hoverLocal,
                pressPulse,
                accent
            );
            float caustic = fluid_caustic(local + hoverLocal * 0.025 * hasHoverPoint, time * (0.58 + activeEnergy * 0.22));
            float2 lightVector = normalize(float2(-0.62, -0.78));
            float glassSpec = pow(clamp(dot(normalize(float2(-local.x, -local.y) + float2(0.001)), lightVector) * 0.5 + 0.5, 0.0, 1.0), 9.0);
            float innerShadow = smoothstep(0.10, 0.94, length(local)) * (0.045 + depth * 0.14);
            float3 topLight = substance +
                accent * innerShine * (0.022 + 0.045 * pressed + 0.032 * hot + 0.035 * audioEnergy) +
                float3(0.88, 1.0, 0.96) * caustic * (0.052 + 0.036 * pressed + 0.035 * activeEnergy) +
                float3(0.78, 1.0, 0.96) * glassSpec * (0.055 + hot * 0.035);
            topLight *= 1.0 - innerShadow;
            float alpha = buttonCoverage * (0.92 - disabled * 0.42);
            color = source_over(color, float4(topLight, alpha));

            float validPress = step(-1000.0, pressPoint.x);
            float rippleDistance = abs(length(p - pressPoint) - pressAge * 94.0);
            float ripple = validPress * buttonCoverage * exp(-(rippleDistance * rippleDistance) / 7.5) * exp(-pressAge / 0.31);
            color = source_over(color, float4(mix(accent, float3(0.92, 1.0, 0.98), 0.42), ripple * 0.16 * enabled));

            float wakeAge = playbackChangeAge;
            float wakeCenter = -0.42 + wakeAge * 2.45;
            float wake = isPlaying *
                exp(-wakeAge / 0.44) *
                gaussian(local.x - wakeCenter, 0.035) *
                gaussian(local.y, 0.40) *
                buttonCoverage;
            color = source_over(color, float4(float3(0.54, 0.96, 0.90), wake * 0.115 * enabled));

            float ringSDF = abs(buttonSDF);
            float ring = smoothstep(2.0, 0.0, ringSDF);
            float rimSpark = fluid_caustic(local * 1.18 + float2(0.31, -0.17), time * 0.72 + 4.0);
            float topRim = smoothstep(0.85, -0.15, local.y) * smoothstep(1.05, 0.52, length(local));
            float ringAlpha = (0.064 + 0.058 * hot + 0.082 * pressed + rimSpark * 0.046 + topRim * 0.056) * enabled;
            color = source_over(color, float4(mix(accent, float3(0.84, 1.0, 0.96), 0.16 + rimSpark * 0.24), ring * ringAlpha));
        }

        float iconAlpha = 0.58 + enabled * 0.42;
        float4 hotIconColor = float4(float3(0.96, 1.0, 1.0), iconAlpha);

        float2 playCenter = center;
        float2 iconLocal = (p - playCenter) / 18.0;
        float iconRefraction = (0.18 + activeEnergy * 0.24 + audioEnergy * 0.12) * enabled;
        float2 iconWarp = float2(
            sin(time * 1.08 + iconLocal.y * 5.2 + iconLocal.x * 1.7),
            cos(time * 0.91 - iconLocal.x * 4.6 + iconLocal.y * 2.2)
        ) * iconRefraction;
        float2 iconGlowPoint = p + iconWarp;
        float iconFade = exp(-playbackChangeAge / 0.14) * enabled;
        float currentIconAlpha = hotIconColor.a * (1.0 - iconFade * 0.24);
        float previousIconAlpha = hotIconColor.a * iconFade * 0.25;
        float currentIcon = 0.0;
        float currentIconGlow = 0.0;
        float previousIcon = 0.0;
        if (isPlaying > 0.5) {
            currentIcon = pause_icon_coverage(p, playCenter, aa, 0.0);
            currentIconGlow = pause_icon_coverage(iconGlowPoint, playCenter, aa * 3.0, 1.25);
        } else {
            currentIcon = play_icon_coverage(p, playCenter, aa, 0.0);
            currentIconGlow = play_icon_coverage(iconGlowPoint, playCenter, aa * 3.0, 1.25);
        }
        if (previousPlaying > 0.5) {
            previousIcon = pause_icon_coverage(p, playCenter, aa, 0.0);
        } else {
            previousIcon = play_icon_coverage(p, playCenter, aa, 0.0);
        }

        color = source_over(color, float4(accent, currentIconGlow * 0.052 * enabled));
        color = source_over(color, float4(float3(0.72, 0.98, 1.0), previousIcon * previousIconAlpha));
        color = source_over(color, float4(hotIconColor.rgb, currentIcon * currentIconAlpha));

        return color;
    }
    """
}
