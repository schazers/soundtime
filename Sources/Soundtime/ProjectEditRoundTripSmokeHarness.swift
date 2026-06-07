import Foundation

enum ProjectEditRoundTripSmokeHarness {
    enum SmokeError: LocalizedError {
        case invalidProject(String)

        var errorDescription: String? {
            switch self {
            case let .invalidProject(message):
                message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let sourceFrameCount = 12_000
        let sampleRate = 48_000.0
        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()
        let sourceURL = URL(fileURLWithPath: "/tmp/SoundtimeProjectEditRoundTrip.wav")
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
        let deletedFrames = timeline.delete(TimelineSelection(startProgress: 0.20, endProgress: 0.30, trackID: trackID))
        try require(deletedFrames == 1_200, "delete frame count mismatch")

        let gainedFrames = timeline.applyGain(
            0.42,
            to: TimelineSelection(startProgress: 0.40, endProgress: 0.55, trackID: trackID)
        )
        try require((1_620...1_621).contains(gainedFrames), "gain frame count mismatch")

        let fadedInFrames = timeline.applyFade(
            .fadeIn,
            to: TimelineSelection(startProgress: 0.00, endProgress: 0.10, trackID: trackID)
        )
        try require(fadedInFrames == 1_080, "fade-in frame count mismatch")

        let fadedOutFrames = timeline.applyFade(
            .fadeOut,
            to: TimelineSelection(startProgress: 0.90, endProgress: 1.00, trackID: trackID)
        )
        try require(fadedOutFrames == 1_080, "fade-out frame count mismatch")

        let originalState = try requireValue(timeline.persistentState, "edited timeline did not persist")
        let project = SoundtimeProject(
            tracks: [
                SoundtimeProject.Track(
                    id: trackID,
                    name: "Round Trip Track",
                    filePath: sourceURL.path,
                    volume: 0.73,
                    isMuted: true,
                    isSoloed: false,
                    editTimeline: originalState
                ),
            ],
            windowLayout: SoundtimeProject.WindowLayout(x: 20, y: 40, width: 1280, height: 720),
            masterVolume: 0.61
        )

        let encodedProject = try JSONEncoder().encode(project)
        let decodedProject = try JSONDecoder().decode(SoundtimeProject.self, from: encodedProject)
        try require(decodedProject.tracks.count == 1, "project track count mismatch")
        try requireLegacyProjectWithoutMasterVolumeDecodes()

        let decodedTrack = try requireValue(decodedProject.tracks.first, "decoded project has no track")
        try require(decodedTrack.id == trackID, "track ID did not persist")
        try require(decodedTrack.name == "Round Trip Track", "track name did not persist")
        try require(decodedTrack.filePath == sourceURL.path, "track path did not persist")
        try require(abs(decodedTrack.volume - 0.73) < 0.000_001, "track volume did not persist")
        try require(decodedTrack.isMuted, "track mute state did not persist")
        try require(!decodedTrack.isSoloed, "track solo state did not persist")
        try require(abs((decodedProject.masterVolume ?? -1) - 0.61) < 0.000_001, "master volume did not persist")

        let decodedState = try requireValue(decodedTrack.editTimeline, "project dropped edit timeline")
        try requirePersistentStatesMatch(originalState, decodedState)

        let restoredTimeline = try requireValue(
            AudioFileEditTimeline(persistentState: decodedState),
            "could not restore edit timeline"
        )
        try require(restoredTimeline.isCompatible(with: fileInfo), "restored edit timeline is incompatible")
        try require(restoredTimeline.frameCount == sourceFrameCount - deletedFrames, "restored frame count mismatch")
        try require(abs(restoredTimeline.duration - timeline.duration) < 0.000_001, "restored duration mismatch")
        try requirePersistentStatesMatch(
            originalState,
            try requireValue(restoredTimeline.persistentState, "restored timeline did not persist")
        )

        let sourceOverview = syntheticOverview(duration: Double(sourceFrameCount) / sampleRate, binCount: 4_096)
        let originalEditedOverview = timeline.waveformOverview(from: sourceOverview)
        let restoredEditedOverview = restoredTimeline.waveformOverview(from: sourceOverview)
        try requireWaveformOverviewsMatch(originalEditedOverview, restoredEditedOverview)
        try requireRenderedAudioMatchesEdits(
            timeline,
            restoredTimeline,
            sourceFrameCount: sourceFrameCount,
            sampleRate: sampleRate
        )

        print(
            "Soundtime project edit round-trip smoke passed: " +
            "\(decodedState.segments.count) segments, \(restoredTimeline.frameCount) frames"
        )
    }

    private static func syntheticOverview(duration: TimeInterval, binCount: Int) -> WaveformOverview {
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount)
        for index in 0..<binCount {
            let phase = Float(index) / Float(max(binCount - 1, 1))
            let low = sin(phase * 31.0) * 0.18
            let high = sin(phase * 211.0) * 0.05
            let peak = min(max(abs(low + high) + 0.04, 0.02), 0.9)
            bins.append(WaveformOverview.Bin(
                minimumSample: -peak * (0.82 + 0.12 * sin(phase * 13.0)),
                maximumSample: peak,
                rmsSample: peak * 0.55,
                lowEnergy: peak * 0.6,
                midEnergy: peak * 0.35,
                highEnergy: peak * 0.18
            ))
        }
        return WaveformOverview(duration: duration, bins: bins)
    }

