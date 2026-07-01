import Foundation
import Metal

struct WaveformTileMetalBufferAllocation {
    let address: WaveformTileAddress
    let resourceID: WaveformTileGPUResourceID
    let buffer: MTLBuffer
    let binOffset: Int
    let binCount: Int
    let byteCount: Int
}

final class WaveformTileMetalBufferStore: @unchecked Sendable {
    private struct PackedWaveformBin {
        var minimumSample: Float
        var maximumSample: Float
        var rmsSample: Float
        var lowEnergy: Float
        var midEnergy: Float
        var highEnergy: Float
        var peakMagnitude: Float
        var reserved: Float
    }

    enum UploadError: Error {
        case emptyTile
        case bufferAllocationFailed
    }

    private let lock = NSLock()
    private let device: MTLDevice
    private var uploadSerial: UInt64 = 0
    private var allocationsByAddress: [WaveformTileAddress: WaveformTileMetalBufferAllocation] = [:]
    private var addressesByResourceID: [WaveformTileGPUResourceID: WaveformTileAddress] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func allocation(for address: WaveformTileAddress) -> WaveformTileMetalBufferAllocation? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return allocationsByAddress[address]
    }

    func upload(_ payload: WaveformTilePayload) throws -> WaveformTileGPUResource {
        let bins = try packedBins(for: payload)
        let byteCount = bins.count * MemoryLayout<PackedWaveformBin>.stride
        guard byteCount > 0 else {
            throw UploadError.emptyTile
        }

        guard let buffer = bins.withUnsafeBytes({ bytes -> MTLBuffer? in
            guard let baseAddress = bytes.baseAddress else {
                return nil
            }
            return device.makeBuffer(
                bytes: baseAddress,
                length: byteCount,
                options: [.storageModeShared, .cpuCacheModeWriteCombined]
            )
        }) else {
            throw UploadError.bufferAllocationFailed
        }

        lock.lock()
        uploadSerial &+= 1
        let resourceID = WaveformTileGPUResourceID(
            rawValue: "metal-\(payload.descriptor.address.sourceID.rawValue)-\(payload.descriptor.address.kind.rawValue)-\(payload.descriptor.address.channelMode.rawValue)-\(payload.descriptor.address.level)-\(payload.descriptor.address.tileIndex)-\(uploadSerial)"
        )
        buffer.label = "Soundtime waveform tile \(resourceID.rawValue)"
        if let previous = allocationsByAddress[payload.descriptor.address] {
            addressesByResourceID.removeValue(forKey: previous.resourceID)
        }
        let allocation = WaveformTileMetalBufferAllocation(
            address: payload.descriptor.address,
            resourceID: resourceID,
            buffer: buffer,
            binOffset: 0,
            binCount: bins.count,
            byteCount: byteCount
        )
        allocationsByAddress[payload.descriptor.address] = allocation
        addressesByResourceID[resourceID] = payload.descriptor.address
        lock.unlock()

        return WaveformTileGPUResource(id: resourceID, byteCount: byteCount)
    }

    func remove(_ address: WaveformTileAddress) {
        lock.lock()
        if let allocation = allocationsByAddress.removeValue(forKey: address) {
            addressesByResourceID.removeValue(forKey: allocation.resourceID)
        }
        lock.unlock()
    }

    func remove(addresses: [WaveformTileAddress]) {
        guard !addresses.isEmpty else {
            return
        }

        lock.lock()
        for address in addresses {
            if let allocation = allocationsByAddress.removeValue(forKey: address) {
                addressesByResourceID.removeValue(forKey: allocation.resourceID)
            }
        }
        lock.unlock()
    }

    func remove(resourceID: WaveformTileGPUResourceID) {
        lock.lock()
        if let address = addressesByResourceID.removeValue(forKey: resourceID) {
            allocationsByAddress.removeValue(forKey: address)
        }
        lock.unlock()
    }

    func removeAll(for sourceID: WaveformSourceID) {
        lock.lock()
        let addresses = allocationsByAddress.keys.filter { $0.sourceID == sourceID }
        for address in addresses {
            if let allocation = allocationsByAddress.removeValue(forKey: address) {
                addressesByResourceID.removeValue(forKey: allocation.resourceID)
            }
        }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        allocationsByAddress.removeAll()
        addressesByResourceID.removeAll()
        lock.unlock()
    }

    func diagnostics() -> (allocationCount: Int, byteCount: Int) {
        lock.lock()
        defer {
            lock.unlock()
        }

        let byteCount = allocationsByAddress.values.reduce(0) { total, allocation in
            total + allocation.byteCount
        }
        return (allocationsByAddress.count, byteCount)
    }

    private func packedBins(for payload: WaveformTilePayload) throws -> [PackedWaveformBin] {
        switch payload {
        case let .peak(tile):
            let bins = tile.bins.map(Self.packedPeakBin)
            guard !bins.isEmpty else {
                throw UploadError.emptyTile
            }
            return bins
        case let .rawSamples(tile):
            let frameCount = tile.samplesByChannel.map(\.count).max() ?? 0
            guard frameCount > 0 else {
                throw UploadError.emptyTile
            }
            return (0..<frameCount).map { frameIndex in
                Self.packedRawSampleBin(samplesByChannel: tile.samplesByChannel, frameIndex: frameIndex)
            }
        }
    }

    private static func packedPeakBin(_ bin: WaveformOverview.Bin) -> PackedWaveformBin {
        PackedWaveformBin(
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

    private static func packedRawSampleBin(
        samplesByChannel: [[Float]],
        frameIndex: Int
    ) -> PackedWaveformBin {
        var minimumSample: Float = 0
        var maximumSample: Float = 0
        var squareSum: Float = 0
        var sampleCount: Float = 0

        for channel in samplesByChannel where frameIndex < channel.count {
            let sample = min(max(channel[frameIndex], -1), 1)
            if sampleCount == 0 {
                minimumSample = sample
                maximumSample = sample
            } else {
                minimumSample = min(minimumSample, sample)
                maximumSample = max(maximumSample, sample)
            }
            squareSum += sample * sample
            sampleCount += 1
        }

        guard sampleCount > 0 else {
            return PackedWaveformBin(
                minimumSample: 0,
                maximumSample: 0,
                rmsSample: 0,
                lowEnergy: 0.34,
                midEnergy: 0.33,
                highEnergy: 0.33,
                peakMagnitude: 0,
                reserved: 0
            )
        }

        let rmsSample = min(max(sqrt(squareSum / sampleCount), 0), 1)
        return PackedWaveformBin(
            minimumSample: minimumSample,
            maximumSample: maximumSample,
            rmsSample: rmsSample,
            lowEnergy: 0.34,
            midEnergy: 0.33,
            highEnergy: 0.33,
            peakMagnitude: min(max(max(abs(minimumSample), abs(maximumSample)), 0), 1),
            reserved: 0
        )
    }
}
