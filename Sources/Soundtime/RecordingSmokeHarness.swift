import Foundation
import SoundtimeEditing

enum RecordingSmokeHarness {
    enum SmokeError: LocalizedError {
        case invalidTake(String)

        var errorDescription: String? {
            switch self {
            case let .invalidTake(message):
                message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundtimeRecordingSmoke-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let sampleRate = 48_000.0
        let channelCount = 2
        let chunkFrameCount = 1_024
        let chunkCount = arguments.contains("--long") ? 32 : 4
        let expectedFrameCount = chunkFrameCount * chunkCount
        let writer = try StreamingWAVTakeWriter(url: tempURL)
        var liveAccumulator = LiveRecordingWaveformAccumulator(sampleRate: sampleRate)
        let liveLayerID = UUID()
        var liveRevision = 0
        var publishedCompletedBinCount = 0
        var emittedCompletedBinCount = 0
        var previousPublishedDuration: TimeInterval = 0

        for chunkIndex in 0..<chunkCount {
            let chunk = makeSyntheticChunk(
                sampleRate: sampleRate,
                channelCount: channelCount,
                frameCount: chunkFrameCount,
                frameOffset: chunkIndex * chunkFrameCount
            )
            writer.append(chunk)
            liveAccumulator.append(
                samplesByChannel: chunk.samplesByChannel,
                frameCount: chunk.frameCount
            )
            liveRevision += 1
            let publication = liveAccumulator.makePublication(
                layerID: liveLayerID,
                revision: liveRevision,
                afterCompletedBinCount: publishedCompletedBinCount,
                sampleRate: sampleRate
            )
            try require(publication.layerID == liveLayerID, "live publication changed layer identity")
            try require(publication.revision == liveRevision, "live publication changed revision")
            try require(
                publication.completedBinStartIndex == publishedCompletedBinCount,
                "live publication did not continue at the last published bin"
            )
            try require(
                publication.completedBins.count == publication.totalCompletedBinCount - publishedCompletedBinCount,
                "live publication duplicated or omitted completed bins"
            )
            try require(
                publication.duration >= previousPublishedDuration,
                "live publication duration moved backward"
            )
            try require(publication.drawableBinCount > 0, "live publication had no drawable waveform")
            emittedCompletedBinCount += publication.completedBins.count
            publishedCompletedBinCount = publication.totalCompletedBinCount
            previousPublishedDuration = publication.duration
        }

        liveRevision += 1
        let unchangedPublication = liveAccumulator.makePublication(
            layerID: liveLayerID,
            revision: liveRevision,
            afterCompletedBinCount: publishedCompletedBinCount,
            sampleRate: sampleRate
        )
        try require(
            unchangedPublication.completedBins.isEmpty,
            "an unchanged live publication resent completed bins"
        )
        try require(
            emittedCompletedBinCount == liveAccumulator.bins.count,
            "incremental live publications did not cover every completed bin exactly once"
        )

        let take = try writer.finish()
        try require(take.frameCount == expectedFrameCount, "recorded take frame count mismatch")
        try require(take.channelCount == channelCount, "recorded take channel count mismatch")
        try require(abs(take.sampleRate - sampleRate) < 0.5, "recorded take sample rate mismatch")

        let fileInfo = try WAVAudioDecoder.inspect(url: tempURL)
        try require(fileInfo.frameCount == expectedFrameCount, "WAV header frame count mismatch")
        try require(fileInfo.channelCount == channelCount, "WAV header channel count mismatch")
        try require(abs(fileInfo.sampleRate - sampleRate) < 0.5, "WAV header sample rate mismatch")

        let (_, overview) = try WAVAudioDecoder.buildSparsePreview(
            url: tempURL,
            targetBinCount: 128,
            samplesPerBin: 8
        )
        try require(!overview.bins.isEmpty, "recording preview generated no bins")
        let liveOverview = liveAccumulator.makeOverview(sampleRate: sampleRate)
        try require(liveAccumulator.totalFrameCount == expectedFrameCount, "live preview frame count mismatch")
        try require(!liveOverview.bins.isEmpty, "live preview generated no bins")
        try require(
            abs(liveOverview.duration - take.duration) < 0.000_1,
            "live preview duration did not match recorded take"
        )

        let decoded = try WAVAudioDecoder.decode(url: tempURL)
        try require(decoded.frameCount == expectedFrameCount, "decoded recording frame count mismatch")
        try require(decoded.samplesByChannel.count == channelCount, "decoded recording channel count mismatch")
        try require(decoded.samplesByChannel.allSatisfy { $0.count == expectedFrameCount }, "decoded channel lengths mismatch")
        try verifyPunchInOverwrite()

        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "recording-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: [
                "streaming WAV writer preserves frame/channel/sample-rate metadata",
                "recording preview and live preview produce waveform bins",
                "live preview publishes append-only waveform deltas without rebuilding history",
                "decoded recording round-trips channel samples",
                "punch-in recording overwrites only the recorded interval",
            ],
            metadata: [
                "frameCount": "\(expectedFrameCount)",
                "channelCount": "\(channelCount)",
                "sampleRate": "\(Int(sampleRate))",
                "chunkCount": "\(chunkCount)",
            ],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }

