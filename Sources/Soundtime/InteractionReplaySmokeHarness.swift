import AppKit
import Foundation
import QuartzCore

@MainActor
enum InteractionReplaySmokeHarness {
    private enum SmokeMode {
        case quick
        case standard
        case stress

        init(arguments: [String]) {
            if arguments.contains("--stress") || arguments.contains("--full") {
                self = .stress
            } else if arguments.contains("--quick") {
                self = .quick
            } else {
                self = .standard
            }
        }

        var seekIterations: Int {
            switch self {
            case .quick: return 12
            case .standard: return 24
            case .stress: return 80
            }
        }

        var dragIterations: Int {
            switch self {
            case .quick: return 12
            case .standard: return 24
            case .stress: return 96
            }
        }

        var reportName: String {
            switch self {
            case .quick:
                return "quick"
            case .standard:
                return "standard"
            case .stress:
                return "full"
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

    private struct ReplayCoverageProfile: Codable {
        var seekIterations: Int
        var dragIterations: Int
        var editIterations: Int
        var selectionMeasurementPasses: Int

        static func make(
            mode: SmokeMode,
            projectID: String
        ) -> ReplayCoverageProfile {
            switch mode {
            case .quick:
                return ReplayCoverageProfile(
                    seekIterations: mode.seekIterations,
                    dragIterations: mode.dragIterations,
                    editIterations: 8,
                    selectionMeasurementPasses: 1
                )
            case .standard:
                let editIterations = [
                    "st-ship-project-004",
                    "st-ship-project-005",
                ].contains(projectID) ? 24 : 8
                return ReplayCoverageProfile(
                    seekIterations: mode.seekIterations,
                    dragIterations: mode.dragIterations,
                    editIterations: editIterations,
                    selectionMeasurementPasses: 1
                )
            case .stress:
                let editIterations: Int
                switch projectID {
                case "st-ship-project-004", "st-ship-project-005":
                    // These are the canonical multi-track and edited-timeline
                    // fixtures. They own the release gate's required 100-cycle
                    // delete/undo/redo and paste/undo/redo torture coverage.
                    editIterations = 100
                case "st-ship-project-003", "st-ship-project-006":
                    // Keep meaningful parity coverage on compressed-origin and
                    // transcript-bearing timelines without duplicating the
                    // canonical edit torture loop.
                    editIterations = 24
                case "st-ship-project-007":
                    editIterations = 12
                default:
                    editIterations = 4
                }
                return ReplayCoverageProfile(
                    seekIterations: mode.seekIterations,
                    dragIterations: mode.dragIterations,
                    editIterations: editIterations,
                    selectionMeasurementPasses: 3
                )
            }
        }
    }

    private struct ReplayScriptReport: Codable {
        struct Action: Codable {
            var index: Int
            var accepted: Bool
            var elapsedMilliseconds: Double
            var message: String
            var editAnimationGenerationChanged: Bool
            var expectedLeadingProgress: Double?
            var renderedLeadingProgress: Double?
            var selectionEdgeErrorPixels: Double?
            var motionDirection: Double?
            var isIntentionalSelectionCollapse: Bool
        }

        var name: String
        var iterationCount: Int
        var elapsedMilliseconds: Double
        var maxActionMilliseconds: Double
        var slowestAction: Action?
        var actions: [Action]
        var finalPlayheadProgress: Float
        var finalSelectionStartProgress: Double?
        var finalSelectionEndProgress: Double?
        var finalSnapshot: WorkspaceVisualInvariantSmokeSnapshot
        var hotPathSnapshot: WorkspaceHotPathContractSmokeSnapshot
        var rejectedActionCount: Int
        var intentionalSelectionCollapseCount: Int
        var directionReversalCount: Int
        var maxSelectionEdgeErrorPixels: Double
        var failures: [String]
    }

    private struct ProjectReport: Codable {
        var id: String
        var role: String
        var path: String
        var expectedTrackCount: Int
        var hasTranscript: Bool
        var coverage: ReplayCoverageProfile
        var scripts: [ReplayScriptReport]
        var failures: [String]
    }

    private enum ReplayBudgets {
        static let hotWindowMilliseconds = 520
        static let renderDrainMilliseconds = 24
        static let editAnimationSettleMilliseconds = 190
        static let loopWrapMilliseconds = 640
        static let maximumActionMilliseconds: Double = 35
        static let maximumPlayheadProgressError: Float = 0.003
        static let maximumSelectionProgressError = 0.003
        static let maximumSelectionEdgeErrorPixels = 0.75
        static let minimumSelectionDirectionReversals = 1
    }

    private struct ReplayScriptContext {
        var name: String
        var deadline: CFTimeInterval

        func check(iteration: Int) throws {
            guard CACurrentMediaTime() <= deadline else {
                throw SmokeError.failed("\(name) exceeded its replay timeout near iteration \(iteration)")
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let mode = SmokeMode(arguments: arguments)
        let rootDirectory = try fixtureRoot(arguments: arguments)
        let manifest = try readManifest(rootDirectory: rootDirectory)
        let projects = selectedProjects(from: manifest, mode: mode, arguments: arguments)
        try require(!projects.isEmpty, "no shippability fixture projects selected for interaction replay smoke")

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

        var projectReports: [ProjectReport] = []
        var checks: [StabilityCheckReport] = []
        for project in projects {
            do {
                printProgress("interaction replay: starting \(project.id) (\(project.role))")
                let report = try autoreleasepool {
                    try verifyProject(project, rootDirectory: rootDirectory, mode: mode)
                }
                // Drain close notifications and any final AppKit release work before
                // constructing the next project's window in this long-lived process.
                runMainLoop(milliseconds: 25)
                printProgress("interaction replay: finished \(project.id) with \(report.failures.count) failure(s)")
                projectReports.append(report)
                checks.append(contentsOf: checkReports(for: report))
            } catch {
                let message = "\(project.id) interaction replay crashed: \(error)"
                checks.append(StabilityCheckReport(
                    name: "\(project.id) interaction replay execution",
                    status: "failed",
                    detail: message
                ))
            }
        }

        checks.append(contentsOf: replayCoverageChecks(
            reports: projectReports,
            expectedProjects: projects,
            mode: mode
        ))
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
            name: "interaction-replay-smoke",
            status: status,
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: metadata,
            arguments: arguments
        ) {
            print("wrote interaction replay report: \(reportURL.path)")
        }

        if !failures.isEmpty {
            throw SmokeError.failed(failures.joined(separator: "\n"))
        }

        print("Soundtime interaction replay smoke passed: \(projectReports.count) project(s)")
    }

    private static func verifyProject(
        _ manifestProject: FixtureManifest.Project,
        rootDirectory: URL,
        mode: SmokeMode
    ) throws -> ProjectReport {
        let projectURL = rootDirectory.appendingPathComponent(manifestProject.path).standardizedFileURL
        let project = try SoundtimeProjectStore.load(from: projectURL)
        try UserPerceivedTimingSmokeHarness.ensureLaunchCachesForSmoke(project: project, projectURL: projectURL)
        installLaunchDefaults(project: project, projectURL: projectURL)

        LaunchStartupTrace.shared.resetForSmokeTesting()
        LaunchStartupTrace.shared.mark(.processEntry, recordsDiagnosticEvent: false)
        let launchPlan = ProjectLaunchCoordinator.resolveLaunchPlanForProject(
            projectURL: projectURL,
            reason: "interaction-replay-fixture"
        )
        LaunchStartupTrace.shared.mark(.launchPlanResolved, fields: launchPlan.diagnosticFields, recordsDiagnosticEvent: false)

        let controller = MainWindowController(launchPlan: launchPlan)
        controller.showWindow(nil)
        guard let window = controller.window else {
            throw SmokeError.failed("\(manifestProject.id) main window was not created")
        }
        defer {
            PerformanceDashboardWindowController.closeIfLoaded()
            controller.prepareForImmediateWindowClose()
            window.close()
            runMainLoop(milliseconds: 25)
        }
        window.makeKeyAndOrderFront(nil)
        runMainLoop(milliseconds: 1)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        controller.submitDeferredLaunchPreviewRenderIfNeeded()
        window.contentView?.displayIfNeeded()

        let workspace = try requireValue(
            window.contentViewController?.view as? WorkspaceView,
            "\(manifestProject.id) window did not host WorkspaceView"
        )

        controller.prepareForDeferredProjectRestore()
        controller.restoreLastProjectAfterLaunchPreviewRender()
        let expectedTrackCount = manifestProject.trackCount ?? project.tracks.count
        let readinessDeadline = CACurrentMediaTime() + 8
        var readinessSnapshot = workspace.hotPathContractSmokeSnapshot()
        while CACurrentMediaTime() <= readinessDeadline {
            readinessSnapshot = workspace.hotPathContractSmokeSnapshot()
            if !readinessSnapshot.isLoadingProject &&
                readinessSnapshot.playbackHasSource &&
                readinessSnapshot.playbackPrimedTrackCount == expectedTrackCount &&
                readinessSnapshot.drawableWaveformTrackCount == expectedTrackCount &&
                workspace.hotPathContractSmokeIsProjectFullyHydrated() &&
                workspace.hotPathContractSmokeIsRendererReady() {
                break
            }
            runMainLoop(milliseconds: 8)
        }
        guard !readinessSnapshot.isLoadingProject,
              readinessSnapshot.playbackHasSource,
              readinessSnapshot.playbackPrimedTrackCount == expectedTrackCount,
              readinessSnapshot.drawableWaveformTrackCount == expectedTrackCount,
              workspace.hotPathContractSmokeIsProjectFullyHydrated(),
              workspace.hotPathContractSmokeIsRendererReady() else {
            throw SmokeError.failed(
                """
                \(manifestProject.id) playback did not become ready before interaction replay \
                (tracks=\(readinessSnapshot.trackCount)/\(expectedTrackCount), \
                drawable=\(readinessSnapshot.drawableWaveformTrackCount), \
                blank=\(readinessSnapshot.blankTrackCount), \
                playbackSource=\(readinessSnapshot.playbackHasSource), \
                primed=\(readinessSnapshot.playbackPrimedTrackCount), \
                hydrated=\(workspace.hotPathContractSmokeIsProjectFullyHydrated()), \
                rendererReady=\(workspace.hotPathContractSmokeIsRendererReady()), \
                loading=\(readinessSnapshot.isLoadingProject), \
                status=\(readinessSnapshot.statusText))
                """
            )
        }

        let hasTranscript = project.tracks.contains { $0.transcript != nil }
        let coverage = ReplayCoverageProfile.make(
            mode: mode,
            projectID: manifestProject.id
        )
        if hasTranscript {
            workspace.hotPathContractSmokeShowTranscriptLayerIfAvailable()
            runMainLoop(milliseconds: 90)
        }
        try warmRendererForInteractionReplay(workspace: workspace)

        var scripts: [ReplayScriptReport] = []
        if hasTranscript {
            scripts.append(try runTranscriptReplay(
                workspace: workspace,
                iterations: min(coverage.dragIterations, 24)
            ))
        }
        scripts.append(try runSeekReplay(
            workspace: workspace,
            iterations: coverage.seekIterations
        ))
        for _ in 0..<coverage.selectionMeasurementPasses {
            scripts.append(try runSelectionDragReplay(
                workspace: workspace,
                iterations: coverage.dragIterations,
                trackCount: expectedTrackCount
            ))
        }
        scripts.append(try runZoomReplay(
            workspace: workspace,
            iterations: coverage.dragIterations
        ))
        scripts.append(try runPanReplay(
            workspace: workspace,
            iterations: coverage.dragIterations
        ))
        scripts.append(try runDeleteUndoRedoReplay(
            workspace: workspace,
            iterations: coverage.editIterations,
            trackCount: expectedTrackCount
        ))
        scripts.append(try runPasteUndoRedoReplay(
            workspace: workspace,
            iterations: coverage.editIterations,
            trackCount: expectedTrackCount
        ))
        if expectedTrackCount > 1 {
            scripts.append(try runCrossSourcePasteReplay(
                workspace: workspace,
                trackCount: expectedTrackCount
            ))
        }
        scripts.append(try runLoopWrapReplay(workspace: workspace))

        let failures = scripts.flatMap(\.failures)
        return ProjectReport(
            id: manifestProject.id,
            role: manifestProject.role,
            path: projectURL.path,
            expectedTrackCount: expectedTrackCount,
            hasTranscript: hasTranscript,
            coverage: coverage,
            scripts: scripts,
            failures: failures
        )
    }

    private static func runSeekReplay(
        workspace: WorkspaceView,
        iterations: Int
    ) throws -> ReplayScriptReport {
        let viewportSnapshot = workspace.visualInvariantSmokeSnapshot()
        let viewportStart = viewportSnapshot.timelineViewportStartProgress ?? 0
        let viewportDuration = max(
            viewportSnapshot.timelineViewportDurationProgress ?? 1,
            0.000_001
        )
        // A click-to-seek gesture can only target the timeline currently under
        // the pointer. Keep this replay inside the visible viewport; viewport
        // paging and transcript relayout belong to the dedicated pan replay.
        let progressValues = deterministicProgressValues(
            count: iterations,
            low: viewportStart + viewportDuration * 0.03,
            high: viewportStart + viewportDuration * 0.97
        )
        return try runScript(
            name: "rapid-click-to-seek",
            workspace: workspace,
            iterationCount: iterations
        ) { context in
            var results: [WorkspaceUserPerceivedTimingSmokeResult] = []
            for (index, progress) in progressValues.enumerated() {
                try context.check(iteration: index + 1)
                results.append(workspace.userPerceivedTimingSmokeSeek(to: progress))
                // The replay saturates the display cadence without manufacturing
                // hundreds of clicks per second that AppKit could never deliver.
                runMainLoop(milliseconds: 8)
            }
            return (results, [
                .playheadProgress(progressValues.last ?? 0)
            ])
        }
    }

    private static func runSelectionDragReplay(
        workspace: WorkspaceView,
        iterations: Int,
        trackCount: Int
    ) throws -> ReplayScriptReport {
        return try runScript(
            name: "fast-selection-drag-left-right",
            workspace: workspace,
            iterationCount: max(iterations, 1) + 1
        ) { context in
            var results: [WorkspaceUserPerceivedTimingSmokeResult] = []
            let usableTrackCount = max(trackCount, 1)
            let distances = [0.02, 0.08, 0.18, 0.38, 0.24, 0.12, 0.05, 0.015]
            let strokeLength = distances.count
            for index in 0..<max(iterations, 1) {
                try context.check(iteration: index + 1)
                let strokeIndex = index / strokeLength
                let phase = index % strokeLength
                let side: Double = strokeIndex.isMultiple(of: 2) ? 1 : -1
                let anchor = side > 0 ? 0.08 : 0.48
                let edge = anchor + side * distances[phase]
                let previousDistance = phase > 0 ? distances[phase - 1] : 0
                let distanceDelta = distances[phase] - previousDistance
                let motionDirection = side * (distanceDelta >= 0 ? 1 : -1)
                let trackIndex = strokeIndex % usableTrackCount
                results.append(workspace.interactionReplaySmokePublishLiveSelection(
                    trackIndex: trackIndex,
                    startProgress: anchor,
                    endProgress: edge,
                    velocityPixelsPerSecond: distanceDelta >= 0 ? 3_400 : 2_200,
                    motionDirection: motionDirection
                ))
                runMainLoop(milliseconds: 1)
            }
            let finalStrokeIndex = max(iterations - 1, 0) / strokeLength
            let finalTrackIndex = finalStrokeIndex % usableTrackCount
            let finalAnchor = finalStrokeIndex.isMultiple(of: 2) ? 0.08 : 0.48
            results.append(workspace.userPerceivedTimingSmokeCollapseSelection(
                trackIndex: finalTrackIndex,
                at: finalAnchor
            ))
            return (results, [.noSelection])
        }
    }

    private static func runZoomReplay(
        workspace: WorkspaceView,
        iterations: Int
    ) throws -> ReplayScriptReport {
        try runScript(
            name: "zoom-wheel-burst",
            workspace: workspace,
            iterationCount: iterations
        ) { context in
            try context.check(iteration: 1)
            var results = [workspace.userPerceivedTimingSmokeSeek(to: 0.36)]
            for index in 0..<max(iterations, 1) {
                try context.check(iteration: index + 1)
                results.append(workspace.interactionReplaySmokeZoomStep(
                    direction: index.isMultiple(of: 2) ? -1 : 1,
                    around: 0.48
                ))
                runMainLoop(milliseconds: 1)
            }
            return (results, [])
        }
    }

    private static func runPanReplay(
        workspace: WorkspaceView,
        iterations: Int
    ) throws -> ReplayScriptReport {
        try runScript(
            name: "pan-burst",
            workspace: workspace,
            iterationCount: iterations
        ) { context in
            try context.check(iteration: 1)
            return ([
                workspace.interactionReplaySmokePanBurst(
                    stepCount: max(iterations, 1),
                    progressDistance: 0.22
                ),
            ], [])
        }
    }

    private static func runDeleteUndoRedoReplay(
        workspace: WorkspaceView,
        iterations: Int,
        trackCount: Int
    ) throws -> ReplayScriptReport {
        try runScript(
            name: "delete-undo-redo-undo",
            workspace: workspace,
            iterationCount: iterations,
            hotWindowMilliseconds: max(
                ReplayBudgets.hotWindowMilliseconds,
                max(iterations, 1) * (ReplayBudgets.editAnimationSettleMilliseconds + 80)
            )
        ) { context in
            var results: [WorkspaceUserPerceivedTimingSmokeResult] = []
            let usableTrackCount = max(trackCount, 1)
            for index in 0..<max(iterations, 1) {
                try context.check(iteration: index + 1)
                let base = 0.10 + Double(index % 7) * 0.012
                let trackIndex = index % usableTrackCount
                let useGroupScope = usableTrackCount > 1 && index.isMultiple(of: 5)
                results.append(workspace.userPerceivedTimingSmokeSelectRange(
                    trackIndex: trackIndex,
                    startProgress: base,
                    endProgress: min(base + 0.012, 0.95),
                    velocityPixelsPerSecond: 1_800
                ))
                results.append(workspace.userPerceivedTimingSmokeDeleteSelection(useGroupScope: useGroupScope))
                runMainLoop(milliseconds: ReplayBudgets.editAnimationSettleMilliseconds)
                try waitForUndoState(workspace: workspace, context: context, iteration: index + 1)
                results.append(workspace.interactionReplaySmokeUndoLastEdit())
                runMainLoop(milliseconds: 12)
                results.append(workspace.interactionReplaySmokeRedoLastEdit())
                runMainLoop(milliseconds: 12)
                results.append(workspace.interactionReplaySmokeUndoLastEdit())
                runMainLoop(milliseconds: 12)
            }
            return (results, [])
        }
    }

    private static func runPasteUndoRedoReplay(
        workspace: WorkspaceView,
        iterations: Int,
        trackCount: Int
    ) throws -> ReplayScriptReport {
        let usableTrackCount = max(trackCount, 1)
        return try runScript(
            name: "paste-undo-redo-undo",
            workspace: workspace,
            iterationCount: iterations,
            hotWindowMilliseconds: max(
                ReplayBudgets.hotWindowMilliseconds,
                max(iterations, 1) * (ReplayBudgets.editAnimationSettleMilliseconds + 80)
            )
        ) { context in
            var results: [WorkspaceUserPerceivedTimingSmokeResult] = []
            for index in 0..<max(iterations, 1) {
                try context.check(iteration: index + 1)
                let progress = Float(0.16 + Double(index % 9) * 0.009)
                let targetTrackIndex = index % usableTrackCount
                results.append(workspace.userPerceivedTimingSmokeSelectRange(
                    trackIndex: targetTrackIndex,
                    startProgress: 0.08,
                    endProgress: 0.105,
                    velocityPixelsPerSecond: 900
                ))
                results.append(
                    workspace.userPerceivedTimingSmokePrepareClipboardFromSelection()
                )
                results.append(workspace.userPerceivedTimingSmokeSeek(to: progress))
                results.append(workspace.userPerceivedTimingSmokePasteAtPlayhead())
                runMainLoop(milliseconds: ReplayBudgets.editAnimationSettleMilliseconds)
                try waitForUndoState(workspace: workspace, context: context, iteration: index + 1)
                results.append(workspace.interactionReplaySmokeUndoLastEdit())
                runMainLoop(milliseconds: 12)
                results.append(workspace.interactionReplaySmokeRedoLastEdit())
                runMainLoop(milliseconds: 12)
                results.append(workspace.interactionReplaySmokeUndoLastEdit())
                runMainLoop(milliseconds: 12)
            }
            return (results, [])
        }
    }

    private static func runLoopWrapReplay(
        workspace: WorkspaceView
    ) throws -> ReplayScriptReport {
        let startProgress: Float = 0.05
        return try runScript(
            name: "loop-playback-wrap",
            workspace: workspace,
            iterationCount: 1,
            hotWindowMilliseconds: ReplayBudgets.loopWrapMilliseconds + 120
        ) { context in
            try context.check(iteration: 1)
            let setup = workspace.interactionReplaySmokeSetLoopRange(
                startProgress: startProgress,
                durationSeconds: 0.35
            )
            let duration = max(workspace.userPerceivedTimingSmokeSnapshot().projectDuration, 0.001)
            let endProgress = min(startProgress + Float(0.35 / duration), 1)
            let seekProgress = max(startProgress, endProgress - Float(0.10 / duration))
            let seek = workspace.userPerceivedTimingSmokeSeek(to: seekProgress)
            let play = workspace.userPerceivedTimingSmokeStartPlayback()
            runMainLoop(milliseconds: ReplayBudgets.loopWrapMilliseconds)
            let pause = workspace.userPerceivedTimingSmokePausePlayback()
            return ([setup, seek, play, pause], [
                .playheadWithin(startProgress...max(endProgress + 0.004, startProgress + 0.004))
            ])
        }
    }

    private static func runCrossSourcePasteReplay(
        workspace: WorkspaceView,
        trackCount: Int
    ) throws -> ReplayScriptReport {
        let sourceTrackIndex = min(max(trackCount - 1, 1), 2)
        return try runScript(
            name: "cross-source-paste-preparation",
            workspace: workspace,
            iterationCount: 1,
            hotWindowMilliseconds: 30_000
        ) { context in
            var results: [WorkspaceUserPerceivedTimingSmokeResult] = []
            results.append(workspace.userPerceivedTimingSmokeSelectRange(
                trackIndex: sourceTrackIndex,
                startProgress: 0.08,
                endProgress: 0.09,
                velocityPixelsPerSecond: 900
            ))
            results.append(workspace.userPerceivedTimingSmokePrepareClipboardFromSelection(
                includePortableBuffer: true
            ))
            results.append(workspace.userPerceivedTimingSmokeSelectRange(
                trackIndex: 0,
                startProgress: 0.16,
                endProgress: 0.17,
                velocityPixelsPerSecond: 900
            ))
            results.append(workspace.userPerceivedTimingSmokeSeek(to: 0.16))

            let undoDepthBeforePaste = workspace.interactionReplaySmokeUndoDepth()
            results.append(workspace.userPerceivedTimingSmokePasteAtPlayhead())
            while
                workspace.interactionReplaySmokeUndoDepth() <= undoDepthBeforePaste,
                CACurrentMediaTime() <= context.deadline
            {
                try context.check(iteration: 1)
                runMainLoop(milliseconds: 8)
            }
            guard workspace.interactionReplaySmokeUndoDepth() > undoDepthBeforePaste else {
                let snapshot = workspace.visualInvariantSmokeSnapshot()
                throw SmokeError.failed(
                    "cross-source paste did not commit its prepared media transaction " +
                        "(status=\(snapshot.statusText))"
                )
            }
            results.append(workspace.interactionReplaySmokeUndoLastEdit())
            return (results, [])
        }
    }

    private static func runTranscriptReplay(
        workspace: WorkspaceView,
        iterations: Int
    ) throws -> ReplayScriptReport {
        try runScript(
            name: "transcript-hover-click-select",
            workspace: workspace,
            iterationCount: iterations
        ) { context in
            var results: [WorkspaceUserPerceivedTimingSmokeResult] = []
            for index in 0..<max(iterations, 1) {
                try context.check(iteration: index + 1)
                results.append(workspace.interactionReplaySmokeTranscriptHoverClickSelect())
                runMainLoop(milliseconds: 1)
            }
            return (results, [.transcriptSelection])
        }
    }

    private enum ReplayInvariant {
        case playheadProgress(Float)
        case playheadWithin(ClosedRange<Float>)
        case selection(TimelineSelection)
        case noSelection
        case transcriptSelection
    }

    private static func runScript(
        name: String,
        workspace: WorkspaceView,
        iterationCount: Int,
        hotWindowMilliseconds: Int = ReplayBudgets.hotWindowMilliseconds,
        action: (ReplayScriptContext) throws -> ([WorkspaceUserPerceivedTimingSmokeResult], [ReplayInvariant])
    ) throws -> ReplayScriptReport {
        printProgress("  replay script: \(name) (\(iterationCount) iteration(s))")
        try waitForLayoutToSettle(workspace: workspace, script: name)
        workspace.hotPathContractSmokeResetDiagnostics()
        let protectedWindowMilliseconds = max(hotWindowMilliseconds, 1) * 2
        workspace.hotPathContractSmokeBeginFrameStatsWindow(
            duration: Double(protectedWindowMilliseconds) / 1_000
        )

        let startedAt = CACurrentMediaTime()
        let maximumScriptMilliseconds = maximumScriptMilliseconds(
            iterationCount: iterationCount,
            hotWindowMilliseconds: hotWindowMilliseconds
        )
        let context = ReplayScriptContext(
            name: name,
            deadline: startedAt + maximumScriptMilliseconds / 1_000
        )
        let (results, invariants) = try action(context)
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        try waitForFrameStats(workspace: workspace, context: context)
        runMainLoop(milliseconds: ReplayBudgets.renderDrainMilliseconds)

        let hotPathSnapshot = workspace.hotPathContractSmokeSnapshot()
        let finalSnapshot = workspace.visualInvariantSmokeSnapshot()
        if
            hotPathSnapshot.transcriptOverlay.layoutBuildCount > 0,
            let reason = hotPathSnapshot.transcriptOverlay.lastLayoutBuildReason
        {
            printProgress(
                "  replay script: \(name) transcript layout build reason: \(reason)"
            )
        }
        let actions = results.enumerated().map { index, result in
            ReplayScriptReport.Action(
                index: index + 1,
                accepted: result.accepted,
                elapsedMilliseconds: result.elapsedMilliseconds,
                message: result.message,
                editAnimationGenerationChanged: result.editAnimationGenerationChanged,
                expectedLeadingProgress: result.expectedLeadingProgress,
                renderedLeadingProgress: result.renderedLeadingProgress,
                selectionEdgeErrorPixels: result.selectionEdgeErrorPixels,
                motionDirection: result.motionDirection,
                isIntentionalSelectionCollapse: result.isIntentionalSelectionCollapse
            )
        }
        let rejectedActionCount = actions.filter { !$0.accepted }.count
        let intentionalSelectionCollapseCount = actions.filter(\.isIntentionalSelectionCollapse).count
        let motionDirections = actions.compactMap(\.motionDirection).filter { abs($0) > 0.001 }
        let directionReversalCount = zip(motionDirections, motionDirections.dropFirst())
            .filter { pair in pair.0.sign != pair.1.sign }
            .count
        let maxSelectionEdgeErrorPixels = actions.compactMap(\.selectionEdgeErrorPixels).max() ?? 0
        let latencyBudgetedActions = actions.filter {
            shouldEnforceActionLatency(script: name, action: $0)
        }
        let maxActionMilliseconds = latencyBudgetedActions.map(\.elapsedMilliseconds).max() ?? 0
        let slowestAction = actions.max { lhs, rhs in
            lhs.elapsedMilliseconds < rhs.elapsedMilliseconds
        }
        let slowestBudgetedAction = latencyBudgetedActions.max { lhs, rhs in
            lhs.elapsedMilliseconds < rhs.elapsedMilliseconds
        }
        var failures = replayFailures(
            script: name,
            results: results,
            invariants: invariants,
            finalSnapshot: finalSnapshot,
            hotPathSnapshot: hotPathSnapshot
        )
        if name == "fast-selection-drag-left-right" {
            if rejectedActionCount > 0 {
                failures.append("\(name): \(rejectedActionCount) drag action(s) were rejected")
            }
            if intentionalSelectionCollapseCount != 1 {
                failures.append(
                    "\(name): expected one intentional collapse, observed \(intentionalSelectionCollapseCount)"
                )
            }
            if directionReversalCount < ReplayBudgets.minimumSelectionDirectionReversals {
                failures.append(
                    "\(name): expected at least \(ReplayBudgets.minimumSelectionDirectionReversals) direction reversal"
                )
            }
            if maxSelectionEdgeErrorPixels > ReplayBudgets.maximumSelectionEdgeErrorPixels {
                failures.append(String(
                    format: "%@ cursor-to-edge error %.3fpx exceeded %.3fpx",
                    name,
                    maxSelectionEdgeErrorPixels,
                    ReplayBudgets.maximumSelectionEdgeErrorPixels
                ))
            }
        }
        if maxActionMilliseconds > ReplayBudgets.maximumActionMilliseconds {
            if let slowestBudgetedAction {
                failures.append(String(
                    format: "%@ action %d (%@) latency %.3fms exceeded %.3fms",
                    name,
                    slowestBudgetedAction.index,
                    slowestBudgetedAction.message,
                    slowestBudgetedAction.elapsedMilliseconds,
                    ReplayBudgets.maximumActionMilliseconds
                ))
            } else {
                failures.append(String(
                    format: "%@ action latency %.3fms exceeded %.3fms",
                    name,
                    maxActionMilliseconds,
                    ReplayBudgets.maximumActionMilliseconds
                ))
            }
        }
        if elapsedMilliseconds > maximumScriptMilliseconds {
            failures.append(String(
                format: "%@ script runtime %.3fms exceeded %.3fms",
                name,
                elapsedMilliseconds,
                maximumScriptMilliseconds
            ))
        }
        let slowestSummary = slowestBudgetedAction.map {
            String(
                format: ", slowest %.3fms (%@)",
                $0.elapsedMilliseconds,
                $0.message
            )
        } ?? ""
        printProgress(String(
            format: "  replay script: %@ finished in %.1fms with %d failure(s)%@",
            name,
            elapsedMilliseconds,
            failures.count,
            slowestSummary
        ))

        return ReplayScriptReport(
            name: name,
            iterationCount: iterationCount,
            elapsedMilliseconds: elapsedMilliseconds,
            maxActionMilliseconds: maxActionMilliseconds,
            slowestAction: slowestAction,
            actions: actions,
            finalPlayheadProgress: finalSnapshot.playheadProgress,
            finalSelectionStartProgress: finalSnapshot.selectedRangeStartProgress,
            finalSelectionEndProgress: finalSnapshot.selectedRangeEndProgress,
            finalSnapshot: finalSnapshot,
            hotPathSnapshot: hotPathSnapshot,
            rejectedActionCount: rejectedActionCount,
            intentionalSelectionCollapseCount: intentionalSelectionCollapseCount,
            directionReversalCount: directionReversalCount,
            maxSelectionEdgeErrorPixels: maxSelectionEdgeErrorPixels,
            failures: failures
        )
    }

    private static func waitForLayoutToSettle(
        workspace: WorkspaceView,
        script: String
    ) throws {
        let deadline = CACurrentMediaTime() + 1.0
        let requiredStableSeconds: CFTimeInterval = 0.12
        var signature = workspace.hotPathContractSmokeLayoutSignature()
        var stableSince = CACurrentMediaTime()

        while CACurrentMediaTime() <= deadline {
            runMainLoop(milliseconds: 8)
            workspace.hotPathContractSmokeFlushLayout()
            let nextSignature = workspace.hotPathContractSmokeLayoutSignature()
            if nextSignature != signature {
                signature = nextSignature
                stableSince = CACurrentMediaTime()
                continue
            }
            if CACurrentMediaTime() - stableSince >= requiredStableSeconds {
                runMainLoop(milliseconds: ReplayBudgets.renderDrainMilliseconds)
                return
            }
        }

        throw SmokeError.failed(
            "\(script) could not begin because the timeline layout did not settle"
        )
    }

    private static func shouldEnforceActionLatency(
        script: String,
        action: ReplayScriptReport.Action
    ) -> Bool {
        if script == "paste-undo-redo-undo",
           action.message == "clipboard prepared"
        {
            return false
        }
        return true
    }

    private static func replayFailures(
        script: String,
        results: [WorkspaceUserPerceivedTimingSmokeResult],
        invariants: [ReplayInvariant],
        finalSnapshot: WorkspaceVisualInvariantSmokeSnapshot,
        hotPathSnapshot: WorkspaceHotPathContractSmokeSnapshot
    ) -> [String] {
        var failures: [String] = []
        func record(_ condition: Bool, _ message: String) {
            guard !condition else {
                return
            }
            failures.append("\(script): \(message)")
        }

        for (index, result) in results.enumerated() {
            record(result.accepted, "step \(index + 1) was rejected: \(result.message)")
        }

        for invariant in invariants {
            switch invariant {
            case let .playheadProgress(progress):
                record(
                    abs(finalSnapshot.playheadProgress - progress) <= ReplayBudgets.maximumPlayheadProgressError,
                    String(format: "playhead %.6f did not match expected %.6f", finalSnapshot.playheadProgress, progress)
                )
            case let .playheadWithin(range):
                record(
                    range.contains(finalSnapshot.playheadProgress),
                    String(format: "playhead %.6f was outside expected loop range %.6f...%.6f", finalSnapshot.playheadProgress, range.lowerBound, range.upperBound)
                )
            case let .selection(selection):
                record(
                    approximatelyEqual(finalSnapshot.selectedRangeStartProgress, selection.startProgress, tolerance: ReplayBudgets.maximumSelectionProgressError),
                    "selection start did not match the replay cursor anchor"
                )
                record(
                    approximatelyEqual(finalSnapshot.selectedRangeEndProgress, selection.endProgress, tolerance: ReplayBudgets.maximumSelectionProgressError),
                    "selection end did not match the replay cursor edge"
                )
            case .noSelection:
                record(
                    finalSnapshot.selectedRangeStartProgress == nil &&
                        finalSnapshot.selectedRangeEndProgress == nil,
                    "intentional selection collapse left a visible selection"
                )
            case .transcriptSelection:
                record(finalSnapshot.selectedRangeStartProgress != nil, "transcript interaction did not mirror a timeline selection")
            }
        }

        failures.append(contentsOf: hotPathFailures(script: script, snapshot: hotPathSnapshot))
        record(finalSnapshot.blankTrackCount == 0, "replay ended with blank waveform lanes")
        record(finalSnapshot.drawableWaveformTrackCount == finalSnapshot.trackCount, "replay ended without drawable waveforms on every track")
        return failures
    }

    private static func hotPathFailures(
        script: String,
        snapshot: WorkspaceHotPathContractSmokeSnapshot
    ) -> [String] {
        var failures: [String] = []
        func record(_ condition: Bool, _ message: String) {
            guard !condition else {
                return
            }
            failures.append("\(script): \(message)")
        }

        guard let frameStats = snapshot.frameStats else {
            return ["\(script): no timeline frame stats were published during replay"]
        }

        record(frameStats.cpuWaveformVertexCount == 0, "CPU waveform vertices were built")
        record(frameStats.cpuWaveformFallbackDrawCount == 0, "CPU waveform fallback drew")
        record(frameStats.shaderBufferUploadCount == 0, "shader buffer uploads happened")
        record(frameStats.shaderBufferUploadByteCount == 0, "shader buffer bytes were uploaded")
        record(frameStats.shaderBufferUploadInFlightCount == 0, "shader buffer uploads were still in flight")
        record(frameStats.waveformHotPathViolationCount == 0, "renderer reported hot-path violations")
        record(frameStats.effectDroppedVertexCount == 0, "effect vertices were dropped")
        record(!snapshot.isLaunchCacheWriteInFlight, "launch waveform cache write was in flight")
        record(!snapshot.hasPendingLaunchCacheWrite, "launch waveform cache write was pending")
        record(snapshot.mainThreadStallCount == 0, "main-thread stall events were recorded")
        record(
            snapshot.lastMainThreadStallMilliseconds <= 24,
            "main-thread stall exceeded 24ms"
        )

        if snapshot.transcriptOverlay.visibleRunCount > 0 {
            record(
                snapshot.transcriptOverlay.runLayerCount == snapshot.transcriptOverlay.visibleRunCount,
                "transcript compositor layer tree did not match cached transcript runs"
            )
            record(
                snapshot.transcriptOverlay.visibleRunLayerCount ==
                    snapshot.transcriptOverlay.expectedVisibleRunLayerCount,
                "transcript compositor visible layers did not match displayable transcript runs"
            )
        }

        if script == "pan-burst", snapshot.transcriptOverlay.visibleRunCount > 0 {
            record(
                snapshot.transcriptOverlay.layoutBuildCount <= 2,
                "transcript layout rebuilt more than twice during pan"
            )
        } else if script == "zoom-wheel-burst", snapshot.transcriptOverlay.visibleRunCount > 0 {
            record(
                snapshot.transcriptOverlay.layoutBuildCount <= 1,
                "transcript layout rebuilt more than once during zoom"
            )
        } else {
            record(
                snapshot.transcriptOverlay.layoutBuildCount == 0,
                "transcript layout rebuilt outside the bounded pan path"
            )
        }

        let forbiddenEvents = Set([
            "project-autosave-main-thread-snapshot",
            "project-autosave-failed",
            "launch-cache-draft-main-thread-cost",
            "launch-snapshot-save-failed",
            "waveform-hot-path-contract-violation",
        ])
        let forbiddenSeen = snapshot.diagnosticEventNames.filter { forbiddenEvents.contains($0) }
        record(forbiddenSeen.isEmpty, "forbidden replay events occurred: \(forbiddenSeen.joined(separator: ","))")
        return failures
    }

    private static func checkReports(for report: ProjectReport) -> [StabilityCheckReport] {
        if report.failures.isEmpty {
            return [StabilityCheckReport(
                name: "\(report.id) interaction replay",
                status: "passed",
                detail: encodedJSONLine(report)
            )]
        }

        var checks = report.failures.map {
            StabilityCheckReport(
                name: "\(report.id) interaction replay",
                status: "failed",
                detail: $0
            )
        }
        checks.append(StabilityCheckReport(
            name: "\(report.id) interaction replay snapshots",
            status: "failed",
            detail: encodedJSONLine(report)
        ))
        return checks
    }

    private static func replayCoverageChecks(
        reports: [ProjectReport],
        expectedProjects: [FixtureManifest.Project],
        mode: SmokeMode
    ) -> [StabilityCheckReport] {
        let expectedIDs = Set(expectedProjects.map(\.id))
        let reportedIDs = Set(reports.map(\.id))
        var failures: [String] = []
        if expectedIDs != reportedIDs {
            let missing = expectedIDs.subtracting(reportedIDs).sorted()
            failures.append("interaction replay omitted fixture(s): \(missing.joined(separator: ","))")
        }

        let requiredScripts = Set([
            "rapid-click-to-seek",
            "fast-selection-drag-left-right",
            "zoom-wheel-burst",
            "pan-burst",
            "delete-undo-redo-undo",
            "paste-undo-redo-undo",
            "loop-playback-wrap",
        ])
        for report in reports {
            let actualScripts = Set(report.scripts.map(\.name))
            let missingScripts = requiredScripts.subtracting(actualScripts).sorted()
            if !missingScripts.isEmpty {
                failures.append(
                    "\(report.id) omitted replay script(s): \(missingScripts.joined(separator: ","))"
                )
            }
            if report.hasTranscript &&
                !actualScripts.contains("transcript-hover-click-select") {
                failures.append("\(report.id) omitted transcript interaction replay")
            }
            if report.expectedTrackCount > 1 &&
                !actualScripts.contains("cross-source-paste-preparation") {
                failures.append("\(report.id) omitted cross-source paste replay")
            }
        }

        if mode == .stress {
            let canonicalEditProjectIDs = Set([
                "st-ship-project-004",
                "st-ship-project-005",
            ])
            if canonicalEditProjectIDs.isSubset(of: expectedIDs) {
                for projectID in canonicalEditProjectIDs.sorted() {
                    guard let report = reports.first(where: { $0.id == projectID }) else {
                        failures.append("\(projectID) was unavailable for canonical edit stress coverage")
                        continue
                    }
                    for scriptName in ["delete-undo-redo-undo", "paste-undo-redo-undo"] {
                        let iterations = report.scripts
                            .filter { $0.name == scriptName }
                            .map(\.iterationCount)
                            .reduce(0, +)
                        if iterations < 100 {
                            failures.append(
                                "\(projectID) \(scriptName) covered \(iterations) cycles; release coverage requires 100"
                            )
                        }
                    }
                }
            }
            for report in reports {
                let selectionPassCount = report.scripts.filter {
                    $0.name == "fast-selection-drag-left-right"
                }.count
                if selectionPassCount < 3 {
                    failures.append(
                        "\(report.id) recorded \(selectionPassCount) selection sample(s); release coverage requires 3"
                    )
                }
            }
        }

        return [StabilityCheckReport(
            name: "interaction replay coverage matrix",
            status: failures.isEmpty ? "passed" : "failed",
            detail: failures.isEmpty
                ? "all selected fixtures and required stress loops were covered"
                : failures.joined(separator: "\n")
        )]
    }

    private static func aggregateMetadata(
        reports: [ProjectReport],
        mode: SmokeMode,
        fixtureRoot: URL
    ) -> [String: String] {
        let scripts = reports.flatMap(\.scripts)
        let frameStats = scripts.compactMap(\.hotPathSnapshot.frameStats)
        let selectionFrameStats = scripts
            .filter { $0.name == "fast-selection-drag-left-right" }
            .compactMap(\.hotPathSnapshot.frameStats)
        let displayRefreshFramesPerSecond = max(
            NSScreen.main?.maximumFramesPerSecond ?? 120,
            60
        )
        let minimumReplayFramesPerSecond = frameStats.map(\.framesPerSecond).min() ?? 0
        let minimumSelectionFramesPerSecond = selectionFrameStats.map(\.framesPerSecond).min() ?? 0
        let replayFrameRatePercent = frameStats.map(frameRatePercent).min() ?? 0
        let selectionFrameRatePercent = selectionFrameStats.map(frameRatePercent).min() ?? 0
        let selectionJitterValues = selectionFrameStats.map(\.frameTimeJitterMilliseconds)
        let deleteIterationCount = scripts
            .filter { $0.name == "delete-undo-redo-undo" }
            .map(\.iterationCount)
            .reduce(0, +)
        let pasteIterationCount = scripts
            .filter { $0.name == "paste-undo-redo-undo" }
            .map(\.iterationCount)
            .reduce(0, +)
        let metadata: [String: String] = [
            "mode": mode.reportName,
            "fixtureRoot": fixtureRoot.path,
            "projectCount": "\(reports.count)",
            "scriptCount": "\(scripts.count)",
            "iterationCount": "\(scripts.map(\.iterationCount).reduce(0, +))",
            "projects": reports.map(\.id).joined(separator: ","),
            "scripts": scripts.map(\.name).uniquedPreservingOrder().joined(separator: ","),
            "failureCount": "\(reports.flatMap(\.failures).count)",
            "maxReplayActionMilliseconds": String(format: "%.3f", scripts.map(\.maxActionMilliseconds).max() ?? 0),
            "maxReplayScriptMilliseconds": String(format: "%.3f", scripts.map(\.elapsedMilliseconds).max() ?? 0),
            "maxRejectedActions": "\(scripts.map(\.rejectedActionCount).max() ?? 0)",
            "maxSelectionEdgeErrorPixels": String(
                format: "%.3f",
                scripts.map(\.maxSelectionEdgeErrorPixels).max() ?? 0
            ),
            "maxSelectionDirectionReversals": "\(scripts.map(\.directionReversalCount).max() ?? 0)",
            "selectionCollapseValidated": scripts.contains {
                $0.name == "fast-selection-drag-left-right" &&
                    $0.intentionalSelectionCollapseCount == 1
            } ? "1" : "0",
            "selectionMeasurementCount": "\(selectionFrameStats.count)",
            "deleteReplayIterationCount": "\(deleteIterationCount)",
            "pasteReplayIterationCount": "\(pasteIterationCount)",
            "targetDisplayFramesPerSecond": "\(displayRefreshFramesPerSecond)",
            "minReplayFramesPerSecond": "\(minimumReplayFramesPerSecond)",
            "minReplayFrameRatePercent": String(format: "%.3f", replayFrameRatePercent),
            "maxReplayFrameJitterMilliseconds": String(
                format: "%.3f",
                frameStats.map(\.frameTimeJitterMilliseconds).max() ?? 0
            ),
            "maxReplayWorstFrameMilliseconds": String(
                format: "%.3f",
                frameStats.map(\.worstFrameTimeMilliseconds).max() ?? 0
            ),
            "minSelectionDragFramesPerSecond": "\(minimumSelectionFramesPerSecond)",
            "minSelectionDragFrameRatePercent": String(format: "%.3f", selectionFrameRatePercent),
            "maxSelectionDragFrameJitterMilliseconds": String(
                format: "%.3f",
                selectionJitterValues.max() ?? 0
            ),
            "p90SelectionDragFrameJitterMilliseconds": String(
                format: "%.3f",
                percentile(selectionJitterValues, percentile: 0.90)
            ),
            "maxSelectionDragWorstFrameMilliseconds": String(
                format: "%.3f",
                selectionFrameStats.map(\.worstFrameTimeMilliseconds).max() ?? 0
            ),
            "maxCPUWaveformVertices": "\(frameStats.map(\.cpuWaveformVertexCount).max() ?? 0)",
            "maxCPUFallbackDraws": "\(frameStats.map(\.cpuWaveformFallbackDrawCount).max() ?? 0)",
            "maxShaderUploads": "\(frameStats.map(\.shaderBufferUploadCount).max() ?? 0)",
            "maxShaderUploadBytes": "\(frameStats.map(\.shaderBufferUploadByteCount).max() ?? 0)",
            "maxShaderUploadsInFlight": "\(frameStats.map(\.shaderBufferUploadInFlightCount).max() ?? 0)",
            "maxHotPathViolations": "\(frameStats.map(\.waveformHotPathViolationCount).max() ?? 0)",
            "maxDroppedEffectVertices": "\(frameStats.map(\.effectDroppedVertexCount).max() ?? 0)",
            "maxAutosaveScheduled": "\(scripts.contains { $0.hotPathSnapshot.isAutosaveScheduled } ? 1 : 0)",
            "maxLaunchSnapshotWriteScheduled": "\(scripts.contains { $0.hotPathSnapshot.isLaunchSnapshotWriteScheduled } ? 1 : 0)",
            "maxPendingLaunchCacheWrites": "\(scripts.contains { $0.hotPathSnapshot.hasPendingLaunchCacheWrite } ? 1 : 0)",
            "maxLaunchCacheWritesInFlight": "\(scripts.contains { $0.hotPathSnapshot.isLaunchCacheWriteInFlight } ? 1 : 0)",
            "maxMainThreadStallCount": "\(scripts.map(\.hotPathSnapshot.mainThreadStallCount).max() ?? 0)",
            "maxMainThreadStallMs": String(format: "%.3f", scripts.map(\.hotPathSnapshot.lastMainThreadStallMilliseconds).max() ?? 0),
            "maxTranscriptLayoutBuilds": "\(scripts.map(\.hotPathSnapshot.transcriptOverlay.layoutBuildCount).max() ?? 0)",
        ]
        return metadata
    }

    private static func percentile(
        _ values: [Double],
        percentile: Double
    ) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let clampedPercentile = min(max(percentile, 0), 1)
        let index = clampedPercentile * Double(sorted.count - 1)
        let lowerIndex = Int(floor(index))
        let upperIndex = Int(ceil(index))
        guard lowerIndex != upperIndex else {
            return sorted[lowerIndex]
        }
        let fraction = index - Double(lowerIndex)
        return sorted[lowerIndex] * (1 - fraction) +
            sorted[upperIndex] * fraction
    }

    private static func frameRatePercent(
        _ frameStats: WorkspaceHotPathContractFrameStatsSnapshot
    ) -> Double {
        let targetFramesPerSecond = max(
            frameStats.displayRefreshFramesPerSecond,
            1
        )
        return Double(frameStats.framesPerSecond) /
            Double(targetFramesPerSecond) *
            100
    }

    private static func selectedProjects(
        from manifest: FixtureManifest,
        mode: SmokeMode,
        arguments: [String]
    ) -> [FixtureManifest.Project] {
        if let flagIndex = arguments.firstIndex(of: "--project-id"),
           arguments.indices.contains(flagIndex + 1) {
            let requestedID = arguments[flagIndex + 1]
            return manifest.projects.filter { $0.id == requestedID }
        }

        let selectedIDs: Set<String>
        switch mode {
        case .quick:
            selectedIDs = ["st-ship-project-004", "st-ship-project-006"]
        case .standard:
            selectedIDs = ["st-ship-project-003", "st-ship-project-004", "st-ship-project-005", "st-ship-project-006"]
        case .stress:
            selectedIDs = Set(manifest.projects.map(\.id))
        }

        return manifest.projects
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
    }

    private static func installLaunchDefaults(project: SoundtimeProject, projectURL: URL) {
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
    }

    private static func deterministicProgressValues(count: Int, low: Float, high: Float) -> [Float] {
        let count = max(count, 1)
        let span = max(high - low, 0)
        return (0..<count).map { index in
            let mixed = (index * 37 + 11) % max(count, 2)
            let fraction = Float(mixed) / Float(max(count - 1, 1))
            return min(max(low + span * fraction, 0), 1)
        }
    }

    private static func timedMilliseconds(_ work: () -> Void) -> Double {
        let startedAt = CACurrentMediaTime()
        work()
        return (CACurrentMediaTime() - startedAt) * 1_000
    }

    private static func maximumScriptMilliseconds(
        iterationCount: Int,
        hotWindowMilliseconds: Int
    ) -> Double {
        let iterations = max(iterationCount, 1)
        let perIterationAllowance = Double(iterations) * 80
        let protectedWindowAllowance = Double(max(hotWindowMilliseconds, ReplayBudgets.hotWindowMilliseconds))
        return protectedWindowAllowance + perIterationAllowance + 2_500
    }

    private static func waitForUndoState(
        workspace: WorkspaceView,
        context: ReplayScriptContext,
        iteration: Int
    ) throws {
        let deadline = min(
            CACurrentMediaTime() + 0.75,
            context.deadline
        )
        while CACurrentMediaTime() <= deadline {
            if workspace.interactionReplaySmokeHasUndoState() {
                return
            }
            try context.check(iteration: iteration)
            runMainLoop(milliseconds: 8)
        }
    }

    private static func waitForFrameStats(
        workspace: WorkspaceView,
        context: ReplayScriptContext
    ) throws {
        let startedAt = CACurrentMediaTime()
        let minimumStableSampleSeconds = 0.50
        let deadline = min(
            startedAt + max(
                Double(ReplayBudgets.hotWindowMilliseconds) / 1_000,
                minimumStableSampleSeconds + 0.10
            ),
            context.deadline
        )
        while CACurrentMediaTime() <= deadline {
            if CACurrentMediaTime() - startedAt >= minimumStableSampleSeconds,
               workspace.hotPathContractSmokeHasFrameStats()
            {
                return
            }
            try context.check(iteration: 0)
            runMainLoop(milliseconds: 8)
        }
    }

    private static func warmRendererForInteractionReplay(
        workspace: WorkspaceView
    ) throws {
        workspace.hotPathContractSmokeResetDiagnostics()
        workspace.hotPathContractSmokeBeginFrameStatsWindow(duration: 0.55)
        let deadline = CACurrentMediaTime() + 1.2
        while CACurrentMediaTime() <= deadline {
            if workspace.hotPathContractSmokeHasFrameStats() {
                workspace.hotPathContractSmokeResetDiagnostics()
                runMainLoop(milliseconds: 16)
                return
            }
            runMainLoop(milliseconds: 8)
        }
        throw SmokeError.failed("timeline renderer did not publish warmup frame statistics")
    }

    private static func printProgress(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    private static func approximatelyEqual(_ lhs: Double?, _ rhs: Double, tolerance: Double) -> Bool {
        guard let lhs else {
            return false
        }
        return abs(lhs - rhs) <= tolerance
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

    private static func waitUntil(
        timeoutMilliseconds: Double,
        description: String,
        condition: () -> Bool
    ) throws {
        let deadline = CACurrentMediaTime() + timeoutMilliseconds / 1_000
        while CACurrentMediaTime() <= deadline {
            if condition() {
                return
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
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
        } while Date() < deadline
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
}

private extension Array where Element: Hashable {
    func uniquedPreservingOrder() -> [Element] {
        var seen = Set<Element>()
        var result: [Element] = []
        for element in self where seen.insert(element).inserted {
            result.append(element)
        }
        return result
    }
}
