import Foundation
import Testing

@testable import SoundtimeEditing

struct TimelineClipUndoTests {
    @Test
    func typedUndoRestoresOnlyAffectedTrackSelectionAndTransport() throws {
        let fixture = try makeFixture()
        let beforeSelection = TimelineClipSelectionSnapshot(selectedClips: [
            .init(trackID: fixture.trackID, clipID: fixture.clipID),
        ])
        let beforeTransport = TimelineTransportSnapshot(playheadFrame: 400, isPlaying: true)
        let result = try TimelineClipCommandExecutor.apply(
            .move([TimelineClipMove(
                clipID: fixture.clipID,
                destinationTrackID: fixture.trackID,
                destinationStartFrame: 3_000
            )]),
            to: fixture.graph,
            expectedRevision: fixture.graph.revision
        )
        let transaction = TimelineClipUndoTransaction(
            label: "Move Clip",
            commandResult: result,
            beforeSelection: beforeSelection,
            afterSelection: beforeSelection,
            beforeTransport: beforeTransport,
            afterTransport: TimelineTransportSnapshot(playheadFrame: 400, isPlaying: true)
        )
        var history = TimelineClipUndoHistory()
        history.record(transaction)
        #expect(history.latestUndoTransaction?.id == transaction.id)

        let undoOutcome = try history.undo(graph: result.graph)
        let undone = try #require(undoOutcome)
        #expect(undone.graph.tracks[0].clip(id: fixture.clipID)?.timelineRange.startFrame == 0)
        #expect(undone.selection == beforeSelection)
        #expect(undone.transport == beforeTransport)
        let redoOutcome = try history.redo(graph: undone.graph)
        let redone = try #require(redoOutcome)
        #expect(redone.graph.tracks[0].clip(id: fixture.clipID)?.timelineRange.startFrame == 3_000)
        #expect(redone.graph.revision == result.graph.revision + 2)
    }

    @Test
    func mediaLeaseRegistryRetainsSourcesUntilEveryLeaseReleases() async {
        let registry = TimelineMediaLeaseRegistry()
        let sourceID = TimelineMediaSourceID(rawValue: "voice")
        let historyLease = await registry.acquire([sourceID])
        let exportLease = await registry.acquire([sourceID])
        let leasedAfterAcquire = await registry.isLeased(sourceID)
        #expect(leasedAfterAcquire)
        await registry.release(historyLease)
        let leasedAfterHistoryRelease = await registry.isLeased(sourceID)
        #expect(leasedAfterHistoryRelease)
        await registry.release(exportLease)
        let leasedAfterAllRelease = await registry.isLeased(sourceID)
        #expect(leasedAfterAllRelease == false)
    }

    @Test
    func typedUndoRestoresExplicitTimelineEnd() throws {
        var fixture = try makeFixture()
        fixture.graph.explicitEndFrame = 4_000
        let result = try TimelineClipCommandExecutor.apply(
            .insertTime(
                trackIDs: [fixture.trackID],
                timelineFrame: 1_000,
                frameCount: 500,
                splitClipIDs: [fixture.clipID: AudioTimelineClipID()]
            ),
            to: fixture.graph,
            expectedRevision: fixture.graph.revision
        )
        let selection = TimelineClipSelectionSnapshot()
        let transport = TimelineTransportSnapshot(playheadFrame: 0, isPlaying: false)
        var history = TimelineClipUndoHistory()
        history.record(TimelineClipUndoTransaction(
            label: "Insert Time",
            commandResult: result,
            beforeSelection: selection,
            afterSelection: selection,
            beforeTransport: transport,
            afterTransport: transport
        ))

        #expect(result.graph.explicitEndFrame == 4_500)
        let undoOutcome = try history.undo(graph: result.graph)
        let undone = try #require(undoOutcome)
        #expect(undone.graph.explicitEndFrame == 4_000)
        let redoOutcome = try history.redo(graph: undone.graph)
        let redone = try #require(redoOutcome)
        #expect(redone.graph.explicitEndFrame == 4_500)
    }

    private func makeFixture() throws -> (
        graph: TimelineClipGraph,
        trackID: UUID,
        clipID: AudioTimelineClipID
    ) {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "voice"),
            frameCount: 20_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let trackID = UUID()
        let clipID = AudioTimelineClipID()
        let clip = TimelineClip(
            id: clipID,
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 2_000),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 2_000),
            name: "Voice"
        )
        return (
            try TimelineClipGraph(
                sources: [source],
                tracks: [TimelineTrack(id: trackID, name: "Track", clips: [clip])],
                timelineSampleRate: 48_000
            ),
            trackID,
            clipID
        )
    }
}
