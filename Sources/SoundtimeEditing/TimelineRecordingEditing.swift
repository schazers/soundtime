import Foundation

public struct TimelineRecordingOverwriteResult: Equatable, Sendable {
    public let graph: TimelineClipGraph
    public let clip: TimelineClip
    public let overwrittenRange: TimelineFrameRange

    public init(graph: TimelineClipGraph, clip: TimelineClip, overwrittenRange: TimelineFrameRange) {
        self.graph = graph
        self.clip = clip
        self.overwrittenRange = overwrittenRange
    }
}

/// Commits a recorded take as a non-destructive punch-in edit.
/// Existing media outside the recorded interval remains untouched.
public enum TimelineRecordingEditingService {
    public static func overwrite(
        trackID: UUID,
        timelineStartFrame: Int,
        source: TimelineMediaSource,
        clipID: AudioTimelineClipID = AudioTimelineClipID(),
        clipName: String,
        in graph: TimelineClipGraph,
        expectedRevision: UInt64
    ) throws -> TimelineRecordingOverwriteResult {
        guard graph.revision == expectedRevision else {
            throw TimelineClipGraphError.staleRevision(expected: expectedRevision, actual: graph.revision)
        }
        try source.validate()
        let timelineFrameCount = max(Int(
            (Double(source.frameCount) / source.sampleRate * graph.timelineSampleRate).rounded()
        ), 1)
        let overwriteRange = TimelineFrameRange(
            startFrame: max(timelineStartFrame, 0),
            frameCount: timelineFrameCount
        )
        let cleared = try TimelineClipRangeEditingService.apply(
            range: overwriteRange,
            toTrackIDs: [trackID],
            mode: .clearGap,
            in: graph,
            expectedRevision: graph.revision
        )
        let inserted = try TimelineMediaInsertionService.insert(
            TimelineMediaInsertionRequest(
                trackID: trackID,
                source: source,
                timelineStartFrame: overwriteRange.startFrame,
                timelineFrameCount: overwriteRange.frameCount,
                clipID: clipID,
                clipName: clipName
            ),
            into: cleared.graph,
            expectedRevision: cleared.graph.revision
        )
        guard let clip = inserted.graph.track(id: trackID)?.clip(id: clipID) else {
            throw TimelineClipGraphError.missingClip(clipID)
        }
        return TimelineRecordingOverwriteResult(
            graph: inserted.graph,
            clip: clip,
            overwrittenRange: overwriteRange
        )
    }
}
