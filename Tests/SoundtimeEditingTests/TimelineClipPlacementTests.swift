import Foundation
import Testing
@testable import SoundtimeEditing

@Suite("Timeline clip placement")
struct TimelineClipPlacementTests {
    @Test("Preview and commit reject the same occupied destination")
    func previewAndCommitAgree() throws {
        let fixture = try makeFixture()
        let placement = TimelineClipPlacement(
            clipID: fixture.movingClipID,
            destinationTrackID: fixture.trackID,
            timelineRange: TimelineFrameRange(startFrame: 2_500, frameCount: 1_000)
        )
        let decision = try TimelineClipPlacementValidator.evaluate([placement], in: fixture.graph)
        #expect(decision == .rejected([TimelineClipPlacementConflict(
            trackID: fixture.trackID,
            movingClipID: fixture.movingClipID,
            conflictingClipID: fixture.stationaryClipID
        )]))

        #expect(throws: TimelineClipGraphError.destinationOccupied(
            trackID: fixture.trackID,
            conflicts: [fixture.stationaryClipID]
        )) {
            try TimelineClipCommandExecutor.apply(
                .move([TimelineClipMove(
                    clipID: fixture.movingClipID,
                    destinationTrackID: fixture.trackID,
                    destinationStartFrame: 2_500
                )]),
                to: fixture.graph,
                expectedRevision: fixture.graph.revision
            )
        }
        #expect(fixture.graph.track(id: fixture.trackID)?.clip(id: fixture.movingClipID)?.timelineRange.startFrame == 0)
    }

    @Test("Clips may touch exactly at their boundaries")
    func touchingBoundariesAreAllowed() throws {
        let fixture = try makeFixture()
        let placement = TimelineClipPlacement(
            clipID: fixture.movingClipID,
            destinationTrackID: fixture.trackID,
            timelineRange: TimelineFrameRange(startFrame: 2_000, frameCount: 1_000)
        )
        #expect(try TimelineClipPlacementValidator.evaluate([placement], in: fixture.graph) == .allowed)
        let result = try TimelineClipCommandExecutor.apply(
            .move([TimelineClipMove(
                clipID: fixture.movingClipID,
                destinationTrackID: fixture.trackID,
                destinationStartFrame: 2_000
            )]),
            to: fixture.graph,
            expectedRevision: fixture.graph.revision
        )
        #expect(result.graph.track(id: fixture.trackID)?.clips.map(\.timelineRange.startFrame) == [2_000, 3_000])
    }

    @Test("Multi-clip placement rejects overlap between moving clips")
    func movingClipsCannotOverlapEachOther() throws {
        let fixture = try makeFixture()
        let decision = try TimelineClipPlacementValidator.evaluate([
            TimelineClipPlacement(
                clipID: fixture.movingClipID,
                destinationTrackID: fixture.trackID,
                timelineRange: TimelineFrameRange(startFrame: 5_000, frameCount: 1_000)
            ),
            TimelineClipPlacement(
                clipID: fixture.stationaryClipID,
                destinationTrackID: fixture.trackID,
                timelineRange: TimelineFrameRange(startFrame: 5_500, frameCount: 1_000)
            )
        ], in: fixture.graph)
        guard case let .rejected(conflicts) = decision else {
            Issue.record("Expected overlapping moving clips to be rejected")
            return
        }
        #expect(conflicts.count == 1)
    }

    private func makeFixture() throws -> (
        graph: TimelineClipGraph,
        trackID: UUID,
        movingClipID: AudioTimelineClipID,
        stationaryClipID: AudioTimelineClipID
    ) {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "source"),
            frameCount: 20_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let trackID = UUID(uuidString: "a0000000-0000-0000-0000-000000000001")!
        let movingClipID = AudioTimelineClipID(
            rawValue: UUID(uuidString: "a0000000-0000-0000-0000-000000000002")!
        )
        let stationaryClipID = AudioTimelineClipID(
            rawValue: UUID(uuidString: "a0000000-0000-0000-0000-000000000003")!
        )
        let clips = [
            TimelineClip(
                id: movingClipID,
                sourceID: source.id,
                timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 1_000),
                sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 1_000),
                name: "Moving"
            ),
            TimelineClip(
                id: stationaryClipID,
                sourceID: source.id,
                timelineRange: TimelineFrameRange(startFrame: 3_000, frameCount: 1_000),
                sourceRange: TimelineFrameRange(startFrame: 1_000, frameCount: 1_000),
                name: "Stationary"
            )
        ]
        return (
            try TimelineClipGraph(
                sources: [source],
                tracks: [TimelineTrack(id: trackID, name: "Track", clips: clips)],
                timelineSampleRate: 48_000
            ),
            trackID,
            movingClipID,
            stationaryClipID
        )
    }
}
