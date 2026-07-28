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

        var editIterations: Int {
            switch self {
            case .quick: return 8
            case .standard: return 24
            case .stress: return 150
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

    private struct ReplayScriptReport: Codable {
        struct Action: Codable {
            var index: Int
            var accepted: Bool
            var elapsedMilliseconds: Double
            var message: String
            var editAnimationGenerationChanged: Bool
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
        var failures: [String]
    }

    private struct ProjectReport: Codable {
        var id: String
        var role: String
        var path: String
        var expectedTrackCount: Int
        var hasTranscript: Bool
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
        let projects = selectedProjects(from: manifest, mode: mode)
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
                let report = try verifyProject(project, rootDirectory: rootDirectory, mode: mode)
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
        try waitUntil(
            timeoutMilliseconds: 8_000,
            description: "\(manifestProject.id) playback did not become ready before interaction replay"
        ) {
            let snapshot = workspace.hotPathContractSmokeSnapshot()
            return snapshot.playbackHasSource &&
                snapshot.playbackPrimedTrackCount == expectedTrackCount &&
                snapshot.drawableWaveformTrackCount == expectedTrackCount &&
                !snapshot.isLoadingProject &&
                workspace.hotPathContractSmokeIsProjectFullyHydrated()
        }

        let hasTranscript = project.tracks.contains { $0.transcript != nil }
        if hasTranscript {
            workspace.hotPathContractSmokeShowTranscriptLayerIfAvailable()
            runMainLoop(milliseconds: 90)
        }

        var scripts: [ReplayScriptReport] = []
        if hasTranscript {
            scripts.append(try runTranscriptReplay(workspace: workspace, iterations: min(mode.dragIterations, 24)))
        }
        scripts.append(try runSeekReplay(workspace: workspace, iterations: mode.seekIterations))
        scripts.append(try runSelectionDragReplay(
            workspace: workspace,
            iterations: mode.dragIterations,
            trackCount: expectedTrackCount
        ))
        scripts.append(try runZoomReplay(workspace: workspace, iterations: mode.dragIterations))
        scripts.append(try runPanReplay(workspace: workspace, iterations: mode.dragIterations))
        scripts.append(try runDeleteUndoReplay(
            workspace: workspace,
            iterations: mode.editIterations,
            trackCount: expectedTrackCount
        ))
        scripts.append(try runPasteUndoReplay(
            workspace: workspace,
            iterations: mode.editIterations,
            trackCount: expectedTrackCount
        ))
        scripts.append(try runLoopWrapReplay(workspace: workspace))

        let failures = scripts.flatMap(\.failures)
        return ProjectReport(
            id: manifestProject.id,
            role: manifestProject.role,
            path: projectURL.path,
            expectedTrackCount: expectedTrackCount,
            hasTranscript: hasTranscript,
            scripts: scripts,
            failures: failures
        )
    }

    private static func runSeekReplay(
        workspace: WorkspaceView,
        iterations: Int
    ) throws -> ReplayScriptReport {
        let progressValues = deterministicProgressValues(count: iterations, low: 0.02, high: 0.92)
        return try runScript(
            name: "rapid-click-to-seek",
            workspace: workspace,
            iterationCount: iterations
        ) { context in
            var results: [WorkspaceUserPerceivedTimingSmokeResult] = []
            for (index, progress) in progressValues.enumerated() {
                try context.check(iteration: index + 1)
                results.append(workspace.userPerceivedTimingSmokeSeek(to: progress))
                runMainLoop(milliseconds: 1)
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
        try runScript(
            name: "fast-selection-drag-left-right",
            workspace: workspace,
            iterationCount: iterations
        ) { context in
            var results: [WorkspaceUserPerceivedTimingSmokeResult] = []
            var finalSelection: TimelineSelection?
            let usableTrackCount = max(trackCount, 1)
            for index in 0..<max(iterations, 1) {
                try context.check(iteration: index + 1)
                let phaseInStroke = Double((index % 12) + 1) / 12.0
                let expanding = (index / 12).isMultiple(of: 2)
                let rightward = (index / 6).isMultiple(of: 2)
                let easedPhase = expanding ? phaseInStroke : 1 - phaseInStroke
                let trackIndex = index % usableTrackCount
                let anchor = rightward ? 0.08 : 0.48
                let edge = rightward ? 0.08 + easedPhase * 0.38 : 0.48 - easedPhase * 0.38
                let selection = TimelineSelection(startProgress: anchor, endProgress: edge)
                finalSelection = selection
                results.append(workspace.userPerceivedTimingSmokeSelectRange(
                    trackIndex: trackIndex,
                    startProgress: anchor,
                    endProgress: edge,
                    velocityPixelsPerSecond: expanding ? 3_400 : 2_200
                ))
                runMainLoop(milliseconds: 1)
            }
            let invariants: [ReplayInvariant] = finalSelection.map { [.selection($0)] } ?? []
            return (results, invariants)
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
            let results = [
                workspace.userPerceivedTimingSmokeSeek(to: 0.36),
                WorkspaceUserPerceivedTimingSmokeResult(
                    accepted: true,
                    elapsedMilliseconds: timedMilliseconds {
                        workspace.hotPathContractSmokeZoomBurst(stepCount: max(iterations, 1), around: 0.48)
                    },
                    message: "zoom burst submitted",
                    editAnimationGenerationChanged: false
                ),
            ]
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

    private static func runDeleteUndoReplay(
        workspace: WorkspaceView,
        iterations: Int,
        trackCount: Int
    ) throws -> ReplayScriptReport {
        try runScript(
            name: "delete-undo-delete",
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
            }
            return (results, [])
        }
    }

    private static func runPasteUndoReplay(
        workspace: WorkspaceView,
        iterations: Int,
        trackCount: Int
    ) throws -> ReplayScriptReport {
        try runScript(
            name: "paste-undo-paste",
            workspace: workspace,
            iterationCount: iterations,
            hotWindowMilliseconds: max(
                ReplayBudgets.hotWindowMilliseconds,
                max(iterations, 1) * (ReplayBudgets.editAnimationSettleMilliseconds + 80)
            )
        ) { context in
            var results: [WorkspaceUserPerceivedTimingSmokeResult] = []
            let usableTrackCount = max(trackCount, 1)
            let clipboardTrackIndex = min(max(usableTrackCount - 1, 0), 2)
            results.append(workspace.userPerceivedTimingSmokeSelectRange(
                trackIndex: clipboardTrackIndex,
                startProgress: 0.08,
                endProgress: 0.105,
                velocityPixelsPerSecond: 1_200
            ))
            results.append(workspace.userPerceivedTimingSmokePrepareClipboardFromSelection(
                includePortableBuffer: true
            ))
            for index in 0..<max(iterations, 1) {
                try context.check(iteration: index + 1)
                let progress = Float(0.16 + Double(index % 9) * 0.009)
                let targetTrackIndex = index % usableTrackCount
                results.append(workspace.userPerceivedTimingSmokeSelectRange(
                    trackIndex: targetTrackIndex,
                    startProgress: Double(progress),
                    endProgress: Double(min(progress + 0.01, 0.95)),
                    velocityPixelsPerSecond: 900
                ))
                results.append(workspace.userPerceivedTimingSmokeSeek(to: progress))
                results.append(workspace.userPerceivedTimingSmokePasteAtPlayhead())
                runMainLoop(milliseconds: ReplayBudgets.editAnimationSettleMilliseconds)
                try waitForUndoState(workspace: workspace, context: context, iteration: index + 1)
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
        runMainLoop(milliseconds: ReplayBudgets.renderDrainMilliseconds)
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
        let actions = results.enumerated().map { index, result in
            ReplayScriptReport.Action(
                index: index + 1,
                accepted: result.accepted,
                elapsedMilliseconds: result.elapsedMilliseconds,
                message: result.message,
                editAnimationGenerationChanged: result.editAnimationGenerationChanged
            )
        }
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
        printProgress(String(
            format: "  replay script: %@ finished in %.1fms with %d failure(s)",
            name,
            elapsedMilliseconds,
            failures.count
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
            failures: failures
        )
    }

    private static func shouldEnforceActionLatency(
        script: String,
        action: ReplayScriptReport.Action
    ) -> Bool {
        if script == "paste-undo-paste",
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

    private static func aggregateMetadata(
        reports: [ProjectReport],
        mode: SmokeMode,
        fixtureRoot: URL
    ) -> [String: String] {
        let scripts = reports.flatMap(\.scripts)
        let frameStats = scripts.compactMap(\.hotPathSnapshot.frameStats)
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

    private static func selectedProjects(
        from manifest: FixtureManifest,
        mode: SmokeMode
    ) -> [FixtureManifest.Project] {
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
        let deadline = min(
            CACurrentMediaTime() + Double(ReplayBudgets.hotWindowMilliseconds) / 1_000,
            context.deadline
        )
        while CACurrentMediaTime() <= deadline {
            if workspace.hotPathContractSmokeHasFrameStats() {
                return
            }
            workspace.hotPathContractSmokeBeginFrameStatsWindow(duration: 0.12)
            try context.check(iteration: 0)
            runMainLoop(milliseconds: 8)
        }
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
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.004))
        }
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
