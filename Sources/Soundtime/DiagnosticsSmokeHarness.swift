import Foundation

enum DiagnosticsSmokeHarness {
    enum SmokeError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let diagnostics = SoundtimeDiagnostics.shared
        diagnostics.resetForSmokeTesting()

        try verifyBasicEventAccounting(diagnostics)
        try verifyOperationCorrelation(diagnostics)
        try verifyFrameStatsEscalation(diagnostics)
        try verifyAudioSnapshotEscalation(diagnostics)
        try verifyMixerSnapshotEscalation(diagnostics)
        try verifyTraceWriting(diagnostics)
        try verifyEventRetentionLimit(diagnostics)
        try verifyMainThreadWatchdog(diagnostics)

        diagnostics.resetForSmokeTesting()
        let checks = [
            "basic event accounting",
            "stable operation correlation",
            "main queue watchdog timing",
            "main queue watchdog reset isolation",
            "frame stats warning/severe escalation",
            "audio snapshot escalation",
            "mixer packet and render-budget escalation",
            "diagnostics trace writing",
            "event retention limit",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "diagnostics-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: ["traceBackend": "json"],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }
        print("Soundtime diagnostics smoke passed")
    }

    private static func verifyMixerSnapshotEscalation(_ diagnostics: SoundtimeDiagnostics) throws {
        let baseline = diagnostics.snapshot(limit: 64)
        diagnostics.recordMixerSnapshot(MixerDiagnosticsSnapshot(
            packetAgeMilliseconds: 12,
            droppedPacketCount: 0,
            stalePacketCount: 0,
            realtimeWorkNanoseconds: 18_000,
            visibleChannelCount: 10,
            renderedMeterCount: 18,
            gpuDrawCount: 1,
            drawDurationMilliseconds: 0.35,
            maximumDrawDurationMilliseconds: 0.62
        ), isPlaying: true)
        var snapshot = diagnostics.snapshot(limit: 64)
        try require(
            snapshot.events.last?.name == "mixer-performance-snapshot" &&
                snapshot.events.last?.severity == .info,
            "healthy mixer diagnostics did not record an informational baseline"
        )
        try require(
            snapshot.warningEventCount == baseline.warningEventCount,
            "healthy mixer diagnostics unexpectedly raised a warning"
        )

        diagnostics.recordMixerSnapshot(MixerDiagnosticsSnapshot(
            packetAgeMilliseconds: 140,
            droppedPacketCount: 2,
            stalePacketCount: 1,
            realtimeWorkNanoseconds: 42_000,
            visibleChannelCount: 10,
            renderedMeterCount: 18,
            gpuDrawCount: 1,
            drawDurationMilliseconds: 2.4,
            maximumDrawDurationMilliseconds: 2.4
        ), isPlaying: true)
        snapshot = diagnostics.snapshot(limit: 64)
        guard let event = snapshot.events.last else {
            throw SmokeError.failed("mixer diagnostics did not emit a budget event")
        }
        try require(event.name == "mixer-performance-snapshot", "mixer diagnostics used an unexpected event name")
        try require(event.severity == .warning, "mixer diagnostics did not escalate a delivery/render failure")
        try require(event.fields["droppedPacketDelta"] == "2", "mixer diagnostics lost dropped-packet context")
        try require(event.fields["stalePacketDelta"] == "1", "mixer diagnostics lost stale-packet context")
        try require(
            snapshot.warningEventCount == baseline.warningEventCount + 1,
            "mixer budget violation did not increment warning accounting exactly once"
        )
    }

    private static func verifyBasicEventAccounting(_ diagnostics: SoundtimeDiagnostics) throws {
        diagnostics.record(
            category: .system,
            severity: .info,
            name: "smoke-info",
            message: "Diagnostics smoke info event."
        )
        diagnostics.record(
            category: .interaction,
            severity: .warning,
            name: "smoke-warning",
            message: "Diagnostics smoke warning event.",
            fields: ["source": "diagnostics-smoke"]
        )
        diagnostics.recordMainThreadStall(milliseconds: 66.5)

        let snapshot = diagnostics.snapshot(limit: 16)
        try require(snapshot.events.count == 3, "diagnostics basic smoke event count mismatch")
        try require(snapshot.warningEventCount == 2, "diagnostics warning accounting mismatch")
        try require(snapshot.severeEventCount == 0, "diagnostics severe count should still be zero")
        try require(snapshot.mainThreadStallCount == 1, "main thread stall count mismatch")
        try require(abs(snapshot.lastMainThreadStallMilliseconds - 66.5) < 0.001, "main thread stall latency mismatch")
    }

