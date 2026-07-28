import Darwin
import Foundation

enum ShippabilityGateHarness {
    private static let gateReportSchemaVersion = 7
    private static let featureDoneProductBarCommand = "swift build && swift run Soundtime --product-bar"
    private static let releaseCandidateProductBarCommand = "swift build && swift run Soundtime --release-candidate-gate"
    private static let productBarRule = "Feature work is not done until the feature-done product bar passes; release candidates require the release-candidate product bar with zero failures, zero budget warnings, and zero regression warnings."

    private enum GateMode: String, Codable {
        case quick
        case standard
        case full

        init(arguments: [String]) {
            if arguments.contains("--full") || arguments.contains("--stress") {
                self = .full
            } else if arguments.contains("--quick") {
                self = .quick
            } else if arguments.contains("--standard") {
                self = .standard
            } else {
                self = .standard
            }
        }

        var description: String {
            switch self {
            case .quick:
                return "daily guard for fast local iteration"
            case .standard:
                return "broad local shippability coverage"
            case .full:
                return "release/stress coverage with heavier checks"
            }
        }

        var targetRuntimeMilliseconds: Double {
            switch self {
            case .quick:
                return 60_000
            case .standard:
                return 300_000
            case .full:
                return 900_000
            }
        }

        var warningRuntimeMilliseconds: Double {
            switch self {
            case .quick:
                return 54_000
            case .standard:
                return 240_000
            case .full:
                return 720_000
            }
        }

        var childTierArguments: [String] {
            switch self {
            case .quick:
                return ["--quick"]
            case .standard:
                return []
            case .full:
                return ["--stress"]
            }
        }
    }

    private enum GatePurpose: String, Codable {
        case manual
        case featureDone = "feature_done"
        case releaseCandidate = "release_candidate"

        init(arguments: [String]) throws {
            let featureDoneRequested = arguments.contains("--product-bar") || arguments.contains("--feature-gate")
            let releaseCandidateRequested = arguments.contains("--release-candidate-gate") || arguments.contains("--rc-gate")
            if featureDoneRequested && releaseCandidateRequested {
                throw GateError.invalidOptions("Use either --product-bar or --release-candidate-gate, not both.")
            }
            if releaseCandidateRequested {
                self = .releaseCandidate
            } else if featureDoneRequested {
                self = .featureDone
            } else {
                self = .manual
            }
        }

        var displayName: String {
            switch self {
            case .manual:
                return "manual shippability run"
            case .featureDone:
                return "feature-done product bar"
            case .releaseCandidate:
                return "release-candidate product bar"
            }
        }

        var description: String {
            switch self {
            case .manual:
                return "Manual tier run. Useful for diagnostics, but the named product-bar commands are the source of truth for feature and release readiness."
            case .featureDone:
                return "Required before calling a feature done. Runs the quick gate after Swift builds the current source."
            case .releaseCandidate:
                return "Required before treating a build as a release candidate. Runs the full gate after Swift builds the current source."
            }
        }

        var blocksOnWarnings: Bool {
            switch self {
            case .manual, .featureDone:
                return false
            case .releaseCandidate:
                return true
            }
        }

        func resolvedMode(requestedMode: GateMode, arguments: [String]) throws -> GateMode {
            let explicitQuick = arguments.contains("--quick")
            let explicitStandard = arguments.contains("--standard")
            let explicitFull = arguments.contains("--full") || arguments.contains("--stress")
            switch self {
            case .manual:
                return requestedMode
            case .featureDone:
                if explicitStandard || explicitFull {
                    throw GateError.invalidOptions("--product-bar always runs the quick feature-done gate. Remove --standard/--full/--stress.")
                }
                return .quick
            case .releaseCandidate:
                if explicitQuick || explicitStandard {
                    throw GateError.invalidOptions("--release-candidate-gate always runs the full release gate. Remove --quick/--standard.")
                }
                return .full
            }
        }

        func decision(
            for status: String,
            budgetFailureCount: Int,
            budgetWarningCount: Int,
            regressionWarningCount: Int
        ) -> String {
            switch self {
            case .manual:
                if status == "passed", budgetFailureCount == 0 {
                    return "Manual gate passed. Use the named product-bar command before declaring feature or release readiness."
                }
                return "Manual gate failed. Fix the failures before running the matching product-bar command."
            case .featureDone:
                if status == "passed", budgetFailureCount == 0 {
                    return "Feature-done bar passed. This change is eligible to be called done."
                }
                return "Feature-done bar failed. This change is not done."
            case .releaseCandidate:
                if status == "passed",
                   budgetFailureCount == 0,
                   budgetWarningCount == 0,
                   regressionWarningCount == 0
                {
                    return "Release-candidate bar passed. This build is eligible for release-candidate review."
                }
                return "Release-candidate bar failed. Release candidates must have zero failures, zero budget warnings, and zero regression warnings."
            }
        }
    }

    private enum PhaseKind {
        case fixtures
        case commands([GateCommand])
    }

    private struct GatePhase {
        var name: String
        var detail: String
        var kind: PhaseKind
    }

    private struct GateCommand {
        var label: String
        var arguments: [String]
        var modes: Set<GateMode>
        var required: Bool

        func runs(in mode: GateMode) -> Bool {
            modes.contains(mode)
        }
    }

    private struct GateReport: Codable {
        var schemaVersion: Int
        var status: String
        var generatedAt: Date
        var durationMilliseconds: Double
        var mode: String
        var tierDescription: String?
        var targetRuntimeMilliseconds: Double?
        var productBar: String?
        var productBarDescription: String?
        var productBarDecision: String?
        var productBarRule: String?
        var featureDoneCommand: String?
        var releaseCandidateCommand: String?
        var fixtureRoot: String
        var fixtureStrategy: String
        var keptFixtures: Bool
        var reportRoot: String
        var runDirectory: String
        var runReportPath: String?
        var latestReportPath: String?
        var markdownReportPath: String?
        var latestMarkdownReportPath: String?
        var traceBundlePath: String?
        var gitCommit: String?
        var commandLine: String
        var thresholds: GateThresholds
        var budgetFailureCount: Int
        var budgetWarningCount: Int
        var regressionWarnings: [String]
        var phases: [GatePhaseReport]
    }

    private struct GateThresholds: Codable {
        var firstWindowVisibleMilliseconds: Double
        var firstWaveformVisibleMilliseconds: Double
        var firstPlaybackReadyMilliseconds: Double
        var maxMainThreadStallMilliseconds: Double
        var maxTimelineFallbackDraws: Int
        var maxAudioUnderruns: Int
        var minPlaybackFramesPerSecond: Double
        var minSelectionDragFramesPerSecond: Double

        static let production = GateThresholds(
            firstWindowVisibleMilliseconds: ShippabilityTimingBudgets.windowVisible.failureMilliseconds,
            firstWaveformVisibleMilliseconds: ShippabilityTimingBudgets.firstWaveformVisible.failureMilliseconds,
            firstPlaybackReadyMilliseconds: ShippabilityTimingBudgets.playbackReady.failureMilliseconds,
            maxMainThreadStallMilliseconds: 16,
            maxTimelineFallbackDraws: 0,
            maxAudioUnderruns: 0,
            minPlaybackFramesPerSecond: 120,
            minSelectionDragFramesPerSecond: 120
        )
    }

    private struct GatePhaseReport: Codable {
        var name: String
        var status: String
        var durationMilliseconds: Double
        var detail: String
        var metrics: [String: String]
        var warnings: [String]
        var failureMessage: String?
        var budgetFindings: [GateBudgetFinding] = []
        var checks: [GateCheckReport]
    }

    private struct GateCheckReport: Codable {
        var label: String
        var status: String
        var durationMilliseconds: Double
        var exitCode: Int32?
        var commandLine: String?
        var logPath: String?
        var stabilityReportPaths: [String] = []
        var metrics: [String: String] = [:]
        var budgetFindings: [GateBudgetFinding] = []
        var outputTail: String?
        var userVisibleRisk: String?
        var failureSummary: String?
    }

    private struct GateBudgetFinding: Codable {
        var severity: String
        var suiteName: String
        var metric: String
        var actual: String
        var threshold: String
        var unit: String
        var message: String
        var userVisibleRisk: String? = nil
    }

    private struct GateReportArtifacts {
        var runReportURL: URL
        var latestReportURL: URL
        var runMarkdownURL: URL
        var latestMarkdownURL: URL
    }

    private struct GateIssueSummary: Codable {
        var severity: String
        var phaseName: String
        var checkLabel: String?
        var suiteName: String?
        var metric: String?
        var actual: String?
        var threshold: String?
        var unit: String?
        var message: String
        var userVisibleRisk: String
        var logPath: String?
        var stabilityReportPaths: [String]
        var outputTail: String?
        var diagnosticHint: String? = nil
    }

    private struct GateTraceBundle: Codable {
        var schemaVersion: Int
        var generatedAt: Date
        var status: String
        var mode: String
        var productBar: String?
        var productBarDecision: String?
        var failureCount: Int
        var warningCount: Int
        var primaryFailure: GateIssueSummary?
        var commandLine: String
        var reportPath: String
        var markdownReportPath: String
        var runDirectory: String
        var fixtureRoot: String
        var failures: [GateIssueSummary]
        var warnings: [GateIssueSummary]
        var logs: [String]
        var stabilityReports: [String]
        var rerunCommand: String
    }

    private struct FixtureManifestSummary: Decodable {
        struct Entry: Decodable {
            var id: String
            var path: String
            var format: String?
            var durationSeconds: Double?
            var trackCount: Int?
            var projectReady: Bool?
            var importExpectation: String?
        }

        var supportedImportFormatsCovered: [String]
        var recognizedUnsupportedFormatsCovered: [String]
        var audio: [Entry]
        var projects: [Entry]
    }

    private struct ChildStabilityReport {
        var url: URL
        var report: StabilitySuiteReport
    }

    private struct TimelinePerfPayload {
        var scenario: String
        var renderer: String?
        var trackCount: Int?
        var cpuWaveformVertices: Int?
        var dropped144HzFrames: Int?
        var dropped60HzFrames: Int?
        var effectVerticesDropped: Int?
        var shaderUploads: Int?
        var shaderUploadsInFlight: Int?
        var waveformRefresh: Bool?
        var cpuSubmitP95Milliseconds: Double?
        var gpuP95Milliseconds: Double?
    }

    private enum GateError: LocalizedError {
        case failed(URL)
        case selfTestFailed(String)
        case executableUnavailable(String)
        case invalidOptions(String)

