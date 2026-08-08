import Foundation

struct TimelineTrackLayout: Sendable, Equatable {
    static let `default` = TimelineTrackLayout()
    static let defaultPreferredTrackHeight: Float = 200
    static let defaultRulerLaneHeight: Float = 40
    fileprivate static let maximumAutoFitTrackCount = 4

    var scrollOffset: Float
    var preferredTrackHeight: Float
    var automaticallyFitsTrackHeight: Bool
    var rulerLaneHeight: Float
    var insertionTrackIndex: Int?
    var insertionProgress: Float
    var trackPositions: [Float]?

    init(
        scrollOffset: Float = 0,
        preferredTrackHeight: Float = Self.defaultPreferredTrackHeight,
        automaticallyFitsTrackHeight: Bool = false,
        rulerLaneHeight: Float = Self.defaultRulerLaneHeight,
        insertionTrackIndex: Int? = nil,
        insertionProgress: Float = 1,
        trackPositions: [Float]? = nil
    ) {
        self.scrollOffset = max(scrollOffset, 0)
        self.preferredTrackHeight = max(preferredTrackHeight, 1)
        self.automaticallyFitsTrackHeight = automaticallyFitsTrackHeight
        self.rulerLaneHeight = max(rulerLaneHeight, 0)
        self.trackPositions = trackPositions
        if let insertionTrackIndex, insertionProgress < 0.999 {
            self.insertionTrackIndex = max(insertionTrackIndex, 0)
            self.insertionProgress = min(max(insertionProgress, 0), 1)
        } else {
            self.insertionTrackIndex = nil
            self.insertionProgress = 1
        }
    }

    func resolved(totalTrackCount: Int, viewportHeight: Float) -> ResolvedTimelineTrackLayout {
        ResolvedTimelineTrackLayout(
            totalTrackCount: totalTrackCount,
            viewportHeight: viewportHeight,
            preferredTrackHeight: preferredTrackHeight,
            automaticallyFitsTrackHeight: automaticallyFitsTrackHeight,
            requestedScrollOffset: scrollOffset,
            rulerLaneHeight: rulerLaneHeight,
            insertionTrackIndex: insertionTrackIndex,
            insertionProgress: insertionProgress,
            trackPositions: trackPositions
        )
    }

    func clamped(totalTrackCount: Int, viewportHeight: Float) -> TimelineTrackLayout {
        let resolvedLayout = resolved(totalTrackCount: totalTrackCount, viewportHeight: viewportHeight)
        return TimelineTrackLayout(
            scrollOffset: resolvedLayout.scrollOffset,
            preferredTrackHeight: preferredTrackHeight,
            automaticallyFitsTrackHeight: automaticallyFitsTrackHeight,
            rulerLaneHeight: rulerLaneHeight,
            insertionTrackIndex: insertionTrackIndex,
            insertionProgress: insertionProgress,
            trackPositions: trackPositions
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
            automaticallyFitsTrackHeight: automaticallyFitsTrackHeight,
            rulerLaneHeight: rulerLaneHeight,
            insertionTrackIndex: insertionTrackIndex,
            insertionProgress: insertionProgress,
            trackPositions: trackPositions
        )
    }

    func withScrollOffset(
        _ scrollOffset: Float,
        totalTrackCount: Int,
        viewportHeight: Float
    ) -> TimelineTrackLayout {
        let resolvedLayout = resolved(totalTrackCount: totalTrackCount, viewportHeight: viewportHeight)
        return TimelineTrackLayout(
            scrollOffset: min(max(scrollOffset, 0), resolvedLayout.maximumScrollOffset),
            preferredTrackHeight: preferredTrackHeight,
            automaticallyFitsTrackHeight: automaticallyFitsTrackHeight,
            rulerLaneHeight: rulerLaneHeight,
            insertionTrackIndex: insertionTrackIndex,
            insertionProgress: insertionProgress,
            trackPositions: trackPositions
        )
    }

