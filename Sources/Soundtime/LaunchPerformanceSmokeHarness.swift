import Foundation
import QuartzCore

enum LaunchPerformanceSmokeHarness {
    enum SmokeError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                return message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let fullMode = arguments.contains("--launch-performance-smoke-full")
        let trackCount = fullMode ? 24 : 8
        let binCount = fullMode ? 65_536 : 32_768
        let loadBudgetMilliseconds = fullMode ? 220.0 : 140.0
        let sourceFrameCount = 48_000 * 90
        let sampleRate = 48_000.0
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundtimeLaunchPerformance-\(UUID().uuidString)", isDirectory: true)
        let projectURL = directory
            .appendingPathComponent("LaunchPerformance")
            .appendingPathExtension(SoundtimeProjectStore.fileExtension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            ProjectLaunchSnapshotStore.remove(for: projectURL)
            try? FileManager.default.removeItem(at: directory)
        }

        try Data("launch performance project".utf8).write(to: projectURL, options: [.atomic])
        let tracks = try (0..<trackCount).map { index in
            let sourceURL = directory
                .appendingPathComponent("Track-\(index + 1)")
                .appendingPathExtension("wav")
            try Data(count: 44 + sourceFrameCount * 4 + index).write(to: sourceURL, options: [.atomic])
            let sourceOverview = syntheticOverview(
                duration: Double(sourceFrameCount) / sampleRate,
                binCount: binCount
            )
            let displayOverview = syntheticOverview(
                duration: Double(sourceFrameCount) / sampleRate,
                binCount: max(1, binCount - index * 17)
            )
            return ProjectLaunchSnapshot.TrackDraft(
                id: UUID(),
                editGroupID: UUID(uuidString: "99999999-aaaa-bbbb-cccc-dddddddddddd"),
                name: "Launch Track \(index + 1)",
                filePath: sourceURL.path,
                durationHint: sourceOverview.duration,
                sourceWaveformOverview: sourceOverview,
                displayWaveformOverview: displayOverview,
                editTimeline: nil,
                editableSource: nil,
                ownsSourceFile: false,
                volume: Float(0.70 + Double(index) * 0.005),
                isMuted: false,
                isSoloed: false
            )
        }

        let snapshot = ProjectLaunchSnapshot(
            projectURL: projectURL,
            windowLayout: SoundtimeProject.WindowLayout(x: 44, y: 55, width: 1512, height: 982),
            timelineViewport: SoundtimeProject.TimelineViewport(startProgress: 0.21, durationProgress: 0.18),
            masterVolume: 0.82,
            transcriptDisplayMode: .hidden,
            tracks: tracks
        )
        let snapshotReadiness = ProjectLaunchReadinessClassifier.summarize(snapshot: snapshot)
        try require(snapshotReadiness.trackCount == trackCount, "snapshot readiness track count mismatch")
        try require(
            snapshotReadiness.drawableWaveformTrackCount == trackCount,
            "snapshot readiness did not count drawable waveforms"
        )
        try require(snapshotReadiness.isFirstFrameUsable, "snapshot readiness should be first-frame usable")

        var durationOnlySnapshot = snapshot
        durationOnlySnapshot.tracks[0].sourceOverview = nil
        durationOnlySnapshot.tracks[0].displayOverview = nil
        durationOnlySnapshot.tracks[0].durationHint = Double(sourceFrameCount) / sampleRate
        let durationOnlyReadiness = ProjectLaunchReadinessClassifier.summarize(snapshot: durationOnlySnapshot)
        try require(durationOnlyReadiness.durationOnlyTrackCount == 1, "duration-only launch track was not classified")
        try require(durationOnlyReadiness.isFirstFrameUsable, "duration-only launch track should still be first-frame usable")

        let plannerTracks = tracks.map { draft in
            SoundtimeProject.Track(
                id: draft.id,
                editGroupID: draft.editGroupID,
                name: draft.name,
                filePath: draft.filePath,
                volume: draft.volume,
                isMuted: draft.isMuted,
                isSoloed: draft.isSoloed
            )
        }
        let orderedHydrationTracks = ProjectLaunchHydrationPlanner.orderedTracks(
            plannerTracks,
            activeTrackID: plannerTracks[3].id,
            selectedTrackIDs: [plannerTracks[1].id, plannerTracks[5].id]
        )
        try require(orderedHydrationTracks[0].id == plannerTracks[3].id, "hydration planner did not prioritize active track")
        try require(orderedHydrationTracks[1].id == plannerTracks[1].id, "hydration planner did not keep selected tracks early")
        try require(orderedHydrationTracks[2].id == plannerTracks[5].id, "hydration planner did not preserve selected track order")

