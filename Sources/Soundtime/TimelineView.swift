import AppKit
import Metal

final class TimelineView: TimelineMetalLayerView, NSMenuItemValidation {
    var onAudioFileDropped: ((URL) -> Void)?
    var onTogglePlayback: (() -> Void)?
    var onDeleteSelection: (() -> Void)?
    var onUndo: (() -> Void)?
    var onExportRequested: (() -> Void)?
    var onGainRequested: (() -> Void)?
    var onFadeInRequested: (() -> Void)?
    var onFadeOutRequested: (() -> Void)?
    var onReapplyLastEffect: (() -> Void)?
    var onSeekRequested: ((Float) -> Void)?
    var onPlayFromProgress: ((Float) -> Void)?
    var onSelectionChanged: ((TimelineSelection?) -> Void)?
    var onTrimRequested: ((TimelineTrimRange) -> Void)?
    var onFrameStatsChanged: ((TimelineFrameStats) -> Void)?
    var canApplyGainEffect = false
    var canApplyFadeEffect = false
    var canReapplyLastEffect = false

    private enum TimelineDragMode {
        case selection
        case trimStart
        case trimEnd
    }

    private var timelineRenderer: TimelineRenderer?
    private let timelineRenderQueue = DispatchQueue(
        label: "Soundtime.timeline.renderer",
        qos: .userInteractive
    )
    private var viewport = TimelineViewport.full
    private var isSelectionEnabled = false
    private var selectionAnchorProgress: Float?
    private var selectionAnchorPoint: CGPoint?
    private var activeDragMode: TimelineDragMode?
    private var hoverTrackingArea: NSTrackingArea?
    private var isDraggingSelection = false
    private var isDraggingTrim = false
    private var rightPanPreviousPoint: CGPoint?
    private var rightPanPreviousTime: TimeInterval?
    private var rightPanLastMovementTime: TimeInterval?
    private var rightPanVelocityProgressPerSecond: Float = 0
    private var rightPanMomentumTimer: Timer?
    private var rightPanMomentumLastTime: TimeInterval?
    private var timelineDisplayLink: TimelineDisplayLink?
    private var transientRenderEndTime: CFTimeInterval?
    private var needsTimelineRender = false
    private var isTimelineRenderInFlight = false
    private var isTimelinePlaybackActive = false
    private let selectionDragThreshold: CGFloat = 3
    private let trimHandleHitWidth: CGFloat = 18
    private let rightPanVelocitySmoothing: Float = 0.42
    private let rightPanMomentumDecayRate: Double = 5.2
    private let rightPanMomentumMinimumVelocity: Float = 0.0015
    private let rightPanStationaryDecayRate: Double = 18
    private let rightPanMomentumReleaseWindow: TimeInterval = 0.12
    private let rightPanMovementThreshold: CGFloat = 0.25
    private let transientRenderPulseDuration: CFTimeInterval = 0.18
    private let waveformTransitionRenderPulseDuration: CFTimeInterval = 0.24
    private let targetFramesPerSecond = 144
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

    required init?(coder: NSCoder) {
        super.init(coder: coder)
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
        configureDisplayLinkIfNeeded()
        updatePreferredFrameRate()
        requestTimelineRender()
    }

    func displayWaveform(_ waveformOverview: WaveformOverview?) {
        let wasSelectionEnabled = isSelectionEnabled
        isSelectionEnabled = waveformOverview?.isEmpty == false
        if !wasSelectionEnabled || !isSelectionEnabled {
            setViewport(.full)
        }

        updateTimelineRenderer { renderer in
            renderer.displayWaveform(waveformOverview)
        }
        displayTrimPreview(nil)

        if wasSelectionEnabled != isSelectionEnabled {
            window?.invalidateCursorRects(for: self)
        }

        startTransientRenderPulse(duration: waveformTransitionRenderPulseDuration)

        if !isSelectionEnabled {
            selectionAnchorProgress = nil
            selectionAnchorPoint = nil
            activeDragMode = nil
            isDraggingSelection = false
            isDraggingTrim = false
            rightPanPreviousPoint = nil
            rightPanPreviousTime = nil
            rightPanLastMovementTime = nil
            stopRightPanMomentum()
            displaySelection(nil)
            displayHoverProgress(nil)
            onSelectionChanged?(nil)
        }
    }

