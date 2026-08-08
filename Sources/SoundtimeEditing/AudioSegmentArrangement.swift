import Foundation

public enum AudioTimelineFadeDirection: Sendable {
    case fadeIn
    case fadeOut
}

public struct AudioTimelineClipID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct AudioTimelinePlaybackSegment: Equatable, Sendable {
    public let outputStartFrame: Int
    public let sourceStartFrame: Int
    public let frameCount: Int
    public let sourceFrameScale: Double
    public let gainStart: Float
    public let gainEnd: Float
    public let startsNewClip: Bool
    public let clipID: AudioTimelineClipID

    public init(
        outputStartFrame: Int,
        sourceStartFrame: Int,
        frameCount: Int,
        sourceFrameScale: Double,
        gainStart: Float,
        gainEnd: Float,
        startsNewClip: Bool = false,
        clipID: AudioTimelineClipID = AudioTimelineClipID()
    ) {
        self.outputStartFrame = outputStartFrame
        self.sourceStartFrame = sourceStartFrame
        self.frameCount = frameCount
        self.sourceFrameScale = sourceFrameScale
        self.gainStart = gainStart
        self.gainEnd = gainEnd
        self.startsNewClip = startsNewClip
        self.clipID = clipID
    }
}

public struct AudioTimelineClipRange: Equatable, Sendable {
    public let id: AudioTimelineClipID
    public let startProgress: Double
    public let endProgress: Double
    public let isSilent: Bool

    public init(
        id: AudioTimelineClipID = AudioTimelineClipID(),
        startProgress: Double,
        endProgress: Double,
        isSilent: Bool = false
    ) {
        self.id = id
        self.startProgress = startProgress
        self.endProgress = endProgress
        self.isSilent = isSilent
    }
}

public enum AudioTimelineClipEdge: Sendable {
    case leading
    case trailing
}

public enum AudioTimelineFollowingClipPolicy: Sendable {
    /// Later clips move by the same duration as the edit.
    case ripple
    /// Later clips retain their output-frame positions. Deleted time becomes silence.
    case preserveTimelinePositions
}

public struct AudioTimelineSegment: Equatable, Sendable {
    public let sourceStartFrame: Int
    public let frameCount: Int
    public let gainStart: Float
    public let gainEnd: Float
    public let startsNewClip: Bool
    public let clipID: AudioTimelineClipID

