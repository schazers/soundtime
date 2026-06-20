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
        try verifyOverviewCacheRoundTrip(rootDirectory: rootDirectory)
        try verifyEditedOverviewCacheRoundTrip(rootDirectory: rootDirectory)

        let checks = [
            "manifest round trip",
            "invalid manifest rejection",
            "scoped cache removal",
            "overview cache round trip",
            "edited overview cache round trip",
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

    private static func verifyOverviewCacheRoundTrip(rootDirectory: URL) throws {
        let wavURL = rootDirectory.appendingPathComponent("Overview.wav")
        let byteCount = 44 + 2_048 * 4
        try Data(repeating: 0, count: byteCount).write(to: wavURL, options: [.atomic])
        let fileInfo = WAVFileInfo(
            url: wavURL,
            formatTag: 1,
            channelCount: 2,
            sampleRate: 48_000,
            blockAlign: 4,
            bitsPerSample: 16,
            dataRange: 44..<byteCount
        )
        let store = WaveformOverviewDiskCacheStore(rootDirectory: rootDirectory)
        let coarseOverview = makeOverview(duration: fileInfo.duration, binCount: 64)
        let fineOverview = makeOverview(duration: fileInfo.duration, binCount: 128)

        try store.saveOverview(
            coarseOverview,
            targetBinCount: 64,
            samplesPerBin: 8,
            fileInfo: fileInfo
        )
        try store.saveOverview(
            fineOverview,
            targetBinCount: 128,
            samplesPerBin: 4,
            fileInfo: fileInfo
        )

        let loaded = try requireValue(
            store.loadBestOverview(for: wavURL, fileInfo: fileInfo),
            "overview cache did not load"
        )
        try require(loaded.level.actualBinCount == 128, "overview cache did not choose the finest level")
        try requireOverviewsMatch(loaded.overview, fineOverview)

        let loadedCoarse = try requireValue(
            store.loadBestOverview(for: wavURL, fileInfo: fileInfo, maximumBinCount: 64),
            "overview cache did not load coarse level"
        )
        try require(loadedCoarse.level.actualBinCount == 64, "overview cache ignored maximum bin count")
        try requireOverviewsMatch(loadedCoarse.overview, coarseOverview)
    }

    private static func verifyEditedOverviewCacheRoundTrip(rootDirectory: URL) throws {
        let wavURL = rootDirectory.appendingPathComponent("Edited.wav")
        let byteCount = 44 + 4_096 * 4
        try Data(repeating: 0, count: byteCount).write(to: wavURL, options: [.atomic])
        let fileInfo = WAVFileInfo(
            url: wavURL,
            formatTag: 1,
            channelCount: 2,
            sampleRate: 48_000,
            blockAlign: 4,
            bitsPerSample: 16,
            dataRange: 44..<byteCount
        )
        var timeline = AudioFileEditTimeline(fileInfo: fileInfo)
        _ = timeline.delete(TimelineSelection(startProgress: 0.25, endProgress: 0.5))
        _ = timeline.applyGain(0.5, to: TimelineSelection(startProgress: 0.5, endProgress: 0.75))
        let editedOverview = makeOverview(duration: timeline.duration, binCount: 96)
        let store = WaveformOverviewDiskCacheStore(rootDirectory: rootDirectory)

        try store.saveEditedOverview(
            editedOverview,
            fileInfo: fileInfo,
            editTimeline: timeline
        )
        let loaded = try requireValue(
            store.loadEditedOverview(
                for: wavURL,
                fileInfo: fileInfo,
                editTimeline: timeline
            ),
            "edited overview cache did not load"
        )
        try requireOverviewsMatch(loaded.overview, editedOverview)

        var differentTimeline = AudioFileEditTimeline(fileInfo: fileInfo)
        _ = differentTimeline.delete(TimelineSelection(startProgress: 0.1, endProgress: 0.2))
        try require(
            try store.loadEditedOverview(
                for: wavURL,
                fileInfo: fileInfo,
                editTimeline: differentTimeline
            ) == nil,
            "edited overview cache loaded for a different edit timeline"
        )
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

    private static func makeOverview(duration: TimeInterval, binCount: Int) -> WaveformOverview {
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount)
        for index in 0..<binCount {
            let phase = Float(index) / Float(max(binCount - 1, 1))
            let peak = min(max(0.12 + 0.48 * abs(sin(phase * 7.3)), 0), 1)
            bins.append(WaveformOverview.Bin(
                minimumSample: -peak * 0.8,
                maximumSample: peak,
                rmsSample: peak * 0.52,
                lowEnergy: 0.5 + phase * 0.1,
                midEnergy: 0.35,
                highEnergy: 0.15
            ))
        }
        return WaveformOverview(duration: duration, bins: bins)
    }

    private static func requireOverviewsMatch(
        _ lhs: WaveformOverview,
        _ rhs: WaveformOverview
    ) throws {
        try require(abs(lhs.duration - rhs.duration) < 0.000_001, "overview duration mismatch")
        try require(lhs.bins.count == rhs.bins.count, "overview bin count mismatch")
        for (leftBin, rightBin) in zip(lhs.bins, rhs.bins) {
            try require(abs(leftBin.minimumSample - rightBin.minimumSample) < 0.000_001, "minimum sample mismatch")
            try require(abs(leftBin.maximumSample - rightBin.maximumSample) < 0.000_001, "maximum sample mismatch")
            try require(abs(leftBin.rmsSample - rightBin.rmsSample) < 0.000_001, "rms sample mismatch")
            try require(abs(leftBin.lowEnergy - rightBin.lowEnergy) < 0.000_001, "low energy mismatch")
            try require(abs(leftBin.midEnergy - rightBin.midEnergy) < 0.000_001, "mid energy mismatch")
            try require(abs(leftBin.highEnergy - rightBin.highEnergy) < 0.000_001, "high energy mismatch")
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw SmokeError.failed(message)
        }
    }

    private static func requireValue<T>(_ value: @autoclosure () throws -> T?, _ message: String) throws -> T {
        guard let value = try value() else {
            throw SmokeError.failed(message)
        }
        return value
    }
}
