import Foundation

enum TimelineLoopEndpoint: Sendable, Equatable {
    case start
    case end
}

struct TimelineLoopCornerVisibility: Sendable, Equatable {
    let roundsLeftCorner: Bool
    let roundsRightCorner: Bool
}

struct TimelineLoopRange: Sendable, Equatable {
    static let `default` = TimelineLoopRange(startProgress: 0, endProgress: 1)

    let startProgress: Float
    let endProgress: Float

    init(startProgress: Float, endProgress: Float) {
        let clampedStart = min(max(startProgress, 0), 1)
        let clampedEnd = min(max(endProgress, 0), 1)
        self.startProgress = min(clampedStart, clampedEnd)
        self.endProgress = max(clampedStart, clampedEnd)
    }

    var durationProgress: Float {
        endProgress - startProgress
    }

    func movingStart(to progress: Float, minimumDuration: Float) -> TimelineLoopRange {
        TimelineLoopRange(
            startProgress: min(max(progress, 0), max(endProgress - minimumDuration, 0)),
            endProgress: endProgress
        )
    }

    func movingEnd(to progress: Float, minimumDuration: Float) -> TimelineLoopRange {
        TimelineLoopRange(
            startProgress: startProgress,
            endProgress: max(min(progress, 1), min(startProgress + minimumDuration, 1))
        )
    }

    func moving(by deltaProgress: Float) -> TimelineLoopRange {
        let clampedStart = min(max(startProgress + deltaProgress, 0), 1 - durationProgress)
        return TimelineLoopRange(
            startProgress: clampedStart,
            endProgress: clampedStart + durationProgress
        )
    }

    func cornerVisibility(in viewport: TimelineViewport) -> TimelineLoopCornerVisibility {
        TimelineLoopCornerVisibility(
            roundsLeftCorner: startProgress >= viewport.startProgress,
            roundsRightCorner: endProgress <= viewport.endProgress
        )
    }
}
