import Foundation
import SoundtimeEditing

enum ProjectTransactionSmokeHarness {
    private struct SmokeFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func runFromCommandLine(arguments _: [String]) throws {
        try verifyAtomicGraphTranscriptTransportUndo()
        try verifyTopologyAndImmutableMediaLeases()
        try verifyTranscriptOnlyHistoryAndRedoDivergence()
        try verifyTrackMixHistoryRemainsChronological()
        try verifyRippleDeleteMovesAutomationAtomically()
        try verifyRepeatDuplicatesClipAutomationAtomically()
        try verifyBoundedHistory()
        print("PASS project transactions: graph, transcript, selection, and transport are atomic")
        print("PASS project transactions: topology and immutable media survive undo leases")
        print("PASS project transactions: transcript-only edits and divergent redo are correct")
        print("PASS project transactions: track mix edits preserve chronological clip history")
        print("PASS project transactions: ripple edits move and restore track automation atomically")
        print("PASS project transactions: repeated clips copy automation and undo atomically")
        print("PASS project transactions: history remains bounded under sustained editing")
    }

    @MainActor
    private static func verifyAtomicGraphTranscriptTransportUndo() throws {
        let fixture = try makeFixture(sourceName: "spoken-original", trackName: "Spoken")
        let beforeTranscript = makeTranscript(trackID: fixture.trackID, text: "before", duration: 1)
        let afterTranscript = makeTranscript(trackID: fixture.trackID, text: "after", duration: 0.5)
        let beforeSelection = TimelineClipSelectionSnapshot(
            timeRange: TimelineFrameRange(startFrame: 0, frameCount: 24_000),
            timeSelectionTrackID: fixture.trackID
        )
        let afterSelection = TimelineClipSelectionSnapshot()
        let beforeTransport = TimelineTransportSnapshot(playheadFrame: 30_000, isPlaying: true)
        let afterTransport = TimelineTransportSnapshot(playheadFrame: 6_000, isPlaying: true)

        let session = ProjectSession()
        try session.installClipGraph(fixture.graph)
        session.installTranscripts([fixture.trackID: beforeTranscript])
        _ = try session.executeClipRangeEdit(
            range: TimelineFrameRange(startFrame: 0, frameCount: 24_000),
            trackIDs: [fixture.trackID],
            mode: .rippleDelete,
            label: "Delete Spoken Range",
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        )
        try require(session.amendLatestTransactionWithTranscriptChanges([
            ProjectTranscriptChange(
                trackID: fixture.trackID,
                before: beforeTranscript,
                after: afterTranscript
            ),
        ]), "graph transaction rejected its transcript reconciliation")
        try require(session.projectUndoCount == 1, "one edit produced more than one undo item")
        try require(session.transcript(for: fixture.trackID) == afterTranscript, "new transcript was not installed")

        let editedGraph = session.clipGraph
        let undo = try requireValue(try session.undoProjectTransaction(), "atomic edit could not undo")
        try require(undo.graph.track(id: fixture.trackID) == fixture.graph.track(id: fixture.trackID), "undo did not restore graph")
        try require(undo.transcriptsByTrackID[fixture.trackID] == beforeTranscript, "undo did not restore transcript")
        try require(undo.selection == beforeSelection, "undo did not restore selection")
        try require(undo.transport == beforeTransport, "undo did not restore transport")

        let redo = try requireValue(try session.redoProjectTransaction(), "atomic edit could not redo")
        try require(redo.graph.track(id: fixture.trackID) == editedGraph.track(id: fixture.trackID), "redo did not restore edited graph")
        try require(redo.transcriptsByTrackID[fixture.trackID] == afterTranscript, "redo did not restore edited transcript")
        try require(redo.selection == afterSelection, "redo did not restore edited selection")
        try require(redo.transport == afterTransport, "redo did not restore edited transport")
    }

