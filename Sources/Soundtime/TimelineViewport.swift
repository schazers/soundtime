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
        self.startProgress = max(presentationStartProgress, 0)
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

struct TimelineCameraTransition: Equatable, Sendable {
    struct Tuning: Equatable, Sendable {
        static let editReframe = Tuning(
            duration: 0.18,
            minimumTranslationPixels: 2,
            minimumZoomRatioDelta: 0.005
        )

        let duration: CFTimeInterval
        let minimumTranslationPixels: Double
        let minimumZoomRatioDelta: Double
    }

    let source: TimelineCameraWindow
    let target: TimelineCameraWindow
    let startTimestamp: CFTimeInterval
    let tuning: Tuning

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
        let easedProgress = Self.smootherstep(linearProgress)
        let center = source.centerTime + (target.centerTime - source.centerTime) * easedProgress
        let sourceLogDuration = log(max(source.visibleDuration, 0.000_001))
        let targetLogDuration = log(max(target.visibleDuration, 0.000_001))
        let visibleDuration = exp(
            sourceLogDuration + (targetLogDuration - sourceLogDuration) * easedProgress
        )
        return TimelineCameraWindow(centerTime: center, visibleDuration: visibleDuration)
    }

    func isComplete(at timestamp: CFTimeInterval) -> Bool {
        timestamp >= endTimestamp
    }

    func isMeaningful(viewportWidth: CGFloat) -> Bool {
        let sourceDuration = max(source.visibleDuration, 0.000_001)
        let translationPixels = abs(target.centerTime - source.centerTime) /
            sourceDuration * Double(max(viewportWidth, 1))
        let zoomRatioDelta = abs(log(max(target.visibleDuration, 0.000_001) / sourceDuration))
        return translationPixels >= tuning.minimumTranslationPixels ||
            zoomRatioDelta >= tuning.minimumZoomRatioDelta
    }

    private static func smootherstep(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}
