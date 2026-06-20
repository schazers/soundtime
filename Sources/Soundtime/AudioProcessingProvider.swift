import Foundation

enum AudioProcessingOperation: String, Sendable {
    case denoise
    case separateMusicStems
}

enum AudioProcessingRenderMode: String, Sendable {
    case perTrackSelection
    case perTrack
    case mixdownSelection
}

struct AudioProcessingInputAsset: Sendable {
    let id: UUID
    let trackID: UUID?
    let url: URL
    let displayName: String
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let timelineStartTime: TimeInterval
}

struct AudioProcessingRequest: Sendable {
    let id: UUID
    let operation: AudioProcessingOperation
    let renderMode: AudioProcessingRenderMode
    let inputAssets: [AudioProcessingInputAsset]
    let outputDirectory: URL
}

struct AudioProcessingOutputAsset: Sendable {
    let inputAssetID: UUID
    let url: URL
    let displayName: String?
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
}

struct AudioProcessingResult: Sendable {
    let requestID: UUID
    let outputAssets: [AudioProcessingOutputAsset]
    let summary: String
}

enum AudioProcessingProgressStage: String, Sendable {
    case preparing
    case uploading
    case queued
    case processing
    case downloading
    case applying
    case completed
    case canceling
}

struct AudioProcessingProgress: Sendable {
    let requestID: UUID
    let stage: AudioProcessingProgressStage
    let fractionCompleted: Double?
    let message: String
}

enum AudioProcessingCancellationResult: Equatable, Sendable {
    case canceledRemotely
    case remoteCancellationUnsupported
}

typealias AudioProcessingProgressHandler = @Sendable (AudioProcessingProgress) -> Void

protocol AudioProcessingProvider: Sendable {
    var identifier: String { get }
    var displayName: String { get }

    func process(
        _ request: AudioProcessingRequest,
        progress: @escaping AudioProcessingProgressHandler
    ) async throws -> AudioProcessingResult
    func cancel(requestID: UUID) async -> AudioProcessingCancellationResult
}

extension AudioProcessingProvider {
    func process(_ request: AudioProcessingRequest) async throws -> AudioProcessingResult {
        try await process(request, progress: { _ in })
    }

    func cancel(requestID: UUID) async -> AudioProcessingCancellationResult {
        .remoteCancellationUnsupported
    }
}

final class LocalDenoiseAudioProcessingProvider: AudioProcessingProvider, @unchecked Sendable {
    enum ProcessingError: LocalizedError {
        case unsupportedOperation
        case missingInput
        case failedToCreateOutputDirectory

        var errorDescription: String? {
            switch self {
            case .unsupportedOperation:
                "This provider only supports denoising."
            case .missingInput:
                "There is no audio asset to denoise."
            case .failedToCreateOutputDirectory:
                "Could not create the denoise output folder."
            }
        }
    }

    let identifier = "local.soundtime.denoise"
    let displayName = "Soundtime Local Denoiser"

    func process(
        _ request: AudioProcessingRequest,
        progress: @escaping AudioProcessingProgressHandler
    ) async throws -> AudioProcessingResult {
        progress(AudioProcessingProgress(
            requestID: request.id,
            stage: .preparing,
            fractionCompleted: 0.1,
            message: "preparing local denoise"
        ))
        let result = try processSynchronously(request)
        progress(AudioProcessingProgress(
            requestID: request.id,
            stage: .completed,
            fractionCompleted: 1,
            message: result.summary
        ))
        return result
    }