    public init(
        sourceStartFrame: Int,
        frameCount: Int,
        gainStart: Float,
        gainEnd: Float,
        startsNewClip: Bool = false,
        clipID: AudioTimelineClipID = AudioTimelineClipID()
    ) {
        self.sourceStartFrame = sourceStartFrame
        self.frameCount = frameCount
        self.gainStart = gainStart
        self.gainEnd = gainEnd
        self.startsNewClip = startsNewClip
        self.clipID = clipID
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
            startsNewClip: startsNewClip,
            clipID: clipID
        )
    }

    public func scaled(startMultiplier: Float, endMultiplier: Float) -> Self {
        Self(
            sourceStartFrame: sourceStartFrame,
            frameCount: frameCount,
            gainStart: gainStart * startMultiplier,
            gainEnd: gainEnd * endMultiplier,
            startsNewClip: startsNewClip,
            clipID: clipID
        )
    }

    public func withClipBoundary(
        _ startsNewClip: Bool,
        clipID replacementClipID: AudioTimelineClipID? = nil
    ) -> Self {
        Self(
            sourceStartFrame: sourceStartFrame,
            frameCount: frameCount,
            gainStart: gainStart,
            gainEnd: gainEnd,
            startsNewClip: startsNewClip,
            clipID: replacementClipID ?? (startsNewClip ? AudioTimelineClipID() : clipID)
        )
    }

    public func withClipID(
        _ clipID: AudioTimelineClipID,
        startsNewClip: Bool? = nil
    ) -> Self {
        Self(
            sourceStartFrame: sourceStartFrame,
            frameCount: frameCount,
            gainStart: gainStart,
            gainEnd: gainEnd,
            startsNewClip: startsNewClip ?? self.startsNewClip,
            clipID: clipID
        )
    }

    public func shifted(by frameDelta: Int) -> Self {
        Self(
            sourceStartFrame: sourceStartFrame + frameDelta,
            frameCount: frameCount,
            gainStart: gainStart,
            gainEnd: gainEnd,
            startsNewClip: startsNewClip,
            clipID: clipID
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
                    gainEnd: 1,
                    clipID: AudioTimelineClipID()
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
                startsNewClip: segment.startsNewClip,
                clipID: segment.clipID
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
        var activeClipID = segments[0].clipID
        var activeClipIsSilent = true
        for segment in segments {
            if segment.startsNewClip, timelineFrame > clipStartFrame {
                ranges.append(AudioTimelineClipRange(
                    id: activeClipID,
                    startProgress: Double(clipStartFrame) / Double(frameCount),
                    endProgress: Double(timelineFrame) / Double(frameCount),
                    isSilent: activeClipIsSilent
                ))
                clipStartFrame = timelineFrame
                activeClipID = segment.clipID
                activeClipIsSilent = true
            }
            activeClipIsSilent = activeClipIsSilent &&
                abs(segment.gainStart) <= Self.gainEpsilon &&
                abs(segment.gainEnd) <= Self.gainEpsilon
            timelineFrame += segment.frameCount
        }
        if timelineFrame > clipStartFrame {
            ranges.append(AudioTimelineClipRange(
                id: activeClipID,
                startProgress: Double(clipStartFrame) / Double(frameCount),
                endProgress: Double(timelineFrame) / Double(frameCount),
                isSilent: activeClipIsSilent
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

    public func clipRange(id: AudioTimelineClipID) -> AudioTimelineClipRange? {
        clipRanges.first(where: { $0.id == id })
    }

    public func frameRange(forClipID id: AudioTimelineClipID) -> Range<Int>? {
        var lowerBound: Int?
        var upperBound: Int?
        var timelineFrame = 0
        for segment in segments {
            let segmentStart = timelineFrame
            timelineFrame += segment.frameCount
            guard segment.clipID == id else {
                if lowerBound != nil {
                    break
                }
                continue
            }
            lowerBound = lowerBound ?? segmentStart
            upperBound = timelineFrame
        }
        guard let lowerBound, let upperBound, upperBound > lowerBound else {
            return nil
        }
        return lowerBound..<upperBound
    }

    public func segments(forClipID id: AudioTimelineClipID) -> [AudioTimelineSegment] {
        guard let range = frameRange(forClipID: id) else {
            return []
        }
        return segments(in: range)
    }

    public func clampedLocalFrameRange(
        _ requestedRange: Range<Int>,
        forClipID id: AudioTimelineClipID
    ) -> Range<Int>? {
        guard let clipRange = frameRange(forClipID: id) else {
            return nil
        }
        let lower = min(max(requestedRange.lowerBound, 0), clipRange.count)
        let upper = min(max(requestedRange.upperBound, lower), clipRange.count)
        return lower..<upper
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
            output.append(output.isEmpty
                ? selected.withClipBoundary(true, clipID: selected.clipID)
                : selected)
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

    @discardableResult
    public mutating func deleteClip(id: AudioTimelineClipID) -> Int {
        guard let range = frameRange(forClipID: id) else {
            return 0
        }
        return delete(frameRange: range)
    }

    /// Deletes several clips as one arrangement mutation. Source ranges are
    /// removed from right to left so every requested clip is resolved against
    /// the same pre-edit timeline and the remaining material ripples once.
    @discardableResult
    public mutating func deleteClips(ids: Set<AudioTimelineClipID>) -> Int {
        let ranges = ids.compactMap { id in
            frameRange(forClipID: id).map { (id: id, range: $0) }
        }
        guard ranges.count == ids.count, !ranges.isEmpty else {
            return 0
        }

        var working = self
        var removed = 0
        for item in ranges.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let count = working.deleteClip(id: item.id)
            guard count == item.range.count else {
                return 0
            }
            removed += count
        }
        self = working
        return removed
    }

    @discardableResult
    public mutating func deleteWithinClip(
        id: AudioTimelineClipID,
        localFrameRange requestedLocalRange: Range<Int>,
        followingClipPolicy: AudioTimelineFollowingClipPolicy
    ) -> Int {
        guard
            let clipRange = frameRange(forClipID: id),
            let localRange = clampedLocalFrameRange(requestedLocalRange, forClipID: id),
            !localRange.isEmpty
        else {
            return 0
        }

        let globalLowerBound = clipRange.lowerBound + localRange.lowerBound
        let globalUpperBound = clipRange.lowerBound + localRange.upperBound
        let globalRange = globalLowerBound..<globalUpperBound
        let removed = delete(frameRange: globalRange)
        guard removed > 0, followingClipPolicy == .preserveTimelinePositions else {
            return removed
        }

        let insertionFrame: Int
        if let remainingClipRange = frameRange(forClipID: id) {
            insertionFrame = remainingClipRange.upperBound
        } else {
            insertionFrame = min(clipRange.lowerBound, frameCount)
        }
        _ = insertSilentClip(frameCount: removed, atFrame: insertionFrame)
        return removed
    }

    @discardableResult
    public mutating func clearWithinClip(
        id: AudioTimelineClipID,
        localFrameRange requestedLocalRange: Range<Int>
    ) -> Int {
        guard
            let clipRange = frameRange(forClipID: id),
            let localRange = clampedLocalFrameRange(requestedLocalRange, forClipID: id),
            !localRange.isEmpty
        else {
            return 0
        }
        let globalLowerBound = clipRange.lowerBound + localRange.lowerBound
        let globalUpperBound = clipRange.lowerBound + localRange.upperBound
        return clear(frameRange: globalLowerBound..<globalUpperBound)
    }

    @discardableResult
    public mutating func insertWithinClip(
        id: AudioTimelineClipID,
        localFrame requestedLocalFrame: Int,
        segments replacementSegments: [AudioTimelineSegment]
    ) -> Int? {
        guard let clipRange = frameRange(forClipID: id) else {
            return nil
        }
        let localFrame = min(max(requestedLocalFrame, 0), clipRange.count)
        let replacements = Self.validatedSegments(
            replacementSegments,
            sourceFrameCount: sourceFrameCount
        ).map { segment in
            segment.withClipID(id, startsNewClip: false)
        }
        guard !replacements.isEmpty else {
            return nil
        }
        return insert(replacements, atFrame: clipRange.lowerBound + localFrame)
    }

    @discardableResult
    public mutating func duplicateClip(
        id: AudioTimelineClipID,
        atFrame requestedFrame: Int
    ) -> AudioTimelineClipID? {
        let clipSegments = segments(forClipID: id)
        guard !clipSegments.isEmpty else {
            return nil
        }
        let duplicateID = AudioTimelineClipID()
        let duplicate = clipSegments.enumerated().map { index, segment in
            segment.withClipID(duplicateID, startsNewClip: index == 0)
        }
        guard insert(duplicate, atFrame: requestedFrame) != nil else {
            return nil
        }
        return duplicateID
    }

    @discardableResult
    public mutating func moveClip(
        id: AudioTimelineClipID,
        toFrame requestedFrame: Int
    ) -> Range<Int>? {
        guard let originalRange = frameRange(forClipID: id) else {
            return nil
        }
        let clipSegments = segments(in: originalRange)
        guard !clipSegments.isEmpty else {
            return nil
        }
        let destinationBeforeRemoval = min(max(requestedFrame, 0), frameCount)
        if destinationBeforeRemoval >= originalRange.lowerBound,
           destinationBeforeRemoval <= originalRange.upperBound {
            return originalRange
        }

        _ = delete(frameRange: originalRange)
        let destination = destinationBeforeRemoval > originalRange.upperBound
            ? destinationBeforeRemoval - originalRange.count
            : destinationBeforeRemoval
        guard insert(clipSegments, atFrame: destination) != nil else {
            return nil
        }
        return destination..<(destination + originalRange.count)
    }

    /// Relocates a clip without rippling any other timeline content.
    ///
    /// The source range becomes silence and the destination must contain only
    /// silence. Moving beyond the current end extends the arrangement with
    /// silence. The operation is transactional: a blocked destination leaves
    /// the arrangement unchanged.
    @discardableResult
    public mutating func relocateClip(
        id: AudioTimelineClipID,
        toFrame requestedFrame: Int
    ) -> Range<Int>? {
        guard let originalRange = frameRange(forClipID: id) else {
            return nil
        }
        let clipSegments = segments(in: originalRange)
        guard !clipSegments.isEmpty else {
            return nil
        }

        let destination = max(requestedFrame, 0)
        if destination == originalRange.lowerBound {
            return originalRange
        }

        var working = self
        _ = working.delete(frameRange: originalRange)
        guard working.insertSilentClip(
            frameCount: originalRange.count,
            atFrame: originalRange.lowerBound
        ) == originalRange.count else {
            return nil
        }

        let destinationEnd = destination + originalRange.count
        if destinationEnd > working.frameCount {
            let extensionFrameCount = destinationEnd - working.frameCount
            guard working.insertSilentClip(
                frameCount: extensionFrameCount,
                atFrame: working.frameCount
            ) == extensionFrameCount else {
                return nil
            }
        }

        let destinationRange = destination..<destinationEnd
        let destinationIsSilent = working.segments(in: destinationRange).allSatisfy {
            $0.gainStart == 0 && $0.gainEnd == 0
        }
        guard destinationIsSilent,
              working.replace(frameRange: destinationRange, with: clipSegments) == originalRange.count
        else {
            return nil
        }

        self = working
        return destinationRange
    }

    /// Relocates clips by a shared frame delta while preserving their spacing.
    /// All source and destination checks happen on a working copy, so a single
    /// occupied destination rejects the entire group without a partial move.
    @discardableResult
    public mutating func relocateClips(
        ids: Set<AudioTimelineClipID>,
        byFrames delta: Int
    ) -> [AudioTimelineClipID: Range<Int>]? {
        guard !ids.isEmpty else {
            return nil
        }
        let originals = ids.compactMap { id in
            frameRange(forClipID: id).map { (id: id, range: $0, segments: segments(forClipID: id)) }
        }
        guard
            originals.count == ids.count,
            originals.allSatisfy({ !$0.segments.isEmpty }),
            originals.allSatisfy({ $0.range.lowerBound + delta >= 0 })
        else {
            return nil
        }
        if delta == 0 {
            return Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0.range) })
        }

        var working = self
        for item in originals.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard
                working.delete(frameRange: item.range) == item.range.count,
                working.insertSilentClip(
                    frameCount: item.range.count,
                    atFrame: item.range.lowerBound
                ) == item.range.count
            else {
                return nil
            }
        }

        let maximumEnd = originals.map { $0.range.upperBound + delta }.max() ?? working.frameCount
        if maximumEnd > working.frameCount {
            guard working.insertSilentClip(
                frameCount: maximumEnd - working.frameCount,
                atFrame: working.frameCount
            ) == maximumEnd - working.frameCount else {
                return nil
            }
        }

        var relocated: [AudioTimelineClipID: Range<Int>] = [:]
        for item in originals.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let destination = (item.range.lowerBound + delta)..<(item.range.upperBound + delta)
            guard
                working.segments(in: destination).allSatisfy({ $0.gainStart == 0 && $0.gainEnd == 0 }),
                working.replace(frameRange: destination, with: item.segments) == destination.count
            else {
                return nil
            }
            relocated[item.id] = destination
        }

        self = working
        return relocated
    }

    @discardableResult
    public mutating func splitClip(
        id: AudioTimelineClipID,
        atLocalFrame requestedLocalFrame: Int
    ) -> AudioTimelineClipID? {
        guard let range = frameRange(forClipID: id) else {
            return nil
        }
        let localFrame = min(max(requestedLocalFrame, 1), range.count - 1)
        let splitFrame = range.lowerBound + localFrame
        guard split(atFrame: splitFrame) else {
            return nil
        }
        return segments.first(where: { $0.clipID != id && frameRange(forClipID: $0.clipID)?.lowerBound == splitFrame })?.clipID
    }

    /// Trims the leading edge without moving the clip or any following clips.
    /// The removed portion becomes a distinct silent clip in the arrangement.
    @discardableResult
    public mutating func trimClipStart(
        id: AudioTimelineClipID,
        toLocalFrame requestedLocalFrame: Int
    ) -> Int {
        guard let originalRange = frameRange(forClipID: id), originalRange.count > 1 else {
            return 0
        }
        let removedCount = min(max(requestedLocalFrame, 0), originalRange.count - 1)
        guard removedCount > 0 else {
            return 0
        }

        let removed = delete(frameRange: originalRange.lowerBound..<(originalRange.lowerBound + removedCount))
        guard removed > 0 else {
            return 0
        }
        _ = insertSilentClip(frameCount: removed, atFrame: originalRange.lowerBound)
        return removed
    }

    /// Trims the trailing edge without moving the clip or any following clips.
    /// The removed portion becomes a distinct silent clip in the arrangement.
    @discardableResult
    public mutating func trimClipEnd(
        id: AudioTimelineClipID,
        toLocalFrame requestedLocalFrame: Int
    ) -> Int {
        guard let originalRange = frameRange(forClipID: id), originalRange.count > 1 else {
            return 0
        }
        let retainedCount = min(max(requestedLocalFrame, 1), originalRange.count)
        let removedCount = originalRange.count - retainedCount
        guard removedCount > 0 else {
            return 0
        }

        let trimStart = originalRange.lowerBound + retainedCount
        let removed = delete(frameRange: trimStart..<originalRange.upperBound)
        guard removed > 0 else {
            return 0
        }
        _ = insertSilentClip(frameCount: removed, atFrame: trimStart)
        return removed
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
                startsNewClip: silence.isEmpty,
                clipID: silence.first?.clipID ?? AudioTimelineClipID()
            ))
            remaining -= chunk
        }

        return insert(silence, atFrame: insertionFrame) ?? 0
    }

    @discardableResult
    private mutating func insertSilentClip(
        frameCount requestedFrameCount: Int,
        atFrame requestedFrame: Int
    ) -> Int {
        guard requestedFrameCount > 0, sourceFrameCount > 0 else {
            return 0
        }
        let clipID = AudioTimelineClipID()
        var remaining = requestedFrameCount
        var silence: [AudioTimelineSegment] = []
        while remaining > 0 {
            let count = min(remaining, sourceFrameCount)
            silence.append(AudioTimelineSegment(
                sourceStartFrame: 0,
                frameCount: count,
                gainStart: 0,
                gainEnd: 0,
                startsNewClip: silence.isEmpty,
                clipID: clipID
            ))
            remaining -= count
        }
        return insert(silence, atFrame: min(max(requestedFrame, 0), frameCount)) ?? 0
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

        let mergedClipID = segments[nearestIndex - 1].clipID
        var index = nearestIndex
        while index < segments.count {
            if index > nearestIndex, segments[index].startsNewClip {
                break
            }
            segments[index] = segments[index].withClipID(
                mergedClipID,
                startsNewClip: false
            )
            index += 1
        }
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
                startsNewClip: offset == 0 && segment.startsNewClip,
                clipID: segment.clipID
            )
        }
        return AudioTimelineSegment(
            sourceStartFrame: segment.sourceStartFrame + offset,
            frameCount: count,
            gainStart: segment.gain(at: offset),
            gainEnd: segment.gain(at: offset + count - 1),
            startsNewClip: offset == 0 && segment.startsNewClip,
            clipID: segment.clipID
        )
    }

    static func coalescedSegments(
        _ input: [AudioTimelineSegment]
    ) -> [AudioTimelineSegment] {
        var result: [AudioTimelineSegment] = []
        result.reserveCapacity(input.count)
        for rawSegment in input where rawSegment.frameCount > 0 {
            let segment = result.isEmpty
                ? rawSegment.withClipBoundary(false)
                : rawSegment.withClipBoundary(
                    rawSegment.startsNewClip || rawSegment.clipID != result.last?.clipID,
                    clipID: rawSegment.clipID
                )
            guard let previous = result.last else {
                result.append(segment)
                continue
            }
            if
                !segment.startsNewClip,
                previous.clipID == segment.clipID,
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
                    startsNewClip: previous.startsNewClip,
                    clipID: previous.clipID
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
        var activeClipID: AudioTimelineClipID?
        let validated = input.compactMap { segment -> AudioTimelineSegment? in
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
            if activeClipID == nil || segment.startsNewClip {
                activeClipID = segment.clipID
            }
            return AudioTimelineSegment(
                sourceStartFrame: segment.sourceStartFrame,
                frameCount: count,
                gainStart: segment.gainStart,
                gainEnd: segment.gainEnd,
                startsNewClip: segment.startsNewClip,
                clipID: activeClipID ?? segment.clipID
            )
        }
        return coalescedSegments(validated)
    }
}