    private static func verifyOperationCorrelation(_ diagnostics: SoundtimeDiagnostics) throws {
        diagnostics.resetForSmokeTesting()
        diagnostics.record(
            category: .import,
            severity: .info,
            name: "import-started",
            message: "Import started.",
            fields: ["graphRevision": "41"]
        )
        diagnostics.record(
            category: .import,
            severity: .info,
            name: "import-progress",
            message: "Import progressed."
        )
        diagnostics.record(
            category: .import,
            severity: .info,
            name: "import-finished",
            message: "Import finished."
        )
        let events = diagnostics.snapshot(limit: 3).events
        let operationIDs = events.compactMap { $0.correlation?.operationID }
        try require(operationIDs.count == 3, "import operation events did not receive operation IDs")
        try require(Set(operationIDs).count == 1, "import operation events did not share one operation ID")
        try require(
            events.allSatisfy { $0.correlation?.graphRevision == 41 },
            "import operation did not retain its graph revision"
        )
        diagnostics.resetForSmokeTesting()
    }

    private static func verifyMainThreadWatchdog(_ diagnostics: SoundtimeDiagnostics) throws {
        diagnostics.resetForSmokeTesting()
        let monitor = SoundtimeMainThreadStallMonitor.shared
        monitor.start()
        monitor.resetForSmokeTesting()
        monitor.enqueueHeartbeatForSmokeTesting()

        Thread.sleep(forTimeInterval: 0.080)
        RunLoop.main.run(until: Date().addingTimeInterval(0.020))

        let snapshot = diagnostics.snapshot(limit: 16)
        try require(snapshot.mainThreadStallCount == 1, "main queue watchdog did not record a blocked heartbeat")
        try require(
            snapshot.lastMainThreadStallMilliseconds >= 70,
            "main queue watchdog underreported the blocked heartbeat"
        )

        diagnostics.resetForSmokeTesting()
        monitor.publishStaleSampleForSmokeTesting(milliseconds: 80)
        let staleSnapshot = diagnostics.snapshot(limit: 16)
        monitor.stop()
        try require(
            staleSnapshot.mainThreadStallCount == 0,
            "main queue watchdog published a stale sample after reset"
        )
        diagnostics.resetForSmokeTesting()
    }

