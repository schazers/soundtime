import XCTest
@testable import SoundtimeEditing

final class TimelineClipWorkflowTests: XCTestCase {
    func testSnapChoosesNearestDeterministically() {
        let targets = [
            TimelineClipSnapTarget(frame: 110, kind: .clipEdge),
            TimelineClipSnapTarget(frame: 106, kind: .playhead),
        ]
        let result = TimelineClipSnapEngine.snap(
            frame: 100,
            targets: targets,
            configuration: TimelineClipSnapConfiguration(toleranceFrames: 8)
        )
        XCTAssertEqual(result.frame, 106)
        XCTAssertEqual(result.target?.kind, .playhead)
    }

    func testSnapHonorsDisabledKinds() {
        let result = TimelineClipSnapEngine.snap(
            frame: 100,
            targets: [TimelineClipSnapTarget(frame: 101, kind: .grid)],
            configuration: TimelineClipSnapConfiguration(
                toleranceFrames: 8,
                enabledKinds: [.clipEdge]
            )
        )
        XCTAssertEqual(result.frame, 100)
        XCTAssertNil(result.target)
    }

    func testFollowingAndContainedSelection() throws {
        let graph = try fixtureGraph()
        let first = graph.tracks[0].clips[0]
        let following = try TimelineClipSelectionPlanner.following(
            anchor: TimelineClipReference(trackID: graph.tracks[0].id, clipID: first.id),
            in: graph,
            acrossTracks: false
        )
        XCTAssertEqual(following.count, 2)
        let contained = TimelineClipSelectionPlanner.contained(
            in: TimelineFrameRange(startFrame: 0, frameCount: 30),
            graph: graph
        )
        XCTAssertEqual(contained.count, 3)
    }

    func testRepeatPreservesSpacing() throws {
        let graph = try fixtureGraph()
        let clip = graph.tracks[0].clips[0]
        let repeats = try TimelineClipRepeatPlanner.duplications(
            reference: TimelineClipReference(trackID: graph.tracks[0].id, clipID: clip.id),
            count: 2,
            gapFrames: 5,
            in: graph
        )
        XCTAssertEqual(repeats.map(\.destinationStartFrame), [15, 30])
    }

    func testSingleRepeatStartsExactlyAtSourceEnd() throws {
        let graph = try fixtureGraph()
        let clip = graph.tracks[0].clips[0]
        let repeats = try TimelineClipRepeatPlanner.duplications(
            reference: TimelineClipReference(trackID: graph.tracks[0].id, clipID: clip.id),
            count: 1,
            in: graph
        )

        XCTAssertEqual(repeats.count, 1)
        XCTAssertEqual(repeats[0].destinationStartFrame, clip.timelineRange.endFrame)
    }

    func testCrossfadeRequiresTouchingClips() throws {
        let graph = try fixtureGraph()
        let clips = graph.tracks[0].clips
        let plan = try TimelineClipCrossfadePlanner.plan(
            trackID: graph.tracks[0].id,
            leadingClipID: clips[0].id,
            trailingClipID: clips[1].id,
            durationFrames: 4,
            graph: graph
        )
        XCTAssertEqual(plan.durationFrames, 4)
    }

    func testGroupingPreservesUnrelatedMetadata() throws {
        let graph = try fixtureGraph()
        let clip = graph.tracks[0].clips[0]
        let reference = TimelineClipReference(trackID: graph.tracks[0].id, clipID: clip.id)
        let commands = try TimelineClipGrouping.commands(
            references: [reference],
            groupID: UUID(),
            graph: graph
        )
        let result = try TimelineClipCommandExecutor.apply(commands[0], to: graph, expectedRevision: graph.revision)
        let edited = result.graph.track(id: reference.trackID)!.clip(id: reference.clipID)!
        XCTAssertEqual(edited.metadata["speaker"], "A")
        XCTAssertNotNil(edited.metadata[TimelineClipGrouping.groupMetadataKey])
    }

    func testGroupingResolvesMembersAcrossTracks() throws {
        var graph = try fixtureGraph()
        let groupID = UUID()
        let references = Set(graph.tracks.flatMap { track in
            track.clips.prefix(1).map { TimelineClipReference(trackID: track.id, clipID: $0.id) }
        })
        for command in try TimelineClipGrouping.commands(
            references: references,
            groupID: groupID,
            graph: graph
        ) {
            graph = try TimelineClipCommandExecutor.apply(
                command,
                to: graph,
                expectedRevision: graph.revision
            ).graph
        }
        let anchor = references.sorted { $0.trackID.uuidString < $1.trackID.uuidString }[0]
        XCTAssertEqual(
            TimelineClipGrouping.members(of: anchor.clipID, in: graph),
            references
        )
    }

    func testRollBoundaryKeepsCombinedDuration() throws {
        let graph = try fixtureGraph()
        let clips = graph.tracks[0].clips
        let result = try TimelineClipCommandExecutor.apply(
            .rollBoundary(
                trackID: graph.tracks[0].id,
                leadingClipID: clips[0].id,
                trailingClipID: clips[1].id,
                timelineFrame: 12
            ),
            to: graph,
            expectedRevision: graph.revision
        )
        let edited = result.graph.tracks[0].clips
        XCTAssertEqual(edited[0].timelineRange.frameCount, 12)
        XCTAssertEqual(edited[1].timelineRange.startFrame, 12)
        XCTAssertEqual(edited[1].timelineRange.endFrame, 20)
    }

    func testSourceReplacementPreservesClipIdentityAndPlacement() throws {
        var graph = try fixtureGraph()
        let replacement = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "replacement"),
            frameCount: 200,
            sampleRate: 48_000,
            channelCount: 2
        )
        graph.upsertSource(replacement)
        let original = graph.tracks[0].clips[0]
        let result = try TimelineClipCommandExecutor.apply(
            .replaceSource(TimelineClipSourceReplacement(
                trackID: graph.tracks[0].id,
                clipID: original.id,
                sourceID: replacement.id,
                sourceRange: TimelineFrameRange(startFrame: 50, frameCount: 20)
            )),
            to: graph,
            expectedRevision: graph.revision
        )
        let edited = result.graph.tracks[0].clips[0]
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.timelineRange, original.timelineRange)
        XCTAssertEqual(edited.sourceID, replacement.id)
    }

    private func fixtureGraph() throws -> TimelineClipGraph {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "source"),
            frameCount: 100,
            sampleRate: 48_000,
            channelCount: 1
        )
        let first = TimelineClip(
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 10),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 10),
            name: "one",
            metadata: ["speaker": "A"]
        )
        let second = TimelineClip(
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 10, frameCount: 10),
            sourceRange: TimelineFrameRange(startFrame: 10, frameCount: 10),
            name: "two"
        )
        let other = TimelineClip(
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 20, frameCount: 10),
            sourceRange: TimelineFrameRange(startFrame: 20, frameCount: 10),
            name: "other"
        )
        return try TimelineClipGraph(
            sources: [source],
            tracks: [
                TimelineTrack(name: "A", clips: [first, second]),
                TimelineTrack(name: "B", clips: [other]),
            ],
            timelineSampleRate: 48_000
        )
    }
}