        var errorDescription: String? {
            switch self {
            case let .failed(reportURL):
                return "shippability gate failed; report written to \(reportURL.path)"
            case let .selfTestFailed(message):
                return message
            case let .executableUnavailable(path):
                return "shippability gate could not resolve executable: \(path)"
            case let .invalidOptions(message):
                return message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        if arguments.contains("--help") || arguments.contains("-h") {
            printHelp()
            return
        }

        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let purpose = try GatePurpose(arguments: arguments)
        let requestedMode = GateMode(arguments: arguments)
        let mode = try purpose.resolvedMode(requestedMode: requestedMode, arguments: arguments)
        let executableURL = try currentExecutableURL(arguments: arguments)
        let reportRoot = reportRootDirectory(arguments: arguments)
        let runID = timestampSlug()
        let runDirectory = reportRoot.appendingPathComponent("runs/\(runID)", isDirectory: true)
        let logDirectory = runDirectory.appendingPathComponent("logs", isDirectory: true)
        let stabilityReportDirectory = runDirectory.appendingPathComponent("stability-reports", isDirectory: true)
        let explicitFixtureRoot = explicitFixtureOutput(arguments: arguments)
        let usesDisposableFixtures = arguments.contains("--disposable-fixtures")
        let rebuildFixtures = arguments.contains("--rebuild-fixtures")
        let fixtureRoot = explicitFixtureRoot ??
            (usesDisposableFixtures
                ? runDirectory.appendingPathComponent("fixtures/v1", isDirectory: true)
                : defaultFixtureCacheDirectory())
        let fixtureStrategy: String
        if explicitFixtureRoot != nil {
            fixtureStrategy = rebuildFixtures ? "explicit-rebuild" : "explicit-reuse"
        } else if usesDisposableFixtures {
            fixtureStrategy = "disposable-rebuild"
        } else {
            fixtureStrategy = rebuildFixtures ? "cached-rebuild" : "cached-reuse"
        }
        let keepFixtures = arguments.contains("--keep-fixtures") || explicitFixtureRoot != nil || !usesDisposableFixtures

        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stabilityReportDirectory, withIntermediateDirectories: true)
        let previousLatestReport = loadPreviousLatestReport(reportRoot: reportRoot)

        print("Soundtime Shippability Gate")
        print("product bar: \(purpose.displayName)")
        print("mode: \(mode.rawValue) - \(mode.description)")
        print("target: \(String(format: "%.0fs", mode.targetRuntimeMilliseconds / 1_000))")
        if purpose != .manual {
            print("required command: \(purpose == .featureDone ? featureDoneProductBarCommand : releaseCandidateProductBarCommand)")
        }
        print("fixtures: \(fixtureRoot.path) (\(fixtureStrategy), \(keepFixtures ? "kept" : "disposable"))")
        print("reports: \(reportRoot.path)")
        fflush(stdout)

        let phases = makePhases()
        var phaseReports: [GatePhaseReport] = []
        var shouldContinue = true

        for (index, phase) in phases.enumerated() {
            guard shouldContinue else {
                let skipped = GatePhaseReport(
                    name: phase.name,
                    status: "skipped",
                    durationMilliseconds: 0,
                    detail: phase.detail,
                    metrics: [:],
                    warnings: [],
                    failureMessage: "Skipped because fixture setup failed.",
                    checks: []
                )
                phaseReports.append(skipped)
                print(formatPhaseLine(status: "SKIP", name: phase.name, milliseconds: 0))
                continue
            }

            let report: GatePhaseReport
            switch phase.kind {
            case .fixtures:
                report = runFixturePhase(
                    phase: phase,
                    fixtureRoot: fixtureRoot,
                    rebuildFixtures: rebuildFixtures || usesDisposableFixtures,
                    mode: mode
                )
                if report.status == "failed" {
                    shouldContinue = false
                }
            case let .commands(commands):
                report = runCommandPhase(
                    phaseIndex: index + 1,
                    phase: phase,
                    commands: commands.filter { $0.runs(in: mode) },
                    executableURL: executableURL,
                    logDirectory: logDirectory,
                    stabilityReportDirectory: stabilityReportDirectory,
                    fixtureRoot: fixtureRoot,
                    mode: mode
                )
            }

            phaseReports.append(report)
            print(formatPhaseLine(
                status: report.status == "passed" ? "PASS" : report.status == "failed" ? "FAIL" : "SKIP",
                name: phase.name,
                milliseconds: report.durationMilliseconds
            ))
            if let failureMessage = report.failureMessage {
                print("  \(failureMessage)")
            }
            fflush(stdout)
        }

        cleanupFixturesIfNeeded(rootDirectory: fixtureRoot, keepFixtures: keepFixtures)

        let totalDurationMilliseconds = elapsedMilliseconds(since: startedAtNanoseconds)
        if let runtimePhase = gateRuntimePhase(
            mode: mode,
            durationMilliseconds: totalDurationMilliseconds,
            phaseReports: phaseReports
        ) {
            phaseReports.append(runtimePhase)
        }

        let failedPhases = phaseReports.filter { $0.status == "failed" }
        let allBudgetFindings = phaseReports.flatMap(\.budgetFindings)
        let budgetFailureCount = allBudgetFindings.filter { $0.severity == "failure" }.count
        let budgetWarningCount = allBudgetFindings.filter { $0.severity == "warning" }.count
        let regressionWarnings = regressionWarnings(
            previous: previousLatestReport,
            mode: mode.rawValue,
            currentPhases: phaseReports
        )
        let warningBlockerCount = purpose.blocksOnWarnings ? budgetWarningCount + regressionWarnings.count : 0
        let status = failedPhases.isEmpty && budgetFailureCount == 0 && warningBlockerCount == 0 ? "passed" : "failed"
        let failureBundleURL = status == "failed"
            ? reportRoot.appendingPathComponent("failures/\(runID)", isDirectory: true)
            : nil
        var report = GateReport(
            schemaVersion: gateReportSchemaVersion,
            status: status,
            generatedAt: Date(),
            durationMilliseconds: totalDurationMilliseconds,
            mode: mode.rawValue,
            tierDescription: mode.description,
            targetRuntimeMilliseconds: mode.targetRuntimeMilliseconds,
            productBar: purpose.rawValue,
            productBarDescription: purpose.description,
            productBarDecision: purpose.decision(
                for: status,
                budgetFailureCount: budgetFailureCount,
                budgetWarningCount: budgetWarningCount,
                regressionWarningCount: regressionWarnings.count
            ),
            productBarRule: productBarRule,
            featureDoneCommand: featureDoneProductBarCommand,
            releaseCandidateCommand: releaseCandidateProductBarCommand,
            fixtureRoot: fixtureRoot.path,
            fixtureStrategy: fixtureStrategy,
            keptFixtures: keepFixtures,
            reportRoot: reportRoot.path,
            runDirectory: runDirectory.path,
            runReportPath: nil,
            latestReportPath: nil,
            markdownReportPath: nil,
            latestMarkdownReportPath: nil,
            traceBundlePath: failureBundleURL?.path,
            gitCommit: gitCommitShortHash(),
            commandLine: commandLine(executableURL: executableURL, arguments: Array(arguments.dropFirst())),
            thresholds: .production,
            budgetFailureCount: budgetFailureCount,
            budgetWarningCount: budgetWarningCount,
            regressionWarnings: regressionWarnings,
            phases: phaseReports
        )

        let artifacts = try writeReports(&report, reportRoot: reportRoot, runDirectory: runDirectory)
        if let failureBundleURL {
            writeFailureArtifacts(
                report: report,
                reportURL: artifacts.runReportURL,
                markdownURL: artifacts.runMarkdownURL,
                failureDirectory: failureBundleURL,
                logDirectory: logDirectory,
                stabilityReportDirectory: stabilityReportDirectory
            )
        }

        printTerminalSummary(report: report, artifacts: artifacts)

        guard failedPhases.isEmpty else {
            throw GateError.failed(artifacts.latestReportURL)
        }
        guard budgetFailureCount == 0 else {
            throw GateError.failed(artifacts.latestReportURL)
        }
        guard warningBlockerCount == 0 else {
            throw GateError.failed(artifacts.latestReportURL)
        }
    }

    static func runSelfTestFromCommandLine(arguments: [String]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundtime-shippability-gate-self-test-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            try ShippabilityFixtureBuilder.verifyFromCommandLine(arguments: [
                "Soundtime",
                "--verify-shippability-fixtures",
                "--fixtures-output",
                root.appendingPathComponent("missing-fixtures").path,
            ])
            throw GateError.selfTestFailed("missing fixture root unexpectedly verified")
        } catch GateError.selfTestFailed {
            throw GateError.selfTestFailed("missing fixture root unexpectedly verified")
        } catch {
            // Expected: missing fixture roots must fail clearly.
        }

