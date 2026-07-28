import AppKit
import Foundation
import QuartzCore

@MainActor
enum VisualInvariantsSmokeHarness {
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

    private struct ProjectVisualReport: Codable {
        var id: String
        var role: String
        var path: String
        var expectedTrackCount: Int
        var expectedMutedTrackCount: Int
        var expectedSoloedTrackCount: Int
        var expectedTranscriptWordCount: Int
        var firstPaintMilliseconds: Double
        var playbackReadyMilliseconds: Double
        var seekMilliseconds: Double
        var selectionMilliseconds: Double
        var deleteMilliseconds: Double
        var pasteMilliseconds: Double
        var firstPaintSnapshot: WorkspaceVisualInvariantSmokeSnapshot
        var playbackReadySnapshot: WorkspaceVisualInvariantSmokeSnapshot
        var seekSnapshot: WorkspaceVisualInvariantSmokeSnapshot
        var selectionSnapshot: WorkspaceVisualInvariantSmokeSnapshot
        var deleteSnapshot: WorkspaceVisualInvariantSmokeSnapshot
        var pasteSnapshot: WorkspaceVisualInvariantSmokeSnapshot
        var transcriptSnapshot: WorkspaceVisualInvariantSmokeSnapshot?
        var failures: [String]
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let mode = SmokeMode(arguments: arguments)
        let rootDirectory = try fixtureRoot(arguments: arguments)
        let manifest = try readManifest(rootDirectory: rootDirectory)
        let projects = selectedProjects(from: manifest, mode: mode)
        try require(!projects.isEmpty, "no shippability fixture projects selected for visual invariants smoke")

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

        var projectReports: [ProjectVisualReport] = []
        var checks: [StabilityCheckReport] = []

        for project in projects {
            do {
                let report = try verifyProject(project, rootDirectory: rootDirectory)
                projectReports.append(report)
                checks.append(contentsOf: checkReports(for: report))
            } catch {
                let message = "\(project.id) visual invariant smoke crashed: \(error)"
                checks.append(StabilityCheckReport(
                    name: "\(project.id) visual invariant execution",
                    status: "failed",
                    detail: message
                ))
            }
        }

        let failures = checks
            .filter { $0.status == "failed" }
            .compactMap { $0.detail ?? $0.name }
        let status = failures.isEmpty ? "passed" : "failed"
        let metadata = aggregateMetadata(
            reports: projectReports,
            mode: mode,
            fixtureRoot: rootDirectory
        )
        if let reportURL = StabilityReportWriter.writeSuite(
            name: "visual-invariants-smoke",
            status: status,
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: metadata,
            arguments: arguments
        ) {
            print("wrote visual invariants report: \(reportURL.path)")
        }

        if !failures.isEmpty {
            throw SmokeError.failed(failures.joined(separator: "\n"))
        }

        print("Soundtime visual invariants smoke passed: \(projectReports.count) project(s)")
    }

    private static func verifyProject(
        _ manifestProject: FixtureManifest.Project,
        rootDirectory: URL
    ) throws -> ProjectVisualReport {
        let projectURL = rootDirectory.appendingPathComponent(manifestProject.path).standardizedFileURL
        let project = try SoundtimeProjectStore.load(from: projectURL)
        try UserPerceivedTimingSmokeHarness.ensureLaunchCachesForSmoke(project: project, projectURL: projectURL)

        let expectedTrackCount = manifestProject.trackCount ?? project.tracks.count
        let expectedMutedTrackCount = project.tracks.filter(\.isMuted).count
        let expectedSoloedTrackCount = project.tracks.filter(\.isSoloed).count
        let expectedTranscriptWordCount = project.tracks.reduce(0) { $0 + ($1.transcript?.words.count ?? 0) }

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
            reason: "visual-invariants-fixture"
        )
        LaunchStartupTrace.shared.mark(.launchPlanResolved, fields: launchPlan.diagnosticFields, recordsDiagnosticEvent: false)

        let controller = MainWindowController(launchPlan: launchPlan)
        controller.showWindow(nil)
        guard let window = controller.window else {
            throw SmokeError.failed("\(manifestProject.id) main window was not created")
        }
        window.makeKeyAndOrderFront(nil)
        runMainLoop(milliseconds: 1)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        controller.submitDeferredLaunchPreviewRenderIfNeeded()
        window.contentView?.displayIfNeeded()
        let firstPaintMilliseconds = (CACurrentMediaTime() - launchStartedAt) * 1_000

