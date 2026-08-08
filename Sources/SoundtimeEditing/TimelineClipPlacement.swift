import Foundation

public struct TimelineClipPlacement: Equatable, Sendable {
    public let clipID: AudioTimelineClipID
    public let destinationTrackID: UUID
    public let timelineRange: TimelineFrameRange

    public init(
        clipID: AudioTimelineClipID,
        destinationTrackID: UUID,
        timelineRange: TimelineFrameRange
    ) {
        self.clipID = clipID
        self.destinationTrackID = destinationTrackID
        self.timelineRange = timelineRange
    }
}

public struct TimelineClipPlacementConflict: Equatable, Sendable {
    public let trackID: UUID
    public let movingClipID: AudioTimelineClipID
    public let conflictingClipID: AudioTimelineClipID

    public init(
        trackID: UUID,
        movingClipID: AudioTimelineClipID,
        conflictingClipID: AudioTimelineClipID
    ) {
        self.trackID = trackID
        self.movingClipID = movingClipID
        self.conflictingClipID = conflictingClipID
    }
}

public enum TimelineClipPlacementDecision: Equatable, Sendable {
    case allowed
    case rejected([TimelineClipPlacementConflict])

    public var isAllowed: Bool {
        self == .allowed
    }
}

public enum TimelineClipPlacementValidator {
    public static func evaluate(
        _ placements: [TimelineClipPlacement],
        in graph: TimelineClipGraph
    ) throws -> TimelineClipPlacementDecision {
        let movingIDs = Set(placements.map(\.clipID))
        guard movingIDs.count == placements.count else {
            let duplicateID = Dictionary(grouping: placements, by: \.clipID)
                .first(where: { $0.value.count > 1 })!
                .key
            throw TimelineClipGraphError.duplicateClip(
                duplicateID
            )
        }

        var conflicts: [TimelineClipPlacementConflict] = []
        for placement in placements {
            guard placement.timelineRange.startFrame >= 0, placement.timelineRange.frameCount > 0 else {
                throw TimelineClipGraphError.invalidTimelineRange(placement.clipID)
            }
            guard let destinationTrack = graph.track(id: placement.destinationTrackID) else {
                throw TimelineClipGraphError.missingTrack(placement.destinationTrackID)
            }
            for existing in destinationTrack.conflicts(
                with: placement.timelineRange,
                excluding: movingIDs
            ) {
                conflicts.append(TimelineClipPlacementConflict(
                    trackID: placement.destinationTrackID,
                    movingClipID: placement.clipID,
                    conflictingClipID: existing.id
                ))
            }
        }

        for leftIndex in placements.indices {
            for rightIndex in placements.indices where rightIndex > leftIndex {
                let left = placements[leftIndex]
                let right = placements[rightIndex]
                guard
                    left.destinationTrackID == right.destinationTrackID,
                    left.timelineRange.intersects(right.timelineRange)
                else {
                    continue
                }
                conflicts.append(TimelineClipPlacementConflict(
                    trackID: left.destinationTrackID,
                    movingClipID: left.clipID,
                    conflictingClipID: right.clipID
                ))
            }
        }

        let ordered = conflicts.sorted { lhs, rhs in
            if lhs.trackID != rhs.trackID {
                return lhs.trackID.uuidString < rhs.trackID.uuidString
            }
            if lhs.movingClipID != rhs.movingClipID {
                return lhs.movingClipID.rawValue.uuidString < rhs.movingClipID.rawValue.uuidString
            }
            return lhs.conflictingClipID.rawValue.uuidString < rhs.conflictingClipID.rawValue.uuidString
        }
        return ordered.isEmpty ? .allowed : .rejected(ordered)
    }

    public static func requireAllowed(
        _ placements: [TimelineClipPlacement],
        in graph: TimelineClipGraph
    ) throws {
        switch try evaluate(placements, in: graph) {
        case .allowed:
            return
        case let .rejected(conflicts):
            let firstTrackID = conflicts[0].trackID
            let conflictingIDs = Set(
                conflicts
                    .filter { $0.trackID == firstTrackID }
                    .map(\.conflictingClipID)
            )
            throw TimelineClipGraphError.destinationOccupied(
                trackID: firstTrackID,
                conflicts: conflictingIDs.sorted {
                    $0.rawValue.uuidString < $1.rawValue.uuidString
                }
            )
        }
    }
}
