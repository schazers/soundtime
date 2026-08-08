import Foundation

struct ProjectTrack {
    var id: UUID
    var editGroupID: UUID? = nil
    var name: String
    var sourceURL: URL
    var durationHint: TimeInterval?
    var sourceWaveformOverview: WaveformOverview?
    var waveformOverview: WaveformOverview?
    var decodedAudioBuffer: DecodedAudioBuffer?
    var zeroCrossingIndex: AudioZeroCrossingIndex?
    var zeroCrossingProbe: WAVZeroCrossingProbe?
    var audioTimeline: AudioEditTimeline?
    var fileTimeline: AudioFileEditTimeline?
    var editableSource: EditableAudioSource?
    var ownsSourceFile: Bool
    var volume: Float
    var pan: Float = 0
    var channelLayout: TrackChannelLayout = .stereo
    var isMuted: Bool
    var isSoloed: Bool
    var importID: UUID
    var editRevision: Int
    var transcript: TranscriptDocument? = nil
    var importedAssetID: UUID? = nil
    var importSessionID: UUID? = nil
    var importStage: AudioImportStage? = nil
    var importProgress: Double = 1
    var importFingerprint: AudioImportFingerprint? = nil
    var importPreviewIsProgressive = false
}

/// The authoritative identity, edit, and selection state for an open project.
///
/// `WorkspaceView` currently forwards its legacy property names into this
/// object. That keeps the migration behavior-neutral while giving render,
/// playback, persistence, and editing coordinators one domain owner to target.
@MainActor
final class ProjectSession {
    var tracks: [ProjectTrack] = []
    var editGraph = EditGraph()
    /// The sole authoritative media arrangement for the open project.
    ///
    /// `tracks` remains a presentation/cache projection while the AppKit views
    /// migrate. It must never be used to reconstruct this graph after load.
    private(set) var clipGraph: TimelineClipGraph
    private(set) var automationGraph: TimelineAutomationGraph
    private(set) var transactionHistory = ProjectTransactionHistory(capacity: 500)
    private(set) var transcriptsByTrackID: [UUID: TranscriptDocument] = [:]
    var activeTrackID: UUID?
    var selectedTrackID: UUID?
    var selectedTrackIDs: Set<UUID> = []
    var selection: TimelineSelection?
    var selectedClipTrackID: UUID?
    var selectedClipID: AudioTimelineClipID?
    var selectedClipKeys: Set<TimelineClipSelectionKey> = []
    var trackSelectionAnchorID: UUID?
    var defaultEditGroupID = UUID()
    var projectURL: URL?
    var projectID = UUID()
    var editRevision: UInt64 = 1
    var publishedTimelineRevision: UInt64 = 1
    var publishedPlaybackRevision: UInt64 = 1
    var visualRevision: UInt64 = 1
    var launchStateRevision: UInt64 = 1
    /// User-authored end of the exported timeline. Content may exist beyond it.
    var timelineEndTime: TimeInterval?

    init() {
        clipGraph = try! TimelineClipGraph(timelineSampleRate: 48_000)
        automationGraph = try! TimelineAutomationGraph()
    }

    func installClipGraph(_ graph: TimelineClipGraph, clearsHistory: Bool = true) throws {
        try graph.validate()
        clipGraph = graph
        if clearsHistory {
            transactionHistory.clear()
        }
        timelineEndTime = graph.explicitEndFrame.map {
            Double($0) / graph.timelineSampleRate
        }
        editRevision = max(editRevision, graph.revision)
    }

    func installAutomationGraph(_ graph: TimelineAutomationGraph, clearsHistory: Bool = false) {
        automationGraph = graph
        if clearsHistory {
            transactionHistory.clear()
        }
        editRevision = max(editRevision, graph.revision)
    }

