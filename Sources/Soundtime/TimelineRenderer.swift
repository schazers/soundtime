import Foundation
@preconcurrency import Metal
import QuartzCore
import simd

struct TimelineFrameStats: Equatable, Sendable {
    let framesPerSecond: Int
    let averageFrameTimeMilliseconds: Double
    let frameTimeJitterMilliseconds: Double
    let worstFrameTimeMilliseconds: Double
    let waveformRenderer: String
    let cpuWaveformVertexCount: Int
    let gpuWaveformDrawCount: Int
    let shaderBufferUploadCount: Int
    let shaderBufferCount: Int
    let shaderBufferByteCount: Int
    let shaderBufferUploadInFlightCount: Int
    let waveformMipCacheCount: Int
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

    private struct WaveformShaderQuadVertex {
        var position: SIMD4<Float>
    }

    private struct WaveformShaderUniform {
        var baseColor: SIMD4<Float>
        var lane: SIMD4<Float>
        var track: SIMD4<Float>
        var viewport: SIMD4<Float>
        var style: SIMD4<Float>
        var style2: SIMD4<Float>
        var gainPreview: SIMD4<Float>
        var fisheye: SIMD4<Float>
        var touch: SIMD4<Float>
        var touch2: SIMD4<Float>
    }

    private struct WaveformShaderBin {
        var minimumSample: Float
        var maximumSample: Float
        var rmsSample: Float
        var lowEnergy: Float
        var midEnergy: Float
        var highEnergy: Float
        var peakMagnitude: Float
        var reserved: Float
    }

    private enum RendererError: Error {
        case commandQueueUnavailable
        case shaderFunctionUnavailable
        case dynamicVertexBufferUnavailable
        case waveformQuadBufferUnavailable
    }

    private struct CachedVertexBuffer: @unchecked Sendable {
        let buffer: MTLBuffer
        let vertexCount: Int
    }

    private struct WaveformMipLevel: Sendable {
        let overview: WaveformOverview
        let binCount: Int
    }

    private struct WaveformMipLevelSnapshot {
        let primary: [WaveformMipLevel]
        let currentByTrack: [UUID: [WaveformMipLevel]]
        let previousByTrack: [UUID: [WaveformMipLevel]]
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

    private struct WaveformDrawCache {
        let vertices: CachedVertexBuffer
        let xTransform: SIMD4<Float>
    }

    private struct WaveformShaderDrawable {
        let mipLevel: WaveformMipLevel
        let buffer: MTLBuffer
    }

    private enum WaveformShaderFallbackPolicy {
        case allowFallbacks
        case preferredOnly
    }

    private final class WaveformShaderBufferStore: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [WaveformMipCacheKey: MTLBuffer] = [:]
        private var accessTicks: [WaveformMipCacheKey: Int] = [:]
        private var accessTick = 0
        private var inFlightKeys: Set<WaveformMipCacheKey> = []
        private var totalBufferByteCount = 0
        private var publishedBufferCount = 0

        func buffer(for key: WaveformMipCacheKey) -> MTLBuffer? {
            lock.lock()
            defer {
                lock.unlock()
            }
            guard let buffer = buffers[key] else {
                return nil
            }

            markAccessed(key)
            return buffer
        }

        func beginPreparing(
            _ key: WaveformMipCacheKey,
            maximumInFlightCount: Int
        ) -> Bool {
            lock.lock()
            defer {
                lock.unlock()
            }

            guard
                buffers[key] == nil,
                !inFlightKeys.contains(key),
                inFlightKeys.count < max(maximumInFlightCount, 1)
            else {
                return false
            }
            inFlightKeys.insert(key)
            return true
        }

        func publish(_ buffer: MTLBuffer?, for key: WaveformMipCacheKey) {
            lock.lock()
            if let buffer {
                if let existingBuffer = buffers[key] {
                    totalBufferByteCount -= existingBuffer.length
                }
                buffers[key] = buffer
                markAccessed(key)
                totalBufferByteCount += buffer.length
                publishedBufferCount += 1
            }
            inFlightKeys.remove(key)
            lock.unlock()
        }

        func drainPublishedBufferCount() -> Int {
            lock.lock()
            let count = publishedBufferCount
            publishedBufferCount = 0
            lock.unlock()
            return count
        }

        func diagnostics() -> (bufferCount: Int, byteCount: Int, inFlightCount: Int) {
            lock.lock()
            defer {
                lock.unlock()
            }

            return (buffers.count, totalBufferByteCount, inFlightKeys.count)
        }

        func trim(toMaximumCount maximumCount: Int, maximumByteCount: Int) {
            lock.lock()
            let maximumCount = max(maximumCount, 1)
            let maximumByteCount = max(maximumByteCount, 1)
            while buffers.count > maximumCount || totalBufferByteCount > maximumByteCount {
                guard let oldestKey = buffers.keys.min(by: {
                    (accessTicks[$0] ?? 0) < (accessTicks[$1] ?? 0)
                }) else {
                    break
                }
                guard !inFlightKeys.contains(oldestKey) else {
                    accessTicks[oldestKey] = accessTick
                    continue
                }
                if let removedBuffer = buffers.removeValue(forKey: oldestKey) {
                    totalBufferByteCount -= removedBuffer.length
                    accessTicks.removeValue(forKey: oldestKey)
                }
            }
            lock.unlock()
        }

        private func markAccessed(_ key: WaveformMipCacheKey) {
            accessTick &+= 1
            accessTicks[key] = accessTick
        }
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

    private struct TransientParticle {
        let originProgress: Float
        let originY: Float
        let velocity: SIMD2<Float>
        let perpendicular: SIMD2<Float>
        let birthTimestamp: CFTimeInterval
        let lifeDuration: CFTimeInterval
        let radius: Float
        let strength: Float
        let spinPhase: Float
        let spinRate: Float
        let color: SIMD3<Float>
    }

    private struct TransientParticleScoreProfile {
        let threshold: Float
        let loudestScore: Float
    }

    private struct WaveformVisualStyle {
        let spectralAmount: Float
        let peakAlpha: Float
        let rmsAlpha: Float
        let glowAlpha: Float
        let transientAlpha: Float
        let transientThreshold: Float
        let centerLineAlpha: Float
        let glowExpansion: Float
    }

    private struct TrackFisheyeState {
        var currentEnergy: Float
        var startEnergy: Float
        var targetEnergy: Float
        var startTime: CFTimeInterval
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
            target: WaveformGeometryTarget
        ) -> WaveformCache? {
            lock.lock()
            defer {
                lock.unlock()
            }

            switch target {
            case .current:
                guard
                    currentCache?.contentSignature == contentSignature
                else {
                    return nil
                }
                return currentCache
            case .previous:
                guard
                    previousCache?.contentSignature == contentSignature
                else {
                    return nil
                }
                return previousCache
            }
        }

