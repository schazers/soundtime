import CoreGraphics
import Foundation

struct TranscriptInteractionHit: Equatable {
    var trackID: UUID
    var wordID: UUID?
    var segmentID: UUID
    var sourceRange: TranscriptionTimeRange
    var projectRange: TranscriptionTimeRange
    var rect: CGRect
    var text: String
    var isWord: Bool
    var confidence: Float?
    var speakerID: String?
}

struct TranscriptInteractionState: Equatable {
    var hoveredWordID: UUID?
    var hoveredSegmentID: UUID?
    var selectedWordIDs: Set<UUID>
    var selectedSegmentIDs: Set<UUID>
    var activeWordID: UUID?
    var mirroredTimelineSelection: TimelineSelection?
    var alignmentDebugEnabled: Bool

    static let empty = TranscriptInteractionState(
        hoveredWordID: nil,
        hoveredSegmentID: nil,
        selectedWordIDs: [],
        selectedSegmentIDs: [],
        activeWordID: nil,
        mirroredTimelineSelection: nil,
        alignmentDebugEnabled: false
    )
}

struct TranscriptInteractionDrag: Equatable {
    var anchor: TranscriptInteractionHit
    var current: TranscriptInteractionHit
}

enum TranscriptInteractionModel {
    static func state(
        previous: TranscriptInteractionState,
        hover hit: TranscriptInteractionHit?
    ) -> TranscriptInteractionState {
        var next = previous
        next.hoveredWordID = hit?.wordID
        next.hoveredSegmentID = hit?.wordID == nil ? hit?.segmentID : nil
        return next
    }

    static func state(
        previous: TranscriptInteractionState,
        selection: TranscriptTokenSelection?,
        selectedSegmentIDs: Set<UUID> = []
    ) -> TranscriptInteractionState {
        var next = previous
        next.selectedWordIDs = Set(selection?.wordIDs ?? [])
        next.selectedSegmentIDs = selectedSegmentIDs
        next.mirroredTimelineSelection = nil
        return next
    }

    static func state(
        previous: TranscriptInteractionState,
        activeWordID: UUID?
    ) -> TranscriptInteractionState {
        var next = previous
        next.activeWordID = activeWordID
        return next
    }

    static func state(
        previous: TranscriptInteractionState,
        mirroredTimelineSelection: TimelineSelection?
    ) -> TranscriptInteractionState {
        var next = previous
        next.mirroredTimelineSelection = mirroredTimelineSelection
        return next
    }

    static func state(
        previous: TranscriptInteractionState,
        alignmentDebugEnabled: Bool
    ) -> TranscriptInteractionState {
        var next = previous
        next.alignmentDebugEnabled = alignmentDebugEnabled
        return next
    }

    static func selection(
        from anchor: TranscriptInteractionHit,
        to current: TranscriptInteractionHit,
        visibleRuns: [TranscriptInteractionHit],
        transcript: TranscriptDocument,
        timeMap: TranscriptSourceTimeMap
    ) -> TranscriptTokenSelection? {
        guard anchor.trackID == current.trackID else {
            return selection(from: current, transcript: transcript, timeMap: timeMap)
        }

        let startTime = min(anchor.sourceRange.startTime, current.sourceRange.startTime)
        let endTime = max(anchor.sourceRange.endTime, current.sourceRange.endTime)
        let visibleWordIDs = Set(visibleRuns.compactMap(\.wordID))
        let wordIDs = transcript.words(overlapping: startTime..<endTime)
            .filter { visibleWordIDs.isEmpty || visibleWordIDs.contains($0.id) }
            .map(\.id)

        if !wordIDs.isEmpty {
            return TranscriptEditPlanner.selection(
                forWords: Set(wordIDs),
                in: transcript,
                trackID: anchor.trackID,
                timeMap: timeMap
            )
        }

        return TranscriptTokenSelection(
            trackID: anchor.trackID,
            wordIDs: [],
            projectRange: TranscriptionTimeRange(
                startTime: min(anchor.projectRange.startTime, current.projectRange.startTime),
                endTime: max(anchor.projectRange.endTime, current.projectRange.endTime)
            ),
            sourceRange: TranscriptionTimeRange(startTime: startTime, endTime: endTime)
        )
    }

    static func selection(
        from hit: TranscriptInteractionHit,
        transcript: TranscriptDocument,
        timeMap: TranscriptSourceTimeMap
    ) -> TranscriptTokenSelection? {
        if let wordID = hit.wordID {
            return TranscriptEditPlanner.selection(
                forWords: [wordID],
                in: transcript,
                trackID: hit.trackID,
                timeMap: timeMap
            )
        }

        let wordIDs = transcript.words(overlapping: hit.sourceRange.startTime..<hit.sourceRange.endTime)
            .map(\.id)
        if !wordIDs.isEmpty {
            return TranscriptEditPlanner.selection(
                forWords: Set(wordIDs),
                in: transcript,
                trackID: hit.trackID,
                timeMap: timeMap
            )
        }

        return TranscriptTokenSelection(
            trackID: hit.trackID,
            wordIDs: [],
            projectRange: hit.projectRange,
            sourceRange: hit.sourceRange
        )
    }

    static func selection(
        extending existing: TranscriptTokenSelection,
        to hit: TranscriptInteractionHit,
        transcript: TranscriptDocument,
        timeMap: TranscriptSourceTimeMap
    ) -> TranscriptTokenSelection? {
        guard existing.trackID == hit.trackID else {
            return selection(from: hit, transcript: transcript, timeMap: timeMap)
        }

        let sourceStart = min(existing.sourceRange.startTime, hit.sourceRange.startTime)
        let sourceEnd = max(existing.sourceRange.endTime, hit.sourceRange.endTime)
        let wordIDs = transcript.words(overlapping: sourceStart..<sourceEnd).map(\.id)
        guard !wordIDs.isEmpty else {
            return TranscriptTokenSelection(
                trackID: hit.trackID,
                wordIDs: [],
                projectRange: TranscriptionTimeRange(
                    startTime: min(existing.projectRange.startTime, hit.projectRange.startTime),
                    endTime: max(existing.projectRange.endTime, hit.projectRange.endTime)
                ),
                sourceRange: TranscriptionTimeRange(startTime: sourceStart, endTime: sourceEnd)
            )
        }

        return TranscriptEditPlanner.selection(
            forWords: Set(wordIDs),
            in: transcript,
            trackID: hit.trackID,
            timeMap: timeMap
        )
    }
}
