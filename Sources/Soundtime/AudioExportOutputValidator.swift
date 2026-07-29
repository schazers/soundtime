import AVFoundation
import Foundation

enum AudioExportOutputValidator {
    struct Validation: Sendable, Codable, Equatable {
        let fileSizeBytes: Int64
        let frameCount: Int
        let sampleRate: Double
        let channelCount: Int
        let durationSeconds: TimeInterval
    }

    enum ValidationError: LocalizedError {
        case missingOutput(URL)
        case emptyOutput(URL)
        case unreadableOutput(URL, Error)
        case invalidChannelCount(expected: Int, actual: Int)
        case invalidSampleRate(expected: Double, actual: Double)
        case invalidDuration(expectedFrames: Int, actualFrames: Int)
        case invalidAudioSamples

        var errorDescription: String? {
            switch self {
            case let .missingOutput(url):
                return "The export output \(url.lastPathComponent) was not created."
            case let .emptyOutput(url):
                return "The export output \(url.lastPathComponent) is empty."
            case let .unreadableOutput(url, error):
                return "The export output \(url.lastPathComponent) could not be decoded: \(error.localizedDescription)"
            case let .invalidChannelCount(expected, actual):
                return "The export has \(actual) channels; \(expected) were expected."
            case let .invalidSampleRate(expected, actual):
                return "The export sample rate is \(actual) Hz; \(expected) Hz was expected."
            case let .invalidDuration(expectedFrames, actualFrames):
                return "The export contains \(actualFrames) frames; approximately \(expectedFrames) were expected."
            case .invalidAudioSamples:
                return "The export contains invalid audio samples."
            }
        }
    }

    static func validate(
        url: URL,
        format: AudioExportFormat,
        expectedFrameCount: Int,
        expectedSampleRate: Double,
        expectedChannelCount: Int
    ) throws -> Validation {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError.missingOutput(url)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw ValidationError.emptyOutput(url)
        }

        do {
            let audioFile = try AVAudioFile(forReading: url)
            let formatDescription = audioFile.processingFormat
            let frameCount = Int(audioFile.length)
            let sampleRate = formatDescription.sampleRate
            let channelCount = Int(formatDescription.channelCount)
            guard channelCount == expectedChannelCount else {
                throw ValidationError.invalidChannelCount(
                    expected: expectedChannelCount,
                    actual: channelCount
                )
            }
            guard abs(sampleRate - expectedSampleRate) <= 0.5 else {
                throw ValidationError.invalidSampleRate(
                    expected: expectedSampleRate,
                    actual: sampleRate
                )
            }

            let durationTolerance = format.isCompressed ? 4_096 : 1
            guard abs(frameCount - expectedFrameCount) <= durationTolerance else {
                throw ValidationError.invalidDuration(
                    expectedFrames: expectedFrameCount,
                    actualFrames: frameCount
                )
            }
            try decodeProbe(audioFile: audioFile, frameCount: frameCount)

            return Validation(
                fileSizeBytes: fileSize,
                frameCount: frameCount,
                sampleRate: sampleRate,
                channelCount: channelCount,
                durationSeconds: sampleRate > 0 ? Double(frameCount) / sampleRate : 0
            )
        } catch let error as ValidationError {
            throw error
        } catch {
            throw ValidationError.unreadableOutput(url, error)
        }
    }

    private static func decodeProbe(audioFile: AVAudioFile, frameCount: Int) throws {
        let probeFrameCount = AVAudioFrameCount(min(max(frameCount, 1), 4_096))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: probeFrameCount
        ) else {
            throw ValidationError.invalidAudioSamples
        }

        audioFile.framePosition = 0
        try audioFile.read(into: buffer, frameCount: probeFrameCount)
        guard buffer.frameLength > 0, samplesAreFinite(buffer) else {
            throw ValidationError.invalidAudioSamples
        }

        if frameCount > Int(probeFrameCount) {
            audioFile.framePosition = AVAudioFramePosition(
                max(frameCount - Int(probeFrameCount), 0)
            )
            buffer.frameLength = 0
            try audioFile.read(into: buffer, frameCount: probeFrameCount)
            guard buffer.frameLength > 0, samplesAreFinite(buffer) else {
                throw ValidationError.invalidAudioSamples
            }
        }
    }

    private static func samplesAreFinite(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else {
            return true
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        for channelIndex in 0..<channelCount {
            for frameIndex in 0..<frameCount where !channels[channelIndex][frameIndex].isFinite {
                return false
            }
        }
        return true
    }
}
