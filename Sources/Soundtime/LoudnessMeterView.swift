import AppKit
import Metal
import QuartzCore

struct LoudnessMeterLevels {
    var leftRMS: Float
    var rightRMS: Float
    var leftPeak: Float
    var rightPeak: Float

    static let silence = LoudnessMeterLevels(
        leftRMS: 0,
        rightRMS: 0,
        leftPeak: 0,
        rightPeak: 0
    )
}

final class LoudnessMeterView: NSView {
    private let labelStack = NSStackView()
    private let leftLabel = LoudnessMeterModeLabel(title: "L")
    private let rightLabel = LoudnessMeterModeLabel(title: "R")
    private let monoLabel = LoudnessMeterModeLabel(title: "L+R")
    private let meterView = LoudnessMeterMetalView()

    private var isMono = false {
        didSet {
            updateMode()
        }
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func display(levels: LoudnessMeterLevels) {
        meterView.display(levels: levels, isMono: isMono)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false

        labelStack.orientation = .vertical
        labelStack.alignment = .trailing
        labelStack.distribution = .fillEqually
        labelStack.spacing = 2
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        meterView.translatesAutoresizingMaskIntoConstraints = false

        let toggleMode: () -> Void = { [weak self] in
            guard let self else {
                return
            }

            isMono.toggle()
        }
        leftLabel.onClick = toggleMode
        rightLabel.onClick = toggleMode
        monoLabel.onClick = toggleMode

        addSubview(labelStack)
        addSubview(meterView)
        updateMode()

        NSLayoutConstraint.activate([
            labelStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelStack.topAnchor.constraint(equalTo: topAnchor),
            labelStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            labelStack.widthAnchor.constraint(equalToConstant: 34),

            meterView.leadingAnchor.constraint(equalTo: labelStack.trailingAnchor, constant: 7),
            meterView.trailingAnchor.constraint(equalTo: trailingAnchor),
            meterView.topAnchor.constraint(equalTo: topAnchor),
            meterView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func updateMode() {
        for subview in labelStack.arrangedSubviews {
            labelStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        if isMono {
            labelStack.addArrangedSubview(monoLabel)
        } else {
            labelStack.addArrangedSubview(leftLabel)
            labelStack.addArrangedSubview(rightLabel)
        }

        meterView.display(levels: meterView.targetLevels, isMono: isMono)
    }
}

private final class LoudnessMeterModeLabel: NSControl {
    var onClick: (() -> Void)?

    private let title: String
    private var isHovered = false {
        didSet {
            needsDisplay = true
        }
    }
    private var trackingArea: NSTrackingArea?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = nextTrackingArea
        addTrackingArea(nextTrackingArea)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let fill = NSColor(white: isHovered ? 0.19 : 0.10, alpha: 1)
        let stroke = NSColor(white: isHovered ? 0.40 : 0.22, alpha: 1)
        let textColor = NSColor(white: isHovered ? 0.92 : 0.66, alpha: 1)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: title.count > 1 ? 9 : 10, weight: .bold),
            .foregroundColor: textColor,
        ]
        let textSize = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(
                x: bounds.midX - textSize.width * 0.5,
                y: bounds.midY - textSize.height * 0.5 - 0.5
            ),
            withAttributes: attributes
        )
    }
}

private final class LoudnessMeterMetalView: TimelineMetalLayerView {
    private struct MeterVertex {
        var position: SIMD2<Float>
    }

    private struct MeterUniforms {
        var levels: SIMD4<Float>
        var peaks: SIMD4<Float>
        var parameters: SIMD4<Float>
    }

    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var vertices: [MeterVertex] = [
        MeterVertex(position: SIMD2<Float>(0, 0)),
        MeterVertex(position: SIMD2<Float>(1, 0)),
        MeterVertex(position: SIMD2<Float>(0, 1)),
        MeterVertex(position: SIMD2<Float>(1, 0)),
        MeterVertex(position: SIMD2<Float>(1, 1)),
        MeterVertex(position: SIMD2<Float>(0, 1)),
    ]

    private(set) var targetLevels = LoudnessMeterLevels.silence
    private var smoothedLevels = LoudnessMeterLevels.silence
    private var heldPeaks = LoudnessMeterLevels.silence
    private var lastUpdateTime = CACurrentMediaTime()
    private var isMono = false

