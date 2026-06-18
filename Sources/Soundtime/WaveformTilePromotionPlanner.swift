import Foundation

struct WaveformTilePromotionConfig: Hashable, Sendable {
    let crossfadeDuration: TimeInterval

    init(crossfadeDuration: TimeInterval = 0.12) {
        self.crossfadeDuration = max(0.001, crossfadeDuration)
    }
}

struct WaveformTilePromotionLayer: Hashable, Sendable {
    let descriptor: WaveformTileDescriptor
    let resource: WaveformTileGPUResource
    let alpha: Float
}

struct WaveformPromotedTile: Hashable, Sendable {
    let requestedDescriptor: WaveformTileDescriptor
    let current: WaveformTilePromotionLayer
    let previous: WaveformTilePromotionLayer?
    let progress: Float
    let isTransitioning: Bool
}

struct WaveformTilePromotionPlan: Equatable, Sendable {
    let tiles: [WaveformPromotedTile]
    let promotedCount: Int
    let transitioningCount: Int

    var drawLayerCount: Int {
        tiles.reduce(0) { count, tile in
            count + 1 + (tile.previous == nil ? 0 : 1)
        }
    }
}

private struct WaveformTilePromotionKey: Hashable {
    let sourceID: WaveformSourceID
    let editGraphID: String?
    let kind: WaveformTileKind
    let channelMode: WaveformChannelMode
    let requestedLevel: Int
    let requestedTileIndex: Int

    init(descriptor: WaveformTileDescriptor) {
        let address = descriptor.address
        self.sourceID = address.sourceID
        self.editGraphID = address.editGraphID
        self.kind = address.kind
        self.channelMode = address.channelMode
        self.requestedLevel = address.level
        self.requestedTileIndex = address.tileIndex
    }
}

final class WaveformTilePromotionPlanner: @unchecked Sendable {
    private struct Record {
        var current: WaveformRenderableTile
        var previous: WaveformRenderableTile?
        var startedAt: TimeInterval
    }

    private let config: WaveformTilePromotionConfig
    private let lock = NSLock()
    private var recordsByKey: [WaveformTilePromotionKey: Record] = [:]

    init(config: WaveformTilePromotionConfig = WaveformTilePromotionConfig()) {
        self.config = config
    }

    func plan(
        selection: WaveformTileRenderSelection,
        timestamp: TimeInterval
    ) -> WaveformTilePromotionPlan {
        lock.lock()
        defer {
            lock.unlock()
        }

        let selectedKeys = Set(selection.tiles.map { WaveformTilePromotionKey(descriptor: $0.requestedDescriptor) })
        recordsByKey = recordsByKey.filter { key, _ in
            selectedKeys.contains(key)
        }

        var promotedTiles: [WaveformPromotedTile] = []
        promotedTiles.reserveCapacity(selection.tiles.count)
        var promotedCount = 0
        var transitioningCount = 0

        for tile in selection.tiles {
            let key = WaveformTilePromotionKey(descriptor: tile.requestedDescriptor)
            let record = updatedRecord(for: key, tile: tile, timestamp: timestamp)
            recordsByKey[key] = record

            let progress = transitionProgress(record: record, timestamp: timestamp)
            let easedProgress = smoothStep(progress)
            let isTransitioning = record.previous != nil && easedProgress < 0.999

            if isTransitioning {
                transitioningCount += 1
            }
            if record.previous != nil {
                promotedCount += 1
            }

            let previousLayer: WaveformTilePromotionLayer?
            if let previous = record.previous, easedProgress < 0.999 {
                previousLayer = WaveformTilePromotionLayer(
                    descriptor: previous.selectedDescriptor,
                    resource: previous.resource,
                    alpha: 1 - easedProgress
                )
            } else {
                previousLayer = nil
            }

            promotedTiles.append(WaveformPromotedTile(
                requestedDescriptor: tile.requestedDescriptor,
                current: WaveformTilePromotionLayer(
                    descriptor: record.current.selectedDescriptor,
                    resource: record.current.resource,
                    alpha: previousLayer == nil ? 1 : easedProgress
                ),
                previous: previousLayer,
                progress: previousLayer == nil ? 1 : easedProgress,
                isTransitioning: isTransitioning
            ))
        }

        return WaveformTilePromotionPlan(
            tiles: promotedTiles,
            promotedCount: promotedCount,
            transitioningCount: transitioningCount
        )
    }

    func removeAll(for sourceID: WaveformSourceID) {
        lock.lock()
        recordsByKey = recordsByKey.filter { key, _ in
            key.sourceID != sourceID
        }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        recordsByKey.removeAll()
        lock.unlock()
    }

    private func updatedRecord(
        for key: WaveformTilePromotionKey,
        tile: WaveformRenderableTile,
        timestamp: TimeInterval
    ) -> Record {
        guard var existing = recordsByKey[key] else {
            return Record(current: tile, previous: nil, startedAt: timestamp)
        }

        guard existing.current.selectedDescriptor.address != tile.selectedDescriptor.address ||
            existing.current.resource != tile.resource
        else {
            return existing
        }

        let activePrevious: WaveformRenderableTile
        if let previous = existing.previous,
           transitionProgress(record: existing, timestamp: timestamp) < 1 {
            activePrevious = blendedCarryForward(current: existing.current, previous: previous)
        } else {
            activePrevious = existing.current
        }

        existing.previous = activePrevious
        existing.current = tile
        existing.startedAt = timestamp
        return existing
    }

    private func blendedCarryForward(
        current: WaveformRenderableTile,
        previous: WaveformRenderableTile
    ) -> WaveformRenderableTile {
        // The renderer can draw only one previous resource per request today. Carrying the
        // current tile preserves continuity if a second promotion arrives mid-crossfade.
        current.resource.byteCount >= previous.resource.byteCount ? current : previous
    }

    private func transitionProgress(record: Record, timestamp: TimeInterval) -> Float {
        guard record.previous != nil else {
            return 1
        }
        let rawProgress = (timestamp - record.startedAt) / config.crossfadeDuration
        return min(max(Float(rawProgress), 0), 1)
    }

    private func smoothStep(_ progress: Float) -> Float {
        let clamped = min(max(progress, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}
