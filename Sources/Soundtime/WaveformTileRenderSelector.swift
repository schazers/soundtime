import Foundation

enum WaveformTileRenderSelectionSource: String, Sendable {
    case exactResident
    case coarserResident
    case lastGoodResident
}

struct WaveformRenderableTile: Hashable, Sendable {
    let requestedDescriptor: WaveformTileDescriptor
    let selectedDescriptor: WaveformTileDescriptor
    let resource: WaveformTileGPUResource
    let source: WaveformTileRenderSelectionSource
}

struct WaveformTileRenderSelection: Equatable, Sendable {
    let tiles: [WaveformRenderableTile]
    let requestedCount: Int
    let exactResidentCount: Int
    let coarserResidentCount: Int
    let lastGoodResidentCount: Int
    let skippedCount: Int

    var selectedCount: Int {
        tiles.count
    }

    var hasCompleteVisibleCoverage: Bool {
        requestedCount > 0 && skippedCount == 0 && selectedCount == requestedCount
    }
}

private struct WaveformTileRenderFallbackKey: Hashable {
    let sourceID: WaveformSourceID
    let editGraphID: String?
    let kind: WaveformTileKind
    let channelMode: WaveformChannelMode

    init(address: WaveformTileAddress) {
        self.sourceID = address.sourceID
        self.editGraphID = address.editGraphID
        self.kind = address.kind
        self.channelMode = address.channelMode
    }
}

private struct WaveformTileRenderHoldKey: Hashable {
    let sourceID: WaveformSourceID
    let editGraphID: String?
    let channelMode: WaveformChannelMode

    init(address: WaveformTileAddress) {
        self.sourceID = address.sourceID
        self.editGraphID = address.editGraphID
        self.channelMode = address.channelMode
    }
}

final class WaveformTileRenderSelector: @unchecked Sendable {
    private static let maximumLastGoodRecordsPerKey = 512

    private struct LastGoodRecord {
        let descriptor: WaveformTileDescriptor
        let resource: WaveformTileGPUResource
        let rememberedSerial: UInt64
    }

    private let tileStore: WaveformTileStore
    private let residencyStore: WaveformTileGPUResidencyStore
    private let lock = NSLock()
    private var lastGoodByKey: [WaveformTileRenderHoldKey: [WaveformTileAddress: LastGoodRecord]] = [:]
    private var lastGoodSerial: UInt64 = 0

    init(
        tileStore: WaveformTileStore,
        residencyStore: WaveformTileGPUResidencyStore
    ) {
        self.tileStore = tileStore
        self.residencyStore = residencyStore
    }

    func selectRenderableTiles(
        for requests: [WaveformTileRequest],
        allowedPurposes: Set<WaveformTileRequestPurpose> = [.visible]
    ) -> WaveformTileRenderSelection {
        let renderRequests = requests
            .filter { allowedPurposes.contains($0.purpose) }
            .sorted()

        var tiles: [WaveformRenderableTile] = []
        tiles.reserveCapacity(renderRequests.count)
        var exactResidentCount = 0
        var coarserResidentCount = 0
        var lastGoodResidentCount = 0
        var skippedCount = 0
        var residentAddressesByFallbackKey: [WaveformTileRenderFallbackKey: [WaveformTileAddress]]?

        for request in renderRequests {
            if let exact = exactResidentTile(for: request.descriptor) {
                rememberLastGood(exact)
                tiles.append(exact)
                exactResidentCount += 1
                continue
            }

            if residentAddressesByFallbackKey == nil {
                residentAddressesByFallbackKey = Dictionary(
                    grouping: residencyStore.unsortedAddressSnapshot(),
                    by: WaveformTileRenderFallbackKey.init(address:)
                )
            }
            if let coarser = coarserResidentTile(
                for: request.descriptor,
                residentAddressesByFallbackKey: residentAddressesByFallbackKey ?? [:]
            ) {
                rememberLastGood(coarser)
                tiles.append(coarser)
                coarserResidentCount += 1
                continue
            }

            if let lastGood = lastGoodTile(for: request.descriptor) {
                tiles.append(lastGood)
                lastGoodResidentCount += 1
                continue
            }

            skippedCount += 1
        }

        return WaveformTileRenderSelection(
            tiles: tiles,
            requestedCount: renderRequests.count,
            exactResidentCount: exactResidentCount,
            coarserResidentCount: coarserResidentCount,
            lastGoodResidentCount: lastGoodResidentCount,
            skippedCount: skippedCount
        )
    }

    func removeAll(for sourceID: WaveformSourceID) {
        lock.lock()
        lastGoodByKey = lastGoodByKey.filter { key, _ in
            key.sourceID != sourceID
        }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        lastGoodByKey.removeAll()
        lock.unlock()
    }

