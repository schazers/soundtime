import AppKit
import Metal
import QuartzCore

final class FrameRateHistoryView: TimelineMetalLayerView {
    enum Metric {
        case framesPerSecond
        case cpuUsage
    }

    private struct HistoryVertex {
        var position: SIMD2<Float>
    }

    private struct HistorySample {
        var timestamp: Float
        var value: Float
    }

    private struct HistoryUniforms {
        var viewport: SIMD4<Float>
        var timing: SIMD4<Float>
        var colors: SIMD4<Float>
        var danger: SIMD4<Float>
    }

    private let historyDuration: CFTimeInterval = 15
    private let historyExitDuration: CFTimeInterval = 1.25
    private let staleSampleHoldDuration: Float = 0.75
    private let maximumSampleCount = 192
    private let renderRefreshRate: TimeInterval = 30
    private let sampleLock = NSLock()
    private let timeOrigin = CACurrentMediaTime()
    private var samples: [HistorySample] = []
    private var displayTimer: Timer?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private let metric: Metric
    private var isLiveResizePaused = false
    private var vertices: [HistoryVertex] = [
        HistoryVertex(position: SIMD2<Float>(0, 0)),
        HistoryVertex(position: SIMD2<Float>(1, 0)),
        HistoryVertex(position: SIMD2<Float>(0, 1)),
        HistoryVertex(position: SIMD2<Float>(1, 0)),
        HistoryVertex(position: SIMD2<Float>(1, 1)),
        HistoryVertex(position: SIMD2<Float>(0, 1)),
    ]

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override init(frame frameRect: NSRect = .zero, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        metric = .framesPerSecond
        super.init(frame: frameRect, device: device)
        configureHistoryRenderer()
    }

    init(metric: Metric, frame frameRect: NSRect = .zero, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.metric = metric
        super.init(frame: frameRect, device: device)
        configureHistoryRenderer()
    }

