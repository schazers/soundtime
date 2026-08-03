import Foundation

struct TimelineViewport: Equatable, Sendable {
    static let full = TimelineViewport(startProgress: 0, durationProgress: 1)
    private static let minimumDurationProgress: Float = 0.000001

    let startProgress: Float
    let durationProgress: Float

    var endProgress: Float {
        min(startProgress + durationProgress, 1)
    }

    var isFull: Bool {
        startProgress <= 0.0001 && durationProgress >= 0.9999
    }

    init(startProgress: Float, durationProgress: Float) {
        let clampedDuration = min(max(durationProgress, Self.minimumDurationProgress), 1)
        let clampedStart = min(max(startProgress, 0), 1 - clampedDuration)
        self.startProgress = clampedStart
        self.durationProgress = clampedDuration
    }

    private init(presentationStartProgress: Float, presentationDurationProgress: Float) {
        self.startProgress = presentationStartProgress
        self.durationProgress = max(presentationDurationProgress, Self.minimumDurationProgress)
    }

    func timelineProgress(forViewportProgress viewportProgress: Float) -> Float {
        min(max(startProgress + min(max(viewportProgress, 0), 1) * durationProgress, 0), 1)
    }

    func viewportProgress(forTimelineProgress timelineProgress: Float) -> Float {
        guard durationProgress > 0 else {
            return 0
        }

        return (timelineProgress - startProgress) / durationProgress
    }

    func panned(byProgress progressDelta: Float) -> TimelineViewport {
        TimelineViewport(
            startProgress: startProgress + progressDelta,
            durationProgress: durationProgress
        )
    }

    func zoomed(by zoomFactor: Float, around anchorProgress: Float) -> TimelineViewport {
        let clampedZoomFactor = min(max(zoomFactor, 0.1), 10)
        let nextDuration = min(
            max(durationProgress / clampedZoomFactor, Self.minimumDurationProgress),
            1
        )
        let anchorViewportProgress = viewportProgress(forTimelineProgress: anchorProgress)
        let nextStart = anchorProgress - anchorViewportProgress * nextDuration

        return TimelineViewport(
            startProgress: nextStart,
            durationProgress: nextDuration
        )
    }

    func preservingAbsoluteTimes(previousDuration: TimeInterval, nextDuration: TimeInterval) -> TimelineViewport {
        guard
            previousDuration.isFinite,
            nextDuration.isFinite,
            previousDuration > 0,
            nextDuration > 0
        else {
            return self
        }

        let absoluteStart = Double(startProgress) * previousDuration
        let absoluteDuration = Double(durationProgress) * previousDuration
        return TimelineViewport(
            startProgress: Float(absoluteStart / nextDuration),
            durationProgress: Float(absoluteDuration / nextDuration)
        )
    }

    static func presentationViewport(
        for camera: TimelineCameraWindow,
        projectDuration: TimeInterval
    ) -> TimelineViewport {
        guard projectDuration.isFinite, projectDuration > 0 else {
            return .full
        }

        return TimelineViewport(
            presentationStartProgress: Float(camera.startTime / projectDuration),
            presentationDurationProgress: Float(camera.visibleDuration / projectDuration)
        )
    }
}

enum TimelineViewportTransitionPolicy: Sendable {
    case immediate
    case animatedEditReframe
}

struct TimelineCameraWindow: Equatable, Sendable {
    private static let minimumVisibleDuration: TimeInterval = 0.000_001

    let centerTime: TimeInterval
    let visibleDuration: TimeInterval

    var startTime: TimeInterval {
        centerTime - visibleDuration * 0.5
    }

    init(centerTime: TimeInterval, visibleDuration: TimeInterval) {
        self.visibleDuration = max(visibleDuration, Self.minimumVisibleDuration)
        self.centerTime = max(centerTime, self.visibleDuration * 0.5)
    }

    init(viewport: TimelineViewport, projectDuration: TimeInterval) {
        let duration = max(projectDuration, Self.minimumVisibleDuration)
        let visibleDuration = Double(viewport.durationProgress) * duration
        let startTime = Double(viewport.startProgress) * duration
        self.init(
            centerTime: startTime + visibleDuration * 0.5,
            visibleDuration: visibleDuration
        )
    }
}

