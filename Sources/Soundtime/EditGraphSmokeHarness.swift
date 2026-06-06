import Foundation

enum EditGraphSmokeHarness {
    enum SmokeError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let sampleRate = 48_000.0
        let sourceFrameCount = Int(sampleRate) * 60 * 60 * 2
        let sourceURL = URL(fileURLWithPath: "/tmp/SoundtimeEditGraphSmoke.wav")
        let fileInfo = WAVFileInfo(
            url: sourceURL,
            formatTag: 1,
            channelCount: 2,
            sampleRate: sampleRate,
            blockAlign: 4,
            bitsPerSample: 16,
            dataRange: 44..<(44 + sourceFrameCount * 4)
        )

        var timeline = AudioFileEditTimeline(fileInfo: fileInfo)
        let operationCount = arguments.contains("--edit-graph-smoke-full") ? 1_500 : 640
        let startTime = DispatchTime.now().uptimeNanoseconds
        var touchedFrameCount = 0

        for index in 0..<operationCount {
            let startProgress = Double((index * 7_919) % 850_000) / 1_000_000.0
            let durationProgress = 0.000_06 + Double(index % 9) * 0.000_012
            let selection = TimelineSelection(
                startProgress: startProgress,
                endProgress: min(startProgress + durationProgress, 0.995)
            )

            switch index % 5 {
            case 0:
                touchedFrameCount += timeline.delete(selection)
            case 1:
                touchedFrameCount += timeline.applyGain(0.72, to: selection)
            case 2:
                touchedFrameCount += timeline.applyGain(1.18, to: selection)
            case 3:
                touchedFrameCount += timeline.applyFade(.fadeIn, to: selection)
            default:
                touchedFrameCount += timeline.applyFade(.fadeOut, to: selection)
            }
        }

        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000
        let state = try requireValue(timeline.persistentState, "edit graph did not persist")
        try require(touchedFrameCount > 0, "edit graph operations touched no frames")
        try require(timeline.frameCount < sourceFrameCount, "delete operations did not shorten the timeline")
        try require(state.segments.count < operationCount * 3, "edit graph segment count exploded: \(state.segments.count)")
        try require(
            elapsedMilliseconds < 1_500,
            String(format: "edit graph operations were too slow: %.2fms", elapsedMilliseconds)
        )

        print(
            String(
                format: "Soundtime edit graph smoke passed: %d ops, %d segments, %.2fms",
                operationCount,
                state.segments.count,
                elapsedMilliseconds
            )
        )
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SmokeError.failed(message)
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw SmokeError.failed(message)
        }

        return value
    }
}

enum EditPreviewSmokeHarness {
    enum SmokeError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let sampleRate = 48_000.0
        let sourceFrameCount = Int(sampleRate) * 60 * 60 * 2
        let sourceURL = URL(fileURLWithPath: "/tmp/SoundtimeEditPreviewSmoke.wav")
        let fileInfo = WAVFileInfo(
            url: sourceURL,
            formatTag: 1,
            channelCount: 2,
            sampleRate: sampleRate,
            blockAlign: 4,
            bitsPerSample: 16,
            dataRange: 44..<(44 + sourceFrameCount * 4)
        )
        let previewBinCount = arguments.contains("--edit-preview-smoke-full") ? 65_536 : 32_768
        let operationCount = arguments.contains("--edit-preview-smoke-full") ? 260 : 96
        let sourceOverview = makeSourceOverview(
            duration: Double(sourceFrameCount) / sampleRate,
            binCount: previewBinCount
        )

        var timeline = AudioFileEditTimeline(fileInfo: fileInfo)
        var latestOverview = sourceOverview
        var maximumPreviewMilliseconds = 0.0
        let startTime = DispatchTime.now().uptimeNanoseconds

        for index in 0..<operationCount {
            let startProgress = Double((index * 37_219) % 900_000) / 1_000_000.0
            let durationProgress = 0.000_08 + Double(index % 11) * 0.000_016
            let selection = TimelineSelection(
                startProgress: startProgress,
                endProgress: min(startProgress + durationProgress, 0.995)
            )

            switch index % 4 {
            case 0:
                _ = timeline.delete(selection)
            case 1:
                _ = timeline.applyGain(0.64, to: selection)
            case 2:
                _ = timeline.applyGain(1.22, to: selection)
            default:
                let fadeDirection: AudioEditTimeline.FadeDirection = index.isMultiple(of: 2) ? .fadeIn : .fadeOut
                _ = timeline.applyFade(fadeDirection, to: selection)
            }

            let previewStartTime = DispatchTime.now().uptimeNanoseconds
            latestOverview = timeline.waveformOverview(from: sourceOverview)
            let previewMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - previewStartTime) / 1_000_000
            maximumPreviewMilliseconds = max(maximumPreviewMilliseconds, previewMilliseconds)
        }

        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000
        let state = try requireValue(timeline.persistentState, "edit graph did not persist")
        try require(!latestOverview.bins.isEmpty, "optimistic preview became empty")
        try require(latestOverview.duration > 0, "optimistic preview duration became invalid")
        try require(state.segments.count < operationCount * 3, "edit preview segment count exploded: \(state.segments.count)")
        try require(
            maximumPreviewMilliseconds < 24,
            String(format: "single optimistic preview was too slow: %.2fms", maximumPreviewMilliseconds)
        )
        try require(
            elapsedMilliseconds < 2_000,
            String(format: "edit previews were too slow: %.2fms", elapsedMilliseconds)
        )

        print(
            String(
                format: "Soundtime edit preview smoke passed: %d ops, %d bins, %d segments, %.2fms max preview, %.2fms total",
                operationCount,
                previewBinCount,
                state.segments.count,
                maximumPreviewMilliseconds,
                elapsedMilliseconds
            )
        )
    }

    private static func makeSourceOverview(duration: TimeInterval, binCount: Int) -> WaveformOverview {
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount)

        for index in 0..<binCount {
            let t = Float(index) / Float(max(binCount - 1, 1))
            let envelope = 0.18 + 0.44 * abs(sin(t * .pi * 37.0))
            let phrase = 0.55 + 0.35 * sin(t * .pi * 5.7 + 0.2)
            let peak = min(max(envelope * phrase, 0.02), 0.98)
            bins.append(
                WaveformOverview.Bin(
                    minimumSample: -peak * (0.72 + 0.20 * sin(t * .pi * 19.0)),
                    maximumSample: peak,
                    rmsSample: peak * 0.58,
                    lowEnergy: 0.26 + 0.18 * sin(t * .pi * 3.0),
                    midEnergy: 0.34 + 0.14 * abs(sin(t * .pi * 29.0)),
                    highEnergy: 0.22 + 0.18 * abs(sin(t * .pi * 83.0))
                )
            )
        }

        return WaveformOverview(duration: duration, bins: bins)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SmokeError.failed(message)
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw SmokeError.failed(message)
        }

        return value
    }
}
