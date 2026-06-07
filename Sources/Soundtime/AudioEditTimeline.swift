import Foundation

struct AudioEditTimeline: Sendable {
    private static let spliceFadeDuration: TimeInterval = 0.005
    private static let gainEpsilon: Float = 0.000_001

    enum FadeDirection: Sendable {
        case fadeIn
        case fadeOut
    }

    struct PlaybackSegment: Sendable {
        let outputStartFrame: Int
        let sourceStartFrame: Int
        let frameCount: Int
        let sourceFrameScale: Double
        let gainStart: Float
        let gainEnd: Float
        let startsNewClip: Bool

        init(
            outputStartFrame: Int,
            sourceStartFrame: Int,
            frameCount: Int,
            sourceFrameScale: Double,
            gainStart: Float,
            gainEnd: Float,
            startsNewClip: Bool = false
        ) {
            self.outputStartFrame = outputStartFrame
            self.sourceStartFrame = sourceStartFrame
            self.frameCount = frameCount
            self.sourceFrameScale = sourceFrameScale
            self.gainStart = gainStart
            self.gainEnd = gainEnd
            self.startsNewClip = startsNewClip
        }
    }

    private struct Segment: Sendable {
        let sourceStartFrame: Int
        let frameCount: Int
        let gainStart: Float
        let gainEnd: Float
        let startsNewClip: Bool

        init(
            sourceStartFrame: Int,
            frameCount: Int,
            gainStart: Float,
            gainEnd: Float,
            startsNewClip: Bool = false
        ) {
            self.sourceStartFrame = sourceStartFrame
            self.frameCount = frameCount
            self.gainStart = gainStart
            self.gainEnd = gainEnd
            self.startsNewClip = startsNewClip
        }

        var sourceEndFrame: Int {
            sourceStartFrame + frameCount
        }

        var hasConstantGain: Bool {
            abs(gainStart - gainEnd) <= AudioEditTimeline.gainEpsilon
        }

        func gain(at offset: Int) -> Float {
            guard frameCount > 1 else {
                return gainEnd
            }

            let clampedOffset = min(max(offset, 0), frameCount - 1)
            let progress = Float(clampedOffset) / Float(frameCount - 1)
            let curve = AudioEditTimeline.smoothstep(progress)
            return gainStart + (gainEnd - gainStart) * curve
        }

        func scaled(by gain: Float) -> Segment {
            Segment(
                sourceStartFrame: sourceStartFrame,
                frameCount: frameCount,
                gainStart: gainStart * gain,
                gainEnd: gainEnd * gain,
                startsNewClip: startsNewClip
            )
        }

        func scaled(startMultiplier: Float, endMultiplier: Float) -> Segment {
            Segment(
                sourceStartFrame: sourceStartFrame,
                frameCount: frameCount,
                gainStart: gainStart * startMultiplier,
                gainEnd: gainEnd * endMultiplier,
                startsNewClip: startsNewClip
            )
        }

        func withClipBoundary(_ startsNewClip: Bool) -> Segment {
            Segment(
                sourceStartFrame: sourceStartFrame,
                frameCount: frameCount,
                gainStart: gainStart,
                gainEnd: gainEnd,
                startsNewClip: startsNewClip
            )
        }
    }

    private let sourceBuffer: DecodedAudioBuffer
    let sourceID: UUID
    private var segments: [Segment]
    private var timelineFrameCount: Int

    init(sourceBuffer: DecodedAudioBuffer) {
        self.sourceBuffer = sourceBuffer
        sourceID = UUID()
        if sourceBuffer.frameCount > 0 {
            segments = [
                Segment(
                    sourceStartFrame: 0,
                    frameCount: sourceBuffer.frameCount,
                    gainStart: 1,
                    gainEnd: 1
                )
            ]
            timelineFrameCount = sourceBuffer.frameCount
        } else {
            segments = []
            timelineFrameCount = 0
        }
    }

