import Foundation

enum WaveformTileDrawLayerRole: String, Hashable, Sendable {
    case current
    case previous
}

struct WaveformTileDrawBatchKey: Hashable, Sendable, Comparable {
    let kind: WaveformTileKind
    let channelMode: WaveformChannelMode

    static func < (lhs: WaveformTileDrawBatchKey, rhs: WaveformTileDrawBatchKey) -> Bool {
        (
            lhs.kind.rawValue,
            lhs.channelMode.rawValue
        ) < (
            rhs.kind.rawValue,
            rhs.channelMode.rawValue
        )
    }
}

struct WaveformTileDrawInstance: Hashable, Sendable {
    let trackID: UUID
    let trackIndex: Int
    let laneTop: Float
    let laneBottom: Float
    let outputStartTime: TimeInterval
    let outputEndTime: TimeInterval
    let sourceStartTime: TimeInterval
    let sourceEndTime: TimeInterval
    let sourceDuration: TimeInterval
    let sourceSampleRate: Double
    let requestedDescriptor: WaveformTileDescriptor
    let tileDescriptor: WaveformTileDescriptor
    let resource: WaveformTileGPUResource
    let alpha: Float
    let role: WaveformTileDrawLayerRole
}

struct WaveformTileDrawBatch: Equatable, Sendable {
    let key: WaveformTileDrawBatchKey
    let instances: [WaveformTileDrawInstance]

    var instanceCount: Int {
        instances.count
    }
}

struct WaveformTileDrawBatchPlan: Equatable, Sendable {
    let batches: [WaveformTileDrawBatch]
    let instanceCount: Int
    let resourceCount: Int

    static let empty = WaveformTileDrawBatchPlan(
        batches: [],
        instanceCount: 0,
        resourceCount: 0
    )

    var batchCount: Int {
        batches.count
    }

    var logicalDrawCallCount: Int {
        batchCount
    }

    /// Resident plans are emitted only after the selector has complete visible coverage.
    /// Once present, they replace the overview base instead of blending on top of it.
    func shouldDrawOverviewBaseWaveform(trackID: UUID, sourceID: WaveformSourceID) -> Bool {
        !batches.contains { batch in
            batch.instances.contains { instance in
                instance.trackID == trackID &&
                    instance.tileDescriptor.address.sourceID == sourceID
            }
        }
    }

    mutating func append(_ other: WaveformTileDrawBatchPlan) {
        guard !other.batches.isEmpty else {
            return
        }

        var instancesByKey = Dictionary(uniqueKeysWithValues: batches.map { ($0.key, $0.instances) })
        for batch in other.batches {
            instancesByKey[batch.key, default: []].append(contentsOf: batch.instances)
        }

        let sortedBatches = instancesByKey.keys.sorted().map { key in
            WaveformTileDrawBatch(
                key: key,
                instances: instancesByKey[key] ?? []
            )
        }
        let resources = Set(sortedBatches.flatMap { batch in
            batch.instances.map(\.resource.id)
        })
        self = WaveformTileDrawBatchPlan(
            batches: sortedBatches,
            instanceCount: sortedBatches.reduce(0) { $0 + $1.instanceCount },
            resourceCount: resources.count
        )
    }
}

