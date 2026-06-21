import AVFoundation
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
        try verifyNativeEditableProxyImport(rootDirectory: rootDirectory)

        let checks = [
            "common audio format recognition",
            "wav importer facade preview/decode round trip",
            "native audio decode to editable wav proxy",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "audio-asset-importer-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: ["nonWAVDecode": "native-avfoundation-proxy"],
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
        }

        let importableFileNames = [
            "voice.wav",
            "voice.wave",
            "music.aiff",
            "music.aif",
            "music.aifc",
            "episode.mp3",
            "mix.m4a",
            "movie.mp4",
            "lossless.alac",
            "clip.aac",
            "master.flac",
            "recording.caf",
            "surround.ac3",
            "surround.eac3",
            "phone.amr",
            "sample.au",
            "sample.snd",
        ]
        for fileName in importableFileNames {
            try require(
                AudioAssetImporter.canImport(URL(fileURLWithPath: "/tmp/\(fileName)")),
                "\(fileName) was not importable"
            )
        }

        let recognizedButUnsupportedFileNames = [
            "archive.ogg",
            "archive.oga",
            "call.opus",
            "legacy.wma",
        ]
        for fileName in recognizedButUnsupportedFileNames {
            try require(
                !AudioAssetImporter.canImport(URL(fileURLWithPath: "/tmp/\(fileName)")),
                "\(fileName) should be recognized but not accepted by the native importer"
            )
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

    private static func verifyNativeEditableProxyImport(rootDirectory: URL) throws {
        let aiffURL = rootDirectory.appendingPathComponent("NativeImport.aiff")
        let sourceBuffer = makeSyntheticBuffer(url: aiffURL, sampleRate: 44_100, frameCount: 8_192)
        try writeNativeAudioFixture(sourceBuffer, to: aiffURL)

        let info = try AudioAssetImporter.inspectSynchronously(url: aiffURL)
        try require(info.format == .aiff, "native importer did not report AIFF format")
        try require(info.wavFileInfo == nil, "native importer should not report WAV file info for AIFF")
        try require(info.sampleRate == sourceBuffer.sampleRate, "native importer sample rate mismatch")
        try require(info.channelCount == sourceBuffer.channelCount, "native importer channel count mismatch")
        try require(info.requiresEditableProxy, "native importer should require an editable proxy")

        let decoded = try awaitValue {
            try await AudioAssetImporter.loadDecodedAsset(at: aiffURL)
        }
        try require(decoded.0.format == .aiff, "native decoded asset did not report AIFF format")
        try require(decoded.1.sampleRate == sourceBuffer.sampleRate, "native decoded sample rate mismatch")
        try require(decoded.1.frameCount == sourceBuffer.frameCount, "native decoded frame count mismatch")
        try require(!decoded.2.bins.isEmpty, "native decoded waveform was empty")

        let proxyResult = try awaitValue {
            try await AudioAssetImporter.importEditableAsset(at: aiffURL)
        }
        try require(!proxyResult.usesOriginalFile, "native import should create a proxy")
        try require(proxyResult.proxyURL.pathExtension.lowercased() == "wav", "native import proxy should be a WAV")
        try require(WAVAudioDecoder.canDecode(proxyResult.proxyURL), "native import proxy was not decodable as WAV")
        try require(
            abs(proxyResult.proxyFileInfo.sampleRate - AudioAssetImporter.editableProxySampleRate) < 0.5,
            "native import proxy did not normalize sample rate"
        )
        try require(proxyResult.decodedAudioBuffer.url == proxyResult.proxyURL, "native import proxy buffer URL mismatch")
        try require(proxyResult.decodedAudioBuffer.frameCount > 0, "native import proxy buffer was empty")
    }

    private static func makeSyntheticBuffer(
        url: URL,
        sampleRate: Double = 48_000,
        frameCount: Int = 4_096
    ) -> DecodedAudioBuffer {
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

    private static func writeNativeAudioFixture(_ buffer: DecodedAudioBuffer, to url: URL) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.sampleRate,
                channels: AVAudioChannelCount(buffer.channelCount),
                interleaved: false
            ),
            let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(buffer.frameCount)
            )
        else {
            throw SmokeError.failed("could not create native fixture audio buffer")
        }

        pcmBuffer.frameLength = AVAudioFrameCount(buffer.frameCount)
        guard let floatChannelData = pcmBuffer.floatChannelData else {
            throw SmokeError.failed("native fixture buffer did not expose float channel data")
        }

        for channelIndex in 0..<buffer.channelCount {
            let source = channelIndex < buffer.samplesByChannel.count ?
                buffer.samplesByChannel[channelIndex] :
                []
            for frameIndex in 0..<buffer.frameCount {
                floatChannelData[channelIndex][frameIndex] = frameIndex < source.count ? source[frameIndex] : 0
            }
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: pcmBuffer)
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
