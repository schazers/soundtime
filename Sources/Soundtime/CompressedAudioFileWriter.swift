import AVFoundation
import Foundation

enum CompressedAudioFileWriter {
    enum WriteError: LocalizedError {
        case unsupportedFormat
        case invalidFormat
        case couldNotCreatePCMBuffer

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                "This export format is not supported."
            case .invalidFormat:
                "The audio buffer cannot be exported in this format."
            case .couldNotCreatePCMBuffer:
                "Could not prepare audio for compressed export."
            }
        }
    }

    static func write(_ buffer: DecodedAudioBuffer, to url: URL) throws {
        let exportURL = normalizedExportURL(url)
        let settings = try outputSettings(for: exportURL, buffer: buffer)
        try FileManager.default.removeCompressedExportIfPresent(at: exportURL)

        let format = try pcmFormat(for: buffer)
        let pcmBuffer = try makePCMBuffer(from: buffer, format: format)
        let outputFile = try AVAudioFile(forWriting: exportURL, settings: settings)
        try outputFile.write(from: pcmBuffer)
    }

    static func canWrite(to url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        return ["m4a", "aac", "mp3"].contains(pathExtension)
    }

    private static func normalizedExportURL(_ url: URL) -> URL {
        url.pathExtension.isEmpty ? url.appendingPathExtension("m4a") : url
    }

    private static func outputSettings(
        for url: URL,
        buffer: DecodedAudioBuffer
    ) throws -> [String: Any] {
        guard
            buffer.sampleRate.isFinite,
            buffer.sampleRate > 0,
            buffer.channelCount > 0
        else {
            throw WriteError.invalidFormat
        }

        let pathExtension = url.pathExtension.lowercased()
        let bitRate = max(128_000, min(buffer.channelCount, 2) * 96_000)
        switch pathExtension {
        case "m4a", "aac":
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: buffer.sampleRate,
                AVNumberOfChannelsKey: buffer.channelCount,
                AVEncoderBitRateKey: bitRate,
            ]
        case "mp3":
            return [
                AVFormatIDKey: kAudioFormatMPEGLayer3,
                AVSampleRateKey: buffer.sampleRate,
                AVNumberOfChannelsKey: buffer.channelCount,
                AVEncoderBitRateKey: bitRate,
            ]
        default:
            throw WriteError.unsupportedFormat
        }
    }

    private static func pcmFormat(for buffer: DecodedAudioBuffer) throws -> AVAudioFormat {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.sampleRate,
                channels: AVAudioChannelCount(buffer.channelCount),
                interleaved: false
            )
        else {
            throw WriteError.invalidFormat
        }

        return format
    }

    private static func makePCMBuffer(
        from buffer: DecodedAudioBuffer,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard
            buffer.frameCount <= Int(AVAudioFrameCount.max),
            let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(buffer.frameCount)
            ),
            let channelData = pcmBuffer.floatChannelData
        else {
            throw WriteError.couldNotCreatePCMBuffer
        }

        pcmBuffer.frameLength = AVAudioFrameCount(buffer.frameCount)
        for channelIndex in 0..<Int(format.channelCount) {
            let destination = channelData[channelIndex]
            guard channelIndex < buffer.samplesByChannel.count else {
                for frameIndex in 0..<buffer.frameCount {
                    destination[frameIndex] = 0
                }
                continue
            }

            let source = buffer.samplesByChannel[channelIndex]
            let frameLimit = min(buffer.frameCount, source.count)
            for frameIndex in 0..<frameLimit {
                destination[frameIndex] = source[frameIndex]
            }
            if frameLimit < buffer.frameCount {
                for frameIndex in frameLimit..<buffer.frameCount {
                    destination[frameIndex] = 0
                }
            }
        }

        return pcmBuffer
    }
}

private extension FileManager {
    func removeCompressedExportIfPresent(at url: URL) throws {
        guard fileExists(atPath: url.path) else {
            return
        }

        try removeItem(at: url)
    }
}