        func fallbackAny(target: WaveformGeometryTarget) -> WaveformCache? {
            lock.lock()
            defer {
                lock.unlock()
            }

            switch target {
            case .current:
                return currentCache
            case .previous:
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

        func cancelCurrentPreparationKeepingCache() {
            lock.lock()
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
    private static let identityXTransform = SIMD4<Float>(1, 0, 0, 0)

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let waveformPipelineState: MTLRenderPipelineState
    private let additivePipelineState: MTLRenderPipelineState
    private let dynamicVertexBufferRing: DynamicVertexBufferRing
    private let waveformQuadVertexBuffer: MTLBuffer
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
    private var isGPUWaveformRendererEnabled = true
    private var waveformMipLevels: [WaveformMipLevel] = []
    private var trackWaveformMipLevels: [UUID: [WaveformMipLevel]] = [:]
    private var previousTrackWaveformMipLevels: [UUID: [WaveformMipLevel]] = [:]
    private let waveformMipLevelStateLock = NSLock()
    private var currentTrackWaveformMipKeys: [UUID: WaveformMipCacheKey] = [:]
    private var currentPrimaryWaveformTrackID: UUID?
    private var previousTransitionTracks: [TimelineRenderState.Track] = []
    private var waveformMipLevelCache: [WaveformMipCacheKey: [WaveformMipLevel]] = [:]
    private var waveformMipLevelCacheOrder: [WaveformMipCacheKey] = []
    private var waveformMipLevelBuildsInFlight: Set<WaveformMipCacheKey> = []
    private let waveformMipLevelCacheLock = NSLock()
    private let waveformShaderBufferStore = WaveformShaderBufferStore()
    private var gridCache: GridCache?
    private var waveformTransitionStartTime: CFTimeInterval?
    private var previousRenderedPlayheadX: Float?
    private var previousRenderedPlayheadTime: CFTimeInterval?
    private var playheadTouchEnergy: Float = 0
    private var lastPlayheadTouchEnergyUpdateTime = CFAbsoluteTimeGetCurrent()
    private var playheadTouchPlayStartProgress: Float?
    private var playheadTouchPauseProgress: Float?
    private var playheadTouchPauseTimestamp: CFTimeInterval?
    private var playheadKickEnergy: Float = 0
    private var playheadKickOriginProgress: Float?
    private var playheadKickStartTime = CFAbsoluteTimeGetCurrent()
    private var lastPlayheadKickEnergyUpdateTime = CFAbsoluteTimeGetCurrent()
    private var playheadContactEvents: [PlayheadContactEvent] = []
    private var transientParticles: [TransientParticle] = []
    private var previousTransientScanProgress: Float?
    private var lastTransientParticleBins: [UUID: Int] = [:]
    private var transientParticleScoreProfiles: [WaveformMipCacheKey: TransientParticleScoreProfile] = [:]
    private var transientParticleScoreProfileBuildsInFlight: Set<WaveformMipCacheKey> = []
    private let transientParticleScoreProfileLock = NSLock()
    private var frameRateWindowStartTime = CFAbsoluteTimeGetCurrent()
    private var previousFrameTime: CFTimeInterval?
    private var frameRateFrameCount = 0
    private var frameIntervalCount = 0
    private var frameIntervalSum: Double = 0
    private var frameIntervalSquareSum: Double = 0
    private var worstFrameInterval: Double = 0
    private var frameStatsWaveformRenderer = "cpu"
    private var frameStatsCPUWaveformVertexCount = 0
    private var frameStatsGPUWaveformDrawCount = 0
    private var frameStatsShaderBufferUploadCount = 0
    var onFrameStatsChanged: ((TimelineFrameStats) -> Void)?
    var onRenderDataPrepared: (() -> Void)?

    func currentFrameStatsSnapshot() -> TimelineFrameStats {
        let waveformBufferDiagnostics = waveformShaderBufferStore.diagnostics()
        return TimelineFrameStats(
            framesPerSecond: 0,
            averageFrameTimeMilliseconds: 0,
            frameTimeJitterMilliseconds: 0,
            worstFrameTimeMilliseconds: 0,
            waveformRenderer: frameStatsWaveformRenderer,
            cpuWaveformVertexCount: frameStatsCPUWaveformVertexCount,
            gpuWaveformDrawCount: frameStatsGPUWaveformDrawCount,
            shaderBufferUploadCount: frameStatsShaderBufferUploadCount,
            shaderBufferCount: waveformBufferDiagnostics.bufferCount,
            shaderBufferByteCount: waveformBufferDiagnostics.byteCount,
            shaderBufferUploadInFlightCount: waveformBufferDiagnostics.inFlightCount,
            waveformMipCacheCount: waveformMipCacheDiagnostics().cacheCount
        )
    }

    private let playheadTouchGeometryAheadDuration: TimeInterval = 0.055
    private let playheadTouchLightAheadDuration: TimeInterval = 0.08
    private var playheadTouchTrailDuration: TimeInterval = 0.56
    private var playheadTouchTrailFalloffSteepness: Float = 1.30
    private var waveformBaseGray: Float = 0.88
    private let waveformTransitionDuration: CFTimeInterval = 0.2
    private let playheadTouchDecayDuration: CFTimeInterval = 0.046
    private let playheadKickDecayDuration: CFTimeInterval = 0.3
    private let playheadKickTrailDuration: CFTimeInterval = 0.38
    private let playheadKickTrailLineCount = 10
    private let playheadContactFadeDuration: CFTimeInterval = 0.6
    private let playheadTouchTrailReferenceInfluence: Float = 0.015
    private let playheadTouchTrailRenderInfluenceCutoff: Float = 0.000_05
    private var waveformFisheyeMinimumVisibleDuration: TimeInterval = 1
    private var waveformFisheyeMaximumVisibleDuration: TimeInterval = 150
    private var waveformFisheyeMaximumRadius: Float = 0.080
    private var waveformFisheyeMinimumExponent: Float = 0.50
    private var waveformFisheyeFadeCurve: Float = 1
    private var waveformFisheyeActivationDuration: CFTimeInterval = 0.111
    private var waveformFisheyeEnergy: Float = 0
    private var waveformFisheyeRampStartEnergy: Float = 0
    private var waveformFisheyeRampTargetEnergy: Float = 0
    private var waveformFisheyeRampStartTime = CACurrentMediaTime()
    private var trackFisheyeStates: [UUID: TrackFisheyeState] = [:]
    private let playheadContactMaximumEventCount = 1_024
    private let transientParticleMaximumCount = 260
    private let transientParticleScorePercentile: Float = 0.997
    private let transientParticleProfileSampleLimit = 2_048
    private let transientParticleMinimumSpacing: TimeInterval = 0.32
    private let transientParticleMaximumScanDuration: TimeInterval = 0.12
    private let maximumInFlightTransientParticleScoreProfileBuilds = 4
    private let maximumSynchronousGeneratedWaveformMipBins = 8_192
    private let maximumInFlightWaveformMipBuilds = 4
    private let maximumGeneratedWaveformMipBins = 65_536
    private let generatedWaveformMipSamplesPerBin = 4
    private let highResolutionWaveformVisibleDurationThreshold: TimeInterval = 30
    private let waveformMipTargetBinsPerPoint: Float = 24
    private let maximumCachedWaveformMipPyramids = 512
    private let maximumCachedWaveformShaderBinBuffers = 768
    private let maximumCachedWaveformShaderBinBufferBytes = 512 * 1_024 * 1_024
    private let maximumInFlightWaveformShaderBufferUploads = 8
    private let maximumSynchronousWaveformShaderBinBufferBins = 4_096
    private let maximumCachedTransientParticleScoreProfiles = 512

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
        let waveformQuadVertices = Self.makeWaveformQuadVertices()
        let waveformQuadVertexBuffer = waveformQuadVertices.withUnsafeBytes { bytes -> MTLBuffer? in
            guard let baseAddress = bytes.baseAddress else {
                return nil
            }

            return device.makeBuffer(
                bytes: baseAddress,
                length: bytes.count,
                options: [.storageModeShared]
            )
        }
        guard let waveformQuadVertexBuffer else {
            throw RendererError.waveformQuadBufferUnavailable
        }
        waveformQuadVertexBuffer.label = "Timeline waveform static quad"

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard
            let vertexFunction = library.makeFunction(name: "timeline_vertex"),
            let fragmentFunction = library.makeFunction(name: "timeline_fragment"),
            let waveformVertexFunction = library.makeFunction(name: "waveform_vertex"),
            let waveformFragmentFunction = library.makeFunction(name: "waveform_fragment")
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
        let waveformDescriptor = MTLRenderPipelineDescriptor()
        waveformDescriptor.vertexFunction = waveformVertexFunction
        waveformDescriptor.fragmentFunction = waveformFragmentFunction
        waveformDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        waveformDescriptor.colorAttachments[0].isBlendingEnabled = true
        waveformDescriptor.colorAttachments[0].rgbBlendOperation = .add
        waveformDescriptor.colorAttachments[0].alphaBlendOperation = .add
        waveformDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        waveformDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        waveformDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        waveformDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let additiveDescriptor = MTLRenderPipelineDescriptor()
        additiveDescriptor.vertexFunction = vertexFunction
        additiveDescriptor.fragmentFunction = fragmentFunction
        additiveDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        additiveDescriptor.colorAttachments[0].isBlendingEnabled = true
        additiveDescriptor.colorAttachments[0].rgbBlendOperation = .add
        additiveDescriptor.colorAttachments[0].alphaBlendOperation = .add
        additiveDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        additiveDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        additiveDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        additiveDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

        self.device = device
        self.commandQueue = commandQueue
        self.dynamicVertexBufferRing = dynamicVertexBufferRing
        self.waveformQuadVertexBuffer = waveformQuadVertexBuffer
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        waveformPipelineState = try device.makeRenderPipelineState(descriptor: waveformDescriptor)
        additivePipelineState = try device.makeRenderPipelineState(descriptor: additiveDescriptor)

        super.init()
    }

    func displayWaveform(_ waveformOverview: WaveformOverview?) {
        let trackID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
        let tracks = waveformOverview.map {
            [TimelineRenderState.Track(
                id: trackID,
                waveformVersion: 0,
                waveformOverview: $0,
                durationHint: $0.duration,
                volume: 1,
                isMuted: false,
                isSoloed: false
            )]
        } ?? []
        displayTracks(tracks)
    }

    func displayTracks(_ tracks: [TimelineRenderState.Track]) {
        let previousTracks = renderState.tracks
        let renderTracks = tracks.map { lightweightRenderTrack(from: $0) }
        let hasNextWaveforms = renderTracks.contains { $0.hasWaveform }
        var nextTrackWaveformMipLevels: [UUID: [WaveformMipLevel]] = [:]
        var nextTrackWaveformMipKeys: [UUID: WaveformMipCacheKey] = [:]
        for track in tracks {
            let mipLevels = cachedWaveformMipLevels(for: track)
            nextTrackWaveformMipLevels[track.id] = mipLevels
            if let key = waveformMipCacheKey(for: track) {
                nextTrackWaveformMipKeys[track.id] = key
            }
        }
        let nextWaveformMipLevels = tracks.first.flatMap { nextTrackWaveformMipLevels[$0.id] } ?? []
        if renderState.hasWaveforms, hasNextWaveforms {
            waveformMipLevelStateLock.lock()
            previousTrackWaveformMipLevels = trackWaveformMipLevels
            waveformMipLevelStateLock.unlock()
            previousTransitionTracks = previousTracks
            waveformGeometryStore.promoteCurrentToPrevious()
            waveformTransitionStartTime = nil
        } else {
            waveformMipLevelStateLock.lock()
            previousTrackWaveformMipLevels = [:]
            waveformMipLevelStateLock.unlock()
            previousTransitionTracks = []
            waveformGeometryStore.clearPrevious()
            waveformTransitionStartTime = nil
        }

        waveformMipLevelStateLock.lock()
        waveformMipLevels = nextWaveformMipLevels
        trackWaveformMipLevels = nextTrackWaveformMipLevels
        currentTrackWaveformMipKeys = nextTrackWaveformMipKeys
        currentPrimaryWaveformTrackID = renderTracks.first?.id
        waveformMipLevelStateLock.unlock()
        prewarmInitialWaveformShaderBuffers(
            tracks: renderTracks,
            trackWaveformMipLevels: nextTrackWaveformMipLevels
        )
        gridCache = nil
        if hasNextWaveforms {
            waveformGeometryStore.cancelCurrentPreparationKeepingCache()
        } else {
            waveformGeometryStore.clearCurrent()
        }
        playheadContactEvents.removeAll()
        transientParticles.removeAll()
        previousTransientScanProgress = nil
        lastTransientParticleBins.removeAll()
        previousRenderedPlayheadX = nil
        previousRenderedPlayheadTime = nil
        resetTrackFisheyeAudibility(for: renderTracks, at: CACurrentMediaTime())
        renderState = renderState.withTracks(renderTracks)
    }

    func displayTrackMixSettings(_ tracks: [TimelineRenderState.Track]) {
        let renderTracks = tracks.map { lightweightRenderTrack(from: $0) }
        updateTrackFisheyeAudibility(for: renderTracks, at: CACurrentMediaTime())
        renderState = renderState.withTracks(renderTracks)
    }

    private func lightweightRenderTrack(from track: TimelineRenderState.Track) -> TimelineRenderState.Track {
        let currentTrack = renderState.tracks.first { $0.id == track.id }
        let durationHint = track.waveformOverview?.duration ?? track.durationHint ?? currentTrack?.durationHint
        let hasWaveform = track.waveformOverview?.isEmpty == false || currentTrack?.hasWaveform == true
        return TimelineRenderState.Track(
            id: track.id,
            waveformVersion: track.waveformVersion,
            waveformOverview: nil,
            durationHint: durationHint,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            hasWaveform: hasWaveform
        )
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

    func updateWaveformFisheyeTuning(
        radius: Float,
        exponent: Float,
        minimumVisibleDuration: TimeInterval,
        maximumVisibleDuration: TimeInterval,
        fadeCurve: Float,
        activationDuration: TimeInterval
    ) {
        let nextMinimumVisibleDuration = max(minimumVisibleDuration, 0)
        let nextMaximumVisibleDuration = max(maximumVisibleDuration, nextMinimumVisibleDuration + 1)

        waveformFisheyeMaximumRadius = min(max(radius, 0), 0.25)
        waveformFisheyeMinimumExponent = min(max(exponent, 0.2), 0.98)
        waveformFisheyeMinimumVisibleDuration = nextMinimumVisibleDuration
        waveformFisheyeMaximumVisibleDuration = nextMaximumVisibleDuration
        waveformFisheyeFadeCurve = min(max(fadeCurve, 0.25), 4)
        waveformFisheyeActivationDuration = min(max(activationDuration, 0.04), 1.2)
    }

    func displayPlayheadProgress(
        _ progress: Float,
        force: Bool = true,
        anchorTimestamp: CFTimeInterval? = nil,
        resetsTouchStart: Bool = true,
        restartsFisheyeActivation: Bool = false,
        restartsPlayheadKick: Bool = false
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
        if restartsFisheyeActivation, renderState.isPlaybackActive {
            restartWaveformFisheyeActivation(at: currentTime)
        }
        if restartsPlayheadKick, renderState.isPlaybackActive {
            restartPlayheadKick(at: anchoredProgress)
        }
        if force, resetsTouchStart {
            playheadTouchPlayStartProgress = anchoredProgress
            playheadTouchPauseProgress = nil
            playheadTouchPauseTimestamp = nil
        }
        if force, renderState.isPlaybackActive {
            resetTransientParticleScan(to: anchoredProgress)
        }
        previousRenderedPlayheadX = nil
        previousRenderedPlayheadTime = nil
    }

    func displayPlaybackActive(_ isActive: Bool) {
        let currentTime = CACurrentMediaTime()
        updatePlayheadTouchEnergy(isPlaybackActive: renderState.isPlaybackActive)
        updatePlayheadKickEnergy()
        updateWaveformFisheyeEnergy(at: currentTime)
        let wasPlaybackActive = renderState.isPlaybackActive

        if wasPlaybackActive != isActive {
            startWaveformFisheyeRamp(to: isActive ? 1 : 0, at: currentTime)
            let anchoredProgress = projectedPlayheadProgress(at: currentTime) ??
                renderState.playheadProgress
            renderState = renderState
                .withPlayheadProgress(anchoredProgress, anchorTimestamp: currentTime)
                .withPlaybackActive(isActive)
            previousRenderedPlayheadX = nil
            previousRenderedPlayheadTime = nil
            if isActive {
                playheadTouchPlayStartProgress = anchoredProgress
                playheadTouchPauseProgress = nil
                playheadTouchPauseTimestamp = nil
                playheadContactEvents.removeAll()
                resetTransientParticleScan(to: anchoredProgress)
            } else if wasPlaybackActive {
                playheadTouchPauseProgress = anchoredProgress
                playheadTouchPauseTimestamp = currentTime
                playheadTouchEnergy = 1
                resetTransientParticleScan(to: nil)
            }
        } else {
            renderState = renderState.withPlaybackActive(isActive)
        }

        if isActive {
            playheadTouchEnergy = 1
            playheadTouchPauseProgress = nil
            playheadTouchPauseTimestamp = nil
            resetTransientParticleScan(to: renderState.playheadProgress)
            if !wasPlaybackActive {
                restartPlayheadKick(at: renderState.playheadProgress)
            }
        }
    }

    func displayRecordingActive(_ isActive: Bool) {
        renderState = renderState.withRecordingActive(isActive)
        if isActive {
            playheadTouchPlayStartProgress = nil
        }
    }

    private func restartPlayheadKick(at progress: Float) {
        let timestamp = CFAbsoluteTimeGetCurrent()
        playheadKickEnergy = 1
        playheadKickOriginProgress = min(max(progress, 0), 1)
        playheadKickStartTime = timestamp
        lastPlayheadKickEnergyUpdateTime = timestamp
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

    func displaySelectedTrack(_ trackID: UUID?) {
        renderState = renderState.withSelectedTrackID(trackID)
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

    @discardableResult
    func renderOffscreen(
        renderPassDescriptor: MTLRenderPassDescriptor,
        viewportSize: CGSize,
        backingScale: Float,
        displayTimestamp: CFTimeInterval,
        waitUntilCompleted: Bool = false
    ) -> MTLCommandBuffer? {
        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return nil
        }

        dynamicVertexBufferRing.beginFrame()
        encodeTimeline(
            into: encoder,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: displayTimestamp
        )
        encoder.endEncoding()

        commandBuffer.commit()
        if waitUntilCompleted {
            commandBuffer.waitUntilCompleted()
        }
        return commandBuffer
    }

    private func encodeTimeline(
        into encoder: MTLRenderCommandEncoder,
        viewportSize: CGSize,
        backingScale: Float,
        displayTimestamp: CFTimeInterval
    ) {
        resetFrameDiagnosticsForNextFrame()
        let renderState = renderStateStore.snapshot()
        let mipLevelSnapshot = waveformMipLevelSnapshot()
        let renderedPlayheadProgress = currentPlayheadProgress(
            renderState: renderState,
            displayTimestamp: displayTimestamp
        )
        updateTrackFisheyeAudibility(for: renderState.tracks, at: displayTimestamp)
        let waveformFisheye = waveformFisheyeParameters(
            renderState: renderState,
            playheadProgress: renderedPlayheadProgress,
            displayTimestamp: displayTimestamp
        )
        let selectedTrackVertices = makeSelectedTrackVertices(renderState: renderState)
        let selectionVertices = makeSelectionVertices(renderState: renderState)
        let usesWaveformShader = shouldRenderShaderWaveforms(
            drawableSize: viewportSize,
            renderState: renderState
        )
        let hasWaveformTransition = hasPreviousWaveformTransition
        let previousShaderRenderState = hasWaveformTransition ?
            renderState.replacingTracks(previousTransitionTracks(withCurrentMixFrom: renderState.tracks)) :
            nil
        let usesPreviousWaveformShader = previousShaderRenderState.map {
            shouldRenderShaderWaveforms(
                drawableSize: viewportSize,
                renderState: $0
            )
        } ?? false
        let waveformTouchParameters = (usesWaveformShader || usesPreviousWaveformShader) ?
            makeWaveformTouchShaderParameters(
                renderState: renderState,
                playheadProgress: renderedPlayheadProgress,
                displayTimestamp: displayTimestamp
            ) :
            emptyWaveformTouchShaderParameters()
        let waveformVertices = usesWaveformShader ?
            nil :
            cachedWaveformVertices(
                drawableSize: viewportSize,
                renderState: renderState,
                mipLevelSnapshot: mipLevelSnapshot
            )
        let previousWaveformVertices = hasWaveformTransition && !usesPreviousWaveformShader ?
            cachedPreviousWaveformVertices(
                drawableSize: viewportSize,
                renderState: renderState,
                mipLevelSnapshot: mipLevelSnapshot
            ) :
            nil
        let currentShaderWaveformsReady = usesWaveformShader &&
            (!hasWaveformTransition || preferredShaderWaveformsAreReady(
                drawableSize: viewportSize,
                renderState: renderState,
                trackWaveformMipLevels: mipLevelSnapshot.currentByTrack
            ))
        let waveformTransitionOpacities = waveformTransitionOpacities(
            at: displayTimestamp,
            hasCurrent: currentShaderWaveformsReady || waveformVertices != nil,
            hasPrevious: usesPreviousWaveformShader || previousWaveformVertices != nil
        )
        let trimPreviewVertices = makeTrimPreviewVertices(
            drawableSize: viewportSize,
            backingScale: backingScale,
            renderState: renderState
        )
        let playheadTouchVertices = usesWaveformShader ? [] :
            makePlayheadTouchVertices(
                drawableSize: viewportSize,
                playheadProgress: renderedPlayheadProgress,
                renderState: renderState,
                mipLevelSnapshot: mipLevelSnapshot,
                displayTimestamp: displayTimestamp
            )
        updateTransientParticles(
            drawableSize: viewportSize,
            playheadProgress: renderedPlayheadProgress,
            renderState: renderState,
            mipLevelSnapshot: mipLevelSnapshot,
            displayTimestamp: displayTimestamp
        )
        let transientParticleVertices = makeTransientParticleVertices(
            drawableSize: viewportSize,
            renderState: renderState,
            displayTimestamp: displayTimestamp
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
            mipLevelSnapshot: mipLevelSnapshot,
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
        draw(vertices: selectedTrackVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: selectionVertices, primitiveType: .triangle, encoder: encoder)
        if let previousShaderRenderState, usesPreviousWaveformShader {
            encoder.setRenderPipelineState(waveformPipelineState)
            drawShaderWaveforms(
                drawableSize: viewportSize,
                backingScale: backingScale,
                renderState: previousShaderRenderState,
                trackWaveformMipLevels: mipLevelSnapshot.previousByTrack,
                fisheye: waveformFisheye,
                touchParameters: waveformTouchParameters,
                opacity: waveformTransitionOpacities.previous,
                displayTimestamp: displayTimestamp,
                fallbackPolicy: .allowFallbacks,
                encoder: encoder
            )
            encoder.setRenderPipelineState(pipelineState)
        } else if let previousWaveformVertices {
            frameStatsCPUWaveformVertexCount += previousWaveformVertices.vertices.vertexCount
            let previousFisheye = cpuFallbackWaveformFisheye(
                waveformFisheye,
                renderState: previousShaderRenderState ?? renderState,
                displayTimestamp: displayTimestamp
            )
            draw(
                cachedVertices: previousWaveformVertices.vertices,
                primitiveType: .triangle,
                encoder: encoder,
                opacity: waveformTransitionOpacities.previous,
                fisheye: previousFisheye,
                xTransform: previousWaveformVertices.xTransform
            )
        }
        if usesWaveformShader {
            frameStatsWaveformRenderer = "gpu"
            encoder.setRenderPipelineState(waveformPipelineState)
            drawShaderWaveforms(
                drawableSize: viewportSize,
                backingScale: backingScale,
                renderState: renderState,
                trackWaveformMipLevels: mipLevelSnapshot.currentByTrack,
                fisheye: waveformFisheye,
                touchParameters: waveformTouchParameters,
                opacity: waveformTransitionOpacities.current,
                displayTimestamp: displayTimestamp,
                fallbackPolicy: hasWaveformTransition ? .preferredOnly : .allowFallbacks,
                encoder: encoder
            )
            encoder.setRenderPipelineState(pipelineState)
        } else if let waveformVertices {
            frameStatsCPUWaveformVertexCount += waveformVertices.vertices.vertexCount
            let fallbackFisheye = cpuFallbackWaveformFisheye(
                waveformFisheye,
                renderState: renderState,
                displayTimestamp: displayTimestamp
            )
            draw(
                cachedVertices: waveformVertices.vertices,
                primitiveType: .triangle,
                encoder: encoder,
                opacity: waveformTransitionOpacities.current,
                fisheye: fallbackFisheye,
                xTransform: waveformVertices.xTransform
            )
        }
        draw(vertices: playheadTouchVertices, primitiveType: .triangle, encoder: encoder)
        if !transientParticleVertices.isEmpty {
            encoder.setRenderPipelineState(additivePipelineState)
            draw(vertices: transientParticleVertices, primitiveType: .triangle, encoder: encoder)
            encoder.setRenderPipelineState(pipelineState)
        }
        draw(vertices: trimPreviewVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: hoverGuideVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: playheadVertices, primitiveType: .triangle, encoder: encoder)
        recordFrameRate()
    }

    private func draw(
        cachedVertices: CachedVertexBuffer,
        primitiveType: MTLPrimitiveType,
        encoder: MTLRenderCommandEncoder,
        opacity: Float = 1,
        fisheye: SIMD4<Float> = .zero,
        xTransform: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 0)
    ) {
        guard cachedVertices.vertexCount > 0 else {
            return
        }

        setVertexFisheye(fisheye, encoder: encoder)
        setVertexXTransform(xTransform, encoder: encoder)
        setFragmentOpacity(opacity, encoder: encoder)
        encoder.setVertexBuffer(cachedVertices.buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: primitiveType, vertexStart: 0, vertexCount: cachedVertices.vertexCount)
    }

    private func draw(
        vertices: [TimelineVertex],
        primitiveType: MTLPrimitiveType,
        encoder: MTLRenderCommandEncoder,
        opacity: Float = 1,
        fisheye: SIMD4<Float> = .zero,
        xTransform: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 0)
    ) {
        guard !vertices.isEmpty else {
            return
        }

        setVertexFisheye(fisheye, encoder: encoder)
        setVertexXTransform(xTransform, encoder: encoder)
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

    private func shouldRenderShaderWaveforms(
        drawableSize: CGSize,
        renderState: TimelineRenderState
    ) -> Bool {
        guard
            isGPUWaveformRendererEnabled,
            drawableSize.width > 0,
            drawableSize.height > 0,
            renderState.hasWaveforms,
            renderState.duration != nil
        else {
            return false
        }

        return renderState.tracks.contains { $0.hasWaveform }
    }

    private func drawShaderWaveforms(
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState,
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]],
        fisheye: SIMD4<Float>,
        touchParameters: (touch: SIMD4<Float>, touch2: SIMD4<Float>),
        opacity: Float,
        displayTimestamp: CFTimeInterval,
        fallbackPolicy: WaveformShaderFallbackPolicy,
        encoder: MTLRenderCommandEncoder
    ) {
        guard
            opacity > 0.001,
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0
        else {
            return
        }

        let trackCount = renderState.tracks.count
        guard trackCount > 0 else {
            return
        }

        let laneHeight = Float(1) / Float(trackCount)
        let anySolo = renderState.tracks.contains { $0.isSoloed }
        let style = waveformVisualStyle(renderState: renderState, projectDuration: projectDuration)

        for (trackIndex, track) in renderState.tracks.enumerated() {
            guard
                track.hasWaveform,
                let trackDuration = track.durationHint,
                trackDuration.isFinite,
                trackDuration > 0,
                let mipLevels = trackWaveformMipLevels[track.id],
                let shaderDrawable = waveformShaderDrawable(
                    track: track,
                    mipLevels: mipLevels,
                    drawableSize: drawableSize,
                    renderState: renderState,
                    fallbackPolicy: fallbackPolicy
                )
            else {
                continue
            }

            let trackDurationProgress = min(max(Float(trackDuration / projectDuration), 0), 1)
            guard trackDurationProgress > 0 else {
                continue
            }

            let laneTop = Float(trackIndex) * laneHeight
            let laneBottom = laneTop + laneHeight
            let centerY = laneTop + laneHeight * 0.5
            let amplitudeHeight = laneHeight * 0.39 * min(max(track.volume, 0), 1.8)
            let isAudible = isTrackAudible(track, anySolo: anySolo)
            let trackAlpha = (isAudible ? Float(1) : Float(0.26)) * min(max(opacity, 0), 1)
            let gray = waveformBaseGray * (isAudible ? 1.0 : 0.68)
            let trackTouch = isAudible ?
                touchParameters.touch :
                SIMD4<Float>(
                    touchParameters.touch.x,
                    touchParameters.touch.y,
                    touchParameters.touch.z,
                    0
                )
            let trackFisheye = scaledWaveformFisheye(
                fisheye,
                by: trackFisheyeEnergy(for: track.id, at: displayTimestamp)
            )
            let uniform = makeWaveformShaderUniform(
                laneTop: laneTop,
                laneBottom: laneBottom,
                centerY: centerY,
                amplitudeHeight: amplitudeHeight,
                binCount: shaderDrawable.mipLevel.binCount,
                trackDurationProgress: trackDurationProgress,
                baseGray: gray,
                alpha: trackAlpha,
                style: style,
                backingScale: backingScale,
                fisheye: trackFisheye,
                touch: trackTouch,
                touch2: touchParameters.touch2,
                trackID: track.id,
                renderState: renderState
            )

            drawWaveformShader(
                uniform: uniform,
                binBuffer: shaderDrawable.buffer,
                opacity: 1,
                encoder: encoder
            )
        }
    }

    private static func makeWaveformQuadVertices() -> [WaveformShaderQuadVertex] {
        [
            WaveformShaderQuadVertex(position: SIMD4<Float>(0, 0, 0, 1)),
            WaveformShaderQuadVertex(position: SIMD4<Float>(1, 0, 0, 1)),
            WaveformShaderQuadVertex(position: SIMD4<Float>(0, 1, 0, 1)),
            WaveformShaderQuadVertex(position: SIMD4<Float>(1, 0, 0, 1)),
            WaveformShaderQuadVertex(position: SIMD4<Float>(1, 1, 0, 1)),
            WaveformShaderQuadVertex(position: SIMD4<Float>(0, 1, 0, 1)),
        ]
    }

    private func makeWaveformShaderUniform(
        laneTop: Float,
        laneBottom: Float,
        centerY: Float,
        amplitudeHeight: Float,
        binCount: Int,
        trackDurationProgress: Float,
        baseGray: Float,
        alpha: Float,
        style: WaveformVisualStyle,
        backingScale: Float,
        fisheye: SIMD4<Float>,
        touch: SIMD4<Float>,
        touch2: SIMD4<Float>,
        trackID: UUID,
        renderState: TimelineRenderState
    ) -> WaveformShaderUniform {
        let baseColor = SIMD4<Float>(baseGray, baseGray, baseGray, alpha)
        let viewport = SIMD4<Float>(
            renderState.viewport.startProgress,
            renderState.viewport.durationProgress,
            renderState.viewport.endProgress,
            max(backingScale, 1)
        )
        let gainPreview: SIMD4<Float>
        if
            let preview = renderState.gainPreview,
            preview.selection.trackID == nil || preview.selection.trackID == trackID
        {
            gainPreview = SIMD4<Float>(
                preview.selection.startProgressFloat,
                preview.selection.endProgressFloat,
                max(preview.gain, 0),
                1
            )
        } else {
            gainPreview = SIMD4<Float>(-1, -1, 1, 0)
        }
        let commonLane = SIMD4<Float>(laneTop, laneBottom, centerY, max(amplitudeHeight, 0))
        let commonTrack = SIMD4<Float>(trackDurationProgress, Float(max(binCount, 1)), 0, 0)
        let commonStyle = SIMD4<Float>(
            style.spectralAmount,
            style.peakAlpha,
            style.rmsAlpha,
            style.glowAlpha
        )
        let commonStyle2 = SIMD4<Float>(
            style.transientAlpha,
            style.transientThreshold,
            style.centerLineAlpha,
            style.glowExpansion
        )

        return WaveformShaderUniform(
            baseColor: baseColor,
            lane: commonLane,
            track: commonTrack,
            viewport: viewport,
            style: commonStyle,
            style2: commonStyle2,
            gainPreview: gainPreview,
            fisheye: fisheye,
            touch: touch,
            touch2: touch2
        )
    }

    private func preferredShaderWaveformsAreReady(
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]]
    ) -> Bool {
        guard
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0
        else {
            return false
        }

        var checkedRenderableTrack = false
        for track in renderState.tracks where track.hasWaveform {
            guard
                let trackDuration = track.durationHint,
                trackDuration.isFinite,
                trackDuration > 0,
                let mipLevels = trackWaveformMipLevels[track.id],
                let preferredIndex = waveformMipLevelIndex(
                    for: drawableSize,
                    renderState: renderState,
                    mipLevels: mipLevels
                )
            else {
                return false
            }

            let trackDurationProgress = min(max(Float(trackDuration / projectDuration), 0), 1)
            guard trackDurationProgress > 0 else {
                return false
            }

            checkedRenderableTrack = true
            let preferredMipLevel = mipLevels[preferredIndex]
            guard waveformShaderBuffer(track: track, mipLevel: preferredMipLevel) != nil else {
                prepareWaveformShaderBinBuffer(
                    track: track,
                    mipLevel: preferredMipLevel,
                    allowsSynchronousUpload: false
                )
                return false
            }
        }

        return checkedRenderableTrack
    }

