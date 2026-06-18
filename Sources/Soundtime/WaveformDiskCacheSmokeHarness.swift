import Foundation

enum WaveformDiskCacheSmokeHarness {
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
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundtime-waveform-cache-smoke-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootDirectory)
        }

        let store = WaveformDiskCacheStore(rootDirectory: rootDirectory)

        try verifyManifestRoundTrip(store: store)
        try verifyInvalidManifestRejection(store: store)
        try verifyScopedRemoval(store: store)

        let checks = [
            "manifest round trip",
            "invalid manifest rejection",
            "scoped cache removal",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "waveform-disk-cache-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: ["rendererIntegration": "disabled"],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }
        print("Soundtime waveform disk cache smoke passed")
    }

    private static func verifyManifestRoundTrip(store: WaveformDiskCacheStore) throws {
        let fingerprint = makeFingerprint(fileName: "Podcast.wav", fileSize: 123_456)
        let level = WaveformDiskCacheManifest.TileLevel(
            kind: .peak,
            channelMode: .stereoPair,
            level: 2,
            framesPerBin: 64,
            framesPerTile: 65_536,
            tileCount: 12,
            fileName: "peak-stereo-l002.bin"
        )
        let manifest = WaveformDiskCacheManifest(
            sourceID: WaveformSourceID(fingerprint: fingerprint),
            fingerprint: fingerprint,
            duration: 98.5,
            frameCount: 4_728_000,
            levels: [level]
        )

        try require(try store.loadManifest(for: fingerprint) == nil, "fresh cache should not have a manifest")
        try store.saveManifest(manifest)
        let loaded = try store.loadManifest(for: fingerprint)
        try require(loaded == manifest, "manifest did not round-trip")
        try require(
            store.manifestURL(for: fingerprint).lastPathComponent == "manifest.json",
            "manifest URL should use the expected file name"
        )
    }

    private static func verifyInvalidManifestRejection(store: WaveformDiskCacheStore) throws {
        let validFingerprint = makeFingerprint(fileName: "Valid.wav", fileSize: 200)
        let staleFingerprint = makeFingerprint(fileName: "Valid.wav", fileSize: 201)
        let staleManifest = WaveformDiskCacheManifest(
            sourceID: WaveformSourceID(fingerprint: staleFingerprint),
            fingerprint: staleFingerprint,
            duration: 1,
            frameCount: 48_000
        )

        try FileManager.default.createDirectory(
            at: store.cacheDirectory(for: validFingerprint),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(staleManifest)
        try data.write(to: store.manifestURL(for: validFingerprint), options: [.atomic])

        do {
            _ = try store.loadManifest(for: validFingerprint)
            throw SmokeError.failed("stale manifest loaded successfully")
        } catch WaveformDiskCacheError.invalidManifest {
            return
        }
    }

    private static func verifyScopedRemoval(store: WaveformDiskCacheStore) throws {
        let firstFingerprint = makeFingerprint(fileName: "First.wav", fileSize: 1_024)
        let secondFingerprint = makeFingerprint(fileName: "Second.wav", fileSize: 2_048)
        let firstManifest = store.makeEmptyManifest(
            for: firstFingerprint,
            duration: 1,
            frameCount: 48_000
        )
        let secondManifest = store.makeEmptyManifest(
            for: secondFingerprint,
            duration: 2,
            frameCount: 96_000
        )

        try store.saveManifest(firstManifest)
        try store.saveManifest(secondManifest)
        try store.removeCache(for: firstFingerprint)

        try require(try store.loadManifest(for: firstFingerprint) == nil, "removed manifest still loaded")
        try require(try store.loadManifest(for: secondFingerprint) == secondManifest, "removing one cache removed another")
    }

    private static func makeFingerprint(fileName: String, fileSize: Int64) -> WaveformFileFingerprint {
        WaveformFileFingerprint(
            url: URL(fileURLWithPath: "/tmp/\(fileName)"),
            fileSize: fileSize,
            modificationDate: Date(timeIntervalSinceReferenceDate: 42),
            sampleRate: 48_000,
            channelCount: 2,
            decoderIdentifier: "wav-1-16-bit"
        )
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw SmokeError.failed(message)
        }
    }
}
