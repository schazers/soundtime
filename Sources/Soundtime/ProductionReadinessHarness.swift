import Darwin
import Foundation

enum ProductionReadinessHarness {
    private struct PhasePlan {
        let number: Int
        let name: String
        let goal: String
        let work: [String]
        let qualityGate: [String]
        let manualChecks: [String]
        let smokeCommands: [SmokeCommand]
    }

    private struct SmokeCommand {
        let label: String
        let arguments: [String]
        let runsInQuickMode: Bool
    }

    private struct CommandResult {
        let phaseNumber: Int
        let phaseName: String
        let label: String
        let commandLine: String
        let exitCode: Int32
        let durationMilliseconds: Double
        let outputTail: String
    }

    private enum HarnessError: LocalizedError {
        case failed([CommandResult])
        case executableUnavailable(String)

        var errorDescription: String? {
            switch self {
            case let .failed(results):
                let failed = results.filter { $0.exitCode != 0 }
                let details = failed.map {
                    "phase \($0.phaseNumber) \($0.phaseName): \($0.label) exited \($0.exitCode)\n\($0.outputTail)"
                }.joined(separator: "\n\n")
                return "production readiness smoke failed:\n\(details)"
            case let .executableUnavailable(path):
                return "production readiness smoke could not resolve executable: \(path)"
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let quickMode = arguments.contains("--quick") || arguments.contains("--production-readiness-smoke-quick")
        let planOnly = arguments.contains("--plan-only") || arguments.contains("--production-readiness-plan")
        let phases = makePhasePlans()

        printPlan(phases)
        guard !planOnly else {
            writePlanOnlyReport(
                startedAtNanoseconds: startedAtNanoseconds,
                phases: phases,
                arguments: arguments
            )
            return
        }

        let executableURL = try currentExecutableURL(arguments: arguments)
        let reportRoot = reportRootDirectory(arguments: arguments)
        let childReportDirectory = reportRoot.appendingPathComponent("child-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: childReportDirectory, withIntermediateDirectories: true)

        print("")
        print("Running Soundtime production readiness smoke")
        print("mode=\(quickMode ? "quick" : "full") executable=\(executableURL.path)")
        print("reports=\(reportRoot.path)")
        fflush(stdout)

        var commandResults: [CommandResult] = []
        var cachedResultsByCommandKey: [String: CommandResult] = [:]
        for phase in phases {
            let runnableCommands = phase.smokeCommands.filter { quickMode ? $0.runsInQuickMode : true }
            guard !runnableCommands.isEmpty else {
                print("skip phase \(phase.number): \(phase.name) (no automated smoke command yet)")
                fflush(stdout)
                continue
            }

            for command in runnableCommands {
                let phaseReportDirectory = childReportDirectory
                    .appendingPathComponent("phase-\(phase.number)-\(sanitizedFileName(phase.name))", isDirectory: true)
                var childArguments = command.arguments
                childArguments.append(contentsOf: ["--report-dir", phaseReportDirectory.path])
                if quickMode, !childArguments.contains("--quick") {
                    childArguments.append("--quick")
                }

                let commandKey = canonicalCommandKey(arguments: childArguments)
                let result: CommandResult
                if let cachedResult = cachedResultsByCommandKey[commandKey] {
                    result = CommandResult(
                        phaseNumber: phase.number,
                        phaseName: phase.name,
                        label: command.label,
                        commandLine: cachedResult.commandLine,
                        exitCode: cachedResult.exitCode,
                        durationMilliseconds: 0,
                        outputTail: "reused result from phase \(cachedResult.phaseNumber): \(cachedResult.label)"
                    )
                } else {
                    let freshResult = runChildCommand(
                        executableURL: executableURL,
                        phase: phase,
                        command: command,
                        arguments: childArguments
                    )
                    cachedResultsByCommandKey[commandKey] = freshResult
                    result = freshResult
                }
                commandResults.append(result)
                let status = result.exitCode == 0 ? (result.durationMilliseconds == 0 ? "reuse" : "ok") : "failed"
                print(
                    String(
                        format: "%@ phase %02d %-32@ %.1fms",
                        status,
                        phase.number,
                        command.label as NSString,
                        result.durationMilliseconds
                    )
                )
                if result.exitCode != 0 {
                    print(result.outputTail)
                }
                fflush(stdout)
            }
        }

        let failedResults = commandResults.filter { $0.exitCode != 0 }
        let reports = phaseReports(phases: phases, commandResults: commandResults)
        let status = failedResults.isEmpty ? "passed" : "failed"
        if let reportURL = StabilityReportWriter.writeSuite(
            name: "production-readiness-smoke",
            status: status,
            startedAtNanoseconds: startedAtNanoseconds,
            checks: reports,
            metadata: [
                "mode": quickMode ? "quick" : "full",
                "phaseCount": "\(phases.count)",
                "commandCount": "\(commandResults.count)",
                "failedCommandCount": "\(failedResults.count)",
                "childReportDirectory": childReportDirectory.path,
            ],
            arguments: argumentsWithReportDirectory(arguments, reportRoot: reportRoot)
        ) {
            print("wrote production readiness report: \(reportURL.path)")
            fflush(stdout)
        }

        guard failedResults.isEmpty else {
            throw HarnessError.failed(commandResults)
        }
        print("Soundtime production readiness smoke passed: \(commandResults.count) checks")
        fflush(stdout)
    }

    private static func makePhasePlans() -> [PhasePlan] {
        [
            PhasePlan(
                number: 1,
                name: "Lock The Baseline",
                goal: "Turn the golden project set into a repeatable scoreboard for launch, render, edit, import, audio, and transcription stability.",
                work: [
                    "Keep canonical short, long, MP3, multitrack, and stress fixtures available locally.",
                    "Run launch, timeline UX, timeline perf, import, edit graph, diagnostics, and transcription harnesses from one command.",
                    "Write one parent stability report plus child reports for focused harnesses.",
                    "Fail the suite when a protected contract regresses instead of relying only on manual feel.",
                ],
                qualityGate: [
                    "One command runs the current production baseline.",
                    "Reports include pass/fail status, duration, and enough command output to diagnose failure.",
                    "The runner works in quick mode for frequent local use and full mode for heavier runs.",
                ],
                manualChecks: [
                    "Open the report directory and confirm per-phase child reports are written.",
                    "Run quick mode before every risky interaction/rendering change.",
                ],
                smokeCommands: [
                    SmokeCommand(label: "launch snapshot readiness", arguments: ["--launch-performance-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "timeline UX render contracts", arguments: ["--timeline-ux-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "timeline performance baseline", arguments: ["--timeline-perf-baseline", "--quick"], runsInQuickMode: true),
                    SmokeCommand(label: "audio import contracts", arguments: ["--audio-asset-importer-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "edit graph contracts", arguments: ["--edit-graph-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "project edit round trip", arguments: ["--project-edit-roundtrip-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "diagnostics contracts", arguments: ["--diagnostics-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "transcription contracts", arguments: ["--transcription-smoke"], runsInQuickMode: true),
                ]
            ),
            PhasePlan(
                number: 2,
                name: "Startup Must Feel Instant",
                goal: "Show the final-size window, track shell, cached previews, and basic playback affordances immediately.",
                work: [
                    "Measure process entry, window visible, visual skeleton, first waveform, and playback prime milestones.",
                    "Keep first-paint snapshot loading bounded by byte and time budgets.",
                    "Defer per-track source validation until full restore so cached previews never blank the first frame.",
                    "Hydrate audio and waveform refinement after the first usable frame.",
                    "Never present blank cached tracks unless the source is truly stale or missing.",
                    "Persist only tiny launch state synchronously on close; keep waveform packet/manifest writes fresh before quit.",
                ],
                qualityGate: [
                    "Cached multitrack projects show tracks and previews on first paint.",
                    "No project decode, waveform refinement, or zero-crossing work blocks first window display.",
                    "Source changes are detected by full restore without blocking first-paint visuals.",
                    "Missing/stale source state is diagnostic, not a normal visual blank.",
                    "Close-path diagnostics report no synchronous launch snapshot or first-frame packet writes.",
                ],
                manualChecks: [
                    "Launch a previously opened three-track project and confirm final window size appears immediately.",
                    "Hit play as soon as the window appears and confirm no beach ball.",
                    "Quit with a loaded multitrack project and confirm the window disappears immediately without a beach ball.",
                ],
                smokeCommands: [
                    SmokeCommand(label: "launch performance smoke", arguments: ["--launch-performance-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "full launch performance smoke", arguments: ["--launch-performance-smoke-full"], runsInQuickMode: false),
                ]
            ),
            PhasePlan(
                number: 3,
                name: "Waveform Rendering Finalization",
                goal: "Make waveform drawing stable: no flicker, no surprise coarse swaps, no stale zoom transforms, no CPU fallback on interaction.",
                work: [
                    "Enforce resident GPU or last-good visual selection in the renderer.",
                    "Track tile misses, upload bytes, fallback draws, and last-good holds.",
                    "Keep zoom and pan as immediate transform/uniform changes.",
                    "Keep playhead glow and transient effects source-time aligned after loops and edits.",
                ],
                qualityGate: [
                    "Hot-path frame stats report zero CPU waveform vertices.",
                    "Timeline UX smoke catches playhead, seek, zoom, pan, ultra-zoom, and refinement regressions.",
                    "Perf baseline stays under protected frame budgets.",
                ],
                manualChecks: [
                    "Zoom rapidly while playing and confirm waveform and grid move together.",
                    "Loop playback and confirm glow/transients stay aligned on every pass.",
                ],
                smokeCommands: [
                    SmokeCommand(label: "waveform disk cache", arguments: ["--waveform-disk-cache-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "waveform tiled pipeline", arguments: ["--waveform-tiled-render-pipeline-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "timeline UX waveform checks", arguments: ["--timeline-ux-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "timeline perf waveform checks", arguments: ["--timeline-perf-baseline", "--quick"], runsInQuickMode: true),
                ]
            ),
            PhasePlan(
                number: 4,
                name: "Selection Interaction Hot Path",
                goal: "Make region selection feel directly attached to the pointer at display refresh rate.",
                work: [
                    "Keep pointer state in tiny view-level render uniforms.",
                    "Compute selection bounds from current drag state, not delayed model side effects.",
                    "Keep tickle/glass/glow effects bounded and shader-only.",
                    "Expose mouse-to-selection-edge latency and frame budget smoke coverage.",
                ],
                qualityGate: [
                    "Rapid selection drag smoke remains responsive and visible.",
                    "No transcript layout, import, cache, diagnostics, or autosave work participates in drag feedback.",
                    "No CPU waveform fallback is allowed because of selection effects.",
                ],
                manualChecks: [
                    "Drag a selection quickly left and right and confirm the edge cannot trail the cursor.",
                    "Watch Development Console for no hot-path violations during drag.",
                ],
                smokeCommands: [
                    SmokeCommand(label: "timeline UX selection checks", arguments: ["--timeline-ux-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "timeline perf edit overlays", arguments: ["--timeline-perf-baseline", "--quick"], runsInQuickMode: true),
                ]
            ),
            PhasePlan(
                number: 5,
                name: "Delete Paste Undo Reliability",
                goal: "Make edit commands boringly correct across WAV, MP3 proxies, groups, undo, redo, and animations.",
                work: [
                    "Treat delete and paste as edit-graph mutations plus visual remaps.",
                    "Keep visible result independent of waveform rebuild or autosave timing.",
                    "Protect animation windows from autosave, hydration, and stale delayed refresh closures.",
                    "Verify playhead, viewport, selection, loop, and edit group state round-trip through undo/redo.",
                ],
                qualityGate: [
                    "Project edit round-trip and edit graph smoke pass.",
                    "Imported proxy files and WAV files hit the same edit timeline path before delete.",
                    "Paste selection is flush with playhead and no stale visual segment stretches.",
                ],
                manualChecks: [
                    "Run 100 delete/undo/delete cycles on grouped tracks.",
                    "Paste/undo/paste a region and confirm no gap or visual stretch.",
                ],
                smokeCommands: [
                    SmokeCommand(label: "edit graph smoke", arguments: ["--edit-graph-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "project edit round-trip smoke", arguments: ["--project-edit-roundtrip-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "timeline UX edit animation checks", arguments: ["--timeline-ux-smoke"], runsInQuickMode: true),
                ]
            ),
            PhasePlan(
                number: 6,
                name: "Audio Engine Confidence",
                goal: "Keep realtime playback sacred: no locks, allocations, underruns, route bugs, or sample-time surprises.",
                work: [
                    "Surface underruns, dropped commands, deadline misses, and route changes in diagnostics.",
                    "Stress prepared sources, segmented tracks, overlapping graph updates, gain ramps, pause, seek, and loop behavior.",
                    "Move large edit graphs toward active segment cursors and block-aware rendering.",
                    "Verify output device switching reaches the actual realtime output unit.",
                ],
                qualityGate: [
                    "Audio core tests pass.",
                    "Realtime graph publish smoke catches unsafe graph swaps.",
                    "Diagnostics smoke records audio deadline and underrun events.",
                ],
                manualChecks: [
                    "Switch output devices during playback and confirm audio moves immediately.",
                    "Seek/loop while playing and listen for clicks or repeats.",
                ],
                smokeCommands: [
                    SmokeCommand(label: "realtime graph publish", arguments: ["--realtime-graph-publish-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "recording smoke", arguments: ["--recording-smoke"], runsInQuickMode: false),
                    SmokeCommand(label: "diagnostics audio events", arguments: ["--diagnostics-smoke"], runsInQuickMode: true),
                ]
            ),
            PhasePlan(
                number: 7,
                name: "Import Pipeline",
                goal: "Make common audio files appear quickly, become editable safely, and behave identically after import.",
                work: [
                    "Use native metadata inspection immediately.",
                    "Create preview/proxy work asynchronously and cancelably.",
                    "Fingerprint source/proxy identity durably.",
                    "Make WAV, AIFF, MP3, M4A/AAC, FLAC, CAF, AC3/EAC3, AMR, AU/SND behavior explicit.",
                ],
                qualityGate: [
                    "Importer smoke verifies common format recognition and proxy delete behavior.",
                    "Unsupported recognized formats show an explicit user-level error path.",
                    "Imported proxies use the same edit timeline semantics as WAV files.",
                ],
                manualChecks: [
                    "Drag an MP3 and confirm track shell appears immediately and playback follows soon after.",
                    "Delete the first half-second of imported MP3 and confirm the visual/edit/audio path matches WAV.",
                ],
                smokeCommands: [
                    SmokeCommand(label: "audio import smoke", arguments: ["--audio-asset-importer-smoke"], runsInQuickMode: true),
                ]
            ),
            PhasePlan(
                number: 8,
                name: "Transcription Product Loop",
                goal: "Make one-hour podcast transcripts visible, selectable, navigable, persistent, and eventually editable.",
                work: [
                    "Harden Deepgram chunking, retry, recovery, and provider error handling.",
                    "Persist transcript sidecars and source revision validity.",
                    "Use virtualized/cached text layout so transcript drawing cannot hurt frame pacing.",
                    "Map word hover, click seek, text drag selection, and edit commands through source-time maps.",
                ],
                qualityGate: [
                    "Transcription smoke verifies parser, chunking, interaction, sidecars, export, and edit planning.",
                    "Timeline render track carries transcript metadata without forcing full layout on hot frames.",
                    "Live Deepgram smoke is available when a key and sample file are provided.",
                ],
                manualChecks: [
                    "Transcribe a voice file, show transcript layer, hover/click/drag words, and watch frame rate.",
                    "Edit text selection should mirror the same audio range precisely.",
                ],
                smokeCommands: [
                    SmokeCommand(label: "transcription smoke", arguments: ["--transcription-smoke"], runsInQuickMode: true),
                ]
            ),
            PhasePlan(
                number: 9,
                name: "API Processing Jobs",
                goal: "Make denoise/stem/API work cancelable, understandable, undoable, and unable to corrupt timeline state.",
                work: [
                    "Represent provider work as queued jobs with stable source revisions.",
                    "Surface progress, cancellation, retry, and errors in modal UI and Development Console.",
                    "Keep before/after or stem review playback zero-latency by preloading both sides.",
                    "Apply accepted results as undoable edit graph changes only.",
                ],
                qualityGate: [
                    "Audio processing smoke verifies fake/local provider request/result/undo behavior.",
                    "Provider credentials use Keychain with environment fallback only for development.",
                    "Failed jobs do not mutate project state.",
                ],
                manualChecks: [
                    "Cancel denoise midway and confirm provider cancel, no selection loss, no timeline mutation.",
                    "Accept/reject a result and confirm undo/redo never re-calls the provider.",
                ],
                smokeCommands: [
                    SmokeCommand(label: "audio processing smoke", arguments: ["--audio-processing-smoke"], runsInQuickMode: true),
                ]
            ),
            PhasePlan(
                number: 10,
                name: "Podcast Editor Essentials",
                goal: "Finish the core edit/export feature set needed for real podcast delivery.",
                work: [
                    "Polish ripple delete, clear gap, split, trim, fades, gains, duplicate, nudge, slip, and heal joins.",
                    "Add silence detection review and high-confidence batch acceptance.",
                    "Export WAV, MP3/AAC, selection, mixdown, and stems.",
                    "Add podcast loudness normalization targets and export validation.",
                ],
                qualityGate: [
                    "Edit graph and project round-trip smoke verify non-destructive edit semantics.",
                    "Export smoke should eventually verify duration, channels, sample rate, loudness metadata, and file integrity.",
                    "Manual full episode edit and export succeeds without app restart.",
                ],
                manualChecks: [
                    "Finish a short episode: import, cut dead air, paste, normalize, export.",
                    "Reopen the exported project and confirm all edits and transcript state persist.",
                ],
                smokeCommands: [
                    SmokeCommand(label: "edit graph podcast essentials", arguments: ["--edit-graph-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "project round-trip podcast essentials", arguments: ["--project-edit-roundtrip-smoke"], runsInQuickMode: true),
                ]
            ),
            PhasePlan(
                number: 11,
                name: "Development Console",
                goal: "Make diagnostics useful without ever becoming the cause of the slowdown.",
                work: [
                    "Cap console update/render rate separately from timeline display link.",
                    "Record stalls, tile misses, uploads, autosaves, hydration, imports, API jobs, and audio deadline misses.",
                    "Export trace bundles with recent events and sampled performance history.",
                    "Provide severity rules that flag render/audio/thread problems plainly.",
                ],
                qualityGate: [
                    "Diagnostics smoke verifies escalation, retention, trace writing, and audio/render event capture.",
                    "Dashboard lifecycle smoke catches display link and window close crashes.",
                    "Opening the console does not materially change timeline FPS.",
                ],
                manualChecks: [
                    "Open/close Development Console repeatedly during playback and watch FPS.",
                    "Export a trace immediately after a hitch and confirm it contains the relevant timeline.",
                ],
                smokeCommands: [
                    SmokeCommand(label: "diagnostics smoke", arguments: ["--diagnostics-smoke"], runsInQuickMode: true),
                    SmokeCommand(label: "dashboard lifecycle smoke", arguments: ["--performance-dashboard-lifecycle-smoke"], runsInQuickMode: false),
                ]
            ),
            PhasePlan(
                number: 12,
                name: "Testing And Release Discipline",
                goal: "Make regressions fail locally before they reach manual testing.",
                work: [
                    "Keep one parent production readiness command.",
                    "Run focused smoke harnesses for launch, render, selection, edit, import, transcription, API, diagnostics, and audio.",
                    "Add sanitizer and UI automation lanes for release candidates.",
                    "Assert no hot-path fallback in protected interaction/playback/delete windows.",
                ],
                qualityGate: [
                    "Quick readiness suite passes before risky commits.",
                    "Full readiness suite is available for release checks.",
                    "CI/local thresholds produce actionable failure output.",
                ],
                manualChecks: [
                    "Run the quick suite before manual testing.",
                    "Run the full suite before a tagged build.",
                ],
                smokeCommands: [
                    SmokeCommand(label: "production suite self-check", arguments: ["--diagnostics-smoke"], runsInQuickMode: true),
                ]
            ),
            PhasePlan(
                number: 13,
                name: "Product Polish",
                goal: "Unify the final visible experience after the core loop is stable.",
                work: [
                    "Lock waveform aesthetic, silence rendering, playhead glow, selection glass, loop region, and paste/delete animations.",
                    "Polish menus, preferences, command validation, shortcut map, and empty/import states.",
                    "Add accessibility basics for controls and transcript navigation.",
                    "Remove or hide debug-only experiments outside debug mode.",
                ],
                qualityGate: [
                    "Timeline UX smoke catches major visual blank/desync regressions.",
                    "Manual design pass confirms the app feels intentional rather than assembled from experiments.",
                    "No product polish adds hot-path CPU or layout work.",
                ],
                manualChecks: [
                    "Run through launch, import, edit, transcribe, export on a real podcast file.",
                    "Check visual states at idle, hover, drag, playback, modal, and disabled states.",
                ],
                smokeCommands: [
                    SmokeCommand(label: "timeline UX polish guard", arguments: ["--timeline-ux-smoke"], runsInQuickMode: true),
                ]
            ),
        ]
    }

    private static func printPlan(_ phases: [PhasePlan]) {
        print("Soundtime production readiness plan")
        for phase in phases {
            print("")
            print("\(phase.number). \(phase.name)")
            print("Goal: \(phase.goal)")
            print("Work:")
            phase.work.forEach { print("  - \($0)") }
            print("Quality gate:")
            phase.qualityGate.forEach { print("  - \($0)") }
            print("Manual checks:")
            phase.manualChecks.forEach { print("  - \($0)") }
        }
    }

    private static func runChildCommand(
        executableURL: URL,
        phase: PhasePlan,
        command: SmokeCommand,
        arguments: [String]
    ) -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundtime-production-readiness-child-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try? FileHandle(forWritingTo: outputURL)
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        let startedAt = DispatchTime.now().uptimeNanoseconds

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            let durationMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            return CommandResult(
                phaseNumber: phase.number,
                phaseName: phase.name,
                label: command.label,
                commandLine: commandLine(executableURL: executableURL, arguments: arguments),
                exitCode: 127,
                durationMilliseconds: durationMilliseconds,
                outputTail: "failed to launch child command: \(error)"
            )
        }

        let durationMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        try? outputHandle?.close()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: outputURL)
        return CommandResult(
            phaseNumber: phase.number,
            phaseName: phase.name,
            label: command.label,
            commandLine: commandLine(executableURL: executableURL, arguments: arguments),
            exitCode: process.terminationStatus,
            durationMilliseconds: durationMilliseconds,
            outputTail: tail(output, limit: 4_000)
        )
    }

    private static func phaseReports(
        phases: [PhasePlan],
        commandResults: [CommandResult]
    ) -> [StabilityCheckReport] {
        phases.map { phase in
            let phaseResults = commandResults.filter { $0.phaseNumber == phase.number }
            if phaseResults.isEmpty {
                return StabilityCheckReport(
                    name: "phase \(phase.number): \(phase.name)",
                    status: "skipped",
                    detail: "No automated smoke command is currently registered for this phase."
                )
            }

            let failed = phaseResults.filter { $0.exitCode != 0 }
            let detail = phaseResults.map {
                let status = $0.exitCode == 0 ? "passed" : "failed"
                return [
                    "\(status): \($0.label)",
                    "command: \($0.commandLine)",
                    String(format: "durationMs: %.1f", $0.durationMilliseconds),
                    $0.exitCode == 0 ? nil : "output:\n\($0.outputTail)",
                ].compactMap { $0 }.joined(separator: "\n")
            }.joined(separator: "\n\n")
            return StabilityCheckReport(
                name: "phase \(phase.number): \(phase.name)",
                status: failed.isEmpty ? "passed" : "failed",
                detail: detail
            )
        }
    }

    private static func writePlanOnlyReport(
        startedAtNanoseconds: UInt64,
        phases: [PhasePlan],
        arguments: [String]
    ) {
        let reports = phases.map { phase in
            StabilityCheckReport(
                name: "phase \(phase.number): \(phase.name)",
                status: "planned",
                detail: ([
                    "goal: \(phase.goal)",
                    "work:",
                ] + phase.work.map { "- \($0)" } + [
                    "quality gate:",
                ] + phase.qualityGate.map { "- \($0)" }).joined(separator: "\n")
            )
        }
        if let reportURL = StabilityReportWriter.writeSuite(
            name: "production-readiness-plan",
            status: "planned",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: reports,
            metadata: ["phaseCount": "\(phases.count)"],
            arguments: arguments
        ) {
            print("wrote production readiness plan report: \(reportURL.path)")
        }
    }

    private static func currentExecutableURL(arguments: [String]) throws -> URL {
        let executablePath = arguments.first ?? CommandLine.arguments.first ?? ""
        guard !executablePath.isEmpty else {
            throw HarnessError.executableUnavailable(executablePath)
        }

        if executablePath.hasPrefix("/") {
            return URL(fileURLWithPath: executablePath).standardizedFileURL
        }

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return currentDirectory.appendingPathComponent(executablePath).standardizedFileURL
    }

    private static func reportRootDirectory(arguments: [String]) -> URL {
        if let explicit = explicitReportDirectory(arguments: arguments) {
            return explicit
        }

        if let environmentPath = ProcessInfo.processInfo.environment["SOUNDTIME_STABILITY_REPORT_DIR"],
           !environmentPath.isEmpty
        {
            return URL(fileURLWithPath: environmentPath, isDirectory: true)
        }

        return FileManager.default.temporaryDirectory
            .appendingPathComponent("soundtime-production-readiness-\(UUID().uuidString)", isDirectory: true)
    }

    private static func argumentsWithReportDirectory(_ arguments: [String], reportRoot: URL) -> [String] {
        guard explicitReportDirectory(arguments: arguments) == nil else {
            return arguments
        }
        return arguments + ["--report-dir", reportRoot.path]
    }

    private static func explicitReportDirectory(arguments: [String]) -> URL? {
        guard let flagIndex = arguments.firstIndex(of: "--report-dir") else {
            return nil
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex), !arguments[valueIndex].isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: arguments[valueIndex], isDirectory: true)
    }

    private static func commandLine(executableURL: URL, arguments: [String]) -> String {
        ([executableURL.path] + arguments).map(shellQuoted).joined(separator: " ")
    }

    private static func canonicalCommandKey(arguments: [String]) -> String {
        var canonical: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--report-dir" {
                index = arguments.index(after: index)
                if index < arguments.endIndex {
                    index = arguments.index(after: index)
                }
                continue
            }
            canonical.append(argument)
            index = arguments.index(after: index)
        }
        return canonical.joined(separator: "\u{1F}")
    }

    private static func shellQuoted(_ string: String) -> String {
        guard string.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines) != nil else {
            return string
        }
        return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let sanitized = name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "phase" : sanitized
    }

    private static func tail(_ output: String, limit: Int) -> String {
        guard output.count > limit else {
            return output
        }
        return String(output.suffix(limit))
    }
}