        let reportRoot = root.appendingPathComponent("reports", isDirectory: true)
        let runDirectory = reportRoot.appendingPathComponent("runs/self-test", isDirectory: true)
        let failureDirectory = reportRoot.appendingPathComponent("failures/self-test", isDirectory: true)
        var report = GateReport(
            schemaVersion: gateReportSchemaVersion,
            status: "failed",
            generatedAt: Date(),
            durationMilliseconds: 1,
            mode: "self-test",
            tierDescription: "self-test report serialization",
            targetRuntimeMilliseconds: nil,
            productBar: GatePurpose.featureDone.rawValue,
            productBarDescription: GatePurpose.featureDone.description,
            productBarDecision: GatePurpose.featureDone.decision(
                for: "failed",
                budgetFailureCount: 0,
                budgetWarningCount: 0,
                regressionWarningCount: 0
            ),
            productBarRule: productBarRule,
            featureDoneCommand: featureDoneProductBarCommand,
            releaseCandidateCommand: releaseCandidateProductBarCommand,
            fixtureRoot: root.appendingPathComponent("fixtures").path,
            fixtureStrategy: "self-test",
            keptFixtures: false,
            reportRoot: reportRoot.path,
            runDirectory: runDirectory.path,
            runReportPath: nil,
            latestReportPath: nil,
            markdownReportPath: nil,
            latestMarkdownReportPath: nil,
            traceBundlePath: failureDirectory.path,
            gitCommit: nil,
            commandLine: arguments.joined(separator: " "),
            thresholds: .production,
            budgetFailureCount: 0,
            budgetWarningCount: 0,
            regressionWarnings: [],
            phases: [
                GatePhaseReport(
                    name: "synthetic",
                    status: "failed",
                    durationMilliseconds: 1,
                    detail: "Synthetic failing phase.",
                    metrics: ["example": "1"],
                    warnings: [],
                    failureMessage: "Synthetic failure.",
                    budgetFindings: [],
                    checks: [
                        GateCheckReport(
                            label: "synthetic check",
                            status: "failed",
                            durationMilliseconds: 1,
                            exitCode: 1,
                            commandLine: "synthetic",
                            logPath: nil,
                            outputTail: "synthetic failure"
                        ),
                    ]
                ),
            ]
        )
        let artifacts = try writeReports(&report, reportRoot: reportRoot, runDirectory: runDirectory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(GateReport.self, from: Data(contentsOf: artifacts.latestReportURL))
        try require(decoded.status == "failed", "self-test report status did not round-trip")
        try require(decoded.phases.first?.checks.first?.status == "failed", "self-test check status did not round-trip")
        try require(FileManager.default.fileExists(atPath: artifacts.latestMarkdownURL.path), "self-test markdown report was not written")
        let markdown = try String(contentsOf: artifacts.latestMarkdownURL, encoding: .utf8)
        try require(markdown.contains("## User-visible Risk"), "self-test markdown report did not include user-visible risk language")
        try require(markdown.contains("## Product Bar"), "self-test markdown report did not include product bar policy")
        try require(markdown.contains("Next:"), "self-test markdown report did not include diagnostic next-step hints")
        try require(decoded.schemaVersion == gateReportSchemaVersion, "self-test report schema version did not round-trip")
        try require(decoded.productBar == GatePurpose.featureDone.rawValue, "self-test product bar did not round-trip")
        try require(decoded.featureDoneCommand == featureDoneProductBarCommand, "self-test feature command did not round-trip")
        try require(
            GatePurpose.featureDone.decision(
                for: "passed",
                budgetFailureCount: 0,
                budgetWarningCount: 1,
                regressionWarningCount: 1
            ).contains("passed"),
            "feature-done product bar should allow warning-only runs"
        )
        try require(
            GatePurpose.releaseCandidate.decision(
                for: "passed",
                budgetFailureCount: 0,
                budgetWarningCount: 1,
                regressionWarningCount: 0
            ).contains("failed"),
            "release-candidate product bar should block budget warnings"
        )
        try require(
            GatePurpose.releaseCandidate.decision(
                for: "passed",
                budgetFailureCount: 0,
                budgetWarningCount: 0,
                regressionWarningCount: 1
            ).contains("failed"),
            "release-candidate product bar should block regression warnings"
        )
        writeFailureArtifacts(
            report: report,
            reportURL: artifacts.runReportURL,
            markdownURL: artifacts.runMarkdownURL,
            failureDirectory: failureDirectory,
            logDirectory: runDirectory.appendingPathComponent("logs", isDirectory: true),
            stabilityReportDirectory: runDirectory.appendingPathComponent("stability-reports", isDirectory: true)
        )
        try require(
            FileManager.default.fileExists(atPath: failureDirectory.appendingPathComponent("trace-bundle.json").path),
            "self-test failure trace bundle was not written"
        )
        let traceBundle = try decoder.decode(
            GateTraceBundle.self,
            from: Data(contentsOf: failureDirectory.appendingPathComponent("trace-bundle.json"))
        )
        try require(traceBundle.schemaVersion == 2, "self-test trace bundle schema version did not round-trip")
        try require(traceBundle.failureCount == 1, "self-test trace bundle failure count was wrong")
        try require(traceBundle.primaryFailure?.diagnosticHint != nil, "self-test trace bundle primary failure lacked a diagnostic hint")

        let syntheticVisualReport = StabilitySuiteReport(
            suiteName: "visual-invariants-smoke",
            status: "failed",
            generatedAt: Date(),
            durationMilliseconds: 1,
            checks: [
                StabilityCheckReport(
                    name: "blank waveform lane should fail",
                    status: "failed",
                    detail: nil
                ),
            ],
            metadata: [
                "checkedFirstPaintTracks": "3",
                "checkedDrawableWaveformTracks": "2",
                "checkedBlankWaveformTracks": "1",
                "checkedDurationOnlyWaveformTracks": "0",
                "checkedPlaceholderTracks": "0",
                "checkedMinimumFirstPaintWaveformBins": "8",
                "checkedMinimumFirstPaintSourceWaveformBins": "8",
            ]
        )
        let visualFindings = visualInvariantBudgetFindings(syntheticVisualReport)
        try require(
            visualFindings.contains { $0.severity == "failure" && $0.metric == "checkedBlankWaveformTracks" },
            "self-test visual invariants did not catch blank waveform lanes"
        )
        try require(
            visualFindings.contains { $0.severity == "failure" && $0.metric == "checkedMinimumFirstPaintWaveformBins" },
            "self-test visual invariants did not catch too-coarse first-frame waveforms"
        )

        let syntheticHotPathReport = StabilitySuiteReport(
            suiteName: "hot-path-contract-smoke",
            status: "failed",
            generatedAt: Date(),
            durationMilliseconds: 1,
            checks: [],
            metadata: [
                "maxCPUWaveformVertices": "0",
                "maxCPUFallbackDraws": "0",
                "maxShaderUploads": "1",
                "maxShaderUploadBytes": "4096",
                "maxShaderUploadsInFlight": "0",
                "maxHotPathViolations": "1",
                "maxAutosaveScheduled": "1",
                "maxLaunchSnapshotWriteScheduled": "0",
                "maxPendingLaunchCacheWrites": "1",
                "maxLaunchCacheWritesInFlight": "0",
                "maxTranscriptLayoutBuilds": "2",
                "maxMainThreadStallCount": "1",
                "maxMainThreadStallMs": "25",
                "maxDashboardFrameDisplayMs": "1",
                "maxDashboardRefreshMs": "1",
            ]
        )
        let hotPathFindings = hotPathContractBudgetFindings(syntheticHotPathReport)
        try require(
            hotPathFindings.contains { $0.severity == "failure" && $0.metric == "maxShaderUploads" },
            "self-test hot-path contract did not catch shader uploads"
        )
        try require(
            hotPathFindings.contains { $0.severity == "failure" && $0.metric == "maxPendingLaunchCacheWrites" },
            "self-test hot-path contract did not catch pending launch cache writes"
        )

        let disposable = root.appendingPathComponent("disposable-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: disposable, withIntermediateDirectories: true)
        cleanupFixturesIfNeeded(rootDirectory: disposable, keepFixtures: false)
        try require(!FileManager.default.fileExists(atPath: disposable.path), "disposable fixture root was not removed")

        let kept = root.appendingPathComponent("kept-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        cleanupFixturesIfNeeded(rootDirectory: kept, keepFixtures: true)
        try require(FileManager.default.fileExists(atPath: kept.path), "kept fixture root was removed")

        print("Soundtime shippability gate self-test passed")
    }

    private static func makePhases() -> [GatePhase] {
        [
            GatePhase(
                name: "fixtures",
                detail: "Generate disposable golden fixtures, verify the manifest contract, and ensure large payloads stay untracked.",
                kind: .fixtures
            ),
            GatePhase(
                name: "startup",
                detail: "Protect instant launch, first waveform visibility, first playback readiness, and close lifecycle behavior.",
                kind: .commands([
                    command("launch performance smoke", ["--launch-performance-smoke"]),
                    command("startup close lifecycle smoke", ["--startup-close-lifecycle-smoke"]),
                    command("full launch performance smoke", ["--launch-performance-smoke-full"], modes: [.full]),
                ])
            ),
            GatePhase(
                name: "user perceived timing",
                detail: "Measure human-visible launch, waveform, playback, interaction, edit, save, and close latency against golden projects.",
                kind: .commands([
                    command("user perceived timing smoke", ["--user-perceived-timing-smoke"]),
                ])
            ),
            GatePhase(
                name: "visual invariants",
                detail: "Catch placeholder lanes, blank cached waveforms, muted/solo first-frame mismatches, playhead desync, paste gaps, and transcript highlight regressions.",
                kind: .commands([
                    command("visual invariants smoke", ["--visual-invariants-smoke"]),
                ])
            ),
            GatePhase(
                name: "hot path contracts",
                detail: "Fail if playback, zoom, selection, delete, paste, transcript, or diagnostics windows do render-adjacent CPU/upload/cache work.",
                kind: .commands([
                    command("hot path contract smoke", ["--hot-path-contract-smoke"]),
                ])
            ),
            GatePhase(
                name: "interaction replay",
                detail: "Replay deterministic seek, selection, zoom, pan, delete/undo, paste/undo, loop, and transcript scripts to catch feel regressions.",
                kind: .commands([
                    command("interaction replay smoke", ["--interaction-replay-smoke"]),
                ])
            ),
            GatePhase(
                name: "import",
                detail: "Verify supported/unsupported format recognition and import contracts.",
                kind: .commands([
                    command("audio import smoke", ["--audio-asset-importer-smoke"]),
                ])
            ),
            GatePhase(
                name: "timeline UX",
                detail: "Verify seek, selection, playhead, zoom, pan, loop, and first-frame waveform rendering.",
                kind: .commands([
                    command("timeline UX smoke", ["--timeline-ux-smoke"], modes: [.standard, .full]),
                    command("agent command bar smoke", ["--agent-command-bar-smoke"], modes: [.standard, .full]),
                ])
            ),
            GatePhase(
                name: "waveform render contract",
                detail: "Verify tile model, disk cache, request scheduling, upload, selection, promotion, and tiled rendering contracts.",
                kind: .commands([
                    command("waveform tile model", ["--waveform-tile-model-smoke"]),
                    command("waveform disk cache", ["--waveform-disk-cache-smoke"]),
                    command("waveform peak tile builder", ["--waveform-peak-tile-builder-smoke"]),
                    command("waveform tile scheduler", ["--waveform-tile-scheduler-smoke"]),
                    command("waveform tile request queue", ["--waveform-tile-request-queue-smoke"]),
                    command("waveform tile build worker", ["--waveform-tile-build-worker-smoke"]),
                    command("waveform tile upload coordinator", ["--waveform-tile-upload-coordinator-smoke"]),
                    command("waveform tile render selector", ["--waveform-tile-render-selector-smoke"]),
                    command("waveform tile promotion planner", ["--waveform-tile-promotion-planner-smoke"]),
                    command("waveform tiled render pipeline", ["--waveform-tiled-render-pipeline-smoke"]),
                    command("timeline perf baseline", ["--timeline-perf-baseline", "--quick", "--ci"], modes: [.standard, .full]),
                ])
            ),
            GatePhase(
                name: "edit graph delete paste",
                detail: "Verify edit graph, edit preview, and project edit round-trip behavior for delete/paste/undo reliability.",
                kind: .commands([
                    command("edit graph smoke", ["--edit-graph-smoke"]),
                    command("edit preview smoke", ["--edit-preview-smoke"]),
                    command("project edit round-trip smoke", ["--project-edit-roundtrip-smoke"]),
                ])
            ),
            GatePhase(
                name: "transcription",
                detail: "Verify transcript parsing, persistence, interaction mapping, sidecars, and chunk recovery.",
                kind: .commands([
                    command("transcription smoke", ["--transcription-smoke"]),
                ])
            ),
            GatePhase(
                name: "export",
                detail: "Verify snapshot export, selected-region renders, stem output, compressed M4A export, mix-bus math, source leases, long-file block rendering, and export reports.",
                kind: .commands([
                    command("audio export smoke", ["--audio-export-smoke"]),
                ])
            ),
            GatePhase(
                name: "diagnostics",
                detail: "Verify diagnostics accounting, trace writing, event retention, and dashboard lifecycle in full mode.",
                kind: .commands([
                    command("diagnostics smoke", ["--diagnostics-smoke"]),
                    command("performance dashboard lifecycle", ["--performance-dashboard-lifecycle-smoke"], modes: [.full]),
                ])
            ),
            GatePhase(
                name: "audio engine",
                detail: "Verify audio safety invariants, realtime graph publication, and heavier recording coverage in full mode.",
                kind: .commands([
                    command("audio safety core smoke", ["--audio-safety-smoke", "--audio-safety-core-only"], modes: [.quick]),
                    command("audio safety smoke", ["--audio-safety-smoke"], modes: [.standard, .full]),
                    command("realtime graph publish smoke", ["--realtime-graph-publish-smoke"]),
                    command("recording smoke", ["--recording-smoke"], modes: [.full]),
                ])
            ),
            GatePhase(
                name: "api processing",
                detail: "Verify local/fake audio processing provider job flow and undo-safe result handling.",
                kind: .commands([
                    command("audio processing smoke", ["--audio-processing-smoke"]),
                ])
            ),
        ]
    }

    private static func command(
        _ label: String,
        _ arguments: [String],
        modes: Set<GateMode> = [.quick, .standard, .full],
        required: Bool = true
    ) -> GateCommand {
        GateCommand(label: label, arguments: arguments, modes: modes, required: required)
    }

    private static func printHelp() {
        print(
            """
            Soundtime Shippability Gate

            Usage:
              swift run Soundtime --shippability-gate --quick
              swift run Soundtime --shippability-gate
              swift run Soundtime --shippability-gate --full
              swift run Soundtime --product-bar
              swift run Soundtime --release-candidate-gate

            Product bar:
              Feature done:       swift build && swift run Soundtime --product-bar
              Release candidate:  swift build && swift run Soundtime --release-candidate-gate

              --product-bar is a named alias for the quick feature-done gate.
              --feature-gate is an alias for --product-bar.
              --release-candidate-gate is a named alias for the full release gate.
              --rc-gate is an alias for --release-candidate-gate.

            Tiers:
              --quick     Daily guard for fast local iteration. Target: under 60s.
              default     Broad local shippability coverage. Target: under 300s.
              --full      Release/stress coverage with heavier checks. Target: under 900s.
              --stress    Legacy alias for --full.
              --standard  Explicit broad local shippability coverage.

            Options:
              --fixtures-output PATH     Use or write fixtures at PATH.
              --rebuild-fixtures         Rebuild cached fixtures before running.
              --disposable-fixtures      Build fixtures under this run directory and remove them afterwards.
              --keep-fixtures            Keep disposable fixtures after the run.
              --report-dir PATH          Write reports, logs, and failure bundles under PATH.

            Reports:
              JSON:      .build/shippability-gate/latest-report.json
              Markdown:  .build/shippability-gate/latest-report.md
            """
        )
    }

    private static func runFixturePhase(
        phase: GatePhase,
        fixtureRoot: URL,
        rebuildFixtures: Bool,
        mode: GateMode
    ) -> GatePhaseReport {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var checks: [GateCheckReport] = []
        var metrics: [String: String] = [:]
        var warnings: [String] = []

        do {
            var didReuseFixtures = false
            if !rebuildFixtures {
                let verifyStartedAt = DispatchTime.now().uptimeNanoseconds
                do {
                    try verifyFixtureBundle(rootDirectory: fixtureRoot, mode: mode)
                    checks.append(GateCheckReport(
                        label: "verify cached fixture manifest",
                        status: "passed",
                        durationMilliseconds: elapsedMilliseconds(since: verifyStartedAt),
                        exitCode: nil,
                        commandLine: "ShippabilityFixtureBuilder.verify",
                        logPath: nil,
                        outputTail: nil
                    ))
                    didReuseFixtures = true
                } catch {
                    warnings.append("fixture cache miss; rebuilt fixtures: \(error)")
                }
            }

            if !didReuseFixtures {
                let buildStartedAt = DispatchTime.now().uptimeNanoseconds
                try ShippabilityFixtureBuilder.runFromCommandLine(arguments: [
                    "Soundtime",
                    "--build-shippability-fixtures",
                    "--fixtures-output",
                    fixtureRoot.path,
                    "--fixture-profile",
                    fixtureProfileArgument(for: mode),
                ])
                checks.append(GateCheckReport(
                    label: "build fixtures",
                    status: "passed",
                    durationMilliseconds: elapsedMilliseconds(since: buildStartedAt),
                    exitCode: nil,
                    commandLine: "ShippabilityFixtureBuilder.build",
                    logPath: nil,
                    outputTail: nil
                ))

                let verifyStartedAt = DispatchTime.now().uptimeNanoseconds
                try verifyFixtureBundle(rootDirectory: fixtureRoot, mode: mode)
                checks.append(GateCheckReport(
                    label: "verify rebuilt fixture manifest",
                    status: "passed",
                    durationMilliseconds: elapsedMilliseconds(since: verifyStartedAt),
                    exitCode: nil,
                    commandLine: "ShippabilityFixtureBuilder.verify",
                    logPath: nil,
                    outputTail: nil
                ))
            }

            let manifestSummary = try readFixtureManifestSummary(rootDirectory: fixtureRoot)
            metrics["audioFiles"] = "\(manifestSummary.audio.count)"
            metrics["projects"] = "\(manifestSummary.projects.count)"
            metrics["supportedFormats"] = manifestSummary.supportedImportFormatsCovered.joined(separator: ",")
            metrics["recognizedUnsupportedFormats"] = manifestSummary.recognizedUnsupportedFormatsCovered.joined(separator: ",")
            metrics["projectTracks"] = "\(manifestSummary.projects.compactMap(\.trackCount).reduce(0, +))"
            metrics["fixtureRoot"] = fixtureRoot.path
            metrics["fixtureCache"] = didReuseFixtures ? "reused" : "rebuilt"
            metrics["fixtureProfile"] = fixtureProfileArgument(for: mode)

            let ignoreResult = verifyFixtureIgnoreContract()
            metrics.merge(ignoreResult.metrics) { _, new in new }
            warnings.append(contentsOf: ignoreResult.warnings)
            if let failure = ignoreResult.failure {
                throw GateError.selfTestFailed(failure)
            }

            return GatePhaseReport(
                name: phase.name,
                status: "passed",
                durationMilliseconds: elapsedMilliseconds(since: startedAt),
                detail: phase.detail,
                metrics: metrics,
                warnings: warnings,
                failureMessage: nil,
                checks: checks
            )
        } catch {
            checks.append(GateCheckReport(
                label: "fixtures",
                status: "failed",
                durationMilliseconds: elapsedMilliseconds(since: startedAt),
                exitCode: nil,
                commandLine: nil,
                logPath: nil,
                outputTail: "\(error)"
            ))
            return GatePhaseReport(
                name: phase.name,
                status: "failed",
                durationMilliseconds: elapsedMilliseconds(since: startedAt),
                detail: phase.detail,
                metrics: metrics,
                warnings: warnings,
                failureMessage: "\(error)",
                checks: checks
            )
        }
    }

    private static func runCommandPhase(
        phaseIndex: Int,
        phase: GatePhase,
        commands: [GateCommand],
        executableURL: URL,
        logDirectory: URL,
        stabilityReportDirectory: URL,
        fixtureRoot: URL,
        mode: GateMode
    ) -> GatePhaseReport {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        guard !commands.isEmpty else {
            return GatePhaseReport(
                name: phase.name,
                status: "skipped",
                durationMilliseconds: 0,
                detail: phase.detail,
                metrics: [:],
                warnings: [],
                failureMessage: "No checks are enabled for this mode.",
                checks: []
            )
        }

        var commandResults: [(command: GateCommand, check: GateCheckReport)] = []
        var warnings: [String] = []
        for (commandIndex, command) in commands.enumerated() {
            let childArguments = tieredChildArguments(command.arguments, mode: mode)
            let logURL = logDirectory.appendingPathComponent(
                "\(String(format: "%02d", phaseIndex))-\(String(format: "%02d", commandIndex + 1))-\(sanitizedFileName(command.label)).log"
            )
            let childReportDirectory = stabilityReportDirectory.appendingPathComponent(
                "\(String(format: "%02d", phaseIndex))-\(String(format: "%02d", commandIndex + 1))-\(sanitizedFileName(command.label))",
                isDirectory: true
            )
            let check = runChildCommand(
                executableURL: executableURL,
                label: command.label,
                phaseName: phase.name,
                arguments: childArguments,
                logURL: logURL,
                stabilityReportDirectory: childReportDirectory,
                fixtureRoot: fixtureRoot
            )
            commandResults.append((command: command, check: check))
            if check.status == "failed", !command.required {
                warnings.append("optional check failed: \(command.label)")
            }
        }

        let checks = commandResults.map(\.check)
        let budgetFindings = checks.flatMap(\.budgetFindings)
        let budgetFailureCount = budgetFindings.filter { $0.severity == "failure" }.count
        let budgetWarningCount = budgetFindings.filter { $0.severity == "warning" }.count
        let failedRequiredChecks = commandResults
            .filter { $0.command.required && $0.check.status == "failed" }
            .map(\.check)
        let failureMessage: String?
        if let firstFailure = failedRequiredChecks.first {
            failureMessage = "\(firstFailure.label) failed"
        } else if budgetFailureCount > 0 {
            failureMessage = "\(budgetFailureCount) budget failure\(budgetFailureCount == 1 ? "" : "s")"
        } else {
            failureMessage = nil
        }
        return GatePhaseReport(
            name: phase.name,
            status: failedRequiredChecks.isEmpty && budgetFailureCount == 0 ? "passed" : "failed",
            durationMilliseconds: elapsedMilliseconds(since: startedAt),
            detail: phase.detail,
            metrics: [
                "checkCount": "\(checks.count)",
                "failedCheckCount": "\(failedRequiredChecks.count)",
                "budgetFailureCount": "\(budgetFailureCount)",
                "budgetWarningCount": "\(budgetWarningCount)",
            ],
            warnings: warnings,
            failureMessage: failureMessage,
            budgetFindings: budgetFindings,
            checks: checks
        )
    }

    private static func tieredChildArguments(_ arguments: [String], mode: GateMode) -> [String] {
        let tierFlags: Set<String> = ["--quick", "--standard", "--full", "--stress"]
        guard arguments.allSatisfy({ !tierFlags.contains($0) }) else {
            return arguments
        }
        return arguments + mode.childTierArguments
    }

    private static func runChildCommand(
        executableURL: URL,
        label: String,
        phaseName: String,
        arguments: [String],
        logURL: URL,
        stabilityReportDirectory: URL,
        fixtureRoot: URL
    ) -> GateCheckReport {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SOUNDTIME_SHIPPABILITY_GATE"] = "1"
        environment["SOUNDTIME_SHIPPABILITY_FIXTURE_ROOT"] = fixtureRoot.path
        environment["SOUNDTIME_STABILITY_REPORT_DIR"] = stabilityReportDirectory.path
        process.environment = environment

        try? FileManager.default.createDirectory(at: stabilityReportDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let outputHandle = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? outputHandle?.close()
            return GateCheckReport(
                label: label,
                status: "failed",
                durationMilliseconds: elapsedMilliseconds(since: startedAt),
                exitCode: 127,
                commandLine: commandLine(executableURL: executableURL, arguments: arguments),
                logPath: logURL.path,
                stabilityReportPaths: [],
                metrics: [:],
                budgetFindings: [],
                outputTail: "failed to launch child command: \(error)",
                userVisibleRisk: userVisibleRisk(phaseName: phaseName, checkLabel: label),
                failureSummary: "\(label) could not be launched"
            )
        }

        try? outputHandle?.close()
        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let exitCode = process.terminationStatus
        let stabilityReports = readStabilityReports(in: stabilityReportDirectory)
        let budgetFindings = budgetFindings(for: stabilityReports)
        let budgetFailures = budgetFindings.filter { $0.severity == "failure" }
        let status = exitCode == 0 && budgetFailures.isEmpty ? "passed" : "failed"
        let outputTail: String?
        if status == "failed" {
            let budgetTail = budgetFailures.map(formatBudgetFinding).joined(separator: "\n")
            outputTail = [tail(output, limit: 3_000), budgetTail]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } else {
            outputTail = nil
        }
        return GateCheckReport(
            label: label,
            status: status,
            durationMilliseconds: elapsedMilliseconds(since: startedAt),
            exitCode: exitCode,
            commandLine: commandLine(executableURL: executableURL, arguments: arguments),
            logPath: logURL.path,
            stabilityReportPaths: stabilityReports.map(\.url.path),
            metrics: flattenedMetrics(from: stabilityReports),
            budgetFindings: budgetFindings,
            outputTail: outputTail,
            userVisibleRisk: status == "failed" ? userVisibleRisk(phaseName: phaseName, checkLabel: label) : nil,
            failureSummary: status == "failed" ? checkFailureSummary(label: label, exitCode: exitCode, budgetFailures: budgetFailures) : nil
        )
    }

    private static func readStabilityReports(in directory: URL) -> [ChildStabilityReport] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let report = try? decoder.decode(StabilitySuiteReport.self, from: data)
                else {
                    return nil
                }
                return ChildStabilityReport(url: url, report: report)
            }
    }