    private func exactResidentTile(for descriptor: WaveformTileDescriptor) -> WaveformRenderableTile? {
        guard let resource = residencyStore.resource(for: descriptor.address),
              tileStore.payload(for: descriptor.address) != nil
        else {
            return nil
        }

        return WaveformRenderableTile(
            requestedDescriptor: descriptor,
            selectedDescriptor: descriptor,
            resource: resource,
            source: .exactResident
        )
    }

    private func coarserResidentTile(
        for descriptor: WaveformTileDescriptor,
        residentAddressesByFallbackKey: [WaveformTileRenderFallbackKey: [WaveformTileAddress]]
    ) -> WaveformRenderableTile? {
        let key = WaveformTileRenderFallbackKey(address: descriptor.address)
        let candidates = (residentAddressesByFallbackKey[key] ?? []).compactMap { address -> (descriptor: WaveformTileDescriptor, resource: WaveformTileGPUResource)? in
            guard address != descriptor.address,
                  address.level > descriptor.address.level,
                  let payload = tileStore.payload(for: address),
                  payload.descriptor.frameRange.intersects(descriptor.frameRange),
                  let resource = residencyStore.resource(for: address)
            else {
                return nil
            }
            return (payload.descriptor, resource)
        }

        guard let best = candidates.min(by: { lhs, rhs in
            let lhsLevelDelta = lhs.descriptor.address.level - descriptor.address.level
            let rhsLevelDelta = rhs.descriptor.address.level - descriptor.address.level
            if lhsLevelDelta != rhsLevelDelta {
                return lhsLevelDelta < rhsLevelDelta
            }
            return lhs.descriptor.address < rhs.descriptor.address
        }) else {
            return nil
        }

        return WaveformRenderableTile(
            requestedDescriptor: descriptor,
            selectedDescriptor: best.descriptor,
            resource: best.resource,
            source: .coarserResident
        )
    }

    private func lastGoodTile(for descriptor: WaveformTileDescriptor) -> WaveformRenderableTile? {
        let key = WaveformTileRenderHoldKey(address: descriptor.address)
        lock.lock()
        let records = lastGoodByKey[key].map { Array($0.values) } ?? []
        lock.unlock()

        let candidates = records.compactMap { record -> (record: LastGoodRecord, resource: WaveformTileGPUResource, overlap: Int64)? in
            guard record.descriptor.frameRange.intersects(descriptor.frameRange),
                  tileStore.payload(for: record.descriptor.address) != nil,
                  let resource = residencyStore.resource(for: record.descriptor.address)
            else {
                return nil
            }

            let overlap = min(record.descriptor.frameRange.endFrame, descriptor.frameRange.endFrame) -
                max(record.descriptor.frameRange.startFrame, descriptor.frameRange.startFrame)
            return (record, resource, max(0, overlap))
        }

        guard let best = candidates.max(by: { lhs, rhs in
            let lhsSameKind = lhs.record.descriptor.address.kind == descriptor.address.kind
            let rhsSameKind = rhs.record.descriptor.address.kind == descriptor.address.kind
            if lhsSameKind != rhsSameKind {
                return !lhsSameKind && rhsSameKind
            }

            let lhsLevelDistance = abs(lhs.record.descriptor.address.level - descriptor.address.level)
            let rhsLevelDistance = abs(rhs.record.descriptor.address.level - descriptor.address.level)
            if lhsLevelDistance != rhsLevelDistance {
                return lhsLevelDistance > rhsLevelDistance
            }

            if lhs.overlap != rhs.overlap {
                return lhs.overlap < rhs.overlap
            }

            if lhs.record.rememberedSerial != rhs.record.rememberedSerial {
                return lhs.record.rememberedSerial < rhs.record.rememberedSerial
            }

            return lhs.record.descriptor.address > rhs.record.descriptor.address
        }) else {
            return nil
        }

        return WaveformRenderableTile(
            requestedDescriptor: descriptor,
            selectedDescriptor: best.record.descriptor,
            resource: best.resource,
            source: .lastGoodResident
        )
    }

    private func rememberLastGood(_ tile: WaveformRenderableTile) {
        let key = WaveformTileRenderHoldKey(address: tile.selectedDescriptor.address)
        lock.lock()
        lastGoodSerial &+= 1
        var records = lastGoodByKey[key] ?? [:]
        records[tile.selectedDescriptor.address] = LastGoodRecord(
            descriptor: tile.selectedDescriptor,
            resource: tile.resource,
            rememberedSerial: lastGoodSerial
        )
        if records.count > Self.maximumLastGoodRecordsPerKey {
            let sortedRecords = records.sorted { lhs, rhs in
                if lhs.value.rememberedSerial != rhs.value.rememberedSerial {
                    return lhs.value.rememberedSerial > rhs.value.rememberedSerial
                }
                return lhs.key < rhs.key
            }
            records = Dictionary(uniqueKeysWithValues: sortedRecords.prefix(Self.maximumLastGoodRecordsPerKey).map { entry in
                (entry.key, entry.value)
            })
        }
        lastGoodByKey[key] = records
        lock.unlock()
    }
}
