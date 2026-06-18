import Foundation

struct WaveformTileWorkItem: Hashable, Sendable {
    let request: WaveformTileRequest
    let sourceGeneration: UInt64
}

struct WaveformTileRequestQueueSnapshot: Equatable, Sendable {
    let pendingCount: Int
    let inFlightCount: Int
    let failedCount: Int

    var isEmpty: Bool {
        pendingCount == 0 && inFlightCount == 0
    }
}

final class WaveformTileRequestQueue: @unchecked Sendable {
    private struct PendingRecord {
        var request: WaveformTileRequest
        var sourceGeneration: UInt64
    }

    private let lock = NSLock()
    private var pendingByAddress: [WaveformTileAddress: PendingRecord] = [:]
    private var inFlightGenerationsByAddress: [WaveformTileAddress: UInt64] = [:]
    private var failedMessagesByAddress: [WaveformTileAddress: String] = [:]
    private var sourceGenerations: [WaveformSourceID: UInt64] = [:]

    func enqueue(_ request: WaveformTileRequest) {
        enqueue([request])
    }

    func enqueue(_ requests: [WaveformTileRequest]) {
        lock.lock()
        defer {
            lock.unlock()
        }

        for request in requests {
            let address = request.descriptor.address
            if inFlightGenerationsByAddress[address] != nil {
                continue
            }

            let generation = sourceGeneration(for: address.sourceID)
            if let existing = pendingByAddress[address] {
                if request < existing.request {
                    pendingByAddress[address] = PendingRecord(
                        request: request,
                        sourceGeneration: generation
                    )
                }
            } else {
                pendingByAddress[address] = PendingRecord(
                    request: request,
                    sourceGeneration: generation
                )
            }
            failedMessagesByAddress.removeValue(forKey: address)
        }
    }

    func dequeue(maxCount: Int) -> [WaveformTileWorkItem] {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard maxCount > 0, !pendingByAddress.isEmpty else {
            return []
        }

        let records = pendingByAddress.values
            .sorted { lhs, rhs in
                lhs.request < rhs.request
            }
            .prefix(maxCount)

        var workItems: [WaveformTileWorkItem] = []
        workItems.reserveCapacity(records.count)
        for record in records {
            let address = record.request.descriptor.address
            pendingByAddress.removeValue(forKey: address)
            inFlightGenerationsByAddress[address] = record.sourceGeneration
            workItems.append(WaveformTileWorkItem(
                request: record.request,
                sourceGeneration: record.sourceGeneration
            ))
        }
        return workItems
    }

    @discardableResult
    func complete(_ workItem: WaveformTileWorkItem) -> Bool {
        finish(workItem, failureMessage: nil)
    }

    @discardableResult
    func fail(_ workItem: WaveformTileWorkItem, message: String) -> Bool {
        finish(workItem, failureMessage: message)
    }

    func requeue(_ workItem: WaveformTileWorkItem) {
        lock.lock()
        defer {
            lock.unlock()
        }

        let address = workItem.request.descriptor.address
        guard currentGeneration(for: address.sourceID) == workItem.sourceGeneration else {
            inFlightGenerationsByAddress.removeValue(forKey: address)
            return
        }

        inFlightGenerationsByAddress.removeValue(forKey: address)
        pendingByAddress[address] = PendingRecord(
            request: workItem.request,
            sourceGeneration: workItem.sourceGeneration
        )
    }

    func removeAll(for sourceID: WaveformSourceID) {
        lock.lock()
        defer {
            lock.unlock()
        }

        sourceGenerations[sourceID] = sourceGeneration(for: sourceID) &+ 1
        pendingByAddress = pendingByAddress.filter { address, _ in
            address.sourceID != sourceID
        }
        inFlightGenerationsByAddress = inFlightGenerationsByAddress.filter { address, _ in
            address.sourceID != sourceID
        }
        failedMessagesByAddress = failedMessagesByAddress.filter { address, _ in
            address.sourceID != sourceID
        }
    }

    func removeAll() {
        lock.lock()
        pendingByAddress.removeAll()
        inFlightGenerationsByAddress.removeAll()
        failedMessagesByAddress.removeAll()
        for sourceID in sourceGenerations.keys {
            sourceGenerations[sourceID] = sourceGeneration(for: sourceID) &+ 1
        }
        lock.unlock()
    }

    func isCurrent(_ workItem: WaveformTileWorkItem) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        return currentGeneration(for: workItem.request.descriptor.address.sourceID) == workItem.sourceGeneration
    }

    func isPending(_ address: WaveformTileAddress) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return pendingByAddress[address] != nil
    }

    func isInFlight(_ address: WaveformTileAddress) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return inFlightGenerationsByAddress[address] != nil
    }

    func failureMessage(for address: WaveformTileAddress) -> String? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return failedMessagesByAddress[address]
    }

    func snapshot() -> WaveformTileRequestQueueSnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }
        return WaveformTileRequestQueueSnapshot(
            pendingCount: pendingByAddress.count,
            inFlightCount: inFlightGenerationsByAddress.count,
            failedCount: failedMessagesByAddress.count
        )
    }

    private func finish(_ workItem: WaveformTileWorkItem, failureMessage: String?) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        let address = workItem.request.descriptor.address
        let isCurrentGeneration = currentGeneration(for: address.sourceID) == workItem.sourceGeneration
        let wasInFlight = inFlightGenerationsByAddress[address] == workItem.sourceGeneration
        inFlightGenerationsByAddress.removeValue(forKey: address)

        guard isCurrentGeneration, wasInFlight else {
            return false
        }

        if let failureMessage {
            failedMessagesByAddress[address] = failureMessage
        } else {
            failedMessagesByAddress.removeValue(forKey: address)
        }
        return true
    }

    private func sourceGeneration(for sourceID: WaveformSourceID) -> UInt64 {
        if let generation = sourceGenerations[sourceID] {
            return generation
        }
        sourceGenerations[sourceID] = 0
        return 0
    }

    private func currentGeneration(for sourceID: WaveformSourceID) -> UInt64 {
        sourceGenerations[sourceID] ?? 0
    }
}
