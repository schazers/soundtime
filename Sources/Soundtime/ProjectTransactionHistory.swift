import Foundation

struct ProjectTranscriptChange: Equatable, Sendable {
    let trackID: UUID
    let before: TranscriptDocument?
    let after: TranscriptDocument?
}

struct ProjectAutomationLaneChange: Equatable, Sendable {
    let address: TimelineAutomationAddress
    let before: TimelineAutomationLane?
    let after: TimelineAutomationLane?
}

/// One chronological, model-only project transaction.
///
/// Presentation caches, renderer buffers, playback projections, and AppKit
/// objects are deliberately excluded. They are regenerated after history
/// navigation from the resulting canonical graph and transcript documents.
struct ProjectTransaction: Equatable, Sendable {
    let id: UUID
    let label: String
    let graphChange: TimelineClipUndoTransaction?
    let transcriptChanges: [ProjectTranscriptChange]
    let automationChanges: [ProjectAutomationLaneChange]
    let beforeSelection: TimelineClipSelectionSnapshot
    let afterSelection: TimelineClipSelectionSnapshot
    let beforeTransport: TimelineTransportSnapshot
    let afterTransport: TimelineTransportSnapshot

    init(
        id: UUID = UUID(),
        label: String,
        graphChange: TimelineClipUndoTransaction? = nil,
        transcriptChanges: [ProjectTranscriptChange] = [],
        automationChanges: [ProjectAutomationLaneChange] = [],
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) {
        self.id = id
        self.label = label
        self.graphChange = graphChange
        self.transcriptChanges = transcriptChanges.sorted { lhs, rhs in
            lhs.trackID.uuidString < rhs.trackID.uuidString
        }
        self.automationChanges = automationChanges.sorted {
            String(describing: $0.address) < String(describing: $1.address)
        }
        self.beforeSelection = beforeSelection
        self.afterSelection = afterSelection
        self.beforeTransport = beforeTransport
        self.afterTransport = afterTransport
    }

    init(graphChange: TimelineClipUndoTransaction) {
        self.init(
            id: graphChange.id,
            label: graphChange.label,
            graphChange: graphChange,
            beforeSelection: graphChange.beforeSelection,
            afterSelection: graphChange.afterSelection,
            beforeTransport: graphChange.beforeTransport,
            afterTransport: graphChange.afterTransport
        )
    }

    var leasedSourceIDs: Set<TimelineMediaSourceID> {
        graphChange?.leasedSourceIDs ?? []
    }

    var leasedSources: [TimelineMediaSourceID: TimelineMediaSource] {
        guard let graphChange else { return [:] }
        return graphChange.sourceChanges.reduce(into: [:]) { sources, change in
            if let before = change.before { sources[before.id] = before }
            if let after = change.after { sources[after.id] = after }
        }
    }

    var leasedTrackIDs: Set<UUID> {
        guard let graphChange else { return [] }
        return Set((graphChange.beforeTracks + graphChange.afterTracks).map(\.id))
    }

    var affectedTrackIDs: Set<UUID> {
        var trackIDs = Set(transcriptChanges.map(\.trackID))
        for change in automationChanges {
            if case let .track(trackID) = change.address.owner {
                trackIDs.insert(trackID)
            }
        }
        if let graphChange {
            trackIDs.formUnion(graphChange.affectedTrackIDs)
        }
        return trackIDs
    }
}

struct ProjectTransactionOutcome: Sendable {
    let graph: TimelineClipGraph
    let automationGraph: TimelineAutomationGraph
    let transcriptsByTrackID: [UUID: TranscriptDocument]
    let selection: TimelineClipSelectionSnapshot
    let transport: TimelineTransportSnapshot
    let transaction: ProjectTransaction
}

struct ProjectTransactionHistory: Sendable {
    private var undoStack: [ProjectTransaction] = []
    private var redoStack: [ProjectTransaction] = []
    let capacity: Int

