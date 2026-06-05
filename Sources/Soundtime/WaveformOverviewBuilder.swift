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
            if binIndex.isMultiple(of: 512) {
                try? ImportWorkBudget.shared.waitIfPlaybackActive()
            }

            let startFrame = binIndex * buffer.frameCount / binCount
            let endFrame = max((binIndex + 1) * buffer.frameCount / binCount, startFrame + 1)
            var accumulator = WaveformBinAccumulator()

            for channelSamples in buffer.samplesByChannel {
                guard startFrame < channelSamples.count else {
                    continue
                }

                let clampedEndFrame = min(endFrame, channelSamples.count)
                for frameIndex in startFrame..<clampedEndFrame {
                    accumulator.addSample(channelSamples[frameIndex])
                }
            }

            bins.append(accumulator.makeBin())
        }

        return WaveformOverview(duration: buffer.duration, bins: bins)
    }
}
