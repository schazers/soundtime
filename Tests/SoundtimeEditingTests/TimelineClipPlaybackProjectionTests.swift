import Foundation
import Testing

@testable import SoundtimeEditing

struct TimelineClipPlaybackProjectionTests {
    @Test
    func projectionCreatesSparseLanePerSourceAndPreservesGaps() throws {
        let sourceA = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "a"),
            frameCount: 20_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let sourceB = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "b"),
            frameCount: 20_000,
            sampleRate: 48_000,
            channelCount: 2
        )
        let clipA = TimelineClip(
            sourceID: sourceA.id,
            timelineRange: TimelineFrameRange(startFrame: 1_000, frameCount: 2_000),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 2_000),
            name: "Voice",
            gain: 0.5,
            fades: TimelineClipFades(fadeInFrames: 200, fadeOutFrames: 300)
        )
        let clipB = TimelineClip(
            sourceID: sourceB.id,
            timelineRange: TimelineFrameRange(startFrame: 8_000, frameCount: 1_000),
            sourceRange: TimelineFrameRange(startFrame: 4_000, frameCount: 2_000),
            name: "Music"
        )
        let graph = try TimelineClipGraph(
            sources: [sourceA, sourceB],
            tracks: [TimelineTrack(name: "Mixed", clips: [clipA, clipB])],
            timelineSampleRate: 48_000
        )

        let lanes = try TimelineClipPlaybackProjection.lanes(from: graph)
        #expect(lanes.count == 2)
        #expect(lanes.allSatisfy { $0.logicalChannelCount == 2 })
        #expect(lanes[0].segments.map(\.outputStartFrame) == [1_000, 1_200, 2_700])
        #expect(lanes[0].segments.map(\.frameCount) == [200, 1_500, 300])
        #expect(lanes[0].segments.first?.gainStart == 0)
        #expect(lanes[0].segments.first?.gainEnd == 0.5)
        #expect(lanes[0].segments[1].gainStart == 0.5)
        #expect(lanes[0].segments[1].gainEnd == 0.5)
        #expect(lanes[0].segments.last?.gainStart == 0.5)
        #expect(lanes[0].segments.last?.gainEnd == 0)
        #expect(lanes[1].segments.first?.outputStartFrame == 8_000)
        #expect(lanes[1].segments.first?.sourceFrameScale == 2)
        #expect(lanes.flatMap(\.segments).contains { $0.outputStartFrame == 3_000 } == false)

        let snapshot = try TimelineClipPlaybackProjection.snapshot(from: graph)
        #expect(snapshot.graphRevision == graph.revision)
        #expect(snapshot.timelineSampleRate == graph.timelineSampleRate)
        #expect(snapshot.endFrame == graph.endFrame)
        #expect(snapshot.lanes == lanes)
    }

    @Test
    func projectionCarriesLogicalLayoutInsteadOfSourceLayout() throws {
        let monoSource = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "mono-on-stereo-track"),
            frameCount: 4_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let clip = TimelineClip(
            sourceID: monoSource.id,
            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 4_000),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 4_000),
            name: "Mono source"
        )
        let graph = try TimelineClipGraph(
            sources: [monoSource],
            tracks: [TimelineTrack(
                name: "Promoted stereo track",
                clips: [clip],
                pan: 1,
                channelLayout: .stereo
            )],
            timelineSampleRate: 48_000
        )

        let lane = try #require(TimelineClipPlaybackProjection.lanes(from: graph).first)
        #expect(lane.source.channelCount == 1)
        #expect(lane.logicalChannelCount == 2)
    }

    @Test
    func projectionPreservesNamedAutomationCurves() throws {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "automation-source"),
            frameCount: 4_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let track = TimelineTrack(
            name: "Voice",
            clips: [TimelineClip(
                sourceID: source.id,
                timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 4_000),
                sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 4_000),
                name: "Voice"
            )]
        )
        let graph = try TimelineClipGraph(
            sources: [source],
            tracks: [track],
            timelineSampleRate: 48_000
        )
        let lane = try TimelineAutomationLane(
            address: .track(track.id, parameterID: .volume),
            defaultNormalizedValue: 1,
            points: [
                TimelineAutomationPoint(frame: 0, normalizedValue: 0, curveToNext: TimelineAutomationCurve.sCurve),
                TimelineAutomationPoint(frame: 1_000, normalizedValue: 1, curveToNext: TimelineAutomationCurve.stepped),
                TimelineAutomationPoint(frame: 2_000, normalizedValue: 0.5),
            ]
        )
        let automation = try TimelineAutomationGraph(lanes: [lane])

        let snapshot = try TimelineClipPlaybackProjection.snapshot(
            from: graph,
            automationGraph: automation
        )

        #expect(snapshot.lanes.count == 1)
        #expect(snapshot.lanes[0].volumeAutomation.map(\.curveToNext) == [
            TimelineAutomationCurve.sCurve,
            TimelineAutomationCurve.stepped,
            0,
        ])
    }
}