    private static func flattenedMetrics(from reports: [ChildStabilityReport]) -> [String: String] {
        var metrics: [String: String] = [:]
        for bundle in reports {
            let suiteName = sanitizedFileName(bundle.report.suiteName)
            metrics["\(suiteName).status"] = bundle.report.status
            metrics["\(suiteName).durationMs"] = String(format: "%.3f", bundle.report.durationMilliseconds)
            for (key, value) in bundle.report.metadata {
                metrics["\(suiteName).\(key)"] = value
            }
        }
        return metrics
    }

    private static func budgetFindings(for reports: [ChildStabilityReport]) -> [GateBudgetFinding] {
        reports.flatMap { bundle -> [GateBudgetFinding] in
            let report = bundle.report
            var findings: [GateBudgetFinding] = []

            switch report.suiteName {
            case "launch-performance-smoke":
                findings.append(contentsOf: launchPerformanceBudgetFindings(report))
            case "startup-close-lifecycle-smoke":
                findings.append(contentsOf: startupCloseBudgetFindings(report))
            case "user-perceived-timing-smoke":
                findings.append(contentsOf: userPerceivedTimingBudgetFindings(report))
            case "visual-invariants-smoke":
                findings.append(contentsOf: visualInvariantBudgetFindings(report))
            case "hot-path-contract-smoke":
                findings.append(contentsOf: hotPathContractBudgetFindings(report))
            case "interaction-replay-smoke":
                findings.append(contentsOf: interactionReplayBudgetFindings(report))
            case "timeline-perf-baseline":
                findings.append(contentsOf: timelinePerfBudgetFindings(report))
            case "audio-safety-smoke":
                findings.append(contentsOf: audioSafetyBudgetFindings(report))
            case "realtime-graph-publish-smoke":
                findings.append(contentsOf: realtimeGraphBudgetFindings(report))
            case "edit-graph-smoke":
                findings.append(contentsOf: editGraphBudgetFindings(report))
            case "edit-preview-smoke":
                findings.append(contentsOf: editPreviewBudgetFindings(report))
            default:
                break
            }

            if report.status == "failed" {
                findings.append(GateBudgetFinding(
                    severity: "failure",
                    suiteName: report.suiteName,
                    metric: "suite.status",
                    actual: report.status,
                    threshold: "passed",
                    unit: "status",
                    message: "\(report.suiteName) reported a failed stability status"
                ))
            }
            return findings
        }
    }

    private static func launchPerformanceBudgetFindings(_ report: StabilitySuiteReport) -> [GateBudgetFinding] {
        let tracks = metadataInt(report, "tracks") ?? 0
        let isFull = tracks > 12
        let averageLoadFail = isFull ? 180 : 120
        let averageLoadWarn = isFull ? 140 : 80
        let worstLoadFail = isFull ? 420 : 260
        let worstLoadWarn = isFull ? 320 : 180
        return [
            maxDoubleFinding(report, "averageLoadMs", warning: Double(averageLoadWarn), failure: Double(averageLoadFail), unit: "ms"),
            maxDoubleFinding(report, "worstLoadMs", warning: Double(worstLoadWarn), failure: Double(worstLoadFail), unit: "ms"),
            maxDoubleFinding(report, "playbackPrimeMs", warning: 180, failure: 250, unit: "ms"),
            maxIntFinding(report, "firstFramePacketBytes", maxMetric: "firstPaintByteLimit", unit: "bytes"),
            equalIntFinding(report, "drawableWaveformTracks", equalsMetric: "tracks", unit: "tracks"),
            equalIntFinding(report, "packetDrawableWaveformTracks", equalsMetric: "tracks", unit: "tracks"),
        ].compactMap { $0 }
    }

    private static func startupCloseBudgetFindings(_ report: StabilitySuiteReport) -> [GateBudgetFinding] {
        [
            maxDoubleFinding(report, "closeElapsedMs", warning: 50, failure: 120, unit: "ms"),
            equalIntFinding(report, "firstPaintDrawableWaveforms", equalsMetric: "firstPaintTracks", unit: "tracks"),
        ].compactMap { $0 }
    }

    private static func userPerceivedTimingBudgetFindings(_ report: StabilitySuiteReport) -> [GateBudgetFinding] {
        [
            maxDoubleFinding(
                report,
                "worstWindowVisibleMilliseconds",
                warning: ShippabilityTimingBudgets.windowVisible.warningMilliseconds,
                failure: GateThresholds.production.firstWindowVisibleMilliseconds,
                unit: "ms"
            ),
            maxDoubleFinding(
                report,
                "worstFirstWaveformVisibleMilliseconds",
                warning: ShippabilityTimingBudgets.firstWaveformVisible.warningMilliseconds,
                failure: GateThresholds.production.firstWaveformVisibleMilliseconds,
                unit: "ms"
            ),
            maxDoubleFinding(
                report,
                "worstPlaybackReadyMilliseconds",
                warning: ShippabilityTimingBudgets.playbackReady.warningMilliseconds,
                failure: GateThresholds.production.firstPlaybackReadyMilliseconds,
                unit: "ms"
            ),
            maxDoubleFinding(report, "worstFirstPlayCommandMilliseconds", warning: ShippabilityTimingBudgets.firstPlayCommand.warningMilliseconds, failure: ShippabilityTimingBudgets.firstPlayCommand.failureMilliseconds, unit: "ms"),
            maxDoubleFinding(report, "worstClickToSeekVisualMilliseconds", warning: ShippabilityTimingBudgets.clickToSeekVisual.warningMilliseconds, failure: ShippabilityTimingBudgets.clickToSeekVisual.failureMilliseconds, unit: "ms"),
            maxDoubleFinding(report, "worstSelectionDragEdgeMilliseconds", warning: ShippabilityTimingBudgets.selectionDragEdge.warningMilliseconds, failure: ShippabilityTimingBudgets.selectionDragEdge.failureMilliseconds, unit: "ms"),
            maxDoubleFinding(report, "worstDeleteAnimationStartMilliseconds", warning: ShippabilityTimingBudgets.deleteAnimationStart.warningMilliseconds, failure: ShippabilityTimingBudgets.deleteAnimationStart.failureMilliseconds, unit: "ms"),
            maxDoubleFinding(report, "worstPasteAnimationStartMilliseconds", warning: ShippabilityTimingBudgets.pasteAnimationStart.warningMilliseconds, failure: ShippabilityTimingBudgets.pasteAnimationStart.failureMilliseconds, unit: "ms"),
            maxDoubleFinding(report, "worstSaveLatencyMilliseconds", warning: ShippabilityTimingBudgets.saveLatency.warningMilliseconds, failure: ShippabilityTimingBudgets.saveLatency.failureMilliseconds, unit: "ms"),
            maxDoubleFinding(report, "worstCloseLatencyMilliseconds", warning: ShippabilityTimingBudgets.closeLatency.warningMilliseconds, failure: ShippabilityTimingBudgets.closeLatency.failureMilliseconds, unit: "ms"),
        ].compactMap { $0 }
    }

    private static func visualInvariantBudgetFindings(_ report: StabilitySuiteReport) -> [GateBudgetFinding] {
        var findings = [
            equalIntFinding(report, "checkedDrawableWaveformTracks", equalsMetric: "checkedFirstPaintTracks", unit: "tracks"),
            equalIntFinding(report, "checkedBlankWaveformTracks", expected: 0, unit: "tracks"),
            equalIntFinding(report, "checkedDurationOnlyWaveformTracks", expected: 0, unit: "tracks"),
            equalIntFinding(report, "checkedPlaceholderTracks", expected: 0, unit: "tracks"),
            minIntFinding(report, "checkedMinimumFirstPaintWaveformBins", warning: 64, failure: 16, unit: "bins"),
            minIntFinding(report, "checkedMinimumFirstPaintSourceWaveformBins", warning: 64, failure: 16, unit: "bins"),
        ].compactMap { $0 }

        for index in report.checks.indices {
            let check = report.checks[index]
            guard check.status == "failed" else {
                continue
            }
            let lowercasedName = check.name.lowercased()
            let message: String?
            if lowercasedName.contains("blank") {
                message = "visual invariant caught a blank waveform lane where cached audio should have painted"
            } else if lowercasedName.contains("duration-only") {
                message = "visual invariant caught a duration-only waveform fallback where cached waveform data should have painted"
            } else if lowercasedName.contains("coarse") || lowercasedName.contains("fallback") {
                message = "visual invariant caught a coarse or fallback waveform regression"
            } else {
                message = nil
            }
            if let message {
                findings.append(finding(
                    severity: "failure",
                    suiteName: report.suiteName,
                    metric: "check[\(index)].\(sanitizedFileName(check.name))",
                    actual: check.status,
                    threshold: "passed",
                    unit: "check",
                    message: message
                ))
            }
        }
        return findings
    }

    private static func hotPathContractBudgetFindings(_ report: StabilitySuiteReport) -> [GateBudgetFinding] {
        [
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxCPUWaveformVertices",
                actual: metadataInt(report, "maxCPUWaveformVertices"),
                warning: 0,
                failure: 0,
                unit: "vertices"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxCPUFallbackDraws",
                actual: metadataInt(report, "maxCPUFallbackDraws"),
                warning: 0,
                failure: 0,
                unit: "draws"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxShaderUploads",
                actual: metadataInt(report, "maxShaderUploads"),
                warning: 0,
                failure: 0,
                unit: "uploads"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxShaderUploadBytes",
                actual: metadataInt(report, "maxShaderUploadBytes"),
                warning: 0,
                failure: 0,
                unit: "bytes"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxShaderUploadsInFlight",
                actual: metadataInt(report, "maxShaderUploadsInFlight"),
                warning: 0,
                failure: 0,
                unit: "uploads"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxHotPathViolations",
                actual: metadataInt(report, "maxHotPathViolations"),
                warning: 0,
                failure: 0,
                unit: "violations"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxPendingLaunchCacheWrites",
                actual: metadataInt(report, "maxPendingLaunchCacheWrites"),
                warning: 0,
                failure: 0,
                unit: "writes"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxLaunchCacheWritesInFlight",
                actual: metadataInt(report, "maxLaunchCacheWritesInFlight"),
                warning: 0,
                failure: 0,
                unit: "writes"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxTranscriptLayoutBuilds",
                actual: metadataInt(report, "maxTranscriptLayoutBuilds"),
                warning: 1,
                failure: 1,
                unit: "builds"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxMainThreadStallCount",
                actual: metadataInt(report, "maxMainThreadStallCount"),
                warning: 0,
                failure: 0,
                unit: "stalls"
            ),
            maxDoubleFinding(report, "maxMainThreadStallMs", warning: 16, failure: 24, unit: "ms"),
            maxDoubleFinding(report, "maxDashboardFrameDisplayMs", warning: 2.5, failure: 4, unit: "ms"),
            maxDoubleFinding(report, "maxDashboardRefreshMs", warning: 4, failure: 8, unit: "ms"),
        ].compactMap { $0 }
    }

