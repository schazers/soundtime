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

    struct Clip: Sendable {
        fileprivate var segments: [Segment]

        var frameCount: Int {
            Self.totalFrameCount(segments)
        }

        var duration: TimeInterval {
            guard sourceSampleRate > 0 else {
                return 0
            }
            return Double(frameCount) / sourceSampleRate
        }

        fileprivate let sourceSampleRate: Double

        private static func totalFrameCount(_ segments: [Segment]) -> Int {
            segments.reduce(0) { total, segment in
                total + segment.frameCount
            }
        }
    }

    struct ClipRange: Equatable, Sendable {
        let startProgress: Double
        let endProgress: Double
    }

    enum ClipEdge: Sendable {
        case leading
        case trailing
    }

    fileprivate struct Segment: Sendable {
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

        func shifted(by frameDelta: Int) -> Segment {
            Segment(
                sourceStartFrame: sourceStartFrame + frameDelta,
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

    var clipRanges: [ClipRange] {
        guard timelineFrameCount > 0 else {
            return []
        }

        var ranges: [ClipRange] = []
        var clipStartFrame = 0
        var timelineFrame = 0
        for segment in segments {
            if segment.startsNewClip, timelineFrame > clipStartFrame {
                ranges.append(ClipRange(
                    startProgress: Double(clipStartFrame) / Double(timelineFrameCount),
                    endProgress: Double(timelineFrame) / Double(timelineFrameCount)
                ))
                clipStartFrame = timelineFrame
            }
            timelineFrame += segment.frameCount
        }
        if timelineFrame > clipStartFrame {
            ranges.append(ClipRange(
                startProgress: Double(clipStartFrame) / Double(timelineFrameCount),
                endProgress: Double(timelineFrame) / Double(timelineFrameCount)
            ))
        }
        return ranges
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

    mutating func delete(frameRange: Range<Int>) -> Int {
        deleteFrames(in: frameRange)
    }

    mutating func clear(_ selection: TimelineSelection) -> Int {
        clearFrames(in: frameRange(for: selection))
    }

    mutating func clear(frameRange: Range<Int>) -> Int {
        clearFrames(in: frameRange)
    }

    func clip(for selection: TimelineSelection) -> Clip? {
        let selectedSegments = segments(in: frameRange(for: selection))
        guard !selectedSegments.isEmpty else {
            return nil
        }

        return Clip(
            segments: selectedSegments,
            sourceSampleRate: sourceBuffer.sampleRate
        )
    }

    mutating func replace(_ selection: TimelineSelection, with clip: Clip) -> Int? {
        guard
            abs(sourceBuffer.sampleRate - clip.sourceSampleRate) < 0.001,
            !clip.segments.isEmpty
        else {
            return nil
        }

        let replacementRange = clampedFrameRange(for: selection)
        let beforeSegments = segments(in: 0..<replacementRange.lowerBound)
        let afterSegments = segments(in: replacementRange.upperBound..<frameCount)
        segments = Self.coalescedSegments(beforeSegments + clip.segments + afterSegments)
        let replacementFrameCount = Self.totalFrameCount(clip.segments)
        timelineFrameCount = timelineFrameCount - replacementRange.count + replacementFrameCount
        return replacementFrameCount
    }

    mutating func insertSilence(frameCount requestedFrameCount: Int, atProgress progress: Double) -> Int {
        guard
            requestedFrameCount > 0,
            progress.isFinite,
            sourceBuffer.frameCount > 0
        else {
            return 0
        }

        let insertionFrame = min(
            max(Int((progress * Double(timelineFrameCount)).rounded()), 0),
            timelineFrameCount
        )
        if insertionFrame > 0, insertionFrame < timelineFrameCount {
            _ = split(atFrame: insertionFrame)
        }

        var insertedFrameCount = 0
        let silenceSegments = makeSilenceSegments(
            frameCount: requestedFrameCount,
            insertedFrameCount: &insertedFrameCount
        )
        guard !silenceSegments.isEmpty, insertedFrameCount > 0 else {
            return 0
        }

        var nextSegments: [Segment] = []
        nextSegments.reserveCapacity(segments.count + silenceSegments.count + 1)
        var timelineFrame = 0
        var didInsert = false
        var marksNextSegmentAsClipStart = false

        for segment in segments {
            if !didInsert, insertionFrame <= timelineFrame {
                nextSegments.append(contentsOf: silenceSegments)
                didInsert = true
                marksNextSegmentAsClipStart = true
            }

            nextSegments.append(marksNextSegmentAsClipStart ? segment.withClipBoundary(true) : segment)
            marksNextSegmentAsClipStart = false
            timelineFrame += segment.frameCount
        }

        if !didInsert {
            nextSegments.append(contentsOf: silenceSegments)
        }

        segments = Self.coalescedSegments(nextSegments)
        timelineFrameCount += insertedFrameCount
        return insertedFrameCount
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

    mutating func healNearestClipBoundary(atProgress progress: Double) -> Bool {
        guard progress.isFinite, timelineFrameCount > 1 else {
            return false
        }

        let targetFrame = min(
            max(Int((progress * Double(timelineFrameCount)).rounded()), 0),
            timelineFrameCount
        )
        var timelineFrame = 0
        var nearestIndex: Int?
        var nearestDistance = Int.max
        for index in segments.indices {
            let segment = segments[index]
            if segment.startsNewClip, timelineFrame > 0 {
                let distance = abs(timelineFrame - targetFrame)
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearestIndex = index
                }
            }
            timelineFrame += segment.frameCount
        }

        guard let nearestIndex else {
            return false
        }

        segments[nearestIndex] = segments[nearestIndex].withClipBoundary(false)
        segments = Self.coalescedSegments(segments)
        timelineFrameCount = Self.totalFrameCount(segments)
        return true
    }

    mutating func slipClip(
        _ clipRange: ClipRange,
        byFrameCount requestedFrameDelta: Int
    ) -> Int {
        guard
            requestedFrameDelta != 0,
            sourceBuffer.frameCount > 0,
            clipRange.startProgress < clipRange.endProgress
        else {
            return 0
        }

        let clipFrameRange = frameRange(for: TimelineSelection(
            startProgress: clipRange.startProgress,
            endProgress: clipRange.endProgress
        ))
        let clipSegments = segments(in: clipFrameRange)
        guard !clipSegments.isEmpty else {
            return 0
        }

        let minimumDelta = clipSegments.map { -$0.sourceStartFrame }.max() ?? 0
        let maximumDelta = clipSegments.map { sourceBuffer.frameCount - $0.sourceEndFrame }.min() ?? 0
        let frameDelta = min(max(requestedFrameDelta, minimumDelta), maximumDelta)
        guard frameDelta != 0 else {
            return 0
        }

        var nextSegments: [Segment] = []
        nextSegments.reserveCapacity(segments.count + 2)
        var timelineFrame = 0
        for segment in segments {
            let segmentStartFrame = timelineFrame
            let segmentEndFrame = timelineFrame + segment.frameCount
            timelineFrame = segmentEndFrame

            let overlapStartFrame = max(segmentStartFrame, clipFrameRange.lowerBound)
            let overlapEndFrame = min(segmentEndFrame, clipFrameRange.upperBound)
            guard overlapStartFrame < overlapEndFrame else {
                nextSegments.append(segment)
                continue
            }

            let beforeCount = overlapStartFrame - segmentStartFrame
            if beforeCount > 0 {
                nextSegments.append(slice(segment, offset: 0, count: beforeCount))
            }

            let selectedSegment = slice(
                segment,
                offset: overlapStartFrame - segmentStartFrame,
                count: overlapEndFrame - overlapStartFrame
            ).shifted(by: frameDelta)
            nextSegments.append(selectedSegment)

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
        timelineFrameCount = Self.totalFrameCount(segments)
        return frameDelta
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

    mutating func trimClip(
        _ clipRange: ClipRange,
        edge: ClipEdge,
        toProgress targetProgress: Double
    ) -> Int {
        let originalFrameCount = frameCount
        guard
            originalFrameCount > 1,
            targetProgress.isFinite,
            clipRange.startProgress < clipRange.endProgress
        else {
            return 0
        }

        let clipStartFrame = min(
            max(Int((clipRange.startProgress * Double(originalFrameCount)).rounded()), 0),
            originalFrameCount
        )
        let clipEndFrame = min(
            max(Int((clipRange.endProgress * Double(originalFrameCount)).rounded()), clipStartFrame),
            originalFrameCount
        )
        guard clipEndFrame - clipStartFrame > 1 else {
            return 0
        }

        switch edge {
        case .leading:
            let targetFrame = min(
                max(Int((targetProgress * Double(originalFrameCount)).rounded()), clipStartFrame + 1),
                clipEndFrame - 1
            )
            let deletedFrameCount = deleteFrames(in: clipStartFrame..<targetFrame)
            if deletedFrameCount > 0, clipStartFrame > 0 {
                _ = split(atFrame: clipStartFrame)
            }
            return deletedFrameCount
        case .trailing:
            let targetFrame = min(
                max(Int((targetProgress * Double(originalFrameCount)).rounded()), clipStartFrame + 1),
                clipEndFrame - 1
            )
            return deleteFrames(in: targetFrame..<clipEndFrame)
        }
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

    private func clampedFrameRange(for selection: TimelineSelection) -> Range<Int> {
        let frameRange = frameRange(for: selection)
        return max(frameRange.lowerBound, 0)..<min(max(frameRange.upperBound, frameRange.lowerBound), frameCount)
    }

    private func segments(in frameRange: Range<Int>) -> [Segment] {
        guard
            frameRange.lowerBound < frameRange.upperBound,
            frameRange.lowerBound < timelineFrameCount,
            frameRange.upperBound > 0
        else {
            return []
        }

        let clampedRange = max(frameRange.lowerBound, 0)..<min(frameRange.upperBound, timelineFrameCount)
        var result: [Segment] = []
        result.reserveCapacity(segments.count)
        var timelineFrame = 0

        for segment in segments {
            let segmentStartFrame = timelineFrame
            let segmentEndFrame = timelineFrame + segment.frameCount
            timelineFrame = segmentEndFrame

            let overlapStartFrame = max(segmentStartFrame, clampedRange.lowerBound)
            let overlapEndFrame = min(segmentEndFrame, clampedRange.upperBound)
            guard overlapStartFrame < overlapEndFrame else {
                continue
            }

            let segmentOffset = overlapStartFrame - segmentStartFrame
            let selectedCount = overlapEndFrame - overlapStartFrame
            let slicedSegment = slice(
                segment,
                offset: segmentOffset,
                count: selectedCount
            )
            result.append(result.isEmpty ? slicedSegment.withClipBoundary(true) : slicedSegment)
        }

        return Self.coalescedSegments(result)
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

    private mutating func clearFrames(in frameRange: Range<Int>) -> Int {
        applyGain(0, toFramesIn: frameRange)
    }

    private func makeSilenceSegments(
        frameCount requestedFrameCount: Int,
        insertedFrameCount: inout Int
    ) -> [Segment] {
        guard requestedFrameCount > 0, sourceBuffer.frameCount > 0 else {
            return []
        }

        var remainingFrameCount = requestedFrameCount
        var result: [Segment] = []
        result.reserveCapacity(max(Int(ceil(Double(requestedFrameCount) / Double(sourceBuffer.frameCount))), 1))
        var isFirstSegment = true
        while remainingFrameCount > 0 {
            let chunkFrameCount = min(remainingFrameCount, sourceBuffer.frameCount)
            result.append(Segment(
                sourceStartFrame: 0,
                frameCount: chunkFrameCount,
                gainStart: 0,
                gainEnd: 0,
                startsNewClip: isFirstSegment
            ))
            insertedFrameCount += chunkFrameCount
            remainingFrameCount -= chunkFrameCount
            isFirstSegment = false
        }
        return result
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
