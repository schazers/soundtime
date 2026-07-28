import AppKit
import Foundation
import QuartzCore

@MainActor
enum UserPerceivedTimingSmokeHarness {
    private enum SmokeMode {
        case quick
        case standard
        case stress

        init(arguments: [String]) {
            if arguments.contains("--stress") {
                self = .stress
            } else if arguments.contains("--quick") {
                self = .quick
            } else {
                self = .standard
            }
        }
    }

    private enum SmokeError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(message):
                return message
            }
        }
    }

    private struct FixtureManifest: Decodable {
        struct Project: Decodable {
            var id: String
            var role: String
            var path: String
            var durationSeconds: Double?
            var trackCount: Int?
        }

        var projects: [Project]
    }

    private struct ProjectTiming: Codable {
        var id: String
        var path: String
        var trackCount: Int
        var windowVisibleMilliseconds: Double
        var firstWaveformVisibleMilliseconds: Double
        var playbackReadyMilliseconds: Double
        var firstPlayCommandMilliseconds: Double
        var clickToSeekVisualMilliseconds: Double
        var selectionDragEdgeMilliseconds: Double
        var deleteAnimationStartMilliseconds: Double
        var pasteAnimationStartMilliseconds: Double
        var saveLatencyMilliseconds: Double
        var closeLatencyMilliseconds: Double
    }

    private struct TimingBudget {
        var warning: Double
        var failure: Double
    }

    private static let budgets: [String: TimingBudget] = [
        "windowVisibleMilliseconds": TimingBudget(warning: 250, failure: 500),
        "firstWaveformVisibleMilliseconds": TimingBudget(warning: 100, failure: 160),
        "playbackReadyMilliseconds": TimingBudget(warning: 350, failure: 600),
        "firstPlayCommandMilliseconds": TimingBudget(warning: 16, failure: 35),
        "clickToSeekVisualMilliseconds": TimingBudget(warning: 8, failure: 16),
        "selectionDragEdgeMilliseconds": TimingBudget(warning: 8, failure: 16),
        "deleteAnimationStartMilliseconds": TimingBudget(warning: 8, failure: 16),
        "pasteAnimationStartMilliseconds": TimingBudget(warning: 8, failure: 16),
        "saveLatencyMilliseconds": TimingBudget(warning: 60, failure: 160),
        "closeLatencyMilliseconds": TimingBudget(warning: 20, failure: 50),
    ]

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let mode = SmokeMode(arguments: arguments)
        let rootDirectory = try fixtureRoot(arguments: arguments)
        let manifest = try readManifest(rootDirectory: rootDirectory)
        let projects = selectedProjects(from: manifest, mode: mode)
        try require(!projects.isEmpty, "no shippability fixture projects selected for timing smoke")

        let previousLastProjectURL = SoundtimeProjectStore.lastProjectURL()
        let previousRecentProjectURLs = SoundtimeProjectStore.recentProjectURLs()
        defer {
            restoreProjectDefaults(
                previousLastProjectURL: previousLastProjectURL,
                previousRecentProjectURLs: previousRecentProjectURLs
            )
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        var timings: [ProjectTiming] = []
        var checks: [StabilityCheckReport] = []
        for project in projects {
            let projectURL = rootDirectory.appendingPathComponent(project.path).standardizedFileURL
            let timing = try measureProject(
                project,
                projectURL: projectURL,
                rootDirectory: rootDirectory
            )
            timings.append(timing)
            checks.append(StabilityCheckReport(
                name: "user timing \(project.id)",
                status: failingBudgetMessages(for: timing).isEmpty ? "passed" : "failed",
                detail: encodedJSONLine(timing)
            ))
        }

        let failures = timings.flatMap(failingBudgetMessages)
        let metadata = aggregateMetadata(timings: timings, mode: mode, fixtureRoot: rootDirectory)
        let reportStatus = failures.isEmpty ? "passed" : "failed"
        let reportChecks = checks + failures.map {
            StabilityCheckReport(name: "timing budget", status: "failed", detail: $0)
        }

        if let reportURL = StabilityReportWriter.writeSuite(
            name: "user-perceived-timing-smoke",
            status: reportStatus,
            startedAtNanoseconds: startedAtNanoseconds,
            checks: reportChecks,
            metadata: metadata,
            arguments: arguments
        ) {
            print("wrote user-perceived timing report: \(reportURL.path)")
        }

        if !failures.isEmpty {
            throw SmokeError.failed(failures.joined(separator: "\n"))
        }

        print("Soundtime user-perceived timing smoke passed: \(timings.count) project(s)")
    }

    private static func measureProject(
        _ manifestProject: FixtureManifest.Project,
        projectURL: URL,
        rootDirectory: URL
    ) throws -> ProjectTiming {
        let project = try SoundtimeProjectStore.load(from: projectURL)
        try ensureLaunchCaches(project: project, projectURL: projectURL)

        SoundtimeProjectStore.clearRecentProjectURLs()
        SoundtimeProjectStore.rememberLastProjectURL(projectURL)
        if let layout = project.windowLayout {
            SoundtimeProjectStore.rememberWindowLayout(layout, for: projectURL)
        }
        if let viewport = project.timelineViewport {
            SoundtimeProjectStore.rememberTimelineViewport(viewport, for: projectURL)
        }
        SoundtimeProjectStore.rememberLaunchStateOverlay(
            SoundtimeProjectLaunchStateOverlay(
                createdAt: Date().timeIntervalSince1970,
                windowLayout: project.windowLayout,
                timelineViewport: project.timelineViewport,
                masterVolume: project.masterVolume,
                transcriptDisplayMode: project.transcriptDisplayMode,
                tracks: project.tracks.map {
                    SoundtimeProjectLaunchStateOverlay.TrackState(
                        id: $0.id,
                        volume: $0.volume,
                        isMuted: $0.isMuted,
                        isSoloed: $0.isSoloed
                    )
                }
            ),
            for: projectURL
        )

        LaunchStartupTrace.shared.resetForSmokeTesting()
        LaunchStartupTrace.shared.mark(.processEntry, recordsDiagnosticEvent: false)
        let launchStartedAt = CACurrentMediaTime()
        let launchPlan = ProjectLaunchCoordinator.resolveLaunchPlanForProject(
            projectURL: projectURL,
            reason: "user-perceived-timing-fixture"
        )
        LaunchStartupTrace.shared.mark(.launchPlanResolved, fields: launchPlan.diagnosticFields, recordsDiagnosticEvent: false)
        try require(launchPlan.restoresProject, "\(manifestProject.id) did not resolve as a restorable launch")
        try require(
            launchPlan.targetProjectURL == projectURL.standardizedFileURL,
            "\(manifestProject.id) launch plan targeted the wrong project"
        )
        try require(launchPlan.expectedTrackCount == project.tracks.count, "\(manifestProject.id) launch plan did not know final track count")
        try require(launchPlan.firstPaintFrame != nil, "\(manifestProject.id) launch plan had no first-paint frame")

        let controller = MainWindowController(launchPlan: launchPlan)
        controller.showWindow(nil)
        guard let window = controller.window else {
            throw SmokeError.failed("\(manifestProject.id) main window was not created")
        }
        window.makeKeyAndOrderFront(nil)
        LaunchStartupTrace.shared.mark(.windowShowRequested, fields: launchPlan.diagnosticFields, recordsDiagnosticEvent: false)
        runMainLoop(milliseconds: 1)
        let windowVisibleAt = CACurrentMediaTime()
        let windowVisibleMilliseconds = (CACurrentMediaTime() - launchStartedAt) * 1_000
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        controller.submitDeferredLaunchPreviewRenderIfNeeded()
        window.contentView?.displayIfNeeded()
        LaunchStartupTrace.shared.mark(.windowVisible, fields: launchPlan.diagnosticFields, recordsDiagnosticEvent: false)

        let workspace = try requireValue(
            window.contentViewController?.view as? WorkspaceView,
            "\(manifestProject.id) window did not host WorkspaceView"
        )
        let expectedTrackCount = project.tracks.count
        let firstWaveformVisibleMilliseconds = try waitUntilElapsed(
            since: windowVisibleAt,
            timeoutMilliseconds: 1_000,
            description: "\(manifestProject.id) cached waveforms were not visible on first launch paint"
        ) {
            let snapshot = workspace.startupCloseSmokeSnapshot()
            return snapshot.trackCount == expectedTrackCount &&
                snapshot.drawableWaveformTrackCount == expectedTrackCount &&
                snapshot.blankTrackCount == 0 &&
                snapshot.placeholderTrackCount == 0
        }

        controller.prepareForDeferredProjectRestore()
        controller.restoreLastProjectAfterLaunchPreviewRender()
        let playbackReadyMilliseconds = try waitUntilElapsed(
            since: windowVisibleAt,
            timeoutMilliseconds: 3_000,
            description: "\(manifestProject.id) playback did not become ready"
        ) {
            let snapshot = workspace.startupCloseSmokeSnapshot()
            return snapshot.playbackHasSource &&
                snapshot.playbackPrimedTrackCount == expectedTrackCount &&
                !snapshot.isLoadingProject
        }

        let playResult = workspace.userPerceivedTimingSmokeStartPlayback()
        try require(playResult.accepted, "\(manifestProject.id) first play command failed: \(playResult.message)")
        _ = workspace.userPerceivedTimingSmokePausePlayback()

        let seekResult = workspace.userPerceivedTimingSmokeSeek(to: 0.18)
        try require(seekResult.accepted, "\(manifestProject.id) click-to-seek smoke failed: \(seekResult.message)")

        let selectionResult = workspace.userPerceivedTimingSmokeSelectRange(
            trackIndex: 0,
            startProgress: 0.08,
            endProgress: 0.105,
            velocityPixelsPerSecond: 1_600
        )
        try require(selectionResult.accepted, "\(manifestProject.id) selection-drag smoke failed: \(selectionResult.message)")

        let clipboardResult = workspace.userPerceivedTimingSmokePrepareClipboardFromSelection()
        try require(clipboardResult.accepted, "\(manifestProject.id) clipboard prep failed: \(clipboardResult.message)")

        let deleteResult = workspace.userPerceivedTimingSmokeDeleteSelection()
        try require(deleteResult.accepted, "\(manifestProject.id) delete animation did not start: \(deleteResult.message)")
        runMainLoop(milliseconds: 210)

        let pasteSeekResult = workspace.userPerceivedTimingSmokeSeek(to: 0.16)
        try require(pasteSeekResult.accepted, "\(manifestProject.id) paste seek setup failed: \(pasteSeekResult.message)")
        let pasteResult = workspace.userPerceivedTimingSmokePasteAtPlayhead()
        try require(pasteResult.accepted, "\(manifestProject.id) paste animation did not start: \(pasteResult.message)")
        runMainLoop(milliseconds: 210)

        let saveURL = rootDirectory
            .appendingPathComponent("timing-scratch", isDirectory: true)
            .appendingPathComponent("\(manifestProject.id)-compact-save.soundtime")
        try? FileManager.default.createDirectory(
            at: saveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let saveResult = workspace.userPerceivedTimingSmokeWriteCompactProjectSnapshot(to: saveURL)
        try require(saveResult.accepted, "\(manifestProject.id) compact save smoke failed: \(saveResult.message)")
        try? FileManager.default.removeItem(at: saveURL)

        let closeStartedAt = CACurrentMediaTime()
        window.close()
        let closeLatencyMilliseconds = (CACurrentMediaTime() - closeStartedAt) * 1_000
        runMainLoop(milliseconds: 25)
        try require(!window.isVisible, "\(manifestProject.id) window remained visible after close")

        return ProjectTiming(
            id: manifestProject.id,
            path: projectURL.path,
            trackCount: expectedTrackCount,
            windowVisibleMilliseconds: windowVisibleMilliseconds,
            firstWaveformVisibleMilliseconds: firstWaveformVisibleMilliseconds,
            playbackReadyMilliseconds: playbackReadyMilliseconds,
            firstPlayCommandMilliseconds: playResult.elapsedMilliseconds,
            clickToSeekVisualMilliseconds: seekResult.elapsedMilliseconds,
            selectionDragEdgeMilliseconds: selectionResult.elapsedMilliseconds,
            deleteAnimationStartMilliseconds: deleteResult.elapsedMilliseconds,
            pasteAnimationStartMilliseconds: pasteResult.elapsedMilliseconds,
            saveLatencyMilliseconds: saveResult.elapsedMilliseconds,
            closeLatencyMilliseconds: closeLatencyMilliseconds
        )
    }

    static func ensureLaunchCachesForSmoke(project: SoundtimeProject, projectURL: URL) throws {
        let drafts = try project.tracks.map { track -> ProjectLaunchSnapshot.TrackDraft in
            let sourceOverview = track.waveformPreview?.sourceOverview.waveformOverview
            let displayOverview = track.waveformPreview?.displayOverview.waveformOverview
            let durationHint = displayOverview?.duration ??
                sourceOverview?.duration ??
                duration(from: track.editTimeline)
            try require(
                displayOverview?.isEmpty == false || sourceOverview?.isEmpty == false,
            "fixture track \(track.name) did not have a launch waveform preview"
            )
            return ProjectLaunchSnapshot.TrackDraft(
                id: track.id,
                editGroupID: track.editGroupID,
                name: track.name,
                filePath: track.filePath,
                durationHint: durationHint,
                sourceWaveformOverview: sourceOverview,
                displayWaveformOverview: displayOverview,
                editTimeline: track.editTimeline,
                editableSource: track.editableSource,
                ownsSourceFile: track.ownsSourceFile,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed
            )
        }

        let snapshot = ProjectLaunchSnapshot(
            projectURL: projectURL,
            projectID: project.projectID,
            editGraphRevision: project.editGraphRevision,
            visualRevision: project.visualRevision,
            launchStateRevision: project.launchStateRevision,
            windowLayout: project.windowLayout,
            timelineViewport: project.timelineViewport,
            masterVolume: project.masterVolume,
            transcriptDisplayMode: project.transcriptDisplayMode,
            tracks: drafts
        )
        let packet = ProjectFirstFrameWaveformPacket(
            projectURL: projectURL,
            projectID: project.projectID,
            editGraphRevision: project.editGraphRevision,
            visualRevision: project.visualRevision,
            launchStateRevision: project.launchStateRevision,
            windowLayout: project.windowLayout,
            timelineViewport: project.timelineViewport,
            masterVolume: project.masterVolume,
            transcriptDisplayMode: project.transcriptDisplayMode,
            tracks: drafts
        )
        let snapshotReadiness = ProjectLaunchReadinessClassifier.summarize(snapshot: snapshot)
        let packetReadiness = ProjectLaunchReadinessClassifier.summarize(packet: packet)
        try require(snapshotReadiness.hasDrawableWaveformForEveryTrack, "launch snapshot cache was not fully drawable")
        try require(packetReadiness.hasDrawableWaveformForEveryTrack, "first-frame packet cache was not fully drawable")

        let snapshotData = try ProjectLaunchSnapshotBinaryCodec.encode(snapshot)
        let packetData = try ProjectFirstFrameWaveformPacketBinaryCodec.encode(packet)
        let manifest = ProjectLaunchManifest(
            projectURL: projectURL,
            projectID: project.projectID,
            editGraphRevision: project.editGraphRevision,
            visualRevision: project.visualRevision,
            launchStateRevision: project.launchStateRevision,
            windowLayout: project.windowLayout,
            timelineViewport: project.timelineViewport,
            masterVolume: project.masterVolume,
            transcriptDisplayMode: project.transcriptDisplayMode,
            tracks: drafts,
            snapshotByteCount: snapshotData.count,
            firstFramePacketByteCount: packetData.count,
            snapshotDrawable: snapshotReadiness.hasAnyDrawableWaveform,
            firstFramePacketDrawable: packetReadiness.hasAnyDrawableWaveform
        )

        try ProjectLaunchSnapshotStore.save(snapshot, for: projectURL)
        try ProjectFirstFrameWaveformPacketStore.save(packet, for: projectURL)
        try ProjectLaunchManifestStore.save(manifest, for: projectURL)
        _ = try ProjectLaunchCacheBundleStore.publish(
            manifest: manifest,
            firstFramePacket: packet,
            snapshot: snapshot,
            for: projectURL
        )
    }

    private static func ensureLaunchCaches(project: SoundtimeProject, projectURL: URL) throws {
        try ensureLaunchCachesForSmoke(project: project, projectURL: projectURL)
    }

    private static func selectedProjects(
        from manifest: FixtureManifest,
        mode: SmokeMode
    ) -> [FixtureManifest.Project] {
        let selectedIDs: Set<String>
        switch mode {
        case .quick:
            selectedIDs = ["st-ship-project-001", "st-ship-project-004"]
        case .standard:
            selectedIDs = Set(manifest.projects.map(\.id)).subtracting(["st-ship-project-007"])
        case .stress:
            selectedIDs = Set(manifest.projects.map(\.id))
        }
        return manifest.projects
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
    }

    private static func fixtureRoot(arguments: [String]) throws -> URL {
        if
            let explicitIndex = arguments.firstIndex(of: "--fixtures-output"),
            arguments.indices.contains(explicitIndex + 1)
        {
            return URL(fileURLWithPath: arguments[explicitIndex + 1], isDirectory: true).standardizedFileURL
        }
        if
            let path = ProcessInfo.processInfo.environment["SOUNDTIME_SHIPPABILITY_FIXTURE_ROOT"],
            !path.isEmpty
        {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        throw SmokeError.failed("missing fixture root; pass --fixtures-output or SOUNDTIME_SHIPPABILITY_FIXTURE_ROOT")
    }

    private static func readManifest(rootDirectory: URL) throws -> FixtureManifest {
        let manifestURL = rootDirectory.appendingPathComponent("fixtures-manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(FixtureManifest.self, from: data)
    }

    private static func aggregateMetadata(
        timings: [ProjectTiming],
        mode: SmokeMode,
        fixtureRoot: URL
    ) -> [String: String] {
        var metadata: [String: String] = [
            "mode": "\(mode)",
            "fixtureRoot": fixtureRoot.path,
            "projectCount": "\(timings.count)",
        ]
        for keyPath in timingMetricKeyPaths {
            let worstTiming = timings.max { lhs, rhs in
                keyPath.value(lhs) < keyPath.value(rhs)
            }
            metadata["worst\(keyPath.name.capitalizedFirst)"] = String(
                format: "%.3f",
                worstTiming.map(keyPath.value) ?? 0
            )
            metadata["worst\(keyPath.name.capitalizedFirst)Project"] = worstTiming?.id ?? "none"
        }
        metadata["projects"] = timings.map(\.id).joined(separator: ",")
        return metadata
    }

    private static let timingMetricKeyPaths: [(name: String, value: (ProjectTiming) -> Double)] = [
        ("windowVisibleMilliseconds", \.windowVisibleMilliseconds),
        ("firstWaveformVisibleMilliseconds", \.firstWaveformVisibleMilliseconds),
        ("playbackReadyMilliseconds", \.playbackReadyMilliseconds),
        ("firstPlayCommandMilliseconds", \.firstPlayCommandMilliseconds),
        ("clickToSeekVisualMilliseconds", \.clickToSeekVisualMilliseconds),
        ("selectionDragEdgeMilliseconds", \.selectionDragEdgeMilliseconds),
        ("deleteAnimationStartMilliseconds", \.deleteAnimationStartMilliseconds),
        ("pasteAnimationStartMilliseconds", \.pasteAnimationStartMilliseconds),
        ("saveLatencyMilliseconds", \.saveLatencyMilliseconds),
        ("closeLatencyMilliseconds", \.closeLatencyMilliseconds),
    ]

    private static func failingBudgetMessages(for timing: ProjectTiming) -> [String] {
        timingMetricKeyPaths.compactMap { metric in
            guard
                let budget = budgets[metric.name],
                metric.value(timing) > budget.failure
            else {
                return nil
            }
            return String(
                format: "%@ %@ %.3fms exceeded %.3fms",
                timing.id,
                metric.name,
                metric.value(timing),
                budget.failure
            )
        }
    }

    private static func duration(from state: AudioFileEditTimeline.PersistentState?) -> TimeInterval? {
        guard let state, state.sourceSampleRate > 0, state.sourceSampleRate.isFinite else {
            return nil
        }
        let frameCount = state.segments.reduce(0) { $0 + max($1.frameCount, 0) }
        return Double(frameCount) / state.sourceSampleRate
    }

    private static func encodedJSONLine<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private static func waitUntilElapsed(
        since startTime: CFTimeInterval,
        timeoutMilliseconds: Double,
        description: String,
        condition: () -> Bool
    ) throws -> Double {
        let deadline = CACurrentMediaTime() + timeoutMilliseconds / 1_000
        while CACurrentMediaTime() <= deadline {
            if condition() {
                return (CACurrentMediaTime() - startTime) * 1_000
            }
            runMainLoop(milliseconds: 8)
        }
        throw SmokeError.failed(description)
    }

    private static func runMainLoop(milliseconds: Int) {
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1_000)
        repeat {
            if let event = NSApplication.shared.nextEvent(
                matching: .any,
                until: Date(),
                inMode: .default,
                dequeue: true
            ) {
                NSApplication.shared.sendEvent(event)
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        } while Date() < deadline
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
        } else {
            SoundtimeProjectStore.forgetLastProjectURL()
        }
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

private extension String {
    var capitalizedFirst: String {
        guard let first else {
            return self
        }
        return String(first).uppercased() + dropFirst()
    }
}
