import Foundation
import Testing
@testable import SoundtimeEditing

@Suite("Timeline recording editing")
struct TimelineRecordingEditingTests {
    @Test("Punch-in replaces only the recorded timeline interval")
    func punchInPreservesSurroundingMediaAndTrackState() throws {
        let trackID = UUID()
        let originalSource = mediaSource(id: "original", frameCount: 1_000, sampleRate: 100)
        let takeSource = mediaSource(id: "take", frameCount: 200, sampleRate: 100)
        let originalClip = TimelineClip(
            sourceID: originalSource.id,
            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 1_000),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 1_000),
            name: "Original"
        )
        let graph = try TimelineClipGraph(
            sources: [originalSource],
            tracks: [TimelineTrack(
                id: trackID,
                name: "Voice",
                clips: [originalClip],
                volume: 0.72,
                pan: -0.25,
                isMuted: false,
                isSoloed: true
            )],
            revision: 11,
            timelineSampleRate: 100,
            explicitEndFrame: 1_200
        )
        let takeID = AudioTimelineClipID()

        let result = try TimelineRecordingEditingService.overwrite(
            trackID: trackID,
            timelineStartFrame: 400,
            source: takeSource,
            clipID: takeID,
            clipName: "Voice Take",
            in: graph,
            expectedRevision: graph.revision
        )

        let track = try #require(result.graph.track(id: trackID))
        #expect(track.clips.map(\.timelineRange) == [
            TimelineFrameRange(startFrame: 0, frameCount: 400),
            TimelineFrameRange(startFrame: 400, frameCount: 200),
            TimelineFrameRange(startFrame: 600, frameCount: 400),
        ])
        #expect(track.clips.map(\.sourceRange) == [
            TimelineFrameRange(startFrame: 0, frameCount: 400),
            TimelineFrameRange(startFrame: 0, frameCount: 200),
            TimelineFrameRange(startFrame: 600, frameCount: 400),
        ])
        #expect(track.clips[1].id == takeID)
        #expect(track.clips[1].sourceID == takeSource.id)
        #expect(track.volume == 0.72)
        #expect(track.pan == -0.25)
        #expect(track.isSoloed)
        #expect(result.graph.explicitEndFrame == 1_200)
        #expect(result.overwrittenRange == TimelineFrameRange(startFrame: 400, frameCount: 200))
    }

    @Test("Recorded source duration projects into the canonical timeline sample rate")
    func projectsTakeDurationAcrossSampleRates() throws {
        let trackID = UUID()
        let graph = try TimelineClipGraph(
            tracks: [TimelineTrack(id: trackID, name: "Voice")],
            timelineSampleRate: 48_000
        )
        let takeSource = mediaSource(id: "take-44k", frameCount: 44_100, sampleRate: 44_100)

        let result = try TimelineRecordingEditingService.overwrite(
            trackID: trackID,
            timelineStartFrame: 24_000,
            source: takeSource,
            clipName: "One Second",
            in: graph,
            expectedRevision: graph.revision
        )

        #expect(result.clip.timelineRange == TimelineFrameRange(startFrame: 24_000, frameCount: 48_000))
        #expect(result.clip.sourceRange == TimelineFrameRange(startFrame: 0, frameCount: 44_100))
        #expect(result.graph.explicitEndFrame == 72_000)
    }

    @Test("Punch-in rejects a stale graph revision atomically")
    func rejectsStaleRevision() throws {
        let trackID = UUID()
        let graph = try TimelineClipGraph(
            tracks: [TimelineTrack(id: trackID, name: "Voice")],
            revision: 4,
            timelineSampleRate: 48_000
        )
        let takeSource = mediaSource(id: "stale-take", frameCount: 1_000, sampleRate: 48_000)

        #expect(throws: TimelineClipGraphError.staleRevision(expected: 3, actual: 4)) {
            try TimelineRecordingEditingService.overwrite(
                trackID: trackID,
                timelineStartFrame: 0,
                source: takeSource,
                clipName: "Stale",
                in: graph,
                expectedRevision: 3
            )
        }
        #expect(graph.sources.isEmpty)
        #expect(graph.track(id: trackID)?.clips.isEmpty == true)
    }

    private func mediaSource(
        id: String,
        frameCount: Int,
        sampleRate: Double
    ) -> TimelineMediaSource {
        TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: id),
            frameCount: frameCount,
            sampleRate: sampleRate,
            channelCount: 1
        )
    }
}
