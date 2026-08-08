@preconcurrency import AVFoundation
import Accelerate
import Foundation

/// Builds a truthful, full-duration first view without waiting for a compressed
/// source to be decoded into its editable proxy.
enum NativeAudioSparsePreviewBuilder {
    static let coarseBinCount = 512
    static let refinedBinCount = 2_048
    private static let sampleWindowFrames: AVAudioFrameCount = 512

    struct Result: Sendable {
        let coarseOverview: WaveformOverview
        let refinedOverview: WaveformOverview
    }

    struct SamplingPlan: Sendable {
        let refinedBinCount: Int
        let coarseRefinedIndices: [Int]
        let refinementIndices: [Int]
    }

    static func makeSamplingPlan(frameLength: Int64) -> SamplingPlan {
        let refinedCount = min(max(Int(frameLength), 1), refinedBinCount)
        let coarseCount = min(refinedCount, coarseBinCount)
        let coarseIndices = (0..<coarseCount).map { coarseIndex in
            min(
                ((2 * coarseIndex + 1) * refinedCount) / (2 * coarseCount),
                refinedCount - 1
            )
        }
        let coarseIndexSet = Set(coarseIndices)
        return SamplingPlan(
            refinedBinCount: refinedCount,
            coarseRefinedIndices: coarseIndices,
            refinementIndices: (0..<refinedCount).filter { !coarseIndexSet.contains($0) }
        )
    }

    static func build(
        sourceURL: URL,
        duration: TimeInterval,
        progress: (@Sendable (AudioImportProgress) -> Void)? = nil
    ) throws -> Result {
        let file = try AVAudioFile(
            forReading: sourceURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = file.processingFormat
        guard file.length > 0, format.channelCount > 0 else {
            throw AudioAssetImporter.ImportError.unreadableNativeAudio(
                AudioAssetFormat.inferred(from: sourceURL)
            )
        }

        let samplingPlan = makeSamplingPlan(frameLength: Int64(file.length))
        let refinedCount = samplingPlan.refinedBinCount
        let coarseCount = samplingPlan.coarseRefinedIndices.count
        var refinedBins = Array(
            repeating: WaveformOverview.Bin(
                minimumSample: 0,
                maximumSample: 0,
                rmsSample: 0,
                lowEnergy: 0,
                midEnergy: 0,
                highEnergy: 0
            ),
            count: refinedCount
        )
        var coarseBins: [WaveformOverview.Bin] = []
        coarseBins.reserveCapacity(coarseCount)

        for refinedIndex in samplingPlan.coarseRefinedIndices {
            try Task.checkCancellation()
            let bin = try sampleBin(
                refinedIndex,
                binCount: refinedCount,
                file: file,
                format: format
            )
            refinedBins[refinedIndex] = bin
            coarseBins.append(bin)
        }

        let coarseOverview = WaveformOverview(duration: duration, bins: coarseBins)
        progress?(AudioImportProgress(
            stage: .previewReady,
            completedFrames: 0,
            totalFrames: Int64(file.length),
            message: "Waveform preview ready",
            previewOverview: coarseOverview
        ))

        if refinedCount > coarseCount {
            for refinedIndex in samplingPlan.refinementIndices {
                try Task.checkCancellation()
                refinedBins[refinedIndex] = try sampleBin(
                    refinedIndex,
                    binCount: refinedCount,
                    file: file,
                    format: format
                )
            }
        }

        let refinedOverview = WaveformOverview(duration: duration, bins: refinedBins)
        progress?(AudioImportProgress(
            stage: .previewReady,
            completedFrames: 0,
            totalFrames: Int64(file.length),
            message: "Detailed waveform preview ready",
            previewOverview: refinedOverview
        ))
        return Result(
            coarseOverview: coarseOverview,
            refinedOverview: refinedOverview
        )
    }

    private static func sampleBin(
        _ index: Int,
        binCount: Int,
        file: AVAudioFile,
        format: AVAudioFormat
    ) throws -> WaveformOverview.Bin {
        let frameCount = Int64(file.length)
        let center = (Int64(index) * frameCount + frameCount / 2) / Int64(binCount)
        let halfWindow = Int64(sampleWindowFrames / 2)
        let maximumStart = max(frameCount - Int64(sampleWindowFrames), 0)
        file.framePosition = AVAudioFramePosition(min(max(center - halfWindow, 0), maximumStart))

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: sampleWindowFrames
        ) else {
            throw AudioAssetImporter.ImportError.unsupportedNativePCMLayout
        }
        try file.read(into: buffer, frameCount: sampleWindowFrames)
        guard
            buffer.frameLength > 0,
            let channelData = buffer.floatChannelData
        else {
            return WaveformOverview.Bin(
                minimumSample: 0,
                maximumSample: 0,
                rmsSample: 0,
                lowEnergy: 0,
                midEnergy: 0,
                highEnergy: 0
            )
        }

        let count = vDSP_Length(buffer.frameLength)
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        var squareSum: Float = 0
        for channel in 0..<Int(format.channelCount) {
            var channelMinimum: Float = 0
            var channelMaximum: Float = 0
            var channelSquareSum: Float = 0
            vDSP_minv(channelData[channel], 1, &channelMinimum, count)
            vDSP_maxv(channelData[channel], 1, &channelMaximum, count)
            vDSP_svesq(channelData[channel], 1, &channelSquareSum, count)
            minimum = min(minimum, channelMinimum)
            maximum = max(maximum, channelMaximum)
            squareSum += channelSquareSum
        }
        let sampleCount = max(Float(buffer.frameLength) * Float(format.channelCount), 1)
        let rms = sqrt(max(squareSum / sampleCount, 0))
        return WaveformOverview.Bin(
            minimumSample: minimum.isFinite ? minimum : 0,
            maximumSample: maximum.isFinite ? maximum : 0,
            rmsSample: rms,
            lowEnergy: rms,
            midEnergy: rms,
            highEnergy: rms
        )
    }
}