struct TimelineCameraVelocity: Equatable, Sendable {
    static let zero = TimelineCameraVelocity(
        centerTimePerSecond: 0,
        logVisibleDurationPerSecond: 0
    )

    let centerTimePerSecond: TimeInterval
    let logVisibleDurationPerSecond: Double

    var isEffectivelyZero: Bool {
        abs(centerTimePerSecond) < 0.000_001 &&
            abs(logVisibleDurationPerSecond) < 0.000_001
    }

    func alignment(
        from source: TimelineCameraWindow,
        toward target: TimelineCameraWindow
    ) -> Double {
        let centerScale = max(source.visibleDuration, 0.000_001)
        let centerDisplacement = (target.centerTime - source.centerTime) / centerScale
        let logDurationDisplacement = log(
            max(target.visibleDuration, 0.000_001) /
                max(source.visibleDuration, 0.000_001)
        )
        return centerDisplacement * (centerTimePerSecond / centerScale) +
            logDurationDisplacement * logVisibleDurationPerSecond
    }

    func clampedForFocusRetarget(
        from source: TimelineCameraWindow,
        toward target: TimelineCameraWindow,
        duration: CFTimeInterval
    ) -> TimelineCameraVelocity {
        let safeDuration = max(duration, 0.001)
        let centerDisplacement = target.centerTime - source.centerTime
        let logDurationDisplacement = log(
            max(target.visibleDuration, 0.000_001) /
                max(source.visibleDuration, 0.000_001)
        )
        let centerLimit = max(
            abs(centerDisplacement) * 2 / safeDuration,
            source.visibleDuration * 0.12 / safeDuration
        )
        let logDurationLimit = max(
            abs(logDurationDisplacement) * 2 / safeDuration,
            0.12 / safeDuration
        )
        return TimelineCameraVelocity(
            centerTimePerSecond: min(max(centerTimePerSecond, -centerLimit), centerLimit),
            logVisibleDurationPerSecond: min(
                max(logVisibleDurationPerSecond, -logDurationLimit),
                logDurationLimit
            )
        )
    }
}

struct TimelineCameraTransition: Equatable, Sendable {
    enum Easing: Equatable, Sendable {
        case smootherstep
        case easeOutCubic

        func value(at progress: Double) -> Double {
            let t = min(max(progress, 0), 1)
            switch self {
            case .smootherstep:
                return t * t * t * (t * (t * 6 - 15) + 10)
            case .easeOutCubic:
                let remaining = 1 - t
                return 1 - remaining * remaining * remaining
            }
        }

        func derivative(at progress: Double) -> Double {
            let t = min(max(progress, 0), 1)
            switch self {
            case .smootherstep:
                return 30 * t * t * (t - 1) * (t - 1)
            case .easeOutCubic:
                let remaining = 1 - t
                return 3 * remaining * remaining
            }
        }
    }

    struct Tuning: Equatable, Sendable {
        static let editReframe = Tuning(
            duration: 0.18,
            minimumTranslationPixels: 2,
            minimumZoomRatioDelta: 0.005,
            easing: .smootherstep
        )
        static let selectionFocus = Tuning(
            duration: 0.22,
            minimumTranslationPixels: 0.5,
            minimumZoomRatioDelta: 0.001,
            easing: .easeOutCubic
        )
        static let selectionFocusOpposingMomentum = Tuning(
            duration: 0.27,
            minimumTranslationPixels: 0.5,
            minimumZoomRatioDelta: 0.001,
            easing: .easeOutCubic
        )
        static let playheadReveal = Tuning(
            duration: 0.24,
            minimumTranslationPixels: 0.5,
            minimumZoomRatioDelta: 0.001,
            easing: .easeOutCubic
        )

        let duration: CFTimeInterval
        let minimumTranslationPixels: Double
        let minimumZoomRatioDelta: Double
        let easing: Easing

        init(
            duration: CFTimeInterval,
            minimumTranslationPixels: Double,
            minimumZoomRatioDelta: Double,
            easing: Easing = .smootherstep
        ) {
            self.duration = duration
            self.minimumTranslationPixels = minimumTranslationPixels
            self.minimumZoomRatioDelta = minimumZoomRatioDelta
            self.easing = easing
        }
    }

