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
    let effectVertexCount: Int
    let effectDroppedVertexCount: Int
    let transientParticleCount: Int
    let deletionEffectCount: Int
    let playheadContactEventCount: Int
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

    private struct TimelineRulerUniform {
        var viewport: SIMD4<Float>
        var metrics: SIMD4<Float>
        var style: SIMD4<Float>
        var color: SIMD4<Float>
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
        var touch3: SIMD4<Float>
    }

    private struct DeletionEffectUniform {
        var rect: SIMD4<Float>
        var overlayRect: SIMD4<Float>
        var timing: SIMD4<Float>
        var metrics: SIMD4<Float>
        var ripple: SIMD4<Float>
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
        let trackHeight: Float
        let trackScrollOffset: Float
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
        let binOffset: Int
    }

    private struct WaveformShaderBufferAllocation {
        let buffer: MTLBuffer
        let binOffset: Int
        let binCount: Int
        let byteCount: Int
    }

    private struct WaveformShaderBatch {
        let key: ObjectIdentifier
        let buffer: MTLBuffer
        var uniforms: [WaveformShaderUniform]
    }

    private enum WaveformShaderFallbackPolicy {
        case allowFallbacks
        case preferredOnly
    }

    private final class WaveformShaderBufferStore: @unchecked Sendable {
        private struct Slab {
            let buffer: MTLBuffer
            let capacityBins: Int
            var usedBins: Int
        }

        private let lock = NSLock()
        private let device: MTLDevice
        private let preferredSlabBinCapacity: Int
        private var slabs: [Slab] = []
        private var allocations: [WaveformMipCacheKey: WaveformShaderBufferAllocation] = [:]
        private var accessTicks: [WaveformMipCacheKey: Int] = [:]
        private var accessTick = 0
        private var inFlightKeys: Set<WaveformMipCacheKey> = []
        private var publishedBufferCount = 0

        init(device: MTLDevice, preferredSlabBinCapacity: Int) {
            self.device = device
            self.preferredSlabBinCapacity = max(preferredSlabBinCapacity, 1)
        }

        func allocation(for key: WaveformMipCacheKey) -> WaveformShaderBufferAllocation? {
            lock.lock()
            defer {
                lock.unlock()
            }
            guard let allocation = allocations[key] else {
                return nil
            }

            markAccessed(key)
            return allocation
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
                allocations[key] == nil,
                !inFlightKeys.contains(key),
                inFlightKeys.count < max(maximumInFlightCount, 1)
            else {
                return false
            }
            inFlightKeys.insert(key)
            return true
        }

        func publish(_ bins: [WaveformShaderBin]?, for key: WaveformMipCacheKey) {
            lock.lock()
            if let bins, !bins.isEmpty {
                publishLocked(bins, for: key)
            }
            inFlightKeys.remove(key)
            lock.unlock()
        }

        private func publishLocked(_ bins: [WaveformShaderBin], for key: WaveformMipCacheKey) {
            guard allocations[key] == nil else {
                markAccessed(key)
                publishedBufferCount += 1
                return
            }

            let binCount = bins.count
            guard let slabIndex = slabIndexForAllocation(binCount: binCount) else {
                return
            }

            let binOffset = slabs[slabIndex].usedBins
            let byteOffset = binOffset * MemoryLayout<WaveformShaderBin>.stride
            let byteCount = binCount * MemoryLayout<WaveformShaderBin>.stride
            bins.withUnsafeBytes { sourceBytes in
                guard let baseAddress = sourceBytes.baseAddress else {
                    return
                }

                slabs[slabIndex].buffer.contents()
                    .advanced(by: byteOffset)
                    .copyMemory(from: baseAddress, byteCount: byteCount)
            }

            let allocation = WaveformShaderBufferAllocation(
                buffer: slabs[slabIndex].buffer,
                binOffset: binOffset,
                binCount: binCount,
                byteCount: byteCount
            )
            allocations[key] = allocation
            slabs[slabIndex].usedBins += binCount
            markAccessed(key)
            publishedBufferCount += 1
        }

        private func slabIndexForAllocation(binCount: Int) -> Int? {
            if let index = slabs.indices.first(where: {
                slabs[$0].capacityBins - slabs[$0].usedBins >= binCount
            }) {
                return index
            }

            let capacityBins = max(preferredSlabBinCapacity, nextPowerOfTwo(binCount))
            let byteCount = capacityBins * MemoryLayout<WaveformShaderBin>.stride
            guard let buffer = device.makeBuffer(length: byteCount, options: [.storageModeShared]) else {
                return nil
            }
            buffer.label = "Timeline waveform bin arena slab \(slabs.count)"
            slabs.append(Slab(buffer: buffer, capacityBins: capacityBins, usedBins: 0))
            return slabs.indices.last
        }

        private func nextPowerOfTwo(_ value: Int) -> Int {
            guard value > 1 else {
                return 1
            }

            var result = 1
            while result < value {
                result <<= 1
            }
            return result
        }

        func publish(_ buffer: MTLBuffer?, for key: WaveformMipCacheKey) {
            lock.lock()
            if let buffer {
                let allocation = WaveformShaderBufferAllocation(
                    buffer: buffer,
                    binOffset: 0,
                    binCount: max(buffer.length / MemoryLayout<WaveformShaderBin>.stride, 1),
                    byteCount: buffer.length
                )
                allocations[key] = allocation
                markAccessed(key)
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

            let totalSlabByteCount = slabs.reduce(0) { result, slab in
                result + slab.buffer.length
            }
            return (allocations.count, totalSlabByteCount, inFlightKeys.count)
        }

        func trim(toMaximumCount maximumCount: Int, maximumByteCount: Int) {
            lock.lock()
            if allocations.count > maximumCount || diagnosticsByteCountLocked() > maximumByteCount {
                compactAllocationsLocked(
                    maximumCount: max(maximumCount, 1),
                    maximumByteCount: max(maximumByteCount, 0)
                )
            } else {
                compactAccessTicksLocked()
            }
            lock.unlock()
        }

        private func diagnosticsByteCountLocked() -> Int {
            slabs.reduce(0) { result, slab in
                result + slab.buffer.length
            }
        }

        private func compactAccessTicksLocked() {
            accessTicks = accessTicks.filter { key, _ in
                allocations[key] != nil || inFlightKeys.contains(key)
            }
        }

        private func compactAllocationsLocked(maximumCount: Int, maximumByteCount: Int) {
            guard !allocations.isEmpty else {
                slabs.removeAll()
                compactAccessTicksLocked()
                return
            }

            let rankedKeys = allocations.keys.sorted { lhs, rhs in
                (accessTicks[lhs] ?? 0) > (accessTicks[rhs] ?? 0)
            }
            var keptAllocations: [(key: WaveformMipCacheKey, allocation: WaveformShaderBufferAllocation)] = []
            keptAllocations.reserveCapacity(min(maximumCount, allocations.count))
            var keptByteCount = 0

            for key in rankedKeys {
                guard let allocation = allocations[key] else {
                    continue
                }

                let projectedByteCount = keptByteCount + allocation.byteCount
                let fitsCount = keptAllocations.count < maximumCount
                let fitsBytes = projectedByteCount <= maximumByteCount || keptAllocations.isEmpty
                guard fitsCount, fitsBytes else {
                    continue
                }

                keptAllocations.append((key, allocation))
                keptByteCount = projectedByteCount
            }

            let oldAllocations = keptAllocations
            slabs.removeAll(keepingCapacity: true)
            allocations.removeAll(keepingCapacity: true)

            for item in oldAllocations {
                let binCount = item.allocation.binCount
                guard let slabIndex = slabIndexForAllocation(binCount: binCount) else {
                    continue
                }

                let destinationBinOffset = slabs[slabIndex].usedBins
                let destinationByteOffset = destinationBinOffset * MemoryLayout<WaveformShaderBin>.stride
                let sourceByteOffset = item.allocation.binOffset * MemoryLayout<WaveformShaderBin>.stride
                let sourcePointer = item.allocation.buffer.contents().advanced(by: sourceByteOffset)
                let destinationPointer = slabs[slabIndex].buffer.contents().advanced(by: destinationByteOffset)
                destinationPointer.copyMemory(from: sourcePointer, byteCount: item.allocation.byteCount)

                allocations[item.key] = WaveformShaderBufferAllocation(
                    buffer: slabs[slabIndex].buffer,
                    binOffset: destinationBinOffset,
                    binCount: binCount,
                    byteCount: item.allocation.byteCount
                )
                slabs[slabIndex].usedBins += binCount
            }

            compactAccessTicksLocked()
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

    private struct DeletionEffect {
        let selection: TimelineSelection
        let visualAnchor: SIMD4<Float>
        let capturedBinBuffer: MTLBuffer?
        let capturedBinCount: Int
        let trailingBinCount: Int
        var birthTimestamp: CFTimeInterval
        let seed: UInt64
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
    private let rulerPipelineState: MTLRenderPipelineState
    private let additivePipelineState: MTLRenderPipelineState
    private let deletionEffectPipelineState: MTLRenderPipelineState
    private let deletionParticlePipelineState: MTLRenderPipelineState
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
    private let waveformShaderBufferStore: WaveformShaderBufferStore
    private var waveformShaderBatchScratch: [WaveformShaderBatch] = []
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
    private var lastPlayheadContactEventTimestamp: CFTimeInterval?
    private var transientParticles: [TransientParticle] = []
    private var deletionEffects: [DeletionEffect] = []
    private let deletionEffectLock = NSLock()
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
    private var frameStatsEffectVertexCount = 0
    private var frameStatsEffectDroppedVertexCount = 0
    private var frameStatsTransientParticleCount = 0
    private var frameStatsDeletionEffectCount = 0
    private var frameStatsPlayheadContactEventCount = 0
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
            waveformMipCacheCount: waveformMipCacheDiagnostics().cacheCount,
            effectVertexCount: frameStatsEffectVertexCount,
            effectDroppedVertexCount: frameStatsEffectDroppedVertexCount,
            transientParticleCount: frameStatsTransientParticleCount,
            deletionEffectCount: frameStatsDeletionEffectCount,
            playheadContactEventCount: frameStatsPlayheadContactEventCount
        )
    }

    private let playheadTouchGeometryAheadDuration: TimeInterval = 0.055
    private let playheadTouchLightAheadDuration: TimeInterval = 0.08
    private var playheadTouchTrailDuration: TimeInterval = 0.56
    private var playheadTouchTrailFalloffSteepness: Float = 1.30
    private var waveformBaseGray: Float = 0.88
    private let waveformTransitionDuration: CFTimeInterval = 0.2
    private let playheadTouchDecayDuration: CFTimeInterval = 0.046
    private let playheadTouchPauseFadeDuration: CFTimeInterval = 0.20
    private let playheadKickDecayDuration: CFTimeInterval = 0.3
    private let playheadKickTrailDuration: CFTimeInterval = 0.38
    private let playheadKickTrailLineCount = 10
    private let playheadContactFadeDuration: CFTimeInterval = 0.6
    private let playheadTouchTrailReferenceInfluence: Float = 0.015
    private let playheadTouchTrailRenderInfluenceCutoff: Float = 0.000_05
    private let playheadTouchZoomedOutLightMinimumVisibleDuration: TimeInterval = 12
    private let playheadTouchZoomedOutLightFullVisibleDuration: TimeInterval = 180
    private let playheadTouchZoomedOutLightMaximumViewportFraction: Float = 0.035
    private let waveformFisheyeEnabled = SoundtimeFeatureFlags.waveformFisheye
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
    private var trackFisheyeAudibilitySignature: Int?
    private let playheadContactMaximumEventCount = 384
    private let playheadContactEventsPerTrackBudget = 8
    private let playheadContactMinimumSpawnInterval: CFTimeInterval = 1.0 / 90.0
    private let transientParticleMaximumCount = 260
    private let maximumTransientParticleVerticesPerFrame = 10_000
    private let deletionEffectDuration: CFTimeInterval = 0.44
    private let deletionShardCount = 96
    private let deletionEffectMaximumCount = 8
    private let deletionEffectMaximumCapturedBins = 512
    private let deletionRippleMaximumCapturedBins = 1_024
    private let transientParticleScorePercentile: Float = 0.997
    private let transientParticleProfileSampleLimit = 2_048
    private let transientParticleMinimumSpacing: TimeInterval = 0.32
    private let transientParticleMaximumScanDuration: TimeInterval = 0.12
    private let maximumInFlightTransientParticleScoreProfileBuilds = 4
    private let maximumSynchronousGeneratedWaveformMipBins = 8_192
    private let maximumInFlightWaveformMipBuilds = 4
    private let maximumGeneratedWaveformMipBins = 262_144
    private let generatedWaveformMipSamplesPerBin = 4
    private let highResolutionWaveformVisibleDurationThreshold: TimeInterval = 90
    private let waveformMipTargetBinsPerPoint: Float = 96
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
            let waveformFragmentFunction = library.makeFunction(name: "waveform_fragment"),
            let rulerVertexFunction = library.makeFunction(name: "timeline_ruler_vertex"),
            let rulerFragmentFunction = library.makeFunction(name: "timeline_ruler_fragment"),
            let deletionEffectVertexFunction = library.makeFunction(name: "deletion_effect_vertex"),
            let deletionEffectFragmentFunction = library.makeFunction(name: "deletion_effect_fragment"),
            let deletionParticleVertexFunction = library.makeFunction(name: "deletion_particle_vertex"),
            let deletionParticleFragmentFunction = library.makeFunction(name: "deletion_particle_fragment")
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
        let rulerDescriptor = MTLRenderPipelineDescriptor()
        rulerDescriptor.vertexFunction = rulerVertexFunction
        rulerDescriptor.fragmentFunction = rulerFragmentFunction
        rulerDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        rulerDescriptor.colorAttachments[0].isBlendingEnabled = true
        rulerDescriptor.colorAttachments[0].rgbBlendOperation = .add
        rulerDescriptor.colorAttachments[0].alphaBlendOperation = .add
        rulerDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        rulerDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        rulerDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        rulerDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
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
        let deletionEffectDescriptor = MTLRenderPipelineDescriptor()
        deletionEffectDescriptor.vertexFunction = deletionEffectVertexFunction
        deletionEffectDescriptor.fragmentFunction = deletionEffectFragmentFunction
        deletionEffectDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        deletionEffectDescriptor.colorAttachments[0].isBlendingEnabled = true
        deletionEffectDescriptor.colorAttachments[0].rgbBlendOperation = .add
        deletionEffectDescriptor.colorAttachments[0].alphaBlendOperation = .add
        deletionEffectDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        deletionEffectDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        deletionEffectDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        deletionEffectDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let deletionParticleDescriptor = MTLRenderPipelineDescriptor()
        deletionParticleDescriptor.vertexFunction = deletionParticleVertexFunction
        deletionParticleDescriptor.fragmentFunction = deletionParticleFragmentFunction
        deletionParticleDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        deletionParticleDescriptor.colorAttachments[0].isBlendingEnabled = true
        deletionParticleDescriptor.colorAttachments[0].rgbBlendOperation = .add
        deletionParticleDescriptor.colorAttachments[0].alphaBlendOperation = .add
        deletionParticleDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        deletionParticleDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        deletionParticleDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        deletionParticleDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

        self.device = device
        self.commandQueue = commandQueue
        self.dynamicVertexBufferRing = dynamicVertexBufferRing
        self.waveformQuadVertexBuffer = waveformQuadVertexBuffer
        waveformShaderBufferStore = WaveformShaderBufferStore(
            device: device,
            preferredSlabBinCapacity: 262_144
        )
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        waveformPipelineState = try device.makeRenderPipelineState(descriptor: waveformDescriptor)
        rulerPipelineState = try device.makeRenderPipelineState(descriptor: rulerDescriptor)
        additivePipelineState = try device.makeRenderPipelineState(descriptor: additiveDescriptor)
        deletionEffectPipelineState = try device.makeRenderPipelineState(descriptor: deletionEffectDescriptor)
        deletionParticlePipelineState = try device.makeRenderPipelineState(descriptor: deletionParticleDescriptor)

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

    func displayTracks(_ tracks: [TimelineRenderState.Track], animateWaveformTransition: Bool = true) {
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
        if animateWaveformTransition, renderState.hasWaveforms, hasNextWaveforms {
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
        lastPlayheadContactEventTimestamp = nil
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
        let durationHint = track.durationHint ?? track.waveformOverview?.duration ?? currentTrack?.durationHint
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
        if waveformFisheyeEnabled, restartsFisheyeActivation, renderState.isPlaybackActive {
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
            lastPlayheadContactEventTimestamp = nil
            resetTransientParticleScan(to: anchoredProgress)
        }
        previousRenderedPlayheadX = nil
        previousRenderedPlayheadTime = nil
    }

    func displayPlaybackActive(_ isActive: Bool) {
        let currentTime = CACurrentMediaTime()
        updatePlayheadTouchEnergy(isPlaybackActive: renderState.isPlaybackActive)
        updatePlayheadKickEnergy()
        if waveformFisheyeEnabled {
            updateWaveformFisheyeEnergy(at: currentTime)
        }
        let wasPlaybackActive = renderState.isPlaybackActive

        if wasPlaybackActive != isActive {
            if waveformFisheyeEnabled {
                startWaveformFisheyeRamp(to: isActive ? 1 : 0, at: currentTime)
            } else {
                waveformFisheyeEnergy = 0
                waveformFisheyeRampStartEnergy = 0
                waveformFisheyeRampTargetEnergy = 0
                waveformFisheyeRampStartTime = currentTime
            }
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
                lastPlayheadContactEventTimestamp = nil
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

    func displayTrackLayout(_ trackLayout: TimelineTrackLayout) {
        guard renderState.trackLayout != trackLayout else {
            return
        }

        gridCache = nil
        renderState = renderState.withTrackLayout(trackLayout)
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

    func inverseFisheyeViewportProgress(
        _ visualViewportProgress: Float,
        trackID: UUID?,
        timestamp: CFTimeInterval
    ) -> Float {
        let visualViewportProgress = min(max(visualViewportProgress, 0), 1)
        guard waveformFisheyeEnabled else {
            return visualViewportProgress
        }

        let playheadProgress = projectedPlayheadProgress(at: timestamp) ?? renderState.playheadProgress
        var fisheye = waveformFisheyeParameters(
            renderState: renderState,
            playheadProgress: playheadProgress,
            displayTimestamp: timestamp
        )
        if let trackID {
            fisheye = scaledWaveformFisheye(
                fisheye,
                by: trackFisheyeEnergy(for: trackID, at: timestamp)
            )
        }

        return inverseFisheyeX(visualViewportProgress, fisheye: fisheye)
    }

    private func deletionEffectVisualAnchor(
        for selection: TimelineSelection,
        displayTimestamp: CFTimeInterval
    ) -> SIMD4<Float> {
        let playheadProgress = projectedPlayheadProgress(at: displayTimestamp) ?? renderState.playheadProgress
        let baseFisheye = waveformFisheyeParameters(
            renderState: renderState,
            playheadProgress: playheadProgress,
            displayTimestamp: displayTimestamp
        )
        let effectFisheye = selectionFisheye(
            for: selection,
            renderState: renderState,
            baseFisheye: baseFisheye,
            displayTimestamp: displayTimestamp
        )

        var left = renderState.viewport.viewportProgress(
            forTimelineProgress: selection.startProgressFloat
        )
        var right = renderState.viewport.viewportProgress(
            forTimelineProgress: selection.endProgressFloat
        )
        left = fisheyeX(left, fisheye: effectFisheye)
        right = fisheyeX(right, fisheye: effectFisheye)
        if right < left {
            swap(&left, &right)
        }

        let trailingEndProgress = deletionTrailingDisplayEndProgress(
            for: selection,
            renderState: renderState
        )
        var trailingEnd = renderState.viewport.viewportProgress(
            forTimelineProgress: trailingEndProgress
        )
        trailingEnd = fisheyeX(trailingEnd, fisheye: effectFisheye)
        trailingEnd = max(trailingEnd, right)

        return SIMD4<Float>(left, right, trailingEnd, 0)
    }

    private func deletionTrailingDisplayEndProgress(
        for selection: TimelineSelection,
        renderState: TimelineRenderState
    ) -> Float {
        guard
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0
        else {
            return max(selection.endProgressFloat, renderState.viewport.endProgress)
        }

        let selectedTrack = selection.trackID.flatMap { trackID in
            renderState.tracks.first { $0.id == trackID }
        } ?? renderState.tracks.first
        let trackDuration = selectedTrack?.durationHint ?? projectDuration
        let trackEndProgress = Float(min(max(trackDuration / projectDuration, 0), 1))
        let visibleTrackEnd = min(trackEndProgress, renderState.viewport.endProgress)
        return max(selection.endProgressFloat, visibleTrackEnd)
    }

    func triggerDeletionEffect(selection: TimelineSelection, sourceSelection: TimelineSelection? = nil) {
        guard selection.durationProgress > 0 else {
            return
        }

        let capturedSelection = sourceSelection ?? selection
        var seed = UInt64(bitPattern: Int64(selection.trackID?.hashValue ?? 0))
        seed &+= UInt64((capturedSelection.startProgress * 1_000_000).rounded(.down))
        seed &*= 0x9E37_79B9_7F4A_7C15
        seed &+= UInt64((capturedSelection.endProgress * 1_000_000).rounded(.down))
        let displayTimestamp = CACurrentMediaTime()
        let visualAnchor = deletionEffectVisualAnchor(
            for: selection,
            displayTimestamp: displayTimestamp
        )
        let capturedBins = capturedDeletionBins(for: capturedSelection)
        let trailingBins = capturedDeletionTrailingBins(
            for: capturedSelection,
            displaySelection: selection
        )
        let capturedBinBuffer = makeDeletionWaveformBinBuffer(from: capturedBins + trailingBins)
        let effect = DeletionEffect(
            selection: selection,
            visualAnchor: visualAnchor,
            capturedBinBuffer: capturedBinBuffer,
            capturedBinCount: capturedBins.count,
            trailingBinCount: trailingBins.count,
            birthTimestamp: -1,
            seed: seed
        )

        deletionEffectLock.lock()
        deletionEffects.append(effect)
        if deletionEffects.count > deletionEffectMaximumCount {
            deletionEffects.removeFirst(deletionEffects.count - deletionEffectMaximumCount)
        }
        deletionEffectLock.unlock()
    }

    func clearDeletionEffects() {
        deletionEffectLock.lock()
        deletionEffects.removeAll()
        frameStatsDeletionEffectCount = 0
        deletionEffectLock.unlock()
    }

    private func capturedDeletionBins(for selection: TimelineSelection) -> [WaveformOverview.Bin] {
        guard let overview = deletionCaptureOverview(for: selection) else {
            return []
        }

        return capturedDeletionBins(
            in: overview,
            startProgress: selection.startProgress,
            endProgress: selection.endProgress,
            maximumBinCount: deletionEffectMaximumCapturedBins
        )
    }

    private func capturedDeletionTrailingBins(
        for selection: TimelineSelection,
        displaySelection: TimelineSelection
    ) -> [WaveformOverview.Bin] {
        guard
            let overview = deletionCaptureOverview(for: selection),
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0,
            overview.duration.isFinite,
            overview.duration > 0
        else {
            return []
        }

        let viewportEndTime = Double(renderState.viewport.endProgress) * projectDuration
        let displayEndTime = displaySelection.endProgress * projectDuration
        guard viewportEndTime > displayEndTime else {
            return []
        }

        let visibleEndProgress = min(
            max(viewportEndTime / overview.duration, selection.endProgress),
            1
        )
        return capturedDeletionBins(
            in: overview,
            startProgress: selection.endProgress,
            endProgress: visibleEndProgress,
            maximumBinCount: deletionRippleMaximumCapturedBins
        )
    }

    private func deletionCaptureOverview(for selection: TimelineSelection) -> WaveformOverview? {
        let selectedTrack = selection.trackID.flatMap { trackID in
            renderState.tracks.first { $0.id == trackID }
        } ?? renderState.tracks.first
        if let overview = selectedTrack?.waveformOverview, !overview.bins.isEmpty {
            return overview
        }

        guard let trackID = selectedTrack?.id ?? selection.trackID else {
            return nil
        }

        waveformMipLevelStateLock.lock()
        let mipLevels = trackWaveformMipLevels[trackID]
        waveformMipLevelStateLock.unlock()
        return mipLevels?.first { !$0.overview.bins.isEmpty }?.overview
    }

    private func capturedDeletionBins(
        in overview: WaveformOverview,
        startProgress: Double,
        endProgress: Double,
        maximumBinCount: Int
    ) -> [WaveformOverview.Bin] {
        let binCount = overview.bins.count
        guard binCount > 0 else {
            return []
        }

        let startIndex = min(
            max(Int((startProgress * Double(binCount)).rounded(.down)), 0),
            binCount
        )
        let endIndex = min(
            max(Int((endProgress * Double(binCount)).rounded(.up)), startIndex),
            binCount
        )
        guard startIndex < endIndex else {
            return []
        }

        let sourceCount = endIndex - startIndex
        let targetCount = min(sourceCount, max(maximumBinCount, 1))
        if sourceCount <= targetCount {
            return Array(overview.bins[startIndex..<endIndex])
        }

        var capturedBins: [WaveformOverview.Bin] = []
        capturedBins.reserveCapacity(targetCount)
        for targetIndex in 0..<targetCount {
            let sourceStart = startIndex + Int(
                (Double(targetIndex) / Double(targetCount)) * Double(sourceCount)
            )
            let sourceEnd = startIndex + Int(
                (Double(targetIndex + 1) / Double(targetCount)) * Double(sourceCount)
            )
            let clampedEnd = min(max(sourceEnd, sourceStart + 1), endIndex)
            var accumulator = WaveformBinAccumulator()
            for sourceIndex in sourceStart..<clampedEnd {
                accumulator.addBin(overview.bins[sourceIndex])
            }
            capturedBins.append(accumulator.makeBin())
        }

        return capturedBins
    }

    private func makeDeletionWaveformBinBuffer(from bins: [WaveformOverview.Bin]) -> MTLBuffer? {
        guard
            let shaderBins = makeWaveformShaderBins(from: bins),
            !shaderBins.isEmpty
        else {
            return nil
        }

        return shaderBins.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return nil
            }

            let metalBuffer = device.makeBuffer(
                bytes: baseAddress,
                length: buffer.count,
                options: [.storageModeShared, .cpuCacheModeWriteCombined]
            )
            metalBuffer?.label = "Timeline deletion captured waveform bins"
            return metalBuffer
        }
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
        let selectionFisheye = selectionFisheye(
            for: renderState.selection,
            renderState: renderState,
            baseFisheye: waveformFisheye,
            displayTimestamp: displayTimestamp
        )
        let selectedTrackVertices = makeSelectedTrackVertices(
            drawableSize: viewportSize,
            renderState: renderState
        )
        let selectionVertices = makeSelectionVertices(
            drawableSize: viewportSize,
            renderState: renderState
        )
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
            displayTimestamp: displayTimestamp,
            maximumVertexCount: maximumTransientParticleVerticesPerFrame
        )
        frameStatsEffectVertexCount += transientParticleVertices.count
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
        drawTimelineRulerTicks(
            drawableSize: viewportSize,
            backingScale: backingScale,
            renderState: renderState,
            encoder: encoder
        )
        encoder.setRenderPipelineState(pipelineState)
        draw(vertices: selectedTrackVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: selectionVertices, primitiveType: .triangle, encoder: encoder, fisheye: selectionFisheye)
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
                fallbackPolicy: .allowFallbacks,
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
        drawDeletionEffects(
            drawableSize: viewportSize,
            renderState: renderState,
            baseFisheye: waveformFisheye,
            displayTimestamp: displayTimestamp,
            encoder: encoder
        )
        encoder.setRenderPipelineState(pipelineState)
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
        touchParameters: (touch: SIMD4<Float>, touch2: SIMD4<Float>, touch3: SIMD4<Float>),
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

        guard !renderState.tracks.isEmpty else {
            return
        }

        let tracks = renderState.tracks
        let anySolo = tracks.contains { $0.isSoloed }
        let style = waveformVisualStyle(renderState: renderState, projectDuration: projectDuration)
        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        waveformShaderBatchScratch.removeAll(keepingCapacity: true)

        for trackIndex in trackLayout.visibleRange(overscan: 1) {
            guard tracks.indices.contains(trackIndex) else {
                continue
            }

            let track = tracks[trackIndex]
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

            guard let laneFrame = trackLayout.laneFrame(forTrackIndex: trackIndex), laneFrame.isVisible else {
                continue
            }

            let laneTop = laneFrame.top
            let laneBottom = laneFrame.bottom
            let centerY = laneFrame.center
            let amplitudeHeight = laneFrame.height * 0.39 * min(max(track.volume, 0), 1.8)
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
            let trackFisheye = fisheye.w > 0.000_1 ?
                scaledWaveformFisheye(
                    fisheye,
                    by: trackFisheyeEnergy(for: track.id, at: displayTimestamp)
                ) :
                .zero
            let uniform = makeWaveformShaderUniform(
                laneTop: laneTop,
                laneBottom: laneBottom,
                centerY: centerY,
                amplitudeHeight: amplitudeHeight,
                binCount: shaderDrawable.mipLevel.binCount,
                binOffset: shaderDrawable.binOffset,
                trackDurationProgress: trackDurationProgress,
                baseGray: gray,
                alpha: trackAlpha,
                style: style,
                drawableSize: drawableSize,
                backingScale: backingScale,
                fisheye: trackFisheye,
                touch: trackTouch,
                touch2: touchParameters.touch2,
                touch3: touchParameters.touch3,
                trackID: track.id,
                renderState: renderState
            )

            let batchKey = ObjectIdentifier(shaderDrawable.buffer)
            if let batchIndex = waveformShaderBatchScratch.firstIndex(where: { $0.key == batchKey }) {
                waveformShaderBatchScratch[batchIndex].uniforms.append(uniform)
            } else {
                var batch = WaveformShaderBatch(
                    key: batchKey,
                    buffer: shaderDrawable.buffer,
                    uniforms: []
                )
                batch.uniforms.reserveCapacity(8)
                batch.uniforms.append(uniform)
                waveformShaderBatchScratch.append(batch)
            }
        }

        for batch in waveformShaderBatchScratch {
            drawWaveformShaderBatch(
                uniforms: batch.uniforms,
                binBuffer: batch.buffer,
                opacity: 1,
                encoder: encoder
            )
        }

        waveformShaderBatchScratch.removeAll(keepingCapacity: true)
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
        binOffset: Int,
        trackDurationProgress: Float,
        baseGray: Float,
        alpha: Float,
        style: WaveformVisualStyle,
        drawableSize: CGSize,
        backingScale: Float,
        fisheye: SIMD4<Float>,
        touch: SIMD4<Float>,
        touch2: SIMD4<Float>,
        touch3: SIMD4<Float>,
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
        let commonTrack = SIMD4<Float>(
            trackDurationProgress,
            Float(max(binCount, 1)),
            Float(max(binOffset, 0)),
            waveformSampleSmoothingAmount(
                drawableSize: drawableSize,
                binCount: binCount,
                trackDurationProgress: trackDurationProgress,
                renderState: renderState
            )
        )
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
            touch2: touch2,
            touch3: touch3
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

        let tracks = renderState.tracks
        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        var checkedRenderableTrack = false
        for trackIndex in trackLayout.visibleRange(overscan: 1) {
            guard tracks.indices.contains(trackIndex) else {
                continue
            }

            let track = tracks[trackIndex]
            guard track.hasWaveform else {
                continue
            }

            guard
                let trackDuration = track.durationHint,
                trackDuration.isFinite,
                trackDuration > 0,
                let mipLevels = trackWaveformMipLevels[track.id]
            else {
                return false
            }

            let trackDurationProgress = min(max(Float(trackDuration / projectDuration), 0), 1)
            guard trackDurationProgress > 0 else {
                return false
            }

            checkedRenderableTrack = true
            guard waveformShaderDrawable(
                track: track,
                mipLevels: mipLevels,
                drawableSize: drawableSize,
                renderState: renderState,
                fallbackPolicy: .allowFallbacks
            ) != nil else {
                return false
            }
        }

        return checkedRenderableTrack
    }

    private func waveformSampleSmoothingAmount(
        drawableSize: CGSize,
        binCount: Int,
        trackDurationProgress: Float,
        renderState: TimelineRenderState
    ) -> Float {
        let trackViewportProgress = min(
            max(renderState.viewport.durationProgress / max(trackDurationProgress, 0.000_001), 0),
            1
        )
        let visibleBins = max(Float(max(binCount, 1)) * trackViewportProgress, 1)
        let pointsPerBin = Float(max(drawableSize.width, 1)) / visibleBins
        let adaptiveSmoothing = min(max((pointsPerBin - 0.08) / 1.65, 0), 0.88)
        return min(max(adaptiveSmoothing, 0.18), 0.96)
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
        if let allocation = waveformShaderAllocation(track: track, mipLevel: preferredMipLevel) {
            return WaveformShaderDrawable(
                mipLevel: preferredMipLevel,
                buffer: allocation.buffer,
                binOffset: allocation.binOffset
            )
        }

        prepareWaveformShaderBinBuffer(
            track: track,
            mipLevel: preferredMipLevel,
            allowsSynchronousUpload: false
        )
        if let allocation = waveformShaderAllocation(track: track, mipLevel: preferredMipLevel) {
            return WaveformShaderDrawable(
                mipLevel: preferredMipLevel,
                buffer: allocation.buffer,
                binOffset: allocation.binOffset
            )
        }

        guard fallbackPolicy == .allowFallbacks else {
            return nil
        }

        if preferredIndex + 1 < mipLevels.count {
            for fallbackIndex in (preferredIndex + 1)..<mipLevels.count {
                let fallbackMipLevel = mipLevels[fallbackIndex]
                if let allocation = waveformShaderAllocation(track: track, mipLevel: fallbackMipLevel) {
                    return WaveformShaderDrawable(
                        mipLevel: fallbackMipLevel,
                        buffer: allocation.buffer,
                        binOffset: allocation.binOffset
                    )
                }
            }
        }

        if preferredIndex > 0 {
            for fallbackIndex in stride(from: preferredIndex - 1, through: 0, by: -1) {
                let fallbackMipLevel = mipLevels[fallbackIndex]
                if let allocation = waveformShaderAllocation(track: track, mipLevel: fallbackMipLevel) {
                    return WaveformShaderDrawable(
                        mipLevel: fallbackMipLevel,
                        buffer: allocation.buffer,
                        binOffset: allocation.binOffset
                    )
                }
            }
        }

        return nil
    }

    private func makeWaveformShaderBins(
        from bins: [WaveformOverview.Bin],
        shouldYieldForPlayback: Bool = false
    ) -> [WaveformShaderBin]? {
        guard !bins.isEmpty else {
            return nil
        }

        var shaderBins: [WaveformShaderBin] = []
        shaderBins.reserveCapacity(bins.count)
        for (index, bin) in bins.enumerated() {
            if shouldYieldForPlayback, index.isMultiple(of: 8_192) {
                try? ImportWorkBudget.shared.waitIfPlaybackActive()
            }
            shaderBins.append(WaveformShaderBin(
                minimumSample: bin.minimumSample,
                maximumSample: bin.maximumSample,
                rmsSample: bin.rmsSample,
                lowEnergy: bin.lowEnergy,
                midEnergy: bin.midEnergy,
                highEnergy: bin.highEnergy,
                peakMagnitude: bin.peakMagnitude,
                reserved: 0
            ))
        }

        return shaderBins
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

    private func waveformShaderAllocation(
        track: TimelineRenderState.Track,
        mipLevel: WaveformMipLevel
    ) -> WaveformShaderBufferAllocation? {
        waveformShaderBufferStore.allocation(for: waveformShaderBufferKey(track: track, mipLevel: mipLevel))
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
        if
            allowsSynchronousUpload,
            mipLevel.binCount <= maximumSynchronousWaveformShaderBinBufferBins
        {
            let shaderBins = makeWaveformShaderBins(from: bins)
            waveformShaderBufferStore.publish(shaderBins, for: key)
            waveformShaderBufferStore.trim(
                toMaximumCount: maximumCachedWaveformShaderBinBuffers,
                maximumByteCount: maximumCachedWaveformShaderBinBufferBytes
            )
            return
        }

        waveformGeometryQueue.async { [weak self] in
            let shaderBins = self?.makeWaveformShaderBins(
                from: bins,
                shouldYieldForPlayback: true
            )
            self?.waveformShaderBufferStore.publish(shaderBins, for: key)
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

    private func drawWaveformShaderBatch(
        uniforms: [WaveformShaderUniform],
        binBuffer: MTLBuffer,
        opacity: Float,
        encoder: MTLRenderCommandEncoder
    ) {
        guard !uniforms.isEmpty else {
            return
        }

        frameStatsGPUWaveformDrawCount += 1
        setWaveformFragmentOpacity(opacity, encoder: encoder)
        encoder.setVertexBuffer(waveformQuadVertexBuffer, offset: 0, index: 0)
        uniforms.withUnsafeBytes { buffer in
            if let stagedUniforms = dynamicVertexBufferRing.stage(buffer) {
                encoder.setVertexBuffer(stagedUniforms.buffer, offset: stagedUniforms.offset, index: 1)
            } else {
                guard
                    let baseAddress = buffer.baseAddress,
                    let uniformBuffer = device.makeBuffer(
                        bytes: baseAddress,
                        length: buffer.count,
                        options: [.storageModeShared, .cpuCacheModeWriteCombined]
                    )
                else {
                    return
                }

                encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            }

            encoder.setFragmentBuffer(binBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: uniforms.count
            )
        }
    }

    private func drawTimelineRulerTicks(
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState,
        encoder: MTLRenderCommandEncoder
    ) {
        guard var uniform = makeTimelineRulerUniform(
            drawableSize: drawableSize,
            backingScale: backingScale,
            renderState: renderState
        ) else {
            return
        }

        encoder.setRenderPipelineState(rulerPipelineState)
        encoder.setVertexBuffer(waveformQuadVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniform,
            length: MemoryLayout<TimelineRulerUniform>.stride,
            index: 1
        )
        encoder.setFragmentBytes(
            &uniform,
            length: MemoryLayout<TimelineRulerUniform>.stride,
            index: 1
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func makeTimelineRulerUniform(
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState
    ) -> TimelineRulerUniform? {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard
            width > 0,
            height > 0,
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0
        else {
            return nil
        }

        let scale = max(backingScale, 1)
        let visibleSeconds = max(Double(renderState.viewport.durationProgress) * projectDuration, 0.000001)
        let targetMinorSpacingPoints: Float = 52
        let approximateMinorStep = visibleSeconds * Double(targetMinorSpacingPoints / max(width, 1))
        let minorStepSeconds = max(Float(niceSecondsStep(approximateMinorStep)), 0.000001)
        let rulerHeightPixels = min(
            max(18 * scale, height * scale * 0.032),
            28 * scale
        )

        return TimelineRulerUniform(
            viewport: SIMD4<Float>(
                renderState.viewport.startProgress,
                renderState.viewport.durationProgress,
                Float(projectDuration),
                minorStepSeconds
            ),
            metrics: SIMD4<Float>(
                width,
                height,
                scale,
                rulerHeightPixels
            ),
            style: SIMD4<Float>(
                5,
                10,
                0.72,
                rulerHeightPixels * 0.34
            ),
            color: SIMD4<Float>(0.78, 0.88, 0.90, 0.72)
        )
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
            waveformMipCacheCount: waveformMipCacheDiagnostics().cacheCount,
            effectVertexCount: frameStatsEffectVertexCount,
            effectDroppedVertexCount: frameStatsEffectDroppedVertexCount,
            transientParticleCount: frameStatsTransientParticleCount,
            deletionEffectCount: frameStatsDeletionEffectCount,
            playheadContactEventCount: frameStatsPlayheadContactEventCount
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
        frameStatsEffectVertexCount = 0
        frameStatsEffectDroppedVertexCount = 0
        frameStatsTransientParticleCount = transientParticles.count
        deletionEffectLock.lock()
        frameStatsDeletionEffectCount = deletionEffects.count
        deletionEffectLock.unlock()
        frameStatsPlayheadContactEventCount = playheadContactEvents.count
    }

    private func resetFrameRateWindow(startingAt currentTime: CFTimeInterval) {
        frameRateWindowStartTime = currentTime
        frameRateFrameCount = 0
        frameIntervalCount = 0
        frameIntervalSum = 0
        frameIntervalSquareSum = 0
        worstFrameInterval = 0
    }

    private func resolvedTrackLayout(
        renderState: TimelineRenderState,
        drawableSize: CGSize
    ) -> ResolvedTimelineTrackLayout {
        renderState.trackLayout.resolved(
            totalTrackCount: renderState.tracks.count,
            viewportHeight: Float(max(drawableSize.height, 1))
        )
    }

    private func laneFrame(
        forTrackIndex trackIndex: Int,
        renderState: TimelineRenderState,
        drawableSize: CGSize
    ) -> TimelineTrackLaneFrame? {
        let layout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        guard let laneFrame = layout.laneFrame(forTrackIndex: trackIndex), laneFrame.isVisible else {
            return nil
        }
        return laneFrame
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

        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        let key = GridCacheKey(
            width: width,
            height: height,
            backingScale: backingScale,
            viewportStart: renderState.viewport.startProgress,
            viewportDuration: renderState.viewport.durationProgress,
            trackCount: max(renderState.tracks.count, 1),
            trackHeight: trackLayout.trackHeight,
            trackScrollOffset: trackLayout.scrollOffset
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

        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        for trackIndex in trackLayout.visibleRange(overscan: 0) {
            guard let laneFrame = trackLayout.laneFrame(forTrackIndex: trackIndex), laneFrame.isVisible else {
                continue
            }

            let laneTop = laneFrame.top * height
            let laneBottom = laneFrame.bottom * height
            if trackIndex > 0 {
                let separatorY = pixelAligned(laneTop, backingScale: backingScale)
                if separatorY >= 0, separatorY <= height {
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
            }

            let centerY = pixelAligned((laneTop + laneBottom) * 0.5, backingScale: backingScale)
            guard centerY >= 0, centerY <= height else {
                continue
            }
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

            guard let laneFrame = laneFrame(
                forTrackIndex: trackIndex,
                renderState: renderState,
                drawableSize: drawableSize
            ) else {
                continue
            }
            let laneTop = laneFrame.top
            let laneBottom = laneFrame.bottom
            let centerY = laneFrame.center
            let amplitudeHeight = laneFrame.height * 0.39 * min(max(track.volume, 0), 1.8)
            let originEdgePadding = min(max(laneFrame.height * 0.120, 0.022), 0.075)
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
        displayTimestamp: CFTimeInterval,
        maximumVertexCount: Int
    ) -> [TimelineVertex] {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0, maximumVertexCount >= 3 else {
            return []
        }

        transientParticles.removeAll { particle in
            displayTimestamp - particle.birthTimestamp >= particle.lifeDuration
        }
        frameStatsTransientParticleCount = transientParticles.count
        guard !transientParticles.isEmpty else {
            return []
        }

        let drawableSize = SIMD2<Float>(width, height)
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(min(maximumVertexCount, transientParticles.count * 36))

        for particle in transientParticles {
            guard vertices.count + 36 <= maximumVertexCount else {
                frameStatsEffectDroppedVertexCount += 36
                continue
            }

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

    private func activeDeletionEffects(at displayTimestamp: CFTimeInterval) -> [DeletionEffect] {
        deletionEffectLock.lock()
        for index in deletionEffects.indices {
            if deletionEffects[index].birthTimestamp < 0 {
                deletionEffects[index].birthTimestamp = displayTimestamp
            }
        }
        deletionEffects.removeAll { effect in
            effect.birthTimestamp >= 0 &&
                displayTimestamp - effect.birthTimestamp >= deletionEffectDuration
        }
        let effects = deletionEffects
        deletionEffectLock.unlock()
        frameStatsDeletionEffectCount = effects.count
        return effects
    }

    private func drawDeletionEffects(
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        baseFisheye: SIMD4<Float>,
        displayTimestamp: CFTimeInterval,
        encoder: MTLRenderCommandEncoder
    ) {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            frameStatsDeletionEffectCount = 0
            return
        }

        let effects = activeDeletionEffects(at: displayTimestamp)
        guard !effects.isEmpty else {
            return
        }

        encoder.setRenderPipelineState(deletionEffectPipelineState)
        encoder.setVertexBuffer(waveformQuadVertexBuffer, offset: 0, index: 0)
        for effect in effects {
            guard
                let binBuffer = effect.capturedBinBuffer,
                effect.capturedBinCount + effect.trailingBinCount > 0,
                var uniform = deletionEffectUniform(
                    for: effect,
                    drawableSize: drawableSize,
                    renderState: renderState,
                    baseFisheye: baseFisheye,
                    displayTimestamp: displayTimestamp
                )
            else {
                continue
            }

            encoder.setVertexBytes(
                &uniform,
                length: MemoryLayout<DeletionEffectUniform>.stride,
                index: 1
            )
            encoder.setFragmentBuffer(binBuffer, offset: 0, index: 1)
            encoder.setFragmentBytes(
                &uniform,
                length: MemoryLayout<DeletionEffectUniform>.stride,
                index: 2
            )
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        encoder.setRenderPipelineState(deletionParticlePipelineState)
        encoder.setVertexBuffer(waveformQuadVertexBuffer, offset: 0, index: 0)
        for effect in effects {
            guard var uniform = deletionEffectUniform(
                for: effect,
                drawableSize: drawableSize,
                renderState: renderState,
                baseFisheye: baseFisheye,
                displayTimestamp: displayTimestamp
            ) else {
                continue
            }

            encoder.setVertexBytes(
                &uniform,
                length: MemoryLayout<DeletionEffectUniform>.stride,
                index: 1
            )
            encoder.setFragmentBytes(
                &uniform,
                length: MemoryLayout<DeletionEffectUniform>.stride,
                index: 1
            )
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: deletionShardCount
            )
        }
    }

    private func deletionEffectUniform(
        for effect: DeletionEffect,
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        baseFisheye: SIMD4<Float>,
        displayTimestamp: CFTimeInterval
    ) -> DeletionEffectUniform? {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return nil
        }

        let birthTimestamp = effect.birthTimestamp >= 0 ? effect.birthTimestamp : displayTimestamp
        let age = max(displayTimestamp - birthTimestamp, 0)
        let progress = min(max(Float(age / deletionEffectDuration), 0), 1)
        let selection = effect.selection
        let leftViewport = effect.visualAnchor.x
        let rightViewport = effect.visualAnchor.y
        let trailingEndViewport = effect.visualAnchor.z
        guard rightViewport > -0.1, leftViewport < 1.1 else {
            return nil
        }

        var leftX = leftViewport * width
        var rightX = rightViewport * width
        var trailingEndX = trailingEndViewport * width
        if rightX < leftX {
            swap(&leftX, &rightX)
        }
        trailingEndX = max(trailingEndX, rightX)
        let minimumEffectWidth: Float = 18
        if rightX - leftX < minimumEffectWidth {
            let centerX = (leftX + rightX) * 0.5
            leftX = centerX - minimumEffectWidth * 0.5
            rightX = centerX + minimumEffectWidth * 0.5
            trailingEndX = max(trailingEndX, rightX)
        }

        guard let verticalRange = selectionVerticalRange(
            for: selection,
            renderState: renderState,
            drawableSize: drawableSize
        ) else {
            return nil
        }

        let topY = verticalRange.top * height
        let bottomY = verticalRange.bottom * height
        guard bottomY > topY else {
            return nil
        }

        let selectionWidth = max(rightX - leftX, 1)
        let pullDistance = max(selectionWidth, 22)
        let slideTime = min(max(progress / 0.22, 0), 1)
        let easedSlideTime = smoothStep(slideTime)
        let slideProgress = 1 - pow(1 - easedSlideTime, 2.45)
        let overlayRightX = max(
            rightX + 20 + min(pullDistance * 0.32, 90),
            trailingEndX + 6
        )
        let overlayLeftX = leftX - 4
        let seed = Float(UInt32(truncatingIfNeeded: effect.seed & 0x00FF_FFFF))
        return DeletionEffectUniform(
            rect: SIMD4<Float>(
                leftX / width,
                rightX / width,
                topY / height,
                bottomY / height
            ),
            overlayRect: SIMD4<Float>(
                overlayLeftX / width,
                overlayRightX / width,
                topY / height,
                bottomY / height
            ),
            timing: SIMD4<Float>(
                progress,
                1 - pow(1 - progress, 2.2),
                seed,
                Float(max(effect.capturedBinCount, 1))
            ),
            metrics: SIMD4<Float>(
                width,
                height,
                max(bottomY - topY, 1),
                Float(deletionEffectDuration)
            ),
            ripple: SIMD4<Float>(
                trailingEndX / width,
                slideProgress,
                Float(effect.trailingBinCount),
                selectionWidth / width
            )
        )
    }

    private func makeSelectionVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState
    ) -> [TimelineVertex] {
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
        guard let verticalRange = selectionVerticalRange(
            for: selection,
            renderState: renderState,
            drawableSize: drawableSize
        ) else {
            return []
        }
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

    private func makeSelectedTrackVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState
    ) -> [TimelineVertex] {
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

        guard let laneFrame = laneFrame(
            forTrackIndex: trackIndex,
            renderState: renderState,
            drawableSize: drawableSize
        ) else {
            return []
        }
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(6)
        appendRectangle(
            to: &vertices,
            left: 0,
            right: 1,
            top: max(laneFrame.top, 0),
            bottom: min(laneFrame.bottom, 1),
            color: SIMD4<Float>(0.78, 0.78, 0.78, 0.075)
        )
        return vertices
    }

    private func selectionVerticalRange(
        for selection: TimelineSelection,
        renderState: TimelineRenderState,
        drawableSize: CGSize
    ) -> (top: Float, bottom: Float)? {
        guard
            let trackID = selection.trackID,
            let trackIndex = renderState.tracks.firstIndex(where: { $0.id == trackID }),
            !renderState.tracks.isEmpty
        else {
            return (0, 1)
        }

        guard let laneFrame = laneFrame(
            forTrackIndex: trackIndex,
            renderState: renderState,
            drawableSize: drawableSize
        ) else {
            return nil
        }
        return (max(laneFrame.top, 0), min(laneFrame.bottom, 1))
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

        let anySolo = tracks.contains { $0.isSoloed }
        let style = waveformVisualStyle(renderState: renderState, projectDuration: projectDuration)
        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        var vertices: [TimelineVertex] = []

        for trackIndex in trackLayout.visibleRange(overscan: 1) {
            guard tracks.indices.contains(trackIndex) else {
                continue
            }

            let track = tracks[trackIndex]
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

            guard let laneFrame = trackLayout.laneFrame(forTrackIndex: trackIndex), laneFrame.isVisible else {
                continue
            }

            let laneTop = laneFrame.top
            let laneBottom = laneFrame.bottom
            let centerY = laneFrame.center
            let amplitudeHeight = laneFrame.height * 0.39 * min(max(track.volume, 0), 1.8)
            let minimumVisualHeight = laneFrame.height * 0.006
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
        let tracks = renderState.tracks
        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        var hasher = Hasher()
        for trackIndex in trackLayout.visibleRange(overscan: 1) {
            guard tracks.indices.contains(trackIndex) else {
                continue
            }

            let track = tracks[trackIndex]
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
        guard waveformFisheyeEnabled else {
            trackFisheyeAudibilitySignature = nil
            trackFisheyeStates.removeAll()
            return
        }

        let anySolo = tracks.contains { $0.isSoloed }
        trackFisheyeAudibilitySignature = trackAudibilitySignature(
            for: tracks,
            anySolo: anySolo
        )
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
        guard waveformFisheyeEnabled else {
            if trackFisheyeAudibilitySignature != nil || !trackFisheyeStates.isEmpty {
                trackFisheyeAudibilitySignature = nil
                trackFisheyeStates.removeAll()
            }
            return
        }

        let anySolo = tracks.contains { $0.isSoloed }
        let nextSignature = trackAudibilitySignature(for: tracks, anySolo: anySolo)
        guard nextSignature != trackFisheyeAudibilitySignature else {
            return
        }

        trackFisheyeAudibilitySignature = nextSignature
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

    private func trackAudibilitySignature(
        for tracks: [TimelineRenderState.Track],
        anySolo: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(anySolo)
        for track in tracks {
            hasher.combine(track.id)
            hasher.combine(isTrackAudible(track, anySolo: anySolo))
        }
        return hasher.finalize()
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
        guard waveformFisheyeEnabled else {
            return .zero
        }

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

        let extendedZoomRatio = max(visibleDuration / max(waveformFisheyeMaximumVisibleDuration, 0.001), 1)
        let extendedZoomAmount = smoothStep(min(max(Float(log2(extendedZoomRatio) / 2.1), 0), 1))
        let radiusBoost = 1 + extendedZoomAmount * amount * 0.72
        let exponentBoost = extendedZoomAmount * amount * 0.20
        let radius = min(waveformFisheyeMaximumRadius * amount * radiusBoost, 0.18)
        let targetExponent = max(waveformFisheyeMinimumExponent - exponentBoost, 0.24)
        let exponent = 1 + (targetExponent - 1) * amount
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

    private func selectionFisheye(
        for selection: TimelineSelection?,
        renderState: TimelineRenderState,
        baseFisheye: SIMD4<Float>,
        displayTimestamp: CFTimeInterval
    ) -> SIMD4<Float> {
        guard baseFisheye.w > 0.000_1 else {
            return .zero
        }

        guard let trackID = selection?.trackID else {
            return cpuFallbackWaveformFisheye(
                baseFisheye,
                renderState: renderState,
                displayTimestamp: displayTimestamp
            )
        }

        return scaledWaveformFisheye(
            baseFisheye,
            by: trackFisheyeEnergy(for: trackID, at: displayTimestamp)
        )
    }

    private func fisheyeX(_ x: Float, fisheye: SIMD4<Float>) -> Float {
        let radius = fisheye.y
        let exponent = fisheye.z
        guard radius > 0, exponent > 0, exponent < 0.999 else {
            return x
        }

        let center = fisheye.x
        let dx = x - center
        let distance = abs(dx)
        let sideRadius = fisheyeSideRadius(dx: dx, radius: radius)
        guard distance > 0.000_001, distance < sideRadius else {
            return x
        }

        let t = min(max(distance / sideRadius, 0), 1)
        let warpedDistance = sideRadius * fisheyeWarpedNormalizedDistance(t, exponent: exponent)
        return min(max(center + (dx < 0 ? -warpedDistance : warpedDistance), 0), 1)
    }

    private func inverseFisheyeX(_ x: Float, fisheye: SIMD4<Float>) -> Float {
        let radius = fisheye.y
        let exponent = fisheye.z
        guard radius > 0, exponent > 0, exponent < 0.999 else {
            return min(max(x, 0), 1)
        }

        let center = fisheye.x
        let dx = x - center
        let distance = abs(dx)
        let sideRadius = fisheyeSideRadius(dx: dx, radius: radius)
        guard distance > 0.000_001, distance < sideRadius else {
            return min(max(x, 0), 1)
        }

        let target = min(max(distance / sideRadius, 0), 1)
        var lowerBound: Float = 0
        var upperBound: Float = 1
        for _ in 0..<10 {
            let midpoint = (lowerBound + upperBound) * 0.5
            let warpedMidpoint = fisheyeWarpedNormalizedDistance(midpoint, exponent: exponent)
            if warpedMidpoint < target {
                lowerBound = midpoint
            } else {
                upperBound = midpoint
            }
        }

        let t = (lowerBound + upperBound) * 0.5
        let unwarpedDistance = sideRadius * t
        return min(max(center + (dx < 0 ? -unwarpedDistance : unwarpedDistance), 0), 1)
    }

    private func fisheyeSideRadius(dx: Float, radius: Float) -> Float {
        let totalRadius = max(radius * 2, 0)
        return dx < 0 ? totalRadius * 0.10 : totalRadius * 0.90
    }

    private func fisheyeWarpedNormalizedDistance(_ normalizedDistance: Float, exponent: Float) -> Float {
        let t = min(max(normalizedDistance, 0), 1)
        let strength = min(max(1 - exponent, 0), 1)
        let centerDisplacement = t *
            exp(-pow(t / 0.32, 4)) *
            pow(max(1 - t, 0), 3)
        return min(max(t + strength * 3 * centerDisplacement, 0), 1)
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

    private func emptyWaveformTouchShaderParameters() -> (
        touch: SIMD4<Float>,
        touch2: SIMD4<Float>,
        touch3: SIMD4<Float>
    ) {
        (
            touch: SIMD4<Float>(0, 0, 0, 0),
            touch2: SIMD4<Float>(0, 0, 0, playheadTouchTrailFalloffSteepness),
            touch3: SIMD4<Float>(0, 0, 0, 0)
        )
    }

    private func makeWaveformTouchShaderParameters(
        renderState: TimelineRenderState,
        playheadProgress: Float,
        displayTimestamp: CFTimeInterval
    ) -> (touch: SIMD4<Float>, touch2: SIMD4<Float>, touch3: SIMD4<Float>) {
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
        let lightTrailRadius = playheadTouchLightTrailRadiusProgress(
            forDuration: projectDuration,
            viewport: viewport
        )
        let touchRenderRadius = max(trailRenderRadius, lightTrailRadius)
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
            let pauseFadeEnergy = playheadTouchPauseFadeEnergy(elapsedTime: elapsedTime)
            guard pauseFadeEnergy > 0.001 else {
                playheadTouchEnergy = 0
                playheadTouchPauseProgress = nil
                playheadTouchPauseTimestamp = nil
                playheadTouchPlayStartProgress = nil
                return emptyWaveformTouchShaderParameters()
            }

            touchEnergy = pauseFadeEnergy
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
            touchHeadProgress - touchRenderRadius,
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
            ),
            touch3: SIMD4<Float>(
                lightTrailRadius,
                0,
                0,
                0
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
        guard !tracks.isEmpty else {
            return []
        }

        let clampedPlayhead = min(max(playheadProgress, 0), 1)
        let geometryAheadRadius = playheadTouchGeometryAheadRadiusProgress(forDuration: projectDuration)
        let lightAheadRadius = playheadTouchLightAheadRadiusProgress(forDuration: projectDuration)
        let trailDecayRadius = playheadTouchTrailRadiusProgress(forDuration: projectDuration)
        let trailRenderRadius = playheadTouchTrailRenderRadiusProgress(forDuration: projectDuration)
        let viewport = renderState.viewport
        let lightTrailRadius = playheadTouchLightTrailRadiusProgress(
            forDuration: projectDuration,
            viewport: viewport
        )
        let touchRenderRadius = max(trailRenderRadius, lightTrailRadius)
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
            let pauseFadeEnergy = playheadTouchPauseFadeEnergy(elapsedTime: elapsedTime)
            guard pauseFadeEnergy > 0.001 else {
                playheadTouchEnergy = 0
                playheadTouchPauseProgress = nil
                playheadTouchPauseTimestamp = nil
                playheadTouchPlayStartProgress = nil
                return []
            }

            touchEnergy = pauseFadeEnergy
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
            touchHeadProgress - touchRenderRadius,
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

            guard let laneFrame = laneFrame(
                forTrackIndex: trackIndex,
                renderState: renderState,
                drawableSize: drawableSize
            ) else {
                continue
            }
            let laneTop = laneFrame.top
            let laneBottom = laneFrame.bottom
            let centerY = laneFrame.center
            let amplitudeHeight = laneFrame.height * 0.39 * min(max(track.volume, 0), 1.8)
            let minimumVisualHeight = laneFrame.height * 0.004
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
                    trailRadius: lightTrailRadius
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
                    let visualHeight = minimumVisualHeight + laneFrame.height * 0.014 * geometryInfluence
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

    private func playheadTouchLightTrailRadiusProgress(
        forDuration duration: TimeInterval,
        viewport: TimelineViewport
    ) -> Float {
        let baseRadius = playheadTouchTrailRadiusProgress(forDuration: duration)
        guard duration.isFinite, duration > 0, viewport.durationProgress > 0 else {
            return baseRadius
        }

        let visibleDuration = duration * Double(viewport.durationProgress)
        let zoomRange = max(
            playheadTouchZoomedOutLightFullVisibleDuration -
                playheadTouchZoomedOutLightMinimumVisibleDuration,
            0.001
        )
        let zoomAmount = min(
            max(
                (visibleDuration - playheadTouchZoomedOutLightMinimumVisibleDuration) / zoomRange,
                0
            ),
            1
        )
        let easedZoomAmount = smoothStep(Float(zoomAmount))
        let zoomRadius = viewport.durationProgress *
            playheadTouchZoomedOutLightMaximumViewportFraction *
            easedZoomAmount
        return min(max(max(baseRadius, zoomRadius), .ulpOfOne), 1)
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

    private func playheadTouchPauseFadeEnergy(elapsedTime: CFTimeInterval) -> Float {
        let progress = min(max(Float(elapsedTime / playheadTouchPauseFadeDuration), 0), 1)
        let remaining = 1 - progress
        return powf(remaining, 1.35)
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
            drawableSize: size,
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
        drawableSize: SIMD2<Float>,
        playheadProgress: Float,
        renderState: TimelineRenderState,
        mipLevelSnapshot: WaveformMipLevelSnapshot,
        displayTimestamp: CFTimeInterval
    ) {
        defer {
            frameStatsPlayheadContactEventCount = playheadContactEvents.count
        }

        playheadContactEvents.removeAll { event in
            displayTimestamp - event.timestamp >= playheadContactFadeDuration
        }
        let contactBudget = playheadContactEventBudget(
            trackCount: renderState.tracks.count,
            drawableHeight: drawableSize.y
        )
        trimPlayheadContactEvents(to: contactBudget)

        guard contactBudget > 0 else {
            return
        }

        guard
            renderState.isPlaybackActive,
            let contacts = playheadWaveformContacts(
                at: playheadProgress,
                drawableSize: drawableSize,
                renderState: renderState,
                mipLevelSnapshot: mipLevelSnapshot
            )
        else {
            return
        }

        if let lastPlayheadContactEventTimestamp,
           displayTimestamp - lastPlayheadContactEventTimestamp < playheadContactMinimumSpawnInterval
        {
            return
        }
        lastPlayheadContactEventTimestamp = displayTimestamp

        playheadContactEvents.append(contentsOf: contacts.map { contact in
            PlayheadContactEvent(
                centerY: contact.centerY,
                laneTop: contact.laneTop,
                laneBottom: contact.laneBottom,
                strength: contact.strength,
                timestamp: displayTimestamp
            )
        })

        trimPlayheadContactEvents(to: contactBudget)
    }

    private func playheadContactEventBudget(trackCount: Int, drawableHeight: Float) -> Int {
        let trackCount = max(trackCount, 1)
        let lanePixelHeight = drawableHeight / Float(trackCount)
        guard lanePixelHeight >= 14 else {
            return 0
        }

        let perTrackBudget: Int
        if lanePixelHeight < 24 {
            perTrackBudget = 3
        } else if lanePixelHeight < 42 {
            perTrackBudget = 5
        } else {
            perTrackBudget = playheadContactEventsPerTrackBudget
        }

        return min(
            playheadContactMaximumEventCount,
            max(48, trackCount * perTrackBudget)
        )
    }

    private func trimPlayheadContactEvents(to budget: Int) {
        guard playheadContactEvents.count > budget else {
            return
        }

        playheadContactEvents.removeFirst(playheadContactEvents.count - budget)
    }

    private func playheadWaveformContacts(
        at playheadProgress: Float,
        drawableSize: SIMD2<Float>,
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
        let anySolo = tracks.contains { $0.isSoloed }
        var contacts: [(centerY: Float, laneTop: Float, laneBottom: Float, strength: Float)] = []
        contacts.reserveCapacity(min(trackCount, 16) * 2)

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
            guard let laneFrame = laneFrame(
                forTrackIndex: trackIndex,
                renderState: renderState,
                drawableSize: CGSize(width: CGFloat(drawableSize.x), height: CGFloat(drawableSize.y))
            ) else {
                continue
            }
            let laneTop = laneFrame.top
            let laneBottom = laneFrame.bottom
            let centerY = laneFrame.center
            let amplitudeHeight = laneFrame.height * 0.39 * min(max(track.volume, 0), 1.8)
            let topY = min(max(centerY - maximumSample * amplitudeHeight, laneTop), laneBottom)
            let bottomY = min(max(centerY - minimumSample * amplitudeHeight, laneTop), laneBottom)
            let amplitude = max(abs(minimumSample), abs(maximumSample))
            let strength = min(max(0.38 + amplitude * 0.62, 0), 1)

            if abs(bottomY - topY) < laneFrame.height * 0.012 {
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

    private func appendShardTriangle(
        to vertices: inout [TimelineVertex],
        center: SIMD2<Float>,
        radius: Float,
        rotation: Float,
        color: SIMD4<Float>,
        drawableSize: SIMD2<Float>
    ) {
        guard
            drawableSize.x > 0,
            drawableSize.y > 0,
            radius > 0,
            color.w > 0
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

        let angles = [
            rotation,
            rotation + Float.pi * 0.73,
            rotation + Float.pi * 1.48,
        ]
        for angle in angles {
            let point = SIMD2<Float>(
                center.x + cos(angle) * radius,
                center.y + sin(angle) * radius * 0.62
            )
            vertices.append(makeVertex(
                normalizedPosition: SIMD2<Float>(
                    point.x / drawableSize.x,
                    point.y / drawableSize.y
                ),
                color: color
            ))
        }
    }

    private func appendThickLine(
        to vertices: inout [TimelineVertex],
        start: SIMD2<Float>,
        end: SIMD2<Float>,
        width: Float,
        color: SIMD4<Float>,
        drawableSize: SIMD2<Float>
    ) {
        guard
            drawableSize.x > 0,
            drawableSize.y > 0,
            width > 0,
            color.w > 0
        else {
            return
        }

        let delta = end - start
        let length = simd_length(delta)
        guard length > 0.001 else {
            appendSoftParticle(
                to: &vertices,
                center: start,
                radius: width * 1.8,
                color: SIMD3<Float>(color.x, color.y, color.z),
                alpha: color.w,
                drawableSize: drawableSize
            )
            return
        }

        let perpendicular = SIMD2<Float>(-delta.y, delta.x) / length * width * 0.5
        let startA = start + perpendicular
        let startB = start - perpendicular
        let endA = end + perpendicular
        let endB = end - perpendicular

        vertices.append(makeVertex(
            normalizedPosition: SIMD2<Float>(startA.x / drawableSize.x, startA.y / drawableSize.y),
            color: color
        ))
        vertices.append(makeVertex(
            normalizedPosition: SIMD2<Float>(endA.x / drawableSize.x, endA.y / drawableSize.y),
            color: color
        ))
        vertices.append(makeVertex(
            normalizedPosition: SIMD2<Float>(startB.x / drawableSize.x, startB.y / drawableSize.y),
            color: color
        ))
        vertices.append(makeVertex(
            normalizedPosition: SIMD2<Float>(endA.x / drawableSize.x, endA.y / drawableSize.y),
            color: color
        ))
        vertices.append(makeVertex(
            normalizedPosition: SIMD2<Float>(endB.x / drawableSize.x, endB.y / drawableSize.y),
            color: color
        ))
        vertices.append(makeVertex(
            normalizedPosition: SIMD2<Float>(startB.x / drawableSize.x, startB.y / drawableSize.y),
            color: color
        ))
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

    private func niceSecondsStep(_ secondsStep: Double) -> Double {
        guard secondsStep > 0, secondsStep.isFinite else {
            return 1
        }

        let exponent = floor(log10(secondsStep))
        let base = pow(10, exponent)
        let normalizedStep = secondsStep / base

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
        float4 touch3;
    };

    struct DeletionEffectUniform {
        float4 rect;
        float4 overlayRect;
        float4 timing;
        float4 metrics;
        float4 ripple;
    };

    struct TimelineRulerUniform {
        float4 viewport;
        float4 metrics;
        float4 style;
        float4 color;
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

    struct TimelineRulerRasterizedVertex {
        float4 position [[position]];
        float2 normalizedPosition;
        float4 viewport;
        float4 metrics;
        float4 style;
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
        float4 touch3;
    };

    struct DeletionEffectRasterizedVertex {
        float4 position [[position]];
        float2 normalizedPosition;
        float2 localPosition;
        float4 rect;
        float4 overlayRect;
        float4 timing;
        float4 metrics;
    };

    struct DeletionParticleRasterizedVertex {
        float4 position [[position]];
        float2 localPosition;
        float4 color;
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

    float fisheye_side_radius(float dx, float radius) {
        float totalRadius = max(radius * 2.0, 0.0);
        return dx < 0.0 ? totalRadius * 0.10 : totalRadius * 0.90;
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
        float sideRadius = fisheye_side_radius(dx, radius);
        if (distance <= 0.000001 || distance >= sideRadius) {
            return x;
        }

        float t = clamp(distance / sideRadius, 0.0, 1.0);
        float warpedDistance = sideRadius * fisheye_warped_normalized_distance(t, exponent);
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
        float sideRadius = fisheye_side_radius(dx, radius);
        if (distance <= 0.000001 || distance >= sideRadius) {
            return x;
        }

        float target = clamp(distance / sideRadius, 0.0, 1.0);
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
        float unwarpedDistance = sideRadius * t;
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

    vertex TimelineRulerRasterizedVertex timeline_ruler_vertex(
        uint vertexID [[vertex_id]],
        constant WaveformShaderQuadVertex *vertices [[buffer(0)]],
        constant TimelineRulerUniform &uniform [[buffer(1)]]
    ) {
        float2 normalizedPosition = vertices[vertexID].position.xy;

        TimelineRulerRasterizedVertex out;
        out.position = float4(
            normalizedPosition.x * 2.0 - 1.0,
            1.0 - normalizedPosition.y * 2.0,
            0.0,
            1.0
        );
        out.normalizedPosition = normalizedPosition;
        out.viewport = uniform.viewport;
        out.metrics = uniform.metrics;
        out.style = uniform.style;
        out.color = uniform.color;
        return out;
    }

    vertex WaveformRasterizedVertex waveform_vertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant WaveformShaderQuadVertex *vertices [[buffer(0)]],
        constant WaveformShaderUniform *uniforms [[buffer(1)]]
    ) {
        WaveformShaderUniform uniform = uniforms[instanceID];
        float2 normalizedPosition = vertices[vertexID].position.xy;
        normalizedPosition.y = mix(uniform.lane.x, uniform.lane.y, normalizedPosition.y);

        WaveformRasterizedVertex out;
        out.position = float4(
            normalizedPosition.x * 2.0 - 1.0,
            1.0 - normalizedPosition.y * 2.0,
            0.0,
            1.0
        );
        out.normalizedPosition = normalizedPosition;
        out.baseColor = uniform.baseColor;
        out.lane = uniform.lane;
        out.track = uniform.track;
        out.viewport = uniform.viewport;
        out.style = uniform.style;
        out.style2 = uniform.style2;
        out.gainPreview = uniform.gainPreview;
        out.fisheye = uniform.fisheye;
        out.touch = uniform.touch;
        out.touch2 = uniform.touch2;
        out.touch3 = uniform.touch3;
        return out;
    }

    fragment float4 timeline_fragment(
        RasterizedVertex in [[stage_in]],
        constant float &opacity [[buffer(1)]]
    ) {
        return float4(in.color.rgb, in.color.a * opacity);
    }

    fragment float4 timeline_ruler_fragment(
        TimelineRulerRasterizedVertex in [[stage_in]]
    ) {
        float height = max(in.metrics.y, 1.0);
        float scale = max(in.metrics.z, 1.0);
        float rulerHeightPixels = max(in.metrics.w, 1.0);
        float yPixels = in.normalizedPosition.y * height * scale;
        if (yPixels > rulerHeightPixels + 1.0) {
            return float4(0.0);
        }

        float projectDuration = max(in.viewport.z, 0.000001);
        float minorStepSeconds = max(in.viewport.w, 0.000001);
        float timelineProgress = in.viewport.x + in.normalizedPosition.x * in.viewport.y;
        float timelineSeconds = timelineProgress * projectDuration;
        if (timelineSeconds < -minorStepSeconds ||
            timelineSeconds > projectDuration + minorStepSeconds) {
            return float4(0.0);
        }

        float scaledTick = timelineSeconds / minorStepSeconds;
        float nearestTickIndex = floor(scaledTick + 0.5);
        float tickDistance = abs(scaledTick - nearestTickIndex);
        float tickDerivative = max(fwidth(scaledTick), 0.000001);
        float distancePixels = tickDistance / tickDerivative;
        float lineHalfWidthPixels = max(in.style.z, 0.25);
        float xCoverage = 1.0 - smoothstep(
            lineHalfWidthPixels,
            lineHalfWidthPixels + 1.0,
            distancePixels
        );
        if (xCoverage <= 0.0) {
            return float4(0.0);
        }

        float mediumEvery = max(in.style.x, 1.0);
        float majorEvery = max(in.style.y, 1.0);
        float majorModulo = fmod(abs(nearestTickIndex), majorEvery);
        float mediumModulo = fmod(abs(nearestTickIndex), mediumEvery);
        float majorDistance = min(majorModulo, majorEvery - majorModulo);
        float mediumDistance = min(mediumModulo, mediumEvery - mediumModulo);
        bool isMajor = majorDistance < 0.01;
        bool isMedium = mediumDistance < 0.01;

        float minorHeightPixels = max(in.style.w, 1.0);
        float mediumHeightPixels = rulerHeightPixels * 0.42;
        float majorHeightPixels = rulerHeightPixels * 0.50;
        float tickHeightPixels = isMajor ? majorHeightPixels : (isMedium ? mediumHeightPixels : minorHeightPixels);
        float yCoverage = 1.0 - smoothstep(tickHeightPixels, tickHeightPixels + 1.0, yPixels);
        if (yCoverage <= 0.0) {
            return float4(0.0);
        }

        float tickAlpha = isMajor ? 1.0 : (isMedium ? 0.68 : 0.38);
        float edgeFade = 1.0 - smoothstep(rulerHeightPixels * 0.72, rulerHeightPixels, yPixels);
        float alpha = in.color.a * xCoverage * yCoverage * tickAlpha * max(edgeFade, 0.15);
        return float4(in.color.rgb, alpha);
    }

    static WaveformShaderBin sample_waveform_bin(
        float localProgress,
        constant WaveformShaderBin *bins,
        uint binCount,
        uint binOffset,
        float smoothAmount
    ) {
        uint count = max(binCount, 1u);
        float clampedProgress = clamp(localProgress, 0.0, 0.999999);
        uint nearestIndex = min(uint(floor(clampedProgress * float(count))), count - 1u);
        WaveformShaderBin nearestBin = bins[binOffset + nearestIndex];
        if (smoothAmount <= 0.001 || count <= 1u) {
            return nearestBin;
        }

        float scaledIndex = clamp(clampedProgress * float(count) - 0.5, 0.0, float(count - 1u));
        uint leftIndex = uint(floor(scaledIndex));
        uint rightIndex = min(leftIndex + 1u, count - 1u);
        float amount = fract(scaledIndex);
        WaveformShaderBin leftBin = bins[binOffset + leftIndex];
        WaveformShaderBin rightBin = bins[binOffset + rightIndex];
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

        float dx = x - fisheye.x;
        float sideRadius = fisheye_side_radius(dx, radius);
        float distance = abs(dx);
        float normalizedDistance = clamp(distance / max(sideRadius, 0.000001), 0.0, 1.0);
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

    static float hash11(float value) {
        return fract(sin(value * 12.9898) * 43758.5453123);
    }

    static float hash21(float2 value) {
        return fract(sin(dot(value, float2(127.1, 311.7))) * 43758.5453123);
    }

    static float deletion_line_coverage(float2 point, float2 start, float2 end, float halfWidth, float aa) {
        float2 segment = end - start;
        float lengthSquared = max(dot(segment, segment), 0.000001);
        float t = clamp(dot(point - start, segment) / lengthSquared, 0.0, 1.0);
        float distance = length(point - (start + segment * t));
        return 1.0 - smoothstep(halfWidth, halfWidth + aa, distance);
    }

    vertex DeletionEffectRasterizedVertex deletion_effect_vertex(
        uint vertexID [[vertex_id]],
        constant WaveformShaderQuadVertex *vertices [[buffer(0)]],
        constant DeletionEffectUniform &effect [[buffer(1)]]
    ) {
        float2 localPosition = vertices[vertexID].position.xy;
        float2 normalizedPosition = float2(
            mix(effect.overlayRect.x, effect.overlayRect.y, localPosition.x),
            mix(effect.overlayRect.z, effect.overlayRect.w, localPosition.y)
        );

        DeletionEffectRasterizedVertex out;
        out.position = float4(
            normalizedPosition.x * 2.0 - 1.0,
            1.0 - normalizedPosition.y * 2.0,
            0.0,
            1.0
        );
        out.normalizedPosition = normalizedPosition;
        out.localPosition = localPosition;
        out.rect = effect.rect;
        out.overlayRect = effect.overlayRect;
        out.timing = effect.timing;
        out.metrics = effect.metrics;
        return out;
    }

    fragment float4 deletion_effect_fragment(
        DeletionEffectRasterizedVertex in [[stage_in]],
        constant WaveformShaderBin *bins [[buffer(1)]],
        constant DeletionEffectUniform &effect [[buffer(2)]]
    ) {
        float width = max(effect.metrics.x, 1.0);
        float height = max(effect.metrics.y, 1.0);
        float laneHeightPixels = max(effect.metrics.z, 1.0);
        float progress = clamp(effect.timing.x, 0.0, 1.0);
        float blast = clamp(effect.timing.y, 0.0, 1.0);
        float seed = effect.timing.z;
        uint selectedBinCount = uint(max(effect.timing.w, 0.0));
        uint trailingBinCount = uint(max(effect.ripple.z, 0.0));
        float left = effect.rect.x;
        float right = effect.rect.y;
        float top = effect.rect.z;
        float bottom = effect.rect.w;
        float trailingEnd = max(effect.ripple.x, right);
        float slide = clamp(effect.ripple.y, 0.0, 1.0);
        float deletionWidth = max(effect.ripple.w, max(right - left, 0.000001));
        float shiftedRight = mix(right, left, slide);
        float shiftedEnd = max(shiftedRight, trailingEnd - deletionWidth * slide);
        float centerY = (top + bottom) * 0.5;
        float2 point = in.normalizedPosition;
        float2 pixelPoint = point * float2(width, height);
        float yAA = max(fwidth(point.y) * 0.75, 0.000001);
        float4 color = float4(0.0);

        if (point.y >= top && point.y <= bottom) {
            float laneCoverage = rectangle_coverage(point.y, top, bottom, yAA);
            float maskRight = max(max(right, shiftedEnd), left + deletionWidth);
            if (point.x >= left && point.x <= maskRight) {
                float coverFade = 1.0 - smoothstep(0.86, 1.0, slide);
                float xAA = max(fwidth(point.x) * 1.5, 0.0005);
                float xCoverage = smoothstep(left - xAA, left + xAA, point.x) *
                    (1.0 - smoothstep(maskRight - xAA, maskRight + xAA, point.x));
                float coverAlpha = 0.92 * coverFade * laneCoverage * xCoverage;
                color = source_over(color, float4(0.070, 0.072, 0.072, coverAlpha));
            }

            float compressedSelectionRight = max(left + 1.0 / width, shiftedRight);
            float compressedSelectionWidthPixels = (compressedSelectionRight - left) * width;
            if (compressedSelectionWidthPixels > 1.0 &&
                point.x >= left &&
                point.x <= compressedSelectionRight) {
                float selectionXAA = max(fwidth(point.x) * 1.25, 1.0 / width);
                float selectionCoverage = laneCoverage *
                    rectangle_coverage(point.x, left, compressedSelectionRight, selectionXAA);
                float edgePulse = 1.0 - smoothstep(
                    0.0,
                    max(3.5 / width, 0.000001),
                    abs(point.x - compressedSelectionRight)
                );
                color = source_over(
                    color,
                    float4(
                        0.0,
                        0.84,
                        0.78,
                        selectionCoverage * (0.21 + 0.08 * edgePulse)
                    )
                );
            }

            if (trailingBinCount > 0 &&
                shiftedEnd > shiftedRight + 0.000001 &&
                point.x >= shiftedRight &&
                point.x <= shiftedEnd) {
                float localX = clamp(
                    (point.x - shiftedRight) / max(shiftedEnd - shiftedRight, 0.000001),
                    0.0,
                    1.0
                );
                float localY = clamp((point.y - top) / max(bottom - top, 0.000001), 0.0, 1.0);
                float localYAA = max(fwidth(localY) * 0.75, 0.000001);
                WaveformShaderBin bin = sample_waveform_bin(
                    localX,
                    bins,
                    trailingBinCount,
                    selectedBinCount,
                    0.82
                );
                float peakTop = 0.5 - bin.maximumSample * 0.39;
                float peakBottom = 0.5 - bin.minimumSample * 0.39;
                if (peakBottom - peakTop < 0.006) {
                    float midpoint = (peakTop + peakBottom) * 0.5;
                    peakTop = midpoint - 0.003;
                    peakBottom = midpoint + 0.003;
                }

                float waveformCoverage = rectangle_coverage(localY, peakTop, peakBottom, localYAA);
                float edgeFade = smoothstep(0.0, 0.010, localX) *
                    (1.0 - smoothstep(0.992, 1.0, localX));
                float settleFade = 1.0 - smoothstep(0.92, 1.0, slide);
                float waveformAlpha = waveformCoverage *
                    edgeFade *
                    settleFade *
                    (0.24 + 0.38 * bin.peakMagnitude);
                if (waveformAlpha > 0.0) {
                    float cold = hash11(seed + floor(localX * float(trailingBinCount)) * 61.0);
                    float3 waveformColor = float3(
                        0.70 + 0.12 * cold,
                        0.88 + 0.08 * cold,
                        0.86 + 0.08 * hash11(seed + floor(localX * float(trailingBinCount)) * 67.0)
                    );
                    color = source_over(color, float4(waveformColor, waveformAlpha));
                }
            }
        }

        if (selectedBinCount > 0 &&
            point.x >= left &&
            point.x <= right &&
            point.y >= top &&
            point.y <= bottom) {
            float localX = clamp((point.x - left) / max(right - left, 0.000001), 0.0, 1.0);
            float localY = clamp((point.y - top) / max(bottom - top, 0.000001), 0.0, 1.0);
            WaveformShaderBin bin = sample_waveform_bin(localX, bins, selectedBinCount, 0u, 0.72);
            float peakTop = 0.5 - bin.maximumSample * 0.39;
            float peakBottom = 0.5 - bin.minimumSample * 0.39;
            if (peakBottom - peakTop < 0.006) {
                float midpoint = (peakTop + peakBottom) * 0.5;
                peakTop = midpoint - 0.003;
                peakBottom = midpoint + 0.003;
            }

            float localYAA = max(fwidth(localY) * 0.75, 0.000001);
            float waveformCoverage = rectangle_coverage(localY, peakTop, peakBottom, localYAA);
            float visibility = 1.0 - smoothstep(0.0, 0.48, progress);
            float dissolveNoise = hash21(float2(
                floor(localX * float(selectedBinCount) * 1.7) + seed,
                floor(localY * 86.0)
            ));
            float dissolveMask = 1.0 - smoothstep(progress * 1.15, progress * 1.15 + 0.22, dissolveNoise);
            float waveformAlpha = visibility * visibility *
                waveformCoverage *
                dissolveMask *
                (0.18 + 0.42 * bin.peakMagnitude);
            if (waveformAlpha > 0.0) {
                float cold = hash11(seed + floor(localX * float(selectedBinCount)) * 79.0);
                float3 waveformColor = float3(
                    0.70 + 0.22 * cold,
                    0.96 + 0.04 * cold,
                    0.94 + 0.06 * hash11(seed + floor(localX * float(selectedBinCount)) * 83.0)
                );
                color = source_over(color, float4(waveformColor, waveformAlpha));
            }

            float flash = 1.0 - smoothstep(0.0, 0.15, progress);
            if (flash > 0.001) {
                float inset = min(0.10, 18.0 / laneHeightPixels);
                float flashCoverage = rectangle_coverage(localY, inset, 1.0 - inset, localYAA);
                color = source_over(color, float4(0.34, 1.0, 0.94, 0.10 * flash * flashCoverage));

                float centerCoverage = 1.0 - smoothstep(
                    1.2 + 3.0 * flash,
                    2.2 + 3.0 * flash,
                    abs((localY - 0.5) * laneHeightPixels)
                );
                color = source_over(
                    color,
                    float4(0.82, 1.0, 0.98, 0.28 * flash * max(centerCoverage, 0.0))
                );
            }
        }

        float travelProgress = smoothstep(0.0, 1.0, clamp(progress / 0.34, 0.0, 1.0));
        float fadeOut = 1.0 - smoothstep(0.0, 1.0, clamp((progress - 0.24) / 0.28, 0.0, 1.0));
        float streakAlpha = 0.34 * travelProgress * fadeOut;
        if (streakAlpha > 0.001) {
            float joinX = left * width;
            float rightX = right * width;
            float topY = top * height;
            float pullDistance = max(rightX - joinX, 22.0);
            for (uint index = 0; index < 9; ++index) {
                float localSeed = seed + float(index) * 153.31;
                float y = topY + (0.20 + 0.60 * hash11(localSeed + 19.0)) * laneHeightPixels;
                float jitter = (hash11(localSeed + 29.0) - 0.5) * laneHeightPixels * 0.08;
                float rightStart = rightX + 18.0 + hash11(localSeed + 41.0) * min(pullDistance * 0.32, 90.0);
                float rightNow = mix(rightStart, joinX, travelProgress);
                float coverage = deletion_line_coverage(
                    pixelPoint,
                    float2(rightNow, y + jitter),
                    float2(joinX, y + jitter * 0.35),
                    0.65 + 0.70 * hash11(localSeed + 89.0),
                    1.1
                );
                color = source_over(color, float4(
                    0.70,
                    0.98,
                    0.96,
                    coverage * streakAlpha * (0.55 + hash11(localSeed + 73.0) * 0.45)
                ));
            }
        }

        float flareProgress = clamp((progress - 0.16) / 0.30, 0.0, 1.0);
        float flareEnergy = sin(flareProgress * 3.14159265);
        if (flareEnergy > 0.001) {
            float2 flareCenter = float2(left * width, centerY * height);
            float distance = length(pixelPoint - flareCenter);
            float coreRadius = (6.0 + laneHeightPixels * 0.07) * (0.70 + flareProgress * 1.25);
            float coreCoverage = 1.0 - smoothstep(coreRadius, coreRadius + 10.0, distance);
            float haloCoverage = 1.0 - smoothstep(coreRadius * 1.65, coreRadius * 1.65 + 18.0, distance);
            color = source_over(
                color,
                float4(0.78, 1.0, 0.96, max(coreCoverage, 0.0) * 0.28 * flareEnergy)
            );
            color = source_over(
                color,
                float4(0.38, 0.96, 1.0, max(haloCoverage, 0.0) * 0.075 * flareEnergy)
            );

            float verticalCoverage = 1.0 - smoothstep(
                0.6 + 2.1 * flareEnergy,
                1.8 + 2.1 * flareEnergy,
                abs(pixelPoint.x - flareCenter.x)
            );
            float verticalSpan = rectangle_coverage(
                pixelPoint.y,
                flareCenter.y - laneHeightPixels * 0.42,
                flareCenter.y + laneHeightPixels * 0.42,
                1.2
            );
            color = source_over(
                color,
                float4(0.72, 1.0, 0.96, verticalCoverage * verticalSpan * 0.18 * flareEnergy)
            );
        }

        return float4(clamp(color.rgb, float3(0.0), float3(1.0)), clamp(color.a, 0.0, 1.0));
    }

    vertex DeletionParticleRasterizedVertex deletion_particle_vertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant WaveformShaderQuadVertex *vertices [[buffer(0)]],
        constant DeletionEffectUniform &effect [[buffer(1)]]
    ) {
        float2 unit = vertices[vertexID].position.xy;
        float2 corner = unit * 2.0 - 1.0;
        float width = max(effect.metrics.x, 1.0);
        float height = max(effect.metrics.y, 1.0);
        float laneHeightPixels = max(effect.metrics.z, 1.0);
        float duration = max(effect.metrics.w, 0.000001);
        float progress = clamp(effect.timing.x, 0.0, 1.0);
        float blast = clamp(effect.timing.y, 0.0, 1.0);
        float seed = effect.timing.z + float(instanceID) * 917.37;
        float leftX = effect.rect.x * width;
        float rightX = effect.rect.y * width;
        float topY = effect.rect.z * height;
        float bottomY = effect.rect.w * height;
        float centerY = (topY + bottomY) * 0.5;
        float sourceX = mix(leftX, rightX, hash11(seed + 17.0));
        float yBias = pow(hash11(seed + 31.0), 1.7);
        float sourceY = centerY + (yBias * 2.0 - 1.0) * laneHeightPixels * 0.39;
        float angle = hash11(seed + 47.0) * 6.2831853;
        float2 direction = float2(cos(angle), sin(angle));
        float speed = 34.0 + 210.0 * hash11(seed + 71.0);
        float ageSeconds = progress * duration;
        float2 center = float2(sourceX, sourceY) +
            direction * speed * ageSeconds * (0.35 + blast * 1.25);
        float radius = 0.62 + 2.5 * hash11(seed + 89.0);
        float dissolve = 1.0 - smoothstep(0.0, 1.0, progress);
        float alpha = progress < 0.78 ?
            dissolve * dissolve * (0.16 + 0.14 * hash11(seed + 167.0)) :
            0.0;
        float3 color = float3(
            0.70 + 0.30 * hash11(seed + 131.0),
            0.91 + 0.09 * hash11(seed + 137.0),
            0.92 + 0.08 * hash11(seed + 149.0)
        );

        float2 normalizedPosition = (center + corner * radius) / float2(width, height);
        DeletionParticleRasterizedVertex out;
        out.position = float4(
            normalizedPosition.x * 2.0 - 1.0,
            1.0 - normalizedPosition.y * 2.0,
            0.0,
            1.0
        );
        out.localPosition = corner;
        out.color = float4(color, alpha);
        return out;
    }

    fragment float4 deletion_particle_fragment(
        DeletionParticleRasterizedVertex in [[stage_in]],
        constant DeletionEffectUniform &effect [[buffer(1)]]
    ) {
        float distance = length(in.localPosition);
        float coverage = 1.0 - smoothstep(0.15, 1.0, distance);
        float softCore = 1.0 - smoothstep(0.0, 0.38, distance);
        float alpha = in.color.a * max(coverage, 0.0) * (0.72 + 0.28 * max(softCore, 0.0));
        return float4(in.color.rgb, alpha);
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
        uint binOffset = uint(max(in.track.z, 0.0));
        float sampleX = inverse_fisheye_x(in.normalizedPosition.x, in.fisheye);
        float timelineProgress = in.viewport.x + sampleX * in.viewport.y;

        if (timelineProgress < 0.0 ||
            timelineProgress > trackDurationProgress ||
            in.normalizedPosition.y < laneTop ||
            in.normalizedPosition.y > laneBottom) {
            return float4(0.0);
        }

        float localProgress = timelineProgress / trackDurationProgress;
        float smoothAmount = max(
            clamp(in.track.w, 0.0, 1.0),
            fisheye_sample_smoothing(in.normalizedPosition.x, in.fisheye)
        );
        WaveformShaderBin bin = sample_waveform_bin(localProgress, bins, binCount, binOffset, smoothAmount);
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
                in.touch3.x,
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