    private static func interactionReplayBudgetFindings(_ report: StabilitySuiteReport) -> [GateBudgetFinding] {
        [
            maxDoubleFinding(report, "maxReplayActionMilliseconds", warning: 16, failure: 35, unit: "ms"),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxCPUWaveformVertices",
                actual: metadataInt(report, "maxCPUWaveformVertices"),
                warning: 0,
                failure: 0,
                unit: "vertices"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxCPUFallbackDraws",
                actual: metadataInt(report, "maxCPUFallbackDraws"),
                warning: 0,
                failure: 0,
                unit: "draws"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxShaderUploads",
                actual: metadataInt(report, "maxShaderUploads"),
                warning: 0,
                failure: 0,
                unit: "uploads"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxShaderUploadBytes",
                actual: metadataInt(report, "maxShaderUploadBytes"),
                warning: 0,
                failure: 0,
                unit: "bytes"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxShaderUploadsInFlight",
                actual: metadataInt(report, "maxShaderUploadsInFlight"),
                warning: 0,
                failure: 0,
                unit: "uploads"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxHotPathViolations",
                actual: metadataInt(report, "maxHotPathViolations"),
                warning: 0,
                failure: 0,
                unit: "violations"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxPendingLaunchCacheWrites",
                actual: metadataInt(report, "maxPendingLaunchCacheWrites"),
                warning: 0,
                failure: 0,
                unit: "writes"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxLaunchCacheWritesInFlight",
                actual: metadataInt(report, "maxLaunchCacheWritesInFlight"),
                warning: 0,
                failure: 0,
                unit: "writes"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxTranscriptLayoutBuilds",
                actual: metadataInt(report, "maxTranscriptLayoutBuilds"),
                warning: 1,
                failure: 1,
                unit: "builds"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxDroppedEffectVertices",
                actual: metadataInt(report, "maxDroppedEffectVertices"),
                warning: 0,
                failure: 0,
                unit: "vertices"
            ),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "failureCount",
                actual: metadataInt(report, "failureCount"),
                warning: 0,
                failure: 0,
                unit: "failures"
            ),
        ].compactMap { $0 }
    }

    private static func timelinePerfBudgetFindings(_ report: StabilitySuiteReport) -> [GateBudgetFinding] {
        report.checks.flatMap { check -> [GateBudgetFinding] in
            guard let payload = timelinePerfPayload(from: check.detail) else {
                return []
            }
            let suite = report.suiteName
            let scenarioPrefix = "scenario[\(payload.scenario)]."
            var findings: [GateBudgetFinding] = []

            if let renderer = payload.renderer, renderer != "gpu" {
                findings.append(finding(
                    severity: "failure",
                    suiteName: suite,
                    metric: scenarioPrefix + "renderer",
                    actual: renderer,
                    threshold: "gpu",
                    unit: "mode",
                    message: "\(payload.scenario) used a non-GPU renderer"
                ))
            }
            findings.append(contentsOf: [
                equalIntFinding(suiteName: suite, metric: scenarioPrefix + "cpu_waveform_vertices", actual: payload.cpuWaveformVertices, expected: 0, unit: "vertices"),
                equalIntFinding(suiteName: suite, metric: scenarioPrefix + "dropped_60hz_frames", actual: payload.dropped60HzFrames, expected: 0, unit: "frames"),
                equalIntFinding(suiteName: suite, metric: scenarioPrefix + "effect_vertices_dropped", actual: payload.effectVerticesDropped, expected: 0, unit: "vertices"),
            ].compactMap { $0 })
            if let dropped144Finding = timelinePerfDropped144Finding(
                suiteName: suite,
                scenarioPrefix: scenarioPrefix,
                payload: payload
            ) {
                findings.append(dropped144Finding)
            }

            let uploadBudget = payload.waveformRefresh == true ? 2 : 0
            findings.append(contentsOf: [
                maxIntFinding(suiteName: suite, metric: scenarioPrefix + "shader_uploads", actual: payload.shaderUploads, warning: uploadBudget, failure: uploadBudget, unit: "uploads"),
                maxIntFinding(suiteName: suite, metric: scenarioPrefix + "shader_uploads_in_flight", actual: payload.shaderUploadsInFlight, warning: uploadBudget, failure: uploadBudget, unit: "uploads"),
                maxDoubleFinding(suiteName: suite, metric: scenarioPrefix + "cpu_submit_p95_ms", actual: payload.cpuSubmitP95Milliseconds, warning: 6.944, failure: 16.667, unit: "ms"),
                maxDoubleFinding(suiteName: suite, metric: scenarioPrefix + "gpu_p95_ms", actual: payload.gpuP95Milliseconds, warning: 6.944, failure: 16.667, unit: "ms"),
            ].compactMap { $0 })

            return findings
        }
    }

    private static func timelinePerfDropped144Finding(
        suiteName: String,
        scenarioPrefix: String,
        payload: TimelinePerfPayload
    ) -> GateBudgetFinding? {
        let allowedDroppedFrames = timelinePerfAllowedDropped144HzFrames(trackCount: payload.trackCount)
        guard let finding = maxIntFinding(
            suiteName: suiteName,
            metric: scenarioPrefix + "dropped_144hz_frames",
            actual: payload.dropped144HzFrames,
            warning: 0,
            failure: allowedDroppedFrames,
            unit: "frames"
        ) else {
            return nil
        }

        if finding.severity == "warning" {
            var warning = finding
            warning.message = "\(suiteName) \(scenarioPrefix)dropped_144hz_frames had a scheduler outlier inside the track-count stress budget"
            return warning
        }
        return finding
    }

    private static func timelinePerfAllowedDropped144HzFrames(trackCount: Int?) -> Int {
        guard let trackCount else {
            return 0
        }
        switch trackCount {
        case ..<50:
            return 0
        case ..<250:
            return 2
        default:
            return 4
        }
    }

    private static func realtimeGraphBudgetFindings(_ report: StabilitySuiteReport) -> [GateBudgetFinding] {
        [
            equalIntFinding(report, "droppedCommandCount", expected: 0, unit: "commands"),
            maxDoubleFinding(report, "publishP95Milliseconds", warning: 5, failure: 8, unit: "ms"),
            maxDoubleFinding(report, "mixP95Milliseconds", warning: 3.5, failure: 6, unit: "ms"),
            maxDoubleFinding(report, "seekP95Milliseconds", warning: 0.75, failure: 1.0, unit: "ms"),
            maxDoubleFinding(report, "duplicateTrackPhaseMaxError", warning: 0.00001, failure: 0.0001, unit: "samples"),
            maxDoubleFinding(report, "fileBackedDuplicateTrackPhaseMaxError", warning: 0.00001, failure: 0.0001, unit: "samples"),
        ].compactMap { $0 }
    }

    private static func audioSafetyBudgetFindings(_ report: StabilitySuiteReport) -> [GateBudgetFinding] {
        var findings = [
            equalIntFinding(report, "underrunCount", expected: 0, unit: "underruns"),
            equalIntFinding(report, "droppedCommandCount", expected: 0, unit: "commands"),
            equalIntFinding(report, "renderDeadlineMissCount", expected: 0, unit: "misses"),
            maxIntFinding(
                suiteName: report.suiteName,
                metric: "maxSeekFrameError",
                actual: metadataInt(report, "maxSeekFrameError"),
                warning: 0,
                failure: 1,
                unit: "frames"
            ),
            maxDoubleFinding(report, "maxLoopSampleError", warning: 0.00001, failure: 0.00005, unit: "samples"),
            maxDoubleFinding(report, "graphSwapP95Milliseconds", warning: 5, failure: 8, unit: "ms"),
            maxDoubleFinding(report, "maxGraphSwapMilliseconds", warning: 14, failure: 24, unit: "ms"),
            minIntFinding(report, "outputDeviceConfigureCount", warning: 2, failure: 2, unit: "configures"),
            minIntFinding(report, "outputDeviceInvalidateCount", warning: 1, failure: 1, unit: "invalidations"),
            minIntFinding(report, "outputDeviceStartCount", warning: 1, failure: 1, unit: "starts"),
            minIntFinding(report, "seekCheckCount", warning: 13, failure: 13, unit: "checks"),
            minIntFinding(report, "loopCapturedFrameCount", warning: 768, failure: 768, unit: "frames"),
            minIntFinding(report, "graphSwapTrackCount", warning: 24, failure: 24, unit: "tracks"),
            minIntFinding(report, "graphSwapUpdateCount", warning: 36, failure: 36, unit: "updates"),
            minIntFinding(report, "graphSwapRenderBlockCount", warning: 900, failure: 900, unit: "blocks"),
        ].compactMap { $0 }
        findings.append(contentsOf: [
            minDoubleFinding(report, "minimumCorePlaybackPeak", warning: 0.001, failure: 0.0005, unit: "peak"),
        ].compactMap { $0 })
        if report.metadata["scope"] != "core-only" {
            findings.append(contentsOf: [
                minDoubleFinding(report, "minimumImportPlaybackPeak", warning: 0.001, failure: 0.0005, unit: "peak"),
                minIntFinding(report, "importedFormatCount", warning: 7, failure: 7, unit: "formats"),
                minIntFinding(report, "importedFileCount", warning: 7, failure: 7, unit: "files"),
            ].compactMap { $0 })
        }
        return findings
    }

    private static func editGraphBudgetFindings(_ report: StabilitySuiteReport) -> [GateBudgetFinding] {
        [
            maxDoubleFinding(report, "operationP95Milliseconds", warning: 3, failure: 8, unit: "ms"),
            maxDoubleFinding(report, "operationMaxMilliseconds", warning: 12, failure: 25, unit: "ms"),
        ].compactMap { $0 }
    }

    private static func editPreviewBudgetFindings(_ report: StabilitySuiteReport) -> [GateBudgetFinding] {
        [
            maxDoubleFinding(report, "previewP95Milliseconds", warning: 4, failure: 10, unit: "ms"),
            maxDoubleFinding(report, "previewMaxMilliseconds", warning: 25, failure: 75, unit: "ms"),
        ].compactMap { $0 }
    }

    private static func timelinePerfPayload(from detail: String?) -> TimelinePerfPayload? {
        guard let jsonLine = detail?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
            let data = String(jsonLine).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return TimelinePerfPayload(
            scenario: stringValue(object["scenario"]) ?? "unknown",
            renderer: stringValue(object["renderer"]),
            trackCount: intValue(object["tracks"]),
            cpuWaveformVertices: intValue(object["cpu_waveform_vertices"]),
            dropped144HzFrames: intValue(object["dropped_144hz_frames"]),
            dropped60HzFrames: intValue(object["dropped_60hz_frames"]),
            effectVerticesDropped: intValue(object["effect_vertices_dropped"]),
            shaderUploads: intValue(object["shader_uploads"]),
            shaderUploadsInFlight: intValue(object["shader_uploads_in_flight"]),
            waveformRefresh: boolValue(object["waveform_refresh"]),
            cpuSubmitP95Milliseconds: doubleValue(object["cpu_submit_p95_ms"]),
            gpuP95Milliseconds: doubleValue(object["gpu_p95_ms"])
        )
    }

    private static func maxDoubleFinding(
        _ report: StabilitySuiteReport,
        _ metric: String,
        warning: Double,
        failure: Double,
        unit: String
    ) -> GateBudgetFinding? {
        guard var finding = maxDoubleFinding(
            suiteName: report.suiteName,
            metric: metric,
            actual: metadataDouble(report, metric),
            warning: warning,
            failure: failure,
            unit: unit
        ) else {
            return nil
        }
        if let project = report.metadata["\(metric)Project"], !project.isEmpty, project != "none" {
            finding.message += " (worst project: \(project))"
        }
        return finding
    }

    private static func maxDoubleFinding(
        suiteName: String,
        metric: String,
        actual: Double?,
        warning: Double,
        failure: Double,
        unit: String
    ) -> GateBudgetFinding? {
        guard let actual else {
            return nil
        }
        if actual > failure {
            return finding(
                severity: "failure",
                suiteName: suiteName,
                metric: metric,
                actual: String(format: "%.3f", actual),
                threshold: "<= \(String(format: "%.3f", failure))",
                unit: unit,
                message: "\(suiteName) \(metric) exceeded the hard budget"
            )
        }
        if actual > warning {
            return finding(
                severity: "warning",
                suiteName: suiteName,
                metric: metric,
                actual: String(format: "%.3f", actual),
                threshold: "<= \(String(format: "%.3f", warning))",
                unit: unit,
                message: "\(suiteName) \(metric) exceeded the warning budget"
            )
        }
        return nil
    }

    private static func maxIntFinding(
        _ report: StabilitySuiteReport,
        _ metric: String,
        maxMetric: String,
        unit: String
    ) -> GateBudgetFinding? {
        guard let actual = metadataInt(report, metric),
              let maximum = metadataInt(report, maxMetric)
        else {
            return nil
        }
        return maxIntFinding(
            suiteName: report.suiteName,
            metric: metric,
            actual: actual,
            warning: maximum,
            failure: maximum,
            unit: unit
        )
    }

    private static func maxIntFinding(
        suiteName: String,
        metric: String,
        actual: Int?,
        warning: Int,
        failure: Int,
        unit: String
    ) -> GateBudgetFinding? {
        guard let actual else {
            return nil
        }
        if actual > failure {
            return finding(
                severity: "failure",
                suiteName: suiteName,
                metric: metric,
                actual: "\(actual)",
                threshold: "<= \(failure)",
                unit: unit,
                message: "\(suiteName) \(metric) exceeded the hard budget"
            )
        }
        if actual > warning {
            return finding(
                severity: "warning",
                suiteName: suiteName,
                metric: metric,
                actual: "\(actual)",
                threshold: "<= \(warning)",
                unit: unit,
                message: "\(suiteName) \(metric) exceeded the warning budget"
            )
        }
        return nil
    }

    private static func minDoubleFinding(
        _ report: StabilitySuiteReport,
        _ metric: String,
        warning: Double,
        failure: Double,
        unit: String
    ) -> GateBudgetFinding? {
        guard let actual = metadataDouble(report, metric) else {
            return nil
        }
        if actual < failure {
            return finding(
                severity: "failure",
                suiteName: report.suiteName,
                metric: metric,
                actual: String(format: "%.6f", actual),
                threshold: ">= \(String(format: "%.6f", failure))",
                unit: unit,
                message: "\(report.suiteName) \(metric) fell below the hard budget"
            )
        }
        if actual < warning {
            return finding(
                severity: "warning",
                suiteName: report.suiteName,
                metric: metric,
                actual: String(format: "%.6f", actual),
                threshold: ">= \(String(format: "%.6f", warning))",
                unit: unit,
                message: "\(report.suiteName) \(metric) fell below the warning budget"
            )
        }
        return nil
    }

    private static func minIntFinding(
        _ report: StabilitySuiteReport,
        _ metric: String,
        warning: Int,
        failure: Int,
        unit: String
    ) -> GateBudgetFinding? {
        guard let actual = metadataInt(report, metric) else {
            return nil
        }
        if actual < failure {
            return finding(
                severity: "failure",
                suiteName: report.suiteName,
                metric: metric,
                actual: "\(actual)",
                threshold: ">= \(failure)",
                unit: unit,
                message: "\(report.suiteName) \(metric) fell below the hard budget"
            )
        }
        if actual < warning {
            return finding(
                severity: "warning",
                suiteName: report.suiteName,
                metric: metric,
                actual: "\(actual)",
                threshold: ">= \(warning)",
                unit: unit,
                message: "\(report.suiteName) \(metric) fell below the warning budget"
            )
        }
        return nil
    }

    private static func equalIntFinding(
        _ report: StabilitySuiteReport,
        _ metric: String,
        equalsMetric: String,
        unit: String
    ) -> GateBudgetFinding? {
        guard let actual = metadataInt(report, metric),
              let expected = metadataInt(report, equalsMetric)
        else {
            return nil
        }
        return equalIntFinding(
            suiteName: report.suiteName,
            metric: metric,
            actual: actual,
            expected: expected,
            unit: unit
        )
    }

    private static func equalIntFinding(
        _ report: StabilitySuiteReport,
        _ metric: String,
        expected: Int,
        unit: String
    ) -> GateBudgetFinding? {
        equalIntFinding(
            suiteName: report.suiteName,
            metric: metric,
            actual: metadataInt(report, metric),
            expected: expected,
            unit: unit
        )
    }

    private static func equalIntFinding(
        suiteName: String,
        metric: String,
        actual: Int?,
        expected: Int,
        unit: String
    ) -> GateBudgetFinding? {
        guard let actual, actual != expected else {
            return nil
        }
        return finding(
            severity: "failure",
            suiteName: suiteName,
            metric: metric,
            actual: "\(actual)",
            threshold: "== \(expected)",
            unit: unit,
            message: "\(suiteName) \(metric) did not match the required value"
        )
    }

    private static func finding(
        severity: String,
        suiteName: String,
        metric: String,
        actual: String,
        threshold: String,
        unit: String,
        message: String
    ) -> GateBudgetFinding {
        GateBudgetFinding(
            severity: severity,
            suiteName: suiteName,
            metric: metric,
            actual: actual,
            threshold: threshold,
            unit: unit,
            message: message,
            userVisibleRisk: userVisibleRisk(suiteName: suiteName, metric: metric)
        )
    }

    private static func formatBudgetFinding(_ finding: GateBudgetFinding) -> String {
        "[\(finding.severity.uppercased())] \(finding.suiteName).\(finding.metric) actual=\(finding.actual) \(finding.unit) threshold=\(finding.threshold): \(finding.message)"
    }

    private static func metadataDouble(_ report: StabilitySuiteReport, _ key: String) -> Double? {
        report.metadata[key].flatMap(Double.init)
    }

    private static func metadataInt(_ report: StabilitySuiteReport, _ key: String) -> Int? {
        if let value = report.metadata[key].flatMap(Int.init) {
            return value
        }
        return report.metadata[key].flatMap(Double.init).map { Int($0.rounded()) }
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double.rounded())
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func readFixtureManifestSummary(rootDirectory: URL) throws -> FixtureManifestSummary {
        let data = try Data(contentsOf: rootDirectory.appendingPathComponent("fixtures-manifest.json"))
        return try JSONDecoder().decode(FixtureManifestSummary.self, from: data)
    }

    private static func verifyFixtureBundle(rootDirectory: URL, mode: GateMode) throws {
        try ShippabilityFixtureBuilder.verifyFromCommandLine(arguments: [
            "Soundtime",
            "--verify-shippability-fixtures",
            "--fixtures-output",
            rootDirectory.path,
            "--fixture-profile",
            fixtureProfileArgument(for: mode),
        ])
    }

    private static func fixtureProfileArgument(for mode: GateMode) -> String {
        mode == .full ? "full" : "quick"
    }

    private static func verifyFixtureIgnoreContract() -> (
        metrics: [String: String],
        warnings: [String],
        failure: String?
    ) {
        guard FileManager.default.fileExists(atPath: ".git") else {
            return (["gitIgnoreChecked": "false"], ["not a Git worktree; skipped fixture ignore contract"], nil)
        }

        let generatedPath = "Fixtures/Shippability/v1/audio/st-ship-audio-001-short-voice-12s.wav"
        let specPath = "Fixtures/Shippability/FIXTURE_SPEC.md"
        let generatedIgnored = runGit(arguments: ["check-ignore", "-q", generatedPath]).exitCode == 0
        let specIgnored = runGit(arguments: ["check-ignore", "-q", specPath]).exitCode == 0
        let trackedGeneratedOutput = runGit(arguments: ["ls-files", "Fixtures/Shippability/v1"]).output
            .split(separator: "\n")
            .filter { !$0.isEmpty }

        if !generatedIgnored {
            return (
                ["gitIgnoreChecked": "true", "generatedFixtureIgnored": "false"],
                [],
                "\(generatedPath) is not ignored"
            )
        }
        if specIgnored {
            return (
                ["gitIgnoreChecked": "true", "fixtureSpecIgnored": "true"],
                [],
                "\(specPath) is unexpectedly ignored"
            )
        }
        if !trackedGeneratedOutput.isEmpty {
            return (
                [
                    "gitIgnoreChecked": "true",
                    "trackedGeneratedFixtureCount": "\(trackedGeneratedOutput.count)",
                ],
                [],
                "generated shippability fixtures are tracked: \(trackedGeneratedOutput.joined(separator: ", "))"
            )
        }

        return (
            [
                "gitIgnoreChecked": "true",
                "generatedFixtureIgnored": "true",
                "fixtureSpecIgnored": "false",
                "trackedGeneratedFixtureCount": "0",
            ],
            [],
            nil
        )
    }

    private static func loadPreviousLatestReport(reportRoot: URL) -> GateReport? {
        let latestReportURL = reportRoot.appendingPathComponent("latest-report.json")
        guard let data = try? Data(contentsOf: latestReportURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GateReport.self, from: data)
    }

    private static func regressionWarnings(
        previous: GateReport?,
        mode: String,
        currentPhases: [GatePhaseReport]
    ) -> [String] {
        guard let previous,
              previous.status == "passed",
              previous.mode == mode
        else {
            return []
        }

        let previousPhases = Dictionary(uniqueKeysWithValues: previous.phases.map { ($0.name, $0) })
        return currentPhases.compactMap { current in
            guard current.status == "passed",
                  let previousPhase = previousPhases[current.name],
                  previousPhase.status == "passed",
                  previousPhase.durationMilliseconds > 0
            else {
                return nil
            }

            let absoluteSlackMilliseconds: Double = 1_500
            let ratioSlack = 1.35
            let allowedMilliseconds = max(
                previousPhase.durationMilliseconds + absoluteSlackMilliseconds,
                previousPhase.durationMilliseconds * ratioSlack
            )
            guard current.durationMilliseconds > allowedMilliseconds else {
                return nil
            }
            return String(
                format: "%@ phase slowed from %.1fms to %.1fms",
                current.name,
                previousPhase.durationMilliseconds,
                current.durationMilliseconds
            )
        }
    }

    private static func gateRuntimePhase(
        mode: GateMode,
        durationMilliseconds: Double,
        phaseReports: [GatePhaseReport]
    ) -> GatePhaseReport? {
        let fixtureRebuildDurationMilliseconds = oneTimeFixtureRebuildDurationMilliseconds(in: phaseReports)
        let budgetedDurationMilliseconds = max(0, durationMilliseconds - fixtureRebuildDurationMilliseconds)
        let severity: String
        let thresholdMilliseconds: Double
        if budgetedDurationMilliseconds > mode.targetRuntimeMilliseconds {
            severity = "failure"
            thresholdMilliseconds = mode.targetRuntimeMilliseconds
        } else if budgetedDurationMilliseconds > mode.warningRuntimeMilliseconds {
            severity = "warning"
            thresholdMilliseconds = mode.warningRuntimeMilliseconds
        } else {
            return nil
        }

        let message: String
        if fixtureRebuildDurationMilliseconds > 0 {
            message = String(
                format: "shippability gate %@ tier took %.1fs after excluding %.1fs of one-time fixture rebuild work, above the %@ runtime budget of %.1fs",
                mode.rawValue,
                budgetedDurationMilliseconds / 1_000,
                fixtureRebuildDurationMilliseconds / 1_000,
                severity == "failure" ? "hard" : "warning",
                thresholdMilliseconds / 1_000
            )
        } else {
            message = String(
                format: "shippability gate %@ tier took %.1fs, above the %@ runtime budget of %.1fs",
                mode.rawValue,
                durationMilliseconds / 1_000,
                severity == "failure" ? "hard" : "warning",
                thresholdMilliseconds / 1_000
            )
        }
        let finding = GateBudgetFinding(
            severity: severity,
            suiteName: "shippability-gate",
            metric: "budgetedDurationMilliseconds",
            actual: String(format: "%.1f", budgetedDurationMilliseconds),
            threshold: "<= \(String(format: "%.1f", thresholdMilliseconds))",
            unit: "ms",
            message: message,
            userVisibleRisk: "The gate is no longer easy to run often, so regressions are less likely to be caught before manual testing."
        )
        return GatePhaseReport(
            name: "gate runtime",
            status: severity == "failure" ? "failed" : "passed",
            durationMilliseconds: 0,
            detail: "Keep each shippability tier small enough to run at the intended cadence.",
            metrics: [
                "mode": mode.rawValue,
                "tierDescription": mode.description,
                "durationMilliseconds": String(format: "%.1f", durationMilliseconds),
                "budgetedDurationMilliseconds": String(format: "%.1f", budgetedDurationMilliseconds),
                "excludedFixtureRebuildDurationMilliseconds": String(format: "%.1f", fixtureRebuildDurationMilliseconds),
                "targetRuntimeMilliseconds": String(format: "%.1f", mode.targetRuntimeMilliseconds),
            ],
            warnings: [],
            failureMessage: severity == "failure" ? message : nil,
            budgetFindings: [finding],
            checks: []
        )
    }

    private static func oneTimeFixtureRebuildDurationMilliseconds(
        in phaseReports: [GatePhaseReport]
    ) -> Double {
        phaseReports.reduce(0) { partialResult, phase in
            guard
                phase.name == "fixtures",
                phase.metrics["fixtureCache"] == "rebuilt"
            else {
                return partialResult
            }
            return partialResult + phase.durationMilliseconds
        }
    }

    private static func printTerminalSummary(report: GateReport, artifacts: GateReportArtifacts) {
        let failures = issueSummaries(in: report, severities: ["failure"])
        let warnings = issueSummaries(in: report, severities: ["warning"])

        print("")
        print("Result: \(report.status.uppercased())")
        print("duration: \(String(format: "%.1fms", report.durationMilliseconds))  mode: \(report.mode)")
        if let tierDescription = report.tierDescription {
            print("tier: \(tierDescription)")
        }
        if let productBar = report.productBar,
           let productBarDescription = report.productBarDescription,
           let productBarDecision = report.productBarDecision
        {
            print("product bar: \(productBar) - \(productBarDescription)")
            print("decision: \(productBarDecision)")
        }
        if let targetRuntimeMilliseconds = report.targetRuntimeMilliseconds {
            print("target runtime: \(String(format: "%.0fs", targetRuntimeMilliseconds / 1_000))")
        }
        if !failures.isEmpty {
            print("")
            print("Failures:")
            for issue in failures.prefix(10) {
                print("  FAIL \(issue.phaseName)\(issue.checkLabel.map { " / \($0)" } ?? "")")
                print("       \(issue.message)")
                print("       risk: \(issue.userVisibleRisk)")
                if let metric = issue.metric {
                    let actual = issue.actual.map { " actual=\($0)" } ?? ""
                    let threshold = issue.threshold.map { " threshold=\($0)" } ?? ""
                    let unit = issue.unit.map { " \($0)" } ?? ""
                    print("       metric: \(metric)\(actual)\(unit)\(threshold)")
                }
                if let logPath = issue.logPath {
                    print("       log: \(logPath)")
                }
                if let diagnosticHint = issue.diagnosticHint {
                    print("       next: \(diagnosticHint)")
                }
            }
            if failures.count > 10 {
                print("       ... \(failures.count - 10) more failure(s) in the markdown report")
            }
        }
        if !warnings.isEmpty {
            print("")
            print("Warnings:")
            for issue in warnings.prefix(8) {
                print("  WARN \(issue.phaseName)\(issue.checkLabel.map { " / \($0)" } ?? "")")
                print("       \(issue.message)")
                print("       risk: \(issue.userVisibleRisk)")
                if let metric = issue.metric {
                    let actual = issue.actual.map { " actual=\($0)" } ?? ""
                    let threshold = issue.threshold.map { " threshold=\($0)" } ?? ""
                    let unit = issue.unit.map { " \($0)" } ?? ""
                    print("       metric: \(metric)\(actual)\(unit)\(threshold)")
                }
                if let diagnosticHint = issue.diagnosticHint {
                    print("       next: \(diagnosticHint)")
                }
            }
            if warnings.count > 8 {
                print("       ... \(warnings.count - 8) more warning(s) in the markdown report")
            }
        }
        if report.regressionWarnings.isEmpty && report.budgetFailureCount == 0 && report.budgetWarningCount == 0 {
            print("budgets: clean")
        } else {
            print("budgets: \(report.budgetFailureCount) failures, \(report.budgetWarningCount) warnings")
        }
        print("json report: \(artifacts.latestReportURL.path)")
        print("markdown report: \(artifacts.latestMarkdownURL.path)")
        if let traceBundlePath = report.traceBundlePath {
            print("failure trace bundle: \(traceBundlePath)")
        }
        if let featureDoneCommand = report.featureDoneCommand {
            print("feature done bar: \(featureDoneCommand)")
        }
        if let releaseCandidateCommand = report.releaseCandidateCommand {
            print("release bar: \(releaseCandidateCommand)")
        }
        fflush(stdout)
    }

    private static func markdownReport(for report: GateReport) -> String {
        let failures = issueSummaries(in: report, severities: ["failure"])
        let warnings = issueSummaries(in: report, severities: ["warning"])
        var lines: [String] = []
        lines.append("# Soundtime Shippability Gate")
        lines.append("")
        lines.append("- Result: **\(report.status.uppercased())**")
        lines.append("- Mode: `\(report.mode)`")
        if let tierDescription = report.tierDescription {
            lines.append("- Tier: \(markdownEscape(tierDescription))")
        }
        if let targetRuntimeMilliseconds = report.targetRuntimeMilliseconds {
            lines.append("- Target runtime: `\(String(format: "%.0fs", targetRuntimeMilliseconds / 1_000))`")
        }
        if let productBar = report.productBar {
            lines.append("- Product bar: `\(productBar)`")
        }
        lines.append("- Duration: `\(String(format: "%.1fms", report.durationMilliseconds))`")
        lines.append("- Generated: `\(ISO8601DateFormatter().string(from: report.generatedAt))`")
        if let gitCommit = report.gitCommit {
            lines.append("- Git commit: `\(gitCommit)`")
        }
        lines.append("- Fixture root: `\(report.fixtureRoot)`")
        lines.append("- Run directory: `\(report.runDirectory)`")
        if let traceBundlePath = report.traceBundlePath {
            lines.append("- Failure trace bundle: `\(traceBundlePath)`")
        }
        lines.append("")
        lines.append("## Product Bar")
        lines.append("")
        if let productBarDescription = report.productBarDescription {
            lines.append(markdownEscape(productBarDescription))
            lines.append("")
        }
        if let productBarDecision = report.productBarDecision {
            lines.append("Decision: **\(markdownEscape(productBarDecision))**")
            lines.append("")
        }
        if let productBarRule = report.productBarRule {
            lines.append("Rule: \(markdownEscape(productBarRule))")
            lines.append("")
        }
        if let featureDoneCommand = report.featureDoneCommand {
            lines.append("- Feature done: `\(markdownEscape(featureDoneCommand))`")
        }
        if let releaseCandidateCommand = report.releaseCandidateCommand {
            lines.append("- Release candidate: `\(markdownEscape(releaseCandidateCommand))`")
        }
        lines.append("")
        lines.append("## User-visible Risk")
        if failures.isEmpty && warnings.isEmpty {
            lines.append("No user-visible risks were found in this run.")
        } else {
            appendIssueMarkdown(title: "Failures", issues: failures, lines: &lines)
            appendIssueMarkdown(title: "Warnings", issues: warnings, lines: &lines)
        }
        lines.append("")
        lines.append("## Phase Summary")
        lines.append("")
        lines.append("| Status | Phase | Duration | Checks | Budget | Detail |")
        lines.append("| --- | --- | ---: | ---: | --- | --- |")
        for phase in report.phases {
            let checkCount = phase.checks.count
            let failedChecks = phase.checks.filter { $0.status == "failed" }.count
            let budgetFailures = phase.budgetFindings.filter { $0.severity == "failure" }.count
            let budgetWarnings = phase.budgetFindings.filter { $0.severity == "warning" }.count
            lines.append(
                "| \(markdownEscape(phase.status.uppercased())) | \(markdownEscape(phase.name)) | \(String(format: "%.1fms", phase.durationMilliseconds)) | \(failedChecks)/\(checkCount) failed | \(budgetFailures) fail, \(budgetWarnings) warn | \(markdownEscape(phase.failureMessage ?? phase.detail)) |"
            )
        }
        lines.append("")
        lines.append("## Check Details")
        for phase in report.phases {
            lines.append("")
            lines.append("### \(phase.name)")
            lines.append("")
            if !phase.metrics.isEmpty {
                lines.append("Metrics:")
                for key in phase.metrics.keys.sorted() {
                    lines.append("- `\(key)`: `\(phase.metrics[key] ?? "")`")
                }
                lines.append("")
            }
            if phase.checks.isEmpty {
                lines.append("No checks ran for this phase.")
                continue
            }
            lines.append("| Status | Check | Duration | Report | Log |")
            lines.append("| --- | --- | ---: | --- | --- |")
            for check in phase.checks {
                let reportPaths = check.stabilityReportPaths.map { "`\($0)`" }.joined(separator: "<br>")
                let log = check.logPath.map { "`\($0)`" } ?? ""
                lines.append(
                    "| \(markdownEscape(check.status.uppercased())) | \(markdownEscape(check.label)) | \(String(format: "%.1fms", check.durationMilliseconds)) | \(markdownEscape(reportPaths)) | \(markdownEscape(log)) |"
                )
                if check.status == "failed" {
                    lines.append("")
                    lines.append("Failure summary: \(markdownEscape(check.failureSummary ?? "\(check.label) failed"))")
                    lines.append("")
                    lines.append("Risk: \(markdownEscape(check.userVisibleRisk ?? userVisibleRisk(phaseName: phase.name, checkLabel: check.label)))")
                    if let outputTail = check.outputTail, !outputTail.isEmpty {
                        lines.append("")
                        lines.append("<details><summary>Output tail</summary>")
                        lines.append("")
                        lines.append("```text")
                        lines.append(outputTail)
                        lines.append("```")
                        lines.append("")
                        lines.append("</details>")
                    }
                }
            }
        }
        lines.append("")
        lines.append("## Re-run")
        lines.append("")
        lines.append("```sh")
        lines.append(report.commandLine)
        lines.append("```")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func appendIssueMarkdown(title: String, issues: [GateIssueSummary], lines: inout [String]) {
        guard !issues.isEmpty else {
            return
        }
        lines.append("")
        lines.append("### \(title)")
        lines.append("")
        for issue in issues {
            lines.append("- **\(issue.severity.uppercased())** `\(issue.phaseName)`\(issue.checkLabel.map { " / `\($0)`" } ?? ""): \(issue.message)")
            lines.append("  Risk: \(issue.userVisibleRisk)")
            if let metric = issue.metric {
                let actual = issue.actual.map { " actual `\($0)`" } ?? ""
                let unit = issue.unit.map { " \($0)" } ?? ""
                let threshold = issue.threshold.map { " threshold `\($0)`" } ?? ""
                lines.append("  Metric: `\(metric)`\(actual)\(unit)\(threshold)")
            }
            if let logPath = issue.logPath {
                lines.append("  Log: `\(logPath)`")
            }
            if let diagnosticHint = issue.diagnosticHint {
                lines.append("  Next: \(markdownEscape(diagnosticHint))")
            }
        }
    }

    private static func failureMarkdownSummary(
        report: GateReport,
        copiedReportURL: URL,
        copiedMarkdownURL: URL,
        traceURL: URL,
        failures: [GateIssueSummary],
        warnings: [GateIssueSummary]
    ) -> String {
        var lines: [String] = []
        lines.append("# Soundtime Shippability Failure Bundle")
        lines.append("")
        lines.append("- Result: `\(report.status)`")
        lines.append("- Mode: `\(report.mode)`")
        if let productBar = report.productBar {
            lines.append("- Product bar: `\(productBar)`")
        }
        if let productBarDecision = report.productBarDecision {
            lines.append("- Decision: \(markdownEscape(productBarDecision))")
        }
        lines.append("- JSON report: `\(copiedReportURL.path)`")
        lines.append("- Markdown report: `\(copiedMarkdownURL.path)`")
        lines.append("- Trace bundle: `\(traceURL.path)`")
        lines.append("- Original run directory: `\(report.runDirectory)`")
        lines.append("")
        appendIssueMarkdown(title: "Failures", issues: failures, lines: &lines)
        appendIssueMarkdown(title: "Warnings", issues: warnings, lines: &lines)
        lines.append("")
        lines.append("## Re-run")
        lines.append("")
        lines.append("```sh")
        lines.append(report.commandLine)
        lines.append("```")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func issueSummaries(in report: GateReport, severities: Set<String>) -> [GateIssueSummary] {
        var issues: [GateIssueSummary] = []
        for phase in report.phases {
            for warning in phase.warnings where severities.contains("warning") {
                issues.append(GateIssueSummary(
                    severity: "warning",
                    phaseName: phase.name,
                    checkLabel: nil,
                    suiteName: nil,
                    metric: nil,
                    actual: nil,
                    threshold: nil,
                    unit: nil,
                    message: warning,
                    userVisibleRisk: userVisibleRisk(phaseName: phase.name, checkLabel: nil),
                    logPath: nil,
                    stabilityReportPaths: [],
                    outputTail: nil
                ))
            }

            let hasSpecificFailure = phase.checks.contains { check in
                check.status == "failed" || check.budgetFindings.contains { $0.severity == "failure" }
            }
            if phase.status == "failed", !hasSpecificFailure, severities.contains("failure") {
                issues.append(GateIssueSummary(
                    severity: "failure",
                    phaseName: phase.name,
                    checkLabel: nil,
                    suiteName: nil,
                    metric: nil,
                    actual: nil,
                    threshold: nil,
                    unit: nil,
                    message: phase.failureMessage ?? "\(phase.name) phase failed",
                    userVisibleRisk: userVisibleRisk(phaseName: phase.name, checkLabel: nil),
                    logPath: nil,
                    stabilityReportPaths: [],
                    outputTail: nil
                ))
            }

            for check in phase.checks {
                let checkBudgetFailures = check.budgetFindings.filter { $0.severity == "failure" }
                if check.status == "failed", checkBudgetFailures.isEmpty, severities.contains("failure") {
                    issues.append(GateIssueSummary(
                        severity: "failure",
                        phaseName: phase.name,
                        checkLabel: check.label,
                        suiteName: nil,
                        metric: nil,
                        actual: nil,
                        threshold: nil,
                        unit: nil,
                        message: check.failureSummary ?? "\(check.label) failed",
                        userVisibleRisk: check.userVisibleRisk ?? userVisibleRisk(phaseName: phase.name, checkLabel: check.label),
                        logPath: check.logPath,
                        stabilityReportPaths: check.stabilityReportPaths,
                        outputTail: check.outputTail
                    ))
                }

                for finding in check.budgetFindings where severities.contains(finding.severity) {
                    issues.append(GateIssueSummary(
                        severity: finding.severity,
                        phaseName: phase.name,
                        checkLabel: check.label,
                        suiteName: finding.suiteName,
                        metric: finding.metric,
                        actual: finding.actual,
                        threshold: finding.threshold,
                        unit: finding.unit,
                        message: finding.message,
                        userVisibleRisk: finding.userVisibleRisk ?? userVisibleRisk(suiteName: finding.suiteName, metric: finding.metric),
                        logPath: check.logPath,
                        stabilityReportPaths: check.stabilityReportPaths,
                        outputTail: finding.severity == "failure" ? check.outputTail : nil
                    ))
                }
            }
        }

        if severities.contains("warning") {
            for warning in report.regressionWarnings {
                issues.append(GateIssueSummary(
                    severity: "warning",
                    phaseName: "regression",
                    checkLabel: nil,
                    suiteName: nil,
                    metric: nil,
                    actual: nil,
                    threshold: nil,
                    unit: nil,
                    message: warning,
                    userVisibleRisk: "A previously passing shippability path became slower, which can hide a fresh performance regression.",
                    logPath: nil,
                    stabilityReportPaths: [],
                    outputTail: nil
                ))
            }
        }
        return issues.map { issue in
            var issue = issue
            issue.diagnosticHint = diagnosticHint(for: issue)
            return issue
        }
    }

    private static func diagnosticHint(for issue: GateIssueSummary) -> String {
        let text = [
            issue.phaseName,
            issue.checkLabel,
            issue.suiteName,
            issue.metric,
            issue.message,
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if text.contains("placeholder") ||
            text.contains("firstpaint") ||
            text.contains("firstwaveform") ||
            text.contains("windowvisible") ||
            text.contains("blank waveform") ||
            text.contains("duration-only") ||
            text.contains("coarse")
        {
            return "Inspect the first-frame launch packet and visual-invariants report; this usually means startup rendered before cached track/waveform state was available."
        }
        if text.contains("hot path") ||
            text.contains("cpuwaveform") ||
            text.contains("fallback") ||
            text.contains("shaderupload") ||
            text.contains("mainthread") ||
            text.contains("autosave") ||
            text.contains("launchcache")
        {
            return "Open the hot-path stability report and child log; look for waveform uploads, cache writes, autosave, or layout work during the named interaction."
        }
        if text.contains("selection") ||
            text.contains("delete") ||
            text.contains("paste") ||
            text.contains("clicktoseek") ||
            text.contains("replay") ||
            text.contains("zoom") ||
            text.contains("pan")
        {
            return "Replay the interaction from the gate log and compare pointer/playhead/selection metrics against the visual-invariants report."
        }
        if text.contains("audio safety") ||
            text.contains("underrun") ||
            text.contains("droppedcommand") ||
            text.contains("output-device") ||
            text.contains("seekframe") ||
            text.contains("loop") ||
            text.contains("import playback")
        {
            return "Inspect the audio-safety report first; failures here point at realtime command delivery, seek/loop math, device setup, or imported-format playback."
        }
        if text.contains("transcript") ||
            text.contains("transcription")
        {
            return "Inspect transcript visual metrics and interaction replay logs; failures usually mean word virtualization, active-word timing, or sidecar persistence regressed."
        }
        if text.contains("runtime") ||
            text.contains("durationmilliseconds")
        {
            return "Compare this run to the previous latest report and look for the slowest phase before drilling into child logs."
        }
        if let logPath = issue.logPath {
            return "Open the child log at \(logPath) and the copied stability reports in the failure bundle."
        }
        return "Open the markdown report, then inspect the failure bundle's logs and stability reports for the phase named above."
    }

    private static func checkFailureSummary(
        label: String,
        exitCode: Int32,
        budgetFailures: [GateBudgetFinding]
    ) -> String {
        if !budgetFailures.isEmpty {
            let first = budgetFailures[0]
            return "\(label) violated \(first.suiteName).\(first.metric): actual \(first.actual) \(first.unit), required \(first.threshold)"
        }
        if exitCode != 0 {
            return "\(label) exited with code \(exitCode)"
        }
        return "\(label) failed"
    }

    private static func userVisibleRisk(
        suiteName: String? = nil,
        metric: String? = nil,
        phaseName: String? = nil,
        checkLabel: String? = nil
    ) -> String {
        let text = [phaseName, checkLabel, suiteName, metric]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if text.contains("audio safety") ||
            text.contains("underrun") ||
            text.contains("droppedcommand") ||
            text.contains("output-device") ||
            text.contains("playback") ||
            text.contains("firstplay") ||
            text.contains("playcommand") ||
            text.contains("loop") ||
            text.contains("seekframe") ||
            text.contains("import playback")
        {
            return "Audio could skip, route to the wrong device, seek to the wrong sample, loop inaccurately, or fail after import."
        }
        if text.contains("launch") ||
            text.contains("startup") ||
            text.contains("windowvisible") ||
            text.contains("waveformvisible") ||
            text.contains("placeholder") ||
            text.contains("firstpaint") ||
            text.contains("close")
        {
            return "The app could open or close with visible delay, blank tracks, stale size, or missing first-frame waveforms."
        }
        if text.contains("hot path") ||
            text.contains("cpuwaveform") ||
            text.contains("fallback") ||
            text.contains("shaderupload") ||
            text.contains("mainthread") ||
            text.contains("dashboard")
        {
            return "Timeline playback, zooming, panning, selection, delete, or paste could hitch or drop frames."
        }
        if text.contains("interaction") ||
            text.contains("selection") ||
            text.contains("drag") ||
            text.contains("paste") ||
            text.contains("delete") ||
            text.contains("replay")
        {
            return "Core editing gestures could lag behind the pointer, paste at the wrong location, or animate incorrectly."
        }
        if text.contains("visual") ||
            text.contains("playhead") ||
            text.contains("transcript") ||
            text.contains("mute") ||
            text.contains("solo") ||
            text.contains("coarse") ||
            text.contains("blank")
        {
            return "The timeline could show stale waveforms, wrong brightness, playhead desync, or transcript highlight mismatch."
        }
        if text.contains("import") ||
            text.contains("mp3") ||
            text.contains("aiff") ||
            text.contains("flac") ||
            text.contains("m4a") ||
            text.contains("aac")
        {
            return "Common audio files could fail to import, become editable too slowly, or play back incorrectly."
        }
        if text.contains("transcription") {
            return "Transcript text could fail to persist, desync from audio, or make the timeline sluggish."
        }
        if text.contains("diagnostics") {
            return "The Development Console could miss useful incident data or affect the performance it is measuring."
        }
        return "A shippability regression could reach manual testing without a clear diagnosis."
    }

    private static func copiedPaths(in directory: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path),
              let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return []
        }

        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                paths.append(url.path)
            }
        }
        return paths.sorted()
    }

    private static func markdownEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func writeReports(
        _ report: inout GateReport,
        reportRoot: URL,
        runDirectory: URL
    ) throws -> GateReportArtifacts {
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reportRoot, withIntermediateDirectories: true)
        let runReportURL = runDirectory.appendingPathComponent("shippability-gate-report.json")
        let latestReportURL = reportRoot.appendingPathComponent("latest-report.json")
        let runMarkdownURL = runDirectory.appendingPathComponent("shippability-gate-report.md")
        let latestMarkdownURL = reportRoot.appendingPathComponent("latest-report.md")

        report.runReportPath = runReportURL.path
        report.latestReportPath = latestReportURL.path
        report.markdownReportPath = runMarkdownURL.path
        report.latestMarkdownReportPath = latestMarkdownURL.path

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: runReportURL, options: [.atomic])
        try data.write(to: latestReportURL, options: [.atomic])

        let markdown = markdownReport(for: report)
        try markdown.write(to: runMarkdownURL, atomically: true, encoding: .utf8)
        try markdown.write(to: latestMarkdownURL, atomically: true, encoding: .utf8)

        let stabilityChecks = report.phases.map { phase in
            StabilityCheckReport(
                name: phase.name,
                status: phase.status,
                detail: phase.failureMessage ?? phase.detail
            )
        }
        _ = StabilityReportWriter.writeSuite(
            name: "shippability-gate",
            status: report.status,
            startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds - UInt64(max(report.durationMilliseconds, 0) * 1_000_000),
            checks: stabilityChecks,
            metadata: [
                "mode": report.mode,
                "tierDescription": report.tierDescription ?? "",
                "targetRuntimeMilliseconds": report.targetRuntimeMilliseconds.map { String(format: "%.1f", $0) } ?? "",
                "productBar": report.productBar ?? "",
                "productBarDecision": report.productBarDecision ?? "",
                "featureDoneCommand": report.featureDoneCommand ?? "",
                "releaseCandidateCommand": report.releaseCandidateCommand ?? "",
                "fixtureRoot": report.fixtureRoot,
                "keptFixtures": "\(report.keptFixtures)",
                "runDirectory": report.runDirectory,
                "budgetFailureCount": "\(report.budgetFailureCount)",
                "budgetWarningCount": "\(report.budgetWarningCount)",
                "regressionWarningCount": "\(report.regressionWarnings.count)",
            ],
            arguments: ["Soundtime", "--report-dir", reportRoot.path]
        )
        return GateReportArtifacts(
            runReportURL: runReportURL,
            latestReportURL: latestReportURL,
            runMarkdownURL: runMarkdownURL,
            latestMarkdownURL: latestMarkdownURL
        )
    }

    private static func writeFailureArtifacts(
        report: GateReport,
        reportURL: URL,
        markdownURL: URL,
        failureDirectory: URL,
        logDirectory: URL,
        stabilityReportDirectory: URL
    ) {
        do {
            try FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
            let copiedReportURL = failureDirectory.appendingPathComponent("shippability-gate-report.json")
            try? FileManager.default.removeItem(at: copiedReportURL)
            try FileManager.default.copyItem(at: reportURL, to: copiedReportURL)
            let copiedMarkdownURL = failureDirectory.appendingPathComponent("shippability-gate-report.md")
            try? FileManager.default.removeItem(at: copiedMarkdownURL)
            try FileManager.default.copyItem(at: markdownURL, to: copiedMarkdownURL)
            let copiedLogDirectory = failureDirectory.appendingPathComponent("logs", isDirectory: true)
            try? FileManager.default.removeItem(at: copiedLogDirectory)
            if FileManager.default.fileExists(atPath: logDirectory.path) {
                try FileManager.default.copyItem(at: logDirectory, to: copiedLogDirectory)
            }
            let copiedStabilityDirectory = failureDirectory.appendingPathComponent("stability-reports", isDirectory: true)
            try? FileManager.default.removeItem(at: copiedStabilityDirectory)
            if FileManager.default.fileExists(atPath: stabilityReportDirectory.path) {
                try FileManager.default.copyItem(at: stabilityReportDirectory, to: copiedStabilityDirectory)
            }

            let failures = issueSummaries(in: report, severities: ["failure"])
            let warnings = issueSummaries(in: report, severities: ["warning"])
            let bundle = GateTraceBundle(
                schemaVersion: 2,
                generatedAt: Date(),
                status: report.status,
                mode: report.mode,
                productBar: report.productBar,
                productBarDecision: report.productBarDecision,
                failureCount: failures.count,
                warningCount: warnings.count,
                primaryFailure: failures.first,
                commandLine: report.commandLine,
                reportPath: copiedReportURL.path,
                markdownReportPath: copiedMarkdownURL.path,
                runDirectory: report.runDirectory,
                fixtureRoot: report.fixtureRoot,
                failures: failures,
                warnings: warnings,
                logs: copiedPaths(in: copiedLogDirectory),
                stabilityReports: copiedPaths(in: copiedStabilityDirectory),
                rerunCommand: report.commandLine
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bundleData = try encoder.encode(bundle)
            let traceURL = failureDirectory.appendingPathComponent("trace-bundle.json")
            try bundleData.write(to: traceURL, options: [.atomic])

            let summary = failureMarkdownSummary(
                report: report,
                copiedReportURL: copiedReportURL,
                copiedMarkdownURL: copiedMarkdownURL,
                traceURL: traceURL,
                failures: failures,
                warnings: warnings
            )
            try summary.write(
                to: failureDirectory.appendingPathComponent("failure-summary.md"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            print("warning: could not write failure artifacts: \(error)")
        }
    }

    private static func cleanupFixturesIfNeeded(rootDirectory: URL, keepFixtures: Bool) {
        guard !keepFixtures else {
            return
        }
        try? FileManager.default.removeItem(at: rootDirectory)
        let parent = rootDirectory.deletingLastPathComponent()
        if parent.lastPathComponent == "fixtures" {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    private static func explicitFixtureOutput(arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--fixtures-output") else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex), !arguments[valueIndex].isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: arguments[valueIndex], isDirectory: true).standardizedFileURL
    }

    private static func reportRootDirectory(arguments: [String]) -> URL {
        if let reportDirectory = explicitReportDirectory(arguments: arguments) {
            return reportDirectory
        }
        if let environmentPath = ProcessInfo.processInfo.environment["SOUNDTIME_SHIPPABILITY_REPORT_DIR"],
           !environmentPath.isEmpty
        {
            return URL(fileURLWithPath: environmentPath, isDirectory: true)
        }
        if let stabilityPath = ProcessInfo.processInfo.environment["SOUNDTIME_STABILITY_REPORT_DIR"],
           !stabilityPath.isEmpty
        {
            return URL(fileURLWithPath: stabilityPath, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/shippability-gate", isDirectory: true)
    }

    private static func defaultFixtureCacheDirectory() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/shippability-fixtures/v1", isDirectory: true)
            .standardizedFileURL
    }

    private static func explicitReportDirectory(arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--report-dir") else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex), !arguments[valueIndex].isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: arguments[valueIndex], isDirectory: true)
    }

    private static func currentExecutableURL(arguments: [String]) throws -> URL {
        let executablePath = arguments.first ?? CommandLine.arguments.first ?? ""
        guard !executablePath.isEmpty else {
            throw GateError.executableUnavailable(executablePath)
        }
        if executablePath.hasPrefix("/") {
            return URL(fileURLWithPath: executablePath).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(executablePath)
            .standardizedFileURL
    }

    private static func gitCommitShortHash() -> String? {
        let result = runGit(arguments: ["rev-parse", "--short", "HEAD"])
        guard result.exitCode == 0 else {
            return nil
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runGit(arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (127, "\(error)")
        }
    }

    private static func formatPhaseLine(
        status: String,
        name: String,
        milliseconds: Double
    ) -> String {
        "\(status.padding(toLength: 4, withPad: " ", startingAt: 0)) \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(String(format: "%.1fms", milliseconds))"
    }

    private static func commandLine(
        executableURL: URL,
        arguments: [String]
    ) -> String {
        ([executableURL.path] + arguments).map(shellQuoted).joined(separator: " ")
    }

    private static func shellQuoted(_ string: String) -> String {
        guard string.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines) != nil else {
            return string
        }
        return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func timestampSlug() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let sanitized = name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "check" : sanitized
    }

    private static func tail(_ output: String, limit: Int) -> String {
        guard output.count > limit else {
            return output
        }
        return String(output.suffix(limit))
    }

    private static func elapsedMilliseconds(since startedAtNanoseconds: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startedAtNanoseconds) / 1_000_000
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw GateError.selfTestFailed(message)
        }
    }
}
