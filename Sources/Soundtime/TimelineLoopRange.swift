import Foundation

enum TimelineLoopEndpoint: Sendable, Equatable {
    case start
    case end
}

struct TimelineRangeEndpointVisibility: Sendable, Equatable {
    let showsLeftEndpoint: Bool
    let showsRightEndpoint: Bool

    static func projected(
        rawLeft: Float,
        rawRight: Float,
        viewportWidth: Float
    ) -> TimelineRangeEndpointVisibility {
        TimelineRangeEndpointVisibility(
            showsLeftEndpoint: rawLeft >= 0,
            showsRightEndpoint: rawRight <= viewportWidth
        )
    }
}

struct TimelineLoopCornerVisibility: Sendable, Equatable {
    let roundsLeftCorner: Bool
    let roundsRightCorner: Bool

    static func projected(
        rawLeft: Float,
        rawRight: Float,
        viewportWidth: Float
    ) -> TimelineLoopCornerVisibility {
        let endpoints = TimelineRangeEndpointVisibility.projected(
            rawLeft: rawLeft,
            rawRight: rawRight,
            viewportWidth: viewportWidth
        )
        return TimelineLoopCornerVisibility(
            roundsLeftCorner: endpoints.showsLeftEndpoint,
            roundsRightCorner: endpoints.showsRightEndpoint
        )
    }
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
        let rawLeft = viewport.viewportProgress(forTimelineProgress: startProgress)
        let rawRight = viewport.viewportProgress(forTimelineProgress: endProgress)
        return TimelineLoopCornerVisibility.projected(
            rawLeft: rawLeft,
            rawRight: rawRight,
            viewportWidth: 1
        )
    }
}

enum TimelineLoopPlaybackPolicy {
    private static let boundaryEpsilon: Float = 0.000_001

    static func bypassesLoopForExplicitSeek(
        to progress: Float,
        whilePlaying: Bool,
        loopRange: TimelineLoopRange,
        isLoopEnabled: Bool
    ) -> Bool {
        guard
            whilePlaying,
            isLoopEnabled,
            loopRange.durationProgress > 0.0001,
            loopRange.durationProgress < 0.999
        else {
            return false
        }

        return progress > loopRange.endProgress + boundaryEpsilon
    }

    static func bypassesLoopAfterRangeChange(
        playbackProgress: Float,
        whilePlaying: Bool,
        loopRange: TimelineLoopRange,
        isLoopEnabled: Bool
    ) -> Bool {
        guard
            whilePlaying,
            isLoopEnabled,
            loopRange.durationProgress > 0.0001,
            loopRange.durationProgress < 0.999
        else {
            return false
        }

        return playbackProgress > loopRange.endProgress + boundaryEpsilon
    }

    static func shouldWrapPlayback(
        at progress: Float,
        loopRange: TimelineLoopRange,
        isLoopEnabled: Bool,
        isBypassed: Bool
    ) -> Bool {
        guard
            isLoopEnabled,
            !isBypassed,
            loopRange.durationProgress > 0.0001,
            loopRange.durationProgress < 0.999,
            loopRange.endProgress > loopRange.startProgress
        else {
            return false
        }

        return progress >= loopRange.endProgress
    }
}
