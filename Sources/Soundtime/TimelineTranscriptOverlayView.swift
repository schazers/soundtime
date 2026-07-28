import AppKit

struct TimelineTranscriptOverlayDiagnosticsSnapshot: Codable, Sendable {
    var configureCount: Int
    var layoutBuildCount: Int
    var interactionOnlyUpdateCount: Int
    var fullDirtyUpdateCount: Int
    var fineDirtyUpdateCount: Int
    var visibleRunCount: Int
}

final class TimelineTranscriptOverlayView: NSView {
    private struct VisibleTextRun {
        let layoutRun: TranscriptTimelineLayout.Run
        let displayRect: CGRect?

        init(layoutRun: TranscriptTimelineLayout.Run, displayRect: CGRect? = nil) {
            self.layoutRun = layoutRun
            self.displayRect = displayRect
        }

        var rect: CGRect {
            displayRect ?? layoutRun.rect
        }

        var text: String {
            layoutRun.text
        }

        var isWord: Bool {
            layoutRun.isWord
        }

        var interactionHit: TranscriptInteractionHit {
            TranscriptInteractionHit(
                trackID: layoutRun.trackID,
                wordID: layoutRun.wordID,
                segmentID: layoutRun.segmentID,
                sourceRange: layoutRun.sourceRange,
                projectRange: layoutRun.projectRange,
                rect: rect,
                text: layoutRun.text,
                isWord: layoutRun.isWord,
                confidence: layoutRun.confidence,
                speakerID: layoutRun.speakerID
            )
        }
    }

    private struct CachedLayout {
        let key: String
        let reuseKey: String
        let visibleProjectRange: TranscriptionTimeRange
        let backgroundRects: [CGRect]
        let runs: [VisibleTextRun]
        let wordRects: [UUID: CGRect]
        let segmentRects: [UUID: CGRect]
    }

    private var tracks: [TimelineRenderState.Track] = []
    private var viewport = TimelineViewport.full
    private var trackLayout = TimelineTrackLayout.default
    private var timelineDuration: TimeInterval = 0
    private var displayMode = TranscriptTimelineDisplayMode.hidden
    private var interactionState = TranscriptInteractionState.empty
    private var cachedLayout: CachedLayout?
    private var diagnosticsConfigureCount = 0
    private var diagnosticsLayoutBuildCount = 0
    private var diagnosticsInteractionOnlyUpdateCount = 0
    private var diagnosticsFullDirtyUpdateCount = 0
    private var diagnosticsFineDirtyUpdateCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    @discardableResult
    func configure(
        tracks: [TimelineRenderState.Track],
        viewport: TimelineViewport,
        trackLayout: TimelineTrackLayout,
        timelineDuration: TimeInterval,
        displayMode: TranscriptTimelineDisplayMode,
        interactionState: TranscriptInteractionState = .empty
    ) -> Bool {
        diagnosticsConfigureCount += 1
        let previousKey = cachedLayout?.key
        let previousInteractionState = self.interactionState
        self.tracks = tracks
        self.viewport = viewport
        self.trackLayout = trackLayout
        self.timelineDuration = timelineDuration
        self.displayMode = displayMode
        self.interactionState = interactionState
        let isVisible = displayMode != .hidden
        isHidden = !isVisible

        let nextKey = cacheKey(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            timelineDuration: timelineDuration,
            displayMode: displayMode
        )
        guard isVisible else {
            if cachedLayout != nil || previousKey != nextKey {
                cachedLayout = nil
                needsDisplay = true
                return true
            }
            return false
        }

        guard previousKey != nextKey else {
            if previousInteractionState != interactionState {
                diagnosticsInteractionOnlyUpdateCount += 1
                markInteractionChangeDirty(from: previousInteractionState, to: interactionState)
            }
            return false
        }

        cachedLayout = buildLayout(key: nextKey)
        diagnosticsLayoutBuildCount += 1
        needsDisplay = true
        return true
    }

