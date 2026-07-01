import Foundation

enum WaveformTileModelSmokeHarness {
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

        try verifyFingerprintStability()
        try verifyStableSourceIdentitySurvivesTimelineEdits()
        try verifyTileAddressSeparation()
        try verifyFrameRangeSemantics()
        try verifyBinRangeSemantics()
        try verifyTileStoreStateTransitions()
        try verifySourceScopedRemoval()

        let checks = [
            "fingerprint stability",
            "stable source identity survives timeline edits",
            "tile address separation",
            "frame range semantics",
            "bin range semantics",
            "tile store state transitions",
            "source scoped removal",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "waveform-tile-model-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: ["rendererIntegration": "disabled"],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }
        print("Soundtime waveform tile model smoke passed")
    }

    private static func verifyFingerprintStability() throws {
        let url = URL(fileURLWithPath: "/tmp/Soundtime Tile Test.wav")
        let date = Date(timeIntervalSinceReferenceDate: 1_234.5)
        let first = WaveformFileFingerprint(
            url: url,
            fileSize: 123_456,
            modificationDate: date,
            sampleRate: 48_000,
            channelCount: 2
        )
        let second = WaveformFileFingerprint(
            url: url,
            fileSize: 123_456,
            modificationDate: date,
            sampleRate: 48_000,
            channelCount: 2
        )
        let changed = WaveformFileFingerprint(
            url: url,
            fileSize: 123_457,
            modificationDate: date,
            sampleRate: 48_000,
            channelCount: 2
        )

        try require(first.cacheKey == second.cacheKey, "identical fingerprints produced different cache keys")
        try require(first.cacheKey != changed.cacheKey, "changed fingerprints produced same cache key")
        try require(WaveformSourceID(fingerprint: first) == WaveformSourceID(fingerprint: second), "source IDs are not stable")
    }

    private static func verifyStableSourceIdentitySurvivesTimelineEdits() throws {
        let fingerprint = WaveformFileFingerprint(
            url: URL(fileURLWithPath: "/tmp/Soundtime Stable Source.wav"),
            fileSize: 987_654,
            modificationDate: Date(timeIntervalSinceReferenceDate: 9_876.5),
            sampleRate: 48_000,
            channelCount: 2
        )
        let source = WaveformTileBuildSource(
            url: URL(fileURLWithPath: "/tmp/Soundtime Stable Source.wav"),
            fingerprint: fingerprint,
            duration: 120,
            frameCount: 5_760_000,
            sampleRate: 48_000,
            channelMode: .monoMix
        )
        let timelineEditRevision = 42
        let afterRippleDelete = WaveformTileBuildSource(
            url: source.url,
            fingerprint: fingerprint,
            duration: source.duration,
            frameCount: source.frameCount,
            sampleRate: 48_000,
            channelMode: .monoMix
        )
        let renderedEffectVersion = WaveformTileBuildSource(
            url: source.url,
            fingerprint: fingerprint,
            duration: source.duration,
            frameCount: source.frameCount,
            sampleRate: 48_000,
            channelMode: .monoMix,
            editGraphID: "rendered-effect-\(timelineEditRevision)"
        )

        try require(
            source.sourceID == afterRippleDelete.sourceID,
            "timeline edits should not change the underlying source ID"
        )
        try require(
            source.metadata.editGraphID == nil && afterRippleDelete.metadata.editGraphID == nil,
            "normal timeline edits should remap source tiles without creating an edit graph identity"
        )
        try require(
            source.metadata.channelMode == afterRippleDelete.metadata.channelMode,
            "channel mode should stay part of stable tile metadata"
        )
        try require(
            source.metadata.sampleRate == afterRippleDelete.metadata.sampleRate,
            "sample rate should stay part of stable tile metadata"
        )
        try require(
            renderedEffectVersion.sourceID == source.sourceID,
            "rendered effect versions should still point at the same source content fingerprint"
        )
        try require(
            renderedEffectVersion.metadata.editGraphID != source.metadata.editGraphID,
            "rendered effect versions need an edit graph identity to avoid colliding with source tiles"
        )
    }

    private static func verifyTileAddressSeparation() throws {
        let sourceID = WaveformSourceID(rawValue: "source-a")
        let monoPeak = WaveformTileAddress(
            sourceID: sourceID,
            kind: .peak,
            channelMode: .monoMix,
            level: 0,
            tileIndex: 0
        )
        let leftPeak = WaveformTileAddress(
            sourceID: sourceID,
            kind: .peak,
            channelMode: .left,
            level: 0,
            tileIndex: 0
        )
        let monoRaw = WaveformTileAddress(
            sourceID: sourceID,
            kind: .rawSamples,
            channelMode: .monoMix,
            level: 0,
            tileIndex: 0
        )
        let nextTile = WaveformTileAddress(
            sourceID: sourceID,
            kind: .peak,
            channelMode: .monoMix,
            level: 0,
            tileIndex: 1
        )
        let editedGraphPeak = WaveformTileAddress(
            sourceID: sourceID,
            editGraphID: "rendered-effect-1",
            kind: .peak,
            channelMode: .monoMix,
            level: 0,
            tileIndex: 0
        )

        try require(monoPeak != leftPeak, "channel mode was not part of tile identity")
        try require(monoPeak != monoRaw, "tile kind was not part of tile identity")
        try require(monoPeak != nextTile, "tile index was not part of tile identity")
        try require(monoPeak != editedGraphPeak, "edit graph ID was not part of tile identity")
    }

