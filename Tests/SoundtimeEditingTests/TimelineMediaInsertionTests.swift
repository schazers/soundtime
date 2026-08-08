import Foundation
import Testing
@testable import SoundtimeEditing

@Suite("Timeline media insertion")
struct TimelineMediaInsertionTests {
    @Test("Stereo media promotes a mono destination without later collapsing it")
    func stereoInsertionPromotesMonoTrack() throws {
        let trackID = UUID()
        let graph = try TimelineClipGraph(
            tracks: [TimelineTrack(id: trackID, name: "Mono", channelLayout: .mono)],
            timelineSampleRate: 48_000
        )
        let stereo = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "stereo-source"),
            frameCount: 48_000,
            sampleRate: 48_000,
            channelCount: 2
        )

        let inserted = try TimelineMediaInsertionService.insert(
            TimelineMediaInsertionRequest(
                trackID: trackID,
                source: stereo,
                timelineStartFrame: 0,
                clipName: "Stereo"
            ),
            into: graph,
            expectedRevision: graph.revision
        ).graph

        #expect(inserted.track(id: trackID)?.channelLayout == .stereo)
        var emptied = inserted
        var track = try #require(emptied.track(id: trackID))
        track.replaceClips([])
        try emptied.replaceTrack(track)
        #expect(emptied.track(id: trackID)?.channelLayout == .stereo)
    }

    @Test("A second media source inserts directly into an existing track")
    func insertsSecondSourceWithoutMaterialization() throws {
        let trackID = UUID()
        let sourceA = source(id: "source-a", frameCount: 48_000)
        let clipA = TimelineClip(
            sourceID: sourceA.id,
            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 48_000),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 48_000),
            name: "A"
        )
        let graph = try TimelineClipGraph(
            sources: [sourceA],
            tracks: [TimelineTrack(id: trackID, name: "Dialogue", clips: [clipA])],
            timelineSampleRate: 48_000
        )
        let sourceB = source(id: "source-b", frameCount: 96_000, absolutePath: "/media/source-b.wav")

        let result = try TimelineMediaInsertionService.insert(
            TimelineMediaInsertionRequest(
                trackID: trackID,
                source: sourceB,
                timelineStartFrame: 96_000,
                clipName: "B"
            ),
            into: graph,
            expectedRevision: graph.revision
        )

        #expect(result.graph.revision == graph.revision + 1)
        #expect(result.graph.sources.count == 2)
        #expect(result.graph.track(id: trackID)?.clips.map(\.sourceID) == [sourceA.id, sourceB.id])
        #expect(result.graph.source(id: sourceB.id)?.absolutePath == "/media/source-b.wav")
        let lanes = try TimelineClipPlaybackProjection.lanes(from: result.graph)
        #expect(lanes.count == 2)
        #expect(Set(lanes.map(\.id.sourceID)) == [sourceA.id, sourceB.id])
        #expect(result.graph.explicitEndFrame == 192_000)
    }

    @Test("Insertion extends but never shrinks the explicit timeline end")
    func extendsExplicitTimelineEnd() throws {
        let trackID = UUID()
        let source = source(id: "source", frameCount: 96_000)
        let graph = try TimelineClipGraph(
            sources: [],
            tracks: [TimelineTrack(id: trackID, name: "Track")],
            timelineSampleRate: 48_000,
            explicitEndFrame: 24_000
        )

        let extended = try TimelineMediaInsertionService.insert(
            TimelineMediaInsertionRequest(
                trackID: trackID,
                source: source,
                timelineStartFrame: 48_000,
                clipName: "Long import"
            ),
            into: graph,
            expectedRevision: graph.revision
        ).graph
        #expect(extended.explicitEndFrame == 144_000)

        let shorterSource = self.source(id: "shorter", frameCount: 4_800)
        let withShorterClip = try TimelineMediaInsertionService.insert(
            TimelineMediaInsertionRequest(
                trackID: trackID,
                source: shorterSource,
                timelineStartFrame: 0,
                clipName: "Short import"
            ),
            into: extended,
            expectedRevision: extended.revision
        ).graph
        #expect(withShorterClip.explicitEndFrame == 144_000)
    }

    @Test("Insertion rejects collisions without mutating the graph")
    func rejectsCollisionAtomically() throws {
        let trackID = UUID()
        let sourceA = source(id: "source-a", frameCount: 48_000)
        let graph = try TimelineClipGraph(
            sources: [sourceA],
            tracks: [TimelineTrack(
                id: trackID,
                name: "Track",
                clips: [TimelineClip(
                    sourceID: sourceA.id,
                    timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 48_000),
                    sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 48_000),
                    name: "Existing"
                )]
            )],
            timelineSampleRate: 48_000
        )
        let sourceB = source(id: "source-b", frameCount: 48_000)

        #expect(throws: TimelineClipGraphError.self) {
            try TimelineMediaInsertionService.insert(
                TimelineMediaInsertionRequest(
                    trackID: trackID,
                    source: sourceB,
                    timelineStartFrame: 24_000,
                    clipName: "Overlapping"
                ),
                into: graph,
                expectedRevision: graph.revision
            )
        }
        #expect(graph.sources.count == 1)
        #expect(graph.track(id: trackID)?.clips.count == 1)
    }

    @Test("A source identifier cannot silently change media identity")
    func rejectsSourceIdentityConflict() throws {
        let trackID = UUID()
        let existing = source(id: "same-id", frameCount: 48_000, absolutePath: "/a.wav")
        let graph = try TimelineClipGraph(
            sources: [existing],
            tracks: [TimelineTrack(id: trackID, name: "Track")],
            timelineSampleRate: 48_000
        )
        let conflicting = source(id: "same-id", frameCount: 48_000, absolutePath: "/b.wav")

        #expect(throws: TimelineClipGraphError.sourceIdentityConflict(existing.id)) {
            try TimelineMediaInsertionService.insert(
                TimelineMediaInsertionRequest(
                    trackID: trackID,
                    source: conflicting,
                    timelineStartFrame: 0,
                    clipName: "Conflict"
                ),
                into: graph,
                expectedRevision: graph.revision
            )
        }
    }

    @Test("A transfer reserves its complete duration including implicit gaps exactly once")
    func insertsTransferWithGapAsOneRipple() throws {
        let trackID = UUID()
        let existingSource = source(id: "existing", frameCount: 2_000)
        let existingClip = TimelineClip(
            sourceID: existingSource.id,
            timelineRange: TimelineFrameRange(startFrame: 500, frameCount: 100),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 100),
            name: "Existing"
        )
        let graph = try TimelineClipGraph(
            sources: [existingSource],
            tracks: [TimelineTrack(id: trackID, name: "Track", clips: [existingClip])],
            timelineSampleRate: 48_000
        )
        let pastedSource = source(id: "pasted", frameCount: 2_000)
        let payload = TimelineClipTransferPayload(
            timelineSampleRate: 48_000,
            frameCount: 300,
            fragments: [
                TimelineClipTransferFragment(
                    source: pastedSource,
                    sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 100),
                    relativeTimelineStartFrame: 0,
                    timelineFrameCount: 100,
                    name: "Part 1"
                ),
                TimelineClipTransferFragment(
                    source: pastedSource,
                    sourceRange: TimelineFrameRange(startFrame: 200, frameCount: 100),
                    relativeTimelineStartFrame: 200,
                    timelineFrameCount: 100,
                    name: "Part 2"
                ),
            ]
        )

        let result = try TimelineMediaInsertionService.insertTransfer(
            payload,
            trackID: trackID,
            timelineStartFrame: 100,
            into: graph,
            expectedRevision: graph.revision
        )

        let clips = try #require(result.graph.track(id: trackID)?.clips)
        #expect(clips.map(\.timelineRange.startFrame) == [100, 300, 800])
        #expect(clips.map(\.timelineRange.frameCount) == [100, 100, 100])
        #expect(clips.last?.id == existingClip.id)
    }

    @Test("A transfer preserves explicit timeline duration across sample rates")
    func transferPreservesTimelineGeometryAcrossRates() throws {
        let trackID = UUID()
        let graph = try TimelineClipGraph(
            tracks: [TimelineTrack(id: trackID, name: "Track")],
            timelineSampleRate: 48_000
        )
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "rate-source"),
            frameCount: 96_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let payload = TimelineClipTransferPayload(
            timelineSampleRate: 24_000,
            frameCount: 12_000,
            fragments: [TimelineClipTransferFragment(
                source: source,
                sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 48_000),
                relativeTimelineStartFrame: 3_000,
                timelineFrameCount: 6_000,
                name: "Stretched"
            )]
        )

        let result = try TimelineMediaInsertionService.insertTransfer(
            payload,
            trackID: trackID,
            timelineStartFrame: 1_000,
            into: graph,
            expectedRevision: graph.revision
        )
        let clip = try #require(result.graph.track(id: trackID)?.clips.first)
        #expect(clip.timelineRange == TimelineFrameRange(startFrame: 7_000, frameCount: 12_000))
        #expect(clip.sourceRange.frameCount == 48_000)
    }

    @Test("A multi-track ripple insertion extends the global project end only once")
    func multiTrackRippleExtendsExplicitEndOnce() throws {
        let firstTrackID = UUID()
        let secondTrackID = UUID()
        let graph = try TimelineClipGraph(
            tracks: [
                TimelineTrack(id: firstTrackID, name: "Dialogue"),
                TimelineTrack(id: secondTrackID, name: "Music"),
            ],
            timelineSampleRate: 48_000,
            explicitEndFrame: 10_000
        )
        let firstSource = source(id: "first-ripple", frameCount: 500)
        let secondSource = source(id: "second-ripple", frameCount: 500)

        let result = try TimelineMediaInsertionService.insert(
            [
                TimelineMediaInsertionRequest(
                    trackID: firstTrackID,
                    source: firstSource,
                    timelineStartFrame: 1_000,
                    clipName: "Dialogue insert"
                ),
                TimelineMediaInsertionRequest(
                    trackID: secondTrackID,
                    source: secondSource,
                    timelineStartFrame: 1_000,
                    clipName: "Music insert"
                ),
            ],
            into: graph,
            expectedRevision: graph.revision,
            policy: .rippleExistingContent
        )

        #expect(result.graph.explicitEndFrame == 10_500)
        #expect(result.beforeExplicitEndFrame == 10_000)
        #expect(result.afterExplicitEndFrame == 10_500)
    }

    private func source(
        id: String,
        frameCount: Int,
        absolutePath: String? = nil
    ) -> TimelineMediaSource {
        TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: id),
            absolutePath: absolutePath,
            frameCount: frameCount,
            sampleRate: 48_000,
            channelCount: 2
        )
    }
}
