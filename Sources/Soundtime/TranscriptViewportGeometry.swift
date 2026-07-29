import CoreGraphics
import Foundation

enum TranscriptViewportGeometry {
    private static let layoutCacheViewportOverscanMultiplier: TimeInterval = 2.0
    private static let minimumLayoutCachePadding: TimeInterval = 30
    private static let maximumLayoutCachePadding: TimeInterval = 90

    static func visibleProjectRange(
        viewport: TimelineViewport,
        timelineDuration: TimeInterval
    ) -> TranscriptionTimeRange {
        TranscriptionTimeRange(
            startTime: TimeInterval(viewport.startProgress) * timelineDuration,
            endTime: TimeInterval(viewport.endProgress) * timelineDuration
        )
    }

    static func layoutCacheProjectRange(
        viewport: TimelineViewport,
        timelineDuration: TimeInterval
    ) -> TranscriptionTimeRange {
        let visibleRange = visibleProjectRange(
            viewport: viewport,
            timelineDuration: timelineDuration
        )
        guard
            timelineDuration.isFinite,
            timelineDuration > 0,
            visibleRange.duration.isFinite,
            visibleRange.duration > 0,
            visibleRange.duration < timelineDuration
        else {
            return visibleRange
        }

        let padding = min(
            max(
                visibleRange.duration * layoutCacheViewportOverscanMultiplier,
                minimumLayoutCachePadding
            ),
            maximumLayoutCachePadding
        )
        return TranscriptionTimeRange(
            startTime: max(visibleRange.startTime - padding, 0),
            endTime: min(visibleRange.endTime + padding, timelineDuration)
        )
    }

    static func layoutCacheViewport(
        viewport: TimelineViewport,
        timelineDuration: TimeInterval
    ) -> TimelineViewport {
        let range = layoutCacheProjectRange(
            viewport: viewport,
            timelineDuration: timelineDuration
        )
        guard timelineDuration.isFinite, timelineDuration > 0 else {
            return viewport
        }

        return TimelineViewport(
            startProgress: Float(range.startTime / timelineDuration),
            durationProgress: Float(range.duration / timelineDuration)
        )
    }

    static func range(
        _ currentRange: TranscriptionTimeRange,
        isCoveredBy cachedRange: TranscriptionTimeRange
    ) -> Bool {
        let tolerance = max(currentRange.duration * 0.01, 0.02)
        return currentRange.startTime >= cachedRange.startTime - tolerance &&
            currentRange.endTime <= cachedRange.endTime + tolerance
    }

    static func displayRect(
        for run: TranscriptTimelineLayout.Run,
        viewport: TimelineViewport,
        timelineDuration: TimeInterval,
        boundsWidth: CGFloat
    ) -> CGRect {
        guard
            timelineDuration.isFinite,
            timelineDuration > 0,
            boundsWidth > 1
        else {
            return run.rect
        }

        let minimumDuration: TimeInterval = run.isWord ? 0.05 : 0.2
        let x0 = xPosition(
            forProjectTime: run.projectRange.startTime,
            viewport: viewport,
            timelineDuration: timelineDuration,
            boundsWidth: boundsWidth
        )
        let x1 = xPosition(
            forProjectTime: max(run.projectRange.endTime, run.projectRange.startTime + minimumDuration),
            viewport: viewport,
            timelineDuration: timelineDuration,
            boundsWidth: boundsWidth
        )
        let minimumWidth: CGFloat = run.isWord ? 18 : 36
        return CGRect(
            x: x0,
            y: run.rect.minY,
            width: max(x1 - x0, minimumWidth),
            height: run.rect.height
        )
    }

    static func xPosition(
        forProjectTime time: TimeInterval,
        viewport: TimelineViewport,
        timelineDuration: TimeInterval,
        boundsWidth: CGFloat
    ) -> CGFloat {
        guard timelineDuration > 0 else {
            return 0
        }

        let timelineProgress = Float(min(max(time / timelineDuration, 0), 1))
        let viewportProgress = viewport.viewportProgress(forTimelineProgress: timelineProgress)
        return CGFloat(viewportProgress) * boundsWidth
    }
}
