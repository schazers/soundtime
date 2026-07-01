import Foundation

enum WaveformTileSchedulerSmokeHarness {
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

        try verifyVisibleTilesWinPriority()
        try verifyNearAndPredictedPrefetchOrdering()
        try verifyRawSampleSchedulingAtExtremeZoom()
        try verifyTimelineViewportConversion()
        try verifySourceBoundsClamping()
        try verifySegmentRemapsVisibleViewportToSourceTiles()
        try verifyRippleDeleteSegmentsRequestShiftedSourceTiles()

        let checks = [
            "visible tile priority",
            "near and predicted prefetch ordering",
            "raw sample scheduling at extreme zoom",
            "timeline viewport conversion",
            "source bounds clamping",
            "segment remaps visible viewport to source tiles",
            "ripple delete segments request shifted source tiles",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "waveform-tile-scheduler-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: ["rendererIntegration": "disabled"],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }
        print("Soundtime waveform tile scheduler smoke passed")
    }

    private static func verifyVisibleTilesWinPriority() throws {
        let requests = scheduledRequests()
        let visible = requests.filter { $0.purpose == .visible }

        try require(!visible.isEmpty, "scheduler did not create visible requests")
        try require(
            requests.prefix(visible.count).allSatisfy { $0.purpose == .visible },
            "visible requests were not sorted before prefetch/background requests"
        )
        try require(
            visible.map { $0.descriptor.address.tileIndex } == Array(100...104),
            "visible tile span did not cover expected viewport tiles: \(visible.map { $0.descriptor.address.tileIndex })"
        )
        try require(
            visible.allSatisfy { $0.descriptor.address.kind == .peak },
            "normal zoom should schedule peak tiles"
        )
        try require(
            visible.allSatisfy { $0.descriptor.framesPerBin == 32 },
            "normal zoom picked unexpected framesPerBin: \(visible.map { $0.descriptor.framesPerBin })"
        )
        try require(
            visible.first?.descriptor.binRange == WaveformBinRange(startBin: 15_000, endBin: 15_150),
            "visible tile did not expose expected global bin range: \(String(describing: visible.first?.descriptor.binRange))"
        )
    }

    private static func verifyNearAndPredictedPrefetchOrdering() throws {
        let requests = scheduledRequests()
        let nearTileIndexes = Set(
            requests
                .filter { $0.purpose == .nearPrefetch }
                .map { $0.descriptor.address.tileIndex }
        )
        let predictedTileIndexes = Set(
            requests
                .filter { $0.purpose == .predictedPrefetch }
                .map { $0.descriptor.address.tileIndex }
        )

        try require(
            nearTileIndexes.isSuperset(of: [98, 99, 105, 106]),
            "near prefetch did not include tiles adjacent to the visible span: \(nearTileIndexes.sorted())"
        )
        try require(
            predictedTileIndexes.isSuperset(of: [149, 150, 151, 152, 153, 154, 155]),
            "predicted prefetch did not include predicted viewport tiles: \(predictedTileIndexes.sorted())"
        )

        let nearIndex = requests.firstIndex { $0.purpose == .nearPrefetch }
        let predictedIndex = requests.firstIndex { $0.purpose == .predictedPrefetch }
        let backgroundIndex = requests.firstIndex { $0.purpose == .background }
        try require(nearIndex != nil, "near prefetch requests were missing")
        try require(predictedIndex != nil, "predicted prefetch requests were missing")
        try require(backgroundIndex != nil, "background requests were missing")
        try require(
            nearIndex! < predictedIndex! && predictedIndex! < backgroundIndex!,
            "prefetch/background priority order was wrong"
        )
    }

    private static func verifyRawSampleSchedulingAtExtremeZoom() throws {
        let source = sourceMetadata()
        let viewport = WaveformTileSchedulerViewport(
            startTime: 10,
            endTime: 10.001,
            widthPixels: 1_000
        )
        let requests = WaveformTileScheduler.requests(
            for: source,
            viewport: viewport,
            config: schedulerConfig()
        )

        try require(!requests.isEmpty, "extreme zoom produced no requests")
        try require(
            requests.allSatisfy { $0.descriptor.address.kind == .rawSamples },
            "extreme zoom should schedule raw sample tiles only"
        )
        try require(
            requests.allSatisfy { $0.purpose != .background },
            "extreme zoom should not ask for full-file raw background work"
        )
        let visible = requests.filter { $0.purpose == .visible }
        try require(
            visible.allSatisfy { $0.descriptor.binRange.binCount == $0.descriptor.frameRange.frameCount },
            "raw-sample tiles should expose one bin per source frame"
        )
    }

