import AppKit
import Darwin

SoundtimeProjectStore.configurePersistenceForCommandLine(arguments: CommandLine.arguments)

private let shippabilityGateCommandFlags: Set<String> = [
    "--shippability-gate",
    "--product-bar",
    "--feature-gate",
    "--release-candidate-gate",
    "--rc-gate",
]

if CommandLine.arguments.contains("--application-update-smoke") {
    do {
        try MainActor.assumeIsolated {
            try ApplicationUpdateSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        }
        exit(0)
    } catch {
        fputs("Soundtime application update smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--timeline-perf-baseline") {
    do {
        try TimelinePerfBaselineHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime timeline perf baseline failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--production-readiness-smoke") ||
    CommandLine.arguments.contains("--production-readiness-smoke-quick") ||
    CommandLine.arguments.contains("--production-readiness-plan")
{
    do {
        try ProductionReadinessHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime production readiness smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--build-shippability-fixtures") {
    do {
        try ShippabilityFixtureBuilder.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime shippability fixture builder failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--verify-shippability-fixtures") {
    do {
        try ShippabilityFixtureBuilder.verifyFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime shippability fixture verification failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains(where: { shippabilityGateCommandFlags.contains($0) }) {
    do {
        try ShippabilityGateHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime shippability gate failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--shippability-gate-self-test") {
    do {
        try ShippabilityGateHarness.runSelfTestFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime shippability gate self-test failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--user-perceived-timing-smoke") {
    do {
        try MainActor.assumeIsolated {
            try UserPerceivedTimingSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        }
        exit(0)
    } catch {
        fputs("Soundtime user-perceived timing smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--visual-invariants-smoke") {
    do {
        try MainActor.assumeIsolated {
            try VisualInvariantsSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        }
        exit(0)
    } catch {
        fputs("Soundtime visual invariants smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--hot-path-contract-smoke") {
    do {
        try MainActor.assumeIsolated {
            try HotPathContractSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        }
        exit(0)
    } catch {
        fputs("Soundtime hot-path contract smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--interaction-replay-smoke") {
    do {
        try MainActor.assumeIsolated {
            try InteractionReplaySmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        }
        exit(0)
    } catch {
        fputs("Soundtime interaction replay smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--audio-safety-smoke") {
    do {
        try MainActor.assumeIsolated {
            try AudioSafetySmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        }
        exit(0)
    } catch {
        fputs("Soundtime audio safety smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--audio-export-smoke") {
    do {
        try AudioExportSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime audio export smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--audio-export-ui-smoke") {
    do {
        try MainActor.assumeIsolated {
            try AudioExportUIContractSmokeHarness.runFromCommandLine(
                arguments: CommandLine.arguments
            )
        }
        exit(0)
    } catch {
        fputs("Soundtime audio export UI contract smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--launch-performance-smoke") ||
    CommandLine.arguments.contains("--launch-performance-smoke-full")
{
    do {
        try LaunchPerformanceSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime launch performance smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--startup-close-lifecycle-smoke") {
    do {
        try MainActor.assumeIsolated {
            try StartupCloseLifecycleSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        }
        exit(0)
    } catch {
        fputs("Soundtime startup/close lifecycle smoke failed: \(error)\n", stderr)
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

if CommandLine.arguments.contains("--audio-asset-importer-smoke") {
    do {
        try AudioAssetImporterSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime audio asset importer smoke failed: \(error)\n", stderr)
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

if CommandLine.arguments.contains("--audio-processing-smoke") {
    do {
        try AudioProcessingSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime audio processing smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--transcription-smoke") {
    do {
        try TranscriptionSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime transcription smoke failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--deepgram-transcription-smoke") {
    do {
        try TranscriptionSmokeHarness.runDeepgramLiveSmokeFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime Deepgram transcription smoke failed: \(error)\n", stderr)
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

if CommandLine.arguments.contains("--edit-transaction-smoke") ||
    CommandLine.arguments.contains("--edit-transaction-smoke-quick")
{
    do {
        try EditTransactionSmokeHarness.runFromCommandLine(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        fputs("Soundtime edit transaction smoke failed: \(error)\n", stderr)
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

LaunchStartupTrace.shared.mark(.processEntry)

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
