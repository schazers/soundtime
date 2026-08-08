import Foundation

public enum TimelineClipRangeEffect: Equatable, Sendable {
    case gain(Float)
    case fadeIn
    case fadeOut
}

public enum TimelineClipEffectsService {
    public static func apply(
        _ effect: TimelineClipRangeEffect,
        range: TimelineFrameRange,
        trackID: UUID,
        in graph: TimelineClipGraph,
        expectedRevision: UInt64
    ) throws -> TimelineClipCommandResult {
        guard expectedRevision == graph.revision else {
            throw TimelineClipGraphError.staleRevision(expected: expectedRevision, actual: graph.revision)
        }
        guard var track = graph.track(id: trackID) else {
            throw TimelineClipGraphError.missingTrack(trackID)
        }
        let beforeTrack = track
        var output: [TimelineClip] = []
        var affected = Set<AudioTimelineClipID>()

        for clip in track.clips {
            let intersectionStart = max(clip.timelineRange.startFrame, range.startFrame)
            let intersectionEnd = min(clip.timelineRange.endFrame, range.endFrame)
            guard intersectionStart < intersectionEnd else {
                output.append(clip)
                continue
            }
            let pieces = split(clip, at: intersectionStart, and: intersectionEnd)
            for var piece in pieces {
                if piece.timelineRange.startFrame >= intersectionStart,
                   piece.timelineRange.endFrame <= intersectionEnd {
                    affected.insert(piece.id)
                    switch effect {
                    case let .gain(multiplier):
                        piece.gain *= max(multiplier, 0)
                    case .fadeIn:
                        let start = multiplier(at: piece.timelineRange.startFrame, in: range, fadesIn: true)
                        let end = multiplier(at: piece.timelineRange.endFrame, in: range, fadesIn: true)
                        piece.gainEnvelope.startMultiplier *= start
                        piece.gainEnvelope.endMultiplier *= end
                    case .fadeOut:
                        let start = multiplier(at: piece.timelineRange.startFrame, in: range, fadesIn: false)
                        let end = multiplier(at: piece.timelineRange.endFrame, in: range, fadesIn: false)
                        piece.gainEnvelope.startMultiplier *= start
                        piece.gainEnvelope.endMultiplier *= end
                    }
                }
                output.append(piece)
            }
        }
        guard !affected.isEmpty else {
            return TimelineClipCommandResult(
                graph: graph,
                affectedTrackIDs: [],
                beforeTracks: [],
                afterTracks: [],
                affectedClipIDs: [],
                beforeExplicitEndFrame: graph.explicitEndFrame,
                afterExplicitEndFrame: graph.explicitEndFrame
            )
        }
        track.replaceClips(output)
        var editedGraph = graph
        try editedGraph.replaceAffectedTracks(
            ids: [trackID],
            with: [track],
            revision: graph.revision &+ 1
        )
        return TimelineClipCommandResult(
            graph: editedGraph,
            affectedTrackIDs: [trackID],
            beforeTracks: [beforeTrack],
            afterTracks: [track],
            affectedClipIDs: affected,
            beforeExplicitEndFrame: graph.explicitEndFrame,
            afterExplicitEndFrame: editedGraph.explicitEndFrame
        )
    }

    public static func rippleDelete(
        ranges: [TimelineFrameRange],
        trackID: UUID,
        in graph: TimelineClipGraph,
        expectedRevision: UInt64
    ) throws -> TimelineClipCommandResult {
        guard expectedRevision == graph.revision else {
            throw TimelineClipGraphError.staleRevision(expected: expectedRevision, actual: graph.revision)
        }
        var working = graph
        let beforeTrack = graph.track(id: trackID)
        var affected = Set<AudioTimelineClipID>()
        for range in ranges.sorted(by: { $0.startFrame > $1.startFrame }) where range.frameCount > 0 {
            let result = try TimelineClipRangeEditingService.apply(
                range: range,
                toTrackIDs: [trackID],
                mode: .rippleDelete,
                in: working,
                expectedRevision: working.revision
            )
            working = result.graph
            affected.formUnion(result.affectedClipIDs)
        }
        guard let beforeTrack, let afterTrack = working.track(id: trackID), beforeTrack != afterTrack else {
            return TimelineClipCommandResult(
                graph: graph,
                affectedTrackIDs: [],
                beforeTracks: [],
                afterTracks: [],
                affectedClipIDs: [],
                beforeExplicitEndFrame: graph.explicitEndFrame,
                afterExplicitEndFrame: graph.explicitEndFrame
            )
        }
        return TimelineClipCommandResult(
            graph: working,
            affectedTrackIDs: [trackID],
            beforeTracks: [beforeTrack],
            afterTracks: [afterTrack],
            affectedClipIDs: affected,
            beforeExplicitEndFrame: graph.explicitEndFrame,
            afterExplicitEndFrame: working.explicitEndFrame
        )
    }