    func processSynchronously(_ request: AudioProcessingRequest) throws -> AudioProcessingResult {
        guard request.operation == .denoise else {
            throw ProcessingError.unsupportedOperation
        }
        guard !request.inputAssets.isEmpty else {
            throw ProcessingError.missingInput
        }

        do {
            try FileManager.default.createDirectory(
                at: request.outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ProcessingError.failedToCreateOutputDirectory
        }

        var outputAssets: [AudioProcessingOutputAsset] = []
        outputAssets.reserveCapacity(request.inputAssets.count)

        for inputAsset in request.inputAssets {
            let decodedInput = try WAVAudioDecoder.decode(url: inputAsset.url)
            let denoisedBuffer = Self.denoisedBuffer(
                decodedInput,
                outputURL: outputURL(for: inputAsset, request: request)
            )
            try WAVFileWriter.write(denoisedBuffer, to: denoisedBuffer.url)
            outputAssets.append(AudioProcessingOutputAsset(
                inputAssetID: inputAsset.id,
                url: denoisedBuffer.url,
                displayName: nil,
                sampleRate: denoisedBuffer.sampleRate,
                channelCount: denoisedBuffer.channelCount,
                frameCount: denoisedBuffer.frameCount
            ))
        }

        return AudioProcessingResult(
            requestID: request.id,
            outputAssets: outputAssets,
            summary: "denoised \(outputAssets.count) asset\(outputAssets.count == 1 ? "" : "s")"
        )
    }

    private func outputURL(
        for inputAsset: AudioProcessingInputAsset,
        request: AudioProcessingRequest
    ) -> URL {
        let safeName = inputAsset.displayName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let stem = safeName.isEmpty ? "Denoised" : safeName
        return request.outputDirectory
            .appendingPathComponent("\(stem)-Denoised-\(UUID().uuidString).wav")
            .standardizedFileURL
    }

    private static func denoisedBuffer(
        _ input: DecodedAudioBuffer,
        outputURL: URL
    ) -> DecodedAudioBuffer {
        guard input.frameCount > 0, input.channelCount > 0 else {
            return DecodedAudioBuffer(
                url: outputURL,
                sampleRate: input.sampleRate,
                channelCount: input.channelCount,
                frameCount: input.frameCount,
                samplesByChannel: input.samplesByChannel
            )
        }

        let noiseFloor = estimatedNoiseFloor(input)
        let threshold = max(noiseFloor * 2.75, 0.004)
        let fullStrength = max(threshold * 5.0, threshold + 0.002)
        let minimumGain: Float = 0.16
        let samplesByChannel = input.samplesByChannel.map { samples in
            denoisedSamples(
                samples,
                threshold: threshold,
                fullStrength: fullStrength,
                minimumGain: minimumGain
            )
        }

        return DecodedAudioBuffer(
            url: outputURL,
            sampleRate: input.sampleRate,
            channelCount: input.channelCount,
            frameCount: input.frameCount,
            samplesByChannel: samplesByChannel
        )
    }

    private static func estimatedNoiseFloor(_ input: DecodedAudioBuffer) -> Float {
        let probeFrameCount = min(
            input.frameCount,
            max(Int(input.sampleRate * 0.35), 512)
        )
        guard probeFrameCount > 0 else {
            return 0.004
        }

        var magnitudes: [Float] = []
        magnitudes.reserveCapacity(probeFrameCount * input.channelCount * 2)
        for channelSamples in input.samplesByChannel {
            let leadingEnd = min(probeFrameCount, channelSamples.count)
            if leadingEnd > 0 {
                for sample in channelSamples[0..<leadingEnd] {
                    magnitudes.append(abs(sample))
                }
            }

            let trailingStart = max(channelSamples.count - probeFrameCount, 0)
            if trailingStart < channelSamples.count {
                for sample in channelSamples[trailingStart..<channelSamples.count] {
                    magnitudes.append(abs(sample))
                }
            }
        }

        guard !magnitudes.isEmpty else {
            return 0.004
        }

        magnitudes.sort()
        let index = min(max(Int(Double(magnitudes.count - 1) * 0.60), 0), magnitudes.count - 1)
        return max(magnitudes[index], 0.000_5)
    }

    private static func denoisedSamples(
        _ samples: [Float],
        threshold: Float,
        fullStrength: Float,
        minimumGain: Float
    ) -> [Float] {
        guard !samples.isEmpty else {
            return []
        }

        var output: [Float] = []
        output.reserveCapacity(samples.count)
        var smoothedGain: Float = 1
        for sample in samples {
            let magnitude = abs(sample)
            let normalized = min(max((magnitude - threshold) / max(fullStrength - threshold, 0.000_001), 0), 1)
            let curve = normalized * normalized * (3 - 2 * normalized)
            let targetGain = minimumGain + (1 - minimumGain) * curve
            let smoothing: Float = targetGain > smoothedGain ? 0.42 : 0.035
            smoothedGain += (targetGain - smoothedGain) * smoothing
            output.append(min(max(sample * smoothedGain, -1), 1))
        }
        return output
    }
}