    private static func verifyFrameStatsEscalation(_ diagnostics: SoundtimeDiagnostics) throws {
        diagnostics.recordFrameStats(TimelineFrameStats(
            framesPerSecond: 144,
            displayRefreshFramesPerSecond: 144,
            averageFrameTimeMilliseconds: 6.9,
            frameTimeJitterMilliseconds: 0.2,
            worstFrameTimeMilliseconds: 8.1,
            waveformRenderer: "smoke",
            cpuWaveformVertexCount: 0,
            gpuWaveformDrawCount: 8,
            shaderBufferUploadCount: 0,
            shaderBufferUploadByteCount: 0,
            shaderBufferCount: 4,
            shaderBufferByteCount: 1_024,
            shaderBufferUploadInFlightCount: 0,
            waveformMipCacheCount: 4,
            cpuWaveformFallbackDrawCount: 0,
            waveformFallbackDrawCount: 0,
            waveformLastGoodHoldCount: 0,
            waveformResidentMissCount: 0,
            waveformHotPathViolationCount: 0,
            waveformHotPathReason: "",
            gpuResidentWaveformMode: "legacy",
            gpuResidentShadowSourceCount: 0,
            gpuResidentShadowRequestCount: 0,
            gpuResidentShadowVisibleTileCount: 0,
            gpuResidentShadowDrawBatchCount: 0,
            gpuResidentShadowDrawInstanceCount: 0,
            effectVertexCount: 0,
            effectDroppedVertexCount: 0,
            transientParticleCount: 0,
            deletionEffectCount: 0,
            playheadContactEventCount: 0
        ))
        let beforeWarningCount = diagnostics.snapshot(limit: 32).warningEventCount
        let beforeSevereCount = diagnostics.snapshot(limit: 32).severeEventCount

        diagnostics.recordFrameStats(TimelineFrameStats(
            framesPerSecond: 78,
            displayRefreshFramesPerSecond: 144,
            averageFrameTimeMilliseconds: 11.5,
            frameTimeJitterMilliseconds: 2.4,
            worstFrameTimeMilliseconds: 18.2,
            waveformRenderer: "smoke",
            cpuWaveformVertexCount: 16,
            gpuWaveformDrawCount: 9,
            shaderBufferUploadCount: 1,
            shaderBufferUploadByteCount: 4_096,
            shaderBufferCount: 5,
            shaderBufferByteCount: 2_048,
            shaderBufferUploadInFlightCount: 0,
            waveformMipCacheCount: 5,
            cpuWaveformFallbackDrawCount: 1,
            waveformFallbackDrawCount: 1,
            waveformLastGoodHoldCount: 0,
            waveformResidentMissCount: 1,
            waveformHotPathViolationCount: 0,
            waveformHotPathReason: "",
            gpuResidentWaveformMode: "legacy",
            gpuResidentShadowSourceCount: 0,
            gpuResidentShadowRequestCount: 0,
            gpuResidentShadowVisibleTileCount: 0,
            gpuResidentShadowDrawBatchCount: 0,
            gpuResidentShadowDrawInstanceCount: 0,
            effectVertexCount: 24,
            effectDroppedVertexCount: 0,
            transientParticleCount: 3,
            deletionEffectCount: 0,
            playheadContactEventCount: 1
        ))
        diagnostics.recordFrameStats(TimelineFrameStats(
            framesPerSecond: 55,
            displayRefreshFramesPerSecond: 144,
            averageFrameTimeMilliseconds: 18.5,
            frameTimeJitterMilliseconds: 5.4,
            worstFrameTimeMilliseconds: 34.0,
            waveformRenderer: "smoke",
            cpuWaveformVertexCount: 44,
            gpuWaveformDrawCount: 10,
            shaderBufferUploadCount: 2,
            shaderBufferUploadByteCount: 8_192,
            shaderBufferCount: 6,
            shaderBufferByteCount: 4_096,
            shaderBufferUploadInFlightCount: 1,
            waveformMipCacheCount: 6,
            cpuWaveformFallbackDrawCount: 2,
            waveformFallbackDrawCount: 2,
            waveformLastGoodHoldCount: 1,
            waveformResidentMissCount: 2,
            waveformHotPathViolationCount: 1,
            waveformHotPathReason: "playback",
            gpuResidentWaveformMode: "gpu-resident-shadow",
            gpuResidentShadowSourceCount: 2,
            gpuResidentShadowRequestCount: 12,
            gpuResidentShadowVisibleTileCount: 4,
            gpuResidentShadowDrawBatchCount: 1,
            gpuResidentShadowDrawInstanceCount: 4,
            effectVertexCount: 48,
            effectDroppedVertexCount: 1,
            transientParticleCount: 12,
            deletionEffectCount: 1,
            playheadContactEventCount: 2
        ))

        let snapshot = diagnostics.snapshot(limit: 32)
        try require(snapshot.frameStats?.framesPerSecond == 55, "latest frame stats were not retained")
        try require(snapshot.warningEventCount >= beforeWarningCount + 1, "frame warning was not recorded")
        try require(snapshot.severeEventCount >= beforeSevereCount + 1, "frame severe event was not recorded")
        try require(
            snapshot.events.contains { $0.name == "timeline-frame-drop" && $0.fields["fps"] == "55" },
            "frame drop event did not retain FPS fields"
        )
    }