    func updateInteractionState(_ interactionState: TranscriptInteractionState) {
        guard self.interactionState != interactionState else {
            return
        }

        let previousState = self.interactionState
        self.interactionState = interactionState
        diagnosticsInteractionOnlyUpdateCount += 1
        markInteractionChangeDirty(from: previousState, to: interactionState)
    }

    @discardableResult
    func updateLiveGeometry(
        viewport: TimelineViewport,
        trackLayout: TimelineTrackLayout,
        timelineDuration: TimeInterval,
        displayMode: TranscriptTimelineDisplayMode
    ) -> Bool {
        self.viewport = viewport
        self.trackLayout = trackLayout
        self.timelineDuration = timelineDuration
        self.displayMode = displayMode
        isHidden = displayMode == .hidden

        guard displayMode != .hidden, cachedLayout != nil else {
            return false
        }

        needsDisplay = true
        return true
    }

    func requiresLayoutRebuild(
        tracks: [TimelineRenderState.Track],
        viewport: TimelineViewport,
        trackLayout: TimelineTrackLayout,
        timelineDuration: TimeInterval,
        displayMode: TranscriptTimelineDisplayMode
    ) -> Bool {
        let isVisible = displayMode != .hidden
        guard isVisible else {
            return cachedLayout != nil
        }
        return cachedLayout?.key != cacheKey(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            timelineDuration: timelineDuration,
            displayMode: displayMode
        )
    }

    func canReuseLayoutForLiveGeometry(
        tracks: [TimelineRenderState.Track],
        viewport: TimelineViewport,
        trackLayout: TimelineTrackLayout,
        timelineDuration: TimeInterval,
        displayMode: TranscriptTimelineDisplayMode
    ) -> Bool {
        guard
            displayMode != .hidden,
            let cachedLayout
        else {
            return false
        }

        let nextReuseKey = layoutReuseKey(
            tracks: tracks,
            trackLayout: trackLayout,
            timelineDuration: timelineDuration,
            displayMode: displayMode
        )
        guard cachedLayout.reuseKey == nextReuseKey else {
            return false
        }

        let nextVisibleRange = TranscriptViewportGeometry.visibleProjectRange(
            viewport: viewport,
            timelineDuration: timelineDuration
        )
        return TranscriptViewportGeometry.range(nextVisibleRange, isCoveredBy: cachedLayout.visibleProjectRange)
    }

    func diagnosticsSnapshotForSmokeTesting() -> TimelineTranscriptOverlayDiagnosticsSnapshot {
        TimelineTranscriptOverlayDiagnosticsSnapshot(
            configureCount: diagnosticsConfigureCount,
            layoutBuildCount: diagnosticsLayoutBuildCount,
            interactionOnlyUpdateCount: diagnosticsInteractionOnlyUpdateCount,
            fullDirtyUpdateCount: diagnosticsFullDirtyUpdateCount,
            fineDirtyUpdateCount: diagnosticsFineDirtyUpdateCount,
            visibleRunCount: cachedLayout?.runs.count ?? 0
        )
    }

    func resetDiagnosticsForSmokeTesting() {
        diagnosticsConfigureCount = 0
        diagnosticsLayoutBuildCount = 0
        diagnosticsInteractionOnlyUpdateCount = 0
        diagnosticsFullDirtyUpdateCount = 0
        diagnosticsFineDirtyUpdateCount = 0
    }

    func transcriptHit(at point: CGPoint) -> TranscriptInteractionHit? {
        guard
            displayMode != .hidden,
            let cachedLayout
        else {
            return nil
        }

        var best: (run: VisibleTextRun, distance: CGFloat)?
        for cachedRun in cachedLayout.runs {
            let run = displayRun(cachedRun)
            let hitRect = run.rect.insetBy(dx: -4, dy: -5)
            guard hitRect.contains(point) else {
                continue
            }
            let distance = abs(point.x - run.rect.midX) + abs(point.y - run.rect.midY)
            if best == nil || distance < best!.distance {
                best = (run, distance)
            }
        }
        return best?.run.interactionHit
    }

