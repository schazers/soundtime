import MetalKit

final class TimelineView: MTKView {
    var onAudioFileDropped: ((URL) -> Void)?
    var onTogglePlayback: (() -> Void)?
    var onDeleteSelection: (() -> Void)?
    var onUndo: (() -> Void)?
    var onExportRequested: (() -> Void)?
    var onSeekRequested: ((Float) -> Void)?
    var onSelectionChanged: ((TimelineSelection?) -> Void)?
    var onTrimRequested: ((TimelineTrimRange) -> Void)?

    private enum TimelineDragMode {
        case selection
        case trimStart
        case trimEnd
    }

    private var timelineRenderer: TimelineRenderer?
    private let selectionOverlayLayer = CALayer()
    private var viewport = TimelineViewport.full
    private var isSelectionEnabled = false
    private var displayedSelection: TimelineSelection?
    private var selectionAnchorProgress: Float?
    private var selectionAnchorPoint: CGPoint?
    private var activeDragMode: TimelineDragMode?
    private var hoverTrackingArea: NSTrackingArea?
    private var isDraggingSelection = false
    private var isDraggingTrim = false
    private let selectionDragThreshold: CGFloat = 3
    private let trimHandleHitWidth: CGFloat = 18
    private let scrollZoomSensitivity: Float = 0.01
    private let supportedAudioExtensions: Set<String> = [
        "aif",
        "aiff",
        "flac",
        "m4a",
        "mp3",
        "wav",
        "wave",
    ]

