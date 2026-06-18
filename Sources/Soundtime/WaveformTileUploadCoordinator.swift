import Foundation

struct WaveformTileGPUResourceID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String {
        rawValue
    }
}

struct WaveformTileGPUResource: Hashable, Sendable {
    let id: WaveformTileGPUResourceID
    let byteCount: Int

    init(id: WaveformTileGPUResourceID, byteCount: Int) {
        self.id = id
        self.byteCount = max(0, byteCount)
    }
}

struct WaveformTileUploadBudget: Hashable, Sendable {
    let maximumBytesPerBatch: Int
    let maximumTilesPerBatch: Int

    init(maximumBytesPerBatch: Int, maximumTilesPerBatch: Int) {
        self.maximumBytesPerBatch = max(0, maximumBytesPerBatch)
        self.maximumTilesPerBatch = max(0, maximumTilesPerBatch)
    }
}

struct WaveformTileUploadBatchSummary: Equatable, Sendable {
    var consideredCount = 0
    var uploadedCount = 0
    var uploadedBytes = 0
    var skippedResidentCount = 0
    var skippedMissingPayloadCount = 0
    var skippedBudgetCount = 0
    var staleUploadCount = 0
    var evictedCount = 0
}

struct WaveformTileGPUResidencySnapshot: Equatable, Sendable {
    let residentCount: Int
    let residentBytes: Int
    let maximumResidentBytes: Int
}

final class WaveformTileGPUResidencyStore: @unchecked Sendable {
    private struct Record {
        let resource: WaveformTileGPUResource
        var lastAccessSerial: UInt64
    }

    private let lock = NSLock()
    private let maximumResidentBytes: Int
    private var recordsByAddress: [WaveformTileAddress: Record] = [:]
    private var accessSerial: UInt64 = 0
    private var residentBytes = 0

    init(maximumResidentBytes: Int) {
        self.maximumResidentBytes = max(0, maximumResidentBytes)
    }

    func resource(for address: WaveformTileAddress) -> WaveformTileGPUResource? {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard var record = recordsByAddress[address] else {
            return nil
        }
        accessSerial &+= 1
        record.lastAccessSerial = accessSerial
        recordsByAddress[address] = record
        return record.resource
    }

    @discardableResult
    func insert(
        _ resource: WaveformTileGPUResource,
        for address: WaveformTileAddress
    ) -> [WaveformTileAddress] {
        lock.lock()
        defer {
            lock.unlock()
        }

        accessSerial &+= 1
        if let existing = recordsByAddress[address] {
            residentBytes -= existing.resource.byteCount
        }
        recordsByAddress[address] = Record(resource: resource, lastAccessSerial: accessSerial)
        residentBytes += resource.byteCount
        return evictIfNeededLocked(protectedAddress: address)
    }

    @discardableResult
    func remove(_ address: WaveformTileAddress) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard let record = recordsByAddress.removeValue(forKey: address) else {
            return false
        }
        residentBytes -= record.resource.byteCount
        return true
    }

    @discardableResult
    func removeAll(for sourceID: WaveformSourceID) -> [WaveformTileAddress] {
        lock.lock()
        defer {
            lock.unlock()
        }

        var removed: [WaveformTileAddress] = []
        for address in recordsByAddress.keys where address.sourceID == sourceID {
            removed.append(address)
        }
        for address in removed {
            if let record = recordsByAddress.removeValue(forKey: address) {
                residentBytes -= record.resource.byteCount
            }
        }
        return removed.sorted()
    }

    func addresses() -> [WaveformTileAddress] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recordsByAddress.keys.sorted()
    }

    func snapshot() -> WaveformTileGPUResidencySnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }
        return WaveformTileGPUResidencySnapshot(
            residentCount: recordsByAddress.count,
            residentBytes: residentBytes,
            maximumResidentBytes: maximumResidentBytes
        )
    }

    private func evictIfNeededLocked(protectedAddress: WaveformTileAddress) -> [WaveformTileAddress] {
        guard maximumResidentBytes > 0 else {
            let evicted = recordsByAddress.keys.filter { $0 != protectedAddress }.sorted()
            for address in evicted {
                if let record = recordsByAddress.removeValue(forKey: address) {
                    residentBytes -= record.resource.byteCount
                }
            }
            return evicted
        }

        var evicted: [WaveformTileAddress] = []
        while residentBytes > maximumResidentBytes, recordsByAddress.count > 1 {
            guard let evictionAddress = recordsByAddress
                .filter({ address, _ in address != protectedAddress })
                .min(by: { lhs, rhs in
                    if lhs.value.lastAccessSerial != rhs.value.lastAccessSerial {
                        return lhs.value.lastAccessSerial < rhs.value.lastAccessSerial
                    }
                    return lhs.key < rhs.key
                })?
                .key
            else {
                break
            }

            if let record = recordsByAddress.removeValue(forKey: evictionAddress) {
                residentBytes -= record.resource.byteCount
                evicted.append(evictionAddress)
            }
        }
        return evicted.sorted()
    }
}

