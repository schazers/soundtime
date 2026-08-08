import Foundation

enum TimelineLoopEndpoint: Sendable, Equatable {
    case start
    case end
}

struct TimelineLoopEdgeResizeResult: Sendable, Equatable {
    let range: TimelineLoopRange
    let draggedEndpoint: TimelineLoopEndpoint
}

enum TimelineLoopEdgeResizeInteraction {
    static func resize(
        fixedProgress: Float,
        draggedProgress: Float,
        fallbackEndpoint: TimelineLoopEndpoint,
        minimumDuration: Float = 0
    ) -> TimelineLoopEdgeResizeResult {
        let fixed = min(max(fixedProgress, 0), 1)
        let pointer = min(max(draggedProgress, 0), 1)

        let endpoint: TimelineLoopEndpoint
        if pointer < fixed {
            endpoint = .start
        } else if pointer > fixed {
            endpoint = .end
        } else {
            endpoint = fallbackEndpoint
        }

        let minimum = min(max(minimumDuration, 0), 1)
        let adjustedPointer: Float
        switch endpoint {
        case .start:
            adjustedPointer = min(pointer, max(fixed - minimum, 0))
        case .end:
            adjustedPointer = max(pointer, min(fixed + minimum, 1))
        }

        return TimelineLoopEdgeResizeResult(
            range: TimelineLoopRange(
                startProgress: fixed,
                endProgress: adjustedPointer
            ),
            draggedEndpoint: endpoint
        )
    }
}

enum TimelineLoopRegionStyleAnimation {
    static let duration: CFTimeInterval = 0.060
    static let renderPulseDuration: CFTimeInterval = duration + (1.0 / 60.0)
}

struct TimelineLoopRegionStyleTransition: Sendable, Equatable {
    let source: Float
    let target: Float
    let startTimestamp: CFTimeInterval
    let duration: CFTimeInterval

    init(
        source: Float,
        target: Float,
        startTimestamp: CFTimeInterval,
        duration: CFTimeInterval = TimelineLoopRegionStyleAnimation.duration
    ) {
        self.source = min(max(source, 0), 1)
        self.target = min(max(target, 0), 1)
        self.startTimestamp = startTimestamp
        self.duration = max(duration, 0)
    }

    func value(at timestamp: CFTimeInterval) -> Float {
        guard duration > 0 else {
            return target
        }
        if timestamp <= startTimestamp {
            return source
        }
        if timestamp >= startTimestamp + duration {
            return target
        }

        let linearProgress = Float((timestamp - startTimestamp) / duration)
        let progress = linearProgress * linearProgress * (3 - 2 * linearProgress)
        return source + (target - source) * progress
    }

    func isComplete(at timestamp: CFTimeInterval) -> Bool {
        timestamp >= startTimestamp + duration
    }
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

enum TimelineLoopRangeProjection {
    static func localRange(
        forProjectRange projectRange: TimelineLoopRange,
        projectDuration: TimeInterval,
        localDuration: TimeInterval
    ) -> TimelineLoopRange? {
        guard
            projectDuration.isFinite,
            localDuration.isFinite,
            projectDuration > 0,
            localDuration > 0
        else {
            return nil
        }

        let projectStartTime = TimeInterval(projectRange.startProgress) * projectDuration
        let projectEndTime = TimeInterval(projectRange.endProgress) * projectDuration
        let visibleStartTime = min(max(projectStartTime, 0), localDuration)
        let visibleEndTime = min(max(projectEndTime, 0), localDuration)
        guard visibleEndTime > visibleStartTime else {
            return nil
        }

        return TimelineLoopRange(
            startProgress: Float(visibleStartTime / localDuration),
            endProgress: Float(visibleEndTime / localDuration)
        )
    }

    static func projectRange(
        forLocalRange localRange: TimelineLoopRange,
        localDuration: TimeInterval,
        projectDuration: TimeInterval
    ) -> TimelineLoopRange? {
        guard
            localDuration.isFinite,
            projectDuration.isFinite,
            localDuration > 0,
            projectDuration > 0
        else {
            return nil
        }

        let startTime = TimeInterval(localRange.startProgress) * localDuration
        let endTime = TimeInterval(localRange.endProgress) * localDuration
        return TimelineLoopRange(
            startProgress: Float(startTime / projectDuration),
            endProgress: Float(endTime / projectDuration)
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

    static func bypassesLoopWhenEnabledDuringPlayback(
        playbackProgress: Float,
        whilePlaying: Bool,
        loopRange: TimelineLoopRange
    ) -> Bool {
        bypassesLoopAfterRangeChange(
            playbackProgress: playbackProgress,
            whilePlaying: whilePlaying,
            loopRange: loopRange,
            isLoopEnabled: true
        )
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
