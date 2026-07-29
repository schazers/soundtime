import Foundation

struct EditTransactionID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String {
        rawValue.uuidString
    }
}

struct EditRevision: Hashable, Comparable, Sendable, CustomStringConvertible {
    let rawValue: UInt64

    static let initial = EditRevision(rawValue: 1)

    func advanced() -> EditRevision {
        EditRevision(rawValue: rawValue == .max ? rawValue : rawValue + 1)
    }

    static func < (lhs: EditRevision, rhs: EditRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String {
        String(rawValue)
    }
}

/// Integer project time used by editing commands. The unit is one nanosecond.
struct ProjectTime: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    static let ticksPerSecond: Int64 = 1_000_000_000
    static let zero = ProjectTime(ticks: 0)

    let ticks: Int64

    init(ticks: Int64) {
        self.ticks = max(ticks, 0)
    }

    init(seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else {
            self = .zero
            return
        }
        let scaled = min(seconds * Double(Self.ticksPerSecond), Double(Int64.max))
        ticks = Int64(scaled.rounded())
    }

    init(frame: Int, sampleRate: Double) {
        guard frame > 0, sampleRate.isFinite, sampleRate > 0 else {
            self = .zero
            return
        }
        self.init(seconds: Double(frame) / sampleRate)
    }

    var seconds: TimeInterval {
        Double(ticks) / Double(Self.ticksPerSecond)
    }

    func frameIndex(sampleRate: Double, rounding: FloatingPointRoundingRule) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return 0
        }
        let frame = (seconds * sampleRate).rounded(rounding)
        guard frame.isFinite, frame > 0 else {
            return 0
        }
        return frame >= Double(Int.max) ? Int.max : Int(frame)
    }

    static func < (lhs: ProjectTime, rhs: ProjectTime) -> Bool {
        lhs.ticks < rhs.ticks
    }

    static func + (lhs: ProjectTime, rhs: ProjectTime) -> ProjectTime {
        let (sum, overflow) = lhs.ticks.addingReportingOverflow(rhs.ticks)
        return ProjectTime(ticks: overflow ? Int64.max : sum)
    }

    static func - (lhs: ProjectTime, rhs: ProjectTime) -> ProjectTime {
        ProjectTime(ticks: lhs.ticks > rhs.ticks ? lhs.ticks - rhs.ticks : 0)
    }

    var description: String {
        String(format: "%.9f", seconds)
    }
}

struct ProjectEditRange: Hashable, Codable, Sendable {
    let start: ProjectTime
    let end: ProjectTime

    init?(start: ProjectTime, end: ProjectTime) {
        guard end > start else {
            return nil
        }
        self.start = start
        self.end = end
    }

    var duration: ProjectTime {
        end - start
    }

    func frameRange(sampleRate: Double, frameCount: Int) -> Range<Int>? {
        let lower = min(
            max(start.frameIndex(sampleRate: sampleRate, rounding: .down), 0),
            max(frameCount, 0)
        )
        let upper = min(
            max(end.frameIndex(sampleRate: sampleRate, rounding: .up), lower),
            max(frameCount, 0)
        )
        return upper > lower ? lower..<upper : nil
    }
}

enum EditCommandKind: String, Codable, Sendable {
    case rippleDelete
    case clearGap
    case cut
    case paste
}

enum EditCommandScope: String, Codable, Sendable {
    case track
    case selected
    case group
    case all
}

struct EditCommand: Sendable {
    let transactionID: EditTransactionID
    let baseRevision: EditRevision
    let kind: EditCommandKind
    let scope: EditCommandScope
    let anchorTrackID: UUID
    let targetTrackIDs: [UUID]
    let range: ProjectEditRange?
    let insertionTime: ProjectTime?
    let clipboardID: UUID?
    let wasPlaying: Bool
    let dispatchedAt: TimeInterval

    init(
        transactionID: EditTransactionID = EditTransactionID(),
        baseRevision: EditRevision,
        kind: EditCommandKind,
        scope: EditCommandScope,
        anchorTrackID: UUID,
        targetTrackIDs: [UUID],
        range: ProjectEditRange? = nil,
        insertionTime: ProjectTime? = nil,
        clipboardID: UUID? = nil,
        wasPlaying: Bool,
        dispatchedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.transactionID = transactionID
        self.baseRevision = baseRevision
        self.kind = kind
        self.scope = scope
        self.anchorTrackID = anchorTrackID
        self.targetTrackIDs = Array(Set(targetTrackIDs)).sorted { $0.uuidString < $1.uuidString }
        self.range = range
        self.insertionTime = insertionTime
        self.clipboardID = clipboardID
        self.wasPlaying = wasPlaying
        self.dispatchedAt = dispatchedAt
    }
}

