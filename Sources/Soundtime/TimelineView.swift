import AppKit
import Metal

struct TimelineSelectionDragSmokeSnapshot: Sendable {
    var leadingProgress: Float
    var viewportDurationProgress: Float
    var boundsWidth: CGFloat

    func edgeErrorPixels(expectedLeadingProgress: Double) -> Double {
        let progressError = abs(Double(leadingProgress) - expectedLeadingProgress)
        let visibleDuration = max(Double(viewportDurationProgress), 0.000_001)
        return progressError / visibleDuration * Double(max(boundsWidth, 1))
    }
}

struct TimelineDeletionEffectRequest: Sendable {
    let selection: TimelineSelection
    let sourceSelection: TimelineSelection?
}

final class TimelineView: TimelineMetalLayerView, NSMenuItemValidation {
    private static let timelineRenderQueueSpecificKey = DispatchSpecificKey<Bool>()

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
    var onAudioFileDragEntered: ((URL) -> Void)?
    var onAudioFileDragExited: ((URL) -> Void)?
    var onUnsupportedAudioFileDropped: ((URL) -> Void)?
    var onTogglePlayback: (() -> Void)?
    var onDeleteSelection: (() -> Void)?
    var onRemoveTimeRangeRequested: (() -> Void)?
    var onClearSelection: (() -> Void)?
    var onCutSelection: (() -> Void)?
    var onCopySelection: (() -> Void)?
    var onPasteAudio: (() -> Void)?
    var onDuplicateRegionRequested: (() -> Void)?
    var onSplitAtPlayhead: (() -> Void)?
    var onInsertSilenceRequested: (() -> Void)?
    var onHealAdjacentClipsRequested: (() -> Void)?
    var onNudgeSelectionRequested: ((Int) -> Void)?
    var onSlipClipContentsRequested: ((Int) -> Void)?
    var onSnapSelectionRequested: (() -> Void)?
    var onSelectTimeAcrossLinkedTracksRequested: (() -> Void)?
    var onSelectAllClipsOnTrackRequested: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onExportRequested: (() -> Void)?
    var onSelectionRegionContextExportRequested: (() -> Void)?
    var onImportAudioFileRequested: (() -> Void)?
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
    var onDenoiseRequested: (() -> Void)?
    var onSeparateMusicStemsRequested: (() -> Void)?
    var onTranscribeSelectedTrackRequested: (() -> Void)?
    var onToggleTranscriptLayerRequested: (() -> Void)?
    var onTranscriptSelectionChanged: ((TranscriptTokenSelection?) -> Void)?
    var onTranscriptEditCommandRequested: ((TranscriptEditCommand) -> Void)?
    var onToggleTranscriptAlignmentDebugRequested: (() -> Void)?
    var onDeleteSilenceRequested: (() -> Void)?
    var onAcceptDeadAirCandidateRequested: (() -> Void)?
    var onAcceptHighConfidenceDeadAirCandidatesRequested: (() -> Void)?
    var onRejectDeadAirCandidateRequested: (() -> Void)?
    var onAuditionDeadAirCandidateRequested: (() -> Void)?
    var onNextDeadAirCandidateRequested: (() -> Void)?
    var onPreviousDeadAirCandidateRequested: (() -> Void)?
    var onReapplyLastEffect: (() -> Void)?
    var onSeekRequested: ((Float) -> Void)?
    var onPlayFromProgress: ((Float) -> Void)?
    var onSelectionChanged: ((TimelineSelection?) -> Void)?
    var onTrimRequested: ((TimelineTrimRange) -> Void)?
    var onClipBoundaryTrimRequested: ((TimelineClipBoundaryTrim) -> Void)?
    var onFrameStatsChanged: ((TimelineFrameStats) -> Void)?
    var onViewportChanged: ((TimelineViewport) -> Void)?
    var onTimelineInteractionBegan: (() -> Void)?
    var onTrackLaneLayoutChanged: ((ResolvedTimelineTrackLayout) -> Void)?
    var onLoopRangeChanged: ((TimelineLoopRange) -> Void)?
    var onLoopRangeEnabledChanged: ((Bool) -> Void)?
    var onPlaybackVisualProgressChanged: ((Float) -> Void)?
    var onExportWAVRequested: (() -> Void)?
    var onExportSelectedRegionRequested: (() -> Void)?
    var onExportMixdownAndStemsRequested: (() -> Void)?
    var onExportStemsRequested: (() -> Void)?
    var canApplyGainEffect = false
    var canApplyFadeEffect = false
    var canApplyDenoiseEffect = false
    var canApplyStemSeparationEffect = false
    var canTranscribeSelectedTrack = false
    var canReapplyLastEffect = false
    var canSplitAtPlayhead = false
    var canCutSelection = false
    var canCopySelection = false
    var canPasteAudio = false
    var canDeleteSelection = false
    var canClearSelection = false
    var canDeleteSilence = false
    var canUseDeadAirCandidate = false
    var isDebugToolsVisible = false

    private enum TimelineDragMode {
        case selection
        case trimStart
        case trimEnd
        case clipBoundary
        case loopStart
        case loopEnd
        case loopRegion
    }

    private struct ClipBoundaryHit {
        let trackID: UUID
        let clipRange: TimelineRenderState.ClipRange
        let edge: TimelineClipBoundaryTrim.Edge
    }

    private enum ScrollGestureMode {
        case pan
        case zoom
    }

    private enum TimelineRenderCadence {
        case immediate
        case coalescedInteraction
        case displayLinkPulse
        case none
    }

    private var timelineRenderer: TimelineRenderer?
    private let bootstrapWaveformView = TimelineBootstrapWaveformView()
    private var rendererInitializationID = UUID()
    private var isRendererInitializationScheduled = false
    private var isAwaitingFirstMetalFrame = true
    private var currentTrackIDs: [UUID] = []
    private var currentRenderTracks: [TimelineRenderState.Track] = []
    private let transcriptOverlayView = TimelineTranscriptOverlayView()
    private let dropPreviewLayer = CALayer()
    private let dropPreviewAccentLayer = CALayer()
    private let dropPreviewTextLayer = CATextLayer()
    private var activeDropPreviewURL: URL?
    private var hasAcceptedCurrentDrag = false
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
    private var currentSelection: TimelineSelection?
    private var liveSelectionDragSnapshot: TimelineSelectionDragSnapshot?
    private var selectionDragPreviousPoint: CGPoint?
    private var selectionDragPreviousTimestamp: CFTimeInterval?
    private var selectionDragVelocityPixelsPerSecond: CGFloat = 0
    private var activeClipBoundaryHit: ClipBoundaryHit?
    private var activeDragMode: TimelineDragMode?
    private var hoveredLoopEndpoint: TimelineLoopEndpoint?
    private var activeLoopDragOffsetX: CGFloat = 0
    private var loopRange = TimelineLoopRange.default
    private var isLoopRangeEnabled = true
    private var isLoopRegionHovered = false
    private var hoverTrackingArea: NSTrackingArea?
    private var isInteractionSuppressed = false
    private var isDraggingSelection = false
    private var isDraggingTrim = false
    private var isDraggingLoop = false
    private var trackInsertionAnimationTimer: Timer?
    private var trackInsertionAnimationStartTime: CFTimeInterval?
    private var trackInsertionAnimationIndex: Int?
    private let trackInsertionAnimationDuration: CFTimeInterval = 0.22
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
    private var selectionDragRenderEndTime: CFTimeInterval?
    private var isProcessingSelectionAnimationActive = false
    private var needsTimelineRender = false
    private var isRenderDataPreparedRenderPending = false
    private var pendingRenderSubmittedCallbacks: [(CFTimeInterval) -> Void] = []
    private let renderFlightGate = RenderFlightGate()
    private var pendingTranscriptOverlayUpdate = false
    private var pendingCursorRectInvalidation = false
    private var hotPathContractSmokeFrameStatsEndTime: CFTimeInterval?
    private var transcriptViewportRelayoutAllowedUntil: CFTimeInterval?
    private var lastTranscriptOverlayUpdateTime: CFTimeInterval = 0
    private let transcriptOverlayInteractionUpdateInterval: CFTimeInterval = 1.0 / 24.0
    private let transcriptOverlayHotPathDeferralInterval: CFTimeInterval = 1.0 / 30.0
    private var transcriptInteractionState = TranscriptInteractionState.empty
    private var activeTranscriptDrag: TranscriptInteractionDrag?
    private var currentTranscriptSelection: TranscriptTokenSelection?
    private var isTranscriptAlignmentDebugVisible = false
    private var isTimelinePlaybackActive = false
    private var timelineDuration: TimeInterval = 0
    private var isTranscriptLayerVisible = false
    private var transcriptDisplayMode = TranscriptTimelineDisplayMode.hidden
    private var pagingPlayheadProgress: Float = 0
    private var pagingPlayheadAnchorTimestamp = CACurrentMediaTime()
    private var latestSubmittedPresentationTimestamp = CACurrentMediaTime()
    private let selectionDragThreshold: CGFloat = 0.01
    private let selectionDragVelocityRiseTimeConstant: CFTimeInterval = 0.055
    private let selectionDragVelocityFallTimeConstant: CFTimeInterval = 0.18
    private let selectionDragVelocityMaximumSampleInterval: CFTimeInterval = 1.0 / 30.0
    private let trimHandleHitWidth: CGFloat = 18
    private let loopFlagWidth: CGFloat = 18
    private let loopFlagHeight: CGFloat = 18
    private let loopRegionEdgeHitWidth: CGFloat = 14
    private let rightPanVelocitySmoothing: Float = 0.54
    private let rightPanMomentumDecayRate: Double = 3.85
    private let rightPanMomentumMinimumVelocity: Float = 0.00042
    private let rightPanStationaryDecayRate: Double = 4.8
    private let rightPanMomentumReleaseWindow: TimeInterval = 0.34
    private let rightPanMovementThreshold: CGFloat = 0.25
    private let zoomVelocitySmoothing: Float = 0.38
    private let zoomMomentumDecayRate: Double = 8.4
    private let zoomMomentumMinimumVelocity: Float = 0.02
    private let zoomMomentumMaximumVelocity: Float = 4.5
    private let zoomMomentumMaximumStepLogScale: Float = 0.08
    private let transientRenderPulseDuration: CFTimeInterval = 0.18
    private let playbackStopTouchTrailRenderPulseDuration: CFTimeInterval = 1.25
    private let waveformTransitionRenderPulseDuration: CFTimeInterval = 0.24
    private let selectionDragEffectRenderPulseDuration: CFTimeInterval = 0.72
    private let deletionEffectRenderPulseDuration: CFTimeInterval = 0.18
    private let targetFramesPerSecond = 144
    private let scrollZoomSensitivity: Float = 0.01
    private let supportedAudioExtensions = AudioAssetImporter.supportedAudioFileExtensions
    private var selectionDragWaveformTuning = SelectionDragWaveformTuning.defaultValue

    init() {
        super.init(frame: .zero, device: nil)
        timelineRenderQueue.setSpecific(key: Self.timelineRenderQueueSpecificKey, value: true)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        timelineRenderQueue.setSpecific(key: Self.timelineRenderQueueSpecificKey, value: true)
        configure()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            rendererInitializationID = UUID()
            isRendererInitializationScheduled = false
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
        scheduleRendererInitializationAfterFirstPaint()
        configureDisplayLinkIfNeeded()
        updatePreferredFrameRate()
        requestTimelineRender()
    }