    @MainActor
    private static func verifyTopologyAndImmutableMediaLeases() throws {
        let original = try makeFixture(sourceName: "original-media", trackName: "Original")
        let replacement = try makeFixture(sourceName: "processed-media", trackName: "Processed")
        let secondTrackID = UUID(uuidString: "72000000-0000-0000-0000-000000000010")!
        let secondTrack = TimelineTrack(id: secondTrackID, name: "Second")
        var beforeGraph = original.graph
        try beforeGraph.replaceAffectedTracks(
            ids: [secondTrackID],
            with: [secondTrack],
            revision: beforeGraph.revision + 1
        )
        let replacedTrack = try requireValue(replacement.graph.tracks.first, "replacement track missing")
        let afterGraph = try TimelineClipGraph(
            sources: Array(replacement.graph.sources.values),
            tracks: [secondTrack, replacedTrack],
            revision: beforeGraph.revision + 1,
            timelineSampleRate: replacement.graph.timelineSampleRate,
            explicitEndFrame: replacement.graph.explicitEndFrame
        )

        let session = ProjectSession()
        try session.installClipGraph(beforeGraph)
        let removedTrackAutomationAddress = TimelineAutomationAddress.track(
            original.trackID,
            parameterID: .volume
        )
        let removedTrackAutomation = try TimelineAutomationLane(
            address: removedTrackAutomationAddress,
            defaultNormalizedValue: 1,
            points: [TimelineAutomationPoint(frame: 120, normalizedValue: 0.3)]
        )
        session.installAutomationGraph(try TimelineAutomationGraph(lanes: [removedTrackAutomation]))
        let state = TimelineClipSelectionSnapshot()
        let transport = TimelineTransportSnapshot(playheadFrame: 0, isPlaying: false)
        try session.recordGraphReplacement(
            label: "Accept Processed Media",
            beforeGraph: beforeGraph,
            afterGraph: afterGraph,
            beforeSelection: state,
            afterSelection: state,
            beforeTransport: transport,
            afterTransport: transport
        )

        try require(session.clipGraph.tracks.map(\.id) == [secondTrackID, replacement.trackID], "replacement topology order was not installed")
        try require(session.leasedClipSourceIDs.contains(original.source.id), "history did not lease original media")
        try require(session.leasedClipSourceIDs.contains(replacement.source.id), "history did not lease replacement media")
        try require(session.leasedClipTrackIDs.contains(original.trackID), "history did not retain removed track presentation identity")
        try require(
            session.automationGraph.lane(at: removedTrackAutomationAddress) == nil,
            "removed track retained orphaned automation"
        )

        _ = try requireValue(try session.undoProjectTransaction(), "media replacement could not undo")
        try require(session.clipGraph.tracks.map(\.id) == beforeGraph.tracks.map(\.id), "undo did not restore track order")
        try require(session.clipGraph.sources[original.source.id] == original.source, "undo did not restore original media")
        try require(
            session.automationGraph.lane(at: removedTrackAutomationAddress) == removedTrackAutomation,
            "undo did not restore removed track automation"
        )
        _ = try requireValue(try session.redoProjectTransaction(), "media replacement could not redo")
        try require(session.clipGraph.tracks.map(\.id) == afterGraph.tracks.map(\.id), "redo did not restore replacement track order")
        try require(session.clipGraph.sources[replacement.source.id] == replacement.source, "redo did not restore replacement media")
        try require(
            session.automationGraph.lane(at: removedTrackAutomationAddress) == nil,
            "redo did not prune removed track automation"
        )
    }

    @MainActor
    private static func verifyTranscriptOnlyHistoryAndRedoDivergence() throws {
        let fixture = try makeFixture(sourceName: "transcript", trackName: "Transcript")
        let first = makeTranscript(trackID: fixture.trackID, text: "one", duration: 1)
        let second = makeTranscript(trackID: fixture.trackID, text: "two", duration: 1)
        let third = makeTranscript(trackID: fixture.trackID, text: "three", duration: 1)
        let state = TimelineClipSelectionSnapshot()
        let transport = TimelineTransportSnapshot(playheadFrame: 0, isPlaying: false)
        let session = ProjectSession()
        try session.installClipGraph(fixture.graph)
        session.installTranscripts([fixture.trackID: first])
        session.recordTranscriptChange(
            label: "Edit Transcript",
            changes: [ProjectTranscriptChange(trackID: fixture.trackID, before: first, after: second)],
            beforeSelection: state,
            afterSelection: state,
            beforeTransport: transport,
            afterTransport: transport
        )
        _ = try requireValue(try session.undoProjectTransaction(), "transcript edit could not undo")
        try require(session.transcript(for: fixture.trackID) == first, "transcript undo did not restore prior document")
        session.recordTranscriptChange(
            label: "Divergent Transcript Edit",
            changes: [ProjectTranscriptChange(trackID: fixture.trackID, before: first, after: third)],
            beforeSelection: state,
            afterSelection: state,
            beforeTransport: transport,
            afterTransport: transport
        )
        try require(!session.canRedoProjectTransaction, "new edit did not invalidate divergent redo history")
        try require(session.transcript(for: fixture.trackID) == third, "divergent transcript edit was not installed")
    }

