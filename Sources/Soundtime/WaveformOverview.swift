import Foundation

struct WaveformOverview: Sendable {
    struct Bin: Sendable {
        let minimumSample: Float
        let maximumSample: Float
        let rmsSample: Float
        let lowEnergy: Float
        let midEnergy: Float
        let highEnergy: Float

        init(
            minimumSample: Float,
            maximumSample: Float,
            rmsSample: Float? = nil,
            lowEnergy: Float = 0.34,
            midEnergy: Float = 0.33,
            highEnergy: Float = 0.33
        ) {
            self.minimumSample = minimumSample
            self.maximumSample = maximumSample
            self.rmsSample = min(max(rmsSample ?? Self.estimatedRMS(minimum: minimumSample, maximum: maximumSample), 0), 1)

            let lowEnergy = max(lowEnergy, 0)
            let midEnergy = max(midEnergy, 0)
            let highEnergy = max(highEnergy, 0)
            let totalEnergy = lowEnergy + midEnergy + highEnergy
            if totalEnergy > 0 {
                self.lowEnergy = lowEnergy / totalEnergy
                self.midEnergy = midEnergy / totalEnergy
                self.highEnergy = highEnergy / totalEnergy
            } else {
                self.lowEnergy = 0.34
                self.midEnergy = 0.33
                self.highEnergy = 0.33
            }
        }

        var peakMagnitude: Float {
            min(max(max(abs(minimumSample), abs(maximumSample)), 0), 1)
        }

        func scaled(by gain: Float) -> Bin {
            let clampedGain = max(gain, 0)
            return Bin(
                minimumSample: min(max(minimumSample * clampedGain, -1), 1),
                maximumSample: min(max(maximumSample * clampedGain, -1), 1),
                rmsSample: min(max(rmsSample * clampedGain, 0), 1),
                lowEnergy: lowEnergy,
                midEnergy: midEnergy,
                highEnergy: highEnergy
            )
        }

        private static func estimatedRMS(minimum: Float, maximum: Float) -> Float {
            let peak = max(abs(minimum), abs(maximum))
            return min(max(peak * 0.62, 0), 1)
        }
    }

    let duration: TimeInterval
    let bins: [Bin]

    var isEmpty: Bool {
        bins.isEmpty
    }
}

struct WaveformBinAccumulator {
    private var minimumSample = Float.greatestFiniteMagnitude
    private var maximumSample = -Float.greatestFiniteMagnitude
    private var rmsSquareSum: Float = 0
    private var lowEnergySum: Float = 0
    private var midEnergySum: Float = 0
    private var highEnergySum: Float = 0
    private var sampleCount: Float = 0
    private var previousSample: Float?
    private var lowState: Float = 0

    mutating func addSample(_ sample: Float) {
        let sample = min(max(sample, -1), 1)
        minimumSample = min(minimumSample, sample)
        maximumSample = max(maximumSample, sample)
        rmsSquareSum += sample * sample

        lowState += (sample - lowState) * 0.08
        let previousSample = previousSample ?? sample
        let highComponent = sample - previousSample
        let midComponent = sample - lowState - highComponent * 0.25

        lowEnergySum += lowState * lowState
        midEnergySum += midComponent * midComponent
        highEnergySum += highComponent * highComponent * 0.7

        self.previousSample = sample
        sampleCount += 1
    }

    mutating func addBin(_ bin: WaveformOverview.Bin) {
        minimumSample = min(minimumSample, bin.minimumSample)
        maximumSample = max(maximumSample, bin.maximumSample)
        rmsSquareSum += bin.rmsSample * bin.rmsSample

        let weight = max(bin.rmsSample * bin.rmsSample, 0.000_001)
        lowEnergySum += bin.lowEnergy * weight
        midEnergySum += bin.midEnergy * weight
        highEnergySum += bin.highEnergy * weight

        sampleCount += 1
    }

    func makeBin() -> WaveformOverview.Bin {
        guard sampleCount > 0 else {
            return WaveformOverview.Bin(minimumSample: 0, maximumSample: 0, rmsSample: 0)
        }

        let minimumSample = minimumSample == Float.greatestFiniteMagnitude ? 0 : minimumSample
        let maximumSample = maximumSample == -Float.greatestFiniteMagnitude ? 0 : maximumSample
        return WaveformOverview.Bin(
            minimumSample: minimumSample,
            maximumSample: maximumSample,
            rmsSample: sqrt(max(rmsSquareSum / sampleCount, 0)),
            lowEnergy: lowEnergySum,
            midEnergy: midEnergySum,
            highEnergy: highEnergySum
        )
    }
}
