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

        let checks = [
            "visible tile priority",
            "near and predicted prefetch ordering",
            "raw sample scheduling at extreme zoom",
            "timeline viewport conversion",
            "source bounds clamping",
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
