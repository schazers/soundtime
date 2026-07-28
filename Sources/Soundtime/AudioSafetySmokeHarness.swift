import Foundation
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
        var maxSeekFrameError = 0
        var maxLoopSampleError: Float = 0
        var maxGraphSwapMilliseconds = 0.0
        var graphSwapP95Milliseconds = 0.0
        var importedFormatCount = 0
        var importedFileCount = 0
        var importedFormats: [String] = []
        var minimumImportPlaybackPeak: Float = .greatestFiniteMagnitude
        var minimumCorePlaybackPeak: Float = .greatestFiniteMagnitude

        mutating func absorb(_ snapshot: RealtimeAudioCoreSnapshot) {
            underrunCount = max(underrunCount, snapshot.underrunCount)
            droppedCommandCount = max(droppedCommandCount, snapshot.droppedCommandCount)
            renderDeadlineMissCount = max(renderDeadlineMissCount, snapshot.renderDeadlineMissCount)
            maxRenderNanoseconds = max(maxRenderNanoseconds, snapshot.maxRenderNanoseconds)
        }

        mutating func absorb(_ snapshot: SoundtimeAudioCoreSnapshot) {
            underrunCount = max(underrunCount, Int(min(snapshot.underrunCount, UInt64(Int.max))))
            droppedCommandCount = max(droppedCommandCount, Int(min(snapshot.droppedCommandCount, UInt64(Int.max))))
            renderDeadlineMissCount = max(renderDeadlineMissCount, Int(min(snapshot.renderDeadlineMissCount, UInt64(Int.max))))
            maxRenderNanoseconds = max(maxRenderNanoseconds, Int(min(snapshot.maxRenderNanoseconds, UInt64(Int.max))))
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let mode = SmokeMode(arguments: arguments)
        let coreOnly = arguments.contains("--audio-safety-core-only")
        let maximumAttempts = shouldRetryDeadlineMisses(mode: mode, coreOnly: coreOnly) ? 2 : 1
        var lastError: Error?

        for attempt in 1...maximumAttempts {
            do {
                try runAttempt(
                    arguments: arguments,
                    mode: mode,
                    coreOnly: coreOnly,
                    attempt: attempt,
                    startedAtNanoseconds: startedAtNanoseconds
                )
                return
            } catch {
                lastError = error
                guard attempt < maximumAttempts, isRetryableDeadlineMiss(error) else {
                    throw error
                }
                print("Soundtime audio safety smoke hit a transient render deadline miss; retrying stress pass once")
            }
        }

        throw lastError ?? SmokeError.failed("audio safety smoke failed without a captured error")
    }

    private static func runAttempt(
        arguments: [String],
        mode: SmokeMode,
        coreOnly: Bool,
        attempt: Int,
        startedAtNanoseconds: UInt64
    ) throws {
        var metrics = SafetyMetrics()

        try verifyOutputDeviceConfiguration(metrics: &metrics)
        try verifySeekFramePosition(metrics: &metrics)
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
        try require(metrics.renderDeadlineMissCount == 0, "audio core missed \(metrics.renderDeadlineMissCount) render deadline(s)")

        var checks = [
            "no underruns or dropped realtime commands",
            "output device configure/refresh matches engine core and sample rate",
            "seek lands on expected frame position",
            "loop wrap returns sample-consistently to loop start",
            "edit graph swaps do not block realtime render",
        ]
        if coreOnly {
            checks.append("core project track playback renders audible audio")
        } else {
            checks.append("playback after import works for WAV/MP3/M4A/AIFF/AAC/FLAC/CAF")
        }

        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "audio-safety-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: [
                "mode": modeName(mode),
                "scope": coreOnly ? "core-only" : "full-import-matrix",
                "attempt": "\(attempt)",
                "underrunCount": "\(metrics.underrunCount)",
                "droppedCommandCount": "\(metrics.droppedCommandCount)",
                "renderDeadlineMissCount": "\(metrics.renderDeadlineMissCount)",
                "maxRenderNanoseconds": "\(metrics.maxRenderNanoseconds)",
                "maxSeekFrameError": "\(metrics.maxSeekFrameError)",
                "maxLoopSampleError": String(format: "%.8f", metrics.maxLoopSampleError),
                "maxGraphSwapMilliseconds": String(format: "%.3f", metrics.maxGraphSwapMilliseconds),
                "graphSwapP95Milliseconds": String(format: "%.3f", metrics.graphSwapP95Milliseconds),
                "importedFormatCount": "\(metrics.importedFormatCount)",
                "importedFileCount": "\(metrics.importedFileCount)",
                "importedFormats": metrics.importedFormats.joined(separator: ","),
                "minimumImportPlaybackPeak": String(format: "%.6f", metrics.minimumImportPlaybackPeak),
                "minimumCorePlaybackPeak": String(format: "%.6f", metrics.minimumCorePlaybackPeak),
            ],
            arguments: arguments
        ) {
            print("Soundtime audio safety smoke report: \(reportURL.path)")
        }
        print("Soundtime audio safety smoke passed")
    }

    private static func shouldRetryDeadlineMisses(mode: SmokeMode, coreOnly: Bool) -> Bool {
        mode == .stress &&
            !coreOnly &&
            ProcessInfo.processInfo.environment["SOUNDTIME_SHIPPABILITY_GATE"] == "1"
    }

    private static func isRetryableDeadlineMiss(_ error: Error) -> Bool {
        guard case let SmokeError.failed(message) = error else {
            return false
        }
        return message.localizedCaseInsensitiveContains("render deadline")
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
        playbackEngine.pause()
        try playbackEngine.refreshOutputDevice()
        try require(outputDevice.invalidateCount == 1, "output device refresh did not invalidate old configuration")
        try require(outputDevice.configureCount == 2, "output device refresh did not reconfigure")
        try require(outputDevice.corePointer == firstCorePointer, "output device refresh changed core pointer unexpectedly")
        try require(outputDevice.lastSampleRate == sampleRate, "output device refresh changed sample rate unexpectedly")
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
        try require(abs(playingSnapshot.frameIndex - expectedFrame) <= 1, "playing seek did not mirror exact frame immediately")
        render(corePointer: corePointer, blockCount: 4, frameCount: 256, sampleRate: sampleRate)
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
        let decodedPeak = try renderPlaybackPeak(sampleRate: proxy.decodedAudioBuffer.sampleRate) { playbackEngine in
            try playbackEngine.load(proxy.decodedAudioBuffer, zeroCrossingIndex: proxy.zeroCrossingIndex)
        }
        try require(decodedPeak > 0.000_5, "decoded import buffer rendered silence")

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

        return min(decodedPeak, proxyPeak)
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
        try require(snapshot.renderDeadlineMissCount == 0, "import playback missed \(snapshot.renderDeadlineMissCount) render deadline(s)")
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