    private func waveformShaderDrawable(
        track: TimelineRenderState.Track,
        mipLevels: [WaveformMipLevel],
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        fallbackPolicy: WaveformShaderFallbackPolicy = .allowFallbacks
    ) -> WaveformShaderDrawable? {
        guard
            !mipLevels.isEmpty,
            let preferredIndex = waveformMipLevelIndex(
                for: drawableSize,
                renderState: renderState,
                mipLevels: mipLevels
            )
        else {
            return nil
        }

        let preferredMipLevel = mipLevels[preferredIndex]
        if let buffer = waveformShaderBuffer(track: track, mipLevel: preferredMipLevel) {
            return WaveformShaderDrawable(mipLevel: preferredMipLevel, buffer: buffer)
        }

        prepareWaveformShaderBinBuffer(
            track: track,
            mipLevel: preferredMipLevel,
            allowsSynchronousUpload: false
        )
        if let buffer = waveformShaderBuffer(track: track, mipLevel: preferredMipLevel) {
            return WaveformShaderDrawable(mipLevel: preferredMipLevel, buffer: buffer)
        }

        guard fallbackPolicy == .allowFallbacks else {
            return nil
        }

        if preferredIndex + 1 < mipLevels.count {
            for fallbackIndex in (preferredIndex + 1)..<mipLevels.count {
                let fallbackMipLevel = mipLevels[fallbackIndex]
                if let buffer = waveformShaderBuffer(track: track, mipLevel: fallbackMipLevel) {
                    return WaveformShaderDrawable(mipLevel: fallbackMipLevel, buffer: buffer)
                }
            }
        }

        if preferredIndex > 0 {
            for fallbackIndex in stride(from: preferredIndex - 1, through: 0, by: -1) {
                let fallbackMipLevel = mipLevels[fallbackIndex]
                if let buffer = waveformShaderBuffer(track: track, mipLevel: fallbackMipLevel) {
                    return WaveformShaderDrawable(mipLevel: fallbackMipLevel, buffer: buffer)
                }
            }
        }

        return nil
    }

    private func makeWaveformShaderBinBuffer(
        from bins: [WaveformOverview.Bin],
        label: String,
        shouldYieldForPlayback: Bool = false
    ) -> MTLBuffer? {
        guard !bins.isEmpty else {
            return nil
        }

        let bufferLength = bins.count * MemoryLayout<WaveformShaderBin>.stride
        guard let buffer = device.makeBuffer(
            length: bufferLength,
            options: [.storageModeShared]
        ) else {
            return nil
        }

        let destination = buffer.contents()
            .bindMemory(to: WaveformShaderBin.self, capacity: bins.count)
        for (index, bin) in bins.enumerated() {
            if shouldYieldForPlayback, index.isMultiple(of: 8_192) {
                try? ImportWorkBudget.shared.waitIfPlaybackActive()
            }
            destination[index] = WaveformShaderBin(
                minimumSample: bin.minimumSample,
                maximumSample: bin.maximumSample,
                rmsSample: bin.rmsSample,
                lowEnergy: bin.lowEnergy,
                midEnergy: bin.midEnergy,
                highEnergy: bin.highEnergy,
                peakMagnitude: bin.peakMagnitude,
                reserved: 0
            )
        }

        buffer.label = label
        return buffer
    }

    private func waveformShaderBufferKey(
        track: TimelineRenderState.Track,
        mipLevel: WaveformMipLevel
    ) -> WaveformMipCacheKey {
        WaveformMipCacheKey(
            trackID: track.id,
            waveformVersion: track.waveformVersion,
            binCount: mipLevel.binCount,
            duration: mipLevel.overview.duration
        )
    }

    private func waveformShaderBuffer(
        track: TimelineRenderState.Track,
        mipLevel: WaveformMipLevel
    ) -> MTLBuffer? {
        waveformShaderBufferStore.buffer(for: waveformShaderBufferKey(track: track, mipLevel: mipLevel))
    }

    private func prepareWaveformShaderBinBuffer(
        track: TimelineRenderState.Track,
        mipLevel: WaveformMipLevel,
        allowsSynchronousUpload: Bool
    ) {
        let key = waveformShaderBufferKey(track: track, mipLevel: mipLevel)
        guard waveformShaderBufferStore.beginPreparing(
            key,
            maximumInFlightCount: maximumInFlightWaveformShaderBufferUploads
        ) else {
            return
        }

        let bins = mipLevel.overview.bins
        let label = "Timeline GPU waveform bins \(mipLevel.binCount)"

        if
            allowsSynchronousUpload,
            mipLevel.binCount <= maximumSynchronousWaveformShaderBinBufferBins
        {
            let buffer = makeWaveformShaderBinBuffer(from: bins, label: label)
            waveformShaderBufferStore.publish(buffer, for: key)
            waveformShaderBufferStore.trim(
                toMaximumCount: maximumCachedWaveformShaderBinBuffers,
                maximumByteCount: maximumCachedWaveformShaderBinBufferBytes
            )
            return
        }

        waveformGeometryQueue.async { [weak self] in
            let buffer = self?.makeWaveformShaderBinBuffer(
                from: bins,
                label: label,
                shouldYieldForPlayback: true
            )
            self?.waveformShaderBufferStore.publish(buffer, for: key)
            self?.waveformShaderBufferStore.trim(
                toMaximumCount: self?.maximumCachedWaveformShaderBinBuffers ?? 768,
                maximumByteCount: self?.maximumCachedWaveformShaderBinBufferBytes ?? 512 * 1_024 * 1_024
            )
            self?.onRenderDataPrepared?()
        }
    }