    private static func verifyAudioSnapshotEscalation(_ diagnostics: SoundtimeDiagnostics) throws {
        diagnostics.recordAudioCoreSnapshot(RealtimeAudioCoreSnapshot(
            frameIndex: 128,
            frameCount: 1_024,
            sampleRate: 48_000,
            hostTimestamp: 100,
            isPlaying: true,
            renderedFrameCount: 128,
            underrunCount: 0,
            droppedCommandCount: 0,
            callbackCount: 1,
            lastRenderNanoseconds: 150_000,
            maxRenderNanoseconds: 150_000,
            renderDeadlineMissCount: 0,
            lastRenderWorkNanoseconds: 120_000,
            maxRenderWorkNanoseconds: 120_000,
            renderWorkDeadlineMissCount: 0,
            callbackSchedulingLateCount: 0,
            maxCallbackSchedulingLatenessNanoseconds: 0
        ))
        diagnostics.recordAudioCoreSnapshot(RealtimeAudioCoreSnapshot(
            frameIndex: 256,
            frameCount: 1_024,
            sampleRate: 48_000,
            hostTimestamp: 101,
            isPlaying: true,
            renderedFrameCount: 256,
            underrunCount: 1,
            droppedCommandCount: 2,
            callbackCount: 2,
            lastRenderNanoseconds: 2_800_000,
            maxRenderNanoseconds: 2_800_000,
            renderDeadlineMissCount: 1,
            lastRenderWorkNanoseconds: 2_600_000,
            maxRenderWorkNanoseconds: 2_600_000,
            renderWorkDeadlineMissCount: 1,
            callbackSchedulingLateCount: 1,
            maxCallbackSchedulingLatenessNanoseconds: 3_000_000
        ))

        let snapshot = diagnostics.snapshot(limit: 64)
        try require(snapshot.audioSnapshot?.underrunCount == 1, "latest audio snapshot was not retained")
        try require(snapshot.events.contains { $0.name == "audio-underrun" }, "audio underrun event missing")
        try require(snapshot.events.contains { $0.name == "audio-dropped-command" }, "audio dropped-command event missing")
        try require(snapshot.events.contains { $0.name == "audio-callback-deadline-miss" }, "audio deadline event missing")
        try require(snapshot.events.contains { $0.name == "audio-render-work-deadline-miss" }, "audio work deadline event missing")
        try require(snapshot.events.contains { $0.name == "audio-callback-scheduling-late" }, "audio scheduling event missing")
        try require(
            snapshot.events.contains {
                $0.name == "audio-callback-deadline-miss" && $0.fields["workMissTotal"] == "1"
            },
            "audio deadline event did not distinguish render work"
        )
    }

    private static func verifyTraceWriting(_ diagnostics: SoundtimeDiagnostics) throws {
        guard let traceURL = diagnostics.writeTraceSynchronouslyForSmokeTesting(reason: "diagnostics smoke!*") else {
            throw SmokeError.failed("diagnostics trace write returned nil")
        }
        try require(
            traceURL.lastPathComponent.contains("diagnostics-smoke"),
            "diagnostics trace reason was not sanitized into filename"
        )

        let data = try Data(contentsOf: traceURL)
        let events = try JSONDecoder().decode([SoundtimeDiagnosticEvent].self, from: data)
        let expectedNames: Set<String> = [
            "timeline-frame-drop",
            "audio-underrun",
            "audio-dropped-command",
            "audio-callback-deadline-miss",
            "audio-render-work-deadline-miss",
            "audio-callback-scheduling-late",
        ]
        let names = Set(events.map(\.name))
        try require(
            expectedNames.isSubset(of: names),
            "diagnostics trace omitted required events: \(expectedNames.subtracting(names).sorted())"
        )
    }

    private static func verifyEventRetentionLimit(_ diagnostics: SoundtimeDiagnostics) throws {
        diagnostics.resetForSmokeTesting()
        for index in 0..<2_100 {
            diagnostics.record(
                category: .system,
                severity: .info,
                name: "retention-\(index)",
                message: "Retention smoke event \(index)"
            )
        }

        let snapshot = diagnostics.snapshot(limit: 3_000)
        try require(snapshot.events.count == 2_048, "diagnostics event retention limit changed unexpectedly")
        try require(snapshot.events.first?.name != "retention-0", "diagnostics did not evict oldest retained event")
        try require(snapshot.events.last?.name == "retention-2099", "diagnostics did not retain newest event")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SmokeError.failed(message)
        }
    }
}
