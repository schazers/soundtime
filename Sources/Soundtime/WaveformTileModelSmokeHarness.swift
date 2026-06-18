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
        try verifyTileAddressSeparation()
        try verifyFrameRangeSemantics()
        try verifyTileStoreStateTransitions()
        try verifySourceScopedRemoval()

        let checks = [
            "fingerprint stability",
            "tile address separation",
            "frame range semantics",
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

        try require(monoPeak != leftPeak, "channel mode was not part of tile identity")
        try require(monoPeak != monoRaw, "tile kind was not part of tile identity")
        try require(monoPeak != nextTile, "tile index was not part of tile identity")
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
