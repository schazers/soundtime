import Foundation

public struct TimelineClipSelectionSnapshot: Equatable, Codable, Sendable {
    public struct SelectedClip: Equatable, Codable, Sendable {
        public let trackID: UUID
        public let clipID: AudioTimelineClipID

        public init(trackID: UUID, clipID: AudioTimelineClipID) {
            self.trackID = trackID
            self.clipID = clipID
        }
    }

    public var selectedClips: [SelectedClip]
    public var selectedTrackIDs: Set<UUID>
    public var primarySelectedTrackID: UUID?
    public var timeRange: TimelineFrameRange?
    public var timeSelectionTrackID: UUID?

    public init(
        selectedClips: [SelectedClip] = [],
        selectedTrackIDs: Set<UUID> = [],
        primarySelectedTrackID: UUID? = nil,
        timeRange: TimelineFrameRange? = nil,
        timeSelectionTrackID: UUID? = nil
    ) {
        self.selectedClips = selectedClips
        self.selectedTrackIDs = selectedTrackIDs
        self.primarySelectedTrackID = primarySelectedTrackID
        self.timeRange = timeRange
        self.timeSelectionTrackID = timeSelectionTrackID
    }
}

public struct TimelineTransportSnapshot: Equatable, Codable, Sendable {
    public enum Focus: String, Codable, Sendable {
        case project
        case trackInspector
    }

    public var playheadFrame: Int
    public var isPlaying: Bool
    public var focus: Focus

    public init(playheadFrame: Int, isPlaying: Bool, focus: Focus = .project) {
        self.playheadFrame = playheadFrame
        self.isPlaying = isPlaying
        self.focus = focus
    }
}

public struct TimelineClipUndoTransaction: Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let affectedTrackIDs: Set<UUID>
    public let beforeTracks: [TimelineTrack]
    public let afterTracks: [TimelineTrack]
    public let beforeSelection: TimelineClipSelectionSnapshot
    public let afterSelection: TimelineClipSelectionSnapshot
    public let beforeTransport: TimelineTransportSnapshot
    public let afterTransport: TimelineTransportSnapshot
    public let leasedSourceIDs: Set<TimelineMediaSourceID>
    public let beforeTrackOrder: [UUID]
    public let afterTrackOrder: [UUID]
    public let sourceChanges: [TimelineMediaSourceChange]
    public let beforeExplicitEndFrame: Int?
    public let afterExplicitEndFrame: Int?

    public init(
        id: UUID = UUID(),
        label: String,
        commandResult: TimelineClipCommandResult,
        beforeSelection: TimelineClipSelectionSnapshot,
        afterSelection: TimelineClipSelectionSnapshot,
        beforeTransport: TimelineTransportSnapshot,
        afterTransport: TimelineTransportSnapshot
    ) {
        self.id = id
        self.label = label
        affectedTrackIDs = commandResult.affectedTrackIDs
        beforeTracks = commandResult.beforeTracks
        afterTracks = commandResult.afterTracks
        self.beforeSelection = beforeSelection
        self.afterSelection = afterSelection
        self.beforeTransport = beforeTransport
        self.afterTransport = afterTransport
        beforeTrackOrder = commandResult.beforeTrackOrder
        afterTrackOrder = commandResult.afterTrackOrder
        sourceChanges = commandResult.sourceChanges
        leasedSourceIDs = Set(
            (commandResult.beforeTracks + commandResult.afterTracks)
                .flatMap(\.clips)
                .map(\.sourceID)
        ).union(commandResult.sourceChanges.map(\.id))
        beforeExplicitEndFrame = commandResult.beforeExplicitEndFrame
        afterExplicitEndFrame = commandResult.afterExplicitEndFrame
    }

    public func restoringBefore(in graph: TimelineClipGraph) throws -> TimelineClipGraph {
        try restoring(
            graph: graph,
            tracks: beforeTracks,
            trackOrder: beforeTrackOrder,
            useBeforeSources: true,
            explicitEndFrame: beforeExplicitEndFrame
        )
    }

    public func restoringAfter(in graph: TimelineClipGraph) throws -> TimelineClipGraph {
        try restoring(
            graph: graph,
            tracks: afterTracks,
            trackOrder: afterTrackOrder,
            useBeforeSources: false,
            explicitEndFrame: afterExplicitEndFrame
        )
    }

    private func restoring(
        graph: TimelineClipGraph,
        tracks replacements: [TimelineTrack],
        trackOrder: [UUID],
        useBeforeSources: Bool,
        explicitEndFrame: Int?
    ) throws -> TimelineClipGraph {
        var sources = graph.sources
        for change in sourceChanges {
            let value = useBeforeSources ? change.before : change.after
            if let value {
                sources[change.id] = value
            } else {
                sources.removeValue(forKey: change.id)
            }
        }

        var tracksByID = Dictionary(uniqueKeysWithValues: graph.tracks.map { ($0.id, $0) })
        for trackID in affectedTrackIDs {
            tracksByID.removeValue(forKey: trackID)
        }
        for track in replacements {
            tracksByID[track.id] = track
        }
        var orderedTracks = trackOrder.compactMap { tracksByID.removeValue(forKey: $0) }
        orderedTracks.append(contentsOf: tracksByID.values.sorted { $0.id.uuidString < $1.id.uuidString })

        return try TimelineClipGraph(
            sources: Array(sources.values),
            tracks: orderedTracks,
            revision: graph.revision &+ 1,
            timelineSampleRate: graph.timelineSampleRate,
            explicitEndFrame: explicitEndFrame
        )
    }
}

