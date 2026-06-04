import Foundation

struct AudioEditTimeline: Sendable {
    private static let spliceFadeDuration: TimeInterval = 0.005

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

    mutating func trim(to trimRange: TimelineTrimRange) -> Int {
        let originalFrameCount = frameCount
        let keepStartFrame = Int((trimRange.startProgress * Float(originalFrameCount)).rounded(.down))
        let keepEndFrame = Int((trimRange.endProgress * Float(originalFrameCount)).rounded(.up))

        guard
            keepStartFrame < keepEndFrame,
            keepStartFrame > 0 || keepEndFrame < originalFrameCount
        else {
            return 0
        }

        let trailingDeletedFrameCount = deleteFrames(in: keepEndFrame..<originalFrameCount)
        let leadingDeletedFrameCount = deleteFrames(in: 0..<keepStartFrame)
        return trailingDeletedFrameCount + leadingDeletedFrameCount
    }

    func render() -> DecodedAudioBuffer {
        let renderedFrameCount = frameCount
        var samplesByChannel = (0..<sourceBuffer.channelCount).map { _ in
            [Float]()
        }

        for channelIndex in samplesByChannel.indices {
            samplesByChannel[channelIndex].reserveCapacity(renderedFrameCount)
        }

        var isFirstRenderedSegment = true
        let spliceFadeFrameCount = max(Int(sourceBuffer.sampleRate * Self.spliceFadeDuration), 1)

        for segment in segments where segment.frameCount > 0 {
            for channelIndex in samplesByChannel.indices {
                let sourceSamples = sourceBuffer.samplesByChannel[channelIndex]
                let sourceEndFrame = min(segment.sourceEndFrame, sourceSamples.count)
                guard segment.sourceStartFrame < sourceEndFrame else {
                    continue
                }

                if !isFirstRenderedSegment {
                    applySpliceFadeOut(
                        outputSamples: &samplesByChannel[channelIndex],
                        fadeFrameCount: spliceFadeFrameCount
                    )
                }

                appendSegmentSamples(
                    to: &samplesByChannel[channelIndex],
                    sourceSamples: sourceSamples,
                    sourceStartFrame: segment.sourceStartFrame,
                    sourceEndFrame: sourceEndFrame,
                    fadeInFrameCount: isFirstRenderedSegment ? 0 : spliceFadeFrameCount
                )
            }

            isFirstRenderedSegment = false
        }

        return DecodedAudioBuffer(
            url: sourceBuffer.url,
            sampleRate: sourceBuffer.sampleRate,
            channelCount: sourceBuffer.channelCount,
            frameCount: renderedFrameCount,
            samplesByChannel: samplesByChannel
        )
    }

    private func applySpliceFadeOut(
        outputSamples: inout [Float],
        fadeFrameCount: Int
    ) {
        let fadeFrameCount = min(fadeFrameCount, outputSamples.count)
        guard fadeFrameCount > 1 else {
            return
        }

        let outputStartIndex = outputSamples.count - fadeFrameCount
        for offset in 0..<fadeFrameCount {
            let progress = Float(offset) / Float(fadeFrameCount - 1)
            let outputIndex = outputStartIndex + offset
            outputSamples[outputIndex] *= 1 - smoothstep(progress)
        }
    }

    private func appendSegmentSamples(
        to outputSamples: inout [Float],
        sourceSamples: [Float],
        sourceStartFrame: Int,
        sourceEndFrame: Int,
        fadeInFrameCount: Int
    ) {
        guard sourceStartFrame < sourceEndFrame else {
            return
        }

        let fadeFrameCount = min(fadeInFrameCount, sourceEndFrame - sourceStartFrame)
        guard fadeFrameCount > 1 else {
            outputSamples.append(contentsOf: sourceSamples[sourceStartFrame..<sourceEndFrame])
            return
        }

        for offset in 0..<fadeFrameCount {
            let progress = Float(offset) / Float(fadeFrameCount - 1)
            outputSamples.append(sourceSamples[sourceStartFrame + offset] * smoothstep(progress))
        }

        let remainingStartFrame = sourceStartFrame + fadeFrameCount
        if remainingStartFrame < sourceEndFrame {
            outputSamples.append(contentsOf: sourceSamples[remainingStartFrame..<sourceEndFrame])
        }
    }

    private func smoothstep(_ progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        return clampedProgress * clampedProgress * (3 - 2 * clampedProgress)
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