    func nearestTranscriptHit(
        at point: CGPoint,
        trackID: UUID,
        maximumHorizontalDistance: CGFloat = 42
    ) -> TranscriptInteractionHit? {
        guard
            displayMode != .hidden,
            let cachedLayout
        else {
            return nil
        }

        var best: (run: VisibleTextRun, distance: CGFloat)?
        for cachedRun in cachedLayout.runs where cachedRun.layoutRun.trackID == trackID {
            let run = displayRun(cachedRun)
            let verticalHitRect = run.rect.insetBy(dx: 0, dy: -9)
            guard point.y >= verticalHitRect.minY, point.y <= verticalHitRect.maxY else {
                continue
            }

            let horizontalDistance: CGFloat
            if point.x < run.rect.minX {
                horizontalDistance = run.rect.minX - point.x
            } else if point.x > run.rect.maxX {
                horizontalDistance = point.x - run.rect.maxX
            } else {
                horizontalDistance = 0
            }
            guard horizontalDistance <= maximumHorizontalDistance else {
                continue
            }
            if best == nil || horizontalDistance < best!.distance {
                best = (run, horizontalDistance)
            }
        }
        return best?.run.interactionHit
    }

    func visibleRunsSnapshot() -> [TranscriptInteractionHit] {
        guard let cachedLayout else {
            return []
        }
        return cachedLayout.runs.map { displayRun($0).interactionHit }
    }

    func transcriptCursorRects() -> [CGRect] {
        guard displayMode != .hidden, let cachedLayout else {
            return []
        }
        return cachedLayout.runs.map { displayRun($0).rect.insetBy(dx: -4, dy: -5) }
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        isHidden = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard
            displayMode != .hidden,
            timelineDuration > 0,
            bounds.width > 1,
            bounds.height > 1
        else {
            return
        }

        guard let cachedLayout else {
            return
        }

        NSGraphicsContext.current?.shouldAntialias = true
        for backgroundRect in cachedLayout.backgroundRects where backgroundRect.intersects(dirtyRect) {
            drawTranscriptBackground(backgroundRect)
        }
        let visibleRuns = cachedLayout.runs.map(displayRun)
        if interactionState.alignmentDebugEnabled {
            drawAlignmentDebug(for: visibleRuns, dirtyRect: dirtyRect)
        }
        for run in visibleRuns where run.rect.intersects(dirtyRect) {
            draw(run)
        }
    }

    private func buildLayout(key: String) -> CachedLayout {
        guard
            displayMode != .hidden,
            timelineDuration > 0,
            bounds.width > 1,
            bounds.height > 1
        else {
            return CachedLayout(
                key: key,
                reuseKey: layoutReuseKey(
                    tracks: tracks,
                    trackLayout: trackLayout,
                    timelineDuration: timelineDuration,
                    displayMode: displayMode
                ),
                visibleProjectRange: TranscriptViewportGeometry.layoutCacheProjectRange(
                    viewport: viewport,
                    timelineDuration: timelineDuration
                ),
                backgroundRects: [],
                runs: [],
                wordRects: [:],
                segmentRects: [:]
            )
        }

        let layoutViewport = TranscriptViewportGeometry.layoutCacheViewport(
            viewport: viewport,
            timelineDuration: timelineDuration
        )
        let layout = TranscriptLayoutEngine.makeLayout(TranscriptTimelineLayoutInput(
            tracks: tracks,
            viewport: layoutViewport,
            trackLayout: trackLayout,
            timelineDuration: timelineDuration,
            bounds: bounds.size,
            displayMode: displayMode
        ))
        let runs = layout.runs.map { VisibleTextRun(layoutRun: $0) }
        return CachedLayout(
            key: key,
            reuseKey: layoutReuseKey(
                tracks: tracks,
                trackLayout: trackLayout,
                timelineDuration: timelineDuration,
                displayMode: displayMode
            ),
            visibleProjectRange: TranscriptViewportGeometry.layoutCacheProjectRange(
                viewport: viewport,
                timelineDuration: timelineDuration
            ),
            backgroundRects: layout.backgrounds.map(\.rect),
            runs: runs,
            wordRects: rectsByWordID(runs),
            segmentRects: rectsBySegmentID(runs)
        )
    }

