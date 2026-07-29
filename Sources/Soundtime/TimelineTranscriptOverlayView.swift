import AppKit

struct TimelineTranscriptOverlayDiagnosticsSnapshot: Codable, Sendable {
    var configureCount: Int
    var layoutBuildCount: Int
    var interactionOnlyUpdateCount: Int
    var fullDirtyUpdateCount: Int
    var fineDirtyUpdateCount: Int
    var drawCount: Int
    var maxDrawMilliseconds: Double
    var maxDrawnRunCount: Int
    var cursorRectResetCount: Int
    var maxCursorRectResetMilliseconds: Double
    var maxCursorRectCount: Int
    var visibleRunCount: Int
    var runLayerCount: Int
    var expectedVisibleRunLayerCount: Int
    var visibleRunLayerCount: Int
    var lastLayoutBuildReason: String?
}

final class TimelineTranscriptOverlayView: NSView {
    private final class RunLayerBundle {
        let layoutRun: TranscriptTimelineLayout.Run
        let containerLayer = CALayer()
        let backgroundLayer = CALayer()
        let textLayer = CATextLayer()

        init(layoutRun: TranscriptTimelineLayout.Run) {
            self.layoutRun = layoutRun
        }
    }

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
        let reuseKeyComponents: [String]
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
    private let transcriptBackgroundLayer = CALayer()
    private let transcriptRunLayer = CALayer()
    private var transcriptBandLayers: [CALayer] = []
    private var transcriptRunLayers: [RunLayerBundle] = []
    private var diagnosticsConfigureCount = 0
    private var diagnosticsLayoutBuildCount = 0
    private var diagnosticsInteractionOnlyUpdateCount = 0
    private var diagnosticsFullDirtyUpdateCount = 0
    private var diagnosticsFineDirtyUpdateCount = 0
    private var diagnosticsDrawCount = 0
    private var diagnosticsMaxDrawMilliseconds: Double = 0
    private var diagnosticsMaxDrawnRunCount = 0
    private var diagnosticsCursorRectResetCount = 0
    private var diagnosticsMaxCursorRectResetMilliseconds: Double = 0
    private var diagnosticsMaxCursorRectCount = 0
    private var diagnosticsLastLayoutBuildReason: String?

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
                rebuildLayerTree()
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

        let nextReuseKeyComponents = layoutReuseKeyComponents(
            tracks: tracks,
            trackLayout: trackLayout,
            timelineDuration: timelineDuration,
            displayMode: displayMode
        )
        if let cachedLayout {
            diagnosticsLastLayoutBuildReason = cachedLayout.reuseKeyComponents == nextReuseKeyComponents
                ? "viewport-uncovered"
                : layoutReuseDifferenceReason(
                    previous: cachedLayout.reuseKeyComponents,
                    next: nextReuseKeyComponents
                )
        } else {
            diagnosticsLastLayoutBuildReason = "cache-missing"
        }
        cachedLayout = buildLayout(key: nextKey)
        rebuildLayerTree()
        diagnosticsLayoutBuildCount += 1
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

        updateLayerGeometry()
        if interactionState.alignmentDebugEnabled {
            needsDisplay = true
        }
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