    func withPreferredTrackHeight(_ preferredTrackHeight: Float) -> TimelineTrackLayout {
        TimelineTrackLayout(
            scrollOffset: scrollOffset,
            preferredTrackHeight: preferredTrackHeight,
            automaticallyFitsTrackHeight: false,
            rulerLaneHeight: rulerLaneHeight,
            insertionTrackIndex: insertionTrackIndex,
            insertionProgress: insertionProgress,
            trackPositions: trackPositions
        )
    }

    func withTrackPositions(_ trackPositions: [Float]?) -> TimelineTrackLayout {
        TimelineTrackLayout(
            scrollOffset: scrollOffset,
            preferredTrackHeight: preferredTrackHeight,
            automaticallyFitsTrackHeight: automaticallyFitsTrackHeight,
            rulerLaneHeight: rulerLaneHeight,
            insertionTrackIndex: insertionTrackIndex,
            insertionProgress: insertionProgress,
            trackPositions: trackPositions
        )
    }

    func insertingTrack(at trackIndex: Int, progress: Float) -> TimelineTrackLayout {
        TimelineTrackLayout(
            scrollOffset: scrollOffset,
            preferredTrackHeight: preferredTrackHeight,
            automaticallyFitsTrackHeight: automaticallyFitsTrackHeight,
            rulerLaneHeight: rulerLaneHeight,
            insertionTrackIndex: trackIndex,
            insertionProgress: progress,
            trackPositions: trackPositions
        )
    }

    func clearingInsertionAnimation() -> TimelineTrackLayout {
        TimelineTrackLayout(
            scrollOffset: scrollOffset,
            preferredTrackHeight: preferredTrackHeight,
            automaticallyFitsTrackHeight: automaticallyFitsTrackHeight,
            rulerLaneHeight: rulerLaneHeight,
            trackPositions: trackPositions
        )
    }
}

enum TimelineRulerLaneGeometry {
    static let loopBandFraction: Float = 0.5

