import AppKit
import Darwin

if CommandLine.arguments.contains("--timeline-perf-baseline") {
    do {
        try TimelinePerfBaselineHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime timeline perf baseline failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--recording-smoke") {
    do {
        try RecordingSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime recording smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
