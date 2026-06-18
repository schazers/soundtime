import Foundation

enum WaveformTileBuildWorkerSmokeHarness {
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
            .appendingPathComponent("soundtime-tile-build-worker-smoke-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        try verifyDiskHitCommitsTile(rootDirectory: rootDirectory.appendingPathComponent("disk-hit", isDirectory: true))
        try verifyBuildMissCommitsAndCachesTile(rootDirectory: rootDirectory.appendingPathComponent("build-miss", isDirectory: true))
        try verifyRawSampleRequestCommitsTile(rootDirectory: rootDirectory.appendingPathComponent("raw", isDirectory: true))
        try verifyStaleCancellationDoesNotCommit(rootDirectory: rootDirectory.appendingPathComponent("stale", isDirectory: true))
        try verifyBatchLimits(rootDirectory: rootDirectory.appendingPathComponent("batch", isDirectory: true))

        let checks = [
            "disk hit commits tile",
            "build miss commits and caches tile",
            "raw sample request commits tile",
            "stale cancellation does not commit",
            "batch limits",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "waveform-tile-build-worker-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: ["rendererIntegration": "disabled"],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }
        print("Soundtime waveform tile build worker smoke passed")
    }

    private static func verifyDiskHitCommitsTile(rootDirectory: URL) throws {
        let fixture = try makeFixture(rootDirectory: rootDirectory)
        let request = tileRequest(for: fixture.source, tileIndex: 2)
        let prebuilt = try WaveformPeakTileBuilder.buildWAVPeakLevel(
            url: fixture.wavURL,
            framesPerBin: request.descriptor.framesPerBin,
            framesPerTile: 256,
            level: request.descriptor.address.level,
            channelMode: request.descriptor.address.channelMode,
            shouldYieldForPlayback: false
        )
        _ = try fixture.diskCacheStore.savePeakLevel(prebuilt)

        fixture.queue.enqueue(request)
        let summary = fixture.worker.processNextBatch(maxCount: 1)

        try require(summary.dequeuedCount == 1, "disk-hit worker did not dequeue one request")
        try require(summary.diskHitCount == 1, "worker did not resolve tile from disk")
        try require(summary.builtLevelCount == 0, "disk-hit worker unexpectedly rebuilt a peak level")
        try require(summary.committedCount == 1, "disk-hit worker did not commit tile")
        try require(
            fixture.tileStore.committedPeakTile(for: request.descriptor.address)?.bins.count == 4,
            "disk-hit committed tile was missing or had the wrong bin count"
        )
    }

    private static func verifyBuildMissCommitsAndCachesTile(rootDirectory: URL) throws {
        let fixture = try makeFixture(rootDirectory: rootDirectory)
        let request = tileRequest(for: fixture.source, tileIndex: 1)

        fixture.queue.enqueue(request)
        let summary = fixture.worker.processNextBatch(maxCount: 1)

        try require(summary.dequeuedCount == 1, "build-miss worker did not dequeue one request")
        try require(summary.diskHitCount == 0, "build-miss worker should not hit disk before building")
        try require(summary.builtLevelCount == 1, "build-miss worker did not build a peak level")
        try require(summary.committedCount == 1, "build-miss worker did not commit tile")
        try require(
            fixture.tileStore.committedPeakTile(for: request.descriptor.address)?.bins.count == 4,
            "build-miss committed tile was missing or had the wrong bin count"
        )

        let loadedManifest = try fixture.diskCacheStore.loadManifest(for: fixture.source.fingerprint)
        try require(loadedManifest?.levels.count == 1, "build-miss worker did not persist built level to disk")
    }

    private static func verifyRawSampleRequestCommitsTile(rootDirectory: URL) throws {
        let fixture = try makeFixture(rootDirectory: rootDirectory)
        let request = rawTileRequest(for: fixture.source, tileIndex: 0)

        fixture.queue.enqueue(request)
        let summary = fixture.worker.processNextBatch(maxCount: 1)

        try require(summary.dequeuedCount == 1, "raw worker did not dequeue one request")
        try require(summary.builtRawTileCount == 1, "raw worker did not build a raw tile")
        try require(summary.committedCount == 1, "raw worker did not commit tile")

        guard case let .rawSamples(tile)? = fixture.tileStore.payload(for: request.descriptor.address) else {
            throw SmokeError.failed("raw worker committed the wrong payload kind")
        }
        try require(tile.samplesByChannel.count == 1, "raw mono-mix tile should expose one channel")
        try require(tile.samplesByChannel.first?.count == 128, "raw tile had wrong sample count")
    }

    private static func verifyStaleCancellationDoesNotCommit(rootDirectory: URL) throws {
        let fixture = try makeFixture(rootDirectory: rootDirectory)
        let request = tileRequest(for: fixture.source, tileIndex: 1)

        fixture.queue.enqueue(request)
        let summary = fixture.worker.processNextBatch(maxCount: 1) { workItem in
            fixture.queue.removeAll(for: workItem.request.descriptor.address.sourceID)
        }

        try require(summary.dequeuedCount == 1, "stale worker did not dequeue one request")
        try require(summary.staleCount == 1, "stale worker did not report stale work")
        try require(summary.committedCount == 0, "stale worker should not commit cancelled tile")
        try require(
            fixture.tileStore.committedPeakTile(for: request.descriptor.address) == nil,
            "stale worker committed a tile after source cancellation"
        )
    }

    private static func verifyBatchLimits(rootDirectory: URL) throws {
        let fixture = try makeFixture(rootDirectory: rootDirectory)
        let requests = [
            tileRequest(for: fixture.source, tileIndex: 0),
            tileRequest(for: fixture.source, tileIndex: 1),
            tileRequest(for: fixture.source, tileIndex: 2),
        ]

        fixture.queue.enqueue(requests)
        let summary = fixture.worker.processNextBatch(maxCount: 2)

        try require(summary.dequeuedCount == 2, "worker did not honor max batch size")
        try require(summary.committedCount == 2, "worker did not commit the dequeued batch")
        try require(fixture.queue.snapshot().pendingCount == 1, "worker consumed more than the bounded batch")
    }

    private struct Fixture {
        let wavURL: URL
        let source: WaveformTileBuildSource
        let queue: WaveformTileRequestQueue
        let tileStore: WaveformTileStore
        let diskCacheStore: WaveformDiskCacheStore
        let worker: WaveformTileBuildWorker
    }

    private static func makeFixture(rootDirectory: URL) throws -> Fixture {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let wavURL = rootDirectory.appendingPathComponent("synthetic.wav")
        try writeSyntheticWAV(to: wavURL)

        let source = try WaveformTileBuildSource(wavURL: wavURL, channelMode: .monoMix)
        let queue = WaveformTileRequestQueue()
        let tileStore = WaveformTileStore()
        let diskCacheStore = WaveformDiskCacheStore(
            rootDirectory: rootDirectory.appendingPathComponent("cache", isDirectory: true)
        )
        let worker = WaveformTileBuildWorker(
            requestQueue: queue,
            tileStore: tileStore,
            diskCacheStore: diskCacheStore
        )
        worker.registerSource(source)
        return Fixture(
            wavURL: wavURL,
            source: source,
            queue: queue,
            tileStore: tileStore,
            diskCacheStore: diskCacheStore,
            worker: worker
        )
    }

    private static func tileRequest(
        for source: WaveformTileBuildSource,
        tileIndex: Int
    ) -> WaveformTileRequest {
        let framesPerTile: Int64 = 256
        let framesPerBin = 64
        let descriptor = WaveformTileDescriptor(
            address: WaveformTileAddress(
                sourceID: source.sourceID,
                kind: .peak,
                channelMode: source.channelMode,
                level: 6,
                tileIndex: tileIndex
            ),
            frameRange: WaveformFrameRange(
                startFrame: Int64(tileIndex) * framesPerTile,
                endFrame: min(Int64(tileIndex + 1) * framesPerTile, source.frameCount)
            ),
            framesPerBin: framesPerBin,
            expectedBinCount: 4
        )
        return WaveformTileRequest(
            descriptor: descriptor,
            purpose: tileIndex == 0 ? .visible : .nearPrefetch,
            distanceFromVisibleTiles: tileIndex,
            samplesPerPixel: 24
        )
    }

    private static func rawTileRequest(
        for source: WaveformTileBuildSource,
        tileIndex: Int
    ) -> WaveformTileRequest {
        let framesPerTile: Int64 = 128
        let descriptor = WaveformTileDescriptor(
            address: WaveformTileAddress(
                sourceID: source.sourceID,
                kind: .rawSamples,
                channelMode: source.channelMode,
                level: 0,
                tileIndex: tileIndex
            ),
            frameRange: WaveformFrameRange(
                startFrame: Int64(tileIndex) * framesPerTile,
                endFrame: min(Int64(tileIndex + 1) * framesPerTile, source.frameCount)
            ),
            framesPerBin: 1,
            expectedBinCount: 128
        )
        return WaveformTileRequest(
            descriptor: descriptor,
            purpose: .visible,
            distanceFromVisibleTiles: 0,
            samplesPerPixel: 0.75
        )
    }

    private static func writeSyntheticWAV(to url: URL) throws {
        let frameCount = 1_024
        let left = (0..<frameCount).map { frame -> Float in
            frame.isMultiple(of: 2) ? -0.80 : 0.80
        }
        let right = (0..<frameCount).map { frame -> Float in
            frame.isMultiple(of: 3) ? 0.35 : -0.35
        }
        let buffer = DecodedAudioBuffer(
            url: url,
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [left, right]
        )
        try WAVFileWriter.write(buffer, to: url)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw SmokeError.failed(message)
        }
    }
}
