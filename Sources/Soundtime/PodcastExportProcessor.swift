import Foundation

struct PodcastExportSettings: Sendable {
    var targetIntegratedLUFS: Double = -16
    var truePeakCeilingDBTP: Double = -1
    var maximumGainAdjustmentDecibels: Double = 36
}

struct PodcastExportAnalysis: Sendable {
    let inputIntegratedLUFS: Double
    let inputTruePeakDBTP: Double
    let outputIntegratedLUFS: Double
    let outputTruePeakDBTP: Double
    let gainDecibels: Double
    let limiterGainReductionDecibels: Double
}

struct PodcastExportResult: Sendable {
    let buffer: DecodedAudioBuffer
    let analysis: PodcastExportAnalysis
}

enum PodcastExportProcessor {
    enum ProcessingError: LocalizedError {
        case invalidBuffer

        var errorDescription: String? {
            switch self {
            case .invalidBuffer:
                "The audio buffer cannot be mastered for export."
            }
        }
    }

    static func masteredForPodcast(
        _ buffer: DecodedAudioBuffer,
        settings: PodcastExportSettings = PodcastExportSettings()
    ) throws -> PodcastExportResult {
        guard
            buffer.sampleRate.isFinite,
            buffer.sampleRate > 0,
            buffer.channelCount > 0,
            buffer.frameCount > 0
        else {
            throw ProcessingError.invalidBuffer
        }

        let inputIntegratedLUFS = integratedLoudnessLUFS(buffer)
        let inputTruePeak = approximateTruePeakAmplitude(buffer)
        let desiredGainDecibels: Double
        if inputIntegratedLUFS <= -119 {
            desiredGainDecibels = 0
        } else {
            desiredGainDecibels = min(
                max(settings.targetIntegratedLUFS - inputIntegratedLUFS, -settings.maximumGainAdjustmentDecibels),
                settings.maximumGainAdjustmentDecibels
            )
        }

        let ceilingAmplitude = amplitude(decibels: settings.truePeakCeilingDBTP)
        let desiredGainAmplitude = amplitude(decibels: desiredGainDecibels)
        let predictedTruePeak = inputTruePeak * desiredGainAmplitude
        let limiterGainAmplitude: Double
        if predictedTruePeak > ceilingAmplitude, predictedTruePeak > 0 {
            limiterGainAmplitude = ceilingAmplitude / predictedTruePeak
        } else {
            limiterGainAmplitude = 1
        }

        let totalGainAmplitude = desiredGainAmplitude * limiterGainAmplitude
        let masteredBuffer = applyingGain(
            totalGainAmplitude,
            peakCeiling: ceilingAmplitude,
            to: buffer
        )
        let outputIntegratedLUFS = integratedLoudnessLUFS(masteredBuffer)
        let outputTruePeak = approximateTruePeakAmplitude(masteredBuffer)
        let analysis = PodcastExportAnalysis(
            inputIntegratedLUFS: inputIntegratedLUFS,
            inputTruePeakDBTP: decibels(amplitude: inputTruePeak),
            outputIntegratedLUFS: outputIntegratedLUFS,
            outputTruePeakDBTP: decibels(amplitude: outputTruePeak),
            gainDecibels: decibels(amplitude: totalGainAmplitude),
            limiterGainReductionDecibels: decibels(amplitude: limiterGainAmplitude)
        )

        return PodcastExportResult(buffer: masteredBuffer, analysis: analysis)
    }

    static func integratedLoudnessLUFS(_ buffer: DecodedAudioBuffer) -> Double {
        var squaredSampleSum = 0.0
        var sampleCount = 0
        let channelCount = max(buffer.channelCount, 0)

        for channelIndex in 0..<channelCount {
            guard channelIndex < buffer.samplesByChannel.count else {
                continue
            }

            let samples = buffer.samplesByChannel[channelIndex]
            let frameLimit = min(buffer.frameCount, samples.count)
            for frameIndex in 0..<frameLimit {
                let sample = Double(samples[frameIndex])
                squaredSampleSum += sample * sample
                sampleCount += 1
            }
        }

        guard sampleCount > 0, squaredSampleSum > 0 else {
            return -120
        }

        let meanSquare = squaredSampleSum / Double(sampleCount)
        return -0.691 + 10 * log10(meanSquare)
    }

    static func approximateTruePeakAmplitude(_ buffer: DecodedAudioBuffer) -> Double {
        var peak = 0.0

        for channelIndex in 0..<max(buffer.channelCount, 0) {
            guard channelIndex < buffer.samplesByChannel.count else {
                continue
            }

            let samples = buffer.samplesByChannel[channelIndex]
            let frameLimit = min(buffer.frameCount, samples.count)
            guard frameLimit > 0 else {
                continue
            }

            for frameIndex in 0..<frameLimit {
                peak = max(peak, abs(Double(samples[frameIndex])))
                guard frameIndex + 1 < frameLimit else {
                    continue
                }

                let y0 = Double(samples[max(frameIndex - 1, 0)])
                let y1 = Double(samples[frameIndex])
                let y2 = Double(samples[frameIndex + 1])
                let y3 = Double(samples[min(frameIndex + 2, frameLimit - 1)])
                for step in 1..<4 {
                    let interpolated = catmullRom(y0: y0, y1: y1, y2: y2, y3: y3, t: Double(step) / 4)
                    peak = max(peak, abs(interpolated))
                }
            }
        }

        return peak
    }

    static func decibels(amplitude: Double) -> Double {
        guard amplitude > 0, amplitude.isFinite else {
            return -120
        }

        return 20 * log10(amplitude)
    }

    static func amplitude(decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    private static func applyingGain(
        _ gain: Double,
        peakCeiling: Double,
        to buffer: DecodedAudioBuffer
    ) -> DecodedAudioBuffer {
        let samplesByChannel = (0..<buffer.channelCount).map { channelIndex -> [Float] in
            guard channelIndex < buffer.samplesByChannel.count else {
                return [Float](repeating: 0, count: buffer.frameCount)
            }

            let samples = buffer.samplesByChannel[channelIndex]
            var processedSamples = [Float](repeating: 0, count: buffer.frameCount)
            let frameLimit = min(buffer.frameCount, samples.count)
            for frameIndex in 0..<frameLimit {
                let gainedSample = Double(samples[frameIndex]) * gain
                processedSamples[frameIndex] = Float(min(max(gainedSample, -peakCeiling), peakCeiling))
            }
            return processedSamples
        }

        return DecodedAudioBuffer(
            url: buffer.url,
            sampleRate: buffer.sampleRate,
            channelCount: buffer.channelCount,
            frameCount: buffer.frameCount,
            samplesByChannel: samplesByChannel
        )
    }

    private static func catmullRom(
        y0: Double,
        y1: Double,
        y2: Double,
        y3: Double,
        t: Double
    ) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * y1) +
                (-y0 + y2) * t +
                (2 * y0 - 5 * y1 + 4 * y2 - y3) * t2 +
                (-y0 + 3 * y1 - 3 * y2 + y3) * t3
        )
    }
}
