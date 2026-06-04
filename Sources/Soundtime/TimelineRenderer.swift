import MetalKit
import simd

final class TimelineRenderer: NSObject, MTKViewDelegate {
    private struct TimelineVertex {
        var position: SIMD4<Float>
        var color: SIMD4<Float>
    }

    private enum RendererError: Error {
        case commandQueueUnavailable
        case shaderFunctionUnavailable
    }

    private struct CachedVertexBuffer {
        let buffer: MTLBuffer
        let vertexCount: Int
    }

    private struct WaveformMipLevel {
        let overview: WaveformOverview
        let binCount: Int
    }

    private struct GridCacheKey: Equatable {
        let width: Float
        let height: Float
        let backingScale: Float
        let viewportStart: Float
        let viewportDuration: Float
    }

    private struct GridCache {
        let key: GridCacheKey
        let vertices: CachedVertexBuffer
    }

    private static let inlineVertexUploadLimit = 4 * 1_024

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var waveformOverview: WaveformOverview?
    private var waveformMipLevels: [WaveformMipLevel] = []
    private var gridCache: GridCache?
    private var dynamicVertexBuffer: MTLBuffer?
    private var playheadProgress: Float = 0
    private var viewport = TimelineViewport.full
    private var hoverProgress: Float?
    private var isHoverGuideArmed = false
    private var selection: TimelineSelection?
    private var trimPreview: TimelineTrimRange?

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw RendererError.commandQueueUnavailable
        }

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard
            let vertexFunction = library.makeFunction(name: "timeline_vertex"),
            let fragmentFunction = library.makeFunction(name: "timeline_fragment")
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

        self.device = device
        self.commandQueue = commandQueue
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func displayWaveform(_ waveformOverview: WaveformOverview?) {
        self.waveformOverview = waveformOverview
        waveformMipLevels = makeWaveformMipLevels(from: waveformOverview)
        gridCache = nil
    }

    func displayPlayheadProgress(_ progress: Float) {
        playheadProgress = min(max(progress, 0), 1)
    }

    func displayViewport(_ viewport: TimelineViewport) {
        guard self.viewport != viewport else {
            return
        }

        self.viewport = viewport
        gridCache = nil
    }

    func displayHoverProgress(_ progress: Float?, isArmed: Bool = false) {
        hoverProgress = progress.map { min(max($0, 0), 1) }
        isHoverGuideArmed = progress != nil && isArmed
    }

    func displaySelection(_ selection: TimelineSelection?) {
        self.selection = selection
    }

    func displayTrimPreview(_ trimPreview: TimelineTrimRange?) {
        self.trimPreview = trimPreview
    }

    func draw(in view: MTKView) {
        guard
            let renderPassDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return
        }

        let renderSize = view.bounds.size
        let backingScale = backingScale(for: view)
        let selectionVertices = makeSelectionVertices()
        let waveformVertices = makeWaveformVertices(drawableSize: renderSize)
        let trimPreviewVertices = makeTrimPreviewVertices(
            drawableSize: renderSize,
            backingScale: backingScale
        )
        let hoverGuideVertices = makeHoverGuideVertices(drawableSize: renderSize, backingScale: backingScale)
        let playheadVertices = makePlayheadVertices(drawableSize: renderSize, backingScale: backingScale)

        encoder.setRenderPipelineState(pipelineState)
        if let gridVertices = cachedGridVertices(drawableSize: renderSize, backingScale: backingScale) {
            draw(cachedVertices: gridVertices, primitiveType: .triangle, encoder: encoder)
        }
        draw(vertices: selectionVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: waveformVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: trimPreviewVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: hoverGuideVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: playheadVertices, primitiveType: .triangle, encoder: encoder)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func draw(
        cachedVertices: CachedVertexBuffer,
        primitiveType: MTLPrimitiveType,
        encoder: MTLRenderCommandEncoder
    ) {
        guard cachedVertices.vertexCount > 0 else {
            return
        }

        encoder.setVertexBuffer(cachedVertices.buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: primitiveType, vertexStart: 0, vertexCount: cachedVertices.vertexCount)
    }

    private func draw(
        vertices: [TimelineVertex],
        primitiveType: MTLPrimitiveType,
        encoder: MTLRenderCommandEncoder
    ) {
        guard !vertices.isEmpty else {
            return
        }

        vertices.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            if buffer.count <= Self.inlineVertexUploadLimit {
                encoder.setVertexBytes(baseAddress, length: buffer.count, index: 0)
            } else {
                guard let vertexBuffer = reusableDynamicVertexBuffer(length: buffer.count) else {
                    return
                }

                vertexBuffer.contents().copyMemory(from: baseAddress, byteCount: buffer.count)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            }

            encoder.drawPrimitives(type: primitiveType, vertexStart: 0, vertexCount: vertices.count)
        }
    }

    private func reusableDynamicVertexBuffer(length: Int) -> MTLBuffer? {
        if let dynamicVertexBuffer, dynamicVertexBuffer.length >= length {
            return dynamicVertexBuffer
        }

        dynamicVertexBuffer = device.makeBuffer(length: length, options: [.storageModeShared])
        return dynamicVertexBuffer
    }

    private func makeCachedBuffer(vertices: [TimelineVertex]) -> CachedVertexBuffer? {
        guard !vertices.isEmpty else {
            return nil
        }

        return vertices.withUnsafeBytes { buffer in
            guard
                let baseAddress = buffer.baseAddress,
                let vertexBuffer = device.makeBuffer(
                    bytes: baseAddress,
                    length: buffer.count,
                    options: [.storageModeShared]
                )
            else {
                return nil
            }

            return CachedVertexBuffer(buffer: vertexBuffer, vertexCount: vertices.count)
        }
    }

    private func cachedGridVertices(drawableSize: CGSize, backingScale: Float) -> CachedVertexBuffer? {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            gridCache = nil
            return nil
        }

        let key = GridCacheKey(
            width: width,
            height: height,
            backingScale: backingScale,
            viewportStart: viewport.startProgress,
            viewportDuration: viewport.durationProgress
        )
        if let gridCache, gridCache.key == key {
            return gridCache.vertices
        }

        guard let vertices = makeCachedBuffer(
            vertices: makeGridVertices(drawableSize: drawableSize, backingScale: backingScale)
        ) else {
            gridCache = nil
            return nil
        }

        let nextCache = GridCache(key: key, vertices: vertices)
        gridCache = nextCache
        return nextCache.vertices
    }

    private func makeGridVertices(drawableSize: CGSize, backingScale: Float) -> [TimelineVertex] {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return []
        }

        let gridColor = SIMD4<Float>(0.24, 0.25, 0.26, 1.0)
        let centerColor = SIMD4<Float>(0.34, 0.36, 0.37, 1.0)
        let targetPixelStep: Float = 96
        let lineWidth = pixelLength(backingScale: backingScale)
        let size = SIMD2<Float>(width, height)
        var vertices: [TimelineVertex] = []

        let approximateProgressStep = max(viewport.durationProgress * targetPixelStep / width, 0.0001)
        let progressStep = niceProgressStep(approximateProgressStep)
        let firstGridProgress = floor(viewport.startProgress / progressStep) * progressStep
        var gridProgress = firstGridProgress

        while gridProgress <= viewport.endProgress + progressStep {
            let viewportProgress = viewport.viewportProgress(forTimelineProgress: gridProgress)
            let x = viewportProgress * width
            guard x >= -targetPixelStep else {
                gridProgress += progressStep
                continue
            }
            guard x <= width + targetPixelStep else {
                break
            }

            let alignedX = pixelAligned(x, backingScale: backingScale)
            appendRectangle(
                to: &vertices,
                left: alignedX,
                right: min(alignedX + lineWidth, width),
                top: 0,
                bottom: height,
                color: gridColor,
                drawableSize: size
            )
            gridProgress += progressStep
        }

        let centerY = pixelAligned(height * 0.5, backingScale: backingScale)
        appendRectangle(
            to: &vertices,
            left: 0,
            right: width,
            top: centerY,
            bottom: min(centerY + lineWidth, height),
            color: centerColor,
            drawableSize: size
        )

        return vertices
    }

    private func makeSelectionVertices() -> [TimelineVertex] {
        guard
            let selection,
            waveformOverview != nil,
            selection.durationProgress > 0.001
        else {
            return []
        }

        let left = viewport.viewportProgress(forTimelineProgress: selection.startProgress)
        let right = viewport.viewportProgress(forTimelineProgress: selection.endProgress)
        guard right > 0, left < 1 else {
            return []
        }

        let color = SIMD4<Float>(0.0, 0.84, 0.78, 0.22)
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(6)

        appendRectangle(
            to: &vertices,
            left: max(left, 0),
            right: min(right, 1),
            top: 0,
            bottom: 1,
            color: color
        )

        return vertices
    }

    private func makeWaveformVertices(drawableSize: CGSize) -> [TimelineVertex] {
        guard
            let mipLevel = waveformMipLevel(for: drawableSize),
            !mipLevel.overview.isEmpty
        else {
            return []
        }

        let centerY: Float = 0.5
        let amplitudeHeight: Float = 0.42
        let minimumVisualHeight: Float = 0.002
        let color = SIMD4<Float>(0.78, 0.92, 0.88, 1.0)
        let bins = mipLevel.overview.bins
        let binCount = bins.count
        let startIndex = max(Int(floor(viewport.startProgress * Float(binCount))) - 1, 0)
        let endIndex = min(Int(ceil(viewport.endProgress * Float(binCount))) + 1, binCount)
        guard startIndex < endIndex else {
            return []
        }

        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity((endIndex - startIndex) * 6)

        for index in startIndex..<endIndex {
            let bin = bins[index]
            let timelineX0 = Float(index) / Float(binCount)
            let timelineX1 = Float(index + 1) / Float(binCount)
            let x0 = viewport.viewportProgress(forTimelineProgress: timelineX0)
            let x1 = viewport.viewportProgress(forTimelineProgress: timelineX1)
            guard x1 > 0, x0 < 1 else {
                continue
            }

            var y0 = centerY - bin.maximumSample * amplitudeHeight
            var y1 = centerY - bin.minimumSample * amplitudeHeight

            if y1 - y0 < minimumVisualHeight {
                let midpoint = (y0 + y1) * 0.5
                y0 = midpoint - minimumVisualHeight * 0.5
                y1 = midpoint + minimumVisualHeight * 0.5
            }

            appendRectangle(
                to: &vertices,
                left: max(x0, 0),
                right: min(x1, 1),
                top: max(y0, 0),
                bottom: min(y1, 1),
                color: color
            )
        }

        return vertices
    }

    private func makeTrimPreviewVertices(drawableSize: CGSize, backingScale: Float) -> [TimelineVertex] {
        guard let waveformOverview, !waveformOverview.isEmpty else {
            return []
        }

        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return []
        }

        let trimRange = trimPreview ?? TimelineTrimRange(startProgress: 0, endProgress: 1)
        let startX = viewport.viewportProgress(forTimelineProgress: trimRange.startProgress) * width
        let endX = viewport.viewportProgress(forTimelineProgress: trimRange.endProgress) * width
        let size = SIMD2<Float>(width, height)
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(36)

        if trimRange.startProgress > 0.001 {
            let visibleRight = min(max(startX, 0), width)
            appendRectangle(
                to: &vertices,
                left: 0,
                right: visibleRight,
                top: 0,
                bottom: height,
                color: SIMD4<Float>(0.0, 0.0, 0.0, 0.46),
                drawableSize: size
            )
        }

        if trimRange.endProgress < 0.999 {
            let visibleLeft = min(max(endX, 0), width)
            appendRectangle(
                to: &vertices,
                left: visibleLeft,
                right: width,
                top: 0,
                bottom: height,
                color: SIMD4<Float>(0.0, 0.0, 0.0, 0.46),
                drawableSize: size
            )
        }

        if startX >= 0, startX <= width {
            appendTrimHandle(
                to: &vertices,
                x: startX,
                direction: .leading,
                color: SIMD4<Float>(1.0, 1.0, 1.0, 0.95),
                drawableSize: size,
                backingScale: backingScale
            )
        }
        if endX >= 0, endX <= width {
            appendTrimHandle(
                to: &vertices,
                x: endX,
                direction: .trailing,
                color: SIMD4<Float>(1.0, 1.0, 1.0, 0.95),
                drawableSize: size,
                backingScale: backingScale
            )
        }

        return vertices
    }

    private func makeHoverGuideVertices(drawableSize: CGSize, backingScale: Float) -> [TimelineVertex] {
        guard
            let hoverProgress,
            waveformOverview != nil
        else {
            return []
        }

        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return []
        }

        let guideProgress = viewport.viewportProgress(forTimelineProgress: hoverProgress)
        guard guideProgress >= 0, guideProgress <= 1 else {
            return []
        }

        let guideX = pixelAligned(guideProgress * width, backingScale: backingScale)
        let guideWidth = pixelLength(backingScale: backingScale)
        let left = max(guideX - guideWidth * 0.5, 0)
        let right = min(left + guideWidth, width)
        let alpha: Float = isHoverGuideArmed ? 0.56 : 0.36
        let color = SIMD4<Float>(0.68, 0.70, 0.72, alpha)
        let size = SIMD2<Float>(width, height)
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(6)

        appendRectangle(
            to: &vertices,
            left: left,
            right: right,
            top: 0,
            bottom: height,
            color: color,
            drawableSize: size
        )

        return vertices
    }

    private func makePlayheadVertices(drawableSize: CGSize, backingScale: Float) -> [TimelineVertex] {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return []
        }

        let playheadX: Float
        if waveformOverview == nil {
            playheadX = min(max(80, 0), width)
        } else {
            let playheadViewportProgress = viewport.viewportProgress(forTimelineProgress: playheadProgress)
            guard playheadViewportProgress >= 0, playheadViewportProgress <= 1 else {
                return []
            }

            playheadX = min(max(playheadViewportProgress * width, 0), width)
        }
        let playheadWidth = pixelLength(2, backingScale: backingScale)
        let alignedPlayheadX = pixelAligned(playheadX, backingScale: backingScale)
        let left = max(alignedPlayheadX - playheadWidth * 0.5, 0)
        let right = min(left + playheadWidth, width)
        let color = SIMD4<Float>(0.0, 0.84, 0.78, 1.0)
        let size = SIMD2<Float>(width, height)
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(6)

        appendRectangle(
            to: &vertices,
            left: left,
            right: right,
            top: 0,
            bottom: height,
            color: color,
            drawableSize: size
        )

        return vertices
    }

    private func makeWaveformMipLevels(from waveformOverview: WaveformOverview?) -> [WaveformMipLevel] {
        guard let waveformOverview, !waveformOverview.isEmpty else {
            return []
        }

        var levels = [
            WaveformMipLevel(overview: waveformOverview, binCount: waveformOverview.bins.count),
        ]
        var bins = waveformOverview.bins

        while bins.count > 256 {
            var nextBins: [WaveformOverview.Bin] = []
            nextBins.reserveCapacity((bins.count + 1) / 2)

            var index = 0
            while index < bins.count {
                let firstBin = bins[index]
                if index + 1 < bins.count {
                    let secondBin = bins[index + 1]
                    nextBins.append(WaveformOverview.Bin(
                        minimumSample: min(firstBin.minimumSample, secondBin.minimumSample),
                        maximumSample: max(firstBin.maximumSample, secondBin.maximumSample)
                    ))
                } else {
                    nextBins.append(firstBin)
                }
                index += 2
            }

            bins = nextBins
            levels.append(WaveformMipLevel(
                overview: WaveformOverview(duration: waveformOverview.duration, bins: bins),
                binCount: bins.count
            ))
        }

        return levels
    }

    private func waveformMipLevel(for drawableSize: CGSize) -> WaveformMipLevel? {
        guard !waveformMipLevels.isEmpty else {
            return nil
        }

        let width = max(Float(drawableSize.width), 1)
        let targetVisibleBins = max(width * 1.6, 256)

        for mipLevel in waveformMipLevels {
            let visibleBins = Float(mipLevel.binCount) * viewport.durationProgress
            if visibleBins <= targetVisibleBins {
                return mipLevel
            }
        }

        return waveformMipLevels.last
    }

    private func appendRectangle(
        to vertices: inout [TimelineVertex],
        left: Float,
        right: Float,
        top: Float,
        bottom: Float,
        color: SIMD4<Float>
    ) {
        let topLeft = makeVertex(
            normalizedPosition: SIMD2<Float>(left, top),
            color: color
        )
        let topRight = makeVertex(
            normalizedPosition: SIMD2<Float>(right, top),
            color: color
        )
        let bottomLeft = makeVertex(
            normalizedPosition: SIMD2<Float>(left, bottom),
            color: color
        )
        let bottomRight = makeVertex(
            normalizedPosition: SIMD2<Float>(right, bottom),
            color: color
        )

        vertices.append(topLeft)
        vertices.append(topRight)
        vertices.append(bottomLeft)
        vertices.append(topRight)
        vertices.append(bottomRight)
        vertices.append(bottomLeft)
    }

    private func appendRectangle(
        to vertices: inout [TimelineVertex],
        left: Float,
        right: Float,
        top: Float,
        bottom: Float,
        color: SIMD4<Float>,
        drawableSize: SIMD2<Float>
    ) {
        guard drawableSize.x > 0, drawableSize.y > 0 else {
            return
        }

        appendRectangle(
            to: &vertices,
            left: left / drawableSize.x,
            right: right / drawableSize.x,
            top: top / drawableSize.y,
            bottom: bottom / drawableSize.y,
            color: color
        )
    }

    private enum TrimHandleDirection {
        case leading
        case trailing
    }

    private func appendTrimHandle(
        to vertices: inout [TimelineVertex],
        x: Float,
        direction: TrimHandleDirection,
        color: SIMD4<Float>,
        drawableSize: SIMD2<Float>,
        backingScale: Float
    ) {
        let width = drawableSize.x
        let height = drawableSize.y
        let lineWidth = pixelLength(2, backingScale: backingScale)
        let gripWidth: Float = 12
        let gripHeight: Float = 18
        let clampedX = min(max(x, 0), width)
        let alignedX = pixelAligned(clampedX, backingScale: backingScale)
        let lineLeft = min(max(alignedX - lineWidth * 0.5, 0), width)
        let lineRight = min(lineLeft + lineWidth, width)

        appendRectangle(
            to: &vertices,
            left: lineLeft,
            right: lineRight,
            top: 0,
            bottom: height,
            color: color,
            drawableSize: drawableSize
        )

        let gripLeft: Float
        let gripRight: Float
        switch direction {
        case .leading:
            gripLeft = min(max(clampedX, 0), width)
            gripRight = min(gripLeft + gripWidth, width)
        case .trailing:
            gripRight = min(max(clampedX, 0), width)
            gripLeft = max(gripRight - gripWidth, 0)
        }

        appendRectangle(
            to: &vertices,
            left: gripLeft,
            right: gripRight,
            top: 0,
            bottom: gripHeight,
            color: color,
            drawableSize: drawableSize
        )
        appendRectangle(
            to: &vertices,
            left: gripLeft,
            right: gripRight,
            top: max(height - gripHeight, 0),
            bottom: height,
            color: color,
            drawableSize: drawableSize
        )
    }

    private func pixelLength(_ pixels: Float = 1, backingScale: Float) -> Float {
        pixels / max(backingScale, 1)
    }

    private func pixelAligned(_ position: Float, backingScale: Float) -> Float {
        round(position * max(backingScale, 1)) / max(backingScale, 1)
    }

    private func niceProgressStep(_ progressStep: Float) -> Float {
        guard progressStep > 0 else {
            return 0.1
        }

        let exponent = floor(log10(progressStep))
        let base = pow(10, exponent)
        let normalizedStep = progressStep / base

        if normalizedStep <= 1 {
            return base
        }
        if normalizedStep <= 2 {
            return 2 * base
        }
        if normalizedStep <= 5 {
            return 5 * base
        }
        return 10 * base
    }

    private func makeVertex(normalizedPosition: SIMD2<Float>, color: SIMD4<Float>) -> TimelineVertex {
        return TimelineVertex(
            position: SIMD4<Float>(
                min(max(normalizedPosition.x, 0), 1),
                min(max(normalizedPosition.y, 0), 1),
                0,
                1
            ),
            color: color
        )
    }

    @MainActor
    private func backingScale(for view: MTKView) -> Float {
        if let windowScale = view.window?.backingScaleFactor, windowScale > 0 {
            return Float(windowScale)
        }

        if let layerScale = view.layer?.contentsScale, layerScale > 0 {
            return Float(layerScale)
        }

        if let screenScale = NSScreen.main?.backingScaleFactor, screenScale > 0 {
            return Float(screenScale)
        }

        return 1
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct TimelineVertex {
        float4 position;
        float4 color;
    };

    struct RasterizedVertex {
        float4 position [[position]];
        float4 color;
    };

    vertex RasterizedVertex timeline_vertex(
        uint vertexID [[vertex_id]],
        constant TimelineVertex *vertices [[buffer(0)]]
    ) {
        float2 normalizedPosition = vertices[vertexID].position.xy;

        RasterizedVertex out;
        out.position = float4(
            normalizedPosition.x * 2.0 - 1.0,
            1.0 - normalizedPosition.y * 2.0,
            0.0,
            1.0
        );
        out.color = vertices[vertexID].color;
        return out;
    }

    fragment float4 timeline_fragment(RasterizedVertex in [[stage_in]]) {
        return in.color;
    }
    """
}