        print(
            "Soundtime recording smoke passed: \(expectedFrameCount) frames, " +
            "\(channelCount) channels, \(Int(sampleRate)) Hz"
        )
    }

    private static func verifyPunchInOverwrite() throws {
        let trackID = UUID()
        let originalSource = TimelineMediaSource(
            id: .init(rawValue: "recording-smoke-original"),
            frameCount: 1_000,
            sampleRate: 100,
            channelCount: 1
        )
        let recordedSource = TimelineMediaSource(
            id: .init(rawValue: "recording-smoke-take"),
            frameCount: 200,
            sampleRate: 100,
            channelCount: 1
        )
        let originalClip = TimelineClip(
            sourceID: originalSource.id,
            timelineRange: .init(startFrame: 0, frameCount: 1_000),
            sourceRange: .init(startFrame: 0, frameCount: 1_000),
            name: "Original"
        )
        let graph = try TimelineClipGraph(
            sources: [originalSource],
            tracks: [TimelineTrack(
                id: trackID,
                name: "Voice",
                clips: [originalClip],
                volume: 0.72,
                pan: -0.25,
                isMuted: false,
                isSoloed: true
            )],
            revision: 7,
            timelineSampleRate: 100
        )
        let takeID = AudioTimelineClipID()
        let result = try TimelineRecordingEditingService.overwrite(
            trackID: trackID,
            timelineStartFrame: 400,
            source: recordedSource,
            clipID: takeID,
            clipName: "Voice Take",
            in: graph,
            expectedRevision: graph.revision
        )
        guard let track = result.graph.track(id: trackID) else {
            throw SmokeError.invalidTake("punch-in removed its destination track")
        }
        let clips = track.clips.sorted { $0.timelineRange.startFrame < $1.timelineRange.startFrame }
        try require(clips.count == 3, "punch-in did not split the overwritten clip into three regions")
        try require(
            clips[0].timelineRange == TimelineFrameRange(startFrame: 0, frameCount: 400),
            "punch-in changed media before the playhead"
        )
        try require(clips[1].id == takeID, "punch-in did not preserve the recording clip identity")
        try require(
            clips[1].timelineRange == TimelineFrameRange(startFrame: 400, frameCount: 200),
            "recording was not placed at the playhead"
        )
        try require(
            clips[2].timelineRange == TimelineFrameRange(startFrame: 600, frameCount: 400),
            "punch-in changed media after the recorded interval"
        )
        try require(
            clips[2].sourceRange == TimelineFrameRange(startFrame: 600, frameCount: 400),
            "right-side source mapping changed after punch-in"
        )
        try require(abs(track.volume - 0.72) < 0.000_1, "punch-in changed track volume")
        try require(abs(track.pan - (-0.25)) < 0.000_1, "punch-in changed track pan")
        try require(track.isSoloed, "punch-in changed track solo state")
    }

    private static func makeSyntheticChunk(
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        frameOffset: Int
    ) -> AudioRecordingChunk {
        var channels = Array(repeating: Array(repeating: Float(0), count: frameCount), count: channelCount)
        for frameIndex in 0..<frameCount {
            let absoluteFrame = frameOffset + frameIndex
            let time = Double(absoluteFrame) / sampleRate
            channels[0][frameIndex] = Float(sin(time * 2 * Double.pi * 440) * 0.35)
            if channelCount > 1 {
                channels[1][frameIndex] = Float(sin(time * 2 * Double.pi * 660) * 0.22)
            }
        }

        return AudioRecordingChunk(
            samplesByChannel: channels,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            hostTimestamp: Double(frameOffset) / sampleRate
        )
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SmokeError.invalidTake(message)
        }
    }
}