    init(sourceBuffer: DecodedAudioBuffer, playbackSegments: [PlaybackSegment]) {
        self.sourceBuffer = sourceBuffer
        sourceID = UUID()
        segments = playbackSegments.compactMap { playbackSegment in
            let sourceStartFrame = min(max(playbackSegment.sourceStartFrame, 0), sourceBuffer.frameCount)
            let frameCount = min(max(playbackSegment.frameCount, 0), max(sourceBuffer.frameCount - sourceStartFrame, 0))
            guard frameCount > 0 else {
                return nil
            }

            return Segment(
                sourceStartFrame: sourceStartFrame,
                frameCount: frameCount,
                gainStart: max(playbackSegment.gainStart, 0),
                gainEnd: max(playbackSegment.gainEnd, 0),
                startsNewClip: playbackSegment.startsNewClip
            )
        }
        segments = Self.coalescedSegments(segments)
        timelineFrameCount = Self.totalFrameCount(segments)
    }

    var frameCount: Int {
        timelineFrameCount
    }

    var sourceAudioBuffer: DecodedAudioBuffer {
        sourceBuffer
    }

    var playbackSegments: [PlaybackSegment] {
        var outputStartFrame = 0
        return segments.map { segment in
            defer {
                outputStartFrame += segment.frameCount
            }

            return PlaybackSegment(
                outputStartFrame: outputStartFrame,
                sourceStartFrame: segment.sourceStartFrame,
                frameCount: segment.frameCount,
                sourceFrameScale: 0,
                gainStart: segment.gainStart,
                gainEnd: segment.gainEnd,
                startsNewClip: segment.startsNewClip
            )
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

    mutating func applyFade(_ direction: FadeDirection, to selection: TimelineSelection) -> Int {
        applyFade(direction, toFramesIn: frameRange(for: selection))
    }

    mutating func split(atProgress progress: Double) -> Bool {
        guard progress.isFinite, timelineFrameCount > 1 else {
            return false
        }

        let splitFrame = Int((progress * Double(timelineFrameCount)).rounded())
        return split(atFrame: splitFrame)
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
                    segment: segment,
                    segmentOffset: segmentOffset
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
            outputSamples[outputIndex] *= 1 - Self.smoothstep(progress)
        }
    }

    private func appendSegmentSamples(
        to outputSamples: inout [Float],
        sourceSamples: [Float],
        sourceStartFrame: Int,
        sourceEndFrame: Int,
        fadeInFrameCount: Int,
        segment: Segment,
        segmentOffset: Int
    ) {
        guard sourceStartFrame < sourceEndFrame else {
            return
        }

        let fadeFrameCount = min(fadeInFrameCount, sourceEndFrame - sourceStartFrame)
        guard fadeFrameCount > 1 else {
            if segment.hasConstantGain, abs(segment.gainStart - 1) <= Self.gainEpsilon {
                outputSamples.append(contentsOf: sourceSamples[sourceStartFrame..<sourceEndFrame])
            } else {
                for frameIndex in sourceStartFrame..<sourceEndFrame {
                    let gain = segment.gain(at: segmentOffset + frameIndex - sourceStartFrame)
                    outputSamples.append(clampAudioSample(sourceSamples[frameIndex] * gain))
                }
            }
            return
        }

        for offset in 0..<fadeFrameCount {
            let progress = Float(offset) / Float(fadeFrameCount - 1)
            let gain = segment.gain(at: segmentOffset + offset)
            outputSamples.append(
                clampAudioSample(sourceSamples[sourceStartFrame + offset] * gain) * Self.smoothstep(progress)
            )
        }

        let remainingStartFrame = sourceStartFrame + fadeFrameCount
        if remainingStartFrame < sourceEndFrame {
            if segment.hasConstantGain, abs(segment.gainStart - 1) <= Self.gainEpsilon {
                outputSamples.append(contentsOf: sourceSamples[remainingStartFrame..<sourceEndFrame])
            } else {
                for frameIndex in remainingStartFrame..<sourceEndFrame {
                    let gain = segment.gain(at: segmentOffset + frameIndex - sourceStartFrame)
                    outputSamples.append(clampAudioSample(sourceSamples[frameIndex] * gain))
                }
            }
        }
    }

    private static func smoothstep(_ progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        return clampedProgress * clampedProgress * (3 - 2 * clampedProgress)
    }

    private static func fadeMultiplier(
        for direction: FadeDirection,
        selectedOffset: Int,
        selectedFrameCount: Int
    ) -> Float {
        guard selectedFrameCount > 1 else {
            return direction == .fadeIn ? 1 : 0
        }

        let progress = Float(min(max(selectedOffset, 0), selectedFrameCount - 1)) /
            Float(selectedFrameCount - 1)
        let curve = smoothstep(progress)
        switch direction {
        case .fadeIn:
            return curve
        case .fadeOut:
            return 1 - curve
        }
    }

    private func slice(_ segment: Segment, offset: Int, count: Int) -> Segment {
        guard count > 0 else {
            return Segment(
                sourceStartFrame: segment.sourceStartFrame + offset,
                frameCount: 0,
                gainStart: segment.gain(at: offset),
                gainEnd: segment.gain(at: offset),
                startsNewClip: offset == 0 && segment.startsNewClip
            )
        }

        return Segment(
            sourceStartFrame: segment.sourceStartFrame + offset,
            frameCount: count,
            gainStart: segment.gain(at: offset),
            gainEnd: segment.gain(at: offset + count - 1),
            startsNewClip: offset == 0 && segment.startsNewClip
        )
    }

    private static func coalescedSegments(_ segments: [Segment]) -> [Segment] {
        var result: [Segment] = []
        result.reserveCapacity(segments.count)

        for rawSegment in segments where rawSegment.frameCount > 0 {
            let segment = result.isEmpty ? rawSegment.withClipBoundary(false) : rawSegment
            guard let previous = result.last else {
                result.append(segment)
                continue
            }

            if
                !segment.startsNewClip,
                previous.sourceEndFrame == segment.sourceStartFrame,
                previous.hasConstantGain,
                segment.hasConstantGain,
                abs(previous.gainStart - segment.gainStart) <= Self.gainEpsilon
            {
                result[result.count - 1] = Segment(
                    sourceStartFrame: previous.sourceStartFrame,
                    frameCount: previous.frameCount + segment.frameCount,
                    gainStart: previous.gainStart,
                    gainEnd: previous.gainEnd,
                    startsNewClip: previous.startsNewClip
                )
            } else {
                result.append(segment)
            }
        }

        return result
    }

    private static func totalFrameCount(_ segments: [Segment]) -> Int {
        segments.reduce(0) { total, segment in
            total + segment.frameCount
        }
    }

    private mutating func split(atFrame requestedFrame: Int) -> Bool {
        guard requestedFrame > 0, requestedFrame < timelineFrameCount else {
            return false
        }

        var nextSegments: [Segment] = []
        nextSegments.reserveCapacity(segments.count + 1)
        var timelineFrame = 0
        var didSplit = false

        for segment in segments {
            let segmentStartFrame = timelineFrame
            let segmentEndFrame = timelineFrame + segment.frameCount
            timelineFrame = segmentEndFrame

            if requestedFrame == segmentStartFrame, !nextSegments.isEmpty {
                if segment.startsNewClip {
                    nextSegments.append(segment)
                } else {
                    nextSegments.append(segment.withClipBoundary(true))
                    didSplit = true
                }
                continue
            }

            guard requestedFrame > segmentStartFrame, requestedFrame < segmentEndFrame else {
                nextSegments.append(segment)
                continue
            }

            let beforeCount = requestedFrame - segmentStartFrame
            let afterCount = segmentEndFrame - requestedFrame
            nextSegments.append(slice(segment, offset: 0, count: beforeCount))
            nextSegments.append(slice(segment, offset: beforeCount, count: afterCount).withClipBoundary(true))
            didSplit = true
        }

        guard didSplit else {
            return false
        }

        segments = Self.coalescedSegments(nextSegments)
        timelineFrameCount = Self.totalFrameCount(segments)
        return true
    }

    private mutating func deleteFrames(in frameRange: Range<Int>) -> Int {
        guard
            frameRange.lowerBound < frameRange.upperBound,
            frameRange.lowerBound < timelineFrameCount,
            frameRange.upperBound > 0
        else {
            return 0
        }

        let originalFrameCount = timelineFrameCount
        let clampedRange = max(frameRange.lowerBound, 0)..<min(frameRange.upperBound, originalFrameCount)
        var nextSegments: [Segment] = []
        nextSegments.reserveCapacity(segments.count + 2)
        var timelineFrame = 0
        var deletedFrameCount = 0

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

            deletedFrameCount += overlapEndFrame - overlapStartFrame
            let beforeCount = overlapStartFrame - segmentStartFrame
            if beforeCount > 0 {
                nextSegments.append(slice(segment, offset: 0, count: beforeCount))
            }

            let afterCount = segmentEndFrame - overlapEndFrame
            if afterCount > 0 {
                nextSegments.append(slice(
                    segment,
                    offset: overlapEndFrame - segmentStartFrame,
                    count: afterCount
                ))
            }
        }

        segments = Self.coalescedSegments(nextSegments)
        timelineFrameCount = originalFrameCount - deletedFrameCount
        return deletedFrameCount
    }

