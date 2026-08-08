import Foundation
import Metal

enum WaveformTileUploadCoordinatorSmokeHarness {
    private enum SmokeError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(message):
                return message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds

        try verifyUploadBudgetLimitsBatch()
        try verifyResidentTilesAreSkipped()
        try verifyLRUEvictionReturnsTilesToCPUCommitted()
        try verifySustainedResidencyPressureStaysBounded()
        try verifyStaleUploadDoesNotBecomeResident()
        try verifyRawSampleByteEstimate()
        try verifyMetalBufferStoreUploadIfAvailable()

        let checks = [
            "upload budget limits batch",
            "resident tiles are skipped",
            "LRU eviction returns tiles to CPU committed",
            "sustained residency pressure stays byte-bounded",
            "stale upload does not become resident",
            "raw sample byte estimate",
            "metal buffer store upload if available",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "waveform-tile-upload-coordinator-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: ["rendererIntegration": "disabled"],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }
        print("Soundtime waveform tile upload coordinator smoke passed")
    }

    private static func verifyUploadBudgetLimitsBatch() throws {
        let fixture = makeFixture(maximumResidentBytes: 1_000_000)
        let addresses = (0..<4).map { tileIndex -> WaveformTileAddress in
            let tile = peakTile(tileIndex: tileIndex, binCount: 4)
            fixture.tileStore.commit(.peak(tile))
            return tile.descriptor.address
        }

        let summary = fixture.coordinator.uploadNextBatch(
            prioritizedAddresses: addresses,
            budget: WaveformTileUploadBudget(maximumBytesPerBatch: 192, maximumTilesPerBatch: 10),
            upload: fakeUpload
        )

        try require(summary.consideredCount == 4, "upload coordinator did not consider all addresses")
        try require(summary.uploadedCount == 2, "byte budget should allow exactly two 96-byte peak tiles")
        try require(summary.uploadedBytes == 192, "uploaded byte count was not tracked")
        try require(summary.uploadedAddresses == Array(addresses.prefix(2)), "uploaded addresses were not tracked per tile")
        try require(summary.skippedBudgetCount == 2, "budget skips were not counted")
        try require(fixture.tileStore.state(for: addresses[0]) == .residentGPU, "first tile did not become GPU resident")
        try require(fixture.tileStore.state(for: addresses[2]) == .committedCPU, "budget-skipped tile should remain CPU committed")
        let snapshot = fixture.residencyStore.snapshot()
        try require(snapshot.residentCount == 2, "residency snapshot did not count resident tiles")
        try require(snapshot.residentTiles.map(\.address) == Array(addresses.prefix(2)), "residency snapshot did not list resident tile addresses")
    }

    private static func verifyResidentTilesAreSkipped() throws {
        let fixture = makeFixture(maximumResidentBytes: 1_000_000)
        let tile = peakTile(tileIndex: 0, binCount: 4)
        fixture.tileStore.commit(.peak(tile))

        let firstSummary = fixture.coordinator.uploadNextBatch(
            prioritizedAddresses: [tile.descriptor.address],
            budget: WaveformTileUploadBudget(maximumBytesPerBatch: 512, maximumTilesPerBatch: 4),
            upload: fakeUpload
        )
        let secondSummary = fixture.coordinator.uploadNextBatch(
            prioritizedAddresses: [tile.descriptor.address],
            budget: WaveformTileUploadBudget(maximumBytesPerBatch: 512, maximumTilesPerBatch: 4),
            upload: fakeUpload
        )

        try require(firstSummary.uploadedCount == 1, "first upload did not upload tile")
        try require(secondSummary.uploadedCount == 0, "resident tile should not upload twice")
        try require(secondSummary.skippedResidentCount == 1, "resident skip was not counted")
    }

    private static func verifyLRUEvictionReturnsTilesToCPUCommitted() throws {
        let fixture = makeFixture(maximumResidentBytes: 192)
        let first = peakTile(tileIndex: 0, binCount: 4)
        let second = peakTile(tileIndex: 1, binCount: 4)
        let third = peakTile(tileIndex: 2, binCount: 4)
        for tile in [first, second, third] {
            fixture.tileStore.commit(.peak(tile))
        }

        _ = fixture.coordinator.uploadNextBatch(
            prioritizedAddresses: [first.descriptor.address, second.descriptor.address],
            budget: WaveformTileUploadBudget(maximumBytesPerBatch: 192, maximumTilesPerBatch: 2),
            upload: fakeUpload
        )
        _ = fixture.residencyStore.resource(for: first.descriptor.address)
        let summary = fixture.coordinator.uploadNextBatch(
            prioritizedAddresses: [third.descriptor.address],
            budget: WaveformTileUploadBudget(maximumBytesPerBatch: 128, maximumTilesPerBatch: 1),
            upload: fakeUpload
        )

        try require(summary.uploadedCount == 1, "third tile did not upload")
        try require(summary.evictedCount == 1, "LRU eviction did not evict exactly one tile")
        try require(summary.uploadedAddresses == [third.descriptor.address], "uploaded tile address was not reported")
        try require(summary.evictedAddresses == [second.descriptor.address], "evicted tile address was not reported")
        try require(fixture.tileStore.state(for: first.descriptor.address) == .residentGPU, "recently touched tile should remain resident")
        try require(fixture.tileStore.state(for: second.descriptor.address) == .committedCPU, "least recently used tile should return to CPU committed")
        try require(fixture.tileStore.state(for: third.descriptor.address) == .residentGPU, "new tile should become resident")
    }