        let workspace = try requireValue(
            window.contentViewController?.view as? WorkspaceView,
            "\(manifestProject.id) window did not host WorkspaceView"
        )

        var failures: [String] = []
        func record(_ condition: Bool, _ message: String) {
            guard !condition else {
                return
            }
            failures.append("\(manifestProject.id) \(message)")
        }

        let firstPaint = workspace.visualInvariantSmokeSnapshot()
        record(launchPlan.restoresProject, "did not resolve a restorable launch plan")
        record(launchPlan.targetProjectURL == projectURL, "launch plan targeted the wrong project")
        record(launchPlan.firstPaintFrame != nil, "launch plan had no first-paint frame")
        record(launchPlan.firstPaintFrame?.isShellOnly == false, "first-paint frame was only a shell")
        record(launchPlan.firstPaintFrame?.summary.hasDrawableWaveformForEveryTrack == true, "first-paint frame was not drawable for every track")
        record(firstPaint.trackCount == expectedTrackCount, "first paint did not show the final track count")
        record(firstPaint.placeholderTrackCount == 0, "first paint showed a placeholder lane")
        record(firstPaint.blankTrackCount == 0, "first paint had blank waveform lanes")
        record(firstPaint.drawableWaveformTrackCount == expectedTrackCount, "first paint did not show cached waveforms for every track")
        record(firstPaint.mutedTrackCount == expectedMutedTrackCount, "first paint did not apply muted track state")
        record(firstPaint.soloedTrackCount == expectedSoloedTrackCount, "first paint did not apply soloed track state")
        record(firstPaint.isVisualReady, "first paint was not visually ready")
        if let viewport = project.timelineViewport {
            record(
                approximatelyEqual(firstPaint.timelineViewportStartProgress, viewport.startProgress, tolerance: 0.000_5),
                "first paint did not restore the saved viewport start"
            )
            record(
                approximatelyEqual(firstPaint.timelineViewportDurationProgress, viewport.durationProgress, tolerance: 0.000_5),
                "first paint did not restore the saved viewport duration"
            )
        }
        if expectedTranscriptWordCount > 0 {
            record(firstPaint.transcriptLayerVisible, "first paint did not restore the transcript layer visibility")
        }

        controller.prepareForDeferredProjectRestore()
        let playbackStartedAt = CACurrentMediaTime()
        controller.restoreLastProjectAfterLaunchPreviewRender()
        let playbackReadyMilliseconds = try waitUntilElapsed(
            since: playbackStartedAt,
            timeoutMilliseconds: 3_000,
            description: "\(manifestProject.id) playback did not become ready"
        ) {
            let snapshot = workspace.visualInvariantSmokeSnapshot()
            return snapshot.playbackHasSource &&
                snapshot.playbackPrimedTrackCount == expectedTrackCount &&
                !snapshot.isLoadingProject
        }
        let playbackReady = workspace.visualInvariantSmokeSnapshot()
        record(playbackReady.trackCount == expectedTrackCount, "hydration changed the track count")
        record(playbackReady.drawableWaveformTrackCount == expectedTrackCount, "hydration blanked cached waveform lanes")
        record(playbackReady.blankTrackCount == 0, "hydration left blank waveform lanes")
        record(playbackReady.playbackHasSource, "playback source was unavailable after hydration")
        record(playbackReady.playbackPrimedTrackCount == expectedTrackCount, "not every track was playback-primed")
        if expectedTranscriptWordCount > 0 {
            record(playbackReady.transcriptTrackCount > 0, "hydration did not load transcript metadata")
            record(playbackReady.transcriptWordCount == expectedTranscriptWordCount, "hydration transcript word count was wrong")
            record(playbackReady.transcriptLayerVisible, "hydration did not keep the transcript layer visible")
        }

        let seekTarget: Float = expectedTranscriptWordCount > 0 ? 0.006 : 0.22
        let seekResult = workspace.userPerceivedTimingSmokeSeek(to: seekTarget)
        let seekSnapshot = workspace.visualInvariantSmokeSnapshot()
        record(seekResult.accepted, "click-to-seek visual command was rejected")
        record(
            approximatelyEqual(seekSnapshot.playheadProgress, seekTarget, tolerance: 0.002),
            "playhead progress did not match the requested seek target"
        )

