import Foundation

enum TimelineClipChromeMetrics {
    static let maximumHeaderHeight: Float = 20
    static let relativeHeaderHeight: Float = 0.18
    static let cornerRadiusPixels: Float = 24
    // Keep enough samples to preserve a curved silhouette even when the
    // corner radius collapses to half the width of a very narrow clip.
    static let cornerArcSegments = 4

    struct VerticalGeometry: Equatable, Sendable {
        let clipTop: Float
        let headerBottom: Float
        let clipBottom: Float

        var headerHeight: Float {
            max(headerBottom - clipTop, 0)
        }
    }

    struct AutomationRange: Equatable, Sendable {
        let top: Float
        let bottom: Float
    }

    /// Returns top-down pixel geometry shared by Metal and AppKit overlays.
    static func verticalGeometry(
        laneTop: Float,
        laneBottom: Float,
        viewportHeight: Float
    ) -> VerticalGeometry {
        // Lane geometry lives in the vertically scrollable content space. Do
        // not intersect it with the viewport here: deriving chrome dimensions
        // from a visible fragment makes the first/last partially visible lane
        // appear compressed. Metal/AppKit clip the completed geometry at the
        // final presentation boundary instead.
        _ = viewportHeight
        let top = laneTop.isFinite ? laneTop : 0
        let resolvedBottom = laneBottom.isFinite ? laneBottom : top
        let bottom = max(resolvedBottom, top)
        let laneHeight = max(bottom - top, 0)
        let clipTop = top
        let headerHeight = min(
            maximumHeaderHeight,
            laneHeight * relativeHeaderHeight
        )
        return VerticalGeometry(
            clipTop: clipTop,
            headerBottom: clipTop + headerHeight,
            clipBottom: bottom
        )
    }

    static func automationRange(
        laneTop: Float,
        laneBottom: Float,
        viewportHeight: Float
    ) -> AutomationRange {
        let chrome = verticalGeometry(
            laneTop: laneTop,
            laneBottom: laneBottom,
            viewportHeight: viewportHeight
        )
        let top = min(chrome.headerBottom, chrome.clipBottom - 4)
        return AutomationRange(
            top: top,
            bottom: max(chrome.clipBottom - 10, top + 1)
        )
    }
}
