import Foundation

struct TranscriptTokenSelection: Codable, Equatable, Sendable {
    var trackID: UUID
    var wordIDs: [UUID]
    var projectRange: TranscriptionTimeRange
    var sourceRange: TranscriptionTimeRange

    init(
        trackID: UUID,
        wordIDs: [UUID],
        projectRange: TranscriptionTimeRange,
        sourceRange: TranscriptionTimeRange
    ) {
        self.trackID = trackID
        self.wordIDs = Array(Set(wordIDs)).sorted { $0.uuidString < $1.uuidString }
        self.projectRange = projectRange
        self.sourceRange = sourceRange
    }

    func timelineSelection(timelineDuration: TimeInterval) -> TimelineSelection {
        let duration = max(timelineDuration, projectRange.endTime, 0.000_001)
        return TimelineSelection(
            startProgress: projectRange.startTime / duration,
            endProgress: projectRange.endTime / duration,
            trackID: trackID
        )
    }
}

enum TranscriptEditCommandKind: String, Codable, CaseIterable, Sendable {
    case deleteWordsRipple
    case clearWordsLeaveGap
    case shortenPause
    case splitAtWordBoundary
    case nudgeWordBoundary
    case correctText
    case renameSpeaker
}

struct TranscriptEditCommand: Codable, Equatable, Sendable {
    var id: UUID
    var kind: TranscriptEditCommandKind
    var selection: TranscriptTokenSelection?
    var replacementText: String?
    var targetDuration: TimeInterval?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: TranscriptEditCommandKind,
        selection: TranscriptTokenSelection? = nil,
        replacementText: String? = nil,
        targetDuration: TimeInterval? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.selection = selection
        self.replacementText = replacementText
        self.targetDuration = targetDuration
        self.createdAt = createdAt
    }
}

enum TranscriptEditPlanner {
    static func selection(
        forWords wordIDs: Set<UUID>,
        in transcript: TranscriptDocument,
        trackID: UUID,
        timeMap: TranscriptSourceTimeMap
    ) -> TranscriptTokenSelection? {
        let words = transcript.words(matching: wordIDs)
        guard let first = words.first, let last = words.last else {
            return nil
        }
        let sourceRange = TranscriptionTimeRange(startTime: first.startTime, endTime: last.endTime)
        let outputRanges = timeMap.projectRanges(forSourceRange: sourceRange.startTime..<sourceRange.endTime)
        guard let projectStart = outputRanges.map(\.lowerBound).min(),
              let projectEnd = outputRanges.map(\.upperBound).max()
        else {
            return nil
        }

        return TranscriptTokenSelection(
            trackID: trackID,
            wordIDs: words.map(\.id),
            projectRange: TranscriptionTimeRange(startTime: projectStart, endTime: projectEnd),
            sourceRange: sourceRange
        )
    }

    static func validationMessage(for command: TranscriptEditCommand) -> String? {
        switch command.kind {
        case .deleteWordsRipple, .clearWordsLeaveGap:
            return command.selection == nil ? "Select transcript text before editing audio." : nil
        case .shortenPause:
            guard command.selection != nil else {
                return "Select a pause before shortening it."
            }
            guard (command.targetDuration ?? 0) >= 0 else {
                return "Pause duration must be non-negative."
            }
            return nil
        case .splitAtWordBoundary, .nudgeWordBoundary:
            return command.selection == nil ? "Select a transcript boundary first." : nil
        case .correctText:
            return (command.replacementText ?? "").isEmpty ? "Enter corrected transcript text." : nil
        case .renameSpeaker:
            return (command.replacementText ?? "").isEmpty ? "Enter a speaker name." : nil
        }
    }
}