        let nextReuseKeyComponents = layoutReuseKeyComponents(
            tracks: tracks,
            trackLayout: trackLayout,
            timelineDuration: timelineDuration,
            displayMode: displayMode
        )
        guard cachedLayout.reuseKeyComponents == nextReuseKeyComponents else {
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
            drawCount: diagnosticsDrawCount,
            maxDrawMilliseconds: diagnosticsMaxDrawMilliseconds,
            maxDrawnRunCount: diagnosticsMaxDrawnRunCount,
            cursorRectResetCount: diagnosticsCursorRectResetCount,
            maxCursorRectResetMilliseconds: diagnosticsMaxCursorRectResetMilliseconds,
            maxCursorRectCount: diagnosticsMaxCursorRectCount,
            visibleRunCount: cachedLayout?.runs.count ?? 0,
            runLayerCount: transcriptRunLayers.count,
            expectedVisibleRunLayerCount: expectedVisibleRunLayerCountForDiagnostics(),
            visibleRunLayerCount: transcriptRunLayers.lazy.filter { !$0.containerLayer.isHidden }.count,
            lastLayoutBuildReason: diagnosticsLastLayoutBuildReason
        )
    }

    func resetDiagnosticsForSmokeTesting() {
        diagnosticsConfigureCount = 0
        diagnosticsLayoutBuildCount = 0
        diagnosticsInteractionOnlyUpdateCount = 0
        diagnosticsFullDirtyUpdateCount = 0
        diagnosticsFineDirtyUpdateCount = 0
        diagnosticsDrawCount = 0
        diagnosticsMaxDrawMilliseconds = 0
        diagnosticsMaxDrawnRunCount = 0
        diagnosticsCursorRectResetCount = 0
        diagnosticsMaxCursorRectResetMilliseconds = 0
        diagnosticsMaxCursorRectCount = 0
        diagnosticsLastLayoutBuildReason = nil
    }

    func recordCursorRectResetForDiagnostics(
        durationMilliseconds: Double,
        rectCount: Int
    ) {
        diagnosticsCursorRectResetCount += 1
        diagnosticsMaxCursorRectResetMilliseconds = max(
            diagnosticsMaxCursorRectResetMilliseconds,
            durationMilliseconds
        )
        diagnosticsMaxCursorRectCount = max(diagnosticsMaxCursorRectCount, rectCount)
    }

    private func expectedVisibleRunLayerCountForDiagnostics() -> Int {
        guard let cachedLayout else {
            return 0
        }
        return cachedLayout.runs.lazy.filter { run in
            let rect = self.displayRun(run).rect.intersection(self.bounds).insetBy(dx: 3, dy: 0)
            return !rect.isNull && rect.width > 2 && rect.height > 2
        }.count
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
        guard let layer else {
            return
        }
        layer.backgroundColor = NSColor.clear.cgColor
        layer.masksToBounds = true
        layer.isGeometryFlipped = true
        transcriptBackgroundLayer.masksToBounds = true
        transcriptRunLayer.masksToBounds = true
        transcriptBackgroundLayer.isGeometryFlipped = true
        transcriptRunLayer.isGeometryFlipped = true
        layer.addSublayer(transcriptBackgroundLayer)
        layer.addSublayer(transcriptRunLayer)
        isHidden = true
    }

    private func rebuildLayerTree() {
        withDisabledLayerActions {
            for layer in transcriptBandLayers {
                layer.removeFromSuperlayer()
            }
            for bundle in transcriptRunLayers {
                bundle.containerLayer.removeFromSuperlayer()
            }
            transcriptBandLayers.removeAll(keepingCapacity: true)
            transcriptRunLayers.removeAll(keepingCapacity: true)

            guard displayMode != .hidden, let cachedLayout else {
                return
            }

            transcriptBandLayers.reserveCapacity(cachedLayout.backgroundRects.count)
            for _ in cachedLayout.backgroundRects {
                let bandLayer = CALayer()
                bandLayer.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
                bandLayer.borderColor = NSColor.white.withAlphaComponent(0.055).cgColor
                bandLayer.borderWidth = 1
                bandLayer.cornerRadius = 9
                transcriptBackgroundLayer.addSublayer(bandLayer)
                transcriptBandLayers.append(bandLayer)
            }

            let contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            transcriptRunLayers.reserveCapacity(cachedLayout.runs.count)
            for run in cachedLayout.runs {
                let bundle = RunLayerBundle(layoutRun: run.layoutRun)
                bundle.containerLayer.masksToBounds = true
                bundle.containerLayer.isGeometryFlipped = true
                bundle.backgroundLayer.isGeometryFlipped = true
                bundle.textLayer.isGeometryFlipped = true
                bundle.textLayer.contentsScale = contentsScale
                bundle.textLayer.alignmentMode = .center
                bundle.textLayer.truncationMode = .end
                bundle.textLayer.isWrapped = false
                bundle.textLayer.masksToBounds = true
                bundle.containerLayer.addSublayer(bundle.backgroundLayer)
                bundle.containerLayer.addSublayer(bundle.textLayer)
                transcriptRunLayer.addSublayer(bundle.containerLayer)
                transcriptRunLayers.append(bundle)
            }

            updateLayerGeometryWithoutTransaction()
            updateAllRunLayerStylesWithoutTransaction()
        }
    }

    private func updateLayerGeometry() {
        withDisabledLayerActions {
            updateLayerGeometryWithoutTransaction()
        }
    }

    private func updateLayerGeometryWithoutTransaction() {
        transcriptBackgroundLayer.frame = bounds
        transcriptRunLayer.frame = bounds

        if let cachedLayout {
            for (index, bandLayer) in transcriptBandLayers.enumerated() {
                guard cachedLayout.backgroundRects.indices.contains(index) else {
                    bandLayer.isHidden = true
                    continue
                }
                let rect = cachedLayout.backgroundRects[index].intersection(bounds)
                bandLayer.isHidden = rect.isNull || rect.width <= 0 || rect.height <= 0
                if !bandLayer.isHidden {
                    bandLayer.frame = rect
                }
            }
        } else {
            for bandLayer in transcriptBandLayers {
                bandLayer.isHidden = true
            }
        }

        for bundle in transcriptRunLayers {
            let displayRect = TranscriptViewportGeometry.displayRect(
                for: bundle.layoutRun,
                viewport: viewport,
                timelineDuration: timelineDuration,
                boundsWidth: bounds.width
            )
            let clippedRect = displayRect.intersection(bounds).insetBy(dx: 3, dy: 0)
            guard
                !clippedRect.isNull,
                clippedRect.width > 2,
                clippedRect.height > 2
            else {
                bundle.containerLayer.isHidden = true
                continue
            }

            bundle.containerLayer.isHidden = false
            bundle.containerLayer.frame = clippedRect
            let localBounds = CGRect(origin: .zero, size: clippedRect.size)
            bundle.backgroundLayer.frame = localBounds
            bundle.backgroundLayer.cornerRadius = bundle.layoutRun.isWord
                ? clippedRect.height * 0.46
                : 8
            let verticalTextInset = max((clippedRect.height - 14) * 0.5, 1)
            bundle.textLayer.frame = localBounds.insetBy(dx: 5, dy: verticalTextInset)
        }
    }

    private func updateAllRunLayerStyles() {
        withDisabledLayerActions {
            updateAllRunLayerStylesWithoutTransaction()
        }
    }

    private func updateAllRunLayerStylesWithoutTransaction() {
        for bundle in transcriptRunLayers {
            updateRunLayerStyle(bundle)
        }
    }

    private func updateRunLayerStyles(
        wordIDs: Set<UUID>,
        segmentIDs: Set<UUID>
    ) {
        guard !wordIDs.isEmpty || !segmentIDs.isEmpty else {
            return
        }
        withDisabledLayerActions {
            for bundle in transcriptRunLayers {
                let layoutRun = bundle.layoutRun
                let shouldUpdate = layoutRun.wordID.map(wordIDs.contains) == true ||
                    segmentIDs.contains(layoutRun.segmentID)
                if shouldUpdate {
                    updateRunLayerStyle(bundle)
                }
            }
        }
    }

    private func updateRunLayerStyle(_ bundle: RunLayerBundle) {
        let run = bundle.layoutRun
        let isSelected = run.wordID.map { interactionState.selectedWordIDs.contains($0) } == true ||
            interactionState.selectedSegmentIDs.contains(run.segmentID)
        let isHovered = run.wordID.map { interactionState.hoveredWordID == $0 } == true ||
            (run.wordID == nil && interactionState.hoveredSegmentID == run.segmentID)
        let isActive = run.wordID.map { interactionState.activeWordID == $0 } == true

        if run.isWord {
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
            bundle.backgroundLayer.backgroundColor = NSColor(
                calibratedRed: 0.14,
                green: 0.86,
                blue: 0.94,
                alpha: fillAlpha
            ).cgColor
            if isSelected || isHovered || isActive {
                bundle.backgroundLayer.borderColor = NSColor.white
                    .withAlphaComponent(isSelected ? 0.28 : 0.16)
                    .cgColor
                bundle.backgroundLayer.borderWidth = isSelected ? 1.2 : 0.8
            } else {
                bundle.backgroundLayer.borderColor = NSColor.clear.cgColor
                bundle.backgroundLayer.borderWidth = 0
            }
        } else if isSelected || isHovered {
            bundle.backgroundLayer.backgroundColor = NSColor(
                calibratedRed: 0.14,
                green: 0.86,
                blue: 0.94,
                alpha: isSelected ? 0.24 : 0.13
            ).cgColor
            bundle.backgroundLayer.borderColor = NSColor.clear.cgColor
            bundle.backgroundLayer.borderWidth = 0
        } else {
            bundle.backgroundLayer.backgroundColor = NSColor.clear.cgColor
            bundle.backgroundLayer.borderColor = NSColor.clear.cgColor
            bundle.backgroundLayer.borderWidth = 0
        }

        bundle.textLayer.string = attributedText(
            for: VisibleTextRun(layoutRun: run),
            isSelected: isSelected,
            isHovered: isHovered,
            isActive: isActive
        )
    }

    private func withDisabledLayerActions(_ update: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        update()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updateLayerGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for bundle in transcriptRunLayers {
            bundle.textLayer.contentsScale = scale
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let startedAt = CACurrentMediaTime()
        var drawnRunCount = 0
        defer {
            diagnosticsDrawCount += 1
            diagnosticsMaxDrawMilliseconds = max(
                diagnosticsMaxDrawMilliseconds,
                (CACurrentMediaTime() - startedAt) * 1_000
            )
            diagnosticsMaxDrawnRunCount = max(diagnosticsMaxDrawnRunCount, drawnRunCount)
        }

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

        guard interactionState.alignmentDebugEnabled else {
            return
        }

        NSGraphicsContext.current?.shouldAntialias = true
        let visibleRuns = cachedLayout.runs.map(displayRun)
        drawnRunCount = visibleRuns.count
        drawAlignmentDebug(for: visibleRuns, dirtyRect: dirtyRect)
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
                reuseKeyComponents: layoutReuseKeyComponents(
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
            densityViewport: viewport,
            trackLayout: trackLayout,
            timelineDuration: timelineDuration,
            bounds: bounds.size,
            displayMode: displayMode
        ))
        let runs = layout.runs.map { VisibleTextRun(layoutRun: $0) }
        return CachedLayout(
            key: key,
            reuseKeyComponents: layoutReuseKeyComponents(
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
            updateAllRunLayerStyles()
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
        updateRunLayerStyles(
            wordIDs: Set(
                [
                    previousState.hoveredWordID,
                    nextState.hoveredWordID,
                    previousState.activeWordID,
                    nextState.activeWordID,
                ].compactMap { $0 }
            ).union(changedWordIDs),
            segmentIDs: Set(
                [
                    previousState.hoveredSegmentID,
                    nextState.hoveredSegmentID,
                ].compactMap { $0 }
            ).union(changedSegmentIDs)
        )
        if dirtyRects.count > 40 {
            diagnosticsFullDirtyUpdateCount += 1
            return
        }
        diagnosticsFineDirtyUpdateCount += dirtyRects.count
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
        components.append(contentsOf: layoutReuseKeyComponents(
            tracks: tracks,
            trackLayout: trackLayout,
            timelineDuration: timelineDuration,
            displayMode: displayMode
        ))
        return components.joined(separator: "|")
    }

    private func layoutReuseDifferenceReason(
        previous: [String],
        next: [String]
    ) -> String {
        let labels = [
            "display-mode",
            "bounds-width",
            "bounds-height",
            "timeline-duration",
            "track-scroll-offset",
            "track-height",
            "ruler-height",
            "insertion-track",
            "insertion-progress",
        ]
        let sharedCount = min(previous.count, next.count)
        if let differenceIndex = (0..<sharedCount).first(where: { previous[$0] != next[$0] }) {
            if labels.indices.contains(differenceIndex) {
                return "layout-\(labels[differenceIndex])-changed-\(previous[differenceIndex])-to-\(next[differenceIndex])"
            }
            return "track-content-changed"
        }
        return previous.count == next.count ? "content-or-layout-changed" : "track-count-changed"
    }

    private func layoutReuseKeyComponents(
        tracks: [TimelineRenderState.Track],
        trackLayout: TimelineTrackLayout,
        timelineDuration: TimeInterval,
        displayMode: TranscriptTimelineDisplayMode
    ) -> [String] {
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
        components.reserveCapacity(components.count + tracks.count * 10)
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
        return components
    }
}
