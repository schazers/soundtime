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
        try runFileClipPasteSmoke(fileInfo: fileInfo)

        print(
            String(
                format: "Soundtime edit graph smoke passed: %d ops, %d segments, %.2fms",
                operationCount,
                state.segments.count,
                elapsedMilliseconds
            )
        )
    }

    private static func runFileClipPasteSmoke(fileInfo: WAVFileInfo) throws {
        var timeline = AudioFileEditTimeline(fileInfo: fileInfo)
        let gainedSelection = TimelineSelection(startProgress: 0.10, endProgress: 0.18)
        let copiedSelection = TimelineSelection(startProgress: 0.12, endProgress: 0.145)
        let insertionSelection = TimelineSelection(startProgress: 0.62, endProgress: 0.62)

        let gainedFrameCount = timeline.applyGain(0.42, to: gainedSelection)
        try require(gainedFrameCount > 0, "file clip smoke gain touched no frames")

        let frameCountBeforePaste = timeline.frameCount
        let clip = try requireValue(timeline.clip(for: copiedSelection), "file clip smoke could not copy clip")
        try require(clip.frameCount > 0, "file clip smoke copied an empty clip")
        try require(
            clip.segments.contains { segment in
                segment.gainStart < 0.99 || segment.gainEnd < 0.99
            },
            "file clip smoke did not preserve selected gain"
        )

        let insertedFrameCount = try requireValue(
            timeline.replace(insertionSelection, with: clip),
            "file clip smoke could not paste clip"
        )
        try require(insertedFrameCount == clip.frameCount, "file clip smoke inserted an unexpected frame count")
        try require(
            timeline.frameCount == frameCountBeforePaste + clip.frameCount,
            "file clip smoke did not splice the pasted clip into the edit graph"
        )

        let state = try requireValue(timeline.persistentState, "file clip smoke did not persist")
        let restoredTimeline = try requireValue(
            AudioFileEditTimeline(persistentState: state),
            "file clip smoke could not restore persisted edit graph"
        )
        try require(
            restoredTimeline.frameCount == timeline.frameCount,
            "file clip smoke persisted the wrong frame count"
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
        var previewDurations: [Double] = []
        previewDurations.reserveCapacity(operationCount)
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
            previewDurations.append(previewMilliseconds)
            maximumPreviewMilliseconds = max(maximumPreviewMilliseconds, previewMilliseconds)
        }

        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000
        let p95PreviewMilliseconds = percentile(previewDurations, percentile: 0.95)
        let state = try requireValue(timeline.persistentState, "edit graph did not persist")
        try require(!latestOverview.bins.isEmpty, "optimistic preview became empty")
        try require(latestOverview.duration > 0, "optimistic preview duration became invalid")
        try require(state.segments.count < operationCount * 3, "edit preview segment count exploded: \(state.segments.count)")
        try require(
            p95PreviewMilliseconds < 8,
            String(format: "optimistic preview p95 was too slow: %.2fms", p95PreviewMilliseconds)
        )
        try require(
            maximumPreviewMilliseconds < 48,
            String(format: "optimistic preview outlier was too slow: %.2fms", maximumPreviewMilliseconds)
        )
        try require(
            elapsedMilliseconds < 2_000,
            String(format: "edit previews were too slow: %.2fms", elapsedMilliseconds)
        )
        try runDeletePrefixStabilitySmoke()

        print(
            String(
                format: "Soundtime edit preview smoke passed: %d ops, %d bins, %d segments, %.2fms p95 preview, %.2fms max preview, %.2fms total",
                operationCount,
                previewBinCount,
                state.segments.count,
                p95PreviewMilliseconds,
                maximumPreviewMilliseconds,
                elapsedMilliseconds
            )
        )
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else {
            return 0
        }

        let sortedValues = values.sorted()
        let clampedPercentile = min(max(percentile, 0), 1)
        let index = min(
            max(Int((Double(sortedValues.count - 1) * clampedPercentile).rounded()), 0),
            sortedValues.count - 1
        )
        return sortedValues[index]
    }

    private static func runDeletePrefixStabilitySmoke() throws {
        let sampleRate = 48_000.0
        let sourceFrameCount = Int(sampleRate) * 60 * 12
        let sourceURL = URL(fileURLWithPath: "/tmp/SoundtimeDeletePrefixStabilitySmoke.wav")
        let fileInfo = WAVFileInfo(
            url: sourceURL,
            formatTag: 1,
            channelCount: 2,
            sampleRate: sampleRate,
            blockAlign: 4,
            bitsPerSample: 16,
            dataRange: 44..<(44 + sourceFrameCount * 4)
        )
        let sourceOverview = makeSourceOverview(
            duration: Double(sourceFrameCount) / sampleRate,
            binCount: 65_536
        )
        let selection = TimelineSelection(startProgress: 0.42, endProgress: 0.54)
        let stablePrefixEndIndex = max(
            Int((selection.startProgress * Double(sourceOverview.bins.count)).rounded(.down)) - 2,
            0
        )

        var timeline = AudioFileEditTimeline(fileInfo: fileInfo)
        let deletedFrames = timeline.delete(selection)
        try require(deletedFrames > 0, "delete prefix stability smoke deleted no frames")

        let editedOverview = timeline.waveformOverview(from: sourceOverview)
        try require(
            editedOverview.bins.count < sourceOverview.bins.count,
            "delete prefix stability smoke did not shorten the preview"
        )
        try require(
            editedOverview.bins.count > stablePrefixEndIndex,
            "delete prefix stability smoke produced too few bins"
        )

        for index in 0..<stablePrefixEndIndex {
            try require(
                binsMatch(sourceOverview.bins[index], editedOverview.bins[index]),
                "delete prefix stability smoke changed untouched prefix bin \(index)"
            )
        }
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

    private static func binsMatch(_ lhs: WaveformOverview.Bin, _ rhs: WaveformOverview.Bin) -> Bool {
        lhs.minimumSample == rhs.minimumSample &&
            lhs.maximumSample == rhs.maximumSample &&
            lhs.rmsSample == rhs.rmsSample &&
            lhs.lowEnergy == rhs.lowEnergy &&
            lhs.midEnergy == rhs.midEnergy &&
            lhs.highEnergy == rhs.highEnergy
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
