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