public struct TimelineClipUndoOutcome: Equatable, Sendable {
    public let graph: TimelineClipGraph
    public let selection: TimelineClipSelectionSnapshot
    public let transport: TimelineTransportSnapshot
    public let transaction: TimelineClipUndoTransaction

    public init(
        graph: TimelineClipGraph,
        selection: TimelineClipSelectionSnapshot,
        transport: TimelineTransportSnapshot,
        transaction: TimelineClipUndoTransaction
    ) {
        self.graph = graph
        self.selection = selection
        self.transport = transport
        self.transaction = transaction
    }
}

public struct TimelineClipUndoHistory: Sendable {
    private var undoStack: [TimelineClipUndoTransaction] = []
    private var redoStack: [TimelineClipUndoTransaction] = []
    public var capacity: Int

    public init(capacity: Int = 200) {
        self.capacity = max(capacity, 1)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var latestUndoTransaction: TimelineClipUndoTransaction? { undoStack.last }
    public var leasedSourceIDs: Set<TimelineMediaSourceID> {
        Set((undoStack + redoStack).flatMap(\.leasedSourceIDs))
    }

    public mutating func record(_ transaction: TimelineClipUndoTransaction) {
        undoStack.append(transaction)
        if undoStack.count > capacity {
            undoStack.removeFirst(undoStack.count - capacity)
        }
        redoStack.removeAll(keepingCapacity: true)
    }

    public mutating func undo(graph: TimelineClipGraph) throws -> TimelineClipUndoOutcome? {
        guard let transaction = undoStack.popLast() else {
            return nil
        }
        let restored = try transaction.restoringBefore(in: graph)
        redoStack.append(transaction)
        return TimelineClipUndoOutcome(
            graph: restored,
            selection: transaction.beforeSelection,
            transport: transaction.beforeTransport,
            transaction: transaction
        )
    }

    public mutating func redo(graph: TimelineClipGraph) throws -> TimelineClipUndoOutcome? {
        guard let transaction = redoStack.popLast() else {
            return nil
        }
        let restored = try transaction.restoringAfter(in: graph)
        undoStack.append(transaction)
        return TimelineClipUndoOutcome(
            graph: restored,
            selection: transaction.afterSelection,
            transport: transaction.afterTransport,
            transaction: transaction
        )
    }

}

public actor TimelineMediaLeaseRegistry {
    public struct Lease: Hashable, Sendable {
        public let id: UUID
        public let sourceIDs: Set<TimelineMediaSourceID>

        fileprivate init(id: UUID, sourceIDs: Set<TimelineMediaSourceID>) {
            self.id = id
            self.sourceIDs = sourceIDs
        }
    }

    private var leasesByID: [UUID: Set<TimelineMediaSourceID>] = [:]
    private var countsBySourceID: [TimelineMediaSourceID: Int] = [:]

    public init() {}

    public func acquire(_ sourceIDs: Set<TimelineMediaSourceID>) -> Lease {
        let lease = Lease(id: UUID(), sourceIDs: sourceIDs)
        leasesByID[lease.id] = sourceIDs
        for sourceID in sourceIDs {
            countsBySourceID[sourceID, default: 0] += 1
        }
        return lease
    }

    public func release(_ lease: Lease) {
        guard let sourceIDs = leasesByID.removeValue(forKey: lease.id) else {
            return
        }
        for sourceID in sourceIDs {
            let nextCount = (countsBySourceID[sourceID] ?? 0) - 1
            if nextCount > 0 {
                countsBySourceID[sourceID] = nextCount
            } else {
                countsBySourceID.removeValue(forKey: sourceID)
            }
        }
    }

    public func isLeased(_ sourceID: TimelineMediaSourceID) -> Bool {
        (countsBySourceID[sourceID] ?? 0) > 0
    }

    public func leasedSourceIDs() -> Set<TimelineMediaSourceID> {
        Set(countsBySourceID.keys)
    }
}