        let primeEditedURL = directory.appendingPathComponent("PrimeEdited.wav")
        let primePlainURL = directory.appendingPathComponent("PrimePlain.wav")
        let primeFrameCount = 4_800
        try WAVFileWriter.write(
            syntheticAudioBuffer(url: primeEditedURL, frameCount: primeFrameCount, sampleRate: sampleRate),
            to: primeEditedURL
        )
        try WAVFileWriter.write(
            syntheticAudioBuffer(url: primePlainURL, frameCount: primeFrameCount, sampleRate: sampleRate),
            to: primePlainURL
        )
        let primeEditedInfo = try WAVAudioDecoder.inspect(url: primeEditedURL)
        let editedTimelineState = AudioFileEditTimeline.PersistentState(
            sourceFrameCount: primeEditedInfo.frameCount,
            sourceSampleRate: primeEditedInfo.sampleRate,
            segments: [
                AudioFileEditTimeline.PersistentSegment(
                    sourceStartFrame: 0,
                    frameCount: primeEditedInfo.frameCount / 3,
                    gainStart: 1,
                    gainEnd: 1
                ),
                AudioFileEditTimeline.PersistentSegment(
                    sourceStartFrame: primeEditedInfo.frameCount / 2,
                    frameCount: primeEditedInfo.frameCount / 3,
                    gainStart: 1,
                    gainEnd: 1,
                    startsNewClip: true
                ),
            ]
        )
        let primeEditedTrackID = UUID()
        let primePlainTrackID = UUID()
        let primeProject = SoundtimeProject(
            tracks: [
                SoundtimeProject.Track(
                    id: primeEditedTrackID,
                    name: "Edited Prime",
                    filePath: primeEditedURL.path,
                    volume: 0.9,
                    isMuted: false,
                    isSoloed: false,
                    editTimeline: editedTimelineState
                ),
                SoundtimeProject.Track(
                    id: primePlainTrackID,
                    name: "Plain Prime",
                    filePath: primePlainURL.path,
                    volume: 0.7,
                    isMuted: true,
                    isSoloed: false
                ),
            ],
            windowLayout: nil,
            masterVolume: nil,
            timelineViewport: nil
        )
        let playbackPrime = ProjectLaunchPlaybackPrimer.prime(
            project: primeProject,
            projectURL: projectURL,
            activeTrackID: primePlainTrackID,
            selectedTrackIDs: []
        )
        try require(playbackPrime.isComplete, "playback prime should load all tiny WAV tracks")
        try require(playbackPrime.tracks.count == 2, "playback prime track count mismatch")
        try require(
            playbackPrime.tracks.map(\.trackID) == [primeEditedTrackID, primePlainTrackID],
            "playback prime must preserve project track order"
        )
        let editedPrimeTrack = try requireValue(
            playbackPrime.tracks.first { $0.trackID == primeEditedTrackID },
            "edited playback prime track missing"
        )
        let plainPrimeTrack = try requireValue(
            playbackPrime.tracks.first { $0.trackID == primePlainTrackID },
            "plain playback prime track missing"
        )
        try require(editedPrimeTrack.fileTimeline?.hasEdits == true, "playback prime did not restore edited file timeline")
        try require(editedPrimeTrack.editableSource.editableURL == primeEditedURL.standardizedFileURL, "edited prime source URL mismatch")
        try require(plainPrimeTrack.fileTimeline == nil, "plain playback prime should not invent an edit timeline")
        switch editedPrimeTrack.playbackTrack.source {
        case let .fileTimeline(url, timeline, zeroCrossingProbe):
            try require(url == primeEditedURL.standardizedFileURL, "edited playback prime URL mismatch")
            try require(timeline.hasEdits, "edited playback prime source did not carry edits")
            try require(zeroCrossingProbe == nil, "playback prime should defer zero-crossing probes")
        default:
            throw SmokeError.failed("edited playback prime did not use fileTimeline source")
        }
        switch plainPrimeTrack.playbackTrack.source {
        case let .file(url, zeroCrossingProbe):
            try require(url == primePlainURL.standardizedFileURL, "plain playback prime URL mismatch")
            try require(zeroCrossingProbe == nil, "plain playback prime should defer zero-crossing probes")
        default:
            throw SmokeError.failed("plain playback prime did not use file source")
        }