    private static func requireRenderedAudioMatchesEdits(
        _ originalTimeline: AudioFileEditTimeline,
        _ restoredTimeline: AudioFileEditTimeline,
        sourceFrameCount: Int,
        sampleRate: Double
    ) throws {
        let sourceBuffer = syntheticAudioBuffer(frameCount: sourceFrameCount, sampleRate: sampleRate)
        let originalRender = originalTimeline.audioTimeline(sourceBuffer: sourceBuffer).render()
        let restoredRender = restoredTimeline.audioTimeline(sourceBuffer: sourceBuffer).render()
        try require(originalRender.frameCount == 10_800, "rendered edit frame count mismatch")
        try require(restoredRender.frameCount == originalRender.frameCount, "restored render frame count mismatch")
        try require(restoredRender.channelCount == originalRender.channelCount, "restored render channel count mismatch")

        for channel in 0..<originalRender.channelCount {
            try require(
                channel < restoredRender.samplesByChannel.count,
                "restored render channel \(channel) missing"
            )
            for frame in 0..<originalRender.frameCount {
                let originalSample = originalRender.samplesByChannel[channel][frame]
                let restoredSample = restoredRender.samplesByChannel[channel][frame]
                try require(
                    abs(originalSample - restoredSample) < 0.000_001,
                    "restored render mismatch at channel \(channel), frame \(frame)"
                )
            }
        }
    }

    private static func syntheticAudioBuffer(frameCount: Int, sampleRate: Double) -> DecodedAudioBuffer {
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            left.append(syntheticSample(channel: 0, frame: frame))
            right.append(syntheticSample(channel: 1, frame: frame))
        }

        return DecodedAudioBuffer(
            url: URL(fileURLWithPath: "/tmp/SoundtimeProjectEditRoundTrip.wav"),
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [left, right]
        )
    }

    private static func syntheticSample(channel: Int, frame: Int) -> Float {
        let base = Float(frame) * 0.000_01
        return channel == 0 ? base : -base * 1.7
    }

    private static func requirePersistentStatesMatch(
        _ left: AudioFileEditTimeline.PersistentState,
        _ right: AudioFileEditTimeline.PersistentState
    ) throws {
        try require(left.sourceFrameCount == right.sourceFrameCount, "source frame count mismatch")
        try require(abs(left.sourceSampleRate - right.sourceSampleRate) < 0.000_001, "source sample rate mismatch")
        try require(left.segments.count == right.segments.count, "segment count mismatch")

        for (index, pair) in zip(left.segments, right.segments).enumerated() {
            let lhs = pair.0
            let rhs = pair.1
            try require(lhs.sourceStartFrame == rhs.sourceStartFrame, "segment \(index) source start mismatch")
            try require(lhs.frameCount == rhs.frameCount, "segment \(index) frame count mismatch")
            try require(abs(lhs.gainStart - rhs.gainStart) < 0.000_001, "segment \(index) gain start mismatch")
            try require(abs(lhs.gainEnd - rhs.gainEnd) < 0.000_001, "segment \(index) gain end mismatch")
        }
    }

    private static func requireWaveformOverviewsMatch(
        _ left: WaveformOverview,
        _ right: WaveformOverview
    ) throws {
        try require(abs(left.duration - right.duration) < 0.000_001, "edited overview duration mismatch")
        try require(left.bins.count == right.bins.count, "edited overview bin count mismatch")

        for (index, pair) in zip(left.bins, right.bins).enumerated() {
            let lhs = pair.0
            let rhs = pair.1
            try require(
                abs(lhs.minimumSample - rhs.minimumSample) < 0.000_001 &&
                    abs(lhs.maximumSample - rhs.maximumSample) < 0.000_001 &&
                    abs(lhs.rmsSample - rhs.rmsSample) < 0.000_001,
                "edited overview bin \(index) mismatch"
            )
        }
    }

    private static func requireLegacyProjectWithoutMasterVolumeDecodes() throws {
        let legacyJSON = """
        {
          "tracks" : [],
          "windowLayout" : {
            "height" : 720,
            "width" : 1280,
            "x" : 20,
            "y" : 40
          }
        }
        """.data(using: .utf8)!
        let legacyProject = try JSONDecoder().decode(SoundtimeProject.self, from: legacyJSON)
        try require(legacyProject.masterVolume == nil, "legacy project unexpectedly decoded master volume")
    }

    private static func requireValue<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else {
            throw SmokeError.invalidProject(message)
        }
        return value
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SmokeError.invalidProject(message)
        }
    }
}
