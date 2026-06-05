import Foundation

enum WaveformOverviewBuilder {
    static let defaultTargetBinCount = 1_048_576

    static func build(
        from buffer: DecodedAudioBuffer,
        targetBinCount: Int = defaultTargetBinCount
    ) -> WaveformOverview {
        guard buffer.frameCount > 0, buffer.channelCount > 0 else {
            return WaveformOverview(duration: buffer.duration, bins: [])
        }

        let binCount = min(max(targetBinCount, 1), buffer.frameCount)
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount)

        for binIndex in 0..<binCount {
            let startFrame = binIndex * buffer.frameCount / binCount
            let endFrame = max((binIndex + 1) * buffer.frameCount / binCount, startFrame + 1)
            var minimumSample: Float = 1
            var maximumSample: Float = -1

            for channelSamples in buffer.samplesByChannel {
                guard startFrame < channelSamples.count else {
                    continue
                }

                let clampedEndFrame = min(endFrame, channelSamples.count)
                for frameIndex in startFrame..<clampedEndFrame {
                    let sample = channelSamples[frameIndex]
                    minimumSample = min(minimumSample, sample)
                    maximumSample = max(maximumSample, sample)
                }
            }

            if minimumSample > maximumSample {
                minimumSample = 0
                maximumSample = 0
            }

            bins.append(WaveformOverview.Bin(
                minimumSample: minimumSample,
                maximumSample: maximumSample
            ))
        }

        return WaveformOverview(duration: buffer.duration, bins: bins)
    }
}
