import MetalKit

final class TimelineView: MTKView {
    var onAudioFileDropped: ((URL) -> Void)?
    var onTogglePlayback: (() -> Void)?
    var onDeleteSelection: (() -> Void)?
    var onUndo: (() -> Void)?
    var onExportRequested: (() -> Void)?
    var onSeekRequested: ((Float) -> Void)?
    var onSelectionChanged: ((TimelineSelection?) -> Void)?

    private var timelineRenderer: TimelineRenderer?
    private var isSelectionEnabled = false
    private var selectionAnchorProgress: Float?
    private var selectionAnchorPoint: CGPoint?
    private var isDraggingSelection = false
    private let selectionDragThreshold: CGFloat = 3
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    func displayWaveform(_ waveformOverview: WaveformOverview?) {
        isSelectionEnabled = waveformOverview?.isEmpty == false
        timelineRenderer?.displayWaveform(waveformOverview)

        if !isSelectionEnabled {
            selectionAnchorProgress = nil
            selectionAnchorPoint = nil
            isDraggingSelection = false
            displaySelection(nil)
            onSelectionChanged?(nil)
        }
    }

    func displayPlayheadProgress(_ progress: Float) {
        timelineRenderer?.displayPlayheadProgress(progress)
    }

    func displaySelection(_ selection: TimelineSelection?) {
        timelineRenderer?.displaySelection(selection)
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

    @objc func exportAudio(_ sender: Any?) {
        onExportRequested?()
    }

    @objc func undoTimelineEdit(_ sender: Any?) {
        onUndo?()
    }

    override func mouseDown(with event: NSEvent) {
        guard isSelectionEnabled else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        let progress = progress(for: event)
        selectionAnchorProgress = progress
        selectionAnchorPoint = convert(event.locationInWindow, from: nil)
        isDraggingSelection = false
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
        if !isDraggingSelection, didMovePastSelectionThreshold(to: point) {
            isDraggingSelection = true
        }

        if isDraggingSelection {
            updateSelection(from: selectionAnchorProgress, to: progress(for: event))
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
        if isDraggingSelection {
            updateSelection(from: selectionAnchorProgress, to: progress)
        } else {
            displaySelection(nil)
            onSelectionChanged?(nil)
            onSeekRequested?(progress)
        }

        self.selectionAnchorProgress = nil
        selectionAnchorPoint = nil
        isDraggingSelection = false
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
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0 else {
            return 0
        }

        return min(max(Float(point.x / bounds.width), 0), 1)
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

    private func didMovePastSelectionThreshold(to point: CGPoint) -> Bool {
        guard let selectionAnchorPoint else {
            return false
        }

        return abs(point.x - selectionAnchorPoint.x) >= selectionDragThreshold ||
            abs(point.y - selectionAnchorPoint.y) >= selectionDragThreshold
    }
}