enum WaveformTileDrawBatchPlanner {
    static func plan(
        trackID: UUID,
        trackIndex: Int,
        laneFrame: TimelineTrackLaneFrame,
        source: WaveformTileSourceMetadata,
        segments: [WaveformTileSchedulerSegment],
        promotionPlan: WaveformTilePromotionPlan
    ) -> WaveformTileDrawBatchPlan {
        guard source.duration > 0, source.sampleRate > 0, !promotionPlan.tiles.isEmpty else {
            return .empty
        }

        let drawSegments = segments.isEmpty ? [
            WaveformTileSchedulerSegment(
                outputStartTime: 0,
                outputEndTime: source.duration,
                sourceStartTime: 0,
                sourceEndTime: source.duration
            ),
        ] : segments

        var instancesByKey: [WaveformTileDrawBatchKey: [WaveformTileDrawInstance]] = [:]
        var resourceIDs = Set<WaveformTileGPUResourceID>()

        for promotedTile in promotionPlan.tiles {
            appendInstances(
                layer: promotedTile.current,
                requestedDescriptor: promotedTile.requestedDescriptor,
                role: .current,
                trackID: trackID,
                trackIndex: trackIndex,
                laneFrame: laneFrame,
                source: source,
                segments: drawSegments,
                instancesByKey: &instancesByKey,
                resourceIDs: &resourceIDs
            )

            if let previous = promotedTile.previous {
                appendInstances(
                    layer: previous,
                    requestedDescriptor: promotedTile.requestedDescriptor,
                    role: .previous,
                    trackID: trackID,
                    trackIndex: trackIndex,
                    laneFrame: laneFrame,
                    source: source,
                    segments: drawSegments,
                    instancesByKey: &instancesByKey,
                    resourceIDs: &resourceIDs
                )
            }
        }

        let batches = instancesByKey.keys.sorted().map { key in
            WaveformTileDrawBatch(
                key: key,
                instances: (instancesByKey[key] ?? []).sorted { lhs, rhs in
                    if lhs.trackIndex != rhs.trackIndex {
                        return lhs.trackIndex < rhs.trackIndex
                    }
                    if lhs.outputStartTime != rhs.outputStartTime {
                        return lhs.outputStartTime < rhs.outputStartTime
                    }
                    if lhs.tileDescriptor.address != rhs.tileDescriptor.address {
                        return lhs.tileDescriptor.address < rhs.tileDescriptor.address
                    }
                    return lhs.role.rawValue < rhs.role.rawValue
                }
            )
        }

        return WaveformTileDrawBatchPlan(
            batches: batches,
            instanceCount: batches.reduce(0) { $0 + $1.instanceCount },
            resourceCount: resourceIDs.count
        )
    }

    private static func appendInstances(
        layer: WaveformTilePromotionLayer,
        requestedDescriptor: WaveformTileDescriptor,
        role: WaveformTileDrawLayerRole,
        trackID: UUID,
        trackIndex: Int,
        laneFrame: TimelineTrackLaneFrame,
        source: WaveformTileSourceMetadata,
        segments: [WaveformTileSchedulerSegment],
        instancesByKey: inout [WaveformTileDrawBatchKey: [WaveformTileDrawInstance]],
        resourceIDs: inout Set<WaveformTileGPUResourceID>
    ) {
        guard layer.alpha > 0.001 else {
            return
        }

        let tileSourceStartTime = TimeInterval(layer.descriptor.frameRange.startFrame) / source.sampleRate
        let tileSourceEndTime = TimeInterval(layer.descriptor.frameRange.endFrame) / source.sampleRate
        guard tileSourceEndTime > tileSourceStartTime else {
            return
        }

        for segment in segments {
            guard
                segment.outputEndTime > segment.outputStartTime,
                segment.sourceEndTime > segment.sourceStartTime
            else {
                continue
            }

            let sourceOverlapStart = max(tileSourceStartTime, segment.sourceStartTime)
            let sourceOverlapEnd = min(tileSourceEndTime, segment.sourceEndTime)
            guard sourceOverlapEnd > sourceOverlapStart else {
                continue
            }

            let sourceDuration = segment.sourceEndTime - segment.sourceStartTime
            let outputDuration = segment.outputEndTime - segment.outputStartTime
            let outputStartRatio = (sourceOverlapStart - segment.sourceStartTime) / sourceDuration
            let outputEndRatio = (sourceOverlapEnd - segment.sourceStartTime) / sourceDuration
            let outputStartTime = segment.outputStartTime + outputStartRatio * outputDuration
            let outputEndTime = segment.outputStartTime + outputEndRatio * outputDuration
            guard outputEndTime > outputStartTime else {
                continue
            }

            let key = WaveformTileDrawBatchKey(
                kind: layer.descriptor.address.kind,
                channelMode: layer.descriptor.address.channelMode
            )
            let instance = WaveformTileDrawInstance(
                trackID: trackID,
                trackIndex: trackIndex,
                laneTop: laneFrame.top,
                laneBottom: laneFrame.bottom,
                outputStartTime: outputStartTime,
                outputEndTime: outputEndTime,
                sourceStartTime: sourceOverlapStart,
                sourceEndTime: sourceOverlapEnd,
                sourceDuration: source.duration,
                sourceSampleRate: source.sampleRate,
                requestedDescriptor: requestedDescriptor,
                tileDescriptor: layer.descriptor,
                resource: layer.resource,
                alpha: min(max(layer.alpha, 0), 1),
                role: role
            )
            instancesByKey[key, default: []].append(instance)
            resourceIDs.insert(layer.resource.id)
        }
    }
}