    @discardableResult
    func updateAutomationLane(
        _ lane: TimelineAutomationLane?,
        at address: TimelineAutomationAddress,
        label: String,
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) throws -> Bool {
        let beforeLane = automationGraph.lane(at: address)
        guard beforeLane != lane else { return false }
        if let lane {
            guard lane.address == address else {
                preconditionFailure("Automation lane address does not match its update key")
            }
            try automationGraph.upsertLane(lane)
        } else {
            automationGraph.removeLane(at: address)
        }
        transactionHistory.record(ProjectTransaction(
            label: label,
            automationChanges: [ProjectAutomationLaneChange(
                address: address,
                before: beforeLane,
                after: lane
            )],
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        ))
        editRevision = max(editRevision &+ 1, automationGraph.revision)
        return true
    }

    func installTranscripts(_ documentsByTrackID: [UUID: TranscriptDocument]) {
        let liveTrackIDs = Set(clipGraph.tracks.map(\.id))
        transcriptsByTrackID = documentsByTrackID.filter { liveTrackIDs.contains($0.key) }
    }

    func installTranscripts(from tracks: [ProjectTrack]) {
        installTranscripts(Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
            track.transcript.map { (track.id, $0) }
        }))
    }

    var missingMediaSources: [TimelineMediaSource] {
        clipGraph.sources.values
            .filter { $0.metadata["missingMedia"] == "true" }
            .sorted { $0.id < $1.id }
    }

    @discardableResult
    func relinkMediaSource(
        sourceID: TimelineMediaSourceID,
        candidate: TimelineMediaRelinkCandidate,
        label: String = "Relink Media",
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) throws -> TimelineClipCommandResult {
        let beforeGraph = clipGraph
        let plan = try TimelineMediaRelinkPlanner.plan(
            sourceID: sourceID,
            candidate: candidate,
            in: beforeGraph
        )
        var afterGraph = beforeGraph
        afterGraph.upsertSource(plan.sourceAfter)
        afterGraph.setRevision(beforeGraph.revision &+ 1)
        try afterGraph.validate()

        let result = TimelineClipCommandResult(
            graph: afterGraph,
            affectedTrackIDs: plan.affectedTrackIDs,
            beforeTracks: beforeGraph.tracks.filter { plan.affectedTrackIDs.contains($0.id) },
            afterTracks: afterGraph.tracks.filter { plan.affectedTrackIDs.contains($0.id) },
            affectedClipIDs: plan.affectedClipIDs,
            sourceChanges: [TimelineMediaSourceChange(
                id: sourceID,
                before: plan.sourceBefore,
                after: plan.sourceAfter
            )],
            beforeExplicitEndFrame: beforeGraph.explicitEndFrame,
            afterExplicitEndFrame: afterGraph.explicitEndFrame
        )
        clipGraph = afterGraph
        recordGraphTransaction(TimelineClipUndoTransaction(
            label: label,
            commandResult: result,
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        ))
        editRevision = max(editRevision &+ 1, afterGraph.revision)
        return result
    }

    func transcript(for trackID: UUID) -> TranscriptDocument? {
        transcriptsByTrackID[trackID]
    }

    func updateClipGraphTrackMix(
        trackID: UUID,
        volume: Float,
        pan: Float,
        isMuted: Bool,
        isSoloed: Bool
    ) throws {
        guard var track = clipGraph.track(id: trackID) else {
            throw TimelineClipGraphError.missingTrack(trackID)
        }
        track.volume = volume
        track.pan = min(max(pan, -1), 1)
        track.isMuted = isMuted
        track.isSoloed = isSoloed
        try clipGraph.replaceTrack(track)
        editRevision = max(editRevision &+ 1, clipGraph.revision)
    }

    /// Records a track-property mutation that has already been applied live.
    ///
    /// Volume gestures publish every intermediate value to the audio graph,
    /// but history must contain one semantic edit rather than one entry per
    /// pointer event. Mute and solo use the same path for chronological parity
    /// with clip edits.
    func recordAppliedTrackPropertyChange(
        label: String,
        beforeTrack: TimelineTrack,
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) throws {
        guard let afterTrack = clipGraph.track(id: beforeTrack.id) else {
            throw TimelineClipGraphError.missingTrack(beforeTrack.id)
        }
        guard beforeTrack != afterTrack else { return }

        let commandResult = TimelineClipCommandResult(
            graph: clipGraph,
            affectedTrackIDs: [beforeTrack.id],
            beforeTracks: [beforeTrack],
            afterTracks: [afterTrack],
            affectedClipIDs: Set(afterTrack.clips.map(\.id)),
            beforeTrackOrder: clipGraph.tracks.map(\.id),
            afterTrackOrder: clipGraph.tracks.map(\.id),
            beforeExplicitEndFrame: clipGraph.explicitEndFrame,
            afterExplicitEndFrame: clipGraph.explicitEndFrame
        )
        recordGraphTransaction(TimelineClipUndoTransaction(
            label: label,
            commandResult: commandResult,
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        ))
    }

    @discardableResult
    func applyClipRangeEffect(
        _ effect: TimelineClipRangeEffect,
        range: TimelineFrameRange,
        trackID: UUID,
        label: String,
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) throws -> TimelineClipCommandResult {
        let result = try TimelineClipEffectsService.apply(
            effect,
            range: range,
            trackID: trackID,
            in: clipGraph,
            expectedRevision: clipGraph.revision
        )
        guard !result.affectedTrackIDs.isEmpty else { return result }
        clipGraph = result.graph
        synchronizeTimelineEndFromClipGraph()
        recordGraphTransaction(TimelineClipUndoTransaction(
            label: label,
            commandResult: result,
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        ))
        editRevision = max(editRevision &+ 1, clipGraph.revision)
        return result
    }

    @discardableResult
    func rippleDeleteClipRanges(
        _ ranges: [TimelineFrameRange],
        trackID: UUID,
        label: String,
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) throws -> TimelineClipCommandResult {
        let beforeAutomationGraph = automationGraph
        let result = try TimelineClipEffectsService.rippleDelete(
            ranges: ranges,
            trackID: trackID,
            in: clipGraph,
            expectedRevision: clipGraph.revision
        )
        guard !result.affectedTrackIDs.isEmpty else { return result }
        var afterAutomationGraph = beforeAutomationGraph
        for range in ranges.sorted(by: { $0.startFrame > $1.startFrame }) where range.frameCount > 0 {
            afterAutomationGraph = try afterAutomationGraph.rippleDeleting(
                range,
                affectedTrackIDs: [trackID],
                followsTrackAutomation: true
            )
        }
        let automationChanges = automationLaneChanges(
            from: beforeAutomationGraph,
            to: afterAutomationGraph
        )
        clipGraph = result.graph
        automationGraph = afterAutomationGraph
        synchronizeTimelineEndFromClipGraph()
        recordGraphTransaction(TimelineClipUndoTransaction(
            label: label,
            commandResult: result,
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        ), automationChanges: automationChanges)
        editRevision = max(editRevision &+ 1, clipGraph.revision)
        return result
    }

    func captureClipTransfer(
        range: TimelineFrameRange,
        trackID: UUID
    ) throws -> TimelineClipTransferPayload {
        try TimelineClipRangeEditingService.capture(
            range: range,
            trackID: trackID,
            in: clipGraph
        )
    }

    func captureClipObjects(
        _ references: Set<TimelineClipReference>
    ) throws -> TimelineClipObjectClipboardDocument {
        try TimelineClipObjectClipboardService.capture(references, in: clipGraph)
    }

    @discardableResult
    func insertClipObjects(
        _ document: TimelineClipObjectClipboardDocument,
        anchorTrackID: UUID,
        timelineStartFrame: Int,
        label: String,
        beforeSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) throws -> (result: TimelineClipCommandResult, selection: TimelineClipSelectionSnapshot) {
        let requests = try TimelineClipObjectClipboardService.insertionRequests(
            for: document,
            anchorTrackID: anchorTrackID,
            timelineStartFrame: timelineStartFrame,
            in: clipGraph
        )
        let result = try TimelineMediaInsertionService.insert(
            requests,
            into: clipGraph,
            expectedRevision: clipGraph.revision,
            policy: .rejectOverlap
        )
        let selection = TimelineClipSelectionSnapshot(
            selectedClips: requests.map {
                .init(trackID: $0.trackID, clipID: $0.clipID)
            }
        )
        clipGraph = result.graph
        synchronizeTimelineEndFromClipGraph()
        recordGraphTransaction(TimelineClipUndoTransaction(
            label: label,
            commandResult: result,
            beforeSelection: beforeSelection,
            afterSelection: selection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        ))
        editRevision = max(editRevision &+ 1, clipGraph.revision)
        return (result, selection)
    }

    @discardableResult
    func executeClipRangeEdit(
        range: TimelineFrameRange,
        trackIDs: Set<UUID>,
        mode: TimelineClipRangeEditMode,
        label: String,
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) throws -> TimelineClipCommandResult {
        let beforeAutomationGraph = automationGraph
        let result = try TimelineClipRangeEditingService.apply(
            range: range,
            toTrackIDs: trackIDs,
            mode: mode,
            in: clipGraph,
            expectedRevision: clipGraph.revision
        )
        let afterAutomationGraph: TimelineAutomationGraph
        switch mode {
        case .clearGap:
            // Track automation is anchored to project time. Clearing media from
            // a range does not alter the project-time axis.
            afterAutomationGraph = beforeAutomationGraph
        case .rippleDelete:
            afterAutomationGraph = try beforeAutomationGraph.rippleDeleting(
                range,
                affectedTrackIDs: trackIDs,
                followsTrackAutomation: true
            )
        }
        let automationChanges = automationLaneChanges(
            from: beforeAutomationGraph,
            to: afterAutomationGraph
        )
        clipGraph = result.graph
        automationGraph = afterAutomationGraph
        synchronizeTimelineEndFromClipGraph()
        recordGraphTransaction(TimelineClipUndoTransaction(
            label: label,
            commandResult: result,
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        ), automationChanges: automationChanges)
        editRevision = max(editRevision &+ 1, clipGraph.revision)
        return result
    }

    @discardableResult
    func insertClipTransfer(
        _ payload: TimelineClipTransferPayload,
        trackID: UUID,
        timelineStartFrame: Int,
        label: String,
        beforeSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) throws -> (result: TimelineClipCommandResult, selection: TimelineClipSelectionSnapshot) {
        guard !payload.fragments.isEmpty else {
            throw TimelineClipGraphError.invalidTimelineSampleRate
        }
        let selection = TimelineClipSelectionSnapshot(
            timeRange: TimelineFrameRange(
                startFrame: timelineStartFrame,
                frameCount: payload.frameCount
            ),
            timeSelectionTrackID: trackID
        )
        let result = try TimelineMediaInsertionService.insertTransfer(
            payload,
            trackID: trackID,
            timelineStartFrame: timelineStartFrame,
            into: clipGraph,
            expectedRevision: clipGraph.revision
        )
        let insertedSelection = TimelineClipSelectionSnapshot(
            selectedClips: result.afterTracks.flatMap { track in
                track.clips.filter { result.affectedClipIDs.contains($0.id) }.map {
                    TimelineClipSelectionSnapshot.SelectedClip(trackID: track.id, clipID: $0.id)
                }
            },
            timeRange: selection.timeRange,
            timeSelectionTrackID: selection.timeSelectionTrackID
        )
        clipGraph = result.graph
        synchronizeTimelineEndFromClipGraph()
        recordGraphTransaction(TimelineClipUndoTransaction(
            label: label,
            commandResult: result,
            beforeSelection: beforeSelection,
            afterSelection: insertedSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        ))
        editRevision = max(editRevision &+ 1, clipGraph.revision)
        return (result, insertedSelection)
    }

    var leasedClipSourceIDs: Set<TimelineMediaSourceID> {
        transactionHistory.leasedSourceIDs
    }

    var leasedClipSources: [TimelineMediaSourceID: TimelineMediaSource] {
        transactionHistory.leasedSources
    }

    var leasedClipTrackIDs: Set<UUID> {
        transactionHistory.leasedTrackIDs
    }

    var latestClipUndoTransaction: TimelineClipUndoTransaction? {
        transactionHistory.latestUndoTransaction?.graphChange
    }

    var canUndoProjectTransaction: Bool { transactionHistory.canUndo }
    var canRedoProjectTransaction: Bool { transactionHistory.canRedo }
    var projectUndoCount: Int { transactionHistory.undoCount }
    var projectRedoCount: Int { transactionHistory.redoCount }
    var latestProjectTransaction: ProjectTransaction? { transactionHistory.latestUndoTransaction }

    func clearProjectTransactionHistory() {
        transactionHistory.clear()
    }

    @discardableResult
    func replaceClipGraphTracks(
        affectedTrackIDs: Set<UUID>,
        replacements: [TimelineTrack],
        label: String,
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) throws -> TimelineClipCommandResult {
        let beforeAutomationGraph = automationGraph
        let beforeTracks = clipGraph.tracks.filter { affectedTrackIDs.contains($0.id) }
        var graph = clipGraph
        try graph.replaceAffectedTracks(
            ids: affectedTrackIDs,
            with: replacements,
            revision: clipGraph.revision &+ 1
        )
        let result = TimelineClipCommandResult(
            graph: graph,
            affectedTrackIDs: affectedTrackIDs,
            beforeTracks: beforeTracks,
            afterTracks: replacements,
            affectedClipIDs: Set((beforeTracks + replacements).flatMap(\.clips).map(\.id)),
            beforeExplicitEndFrame: clipGraph.explicitEndFrame,
            afterExplicitEndFrame: graph.explicitEndFrame
        )
        let afterAutomationGraph = automationGraphPruned(for: graph, startingFrom: beforeAutomationGraph)
        let automationChanges = automationLaneChanges(from: beforeAutomationGraph, to: afterAutomationGraph)
        clipGraph = graph
        automationGraph = afterAutomationGraph
        recordGraphTransaction(TimelineClipUndoTransaction(
            label: label,
            commandResult: result,
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        ), automationChanges: automationChanges)
        editRevision = max(editRevision &+ 1, clipGraph.revision)
        return result
    }

    @discardableResult
    func executeClipCommand(
        _ command: TimelineClipCommand,
        label: String,
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) throws -> TimelineClipCommandResult {
        let beforeAutomationGraph = automationGraph
        let result = try TimelineClipCommandExecutor.apply(
            command,
            to: clipGraph,
            expectedRevision: clipGraph.revision
        )
        let afterAutomationGraph = try automationGraph(
            applying: command,
            resultingGraph: result.graph,
            startingFrom: beforeAutomationGraph
        )
        let automationChanges = automationLaneChanges(from: beforeAutomationGraph, to: afterAutomationGraph)
        let transaction = TimelineClipUndoTransaction(
            label: label,
            commandResult: result,
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        )
        clipGraph = result.graph
        automationGraph = afterAutomationGraph
        recordGraphTransaction(transaction, automationChanges: automationChanges)
        editRevision = max(editRevision &+ 1, clipGraph.revision)
        return result
    }

    /// Applies a user-visible compound edit as one graph revision and one undo item.
    @discardableResult
    func executeClipCommands(
        _ commands: [TimelineClipCommand],
        label: String,
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) throws -> TimelineClipCommandResult {
        guard !commands.isEmpty else {
            return TimelineClipCommandResult(
                graph: clipGraph,
                affectedTrackIDs: [],
                beforeTracks: [],
                afterTracks: [],
                affectedClipIDs: [],
                beforeExplicitEndFrame: clipGraph.explicitEndFrame,
                afterExplicitEndFrame: clipGraph.explicitEndFrame
            )
        }
        let originalGraph = clipGraph
        let beforeAutomationGraph = automationGraph
        var workingGraph = originalGraph
        var workingAutomationGraph = beforeAutomationGraph
        var affectedTrackIDs = Set<UUID>()
        var affectedClipIDs = Set<AudioTimelineClipID>()
        for command in commands {
            let result = try TimelineClipCommandExecutor.apply(
                command,
                to: workingGraph,
                expectedRevision: workingGraph.revision
            )
            workingGraph = result.graph
            workingAutomationGraph = try automationGraph(
                applying: command,
                resultingGraph: workingGraph,
                startingFrom: workingAutomationGraph
            )
            affectedTrackIDs.formUnion(result.affectedTrackIDs)
            affectedClipIDs.formUnion(result.affectedClipIDs)
        }
        // A compound interaction publishes exactly one externally visible revision.
        workingGraph.setRevision(originalGraph.revision &+ 1)
        let result = TimelineClipCommandResult(
            graph: workingGraph,
            affectedTrackIDs: affectedTrackIDs,
            beforeTracks: originalGraph.tracks.filter { affectedTrackIDs.contains($0.id) },
            afterTracks: workingGraph.tracks.filter { affectedTrackIDs.contains($0.id) },
            affectedClipIDs: affectedClipIDs,
            beforeExplicitEndFrame: originalGraph.explicitEndFrame,
            afterExplicitEndFrame: workingGraph.explicitEndFrame
        )
        let automationChanges = automationLaneChanges(
            from: beforeAutomationGraph,
            to: workingAutomationGraph
        )
        clipGraph = workingGraph
        automationGraph = workingAutomationGraph
        recordGraphTransaction(TimelineClipUndoTransaction(
            label: label,
            commandResult: result,
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        ), automationChanges: automationChanges)
        editRevision = max(editRevision &+ 1, clipGraph.revision)
        return result
    }

    @discardableResult
    func insertMedia(
        _ request: TimelineMediaInsertionRequest,
        policy: TimelineMediaInsertionPolicy = .rejectOverlap,
        label: String,
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) throws -> TimelineClipCommandResult {
        let result = try TimelineMediaInsertionService.insert(
            request,
            into: clipGraph,
            expectedRevision: clipGraph.revision,
            policy: policy
        )
        clipGraph = result.graph
        synchronizeTimelineEndFromClipGraph()
        recordGraphTransaction(TimelineClipUndoTransaction(
            label: label,
            commandResult: result,
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        ))
        editRevision = max(editRevision &+ 1, clipGraph.revision)
        return result
    }

    @discardableResult
    func insertMedia(
        _ requests: [TimelineMediaInsertionRequest],
        policy: TimelineMediaInsertionPolicy = .rejectOverlap,
        label: String,
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) throws -> TimelineClipCommandResult {
        let result = try TimelineMediaInsertionService.insert(
            requests,
            into: clipGraph,
            expectedRevision: clipGraph.revision,
            policy: policy
        )
        clipGraph = result.graph
        synchronizeTimelineEndFromClipGraph()
        recordGraphTransaction(TimelineClipUndoTransaction(
            label: label,
            commandResult: result,
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        ))
        editRevision = max(editRevision &+ 1, clipGraph.revision)
        return result
    }

    func undoClipCommand() throws -> TimelineClipUndoOutcome? {
        guard let outcome = try undoProjectTransaction(),
              let graphChange = outcome.transaction.graphChange else {
            return nil
        }
        return TimelineClipUndoOutcome(
            graph: outcome.graph,
            selection: outcome.selection,
            transport: outcome.transport,
            transaction: graphChange
        )
    }

    func redoClipCommand() throws -> TimelineClipUndoOutcome? {
        guard let outcome = try redoProjectTransaction(),
              let graphChange = outcome.transaction.graphChange else {
            return nil
        }
        return TimelineClipUndoOutcome(
            graph: outcome.graph,
            selection: outcome.selection,
            transport: outcome.transport,
            transaction: graphChange
        )
    }

    func recordTranscriptChange(
        label: String,
        changes: [ProjectTranscriptChange],
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) {
        guard changes.contains(where: { $0.before != $0.after }) else { return }
        for change in changes {
            if let document = change.after {
                transcriptsByTrackID[change.trackID] = document
            } else {
                transcriptsByTrackID.removeValue(forKey: change.trackID)
            }
        }
        transactionHistory.record(ProjectTransaction(
            label: label,
            transcriptChanges: changes,
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        ))
        editRevision &+= 1
    }

    @discardableResult
    func amendLatestTransactionWithTranscriptChanges(
        _ changes: [ProjectTranscriptChange]
    ) -> Bool {
        guard changes.contains(where: { $0.before != $0.after }) else { return true }
        guard transactionHistory.amendLatestUndo(with: changes) else { return false }
        for change in changes {
            if let document = change.after {
                transcriptsByTrackID[change.trackID] = document
            } else {
                transcriptsByTrackID.removeValue(forKey: change.trackID)
            }
        }
        return true
    }

    func recordGraphReplacement(
        label: String,
        beforeGraph: TimelineClipGraph,
        afterGraph: TimelineClipGraph,
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot,
        transcriptChanges: [ProjectTranscriptChange] = []
    ) throws {
        try afterGraph.validate()
        let liveTrackIDs = Set(afterGraph.tracks.map(\.id))
        let liveClipIDs = Set(afterGraph.tracks.flatMap(\.clips).map(\.id))
        let afterAutomationGraph = automationGraph.pruningOrphanedOwners(
            liveTrackIDs: liveTrackIDs,
            liveClipIDs: liveClipIDs
        )
        let automationChanges = automationLaneChanges(
            from: automationGraph,
            to: afterAutomationGraph
        )
        let affectedTrackIDs = Set(beforeGraph.tracks.map(\.id)).union(afterGraph.tracks.map(\.id))
        let changedTrackIDs = affectedTrackIDs.filter {
            beforeGraph.track(id: $0) != afterGraph.track(id: $0)
        }
        let sourceIDs = Set(beforeGraph.sources.keys).union(afterGraph.sources.keys)
        let sourceChanges = sourceIDs.compactMap { sourceID -> TimelineMediaSourceChange? in
            let before = beforeGraph.sources[sourceID]
            let after = afterGraph.sources[sourceID]
            guard before != after else { return nil }
            return TimelineMediaSourceChange(id: sourceID, before: before, after: after)
        }
        let commandResult = TimelineClipCommandResult(
            graph: afterGraph,
            affectedTrackIDs: Set(changedTrackIDs),
            beforeTracks: beforeGraph.tracks.filter { changedTrackIDs.contains($0.id) },
            afterTracks: afterGraph.tracks.filter { changedTrackIDs.contains($0.id) },
            affectedClipIDs: Set(
                (beforeGraph.tracks + afterGraph.tracks)
                    .filter { changedTrackIDs.contains($0.id) }
                    .flatMap(\.clips)
                    .map(\.id)
            ),
            beforeTrackOrder: beforeGraph.tracks.map(\.id),
            afterTrackOrder: afterGraph.tracks.map(\.id),
            sourceChanges: sourceChanges,
            beforeExplicitEndFrame: beforeGraph.explicitEndFrame,
            afterExplicitEndFrame: afterGraph.explicitEndFrame
        )
        let graphChange = TimelineClipUndoTransaction(
            label: label,
            commandResult: commandResult,
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        )
        clipGraph = afterGraph
        automationGraph = afterAutomationGraph
        for change in transcriptChanges {
            if let document = change.after {
                transcriptsByTrackID[change.trackID] = document
            } else {
                transcriptsByTrackID.removeValue(forKey: change.trackID)
            }
        }
        transactionHistory.record(ProjectTransaction(
            id: graphChange.id,
            label: label,
            graphChange: graphChange,
            transcriptChanges: transcriptChanges,
            automationChanges: automationChanges,
            beforeSelection: beforeSelection,
            afterSelection: afterSelection,
            beforeTransport: beforeTransport,
            afterTransport: afterTransport
        ))
        timelineEndTime = afterGraph.explicitEndFrame.map {
            Double($0) / afterGraph.timelineSampleRate
        }
        editRevision = max(editRevision &+ 1, afterGraph.revision)
    }

    func undoProjectTransaction() throws -> ProjectTransactionOutcome? {
        guard let outcome = try transactionHistory.undo(
            graph: clipGraph,
            automationGraph: automationGraph,
            transcriptsByTrackID: transcriptsByTrackID
        ) else { return nil }
        installHistoryOutcome(outcome)
        return outcome
    }

    func redoProjectTransaction() throws -> ProjectTransactionOutcome? {
        guard let outcome = try transactionHistory.redo(
            graph: clipGraph,
            automationGraph: automationGraph,
            transcriptsByTrackID: transcriptsByTrackID
        ) else { return nil }
        installHistoryOutcome(outcome)
        return outcome
    }

    private func recordGraphTransaction(
        _ transaction: TimelineClipUndoTransaction,
        automationChanges: [ProjectAutomationLaneChange] = []
    ) {
        transactionHistory.record(ProjectTransaction(
            id: transaction.id,
            label: transaction.label,
            graphChange: transaction,
            automationChanges: automationChanges,
            beforeSelection: transaction.beforeSelection,
            afterSelection: transaction.afterSelection,
            beforeTransport: transaction.beforeTransport,
            afterTransport: transaction.afterTransport
        ))
    }

    private func automationLaneChanges(
        from beforeGraph: TimelineAutomationGraph,
        to afterGraph: TimelineAutomationGraph
    ) -> [ProjectAutomationLaneChange] {
        let beforeByAddress = Dictionary(uniqueKeysWithValues: beforeGraph.lanes.map {
            ($0.address, $0)
        })
        let afterByAddress = Dictionary(uniqueKeysWithValues: afterGraph.lanes.map {
            ($0.address, $0)
        })
        return Set(beforeByAddress.keys).union(afterByAddress.keys).compactMap { address in
            let before = beforeByAddress[address]
            let after = afterByAddress[address]
            guard before != after else { return nil }
            return ProjectAutomationLaneChange(address: address, before: before, after: after)
        }
    }

    private func automationGraph(
        applying command: TimelineClipCommand,
        resultingGraph: TimelineClipGraph,
        startingFrom graph: TimelineAutomationGraph
    ) throws -> TimelineAutomationGraph {
        var next = graph
        switch command {
        case let .insertTime(trackIDs, timelineFrame, frameCount, _):
            next = try next.insertingTime(
                at: timelineFrame,
                frameCount: frameCount,
                affectedTrackIDs: trackIDs,
                followsTrackAutomation: true
            )
        case let .move(moves):
            for move in moves {
                next = try next.transformedForClipMove(
                    clipID: move.clipID,
                    destinationTrackID: move.destinationTrackID,
                    supportsParameter: { _, _ in false }
                )
            }
        case let .duplicate(_, clipID, _, _, newClipID):
            next = try next.duplicatingClipAutomation(
                from: clipID,
                to: newClipID
            )
        case let .duplicateMany(duplications):
            for duplication in duplications {
                next = try next.duplicatingClipAutomation(
                    from: duplication.clipID,
                    to: duplication.newClipID
                )
            }
        default:
            break
        }
        return automationGraphPruned(for: resultingGraph, startingFrom: next)
    }

    private func automationGraphPruned(
        for clipGraph: TimelineClipGraph,
        startingFrom graph: TimelineAutomationGraph
    ) -> TimelineAutomationGraph {
        graph.pruningOrphanedOwners(
            liveTrackIDs: Set(clipGraph.tracks.map(\.id)),
            liveClipIDs: Set(clipGraph.tracks.flatMap(\.clips).map(\.id))
        )
    }

    private func installHistoryOutcome(_ outcome: ProjectTransactionOutcome) {
        clipGraph = outcome.graph
        automationGraph = outcome.automationGraph
        transcriptsByTrackID = outcome.transcriptsByTrackID
        timelineEndTime = clipGraph.explicitEndFrame.map {
            Double($0) / clipGraph.timelineSampleRate
        }
        editRevision = max(editRevision &+ 1, clipGraph.revision)
    }

    private func synchronizeTimelineEndFromClipGraph() {
        timelineEndTime = clipGraph.explicitEndFrame.map {
            Double($0) / clipGraph.timelineSampleRate
        }
    }

    var clipGraphDocument: TimelineClipGraphDocument? {
        try? TimelineClipGraphDocument(graph: clipGraph)
    }

    var automationDocument: TimelineAutomationDocument {
        TimelineAutomationDocument(graph: automationGraph)
    }
}
