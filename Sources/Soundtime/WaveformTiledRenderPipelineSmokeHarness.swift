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
        try verifyAsyncFrameRequestsWorkWithoutInlineBuild(rootDirectory: rootDirectory.appendingPathComponent("async", isDirectory: true))
        try verifyLastGoodHoldsDuringPreferredTileMiss(rootDirectory: rootDirectory.appendingPathComponent("hold", isDirectory: true))
        try verifySegmentRemappedFrameBuildsSourceTiles(rootDirectory: rootDirectory.appendingPathComponent("segments", isDirectory: true))
        try verifyDrawBatchPlannerClipsTilesThroughSegments()
        try verifyDrawBatchPlannerIncludesPromotionLayers()

        let checks = [
            "peak viewport builds uploads and selects",
            "raw ultra-zoom viewport builds uploads and selects",
            "missing tile skips instead of CPU fallback",
            "async frame requests work without inline build",
            "last-good holds during preferred tile miss",
            "segment-remapped frame builds source tiles",
            "draw batch planner clips tiles through segments",
            "draw batch planner includes promotion layers",
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

    private static func verifyAsyncFrameRequestsWorkWithoutInlineBuild(rootDirectory: URL) throws {
        let fixture = try makeFixture(rootDirectory: rootDirectory)
        let viewport = WaveformTileSchedulerViewport(
            startTime: 0,
            endTime: fixture.source.duration,
            widthPixels: 32
        )
        let workCompletionLock = NSLock()
        var workCompletionCount = 0
        let onWorkCompleted = {
            workCompletionLock.lock()
            workCompletionCount += 1
            workCompletionLock.unlock()
        }

        let firstFrame = fixture.pipeline.prepareResidentFrame(
            source: fixture.source.metadata,
            viewport: viewport,
            timestamp: 0,
            schedulerConfig: schedulerConfig(),
            buildBatchLimit: 4,
            uploadBudget: uploadBudget(),
            upload: uploadResource,
            onWorkCompleted: onWorkCompleted
        )

        try require(firstFrame.buildSummary.dequeuedCount == 0, "async render frame built tiles inline")
        try require(firstFrame.uploadSummary.uploadedCount == 0, "async render frame uploaded tiles inline")
        try require(firstFrame.renderSelection.requestedCount > 0, "async render frame did not request visible tiles")

        var resolvedCount = 0
        var uploadedCount = 0
        var selectedResidentCount = firstFrame.renderSelection.selectedCount
        for attempt in 0..<80 where selectedResidentCount == 0 {
            Thread.sleep(forTimeInterval: 0.025)
            let completedWork = fixture.pipeline.drainCompletedAsyncWork()
            resolvedCount += completedWork.buildSummary.resolvedCount
            uploadedCount += completedWork.uploadSummary.uploadedCount
            let nextFrame = fixture.pipeline.prepareResidentFrame(
                source: fixture.source.metadata,
                viewport: viewport,
                timestamp: Double(attempt + 1) * 0.025,
                schedulerConfig: schedulerConfig(),
                buildBatchLimit: 4,
                uploadBudget: uploadBudget(),
                upload: uploadResource,
                onWorkCompleted: onWorkCompleted
            )
            selectedResidentCount = nextFrame.renderSelection.selectedCount
        }

        let finalCompletedWork = fixture.pipeline.drainCompletedAsyncWork()
        resolvedCount += finalCompletedWork.buildSummary.resolvedCount
        uploadedCount += finalCompletedWork.uploadSummary.uploadedCount

        workCompletionLock.lock()
        let completions = workCompletionCount
        workCompletionLock.unlock()

        try require(resolvedCount > 0, "async worker did not resolve requested tiles")
        try require(uploadedCount > 0, "async worker did not upload requested tiles")
        try require(selectedResidentCount > 0, "async render frame did not select resident tiles after worker completed")
        try require(completions > 0, "async worker did not signal completion")
    }

    private static func verifyLastGoodHoldsDuringPreferredTileMiss(rootDirectory: URL) throws {
        let fixture = try makeFixture(rootDirectory: rootDirectory)
        let peakViewport = WaveformTileSchedulerViewport(
            startTime: 0,
            endTime: fixture.source.duration,
            widthPixels: 32
        )
        let peakFrame = fixture.pipeline.prepareFrame(
            source: fixture.source.metadata,
            viewport: peakViewport,
            timestamp: 0,
            schedulerConfig: schedulerConfig(),
            buildBatchLimit: 8,
            uploadBudget: uploadBudget(),
            upload: uploadResource
        )

        try require(peakFrame.renderSelection.exactResidentCount > 0, "setup did not make peak tiles resident")

        let rawWindowDuration = 128 / fixture.source.sampleRate
        let rawViewport = WaveformTileSchedulerViewport(
            startTime: 0,
            endTime: rawWindowDuration,
            widthPixels: 512
        )
        let rawFrame = fixture.pipeline.prepareFrame(
            source: fixture.source.metadata,
            viewport: rawViewport,
            timestamp: 0.1,
            schedulerConfig: schedulerConfig(),
            buildBatchLimit: 0,
            uploadBudget: uploadBudget(),
            upload: uploadResource
        )

        try require(rawFrame.buildSummary.dequeuedCount == 0, "hold test should not build raw preferred tile inline")
        try require(rawFrame.uploadSummary.uploadedCount == 0, "hold test should not upload raw preferred tile inline")
        try require(rawFrame.renderSelection.lastGoodResidentCount > 0, "raw preferred miss did not hold prior peak tile")
        try require(rawFrame.renderSelection.skippedCount < rawFrame.renderSelection.requestedCount, "last-good hold did not reduce skipped tiles")
    }

    private static func verifySegmentRemappedFrameBuildsSourceTiles(rootDirectory: URL) throws {
        let fixture = try makeFixture(rootDirectory: rootDirectory)
        let frame = fixture.pipeline.prepareFrame(
            source: fixture.source.metadata,
            viewport: WaveformTileSchedulerViewport(
                startTime: 0.02,
                endTime: 0.04,
                widthPixels: 200
            ),
            segments: [
                WaveformTileSchedulerSegment(
                    outputStartTime: 0,
                    outputEndTime: 0.1,
                    sourceStartTime: 0.05,
                    sourceEndTime: 0.15
                ),
            ],
            timestamp: 0,
            schedulerConfig: schedulerConfig(),
            buildBatchLimit: 8,
            uploadBudget: uploadBudget(),
            upload: uploadResource
        )
        let visibleTileIndexes = frame.requestedTiles
            .filter { $0.purpose == .visible }
            .map { $0.descriptor.address.tileIndex }

        try require(
            visibleTileIndexes == [3, 4],
            "segment-remapped pipeline frame requested wrong source tiles: \(visibleTileIndexes)"
        )
        try require(frame.buildSummary.resolvedCount > 0, "segment-remapped frame did not resolve any source tiles")
        try require(frame.uploadSummary.uploadedCount > 0, "segment-remapped frame did not upload any source tiles")
        try require(frame.renderSelection.exactResidentCount > 0, "segment-remapped frame did not select resident source tiles")
    }

    private static func verifyDrawBatchPlannerClipsTilesThroughSegments() throws {
        let source = drawBatchSourceMetadata()
        let descriptor = drawBatchDescriptor(
            source: source,
            startFrame: 48_000,
            endFrame: 96_000,
            tileIndex: 1
        )
        let plan = WaveformTileDrawBatchPlanner.plan(
            trackID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            trackIndex: 2,
            laneFrame: TimelineTrackLaneFrame(top: 0.2, bottom: 0.4),
            source: source,
            segments: [
                WaveformTileSchedulerSegment(
                    outputStartTime: 20,
                    outputEndTime: 30,
                    sourceStartTime: 0,
                    sourceEndTime: 10
                ),
            ],
            promotionPlan: WaveformTilePromotionPlan(
                tiles: [
                    WaveformPromotedTile(
                        requestedDescriptor: descriptor,
                        current: WaveformTilePromotionLayer(
                            descriptor: descriptor,
                            resource: WaveformTileGPUResource(
                                id: WaveformTileGPUResourceID(rawValue: "batch-current"),
                                byteCount: 512
                            ),
                            alpha: 1
                        ),
                        previous: nil,
                        progress: 1,
                        isTransitioning: false
                    ),
                ],
                promotedCount: 0,
                transitioningCount: 0
            )
        )

        try require(plan.batchCount == 1, "draw batch planner should produce one compatible batch")
        try require(plan.instanceCount == 1, "draw batch planner should produce one clipped instance")
        guard let instance = plan.batches.first?.instances.first else {
            throw SmokeError.failed("draw batch planner produced no instance")
        }
        try require(abs(instance.outputStartTime - 21) < 0.000_1, "source tile did not map to output start")
        try require(abs(instance.outputEndTime - 22) < 0.000_1, "source tile did not map to output end")
        try require(abs(instance.sourceStartTime - 1) < 0.000_1, "source clip start was wrong")
        try require(abs(instance.sourceEndTime - 2) < 0.000_1, "source clip end was wrong")
        try require(instance.trackIndex == 2, "track index was not carried into draw instance")
    }

    private static func verifyDrawBatchPlannerIncludesPromotionLayers() throws {
        let source = drawBatchSourceMetadata()
        let currentDescriptor = drawBatchDescriptor(
            source: source,
            startFrame: 48_000,
            endFrame: 96_000,
            tileIndex: 1
        )
        let previousDescriptor = drawBatchDescriptor(
            source: source,
            startFrame: 0,
            endFrame: 240_000,
            tileIndex: 0,
            level: 4,
            framesPerBin: 16
        )
        let plan = WaveformTileDrawBatchPlanner.plan(
            trackID: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            trackIndex: 0,
            laneFrame: TimelineTrackLaneFrame(top: 0, bottom: 0.25),
            source: source,
            segments: [
                WaveformTileSchedulerSegment(
                    outputStartTime: 0,
                    outputEndTime: 10,
                    sourceStartTime: 0,
                    sourceEndTime: 10
                ),
            ],
            promotionPlan: WaveformTilePromotionPlan(
                tiles: [
                    WaveformPromotedTile(
                        requestedDescriptor: currentDescriptor,
                        current: WaveformTilePromotionLayer(
                            descriptor: currentDescriptor,
                            resource: WaveformTileGPUResource(
                                id: WaveformTileGPUResourceID(rawValue: "batch-promotion-current"),
                                byteCount: 512
                            ),
                            alpha: 0.75
                        ),
                        previous: WaveformTilePromotionLayer(
                            descriptor: previousDescriptor,
                            resource: WaveformTileGPUResource(
                                id: WaveformTileGPUResourceID(rawValue: "batch-promotion-previous"),
                                byteCount: 1_024
                            ),
                            alpha: 0.25
                        ),
                        progress: 0.75,
                        isTransitioning: true
                    ),
                ],
                promotedCount: 1,
                transitioningCount: 1
            )
        )
        let roles = Set(plan.batches.flatMap { batch in
            batch.instances.map(\.role)
        })

        try require(plan.batchCount == 1, "promotion layers with same kind/channel should stay in one batch")
        try require(plan.instanceCount == 2, "promotion crossfade should produce current and previous instances")
        try require(plan.resourceCount == 2, "promotion crossfade should reference both resources")
        try require(roles == [.current, .previous], "promotion roles were not preserved: \(roles)")
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

    private static func drawBatchSourceMetadata() -> WaveformTileSourceMetadata {
        WaveformTileSourceMetadata(
            sourceID: WaveformSourceID(rawValue: "draw-batch-source"),
            duration: 10,
            frameCount: 480_000,
            sampleRate: 48_000,
            channelMode: .monoMix
        )
    }

    private static func drawBatchDescriptor(
        source: WaveformTileSourceMetadata,
        startFrame: Int64,
        endFrame: Int64,
        tileIndex: Int,
        level: Int = 0,
        framesPerBin: Int = 1
    ) -> WaveformTileDescriptor {
        let frameRange = WaveformFrameRange(startFrame: startFrame, endFrame: endFrame)
        return WaveformTileDescriptor(
            address: WaveformTileAddress(
                sourceID: source.sourceID,
                editGraphID: source.editGraphID,
                kind: .peak,
                channelMode: source.channelMode,
                level: level,
                tileIndex: tileIndex
            ),
            frameRange: frameRange,
            framesPerBin: framesPerBin,
            expectedBinCount: Int(frameRange.frameCount / Int64(max(framesPerBin, 1)))
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