    required init?(coder: NSCoder) {
        metric = .framesPerSecond
        super.init(coder: coder)
        configureHistoryRenderer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            stopDisplayTimer()
        } else {
            startDisplayTimerIfNeeded()
            render()
        }
    }

    override var isHidden: Bool {
        didSet {
            if isHidden {
                stopDisplayTimer()
            } else {
                startDisplayTimerIfNeeded()
                render()
            }
        }
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isLiveResizePaused = true
        stopDisplayTimer()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isLiveResizePaused = false
        startDisplayTimerIfNeeded()
        render()
    }

    override func layout() {
        super.layout()
        render()
    }

    func display(frameStats: TimelineFrameStats) {
        display(value: Float(max(frameStats.framesPerSecond, 0)))
    }

    func display(cpuPercent: Double) {
        display(value: Float(max(cpuPercent, 0)))
    }

    private func display(value: Float) {
        let now = relativeTimestamp()
        let sample = HistorySample(
            timestamp: now,
            value: value
        )

        sampleLock.lock()
        samples.append(sample)
        trimSamples(now: now)
        sampleLock.unlock()

        startDisplayTimerIfNeeded()
        render()
    }

    private func startDisplayTimerIfNeeded() {
        guard
            displayTimer == nil,
            window != nil,
            !isLiveResizePaused,
            !isHiddenOrHasHiddenAncestor
        else {
            return
        }

        let timer = Timer(
            timeInterval: 1 / renderRefreshRate,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.render()
            }
        }
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func configureHistoryRenderer() {
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.055, green: 0.055, blue: 0.055, alpha: 1)
        framebufferOnly = true

        guard
            let device = metalDevice,
            let commandQueue = device.makeCommandQueue()
        else {
            return
        }

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard
                let vertexFunction = library.makeFunction(name: "frame_rate_history_vertex"),
                let fragmentFunction = library.makeFunction(name: "frame_rate_history_fragment")
            else {
                return
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            self.commandQueue = commandQueue
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Swift.print("Soundtime could not create frame-rate history renderer: \(error)")
        }
    }

    private func render() {
        guard
            !isLiveResizePaused,
            !isHiddenOrHasHiddenAncestor,
            let renderTarget = makeTimelineRenderTarget(),
            let commandQueue,
            let pipelineState,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderTarget.renderPassDescriptor)
        else {
            return
        }

        let now = relativeTimestamp()
        let renderSamples = currentRenderSamples(now: now)
        var uniforms = HistoryUniforms(
            viewport: SIMD4<Float>(
                Float(renderTarget.viewportSize.width),
                Float(renderTarget.viewportSize.height),
                renderTarget.backingScale,
                maximumValue(for: renderSamples)
            ),
            timing: SIMD4<Float>(
                now,
                Float(historyDuration),
                Float(renderSamples.count),
                renderSamples.last?.value ?? 0
            ),
            colors: baseColor,
            danger: dangerUniform(for: renderSamples)
        )

        encoder.setRenderPipelineState(pipelineState)
        vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }

            encoder.setVertexBytes(baseAddress, length: bytes.count, index: 0)
        }
        renderSamples.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress, !bytes.isEmpty {
                encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 0)
            } else {
                var emptySample = HistorySample(timestamp: now, value: 0)
                encoder.setFragmentBytes(&emptySample, length: MemoryLayout<HistorySample>.stride, index: 0)
            }
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<HistoryUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        commandBuffer.present(renderTarget.drawable)
        commandBuffer.commit()
    }

    private func currentRenderSamples(now: Float) -> [HistorySample] {
        sampleLock.lock()
        trimSamples(now: now)
        var renderSamples = samples
        sampleLock.unlock()

        if let latestSample = renderSamples.last {
            if now > latestSample.timestamp {
                if renderSamples.count == 1 {
                    renderSamples.insert(HistorySample(
                        timestamp: now - Float(historyDuration),
                        value: latestSample.value
                    ), at: 0)
                }
                // The timeline display link intentionally sleeps while idle. Hold
                // the most recent active value briefly so the graph does not snap
                // to zero, then let it age out as historical data instead of
                // pretending stale FPS is the current frame rate forever.
                if now - latestSample.timestamp <= staleSampleHoldDuration {
                    renderSamples.append(HistorySample(
                        timestamp: now,
                        value: latestSample.value
                    ))
                }
            }
        }

        if renderSamples.count > maximumSampleCount {
            renderSamples.removeFirst(renderSamples.count - maximumSampleCount)
        }
        return renderSamples
    }

    private func trimSamples(now: Float) {
        let oldestRetainedTimestamp = now - Float(historyDuration + historyExitDuration)
        while samples.count > 1 &&
            (samples.count > maximumSampleCount || (samples.first?.timestamp ?? now) < oldestRetainedTimestamp)
        {
            samples.removeFirst()
        }
    }

    private func maximumValue(for samples: [HistorySample]) -> Float {
        let maximumObservedValue = samples.reduce(Float(0)) { result, sample in
            max(result, sample.value)
        }

        switch metric {
        case .framesPerSecond:
            let paddedMaximum = ceil(max(maximumObservedValue, 144) / 30) * 30
            return min(max(paddedMaximum, 144), 240)
        case .cpuUsage:
            let paddedMaximum = ceil(max(maximumObservedValue, 100) / 50) * 50
            return min(max(paddedMaximum, 100), 1_000)
        }
    }

    private var baseColor: SIMD4<Float> {
        switch metric {
        case .framesPerSecond:
            return SIMD4<Float>(0.0, 0.78, 0.84, 1.0)
        case .cpuUsage:
            return SIMD4<Float>(0.88, 0.91, 0.93, 1.0)
        }
    }

    private func dangerUniform(for samples: [HistorySample]) -> SIMD4<Float> {
        let maximumRenderedValue = maximumValue(for: samples)
        switch metric {
        case .framesPerSecond:
            return SIMD4<Float>(1, 60, 80, 60)
        case .cpuUsage:
            return SIMD4<Float>(0, 0, 1, max(maximumRenderedValue / 4, 25))
        }
    }

    private func relativeTimestamp() -> Float {
        Float(CACurrentMediaTime() - timeOrigin)
    }

    static func smokeRenderPixelSummary(
        samples inputSamples: [(timestamp: Float, framesPerSecond: Float)],
        now: Float = 16,
        width: Int = 192,
        height: Int = 64
    ) throws -> MetalPixelSmokeSummary {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalPixelSmokeError.metalDeviceUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalPixelSmokeError.commandQueueUnavailable
        }
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        guard
            let vertexFunction = library.makeFunction(name: "frame_rate_history_vertex"),
            let fragmentFunction = library.makeFunction(name: "frame_rate_history_fragment")
        else {
            throw MetalPixelSmokeError.libraryUnavailable
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.renderTarget]
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw MetalPixelSmokeError.textureUnavailable
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.055, green: 0.055, blue: 0.055, alpha: 1)

        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            throw MetalPixelSmokeError.commandBufferUnavailable
        }

        let vertices = [
            HistoryVertex(position: SIMD2<Float>(0, 0)),
            HistoryVertex(position: SIMD2<Float>(1, 0)),
            HistoryVertex(position: SIMD2<Float>(0, 1)),
            HistoryVertex(position: SIMD2<Float>(1, 0)),
            HistoryVertex(position: SIMD2<Float>(1, 1)),
            HistoryVertex(position: SIMD2<Float>(0, 1)),
        ]
        var samples = inputSamples
            .prefix(192)
            .map { HistorySample(timestamp: $0.timestamp, value: $0.framesPerSecond) }
        if samples.isEmpty {
            samples.append(HistorySample(timestamp: now, value: 0))
        }
        let maxFPS = samples.reduce(Float(144)) { max($0, $1.value) }
        var uniforms = HistoryUniforms(
            viewport: SIMD4<Float>(Float(width), Float(height), 1, min(max(ceil(maxFPS / 30) * 30, 144), 240)),
            timing: SIMD4<Float>(now, 15, Float(samples.count), samples.last?.value ?? 0),
            colors: SIMD4<Float>(0.0, 0.78, 0.84, 1.0),
            danger: SIMD4<Float>(1, 60, 80, 60)
        )

        encoder.setRenderPipelineState(pipelineState)
        vertices.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                encoder.setVertexBytes(baseAddress, length: bytes.count, index: 0)
            }
        }
        samples.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 0)
            }
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<HistoryUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return MetalPixelSmokeSummary.analyzeBGRA8(bytes, width: width, height: height)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct HistoryVertex {
        float2 position;
    };

    struct HistorySample {
        float timestamp;
        float value;
    };

    struct HistoryUniforms {
        float4 viewport;
        float4 timing;
        float4 colors;
        float4 danger;
    };

    struct RasterizedVertex {
        float4 position [[position]];
        float2 uv;
    };

    vertex RasterizedVertex frame_rate_history_vertex(
        uint vertexID [[vertex_id]],
        constant HistoryVertex *vertices [[buffer(0)]]
    ) {
        float2 position = vertices[vertexID].position;
        RasterizedVertex out;
        out.position = float4(position.x * 2.0 - 1.0, position.y * 2.0 - 1.0, 0.0, 1.0);
        out.uv = position;
        return out;
    }

    static float rect_alpha(float2 p, float left, float right, float bottom, float top) {
        float2 distance = min(p - float2(left, bottom), float2(right, top) - p);
        float edgeDistance = min(distance.x, distance.y);
        float aa = max(max(fwidth(p.x), fwidth(p.y)), 0.001);
        return smoothstep(0.0, aa, edgeDistance);
    }

    static float line_alpha(float value, float target, float width) {
        float distance = abs(value - target);
        float aa = max(fwidth(value), 0.001);
        return 1.0 - smoothstep(width, width + aa, distance);
    }

    static float segment_distance(float2 point, float2 start, float2 end) {
        float2 segment = end - start;
        float segmentLengthSquared = max(dot(segment, segment), 0.000001);
        float amount = clamp(dot(point - start, segment) / segmentLengthSquared, 0.0, 1.0);
        return length(point - (start + segment * amount));
    }

    static float sample_x(HistorySample sample, float now, float duration) {
        return 1.0 - ((now - sample.timestamp) / max(duration, 0.001));
    }

    static float sample_y(HistorySample sample, float maxValue, float bottom, float top) {
        float normalizedValue = clamp(sample.value / max(maxValue, 1.0), 0.0, 1.0);
        return mix(bottom, top, normalizedValue);
    }

    static float sample_danger(HistorySample sample, float4 danger) {
        if (danger.x < 0.5) {
            return 0.0;
        }
        return 1.0 - smoothstep(danger.y, danger.z, sample.value);
    }

    fragment float4 frame_rate_history_fragment(
        RasterizedVertex in [[stage_in]],
        constant HistorySample *samples [[buffer(0)]],
        constant HistoryUniforms &uniforms [[buffer(1)]]
    ) {
        float2 uv = in.uv;
        float width = max(uniforms.viewport.x, 1.0);
        float height = max(uniforms.viewport.y, 1.0);
        float maxValue = max(uniforms.viewport.w, 1.0);
        float now = uniforms.timing.x;
        float duration = max(uniforms.timing.y, 0.001);
        uint sampleCount = min(uint(max(uniforms.timing.z, 0.0)), 192u);

        float left = 0.035;
        float right = 0.985;
        float bottom = 0.18;
        float top = 0.86;
        float background = rect_alpha(uv, left, right, bottom, top);
        float3 color = float3(0.055, 0.057, 0.058);
        color = mix(color, float3(0.082, 0.092, 0.096), background);

        float gridAlpha = 0.0;
        float gridStep = max(uniforms.danger.w, 1.0);
        for (float value = gridStep; value < maxValue + 1.0; value += gridStep) {
            float y = mix(bottom, top, clamp(value / maxValue, 0.0, 1.0));
            gridAlpha += line_alpha(uv.y, y, 0.0013) * background * 0.30;
        }
        float3 baseGraphColor = clamp(uniforms.colors.rgb, float3(0.0), float3(1.0));
        color = mix(color, baseGraphColor * 0.34, clamp(gridAlpha, 0.0, 1.0));

        float aspect = width / height;
        float2 scaledUV = float2(uv.x * aspect, uv.y);
        float line = 0.0;
        float glow = 0.0;
        float lineDanger = 0.0;
        float glowDanger = 0.0;
        float fill = 0.0;
        float latestDot = 0.0;
        float latestDanger = 0.0;
        float edgeFade = smoothstep(left, left + 0.070, uv.x) *
            (1.0 - smoothstep(right - 0.070, right, uv.x));

        if (sampleCount >= 2u) {
            for (uint i = 1u; i < sampleCount; ++i) {
                HistorySample previousSample = samples[i - 1u];
                HistorySample currentSample = samples[i];
                float x0 = mix(left, right, sample_x(previousSample, now, duration));
                float x1 = mix(left, right, sample_x(currentSample, now, duration));
                if ((x0 < left && x1 < left) || (x0 > right && x1 > right)) {
                    continue;
                }

                float y0 = sample_y(previousSample, maxValue, bottom, top);
                float y1 = sample_y(currentSample, maxValue, bottom, top);
                float2 p0 = float2(x0 * aspect, y0);
                float2 p1 = float2(x1 * aspect, y1);
                float distance = segment_distance(scaledUV, p0, p1);
                float lineWidth = 1.45 / height;
                float glowWidth = 7.5 / height;
                float segmentLine = (1.0 - smoothstep(lineWidth, lineWidth + 1.4 / height, distance)) * edgeFade;
                float segmentGlow = (1.0 - smoothstep(lineWidth, glowWidth, distance)) * edgeFade;
                float danger = max(sample_danger(previousSample, uniforms.danger), sample_danger(currentSample, uniforms.danger));
                line = max(line, segmentLine);
                glow = max(glow, segmentGlow);
                lineDanger = max(lineDanger, segmentLine * danger);
                glowDanger = max(glowDanger, segmentGlow * danger);

                float segmentLeft = min(x0, x1);
                float segmentRight = max(x0, x1);
                float yOnSegment = mix(y0, y1, clamp((uv.x - x0) / max(x1 - x0, 0.000001), 0.0, 1.0));
                float inSegmentX = smoothstep(segmentLeft, segmentLeft + 0.004, uv.x) *
                    (1.0 - smoothstep(segmentRight - 0.004, segmentRight, uv.x));
                fill = max(fill, inSegmentX * smoothstep(bottom, yOnSegment, uv.y) *
                    (1.0 - smoothstep(yOnSegment, yOnSegment + 0.01, uv.y)) * 0.10 * edgeFade);
            }

            HistorySample latestSample = samples[sampleCount - 1u];
            float latestX = mix(left, right, sample_x(latestSample, now, duration));
            float latestY = sample_y(latestSample, maxValue, bottom, top);
            latestDot = (1.0 - smoothstep(2.0 / height, 6.0 / height, distance(scaledUV, float2(latestX * aspect, latestY)))) * edgeFade;
            latestDanger = sample_danger(latestSample, uniforms.danger);
        }

        float lineDangerAmount = clamp(lineDanger / max(line, 0.0001), 0.0, 1.0);
        float glowDangerAmount = clamp(glowDanger / max(glow, 0.0001), 0.0, 1.0);
        float3 calmGlowColor = baseGraphColor * 0.82;
        float3 dangerGlowColor = float3(1.0, 0.13, 0.08);
        float3 glowColor = mix(calmGlowColor, dangerGlowColor, glowDangerAmount);
        float3 calmLineColor = mix(baseGraphColor * 0.82, float3(0.98, 0.99, 1.0), line * 0.45);
        float3 dangerLineColor = mix(float3(0.96, 0.20, 0.12), float3(1.0, 0.62, 0.50), line * 0.30);
        float3 lineColor = mix(calmLineColor, dangerLineColor, lineDangerAmount);
        float3 latestDotColor = mix(float3(0.96, 1.0, 1.0), float3(1.0, 0.24, 0.15), latestDanger);
        color += glowColor * glow * 0.24 * background;
        color = mix(color, baseGraphColor * 0.23, fill * background);
        color = mix(color, lineColor, line * background);
        color = mix(color, latestDotColor, latestDot * 0.75 * background);

        float topSheen = smoothstep(top, top - 0.10, uv.y) * background * 0.08;
        color += baseGraphColor * 0.26 * topSheen;

        return float4(color, 1.0);
    }
    """
}