    static func loopBandHeight(for rulerHeight: Float) -> Float {
        max(rulerHeight, 0) * loopBandFraction
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
    let insertionTrackIndex: Int?
    let insertionProgress: Float
    let insertedTrackHeight: Float
    let trackPositions: [Float]?

    init(
        totalTrackCount: Int,
        viewportHeight: Float,
        preferredTrackHeight: Float,
        automaticallyFitsTrackHeight: Bool = false,
        requestedScrollOffset: Float,
        rulerLaneHeight: Float = TimelineTrackLayout.defaultRulerLaneHeight,
        insertionTrackIndex: Int? = nil,
        insertionProgress: Float = 1,
        trackPositions: [Float]? = nil
    ) {
        let safeTrackCount = max(totalTrackCount, 0)
        let safeViewportHeight = max(viewportHeight, 1)
        let safePreferredTrackHeight = max(preferredTrackHeight, 1)
        let safeRulerLaneHeight = min(max(rulerLaneHeight, 0), max(safeViewportHeight - 1, 0))
        let safeTrackViewportHeight = max(safeViewportHeight - safeRulerLaneHeight, 1)
        let clampedInsertionProgress = min(max(insertionProgress, 0), 1)
        let clampedInsertionTrackIndex: Int?
        if
            let insertionTrackIndex,
            safeTrackCount > 0,
            clampedInsertionProgress < 0.999
        {
            clampedInsertionTrackIndex = min(max(insertionTrackIndex, 0), safeTrackCount - 1)
        } else {
            clampedInsertionTrackIndex = nil
        }

        let resolvedTrackHeight: Float
        let resolvedInsertedTrackHeight: Float
        let resolvedContentHeight: Float
        if clampedInsertionTrackIndex != nil {
            let previousTrackCount = max(safeTrackCount - 1, 0)
            let previousTrackHeight = Self.resolvedTrackHeight(
                totalTrackCount: previousTrackCount,
                trackViewportHeight: safeTrackViewportHeight,
                preferredTrackHeight: safePreferredTrackHeight,
                automaticallyFitsTrackHeight: automaticallyFitsTrackHeight
            )
            let finalTrackHeight = Self.resolvedTrackHeight(
                totalTrackCount: safeTrackCount,
                trackViewportHeight: safeTrackViewportHeight,
                preferredTrackHeight: safePreferredTrackHeight,
                automaticallyFitsTrackHeight: automaticallyFitsTrackHeight
            )
            resolvedTrackHeight = previousTrackHeight + (finalTrackHeight - previousTrackHeight) *
                clampedInsertionProgress
            resolvedInsertedTrackHeight = finalTrackHeight * clampedInsertionProgress
            resolvedContentHeight = resolvedTrackHeight * Float(previousTrackCount) + resolvedInsertedTrackHeight
        } else {
            resolvedTrackHeight = Self.resolvedTrackHeight(
                totalTrackCount: safeTrackCount,
                trackViewportHeight: safeTrackViewportHeight,
                preferredTrackHeight: safePreferredTrackHeight,
                automaticallyFitsTrackHeight: automaticallyFitsTrackHeight
            )
            resolvedInsertedTrackHeight = resolvedTrackHeight
            resolvedContentHeight = resolvedTrackHeight * Float(max(safeTrackCount, 1))
        }
        let maximumScrollOffset = max(resolvedContentHeight - safeTrackViewportHeight, 0)

        self.totalTrackCount = safeTrackCount
        self.viewportHeight = safeViewportHeight
        self.trackHeight = resolvedTrackHeight
        self.scrollOffset = min(max(requestedScrollOffset, 0), maximumScrollOffset)
        self.contentHeight = resolvedContentHeight
        self.rulerLaneHeight = safeRulerLaneHeight
        self.trackViewportHeight = safeTrackViewportHeight
        self.insertionTrackIndex = clampedInsertionTrackIndex
        self.insertionProgress = clampedInsertionTrackIndex == nil ? 1 : clampedInsertionProgress
        self.insertedTrackHeight = resolvedInsertedTrackHeight
        self.trackPositions = trackPositions?.count == safeTrackCount ? trackPositions : nil
    }

    private static func resolvedTrackHeight(
        totalTrackCount: Int,
        trackViewportHeight: Float,
        preferredTrackHeight: Float,
        automaticallyFitsTrackHeight: Bool
    ) -> Float {
        let safeTrackCount = max(totalTrackCount, 0)
        let fillTrackHeight = safeTrackCount > 0 ?
            trackViewportHeight / Float(safeTrackCount) :
            trackViewportHeight
        if safeTrackCount == 0 {
            return trackViewportHeight
        } else if automaticallyFitsTrackHeight && safeTrackCount <= TimelineTrackLayout.maximumAutoFitTrackCount {
            return fillTrackHeight
        } else if automaticallyFitsTrackHeight {
            return max(preferredTrackHeight, fillTrackHeight)
        } else {
            return preferredTrackHeight
        }
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

        if insertionTrackIndex != nil || trackPositions != nil {
            var lowerBound: Int?
            var upperBound = 0
            for trackIndex in 0..<totalTrackCount {
                guard let laneFrame = laneFrame(forTrackIndex: trackIndex) else {
                    continue
                }
                let overscanAmount = Float(max(overscan, 0)) * max(trackHeight, insertedTrackHeight) / viewportHeight
                if laneFrame.bottom > -overscanAmount && laneFrame.top < 1 + overscanAmount {
                    lowerBound = min(lowerBound ?? trackIndex, trackIndex)
                    upperBound = max(upperBound, trackIndex + 1)
                }
            }
            guard let lowerBound else {
                return 0..<0
            }
            return lowerBound..<min(max(upperBound, lowerBound), totalTrackCount)
        }

        let firstVisibleIndex = Int(floor(scrollOffset / trackHeight))
        let lastVisibleIndex = Int(ceil((scrollOffset + trackViewportHeight) / trackHeight))
        let lowerBound = max(firstVisibleIndex - max(overscan, 0), 0)
        let upperBound = min(lastVisibleIndex + max(overscan, 0), totalTrackCount)
        return lowerBound..<max(lowerBound, upperBound)
    }

    func visibleTrackIndices(overscan: Int = 1) -> [Int] {
        guard totalTrackCount > 0 else {
            return []
        }
        guard insertionTrackIndex != nil || trackPositions != nil else {
            return Array(visibleRange(overscan: overscan))
        }

        let overscanAmount = Float(max(overscan, 0)) * max(trackHeight, insertedTrackHeight) /
            viewportHeight
        return (0..<totalTrackCount).filter { trackIndex in
            guard let laneFrame = laneFrame(forTrackIndex: trackIndex) else {
                return false
            }
            return laneFrame.bottom > -overscanAmount && laneFrame.top < 1 + overscanAmount
        }
    }

    func laneFrame(forTrackIndex trackIndex: Int) -> TimelineTrackLaneFrame? {
        guard trackIndex >= 0, trackIndex < totalTrackCount else {
            return nil
        }

        let topPixels: Float
        let bottomPixels: Float
        if let trackPositions {
            topPixels = rulerLaneHeight + trackPositions[trackIndex] * trackHeight - scrollOffset
            bottomPixels = topPixels + trackHeight
        } else if let insertionTrackIndex {
            if trackIndex < insertionTrackIndex {
                topPixels = rulerLaneHeight + Float(trackIndex) * trackHeight - scrollOffset
                bottomPixels = topPixels + trackHeight
            } else if trackIndex == insertionTrackIndex {
                topPixels = rulerLaneHeight + Float(trackIndex) * trackHeight - scrollOffset
                bottomPixels = topPixels + insertedTrackHeight
            } else {
                topPixels = rulerLaneHeight + Float(trackIndex - 1) * trackHeight +
                    insertedTrackHeight - scrollOffset
                bottomPixels = topPixels + trackHeight
            }
        } else {
            topPixels = rulerLaneHeight + Float(trackIndex) * trackHeight - scrollOffset
            bottomPixels = topPixels + trackHeight
        }
        let top = topPixels / viewportHeight
        let bottom = bottomPixels / viewportHeight
        return TimelineTrackLaneFrame(top: top, bottom: bottom)
    }

    func lanePixelFrame(forTrackIndex trackIndex: Int) -> TimelineTrackLanePixelFrame? {
        guard let laneFrame = laneFrame(forTrackIndex: trackIndex) else {
            return nil
        }
        return pixelFrame(for: laneFrame)
    }

    func pixelFrame(for laneFrame: TimelineTrackLaneFrame) -> TimelineTrackLanePixelFrame {
        TimelineTrackLanePixelFrame(
            top: laneFrame.top * viewportHeight,
            bottom: laneFrame.bottom * viewportHeight
        )
    }

    func trackIndex(atYFromTop yFromTop: Float) -> Int? {
        guard totalTrackCount > 0 else {
            return nil
        }

        guard yFromTop >= rulerLaneHeight else {
            return nil
        }

        if insertionTrackIndex != nil || trackPositions != nil {
            let normalizedY = yFromTop / viewportHeight
            for trackIndex in visibleTrackIndices(overscan: 1) {
                guard let laneFrame = laneFrame(forTrackIndex: trackIndex) else {
                    continue
                }
                if normalizedY >= laneFrame.top && normalizedY <= laneFrame.bottom {
                    return trackIndex
                }
            }
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

struct TimelineTrackLanePixelFrame: Sendable, Equatable {
    let top: Float
    let bottom: Float

    var height: Float {
        bottom - top
    }

    func intersectsViewport(height viewportHeight: CGFloat) -> Bool {
        bottom > 0 && top < Float(max(viewportHeight, 0))
    }

    /// Projects the complete top-down lane into AppKit's bottom-up coordinate
    /// space. The frame intentionally extends outside the viewport when a lane
    /// is partially visible; the owning viewport is responsible for clipping.
    func appKitFrame(viewportWidth: CGFloat, viewportHeight: CGFloat) -> CGRect {
        CGRect(
            x: 0,
            y: viewportHeight - CGFloat(bottom),
            width: viewportWidth,
            height: max(CGFloat(height), 0)
        )
    }
}
