import Foundation

struct TimelineTrackLayout: Sendable, Equatable {
    static let `default` = TimelineTrackLayout()
    static let defaultPreferredTrackHeight: Float = 148
    static let defaultRulerLaneHeight: Float = 32
    fileprivate static let maximumAutoFitTrackCount = 4

    var scrollOffset: Float
    var preferredTrackHeight: Float
    var rulerLaneHeight: Float

    init(
        scrollOffset: Float = 0,
        preferredTrackHeight: Float = Self.defaultPreferredTrackHeight,
        rulerLaneHeight: Float = Self.defaultRulerLaneHeight
    ) {
        self.scrollOffset = max(scrollOffset, 0)
        self.preferredTrackHeight = max(preferredTrackHeight, 1)
        self.rulerLaneHeight = max(rulerLaneHeight, 0)
    }

    func resolved(totalTrackCount: Int, viewportHeight: Float) -> ResolvedTimelineTrackLayout {
        ResolvedTimelineTrackLayout(
            totalTrackCount: totalTrackCount,
            viewportHeight: viewportHeight,
            preferredTrackHeight: preferredTrackHeight,
            requestedScrollOffset: scrollOffset,
            rulerLaneHeight: rulerLaneHeight
        )
    }

    func clamped(totalTrackCount: Int, viewportHeight: Float) -> TimelineTrackLayout {
        let resolvedLayout = resolved(totalTrackCount: totalTrackCount, viewportHeight: viewportHeight)
        return TimelineTrackLayout(
            scrollOffset: resolvedLayout.scrollOffset,
            preferredTrackHeight: preferredTrackHeight,
            rulerLaneHeight: rulerLaneHeight
        )
    }

    func scrolled(
        by deltaPixels: Float,
        totalTrackCount: Int,
        viewportHeight: Float
    ) -> TimelineTrackLayout {
        let resolvedLayout = resolved(totalTrackCount: totalTrackCount, viewportHeight: viewportHeight)
        return TimelineTrackLayout(
            scrollOffset: min(max(resolvedLayout.scrollOffset + deltaPixels, 0), resolvedLayout.maximumScrollOffset),
            preferredTrackHeight: preferredTrackHeight,
            rulerLaneHeight: rulerLaneHeight
        )
    }
}

struct ResolvedTimelineTrackLayout: Sendable, Equatable {
    let totalTrackCount: Int
    let viewportHeight: Float
    let trackHeight: Float
    let scrollOffset: Float
    let contentHeight: Float
    let rulerLaneHeight: Float
    let trackViewportHeight: Float

    init(
        totalTrackCount: Int,
        viewportHeight: Float,
        preferredTrackHeight: Float,
        requestedScrollOffset: Float,
        rulerLaneHeight: Float = TimelineTrackLayout.defaultRulerLaneHeight
    ) {
        let safeTrackCount = max(totalTrackCount, 0)
        let safeViewportHeight = max(viewportHeight, 1)
        let safePreferredTrackHeight = max(preferredTrackHeight, 1)
        let safeRulerLaneHeight = min(max(rulerLaneHeight, 0), max(safeViewportHeight - 1, 0))
        let safeTrackViewportHeight = max(safeViewportHeight - safeRulerLaneHeight, 1)
        let fillTrackHeight = safeTrackCount > 0 ?
            safeTrackViewportHeight / Float(safeTrackCount) :
            safeTrackViewportHeight
        let resolvedTrackHeight: Float
        if safeTrackCount == 0 {
            resolvedTrackHeight = safeTrackViewportHeight
        } else if safeTrackCount <= TimelineTrackLayout.maximumAutoFitTrackCount {
            resolvedTrackHeight = fillTrackHeight
        } else {
            resolvedTrackHeight = max(safePreferredTrackHeight, fillTrackHeight)
        }
        let resolvedContentHeight = resolvedTrackHeight * Float(max(safeTrackCount, 1))
        let maximumScrollOffset = max(resolvedContentHeight - safeTrackViewportHeight, 0)

        self.totalTrackCount = safeTrackCount
        self.viewportHeight = safeViewportHeight
        self.trackHeight = resolvedTrackHeight
        self.scrollOffset = min(max(requestedScrollOffset, 0), maximumScrollOffset)
        self.contentHeight = resolvedContentHeight
        self.rulerLaneHeight = safeRulerLaneHeight
        self.trackViewportHeight = safeTrackViewportHeight
    }

    var maximumScrollOffset: Float {
        max(contentHeight - trackViewportHeight, 0)
    }

    var isScrollable: Bool {
        maximumScrollOffset > 0.5
    }

    func visibleRange(overscan: Int = 1) -> Range<Int> {
        guard totalTrackCount > 0 else {
            return 0..<0
        }

        let firstVisibleIndex = Int(floor(scrollOffset / trackHeight))
        let lastVisibleIndex = Int(ceil((scrollOffset + trackViewportHeight) / trackHeight))
        let lowerBound = max(firstVisibleIndex - max(overscan, 0), 0)
        let upperBound = min(lastVisibleIndex + max(overscan, 0), totalTrackCount)
        return lowerBound..<max(lowerBound, upperBound)
    }

    func laneFrame(forTrackIndex trackIndex: Int) -> TimelineTrackLaneFrame? {
        guard trackIndex >= 0, trackIndex < totalTrackCount else {
            return nil
        }

        let topPixels = rulerLaneHeight + Float(trackIndex) * trackHeight - scrollOffset
        let bottomPixels = topPixels + trackHeight
        let top = topPixels / viewportHeight
        let bottom = bottomPixels / viewportHeight
        return TimelineTrackLaneFrame(top: top, bottom: bottom)
    }

    func trackIndex(atYFromTop yFromTop: Float) -> Int? {
        guard totalTrackCount > 0 else {
            return nil
        }

        guard yFromTop >= rulerLaneHeight else {
            return nil
        }

        let trackYFromTop = min(max(yFromTop - rulerLaneHeight, 0), trackViewportHeight)
        let index = Int(floor((trackYFromTop + scrollOffset) / trackHeight))
        guard index >= 0, index < totalTrackCount else {
            return nil
        }
        return index
    }
}

struct TimelineTrackLaneFrame: Sendable, Equatable {
    let top: Float
    let bottom: Float

    var center: Float {
        (top + bottom) * 0.5
    }

    var height: Float {
        bottom - top
    }

    var isVisible: Bool {
        bottom > 0 && top < 1
    }

    var clampedTop: Float {
        min(max(top, 0), 1)
    }

    var clampedBottom: Float {
        min(max(bottom, 0), 1)
    }
}
