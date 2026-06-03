import Foundation

struct TimelineSelection: Equatable, Sendable {
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

    func duration(in totalDuration: TimeInterval) -> TimeInterval {
        TimeInterval(durationProgress) * totalDuration
    }
}
