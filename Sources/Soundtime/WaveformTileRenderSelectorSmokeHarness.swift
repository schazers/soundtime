import Foundation

enum WaveformTileRenderSelectorSmokeHarness {
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

        try verifyCPUCommittedTileIsSkippedWithoutResidency()
        try verifyExactResidentSelection()
        try verifyCoarserResidentFallback()
        try verifyLastGoodResidentFallback()
        try verifySourceRemovalClearsLastGood()

        let checks = [
            "CPU committed tile skipped without residency",
            "exact resident selection",
            "coarser resident fallback",
            "last-good resident fallback",
            "source removal clears last-good",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "waveform-tile-render-selector-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: ["rendererIntegration": "disabled"],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }
        print("Soundtime waveform tile render selector smoke passed")
    }

    private static func verifyCPUCommittedTileIsSkippedWithoutResidency() throws {
        let fixture = makeFixture()
        let tile = peakTile(level: 5, tileIndex: 0)
        fixture.tileStore.commit(.peak(tile))

        let selection = fixture.selector.selectRenderableTiles(
            for: [request(for: tile.descriptor)]
        )

        try require(selection.requestedCount == 1, "selector did not consider visible request")
        try require(selection.selectedCount == 0, "CPU-only tile should not be renderable")
        try require(selection.skippedCount == 1, "CPU-only skip was not counted")
    }

    private static func verifyExactResidentSelection() throws {
        let fixture = makeFixture()
        let tile = peakTile(level: 5, tileIndex: 0)
        commitResident(tile, into: fixture)

        let selection = fixture.selector.selectRenderableTiles(
            for: [request(for: tile.descriptor)]
        )

        try require(selection.selectedCount == 1, "exact resident tile was not selected")
        try require(selection.exactResidentCount == 1, "exact resident count was wrong")
        try require(selection.tiles[0].selectedDescriptor.address == tile.descriptor.address, "selected wrong exact tile")
        try require(selection.tiles[0].source == .exactResident, "selection source was not exact")
    }

    private static func verifyCoarserResidentFallback() throws {
        let fixture = makeFixture()
        let requested = peakTile(level: 5, tileIndex: 0)
        let coarser = peakTile(level: 8, tileIndex: 0)
        commitResident(coarser, into: fixture)

        let selection = fixture.selector.selectRenderableTiles(
            for: [request(for: requested.descriptor)]
        )

        try require(selection.selectedCount == 1, "coarser resident tile was not selected")
        try require(selection.coarserResidentCount == 1, "coarser resident count was wrong")
        try require(selection.tiles[0].selectedDescriptor.address == coarser.descriptor.address, "selected wrong coarser tile")
        try require(selection.tiles[0].source == .coarserResident, "selection source was not coarser")
    }

    private static func verifyLastGoodResidentFallback() throws {
        let fixture = makeFixture()
        let finer = peakTile(level: 4, tileIndex: 0)
        let requestedFiner = request(for: finer.descriptor)
        commitResident(finer, into: fixture)

        let firstSelection = fixture.selector.selectRenderableTiles(for: [requestedFiner])
        try require(firstSelection.exactResidentCount == 1, "setup did not select exact finer tile")

        let missingCoarser = peakTile(level: 6, tileIndex: 0)
        let secondSelection = fixture.selector.selectRenderableTiles(
            for: [request(for: missingCoarser.descriptor)]
        )

        try require(secondSelection.selectedCount == 1, "last-good resident tile was not selected")
        try require(secondSelection.lastGoodResidentCount == 1, "last-good count was wrong")
        try require(secondSelection.tiles[0].selectedDescriptor.address == finer.descriptor.address, "selected wrong last-good tile")
        try require(secondSelection.tiles[0].source == .lastGoodResident, "selection source was not last-good")
    }

    private static func verifySourceRemovalClearsLastGood() throws {
        let fixture = makeFixture()
        let sourceID = WaveformSourceID(rawValue: "removed-source")
        let tile = peakTile(sourceID: sourceID, level: 4, tileIndex: 0)
        commitResident(tile, into: fixture)

        let firstSelection = fixture.selector.selectRenderableTiles(
            for: [request(for: tile.descriptor)]
        )
        try require(firstSelection.selectedCount == 1, "setup did not select resident tile")

        fixture.selector.removeAll(for: sourceID)
        _ = fixture.residencyStore.removeAll(for: sourceID)
        fixture.tileStore.removeAll(for: sourceID)

        let missing = peakTile(sourceID: sourceID, level: 6, tileIndex: 0)
        let secondSelection = fixture.selector.selectRenderableTiles(
            for: [request(for: missing.descriptor)]
        )

        try require(secondSelection.selectedCount == 0, "removed source should not use stale last-good tile")
        try require(secondSelection.skippedCount == 1, "removed source skip was not counted")
    }

    private struct Fixture {
        let tileStore: WaveformTileStore
        let residencyStore: WaveformTileGPUResidencyStore
        let selector: WaveformTileRenderSelector
    }

    private static func makeFixture() -> Fixture {
        let tileStore = WaveformTileStore()
        let residencyStore = WaveformTileGPUResidencyStore(maximumResidentBytes: 1_000_000)
        return Fixture(
            tileStore: tileStore,
            residencyStore: residencyStore,
            selector: WaveformTileRenderSelector(
                tileStore: tileStore,
                residencyStore: residencyStore
            )
        )
    }

    private static func commitResident(_ tile: WaveformPeakTile, into fixture: Fixture) {
        fixture.tileStore.commit(.peak(tile))
        let resource = WaveformTileGPUResource(
            id: WaveformTileGPUResourceID(rawValue: "gpu-\(tile.descriptor.address.level)-\(tile.descriptor.address.tileIndex)"),
            byteCount: max(tile.bins.count, 1) * WaveformPeakTileBinaryCodec.floatsPerBin * MemoryLayout<Float>.size
        )
        _ = fixture.residencyStore.insert(resource, for: tile.descriptor.address)
        fixture.tileStore.markGPUResident(tile.descriptor.address)
    }

    private static func peakTile(
        sourceID: WaveformSourceID = WaveformSourceID(rawValue: "render-selector-source"),
        level: Int,
        tileIndex: Int
    ) -> WaveformPeakTile {
        let descriptor = WaveformTileDescriptor(
            address: WaveformTileAddress(
                sourceID: sourceID,
                kind: .peak,
                channelMode: .monoMix,
                level: level,
                tileIndex: tileIndex
            ),
            frameRange: WaveformFrameRange(
                startFrame: Int64(tileIndex * 1_024),
                endFrame: Int64((tileIndex + 1) * 1_024)
            ),
            framesPerBin: max(1, 1 << level),
            expectedBinCount: max(1, 1_024 / max(1, 1 << level))
        )
        let bins = (0..<max(descriptor.expectedBinCount, 1)).map { index in
            WaveformOverview.Bin(
                minimumSample: -0.2 - Float(index) * 0.01,
                maximumSample: 0.2 + Float(index) * 0.01,
                rmsSample: 0.1,
                lowEnergy: 0.01,
                midEnergy: 0.02,
                highEnergy: 0.03
            )
        }
        return WaveformPeakTile(descriptor: descriptor, bins: bins)
    }

    private static func request(for descriptor: WaveformTileDescriptor) -> WaveformTileRequest {
        WaveformTileRequest(
            descriptor: descriptor,
            purpose: .visible,
            distanceFromVisibleTiles: 0,
            samplesPerPixel: Double(descriptor.framesPerBin)
        )
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw SmokeError.failed(message)
        }
    }
}
