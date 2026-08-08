import Foundation
import Testing

@testable import SoundtimeEditing

struct TimelineClipEffectsTests {
    @Test
    func gainEffectSplitsOnlyTheSelectedSourceInterval() throws {
        let fixture = try makeFixture()
        let result = try TimelineClipEffectsService.apply(
            .gain(0.5),
            range: TimelineFrameRange(startFrame: 250, frameCount: 500),
            trackID: fixture.trackID,
            in: fixture.graph,
            expectedRevision: fixture.graph.revision
        )

        let clips = try #require(result.graph.track(id: fixture.trackID)?.clips)
        #expect(clips.map(\.timelineRange) == [
            TimelineFrameRange(startFrame: 0, frameCount: 250),
            TimelineFrameRange(startFrame: 250, frameCount: 500),
            TimelineFrameRange(startFrame: 750, frameCount: 250),
        ])
        #expect(clips.map(\.sourceRange) == clips.map(\.timelineRange))
        #expect(clips.map(\.gain) == [1, 0.5, 1])
        #expect(result.graph.revision == fixture.graph.revision + 1)
        #expect(result.beforeTracks == fixture.graph.tracks)
    }

    @Test
    func fadeEffectUsesTheRequestedRangeWithoutMaterializingAudio() throws {
        let fixture = try makeFixture()
        let result = try TimelineClipEffectsService.apply(
            .fadeIn,
            range: TimelineFrameRange(startFrame: 200, frameCount: 600),
            trackID: fixture.trackID,
            in: fixture.graph,
            expectedRevision: fixture.graph.revision
        )

        let clips = try #require(result.graph.track(id: fixture.trackID)?.clips)
        let faded = try #require(clips.first { $0.timelineRange.startFrame == 200 })
        #expect(faded.timelineRange.frameCount == 600)
        #expect(faded.sourceRange == faded.timelineRange)
        #expect(faded.gainEnvelope.startMultiplier == 0)
        #expect(faded.gainEnvelope.endMultiplier == 1)
        #expect(result.graph.sources == fixture.graph.sources)
    }

    @Test
    func compoundRippleDeletePreservesSurvivingSourceOrder() throws {
        let fixture = try makeFixture()
        let result = try TimelineClipEffectsService.rippleDelete(
            ranges: [
                TimelineFrameRange(startFrame: 100, frameCount: 100),
                TimelineFrameRange(startFrame: 500, frameCount: 100),
            ],
            trackID: fixture.trackID,
            in: fixture.graph,
            expectedRevision: fixture.graph.revision
        )

        let clips = try #require(result.graph.track(id: fixture.trackID)?.clips)
        #expect(clips.map(\.timelineRange) == [
            TimelineFrameRange(startFrame: 0, frameCount: 100),
            TimelineFrameRange(startFrame: 100, frameCount: 300),
            TimelineFrameRange(startFrame: 400, frameCount: 400),
        ])
        #expect(clips.map(\.sourceRange) == [
            TimelineFrameRange(startFrame: 0, frameCount: 100),
            TimelineFrameRange(startFrame: 200, frameCount: 300),
            TimelineFrameRange(startFrame: 600, frameCount: 400),
        ])
        #expect(result.graph.revision == fixture.graph.revision + 2)
    }

    @Test
    func pruningSourcesKeepsOnlyLiveClipReferences() throws {
        let fixture = try makeFixture()
        let unused = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "unused"),
            frameCount: 1_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let graph = try TimelineClipGraph(
            sources: Array(fixture.graph.sources.values) + [unused],
            tracks: fixture.graph.tracks,
            revision: fixture.graph.revision,
            timelineSampleRate: fixture.graph.timelineSampleRate,
            explicitEndFrame: fixture.graph.explicitEndFrame
        )

        let pruned = try graph.pruningUnreferencedSources()

        #expect(pruned.sources == fixture.graph.sources)
        #expect(pruned.tracks == fixture.graph.tracks)
        #expect(pruned.revision == graph.revision)
    }

    private func makeFixture() throws -> (graph: TimelineClipGraph, trackID: UUID) {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "effects-source"),
            frameCount: 1_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let trackID = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
        let clip = TimelineClip(
            id: AudioTimelineClipID(
                rawValue: UUID(uuidString: "71000000-0000-0000-0000-000000000002")!
            ),
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 1_000),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 1_000),
            name: "Effects"
        )
        return (
            try TimelineClipGraph(
                sources: [source],
                tracks: [TimelineTrack(id: trackID, name: "Effects", clips: [clip])],
                timelineSampleRate: 48_000,
                explicitEndFrame: 1_000
            ),
            trackID
        )
    }
}
