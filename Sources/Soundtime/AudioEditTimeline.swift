import Foundation

struct AudioEditTimeline: Sendable {
    private struct Segment: Sendable {
        let sourceStartFrame: Int
        let frameCount: Int

        var sourceEndFrame: Int {
            sourceStartFrame + frameCount
        }
    }

    private let sourceBuffer: DecodedAudioBuffer
    private var segments: [Segment]

    init(sourceBuffer: DecodedAudioBuffer) {
        self.sourceBuffer = sourceBuffer
        if sourceBuffer.frameCount > 0 {
            segments = [Segment(sourceStartFrame: 0, frameCount: sourceBuffer.frameCount)]
        } else {
            segments = []
        }
    }

    var frameCount: Int {
        segments.reduce(0) { total, segment in
            total + segment.frameCount
        }
    }

    var duration: TimeInterval {
        guard sourceBuffer.sampleRate > 0 else {
            return 0
        }

        return Double(frameCount) / sourceBuffer.sampleRate
    }

    mutating func delete(_ selection: TimelineSelection) -> Int {
        let deleteStartFrame = Int((selection.startProgress * Float(frameCount)).rounded(.down))
        let deleteEndFrame = Int((selection.endProgress * Float(frameCount)).rounded(.up))
        return deleteFrames(in: deleteStartFrame..<deleteEndFrame)
    }

    func render() -> DecodedAudioBuffer {
        let renderedFrameCount = frameCount
        var samplesByChannel = (0..<sourceBuffer.channelCount).map { _ in
            [Float]()
        }

        for channelIndex in samplesByChannel.indices {
            samplesByChannel[channelIndex].reserveCapacity(renderedFrameCount)
        }

        for segment in segments where segment.frameCount > 0 {
            for channelIndex in samplesByChannel.indices {
                let sourceSamples = sourceBuffer.samplesByChannel[channelIndex]
                let sourceEndFrame = min(segment.sourceEndFrame, sourceSamples.count)
                guard segment.sourceStartFrame < sourceEndFrame else {
                    continue
                }

                samplesByChannel[channelIndex].append(contentsOf: sourceSamples[segment.sourceStartFrame..<sourceEndFrame])
            }
        }

        return DecodedAudioBuffer(
            url: sourceBuffer.url,
            sampleRate: sourceBuffer.sampleRate,
            channelCount: sourceBuffer.channelCount,
            frameCount: renderedFrameCount,
            samplesByChannel: samplesByChannel
        )
    }

    private mutating func deleteFrames(in frameRange: Range<Int>) -> Int {
        guard
            frameRange.lowerBound < frameRange.upperBound,
            frameRange.lowerBound < frameCount,
            frameRange.upperBound > 0
        else {
            return 0
        }

        let clampedRange = max(frameRange.lowerBound, 0)..<min(frameRange.upperBound, frameCount)
        var nextSegments: [Segment] = []
        var timelineFrame = 0

        for segment in segments {
            let segmentStartFrame = timelineFrame
            let segmentEndFrame = timelineFrame + segment.frameCount
            timelineFrame = segmentEndFrame

            let overlapStartFrame = max(segmentStartFrame, clampedRange.lowerBound)
            let overlapEndFrame = min(segmentEndFrame, clampedRange.upperBound)

            guard overlapStartFrame < overlapEndFrame else {
                nextSegments.append(segment)
                continue
            }

            let beforeCount = overlapStartFrame - segmentStartFrame
            if beforeCount > 0 {
                nextSegments.append(Segment(
                    sourceStartFrame: segment.sourceStartFrame,
                    frameCount: beforeCount
                ))
            }

            let afterCount = segmentEndFrame - overlapEndFrame
            if afterCount > 0 {
                nextSegments.append(Segment(
                    sourceStartFrame: segment.sourceStartFrame + (overlapEndFrame - segmentStartFrame),
                    frameCount: afterCount
                ))
            }
        }

        let deletedFrameCount = frameCount - nextSegments.reduce(0) { total, segment in
            total + segment.frameCount
        }

        segments = nextSegments
        return deletedFrameCount
    }
}
