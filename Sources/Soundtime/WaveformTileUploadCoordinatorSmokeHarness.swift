import Foundation

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
        try verifyStaleUploadDoesNotBecomeResident()
        try verifyRawSampleByteEstimate()

        let checks = [
            "upload budget limits batch",
            "resident tiles are skipped",
            "LRU eviction returns tiles to CPU committed",
            "stale upload does not become resident",
            "raw sample byte estimate",
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
        try require(summary.skippedBudgetCount == 2, "budget skips were not counted")
        try require(fixture.tileStore.state(for: addresses[0]) == .residentGPU, "first tile did not become GPU resident")
        try require(fixture.tileStore.state(for: addresses[2]) == .committedCPU, "budget-skipped tile should remain CPU committed")
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
        try require(fixture.tileStore.state(for: first.descriptor.address) == .residentGPU, "recently touched tile should remain resident")
        try require(fixture.tileStore.state(for: second.descriptor.address) == .committedCPU, "least recently used tile should return to CPU committed")
        try require(fixture.tileStore.state(for: third.descriptor.address) == .residentGPU, "new tile should become resident")
    }

    private static func verifyStaleUploadDoesNotBecomeResident() throws {
        let fixture = makeFixture(maximumResidentBytes: 1_000_000)
        let tile = peakTile(sourceID: WaveformSourceID(rawValue: "stale-source"), tileIndex: 0, binCount: 4)
        fixture.tileStore.commit(.peak(tile))

        let summary = fixture.coordinator.uploadNextBatch(
            prioritizedAddresses: [tile.descriptor.address],
            budget: WaveformTileUploadBudget(maximumBytesPerBatch: 512, maximumTilesPerBatch: 1),
            beforeUpload: { address in
                fixture.coordinator.removeAll(for: address.sourceID)
                fixture.tileStore.removeAll(for: address.sourceID)
            },
            upload: fakeUpload
        )

        try require(summary.uploadedCount == 0, "stale tile should not upload")
        try require(summary.staleUploadCount == 1, "stale upload was not counted")
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