    private func markInteractionChangeDirty(
        from previousState: TranscriptInteractionState,
        to nextState: TranscriptInteractionState
    ) {
        guard let cachedLayout else {
            diagnosticsFullDirtyUpdateCount += 1
            needsDisplay = true
            return
        }

        guard previousState.alignmentDebugEnabled == nextState.alignmentDebugEnabled else {
            diagnosticsFullDirtyUpdateCount += 1
            needsDisplay = true
            return
        }

        var dirtyRects: [CGRect] = []
        let wordRects = currentWordRects(for: cachedLayout.runs)
        let segmentRects = currentSegmentRects(for: cachedLayout.runs)

        appendDirtyRect(for: previousState.hoveredWordID, in: wordRects, to: &dirtyRects)
        appendDirtyRect(for: nextState.hoveredWordID, in: wordRects, to: &dirtyRects)
        appendDirtyRect(for: previousState.activeWordID, in: wordRects, to: &dirtyRects)
        appendDirtyRect(for: nextState.activeWordID, in: wordRects, to: &dirtyRects)
        appendDirtyRect(for: previousState.hoveredSegmentID, in: segmentRects, to: &dirtyRects)
        appendDirtyRect(for: nextState.hoveredSegmentID, in: segmentRects, to: &dirtyRects)

        let changedWordIDs = previousState.selectedWordIDs.symmetricDifference(nextState.selectedWordIDs)
        let changedSegmentIDs = previousState.selectedSegmentIDs.symmetricDifference(nextState.selectedSegmentIDs)
        for wordID in changedWordIDs {
            appendDirtyRect(for: wordID, in: wordRects, to: &dirtyRects)
        }
        for segmentID in changedSegmentIDs {
            appendDirtyRect(for: segmentID, in: segmentRects, to: &dirtyRects)
        }

        guard !dirtyRects.isEmpty else {
            return
        }
        if dirtyRects.count > 40 {
            diagnosticsFullDirtyUpdateCount += 1
            needsDisplay = true
            return
        }
        for rect in dirtyRects {
            diagnosticsFineDirtyUpdateCount += 1
            setNeedsDisplay(expandedDirtyRect(rect))
        }
    }

    private func appendDirtyRect(
        for id: UUID?,
        in rects: [UUID: CGRect],
        to output: inout [CGRect]
    ) {
        guard let id, let rect = rects[id] else {
            return
        }
        output.append(rect)
    }

