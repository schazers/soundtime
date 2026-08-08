import Foundation
import Testing

@testable import SoundtimeEditing

struct TimelineClipCommandTests {
    @Test
    func commandSequenceIsAtomicAndRevisionChecked() throws {
        let fixture = try makeFixture()
        let original = fixture.graph
        let rightID = AudioTimelineClipID(rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!)
        let split = try TimelineClipCommandExecutor.apply(
            .split(
                trackID: fixture.trackID,
                clipID: fixture.clipID,
                timelineFrame: 1_000,
                rightClipID: rightID
            ),
            to: original,
            expectedRevision: original.revision
        )
        #expect(split.graph.revision == original.revision + 1)
        #expect(split.graph.tracks[0].clips.map(\.name) == ["Voice 1", "Voice 2"])
        #expect(split.graph.tracks[0].clips.map(\.timelineRange.frameCount) == [1_000, 1_000])

        #expect(throws: TimelineClipGraphError.self) {
            _ = try TimelineClipCommandExecutor.apply(
                .remove(trackID: fixture.trackID, clipIDs: [rightID]),
                to: split.graph,
                expectedRevision: original.revision
            )
        }
        #expect(original.tracks[0].clips.count == 1)
    }

    @Test
    func moveTrimSlipDuplicateRenameAndRemoveUseOneGraphPath() throws {
        let fixture = try makeFixture()
        var graph = fixture.graph

        graph = try TimelineClipCommandExecutor.apply(
            .move([TimelineClipMove(
                clipID: fixture.clipID,
                destinationTrackID: fixture.trackID,
                destinationStartFrame: 3_000
            )]),
            to: graph,
            expectedRevision: graph.revision
        ).graph
        graph = try TimelineClipCommandExecutor.apply(
            .trim(
                trackID: fixture.trackID,
                clipID: fixture.clipID,
                edge: .leading,
                timelineFrame: 3_200
            ),
            to: graph,
            expectedRevision: graph.revision
        ).graph
        graph = try TimelineClipCommandExecutor.apply(
            .slip(trackID: fixture.trackID, clipID: fixture.clipID, sourceFrameDelta: 50),
            to: graph,
            expectedRevision: graph.revision
        ).graph
        graph = try TimelineClipCommandExecutor.apply(
            .setProperties(
                trackID: fixture.trackID,
                clipIDs: [fixture.clipID],
                patch: TimelineClipPropertiesPatch(name: "Renamed", gain: 0.5)
            ),
            to: graph,
            expectedRevision: graph.revision
        ).graph

        let duplicateID = AudioTimelineClipID()
        graph = try TimelineClipCommandExecutor.apply(
            .duplicate(
                sourceTrackID: fixture.trackID,
                clipID: fixture.clipID,
                destinationTrackID: fixture.trackID,
                destinationStartFrame: 6_000,
                newClipID: duplicateID
            ),
            to: graph,
            expectedRevision: graph.revision
        ).graph
        #expect(graph.tracks[0].clips.count == 2)
        #expect(graph.tracks[0].clip(id: fixture.clipID)?.name == "Renamed")
        #expect(graph.tracks[0].clip(id: fixture.clipID)?.sourceRange.startFrame == 250)

        graph = try TimelineClipCommandExecutor.apply(
            .remove(trackID: fixture.trackID, clipIDs: [duplicateID]),
            to: graph,
            expectedRevision: graph.revision
        ).graph
        #expect(graph.tracks[0].clips.count == 1)
    }

    @Test
    func removeManyIsAtomicAcrossTracks() throws {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "shared"),
            frameCount: 20_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let firstTrackID = UUID()
        let secondTrackID = UUID()
        let firstClip = TimelineClip(
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 1_000),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 1_000),
            name: "First"
        )
        let secondClip = TimelineClip(
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 2_000, frameCount: 1_000),
            sourceRange: TimelineFrameRange(startFrame: 1_000, frameCount: 1_000),
            name: "Second"
        )
        let graph = try TimelineClipGraph(
            sources: [source],
            tracks: [
                TimelineTrack(id: firstTrackID, name: "One", clips: [firstClip]),
                TimelineTrack(id: secondTrackID, name: "Two", clips: [secondClip]),
            ],
            timelineSampleRate: 48_000
        )

        let result = try TimelineClipCommandExecutor.apply(
            .removeMany([
                TimelineClipReference(trackID: firstTrackID, clipID: firstClip.id),
                TimelineClipReference(trackID: secondTrackID, clipID: secondClip.id),
            ]),
            to: graph,
            expectedRevision: graph.revision
        )

        #expect(result.graph.tracks.allSatisfy { $0.clips.isEmpty })
        #expect(result.affectedTrackIDs == [firstTrackID, secondTrackID])
        #expect(result.beforeTracks.count == 2)
        #expect(result.afterTracks.count == 2)
    }

    @Test
    func groupMoveAcrossTracksPreservesIdentityOffsetsAndProperties() throws {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "group-move"),
            frameCount: 30_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let firstTrackID = UUID()
        let secondTrackID = UUID()
        let thirdTrackID = UUID()
        let firstClip = TimelineClip(
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 1_000, frameCount: 1_000),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 1_000),
            name: "First",
            gain: 0.7,
            fades: TimelineClipFades(fadeInFrames: 100, fadeOutFrames: 80)
        )
        let secondClip = TimelineClip(
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 2_500, frameCount: 800),
            sourceRange: TimelineFrameRange(startFrame: 1_000, frameCount: 800),
            name: "Second",
            gain: 1.2
        )
        let graph = try TimelineClipGraph(
            sources: [source],
            tracks: [
                TimelineTrack(id: firstTrackID, name: "One", clips: [firstClip]),
                TimelineTrack(id: secondTrackID, name: "Two", clips: [secondClip]),
                TimelineTrack(id: thirdTrackID, name: "Three"),
            ],
            timelineSampleRate: 48_000
        )

        let result = try TimelineClipCommandExecutor.apply(
            .move([
                TimelineClipMove(
                    clipID: firstClip.id,
                    destinationTrackID: secondTrackID,
                    destinationStartFrame: 5_000
                ),
                TimelineClipMove(
                    clipID: secondClip.id,
                    destinationTrackID: thirdTrackID,
                    destinationStartFrame: 6_500
                ),
            ]),
            to: graph,
            expectedRevision: graph.revision
        )

        #expect(result.graph.track(id: firstTrackID)?.clips.isEmpty == true)
        let movedFirst = try #require(result.graph.track(id: secondTrackID)?.clip(id: firstClip.id))
        let movedSecond = try #require(result.graph.track(id: thirdTrackID)?.clip(id: secondClip.id))
        #expect(movedFirst.timelineRange.startFrame == 5_000)
        #expect(movedSecond.timelineRange.startFrame == 6_500)
        #expect(movedSecond.timelineRange.startFrame - movedFirst.timelineRange.startFrame == 1_500)
        #expect(movedFirst.sourceRange == firstClip.sourceRange)
        #expect(movedFirst.gain == firstClip.gain)
        #expect(movedFirst.fades == firstClip.fades)
    }

    @Test
    func duplicateManyIsAtomicPreservesPropertiesAndUndoRestoresOriginalGraph() throws {
        let fixture = try makeFixture()
        let secondTrackID = UUID()
        var graph = try fixture.graph.replacingAllTracks(
            fixture.graph.tracks + [TimelineTrack(id: secondTrackID, name: "Destination")]
        )
        graph = try TimelineClipCommandExecutor.apply(
            .setProperties(
                trackID: fixture.trackID,
                clipIDs: [fixture.clipID],
                patch: TimelineClipPropertiesPatch(
                    gain: 0.42,
                    fades: TimelineClipFades(fadeInFrames: 120, fadeOutFrames: 75)
                )
            ),
            to: graph,
            expectedRevision: graph.revision
        ).graph
        let duplicateID = AudioTimelineClipID()
        let result = try TimelineClipCommandExecutor.apply(
            .duplicateMany([
                TimelineClipDuplication(
                    sourceTrackID: fixture.trackID,
                    clipID: fixture.clipID,
                    destinationTrackID: secondTrackID,
                    destinationStartFrame: 4_000,
                    newClipID: duplicateID
                ),
            ]),
            to: graph,
            expectedRevision: graph.revision
        )

        let duplicate = try #require(result.graph.track(id: secondTrackID)?.clip(id: duplicateID))
        let original = try #require(result.graph.track(id: fixture.trackID)?.clip(id: fixture.clipID))
        #expect(duplicate.sourceID == original.sourceID)
        #expect(duplicate.sourceRange == original.sourceRange)
        #expect(duplicate.gain == 0.42)
        #expect(duplicate.fades == TimelineClipFades(fadeInFrames: 120, fadeOutFrames: 75))
        #expect(duplicate.isLocked == false)

        let transaction = TimelineClipUndoTransaction(
            label: "Duplicate Clips",
            commandResult: result,
            beforeSelection: TimelineClipSelectionSnapshot(),
            afterSelection: TimelineClipSelectionSnapshot(selectedClips: [
                .init(trackID: secondTrackID, clipID: duplicateID),
            ]),
            beforeTransport: TimelineTransportSnapshot(playheadFrame: 0, isPlaying: false),
            afterTransport: TimelineTransportSnapshot(playheadFrame: 0, isPlaying: false)
        )
        let restored = try transaction.restoringBefore(in: result.graph)
        #expect(restored.track(id: secondTrackID)?.clips.isEmpty == true)
        #expect(restored.track(id: fixture.trackID)?.clip(id: fixture.clipID) == original)
    }

    @Test
    func duplicateManyRejectsTheWholeOperationWhenAnyPlacementConflicts() throws {
        let fixture = try makeFixture()
        let newID = AudioTimelineClipID()
        #expect(throws: TimelineClipGraphError.self) {
            _ = try TimelineClipCommandExecutor.apply(
                .duplicateMany([
                    TimelineClipDuplication(
                        sourceTrackID: fixture.trackID,
                        clipID: fixture.clipID,
                        destinationTrackID: fixture.trackID,
                        destinationStartFrame: 1_000,
                        newClipID: newID
                    ),
                ]),
                to: fixture.graph,
                expectedRevision: fixture.graph.revision
            )
        }
        #expect(fixture.graph.track(id: fixture.trackID)?.clips.count == 1)
        #expect(fixture.graph.location(of: newID) == nil)
    }

    @Test
    func insertTimeCreatesImplicitGapAndPreservesSourceMedia() throws {
        var fixture = try makeFixture()
        fixture.graph.explicitEndFrame = 4_000
        let rightID = AudioTimelineClipID()
        let result = try TimelineClipCommandExecutor.apply(
            .insertTime(
                trackIDs: [fixture.trackID],
                timelineFrame: 750,
                frameCount: 500,
                splitClipIDs: [fixture.clipID: rightID]
            ),
            to: fixture.graph,
            expectedRevision: fixture.graph.revision
        )

        let clips = try #require(result.graph.track(id: fixture.trackID)?.clips)
        #expect(clips.map(\.timelineRange) == [
            TimelineFrameRange(startFrame: 0, frameCount: 750),
            TimelineFrameRange(startFrame: 1_250, frameCount: 1_250),
        ])
        #expect(clips.map(\.sourceRange) == [
            TimelineFrameRange(startFrame: 0, frameCount: 750),
            TimelineFrameRange(startFrame: 750, frameCount: 1_250),
        ])
        #expect(result.graph.sources == fixture.graph.sources)
        #expect(result.graph.explicitEndFrame == 4_500)
        #expect(result.graph.track(id: fixture.trackID)?.implicitGaps(
            within: TimelineFrameRange(startFrame: 0, frameCount: 2_500)
        ) == [TimelineFrameRange(startFrame: 750, frameCount: 500)])
    }

    @Test
    func mergeAdjacentReversesCanonicalSplit() throws {
        let fixture = try makeFixture()
        let rightID = AudioTimelineClipID()
        let split = try TimelineClipCommandExecutor.apply(
            .split(
                trackID: fixture.trackID,
                clipID: fixture.clipID,
                timelineFrame: 1_000,
                rightClipID: rightID
            ),
            to: fixture.graph,
            expectedRevision: fixture.graph.revision
        )
        let merged = try TimelineClipCommandExecutor.apply(
            .mergeAdjacent(
                trackID: fixture.trackID,
                leadingClipID: fixture.clipID,
                trailingClipID: rightID
            ),
            to: split.graph,
            expectedRevision: split.graph.revision
        )

        let clip = try #require(merged.graph.track(id: fixture.trackID)?.clips.first)
        #expect(merged.graph.track(id: fixture.trackID)?.clips.count == 1)
        #expect(clip.timelineRange == fixture.graph.tracks[0].clips[0].timelineRange)
        #expect(clip.sourceRange == fixture.graph.tracks[0].clips[0].sourceRange)
    }

    @Test
    func slipRejectsSourceRangeOutsideMedia() throws {
        let fixture = try makeFixture()
        #expect(throws: TimelineClipGraphError.self) {
            _ = try TimelineClipCommandExecutor.apply(
                .slip(trackID: fixture.trackID, clipID: fixture.clipID, sourceFrameDelta: -1),
                to: fixture.graph,
                expectedRevision: fixture.graph.revision
            )
        }
        #expect(throws: TimelineClipGraphError.self) {
            _ = try TimelineClipCommandExecutor.apply(
                .slip(trackID: fixture.trackID, clipID: fixture.clipID, sourceFrameDelta: 19_000),
                to: fixture.graph,
                expectedRevision: fixture.graph.revision
            )
        }
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
        let trackID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        let clipID = AudioTimelineClipID(
            rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
        )
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
