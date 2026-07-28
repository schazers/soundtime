import AppKit
import Foundation
import QuartzCore

@MainActor
enum StartupCloseLifecycleSmokeHarness {
    private enum SmokeError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(message):
                return message
            }
        }
    }

    private struct Fixture {
        var directory: URL
        var projectURL: URL
        var project: SoundtimeProject
        var trackDrafts: [ProjectLaunchSnapshot.TrackDraft]
        var windowLayout: SoundtimeProject.WindowLayout
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let previousLastProjectURL = SoundtimeProjectStore.lastProjectURL()
        let previousRecentProjectURLs = SoundtimeProjectStore.recentProjectURLs()
        let fixture = try makeFixture()

        defer {
            ProjectLaunchCacheBundleStore.remove(for: fixture.projectURL)
            ProjectLaunchManifestStore.remove(for: fixture.projectURL)
            ProjectFirstFrameWaveformPacketStore.remove(for: fixture.projectURL)
            ProjectLaunchSnapshotStore.remove(for: fixture.projectURL)
            try? FileManager.default.removeItem(at: fixture.directory)
            restoreProjectDefaults(
                previousLastProjectURL: previousLastProjectURL,
                previousRecentProjectURLs: previousRecentProjectURLs
            )
        }

        try installLaunchCaches(for: fixture)
        SoundtimeProjectStore.clearRecentProjectURLs()
        SoundtimeProjectStore.rememberLastProjectURL(fixture.projectURL)
        SoundtimeProjectStore.rememberWindowLayout(fixture.windowLayout, for: fixture.projectURL)
        SoundtimeProjectStore.rememberTimelineViewport(
            fixture.project.timelineViewport ?? SoundtimeProject.TimelineViewport(startProgress: 0, durationProgress: 1),
            for: fixture.projectURL
        )
        SoundtimeProjectStore.rememberLaunchStateOverlay(
            SoundtimeProjectLaunchStateOverlay(
                createdAt: Date().timeIntervalSince1970,
                windowLayout: fixture.windowLayout,
                timelineViewport: fixture.project.timelineViewport,
                masterVolume: fixture.project.masterVolume,
                transcriptDisplayMode: fixture.project.transcriptDisplayMode,
                tracks: fixture.trackDrafts.map {
                    SoundtimeProjectLaunchStateOverlay.TrackState(
                        id: $0.id,
                        volume: $0.volume,
                        isMuted: $0.isMuted,
                        isSoloed: $0.isSoloed
                    )
                }
            ),
            for: fixture.projectURL
        )

        LaunchStartupTrace.shared.resetForSmokeTesting()
        LaunchStartupTrace.shared.mark(.processEntry)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let launchPlan = ProjectLaunchCoordinator.resolveLaunchPlan(restoresLastProject: true)
        LaunchStartupTrace.shared.mark(.launchPlanResolved, fields: launchPlan.diagnosticFields)
        try require(launchPlan.restoresProject, "launch plan did not restore the remembered smoke project")
        try require(launchPlan.targetProjectURL == fixture.projectURL.standardizedFileURL, "launch plan targeted the wrong project")
        try require(launchPlan.expectedTrackCount == fixture.project.tracks.count, "launch plan did not know the final track count")
        try require(launchPlan.firstPaintFrame != nil, "launch plan did not load a first-paint frame")
        try require(launchPlan.firstPaintFrame?.summary.hasDrawableWaveformForEveryTrack == true, "first-paint frame did not contain drawable waveforms for every track")
        try require(launchPlan.windowLayout?.width == fixture.windowLayout.width, "launch plan did not preserve final window width")
        try require(launchPlan.windowLayout?.height == fixture.windowLayout.height, "launch plan did not preserve final window height")

        let controller = MainWindowController(launchPlan: launchPlan)
        controller.showWindow(nil)
        guard let window = controller.window else {
            throw SmokeError.failed("main window controller did not create a window")
        }
        window.makeKeyAndOrderFront(nil)
        LaunchStartupTrace.shared.mark(.windowShowRequested, fields: launchPlan.diagnosticFields)
        runMainLoop(milliseconds: 12)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        controller.submitDeferredLaunchPreviewRenderIfNeeded()
        window.contentView?.displayIfNeeded()
        LaunchStartupTrace.shared.mark(.windowVisible, fields: launchPlan.diagnosticFields)

        let workspace = try requireValue(
            window.contentViewController?.view as? WorkspaceView,
            "main window did not host WorkspaceView"
        )
        let firstPaint = workspace.startupCloseSmokeSnapshot()
        try require(firstPaint.trackCount == 3, "first paint did not show the final 3-track shell: \(firstPaint)")
        try require(firstPaint.placeholderTrackCount == 0, "first paint showed a default placeholder track")
        try require(firstPaint.drawableWaveformTrackCount == 3, "first paint did not show cached waveforms for every track: \(firstPaint)")
        try require(firstPaint.blankTrackCount == 0, "first paint still had blank tracks: \(firstPaint)")
        try require(firstPaint.mutedTrackCount == 1, "first paint did not apply muted track state")
        try require(firstPaint.soloedTrackCount == 1, "first paint did not apply soloed track state")
        try require(firstPaint.isVisualReady, "first paint was not visually ready")
        try require(
            approximatelyEqual(window.frame.width, fixture.windowLayout.width, tolerance: 2) &&
                approximatelyEqual(window.frame.height, fixture.windowLayout.height, tolerance: 2),
            "window did not open at saved final size: \(window.frame)"
        )

        controller.prepareForDeferredProjectRestore()
        controller.restoreLastProjectAfterLaunchPreviewRender()
        try waitUntil(timeoutMilliseconds: 2_000, description: "playback prime did not become ready") {
            let snapshot = workspace.startupCloseSmokeSnapshot()
            return snapshot.playbackHasSource && snapshot.playbackPrimedTrackCount == 3
        }
        let playbackReady = workspace.startupCloseSmokeSnapshot()
        try require(playbackReady.trackCount == 3, "project hydration changed the track count")
        try require(playbackReady.drawableWaveformTrackCount == 3, "project hydration blanked a cached waveform")
        try require(playbackReady.playbackHasSource, "playback was not primed")
        try require(playbackReady.playbackPrimedTrackCount == 3, "not every track was playback-primed")
        try waitUntil(timeoutMilliseconds: 2_000, description: "project loading did not finish") {
            !workspace.startupCloseSmokeSnapshot().isLoadingProject
        }

        let acceptedHotPathRequest = workspace.startupCloseSmokeRequestLaunchCacheDuringHotInteraction()
        let hotPathRequestStart = workspace.startupCloseSmokeSnapshot()
        try require(
            acceptedHotPathRequest,
            "launch cache hot-path request was skipped: \(hotPathRequestStart)"
        )
        try waitUntil(timeoutMilliseconds: 300, description: "launch cache hot-path deferral was not recorded") {
            SoundtimeDiagnostics.shared.recentEvents(limit: 64).contains {
                $0.name == "launch-cache-write-deferred-hot-path" &&
                    $0.fields["reason"] == "startup-close-hot-path-smoke"
            }
        }
        let hotPathCacheWrite = workspace.startupCloseSmokeSnapshot()
        try require(!hotPathCacheWrite.isLaunchCacheWriteInFlight, "launch cache write started during a hot interaction")
        try require(
            hotPathCacheWrite.isLaunchSnapshotWriteScheduled || hotPathCacheWrite.hasPendingLaunchCacheWrite,
            "launch cache hot-path request was not deferred/coalesced"
        )

        let closeStartedAt = CACurrentMediaTime()
        window.close()
        runMainLoop(milliseconds: 20)
        let closeElapsedMilliseconds = (CACurrentMediaTime() - closeStartedAt) * 1_000
        try require(!window.isVisible, "main window remained visible after close")
        try require(closeElapsedMilliseconds < 120, "window close path took too long: \(closeElapsedMilliseconds)ms")

        try assertLaunchTraceContracts(expectedTrackCount: 3)
        let closeTraceElapsedMilliseconds = closeTraceElapsedMilliseconds()
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "startup-close-lifecycle-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: [
                "resolved remembered project with cached first-paint waveforms",
                "opened final-size window with final track count",
                "first paint showed every cached waveform with mute/solo state",
                "playback primed after visual first paint",
                "launch cache writes deferred during hot timeline interaction",
                "close path did not synchronously write waveform caches",
            ],
            metadata: [
                "project": fixture.projectURL.path,
                "firstPaintTracks": "\(firstPaint.trackCount)",
                "firstPaintDrawableWaveforms": "\(firstPaint.drawableWaveformTrackCount)",
                "closeElapsedMs": String(format: "%.2f", closeElapsedMilliseconds),
                "closeTraceElapsedMs": closeTraceElapsedMilliseconds.map { String(format: "%.2f", $0) } ?? "missing",
            ],
            arguments: arguments
        ) {
            print("wrote startup/close lifecycle report: \(reportURL.path)")
        }

        print("Soundtime startup/close lifecycle smoke passed")
    }

    private static func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundtimeStartupCloseLifecycle-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let projectURL = directory.appendingPathComponent("StartupCloseLifecycle.soundtime")
        let windowLayout = SoundtimeProject.WindowLayout(x: 120, y: 140, width: 1_420, height: 820)
        let viewport = SoundtimeProject.TimelineViewport(startProgress: 0.11, durationProgress: 0.42)
        let projectID = UUID()
        let editGroupID = UUID()
        let sampleRate = 48_000.0
        let trackSpecs: [(name: String, frameCount: Int, volume: Float, muted: Bool, soloed: Bool)] = [
            ("Dialog A", 9_600, 0.82, false, false),
            ("Muted Bed", 12_000, 0.67, true, false),
            ("Solo Reference", 14_400, 0.74, false, true),
        ]

        var tracks: [SoundtimeProject.Track] = []
        var drafts: [ProjectLaunchSnapshot.TrackDraft] = []
        for (index, spec) in trackSpecs.enumerated() {
            let audioURL = directory.appendingPathComponent("Track-\(index + 1).wav")
            try WAVFileWriter.write(
                syntheticAudioBuffer(
                    url: audioURL,
                    frameCount: spec.frameCount,
                    sampleRate: sampleRate,
                    seed: Double(index + 1)
                ),
                to: audioURL
            )
            let fileInfo = try WAVAudioDecoder.inspect(url: audioURL)
            let sourceOverview = syntheticOverview(duration: fileInfo.duration, binCount: 8_192, seed: Double(index + 1))
            let displayOverview = syntheticOverview(duration: fileInfo.duration, binCount: 8_192, seed: Double(index + 4))
            let preview = try requireValue(
                SoundtimeProject.WaveformPreview(
                    sourceOverview: sourceOverview,
                    displayOverview: displayOverview,
                    fileInfo: fileInfo,
                    maximumBinCount: ProjectFirstFrameWaveformPacket.maximumOverviewBinCount
                ),
                "could not create waveform preview for \(spec.name)"
            )
            let trackID = UUID()
            let track = SoundtimeProject.Track(
                id: trackID,
                editGroupID: editGroupID,
                name: spec.name,
                filePath: audioURL.path,
                volume: spec.volume,
                isMuted: spec.muted,
                isSoloed: spec.soloed,
                editTimeline: nil,
                editableSource: nil,
                waveformPreview: preview,
                ownsSourceFile: false,
                transcript: nil
            )
            tracks.append(track)
            drafts.append(ProjectLaunchSnapshot.TrackDraft(
                id: trackID,
                editGroupID: editGroupID,
                name: spec.name,
                filePath: audioURL.path,
                durationHint: fileInfo.duration,
                sourceWaveformOverview: sourceOverview,
                displayWaveformOverview: displayOverview,
                editTimeline: nil,
                editableSource: nil,
                ownsSourceFile: false,
                volume: spec.volume,
                isMuted: spec.muted,
                isSoloed: spec.soloed
            ))
        }

        let project = SoundtimeProject(
            projectID: projectID,
            editGraphRevision: 7,
            visualRevision: 11,
            launchStateRevision: 13,
            tracks: tracks,
            windowLayout: windowLayout,
            masterVolume: 0.78,
            timelineViewport: viewport,
            transcriptDisplayMode: .hidden
        )
        try SoundtimeProjectStore.save(project, to: projectURL)
        return Fixture(
            directory: directory,
            projectURL: projectURL.standardizedFileURL,
            project: project,
            trackDrafts: drafts,
            windowLayout: windowLayout
        )
    }

    private static func installLaunchCaches(for fixture: Fixture) throws {
        let snapshot = ProjectLaunchSnapshot(
            projectURL: fixture.projectURL,
            projectID: fixture.project.projectID,
            editGraphRevision: fixture.project.editGraphRevision,
            visualRevision: fixture.project.visualRevision,
            launchStateRevision: fixture.project.launchStateRevision,
            windowLayout: fixture.project.windowLayout,
            timelineViewport: fixture.project.timelineViewport,
            masterVolume: fixture.project.masterVolume,
            transcriptDisplayMode: fixture.project.transcriptDisplayMode,
            tracks: fixture.trackDrafts
        )
        let packet = ProjectFirstFrameWaveformPacket(
            projectURL: fixture.projectURL,
            projectID: fixture.project.projectID,
            editGraphRevision: fixture.project.editGraphRevision,
            visualRevision: fixture.project.visualRevision,
            launchStateRevision: fixture.project.launchStateRevision,
            windowLayout: fixture.project.windowLayout,
            timelineViewport: fixture.project.timelineViewport,
            masterVolume: fixture.project.masterVolume,
            transcriptDisplayMode: fixture.project.transcriptDisplayMode,
            tracks: fixture.trackDrafts
        )
        let snapshotReadiness = ProjectLaunchReadinessClassifier.summarize(snapshot: snapshot)
        let packetReadiness = ProjectLaunchReadinessClassifier.summarize(packet: packet)
        try require(snapshotReadiness.hasDrawableWaveformForEveryTrack, "snapshot fixture is not fully drawable")
        try require(packetReadiness.hasDrawableWaveformForEveryTrack, "first-frame packet fixture is not fully drawable")

        try ProjectLaunchSnapshotStore.save(snapshot, for: fixture.projectURL)
        try ProjectFirstFrameWaveformPacketStore.save(packet, for: fixture.projectURL)
        let snapshotByteCount = try Data(contentsOf: ProjectLaunchSnapshotStore.snapshotURL(for: fixture.projectURL)).count
        let packetByteCount = try Data(contentsOf: ProjectFirstFrameWaveformPacketStore.packetURL(for: fixture.projectURL)).count
        let manifest = ProjectLaunchManifest(
            projectURL: fixture.projectURL,
            projectID: fixture.project.projectID,
            editGraphRevision: fixture.project.editGraphRevision,
            visualRevision: fixture.project.visualRevision,
            launchStateRevision: fixture.project.launchStateRevision,
            windowLayout: fixture.project.windowLayout,
            timelineViewport: fixture.project.timelineViewport,
            masterVolume: fixture.project.masterVolume,
            transcriptDisplayMode: fixture.project.transcriptDisplayMode,
            tracks: fixture.trackDrafts,
            snapshotByteCount: snapshotByteCount,
            firstFramePacketByteCount: packetByteCount,
            snapshotDrawable: snapshotReadiness.hasAnyDrawableWaveform,
            firstFramePacketDrawable: packetReadiness.hasAnyDrawableWaveform
        )
        try ProjectLaunchManifestStore.save(manifest, for: fixture.projectURL)
        _ = try ProjectLaunchCacheBundleStore.publish(
            manifest: manifest,
            firstFramePacket: packet,
            snapshot: snapshot,
            for: fixture.projectURL
        )
    }

    private static func assertLaunchTraceContracts(expectedTrackCount: Int) throws {
        let events = LaunchStartupTrace.shared.snapshot()
        let visualSkeleton = try requireValue(
            events.last(where: { $0.milestone == .visualSkeletonApplied }),
            "launch trace did not record visual skeleton application"
        )
        try require(visualSkeleton.fields["tracks"] == "\(expectedTrackCount)", "visual skeleton trace had wrong track count")
        try require(visualSkeleton.fields["blank"] == "0", "visual skeleton trace allowed blank first-paint tracks")
        try require(
            visualSkeleton.fields["allWaveformsDrawable"] == "true",
            "visual skeleton trace did not require every waveform to be drawable"
        )
        try require(LaunchStartupTrace.shared.contains(.firstWaveformVisibleFrame), "launch trace did not record first waveform visible frame")
        try require(LaunchStartupTrace.shared.contains(.playbackPrimeReady), "launch trace did not record playback prime readiness")

        for milestone in [
            LaunchStartupMilestone.windowClosePrepared,
            .windowCloseStatePersisted,
            .windowCloseFinished,
        ] {
            let event = try requireValue(
                events.last(where: { $0.milestone == milestone }),
                "launch trace missing \(milestone.rawValue)"
            )
            try require(
                event.fields["launchSnapshotWrite"] == "false",
                "\(milestone.rawValue) wrote a launch snapshot synchronously"
            )
            try require(
                event.fields["firstFramePacketWrite"] == "false",
                "\(milestone.rawValue) wrote a first-frame packet synchronously"
            )
        }
    }

    private static func closeTraceElapsedMilliseconds() -> Double? {
        let events = LaunchStartupTrace.shared.snapshot()
        guard
            let requested = events.last(where: { $0.milestone == .windowCloseRequested }),
            let finished = events.last(where: { $0.milestone == .windowCloseFinished })
        else {
            return nil
        }
        return max(0, (finished.timestamp - requested.timestamp) * 1_000)
    }

    private static func restoreProjectDefaults(
        previousLastProjectURL: URL?,
        previousRecentProjectURLs: [URL]
    ) {
        SoundtimeProjectStore.clearRecentProjectURLs()
        for url in previousRecentProjectURLs.reversed() {
            SoundtimeProjectStore.rememberRecentProjectURL(url)
        }
        if let previousLastProjectURL {
            SoundtimeProjectStore.rememberLastProjectURL(previousLastProjectURL)
        }
    }

    private static func syntheticAudioBuffer(
        url: URL,
        frameCount: Int,
        sampleRate: Double,
        seed: Double
    ) -> DecodedAudioBuffer {
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            let envelope = 0.35 + 0.45 * abs(sin((time + seed * 0.017) * 4.0 * .pi))
            left.append(Float(sin(time * (220.0 + seed * 91.0) * 2.0 * .pi) * envelope * 0.28))
            right.append(Float(sin(time * (330.0 + seed * 73.0) * 2.0 * .pi) * envelope * 0.24))
        }
        return DecodedAudioBuffer(
            url: url,
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [left, right]
        )
    }

    private static func syntheticOverview(
        duration: Double,
        binCount: Int,
        seed: Double
    ) -> WaveformOverview {
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount)
        for index in 0..<binCount {
            let phase = Double(index) / Double(max(binCount - 1, 1))
            let pulse = abs(sin((phase * (19.0 + seed)) * .pi))
            let grit = abs(sin((phase * (233.0 + seed * 17.0)) * .pi)) * 0.08
            let peak = Float(min(max(0.03 + pulse * 0.38 + grit, 0.01), 0.94))
            bins.append(WaveformOverview.Bin(
                minimumSample: -peak,
                maximumSample: peak,
                rmsSample: peak * 0.48
            ))
        }
        return WaveformOverview(duration: duration, bins: bins)
    }

    private static func waitUntil(
        timeoutMilliseconds: Double,
        description: String,
        condition: () -> Bool
    ) throws {
        let deadline = CACurrentMediaTime() + timeoutMilliseconds / 1_000
        while CACurrentMediaTime() < deadline {
            if condition() {
                return
            }
            runMainLoop(milliseconds: 20)
        }
        guard condition() else {
            throw SmokeError.failed(description)
        }
    }

    private static func runMainLoop(milliseconds: Double) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: milliseconds / 1_000))
    }

    private static func approximatelyEqual(_ lhs: CGFloat, _ rhs: Double, tolerance: CGFloat) -> Bool {
        abs(lhs - CGFloat(rhs)) <= tolerance
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
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
