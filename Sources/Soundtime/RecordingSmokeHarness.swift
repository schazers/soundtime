import Foundation

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
        }

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

        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "recording-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: [
                "streaming WAV writer preserves frame/channel/sample-rate metadata",
                "recording preview and live preview produce waveform bins",
                "decoded recording round-trips channel samples",
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