    func updateWaveformTouchTuning(
        trailDuration: TimeInterval,
        trailFalloffSteepness: Float,
        waveformGray: Float
    ) {
        updateTimelineRenderer { renderer in
            renderer.updateWaveformTouchTuning(
                trailDuration: trailDuration,
                trailFalloffSteepness: trailFalloffSteepness,
                waveformGray: waveformGray
            )
        }
        requestTimelineRender()
    }

    func displayPlayheadProgress(
        _ progress: Float,
        syncRenderer: Bool = true,
        anchorTimestamp: CFTimeInterval? = nil
    ) {
        let clampedProgress = min(max(progress, 0), 1)
        pageViewportIfNeeded(forPlayheadProgress: clampedProgress)
        updateTimelineRenderer { renderer in
            renderer.displayPlayheadProgress(
                clampedProgress,
                force: syncRenderer,
                anchorTimestamp: anchorTimestamp
            )
        }
        requestTimelineRender()
    }

    func displayPlaybackActive(_ isActive: Bool) {
        isTimelinePlaybackActive = isActive
        updateTimelineRenderer { renderer in
            renderer.displayPlaybackActive(isActive)
        }
        requestTimelineRender()
        if !isActive {
            startTransientRenderPulse()
        }
    }

    func displaySelection(_ selection: TimelineSelection?) {
        updateTimelineRenderer { renderer in
            renderer.displaySelection(selection)
        }
        requestTimelineRender()
    }

    func displayTrimPreview(_ trimRange: TimelineTrimRange?) {
        updateTimelineRenderer { renderer in
            renderer.displayTrimPreview(trimRange)
        }
        requestTimelineRender()
    }

    func displayHoverProgress(_ progress: Float?, isArmed: Bool = false) {
        updateTimelineRenderer { renderer in
            renderer.displayHoverProgress(progress, isArmed: isArmed)
        }
        requestTimelineRender()
    }

    func displayGainPreview(selection: TimelineSelection?, gain: Float) {
        updateTimelineRenderer { renderer in
            renderer.displayGainPreview(selection: selection, gain: gain)
        }
        requestTimelineRender()
    }

    private func configure() {
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        framebufferOnly = true
        preferredFramesPerSecond = targetFramesPerSecond

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        registerForDraggedTypes([.fileURL])
    }