    let source: TimelineCameraWindow
    let target: TimelineCameraWindow
    let startTimestamp: CFTimeInterval
    let tuning: Tuning
    let initialVelocity: TimelineCameraVelocity?

    init(
        source: TimelineCameraWindow,
        target: TimelineCameraWindow,
        startTimestamp: CFTimeInterval,
        tuning: Tuning,
        initialVelocity: TimelineCameraVelocity? = nil
    ) {
        self.source = source
        self.target = target
        self.startTimestamp = startTimestamp
        self.tuning = tuning
        self.initialVelocity = initialVelocity
    }

    var endTimestamp: CFTimeInterval {
        startTimestamp + max(tuning.duration, 0)
    }

    func camera(at timestamp: CFTimeInterval) -> TimelineCameraWindow {
        guard tuning.duration > 0 else {
            return target
        }

        if timestamp <= startTimestamp {
            return source
        }
        if timestamp >= endTimestamp {
            return target
        }

        let linearProgress = min(max((timestamp - startTimestamp) / tuning.duration, 0), 1)
        let sourceLogDuration = log(max(source.visibleDuration, 0.000_001))
        let targetLogDuration = log(max(target.visibleDuration, 0.000_001))
        let center: TimeInterval
        let logVisibleDuration: Double
        if let initialVelocity {
            let t = linearProgress
            let t2 = t * t
            let t3 = t2 * t
            let sourceWeight = 2 * t3 - 3 * t2 + 1
            let sourceTangentWeight = t3 - 2 * t2 + t
            let targetWeight = -2 * t3 + 3 * t2
            center = source.centerTime * sourceWeight +
                initialVelocity.centerTimePerSecond * tuning.duration * sourceTangentWeight +
                target.centerTime * targetWeight
            logVisibleDuration = sourceLogDuration * sourceWeight +
                initialVelocity.logVisibleDurationPerSecond * tuning.duration * sourceTangentWeight +
                targetLogDuration * targetWeight
        } else {
            let easedProgress = tuning.easing.value(at: linearProgress)
            center = source.centerTime + (target.centerTime - source.centerTime) * easedProgress
            logVisibleDuration = sourceLogDuration +
                (targetLogDuration - sourceLogDuration) * easedProgress
        }
        let visibleDuration = exp(logVisibleDuration)
        return TimelineCameraWindow(centerTime: center, visibleDuration: visibleDuration)
    }

    func velocity(at timestamp: CFTimeInterval) -> TimelineCameraVelocity {
        guard tuning.duration > 0, timestamp < endTimestamp else {
            return .zero
        }

        let linearProgress = min(max((timestamp - startTimestamp) / tuning.duration, 0), 1)
        let sourceLogDuration = log(max(source.visibleDuration, 0.000_001))
        let targetLogDuration = log(max(target.visibleDuration, 0.000_001))
        if let initialVelocity {
            let t = linearProgress
            let t2 = t * t
            let sourceDerivative = 6 * t2 - 6 * t
            let sourceTangentDerivative = 3 * t2 - 4 * t + 1
            let targetDerivative = -6 * t2 + 6 * t
            return TimelineCameraVelocity(
                centerTimePerSecond: (
                    source.centerTime * sourceDerivative +
                        initialVelocity.centerTimePerSecond * tuning.duration * sourceTangentDerivative +
                        target.centerTime * targetDerivative
                ) / tuning.duration,
                logVisibleDurationPerSecond: (
                    sourceLogDuration * sourceDerivative +
                        initialVelocity.logVisibleDurationPerSecond * tuning.duration * sourceTangentDerivative +
                        targetLogDuration * targetDerivative
                ) / tuning.duration
            )
        }

        let easedDerivative = tuning.easing.derivative(at: linearProgress) / tuning.duration
        return TimelineCameraVelocity(
            centerTimePerSecond: (target.centerTime - source.centerTime) * easedDerivative,
            logVisibleDurationPerSecond: (targetLogDuration - sourceLogDuration) * easedDerivative
        )
    }

    func isComplete(at timestamp: CFTimeInterval) -> Bool {
        timestamp >= endTimestamp
    }

