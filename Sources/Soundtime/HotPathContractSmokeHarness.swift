import AppKit
import Foundation
import QuartzCore

@MainActor
enum HotPathContractSmokeHarness {
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

    private struct ScenarioReport: Codable {
        var name: String
        var elapsedMilliseconds: Double
        var snapshot: WorkspaceHotPathContractSmokeSnapshot
        var failures: [String]
    }

    private struct ProjectReport: Codable {
        var id: String
        var role: String
        var path: String
        var expectedTrackCount: Int
        var hasTranscript: Bool
        var scenarios: [ScenarioReport]
        var failures: [String]
    }

    private struct HotPathBudgets {
        static let maximumMainThreadStallMilliseconds: Double = 24
        static let maximumDashboardFrameStatsDisplayMilliseconds: Double = 2.5
        static let maximumDashboardRefreshMilliseconds: Double = 4
        static let hotWindowMilliseconds = 360
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let mode = SmokeMode(arguments: arguments)
        let rootDirectory = try fixtureRoot(arguments: arguments)
        let manifest = try readManifest(rootDirectory: rootDirectory)
        let projects = selectedProjects(from: manifest, mode: mode)
        try require(!projects.isEmpty, "no shippability fixture projects selected for hot-path contract smoke")

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
                let report = try verifyProject(project, rootDirectory: rootDirectory)
                projectReports.append(report)
                checks.append(contentsOf: checkReports(for: report))
            } catch {
                let message = "\(project.id) hot-path contract smoke crashed: \(error)"
                checks.append(StabilityCheckReport(
                    name: "\(project.id) hot-path contract execution",
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
            name: "hot-path-contract-smoke",
            status: status,
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: metadata,
            arguments: arguments
        ) {
            print("wrote hot-path contract report: \(reportURL.path)")
        }

        if !failures.isEmpty {
            throw SmokeError.failed(failures.joined(separator: "\n"))
        }

        print("Soundtime hot-path contract smoke passed: \(projectReports.count) project(s)")
    }

    private static func verifyProject(
        _ manifestProject: FixtureManifest.Project,
        rootDirectory: URL
    ) throws -> ProjectReport {
        let projectURL = rootDirectory.appendingPathComponent(manifestProject.path).standardizedFileURL
        let project = try SoundtimeProjectStore.load(from: projectURL)
        try UserPerceivedTimingSmokeHarness.ensureLaunchCachesForSmoke(project: project, projectURL: projectURL)

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
        let launchPlan = ProjectLaunchCoordinator.resolveLaunchPlanForProject(
            projectURL: projectURL,
            reason: "hot-path-contract-fixture"
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
            description: "\(manifestProject.id) playback did not become ready before hot-path smoke"
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
            runMainLoop(milliseconds: 80)
        }

        var scenarios: [ScenarioReport] = []
        scenarios.append(try runScenario("playback", workspace: workspace) {
            workspace.userPerceivedTimingSmokeStartPlayback()
        } cleanup: {
            _ = workspace.userPerceivedTimingSmokePausePlayback()
        })

        scenarios.append(try runScenario("zoom", workspace: workspace) {
            workspace.hotPathContractSmokeZoomBurst(stepCount: 10, around: 0.42)
            return WorkspaceUserPerceivedTimingSmokeResult(
                accepted: true,
                elapsedMilliseconds: 0,
                message: "zoom burst submitted",
                editAnimationGenerationChanged: false
            )
        })

        scenarios.append(try runScenario("selection-drag", workspace: workspace) {
            workspace.userPerceivedTimingSmokeSelectRange(
                trackIndex: 0,
                startProgress: 0.08,
                endProgress: 0.14,
                velocityPixelsPerSecond: 2_600
            )
        })

        let copySetup = workspace.userPerceivedTimingSmokePrepareClipboardFromSelection()
        try require(copySetup.accepted, "\(manifestProject.id) clipboard prep failed before delete/paste hot-path checks")

        scenarios.append(try runScenario("delete", workspace: workspace) {
            let selectionResult = workspace.userPerceivedTimingSmokeSelectRange(
                trackIndex: 0,
                startProgress: 0.12,
                endProgress: 0.145,
                velocityPixelsPerSecond: 1_200
            )
            guard selectionResult.accepted else {
                return selectionResult
            }
            return workspace.userPerceivedTimingSmokeDeleteSelection()
        })

        let pasteSeek = workspace.userPerceivedTimingSmokeSeek(to: 0.18)
        try require(pasteSeek.accepted, "\(manifestProject.id) paste seek setup failed")
        scenarios.append(try runScenario("paste", workspace: workspace) {
            workspace.userPerceivedTimingSmokePasteAtPlayhead()
        })

        if hasTranscript {
            workspace.hotPathContractSmokeShowTranscriptLayerIfAvailable()
            runMainLoop(milliseconds: 80)
            scenarios.append(try runScenario("transcript-playback", workspace: workspace) {
                let seekResult = workspace.userPerceivedTimingSmokeSeek(to: 0.006)
                guard seekResult.accepted else {
                    return seekResult
                }
                return workspace.userPerceivedTimingSmokeStartPlayback()
            } cleanup: {
                _ = workspace.userPerceivedTimingSmokePausePlayback()
            })
        }

        scenarios.append(try runScenario("development-console-playback", workspace: workspace, showsDevelopmentConsole: true) {
            workspace.userPerceivedTimingSmokeStartPlayback()
        } cleanup: {
            _ = workspace.userPerceivedTimingSmokePausePlayback()
            workspace.hotPathContractSmokeCloseDevelopmentConsole()
        })

        let failures = scenarios.flatMap(\.failures)
        return ProjectReport(
            id: manifestProject.id,
            role: manifestProject.role,
            path: projectURL.path,
            expectedTrackCount: expectedTrackCount,
            hasTranscript: hasTranscript,
            scenarios: scenarios,
            failures: failures
        )
    }

    private static func runScenario(
        _ name: String,
        workspace: WorkspaceView,
        showsDevelopmentConsole: Bool = false,
        action: () -> WorkspaceUserPerceivedTimingSmokeResult,
        cleanup: (() -> Void)? = nil
    ) throws -> ScenarioReport {
        if showsDevelopmentConsole {
            workspace.hotPathContractSmokeShowDevelopmentConsole()
            runMainLoop(milliseconds: 100)
        }

        workspace.hotPathContractSmokeResetDiagnostics()
        workspace.hotPathContractSmokeBeginFrameStatsWindow(
            duration: Double(HotPathBudgets.hotWindowMilliseconds) / 1_000
        )

        let startedAt = CACurrentMediaTime()
        let result = action()
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        try require(result.accepted, "\(name) action was rejected: \(result.message)")
        waitForFrameStats(
            workspace: workspace,
            timeoutMilliseconds: HotPathBudgets.hotWindowMilliseconds
        )

        let snapshot = workspace.hotPathContractSmokeSnapshot()
        cleanup?()
        runMainLoop(milliseconds: 30)

        let failures = contractFailures(
            scenario: name,
            snapshot: snapshot,
            includesDevelopmentConsole: showsDevelopmentConsole
        )
        return ScenarioReport(
            name: name,
            elapsedMilliseconds: max(elapsedMilliseconds, result.elapsedMilliseconds),
            snapshot: snapshot,
            failures: failures
        )
    }

    private static func contractFailures(
        scenario: String,
        snapshot: WorkspaceHotPathContractSmokeSnapshot,
        includesDevelopmentConsole: Bool
    ) -> [String] {
        var failures: [String] = []
        func record(_ condition: Bool, _ message: String) {
            guard !condition else {
                return
            }
            failures.append("\(scenario): \(message)")
        }

        guard let frameStats = snapshot.frameStats else {
            failures.append("\(scenario): no timeline frame stats were published during the hot path")
            return failures
        }

        record(frameStats.cpuWaveformVertexCount == 0, "CPU waveform vertices were built")
        record(frameStats.cpuWaveformFallbackDrawCount == 0, "CPU waveform fallback drew during interaction")
        record(frameStats.shaderBufferUploadCount == 0, "shader buffer uploads happened during interaction")
        record(frameStats.shaderBufferUploadByteCount == 0, "shader buffer bytes were uploaded during interaction")
        record(frameStats.shaderBufferUploadInFlightCount == 0, "shader buffer uploads were still in flight")
        record(frameStats.waveformHotPathViolationCount == 0, "renderer reported hot-path violations")
        record(frameStats.effectDroppedVertexCount == 0, "effect vertices were dropped")
        record(!snapshot.isLaunchCacheWriteInFlight, "launch waveform cache write was in flight")
        record(snapshot.mainThreadStallCount == 0, "main thread stall events were recorded")
        record(
            snapshot.lastMainThreadStallMilliseconds <= HotPathBudgets.maximumMainThreadStallMilliseconds,
            "main thread stall exceeded budget"
        )

        let forbiddenEvents = Set([
            "project-autosave-main-thread-snapshot",
            "project-autosave-failed",
            "launch-cache-draft-main-thread-cost",
            "launch-cache-write-started",
            "launch-snapshot-save-failed",
            "waveform-hot-path-contract-violation",
        ])
        let forbiddenSeen = snapshot.diagnosticEventNames.filter { forbiddenEvents.contains($0) }
        record(forbiddenSeen.isEmpty, "forbidden hot-path events occurred: \(forbiddenSeen.joined(separator: ","))")

        if scenario.contains("transcript") || snapshot.transcriptOverlay.visibleRunCount > 0 {
            let layoutLimit = scenario == "zoom" ? 1 : 0
            record(
                snapshot.transcriptOverlay.layoutBuildCount <= layoutLimit,
                "transcript layout rebuilt \(snapshot.transcriptOverlay.layoutBuildCount)x during hot frames"
            )
        }

        if includesDevelopmentConsole {
            record(
                snapshot.performanceDashboard.frameStatsDisplayCount > 0,
                "Development Console did not receive frame stats while visible"
            )
            record(
                snapshot.performanceDashboard.maxFrameStatsDisplayMilliseconds <= HotPathBudgets.maximumDashboardFrameStatsDisplayMilliseconds,
                "Development Console frame display exceeded budget"
            )
            record(
                snapshot.performanceDashboard.maxRefreshRequestMilliseconds <= HotPathBudgets.maximumDashboardRefreshMilliseconds,
                "Development Console refresh exceeded budget"
            )
        }

        return failures
    }

    private static func checkReports(for report: ProjectReport) -> [StabilityCheckReport] {
        if report.failures.isEmpty {
            return [StabilityCheckReport(
                name: "\(report.id) hot-path contracts",
                status: "passed",
                detail: encodedJSONLine(report)
            )]
        }

        var checks = report.failures.map {
            StabilityCheckReport(
                name: "\(report.id) hot-path contract",
                status: "failed",
                detail: $0
            )
        }
        checks.append(StabilityCheckReport(
            name: "\(report.id) hot-path contract snapshots",
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
            selectedIDs = ["st-ship-project-004", "st-ship-project-006"]
        case .standard:
            selectedIDs = Set(manifest.projects.map(\.id)).subtracting(["st-ship-project-007"])
        case .stress:
            selectedIDs = Set(manifest.projects.map(\.id))
        }

        return manifest.projects
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
    }

    private static func aggregateMetadata(
        reports: [ProjectReport],
        mode: SmokeMode,
        fixtureRoot: URL
    ) -> [String: String] {
        let scenarioReports = reports.flatMap(\.scenarios)
        let frameStats = scenarioReports.compactMap(\.snapshot.frameStats)
        let dashboardSnapshots = scenarioReports.map(\.snapshot.performanceDashboard)
        var metadata: [String: String] = [
            "mode": "\(mode)",
            "fixtureRoot": fixtureRoot.path,
            "projectCount": "\(reports.count)",
            "scenarioCount": "\(scenarioReports.count)",
            "projects": reports.map(\.id).joined(separator: ","),
            "failureCount": "\(reports.flatMap(\.failures).count)",
            "maxCPUWaveformVertices": "\(frameStats.map(\.cpuWaveformVertexCount).max() ?? 0)",
            "maxCPUFallbackDraws": "\(frameStats.map(\.cpuWaveformFallbackDrawCount).max() ?? 0)",
            "maxShaderUploads": "\(frameStats.map(\.shaderBufferUploadCount).max() ?? 0)",
            "maxShaderUploadBytes": "\(frameStats.map(\.shaderBufferUploadByteCount).max() ?? 0)",
            "maxShaderUploadsInFlight": "\(frameStats.map(\.shaderBufferUploadInFlightCount).max() ?? 0)",
            "maxHotPathViolations": "\(frameStats.map(\.waveformHotPathViolationCount).max() ?? 0)",
            "maxTranscriptLayoutBuilds": "\(scenarioReports.map(\.snapshot.transcriptOverlay.layoutBuildCount).max() ?? 0)",
            "maxMainThreadStallCount": "\(scenarioReports.map(\.snapshot.mainThreadStallCount).max() ?? 0)",
            "maxMainThreadStallMs": String(format: "%.3f", scenarioReports.map(\.snapshot.lastMainThreadStallMilliseconds).max() ?? 0),
            "maxDashboardFrameDisplayMs": String(
                format: "%.3f",
                dashboardSnapshots.map(\.maxFrameStatsDisplayMilliseconds).max() ?? 0
            ),
            "maxDashboardRefreshMs": String(
                format: "%.3f",
                dashboardSnapshots.map(\.maxRefreshRequestMilliseconds).max() ?? 0
            ),
        ]
        metadata["scenarios"] = scenarioReports.map(\.name).uniquedPreservingOrder().joined(separator: ",")
        return metadata
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

    @discardableResult
    private static func waitForFrameStats(
        workspace: WorkspaceView,
        timeoutMilliseconds: Int
    ) -> Bool {
        let deadline = CACurrentMediaTime() + Double(max(timeoutMilliseconds, 1)) / 1_000
        while CACurrentMediaTime() <= deadline {
            if workspace.hotPathContractSmokeHasFrameStats() {
                return true
            }
            workspace.hotPathContractSmokeBeginFrameStatsWindow(duration: 0.12)
            runMainLoop(milliseconds: 8)
        }
        return workspace.hotPathContractSmokeHasFrameStats()
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