    override init(frame frameRect: NSRect = .zero, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        super.init(frame: frameRect, device: device)
        configureMeter()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureMeter()
    }

    func display(levels: LoudnessMeterLevels, isMono: Bool) {
        targetLevels = levels
        self.isMono = isMono
        updateSmoothing()
        render()
    }

    private func configureMeter() {
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
                let vertexFunction = library.makeFunction(name: "loudness_meter_vertex"),
                let fragmentFunction = library.makeFunction(name: "loudness_meter_fragment")
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
            Swift.print("Soundtime could not create loudness meter renderer: \(error)")
        }
    }

    private func updateSmoothing() {
        let now = CACurrentMediaTime()
        let dt = max(now - lastUpdateTime, 0)
        lastUpdateTime = now

        smoothedLevels.leftRMS = smoothedValue(
            current: smoothedLevels.leftRMS,
            target: targetLevels.leftRMS,
            dt: dt
        )
        smoothedLevels.rightRMS = smoothedValue(
            current: smoothedLevels.rightRMS,
            target: targetLevels.rightRMS,
            dt: dt
        )
        heldPeaks.leftPeak = peakValue(
            current: heldPeaks.leftPeak,
            target: targetLevels.leftPeak,
            dt: dt
        )
        heldPeaks.rightPeak = peakValue(
            current: heldPeaks.rightPeak,
            target: targetLevels.rightPeak,
            dt: dt
        )
    }

    private func smoothedValue(current: Float, target: Float, dt: CFTimeInterval) -> Float {
        let timeConstant: Float = target > current ? 0.035 : 0.18
        let amount = 1 - exp(-Float(dt) / max(timeConstant, 0.001))
        return current + (target - current) * min(max(amount, 0), 1)
    }

    private func peakValue(current: Float, target: Float, dt: CFTimeInterval) -> Float {
        if target >= current {
            return target
        }

        let decayPerSecond: Float = 1.65
        return max(current - decayPerSecond * Float(dt), target)
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

        let levels: SIMD4<Float>
        let peaks: SIMD4<Float>
        if isMono {
            let monoRMS = sqrt((smoothedLevels.leftRMS * smoothedLevels.leftRMS +
                smoothedLevels.rightRMS * smoothedLevels.rightRMS) * 0.5)
            let monoPeak = max(heldPeaks.leftPeak, heldPeaks.rightPeak)
            levels = SIMD4<Float>(monoRMS, monoRMS, 0, 0)
            peaks = SIMD4<Float>(monoPeak, monoPeak, 0, 0)
        } else {
            levels = SIMD4<Float>(smoothedLevels.leftRMS, smoothedLevels.rightRMS, 0, 0)
            peaks = SIMD4<Float>(heldPeaks.leftPeak, heldPeaks.rightPeak, 0, 0)
        }

        var uniforms = MeterUniforms(
            levels: levels,
            peaks: peaks,
            parameters: SIMD4<Float>(isMono ? 1 : 2, Float(CACurrentMediaTime()), 0, 0)
        )

        encoder.setRenderPipelineState(pipelineState)
        vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }

            encoder.setVertexBytes(baseAddress, length: bytes.count, index: 0)
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MeterUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        commandBuffer.present(renderTarget.drawable)
        commandBuffer.commit()
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct MeterVertex {
        float2 position;
    };

    struct RasterizedVertex {
        float4 position [[position]];
        float2 uv;
    };

    struct MeterUniforms {
        float4 levels;
        float4 peaks;
        float4 parameters;
    };

    vertex RasterizedVertex loudness_meter_vertex(
        uint vertexID [[vertex_id]],
        constant MeterVertex *vertices [[buffer(0)]]
    ) {
        float2 position = vertices[vertexID].position;
        RasterizedVertex out;
        out.position = float4(position.x * 2.0 - 1.0, position.y * 2.0 - 1.0, 0.0, 1.0);
        out.uv = position;
        return out;
    }

    static float level_x(float level) {
        float db = 20.0 * log10(max(level, 0.000001));
        return clamp((db + 60.0) / 66.0, 0.0, 1.0);
    }