    private static func verifyTimelineViewportConversion() throws {
        let viewport = WaveformTileSchedulerViewport(
            timelineViewport: TimelineViewport(startProgress: 0.25, durationProgress: 0.125),
            duration: 120,
            widthPixels: 800
        )

        try require(abs(viewport.startTime - 30) < 0.000_1, "timeline viewport start did not convert to seconds")
        try require(abs(viewport.endTime - 45) < 0.000_1, "timeline viewport end did not convert to seconds")
        try require(abs(viewport.samplesPerPixel(sampleRate: 48_000) - 900) < 0.000_1, "samplesPerPixel conversion was wrong")
    }

    private static func verifySourceBoundsClamping() throws {
        let source = sourceMetadata()
        let viewport = WaveformTileSchedulerViewport(
            startTime: 119.9,
            endTime: 122,
            widthPixels: 700
        )
        let requests = WaveformTileScheduler.requests(
            for: source,
            viewport: viewport,
            config: schedulerConfig()
        )

        try require(!requests.isEmpty, "end-of-file viewport produced no requests")
        for request in requests {
            try require(request.descriptor.frameRange.startFrame >= 0, "request started before frame zero")
            try require(
                request.descriptor.frameRange.endFrame <= source.frameCount,
                "request exceeded source frame count: \(request.descriptor.frameRange.endFrame) > \(source.frameCount)"
            )
        }
        try require(
            requests.contains { $0.purpose == .visible && $0.descriptor.frameRange.contains(frame: source.frameCount - 1) },
            "visible end-of-file request did not include final source frame"
        )
    }

    private static func verifySegmentRemapsVisibleViewportToSourceTiles() throws {
        let source = sourceMetadata()
        let requests = WaveformTileScheduler.requests(
            for: source,
            viewport: WaveformTileSchedulerViewport(
                startTime: 12,
                endTime: 12.5,
                widthPixels: 1_000
            ),
            segments: [
                WaveformTileSchedulerSegment(
                    outputStartTime: 10,
                    outputEndTime: 20,
                    sourceStartTime: 40,
                    sourceEndTime: 50
                ),
            ],
            config: schedulerConfig()
        )
        let visibleTileIndexes = requests
            .filter { $0.purpose == .visible }
            .map { $0.descriptor.address.tileIndex }

        try require(
            visibleTileIndexes == Array(420...424),
            "segment request did not map output viewport onto source tiles: \(visibleTileIndexes)"
        )
        try require(
            !visibleTileIndexes.contains(120),
            "segment request incorrectly used output-time tile coordinates"
        )
    }

    private static func verifyRippleDeleteSegmentsRequestShiftedSourceTiles() throws {
        let source = sourceMetadata()
        let requests = WaveformTileScheduler.requests(
            for: source,
            viewport: WaveformTileSchedulerViewport(
                startTime: 10.25,
                endTime: 10.75,
                widthPixels: 1_000
            ),
            segments: [
                WaveformTileSchedulerSegment(
                    outputStartTime: 0,
                    outputEndTime: 10,
                    sourceStartTime: 0,
                    sourceEndTime: 10
                ),
                WaveformTileSchedulerSegment(
                    outputStartTime: 10,
                    outputEndTime: 20,
                    sourceStartTime: 12,
                    sourceEndTime: 22
                ),
            ],
            config: schedulerConfig()
        )
        let visibleTileIndexes = requests
            .filter { $0.purpose == .visible }
            .map { $0.descriptor.address.tileIndex }

        try require(
            visibleTileIndexes == Array(122...127),
            "ripple delete segment should request post-delete source tiles, got \(visibleTileIndexes)"
        )
        try require(
            !visibleTileIndexes.contains(102),
            "ripple delete segment incorrectly requested output-time tile coordinates"
        )
    }

    private static func scheduledRequests() -> [WaveformTileRequest] {
        WaveformTileScheduler.requests(
            for: sourceMetadata(),
            viewport: WaveformTileSchedulerViewport(
                startTime: 10,
                endTime: 10.5,
                widthPixels: 1_000
            ),
            predictedViewport: WaveformTileSchedulerViewport(
                startTime: 15,
                endTime: 15.5,
                widthPixels: 1_000
            ),
            config: schedulerConfig()
        )
    }

    private static func sourceMetadata() -> WaveformTileSourceMetadata {
        WaveformTileSourceMetadata(
            sourceID: WaveformSourceID(rawValue: "scheduler-smoke-source"),
            editGraphID: "edit-graph-a",
            duration: 120,
            frameCount: 5_760_000,
            sampleRate: 48_000,
            channelMode: .stereoPair
        )
    }

    private static func schedulerConfig() -> WaveformTileSchedulerConfig {
        WaveformTileSchedulerConfig(
            peakFramesPerTile: 4_800,
            rawFramesPerTile: 512,
            minimumPeakFramesPerBin: 8,
            maximumPeakFramesPerBin: 4_096,
            targetPeakBinsPerPixel: 0.75,
            rawSamplesPerPixelThreshold: 2,
            nearPrefetchTileRadius: 2,
            predictedPrefetchTileRadius: 1,
            backgroundTileStride: 100,
            maximumBackgroundRequests: 8
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw SmokeError.failed(message)
        }
    }
}
