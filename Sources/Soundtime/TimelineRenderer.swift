import MetalKit
import simd

struct TimelineFrameStats: Equatable, Sendable {
    let framesPerSecond: Int
    let averageFrameTimeMilliseconds: Double
    let frameTimeJitterMilliseconds: Double
    let worstFrameTimeMilliseconds: Double
}

struct TimelineRenderTarget {
    let renderPassDescriptor: MTLRenderPassDescriptor
    let drawable: MTLDrawable
    let viewportSize: CGSize
    let backingScale: Float
}

final class TimelineRenderer: NSObject {
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

    private struct WaveformCacheKey: Equatable {
        let width: Float
        let viewportStart: Float
        let viewportDuration: Float
        let mipBinCount: Int
        let gainSelectionStart: Float
        let gainSelectionEnd: Float
        let gain: Float
    }

    private struct WaveformCache {
        let key: WaveformCacheKey
        let vertices: CachedVertexBuffer
    }

    private static let inlineVertexUploadLimit = 4 * 1_024

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var renderState = TimelineRenderState.empty
    private var waveformMipLevels: [WaveformMipLevel] = []
    private var gridCache: GridCache?
    private var waveformCache: WaveformCache?
    private var visualPlayheadProgress: Float?
    private var visualPlaybackFrameRate: Double = 144
    private var previousRenderedPlayheadX: Float?
    private var previousRenderedPlayheadTime: CFTimeInterval?
    private var playheadTouchEnergy: Float = 0
    private var lastPlayheadTouchEnergyUpdateTime = CFAbsoluteTimeGetCurrent()
    private var playheadKickEnergy: Float = 0
    private var lastPlayheadKickEnergyUpdateTime = CFAbsoluteTimeGetCurrent()
    private var frameRateWindowStartTime = CFAbsoluteTimeGetCurrent()
    private var previousFrameTime: CFTimeInterval?
    private var frameRateFrameCount = 0
    private var frameIntervalCount = 0
    private var frameIntervalSum: Double = 0
    private var frameIntervalSquareSum: Double = 0
    private var worstFrameInterval: Double = 0
    var onFrameStatsChanged: ((TimelineFrameStats) -> Void)?
    private let playheadTouchRadiusDuration: TimeInterval = 0.42
    private let playheadTouchDecayDuration: CFTimeInterval = 0.046
    private let playheadKickDecayDuration: CFTimeInterval = 0.3
    private let visualPlaybackFrameRateSmoothing = 0.12

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

    func displayWaveform(_ waveformOverview: WaveformOverview?) {
        renderState = renderState.withWaveformOverview(waveformOverview)
        waveformMipLevels = makeWaveformMipLevels(from: waveformOverview)
        gridCache = nil
        waveformCache = nil
        visualPlayheadProgress = nil
        previousRenderedPlayheadX = nil
        previousRenderedPlayheadTime = nil
    }

    func displayPlayheadProgress(_ progress: Float, force: Bool = true) {
        let clampedProgress = min(max(progress, 0), 1)
        if renderState.isPlaybackActive, !force {
            return
        }

        renderState = renderState.withPlayheadProgress(clampedProgress)
        visualPlayheadProgress = clampedProgress
        previousRenderedPlayheadX = nil
        previousRenderedPlayheadTime = nil
    }

    func displayPlaybackActive(_ isActive: Bool) {
        updatePlayheadTouchEnergy(isPlaybackActive: renderState.isPlaybackActive)
        updatePlayheadKickEnergy()
        let wasPlaybackActive = renderState.isPlaybackActive
        renderState = renderState.withPlaybackActive(isActive)

        if wasPlaybackActive != isActive {
            visualPlayheadProgress = renderState.playheadProgress
            previousRenderedPlayheadX = nil
            previousRenderedPlayheadTime = nil
        }

        if isActive {
            playheadTouchEnergy = 1
            if !wasPlaybackActive {
                playheadKickEnergy = 1
            }
        }
    }

    func displayViewport(_ viewport: TimelineViewport) {
        guard renderState.viewport != viewport else {
            return
        }

        renderState = renderState.withViewport(viewport)
        gridCache = nil
        waveformCache = nil
        previousRenderedPlayheadX = nil
        previousRenderedPlayheadTime = nil
    }

    func displayHoverProgress(_ progress: Float?, isArmed: Bool = false) {
        renderState = renderState.withHover(progress: progress, isArmed: isArmed)
    }

