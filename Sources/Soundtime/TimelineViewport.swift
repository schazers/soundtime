import Foundation

struct TimelineViewport: Equatable, Sendable {
    static let full = TimelineViewport(startProgress: 0, durationProgress: 1)

    let startProgress: Float
    let durationProgress: Float

    var endProgress: Float {
        min(startProgress + durationProgress, 1)
    }

    var isFull: Bool {
        startProgress <= 0.0001 && durationProgress >= 0.9999
    }

    init(startProgress: Float, durationProgress: Float) {
        let clampedDuration = min(max(durationProgress, 0.01), 1)
        let clampedStart = min(max(startProgress, 0), 1 - clampedDuration)
        self.startProgress = clampedStart
        self.durationProgress = clampedDuration
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
        let nextDuration = min(max(durationProgress / clampedZoomFactor, 0.01), 1)
        let anchorViewportProgress = viewportProgress(forTimelineProgress: anchorProgress)
        let nextStart = anchorProgress - anchorViewportProgress * nextDuration

        return TimelineViewport(
            startProgress: nextStart,
            durationProgress: nextDuration
        )
    }
}