    private mutating func applyGain(_ gain: Float, toFramesIn frameRange: Range<Int>) -> Int {
        guard
            frameRange.lowerBound < frameRange.upperBound,
            frameRange.lowerBound < timelineFrameCount,
            frameRange.upperBound > 0,
            gain >= 0,
            gain.isFinite
        else {
            return 0
        }

        let clampedRange = max(frameRange.lowerBound, 0)..<min(frameRange.upperBound, timelineFrameCount)
        var nextSegments: [Segment] = []
        nextSegments.reserveCapacity(segments.count + 2)
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
                nextSegments.append(slice(segment, offset: 0, count: beforeCount))
            }

            let selectedCount = overlapEndFrame - overlapStartFrame
            nextSegments.append(slice(
                segment,
                offset: overlapStartFrame - segmentStartFrame,
                count: selectedCount
            ).scaled(by: gain))
            affectedFrameCount += selectedCount

            let afterCount = segmentEndFrame - overlapEndFrame
            if afterCount > 0 {
                nextSegments.append(slice(
                    segment,
                    offset: overlapEndFrame - segmentStartFrame,
                    count: afterCount
                ))
            }
        }

        segments = Self.coalescedSegments(nextSegments)
        return affectedFrameCount
    }

    private mutating func applyFade(_ direction: FadeDirection, toFramesIn frameRange: Range<Int>) -> Int {
        guard
            frameRange.lowerBound < frameRange.upperBound,
            frameRange.lowerBound < timelineFrameCount,
            frameRange.upperBound > 0
        else {
            return 0
        }

        let clampedRange = max(frameRange.lowerBound, 0)..<min(frameRange.upperBound, timelineFrameCount)
        let selectedFrameCount = clampedRange.count
        var nextSegments: [Segment] = []
        nextSegments.reserveCapacity(segments.count + 2)
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
                nextSegments.append(slice(segment, offset: 0, count: beforeCount))
            }

            let selectedCount = overlapEndFrame - overlapStartFrame
            let selectedStartOffset = overlapStartFrame - clampedRange.lowerBound
            let selectedEndOffset = selectedStartOffset + selectedCount - 1
            let startMultiplier = Self.fadeMultiplier(
                for: direction,
                selectedOffset: selectedStartOffset,
                selectedFrameCount: selectedFrameCount
            )
            let endMultiplier = Self.fadeMultiplier(
                for: direction,
                selectedOffset: selectedEndOffset,
                selectedFrameCount: selectedFrameCount
            )
            nextSegments.append(slice(
                segment,
                offset: overlapStartFrame - segmentStartFrame,
                count: selectedCount
            ).scaled(startMultiplier: startMultiplier, endMultiplier: endMultiplier))
            affectedFrameCount += selectedCount

            let afterCount = segmentEndFrame - overlapEndFrame
            if afterCount > 0 {
                nextSegments.append(slice(
                    segment,
                    offset: overlapEndFrame - segmentStartFrame,
                    count: afterCount
                ))
            }
        }

        segments = Self.coalescedSegments(nextSegments)
        return affectedFrameCount
    }

    private func clampAudioSample(_ sample: Float) -> Float {
        min(max(sample, -1), 1)
    }
}
