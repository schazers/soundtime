import AVFoundation
import Foundation
import Darwin
import SoundtimeAudioCore

private final class AudioSafetySmokeResultBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}

@MainActor
enum AudioSafetySmokeHarness {
    private enum SmokeError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(message):
                message
            }
        }
    }

    private enum SmokeMode {
        case quick
        case standard
        case stress

        init(arguments: [String]) {
            if arguments.contains("--full") || arguments.contains("--stress") {
                self = .stress
            } else if arguments.contains("--quick") {
                self = .quick
            } else {
                self = .standard
            }
        }

        var graphSwapTrackCount: Int {
            switch self {
            case .quick: 24
            case .standard: 48
            case .stress: 96
            }
        }

        var graphSwapUpdateCount: Int {
            switch self {
            case .quick: 36
            case .standard: 80
            case .stress: 150
            }
        }

        var renderBlockCount: Int {
            switch self {
            case .quick: 900
            case .standard: 2_400
            case .stress: 5_500
            }
        }
    }

    private enum ImportExpectation: String, Decodable {
        case importable
        case recognizedUnsupported
    }

    private struct FixtureManifest: Decodable {
        struct Audio: Decodable {
            let id: String
            let role: String
            let path: String
            let format: String?
            let durationSeconds: Double?
            let importExpectation: ImportExpectation?
        }

        let audio: [Audio]
    }

    private struct SafetyMetrics {
        var underrunCount = 0
        var droppedCommandCount = 0
        var renderDeadlineMissCount = 0
        var maxRenderNanoseconds = 0
        var renderWorkDeadlineMissCount = 0
        var maxRenderWorkNanoseconds = 0
        var callbackSchedulingLateCount = 0
        var maxCallbackSchedulingLatenessNanoseconds = 0
        var maxSeekFrameError = 0
        var maxLoopSampleError: Float = 0
        var maxGraphSwapMilliseconds = 0.0
        var graphSwapP95Milliseconds = 0.0
        var outputDeviceConfigureCount = 0
        var outputDeviceInvalidateCount = 0
        var outputDeviceStartCount = 0
        var seekCheckCount = 0
        var loopCapturedFrameCount = 0
        var graphSwapTrackCount = 0
        var graphSwapUpdateCount = 0
        var graphSwapRenderBlockCount = 0
        var importedFormatCount = 0
        var importedFileCount = 0
        var importedFormats: [String] = []
        var minimumOriginalPlaybackPeak: Float = .greatestFiniteMagnitude
        var minimumImportPlaybackPeak: Float = .greatestFiniteMagnitude
        var minimumCorePlaybackPeak: Float = .greatestFiniteMagnitude

        mutating func absorb(_ snapshot: RealtimeAudioCoreSnapshot) {
            underrunCount = max(underrunCount, snapshot.underrunCount)
            droppedCommandCount = max(droppedCommandCount, snapshot.droppedCommandCount)
            renderDeadlineMissCount = max(renderDeadlineMissCount, snapshot.renderDeadlineMissCount)
            maxRenderNanoseconds = max(maxRenderNanoseconds, snapshot.maxRenderNanoseconds)
            renderWorkDeadlineMissCount = max(
                renderWorkDeadlineMissCount,
                snapshot.renderWorkDeadlineMissCount
            )
            maxRenderWorkNanoseconds = max(
                maxRenderWorkNanoseconds,
                snapshot.maxRenderWorkNanoseconds
            )
            callbackSchedulingLateCount = max(
                callbackSchedulingLateCount,
                snapshot.callbackSchedulingLateCount
            )
            maxCallbackSchedulingLatenessNanoseconds = max(
                maxCallbackSchedulingLatenessNanoseconds,
                snapshot.maxCallbackSchedulingLatenessNanoseconds
            )
        }

        mutating func absorb(_ snapshot: SoundtimeAudioCoreSnapshot) {
            underrunCount = max(underrunCount, Int(min(snapshot.underrunCount, UInt64(Int.max))))
            droppedCommandCount = max(droppedCommandCount, Int(min(snapshot.droppedCommandCount, UInt64(Int.max))))
            renderDeadlineMissCount = max(renderDeadlineMissCount, Int(min(snapshot.renderDeadlineMissCount, UInt64(Int.max))))
            maxRenderNanoseconds = max(maxRenderNanoseconds, Int(min(snapshot.maxRenderNanoseconds, UInt64(Int.max))))
            renderWorkDeadlineMissCount = max(
                renderWorkDeadlineMissCount,
                Int(min(snapshot.renderWorkDeadlineMissCount, UInt64(Int.max)))
            )
            maxRenderWorkNanoseconds = max(
                maxRenderWorkNanoseconds,
                Int(min(snapshot.maxRenderWorkNanoseconds, UInt64(Int.max)))
            )
            callbackSchedulingLateCount = max(
                callbackSchedulingLateCount,
                Int(min(snapshot.callbackSchedulingLateCount, UInt64(Int.max)))
            )
            maxCallbackSchedulingLatenessNanoseconds = max(
                maxCallbackSchedulingLatenessNanoseconds,
                Int(min(snapshot.maxCallbackSchedulingLatenessNanoseconds, UInt64(Int.max)))
            )
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let mode = SmokeMode(arguments: arguments)
        let coreOnly = arguments.contains("--audio-safety-core-only")
        setenv("SOUNDTIME_AUDIO_DETAILED_TIMING", "1", 1)
        try runAttempt(
            arguments: arguments,
            mode: mode,
            coreOnly: coreOnly,
            startedAtNanoseconds: startedAtNanoseconds
        )
    }

    private static func runAttempt(
        arguments: [String],
        mode: SmokeMode,
        coreOnly: Bool,
        startedAtNanoseconds: UInt64
    ) throws {
        var metrics = SafetyMetrics()

        try verifyOutputDeviceConfiguration(metrics: &metrics)
        try verifySeekFramePosition(metrics: &metrics)
        try verifyTransportClockDoesNotRunAhead(metrics: &metrics)
        try verifyMixedRateTrackEndpointAlignment(metrics: &metrics)
        try verifyLogicalTrackMixTargetsEverySourceLane(metrics: &metrics)
        try verifyLoopWrapSampleConsistency(metrics: &metrics)
        try verifyEditGraphSwapSafety(mode: mode, metrics: &metrics)
        if coreOnly {
            try verifyCoreProjectTrackPlayback(metrics: &metrics)
        } else if let rootDirectory = try? fixtureRoot(arguments: arguments) {
            try verifyPlaybackAfterImport(rootDirectory: rootDirectory, mode: mode, metrics: &metrics)
        } else {
            throw SmokeError.failed("missing fixture root; pass --fixtures-output or SOUNDTIME_SHIPPABILITY_FIXTURE_ROOT")
        }

        try require(metrics.underrunCount == 0, "audio core reported \(metrics.underrunCount) underrun(s)")
        try require(metrics.droppedCommandCount == 0, "audio core dropped \(metrics.droppedCommandCount) command(s)")
        try require(
            metrics.renderWorkDeadlineMissCount == 0,
            "audio core CPU work missed \(metrics.renderWorkDeadlineMissCount) render deadline(s)"
        )

        var checks = [
            "no underruns or dropped realtime commands",
            "output device configure/refresh matches engine core and sample rate",
            "live output route refresh resumes active playback",
            "seek lands on expected frame position",
            "visual transport clock cannot outrun rendered audio callbacks",
            "mixed-rate track audio ends at its canonical visual endpoint",
            "logical track mute reaches every canonical source lane",
            "loop wrap returns sample-consistently to loop start",
            "edit graph swaps do not block realtime render",
        ]
        if coreOnly {
            checks.append("core project track playback renders audible audio")
        } else {
            checks.append("original and proxy playback work for WAV/MP3/M4A/AIFF/AAC/FLAC/CAF")
        }

        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "audio-safety-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: [
                "mode": modeName(mode),
                "scope": coreOnly ? "core-only" : "full-import-matrix",
                "attempt": "1",
                "underrunCount": "\(metrics.underrunCount)",
                "droppedCommandCount": "\(metrics.droppedCommandCount)",
                "renderDeadlineMissCount": "\(metrics.renderDeadlineMissCount)",
                "renderDeadlineMissClassification": "diagnostic-synthetic-driver",
                "maxRenderNanoseconds": "\(metrics.maxRenderNanoseconds)",
                "renderWorkDeadlineMissCount": "\(metrics.renderWorkDeadlineMissCount)",
                "maxRenderWorkNanoseconds": "\(metrics.maxRenderWorkNanoseconds)",
                "callbackSchedulingLateCount": "\(metrics.callbackSchedulingLateCount)",
                "maxCallbackSchedulingLatenessNanoseconds": "\(metrics.maxCallbackSchedulingLatenessNanoseconds)",
                "maxSeekFrameError": "\(metrics.maxSeekFrameError)",
                "maxLoopSampleError": String(format: "%.8f", metrics.maxLoopSampleError),
                "maxGraphSwapMilliseconds": String(format: "%.3f", metrics.maxGraphSwapMilliseconds),
                "graphSwapP95Milliseconds": String(format: "%.3f", metrics.graphSwapP95Milliseconds),
                "outputDeviceConfigureCount": "\(metrics.outputDeviceConfigureCount)",
                "outputDeviceInvalidateCount": "\(metrics.outputDeviceInvalidateCount)",
                "outputDeviceStartCount": "\(metrics.outputDeviceStartCount)",
                "seekCheckCount": "\(metrics.seekCheckCount)",
                "loopCapturedFrameCount": "\(metrics.loopCapturedFrameCount)",
                "graphSwapTrackCount": "\(metrics.graphSwapTrackCount)",
                "graphSwapUpdateCount": "\(metrics.graphSwapUpdateCount)",
                "graphSwapRenderBlockCount": "\(metrics.graphSwapRenderBlockCount)",
                "importedFormatCount": "\(metrics.importedFormatCount)",
                "importedFileCount": "\(metrics.importedFileCount)",
                "importedFormats": metrics.importedFormats.joined(separator: ","),
                "minimumOriginalPlaybackPeak": String(
                    format: "%.6f",
                    metrics.minimumOriginalPlaybackPeak
                ),
                "minimumImportPlaybackPeak": String(format: "%.6f", metrics.minimumImportPlaybackPeak),
                "minimumCorePlaybackPeak": String(format: "%.6f", metrics.minimumCorePlaybackPeak),
            ],
            arguments: arguments
        ) {
            print("Soundtime audio safety smoke report: \(reportURL.path)")
        }
        print("Soundtime audio safety smoke passed")
    }

    private static func verifyOutputDeviceConfiguration(metrics: inout SafetyMetrics) throws {
        let outputDevice = AudioSafetySmokeOutputDevice()
        guard let playbackEngine = RealtimeCorePlaybackEngine(outputDevice: outputDevice) else {
            throw SmokeError.failed("could not create realtime playback engine for output-device safety")
        }

        let sampleRate = 48_000.0
        let buffer = syntheticAudioBuffer(frameCount: Int(sampleRate * 2), sampleRate: sampleRate)
        try playbackEngine.load(buffer, zeroCrossingIndex: nil)
        try require(outputDevice.configureCount == 1, "output device was not configured exactly once on load")
        try require(outputDevice.lastSampleRate == sampleRate, "output device configured at wrong sample rate")
        let firstCorePointer = try requireValue(outputDevice.corePointer, "output device did not receive a core pointer")

        try playbackEngine.play()
        try require(outputDevice.startCount == 1, "output device did not start when playback started")
        render(corePointer: firstCorePointer, blockCount: 8, frameCount: 256, sampleRate: sampleRate)
        try playbackEngine.refreshOutputDevice()
        try require(outputDevice.invalidateCount == 1, "output device refresh did not invalidate old configuration")
        try require(outputDevice.configureCount == 2, "output device refresh did not reconfigure")
        try require(outputDevice.corePointer == firstCorePointer, "output device refresh changed core pointer unexpectedly")
        try require(outputDevice.lastSampleRate == sampleRate, "output device refresh changed sample rate unexpectedly")
        try require(outputDevice.stopCount == 1, "live output device refresh did not stop the old route")
        try require(outputDevice.startCount == 2, "live output device refresh did not start the new route")
        try require(playbackEngine.isPlaying, "live output device refresh interrupted transport playback")
        playbackEngine.pause()
        metrics.outputDeviceConfigureCount = max(metrics.outputDeviceConfigureCount, outputDevice.configureCount)
        metrics.outputDeviceInvalidateCount = max(metrics.outputDeviceInvalidateCount, outputDevice.invalidateCount)
        metrics.outputDeviceStartCount = max(metrics.outputDeviceStartCount, outputDevice.startCount)
        metrics.absorb(playbackEngine.realtimeSnapshotForSafetySmoke())
    }

    private static func verifySeekFramePosition(metrics: inout SafetyMetrics) throws {
        let outputDevice = AudioSafetySmokeOutputDevice()
        guard let playbackEngine = RealtimeCorePlaybackEngine(outputDevice: outputDevice) else {
            throw SmokeError.failed("could not create realtime playback engine for seek safety")
        }

        let sampleRate = 48_000.0
        let frameCount = Int(sampleRate * 5)
        let buffer = syntheticAudioBuffer(frameCount: frameCount, sampleRate: sampleRate)
        try playbackEngine.load(buffer, zeroCrossingIndex: nil)
        let corePointer = try requireValue(outputDevice.corePointer, "seek safety output device did not receive core pointer")

        for progress in [0.0, 0.125, 0.333, 0.5, 0.875, 0.999] {
            try playbackEngine.seekExactly(toProgress: Float(progress))
            let pending = playbackEngine.snapshot()
            let expectedFrame = min(max(Int((Double(frameCount) * progress).rounded(.down)), 0), frameCount)
            metrics.maxSeekFrameError = max(metrics.maxSeekFrameError, abs(pending.frameIndex - expectedFrame))
            try require(
                abs(pending.frameIndex - expectedFrame) <= 1,
                "pending seek landed on frame \(pending.frameIndex), expected \(expectedFrame)"
            )
            render(corePointer: corePointer, blockCount: 1, frameCount: 256, sampleRate: sampleRate)
            let committed = playbackEngine.snapshot()
            metrics.maxSeekFrameError = max(metrics.maxSeekFrameError, abs(committed.frameIndex - expectedFrame))
            metrics.seekCheckCount += 2
            try require(
                abs(committed.frameIndex - expectedFrame) <= 1,
                "committed paused seek landed on frame \(committed.frameIndex), expected \(expectedFrame)"
            )
        }

        try playbackEngine.seekExactly(toProgress: 0.42)
        try playbackEngine.play()
        let playingSnapshot = playbackEngine.snapshot()
        let expectedFrame = Int((Double(frameCount) * 0.42).rounded(.down))
        metrics.maxSeekFrameError = max(metrics.maxSeekFrameError, abs(playingSnapshot.frameIndex - expectedFrame))
        metrics.seekCheckCount += 1
        try require(abs(playingSnapshot.frameIndex - expectedFrame) <= 1, "playing seek did not mirror exact frame immediately")
        render(corePointer: corePointer, blockCount: 4, frameCount: 256, sampleRate: sampleRate)
        playbackEngine.pause()
        metrics.absorb(playbackEngine.realtimeSnapshotForSafetySmoke())
    }

    private static func verifyTransportClockDoesNotRunAhead(
        metrics: inout SafetyMetrics
    ) throws {
        let outputDevice = AudioSafetySmokeOutputDevice()
        guard let playbackEngine = RealtimeCorePlaybackEngine(outputDevice: outputDevice) else {
            throw SmokeError.failed("could not create realtime playback engine for transport clock safety")
        }

        let sampleRate = 48_000.0
        let callbackFrameCount = 256
        let buffer = syntheticAudioBuffer(frameCount: Int(sampleRate * 2), sampleRate: sampleRate)
        try playbackEngine.load(buffer, zeroCrossingIndex: nil)
        try playbackEngine.play()
        let corePointer = try requireValue(
            outputDevice.corePointer,
            "transport clock output device did not receive core pointer"
        )
        renderAtHostTime(
            corePointer: corePointer,
            frameCount: callbackFrameCount,
            hostTimestamp: CACurrentMediaTime()
        )
        let callbackCommittedSnapshot = playbackEngine.snapshot()

        Thread.sleep(forTimeInterval: 0.08)
        let stalledCallbackSnapshot = playbackEngine.snapshot()
        let visualLeadFrames = max(
            stalledCallbackSnapshot.frameIndex - callbackCommittedSnapshot.frameIndex,
            0
        )
        try require(
            visualLeadFrames <= callbackFrameCount * 2,
            "visual transport ran \(visualLeadFrames) frames ahead while audio callbacks were stalled"
        )
        playbackEngine.pause()
        metrics.absorb(playbackEngine.realtimeSnapshotForSafetySmoke())
    }

    private static func verifyMixedRateTrackEndpointAlignment(
        metrics: inout SafetyMetrics
    ) throws {
        let outputDevice = AudioSafetySmokeOutputDevice()
        guard let playbackEngine = RealtimeCorePlaybackEngine(outputDevice: outputDevice) else {
            throw SmokeError.failed("could not create realtime playback engine for endpoint alignment")
        }

        let projectSampleRate = 48_000.0
        let shorterDuration = 1.5
        let longerDuration = 1.8
        let shorterBuffer = syntheticAudioBuffer(
            frameCount: Int(projectSampleRate * shorterDuration),
            sampleRate: projectSampleRate
        )
        let longerSampleRate = 44_100.0
        let longerBuffer = syntheticAudioBuffer(
            frameCount: Int(longerSampleRate * longerDuration),
            sampleRate: longerSampleRate
        )
        let shorterTimeline = AudioEditTimeline(sourceBuffer: shorterBuffer)
        let longerTimeline = AudioEditTimeline(sourceBuffer: longerBuffer)
        let shorterTrack = ProjectPlaybackTrack(
            id: stableUUID("00000000-0000-4000-a200-%012d", 1),
            source: .timeline(
                audioTimeline: shorterTimeline,
                zeroCrossingIndex: nil
            ),
            sourceRevision: 0,
            volume: 1,
            isMuted: false,
            isSoloed: false
        )
        let longerTrack = ProjectPlaybackTrack(
            id: stableUUID("00000000-0000-4000-a200-%012d", 2),
            source: .timeline(
                audioTimeline: longerTimeline,
                zeroCrossingIndex: nil
            ),
            sourceRevision: 0,
            volume: 1,
            isMuted: true,
            isSoloed: false
        )
        try playbackEngine.loadProjectTracks([shorterTrack])
        try playbackEngine.seekExactly(toProgress: 0.8)
        let beforeImportSnapshot = playbackEngine.snapshot()
        let beforeImportTime = try requireValue(
            beforeImportSnapshot.projectTime,
            "mixed-rate project did not expose its pre-import project time"
        )

        try playbackEngine.updateProjectTracks([shorterTrack, longerTrack])
        let loadedSnapshot = playbackEngine.snapshot()
        try require(
            abs((loadedSnapshot.duration ?? 0) - longerDuration) <= 1 / projectSampleRate,
            "mixed-rate project duration did not preserve the longer track's seconds"
        )
        try require(
            abs((loadedSnapshot.projectTime ?? 0) - beforeImportTime) <= 1 / projectSampleRate,
            "adding a longer mixed-rate track changed the absolute playhead time"
        )
        try require(
            abs(
                Double(loadedSnapshot.progress) * longerDuration -
                    beforeImportTime
            ) <= 1 / projectSampleRate,
            "mixed-rate project normalized progress no longer maps to the visual project time"
        )
        let corePointer = try requireValue(
            outputDevice.corePointer,
            "endpoint alignment output device did not receive core pointer"
        )
        try playbackEngine.seekExactly(
            toProgress: Float((shorterDuration + 0.05) / longerDuration)
        )
        try playbackEngine.play()
        let captured = renderCapturedAtHostTime(
            corePointer: corePointer,
            blockCount: 8,
            frameCount: 256,
            sampleRate: projectSampleRate,
            firstHostTimestamp: CACurrentMediaTime()
        )
        let peak = max(
            captured.left.map { Swift.abs($0) }.max() ?? 0,
            captured.right.map { Swift.abs($0) }.max() ?? 0
        )
        try require(
            peak <= 0.000_001,
            "shorter audible track emitted audio after its visual endpoint (peak \(peak))"
        )
        playbackEngine.pause()

        playbackEngine.updateProjectTrackMix([
            ProjectPlaybackTrackMix(
                id: shorterTrack.id,
                volume: 1,
                isMuted: true,
                isSoloed: false
            ),
            ProjectPlaybackTrackMix(
                id: longerTrack.id,
                volume: 1,
                isMuted: false,
                isSoloed: true
            ),
        ])
        try playbackEngine.seekExactly(toProgress: Float(1.7 / longerDuration))
        try playbackEngine.play()
        let longerTrackCapture = renderCapturedAtHostTime(
            corePointer: corePointer,
            blockCount: 8,
            frameCount: 256,
            sampleRate: projectSampleRate,
            firstHostTimestamp: CACurrentMediaTime()
        )
        let longerTrackPeak = max(
            longerTrackCapture.left.map { Swift.abs($0) }.max() ?? 0,
            longerTrackCapture.right.map { Swift.abs($0) }.max() ?? 0
        )
        try require(
            longerTrackPeak > 0.001,
            "longer mixed-rate track ended before its visual endpoint (peak \(longerTrackPeak))"
        )
        playbackEngine.pause()
        metrics.absorb(playbackEngine.realtimeSnapshotForSafetySmoke())
    }

    private static func verifyLogicalTrackMixTargetsEverySourceLane(
        metrics: inout SafetyMetrics
    ) throws {
        let outputDevice = AudioSafetySmokeOutputDevice()
        guard let playbackEngine = RealtimeCorePlaybackEngine(outputDevice: outputDevice) else {
            throw SmokeError.failed("could not create realtime playback engine for logical track mix safety")
        }

        let sampleRate = 48_000.0
        let logicalTrackID = stableUUID("00000000-0000-4000-a210-%012d", 1)
        let sourceLanes = [1, 2].map { laneIndex in
            ProjectPlaybackTrack(
                id: stableUUID("00000000-0000-4000-a211-%012d", laneIndex),
                logicalTrackID: logicalTrackID,
                source: .timeline(
                    audioTimeline: AudioEditTimeline(sourceBuffer: syntheticAudioBuffer(
                        frameCount: Int(sampleRate * 2),
                        sampleRate: sampleRate
                    )),
                    zeroCrossingIndex: nil
                ),
                sourceRevision: laneIndex,
                volume: 1,
                isMuted: false,
                isSoloed: false
            )
        }

        try playbackEngine.loadProjectTracks(sourceLanes)
        let corePointer = try requireValue(
            outputDevice.corePointer,
            "logical track mix output device did not receive core pointer"
        )
        try playbackEngine.play()
        let audible = renderCaptured(
            corePointer: corePointer,
            blockCount: 8,
            frameCount: 256,
            sampleRate: sampleRate
        )
        let audiblePeak = max(
            audible.left.map { Swift.abs($0) }.max() ?? 0,
            audible.right.map { Swift.abs($0) }.max() ?? 0
        )
        try require(audiblePeak > 0.001, "logical track source lanes were silent before mute")

        playbackEngine.updateProjectTrackMix([
            ProjectPlaybackTrackMix(
                id: logicalTrackID,
                volume: 1,
                isMuted: true,
                isSoloed: false
            ),
        ])
        // Track gain changes intentionally ramp for 3 ms to avoid clicks.
        render(corePointer: corePointer, blockCount: 2, frameCount: 256, sampleRate: sampleRate)
        let muted = renderCaptured(
            corePointer: corePointer,
            blockCount: 8,
            frameCount: 256,
            sampleRate: sampleRate
        )
        let mutedPeak = max(
            muted.left.map { Swift.abs($0) }.max() ?? 0,
            muted.right.map { Swift.abs($0) }.max() ?? 0
        )
        try require(
            mutedPeak <= 0.000_001,
            "logical track mute left a canonical source lane audible (peak \(mutedPeak))"
        )
        playbackEngine.pause()
        metrics.absorb(playbackEngine.realtimeSnapshotForSafetySmoke())
    }

    private static func verifyLoopWrapSampleConsistency(metrics: inout SafetyMetrics) throws {
        guard let core = RealtimeAudioCore() else {
            throw SmokeError.failed("could not create realtime core for loop safety")
        }

        let sampleRate = 48_000.0
        let frameCount = Int(sampleRate * 4)
        let buffer = syntheticAudioBuffer(frameCount: frameCount, sampleRate: sampleRate)
        guard let source = PreparedRealtimeAudioSource.make(from: buffer) else {
            throw SmokeError.failed("could not prepare realtime source for loop safety")
        }
        try require(core.setPreparedSource(source), "loop safety could not load prepared source")
        core.setTransportRampDuration(0)
        let corePointer = try requireValue(core.enginePointer, "loop safety core pointer unavailable")
        let loopStartFrame = Int(sampleRate * 1.125)
        let loopEndFrame = Int(sampleRate * 2.25)

        core.seek(toFrame: loopStartFrame)
        core.play()
        let expected = renderCaptured(corePointer: corePointer, blockCount: 3, frameCount: 256, sampleRate: sampleRate)

        core.seek(toFrame: loopEndFrame - 128)
        core.play()
        _ = renderCaptured(corePointer: corePointer, blockCount: 1, frameCount: 256, sampleRate: sampleRate)
        core.seek(toFrame: loopStartFrame)
        let actual = renderCaptured(corePointer: corePointer, blockCount: 3, frameCount: 256, sampleRate: sampleRate)
        core.pause()
        metrics.loopCapturedFrameCount = max(metrics.loopCapturedFrameCount, min(expected.left.count, actual.left.count))

        var maxError: Float = 0
        for index in expected.left.indices {
            maxError = max(
                maxError,
                abs(expected.left[index] - actual.left[index]),
                abs(expected.right[index] - actual.right[index])
            )
        }
        metrics.maxLoopSampleError = max(metrics.maxLoopSampleError, maxError)
        try require(
            maxError <= 0.000_05,
            String(format: "loop wrap sample mismatch %.8f", maxError)
        )
        metrics.absorb(core.detailedSnapshot())
    }

    private static func verifyEditGraphSwapSafety(mode: SmokeMode, metrics: inout SafetyMetrics) throws {
        let outputDevice = AudioSafetySmokeOutputDevice()
        guard let playbackEngine = RealtimeCorePlaybackEngine(outputDevice: outputDevice) else {
            throw SmokeError.failed("could not create realtime playback engine for edit graph safety")
        }

        let sampleRate = 48_000.0
        let sourceFrameCount = Int(sampleRate * 20)
        let sourceBuffer = syntheticAudioBuffer(frameCount: sourceFrameCount, sampleRate: sampleRate)
        var timelines = Array(repeating: AudioEditTimeline(sourceBuffer: sourceBuffer), count: mode.graphSwapTrackCount)
        var sourceRevisions = Array(repeating: 0, count: mode.graphSwapTrackCount)
        let trackIDs = (0..<mode.graphSwapTrackCount).map { index in
            stableUUID("00000000-0000-4000-c000-%012d", index)
        }

        try playbackEngine.loadProjectTracks(projectTracks(ids: trackIDs, timelines: timelines, sourceRevisions: sourceRevisions, iteration: 0))
        try playbackEngine.play()
        let corePointer = try requireValue(outputDevice.corePointer, "edit graph safety output device did not receive core pointer")
        let uncheckedCorePointer = UncheckedCorePointer(pointer: corePointer)
        let renderGroup = DispatchGroup()
        renderGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            render(
                corePointer: uncheckedCorePointer.pointer,
                blockCount: mode.renderBlockCount,
                frameCount: 256,
                sampleRate: sampleRate
            )
            renderGroup.leave()
        }

        var publishDurations: [Double] = []
        publishDurations.reserveCapacity(mode.graphSwapUpdateCount)
        for iteration in 0..<mode.graphSwapUpdateCount {
            let editedTrackIndex = (iteration * 17) % mode.graphSwapTrackCount
            applySyntheticEdit(to: &timelines[editedTrackIndex], iteration: iteration)
            sourceRevisions[editedTrackIndex] += 1
            let updatedTracks = projectTracks(
                ids: trackIDs,
                timelines: timelines,
                sourceRevisions: sourceRevisions,
                iteration: iteration
            )
            let publishStart = DispatchTime.now().uptimeNanoseconds
            try playbackEngine.updateProjectTracks(updatedTracks)
            let publishMilliseconds = milliseconds(since: publishStart)
            publishDurations.append(publishMilliseconds)
            if iteration.isMultiple(of: 5) {
                try playbackEngine.seekExactly(toProgress: Float(Double((iteration * 13) % 97) / 97.0))
            }
        }

        renderGroup.wait()
        playbackEngine.pause()
        metrics.graphSwapTrackCount = max(metrics.graphSwapTrackCount, mode.graphSwapTrackCount)
        metrics.graphSwapUpdateCount = max(metrics.graphSwapUpdateCount, mode.graphSwapUpdateCount)
        metrics.graphSwapRenderBlockCount = max(metrics.graphSwapRenderBlockCount, mode.renderBlockCount)
        metrics.maxGraphSwapMilliseconds = publishDurations.max() ?? 0
        metrics.graphSwapP95Milliseconds = percentile(publishDurations, percentile: 0.95)
        metrics.absorb(playbackEngine.realtimeSnapshotForSafetySmoke())
        try require(metrics.maxGraphSwapMilliseconds < 24, String(format: "edit graph swap max too slow %.3fms", metrics.maxGraphSwapMilliseconds))
        try require(metrics.graphSwapP95Milliseconds < 8, String(format: "edit graph swap p95 too slow %.3fms", metrics.graphSwapP95Milliseconds))
    }

    private static func verifyCoreProjectTrackPlayback(metrics: inout SafetyMetrics) throws {
        let sampleRate = 48_000.0
        let buffer = syntheticAudioBuffer(frameCount: Int(sampleRate * 2), sampleRate: sampleRate)
        let peak = try renderPlaybackPeak(sampleRate: sampleRate) { playbackEngine in
            try playbackEngine.loadProjectTracks([
                ProjectPlaybackTrack(
                    id: stableUUID("00000000-0000-4000-a100-%012d", 1),
                    source: .timeline(audioTimeline: AudioEditTimeline(sourceBuffer: buffer), zeroCrossingIndex: nil),
                    sourceRevision: 0,
                    volume: 1,
                    isMuted: false,
                    isSoloed: false
                ),
            ])
        }
        metrics.minimumCorePlaybackPeak = min(metrics.minimumCorePlaybackPeak, peak)
        try require(peak > 0.000_5, "core project track playback rendered silence")
    }

    private static func verifyPlaybackAfterImport(rootDirectory: URL, mode: SmokeMode, metrics: inout SafetyMetrics) throws {
        let manifest = try readManifest(rootDirectory: rootDirectory)
        let expectedFormats: Set<String> = ["wav", "mp3", "mpeg4Audio", "aiff", "aac", "flac", "caf"]
        let importableAudio = manifest.audio
            .filter { entry in
                guard
                    let format = entry.format,
                    expectedFormats.contains(format),
                    entry.importExpectation == .importable
                else {
                    return false
                }
                return true
            }
            .sorted { ($0.format ?? "") < ($1.format ?? "") }
        let formatsFound = Set(importableAudio.compactMap(\.format))
        try require(formatsFound == expectedFormats, "audio safety fixture formats mismatch: \(formatsFound.sorted())")
        let audioToImport = selectedImportFixtures(from: importableAudio, mode: mode, expectedFormats: expectedFormats)

        var importedFormats = Set<String>()
        for audio in audioToImport {
            let sourceURL = rootDirectory.appendingPathComponent(audio.path).standardizedFileURL
            let originalInfo = try AudioAssetImporter.inspectSynchronously(url: sourceURL)
            let originalPeak = try renderOriginalPlaybackPeak(
                sourceURL: sourceURL,
                expectedSampleRate: try requireValue(
                    originalInfo.sampleRate,
                    "\(audio.id) did not expose a source sample rate"
                )
            )
            metrics.minimumOriginalPlaybackPeak = min(
                metrics.minimumOriginalPlaybackPeak,
                originalPeak
            )
            try require(
                originalPeak > 0.000_5,
                "\(audio.id) \(audio.format ?? "unknown") original-file playback rendered silence"
            )

            let proxy = try awaitValue {
                try await AudioAssetImporter.importEditableAsset(at: sourceURL)
            }
            let peak = try renderImportedPlaybackPeak(proxy: proxy)
            if let format = audio.format {
                importedFormats.insert(format)
            }
            metrics.minimumImportPlaybackPeak = min(metrics.minimumImportPlaybackPeak, peak)
            try require(peak > 0.000_5, "\(audio.id) \(audio.format ?? "unknown") playback rendered silence after import")
        }
        metrics.importedFormatCount = importedFormats.count
        metrics.importedFileCount = audioToImport.count
        metrics.importedFormats = importedFormats.sorted()
    }

    private static func renderOriginalPlaybackPeak(
        sourceURL: URL,
        expectedSampleRate: Double
    ) throws -> Float {
        let track = ProjectPlaybackTrack(
            id: stableUUID("00000000-0000-4000-a001-%012d", 1),
            source: .file(url: sourceURL, zeroCrossingProbe: nil),
            sourceRevision: 0,
            volume: 1,
            isMuted: false,
            isSoloed: false
        )
        let playbackController = MultitrackPlaybackController()
        try playbackController.loadProjectTracks([track])
        defer {
            playbackController.clear()
        }
        try require(
            playbackController.hasSource,
            "\(sourceURL.lastPathComponent) was not admitted by original-file playback"
        )

        let audioFile = try AVAudioFile(
            forReading: sourceURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try require(
            abs(audioFile.processingFormat.sampleRate - expectedSampleRate) < 0.5,
            "\(sourceURL.lastPathComponent) original playback sample rate changed"
        )
        let frameCapacity = AVAudioFrameCount(
            min(max(audioFile.length, 1), 4_096)
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: frameCapacity
        ) else {
            throw SmokeError.failed(
                "\(sourceURL.lastPathComponent) could not allocate an original playback buffer"
            )
        }
        try audioFile.read(into: buffer, frameCount: frameCapacity)
        guard
            let channelData = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            throw SmokeError.failed(
                "\(sourceURL.lastPathComponent) original playback produced no PCM frames"
            )
        }
        var peak: Float = 0
        for channelIndex in 0..<Int(buffer.format.channelCount) {
            for frameIndex in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channelData[channelIndex][frameIndex]))
            }
        }
        return peak
    }

    private static func selectedImportFixtures(
        from fixtures: [FixtureManifest.Audio],
        mode: SmokeMode,
        expectedFormats: Set<String>
    ) -> [FixtureManifest.Audio] {
        guard mode == .quick else {
            return fixtures
        }

        return expectedFormats
            .sorted()
            .compactMap { format in
                fixtures
                    .filter { $0.format == format }
                    .min { lhs, rhs in
                        let lhsDuration = lhs.durationSeconds ?? .greatestFiniteMagnitude
                        let rhsDuration = rhs.durationSeconds ?? .greatestFiniteMagnitude
                        if lhsDuration == rhsDuration {
                            return lhs.id < rhs.id
                        }
                        return lhsDuration < rhsDuration
                    }
            }
    }

    private static func renderImportedPlaybackPeak(proxy: AudioAssetProxyResult) throws -> Float {
        let proxyPeak = try renderPlaybackPeak(sampleRate: proxy.proxyFileInfo.sampleRate) { playbackEngine in
            try playbackEngine.loadProjectTracks([
                ProjectPlaybackTrack(
                    id: stableUUID("00000000-0000-4000-a000-%012d", 1),
                    source: .file(url: proxy.proxyURL, zeroCrossingProbe: nil),
                    sourceRevision: 0,
                    volume: 1,
                    isMuted: false,
                    isSoloed: false
                ),
            ])
        }
        try require(proxyPeak > 0.000_5, "persisted editable proxy rendered silence")

        return proxyPeak
    }

    private static func renderPlaybackPeak(
        sampleRate: Double,
        configure: (RealtimeCorePlaybackEngine) throws -> Void
    ) throws -> Float {
        let outputDevice = AudioSafetySmokeOutputDevice()
        guard let playbackEngine = RealtimeCorePlaybackEngine(outputDevice: outputDevice) else {
            throw SmokeError.failed("could not create realtime playback engine for import playback")
        }
        try configure(playbackEngine)
        try playbackEngine.play()
        let corePointer = try requireValue(outputDevice.corePointer, "import playback output device did not receive core pointer")
        var peak: Float = 0
        for progress in [0.02, 0.08, 0.18, 0.34, 0.50, 0.72, 0.88] {
            try playbackEngine.seekExactly(toProgress: Float(progress))
            let captured = renderCaptured(
                corePointer: corePointer,
                blockCount: 24,
                frameCount: 256,
                sampleRate: sampleRate
            )
            peak = max(
                peak,
                captured.left.map { Swift.abs($0) }.max() ?? 0,
                captured.right.map { Swift.abs($0) }.max() ?? 0
            )
        }
        playbackEngine.pause()
        let snapshot = playbackEngine.realtimeSnapshotForSafetySmoke()
        try require(snapshot.underrunCount == 0, "import playback produced \(snapshot.underrunCount) underrun(s)")
        try require(snapshot.droppedCommandCount == 0, "import playback dropped \(snapshot.droppedCommandCount) command(s)")
        try require(
            snapshot.renderWorkDeadlineMissCount == 0,
            "import playback CPU work missed \(snapshot.renderWorkDeadlineMissCount) render deadline(s)"
        )
        return peak
    }

    private static func projectTracks(
        ids: [UUID],
        timelines: [AudioEditTimeline],
        sourceRevisions: [Int],
        iteration: Int
    ) -> [ProjectPlaybackTrack] {
        var tracks: [ProjectPlaybackTrack] = []
        tracks.reserveCapacity(ids.count)
        for index in ids.indices {
            let volume = Float(0.62 + 0.32 * (Double((index + iteration) % 13) / 12.0))
            tracks.append(ProjectPlaybackTrack(
                id: ids[index],
                source: .timeline(audioTimeline: timelines[index], zeroCrossingIndex: nil),
                sourceRevision: sourceRevisions[index],
                volume: volume,
                isMuted: (index + iteration).isMultiple(of: 23),
                isSoloed: false
            ))
        }
        return tracks
    }

    private static func applySyntheticEdit(to timeline: inout AudioEditTimeline, iteration: Int) {
        let startProgress = Double((iteration * 7_919) % 900_000) / 1_000_000.0
        let endProgress = min(startProgress + 0.001_2 + Double(iteration % 5) * 0.000_18, 0.995)
        let selection = TimelineSelection(startProgress: startProgress, endProgress: endProgress)
        switch iteration % 5 {
        case 0:
            _ = timeline.delete(selection)
        case 1:
            _ = timeline.applyGain(0.72, to: selection)
        case 2:
            _ = timeline.applyGain(1.18, to: selection)
        case 3:
            _ = timeline.applyFade(.fadeIn, to: selection)
        default:
            _ = timeline.applyFade(.fadeOut, to: selection)
        }
    }

    private static func syntheticAudioBuffer(frameCount: Int, sampleRate: Double) -> DecodedAudioBuffer {
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            let envelope = 0.55 + 0.45 * sin(time * .pi * 2 * 0.37)
            let sample = Float(
                envelope *
                    (sin(time * .pi * 2 * 220) * 0.28 +
                        sin(time * .pi * 2 * 880) * 0.12 +
                        sin(time * .pi * 2 * 1_760) * 0.04)
            )
            left.append(sample)
            right.append(-sample * 0.78)
        }
        return DecodedAudioBuffer(
            url: URL(fileURLWithPath: "/tmp/SoundtimeAudioSafetySmoke.wav"),
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [left, right]
        )
    }

    private nonisolated static func render(
        corePointer: OpaquePointer,
        blockCount: Int,
        frameCount: Int,
        sampleRate: Double
    ) {
        var leftOutput = [Float](repeating: 0, count: frameCount)
        var rightOutput = [Float](repeating: 0, count: frameCount)
        for blockIndex in 0..<blockCount {
            leftOutput.withUnsafeMutableBufferPointer { leftBuffer in
                rightOutput.withUnsafeMutableBufferPointer { rightBuffer in
                    var outputs: [UnsafeMutablePointer<Float>?] = [
                        leftBuffer.baseAddress,
                        rightBuffer.baseAddress,
                    ]
                    outputs.withUnsafeMutableBufferPointer { outputBuffer in
                        soundtime_audio_core_render_at_host_time(
                            corePointer,
                            outputBuffer.baseAddress,
                            2,
                            UInt32(frameCount),
                            Double(blockIndex * frameCount) / sampleRate
                        )
                    }
                }
            }
        }
    }

    private nonisolated static func renderAtHostTime(
        corePointer: OpaquePointer,
        frameCount: Int,
        hostTimestamp: TimeInterval
    ) {
        var leftOutput = [Float](repeating: 0, count: frameCount)
        var rightOutput = [Float](repeating: 0, count: frameCount)
        leftOutput.withUnsafeMutableBufferPointer { leftBuffer in
            rightOutput.withUnsafeMutableBufferPointer { rightBuffer in
                var outputs: [UnsafeMutablePointer<Float>?] = [
                    leftBuffer.baseAddress,
                    rightBuffer.baseAddress,
                ]
                outputs.withUnsafeMutableBufferPointer { outputBuffer in
                    soundtime_audio_core_render_at_host_time(
                        corePointer,
                        outputBuffer.baseAddress,
                        2,
                        UInt32(frameCount),
                        hostTimestamp
                    )
                }
            }
        }
    }

    private nonisolated static func renderCapturedAtHostTime(
        corePointer: OpaquePointer,
        blockCount: Int,
        frameCount: Int,
        sampleRate: Double,
        firstHostTimestamp: TimeInterval
    ) -> (left: [Float], right: [Float]) {
        var leftOutput = [Float](repeating: 0, count: frameCount)
        var rightOutput = [Float](repeating: 0, count: frameCount)
        var capturedLeft: [Float] = []
        var capturedRight: [Float] = []
        capturedLeft.reserveCapacity(blockCount * frameCount)
        capturedRight.reserveCapacity(blockCount * frameCount)
        for blockIndex in 0..<blockCount {
            leftOutput.withUnsafeMutableBufferPointer { leftBuffer in
                rightOutput.withUnsafeMutableBufferPointer { rightBuffer in
                    var outputs: [UnsafeMutablePointer<Float>?] = [
                        leftBuffer.baseAddress,
                        rightBuffer.baseAddress,
                    ]
                    outputs.withUnsafeMutableBufferPointer { outputBuffer in
                        soundtime_audio_core_render_at_host_time(
                            corePointer,
                            outputBuffer.baseAddress,
                            2,
                            UInt32(frameCount),
                            firstHostTimestamp + Double(blockIndex * frameCount) / sampleRate
                        )
                    }
                    if let baseAddress = leftBuffer.baseAddress {
                        capturedLeft.append(
                            contentsOf: UnsafeBufferPointer(
                                start: baseAddress,
                                count: frameCount
                            )
                        )
                    }
                    if let baseAddress = rightBuffer.baseAddress {
                        capturedRight.append(
                            contentsOf: UnsafeBufferPointer(
                                start: baseAddress,
                                count: frameCount
                            )
                        )
                    }
                }
            }
        }
        return (capturedLeft, capturedRight)
    }

    private nonisolated static func renderCaptured(
        corePointer: OpaquePointer,
        blockCount: Int,
        frameCount: Int,
        sampleRate: Double
    ) -> (left: [Float], right: [Float]) {
        var leftOutput = [Float](repeating: 0, count: frameCount)
        var rightOutput = [Float](repeating: 0, count: frameCount)
        var capturedLeft: [Float] = []
        var capturedRight: [Float] = []
        capturedLeft.reserveCapacity(blockCount * frameCount)
        capturedRight.reserveCapacity(blockCount * frameCount)
        for blockIndex in 0..<blockCount {
            leftOutput.withUnsafeMutableBufferPointer { leftBuffer in
                rightOutput.withUnsafeMutableBufferPointer { rightBuffer in
                    var outputs: [UnsafeMutablePointer<Float>?] = [
                        leftBuffer.baseAddress,
                        rightBuffer.baseAddress,
                    ]
                    outputs.withUnsafeMutableBufferPointer { outputBuffer in
                        soundtime_audio_core_render_at_host_time(
                            corePointer,
                            outputBuffer.baseAddress,
                            2,
                            UInt32(frameCount),
                            Double(blockIndex * frameCount) / sampleRate
                        )
                    }
                    if let baseAddress = leftBuffer.baseAddress {
                        capturedLeft.append(contentsOf: UnsafeBufferPointer(start: baseAddress, count: frameCount))
                    }
                    if let baseAddress = rightBuffer.baseAddress {
                        capturedRight.append(contentsOf: UnsafeBufferPointer(start: baseAddress, count: frameCount))
                    }
                }
            }
        }
        return (capturedLeft, capturedRight)
    }

    private static func fixtureRoot(arguments: [String]) throws -> URL {
        if
            let explicitIndex = arguments.firstIndex(of: "--fixtures-output"),
            arguments.indices.contains(explicitIndex + 1)
        {
            return URL(fileURLWithPath: arguments[explicitIndex + 1], isDirectory: true).standardizedFileURL
        }
        if let path = ProcessInfo.processInfo.environment["SOUNDTIME_SHIPPABILITY_FIXTURE_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        throw SmokeError.failed("missing fixture root")
    }

    private static func readManifest(rootDirectory: URL) throws -> FixtureManifest {
        let manifestURL = rootDirectory.appendingPathComponent("fixtures-manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(FixtureManifest.self, from: data)
    }

    private static func awaitValue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = AudioSafetySmokeResultBox<T>()
        Task.detached {
            do {
                box.result = Result.success(try await operation())
            } catch {
                box.result = Result.failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.result {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        case nil:
            throw SmokeError.failed("async audio safety operation did not produce a result")
        }
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sortedValues = values.sorted()
        let clampedPercentile = min(max(percentile, 0), 1)
        let index = min(
            max(Int((Double(sortedValues.count - 1) * clampedPercentile).rounded()), 0),
            sortedValues.count - 1
        )
        return sortedValues[index]
    }

    private static func milliseconds(since startTime: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000
    }

    private static func modeName(_ mode: SmokeMode) -> String {
        switch mode {
        case .quick:
            "quick"
        case .standard:
            "standard"
        case .stress:
            "full"
        }
    }

    private static func stableUUID(_ format: String, _ value: Int) -> UUID {
        UUID(uuidString: String(format: format, value)) ?? UUID()
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw SmokeError.failed(message)
        }
        return value
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw SmokeError.failed(message)
        }
        return value
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw SmokeError.failed(message)
        }
    }
}

private final class AudioSafetySmokeOutputDevice: RealtimeAudioOutputDevice {
    var corePointer: OpaquePointer?
    private(set) var configureCount = 0
    private(set) var invalidateCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastSampleRate = 0.0

    func configure(corePointer: OpaquePointer, sampleRate: Double) throws {
        configureCount += 1
        self.corePointer = corePointer
        lastSampleRate = sampleRate
    }

    func invalidateConfiguration() {
        invalidateCount += 1
    }

    func start() throws {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

private struct UncheckedCorePointer: @unchecked Sendable {
    let pointer: OpaquePointer
}
