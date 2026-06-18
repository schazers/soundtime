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

if CommandLine.arguments.contains("--timeline-ux-smoke") {
    do {
        try TimelineUXSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime timeline UX smoke failed: \(error)\n", stderr)
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

if CommandLine.arguments.contains("--diagnostics-smoke") {
    do {
        try DiagnosticsSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime diagnostics smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--waveform-tile-model-smoke") {
    do {
        try WaveformTileModelSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime waveform tile model smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--waveform-disk-cache-smoke") {
    do {
        try WaveformDiskCacheSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime waveform disk cache smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--waveform-peak-tile-builder-smoke") {
    do {
        try WaveformPeakTileBuilderSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime waveform peak tile builder smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--waveform-tile-scheduler-smoke") {
    do {
        try WaveformTileSchedulerSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime waveform tile scheduler smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--waveform-tile-request-queue-smoke") {
    do {
        try WaveformTileRequestQueueSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime waveform tile request queue smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--waveform-tile-build-worker-smoke") {
    do {
        try WaveformTileBuildWorkerSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime waveform tile build worker smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--waveform-tile-upload-coordinator-smoke") {
    do {
        try WaveformTileUploadCoordinatorSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime waveform tile upload coordinator smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--waveform-tile-render-selector-smoke") {
    do {
        try WaveformTileRenderSelectorSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime waveform tile render selector smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--waveform-tile-promotion-planner-smoke") {
    do {
        try WaveformTilePromotionPlannerSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime waveform tile promotion planner smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--waveform-tiled-render-pipeline-smoke") {
    do {
        try WaveformTiledRenderPipelineSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime waveform tiled render pipeline smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--agent-command-bar-smoke") {
    do {
        try MainActor.assumeIsolated {
            try AgentCommandBarSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        }
        exit(0)
    } catch {
        fputs("Soundtime agent command bar smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--performance-dashboard-lifecycle-smoke") {
    do {
        try MainActor.assumeIsolated {
            try PerformanceDashboardWindowController.runLifecycleSmoke()
        }
        exit(0)
    } catch {
        fputs("Soundtime performance dashboard lifecycle smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--project-edit-roundtrip-smoke") ||
    CommandLine.arguments.contains("--project-edit-round-trip-smoke")
{
    do {
        try ProjectEditRoundTripSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime project edit round-trip smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--edit-graph-smoke") {
    do {
        try EditGraphSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime edit graph smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--edit-preview-smoke") {
    do {
        try EditPreviewSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime edit preview smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--realtime-graph-publish-smoke") {
    do {
        try MainActor.assumeIsolated {
            try RealtimeGraphPublishSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        }
        exit(0)
    } catch {
        fputs("Soundtime realtime graph publish smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