    init(capacity: Int = 500) {
        self.capacity = max(capacity, 1)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoCount: Int { undoStack.count }
    var redoCount: Int { redoStack.count }
    var latestUndoTransaction: ProjectTransaction? { undoStack.last }
    var leasedSourceIDs: Set<TimelineMediaSourceID> {
        Set((undoStack + redoStack).flatMap(\.leasedSourceIDs))
    }
    var leasedSources: [TimelineMediaSourceID: TimelineMediaSource] {
        (undoStack + redoStack).reduce(into: [:]) { sources, transaction in
            sources.merge(transaction.leasedSources) { _, latest in latest }
        }
    }
    var leasedTrackIDs: Set<UUID> {
        Set((undoStack + redoStack).flatMap(\.leasedTrackIDs))
    }

    mutating func record(_ transaction: ProjectTransaction) {
        undoStack.append(transaction)
        if undoStack.count > capacity {
            undoStack.removeFirst(undoStack.count - capacity)
        }
        redoStack.removeAll(keepingCapacity: true)
    }

    mutating func clear() {
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
    }

    mutating func amendLatestUndo(with transcriptChanges: [ProjectTranscriptChange]) -> Bool {
        guard !transcriptChanges.isEmpty, let latest = undoStack.popLast() else { return false }
        var changesByTrack = Dictionary(
            uniqueKeysWithValues: latest.transcriptChanges.map { ($0.trackID, $0) }
        )
        for change in transcriptChanges {
            if let existing = changesByTrack[change.trackID] {
                changesByTrack[change.trackID] = ProjectTranscriptChange(
                    trackID: change.trackID,
                    before: existing.before,
                    after: change.after
                )
            } else {
                changesByTrack[change.trackID] = change
            }
        }
        undoStack.append(ProjectTransaction(
            id: latest.id,
            label: latest.label,
            graphChange: latest.graphChange,
            transcriptChanges: Array(changesByTrack.values),
            automationChanges: latest.automationChanges,
            beforeSelection: latest.beforeSelection,
            afterSelection: latest.afterSelection,
            beforeTransport: latest.beforeTransport,
            afterTransport: latest.afterTransport
        ))
        return true
    }

    mutating func undo(
        graph: TimelineClipGraph,
        automationGraph: TimelineAutomationGraph,
        transcriptsByTrackID: [UUID: TranscriptDocument]
    ) throws -> ProjectTransactionOutcome? {
        guard let transaction = undoStack.popLast() else { return nil }
        do {
            let outcome = try applying(
                transaction,
                graph: graph,
                automationGraph: automationGraph,
                transcriptsByTrackID: transcriptsByTrackID,
                useBeforeState: true
            )
            redoStack.append(transaction)
            return outcome
        } catch {
            undoStack.append(transaction)
            throw error
        }
    }

    mutating func redo(
        graph: TimelineClipGraph,
        automationGraph: TimelineAutomationGraph,
        transcriptsByTrackID: [UUID: TranscriptDocument]
    ) throws -> ProjectTransactionOutcome? {
        guard let transaction = redoStack.popLast() else { return nil }
        do {
            let outcome = try applying(
                transaction,
                graph: graph,
                automationGraph: automationGraph,
                transcriptsByTrackID: transcriptsByTrackID,
                useBeforeState: false
            )
            undoStack.append(transaction)
            return outcome
        } catch {
            redoStack.append(transaction)
            throw error
        }
    }

    private func applying(
        _ transaction: ProjectTransaction,
        graph: TimelineClipGraph,
        automationGraph: TimelineAutomationGraph,
        transcriptsByTrackID: [UUID: TranscriptDocument],
        useBeforeState: Bool
    ) throws -> ProjectTransactionOutcome {
        let restoredGraph: TimelineClipGraph
        if let graphChange = transaction.graphChange {
            restoredGraph = try useBeforeState
                ? graphChange.restoringBefore(in: graph)
                : graphChange.restoringAfter(in: graph)
        } else {
            restoredGraph = graph
        }

        var restoredTranscripts = transcriptsByTrackID
        for change in transaction.transcriptChanges {
            let document = useBeforeState ? change.before : change.after
            if let document {
                restoredTranscripts[change.trackID] = document
            } else {
                restoredTranscripts.removeValue(forKey: change.trackID)
            }
        }
        let liveTrackIDs = Set(restoredGraph.tracks.map(\.id))
        restoredTranscripts = restoredTranscripts.filter { liveTrackIDs.contains($0.key) }

        var restoredAutomation = automationGraph
        for change in transaction.automationChanges {
            try restoredAutomation.restoreLane(
                at: change.address,
                to: useBeforeState ? change.before : change.after
            )
        }

        return ProjectTransactionOutcome(
            graph: restoredGraph,
            automationGraph: restoredAutomation,
            transcriptsByTrackID: restoredTranscripts,
            selection: useBeforeState ? transaction.beforeSelection : transaction.afterSelection,
            transport: useBeforeState ? transaction.beforeTransport : transaction.afterTransport,
            transaction: transaction
        )
    }
}
