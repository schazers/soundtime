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
        let diagnostics = SoundtimeDiagnostics.shared
        diagnostics.resetForSmokeTesting()

        try verifyBasicEventAccounting(diagnostics)
        try verifyFrameStatsEscalation(diagnostics)
        try verifyAudioSnapshotEscalation(diagnostics)
        try verifyTraceWriting(diagnostics)
        try verifyEventRetentionLimit(diagnostics)

        diagnostics.resetForSmokeTesting()
        print("Soundtime diagnostics smoke passed")
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

    private static func verifyFrameStatsEscalation(_ diagnostics: SoundtimeDiagnostics) throws {
        diagnostics.recordFrameStats(TimelineFrameStats(
            framesPerSecond: 144,
            averageFrameTimeMilliseconds: 6.9,
            frameTimeJitterMilliseconds: 0.2,
            worstFrameTimeMilliseconds: 8.1,
            waveformRenderer: "smoke",
            cpuWaveformVertexCount: 0,
            gpuWaveformDrawCount: 8,
            shaderBufferUploadCount: 0,
            shaderBufferCount: 4,
            shaderBufferByteCount: 1_024,
            shaderBufferUploadInFlightCount: 0,
            waveformMipCacheCount: 4,
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
            averageFrameTimeMilliseconds: 11.5,
            frameTimeJitterMilliseconds: 2.4,
            worstFrameTimeMilliseconds: 18.2,
            waveformRenderer: "smoke",
            cpuWaveformVertexCount: 16,
            gpuWaveformDrawCount: 9,
            shaderBufferUploadCount: 1,
            shaderBufferCount: 5,
            shaderBufferByteCount: 2_048,
            shaderBufferUploadInFlightCount: 0,
            waveformMipCacheCount: 5,
            effectVertexCount: 24,
            effectDroppedVertexCount: 0,
            transientParticleCount: 3,
            deletionEffectCount: 0,
            playheadContactEventCount: 1
        ))
        diagnostics.recordFrameStats(TimelineFrameStats(
            framesPerSecond: 55,
            averageFrameTimeMilliseconds: 18.5,
            frameTimeJitterMilliseconds: 5.4,
            worstFrameTimeMilliseconds: 34.0,
            waveformRenderer: "smoke",
            cpuWaveformVertexCount: 44,
            gpuWaveformDrawCount: 10,
            shaderBufferUploadCount: 2,
            shaderBufferCount: 6,
            shaderBufferByteCount: 4_096,
            shaderBufferUploadInFlightCount: 1,
            waveformMipCacheCount: 6,
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
            renderDeadlineMissCount: 0
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
            renderDeadlineMissCount: 1
        ))

        let snapshot = diagnostics.snapshot(limit: 64)
        try require(snapshot.audioSnapshot?.underrunCount == 1, "latest audio snapshot was not retained")
        try require(snapshot.events.contains { $0.name == "audio-underrun" }, "audio underrun event missing")
        try require(snapshot.events.contains { $0.name == "audio-dropped-command" }, "audio dropped-command event missing")
        try require(snapshot.events.contains { $0.name == "audio-callback-deadline-miss" }, "audio deadline event missing")
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
        try require(events.count >= 8, "diagnostics trace did not include recent events")
        try require(events.contains { $0.name == "audio-underrun" }, "diagnostics trace did not include audio event")
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
