import Foundation

struct LiveRecordingWaveformAccumulator {
    private(set) var bins: [WaveformOverview.Bin] = []
    private var currentAccumulator = WaveformBinAccumulator()
    private var framesInCurrentBin = 0
    private(set) var totalFrameCount = 0
    private let framesPerBin: Int

    init(sampleRate: Double) {
        let framesPerSecond = max(sampleRate, 1)
        framesPerBin = max(Int((framesPerSecond / 180).rounded()), 96)
    }

    mutating func append(samplesByChannel: [[Float]], frameCount: Int) {
        guard frameCount > 0, !samplesByChannel.isEmpty else {
            return
        }

        for frameIndex in 0..<frameCount {
            var mixedSample: Float = 0
            var mixedChannelCount: Float = 0
            for samples in samplesByChannel where frameIndex < samples.count {
                mixedSample += samples[frameIndex]
                mixedChannelCount += 1
            }

            guard mixedChannelCount > 0 else {
                continue
            }

            currentAccumulator.addSample(mixedSample / mixedChannelCount)
            framesInCurrentBin += 1
            totalFrameCount += 1

            if framesInCurrentBin >= framesPerBin {
                bins.append(currentAccumulator.makeBin())
                currentAccumulator = WaveformBinAccumulator()
                framesInCurrentBin = 0
            }
        }
    }

    func makeOverview(sampleRate: Double) -> WaveformOverview {
        var overviewBins = bins
        if framesInCurrentBin > 0 {
            overviewBins.append(currentAccumulator.makeBin())
        }

        let duration = sampleRate > 0 ? Double(totalFrameCount) / sampleRate : 0
        return WaveformOverview(duration: duration, bins: overviewBins)
    }
}
