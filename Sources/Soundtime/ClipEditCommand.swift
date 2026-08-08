import Foundation

struct ClipEditTarget: Equatable, Sendable {
    let trackID: UUID
    let clipID: AudioTimelineClipID
    let expectedEditRevision: Int
}

enum ClipFollowingContentPolicy: String, Codable, Sendable {
    case ripple
    case preserveTimelinePositions

    var timelinePolicy: AudioTimelineFollowingClipPolicy {
        switch self {
        case .ripple:
            return .ripple
        case .preserveTimelinePositions:
            return .preserveTimelinePositions
        }
    }
}

enum ClipEditOperation: Equatable, Sendable {
    case delete(localFrameRange: Range<Int>, followingContent: ClipFollowingContentPolicy)
    case clear(localFrameRange: Range<Int>)
    case paste(localFrame: Int, clipboardID: UUID)
    case split(localFrame: Int)
    case trimStart(localFrame: Int)
    case trimEnd(localFrame: Int)
    case duplicate(destinationFrame: Int)
    case move(destinationFrame: Int)
    case relocate(destinationFrame: Int)
    case deleteClip
}

struct ClipEditCommand: Equatable, Sendable {
    let transactionID: UUID
    let target: ClipEditTarget
    let operation: ClipEditOperation

    init(
        transactionID: UUID = UUID(),
        target: ClipEditTarget,
        operation: ClipEditOperation
    ) {
        self.transactionID = transactionID
        self.target = target
        self.operation = operation
    }
}

enum ClipEditCommandError: LocalizedError, Equatable {
    case trackMissing
    case staleRevision
    case clipMissing
    case invalidLocalRange
    case destinationOccupied
    case unsupportedSource

    var errorDescription: String? {
        switch self {
        case .trackMissing:
            return "The clip's track no longer exists."
        case .staleRevision:
            return "The clip changed before the edit could be applied."
        case .clipMissing:
            return "The clip no longer exists."
        case .invalidLocalRange:
            return "The selected clip range is empty."
        case .destinationOccupied:
            return "The clip cannot be placed on top of existing audio."
        case .unsupportedSource:
            return "This clip source is not editable yet."
        }
    }
}