    func displayWaveform(_ waveformOverview: WaveformOverview?) {
        let trackID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
        currentTrackIDs = waveformOverview.map { _ in [trackID] } ?? []
        currentRenderTracks = waveformOverview.map {
            [TimelineRenderState.Track(
                id: trackID,
                waveformVersion: 0,
                waveformOverview: $0,
                durationHint: $0.duration,
                volume: 1,
                isMuted: false,
                isSoloed: false,
                clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
            )]
        } ?? []
        timelineDuration = waveformOverview?.duration ?? 0
        let wasSelectionEnabled = isSelectionEnabled
        isSelectionEnabled = waveformOverview?.isEmpty == false
        if !wasSelectionEnabled || !isSelectionEnabled {
            setViewport(.full, kicksImmediateRender: false)
        }
        updateTrackLayoutForCurrentBounds(requestRender: false)
        updateTranscriptOverlay()
        updateTimelineRenderer { renderer in
            renderer.displayWaveform(waveformOverview)
        }
        displayTrimPreview(nil)

        if wasSelectionEnabled != isSelectionEnabled {
            invalidateTimelineCursorRects()
        }

        startTransientRenderPulse(duration: waveformTransitionRenderPulseDuration)

        if !isSelectionEnabled {
            selectionAnchorProgress = nil
            selectionAnchorPoint = nil
            selectionAnchorTrackID = nil
            activeClipBoundaryHit = nil
            activeDragMode = nil
            isDraggingSelection = false
            isDraggingTrim = false
            isDraggingLoop = false
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

    func displayTracks(
        _ tracks: [TimelineRenderState.Track],
        animateWaveformTransition: Bool = true,
        allowImmediateWaveformPrewarm: Bool = true,
        allowImmediateInteractiveWaveformPrewarm: Bool = true,
        updatesRendererImmediately: Bool = false
    ) {
        let previousTimelineDuration = timelineDuration
        let previousViewport = viewport
        currentTrackIDs = tracks.map(\.id)
        currentRenderTracks = tracks
        let nextTimelineDuration = Self.timelineDuration(for: tracks)
        timelineDuration = nextTimelineDuration
        let wasSelectionEnabled = isSelectionEnabled
        isSelectionEnabled = Self.hasInteractiveTimelineContent(tracks)
        if !wasSelectionEnabled || !isSelectionEnabled {
            setViewport(.full, kicksImmediateRender: false, marksInteraction: false)
        } else if
            previousTimelineDuration > 0,
            nextTimelineDuration > 0,
            previousTimelineDuration != nextTimelineDuration
        {
            let preservedViewport = previousViewport.preservingAbsoluteTimes(
                previousDuration: previousTimelineDuration,
                nextDuration: nextTimelineDuration
            )
            setViewport(preservedViewport, kicksImmediateRender: false, marksInteraction: false)
        }
        if let pendingRestoredViewport, isSelectionEnabled {
            self.pendingRestoredViewport = nil
            setViewport(pendingRestoredViewport, kicksImmediateRender: false, marksInteraction: false)
        }
        updateTrackLayoutForCurrentBounds(requestRender: false)
        let drawableMetrics = currentTimelineDrawableMetricsForPrewarm()
        updateBootstrapWaveformView()
        let rendererUpdate: @Sendable (TimelineRenderer) -> Void = { renderer in
            renderer.updatePrewarmViewportSize(
                drawableMetrics.viewportSize,
                backingScale: drawableMetrics.backingScale
            )
            renderer.displayTracks(
                tracks,
                animateWaveformTransition: animateWaveformTransition,
                allowImmediateWaveformPrewarm: allowImmediateWaveformPrewarm,
                allowImmediateInteractiveWaveformPrewarm: allowImmediateInteractiveWaveformPrewarm
            )
            if
                updatesRendererImmediately,
                allowImmediateWaveformPrewarm,
                !allowImmediateInteractiveWaveformPrewarm,
                !animateWaveformTransition
            {
                renderer.prepareFirstPaintWaveformShaderBuffers(
                    drawableSize: drawableMetrics.viewportSize,
                    backingScale: drawableMetrics.backingScale
                )
            }
        }
        if updatesRendererImmediately {
            updateTimelineRendererImmediately(rendererUpdate)
        } else {
            updateTimelineRenderer(rendererUpdate)
        }
        requestTimelineRender()
        displayTrimPreview(nil)

        if wasSelectionEnabled != isSelectionEnabled {
            invalidateTimelineCursorRects()
        }

        if animateWaveformTransition {
            startTransientRenderPulse(duration: waveformTransitionRenderPulseDuration)
        }

        if !isSelectionEnabled {
            selectionAnchorProgress = nil
            selectionAnchorPoint = nil
            selectionAnchorTrackID = nil
            activeClipBoundaryHit = nil
            activeDragMode = nil
            isDraggingSelection = false
            isDraggingTrim = false
            isDraggingLoop = false
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

    func prepareTrackInsertionAnimation(at trackIndex: Int) {
        stopTrackInsertionAnimation(clearsLayout: false)
        trackInsertionAnimationIndex = max(trackIndex, 0)
        trackInsertionAnimationStartTime = nil
        trackLayout = trackLayout.insertingTrack(at: trackIndex, progress: 0)
    }

    func startPreparedTrackInsertionAnimation() {
        guard let trackInsertionAnimationIndex else {
            return
        }

        trackInsertionAnimationStartTime = CACurrentMediaTime()
        publishTrackLayout(
            trackLayout.insertingTrack(at: trackInsertionAnimationIndex, progress: 0),
            requestRender: true
        )

        let timer = Timer(timeInterval: 1.0 / Double(targetFramesPerSecond), repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Task { @MainActor [weak self] in
                self?.advanceTrackInsertionAnimation()
            }
        }
        trackInsertionAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    var currentViewport: TimelineViewport {
        viewport
    }

    func restoreViewport(_ restoredViewport: TimelineViewport?) {
        guard let restoredViewport else {
            pendingRestoredViewport = nil
            setViewport(.full, kicksImmediateRender: false, marksInteraction: false)
            return
        }

        if isSelectionEnabled {
            pendingRestoredViewport = nil
            setViewport(restoredViewport, kicksImmediateRender: false, marksInteraction: false)
        } else {
            pendingRestoredViewport = restoredViewport
        }
    }

    func displayTrackMixSettings(_ tracks: [TimelineRenderState.Track]) {
        currentTrackIDs = tracks.map(\.id)
        let mergedTracks = mergeTrackMetadata(tracks)
        currentRenderTracks = mergedTracks
        timelineDuration = Self.timelineDuration(for: mergedTracks)
        let wasSelectionEnabled = isSelectionEnabled
        isSelectionEnabled = Self.hasInteractiveTimelineContent(mergedTracks)
        updateTrackLayoutForCurrentBounds(requestRender: false)
        updateTimelineRenderer { renderer in
            renderer.displayTrackMixSettings(mergedTracks)
        }
        requestTimelineRender()

        if wasSelectionEnabled != isSelectionEnabled {
            invalidateTimelineCursorRects()
        }
    }

    private static func timelineDuration(for tracks: [TimelineRenderState.Track]) -> TimeInterval {
        tracks.reduce(TimeInterval(0)) { result, track in
            max(result, track.durationHint ?? track.waveformOverview?.duration ?? 0)
        }
    }

    private static func hasInteractiveTimelineContent(_ tracks: [TimelineRenderState.Track]) -> Bool {
        guard !tracks.isEmpty else {
            return false
        }

        return true
    }

    private func mergeTrackMetadata(_ tracks: [TimelineRenderState.Track]) -> [TimelineRenderState.Track] {
        let currentByID = Dictionary(uniqueKeysWithValues: currentRenderTracks.map { ($0.id, $0) })
        return tracks.map { track in
            let current = currentByID[track.id]
            return TimelineRenderState.Track(
                id: track.id,
                waveformVersion: track.waveformOverview == nil ?
                    (current?.waveformVersion ?? track.waveformVersion) :
                    track.waveformVersion,
                waveformOverview: track.waveformOverview ?? current?.waveformOverview,
                durationHint: track.durationHint ?? current?.durationHint,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed,
                hasWaveform: track.hasWaveform || current?.hasWaveform == true,
                clipRanges: track.clipRanges.isEmpty ? (current?.clipRanges ?? []) : track.clipRanges,
                waveformSegments: Self.shouldPreserveCurrentWaveformSegments(for: track) ?
                    (current?.waveformSegments ?? []) :
                    track.waveformSegments,
                waveformTileSource: track.waveformTileSource ?? current?.waveformTileSource,
                transcript: track.transcript ?? current?.transcript
            )
        }
    }

    private static func shouldPreserveCurrentWaveformSegments(
        for track: TimelineRenderState.Track
    ) -> Bool {
        track.waveformSegments.isEmpty &&
            track.waveformOverview == nil &&
            track.waveformTileSource == nil
    }

    func displayTranscriptLayerVisible(_ isVisible: Bool) {
        displayTranscriptMode(isVisible ? .waveformOverlay : .hidden)
    }

    func displayTranscriptMode(_ mode: TranscriptTimelineDisplayMode) {
        let sanitizedMode = mode
        guard transcriptDisplayMode != sanitizedMode else {
            updateTranscriptOverlay()
            return
        }

        transcriptDisplayMode = sanitizedMode
        isTranscriptLayerVisible = sanitizedMode != .hidden
        updateTranscriptOverlay()
    }

    func displayTranscriptSelection(_ selection: TranscriptTokenSelection?) {
        currentTranscriptSelection = selection
        transcriptInteractionState = TranscriptInteractionModel.state(
            previous: transcriptInteractionState,
            selection: selection
        )
        transcriptOverlayView.updateInteractionState(transcriptInteractionState)
    }

    func displayTranscriptMirroredTimelineSelection(_ selection: TimelineSelection?) {
        transcriptInteractionState = TranscriptInteractionModel.state(
            previous: transcriptInteractionState,
            mirroredTimelineSelection: selection
        )
        transcriptOverlayView.updateInteractionState(transcriptInteractionState)
    }

    func displayTranscriptActiveWord(_ wordID: UUID?) {
        transcriptInteractionState = TranscriptInteractionModel.state(
            previous: transcriptInteractionState,
            activeWordID: wordID
        )
        transcriptOverlayView.updateInteractionState(transcriptInteractionState)
    }

    func prepareLaunchPreviewFirstPaint(
        selectedTrackIDs: Set<UUID>,
        primaryTrackID: UUID?
    ) {
        currentSelection = nil
        liveSelectionDragSnapshot = nil
        currentTranscriptSelection = nil
        let keepsAlignmentDebugVisible = transcriptInteractionState.alignmentDebugEnabled
        transcriptInteractionState = TranscriptInteractionState.empty
        transcriptInteractionState.alignmentDebugEnabled = keepsAlignmentDebugVisible
        transcriptOverlayView.updateInteractionState(transcriptInteractionState)

        updateTimelineRendererImmediately { renderer in
            renderer.displaySelection(nil, marksInteraction: false)
            renderer.displaySelectedTracks(selectedTrackIDs, primaryTrackID: primaryTrackID)
        }
    }

    func displayTranscriptAlignmentDebug(_ isVisible: Bool) {
        isTranscriptAlignmentDebugVisible = isVisible
        transcriptInteractionState = TranscriptInteractionModel.state(
            previous: transcriptInteractionState,
            alignmentDebugEnabled: isVisible
        )
        transcriptOverlayView.updateInteractionState(transcriptInteractionState)
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

    func updateSelectionDragWaveformTuning(_ tuning: SelectionDragWaveformTuning) {
        selectionDragWaveformTuning = tuning.sanitized
        updateTimelineRenderer { renderer in
            renderer.updateSelectionDragWaveformTuning(tuning)
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
        let updateRenderer: @Sendable (TimelineRenderer) -> Void = { renderer in
            renderer.displayPlayheadProgress(
                clampedProgress,
                force: syncRenderer,
                anchorTimestamp: anchorTimestamp,
                resetsTouchStart: resetsTouchStart,
                restartsFisheyeActivation: restartsFisheyeActivation,
                restartsPlayheadKick: restartsPlayheadKick
            )
        }
        if syncRenderer {
            updateTimelineRendererImmediately(updateRenderer)
            kickInteractionRenderIfPossible()
        } else {
            updateTimelineRenderer(updateRenderer)
            requestTimelineRender()
        }
    }

    func displayPlayheadJumpTrail(from originProgress: Float, to targetProgress: Float) {
        let clampedOrigin = min(max(originProgress, 0), 1)
        let clampedTarget = min(max(targetProgress, 0), 1)
        guard abs(clampedTarget - clampedOrigin) > 0.000_001 else {
            return
        }

        updateTimelineRendererImmediately { renderer in
            renderer.displayPlayheadJumpTrail(from: clampedOrigin, to: clampedTarget)
        }
        startTransientRenderPulse(duration: 0.42)
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
        updateTimelineRendererImmediately { renderer in
            renderer.displayPlaybackActive(isActive)
        }
        requestTimelineRender()
        if !isActive {
            startTransientRenderPulse(duration: playbackStopTouchTrailRenderPulseDuration)
        }
    }

    func displayRecordingActive(_ isActive: Bool) {
        updateTimelineRendererImmediately { renderer in
            renderer.displayRecordingActive(isActive)
        }
        requestTimelineRender()
    }

    func displaySelection(_ selection: TimelineSelection?, marksInteraction: Bool = true) {
        currentSelection = selection
        liveSelectionDragSnapshot = nil
        if selection == nil {
            clearLiveSelectionDragSnapshot(clearsSelection: true)
        }
        updateTimelineRendererImmediately { renderer in
            renderer.displaySelection(selection, marksInteraction: marksInteraction)
        }
        requestTimelineRender()
    }

    func displayProcessingSelectionProgress(selection: TimelineSelection?, fractionCompleted: Float?) {
        isProcessingSelectionAnimationActive = selection != nil
        updateTimelineRendererImmediately { renderer in
            renderer.displayProcessingSelectionProgress(
                selection: selection,
                fractionCompleted: fractionCompleted
            )
        }
        requestTimelineRender()
        if isProcessingSelectionAnimationActive {
            startTimelineDisplayLink()
        }
    }

    func triggerSelectionCopyFlash() {
        updateTimelineRendererImmediately { renderer in
            renderer.triggerSelectionCopyFlash()
        }
        requestTimelineRender()
        startTransientRenderPulse(duration: 0.20)
    }

    func setInteractionSuppressed(_ isSuppressed: Bool) {
        guard isInteractionSuppressed != isSuppressed else {
            updateTimelineRendererImmediately { renderer in
                renderer.displayInteractionSuppressed(isSuppressed)
            }
            return
        }

        isInteractionSuppressed = isSuppressed
        updateTimelineRendererImmediately { renderer in
            renderer.displayInteractionSuppressed(isSuppressed)
        }
        if isSuppressed {
            activeDragMode = nil
            activeClipBoundaryHit = nil
            selectionAnchorProgress = nil
            selectionAnchorPoint = nil
            selectionAnchorTrackID = nil
            clearLiveSelectionDragSnapshot()
            isDraggingSelection = false
            isDraggingTrim = false
            isDraggingLoop = false
            activeTranscriptDrag = nil
            activeLoopDragOffsetX = 0
            displayHoverProgress(nil)
            displayHighlightedLoopEndpoint(nil)
            displayHighlightedLoopRegion(false)
            stopRightPanMomentum()
            stopZoomMomentum()
            scrollGestureMode = nil
            flushPendingCursorRectInvalidationIfNeeded()
        }
    }

    func displayModalBackdropActive(_ isActive: Bool) {
        updateTimelineRendererImmediately { renderer in
            renderer.displayModalBackdropActive(isActive)
        }
        requestTimelineRender()
    }

    private func displayLiveSelection(
        _ selection: TimelineSelection?,
        leadingProgress: Double,
        velocityPixelsPerSecond: CGFloat,
        direction: CGFloat,
        timestamp: CFTimeInterval,
        schedulesRender: Bool = true
    ) {
        currentSelection = selection
        guard let selection, selection.durationProgress > 0 else {
            clearLiveSelectionDragSnapshot(clearsSelection: true)
            if schedulesRender {
                kickInteractionRenderIfPossible()
            }
            return
        }

        let snapshot = TimelineSelectionDragSnapshot(
            selection: selection,
            leadingProgress: Float(leadingProgress),
            velocityPixelsPerSecond: Float(velocityPixelsPerSecond),
            direction: Float(direction),
            timestamp: timestamp
        )
        liveSelectionDragSnapshot = snapshot
        timelineRenderer?.publishInteractionSelectionDragSnapshot(snapshot)
        startSelectionDragRenderPulse(duration: selectionDragWaveformRenderPulseDuration)
        if schedulesRender {
            kickInteractionRenderIfPossible()
        }
    }

    func userPerceivedTimingSmokeDisplayLiveSelection(
        _ selection: TimelineSelection,
        leadingProgress: Double,
        velocityPixelsPerSecond: CGFloat,
        direction: CGFloat,
        timestamp: CFTimeInterval = CACurrentMediaTime()
    ) {
        displayLiveSelection(
            selection,
            leadingProgress: leadingProgress,
            velocityPixelsPerSecond: velocityPixelsPerSecond,
            direction: direction,
            timestamp: timestamp
        )
    }

    func userPerceivedTimingSmokeSelectionDragSnapshot() -> TimelineSelectionDragSmokeSnapshot? {
        guard let liveSelectionDragSnapshot else {
            return nil
        }
        return TimelineSelectionDragSmokeSnapshot(
            leadingProgress: liveSelectionDragSnapshot.leadingProgress,
            viewportDurationProgress: viewport.durationProgress,
            boundsWidth: bounds.width
        )
    }

    func hotPathContractSmokeBeginFrameStatsWindow(duration: CFTimeInterval = 0.45) {
        let requestedEndTime = CACurrentMediaTime() + max(duration, 0.01)
        hotPathContractSmokeFrameStatsEndTime = max(
            hotPathContractSmokeFrameStatsEndTime ?? 0,
            requestedEndTime
        )
        timelineRenderer?.resetFrameRateMeasurement()
        timelineRenderer?.noteTimelineInteraction()
        requestTimelineRender()
    }

    func hotPathContractSmokeIsRendererReady() -> Bool {
        timelineRenderer != nil && !isAwaitingFirstMetalFrame
    }

    func hotPathContractSmokeZoomBurst(stepCount: Int = 8, around anchorProgress: Float = 0.5) {
        hotPathContractSmokeBeginFrameStatsWindow(duration: 0.45)
        let count = max(stepCount, 1)
        for index in 0..<count {
            let direction: Float = index.isMultiple(of: 2) ? -1 : 1
            let logScaleDelta = direction * 0.055
            let nextViewport = viewport.zoomed(by: exp(logScaleDelta), around: anchorProgress)
            setViewport(
                nextViewport,
                transcriptCadence: .coalescedInteraction,
                invalidatesCursorRects: false,
                renderCadence: .coalescedInteraction
            )
        }
        requestTimelineRender()
    }

    func interactionReplaySmokeZoomStep(
        direction: Float,
        around anchorProgress: Float = 0.5
    ) -> Double {
        let startedAt = CACurrentMediaTime()
        let sanitizedDirection: Float = direction < 0 ? -1 : 1
        let nextViewport = viewport.zoomed(
            by: exp(sanitizedDirection * 0.055),
            around: anchorProgress
        )
        setViewport(
            nextViewport,
            transcriptCadence: .coalescedInteraction,
            invalidatesCursorRects: false,
            renderCadence: .coalescedInteraction
        )
        requestTimelineRender()
        return (CACurrentMediaTime() - startedAt) * 1_000
    }

    func interactionReplaySmokePanBurst(stepCount: Int = 12, progressDistance: Float = 0.18) -> Double {
        hotPathContractSmokeBeginFrameStatsWindow(duration: 0.45)
        let count = max(stepCount, 1)
        let stepDistance = progressDistance / Float(count)
        var submissionMilliseconds: Double = 0
        for index in 0..<count {
            let direction: Float = index < (count * 2) / 3 ? 1 : -1
            let startedAt = CACurrentMediaTime()
            setViewport(
                viewport.panned(byProgress: stepDistance * direction),
                transcriptCadence: .coalescedInteraction,
                invalidatesCursorRects: false,
                renderCadence: .immediate
            )
            submissionMilliseconds = max(submissionMilliseconds, (CACurrentMediaTime() - startedAt) * 1_000)
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.004))
        }
        requestTimelineRender()
        return submissionMilliseconds
    }

    func interactionReplaySmokeTranscriptHoverClickSelect() -> Bool {
        guard isTranscriptLayerVisible else {
            return false
        }

        var visibleRuns = transcriptOverlayView.visibleRunsSnapshot()
        if !visibleRuns.contains(where: \.isWord) {
            guard interactionReplaySmokePlaceTranscriptWordsInView() else {
                return false
            }
            layoutSubtreeIfNeeded()
            updateTranscriptOverlay(cadence: .immediate)
            visibleRuns = transcriptOverlayView.visibleRunsSnapshot()
        }

        guard
            let firstHit = visibleRuns.first(where: { $0.isWord }),
            let lastHit = visibleRuns.dropFirst().first(where: { $0.isWord && $0.trackID == firstHit.trackID }) ??
                visibleRuns.last(where: { $0.isWord && $0.trackID == firstHit.trackID }),
            let context = transcriptContext(for: firstHit.trackID)
        else {
            return false
        }

        hotPathContractSmokeBeginFrameStatsWindow(duration: 0.45)
        updateTranscriptHover(firstHit)
        let selection = TranscriptInteractionModel.selection(
            from: firstHit,
            to: lastHit,
            visibleRuns: visibleRuns,
            transcript: context.transcript,
            timeMap: context.timeMap
        )
        publishTranscriptSelection(selection, notifiesWorkspace: true)
        onSeekRequested?(progress(forProjectTime: firstHit.projectRange.startTime))
        kickInteractionRenderIfPossible()
        return selection != nil
    }

    private func interactionReplaySmokePlaceTranscriptWordsInView() -> Bool {
        guard timelineDuration > 0 else {
            return false
        }

        for track in currentRenderTracks {
            guard
                let transcript = track.transcript,
                let firstWord = transcript.words.first
            else {
                continue
            }

            let timeMap = transcript.sourceTimeMap ?? TranscriptSourceTimeMap.fromRenderTrack(track)
            let sourceEndTime = max(firstWord.endTime, firstWord.startTime + 0.05)
            guard let projectRange = timeMap.projectRanges(
                forSourceRange: firstWord.startTime..<sourceEndTime
            ).first else {
                continue
            }

            let centerTime = (projectRange.lowerBound + projectRange.upperBound) * 0.5
            let visibleSeconds = min(max(4.0, projectRange.upperBound - projectRange.lowerBound), timelineDuration)
            let durationProgress = Float(min(max(visibleSeconds / timelineDuration, 0.03), 0.25))
            let centerProgress = progress(forProjectTime: centerTime)
            let startProgress = centerProgress - durationProgress * 0.35
            setViewport(
                TimelineViewport(startProgress: startProgress, durationProgress: durationProgress),
                transcriptCadence: .immediate,
                invalidatesCursorRects: false,
                renderCadence: .immediate
            )
            requestTimelineRender()
            return true
        }

        return false
    }

    func hotPathContractSmokeTranscriptDiagnosticsSnapshot() -> TimelineTranscriptOverlayDiagnosticsSnapshot {
        transcriptOverlayView.diagnosticsSnapshotForSmokeTesting()
    }

    func hotPathContractSmokeLayoutSignature() -> String {
        [
            "\(Int((bounds.width * 2).rounded()))",
            "\(Int((bounds.height * 2).rounded()))",
            "\(Int((trackLayout.scrollOffset * 10).rounded()))",
            "\(Int((trackLayout.preferredTrackHeight * 10).rounded()))",
            "\(Int((trackLayout.rulerLaneHeight * 10).rounded()))",
            "\(trackLayout.insertionTrackIndex ?? -1)",
            "\(Int((trackLayout.insertionProgress * 1_000).rounded()))",
        ].joined(separator: "|")
    }

    func hotPathContractSmokeResetTranscriptDiagnostics() {
        transcriptOverlayView.resetDiagnosticsForSmokeTesting()
    }

    private func clearLiveSelectionDragSnapshot(clearsSelection: Bool = false) {
        liveSelectionDragSnapshot = nil
        if clearsSelection {
            timelineRenderer?.publishInteractionSelection(nil)
        }
        timelineRenderer?.publishInteractionSelectionDragSnapshot(nil)
    }

    func displaySelectedTrack(_ trackID: UUID?) {
        updateTimelineRendererImmediately { renderer in
            renderer.displaySelectedTrack(trackID)
        }
        requestTimelineRender()
    }

    func displaySelectedTracks(_ trackIDs: Set<UUID>, primaryTrackID: UUID?) {
        updateTimelineRendererImmediately { renderer in
            renderer.displaySelectedTracks(trackIDs, primaryTrackID: primaryTrackID)
        }
        requestTimelineRender()
    }

    private func displayTrimPreview(
        _ trimRange: TimelineTrimRange?,
        renderCadence: TimelineRenderCadence = .immediate
    ) {
        updateTimelineRendererImmediately { renderer in
            renderer.displayTrimPreview(trimRange)
        }
        requestRender(cadence: renderCadence)
    }

    func displayLoopRange(_ loopRange: TimelineLoopRange) {
        guard self.loopRange != loopRange else {
            return
        }

        self.loopRange = loopRange
        updateTimelineRendererImmediately { renderer in
            renderer.displayLoopRange(loopRange)
        }
        invalidateTimelineCursorRects()
        requestTimelineRender()
    }

    func displayLoopRangeEnabled(_ isEnabled: Bool) {
        guard isLoopRangeEnabled != isEnabled else {
            return
        }

        isLoopRangeEnabled = isEnabled
        updateTimelineRendererImmediately { renderer in
            renderer.displayLoopRangeEnabled(isEnabled)
        }
        requestTimelineRender()
    }

    func triggerLoopRangeFlash() {
        updateTimelineRendererImmediately { renderer in
            renderer.triggerLoopRangeFlash()
        }
        startTransientRenderPulse(duration: 0.35)
        requestTimelineRender()
    }

    private func displayHighlightedLoopEndpoint(
        _ endpoint: TimelineLoopEndpoint?,
        renderCadence: TimelineRenderCadence = .immediate
    ) {
        guard hoveredLoopEndpoint != endpoint else {
            return
        }

        hoveredLoopEndpoint = endpoint
        updateTimelineRendererImmediately { renderer in
            renderer.displayHighlightedLoopEndpoint(endpoint)
        }
        requestRender(cadence: renderCadence)
    }

    private func displayHighlightedLoopRegion(
        _ isHighlighted: Bool,
        renderCadence: TimelineRenderCadence = .immediate
    ) {
        guard isLoopRegionHovered != isHighlighted else {
            return
        }

        isLoopRegionHovered = isHighlighted
        updateTimelineRendererImmediately { renderer in
            renderer.displayHighlightedLoopRegion(isHighlighted)
        }
        requestRender(cadence: renderCadence)
    }

    private func displayHoverProgress(
        _ progress: Float?,
        isArmed: Bool = false,
        renderCadence: TimelineRenderCadence = .immediate
    ) {
        let publishedProgress = isInteractionSuppressed ? nil : progress
        let publishedArmed = isInteractionSuppressed ? false : isArmed
        timelineRenderer?.publishInteractionHover(progress: publishedProgress, isArmed: publishedArmed)
        requestRender(cadence: renderCadence)
    }

    func displayGainPreview(selection: TimelineSelection?, gain: Float) {
        updateTimelineRendererImmediately { renderer in
            renderer.displayGainPreview(selection: selection, gain: gain)
        }
        requestTimelineRender()
    }

    func displayCandidateRegions(_ candidateRegions: [TimelineRenderState.CandidateRegion]) {
        updateTimelineRenderer { renderer in
            renderer.displayCandidateRegions(candidateRegions)
        }
        requestTimelineRender()
    }

    func displayProcessingTrackHighlight(trackID: UUID?, alpha: Float) {
        updateTimelineRendererImmediately { renderer in
            renderer.displayProcessingTrackHighlight(trackID: trackID, alpha: alpha)
        }
        requestTimelineRender()
    }

    func prepareDeletionEffectRendering() {
        updateTimelineRendererImmediately { renderer in
            renderer.prepareVisibleWaveformShaderBuffersForDeletion()
        }
    }

    func triggerDeletionEffect(selection: TimelineSelection, sourceSelection: TimelineSelection? = nil) {
        triggerDeletionEffects([
            TimelineDeletionEffectRequest(
                selection: selection,
                sourceSelection: sourceSelection
            ),
        ])
    }

    func triggerDeletionEffects(_ requests: [TimelineDeletionEffectRequest]) {
        guard !requests.isEmpty else {
            return
        }
        updateTimelineRendererImmediately { renderer in
            renderer.triggerDeletionEffects(requests)
        }
        requestTimelineRender()
        startTransientRenderPulse(duration: deletionEffectRenderPulseDuration)
    }

    func triggerPasteEffect(selection: TimelineSelection, waveformOverview: WaveformOverview?) {
        updateTimelineRendererImmediately { renderer in
            renderer.triggerPasteEffect(selection: selection, waveformOverview: waveformOverview)
        }
        requestTimelineRender()
        startTransientRenderPulse(duration: deletionEffectRenderPulseDuration)
    }

    func clearDeletionEffects() {
        updateTimelineRenderer { renderer in
            renderer.clearDeletionEffects()
        }
        requestTimelineRender()
    }

    func notifyAfterNextSubmittedTimelineRender(_ callback: @escaping (CFTimeInterval) -> Void) {
        pendingRenderSubmittedCallbacks.append(callback)
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
        configureDropPreviewLayer()
        bootstrapWaveformView.translatesAutoresizingMaskIntoConstraints = false
        transcriptOverlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bootstrapWaveformView)
        addSubview(transcriptOverlayView)

        registerForDraggedTypes([.fileURL])
    }

    override func layout() {
        super.layout()
        bootstrapWaveformView.frame = bounds
        transcriptOverlayView.frame = bounds
        updateTrackLayoutForCurrentBounds(requestRender: false)
        updateBootstrapWaveformView()
        updateDropPreviewLayout()
        updateTranscriptOverlay()
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

    private func beginRendererInitialization() {
        let initializationID = UUID()
        rendererInitializationID = initializationID
        let pixelFormat = colorPixelFormat
        MetalRendererInitialization.timelineQueue.async {
            let result: Result<(MTLDevice, TimelineRenderer), Error> = Result {
                guard let backgroundDevice = MTLCreateSystemDefaultDevice() else {
                    throw NSError(
                        domain: "Soundtime.TimelineRenderer",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Metal device unavailable"]
                    )
                }
                return (
                    backgroundDevice,
                    try TimelineRenderer(device: backgroundDevice, pixelFormat: pixelFormat)
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    self.window != nil,
                    self.rendererInitializationID == initializationID
                else {
                    return
                }
                switch result {
                case let .success((device, renderer)):
                    self.installMetalDevice(device)
                    self.installTimelineRenderer(renderer)
                case let .failure(error):
                    Swift.print("Soundtime could not create the timeline renderer: \(error)")
                }
            }
        }
    }

    private func scheduleRendererInitializationAfterFirstPaint() {
        guard timelineRenderer == nil, !isRendererInitializationScheduled else {
            return
        }
        isRendererInitializationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.window != nil else {
                return
            }
            self.beginRendererInitialization()
        }
    }

    private func installTimelineRenderer(_ renderer: TimelineRenderer) {
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

        let tracks = currentRenderTracks
        let currentViewport = viewport
        let currentTrackLayout = trackLayout
        let currentLoopRange = loopRange
        let currentLoopRangeEnabled = isLoopRangeEnabled
        let currentSelection = currentSelection
        let currentPlayheadProgress = pagingPlayheadProgress
        let playbackActive = isTimelinePlaybackActive
        let drawableMetrics = currentTimelineDrawableMetricsForPrewarm()
        timelineRenderQueue.async { [renderer] in
            renderer.updatePrewarmViewportSize(
                drawableMetrics.viewportSize,
                backingScale: drawableMetrics.backingScale
            )
            renderer.displayViewport(currentViewport, marksInteraction: false)
            renderer.displayTrackLayout(currentTrackLayout, marksInteraction: false)
            renderer.displayLoopRange(currentLoopRange)
            renderer.displayLoopRangeEnabled(currentLoopRangeEnabled)
            renderer.displayTracks(
                tracks,
                animateWaveformTransition: false,
                allowImmediateWaveformPrewarm: true,
                allowImmediateInteractiveWaveformPrewarm: false
            )
            renderer.displaySelection(currentSelection, marksInteraction: false)
            renderer.displayPlayheadProgress(
                currentPlayheadProgress,
                force: true,
                resetsTouchStart: false
            )
            renderer.displayPlaybackActive(playbackActive)
        }
        isAwaitingFirstMetalFrame = true
        requestTimelineRender()
    }

    private func updateBootstrapWaveformView() {
        guard isAwaitingFirstMetalFrame else {
            return
        }
        bootstrapWaveformView.display(
            tracks: currentRenderTracks,
            viewport: viewport,
            trackLayout: trackLayout
        )
    }

    private func configureDropPreviewLayer() {
        dropPreviewLayer.opacity = 0
        dropPreviewLayer.isHidden = true
        dropPreviewLayer.cornerRadius = 12
        dropPreviewLayer.borderWidth = 1
        dropPreviewLayer.borderColor = NSColor.systemTeal.withAlphaComponent(0.72).cgColor
        dropPreviewLayer.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.10).cgColor
        dropPreviewLayer.shadowColor = NSColor.systemTeal.cgColor
        dropPreviewLayer.shadowOpacity = 0.24
        dropPreviewLayer.shadowRadius = 16
        dropPreviewLayer.shadowOffset = .zero
        dropPreviewLayer.masksToBounds = false

        dropPreviewAccentLayer.cornerRadius = 2
        dropPreviewAccentLayer.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.85).cgColor
        dropPreviewLayer.addSublayer(dropPreviewAccentLayer)

        dropPreviewTextLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        dropPreviewTextLayer.foregroundColor = NSColor.white.withAlphaComponent(0.94).cgColor
        dropPreviewTextLayer.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        dropPreviewTextLayer.fontSize = 13
        dropPreviewTextLayer.alignmentMode = .left
        dropPreviewTextLayer.truncationMode = .end
        dropPreviewLayer.addSublayer(dropPreviewTextLayer)

        layer?.addSublayer(dropPreviewLayer)
    }

    private func showDropPreview(for url: URL) {
        activeDropPreviewURL = url
        dropPreviewTextLayer.string = "Drop to create new track - \(url.deletingPathExtension().lastPathComponent)"
        dropPreviewLayer.isHidden = false
        updateDropPreviewLayout()

        dropPreviewLayer.removeAnimation(forKey: "fade")
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        dropPreviewLayer.opacity = 1
        CATransaction.commit()
    }

    private func hideDropPreview(fades: Bool) {
        activeDropPreviewURL = nil
        guard !dropPreviewLayer.isHidden else {
            return
        }

        dropPreviewLayer.removeAnimation(forKey: "fade")
        if fades {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.activeDropPreviewURL == nil else {
                    return
                }
                self.dropPreviewLayer.isHidden = true
            }
            dropPreviewLayer.opacity = 0
            CATransaction.commit()
        } else {
            dropPreviewLayer.opacity = 0
            dropPreviewLayer.isHidden = true
        }
    }

    private func updateDropPreviewLayout() {
        guard activeDropPreviewURL != nil, bounds.width > 0, bounds.height > 0 else {
            return
        }

        let resolvedLayout = trackLayout.resolved(
            totalTrackCount: currentTrackIDs.count + 1,
            viewportHeight: Float(max(bounds.height, 1))
        )
        let newTrackIndex = max(currentTrackIDs.count, 0)
        let laneFrame = resolvedLayout.laneFrame(forTrackIndex: newTrackIndex)
        let laneRect: CGRect
        if let laneFrame, laneFrame.isVisible {
            let topFromTop = CGFloat(laneFrame.clampedTop) * bounds.height
            let bottomFromTop = CGFloat(laneFrame.clampedBottom) * bounds.height
            laneRect = CGRect(
                x: 0,
                y: bounds.height - bottomFromTop,
                width: bounds.width,
                height: max(bottomFromTop - topFromTop, 1)
            )
        } else {
            let rulerHeight = CGFloat(min(max(resolvedLayout.rulerLaneHeight, 0), Float(bounds.height)))
            let trackAreaHeight = max(bounds.height - rulerHeight, 1)
            let previewHeight = min(CGFloat(resolvedLayout.trackHeight), trackAreaHeight)
            laneRect = CGRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: max(previewHeight, 64)
            )
        }

        let insetRect = laneRect.insetBy(dx: 8, dy: 8)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropPreviewLayer.frame = insetRect
        dropPreviewAccentLayer.frame = CGRect(
            x: 12,
            y: 12,
            width: 4,
            height: max(insetRect.height - 24, 12)
        )
        dropPreviewTextLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        dropPreviewTextLayer.frame = CGRect(
            x: 28,
            y: max((insetRect.height - 18) * 0.5, 0),
            width: max(insetRect.width - 44, 1),
            height: 20
        )
        CATransaction.commit()
    }

    private func updateTimelineRenderer(_ update: @escaping @Sendable (TimelineRenderer) -> Void) {
        guard let timelineRenderer else {
            return
        }

        timelineRenderQueue.async { [timelineRenderer] in
            update(timelineRenderer)
        }
    }

    private func updateTimelineRendererImmediately(_ update: @escaping @Sendable (TimelineRenderer) -> Void) {
        guard let timelineRenderer else {
            return
        }

        if DispatchQueue.getSpecific(key: Self.timelineRenderQueueSpecificKey) == true {
            update(timelineRenderer)
            return
        }

        timelineRenderQueue.sync { [timelineRenderer] in
            update(timelineRenderer)
        }
    }

    private func updatePreferredFrameRate() {
        preferredFramesPerSecond = targetFramesPerSecond
        PerformanceSampler.shared.updateTargetFramesPerSecond(targetFramesPerSecond)
        timelineDisplayLink?.updatePreferredFramesPerSecond(targetFramesPerSecond)
    }

    private func requestTimelineRender() {
        needsTimelineRender = true
        startTimelineDisplayLink()
    }

    @discardableResult
    func submitImmediateTimelineRenderForFirstPaint() -> Bool {
        guard timelineRenderer != nil else {
            return false
        }

        let drawableMetrics = currentTimelineDrawableMetricsForPrewarm()
        updateTimelineRendererImmediately { renderer in
            renderer.prepareFirstPaintWaveformShaderBuffers(
                drawableSize: drawableMetrics.viewportSize,
                backingScale: drawableMetrics.backingScale
            )
        }
        needsTimelineRender = true
        startTimelineDisplayLink()
        return true
    }

    private func requestCoalescedInteractionRender() {
        guard !needsTimelineRender else {
            return
        }

        requestTimelineRender()
    }

    private func requestRender(cadence: TimelineRenderCadence) {
        switch cadence {
        case .immediate:
            requestTimelineRender()
        case .coalescedInteraction:
            requestCoalescedInteractionRender()
        case .displayLinkPulse:
            startTimelineDisplayLink()
        case .none:
            break
        }
    }

    private func scheduleRenderDataPreparedRender() {
        guard window != nil, !isRenderDataPreparedRenderPending else {
            return
        }

        isRenderDataPreparedRenderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            isRenderDataPreparedRenderPending = false
            guard self.window != nil else {
                return
            }
            requestTimelineRender()
        }
    }