final class WaveformTileUploadCoordinator: @unchecked Sendable {
    typealias UploadHandler = (WaveformTilePayload) throws -> WaveformTileGPUResource

    private let tileStore: WaveformTileStore
    private let residencyStore: WaveformTileGPUResidencyStore
    private let lock = NSLock()
    private var sourceGenerations: [WaveformSourceID: UInt64] = [:]

    init(
        tileStore: WaveformTileStore,
        residencyStore: WaveformTileGPUResidencyStore
    ) {
        self.tileStore = tileStore
        self.residencyStore = residencyStore
    }

    func uploadNextBatch(
        prioritizedAddresses: [WaveformTileAddress],
        budget: WaveformTileUploadBudget,
        beforeUpload: ((WaveformTileAddress) -> Void)? = nil,
        upload: UploadHandler
    ) -> WaveformTileUploadBatchSummary {
        var summary = WaveformTileUploadBatchSummary()
        guard budget.maximumBytesPerBatch > 0, budget.maximumTilesPerBatch > 0 else {
            return summary
        }

        var seenAddresses = Set<WaveformTileAddress>()
        var uploadedTiles = 0
        var uploadedBytes = 0

        for address in prioritizedAddresses where seenAddresses.insert(address).inserted {
            summary.consideredCount += 1

            if residencyStore.resource(for: address) != nil {
                summary.skippedResidentCount += 1
                continue
            }

            guard let payload = tileStore.payload(for: address) else {
                summary.skippedMissingPayloadCount += 1
                continue
            }

            let estimatedBytes = Self.estimatedUploadBytes(for: payload)
            guard uploadedTiles < budget.maximumTilesPerBatch,
                  estimatedBytes <= budget.maximumBytesPerBatch - uploadedBytes
            else {
                summary.skippedBudgetCount += 1
                continue
            }

            let generation = sourceGeneration(for: address.sourceID)
            beforeUpload?(address)
            guard currentGeneration(for: address.sourceID) == generation,
                  tileStore.payload(for: address) != nil
            else {
                summary.staleUploadCount += 1
                continue
            }

            do {
                let resource = try upload(payload)
                guard currentGeneration(for: address.sourceID) == generation,
                      tileStore.payload(for: address) != nil
                else {
                    summary.staleUploadCount += 1
                    continue
                }

                let evicted = residencyStore.insert(resource, for: address)
                for evictedAddress in evicted {
                    tileStore.markGPUEvicted(evictedAddress)
                }
                tileStore.markGPUResident(address)
                summary.uploadedCount += 1
                summary.uploadedBytes += resource.byteCount
                summary.evictedCount += evicted.count
                uploadedTiles += 1
                uploadedBytes += estimatedBytes
            } catch {
                tileStore.markFailed(address, message: String(describing: error))
            }
        }

        return summary
    }

    func removeAll(for sourceID: WaveformSourceID) {
        bumpGeneration(for: sourceID)
        let evicted = residencyStore.removeAll(for: sourceID)
        for address in evicted {
            tileStore.markGPUEvicted(address)
        }
    }

    static func estimatedUploadBytes(for payload: WaveformTilePayload) -> Int {
        switch payload {
        case let .peak(tile):
            return tile.bins.count * WaveformPeakTileBinaryCodec.floatsPerBin * MemoryLayout<Float>.size
        case let .rawSamples(tile):
            return tile.samplesByChannel.reduce(0) { total, samples in
                total + samples.count * MemoryLayout<Float>.size
            }
        }
    }

    private func sourceGeneration(for sourceID: WaveformSourceID) -> UInt64 {
        lock.lock()
        defer {
            lock.unlock()
        }
        if let generation = sourceGenerations[sourceID] {
            return generation
        }
        sourceGenerations[sourceID] = 0
        return 0
    }

    private func currentGeneration(for sourceID: WaveformSourceID) -> UInt64 {
        lock.lock()
        defer {
            lock.unlock()
        }
        return sourceGenerations[sourceID] ?? 0
    }

    private func bumpGeneration(for sourceID: WaveformSourceID) {
        lock.lock()
        sourceGenerations[sourceID] = (sourceGenerations[sourceID] ?? 0) &+ 1
        lock.unlock()
    }
}