    @MainActor
    private static func verifyTrackMixHistoryRemainsChronological() throws {
        let fixture = try makeFixture(sourceName: "mix-history", trackName: "Mix History")
        let state = TimelineClipSelectionSnapshot()
        let transport = TimelineTransportSnapshot(playheadFrame: 0, isPlaying: false)
        let session = ProjectSession()
        try session.installClipGraph(fixture.graph)
        let clip = try requireValue(
            fixture.graph.track(id: fixture.trackID)?.clips.first,
            "mix-history fixture clip missing"
        )

        _ = try session.executeClipCommand(
            .move([TimelineClipMove(
                clipID: clip.id,
                destinationTrackID: fixture.trackID,
                destinationStartFrame: 240
            )]),
            label: "Move Clip",
            beforeSelection: state,
            afterSelection: state,
            beforeTransport: transport,
            afterTransport: transport
        )
        let beforeMix = try requireValue(
            session.clipGraph.track(id: fixture.trackID),
            "moved track missing before mix edit"
        )
        try session.updateClipGraphTrackMix(
            trackID: fixture.trackID,
            volume: 0.25,
            pan: 0,
            isMuted: true,
            isSoloed: false
        )
        try session.recordAppliedTrackPropertyChange(
            label: "Change Track Mix",
            beforeTrack: beforeMix,
            beforeSelection: state,
            afterSelection: state,
            beforeTransport: transport,
            afterTransport: transport
        )
        try require(session.projectUndoCount == 2, "mix edit did not produce one chronological undo item")

        _ = try requireValue(try session.undoProjectTransaction(), "mix edit could not undo")
        var restored = try requireValue(session.clipGraph.track(id: fixture.trackID), "track missing after mix undo")
        try require(restored.volume == 1 && !restored.isMuted, "mix undo did not restore track properties")
        try require(restored.clips.first?.timelineRange.startFrame == 240, "mix undo reverted the earlier clip move")

        _ = try requireValue(try session.undoProjectTransaction(), "clip move could not undo after mix edit")
        restored = try requireValue(session.clipGraph.track(id: fixture.trackID), "track missing after move undo")
        try require(restored.clips.first?.timelineRange.startFrame == 0, "clip move undo did not restore placement")

        _ = try requireValue(try session.redoProjectTransaction(), "clip move could not redo")
        _ = try requireValue(try session.redoProjectTransaction(), "mix edit could not redo")
        restored = try requireValue(session.clipGraph.track(id: fixture.trackID), "track missing after mix redo")
        try require(restored.clips.first?.timelineRange.startFrame == 240, "mix redo lost the moved clip placement")
        try require(restored.volume == 0.25 && restored.isMuted, "mix redo did not restore track properties")
    }

