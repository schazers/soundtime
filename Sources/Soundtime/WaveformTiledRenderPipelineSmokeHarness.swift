import Foundation

enum WaveformTiledRenderPipelineSmokeHarness {
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
            .appendingPathComponent("soundtime-tiled-render-pipeline-smoke-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        try verifyPeakViewportBuildsUploadsAndSelects(rootDirectory: rootDirectory.appendingPathComponent("peak", isDirectory: true))
        try verifyRawUltraZoomViewportBuildsUploadsAndSelects(rootDirectory: rootDirectory.appendingPathComponent("raw", isDirectory: true))
        try verifyMissingTileSkipsInsteadOfCPUFallback(rootDirectory: rootDirectory.appendingPathComponent("missing", isDirectory: true))

        let checks = [
            "peak viewport builds uploads and selects",
            "raw ultra-zoom viewport builds uploads and selects",
            "missing tile skips instead of CPU fallback",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "waveform-tiled-render-pipeline-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: ["rendererIntegration": "feature-flagged"],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }
        print("Soundtime waveform tiled render pipeline smoke passed")
    }

    private static func verifyPeakViewportBuildsUploadsAndSelects(rootDirectory: URL) throws {
        let fixture = try makeFixture(rootDirectory: rootDirectory)
        let viewport = WaveformTileSchedulerViewport(
            startTime: 0,
            endTime: fixture.source.duration,
            widthPixels: 32
        )
        let frame = fixture.pipeline.prepareFrame(
            source: fixture.source.metadata,
            viewport: viewport,
            timestamp: 0,
            schedulerConfig: schedulerConfig(),
            buildBatchLimit: 8,
            uploadBudget: uploadBudget(),
            upload: uploadResource
        )

        try require(frame.requestedTiles.contains { $0.descriptor.address.kind == .peak }, "peak viewport did not request peak tiles")
        try require(frame.buildSummary.builtLevelCount > 0, "peak viewport did not build a peak level")
        try require(frame.uploadSummary.uploadedCount > 0, "peak viewport did not upload any tiles")
        try require(frame.renderSelection.exactResidentCount > 0, "peak viewport did not select resident tiles")
        try require(frame.promotionPlan.drawLayerCount > 0, "peak viewport produced no promotion layers")
    }

    private static func verifyRawUltraZoomViewportBuildsUploadsAndSelects(rootDirectory: URL) throws {
        let fixture = try makeFixture(rootDirectory: rootDirectory)
        let rawWindowDuration = 128 / fixture.source.sampleRate
        let viewport = WaveformTileSchedulerViewport(
            startTime: 0,
            endTime: rawWindowDuration,
            widthPixels: 512
        )
        let frame = fixture.pipeline.prepareFrame(
            source: fixture.source.metadata,
            viewport: viewport,
            timestamp: 0,
            schedulerConfig: schedulerConfig(),
            buildBatchLimit: 8,
            uploadBudget: uploadBudget(),
            upload: uploadResource
        )

        try require(frame.requestedTiles.contains { $0.descriptor.address.kind == .rawSamples }, "ultra-zoom viewport did not request raw tiles")
        try require(frame.buildSummary.builtRawTileCount > 0, "ultra-zoom viewport did not build raw tiles")
        try require(frame.uploadSummary.uploadedCount > 0, "ultra-zoom viewport did not upload raw tiles")
        try require(frame.renderSelection.exactResidentCount > 0, "ultra-zoom viewport did not select exact resident raw tiles")
        try require(frame.promotionPlan.drawLayerCount > 0, "ultra-zoom viewport produced no promotion layers")
    }

    private static func verifyMissingTileSkipsInsteadOfCPUFallback(rootDirectory: URL) throws {
        let fixture = try makeFixture(rootDirectory: rootDirectory)
        let viewport = WaveformTileSchedulerViewport(
            startTime: 0,
            endTime: fixture.source.duration,
            widthPixels: 32
        )
        let frame = fixture.pipeline.prepareFrame(
            source: fixture.source.metadata,
            viewport: viewport,
            timestamp: 0,
            schedulerConfig: schedulerConfig(),
            buildBatchLimit: 0,
            uploadBudget: uploadBudget(),
            upload: uploadResource
        )

        try require(frame.buildSummary.dequeuedCount == 0, "missing-tile frame should not build synchronously")
        try require(frame.uploadSummary.uploadedCount == 0, "missing-tile frame should not upload absent tiles")
        try require(frame.renderSelection.selectedCount == 0, "missing-tile frame should not select nonresident tiles")
        try require(frame.renderSelection.skippedCount == frame.renderSelection.requestedCount, "missing-tile frame should skip requested tiles")
    }

    private struct Fixture {
        let wavURL: URL
        let source: WaveformTileBuildSource
        let pipeline: WaveformTiledRenderPipeline
    }

    private static func makeFixture(rootDirectory: URL) throws -> Fixture {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let wavURL = rootDirectory.appendingPathComponent("synthetic.wav")
        try writeSyntheticWAV(to: wavURL)

        let source = try WaveformTileBuildSource(wavURL: wavURL, channelMode: .monoMix)
        let pipeline = WaveformTiledRenderPipeline(
            diskCacheStore: WaveformDiskCacheStore(rootDirectory: rootDirectory.appendingPathComponent("cache", isDirectory: true)),
            maximumResidentBytes: 8 * 1_024 * 1_024
        )
        pipeline.registerSources([source])
        return Fixture(wavURL: wavURL, source: source, pipeline: pipeline)
    }

    private static func schedulerConfig() -> WaveformTileSchedulerConfig {
        WaveformTileSchedulerConfig(
            peakFramesPerTile: 1_024,
            rawFramesPerTile: 256,
            minimumPeakFramesPerBin: 8,
            maximumPeakFramesPerBin: 512,
            targetPeakBinsPerPixel: 0.75,
            rawSamplesPerPixelThreshold: 2,
            nearPrefetchTileRadius: 0,
            predictedPrefetchTileRadius: 0,
            backgroundTileStride: 8,
            maximumBackgroundRequests: 0
        )
    }

    private static func uploadBudget() -> WaveformTileUploadBudget {
        WaveformTileUploadBudget(
            maximumBytesPerBatch: 2 * 1_024 * 1_024,
            maximumTilesPerBatch: 16
        )
    }

    private static func uploadResource(_ payload: WaveformTilePayload) throws -> WaveformTileGPUResource {
        let address = payload.descriptor.address
        return WaveformTileGPUResource(
            id: WaveformTileGPUResourceID(rawValue: "smoke-\(address.sourceID.rawValue)-\(address.kind.rawValue)-\(address.level)-\(address.tileIndex)"),
            byteCount: WaveformTileUploadCoordinator.estimatedUploadBytes(for: payload)
        )
    }

    private static func writeSyntheticWAV(to url: URL) throws {
        let frameCount = 8_192
        let left = (0..<frameCount).map { frame -> Float in
            let phase = Double(frame) / 18
            return Float(sin(phase) * 0.85)
        }
        let right = (0..<frameCount).map { frame -> Float in
            let phase = Double(frame) / 29
            return Float(cos(phase) * 0.55)
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
