import AppKit
import Metal

final class TimelineView: TimelineMetalLayerView, NSMenuItemValidation {
    private final class RenderFlightGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isInFlight = false

        func begin() -> Bool {
            lock.lock()
            defer {
                lock.unlock()
            }

            guard !isInFlight else {
                return false
            }

            isInFlight = true
            return true
        }

        func finish() {
            lock.lock()
            isInFlight = false
            lock.unlock()
        }
    }

    var onAudioFileDropped: ((URL) -> Void)?
    var onTogglePlayback: (() -> Void)?
    var onDeleteSelection: (() -> Void)?
    var onCutSelection: (() -> Void)?
    var onCopySelection: (() -> Void)?
    var onPasteAudio: (() -> Void)?
    var onSplitAtPlayhead: (() -> Void)?
    var onUndo: (() -> Void)?
    var onExportRequested: (() -> Void)?
    var onOpenProjectRequested: (() -> Void)?
    var onOpenRecentProjectRequested: ((URL) -> Void)?
    var onClearRecentProjectsRequested: (() -> Void)?
    var onSaveProjectRequested: (() -> Void)?
    var onSaveProjectAsRequested: (() -> Void)?
    var onToggleDebugTools: (() -> Void)?
    var onGainRequested: (() -> Void)?
    var onFadeInRequested: (() -> Void)?
    var onFadeOutRequested: (() -> Void)?
    var onNormalizeRequested: (() -> Void)?
    var onDeleteSilenceRequested: (() -> Void)?
    var onReapplyLastEffect: (() -> Void)?
    var onSeekRequested: ((Float) -> Void)?
    var onPlayFromProgress: ((Float) -> Void)?
    var onSelectionChanged: ((TimelineSelection?) -> Void)?
    var onTrimRequested: ((TimelineTrimRange) -> Void)?
    var onFrameStatsChanged: ((TimelineFrameStats) -> Void)?
    var onTimelineInteractionBegan: (() -> Void)?
    var onTrackLaneLayoutChanged: ((ResolvedTimelineTrackLayout) -> Void)?
    var canApplyGainEffect = false
    var canApplyFadeEffect = false
    var canReapplyLastEffect = false
    var canSplitAtPlayhead = false
    var canDeleteSilence = false
    var isDebugToolsVisible = false

    private enum TimelineDragMode {
        case selection
        case trimStart
        case trimEnd
    }

    private enum ScrollGestureMode {
        case pan
        case zoom
    }

    private var timelineRenderer: TimelineRenderer?
    private var currentTrackIDs: [UUID] = []
    private let timelineRenderQueue = DispatchQueue(
        label: "Soundtime.timeline.renderer",
        qos: .userInteractive
    )
    private var viewport = TimelineViewport.full
    private var pendingRestoredViewport: TimelineViewport?
    private var trackLayout = TimelineTrackLayout.default
    private var lastPublishedTrackLayout: ResolvedTimelineTrackLayout?
    private var isSelectionEnabled = false
    private var selectionAnchorProgress: Double?
    private var selectionAnchorPoint: CGPoint?
    private var selectionAnchorTrackID: UUID?
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
    private var zoomMomentumAnchorProgress: Float?
    private var zoomPreviousTime: TimeInterval?
    private var zoomLastInputTime: TimeInterval?
    private var zoomVelocityLogScalePerSecond: Float = 0
    private var zoomMomentumTimer: Timer?
    private var zoomMomentumLastTime: TimeInterval?
    private var scrollGestureMode: ScrollGestureMode?
    private var timelineDisplayLink: TimelineDisplayLink?
    private var transientRenderEndTime: CFTimeInterval?
    private var needsTimelineRender = false
    private var isRenderDataPreparedRenderPending = false
    private let renderFlightGate = RenderFlightGate()
    private var isTimelinePlaybackActive = false
    private var timelineDuration: TimeInterval = 0
    private var pagingPlayheadProgress: Float = 0
    private var pagingPlayheadAnchorTimestamp = CACurrentMediaTime()
    private var latestSubmittedPresentationTimestamp = CACurrentMediaTime()
    private let selectionDragThreshold: CGFloat = 0.01
    private let trimHandleHitWidth: CGFloat = 18
    private let rightPanVelocitySmoothing: Float = 0.42
    private let rightPanMomentumDecayRate: Double = 5.2
    private let rightPanMomentumMinimumVelocity: Float = 0.0015
    private let rightPanStationaryDecayRate: Double = 18
    private let rightPanMomentumReleaseWindow: TimeInterval = 0.12
    private let rightPanMovementThreshold: CGFloat = 0.25
    private let zoomVelocitySmoothing: Float = 0.38
    private let zoomMomentumDecayRate: Double = 8.4
    private let zoomMomentumMinimumVelocity: Float = 0.02
    private let zoomMomentumMaximumVelocity: Float = 4.5
    private let zoomMomentumMaximumStepLogScale: Float = 0.08
    private let transientRenderPulseDuration: CFTimeInterval = 0.18
    private let playbackStopTouchTrailRenderPulseDuration: CFTimeInterval = 1.25
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            tearDownTimelineAnimation()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            tearDownTimelineAnimation()
            return
        }

        window.makeFirstResponder(self)
        window.acceptsMouseMovedEvents = true
        configureDisplayLinkIfNeeded()
        updatePreferredFrameRate()
        requestTimelineRender()
    }

    func displayWaveform(_ waveformOverview: WaveformOverview?) {
        let trackID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
        currentTrackIDs = waveformOverview.map { _ in [trackID] } ?? []
        timelineDuration = waveformOverview?.duration ?? 0
        let wasSelectionEnabled = isSelectionEnabled
        isSelectionEnabled = waveformOverview?.isEmpty == false
        if !wasSelectionEnabled || !isSelectionEnabled {
            setViewport(.full)
        }
        updateTrackLayoutForCurrentBounds(requestRender: false)

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
            selectionAnchorTrackID = nil
            activeDragMode = nil
            isDraggingSelection = false
            isDraggingTrim = false
            rightPanPreviousPoint = nil
            rightPanPreviousTime = nil
            rightPanLastMovementTime = nil
            stopRightPanMomentum()
            stopZoomMomentum()
            displaySelection(nil)
            displayHoverProgress(nil)
            onSelectionChanged?(nil)
        }
    }

    func displayTracks(_ tracks: [TimelineRenderState.Track], animateWaveformTransition: Bool = true) {
        let previousTimelineDuration = timelineDuration
        let previousViewport = viewport
        currentTrackIDs = tracks.map(\.id)
        let nextTimelineDuration = Self.timelineDuration(for: tracks)
        timelineDuration = nextTimelineDuration
        let wasSelectionEnabled = isSelectionEnabled
        isSelectionEnabled = tracks.contains { $0.hasWaveform }
        if !wasSelectionEnabled || !isSelectionEnabled {
            setViewport(.full)
        } else if
            !animateWaveformTransition,
            previousTimelineDuration > 0,
            nextTimelineDuration > 0,
            previousTimelineDuration != nextTimelineDuration
        {
            let absoluteStart = Double(previousViewport.startProgress) * previousTimelineDuration
            let absoluteDuration = Double(previousViewport.durationProgress) * previousTimelineDuration
            let preservedViewport = TimelineViewport(
                startProgress: Float(absoluteStart / nextTimelineDuration),
                durationProgress: Float(absoluteDuration / nextTimelineDuration)
            )
            setViewport(preservedViewport)
        }
        if let pendingRestoredViewport, isSelectionEnabled {
            self.pendingRestoredViewport = nil
            setViewport(pendingRestoredViewport)
        }
        updateTrackLayoutForCurrentBounds(requestRender: false)

        updateTimelineRenderer { renderer in
            renderer.displayTracks(tracks, animateWaveformTransition: animateWaveformTransition)
        }
        displayTrimPreview(nil)

        if wasSelectionEnabled != isSelectionEnabled {
            window?.invalidateCursorRects(for: self)
        }

        if animateWaveformTransition {
            startTransientRenderPulse(duration: waveformTransitionRenderPulseDuration)
        }

        if !isSelectionEnabled {
            selectionAnchorProgress = nil
            selectionAnchorPoint = nil
            selectionAnchorTrackID = nil
            activeDragMode = nil
            isDraggingSelection = false
            isDraggingTrim = false
            rightPanPreviousPoint = nil
            rightPanPreviousTime = nil
            rightPanLastMovementTime = nil
            stopRightPanMomentum()
            stopZoomMomentum()
            displaySelection(nil)
            displayHoverProgress(nil)
            onSelectionChanged?(nil)
        }
    }

    var currentViewport: TimelineViewport {
        viewport
    }

    func restoreViewport(_ restoredViewport: TimelineViewport?) {
        guard let restoredViewport else {
            pendingRestoredViewport = nil
            setViewport(.full)
            return
        }

        if isSelectionEnabled {
            pendingRestoredViewport = nil
            setViewport(restoredViewport)
        } else {
            pendingRestoredViewport = restoredViewport
        }
    }

    func displayTrackMixSettings(_ tracks: [TimelineRenderState.Track]) {
        currentTrackIDs = tracks.map(\.id)
        timelineDuration = Self.timelineDuration(for: tracks)
        let wasSelectionEnabled = isSelectionEnabled
        isSelectionEnabled = tracks.contains { $0.hasWaveform }
        updateTrackLayoutForCurrentBounds(requestRender: false)

        updateTimelineRenderer { renderer in
            renderer.displayTrackMixSettings(tracks)
        }
        requestTimelineRender()

        if wasSelectionEnabled != isSelectionEnabled {
            window?.invalidateCursorRects(for: self)
        }
    }

    private static func timelineDuration(for tracks: [TimelineRenderState.Track]) -> TimeInterval {
        tracks.reduce(TimeInterval(0)) { result, track in
            max(result, track.durationHint ?? track.waveformOverview?.duration ?? 0)
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

    func updateWaveformFisheyeTuning(
        radius: Float,
        exponent: Float,
        minimumVisibleDuration: TimeInterval,
        maximumVisibleDuration: TimeInterval,
        fadeCurve: Float,
        activationDuration: TimeInterval
    ) {
        updateTimelineRenderer { renderer in
            renderer.updateWaveformFisheyeTuning(
                radius: radius,
                exponent: exponent,
                minimumVisibleDuration: minimumVisibleDuration,
                maximumVisibleDuration: maximumVisibleDuration,
                fadeCurve: fadeCurve,
                activationDuration: activationDuration
            )
        }
        requestTimelineRender()
    }

    func displayPlayheadProgress(
        _ progress: Float,
        syncRenderer: Bool = true,
        anchorTimestamp: CFTimeInterval? = nil,
        resetsTouchStart: Bool = true,
        restartsFisheyeActivation: Bool = false,
        restartsPlayheadKick: Bool = false
    ) {
        let clampedProgress = min(max(progress, 0), 1)
        pagingPlayheadProgress = clampedProgress
        pagingPlayheadAnchorTimestamp = anchorTimestamp ?? CACurrentMediaTime()
        pageViewportIfNeeded(forPlayheadProgress: clampedProgress)
        updateTimelineRenderer { renderer in
            renderer.displayPlayheadProgress(
                clampedProgress,
                force: syncRenderer,
                anchorTimestamp: anchorTimestamp,
                resetsTouchStart: resetsTouchStart,
                restartsFisheyeActivation: restartsFisheyeActivation,
                restartsPlayheadKick: restartsPlayheadKick
            )
        }
        requestTimelineRender()
    }

    func displayedPlayheadProgress(at timestamp: CFTimeInterval = CACurrentMediaTime()) -> Float? {
        timelineRenderer?.projectedPlayheadProgress(at: timestamp)
    }

    func pausePresentationPlayheadProgress() -> Float? {
        let timestamp = max(CACurrentMediaTime(), latestSubmittedPresentationTimestamp)
        return displayedPlayheadProgress(at: timestamp)
    }

    func displayPlaybackActive(_ isActive: Bool) {
        isTimelinePlaybackActive = isActive
        updateTimelineRenderer { renderer in
            renderer.displayPlaybackActive(isActive)
        }
        requestTimelineRender()
        if !isActive {
            startTransientRenderPulse(duration: playbackStopTouchTrailRenderPulseDuration)
        }
    }

    func displayRecordingActive(_ isActive: Bool) {
        updateTimelineRenderer { renderer in
            renderer.displayRecordingActive(isActive)
        }
        requestTimelineRender()
    }

    func displaySelection(_ selection: TimelineSelection?) {
        timelineRenderer?.publishInteractionSelection(selection)
        requestTimelineRender()
    }

    func displaySelectedTrack(_ trackID: UUID?) {
        updateTimelineRenderer { renderer in
            renderer.displaySelectedTrack(trackID)
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
        timelineRenderer?.publishInteractionHover(progress: progress, isArmed: isArmed)
        requestTimelineRender()
    }

    func displayGainPreview(selection: TimelineSelection?, gain: Float) {
        updateTimelineRenderer { renderer in
            renderer.displayGainPreview(selection: selection, gain: gain)
        }
        requestTimelineRender()
    }

    func triggerDeletionEffect(selection: TimelineSelection, sourceSelection: TimelineSelection? = nil) {
        updateTimelineRenderer { renderer in
            renderer.triggerDeletionEffect(selection: selection, sourceSelection: sourceSelection)
        }
        requestTimelineRender()
        startTransientRenderPulse(duration: 0.34)
    }

    func clearDeletionEffects() {
        updateTimelineRenderer { renderer in
            renderer.clearDeletionEffects()
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
        updateTrackLayoutForCurrentBounds(requestRender: false)
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
            renderer.onRenderDataPrepared = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleRenderDataPreparedRender()
                }
            }
            let initialViewport = viewport
            let initialTrackLayout = trackLayout
            updateTimelineRenderer { renderer in
                renderer.displayViewport(initialViewport)
                renderer.displayTrackLayout(initialTrackLayout)
            }
            requestTimelineRender()
        } catch {
            Swift.print("Soundtime could not create the timeline renderer: \(error)")
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

    private func scheduleRenderDataPreparedRender() {
        guard !isRenderDataPreparedRenderPending else {
            return
        }

        isRenderDataPreparedRenderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            isRenderDataPreparedRenderPending = false
            requestTimelineRender()
        }
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

    private func tearDownTimelineAnimation() {
        timelineDisplayLink?.invalidate()
        timelineDisplayLink = nil
        transientRenderEndTime = nil
        needsTimelineRender = false
        isTimelinePlaybackActive = false
        stopRightPanMomentum()
        stopZoomMomentum()
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
            !viewport.isFull,
            let playheadProgress = projectedPagingPlayheadProgress(at: frame.targetPresentationTimestamp)
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
        guard renderFlightGate.begin() else {
            return false
        }

        guard
            let timelineRenderer,
            let renderTarget = makeTimelineRenderTarget(frame: frame)
        else {
            renderFlightGate.finish()
            return false
        }

        latestSubmittedPresentationTimestamp = frame.targetPresentationTimestamp
        timelineRenderQueue.async { [weak self, timelineRenderer, renderTarget] in
            timelineRenderer.render(to: renderTarget)
            self?.renderFlightGate.finish()
        }
        return true
    }

    private func startTransientRenderPulse(duration: CFTimeInterval? = nil) {
        transientRenderEndTime = CFAbsoluteTimeGetCurrent() + (duration ?? transientRenderPulseDuration)
        startTimelineDisplayLink()
    }

    private func projectedPagingPlayheadProgress(at timestamp: CFTimeInterval) -> Float? {
        guard isTimelinePlaybackActive, timelineDuration.isFinite, timelineDuration > 0 else {
            return nil
        }

        let elapsedTime = timestamp - pagingPlayheadAnchorTimestamp
        let projectedProgress = pagingPlayheadProgress + Float(elapsedTime / timelineDuration)
        return min(max(projectedProgress, 0), 1)
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

        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        onAudioFileDropped?(url)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 6, event.modifierFlags.contains(.command) {
            onUndo?()
            return
        }

        if event.keyCode == 7, event.modifierFlags.contains(.command) {
            onCutSelection?()
            return
        }

        if event.keyCode == 8, event.modifierFlags.contains(.command) {
            onCopySelection?()
            return
        }

        if event.keyCode == 9, event.modifierFlags.contains(.command) {
            onPasteAudio?()
            return
        }

        if
            event.charactersIgnoringModifiers?.lowercased() == "b",
            event.modifierFlags.contains(.command)
        {
            onSplitAtPlayhead?()
            return
        }

        if event.keyCode == 14, event.modifierFlags.contains(.command) {
            onExportRequested?()
            return
        }

        if event.keyCode == 1, event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.shift) {
                onSaveProjectAsRequested?()
            } else {
                onSaveProjectRequested?()
            }
            return
        }

        if event.keyCode == 31, event.modifierFlags.contains(.command) {
            onOpenProjectRequested?()
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

    @objc func openProject(_ sender: Any?) {
        onOpenProjectRequested?()
    }

    @objc func openRecentProject(_ sender: Any?) {
        guard
            let menuItem = sender as? NSMenuItem,
            let url = menuItem.representedObject as? URL
        else {
            return
        }

        onOpenRecentProjectRequested?(url)
    }

    @objc func clearRecentProjects(_ sender: Any?) {
        onClearRecentProjectsRequested?()
    }

    @objc func saveProject(_ sender: Any?) {
        onSaveProjectRequested?()
    }

    @objc func saveProjectAs(_ sender: Any?) {
        onSaveProjectAsRequested?()
    }

    @objc func toggleDebugTools(_ sender: Any?) {
        onToggleDebugTools?()
    }

    @objc func undoTimelineEdit(_ sender: Any?) {
        onUndo?()
    }

    @objc func cutTimelineSelection(_ sender: Any?) {
        onCutSelection?()
    }

    @objc func copyTimelineSelection(_ sender: Any?) {
        onCopySelection?()
    }

    @objc func pasteTimelineAudio(_ sender: Any?) {
        onPasteAudio?()
    }

    @objc func splitAtPlayhead(_ sender: Any?) {
        onSplitAtPlayhead?()
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

    @objc func normalizeTimelineSelection(_ sender: Any?) {
        onNormalizeRequested?()
    }

    @objc func deleteSilence(_ sender: Any?) {
        onDeleteSilenceRequested?()
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
        case #selector(normalizeTimelineSelection(_:)):
            return canApplyGainEffect
        case #selector(deleteSilence(_:)):
            return canDeleteSilence
        case #selector(reapplyLastEffect(_:)):
            return canReapplyLastEffect
        case #selector(splitAtPlayhead(_:)):
            return canSplitAtPlayhead
        case #selector(toggleDebugTools(_:)):
            menuItem.state = isDebugToolsVisible ? .on : .off
            return true
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

        let hasGesturePhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        let isGestureEnding =
            event.phase.contains(.ended) ||
            event.phase.contains(.cancelled) ||
            event.momentumPhase.contains(.ended) ||
            event.momentumPhase.contains(.cancelled)
        defer {
            if isGestureEnding || !hasGesturePhase {
                scrollGestureMode = nil
            }
        }

        let horizontalDelta = event.scrollingDeltaX
        let verticalDelta = event.scrollingDeltaY
        guard horizontalDelta != 0 || verticalDelta != 0 else {
            if isGestureEnding, scrollGestureMode == .zoom, event.momentumPhase.isEmpty {
                startZoomMomentumIfNeeded()
            }
            return
        }
        let proposedGestureMode: ScrollGestureMode =
            abs(verticalDelta) >= abs(horizontalDelta) && verticalDelta != 0 ?
            .zoom :
            .pan
        let gestureMode = scrollGestureMode ?? proposedGestureMode
        scrollGestureMode = gestureMode

        if gestureMode == .zoom {
            stopRightPanMomentum()
            guard verticalDelta != 0 else {
                return
            }
            let anchorProgress = progress(for: convert(event.locationInWindow, from: nil))
            let logScaleDelta = Float(verticalDelta) * scrollZoomSensitivity
            applyZoomMomentumInput(
                logScaleDelta: logScaleDelta,
                anchorProgress: anchorProgress,
                timestamp: event.timestamp,
                recordsVelocity: event.momentumPhase.isEmpty
            )
            if !hasGesturePhase {
                startZoomMomentumIfNeeded()
            }
            return
        }

        stopZoomMomentum()
        guard horizontalDelta != 0, bounds.width > 0 else {
            return
        }

        let progressDelta = Float(-horizontalDelta / bounds.width) * viewport.durationProgress
        setViewport(viewport.panned(byProgress: progressDelta))
    }

    override func magnify(with event: NSEvent) {
        guard isSelectionEnabled else {
            super.magnify(with: event)
            return
        }

        stopRightPanMomentum()
        let hasGesturePhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        let isGestureEnding =
            event.phase.contains(.ended) ||
            event.phase.contains(.cancelled) ||
            event.momentumPhase.contains(.ended) ||
            event.momentumPhase.contains(.cancelled)
        defer {
            if isGestureEnding || !hasGesturePhase {
                scrollGestureMode = nil
            }
        }

        if scrollGestureMode == nil {
            scrollGestureMode = .zoom
        }
        guard scrollGestureMode == .zoom else {
            return
        }

        let anchorProgress = progress(for: convert(event.locationInWindow, from: nil))
        let zoomFactor = max(1 + Float(event.magnification), 0.1)
        let logScaleDelta = log(zoomFactor)
        if logScaleDelta != 0 {
            applyZoomMomentumInput(
                logScaleDelta: logScaleDelta,
                anchorProgress: anchorProgress,
                timestamp: event.timestamp,
                recordsVelocity: event.momentumPhase.isEmpty
            )
        }
        if isGestureEnding {
            startZoomMomentumIfNeeded()
        }
    }

    override func smartMagnify(with event: NSEvent) {
        guard isSelectionEnabled else {
            super.smartMagnify(with: event)
            return
        }

        stopRightPanMomentum()
        stopZoomMomentum()

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
        stopZoomMomentum()
        onTimelineInteractionBegan?()
        let point = currentDragPoint(for: event)
        let timelineProgress = progress(for: point)
        if event.clickCount >= 2 {
            displayHoverProgress(nil)
            displaySelection(nil)
            onSelectionChanged?(nil)
            selectionAnchorProgress = nil
            selectionAnchorPoint = nil
            selectionAnchorTrackID = nil
            activeDragMode = nil
            isDraggingSelection = false
            isDraggingTrim = false
            onPlayFromProgress?(timelineProgress)
            return
        }

        if let trimDragMode = trimDragMode(for: point) {
            displayHoverProgress(nil)
            activeDragMode = trimDragMode
            selectionAnchorProgress = Double(progress(for: point, followsVisualFisheye: false))
            selectionAnchorPoint = point
            selectionAnchorTrackID = nil
            isDraggingSelection = false
            isDraggingTrim = false
            displaySelection(nil)
            onSelectionChanged?(nil)
            return
        }

        activeDragMode = .selection
        selectionAnchorProgress = preciseProgress(for: point)
        selectionAnchorPoint = point
        selectionAnchorTrackID = trackID(at: point)
        isDraggingSelection = false
        isDraggingTrim = false
        displayHoverProgress(timelineProgress, isArmed: true)
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
                updateTrimPreview(for: activeDragMode, progress: progress(for: point, followsVisualFisheye: false))
            }
            return
        }

        if !isDraggingSelection, didMovePastSelectionThreshold(to: point) {
            isDraggingSelection = true
            displayHoverProgress(nil)
        }

        if isDraggingSelection {
            updateSelection(from: selectionAnchorProgress, to: preciseProgress(for: point), notifyChange: false)
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

        let point = currentDragPoint(for: event)
        let timelineProgress = progress(for: point)
        if
            (activeDragMode == .trimStart || activeDragMode == .trimEnd),
            let activeDragMode
        {
            let trimRange = trimRange(
                for: activeDragMode,
                progress: progress(for: point, followsVisualFisheye: false)
            )
            displayTrimPreview(nil)

            if isDraggingTrim, trimRange.trimsAudio, trimRange.durationProgress > 0.001 {
                onTrimRequested?(trimRange)
            }
        } else if isDraggingSelection {
            updateSelection(from: selectionAnchorProgress, to: preciseProgress(for: point), notifyChange: true)
        } else {
            displaySelection(nil)
            onSelectionChanged?(nil)
            onSeekRequested?(timelineProgress)
        }

        self.selectionAnchorProgress = nil
        selectionAnchorPoint = nil
        selectionAnchorTrackID = nil
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
        stopZoomMomentum()
        onTimelineInteractionBegan?()
        rightPanPreviousPoint = currentDragPoint(for: event)
        rightPanPreviousTime = event.timestamp
        rightPanLastMovementTime = nil
        rightPanVelocityProgressPerSecond = 0
        selectionAnchorProgress = nil
        selectionAnchorPoint = nil
        selectionAnchorTrackID = nil
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

    private func applyZoomMomentumInput(
        logScaleDelta: Float,
        anchorProgress: Float,
        timestamp: TimeInterval,
        recordsVelocity: Bool
    ) {
        guard logScaleDelta != 0 else {
            return
        }

        stopZoomMomentum(clearVelocity: false)
        zoomMomentumAnchorProgress = anchorProgress
        setViewport(viewport.zoomed(by: exp(logScaleDelta), around: anchorProgress))

        guard recordsVelocity else {
            return
        }

        let elapsedTime: TimeInterval
        if let zoomPreviousTime {
            elapsedTime = min(max(timestamp - zoomPreviousTime, 1 / 240), 1 / 12)
        } else {
            elapsedTime = 1 / 120
        }

        let instantVelocity = logScaleDelta / Float(elapsedTime)
        let smoothedVelocity =
            zoomVelocityLogScalePerSecond * (1 - zoomVelocitySmoothing) +
            instantVelocity * zoomVelocitySmoothing
        zoomVelocityLogScalePerSecond = min(
            max(smoothedVelocity, -zoomMomentumMaximumVelocity),
            zoomMomentumMaximumVelocity
        )
        zoomPreviousTime = timestamp
        zoomLastInputTime = timestamp
    }

    private func startZoomMomentumIfNeeded() {
        stopZoomMomentum(clearVelocity: false)

        guard
            isSelectionEnabled,
            zoomMomentumAnchorProgress != nil,
            abs(zoomVelocityLogScalePerSecond) >= zoomMomentumMinimumVelocity
        else {
            stopZoomMomentum()
            return
        }

        zoomMomentumLastTime = CFAbsoluteTimeGetCurrent()
        let frameRate = window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 120
        let timer = Timer(timeInterval: 1 / Double(max(frameRate, 60)), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepZoomMomentum()
            }
        }

        zoomMomentumTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stepZoomMomentum() {
        guard
            isSelectionEnabled,
            let anchorProgress = zoomMomentumAnchorProgress,
            abs(zoomVelocityLogScalePerSecond) >= zoomMomentumMinimumVelocity
        else {
            stopZoomMomentum()
            return
        }

        let currentTime = CFAbsoluteTimeGetCurrent()
        let elapsedTime = min(max(currentTime - (zoomMomentumLastTime ?? currentTime), 1 / 240), 1 / 20)
        zoomMomentumLastTime = currentTime

        let unclampedLogScaleDelta = zoomVelocityLogScalePerSecond * Float(elapsedTime)
        let logScaleDelta = min(
            max(unclampedLogScaleDelta, -zoomMomentumMaximumStepLogScale),
            zoomMomentumMaximumStepLogScale
        )
        let nextViewport = viewport.zoomed(by: exp(logScaleDelta), around: anchorProgress)
        guard nextViewport != viewport else {
            stopZoomMomentum()
            return
        }

        setViewport(nextViewport)
        let decay = Float(exp(-zoomMomentumDecayRate * elapsedTime))
        zoomVelocityLogScalePerSecond *= decay
    }

    private func stopZoomMomentum(clearVelocity: Bool = true) {
        zoomMomentumTimer?.invalidate()
        zoomMomentumTimer = nil
        zoomMomentumLastTime = nil

        if clearVelocity {
            zoomMomentumAnchorProgress = nil
            zoomPreviousTime = nil
            zoomLastInputTime = nil
            zoomVelocityLogScalePerSecond = 0
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

    private func progress(for point: CGPoint, followsVisualFisheye: Bool = true) -> Float {
        guard bounds.width > 0 else {
            return 0
        }

        let viewportProgress = viewportProgress(for: point, followsVisualFisheye: followsVisualFisheye)
        return viewport.timelineProgress(forViewportProgress: viewportProgress)
    }

    private func preciseProgress(for point: CGPoint, followsVisualFisheye: Bool = true) -> Double {
        guard bounds.width > 0 else {
            return 0
        }

        let viewportProgress = Double(viewportProgress(for: point, followsVisualFisheye: followsVisualFisheye))
        return min(
            max(Double(viewport.startProgress) + viewportProgress * Double(viewport.durationProgress), 0),
            1
        )
    }

    private func viewportProgress(for point: CGPoint, followsVisualFisheye: Bool) -> Float {
        guard bounds.width > 0 else {
            return 0
        }

        let visualViewportProgress = min(max(Float(point.x / bounds.width), 0), 1)
        guard
            followsVisualFisheye,
            let timelineRenderer
        else {
            return visualViewportProgress
        }

        return timelineRenderer.inverseFisheyeViewportProgress(
            visualViewportProgress,
            trackID: trackID(at: point),
            timestamp: CACurrentMediaTime()
        )
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

    func scrollTracks(byPixels deltaPixels: Float) {
        let nextTrackLayout = trackLayout.scrolled(
            by: deltaPixels,
            totalTrackCount: currentTrackIDs.count,
            viewportHeight: Float(max(bounds.height, 1))
        )
        guard nextTrackLayout != trackLayout else {
            return
        }

        trackLayout = nextTrackLayout
        updateTimelineRenderer { renderer in
            renderer.displayTrackLayout(nextTrackLayout)
        }
        updateTrackLayoutForCurrentBounds(requestRender: false)
        requestTimelineRender()
    }

    private func resolvedTrackLayoutForCurrentBounds() -> ResolvedTimelineTrackLayout {
        trackLayout.resolved(
            totalTrackCount: currentTrackIDs.count,
            viewportHeight: Float(max(bounds.height, 1))
        )
    }

    private func updateTrackLayoutForCurrentBounds(requestRender: Bool) {
        let clampedLayout = trackLayout.clamped(
            totalTrackCount: currentTrackIDs.count,
            viewportHeight: Float(max(bounds.height, 1))
        )
        let layoutChanged = clampedLayout != trackLayout
        trackLayout = clampedLayout
        let resolvedLayout = resolvedTrackLayoutForCurrentBounds()
        if lastPublishedTrackLayout != resolvedLayout {
            lastPublishedTrackLayout = resolvedLayout
            onTrackLaneLayoutChanged?(resolvedLayout)
        }

        guard layoutChanged else {
            return
        }

        updateTimelineRenderer { renderer in
            renderer.displayTrackLayout(clampedLayout)
        }
        if requestRender {
            requestTimelineRender()
        }
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

    private func updateSelection(from startProgress: Double, to endProgress: Double, notifyChange: Bool) {
        let selection = TimelineSelection(
            startProgress: startProgress,
            endProgress: endProgress,
            trackID: selectionAnchorTrackID
        )
        let visibleSelection = selection.durationProgress > 0 ? selection : nil

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

    private func trackID(at point: CGPoint) -> UUID? {
        guard
            bounds.height > 0,
            !currentTrackIDs.isEmpty
        else {
            return nil
        }

        let yFromTop = Float(bounds.height - point.y)
        guard let trackIndex = resolvedTrackLayoutForCurrentBounds().trackIndex(atYFromTop: yFromTop) else {
            return nil
        }
        guard currentTrackIDs.indices.contains(trackIndex) else {
            return nil
        }
        return currentTrackIDs[trackIndex]
    }
}
