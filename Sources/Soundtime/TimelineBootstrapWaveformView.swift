import AppKit

/// Startup-only renderer used while Metal creates its cold pipeline state off the main thread.
/// It is never used after the first Metal frame and is not part of the interactive render path.
final class TimelineBootstrapWaveformView: NSView {
    private var tracks: [TimelineRenderState.Track] = []
    private var viewport = TimelineViewport.full
    private var trackLayout = TimelineTrackLayout.default

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func display(
        tracks: [TimelineRenderState.Track],
        viewport: TimelineViewport,
        trackLayout: TimelineTrackLayout
    ) {
        self.tracks = tracks
        self.viewport = viewport
        self.trackLayout = trackLayout
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !tracks.isEmpty, bounds.width > 0, bounds.height > 0 else {
            return
        }

        let resolvedLayout = trackLayout.resolved(
            totalTrackCount: tracks.count,
            viewportHeight: Float(max(bounds.height, 1))
        )
        let projectDuration = tracks.compactMap(\.durationHint).max() ?? 0
        let hasSoloedTrack = tracks.contains(where: \.isSoloed)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let columnWidth = max(1 / max(scale, 1), 0.5)

        NSGraphicsContext.current?.shouldAntialias = false
        for trackIndex in resolvedLayout.visibleRange(overscan: 0) {
            guard
                let lane = resolvedLayout.laneFrame(forTrackIndex: trackIndex),
                lane.isVisible
            else {
                continue
            }

            let track = tracks[trackIndex]
            let topFromTop = CGFloat(lane.clampedTop) * bounds.height
            let bottomFromTop = CGFloat(lane.clampedBottom) * bounds.height
            let laneRect = CGRect(
                x: 0,
                y: bounds.height - bottomFromTop,
                width: bounds.width,
                height: max(bottomFromTop - topFromTop, 1)
            )
            drawWaveform(
                track,
                in: laneRect,
                projectDuration: projectDuration,
                hasSoloedTrack: hasSoloedTrack,
                columnWidth: columnWidth
            )

            NSColor.white.withAlphaComponent(0.09).setFill()
            CGRect(x: laneRect.minX, y: laneRect.minY, width: laneRect.width, height: columnWidth).fill()
        }
    }

    private func drawWaveform(
        _ track: TimelineRenderState.Track,
        in laneRect: CGRect,
        projectDuration: TimeInterval,
        hasSoloedTrack: Bool,
        columnWidth: CGFloat
    ) {
        guard let overview = track.waveformOverview, !overview.bins.isEmpty else {
            return
        }

        let trackDuration = max(track.durationHint ?? overview.duration, 0)
        let trackEndProgress = projectDuration > 0 ?
            min(max(trackDuration / projectDuration, 0), 1) :
            1
        guard trackEndProgress > 0 else {
            return
        }

        let isAudible = !track.isMuted && (!hasSoloedTrack || track.isSoloed)
        let alpha: CGFloat = isAudible ? 0.54 : 0.18
        NSColor.white.withAlphaComponent(alpha).setFill()

        let centerY = laneRect.midY
        let amplitudeScale = max(laneRect.height * 0.44, 1)
        let pixelColumns = max(Int(ceil(laneRect.width)), 1)
        for column in 0..<pixelColumns {
            let viewportProgress = (Float(column) + 0.5) / Float(pixelColumns)
            let timelineProgress = viewport.timelineProgress(forViewportProgress: viewportProgress)
            guard timelineProgress <= Float(trackEndProgress) else {
                continue
            }

            guard let sourceProgress = sourceProgress(
                for: timelineProgress,
                track: track,
                trackEndProgress: Float(trackEndProgress)
            ) else {
                continue
            }
            let binIndex = min(
                max(Int(sourceProgress * Float(overview.bins.count)), 0),
                overview.bins.count - 1
            )
            let bin = overview.bins[binIndex]
            let top = centerY + CGFloat(max(bin.maximumSample, 0)) * amplitudeScale
            let bottom = centerY + CGFloat(min(bin.minimumSample, 0)) * amplitudeScale
            CGRect(
                x: laneRect.minX + CGFloat(column),
                y: bottom,
                width: columnWidth,
                height: max(top - bottom, columnWidth)
            ).fill()
        }
    }

    private func sourceProgress(
        for timelineProgress: Float,
        track: TimelineRenderState.Track,
        trackEndProgress: Float
    ) -> Float? {
        if !track.waveformSegments.isEmpty {
            guard let segment = track.waveformSegments.first(where: {
                timelineProgress >= $0.outputStartProgress &&
                    timelineProgress <= $0.outputEndProgress
            }) else {
                return nil
            }
            let outputDuration = max(segment.outputEndProgress - segment.outputStartProgress, 0.000_001)
            let fraction = (timelineProgress - segment.outputStartProgress) / outputDuration
            return min(max(
                segment.sourceStartProgress +
                    fraction * (segment.sourceEndProgress - segment.sourceStartProgress),
                0
            ), 1)
        }

        return min(max(timelineProgress / max(trackEndProgress, 0.000_001), 0), 1)
    }
}
