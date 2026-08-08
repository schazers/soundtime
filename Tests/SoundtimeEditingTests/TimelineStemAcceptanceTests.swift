import Foundation
import Testing
@testable import SoundtimeEditing

@Suite("Timeline stem acceptance")
struct TimelineStemAcceptanceTests {
    @Test("Accepting stems preserves the source and inserts aligned unmuted tracks beneath it")
    func acceptsAlignedStemsAtomically() throws {
        let sourceTrackID = UUID()
        let followingTrackID = UUID()
        let originalSource = mediaSource(id: "original", frames: 480_000)
        let originalClip = TimelineClip(
            sourceID: originalSource.id,
            timelineRange: TimelineFrameRange(startFrame: 24_000, frameCount: 480_000),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 480_000),
            name: "Original clip"
        )
        let graph = try TimelineClipGraph(
            sources: [originalSource],
            tracks: [
                TimelineTrack(
                    id: sourceTrackID,
                    name: "At the Bottom of Night",
                    clips: [originalClip],
                    volume: 0.75,
                    isMuted: false,
                    isSoloed: true
                ),
                TimelineTrack(id: followingTrackID, name: "Following"),
            ],
            revision: 9,
            timelineSampleRate: 48_000
        )
        let bassID = UUID()
        let vocalsID = UUID()
        let stems = [
            TimelinePreparedStem(
                trackID: bassID,
                source: mediaSource(id: "bass", frames: 96_000),
                partName: "bass_stem"
            ),
            TimelinePreparedStem(
                trackID: vocalsID,
                source: mediaSource(id: "vocals", frames: 96_000),
                partName: "lead-vocals"
            ),
        ]

        let result = try TimelineStemAcceptanceService.accept(
            stems,
            sourceTrackID: sourceTrackID,
            timelineStartFrame: 72_000,
            into: graph
        )

        #expect(result.graph.revision == 10)
        #expect(result.graph.tracks.map(\.id) == [sourceTrackID, bassID, vocalsID, followingTrackID])
        let sourceTrack = try #require(result.graph.track(id: sourceTrackID))
        #expect(sourceTrack.isMuted)
        #expect(!sourceTrack.isSoloed)
        #expect(sourceTrack.clips == [originalClip])

        let bassTrack = try #require(result.graph.track(id: bassID))
        let vocalsTrack = try #require(result.graph.track(id: vocalsID))
        #expect(bassTrack.name == "At the Bottom of Night (Bass)")
        #expect(vocalsTrack.name == "At the Bottom of Night (Vocals)")
        #expect(!bassTrack.isMuted && !bassTrack.isSoloed)
        #expect(!vocalsTrack.isMuted && !vocalsTrack.isSoloed)
        #expect(bassTrack.volume == 0.75)
        #expect(bassTrack.clips.first?.timelineRange == TimelineFrameRange(startFrame: 72_000, frameCount: 96_000))
        #expect(vocalsTrack.clips.first?.timelineRange == TimelineFrameRange(startFrame: 72_000, frameCount: 96_000))
        #expect(result.addedTrackNames == [
            "At the Bottom of Night (Bass)",
            "At the Bottom of Night (Vocals)",
        ])
    }

    @Test("Empty stem acceptance is a no-op")
    func emptyAcceptanceIsNoOp() throws {
        let trackID = UUID()
        let graph = try TimelineClipGraph(
            tracks: [TimelineTrack(id: trackID, name: "Track")],
            timelineSampleRate: 48_000
        )

        let result = try TimelineStemAcceptanceService.accept(
            [],
            sourceTrackID: trackID,
            timelineStartFrame: 0,
            into: graph
        )

        #expect(result.graph == graph)
        #expect(result.addedTrackIDs.isEmpty)
    }

    private func mediaSource(id: String, frames: Int) -> TimelineMediaSource {
        TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: id),
            absolutePath: "/tmp/\(id).wav",
            frameCount: frames,
            sampleRate: 48_000,
            channelCount: 2,
            metadata: ["ownedByProjectSession": "true"]
        )
    }
}