    private func prewarmInitialWaveformShaderBuffers(
        tracks: [TimelineRenderState.Track],
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]]
    ) {
        for track in tracks {
            guard let lowestCostMipLevel = trackWaveformMipLevels[track.id]?.last else {
                continue
            }

            prepareWaveformShaderBinBuffer(
                track: track,
                mipLevel: lowestCostMipLevel,
                allowsSynchronousUpload: true
            )
        }
    }

    private func drawWaveformShader(
        uniform: WaveformShaderUniform,
        binBuffer: MTLBuffer,
        opacity: Float,
        encoder: MTLRenderCommandEncoder
    ) {
        frameStatsGPUWaveformDrawCount += 1
        setWaveformFragmentOpacity(opacity, encoder: encoder)
        var uniform = uniform
        encoder.setVertexBuffer(waveformQuadVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<WaveformShaderUniform>.stride, index: 1)
        encoder.setFragmentBuffer(binBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func waveformMipLevelSnapshot() -> WaveformMipLevelSnapshot {
        waveformMipLevelStateLock.lock()
        defer {
            waveformMipLevelStateLock.unlock()
        }

        return WaveformMipLevelSnapshot(
            primary: waveformMipLevels,
            currentByTrack: trackWaveformMipLevels,
            previousByTrack: previousTrackWaveformMipLevels
        )
    }

    private var hasPreviousWaveformTransition: Bool {
        waveformMipLevelStateLock.lock()
        defer {
            waveformMipLevelStateLock.unlock()
        }

        return !previousTrackWaveformMipLevels.isEmpty && !previousTransitionTracks.isEmpty
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
            waveformMipLevelStateLock.lock()
            previousTrackWaveformMipLevels = [:]
            waveformMipLevelStateLock.unlock()
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

    private func setVertexFisheye(_ fisheye: SIMD4<Float>, encoder: MTLRenderCommandEncoder) {
        var vertexFisheye = fisheye
        encoder.setVertexBytes(
            &vertexFisheye,
            length: MemoryLayout<SIMD4<Float>>.stride,
            index: 1
        )
    }

    private func setVertexXTransform(_ xTransform: SIMD4<Float>, encoder: MTLRenderCommandEncoder) {
        var vertexXTransform = xTransform
        encoder.setVertexBytes(
            &vertexXTransform,
            length: MemoryLayout<SIMD4<Float>>.stride,
            index: 2
        )
    }

    private func setWaveformFragmentOpacity(_ opacity: Float, encoder: MTLRenderCommandEncoder) {
        var fragmentOpacity = min(max(opacity, 0), 1)
        encoder.setFragmentBytes(
            &fragmentOpacity,
            length: MemoryLayout<Float>.stride,
            index: 2
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
        let waveformBufferDiagnostics = waveformShaderBufferStore.diagnostics()
        let frameStats = TimelineFrameStats(
            framesPerSecond: framesPerSecond,
            averageFrameTimeMilliseconds: averageFrameInterval * 1_000,
            frameTimeJitterMilliseconds: sqrt(frameIntervalVariance) * 1_000,
            worstFrameTimeMilliseconds: worstFrameInterval * 1_000,
            waveformRenderer: frameStatsWaveformRenderer,
            cpuWaveformVertexCount: frameStatsCPUWaveformVertexCount,
            gpuWaveformDrawCount: frameStatsGPUWaveformDrawCount,
            shaderBufferUploadCount: frameStatsShaderBufferUploadCount,
            shaderBufferCount: waveformBufferDiagnostics.bufferCount,
            shaderBufferByteCount: waveformBufferDiagnostics.byteCount,
            shaderBufferUploadInFlightCount: waveformBufferDiagnostics.inFlightCount,
            waveformMipCacheCount: waveformMipCacheDiagnostics().cacheCount
        )

        frameRateWindowStartTime = currentTime
        frameRateFrameCount = 0
        frameIntervalCount = 0
        frameIntervalSum = 0
        frameIntervalSquareSum = 0
        worstFrameInterval = 0
        onFrameStatsChanged?(frameStats)
    }

    private func waveformMipCacheDiagnostics() -> (cacheCount: Int, inFlightCount: Int) {
        waveformMipLevelCacheLock.lock()
        defer {
            waveformMipLevelCacheLock.unlock()
        }

        return (waveformMipLevelCache.count, waveformMipLevelBuildsInFlight.count)
    }

    private func resetFrameDiagnosticsForNextFrame() {
        frameStatsWaveformRenderer = "cpu"
        frameStatsCPUWaveformVertexCount = 0
        frameStatsGPUWaveformDrawCount = 0
        frameStatsShaderBufferUploadCount = waveformShaderBufferStore.drainPublishedBufferCount()
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
        renderState: TimelineRenderState,
        mipLevelSnapshot: WaveformMipLevelSnapshot
    ) -> WaveformDrawCache? {
        cachedWaveformVertices(
            drawableSize: drawableSize,
            renderState: renderState,
            mipLevels: mipLevelSnapshot.primary,
            trackWaveformMipLevels: mipLevelSnapshot.currentByTrack,
            target: .current,
            usesTrackLanes: true
        )
    }

    private func cachedPreviousWaveformVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        mipLevelSnapshot: WaveformMipLevelSnapshot
    ) -> WaveformDrawCache? {
        let previousTracks = previousTransitionTracks(withCurrentMixFrom: renderState.tracks)
        guard !previousTracks.isEmpty else {
            return nil
        }

        let previousRenderState = renderState.replacingTracks(previousTracks)
        return cachedWaveformVertices(
            drawableSize: drawableSize,
            renderState: previousRenderState,
            mipLevels: [],
            trackWaveformMipLevels: mipLevelSnapshot.previousByTrack,
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
                durationHint: previousTrack.durationHint,
                volume: currentTrack?.volume ?? previousTrack.volume,
                isMuted: currentTrack?.isMuted ?? previousTrack.isMuted,
                isSoloed: currentTrack?.isSoloed ?? previousTrack.isSoloed,
                hasWaveform: previousTrack.hasWaveform
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
    ) -> WaveformDrawCache? {
        if usesTrackLanes, renderState.hasWaveforms {
            let geometryViewport = waveformGeometryViewport(for: renderState.viewport)
            let mipBinSignature = selectedTrackMipBinSignature(
                drawableSize: drawableSize,
                renderState: renderState,
                trackWaveformMipLevels: trackWaveformMipLevels
            )
            let key = waveformCacheKey(
                drawableSize: drawableSize,
                mipBinCount: mipBinSignature,
                renderState: renderState,
                geometryViewport: geometryViewport
            )

            if let cache = waveformGeometryStore.cache(for: key, target: target) {
                return waveformDrawCache(cache, renderViewport: renderState.viewport)
            }

            let contentSignature = waveformContentSignature(renderState: renderState)
            let visualSignature = waveformVisualSignature(renderState: renderState)
            if renderState.isPlaybackActive, isGPUWaveformRendererEnabled {
                return waveformGeometryStore.fallback(
                    contentSignature: contentSignature,
                    target: target
                ).map { waveformDrawCache($0, renderViewport: renderState.viewport) } ??
                waveformGeometryStore.fallbackAny(target: target).map {
                    waveformDrawCache($0, renderViewport: renderState.viewport)
                }
            }
            let geometryRenderState = renderState.withViewport(geometryViewport)
            prepareWaveformGeometry(
                key: key,
                contentSignature: contentSignature,
                visualSignature: visualSignature,
                target: target,
                drawableSize: drawableSize,
                renderState: geometryRenderState,
                mipLevel: nil,
                trackWaveformMipLevels: trackWaveformMipLevels,
                usesTrackLanes: true
            )
            return waveformGeometryStore.fallback(
                contentSignature: contentSignature,
                target: target
            ).map { waveformDrawCache($0, renderViewport: renderState.viewport) } ??
            waveformGeometryStore.fallbackAny(target: target).map {
                waveformDrawCache($0, renderViewport: renderState.viewport)
            }
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

        let geometryViewport = waveformGeometryViewport(for: renderState.viewport)
        let key = waveformCacheKey(
            drawableSize: drawableSize,
            mipLevel: mipLevel,
            renderState: renderState,
            geometryViewport: geometryViewport
        )

        if let cache = waveformGeometryStore.cache(for: key, target: target) {
            return waveformDrawCache(cache, renderViewport: renderState.viewport)
        }

        let contentSignature = waveformContentSignature(renderState: renderState)
        let visualSignature = waveformVisualSignature(renderState: renderState)
        if renderState.isPlaybackActive, isGPUWaveformRendererEnabled {
            return waveformGeometryStore.fallback(
                contentSignature: contentSignature,
                target: target
            ).map { waveformDrawCache($0, renderViewport: renderState.viewport) } ??
            waveformGeometryStore.fallbackAny(target: target).map {
                waveformDrawCache($0, renderViewport: renderState.viewport)
            }
        }
        let geometryRenderState = renderState.withViewport(geometryViewport)
        prepareWaveformGeometry(
            key: key,
            contentSignature: contentSignature,
            visualSignature: visualSignature,
            target: target,
            drawableSize: drawableSize,
            renderState: geometryRenderState,
            mipLevel: mipLevel,
            trackWaveformMipLevels: trackWaveformMipLevels,
            usesTrackLanes: false
        )
        return waveformGeometryStore.fallback(
            contentSignature: contentSignature,
            target: target
        ).map { waveformDrawCache($0, renderViewport: renderState.viewport) } ??
        waveformGeometryStore.fallbackAny(target: target).map {
            waveformDrawCache($0, renderViewport: renderState.viewport)
        }
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
        renderState: TimelineRenderState,
        geometryViewport: TimelineViewport
    ) -> WaveformCacheKey {
        waveformCacheKey(
            drawableSize: drawableSize,
            mipBinCount: mipLevel.binCount,
            renderState: renderState,
            geometryViewport: geometryViewport
        )
    }

    private func waveformCacheKey(
        drawableSize: CGSize,
        mipBinCount: Int,
        renderState: TimelineRenderState,
        geometryViewport: TimelineViewport
    ) -> WaveformCacheKey {
        let gainSelectionStart: Float
        let gainSelectionEnd: Float
        let gain: Float
        if let gainPreview = renderState.gainPreview {
            gainSelectionStart = gainPreview.selection.startProgressFloat
            gainSelectionEnd = gainPreview.selection.endProgressFloat
            gain = gainPreview.gain
        } else {
            gainSelectionStart = -1
            gainSelectionEnd = -1
            gain = 1
        }

        return WaveformCacheKey(
            width: Float(drawableSize.width),
            viewportStart: geometryViewport.startProgress,
            viewportDuration: geometryViewport.durationProgress,
            mipBinCount: mipBinCount,
            gainSelectionStart: gainSelectionStart,
            gainSelectionEnd: gainSelectionEnd,
            gain: gain,
            waveformBaseGray: waveformBaseGray,
            trackSignature: trackSignature(renderState: renderState)
        )
    }

    private func waveformGeometryViewport(for viewport: TimelineViewport) -> TimelineViewport {
        guard !viewport.isFull else {
            return .full
        }

        let renderDuration = max(viewport.durationProgress, 0.000_001)
        let geometryDuration = min(renderDuration * 2, 1)
        guard geometryDuration < 1 else {
            return .full
        }

        let tileStep = max(renderDuration * 0.5, 0.000_001)
        let tileIndex = floor(viewport.startProgress / tileStep)
        let centeredStart = tileIndex * tileStep - (geometryDuration - renderDuration) * 0.5

        return TimelineViewport(
            startProgress: centeredStart,
            durationProgress: geometryDuration
        )
    }

    private func waveformDrawCache(
        _ cache: WaveformCache,
        renderViewport: TimelineViewport
    ) -> WaveformDrawCache {
        WaveformDrawCache(
            vertices: cache.vertices,
            xTransform: waveformXTransform(from: cache.key, to: renderViewport)
        )
    }

    private func waveformXTransform(
        from cacheKey: WaveformCacheKey,
        to renderViewport: TimelineViewport
    ) -> SIMD4<Float> {
        let renderDuration = max(renderViewport.durationProgress, 0.000_001)
        let scale = cacheKey.viewportDuration / renderDuration
        let offset = (cacheKey.viewportStart - renderViewport.startProgress) / renderDuration
        return SIMD4<Float>(scale, offset, 0, 0)
    }

    private func waveformContentSignature(renderState: TimelineRenderState) -> Int {
        var hasher = Hasher()
        for track in renderState.tracks {
            hasher.combine(track.id)
            hasher.combine(track.waveformVersion)
            hasher.combine(track.hasWaveform)
            hasher.combine(track.durationHint ?? 0)
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
            hasher.combine(track.hasWaveform)
            hasher.combine(track.durationHint ?? 0)
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

    private func updateTransientParticles(
        drawableSize: CGSize,
        playheadProgress: Float,
        renderState: TimelineRenderState,
        mipLevelSnapshot: WaveformMipLevelSnapshot,
        displayTimestamp: CFTimeInterval
    ) {
        transientParticles.removeAll { particle in
            displayTimestamp - particle.birthTimestamp >= particle.lifeDuration
        }

        guard
            renderState.isPlaybackActive,
            renderState.hasWaveforms,
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0
        else {
            resetTransientParticleScan(to: nil)
            return
        }

        let clampedProgress = min(max(playheadProgress, 0), 1)
        guard let previousProgress = previousTransientScanProgress else {
            previousTransientScanProgress = clampedProgress
            return
        }

        defer {
            previousTransientScanProgress = clampedProgress
        }

        guard clampedProgress >= previousProgress else {
            resetTransientParticleScan(to: clampedProgress)
            return
        }

        let scannedProgress = clampedProgress - previousProgress
        let scannedDuration = TimeInterval(scannedProgress) * projectDuration
        guard
            scannedProgress > .ulpOfOne,
            scannedProgress < renderState.viewport.durationProgress * 0.75,
            scannedDuration <= transientParticleMaximumScanDuration
        else {
            if scannedProgress > .ulpOfOne {
                resetTransientParticleScan(to: clampedProgress)
            }
            return
        }

        guard drawableSize.width > 0, drawableSize.height > 0 else {
            return
        }

        let anySolo = renderState.tracks.contains { $0.isSoloed }
        let laneHeight = Float(1) / Float(max(renderState.tracks.count, 1))
        let viewport = renderState.viewport

        for (trackIndex, track) in renderState.tracks.enumerated() {
            guard isTrackAudible(track, anySolo: anySolo) else {
                continue
            }
            guard
                track.hasWaveform,
                let trackDuration = track.durationHint,
                trackDuration.isFinite,
                trackDuration > 0,
                let highResolutionMip = mipLevelSnapshot.currentByTrack[track.id]?.first,
                !highResolutionMip.overview.isEmpty
            else {
                continue
            }

            let bins = highResolutionMip.overview.bins
            let binCount = bins.count
            let trackDurationProgress = min(max(Float(trackDuration / projectDuration), 0), 1)
            guard binCount > 0, trackDurationProgress > 0 else {
                continue
            }
            guard let scoreProfile = transientParticleScoreProfile(
                for: track,
                mipLevel: highResolutionMip
            ) else {
                continue
            }

            let scanStart = max(previousProgress, 0)
            let scanEnd = min(clampedProgress, trackDurationProgress)
            guard scanStart < scanEnd else {
                continue
            }

            let firstIndex = max(Int(floor(scanStart / trackDurationProgress * Float(binCount))) - 1, 0)
            let lastIndex = min(Int(ceil(scanEnd / trackDurationProgress * Float(binCount))) + 1, binCount - 1)
            guard firstIndex <= lastIndex else {
                continue
            }

            let binsPerSecond = Double(binCount) / trackDuration
            let minimumSpacingBins = max(Int((binsPerSecond * transientParticleMinimumSpacing).rounded(.up)), 1)
            let previousTriggeredBin = lastTransientParticleBins[track.id] ?? -minimumSpacingBins * 2
            var latestTriggeredBin = previousTriggeredBin

            let laneTop = Float(trackIndex) * laneHeight
            let laneBottom = laneTop + laneHeight
            let centerY = laneTop + laneHeight * 0.5
            let amplitudeHeight = laneHeight * 0.39 * min(max(track.volume, 0), 1.8)
            let originEdgePadding = min(max(laneHeight * 0.120, 0.022), 0.075)
            let neighborhoodRadius = max(min(Int((binsPerSecond * 0.035).rounded(.up)), 24), 3)

            for index in firstIndex...lastIndex {
                guard index - latestTriggeredBin >= minimumSpacingBins else {
                    continue
                }

                let bin = bins[index]
                let score = transientParticleScore(for: bin)
                guard score >= scoreProfile.threshold else {
                    continue
                }

                let relativeRange = max(scoreProfile.loudestScore - scoreProfile.threshold, 0.001)
                let neighborhoodStart = max(index - neighborhoodRadius, 0)
                let neighborhoodEnd = min(index + neighborhoodRadius, binCount - 1)
                var neighboringMaximumScore: Float = 0
                var neighboringScoreSum: Float = 0
                var neighboringScoreCount: Float = 0
                if neighborhoodStart <= neighborhoodEnd {
                    for neighborIndex in neighborhoodStart...neighborhoodEnd where neighborIndex != index {
                        let neighborScore = transientParticleScore(for: bins[neighborIndex])
                        neighboringMaximumScore = max(neighboringMaximumScore, neighborScore)
                        neighboringScoreSum += neighborScore
                        neighboringScoreCount += 1
                    }
                }

                let neighboringAverageScore = neighboringScoreCount > 0 ?
                    neighboringScoreSum / neighboringScoreCount :
                    0
                let localPeakProminence = score - neighboringMaximumScore
                let localBedProminence = score - neighboringAverageScore
                guard
                    score >= neighboringMaximumScore,
                    localPeakProminence >= relativeRange * 0.18 ||
                        localBedProminence >= relativeRange * 0.44
                else {
                    continue
                }

                let localX = (Float(index) + 0.5) / Float(binCount)
                let timelineProgress = localX * trackDurationProgress
                let viewportX = viewport.viewportProgress(forTimelineProgress: timelineProgress)
                guard viewportX >= -0.08, viewportX <= 1.08 else {
                    continue
                }

                let gain = previewGain(
                    forBinStart: Float(index) / Float(binCount) * trackDurationProgress,
                    end: Float(index + 1) / Float(binCount) * trackDurationProgress,
                    trackID: track.id,
                    renderState: renderState
                )
                let maximumSample = clampAudioSample(bin.maximumSample * gain)
                let minimumSample = clampAudioSample(bin.minimumSample * gain)
                let peakFloor = min(max(bin.peakMagnitude * max(gain, 0) * 0.985, 0), 1)
                let topMagnitude = min(max(maximumSample, peakFloor), 1)
                let bottomMagnitude = min(max(abs(minimumSample), peakFloor), 1)
                let topY = min(max(centerY - topMagnitude * amplitudeHeight - originEdgePadding, laneTop), laneBottom)
                let bottomY = min(max(centerY + bottomMagnitude * amplitudeHeight + originEdgePadding, laneTop), laneBottom)
                let normalizedScore = min(max((score - scoreProfile.threshold) / relativeRange, 0), 1)
                let normalizedProminence = min(max(max(localPeakProminence, localBedProminence) / relativeRange, 0), 1)
                let strength = min(max(0.34 + normalizedScore * 0.50 + normalizedProminence * 0.28, 0), 1)
                let baseSeed = transientParticleSeed(trackID: track.id, binIndex: index)

                spawnTransientParticleBurst(
                    originProgress: timelineProgress,
                    originY: topY,
                    isTopEdge: true,
                    strength: strength,
                    seed: baseSeed,
                    birthTimestamp: displayTimestamp
                )
                spawnTransientParticleBurst(
                    originProgress: timelineProgress,
                    originY: bottomY,
                    isTopEdge: false,
                    strength: strength,
                    seed: baseSeed &+ 0x9E37_79B9_7F4A_7C15,
                    birthTimestamp: displayTimestamp
                )

                latestTriggeredBin = index
            }

            if latestTriggeredBin != previousTriggeredBin {
                lastTransientParticleBins[track.id] = latestTriggeredBin
            }
        }

        if transientParticles.count > transientParticleMaximumCount {
            transientParticles.removeFirst(transientParticles.count - transientParticleMaximumCount)
        }
    }

    private func transientParticleScore(for bin: WaveformOverview.Bin) -> Float {
        let midHigh = bin.highEnergy * 0.46 + bin.midEnergy * 0.18
        let peakWeight = min(max(bin.peakMagnitude * 0.44 + bin.rmsSample * 0.16, 0), 0.52)
        return min(max(midHigh + peakWeight, 0), 1)
    }

    private func transientParticleScoreProfile(
        for track: TimelineRenderState.Track,
        mipLevel: WaveformMipLevel
    ) -> TransientParticleScoreProfile? {
        let key = WaveformMipCacheKey(
            trackID: track.id,
            waveformVersion: track.waveformVersion,
            binCount: mipLevel.binCount,
            duration: mipLevel.overview.duration
        )

        transientParticleScoreProfileLock.lock()
        if let cachedProfile = transientParticleScoreProfiles[key] {
            transientParticleScoreProfileLock.unlock()
            return cachedProfile
        }
        guard
            !transientParticleScoreProfileBuildsInFlight.contains(key),
            transientParticleScoreProfileBuildsInFlight.count < maximumInFlightTransientParticleScoreProfileBuilds
        else {
            transientParticleScoreProfileLock.unlock()
            return nil
        }
        transientParticleScoreProfileBuildsInFlight.insert(key)
        transientParticleScoreProfileLock.unlock()

        waveformGeometryQueue.async { [weak self] in
            guard let self else {
                return
            }

            let profile = self.buildTransientParticleScoreProfile(mipLevel: mipLevel)
            self.transientParticleScoreProfileLock.lock()
            if self.transientParticleScoreProfiles.count >= self.maximumCachedTransientParticleScoreProfiles {
                self.transientParticleScoreProfiles.removeAll(keepingCapacity: true)
            }
            self.transientParticleScoreProfiles[key] = profile
            self.transientParticleScoreProfileBuildsInFlight.remove(key)
            self.transientParticleScoreProfileLock.unlock()
            self.onRenderDataPrepared?()
        }

        return nil
    }

    private func buildTransientParticleScoreProfile(
        mipLevel: WaveformMipLevel
    ) -> TransientParticleScoreProfile {
        let histogramBucketCount = 128
        var histogram = Array(repeating: 0, count: histogramBucketCount)
        var scoreSum: Double = 0
        var scoreSquareSum: Double = 0
        var loudestScore: Float = 0
        let bins = mipLevel.overview.bins
        let sampleLimit = max(transientParticleProfileSampleLimit, 1)
        let sampleStride = max(bins.count / sampleLimit, 1)
        var sampledBinCount = 0

        var binIndex = 0
        while binIndex < bins.count {
            if sampledBinCount.isMultiple(of: 256) {
                try? ImportWorkBudget.shared.waitIfPlaybackActive()
            }
            let bin = bins[binIndex]
            let score = transientParticleScore(for: bin)
            let bucket = min(
                max(Int((score * Float(histogramBucketCount - 1)).rounded(.down)), 0),
                histogramBucketCount - 1
            )
            histogram[bucket] += 1
            scoreSum += Double(score)
            scoreSquareSum += Double(score * score)
            loudestScore = max(loudestScore, score)
            sampledBinCount += 1
            binIndex += sampleStride
        }

        if sampleStride > 1, let finalBin = bins.last {
            let score = transientParticleScore(for: finalBin)
            let bucket = min(
                max(Int((score * Float(histogramBucketCount - 1)).rounded(.down)), 0),
                histogramBucketCount - 1
            )
            histogram[bucket] += 1
            scoreSum += Double(score)
            scoreSquareSum += Double(score * score)
            loudestScore = max(loudestScore, score)
            sampledBinCount += 1
        }

        guard sampledBinCount > 0, loudestScore > 0.0001 else {
            return TransientParticleScoreProfile(threshold: 1, loudestScore: 0)
        }

        let count = Double(sampledBinCount)
        let mean = Float(scoreSum / count)
        let variance = max(Float(scoreSquareSum / count) - mean * mean, 0)
        let standardDeviation = sqrt(variance)
        let percentileRank = max(
            Int((Float(sampledBinCount) * transientParticleScorePercentile).rounded(.up)),
            1
        )
        var cumulativeCount = 0
        var percentileThreshold = loudestScore
        for (bucketIndex, bucketCount) in histogram.enumerated() {
            cumulativeCount += bucketCount
            if cumulativeCount >= percentileRank {
                percentileThreshold = min(
                    max((Float(bucketIndex) + 0.5) / Float(histogramBucketCount - 1), 0),
                    1
                )
                break
            }
        }

        let statisticalThreshold = mean + standardDeviation * 1.45
        let loudnessFloor = loudestScore * 0.86
        let relativeCeiling = loudestScore * 0.993
        let threshold = min(
            max(max(percentileThreshold, statisticalThreshold), loudnessFloor),
            max(relativeCeiling, 0.0001)
        )
        return TransientParticleScoreProfile(
            threshold: min(max(threshold, 0), 1),
            loudestScore: loudestScore
        )
    }

    private func spawnTransientParticleBurst(
        originProgress: Float,
        originY: Float,
        isTopEdge: Bool,
        strength: Float,
        seed: UInt64,
        birthTimestamp: CFTimeInterval
    ) {
        let particleCount = 5 + Int((strength * 5.0).rounded(.down))
        for particleIndex in 0..<particleCount {
            let distribution = particleCount <= 1 ?
                Float(0.5) :
                Float(particleIndex) / Float(particleCount - 1)
            let angleJitter = (pseudoRandom01(seed &+ UInt64(particleIndex) &* 37) - 0.5) * 0.16
            let angle = Float.pi * min(max(0.12 + distribution * 0.76 + angleJitter, 0.06), 0.94)
            let direction = isTopEdge ?
                SIMD2<Float>(cos(angle), -sin(angle)) :
                SIMD2<Float>(cos(angle), sin(angle))
            let perpendicular = SIMD2<Float>(-direction.y, direction.x)
            let speed = 46 + 64 * strength + 18 * pseudoRandom01(seed &+ UInt64(particleIndex) &* 101)
            let radius = 0.45 + 0.60 * strength + 0.25 * pseudoRandom01(seed &+ UInt64(particleIndex) &* 191)
            let lifeDuration = CFTimeInterval(0.22 + 0.12 * Double(pseudoRandom01(seed &+ UInt64(particleIndex) &* 293)))
            let phase = pseudoRandom01(seed &+ UInt64(particleIndex) &* 389) * Float.pi * 2
            let spinRate = 20 + 28 * pseudoRandom01(seed &+ UInt64(particleIndex) &* 479)
            let color = SIMD3<Float>(
                0.82 + 0.14 * strength,
                0.97,
                0.92 + 0.08 * pseudoRandom01(seed &+ UInt64(particleIndex) &* 577)
            )

            transientParticles.append(TransientParticle(
                originProgress: originProgress,
                originY: originY,
                velocity: direction * speed,
                perpendicular: perpendicular,
                birthTimestamp: birthTimestamp,
                lifeDuration: lifeDuration,
                radius: radius,
                strength: 0.26 + 0.18 * strength,
                spinPhase: phase,
                spinRate: spinRate,
                color: color
            ))
        }
    }

    private func makeTransientParticleVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        displayTimestamp: CFTimeInterval
    ) -> [TimelineVertex] {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return []
        }

        transientParticles.removeAll { particle in
            displayTimestamp - particle.birthTimestamp >= particle.lifeDuration
        }
        guard !transientParticles.isEmpty else {
            return []
        }

        let drawableSize = SIMD2<Float>(width, height)
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(transientParticles.count * 36)

        for particle in transientParticles {
            let originViewportX = renderState.viewport.viewportProgress(
                forTimelineProgress: particle.originProgress
            )
            let origin = SIMD2<Float>(originViewportX * width, particle.originY * height)
            let age = max(displayTimestamp - particle.birthTimestamp, 0)
            let progress = min(max(Float(age / particle.lifeDuration), 0), 1)
            let fade = 1 - progress
            let easedTravel = 1 - pow(1 - progress, 2.6)
            let swirl = sin(progress * particle.spinRate + particle.spinPhase) *
                particle.radius * 0.75 * fade
            let center = origin +
                particle.velocity * Float(age) * (0.55 + 0.45 * easedTravel) +
                particle.perpendicular * swirl
            let radius = particle.radius * (0.85 + progress * 0.9)
            let alpha = particle.strength * fade * fade
            guard alpha > 0.002 else {
                continue
            }

            appendSoftParticle(
                to: &vertices,
                center: center,
                radius: radius,
                color: particle.color,
                alpha: alpha,
                drawableSize: drawableSize
            )
        }

        return vertices
    }

    private func makeSelectionVertices(renderState: TimelineRenderState) -> [TimelineVertex] {
        guard
            let selection = renderState.selection,
            renderState.hasWaveforms,
            selection.durationProgress > 0
        else {
            return []
        }

        let viewport = renderState.viewport
        let viewportStart = Double(viewport.startProgress)
        let viewportDuration = max(Double(viewport.durationProgress), 0.000_000_001)
        let left = Float((selection.startProgress - viewportStart) / viewportDuration)
        let right = Float((selection.endProgress - viewportStart) / viewportDuration)
        guard right > 0, left < 1 else {
            return []
        }

        let color = SIMD4<Float>(0.0, 0.84, 0.78, 0.22)
        let verticalRange = selectionVerticalRange(
            for: selection,
            tracks: renderState.tracks
        )
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(6)

        appendRectangle(
            to: &vertices,
            left: max(left, 0),
            right: min(right, 1),
            top: verticalRange.top,
            bottom: verticalRange.bottom,
            color: color
        )

        return vertices
    }

    private func makeSelectedTrackVertices(renderState: TimelineRenderState) -> [TimelineVertex] {
        guard
            let selectedTrackID = renderState.selectedTrackID,
            let trackIndex = renderState.tracks.firstIndex(where: { $0.id == selectedTrackID }),
            !renderState.tracks.isEmpty
        else {
            return []
        }
        if
            let selection = renderState.selection,
            selection.trackID == selectedTrackID,
            selection.startProgress <= 0.001,
            selection.endProgress >= 0.999
        {
            return []
        }

        let laneHeight = Float(1) / Float(renderState.tracks.count)
        let laneTop = Float(trackIndex) * laneHeight
        let laneBottom = laneTop + laneHeight
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(6)
        appendRectangle(
            to: &vertices,
            left: 0,
            right: 1,
            top: laneTop,
            bottom: laneBottom,
            color: SIMD4<Float>(0.78, 0.78, 0.78, 0.075)
        )
        return vertices
    }

    private func selectionVerticalRange(
        for selection: TimelineSelection,
        tracks: [TimelineRenderState.Track]
    ) -> (top: Float, bottom: Float) {
        guard
            let trackID = selection.trackID,
            let trackIndex = tracks.firstIndex(where: { $0.id == trackID }),
            !tracks.isEmpty
        else {
            return (0, 1)
        }

        let laneHeight = Float(1) / Float(tracks.count)
        let top = Float(trackIndex) * laneHeight
        return (top, top + laneHeight)
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
        let style = waveformVisualStyle(
            renderState: renderState,
            projectDuration: mipLevel.overview.duration
        )
        let bins = mipLevel.overview.bins
        let binCount = bins.count
        let viewport = renderState.viewport
        let startIndex = max(Int(floor(viewport.startProgress * Float(binCount))) - 1, 0)
        let endIndex = min(Int(ceil(viewport.endProgress * Float(binCount))) + 1, binCount)
        guard startIndex < endIndex else {
            return []
        }

        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity((endIndex - startIndex) * 36)

        for index in startIndex..<endIndex {
            let bin = bins[index]
            let timelineX0 = Float(index) / Float(binCount)
            let timelineX1 = Float(index + 1) / Float(binCount)
            let x0 = viewport.viewportProgress(forTimelineProgress: timelineX0)
            let x1 = viewport.viewportProgress(forTimelineProgress: timelineX1)
            guard x1 > 0, x0 < 1 else {
                continue
            }

            appendStyledWaveformBin(
                to: &vertices,
                left: max(x0, 0),
                right: min(x1, 1),
                centerY: centerY,
                laneTop: 0,
                laneBottom: 1,
                amplitudeHeight: amplitudeHeight,
                minimumVisualHeight: minimumVisualHeight,
                bin: bin,
                gain: previewGain(forBinStart: timelineX0, end: timelineX1, renderState: renderState),
                baseGray: waveformBaseGray,
                alpha: 1,
                style: style
            )
        }

        return vertices
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
        let style = waveformVisualStyle(renderState: renderState, projectDuration: projectDuration)
        var vertices: [TimelineVertex] = []

        for (trackIndex, track) in tracks.enumerated() {
            guard
                track.hasWaveform,
                let trackDuration = track.durationHint,
                trackDuration.isFinite,
                trackDuration > 0,
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
            let trackDurationProgress = min(max(Float(trackDuration / projectDuration), 0), 1)
            guard binCount > 0, trackDurationProgress > 0 else {
                continue
            }

            let laneTop = Float(trackIndex) * laneHeight
            let laneBottom = laneTop + laneHeight
            let centerY = laneTop + laneHeight * 0.5
            let amplitudeHeight = laneHeight * 0.39 * min(max(track.volume, 0), 1.8)
            let isAudible = isTrackAudible(track, anySolo: anySolo)
            let alpha: Float = isAudible ? 1.0 : 0.26
            let gray = waveformBaseGray * (isAudible ? 1.0 : 0.68)
            let startIndex = max(Int(floor(renderState.viewport.startProgress / trackDurationProgress * Float(binCount))) - 1, 0)
            let endIndex = min(Int(ceil(renderState.viewport.endProgress / trackDurationProgress * Float(binCount))) + 1, binCount)
            guard startIndex < endIndex else {
                continue
            }

            vertices.reserveCapacity(vertices.count + (endIndex - startIndex) * 36)
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

                appendStyledWaveformBin(
                    to: &vertices,
                    left: max(x0, 0),
                    right: min(x1, 1),
                    centerY: centerY,
                    laneTop: laneTop,
                    laneBottom: laneBottom,
                    amplitudeHeight: amplitudeHeight,
                    minimumVisualHeight: minimumVisualHeight,
                    bin: bin,
                    gain: previewGain(forBinStart: timelineX0, end: timelineX1, trackID: track.id, renderState: renderState),
                    baseGray: gray,
                    alpha: alpha,
                    style: style
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

    private func previewGain(
        forBinStart binStart: Float,
        end binEnd: Float,
        trackID: UUID? = nil,
        renderState: TimelineRenderState
    ) -> Float {
        guard let gainPreview = renderState.gainPreview else {
            return 1
        }

        let selection = gainPreview.selection
        if let selectionTrackID = selection.trackID,
           let trackID,
           selectionTrackID != trackID
        {
            return 1
        }

        guard Double(binEnd) > selection.startProgress, Double(binStart) < selection.endProgress else {
            return 1
        }

        return gainPreview.gain
    }

    private func clampAudioSample(_ sample: Float) -> Float {
        min(max(sample, -1), 1)
    }

    private func isTrackAudible(_ track: TimelineRenderState.Track, anySolo: Bool) -> Bool {
        anySolo ? track.isSoloed : !track.isMuted
    }

    private func resetTrackFisheyeAudibility(
        for tracks: [TimelineRenderState.Track],
        at timestamp: CFTimeInterval
    ) {
        let anySolo = tracks.contains { $0.isSoloed }
        trackFisheyeStates = Dictionary(uniqueKeysWithValues: tracks.map { track in
            let energy: Float = isTrackAudible(track, anySolo: anySolo) ? 1 : 0
            return (
                track.id,
                TrackFisheyeState(
                    currentEnergy: energy,
                    startEnergy: energy,
                    targetEnergy: energy,
                    startTime: timestamp
                )
            )
        })
    }

    private func updateTrackFisheyeAudibility(
        for tracks: [TimelineRenderState.Track],
        at timestamp: CFTimeInterval
    ) {
        let anySolo = tracks.contains { $0.isSoloed }
        var liveTrackIDs = Set<UUID>()

        for track in tracks {
            liveTrackIDs.insert(track.id)
            let targetEnergy: Float = isTrackAudible(track, anySolo: anySolo) ? 1 : 0

            guard var state = trackFisheyeStates[track.id] else {
                trackFisheyeStates[track.id] = TrackFisheyeState(
                    currentEnergy: targetEnergy,
                    startEnergy: targetEnergy,
                    targetEnergy: targetEnergy,
                    startTime: timestamp
                )
                continue
            }

            let currentEnergy = resolvedTrackFisheyeEnergy(state, at: timestamp)
            if abs(state.targetEnergy - targetEnergy) > 0.000_1 {
                state.currentEnergy = currentEnergy
                state.startEnergy = currentEnergy
                state.targetEnergy = targetEnergy
                state.startTime = timestamp
            } else {
                state.currentEnergy = currentEnergy
                if abs(currentEnergy - state.targetEnergy) <= 0.000_1 {
                    state.currentEnergy = state.targetEnergy
                    state.startEnergy = state.targetEnergy
                    state.startTime = timestamp
                }
            }

            trackFisheyeStates[track.id] = state
        }

        trackFisheyeStates = trackFisheyeStates.filter { liveTrackIDs.contains($0.key) }
    }

    private func resolvedTrackFisheyeEnergy(
        _ state: TrackFisheyeState,
        at timestamp: CFTimeInterval
    ) -> Float {
        let duration = max(waveformFisheyeActivationDuration, 0.001)
        let progress = min(max((timestamp - state.startTime) / duration, 0), 1)
        let easedProgress = smoothStep(Float(progress))
        return min(max(
            state.startEnergy + (state.targetEnergy - state.startEnergy) * easedProgress,
            0
        ), 1)
    }

    private func trackFisheyeEnergy(for trackID: UUID, at timestamp: CFTimeInterval) -> Float {
        guard let state = trackFisheyeStates[trackID] else {
            return 1
        }

        return resolvedTrackFisheyeEnergy(state, at: timestamp)
    }

    private func resetTransientParticleScan(to progress: Float?) {
        previousTransientScanProgress = progress.map { min(max($0, 0), 1) }
        lastTransientParticleBins.removeAll()
    }

    private func waveformVisualStyle(
        renderState: TimelineRenderState,
        projectDuration: TimeInterval
    ) -> WaveformVisualStyle {
        let visibleDuration = max(projectDuration * Double(renderState.viewport.durationProgress), 0)
        if visibleDuration > 90 {
            return WaveformVisualStyle(
                spectralAmount: 0.34,
                peakAlpha: 0.42,
                rmsAlpha: 0.72,
                glowAlpha: 0.055,
                transientAlpha: 0.08,
                transientThreshold: 0.46,
                centerLineAlpha: 0.02,
                glowExpansion: 0.010
            )
        }

        if visibleDuration > 8 {
            return WaveformVisualStyle(
                spectralAmount: 0.26,
                peakAlpha: 0.46,
                rmsAlpha: 0.76,
                glowAlpha: 0.038,
                transientAlpha: 0.13,
                transientThreshold: 0.42,
                centerLineAlpha: 0.035,
                glowExpansion: 0.007
            )
        }

        if visibleDuration > 0.6 {
            return WaveformVisualStyle(
                spectralAmount: 0.16,
                peakAlpha: 0.52,
                rmsAlpha: 0.82,
                glowAlpha: 0.022,
                transientAlpha: 0.19,
                transientThreshold: 0.36,
                centerLineAlpha: 0.07,
                glowExpansion: 0.004
            )
        }

        return WaveformVisualStyle(
            spectralAmount: 0.08,
            peakAlpha: 0.58,
            rmsAlpha: 0.86,
            glowAlpha: 0.012,
            transientAlpha: 0.26,
            transientThreshold: 0.30,
            centerLineAlpha: 0.11,
            glowExpansion: 0.002
        )
    }

    private func waveformFisheyeParameters(
        renderState: TimelineRenderState,
        playheadProgress: Float,
        displayTimestamp: CFTimeInterval
    ) -> SIMD4<Float> {
        let activationEnergy = updateWaveformFisheyeEnergy(at: displayTimestamp)
        guard
            activationEnergy > 0.000_1,
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0,
            renderState.viewport.durationProgress > 0
        else {
            return .zero
        }

        let visibleDuration = projectDuration * Double(renderState.viewport.durationProgress)
        let rawAmount = (visibleDuration - waveformFisheyeMinimumVisibleDuration) /
            max(waveformFisheyeMaximumVisibleDuration - waveformFisheyeMinimumVisibleDuration, 0.001)
        let linearAmount = min(max(Float(rawAmount), 0), 1)
        let curvedAmount = pow(linearAmount, waveformFisheyeFadeCurve)
        let amount = smoothStep(curvedAmount) * activationEnergy
        guard amount > 0.000_1 else {
            return .zero
        }

        let centerX = renderState.viewport.viewportProgress(forTimelineProgress: playheadProgress)
        guard centerX > -waveformFisheyeMaximumRadius, centerX < 1 + waveformFisheyeMaximumRadius else {
            return .zero
        }

        let radius = waveformFisheyeMaximumRadius * amount
        let exponent = 1 + (waveformFisheyeMinimumExponent - 1) * amount
        return SIMD4<Float>(
            min(max(centerX, 0), 1),
            max(radius, 0.001),
            min(max(exponent, 0.1), 1),
            amount
        )
    }

    @discardableResult
    private func updateWaveformFisheyeEnergy(at timestamp: CFTimeInterval) -> Float {
        let elapsedTime = timestamp - waveformFisheyeRampStartTime
        guard elapsedTime > 0 else {
            return waveformFisheyeEnergy
        }

        let progress = min(max(elapsedTime / waveformFisheyeActivationDuration, 0), 1)
        let easedProgress = smoothStep(Float(progress))
        waveformFisheyeEnergy = waveformFisheyeRampStartEnergy +
            (waveformFisheyeRampTargetEnergy - waveformFisheyeRampStartEnergy) * easedProgress

        if progress >= 1 {
            waveformFisheyeEnergy = waveformFisheyeRampTargetEnergy
            waveformFisheyeRampStartEnergy = waveformFisheyeRampTargetEnergy
            waveformFisheyeRampStartTime = timestamp
        }

        return min(max(waveformFisheyeEnergy, 0), 1)
    }

    private func startWaveformFisheyeRamp(to targetEnergy: Float, at timestamp: CFTimeInterval) {
        let currentEnergy = updateWaveformFisheyeEnergy(at: timestamp)
        waveformFisheyeRampStartEnergy = currentEnergy
        waveformFisheyeRampTargetEnergy = min(max(targetEnergy, 0), 1)
        waveformFisheyeRampStartTime = timestamp
        waveformFisheyeEnergy = currentEnergy
    }

    private func restartWaveformFisheyeActivation(at timestamp: CFTimeInterval) {
        waveformFisheyeEnergy = 0
        waveformFisheyeRampStartEnergy = 0
        waveformFisheyeRampTargetEnergy = 1
        waveformFisheyeRampStartTime = timestamp
    }

    private func scaledWaveformFisheye(
        _ fisheye: SIMD4<Float>,
        by energy: Float
    ) -> SIMD4<Float> {
        let energy = min(max(energy, 0), 1)
        guard fisheye.w > 0.000_1, energy > 0.000_1 else {
            return .zero
        }

        return SIMD4<Float>(
            fisheye.x,
            fisheye.y * energy,
            1 + (fisheye.z - 1) * energy,
            fisheye.w * energy
        )
    }

    private func cpuFallbackWaveformFisheye(
        _ fisheye: SIMD4<Float>,
        renderState: TimelineRenderState,
        displayTimestamp: CFTimeInterval
    ) -> SIMD4<Float> {
        let tracksWithWaveforms = renderState.tracks.filter(\.hasWaveform)
        guard !tracksWithWaveforms.isEmpty else {
            return .zero
        }

        var sharedEnergy: Float?
        for track in tracksWithWaveforms {
            let energy = trackFisheyeEnergy(for: track.id, at: displayTimestamp)
            if let existingEnergy = sharedEnergy {
                guard abs(existingEnergy - energy) <= 0.001 else {
                    return .zero
                }
            } else {
                sharedEnergy = energy
            }
        }

        return scaledWaveformFisheye(fisheye, by: sharedEnergy ?? 0)
    }

    private func smoothStep(_ progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        return clampedProgress * clampedProgress * (3 - 2 * clampedProgress)
    }

    private func waveformColor(
        for bin: WaveformOverview.Bin,
        baseGray: Float,
        alpha: Float,
        style: WaveformVisualStyle
    ) -> SIMD4<Float> {
        let base = SIMD3<Float>(baseGray, baseGray, baseGray)
        let lowTint = SIMD3<Float>(0.54, 0.76, 0.92)
        let midTint = SIMD3<Float>(0.88, 0.86, 0.80)
        let highTint = SIMD3<Float>(0.94, 0.99, 0.97)
        let tint =
            lowTint * bin.lowEnergy +
            midTint * bin.midEnergy +
            highTint * bin.highEnergy
        let energy = min(max(bin.rmsSample * 1.35 + bin.peakMagnitude * 0.22, 0), 1)
        let amount = style.spectralAmount * (0.35 + energy * 0.65)
        let rgb = base + (tint - base) * amount
        return SIMD4<Float>(rgb.x, rgb.y, rgb.z, alpha)
    }

    private func colorWithAlpha(_ color: SIMD4<Float>, alpha: Float) -> SIMD4<Float> {
        SIMD4<Float>(color.x, color.y, color.z, alpha)
    }

    private func lightened(_ color: SIMD4<Float>, amount: Float, alpha: Float? = nil) -> SIMD4<Float> {
        let amount = min(max(amount, 0), 1)
        return SIMD4<Float>(
            color.x + (1 - color.x) * amount,
            color.y + (1 - color.y) * amount,
            color.z + (1 - color.z) * amount,
            alpha ?? color.w
        )
    }

    private func appendStyledWaveformBin(
        to vertices: inout [TimelineVertex],
        left: Float,
        right: Float,
        centerY: Float,
        laneTop: Float,
        laneBottom: Float,
        amplitudeHeight: Float,
        minimumVisualHeight: Float,
        bin: WaveformOverview.Bin,
        gain: Float,
        baseGray: Float,
        alpha: Float,
        style: WaveformVisualStyle
    ) {
        let left = max(left, 0)
        let right = min(right, 1)
        guard right > left, laneBottom > laneTop, amplitudeHeight > 0 else {
            return
        }

        let minimumSample = clampAudioSample(bin.minimumSample * gain)
        let maximumSample = clampAudioSample(bin.maximumSample * gain)
        var peakTop = centerY - maximumSample * amplitudeHeight
        var peakBottom = centerY - minimumSample * amplitudeHeight
        if peakBottom - peakTop < minimumVisualHeight {
            let midpoint = (peakTop + peakBottom) * 0.5
            peakTop = midpoint - minimumVisualHeight * 0.5
            peakBottom = midpoint + minimumVisualHeight * 0.5
        }

        peakTop = max(peakTop, laneTop)
        peakBottom = min(peakBottom, laneBottom)
        guard peakBottom > peakTop else {
            return
        }

        let baseColor = waveformColor(for: bin, baseGray: baseGray, alpha: alpha, style: style)
        let peakCenterColor = lightened(baseColor, amount: 0.12, alpha: style.peakAlpha * alpha)
        let peakEdgeColor = colorWithAlpha(baseColor, alpha: style.peakAlpha * 0.42 * alpha)
        let glowColor = lightened(baseColor, amount: 0.18, alpha: style.glowAlpha * alpha)

        if style.glowAlpha > 0.001 {
            appendRectangle(
                to: &vertices,
                left: left,
                right: right,
                top: max(peakTop - style.glowExpansion, laneTop),
                bottom: min(peakBottom + style.glowExpansion, laneBottom),
                color: glowColor
            )
        }

        appendCenterWeightedWaveformBand(
            to: &vertices,
            left: left,
            right: right,
            top: peakTop,
            bottom: peakBottom,
            centerY: centerY,
            centerColor: peakCenterColor,
            edgeColor: peakEdgeColor
        )

        let rmsSample = min(max(bin.rmsSample * max(gain, 0), 0), 1)
        let rmsVisualHeight = max(rmsSample * amplitudeHeight, minimumVisualHeight * 0.7)
        let rmsTop = max(centerY - rmsVisualHeight, laneTop)
        let rmsBottom = min(centerY + rmsVisualHeight, laneBottom)
        if rmsBottom > rmsTop {
            let rmsColor = lightened(baseColor, amount: 0.22, alpha: style.rmsAlpha * alpha)
            appendCenterWeightedWaveformBand(
                to: &vertices,
                left: left,
                right: right,
                top: rmsTop,
                bottom: rmsBottom,
                centerY: centerY,
                centerColor: rmsColor,
                edgeColor: colorWithAlpha(rmsColor, alpha: rmsColor.w * 0.50)
            )
        }

        let transientStrength = max(bin.highEnergy - style.transientThreshold, 0) /
            max(1 - style.transientThreshold, 0.001)
        if transientStrength > 0.001 {
            let transientColor = lightened(baseColor, amount: 0.45, alpha: transientStrength * style.transientAlpha * alpha)
            let inset = (right - left) * 0.34
            appendRectangle(
                to: &vertices,
                left: left + inset,
                right: right - inset,
                top: peakTop,
                bottom: peakBottom,
                color: transientColor
            )
        }

        if style.centerLineAlpha > 0.001 {
            appendRectangle(
                to: &vertices,
                left: left,
                right: right,
                top: max(centerY - minimumVisualHeight * 0.28, laneTop),
                bottom: min(centerY + minimumVisualHeight * 0.28, laneBottom),
                color: lightened(baseColor, amount: 0.18, alpha: style.centerLineAlpha * alpha)
            )
        }
    }

    private func appendCenterWeightedWaveformBand(
        to vertices: inout [TimelineVertex],
        left: Float,
        right: Float,
        top: Float,
        bottom: Float,
        centerY: Float,
        centerColor: SIMD4<Float>,
        edgeColor: SIMD4<Float>
    ) {
        guard bottom > top, right > left else {
            return
        }

        if top < centerY, centerY < bottom {
            appendVerticalGradientRectangle(
                to: &vertices,
                left: left,
                right: right,
                top: top,
                bottom: centerY,
                topColor: edgeColor,
                bottomColor: centerColor
            )
            appendVerticalGradientRectangle(
                to: &vertices,
                left: left,
                right: right,
                top: centerY,
                bottom: bottom,
                topColor: centerColor,
                bottomColor: edgeColor
            )
        } else {
            appendRectangle(to: &vertices, left: left, right: right, top: top, bottom: bottom, color: centerColor)
        }
    }

    private func emptyWaveformTouchShaderParameters() -> (touch: SIMD4<Float>, touch2: SIMD4<Float>) {
        (
            touch: SIMD4<Float>(0, 0, 0, 0),
            touch2: SIMD4<Float>(0, 0, 0, playheadTouchTrailFalloffSteepness)
        )
    }

    private func makeWaveformTouchShaderParameters(
        renderState: TimelineRenderState,
        playheadProgress: Float,
        displayTimestamp: CFTimeInterval
    ) -> (touch: SIMD4<Float>, touch2: SIMD4<Float>) {
        guard
            renderState.hasWaveforms,
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0
        else {
            return emptyWaveformTouchShaderParameters()
        }

        let clampedPlayhead = min(max(playheadProgress, 0), 1)
        let geometryAheadRadius = playheadTouchGeometryAheadRadiusProgress(forDuration: projectDuration)
        let lightAheadRadius = playheadTouchLightAheadRadiusProgress(forDuration: projectDuration)
        let trailDecayRadius = playheadTouchTrailRadiusProgress(forDuration: projectDuration)
        let trailRenderRadius = playheadTouchTrailRenderRadiusProgress(forDuration: projectDuration)
        let viewport = renderState.viewport
        let touchHeadProgress: Float
        let touchRegionEnd: Float
        let touchEnergy: Float

        if renderState.isPlaybackActive {
            touchEnergy = currentPlayheadTouchEnergy(isPlaybackActive: true)
            touchHeadProgress = clampedPlayhead
            touchRegionEnd = min(
                clampedPlayhead + max(geometryAheadRadius, lightAheadRadius),
                viewport.endProgress
            )
        } else if
            let pauseProgress = playheadTouchPauseProgress,
            let pauseTimestamp = playheadTouchPauseTimestamp
        {
            let elapsedTime = max(displayTimestamp - pauseTimestamp, 0)
            guard elapsedTime < playheadTouchTrailRenderDuration else {
                playheadTouchEnergy = 0
                playheadTouchPauseProgress = nil
                playheadTouchPauseTimestamp = nil
                playheadTouchPlayStartProgress = nil
                return emptyWaveformTouchShaderParameters()
            }

            touchEnergy = 1
            touchHeadProgress = min(max(pauseProgress + Float(elapsedTime / projectDuration), 0), 1)
            touchRegionEnd = min(max(pauseProgress, 0), viewport.endProgress)
        } else {
            touchEnergy = currentPlayheadTouchEnergy(isPlaybackActive: false)
            touchHeadProgress = clampedPlayhead
            touchRegionEnd = min(clampedPlayhead, viewport.endProgress)
        }

        guard touchEnergy > 0.001 else {
            return emptyWaveformTouchShaderParameters()
        }

        let playthroughTrailStart = playheadTouchPlayStartProgress.map {
            min(max($0, 0), min(touchHeadProgress, touchRegionEnd))
        }
        let visibleTouchStart = max(
            touchHeadProgress - trailRenderRadius,
            playthroughTrailStart ?? 0,
            viewport.startProgress
        )
        let visibleTouchEnd = touchRegionEnd

        guard visibleTouchStart < visibleTouchEnd else {
            return emptyWaveformTouchShaderParameters()
        }

        return (
            touch: SIMD4<Float>(
                touchHeadProgress,
                visibleTouchEnd,
                visibleTouchStart,
                touchEnergy
            ),
            touch2: SIMD4<Float>(
                geometryAheadRadius,
                lightAheadRadius,
                trailDecayRadius,
                playheadTouchTrailFalloffSteepness
            )
        )
    }

    private func makePlayheadTouchVertices(
        drawableSize: CGSize,
        playheadProgress: Float,
        renderState: TimelineRenderState,
        mipLevelSnapshot: WaveformMipLevelSnapshot,
        displayTimestamp: CFTimeInterval
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
        let clampedPlayhead = min(max(playheadProgress, 0), 1)
        let geometryAheadRadius = playheadTouchGeometryAheadRadiusProgress(forDuration: projectDuration)
        let lightAheadRadius = playheadTouchLightAheadRadiusProgress(forDuration: projectDuration)
        let trailDecayRadius = playheadTouchTrailRadiusProgress(forDuration: projectDuration)
        let trailRenderRadius = playheadTouchTrailRenderRadiusProgress(forDuration: projectDuration)
        let viewport = renderState.viewport
        let touchHeadProgress: Float
        let touchRegionEnd: Float
        let touchEnergy: Float

        if renderState.isPlaybackActive {
            touchEnergy = currentPlayheadTouchEnergy(isPlaybackActive: true)
            touchHeadProgress = clampedPlayhead
            touchRegionEnd = min(
                clampedPlayhead + max(geometryAheadRadius, lightAheadRadius),
                viewport.endProgress
            )
        } else if
            let pauseProgress = playheadTouchPauseProgress,
            let pauseTimestamp = playheadTouchPauseTimestamp
        {
            let elapsedTime = max(displayTimestamp - pauseTimestamp, 0)
            guard elapsedTime < playheadTouchTrailRenderDuration else {
                playheadTouchEnergy = 0
                playheadTouchPauseProgress = nil
                playheadTouchPauseTimestamp = nil
                playheadTouchPlayStartProgress = nil
                return []
            }

            touchEnergy = 1
            touchHeadProgress = min(max(pauseProgress + Float(elapsedTime / projectDuration), 0), 1)
            touchRegionEnd = min(max(pauseProgress, 0), viewport.endProgress)
        } else {
            touchEnergy = currentPlayheadTouchEnergy(isPlaybackActive: false)
            touchHeadProgress = clampedPlayhead
            touchRegionEnd = min(clampedPlayhead, viewport.endProgress)
        }

        guard touchEnergy > 0.001 else {
            return []
        }

        let playthroughTrailStart = playheadTouchPlayStartProgress.map {
            min(max($0, 0), min(touchHeadProgress, touchRegionEnd))
        }
        let visibleTouchStart = max(
            touchHeadProgress - trailRenderRadius,
            playthroughTrailStart ?? 0,
            viewport.startProgress
        )
        let visibleTouchEnd = touchRegionEnd

        guard visibleTouchStart < visibleTouchEnd else {
            return []
        }

        var vertices: [TimelineVertex] = []
        let anySolo = tracks.contains { $0.isSoloed }

        for (trackIndex, track) in tracks.enumerated() {
            guard
                track.hasWaveform,
                let trackDuration = track.durationHint,
                trackDuration.isFinite,
                trackDuration > 0,
                let mipLevels = mipLevelSnapshot.currentByTrack[track.id],
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
            let trackDurationProgress = min(max(Float(trackDuration / projectDuration), 0), 1)
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
            guard isTrackAudible(track, anySolo: anySolo) else {
                continue
            }
            let audibleEnergy = touchEnergy
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
                    offsetFromPlayhead: binCenter - touchHeadProgress,
                    aheadRadius: geometryAheadRadius,
                    trailRadius: trailDecayRadius
                )
                let lightInfluenceRaw = playheadTouchLightInfluence(
                    offsetFromPlayhead: binCenter - touchHeadProgress,
                    aheadRadius: lightAheadRadius,
                    trailRadius: trailDecayRadius
                )
                guard max(geometryInfluenceRaw, lightInfluenceRaw) > playheadTouchTrailRenderInfluenceCutoff else {
                    continue
                }

                let geometryInfluence = geometryInfluenceRaw * audibleEnergy
                let expansion = 1 + 0.30 * geometryInfluence
                let gain = previewGain(forBinStart: timelineX0, end: timelineX1, trackID: track.id, renderState: renderState)
                var y0 = centerY - clampAudioSample(bin.maximumSample * gain) * amplitudeHeight * expansion
                var y1 = centerY - clampAudioSample(bin.minimumSample * gain) * amplitudeHeight * expansion

                if y1 - y0 < minimumVisualHeight {
                    let midpoint = (y0 + y1) * 0.5
                    let visualHeight = minimumVisualHeight + laneHeight * 0.014 * geometryInfluence
                    y0 = midpoint - visualHeight * 0.5
                    y1 = midpoint + visualHeight * 0.5
                }

                let baseGray = waveformBaseGray
                let baseColor = SIMD3<Float>(baseGray, baseGray, baseGray)
                let whiteColor = SIMD3<Float>(1.0, 1.0, 1.0)
                let colorInfluence = lightInfluenceRaw * audibleEnergy
                let blendedColor = baseColor + (whiteColor - baseColor) * colorInfluence
                let overlayPresence = max(geometryInfluenceRaw * 0.42, lightInfluenceRaw)
                let color = SIMD4<Float>(
                    blendedColor.x,
                    blendedColor.y,
                    blendedColor.z,
                    min(max(overlayPresence * audibleEnergy, 0), 1)
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

    private var playheadTouchTrailRenderDuration: TimeInterval {
        playheadTouchTrailDuration * TimeInterval(playheadTouchTrailRenderRadiusMultiplier())
    }

    private func playheadTouchTrailRenderRadiusProgress(forDuration duration: TimeInterval) -> Float {
        guard duration.isFinite, duration > 0 else {
            return 0.024
        }

        let decayRadius = playheadTouchTrailRadiusProgress(forDuration: duration)
        return min(max(decayRadius * playheadTouchTrailRenderRadiusMultiplier(), .ulpOfOne), 1)
    }

    private func playheadTouchTrailRenderRadiusMultiplier() -> Float {
        let exponent = max(playheadTouchTrailFalloffSteepness, 0.25)
        let referenceInfluence = min(max(playheadTouchTrailReferenceInfluence, 0.000_1), 0.5)
        let cutoffInfluence = min(max(playheadTouchTrailRenderInfluenceCutoff, .ulpOfOne), referenceInfluence)
        let referencePower = -log(referenceInfluence)
        let cutoffPower = -log(cutoffInfluence)
        return Float(pow(Double(cutoffPower / referencePower), 1 / Double(exponent)))
    }

    private func transientParticleSeed(trackID: UUID, binIndex: Int) -> UInt64 {
        UInt64(bitPattern: Int64(trackID.hashValue)) &+
            UInt64(truncatingIfNeeded: binIndex) &* 0xBF58_476D_1CE4_E5B9
    }

    private func pseudoRandom01(_ seed: UInt64) -> Float {
        var value = seed &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value = value ^ (value >> 31)
        return Float(value & 0x00FF_FFFF) / Float(0x0100_0000)
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
        mipLevelSnapshot: WaveformMipLevelSnapshot,
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
        let baseColor = renderState.isRecordingActive ?
            SIMD3<Float>(0.96, 0.12, 0.14) :
            SIMD3<Float>(0.0, 0.75, 0.78)
        let burstColor = renderState.isRecordingActive ?
            SIMD3<Float>(1.0, 0.30, 0.24) :
            SIMD3<Float>(0.0, 0.62, 0.86)
        let blendedColor = baseColor + (burstColor - baseColor) * kickEnergy
        let size = SIMD2<Float>(width, height)
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(90)
        let baseWidth = pixelLength(4.0, backingScale: backingScale)
        let halfBaseWidth = baseWidth * 0.5
        updatePlayheadContactEvents(
            playheadProgress: playheadProgress,
            renderState: renderState,
            mipLevelSnapshot: mipLevelSnapshot,
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
        mipLevelSnapshot: WaveformMipLevelSnapshot,
        displayTimestamp: CFTimeInterval
    ) {
        playheadContactEvents.removeAll { event in
            displayTimestamp - event.timestamp >= playheadContactFadeDuration
        }

        guard
            renderState.isPlaybackActive,
            let contacts = playheadWaveformContacts(
                at: playheadProgress,
                renderState: renderState,
                mipLevelSnapshot: mipLevelSnapshot
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
        renderState: TimelineRenderState,
        mipLevelSnapshot: WaveformMipLevelSnapshot
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
            guard isTrackAudible(track, anySolo: anySolo) else {
                continue
            }

            guard
                track.hasWaveform,
                let trackDuration = track.durationHint,
                trackDuration.isFinite,
                trackDuration > 0,
                let mipLevel = mipLevelSnapshot.currentByTrack[track.id]?.first,
                !mipLevel.overview.isEmpty
            else {
                continue
            }

            let trackDurationProgress = min(max(Float(trackDuration / projectDuration), 0), 1)
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
            let gain = previewGain(forBinStart: timelineX0, end: timelineX1, trackID: track.id, renderState: renderState)
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

    private func makeWaveformMipLevels(
        from waveformOverview: WaveformOverview?,
        shouldYieldForPlayback: Bool = false
    ) -> [WaveformMipLevel] {
        guard let waveformOverview, !waveformOverview.isEmpty else {
            return []
        }

        var levels = [
            WaveformMipLevel(overview: waveformOverview, binCount: waveformOverview.bins.count),
        ]
        let sourceBinCount = waveformOverview.bins.count
        var targetBinCount = min(sourceBinCount / 2, maximumGeneratedWaveformMipBins)

        while targetBinCount >= 256 {
            let mipOverview = sampledWaveformOverview(
                from: waveformOverview,
                targetBinCount: targetBinCount,
                samplesPerBin: generatedWaveformMipSamplesPerBin,
                shouldYieldForPlayback: shouldYieldForPlayback
            )
            levels.append(WaveformMipLevel(
                overview: mipOverview,
                binCount: mipOverview.bins.count
            ))
            targetBinCount /= 2
        }

        return levels
    }

    private func makeInitialWaveformMipLevels(from waveformOverview: WaveformOverview?) -> [WaveformMipLevel] {
        guard let waveformOverview, !waveformOverview.isEmpty else {
            return []
        }

        let sourceBinCount = waveformOverview.bins.count
        guard sourceBinCount > maximumSynchronousGeneratedWaveformMipBins else {
            return makeWaveformMipLevels(from: waveformOverview)
        }

        var levels = [
            WaveformMipLevel(overview: waveformOverview, binCount: sourceBinCount),
        ]
        var targetBinCount = min(sourceBinCount / 2, maximumSynchronousGeneratedWaveformMipBins)

        while targetBinCount >= 256 {
            let mipOverview = sampledWaveformOverview(
                from: waveformOverview,
                targetBinCount: targetBinCount,
                samplesPerBin: generatedWaveformMipSamplesPerBin
            )
            levels.append(WaveformMipLevel(
                overview: mipOverview,
                binCount: mipOverview.bins.count
            ))
            targetBinCount /= 2
        }

        return levels
    }

    private func sampledWaveformOverview(
        from waveformOverview: WaveformOverview,
        targetBinCount: Int,
        samplesPerBin: Int,
        shouldYieldForPlayback: Bool = false
    ) -> WaveformOverview {
        let sourceBins = waveformOverview.bins
        let sourceBinCount = sourceBins.count
        let targetBinCount = min(max(targetBinCount, 1), sourceBinCount)
        let samplesPerBin = max(samplesPerBin, 1)
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(targetBinCount)

        for targetIndex in 0..<targetBinCount {
            if shouldYieldForPlayback, targetIndex.isMultiple(of: 1_024) {
                try? ImportWorkBudget.shared.waitIfPlaybackActive()
            }
            let unclampedStartIndex = targetIndex * sourceBinCount / targetBinCount
            let sourceStartIndex = min(max(unclampedStartIndex, 0), sourceBinCount - 1)
            let unclampedEndIndex = max(
                sourceStartIndex + 1,
                (targetIndex + 1) * sourceBinCount / targetBinCount
            )
            let sourceEndIndex = min(max(unclampedEndIndex, sourceStartIndex + 1), sourceBinCount)
            let sourceSpan = sourceEndIndex - sourceStartIndex
            let stride = max(sourceSpan / samplesPerBin, 1)
            var accumulator = WaveformBinAccumulator()
            var sampledIndex = sourceStartIndex
            var sampledCount = 0

            while sampledIndex < sourceEndIndex, sampledIndex < sourceBinCount, sampledCount < samplesPerBin {
                accumulator.addBin(sourceBins[sampledIndex])
                sampledIndex += stride
                sampledCount += 1
            }

            if sourceSpan > 1, sourceEndIndex > sourceStartIndex, sourceEndIndex <= sourceBinCount {
                accumulator.addBin(sourceBins[sourceEndIndex - 1])
            }

            bins.append(accumulator.makeBin())
        }

        return WaveformOverview(duration: waveformOverview.duration, bins: bins)
    }

    private func cachedWaveformMipLevels(for track: TimelineRenderState.Track) -> [WaveformMipLevel] {
        guard let waveformOverview = track.waveformOverview, !waveformOverview.isEmpty else {
            return []
        }

        let key = waveformMipCacheKey(for: track)
        guard let key else {
            return []
        }

        waveformMipLevelCacheLock.lock()
        if let cachedLevels = waveformMipLevelCache[key] {
            markWaveformMipCacheRecentlyUsedLocked(key)
            waveformMipLevelCacheLock.unlock()
            return cachedLevels
        }
        waveformMipLevelCacheLock.unlock()

        let initialLevels = makeInitialWaveformMipLevels(from: waveformOverview)
        publishWaveformMipLevelsToCache(initialLevels, for: key)
        scheduleCompleteWaveformMipLevelBuild(for: key, waveformOverview: waveformOverview)

        return initialLevels
    }

    private func waveformMipCacheKey(for track: TimelineRenderState.Track) -> WaveformMipCacheKey? {
        guard let waveformOverview = track.waveformOverview, !waveformOverview.isEmpty else {
            return nil
        }

        return WaveformMipCacheKey(
            trackID: track.id,
            waveformVersion: track.waveformVersion,
            binCount: waveformOverview.bins.count,
            duration: waveformOverview.duration
        )
    }

    private func scheduleCompleteWaveformMipLevelBuild(
        for key: WaveformMipCacheKey,
        waveformOverview: WaveformOverview
    ) {
        guard waveformOverview.bins.count > maximumSynchronousGeneratedWaveformMipBins else {
            return
        }

        waveformMipLevelCacheLock.lock()
        guard
            !waveformMipLevelBuildsInFlight.contains(key),
            waveformMipLevelBuildsInFlight.count < maximumInFlightWaveformMipBuilds
        else {
            waveformMipLevelCacheLock.unlock()
            return
        }
        waveformMipLevelBuildsInFlight.insert(key)
        waveformMipLevelCacheLock.unlock()

        waveformGeometryQueue.async { [weak self] in
            guard let self else {
                return
            }

            let levels = self.makeWaveformMipLevels(
                from: waveformOverview,
                shouldYieldForPlayback: true
            )
            self.publishCompleteWaveformMipLevels(levels, for: key)
        }
    }

    private func publishCompleteWaveformMipLevels(
        _ levels: [WaveformMipLevel],
        for key: WaveformMipCacheKey
    ) {
        publishWaveformMipLevelsToCache(levels, for: key)

        var shouldNotify = false
        waveformMipLevelStateLock.lock()
        if currentTrackWaveformMipKeys[key.trackID] == key {
            trackWaveformMipLevels[key.trackID] = levels
            if currentPrimaryWaveformTrackID == key.trackID {
                waveformMipLevels = levels
            }
            shouldNotify = true
        }
        waveformMipLevelStateLock.unlock()

        waveformMipLevelCacheLock.lock()
        waveformMipLevelBuildsInFlight.remove(key)
        waveformMipLevelCacheLock.unlock()

        if shouldNotify {
            onRenderDataPrepared?()
        }
    }

    private func publishWaveformMipLevelsToCache(
        _ levels: [WaveformMipLevel],
        for key: WaveformMipCacheKey
    ) {
        waveformMipLevelCacheLock.lock()
        while waveformMipLevelCache.count >= maximumCachedWaveformMipPyramids,
              let oldestKey = waveformMipLevelCacheOrder.first
        {
            waveformMipLevelCacheOrder.removeFirst()
            waveformMipLevelCache.removeValue(forKey: oldestKey)
            waveformMipLevelBuildsInFlight.remove(oldestKey)
        }

        waveformMipLevelCache[key] = levels
        markWaveformMipCacheRecentlyUsedLocked(key)
        waveformMipLevelCacheLock.unlock()
    }

    private func markWaveformMipCacheRecentlyUsedLocked(_ key: WaveformMipCacheKey) {
        waveformMipLevelCacheOrder.removeAll { $0 == key }
        waveformMipLevelCacheOrder.append(key)
    }

    private func waveformMipLevel(
        for drawableSize: CGSize,
        renderState: TimelineRenderState,
        mipLevels: [WaveformMipLevel]
    ) -> WaveformMipLevel? {
        guard let index = waveformMipLevelIndex(
            for: drawableSize,
            renderState: renderState,
            mipLevels: mipLevels
        ) else {
            return nil
        }

        return mipLevels[index]
    }

    private func waveformMipLevelIndex(
        for drawableSize: CGSize,
        renderState: TimelineRenderState,
        mipLevels: [WaveformMipLevel]
    ) -> Int? {
        guard !mipLevels.isEmpty else {
            return nil
        }

        if
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0
        {
            let visibleDuration = projectDuration * Double(renderState.viewport.durationProgress)
            if visibleDuration <= highResolutionWaveformVisibleDurationThreshold {
                return mipLevels.startIndex
            }
        }

        let width = max(Float(drawableSize.width), 1)
        let targetVisibleBins = max(width * waveformMipTargetBinsPerPoint, 8_192)

        for (index, mipLevel) in mipLevels.enumerated() {
            let visibleBins = Float(mipLevel.binCount) * renderState.viewport.durationProgress
            if visibleBins <= targetVisibleBins {
                return index
            }
        }

        return mipLevels.indices.last
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

    private func appendVerticalGradientRectangle(
        to vertices: inout [TimelineVertex],
        left: Float,
        right: Float,
        top: Float,
        bottom: Float,
        topColor: SIMD4<Float>,
        bottomColor: SIMD4<Float>
    ) {
        guard right > left, bottom > top else {
            return
        }

        let topLeft = makeVertex(
            normalizedPosition: SIMD2<Float>(left, top),
            color: topColor
        )
        let topRight = makeVertex(
            normalizedPosition: SIMD2<Float>(right, top),
            color: topColor
        )
        let bottomLeft = makeVertex(
            normalizedPosition: SIMD2<Float>(left, bottom),
            color: bottomColor
        )
        let bottomRight = makeVertex(
            normalizedPosition: SIMD2<Float>(right, bottom),
            color: bottomColor
        )

        vertices.append(topLeft)
        vertices.append(topRight)
        vertices.append(bottomLeft)
        vertices.append(topRight)
        vertices.append(bottomRight)
        vertices.append(bottomLeft)
    }

    private func appendSoftParticle(
        to vertices: inout [TimelineVertex],
        center: SIMD2<Float>,
        radius: Float,
        color: SIMD3<Float>,
        alpha: Float,
        drawableSize: SIMD2<Float>
    ) {
        guard
            drawableSize.x > 0,
            drawableSize.y > 0,
            radius > 0,
            alpha > 0
        else {
            return
        }

        if
            center.x + radius < 0 ||
            center.x - radius > drawableSize.x ||
            center.y + radius < 0 ||
            center.y - radius > drawableSize.y
        {
            return
        }

        let segmentCount = 12
        let centerVertex = makeVertex(
            normalizedPosition: SIMD2<Float>(
                center.x / drawableSize.x,
                center.y / drawableSize.y
            ),
            color: SIMD4<Float>(color.x, color.y, color.z, alpha)
        )

        for segmentIndex in 0..<segmentCount {
            let startAngle = Float(segmentIndex) / Float(segmentCount) * Float.pi * 2
            let endAngle = Float(segmentIndex + 1) / Float(segmentCount) * Float.pi * 2
            let start = SIMD2<Float>(
                center.x + cos(startAngle) * radius,
                center.y + sin(startAngle) * radius
            )
            let end = SIMD2<Float>(
                center.x + cos(endAngle) * radius,
                center.y + sin(endAngle) * radius
            )
            let edgeColor = SIMD4<Float>(color.x, color.y, color.z, 0)
            vertices.append(centerVertex)
            vertices.append(makeVertex(
                normalizedPosition: SIMD2<Float>(start.x / drawableSize.x, start.y / drawableSize.y),
                color: edgeColor
            ))
            vertices.append(makeVertex(
                normalizedPosition: SIMD2<Float>(end.x / drawableSize.x, end.y / drawableSize.y),
                color: edgeColor
            ))
        }
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

        let distanceRatio = abs(offsetFromPlayhead) / max(trailRadius, .ulpOfOne)
        return contactTrailFalloff(distanceRatio: distanceRatio)
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

        let distanceRatio = abs(offsetFromPlayhead) / max(trailRadius, .ulpOfOne)
        return contactTrailFalloff(distanceRatio: distanceRatio)
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

    private func contactTrailFalloff(distanceRatio: Float) -> Float {
        let distanceRatio = max(distanceRatio, 0)
        let exponent = max(playheadTouchTrailFalloffSteepness, 0.25)
        let referenceInfluence = min(max(playheadTouchTrailReferenceInfluence, 0.000_1), 0.5)
        let referenceScale = Float(pow(Double(-log(referenceInfluence)), 1 / Double(exponent)))
        let poweredDistance = pow(Double(distanceRatio * referenceScale), Double(exponent))
        return Float(exp(-poweredDistance))
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

    struct WaveformShaderQuadVertex {
        float4 position;
    };

    struct WaveformShaderUniform {
        float4 baseColor;
        float4 lane;
        float4 track;
        float4 viewport;
        float4 style;
        float4 style2;
        float4 gainPreview;
        float4 fisheye;
        float4 touch;
        float4 touch2;
    };

    struct WaveformShaderBin {
        float minimumSample;
        float maximumSample;
        float rmsSample;
        float lowEnergy;
        float midEnergy;
        float highEnergy;
        float peakMagnitude;
        float reserved;
    };

    struct RasterizedVertex {
        float4 position [[position]];
        float4 color;
    };

    struct WaveformRasterizedVertex {
        float4 position [[position]];
        float2 normalizedPosition;
        float4 baseColor;
        float4 lane;
        float4 track;
        float4 viewport;
        float4 style;
        float4 style2;
        float4 gainPreview;
        float4 fisheye;
        float4 touch;
        float4 touch2;
    };

    float fisheye_focus_weight(float normalizedDistance) {
        float t = clamp(normalizedDistance, 0.0, 1.0);
        return exp(-pow(t / 0.34, 6.0));
    }

    float fisheye_warped_normalized_distance(float normalizedDistance, float exponent) {
        float t = clamp(normalizedDistance, 0.0, 1.0);
        float strength = clamp(1.0 - exponent, 0.0, 1.0);
        float centerDisplacement = t *
            exp(-pow(t / 0.32, 4.0)) *
            pow(max(1.0 - t, 0.0), 3.0);
        return clamp(t + strength * 3.0 * centerDisplacement, 0.0, 1.0);
    }

    float fisheye_x(float x, float4 fisheye) {
        float radius = fisheye.y;
        float exponent = fisheye.z;
        if (radius <= 0.0 || exponent <= 0.0 || exponent >= 0.999) {
            return x;
        }

        float center = fisheye.x;
        float dx = x - center;
        float distance = abs(dx);
        if (distance <= 0.000001 || distance >= radius) {
            return x;
        }

        float t = clamp(distance / radius, 0.0, 1.0);
        float warpedDistance = radius * fisheye_warped_normalized_distance(t, exponent);
        return clamp(center + sign(dx) * warpedDistance, 0.0, 1.0);
    }

    float inverse_fisheye_x(float x, float4 fisheye) {
        float radius = fisheye.y;
        float exponent = fisheye.z;
        if (radius <= 0.0 || exponent <= 0.0 || exponent >= 0.999) {
            return x;
        }

        float center = fisheye.x;
        float dx = x - center;
        float distance = abs(dx);
        if (distance <= 0.000001 || distance >= radius) {
            return x;
        }

        float target = clamp(distance / radius, 0.0, 1.0);
        float lowerBound = 0.0;
        float upperBound = 1.0;
        for (uint iteration = 0; iteration < 10; ++iteration) {
            float midpoint = (lowerBound + upperBound) * 0.5;
            float warpedMidpoint = fisheye_warped_normalized_distance(midpoint, exponent);
            if (warpedMidpoint < target) {
                lowerBound = midpoint;
            } else {
                upperBound = midpoint;
            }
        }

        float t = (lowerBound + upperBound) * 0.5;
        float unwarpedDistance = radius * t;
        return clamp(center + sign(dx) * unwarpedDistance, 0.0, 1.0);
    }

    vertex RasterizedVertex timeline_vertex(
        uint vertexID [[vertex_id]],
        constant TimelineVertex *vertices [[buffer(0)]],
        constant float4 &fisheye [[buffer(1)]],
        constant float4 &xTransform [[buffer(2)]]
    ) {
        float2 normalizedPosition = vertices[vertexID].position.xy;
        normalizedPosition.x = normalizedPosition.x * xTransform.x + xTransform.y;
        normalizedPosition.x = fisheye_x(normalizedPosition.x, fisheye);

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

    vertex WaveformRasterizedVertex waveform_vertex(
        uint vertexID [[vertex_id]],
        constant WaveformShaderQuadVertex *vertices [[buffer(0)]],
        constant WaveformShaderUniform &uniforms [[buffer(1)]]
    ) {
        float2 normalizedPosition = vertices[vertexID].position.xy;
        normalizedPosition.y = mix(uniforms.lane.x, uniforms.lane.y, normalizedPosition.y);

        WaveformRasterizedVertex out;
        out.position = float4(
            normalizedPosition.x * 2.0 - 1.0,
            1.0 - normalizedPosition.y * 2.0,
            0.0,
            1.0
        );
        out.normalizedPosition = normalizedPosition;
        out.baseColor = uniforms.baseColor;
        out.lane = uniforms.lane;
        out.track = uniforms.track;
        out.viewport = uniforms.viewport;
        out.style = uniforms.style;
        out.style2 = uniforms.style2;
        out.gainPreview = uniforms.gainPreview;
        out.fisheye = uniforms.fisheye;
        out.touch = uniforms.touch;
        out.touch2 = uniforms.touch2;
        return out;
    }

    fragment float4 timeline_fragment(
        RasterizedVertex in [[stage_in]],
        constant float &opacity [[buffer(1)]]
    ) {
        return float4(in.color.rgb, in.color.a * opacity);
    }

    static WaveformShaderBin sample_waveform_bin(
        float localProgress,
        constant WaveformShaderBin *bins,
        uint binCount,
        float smoothAmount
    ) {
        uint count = max(binCount, 1u);
        float clampedProgress = clamp(localProgress, 0.0, 0.999999);
        uint nearestIndex = min(uint(floor(clampedProgress * float(count))), count - 1u);
        WaveformShaderBin nearestBin = bins[nearestIndex];
        if (smoothAmount <= 0.001 || count <= 1u) {
            return nearestBin;
        }

        float scaledIndex = clamp(clampedProgress * float(count) - 0.5, 0.0, float(count - 1u));
        uint leftIndex = uint(floor(scaledIndex));
        uint rightIndex = min(leftIndex + 1u, count - 1u);
        float amount = fract(scaledIndex);
        WaveformShaderBin leftBin = bins[leftIndex];
        WaveformShaderBin rightBin = bins[rightIndex];
        WaveformShaderBin linearBin;
        linearBin.minimumSample = mix(leftBin.minimumSample, rightBin.minimumSample, amount);
        linearBin.maximumSample = mix(leftBin.maximumSample, rightBin.maximumSample, amount);
        linearBin.rmsSample = mix(leftBin.rmsSample, rightBin.rmsSample, amount);
        linearBin.lowEnergy = mix(leftBin.lowEnergy, rightBin.lowEnergy, amount);
        linearBin.midEnergy = mix(leftBin.midEnergy, rightBin.midEnergy, amount);
        linearBin.highEnergy = mix(leftBin.highEnergy, rightBin.highEnergy, amount);
        linearBin.peakMagnitude = mix(leftBin.peakMagnitude, rightBin.peakMagnitude, amount);
        linearBin.reserved = 0.0;

        float blendAmount = clamp(smoothAmount, 0.0, 1.0);
        WaveformShaderBin result;
        result.minimumSample = mix(nearestBin.minimumSample, linearBin.minimumSample, blendAmount);
        result.maximumSample = mix(nearestBin.maximumSample, linearBin.maximumSample, blendAmount);
        result.rmsSample = mix(nearestBin.rmsSample, linearBin.rmsSample, blendAmount);
        result.lowEnergy = mix(nearestBin.lowEnergy, linearBin.lowEnergy, blendAmount);
        result.midEnergy = mix(nearestBin.midEnergy, linearBin.midEnergy, blendAmount);
        result.highEnergy = mix(nearestBin.highEnergy, linearBin.highEnergy, blendAmount);
        result.peakMagnitude = mix(nearestBin.peakMagnitude, linearBin.peakMagnitude, blendAmount);
        result.reserved = 0.0;
        return result;
    }

    static float fisheye_sample_smoothing(float x, float4 fisheye) {
        float radius = fisheye.y;
        float energy = fisheye.w;
        if (radius <= 0.000001 || energy <= 0.000001) {
            return 0.0;
        }

        float distance = abs(x - fisheye.x);
        float normalizedDistance = clamp(distance / radius, 0.0, 1.0);
        float localAmount = fisheye_focus_weight(normalizedDistance);
        return clamp(localAmount * energy, 0.0, 1.0);
    }

    static float touch_trail_falloff(float distanceRatio, float exponent) {
        float clampedDistance = max(distanceRatio, 0.0);
        float safeExponent = max(exponent, 0.25);
        float referenceInfluence = 0.015;
        float referenceScale = pow(-log(referenceInfluence), 1.0 / safeExponent);
        return exp(-pow(clampedDistance * referenceScale, safeExponent));
    }

    static float touch_geometry_influence(float offsetFromPlayhead, float aheadRadius, float trailRadius, float exponent) {
        if (offsetFromPlayhead >= 0.0) {
            float proximity = 1.0 - min(offsetFromPlayhead / max(aheadRadius, 0.0000001), 1.0);
            proximity = clamp(proximity, 0.0, 1.0);
            return proximity * proximity * proximity * proximity;
        }

        return touch_trail_falloff(abs(offsetFromPlayhead) / max(trailRadius, 0.0000001), exponent);
    }

    static float touch_light_influence(float offsetFromPlayhead, float aheadRadius, float trailRadius, float exponent) {
        if (offsetFromPlayhead >= 0.0) {
            float proximity = 1.0 - min(offsetFromPlayhead / max(aheadRadius, 0.0000001), 1.0);
            proximity = clamp(proximity, 0.0, 1.0);
            return proximity * proximity;
        }

        return touch_trail_falloff(abs(offsetFromPlayhead) / max(trailRadius, 0.0000001), exponent);
    }

    static float waveform_gain(float timelineProgress, float4 gainPreview) {
        if (gainPreview.w > 0.5 &&
            timelineProgress >= gainPreview.x &&
            timelineProgress <= gainPreview.y) {
            return max(gainPreview.z, 0.0);
        }

        return 1.0;
    }

    static float rectangle_coverage(float value, float start, float end, float aa) {
        float insideDistance = min(value - start, end - value);
        return smoothstep(0.0, aa, insideDistance);
    }

    static float4 color_with_alpha(float4 color, float alpha) {
        return float4(color.rgb, alpha);
    }

    static float4 lightened_color(float4 color, float amount, float alpha) {
        amount = clamp(amount, 0.0, 1.0);
        return float4(color.rgb + (float3(1.0) - color.rgb) * amount, alpha);
    }

    static float4 waveform_base_color(
        WaveformShaderBin bin,
        float baseGray,
        float alpha,
        float spectralAmount
    ) {
        float3 base = float3(baseGray);
        float3 lowTint = float3(0.54, 0.76, 0.92);
        float3 midTint = float3(0.88, 0.86, 0.80);
        float3 highTint = float3(0.94, 0.99, 0.97);
        float3 tint = lowTint * bin.lowEnergy +
            midTint * bin.midEnergy +
            highTint * bin.highEnergy;
        float energy = clamp(bin.rmsSample * 1.35 + bin.peakMagnitude * 0.22, 0.0, 1.0);
        float amount = spectralAmount * (0.35 + energy * 0.65);
        return float4(base + (tint - base) * amount, alpha);
    }

    static float4 source_over(float4 destination, float4 source) {
        float sourceAlpha = clamp(source.a, 0.0, 1.0);
        float destinationAlpha = clamp(destination.a, 0.0, 1.0);
        float outAlpha = sourceAlpha + destinationAlpha * (1.0 - sourceAlpha);
        if (outAlpha <= 0.000001) {
            return float4(0.0);
        }

        float3 outColor = (
            source.rgb * sourceAlpha +
            destination.rgb * destinationAlpha * (1.0 - sourceAlpha)
        ) / outAlpha;
        return float4(outColor, outAlpha);
    }

    static float4 center_weighted_waveform_band(
        float y,
        float top,
        float bottom,
        float centerY,
        float4 centerColor,
        float4 edgeColor,
        float aa
    ) {
        float coverage = rectangle_coverage(y, top, bottom, aa);
        if (coverage <= 0.0) {
            return float4(0.0);
        }

        float4 color = centerColor;
        if (top < centerY && centerY < bottom) {
            if (y < centerY) {
                float amount = clamp((y - top) / max(centerY - top, 0.000001), 0.0, 1.0);
                color = mix(edgeColor, centerColor, amount);
            } else {
                float amount = clamp((y - centerY) / max(bottom - centerY, 0.000001), 0.0, 1.0);
                color = mix(centerColor, edgeColor, amount);
            }
        }

        color.a *= coverage;
        return color;
    }

    fragment float4 waveform_fragment(
        WaveformRasterizedVertex in [[stage_in]],
        constant WaveformShaderBin *bins [[buffer(1)]],
        constant float &opacity [[buffer(2)]]
    ) {
        float laneTop = in.lane.x;
        float laneBottom = in.lane.y;
        float centerY = in.lane.z;
        float amplitudeHeight = in.lane.w;
        float trackDurationProgress = max(in.track.x, 0.000001);
        uint binCount = uint(max(in.track.y, 1.0));
        float sampleX = inverse_fisheye_x(in.normalizedPosition.x, in.fisheye);
        float timelineProgress = in.viewport.x + sampleX * in.viewport.y;

        if (timelineProgress < 0.0 ||
            timelineProgress > trackDurationProgress ||
            in.normalizedPosition.y < laneTop ||
            in.normalizedPosition.y > laneBottom) {
            return float4(0.0);
        }

        float localProgress = timelineProgress / trackDurationProgress;
        float smoothAmount = fisheye_sample_smoothing(in.normalizedPosition.x, in.fisheye);
        WaveformShaderBin bin = sample_waveform_bin(localProgress, bins, binCount, smoothAmount);
        float gain = waveform_gain(timelineProgress, in.gainPreview);
        float minimumSample = clamp(bin.minimumSample * gain, -1.0, 1.0);
        float maximumSample = clamp(bin.maximumSample * gain, -1.0, 1.0);
        float rmsSample = clamp(bin.rmsSample * gain, 0.0, 1.0);
        float touchEnergy = clamp(in.touch.w, 0.0, 1.0);
        float geometryInfluence = 0.0;
        float lightInfluence = 0.0;
        if (touchEnergy > 0.001 &&
            timelineProgress >= in.touch.z &&
            timelineProgress <= in.touch.y) {
            float offsetFromPlayhead = timelineProgress - in.touch.x;
            geometryInfluence = touch_geometry_influence(
                offsetFromPlayhead,
                in.touch2.x,
                in.touch2.z,
                in.touch2.w
            ) * touchEnergy;
            lightInfluence = touch_light_influence(
                offsetFromPlayhead,
                in.touch2.y,
                in.touch2.z,
                in.touch2.w
            ) * touchEnergy;
        }
        float expansion = 1.0 + 0.30 * geometryInfluence;

        float peakTop = centerY - maximumSample * amplitudeHeight * expansion;
        float peakBottom = centerY - minimumSample * amplitudeHeight * expansion;
        float minimumVisualHeight = (laneBottom - laneTop) * 0.006;
        if (peakBottom - peakTop < minimumVisualHeight) {
            float midpoint = (peakTop + peakBottom) * 0.5;
            peakTop = midpoint - minimumVisualHeight * 0.5;
            peakBottom = midpoint + minimumVisualHeight * 0.5;
        }

        peakTop = clamp(peakTop, laneTop, laneBottom);
        peakBottom = clamp(peakBottom, laneTop, laneBottom);
        float rmsHeight = max(rmsSample * amplitudeHeight, minimumVisualHeight * 0.7);
        float rmsTop = clamp(centerY - rmsHeight, laneTop, laneBottom);
        float rmsBottom = clamp(centerY + rmsHeight, laneTop, laneBottom);
        float y = in.normalizedPosition.y;
        float yAA = max(fwidth(y) * 0.75, 0.000001);
        float alphaScale = clamp(in.baseColor.a * opacity, 0.0, 1.0);
        float4 baseColor = waveform_base_color(bin, in.baseColor.r, alphaScale, in.style.x);
        if (lightInfluence > 0.001) {
            baseColor = lightened_color(baseColor, min(lightInfluence * 0.72, 1.0), alphaScale);
        }
        float4 color = float4(0.0);

        if (in.style.w > 0.001) {
            float glowTop = max(peakTop - in.style2.w, laneTop);
            float glowBottom = min(peakBottom + in.style2.w, laneBottom);
            float coverage = rectangle_coverage(y, glowTop, glowBottom, yAA);
            if (coverage > 0.0) {
                float4 glowColor = lightened_color(baseColor, 0.18, in.style.w * alphaScale * coverage);
                color = source_over(color, glowColor);
            }
        }

        float4 peakCenterColor = lightened_color(baseColor, 0.12, in.style.y * alphaScale);
        float4 peakEdgeColor = color_with_alpha(baseColor, in.style.y * 0.42 * alphaScale);
        color = source_over(
            color,
            center_weighted_waveform_band(
                y,
                peakTop,
                peakBottom,
                centerY,
                peakCenterColor,
                peakEdgeColor,
                yAA
            )
        );

        if (rmsBottom > rmsTop) {
            float4 rmsColor = lightened_color(baseColor, 0.22, in.style.z * alphaScale);
            color = source_over(
                color,
                center_weighted_waveform_band(
                    y,
                    rmsTop,
                    rmsBottom,
                    centerY,
                    rmsColor,
                    color_with_alpha(rmsColor, rmsColor.a * 0.50),
                    yAA
                )
            );
        }

        if (lightInfluence > 0.001) {
            float touchExpansion = max(in.style2.w * 1.45, yAA * 2.0);
            float touchGlowTop = max(peakTop - touchExpansion, laneTop);
            float touchGlowBottom = min(peakBottom + touchExpansion, laneBottom);
            float touchGlowCoverage = rectangle_coverage(y, touchGlowTop, touchGlowBottom, yAA);
            float touchCoreCoverage = rectangle_coverage(y, peakTop, peakBottom, yAA);
            float touchCoverage = max(touchCoreCoverage, touchGlowCoverage * 0.42);
            if (touchCoverage > 0.0) {
                float shapedLight = smoothstep(0.0, 1.0, clamp(lightInfluence, 0.0, 1.0));
                float touchAlpha = alphaScale * touchCoverage * min(shapedLight * 0.92, 0.94);
                float3 touchRGB = mix(baseColor.rgb, float3(1.0), 0.82 + shapedLight * 0.16);
                color = source_over(color, float4(touchRGB, touchAlpha));
            }
        }

        float transientStrength = max(bin.highEnergy - in.style2.y, 0.0) /
            max(1.0 - in.style2.y, 0.001);
        if (transientStrength > 0.001) {
            float binPhase = fract(clamp(localProgress, 0.0, 0.999999) * float(binCount));
            float phaseAA = max(fwidth(localProgress * float(binCount)) * 0.5, 0.0005);
            float xCoverage = smoothstep(0.34, 0.34 + phaseAA, binPhase) *
                (1.0 - smoothstep(0.66 - phaseAA, 0.66, binPhase));
            float yCoverage = rectangle_coverage(y, peakTop, peakBottom, yAA);
            float coverage = xCoverage * yCoverage;
            if (coverage > 0.0) {
                float4 transientColor = lightened_color(
                    baseColor,
                    0.45,
                    transientStrength * in.style2.x * alphaScale * coverage
                );
                color = source_over(color, transientColor);
            }
        }

        if (in.style2.z > 0.001) {
            float centerTop = max(centerY - minimumVisualHeight * 0.28, laneTop);
            float centerBottom = min(centerY + minimumVisualHeight * 0.28, laneBottom);
            float coverage = rectangle_coverage(y, centerTop, centerBottom, yAA);
            if (coverage > 0.0) {
                float4 centerColor = lightened_color(baseColor, 0.18, in.style2.z * alphaScale * coverage);
                color = source_over(color, centerColor);
            }
        }

        return color;
    }
    """
}
