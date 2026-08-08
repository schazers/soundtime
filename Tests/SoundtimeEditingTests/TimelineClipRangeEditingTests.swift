import Foundation
import Testing

@testable import SoundtimeEditing

@Suite("Canonical timeline range editing")
struct TimelineClipRangeEditingTests {
    @Test("Clear gap removes only the selected source interval and keeps an implicit gap")
    func clearGapSplitsWithoutGeneratedSilence() throws {
        let fixture = try makeFixture()
        let result = try TimelineClipRangeEditingService.apply(
            range: TimelineFrameRange(startFrame: 100, frameCount: 100),
            toTrackIDs: [fixture.trackID],
            mode: .clearGap,
            in: fixture.graph,
            expectedRevision: fixture.graph.revision
        )

        let track = try #require(result.graph.track(id: fixture.trackID))
        #expect(track.clips.map(\.timelineRange) == [
            TimelineFrameRange(startFrame: 0, frameCount: 100),
            TimelineFrameRange(startFrame: 200, frameCount: 100),
        ])
        #expect(track.clips.map(\.sourceRange) == [
            TimelineFrameRange(startFrame: 0, frameCount: 100),
            TimelineFrameRange(startFrame: 200, frameCount: 100),
        ])
        #expect(track.implicitGaps(within: TimelineFrameRange(startFrame: 0, frameCount: 300)) == [
            TimelineFrameRange(startFrame: 100, frameCount: 100),
        ])
    }

    @Test("Ripple delete remaps surviving audio without changing its source truth")
    func rippleDeleteMovesRightSideLeft() throws {
        let fixture = try makeFixture()
        let result = try TimelineClipRangeEditingService.apply(
            range: TimelineFrameRange(startFrame: 100, frameCount: 100),
            toTrackIDs: [fixture.trackID],
            mode: .rippleDelete,
            in: fixture.graph,
            expectedRevision: fixture.graph.revision
        )

        let clips = try #require(result.graph.track(id: fixture.trackID)?.clips)
        #expect(clips.map(\.timelineRange) == [
            TimelineFrameRange(startFrame: 0, frameCount: 100),
            TimelineFrameRange(startFrame: 100, frameCount: 100),
        ])
        #expect(clips[1].sourceRange == TimelineFrameRange(startFrame: 200, frameCount: 100))
    }

    @Test("Captured transfer preserves gaps, source identity, and clip properties")
    func capturePreservesCanonicalProperties() throws {
        let fixture = try makeFixture()
        let payload = try TimelineClipRangeEditingService.capture(
            range: TimelineFrameRange(startFrame: 50, frameCount: 200),
            trackID: fixture.trackID,
            in: fixture.graph
        )

        #expect(payload.frameCount == 200)
        #expect(payload.fragments.count == 1)
        #expect(payload.fragments[0].relativeTimelineStartFrame == 0)
        #expect(payload.fragments[0].timelineFrameCount == 200)
        #expect(payload.fragments[0].sourceRange == TimelineFrameRange(startFrame: 50, frameCount: 200))
        #expect(payload.fragments[0].gain == 0.75)
        #expect(payload.fragments[0].colorToken == "voice")
    }

    private func makeFixture() throws -> (graph: TimelineClipGraph, trackID: UUID) {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "voice-source"),
            absolutePath: "/media/voice.wav",
            frameCount: 1_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let trackID = UUID()
        let clip = TimelineClip(
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 300),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 300),
            name: "Voice",
            gain: 0.75,
            colorToken: "voice"
        )
        return (
            try TimelineClipGraph(
                sources: [source],
                tracks: [TimelineTrack(id: trackID, name: "Dialogue", clips: [clip])],
                timelineSampleRate: 48_000
            ),
            trackID
        )
    }
}