    private static func verifySustainedResidencyPressureStaysBounded() throws {
        let bytesPerTile = 96
        let residentTileCapacity = 32
        let fixture = makeFixture(maximumResidentBytes: bytesPerTile * residentTileCapacity)
        let tiles = (0..<2_048).map { peakTile(tileIndex: $0, binCount: 4) }
        for tile in tiles {
            fixture.tileStore.commit(.peak(tile))
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        var totalEvictions = 0
        for chunkStart in stride(from: 0, to: tiles.count, by: 8) {
            let chunk = tiles[chunkStart..<min(chunkStart + 8, tiles.count)]
            let summary = fixture.coordinator.uploadNextBatch(
                prioritizedAddresses: chunk.map(\.descriptor.address),
                budget: WaveformTileUploadBudget(maximumBytesPerBatch: bytesPerTile * 8, maximumTilesPerBatch: 8),
                upload: fakeUpload
            )
            totalEvictions += summary.evictedCount
            let snapshot = fixture.residencyStore.snapshot()
            try require(snapshot.residentBytes <= snapshot.maximumResidentBytes, "residency exceeded its byte budget during churn")
            try require(snapshot.residentCount <= residentTileCapacity, "residency exceeded its tile capacity during churn")
        }

        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        let snapshot = fixture.residencyStore.snapshot()
        let expectedTail = Set(tiles.suffix(residentTileCapacity).map(\.descriptor.address))
        try require(snapshot.residentBytes == bytesPerTile * residentTileCapacity, "pressure test did not settle at the configured byte budget")
        try require(Set(snapshot.residentTiles.map(\.address)) == expectedTail, "LRU pressure did not retain the newest resident working set")
        try require(totalEvictions == tiles.count - residentTileCapacity, "pressure test eviction count was not deterministic")
        try require(elapsedMilliseconds <= 500, String(format: "residency pressure churn took %.2fms", elapsedMilliseconds))
    }

    private static func verifyStaleUploadDoesNotBecomeResident() throws {
        let fixture = makeFixture(maximumResidentBytes: 1_000_000)
        let tile = peakTile(sourceID: WaveformSourceID(rawValue: "stale-source"), tileIndex: 0, binCount: 4)
        fixture.tileStore.commit(.peak(tile))
        var discardedUploads: [(WaveformTileAddress, WaveformTileGPUResource)] = []

        let summary = fixture.coordinator.uploadNextBatch(
            prioritizedAddresses: [tile.descriptor.address],
            budget: WaveformTileUploadBudget(maximumBytesPerBatch: 512, maximumTilesPerBatch: 1),
            discardUpload: { address, resource in
                discardedUploads.append((address, resource))
            },
            upload: { payload in
                let resource = fakeUpload(payload)
                fixture.coordinator.removeAll(for: payload.descriptor.address.sourceID)
                fixture.tileStore.removeAll(for: payload.descriptor.address.sourceID)
                return resource
            }
        )

        try require(summary.uploadedCount == 0, "stale tile should not upload")
        try require(summary.staleUploadCount == 1, "stale upload was not counted")
        try require(discardedUploads.count == 1, "stale uploaded resource was not discarded")
        try require(discardedUploads.first?.0 == tile.descriptor.address, "discarded stale upload had unexpected address")
        try require(discardedUploads.first?.1.id.rawValue.contains("stale-source") == true, "discarded stale upload had unexpected resource")
        try require(fixture.residencyStore.resource(for: tile.descriptor.address) == nil, "stale tile became resident")
        try require(fixture.tileStore.state(for: tile.descriptor.address) == .missing, "stale source should be removed from tile store")
    }

    private static func verifyRawSampleByteEstimate() throws {
        let descriptor = WaveformTileDescriptor(
            address: WaveformTileAddress(
                sourceID: WaveformSourceID(rawValue: "raw-source"),
                kind: .rawSamples,
                channelMode: .stereoPair,
                level: 0,
                tileIndex: 0
            ),
            frameRange: WaveformFrameRange(startFrame: 0, endFrame: 8),
            framesPerBin: 1,
            expectedBinCount: 8
        )
        let tile = WaveformRawSampleTile(
            descriptor: descriptor,
            samplesByChannel: [
                Array(repeating: 0.1, count: 8),
                Array(repeating: -0.1, count: 8),
            ]
        )

        try require(
            WaveformTileUploadCoordinator.estimatedUploadBytes(for: .rawSamples(tile)) == 64,
            "raw sample byte estimate should be channel sample count * Float stride"
        )
    }

    private static func verifyMetalBufferStoreUploadIfAvailable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return
        }