    override func layout() {
        super.layout()
        requestTimelineRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updatePreferredFrameRate()
        requestTimelineRender()
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
            renderer.onFrameStatsChanged = { [weak self] frameStats in
                Task { @MainActor [weak self] in
                    self?.onFrameStatsChanged?(frameStats)
                }
            }
            let initialViewport = viewport
            updateTimelineRenderer { renderer in
                renderer.displayViewport(initialViewport)
            }
            requestTimelineRender()
        } catch {
            Swift.print("Soundtime could not create the timeline renderer: \\(error)")
        }
    }

    private func updateTimelineRenderer(_ update: @escaping @Sendable (TimelineRenderer) -> Void) {
        guard let timelineRenderer else {
            return
        }

        timelineRenderQueue.async { [timelineRenderer] in
            update(timelineRenderer)
        }
    }

    private func updatePreferredFrameRate() {
        preferredFramesPerSecond = targetFramesPerSecond
        timelineDisplayLink?.updatePreferredFramesPerSecond(targetFramesPerSecond)
    }

    private func requestTimelineRender() {
        needsTimelineRender = true
        startTimelineDisplayLink()
    }

    private func configureDisplayLinkIfNeeded() {
        guard timelineDisplayLink == nil, let timelineMetalLayer else {
            return
        }

        let displayLink = TimelineDisplayLink(
            metalLayer: timelineMetalLayer,
            preferredFramesPerSecond: targetFramesPerSecond
        )
        displayLink.onFrame = { [weak self] frame in
            MainActor.assumeIsolated {
                self?.displayLinkDidTick(frame)
            }
        }
        timelineDisplayLink = displayLink
    }

    private func startTimelineDisplayLink() {
        configureDisplayLinkIfNeeded()
        timelineDisplayLink?.start()
    }

    private func stopTimelineDisplayLinkIfIdle() {
        guard !needsTimelineRender, !isTimelinePlaybackActive, !hasActiveTransientRenderPulse() else {
            return
        }

        timelineDisplayLink?.stop()
    }

    private func displayLinkDidTick(_ frame: TimelineDisplayLinkFrame) {
        let shouldRender = needsTimelineRender ||
            isTimelinePlaybackActive ||
            hasActiveTransientRenderPulse()

        guard shouldRender else {
            timelineDisplayLink?.stop()
            return
        }

        if
            isTimelinePlaybackActive,
            let playheadProgress = timelineRenderer?.projectedPlayheadProgress(
                at: frame.targetPresentationTimestamp
            )
        {
            pageViewportIfNeeded(forPlayheadProgress: playheadProgress)
        }

        let didSubmitRender = submitTimelineRender(frame: frame)
        if didSubmitRender {
            needsTimelineRender = false
        }
        stopTimelineDisplayLinkIfIdle()
    }

    private func submitTimelineRender(frame: TimelineDisplayLinkFrame) -> Bool {
        guard !isTimelineRenderInFlight else {
            return false
        }

        guard
            let timelineRenderer,
            let renderTarget = makeTimelineRenderTarget(frame: frame)
        else {
            return false
        }

        isTimelineRenderInFlight = true
        timelineRenderQueue.async { [weak self, timelineRenderer, renderTarget] in
            timelineRenderer.render(to: renderTarget)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.isTimelineRenderInFlight = false
                }
            }
        }
        return true
    }

    private func startTransientRenderPulse(duration: CFTimeInterval? = nil) {
        transientRenderEndTime = CFAbsoluteTimeGetCurrent() + (duration ?? transientRenderPulseDuration)
        startTimelineDisplayLink()
    }

    private func hasActiveTransientRenderPulse() -> Bool {
        guard let transientRenderEndTime else {
            return false
        }

        if CFAbsoluteTimeGetCurrent() <= transientRenderEndTime {
            return true
        }

        self.transientRenderEndTime = nil
        return false
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

        if event.keyCode == 15, event.modifierFlags.contains(.command) {
            onReapplyLastEffect?()
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

    @objc func showGainEffect(_ sender: Any?) {
        onGainRequested?()
    }

    @objc func applyFadeInEffect(_ sender: Any?) {
        onFadeInRequested?()
    }

    @objc func applyFadeOutEffect(_ sender: Any?) {
        onFadeOutRequested?()
    }

    @objc func reapplyLastEffect(_ sender: Any?) {
        onReapplyLastEffect?()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showGainEffect(_:)):
            return canApplyGainEffect
        case #selector(applyFadeInEffect(_:)), #selector(applyFadeOutEffect(_:)):
            return canApplyFadeEffect
        case #selector(reapplyLastEffect(_:)):
            return canReapplyLastEffect
        default:
            return true
        }
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

        stopRightPanMomentum()

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

        stopRightPanMomentum()

        let anchorProgress = progress(for: convert(event.locationInWindow, from: nil))
        let zoomFactor = max(1 + Float(event.magnification), 0.1)
        setViewport(viewport.zoomed(by: zoomFactor, around: anchorProgress))
    }

    override func smartMagnify(with event: NSEvent) {
        guard isSelectionEnabled else {
            super.smartMagnify(with: event)
            return
        }

        stopRightPanMomentum()

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
        stopRightPanMomentum()
        let point = currentDragPoint(for: event)
        let progress = progress(for: point)
        if event.clickCount >= 2 {
            displayHoverProgress(nil)
            displaySelection(nil)
            onSelectionChanged?(nil)
            selectionAnchorProgress = nil
            selectionAnchorPoint = nil
            activeDragMode = nil
            isDraggingSelection = false
            isDraggingTrim = false
            onPlayFromProgress?(progress)
            return
        }

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

    override func rightMouseDown(with event: NSEvent) {
        guard isSelectionEnabled else {
            super.rightMouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        stopRightPanMomentum()
        rightPanPreviousPoint = currentDragPoint(for: event)
        rightPanPreviousTime = event.timestamp
        rightPanLastMovementTime = nil
        rightPanVelocityProgressPerSecond = 0
        selectionAnchorProgress = nil
        selectionAnchorPoint = nil
        activeDragMode = nil
        isDraggingSelection = false
        isDraggingTrim = false
        displayHoverProgress(nil)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard
            isSelectionEnabled,
            let previousPoint = rightPanPreviousPoint,
            bounds.width > 0
        else {
            super.rightMouseDragged(with: event)
            return
        }

        let point = currentDragPoint(for: event)
        let horizontalDelta = previousPoint.x - point.x
        let progressDelta = Float(horizontalDelta / bounds.width) * viewport.durationProgress
        let elapsedTime: TimeInterval
        if let previousTime = rightPanPreviousTime {
            elapsedTime = max(event.timestamp - previousTime, 1 / 240)
        } else {
            elapsedTime = 1 / 120
        }

        if abs(horizontalDelta) >= rightPanMovementThreshold {
            setViewport(viewport.panned(byProgress: progressDelta))
            let instantVelocity = progressDelta / Float(elapsedTime)
            rightPanVelocityProgressPerSecond =
                rightPanVelocityProgressPerSecond * (1 - rightPanVelocitySmoothing) +
                instantVelocity * rightPanVelocitySmoothing
            rightPanLastMovementTime = event.timestamp
        } else {
            let decay = Float(exp(-rightPanStationaryDecayRate * elapsedTime))
            rightPanVelocityProgressPerSecond *= decay
        }

        rightPanPreviousPoint = point
        rightPanPreviousTime = event.timestamp
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isSelectionEnabled else {
            super.rightMouseUp(with: event)
            return
        }

        if let lastMovementTime = rightPanLastMovementTime {
            let idleTime = max(event.timestamp - lastMovementTime, 0)
            if idleTime > rightPanMomentumReleaseWindow {
                rightPanVelocityProgressPerSecond = 0
            } else {
                let decay = Float(exp(-rightPanStationaryDecayRate * idleTime))
                rightPanVelocityProgressPerSecond *= decay
            }
        } else {
            rightPanVelocityProgressPerSecond = 0
        }

        rightPanPreviousPoint = nil
        rightPanPreviousTime = nil
        rightPanLastMovementTime = nil
        startRightPanMomentumIfNeeded()
        updateHoverGuide(for: event)
    }

    private func startRightPanMomentumIfNeeded() {
        stopRightPanMomentum(clearVelocity: false)

        guard
            isSelectionEnabled,
            !viewport.isFull,
            abs(rightPanVelocityProgressPerSecond) >= rightPanMomentumMinimumVelocity
        else {
            rightPanVelocityProgressPerSecond = 0
            return
        }

        rightPanMomentumLastTime = CFAbsoluteTimeGetCurrent()
        let frameRate = window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 120
        let timer = Timer(timeInterval: 1 / Double(max(frameRate, 60)), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepRightPanMomentum()
            }
        }

        rightPanMomentumTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stepRightPanMomentum() {
        guard
            isSelectionEnabled,
            !viewport.isFull,
            bounds.width > 0,
            abs(rightPanVelocityProgressPerSecond) >= rightPanMomentumMinimumVelocity
        else {
            stopRightPanMomentum()
            return
        }

        let currentTime = CFAbsoluteTimeGetCurrent()
        let elapsedTime = min(max(currentTime - (rightPanMomentumLastTime ?? currentTime), 1 / 240), 1 / 20)
        rightPanMomentumLastTime = currentTime

        let progressDelta = rightPanVelocityProgressPerSecond * Float(elapsedTime)
        let nextViewport = viewport.panned(byProgress: progressDelta)
        guard nextViewport != viewport else {
            stopRightPanMomentum()
            return
        }

        setViewport(nextViewport)
        let decay = Float(exp(-rightPanMomentumDecayRate * elapsedTime))
        rightPanVelocityProgressPerSecond *= decay
    }

    private func stopRightPanMomentum(clearVelocity: Bool = true) {
        rightPanMomentumTimer?.invalidate()
        rightPanMomentumTimer = nil
        rightPanMomentumLastTime = nil

        if clearVelocity {
            rightPanVelocityProgressPerSecond = 0
            rightPanLastMovementTime = nil
        }
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
        updateTimelineRenderer { renderer in
            renderer.displayViewport(nextViewport)
        }
        window?.invalidateCursorRects(for: self)
        requestTimelineRender()
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
                max(progress, nextViewport.startProgress + nextViewport.durationProgress),
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

        displaySelection(visibleSelection)
        if notifyChange {
            onSelectionChanged?(visibleSelection)
        }
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
