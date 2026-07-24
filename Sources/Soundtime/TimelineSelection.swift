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

struct TimelineSelectionDragSnapshot: Equatable, Sendable {
    let selection: TimelineSelection
    let leadingProgress: Float
    let velocityPixelsPerSecond: Float
    let direction: Float
    let timestamp: CFTimeInterval

    init(
        selection: TimelineSelection,
        leadingProgress: Float,
        velocityPixelsPerSecond: Float,
        direction: Float,
        timestamp: CFTimeInterval
    ) {
        self.selection = selection
        self.leadingProgress = min(max(leadingProgress, 0), 1)
        self.velocityPixelsPerSecond = max(velocityPixelsPerSecond, 0)
        if abs(direction) < 0.001 {
            self.direction = 0
        } else {
            self.direction = direction > 0 ? 1 : -1
        }
        self.timestamp = timestamp
    }
}