        let store = WaveformTileMetalBufferStore(device: device)
        let peak = peakTile(tileIndex: 9, binCount: 3)
        let peakResource = try store.upload(.peak(peak))
        guard let peakAllocation = store.allocation(for: peak.descriptor.address) else {
            throw SmokeError.failed("metal buffer store did not retain peak allocation")
        }
        try require(peakAllocation.resourceID == peakResource.id, "peak allocation did not use returned resource ID")
        try require(peakAllocation.binCount == 3, "peak allocation bin count was incorrect")
        try require(peakAllocation.byteCount == peakResource.byteCount, "peak allocation byte count did not match resource")

        store.remove(resourceID: peakResource.id)
        try require(store.allocation(for: peak.descriptor.address) == nil, "resource removal did not clear peak allocation")

        let rawDescriptor = WaveformTileDescriptor(
            address: WaveformTileAddress(
                sourceID: WaveformSourceID(rawValue: "metal-raw-source"),
                kind: .rawSamples,
                channelMode: .stereoPair,
                level: 0,
                tileIndex: 0
            ),
            frameRange: WaveformFrameRange(startFrame: 0, endFrame: 4),
            framesPerBin: 1,
            expectedBinCount: 4
        )
        let rawTile = WaveformRawSampleTile(
            descriptor: rawDescriptor,
            samplesByChannel: [
                [0.1, -0.2, 0.3, -0.4],
                [-0.1, 0.2, -0.3, 0.4],
            ]
        )
        let rawResource = try store.upload(.rawSamples(rawTile))
        guard let rawAllocation = store.allocation(for: rawDescriptor.address) else {
            throw SmokeError.failed("metal buffer store did not retain raw allocation")
        }
        try require(rawAllocation.binCount == 4, "raw allocation should expose one packed bin per sample frame")
        try require(rawAllocation.byteCount == rawResource.byteCount, "raw allocation byte count did not match resource")
        store.remove(rawDescriptor.address)
        try require(store.allocation(for: rawDescriptor.address) == nil, "address removal did not clear raw allocation")
    }

    private struct Fixture {
        let tileStore: WaveformTileStore
        let residencyStore: WaveformTileGPUResidencyStore
        let coordinator: WaveformTileUploadCoordinator
    }

    private static func makeFixture(maximumResidentBytes: Int) -> Fixture {
        let tileStore = WaveformTileStore()
        let residencyStore = WaveformTileGPUResidencyStore(maximumResidentBytes: maximumResidentBytes)
        return Fixture(
            tileStore: tileStore,
            residencyStore: residencyStore,
            coordinator: WaveformTileUploadCoordinator(
                tileStore: tileStore,
                residencyStore: residencyStore
            )
        )
    }

    private static func peakTile(
        sourceID: WaveformSourceID = WaveformSourceID(rawValue: "upload-source"),
        tileIndex: Int,
        binCount: Int
    ) -> WaveformPeakTile {
        let descriptor = WaveformTileDescriptor(
            address: WaveformTileAddress(
                sourceID: sourceID,
                kind: .peak,
                channelMode: .monoMix,
                level: 5,
                tileIndex: tileIndex
            ),
            frameRange: WaveformFrameRange(
                startFrame: Int64(tileIndex * 256),
                endFrame: Int64((tileIndex + 1) * 256)
            ),
            framesPerBin: 64,
            expectedBinCount: binCount
        )
        let bins = (0..<binCount).map { index in
            WaveformOverview.Bin(
                minimumSample: -0.1 * Float(index + 1),
                maximumSample: 0.1 * Float(index + 1),
                rmsSample: 0.05,
                lowEnergy: 0.02,
                midEnergy: 0.03,
                highEnergy: 0.04
            )
        }
        return WaveformPeakTile(descriptor: descriptor, bins: bins)
    }

    private static func fakeUpload(_ payload: WaveformTilePayload) -> WaveformTileGPUResource {
        let descriptor = payload.descriptor
        return WaveformTileGPUResource(
            id: WaveformTileGPUResourceID(rawValue: "gpu-\(descriptor.address.sourceID.rawValue)-\(descriptor.address.tileIndex)"),
            byteCount: WaveformTileUploadCoordinator.estimatedUploadBytes(for: payload)
        )
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw SmokeError.failed(message)
        }
    }
}
