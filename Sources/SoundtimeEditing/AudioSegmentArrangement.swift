import Foundation

public enum AudioTimelineFadeDirection: Sendable {
    case fadeIn
    case fadeOut
}

public struct AudioTimelinePlaybackSegment: Equatable, Sendable {
    public let outputStartFrame: Int
    public let sourceStartFrame: Int
    public let frameCount: Int
    public let sourceFrameScale: Double
    public let gainStart: Float
    public let gainEnd: Float
    public let startsNewClip: Bool

    public init(
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

public struct AudioTimelineClipRange: Equatable, Sendable {
    public let startProgress: Double
    public let endProgress: Double

    public init(startProgress: Double, endProgress: Double) {
        self.startProgress = startProgress
        self.endProgress = endProgress
    }
}

public enum AudioTimelineClipEdge: Sendable {
    case leading
    case trailing
}

public struct AudioTimelineSegment: Equatable, Sendable {
    public let sourceStartFrame: Int
    public let frameCount: Int
    public let gainStart: Float
    public let gainEnd: Float
    public let startsNewClip: Bool

    public init(
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

    public var sourceEndFrame: Int {
        sourceStartFrame + frameCount
    }

    public var hasConstantGain: Bool {
        abs(gainStart - gainEnd) <= AudioSegmentArrangement.gainEpsilon
    }

    public func gain(at offset: Int) -> Float {
        guard frameCount > 1 else {
            return gainEnd
        }

        let clampedOffset = min(max(offset, 0), frameCount - 1)
        let progress = Float(clampedOffset) / Float(frameCount - 1)
        let curve = AudioSegmentArrangement.smoothstep(progress)
        return gainStart + (gainEnd - gainStart) * curve
    }

    public func scaled(by gain: Float) -> Self {
        Self(
            sourceStartFrame: sourceStartFrame,
            frameCount: frameCount,
            gainStart: gainStart * gain,
            gainEnd: gainEnd * gain,
            startsNewClip: startsNewClip
        )
    }

    public func scaled(startMultiplier: Float, endMultiplier: Float) -> Self {
        Self(
            sourceStartFrame: sourceStartFrame,
            frameCount: frameCount,
            gainStart: gainStart * startMultiplier,
            gainEnd: gainEnd * endMultiplier,
            startsNewClip: startsNewClip
        )
    }

    public func withClipBoundary(_ startsNewClip: Bool) -> Self {
        Self(
            sourceStartFrame: sourceStartFrame,
            frameCount: frameCount,
            gainStart: gainStart,
            gainEnd: gainEnd,
            startsNewClip: startsNewClip
        )
    }

    public func shifted(by frameDelta: Int) -> Self {
        Self(
            sourceStartFrame: sourceStartFrame + frameDelta,
            frameCount: frameCount,
            gainStart: gainStart,
            gainEnd: gainEnd,
            startsNewClip: startsNewClip
        )
    }
}

/// Canonical edit algebra shared by decoded and file-backed audio sources.
public struct AudioSegmentArrangement: Sendable {
    public static let gainEpsilon: Float = 0.000_001

    public let sourceFrameCount: Int
    public private(set) var segments: [AudioTimelineSegment]
    public private(set) var frameCount: Int

    public init(sourceFrameCount: Int) {
        self.sourceFrameCount = max(sourceFrameCount, 0)
        if sourceFrameCount > 0 {
            segments = [
                AudioTimelineSegment(
                    sourceStartFrame: 0,
                    frameCount: sourceFrameCount,
                    gainStart: 1,
                    gainEnd: 1
                ),
            ]
            frameCount = sourceFrameCount
        } else {
            segments = []
            frameCount = 0
        }
    }

    public init(sourceFrameCount: Int, segments: [AudioTimelineSegment]) {
        self.sourceFrameCount = max(sourceFrameCount, 0)
        self.segments = Self.validatedSegments(
            segments,
            sourceFrameCount: max(sourceFrameCount, 0)
        )
        frameCount = Self.totalFrameCount(self.segments)
    }

    public var playbackSegments: [AudioTimelinePlaybackSegment] {
        var outputStartFrame = 0
        return segments.map { segment in
            defer {
                outputStartFrame += segment.frameCount
            }
            return AudioTimelinePlaybackSegment(
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

    public var clipRanges: [AudioTimelineClipRange] {
        guard frameCount > 0 else {
            return []
        }

        var ranges: [AudioTimelineClipRange] = []
        var clipStartFrame = 0
        var timelineFrame = 0
        for segment in segments {
            if segment.startsNewClip, timelineFrame > clipStartFrame {
                ranges.append(AudioTimelineClipRange(
                    startProgress: Double(clipStartFrame) / Double(frameCount),
                    endProgress: Double(timelineFrame) / Double(frameCount)
                ))
                clipStartFrame = timelineFrame
            }
            timelineFrame += segment.frameCount
        }
        if timelineFrame > clipStartFrame {
            ranges.append(AudioTimelineClipRange(
                startProgress: Double(clipStartFrame) / Double(frameCount),
                endProgress: Double(timelineFrame) / Double(frameCount)
            ))
        }
        return ranges
    }

    public var hasEdits: Bool {
        guard segments.count == 1, let segment = segments.first else {
            return true
        }
        return segment.sourceStartFrame != 0 ||
            segment.frameCount != sourceFrameCount ||
            abs(segment.gainStart - 1) > Float.ulpOfOne ||
            abs(segment.gainEnd - 1) > Float.ulpOfOne
    }

    public var hasSourceFrameAlignment: Bool {
        var timelineFrame = 0
        for segment in segments {
            guard segment.sourceStartFrame == timelineFrame else {
                return false
            }
            timelineFrame += segment.frameCount
        }
        return timelineFrame == sourceFrameCount
    }

    public func frameRange(for selection: TimelineSelection) -> Range<Int> {
        let startFrame = Int((selection.startProgress * Double(frameCount)).rounded(.down))
        let endFrame = Int((selection.endProgress * Double(frameCount)).rounded(.up))
        return clampedFrameRange(startFrame..<max(endFrame, startFrame))
    }

    public func clampedFrameRange(_ requestedRange: Range<Int>) -> Range<Int> {
        let lowerBound = min(max(requestedRange.lowerBound, 0), frameCount)
        let upperBound = min(max(requestedRange.upperBound, lowerBound), frameCount)
        return lowerBound..<upperBound
    }

    public func segments(in requestedRange: Range<Int>) -> [AudioTimelineSegment] {
        let range = clampedFrameRange(requestedRange)
        guard !range.isEmpty else {
            return []
        }

        var output: [AudioTimelineSegment] = []
        output.reserveCapacity(segments.count)
        var timelineFrame = 0
        for segment in segments {
            let segmentStart = timelineFrame
            let segmentEnd = segmentStart + segment.frameCount
            timelineFrame = segmentEnd
            let overlapStart = max(segmentStart, range.lowerBound)
            let overlapEnd = min(segmentEnd, range.upperBound)
            guard overlapStart < overlapEnd else {
                continue
            }

            let selected = slice(
                segment,
                offset: overlapStart - segmentStart,
                count: overlapEnd - overlapStart
            )
            output.append(output.isEmpty ? selected.withClipBoundary(true) : selected)
        }
        return Self.coalescedSegments(output)
    }

    public mutating func replace(
        frameRange requestedRange: Range<Int>,
        with replacementSegments: [AudioTimelineSegment]
    ) -> Int? {
        let replacements = Self.validatedSegments(
            replacementSegments,
            sourceFrameCount: sourceFrameCount
        )
        guard !replacements.isEmpty else {
            return nil
        }

        let range = clampedFrameRange(requestedRange)
        let before = segments(in: 0..<range.lowerBound)
        let after = segments(in: range.upperBound..<frameCount)
        segments = Self.coalescedSegments(before + replacements + after)
        let replacementFrameCount = Self.totalFrameCount(replacements)
        frameCount = frameCount - range.count + replacementFrameCount
        return replacementFrameCount
    }

    public mutating func insert(
        _ replacementSegments: [AudioTimelineSegment],
        atFrame requestedFrame: Int
    ) -> Int? {
        let insertionFrame = min(max(requestedFrame, 0), frameCount)
        return replace(
            frameRange: insertionFrame..<insertionFrame,
            with: replacementSegments
        )
    }

    public mutating func delete(frameRange requestedRange: Range<Int>) -> Int {
        let range = clampedFrameRange(requestedRange)
        guard !range.isEmpty else {
            return 0
        }

        let originalFrameCount = frameCount
        var next: [AudioTimelineSegment] = []
        next.reserveCapacity(segments.count + 2)
        var timelineFrame = 0
        var deletedFrameCount = 0
        for segment in segments {
            let segmentStart = timelineFrame
            let segmentEnd = segmentStart + segment.frameCount
            timelineFrame = segmentEnd
            let overlapStart = max(segmentStart, range.lowerBound)
            let overlapEnd = min(segmentEnd, range.upperBound)
            guard overlapStart < overlapEnd else {
                next.append(segment)
                continue
            }

            deletedFrameCount += overlapEnd - overlapStart
            let beforeCount = overlapStart - segmentStart
            if beforeCount > 0 {
                next.append(slice(segment, offset: 0, count: beforeCount))
            }
            let afterCount = segmentEnd - overlapEnd
            if afterCount > 0 {
                next.append(slice(
                    segment,
                    offset: overlapEnd - segmentStart,
                    count: afterCount
                ))
            }
        }

        segments = Self.coalescedSegments(next)
        frameCount = originalFrameCount - deletedFrameCount
        return deletedFrameCount
    }

    public mutating func clear(frameRange: Range<Int>) -> Int {
        applyGain(0, frameRange: frameRange)
    }

    public mutating func insertSilence(
        frameCount requestedFrameCount: Int,
        atProgress progress: Double
    ) -> Int {
        guard requestedFrameCount > 0, progress.isFinite, sourceFrameCount > 0 else {
            return 0
        }

        let insertionFrame = min(
            max(Int((progress * Double(frameCount)).rounded()), 0),
            frameCount
        )
        if insertionFrame > 0, insertionFrame < frameCount {
            _ = split(atFrame: insertionFrame)
        }

        var remaining = requestedFrameCount
        var silence: [AudioTimelineSegment] = []
        silence.reserveCapacity(max(Int(ceil(Double(requestedFrameCount) / Double(sourceFrameCount))), 1))
        while remaining > 0 {
            let chunk = min(remaining, sourceFrameCount)
            silence.append(AudioTimelineSegment(
                sourceStartFrame: 0,
                frameCount: chunk,
                gainStart: 0,
                gainEnd: 0,
                startsNewClip: silence.isEmpty
            ))
            remaining -= chunk
        }

        return insert(silence, atFrame: insertionFrame) ?? 0
    }

    public mutating func applyGain(_ gain: Float, frameRange requestedRange: Range<Int>) -> Int {
        let range = clampedFrameRange(requestedRange)
        guard !range.isEmpty, gain >= 0, gain.isFinite else {
            return 0
        }

        var next: [AudioTimelineSegment] = []
        next.reserveCapacity(segments.count + 2)
        var timelineFrame = 0
        var affectedFrameCount = 0
        for segment in segments {
            let segmentStart = timelineFrame
            let segmentEnd = segmentStart + segment.frameCount
            timelineFrame = segmentEnd
            let overlapStart = max(segmentStart, range.lowerBound)
            let overlapEnd = min(segmentEnd, range.upperBound)
            guard overlapStart < overlapEnd else {
                next.append(segment)
                continue
            }

            let beforeCount = overlapStart - segmentStart
            if beforeCount > 0 {
                next.append(slice(segment, offset: 0, count: beforeCount))
            }
            let selectedCount = overlapEnd - overlapStart
            next.append(slice(
                segment,
                offset: overlapStart - segmentStart,
                count: selectedCount
            ).scaled(by: gain))
            affectedFrameCount += selectedCount
            let afterCount = segmentEnd - overlapEnd
            if afterCount > 0 {
                next.append(slice(
                    segment,
                    offset: overlapEnd - segmentStart,
                    count: afterCount
                ))
            }
        }

        segments = Self.coalescedSegments(next)
        return affectedFrameCount
    }

    public mutating func applyFade(
        _ direction: AudioTimelineFadeDirection,
        frameRange requestedRange: Range<Int>
    ) -> Int {
        let range = clampedFrameRange(requestedRange)
        guard !range.isEmpty else {
            return 0
        }

        var next: [AudioTimelineSegment] = []
        next.reserveCapacity(segments.count + 2)
        var timelineFrame = 0
        var affectedFrameCount = 0
        for segment in segments {
            let segmentStart = timelineFrame
            let segmentEnd = segmentStart + segment.frameCount
            timelineFrame = segmentEnd
            let overlapStart = max(segmentStart, range.lowerBound)
            let overlapEnd = min(segmentEnd, range.upperBound)
            guard overlapStart < overlapEnd else {
                next.append(segment)
                continue
            }

            let beforeCount = overlapStart - segmentStart
            if beforeCount > 0 {
                next.append(slice(segment, offset: 0, count: beforeCount))
            }
            let selectedCount = overlapEnd - overlapStart
            let selectedStartOffset = overlapStart - range.lowerBound
            let selectedEndOffset = selectedStartOffset + selectedCount - 1
            next.append(slice(
                segment,
                offset: overlapStart - segmentStart,
                count: selectedCount
            ).scaled(
                startMultiplier: Self.fadeMultiplier(
                    for: direction,
                    selectedOffset: selectedStartOffset,
                    selectedFrameCount: range.count
                ),
                endMultiplier: Self.fadeMultiplier(
                    for: direction,
                    selectedOffset: selectedEndOffset,
                    selectedFrameCount: range.count
                )
            ))
            affectedFrameCount += selectedCount
            let afterCount = segmentEnd - overlapEnd
            if afterCount > 0 {
                next.append(slice(
                    segment,
                    offset: overlapEnd - segmentStart,
                    count: afterCount
                ))
            }
        }

        segments = Self.coalescedSegments(next)
        return affectedFrameCount
    }

    public mutating func split(atProgress progress: Double) -> Bool {
        guard progress.isFinite, frameCount > 1 else {
            return false
        }
        return split(atFrame: Int((progress * Double(frameCount)).rounded()))
    }

    public mutating func split(atFrame requestedFrame: Int) -> Bool {
        guard requestedFrame > 0, requestedFrame < frameCount else {
            return false
        }

        var next: [AudioTimelineSegment] = []
        next.reserveCapacity(segments.count + 1)
        var timelineFrame = 0
        var didSplit = false
        for segment in segments {
            let segmentStart = timelineFrame
            let segmentEnd = segmentStart + segment.frameCount
            timelineFrame = segmentEnd
            if requestedFrame == segmentStart, !next.isEmpty {
                if segment.startsNewClip {
                    next.append(segment)
                } else {
                    next.append(segment.withClipBoundary(true))
                    didSplit = true
                }
                continue
            }
            guard requestedFrame > segmentStart, requestedFrame < segmentEnd else {
                next.append(segment)
                continue
            }

            let beforeCount = requestedFrame - segmentStart
            next.append(slice(segment, offset: 0, count: beforeCount))
            next.append(slice(
                segment,
                offset: beforeCount,
                count: segmentEnd - requestedFrame
            ).withClipBoundary(true))
            didSplit = true
        }

        guard didSplit else {
            return false
        }
        segments = Self.coalescedSegments(next)
        frameCount = Self.totalFrameCount(segments)
        return true
    }

    public mutating func healNearestClipBoundary(atProgress progress: Double) -> Bool {
        guard progress.isFinite, frameCount > 1 else {
            return false
        }

        let targetFrame = min(
            max(Int((progress * Double(frameCount)).rounded()), 0),
            frameCount
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
        frameCount = Self.totalFrameCount(segments)
        return true
    }

    public mutating func slipClip(
        _ clipRange: AudioTimelineClipRange,
        byFrameCount requestedFrameDelta: Int
    ) -> Int {
        guard
            requestedFrameDelta != 0,
            sourceFrameCount > 0,
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
        let maximumDelta = clipSegments.map { sourceFrameCount - $0.sourceEndFrame }.min() ?? 0
        let frameDelta = min(max(requestedFrameDelta, minimumDelta), maximumDelta)
        guard frameDelta != 0 else {
            return 0
        }

        var next: [AudioTimelineSegment] = []
        next.reserveCapacity(segments.count + 2)
        var timelineFrame = 0
        for segment in segments {
            let segmentStart = timelineFrame
            let segmentEnd = segmentStart + segment.frameCount
            timelineFrame = segmentEnd
            let overlapStart = max(segmentStart, clipFrameRange.lowerBound)
            let overlapEnd = min(segmentEnd, clipFrameRange.upperBound)
            guard overlapStart < overlapEnd else {
                next.append(segment)
                continue
            }
            let beforeCount = overlapStart - segmentStart
            if beforeCount > 0 {
                next.append(slice(segment, offset: 0, count: beforeCount))
            }
            next.append(slice(
                segment,
                offset: overlapStart - segmentStart,
                count: overlapEnd - overlapStart
            ).shifted(by: frameDelta))
            let afterCount = segmentEnd - overlapEnd
            if afterCount > 0 {
                next.append(slice(
                    segment,
                    offset: overlapEnd - segmentStart,
                    count: afterCount
                ))
            }
        }

        segments = Self.coalescedSegments(next)
        frameCount = Self.totalFrameCount(segments)
        return frameDelta
    }

    public mutating func trim(to range: TimelineTrimRange) -> Int {
        let originalFrameCount = frameCount
        let keepStartFrame = Int((range.startProgress * Float(originalFrameCount)).rounded(.down))
        let keepEndFrame = Int((range.endProgress * Float(originalFrameCount)).rounded(.up))
        guard
            keepStartFrame < keepEndFrame,
            keepStartFrame > 0 || keepEndFrame < originalFrameCount
        else {
            return 0
        }
        let trailing = delete(frameRange: keepEndFrame..<originalFrameCount)
        let leading = delete(frameRange: 0..<keepStartFrame)
        return trailing + leading
    }

    public mutating func trimClip(
        _ clipRange: AudioTimelineClipRange,
        edge: AudioTimelineClipEdge,
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

        let clipStart = min(
            max(Int((clipRange.startProgress * Double(originalFrameCount)).rounded()), 0),
            originalFrameCount
        )
        let clipEnd = min(
            max(Int((clipRange.endProgress * Double(originalFrameCount)).rounded()), clipStart),
            originalFrameCount
        )
        guard clipEnd - clipStart > 1 else {
            return 0
        }
        let target = min(
            max(Int((targetProgress * Double(originalFrameCount)).rounded()), clipStart + 1),
            clipEnd - 1
        )

        switch edge {
        case .leading:
            let deleted = delete(frameRange: clipStart..<target)
            if deleted > 0, clipStart > 0 {
                _ = split(atFrame: clipStart)
            }
            return deleted
        case .trailing:
            return delete(frameRange: target..<clipEnd)
        }
    }

    public static func smoothstep(_ progress: Float) -> Float {
        let clamped = min(max(progress, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func fadeMultiplier(
        for direction: AudioTimelineFadeDirection,
        selectedOffset: Int,
        selectedFrameCount: Int
    ) -> Float {
        guard selectedFrameCount > 1 else {
            return direction == .fadeIn ? 1 : 0
        }
        let progress = Float(min(max(selectedOffset, 0), selectedFrameCount - 1)) /
            Float(selectedFrameCount - 1)
        let curve = smoothstep(progress)
        return direction == .fadeIn ? curve : 1 - curve
    }

    private func slice(
        _ segment: AudioTimelineSegment,
        offset: Int,
        count: Int
    ) -> AudioTimelineSegment {
        guard count > 0 else {
            return AudioTimelineSegment(
                sourceStartFrame: segment.sourceStartFrame + offset,
                frameCount: 0,
                gainStart: segment.gain(at: offset),
                gainEnd: segment.gain(at: offset),
                startsNewClip: offset == 0 && segment.startsNewClip
            )
        }
        return AudioTimelineSegment(
            sourceStartFrame: segment.sourceStartFrame + offset,
            frameCount: count,
            gainStart: segment.gain(at: offset),
            gainEnd: segment.gain(at: offset + count - 1),
            startsNewClip: offset == 0 && segment.startsNewClip
        )
    }

    static func coalescedSegments(
        _ input: [AudioTimelineSegment]
    ) -> [AudioTimelineSegment] {
        var result: [AudioTimelineSegment] = []
        result.reserveCapacity(input.count)
        for rawSegment in input where rawSegment.frameCount > 0 {
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
                abs(previous.gainStart - segment.gainStart) <= gainEpsilon
            {
                result[result.count - 1] = AudioTimelineSegment(
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

    public static func totalFrameCount(_ segments: [AudioTimelineSegment]) -> Int {
        segments.reduce(0) { $0 + $1.frameCount }
    }

    static func validatedSegments(
        _ input: [AudioTimelineSegment],
        sourceFrameCount: Int
    ) -> [AudioTimelineSegment] {
        coalescedSegments(input.compactMap { segment in
            guard
                segment.sourceStartFrame >= 0,
                segment.frameCount > 0,
                segment.sourceStartFrame < sourceFrameCount,
                segment.gainStart >= 0,
                segment.gainStart.isFinite,
                segment.gainEnd >= 0,
                segment.gainEnd.isFinite
            else {
                return nil
            }
            let count = min(segment.frameCount, sourceFrameCount - segment.sourceStartFrame)
            guard count > 0 else {
                return nil
            }
            return AudioTimelineSegment(
                sourceStartFrame: segment.sourceStartFrame,
                frameCount: count,
                gainStart: segment.gainStart,
                gainEnd: segment.gainEnd,
                startsNewClip: segment.startsNewClip
            )
        })
    }
}
