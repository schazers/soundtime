import Foundation
import Metal
import QuartzCore
import simd

struct TimelineFrameStats: Equatable, Sendable {
    let framesPerSecond: Int
    let averageFrameTimeMilliseconds: Double
    let frameTimeJitterMilliseconds: Double
    let worstFrameTimeMilliseconds: Double
}

struct TimelineRenderTarget: @unchecked Sendable {
    let renderPassDescriptor: MTLRenderPassDescriptor
    let drawable: MTLDrawable
    let viewportSize: CGSize
    let backingScale: Float
    let displayTimestamp: CFTimeInterval
}

final class TimelineRenderer: NSObject, @unchecked Sendable {
    private struct TimelineVertex {
        var position: SIMD4<Float>
        var color: SIMD4<Float>
    }

    private enum RendererError: Error {
        case commandQueueUnavailable
        case shaderFunctionUnavailable
        case dynamicVertexBufferUnavailable
    }

    private struct CachedVertexBuffer: @unchecked Sendable {
        let buffer: MTLBuffer
        let vertexCount: Int
    }

    private struct WaveformMipLevel: Sendable {
        let overview: WaveformOverview
        let binCount: Int
    }

    private struct WaveformMipCacheKey: Hashable {
        let trackID: UUID
        let waveformVersion: Int
        let binCount: Int
        let duration: TimeInterval
    }

    private struct GridCacheKey: Equatable {
        let width: Float
        let height: Float
        let backingScale: Float
        let viewportStart: Float
        let viewportDuration: Float
        let trackCount: Int
    }

    private struct GridCache {
        let key: GridCacheKey
        let vertices: CachedVertexBuffer
    }

    private struct WaveformCacheKey: Hashable {
        let width: Float
        let viewportStart: Float
        let viewportDuration: Float
        let mipBinCount: Int
        let gainSelectionStart: Float
        let gainSelectionEnd: Float
        let gain: Float
        let waveformBaseGray: Float
        let trackSignature: Int
    }

    private struct WaveformCache: @unchecked Sendable {
        let key: WaveformCacheKey
        let contentSignature: Int
        let visualSignature: Int
        let vertices: CachedVertexBuffer
    }

    private enum WaveformGeometryTarget: Sendable {
        case current
        case previous
    }

    private struct PlayheadContactEvent {
        let centerY: Float
        let laneTop: Float
        let laneBottom: Float
        let strength: Float
        let timestamp: CFTimeInterval
    }

    private final class TimelineRenderStateStore {
        private let lock = NSLock()
        private var currentState: TimelineRenderState

        init(initialState: TimelineRenderState) {
            currentState = initialState
        }

        func publish(_ state: TimelineRenderState) {
            lock.lock()
            defer {
                lock.unlock()
            }
            currentState = state
        }

        func snapshot() -> TimelineRenderState {
            lock.lock()
            defer {
                lock.unlock()
            }
            let state = currentState
            return state
        }
    }

    private final class DynamicVertexBufferRing {
        private let buffers: [MTLBuffer]
        private let capacity: Int
        private let alignment: Int
        private var bufferIndex = 0
        private var writeOffset = 0

        init?(
            device: MTLDevice,
            bufferCount: Int,
            capacity: Int,
            alignment: Int
        ) {
            guard bufferCount > 0, capacity > 0, alignment > 0 else {
                return nil
            }

            var buffers: [MTLBuffer] = []
            buffers.reserveCapacity(bufferCount)
            for index in 0..<bufferCount {
                guard let buffer = device.makeBuffer(
                    length: capacity,
                    options: [.storageModeShared, .cpuCacheModeWriteCombined]
                ) else {
                    return nil
                }
                buffer.label = "Timeline dynamic vertices \(index)"
                buffers.append(buffer)
            }

            self.buffers = buffers
            self.capacity = capacity
            self.alignment = alignment
        }

        func beginFrame() {
            bufferIndex = (bufferIndex + 1) % buffers.count
            writeOffset = 0
        }

        func stage(_ bytes: UnsafeRawBufferPointer) -> (buffer: MTLBuffer, offset: Int)? {
            guard let baseAddress = bytes.baseAddress, bytes.count > 0 else {
                return nil
            }

            let offset = aligned(writeOffset)
            guard offset + bytes.count <= capacity else {
                return nil
            }

            let buffer = buffers[bufferIndex]
            buffer.contents()
                .advanced(by: offset)
                .copyMemory(from: baseAddress, byteCount: bytes.count)
            writeOffset = offset + bytes.count
            return (buffer, offset)
        }

        private func aligned(_ offset: Int) -> Int {
            let remainder = offset % alignment
            guard remainder != 0 else {
                return offset
            }

            return offset + alignment - remainder
        }
    }

    private final class WaveformGeometryStore: @unchecked Sendable {
        private let lock = NSLock()
        private var currentCache: WaveformCache?
        private var previousCache: WaveformCache?
        private var currentInFlightKey: WaveformCacheKey?
        private var previousInFlightKey: WaveformCacheKey?
        private var currentGeneration = 0
        private var previousGeneration = 0

        func cache(for key: WaveformCacheKey, target: WaveformGeometryTarget) -> WaveformCache? {
            lock.lock()
            defer {
                lock.unlock()
            }

            switch target {
            case .current:
                return currentCache?.key == key ? currentCache : nil
            case .previous:
                return previousCache?.key == key ? previousCache : nil
            }
        }

        func fallback(
            contentSignature: Int,
            visualSignature: Int,
            target: WaveformGeometryTarget
        ) -> WaveformCache? {
            lock.lock()
            defer {
                lock.unlock()
            }

            switch target {
            case .current:
                guard
                    currentCache?.contentSignature == contentSignature,
                    currentCache?.visualSignature == visualSignature
                else {
                    return nil
                }
                return currentCache
            case .previous:
                guard
                    previousCache?.contentSignature == contentSignature,
                    previousCache?.visualSignature == visualSignature
                else {
                    return nil
                }
                return previousCache
            }
        }

        func beginPreparing(key: WaveformCacheKey, target: WaveformGeometryTarget) -> Int? {
            lock.lock()
            defer {
                lock.unlock()
            }

            switch target {
            case .current:
                guard currentCache?.key != key, currentInFlightKey == nil else {
                    return nil
                }
                currentInFlightKey = key
                return currentGeneration
            case .previous:
                guard previousCache?.key != key, previousInFlightKey == nil else {
                    return nil
                }
                previousInFlightKey = key
                return previousGeneration
            }
        }

        func publish(
            _ cache: WaveformCache?,
            key: WaveformCacheKey,
            target: WaveformGeometryTarget,
            generation: Int
        ) -> Bool {
            lock.lock()
            defer {
                lock.unlock()
            }

            switch target {
            case .current:
                guard generation == currentGeneration else {
                    return false
                }
                if currentInFlightKey == key {
                    currentInFlightKey = nil
                }
                if let cache {
                    currentCache = cache
                }
                return true
            case .previous:
                guard generation == previousGeneration else {
                    return false
                }
                if previousInFlightKey == key {
                    previousInFlightKey = nil
                }
                if let cache {
                    previousCache = cache
                }
                return true
            }
        }

        func promoteCurrentToPrevious() {
            lock.lock()
            previousCache = currentCache
            previousInFlightKey = nil
            previousGeneration += 1
            lock.unlock()
        }

        func clearCurrent() {
            lock.lock()
            currentCache = nil
            currentInFlightKey = nil
            currentGeneration += 1
            lock.unlock()
        }

        func clearPrevious() {
            lock.lock()
            previousCache = nil
            previousInFlightKey = nil
            previousGeneration += 1
            lock.unlock()
        }
    }

