import Foundation

struct AudioEditTimeline: Sendable {
    private static let spliceFadeDuration: TimeInterval = 0.005

    private struct Segment: Sendable {
        let sourceStartFrame: Int
        let frameCount: Int
        let gain: Float

        var sourceEndFrame: Int {
            sourceStartFrame + frameCount
        }
    }

    private let sourceBuffer: DecodedAudioBuffer
    private var segments: [Segment]

    init(sourceBuffer: DecodedAudioBuffer) {
        self.sourceBuffer = sourceBuffer
        if sourceBuffer.frameCount > 0 {
            segments = [Segment(sourceStartFrame: 0, frameCount: sourceBuffer.frameCount, gain: 1)]
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

    func frameRange(for selection: TimelineSelection) -> Range<Int> {
        let startFrame = Int((selection.startProgress * Double(frameCount)).rounded(.down))
        let endFrame = Int((selection.endProgress * Double(frameCount)).rounded(.up))
        return max(startFrame, 0)..<min(max(endFrame, startFrame), frameCount)
    }

    mutating func delete(_ selection: TimelineSelection) -> Int {
        deleteFrames(in: frameRange(for: selection))
    }

    mutating func applyGain(_ gain: Float, to selection: TimelineSelection) -> Int {
        applyGain(gain, toFramesIn: frameRange(for: selection))
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
        render(frameRange: 0..<frameCount)
    }

    func render(selection: TimelineSelection) -> DecodedAudioBuffer {
        render(frameRange: frameRange(for: selection))
    }

    func render(frameRange requestedFrameRange: Range<Int>) -> DecodedAudioBuffer {
        let renderedFrameCount = frameCount
        let frameRange = max(requestedFrameRange.lowerBound, 0)..<min(requestedFrameRange.upperBound, renderedFrameCount)
        var samplesByChannel = (0..<sourceBuffer.channelCount).map { _ in
            [Float]()
        }

        for channelIndex in samplesByChannel.indices {
            samplesByChannel[channelIndex].reserveCapacity(max(frameRange.count, 0))
        }

        var isFirstRenderedSegment = true
        let spliceFadeFrameCount = max(Int(sourceBuffer.sampleRate * Self.spliceFadeDuration), 1)
        var timelineFrame = 0

        for segment in segments where segment.frameCount > 0 {
            let segmentTimelineStart = timelineFrame
            let segmentTimelineEnd = timelineFrame + segment.frameCount
            timelineFrame = segmentTimelineEnd
            let renderStart = max(segmentTimelineStart, frameRange.lowerBound)
            let renderEnd = min(segmentTimelineEnd, frameRange.upperBound)
            guard renderStart < renderEnd else {
                continue
            }

            let segmentOffset = renderStart - segmentTimelineStart
            let sourceStartFrame = segment.sourceStartFrame + segmentOffset
            let sourceEndFrame = sourceStartFrame + (renderEnd - renderStart)

            for channelIndex in samplesByChannel.indices {
                let sourceSamples = sourceBuffer.samplesByChannel[channelIndex]
                let boundedSourceEndFrame = min(sourceEndFrame, sourceSamples.count)
                guard sourceStartFrame < boundedSourceEndFrame else {
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
                    sourceStartFrame: sourceStartFrame,
                    sourceEndFrame: boundedSourceEndFrame,
                    fadeInFrameCount: isFirstRenderedSegment ? 0 : spliceFadeFrameCount,
                    gain: segment.gain
                )
            }

            isFirstRenderedSegment = false
        }

        return DecodedAudioBuffer(
            url: sourceBuffer.url,
            sampleRate: sourceBuffer.sampleRate,
            channelCount: sourceBuffer.channelCount,
            frameCount: frameRange.count,
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
        fadeInFrameCount: Int,
        gain: Float
    ) {
        guard sourceStartFrame < sourceEndFrame else {
            return
        }

        let fadeFrameCount = min(fadeInFrameCount, sourceEndFrame - sourceStartFrame)
        guard fadeFrameCount > 1 else {
            if gain == 1 {
                outputSamples.append(contentsOf: sourceSamples[sourceStartFrame..<sourceEndFrame])
            } else {
                for frameIndex in sourceStartFrame..<sourceEndFrame {
                    outputSamples.append(clampAudioSample(sourceSamples[frameIndex] * gain))
                }
            }
            return
        }

        for offset in 0..<fadeFrameCount {
            let progress = Float(offset) / Float(fadeFrameCount - 1)
            outputSamples.append(clampAudioSample(sourceSamples[sourceStartFrame + offset] * gain) * smoothstep(progress))
        }

        let remainingStartFrame = sourceStartFrame + fadeFrameCount
        if remainingStartFrame < sourceEndFrame {
            if gain == 1 {
                outputSamples.append(contentsOf: sourceSamples[remainingStartFrame..<sourceEndFrame])
            } else {
                for frameIndex in remainingStartFrame..<sourceEndFrame {
                    outputSamples.append(clampAudioSample(sourceSamples[frameIndex] * gain))
                }
            }
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
                    frameCount: beforeCount,
                    gain: segment.gain
                ))
            }

            let afterCount = segmentEndFrame - overlapEndFrame
            if afterCount > 0 {
                nextSegments.append(Segment(
                    sourceStartFrame: segment.sourceStartFrame + (overlapEndFrame - segmentStartFrame),
                    frameCount: afterCount,
                    gain: segment.gain
                ))
            }
        }

        let deletedFrameCount = frameCount - nextSegments.reduce(0) { total, segment in
            total + segment.frameCount
        }

        segments = nextSegments
        return deletedFrameCount
    }

    private mutating func applyGain(_ gain: Float, toFramesIn frameRange: Range<Int>) -> Int {
        guard
            frameRange.lowerBound < frameRange.upperBound,
            frameRange.lowerBound < frameCount,
            frameRange.upperBound > 0,
            gain >= 0,
            gain.isFinite
        else {
            return 0
        }

        let clampedRange = max(frameRange.lowerBound, 0)..<min(frameRange.upperBound, frameCount)
        var nextSegments: [Segment] = []
        var timelineFrame = 0
        var affectedFrameCount = 0

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
                    frameCount: beforeCount,
                    gain: segment.gain
                ))
            }

            let selectedCount = overlapEndFrame - overlapStartFrame
            nextSegments.append(Segment(
                sourceStartFrame: segment.sourceStartFrame + (overlapStartFrame - segmentStartFrame),
                frameCount: selectedCount,
                gain: segment.gain * gain
            ))
            affectedFrameCount += selectedCount

            let afterCount = segmentEndFrame - overlapEndFrame
            if afterCount > 0 {
                nextSegments.append(Segment(
                    sourceStartFrame: segment.sourceStartFrame + (overlapEndFrame - segmentStartFrame),
                    frameCount: afterCount,
                    gain: segment.gain
                ))
            }
        }

        segments = nextSegments
        return affectedFrameCount
    }

    private func clampAudioSample(_ sample: Float) -> Float {
        min(max(sample, -1), 1)
    }
}