    private func expandedDirtyRect(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -10, dy: -8).intersection(bounds)
    }

    private func rectsByWordID(_ runs: [VisibleTextRun]) -> [UUID: CGRect] {
        var rects: [UUID: CGRect] = [:]
        for run in runs {
            guard let wordID = run.layoutRun.wordID else {
                continue
            }
            rects[wordID] = union(rects[wordID], run.rect)
        }
        return rects
    }

    private func rectsBySegmentID(_ runs: [VisibleTextRun]) -> [UUID: CGRect] {
        var rects: [UUID: CGRect] = [:]
        for run in runs {
            rects[run.layoutRun.segmentID] = union(rects[run.layoutRun.segmentID], run.rect)
        }
        return rects
    }

    private func currentWordRects(for runs: [VisibleTextRun]) -> [UUID: CGRect] {
        rectsByWordID(runs.map(displayRun))
    }

    private func currentSegmentRects(for runs: [VisibleTextRun]) -> [UUID: CGRect] {
        rectsBySegmentID(runs.map(displayRun))
    }

    private func displayRun(_ run: VisibleTextRun) -> VisibleTextRun {
        VisibleTextRun(
            layoutRun: run.layoutRun,
            displayRect: TranscriptViewportGeometry.displayRect(
                for: run.layoutRun,
                viewport: viewport,
                timelineDuration: timelineDuration,
                boundsWidth: bounds.width
            )
        )
    }

    private func union(_ existing: CGRect?, _ next: CGRect) -> CGRect {
        guard let existing else {
            return next
        }
        return existing.union(next)
    }

    private func drawTranscriptBackground(_ textBand: CGRect) {
        let path = NSBezierPath(roundedRect: textBand, xRadius: 9, yRadius: 9)
        NSColor.black.withAlphaComponent(0.28).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.055).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func draw(_ run: VisibleTextRun) {
        let clippedRect = run.rect.intersection(bounds).insetBy(dx: 3, dy: 0)
        guard clippedRect.width > 2, clippedRect.height > 2 else {
            return
        }

        let isSelected = run.layoutRun.wordID.map { interactionState.selectedWordIDs.contains($0) } == true ||
            interactionState.selectedSegmentIDs.contains(run.layoutRun.segmentID)
        let isHovered = run.layoutRun.wordID.map { interactionState.hoveredWordID == $0 } == true ||
            (run.layoutRun.wordID == nil && interactionState.hoveredSegmentID == run.layoutRun.segmentID)
        let isActive = run.layoutRun.wordID.map { interactionState.activeWordID == $0 } == true

        if run.isWord {
            let path = NSBezierPath(roundedRect: clippedRect, xRadius: clippedRect.height * 0.46, yRadius: clippedRect.height * 0.46)
            let fillAlpha: CGFloat
            if isSelected {
                fillAlpha = 0.34
            } else if isActive {
                fillAlpha = 0.28
            } else if isHovered {
                fillAlpha = 0.22
            } else {
                fillAlpha = 0.14
            }
            NSColor(calibratedRed: 0.14, green: 0.86, blue: 0.94, alpha: fillAlpha).setFill()
            path.fill()
            if isSelected || isHovered || isActive {
                NSColor.white.withAlphaComponent(isSelected ? 0.28 : 0.16).setStroke()
                path.lineWidth = isSelected ? 1.2 : 0.8
                path.stroke()
            }
        } else if isSelected || isHovered {
            let path = NSBezierPath(roundedRect: clippedRect, xRadius: 8, yRadius: 8)
            NSColor(calibratedRed: 0.14, green: 0.86, blue: 0.94, alpha: isSelected ? 0.24 : 0.13).setFill()
            path.fill()
        }

        attributedText(for: run, isSelected: isSelected, isHovered: isHovered, isActive: isActive)
            .draw(in: clippedRect.insetBy(dx: 5, dy: max((clippedRect.height - 14) * 0.5, 1)))
    }

    private func attributedText(
        for run: VisibleTextRun,
        isSelected: Bool,
        isHovered: Bool,
        isActive: Bool
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        paragraphStyle.alignment = .center
        let alpha: CGFloat
        if isSelected || isActive {
            alpha = 0.98
        } else if isHovered {
            alpha = 0.94
        } else {
            alpha = run.isWord ? 0.86 : 0.76
        }
        return NSAttributedString(
            string: run.text,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: run.isWord ? 11 : 12,
                    weight: isActive || isSelected ? .bold : (run.isWord ? .semibold : .medium)
                ),
                .foregroundColor: NSColor.white.withAlphaComponent(alpha),
                .paragraphStyle: paragraphStyle,
            ]
        )
    }

    private func drawAlignmentDebug(for runs: [VisibleTextRun], dirtyRect: NSRect) {
        guard !runs.isEmpty else {
            return
        }

        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.setLineWidth(1)
        for run in runs {
            let confidence = CGFloat(run.layoutRun.confidence ?? 0.75)
            let alpha = min(max(0.12 + confidence * 0.28, 0.12), 0.42)
            let startX = run.rect.minX
            let endX = run.rect.maxX
            let top = run.rect.minY - 8
            let bottom = run.rect.maxY + 8
            let startLine = CGRect(x: startX - 0.5, y: top, width: 1, height: max(bottom - top, 1))
            let endLine = CGRect(x: endX - 0.5, y: top, width: 1, height: max(bottom - top, 1))
            guard startLine.intersects(dirtyRect) || endLine.intersects(dirtyRect) else {
                continue
            }

            NSColor.systemYellow.withAlphaComponent(alpha).setStroke()
            let path = NSBezierPath()
            path.move(to: CGPoint(x: startX, y: top))
            path.line(to: CGPoint(x: startX, y: bottom))
            path.move(to: CGPoint(x: endX, y: top))
            path.line(to: CGPoint(x: endX, y: bottom))
            path.stroke()
        }
        context?.restoreGState()
    }

    private func cacheKey(
        tracks: [TimelineRenderState.Track],
        viewport: TimelineViewport,
        trackLayout: TimelineTrackLayout,
        timelineDuration: TimeInterval,
        displayMode: TranscriptTimelineDisplayMode
    ) -> String {
        var components = [
            displayMode.rawValue,
            "\(Int((bounds.width * 2).rounded()))",
            "\(Int((bounds.height * 2).rounded()))",
            "\(Int((viewport.startProgress * 1_000_000).rounded()))",
            "\(Int((viewport.durationProgress * 1_000_000).rounded()))",
            "\(Int((timelineDuration * 1_000).rounded()))",
            "\(Int((trackLayout.scrollOffset * 10).rounded()))",
            "\(Int((trackLayout.preferredTrackHeight * 10).rounded()))",
            "\(Int((trackLayout.rulerLaneHeight * 10).rounded()))",
            "\(trackLayout.insertionTrackIndex ?? -1)",
            "\(Int((trackLayout.insertionProgress * 1_000).rounded()))",
        ]
        components.append(
            layoutReuseKey(
                tracks: tracks,
                trackLayout: trackLayout,
                timelineDuration: timelineDuration,
                displayMode: displayMode
            )
        )
        return components.joined(separator: "|")
    }

    private func layoutReuseKey(
        tracks: [TimelineRenderState.Track],
        trackLayout: TimelineTrackLayout,
        timelineDuration: TimeInterval,
        displayMode: TranscriptTimelineDisplayMode
    ) -> String {
        var components = [
            displayMode.rawValue,
            "\(Int((bounds.width * 2).rounded()))",
            "\(Int((bounds.height * 2).rounded()))",
            "\(Int((timelineDuration * 1_000).rounded()))",
            "\(Int((trackLayout.scrollOffset * 10).rounded()))",
            "\(Int((trackLayout.preferredTrackHeight * 10).rounded()))",
            "\(Int((trackLayout.rulerLaneHeight * 10).rounded()))",
            "\(trackLayout.insertionTrackIndex ?? -1)",
            "\(Int((trackLayout.insertionProgress * 1_000).rounded()))",
        ]
        components.reserveCapacity(components.count + tracks.count * 4)
        for track in tracks {
            components.append(track.id.uuidString)
            components.append(track.transcript?.id.uuidString ?? "-")
            components.append("\(track.transcript?.segments.count ?? 0)")
            components.append("\(Int(((track.durationHint ?? 0) * 1_000).rounded()))")
            components.append("\(track.waveformSegments.count)")
            var segmentFingerprint = 0
            for segment in track.waveformSegments {
                segmentFingerprint = segmentFingerprint &* 31 &+ Int((segment.outputStartProgress * 1_000_000).rounded())
                segmentFingerprint = segmentFingerprint &* 31 &+ Int((segment.outputEndProgress * 1_000_000).rounded())
                segmentFingerprint = segmentFingerprint &* 31 &+ Int((segment.sourceStartProgress * 1_000_000).rounded())
                segmentFingerprint = segmentFingerprint &* 31 &+ Int((segment.sourceEndProgress * 1_000_000).rounded())
            }
            components.append("\(segmentFingerprint)")
            if let firstSegment = track.waveformSegments.first {
                components.append("\(Int((firstSegment.outputStartProgress * 1_000_000).rounded()))")
                components.append("\(Int((firstSegment.sourceStartProgress * 1_000_000).rounded()))")
            }
            if let lastSegment = track.waveformSegments.last {
                components.append("\(Int((lastSegment.outputEndProgress * 1_000_000).rounded()))")
                components.append("\(Int((lastSegment.sourceEndProgress * 1_000_000).rounded()))")
            }
        }
        return components.joined(separator: "|")
    }
}
