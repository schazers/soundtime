import Foundation

struct AudioZeroCrossingIndex: Sendable {
    private static let zeroEpsilon: Float = 0.000_001

    let frameCount: Int
    private let crossings: [Int]

    init(frameCount: Int, crossings: [Int]) {
        self.frameCount = frameCount
        self.crossings = crossings
    }

    var isEmpty: Bool {
        crossings.isEmpty
    }

    func nearestFrame(to frame: Int) -> Int {
        guard !crossings.isEmpty else {
            return min(max(frame, 0), frameCount)
        }

        let clampedFrame = min(max(frame, 0), frameCount)
        guard clampedFrame > 0, clampedFrame < frameCount else {
            return clampedFrame
        }

        let insertionIndex = crossings.lowerBound(for: clampedFrame)
        var nearestFrame = crossings[min(insertionIndex, crossings.count - 1)]

        if insertionIndex > 0 {
            let previousFrame = crossings[insertionIndex - 1]
            if abs(previousFrame - clampedFrame) <= abs(nearestFrame - clampedFrame) {
                nearestFrame = previousFrame
            }
        }

        return nearestFrame
    }

    static func build(from buffer: DecodedAudioBuffer) -> AudioZeroCrossingIndex {
        guard buffer.frameCount > 0, buffer.channelCount > 0 else {
            return AudioZeroCrossingIndex(frameCount: buffer.frameCount, crossings: [])
        }

        var crossings: [Int] = []
        crossings.reserveCapacity(max(buffer.frameCount / 128, 8))
        appendCrossing(0, to: &crossings)

        var previousSample = mixedSample(in: buffer, at: 0)

        for frameIndex in 1..<buffer.frameCount {
            if frameIndex.isMultiple(of: 8_192) {
                try? ImportWorkBudget.shared.waitIfPlaybackActive(.zeroCrossingAnalysis)
            }

            let sample = mixedSample(in: buffer, at: frameIndex)
            if let crossingFrame = crossingFrame(
                previousSample: previousSample,
                sample: sample,
                previousFrame: frameIndex - 1,
                frame: frameIndex
            ) {
                appendCrossing(crossingFrame, to: &crossings)
            }

            previousSample = sample
        }

        appendCrossing(buffer.frameCount, to: &crossings)
        return AudioZeroCrossingIndex(frameCount: buffer.frameCount, crossings: crossings)
    }

    static func nearestFrame(
        to frame: Int,
        in samples: (Int) throws -> Float,
        frameCount: Int,
        searchRadius: Int
    ) throws -> Int {
        let clampedFrame = min(max(frame, 0), frameCount)
        guard clampedFrame > 0, clampedFrame < frameCount else {
            return clampedFrame
        }

        let startFrame = max(clampedFrame - searchRadius, 1)
        let endFrame = min(clampedFrame + searchRadius, frameCount - 1)
        guard startFrame <= endFrame else {
            return clampedFrame
        }

        var nearestFrame: Int?
        var nearestDistance = Int.max
        var previousFrame = startFrame - 1
        var previousSample = try samples(previousFrame)

        for frameIndex in startFrame...endFrame {
            let sample = try samples(frameIndex)
            if let crossingFrame = crossingFrame(
                previousSample: previousSample,
                sample: sample,
                previousFrame: previousFrame,
                frame: frameIndex
            ) {
                let distance = abs(crossingFrame - clampedFrame)
                if distance < nearestDistance {
                    nearestFrame = crossingFrame
                    nearestDistance = distance
                }
            }

            previousFrame = frameIndex
            previousSample = sample
        }

        return nearestFrame ?? clampedFrame
    }

    static func crossingFrame(
        previousSample: Float,
        sample: Float,
        previousFrame: Int,
        frame: Int
    ) -> Int? {
        let previousIsZero = abs(previousSample) <= zeroEpsilon
        let sampleIsZero = abs(sample) <= zeroEpsilon

        if sampleIsZero {
            return frame
        }
        if previousIsZero {
            return previousFrame
        }

        let crossesZero = previousSample < 0 && sample > 0 || previousSample > 0 && sample < 0
        guard crossesZero else {
            return nil
        }

        return abs(previousSample) <= abs(sample) ? previousFrame : frame
    }

    private static func appendCrossing(_ frame: Int, to crossings: inout [Int]) {
        guard crossings.last != frame else {
            return
        }

        crossings.append(frame)
    }

    private static func mixedSample(in buffer: DecodedAudioBuffer, at frameIndex: Int) -> Float {
        var sample: Float = 0
        var channelSampleCount: Float = 0

        for channelSamples in buffer.samplesByChannel {
            guard frameIndex < channelSamples.count else {
                continue
            }

            sample += channelSamples[frameIndex]
            channelSampleCount += 1
        }

        guard channelSampleCount > 0 else {
            return 0
        }

        return sample / channelSampleCount
    }
}

private extension Array where Element == Int {
    func lowerBound(for value: Int) -> Int {
        var low = 0
        var high = count

        while low < high {
            let mid = low + (high - low) / 2
            if self[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }

        return low
    }
}
