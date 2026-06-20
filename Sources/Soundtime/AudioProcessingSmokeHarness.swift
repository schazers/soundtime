import Foundation

enum AudioProcessingSmokeHarness {
    private enum SmokeError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(message):
                return message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundtimeAudioProcessingSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let inputURL = directory.appendingPathComponent("noisy-input.wav")
        let inputBuffer = noisySpeechLikeBuffer(url: inputURL)
        try WAVFileWriter.write(inputBuffer, to: inputURL)

        let provider = LocalDenoiseAudioProcessingProvider()
        let inputAsset = AudioProcessingInputAsset(
            id: UUID(),
            trackID: UUID(),
            url: inputURL,
            displayName: "DenoiseSmoke",
            sampleRate: inputBuffer.sampleRate,
            channelCount: inputBuffer.channelCount,
            frameCount: inputBuffer.frameCount,
            timelineStartTime: 0
        )
        let request = AudioProcessingRequest(
            id: UUID(),
            operation: .denoise,
            renderMode: .perTrackSelection,
            inputAssets: [inputAsset],
            outputDirectory: directory
        )
        let result = try provider.processSynchronously(request)

        guard let outputAsset = result.outputAssets.first else {
            throw SmokeError.failed("denoise provider produced no output")
        }

        let outputBuffer = try WAVAudioDecoder.decode(url: outputAsset.url)
        try require(outputBuffer.frameCount == inputBuffer.frameCount, "denoise changed frame count")
        try require(outputBuffer.channelCount == inputBuffer.channelCount, "denoise changed channel count")

        let quietRange = 0..<min(Int(inputBuffer.sampleRate * 0.35), inputBuffer.frameCount)
        let voicedRange = Int(inputBuffer.sampleRate * 0.65)..<min(Int(inputBuffer.sampleRate * 1.25), inputBuffer.frameCount)
        let inputQuietRMS = rms(inputBuffer, frameRange: quietRange)
        let outputQuietRMS = rms(outputBuffer, frameRange: quietRange)
        let inputVoicedRMS = rms(inputBuffer, frameRange: voicedRange)
        let outputVoicedRMS = rms(outputBuffer, frameRange: voicedRange)

        try require(outputQuietRMS < inputQuietRMS * 0.55, "denoise did not reduce quiet noise enough")
        try require(outputVoicedRMS > inputVoicedRMS * 0.45, "denoise removed too much voiced material")

        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "audio-processing-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: [
                "local denoise provider preserves shape and reduces quiet noise",
            ],
            metadata: [
                "inputQuietRMS": String(format: "%.6f", inputQuietRMS),
                "outputQuietRMS": String(format: "%.6f", outputQuietRMS),
                "inputVoicedRMS": String(format: "%.6f", inputVoicedRMS),
                "outputVoicedRMS": String(format: "%.6f", outputVoicedRMS),
            ],
            arguments: arguments
        ) {
            print("Soundtime audio processing smoke report: \(reportURL.path)")
        }

        print("Soundtime audio processing smoke passed")
    }

    private static func noisySpeechLikeBuffer(url: URL) -> DecodedAudioBuffer {
        let sampleRate = 48_000.0
        let frameCount = Int(sampleRate * 1.6)
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)

        var randomState: UInt64 = 0x1234_5678_ABCD_EF01
        for frame in 0..<frameCount {
            let t = Double(frame) / sampleRate
            let envelope: Float
            if t < 0.45 || t > 1.42 {
                envelope = 0
            } else {
                let attack = min(max((t - 0.45) / 0.12, 0), 1)
                let release = min(max((1.42 - t) / 0.16, 0), 1)
                envelope = Float(min(attack, release))
            }
            let voice = Float(sin(2 * Double.pi * 180 * t) * 0.22 + sin(2 * Double.pi * 410 * t) * 0.08) * envelope
            let noise = nextNoise(&randomState) * 0.024
            left.append(min(max(voice + noise, -1), 1))
            right.append(min(max(voice * 0.96 + noise * 0.9, -1), 1))
        }

        return DecodedAudioBuffer(
            url: url,
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [left, right]
        )
    }

    private static func nextNoise(_ state: inout UInt64) -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let value = Float((state >> 40) & 0xFF_FFFF) / Float(0xFF_FFFF)
        return value * 2 - 1
    }

    private static func rms(_ buffer: DecodedAudioBuffer, frameRange: Range<Int>) -> Float {
        guard !frameRange.isEmpty else {
            return 0
        }
        var sum: Double = 0
        var count = 0
        for samples in buffer.samplesByChannel {
            let lowerBound = min(max(frameRange.lowerBound, 0), samples.count)
            let upperBound = min(max(frameRange.upperBound, lowerBound), samples.count)
            for sample in samples[lowerBound..<upperBound] {
                sum += Double(sample * sample)
                count += 1
            }
        }
        guard count > 0 else {
            return 0
        }
        return Float(sqrt(sum / Double(count)))
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SmokeError.failed(message)
        }
    }
}
