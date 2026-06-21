import Foundation

private final class AudioAssetImporterSmokeResultBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}

enum AudioAssetImporterSmokeHarness {
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
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundtime-audio-asset-importer-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootDirectory)
        }

        try verifyCommonFormatRecognition()
        try verifyWAVFacadeRoundTrip(rootDirectory: rootDirectory)

        let checks = [
            "common audio format recognition",
            "wav importer facade preview/decode round trip",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "audio-asset-importer-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: ["nonWAVDecode": "not-yet-wired"],
            arguments: arguments
        ) {
            print("Soundtime audio asset importer smoke report: \(reportURL.path)")
        }
        print("Soundtime audio asset importer smoke passed")
    }

    private static func verifyCommonFormatRecognition() throws {
        let expectedFormats: [(String, AudioAssetFormat)] = [
            ("voice.wav", .wav),
            ("voice.wave", .wav),
            ("music.aiff", .aiff),
            ("music.aif", .aiff),
            ("music.aifc", .aiff),
            ("episode.mp3", .mp3),
            ("mix.m4a", .mpeg4Audio),
            ("movie.mp4", .mpeg4Audio),
            ("lossless.alac", .mpeg4Audio),
            ("clip.aac", .aac),
            ("master.flac", .flac),
            ("recording.caf", .caf),
            ("archive.ogg", .ogg),
            ("archive.oga", .ogg),
            ("call.opus", .opus),
            ("legacy.wma", .wma),
            ("surround.ac3", .ac3),
            ("surround.eac3", .ac3),
            ("phone.amr", .amr),
            ("sample.au", .au),
            ("sample.snd", .au),
        ]

        for (fileName, format) in expectedFormats {
            let url = URL(fileURLWithPath: "/tmp/\(fileName)")
            try require(AudioAssetFormat.inferred(from: url) == format, "\(fileName) inferred wrong format")
            try require(AudioAssetImporter.canImport(url), "\(fileName) was not importable")
        }

        let unknownURL = URL(fileURLWithPath: "/tmp/not-audio.xyz")
        try require(AudioAssetFormat.inferred(from: unknownURL) == .unknown, "unknown format inference failed")
        try require(!AudioAssetImporter.canImport(unknownURL), "unknown format should not be importable")
    }

    private static func verifyWAVFacadeRoundTrip(rootDirectory: URL) throws {
        let wavURL = rootDirectory.appendingPathComponent("Facade.wav")
        let buffer = makeSyntheticBuffer(url: wavURL)
        try WAVFileWriter.write(buffer, to: wavURL)

        let info = try AudioAssetImporter.inspectSynchronously(url: wavURL)
        try require(info.format == .wav, "wav facade did not report WAV format")
        try require(info.wavFileInfo?.sampleRate == buffer.sampleRate, "wav facade sample rate mismatch")
        try require(info.wavFileInfo?.channelCount == buffer.channelCount, "wav facade channel count mismatch")
        try require(info.supportsSparsePreview, "wav facade should support sparse preview")
        try require(info.supportsFileBackedEditing, "wav facade should support file-backed editing")

        let preview = try awaitValue {
            try await AudioAssetImporter.loadPreview(
                at: wavURL,
                targetBinCount: 64,
                samplesPerBin: 8
            )
        }
        try require(preview.assetInfo.format == .wav, "preview facade did not report WAV format")
        try require(!preview.waveformOverview.bins.isEmpty, "preview facade returned empty waveform")
        try require(preview.wavPreviewResult != nil, "preview facade did not bridge back to WAV preview result")

        let decoded = try awaitValue {
            try await AudioAssetImporter.loadDecodedAsset(at: wavURL)
        }
        try require(decoded.0.format == .wav, "decoded facade did not report WAV format")
        try require(decoded.1.frameCount == buffer.frameCount, "decoded facade frame count mismatch")
        try require(!decoded.2.bins.isEmpty, "decoded facade returned empty waveform")
    }

    private static func makeSyntheticBuffer(url: URL) -> DecodedAudioBuffer {
        let sampleRate = 48_000.0
        let frameCount = 4_096
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        for frameIndex in 0..<frameCount {
            let t = Double(frameIndex) / sampleRate
            left[frameIndex] = Float(sin(t * .pi * 2 * 440) * 0.42)
            right[frameIndex] = Float(sin(t * .pi * 2 * 660) * 0.32)
        }

        return DecodedAudioBuffer(
            url: url,
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [left, right]
        )
    }

    private static func awaitValue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = AudioAssetImporterSmokeResultBox<T>()

        Task {
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
            throw SmokeError.failed("async importer operation did not produce a result")
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw SmokeError.failed(message)
        }
    }
}