    private func configureDisplayLinkIfNeeded() {
        guard
            timelineDisplayLink == nil,
            metalDevice != nil,
            let timelineMetalLayer
        else {
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
        guard window != nil else {
            return
        }
        configureDisplayLinkIfNeeded()
        timelineDisplayLink?.start()
    }

    private func stopTimelineDisplayLinkIfIdle() {
        guard
            !needsTimelineRender,
            !isTimelinePlaybackActive,
            !isProcessingSelectionAnimationActive,
            !hasActiveTransientRenderPulse(),
            !hasActiveSelectionDragRenderPulse(),
            !isHotPathContractSmokeFrameStatsActive
        else {
            return
        }

        timelineDisplayLink?.stop()
        publishPerformanceRenderDemand()
    }

    private var isHotPathContractSmokeFrameStatsActive: Bool {
        hotPathContractSmokeFrameStatsEndTime.map { CACurrentMediaTime() <= $0 } == true
    }

    private var isTimelineGestureActive: Bool {
        activeDragMode != nil ||
            activeTranscriptDrag != nil ||
            isDraggingSelection ||
            isDraggingTrim ||
            isDraggingLoop ||
            scrollGestureMode != nil ||
            rightPanPreviousPoint != nil
    }

    private func invalidateTimelineCursorRects() {
        guard window != nil else {
            return
        }

        guard !isTimelineGestureActive else {
            pendingCursorRectInvalidation = true
            return
        }

        window?.invalidateCursorRects(for: self)
    }

    private func flushPendingCursorRectInvalidationIfNeeded() {
        guard pendingCursorRectInvalidation, window != nil else {
            return
        }

        pendingCursorRectInvalidation = false
        window?.invalidateCursorRects(for: self)
    }

    private func tearDownTimelineAnimation() {
        timelineDisplayLink?.invalidate()
        timelineDisplayLink = nil
        transientRenderEndTime = nil
        selectionDragRenderEndTime = nil
        isProcessingSelectionAnimationActive = false
        needsTimelineRender = false
        isTimelinePlaybackActive = false
        stopRightPanMomentum()
        stopZoomMomentum()
        PerformanceSampler.shared.updateRenderDemand(.idle)
    }

    private func displayLinkDidTick(_ frame: TimelineDisplayLinkFrame) {
        publishPerformanceRenderDemand()
        let shouldRender = needsTimelineRender ||
            isTimelinePlaybackActive ||
            isProcessingSelectionAnimationActive ||
            hasActiveTransientRenderPulse() ||
            hasActiveSelectionDragRenderPulse() ||
            isHotPathContractSmokeFrameStatsActive

        guard shouldRender else {
            timelineDisplayLink?.stop()
            PerformanceSampler.shared.updateRenderDemand(.idle)
            return
        }

        if refreshLiveSelectionFromCurrentMouse(sampledAt: CACurrentMediaTime()) {
            needsTimelineRender = true
        }

        if isTimelinePlaybackActive,
           let playheadProgress = projectedPagingPlayheadProgress(at: frame.targetPresentationTimestamp) {
            onPlaybackVisualProgressChanged?(playheadProgress)
            if !viewport.isFull {
                pageViewportIfNeeded(
                    forPlayheadProgress: playheadProgress,
                    renderCadence: .coalescedInteraction
                )
            }
        }

        let didSubmitRender = submitTimelineRender(frame: frame)
        if didSubmitRender {
            needsTimelineRender = false
            finishBootstrapWaveformHandoffAfterSubmittedFrame()
        }
        stopTimelineDisplayLinkIfIdle()
    }

    private func submitTimelineRender(frame: TimelineDisplayLinkFrame) -> Bool {
        guard renderFlightGate.begin() else {
            return false
        }

        guard let timelineRenderer else {
            renderFlightGate.finish()
            return false
        }

        guard let renderTarget = makeTimelineRenderTarget(frame: frame)?.withPublishesFrameStats(shouldPublishTimelineFrameStats()) else {
            renderFlightGate.finish()
            return false
        }

        latestSubmittedPresentationTimestamp = frame.targetPresentationTimestamp
        timelineRenderQueue.async { [weak self, timelineRenderer, renderTarget] in
            timelineRenderer.render(to: renderTarget)
            let submittedAt = CACurrentMediaTime()
            DispatchQueue.main.async { [weak self] in
                self?.finishPendingRenderSubmittedCallbacks(submittedAt: submittedAt)
            }
            self?.renderFlightGate.finish()
        }
        return true
    }

    private func finishBootstrapWaveformHandoffAfterSubmittedFrame() {
        guard isAwaitingFirstMetalFrame else {
            return
        }
        isAwaitingFirstMetalFrame = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / Double(targetFramesPerSecond)) { [weak self] in
            guard let self, !self.isAwaitingFirstMetalFrame else {
                return
            }
            self.bootstrapWaveformView.isHidden = true
        }
    }