    @MainActor
    private static func verifyRippleDeleteMovesAutomationAtomically() throws {
        let fixture = try makeFixture(sourceName: "automation-ripple", trackName: "Automated")
        let address = TimelineAutomationAddress.track(fixture.trackID, parameterID: .volume)
        let lane = try TimelineAutomationLane(
            address: address,
            defaultNormalizedValue: 1,
            points: [
                TimelineAutomationPoint(frame: 4_000, normalizedValue: 0.2),
                TimelineAutomationPoint(frame: 24_000, normalizedValue: 0.8),
                TimelineAutomationPoint(frame: 40_000, normalizedValue: 0.4),
            ]
        )
        let automation = try TimelineAutomationGraph(lanes: [lane])
        let state = TimelineClipSelectionSnapshot()
        let transport = TimelineTransportSnapshot(playheadFrame: 30_000, isPlaying: true)
        let session = ProjectSession()
        try session.installClipGraph(fixture.graph)
        session.installAutomationGraph(automation)

        let deletion = TimelineFrameRange(startFrame: 12_000, frameCount: 8_000)
        _ = try session.executeClipRangeEdit(
            range: deletion,
            trackIDs: [fixture.trackID],
            mode: .rippleDelete,
            label: "Ripple Automated Range",
            beforeSelection: state,
            afterSelection: state,
            beforeTransport: transport,
            afterTransport: transport
        )
        let editedLane = try requireValue(
            session.automationGraph.lane(at: address),
            "ripple edit removed its automation lane"
        )
        try require(
            editedLane.points.contains(where: { $0.frame == 16_000 && abs($0.normalizedValue - 0.8) < 0.000_1 }),
            "ripple edit did not shift the point after the deleted range"
        )
        try require(session.projectUndoCount == 1, "ripple graph and automation produced separate undo items")

        _ = try requireValue(try session.undoProjectTransaction(), "automated ripple edit could not undo")
        try require(session.automationGraph.lane(at: address) == lane, "undo did not restore automation exactly")
        _ = try requireValue(try session.redoProjectTransaction(), "automated ripple edit could not redo")
        try require(session.automationGraph.lane(at: address) == editedLane, "redo did not restore shifted automation")
    }

    @MainActor
    private static func verifyRepeatDuplicatesClipAutomationAtomically() throws {
        let fixture = try makeFixture(sourceName: "automation-repeat", trackName: "Repeated")
        let sourceClip = try requireValue(
            fixture.graph.track(id: fixture.trackID)?.clips.first,
            "repeat fixture clip missing"
        )
        let destinationClipID = AudioTimelineClipID()
        let sourceAddress = TimelineAutomationAddress(
            owner: .clip(sourceClip.id),
            parameterID: .volume
        )
        let destinationAddress = TimelineAutomationAddress(
            owner: .clip(destinationClipID),
            parameterID: .volume
        )
        let sourceLane = try TimelineAutomationLane(
            address: sourceAddress,
            defaultNormalizedValue: 0.75,
            points: [
                TimelineAutomationPoint(frame: 0, normalizedValue: 0.25, curveToNext: 0.4),
                TimelineAutomationPoint(frame: 24_000, normalizedValue: 0.9),
            ]
        )
        let beforeSelection = TimelineClipSelectionSnapshot(selectedClips: [
            .init(trackID: fixture.trackID, clipID: sourceClip.id),
        ])
        let afterSelection = TimelineClipSelectionSnapshot(selectedClips: [
            .init(trackID: fixture.trackID, clipID: destinationClipID),
        ])
        let transport = TimelineTransportSnapshot(playheadFrame: 0, isPlaying: false)
        let session = ProjectSession()
        try session.installClipGraph(fixture.graph)
        session.installAutomationGraph(try TimelineAutomationGraph(lanes: [sourceLane]))

        _ = try session.executeClipCommand(
            .duplicateMany([TimelineClipDuplication(
                sourceTrackID: fixture.trackID,
                clipID: sourceClip.id,
                destinationTrackID: fixture.trackID,
                destinationStartFrame: sourceClip.timelineRange.endFrame,
                newClipID: destinationClipID
            )]),
            label: "Repeat Clip",
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: transport,
            afterTransport: transport
        )

        let repeatedClip = try requireValue(
            session.clipGraph.track(id: fixture.trackID)?.clip(id: destinationClipID),
            "repeat did not create its destination clip"
        )
        try require(
            repeatedClip.timelineRange.startFrame == sourceClip.timelineRange.endFrame,
            "repeat did not place the copy flush with the source end"
        )
        let copiedLane = try requireValue(
            session.automationGraph.lane(at: destinationAddress),
            "repeat did not copy clip automation"
        )
        let copiedFrames = copiedLane.points.map { $0.frame }
        let sourceFrames = sourceLane.points.map { $0.frame }
        let copiedValues = copiedLane.points.map { $0.normalizedValue }
        let sourceValues = sourceLane.points.map { $0.normalizedValue }
        try require(copiedFrames == sourceFrames, "repeat changed copied automation timing")
        try require(copiedValues == sourceValues, "repeat changed copied automation values")
        let copiedPointIDs = Set(copiedLane.points.map { $0.id })
        let sourcePointIDs = sourceLane.points.map { $0.id }
        try require(
            copiedPointIDs.isDisjoint(with: sourcePointIDs),
            "repeat reused automation point identities"
        )
        try require(session.projectUndoCount == 1, "repeat clip and automation produced separate undo items")

        let undo = try requireValue(try session.undoProjectTransaction(), "repeat could not undo")
        try require(
            undo.graph.track(id: fixture.trackID)?.clip(id: destinationClipID) == nil,
            "undo retained the repeated clip"
        )
        try require(
            session.automationGraph.lane(at: destinationAddress) == nil,
            "undo retained repeated clip automation"
        )
        let redo = try requireValue(try session.redoProjectTransaction(), "repeat could not redo")
        try require(
            redo.selection == afterSelection &&
                redo.graph.track(id: fixture.trackID)?.clip(id: destinationClipID) != nil,
            "redo did not restore the selected repeated clip"
        )
        try require(
            session.automationGraph.lane(at: destinationAddress) == copiedLane,
            "redo did not restore repeated clip automation"
        )
    }