    private static func split(_ clip: TimelineClip, at start: Int, and end: Int) -> [TimelineClip] {
        let boundaries = [clip.timelineRange.startFrame, start, end, clip.timelineRange.endFrame]
            .filter { $0 >= clip.timelineRange.startFrame && $0 <= clip.timelineRange.endFrame }
        let sorted = Array(Set(boundaries)).sorted()
        return zip(sorted, sorted.dropFirst()).enumerated().compactMap { index, pair in
            let (lower, upper) = pair
            guard lower < upper else { return nil }
            let sourceScale = clip.sourceFrameScale
            let sourceStart = clip.sourceRange.startFrame + Int((Double(lower - clip.timelineRange.startFrame) * sourceScale).rounded())
            let sourceEnd = clip.sourceRange.startFrame + Int((Double(upper - clip.timelineRange.startFrame) * sourceScale).rounded())
            var piece = clip
            if index > 0 { piece = TimelineClip(
                sourceID: clip.sourceID,
                timelineRange: TimelineFrameRange(startFrame: lower, frameCount: upper - lower),
                sourceRange: TimelineFrameRange(startFrame: sourceStart, frameCount: max(sourceEnd - sourceStart, 1)),
                name: clip.name,
                gain: clip.gain,
                gainEnvelope: envelope(for: clip, lower: lower, upper: upper),
                fades: fades(for: clip, lower: lower, upper: upper),
                isMuted: clip.isMuted,
                isLocked: clip.isLocked,
                colorToken: clip.colorToken,
                metadata: clip.metadata
            ) } else {
                piece.timelineRange = TimelineFrameRange(startFrame: lower, frameCount: upper - lower)
                piece.sourceRange = TimelineFrameRange(startFrame: sourceStart, frameCount: max(sourceEnd - sourceStart, 1))
                piece.gainEnvelope = envelope(for: clip, lower: lower, upper: upper)
                piece.fades = fades(for: clip, lower: lower, upper: upper)
            }
            return piece
        }
    }

    private static func envelope(for clip: TimelineClip, lower: Int, upper: Int) -> TimelineClipGainEnvelope {
        func value(_ frame: Int) -> Float {
            let p = Float(frame - clip.timelineRange.startFrame) / Float(max(clip.timelineRange.frameCount, 1))
            return clip.gainEnvelope.startMultiplier + (clip.gainEnvelope.endMultiplier - clip.gainEnvelope.startMultiplier) * p
        }
        return TimelineClipGainEnvelope(startMultiplier: value(lower), endMultiplier: value(upper))
    }

    private static func fades(for clip: TimelineClip, lower: Int, upper: Int) -> TimelineClipFades {
        TimelineClipFades(
            fadeInFrames: lower == clip.timelineRange.startFrame ? min(clip.fades.fadeInFrames, upper - lower) : 0,
            fadeOutFrames: upper == clip.timelineRange.endFrame ? min(clip.fades.fadeOutFrames, upper - lower) : 0
        )
    }

    private static func multiplier(at frame: Int, in range: TimelineFrameRange, fadesIn: Bool) -> Float {
        let progress = Float(frame - range.startFrame) / Float(max(range.frameCount, 1))
        let clamped = min(max(progress, 0), 1)
        return fadesIn ? clamped : 1 - clamped
    }
}