        try ProjectLaunchSnapshotStore.save(snapshot, for: projectURL)
        let snapshotURL = ProjectLaunchSnapshotStore.snapshotURL(for: projectURL)
        let binaryData = try Data(contentsOf: snapshotURL)
        let legacyJSONData = try JSONEncoder().encode(snapshot)
        try require(ProjectLaunchSnapshotBinaryCodec.hasBinaryMagic(binaryData), "snapshot sidecar did not use binary magic")
        try require(
            binaryData.count < legacyJSONData.count,
            "binary snapshot was not smaller than JSON/base64 snapshot"
        )
        let firstPaintSnapshot = ProjectLaunchSnapshotStore.loadForFirstPaintIfAvailable(for: projectURL)
        if binaryData.count <= ProjectLaunchSnapshotStore.firstPaintSynchronousByteLimit {
            let firstPaintSnapshot = try requireValue(
                firstPaintSnapshot,
                "binary snapshot was not available for bounded first-paint load"
            )
            try require(firstPaintSnapshot.tracks.count == trackCount, "first-paint snapshot track count mismatch")
        } else {
            try require(
                firstPaintSnapshot == nil,
                "oversized binary snapshot should not load on the synchronous first-paint path"
            )
        }

        var loadDurations: [Double] = []
        for _ in 0..<5 {
            let startedAt = CACurrentMediaTime()
            let loadedSnapshot = try ProjectLaunchSnapshotStore.load(for: projectURL)
            let durationMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
            loadDurations.append(durationMilliseconds)
            try require(loadedSnapshot.tracks.count == trackCount, "loaded snapshot track count mismatch")
            try require(loadedSnapshot.isDrawable, "loaded snapshot should be drawable")
            try require(
                loadedSnapshot.tracks.allSatisfy { $0.displayWaveformOverview != nil },
                "loaded snapshot dropped display overviews"
            )
        }

        let averageLoadMilliseconds = loadDurations.reduce(0, +) / Double(max(loadDurations.count, 1))
        let worstLoadMilliseconds = loadDurations.max() ?? 0
        try require(
            averageLoadMilliseconds <= loadBudgetMilliseconds,
            String(format: "average launch snapshot load %.2fms exceeded %.2fms budget", averageLoadMilliseconds, loadBudgetMilliseconds)
        )
        try require(
            worstLoadMilliseconds <= loadBudgetMilliseconds * 1.75,
            String(format: "worst launch snapshot load %.2fms exceeded burst budget", worstLoadMilliseconds)
        )

        try legacyJSONData.write(to: snapshotURL, options: [.atomic])
        try require(
            ProjectLaunchSnapshotStore.loadForFirstPaintIfAvailable(for: projectURL) == nil,
            "legacy JSON snapshot should not load on the synchronous first-paint path"
        )
        let legacyLoaded = try ProjectLaunchSnapshotStore.load(for: projectURL)
        try require(legacyLoaded.tracks.count == trackCount, "legacy JSON snapshot fallback failed")

        try ProjectLaunchSnapshotStore.save(snapshot, for: projectURL)
        let firstSourceURL = URL(fileURLWithPath: tracks[0].filePath)
        try Data("stale source".utf8).write(to: firstSourceURL, options: [.atomic])
        let firstPaintBlankTracksAfterStaleSource: String
        if binaryData.count <= ProjectLaunchSnapshotStore.firstPaintSynchronousByteLimit {
            let staleFirstPaintSnapshot = try requireValue(
                ProjectLaunchSnapshotStore.loadForFirstPaintIfAvailable(for: projectURL),
                "stale-source snapshot should still be available for first paint"
            )
            let staleFirstPaintTrack = try requireValue(
                staleFirstPaintSnapshot.tracks.first,
                "stale-source first-paint snapshot dropped first track"
            )
            try require(
                staleFirstPaintTrack.displayOverview != nil || staleFirstPaintTrack.sourceOverview != nil,
                "stale-source first-paint path stripped cached waveform previews"
            )
            let staleFirstPaintReadiness = ProjectLaunchReadinessClassifier.summarize(
                snapshot: staleFirstPaintSnapshot
            )
            try require(
                staleFirstPaintReadiness.isFirstFrameUsable,
                "stale-source first-paint path should preserve a usable visual shell"
            )
            firstPaintBlankTracksAfterStaleSource = "\(staleFirstPaintReadiness.blankTrackCount)"
        } else {
            try require(
                ProjectLaunchSnapshotStore.loadForFirstPaintIfAvailable(for: projectURL) == nil,
                "oversized stale-source snapshot should remain outside first-paint loading"
            )
            firstPaintBlankTracksAfterStaleSource = "skipped-oversized"
        }

