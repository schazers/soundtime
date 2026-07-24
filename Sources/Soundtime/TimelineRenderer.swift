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
    let shaderBufferUploadByteCount: Int
    let shaderBufferCount: Int
    let shaderBufferByteCount: Int
    let shaderBufferUploadInFlightCount: Int
    let waveformMipCacheCount: Int
    let cpuWaveformFallbackDrawCount: Int
    let waveformFallbackDrawCount: Int
    let waveformLastGoodHoldCount: Int
    let waveformResidentMissCount: Int
    let waveformHotPathViolationCount: Int
    let waveformHotPathReason: String
    let gpuResidentWaveformMode: String
    let gpuResidentShadowSourceCount: Int
    let gpuResidentShadowRequestCount: Int
    let gpuResidentShadowVisibleTileCount: Int
    let gpuResidentShadowDrawBatchCount: Int
    let gpuResidentShadowDrawInstanceCount: Int
    let effectVertexCount: Int
    let effectDroppedVertexCount: Int
    let transientParticleCount: Int
    let deletionEffectCount: Int
    let playheadContactEventCount: Int
}

struct SelectionDragWaveformTuning: Equatable, Sendable {
    static let defaultValue = SelectionDragWaveformTuning()

    var minimumSpeedPixelsPerSecond: Float = 120
    var fullSpeedPixelsPerSecond: Float = 1_800
    var contactLifetime: CFTimeInterval = 0.174
    var frontRadiusPixels: Float = 10
    var backRadiusPixels: Float = 38
    var contactCoreRadiusPixels: Float = 3
    var maximumExpansion: Float = 0.38
    var maximumWhitening: Float = 0.65
    var maximumContactCount: Int = 4
    var particleLimit: Int = 56

    var sanitized: SelectionDragWaveformTuning {
        var tuning = self
        tuning.minimumSpeedPixelsPerSecond = min(max(tuning.minimumSpeedPixelsPerSecond, 0), 2_400)
        tuning.fullSpeedPixelsPerSecond = min(
            max(tuning.fullSpeedPixelsPerSecond, tuning.minimumSpeedPixelsPerSecond + 1),
            4_800
        )
        tuning.contactLifetime = min(max(tuning.contactLifetime, 0.08), 0.24)
        tuning.frontRadiusPixels = min(max(tuning.frontRadiusPixels, 1), 80)
        tuning.backRadiusPixels = min(max(tuning.backRadiusPixels, 1), 140)
        tuning.contactCoreRadiusPixels = min(max(tuning.contactCoreRadiusPixels, 1), 24)
        tuning.maximumExpansion = min(max(tuning.maximumExpansion, 0), 1.4)
        tuning.maximumWhitening = min(max(tuning.maximumWhitening, 0), 1)
        tuning.maximumContactCount = min(max(tuning.maximumContactCount, 0), 4)
        tuning.particleLimit = min(max(tuning.particleLimit, 0), 160)
        return tuning
    }
}

struct TimelineRenderTarget: @unchecked Sendable {
    let renderPassDescriptor: MTLRenderPassDescriptor
    let drawable: MTLDrawable
    let viewportSize: CGSize
    let backingScale: Float
    let displayTimestamp: CFTimeInterval
    let publishesFrameStats: Bool