    private func finishPendingRenderSubmittedCallbacks(submittedAt: CFTimeInterval) {
        guard !pendingRenderSubmittedCallbacks.isEmpty else {
            return
        }

        let callbacks = pendingRenderSubmittedCallbacks
        pendingRenderSubmittedCallbacks.removeAll(keepingCapacity: true)
        for callback in callbacks {
            callback(submittedAt)
        }
    }

    private func shouldPublishTimelineFrameStats() -> Bool {
        guard !inLiveResize else {
            return false
        }

        if let endTime = hotPathContractSmokeFrameStatsEndTime {
            if CACurrentMediaTime() <= endTime {
                return true
            }
            hotPathContractSmokeFrameStatsEndTime = nil
        }

        return isTimelinePlaybackActive ||
            isDraggingSelection ||
            isDraggingTrim ||
            activeDragMode != nil ||
            rightPanMomentumTimer != nil ||
            zoomMomentumTimer != nil ||
            scrollGestureMode != nil ||
            isProcessingSelectionAnimationActive ||
            hasActiveTransientRenderPulse() ||
            hasActiveSelectionDragRenderPulse()
    }

    private func publishPerformanceRenderDemand() {
        PerformanceSampler.shared.updateRenderDemand(currentPerformanceRenderDemand())
    }

    private func currentPerformanceRenderDemand() -> PerformanceRenderDemand {
        if isTimelinePlaybackActive {
            return .playback
        }

        if hotPathContractSmokeFrameStatsEndTime.map({ CACurrentMediaTime() <= $0 }) == true {
            return .interaction
        }

        if hasActiveSelectionDragRenderPulse() {
            return .interaction
        }

        if isDraggingSelection ||
            isDraggingTrim ||
            activeDragMode != nil ||
            rightPanMomentumTimer != nil ||
            zoomMomentumTimer != nil ||
            scrollGestureMode != nil
        {
            return .interaction
        }

        if isProcessingSelectionAnimationActive || hasActiveTransientRenderPulse() {
            return .animation
        }

        return .idle
    }

    private func kickInteractionRenderIfPossible() {
        timelineRenderer?.noteTimelineInteraction()
        requestTimelineRender()
    }

    private func kickInteractionRenderIfPossible(cadence: TimelineRenderCadence) {
        timelineRenderer?.noteTimelineInteraction()
        requestRender(cadence: cadence)
    }

    private func currentMousePointInTimeline() -> CGPoint? {
        guard let window else {
            return nil
        }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return convert(windowPoint, from: nil)
    }

    private func refreshLiveSelectionFromCurrentMouse(sampledAt timestamp: CFTimeInterval) -> Bool {
        guard
            isSelectionEnabled,
            activeDragMode == .selection,
            isDraggingSelection,
            let selectionAnchorProgress,
            let point = currentMousePointInTimeline()
        else {
            return false
        }

        let dragVelocity = updateSelectionDragVelocity(to: point, timestamp: timestamp)
        let dragProgress = preciseProgress(for: point)
        updateSelection(
            from: selectionAnchorProgress,
            to: dragProgress,
            notifyChange: false,
            liveLeadingProgress: dragProgress,
            liveVelocityPixelsPerSecond: dragVelocity.speed,
            liveDirection: dragVelocity.direction,
            liveTimestamp: timestamp,
            schedulesRender: false
        )
        return true
    }

    private func startTransientRenderPulse(duration: CFTimeInterval? = nil) {
        transientRenderEndTime = CFAbsoluteTimeGetCurrent() + (duration ?? transientRenderPulseDuration)
        startTimelineDisplayLink()
    }

    private func startSelectionDragRenderPulse(duration: CFTimeInterval? = nil) {
        selectionDragRenderEndTime = CFAbsoluteTimeGetCurrent() + (duration ?? selectionDragWaveformRenderPulseDuration)
        startTimelineDisplayLink()
    }

    private var selectionDragWaveformRenderPulseDuration: CFTimeInterval {
        max(selectionDragEffectRenderPulseDuration, selectionDragWaveformTuning.contactLifetime + 0.18)
    }

    private func projectedPagingPlayheadProgress(at timestamp: CFTimeInterval) -> Float? {
        guard isTimelinePlaybackActive, timelineDuration.isFinite, timelineDuration > 0 else {
            return nil
        }

        let elapsedTime = timestamp - pagingPlayheadAnchorTimestamp
        let projectedProgress = pagingPlayheadProgress + Float(elapsedTime / timelineDuration)
        return loopConstrainedPagingProgress(projectedProgress)
    }

    private func loopConstrainedPagingProgress(_ progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        guard isLoopRangeEnabled else {
            return clampedProgress
        }

        let start = loopRange.startProgress
        let end = loopRange.endProgress
        let duration = end - start
        guard duration > 0.0001, duration < 0.999, end > start else {
            return clampedProgress
        }

        guard clampedProgress > end else {
            return clampedProgress
        }

        let overflow = clampedProgress - end
        guard overflow > 0 else {
            return start
        }

        return start + overflow.truncatingRemainder(dividingBy: duration)
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

    private func hasActiveSelectionDragRenderPulse() -> Bool {
        guard let selectionDragRenderEndTime else {
            return false
        }

        if CFAbsoluteTimeGetCurrent() <= selectionDragRenderEndTime {
            return true
        }

        self.selectionDragRenderEndTime = nil
        return false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let fileURL = firstFileURL(from: sender.draggingPasteboard) else {
            return []
        }

        hasAcceptedCurrentDrag = false
        guard supportedAudioExtensions.contains(fileURL.pathExtension.lowercased()) else {
            return .copy
        }

        setDropHighlightVisible(true)
        showDropPreview(for: fileURL)
        onAudioFileDragEntered?(fileURL)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let fileURL = firstFileURL(from: sender.draggingPasteboard) else {
            return []
        }

        guard supportedAudioExtensions.contains(fileURL.pathExtension.lowercased()) else {
            return .copy
        }

        if activeDropPreviewURL != fileURL {
            showDropPreview(for: fileURL)
            onAudioFileDragEntered?(fileURL)
        } else {
            updateDropPreviewLayout()
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        let exitingURL = activeDropPreviewURL ?? sender.flatMap { firstSupportedAudioURL(from: $0.draggingPasteboard) }
        setDropHighlightVisible(false)
        hideDropPreview(fades: true)
        if let url = exitingURL {
            onAudioFileDragExited?(url)
        }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropHighlightVisible(false)
        hideDropPreview(fades: !hasAcceptedCurrentDrag)
        if !hasAcceptedCurrentDrag, let url = firstSupportedAudioURL(from: sender.draggingPasteboard) {
            onAudioFileDragExited?(url)
        }
        hasAcceptedCurrentDrag = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlightVisible(false)

        hasAcceptedCurrentDrag = true
        hideDropPreview(fades: false)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)

        if let url = firstSupportedAudioURL(from: sender.draggingPasteboard) {
            onAudioFileDropped?(url)
            return true
        }

        guard let unsupportedURL = firstFileURL(from: sender.draggingPasteboard) else {
            return false
        }

        onUnsupportedAudioFileDropped?(unsupportedURL)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard !isInteractionSuppressed else {
            return
        }

        if event.keyCode == 6, event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.shift) {
                onRedo?()
            } else {
                onUndo?()
            }
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
            event.charactersIgnoringModifiers?.lowercased() == "d",
            event.modifierFlags.contains(.command),
            !event.modifierFlags.contains(.shift)
        {
            onDuplicateRegionRequested?()
            return
        }

        if
            event.charactersIgnoringModifiers?.lowercased() == "b",
            event.modifierFlags.contains(.command)
        {
            onSplitAtPlayhead?()
            return
        }

        if
            event.charactersIgnoringModifiers?.lowercased() == "i",
            event.modifierFlags.contains(.command),
            event.modifierFlags.contains(.shift)
        {
            onImportAudioFileRequested?()
            return
        }

        if
            event.charactersIgnoringModifiers?.lowercased() == "i",
            event.modifierFlags.contains(.command),
            !event.modifierFlags.contains(.shift)
        {
            onInsertSilenceRequested?()
            return
        }

        if
            event.charactersIgnoringModifiers?.lowercased() == "j",
            event.modifierFlags.contains(.command)
        {
            zoomToSelection()
            return
        }

        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "]" {
            onNextDeadAirCandidateRequested?()
            return
        }

        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "[" {
            onPreviousDeadAirCandidateRequested?()
            return
        }

        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            if event.modifierFlags.contains(.shift) {
                onAcceptHighConfidenceDeadAirCandidatesRequested?()
            } else {
                onAcceptDeadAirCandidateRequested?()
            }
            return
        }

