import Foundation
import Testing
@testable import SoundtimeEditing

@Suite("Timeline clip object clipboard")
struct TimelineClipObjectClipboardTests {
    @Test("Clipboard preserves cross-track geometry and clip properties")
    func preservesGeometryAndProperties() throws {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "clipboard-source"),
            absolutePath: "/media/dialogue.wav",
            frameCount: 100_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let trackIDs = [UUID(), UUID(), UUID()]
        let first = TimelineClip(
            sourceID: source.id,
            timelineRange: .init(startFrame: 1_000, frameCount: 2_000),
            sourceRange: .init(startFrame: 5_000, frameCount: 2_000),
            name: "Dialogue",
            gain: 0.7,
            fades: .init(fadeInFrames: 120, fadeOutFrames: 80),
            isMuted: true,
            isLocked: true,
            colorToken: "teal",
            metadata: ["speaker": "A"]
        )
        let second = TimelineClip(
            sourceID: source.id,
            timelineRange: .init(startFrame: 4_000, frameCount: 1_000),
            sourceRange: .init(startFrame: 10_000, frameCount: 1_000),
            name: "Reply"
        )
        let graph = try TimelineClipGraph(
            sources: [source],
            tracks: [
                TimelineTrack(id: trackIDs[0], name: "One", clips: [first]),
                TimelineTrack(id: trackIDs[1], name: "Two"),
                TimelineTrack(id: trackIDs[2], name: "Three", clips: [second]),
            ],
            timelineSampleRate: 48_000
        )

        let document = try TimelineClipObjectClipboardService.capture([
            .init(trackID: trackIDs[0], clipID: first.id),
            .init(trackID: trackIDs[2], clipID: second.id),
        ], in: graph)
        #expect(document.frameCount == 4_000)
        #expect(document.trackSpan == 3)
        #expect(document.items.map(\.relativeTrackIndex) == [0, 2])
        #expect(document.items.map(\.relativeStartFrame) == [0, 3_000])

        let requests = try TimelineClipObjectClipboardService.insertionRequests(
            for: document,
            anchorTrackID: trackIDs[0],
            timelineStartFrame: 20_000,
            in: graph
        )
        #expect(requests.map(\.trackID) == [trackIDs[0], trackIDs[2]])
        #expect(requests.map(\.timelineStartFrame) == [20_000, 23_000])
        #expect(requests[0].gain == 0.7)
        #expect(requests[0].fades == first.fades)
        #expect(requests[0].isMuted)
        #expect(requests[0].isLocked)
        #expect(requests[0].colorToken == "teal")
        #expect(requests[0].clipMetadata["speaker"] == "A")
    }

    @Test("Clipboard rejects a destination without enough lanes")
    func rejectsInsufficientDestinationTracks() throws {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "clipboard-lanes"),
            frameCount: 10_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let firstTrackID = UUID()
        let secondTrackID = UUID()
        let first = TimelineClip(
            sourceID: source.id,
            timelineRange: .init(startFrame: 0, frameCount: 100),
            sourceRange: .init(startFrame: 0, frameCount: 100),
            name: "One"
        )
        let second = TimelineClip(
            sourceID: source.id,
            timelineRange: .init(startFrame: 0, frameCount: 100),
            sourceRange: .init(startFrame: 100, frameCount: 100),
            name: "Two"
        )
        let graph = try TimelineClipGraph(
            sources: [source],
            tracks: [
                TimelineTrack(id: firstTrackID, name: "One", clips: [first]),
                TimelineTrack(id: secondTrackID, name: "Two", clips: [second]),
            ],
            timelineSampleRate: 48_000
        )
        let document = try TimelineClipObjectClipboardService.capture([
            .init(trackID: firstTrackID, clipID: first.id),
            .init(trackID: secondTrackID, clipID: second.id),
        ], in: graph)

        #expect(throws: TimelineClipObjectClipboardError.self) {
            try TimelineClipObjectClipboardService.insertionRequests(
                for: document,
                anchorTrackID: secondTrackID,
                timelineStartFrame: 0,
                in: graph
            )
        }
    }
}
