import CoreGraphics
import Foundation

enum TimelineScrollbarAxis: Sendable {
    case horizontal
    case vertical
}

enum TimelineNavigationPanGeometry {
    static func horizontalProgressDelta(
        scrollingDeltaX: CGFloat,
        viewportWidth: CGFloat,
        viewportDurationProgress: Float
    ) -> Float {
        guard viewportWidth > 0 else {
            return 0
        }
        return Float(-scrollingDeltaX / viewportWidth) * viewportDurationProgress
    }

    static func verticalTrackDelta(scrollingDeltaY: CGFloat) -> Float {
        Float(-scrollingDeltaY)
    }
}

enum TimelineNavigationScrollbarDragGeometry {
    static let interactionFramesPerSecond = 144

    static func shouldContinueDisplayPacedDrag(
        hasDragOffset: Bool,
        pressedMouseButtons: Int
    ) -> Bool {
        hasDragOffset && pressedMouseButtons & 1 != 0
    }

    static func normalizedValue(
        primaryPosition: CGFloat,
        dragOffset: CGFloat,
        handleLength: CGFloat
    ) -> Float {
        let travel = max(1 - handleLength, 0.000_001)
        return Float(min(max((primaryPosition - dragOffset) / travel, 0), 1))
    }

}

enum TimelineNavigationScrollbarVisibilityTiming {
    static let fadeDuration: TimeInterval = 0.15
    static let fadeInDuration = fadeDuration
    static let lingerDuration: TimeInterval = 0.60
    static let fadeOutDuration = fadeDuration
}

struct TimelineScrollbarGeometry: Equatable, Sendable {
    static let horizontalThickness: CGFloat = 9
    static let verticalThickness: CGFloat = 9
    static let edgeInset: CGFloat = 7
    static let minimumHandleLength: CGFloat = 34

    let horizontalTrack: CGRect
    let horizontalHandle: CGRect
    let verticalTrack: CGRect
    let verticalHandle: CGRect
    let isHorizontalScrollable: Bool
    let isVerticalScrollable: Bool

    static func resolve(
        bounds: CGRect,
        viewport: TimelineViewport,
        trackLayout: ResolvedTimelineTrackLayout
    ) -> TimelineScrollbarGeometry {
        let horizontalTrack = CGRect(
            x: edgeInset,
            y: edgeInset,
            width: max(bounds.width - edgeInset * 2 - verticalThickness - 5, 1),
            height: horizontalThickness
        )
        let horizontalHandleWidth = min(
            max(horizontalTrack.width * CGFloat(viewport.durationProgress), minimumHandleLength),
            horizontalTrack.width
        )
        let horizontalTravel = max(horizontalTrack.width - horizontalHandleWidth, 0)
        let horizontalRange = max(1 - CGFloat(viewport.durationProgress), 0.000_001)
        let horizontalFraction = min(max(CGFloat(viewport.startProgress) / horizontalRange, 0), 1)
        let horizontalHandle = CGRect(
            x: horizontalTrack.minX + horizontalTravel * horizontalFraction,
            y: horizontalTrack.minY,
            width: horizontalHandleWidth,
            height: horizontalTrack.height
        )

        let rulerHeight = CGFloat(trackLayout.rulerLaneHeight)
        let verticalTrack = CGRect(
            x: max(bounds.maxX - edgeInset - verticalThickness, 0),
            y: edgeInset + horizontalThickness + 5,
            width: verticalThickness,
            height: max(bounds.height - rulerHeight - edgeInset * 2 - horizontalThickness - 5, 1)
        )
        let visibleFraction = min(
            max(CGFloat(trackLayout.trackViewportHeight / max(trackLayout.contentHeight, 1)), 0),
            1
        )
        let verticalHandleHeight = min(
            max(verticalTrack.height * visibleFraction, minimumHandleLength),
            verticalTrack.height
        )
        let verticalTravel = max(verticalTrack.height - verticalHandleHeight, 0)
        let verticalFraction = trackLayout.maximumScrollOffset > 0 ?
            CGFloat(trackLayout.scrollOffset / trackLayout.maximumScrollOffset) : 0
        // AppKit's y axis points upward while track scroll offsets grow downward.
        let verticalHandle = CGRect(
            x: verticalTrack.minX,
            y: verticalTrack.maxY - verticalHandleHeight - verticalTravel * verticalFraction,
            width: verticalTrack.width,
            height: verticalHandleHeight
        )

        return TimelineScrollbarGeometry(
            horizontalTrack: horizontalTrack,
            horizontalHandle: horizontalHandle,
            verticalTrack: verticalTrack,
            verticalHandle: verticalHandle,
            isHorizontalScrollable: !viewport.isFull,
            isVerticalScrollable: trackLayout.maximumScrollOffset > 0
        )
    }

    func axis(at point: CGPoint, hitSlop: CGFloat = 5) -> TimelineScrollbarAxis? {
        if isHorizontalScrollable,
           horizontalHandle.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point) {
            return .horizontal
        }
        if isVerticalScrollable,
           verticalHandle.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point) {
            return .vertical
        }
        return nil
    }
}

enum TimelineTrackReorderGeometry {
    static func targetIndex(
        yFromTop: Float,
        layout: ResolvedTimelineTrackLayout
    ) -> Int? {
        guard layout.totalTrackCount > 0 else {
            return nil
        }
        let position = (yFromTop - layout.rulerLaneHeight + layout.scrollOffset) /
            max(layout.trackHeight, 1) - 0.5
        return min(max(Int(position.rounded()), 0), layout.totalTrackCount - 1)
    }

    static func trackPositions(
        count: Int,
        draggedIndex: Int,
        targetIndex: Int,
        draggedPosition: Float
    ) -> [Float] {
        guard count > 0, draggedIndex >= 0, draggedIndex < count else {
            return []
        }
        let clampedTarget = min(max(targetIndex, 0), count - 1)
        var order = Array(0..<count)
        order.remove(at: draggedIndex)
        order.insert(draggedIndex, at: clampedTarget)

        var positions = Array(repeating: Float(0), count: count)
        for (slot, logicalIndex) in order.enumerated() {
            positions[logicalIndex] = Float(slot)
        }
        positions[draggedIndex] = min(max(draggedPosition, 0), Float(count - 1))
        return positions
    }
}