    func withPublishesFrameStats(_ publishesFrameStats: Bool) -> TimelineRenderTarget {
        TimelineRenderTarget(
            renderPassDescriptor: renderPassDescriptor,
            drawable: drawable,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: displayTimestamp,
            publishesFrameStats: publishesFrameStats
        )
    }
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
        var sourceMap: SIMD4<Float>
        var segmentGain: SIMD4<Float>
        var style: SIMD4<Float>
        var style2: SIMD4<Float>
        var gainPreview: SIMD4<Float>
        var fisheye: SIMD4<Float>
        var touch: SIMD4<Float>
        var touch2: SIMD4<Float>
        var touch3: SIMD4<Float>
        var selectionDrag: SIMD4<Float>
        var selectionDrag2: SIMD4<Float>
        var selectionDragContact0: SIMD4<Float>
        var selectionDragContact1: SIMD4<Float>
        var selectionDragContact2: SIMD4<Float>
        var selectionDragContact3: SIMD4<Float>
        var selectionDragContact4: SIMD4<Float>
        var selectionDragContact5: SIMD4<Float>
        var selectionDragContact6: SIMD4<Float>
        var selectionDragContact7: SIMD4<Float>
        var deletionWarp: SIMD4<Float>
    }

    private struct DeletionEffectUniform {
        var rect: SIMD4<Float>
        var overlayRect: SIMD4<Float>
        var timing: SIMD4<Float>
        var metrics: SIMD4<Float>
        var ripple: SIMD4<Float>
        var waveformStyle: SIMD4<Float>
        var waveformStyle2: SIMD4<Float>
    }

    private struct SelectionDragEffectUniform {
        var rect: SIMD4<Float>
        var metrics: SIMD4<Float>
        var effect: SIMD4<Float>
        var color: SIMD4<Float>
        var mask: SIMD4<Float>
    }

    private struct SelectionOverlayUniform {
        var rect: SIMD4<Float>
        var metrics: SIMD4<Float>
        var style: SIMD4<Float>
        var pulse: SIMD4<Float>
        var baseColor: SIMD4<Float>
        var progressColor: SIMD4<Float>
        var fisheye: SIMD4<Float>
    }

    private struct LoopRegionUniform {
        var rect: SIMD4<Float>
        var metrics: SIMD4<Float>
        var style: SIMD4<Float>
        var edgeHighlight: SIMD4<Float>
        var fillColor: SIMD4<Float>
        var topColor: SIMD4<Float>
        var bottomColor: SIMD4<Float>
        var edgeColor: SIMD4<Float>
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
        let projectDuration: TimeInterval
        let viewportStart: Float
        let viewportDuration: Float
        let trackCount: Int
        let trackHeight: Float
        let trackScrollOffset: Float
        let rulerLaneHeight: Float
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
        let isPreferred: Bool
    }

    private struct WaveformShaderPromotionLayer {
        let drawable: WaveformShaderDrawable
        let alpha: Float
    }

    private struct WaveformShaderPromotionRecord {
        var waveformVersion: Int
        var current: WaveformShaderDrawable
        var previous: WaveformShaderDrawable?
        var startedAt: CFTimeInterval
    }

    private struct PendingWaveformShaderBinPublish {
        let bins: [WaveformShaderBin]
        let generation: Int?
        let byteCount: Int
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
        private var preparingKeys: Set<WaveformMipCacheKey> = []
        private var publishedBufferCount = 0
        private var publishedBufferByteCount = 0

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
                !preparingKeys.contains(key),
                preparingKeys.count < max(maximumInFlightCount, 1)
            else {
                return false
            }
            preparingKeys.insert(key)
            return true
        }

        func isPreparing(_ key: WaveformMipCacheKey) -> Bool {
            lock.lock()
            defer {
                lock.unlock()
            }
            return preparingKeys.contains(key)
        }

        func publish(_ bins: [WaveformShaderBin]?, for key: WaveformMipCacheKey) {
            lock.lock()
            if let bins, !bins.isEmpty {
                publishLocked(bins, for: key)
            }
            preparingKeys.remove(key)
            lock.unlock()
        }

        func publishPreservingPreparation(_ bins: [WaveformShaderBin]?, for key: WaveformMipCacheKey) {
            lock.lock()
            if let bins, !bins.isEmpty {
                publishLocked(bins, for: key)
            }
            lock.unlock()
        }

        private func publishLocked(_ bins: [WaveformShaderBin], for key: WaveformMipCacheKey) {
            guard allocations[key] == nil else {
                markAccessed(key)
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
            publishedBufferCount += 1
            publishedBufferByteCount += byteCount
            markAccessed(key)
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
                publishedBufferByteCount += buffer.length
            }
            preparingKeys.remove(key)
            lock.unlock()
        }

        func drainPublishedBufferStats() -> (count: Int, byteCount: Int) {
            lock.lock()
            let count = publishedBufferCount
            let byteCount = publishedBufferByteCount
            publishedBufferCount = 0
            publishedBufferByteCount = 0
            lock.unlock()
            return (count, byteCount)
        }

        func diagnostics() -> (bufferCount: Int, byteCount: Int, inFlightCount: Int) {
            lock.lock()
            defer {
                lock.unlock()
            }

            let totalSlabByteCount = slabs.reduce(0) { result, slab in
                result + slab.buffer.length
            }
            return (allocations.count, totalSlabByteCount, 0)
        }

        func containsAllAllocatedOrInFlight(_ keys: [WaveformMipCacheKey]) -> Bool {
            lock.lock()
            defer {
                lock.unlock()
            }

            return keys.allSatisfy { key in
                allocations[key] != nil || preparingKeys.contains(key)
            }
        }

        func containsAllAllocated(_ keys: [WaveformMipCacheKey]) -> Bool {
            lock.lock()
            defer {
                lock.unlock()
            }

            return keys.allSatisfy { key in
                allocations[key] != nil
            }
        }

        func trim(
            toMaximumCount maximumCount: Int,
            maximumByteCount: Int,
            protecting protectedKeys: Set<WaveformMipCacheKey> = []
        ) {
            lock.lock()
            if allocations.count > maximumCount || diagnosticsByteCountLocked() > maximumByteCount {
                compactAllocationsLocked(
                    maximumCount: max(maximumCount, 1),
                    maximumByteCount: max(maximumByteCount, 0),
                    protecting: protectedKeys
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
                allocations[key] != nil || preparingKeys.contains(key)
            }
        }

        private func compactAllocationsLocked(
            maximumCount: Int,
            maximumByteCount: Int,
            protecting protectedKeys: Set<WaveformMipCacheKey>
        ) {
            guard !allocations.isEmpty else {
                slabs.removeAll()
                compactAccessTicksLocked()
                return
            }

            let rankedKeys = allocations.keys.sorted { lhs, rhs in
                let lhsIsProtected = protectedKeys.contains(lhs)
                let rhsIsProtected = protectedKeys.contains(rhs)
                if lhsIsProtected != rhsIsProtected {
                    return lhsIsProtected
                }
                return (accessTicks[lhs] ?? 0) > (accessTicks[rhs] ?? 0)
            }
            var keptAllocations: [(key: WaveformMipCacheKey, allocation: WaveformShaderBufferAllocation)] = []
            keptAllocations.reserveCapacity(min(max(maximumCount, protectedKeys.count), allocations.count))
            var keptByteCount = 0

            for key in rankedKeys {
                guard let allocation = allocations[key] else {
                    continue
                }

                let projectedByteCount = keptByteCount + allocation.byteCount
                let isProtected = protectedKeys.contains(key)
                let fitsCount = keptAllocations.count < maximumCount || isProtected
                let fitsBytes = projectedByteCount <= maximumByteCount || keptAllocations.isEmpty || isProtected
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

    private struct SelectionDragWaveformContact: Sendable {
        let trackID: UUID?
        let progress: Float
        let direction: Float
        let strength: Float
        let birthTimestamp: CFTimeInterval
    }

    private struct SelectionDragWaveformContactVectors {
        var contact0 = SIMD4<Float>.zero
        var contact1 = SIMD4<Float>.zero
        var contact2 = SIMD4<Float>.zero
        var contact3 = SIMD4<Float>.zero
        var contact4 = SIMD4<Float>.zero
        var contact5 = SIMD4<Float>.zero
        var contact6 = SIMD4<Float>.zero
        var contact7 = SIMD4<Float>.zero
        var activeCount: Int = 0

        static let empty = SelectionDragWaveformContactVectors()

        init(_ contacts: [SIMD4<Float>] = []) {
            activeCount = min(max(contacts.count, 0), 8)
            var padded = contacts
            if padded.count < 8 {
                padded.append(contentsOf: Array(repeating: .zero, count: 8 - padded.count))
            }
            contact0 = padded[0]
            contact1 = padded[1]
            contact2 = padded[2]
            contact3 = padded[3]
            contact4 = padded[4]
            contact5 = padded[5]
            contact6 = padded[6]
            contact7 = padded[7]
        }
    }

    private struct ProcessingSelectionProgress {
        let selection: TimelineSelection
        let startFraction: Float?
        let targetFraction: Float?
        let transitionStartTimestamp: CFTimeInterval
        let pulseStartTimestamp: CFTimeInterval
    }

    private enum TimelineEditEffectKind {
        case deletion
        case insertion
    }

    private struct DeletionEffect {
        let selection: TimelineSelection
        let visualAnchor: SIMD4<Float>
        let capturedBinBuffer: MTLBuffer?
        let capturedBinCount: Int
        let capturedEnergySamples: [Float]
        var birthTimestamp: CFTimeInterval
        let seed: UInt64
        let kind: TimelineEditEffectKind
    }

    private struct TransientParticleScoreProfile {
        let threshold: Float
        let loudestScore: Float
    }

    private struct WaveformVisualStyle {
        let spectralAmount: Float
        let peakAlpha: Float
        let bodyAlpha: Float
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

    private final class TimelineInteractionStateStore {
        private let lock = NSLock()
        private var viewport: TimelineViewport?
        private var selection: TimelineSelection?
        private var selectionDragSnapshot: TimelineSelectionDragSnapshot?
        private var selectionDragWaveformContacts: [SelectionDragWaveformContact] = []
        private var hoverProgress: Float?
        private var isHoverArmed = false

        func publishViewport(_ viewport: TimelineViewport) {
            lock.lock()
            defer {
                lock.unlock()
            }
            self.viewport = viewport
        }

        func publishSelection(_ selection: TimelineSelection?) {
            lock.lock()
            defer {
                lock.unlock()
            }
            self.selection = selection
        }

        func publishSelectionDragSnapshot(
            _ snapshot: TimelineSelectionDragSnapshot?,
            contact: SelectionDragWaveformContact?,
            displayTimestamp: CFTimeInterval,
            lifetime: CFTimeInterval,
            maximumCount: Int
        ) {
            lock.lock()
            defer {
                lock.unlock()
            }
            selectionDragSnapshot = snapshot
            pruneSelectionDragWaveformContacts(
                displayTimestamp: displayTimestamp,
                lifetime: lifetime,
                maximumCount: maximumCount
            )
            guard maximumCount > 0, let contact else {
                return
            }

            let minimumContactInterval = maximumCount > 1 ?
                min(max(lifetime / Double(maximumCount) * 0.28, 1.0 / 144.0), 1.0 / 28.0) :
                0
            if
                let lastContact = selectionDragWaveformContacts.last,
                displayTimestamp - lastContact.birthTimestamp < minimumContactInterval
            {
                selectionDragWaveformContacts[selectionDragWaveformContacts.count - 1] = contact
            } else {
                selectionDragWaveformContacts.append(contact)
            }
            pruneSelectionDragWaveformContacts(
                displayTimestamp: displayTimestamp,
                lifetime: lifetime,
                maximumCount: maximumCount
            )
        }

        func publishHover(progress: Float?, isArmed: Bool) {
            lock.lock()
            defer {
                lock.unlock()
            }
            hoverProgress = progress
            isHoverArmed = isArmed
        }

        func applying(to state: TimelineRenderState) -> TimelineRenderState {
            lock.lock()
            defer {
                lock.unlock()
            }
            var state = state
            if let viewport {
                state = state.withViewport(viewport)
            }
            return state
                .withSelection(selection)
                .withHover(progress: hoverProgress, isArmed: isHoverArmed)
        }

        func currentSelectionDragSnapshot() -> TimelineSelectionDragSnapshot? {
            lock.lock()
            defer {
                lock.unlock()
            }
            return selectionDragSnapshot
        }

        func selectionDragWaveformContactsSnapshot(
            displayTimestamp: CFTimeInterval,
            lifetime: CFTimeInterval,
            maximumCount: Int
        ) -> [SelectionDragWaveformContact] {
            lock.lock()
            defer {
                lock.unlock()
            }
            pruneSelectionDragWaveformContacts(
                displayTimestamp: displayTimestamp,
                lifetime: lifetime,
                maximumCount: maximumCount
            )
            return selectionDragWaveformContacts
        }

        private func pruneSelectionDragWaveformContacts(
            displayTimestamp: CFTimeInterval,
            lifetime: CFTimeInterval,
            maximumCount: Int
        ) {
            let clampedLifetime = max(lifetime, 0.001)
            selectionDragWaveformContacts.removeAll {
                displayTimestamp - $0.birthTimestamp > clampedLifetime
            }
            let clampedMaximumCount = max(maximumCount, 0)
            let storageMaximumCount = min(max(clampedMaximumCount * 6, clampedMaximumCount), 64)
            if selectionDragWaveformContacts.count > storageMaximumCount {
                selectionDragWaveformContacts.removeFirst(
                    selectionDragWaveformContacts.count - storageMaximumCount
                )
            }
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
    private let selectionOverlayPipelineState: MTLRenderPipelineState
    private let loopRegionPipelineState: MTLRenderPipelineState
    private let selectionDragEffectPipelineState: MTLRenderPipelineState
    private let deletionEffectPipelineState: MTLRenderPipelineState
    private let dynamicVertexBufferRing: DynamicVertexBufferRing
    private let waveformQuadVertexBuffer: MTLBuffer
    private let deletionPlaceholderBinBuffer: MTLBuffer
    private let waveformGeometryQueue = DispatchQueue(
        label: "Soundtime.timeline.waveform.geometry",
        qos: .userInitiated
    )
    private let waveformGeometryStore = WaveformGeometryStore()
    private let waveformHotPathLock = NSLock()
    private let renderStateStore = TimelineRenderStateStore(initialState: .empty)
    private let interactionStateStore = TimelineInteractionStateStore()
    private let tiledWaveformPipeline: WaveformTiledRenderPipeline?
    private let tiledWaveformMetalBufferStore: WaveformTileMetalBufferStore?
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
    private let waveformCPUFallbackInteractionCooldown: CFTimeInterval = 0.35
    private let gpuResidentShadowInteractionCooldown: CFTimeInterval = 0.45
    private let processingSelectionProgressSmoothingDuration: CFTimeInterval = 0.42
    private var lastWaveformHotInteractionTimestamp: CFTimeInterval = -Double.infinity
    private var waveformSourceTracksByID: [UUID: TimelineRenderState.Track] = [:]
    private var currentTrackWaveformMipKeys: [UUID: WaveformMipCacheKey] = [:]
    private var currentPrimaryWaveformTrackID: UUID?
    private var previousTransitionTracks: [TimelineRenderState.Track] = []
    private var previousTransitionViewport: TimelineViewport?
    private var waveformMipLevelCache: [WaveformMipCacheKey: [WaveformMipLevel]] = [:]
    private var waveformMipLevelCacheOrder: [WaveformMipCacheKey] = []
    private var waveformMipLevelBuildsInFlight: Set<WaveformMipCacheKey> = []
    private var pendingCompleteWaveformMipLevels: [WaveformMipCacheKey: [WaveformMipLevel]] = [:]
    private let waveformMipLevelCacheLock = NSLock()
    private let waveformShaderBufferStore: WaveformShaderBufferStore
    private let deferredWaveformShaderPublishLock = NSLock()
    private var deferredWaveformShaderBinPublishes: [WaveformMipCacheKey: PendingWaveformShaderBinPublish] = [:]
    private var deferredWaveformShaderPublishWakeupScheduled = false
    private var waveformShaderBatchScratch: [WaveformShaderBatch] = []
    private var waveformShaderPromotionRecordsByTrackID: [UUID: WaveformShaderPromotionRecord] = [:]
    private let waveformShaderPromotionDuration: CFTimeInterval = 0.12
    private var lastInteractiveWaveformPrewarmKeys: [WaveformMipCacheKey] = []
    private var waveformShaderPrewarmGeneration = 0
    private var selectedTrackVertexScratch: [TimelineVertex] = []
    private var processingTrackVertexScratch: [TimelineVertex] = []
    private var candidateRegionVertexScratch: [TimelineVertex] = []
    private var selectionVertexScratch: [TimelineVertex] = []
    private var processingSelectionProgress: ProcessingSelectionProgress?
    private var selectionDragGlowVertexScratch: [TimelineVertex] = []
    private var clipBoundaryVertexScratch: [TimelineVertex] = []
    private var loopRange = TimelineLoopRange.default
    private var isLoopRangeEnabled = true
    private var isLoopRegionHighlighted = false
    private var loopRangeFlashStartTime: CFTimeInterval?
    private var highlightedLoopEndpoint: TimelineLoopEndpoint?
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
    private var isModalBackdropActive = false
    private var transientParticles: [TransientParticle] = []
    private var deletionEffects: [DeletionEffect] = []
    private var lastDeletionEffectsClearedTimestamp: CFTimeInterval = -Double.infinity
    private let deletionEffectLock = NSLock()
    private var selectionCopyFlashStartTime: CFTimeInterval?
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
    private var frameStatsShaderBufferUploadByteCount = 0
    private var frameStatsCPUWaveformFallbackDrawCount = 0
    private var frameStatsWaveformFallbackDrawCount = 0
    private var frameStatsWaveformLastGoodHoldCount = 0
    private var frameStatsWaveformResidentMissCount = 0
    private var frameStatsWaveformHotPathViolationCount = 0
    private var frameStatsWaveformHotPathReason = ""
    private var frameStatsGPUResidentWaveformMode = WaveformGPUResidentWaveformsFeatureFlags.modeDescription
    private var frameStatsGPUResidentShadowSourceCount = 0
    private var frameStatsGPUResidentShadowRequestCount = 0
    private var frameStatsGPUResidentShadowVisibleTileCount = 0
    private var frameStatsGPUResidentShadowDrawBatchCount = 0
    private var frameStatsGPUResidentShadowDrawInstanceCount = 0
    private var frameStatsEffectVertexCount = 0
    private var frameStatsEffectDroppedVertexCount = 0
    private var frameStatsTransientParticleCount = 0
    private var frameStatsDeletionEffectCount = 0
    private var frameStatsPlayheadContactEventCount = 0
    private var lastWaveformPerformanceContractEventTime: CFTimeInterval = -Double.infinity
    private var lastImmediateHotPathFrameStatsPublishTime: CFTimeInterval = -Double.infinity
    private var lastFrameStats: TimelineFrameStats?
    private var lastRenderViewportSize = CGSize(width: 1600, height: 900)
    private var lastRenderBackingScale: Float = 1
    var onFrameStatsChanged: ((TimelineFrameStats) -> Void)?
    var onRenderDataPrepared: (() -> Void)?

    func currentFrameStatsSnapshot() -> TimelineFrameStats {
        if let lastFrameStats {
            return lastFrameStats
        }

        return makeFrameStats(
            framesPerSecond: 0,
            averageFrameTimeMilliseconds: 0,
            frameTimeJitterMilliseconds: 0,
            worstFrameTimeMilliseconds: 0
        )
    }

    private let playheadTouchGeometryAheadDuration: TimeInterval = 0.055
    private let playheadTouchLightAheadDuration: TimeInterval = 0.08
    private var playheadTouchTrailDuration: TimeInterval = 0.56
    private var playheadTouchTrailFalloffSteepness: Float = 1.30
    private var waveformBaseGray: Float = 0.92
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
    private var selectionDragWaveformTuning = SelectionDragWaveformTuning.defaultValue
    private let maximumSelectionDragShaderContactCount = 4
    private let selectionDragEffectFadeDuration: CFTimeInterval = 0.22
    private let selectionDragWaveformContactMinimumStrength: Float = 0.001
    private let selectionDragSlowContactStrengthFloor: Float = 0.20
    private let selectionDragMotionEpsilonPixelsPerSecond: Float = 2.0
    private let deletionEffectDuration: CFTimeInterval = 0.14
    private let deletionEffectLifetimePadding: CFTimeInterval = 0.04
    private let deletionHandoffWaveformDemotionHoldDuration: CFTimeInterval = 0.18
    private let deletionEffectMaximumCount = 8
    private let deletionEffectMaximumCapturedBins = 512
    private let selectionCopyFlashDuration: CFTimeInterval = 0.20
    private let loopRangeFlashDuration: CFTimeInterval = 0.35
    private let transientParticleScorePercentile: Float = 0.997
    private let transientParticleProfileSampleLimit = 2_048
    private let transientParticleMinimumSpacing: TimeInterval = 0.32
    private let transientParticleMaximumScanDuration: TimeInterval = 0.12
    private let maximumInFlightTransientParticleScoreProfileBuilds = 4
    private let maximumSynchronousGeneratedWaveformMipBins = 8_192
    private let maximumInFlightWaveformMipBuilds = 4
    private let maximumGeneratedWaveformMipBins = 2_097_152
    private let generatedWaveformMipSamplesPerBin = 4
    private let highResolutionWaveformVisibleDurationThreshold: TimeInterval = 120
    private let overviewWaveformMipTargetBinsPerPixel: Float = 12.0
    private let mediumWaveformMipTargetBinsPerPixel: Float = 24.0
    private let detailWaveformMipTargetBinsPerPixel: Float = 64.0
    private let detailWaveformMipVisibleDuration: TimeInterval = 12
    private let mediumWaveformMipVisibleDuration: TimeInterval = 120
    private let overviewWaveformMipVisibleDuration: TimeInterval = 240
    private let minimumWaveformMipTargetVisibleBins: Float = 32_768
    private let maximumCachedWaveformMipPyramids = 512
    private let maximumCachedWaveformShaderBinBuffers = 2_048
    private let maximumCachedWaveformShaderBinBufferBytes = 1_024 * 1_024 * 1_024
    private let maximumBackgroundPrewarmedWaveformShaderBins = 16_384
    private let maximumViewportPrewarmedWaveformShaderBins = WaveformOverviewBuilder.defaultTargetBinCount
    private let detailMinimumDisplayableWaveformBinsPerPixel: Float = 1.65
    private let overviewMinimumDisplayableWaveformBinsPerPixel: Float = 0.72
    private let minimumDisplayableWaveformDurationThreshold: TimeInterval = 30
    private let maximumViewportPrewarmTrackCount = 32
    private let maximumHighResolutionPrewarmTrackCount = 8
    private let waveformShaderPrewarmTrackOverscan = 8
    private let waveformShaderHighResolutionPrewarmTrackOverscan = 1
    private let waveformPrewarmJobBatchSize = 8
    private let maximumInFlightWaveformShaderBufferUploads = 8
    private let maximumSynchronousWaveformShaderBinBufferBins = 16_384
    private let maximumSynchronousInteractiveWaveformShaderUploads = 2
    private let maximumDeferredWaveformShaderPublishCountPerFrame = 8
    private let maximumDeferredWaveformShaderPublishByteCountPerFrame = 4 * 1_024 * 1_024
    private let maximumLowCostContinuityWaveformShaderBins = 16_384
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
        var deletionPlaceholderBin = WaveformShaderBin(
            minimumSample: 0,
            maximumSample: 0,
            rmsSample: 0,
            lowEnergy: 0,
            midEnergy: 0,
            highEnergy: 0,
            peakMagnitude: 0,
            reserved: 0
        )
        guard let deletionPlaceholderBinBuffer = device.makeBuffer(
            bytes: &deletionPlaceholderBin,
            length: MemoryLayout<WaveformShaderBin>.stride,
            options: [.storageModeShared]
        ) else {
            throw RendererError.waveformQuadBufferUnavailable
        }
        deletionPlaceholderBinBuffer.label = "Timeline deletion placeholder bin"

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard
            let vertexFunction = library.makeFunction(name: "timeline_vertex"),
            let fragmentFunction = library.makeFunction(name: "timeline_fragment"),
            let waveformVertexFunction = library.makeFunction(name: "waveform_vertex"),
            let waveformFragmentFunction = library.makeFunction(name: "waveform_fragment"),
            let rulerVertexFunction = library.makeFunction(name: "timeline_ruler_vertex"),
            let rulerFragmentFunction = library.makeFunction(name: "timeline_ruler_fragment"),
            let selectionOverlayVertexFunction = library.makeFunction(name: "selection_overlay_vertex"),
            let selectionOverlayFragmentFunction = library.makeFunction(name: "selection_overlay_fragment"),
            let loopRegionVertexFunction = library.makeFunction(name: "loop_region_vertex"),
            let loopRegionFragmentFunction = library.makeFunction(name: "loop_region_fragment"),
            let selectionDragEffectVertexFunction = library.makeFunction(name: "selection_drag_effect_vertex"),
            let selectionDragEffectFragmentFunction = library.makeFunction(name: "selection_drag_effect_fragment"),
            let deletionEffectVertexFunction = library.makeFunction(name: "deletion_effect_vertex"),
            let deletionEffectFragmentFunction = library.makeFunction(name: "deletion_effect_fragment")
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
        let selectionOverlayDescriptor = MTLRenderPipelineDescriptor()
        selectionOverlayDescriptor.vertexFunction = selectionOverlayVertexFunction
        selectionOverlayDescriptor.fragmentFunction = selectionOverlayFragmentFunction
        selectionOverlayDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        selectionOverlayDescriptor.colorAttachments[0].isBlendingEnabled = true
        selectionOverlayDescriptor.colorAttachments[0].rgbBlendOperation = .add
        selectionOverlayDescriptor.colorAttachments[0].alphaBlendOperation = .add
        selectionOverlayDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        selectionOverlayDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        selectionOverlayDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        selectionOverlayDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let loopRegionDescriptor = MTLRenderPipelineDescriptor()
        loopRegionDescriptor.vertexFunction = loopRegionVertexFunction
        loopRegionDescriptor.fragmentFunction = loopRegionFragmentFunction
        loopRegionDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        loopRegionDescriptor.colorAttachments[0].isBlendingEnabled = true
        loopRegionDescriptor.colorAttachments[0].rgbBlendOperation = .add
        loopRegionDescriptor.colorAttachments[0].alphaBlendOperation = .add
        loopRegionDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        loopRegionDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        loopRegionDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        loopRegionDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let selectionDragEffectDescriptor = MTLRenderPipelineDescriptor()
        selectionDragEffectDescriptor.vertexFunction = selectionDragEffectVertexFunction
        selectionDragEffectDescriptor.fragmentFunction = selectionDragEffectFragmentFunction
        selectionDragEffectDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        selectionDragEffectDescriptor.colorAttachments[0].isBlendingEnabled = true
        selectionDragEffectDescriptor.colorAttachments[0].rgbBlendOperation = .add
        selectionDragEffectDescriptor.colorAttachments[0].alphaBlendOperation = .add
        selectionDragEffectDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        selectionDragEffectDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        selectionDragEffectDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        selectionDragEffectDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
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

        self.device = device
        self.commandQueue = commandQueue
        self.dynamicVertexBufferRing = dynamicVertexBufferRing
        self.waveformQuadVertexBuffer = waveformQuadVertexBuffer
        self.deletionPlaceholderBinBuffer = deletionPlaceholderBinBuffer
        waveformShaderBufferStore = WaveformShaderBufferStore(
            device: device,
            preferredSlabBinCapacity: 262_144
        )
        let isTiledWaveformPipelineEnabled = WaveformTiledRendererFeatureFlags.isEnabled
        tiledWaveformPipeline = isTiledWaveformPipelineEnabled ?
            WaveformTiledRenderPipeline() :
            nil
        tiledWaveformMetalBufferStore = isTiledWaveformPipelineEnabled ?
            WaveformTileMetalBufferStore(device: device) :
            nil
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        waveformPipelineState = try device.makeRenderPipelineState(descriptor: waveformDescriptor)
        rulerPipelineState = try device.makeRenderPipelineState(descriptor: rulerDescriptor)
        additivePipelineState = try device.makeRenderPipelineState(descriptor: additiveDescriptor)
        selectionOverlayPipelineState = try device.makeRenderPipelineState(descriptor: selectionOverlayDescriptor)
        loopRegionPipelineState = try device.makeRenderPipelineState(descriptor: loopRegionDescriptor)
        selectionDragEffectPipelineState = try device.makeRenderPipelineState(descriptor: selectionDragEffectDescriptor)
        deletionEffectPipelineState = try device.makeRenderPipelineState(descriptor: deletionEffectDescriptor)

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

    func displayTracks(
        _ tracks: [TimelineRenderState.Track],
        animateWaveformTransition: Bool = true,
        allowImmediateWaveformPrewarm: Bool = true,
        allowImmediateInteractiveWaveformPrewarm: Bool = true
    ) {
        let previousTracks = renderState.tracks
        let staleTiledSourceIDs = tiledWaveformPipeline?.registerSources(tracks.compactMap(\.waveformTileSource)) ?? []
        for sourceID in staleTiledSourceIDs {
            tiledWaveformMetalBufferStore?.removeAll(for: sourceID)
        }
        updateWaveformSourceTracks(from: tracks)
        let currentTracksByID = Dictionary(uniqueKeysWithValues: previousTracks.map { ($0.id, $0) })
        let renderTracks = tracks.map { lightweightRenderTrack(from: $0, currentTrack: currentTracksByID[$0.id]) }
        let nextRenderState = renderState.withTracks(renderTracks)
        let hasNextWaveforms = renderTracks.contains { $0.hasWaveform }
        let defersWaveformResolutionForDeletion =
            animateWaveformTransition && hasDeletionEffectsInFlight()
        var nextTrackWaveformMipLevels: [UUID: [WaveformMipLevel]] = [:]
        var nextTrackWaveformMipKeys: [UUID: WaveformMipCacheKey] = [:]
        if !defersWaveformResolutionForDeletion {
            for track in tracks {
                let sourceTrack = waveformSourceTrack(for: track)
                let mipLevels = cachedWaveformMipLevels(
                    for: sourceTrack,
                    priorityRenderState: nextRenderState
                )
                nextTrackWaveformMipLevels[track.id] = mipLevels
                if let key = waveformMipCacheKey(for: sourceTrack) {
                    nextTrackWaveformMipKeys[track.id] = key
                }
            }
        }
        let nextWaveformMipLevels = tracks.first.flatMap { nextTrackWaveformMipLevels[$0.id] } ?? []
        let previousTrackIDsInOrder = previousTracks.map(\.id)
        let nextTrackIDsInOrder = renderTracks.map(\.id)
        let previousTrackIDs = Set(previousTrackIDsInOrder)
        let nextTrackIDs = Set(renderTracks.map(\.id))
        let hasSharedTransitionTracks = !previousTrackIDs.isDisjoint(with: nextTrackIDs)
        let hasActiveDeletionEffects = hasDeletionEffectsInFlight()
        let canAnimateWaveformTransition =
            animateWaveformTransition &&
            !renderState.isPlaybackActive &&
            !nextRenderState.isPlaybackActive
        let canReuseResidentWaveformsForDeletion =
            hasActiveDeletionEffects &&
            previousTrackIDsInOrder == nextTrackIDsInOrder &&
            renderTracks.allSatisfy { nextTrack in
                guard let previousTrack = currentTracksByID[nextTrack.id] else {
                    return false
                }

                return previousTrack.waveformVersion == nextTrack.waveformVersion
            }
        let preservesEffectContinuity = previousTrackIDsInOrder == nextTrackIDsInOrder &&
            renderState.hasWaveforms &&
            hasNextWaveforms
        if canAnimateWaveformTransition, renderState.hasWaveforms, hasNextWaveforms, hasSharedTransitionTracks {
            waveformMipLevelStateLock.lock()
            previousTrackWaveformMipLevels = trackWaveformMipLevels
            waveformMipLevelStateLock.unlock()
            previousTransitionTracks = previousTracks
            previousTransitionViewport = renderState.viewport
            waveformGeometryStore.promoteCurrentToPrevious()
            waveformTransitionStartTime = nil
        } else {
            waveformMipLevelStateLock.lock()
            previousTrackWaveformMipLevels = [:]
            waveformMipLevelStateLock.unlock()
            previousTransitionTracks = []
            previousTransitionViewport = nil
            waveformGeometryStore.clearPrevious()
            waveformTransitionStartTime = nil
        }

        waveformMipLevelStateLock.lock()
        if canReuseResidentWaveformsForDeletion {
            let existingTrackWaveformMipLevels = trackWaveformMipLevels
            let existingTrackWaveformMipKeys = currentTrackWaveformMipKeys
            trackWaveformMipLevels = existingTrackWaveformMipLevels.filter { nextTrackIDs.contains($0.key) }
            currentTrackWaveformMipKeys = existingTrackWaveformMipKeys.filter { nextTrackIDs.contains($0.key) }
            waveformMipLevels = renderTracks.first.flatMap { trackWaveformMipLevels[$0.id] } ?? []
        } else {
            waveformMipLevels = nextWaveformMipLevels
            trackWaveformMipLevels = nextTrackWaveformMipLevels
            currentTrackWaveformMipKeys = nextTrackWaveformMipKeys
        }
        currentPrimaryWaveformTrackID = renderTracks.first?.id
        waveformMipLevelStateLock.unlock()
        lastInteractiveWaveformPrewarmKeys.removeAll()
        waveformShaderPrewarmGeneration += 1
        if allowImmediateWaveformPrewarm && !canReuseResidentWaveformsForDeletion && !defersWaveformResolutionForDeletion {
            prewarmInitialWaveformShaderBuffers(
                tracks: renderTracks,
                trackWaveformMipLevels: nextTrackWaveformMipLevels,
                renderState: nextRenderState,
                drawableSize: lastRenderViewportSize,
                backingScale: lastRenderBackingScale
            )
            if allowImmediateInteractiveWaveformPrewarm {
                prewarmInteractiveWaveformShaderBuffers(
                    tracks: renderTracks,
                    trackWaveformMipLevels: nextTrackWaveformMipLevels,
                    renderState: nextRenderState,
                    drawableSize: lastRenderViewportSize,
                    backingScale: lastRenderBackingScale
                )
            }
        }
        gridCache = nil
        if hasNextWaveforms {
            waveformGeometryStore.cancelCurrentPreparationKeepingCache()
        } else {
            waveformGeometryStore.clearCurrent()
        }
        if !preservesEffectContinuity {
            playheadContactEvents.removeAll()
            lastPlayheadContactEventTimestamp = nil
            transientParticles.removeAll()
            previousTransientScanProgress = nil
            lastTransientParticleBins.removeAll()
        }
        previousRenderedPlayheadX = nil
        previousRenderedPlayheadTime = nil
        resetTrackFisheyeAudibility(for: nextRenderState, at: CACurrentMediaTime())
        renderState = nextRenderState
    }

    func displayTrackMixSettings(_ tracks: [TimelineRenderState.Track]) {
        updateWaveformSourceTracks(from: tracks)
        let currentTracksByID = Dictionary(uniqueKeysWithValues: renderState.tracks.map { ($0.id, $0) })
        let renderTracks = tracks.map { lightweightRenderTrack(from: $0, currentTrack: currentTracksByID[$0.id]) }
        ensureWaveformMipLevelsExist(for: renderTracks)
        let nextRenderState = renderState.withTracks(renderTracks)
        updateTrackFisheyeAudibility(for: nextRenderState, at: CACurrentMediaTime())
        renderState = nextRenderState
    }

    private func lightweightRenderTrack(
        from track: TimelineRenderState.Track,
        currentTrack: TimelineRenderState.Track? = nil
    ) -> TimelineRenderState.Track {
        let sourceTrack = waveformSourceTracksByID[track.id]
        let sourceOverview = track.waveformOverview ?? sourceTrack?.waveformOverview
        let durationHint = track.durationHint ??
            sourceOverview?.duration ??
            currentTrack?.durationHint ??
            sourceTrack?.durationHint
        let hasWaveform =
            track.hasWaveform ||
            sourceOverview?.isEmpty == false ||
            currentTrack?.hasWaveform == true ||
            sourceTrack?.hasWaveform == true
        let waveformVersion = sourceOverview == nil ?
            (sourceTrack?.waveformVersion ?? currentTrack?.waveformVersion ?? track.waveformVersion) :
            track.waveformVersion
        let shouldPreserveCurrentSegments = track.waveformSegments.isEmpty &&
            track.waveformOverview == nil &&
            track.waveformTileSource == nil
        let waveformSegments = shouldPreserveCurrentSegments ?
            (currentTrack?.waveformSegments ?? sourceTrack?.waveformSegments ?? []) :
            track.waveformSegments
        return TimelineRenderState.Track(
            id: track.id,
            waveformVersion: waveformVersion,
            waveformOverview: nil,
            durationHint: durationHint,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            hasWaveform: hasWaveform,
            clipRanges: track.clipRanges.isEmpty ? (currentTrack?.clipRanges ?? []) : track.clipRanges,
            waveformSegments: waveformSegments,
            waveformTileSource: track.waveformTileSource ??
                currentTrack?.waveformTileSource ??
                sourceTrack?.waveformTileSource
        )
    }

    private func updateWaveformSourceTracks(from tracks: [TimelineRenderState.Track]) {
        let activeTrackIDs = Set(tracks.map(\.id))
        waveformSourceTracksByID = waveformSourceTracksByID.filter { activeTrackIDs.contains($0.key) }
        for track in tracks where track.waveformOverview?.isEmpty == false {
            waveformSourceTracksByID[track.id] = track
        }
    }

    private func waveformSourceTrack(for track: TimelineRenderState.Track) -> TimelineRenderState.Track {
        guard track.waveformOverview?.isEmpty != false, let sourceTrack = waveformSourceTracksByID[track.id] else {
            return track
        }

        return TimelineRenderState.Track(
            id: track.id,
            waveformVersion: sourceTrack.waveformVersion,
            waveformOverview: sourceTrack.waveformOverview,
            durationHint: track.durationHint ?? sourceTrack.durationHint,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            hasWaveform: sourceTrack.hasWaveform,
            clipRanges: track.clipRanges.isEmpty ? sourceTrack.clipRanges : track.clipRanges,
            waveformSegments: track.waveformSegments.isEmpty ? sourceTrack.waveformSegments : track.waveformSegments,
            waveformTileSource: track.waveformTileSource ?? sourceTrack.waveformTileSource
        )
    }

    private func waveformDrawableDurationHint(for track: TimelineRenderState.Track) -> TimeInterval? {
        let sourceTrack = waveformSourceTrack(for: track)
        if let sourceDuration = sourceTrack.waveformOverview?.duration,
           sourceDuration.isFinite,
           sourceDuration > 0 {
            return sourceDuration
        }

        if let cachedSourceDuration = waveformSourceTracksByID[track.id]?.waveformOverview?.duration,
           cachedSourceDuration.isFinite,
           cachedSourceDuration > 0 {
            return cachedSourceDuration
        }

        if let trackDuration = track.durationHint,
           trackDuration.isFinite,
           trackDuration > 0 {
            return trackDuration
        }

        return nil
    }

    private func ensureWaveformMipLevelsExist(for tracks: [TimelineRenderState.Track]) {
        var didChangeMipState = false
        var ensuredPrimaryLevels: [WaveformMipLevel]?
        waveformMipLevelStateLock.lock()
        var nextTrackWaveformMipLevels = trackWaveformMipLevels
        var nextTrackWaveformMipKeys = currentTrackWaveformMipKeys
        waveformMipLevelStateLock.unlock()

        for track in tracks where track.hasWaveform {
            guard nextTrackWaveformMipLevels[track.id]?.isEmpty != false else {
                continue
            }

            let sourceTrack = waveformSourceTrack(for: track)
            let mipLevels = cachedWaveformMipLevels(for: sourceTrack)
            guard !mipLevels.isEmpty else {
                continue
            }

            nextTrackWaveformMipLevels[track.id] = mipLevels
            if let key = waveformMipCacheKey(for: sourceTrack) {
                nextTrackWaveformMipKeys[track.id] = key
            }
            if ensuredPrimaryLevels == nil {
                ensuredPrimaryLevels = mipLevels
            }
            didChangeMipState = true
        }

        guard didChangeMipState else {
            return
        }

        waveformMipLevelStateLock.lock()
        trackWaveformMipLevels = nextTrackWaveformMipLevels
        currentTrackWaveformMipKeys = nextTrackWaveformMipKeys
        if waveformMipLevels.isEmpty, let ensuredPrimaryLevels {
            waveformMipLevels = ensuredPrimaryLevels
        }
        if currentPrimaryWaveformTrackID == nil {
            currentPrimaryWaveformTrackID = tracks.first(where: { $0.hasWaveform })?.id
        }
        waveformMipLevelStateLock.unlock()
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

    func updateSelectionDragWaveformTuning(_ tuning: SelectionDragWaveformTuning) {
        selectionDragWaveformTuning = tuning.sanitized
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

    func noteTimelineInteraction(at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        markWaveformHotInteraction(at: timestamp)
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
        markWaveformHotInteraction()
        interactionStateStore.publishViewport(viewport)
        commitViewport(viewport)
    }

    func commitViewport(_ viewport: TimelineViewport) {
        guard renderState.viewport != viewport else {
            return
        }

        markWaveformHotInteraction()
        gridCache = nil
        previousRenderedPlayheadX = nil
        previousRenderedPlayheadTime = nil
        renderState = renderState.withViewport(viewport)
        prewarmCurrentInteractiveWaveformShaderBuffers(
            drawableSize: lastRenderViewportSize,
            backingScale: lastRenderBackingScale
        )
    }

    func displayTrackLayout(_ trackLayout: TimelineTrackLayout) {
        guard renderState.trackLayout != trackLayout else {
            return
        }

        markWaveformHotInteraction()
        gridCache = nil
        renderState = renderState.withTrackLayout(trackLayout)
        prewarmCurrentInteractiveWaveformShaderBuffers(
            drawableSize: lastRenderViewportSize,
            backingScale: lastRenderBackingScale
        )
    }

    func displayHoverProgress(_ progress: Float?, isArmed: Bool = false) {
        markWaveformHotInteraction()
        interactionStateStore.publishHover(progress: progress, isArmed: isArmed)
        renderState = renderState.withHover(progress: progress, isArmed: isArmed)
    }

    func displayInteractionSuppressed(_ isSuppressed: Bool) {
        guard isSuppressed else {
            return
        }

        interactionStateStore.publishHover(progress: nil, isArmed: false)
        renderState = renderState.withHover(progress: nil, isArmed: false)
    }

    func displaySelection(_ selection: TimelineSelection?) {
        markWaveformHotInteraction()
        interactionStateStore.publishSelection(selection)
        let tuning = selectionDragWaveformTuning
        interactionStateStore.publishSelectionDragSnapshot(
            nil,
            contact: nil,
            displayTimestamp: CACurrentMediaTime(),
            lifetime: tuning.contactLifetime,
            maximumCount: tuning.maximumContactCount
        )
        renderState = renderState.withSelection(selection)
    }

    func displayProcessingSelectionProgress(selection: TimelineSelection?, fractionCompleted: Float?) {
        guard
            let selection,
            selection.durationProgress > 0
        else {
            processingSelectionProgress = nil
            return
        }

        let now = CACurrentMediaTime()
        let clampedFraction = fractionCompleted.map { min(max($0, 0), 1) }
        let startFraction: Float?
        let pulseStartTimestamp: CFTimeInterval
        if let existing = processingSelectionProgress, existing.selection == selection {
            startFraction = interpolatedProcessingSelectionFraction(existing, at: now)
            pulseStartTimestamp = existing.pulseStartTimestamp
        } else {
            startFraction = clampedFraction.map { _ in 0 }
            pulseStartTimestamp = now
        }

        processingSelectionProgress = ProcessingSelectionProgress(
            selection: selection,
            startFraction: startFraction,
            targetFraction: clampedFraction,
            transitionStartTimestamp: now,
            pulseStartTimestamp: pulseStartTimestamp
        )
        if renderState.selection != selection {
            renderState = renderState.withSelection(selection)
        }
    }

    func triggerSelectionCopyFlash(at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard renderState.selection?.durationProgress ?? 0 > 0 else {
            return
        }

        markWaveformHotInteraction(at: timestamp)
        selectionCopyFlashStartTime = timestamp
    }

    func displayModalBackdropActive(_ isActive: Bool) {
        guard isModalBackdropActive != isActive else {
            return
        }

        isModalBackdropActive = isActive
        previousRenderedPlayheadX = nil
        previousRenderedPlayheadTime = nil
        if isActive {
            playheadContactEvents.removeAll()
        }
    }

    func publishInteractionSelection(_ selection: TimelineSelection?) {
        markWaveformHotInteraction()
        interactionStateStore.publishSelection(selection)
    }

    func publishInteractionSelectionDragSnapshot(_ snapshot: TimelineSelectionDragSnapshot?) {
        let timestamp = snapshot?.timestamp ?? CACurrentMediaTime()
        guard
            let snapshot,
            snapshot.selection.durationProgress > 0
        else {
            let tuning = selectionDragWaveformTuning
            interactionStateStore.publishSelectionDragSnapshot(
                nil,
                contact: nil,
                displayTimestamp: timestamp,
                lifetime: tuning.contactLifetime,
                maximumCount: tuning.maximumContactCount
            )
            return
        }

        interactionStateStore.publishSelection(snapshot.selection)
        let tuning = selectionDragWaveformTuning
        let contactStrength = selectionDragStrength(for: snapshot.velocityPixelsPerSecond)
        let contact: SelectionDragWaveformContact?
        if
            snapshot.direction != 0,
            contactStrength > selectionDragWaveformContactMinimumStrength
        {
            contact = SelectionDragWaveformContact(
                trackID: snapshot.selection.trackID,
                progress: snapshot.leadingProgress,
                direction: snapshot.direction,
                strength: min(max(contactStrength, 0), 1),
                birthTimestamp: timestamp
            )
        } else {
            contact = nil
        }
        interactionStateStore.publishSelectionDragSnapshot(
            snapshot,
            contact: contact,
            displayTimestamp: timestamp,
            lifetime: tuning.contactLifetime,
            maximumCount: tuning.maximumContactCount
        )
    }

    func publishInteractionHover(progress: Float?, isArmed: Bool = false) {
        markWaveformHotInteraction()
        interactionStateStore.publishHover(progress: progress, isArmed: isArmed)
    }

    func publishInteractionViewport(_ viewport: TimelineViewport) {
        markWaveformHotInteraction()
        interactionStateStore.publishViewport(viewport)
    }

    func displaySelectedTrack(_ trackID: UUID?) {
        renderState = renderState.withSelectedTrackID(trackID)
    }

    func displaySelectedTracks(_ trackIDs: Set<UUID>, primaryTrackID: UUID?) {
        renderState = renderState.withSelectedTrackIDs(trackIDs, primaryTrackID: primaryTrackID)
    }

    func displayTrimPreview(_ trimPreview: TimelineTrimRange?) {
        markWaveformHotInteraction()
        renderState = renderState.withTrimPreview(trimPreview)
    }

    func displayLoopRange(_ loopRange: TimelineLoopRange) {
        guard self.loopRange != loopRange else {
            return
        }

        markWaveformHotInteraction()
        self.loopRange = loopRange
    }

    func displayLoopRangeEnabled(_ isEnabled: Bool) {
        guard isLoopRangeEnabled != isEnabled else {
            return
        }

        markWaveformHotInteraction()
        isLoopRangeEnabled = isEnabled
    }

    func displayHighlightedLoopEndpoint(_ endpoint: TimelineLoopEndpoint?) {
        guard highlightedLoopEndpoint != endpoint else {
            return
        }

        highlightedLoopEndpoint = endpoint
    }

    func displayHighlightedLoopRegion(_ isHighlighted: Bool) {
        guard isLoopRegionHighlighted != isHighlighted else {
            return
        }

        isLoopRegionHighlighted = isHighlighted
    }

    func triggerLoopRangeFlash(at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard isLoopRangeEnabled, loopRange.durationProgress > 0.0001, loopRange.durationProgress < 0.999 else {
            return
        }

        markWaveformHotInteraction()
        loopRangeFlashStartTime = timestamp
    }

    func displayGainPreview(selection: TimelineSelection?, gain: Float) {
        markWaveformHotInteraction()
        let gainPreview: TimelineRenderState.GainPreview?
        if let selection, selection.durationProgress > 0 {
            gainPreview = TimelineRenderState.GainPreview(selection: selection, gain: max(gain, 0))
        } else {
            gainPreview = nil
        }
        renderState = renderState.withGainPreview(gainPreview)
    }

    func displayCandidateRegions(_ candidateRegions: [TimelineRenderState.CandidateRegion]) {
        renderState = renderState.withCandidateRegions(candidateRegions)
    }

    func displayProcessingTrackHighlight(trackID: UUID?, alpha: Float) {
        let highlight = trackID.map {
            TimelineRenderState.ProcessingTrackHighlight(trackID: $0, alpha: alpha)
        }
        renderState = renderState.withProcessingTrackHighlight(highlight)
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

        return SIMD4<Float>(left, right, right, 0)
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
        let effect = DeletionEffect(
            selection: selection,
            visualAnchor: visualAnchor,
            capturedBinBuffer: deletionPlaceholderBinBuffer,
            capturedBinCount: 1,
            capturedEnergySamples: [],
            birthTimestamp: -1,
            seed: seed,
            kind: .deletion
        )

        deletionEffectLock.lock()
        deletionEffects.append(effect)
        if deletionEffects.count > deletionEffectMaximumCount {
            deletionEffects.removeFirst(deletionEffects.count - deletionEffectMaximumCount)
        }
        deletionEffectLock.unlock()
    }

    func triggerPasteEffect(
        selection: TimelineSelection,
        waveformOverview: WaveformOverview?,
        at timestamp: CFTimeInterval = CACurrentMediaTime()
    ) {
        guard selection.durationProgress > 0 else {
            return
        }

        var seed = UInt64(bitPattern: Int64(selection.trackID?.hashValue ?? 0))
        seed &+= UInt64((selection.startProgress * 1_000_000).rounded(.down))
        seed &*= 0xD6E8_FD9D_50B9_1D35
        seed &+= UInt64((selection.endProgress * 1_000_000).rounded(.down))
        let visualAnchor = deletionEffectVisualAnchor(
            for: selection,
            displayTimestamp: timestamp
        )
        let capturedBins: [WaveformOverview.Bin]
        if let waveformOverview {
            capturedBins = capturedDeletionBins(
                in: waveformOverview,
                startProgress: 0,
                endProgress: 1,
                maximumBinCount: deletionEffectMaximumCapturedBins
            )
        } else {
            capturedBins = []
        }
        let capturedBinBuffer = makeDeletionWaveformBinBuffer(from: capturedBins)
        let effect = DeletionEffect(
            selection: selection,
            visualAnchor: visualAnchor,
            capturedBinBuffer: capturedBinBuffer ?? deletionPlaceholderBinBuffer,
            capturedBinCount: max(capturedBins.count, 1),
            capturedEnergySamples: deletionWallEnergySamples(from: capturedBins),
            birthTimestamp: -1,
            seed: seed,
            kind: .insertion
        )

        deletionEffectLock.lock()
        deletionEffects.append(effect)
        if deletionEffects.count > deletionEffectMaximumCount {
            deletionEffects.removeFirst(deletionEffects.count - deletionEffectMaximumCount)
        }
        deletionEffectLock.unlock()
        markWaveformHotInteraction(at: timestamp)
    }

    func clearDeletionEffects() {
        deletionEffectLock.lock()
        let hadEffects = !deletionEffects.isEmpty
        deletionEffects.removeAll()
        if hadEffects {
            lastDeletionEffectsClearedTimestamp = CACurrentMediaTime()
        }
        frameStatsDeletionEffectCount = 0
        deletionEffectLock.unlock()
    }

    func activeDeletionEffectCountForPerformanceTest() -> Int {
        deletionEffectLock.lock()
        let count = deletionEffects.count
        deletionEffectLock.unlock()
        return count
    }

    func triggerTransientParticlesForPerformanceTest(
        originProgress: Float,
        displayTimestamp: CFTimeInterval
    ) {
        let clampedProgress = min(max(originProgress, 0), 1)
        let seed = UInt64(clampedProgress.bitPattern) &* 0x9E37_79B9_7F4A_7C15
        spawnTransientParticleBurst(
            originProgress: clampedProgress,
            originY: 0.42,
            isTopEdge: true,
            strength: 0.88,
            seed: seed,
            birthTimestamp: displayTimestamp
        )
        spawnTransientParticleBurst(
            originProgress: clampedProgress,
            originY: 0.58,
            isTopEdge: false,
            strength: 0.88,
            seed: seed &+ 0xBF58_476D_1CE4_E5B9,
            birthTimestamp: displayTimestamp
        )
        if transientParticles.count > transientParticleMaximumCount {
            transientParticles.removeFirst(transientParticles.count - transientParticleMaximumCount)
        }
        frameStatsTransientParticleCount = transientParticles.count
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

    private func deletionWallEnergySamples(from bins: [WaveformOverview.Bin]) -> [Float] {
        bins.map { bin in
            let peak = max(abs(bin.minimumSample), abs(bin.maximumSample))
            let energy = min(max(peak * 0.82 + bin.rmsSample * 0.72, 0), 1)
            return smoothStep(edge0: 0.012, edge1: 0.38, value: energy)
        }
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
        lastRenderViewportSize = target.viewportSize
        lastRenderBackingScale = target.backingScale
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
            displayTimestamp: target.displayTimestamp,
            publishesFrameStats: target.publishesFrameStats
        )
        encoder.endEncoding()

        commandBuffer.present(target.drawable)
        PerformanceSampler.shared.recordTimelineFramePresented()
        commandBuffer.addCompletedHandler { _ in
            PerformanceSampler.shared.recordTimelineFrameCompleted()
        }
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
        lastRenderViewportSize = viewportSize
        lastRenderBackingScale = backingScale
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
            displayTimestamp: displayTimestamp,
            publishesFrameStats: true
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
        displayTimestamp: CFTimeInterval,
        publishesFrameStats: Bool
    ) {
        resetFrameDiagnosticsForNextFrame()
        let renderState = interactionStateStore.applying(to: renderStateStore.snapshot())
        let selectionDragSnapshot = interactionStateStore.currentSelectionDragSnapshot()
        let selectionDragTuning = selectionDragWaveformTuning
        let selectionDragWaveformContacts = interactionStateStore.selectionDragWaveformContactsSnapshot(
            displayTimestamp: displayTimestamp,
            lifetime: selectionDragTuning.contactLifetime,
            maximumCount: selectionDragTuning.maximumContactCount
        )
        let isSelectionDragFrame = isSelectionDragEffectActive(
            selectionDragSnapshot,
            displayTimestamp: displayTimestamp
        ) || !selectionDragWaveformContacts.isEmpty
        if isSelectionDragFrame {
            markWaveformHotInteraction(at: displayTimestamp)
        }
        if !isSelectionDragFrame {
            promoteReadyPendingWaveformMipLevelPublications(
                renderState: renderState,
                drawableSize: viewportSize,
                backingScale: backingScale
            )
        }
        let mipLevelSnapshot = waveformMipLevelSnapshot()
        let renderedPlayheadProgress = currentPlayheadProgress(
            renderState: renderState,
            displayTimestamp: displayTimestamp
        )
        updateTrackFisheyeAudibility(for: renderState, at: displayTimestamp)
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
        let deletionEffectsForFrame = activeDeletionEffects(at: displayTimestamp)
        let hasActiveDeletionEffect = !deletionEffectsForFrame.isEmpty
        let selectedTrackVertices = makeSelectedTrackVertices(
            drawableSize: viewportSize,
            renderState: renderState
        )
        let processingTrackVertices = makeProcessingTrackHighlightVertices(
            drawableSize: viewportSize,
            renderState: renderState
        )
        let selectionOverlayUniform = makeSelectionOverlayUniform(
            drawableSize: viewportSize,
            renderState: renderState,
            displayTimestamp: displayTimestamp,
            fisheye: selectionFisheye,
            dragSnapshot: selectionDragSnapshot
        )
        let selectionDragEffectUniform = makeSelectionDragEffectUniform(
            snapshot: selectionDragSnapshot,
            drawableSize: viewportSize,
            renderState: renderState,
            displayTimestamp: displayTimestamp
        )
        let candidateRegionVertices = makeCandidateRegionVertices(
            drawableSize: viewportSize,
            renderState: renderState
        )
        let clipBoundaryVertices = makeClipBoundaryVertices(
            drawableSize: viewportSize,
            backingScale: backingScale,
            renderState: renderState
        )
        let canUseWaveformShader = shouldRenderShaderWaveforms(
            drawableSize: viewportSize,
            renderState: renderState
        )
        updateGPUResidentWaveformShadowFrameStats(
            renderState: renderState,
            drawableSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: displayTimestamp
        )
        let existingWaveformTransition = hasPreviousWaveformTransition
        if renderState.isPlaybackActive, existingWaveformTransition {
            clearPreviousWaveformTransition()
        }
        let hasWaveformTransition = !renderState.isPlaybackActive && existingWaveformTransition
        let waveformHotPathReason = waveformPerformanceContractHotPathReason(
            renderState: renderState,
            hasActiveDeletionEffect: hasActiveDeletionEffect,
            isSelectionDragFrame: isSelectionDragFrame,
            hasWaveformTransition: hasWaveformTransition,
            displayTimestamp: displayTimestamp
        )
        frameStatsWaveformHotPathReason = waveformHotPathReason ?? ""
        let isWaveformHotPath = waveformHotPathReason != nil
        let hoverNeedsInitialPrewarm =
            waveformHotPathReason == "hover" &&
            canUseWaveformShader &&
            !shaderWaveformsAreDrawable(
                drawableSize: viewportSize,
                backingScale: backingScale,
                renderState: renderState,
                trackWaveformMipLevels: mipLevelSnapshot.currentByTrack,
                fallbackPolicy: .allowFallbacks
            )
        if waveformHotPathReason == nil ||
            waveformHotPathReason == "viewport-interaction" ||
            hoverNeedsInitialPrewarm {
            prewarmCurrentInteractiveWaveformShaderBuffers(
                drawableSize: viewportSize,
                backingScale: backingScale
            )
        }
        flushDeferredWaveformShaderBinPublishesIfAllowed(
            renderState: renderState,
            drawableSize: viewportSize,
            backingScale: backingScale,
            trackWaveformMipLevels: mipLevelSnapshot.currentByTrack,
            displayTimestamp: displayTimestamp,
            waveformHotPathReason: waveformHotPathReason
        )
        let allowsCPUWaveformFallback =
            !isWaveformHotPath &&
            isColdStaticCPUWaveformFallbackAllowed(
                renderState: renderState,
                hasWaveformTransition: hasWaveformTransition,
                displayTimestamp: displayTimestamp
            )
        let previousShaderRenderState = hasWaveformTransition ?
            previousTransitionRenderState(
                withCurrentState: renderState,
                displayTimestamp: displayTimestamp,
                followsLiveViewport: !hasActiveDeletionEffect
            ) :
            nil
        let canUsePreviousWaveformShader = previousShaderRenderState.map {
            shouldRenderShaderWaveforms(
                drawableSize: viewportSize,
                renderState: $0
            )
        } ?? false
        let usesPreviousWaveformShader = previousShaderRenderState.map { previousRenderState in
            canUsePreviousWaveformShader && shaderWaveformsAreDrawable(
                drawableSize: viewportSize,
                backingScale: backingScale,
                renderState: previousRenderState,
                trackWaveformMipLevels: mipLevelSnapshot.previousByTrack,
                fallbackPolicy: .allowFallbacks
            )
        } ?? false
        let canUsePreviousCPUWaveform = allowsCPUWaveformFallback
        let previousWaveformVertices = hasWaveformTransition && !usesPreviousWaveformShader && canUsePreviousCPUWaveform ?
            cachedPreviousWaveformVertices(
                drawableSize: viewportSize,
                renderState: renderState,
                mipLevelSnapshot: mipLevelSnapshot,
                displayTimestamp: displayTimestamp,
                followsLiveViewport: !hasActiveDeletionEffect,
                allowsPreparation: !hasActiveDeletionEffect
            ) :
            nil
        let canHoldPreviousWaveform =
            hasWaveformTransition &&
            (usesPreviousWaveformShader || previousWaveformVertices != nil)
        let currentWaveformFallbackPolicy: WaveformShaderFallbackPolicy =
            canHoldPreviousWaveform ? .preferredOnly : .allowFallbacks
        let usesWaveformShader = canUseWaveformShader && shaderWaveformsAreDrawable(
            drawableSize: viewportSize,
            backingScale: backingScale,
            renderState: renderState,
            trackWaveformMipLevels: mipLevelSnapshot.currentByTrack,
            fallbackPolicy: currentWaveformFallbackPolicy
        )
        let waveformTouchParameters = (usesWaveformShader || usesPreviousWaveformShader) ?
            makeWaveformTouchShaderParameters(
                renderState: renderState,
                playheadProgress: renderedPlayheadProgress,
                displayTimestamp: displayTimestamp
            ) :
            emptyWaveformTouchShaderParameters()
        let isHoldingPreviousUntilPreferredWaveformIsReady =
            canHoldPreviousWaveform &&
            canUseWaveformShader &&
            !usesWaveformShader
        if isHoldingPreviousUntilPreferredWaveformIsReady {
            frameStatsWaveformLastGoodHoldCount += 1
            frameStatsWaveformResidentMissCount += 1
        } else if canUseWaveformShader && !usesWaveformShader {
            frameStatsWaveformResidentMissCount += 1
        }
        let waveformVertices = usesWaveformShader || isHoldingPreviousUntilPreferredWaveformIsReady ?
            nil :
            allowsCPUWaveformFallback ? cachedWaveformVertices(
                drawableSize: viewportSize,
                renderState: renderState,
                mipLevelSnapshot: mipLevelSnapshot
            ) : nil
        let currentShaderWaveformsReady = usesWaveformShader
        let waveformTransitionOpacities = waveformTransitionOpacities(
            at: displayTimestamp,
            hasCurrent: currentShaderWaveformsReady || waveformVertices != nil,
            hasPrevious: usesPreviousWaveformShader || previousWaveformVertices != nil,
            holdsPreviousForDeletion: hasActiveDeletionEffect
        )
        let suppressCurrentWaveformForDeletion =
            hasActiveDeletionEffect &&
            (usesPreviousWaveformShader || previousWaveformVertices != nil)
        let rulerLaneVertices = makeRulerLaneVertices(
            drawableSize: viewportSize,
            backingScale: backingScale,
            renderState: renderState
        )
        let loopRangeUniform = makeLoopRangeUniform(
            drawableSize: viewportSize,
            backingScale: backingScale,
            renderState: renderState,
            displayTimestamp: displayTimestamp
        )
        let trimPreviewVertices = makeTrimPreviewVertices(
            drawableSize: viewportSize,
            backingScale: backingScale,
            renderState: renderState
        )
        let playheadTouchVertices = usesWaveformShader || !allowsCPUWaveformFallback ? [] :
            makePlayheadTouchVertices(
                drawableSize: viewportSize,
                playheadProgress: renderedPlayheadProgress,
                renderState: renderState,
                mipLevelSnapshot: mipLevelSnapshot,
                displayTimestamp: displayTimestamp
            )
        if !isSelectionDragFrame {
            updateTransientParticles(
                drawableSize: viewportSize,
                playheadProgress: renderedPlayheadProgress,
                renderState: renderState,
                mipLevelSnapshot: mipLevelSnapshot,
                displayTimestamp: displayTimestamp
            )
        }
        let transientParticleVertices = makeTransientParticleVertices(
            drawableSize: viewportSize,
            renderState: renderState,
            displayTimestamp: displayTimestamp,
            maximumVertexCount: maximumTransientParticleVerticesPerFrame
        )
        frameStatsEffectVertexCount += transientParticleVertices.count
        frameStatsEffectVertexCount += selectionDragEffectUniform == nil ? 0 : 6
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
        draw(vertices: rulerLaneVertices, primitiveType: .triangle, encoder: encoder)
        drawTimelineRulerTicks(
            drawableSize: viewportSize,
            backingScale: backingScale,
            renderState: renderState,
            encoder: encoder
        )
        drawLoopRange(uniform: loopRangeUniform, encoder: encoder)
        encoder.setRenderPipelineState(pipelineState)
        draw(vertices: selectedTrackVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: processingTrackVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: candidateRegionVertices, primitiveType: .triangle, encoder: encoder)
        drawSelectionOverlay(uniform: selectionOverlayUniform, encoder: encoder)
        encoder.setRenderPipelineState(pipelineState)
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
                selectionDragWaveformContacts: selectionDragWaveformContacts,
                deletionWarpEffects: deletionEffectsForFrame,
                encoder: encoder
            )
            encoder.setRenderPipelineState(pipelineState)
        } else if let previousWaveformVertices {
            frameStatsWaveformRenderer = "cpu"
            frameStatsCPUWaveformVertexCount += previousWaveformVertices.vertices.vertexCount
            frameStatsCPUWaveformFallbackDrawCount += 1
            frameStatsWaveformFallbackDrawCount += 1
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
        if usesWaveformShader && !suppressCurrentWaveformForDeletion {
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
                fallbackPolicy: currentWaveformFallbackPolicy,
                selectionDragWaveformContacts: selectionDragWaveformContacts,
                deletionWarpEffects: deletionEffectsForFrame,
                encoder: encoder
            )
            encoder.setRenderPipelineState(pipelineState)
        } else if let waveformVertices, !suppressCurrentWaveformForDeletion {
            frameStatsWaveformRenderer = "cpu"
            frameStatsCPUWaveformVertexCount += waveformVertices.vertices.vertexCount
            frameStatsCPUWaveformFallbackDrawCount += 1
            frameStatsWaveformFallbackDrawCount += 1
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
        if selectionDragEffectUniform != nil {
            drawSelectionDragEffect(uniform: selectionDragEffectUniform, encoder: encoder)
        }
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
            effects: deletionEffectsForFrame,
            encoder: encoder
        )
        encoder.setRenderPipelineState(pipelineState)
        draw(vertices: clipBoundaryVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: trimPreviewVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: hoverGuideVertices, primitiveType: .triangle, encoder: encoder)
        draw(vertices: playheadVertices, primitiveType: .triangle, encoder: encoder)
        recordWaveformPerformanceContract(
            hotPathReason: waveformHotPathReason,
            displayTimestamp: displayTimestamp
        )
        if publishesFrameStats {
            recordFrameRate()
        }
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

        return renderState.hasWaveforms
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
        selectionDragWaveformContacts: [SelectionDragWaveformContact],
        deletionWarpEffects: [DeletionEffect] = [],
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
        let anySolo = renderState.hasSoloedTrack
        let style = waveformVisualStyle(renderState: renderState, projectDuration: projectDuration)
        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        var visiblePromotedTrackIDs = Set<UUID>()
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
                trackDuration > 0
            else {
                continue
            }

            let shaderDrawable: WaveformShaderDrawable?
            if let mipLevels = trackWaveformMipLevels[track.id] {
                shaderDrawable = waveformShaderDrawable(
                    track: track,
                    mipLevels: mipLevels,
                    drawableSize: drawableSize,
                    backingScale: backingScale,
                    renderState: renderState,
                    fallbackPolicy: fallbackPolicy
                )
            } else {
                shaderDrawable = nil
            }
            if let shaderDrawable, !shaderDrawable.isPreferred {
                frameStatsWaveformResidentMissCount += 1
                frameStatsWaveformFallbackDrawCount += 1
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
            let selectionDragTuningVectors = selectionDragWaveformTuningVectors(
                drawableSize: drawableSize,
                renderState: renderState
            )
            let selectionDragContacts = selectionDragWaveformContactVectors(
                selectionDragWaveformContacts,
                trackID: track.id,
                displayTimestamp: displayTimestamp
            )
            let trackSelectionDragTuning = SIMD4<Float>(
                selectionDragTuningVectors.primary.x,
                selectionDragTuningVectors.primary.y,
                selectionDragTuningVectors.primary.z,
                Float(selectionDragContacts.activeCount)
            )
            var trackSelectionDragVisuals = selectionDragTuningVectors.secondary
            if let dragBounds = selectionDragWaveformEffectBounds(
                selection: renderState.selection,
                contacts: selectionDragWaveformContacts,
                trackID: track.id,
                drawableSize: drawableSize,
                renderState: renderState,
                displayTimestamp: displayTimestamp
            ) {
                trackSelectionDragVisuals.z = dragBounds.x
                trackSelectionDragVisuals.w = dragBounds.y
            } else {
                trackSelectionDragVisuals.z = 1
                trackSelectionDragVisuals.w = 0
            }
            let trackFisheye = fisheye.w > 0.000_1 ?
                scaledWaveformFisheye(
                    fisheye,
                    by: trackFisheyeEnergy(for: track.id, at: displayTimestamp)
                ) :
                .zero
            let promotionLayers = promotedWaveformShaderLayers(
                track: track,
                candidate: shaderDrawable,
                displayTimestamp: displayTimestamp
            )
            guard !promotionLayers.isEmpty else {
                continue
            }
            visiblePromotedTrackIDs.insert(track.id)

            for layer in promotionLayers {
                let layerAlpha = trackAlpha * layer.alpha
                guard layerAlpha > 0.001 else {
                    continue
                }
                let uniform = makeWaveformShaderUniform(
                    laneTop: laneTop,
                    laneBottom: laneBottom,
                    centerY: centerY,
                    amplitudeHeight: amplitudeHeight,
                    binCount: layer.drawable.mipLevel.binCount,
                    binOffset: layer.drawable.binOffset,
                    trackDurationProgress: trackDurationProgress,
                    baseGray: gray,
                    alpha: layerAlpha,
                    style: style,
                    drawableSize: drawableSize,
                    backingScale: backingScale,
                    fisheye: trackFisheye,
                    touch: trackTouch,
                    touch2: touchParameters.touch2,
                    touch3: touchParameters.touch3,
                    selectionDrag: trackSelectionDragTuning,
                    selectionDrag2: trackSelectionDragVisuals,
                    selectionDragContacts: selectionDragContacts,
                    deletionWarp: waveformDeletionWarp(
                        for: track,
                        effects: deletionWarpEffects,
                        displayTimestamp: displayTimestamp
                    ),
                    segment: nil,
                    trackID: track.id,
                    renderState: renderState
                )
                if track.waveformSegments.isEmpty {
                    appendWaveformShaderBatchUniform(uniform, buffer: layer.drawable.buffer)
                } else {
                    for segment in track.waveformSegments {
                        let segmentUniform = makeWaveformShaderUniform(
                            laneTop: laneTop,
                            laneBottom: laneBottom,
                            centerY: centerY,
                            amplitudeHeight: amplitudeHeight,
                            binCount: layer.drawable.mipLevel.binCount,
                            binOffset: layer.drawable.binOffset,
                            trackDurationProgress: trackDurationProgress,
                            baseGray: gray,
                            alpha: layerAlpha,
                            style: style,
                            drawableSize: drawableSize,
                            backingScale: backingScale,
                            fisheye: trackFisheye,
                            touch: trackTouch,
                            touch2: touchParameters.touch2,
                            touch3: touchParameters.touch3,
                            selectionDrag: trackSelectionDragTuning,
                            selectionDrag2: trackSelectionDragVisuals,
                            selectionDragContacts: selectionDragContacts,
                            deletionWarp: waveformDeletionWarp(
                                for: track,
                                effects: deletionWarpEffects,
                                displayTimestamp: displayTimestamp
                            ),
                            segment: segment,
                            trackID: track.id,
                            renderState: renderState
                        )
                        appendWaveformShaderBatchUniform(segmentUniform, buffer: layer.drawable.buffer)
                    }
                }
            }
        }

        trimWaveformShaderPromotionRecords(keeping: visiblePromotedTrackIDs)

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

    private func appendWaveformShaderBatchUniform(
        _ uniform: WaveformShaderUniform,
        buffer: MTLBuffer
    ) {
        let batchKey = ObjectIdentifier(buffer)
        if let batchIndex = waveformShaderBatchScratch.firstIndex(where: { $0.key == batchKey }) {
            waveformShaderBatchScratch[batchIndex].uniforms.append(uniform)
            return
        }

        var batch = WaveformShaderBatch(
            key: batchKey,
            buffer: buffer,
            uniforms: []
        )
        batch.uniforms.reserveCapacity(8)
        batch.uniforms.append(uniform)
        waveformShaderBatchScratch.append(batch)
    }

    private func promotedWaveformShaderLayers(
        track: TimelineRenderState.Track,
        candidate: WaveformShaderDrawable?,
        displayTimestamp: CFTimeInterval
    ) -> [WaveformShaderPromotionLayer] {
        guard let candidate else {
            if
                let existing = waveformShaderPromotionRecordsByTrackID[track.id],
                waveformShaderPromotionRecordCanBeHeld(existing, for: track)
            {
                frameStatsWaveformLastGoodHoldCount += 1
                frameStatsWaveformResidentMissCount += 1
                return activeWaveformShaderPromotionLayers(
                    from: existing,
                    displayTimestamp: displayTimestamp
                )
            }
            frameStatsWaveformResidentMissCount += 1
            return []
        }

        if
            !candidate.isPreferred,
            let existing = waveformShaderPromotionRecordsByTrackID[track.id],
            waveformShaderPromotionRecordCanBeHeld(existing, for: track)
        {
            frameStatsWaveformLastGoodHoldCount += 1
            return activeWaveformShaderPromotionLayers(
                from: existing,
                displayTimestamp: displayTimestamp
            )
        }

        if
            deletionHandoffWaveformDemotionProtectionIsActive(at: displayTimestamp),
            let existing = waveformShaderPromotionRecordsByTrackID[track.id],
            waveformShaderPromotionRecordCanBeHeld(existing, for: track),
            existing.current.mipLevel.binCount > candidate.mipLevel.binCount
        {
            frameStatsWaveformLastGoodHoldCount += 1
            return activeWaveformShaderPromotionLayers(
                from: existing,
                displayTimestamp: displayTimestamp
            )
        }

        if var existing = waveformShaderPromotionRecordsByTrackID[track.id],
           existing.waveformVersion == track.waveformVersion {
            if waveformShaderDrawableIdentity(existing.current) == waveformShaderDrawableIdentity(candidate) {
                existing.current = candidate
                waveformShaderPromotionRecordsByTrackID[track.id] = existing
                return activeWaveformShaderPromotionLayers(
                    from: existing,
                    displayTimestamp: displayTimestamp
                )
            }

            let previous = activePreviousWaveformShaderDrawable(
                from: existing
            )
            let nextRecord = WaveformShaderPromotionRecord(
                waveformVersion: track.waveformVersion,
                current: candidate,
                previous: previous,
                startedAt: displayTimestamp
            )
            waveformShaderPromotionRecordsByTrackID[track.id] = nextRecord
            return activeWaveformShaderPromotionLayers(
                from: nextRecord,
                displayTimestamp: displayTimestamp
            )
        }

        let record = WaveformShaderPromotionRecord(
            waveformVersion: track.waveformVersion,
            current: candidate,
            previous: nil,
            startedAt: displayTimestamp
        )
        waveformShaderPromotionRecordsByTrackID[track.id] = record
        return [WaveformShaderPromotionLayer(drawable: candidate, alpha: 1)]
    }

    private func waveformShaderPromotionRecordCanBeHeld(
        _ record: WaveformShaderPromotionRecord,
        for track: TimelineRenderState.Track
    ) -> Bool {
        guard let durationHint = waveformDrawableDurationHint(for: track) else {
            return true
        }

        let drawableDuration = record.current.mipLevel.overview.duration
        guard drawableDuration.isFinite, drawableDuration > 0 else {
            return false
        }

        return abs(drawableDuration - durationHint) <= max(0.001, durationHint * 0.000_1)
    }

    private func activeWaveformShaderPromotionLayers(
        from record: WaveformShaderPromotionRecord,
        displayTimestamp: CFTimeInterval
    ) -> [WaveformShaderPromotionLayer] {
        guard let previous = record.previous else {
            return [WaveformShaderPromotionLayer(drawable: record.current, alpha: 1)]
        }

        let progress = waveformShaderPromotionProgress(record: record, displayTimestamp: displayTimestamp)
        if progress >= 0.999 {
            return [WaveformShaderPromotionLayer(drawable: record.current, alpha: 1)]
        }

        return [
            WaveformShaderPromotionLayer(drawable: previous, alpha: 1 - progress),
            WaveformShaderPromotionLayer(drawable: record.current, alpha: progress),
        ]
    }

    private func activePreviousWaveformShaderDrawable(
        from record: WaveformShaderPromotionRecord
    ) -> WaveformShaderDrawable {
        return record.current
    }

    private func waveformShaderPromotionProgress(
        record: WaveformShaderPromotionRecord,
        displayTimestamp: CFTimeInterval
    ) -> Float {
        let rawProgress = (displayTimestamp - record.startedAt) / waveformShaderPromotionDuration
        let clamped = min(max(Float(rawProgress), 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func waveformShaderDrawableIdentity(_ drawable: WaveformShaderDrawable) -> String {
        "\(ObjectIdentifier(drawable.buffer)):\(drawable.binOffset):\(drawable.mipLevel.binCount)"
    }

    private func trimWaveformShaderPromotionRecords(keeping visibleTrackIDs: Set<UUID>) {
        guard !visibleTrackIDs.isEmpty else {
            waveformShaderPromotionRecordsByTrackID.removeAll()
            return
        }
        waveformShaderPromotionRecordsByTrackID = waveformShaderPromotionRecordsByTrackID.filter { trackID, _ in
            visibleTrackIDs.contains(trackID)
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
        selectionDrag: SIMD4<Float>,
        selectionDrag2: SIMD4<Float>,
        selectionDragContacts: SelectionDragWaveformContactVectors,
        deletionWarp: SIMD4<Float> = .zero,
        segment: TimelineRenderState.Track.WaveformSegment?,
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
        let sampleSmoothing = waveformSampleSmoothingAmount(
            drawableSize: drawableSize,
            backingScale: backingScale,
            binCount: binCount,
            trackDurationProgress: trackDurationProgress,
            renderState: renderState
        )
        let commonTrack = SIMD4<Float>(
            trackDurationProgress,
            Float(max(binCount, 1)),
            Float(max(binOffset, 0)),
            sampleSmoothing
        )
        let waveformSegment = segment ?? TimelineRenderState.Track.WaveformSegment(
            outputStartProgress: 0,
            outputEndProgress: 1,
            sourceStartProgress: 0,
            sourceEndProgress: 1
        )
        let outputStart = min(max(waveformSegment.outputStartProgress * trackDurationProgress, 0), trackDurationProgress)
        let outputEnd = min(max(waveformSegment.outputEndProgress * trackDurationProgress, outputStart), trackDurationProgress)
        let sourceStart = min(max(waveformSegment.sourceStartProgress, 0), 1)
        let sourceEnd = min(max(waveformSegment.sourceEndProgress, 0), 1)
        let sourceMap = SIMD4<Float>(outputStart, outputEnd, sourceStart, sourceEnd)
        let segmentGain = SIMD4<Float>(
            max(waveformSegment.gainStart, 0),
            max(waveformSegment.gainEnd, 0),
            0,
            segment == nil ? 0 : 1
        )
        let commonStyle = SIMD4<Float>(
            style.spectralAmount,
            style.peakAlpha,
            style.bodyAlpha,
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
            sourceMap: sourceMap,
            segmentGain: segmentGain,
            style: commonStyle,
            style2: commonStyle2,
            gainPreview: gainPreview,
            fisheye: fisheye,
            touch: touch,
            touch2: touch2,
            touch3: touch3,
            selectionDrag: selectionDrag,
            selectionDrag2: selectionDrag2,
            selectionDragContact0: selectionDragContacts.contact0,
            selectionDragContact1: selectionDragContacts.contact1,
            selectionDragContact2: selectionDragContacts.contact2,
            selectionDragContact3: selectionDragContacts.contact3,
            selectionDragContact4: selectionDragContacts.contact4,
            selectionDragContact5: selectionDragContacts.contact5,
            selectionDragContact6: selectionDragContacts.contact6,
            selectionDragContact7: selectionDragContacts.contact7,
            deletionWarp: deletionWarp
        )
    }

    private func preferredShaderWaveformsAreReady(
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState,
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]]
    ) -> Bool {
        shaderWaveformsAreDrawable(
            drawableSize: drawableSize,
            backingScale: backingScale,
            renderState: renderState,
            trackWaveformMipLevels: trackWaveformMipLevels,
            fallbackPolicy: .preferredOnly
        )
    }

    private func shaderWaveformsAreDrawable(
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState,
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]],
        fallbackPolicy: WaveformShaderFallbackPolicy
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
        var drawableTrackCount = 0
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
                trackDuration > 0
            else {
                return false
            }

            let trackDurationProgress = min(max(Float(trackDuration / projectDuration), 0), 1)
            guard trackDurationProgress > 0 else {
                return false
            }

            checkedRenderableTrack = true
            let shaderDrawable = trackWaveformMipLevels[track.id].flatMap { mipLevels in
                waveformShaderDrawable(
                    track: track,
                    mipLevels: mipLevels,
                    drawableSize: drawableSize,
                    backingScale: backingScale,
                    renderState: renderState,
                    fallbackPolicy: fallbackPolicy
                )
            }
            guard shaderDrawable != nil ||
                (
                    fallbackPolicy == .allowFallbacks &&
                    waveformShaderPromotionRecordsByTrackID[track.id].map {
                        waveformShaderPromotionRecordCanBeHeld($0, for: track)
                    } == true
                )
            else {
                if fallbackPolicy == .preferredOnly {
                    return false
                }
                continue
            }
            drawableTrackCount += 1
        }

        if fallbackPolicy == .preferredOnly {
            return checkedRenderableTrack
        }
        return checkedRenderableTrack && drawableTrackCount > 0
    }

    private func waveformSampleSmoothingAmount(
        drawableSize: CGSize,
        backingScale: Float,
        binCount: Int,
        trackDurationProgress: Float,
        renderState: TimelineRenderState
    ) -> Float {
        let trackViewportProgress = min(
            max(renderState.viewport.durationProgress / max(trackDurationProgress, 0.000_001), 0),
            1
        )
        let visibleBins = max(Float(max(binCount, 1)) * trackViewportProgress, 1)
        let pixelWidth = Float(max(drawableSize.width, 1)) * max(backingScale, 1)
        let pointsPerBin = pixelWidth / visibleBins
        let adaptiveSmoothing = min(max((pointsPerBin - 0.02) / 1.15, 0.45), 1.0)
        return min(max(adaptiveSmoothing, 0.45), 1.0)
    }

    private func waveformShaderDrawable(
        track: TimelineRenderState.Track,
        mipLevels: [WaveformMipLevel],
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState,
        fallbackPolicy: WaveformShaderFallbackPolicy = .allowFallbacks
    ) -> WaveformShaderDrawable? {
        guard
            !mipLevels.isEmpty,
            let preferredIndex = waveformMipLevelIndex(
                for: drawableSize,
                backingScale: backingScale,
                renderState: renderState,
                mipLevels: mipLevels
            )
        else {
            return nil
        }

        let preferredMipLevel = mipLevels[preferredIndex]
        guard waveformMipLevelIsDisplayable(
            preferredMipLevel,
            track: track,
            drawableSize: drawableSize,
            backingScale: backingScale,
            renderState: renderState
        ) else {
            return nil
        }

        if let allocation = waveformShaderAllocation(track: track, mipLevel: preferredMipLevel) {
            return WaveformShaderDrawable(
                mipLevel: preferredMipLevel,
                buffer: allocation.buffer,
                binOffset: allocation.binOffset,
                isPreferred: true
            )
        }

        guard fallbackPolicy == .allowFallbacks else {
            return nil
        }

        if preferredIndex + 1 < mipLevels.count {
            for fallbackIndex in (preferredIndex + 1)..<mipLevels.count {
                let fallbackMipLevel = mipLevels[fallbackIndex]
                guard waveformMipLevelIsDisplayable(
                    fallbackMipLevel,
                    track: track,
                    drawableSize: drawableSize,
                    backingScale: backingScale,
                    renderState: renderState
                ) else {
                    continue
                }
                if let allocation = waveformShaderAllocation(track: track, mipLevel: fallbackMipLevel) {
                    return WaveformShaderDrawable(
                        mipLevel: fallbackMipLevel,
                        buffer: allocation.buffer,
                        binOffset: allocation.binOffset,
                        isPreferred: false
                    )
                }
            }
        }

        if preferredIndex > 0 {
            for fallbackIndex in stride(from: preferredIndex - 1, through: 0, by: -1) {
                let fallbackMipLevel = mipLevels[fallbackIndex]
                guard waveformMipLevelIsDisplayable(
                    fallbackMipLevel,
                    track: track,
                    drawableSize: drawableSize,
                    backingScale: backingScale,
                    renderState: renderState
                ) else {
                    continue
                }
                if let allocation = waveformShaderAllocation(track: track, mipLevel: fallbackMipLevel) {
                    return WaveformShaderDrawable(
                        mipLevel: fallbackMipLevel,
                        buffer: allocation.buffer,
                        binOffset: allocation.binOffset,
                        isPreferred: false
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
        allowsSynchronousUpload: Bool = false,
        generation: Int? = nil,
        maximumInFlightCount: Int? = nil,
        synchronousUploadBinLimit: Int? = nil,
        allowsSynchronousInFlightOverride: Bool = false
    ) {
        let key = waveformShaderBufferKey(track: track, mipLevel: mipLevel)
        let synchronousLimit = synchronousUploadBinLimit ?? maximumSynchronousWaveformShaderBinBufferBins
        guard waveformShaderBufferStore.beginPreparing(
            key,
            maximumInFlightCount: maximumInFlightCount ?? maximumInFlightWaveformShaderBufferUploads
        ) else {
            if
                allowsSynchronousInFlightOverride,
                allowsSynchronousUpload,
                mipLevel.binCount <= synchronousLimit,
                waveformShaderBufferStore.isPreparing(key)
            {
                let shaderBins = makeWaveformShaderBins(from: mipLevel.overview.bins)
                waveformShaderBufferStore.publishPreservingPreparation(shaderBins, for: key)
                onRenderDataPrepared?()
            }
            return
        }

        let bins = mipLevel.overview.bins
        if
            allowsSynchronousUpload,
            mipLevel.binCount <= synchronousLimit
        {
            let shaderBins = makeWaveformShaderBins(from: bins)
            waveformShaderBufferStore.publish(shaderBins, for: key)
            waveformShaderBufferStore.trim(
                toMaximumCount: maximumCachedWaveformShaderBinBuffers,
                maximumByteCount: maximumCachedWaveformShaderBinBufferBytes,
                protecting: protectedWaveformShaderKeys()
            )
            onRenderDataPrepared?()
            return
        }

        waveformGeometryQueue.async { [weak self] in
            guard
                generation == nil ||
                    generation == self?.waveformShaderPrewarmGeneration
            else {
                self?.waveformShaderBufferStore.publish(Optional<[WaveformShaderBin]>.none, for: key)
                return
            }

            let shaderBins = self?.makeWaveformShaderBins(
                from: bins,
                shouldYieldForPlayback: true
            )
            guard
                generation == nil ||
                    generation == self?.waveformShaderPrewarmGeneration
            else {
                self?.waveformShaderBufferStore.publish(Optional<[WaveformShaderBin]>.none, for: key)
                return
            }
            self?.deferWaveformShaderBinPublish(shaderBins, for: key, generation: generation)
        }
    }

    private func deferWaveformShaderBinPublish(
        _ bins: [WaveformShaderBin]?,
        for key: WaveformMipCacheKey,
        generation: Int?
    ) {
        guard
            generation == nil ||
                generation == waveformShaderPrewarmGeneration
        else {
            waveformShaderBufferStore.publish(Optional<[WaveformShaderBin]>.none, for: key)
            return
        }

        guard let bins, !bins.isEmpty else {
            waveformShaderBufferStore.publish(Optional<[WaveformShaderBin]>.none, for: key)
            return
        }

        let byteCount = bins.count * MemoryLayout<WaveformShaderBin>.stride
        deferredWaveformShaderPublishLock.lock()
        deferredWaveformShaderBinPublishes[key] = PendingWaveformShaderBinPublish(
            bins: bins,
            generation: generation,
            byteCount: byteCount
        )
        let shouldScheduleWakeup = !deferredWaveformShaderPublishWakeupScheduled
        if shouldScheduleWakeup {
            deferredWaveformShaderPublishWakeupScheduled = true
        }
        deferredWaveformShaderPublishLock.unlock()

        if shouldScheduleWakeup {
            onRenderDataPrepared?()
            scheduleDeferredWaveformShaderPublishWakeup()
        }
    }

    private func scheduleDeferredWaveformShaderPublishWakeup() {
        waveformGeometryQueue.asyncAfter(deadline: .now() + gpuResidentShadowInteractionCooldown) { [weak self] in
            guard let self else {
                return
            }
            self.deferredWaveformShaderPublishLock.lock()
            self.deferredWaveformShaderPublishWakeupScheduled = false
            let hasPendingPublishes = !self.deferredWaveformShaderBinPublishes.isEmpty
            self.deferredWaveformShaderPublishLock.unlock()
            if hasPendingPublishes {
                self.onRenderDataPrepared?()
            }
        }
    }

    private func hasDeferredWaveformShaderBinPublishes() -> Bool {
        deferredWaveformShaderPublishLock.lock()
        let hasPendingPublishes = !deferredWaveformShaderBinPublishes.isEmpty
        deferredWaveformShaderPublishLock.unlock()
        return hasPendingPublishes
    }

    private func flushDeferredWaveformShaderBinPublishesIfAllowed(
        renderState: TimelineRenderState,
        drawableSize: CGSize,
        backingScale: Float,
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]],
        displayTimestamp: CFTimeInterval,
        waveformHotPathReason: String?
    ) {
        guard hasDeferredWaveformShaderBinPublishes() else {
            return
        }

        let hoverNeedsInitialDrawableWaveform =
            waveformHotPathReason == "hover" &&
            !shaderWaveformsAreDrawable(
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: renderState,
                trackWaveformMipLevels: trackWaveformMipLevels,
                fallbackPolicy: .allowFallbacks
            )
        let allowsBudgetedPublish =
            waveformHotPathReason == nil ||
            waveformHotPathReason == "viewport-interaction" ||
            waveformHotPathReason == "waveform-transition" ||
            waveformHotPathReason == "hover" ||
            hoverNeedsInitialDrawableWaveform
        guard
            allowsBudgetedPublish,
            !renderState.isPlaybackActive,
            !renderState.isRecordingActive,
            !hasDeletionEffectsInFlight()
        else {
            scheduleDeferredWaveformShaderPublishWakeupIfNeeded()
            return
        }

        var selectedPublishes: [(WaveformMipCacheKey, PendingWaveformShaderBinPublish)] = []
        var staleKeys: [WaveformMipCacheKey] = []
        var selectedByteCount = 0

        deferredWaveformShaderPublishLock.lock()
        for (key, pending) in deferredWaveformShaderBinPublishes {
            if
                let generation = pending.generation,
                generation != waveformShaderPrewarmGeneration
            {
                staleKeys.append(key)
                continue
            }

            let projectedByteCount = selectedByteCount + pending.byteCount
            guard
                selectedPublishes.count < maximumDeferredWaveformShaderPublishCountPerFrame,
                projectedByteCount <= maximumDeferredWaveformShaderPublishByteCountPerFrame ||
                    selectedPublishes.isEmpty
            else {
                continue
            }

            selectedPublishes.append((key, pending))
            selectedByteCount = projectedByteCount
        }

        for key in staleKeys {
            deferredWaveformShaderBinPublishes.removeValue(forKey: key)
        }
        for (key, _) in selectedPublishes {
            deferredWaveformShaderBinPublishes.removeValue(forKey: key)
        }
        let hasRemainingPublishes = !deferredWaveformShaderBinPublishes.isEmpty
        deferredWaveformShaderPublishLock.unlock()

        for key in staleKeys {
            waveformShaderBufferStore.publish(Optional<[WaveformShaderBin]>.none, for: key)
        }
        guard !selectedPublishes.isEmpty else {
            if hasRemainingPublishes {
                scheduleDeferredWaveformShaderPublishWakeupIfNeeded()
            }
            return
        }

        for (key, pending) in selectedPublishes {
            waveformShaderBufferStore.publish(pending.bins, for: key)
        }
        waveformShaderBufferStore.trim(
            toMaximumCount: maximumCachedWaveformShaderBinBuffers,
            maximumByteCount: maximumCachedWaveformShaderBinBufferBytes,
            protecting: protectedWaveformShaderKeys()
        )
        let publishedBufferStats = waveformShaderBufferStore.drainPublishedBufferStats()
        frameStatsShaderBufferUploadCount += publishedBufferStats.count
        frameStatsShaderBufferUploadByteCount += publishedBufferStats.byteCount

        onRenderDataPrepared?()

        if hasRemainingPublishes {
            scheduleDeferredWaveformShaderPublishWakeupIfNeeded()
        }
    }

    private func scheduleDeferredWaveformShaderPublishWakeupIfNeeded() {
        deferredWaveformShaderPublishLock.lock()
        let shouldScheduleWakeup =
            !deferredWaveformShaderBinPublishes.isEmpty &&
            !deferredWaveformShaderPublishWakeupScheduled
        if shouldScheduleWakeup {
            deferredWaveformShaderPublishWakeupScheduled = true
        }
        deferredWaveformShaderPublishLock.unlock()

        if shouldScheduleWakeup {
            scheduleDeferredWaveformShaderPublishWakeup()
        }
    }

    private func prewarmInitialWaveformShaderBuffers(
        tracks: [TimelineRenderState.Track],
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]],
        renderState: TimelineRenderState,
        drawableSize: CGSize,
        backingScale: Float
    ) {
        let prewarmTracks = visiblePrewarmTracks(
            tracks: tracks,
            renderState: renderState,
            drawableSize: drawableSize
        )
        let jobs = prewarmTracks.compactMap { track -> (TimelineRenderState.Track, WaveformMipLevel)? in
            guard let mipLevels = trackWaveformMipLevels[track.id] else {
                return nil
            }
            let lowestCostMipLevel = lowestCostDisplayableWaveformMipLevel(
                from: mipLevels,
                track: track,
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: renderState
            ) ?? mipLevels.first

            return lowestCostMipLevel.map { (track, $0) }
        }
        guard !jobs.isEmpty else {
            return
        }

        for (track, mipLevel) in jobs {
            prepareWaveformShaderBinBuffer(
                track: track,
                mipLevel: mipLevel,
                allowsSynchronousUpload: true,
                generation: waveformShaderPrewarmGeneration
            )
        }

    }

    private func prewarmCurrentInteractiveWaveformShaderBuffers(
        drawableSize: CGSize,
        backingScale: Float
    ) {
        guard drawableSize.width > 0, drawableSize.height > 0, !renderState.tracks.isEmpty else {
            return
        }
        guard !hasDeletionEffectsInFlight() else {
            return
        }

        waveformMipLevelStateLock.lock()
        let mipLevels = trackWaveformMipLevels
        waveformMipLevelStateLock.unlock()
        prewarmInteractiveWaveformShaderBuffers(
            tracks: renderState.tracks,
            trackWaveformMipLevels: mipLevels,
            renderState: renderState,
            drawableSize: drawableSize,
            backingScale: backingScale
        )
    }

    func prepareVisibleWaveformShaderBuffersForDeletion() {
        let drawableSize = lastRenderViewportSize
        let backingScale = lastRenderBackingScale
        guard drawableSize.width > 0, drawableSize.height > 0, !renderState.tracks.isEmpty else {
            return
        }

        ensureWaveformMipLevelsExist(for: renderState.tracks)

        waveformMipLevelStateLock.lock()
        let mipLevels = trackWaveformMipLevels
        waveformMipLevelStateLock.unlock()

        let state = renderState
        let visibleTracks = visiblePrewarmTracks(
            tracks: state.tracks,
            renderState: state,
            drawableSize: drawableSize,
            overscan: 1,
            maximumCount: maximumViewportPrewarmTrackCount
        )
        let viewportBinLimit = viewportAwarePrewarmBinLimit(
            renderState: state,
            drawableSize: drawableSize,
            backingScale: backingScale
        )

        for track in visibleTracks where track.hasWaveform {
            guard let trackMipLevels = mipLevels[track.id], !trackMipLevels.isEmpty else {
                continue
            }

            let preferredMipLevel = preferredInteractiveWaveformShaderMipLevel(
                from: trackMipLevels,
                track: track,
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: state,
                fallbackBinLimit: viewportBinLimit
            )

            if let preferredMipLevel {
                let preferredKey = waveformShaderBufferKey(track: track, mipLevel: preferredMipLevel)
                if waveformShaderBufferStore.allocation(for: preferredKey) == nil {
                    prepareWaveformShaderBinBuffer(
                        track: track,
                        mipLevel: preferredMipLevel,
                        allowsSynchronousUpload: preferredMipLevel.binCount <= maximumLowCostContinuityWaveformShaderBins,
                        generation: waveformShaderPrewarmGeneration,
                        maximumInFlightCount: Int.max,
                        synchronousUploadBinLimit: maximumLowCostContinuityWaveformShaderBins,
                        allowsSynchronousInFlightOverride: true
                    )
                }
            }

            guard let continuityMipLevel = continuityWaveformShaderMipLevel(
                from: trackMipLevels,
                track: track,
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: state,
                prefersLowCostContinuity: true
            ) else {
                continue
            }

            let continuityKey = waveformShaderBufferKey(track: track, mipLevel: continuityMipLevel)
            guard waveformShaderBufferStore.allocation(for: continuityKey) == nil else {
                continue
            }
            prepareWaveformShaderBinBuffer(
                track: track,
                mipLevel: continuityMipLevel,
                allowsSynchronousUpload: true,
                generation: waveformShaderPrewarmGeneration,
                maximumInFlightCount: Int.max,
                synchronousUploadBinLimit: maximumLowCostContinuityWaveformShaderBins,
                allowsSynchronousInFlightOverride: true
            )
        }
    }

    private func prewarmInteractiveWaveformShaderBuffers(
        tracks: [TimelineRenderState.Track],
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]],
        renderState: TimelineRenderState,
        drawableSize: CGSize,
        backingScale: Float
    ) {
        let prefersExactMip = prefersExactWaveformMip(renderState: renderState)
        let visibleTracks = visiblePrewarmTracks(
            tracks: tracks,
            renderState: renderState,
            drawableSize: drawableSize,
            overscan: prefersExactMip ?
                waveformShaderHighResolutionPrewarmTrackOverscan :
                waveformShaderPrewarmTrackOverscan,
            maximumCount: prefersExactMip ?
                maximumHighResolutionPrewarmTrackCount :
                maximumViewportPrewarmTrackCount
        )
        let viewportBinLimit = viewportAwarePrewarmBinLimit(
            renderState: renderState,
            drawableSize: drawableSize,
            backingScale: backingScale
        )
        var visibleJobs: [(TimelineRenderState.Track, WaveformMipLevel)] = []
        var visibleJobKeys: Set<WaveformMipCacheKey> = []
        visibleJobs.reserveCapacity(visibleTracks.count * 2)
        for track in visibleTracks {
            guard let mipLevels = trackWaveformMipLevels[track.id] else {
                continue
            }

            if let continuityMipLevel = continuityWaveformShaderMipLevel(
                from: mipLevels,
                track: track,
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: renderState,
                prefersLowCostContinuity: true
            ) {
                let key = waveformShaderBufferKey(track: track, mipLevel: continuityMipLevel)
                if !visibleJobKeys.contains(key) {
                    visibleJobKeys.insert(key)
                    visibleJobs.append((track, continuityMipLevel))
                }
            }

            guard let interactiveMipLevel = preferredInteractiveWaveformShaderMipLevel(
                from: mipLevels,
                track: track,
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: renderState,
                fallbackBinLimit: viewportBinLimit
            ) else {
                continue
            }

            let key = waveformShaderBufferKey(track: track, mipLevel: interactiveMipLevel)
            if !visibleJobKeys.contains(key) {
                visibleJobKeys.insert(key)
                visibleJobs.append((track, interactiveMipLevel))
            }
        }

        let jobKeys = visibleJobs.map { track, mipLevel in
            waveformShaderBufferKey(track: track, mipLevel: mipLevel)
        }
        if
            jobKeys == lastInteractiveWaveformPrewarmKeys,
            waveformShaderBufferStore.containsAllAllocated(jobKeys)
        {
            return
        }
        lastInteractiveWaveformPrewarmKeys = jobKeys

        var deferredJobs: [(TimelineRenderState.Track, WaveformMipLevel)] = []
        var synchronousUploadCount = 0
        deferredJobs.reserveCapacity(visibleJobs.count)
        for (track, mipLevel) in visibleJobs {
            let key = waveformShaderBufferKey(track: track, mipLevel: mipLevel)
            if waveformShaderBufferStore.allocation(for: key) != nil {
                continue
            }
            if
                mipLevel.binCount <= maximumSynchronousWaveformShaderBinBufferBins,
                synchronousUploadCount < maximumSynchronousInteractiveWaveformShaderUploads
            {
                prepareWaveformShaderBinBuffer(
                    track: track,
                    mipLevel: mipLevel,
                    allowsSynchronousUpload: true,
                    generation: waveformShaderPrewarmGeneration,
                    maximumInFlightCount: Int.max,
                    synchronousUploadBinLimit: maximumSynchronousWaveformShaderBinBufferBins,
                    allowsSynchronousInFlightOverride: true
                )
                synchronousUploadCount += 1
                if waveformShaderBufferStore.allocation(for: key) != nil {
                    continue
                }
            }
            deferredJobs.append((track, mipLevel))
        }
        guard !deferredJobs.isEmpty else {
            return
        }

        let usesPriorityConversion = visibleJobs.count == 1 &&
            (visibleJobs.first?.1.binCount ?? 0) > maximumBackgroundPrewarmedWaveformShaderBins
        enqueueWaveformShaderPrewarmJobs(
            deferredJobs,
            generation: waveformShaderPrewarmGeneration,
            usesPriorityConversion: usesPriorityConversion
        )
    }

    func visibleWaveformShaderBuffersAreResident(drawableSize: CGSize) -> Bool {
        guard drawableSize.width > 0, drawableSize.height > 0 else {
            return true
        }

        let state = renderStateStore.snapshot()
        guard !state.tracks.isEmpty else {
            return true
        }

        waveformMipLevelStateLock.lock()
        let mipLevels = trackWaveformMipLevels
        waveformMipLevelStateLock.unlock()

        let keys = visibleInteractiveWaveformShaderKeys(
            tracks: state.tracks,
            trackWaveformMipLevels: mipLevels,
            renderState: state,
            drawableSize: drawableSize,
            backingScale: lastRenderBackingScale
        )
        return waveformShaderBufferStore.containsAllAllocated(keys)
    }

    func visibleWaveformDrawableBinCounts(
        drawableSize: CGSize,
        backingScale: Float
    ) -> [Int] {
        guard drawableSize.width > 0, drawableSize.height > 0 else {
            return []
        }

        let state = renderStateStore.snapshot()
        guard !state.tracks.isEmpty else {
            return []
        }

        waveformMipLevelStateLock.lock()
        let mipLevelsByTrack = trackWaveformMipLevels
        waveformMipLevelStateLock.unlock()

        let visibleTracks = visiblePrewarmTracks(
            tracks: state.tracks,
            renderState: state,
            drawableSize: drawableSize
        )
        return visibleTracks.compactMap { track -> Int? in
            guard let mipLevels = mipLevelsByTrack[track.id] else {
                return nil
            }

            return waveformShaderDrawable(
                track: track,
                mipLevels: mipLevels,
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: state,
                fallbackPolicy: .allowFallbacks
            )?.mipLevel.binCount
        }
    }

    private func visibleInteractiveWaveformShaderKeys(
        tracks: [TimelineRenderState.Track],
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]],
        renderState: TimelineRenderState,
        drawableSize: CGSize,
        backingScale: Float
    ) -> [WaveformMipCacheKey] {
        let visibleTracks = visiblePrewarmTracks(
            tracks: tracks,
            renderState: renderState,
            drawableSize: drawableSize
        )
        let viewportBinLimit = viewportAwarePrewarmBinLimit(
            renderState: renderState,
            drawableSize: drawableSize,
            backingScale: backingScale
        )
        return visibleTracks.compactMap { track -> WaveformMipCacheKey? in
            guard let mipLevels = trackWaveformMipLevels[track.id] else {
                return nil
            }
            guard let interactiveMipLevel = preferredInteractiveWaveformShaderMipLevel(
                from: mipLevels,
                track: track,
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: renderState,
                fallbackBinLimit: viewportBinLimit
            ) else {
                return nil
            }

            return waveformShaderBufferKey(track: track, mipLevel: interactiveMipLevel)
        }
    }

    private func protectedWaveformShaderKeys() -> Set<WaveformMipCacheKey> {
        let state = renderState
        let drawableSize = lastRenderViewportSize
        let backingScale = lastRenderBackingScale
        guard drawableSize.width > 0, drawableSize.height > 0 else {
            return []
        }

        waveformMipLevelStateLock.lock()
        let currentByTrack = trackWaveformMipLevels
        let previousByTrack = previousTrackWaveformMipLevels
        waveformMipLevelStateLock.unlock()

        var protectedKeys: Set<WaveformMipCacheKey> = []
        appendProtectedWaveformShaderKeys(
            to: &protectedKeys,
            tracks: state.tracks,
            trackWaveformMipLevels: currentByTrack,
            renderState: state,
            drawableSize: drawableSize,
            backingScale: backingScale
        )
        appendProtectedWaveformShaderKeys(
            to: &protectedKeys,
            tracks: previousTransitionTracks,
            trackWaveformMipLevels: previousByTrack,
            renderState: state,
            drawableSize: drawableSize,
            backingScale: backingScale
        )
        return protectedKeys
    }

    private func appendProtectedWaveformShaderKeys(
        to protectedKeys: inout Set<WaveformMipCacheKey>,
        tracks: [TimelineRenderState.Track],
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]],
        renderState: TimelineRenderState,
        drawableSize: CGSize,
        backingScale: Float
    ) {
        let visibleTracks = visiblePrewarmTracks(
            tracks: tracks,
            renderState: renderState,
            drawableSize: drawableSize,
            maximumCount: maximumViewportPrewarmTrackCount
        )
        let viewportBinLimit = viewportAwarePrewarmBinLimit(
            renderState: renderState,
            drawableSize: drawableSize,
            backingScale: backingScale
        )
        for track in visibleTracks {
            guard let mipLevels = trackWaveformMipLevels[track.id] else {
                continue
            }

            if let continuityMipLevel = continuityWaveformShaderMipLevel(
                from: mipLevels,
                track: track,
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: renderState
            ) {
                protectedKeys.insert(waveformShaderBufferKey(track: track, mipLevel: continuityMipLevel))
            }

            if let interactiveMipLevel = preferredInteractiveWaveformShaderMipLevel(
                from: mipLevels,
                track: track,
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: renderState,
                fallbackBinLimit: viewportBinLimit
            ) {
                protectedKeys.insert(waveformShaderBufferKey(track: track, mipLevel: interactiveMipLevel))
            }
        }
    }

    private func continuityWaveformShaderMipLevel(
        from mipLevels: [WaveformMipLevel],
        track: TimelineRenderState.Track,
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState,
        prefersLowCostContinuity: Bool = false
    ) -> WaveformMipLevel? {
        guard !mipLevels.isEmpty else {
            return nil
        }

        let displayableMipLevels = mipLevels.reversed().filter {
            waveformMipLevelIsDisplayable(
                $0,
                track: track,
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: renderState
            )
        }

        if prefersLowCostContinuity,
           let lowCostDisplayableMipLevel = displayableMipLevels.first(where: {
               $0.binCount <= maximumLowCostContinuityWaveformShaderBins
           })
        {
            return lowCostDisplayableMipLevel
        }

        if let displayableMipLevel = displayableMipLevels.first {
            return displayableMipLevel
        }

        if prefersLowCostContinuity,
           let lowCostMipLevel = mipLevels.reversed().first(where: {
               $0.binCount <= maximumLowCostContinuityWaveformShaderBins
           })
        {
            return lowCostMipLevel
        }

        return mipLevels.last ?? mipLevels.first
    }

    @discardableResult
    private func ensureContinuityWaveformShaderBufferIsResident(
        trackID: UUID,
        mipLevels: [WaveformMipLevel],
        renderState: TimelineRenderState,
        drawableSize: CGSize,
        backingScale: Float
    ) -> Bool {
        guard
            drawableSize.width > 0,
            drawableSize.height > 0,
            let track = renderState.tracks.first(where: { $0.id == trackID }),
            let continuityMipLevel = continuityWaveformShaderMipLevel(
                from: mipLevels,
                track: track,
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: renderState,
                prefersLowCostContinuity: true
            )
        else {
            return false
        }

        let key = waveformShaderBufferKey(track: track, mipLevel: continuityMipLevel)
        if waveformShaderBufferStore.allocation(for: key) != nil {
            return true
        }

        prepareWaveformShaderBinBuffer(
            track: track,
            mipLevel: continuityMipLevel,
            allowsSynchronousUpload: true,
            generation: waveformShaderPrewarmGeneration,
            maximumInFlightCount: Int.max,
            synchronousUploadBinLimit: maximumLowCostContinuityWaveformShaderBins,
            allowsSynchronousInFlightOverride: true
        )
        return waveformShaderBufferStore.allocation(for: key) != nil
    }

    private func ensurePreferredWaveformShaderBufferIsResident(
        trackID: UUID,
        mipLevels: [WaveformMipLevel],
        renderState: TimelineRenderState,
        drawableSize: CGSize,
        backingScale: Float
    ) -> Bool {
        guard
            drawableSize.width > 0,
            drawableSize.height > 0,
            let track = renderState.tracks.first(where: { $0.id == trackID }),
            let preferredIndex = waveformMipLevelIndex(
                for: drawableSize,
                backingScale: backingScale,
                renderState: renderState,
                mipLevels: mipLevels
            )
        else {
            return false
        }

        let preferredMipLevel = mipLevels[preferredIndex]
        guard waveformMipLevelIsDisplayable(
            preferredMipLevel,
            track: track,
            drawableSize: drawableSize,
            backingScale: backingScale,
            renderState: renderState
        ) else {
            return false
        }

        let key = waveformShaderBufferKey(track: track, mipLevel: preferredMipLevel)
        if waveformShaderBufferStore.allocation(for: key) != nil {
            return true
        }

        prepareWaveformShaderBinBuffer(
            track: track,
            mipLevel: preferredMipLevel,
            allowsSynchronousUpload: preferredMipLevel.binCount <= maximumLowCostContinuityWaveformShaderBins,
            generation: waveformShaderPrewarmGeneration,
            maximumInFlightCount: Int.max,
            synchronousUploadBinLimit: maximumLowCostContinuityWaveformShaderBins,
            allowsSynchronousInFlightOverride: true
        )
        return waveformShaderBufferStore.allocation(for: key) != nil
    }

    private func promoteReadyPendingWaveformMipLevelPublications(
        renderState currentRenderState: TimelineRenderState,
        drawableSize: CGSize,
        backingScale: Float
    ) {
        guard drawableSize.width > 0, drawableSize.height > 0 else {
            return
        }

        waveformMipLevelStateLock.lock()
        let pendingLevels = pendingCompleteWaveformMipLevels
        let activeKeys = currentTrackWaveformMipKeys
        waveformMipLevelStateLock.unlock()

        guard !pendingLevels.isEmpty else {
            return
        }

        var didPromote = false
        for (key, levels) in pendingLevels where activeKeys[key.trackID] == key {
            guard ensurePreferredWaveformShaderBufferIsResident(
                trackID: key.trackID,
                mipLevels: levels,
                renderState: currentRenderState,
                drawableSize: drawableSize,
                backingScale: backingScale
            ) else {
                continue
            }

            didPromote = commitVisibleWaveformMipLevels(levels, for: key, renderState: currentRenderState) || didPromote
        }

        if didPromote {
            prewarmCurrentInteractiveWaveformShaderBuffers(
                drawableSize: drawableSize,
                backingScale: backingScale
            )
        }
    }

    @discardableResult
    private func commitVisibleWaveformMipLevels(
        _ levels: [WaveformMipLevel],
        for key: WaveformMipCacheKey,
        renderState: TimelineRenderState
    ) -> Bool {
        waveformMipLevelStateLock.lock()
        defer {
            waveformMipLevelStateLock.unlock()
        }

        pendingCompleteWaveformMipLevels.removeValue(forKey: key)
        guard currentTrackWaveformMipKeys[key.trackID] == key else {
            return false
        }

        if let currentLevels = trackWaveformMipLevels[key.trackID],
           !currentLevels.isEmpty,
           waveformMipLevelBinSignature(currentLevels) != waveformMipLevelBinSignature(levels)
        {
            if renderState.isPlaybackActive {
                previousTrackWaveformMipLevels = [:]
                previousTransitionTracks = []
                previousTransitionViewport = nil
                waveformGeometryStore.clearPrevious()
                waveformTransitionStartTime = nil
            } else {
                previousTrackWaveformMipLevels = trackWaveformMipLevels
                previousTransitionTracks = renderState.tracks
                previousTransitionViewport = renderState.viewport
                waveformGeometryStore.promoteCurrentToPrevious()
                waveformTransitionStartTime = nil
            }
        }
        trackWaveformMipLevels[key.trackID] = levels
        if currentPrimaryWaveformTrackID == key.trackID {
            waveformMipLevels = levels
        }
        return true
    }

    private func lowestCostDisplayableWaveformMipLevel(
        from mipLevels: [WaveformMipLevel],
        track: TimelineRenderState.Track,
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState
    ) -> WaveformMipLevel? {
        mipLevels.reversed().first {
            waveformMipLevelIsDisplayable(
                $0,
                track: track,
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: renderState
            )
        }
    }

    private func preferredInteractiveWaveformShaderMipLevel(
        from mipLevels: [WaveformMipLevel],
        track: TimelineRenderState.Track,
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState,
        fallbackBinLimit: Int
    ) -> WaveformMipLevel? {
        if let preferredIndex = waveformMipLevelIndex(
            for: drawableSize,
            backingScale: backingScale,
            renderState: renderState,
            mipLevels: mipLevels
        ) {
            let mipLevel = mipLevels[preferredIndex]
            return waveformMipLevelIsDisplayable(
                mipLevel,
                track: track,
                drawableSize: drawableSize,
                backingScale: backingScale,
                renderState: renderState
            ) ? mipLevel : nil
        }

        return mipLevels.first {
            $0.binCount <= fallbackBinLimit &&
                waveformMipLevelIsDisplayable(
                    $0,
                    track: track,
                    drawableSize: drawableSize,
                    backingScale: backingScale,
                    renderState: renderState
            )
        }
    }

    private func waveformMipLevelIsDisplayable(
        _ mipLevel: WaveformMipLevel,
        track: TimelineRenderState.Track,
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState
    ) -> Bool {
        guard mipLevel.binCount > 0 else {
            return false
        }
        guard
            mipLevel.overview.duration >= minimumDisplayableWaveformDurationThreshold,
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0,
            let trackDuration = track.durationHint,
            trackDuration.isFinite,
            trackDuration > 0
        else {
            return true
        }

        let visibleDuration = projectDuration * Double(max(renderState.viewport.durationProgress, 0))
        if visibleDuration <= highResolutionWaveformVisibleDurationThreshold {
            return true
        }

        let trackDurationProgress = min(max(Float(trackDuration / projectDuration), 0), 1)
        guard trackDurationProgress > 0 else {
            return false
        }

        let visibleStart = max(renderState.viewport.startProgress, 0)
        let visibleEnd = min(renderState.viewport.endProgress, trackDurationProgress)
        let visibleTrackProgress = max(visibleEnd - visibleStart, 0)
        guard visibleTrackProgress > 0 else {
            return true
        }

        let viewportDuration = max(renderState.viewport.durationProgress, 0.000_001)
        let drawablePixelWidth = max(Float(drawableSize.width) * max(backingScale, 1), 1)
        let visiblePixelWidth = max(drawablePixelWidth * visibleTrackProgress / viewportDuration, 1)
        let visibleBinCount = Float(mipLevel.binCount) * visibleTrackProgress / trackDurationProgress
        let binsPerPixel = visibleBinCount / visiblePixelWidth
        return binsPerPixel >= minimumDisplayableWaveformBinsPerPixel(renderState: renderState)
    }

    private func minimumDisplayableWaveformBinsPerPixel(renderState: TimelineRenderState) -> Float {
        guard
            let duration = renderState.duration,
            duration.isFinite,
            duration > 0
        else {
            return detailMinimumDisplayableWaveformBinsPerPixel
        }

        let visibleDuration = duration * Double(max(renderState.viewport.durationProgress, 0))
        guard visibleDuration.isFinite, visibleDuration > highResolutionWaveformVisibleDurationThreshold else {
            return detailMinimumDisplayableWaveformBinsPerPixel
        }

        let progress = smoothStep(
            Float(
                (visibleDuration - highResolutionWaveformVisibleDurationThreshold) /
                max(overviewWaveformMipVisibleDuration - highResolutionWaveformVisibleDurationThreshold, 0.000_001)
            )
        )
        return mix(
            detailMinimumDisplayableWaveformBinsPerPixel,
            overviewMinimumDisplayableWaveformBinsPerPixel,
            progress
        )
    }

    private func visiblePrewarmTracks(
        tracks: [TimelineRenderState.Track],
        renderState: TimelineRenderState,
        drawableSize: CGSize,
        overscan: Int = -1,
        maximumCount: Int = -1
    ) -> [TimelineRenderState.Track] {
        guard !tracks.isEmpty else {
            return []
        }

        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        let visibleRange = trackLayout.visibleRange(
            overscan: overscan >= 0 ? overscan : waveformShaderPrewarmTrackOverscan
        )
        let maximumCount = maximumCount > 0 ? maximumCount : maximumViewportPrewarmTrackCount
        var visibleTracks: [TimelineRenderState.Track] = []
        visibleTracks.reserveCapacity(min(maximumCount, visibleRange.count))
        for trackIndex in visibleRange {
            guard visibleTracks.count < maximumCount else {
                break
            }
            guard tracks.indices.contains(trackIndex) else {
                continue
            }

            visibleTracks.append(tracks[trackIndex])
        }
        return visibleTracks
    }

    private func prefersExactWaveformMip(renderState: TimelineRenderState) -> Bool {
        guard
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0
        else {
            return false
        }

        let visibleDuration = projectDuration * Double(renderState.viewport.durationProgress)
        return visibleDuration <= highResolutionWaveformVisibleDurationThreshold
    }

    private func enqueueWaveformShaderPrewarmJobs(
        _ jobs: [(TimelineRenderState.Track, WaveformMipLevel)],
        generation: Int,
        usesPriorityConversion: Bool
    ) {
        guard !jobs.isEmpty else {
            return
        }

        enqueueWaveformShaderPrewarmJobs(
            jobs,
            startIndex: 0,
            generation: generation,
            usesPriorityConversion: usesPriorityConversion
        )
    }

    private func enqueueWaveformShaderPrewarmJobs(
        _ jobs: [(TimelineRenderState.Track, WaveformMipLevel)],
        startIndex: Int,
        generation: Int,
        usesPriorityConversion: Bool
    ) {
        guard startIndex < jobs.count else {
            return
        }

        waveformGeometryQueue.async { [weak self] in
            guard let self else {
                return
            }
            guard generation == self.waveformShaderPrewarmGeneration else {
                return
            }

            let endIndex = min(startIndex + self.waveformPrewarmJobBatchSize, jobs.count)
            for jobIndex in startIndex..<endIndex {
                guard generation == self.waveformShaderPrewarmGeneration else {
                    return
                }

                let (track, mipLevel) = jobs[jobIndex]
                let key = self.waveformShaderBufferKey(track: track, mipLevel: mipLevel)
                if self.waveformShaderBufferStore.allocation(for: key) != nil {
                    continue
                }

                guard self.waveformShaderBufferStore.beginPreparing(
                    key,
                    maximumInFlightCount: Int.max
                ) else {
                    continue
                }

                let shaderBins = self.makeWaveformShaderBins(
                    from: mipLevel.overview.bins,
                    shouldYieldForPlayback: true
                )
                guard generation == self.waveformShaderPrewarmGeneration else {
                    self.waveformShaderBufferStore.publish(Optional<[WaveformShaderBin]>.none, for: key)
                    return
                }
                self.deferWaveformShaderBinPublish(shaderBins, for: key, generation: generation)
            }

            if endIndex < jobs.count {
                self.enqueueWaveformShaderPrewarmJobs(
                    jobs,
                    startIndex: endIndex,
                    generation: generation,
                    usesPriorityConversion: usesPriorityConversion
                )
            }
        }
    }

    private func viewportAwarePrewarmBinLimit(
        renderState: TimelineRenderState,
        drawableSize: CGSize,
        backingScale: Float
    ) -> Int {
        let viewportDurationProgress = max(renderState.viewport.durationProgress, 0.000_001)
        let targetVisibleBins = waveformMipTargetVisibleBins(
            drawableSize: drawableSize,
            backingScale: backingScale,
            renderState: renderState
        )
        let binsForVisibleViewport = Int(
            ceil(Double(targetVisibleBins / viewportDurationProgress))
        )
        return min(
            max(maximumBackgroundPrewarmedWaveformShaderBins, binsForVisibleViewport),
            maximumViewportPrewarmedWaveformShaderBins
        )
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
        let trackLayout = renderState.trackLayout.resolved(
            totalTrackCount: renderState.tracks.count,
            viewportHeight: height
        )
        let rulerHeightPixels = max(trackLayout.rulerLaneHeight * scale, 1)

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

    private func makeRulerLaneVertices(
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState
    ) -> [TimelineVertex] {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return []
        }

        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        let rulerHeight = min(max(trackLayout.rulerLaneHeight, 0), height)
        guard rulerHeight > 0 else {
            return []
        }

        let size = SIMD2<Float>(width, height)
        let lineWidth = pixelLength(backingScale: backingScale)
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(12)
        appendRectangle(
            to: &vertices,
            left: 0,
            right: width,
            top: 0,
            bottom: rulerHeight,
            color: SIMD4<Float>(0.055, 0.058, 0.060, 0.96),
            drawableSize: size
        )
        let separatorY = pixelAligned(rulerHeight, backingScale: backingScale)
        appendRectangle(
            to: &vertices,
            left: 0,
            right: width,
            top: max(separatorY - lineWidth, 0),
            bottom: min(separatorY, height),
            color: SIMD4<Float>(0.20, 0.22, 0.23, 0.72),
            drawableSize: size
        )
        return vertices
    }

    private func makeLoopRangeUniform(
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState,
        displayTimestamp: CFTimeInterval
    ) -> LoopRegionUniform? {
        guard
            renderState.duration != nil,
            !renderState.tracks.isEmpty
        else {
            return nil
        }

        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return nil
        }

        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        let rulerHeight = min(max(trackLayout.rulerLaneHeight, 0), height)
        guard rulerHeight > 8 else {
            return nil
        }

        guard loopRange.durationProgress < 0.999 else {
            return nil
        }

        let startViewportProgress = renderState.viewport.viewportProgress(
            forTimelineProgress: loopRange.startProgress
        )
        let endViewportProgress = renderState.viewport.viewportProgress(
            forTimelineProgress: loopRange.endProgress
        )
        let rawLeft = min(startViewportProgress, endViewportProgress) * width
        let rawRight = max(startViewportProgress, endViewportProgress) * width
        let left = min(max(rawLeft, 0), width)
        let right = min(max(rawRight, 0), width)
        guard right - left > pixelLength(backingScale: backingScale) else {
            return nil
        }

        let lineWidth = pixelLength(backingScale: backingScale)
        let top = max(pixelLength(2, backingScale: backingScale), 1)
        let bottom = max(rulerHeight, top + 1)
        let radius = min(max((bottom - top) * 0.34, 4), 8)
        let hoverBoost: Float = isLoopRegionHighlighted ? 1 : 0
        let flashBoost = currentLoopRangeFlashBoost(displayTimestamp: displayTimestamp)
        let activeAlpha: Float = isLoopRangeEnabled ? 0.30 : 0.15
        let fillAlpha = activeAlpha + hoverBoost * 0.08
        let edgeAlpha = (isLoopRangeEnabled ? 0.72 : 0.36) + hoverBoost * 0.12
        let fillRGB = isLoopRangeEnabled ?
            mix(SIMD3<Float>(0.10, 0.78, 0.86), SIMD3<Float>(0.92, 1.0, 1.0), flashBoost * 0.38) :
            SIMD3<Float>(0.46 + hoverBoost * 0.06, 0.47 + hoverBoost * 0.06, 0.48 + hoverBoost * 0.06)
        let topRGB = isLoopRangeEnabled ?
            mix(SIMD3<Float>(0.92, 1.0, 1.0), SIMD3<Float>(1.0, 1.0, 1.0), flashBoost * 0.55) :
            SIMD3<Float>(0.82, 0.83, 0.84)
        let bottomRGB = isLoopRangeEnabled ?
            mix(SIMD3<Float>(0.00, 0.20, 0.23), SIMD3<Float>(0.58, 0.68, 0.70), flashBoost * 0.42) :
            SIMD3<Float>(0.16, 0.16, 0.17)
        let edgeRGB = isLoopRangeEnabled ?
            mix(SIMD3<Float>(0.86, 0.98, 1.0), SIMD3<Float>(1.0, 1.0, 1.0), flashBoost * 0.65) :
            SIMD3<Float>(0.78, 0.79, 0.80)
        let flashedFillAlpha = min(fillAlpha + flashBoost * 0.10, 0.55)
        let flashedEdgeAlpha = min(edgeAlpha + flashBoost * 0.16, 0.96)
        let endpointHighlight: Float
        switch highlightedLoopEndpoint {
        case .start:
            endpointHighlight = -1
        case .end:
            endpointHighlight = 1
        case nil:
            endpointHighlight = 0
        }

        return LoopRegionUniform(
            rect: SIMD4<Float>(
                left / width,
                right / width,
                top / height,
                bottom / height
            ),
            metrics: SIMD4<Float>(
                max(right - left, 1),
                max(bottom - top, 1),
                radius,
                max(lineWidth, 1)
            ),
            style: SIMD4<Float>(
                isLoopRangeEnabled ? 1 : 0,
                hoverBoost,
                flashBoost,
                Float(displayTimestamp.truncatingRemainder(dividingBy: 8192))
            ),
            edgeHighlight: SIMD4<Float>(
                endpointHighlight,
                abs(endpointHighlight),
                max(lineWidth, 1),
                0
            ),
            fillColor: SIMD4<Float>(fillRGB.x, fillRGB.y, fillRGB.z, flashedFillAlpha),
            topColor: SIMD4<Float>(
                topRGB.x,
                topRGB.y,
                topRGB.z,
                isLoopRangeEnabled ? 0.13 + hoverBoost * 0.05 + flashBoost * 0.08 : 0.07 + hoverBoost * 0.03
            ),
            bottomColor: SIMD4<Float>(
                bottomRGB.x,
                bottomRGB.y,
                bottomRGB.z,
                isLoopRangeEnabled ? 0.18 + flashBoost * 0.06 : 0.10
            ),
            edgeColor: SIMD4<Float>(edgeRGB.x, edgeRGB.y, edgeRGB.z, flashedEdgeAlpha)
        )
    }

    private func currentLoopRangeFlashBoost(displayTimestamp: CFTimeInterval) -> Float {
        guard isLoopRangeEnabled, let loopRangeFlashStartTime else {
            return 0
        }

        let elapsed = displayTimestamp - loopRangeFlashStartTime
        guard elapsed >= 0 else {
            return 1
        }

        guard elapsed < loopRangeFlashDuration else {
            self.loopRangeFlashStartTime = nil
            return 0
        }

        let progress = min(max(Float(elapsed / loopRangeFlashDuration), 0), 1)
        let remaining = 1 - smoothStep(progress)
        return remaining * 0.72
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

    private func clearPreviousWaveformTransition() {
        waveformMipLevelStateLock.lock()
        previousTrackWaveformMipLevels = [:]
        waveformMipLevelStateLock.unlock()
        previousTransitionTracks = []
        previousTransitionViewport = nil
        waveformGeometryStore.clearPrevious()
        waveformTransitionStartTime = nil
    }

    private func markWaveformHotInteraction(at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        waveformHotPathLock.lock()
        lastWaveformHotInteractionTimestamp = timestamp
        waveformHotPathLock.unlock()
    }

    private func isViewportInteractionHot(at timestamp: CFTimeInterval) -> Bool {
        waveformHotPathLock.lock()
        let lastInteractionTimestamp = lastWaveformHotInteractionTimestamp
        waveformHotPathLock.unlock()
        return timestamp - lastInteractionTimestamp < gpuResidentShadowInteractionCooldown
    }

    private func updateGPUResidentWaveformShadowFrameStats(
        renderState: TimelineRenderState,
        drawableSize: CGSize,
        backingScale: Float,
        displayTimestamp: CFTimeInterval
    ) {
        frameStatsGPUResidentWaveformMode = WaveformGPUResidentWaveformsFeatureFlags.modeDescription
        frameStatsGPUResidentShadowSourceCount = 0
        frameStatsGPUResidentShadowRequestCount = 0
        frameStatsGPUResidentShadowVisibleTileCount = 0
        frameStatsGPUResidentShadowDrawBatchCount = 0
        frameStatsGPUResidentShadowDrawInstanceCount = 0

        guard
            WaveformGPUResidentWaveformsFeatureFlags.isShadowModeEnabled,
            let tiledWaveformPipeline,
            let tiledWaveformMetalBufferStore
        else {
            return
        }

        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        let widthPixels = Double(max(drawableSize.width, 1)) * Double(max(backingScale, 1))
        let projectDuration = max(renderState.duration ?? 0, 0)
        guard projectDuration > 0 else {
            return
        }

        var sourceIDs = Set<WaveformSourceID>()
        var requestedTileCount = 0
        guard
            !renderState.isPlaybackActive,
            !renderState.isRecordingActive,
            !hasDeletionEffectsInFlight(),
            !isViewportInteractionHot(at: displayTimestamp)
        else {
            return
        }

        var selectedResidentTileCount = 0
        var shadowDrawBatchPlan = WaveformTileDrawBatchPlan.empty
        let completedWork = tiledWaveformPipeline.drainCompletedAsyncWork()
        frameStatsShaderBufferUploadCount += completedWork.uploadSummary.uploadedCount
        frameStatsShaderBufferUploadByteCount += completedWork.uploadSummary.uploadedBytes

        for trackIndex in trackLayout.visibleRange(overscan: 1) {
            guard
                renderState.tracks.indices.contains(trackIndex),
                let source = renderState.tracks[trackIndex].waveformTileSource
            else {
                continue
            }

            let track = renderState.tracks[trackIndex]
            sourceIDs.insert(source.sourceID)
            let viewport = WaveformTileSchedulerViewport(
                timelineViewport: renderState.viewport,
                duration: projectDuration,
                widthPixels: widthPixels
            )
            let segments = waveformTileSchedulerSegments(
                for: track,
                source: source,
                projectDuration: projectDuration
            )
            let frame = tiledWaveformPipeline.prepareResidentFrame(
                source: source.metadata,
                viewport: viewport,
                segments: segments,
                timestamp: displayTimestamp,
                buildBatchLimit: 2,
                uploadBudget: WaveformTileUploadBudget(
                    maximumBytesPerBatch: 512 * 1_024,
                    maximumTilesPerBatch: 4
                ),
                discardUpload: { _, resource in
                    tiledWaveformMetalBufferStore.remove(resourceID: resource.id)
                },
                evictUpload: { addresses in
                    tiledWaveformMetalBufferStore.remove(addresses: addresses)
                },
                upload: { payload in
                    try tiledWaveformMetalBufferStore.upload(payload)
                },
                onWorkCompleted: onRenderDataPrepared
            )
            requestedTileCount += frame.renderSelection.requestedCount
            selectedResidentTileCount += frame.renderSelection.selectedCount
            if let laneFrame = trackLayout.laneFrame(forTrackIndex: trackIndex), laneFrame.isVisible {
                shadowDrawBatchPlan.append(WaveformTileDrawBatchPlanner.plan(
                    trackID: track.id,
                    trackIndex: trackIndex,
                    laneFrame: laneFrame,
                    source: source.metadata,
                    segments: segments,
                    promotionPlan: frame.promotionPlan
                ))
            }
        }

        frameStatsGPUResidentShadowSourceCount = sourceIDs.count
        frameStatsGPUResidentShadowRequestCount = requestedTileCount
        frameStatsGPUResidentShadowVisibleTileCount = selectedResidentTileCount
        frameStatsGPUResidentShadowDrawBatchCount = shadowDrawBatchPlan.batchCount
        frameStatsGPUResidentShadowDrawInstanceCount = shadowDrawBatchPlan.instanceCount
    }

    private func waveformTileSchedulerSegments(
        for track: TimelineRenderState.Track,
        source: WaveformTileBuildSource,
        projectDuration: TimeInterval
    ) -> [WaveformTileSchedulerSegment] {
        let outputDuration = min(
            max(track.durationHint ?? source.duration, 0),
            max(projectDuration, 0)
        )
        guard outputDuration > 0, source.duration > 0 else {
            return []
        }

        if track.waveformSegments.isEmpty {
            return [
                WaveformTileSchedulerSegment(
                    outputStartTime: 0,
                    outputEndTime: outputDuration,
                    sourceStartTime: 0,
                    sourceEndTime: source.duration
                )
            ]
        }

        return track.waveformSegments.map { segment in
            WaveformTileSchedulerSegment(
                outputStartProgress: segment.outputStartProgress,
                outputEndProgress: segment.outputEndProgress,
                sourceStartProgress: segment.sourceStartProgress,
                sourceEndProgress: segment.sourceEndProgress,
                outputDuration: outputDuration,
                sourceDuration: source.duration
            )
        }
    }

    private func waveformPerformanceContractHotPathReason(
        renderState: TimelineRenderState,
        hasActiveDeletionEffect: Bool,
        isSelectionDragFrame: Bool,
        hasWaveformTransition: Bool,
        displayTimestamp: CFTimeInterval
    ) -> String? {
        if renderState.isPlaybackActive {
            return "playback"
        }
        if renderState.isRecordingActive {
            return "recording"
        }
        if hasActiveDeletionEffect {
            return "delete-animation"
        }
        if isSelectionDragFrame {
            return "selection-drag"
        }
        if hasWaveformTransition {
            return "waveform-transition"
        }
        if renderState.trimPreview != nil {
            return "trim-preview"
        }
        if renderState.gainPreview != nil {
            return "gain-preview"
        }
        if renderState.hoverProgress != nil || renderState.isHoverGuideArmed {
            return "hover"
        }

        waveformHotPathLock.lock()
        let lastInteractionTimestamp = lastWaveformHotInteractionTimestamp
        waveformHotPathLock.unlock()
        if displayTimestamp - lastInteractionTimestamp < waveformCPUFallbackInteractionCooldown {
            return "viewport-interaction"
        }

        return nil
    }

    private func recordWaveformPerformanceContract(
        hotPathReason: String?,
        displayTimestamp: CFTimeInterval
    ) {
        guard let hotPathReason else {
            frameStatsWaveformHotPathViolationCount = 0
            return
        }

        var violationCount = 0
        if frameStatsCPUWaveformVertexCount > 0 {
            violationCount += 1
        }
        if frameStatsCPUWaveformFallbackDrawCount > 0 {
            violationCount += 1
        }
        let uploadIsViolation = hotPathReason != "viewport-interaction" &&
            frameStatsShaderBufferUploadByteCount > 0
        if uploadIsViolation {
            violationCount += 1
        }

        frameStatsWaveformHotPathViolationCount = violationCount
        guard
            violationCount > 0,
            displayTimestamp - lastWaveformPerformanceContractEventTime >= 1
        else {
            return
        }

        lastWaveformPerformanceContractEventTime = displayTimestamp
        SoundtimeDiagnostics.shared.record(
            category: .render,
            severity: .warning,
            name: "waveform-hot-path-contract-violation",
            message: "Waveform renderer did CPU or upload work during a hot interaction.",
            fields: [
                "reason": hotPathReason,
                "cpuVertices": "\(frameStatsCPUWaveformVertexCount)",
                "cpuFallbackDraws": "\(frameStatsCPUWaveformFallbackDrawCount)",
                "uploadCount": "\(frameStatsShaderBufferUploadCount)",
                "uploadBytes": "\(frameStatsShaderBufferUploadByteCount)",
                "fallbackDraws": "\(frameStatsWaveformFallbackDrawCount)",
                "residentMisses": "\(frameStatsWaveformResidentMissCount)",
                "lastGoodHolds": "\(frameStatsWaveformLastGoodHoldCount)",
            ]
        )
    }

    private func isColdStaticCPUWaveformFallbackAllowed(
        renderState: TimelineRenderState,
        hasWaveformTransition: Bool,
        displayTimestamp: CFTimeInterval
    ) -> Bool {
        // CPU waveform geometry is only a cold, static-frame escape hatch. Any
        // interactive frame must hold resident GPU data or skip waveform drawing
        // for that frame instead of rebuilding geometry on the render path.
        if renderState.isPlaybackActive ||
            renderState.isRecordingActive ||
            hasWaveformTransition ||
            renderState.trimPreview != nil ||
            renderState.gainPreview != nil ||
            renderState.hoverProgress != nil ||
            renderState.isHoverGuideArmed
        {
            return false
        }

        waveformHotPathLock.lock()
        let lastInteractionTimestamp = lastWaveformHotInteractionTimestamp
        waveformHotPathLock.unlock()
        return displayTimestamp - lastInteractionTimestamp >= waveformCPUFallbackInteractionCooldown
    }

    private func waveformTransitionOpacities(
        at displayTimestamp: CFTimeInterval,
        hasCurrent: Bool,
        hasPrevious: Bool,
        holdsPreviousForDeletion: Bool = false
    ) -> (
        current: Float,
        previous: Float
    ) {
        guard hasPreviousWaveformTransition, hasPrevious else {
            return (current: 1, previous: 0)
        }
        if holdsPreviousForDeletion {
            return (current: 0, previous: 1)
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
            previousTransitionViewport = nil
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
        publishImmediateHotPathFrameStatsIfNeeded(currentTime: currentTime)

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
        let frameStats = makeFrameStats(
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
        lastFrameStats = frameStats
        onFrameStatsChanged?(frameStats)
    }

    private func publishImmediateHotPathFrameStatsIfNeeded(currentTime: CFTimeInterval) {
        guard !frameStatsWaveformHotPathReason.isEmpty else {
            return
        }

        let reasonChanged = lastFrameStats?.waveformHotPathReason != frameStatsWaveformHotPathReason
        guard reasonChanged || currentTime - lastImmediateHotPathFrameStatsPublishTime >= 0.10 else {
            return
        }

        lastImmediateHotPathFrameStatsPublishTime = currentTime
        let elapsed = max(currentTime - frameRateWindowStartTime, 0.000_001)
        let estimatedFramesPerSecond = max(Int((Double(max(frameRateFrameCount, 1)) / elapsed).rounded()), 0)
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
        let frameStats = makeFrameStats(
            framesPerSecond: estimatedFramesPerSecond,
            averageFrameTimeMilliseconds: averageFrameInterval * 1_000,
            frameTimeJitterMilliseconds: sqrt(frameIntervalVariance) * 1_000,
            worstFrameTimeMilliseconds: worstFrameInterval * 1_000
        )
        lastFrameStats = frameStats
        onFrameStatsChanged?(frameStats)
    }

    private func makeFrameStats(
        framesPerSecond: Int,
        averageFrameTimeMilliseconds: Double,
        frameTimeJitterMilliseconds: Double,
        worstFrameTimeMilliseconds: Double
    ) -> TimelineFrameStats {
        let waveformBufferDiagnostics = waveformShaderBufferStore.diagnostics()
        return TimelineFrameStats(
            framesPerSecond: framesPerSecond,
            averageFrameTimeMilliseconds: averageFrameTimeMilliseconds,
            frameTimeJitterMilliseconds: frameTimeJitterMilliseconds,
            worstFrameTimeMilliseconds: worstFrameTimeMilliseconds,
            waveformRenderer: frameStatsWaveformRenderer,
            cpuWaveformVertexCount: frameStatsCPUWaveformVertexCount,
            gpuWaveformDrawCount: frameStatsGPUWaveformDrawCount,
            shaderBufferUploadCount: frameStatsShaderBufferUploadCount,
            shaderBufferUploadByteCount: frameStatsShaderBufferUploadByteCount,
            shaderBufferCount: waveformBufferDiagnostics.bufferCount,
            shaderBufferByteCount: waveformBufferDiagnostics.byteCount,
            shaderBufferUploadInFlightCount: waveformBufferDiagnostics.inFlightCount,
            waveformMipCacheCount: waveformMipCacheDiagnostics().cacheCount,
            cpuWaveformFallbackDrawCount: frameStatsCPUWaveformFallbackDrawCount,
            waveformFallbackDrawCount: frameStatsWaveformFallbackDrawCount,
            waveformLastGoodHoldCount: frameStatsWaveformLastGoodHoldCount,
            waveformResidentMissCount: frameStatsWaveformResidentMissCount,
            waveformHotPathViolationCount: frameStatsWaveformHotPathViolationCount,
            waveformHotPathReason: frameStatsWaveformHotPathReason,
            gpuResidentWaveformMode: frameStatsGPUResidentWaveformMode,
            gpuResidentShadowSourceCount: frameStatsGPUResidentShadowSourceCount,
            gpuResidentShadowRequestCount: frameStatsGPUResidentShadowRequestCount,
            gpuResidentShadowVisibleTileCount: frameStatsGPUResidentShadowVisibleTileCount,
            gpuResidentShadowDrawBatchCount: frameStatsGPUResidentShadowDrawBatchCount,
            gpuResidentShadowDrawInstanceCount: frameStatsGPUResidentShadowDrawInstanceCount,
            effectVertexCount: frameStatsEffectVertexCount,
            effectDroppedVertexCount: frameStatsEffectDroppedVertexCount,
            transientParticleCount: frameStatsTransientParticleCount,
            deletionEffectCount: frameStatsDeletionEffectCount,
            playheadContactEventCount: frameStatsPlayheadContactEventCount
        )
    }

    private func waveformMipCacheDiagnostics() -> (cacheCount: Int, inFlightCount: Int) {
        waveformMipLevelCacheLock.lock()
        defer {
            waveformMipLevelCacheLock.unlock()
        }

        return (waveformMipLevelCache.count, waveformMipLevelBuildsInFlight.count)
    }

    private func resetFrameDiagnosticsForNextFrame() {
        frameStatsWaveformRenderer = "gpu"
        frameStatsCPUWaveformVertexCount = 0
        frameStatsGPUWaveformDrawCount = 0
        _ = waveformShaderBufferStore.drainPublishedBufferStats()
        frameStatsShaderBufferUploadCount = 0
        frameStatsShaderBufferUploadByteCount = 0
        frameStatsCPUWaveformFallbackDrawCount = 0
        frameStatsWaveformFallbackDrawCount = 0
        frameStatsWaveformLastGoodHoldCount = 0
        frameStatsWaveformResidentMissCount = 0
        frameStatsWaveformHotPathViolationCount = 0
        frameStatsWaveformHotPathReason = ""
        frameStatsGPUResidentWaveformMode = WaveformGPUResidentWaveformsFeatureFlags.modeDescription
        frameStatsGPUResidentShadowSourceCount = 0
        frameStatsGPUResidentShadowRequestCount = 0
        frameStatsGPUResidentShadowVisibleTileCount = 0
        frameStatsGPUResidentShadowDrawBatchCount = 0
        frameStatsGPUResidentShadowDrawInstanceCount = 0
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
            projectDuration: renderState.duration ?? 0,
            viewportStart: renderState.viewport.startProgress,
            viewportDuration: renderState.viewport.durationProgress,
            trackCount: max(renderState.tracks.count, 1),
            trackHeight: trackLayout.trackHeight,
            trackScrollOffset: trackLayout.scrollOffset,
            rulerLaneHeight: trackLayout.rulerLaneHeight
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

    private func visibleTrackWaveformMipsAreDisplayable(
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]]
    ) -> Bool {
        guard
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0
        else {
            return true
        }

        let tracks = renderState.tracks
        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
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
                trackDuration / projectDuration > 0,
                let mipLevels = trackWaveformMipLevels[track.id],
                let mipLevel = waveformMipLevel(
                    for: drawableSize,
                    renderState: renderState,
                    mipLevels: mipLevels
                )
            else {
                return false
            }

            guard waveformMipLevelIsDisplayable(
                mipLevel,
                track: track,
                drawableSize: drawableSize,
                backingScale: lastRenderBackingScale,
                renderState: renderState
            ) else {
                return false
            }
        }

        return true
    }

    private func waveformMipLevelIsDisplayableForPrimaryTrack(
        _ mipLevel: WaveformMipLevel,
        drawableSize: CGSize,
        renderState: TimelineRenderState
    ) -> Bool {
        let primaryTrack = renderState.tracks.first {
            $0.hasWaveform && $0.durationHint?.isFinite == true && ($0.durationHint ?? 0) > 0
        } ?? TimelineRenderState.Track(
            id: currentPrimaryWaveformTrackID ?? UUID(),
            waveformVersion: 0,
            waveformOverview: nil,
            durationHint: renderState.duration ?? mipLevel.overview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            hasWaveform: true
        )

        return waveformMipLevelIsDisplayable(
            mipLevel,
            track: primaryTrack,
            drawableSize: drawableSize,
            backingScale: lastRenderBackingScale,
            renderState: renderState
        )
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
        mipLevelSnapshot: WaveformMipLevelSnapshot,
        displayTimestamp: CFTimeInterval,
        followsLiveViewport: Bool,
        allowsPreparation: Bool = true
    ) -> WaveformDrawCache? {
        guard
            let previousRenderState = previousTransitionRenderState(
                withCurrentState: renderState,
                displayTimestamp: displayTimestamp,
                followsLiveViewport: followsLiveViewport
            )
        else {
            return nil
        }

        return cachedWaveformVertices(
            drawableSize: drawableSize,
            renderState: previousRenderState,
            mipLevels: [],
            trackWaveformMipLevels: mipLevelSnapshot.previousByTrack,
            target: .previous,
            usesTrackLanes: true,
            allowsPreparation: allowsPreparation
        )
    }

    private func previousTransitionRenderState(
        withCurrentState renderState: TimelineRenderState,
        displayTimestamp: CFTimeInterval,
        followsLiveViewport: Bool
    ) -> TimelineRenderState? {
        let previousTracks = previousTransitionTracks(withCurrentMixFrom: renderState.tracks)
        guard !previousTracks.isEmpty else {
            return nil
        }

        let previousRenderState = renderState.replacingTracks(previousTracks)
        if followsLiveViewport, isViewportInteractionHot(at: displayTimestamp) {
            return previousRenderState.withViewport(renderState.viewport)
        }

        return previousRenderState.withViewport(previousTransitionViewport ?? renderState.viewport)
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
                hasWaveform: previousTrack.hasWaveform,
                clipRanges: previousTrack.clipRanges,
                waveformSegments: previousTrack.waveformSegments,
                waveformTileSource: currentTrack?.waveformTileSource ?? previousTrack.waveformTileSource
            )
        }
    }

    private func cachedWaveformVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        mipLevels: [WaveformMipLevel],
        trackWaveformMipLevels: [UUID: [WaveformMipLevel]],
        target: WaveformGeometryTarget,
        usesTrackLanes: Bool,
        allowsPreparation: Bool = true
    ) -> WaveformDrawCache? {
        if usesTrackLanes, renderState.hasWaveforms {
            guard visibleTrackWaveformMipsAreDisplayable(
                drawableSize: drawableSize,
                renderState: renderState,
                trackWaveformMipLevels: trackWaveformMipLevels
            ) else {
                return nil
            }

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
            if !allowsPreparation {
                return waveformGeometryStore.fallback(
                    contentSignature: contentSignature,
                    target: target
                ).map { waveformDrawCache($0, renderViewport: renderState.viewport) }
            }

            let visualSignature = waveformVisualSignature(renderState: renderState)
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
            ).map { waveformDrawCache($0, renderViewport: renderState.viewport) }
        }

        guard
            let mipLevel = waveformMipLevel(
                for: drawableSize,
                renderState: renderState,
                mipLevels: mipLevels
            ),
            !mipLevel.overview.isEmpty,
            waveformMipLevelIsDisplayableForPrimaryTrack(
                mipLevel,
                drawableSize: drawableSize,
                renderState: renderState
            )
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
        if !allowsPreparation {
            return waveformGeometryStore.fallback(
                contentSignature: contentSignature,
                target: target
            ).map { waveformDrawCache($0, renderViewport: renderState.viewport) }
        }

        let visualSignature = waveformVisualSignature(renderState: renderState)
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
        ).map { waveformDrawCache($0, renderViewport: renderState.viewport) }
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

    private func selectionDragStrength(for velocityPixelsPerSecond: Float) -> Float {
        let tuning = selectionDragWaveformTuning
        guard velocityPixelsPerSecond > selectionDragMotionEpsilonPixelsPerSecond else {
            return 0
        }

        let range = max(tuning.fullSpeedPixelsPerSecond - tuning.minimumSpeedPixelsPerSecond, 1)
        let speedEnergy = smoothStep((velocityPixelsPerSecond - tuning.minimumSpeedPixelsPerSecond) / range)
        return min(max(selectionDragSlowContactStrengthFloor + (1 - selectionDragSlowContactStrengthFloor) * speedEnergy, 0), 1)
    }

    private func isSelectionDragEffectActive(
        _ snapshot: TimelineSelectionDragSnapshot?,
        displayTimestamp: CFTimeInterval
    ) -> Bool {
        guard let snapshot else {
            return false
        }

        return snapshot.selection.durationProgress > 0 &&
            displayTimestamp - snapshot.timestamp <= max(
                selectionDragEffectFadeDuration,
                selectionDragWaveformTuning.contactLifetime
            )
    }

    private func selectionDragWaveformTuningVectors(
        drawableSize: CGSize,
        renderState: TimelineRenderState
    ) -> (primary: SIMD4<Float>, secondary: SIMD4<Float>) {
        let tuning = selectionDragWaveformTuning
        let width = Float(max(drawableSize.width, 1))
        let viewportDuration = renderState.viewport.durationProgress
        let frontRadiusProgress = max(tuning.frontRadiusPixels / width * viewportDuration, 0.000_001)
        let backRadiusProgress = max(tuning.backRadiusPixels / width * viewportDuration, 0.000_001)
        let coreRadiusProgress = max(
            tuning.contactCoreRadiusPixels / width * viewportDuration,
            0.000_001
        )
        return (
            SIMD4<Float>(
                frontRadiusProgress,
                backRadiusProgress,
                coreRadiusProgress,
                Float(tuning.maximumContactCount)
            ),
            SIMD4<Float>(
                tuning.maximumExpansion,
                tuning.maximumWhitening,
                0,
                0
            )
        )
    }

    private func selectionDragWaveformContactVectors(
        _ contacts: [SelectionDragWaveformContact],
        trackID: UUID,
        displayTimestamp: CFTimeInterval
    ) -> SelectionDragWaveformContactVectors {
        let tuning = selectionDragWaveformTuning
        let maximumCount = min(
            max(tuning.maximumContactCount, 0),
            maximumSelectionDragShaderContactCount,
            8
        )
        guard maximumCount > 0, !contacts.isEmpty else {
            return .empty
        }

        var eligibleVectors: [SIMD4<Float>] = []
        eligibleVectors.reserveCapacity(min(contacts.count, 64))
        for contact in contacts {
            guard contact.trackID == nil || contact.trackID == trackID else {
                continue
            }

            let age = max(displayTimestamp - contact.birthTimestamp, 0)
            guard age <= tuning.contactLifetime else {
                continue
            }

            let lifetimeProgress = min(max(Float(age / tuning.contactLifetime), 0), 1)
            let inverseLifetimeProgress = max(1 - lifetimeProgress, 0)
            let timeFade = inverseLifetimeProgress * inverseLifetimeProgress * (3 - 2 * inverseLifetimeProgress)
            let strength = min(max(contact.strength * timeFade, 0), 1)
            guard strength > selectionDragWaveformContactMinimumStrength else {
                continue
            }

            eligibleVectors.append(SIMD4<Float>(
                min(max(contact.progress, 0), 1),
                strength,
                contact.direction >= 0 ? 1 : -1,
                1
            ))
        }

        guard !eligibleVectors.isEmpty else {
            return .empty
        }

        if eligibleVectors.count <= maximumCount {
            return SelectionDragWaveformContactVectors(eligibleVectors)
        }

        var selectedVectors: [SIMD4<Float>] = []
        selectedVectors.reserveCapacity(maximumCount)
        let lastIndex = eligibleVectors.count - 1
        for slot in 0..<maximumCount {
            let position = maximumCount == 1 ?
                Double(lastIndex) :
                Double(slot) / Double(maximumCount - 1) * Double(lastIndex)
            selectedVectors.append(eligibleVectors[min(max(Int(position.rounded()), 0), lastIndex)])
        }

        return SelectionDragWaveformContactVectors(selectedVectors)
    }

    private func selectionDragWaveformEffectBounds(
        selection: TimelineSelection?,
        contacts: [SelectionDragWaveformContact],
        trackID: UUID,
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        displayTimestamp: CFTimeInterval
    ) -> SIMD2<Float>? {
        guard
            let selection,
            selection.durationProgress > 0,
            selection.trackID == nil || selection.trackID == trackID,
            drawableSize.width > 0
        else {
            return nil
        }

        let tuning = selectionDragWaveformTuning
        let selectionLower = selection.startProgressFloat
        let selectionUpper = selection.endProgressFloat
        let radiusPixels = max(
            tuning.frontRadiusPixels,
            tuning.backRadiusPixels,
            tuning.contactCoreRadiusPixels
        ) + 2
        let radiusProgress = max(
            radiusPixels / Float(drawableSize.width) * renderState.viewport.durationProgress,
            0.000_001
        )
        var lower = Float.greatestFiniteMagnitude
        var upper = -Float.greatestFiniteMagnitude
        for contact in contacts where contact.trackID == nil || contact.trackID == trackID {
            let age = max(displayTimestamp - contact.birthTimestamp, 0)
            guard age <= tuning.contactLifetime else {
                continue
            }

            let lifetimeProgress = min(max(Float(age / tuning.contactLifetime), 0), 1)
            let inverseLifetimeProgress = max(1 - lifetimeProgress, 0)
            let timeFade = inverseLifetimeProgress * inverseLifetimeProgress * (3 - 2 * inverseLifetimeProgress)
            let strength = min(max(contact.strength * timeFade, 0), 1)
            guard strength > selectionDragWaveformContactMinimumStrength else {
                continue
            }

            let progress = min(max(contact.progress, 0), 1)
            let contactLower = max(selectionLower, progress - radiusProgress)
            let contactUpper = min(selectionUpper, progress + radiusProgress)
            guard contactUpper > contactLower else {
                continue
            }

            lower = min(lower, contactLower)
            upper = max(upper, contactUpper)
        }

        guard lower.isFinite, upper.isFinite, upper > lower else {
            return nil
        }

        return SIMD2<Float>(lower, upper)
    }

    private func makeSelectionDragEffectUniform(
        snapshot: TimelineSelectionDragSnapshot?,
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        displayTimestamp: CFTimeInterval
    ) -> SelectionDragEffectUniform? {
        guard
            let snapshot,
            renderState.hasWaveforms,
            snapshot.selection.durationProgress > 0
        else {
            return nil
        }

        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return nil
        }

        let age = max(displayTimestamp - snapshot.timestamp, 0)
        guard age <= selectionDragEffectFadeDuration else {
            return nil
        }

        let fadeProgress = min(max(Float(age / selectionDragEffectFadeDuration), 0), 1)
        let freshness = 1 - smoothStep(fadeProgress)
        let speedStrength = selectionDragStrength(for: snapshot.velocityPixelsPerSecond)
        let strength = speedStrength * freshness
        guard strength > 0.001 else {
            return nil
        }

        let edgeX = renderState.viewport.viewportProgress(forTimelineProgress: snapshot.leadingProgress)
        guard edgeX > -0.04, edgeX < 1.04 else {
            return nil
        }

        guard let verticalRange = selectionVerticalRange(
            for: snapshot.selection,
            renderState: renderState,
            drawableSize: drawableSize
        ) else {
            return nil
        }

        let laneTop = max(verticalRange.top, 0)
        let laneBottom = min(verticalRange.bottom, 1)
        guard laneBottom > laneTop else {
            return nil
        }

        let laneHeightPixels = max((laneBottom - laneTop) * height, 1)
        let halfWidthPixels = 12 + 18 * strength
        let effectLeft = edgeX - halfWidthPixels / width
        let effectRight = edgeX + halfWidthPixels / width
        guard effectRight > 0, effectLeft < 1 else {
            return nil
        }

        let clampedLeft = max(effectLeft, 0)
        let clampedRight = min(effectRight, 1)
        let edgeLocalX = min(max((edgeX - clampedLeft) / max(clampedRight - clampedLeft, 0.000_001), 0), 1)
        let viewport = renderState.viewport
        let viewportStart = Double(viewport.startProgress)
        let viewportDuration = max(Double(viewport.durationProgress), 0.000_000_001)
        let selectionLeft = Float((snapshot.selection.startProgress - viewportStart) / viewportDuration)
        let selectionRight = Float((snapshot.selection.endProgress - viewportStart) / viewportDuration)
        let visibleSelectionLeft = max(selectionLeft, 0)
        let visibleSelectionRight = min(selectionRight, 1)
        let effectWidthPixels = max((clampedRight - clampedLeft) * width, 1)
        let selectionLeftLocalPixels = ((visibleSelectionLeft - clampedLeft) / max(clampedRight - clampedLeft, 0.000_001)) * effectWidthPixels
        let selectionRightLocalPixels = ((visibleSelectionRight - clampedLeft) / max(clampedRight - clampedLeft, 0.000_001)) * effectWidthPixels
        let visibleSelectionWidthPixels = max((visibleSelectionRight - visibleSelectionLeft) * width, 1)
        let cornerRadiusPixels = min(
            max(8, laneHeightPixels * 0.075),
            min(18, visibleSelectionWidthPixels * 0.5)
        )
        let seed = Float(UInt32(truncatingIfNeeded: snapshot.selection.trackID?.hashValue ?? 0) & 0x00FF_FFFF)
        return SelectionDragEffectUniform(
            rect: SIMD4<Float>(
                clampedLeft,
                clampedRight,
                laneTop,
                laneBottom
            ),
            metrics: SIMD4<Float>(
                max((clampedRight - clampedLeft) * width, 1),
                laneHeightPixels,
                halfWidthPixels,
                edgeLocalX
            ),
            effect: SIMD4<Float>(
                strength,
                Float(age),
                seed,
                snapshot.direction == 0 ? 1 : snapshot.direction
            ),
            color: SIMD4<Float>(
                0.58 + 0.36 * strength,
                0.96,
                1.0,
                0.30 + 0.52 * strength
            ),
            mask: SIMD4<Float>(
                selectionLeftLocalPixels,
                selectionRightLocalPixels,
                cornerRadiusPixels,
                0
            )
        )
    }

    private func makeSelectionOverlayUniform(
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        displayTimestamp: CFTimeInterval,
        fisheye: SIMD4<Float>,
        dragSnapshot: TimelineSelectionDragSnapshot?
    ) -> SelectionOverlayUniform? {
        guard
            let selection = renderState.selection,
            renderState.hasWaveforms,
            selection.durationProgress > 0
        else {
            return nil
        }

        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            return nil
        }

        let viewport = renderState.viewport
        let viewportStart = Double(viewport.startProgress)
        let viewportDuration = max(Double(viewport.durationProgress), 0.000_000_001)
        let left = Float((selection.startProgress - viewportStart) / viewportDuration)
        let right = Float((selection.endProgress - viewportStart) / viewportDuration)
        guard right > 0, left < 1 else {
            return nil
        }

        guard let verticalRange = selectionVerticalRange(
            for: selection,
            renderState: renderState,
            drawableSize: drawableSize
        ) else {
            return nil
        }

        let visibleLeft = max(left, 0)
        let visibleRight = min(right, 1)
        guard visibleRight > visibleLeft else {
            return nil
        }

        let visibleWidthPixels = max((visibleRight - visibleLeft) * width, 1)
        let visibleHeightPixels = max((verticalRange.bottom - verticalRange.top) * height, 1)
        let cornerRadiusPixels = min(
            max(8, visibleHeightPixels * 0.075),
            min(18, visibleWidthPixels * 0.5)
        )

        let activeProcessingSelection = processingSelectionProgress.flatMap { progress in
            progress.selection == selection ? progress : nil
        }
        let pulseOpacityMultiplier: Float
        let progressFraction: Float
        if let activeProcessingSelection {
            let elapsed = max(displayTimestamp - activeProcessingSelection.pulseStartTimestamp, 0)
            let wave = 0.5 + 0.5 * sin(Float(elapsed) * 2 * .pi * 1.15)
            pulseOpacityMultiplier = 0.76 + wave * 0.24
            if let fractionCompleted = interpolatedProcessingSelectionFraction(
                activeProcessingSelection,
                at: displayTimestamp
            ) {
                let fillRight = left + (right - left) * fractionCompleted
                progressFraction = min(max((fillRight - visibleLeft) / max(visibleRight - visibleLeft, 0.000_001), 0), 1)
            } else {
                progressFraction = -1
            }
        } else {
            pulseOpacityMultiplier = 1
            progressFraction = -1
        }

        let baseColor = isModalBackdropActive ?
            SIMD4<Float>(0.74, 0.76, 0.77, 0.16 * pulseOpacityMultiplier) :
            SIMD4<Float>(0.02, 0.82, 0.88, 0.18 * pulseOpacityMultiplier)
        let progressColor = isModalBackdropActive ?
            SIMD4<Float>(0.92, 0.92, 0.92, 0.20 + 0.10 * pulseOpacityMultiplier) :
            SIMD4<Float>(0.28, 0.96, 1.0, 0.20 + 0.10 * pulseOpacityMultiplier)
        let copyFlash: Float
        if let selectionCopyFlashStartTime {
            let elapsed = displayTimestamp - selectionCopyFlashStartTime
            if elapsed >= 0, elapsed <= selectionCopyFlashDuration {
                let progress = min(max(Float(elapsed / selectionCopyFlashDuration), 0), 1)
                copyFlash = 1 - smoothStep(progress)
            } else {
                if elapsed > selectionCopyFlashDuration {
                    self.selectionCopyFlashStartTime = nil
                }
                copyFlash = 0
            }
        } else {
            copyFlash = 0
        }

        var dragEdgeLocalX: Float = -1
        var dragStrength: Float = 0
        var dragDirection: Float = 1
        if
            let dragSnapshot,
            dragSnapshot.selection == selection,
            dragSnapshot.selection.durationProgress > 0
        {
            let age = max(displayTimestamp - dragSnapshot.timestamp, 0)
            if age <= selectionDragEffectFadeDuration {
                let fadeProgress = min(max(Float(age / selectionDragEffectFadeDuration), 0), 1)
                let freshness = 1 - smoothStep(fadeProgress)
                dragStrength = selectionDragStrength(for: dragSnapshot.velocityPixelsPerSecond) * freshness
                let edgeX = renderState.viewport.viewportProgress(forTimelineProgress: dragSnapshot.leadingProgress)
                dragEdgeLocalX = min(max((edgeX - visibleLeft) / max(visibleRight - visibleLeft, 0.000_001), 0), 1)
                dragDirection = dragSnapshot.direction == 0 ? 1 : dragSnapshot.direction
            }
        }

        let seed = Float(UInt32(truncatingIfNeeded: selection.trackID?.hashValue ?? 0) & 0x00FF_FFFF)
        return SelectionOverlayUniform(
            rect: SIMD4<Float>(
                visibleLeft,
                visibleRight,
                verticalRange.top,
                verticalRange.bottom
            ),
            metrics: SIMD4<Float>(
                visibleWidthPixels,
                visibleHeightPixels,
                cornerRadiusPixels,
                progressFraction
            ),
            style: SIMD4<Float>(
                dragEdgeLocalX,
                dragStrength,
                dragDirection,
                seed + Float(displayTimestamp.truncatingRemainder(dividingBy: 2048))
            ),
            pulse: SIMD4<Float>(
                copyFlash,
                Float(selectionCopyFlashDuration),
                0,
                0
            ),
            baseColor: baseColor,
            progressColor: progressColor,
            fisheye: fisheye
        )
    }

    private func drawSelectionOverlay(
        uniform: SelectionOverlayUniform?,
        encoder: MTLRenderCommandEncoder
    ) {
        guard var uniform else {
            return
        }

        encoder.setRenderPipelineState(selectionOverlayPipelineState)
        encoder.setVertexBuffer(waveformQuadVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniform,
            length: MemoryLayout<SelectionOverlayUniform>.stride,
            index: 1
        )
        encoder.setFragmentBytes(
            &uniform,
            length: MemoryLayout<SelectionOverlayUniform>.stride,
            index: 1
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawLoopRange(
        uniform: LoopRegionUniform?,
        encoder: MTLRenderCommandEncoder
    ) {
        guard var uniform else {
            return
        }

        encoder.setRenderPipelineState(loopRegionPipelineState)
        encoder.setVertexBuffer(waveformQuadVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniform,
            length: MemoryLayout<LoopRegionUniform>.stride,
            index: 1
        )
        encoder.setFragmentBytes(
            &uniform,
            length: MemoryLayout<LoopRegionUniform>.stride,
            index: 1
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawSelectionDragEffect(
        uniform: SelectionDragEffectUniform?,
        encoder: MTLRenderCommandEncoder
    ) {
        guard var uniform else {
            return
        }

        encoder.setRenderPipelineState(selectionDragEffectPipelineState)
        encoder.setVertexBuffer(waveformQuadVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniform,
            length: MemoryLayout<SelectionDragEffectUniform>.stride,
            index: 1
        )
        encoder.setFragmentBytes(
            &uniform,
            length: MemoryLayout<SelectionDragEffectUniform>.stride,
            index: 1
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
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

        func appendVerticalGridLine(at viewportProgress: Float) -> Bool {
            let x = viewportProgress * width
            if x < -targetPixelStep {
                return true
            }
            if x > width + targetPixelStep {
                return false
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
            return true
        }

        if
            let projectDuration = renderState.duration,
            projectDuration.isFinite,
            projectDuration > 0
        {
            let visibleSeconds = max(Double(viewport.durationProgress) * projectDuration, 0.000_001)
            let approximateSecondsStep = visibleSeconds * Double(targetPixelStep / max(width, 1))
            let secondsStep = max(niceSecondsStep(approximateSecondsStep), 0.000_001)
            let visibleStartSeconds = Double(viewport.startProgress) * projectDuration
            let visibleEndSeconds = Double(viewport.endProgress) * projectDuration
            var gridSeconds = floor(visibleStartSeconds / secondsStep) * secondsStep

            while gridSeconds <= visibleEndSeconds + secondsStep {
                let timelineProgress = Float(gridSeconds / projectDuration)
                guard appendVerticalGridLine(at: viewport.viewportProgress(forTimelineProgress: timelineProgress)) else {
                    break
                }
                gridSeconds += secondsStep
            }
        } else {
            let approximateProgressStep = max(viewport.durationProgress * targetPixelStep / width, 0.0001)
            let progressStep = niceProgressStep(approximateProgressStep)
            let firstGridProgress = floor(viewport.startProgress / progressStep) * progressStep
            var gridProgress = firstGridProgress

            while gridProgress <= viewport.endProgress + progressStep {
                guard appendVerticalGridLine(at: viewport.viewportProgress(forTimelineProgress: gridProgress)) else {
                    break
                }
                gridProgress += progressStep
            }
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

        let anySolo = renderState.hasSoloedTrack
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

            let sourceDuration = max(highResolutionMip.overview.duration, trackDuration)
            let sourceBinsPerSecond = Double(binCount) / max(sourceDuration, 0.000001)
            let outputBinCount = max(Int((trackDuration * sourceBinsPerSecond).rounded(.up)), 1)
            let minimumSpacingBins = max(Int((sourceBinsPerSecond * transientParticleMinimumSpacing).rounded(.up)), 1)
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
            let neighborhoodRadius = max(min(Int((sourceBinsPerSecond * 0.035).rounded(.up)), 24), 3)
            let waveformSegments = track.waveformSegments.isEmpty ? [
                TimelineRenderState.Track.WaveformSegment(
                    outputStartProgress: 0,
                    outputEndProgress: 1,
                    sourceStartProgress: 0,
                    sourceEndProgress: 1
                )
            ] : track.waveformSegments

            for waveformSegment in waveformSegments {
                let outputStart = min(max(waveformSegment.outputStartProgress * trackDurationProgress, 0), trackDurationProgress)
                let outputEnd = min(max(waveformSegment.outputEndProgress * trackDurationProgress, outputStart), trackDurationProgress)
                let outputWidth = outputEnd - outputStart
                let sourceStart = min(max(waveformSegment.sourceStartProgress, 0), 1)
                let sourceEnd = min(max(waveformSegment.sourceEndProgress, sourceStart), 1)
                let sourceWidth = sourceEnd - sourceStart
                guard outputWidth > 0.0000001, sourceWidth > 0.0000001 else {
                    continue
                }

                let scanStart = max(previousProgress, outputStart)
                let scanEnd = min(clampedProgress, outputEnd)
                guard scanStart < scanEnd else {
                    continue
                }

                let scanStartSegmentProgress = min(max((scanStart - outputStart) / outputWidth, 0), 1)
                let scanEndSegmentProgress = min(max((scanEnd - outputStart) / outputWidth, 0), 1)
                let sourceScanStart = sourceStart + sourceWidth * scanStartSegmentProgress
                let sourceScanEnd = sourceStart + sourceWidth * scanEndSegmentProgress
                let firstIndex = max(Int(floor(sourceScanStart * Float(binCount))) - 1, 0)
                let lastIndex = min(Int(ceil(sourceScanEnd * Float(binCount))) + 1, binCount - 1)
                guard firstIndex <= lastIndex else {
                    continue
                }

                for index in firstIndex...lastIndex {
                    let sourceLocalX = (Float(index) + 0.5) / Float(binCount)
                    guard sourceLocalX >= sourceStart, sourceLocalX <= sourceEnd else {
                        continue
                    }

                    let segmentProgress = min(max((sourceLocalX - sourceStart) / sourceWidth, 0), 1)
                    let timelineProgress = outputStart + outputWidth * segmentProgress
                    guard timelineProgress >= scanStart, timelineProgress <= scanEnd else {
                        continue
                    }

                    let outputTrackProgress = trackDurationProgress > 0 ?
                        min(max(timelineProgress / trackDurationProgress, 0), 1) :
                        0
                    let outputTriggerBin = Int((outputTrackProgress * Float(outputBinCount)).rounded(.down))
                    guard outputTriggerBin - latestTriggeredBin >= minimumSpacingBins else {
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

                    let viewportX = viewport.viewportProgress(forTimelineProgress: timelineProgress)
                    guard viewportX >= -0.08, viewportX <= 1.08 else {
                        continue
                    }

                    let sourceBinStart = Float(index) / Float(binCount)
                    let sourceBinEnd = Float(index + 1) / Float(binCount)
                    let outputBinStartProgress = min(max((sourceBinStart - sourceStart) / sourceWidth, 0), 1)
                    let outputBinEndProgress = min(max((sourceBinEnd - sourceStart) / sourceWidth, 0), 1)
                    let outputBinStart = outputStart + outputWidth * outputBinStartProgress
                    let outputBinEnd = outputStart + outputWidth * outputBinEndProgress
                    let previewGainAmount = previewGain(
                        forBinStart: outputBinStart,
                        end: outputBinEnd,
                        trackID: track.id,
                        renderState: renderState
                    )
                    let segmentGain = waveformSegment.gainStart +
                        (waveformSegment.gainEnd - waveformSegment.gainStart) *
                        smoothStep(segmentProgress)
                    let gain = previewGainAmount * max(segmentGain, 0)
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
                    let baseSeed = transientParticleSeed(trackID: track.id, binIndex: index) &+
                        UInt64(max(outputTriggerBin, 0)) &* 0x9E37_79B9_7F4A_7C15

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

                    latestTriggeredBin = outputTriggerBin
                }
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
        let hadEffects = !deletionEffects.isEmpty
        for index in deletionEffects.indices {
            if deletionEffects[index].birthTimestamp < 0 {
                deletionEffects[index].birthTimestamp = displayTimestamp
            }
        }
        deletionEffects.removeAll { effect in
            effect.birthTimestamp >= 0 &&
                displayTimestamp - effect.birthTimestamp >= deletionEffectDuration + deletionEffectLifetimePadding
        }
        let effects = deletionEffects
        if hadEffects, effects.isEmpty {
            lastDeletionEffectsClearedTimestamp = displayTimestamp
        }
        deletionEffectLock.unlock()
        frameStatsDeletionEffectCount = effects.count
        return effects
    }

    private func hasDeletionEffectsInFlight() -> Bool {
        deletionEffectLock.lock()
        let hasEffects = !deletionEffects.isEmpty
        deletionEffectLock.unlock()
        return hasEffects
    }

    private func deletionHandoffWaveformDemotionProtectionIsActive(at displayTimestamp: CFTimeInterval) -> Bool {
        deletionEffectLock.lock()
        let hasEffects = !deletionEffects.isEmpty
        let clearedAt = lastDeletionEffectsClearedTimestamp
        deletionEffectLock.unlock()
        if hasEffects {
            return true
        }
        return clearedAt.isFinite &&
            displayTimestamp - clearedAt >= 0 &&
            displayTimestamp - clearedAt <= deletionHandoffWaveformDemotionHoldDuration
    }

    private func drawDeletionEffects(
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        baseFisheye: SIMD4<Float>,
        displayTimestamp: CFTimeInterval,
        effects: [DeletionEffect],
        encoder: MTLRenderCommandEncoder
    ) {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else {
            frameStatsDeletionEffectCount = 0
            return
        }

        guard !effects.isEmpty else {
            return
        }

        let wallVertices = deletionWallVertices(
            drawableSize: drawableSize,
            renderState: renderState,
            displayTimestamp: displayTimestamp,
            effects: effects
        )
        if !wallVertices.isEmpty {
            encoder.setRenderPipelineState(pipelineState)
            draw(vertices: wallVertices, primitiveType: .triangle, encoder: encoder)
        }

        encoder.setRenderPipelineState(deletionEffectPipelineState)
        encoder.setVertexBuffer(waveformQuadVertexBuffer, offset: 0, index: 0)
        for effect in effects {
            guard
                let binBuffer = effect.capturedBinBuffer,
                effect.capturedBinCount > 0,
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
    }

    private func deletionWallVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        displayTimestamp: CFTimeInterval,
        effects: [DeletionEffect]
    ) -> [TimelineVertex] {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard
            width > 0,
            height > 0,
            let verticalSpan = visibleTimelineTrackSpan(renderState: renderState, drawableSize: drawableSize)
        else {
            return []
        }

        var weightedLineX: Float = 0
        var totalLineWeight: Float = 0
        var activeEnergy: Float = 0
        var activeCount: Float = 0

        for effect in effects {
            let birthTimestamp = effect.birthTimestamp >= 0 ? effect.birthTimestamp : displayTimestamp
            let age = max(displayTimestamp - birthTimestamp, 0)
            let progress = min(max(Float(age / deletionEffectDuration), 0), 1)
            let window = smoothStep(edge0: 0.006, edge1: 0.055, value: progress) *
                (1 - smoothStep(edge0: 0.965, edge1: 1, value: progress))
            guard window > 0.0001 else {
                continue
            }

            var left = effect.visualAnchor.x
            var right = effect.visualAnchor.y
            if right < left {
                swap(&left, &right)
            }

            let lineX = min(max(left * width, 0), width)
            weightedLineX += lineX * window
            totalLineWeight += window

            let slideProgress = deletionSlideProgress(progress)
            let energy = deletionWallEnergy(for: effect, slideProgress: slideProgress)
            activeEnergy += (0.10 + energy * 0.90) * window
            activeCount += 1
        }

        guard totalLineWeight > 0, activeCount > 0 else {
            return []
        }

        let lineX = weightedLineX / totalLineWeight
        let wallWidthPixels: Float = 20
        let leftX = min(max(lineX, 0), width)
        let rightX = min(max(leftX + wallWidthPixels, leftX), width)
        guard rightX - leftX > 0.5 else {
            return []
        }

        let normalizedEnergy = min(max(activeEnergy / activeCount, 0), 1)
        let alpha = min(max(pow(normalizedEnergy, 0.72) * 0.68, 0), 0.68)
        let top = min(max(verticalSpan.top, 0), 1)
        let bottom = min(max(verticalSpan.bottom, top), 1)
        guard bottom > top else {
            return []
        }

        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(6)
        appendHorizontalGradientRectangle(
            to: &vertices,
            left: leftX / width,
            right: rightX / width,
            top: top,
            bottom: bottom,
            leftColor: SIMD4<Float>(0.88, 0.98, 1.0, alpha),
            rightColor: SIMD4<Float>(0.88, 0.98, 1.0, 0)
        )
        return vertices
    }

    private func visibleTimelineTrackSpan(
        renderState: TimelineRenderState,
        drawableSize: CGSize
    ) -> (top: Float, bottom: Float)? {
        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        let visibleRange = trackLayout.visibleRange(overscan: 0)
        guard !visibleRange.isEmpty else {
            return nil
        }

        var top: Float = 1
        var bottom: Float = 0
        var hasVisibleLane = false
        for trackIndex in visibleRange {
            guard let laneFrame = trackLayout.laneFrame(forTrackIndex: trackIndex), laneFrame.isVisible else {
                continue
            }
            top = min(top, laneFrame.top)
            bottom = max(bottom, laneFrame.bottom)
            hasVisibleLane = true
        }

        guard hasVisibleLane, bottom > top else {
            return nil
        }

        return (top, bottom)
    }

    private func deletionWallEnergy(for effect: DeletionEffect, slideProgress: Float) -> Float {
        let samples = effect.capturedEnergySamples
        guard !samples.isEmpty else {
            return 0.58
        }
        guard samples.count > 1 else {
            return samples[0]
        }

        let samplePosition = min(max(slideProgress, 0), 1) * Float(samples.count - 1)
        let centerIndex = Int(samplePosition.rounded())
        var weightedEnergy: Float = 0
        var totalWeight: Float = 0
        for offset in -3...3 {
            let index = min(max(centerIndex + offset, 0), samples.count - 1)
            let distance = Float(abs(offset))
            let weight = exp(-(distance * distance) / 5.5)
            weightedEnergy += samples[index] * weight
            totalWeight += weight
        }

        return min(max(weightedEnergy / max(totalWeight, 0.000_001), 0), 1)
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
        guard rightViewport > -0.1, leftViewport < 1.1 else {
            return nil
        }

        var leftX = leftViewport * width
        var rightX = rightViewport * width
        if rightX < leftX {
            swap(&leftX, &rightX)
        }
        let minimumEffectWidth: Float = 18
        if rightX - leftX < minimumEffectWidth {
            let centerX = (leftX + rightX) * 0.5
            leftX = centerX - minimumEffectWidth * 0.5
            rightX = centerX + minimumEffectWidth * 0.5
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
        let slideProgress = deletionSlideProgress(progress)
        let effectMode: Float = effect.kind == .insertion ? 2 : 1
        let laneHeight = max(bottomY - topY, 1)
        let projectDuration = max(renderState.duration ?? 0, 0.000_001)
        let waveformStyle = waveformVisualStyle(
            renderState: renderState,
            projectDuration: projectDuration
        )
        let anySolo = renderState.hasSoloedTrack
        let track = selection.trackID.flatMap { trackID in
            renderState.tracks.first { $0.id == trackID }
        }
        let isAudible = track.map { isTrackAudible($0, anySolo: anySolo) } ?? true
        let volumeScale = min(max(track?.volume ?? 1, 0), 1.8)
        let baseGray = waveformBaseGray * (isAudible ? 1.0 : 0.68)
        let alpha = isAudible ? Float(1) : Float(0.26)
        let overlayLeftX = min(max(leftX, 0), width)
        let overlayRightX = min(max(rightX, overlayLeftX), width)
        let overlayTopY = min(max(topY, 0), height)
        let overlayBottomY = min(max(bottomY, overlayTopY), height)
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
                overlayTopY / height,
                overlayBottomY / height
            ),
            timing: SIMD4<Float>(
                progress,
                Float(displayTimestamp.truncatingRemainder(dividingBy: 2048)),
                seed,
                Float(max(effect.capturedBinCount, 1))
            ),
            metrics: SIMD4<Float>(
                width,
                height,
                laneHeight,
                Float(deletionEffectDuration)
            ),
            ripple: SIMD4<Float>(
                rightX / width,
                slideProgress,
                effectMode,
                selectionWidth / width
            ),
            waveformStyle: SIMD4<Float>(
                baseGray,
                alpha,
                waveformStyle.spectralAmount,
                volumeScale
            ),
            waveformStyle2: SIMD4<Float>(
                waveformStyle.peakAlpha,
                waveformStyle.bodyAlpha,
                waveformStyle.glowAlpha,
                waveformStyle.glowExpansion
            )
        )
    }

    private func waveformDeletionWarp(
        for track: TimelineRenderState.Track,
        effects: [DeletionEffect],
        displayTimestamp: CFTimeInterval
    ) -> SIMD4<Float> {
        guard let effect = effects.first(where: { effect in
            effect.selection.trackID == nil || effect.selection.trackID == track.id
        }) else {
            return .zero
        }

        let birthTimestamp = effect.birthTimestamp >= 0 ? effect.birthTimestamp : displayTimestamp
        let age = max(displayTimestamp - birthTimestamp, 0)
        let progress = min(max(Float(age / deletionEffectDuration), 0), 1)
        let slideProgress = deletionSlideProgress(progress)
        guard slideProgress > 0.0001 else {
            return .zero
        }

        var left = effect.visualAnchor.x
        var right = effect.visualAnchor.y
        if right < left {
            swap(&left, &right)
        }
        guard right > left else {
            return .zero
        }

        return SIMD4<Float>(
            min(max(left, -1), 2),
            min(max(right, -1), 2),
            min(max(slideProgress, 0), 1),
            effect.kind == .insertion ? 2 : 1
        )
    }

    private func interpolatedProcessingSelectionFraction(
        _ progress: ProcessingSelectionProgress,
        at displayTimestamp: CFTimeInterval
    ) -> Float? {
        guard let targetFraction = progress.targetFraction else {
            return nil
        }

        let startFraction = progress.startFraction ?? targetFraction
        let elapsed = max(displayTimestamp - progress.transitionStartTimestamp, 0)
        let rawProgress = Float(elapsed / max(processingSelectionProgressSmoothingDuration, 0.001))
        let easedProgress = smoothStep(rawProgress)
        return startFraction + (targetFraction - startFraction) * easedProgress
    }

    private func makeSelectionVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState,
        displayTimestamp: CFTimeInterval
    ) -> [TimelineVertex] {
        selectionVertexScratch.removeAll(keepingCapacity: true)
        guard
            let selection = renderState.selection,
            renderState.hasWaveforms,
            selection.durationProgress > 0
        else {
            return selectionVertexScratch
        }

        let viewport = renderState.viewport
        let viewportStart = Double(viewport.startProgress)
        let viewportDuration = max(Double(viewport.durationProgress), 0.000_000_001)
        let left = Float((selection.startProgress - viewportStart) / viewportDuration)
        let right = Float((selection.endProgress - viewportStart) / viewportDuration)
        guard right > 0, left < 1 else {
            return selectionVertexScratch
        }

        let activeProcessingSelection = processingSelectionProgress.flatMap { progress in
            progress.selection == selection ? progress : nil
        }
        let pulseOpacityMultiplier: Float
        if let activeProcessingSelection {
            let elapsed = max(displayTimestamp - activeProcessingSelection.pulseStartTimestamp, 0)
            let wave = 0.5 + 0.5 * sin(Float(elapsed) * 2 * .pi * 1.15)
            pulseOpacityMultiplier = 0.76 + wave * 0.24
        } else {
            pulseOpacityMultiplier = 1
        }

        let baseColor = isModalBackdropActive ?
            SIMD4<Float>(0.72, 0.72, 0.72, 0.18 * pulseOpacityMultiplier) :
            SIMD4<Float>(0.0, 0.84, 0.78, 0.22 * pulseOpacityMultiplier)
        let progressColor = isModalBackdropActive ?
            SIMD4<Float>(0.86, 0.86, 0.86, 0.16 + 0.10 * pulseOpacityMultiplier) :
            SIMD4<Float>(0.20, 0.96, 1.0, 0.18 + 0.12 * pulseOpacityMultiplier)
        guard let verticalRange = selectionVerticalRange(
            for: selection,
            renderState: renderState,
            drawableSize: drawableSize
        ) else {
            return selectionVertexScratch
        }
        selectionVertexScratch.reserveCapacity(activeProcessingSelection == nil ? 6 : 12)

        appendRectangle(
            to: &selectionVertexScratch,
            left: max(left, 0),
            right: min(right, 1),
            top: verticalRange.top,
            bottom: verticalRange.bottom,
            color: baseColor
        )

        if
            let activeProcessingSelection,
            let fractionCompleted = interpolatedProcessingSelectionFraction(
                activeProcessingSelection,
                at: displayTimestamp
            )
        {
            let fillRight = left + (right - left) * fractionCompleted
            let visibleLeft = max(left, 0)
            let visibleRight = min(fillRight, 1)
            if visibleRight > visibleLeft {
                appendRectangle(
                    to: &selectionVertexScratch,
                    left: visibleLeft,
                    right: visibleRight,
                    top: verticalRange.top,
                    bottom: verticalRange.bottom,
                    color: progressColor
                )
            }
        }

        return selectionVertexScratch
    }

    private func makeCandidateRegionVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState
    ) -> [TimelineVertex] {
        candidateRegionVertexScratch.removeAll(keepingCapacity: true)
        guard renderState.hasWaveforms, !renderState.candidateRegions.isEmpty else {
            return candidateRegionVertexScratch
        }

        let viewport = renderState.viewport
        let viewportStart = Double(viewport.startProgress)
        let viewportDuration = max(Double(viewport.durationProgress), 0.000_000_001)
        let pixelWidth = drawableSize.width > 0 ? Float(1.0 / drawableSize.width) : 0
        let pixelHeight = drawableSize.height > 0 ? Float(1.0 / drawableSize.height) : 0
        candidateRegionVertexScratch.reserveCapacity(renderState.candidateRegions.count * 30)

        for region in renderState.candidateRegions where region.selection.durationProgress > 0 {
            let left = Float((region.selection.startProgress - viewportStart) / viewportDuration)
            let right = Float((region.selection.endProgress - viewportStart) / viewportDuration)
            guard right > 0, left < 1 else {
                continue
            }
            guard let verticalRange = selectionVerticalRange(
                for: region.selection,
                renderState: renderState,
                drawableSize: drawableSize
            ) else {
                continue
            }

            let clampedLeft = max(left, 0)
            let clampedRight = min(right, 1)
            guard clampedRight > clampedLeft else {
                continue
            }

            let fillColor = region.isActive ?
                SIMD4<Float>(0.95, 0.82, 0.36, 0.22) :
                SIMD4<Float>(0.92, 0.68, 0.24, 0.14)
            let outlineColor = region.isActive ?
                SIMD4<Float>(1.0, 0.92, 0.54, 0.72) :
                SIMD4<Float>(0.98, 0.76, 0.32, 0.42)
            let top = max(verticalRange.top, 0)
            let bottom = min(verticalRange.bottom, 1)
            appendRectangle(
                to: &candidateRegionVertexScratch,
                left: clampedLeft,
                right: clampedRight,
                top: top,
                bottom: bottom,
                color: fillColor
            )

            let edgeWidth = max(pixelWidth * (region.isActive ? 2.0 : 1.0), 0.001)
            let edgeHeight = max(pixelHeight * (region.isActive ? 2.0 : 1.0), 0.001)
            appendRectangle(
                to: &candidateRegionVertexScratch,
                left: clampedLeft,
                right: min(clampedLeft + edgeWidth, clampedRight),
                top: top,
                bottom: bottom,
                color: outlineColor
            )
            appendRectangle(
                to: &candidateRegionVertexScratch,
                left: max(clampedRight - edgeWidth, clampedLeft),
                right: clampedRight,
                top: top,
                bottom: bottom,
                color: outlineColor
            )
            appendRectangle(
                to: &candidateRegionVertexScratch,
                left: clampedLeft,
                right: clampedRight,
                top: top,
                bottom: min(top + edgeHeight, bottom),
                color: outlineColor
            )
            appendRectangle(
                to: &candidateRegionVertexScratch,
                left: clampedLeft,
                right: clampedRight,
                top: max(bottom - edgeHeight, top),
                bottom: bottom,
                color: outlineColor
            )
        }

        return candidateRegionVertexScratch
    }

    private func makeSelectedTrackVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState
    ) -> [TimelineVertex] {
        selectedTrackVertexScratch.removeAll(keepingCapacity: true)
        guard !renderState.selectedTrackIDs.isEmpty, !renderState.tracks.isEmpty else {
            return selectedTrackVertexScratch
        }

        selectedTrackVertexScratch.reserveCapacity(renderState.selectedTrackIDs.count * 6)
        for (trackIndex, track) in renderState.tracks.enumerated()
            where renderState.selectedTrackIDs.contains(track.id)
        {
            if
                let selection = renderState.selection,
                selection.trackID == track.id,
                selection.startProgress <= 0.001,
                selection.endProgress >= 0.999
            {
                continue
            }

            guard let laneFrame = laneFrame(
                forTrackIndex: trackIndex,
                renderState: renderState,
                drawableSize: drawableSize
            ) else {
                continue
            }
            appendRectangle(
                to: &selectedTrackVertexScratch,
                left: 0,
                right: 1,
                top: max(laneFrame.top, 0),
                bottom: min(laneFrame.bottom, 1),
                color: SIMD4<Float>(0.78, 0.78, 0.78, 0.075)
            )
        }
        return selectedTrackVertexScratch
    }

    private func makeProcessingTrackHighlightVertices(
        drawableSize: CGSize,
        renderState: TimelineRenderState
    ) -> [TimelineVertex] {
        processingTrackVertexScratch.removeAll(keepingCapacity: true)
        guard
            let highlight = renderState.processingTrackHighlight,
            highlight.alpha > 0.001,
            !renderState.tracks.isEmpty,
            let trackIndex = renderState.tracks.firstIndex(where: { $0.id == highlight.trackID }),
            let laneFrame = laneFrame(
                forTrackIndex: trackIndex,
                renderState: renderState,
                drawableSize: drawableSize
            )
        else {
            return processingTrackVertexScratch
        }

        let alpha = highlight.alpha
        let fillColor = isModalBackdropActive ?
            SIMD4<Float>(0.58, 0.58, 0.58, 0.085 * alpha) :
            SIMD4<Float>(0.08, 0.92, 0.96, 0.10 * alpha)
        let topEdgeColor = isModalBackdropActive ?
            SIMD4<Float>(0.84, 0.84, 0.84, 0.22 * alpha) :
            SIMD4<Float>(0.32, 0.98, 1.0, 0.30 * alpha)
        let bottomEdgeColor = isModalBackdropActive ?
            SIMD4<Float>(0.78, 0.78, 0.78, 0.14 * alpha) :
            SIMD4<Float>(0.32, 0.98, 1.0, 0.18 * alpha)
        let top = max(laneFrame.top, 0)
        let bottom = min(laneFrame.bottom, 1)
        guard bottom > top else {
            return processingTrackVertexScratch
        }

        let pixelHeight = drawableSize.height > 0 ? Float(1.0 / drawableSize.height) : 0
        let edgeHeight = max(pixelHeight * 2.0, 0.001)
        processingTrackVertexScratch.reserveCapacity(18)
        appendRectangle(
            to: &processingTrackVertexScratch,
            left: 0,
            right: 1,
            top: top,
            bottom: bottom,
            color: fillColor
        )
        appendRectangle(
            to: &processingTrackVertexScratch,
            left: 0,
            right: 1,
            top: top,
            bottom: min(top + edgeHeight, bottom),
            color: topEdgeColor
        )
        appendRectangle(
            to: &processingTrackVertexScratch,
            left: 0,
            right: 1,
            top: max(bottom - edgeHeight, top),
            bottom: bottom,
            color: bottomEdgeColor
        )
        return processingTrackVertexScratch
    }

    private func makeClipBoundaryVertices(
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState
    ) -> [TimelineVertex] {
        clipBoundaryVertexScratch.removeAll(keepingCapacity: true)
        guard renderState.hasWaveforms, !renderState.tracks.isEmpty else {
            return clipBoundaryVertexScratch
        }

        let projectDuration = Float(renderState.duration ?? 0)
        guard projectDuration > 0 else {
            return clipBoundaryVertexScratch
        }

        let viewport = renderState.viewport
        let width = Float(drawableSize.width)
        let pixelWidth = width > 0 ? max(pixelLength(backingScale: backingScale) / width, 0.0012) : 0.0012
        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        let visibleRange = trackLayout.visibleRange(overscan: 1)
        clipBoundaryVertexScratch.reserveCapacity(visibleRange.count * 24)

        for trackIndex in visibleRange {
            guard renderState.tracks.indices.contains(trackIndex) else {
                continue
            }

            let track = renderState.tracks[trackIndex]
            guard
                track.hasWaveform,
                !track.clipRanges.isEmpty,
                let trackDuration = track.durationHint,
                trackDuration > 0,
                let laneFrame = trackLayout.laneFrame(forTrackIndex: trackIndex),
                laneFrame.isVisible
            else {
                continue
            }

            let trackDurationProgress = min(max(Float(trackDuration) / projectDuration, 0), 1)
            guard trackDurationProgress > 0 else {
                continue
            }

            var emittedBoundaryKeys = Set<Int>()
            for clipRange in track.clipRanges {
                for localBoundary in [clipRange.startProgress, clipRange.endProgress] {
                    let projectProgress = Float(localBoundary) * trackDurationProgress
                    let viewportProgress = viewport.viewportProgress(forTimelineProgress: projectProgress)
                    guard viewportProgress >= -pixelWidth, viewportProgress <= 1 + pixelWidth else {
                        continue
                    }

                    let key = Int((projectProgress * 1_000_000).rounded())
                    guard emittedBoundaryKeys.insert(key).inserted else {
                        continue
                    }

                    let isOuterBoundary =
                        projectProgress <= 0.000_001 ||
                        abs(projectProgress - trackDurationProgress) <= 0.000_001
                    let alpha: Float = isOuterBoundary ? 0.16 : 0.42
                    let color = SIMD4<Float>(0.88, 0.94, 0.96, alpha)
                    let x = min(max(viewportProgress, 0), 1)
                    appendRectangle(
                        to: &clipBoundaryVertexScratch,
                        left: max(x - pixelWidth * 0.5, 0),
                        right: min(x + pixelWidth * 0.5, 1),
                        top: max(laneFrame.top + 0.035, 0),
                        bottom: min(laneFrame.bottom - 0.035, 1),
                        color: color
                    )
                }
            }
        }

        return clipBoundaryVertexScratch
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

        let anySolo = renderState.hasSoloedTrack
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
        for renderState: TimelineRenderState,
        at timestamp: CFTimeInterval
    ) {
        guard waveformFisheyeEnabled else {
            trackFisheyeAudibilitySignature = nil
            trackFisheyeStates.removeAll()
            return
        }

        let tracks = renderState.tracks
        let anySolo = renderState.hasSoloedTrack
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
        for renderState: TimelineRenderState,
        at timestamp: CFTimeInterval
    ) {
        guard waveformFisheyeEnabled else {
            if trackFisheyeAudibilitySignature != nil || !trackFisheyeStates.isEmpty {
                trackFisheyeAudibilitySignature = nil
                trackFisheyeStates.removeAll()
            }
            return
        }

        let tracks = renderState.tracks
        let anySolo = renderState.hasSoloedTrack
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
                peakAlpha: 0.48,
                bodyAlpha: 0.075,
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
                peakAlpha: 0.52,
                bodyAlpha: 0.060,
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
                peakAlpha: 0.58,
                bodyAlpha: 0.038,
                glowAlpha: 0.022,
                transientAlpha: 0.19,
                transientThreshold: 0.36,
                centerLineAlpha: 0.07,
                glowExpansion: 0.004
            )
        }

        return WaveformVisualStyle(
            spectralAmount: 0.08,
            peakAlpha: 0.64,
            bodyAlpha: 0.020,
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

    private func smoothStep(edge0: Float, edge1: Float, value: Float) -> Float {
        guard edge1 != edge0 else {
            return value >= edge1 ? 1 : 0
        }
        return smoothStep((value - edge0) / (edge1 - edge0))
    }

    private func deletionSlideProgress(_ progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        if clampedProgress < 0.5 {
            let halfProgress = clampedProgress * 2
            return 0.5 * halfProgress * halfProgress
        }
        let halfProgress = (clampedProgress - 0.5) * 2
        return 0.5 + 0.5 * (1 - pow(1 - halfProgress, 3))
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

        if style.bodyAlpha > 0.001 {
            let bodyColor = lightened(baseColor, amount: 0.14, alpha: style.bodyAlpha * alpha)
            appendCenterWeightedWaveformBand(
                to: &vertices,
                left: left,
                right: right,
                top: peakTop,
                bottom: peakBottom,
                centerY: centerY,
                centerColor: bodyColor,
                edgeColor: colorWithAlpha(bodyColor, alpha: bodyColor.w * 0.42)
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

        let transientStrength = max(bin.highEnergy - style.transientThreshold, 0) /
            max(1 - style.transientThreshold, 0.001)
        if transientStrength > 0.001 {
            let transientColor = lightened(
                baseColor,
                amount: 0.16,
                alpha: transientStrength * transientStrength * style.transientAlpha * alpha * 0.10
            )
            appendCenterWeightedWaveformBand(
                to: &vertices,
                left: left,
                right: right,
                top: peakTop,
                bottom: peakBottom,
                centerY: centerY,
                centerColor: transientColor,
                edgeColor: colorWithAlpha(transientColor, alpha: transientColor.w * 0.35)
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
        return loopConstrainedPlaybackProgress(progress)
    }

    private func loopConstrainedPlaybackProgress(_ progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        guard isLoopRangeEnabled else {
            return clampedProgress
        }

        let start = loopRange.startProgress
        let end = loopRange.endProgress
        let duration = end - start
        guard duration > 0.0001, duration < 0.999, end > start else {
            return clampedProgress
        }

        guard clampedProgress > end else {
            return clampedProgress
        }

        let overflow = clampedProgress - end
        guard overflow > 0 else {
            return start
        }

        return start + overflow.truncatingRemainder(dividingBy: duration)
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

        guard let trimRange = renderState.trimPreview else {
            return []
        }
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
        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        let guideTop = min(max(trackLayout.rulerLaneHeight, 0), height)
        guard guideTop < height else {
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
            top: guideTop,
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
        let trackLayout = resolvedTrackLayout(renderState: renderState, drawableSize: drawableSize)
        let playheadTop = min(max(trackLayout.rulerLaneHeight, 0), height)
        guard playheadTop < height else {
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
        let baseColor: SIMD3<Float>
        let burstColor: SIMD3<Float>
        if isModalBackdropActive {
            baseColor = SIMD3<Float>(0.58, 0.58, 0.58)
            burstColor = SIMD3<Float>(0.72, 0.72, 0.72)
        } else if renderState.isRecordingActive {
            baseColor = SIMD3<Float>(0.96, 0.12, 0.14)
            burstColor = SIMD3<Float>(1.0, 0.30, 0.24)
        } else {
            baseColor = SIMD3<Float>(0.0, 0.75, 0.78)
            burstColor = SIMD3<Float>(0.0, 0.62, 0.86)
        }
        let blendedColor = baseColor + (burstColor - baseColor) * kickEnergy
        let size = SIMD2<Float>(width, height)
        var vertices: [TimelineVertex] = []
        vertices.reserveCapacity(90)
        let baseWidth = pixelLength(4.0, backingScale: backingScale)
        let halfBaseWidth = baseWidth * 0.5
        if isModalBackdropActive {
            playheadContactEvents.removeAll()
        } else {
            updatePlayheadContactEvents(
                drawableSize: size,
                playheadProgress: playheadProgress,
                renderState: renderState,
                mipLevelSnapshot: mipLevelSnapshot,
                displayTimestamp: displayTimestamp
            )
        }

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
                    top: playheadTop,
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
                        top: playheadTop,
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
                            top: playheadTop,
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
                top: playheadTop,
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
            top: playheadTop,
            bottom: height,
            color: SIMD4<Float>(blendedColor.x, blendedColor.y, blendedColor.z, 1.0),
            drawableSize: size,
            backingScale: backingScale
        )

        if !isModalBackdropActive {
            appendPlayheadContactVertices(
                to: &vertices,
                playheadX: playheadX,
                lineHalfWidth: halfBaseWidth,
                drawableSize: size,
                backingScale: backingScale,
                displayTimestamp: displayTimestamp
            )
        }

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

    private func cachedWaveformMipLevels(
        for track: TimelineRenderState.Track,
        priorityRenderState: TimelineRenderState? = nil
    ) -> [WaveformMipLevel] {
        let sourceTrack = waveformSourceTrack(for: track)
        guard let waveformOverview = sourceTrack.waveformOverview, !waveformOverview.isEmpty else {
            return []
        }

        let key = waveformMipCacheKey(for: sourceTrack)
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
        scheduleCompleteWaveformMipLevelBuild(
            for: key,
            waveformOverview: waveformOverview,
            priorityRenderState: priorityRenderState
        )

        return initialLevels
    }

    private func waveformMipCacheKey(for track: TimelineRenderState.Track) -> WaveformMipCacheKey? {
        let sourceTrack = waveformSourceTrack(for: track)
        guard let waveformOverview = sourceTrack.waveformOverview, !waveformOverview.isEmpty else {
            return nil
        }

        return WaveformMipCacheKey(
            trackID: sourceTrack.id,
            waveformVersion: sourceTrack.waveformVersion,
            binCount: waveformOverview.bins.count,
            duration: waveformOverview.duration
        )
    }

    private func scheduleCompleteWaveformMipLevelBuild(
        for key: WaveformMipCacheKey,
        waveformOverview: WaveformOverview,
        priorityRenderState: TimelineRenderState? = nil
    ) {
        guard waveformOverview.bins.count > maximumSynchronousGeneratedWaveformMipBins else {
            return
        }

        let priorityTargetBinCount = preferredProgressiveWaveformMipTargetBinCount(
            for: key,
            waveformOverview: waveformOverview,
            renderState: priorityRenderState ?? renderState
        )

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

            if let priorityTargetBinCount {
                let priorityOverview = self.sampledWaveformOverview(
                    from: waveformOverview,
                    targetBinCount: priorityTargetBinCount,
                    samplesPerBin: self.generatedWaveformMipSamplesPerBin,
                    shouldYieldForPlayback: true
                )
                let priorityLevels = self.mergedWaveformMipLevels(
                    self.cachedWaveformMipLevelsForBackgroundPublish(for: key) ??
                        self.makeInitialWaveformMipLevels(from: waveformOverview),
                    adding: WaveformMipLevel(
                        overview: priorityOverview,
                        binCount: priorityOverview.bins.count
                    )
                )
                self.publishWaveformMipLevels(priorityLevels, for: key, isFinalBuild: false)
            }

            let levels = self.makeWaveformMipLevels(
                from: waveformOverview,
                shouldYieldForPlayback: true
            )
            self.publishWaveformMipLevels(levels, for: key, isFinalBuild: true)
        }
    }

    private func cachedWaveformMipLevelsForBackgroundPublish(
        for key: WaveformMipCacheKey
    ) -> [WaveformMipLevel]? {
        waveformMipLevelCacheLock.lock()
        let levels = waveformMipLevelCache[key]
        waveformMipLevelCacheLock.unlock()
        return levels
    }

    private func mergedWaveformMipLevels(
        _ levels: [WaveformMipLevel],
        adding level: WaveformMipLevel
    ) -> [WaveformMipLevel] {
        guard level.binCount > 0 else {
            return levels
        }

        var byBinCount = Dictionary(uniqueKeysWithValues: levels.map { ($0.binCount, $0) })
        byBinCount[level.binCount] = level
        return byBinCount.values.sorted { $0.binCount > $1.binCount }
    }

    private func preferredProgressiveWaveformMipTargetBinCount(
        for key: WaveformMipCacheKey,
        waveformOverview: WaveformOverview,
        renderState state: TimelineRenderState
    ) -> Int? {
        let sourceBinCount = waveformOverview.bins.count
        guard sourceBinCount > maximumSynchronousGeneratedWaveformMipBins else {
            return nil
        }

        guard
            lastRenderViewportSize.width > 0,
            lastRenderViewportSize.height > 0,
            state.tracks.contains(where: { $0.id == key.trackID })
        else {
            return nil
        }

        let targetVisibleBins = waveformMipTargetVisibleBins(
            drawableSize: lastRenderViewportSize,
            backingScale: lastRenderBackingScale,
            renderState: state
        )
        let viewportDurationProgress = max(state.viewport.durationProgress, 0.000_001)
        var targetBinCount = min(sourceBinCount / 2, maximumGeneratedWaveformMipBins)
        while targetBinCount >= 256 {
            let visibleBins = Float(targetBinCount) * viewportDurationProgress
            if visibleBins <= targetVisibleBins {
                return targetBinCount > maximumSynchronousGeneratedWaveformMipBins ? targetBinCount : nil
            }
            targetBinCount /= 2
        }

        return nil
    }

    private func publishWaveformMipLevels(
        _ levels: [WaveformMipLevel],
        for key: WaveformMipCacheKey,
        isFinalBuild: Bool
    ) {
        publishWaveformMipLevelsToCache(levels, for: key)

        let continuityRenderState = renderState
        let continuityDrawableSize = lastRenderViewportSize
        let continuityBackingScale = lastRenderBackingScale
        let preferredBufferIsReady = ensurePreferredWaveformShaderBufferIsResident(
            trackID: key.trackID,
            mipLevels: levels,
            renderState: continuityRenderState,
            drawableSize: continuityDrawableSize,
            backingScale: continuityBackingScale
        )

        var didPublishVisibleLevels = false
        waveformMipLevelStateLock.lock()
        if currentTrackWaveformMipKeys[key.trackID] == key {
            if preferredBufferIsReady {
                pendingCompleteWaveformMipLevels.removeValue(forKey: key)
                didPublishVisibleLevels = true
            } else {
                pendingCompleteWaveformMipLevels[key] = levels
            }
        }
        waveformMipLevelStateLock.unlock()

        if didPublishVisibleLevels {
            _ = commitVisibleWaveformMipLevels(levels, for: key, renderState: continuityRenderState)
        }

        if isFinalBuild {
            waveformMipLevelCacheLock.lock()
            waveformMipLevelBuildsInFlight.remove(key)
            waveformMipLevelCacheLock.unlock()
        }

        if didPublishVisibleLevels {
            prewarmCurrentInteractiveWaveformShaderBuffers(
                drawableSize: lastRenderViewportSize,
                backingScale: lastRenderBackingScale
            )
            onRenderDataPrepared?()
        } else {
            onRenderDataPrepared?()
        }
    }

    private func waveformMipLevelBinSignature(_ levels: [WaveformMipLevel]) -> [Int] {
        levels.map(\.binCount)
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
        backingScale: Float = 1,
        renderState: TimelineRenderState,
        mipLevels: [WaveformMipLevel]
    ) -> WaveformMipLevel? {
        guard let index = waveformMipLevelIndex(
            for: drawableSize,
            backingScale: backingScale,
            renderState: renderState,
            mipLevels: mipLevels
        ) else {
            return nil
        }

        return mipLevels[index]
    }

    private func waveformMipLevelIndex(
        for drawableSize: CGSize,
        backingScale: Float = 1,
        renderState: TimelineRenderState,
        mipLevels: [WaveformMipLevel]
    ) -> Int? {
        guard !mipLevels.isEmpty else {
            return nil
        }

        let targetVisibleBins = waveformMipTargetVisibleBins(
            drawableSize: drawableSize,
            backingScale: backingScale,
            renderState: renderState
        )

        for (index, mipLevel) in mipLevels.enumerated() {
            let visibleBins = Float(mipLevel.binCount) * renderState.viewport.durationProgress
            if visibleBins <= targetVisibleBins {
                return index
            }
        }

        return mipLevels.indices.last
    }

    private func waveformMipTargetVisibleBins(
        drawableSize: CGSize,
        backingScale: Float,
        renderState: TimelineRenderState
    ) -> Float {
        let width = max(Float(drawableSize.width) * max(backingScale, 1), 1)
        let binsPerPixel = waveformMipTargetBinsPerPixel(renderState: renderState)
        return max(width * binsPerPixel, minimumWaveformMipTargetVisibleBins)
    }

    private func waveformMipTargetBinsPerPixel(renderState: TimelineRenderState) -> Float {
        guard
            let duration = renderState.duration,
            duration.isFinite,
            duration > 0
        else {
            return mediumWaveformMipTargetBinsPerPixel
        }

        let visibleDuration = duration * Double(max(renderState.viewport.durationProgress, 0))
        guard visibleDuration.isFinite, visibleDuration > 0 else {
            return mediumWaveformMipTargetBinsPerPixel
        }

        if visibleDuration <= detailWaveformMipVisibleDuration {
            return detailWaveformMipTargetBinsPerPixel
        }

        if visibleDuration <= mediumWaveformMipVisibleDuration {
            let progress = smoothStep(
                Float(
                    (visibleDuration - detailWaveformMipVisibleDuration) /
                    max(mediumWaveformMipVisibleDuration - detailWaveformMipVisibleDuration, 0.000_001)
                )
            )
            return mix(
                detailWaveformMipTargetBinsPerPixel,
                mediumWaveformMipTargetBinsPerPixel,
                progress
            )
        }

        if visibleDuration <= overviewWaveformMipVisibleDuration {
            let progress = smoothStep(
                Float(
                    (visibleDuration - mediumWaveformMipVisibleDuration) /
                    max(overviewWaveformMipVisibleDuration - mediumWaveformMipVisibleDuration, 0.000_001)
                )
            )
            return mix(
                mediumWaveformMipTargetBinsPerPixel,
                overviewWaveformMipTargetBinsPerPixel,
                progress
            )
        }

        return overviewWaveformMipTargetBinsPerPixel
    }

    private func mix(_ start: Float, _ end: Float, _ progress: Float) -> Float {
        start + (end - start) * min(max(progress, 0), 1)
    }

    private func mix(_ start: SIMD3<Float>, _ end: SIMD3<Float>, _ progress: Float) -> SIMD3<Float> {
        let amount = min(max(progress, 0), 1)
        return start + (end - start) * amount
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

    private func appendHorizontalGradientRectangle(
        to vertices: inout [TimelineVertex],
        left: Float,
        right: Float,
        top: Float,
        bottom: Float,
        leftColor: SIMD4<Float>,
        rightColor: SIMD4<Float>
    ) {
        guard right > left, bottom > top else {
            return
        }

        let topLeft = makeVertex(
            normalizedPosition: SIMD2<Float>(left, top),
            color: leftColor
        )
        let topRight = makeVertex(
            normalizedPosition: SIMD2<Float>(right, top),
            color: rightColor
        )
        let bottomLeft = makeVertex(
            normalizedPosition: SIMD2<Float>(left, bottom),
            color: leftColor
        )
        let bottomRight = makeVertex(
            normalizedPosition: SIMD2<Float>(right, bottom),
            color: rightColor
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
        drawableSize: SIMD2<Float>,
        segmentCount: Int = 12
    ) {
        guard
            drawableSize.x > 0,
            drawableSize.y > 0,
            radius > 0,
            alpha > 0,
            segmentCount >= 3
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

    private enum LoopFlagRoundedEdge {
        case leading
        case trailing
    }

    private func appendLoopHandle(
        to vertices: inout [TimelineVertex],
        label: Character,
        endpoint: TimelineLoopEndpoint,
        progress: Float,
        color: SIMD4<Float>,
        isHighlighted: Bool,
        drawableSize: SIMD2<Float>,
        rulerHeight: Float,
        backingScale: Float,
        renderState: TimelineRenderState
    ) {
        let width = drawableSize.x
        let height = drawableSize.y
        let viewportProgress = renderState.viewport.viewportProgress(forTimelineProgress: progress)
        guard viewportProgress >= -0.04, viewportProgress <= 1.04 else {
            return
        }

        let clampedX = min(max(viewportProgress * width, 0), width)
        let alignedX = pixelAligned(clampedX, backingScale: backingScale)
        let lineWidth = max(pixelLength(2, backingScale: backingScale), 1)
        let lineLeft = min(max(alignedX - lineWidth * 0.5, 0), width)
        let lineRight = min(lineLeft + lineWidth, width)
        let tabWidth: Float = 18
        let tabHeight = min(max(rulerHeight - 14, 14), 18)
        let tabTop: Float = 0
        let tabBottom = min(tabHeight, rulerHeight - pixelLength(backingScale: backingScale))
        let tabLeft: Float
        let tabRight: Float
        if label == "L" {
            tabLeft = min(max(alignedX, 0), max(width - tabWidth, 0))
            tabRight = min(tabLeft + tabWidth, width)
        } else {
            tabRight = max(min(alignedX, width), tabWidth)
            tabLeft = max(tabRight - tabWidth, 0)
        }

        let guideAlpha: Float = isHighlighted ? 0.78 : 0.50
        let guideColor = isHighlighted ?
            SIMD4<Float>(0.90, 0.97, 1.0, guideAlpha) :
            SIMD4<Float>(color.x, color.y, color.z, guideAlpha)
        appendRectangle(
            to: &vertices,
            left: lineLeft,
            right: lineRight,
            top: tabBottom,
            bottom: height,
            color: guideColor,
            drawableSize: drawableSize
        )

        let flagColor = isHighlighted ?
            SIMD4<Float>(0.92, 0.97, 1.0, 0.98) :
            color
        appendLoopFlag(
            to: &vertices,
            left: tabLeft,
            right: tabRight,
            top: tabTop,
            bottom: tabBottom,
            roundedEdge: endpoint == .start ? .trailing : .leading,
            color: flagColor,
            drawableSize: drawableSize
        )
        appendLoopLabelGlyph(
            to: &vertices,
            label: label,
            left: tabLeft,
            right: tabRight,
            top: tabTop,
            bottom: tabBottom,
            drawableSize: drawableSize,
            backingScale: backingScale
        )
    }

    private func appendLoopFlag(
        to vertices: inout [TimelineVertex],
        left: Float,
        right: Float,
        top: Float,
        bottom: Float,
        roundedEdge: LoopFlagRoundedEdge,
        color: SIMD4<Float>,
        drawableSize: SIMD2<Float>
    ) {
        guard right > left, bottom > top else {
            return
        }

        let width = right - left
        let height = bottom - top
        let radius = min(width * 0.36, height * 0.42, 5)
        guard radius > 0.5 else {
            appendRectangle(
                to: &vertices,
                left: left,
                right: right,
                top: top,
                bottom: bottom,
                color: color,
                drawableSize: drawableSize
            )
            return
        }

        let sliceCount = 6
        switch roundedEdge {
        case .trailing:
            appendRectangle(
                to: &vertices,
                left: left,
                right: right - radius,
                top: top,
                bottom: bottom,
                color: color,
                drawableSize: drawableSize
            )
            for index in 0..<sliceCount {
                let x0 = right - radius + radius * Float(index) / Float(sliceCount)
                let x1 = right - radius + radius * Float(index + 1) / Float(sliceCount)
                let midX = (x0 + x1) * 0.5
                let distanceFromSquareEdge = midX - (right - radius)
                let inset = radius - sqrt(max(radius * radius - distanceFromSquareEdge * distanceFromSquareEdge, 0))
                appendRectangle(
                    to: &vertices,
                    left: x0,
                    right: x1,
                    top: top + inset,
                    bottom: bottom - inset,
                    color: color,
                    drawableSize: drawableSize
                )
            }
        case .leading:
            appendRectangle(
                to: &vertices,
                left: left + radius,
                right: right,
                top: top,
                bottom: bottom,
                color: color,
                drawableSize: drawableSize
            )
            for index in 0..<sliceCount {
                let x0 = left + radius * Float(index) / Float(sliceCount)
                let x1 = left + radius * Float(index + 1) / Float(sliceCount)
                let midX = (x0 + x1) * 0.5
                let distanceFromSquareEdge = (left + radius) - midX
                let inset = radius - sqrt(max(radius * radius - distanceFromSquareEdge * distanceFromSquareEdge, 0))
                appendRectangle(
                    to: &vertices,
                    left: x0,
                    right: x1,
                    top: top + inset,
                    bottom: bottom - inset,
                    color: color,
                    drawableSize: drawableSize
                )
            }
        }
    }

    private func appendRoundedRectangle(
        to vertices: inout [TimelineVertex],
        left: Float,
        right: Float,
        top: Float,
        bottom: Float,
        radius requestedRadius: Float,
        color: SIMD4<Float>,
        drawableSize: SIMD2<Float>
    ) {
        guard right > left, bottom > top else {
            return
        }

        let width = right - left
        let height = bottom - top
        let radius = min(max(requestedRadius, 0), width * 0.5, height * 0.5)
        guard radius > 0.5 else {
            appendRectangle(
                to: &vertices,
                left: left,
                right: right,
                top: top,
                bottom: bottom,
                color: color,
                drawableSize: drawableSize
            )
            return
        }

        appendRectangle(
            to: &vertices,
            left: left + radius,
            right: right - radius,
            top: top,
            bottom: bottom,
            color: color,
            drawableSize: drawableSize
        )

        let sliceCount = 8
        for index in 0..<sliceCount {
            let y0 = top + height * Float(index) / Float(sliceCount)
            let y1 = top + height * Float(index + 1) / Float(sliceCount)
            let midY = (y0 + y1) * 0.5
            let centerY = (top + bottom) * 0.5
            let verticalDistance = abs(midY - centerY)
            let capWidth = sqrt(max(radius * radius - verticalDistance * verticalDistance, 0))
            appendRectangle(
                to: &vertices,
                left: left + radius - capWidth,
                right: left + radius,
                top: y0,
                bottom: y1,
                color: color,
                drawableSize: drawableSize
            )
            appendRectangle(
                to: &vertices,
                left: right - radius,
                right: right - radius + capWidth,
                top: y0,
                bottom: y1,
                color: color,
                drawableSize: drawableSize
            )
        }
    }

    private func appendTopRoundedRectangle(
        to vertices: inout [TimelineVertex],
        left: Float,
        right: Float,
        top: Float,
        bottom: Float,
        radius requestedRadius: Float,
        color: SIMD4<Float>,
        drawableSize: SIMD2<Float>
    ) {
        guard right > left, bottom > top else {
            return
        }

        let width = right - left
        let height = bottom - top
        let radius = min(max(requestedRadius, 0), width * 0.5, height)
        guard radius > 0.5 else {
            appendRectangle(
                to: &vertices,
                left: left,
                right: right,
                top: top,
                bottom: bottom,
                color: color,
                drawableSize: drawableSize
            )
            return
        }

        appendRectangle(
            to: &vertices,
            left: left,
            right: right,
            top: top + radius,
            bottom: bottom,
            color: color,
            drawableSize: drawableSize
        )
        appendRectangle(
            to: &vertices,
            left: left + radius,
            right: right - radius,
            top: top,
            bottom: top + radius,
            color: color,
            drawableSize: drawableSize
        )

        let sliceCount = 8
        for index in 0..<sliceCount {
            let y0 = top + radius * Float(index) / Float(sliceCount)
            let y1 = top + radius * Float(index + 1) / Float(sliceCount)
            let midY = (y0 + y1) * 0.5
            let verticalDistance = (top + radius) - midY
            let capWidth = sqrt(max(radius * radius - verticalDistance * verticalDistance, 0))
            appendRectangle(
                to: &vertices,
                left: left + radius - capWidth,
                right: left + radius,
                top: y0,
                bottom: y1,
                color: color,
                drawableSize: drawableSize
            )
            appendRectangle(
                to: &vertices,
                left: right - radius,
                right: right - radius + capWidth,
                top: y0,
                bottom: y1,
                color: color,
                drawableSize: drawableSize
            )
        }
    }

    private func appendLoopLabelGlyph(
        to vertices: inout [TimelineVertex],
        label: Character,
        left: Float,
        right: Float,
        top: Float,
        bottom: Float,
        drawableSize: SIMD2<Float>,
        backingScale: Float
    ) {
        let stroke = max(pixelLength(2, backingScale: backingScale), 1)
        let glyphWidth = min(max((right - left) * 0.42, 6), 8)
        let glyphHeight = min(max((bottom - top) * 0.58, 8), 12)
        let glyphLeft = pixelAligned((left + right - glyphWidth) * 0.5, backingScale: backingScale)
        let glyphTop = pixelAligned((top + bottom - glyphHeight) * 0.5, backingScale: backingScale)
        let glyphRight = glyphLeft + glyphWidth
        let glyphBottom = glyphTop + glyphHeight
        let glyphColor = SIMD4<Float>(0.015, 0.025, 0.030, 0.92)

        appendRectangle(
            to: &vertices,
            left: glyphLeft,
            right: glyphLeft + stroke,
            top: glyphTop,
            bottom: glyphBottom,
            color: glyphColor,
            drawableSize: drawableSize
        )

        if label == "L" {
            appendRectangle(
                to: &vertices,
                left: glyphLeft,
                right: glyphRight,
                top: glyphBottom - stroke,
                bottom: glyphBottom,
                color: glyphColor,
                drawableSize: drawableSize
            )
        } else {
            appendRectangle(
                to: &vertices,
                left: glyphLeft,
                right: glyphRight - stroke * 0.3,
                top: glyphTop,
                bottom: glyphTop + stroke,
                color: glyphColor,
                drawableSize: drawableSize
            )
            appendRectangle(
                to: &vertices,
                left: glyphLeft,
                right: glyphRight - stroke * 0.5,
                top: glyphTop + glyphHeight * 0.43,
                bottom: glyphTop + glyphHeight * 0.43 + stroke,
                color: glyphColor,
                drawableSize: drawableSize
            )
            appendRectangle(
                to: &vertices,
                left: glyphRight - stroke,
                right: glyphRight,
                top: glyphTop + stroke * 0.4,
                bottom: glyphTop + glyphHeight * 0.43 + stroke * 0.4,
                color: glyphColor,
                drawableSize: drawableSize
            )
            appendLineSegment(
                to: &vertices,
                start: SIMD2<Float>(
                    glyphLeft + glyphWidth * 0.44,
                    glyphTop + glyphHeight * 0.52
                ),
                end: SIMD2<Float>(
                    glyphRight,
                    glyphBottom
                ),
                thickness: stroke,
                color: glyphColor,
                drawableSize: drawableSize
            )
        }
    }

    private func appendLineSegment(
        to vertices: inout [TimelineVertex],
        start: SIMD2<Float>,
        end: SIMD2<Float>,
        thickness: Float,
        color: SIMD4<Float>,
        drawableSize: SIMD2<Float>
    ) {
        let direction = end - start
        let length = max(simd_length(direction), 0.001)
        let normal = SIMD2<Float>(-direction.y, direction.x) / length * max(thickness * 0.5, 0.5)
        appendQuad(
            to: &vertices,
            p0: start + normal,
            p1: end + normal,
            p2: end - normal,
            p3: start - normal,
            color: color,
            drawableSize: drawableSize
        )
    }

    private func appendQuad(
        to vertices: inout [TimelineVertex],
        p0: SIMD2<Float>,
        p1: SIMD2<Float>,
        p2: SIMD2<Float>,
        p3: SIMD2<Float>,
        color: SIMD4<Float>,
        drawableSize: SIMD2<Float>
    ) {
        guard drawableSize.x > 0, drawableSize.y > 0 else {
            return
        }

        let v0 = makeVertex(normalizedPosition: SIMD2<Float>(p0.x / drawableSize.x, p0.y / drawableSize.y), color: color)
        let v1 = makeVertex(normalizedPosition: SIMD2<Float>(p1.x / drawableSize.x, p1.y / drawableSize.y), color: color)
        let v2 = makeVertex(normalizedPosition: SIMD2<Float>(p2.x / drawableSize.x, p2.y / drawableSize.y), color: color)
        let v3 = makeVertex(normalizedPosition: SIMD2<Float>(p3.x / drawableSize.x, p3.y / drawableSize.y), color: color)
        vertices.append(v0)
        vertices.append(v1)
        vertices.append(v3)
        vertices.append(v1)
        vertices.append(v2)
        vertices.append(v3)
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
        float4 sourceMap;
        float4 segmentGain;
        float4 style;
        float4 style2;
        float4 gainPreview;
        float4 fisheye;
        float4 touch;
        float4 touch2;
        float4 touch3;
        float4 selectionDrag;
        float4 selectionDrag2;
        float4 selectionDragContact0;
        float4 selectionDragContact1;
        float4 selectionDragContact2;
        float4 selectionDragContact3;
        float4 selectionDragContact4;
        float4 selectionDragContact5;
        float4 selectionDragContact6;
        float4 selectionDragContact7;
        float4 deletionWarp;
    };

    struct DeletionEffectUniform {
        float4 rect;
        float4 overlayRect;
        float4 timing;
        float4 metrics;
        float4 ripple;
        float4 waveformStyle;
        float4 waveformStyle2;
    };

    struct SelectionDragEffectUniform {
        float4 rect;
        float4 metrics;
        float4 effect;
        float4 color;
        float4 mask;
    };

    struct SelectionOverlayUniform {
        float4 rect;
        float4 metrics;
        float4 style;
        float4 pulse;
        float4 baseColor;
        float4 progressColor;
        float4 fisheye;
    };

    struct LoopRegionUniform {
        float4 rect;
        float4 metrics;
        float4 style;
        float4 edgeHighlight;
        float4 fillColor;
        float4 topColor;
        float4 bottomColor;
        float4 edgeColor;
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
        float4 sourceMap;
        float4 segmentGain;
        float4 style;
        float4 style2;
        float4 gainPreview;
        float4 fisheye;
        float4 touch;
        float4 touch2;
        float4 touch3;
        float4 selectionDrag;
        float4 selectionDrag2;
        float4 selectionDragContact0;
        float4 selectionDragContact1;
        float4 selectionDragContact2;
        float4 selectionDragContact3;
        float4 selectionDragContact4;
        float4 selectionDragContact5;
        float4 selectionDragContact6;
        float4 selectionDragContact7;
        float4 deletionWarp;
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

    struct SelectionDragEffectRasterizedVertex {
        float4 position [[position]];
        float2 localPosition;
        float4 metrics;
        float4 effect;
        float4 color;
        float4 mask;
    };

    struct SelectionOverlayRasterizedVertex {
        float4 position [[position]];
        float2 normalizedPosition;
        float2 localPosition;
        float4 metrics;
        float4 style;
        float4 pulse;
        float4 baseColor;
        float4 progressColor;
    };

    struct LoopRegionRasterizedVertex {
        float4 position [[position]];
        float2 localPosition;
        float4 metrics;
        float4 style;
        float4 edgeHighlight;
        float4 fillColor;
        float4 topColor;
        float4 bottomColor;
        float4 edgeColor;
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
        out.sourceMap = uniform.sourceMap;
        out.segmentGain = uniform.segmentGain;
        out.style = uniform.style;
        out.style2 = uniform.style2;
        out.gainPreview = uniform.gainPreview;
        out.fisheye = uniform.fisheye;
        out.touch = uniform.touch;
        out.touch2 = uniform.touch2;
        out.touch3 = uniform.touch3;
        out.selectionDrag = uniform.selectionDrag;
        out.selectionDrag2 = uniform.selectionDrag2;
        out.selectionDragContact0 = uniform.selectionDragContact0;
        out.selectionDragContact1 = uniform.selectionDragContact1;
        out.selectionDragContact2 = uniform.selectionDragContact2;
        out.selectionDragContact3 = uniform.selectionDragContact3;
        out.selectionDragContact4 = uniform.selectionDragContact4;
        out.selectionDragContact5 = uniform.selectionDragContact5;
        out.selectionDragContact6 = uniform.selectionDragContact6;
        out.selectionDragContact7 = uniform.selectionDragContact7;
        out.deletionWarp = uniform.deletionWarp;
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
        float yFromTrackTopPixels = rulerHeightPixels - yPixels;
        if (yFromTrackTopPixels < -1.0) {
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
        float yCoverage = 1.0 - smoothstep(
            tickHeightPixels,
            tickHeightPixels + 1.0,
            yFromTrackTopPixels
        );
        float baseFade = (isMajor || isMedium) ?
            smoothstep(0.35, 1.35, yFromTrackTopPixels) :
            1.0;
        yCoverage *= baseFade;
        if (yCoverage <= 0.0) {
            return float4(0.0);
        }

        float tickAlpha = isMajor ? 1.0 : (isMedium ? 0.68 : 0.38);
        float alpha = in.color.a * xCoverage * yCoverage * tickAlpha;
        return float4(in.color.rgb, alpha);
    }

    static float catmull_rom_scalar(float p0, float p1, float p2, float p3, float t) {
        float t2 = t * t;
        float t3 = t2 * t;
        return 0.5 * (
            (2.0 * p1) +
            (-p0 + p2) * t +
            (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
            (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
        );
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
        uint previousIndex = leftIndex > 0u ? leftIndex - 1u : leftIndex;
        uint nextIndex = min(rightIndex + 1u, count - 1u);
        WaveformShaderBin previousBin = bins[binOffset + previousIndex];
        WaveformShaderBin leftBin = bins[binOffset + leftIndex];
        WaveformShaderBin rightBin = bins[binOffset + rightIndex];
        WaveformShaderBin nextBin = bins[binOffset + nextIndex];
        WaveformShaderBin linearBin;
        linearBin.minimumSample = mix(leftBin.minimumSample, rightBin.minimumSample, amount);
        linearBin.maximumSample = mix(leftBin.maximumSample, rightBin.maximumSample, amount);
        linearBin.rmsSample = mix(leftBin.rmsSample, rightBin.rmsSample, amount);
        linearBin.lowEnergy = mix(leftBin.lowEnergy, rightBin.lowEnergy, amount);
        linearBin.midEnergy = mix(leftBin.midEnergy, rightBin.midEnergy, amount);
        linearBin.highEnergy = mix(leftBin.highEnergy, rightBin.highEnergy, amount);
        linearBin.peakMagnitude = mix(leftBin.peakMagnitude, rightBin.peakMagnitude, amount);
        linearBin.reserved = 0.0;

        float cubicAmount = amount * amount * (3.0 - 2.0 * amount);
        WaveformShaderBin cubicBin;
        cubicBin.minimumSample = catmull_rom_scalar(
            previousBin.minimumSample,
            leftBin.minimumSample,
            rightBin.minimumSample,
            nextBin.minimumSample,
            cubicAmount
        );
        cubicBin.maximumSample = catmull_rom_scalar(
            previousBin.maximumSample,
            leftBin.maximumSample,
            rightBin.maximumSample,
            nextBin.maximumSample,
            cubicAmount
        );
        cubicBin.rmsSample = catmull_rom_scalar(
            previousBin.rmsSample,
            leftBin.rmsSample,
            rightBin.rmsSample,
            nextBin.rmsSample,
            cubicAmount
        );
        cubicBin.lowEnergy = catmull_rom_scalar(
            previousBin.lowEnergy,
            leftBin.lowEnergy,
            rightBin.lowEnergy,
            nextBin.lowEnergy,
            cubicAmount
        );
        cubicBin.midEnergy = catmull_rom_scalar(
            previousBin.midEnergy,
            leftBin.midEnergy,
            rightBin.midEnergy,
            nextBin.midEnergy,
            cubicAmount
        );
        cubicBin.highEnergy = catmull_rom_scalar(
            previousBin.highEnergy,
            leftBin.highEnergy,
            rightBin.highEnergy,
            nextBin.highEnergy,
            cubicAmount
        );
        cubicBin.peakMagnitude = catmull_rom_scalar(
            previousBin.peakMagnitude,
            leftBin.peakMagnitude,
            rightBin.peakMagnitude,
            nextBin.peakMagnitude,
            cubicAmount
        );
        cubicBin.reserved = 0.0;

        float blendAmount = clamp(smoothAmount, 0.0, 1.0);
        float cubicBlendAmount = blendAmount * 0.62;
        WaveformShaderBin smoothBin;
        smoothBin.minimumSample = clamp(mix(linearBin.minimumSample, cubicBin.minimumSample, cubicBlendAmount), -1.0, 1.0);
        smoothBin.maximumSample = clamp(mix(linearBin.maximumSample, cubicBin.maximumSample, cubicBlendAmount), -1.0, 1.0);
        if (smoothBin.minimumSample > smoothBin.maximumSample) {
            float midpoint = (smoothBin.minimumSample + smoothBin.maximumSample) * 0.5;
            smoothBin.minimumSample = midpoint;
            smoothBin.maximumSample = midpoint;
        }
        smoothBin.rmsSample = clamp(mix(linearBin.rmsSample, cubicBin.rmsSample, cubicBlendAmount), 0.0, 1.0);
        smoothBin.lowEnergy = clamp(mix(linearBin.lowEnergy, cubicBin.lowEnergy, cubicBlendAmount), 0.0, 1.0);
        smoothBin.midEnergy = clamp(mix(linearBin.midEnergy, cubicBin.midEnergy, cubicBlendAmount), 0.0, 1.0);
        smoothBin.highEnergy = clamp(mix(linearBin.highEnergy, cubicBin.highEnergy, cubicBlendAmount), 0.0, 1.0);
        smoothBin.peakMagnitude = clamp(mix(linearBin.peakMagnitude, cubicBin.peakMagnitude, cubicBlendAmount), 0.0, 1.0);
        smoothBin.reserved = 0.0;

        WaveformShaderBin result;
        result.minimumSample = mix(nearestBin.minimumSample, smoothBin.minimumSample, blendAmount);
        result.maximumSample = mix(nearestBin.maximumSample, smoothBin.maximumSample, blendAmount);
        result.rmsSample = mix(nearestBin.rmsSample, smoothBin.rmsSample, blendAmount);
        result.lowEnergy = mix(nearestBin.lowEnergy, smoothBin.lowEnergy, blendAmount);
        result.midEnergy = mix(nearestBin.midEnergy, smoothBin.midEnergy, blendAmount);
        result.highEnergy = mix(nearestBin.highEnergy, smoothBin.highEnergy, blendAmount);
        result.peakMagnitude = mix(nearestBin.peakMagnitude, smoothBin.peakMagnitude, blendAmount);
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

    vertex SelectionOverlayRasterizedVertex selection_overlay_vertex(
        uint vertexID [[vertex_id]],
        constant WaveformShaderQuadVertex *vertices [[buffer(0)]],
        constant SelectionOverlayUniform &uniform [[buffer(1)]]
    ) {
        float2 localPosition = vertices[vertexID].position.xy;
        float2 normalizedPosition = float2(
            mix(uniform.rect.x, uniform.rect.y, localPosition.x),
            mix(uniform.rect.z, uniform.rect.w, localPosition.y)
        );
        normalizedPosition.x = fisheye_x(normalizedPosition.x, uniform.fisheye);

        SelectionOverlayRasterizedVertex out;
        out.position = float4(
            normalizedPosition.x * 2.0 - 1.0,
            1.0 - normalizedPosition.y * 2.0,
            0.0,
            1.0
        );
        out.normalizedPosition = normalizedPosition;
        out.localPosition = localPosition;
        out.metrics = uniform.metrics;
        out.style = uniform.style;
        out.pulse = uniform.pulse;
        out.baseColor = uniform.baseColor;
        out.progressColor = uniform.progressColor;
        return out;
    }

    static float rounded_rect_signed_distance(float2 point, float2 halfSize, float radius) {
        float2 q = abs(point) - halfSize + radius;
        return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    }

    static float box_signed_distance(float2 point, float2 center, float2 halfSize) {
        float2 q = abs(point - center) - halfSize;
        return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0);
    }

    static float top_rounded_tab_signed_distance(float2 pixel, float width, float height, float radius) {
        float r = clamp(radius, 0.0, min(width * 0.5, height));
        if (r <= 0.5) {
            return box_signed_distance(pixel, float2(width, height) * 0.5, float2(width, height) * 0.5);
        }

        if (pixel.y < r) {
            if (pixel.x < r) {
                return length(pixel - float2(r, r)) - r;
            }
            if (pixel.x > width - r) {
                return length(pixel - float2(width - r, r)) - r;
            }
        }

        return box_signed_distance(pixel, float2(width, height) * 0.5, float2(width, height) * 0.5);
    }

    vertex LoopRegionRasterizedVertex loop_region_vertex(
        uint vertexID [[vertex_id]],
        constant WaveformShaderQuadVertex *vertices [[buffer(0)]],
        constant LoopRegionUniform &uniform [[buffer(1)]]
    ) {
        float2 localPosition = vertices[vertexID].position.xy;
        float2 normalizedPosition = float2(
            mix(uniform.rect.x, uniform.rect.y, localPosition.x),
            mix(uniform.rect.z, uniform.rect.w, localPosition.y)
        );

        LoopRegionRasterizedVertex out;
        out.position = float4(
            normalizedPosition.x * 2.0 - 1.0,
            1.0 - normalizedPosition.y * 2.0,
            0.0,
            1.0
        );
        out.localPosition = localPosition;
        out.metrics = uniform.metrics;
        out.style = uniform.style;
        out.edgeHighlight = uniform.edgeHighlight;
        out.fillColor = uniform.fillColor;
        out.topColor = uniform.topColor;
        out.bottomColor = uniform.bottomColor;
        out.edgeColor = uniform.edgeColor;
        return out;
    }

    fragment float4 loop_region_fragment(
        LoopRegionRasterizedVertex in [[stage_in]],
        constant LoopRegionUniform &uniform [[buffer(1)]]
    ) {
        float widthPixels = max(in.metrics.x, 1.0);
        float heightPixels = max(in.metrics.y, 1.0);
        float radiusPixels = max(in.metrics.z, 1.0);
        float edgeWidthPixels = max(in.metrics.w, 1.0);
        float2 pixel = float2(in.localPosition.x * widthPixels, in.localPosition.y * heightPixels);

        float distance = top_rounded_tab_signed_distance(pixel, widthPixels, heightPixels, radiusPixels);
        float aa = max(fwidth(distance), 0.82);
        float coverage = 1.0 - smoothstep(-aa, aa, distance);
        if (coverage <= 0.0001) {
            return float4(0.0);
        }

        float enabled = clamp(in.style.x, 0.0, 1.0);
        float hover = clamp(in.style.y, 0.0, 1.0);
        float flash = clamp(in.style.z, 0.0, 1.0);
        float time = in.style.w;
        float y = clamp(in.localPosition.y, 0.0, 1.0);
        float x = clamp(in.localPosition.x, 0.0, 1.0);

        float edgeDistance = abs(distance);
        float rim = exp(-(edgeDistance * edgeDistance) / max(10.0, 8.0 + radiusPixels * 0.6));
        float innerRim = exp(-pow(max(-distance, 0.0) / max(4.0, radiusPixels * 0.52), 2.0));
        float topSheen = pow(max(1.0 - y, 0.0), 2.1);
        float bottomShade = pow(max(y, 0.0), 2.4);
        float sideEdgeDistance = min(pixel.x, widthPixels - pixel.x);
        float sideRim = exp(-pow(sideEdgeDistance / max(edgeWidthPixels * 3.4, 2.0), 2.0));
        float hoveredEdgeSide = clamp(in.edgeHighlight.x, -1.0, 1.0);
        float hoveredEdgeAmount = clamp(in.edgeHighlight.y, 0.0, 1.0);
        float hoveredEdgeDistance = hoveredEdgeSide < 0.0 ? pixel.x : widthPixels - pixel.x;
        float hoveredEdgeCore = exp(-pow(hoveredEdgeDistance / max(edgeWidthPixels * 1.35, 1.35), 2.0));
        float hoveredEdgeHalo = exp(-pow(hoveredEdgeDistance / max(edgeWidthPixels * 5.8, 5.8), 2.0));
        float hoveredEdgeGlow = hoveredEdgeAmount * (hoveredEdgeCore * 0.72 + hoveredEdgeHalo * 0.42);

        float liquidA = sin(pixel.x * 0.047 + pixel.y * 0.071 + time * 0.95);
        float liquidB = sin(pixel.x * -0.031 + pixel.y * 0.055 + time * 0.62 + liquidA * 0.85);
        float liquid = 0.5 + 0.5 * (liquidA * 0.56 + liquidB * 0.44);
        liquid = smoothstep(0.18, 1.0, liquid);
        float refract = (liquid - 0.5) * (0.045 + enabled * 0.04) + flash * 0.045;

        float3 fill = in.fillColor.rgb;
        float3 top = in.topColor.rgb;
        float3 bottom = in.bottomColor.rgb;
        float3 edge = in.edgeColor.rgb;
        float3 color = fill;
        color = mix(color, top, topSheen * (0.42 + enabled * 0.12));
        color = mix(color, bottom, bottomShade * 0.24);
        color += float3(0.11, 0.16, 0.17) * refract * enabled;
        color = mix(color, edge, rim * (0.20 + hover * 0.12 + flash * 0.18));
        color = mix(color, float3(1.0), flash * 0.16 + innerRim * 0.035);
        color = mix(color, float3(1.0), clamp(hoveredEdgeGlow * 0.72, 0.0, 0.82));

        float alpha = in.fillColor.a * (0.82 + topSheen * 0.24 + rim * 0.24 + hover * 0.12 + flash * 0.20);
        alpha += in.topColor.a * topSheen * 0.32;
        alpha += in.bottomColor.a * bottomShade * 0.18;
        alpha += in.edgeColor.a * (rim * 0.16 + sideRim * 0.055);
        alpha += hoveredEdgeAmount * (hoveredEdgeCore * 0.34 + hoveredEdgeHalo * 0.20);
        alpha *= coverage;

        float bottomSnap = 1.0 - smoothstep(0.0, 1.0 / max(heightPixels, 1.0), abs(1.0 - y));
        color = mix(color, bottom, bottomSnap * 0.18);
        alpha = min(alpha + bottomSnap * 0.018, 1.0);

        return float4(clamp(color, float3(0.0), float3(1.0)), clamp(alpha, 0.0, 1.0));
    }

    static float4 selection_glass_overlay_color(
        float2 localPosition,
        float2 pixel,
        float widthPixels,
        float heightPixels,
        float radiusPixels,
        float progressFraction,
        float4 style,
        float4 pulse,
        float4 baseColor,
        float4 progressFillColor
    ) {
        float2 centered = pixel - float2(widthPixels, heightPixels) * 0.5;
        float distance = rounded_rect_signed_distance(
            centered,
            max(float2(widthPixels, heightPixels) * 0.5, float2(radiusPixels + 0.5)),
            radiusPixels
        );
        float aa = max(fwidth(distance), 0.85);
        float coverage = 1.0 - smoothstep(-aa, aa, distance);
        if (coverage <= 0.0001) {
            return float4(0.0);
        }

        float edgeDistance = abs(distance);
        float rim = exp(-(edgeDistance * edgeDistance) / max(18.0, 16.0 + radiusPixels * 0.35));
        float innerRim = exp(-pow(max(-distance, 0.0) / max(6.0, radiusPixels * 0.55), 2.0));
        float outerRim = exp(-pow(max(distance, 0.0) / max(5.0, radiusPixels * 0.35), 2.0));
        float topSheen = pow(max(1.0 - localPosition.y, 0.0), 2.35);
        float lowerShade = pow(max(localPosition.y, 0.0), 2.8);
        float caustic = hash21(floor(pixel * float2(0.115, 0.073) + style.w));
        caustic = smoothstep(0.46, 1.0, caustic) * 0.42;
        float wave = 0.5 + 0.5 * sin((pixel.x * 0.055 - pixel.y * 0.018) + style.w * 0.24);

        float dragEdgeLocalX = style.x;
        float dragStrength = clamp(style.y, 0.0, 1.0);
        float dragDirection = style.z >= 0.0 ? 1.0 : -1.0;
        float dragEdge = 0.0;
        float refractivePush = 0.0;
        if (dragEdgeLocalX >= 0.0 && dragEdgeLocalX <= 1.0 && dragStrength > 0.001) {
            float edgeX = dragEdgeLocalX * widthPixels;
            float distX = abs(pixel.x - edgeX);
            float insideSide = dragDirection > 0.0 ? step(pixel.x, edgeX) : step(edgeX, pixel.x);
            float outsideDistance = dragDirection > 0.0 ? max(pixel.x - edgeX, 0.0) : max(edgeX - pixel.x, 0.0);
            float outsideLimiter = exp(-(outsideDistance * outsideDistance) / max(14.0, 6.0 + dragStrength * 12.0));
            float insideTrail = exp(-(distX * distX) / max(72.0, 30.0 + dragStrength * 95.0));
            dragEdge = mix(outsideLimiter * 0.34, insideTrail, insideSide) * dragStrength;
            refractivePush = exp(-(distX * distX) / max(20.0, 10.0 + dragStrength * 26.0)) * dragStrength;
        }

        float4 base = baseColor;
        float glassAlpha = base.a * (0.78 + topSheen * 0.26 + rim * 0.42 + dragEdge * 0.22);
        float3 glassTint = base.rgb;
        glassTint = mix(glassTint, float3(0.78, 1.0, 1.0), 0.20 * topSheen + 0.12 * rim + 0.18 * dragEdge);
        glassTint = mix(glassTint, float3(0.02, 0.18, 0.19), 0.12 * lowerShade);
        glassTint += float3(0.06, 0.10, 0.11) * caustic * (0.25 + 0.35 * wave);
        glassTint += float3(0.18, 0.35, 0.38) * refractivePush * 0.18;

        float4 color = float4(glassTint, glassAlpha * coverage);
        float4 rimColor = float4(
            mix(float3(0.40, 0.96, 1.0), float3(1.0), clamp(rim * 0.35 + dragEdge * 0.45, 0.0, 1.0)),
            coverage * (rim * 0.13 + innerRim * 0.045 + outerRim * 0.05 + dragEdge * 0.12)
        );
        color = source_over(color, rimColor);

        if (progressFraction >= 0.0 && localPosition.x <= progressFraction) {
            float progressEdge = 1.0 - smoothstep(0.0, max(0.006, fwidth(localPosition.x) * 2.0), abs(localPosition.x - progressFraction));
            float4 progressColor = float4(
                mix(progressFillColor.rgb, float3(1.0), progressEdge * 0.28),
                progressFillColor.a * coverage * (0.76 + progressEdge * 0.34)
            );
            color = source_over(color, progressColor);
        }

        float copyPulse = clamp(pulse.x, 0.0, 1.0);
        if (copyPulse > 0.001) {
            float4 pulseColor = float4(
                mix(float3(0.42, 0.96, 1.0), float3(1.0), 0.56),
                coverage * (0.10 + 0.32 * copyPulse)
            );
            color = source_over(color, pulseColor);
        }

        return float4(clamp(color.rgb, float3(0.0), float3(1.0)), clamp(color.a, 0.0, 1.0));
    }

    fragment float4 selection_overlay_fragment(
        SelectionOverlayRasterizedVertex in [[stage_in]],
        constant SelectionOverlayUniform &uniform [[buffer(1)]]
    ) {
        float widthPixels = max(in.metrics.x, 1.0);
        float heightPixels = max(in.metrics.y, 1.0);
        float radiusPixels = max(in.metrics.z, 1.0);
        float2 pixel = float2(in.localPosition.x * widthPixels, in.localPosition.y * heightPixels);
        return selection_glass_overlay_color(
            in.localPosition,
            pixel,
            widthPixels,
            heightPixels,
            radiusPixels,
            in.metrics.w,
            in.style,
            in.pulse,
            in.baseColor,
            in.progressColor
        );
    }

    vertex SelectionDragEffectRasterizedVertex selection_drag_effect_vertex(
        uint vertexID [[vertex_id]],
        constant WaveformShaderQuadVertex *vertices [[buffer(0)]],
        constant SelectionDragEffectUniform &uniform [[buffer(1)]]
    ) {
        float2 localPosition = vertices[vertexID].position.xy;
        float2 normalizedPosition = float2(
            mix(uniform.rect.x, uniform.rect.y, localPosition.x),
            mix(uniform.rect.z, uniform.rect.w, localPosition.y)
        );

        SelectionDragEffectRasterizedVertex out;
        out.position = float4(
            normalizedPosition.x * 2.0 - 1.0,
            1.0 - normalizedPosition.y * 2.0,
            0.0,
            1.0
        );
        out.localPosition = localPosition;
        out.metrics = uniform.metrics;
        out.effect = uniform.effect;
        out.color = uniform.color;
        out.mask = uniform.mask;
        return out;
    }

    fragment float4 selection_drag_effect_fragment(
        SelectionDragEffectRasterizedVertex in [[stage_in]],
        constant SelectionDragEffectUniform &uniform [[buffer(1)]]
    ) {
        float widthPixels = max(in.metrics.x, 1.0);
        float heightPixels = max(in.metrics.y, 1.0);
        float halfWidthPixels = max(in.metrics.z, 1.0);
        float edgeLocalX = clamp(in.metrics.w, 0.0, 1.0);
        float strength = clamp(in.effect.x, 0.0, 1.0);
        float age = max(in.effect.y, 0.0);
        float seed = in.effect.z;
        float direction = in.effect.w >= 0.0 ? 1.0 : -1.0;

        float2 pixel = float2(in.localPosition.x * widthPixels, in.localPosition.y * heightPixels);
        float selectionLeft = in.mask.x;
        float selectionRight = in.mask.y;
        if (selectionRight <= selectionLeft + 0.5) {
            return float4(0.0);
        }
        float selectionRadius = max(in.mask.z, 1.0);
        float2 selectionCenter = float2((selectionLeft + selectionRight) * 0.5, heightPixels * 0.5);
        float2 selectionHalfSize = float2(
            max((selectionRight - selectionLeft) * 0.5, 0.5),
            max(heightPixels * 0.5, selectionRadius + 0.5)
        );
        float maskDistance = rounded_rect_signed_distance(pixel - selectionCenter, selectionHalfSize, selectionRadius);
        float maskAA = max(fwidth(maskDistance), 0.85);
        float roundedSelectionCoverage = 1.0 - smoothstep(-maskAA, maskAA, maskDistance);
        if (roundedSelectionCoverage <= 0.0001) {
            return float4(0.0);
        }

        float edgeX = edgeLocalX * widthPixels;
        float endRadius = min(max(10.0, heightPixels * 0.06), max(heightPixels * 0.50, 1.0));
        float segmentTop = endRadius;
        float segmentBottom = max(heightPixels - endRadius, segmentTop);
        float clampedY = clamp(pixel.y, segmentTop, segmentBottom);
        float capsuleDistance = length(pixel - float2(edgeX, clampedY));

        float glowWidth = 6.0 + 14.0 * strength;
        float glow = exp(-(capsuleDistance * capsuleDistance) / max(glowWidth * glowWidth, 0.001));
        float aura = exp(-(capsuleDistance * capsuleDistance) / max(pow(glowWidth * 1.85, 2.0), 0.001));

        float trailingSide = direction > 0.0 ? step(pixel.x, edgeX) : step(edgeX, pixel.x);
        float outsideDistance = direction > 0.0 ? max(pixel.x - edgeX, 0.0) : max(edgeX - pixel.x, 0.0);
        float outsideWidth = 2.2 + 1.3 * strength;
        float outsideLimiter = mix(
            exp(-(outsideDistance * outsideDistance) / max(outsideWidth * outsideWidth, 0.001)),
            1.0,
            trailingSide
        );
        float trailDistance = direction > 0.0 ? max(edgeX - pixel.x, 0.0) : max(pixel.x - edgeX, 0.0);
        float alpha = in.color.a * strength * outsideLimiter * roundedSelectionCoverage * (glow * 0.32 + aura * 0.12);
        float3 glowColor = mix(float3(0.22, 0.86, 1.0), float3(1.0), min(glow * 0.18, 1.0));
        float3 color = mix(in.color.rgb, glowColor, 0.42 + 0.36 * strength);
        return float4(color, clamp(alpha, 0.0, 1.0));
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
        float progress = clamp(effect.timing.x, 0.0, 1.0);
        float left = effect.rect.x;
        float right = effect.rect.y;
        float top = effect.rect.z;
        float bottom = effect.rect.w;
        float slide = clamp(effect.ripple.y, 0.0, 1.0);
        float mode = effect.ripple.z;
        float shiftedRight = mode > 1.5 ? mix(left, right, slide) : mix(right, left, slide);
        float selectionRight = max(left + 1.0 / width, shiftedRight);
        float2 point = in.normalizedPosition;
        float yAA = max(fwidth(point.y) * 0.75, 0.000001);
        float4 color = float4(0.0);

        if (point.y >= top && point.y <= bottom) {
            float laneCoverage = rectangle_coverage(point.y, top, bottom, yAA);
            float selectionWidthPixels = (selectionRight - left) * width;
            if (selectionWidthPixels > 1.0 &&
                point.x >= left &&
                point.x <= selectionRight) {
                float selectionXAA = max(fwidth(point.x) * 1.25, 1.0 / width);
                float selectionCoverage = laneCoverage *
                    rectangle_coverage(point.x, left, selectionRight, selectionXAA);
                if (mode > 1.5) {
                    float selectionHeightPixels = max((bottom - top) * height, 1.0);
                    float radiusPixels = min(
                        max(8.0, selectionHeightPixels * 0.075),
                        min(18.0, selectionWidthPixels * 0.5)
                    );
                    float2 selectionLocal = float2(
                        clamp((point.x - left) / max(selectionRight - left, 0.000001), 0.0, 1.0),
                        clamp((point.y - top) / max(bottom - top, 0.000001), 0.0, 1.0)
                    );
                    float2 selectionPixel = float2(
                        selectionLocal.x * selectionWidthPixels,
                        selectionLocal.y * selectionHeightPixels
                    );
                    float2 selectionCentered = selectionPixel - float2(selectionWidthPixels, selectionHeightPixels) * 0.5;
                    float selectionDistance = rounded_rect_signed_distance(
                        selectionCentered,
                        max(float2(selectionWidthPixels, selectionHeightPixels) * 0.5, float2(radiusPixels + 0.5)),
                        radiusPixels
                    );
                    float selectionAA = max(fwidth(selectionDistance), 0.85);
                    selectionCoverage = 1.0 - smoothstep(-selectionAA, selectionAA, selectionDistance);
                    float edgeStrength = (1.0 - smoothstep(0.72, 1.0, slide)) * 0.52;
                    color = source_over(
                        color,
                        selection_glass_overlay_color(
                            selectionLocal,
                            selectionPixel,
                            selectionWidthPixels,
                            selectionHeightPixels,
                            radiusPixels,
                            -1.0,
                            float4(1.0, edgeStrength, 1.0, effect.timing.z + effect.timing.y),
                            float4(0.0),
                            float4(0.02, 0.82, 0.88, 0.18),
                            float4(0.28, 0.96, 1.0, 0.20)
                        )
                    );
                } else {
                    float edgePulse = 1.0 - smoothstep(
                        0.0,
                        max(3.5 / width, 0.000001),
                        abs(point.x - selectionRight)
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

                if (mode > 1.5) {
                    uint binCount = uint(max(effect.timing.w, 1.0));
                    float fullWidth = max(right - left, 0.000001);
                    float revealedFraction = min(max(slide, 1.0 / max(fullWidth * width, 1.0)), 1.0);
                    float visibleProgress = clamp((point.x - left) / max(fullWidth * revealedFraction, 0.000001), 0.0, 1.0);
                    float localProgress = clamp(1.0 - revealedFraction + visibleProgress * revealedFraction, 0.0, 1.0);
                    WaveformShaderBin bin = sample_waveform_bin(localProgress, bins, binCount, 0u, 0.45);
                    float centerY = (top + bottom) * 0.5;
                    float laneHeight = max(bottom - top, 0.000001);
                    float waveformVolumeScale = max(effect.waveformStyle.w, 0.0);
                    float amplitude = laneHeight * 0.39 * waveformVolumeScale;
                    float peakTop = centerY - clamp(bin.maximumSample, -1.0, 1.0) * amplitude;
                    float peakBottom = centerY - clamp(bin.minimumSample, -1.0, 1.0) * amplitude;
                    float minimumVisualHeight = laneHeight * 0.006;
                    if (peakBottom - peakTop < minimumVisualHeight) {
                        float midpoint = (peakTop + peakBottom) * 0.5;
                        peakTop = midpoint - minimumVisualHeight * 0.5;
                        peakBottom = midpoint + minimumVisualHeight * 0.5;
                    }
                    peakTop = clamp(peakTop, top, bottom);
                    peakBottom = clamp(peakBottom, top, bottom);
                    float waveformCoverage = rectangle_coverage(point.y, peakTop, peakBottom, yAA);
                    if (waveformCoverage > 0.0) {
                        float waveformAlpha = clamp(effect.waveformStyle.y, 0.0, 1.0) * selectionCoverage;
                        float4 baseColor = waveform_base_color(
                            bin,
                            clamp(effect.waveformStyle.x, 0.0, 1.0),
                            waveformAlpha,
                            clamp(effect.waveformStyle.z, 0.0, 1.0)
                        );
                        float peakAlpha = clamp(effect.waveformStyle2.x, 0.0, 1.0);
                        float bodyAlpha = clamp(effect.waveformStyle2.y, 0.0, 1.0);
                        float glowAlpha = clamp(effect.waveformStyle2.z, 0.0, 1.0);
                        float glowExpansion = max(effect.waveformStyle2.w, 0.0);

                        if (glowAlpha > 0.001) {
                            float glowTop = max(peakTop - glowExpansion, top);
                            float glowBottom = min(peakBottom + glowExpansion, bottom);
                            float glowCoverage = rectangle_coverage(point.y, glowTop, glowBottom, yAA);
                            if (glowCoverage > 0.0) {
                                float4 glowColor = lightened_color(
                                    baseColor,
                                    0.18,
                                    glowAlpha * waveformAlpha * glowCoverage
                                );
                                color = source_over(color, glowColor);
                            }
                        }

                        if (bodyAlpha > 0.001) {
                            float4 bodyColor = lightened_color(
                                baseColor,
                                0.14,
                                bodyAlpha * waveformAlpha
                            );
                            color = source_over(
                                color,
                                center_weighted_waveform_band(
                                    point.y,
                                    peakTop,
                                    peakBottom,
                                    centerY,
                                    bodyColor,
                                    color_with_alpha(bodyColor, bodyColor.a * 0.42),
                                    yAA
                                )
                            );
                        }

                        float4 peakCenterColor = lightened_color(
                            baseColor,
                            0.12,
                            peakAlpha * waveformAlpha
                        );
                        float4 peakEdgeColor = color_with_alpha(
                            baseColor,
                            peakAlpha * 0.42 * waveformAlpha
                        );
                        color = source_over(
                            color,
                            center_weighted_waveform_band(
                                point.y,
                                peakTop,
                                peakBottom,
                                centerY,
                                peakCenterColor,
                                peakEdgeColor,
                                yAA
                            )
                        );
                    }
                }
            }
        }

        return float4(clamp(color.rgb, float3(0.0), float3(1.0)), clamp(color.a, 0.0, 1.0));
    }

    static float deletion_warp_source_x(float x, float4 warp) {
        if (warp.w <= 0.0 || warp.z <= 0.00001) {
            return x;
        }

        float left = min(warp.x, warp.y);
        float right = max(warp.x, warp.y);
        float width = max(right - left, 0.000001);
        float slide = clamp(warp.z, 0.0, 1.0);
        if (warp.w > 1.5) {
            float growingRight = left + width * slide;
            if (x < left) {
                return x;
            }
            if (x < growingRight) {
                return -1000.0;
            }

            return x - width * slide;
        }

        if (x < left) {
            return x;
        }

        // Translate the delete region and everything after it leftward at normal
        // scale. Samples that would move past `left` are clipped by the unchanged
        // pre-delete region to the left of the boundary.
        return x + width * slide;
    }

    static float2 selection_drag_contact_influence(
        float timelineProgress,
        float4 contact,
        float4 tuning
    ) {
        if (contact.w <= 0.0 || contact.y <= 0.0001 || abs(contact.z) < 0.5) {
            return float2(0.0);
        }

        float offset = timelineProgress - contact.x;
        float signedOffset = offset * contact.z;
        float frontSide = step(0.0, signedOffset);
        float radius = mix(max(tuning.y, 0.0000001), max(tuning.x, 0.0000001), frontSide);
        float sideScale = mix(0.95, 0.28, frontSide);
        float lightScale = mix(0.78, 0.20, frontSide);
        float sideRatio = clamp(1.0 - abs(offset) / radius, 0.0, 1.0);
        float sideSmooth = sideRatio * sideRatio * (3.0 - 2.0 * sideRatio);
        float sideContact = mix(
            sideSmooth * (0.62 + 0.38 * sideSmooth),
            sideSmooth * sideSmooth,
            frontSide
        );

        float coreRadius = max(tuning.z, 0.0000001);
        float coreRatio = clamp(1.0 - abs(offset) / coreRadius, 0.0, 1.0);
        float coreContact = coreRatio * coreRatio * (3.0 - 2.0 * coreRatio);
        float strength = clamp(contact.y, 0.0, 1.0);
        float geometry = max(sideContact * sideScale, coreContact) * strength;
        float light = max(sideContact * lightScale, coreContact * 0.92) * strength;
        return clamp(float2(geometry, light), float2(0.0), float2(1.0));
    }

    static float2 selection_drag_waveform_influence(
        float timelineProgress,
        WaveformRasterizedVertex vertexIn
    ) {
        float selectionStart = min(vertexIn.selectionDrag2.z, vertexIn.selectionDrag2.w);
        float selectionEnd = max(vertexIn.selectionDrag2.z, vertexIn.selectionDrag2.w);
        if (selectionEnd <= selectionStart ||
            timelineProgress < selectionStart ||
            timelineProgress > selectionEnd) {
            return float2(0.0);
        }

        float2 influence = float2(0.0);
        float count = clamp(vertexIn.selectionDrag.w, 0.0, 8.0);
        if (count > 0.5) {
            influence = max(influence, selection_drag_contact_influence(timelineProgress, vertexIn.selectionDragContact0, vertexIn.selectionDrag));
        }
        if (count > 1.5) {
            influence = max(influence, selection_drag_contact_influence(timelineProgress, vertexIn.selectionDragContact1, vertexIn.selectionDrag));
        }
        if (count > 2.5) {
            influence = max(influence, selection_drag_contact_influence(timelineProgress, vertexIn.selectionDragContact2, vertexIn.selectionDrag));
        }
        if (count > 3.5) {
            influence = max(influence, selection_drag_contact_influence(timelineProgress, vertexIn.selectionDragContact3, vertexIn.selectionDrag));
        }
        if (count > 4.5) {
            influence = max(influence, selection_drag_contact_influence(timelineProgress, vertexIn.selectionDragContact4, vertexIn.selectionDrag));
        }
        if (count > 5.5) {
            influence = max(influence, selection_drag_contact_influence(timelineProgress, vertexIn.selectionDragContact5, vertexIn.selectionDrag));
        }
        if (count > 6.5) {
            influence = max(influence, selection_drag_contact_influence(timelineProgress, vertexIn.selectionDragContact6, vertexIn.selectionDrag));
        }
        if (count > 7.5) {
            influence = max(influence, selection_drag_contact_influence(timelineProgress, vertexIn.selectionDragContact7, vertexIn.selectionDrag));
        }
        return clamp(influence, float2(0.0), float2(1.0));
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
        float warpedSourceX = deletion_warp_source_x(in.normalizedPosition.x, in.deletionWarp);
        float sampleX = inverse_fisheye_x(warpedSourceX, in.fisheye);
        float timelineProgress = in.viewport.x + sampleX * in.viewport.y;

        if (timelineProgress < 0.0 ||
            timelineProgress > trackDurationProgress ||
            in.normalizedPosition.y < laneTop ||
            in.normalizedPosition.y > laneBottom) {
            return float4(0.0);
        }

        float outputStart = clamp(in.sourceMap.x, 0.0, trackDurationProgress);
        float outputEnd = clamp(max(in.sourceMap.y, outputStart), 0.0, trackDurationProgress);
        float outputWidth = outputEnd - outputStart;
        if (outputWidth <= 0.0000001 ||
            timelineProgress < outputStart ||
            timelineProgress > outputEnd) {
            return float4(0.0);
        }

        float segmentProgress = clamp((timelineProgress - outputStart) / max(outputWidth, 0.0000001), 0.0, 1.0);
        float sourceStart = clamp(in.sourceMap.z, 0.0, 1.0);
        float sourceEnd = clamp(in.sourceMap.w, 0.0, 1.0);
        float localProgress = clamp(mix(sourceStart, sourceEnd, segmentProgress), 0.0, 1.0);
        float smoothAmount = max(
            clamp(in.track.w, 0.0, 1.0),
            fisheye_sample_smoothing(in.normalizedPosition.x, in.fisheye)
        );
        WaveformShaderBin bin = sample_waveform_bin(localProgress, bins, binCount, binOffset, smoothAmount);
        float localPixelSpan = max(fwidth(localProgress), 0.0);
        float pixelBinSpan = localPixelSpan * float(binCount);
        if (pixelBinSpan > 0.75) {
            float envelopeAmount = smoothstep(0.75, 3.5, pixelBinSpan);
            float halfSpan = localPixelSpan * 0.55;
            float fullSpan = localPixelSpan * 1.10;
            WaveformShaderBin leftNearBin = sample_waveform_bin(localProgress - halfSpan, bins, binCount, binOffset, 0.0);
            WaveformShaderBin rightNearBin = sample_waveform_bin(localProgress + halfSpan, bins, binCount, binOffset, 0.0);
            WaveformShaderBin leftFarBin = sample_waveform_bin(localProgress - fullSpan, bins, binCount, binOffset, 0.0);
            WaveformShaderBin rightFarBin = sample_waveform_bin(localProgress + fullSpan, bins, binCount, binOffset, 0.0);
            float envelopeMinimum = min(
                min(leftFarBin.minimumSample, leftNearBin.minimumSample),
                min(rightNearBin.minimumSample, rightFarBin.minimumSample)
            );
            float envelopeMaximum = max(
                max(leftFarBin.maximumSample, leftNearBin.maximumSample),
                max(rightNearBin.maximumSample, rightFarBin.maximumSample)
            );
            float envelopeRMS = max(
                max(leftFarBin.rmsSample, leftNearBin.rmsSample),
                max(rightNearBin.rmsSample, rightFarBin.rmsSample)
            );
            float envelopePeak = max(
                max(leftFarBin.peakMagnitude, leftNearBin.peakMagnitude),
                max(rightNearBin.peakMagnitude, rightFarBin.peakMagnitude)
            );
            bin.minimumSample = mix(bin.minimumSample, min(bin.minimumSample, envelopeMinimum), envelopeAmount);
            bin.maximumSample = mix(bin.maximumSample, max(bin.maximumSample, envelopeMaximum), envelopeAmount);
            bin.rmsSample = mix(bin.rmsSample, max(bin.rmsSample, envelopeRMS), envelopeAmount * 0.35);
            bin.peakMagnitude = mix(bin.peakMagnitude, max(bin.peakMagnitude, envelopePeak), envelopeAmount);
        }
        float segmentGain = mix(in.segmentGain.x, in.segmentGain.y, smoothstep(0.0, 1.0, segmentProgress));
        float gain = waveform_gain(timelineProgress, in.gainPreview) * max(segmentGain, 0.0);
        float minimumSample = clamp(bin.minimumSample * gain, -1.0, 1.0);
        float maximumSample = clamp(bin.maximumSample * gain, -1.0, 1.0);
        float rmsSample = clamp(bin.rmsSample * gain, 0.0, 1.0);
        float signalMagnitude = max(max(abs(minimumSample), abs(maximumSample)), rmsSample);
        float touchSignalEnergy = smoothstep(0.006, 0.055, signalMagnitude);
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
        float playheadGeometryInfluence = geometryInfluence * touchSignalEnergy;
        float playheadLightInfluence = lightInfluence * touchSignalEnergy;

        float2 dragInfluence = selection_drag_waveform_influence(timelineProgress, in);
        float dragGeometryInfluence = dragInfluence.x * touchSignalEnergy;
        float dragLightInfluence = dragInfluence.y * touchSignalEnergy;

        geometryInfluence = max(playheadGeometryInfluence, dragGeometryInfluence);
        lightInfluence = max(playheadLightInfluence, dragLightInfluence);
        float expansion = 1.0 +
            0.30 * playheadGeometryInfluence +
            in.selectionDrag2.x * dragGeometryInfluence;

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
        float y = in.normalizedPosition.y;
        float yAA = max(fwidth(y) * 0.75, 0.000001);
        float alphaScale = clamp(in.baseColor.a * opacity, 0.0, 1.0);
        float4 baseColor = waveform_base_color(bin, in.baseColor.r, alphaScale, in.style.x);
        if (lightInfluence > 0.001) {
            float dragLightScale = mix(0.72, clamp(in.selectionDrag2.y, 0.0, 1.0), step(0.001, dragLightInfluence));
            baseColor = lightened_color(baseColor, min(lightInfluence * dragLightScale, 1.0), alphaScale);
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

        if (in.style.z > 0.001) {
            float4 bodyColor = lightened_color(baseColor, 0.14, in.style.z * alphaScale);
            color = source_over(
                color,
                center_weighted_waveform_band(
                    y,
                    peakTop,
                    peakBottom,
                    centerY,
                    bodyColor,
                    color_with_alpha(bodyColor, bodyColor.a * 0.42),
                    yAA
                )
            );
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
            float yCoverage = rectangle_coverage(y, peakTop, peakBottom, yAA);
            float shapedTransient = transientStrength * transientStrength;
            float coverage = yCoverage * shapedTransient;
            if (coverage > 0.0) {
                float4 transientColor = lightened_color(
                    baseColor,
                    0.16,
                    in.style2.x * alphaScale * coverage * 0.10
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