    @MainActor
    private static func verifyBoundedHistory() throws {
        let fixture = try makeFixture(sourceName: "bounded", trackName: "Bounded")
        let state = TimelineClipSelectionSnapshot()
        let transport = TimelineTransportSnapshot(playheadFrame: 0, isPlaying: false)
        let session = ProjectSession()
        try session.installClipGraph(fixture.graph)
        var document = makeTranscript(trackID: fixture.trackID, text: "0", duration: 1)
        session.installTranscripts([fixture.trackID: document])
        for index in 1...550 {
            let next = makeTranscript(trackID: fixture.trackID, text: "\(index)", duration: 1)
            session.recordTranscriptChange(
                label: "Bounded History",
                changes: [ProjectTranscriptChange(trackID: fixture.trackID, before: document, after: next)],
                beforeSelection: state,
                afterSelection: state,
                beforeTransport: transport,
                afterTransport: transport
            )
            document = next
        }
        try require(session.projectUndoCount == 500, "history exceeded its configured bound")
        for _ in 0..<500 {
            _ = try requireValue(try session.undoProjectTransaction(), "bounded history ended early")
        }
        try require(!session.canUndoProjectTransaction, "bounded history retained inaccessible entries")
        try require(session.projectRedoCount == 500, "bounded undo did not produce matching redo history")
    }

    private static func makeFixture(
        sourceName: String,
        trackName: String
    ) throws -> (graph: TimelineClipGraph, source: TimelineMediaSource, trackID: UUID) {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: sourceName),
            absolutePath: "/tmp/soundtime-project-transaction/\(sourceName).wav",
            frameCount: 48_000,
            sampleRate: 48_000,
            channelCount: 1,
            metadata: ["ownedByProjectSession": "true"]
        )
        let trackID = UUID()
        let clip = TimelineClip(
            sourceID: source.id,
            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 48_000),
            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 48_000),
            name: trackName
        )
        return (
            try TimelineClipGraph(
                sources: [source],
                tracks: [TimelineTrack(id: trackID, name: trackName, clips: [clip])],
                timelineSampleRate: 48_000,
                explicitEndFrame: 48_000
            ),
            source,
            trackID
        )
    }

    private static func makeTranscript(
        trackID: UUID,
        text: String,
        duration: TimeInterval
    ) -> TranscriptDocument {
        let word = TranscriptWord(text: text, startTime: 0, endTime: duration)
        return TranscriptDocument(
            trackID: trackID,
            sourceRevision: 1,
            sourceDuration: duration,
            providerIdentifier: "smoke",
            providerDisplayName: "Smoke",
            segments: [TranscriptSegment(
                startTime: 0,
                endTime: duration,
                text: text,
                words: [word]
            )]
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SmokeFailure(message: message) }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SmokeFailure(message: message) }
        return value
    }
}
