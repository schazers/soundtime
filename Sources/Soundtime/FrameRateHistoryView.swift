import AppKit
import Metal
import QuartzCore

final class FrameRateHistoryView: TimelineMetalLayerView {
    private struct HistoryVertex {
        var position: SIMD2<Float>
    }

    private struct HistorySample {
        var timestamp: Float
        var framesPerSecond: Float
    }

    private struct HistoryUniforms {
        var viewport: SIMD4<Float>
        var timing: SIMD4<Float>
        var colors: SIMD4<Float>
    }

    private let historyDuration: CFTimeInterval = 15
    private let historyExitDuration: CFTimeInterval = 1.25
    private let maximumSampleCount = 192
    private let renderRefreshRate: TimeInterval = 30
    private let sampleLock = NSLock()
    private let timeOrigin = CACurrentMediaTime()
    private var samples: [HistorySample] = []
    private var displayTimer: Timer?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
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
        super.init(frame: frameRect, device: device)
        configureHistoryRenderer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureHistoryRenderer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            displayTimer?.invalidate()
            displayTimer = nil
        } else {
            startDisplayTimerIfNeeded()
            render()
        }
    }

    override func layout() {
        super.layout()
        render()
    }

    func display(frameStats: TimelineFrameStats) {
        let now = relativeTimestamp()
        let sample = HistorySample(
            timestamp: now,
            framesPerSecond: Float(max(frameStats.framesPerSecond, 0))
        )

        sampleLock.lock()
        samples.append(sample)
        trimSamples(now: now)
        sampleLock.unlock()

        render()
    }

    private func startDisplayTimerIfNeeded() {
        guard displayTimer == nil else {
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
                maximumFramesPerSecond(for: renderSamples)
            ),
            timing: SIMD4<Float>(
                now,
                Float(historyDuration),
                Float(renderSamples.count),
                renderSamples.last?.framesPerSecond ?? 0
            ),
            colors: SIMD4<Float>(0.0, 0.78, 0.84, 1.0)
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
                renderSamples.append(HistorySample(
                    timestamp: now,
                    framesPerSecond: latestSample.framesPerSecond
                ))
            }
        } else {
            renderSamples.append(HistorySample(timestamp: now, framesPerSecond: 0))
        }

        if renderSamples.count > maximumSampleCount {
            renderSamples.removeFirst(renderSamples.count - maximumSampleCount)
        }
        return renderSamples
    }

    private func trimSamples(now: Float) {
        let oldestRetainedTimestamp = now - Float(historyDuration + historyExitDuration)
        while samples.count > maximumSampleCount || (samples.first?.timestamp ?? now) < oldestRetainedTimestamp {
            samples.removeFirst()
        }
    }

    private func maximumFramesPerSecond(for samples: [HistorySample]) -> Float {
        let maximumObservedFPS = samples.reduce(Float(0)) { result, sample in
            max(result, sample.framesPerSecond)
        }
        let paddedMaximum = ceil(max(maximumObservedFPS, 144) / 30) * 30
        return min(max(paddedMaximum, 144), 240)
    }

    private func relativeTimestamp() -> Float {
        Float(CACurrentMediaTime() - timeOrigin)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct HistoryVertex {
        float2 position;
    };

    struct HistorySample {
        float timestamp;
        float framesPerSecond;
    };

    struct HistoryUniforms {
        float4 viewport;
        float4 timing;
        float4 colors;
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

    static float sample_y(HistorySample sample, float maxFPS, float bottom, float top) {
        float normalizedFPS = clamp(sample.framesPerSecond / max(maxFPS, 1.0), 0.0, 1.0);
        return mix(bottom, top, normalizedFPS);
    }

    fragment float4 frame_rate_history_fragment(
        RasterizedVertex in [[stage_in]],
        constant HistorySample *samples [[buffer(0)]],
        constant HistoryUniforms &uniforms [[buffer(1)]]
    ) {
        float2 uv = in.uv;
        float width = max(uniforms.viewport.x, 1.0);
        float height = max(uniforms.viewport.y, 1.0);
        float maxFPS = max(uniforms.viewport.w, 1.0);
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
        for (float fps = 60.0; fps < maxFPS + 1.0; fps += 60.0) {
            float y = mix(bottom, top, clamp(fps / maxFPS, 0.0, 1.0));
            gridAlpha += line_alpha(uv.y, y, 0.0013) * background * 0.30;
        }
        color = mix(color, float3(0.25, 0.34, 0.36), clamp(gridAlpha, 0.0, 1.0));

        float aspect = width / height;
        float2 scaledUV = float2(uv.x * aspect, uv.y);
        float line = 0.0;
        float glow = 0.0;
        float fill = 0.0;
        float latestDot = 0.0;
        float leftFade = smoothstep(left, left + 0.060, uv.x);

        if (sampleCount >= 2u) {
            for (uint i = 1u; i < sampleCount; ++i) {
                HistorySample previousSample = samples[i - 1u];
                HistorySample currentSample = samples[i];
                float x0 = mix(left, right, sample_x(previousSample, now, duration));
                float x1 = mix(left, right, sample_x(currentSample, now, duration));
                if ((x0 < left && x1 < left) || (x0 > right && x1 > right)) {
                    continue;
                }

                float y0 = sample_y(previousSample, maxFPS, bottom, top);
                float y1 = sample_y(currentSample, maxFPS, bottom, top);
                float2 p0 = float2(x0 * aspect, y0);
                float2 p1 = float2(x1 * aspect, y1);
                float distance = segment_distance(scaledUV, p0, p1);
                float lineWidth = 1.45 / height;
                float glowWidth = 7.5 / height;
                line = max(line, (1.0 - smoothstep(lineWidth, lineWidth + 1.4 / height, distance)) * leftFade);
                glow = max(glow, (1.0 - smoothstep(lineWidth, glowWidth, distance)) * leftFade);

                float segmentLeft = min(x0, x1);
                float segmentRight = max(x0, x1);
                float yOnSegment = mix(y0, y1, clamp((uv.x - x0) / max(x1 - x0, 0.000001), 0.0, 1.0));
                float inSegmentX = smoothstep(segmentLeft, segmentLeft + 0.004, uv.x) *
                    (1.0 - smoothstep(segmentRight - 0.004, segmentRight, uv.x));
                fill = max(fill, inSegmentX * smoothstep(bottom, yOnSegment, uv.y) *
                    (1.0 - smoothstep(yOnSegment, yOnSegment + 0.01, uv.y)) * 0.10 * leftFade);
            }

            HistorySample latestSample = samples[sampleCount - 1u];
            float latestX = mix(left, right, sample_x(latestSample, now, duration));
            float latestY = sample_y(latestSample, maxFPS, bottom, top);
            latestDot = 1.0 - smoothstep(2.0 / height, 6.0 / height, distance(scaledUV, float2(latestX * aspect, latestY)));
        }

        float3 glowColor = float3(0.08, 0.70, 0.86);
        float3 lineColor = mix(float3(0.28, 0.82, 0.86), float3(0.94, 0.98, 0.99), line * 0.45);
        color += glowColor * glow * 0.28 * background;
        color = mix(color, float3(0.09, 0.34, 0.39), fill * background);
        color = mix(color, lineColor, line * background);
        color = mix(color, float3(0.96, 1.0, 1.0), latestDot * 0.75 * background);

        float topSheen = smoothstep(top, top - 0.10, uv.y) * background * 0.08;
        color += float3(0.18, 0.46, 0.50) * topSheen;

        return float4(color, 1.0);
    }
    """
}
