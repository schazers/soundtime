import Foundation

/// Projects pre-edit timeline geometry through the visual phase of a ripple
/// delete. The canonical clip graph is committed separately; this projection
/// keeps the old presentation moving continuously until that graph is handed
/// to the renderer.
public enum TimelineRippleDeletePresentation {
    public static func easedProgress(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        if clamped < 0.5 {
            let halfProgress = clamped * 2
            return 0.5 * halfProgress * halfProgress
        }
        let halfProgress = (clamped - 0.5) * 2
        return 0.5 + 0.5 * (1 - pow(1 - halfProgress, 3))
    }

    public static func project(
        _ position: Double,
        deleting range: ClosedRange<Double>,
        progress: Double
    ) -> Double {
        let start = min(range.lowerBound, range.upperBound)
        let end = max(range.lowerBound, range.upperBound)
        guard end > start, position > start else {
            return position
        }

        let shift = (end - start) * min(max(progress, 0), 1)
        return max(start, position - shift)
    }

    public static func project(
        _ range: ClosedRange<Double>,
        deleting deletionRange: ClosedRange<Double>,
        progress: Double
    ) -> ClosedRange<Double> {
        let projectedStart = project(
            range.lowerBound,
            deleting: deletionRange,
            progress: progress
        )
        let projectedEnd = project(
            range.upperBound,
            deleting: deletionRange,
            progress: progress
        )
        return min(projectedStart, projectedEnd)...max(projectedStart, projectedEnd)
    }
}