        if event.modifierFlags.contains(.option), event.keyCode == 123 {
            if event.modifierFlags.contains(.command) {
                onSlipClipContentsRequested?(-1)
                return
            }
            onNudgeSelectionRequested?(-1)
            return
        }

        if event.modifierFlags.contains(.option), event.keyCode == 124 {
            if event.modifierFlags.contains(.command) {
                onSlipClipContentsRequested?(1)
                return
            }
            onNudgeSelectionRequested?(1)
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

        if event.keyCode == 53 {
            displayTrimPreview(nil)
            displaySelection(nil)
            displayTranscriptSelection(nil)
            onSelectionChanged?(nil)
            onTranscriptSelectionChanged?(nil)
            onTimelineInteractionBegan?()
            activeDragMode = nil
            activeClipBoundaryHit = nil
            activeTranscriptDrag = nil
            isDraggingSelection = false
            isDraggingTrim = false
            isDraggingLoop = false
            flushPendingCursorRectInvalidationIfNeeded()
            return
        }

        if (event.keyCode == 51 || event.keyCode == 117), currentTranscriptSelection != nil {
            let kind: TranscriptEditCommandKind = event.modifierFlags.contains(.command) ?
                .clearWordsLeaveGap :
                .deleteWordsRipple
            onTranscriptEditCommandRequested?(TranscriptEditCommand(
                kind: kind,
                selection: currentTranscriptSelection
            ))
            return
        }

        if (event.keyCode == 51 || event.keyCode == 117), event.modifierFlags.contains(.command) {
            onClearSelection?()
            return
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            SoundtimeDiagnostics.shared.record(
                category: .edit,
                severity: .info,
                name: "timeline-delete-keydown",
                message: "TimelineView received a delete key event.",
                fields: [
                    "keyCode": "\(event.keyCode)",
                    "hasCommand": "\(event.modifierFlags.contains(.command))",
                    "canDeleteSelection": "\(canDeleteSelection)",
                    "isInteractionSuppressed": "\(isInteractionSuppressed)",
                ]
            )
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

        addTranscriptCursorRects()
        addLoopHandleCursorRects()
        addClipBoundaryCursorRects()
    }

    private func addTranscriptCursorRects() {
        guard isTranscriptLayerVisible else {
            return
        }

        let startedAt = CACurrentMediaTime()
        let cursorRects = transcriptOverlayView.transcriptCursorRects()
        for rect in cursorRects {
            guard rect.width > 1, rect.height > 1 else {
                continue
            }
            addCursorRect(rect, cursor: .iBeam)
        }
        transcriptOverlayView.recordCursorRectResetForDiagnostics(
            durationMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
            rectCount: cursorRects.count
        )
    }

    private func addLoopHandleCursorRects() {
        let rulerRect = rulerLaneRect()
        guard rulerRect.width > 0, rulerRect.height > 0 else {
            return
        }

        addCursorRect(rulerRect, cursor: .pointingHand)
        for endpoint in [TimelineLoopEndpoint.start, .end] {
            guard let rect = loopRegionEdgeHitRect(for: endpoint) else {
                continue
            }

            addCursorRect(rect, cursor: .resizeLeftRight)
        }
    }

    @objc func exportAudio(_ sender: Any?) {
        onExportRequested?()
    }

    @objc func importAudioFile(_ sender: Any?) {
        onImportAudioFileRequested?()
    }

    @objc func exportWAVAudio(_ sender: Any?) {
        onExportWAVRequested?()
    }

    @objc func exportSelectedRegion(_ sender: Any?) {
        onExportSelectedRegionRequested?()
    }

    @objc func exportMixdownAndStems(_ sender: Any?) {
        onExportMixdownAndStemsRequested?()
    }

    @objc func exportStems(_ sender: Any?) {
        onExportStemsRequested?()
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

    @objc func redoTimelineEdit(_ sender: Any?) {
        onRedo?()
    }

    @objc func cutTimelineSelection(_ sender: Any?) {
        onCutSelection?()
    }

    @objc func cut(_ sender: Any?) {
        cutTimelineSelection(sender)
    }

    @objc func copyTimelineSelection(_ sender: Any?) {
        onCopySelection?()
    }

    @objc func copy(_ sender: Any?) {
        copyTimelineSelection(sender)
    }

    @objc func pasteTimelineAudio(_ sender: Any?) {
        onPasteAudio?()
    }

    @objc func paste(_ sender: Any?) {
        pasteTimelineAudio(sender)
    }

    @objc func duplicateTimelineRegion(_ sender: Any?) {
        onDuplicateRegionRequested?()
    }

    @objc func deleteTimelineSelection(_ sender: Any?) {
        SoundtimeDiagnostics.shared.record(
            category: .edit,
            severity: .info,
            name: "timeline-delete-action",
            message: "TimelineView received the Delete Time menu/action command.",
            fields: [
                "canDeleteSelection": "\(canDeleteSelection)",
                "isInteractionSuppressed": "\(isInteractionSuppressed)",
            ]
        )
        onDeleteSelection?()
    }

    @objc func removeTimeRangeAcrossScope(_ sender: Any?) {
        onRemoveTimeRangeRequested?()
    }

    @objc func clearTimelineSelection(_ sender: Any?) {
        onClearSelection?()
    }

    @objc func splitAtPlayhead(_ sender: Any?) {
        onSplitAtPlayhead?()
    }

    @objc func insertSilenceAtPlayhead(_ sender: Any?) {
        onInsertSilenceRequested?()
    }

    @objc func healAdjacentClips(_ sender: Any?) {
        onHealAdjacentClipsRequested?()
    }

    @objc func nudgeSelectionLeft(_ sender: Any?) {
        onNudgeSelectionRequested?(-1)
    }

    @objc func nudgeSelectionRight(_ sender: Any?) {
        onNudgeSelectionRequested?(1)
    }

    @objc func slipClipContentsLeft(_ sender: Any?) {
        onSlipClipContentsRequested?(-1)
    }

    @objc func slipClipContentsRight(_ sender: Any?) {
        onSlipClipContentsRequested?(1)
    }

    @objc func snapSelectionToPlayheadEdgesOrSilence(_ sender: Any?) {
        onSnapSelectionRequested?()
    }

    @objc func selectTimeAcrossLinkedTracks(_ sender: Any?) {
        onSelectTimeAcrossLinkedTracksRequested?()
    }

    @objc func selectAllClipsOnTrack(_ sender: Any?) {
        onSelectAllClipsOnTrackRequested?()
    }

    @objc func zoomToSelection(_ sender: Any?) {
        zoomToSelection()
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

    @objc func denoiseTimelineSelection(_ sender: Any?) {
        onDenoiseRequested?()
    }

    @objc func separateMusicStemsTimelineSelection(_ sender: Any?) {
        onSeparateMusicStemsRequested?()
    }

    @objc func transcribeSelectedTrack(_ sender: Any?) {
        onTranscribeSelectedTrackRequested?()
    }

    @objc func toggleTranscriptLayer(_ sender: Any?) {
        onToggleTranscriptLayerRequested?()
    }

    @objc func toggleTranscriptAlignmentDebug(_ sender: Any?) {
        onToggleTranscriptAlignmentDebugRequested?()
    }

    @objc func deleteTranscriptText(_ sender: Any?) {
        guard let currentTranscriptSelection else {
            return
        }
        onTranscriptEditCommandRequested?(TranscriptEditCommand(
            kind: .deleteWordsRipple,
            selection: currentTranscriptSelection
        ))
    }

    @objc func clearTranscriptText(_ sender: Any?) {
        guard let currentTranscriptSelection else {
            return
        }
        onTranscriptEditCommandRequested?(TranscriptEditCommand(
            kind: .clearWordsLeaveGap,
            selection: currentTranscriptSelection
        ))
    }

    @objc func splitAtTranscriptWord(_ sender: Any?) {
        guard let currentTranscriptSelection else {
            return
        }
        onTranscriptEditCommandRequested?(TranscriptEditCommand(
            kind: .splitAtWordBoundary,
            selection: currentTranscriptSelection
        ))
    }

    @objc func deleteSilence(_ sender: Any?) {
        onDeleteSilenceRequested?()
    }

    @objc func acceptDeadAirCandidate(_ sender: Any?) {
        onAcceptDeadAirCandidateRequested?()
    }

    @objc func acceptHighConfidenceDeadAirCandidates(_ sender: Any?) {
        onAcceptHighConfidenceDeadAirCandidatesRequested?()
    }

    @objc func rejectDeadAirCandidate(_ sender: Any?) {
        onRejectDeadAirCandidateRequested?()
    }

    @objc func auditionDeadAirCandidate(_ sender: Any?) {
        onAuditionDeadAirCandidateRequested?()
    }

    @objc func nextDeadAirCandidate(_ sender: Any?) {
        onNextDeadAirCandidateRequested?()
    }

    @objc func previousDeadAirCandidate(_ sender: Any?) {
        onPreviousDeadAirCandidateRequested?()
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
        case #selector(denoiseTimelineSelection(_:)):
            return canApplyDenoiseEffect
        case #selector(separateMusicStemsTimelineSelection(_:)):
            return canApplyStemSeparationEffect
        case #selector(transcribeSelectedTrack(_:)):
            return canTranscribeSelectedTrack
        case #selector(toggleTranscriptLayer(_:)):
            menuItem.state = isTranscriptLayerVisible ? .on : .off
            return true
        case #selector(toggleTranscriptAlignmentDebug(_:)):
            menuItem.state = isTranscriptAlignmentDebugVisible ? .on : .off
            return isTranscriptLayerVisible
        case #selector(deleteTranscriptText(_:)),
             #selector(clearTranscriptText(_:)),
             #selector(splitAtTranscriptWord(_:)):
            return currentTranscriptSelection != nil
        case #selector(deleteSilence(_:)):
            return canDeleteSilence
        case #selector(acceptDeadAirCandidate(_:)),
             #selector(acceptHighConfidenceDeadAirCandidates(_:)),
             #selector(rejectDeadAirCandidate(_:)),
             #selector(auditionDeadAirCandidate(_:)),
             #selector(nextDeadAirCandidate(_:)),
             #selector(previousDeadAirCandidate(_:)):
            return canUseDeadAirCandidate
        case #selector(nudgeSelectionLeft(_:)),
             #selector(nudgeSelectionRight(_:)):
            return currentSelection?.durationProgress ?? 0 > 0
        case #selector(slipClipContentsLeft(_:)),
             #selector(slipClipContentsRight(_:)):
            return canSplitAtPlayhead
        case #selector(snapSelectionToPlayheadEdgesOrSilence(_:)):
            return currentSelection?.durationProgress ?? 0 > 0 || canUseDeadAirCandidate
        case #selector(selectTimeAcrossLinkedTracks(_:)):
            return currentSelection?.durationProgress ?? 0 > 0
        case #selector(selectAllClipsOnTrack(_:)):
            return canSplitAtPlayhead
        case #selector(reapplyLastEffect(_:)):
            return canReapplyLastEffect
        case #selector(exportSelectedRegion(_:)), #selector(exportSelectionFromContextMenu(_:)):
            return currentSelection?.durationProgress ?? 0 > 0
        case #selector(deleteTimelineSelection(_:)):
            return canDeleteSelection
        case #selector(removeTimeRangeAcrossScope(_:)):
            return canDeleteSelection
        case #selector(clearTimelineSelection(_:)):
            return canClearSelection
        case #selector(cutTimelineSelection(_:)), #selector(cut(_:)):
            return canCutSelection
        case #selector(copyTimelineSelection(_:)), #selector(copy(_:)):
            return canCopySelection
        case #selector(duplicateTimelineRegion(_:)):
            return canCopySelection
        case #selector(pasteTimelineAudio(_:)), #selector(paste(_:)):
            return canPasteAudio
        case #selector(splitAtPlayhead(_:)):
            return canSplitAtPlayhead
        case #selector(insertSilenceAtPlayhead(_:)):
            return canSplitAtPlayhead
        case #selector(healAdjacentClips(_:)):
            return canSplitAtPlayhead
        case #selector(zoomToSelection(_:)):
            return currentSelection?.durationProgress ?? 0 > 0
        case #selector(toggleDebugTools(_:)):
            menuItem.state = isDebugToolsVisible ? .on : .off
            return true
        default:
            return true
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isInteractionSuppressed else {
            return
        }

        PerformanceSampler.shared.recordTimelineInputEvent(kind: "mouse-entered", at: event.timestamp)
        if updateLoopHover(for: event) {
            return
        }
        if updateTranscriptHover(for: event) {
            return
        }
        updateHoverGuide(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isInteractionSuppressed else {
            return
        }

        PerformanceSampler.shared.recordTimelineInputEvent(kind: "mouse-moved", at: event.timestamp)
        if updateLoopHover(for: event) {
            return
        }
        if updateTranscriptHover(for: event) {
            return
        }
        updateHoverGuide(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isInteractionSuppressed else {
            return
        }

        PerformanceSampler.shared.recordTimelineInputEvent(kind: "mouse-exited", at: event.timestamp)
        displayHoverProgress(nil)
        displayHighlightedLoopEndpoint(nil)
        displayHighlightedLoopRegion(false)
        updateTranscriptHover(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !isInteractionSuppressed else {
            return
        }

        PerformanceSampler.shared.recordTimelineInputEvent(kind: "scroll", at: event.timestamp)
        guard isSelectionEnabled else {
            super.scrollWheel(with: event)
            return
        }

        displayHoverProgress(nil, renderCadence: .coalescedInteraction)
        let hasGesturePhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        let isGestureEnding =
            event.phase.contains(.ended) ||
            event.phase.contains(.cancelled) ||
            event.momentumPhase.contains(.ended) ||
            event.momentumPhase.contains(.cancelled)
        defer {
            if isGestureEnding || !hasGesturePhase {
                scrollGestureMode = nil
                flushPendingCursorRectInvalidationIfNeeded()
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
        setViewport(
            viewport.panned(byProgress: progressDelta),
            transcriptCadence: .coalescedInteraction,
            invalidatesCursorRects: false,
            renderCadence: .coalescedInteraction
        )
    }

    override func magnify(with event: NSEvent) {
        guard !isInteractionSuppressed else {
            return
        }

        PerformanceSampler.shared.recordTimelineInputEvent(kind: "magnify", at: event.timestamp)
        guard isSelectionEnabled else {
            super.magnify(with: event)
            return
        }

        displayHoverProgress(nil, renderCadence: .coalescedInteraction)
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
                flushPendingCursorRectInvalidationIfNeeded()
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
        guard !isInteractionSuppressed else {
            return
        }

        PerformanceSampler.shared.recordTimelineInputEvent(kind: "smart-magnify", at: event.timestamp)
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
        guard !isInteractionSuppressed else {
            return
        }

        PerformanceSampler.shared.recordTimelineInputEvent(kind: "mouse-down", at: event.timestamp)
        guard isSelectionEnabled else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        stopRightPanMomentum()
        stopZoomMomentum()
        onTimelineInteractionBegan?()
        clearLiveSelectionDragSnapshot()
        let point = currentDragPoint(for: event)
        let timelineProgress = progress(for: point)
        if let loopDragMode = loopDragMode(for: point) {
            displayHoverProgress(nil)
            if let endpoint = loopEndpoint(for: loopDragMode) {
                displayHighlightedLoopEndpoint(endpoint)
                let handleProgress = endpoint == .start ? loopRange.startProgress : loopRange.endProgress
                if let handleX = loopHandleX(forTimelineProgress: handleProgress) {
                    activeLoopDragOffsetX = point.x - handleX
                } else {
                    activeLoopDragOffsetX = 0
                }
            } else {
                activeLoopDragOffsetX = 0
                displayHighlightedLoopEndpoint(nil)
                displayHighlightedLoopRegion(loopRegionContains(point))
            }
            activeDragMode = loopDragMode
            selectionAnchorProgress = Double(progress(for: loopDragProgressPoint(from: point), followsVisualFisheye: false))
            selectionAnchorPoint = point
            selectionAnchorTrackID = nil
            activeClipBoundaryHit = nil
            isDraggingSelection = false
            isDraggingTrim = false
            isDraggingLoop = false
            return
        }
        activeLoopDragOffsetX = 0
        displayHighlightedLoopEndpoint(nil)
        displayHighlightedLoopRegion(false)

        if beginTranscriptInteraction(with: event, at: point) {
            return
        }

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
            isDraggingLoop = false
            onPlayFromProgress?(timelineProgress)
            return
        }

        if let trimDragMode = trimDragMode(for: point) {
            displayHoverProgress(nil)
            activeDragMode = trimDragMode
            selectionAnchorProgress = Double(progress(for: point, followsVisualFisheye: false))
            selectionAnchorPoint = point
            selectionAnchorTrackID = nil
            activeClipBoundaryHit = nil
            isDraggingSelection = false
            isDraggingTrim = false
            isDraggingLoop = false
            displaySelection(nil)
            onSelectionChanged?(nil)
            return
        }

        if let clipBoundaryHit = clipBoundaryHit(for: point) {
            displayHoverProgress(nil)
            activeDragMode = .clipBoundary
            activeClipBoundaryHit = clipBoundaryHit
            selectionAnchorProgress = Double(progress(for: point, followsVisualFisheye: false))
            selectionAnchorPoint = point
            selectionAnchorTrackID = clipBoundaryHit.trackID
            isDraggingSelection = false
            isDraggingTrim = false
            isDraggingLoop = false
            displaySelection(nil)
            onSelectionChanged?(nil)
            return
        }

        activeDragMode = .selection
        selectionAnchorProgress = preciseProgress(for: point)
        selectionAnchorPoint = point
        selectionAnchorTrackID = trackID(at: point)
        resetSelectionDragVelocity(at: point, timestamp: CACurrentMediaTime())
        activeClipBoundaryHit = nil
        isDraggingSelection = false
        isDraggingTrim = false
        isDraggingLoop = false
        displayHoverProgress(timelineProgress, isArmed: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isInteractionSuppressed else {
            return
        }

        PerformanceSampler.shared.recordTimelineInputEvent(kind: "mouse-dragged", at: event.timestamp)
        if let activeTranscriptDrag {
            updateTranscriptDrag(activeTranscriptDrag, with: currentDragPoint(for: event))
            return
        }

        guard
            isSelectionEnabled,
            let selectionAnchorProgress
        else {
            super.mouseDragged(with: event)
            return
        }

        let point = currentDragPoint(for: event)
        if activeDragMode == .loopStart || activeDragMode == .loopEnd || activeDragMode == .loopRegion {
            if activeDragMode != .loopRegion {
                displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            }
            if !isDraggingLoop, (activeDragMode == .loopRegion || didMovePastSelectionThreshold(to: point)) {
                isDraggingLoop = true
                if activeDragMode == .loopRegion {
                    setLoopRangeEnabled(true, notifyChange: true)
                    displayHighlightedLoopRegion(true, renderCadence: .coalescedInteraction)
                }
            }

            if let activeDragMode {
                let dragProgress = progress(for: loopDragProgressPoint(from: point), followsVisualFisheye: false)
                if activeDragMode == .loopRegion {
                    updateLoopRegionRange(
                        from: Float(selectionAnchorProgress),
                        to: dragProgress,
                        renderCadence: .coalescedInteraction,
                        invalidatesCursorRects: false
                    )
                    displayHoverProgress(dragProgress, isArmed: true, renderCadence: .coalescedInteraction)
                } else {
                    updateLoopRange(
                        for: activeDragMode,
                        progress: dragProgress,
                        renderCadence: .coalescedInteraction,
                        invalidatesCursorRects: false
                    )
                }
            }
            return
        }

        if activeDragMode == .trimStart || activeDragMode == .trimEnd {
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            if !isDraggingTrim, didMovePastSelectionThreshold(to: point) {
                isDraggingTrim = true
            }

            if isDraggingTrim, let activeDragMode {
                updateTrimPreview(
                    for: activeDragMode,
                    progress: progress(for: point, followsVisualFisheye: false),
                    renderCadence: .coalescedInteraction
                )
            }
            return
        }

        if activeDragMode == .clipBoundary {
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            if !isDraggingTrim, didMovePastSelectionThreshold(to: point) {
                isDraggingTrim = true
            }

            if isDraggingTrim, let activeClipBoundaryHit {
                updateClipBoundaryTrimPreview(
                    hit: activeClipBoundaryHit,
                    point: point,
                    renderCadence: .coalescedInteraction
                )
            }
            return
        }

        if !isDraggingSelection, didMovePastSelectionThreshold(to: point) {
            isDraggingSelection = true
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
        }

        if isDraggingSelection {
            let timestamp = CACurrentMediaTime()
            let dragVelocity = updateSelectionDragVelocity(to: point, timestamp: timestamp)
            let dragProgress = preciseProgress(for: point)
            updateSelection(
                from: selectionAnchorProgress,
                to: dragProgress,
                notifyChange: false,
                liveLeadingProgress: dragProgress,
                liveVelocityPixelsPerSecond: dragVelocity.speed,
                liveDirection: dragVelocity.direction,
                liveTimestamp: timestamp,
                schedulesRender: true
            )
        } else {
            displayHoverProgress(progress(for: point), isArmed: true, renderCadence: .coalescedInteraction)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !isInteractionSuppressed else {
            return
        }

        PerformanceSampler.shared.recordTimelineInputEvent(kind: "mouse-up", at: event.timestamp)
        if let activeTranscriptDrag {
            updateTranscriptDrag(activeTranscriptDrag, with: currentDragPoint(for: event), finishes: true)
            self.activeTranscriptDrag = nil
            if !updateTranscriptHover(for: event), !updateLoopHover(for: event) {
                updateHoverGuide(for: event)
            }
            flushPendingCursorRectInvalidationIfNeeded()
            return
        }

        guard
            isSelectionEnabled,
            let selectionAnchorProgress
        else {
            super.mouseUp(with: event)
            return
        }

        let point = currentDragPoint(for: event)
        let timelineProgress = progress(for: point)
        if activeDragMode == .loopStart || activeDragMode == .loopEnd || activeDragMode == .loopRegion {
            if let activeDragMode {
                let dragProgress = progress(for: loopDragProgressPoint(from: point), followsVisualFisheye: false)
                if activeDragMode == .loopRegion {
                    if isDraggingLoop {
                        updateLoopRegionRange(
                            from: Float(selectionAnchorProgress),
                            to: dragProgress
                        )
                    } else if loopRegionContains(point) {
                        setLoopRangeEnabled(!isLoopRangeEnabled, notifyChange: true)
                    } else {
                        onSeekRequested?(timelineProgress)
                    }
                    displayHoverProgress(nil)
                } else {
                    updateLoopRange(
                        for: activeDragMode,
                        progress: dragProgress
                    )
                }
            }
        } else if
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
        } else if activeDragMode == .clipBoundary, let activeClipBoundaryHit {
            displaySelection(nil)
            if isDraggingTrim {
                onClipBoundaryTrimRequested?(TimelineClipBoundaryTrim(
                    trackID: activeClipBoundaryHit.trackID,
                    clipRange: activeClipBoundaryHit.clipRange,
                    edge: activeClipBoundaryHit.edge,
                    targetProgress: constrainedClipBoundaryTarget(
                        for: activeClipBoundaryHit,
                        point: point
                    )
                ))
            }
        } else if isDraggingSelection {
            updateSelection(from: selectionAnchorProgress, to: preciseProgress(for: point), notifyChange: true)
            startSelectionDragRenderPulse(duration: selectionDragWaveformRenderPulseDuration)
        } else {
            displaySelection(nil)
            onSelectionChanged?(nil)
            onSeekRequested?(timelineProgress)
        }

        self.selectionAnchorProgress = nil
        selectionAnchorPoint = nil
        selectionAnchorTrackID = nil
        resetSelectionDragVelocity()
        activeClipBoundaryHit = nil
        activeDragMode = nil
        isDraggingSelection = false
        isDraggingTrim = false
        isDraggingLoop = false
        activeLoopDragOffsetX = 0
        flushPendingCursorRectInvalidationIfNeeded()
        if !updateLoopHover(for: event) {
            updateHoverGuide(for: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isInteractionSuppressed else {
            return
        }

        PerformanceSampler.shared.recordTimelineInputEvent(kind: "right-mouse-down", at: event.timestamp)
        guard isSelectionEnabled else {
            super.rightMouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if shouldShowSelectionContextMenu(at: point) {
            showSelectionContextMenu(with: event)
            return
        }

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
        isDraggingLoop = false
        displayHoverProgress(nil)
    }

    private func shouldShowSelectionContextMenu(at point: CGPoint) -> Bool {
        guard
            let selection = currentSelection,
            selection.durationProgress > 0
        else {
            return false
        }

        let progress = preciseProgress(for: point, followsVisualFisheye: false)
        guard progress >= selection.startProgress, progress <= selection.endProgress else {
            return false
        }

        guard let pointTrackID = trackID(at: point) else {
            return false
        }

        if let selectionTrackID = selection.trackID {
            return pointTrackID == selectionTrackID
        }
        return true
    }

    private func showSelectionContextMenu(with event: NSEvent) {
        let menu = NSMenu(title: "Selected Region")

        let exportItem = NSMenuItem(
            title: "Export Selected Region...",
            action: #selector(exportSelectionFromContextMenu(_:)),
            keyEquivalent: ""
        )
        exportItem.target = self
        menu.addItem(exportItem)
        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: "Copy", action: #selector(copyTimelineSelection(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let cutItem = NSMenuItem(title: "Cut", action: #selector(cutTimelineSelection(_:)), keyEquivalent: "")
        cutItem.target = self
        menu.addItem(cutItem)

        let deleteItem = NSMenuItem(title: "Delete Time", action: #selector(removeTimeRangeAcrossScope(_:)), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func exportSelectionFromContextMenu(_ sender: Any?) {
        onSelectionRegionContextExportRequested?()
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard !isInteractionSuppressed else {
            return
        }

        PerformanceSampler.shared.recordTimelineInputEvent(kind: "right-mouse-dragged", at: event.timestamp)
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
            setViewport(
                viewport.panned(byProgress: progressDelta),
                transcriptCadence: .coalescedInteraction,
                invalidatesCursorRects: false,
                renderCadence: .coalescedInteraction
            )
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
        guard !isInteractionSuppressed else {
            return
        }

        PerformanceSampler.shared.recordTimelineInputEvent(kind: "right-mouse-up", at: event.timestamp)
        guard isSelectionEnabled else {
            super.rightMouseUp(with: event)
            return
        }

        if let lastMovementTime = rightPanLastMovementTime {
            let idleTime = max(event.timestamp - lastMovementTime, 0)
            let decayWindow = min(idleTime, rightPanMomentumReleaseWindow)
            let decay = Float(exp(-rightPanStationaryDecayRate * decayWindow))
            rightPanVelocityProgressPerSecond *= decay
        } else {
            rightPanVelocityProgressPerSecond = 0
        }

        rightPanPreviousPoint = nil
        rightPanPreviousTime = nil
        rightPanLastMovementTime = nil
        flushPendingCursorRectInvalidationIfNeeded()
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

        setViewport(
            nextViewport,
            transcriptCadence: .coalescedInteraction,
            invalidatesCursorRects: false,
            renderCadence: .coalescedInteraction
        )
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
        setViewport(
            viewport.zoomed(by: exp(logScaleDelta), around: anchorProgress),
            transcriptCadence: .coalescedInteraction,
            invalidatesCursorRects: false,
            renderCadence: .coalescedInteraction
        )

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

        setViewport(
            nextViewport,
            transcriptCadence: .coalescedInteraction,
            invalidatesCursorRects: false,
            renderCadence: .coalescedInteraction
        )
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
        firstFileURLs(from: pasteboard).first { url in
            supportedAudioExtensions.contains(url.pathExtension.lowercased())
        }
    }

    private func firstFileURL(from pasteboard: NSPasteboard) -> URL? {
        firstFileURLs(from: pasteboard).first
    }

    private func firstFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]

        guard
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        else {
            return []
        }

        return urls
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
            SoundtimeFeatureFlags.waveformFisheye,
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

    private func setViewport(
        _ nextViewport: TimelineViewport,
        kicksImmediateRender: Bool = true,
        transcriptCadence: TimelineRenderCadence = .immediate,
        invalidatesCursorRects: Bool = true,
        renderCadence: TimelineRenderCadence = .immediate,
        marksInteraction: Bool = true
    ) {
        guard viewport != nextViewport else {
            return
        }

        viewport = nextViewport
        updateBootstrapWaveformView()
        onViewportChanged?(nextViewport)
        if marksInteraction {
            timelineRenderer?.publishInteractionViewport(nextViewport)
        }
        if transcriptCadence != .immediate {
            transcriptViewportRelayoutAllowedUntil = CACurrentMediaTime() + 0.18
        }
        updateTranscriptOverlay(cadence: transcriptCadence)
        if invalidatesCursorRects {
            invalidateTimelineCursorRects()
        }
        if kicksImmediateRender {
            if renderCadence == .immediate {
                updateTimelineRenderer { renderer in
                    renderer.commitViewport(nextViewport, marksInteraction: marksInteraction)
                }
            }
            kickInteractionRenderIfPossible(cadence: renderCadence)
        } else {
            updateTimelineRendererImmediately { renderer in
                renderer.displayViewport(nextViewport, marksInteraction: marksInteraction)
            }
            requestRender(cadence: renderCadence)
        }
    }

    private func zoomToSelection() {
        guard
            let selection = currentSelection,
            selection.durationProgress > 0
        else {
            return
        }

        focusSelection(selection)
    }

    func focusSelection(_ selection: TimelineSelection) {
        guard selection.durationProgress > 0 else {
            return
        }

        let selectionStart = Float(selection.startProgress)
        let selectionDuration = max(Float(selection.durationProgress), 0.000_001)
        let padding = max(selectionDuration * 0.14, 0.002)
        let nextViewport = TimelineViewport(
            startProgress: selectionStart - padding,
            durationProgress: min(selectionDuration + padding * 2, 1)
        )
        setViewport(
            nextViewport,
            transcriptCadence: .coalescedInteraction,
            invalidatesCursorRects: false,
            renderCadence: .coalescedInteraction
        )
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
        updateTimelineRendererImmediately { renderer in
            renderer.displayTrackLayout(nextTrackLayout)
        }
        updateTrackLayoutForCurrentBounds(requestRender: false)
        updateTranscriptOverlay()
        requestTimelineRender()
    }

    private func resolvedTrackLayoutForCurrentBounds() -> ResolvedTimelineTrackLayout {
        trackLayout.resolved(
            totalTrackCount: currentTrackIDs.count,
            viewportHeight: Float(max(bounds.height, 1))
        )
    }

    private func advanceTrackInsertionAnimation() {
        guard
            let trackInsertionAnimationStartTime,
            let trackInsertionAnimationIndex
        else {
            trackInsertionAnimationTimer?.invalidate()
            trackInsertionAnimationTimer = nil
            return
        }

        let elapsed = CACurrentMediaTime() - trackInsertionAnimationStartTime
        let rawProgress = Float(min(max(elapsed / trackInsertionAnimationDuration, 0), 1))
        let easedProgress = easeInOutCubic(rawProgress)
        if rawProgress >= 1 {
            stopTrackInsertionAnimation(clearsLayout: true)
            return
        }

        publishTrackLayout(
            trackLayout.insertingTrack(at: trackInsertionAnimationIndex, progress: easedProgress),
            requestRender: true
        )
    }

    private func stopTrackInsertionAnimation(clearsLayout: Bool) {
        trackInsertionAnimationTimer?.invalidate()
        trackInsertionAnimationTimer = nil
        trackInsertionAnimationStartTime = nil
        trackInsertionAnimationIndex = nil

        if clearsLayout {
            publishTrackLayout(trackLayout.clearingInsertionAnimation(), requestRender: true)
        }
    }

    private func publishTrackLayout(_ nextTrackLayout: TimelineTrackLayout, requestRender: Bool) {
        let clampedLayout = nextTrackLayout.clamped(
            totalTrackCount: currentTrackIDs.count,
            viewportHeight: Float(max(bounds.height, 1))
        )
        trackLayout = clampedLayout
        updateBootstrapWaveformView()
        let resolvedLayout = resolvedTrackLayoutForCurrentBounds()
        if lastPublishedTrackLayout != resolvedLayout {
            lastPublishedTrackLayout = resolvedLayout
            onTrackLaneLayoutChanged?(resolvedLayout)
        }
        if transcriptDisplayMode != .hidden {
            updateTranscriptOverlay()
        }
        updateTimelineRendererImmediately { renderer in
            renderer.displayTrackLayout(clampedLayout, marksInteraction: requestRender)
        }
        if requestRender {
            requestTimelineRender()
        }
    }

    private func easeInOutCubic(_ progress: Float) -> Float {
        let clamped = min(max(progress, 0), 1)
        if clamped < 0.5 {
            return 4 * clamped * clamped * clamped
        }

        let shifted = -2 * clamped + 2
        return 1 - (shifted * shifted * shifted) * 0.5
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
        updateTranscriptOverlay()

        guard layoutChanged else {
            return
        }

        updateTimelineRendererImmediately { renderer in
            renderer.displayTrackLayout(clampedLayout)
        }
        if requestRender {
            requestTimelineRender()
        }
    }

    private func updateTranscriptOverlay(cadence: TimelineRenderCadence = .immediate) {
        guard cadence != .immediate else {
            performTranscriptOverlayUpdate()
            return
        }

        guard isTranscriptLayerVisible else {
            performTranscriptOverlayUpdate()
            return
        }

        updateTranscriptOverlayLiveGeometry()
        if shouldRelayoutTranscriptOverlayForUncoveredViewport() {
            performTranscriptOverlayUpdate()
            return
        }

        let now = CACurrentMediaTime()
        let elapsed = now - lastTranscriptOverlayUpdateTime
        guard elapsed >= transcriptOverlayInteractionUpdateInterval else {
            scheduleTranscriptOverlayUpdate(after: transcriptOverlayInteractionUpdateInterval - elapsed)
            return
        }

        performTranscriptOverlayUpdate()
    }

    private func shouldRelayoutTranscriptOverlayForUncoveredViewport() -> Bool {
        guard
            !shouldDeferTranscriptOverlayLayoutForNonViewportHotPath,
            isTranscriptViewportRelayoutAllowed,
            transcriptOverlayView.requiresLayoutRebuild(
                tracks: currentRenderTracks,
                viewport: viewport,
                trackLayout: trackLayout,
                timelineDuration: timelineDuration,
                displayMode: transcriptDisplayMode
            )
        else {
            return false
        }

        return !transcriptOverlayView.canReuseLayoutForLiveGeometry(
            tracks: currentRenderTracks,
            viewport: viewport,
            trackLayout: trackLayout,
            timelineDuration: timelineDuration,
            displayMode: transcriptDisplayMode
        )
    }

    private func scheduleTranscriptOverlayUpdate(after delay: CFTimeInterval) {
        guard !pendingTranscriptOverlayUpdate else {
            return
        }

        pendingTranscriptOverlayUpdate = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0)) { [weak self] in
            guard let self else {
                return
            }

            pendingTranscriptOverlayUpdate = false
            performTranscriptOverlayUpdate()
        }
    }

    private func performTranscriptOverlayUpdate() {
        if transcriptOverlayView.requiresLayoutRebuild(
            tracks: currentRenderTracks,
            viewport: viewport,
            trackLayout: trackLayout,
            timelineDuration: timelineDuration,
            displayMode: transcriptDisplayMode
        ) {
            let canReuseLiveGeometry = transcriptOverlayView.canReuseLayoutForLiveGeometry(
               tracks: currentRenderTracks,
               viewport: viewport,
               trackLayout: trackLayout,
                timelineDuration: timelineDuration,
                displayMode: transcriptDisplayMode
            )
            if canReuseLiveGeometry {
                updateTranscriptOverlayLiveGeometry()
                return
            }
            if shouldDeferTranscriptOverlayLayoutForNonViewportHotPath ||
                (shouldDeferTranscriptOverlayLayoutForHotPath &&
                    !isTranscriptViewportRelayoutAllowed) {
                updateTranscriptOverlayLiveGeometry()
                scheduleTranscriptOverlayUpdate(after: transcriptOverlayHotPathDeferralInterval)
                return
            }
        }

        lastTranscriptOverlayUpdateTime = CACurrentMediaTime()
        let cursorRectsChanged = transcriptOverlayView.configure(
            tracks: currentRenderTracks,
            viewport: viewport,
            trackLayout: trackLayout,
            timelineDuration: timelineDuration,
            displayMode: transcriptDisplayMode,
            interactionState: transcriptInteractionState
        )
        if cursorRectsChanged {
            invalidateTimelineCursorRects()
        }
    }

    private func updateTranscriptOverlayLiveGeometry() {
        transcriptOverlayView.updateLiveGeometry(
            viewport: viewport,
            trackLayout: trackLayout,
            timelineDuration: timelineDuration,
            displayMode: transcriptDisplayMode
        )
    }

    private var shouldDeferTranscriptOverlayLayoutForHotPath: Bool {
        if isTimelinePlaybackActive ||
            isTimelineGestureActive ||
            isProcessingSelectionAnimationActive ||
            rightPanMomentumTimer != nil ||
            zoomMomentumTimer != nil ||
            scrollGestureMode != nil
        {
            return true
        }

        if hotPathContractSmokeFrameStatsEndTime.map({ CACurrentMediaTime() <= $0 }) == true {
            return true
        }

        return hasActiveTransientRenderPulse() || hasActiveSelectionDragRenderPulse()
    }

    private var shouldDeferTranscriptOverlayLayoutForNonViewportHotPath: Bool {
        isTimelinePlaybackActive ||
            isProcessingSelectionAnimationActive ||
            activeDragMode != nil ||
            activeTranscriptDrag != nil ||
            isDraggingSelection ||
            isDraggingTrim ||
            isDraggingLoop ||
            hasActiveTransientRenderPulse() ||
            hasActiveSelectionDragRenderPulse()
    }

    private var isTranscriptViewportRelayoutAllowed: Bool {
        let now = CACurrentMediaTime()
        if let allowedUntil = transcriptViewportRelayoutAllowedUntil {
            if now <= allowedUntil {
                return true
            }
            transcriptViewportRelayoutAllowedUntil = nil
        }

        return scrollGestureMode != nil ||
            rightPanMomentumTimer != nil ||
            zoomMomentumTimer != nil ||
            rightPanPreviousPoint != nil
    }

    private func pageViewportIfNeeded(
        forPlayheadProgress progress: Float,
        renderCadence: TimelineRenderCadence = .immediate
    ) {
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

        setViewport(
            nextViewport,
            transcriptCadence: renderCadence == .immediate ? .immediate : .coalescedInteraction,
            invalidatesCursorRects: renderCadence == .immediate,
            renderCadence: renderCadence
        )
    }

    private func updateHoverGuide(for event: NSEvent) {
        guard !isInteractionSuppressed else {
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopEndpoint(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopRegion(false, renderCadence: .coalescedInteraction)
            return
        }

        guard
            isSelectionEnabled,
            activeDragMode == nil
        else {
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopEndpoint(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopRegion(false, renderCadence: .coalescedInteraction)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopEndpoint(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopRegion(false, renderCadence: .coalescedInteraction)
            return
        }

        displayHoverProgress(progress(for: point), renderCadence: .coalescedInteraction)
    }

    private func updateTranscriptHover(for event: NSEvent) -> Bool {
        guard isTranscriptLayerVisible, activeDragMode == nil else {
            updateTranscriptHover(nil)
            return false
        }

        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), let hit = transcriptOverlayView.transcriptHit(at: point) else {
            updateTranscriptHover(nil)
            return false
        }

        updateTranscriptHover(hit)
        displayHoverProgress(nil, renderCadence: .coalescedInteraction)
        return true
    }

    private func updateTranscriptHover(_ hit: TranscriptInteractionHit?) {
        let nextState = TranscriptInteractionModel.state(
            previous: transcriptInteractionState,
            hover: hit
        )
        guard nextState != transcriptInteractionState else {
            return
        }

        transcriptInteractionState = nextState
        transcriptOverlayView.updateInteractionState(transcriptInteractionState)
    }

    private func beginTranscriptInteraction(with event: NSEvent, at point: CGPoint) -> Bool {
        guard
            isTranscriptLayerVisible,
            let hit = transcriptOverlayView.transcriptHit(at: point),
            let context = transcriptContext(for: hit.trackID),
            timelineDuration > 0
        else {
            updateTranscriptHover(nil)
            return false
        }

        window?.makeFirstResponder(self)
        onTimelineInteractionBegan?()
        displayHoverProgress(nil)
        displayHighlightedLoopEndpoint(nil)
        displayHighlightedLoopRegion(false)
        activeDragMode = nil
        activeClipBoundaryHit = nil
        selectionAnchorProgress = nil
        selectionAnchorPoint = nil
        selectionAnchorTrackID = hit.trackID
        isDraggingSelection = false
        isDraggingTrim = false
        isDraggingLoop = false

        let selection: TranscriptTokenSelection?
        if
            event.modifierFlags.contains(.shift),
            let currentTranscriptSelection
        {
            selection = TranscriptInteractionModel.selection(
                extending: currentTranscriptSelection,
                to: hit,
                transcript: context.transcript,
                timeMap: context.timeMap
            )
        } else {
            selection = TranscriptInteractionModel.selection(
                from: hit,
                transcript: context.transcript,
                timeMap: context.timeMap
            )
        }
        activeTranscriptDrag = TranscriptInteractionDrag(anchor: hit, current: hit)
        publishTranscriptSelection(selection, notifiesWorkspace: true)
        onSeekRequested?(progress(forProjectTime: hit.projectRange.startTime))
        return true
    }

    private func updateTranscriptDrag(
        _ drag: TranscriptInteractionDrag,
        with point: CGPoint,
        finishes: Bool = false
    ) {
        guard
            let hit = transcriptOverlayView.transcriptHit(at: point) ??
                transcriptOverlayView.nearestTranscriptHit(at: point, trackID: drag.anchor.trackID),
            let context = transcriptContext(for: drag.anchor.trackID)
        else {
            if finishes {
                onTranscriptSelectionChanged?(currentTranscriptSelection)
            }
            return
        }

        let nextDrag = TranscriptInteractionDrag(anchor: drag.anchor, current: hit)
        activeTranscriptDrag = finishes ? nil : nextDrag
        let selection = TranscriptInteractionModel.selection(
            from: drag.anchor,
            to: hit,
            visibleRuns: transcriptOverlayView.visibleRunsSnapshot(),
            transcript: context.transcript,
            timeMap: context.timeMap
        )
        publishTranscriptSelection(selection, notifiesWorkspace: finishes)
    }

    private func publishTranscriptSelection(
        _ selection: TranscriptTokenSelection?,
        notifiesWorkspace: Bool
    ) {
        let didChange = currentTranscriptSelection != selection
        if didChange {
            displayTranscriptSelection(selection)
            let timelineSelection = selection?.timelineSelection(timelineDuration: timelineDuration)
            if notifiesWorkspace {
                displaySelection(timelineSelection)
            } else {
                displayLiveTranscriptMirroredSelection(timelineSelection)
            }
        }
        if notifiesWorkspace {
            onTranscriptSelectionChanged?(selection)
        }
    }

    private func displayLiveTranscriptMirroredSelection(_ selection: TimelineSelection?) {
        currentSelection = selection
        clearLiveSelectionDragSnapshot(clearsSelection: false)
        timelineRenderer?.publishInteractionSelection(selection)
        kickInteractionRenderIfPossible()
    }

    private func transcriptContext(
        for trackID: UUID
    ) -> (track: TimelineRenderState.Track, transcript: TranscriptDocument, timeMap: TranscriptSourceTimeMap)? {
        guard
            let track = currentRenderTracks.first(where: { $0.id == trackID }),
            let transcript = track.transcript
        else {
            return nil
        }

        let timeMap = transcript.sourceTimeMap ?? TranscriptSourceTimeMap.fromRenderTrack(track)
        return (track, transcript, timeMap)
    }

    private func progress(forProjectTime projectTime: TimeInterval) -> Float {
        guard timelineDuration > 0 else {
            return 0
        }

        return Float(min(max(projectTime / timelineDuration, 0), 1))
    }

    private func updateLoopHover(for event: NSEvent) -> Bool {
        guard
            !isInteractionSuppressed,
            isSelectionEnabled,
            activeDragMode == nil
        else {
            displayHighlightedLoopEndpoint(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopRegion(false, renderCadence: .coalescedInteraction)
            return false
        }

        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            displayHighlightedLoopEndpoint(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopRegion(false, renderCadence: .coalescedInteraction)
            return false
        }

        guard rulerLaneRect().contains(point) else {
            displayHighlightedLoopEndpoint(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopRegion(false, renderCadence: .coalescedInteraction)
            return false
        }

        displayHoverProgress(nil, renderCadence: .coalescedInteraction)
        let hoveredEndpoint = loopRegionEndpointNear(point)
        displayHighlightedLoopEndpoint(hoveredEndpoint, renderCadence: .coalescedInteraction)
        displayHighlightedLoopRegion(loopRegionContains(point), renderCadence: .coalescedInteraction)
        return true
    }

    private func updateSelection(
        from startProgress: Double,
        to endProgress: Double,
        notifyChange: Bool,
        liveLeadingProgress: Double? = nil,
        liveVelocityPixelsPerSecond: CGFloat = 0,
        liveDirection: CGFloat = 0,
        liveTimestamp: CFTimeInterval = CACurrentMediaTime(),
        schedulesRender: Bool = true
    ) {
        let selection = TimelineSelection(
            startProgress: startProgress,
            endProgress: endProgress,
            trackID: selectionAnchorTrackID
        )
        let visibleSelection = selection.durationProgress > 0 ? selection : nil

        if notifyChange {
            displaySelection(visibleSelection)
            onSelectionChanged?(visibleSelection)
        } else {
            displayLiveSelection(
                visibleSelection,
                leadingProgress: liveLeadingProgress ?? endProgress,
                velocityPixelsPerSecond: liveVelocityPixelsPerSecond,
                direction: liveDirection,
                timestamp: liveTimestamp,
                schedulesRender: schedulesRender
            )
        }
    }

    private func resetSelectionDragVelocity(
        at point: CGPoint? = nil,
        timestamp: CFTimeInterval? = nil
    ) {
        selectionDragPreviousPoint = point
        selectionDragPreviousTimestamp = timestamp
        selectionDragVelocityPixelsPerSecond = 0
    }

    private func updateSelectionDragVelocity(
        to point: CGPoint,
        timestamp: CFTimeInterval
    ) -> (speed: CGFloat, direction: CGFloat) {
        guard
            let previousPoint = selectionDragPreviousPoint,
            let previousTimestamp = selectionDragPreviousTimestamp
        else {
            resetSelectionDragVelocity(at: point, timestamp: timestamp)
            return (0, 0)
        }

        let elapsed = min(
            max(timestamp - previousTimestamp, 0.000_1),
            selectionDragVelocityMaximumSampleInterval
        )
        let deltaX = point.x - previousPoint.x
        let instantaneousSpeed = abs(deltaX) / CGFloat(elapsed)
        let timeConstant = instantaneousSpeed > selectionDragVelocityPixelsPerSecond ?
            selectionDragVelocityRiseTimeConstant :
            selectionDragVelocityFallTimeConstant
        let alpha = 1 - exp(-elapsed / max(timeConstant, 0.000_1))
        selectionDragVelocityPixelsPerSecond +=
            (instantaneousSpeed - selectionDragVelocityPixelsPerSecond) * CGFloat(alpha)
        selectionDragPreviousPoint = point
        selectionDragPreviousTimestamp = timestamp

        let direction: CGFloat
        if abs(deltaX) > 0.1 {
            direction = deltaX > 0 ? 1 : -1
        } else {
            direction = 0
        }
        return (selectionDragVelocityPixelsPerSecond, direction)
    }

    private func updateTrimPreview(
        for dragMode: TimelineDragMode,
        progress: Float,
        renderCadence: TimelineRenderCadence = .immediate
    ) {
        displayTrimPreview(trimRange(for: dragMode, progress: progress), renderCadence: renderCadence)
    }

    private func trimRange(for dragMode: TimelineDragMode, progress: Float) -> TimelineTrimRange {
        switch dragMode {
        case .trimStart:
            TimelineTrimRange(startProgress: min(max(progress, 0), 0.999), endProgress: 1)
        case .trimEnd:
            TimelineTrimRange(startProgress: 0, endProgress: max(min(progress, 1), 0.001))
        case .selection, .clipBoundary, .loopStart, .loopEnd, .loopRegion:
            TimelineTrimRange(startProgress: 0, endProgress: 1)
        }
    }

    private func setLoopRangeEnabled(_ isEnabled: Bool, notifyChange: Bool) {
        guard isLoopRangeEnabled != isEnabled else {
            return
        }

        isLoopRangeEnabled = isEnabled
        updateTimelineRendererImmediately { renderer in
            renderer.displayLoopRangeEnabled(isEnabled)
        }
        if notifyChange {
            onLoopRangeEnabledChanged?(isEnabled)
        }
        requestTimelineRender()
    }

    private func updateLoopRegionRange(
        from anchorProgress: Float,
        to currentProgress: Float,
        renderCadence: TimelineRenderCadence = .immediate,
        invalidatesCursorRects: Bool = true
    ) {
        let minimumDuration = minimumLoopDurationProgress()
        let clampedAnchor = min(max(anchorProgress, 0), 1)
        let clampedCurrent = min(max(currentProgress, 0), 1)
        let nextRange: TimelineLoopRange
        if clampedCurrent >= clampedAnchor {
            nextRange = TimelineLoopRange(
                startProgress: clampedAnchor,
                endProgress: min(max(clampedCurrent, clampedAnchor + minimumDuration), 1)
            )
        } else {
            nextRange = TimelineLoopRange(
                startProgress: max(min(clampedCurrent, clampedAnchor - minimumDuration), 0),
                endProgress: clampedAnchor
            )
        }

        guard nextRange != loopRange else {
            return
        }

        loopRange = nextRange
        updateTimelineRendererImmediately { renderer in
            renderer.displayLoopRange(nextRange)
        }
        if invalidatesCursorRects {
            invalidateTimelineCursorRects()
        }
        onLoopRangeChanged?(nextRange)
        requestRender(cadence: renderCadence)
    }

    private func updateLoopRange(
        for dragMode: TimelineDragMode,
        progress: Float,
        renderCadence: TimelineRenderCadence = .immediate,
        invalidatesCursorRects: Bool = true
    ) {
        let minimumDuration = minimumLoopDurationProgress()
        let nextRange: TimelineLoopRange
        switch dragMode {
        case .loopStart:
            nextRange = loopRange.movingStart(to: progress, minimumDuration: minimumDuration)
        case .loopEnd:
            nextRange = loopRange.movingEnd(to: progress, minimumDuration: minimumDuration)
        case .loopRegion:
            return
        case .selection, .trimStart, .trimEnd, .clipBoundary:
            return
        }

        guard nextRange != loopRange else {
            return
        }

        loopRange = nextRange
        updateTimelineRendererImmediately { renderer in
            renderer.displayLoopRange(nextRange)
        }
        if invalidatesCursorRects {
            invalidateTimelineCursorRects()
        }
        onLoopRangeChanged?(nextRange)
        requestRender(cadence: renderCadence)
    }

    private func minimumLoopDurationProgress() -> Float {
        let pixelDuration = bounds.width > 0 ?
            viewport.durationProgress * Float(4 / bounds.width) :
            0.0001
        return max(pixelDuration, 0.0001)
    }

    private func trimDragMode(for point: CGPoint) -> TimelineDragMode? {
        return nil
    }

    private func loopDragMode(for point: CGPoint) -> TimelineDragMode? {
        guard
            bounds.width > 0,
            rulerLaneRect().contains(point)
        else {
            return nil
        }

        if let endpoint = loopRegionEndpointNear(point) {
            return endpoint == .start ? .loopStart : .loopEnd
        }

        return .loopRegion
    }

    private func legacyLoopEndpointDragMode(for point: CGPoint) -> TimelineDragMode? {
        guard
            bounds.width > 0,
            rulerLaneRect().contains(point)
        else {
            return nil
        }

        let candidates: [(mode: TimelineDragMode, endpoint: TimelineLoopEndpoint, x: CGFloat?)] = [
            (.loopStart, .start, loopHandleX(forTimelineProgress: loopRange.startProgress)),
            (.loopEnd, .end, loopHandleX(forTimelineProgress: loopRange.endProgress))
        ]
        var best: (mode: TimelineDragMode, distance: CGFloat)?
        for candidate in candidates {
            guard
                let x = candidate.x,
                let rect = loopFlagRect(for: candidate.endpoint),
                rect.contains(point)
            else {
                continue
            }

            let distance = abs(point.x - x)
            if best == nil || distance < best!.distance {
                best = (candidate.mode, distance)
            }
        }

        return best?.mode
    }

    private func loopEndpoint(for dragMode: TimelineDragMode) -> TimelineLoopEndpoint? {
        switch dragMode {
        case .loopStart:
            return .start
        case .loopEnd:
            return .end
        case .selection, .trimStart, .trimEnd, .clipBoundary, .loopRegion:
            return nil
        }
    }

    private func loopDragProgressPoint(from point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - activeLoopDragOffsetX, y: point.y)
    }

    private func loopRegionContains(_ point: CGPoint) -> Bool {
        guard
            rulerLaneRect().contains(point),
            loopRange.durationProgress < 0.999,
            let startX = loopHandleX(forTimelineProgress: loopRange.startProgress),
            let endX = loopHandleX(forTimelineProgress: loopRange.endProgress)
        else {
            return false
        }

        let left = min(startX, endX)
        let right = max(startX, endX)
        return point.x >= left && point.x <= right
    }

    private func loopRegionEndpointNear(_ point: CGPoint) -> TimelineLoopEndpoint? {
        guard
            rulerLaneRect().contains(point),
            loopRange.durationProgress < 0.999,
            let startX = loopHandleX(forTimelineProgress: loopRange.startProgress),
            let endX = loopHandleX(forTimelineProgress: loopRange.endProgress)
        else {
            return nil
        }

        let candidates: [(endpoint: TimelineLoopEndpoint, x: CGFloat)] = [
            (.start, min(startX, endX)),
            (.end, max(startX, endX))
        ]
        let hitWidth = max(loopRegionEdgeHitWidth, 1)
        var best: (endpoint: TimelineLoopEndpoint, distance: CGFloat)?
        for candidate in candidates {
            let distance = abs(point.x - candidate.x)
            guard distance <= hitWidth * 0.5 else {
                continue
            }

            if best == nil || distance < best!.distance {
                best = (candidate.endpoint, distance)
            }
        }

        return best?.endpoint
    }

    private func loopRegionEdgeHitRect(for endpoint: TimelineLoopEndpoint) -> NSRect? {
        let progress = endpoint == .start ? loopRange.startProgress : loopRange.endProgress
        guard
            loopRange.durationProgress < 0.999,
            let handleX = loopHandleX(forTimelineProgress: progress)
        else {
            return nil
        }

        let rulerRect = rulerLaneRect()
        guard rulerRect.width > 0, rulerRect.height > 0 else {
            return nil
        }

        let width = max(loopRegionEdgeHitWidth, 1)
        return NSRect(
            x: min(max(handleX - width * 0.5, 0), max(bounds.width - width, 0)),
            y: rulerRect.minY,
            width: min(width, bounds.width),
            height: rulerRect.height
        )
    }

    private func loopFlagRect(for endpoint: TimelineLoopEndpoint) -> NSRect? {
        let progress = endpoint == .start ? loopRange.startProgress : loopRange.endProgress
        guard
            let handleX = loopHandleX(forTimelineProgress: progress),
            bounds.width > 0
        else {
            return nil
        }

        let rulerRect = rulerLaneRect()
        guard rulerRect.width > 0, rulerRect.height > 0 else {
            return nil
        }

        let flagWidth = min(loopFlagWidth, max(bounds.width, 0))
        let flagHeight = min(loopFlagHeight, rulerRect.height)
        let flagLeft: CGFloat
        switch endpoint {
        case .start:
            flagLeft = min(max(handleX, 0), max(bounds.width - flagWidth, 0))
        case .end:
            let flagRight = max(min(handleX, bounds.width), flagWidth)
            flagLeft = min(max(flagRight - flagWidth, 0), max(bounds.width - flagWidth, 0))
        }

        return NSRect(
            x: flagLeft,
            y: max(rulerRect.maxY - flagHeight, rulerRect.minY),
            width: flagWidth,
            height: flagHeight
        )
    }

    private func trimHandleX(forTimelineProgress progress: Float) -> CGFloat? {
        loopHandleX(forTimelineProgress: progress)
    }

    private func loopHandleX(forTimelineProgress progress: Float) -> CGFloat? {
        let viewportProgress = viewport.viewportProgress(forTimelineProgress: progress)
        guard viewportProgress >= 0, viewportProgress <= 1 else {
            return nil
        }

        return CGFloat(viewportProgress) * bounds.width
    }

    private func rulerLaneRect() -> NSRect {
        let rulerHeight = CGFloat(resolvedTrackLayoutForCurrentBounds().rulerLaneHeight)
        guard rulerHeight > 0, bounds.height > 0 else {
            return .zero
        }

        return NSRect(
            x: 0,
            y: max(bounds.height - rulerHeight, 0),
            width: bounds.width,
            height: min(rulerHeight, bounds.height)
        )
    }

    private func addClipBoundaryCursorRects() {
        guard timelineDuration > 0, bounds.width > 0, bounds.height > 0 else {
            return
        }

        let layout = resolvedTrackLayoutForCurrentBounds()
        let trackByID = Dictionary(uniqueKeysWithValues: currentRenderTracks.map { ($0.id, $0) })
        for (trackIndex, trackID) in currentTrackIDs.enumerated() {
            guard
                let track = trackByID[trackID],
                let laneFrame = layout.laneFrame(forTrackIndex: trackIndex),
                laneFrame.isVisible
            else {
                continue
            }

            let laneTop = CGFloat(laneFrame.top) * bounds.height
            let laneBottom = CGFloat(laneFrame.bottom) * bounds.height
            let rectY = bounds.height - laneBottom
            let rectHeight = max(laneBottom - laneTop, 1)
            for boundaryProgress in clipBoundaryProjectProgresses(for: track) {
                guard let handleX = trimHandleX(forTimelineProgress: boundaryProgress) else {
                    continue
                }

                addCursorRect(
                    NSRect(
                        x: max(handleX - trimHandleHitWidth * 0.5, 0),
                        y: rectY,
                        width: min(trimHandleHitWidth, bounds.width),
                        height: rectHeight
                    ),
                    cursor: .resizeLeftRight
                )
            }
        }
    }

    private func clipBoundaryHit(for point: CGPoint) -> ClipBoundaryHit? {
        guard
            timelineDuration > 0,
            bounds.width > 0,
            let trackID = trackID(at: point),
            let track = currentRenderTracks.first(where: { $0.id == trackID })
        else {
            return nil
        }

        var bestHit: (hit: ClipBoundaryHit, distance: CGFloat)?
        for clipRange in track.clipRanges where clipRange.durationProgress > 0 {
            for edge in [TimelineClipBoundaryTrim.Edge.leading, .trailing] {
                let localProgress = edge == .leading ? clipRange.startProgress : clipRange.endProgress
                let projectProgress = projectProgress(forLocalProgress: localProgress, track: track)
                guard let handleX = trimHandleX(forTimelineProgress: projectProgress) else {
                    continue
                }

                let distance = abs(point.x - handleX)
                guard distance <= trimHandleHitWidth * 0.5 else {
                    continue
                }

                let hit = ClipBoundaryHit(
                    trackID: trackID,
                    clipRange: clipRange,
                    edge: edge
                )
                if bestHit == nil || distance < bestHit!.distance {
                    bestHit = (hit, distance)
                }
            }
        }

        return bestHit?.hit
    }

    private func clipBoundaryProjectProgresses(for track: TimelineRenderState.Track) -> [Float] {
        var keys = Set<Int>()
        var progresses: [Float] = []
        for clipRange in track.clipRanges {
            for localProgress in [clipRange.startProgress, clipRange.endProgress] {
                let projectProgress = projectProgress(forLocalProgress: localProgress, track: track)
                let key = Int((projectProgress * 1_000_000).rounded())
                guard keys.insert(key).inserted else {
                    continue
                }
                progresses.append(projectProgress)
            }
        }
        return progresses
    }

    private func projectProgress(
        forLocalProgress localProgress: Double,
        track: TimelineRenderState.Track
    ) -> Float {
        guard timelineDuration > 0, let trackDuration = track.durationHint, trackDuration > 0 else {
            return Float(localProgress)
        }

        let trackDurationProgress = min(max(trackDuration / timelineDuration, 0), 1)
        return Float(min(max(localProgress * trackDurationProgress, 0), 1))
    }

    private func localProgress(
        for point: CGPoint,
        trackID: UUID
    ) -> Double {
        let projectProgress = Double(progress(for: point, followsVisualFisheye: false))
        guard
            timelineDuration > 0,
            let track = currentRenderTracks.first(where: { $0.id == trackID }),
            let trackDuration = track.durationHint,
            trackDuration > 0
        else {
            return min(max(projectProgress, 0), 1)
        }

        let trackDurationProgress = min(max(trackDuration / timelineDuration, 0), 1)
        guard trackDurationProgress > 0 else {
            return 0
        }
        return min(max(projectProgress / trackDurationProgress, 0), 1)
    }

    private func constrainedClipBoundaryTarget(
        for hit: ClipBoundaryHit,
        point: CGPoint
    ) -> Double {
        let rawProgress = localProgress(for: point, trackID: hit.trackID)
        let minimumGap = max(hit.clipRange.durationProgress * 0.002, 0.000_001)
        switch hit.edge {
        case .leading:
            return min(max(rawProgress, hit.clipRange.startProgress + minimumGap), hit.clipRange.endProgress - minimumGap)
        case .trailing:
            return min(max(rawProgress, hit.clipRange.startProgress + minimumGap), hit.clipRange.endProgress - minimumGap)
        }
    }

    private func updateClipBoundaryTrimPreview(
        hit: ClipBoundaryHit,
        point: CGPoint,
        renderCadence: TimelineRenderCadence = .immediate
    ) {
        let targetProgress = constrainedClipBoundaryTarget(for: hit, point: point)
        let track = currentRenderTracks.first { $0.id == hit.trackID }
        let trackDurationProgress = track.map { Double(projectProgress(forLocalProgress: 1, track: $0)) } ?? 1
        let startProgress: Double
        let endProgress: Double
        switch hit.edge {
        case .leading:
            startProgress = hit.clipRange.startProgress * trackDurationProgress
            endProgress = targetProgress * trackDurationProgress
        case .trailing:
            startProgress = targetProgress * trackDurationProgress
            endProgress = hit.clipRange.endProgress * trackDurationProgress
        }

        let selection = TimelineSelection(
            startProgress: startProgress,
            endProgress: endProgress,
            trackID: hit.trackID
        )
        currentSelection = selection
        timelineRenderer?.publishInteractionSelection(selection)
        kickInteractionRenderIfPossible(cadence: renderCadence)
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
