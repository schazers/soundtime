import Foundation
import Testing

@testable import SoundtimeEditing

struct TimelineTrackTests {
    @Test
    func trackOrdersClipsAndAllowsMultipleSources() throws {
        let sourceA = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "a"),
            frameCount: 10_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let sourceB = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "b"),
            frameCount: 10_000,
            sampleRate: 48_000,
            channelCount: 2
        )
        let later = TimelineClip(
            sourceID: sourceB.id,
            timelineRange: TimelineFrameRange(startFrame: 4_000, frameCount: 1_000),
            sourceRange: TimelineFrameRange(startFrame: 200, frameCount: 1_000),
            name: "Music"
        )
        let earlier = TimelineClip(
            sourceID: sourceA.id,
            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 2_000),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 2_000),
            name: "Voice"
        )
        let track = TimelineTrack(name: "Mixed", clips: [later, earlier])
        let graph = try TimelineClipGraph(
            sources: [sourceA, sourceB],
            tracks: [track],
            timelineSampleRate: 48_000
        )

        #expect(graph.tracks[0].clips.map(\.id) == [earlier.id, later.id])
        #expect(Set(graph.tracks[0].clips.map(\.sourceID)) == [sourceA.id, sourceB.id])
        #expect(graph.endFrame == 5_000)
    }

    @Test
    func trackRejectsOverlapsDeterministically() {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "a"),
            frameCount: 10_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let first = TimelineClip(
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 2_000),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 2_000),
            name: "One"
        )
        let second = TimelineClip(
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 1_999, frameCount: 500),
            sourceRange: TimelineFrameRange(startFrame: 2_000, frameCount: 500),
            name: "Two"
        )

        #expect(throws: TimelineClipGraphError.self) {
            _ = try TimelineClipGraph(
                sources: [source],
                tracks: [TimelineTrack(name: "Track", clips: [first, second])],
                timelineSampleRate: 48_000
            )
        }
    }

    @Test
    func gapsAreAbsenceRatherThanSyntheticClips() throws {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "a"),
            frameCount: 10_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let first = TimelineClip(
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 1_000, frameCount: 1_000),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 1_000),
            name: "One"
        )
        let second = TimelineClip(
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 4_000, frameCount: 1_000),
            sourceRange: TimelineFrameRange(startFrame: 2_000, frameCount: 1_000),
            name: "Two"
        )
        let track = TimelineTrack(name: "Track", clips: [first, second])

        #expect(track.clips.count == 2)
        #expect(track.implicitGaps(within: TimelineFrameRange(startFrame: 0, frameCount: 6_000)) == [
            TimelineFrameRange(startFrame: 0, frameCount: 1_000),
            TimelineFrameRange(startFrame: 2_000, frameCount: 2_000),
            TimelineFrameRange(startFrame: 5_000, frameCount: 1_000),
        ])
    }
}