    private static func verifyFrameRangeSemantics() throws {
        let range = WaveformFrameRange(startFrame: 128, endFrame: 256)
        let overlapping = WaveformFrameRange(startFrame: 200, endFrame: 300)
        let adjacent = WaveformFrameRange(startFrame: 256, endFrame: 400)
        let clamped = WaveformFrameRange(startFrame: 500, endFrame: 400)

        try require(range.frameCount == 128, "frame range count was incorrect")
        try require(range.contains(frame: 128), "range should include start frame")
        try require(!range.contains(frame: 256), "range should exclude end frame")
        try require(range.intersects(overlapping), "overlap was not detected")
        try require(!range.intersects(adjacent), "adjacent range should not intersect")
        try require(clamped.isEmpty, "inverted ranges should clamp to empty")
    }

    private static func verifyBinRangeSemantics() throws {
        let range = WaveformBinRange(startBin: 128, endBin: 256)
        let overlapping = WaveformBinRange(startBin: 200, endBin: 300)
        let adjacent = WaveformBinRange(startBin: 256, endBin: 400)
        let clamped = WaveformBinRange(startBin: 500, endBin: 400)
        let descriptor = WaveformTileDescriptor(
            address: WaveformTileAddress(
                sourceID: WaveformSourceID(rawValue: "bin-range-source"),
                kind: .peak,
                channelMode: .monoMix,
                level: 5,
                tileIndex: 3
            ),
            frameRange: WaveformFrameRange(startFrame: 12_288, endFrame: 16_384),
            framesPerBin: 32,
            expectedBinCount: 128
        )

        try require(range.binCount == 128, "bin range count was incorrect")
        try require(range.contains(bin: 128), "bin range should include start bin")
        try require(!range.contains(bin: 256), "bin range should exclude end bin")
        try require(range.intersects(overlapping), "bin overlap was not detected")
        try require(!range.intersects(adjacent), "adjacent bin ranges should not intersect")
        try require(clamped.isEmpty, "inverted bin ranges should clamp to empty")
        try require(descriptor.binRange.startBin == 384, "descriptor did not derive global start bin")
        try require(descriptor.binRange.endBin == 512, "descriptor did not derive global end bin")
    }

    private static func verifyTileStoreStateTransitions() throws {
        let store = WaveformTileStore()
        let address = WaveformTileAddress(
            sourceID: WaveformSourceID(rawValue: "source-a"),
            kind: .peak,
            channelMode: .monoMix,
            level: 1,
            tileIndex: 4
        )
        let descriptor = WaveformTileDescriptor(
            address: address,
            frameRange: WaveformFrameRange(startFrame: 4_096, endFrame: 8_192),
            framesPerBin: 16,
            expectedBinCount: 2
        )
        let bins = [
            WaveformOverview.Bin(minimumSample: -0.25, maximumSample: 0.5, rmsSample: 0.2),
            WaveformOverview.Bin(minimumSample: -0.5, maximumSample: 0.8, rmsSample: 0.4),
        ]

        try require(store.state(for: address) == .missing, "new tile should start missing")
        store.markBuilding(descriptor)
        try require(store.state(for: address) == .building, "tile did not enter building state")
        store.commit(.peak(WaveformPeakTile(descriptor: descriptor, bins: bins)))
        try require(store.state(for: address) == .committedCPU, "tile did not commit on CPU")
        try require(store.committedPeakTile(for: address)?.bins.count == bins.count, "committed tile payload was missing")
        store.markGPUResident(address)
        try require(store.state(for: address) == .residentGPU, "tile did not become GPU resident")
    }

    private static func verifySourceScopedRemoval() throws {
        let store = WaveformTileStore()
        let sourceA = WaveformSourceID(rawValue: "source-a")
        let sourceB = WaveformSourceID(rawValue: "source-b")
        let addressA = WaveformTileAddress(
            sourceID: sourceA,
            kind: .peak,
            channelMode: .monoMix,
            level: 0,
            tileIndex: 0
        )
        let addressB = WaveformTileAddress(
            sourceID: sourceB,
            kind: .peak,
            channelMode: .monoMix,
            level: 0,
            tileIndex: 0
        )
        let range = WaveformFrameRange(startFrame: 0, endFrame: 1_024)
        let descriptorA = WaveformTileDescriptor(address: addressA, frameRange: range, framesPerBin: 16, expectedBinCount: 1)
        let descriptorB = WaveformTileDescriptor(address: addressB, frameRange: range, framesPerBin: 16, expectedBinCount: 1)
        let bin = WaveformOverview.Bin(minimumSample: -0.1, maximumSample: 0.1, rmsSample: 0.05)

        store.commit(.peak(WaveformPeakTile(descriptor: descriptorA, bins: [bin])))
        store.commit(.peak(WaveformPeakTile(descriptor: descriptorB, bins: [bin])))
        try require(store.committedAddresses().count == 2, "source removal setup did not commit both tiles")
        store.removeAll(for: sourceA)
        try require(store.state(for: addressA) == .missing, "source-scoped removal did not remove source A")
        try require(store.state(for: addressB) == .committedCPU, "source-scoped removal removed the wrong source")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw SmokeError.failed(message)
        }
    }
}
