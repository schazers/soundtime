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
    private var isSelectionEnabled = false
    private var selectionAnchorProgress: Float?
    private var selectionAnchorPoint: CGPoint?
    private var activeDragMode: TimelineDragMode?
    private var hoverTrackingArea: NSTrackingArea?
    private var isDraggingSelection = false
    private var isDraggingTrim = false
    private let selectionDragThreshold: CGFloat = 3
    private let trimHandleHitWidth: CGFloat = 18
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
    }

    func displayWaveform(_ waveformOverview: WaveformOverview?) {
        let wasSelectionEnabled = isSelectionEnabled
        isSelectionEnabled = waveformOverview?.isEmpty == false
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
        timelineRenderer?.displayPlayheadProgress(progress)
    }

    func displaySelection(_ selection: TimelineSelection?) {
        timelineRenderer?.displaySelection(selection)
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
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
        autoResizeDrawable = true

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        registerForDraggedTypes([.fileURL])
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
            delegate = renderer
        } catch {
            Swift.print("Soundtime could not create the timeline renderer: \\(error)")
        }
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

        addCursorRect(
            NSRect(x: 0, y: 0, width: trimHandleHitWidth, height: bounds.height),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            NSRect(
                x: max(bounds.width - trimHandleHitWidth, 0),
                y: 0,
                width: trimHandleHitWidth,
                height: bounds.height
            ),
            cursor: .resizeLeftRight
        )
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

    override func mouseDown(with event: NSEvent) {
        guard isSelectionEnabled else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        let progress = progress(for: event)
        let point = convert(event.locationInWindow, from: nil)
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

        let point = convert(event.locationInWindow, from: nil)
        if activeDragMode == .trimStart || activeDragMode == .trimEnd {
            displayHoverProgress(nil)
            if !isDraggingTrim, didMovePastSelectionThreshold(to: point) {
                isDraggingTrim = true
            }

            if isDraggingTrim, let activeDragMode {
                updateTrimPreview(for: activeDragMode, progress: progress(for: event))
            }
            return
        }

        if !isDraggingSelection, didMovePastSelectionThreshold(to: point) {
            isDraggingSelection = true
            displayHoverProgress(nil)
        }

        if isDraggingSelection {
            updateSelection(from: selectionAnchorProgress, to: progress(for: event))
        } else {
            displayHoverProgress(progress(for: event), isArmed: true)
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

        let progress = progress(for: event)
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
            updateSelection(from: selectionAnchorProgress, to: progress)
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

    private func progress(for point: CGPoint) -> Float {
        guard bounds.width > 0 else {
            return 0
        }

        return min(max(Float(point.x / bounds.width), 0), 1)
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

    private func updateSelection(from startProgress: Float, to endProgress: Float) {
        let selection = TimelineSelection(
            startProgress: startProgress,
            endProgress: endProgress
        )
        let visibleSelection = selection.durationProgress > 0.001 ? selection : nil

        displaySelection(visibleSelection)
        onSelectionChanged?(visibleSelection)
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

        if point.x <= trimHandleHitWidth {
            return .trimStart
        }

        if point.x >= bounds.width - trimHandleHitWidth {
            return .trimEnd
        }

        return nil
    }

    private func didMovePastSelectionThreshold(to point: CGPoint) -> Bool {
        guard let selectionAnchorPoint else {
            return false
        }

        return abs(point.x - selectionAnchorPoint.x) >= selectionDragThreshold ||
            abs(point.y - selectionAnchorPoint.y) >= selectionDragThreshold
    }
}