    static float rounded_rect_alpha(float2 p, float2 center, float2 halfSize, float radius) {
        float2 q = abs(p - center) - halfSize + radius;
        float distance = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
        float aa = max(fwidth(distance), 0.0015);
        return 1.0 - smoothstep(0.0, aa, distance);
    }

    static float segment_alpha(float x, float start, float end) {
        if (end <= start) {
            return 0.0;
        }
        float aa = max(fwidth(x) * 1.4, 0.001);
        return smoothstep(start, start + aa, x) * (1.0 - smoothstep(end - aa, end, x));
    }

    static float lane_alpha(float y, float center, float height) {
        float aa = max(fwidth(y) * 1.6, 0.001);
        float halfHeight = height * 0.5;
        return smoothstep(center - halfHeight, center - halfHeight + aa, y) *
            (1.0 - smoothstep(center + halfHeight - aa, center + halfHeight, y));
    }

    fragment float4 loudness_meter_fragment(
        RasterizedVertex in [[stage_in]],
        constant MeterUniforms &uniforms [[buffer(0)]]
    ) {
        float laneCount = max(uniforms.parameters.x, 1.0);
        float time = uniforms.parameters.y;
        float2 uv = in.uv;
        float zeroX = 60.0 / 66.0;
        float laneIndex = laneCount < 1.5 ? 0.0 : (uv.y > 0.5 ? 0.0 : 1.0);
        float laneCenter = laneCount < 1.5 ? 0.5 : (laneIndex < 0.5 ? 0.70 : 0.30);
        float laneHeight = laneCount < 1.5 ? 0.52 : 0.28;
        float laneMask = lane_alpha(uv.y, laneCenter, laneHeight);

        float railAlpha = rounded_rect_alpha(
            uv,
            float2(0.5, laneCenter),
            float2(0.5, laneHeight * 0.5),
            0.045
        );
        float level = laneIndex < 0.5 ? uniforms.levels.x : uniforms.levels.y;
        float peak = laneIndex < 0.5 ? uniforms.peaks.x : uniforms.peaks.y;
        float levelX = level_x(level);
        float peakX = level_x(peak);

        float stripe = 0.5 + 0.5 * sin((uv.x * 38.0) + time * 4.5 + laneIndex * 1.7);
        float shimmer = 0.82 + stripe * 0.18;
        float verticalGlow = exp(-pow((uv.y - laneCenter) / max(laneHeight * 0.34, 0.001), 2.0));

        float4 color = float4(0.055, 0.055, 0.055, 1.0);
        float rail = railAlpha * (0.52 + verticalGlow * 0.18);
        color.rgb = mix(color.rgb, float3(0.135, 0.145, 0.145), rail);

        float normalFill = segment_alpha(uv.x, 0.0, min(levelX, zeroX)) * laneMask;
        float3 normalColor = mix(float3(0.36, 0.78, 0.76), float3(0.92, 0.96, 0.86), uv.x);
        normalColor *= shimmer * (0.78 + verticalGlow * 0.25);
        color.rgb = mix(color.rgb, normalColor, normalFill * 0.92);

        float clipEndX = max(levelX, peakX);
        float clipFill = segment_alpha(uv.x, zeroX, clipEndX) * laneMask *
            (max(level, peak) > 1.0 ? 1.0 : 0.0);
        float3 clipColor = mix(float3(0.75, 0.10, 0.08), float3(1.0, 0.28, 0.18), uv.x);
        clipColor *= 0.92 + stripe * 0.18;
        color.rgb = mix(color.rgb, clipColor, clipFill);

        float zeroLine = 1.0 - smoothstep(0.001, 0.004, abs(uv.x - zeroX));
        color.rgb = mix(color.rgb, float3(0.83, 0.86, 0.82), zeroLine * laneMask * 0.50);

        float peakLine = 1.0 - smoothstep(0.001, 0.005, abs(uv.x - peakX));
        float peakVisible = peak > 0.00001 ? peakLine * laneMask : 0.0;
        float3 peakColor = peakX > zeroX ? float3(1.0, 0.32, 0.20) : float3(0.95, 0.98, 0.88);
        color.rgb = mix(color.rgb, peakColor, peakVisible * 0.75);

        return float4(color.rgb, 1.0);
    }
    """
}
