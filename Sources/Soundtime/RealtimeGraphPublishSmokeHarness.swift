import Darwin
import Foundation
import SoundtimeAudioCore

@MainActor
enum RealtimeGraphPublishSmokeHarness {
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
        let isFull = arguments.contains("--realtime-graph-publish-full")
        let trackCount = isFull ? 256 : 128
        let updateCount = isFull ? 220 : 96
        let renderBlockCount = isFull ? 10_000 : 4_000
        let renderBlockFrameCount = 256
        let sampleRate = 48_000.0
        let sourceFrameCount = Int(sampleRate) * 30
        let outputDevice = RealtimeGraphPublishSmokeOutputDevice()

        guard let playbackEngine = RealtimeCorePlaybackEngine(outputDevice: outputDevice) else {
            throw SmokeError.failed("could not create realtime playback engine")
        }

        let sourceBuffer = syntheticAudioBuffer(frameCount: sourceFrameCount, sampleRate: sampleRate)
        let baseTimeline = AudioEditTimeline(sourceBuffer: sourceBuffer)
        var timelines = Array(repeating: baseTimeline, count: trackCount)
        var sourceRevisions = Array(repeating: 0, count: trackCount)
        let trackIDs = (0..<trackCount).map { index in
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index)) ?? UUID()
        }

        try playbackEngine.loadProjectTracks(projectTracks(
            ids: trackIDs,
            timelines: timelines,
            sourceRevisions: sourceRevisions,
            iteration: 0
        ))
        try playbackEngine.play()

        guard let corePointer = outputDevice.corePointer else {
            throw SmokeError.failed("realtime output device was not configured")
        }

        let renderGroup = DispatchGroup()
        renderGroup.enter()
        let uncheckedCorePointer = UncheckedAudioCorePointer(pointer: corePointer)
        DispatchQueue.global(qos: .userInitiated).async {
            render(
                corePointer: uncheckedCorePointer.pointer,
                blockCount: renderBlockCount,
                frameCount: renderBlockFrameCount,
                sampleRate: sampleRate
            )
            renderGroup.leave()
        }

        var publishDurations: [Double] = []
        var mixDurations: [Double] = []
        var seekDurations: [Double] = []
        publishDurations.reserveCapacity(updateCount)
        mixDurations.reserveCapacity(updateCount)
        seekDurations.reserveCapacity(updateCount / 8)
        let startTime = DispatchTime.now().uptimeNanoseconds

        for iteration in 0..<updateCount {
            let editedTrackIndex = (iteration * 37) % trackCount
            applySyntheticEdit(
                to: &timelines[editedTrackIndex],
                iteration: iteration
            )
            sourceRevisions[editedTrackIndex] += 1

            let updatedTracks = projectTracks(
                ids: trackIDs,
                timelines: timelines,
                sourceRevisions: sourceRevisions,
                iteration: iteration
            )

            let publishStart = DispatchTime.now().uptimeNanoseconds
            try playbackEngine.updateProjectTracks(updatedTracks)
            publishDurations.append(milliseconds(since: publishStart))

            let mixTracks = projectTracks(
                ids: trackIDs,
                timelines: timelines,
                sourceRevisions: sourceRevisions,
                iteration: iteration + 1
            )
            let mixStart = DispatchTime.now().uptimeNanoseconds
            playbackEngine.updateProjectTrackMix(mixTracks)
            mixDurations.append(milliseconds(since: mixStart))

            if iteration.isMultiple(of: 8) {
                let seekStart = DispatchTime.now().uptimeNanoseconds
                try playbackEngine.seekExactly(toProgress: Float(Double(iteration % 97) / 97.0))
                seekDurations.append(milliseconds(since: seekStart))
            }
        }

        renderGroup.wait()
        playbackEngine.pause()

        let elapsedMilliseconds = milliseconds(since: startTime)
        let publishP95 = percentile(publishDurations, percentile: 0.95)
        let publishMax = publishDurations.max() ?? 0
        let mixP95 = percentile(mixDurations, percentile: 0.95)
        let mixMax = mixDurations.max() ?? 0
        let seekP95 = percentile(seekDurations, percentile: 0.95)
        let snapshot = soundtime_audio_core_snapshot(corePointer)

        try require(snapshot.droppedCommandCount == 0, "realtime core dropped \(snapshot.droppedCommandCount) commands")
        try require(
            publishP95 < (isFull ? 7.5 : 5.0),
            String(format: "graph publish p95 too slow: %.3fms", publishP95)
        )
        try require(
            publishMax < (isFull ? 24.0 : 18.0),
            String(format: "graph publish outlier too slow: %.3fms", publishMax)
        )
        try require(
            mixP95 < (isFull ? 5.0 : 3.5),
            String(format: "mix publish p95 too slow: %.3fms", mixP95)
        )
        try require(
            mixMax < (isFull ? 16.0 : 12.0),
            String(format: "mix publish outlier too slow: %.3fms", mixMax)
        )
        try require(
            seekP95 < 1.0,
            String(format: "seek p95 too slow during graph churn: %.3fms", seekP95)
        )

        print(
            String(
                format: "Soundtime realtime graph publish smoke passed: %d tracks, %d updates, publish %.3fms p95 / %.3fms max, mix %.3fms p95 / %.3fms max, seek %.3fms p95, %.2fms total",
                trackCount,
                updateCount,
                publishP95,
                publishMax,
                mixP95,
                mixMax,
                seekP95,
                elapsedMilliseconds
            )
        )
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
            let volume = Float(0.54 + 0.42 * (Double((index + iteration) % 19) / 18.0))
            tracks.append(ProjectPlaybackTrack(
                id: ids[index],
                source: .timeline(audioTimeline: timelines[index], zeroCrossingIndex: nil),
                sourceRevision: sourceRevisions[index],
                volume: volume,
                isMuted: (index + iteration).isMultiple(of: 29),
                isSoloed: false
            ))
        }
        return tracks
    }

    private static func applySyntheticEdit(
        to timeline: inout AudioEditTimeline,
        iteration: Int
    ) {
        let startProgress = Double((iteration * 8_191) % 900_000) / 1_000_000.0
        let endProgress = min(startProgress + 0.001_5 + Double(iteration % 7) * 0.000_15, 0.995)
        let selection = TimelineSelection(startProgress: startProgress, endProgress: endProgress)

        switch iteration % 6 {
        case 0:
            _ = timeline.applyGain(0.68, to: selection)
        case 1:
            _ = timeline.applyGain(1.16, to: selection)
        case 2:
            _ = timeline.applyFade(.fadeIn, to: selection)
        case 3:
            _ = timeline.applyFade(.fadeOut, to: selection)
        case 4:
            _ = timeline.delete(selection)
        default:
            _ = timeline.applyGain(0.91, to: selection)
        }
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

    private static func syntheticAudioBuffer(frameCount: Int, sampleRate: Double) -> DecodedAudioBuffer {
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            let phase = Double(frame) / sampleRate
            let sample = Float(
                sin(phase * 440.0 * 2.0 * .pi) * 0.32 +
                    sin(phase * 1_771.0 * 2.0 * .pi) * 0.08
            )
            left.append(sample)
            right.append(-sample * 0.82)
        }

        return DecodedAudioBuffer(
            url: URL(fileURLWithPath: "/tmp/SoundtimeRealtimeGraphPublishSmoke.wav"),
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [left, right]
        )
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

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SmokeError.failed(message)
        }
    }
}

private final class RealtimeGraphPublishSmokeOutputDevice: RealtimeAudioOutputDevice {
    var corePointer: OpaquePointer?

    func configure(corePointer: OpaquePointer, sampleRate _: Double) throws {
        self.corePointer = corePointer
    }

    func start() throws {}

    func stop() {}
}

private struct UncheckedAudioCorePointer: @unchecked Sendable {
    let pointer: OpaquePointer
}