    func displaySelection(_ selection: TimelineSelection?) {
        renderState = renderState.withSelection(selection)
    }

    func displayTrimPreview(_ trimPreview: TimelineTrimRange?) {
        renderState = renderState.withTrimPreview(trimPreview)
    }

    func displayGainPreview(selection: TimelineSelection?, gain: Float) {
        let gainPreview: TimelineRenderState.GainPreview?
        if let selection, selection.durationProgress > 0 {
            gainPreview = TimelineRenderState.GainPreview(selection: selection, gain: max(gain, 0))
        } else {
            gainPreview = nil
        }
        renderState = renderState.withGainPreview(gainPreview)
        waveformCache = nil
    }

    func render(to target: TimelineRenderTarget) {
        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: target.renderPassDescriptor)
        else {
            return
        }

        encodeTimeline(
            into: encoder,
            viewportSize: target.viewportSize,
            backingScale: target.backingScale
        )
        encoder.endEncoding()

        commandBuffer.present(target.drawable)
        commandBuffer.commit()
    }

    private func encodeTimeline(
        into encoder: MTLRenderCommandEncoder,
        viewportSize: CGSize,
        backingScale: Float
    ) {
        recordFrameRate()
        let renderState = renderState
        let renderedPlayheadProgress = currentPlayheadProgress(renderState: renderState)
        let selectionVertices = makeSelectionVertices(renderState: renderState)
        let waveformVertices = cachedWaveformVertices(drawableSize: viewportSize, renderState: renderState)
        let trimPreviewVertices = makeTrimPreviewVertices(
            drawableSize: viewportSize,
            backingScale: backingScale,
            renderState: renderState
        )
        let playheadTouchVertices = makePlayheadTouchVertices(
            drawableSize: viewportSize,
            playheadProgress: renderedPlayheadProgress,
            renderState: renderState
        )
        let hoverGuideVertices = makeHoverGuideVertices(
            drawableSize: viewportSize,
            backingScale: backingScale,
            renderState: renderState
        )
        let playheadVertices = makePlayheadVertices(
            drawableSize: viewportSize,
            backingScale: backingScale,
            playheadProgress: renderedPlayheadProgress,
            renderState: renderState
        )

        encoder.setRenderPipelineState(pipelineState)
        if let gridVertices = cachedGridVertices(
            drawableSize: viewportSize,
            backingScale: backingScale,
            renderState: renderState
        ) {
            draw(cachedVertices: gridVertices, primitiveType: .triangle, encoder: encoder)
        }
        draw(vertices: selectionVertices, primitiveType: .triangle, encoder: encoder)
        if let waveformVertices {
            draw(cachedVertices: waveformVertices, primitiveType: .triangle, encoder: encoder)
        }
        draw(vertices: playheadTouchVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: trimPreviewVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: hoverGuideVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: playheadVertices, primitiveType: .triangle, encoder: encoder)
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
                // Each large dynamic draw needs its own buffer. Reusing one buffer within
                // a frame can overwrite vertices before the GPU consumes earlier draws.
                guard let vertexBuffer = device.makeBuffer(
                    bytes: baseAddress,
                    length: buffer.count,
                    options: [.storageModeShared]
                ) else {
                    return
                }

                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            }

            encoder.drawPrimitives(type: primitiveType, vertexStart: 0, vertexCount: vertices.count)
        }
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

    private func recordFrameRate() {
        let currentTime = CFAbsoluteTimeGetCurrent()
        if let previousFrameTime {
            let frameInterval = currentTime - previousFrameTime
            if frameInterval > 0, frameInterval < 0.25 {
                frameIntervalCount += 1
                frameIntervalSum += frameInterval
                frameIntervalSquareSum += frameInterval * frameInterval
                worstFrameInterval = max(worstFrameInterval, frameInterval)
            }
        }

        previousFrameTime = currentTime
        frameRateFrameCount += 1

        let elapsedTime = currentTime - frameRateWindowStartTime
        guard elapsedTime >= 0.25 else {
            return
        }

        let framesPerSecond = Int((Double(frameRateFrameCount) / elapsedTime).rounded())
        let measuredFrameRate = max(Double(framesPerSecond), 1)
        visualPlaybackFrameRate =
            visualPlaybackFrameRate * (1 - visualPlaybackFrameRateSmoothing) +
            measuredFrameRate * visualPlaybackFrameRateSmoothing

        let averageFrameInterval = frameIntervalCount > 0 ?
            frameIntervalSum / Double(frameIntervalCount) :
            0
        let averageSquareFrameInterval = frameIntervalCount > 0 ?
            frameIntervalSquareSum / Double(frameIntervalCount) :
            0
        let frameIntervalVariance = max(
            averageSquareFrameInterval - averageFrameInterval * averageFrameInterval,
            0
        )
        let frameStats = TimelineFrameStats(
            framesPerSecond: framesPerSecond,
            averageFrameTimeMilliseconds: averageFrameInterval * 1_000,
            frameTimeJitterMilliseconds: sqrt(frameIntervalVariance) * 1_000,
            worstFrameTimeMilliseconds: worstFrameInterval * 1_000
        )

        frameRateWindowStartTime = currentTime
        frameRateFrameCount = 0
        frameIntervalCount = 0
        frameIntervalSum = 0
        frameIntervalSquareSum = 0
        worstFrameInterval = 0
        onFrameStatsChanged?(frameStats)
    }

    private func cachedGridVertices(
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState
    ) -> CachedVertexBuffer? {
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
            viewportStart: renderState.viewport.startProgress,
            viewportDuration: renderState.viewport.durationProgress
        )
        if let gridCache, gridCache.key == key {
            return gridCache.vertices
        }

        guard let vertices = makeCachedBuffer(
            vertices: makeGridVertices(
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: renderState
            )
        ) else {
            gridCache = nil
            return nil
        }

        let nextCache = GridCache(key: key, vertices: vertices)
        gridCache = nextCache
        return nextCache.vertices
    }

    private func cachedWaveformVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState
    ) -> CachedVertexBuffer? {
        guard
            let mipLevel = waveformMipLevel(for: drawableSize, renderState: renderState),
            !mipLevel.overview.isEmpty
        else {
            waveformCache = nil
            return nil
        }

        let key = waveformCacheKey(
            drawableSize: drawableSize,
            mipLevel: mipLevel,
            renderState: renderState
        )
        if let waveformCache, waveformCache.key == key {
            return waveformCache.vertices
        }

        guard let vertices = makeCachedBuffer(
            vertices: makeWaveformVertices(
                drawableSize: drawableSize,
                mipLevel: mipLevel,
                renderState: renderState
            )
        ) else {
            waveformCache = nil
            return nil
        }

        let nextCache = WaveformCache(key: key, vertices: vertices)
        waveformCache = nextCache
        return nextCache.vertices
    }

    private func waveformCacheKey(
        drawableSize: CGSize,
        mipLevel: WaveformMipLevel,
        renderState: TimelineRenderState
    ) -> WaveformCacheKey {
        let gainSelectionStart: Float
        let gainSelectionEnd: Float
        let gain: Float
        if let gainPreview = renderState.gainPreview {
            gainSelectionStart = gainPreview.selection.startProgress
            gainSelectionEnd = gainPreview.selection.endProgress
            gain = gainPreview.gain
        } else {
            gainSelectionStart = -1
            gainSelectionEnd = -1
            gain = 1
        }

        return WaveformCacheKey(
            width: Float(drawableSize.width),
            viewportStart: renderState.viewport.startProgress,
            viewportDuration: renderState.viewport.durationProgress,
            mipBinCount: mipLevel.binCount,
            gainSelectionStart: gainSelectionStart,
            gainSelectionEnd: gainSelectionEnd,
            gain: gain
        )
    }

    private func makeGridVertices(
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState
    ) -> [TimelineVertex] {
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
        let viewport = renderState.viewport

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

    private func makeSelectionVertices(renderState: TimelineRenderState) -> [TimelineVertex] {
        guard
            let selection = renderState.selection,
            renderState.waveformOverview != nil,
            selection.durationProgress > 0.001
        else {
            return []
        }

        let viewport = renderState.viewport
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

    private func makeWaveformVertices(
        drawableSize: CGSize,
        mipLevel: WaveformMipLevel,
        renderState: TimelineRenderState
    ) -> [TimelineVertex] {
        let centerY: Float = 0.5
        let amplitudeHeight: Float = 0.42
        let minimumVisualHeight: Float = 0.008
        let color = SIMD4<Float>(0.70, 0.72, 0.72, 1.0)
        let bins = mipLevel.overview.bins
        let binCount = bins.count
        let viewport = renderState.viewport
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

            let gain = previewGain(forBinStart: timelineX0, end: timelineX1, renderState: renderState)
            var y0 = centerY - clampAudioSample(bin.maximumSample * gain) * amplitudeHeight
            var y1 = centerY - clampAudioSample(bin.minimumSample * gain) * amplitudeHeight

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

    private func previewGain(forBinStart binStart: Float, end binEnd: Float, renderState: TimelineRenderState) -> Float {
        guard let gainPreview = renderState.gainPreview else {
            return 1
        }

        let selection = gainPreview.selection
        guard binEnd > selection.startProgress, binStart < selection.endProgress else {
            return 1
        }

        return gainPreview.gain
    }

    private func clampAudioSample(_ sample: Float) -> Float {
        min(max(sample, -1), 1)
    }

    private func makePlayheadTouchVertices(
        drawableSize: CGSize,
        playheadProgress: Float,
        renderState: TimelineRenderState
    ) -> [TimelineVertex] {
        guard
            let mipLevel = waveformMipLevel(for: drawableSize, renderState: renderState),
            !mipLevel.overview.isEmpty
        else {
            return []
        }

        let bins = mipLevel.overview.bins
        let binCount = bins.count
        let centerY: Float = 0.5
        let amplitudeHeight: Float = 0.42
        let minimumVisualHeight: Float = 0.004
        let touchEnergy = currentPlayheadTouchEnergy(isPlaybackActive: renderState.isPlaybackActive)
        let clampedPlayhead = playheadProgress
        let touchRadius = playheadTouchRadiusProgress(forDuration: mipLevel.overview.duration)
        let coreRadius = max(touchRadius * 0.42, .ulpOfOne)
        let viewport = renderState.viewport
        let visibleTouchStart = max(clampedPlayhead - touchRadius, viewport.startProgress)
        let visibleTouchEnd = min(clampedPlayhead + touchRadius, viewport.endProgress)
        let startIndex = max(Int(floor(visibleTouchStart * Float(binCount))) - 1, 0)
        let endIndex = min(Int(ceil(visibleTouchEnd * Float(binCount))) + 1, binCount)

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

            let binCenter = (timelineX0 + timelineX1) * 0.5
            let distance = abs(binCenter - clampedPlayhead)
            let influence = contactFalloff(1 - min(distance / touchRadius, 1))
            let coreInfluence = contactCoreFalloff(1 - min(distance / coreRadius, 1))
            guard influence > 0.001 else {
                continue
            }

            let geometryInfluence = max(influence, coreInfluence) * touchEnergy
            let expansion = 1 + 0.22 * geometryInfluence
            var y0 = centerY - bin.maximumSample * amplitudeHeight * expansion
            var y1 = centerY - bin.minimumSample * amplitudeHeight * expansion

            if y1 - y0 < minimumVisualHeight {
                let midpoint = (y0 + y1) * 0.5
                let visualHeight = minimumVisualHeight + 0.014 * geometryInfluence
                y0 = midpoint - visualHeight * 0.5
                y1 = midpoint + visualHeight * 0.5
            }

            let baseColor = SIMD3<Float>(0.70, 0.72, 0.72)
            let whiteColor = SIMD3<Float>(1.0, 1.0, 1.0)
            let colorInfluence = max(influence, coreInfluence)
            let blendedColor = baseColor + (whiteColor - baseColor) * colorInfluence
            let color = SIMD4<Float>(
                blendedColor.x,
                blendedColor.y,
                blendedColor.z,
                0.12 + 0.88 * colorInfluence
            )

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

    private func playheadTouchRadiusProgress(forDuration duration: TimeInterval) -> Float {
        guard duration.isFinite, duration > 0 else {
            return 0.014
        }

        return min(max(Float(playheadTouchRadiusDuration / duration), .ulpOfOne), 1)
    }

    private func currentPlayheadProgress(renderState: TimelineRenderState) -> Float {
        let clampedProgress = min(max(renderState.playheadProgress, 0), 1)
        guard
            renderState.isPlaybackActive,
            let duration = renderState.waveformOverview?.duration,
            duration.isFinite,
            duration > 0
        else {
            return clampedProgress
        }

        let currentVisualProgress = visualPlayheadProgress ?? clampedProgress
        let frameRate = max(visualPlaybackFrameRate, 1)
        let frameProgress = Float(1 / (duration * frameRate))
        let nextVisualProgress = min(max(currentVisualProgress + frameProgress, 0), 1)
        visualPlayheadProgress = nextVisualProgress
        return nextVisualProgress
    }

    private func currentPlayheadTouchEnergy(isPlaybackActive: Bool) -> Float {
        updatePlayheadTouchEnergy(isPlaybackActive: isPlaybackActive)
        return playheadTouchEnergy
    }

    private func updatePlayheadTouchEnergy(isPlaybackActive: Bool) {
        let currentTime = CFAbsoluteTimeGetCurrent()
        defer {
            lastPlayheadTouchEnergyUpdateTime = currentTime
        }

        guard !isPlaybackActive else {
            playheadTouchEnergy = 1
            return
        }

        let elapsedTime = currentTime - lastPlayheadTouchEnergyUpdateTime
        guard elapsedTime > 0 else {
            return
        }

        let decayAmount = Float(elapsedTime / playheadTouchDecayDuration)
        playheadTouchEnergy = max(playheadTouchEnergy - decayAmount, 0)
    }

    private func currentPlayheadKickEnergy() -> Float {
        updatePlayheadKickEnergy()
        return playheadKickEnergy
    }

    private func updatePlayheadKickEnergy() {
        let currentTime = CFAbsoluteTimeGetCurrent()
        defer {
            lastPlayheadKickEnergyUpdateTime = currentTime
        }

        let elapsedTime = currentTime - lastPlayheadKickEnergyUpdateTime
        guard elapsedTime > 0 else {
            return
        }

        let decayAmount = Float(elapsedTime / playheadKickDecayDuration)
        playheadKickEnergy = max(playheadKickEnergy - decayAmount, 0)
    }

    private func makeTrimPreviewVertices(
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState
    ) -> [TimelineVertex] {
        guard let waveformOverview = renderState.waveformOverview, !waveformOverview.isEmpty else {
            return []
        }

        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return []
        }

        let trimRange = renderState.trimPreview ?? TimelineTrimRange(startProgress: 0, endProgress: 1)
        let viewport = renderState.viewport
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

    private func makeHoverGuideVertices(
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState
    ) -> [TimelineVertex] {
        guard
            let hoverProgress = renderState.hoverProgress,
            renderState.waveformOverview != nil
        else {
            return []
        }

        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return []
        }

        let viewport = renderState.viewport
        let guideProgress = viewport.viewportProgress(forTimelineProgress: hoverProgress)
        guard guideProgress >= 0, guideProgress <= 1 else {
            return []
        }

        let guideX = pixelAligned(guideProgress * width, backingScale: backingScale)
        let guideWidth = pixelLength(backingScale: backingScale)
        let left = max(guideX - guideWidth * 0.5, 0)
        let right = min(left + guideWidth, width)
        let alpha: Float = renderState.isHoverGuideArmed ? 0.56 : 0.36
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

    private func makePlayheadVertices(
        drawableSize: CGSize,
        backingScale: Float,
        playheadProgress: Float,
        renderState: TimelineRenderState
    ) -> [TimelineVertex] {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return []
        }

        let playheadX: Float
        if renderState.waveformOverview == nil {
            playheadX = min(max(80, 0), width)
        } else {
            let playheadViewportProgress =
                renderState.viewport.viewportProgress(forTimelineProgress: playheadProgress)
            guard playheadViewportProgress >= 0, playheadViewportProgress <= 1 else {
                previousRenderedPlayheadX = nil
                previousRenderedPlayheadTime = nil
                return []
            }

            playheadX = min(max(playheadViewportProgress * width, 0), width)
        }
        let kickEnergy = currentPlayheadKickEnergy()
        let baseColor = SIMD3<Float>(0.0, 0.84, 0.78)
        let burstColor = SIMD3<Float>(0.025, 0.855, 0.795)
        let blendedColor = baseColor + (burstColor - baseColor) * kickEnergy
        let size = SIMD2<Float>(width, height)
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(60)

        if renderState.isPlaybackActive,
           let previousRenderedPlayheadX,
           let previousRenderedPlayheadTime
        {
            let currentTime = CFAbsoluteTimeGetCurrent()
            let elapsedTime = currentTime - previousRenderedPlayheadTime
            let movement = playheadX - previousRenderedPlayheadX
            if elapsedTime > 0, elapsedTime < 0.05, abs(movement) > 1, abs(movement) < width * 0.2 {
                let sweepPadding = pixelLength(0.75, backingScale: backingScale)
                let sweepLeft = min(previousRenderedPlayheadX, playheadX) - sweepPadding
                let sweepRight = max(previousRenderedPlayheadX, playheadX) + sweepPadding
                appendRectangle(
                    to: &vertices,
                    left: max(sweepLeft, 0),
                    right: min(sweepRight, width),
                    top: 0,
                    bottom: height,
                    color: SIMD4<Float>(
                        blendedColor.x,
                        blendedColor.y,
                        blendedColor.z,
                        min(max(abs(movement) / 18, 0.08), 0.18)
                    ),
                    drawableSize: size
                )
            }
        }

        if kickEnergy > 0.001 {
            let kickWidth = pixelLength(2 + 12 * kickEnergy, backingScale: backingScale)
            let kickLeftWidth = kickWidth * 0.42
            let kickRightWidth = kickWidth * 0.58
            appendSubpixelVerticalBand(
                to: &vertices,
                centerX: playheadX,
                leftWidth: kickLeftWidth,
                rightWidth: kickRightWidth,
                top: 0,
                bottom: height,
                color: SIMD4<Float>(
                    blendedColor.x,
                    blendedColor.y,
                    blendedColor.z,
                    0.52 * kickEnergy
                ),
                drawableSize: size,
                backingScale: backingScale
            )
        }

        let baseWidth = pixelLength(3.5, backingScale: backingScale)
        let halfBaseWidth = baseWidth * 0.5

        appendSubpixelVerticalBand(
            to: &vertices,
            centerX: playheadX,
            leftWidth: halfBaseWidth,
            rightWidth: halfBaseWidth,
            top: 0,
            bottom: height,
            color: SIMD4<Float>(blendedColor.x, blendedColor.y, blendedColor.z, 1.0),
            drawableSize: size,
            backingScale: backingScale
        )

        previousRenderedPlayheadX = playheadX
        previousRenderedPlayheadTime = CFAbsoluteTimeGetCurrent()
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

    private func waveformMipLevel(for drawableSize: CGSize, renderState: TimelineRenderState) -> WaveformMipLevel? {
        guard !waveformMipLevels.isEmpty else {
            return nil
        }

        let width = max(Float(drawableSize.width), 1)
        let targetVisibleBins = max(width * 1.6, 256)

        for mipLevel in waveformMipLevels {
            let visibleBins = Float(mipLevel.binCount) * renderState.viewport.durationProgress
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

    private func appendSubpixelVerticalBand(
        to vertices: inout [TimelineVertex],
        centerX: Float,
        leftWidth: Float,
        rightWidth: Float,
        top: Float,
        bottom: Float,
        color: SIMD4<Float>,
        drawableSize: SIMD2<Float>,
        backingScale: Float
    ) {
        let scale = max(backingScale, 1)
        let width = drawableSize.x
        guard width > 0, drawableSize.y > 0 else {
            return
        }

        let leftPixel = (centerX - leftWidth) * scale
        let rightPixel = (centerX + rightWidth) * scale
        let firstPixel = Int(floor(leftPixel))
        let lastPixel = Int(ceil(rightPixel))

        for pixel in firstPixel..<lastPixel {
            let pixelLeft = Float(pixel)
            let pixelRight = Float(pixel + 1)
            let coverage = min(rightPixel, pixelRight) - max(leftPixel, pixelLeft)
            guard coverage > 0 else {
                continue
            }

            let left = max(pixelLeft / scale, 0)
            let right = min(pixelRight / scale, width)
            guard right > left else {
                continue
            }

            appendRectangle(
                to: &vertices,
                left: left,
                right: right,
                top: top,
                bottom: bottom,
                color: SIMD4<Float>(
                    color.x,
                    color.y,
                    color.z,
                    color.w * min(max(coverage, 0), 1)
                ),
                drawableSize: drawableSize
            )
        }
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

    private func contactFalloff(_ value: Float) -> Float {
        let clampedValue = min(max(value, 0), 1)
        let smoothedValue = clampedValue * clampedValue * (3 - 2 * clampedValue)
        return smoothedValue * smoothedValue
    }

    private func contactCoreFalloff(_ value: Float) -> Float {
        let clampedValue = min(max(value, 0), 1)
        return clampedValue * clampedValue
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

extension TimelineRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let renderPassDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable
        else {
            return
        }

        render(to: TimelineRenderTarget(
            renderPassDescriptor: renderPassDescriptor,
            drawable: drawable,
            viewportSize: view.bounds.size,
            backingScale: backingScale(for: view)
        ))
    }
}