        let staleLoaded = try ProjectLaunchSnapshotStore.load(for: projectURL)
        let staleTrack = try requireValue(staleLoaded.tracks.first, "stale-source snapshot dropped first track")
        try require(staleTrack.sourceOverview == nil, "stale source overview was not stripped")
        try require(staleTrack.displayOverview == nil, "stale display overview was not stripped")
        let staleReadiness = ProjectLaunchReadinessClassifier.summarize(snapshot: staleLoaded)
        try require(staleReadiness.blankTrackCount == 1, "stale source should be classified as a blank launch track")
        try require(!staleReadiness.isFirstFrameUsable, "stale blank source should not be first-frame usable")
        try require(
            staleLoaded.tracks.dropFirst().allSatisfy { $0.displayWaveformOverview != nil },
            "stale source validation stripped unrelated tracks"
        )

        LaunchStartupTrace.shared.resetForSmokeTesting()
        LaunchStartupTrace.shared.mark(.processEntry, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.mark(.windowVisible, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.mark(.visualSkeletonApplied, fields: snapshotReadiness.diagnosticFields, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.markOnce(.firstWaveformVisibleFrame, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.markOnce(.firstWaveformVisibleFrame, recordsDiagnosticEvent: false)
        let launchTraceEvents = LaunchStartupTrace.shared.snapshot()
        try require(
            launchTraceEvents.map(\.milestone) == [
                .processEntry,
                .windowVisible,
                .visualSkeletonApplied,
                .firstWaveformVisibleFrame,
            ],
            "launch trace milestones were not recorded in order"
        )
        try require(
            launchTraceEvents.last?.elapsedMilliseconds ?? -1 >= 0,
            "launch trace did not produce elapsed timing"
        )

        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "launch-performance-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: [
                "binary launch snapshot sidecars replace JSON/base64 waveform payloads",
                "bounded first-paint path loads only compact binary launch snapshots",
                "legacy JSON launch snapshots still load",
                "per-track source validation strips stale previews",
                "launch visual readiness distinguishes drawable, placeholder, and blank tracks",
                "playback prime restores file-backed audio without waveform or zero-crossing work",
                "launch startup trace records ordered first-frame milestones",
                "snapshot load time remains inside startup budget",
                "first-paint launch snapshots preserve cached previews while deferring per-track source validation",
            ],
            metadata: [
                "tracks": "\(trackCount)",
                "binsPerTrack": "\(binCount)",
                "binaryBytes": "\(binaryData.count)",
                "firstPaintByteLimit": "\(ProjectLaunchSnapshotStore.firstPaintSynchronousByteLimit)",
                "legacyJSONBytes": "\(legacyJSONData.count)",
                "drawableWaveformTracks": "\(snapshotReadiness.drawableWaveformTrackCount)",
                "durationOnlyTracks": "\(durationOnlyReadiness.durationOnlyTrackCount)",
                "playbackPrimeMs": String(format: "%.2f", playbackPrime.elapsedMilliseconds),
                "playbackPrimeTracks": "\(playbackPrime.tracks.count)",
                "firstPaintBlankTracksAfterStaleSource": firstPaintBlankTracksAfterStaleSource,
                "blankTracksAfterStaleValidation": "\(staleReadiness.blankTrackCount)",
                "averageLoadMs": String(format: "%.2f", averageLoadMilliseconds),
                "worstLoadMs": String(format: "%.2f", worstLoadMilliseconds),
            ],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }

        print(
            String(
                format: "Soundtime launch performance smoke passed: %d tracks, %.2fms avg snapshot load",
                trackCount,
                averageLoadMilliseconds
            )
        )
    }

    private static func syntheticOverview(duration: TimeInterval, binCount: Int) -> WaveformOverview {
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount)
        for index in 0..<binCount {
            let phase = Float(index) / Float(max(binCount - 1, 1))
            let peak = min(max(abs(sin(phase * 23.0) * 0.20 + sin(phase * 317.0) * 0.07) + 0.02, 0.01), 0.95)
            bins.append(WaveformOverview.Bin(
                minimumSample: -peak,
                maximumSample: peak,
                rmsSample: peak * 0.52
            ))
        }
        return WaveformOverview(duration: duration, bins: bins)
    }

    private static func syntheticAudioBuffer(
        url: URL,
        frameCount: Int,
        sampleRate: Double
    ) -> DecodedAudioBuffer {
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            let phase = Double(frame) / sampleRate
            left.append(Float(sin(phase * 440.0 * Double.pi * 2.0) * 0.20))
            right.append(Float(sin(phase * 660.0 * Double.pi * 2.0) * 0.18))
        }
        return DecodedAudioBuffer(
            url: url,
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [left, right]
        )
    }

    private static func requireValue<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else {
            throw SmokeError.failed(message)
        }
        return value
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SmokeError.failed(message)
        }
    }
}
