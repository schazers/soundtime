import Foundation

public enum TimelineClipRangeEditMode: Equatable, Sendable {
    case clearGap
    case rippleDelete
}

public struct TimelineClipTransferFragment: Equatable, Codable, Sendable {
    public let source: TimelineMediaSource
    public let sourceRange: TimelineFrameRange
    public let relativeTimelineStartFrame: Int
    public let timelineFrameCount: Int
    public let name: String
    public let gain: Float
    public let gainEnvelope: TimelineClipGainEnvelope
    public let fades: TimelineClipFades
    public let isMuted: Bool
    public let colorToken: String?
    public let metadata: [String: String]

    public init(
        source: TimelineMediaSource,
        sourceRange: TimelineFrameRange,
        relativeTimelineStartFrame: Int,
        timelineFrameCount: Int,
        name: String,
        gain: Float = 1,
        gainEnvelope: TimelineClipGainEnvelope = TimelineClipGainEnvelope(),
        fades: TimelineClipFades = TimelineClipFades(),
        isMuted: Bool = false,
        colorToken: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.source = source
        self.sourceRange = sourceRange
        self.relativeTimelineStartFrame = relativeTimelineStartFrame
        self.timelineFrameCount = timelineFrameCount
        self.name = name
        self.gain = gain
        self.gainEnvelope = gainEnvelope
        self.fades = fades
        self.isMuted = isMuted
        self.colorToken = colorToken
        self.metadata = metadata
    }
}

public struct TimelineClipTransferPayload: Equatable, Codable, Sendable {
    public let timelineSampleRate: Double
    public let frameCount: Int
    public let fragments: [TimelineClipTransferFragment]

    public init(
        timelineSampleRate: Double,
        frameCount: Int,
        fragments: [TimelineClipTransferFragment]
    ) {
        self.timelineSampleRate = timelineSampleRate
        self.frameCount = frameCount
        self.fragments = fragments
    }
}

public enum TimelineClipRangeEditingService {
    public static func capture(
        range: TimelineFrameRange,
        trackID: UUID,
        in graph: TimelineClipGraph
    ) throws -> TimelineClipTransferPayload {
        guard let track = graph.track(id: trackID) else {
            throw TimelineClipGraphError.missingTrack(trackID)
        }
        let fragments = try track.clips.compactMap { clip -> TimelineClipTransferFragment? in
            guard let intersection = intersection(clip.timelineRange, range) else { return nil }
            guard let source = graph.source(id: clip.sourceID) else {
                throw TimelineClipGraphError.missingSource(clip.sourceID)
            }
            let sourceRange = mappedSourceRange(for: clip, timelineRange: intersection)
            return TimelineClipTransferFragment(
                source: source,
                sourceRange: sourceRange,
                relativeTimelineStartFrame: intersection.startFrame - range.startFrame,
                timelineFrameCount: intersection.frameCount,
                name: clip.name,
                gain: clip.gain,
                gainEnvelope: clippedEnvelope(for: clip, timelineRange: intersection),
                fades: clippedFades(for: clip, timelineRange: intersection),
                isMuted: clip.isMuted,
                colorToken: clip.colorToken,
                metadata: clip.metadata
            )
        }
        return TimelineClipTransferPayload(
            timelineSampleRate: graph.timelineSampleRate,
            frameCount: range.frameCount,
            fragments: fragments
        )
    }