    private static let dynamicVertexBufferCount = 6
    private static let dynamicVertexBufferCapacity = 4 * 1_024 * 1_024
    private static let dynamicVertexBufferAlignment = 256

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let dynamicVertexBufferRing: DynamicVertexBufferRing
    private let waveformGeometryQueue = DispatchQueue(
        label: "Soundtime.timeline.waveform.geometry",
        qos: .userInitiated
    )
    private let waveformGeometryStore = WaveformGeometryStore()
    private let renderStateStore = TimelineRenderStateStore(initialState: .empty)
    private var renderState = TimelineRenderState.empty {
        didSet {
            renderStateStore.publish(renderState)
        }
    }
    private var waveformMipLevels: [WaveformMipLevel] = []
    private var trackWaveformMipLevels: [UUID: [WaveformMipLevel]] = [:]
    private var previousTrackWaveformMipLevels: [UUID: [WaveformMipLevel]] = [:]
    private var previousTransitionTracks: [TimelineRenderState.Track] = []
    private var waveformMipLevelCache: [WaveformMipCacheKey: [WaveformMipLevel]] = [:]
    private var gridCache: GridCache?
    private var waveformTransitionStartTime: CFTimeInterval?
    private var previousRenderedPlayheadX: Float?
    private var previousRenderedPlayheadTime: CFTimeInterval?
    private var playheadTouchEnergy: Float = 0
    private var lastPlayheadTouchEnergyUpdateTime = CFAbsoluteTimeGetCurrent()
    private var playheadTouchPlayStartProgress: Float?
    private var playheadKickEnergy: Float = 0
    private var playheadKickOriginProgress: Float?
    private var playheadKickStartTime = CFAbsoluteTimeGetCurrent()
    private var lastPlayheadKickEnergyUpdateTime = CFAbsoluteTimeGetCurrent()
    private var playheadContactEvents: [PlayheadContactEvent] = []
    private var frameRateWindowStartTime = CFAbsoluteTimeGetCurrent()
    private var previousFrameTime: CFTimeInterval?
    private var frameRateFrameCount = 0
    private var frameIntervalCount = 0
    private var frameIntervalSum: Double = 0
    private var frameIntervalSquareSum: Double = 0
    private var worstFrameInterval: Double = 0
    var onFrameStatsChanged: ((TimelineFrameStats) -> Void)?
    var onRenderDataPrepared: (() -> Void)?
    private let playheadTouchGeometryAheadDuration: TimeInterval = 0.055
    private let playheadTouchLightAheadDuration: TimeInterval = 0.08
    private var playheadTouchTrailDuration: TimeInterval = 0.44
    private var playheadTouchTrailFalloffSteepness: Float = 2.11
    private var waveformBaseGray: Float = 0.88
    private let waveformTransitionDuration: CFTimeInterval = 0.2
    private let playheadTouchDecayDuration: CFTimeInterval = 0.046
    private let playheadKickDecayDuration: CFTimeInterval = 0.3
    private let playheadKickTrailDuration: CFTimeInterval = 0.38
    private let playheadKickTrailLineCount = 10
    private let playheadContactFadeDuration: CFTimeInterval = 0.6
    private let playheadContactMaximumEventCount = 1_024
    private let maximumCachedWaveformMipPyramids = 12

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw RendererError.commandQueueUnavailable
        }
        guard let dynamicVertexBufferRing = DynamicVertexBufferRing(
            device: device,
            bufferCount: Self.dynamicVertexBufferCount,
            capacity: Self.dynamicVertexBufferCapacity,
            alignment: Self.dynamicVertexBufferAlignment
        ) else {
            throw RendererError.dynamicVertexBufferUnavailable
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
        self.dynamicVertexBufferRing = dynamicVertexBufferRing
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        super.init()
    }

    func displayWaveform(_ waveformOverview: WaveformOverview?) {
        let trackID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
        let tracks = waveformOverview.map {
            [TimelineRenderState.Track(
                id: trackID,
                waveformVersion: 0,
                waveformOverview: $0,
                volume: 1,
                isMuted: false,
                isSoloed: false
            )]
        } ?? []
        displayTracks(tracks)
    }

    func displayTracks(_ tracks: [TimelineRenderState.Track]) {
        let previousTracks = renderState.tracks
        let nextTrackWaveformMipLevels = Dictionary(
            uniqueKeysWithValues: tracks.map { track in
                (track.id, cachedWaveformMipLevels(for: track))
            }
        )
        let nextWaveformMipLevels = tracks.first.flatMap { nextTrackWaveformMipLevels[$0.id] } ?? []
        if renderState.hasWaveforms, tracks.contains(where: { $0.waveformOverview?.isEmpty == false }) {
            previousTrackWaveformMipLevels = trackWaveformMipLevels
            previousTransitionTracks = previousTracks
            waveformGeometryStore.promoteCurrentToPrevious()
            waveformTransitionStartTime = nil
        } else {
            previousTrackWaveformMipLevels = [:]
            previousTransitionTracks = []
            waveformGeometryStore.clearPrevious()
            waveformTransitionStartTime = nil
        }

        waveformMipLevels = nextWaveformMipLevels
        trackWaveformMipLevels = nextTrackWaveformMipLevels
        gridCache = nil
        waveformGeometryStore.clearCurrent()
        playheadContactEvents.removeAll()
        previousRenderedPlayheadX = nil
        previousRenderedPlayheadTime = nil
        renderState = renderState.withTracks(tracks)
    }

    func displayTrackMixSettings(_ tracks: [TimelineRenderState.Track]) {
        renderState = renderState.withTracks(tracks)
        waveformGeometryStore.clearCurrent()
        waveformGeometryStore.clearPrevious()
        previousTrackWaveformMipLevels = [:]
        previousTransitionTracks = []
        waveformTransitionStartTime = nil
    }

    func updateWaveformTouchTuning(
        trailDuration: TimeInterval,
        trailFalloffSteepness: Float,
        waveformGray: Float
    ) {
        let nextTrailDuration = min(max(trailDuration, 0.05), 1.2)
        let nextTrailFalloffSteepness = min(max(trailFalloffSteepness, 0.25), 4)
        let nextWaveformGray = min(max(waveformGray, 0.45), 0.98)

        playheadTouchTrailDuration = nextTrailDuration
        playheadTouchTrailFalloffSteepness = nextTrailFalloffSteepness
        waveformBaseGray = nextWaveformGray
    }

    func displayPlayheadProgress(
        _ progress: Float,
        force: Bool = true,
        anchorTimestamp: CFTimeInterval? = nil
    ) {
        let currentTime = anchorTimestamp ?? CACurrentMediaTime()
        let clampedProgress = min(max(progress, 0), 1)
        if renderState.isPlaybackActive, !force {
            if anchorTimestamp != nil {
                renderState = renderState.withPlayheadProgress(
                    clampedProgress,
                    anchorTimestamp: currentTime
                )
            }
            return
        }

        let anchoredProgress: Float
        if
            renderState.isPlaybackActive,
            anchorTimestamp == nil,
            let projectedProgress = projectedPlayheadProgress(at: currentTime),
            let duration = renderState.duration,
            duration.isFinite,
            duration > 0
        {
            let backwardCorrection = projectedProgress - clampedProgress
            let maximumSilentCorrection = Float(0.12 / duration)
            if backwardCorrection > 0, backwardCorrection <= maximumSilentCorrection {
                anchoredProgress = projectedProgress
            } else {
                anchoredProgress = clampedProgress
            }
        } else {
            anchoredProgress = clampedProgress
        }

        renderState = renderState.withPlayheadProgress(anchoredProgress, anchorTimestamp: currentTime)
        if force {
            playheadTouchPlayStartProgress = anchoredProgress
        }
        previousRenderedPlayheadX = nil
        previousRenderedPlayheadTime = nil
    }

    func displayPlaybackActive(_ isActive: Bool) {
        let currentTime = CACurrentMediaTime()
        updatePlayheadTouchEnergy(isPlaybackActive: renderState.isPlaybackActive)
        updatePlayheadKickEnergy()
        let wasPlaybackActive = renderState.isPlaybackActive

        if wasPlaybackActive != isActive {
            let anchoredProgress = projectedPlayheadProgress(at: currentTime) ??
                renderState.playheadProgress
            renderState = renderState
                .withPlayheadProgress(anchoredProgress, anchorTimestamp: currentTime)
                .withPlaybackActive(isActive)
            previousRenderedPlayheadX = nil
            previousRenderedPlayheadTime = nil
            if isActive {
                playheadTouchPlayStartProgress = anchoredProgress
                playheadContactEvents.removeAll()
            }
        } else {
            renderState = renderState.withPlaybackActive(isActive)
        }

        if isActive {
            playheadTouchEnergy = 1
            if !wasPlaybackActive {
                playheadKickEnergy = 1
                playheadKickOriginProgress = renderState.playheadProgress
                playheadKickStartTime = CFAbsoluteTimeGetCurrent()
            }
        }
    }

    func displayViewport(_ viewport: TimelineViewport) {
        guard renderState.viewport != viewport else {
            return
        }

        gridCache = nil
        previousRenderedPlayheadX = nil
        previousRenderedPlayheadTime = nil
        renderState = renderState.withViewport(viewport)
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
    }

    func render(to target: TimelineRenderTarget) {
        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: target.renderPassDescriptor)
        else {
            return
        }

        dynamicVertexBufferRing.beginFrame()
        encodeTimeline(
            into: encoder,
            viewportSize: target.viewportSize,
            backingScale: target.backingScale,
            displayTimestamp: target.displayTimestamp
        )
        encoder.endEncoding()

        commandBuffer.present(target.drawable)
        commandBuffer.commit()
    }

    private func encodeTimeline(
        into encoder: MTLRenderCommandEncoder,
        viewportSize: CGSize,
        backingScale: Float,
        displayTimestamp: CFTimeInterval
    ) {
        recordFrameRate()
        let renderState = renderStateStore.snapshot()
        let renderedPlayheadProgress = currentPlayheadProgress(
            renderState: renderState,
            displayTimestamp: displayTimestamp
        )
        let selectionVertices = makeSelectionVertices(renderState: renderState)
        let waveformVertices = cachedWaveformVertices(drawableSize: viewportSize, renderState: renderState)
        let previousWaveformVertices = hasPreviousWaveformTransition ?
            cachedPreviousWaveformVertices(drawableSize: viewportSize, renderState: renderState) :
            nil
        let waveformTransitionOpacities = waveformTransitionOpacities(
            at: displayTimestamp,
            hasCurrent: waveformVertices != nil,
            hasPrevious: previousWaveformVertices != nil
        )
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
            renderState: renderState,
            displayTimestamp: displayTimestamp
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
        if let previousWaveformVertices {
            draw(
                cachedVertices: previousWaveformVertices,
                primitiveType: .triangle,
                encoder: encoder,
                opacity: waveformTransitionOpacities.previous
            )
        }
        if let waveformVertices {
            draw(
                cachedVertices: waveformVertices,
                primitiveType: .triangle,
                encoder: encoder,
                opacity: waveformTransitionOpacities.current
            )
        }
        draw(vertices: playheadTouchVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: trimPreviewVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: hoverGuideVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: playheadVertices, primitiveType: .triangle, encoder: encoder)
    }

    private func draw(
        cachedVertices: CachedVertexBuffer,
        primitiveType: MTLPrimitiveType,
        encoder: MTLRenderCommandEncoder,
        opacity: Float = 1
    ) {
        guard cachedVertices.vertexCount > 0 else {
            return
        }

        setFragmentOpacity(opacity, encoder: encoder)
        encoder.setVertexBuffer(cachedVertices.buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: primitiveType, vertexStart: 0, vertexCount: cachedVertices.vertexCount)
    }

    private func draw(
        vertices: [TimelineVertex],
        primitiveType: MTLPrimitiveType,
        encoder: MTLRenderCommandEncoder,
        opacity: Float = 1
    ) {
        guard !vertices.isEmpty else {
            return
        }

        setFragmentOpacity(opacity, encoder: encoder)
        vertices.withUnsafeBytes { buffer in
            if let stagedVertices = dynamicVertexBufferRing.stage(buffer) {
                encoder.setVertexBuffer(stagedVertices.buffer, offset: stagedVertices.offset, index: 0)
            } else {
                guard
                    let baseAddress = buffer.baseAddress,
                    let vertexBuffer = device.makeBuffer(
                        bytes: baseAddress,
                        length: buffer.count,
                        options: [.storageModeShared, .cpuCacheModeWriteCombined]
                    )
                else {
                    return
                }

                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            }

            encoder.drawPrimitives(type: primitiveType, vertexStart: 0, vertexCount: vertices.count)
        }
    }

    private var hasPreviousWaveformTransition: Bool {
        !previousTrackWaveformMipLevels.isEmpty && !previousTransitionTracks.isEmpty
    }

    private func waveformTransitionOpacities(
        at displayTimestamp: CFTimeInterval,
        hasCurrent: Bool,
        hasPrevious: Bool
    ) -> (
        current: Float,
        previous: Float
    ) {
        guard hasPreviousWaveformTransition, hasPrevious else {
            return (current: 1, previous: 0)
        }
        guard hasCurrent else {
            return (current: 0, previous: 1)
        }

        if waveformTransitionStartTime == nil {
            waveformTransitionStartTime = displayTimestamp
        }
        guard let waveformTransitionStartTime else {
            return (current: 0, previous: 1)
        }

        let rawProgress = min(
            max((displayTimestamp - waveformTransitionStartTime) / waveformTransitionDuration, 0),
            1
        )
        guard rawProgress < 1 else {
            previousTrackWaveformMipLevels = [:]
            previousTransitionTracks = []
            waveformGeometryStore.clearPrevious()
            self.waveformTransitionStartTime = nil
            return (current: 1, previous: 0)
        }

        let progress = Float(rawProgress)
        let easedProgress = progress * progress * (3 - 2 * progress)
        return (current: easedProgress, previous: 1 - easedProgress)
    }

    private func setFragmentOpacity(_ opacity: Float, encoder: MTLRenderCommandEncoder) {
        var fragmentOpacity = min(max(opacity, 0), 1)
        encoder.setFragmentBytes(
            &fragmentOpacity,
            length: MemoryLayout<Float>.stride,
            index: 1
        )
    }

    private func makeCachedBuffer(vertices: [TimelineVertex]) -> CachedVertexBuffer? {
        guard !vertices.isEmpty else {
            guard let vertexBuffer = device.makeBuffer(
                length: MemoryLayout<TimelineVertex>.stride,
                options: [.storageModeShared]
            ) else {
                return nil
            }

            return CachedVertexBuffer(buffer: vertexBuffer, vertexCount: 0)
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
        guard let previousFrameTime else {
            resetFrameRateWindow(startingAt: currentTime)
            self.previousFrameTime = currentTime
            frameRateFrameCount = 1
            return
        }

        let frameInterval = currentTime - previousFrameTime
        guard frameInterval < 0.25 else {
            resetFrameRateWindow(startingAt: currentTime)
            self.previousFrameTime = currentTime
            frameRateFrameCount = 1
            return
        }

        if frameInterval > 0 {
            frameIntervalCount += 1
            frameIntervalSum += frameInterval
            frameIntervalSquareSum += frameInterval * frameInterval
            worstFrameInterval = max(worstFrameInterval, frameInterval)
        }

        self.previousFrameTime = currentTime
        frameRateFrameCount += 1

        let elapsedTime = currentTime - frameRateWindowStartTime
        guard elapsedTime >= 0.5 else {
            return
        }

        let framesPerSecond = Int((Double(frameRateFrameCount) / elapsedTime).rounded())
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

    private func resetFrameRateWindow(startingAt currentTime: CFTimeInterval) {
        frameRateWindowStartTime = currentTime
        frameRateFrameCount = 0
        frameIntervalCount = 0
        frameIntervalSum = 0
        frameIntervalSquareSum = 0
        worstFrameInterval = 0
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
            viewportDuration: renderState.viewport.durationProgress,
            trackCount: max(renderState.tracks.count, 1)
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
        cachedWaveformVertices(
            drawableSize: drawableSize,
            renderState: renderState,
            mipLevels: waveformMipLevels,
            trackWaveformMipLevels: trackWaveformMipLevels,
            target: .current,
            usesTrackLanes: true
        )
    }

    private func cachedPreviousWaveformVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState
    ) -> CachedVertexBuffer? {
        let previousTracks = previousTransitionTracks(withCurrentMixFrom: renderState.tracks)
        guard !previousTracks.isEmpty else {
            return nil
        }

        let previousRenderState = renderState.replacingTracks(previousTracks)
        return cachedWaveformVertices(
            drawableSize: drawableSize,
            renderState: previousRenderState,
            mipLevels: [],
            trackWaveformMipLevels: previousTrackWaveformMipLevels,
            target: .previous,
            usesTrackLanes: true
        )
    }

    private func previousTransitionTracks(
        withCurrentMixFrom currentTracks: [TimelineRenderState.Track]
    ) -> [TimelineRenderState.Track] {
        let currentMixByID = Dictionary(uniqueKeysWithValues: currentTracks.map { ($0.id, $0) })
        return previousTransitionTracks.map { previousTrack in
            let currentTrack = currentMixByID[previousTrack.id]
            return TimelineRenderState.Track(
                id: previousTrack.id,
                waveformVersion: previousTrack.waveformVersion,
                waveformOverview: previousTrack.waveformOverview,
                volume: currentTrack?.volume ?? previousTrack.volume,
                isMuted: currentTrack?.isMuted ?? previousTrack.isMuted,
                isSoloed: currentTrack?.isSoloed ?? previousTrack.isSoloed
            )
        }
    }

    private func cachedWaveformVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        mipLevels: [WaveformMipLevel],
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]],
        target: WaveformGeometryTarget,
        usesTrackLanes: Bool
    ) -> CachedVertexBuffer? {
        if usesTrackLanes, renderState.hasWaveforms {
            let mipBinSignature = selectedTrackMipBinSignature(
                drawableSize: drawableSize,
                renderState: renderState,
                trackWaveformMipLevels: trackWaveformMipLevels
            )
            let key = waveformCacheKey(
                drawableSize: drawableSize,
                mipBinCount: mipBinSignature,
                renderState: renderState
            )

            if let cache = waveformGeometryStore.cache(for: key, target: target) {
                return cache.vertices
            }

            let contentSignature = waveformContentSignature(renderState: renderState)
            let visualSignature = waveformVisualSignature(renderState: renderState)
            prepareWaveformGeometry(
                key: key,
                contentSignature: contentSignature,
                visualSignature: visualSignature,
                target: target,
                drawableSize: drawableSize,
                renderState: renderState,
                mipLevel: nil,
                trackWaveformMipLevels: trackWaveformMipLevels,
                usesTrackLanes: true
            )
            return waveformGeometryStore.fallback(
                contentSignature: contentSignature,
                visualSignature: visualSignature,
                target: target
            )?.vertices
        }

        guard
            let mipLevel = waveformMipLevel(
                for: drawableSize,
                renderState: renderState,
                mipLevels: mipLevels
            ),
            !mipLevel.overview.isEmpty
        else {
            return nil
        }

        let key = waveformCacheKey(
            drawableSize: drawableSize,
            mipLevel: mipLevel,
            renderState: renderState
        )

        if let cache = waveformGeometryStore.cache(for: key, target: target) {
            return cache.vertices
        }

        let contentSignature = waveformContentSignature(renderState: renderState)
        let visualSignature = waveformVisualSignature(renderState: renderState)
        prepareWaveformGeometry(
            key: key,
            contentSignature: contentSignature,
            visualSignature: visualSignature,
            target: target,
            drawableSize: drawableSize,
            renderState: renderState,
            mipLevel: mipLevel,
            trackWaveformMipLevels: trackWaveformMipLevels,
            usesTrackLanes: false
        )
        return waveformGeometryStore.fallback(
            contentSignature: contentSignature,
            visualSignature: visualSignature,
            target: target
        )?.vertices
    }

    private func prepareWaveformGeometry(
        key: WaveformCacheKey,
        contentSignature: Int,
        visualSignature: Int,
        target: WaveformGeometryTarget,
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        mipLevel: WaveformMipLevel?,
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]],
        usesTrackLanes: Bool
    ) {
        guard let generation = waveformGeometryStore.beginPreparing(key: key, target: target) else {
            return
        }

        let waveformBaseGray = waveformBaseGray
        waveformGeometryQueue.async { [weak self] in
            guard let self else {
                return
            }

            let rawVertices: [TimelineVertex]
            if usesTrackLanes {
                rawVertices = self.makeTrackWaveformVertices(
                    drawableSize: drawableSize,
                    renderState: renderState,
                    trackWaveformMipLevels: trackWaveformMipLevels,
                    waveformBaseGray: waveformBaseGray
                )
            } else if let mipLevel {
                rawVertices = self.makeWaveformVertices(
                    drawableSize: drawableSize,
                    mipLevel: mipLevel,
                    renderState: renderState,
                    waveformBaseGray: waveformBaseGray
                )
            } else {
                rawVertices = []
            }

            let cachedVertices = self.makeCachedBuffer(vertices: rawVertices)
            let cache = cachedVertices.map {
                WaveformCache(
                    key: key,
                    contentSignature: contentSignature,
                    visualSignature: visualSignature,
                    vertices: $0
                )
            }
            let didPublish = self.waveformGeometryStore.publish(
                cache,
                key: key,
                target: target,
                generation: generation
            )
            if didPublish {
                self.onRenderDataPrepared?()
            }
        }
    }

    private func waveformCacheKey(
        drawableSize: CGSize,
        mipLevel: WaveformMipLevel,
        renderState: TimelineRenderState
    ) -> WaveformCacheKey {
        waveformCacheKey(
            drawableSize: drawableSize,
            mipBinCount: mipLevel.binCount,
            renderState: renderState
        )
    }

    private func waveformCacheKey(
        drawableSize: CGSize,
        mipBinCount: Int,
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
            mipBinCount: mipBinCount,
            gainSelectionStart: gainSelectionStart,
            gainSelectionEnd: gainSelectionEnd,
            gain: gain,
            waveformBaseGray: waveformBaseGray,
            trackSignature: trackSignature(renderState: renderState)
        )
    }

    private func waveformContentSignature(renderState: TimelineRenderState) -> Int {
        var hasher = Hasher()
        for track in renderState.tracks {
            hasher.combine(track.id)
            hasher.combine(track.waveformVersion)
            hasher.combine(track.waveformOverview?.bins.count ?? 0)
            hasher.combine(track.waveformOverview?.duration ?? 0)
        }
        return hasher.finalize()
    }

    private func waveformVisualSignature(renderState: TimelineRenderState) -> Int {
        var hasher = Hasher()
        hasher.combine(waveformBaseGray)
        if let gainPreview = renderState.gainPreview {
            hasher.combine(gainPreview.selection.startProgress)
            hasher.combine(gainPreview.selection.endProgress)
            hasher.combine(gainPreview.gain)
        } else {
            hasher.combine(-1 as Float)
            hasher.combine(-1 as Float)
            hasher.combine(1 as Float)
        }

        for track in renderState.tracks {
            hasher.combine(track.id)
            hasher.combine(track.volume)
            hasher.combine(track.isMuted)
            hasher.combine(track.isSoloed)
        }
        return hasher.finalize()
    }

    private func trackSignature(renderState: TimelineRenderState) -> Int {
        var hasher = Hasher()
        for track in renderState.tracks {
            hasher.combine(track.id)
            hasher.combine(track.waveformVersion)
            hasher.combine(track.waveformOverview?.bins.count ?? 0)
            hasher.combine(track.waveformOverview?.duration ?? 0)
            hasher.combine(track.volume)
            hasher.combine(track.isMuted)
            hasher.combine(track.isSoloed)
        }
        return hasher.finalize()
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

        let trackCount = max(renderState.tracks.count, 1)
        let laneHeight = height / Float(trackCount)
        for trackIndex in 0..<trackCount {
            let laneTop = Float(trackIndex) * laneHeight
            if trackIndex > 0 {
                let separatorY = pixelAligned(laneTop, backingScale: backingScale)
                appendRectangle(
                    to: &vertices,
                    left: 0,
                    right: width,
                    top: separatorY,
                    bottom: min(separatorY + lineWidth, height),
                    color: SIMD4<Float>(0.18, 0.19, 0.20, 1.0),
                    drawableSize: size
                )
            }

            let centerY = pixelAligned(laneTop + laneHeight * 0.5, backingScale: backingScale)
            appendRectangle(
                to: &vertices,
                left: 0,
                right: width,
                top: centerY,
                bottom: min(centerY + lineWidth, height),
                color: centerColor,
                drawableSize: size
            )
        }

        return vertices
    }

    private func makeSelectionVertices(renderState: TimelineRenderState) -> [TimelineVertex] {
        guard
            let selection = renderState.selection,
            renderState.hasWaveforms,
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
        makeWaveformVertices(
            drawableSize: drawableSize,
            mipLevel: mipLevel,
            renderState: renderState,
            waveformBaseGray: waveformBaseGray
        )
    }

    private func makeWaveformVertices(
        drawableSize: CGSize,
        mipLevel: WaveformMipLevel,
        renderState: TimelineRenderState,
        waveformBaseGray: Float
    ) -> [TimelineVertex] {
        let centerY: Float = 0.5
        let amplitudeHeight: Float = 0.42
        let minimumVisualHeight: Float = 0.008
        let color = SIMD4<Float>(waveformBaseGray, waveformBaseGray, waveformBaseGray, 1.0)
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

    private func makeTrackWaveformVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState
    ) -> [TimelineVertex] {
        makeTrackWaveformVertices(
            drawableSize: drawableSize,
            renderState: renderState,
            trackWaveformMipLevels: trackWaveformMipLevels,
            waveformBaseGray: waveformBaseGray
        )
    }

    private func makeTrackWaveformVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]],
        waveformBaseGray: Float
    ) -> [TimelineVertex] {
        let tracks = renderState.tracks
        let trackCount = tracks.count
        guard
            trackCount > 0,
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0
        else {
            return []
        }

        let laneHeight = Float(1) / Float(trackCount)
        let minimumVisualHeight = laneHeight * 0.006
        let anySolo = tracks.contains { $0.isSoloed }
        var vertices: [TimelineVertex] = []

        for (trackIndex, track) in tracks.enumerated() {
            guard
                let overview = track.waveformOverview,
                !overview.isEmpty,
                let mipLevels = trackWaveformMipLevels[track.id],
                let mipLevel = waveformMipLevel(
                    for: drawableSize,
                    renderState: renderState,
                    mipLevels: mipLevels
                )
            else {
                continue
            }

            let bins = mipLevel.overview.bins
            let binCount = bins.count
            let trackDurationProgress = min(max(Float(overview.duration / projectDuration), 0), 1)
            guard binCount > 0, trackDurationProgress > 0 else {
                continue
            }

            let laneTop = Float(trackIndex) * laneHeight
            let laneBottom = laneTop + laneHeight
            let centerY = laneTop + laneHeight * 0.5
            let amplitudeHeight = laneHeight * 0.39 * min(max(track.volume, 0), 1.8)
            let isAudible = !track.isMuted && (!anySolo || track.isSoloed)
            let alpha: Float = isAudible ? 1.0 : 0.26
            let gray = waveformBaseGray * (isAudible ? 1.0 : 0.68)
            let color = SIMD4<Float>(gray, gray, gray, alpha)
            let startIndex = max(Int(floor(renderState.viewport.startProgress / trackDurationProgress * Float(binCount))) - 1, 0)
            let endIndex = min(Int(ceil(renderState.viewport.endProgress / trackDurationProgress * Float(binCount))) + 1, binCount)
            guard startIndex < endIndex else {
                continue
            }

            vertices.reserveCapacity(vertices.count + (endIndex - startIndex) * 6)
            for index in startIndex..<endIndex {
                let bin = bins[index]
                let localX0 = Float(index) / Float(binCount)
                let localX1 = Float(index + 1) / Float(binCount)
                let timelineX0 = localX0 * trackDurationProgress
                let timelineX1 = localX1 * trackDurationProgress
                let x0 = renderState.viewport.viewportProgress(forTimelineProgress: timelineX0)
                let x1 = renderState.viewport.viewportProgress(forTimelineProgress: timelineX1)
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
                    top: max(y0, laneTop),
                    bottom: min(y1, laneBottom),
                    color: color
                )
            }
        }

        return vertices
    }

    private func selectedTrackMipBinSignature(
        drawableSize: CGSize,
        renderState: TimelineRenderState
    ) -> Int {
        selectedTrackMipBinSignature(
            drawableSize: drawableSize,
            renderState: renderState,
            trackWaveformMipLevels: trackWaveformMipLevels
        )
    }

    private func selectedTrackMipBinSignature(
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]]
    ) -> Int {
        var hasher = Hasher()
        for track in renderState.tracks {
            hasher.combine(track.id)
            hasher.combine(trackWaveformMipLevels[track.id]?.count ?? 0)
            if let mipLevels = trackWaveformMipLevels[track.id],
               let mipLevel = waveformMipLevel(
                for: drawableSize,
                renderState: renderState,
                mipLevels: mipLevels
               )
            {
                hasher.combine(mipLevel.binCount)
            }
        }
        return hasher.finalize()
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
            renderState.hasWaveforms,
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0
        else {
            return []
        }

        let tracks = renderState.tracks
        let trackCount = tracks.count
        guard trackCount > 0 else {
            return []
        }

        let laneHeight = Float(1) / Float(trackCount)
        let touchEnergy = currentPlayheadTouchEnergy(isPlaybackActive: renderState.isPlaybackActive)
        let clampedPlayhead = playheadProgress
        let geometryAheadRadius = playheadTouchGeometryAheadRadiusProgress(forDuration: projectDuration)
        let lightAheadRadius = playheadTouchLightAheadRadiusProgress(forDuration: projectDuration)
        let trailRadius = playheadTouchTrailRadiusProgress(forDuration: projectDuration)
        let viewport = renderState.viewport
        let playthroughTrailStart = playheadTouchPlayStartProgress.map {
            min(max($0, 0), clampedPlayhead)
        }
        let visibleTouchStart = max(
            clampedPlayhead - trailRadius,
            playthroughTrailStart ?? 0,
            viewport.startProgress
        )
        let visibleTouchEnd = min(
            clampedPlayhead + max(geometryAheadRadius, lightAheadRadius),
            viewport.endProgress
        )

        guard visibleTouchStart < visibleTouchEnd else {
            return []
        }

        var vertices: [TimelineVertex] = []
        let anySolo = tracks.contains { $0.isSoloed }

        for (trackIndex, track) in tracks.enumerated() {
            guard
                let overview = track.waveformOverview,
                !overview.isEmpty,
                let mipLevels = trackWaveformMipLevels[track.id],
                let mipLevel = waveformMipLevel(
                    for: drawableSize,
                    renderState: renderState,
                    mipLevels: mipLevels
                )
            else {
                continue
            }

            let bins = mipLevel.overview.bins
            let binCount = bins.count
            let trackDurationProgress = min(max(Float(overview.duration / projectDuration), 0), 1)
            guard binCount > 0, trackDurationProgress > 0 else {
                continue
            }

            let trackVisibleTouchStart = max(visibleTouchStart, 0)
            let trackVisibleTouchEnd = min(visibleTouchEnd, trackDurationProgress)
            guard trackVisibleTouchStart < trackVisibleTouchEnd else {
                continue
            }

            let laneTop = Float(trackIndex) * laneHeight
            let laneBottom = laneTop + laneHeight
            let centerY = laneTop + laneHeight * 0.5
            let amplitudeHeight = laneHeight * 0.39 * min(max(track.volume, 0), 1.8)
            let minimumVisualHeight = laneHeight * 0.004
            let isAudible = !track.isMuted && (!anySolo || track.isSoloed)
            let audibleEnergy = touchEnergy * (isAudible ? 1 : 0.22)
            let startIndex = max(
                Int(floor(trackVisibleTouchStart / trackDurationProgress * Float(binCount))) - 1,
                0
            )
            let endIndex = min(
                Int(ceil(trackVisibleTouchEnd / trackDurationProgress * Float(binCount))) + 1,
                binCount
            )
            guard startIndex < endIndex else {
                continue
            }

            vertices.reserveCapacity(vertices.count + (endIndex - startIndex) * 6)
            for index in startIndex..<endIndex {
                let bin = bins[index]
                let localX0 = Float(index) / Float(binCount)
                let localX1 = Float(index + 1) / Float(binCount)
                let timelineX0 = localX0 * trackDurationProgress
                let timelineX1 = localX1 * trackDurationProgress
                let x0 = viewport.viewportProgress(forTimelineProgress: timelineX0)
                let x1 = viewport.viewportProgress(forTimelineProgress: timelineX1)
                guard x1 > 0, x0 < 1 else {
                    continue
                }

                let binCenter = (timelineX0 + timelineX1) * 0.5
                if let playthroughTrailStart, binCenter < playthroughTrailStart {
                    continue
                }

                let geometryInfluenceRaw = playheadTouchGeometryInfluence(
                    offsetFromPlayhead: binCenter - clampedPlayhead,
                    aheadRadius: geometryAheadRadius,
                    trailRadius: trailRadius
                )
                let lightInfluenceRaw = playheadTouchLightInfluence(
                    offsetFromPlayhead: binCenter - clampedPlayhead,
                    aheadRadius: lightAheadRadius,
                    trailRadius: trailRadius
                )
                guard max(geometryInfluenceRaw, lightInfluenceRaw) > 0.001 else {
                    continue
                }

                let geometryInfluence = geometryInfluenceRaw * audibleEnergy
                let expansion = 1 + 0.22 * geometryInfluence
                let gain = previewGain(forBinStart: timelineX0, end: timelineX1, renderState: renderState)
                var y0 = centerY - clampAudioSample(bin.maximumSample * gain) * amplitudeHeight * expansion
                var y1 = centerY - clampAudioSample(bin.minimumSample * gain) * amplitudeHeight * expansion

                if y1 - y0 < minimumVisualHeight {
                    let midpoint = (y0 + y1) * 0.5
                    let visualHeight = minimumVisualHeight + laneHeight * 0.014 * geometryInfluence
                    y0 = midpoint - visualHeight * 0.5
                    y1 = midpoint + visualHeight * 0.5
                }

                let baseGray = waveformBaseGray * (isAudible ? 1 : 0.68)
                let baseColor = SIMD3<Float>(baseGray, baseGray, baseGray)
                let whiteColor = SIMD3<Float>(1.0, 1.0, 1.0)
                let colorInfluence = lightInfluenceRaw * audibleEnergy
                let blendedColor = baseColor + (whiteColor - baseColor) * colorInfluence
                let color = SIMD4<Float>(
                    blendedColor.x,
                    blendedColor.y,
                    blendedColor.z,
                    (0.12 + 0.88 * colorInfluence) * audibleEnergy
                )

                appendRectangle(
                    to: &vertices,
                    left: max(x0, 0),
                    right: min(x1, 1),
                    top: max(y0, laneTop),
                    bottom: min(y1, laneBottom),
                    color: color
                )
            }
        }

        return vertices
    }

    private func playheadTouchGeometryAheadRadiusProgress(forDuration duration: TimeInterval) -> Float {
        guard duration.isFinite, duration > 0 else {
            return 0.002
        }

        return min(max(Float(playheadTouchGeometryAheadDuration / duration), .ulpOfOne), 1)
    }

    private func playheadTouchLightAheadRadiusProgress(forDuration duration: TimeInterval) -> Float {
        guard duration.isFinite, duration > 0 else {
            return 0.003
        }

        return min(max(Float(playheadTouchLightAheadDuration / duration), .ulpOfOne), 1)
    }

    private func playheadTouchTrailRadiusProgress(forDuration duration: TimeInterval) -> Float {
        guard duration.isFinite, duration > 0 else {
            return 0.018
        }

        return min(max(Float(playheadTouchTrailDuration / duration), .ulpOfOne), 1)
    }

    func projectedPlayheadProgress(at displayTimestamp: CFTimeInterval) -> Float? {
        projectedPlayheadProgress(at: displayTimestamp, renderState: renderStateStore.snapshot())
    }

    private func currentPlayheadProgress(
        renderState: TimelineRenderState,
        displayTimestamp: CFTimeInterval
    ) -> Float {
        projectedPlayheadProgress(at: displayTimestamp, renderState: renderState) ??
            min(max(renderState.playheadProgress, 0), 1)
    }

    private func projectedPlayheadProgress(
        at displayTimestamp: CFTimeInterval,
        renderState: TimelineRenderState
    ) -> Float? {
        let clampedProgress = min(max(renderState.playheadProgress, 0), 1)
        guard
            renderState.isPlaybackActive,
            let duration = renderState.duration,
            duration.isFinite,
            duration > 0
        else {
            return clampedProgress
        }

        let elapsedTime = displayTimestamp - renderState.playheadAnchorTimestamp
        let progress = clampedProgress + Float(elapsedTime / duration)
        return min(max(progress, 0), 1)
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
        if playheadTouchEnergy == 0 {
            playheadTouchPlayStartProgress = nil
        }
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
        guard renderState.hasWaveforms else {
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
            renderState.hasWaveforms
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
        renderState: TimelineRenderState,
        displayTimestamp: CFTimeInterval
    ) -> [TimelineVertex] {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return []
        }

        let playheadX: Float
        if !renderState.hasWaveforms {
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
        let baseColor = SIMD3<Float>(0.0, 0.75, 0.78)
        let burstColor = SIMD3<Float>(0.0, 0.62, 0.86)
        let blendedColor = baseColor + (burstColor - baseColor) * kickEnergy
        let size = SIMD2<Float>(width, height)
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(90)
        let baseWidth = pixelLength(3.5, backingScale: backingScale)
        let halfBaseWidth = baseWidth * 0.5
        updatePlayheadContactEvents(
            playheadProgress: playheadProgress,
            renderState: renderState,
            displayTimestamp: displayTimestamp
        )

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

        if
            renderState.isPlaybackActive,
            kickEnergy > 0.001,
            let playheadKickOriginProgress,
            renderState.hasWaveforms
        {
            let originViewportProgress =
                renderState.viewport.viewportProgress(forTimelineProgress: playheadKickOriginProgress)
            if originViewportProgress >= 0, originViewportProgress <= 1 {
                let originX = min(max(originViewportProgress * width, 0), width)
                let trailDistance = playheadX - originX
                let trailAge = max(CFAbsoluteTimeGetCurrent() - playheadKickStartTime, 0)
                let trailProgress = min(max(Float(trailAge / playheadKickTrailDuration), 0), 1)
                let easedTrailEnergy = 1 - trailProgress * trailProgress * (3 - 2 * trailProgress)
                if easedTrailEnergy > 0.001 {
                    appendSubpixelVerticalBand(
                        to: &vertices,
                        centerX: originX,
                        leftWidth: halfBaseWidth,
                        rightWidth: halfBaseWidth,
                        top: 0,
                        bottom: height,
                        color: SIMD4<Float>(
                            baseColor.x,
                            baseColor.y,
                            baseColor.z,
                            0.38 * easedTrailEnergy
                        ),
                        drawableSize: size,
                        backingScale: backingScale
                    )
                }

                if easedTrailEnergy > 0.001, abs(trailDistance) > halfBaseWidth {
                    let distanceLineCount = max(1, Int(abs(trailDistance) / max(baseWidth * 1.8, 1)))
                    let lineCount = min(playheadKickTrailLineCount, distanceLineCount)

                    for lineIndex in 0..<lineCount {
                        let fraction = Float(lineIndex + 1) / Float(lineCount + 1)
                        let trailX = originX + trailDistance * fraction
                        let tailFalloff = 1 - fraction
                        let alpha = 0.28 * easedTrailEnergy * tailFalloff * tailFalloff
                        appendSubpixelVerticalBand(
                            to: &vertices,
                            centerX: trailX,
                            leftWidth: halfBaseWidth,
                            rightWidth: halfBaseWidth,
                            top: 0,
                            bottom: height,
                            color: SIMD4<Float>(
                                baseColor.x,
                                baseColor.y,
                                baseColor.z,
                                alpha
                            ),
                            drawableSize: size,
                            backingScale: backingScale
                        )
                    }
                }
            }
        }

        if kickEnergy > 0.001 {
            let kickWidth = pixelLength(2 + 16 * kickEnergy, backingScale: backingScale)
            let kickHalfWidth = kickWidth * 0.5
            appendSubpixelVerticalBand(
                to: &vertices,
                centerX: playheadX,
                leftWidth: kickHalfWidth,
                rightWidth: kickHalfWidth,
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

        appendPlayheadContactVertices(
            to: &vertices,
            playheadX: playheadX,
            lineHalfWidth: halfBaseWidth,
            drawableSize: size,
            backingScale: backingScale,
            displayTimestamp: displayTimestamp
        )

        previousRenderedPlayheadX = playheadX
        previousRenderedPlayheadTime = CFAbsoluteTimeGetCurrent()
        return vertices
    }

    private func updatePlayheadContactEvents(
        playheadProgress: Float,
        renderState: TimelineRenderState,
        displayTimestamp: CFTimeInterval
    ) {
        playheadContactEvents.removeAll { event in
            displayTimestamp - event.timestamp >= playheadContactFadeDuration
        }

        guard
            renderState.isPlaybackActive,
            let contacts = playheadWaveformContacts(
                at: playheadProgress,
                renderState: renderState
            )
        else {
            return
        }

        playheadContactEvents.append(contentsOf: contacts.map { contact in
            PlayheadContactEvent(
                centerY: contact.centerY,
                laneTop: contact.laneTop,
                laneBottom: contact.laneBottom,
                strength: contact.strength,
                timestamp: displayTimestamp
            )
        })

        if playheadContactEvents.count > playheadContactMaximumEventCount {
            playheadContactEvents.removeFirst(playheadContactEvents.count - playheadContactMaximumEventCount)
        }
    }

    private func playheadWaveformContacts(
        at playheadProgress: Float,
        renderState: TimelineRenderState
    ) -> [(centerY: Float, laneTop: Float, laneBottom: Float, strength: Float)]? {
        guard
            renderState.hasWaveforms,
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0
        else {
            return nil
        }

        let tracks = renderState.tracks
        let trackCount = tracks.count
        guard trackCount > 0 else {
            return nil
        }

        let clampedProgress = min(max(playheadProgress, 0), 1)
        let laneHeight = Float(1) / Float(trackCount)
        let anySolo = tracks.contains { $0.isSoloed }
        var contacts: [(centerY: Float, laneTop: Float, laneBottom: Float, strength: Float)] = []
        contacts.reserveCapacity(trackCount * 2)

        for (trackIndex, track) in tracks.enumerated() {
            guard !track.isMuted, !anySolo || track.isSoloed else {
                continue
            }

            guard
                let overview = track.waveformOverview,
                !overview.isEmpty,
                let mipLevel = trackWaveformMipLevels[track.id]?.first,
                !mipLevel.overview.isEmpty
            else {
                continue
            }

            let trackDurationProgress = min(max(Float(overview.duration / projectDuration), 0), 1)
            guard clampedProgress <= trackDurationProgress, trackDurationProgress > 0 else {
                continue
            }

            let bins = mipLevel.overview.bins
            let binCount = bins.count
            guard binCount > 0 else {
                continue
            }

            let localProgress = min(max(clampedProgress / trackDurationProgress, 0), 1)
            let index = min(max(Int((localProgress * Float(binCount)).rounded(.down)), 0), binCount - 1)
            let bin = bins[index]
            let localX0 = Float(index) / Float(binCount)
            let localX1 = Float(index + 1) / Float(binCount)
            let timelineX0 = localX0 * trackDurationProgress
            let timelineX1 = localX1 * trackDurationProgress
            let gain = previewGain(forBinStart: timelineX0, end: timelineX1, renderState: renderState)
            let minimumSample = clampAudioSample(bin.minimumSample * gain)
            let maximumSample = clampAudioSample(bin.maximumSample * gain)
            let laneTop = Float(trackIndex) * laneHeight
            let laneBottom = laneTop + laneHeight
            let centerY = laneTop + laneHeight * 0.5
            let amplitudeHeight = laneHeight * 0.39 * min(max(track.volume, 0), 1.8)
            let topY = min(max(centerY - maximumSample * amplitudeHeight, laneTop), laneBottom)
            let bottomY = min(max(centerY - minimumSample * amplitudeHeight, laneTop), laneBottom)
            let amplitude = max(abs(minimumSample), abs(maximumSample))
            let strength = min(max(0.38 + amplitude * 0.62, 0), 1)

            if abs(bottomY - topY) < laneHeight * 0.012 {
                contacts.append((
                    centerY: min(max((topY + bottomY) * 0.5, laneTop), laneBottom),
                    laneTop: laneTop,
                    laneBottom: laneBottom,
                    strength: strength
                ))
            } else {
                contacts.append((
                    centerY: topY,
                    laneTop: laneTop,
                    laneBottom: laneBottom,
                    strength: strength
                ))
                contacts.append((
                    centerY: bottomY,
                    laneTop: laneTop,
                    laneBottom: laneBottom,
                    strength: strength
                ))
            }
        }

        return contacts.isEmpty ? nil : contacts
    }

    private func appendPlayheadContactVertices(
        to vertices: inout [TimelineVertex],
        playheadX: Float,
        lineHalfWidth: Float,
        drawableSize: SIMD2<Float>,
        backingScale: Float,
        displayTimestamp: CFTimeInterval
    ) {
        guard !playheadContactEvents.isEmpty, drawableSize.y > 0 else {
            return
        }

        let haloFadeDistance = pixelLength(42, backingScale: backingScale)
        let coreFadeDistance = pixelLength(18, backingScale: backingScale)
        let haloHalfWidth = lineHalfWidth + pixelLength(1.25, backingScale: backingScale)
        for event in playheadContactEvents {
            let age = max(displayTimestamp - event.timestamp, 0)
            let progress = min(max(Float(age / playheadContactFadeDuration), 0), 1)
            let remaining = 1 - progress
            let easedEnergy = remaining * remaining * (3 - 2 * remaining)
            guard easedEnergy > 0.001 else {
                continue
            }

            let laneTop = min(max(event.laneTop * drawableSize.y, 0), drawableSize.y)
            let laneBottom = min(max(event.laneBottom * drawableSize.y, laneTop), drawableSize.y)
            guard laneBottom > laneTop else {
                continue
            }

            let centerY = min(max(event.centerY * drawableSize.y, laneTop), laneBottom)
            let mirrorY = min(max(laneTop + laneBottom - centerY, laneTop), laneBottom)
            let spanTop = min(centerY, mirrorY)
            let spanBottom = max(centerY, mirrorY)
            let haloAlpha = min(0.075 * easedEnergy * event.strength, 0.11)
            let contactColor = SIMD3<Float>(0.0, 0.92, 0.88)
            let transparentContactColor = SIMD4<Float>(
                contactColor.x,
                contactColor.y,
                contactColor.z,
                0
            )
            let haloColor = SIMD4<Float>(
                contactColor.x,
                contactColor.y,
                contactColor.z,
                haloAlpha
            )
            appendSubpixelVerticalBand(
                to: &vertices,
                centerX: playheadX,
                leftWidth: haloHalfWidth,
                rightWidth: haloHalfWidth,
                top: spanTop,
                bottom: spanBottom,
                color: haloColor,
                drawableSize: drawableSize,
                backingScale: backingScale
            )
            appendSubpixelVerticalGradientBand(
                to: &vertices,
                centerX: playheadX,
                leftWidth: haloHalfWidth,
                rightWidth: haloHalfWidth,
                top: max(spanTop - haloFadeDistance, laneTop),
                bottom: spanTop,
                topColor: transparentContactColor,
                bottomColor: haloColor,
                drawableSize: drawableSize,
                backingScale: backingScale
            )
            appendSubpixelVerticalGradientBand(
                to: &vertices,
                centerX: playheadX,
                leftWidth: haloHalfWidth,
                rightWidth: haloHalfWidth,
                top: spanBottom,
                bottom: min(spanBottom + haloFadeDistance, laneBottom),
                topColor: haloColor,
                bottomColor: transparentContactColor,
                drawableSize: drawableSize,
                backingScale: backingScale
            )

            let coreAlpha = min(0.16 * easedEnergy * event.strength, 0.22)
            let coreColor = SIMD4<Float>(
                contactColor.x,
                contactColor.y,
                contactColor.z,
                coreAlpha
            )
            appendSubpixelVerticalBand(
                to: &vertices,
                centerX: playheadX,
                leftWidth: lineHalfWidth,
                rightWidth: lineHalfWidth,
                top: spanTop,
                bottom: spanBottom,
                color: coreColor,
                drawableSize: drawableSize,
                backingScale: backingScale
            )
            appendSubpixelVerticalGradientBand(
                to: &vertices,
                centerX: playheadX,
                leftWidth: lineHalfWidth,
                rightWidth: lineHalfWidth,
                top: max(spanTop - coreFadeDistance, laneTop),
                bottom: spanTop,
                topColor: transparentContactColor,
                bottomColor: coreColor,
                drawableSize: drawableSize,
                backingScale: backingScale
            )
            appendSubpixelVerticalGradientBand(
                to: &vertices,
                centerX: playheadX,
                leftWidth: lineHalfWidth,
                rightWidth: lineHalfWidth,
                top: spanBottom,
                bottom: min(spanBottom + coreFadeDistance, laneBottom),
                topColor: coreColor,
                bottomColor: transparentContactColor,
                drawableSize: drawableSize,
                backingScale: backingScale
            )
        }
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

    private func cachedWaveformMipLevels(for track: TimelineRenderState.Track) -> [WaveformMipLevel] {
        guard let waveformOverview = track.waveformOverview, !waveformOverview.isEmpty else {
            return []
        }

        let key = WaveformMipCacheKey(
            trackID: track.id,
            waveformVersion: track.waveformVersion,
            binCount: waveformOverview.bins.count,
            duration: waveformOverview.duration
        )
        if let cachedLevels = waveformMipLevelCache[key] {
            return cachedLevels
        }

        if waveformMipLevelCache.count >= maximumCachedWaveformMipPyramids {
            waveformMipLevelCache.removeAll(keepingCapacity: true)
        }

        let levels = makeWaveformMipLevels(from: waveformOverview)
        waveformMipLevelCache[key] = levels
        return levels
    }

    private func waveformMipLevel(for drawableSize: CGSize, renderState: TimelineRenderState) -> WaveformMipLevel? {
        waveformMipLevel(
            for: drawableSize,
            renderState: renderState,
            mipLevels: waveformMipLevels
        )
    }

    private func waveformMipLevel(
        for drawableSize: CGSize,
        renderState: TimelineRenderState,
        mipLevels: [WaveformMipLevel]
    ) -> WaveformMipLevel? {
        guard !mipLevels.isEmpty else {
            return nil
        }

        let width = max(Float(drawableSize.width), 1)
        let targetVisibleBins = max(width * 1.6, 256)

        for mipLevel in mipLevels {
            let visibleBins = Float(mipLevel.binCount) * renderState.viewport.durationProgress
            if visibleBins <= targetVisibleBins {
                return mipLevel
            }
        }

        return mipLevels.last
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

    private func appendVerticalGradientRectangle(
        to vertices: inout [TimelineVertex],
        left: Float,
        right: Float,
        top: Float,
        bottom: Float,
        topColor: SIMD4<Float>,
        bottomColor: SIMD4<Float>,
        drawableSize: SIMD2<Float>
    ) {
        guard
            drawableSize.x > 0,
            drawableSize.y > 0,
            right > left,
            bottom > top
        else {
            return
        }

        let normalizedLeft = left / drawableSize.x
        let normalizedRight = right / drawableSize.x
        let normalizedTop = top / drawableSize.y
        let normalizedBottom = bottom / drawableSize.y
        let topLeft = makeVertex(
            normalizedPosition: SIMD2<Float>(normalizedLeft, normalizedTop),
            color: topColor
        )
        let topRight = makeVertex(
            normalizedPosition: SIMD2<Float>(normalizedRight, normalizedTop),
            color: topColor
        )
        let bottomLeft = makeVertex(
            normalizedPosition: SIMD2<Float>(normalizedLeft, normalizedBottom),
            color: bottomColor
        )
        let bottomRight = makeVertex(
            normalizedPosition: SIMD2<Float>(normalizedRight, normalizedBottom),
            color: bottomColor
        )

        vertices.append(topLeft)
        vertices.append(topRight)
        vertices.append(bottomLeft)
        vertices.append(topRight)
        vertices.append(bottomRight)
        vertices.append(bottomLeft)
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

    private func appendSubpixelVerticalGradientBand(
        to vertices: inout [TimelineVertex],
        centerX: Float,
        leftWidth: Float,
        rightWidth: Float,
        top: Float,
        bottom: Float,
        topColor: SIMD4<Float>,
        bottomColor: SIMD4<Float>,
        drawableSize: SIMD2<Float>,
        backingScale: Float
    ) {
        let scale = max(backingScale, 1)
        let width = drawableSize.x
        guard width > 0, drawableSize.y > 0, bottom > top else {
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

            let clampedCoverage = min(max(coverage, 0), 1)
            appendVerticalGradientRectangle(
                to: &vertices,
                left: left,
                right: right,
                top: top,
                bottom: bottom,
                topColor: SIMD4<Float>(
                    topColor.x,
                    topColor.y,
                    topColor.z,
                    topColor.w * clampedCoverage
                ),
                bottomColor: SIMD4<Float>(
                    bottomColor.x,
                    bottomColor.y,
                    bottomColor.z,
                    bottomColor.w * clampedCoverage
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

    private func playheadTouchGeometryInfluence(
        offsetFromPlayhead: Float,
        aheadRadius: Float,
        trailRadius: Float
    ) -> Float {
        if offsetFromPlayhead >= 0 {
            let proximity = 1 - min(offsetFromPlayhead / max(aheadRadius, .ulpOfOne), 1)
            return contactAheadGeometryFalloff(proximity)
        }

        let proximity = 1 - min(abs(offsetFromPlayhead) / max(trailRadius, .ulpOfOne), 1)
        return contactTrailFalloff(proximity)
    }

    private func playheadTouchLightInfluence(
        offsetFromPlayhead: Float,
        aheadRadius: Float,
        trailRadius: Float
    ) -> Float {
        if offsetFromPlayhead >= 0 {
            let proximity = 1 - min(offsetFromPlayhead / max(aheadRadius, .ulpOfOne), 1)
            return contactAheadLightFalloff(proximity)
        }

        let proximity = 1 - min(abs(offsetFromPlayhead) / max(trailRadius, .ulpOfOne), 1)
        return contactTrailFalloff(proximity)
    }

    private func contactAheadGeometryFalloff(_ value: Float) -> Float {
        let clampedValue = min(max(value, 0), 1)
        let squaredValue = clampedValue * clampedValue
        return squaredValue * squaredValue
    }

    private func contactAheadLightFalloff(_ value: Float) -> Float {
        let clampedValue = min(max(value, 0), 1)
        return clampedValue * clampedValue
    }

    private func contactTrailFalloff(_ value: Float) -> Float {
        let clampedValue = min(max(value, 0), 1)
        let smoothedValue = clampedValue * clampedValue * (3 - 2 * clampedValue)
        return Float(pow(Double(smoothedValue), Double(playheadTouchTrailFalloffSteepness)))
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

    fragment float4 timeline_fragment(
        RasterizedVertex in [[stage_in]],
        constant float &opacity [[buffer(1)]]
    ) {
        return float4(in.color.rgb, in.color.a * opacity);
    }
    """
}