    func isMeaningful(viewportWidth: CGFloat) -> Bool {
        let sourceDuration = max(source.visibleDuration, 0.000_001)
        let translationPixels = abs(target.centerTime - source.centerTime) /
            sourceDuration * Double(max(viewportWidth, 1))
        let zoomRatioDelta = abs(log(max(target.visibleDuration, 0.000_001) / sourceDuration))
        let velocityTranslationPixels = abs(initialVelocity?.centerTimePerSecond ?? 0) *
            tuning.duration / sourceDuration * Double(max(viewportWidth, 1))
        let velocityZoomDelta = abs(initialVelocity?.logVisibleDurationPerSecond ?? 0) *
            tuning.duration
        return translationPixels >= tuning.minimumTranslationPixels ||
            zoomRatioDelta >= tuning.minimumZoomRatioDelta ||
            velocityTranslationPixels >= tuning.minimumTranslationPixels ||
            velocityZoomDelta >= tuning.minimumZoomRatioDelta
    }
}

enum TimelineOffscreenPlayheadDirection: Equatable, Sendable {
    case left
    case right
}

struct TimelineOffscreenPlayheadNavigation: Equatable, Sendable {
    static let revealAnchorFraction: Float = 0.12

    static func direction(
        playheadProgress: Float,
        viewport: TimelineViewport,
        epsilon: Float = 0.000_001
    ) -> TimelineOffscreenPlayheadDirection? {
        if playheadProgress < viewport.startProgress - epsilon {
            return .left
        }
        if playheadProgress > viewport.endProgress + epsilon {
            return .right
        }
        return nil
    }

    static func revealViewport(
        playheadProgress: Float,
        viewport: TimelineViewport,
        anchorFraction: Float = revealAnchorFraction
    ) -> TimelineViewport {
        let clampedPlayhead = min(max(playheadProgress, 0), 1)
        let clampedAnchor = min(max(anchorFraction, 0), 1)
        return TimelineViewport(
            startProgress: clampedPlayhead - viewport.durationProgress * clampedAnchor,
            durationProgress: viewport.durationProgress
        )
    }
}

struct TimelineScalarTransition: Equatable, Sendable {
    let source: Float
    let target: Float
    let startTimestamp: CFTimeInterval
    let duration: CFTimeInterval
    let easing: TimelineCameraTransition.Easing

    var endTimestamp: CFTimeInterval {
        startTimestamp + max(duration, 0)
    }

    func value(at timestamp: CFTimeInterval) -> Float {
        guard duration > 0 else {
            return target
        }
        if timestamp <= startTimestamp {
            return source
        }
        if timestamp >= endTimestamp {
            return target
        }
        let progress = (timestamp - startTimestamp) / duration
        let eased = Float(easing.value(at: progress))
        return source + (target - source) * eased
    }

    func isComplete(at timestamp: CFTimeInterval) -> Bool {
        timestamp >= endTimestamp
    }
}

struct TimelineSelectionFocusPlan: Equatable, Sendable {
    static let horizontalMargin: CGFloat = 64

    let viewport: TimelineViewport
    let trackScrollOffset: Float

    init(
        selection: TimelineSelection,
        trackIndex: Int?,
        trackLayout: ResolvedTimelineTrackLayout,
        viewportWidth: CGFloat,
        horizontalMargin: CGFloat = Self.horizontalMargin
    ) {
        let width = max(viewportWidth, 1)
        let clampedMargin = min(max(horizontalMargin, 0), max((width - 1) * 0.5, 0))
        let selectedWidthFraction = max((width - clampedMargin * 2) / width, 0.000_001)
        let focusedDuration = Float(selection.durationProgress) / Float(selectedWidthFraction)
        let leadingMarginProgress = focusedDuration * Float(clampedMargin / width)
        viewport = TimelineViewport(
            startProgress: Float(selection.startProgress) - leadingMarginProgress,
            durationProgress: focusedDuration
        )

        guard
            let trackIndex,
            let laneFrame = trackLayout.laneFrame(forTrackIndex: trackIndex)
        else {
            trackScrollOffset = trackLayout.scrollOffset
            return
        }

        let laneCenterInViewport = laneFrame.center * trackLayout.viewportHeight
        let laneCenterInContent = laneCenterInViewport - trackLayout.rulerLaneHeight +
            trackLayout.scrollOffset
        trackScrollOffset = min(max(
            laneCenterInContent - trackLayout.trackViewportHeight * 0.5,
            0
        ), trackLayout.maximumScrollOffset)
    }
}