    public static func apply(
        range: TimelineFrameRange,
        toTrackIDs trackIDs: Set<UUID>,
        mode: TimelineClipRangeEditMode,
        in graph: TimelineClipGraph,
        expectedRevision: UInt64
    ) throws -> TimelineClipCommandResult {
        guard graph.revision == expectedRevision else {
            throw TimelineClipGraphError.staleRevision(
                expected: expectedRevision,
                actual: graph.revision
            )
        }
        guard range.startFrame >= 0, range.frameCount > 0 else {
            throw TimelineClipGraphError.invalidTimelineSampleRate
        }
        var replacements: [TimelineTrack] = []
        var affectedClipIDs = Set<AudioTimelineClipID>()
        for trackID in trackIDs {
            guard let track = graph.track(id: trackID) else {
                throw TimelineClipGraphError.missingTrack(trackID)
            }
            let result = try editing(track: track, range: range, mode: mode)
            replacements.append(result.track)
            affectedClipIDs.formUnion(result.affectedClipIDs)
        }
        var editedGraph = graph
        try editedGraph.replaceAffectedTracks(
            ids: trackIDs,
            with: replacements,
            revision: graph.revision &+ 1
        )
        if mode == .rippleDelete,
           let explicitEndFrame = graph.explicitEndFrame,
           range.startFrame < explicitEndFrame {
            editedGraph.explicitEndFrame = max(
                range.startFrame,
                explicitEndFrame - min(range.frameCount, explicitEndFrame - range.startFrame)
            )
        }
        return TimelineClipCommandResult(
            graph: editedGraph,
            affectedTrackIDs: trackIDs,
            beforeTracks: graph.tracks.filter { trackIDs.contains($0.id) },
            afterTracks: replacements,
            affectedClipIDs: affectedClipIDs,
            beforeExplicitEndFrame: graph.explicitEndFrame,
            afterExplicitEndFrame: editedGraph.explicitEndFrame
        )
    }

    public static func insertionRequests(
        for payload: TimelineClipTransferPayload,
        trackID: UUID,
        timelineStartFrame: Int
    ) -> [TimelineMediaInsertionRequest] {
        let scale = payload.timelineSampleRate > 0 ? payload.timelineSampleRate : 1
        return payload.fragments.map { fragment in
            let relativeSeconds = Double(fragment.relativeTimelineStartFrame) / scale
            return TimelineMediaInsertionRequest(
                trackID: trackID,
                source: fragment.source,
                sourceRange: fragment.sourceRange,
                timelineStartFrame: timelineStartFrame + Int((relativeSeconds * scale).rounded()),
                timelineFrameCount: fragment.timelineFrameCount,
                clipID: AudioTimelineClipID(),
                clipName: fragment.name,
                gain: fragment.gain,
                gainEnvelope: fragment.gainEnvelope,
                fades: fragment.fades,
                isMuted: fragment.isMuted,
                colorToken: fragment.colorToken,
                clipMetadata: fragment.metadata
            )
        }
    }

    private static func editing(
        track: TimelineTrack,
        range: TimelineFrameRange,
        mode: TimelineClipRangeEditMode
    ) throws -> (track: TimelineTrack, affectedClipIDs: Set<AudioTimelineClipID>) {
        var clips: [TimelineClip] = []
        var affected = Set<AudioTimelineClipID>()
        for clip in track.clips {
            guard intersection(clip.timelineRange, range) != nil else {
                var unchanged = clip
                if mode == .rippleDelete, clip.timelineRange.startFrame >= range.endFrame {
                    unchanged.timelineRange.startFrame -= range.frameCount
                    affected.insert(clip.id)
                }
                clips.append(unchanged)
                continue
            }
            guard !clip.isLocked else {
                throw TimelineClipGraphError.lockedClip(clip.id)
            }
            affected.insert(clip.id)
            let leftCount = max(min(range.startFrame, clip.timelineRange.endFrame) - clip.timelineRange.startFrame, 0)
            let rightStart = max(range.endFrame, clip.timelineRange.startFrame)
            let rightCount = max(clip.timelineRange.endFrame - rightStart, 0)
            let names = AudioTimelineClipSplitNames.derived(from: clip.name)

            if leftCount > 0 {
                var left = clip
                left.timelineRange.frameCount = leftCount
                left.sourceRange = mappedSourceRange(for: clip, timelineRange: left.timelineRange)
                left.name = rightCount > 0 ? names.left : clip.name
                left.fades = clippedFades(for: clip, timelineRange: left.timelineRange)
                left.gainEnvelope = clippedEnvelope(for: clip, timelineRange: left.timelineRange)
                clips.append(left)
            }
            if rightCount > 0 {
                let originalRange = TimelineFrameRange(startFrame: rightStart, frameCount: rightCount)
                let destinationStart = mode == .rippleDelete ? rightStart - range.frameCount : rightStart
                let right = TimelineClip(
                    id: leftCount > 0 ? AudioTimelineClipID() : clip.id,
                    sourceID: clip.sourceID,
                    timelineRange: TimelineFrameRange(startFrame: destinationStart, frameCount: rightCount),
                    sourceRange: mappedSourceRange(for: clip, timelineRange: originalRange),
                    name: leftCount > 0 ? names.right : clip.name,
                    gain: clip.gain,
                    gainEnvelope: clippedEnvelope(for: clip, timelineRange: originalRange),
                    fades: clippedFades(for: clip, timelineRange: originalRange),
                    isMuted: clip.isMuted,
                    isLocked: clip.isLocked,
                    colorToken: clip.colorToken,
                    metadata: clip.metadata
                )
                clips.append(right)
                affected.insert(right.id)
            }
        }
        var edited = track
        edited.replaceClips(clips)
        return (edited, affected)
    }

