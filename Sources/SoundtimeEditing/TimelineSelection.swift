import Foundation

public struct TimelineSelection: Equatable, Sendable {
    public let startProgress: Double
    public let endProgress: Double
    public let trackID: UUID?

    public init(startProgress: Double, endProgress: Double, trackID: UUID? = nil) {
        let clampedStart = min(max(startProgress, 0), 1)
        let clampedEnd = min(max(endProgress, 0), 1)

        self.startProgress = min(clampedStart, clampedEnd)
        self.endProgress = max(clampedStart, clampedEnd)
        self.trackID = trackID
    }

    public var durationProgress: Double {
        endProgress - startProgress
    }

    public var startProgressFloat: Float {
        Float(startProgress)
    }

    public var endProgressFloat: Float {
        Float(endProgress)
    }

    public var durationProgressFloat: Float {
        Float(durationProgress)
    }

    public func duration(in totalDuration: TimeInterval) -> TimeInterval {
        durationProgress * totalDuration
    }

    public func timeRange(in totalDuration: TimeInterval) -> Range<TimeInterval>? {
        guard totalDuration.isFinite, totalDuration > 0, durationProgress > 0 else {
            return nil
        }

        return (startProgress * totalDuration)..<(endProgress * totalDuration)
    }
}

public struct TimelineSelectionDragSnapshot: Equatable, Sendable {
    public let selection: TimelineSelection
    public let leadingProgress: Float
    public let velocityPixelsPerSecond: Float
    public let direction: Float
    public let timestamp: CFTimeInterval

    public init(
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
