import Foundation

struct TimelineSelection: Equatable, Sendable {
    let startProgress: Double
    let endProgress: Double
    let trackID: UUID?

    init(startProgress: Double, endProgress: Double, trackID: UUID? = nil) {
        let clampedStart = min(max(startProgress, 0), 1)
        let clampedEnd = min(max(endProgress, 0), 1)

        self.startProgress = min(clampedStart, clampedEnd)
        self.endProgress = max(clampedStart, clampedEnd)
        self.trackID = trackID
    }

    var durationProgress: Double {
        endProgress - startProgress
    }

    var startProgressFloat: Float {
        Float(startProgress)
    }

    var endProgressFloat: Float {
        Float(endProgress)
    }

    var durationProgressFloat: Float {
        Float(durationProgress)
    }

    func duration(in totalDuration: TimeInterval) -> TimeInterval {
        durationProgress * totalDuration
    }
}
