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
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
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

        let copiedClip = try requireValue(
            timeline.clip(for: TimelineSelection(startProgress: 0.08, endProgress: 0.12, trackID: trackID)),
            "could not copy file-backed clip"
        )
        let pastedFrames = try requireValue(
            timeline.replace(
                TimelineSelection(startProgress: 0.65, endProgress: 0.65, trackID: trackID),
                with: copiedClip
            ),
            "could not paste file-backed clip"
        )
        try require(pastedFrames == copiedClip.frameCount, "pasted clip frame count mismatch")

        let originalState = try requireValue(timeline.persistentState, "edited timeline did not persist")
        let sourceOverview = syntheticOverview(duration: Double(sourceFrameCount) / sampleRate, binCount: 512)
        let originalEditedOverview = timeline.waveformOverview(from: sourceOverview)
        let waveformPreview = try requireValue(
            SoundtimeProject.WaveformPreview(
                sourceOverview: sourceOverview,
                displayOverview: originalEditedOverview,
                fileInfo: fileInfo,
                maximumBinCount: 128
            ),
            "could not create launch waveform preview"
        )
        let project = SoundtimeProject(
            tracks: [
                SoundtimeProject.Track(
                    id: trackID,
                    name: "Round Trip Track",
                    filePath: sourceURL.path,
                    volume: 0.73,
                    isMuted: true,
                    isSoloed: false,
                    editTimeline: originalState,
                    waveformPreview: waveformPreview
                ),
            ],
            windowLayout: SoundtimeProject.WindowLayout(x: 20, y: 40, width: 1280, height: 720),
            masterVolume: 0.61,
            timelineViewport: SoundtimeProject.TimelineViewport(
                startProgress: 0.17,
                durationProgress: 0.23
            )
        )

        let encodedProject = try JSONEncoder().encode(project)
        let decodedProject = try JSONDecoder().decode(SoundtimeProject.self, from: encodedProject)
        try require(
            decodedProject.schemaVersion == SoundtimeProject.currentSchemaVersion,
            "project schema version did not persist"
        )
        try require(decodedProject.tracks.count == 1, "project track count mismatch")
        try requireLegacyProjectWithoutMasterVolumeDecodes()
        try requireProjectStoreMigratesLegacyProject()
        try requireMultiTrackEditGraphStressRoundTrip(fileInfo: fileInfo)

        let decodedTrack = try requireValue(decodedProject.tracks.first, "decoded project has no track")
        try require(decodedTrack.id == trackID, "track ID did not persist")
        try require(decodedTrack.name == "Round Trip Track", "track name did not persist")
        try require(decodedTrack.filePath == sourceURL.path, "track path did not persist")
        try require(abs(decodedTrack.volume - 0.73) < 0.000_001, "track volume did not persist")
        try require(decodedTrack.isMuted, "track mute state did not persist")
        try require(!decodedTrack.isSoloed, "track solo state did not persist")
        let decodedPreview = try requireValue(decodedTrack.waveformPreview, "track dropped launch waveform preview")
        try require(decodedPreview.isValid(for: fileInfo), "launch waveform preview did not validate")
        try require(decodedPreview.sourceOverview.bins.count == 128, "source launch preview was not compacted")
        try require(decodedPreview.displayOverview.bins.count == 128, "display launch preview was not compacted")
        let restoredLaunchOverview = decodedPreview.displayOverview.waveformOverview
        try require(
            abs(restoredLaunchOverview.duration - originalEditedOverview.duration) < 0.000_001,
            "launch preview duration did not persist"
        )
        let mismatchedFileInfo = WAVFileInfo(
            url: sourceURL,
            formatTag: 1,
            channelCount: 2,
            sampleRate: sampleRate,
            blockAlign: 4,
            bitsPerSample: 16,
            dataRange: 44..<(44 + (sourceFrameCount + 1) * 4)
        )
        try require(!decodedPreview.isValid(for: mismatchedFileInfo), "launch preview did not invalidate")
        try require(abs((decodedProject.masterVolume ?? -1) - 0.61) < 0.000_001, "master volume did not persist")
        try require(
            abs((decodedProject.timelineViewport?.startProgress ?? -1) - 0.17) < 0.000_001 &&
                abs((decodedProject.timelineViewport?.durationProgress ?? -1) - 0.23) < 0.000_001,
            "timeline viewport did not persist"
        )

        let decodedState = try requireValue(decodedTrack.editTimeline, "project dropped edit timeline")
        try requirePersistentStatesMatch(originalState, decodedState)

        let restoredTimeline = try requireValue(
            AudioFileEditTimeline(persistentState: decodedState),
            "could not restore edit timeline"
        )
        try require(restoredTimeline.isCompatible(with: fileInfo), "restored edit timeline is incompatible")
        try require(
            restoredTimeline.frameCount == sourceFrameCount - deletedFrames + pastedFrames,
            "restored frame count mismatch"
        )
        try require(abs(restoredTimeline.duration - timeline.duration) < 0.000_001, "restored duration mismatch")
        try requirePersistentStatesMatch(
            originalState,
            try requireValue(restoredTimeline.persistentState, "restored timeline did not persist")
        )

        let restoredEditedOverview = restoredTimeline.waveformOverview(from: sourceOverview)
        try requireWaveformOverviewsMatch(originalEditedOverview, restoredEditedOverview)
        try requireRenderedAudioMatchesEdits(
            timeline,
            restoredTimeline,
            sourceFrameCount: sourceFrameCount,
            sampleRate: sampleRate,
            expectedFrameCount: sourceFrameCount - deletedFrames + pastedFrames
        )

        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "project-edit-roundtrip-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: [
                "project preserves track and mixer state",
                "project preserves edit timeline state",
                "project preserves compact launch waveform preview",
                "restored timeline renders audio identical to original edits",
                "legacy projects migrate and decode",
                "multi-track edit graph stress round-trips",
            ],
            metadata: [
                "sourceFrameCount": "\(sourceFrameCount)",
                "restoredFrameCount": "\(restoredTimeline.frameCount)",
                "segmentCount": "\(decodedState.segments.count)",
                "deletedFrames": "\(deletedFrames)",
                "pastedFrames": "\(pastedFrames)",
            ],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }

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
        sampleRate: Double,
        expectedFrameCount: Int
    ) throws {
        let sourceBuffer = syntheticAudioBuffer(frameCount: sourceFrameCount, sampleRate: sampleRate)
        let originalRender = originalTimeline.audioTimeline(sourceBuffer: sourceBuffer).render()
        let restoredRender = restoredTimeline.audioTimeline(sourceBuffer: sourceBuffer).render()
        try require(originalRender.frameCount == expectedFrameCount, "rendered edit frame count mismatch")
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
            try require(lhs.startsNewClip == rhs.startsNewClip, "segment \(index) clip boundary mismatch")
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
        try require(legacyProject.schemaVersion == 1, "legacy project schema version mismatch")
        try require(legacyProject.masterVolume == nil, "legacy project unexpectedly decoded master volume")
        try require(legacyProject.timelineViewport == nil, "legacy project unexpectedly decoded timeline viewport")
    }

    private static func requireProjectStoreMigratesLegacyProject() throws {
        let legacyURL = URL(fileURLWithPath: "/tmp/SoundtimeLegacyProjectMigrationSmoke.soundtime")
        let legacyJSON = """
        {
          "tracks" : [
            {
              "id" : "11111111-2222-3333-4444-555555555555",
              "name" : "Legacy",
              "filePath" : "/tmp/legacy.wav",
              "volume" : 1,
              "isMuted" : false,
              "isSoloed" : false
            }
          ]
        }
        """.data(using: .utf8)!
        try legacyJSON.write(to: legacyURL, options: [.atomic])
        defer {
            try? FileManager.default.removeItem(at: legacyURL)
        }

        let migratedProject = try SoundtimeProjectStore.load(from: legacyURL)
        try require(
            migratedProject.schemaVersion == SoundtimeProject.currentSchemaVersion,
            "project store did not migrate legacy schema"
        )
        try require(migratedProject.tracks.count == 1, "migrated legacy project lost tracks")
    }

    private static func requireMultiTrackEditGraphStressRoundTrip(fileInfo: WAVFileInfo) throws {
        let projectURL = URL(fileURLWithPath: "/tmp/SoundtimeProjectStressRoundTrip.soundtime")
        let editGroupID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee") ?? UUID()
        let tracks: [SoundtimeProject.Track] = try (0..<12).map { trackIndex in
            var timeline = AudioFileEditTimeline(fileInfo: fileInfo)
            for editIndex in 0..<18 {
                let start = Double((trackIndex * 7_111 + editIndex * 31_337) % 750_000) / 1_000_000
                let end = min(start + 0.004 + Double(editIndex % 5) * 0.000_7, 0.96)
                let selection = TimelineSelection(startProgress: start, endProgress: end)
                switch editIndex % 4 {
                case 0:
                    _ = timeline.applyGain(0.82, to: selection)
                case 1:
                    _ = timeline.applyFade(.fadeIn, to: selection)
                case 2:
                    _ = timeline.applyFade(.fadeOut, to: selection)
                default:
                    _ = timeline.delete(selection)
                }
            }

            return SoundtimeProject.Track(
                id: UUID(),
                editGroupID: editGroupID,
                name: "Stress \(trackIndex + 1)",
                filePath: fileInfo.url.path,
                volume: Float(0.5 + Double(trackIndex) * 0.025),
                isMuted: trackIndex.isMultiple(of: 5),
                isSoloed: trackIndex == 3,
                editTimeline: try requireValue(timeline.persistentState, "stress track did not persist")
            )
        }
        let project = SoundtimeProject(
            tracks: tracks,
            windowLayout: SoundtimeProject.WindowLayout(x: 44, y: 55, width: 1440, height: 900),
            masterVolume: 0.88,
            timelineViewport: SoundtimeProject.TimelineViewport(startProgress: 0.11, durationProgress: 0.37)
        )

        let data = try JSONEncoder().encode(project)
        try data.write(to: projectURL, options: [.atomic])
        defer {
            try? FileManager.default.removeItem(at: projectURL)
        }

        let restoredProject = try SoundtimeProjectStore.load(from: projectURL)
        try require(restoredProject.schemaVersion == SoundtimeProject.currentSchemaVersion, "stress schema mismatch")
        try require(restoredProject.tracks.count == tracks.count, "stress track count mismatch")
        try require(abs((restoredProject.masterVolume ?? 0) - 0.88) < 0.000_001, "stress master volume mismatch")
        for (index, pair) in zip(tracks, restoredProject.tracks).enumerated() {
            let original = pair.0
            let restored = pair.1
            try require(original.editGroupID == restored.editGroupID, "stress track \(index) group mismatch")
            try require(original.name == restored.name, "stress track \(index) name mismatch")
            try require(abs(original.volume - restored.volume) < 0.000_001, "stress track \(index) volume mismatch")
            try require(original.isMuted == restored.isMuted, "stress track \(index) mute mismatch")
            try require(original.isSoloed == restored.isSoloed, "stress track \(index) solo mismatch")
            try requirePersistentStatesMatch(
                try requireValue(original.editTimeline, "stress original timeline missing"),
                try requireValue(restored.editTimeline, "stress restored timeline missing")
            )
        }
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