    init() {
        let metalDevice = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: metalDevice)
        configure()
        configureRenderer(with: metalDevice)
    }

    required init(coder: NSCoder) {
        let metalDevice = MTLCreateSystemDefaultDevice()
        super.init(coder: coder)
        device = metalDevice
        configure()
        configureRenderer(with: metalDevice)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        updatePreferredFrameRate()
    }

    func displayWaveform(_ waveformOverview: WaveformOverview?) {
        let wasSelectionEnabled = isSelectionEnabled
        isSelectionEnabled = waveformOverview?.isEmpty == false
        if !wasSelectionEnabled || !isSelectionEnabled {
            setViewport(.full)
        }

        timelineRenderer?.displayWaveform(waveformOverview)
        displayTrimPreview(nil)

        if wasSelectionEnabled != isSelectionEnabled {
            window?.invalidateCursorRects(for: self)
        }

        if !isSelectionEnabled {
            selectionAnchorProgress = nil
            selectionAnchorPoint = nil
            activeDragMode = nil
            isDraggingSelection = false
            isDraggingTrim = false
            displaySelection(nil)
            displayHoverProgress(nil)
            onSelectionChanged?(nil)
        }
    }

    func displayPlayheadProgress(_ progress: Float) {
        let clampedProgress = min(max(progress, 0), 1)
        pageViewportIfNeeded(forPlayheadProgress: clampedProgress)
        timelineRenderer?.displayPlayheadProgress(clampedProgress)
    }

    func displayPlaybackActive(_ isActive: Bool) {
        timelineRenderer?.displayPlaybackActive(isActive)
    }

    func displaySelection(_ selection: TimelineSelection?) {
        timelineRenderer?.displaySelection(nil)
        displayedSelection = selection
        updateSelectionOverlay(flushImmediately: false)
    }

    func displayTrimPreview(_ trimRange: TimelineTrimRange?) {
        timelineRenderer?.displayTrimPreview(trimRange)
    }

    func displayHoverProgress(_ progress: Float?, isArmed: Bool = false) {
        timelineRenderer?.displayHoverProgress(progress, isArmed: isArmed)
    }

    private func configure() {
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        framebufferOnly = true
        preferredFramesPerSecond = 120
        enableSetNeedsDisplay = false
        isPaused = false
        autoResizeDrawable = true

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        configureSelectionOverlay()

        registerForDraggedTypes([.fileURL])
    }

    override func layout() {
        super.layout()
        updateSelectionOverlay(flushImmediately: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updatePreferredFrameRate()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        hoverTrackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    private func configureRenderer(with metalDevice: MTLDevice?) {
        guard let metalDevice else {
            Swift.print("Soundtime could not create a Metal device.")
            return
        }

        do {
            let renderer = try TimelineRenderer(device: metalDevice, pixelFormat: colorPixelFormat)
            timelineRenderer = renderer
            renderer.displayViewport(viewport)
            delegate = renderer
        } catch {
            Swift.print("Soundtime could not create the timeline renderer: \\(error)")
        }
    }

    private func updatePreferredFrameRate() {
        preferredFramesPerSecond = window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 120
    }

    private func configureSelectionOverlay() {
        selectionOverlayLayer.backgroundColor = NSColor(
            calibratedRed: 0.0,
            green: 0.84,
            blue: 0.78,
            alpha: 0.22
        ).cgColor
        selectionOverlayLayer.isHidden = true
        selectionOverlayLayer.actions = [
            "bounds": NSNull(),
            "frame": NSNull(),
            "hidden": NSNull(),
            "position": NSNull(),
        ]
        selectionOverlayLayer.zPosition = 10
        layer?.addSublayer(selectionOverlayLayer)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard firstSupportedAudioURL(from: sender.draggingPasteboard) != nil else {
            return []
        }

        setDropHighlightVisible(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlightVisible(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropHighlightVisible(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlightVisible(false)

        guard let url = firstSupportedAudioURL(from: sender.draggingPasteboard) else {
            return false
        }

        onAudioFileDropped?(url)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 6, event.modifierFlags.contains(.command) {
            onUndo?()
            return
        }

        if event.keyCode == 14, event.modifierFlags.contains(.command) {
            onExportRequested?()
            return
        }

        if event.keyCode == 49 {
            guard !event.isARepeat else {
                return
            }

            onTogglePlayback?()
            return
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            onDeleteSelection?()
            return
        }

        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        guard isSelectionEnabled, bounds.width > 0, bounds.height > 0 else {
            return
        }

        for progress in [Float(0), Float(1)] {
            guard let handleX = trimHandleX(forTimelineProgress: progress) else {
                continue
            }

            addCursorRect(
                NSRect(
                    x: max(handleX - trimHandleHitWidth * 0.5, 0),
                    y: 0,
                    width: min(trimHandleHitWidth, bounds.width),
                    height: bounds.height
                ),
                cursor: .resizeLeftRight
            )
        }
    }

    @objc func exportAudio(_ sender: Any?) {
        onExportRequested?()
    }

    @objc func undoTimelineEdit(_ sender: Any?) {
        onUndo?()
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoverGuide(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverGuide(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        displayHoverProgress(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isSelectionEnabled else {
            super.scrollWheel(with: event)
            return
        }

        let horizontalDelta = event.scrollingDeltaX
        let verticalDelta = event.scrollingDeltaY

        if abs(verticalDelta) >= abs(horizontalDelta), verticalDelta != 0 {
            let anchorProgress = progress(for: convert(event.locationInWindow, from: nil))
            let zoomFactor = exp(Float(verticalDelta) * scrollZoomSensitivity)
            setViewport(viewport.zoomed(by: zoomFactor, around: anchorProgress))
            return
        }

        guard horizontalDelta != 0, bounds.width > 0 else {
            return
        }

        let progressDelta = Float(horizontalDelta / bounds.width) * viewport.durationProgress
        setViewport(viewport.panned(byProgress: progressDelta))
    }

    override func magnify(with event: NSEvent) {
        guard isSelectionEnabled else {
            super.magnify(with: event)
            return
        }

        let anchorProgress = progress(for: convert(event.locationInWindow, from: nil))
        let zoomFactor = max(1 + Float(event.magnification), 0.1)
        setViewport(viewport.zoomed(by: zoomFactor, around: anchorProgress))
    }

    override func smartMagnify(with event: NSEvent) {
        guard isSelectionEnabled else {
            super.smartMagnify(with: event)
            return
        }

        let anchorProgress = progress(for: convert(event.locationInWindow, from: nil))
        if viewport.isFull {
            setViewport(viewport.zoomed(by: 4, around: anchorProgress))
        } else {
            setViewport(.full)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isSelectionEnabled else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        let point = currentDragPoint(for: event)
        let progress = progress(for: point)
        if let trimDragMode = trimDragMode(for: point) {
            displayHoverProgress(nil)
            activeDragMode = trimDragMode
            selectionAnchorProgress = progress
            selectionAnchorPoint = point
            isDraggingSelection = false
            isDraggingTrim = false
            displaySelection(nil)
            onSelectionChanged?(nil)
            return
        }

        activeDragMode = .selection
        selectionAnchorProgress = progress
        selectionAnchorPoint = point
        isDraggingSelection = false
        isDraggingTrim = false
        displayHoverProgress(progress, isArmed: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            isSelectionEnabled,
            let selectionAnchorProgress
        else {
            super.mouseDragged(with: event)
            return
        }

        let point = currentDragPoint(for: event)
        if activeDragMode == .trimStart || activeDragMode == .trimEnd {
            displayHoverProgress(nil)
            if !isDraggingTrim, didMovePastSelectionThreshold(to: point) {
                isDraggingTrim = true
            }

            if isDraggingTrim, let activeDragMode {
                updateTrimPreview(for: activeDragMode, progress: progress(for: point))
            }
            return
        }

        if !isDraggingSelection, didMovePastSelectionThreshold(to: point) {
            isDraggingSelection = true
            displayHoverProgress(nil)
        }

        if isDraggingSelection {
            updateSelection(from: selectionAnchorProgress, to: progress(for: point), notifyChange: false)
        } else {
            displayHoverProgress(progress(for: point), isArmed: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard
            isSelectionEnabled,
            let selectionAnchorProgress
        else {
            super.mouseUp(with: event)
            return
        }

        let progress = progress(for: currentDragPoint(for: event))
        if
            (activeDragMode == .trimStart || activeDragMode == .trimEnd),
            let activeDragMode
        {
            let trimRange = trimRange(for: activeDragMode, progress: progress)
            displayTrimPreview(nil)

            if isDraggingTrim, trimRange.trimsAudio, trimRange.durationProgress > 0.001 {
                onTrimRequested?(trimRange)
            }
        } else if isDraggingSelection {
            updateSelection(from: selectionAnchorProgress, to: progress, notifyChange: true)
        } else {
            displaySelection(nil)
            onSelectionChanged?(nil)
            onSeekRequested?(progress)
        }

        self.selectionAnchorProgress = nil
        selectionAnchorPoint = nil
        activeDragMode = nil
        isDraggingSelection = false
        isDraggingTrim = false
        updateHoverGuide(for: event)
    }

    private func firstSupportedAudioURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]

        guard
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        else {
            return nil
        }

        return urls.first { url in
            supportedAudioExtensions.contains(url.pathExtension.lowercased())
        }
    }

    private func setDropHighlightVisible(_ isVisible: Bool) {
        layer?.borderColor = isVisible ? NSColor.systemTeal.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = isVisible ? 2 : 0
    }

    private func progress(for event: NSEvent) -> Float {
        progress(for: convert(event.locationInWindow, from: nil))
    }

    private func currentDragPoint(for event: NSEvent) -> CGPoint {
        guard let window else {
            return convert(event.locationInWindow, from: nil)
        }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return convert(windowPoint, from: nil)
    }

    private func progress(for point: CGPoint) -> Float {
        guard bounds.width > 0 else {
            return 0
        }

        let viewportProgress = Float(point.x / bounds.width)
        return viewport.timelineProgress(forViewportProgress: viewportProgress)
    }

    private func setViewport(_ nextViewport: TimelineViewport) {
        guard viewport != nextViewport else {
            return
        }

        viewport = nextViewport
        timelineRenderer?.displayViewport(nextViewport)
        updateSelectionOverlay(flushImmediately: false)
        window?.invalidateCursorRects(for: self)
        draw()
    }

    private func pageViewportIfNeeded(forPlayheadProgress progress: Float) {
        guard isSelectionEnabled, !viewport.isFull else {
            return
        }

        let epsilon: Float = 0.00001
        var nextViewport = viewport

        while
            progress >= nextViewport.endProgress - epsilon,
            nextViewport.endProgress < 1 - epsilon
        {
            let nextStartProgress = min(
                nextViewport.startProgress + nextViewport.durationProgress,
                1 - nextViewport.durationProgress
            )

            guard nextStartProgress > nextViewport.startProgress + epsilon else {
                break
            }

            nextViewport = TimelineViewport(
                startProgress: nextStartProgress,
                durationProgress: nextViewport.durationProgress
            )
        }

        while
            progress < nextViewport.startProgress - epsilon,
            nextViewport.startProgress > epsilon
        {
            let nextStartProgress = max(
                nextViewport.startProgress - nextViewport.durationProgress,
                0
            )

            guard nextStartProgress < nextViewport.startProgress - epsilon else {
                break
            }

            nextViewport = TimelineViewport(
                startProgress: nextStartProgress,
                durationProgress: nextViewport.durationProgress
            )
        }

        setViewport(nextViewport)
    }

    private func updateHoverGuide(for event: NSEvent) {
        guard
            isSelectionEnabled,
            activeDragMode == nil
        else {
            displayHoverProgress(nil)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            displayHoverProgress(nil)
            return
        }

        displayHoverProgress(progress(for: point))
    }

    private func updateSelection(from startProgress: Float, to endProgress: Float, notifyChange: Bool) {
        let selection = TimelineSelection(
            startProgress: startProgress,
            endProgress: endProgress
        )
        let visibleSelection = selection.durationProgress > 0.001 ? selection : nil

        displaySelection(visibleSelection, flushImmediately: true)
        if notifyChange {
            onSelectionChanged?(visibleSelection)
        }
    }

    private func displaySelection(_ selection: TimelineSelection?, flushImmediately: Bool) {
        timelineRenderer?.displaySelection(nil)
        displayedSelection = selection
        updateSelectionOverlay(flushImmediately: flushImmediately)
    }

    private func updateSelectionOverlay(flushImmediately: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        defer {
            CATransaction.commit()
            if flushImmediately {
                CATransaction.flush()
            }
        }

        guard
            let displayedSelection,
            displayedSelection.durationProgress > 0.001,
            bounds.width > 0,
            bounds.height > 0
        else {
            selectionOverlayLayer.isHidden = true
            selectionOverlayLayer.frame = .zero
            return
        }

        let leftProgress = viewport.viewportProgress(forTimelineProgress: displayedSelection.startProgress)
        let rightProgress = viewport.viewportProgress(forTimelineProgress: displayedSelection.endProgress)
        guard rightProgress > 0, leftProgress < 1 else {
            selectionOverlayLayer.isHidden = true
            selectionOverlayLayer.frame = .zero
            return
        }

        let left = CGFloat(max(leftProgress, 0)) * bounds.width
        let right = CGFloat(min(rightProgress, 1)) * bounds.width
        selectionOverlayLayer.frame = CGRect(
            x: left,
            y: 0,
            width: max(right - left, 0),
            height: bounds.height
        )
        selectionOverlayLayer.isHidden = false
    }

    private func updateTrimPreview(for dragMode: TimelineDragMode, progress: Float) {
        displayTrimPreview(trimRange(for: dragMode, progress: progress))
    }

    private func trimRange(for dragMode: TimelineDragMode, progress: Float) -> TimelineTrimRange {
        switch dragMode {
        case .trimStart:
            TimelineTrimRange(startProgress: min(max(progress, 0), 0.999), endProgress: 1)
        case .trimEnd:
            TimelineTrimRange(startProgress: 0, endProgress: max(min(progress, 1), 0.001))
        case .selection:
            TimelineTrimRange(startProgress: 0, endProgress: 1)
        }
    }

    private func trimDragMode(for point: CGPoint) -> TimelineDragMode? {
        guard bounds.width > 0 else {
            return nil
        }

        if let startHandleX = trimHandleX(forTimelineProgress: 0),
           abs(point.x - startHandleX) <= trimHandleHitWidth * 0.5
        {
            return .trimStart
        }

        if let endHandleX = trimHandleX(forTimelineProgress: 1),
           abs(point.x - endHandleX) <= trimHandleHitWidth * 0.5
        {
            return .trimEnd
        }

        return nil
    }

    private func trimHandleX(forTimelineProgress progress: Float) -> CGFloat? {
        let viewportProgress = viewport.viewportProgress(forTimelineProgress: progress)
        guard viewportProgress >= 0, viewportProgress <= 1 else {
            return nil
        }

        return CGFloat(viewportProgress) * bounds.width
    }

    private func didMovePastSelectionThreshold(to point: CGPoint) -> Bool {
        guard let selectionAnchorPoint else {
            return false
        }

        return abs(point.x - selectionAnchorPoint.x) >= selectionDragThreshold ||
            abs(point.y - selectionAnchorPoint.y) >= selectionDragThreshold
    }
}