struct EditTrackDescriptor: Sendable {
    let trackID: UUID
    let sampleRate: Double
    let frameCount: Int
    let isEditable: Bool

    var duration: ProjectTime {
        ProjectTime(frame: frameCount, sampleRate: sampleRate)
    }
}

enum PlannedTrackMutation: Sendable {
    case delete(frameRange: Range<Int>)
    case clear(frameRange: Range<Int>)
    case insert(frame: Int)

    var expectedChangedFrameCount: Int {
        switch self {
        case let .delete(frameRange), let .clear(frameRange):
            return frameRange.count
        case .insert:
            return 0
        }
    }
}

struct PlannedTrackEdit: Sendable {
    let trackID: UUID
    let mutation: PlannedTrackMutation
}

struct EditPlan: Sendable {
    let command: EditCommand
    let nextRevision: EditRevision
    let trackEdits: [PlannedTrackEdit]
    let playheadTime: ProjectTime
    let resultingSelection: ProjectEditRange?
}

enum EditTransactionError: LocalizedError, Equatable {
    case staleRevision(expected: EditRevision, actual: EditRevision)
    case missingRange
    case missingInsertionTime
    case missingClipboard
    case clipboardIDMismatch
    case missingFileClipboardClip
    case missingMemoryClipboardClip
    case incompatibleClipboardSource
    case incompatibleClipboardClip
    case missingTrack(UUID)
    case duplicateTrack(UUID)
    case uneditableTrack(UUID)
    case changedProjectTopology
    case noAudioInRange
    case changedFrameCount(trackID: UUID, expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case let .staleRevision(expected, actual):
            return "The edit was planned for revision \(expected), but the project is revision \(actual)."
        case .missingRange:
            return "The edit command does not contain a valid time range."
        case .missingInsertionTime:
            return "The paste command does not contain an insertion time."
        case .missingClipboard:
            return "The paste command does not reference clipboard media."
        case .clipboardIDMismatch:
            return "The paste command references a stale clipboard revision."
        case .missingFileClipboardClip:
            return "The clipboard does not contain a file-backed clip."
        case .missingMemoryClipboardClip:
            return "The clipboard does not contain an in-memory clip."
        case .incompatibleClipboardSource:
            return "The clipboard clip belongs to a different audio source."
        case .incompatibleClipboardClip:
            return "The clipboard clip is incompatible with the destination timeline."
        case let .missingTrack(trackID):
            return "The edit target track \(trackID) no longer exists."
        case let .duplicateTrack(trackID):
            return "The edit target track \(trackID) appears more than once."
        case let .uneditableTrack(trackID):
            return "The edit target track \(trackID) is not editable."
        case .changedProjectTopology:
            return "The project track topology changed after this edit was recorded."
        case .noAudioInRange:
            return "There is no editable audio in the selected range."
        case let .changedFrameCount(trackID, expected, actual):
            return "Track \(trackID) changed \(actual) frames; the transaction expected \(expected)."
        }
    }
}

struct EditHistoryRecord<State> {
    let transactionID: EditTransactionID
    let commandKind: EditCommandKind
    let beforeRevision: EditRevision
    let afterRevision: EditRevision
    let beforeState: State
    let afterState: State
}

struct EditHistory<State> {
    private(set) var undoRecords: [EditHistoryRecord<State>] = []
    private(set) var redoRecords: [EditHistoryRecord<State>] = []

    var canUndo: Bool {
        !undoRecords.isEmpty
    }

    var canRedo: Bool {
        !redoRecords.isEmpty
    }

    mutating func record(_ record: EditHistoryRecord<State>) {
        undoRecords.append(record)
        redoRecords.removeAll(keepingCapacity: true)
    }

    mutating func popUndo() -> EditHistoryRecord<State>? {
        guard let record = undoRecords.popLast() else {
            return nil
        }
        redoRecords.append(record)
        return record
    }

    mutating func popRedo() -> EditHistoryRecord<State>? {
        guard let record = redoRecords.popLast() else {
            return nil
        }
        undoRecords.append(record)
        return record
    }

    mutating func removeAll() {
        undoRecords.removeAll(keepingCapacity: false)
        redoRecords.removeAll(keepingCapacity: false)
    }
}