    private static func intersection(
        _ lhs: TimelineFrameRange,
        _ rhs: TimelineFrameRange
    ) -> TimelineFrameRange? {
        let start = max(lhs.startFrame, rhs.startFrame)
        let end = min(lhs.endFrame, rhs.endFrame)
        guard end > start else { return nil }
        return TimelineFrameRange(startFrame: start, frameCount: end - start)
    }

    private static func mappedSourceRange(
        for clip: TimelineClip,
        timelineRange: TimelineFrameRange
    ) -> TimelineFrameRange {
        let startOffset = timelineRange.startFrame - clip.timelineRange.startFrame
        let endOffset = timelineRange.endFrame - clip.timelineRange.startFrame
        let sourceStart = clip.sourceRange.startFrame + Int((Double(startOffset) * clip.sourceFrameScale).rounded())
        let sourceEnd = clip.sourceRange.startFrame + Int((Double(endOffset) * clip.sourceFrameScale).rounded())
        return TimelineFrameRange(
            startFrame: sourceStart,
            frameCount: max(sourceEnd - sourceStart, 1)
        )
    }

    private static func clippedFades(
        for clip: TimelineClip,
        timelineRange: TimelineFrameRange
    ) -> TimelineClipFades {
        let keepsLeadingEdge = timelineRange.startFrame == clip.timelineRange.startFrame
        let keepsTrailingEdge = timelineRange.endFrame == clip.timelineRange.endFrame
        return TimelineClipFades(
            fadeInFrames: keepsLeadingEdge ? min(clip.fades.fadeInFrames, timelineRange.frameCount) : 0,
            fadeOutFrames: keepsTrailingEdge ? min(clip.fades.fadeOutFrames, timelineRange.frameCount) : 0
        )
    }

    private static func clippedEnvelope(
        for clip: TimelineClip,
        timelineRange: TimelineFrameRange
    ) -> TimelineClipGainEnvelope {
        guard clip.timelineRange.frameCount > 0 else { return clip.gainEnvelope }
        func value(at frame: Int) -> Float {
            let progress = Float(frame - clip.timelineRange.startFrame) / Float(clip.timelineRange.frameCount)
            return clip.gainEnvelope.startMultiplier +
                (clip.gainEnvelope.endMultiplier - clip.gainEnvelope.startMultiplier) * progress
        }
        return TimelineClipGainEnvelope(
            startMultiplier: value(at: timelineRange.startFrame),
            endMultiplier: value(at: timelineRange.endFrame)
        )
    }
}