        var transcriptSnapshot: WorkspaceVisualInvariantSmokeSnapshot?
        if expectedTranscriptWordCount > 0 {
            runMainLoop(milliseconds: 16)
            let snapshot = workspace.visualInvariantSmokeSnapshot()
            transcriptSnapshot = snapshot
            record(snapshot.transcriptLayerVisible, "transcript layer was not visible after hydration")
            record(snapshot.activeTranscriptWordID != nil, "transcript active word did not follow the playhead")
        }

        let selectionStart = 0.12
        let selectionEnd = 0.155
        let selectionResult = workspace.userPerceivedTimingSmokeSelectRange(
            trackIndex: 0,
            startProgress: selectionStart,
            endProgress: selectionEnd,
            velocityPixelsPerSecond: 2_400
        )
        let selectionSnapshot = workspace.visualInvariantSmokeSnapshot()
        record(selectionResult.accepted, "selection visual command was rejected")
        record(
            approximatelyEqual(selectionSnapshot.selectedRangeStartProgress, selectionStart, tolerance: 0.000_5),
            "selection start did not match the dragged start"
        )
        record(
            approximatelyEqual(selectionSnapshot.selectedRangeEndProgress, selectionEnd, tolerance: 0.000_5),
            "selection end did not match the dragged end"
        )
        if let firstTrackID = project.tracks.first?.id {
            record(selectionSnapshot.selectedTrackID == firstTrackID, "selection did not target the intended track")
        }

        let clipboardResult = workspace.userPerceivedTimingSmokePrepareClipboardFromSelection()
        let clipboardSnapshot = workspace.visualInvariantSmokeSnapshot()
        record(clipboardResult.accepted, "copy/clipboard prep was rejected")
        record(clipboardSnapshot.hasClipboard, "copy did not create an audio clipboard")

        let deleteGenerationBefore = clipboardSnapshot.editAnimationGeneration
        let deleteResult = workspace.userPerceivedTimingSmokeDeleteSelection()
        runMainLoop(milliseconds: 170)
        let deleteSnapshot = workspace.visualInvariantSmokeSnapshot()
        record(deleteResult.accepted, "delete visual command was rejected")
        record(deleteSnapshot.editAnimationGeneration > deleteGenerationBefore, "delete did not advance the edit animation generation")
        record(deleteSnapshot.drawableWaveformTrackCount == expectedTrackCount, "delete handoff lost drawable waveform lanes")
        record(deleteSnapshot.blankTrackCount == 0, "delete handoff showed blank waveform lanes")

        let pasteTarget: Float = 0.18
        let pasteSeekResult = workspace.userPerceivedTimingSmokeSeek(to: pasteTarget)
        record(pasteSeekResult.accepted, "paste setup seek was rejected")
        let pasteGenerationBefore = workspace.visualInvariantSmokeSnapshot().editAnimationGeneration
        let pasteResult = workspace.userPerceivedTimingSmokePasteAtPlayhead()
        runMainLoop(milliseconds: 190)
        let pasteSnapshot = workspace.visualInvariantSmokeSnapshot()
        record(pasteResult.accepted, "paste visual command was rejected")
        record(pasteSnapshot.editAnimationGeneration > pasteGenerationBefore, "paste did not advance the edit animation generation")
        record(pasteSnapshot.selectedRangeStartProgress != nil, "paste did not select the pasted region")
        if let pastedStart = pasteSnapshot.selectedRangeStartProgress {
            record(
                approximatelyEqual(pastedStart, Double(pasteSnapshot.playheadProgress), tolerance: 0.003),
                "paste selection did not start flush with the playhead"
            )
        }
        record(pasteSnapshot.drawableWaveformTrackCount == expectedTrackCount, "paste handoff lost drawable waveform lanes")
        record(pasteSnapshot.blankTrackCount == 0, "paste handoff showed blank waveform lanes")

        window.close()
        runMainLoop(milliseconds: 20)

