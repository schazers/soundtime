import Foundation

public struct TimelineTrimRange: Equatable, Sendable {
    public let startProgress: Float
    public let endProgress: Float

    public init(startProgress: Float, endProgress: Float) {
        let clampedStart = min(max(startProgress, 0), 1)
        let clampedEnd = min(max(endProgress, 0), 1)

        self.startProgress = min(clampedStart, clampedEnd)
        self.endProgress = max(clampedStart, clampedEnd)
    }

    public var durationProgress: Float {
        endProgress - startProgress
    }

    public var trimsAudio: Bool {
        startProgress > 0.001 || endProgress < 0.999
    }

    public func trimmedDuration(in totalDuration: TimeInterval) -> TimeInterval {
        TimeInterval(1 - durationProgress) * totalDuration
    }
}
