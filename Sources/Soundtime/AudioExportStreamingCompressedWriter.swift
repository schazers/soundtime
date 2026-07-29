import AVFoundation
import Foundation

final class AudioExportStreamingCompressedWriter: AudioExportSampleWriter, @unchecked Sendable {
    enum WriterError: LocalizedError {
        case invalidFormat
        case unsupportedFormat(AudioExportFormat)
        case noSamplesWritten
        case missingAudioBuffer
        case writeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "The compressed export audio format is invalid."
            case let .unsupportedFormat(format):
                return "\(format.displayName) export is not supported by the current system encoder."
            case .noSamplesWritten:
                return "No audio samples were rendered."
            case .missingAudioBuffer:
                return "The compressed export buffer could not be created."
            case let .writeFailed(error):
                return "Compressed export write failed: \(error.localizedDescription)"
            }
        }
    }

    let url: URL

    private let format: AudioExportFormat
    private let channelCount: Int
    private let inputFormat: AVAudioFormat
    private var audioFile: AVAudioFile?
    private var frameCount = 0
    private var isFinished = false

    init(
        url: URL,
        format: AudioExportFormat,
        sampleRate: Double,
        channelCount: Int,
        bitRate: Int
    ) throws {
        guard
            format.isCompressed,
            sampleRate.isFinite,
            sampleRate > 0,
            channelCount > 0,
            channelCount <= Int(UInt32.max),
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            )
        else {
            throw WriterError.invalidFormat
        }

        self.format = format
        self.url = url.pathExtension.isEmpty ? url.appendingPathExtension(format.fileExtension) : url
        self.channelCount = channelCount
        self.inputFormat = inputFormat

        guard !FileManager.default.fileExists(atPath: self.url.path) else {
            throw WriterError.writeFailed(
                CocoaError(.fileWriteFileExists)
            )
        }
        do {
            audioFile = try AVAudioFile(
                forWriting: self.url,
                settings: Self.settings(
                    format: format,
                    sampleRate: sampleRate,
                    channelCount: channelCount,
                    bitRate: bitRate
                ),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw WriterError.writeFailed(error)
        }
    }

    func append(samplesByChannel: [[Float]], frameCount chunkFrameCount: Int) throws {
        guard !isFinished else {
            throw WriterError.invalidFormat
        }
        guard chunkFrameCount > 0, !samplesByChannel.isEmpty else {
            return
        }

        try Task.checkCancellation()
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(chunkFrameCount)
        ) else {
            throw WriterError.missingAudioBuffer
        }
        buffer.frameLength = AVAudioFrameCount(chunkFrameCount)

        guard let channelData = buffer.floatChannelData else {
            throw WriterError.missingAudioBuffer
        }

        for channelIndex in 0..<channelCount {
            let sourceChannel = channelIndex < samplesByChannel.count ? channelIndex : samplesByChannel.count - 1
            let sourceSamples = samplesByChannel[sourceChannel]
            let destination = channelData[channelIndex]
            for frameIndex in 0..<chunkFrameCount {
                let sample = frameIndex < sourceSamples.count ? sourceSamples[frameIndex] : 0
                destination[frameIndex] = Self.clampAudioSample(sample)
            }
        }

        do {
            guard let audioFile else {
                throw WriterError.invalidFormat
            }
            try audioFile.write(from: buffer)
            frameCount += chunkFrameCount
        } catch {
            throw WriterError.writeFailed(error)
        }
    }

    func finish() throws -> URL {
        guard !isFinished else {
            return url
        }
        guard frameCount > 0 else {
            cancel()
            throw WriterError.noSamplesWritten
        }

        audioFile = nil
        isFinished = true
        return url
    }

    func cancel() {
        guard !isFinished else {
            return
        }
        audioFile = nil
        try? FileManager.default.removeItem(at: url)
        isFinished = true
    }

    private static func settings(
        format: AudioExportFormat,
        sampleRate: Double,
        channelCount: Int,
        bitRate: Int
    ) throws -> [String: Any] {
        let formatID: AudioFormatID
        switch format {
        case .wav:
            throw WriterError.unsupportedFormat(format)
        case .m4a, .aac:
            formatID = kAudioFormatMPEG4AAC
        case .mp3:
            formatID = kAudioFormatMPEGLayer3
        }

        return [
            AVFormatIDKey: formatID,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
        ]
    }

    private static func clampAudioSample(_ sample: Float) -> Float {
        min(max(sample, -1), 1)
    }
}