        return ProjectVisualReport(
            id: manifestProject.id,
            role: manifestProject.role,
            path: projectURL.path,
            expectedTrackCount: expectedTrackCount,
            expectedMutedTrackCount: expectedMutedTrackCount,
            expectedSoloedTrackCount: expectedSoloedTrackCount,
            expectedTranscriptWordCount: expectedTranscriptWordCount,
            firstPaintMilliseconds: firstPaintMilliseconds,
            playbackReadyMilliseconds: playbackReadyMilliseconds,
            seekMilliseconds: seekResult.elapsedMilliseconds,
            selectionMilliseconds: selectionResult.elapsedMilliseconds,
            deleteMilliseconds: deleteResult.elapsedMilliseconds,
            pasteMilliseconds: pasteResult.elapsedMilliseconds,
            firstPaintSnapshot: firstPaint,
            playbackReadySnapshot: playbackReady,
            seekSnapshot: seekSnapshot,
            selectionSnapshot: selectionSnapshot,
            deleteSnapshot: deleteSnapshot,
            pasteSnapshot: pasteSnapshot,
            transcriptSnapshot: transcriptSnapshot,
            failures: failures
        )
    }

    private static func checkReports(for report: ProjectVisualReport) -> [StabilityCheckReport] {
        var checks: [StabilityCheckReport] = []
        if report.failures.isEmpty {
            checks.append(StabilityCheckReport(
                name: "\(report.id) visual invariants",
                status: "passed",
                detail: encodedJSONLine(report)
            ))
            return checks
        }

        for failure in report.failures {
            checks.append(StabilityCheckReport(
                name: "\(report.id) visual invariant",
                status: "failed",
                detail: failure
            ))
        }
        checks.append(StabilityCheckReport(
            name: "\(report.id) visual invariant snapshots",
            status: "failed",
            detail: encodedJSONLine(report)
        ))
        return checks
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
        reports: [ProjectVisualReport],
        mode: SmokeMode,
        fixtureRoot: URL
    ) -> [String: String] {
        var metadata: [String: String] = [
            "mode": "\(mode)",
            "fixtureRoot": fixtureRoot.path,
            "projectCount": "\(reports.count)",
            "projects": reports.map(\.id).joined(separator: ","),
            "failureCount": "\(reports.reduce(0) { $0 + $1.failures.count })",
            "worstFirstPaintMs": String(format: "%.3f", reports.map(\.firstPaintMilliseconds).max() ?? 0),
            "worstPlaybackReadyMs": String(format: "%.3f", reports.map(\.playbackReadyMilliseconds).max() ?? 0),
            "worstSeekMs": String(format: "%.3f", reports.map(\.seekMilliseconds).max() ?? 0),
            "worstSelectionMs": String(format: "%.3f", reports.map(\.selectionMilliseconds).max() ?? 0),
            "worstDeleteMs": String(format: "%.3f", reports.map(\.deleteMilliseconds).max() ?? 0),
            "worstPasteMs": String(format: "%.3f", reports.map(\.pasteMilliseconds).max() ?? 0),
        ]
        metadata["checkedFirstPaintTracks"] = "\(reports.reduce(0) { $0 + $1.firstPaintSnapshot.trackCount })"
        metadata["checkedDrawableWaveformTracks"] = "\(reports.reduce(0) { $0 + $1.firstPaintSnapshot.drawableWaveformTrackCount })"
        metadata["checkedTranscriptWords"] = "\(reports.reduce(0) { $0 + $1.expectedTranscriptWordCount })"
        return metadata
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

    private static func approximatelyEqual(_ lhs: Float?, _ rhs: Float, tolerance: Float) -> Bool {
        guard let lhs, lhs.isFinite, rhs.isFinite else {
            return false
        }
        return abs(lhs - rhs) <= tolerance
    }

    private static func approximatelyEqual(_ lhs: Float, _ rhs: Float, tolerance: Float) -> Bool {
        guard lhs.isFinite, rhs.isFinite else {
            return false
        }
        return abs(lhs - rhs) <= tolerance
    }

    private static func approximatelyEqual(_ lhs: Double?, _ rhs: Double, tolerance: Double) -> Bool {
        guard let lhs, lhs.isFinite, rhs.isFinite else {
            return false
        }
        return abs(lhs - rhs) <= tolerance
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
