import AppKit
import Metal
import SoundtimeEditing

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
    static let animationDuration: CFTimeInterval = 0.14
    static let lifetime: CFTimeInterval = 0.18

    let selection: TimelineSelection
    let sourceSelection: TimelineSelection?
}

enum TimelineAutomationTool: String, Sendable {
    case point
    case curve
    case pencil
    case ramp
    case eraser
}

struct TimelineAutomationDrawPresentationSample: Sendable {
    let id: UUID
    let frameProgress: Double
    let normalizedValue: Float

    init(
        id: UUID = UUID(),
        frameProgress: Double,
        normalizedValue: Float
    ) {
        self.id = id
        self.frameProgress = frameProgress
        self.normalizedValue = normalizedValue
    }
}

enum TimelineAutomationEditAction: Sendable {
    case add(pointID: UUID, frameProgress: Double, normalizedValue: Float)
    case remove(pointIDs: Set<UUID>)
    case move(
        pointIDs: Set<UUID>,
        anchorPointID: UUID,
        frameProgress: Double,
        normalizedValue: Float
    )
    case setCurve(leavingPointID: UUID, curve: Float)
    case setCurvePreset(pointIDs: Set<UUID>, preset: TimelineAutomationCurvePreset)
    case nudge(pointIDs: Set<UUID>, frameDelta: Int, normalizedValueDelta: Float)
    case setWriteMode(TimelineAutomationWriteMode)
    case clear
    case replaceRange(
        startProgress: Double,
        endProgress: Double,
        samples: [TimelineAutomationDrawPresentationSample]
    )
    case copy(pointIDs: Set<UUID>)
    case cut(pointIDs: Set<UUID>)
    case paste(frameProgress: Double)
}

struct TimelineAutomationEditRequest: Sendable {
    let trackID: UUID
    let parameterID: String
    let action: TimelineAutomationEditAction
}

private final class TimelineClipAccessibilityElement: NSAccessibilityElement {
    private let pressHandler: () -> Void

    init(pressHandler: @escaping () -> Void) {
        self.pressHandler = pressHandler
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func accessibilityPerformPress() -> Bool {
        pressHandler()
        return true
    }
}

private final class TimelineAutomationPointAccessibilityElement: NSAccessibilityElement {
    private let selectHandler: () -> Void
    private let adjustmentHandler: (Int, Float) -> Void

    init(
        selectHandler: @escaping () -> Void,
        adjustmentHandler: @escaping (Int, Float) -> Void
    ) {
        self.selectHandler = selectHandler
        self.adjustmentHandler = adjustmentHandler
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func accessibilityPerformPress() -> Bool {
        selectHandler()
        return true
    }

    override func accessibilityPerformIncrement() -> Bool {
        adjustmentHandler(0, 0.01)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        adjustmentHandler(0, -0.01)
        return true
    }
}

final class TimelineRenderFlightGate: @unchecked Sendable {
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

final class TimelineView: TimelineMetalLayerView, NSMenuItemValidation {
    private static let timelineRenderQueueSpecificKey = DispatchSpecificKey<Bool>()

    struct AudioDropTarget: Sendable {
        let trackID: UUID?
        let projectTime: TimeInterval
    }

    var onAudioFileDropped: ((URL, AudioDropTarget) -> Void)?
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
    var onSelectAdjacentClipRequested: ((Int, Bool) -> Void)?
    var onToggleSelectedClipMuteRequested: (() -> Void)?
    var onToggleSelectedClipLockRequested: (() -> Void)?
    var onGroupSelectedClipsRequested: (() -> Void)?
    var onUngroupSelectedClipsRequested: (() -> Void)?
    var onRepeatSelectedClipsRequested: (() -> Void)?
    var onCrossfadeSelectedClipsRequested: (() -> Void)?
    var onSnapSelectionRequested: (() -> Void)?
    var onSelectTimeAcrossLinkedTracksRequested: (() -> Void)?
    var onSelectAllClipsOnTrackRequested: (() -> Void)?
    var onSelectFollowingClipsRequested: (() -> Void)?
    var onSelectClipsInTimeSelectionRequested: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onExportRequested: (() -> Void)?
    var onSelectionRegionContextExportRequested: (() -> Void)?
    var onImportAudioFileRequested: (() -> Void)?
    var onRelinkMissingMediaRequested: (() -> Void)?
    var onCancelMissingMediaRelinkRequested: (() -> Void)?
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
    var onFrameStatsChanged: ((TimelineFrameStats) -> Void)?
    var onViewportChanged: ((TimelineViewport) -> Void)?
    var onNavigationPresentationChanged: (() -> Void)?
    var onTimelineInteractionBegan: (() -> Void)?
    var onNavigationScrollActivity: ((TimelineScrollbarAxis) -> Void)?
    var onTrackLaneLayoutChanged: ((ResolvedTimelineTrackLayout) -> Void)?
    var onTrackReorderCommitted: ((UUID, Int) -> Void)?
    var onLoopRangeChanged: ((TimelineLoopRange) -> Void)?
    var onLoopRangeEnabledChanged: ((Bool) -> Void)?
    var onTimelineEndChanged: ((TimeInterval) -> Void)?
    var onPlaybackVisualProgressChanged: ((Float) -> Void)?
    var onClipDoubleClicked: ((TimelineClipFocusRequest) -> Void)?
    var onClipSelected: ((TimelineClipFocusRequest?, TimelineClipSelectionIntent) -> Void)?
    var onClipMarqueeSelected: (([TimelineClipFocusRequest], TimelineClipSelectionIntent) -> Void)?
    var onClipDragCommitted: (([TimelineClipDragPreview], Bool) -> Void)?
    var onValidateClipDragPreviews: (([TimelineClipDragPreview]) -> Bool)?
    var onClipTrimmed: ((TimelineClipFocusRequest, TimelineClipEdge, Float) -> Void)?
    var onClipPropertiesChanged: ((TimelineClipFocusRequest, TimelineClipPropertyPreview) -> Void)?
    var onClipContextAction: ((TimelineClipFocusRequest, TimelineClipContextAction) -> Void)?
    var onCloseFocusedClipRequested: (() -> Void)?
    var onSplitFocusedClipRequested: (() -> Void)?
    var onTrimFocusedClipStartRequested: (() -> Void)?
    var onTrimFocusedClipEndRequested: (() -> Void)?
    var onMoveFocusedClipEarlierRequested: (() -> Void)?
    var onMoveFocusedClipLaterRequested: (() -> Void)?
    var onDuplicateFocusedClipRequested: (() -> Void)?
    var onRenameFocusedClipRequested: (() -> Void)?
    var onDeleteFocusedClipRequested: (() -> Void)?
    var onOpenSelectedClipInspectorRequested: (() -> Void)?
    var onMoveSelectedClipsAcrossTracksRequested: ((Int) -> Void)?
    var onAutomationEditRequested: ((TimelineAutomationEditRequest) -> Void)?
    var onToggleAutomationModeRequested: (() -> Void)?
    var onPointerPresenceChanged: ((Bool) -> Void)?
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
    var canUseFocusedClipCommands = false
    var canRelinkMissingMedia = false
    var clipCommandContext = TimelineClipCommandContext()
    private(set) var isClipSnappingEnabled = true
    var isDebugToolsVisible = false

    private enum TimelineDragMode {
        case seek
        case selection
        case resizeSelectionStart
        case resizeSelectionEnd
        case loopStart
        case loopEnd
        case loopRegion
        case moveLoopRegion
        case horizontalScrollbar
        case verticalScrollbar
        case timelineEnd
        case moveClip
        case trimClipStart
        case trimClipEnd
        case clipMarquee
        case clipFadeIn
        case clipFadeOut
        case automationPoint
        case automationCurve
        case automationMarquee
        case automationPencil
        case automationRamp
        case automationEraser
    }

    private struct AutomationHit {
        enum Kind: Equatable {
            case point(UUID)
            case segment(UUID)
            case fence(UUID?)
            case lane
        }

        let kind: Kind
        let trackID: UUID
        let parameterID: String
        let projectProgress: Double
        let normalizedValue: Float
        let points: [TimelineRenderState.Track.AutomationPoint]
        let initialCurve: Float
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
    private let clipLabelOverlayView = TimelineClipLabelOverlayView()
    private var clipAccessibilityElements: [NSAccessibilityElement] = []
    private var automationAccessibilityElements: [NSAccessibilityElement] = []
    private let clipMarqueeLayer = CAShapeLayer()
    private let automationMarqueeLayer = CAShapeLayer()
    private let transcriptOverlayView = TimelineTranscriptOverlayView()
    private let timelineEndOverlayView = TimelineEndOverlayView()
    private let leftOffscreenPlayheadButton = TimelineOffscreenPlayheadButton(direction: .left)
    private let rightOffscreenPlayheadButton = TimelineOffscreenPlayheadButton(direction: .right)
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
    private var settledViewport = TimelineViewport.full
    private var activeCameraTransition: TimelineCameraTransition?
    private var activeTrackScrollTransition: TimelineScalarTransition?
    private var pendingRestoredViewport: TimelineViewport?
    private var trackLayout = TimelineTrackLayout.default
    private var lastPublishedTrackLayout: ResolvedTimelineTrackLayout?
    private var isSelectionEnabled = false
    private var selectionAnchorProgress: Double?
    private var selectionAnchorPoint: CGPoint?
    private var selectionAnchorTrackID: UUID?
    private var currentSelection: TimelineSelection?
    private(set) var isAutomationModeVisible = false
    private(set) var automationTool = TimelineAutomationTool.point
    private var displayedAutomationParameterID = TimelineAutomationParameterID.volume.rawValue
    private var activeAutomationHit: AutomationHit?
    private var activeAutomationPoints: [TimelineRenderState.Track.AutomationPoint] = []
    private var activeAutomationDidDrag = false
    private var activeAutomationMouseDownModifierFlags: NSEvent.ModifierFlags = []
    private var automationSelection = TimelineAutomationSelection.empty
    private var automationMarqueeBaseSelection = TimelineAutomationSelection.empty
    private var activeAutomationDrawSamples: [TimelineAutomationDrawPresentationSample] = []
    private var activeAutomationErasedPointIDs = Set<UUID>()
    private var lastAutomationDrawPoint: CGPoint?

    var selectedRangeForEditing: TimelineSelection? {
        currentSelection
    }

    var automationParameterID: TimelineAutomationParameterID {
        TimelineAutomationParameterID(rawValue: displayedAutomationParameterID)
    }
    private var liveSelectionDragSnapshot: TimelineSelectionDragSnapshot?
    private var selectionDragPreviousPoint: CGPoint?
    private var selectionDragPreviousTimestamp: CFTimeInterval?
    private var selectionDragVelocityPixelsPerSecond: CGFloat = 0
    private var activeDragMode: TimelineDragMode?
    private var hoveredSelectionEndpoint: TimelineSelectionEndpoint?
    private var activeSelectionDragOffsetX: CGFloat = 0
    private var activeClipRequest: TimelineClipFocusRequest?
    private var activeClipRequests: [TimelineClipFocusRequest] = []
    private var activeClipDragOffsetProgress: Float = 0
    private var activeClipDragPreviews: [TimelineClipDragPreview] = []
    private var activeClipPlacementIsAllowed = true
    private var lastDisplayedClipPlacementIsAllowed = true
    private var activeClipPropertyPreview: TimelineClipPropertyPreview?
    private var activeClipPropertyControl: TimelineClipPropertyControl?
    private var activeClipDragDuplicates = false
    private var activeClipSnapGuideProgress: Float?
    private var activeClipSnapCandidates: [Float]?
    private var activeClipTrackIndices: [UUID: Int] = [:]
    private var hoveredClipRequest: TimelineClipFocusRequest?
    private var hoveredClipEdge: TimelineClipEdge?
    private var hoveredClipProperty: TimelineClipPropertyHover?
    private var armedClipContextRequest: TimelineClipFocusRequest?
    private var contextMenuClipRequest: TimelineClipFocusRequest?
    private var hoveredLoopEndpoint: TimelineLoopEndpoint?
    private var activeLoopDragOffsetX: CGFloat = 0
    private var activeLoopResizeFixedProgress: Float?
    private var activeLoopMoveInitialRange: TimelineLoopRange?
    private var activeScrollbarAxis: TimelineScrollbarAxis?
    private var activeScrollbarDragOffset: CGFloat = 0
    private var hoveredScrollbarAxis: TimelineScrollbarAxis?
    private var scrollbarPresentationAxis: TimelineScrollbarAxis?
    private var scrollbarHoverPresentation: Float = 0
    private var scrollbarHoverTarget: Float = 0
    private var scrollbarHoverTransitionStartTime = CACurrentMediaTime()
    private var scrollbarHoverTransitionSource: Float = 0
    private let scrollbarHoverTransitionDuration: CFTimeInterval = 0.06
    private var areEmbeddedScrollbarsEnabled = true
    private var trackReorderTrackID: UUID?
    private var trackReorderDraggedIndex: Int?
    private var trackReorderTargetIndex: Int?
    private var trackReorderPointerYFromTop: Float?
    private var trackReorderSourcePositions: [Float]?
    private var trackReorderTargetPositions: [Float]?
    private var trackReorderAnimationStartTime = CACurrentMediaTime()
    private let trackReorderAnimationDuration: CFTimeInterval = 0.14
    private var trackReorderLastTickTime = CACurrentMediaTime()
    private var isZoomControlInteractionActive = false
    private var edgeAutoPanLastTimestamp: CFTimeInterval?
    private var loopRange = TimelineLoopRange.default
    private var isLoopRangeEnabled = true
    private var isLoopPlaybackBypassed = false
    private var showsLoopMoveGuides = false
    private var isLoopRegionHovered = false
    private var hoverTrackingArea: NSTrackingArea?
    private var isInteractionSuppressed = false
    private var isDraggingSelection = false
    private var isDraggingLoop = false
    private var trackInsertionAnimationTimer: Timer?
    private var trackInsertionAnimationStartTime: CFTimeInterval?
    private var trackInsertionAnimationIndex: Int?
    private let trackInsertionAnimationDuration: CFTimeInterval = 0.22
    private var rightPanPreviousPoint: CGPoint?
    private var rightPanInitialPoint: CGPoint?
    private var rightPanPreviousTime: TimeInterval?
    private var rightPanLastMovementTime: TimeInterval?
    private var rightPanVelocityProgressPerSecond: Float = 0
    private var isRightPanGestureActive = false
    private var isSelectionContextMenuArmed = false
    private var rightPanMomentumTimer: Timer?
    private var rightPanMomentumLastTime: TimeInterval?
    private var trackpadPanVelocityProgressPerSecond: Float = 0
    private var trackpadPanPreviousTime: TimeInterval?
    private var zoomMomentumAnchorProgress: Float?
    private var zoomPreviousTime: TimeInterval?
    private var zoomLastInputTime: TimeInterval?
    private var zoomVelocityLogScalePerSecond: Float = 0
    private var zoomMomentumTimer: Timer?
    private var zoomMomentumLastTime: TimeInterval?
    private var scrollGestureMode: ScrollGestureMode?
    private var suppressesNavigationGestureForSelectionFocus = false
    private var timelineDisplayLink: TimelineDisplayLink?
    private var transientRenderEndTime: CFTimeInterval?
    private var selectionDragRenderEndTime: CFTimeInterval?
    private var isProcessingSelectionAnimationActive = false
    private var needsTimelineRender = false
    private var timelineRenderRequestGeneration: UInt64 = 0
    private var pendingRenderSubmittedCallbacks: [(CFTimeInterval) -> Void] = []
    private let renderFlightGate = TimelineRenderFlightGate()
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
    private var contentDuration: TimeInterval = 0
    private var timelineEndTime: TimeInterval?
    private var isTranscriptLayerVisible = false
    private var transcriptDisplayMode = TranscriptTimelineDisplayMode.hidden
    private var presentationPlayheadProgress: Float = 0
    private var presentationPlayheadAnchorTimestamp = CACurrentMediaTime()
    private var latestSubmittedPresentationTimestamp = CACurrentMediaTime()
    private let selectionDragThreshold: CGFloat = 0.01
    private let selectionDragVelocityRiseTimeConstant: CFTimeInterval = 0.055
    private let selectionDragVelocityFallTimeConstant: CFTimeInterval = 0.18
    private let selectionDragVelocityMaximumSampleInterval: CFTimeInterval = 1.0 / 30.0
    private let selectionEdgeHitWidth: CGFloat = 24
    private let retainedSelectionEdgeHitWidth: CGFloat = 32
    private let loopFlagWidth: CGFloat = 18
    private let loopFlagHeight: CGFloat = 18
    private let loopRegionEdgeHitWidth: CGFloat = 14
    private let edgeAutoPanActivationDistance: CGFloat = 84
    private let edgeAutoPanMaximumViewportWidthsPerSecond: Float = 0.9
    private let edgeAutoPanMaximumFrameInterval: CFTimeInterval = 1.0 / 20.0
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
        updateTimelineRenderer(requestsRenderAfterUpdate: true) { renderer in
            renderer.displayWaveform(waveformOverview)
        }
        if wasSelectionEnabled != isSelectionEnabled {
            invalidateTimelineCursorRects()
        }

        startTransientRenderPulse(duration: waveformTransitionRenderPulseDuration)

        if !isSelectionEnabled {
            selectionAnchorProgress = nil
            selectionAnchorPoint = nil
            selectionAnchorTrackID = nil
            activeDragMode = nil
            activeSelectionDragOffsetX = 0
            isDraggingSelection = false
            isDraggingLoop = false
            activeLoopResizeFixedProgress = nil
            edgeAutoPanLastTimestamp = nil
            resetRightPanGestureState()
            stopRightPanMomentum()
            stopZoomMomentum()
            displaySelection(nil)
            displayHoverProgress(nil)
            onSelectionChanged?(nil)
        }
        updateOffscreenPlayheadButtons()
    }

    func displayTracks(
        _ tracks: [TimelineRenderState.Track],
        animateWaveformTransition: Bool = true,
        allowImmediateWaveformPrewarm: Bool = true,
        allowImmediateInteractiveWaveformPrewarm: Bool = true,
        updatesRendererImmediately: Bool = false,
        viewportTransition: TimelineViewportTransitionPolicy = .immediate,
        completesDeletionHandoff: Bool = false
    ) {
        let previousTimelineDuration = timelineDuration
        let previousViewport = viewport
        let previousSettledViewport = settledViewport
        let sourceCamera = TimelineCameraWindow(
            viewport: previousViewport,
            projectDuration: previousTimelineDuration
        )
        activeCameraTransition = nil
        activeTrackScrollTransition = nil
        currentTrackIDs = tracks.map(\.id)
        currentRenderTracks = tracks
        contentDuration = Self.timelineDuration(for: tracks)
        let nextTimelineDuration = max(contentDuration, timelineEndTime ?? contentDuration)
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
            let targetViewport = previousSettledViewport.isFull ?
                TimelineViewport.full :
                previousSettledViewport.preservingAbsoluteTimes(
                    previousDuration: previousTimelineDuration,
                    nextDuration: nextTimelineDuration
                )
            if viewportTransition == .animatedEditReframe {
                beginCameraTransition(
                    from: sourceCamera,
                    to: targetViewport,
                    projectDuration: nextTimelineDuration
                )
            } else {
                setViewport(targetViewport, kicksImmediateRender: false, marksInteraction: false)
            }
        }
        if let pendingRestoredViewport, isSelectionEnabled {
            self.pendingRestoredViewport = nil
            setViewport(pendingRestoredViewport, kicksImmediateRender: false, marksInteraction: false)
        }
        updateTrackLayoutForCurrentBounds(requestRender: false)
        if completesDeletionHandoff {
            clipLabelOverlayView.clearDeletionEffects()
        }
        updateClipLabelOverlay()
        let drawableMetrics = currentTimelineDrawableMetricsForPrewarm()
        updateBootstrapWaveformView()
        let rendererUpdate: @Sendable (TimelineRenderer) -> Void = { renderer in
            if completesDeletionHandoff {
                renderer.clearDeletionEffects()
            }
            renderer.updatePrewarmViewportSize(
                drawableMetrics.viewportSize,
                backingScale: drawableMetrics.backingScale
            )
            renderer.displayTracks(
                tracks,
                animateWaveformTransition: animateWaveformTransition,
                allowImmediateWaveformPrewarm: allowImmediateWaveformPrewarm,
                allowImmediateInteractiveWaveformPrewarm: allowImmediateInteractiveWaveformPrewarm,
                projectDuration: nextTimelineDuration
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
            updateTimelineRenderer(requestsRenderAfterUpdate: true, rendererUpdate)
        }
        requestTimelineRender()
        if wasSelectionEnabled != isSelectionEnabled {
            invalidateTimelineCursorRects()
        }

        if animateWaveformTransition {
            startTransientRenderPulse(duration: waveformTransitionRenderPulseDuration)
        }
        updateTimelineEndOverlay()

        if !isSelectionEnabled {
            selectionAnchorProgress = nil
            selectionAnchorPoint = nil
            selectionAnchorTrackID = nil
            activeDragMode = nil
            activeSelectionDragOffsetX = 0
            isDraggingSelection = false
            isDraggingLoop = false
            activeLoopResizeFixedProgress = nil
            edgeAutoPanLastTimestamp = nil
            resetRightPanGestureState()
            stopRightPanMomentum()
            stopZoomMomentum()
            displaySelection(nil)
            displayHoverProgress(nil)
            onSelectionChanged?(nil)
        }
        updateOffscreenPlayheadButtons()
    }

    func beginLiveRecordingWaveform(layerID: UUID) {
        updateTimelineRendererImmediately { renderer in
            renderer.beginLiveRecordingWaveform(layerID: layerID)
        }
    }

    @discardableResult
    func publishLiveRecordingWaveform(_ publication: LiveRecordingWaveformPublication) -> Bool {
        guard timelineRenderer != nil else { return false }
        updateTimelineRenderer(requestsRenderAfterUpdate: true) { renderer in
            renderer.publishLiveRecordingWaveform(publication)
        }
        return true
    }

    func promoteLiveRecordingWaveform(
        layerID: UUID,
        toStaticLayerID staticLayerID: UUID,
        waveformVersion: Int,
        overview: WaveformOverview
    ) {
        updateTimelineRendererImmediately { renderer in
            renderer.promoteLiveRecordingWaveform(
                layerID: layerID,
                toStaticLayerID: staticLayerID,
                waveformVersion: waveformVersion,
                overview: overview
            )
        }
    }

    func endLiveRecordingWaveform(layerID: UUID) {
        updateTimelineRendererImmediately { renderer in
            renderer.endLiveRecordingWaveform(layerID: layerID)
        }
    }

    func displayTimelineEnd(_ endTime: TimeInterval?) {
        let sanitized = endTime.flatMap { value in
            value.isFinite ? max(value, 0) : nil
        }
        timelineEndTime = sanitized
        let nextDuration = max(contentDuration, sanitized ?? contentDuration)
        if nextDuration != timelineDuration {
            let previousDuration = timelineDuration
            timelineDuration = nextDuration
            if previousDuration > 0, nextDuration > 0, !settledViewport.isFull {
                setViewport(
                    settledViewport.preservingAbsoluteTimes(
                        previousDuration: previousDuration,
                        nextDuration: nextDuration
                    ),
                    kicksImmediateRender: false,
                    marksInteraction: false
                )
            }
            updateTimelineRendererImmediately { renderer in
                renderer.displayProjectDuration(nextDuration)
            }
        }
        updateTimelineEndOverlay()
        invalidateTimelineCursorRects()
        requestTimelineRender()
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
        settledViewport
    }

    var currentTimelineDuration: TimeInterval {
        timelineDuration
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
        let mixesByID = Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.id, ProjectPlaybackTrackMix(
                id: $0.id,
                volume: $0.volume,
                isMuted: $0.isMuted,
                isSoloed: $0.isSoloed
            ))
        })
        let mergedTracks = currentRenderTracks.map { track in
            guard let mix = mixesByID[track.id] else {
                return track
            }
            return track.applying(mix)
        }
        guard !mergedTracks.isEmpty else {
            return
        }
        currentTrackIDs = mergedTracks.map(\.id)
        currentRenderTracks = mergedTracks
        contentDuration = Self.timelineDuration(for: mergedTracks)
        timelineDuration = max(contentDuration, timelineEndTime ?? contentDuration)
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
        presentationPlayheadProgress = clampedProgress
        presentationPlayheadAnchorTimestamp = anchorTimestamp ?? CACurrentMediaTime()
        updateOffscreenPlayheadButtons(playheadProgress: clampedProgress)
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
        updateOffscreenPlayheadButtons()
    }

    func displayRecordingActive(_ isActive: Bool) {
        updateTimelineRendererImmediately { renderer in
            renderer.displayRecordingActive(isActive)
        }
        requestTimelineRender()
    }

    func displaySelection(_ selection: TimelineSelection?, marksInteraction: Bool = true) {
        let selectionChanged = currentSelection != selection
        currentSelection = selection
        liveSelectionDragSnapshot = nil
        if selection == nil {
            clearLiveSelectionDragSnapshot(clearsSelection: true)
            displayHighlightedSelectionEndpoint(nil)
        }
        updateTimelineRendererImmediately { renderer in
            renderer.displaySelection(selection, marksInteraction: marksInteraction)
        }
        if selectionChanged {
            invalidateTimelineCursorRects()
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

    func triggerClipShines(_ clips: [TimelineClipReference]) {
        guard !clips.isEmpty else { return }
        let timestamp = CACurrentMediaTime()
        updateTimelineRendererImmediately { renderer in
            for clip in clips {
                renderer.triggerClipShine(
                    trackID: clip.trackID,
                    clipID: clip.clipID,
                    at: timestamp
                )
            }
        }
        requestTimelineRender()
        startTransientRenderPulse(duration: 0.46)
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
            selectionAnchorProgress = nil
            selectionAnchorPoint = nil
            selectionAnchorTrackID = nil
            clearLiveSelectionDragSnapshot()
            isDraggingSelection = false
            isDraggingLoop = false
            let committedLoopRange = loopRange
            updateTimelineRendererImmediately { renderer in
                renderer.displayLoopRange(committedLoopRange)
            }
            activeTranscriptDrag = nil
            activeSelectionDragOffsetX = 0
            activeLoopDragOffsetX = 0
            activeLoopResizeFixedProgress = nil
            activeLoopMoveInitialRange = nil
            edgeAutoPanLastTimestamp = nil
            displayHoverProgress(nil)
            displayLoopMoveGuides(false)
            displayHighlightedSelectionEndpoint(nil)
            displayHighlightedLoopEndpoint(nil)
            displayHighlightedLoopRegion(false)
            resetRightPanGestureState()
            stopRightPanMomentum()
            stopZoomMomentum()
            scrollGestureMode = nil
            flushPendingCursorRectInvalidationIfNeeded()
        }
        updateOffscreenPlayheadButtons()
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

    func hotPathContractSmokeWaveformBuffersAreSettled() -> Bool {
        guard let timelineRenderer else {
            return false
        }
        let drawableMetrics = currentTimelineDrawableMetricsForPrewarm()
        return timelineRenderer.waveformShaderBuffersAreSettledForSmokeTesting(
            drawableSize: drawableMetrics.viewportSize
        )
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
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.008))
        }
        requestTimelineRender()
        return submissionMilliseconds
    }

    func visualInvariantSmokePanAndSelectRange(
        trackID: UUID,
        viewport: TimelineViewport,
        startViewportProgress: Double,
        endViewportProgress: Double,
        viewportAfterSelection: TimelineViewport? = nil,
        stagedZoomMomentumVelocity: Float? = nil
    ) -> TimelineSelection? {
        guard
            let trackIndex = currentTrackIDs.firstIndex(of: trackID),
            bounds.width > 0,
            bounds.height > 0,
            let laneFrame = resolvedTrackLayoutForCurrentBounds().laneFrame(forTrackIndex: trackIndex)
        else {
            return nil
        }

        setViewport(
            viewport,
            transcriptCadence: .coalescedInteraction,
            invalidatesCursorRects: false,
            renderCadence: .coalescedInteraction
        )

        let yFromTop = (CGFloat(laneFrame.clampedTop) + CGFloat(laneFrame.clampedBottom)) *
            bounds.height * 0.5
        let y = bounds.height - yFromTop
        let startPoint = CGPoint(
            x: min(max(startViewportProgress, 0), 1) * bounds.width,
            y: y
        )
        let endPoint = CGPoint(
            x: min(max(endViewportProgress, 0), 1) * bounds.width,
            y: y
        )
        selectionAnchorTrackID = trackID
        let startProgress = preciseProgress(for: startPoint)
        let endProgress = preciseProgress(for: endPoint)
        updateSelection(
            from: startProgress,
            to: endProgress,
            notifyChange: true
        )
        selectionAnchorTrackID = nil
        if let viewportAfterSelection {
            setViewport(
                viewportAfterSelection,
                transcriptCadence: .coalescedInteraction,
                invalidatesCursorRects: false,
                renderCadence: .coalescedInteraction
            )
        }
        if let stagedZoomMomentumVelocity {
            stopZoomMomentum()
            zoomMomentumAnchorProgress = 0.5
            zoomVelocityLogScalePerSecond = stagedZoomMomentumVelocity
            zoomMomentumLastTime = CFAbsoluteTimeGetCurrent() - (1 / 120)
        }
        return currentSelection
    }

    func visualInvariantSmokeAdvancePendingZoomMomentum() -> Bool {
        let previousViewport = viewport
        stepZoomMomentum()
        return viewport != previousViewport
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

    func displayLoopPlaybackBypassed(_ isBypassed: Bool) {
        guard isLoopPlaybackBypassed != isBypassed else {
            return
        }

        isLoopPlaybackBypassed = isBypassed
        updateTimelineRendererImmediately { renderer in
            renderer.displayLoopPlaybackBypassed(isBypassed)
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

    private func displayHighlightedSelectionEndpoint(
        _ endpoint: TimelineSelectionEndpoint?,
        renderCadence: TimelineRenderCadence = .immediate
    ) {
        guard hoveredSelectionEndpoint != endpoint else {
            return
        }

        hoveredSelectionEndpoint = endpoint
        updateTimelineRendererImmediately { renderer in
            renderer.displayHighlightedSelectionEndpoint(endpoint)
        }
        requestRender(cadence: renderCadence)
    }

    private func displayHighlightedClipEdge(
        _ hit: ClipHit?,
        renderCadence: TimelineRenderCadence = .immediate
    ) {
        let request = hit?.edge == nil ? nil : hit?.request
        let edge = hit?.edge
        guard hoveredClipRequest != request || hoveredClipEdge != edge else {
            return
        }

        hoveredClipRequest = request
        hoveredClipEdge = edge
        updateTimelineRendererImmediately { renderer in
            renderer.displayHighlightedClipEdge(
                trackID: request?.trackID,
                clipID: request?.clipID,
                edge: edge
            )
        }
        requestRender(cadence: renderCadence)
    }

    private func displayClipDragPreviews(
        _ previews: [TimelineClipDragPreview],
        renderCadence: TimelineRenderCadence = .coalescedInteraction
    ) {
        let placementAllowed = previews.isEmpty || activeClipPlacementIsAllowed
        guard
            activeClipDragPreviews != previews ||
                lastDisplayedClipPlacementIsAllowed != placementAllowed
        else {
            return
        }
        activeClipDragPreviews = previews
        lastDisplayedClipPlacementIsAllowed = placementAllowed
        clipLabelOverlayView.displayDragPreviews(previews)
        updateTimelineRendererImmediately { renderer in
            renderer.displayClipDragPreviews(previews, placementAllowed: placementAllowed)
        }
        requestRender(cadence: renderCadence)
    }

    private func displayClipMarquee(from anchor: CGPoint?, to point: CGPoint?) {
        guard let anchor, let point else {
            clipMarqueeLayer.isHidden = true
            clipMarqueeLayer.path = nil
            return
        }
        let rect = NSRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
        clipMarqueeLayer.path = CGPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 4,
            cornerHeight: 4,
            transform: nil
        )
        clipMarqueeLayer.isHidden = false
    }

    private func displayAutomationMarquee(from anchor: CGPoint?, to point: CGPoint?) {
        guard let anchor, let point else {
            automationMarqueeLayer.isHidden = true
            automationMarqueeLayer.path = nil
            return
        }
        let rect = marqueeRect(from: anchor, to: point)
        automationMarqueeLayer.path = CGPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 3,
            cornerHeight: 3,
            transform: nil
        )
        automationMarqueeLayer.isHidden = false
    }

    private func displayClipPropertyPreview(_ preview: TimelineClipPropertyPreview?) {
        guard activeClipPropertyPreview != preview else { return }
        activeClipPropertyPreview = preview
        updateTimelineRendererImmediately { renderer in
            renderer.displayClipPropertyPreview(preview)
        }
        requestRender(cadence: .coalescedInteraction)
    }

    private func displayClipPropertyHover(_ hover: TimelineClipPropertyHover?) {
        guard hoveredClipProperty != hover else { return }
        hoveredClipProperty = hover
        updateTimelineRendererImmediately { renderer in
            renderer.displayClipPropertyHover(hover)
        }
        requestRender(cadence: .coalescedInteraction)
    }

    @discardableResult
    private func updateClipDragPreview(
        to point: CGPoint,
        renderCadence: TimelineRenderCadence = .coalescedInteraction
    ) -> [TimelineClipDragPreview] {
        guard let request = activeClipRequest else {
            return []
        }

        let destination = progress(for: point, followsVisualFisheye: false)
        let previews: [TimelineClipDragPreview]
        switch activeDragMode {
        case .moveClip:
            let requests = activeClipRequests.isEmpty ? [request] : activeClipRequests
            let minimumStart = requests.map(\.projectStartProgress).min() ?? request.projectStartProgress
            let requestedDelta = destination - activeClipDragOffsetProgress - request.projectStartProgress
            // The right side of the timeline is extendable. Clamping against
            // progress 1 made any clip that defined the project duration
            // immovable because its maximum permitted delta was always zero.
            let clampedDelta = max(requestedDelta, -minimumStart)
            let delta = snappedClipGroupDelta(
                clampedDelta,
                requests: requests
            )
            let destinationTrackID = trackID(at: point) ?? request.trackID
            let anchorSourceIndex = activeClipTrackIndices[request.trackID] ??
                currentTrackIDs.firstIndex(of: request.trackID) ?? 0
            let requestedDestinationIndex = activeClipTrackIndices[destinationTrackID] ??
                currentTrackIDs.firstIndex(of: destinationTrackID) ?? anchorSourceIndex
            let selectedSourceIndices = requests.compactMap {
                activeClipTrackIndices[$0.trackID] ?? currentTrackIDs.firstIndex(of: $0.trackID)
            }
            let minimumSourceIndex = selectedSourceIndices.min() ?? anchorSourceIndex
            let maximumSourceIndex = selectedSourceIndices.max() ?? anchorSourceIndex
            let trackDelta = min(
                max(requestedDestinationIndex - anchorSourceIndex, -minimumSourceIndex),
                max(currentTrackIDs.count - 1 - maximumSourceIndex, 0)
            )
            previews = requests.map { item in
                let sourceIndex = activeClipTrackIndices[item.trackID] ??
                    currentTrackIDs.firstIndex(of: item.trackID) ?? anchorSourceIndex
                let destinationIndex = min(max(sourceIndex + trackDelta, 0), currentTrackIDs.count - 1)
                return TimelineClipDragPreview(
                    trackID: item.trackID,
                    destinationTrackID: currentTrackIDs[destinationIndex],
                    clipID: item.clipID,
                    originalStartProjectProgress: item.projectStartProgress,
                    originalEndProjectProgress: item.projectEndProgress,
                    presentedStartProjectProgress: item.projectStartProgress + delta,
                    presentedEndProjectProgress: item.projectEndProgress + delta,
                    kind: activeClipDragDuplicates ? .duplicate : .move
                )
            }
        case .trimClipStart:
            let start = snappedClipEdgeProgress(
                min(max(destination, 0), request.projectEndProgress),
                request: request
            )
            previews = [TimelineClipDragPreview(
                trackID: request.trackID,
                clipID: request.clipID,
                originalStartProjectProgress: request.projectStartProgress,
                originalEndProjectProgress: request.projectEndProgress,
                presentedStartProjectProgress: min(start, request.projectEndProgress),
                presentedEndProjectProgress: request.projectEndProgress,
                kind: .trimLeading
            )]
        case .trimClipEnd:
            let end = snappedClipEdgeProgress(
                max(min(destination, 1), request.projectStartProgress),
                request: request
            )
            previews = [TimelineClipDragPreview(
                trackID: request.trackID,
                clipID: request.clipID,
                originalStartProjectProgress: request.projectStartProgress,
                originalEndProjectProgress: request.projectEndProgress,
                presentedStartProjectProgress: request.projectStartProgress,
                presentedEndProjectProgress: max(end, request.projectStartProgress),
                kind: .trimTrailing
            )]
        default:
            return []
        }

        activeClipPlacementIsAllowed = onValidateClipDragPreviews?(previews) ?? true
        displayClipDragPreviews(previews, renderCadence: renderCadence)
        displayHoverProgress(activeClipSnapGuideProgress ?? destination, isArmed: true, renderCadence: renderCadence)
        return previews
    }

    private func clipSnapCandidates(excluding keys: Set<TimelineClipSelectionKey>) -> [Float] {
        guard timelineDuration > 0 else {
            return [0, 1]
        }

        var candidates: [Float] = [0, 1, currentPresentationPlayheadProgress()]
        if isLoopRangeEnabled {
            candidates.append(loopRange.startProgress)
            candidates.append(loopRange.endProgress)
        }
        candidates.reserveCapacity(5 + currentRenderTracks.reduce(0) { $0 + $1.clipRanges.count * 2 })
        for track in currentRenderTracks {
            let trackDuration = track.durationHint ?? track.waveformOverview?.duration ?? 0
            guard trackDuration > 0 else {
                continue
            }
            let scale = Float(min(max(trackDuration / timelineDuration, 0), 1))
            for clip in track.clipRanges where !clip.isSilent {
                if keys.contains(TimelineClipSelectionKey(trackID: track.id, clipID: clip.id)) {
                    continue
                }
                candidates.append(Float(clip.startProgress) * scale)
                candidates.append(Float(clip.endProgress) * scale)
            }
        }
        return candidates
    }

    private func clipSnapCandidates(excluding request: TimelineClipFocusRequest) -> [Float] {
        clipSnapCandidates(excluding: [TimelineClipSelectionKey(request)])
    }

    private func snappedClipEdgeProgress(
        _ progress: Float,
        request: TimelineClipFocusRequest
    ) -> Float {
        snapProgress(
            progress,
            candidates: activeClipSnapCandidates ?? clipSnapCandidates(excluding: request)
        )
    }

    private func snappedClipGroupDelta(
        _ delta: Float,
        requests: [TimelineClipFocusRequest]
    ) -> Float {
        let candidates: [Float]
        if let activeClipSnapCandidates {
            candidates = activeClipSnapCandidates
        } else {
            let keys = Set(requests.map(TimelineClipSelectionKey.init))
            candidates = clipSnapCandidates(excluding: keys)
        }
        var bestDelta: Float?
        var bestGuide: Float?
        let threshold = Float(8 / max(bounds.width, 1)) * viewport.durationProgress
        for request in requests {
            for edge in [request.projectStartProgress + delta, request.projectEndProgress + delta] {
                for candidate in candidates {
                    let snapDelta = candidate - edge
                    guard isClipSnappingEnabled, abs(snapDelta) <= threshold else {
                        continue
                    }
                    if bestDelta == nil || abs(snapDelta) < abs(bestDelta!) {
                        bestDelta = snapDelta
                        bestGuide = candidate
                    }
                }
            }
        }
        let minimumStart = requests.map(\.projectStartProgress).min() ?? 0
        let result = max(delta + (bestDelta ?? 0), -minimumStart)
        activeClipSnapGuideProgress = bestGuide
        return result
    }

    private func snapProgress(_ progress: Float, candidates: [Float]) -> Float {
        let thresholdProgress = Float(8 / max(bounds.width, 1)) * viewport.durationProgress
        guard isClipSnappingEnabled else {
            activeClipSnapGuideProgress = nil
            return progress
        }
        var nearest: Float?
        var nearestDistance = Float.greatestFiniteMagnitude
        for candidate in candidates {
            let distance = abs(candidate - progress)
            if distance <= thresholdProgress, distance < nearestDistance {
                nearest = candidate
                nearestDistance = distance
            }
        }
        activeClipSnapGuideProgress = nearest
        return nearest ?? progress
    }

    private func prepareClipDragInteractionContext() {
        let requests: [TimelineClipFocusRequest]
        if let activeClipRequest {
            requests = activeClipRequests.isEmpty ? [activeClipRequest] : activeClipRequests
        } else {
            requests = []
        }
        activeClipTrackIndices = Dictionary(
            uniqueKeysWithValues: currentTrackIDs.enumerated().map { ($0.element, $0.offset) }
        )
        guard !requests.isEmpty else {
            activeClipSnapCandidates = nil
            return
        }
        activeClipSnapCandidates = clipSnapCandidates(
            excluding: Set(requests.map(TimelineClipSelectionKey.init))
        )
    }

    private func clearClipDragInteractionContext() {
        activeClipSnapCandidates = nil
        activeClipTrackIndices.removeAll(keepingCapacity: true)
        activeClipSnapGuideProgress = nil
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
        startTransientRenderPulse(duration: TimelineLoopRegionStyleAnimation.renderPulseDuration)
        requestRender(cadence: renderCadence)
    }

    private func displayHoverProgress(
        _ progress: Float?,
        isArmed: Bool = false,
        guideSpan: TimelineHoverGuideSpan? = nil,
        renderCadence: TimelineRenderCadence = .immediate
    ) {
        let publishedProgress = isInteractionSuppressed ? nil : progress
        let publishedArmed = isInteractionSuppressed ? false : isArmed
        timelineRenderer?.publishInteractionHover(
            progress: publishedProgress,
            isArmed: publishedArmed,
            guideSpan: publishedProgress == nil ? nil : guideSpan
        )
        onHoverGuideStatePublishedForTesting?(
            publishedProgress,
            publishedArmed,
            publishedProgress == nil ? nil : guideSpan
        )
        requestRender(cadence: renderCadence)
    }

    private func displayLoopMoveGuides(
        _ isVisible: Bool,
        renderCadence: TimelineRenderCadence = .immediate
    ) {
        guard showsLoopMoveGuides != isVisible else {
            return
        }

        showsLoopMoveGuides = isVisible
        timelineRenderer?.publishInteractionLoopMoveGuides(isVisible)
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

    func prepareForEditTransaction() {
        stopRightPanMomentum()
        stopZoomMomentum()
        scrollGestureMode = nil
        flushPendingCursorRectInvalidationIfNeeded()
        let stableViewport = viewport
        updateTimelineRendererImmediately { renderer in
            renderer.commitViewport(stableViewport, marksInteraction: true)
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
        let displayTimestamp = CACurrentMediaTime()
        clipLabelOverlayView.displayDeletionEffects(
            requests,
            startTimestamp: displayTimestamp
        )
        updateTimelineRendererImmediately { renderer in
            renderer.triggerDeletionEffects(requests, at: displayTimestamp)
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
        clipLabelOverlayView.clearDeletionEffects()
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
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Audio timeline")
        setAccessibilityHelp(
            "Select clips and time ranges, seek playback, edit the loop range, and navigate tracks. " +
                "Clip commands are also available from the Edit and Clip menus."
        )
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        framebufferOnly = true
        preferredFramesPerSecond = targetFramesPerSecond

        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.masksToBounds = true
        configureDropPreviewLayer()
        clipMarqueeLayer.fillColor = NSColor(calibratedRed: 0.10, green: 0.68, blue: 0.72, alpha: 0.10).cgColor
        clipMarqueeLayer.strokeColor = NSColor(calibratedRed: 0.64, green: 0.94, blue: 0.96, alpha: 0.82).cgColor
        clipMarqueeLayer.lineWidth = 1
        clipMarqueeLayer.isHidden = true
        clipMarqueeLayer.actions = [
            "path": NSNull(),
            "hidden": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
        ]
        layer?.addSublayer(clipMarqueeLayer)
        automationMarqueeLayer.fillColor = NSColor(white: 0.92, alpha: 0.08).cgColor
        automationMarqueeLayer.strokeColor = NSColor(white: 0.92, alpha: 0.74).cgColor
        automationMarqueeLayer.lineWidth = 1
        automationMarqueeLayer.isHidden = true
        automationMarqueeLayer.actions = [
            "path": NSNull(),
            "hidden": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
        ]
        layer?.addSublayer(automationMarqueeLayer)
        bootstrapWaveformView.translatesAutoresizingMaskIntoConstraints = false
        clipLabelOverlayView.translatesAutoresizingMaskIntoConstraints = false
        transcriptOverlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bootstrapWaveformView)
        addSubview(clipLabelOverlayView)
        addSubview(transcriptOverlayView)
        timelineEndOverlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timelineEndOverlayView)
        leftOffscreenPlayheadButton.onActivate = { [weak self] _ in
            self?.revealOffscreenPlayhead()
        }
        rightOffscreenPlayheadButton.onActivate = { [weak self] _ in
            self?.revealOffscreenPlayhead()
        }
        addSubview(leftOffscreenPlayheadButton)
        addSubview(rightOffscreenPlayheadButton)

        registerForDraggedTypes([.fileURL])
    }

    override func layout() {
        super.layout()
        bootstrapWaveformView.frame = bounds
        clipLabelOverlayView.frame = bounds
        transcriptOverlayView.frame = bounds
        timelineEndOverlayView.frame = bounds
        clipMarqueeLayer.frame = bounds
        automationMarqueeLayer.frame = bounds
        layoutOffscreenPlayheadButtons()
        updateTrackLayoutForCurrentBounds(requestRender: false)
        updateClipLabelOverlay()
        updateOffscreenPlayheadButtons()
        updateBootstrapWaveformView()
        updateDropPreviewLayout()
        updateTranscriptOverlay()
        updateTimelineEndOverlay()
        requestTimelineRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updatePreferredFrameRate()
        requestTimelineRender()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateTrackLayoutForCurrentBounds(requestRender: false)
        performTranscriptOverlayUpdate(forceLayoutRebuild: true)
        invalidateTimelineCursorRects()
        requestTimelineRender()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
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
                guard let self, self.window != nil else {
                    return
                }
                self.requestTimelineRender()
            }
        }

        let tracks = currentRenderTracks
        let currentViewport = viewport
        let currentTrackLayout = trackLayout
        let currentLoopRange = loopRange
        let currentLoopRangeEnabled = isLoopRangeEnabled
        let currentLoopPlaybackBypassed = isLoopPlaybackBypassed
        let currentEmbeddedScrollbarsEnabled = areEmbeddedScrollbarsEnabled
        let currentShowsLoopMoveGuides = showsLoopMoveGuides
        let currentSelection = currentSelection
        let currentAutomationParameterID = isAutomationModeVisible ? displayedAutomationParameterID : nil
        let currentPlayheadProgress = presentationPlayheadProgress
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
            renderer.displayLoopPlaybackBypassed(currentLoopPlaybackBypassed)
            renderer.displayEmbeddedScrollbarsVisible(currentEmbeddedScrollbarsEnabled)
            renderer.publishInteractionLoopMoveGuides(currentShowsLoopMoveGuides)
            renderer.displayTracks(
                tracks,
                animateWaveformTransition: false,
                allowImmediateWaveformPrewarm: true,
                allowImmediateInteractiveWaveformPrewarm: false
            )
            renderer.displaySelection(currentSelection, marksInteraction: false)
            renderer.displayAutomationParameter(currentAutomationParameterID)
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
            let topFromTop = CGFloat(laneFrame.top) * bounds.height
            let bottomFromTop = CGFloat(laneFrame.bottom) * bounds.height
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

    private func updateTimelineRenderer(
        requestsRenderAfterUpdate: Bool = false,
        _ update: @escaping @Sendable (TimelineRenderer) -> Void
    ) {
        guard let timelineRenderer else {
            return
        }

        timelineRenderQueue.async { [weak self, timelineRenderer] in
            update(timelineRenderer)
            guard requestsRenderAfterUpdate else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.requestTimelineRender()
            }
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
        timelineRenderRequestGeneration &+= 1
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
            !isDraggingLoop,
            !isAutomationDragActive,
            !hasActiveTransientRenderPulse(),
            !hasActiveSelectionDragRenderPulse(),
            activeCameraTransition == nil,
            activeTrackScrollTransition == nil,
            !isEdgeAutoPanDragActive,
            trackReorderTrackID == nil,
            !isScrollbarHoverAnimating,
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
            isDraggingLoop ||
            trackReorderTrackID != nil ||
            isZoomControlInteractionActive ||
            scrollGestureMode != nil ||
            rightPanPreviousPoint != nil
    }

    private var isAutomationDragActive: Bool {
        activeDragMode == .automationPoint ||
            activeDragMode == .automationCurve ||
            activeDragMode == .automationMarquee
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
        activeCameraTransition = nil
        activeTrackScrollTransition = nil
        edgeAutoPanLastTimestamp = nil
        isProcessingSelectionAnimationActive = false
        needsTimelineRender = false
        isTimelinePlaybackActive = false
        stopRightPanMomentum()
        stopZoomMomentum()
        scrollGestureMode = nil
        suppressesNavigationGestureForSelectionFocus = false
        trackpadPanPreviousTime = nil
        trackpadPanVelocityProgressPerSecond = 0
        PerformanceSampler.shared.updateRenderDemand(.idle)
    }

    private func displayLinkDidTick(_ frame: TimelineDisplayLinkFrame) {
        publishPerformanceRenderDemand()
        let sampledAt = CACurrentMediaTime()
        let didAdvanceClipDeletion = clipLabelOverlayView.advanceDeletionPresentation(
            at: sampledAt
        )
        let didAutoPan = stepEdgeAutoPan(sampledAt: sampledAt)
        let didAdvanceCamera = stepCameraTransition(sampledAt: sampledAt)
        let didAdvanceTrackScroll = stepTrackScrollTransition(sampledAt: sampledAt)
        let didAdvanceTrackReorder = stepTrackReorder(sampledAt: sampledAt)
        let didAdvanceScrollbarHover = stepScrollbarHover(sampledAt: sampledAt)
        let didRefreshSelection = refreshLiveSelectionFromCurrentMouse(sampledAt: sampledAt)
        let didRefreshLoop = refreshLiveLoopFromCurrentMouse()
        let didRefreshClipDrag = refreshLiveClipDragFromCurrentMouse()
        let didRefreshAutomation = refreshLiveAutomationFromCurrentMouse()
        if didRefreshSelection || didRefreshLoop || didRefreshClipDrag || didRefreshAutomation {
            PerformanceSampler.shared.recordTimelineInputEvent(
                kind: "display-paced-drag-sample",
                at: sampledAt
            )
        }
        let shouldRender = needsTimelineRender ||
            isTimelinePlaybackActive ||
            isProcessingSelectionAnimationActive ||
            isDraggingLoop ||
            isAutomationDragActive ||
            didAdvanceClipDeletion ||
            hasActiveTransientRenderPulse() ||
            hasActiveSelectionDragRenderPulse() ||
            activeCameraTransition != nil ||
            activeTrackScrollTransition != nil ||
            didAdvanceCamera ||
            didAdvanceTrackScroll ||
            didAutoPan ||
            didAdvanceTrackReorder ||
            didAdvanceScrollbarHover ||
            didRefreshSelection ||
            didRefreshLoop ||
            didRefreshClipDrag ||
            didRefreshAutomation ||
            isHotPathContractSmokeFrameStatsActive

        guard shouldRender else {
            if isEdgeAutoPanDragActive {
                return
            }
            timelineDisplayLink?.stop()
            PerformanceSampler.shared.updateRenderDemand(.idle)
            return
        }

        if didRefreshSelection || didRefreshLoop || didRefreshClipDrag || didRefreshAutomation {
            needsTimelineRender = true
        }

        if isTimelinePlaybackActive,
           let playheadProgress = projectedPresentationPlayheadProgress(at: frame.targetPresentationTimestamp) {
            onPlaybackVisualProgressChanged?(playheadProgress)
            updateOffscreenPlayheadButtons(playheadProgress: playheadProgress)
        }

        let submittedRequestGeneration = timelineRenderRequestGeneration
        let didSubmitRender = submitTimelineRender(frame: frame)
        if didSubmitRender {
            needsTimelineRender = Self.renderRequestRemainsPendingAfterSubmission(
                submittedGeneration: submittedRequestGeneration,
                currentGeneration: timelineRenderRequestGeneration
            )
            finishBootstrapWaveformHandoffAfterSubmittedFrame()
        }
        stopTimelineDisplayLinkIfIdle()
    }

    nonisolated static func renderRequestRemainsPendingAfterSubmission(
        submittedGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        currentGeneration != submittedGeneration
    }

    private func stepTrackReorder(sampledAt timestamp: CFTimeInterval) -> Bool {
        guard trackReorderTrackID != nil, let pointerY = trackReorderPointerYFromTop else {
            return false
        }
        let previousTick = trackReorderLastTickTime
        trackReorderLastTickTime = timestamp
        let elapsed = min(max(timestamp - previousTick, 1.0 / 240.0), 1.0 / 20.0)
        let edgeZone: Float = 42
        let height = Float(max(bounds.height, 1))
        let topDistance = pointerY - trackLayout.rulerLaneHeight
        let bottomDistance = height - pointerY
        let direction: Float
        let proximity: Float
        if topDistance < edgeZone {
            direction = -1
            proximity = min(max(1 - topDistance / edgeZone, 0), 1)
        } else if bottomDistance < edgeZone {
            direction = 1
            proximity = min(max(1 - bottomDistance / edgeZone, 0), 1)
        } else {
            direction = 0
            proximity = 0
        }
        if direction != 0 {
            let speed = 760 * proximity * proximity
            scrollTracks(byPixels: direction * speed * Float(elapsed))
            updateTrackReorder(yFromTop: pointerY)
        }
        return publishTrackReorderPresentation(at: timestamp)
    }

    private var isScrollbarHoverAnimating: Bool {
        abs(scrollbarHoverPresentation - scrollbarHoverTarget) > 0.001
    }

    private func stepScrollbarHover(sampledAt timestamp: CFTimeInterval) -> Bool {
        guard isScrollbarHoverAnimating else {
            return false
        }
        let raw = Float(min(max(
            (timestamp - scrollbarHoverTransitionStartTime) / scrollbarHoverTransitionDuration,
            0
        ), 1))
        let eased = easeInOutCubic(raw)
        scrollbarHoverPresentation = scrollbarHoverTransitionSource +
            (scrollbarHoverTarget - scrollbarHoverTransitionSource) * eased
        if raw >= 1 {
            scrollbarHoverPresentation = scrollbarHoverTarget
            if scrollbarHoverTarget == 0, activeScrollbarAxis == nil {
                publishScrollbarPresentation()
                scrollbarPresentationAxis = nil
                return true
            }
        }
        publishScrollbarPresentation()
        return true
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
        timelineRenderQueue.async { [weak self, timelineRenderer, renderTarget, renderFlightGate] in
            let didCommit = timelineRenderer.render(to: renderTarget) {
                renderFlightGate.finish()
            }
            let submittedAt = CACurrentMediaTime()
            DispatchQueue.main.async { [weak self] in
                self?.finishPendingRenderSubmittedCallbacks(submittedAt: submittedAt)
            }
            if !didCommit {
                renderFlightGate.finish()
            }
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
            activeDragMode != nil ||
            rightPanMomentumTimer != nil ||
            zoomMomentumTimer != nil ||
            scrollGestureMode != nil
        {
            return .interaction
        }

        if isProcessingSelectionAnimationActive ||
            activeCameraTransition != nil ||
            activeTrackScrollTransition != nil ||
            hasActiveTransientRenderPulse()
        {
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

    private func wakeDisplayPacedInteractionSampler() {
        // Raw mouse events can substantially outpace the display. They only keep the sampler
        // awake; the display link owns pointer geometry publication and renderer interaction work.
        startTimelineDisplayLink()
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
            isDraggingSelection,
            let selectionAnchorProgress,
            let point = currentMousePointInTimeline()
        else {
            return false
        }

        switch activeDragMode {
        case .selection:
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
        case .resizeSelectionStart, .resizeSelectionEnd:
            updateSelectionResizeDrag(
                to: point,
                timestamp: timestamp,
                schedulesRender: false
            )
            return true
        default:
            return false
        }
    }

    private func refreshLiveLoopFromCurrentMouse() -> Bool {
        guard
            isDraggingLoop,
            let point = currentMousePointInTimeline()
        else {
            return false
        }

        // AppKit drag events may arrive either above or below display cadence. This is the single
        // live owner of loop geometry so each presentable frame consumes exactly one pointer sample.
        return updateActiveLoopDrag(
            to: point,
            renderCadence: .none,
            notifiesChange: true
        )
    }

    private func refreshLiveClipDragFromCurrentMouse() -> Bool {
        guard
            isDraggingSelection,
            activeDragMode == .moveClip ||
                activeDragMode == .trimClipStart ||
                activeDragMode == .trimClipEnd,
            let point = currentMousePointInTimeline()
        else {
            return false
        }

        updateClipDragPreview(to: point, renderCadence: .none)
        return true
    }

    private var isEdgeAutoPanDragActive: Bool {
        guard isSelectionEnabled, !viewport.isFull else {
            return false
        }

        switch activeDragMode {
        case .resizeSelectionStart, .resizeSelectionEnd:
            return isDraggingSelection
        case .loopStart, .loopEnd:
            return isDraggingLoop
        case .moveClip, .trimClipStart, .trimClipEnd:
            return isDraggingSelection
        case .clipFadeIn, .clipFadeOut:
            return isDraggingSelection
        case
            .automationPoint,
            .automationCurve,
            .automationMarquee,
            .automationPencil,
            .automationRamp,
            .automationEraser:
            return false
        case .clipMarquee:
            return false
        case .timelineEnd:
            return true
        case .horizontalScrollbar, .verticalScrollbar:
            return false
        case
            .seek,
            .selection,
            .loopRegion,
            .moveLoopRegion,
            .none:
            return false
        }
    }

    @discardableResult
    private func stepEdgeAutoPan(sampledAt timestamp: CFTimeInterval) -> Bool {
        guard
            isEdgeAutoPanDragActive,
            bounds.width > 0,
            let point = currentMousePointInTimeline()
        else {
            edgeAutoPanLastTimestamp = nil
            return false
        }

        let normalizedVelocity = TimelineEdgeAutoPan.normalizedVelocity(
            pointerX: point.x,
            viewportWidth: bounds.width,
            activationDistance: edgeAutoPanActivationDistance
        )
        let previousTimestamp = edgeAutoPanLastTimestamp
        edgeAutoPanLastTimestamp = timestamp
        guard normalizedVelocity != 0 else {
            return false
        }

        let defaultFrameInterval = 1.0 / Double(max(targetFramesPerSecond, 1))
        let elapsedTime = min(
            max(timestamp - (previousTimestamp ?? timestamp - defaultFrameInterval), 1.0 / 240.0),
            edgeAutoPanMaximumFrameInterval
        )
        let progressDelta = TimelineEdgeAutoPan.progressDelta(
            normalizedVelocity: normalizedVelocity,
            viewportDurationProgress: viewport.durationProgress,
            elapsedTime: elapsedTime,
            maximumViewportWidthsPerSecond: edgeAutoPanMaximumViewportWidthsPerSecond
        )
        let nextViewport = viewport.panned(byProgress: progressDelta)
        guard nextViewport != viewport else {
            return false
        }

        setViewport(
            nextViewport,
            transcriptCadence: .coalescedInteraction,
            invalidatesCursorRects: false,
            renderCadence: .coalescedInteraction
        )
        onNavigationScrollActivity?(.horizontal)

        switch activeDragMode {
        case .resizeSelectionStart, .resizeSelectionEnd, .loopStart, .loopEnd:
            // The display-paced pointer refresh below owns these geometries. Recomputing them here
            // would publish the same state twice in one display interval during edge auto-pan.
            break
        case .moveClip, .trimClipStart, .trimClipEnd:
            // Clip geometry is sampled immediately after auto-pan by the display-link owner.
            // Publishing here as well would validate and render the same pointer twice per frame.
            break
        case .clipFadeIn, .clipFadeOut:
            updateClipPropertyPreview(to: point)
        case
            .automationPoint,
            .automationCurve,
            .automationMarquee,
            .automationPencil,
            .automationRamp,
            .automationEraser:
            break
        case .timelineEnd:
            updateTimelineEndDrag(to: point)
        case .horizontalScrollbar, .verticalScrollbar:
            break
        case
            .seek,
            .selection,
            .loopRegion,
            .moveLoopRegion,
            .clipMarquee,
            .none:
            break
        }
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

    private func projectedPresentationPlayheadProgress(at timestamp: CFTimeInterval) -> Float? {
        guard isTimelinePlaybackActive, timelineDuration.isFinite, timelineDuration > 0 else {
            return nil
        }

        let elapsedTime = timestamp - presentationPlayheadAnchorTimestamp
        let projectedProgress = presentationPlayheadProgress + Float(elapsedTime / timelineDuration)
        return loopConstrainedPagingProgress(projectedProgress)
    }

    private func loopConstrainedPagingProgress(_ progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        guard isLoopRangeEnabled, !isLoopPlaybackBypassed else {
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
            let point = convert(sender.draggingLocation, from: nil)
            let target = AudioDropTarget(
                trackID: trackID(at: point),
                projectTime: projectTime(atRawX: point.x)
            )
            onAudioFileDropped?(url, target)
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

        let unmodifiedKey = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if unmodifiedKey, event.charactersIgnoringModifiers?.lowercased() == "a" {
            guard !event.isARepeat else { return }
            toggleAutomationMode(nil)
            return
        }
        if unmodifiedKey, event.charactersIgnoringModifiers?.lowercased() == "c" {
            guard !event.isARepeat else { return }
            selectAutomationCurveTool(nil)
            return
        }
        if unmodifiedKey, event.charactersIgnoringModifiers?.lowercased() == "p" {
            guard !event.isARepeat else { return }
            cycleDisplayedAutomationParameter()
            return
        }
        if isAutomationModeVisible,
           (event.keyCode == 51 || event.keyCode == 117),
           let address = automationSelection.address,
           case let .track(trackID) = address.owner,
           !automationSelection.pointIDs.isEmpty {
            onAutomationEditRequested?(TimelineAutomationEditRequest(
                trackID: trackID,
                parameterID: address.parameterID.rawValue,
                action: .remove(pointIDs: automationSelection.pointIDs)
            ))
            setAutomationSelection(.empty)
            return
        }

        if isAutomationModeVisible,
           event.modifierFlags.contains(.command),
           event.modifierFlags.intersection([.control, .option]).isEmpty,
           let character = event.charactersIgnoringModifiers?.lowercased(),
           ["c", "x", "v"].contains(character),
           let address = automationSelection.address,
           case let .track(trackID) = address.owner {
            switch character {
            case "c" where !automationSelection.pointIDs.isEmpty:
                onAutomationEditRequested?(TimelineAutomationEditRequest(
                    trackID: trackID,
                    parameterID: address.parameterID.rawValue,
                    action: .copy(pointIDs: automationSelection.pointIDs)
                ))
                return
            case "x" where !automationSelection.pointIDs.isEmpty:
                onAutomationEditRequested?(TimelineAutomationEditRequest(
                    trackID: trackID,
                    parameterID: address.parameterID.rawValue,
                    action: .cut(pointIDs: automationSelection.pointIDs)
                ))
                setAutomationSelection(.empty)
                return
            case "v":
                onAutomationEditRequested?(TimelineAutomationEditRequest(
                    trackID: trackID,
                    parameterID: address.parameterID.rawValue,
                    action: .paste(frameProgress: Double(currentPresentationPlayheadProgress()))
                ))
                return
            default:
                break
            }
        }

        if
            isAutomationModeVisible,
            let address = automationSelection.address,
            case let .track(trackID) = address.owner,
            !automationSelection.pointIDs.isEmpty,
            [123, 124, 125, 126].contains(event.keyCode),
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        {
            let multiplier = event.modifierFlags.contains(.shift) ? 10 : 1
            let frameDelta: Int
            let normalizedValueDelta: Float
            switch event.keyCode {
            case 123:
                frameDelta = -multiplier
                normalizedValueDelta = 0
            case 124:
                frameDelta = multiplier
                normalizedValueDelta = 0
            case 125:
                frameDelta = 0
                normalizedValueDelta = -0.01 * Float(multiplier)
            default:
                frameDelta = 0
                normalizedValueDelta = 0.01 * Float(multiplier)
            }
            onAutomationEditRequested?(TimelineAutomationEditRequest(
                trackID: trackID,
                parameterID: address.parameterID.rawValue,
                action: .nudge(
                    pointIDs: automationSelection.pointIDs,
                    frameDelta: frameDelta,
                    normalizedValueDelta: normalizedValueDelta
                )
            ))
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

        let focusSelectionModifiers = event.modifierFlags.intersection([
            .command,
            .control,
            .option,
            .shift,
        ])
        if event.keyCode == 6, focusSelectionModifiers.isEmpty {
            guard !event.isARepeat else {
                return
            }
            zoomToSelection()
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

        if event.modifierFlags.contains(.control), (event.keyCode == 123 || event.keyCode == 124) {
            onSelectAdjacentClipRequested?(
                event.keyCode == 124 ? 1 : -1,
                event.modifierFlags.contains(.shift)
            )
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
            if event.modifierFlags.contains(.shift) {
                onReapplyLastEffect?()
            } else if clipCommandContext.isEnabled(.repeatClips) {
                onRepeatSelectedClipsRequested?()
            }
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
            displaySelection(nil)
            displayTranscriptSelection(nil)
            displayAutomationMarquee(from: nil, to: nil)
            displayAutomationPreview(points: nil, hit: nil)
            onSelectionChanged?(nil)
            onTranscriptSelectionChanged?(nil)
            onTimelineInteractionBegan?()
            activeDragMode = nil
            activeAutomationHit = nil
            activeAutomationPoints.removeAll(keepingCapacity: true)
            activeAutomationDidDrag = false
            activeAutomationMouseDownModifierFlags = []
            automationMarqueeBaseSelection = .empty
            activeTranscriptDrag = nil
            activeSelectionDragOffsetX = 0
            isDraggingSelection = false
            isDraggingLoop = false
            activeLoopResizeFixedProgress = nil
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
        if isAutomationModeVisible {
            addCursorRect(bounds, cursor: .crosshair)
        }
        if let markerX = timelineEndMarkerX() {
            addCursorRect(
                NSRect(
                    x: markerX - 6,
                    y: rulerLaneRect().minY,
                    width: 30,
                    height: rulerLaneRect().height
                ),
                cursor: .resizeLeftRight
            )
        }
        addLoopHandleCursorRects()
        addSelectionEdgeCursorRects()
        addClipCursorRects()
        if areEmbeddedScrollbarsEnabled {
            let scrollbarGeometry = currentScrollbarGeometry()
            if scrollbarGeometry.isHorizontalScrollable {
                addCursorRect(scrollbarGeometry.horizontalHandle.insetBy(dx: -4, dy: -4), cursor: .openHand)
            }
            if scrollbarGeometry.isVerticalScrollable {
                addCursorRect(scrollbarGeometry.verticalHandle.insetBy(dx: -4, dy: -4), cursor: .openHand)
            }
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard
            !isInteractionSuppressed,
            isSelectionEnabled,
            activeDragMode == nil,
            isFrontmostPointerOwner(for: event)
        else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if isAutomationModeVisible, let hit = automationHit(at: point) {
            displayClipPropertyHover(nil)
            displayAutomationHover(for: hit)
            switch hit.kind {
            case .point:
                NSCursor.pointingHand.set()
            case .segment where automationTool == .curve:
                NSCursor.resizeUpDown.set()
            case .segment, .fence, .lane:
                NSCursor.crosshair.set()
            }
            return
        }
        if timelineEndHandleHit(at: point) {
            displayClipPropertyHover(nil)
            timelineEndOverlayView.isHandleHovered = true
            NSCursor.resizeLeftRight.set()
            return
        }
        timelineEndOverlayView.isHandleHovered = false
        if let endpointHit = selectionEndpointHit(at: point) {
            displayClipPropertyHover(nil)
            displayHighlightedClipEdge(nil, renderCadence: .coalescedInteraction)
            displayHighlightedSelectionEndpoint(
                endpointHit.endpoint,
                renderCadence: .coalescedInteraction
            )
            NSCursor.resizeLeftRight.set()
            return
        }

        displayHighlightedSelectionEndpoint(nil, renderCadence: .coalescedInteraction)
        if let propertyHit = clipPropertyHit(at: point) {
            displayClipPropertyHover(TimelineClipPropertyHover(
                trackID: propertyHit.request.trackID,
                clipID: propertyHit.request.clipID,
                control: propertyHit.control
            ))
            displayHighlightedClipEdge(nil, renderCadence: .coalescedInteraction)
            NSCursor.resizeLeftRight.set()
            return
        }
        displayClipPropertyHover(nil)
        if let hit = clipHit(at: point), hit.edge != nil {
            displayClipPropertyHover(nil)
            displayHighlightedClipEdge(hit, renderCadence: .coalescedInteraction)
            NSCursor.resizeLeftRight.set()
            return
        }
        if let hit = clipHit(at: point), hit.isHeader {
            displayClipPropertyHover(nil)
            displayHighlightedClipEdge(nil, renderCadence: .coalescedInteraction)
            NSCursor.openHand.set()
            return
        }
        displayHighlightedClipEdge(nil, renderCadence: .coalescedInteraction)
        displayClipPropertyHover(nil)
        super.cursorUpdate(with: event)
    }

    private func isFrontmostPointerOwner(for event: NSEvent) -> Bool {
        guard let window, let contentView = window.contentView else {
            return true
        }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(point) else {
            return false
        }
        return hitView === self || hitView.isDescendant(of: self)
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

    private func addClipCursorRects() {
        guard timelineDuration > 0, viewport.durationProgress > 0 else {
            return
        }
        let layout = resolvedTrackLayoutForCurrentBounds()
        for (trackIndex, track) in currentRenderTracks.enumerated() {
            guard let lane = layout.laneFrame(forTrackIndex: trackIndex), lane.isVisible else {
                continue
            }
            let duration = track.durationHint ?? track.waveformOverview?.duration ?? 0
            guard duration > 0 else {
                continue
            }
            let scale = duration / timelineDuration
            let bottom = bounds.height - CGFloat(lane.bottom) * bounds.height
            let height = CGFloat(lane.height) * bounds.height
            let headerHeight = min(22, height)
            for clip in track.clipRanges where !clip.isSilent {
                let start = Float(clip.startProgress * scale)
                let end = Float(clip.endProgress * scale)
                let startX = CGFloat((start - viewport.startProgress) / viewport.durationProgress) * bounds.width
                let endX = CGFloat((end - viewport.startProgress) / viewport.durationProgress) * bounds.width
                for x in [startX, endX] where x >= -10 && x <= bounds.width + 10 {
                    addCursorRect(
                        NSRect(x: x - 8, y: bottom, width: 16, height: height),
                        cursor: .resizeLeftRight
                    )
                }
                let headerRect = NSRect(
                    x: max(startX + 8, 0),
                    y: bottom + height - headerHeight,
                    width: max(min(endX - 8, bounds.width) - max(startX + 8, 0), 0),
                    height: headerHeight
                )
                if headerRect.width > 2 {
                    addCursorRect(headerRect, cursor: .openHand)
                }
            }
        }
    }

    private func addLoopHandleCursorRects() {
        let loopBandRect = loopInteractionBandRect()
        guard loopBandRect.width > 0, loopBandRect.height > 0 else {
            return
        }

        addCursorRect(rulerSeekBandRect(), cursor: .pointingHand)
        addCursorRect(loopBandRect, cursor: .pointingHand)
        if let loopRegionRect = loopRegionRect() {
            addCursorRect(loopRegionRect, cursor: .openHand)
        }
        for endpoint in [TimelineLoopEndpoint.start, .end] {
            guard let rect = loopRegionEdgeHitRect(for: endpoint) else {
                continue
            }

            addCursorRect(rect, cursor: .resizeLeftRight)
        }
    }

    private func addSelectionEdgeCursorRects() {
        guard
            let selection = currentSelection,
            selection.durationProgress > 0,
            let geometry = selectionEndpointGeometry(
                for: selection,
                at: CACurrentMediaTime()
            )
        else {
            return
        }

        for endpoint in [TimelineSelectionEndpoint.start, .end] {
            guard let rect = selectionEdgeHitRect(
                for: endpoint,
                geometry: geometry
            ) else {
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

    @objc func toggleAutomationMode(_ sender: Any?) {
        if let onToggleAutomationModeRequested {
            onToggleAutomationModeRequested()
            return
        }
        setAutomationModeVisible(!isAutomationModeVisible)
    }

    func setAutomationModeVisible(_ isVisible: Bool) {
        guard isAutomationModeVisible != isVisible else {
            let displayedParameterID = isVisible ? displayedAutomationParameterID : nil
            updateTimelineRendererImmediately { renderer in
                renderer.displayAutomationParameter(displayedParameterID)
            }
            requestTimelineRender()
            return
        }

        isAutomationModeVisible = isVisible
        if !isAutomationModeVisible {
            activeAutomationHit = nil
            activeAutomationPoints.removeAll(keepingCapacity: true)
            activeAutomationDidDrag = false
            activeAutomationMouseDownModifierFlags = []
            setAutomationSelection(.empty)
        }
        let displayedParameterID = isAutomationModeVisible ? displayedAutomationParameterID : nil
        updateTimelineRendererImmediately { renderer in
            renderer.displayAutomationParameter(displayedParameterID)
            renderer.displayAutomationHover(nil)
            renderer.displayAutomationPreview(nil)
        }
        invalidateTimelineCursorRects()
        requestTimelineRender()
    }

    func setDisplayedAutomationParameter(_ parameterID: TimelineAutomationParameterID) {
        guard
            parameterID != automationParameterID,
            TimelineAutomationParameterRegistry.descriptor(for: parameterID)?.supportedOwners.contains(.track) == true
        else {
            return
        }
        displayedAutomationParameterID = parameterID.rawValue
        setAutomationSelection(.empty)
        activeAutomationHit = nil
        activeAutomationPoints.removeAll(keepingCapacity: true)
        let renderedParameterID = isAutomationModeVisible ? parameterID.rawValue : nil
        updateTimelineRendererImmediately { renderer in
            renderer.displayAutomationParameter(renderedParameterID)
            renderer.displayAutomationHover(nil)
            renderer.displayAutomationPreview(nil)
        }
        invalidateTimelineCursorRects()
        requestTimelineRender()
    }

    @objc func selectAutomationPointTool(_ sender: Any?) {
        automationTool = .point
        if !isAutomationModeVisible {
            toggleAutomationMode(nil)
        }
    }

    @objc func selectAutomationCurveTool(_ sender: Any?) {
        automationTool = .curve
        if !isAutomationModeVisible {
            toggleAutomationMode(nil)
        }
    }

    @objc func selectAutomationPencilTool(_ sender: Any?) { selectAutomationTool(.pencil) }
    @objc func selectAutomationRampTool(_ sender: Any?) { selectAutomationTool(.ramp) }
    @objc func selectAutomationEraserTool(_ sender: Any?) { selectAutomationTool(.eraser) }

    private func selectAutomationTool(_ tool: TimelineAutomationTool) {
        automationTool = tool
        if !isAutomationModeVisible { toggleAutomationMode(nil) }
        invalidateTimelineCursorRects()
    }

    @objc func setAutomationCurveLinear(_ sender: Any?) { setSelectedAutomationCurvePreset(.linear) }
    @objc func setAutomationCurveEaseIn(_ sender: Any?) { setSelectedAutomationCurvePreset(.easeIn) }
    @objc func setAutomationCurveEaseOut(_ sender: Any?) { setSelectedAutomationCurvePreset(.easeOut) }
    @objc func setAutomationCurveSCurve(_ sender: Any?) { setSelectedAutomationCurvePreset(.sCurve) }
    @objc func setAutomationCurveStepped(_ sender: Any?) { setSelectedAutomationCurvePreset(.stepped) }

    private func setSelectedAutomationCurvePreset(_ preset: TimelineAutomationCurvePreset) {
        guard
            isAutomationModeVisible,
            let address = automationSelection.address,
            case let .track(trackID) = address.owner,
            !automationSelection.pointIDs.isEmpty
        else { return }
        onAutomationEditRequested?(TimelineAutomationEditRequest(
            trackID: trackID,
            parameterID: address.parameterID.rawValue,
            action: .setCurvePreset(pointIDs: automationSelection.pointIDs, preset: preset)
        ))
    }

    @objc func undoTimelineEdit(_ sender: Any?) {
        onUndo?()
    }

    @objc func redoTimelineEdit(_ sender: Any?) {
        onRedo?()
    }

    @objc func cutTimelineSelection(_ sender: Any?) {
        if requestAutomationClipboardAction(isCut: true) { return }
        onCutSelection?()
    }

    @objc func cut(_ sender: Any?) {
        cutTimelineSelection(sender)
    }

    @objc func copyTimelineSelection(_ sender: Any?) {
        if requestAutomationClipboardAction(isCut: false) { return }
        onCopySelection?()
    }

    @objc func copy(_ sender: Any?) {
        copyTimelineSelection(sender)
    }

    @objc func pasteTimelineAudio(_ sender: Any?) {
        if
            isAutomationModeVisible,
            let address = automationSelection.address,
            case let .track(trackID) = address.owner
        {
            onAutomationEditRequested?(TimelineAutomationEditRequest(
                trackID: trackID,
                parameterID: address.parameterID.rawValue,
                action: .paste(frameProgress: Double(currentPresentationPlayheadProgress()))
            ))
            return
        }
        onPasteAudio?()
    }

    private func requestAutomationClipboardAction(isCut: Bool) -> Bool {
        guard
            isAutomationModeVisible,
            let address = automationSelection.address,
            case let .track(trackID) = address.owner,
            !automationSelection.pointIDs.isEmpty
        else { return false }
        onAutomationEditRequested?(TimelineAutomationEditRequest(
            trackID: trackID,
            parameterID: address.parameterID.rawValue,
            action: isCut ? .cut(pointIDs: automationSelection.pointIDs) :
                .copy(pointIDs: automationSelection.pointIDs)
        ))
        if isCut { setAutomationSelection(.empty) }
        return true
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

    @objc func selectPreviousClip(_ sender: Any?) {
        onSelectAdjacentClipRequested?(-1, false)
    }

    @objc func selectNextClip(_ sender: Any?) {
        onSelectAdjacentClipRequested?(1, false)
    }

    @objc func toggleSelectedClipMute(_ sender: Any?) { onToggleSelectedClipMuteRequested?() }
    @objc func toggleSelectedClipLock(_ sender: Any?) { onToggleSelectedClipLockRequested?() }
    @objc func groupSelectedClips(_ sender: Any?) { onGroupSelectedClipsRequested?() }
    @objc func ungroupSelectedClips(_ sender: Any?) { onUngroupSelectedClipsRequested?() }
    @objc func repeatSelectedClips(_ sender: Any?) { onRepeatSelectedClipsRequested?() }
    @objc func crossfadeSelectedClips(_ sender: Any?) { onCrossfadeSelectedClipsRequested?() }
    @objc func toggleClipSnapping(_ sender: Any?) {
        isClipSnappingEnabled.toggle()
        activeClipSnapGuideProgress = nil
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

    @objc func selectFollowingClips(_ sender: Any?) {
        onSelectFollowingClipsRequested?()
    }

    @objc func selectClipsInTimeSelection(_ sender: Any?) {
        onSelectClipsInTimeSelectionRequested?()
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

    @objc func closeFocusedClipInspector(_ sender: Any?) {
        onCloseFocusedClipRequested?()
    }

    @objc func splitFocusedClipAtPlayhead(_ sender: Any?) {
        onSplitFocusedClipRequested?()
    }

    @objc func trimFocusedClipStartToPlayhead(_ sender: Any?) {
        onTrimFocusedClipStartRequested?()
    }

    @objc func trimFocusedClipEndToPlayhead(_ sender: Any?) {
        onTrimFocusedClipEndRequested?()
    }

    @objc func moveFocusedClipEarlier(_ sender: Any?) {
        onMoveFocusedClipEarlierRequested?()
    }

    @objc func moveFocusedClipLater(_ sender: Any?) {
        onMoveFocusedClipLaterRequested?()
    }

    @objc func duplicateFocusedClip(_ sender: Any?) {
        onDuplicateFocusedClipRequested?()
    }

    @objc func renameFocusedClip(_ sender: Any?) {
        onRenameFocusedClipRequested?()
    }

    @objc func deleteFocusedClip(_ sender: Any?) {
        onDeleteFocusedClipRequested?()
    }

    @objc func openSelectedClipInspector(_ sender: Any?) {
        onOpenSelectedClipInspectorRequested?()
    }

    @objc func moveSelectedClipsToTrackAbove(_ sender: Any?) {
        onMoveSelectedClipsAcrossTracksRequested?(-1)
    }

    @objc func moveSelectedClipsToTrackBelow(_ sender: Any?) {
        onMoveSelectedClipsAcrossTracksRequested?(1)
    }

    @objc func relinkMissingMedia(_ sender: Any?) {
        onRelinkMissingMediaRequested?()
    }

    @objc func cancelMissingMediaRelink(_ sender: Any?) {
        onCancelMissingMediaRelinkRequested?()
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
            return clipCommandContext.isEnabled(.slip)
        case #selector(selectPreviousClip(_:)), #selector(selectNextClip(_:)):
            return clipCommandContext.isEnabled(.selectPreviousOrNext)
        case #selector(toggleSelectedClipMute(_:)),
             #selector(toggleSelectedClipLock(_:)),
             #selector(groupSelectedClips(_:)),
             #selector(ungroupSelectedClips(_:)):
            return clipCommandContext.isEnabled(.mute)
        case #selector(repeatSelectedClips(_:)):
            return clipCommandContext.isEnabled(.repeatClips)
        case #selector(crossfadeSelectedClips(_:)):
            return clipCommandContext.isEnabled(.crossfade)
        case #selector(toggleClipSnapping(_:)):
            menuItem.state = isClipSnappingEnabled ? .on : .off
            return true
        case #selector(snapSelectionToPlayheadEdgesOrSilence(_:)):
            return currentSelection?.durationProgress ?? 0 > 0 || canUseDeadAirCandidate
        case #selector(selectTimeAcrossLinkedTracks(_:)):
            return currentSelection?.durationProgress ?? 0 > 0
        case #selector(selectAllClipsOnTrack(_:)):
            return clipCommandContext.isEnabled(.selectAllOnTrack)
        case #selector(selectFollowingClips(_:)):
            return clipCommandContext.isEnabled(.selectFollowing)
        case #selector(selectClipsInTimeSelection(_:)):
            return clipCommandContext.isEnabled(.selectInTimeRange)
        case #selector(openSelectedClipInspector(_:)):
            return clipCommandContext.isEnabled(.openInspector)
        case #selector(moveSelectedClipsToTrackAbove(_:)):
            return clipCommandContext.isEnabled(.moveToTrackAbove)
        case #selector(moveSelectedClipsToTrackBelow(_:)):
            return clipCommandContext.isEnabled(.moveToTrackBelow)
        case #selector(reapplyLastEffect(_:)):
            return canReapplyLastEffect
        case #selector(closeFocusedClipInspector(_:)),
             #selector(splitFocusedClipAtPlayhead(_:)),
             #selector(trimFocusedClipStartToPlayhead(_:)),
             #selector(trimFocusedClipEndToPlayhead(_:)),
             #selector(moveFocusedClipEarlier(_:)),
             #selector(moveFocusedClipLater(_:)),
             #selector(duplicateFocusedClip(_:)),
             #selector(renameFocusedClip(_:)),
             #selector(deleteFocusedClip(_:)):
            return canUseFocusedClipCommands
        case #selector(relinkMissingMedia(_:)):
            return clipCommandContext.isEnabled(.relinkMissingMedia)
        case #selector(cancelMissingMediaRelink(_:)):
            return clipCommandContext.isEnabled(.cancelMediaRelink)
        case #selector(exportSelectedRegion(_:)), #selector(exportSelectionFromContextMenu(_:)):
            return currentSelection?.durationProgress ?? 0 > 0
        case #selector(deleteTimelineSelection(_:)):
            return canDeleteSelection
        case #selector(removeTimeRangeAcrossScope(_:)):
            return canDeleteSelection
        case #selector(clearTimelineSelection(_:)):
            return canClearSelection
        case #selector(cutTimelineSelection(_:)), #selector(cut(_:)):
            return canCutSelection || (isAutomationModeVisible && !automationSelection.pointIDs.isEmpty)
        case #selector(copyTimelineSelection(_:)), #selector(copy(_:)):
            return canCopySelection || (isAutomationModeVisible && !automationSelection.pointIDs.isEmpty)
        case #selector(duplicateTimelineRegion(_:)):
            return canCopySelection
        case #selector(pasteTimelineAudio(_:)), #selector(paste(_:)):
            return canPasteAudio || (isAutomationModeVisible && automationSelection.address != nil)
        case #selector(splitAtPlayhead(_:)):
            return canSplitAtPlayhead
        case #selector(insertSilenceAtPlayhead(_:)):
            return canSplitAtPlayhead
        case #selector(healAdjacentClips(_:)):
            return canSplitAtPlayhead
        case #selector(zoomToSelection(_:)):
            return zoomFocusSelection() != nil
        case #selector(toggleAutomationMode(_:)):
            menuItem.state = isAutomationModeVisible ? .on : .off
            return true
        case #selector(selectAutomationPointTool(_:)):
            menuItem.state = automationTool == .point ? .on : .off
            return isAutomationModeVisible
        case #selector(selectAutomationCurveTool(_:)):
            menuItem.state = automationTool == .curve ? .on : .off
            return isAutomationModeVisible
        case #selector(selectAutomationPencilTool(_:)):
            menuItem.state = automationTool == .pencil ? .on : .off
            return isAutomationModeVisible
        case #selector(selectAutomationRampTool(_:)):
            menuItem.state = automationTool == .ramp ? .on : .off
            return isAutomationModeVisible
        case #selector(selectAutomationEraserTool(_:)):
            menuItem.state = automationTool == .eraser ? .on : .off
            return isAutomationModeVisible
        case #selector(setAutomationCurveLinear(_:)),
             #selector(setAutomationCurveEaseIn(_:)),
             #selector(setAutomationCurveEaseOut(_:)),
             #selector(setAutomationCurveSCurve(_:)),
             #selector(setAutomationCurveStepped(_:)):
            return isAutomationModeVisible && !automationSelection.pointIDs.isEmpty
        case #selector(toggleDebugTools(_:)):
            menuItem.state = isDebugToolsVisible ? .on : .off
            return true
        default:
            return true
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isInteractionSuppressed, isFrontmostPointerOwner(for: event) else {
            return
        }

        onPointerPresenceChanged?(true)
        PerformanceSampler.shared.recordTimelineInputEvent(kind: "mouse-entered", at: event.timestamp)
        if updateTimelineEndHover(for: event) {
            return
        }
        if updateLoopHover(for: event) {
            return
        }
        if updateAutomationHover(for: event) {
            return
        }
        if updateSelectionEdgeHover(for: event) {
            return
        }
        if updateClipHover(for: event) {
            return
        }
        if updateTranscriptHover(for: event) {
            return
        }
        updateHoverGuide(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isInteractionSuppressed, isFrontmostPointerOwner(for: event) else {
            return
        }

        PerformanceSampler.shared.recordTimelineInputEvent(kind: "mouse-moved", at: event.timestamp)
        if areEmbeddedScrollbarsEnabled, updateScrollbarHover(for: event) {
            displayClipPropertyHover(nil)
            return
        }
        if updateTimelineEndHover(for: event) {
            displayClipPropertyHover(nil)
            return
        }
        if updateLoopHover(for: event) {
            displayClipPropertyHover(nil)
            return
        }
        if updateAutomationHover(for: event) {
            displayClipPropertyHover(nil)
            return
        }
        if updateSelectionEdgeHover(for: event) {
            displayClipPropertyHover(nil)
            return
        }
        if updateClipHover(for: event) {
            return
        }
        if updateTranscriptHover(for: event) {
            displayClipPropertyHover(nil)
            return
        }
        displayClipPropertyHover(nil)
        updateHoverGuide(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isInteractionSuppressed else {
            return
        }

        onPointerPresenceChanged?(false)
        PerformanceSampler.shared.recordTimelineInputEvent(kind: "mouse-exited", at: event.timestamp)
        displayHoverProgress(nil)
        displayHighlightedSelectionEndpoint(nil)
        displayHighlightedClipEdge(nil)
        displayClipPropertyHover(nil)
        displayHighlightedLoopEndpoint(nil)
        displayHighlightedLoopRegion(false)
        displayAutomationHover(for: nil)
        timelineEndOverlayView.isHandleHovered = false
        setHoveredScrollbarAxis(nil)
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
        if shouldSuppressNavigationGestureForSelectionFocus(event) {
            return
        }
        cancelSelectionFocusTransition()

        let hasGesturePhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        let isGestureEnding =
            event.phase.contains(.ended) ||
            event.phase.contains(.cancelled) ||
            event.momentumPhase.contains(.ended) ||
            event.momentumPhase.contains(.cancelled)
        defer {
            if isGestureEnding || !hasGesturePhase {
                scrollGestureMode = nil
                trackpadPanPreviousTime = nil
                trackpadPanVelocityProgressPerSecond = 0
                flushPendingCursorRectInvalidationIfNeeded()
            }
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let horizontalDelta = event.scrollingDeltaX
        let verticalDelta = event.scrollingDeltaY
        guard horizontalDelta != 0 || verticalDelta != 0 else {
            return
        }

        if modifiers.contains(.command) {
            scrollGestureMode = .zoom
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            stopRightPanMomentum()
            let logScaleDelta = TimelineNavigationWheelGeometry.commandZoomLogScaleDelta(
                scrollingDeltaX: horizontalDelta,
                scrollingDeltaY: verticalDelta,
                hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
            )
            guard logScaleDelta != 0 else {
                return
            }
            let anchorProgress = progress(for: convert(event.locationInWindow, from: nil))
            applyCommandWheelZoomMomentumInput(
                logScaleDelta: logScaleDelta,
                anchorProgress: anchorProgress,
                timestamp: event.timestamp
            )
            onNavigationScrollActivity?(.horizontal)
            return
        }

        let effectiveHorizontalDelta = modifiers.contains(.shift) ?
            TimelineNavigationWheelGeometry.shiftedHorizontalDelta(
                scrollingDeltaX: horizontalDelta,
                scrollingDeltaY: verticalDelta
            ) : horizontalDelta
        let effectiveVerticalDelta = modifiers.contains(.shift) ? 0 : verticalDelta
        scrollGestureMode = .pan

        if modifiers.contains(.shift), !event.hasPreciseScrollingDeltas {
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            stopZoomMomentum()
            applyShiftWheelPanMomentumInput(
                horizontalDeltaPixels: effectiveHorizontalDelta
            )
            onNavigationScrollActivity?(.horizontal)
            return
        }

        let elapsedTime: TimeInterval
        if let trackpadPanPreviousTime {
            elapsedTime = min(max(event.timestamp - trackpadPanPreviousTime, 1 / 240), 1 / 12)
        } else {
            elapsedTime = 1 / 120
        }
        let horizontalProgressDelta = TimelineNavigationPanGeometry.horizontalProgressDelta(
            scrollingDeltaX: effectiveHorizontalDelta,
            viewportWidth: bounds.width,
            viewportDurationProgress: settledViewport.durationProgress
        )
        let instantVelocity = horizontalProgressDelta / Float(elapsedTime)
        trackpadPanVelocityProgressPerSecond =
            trackpadPanVelocityProgressPerSecond * 0.54 + instantVelocity * 0.46
        trackpadPanPreviousTime = event.timestamp
        displayHoverProgress(nil, renderCadence: .coalescedInteraction)
        stopRightPanMomentum()
        applyTwoDimensionalPan(
            horizontalDeltaPixels: effectiveHorizontalDelta,
            verticalDeltaPixels: effectiveVerticalDelta
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
        if shouldSuppressNavigationGestureForSelectionFocus(event) {
            return
        }
        cancelSelectionFocusTransition()

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

        scrollGestureMode = .zoom

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
        cancelSelectionFocusTransition()
        stopRightPanMomentum()
        stopZoomMomentum()
        onTimelineInteractionBegan?()
        clearLiveSelectionDragSnapshot()
        edgeAutoPanLastTimestamp = nil
        displayLoopMoveGuides(false)
        let point = convert(event.locationInWindow, from: nil)
        let timelineProgress = progress(for: point)
        if timelineEndHandleHit(at: point) {
            activeDragMode = .timelineEnd
            selectionAnchorProgress = Double(timelineProgress)
            selectionAnchorPoint = point
            selectionAnchorTrackID = nil
            startTimelineDisplayLink()
            timelineEndOverlayView.isHandleHovered = true
            NSCursor.resizeLeftRight.set()
            return
        }
        if areEmbeddedScrollbarsEnabled, let scrollbarAxis = currentScrollbarGeometry().axis(at: point) {
            let geometry = currentScrollbarGeometry()
            activeScrollbarAxis = scrollbarAxis
            activeDragMode = scrollbarAxis == .horizontal ? .horizontalScrollbar : .verticalScrollbar
            let handle = scrollbarAxis == .horizontal ? geometry.horizontalHandle : geometry.verticalHandle
            activeScrollbarDragOffset = scrollbarAxis == .horizontal ?
                point.x - handle.minX : point.y - handle.minY
            selectionAnchorProgress = Double(timelineProgress)
            selectionAnchorPoint = point
            selectionAnchorTrackID = nil
            setHoveredScrollbarAxis(scrollbarAxis)
            NSCursor.closedHand.set()
            return
        }
        if let loopDragMode = loopDragMode(for: point) {
            if loopDragMode == .loopRegion, !loopRegionContains(point) {
                displayHoverProgress(
                    timelineProgress,
                    isArmed: true,
                    guideSpan: hoverGuideSpan(for: loopInteractionBandRect())
                )
            } else {
                displayHoverProgress(nil)
            }
            if let endpoint = loopEndpoint(for: loopDragMode) {
                displayHighlightedLoopEndpoint(endpoint)
                let handleProgress = endpoint == .start ? loopRange.startProgress : loopRange.endProgress
                activeLoopResizeFixedProgress = endpoint == .start ?
                    loopRange.endProgress :
                    loopRange.startProgress
                if let handleX = loopHandleX(forTimelineProgress: handleProgress) {
                    activeLoopDragOffsetX = point.x - handleX
                } else {
                    activeLoopDragOffsetX = 0
                }
            } else {
                activeLoopDragOffsetX = 0
                activeLoopResizeFixedProgress = nil
                displayHighlightedLoopEndpoint(nil)
                displayHighlightedLoopRegion(loopRegionContains(point))
                if loopDragMode == .moveLoopRegion {
                    activeLoopMoveInitialRange = loopRange
                    NSCursor.closedHand.set()
                } else {
                    activeLoopMoveInitialRange = nil
                }
            }
            activeDragMode = loopDragMode
            selectionAnchorProgress = Double(progress(for: loopDragProgressPoint(from: point), followsVisualFisheye: false))
            selectionAnchorPoint = point
            selectionAnchorTrackID = nil
            isDraggingSelection = false
            isDraggingLoop = false
            return
        }
        activeLoopDragOffsetX = 0
        activeLoopResizeFixedProgress = nil
        activeLoopMoveInitialRange = nil
        displayHighlightedLoopEndpoint(nil)
        displayHighlightedLoopRegion(false)

        if let gutter = seekGutterHit(at: point) {
            activeDragMode = .seek
            selectionAnchorProgress = Double(timelineProgress)
            selectionAnchorPoint = point
            selectionAnchorTrackID = nil
            isDraggingSelection = false
            isDraggingLoop = false
            displayHoverProgress(
                timelineProgress,
                isArmed: true,
                guideSpan: gutter.span
            )
            return
        }

        if isAutomationModeVisible, let hit = automationHit(at: point) {
            activeAutomationHit = hit
            activeAutomationPoints = hit.points
            activeAutomationDidDrag = false
            activeAutomationMouseDownModifierFlags = event.modifierFlags.intersection(
                .deviceIndependentFlagsMask
            )
            selectionAnchorProgress = hit.projectProgress
            selectionAnchorPoint = point
            selectionAnchorTrackID = hit.trackID
            isDraggingSelection = false
            isDraggingLoop = false
            if event.modifierFlags.contains(.command) {
                switch hit.kind {
                case .point:
                    break
                case .segment, .fence, .lane:
                    let address = TimelineAutomationAddress.track(
                        hit.trackID,
                        parameterID: TimelineAutomationParameterID(rawValue: hit.parameterID)
                    )
                    automationMarqueeBaseSelection = automationSelection.address == address ?
                        automationSelection : .empty
                    activeDragMode = .automationMarquee
                    displayAutomationMarquee(from: point, to: point)
                    NSCursor.crosshair.set()
                    displayHoverProgress(nil)
                    return
                }
            }
            switch automationTool {
            case .pencil:
                activeDragMode = .automationPencil
                activeAutomationDrawSamples = [TimelineAutomationDrawPresentationSample(
                    frameProgress: hit.projectProgress,
                    normalizedValue: hit.normalizedValue
                )]
                lastAutomationDrawPoint = point
                displayAutomationPreview(points: automationDrawingPreviewPoints(for: hit), hit: hit)
                NSCursor.crosshair.set()
                displayHoverProgress(nil)
                return
            case .ramp:
                activeDragMode = .automationRamp
                activeAutomationDrawSamples = [TimelineAutomationDrawPresentationSample(
                    frameProgress: hit.projectProgress,
                    normalizedValue: hit.normalizedValue
                )]
                lastAutomationDrawPoint = point
                displayAutomationPreview(points: automationDrawingPreviewPoints(for: hit), hit: hit)
                NSCursor.crosshair.set()
                displayHoverProgress(nil)
                return
            case .eraser:
                activeDragMode = .automationEraser
                activeAutomationErasedPointIDs.removeAll(keepingCapacity: true)
                if case let .point(pointID) = hit.kind { activeAutomationErasedPointIDs.insert(pointID) }
                displayAutomationPreview(
                    points: hit.points.filter { !activeAutomationErasedPointIDs.contains($0.id) },
                    hit: hit
                )
                NSCursor.disappearingItem.set()
                displayHoverProgress(nil)
                return
            case .point, .curve:
                break
            }
            switch hit.kind {
            case let .point(pointID):
                updateAutomationSelection(
                    pointID: pointID,
                    hit: hit,
                    modifierFlags: event.modifierFlags
                )
                activeDragMode = .automationPoint
                NSCursor.pointingHand.set()
            case let .segment(pointID) where automationTool == .curve:
                if event.clickCount >= 2 {
                    onAutomationEditRequested?(TimelineAutomationEditRequest(
                        trackID: hit.trackID,
                        parameterID: hit.parameterID,
                        action: .setCurvePreset(pointIDs: [pointID], preset: .linear)
                    ))
                    activeAutomationHit = nil
                    activeAutomationPoints.removeAll(keepingCapacity: true)
                    selectionAnchorPoint = nil
                    return
                }
                activeDragMode = .automationCurve
                NSCursor.resizeUpDown.set()
            case .segment, .fence, .lane:
                activeDragMode = .automationPoint
                displayAutomationPreview(points: pointsAddingAutomationPoint(from: hit), hit: hit)
                NSCursor.crosshair.set()
            }
            displayHoverProgress(nil)
            return
        }

        if event.clickCount >= 2, let request = clipFocusRequest(at: point) {
            if !request.trackLocalRange.isSelected {
                onClipSelected?(request, .replace)
            }
            displayHoverProgress(nil)
            displayHighlightedSelectionEndpoint(nil)
            selectionAnchorProgress = nil
            selectionAnchorPoint = nil
            selectionAnchorTrackID = nil
            activeDragMode = nil
            activeSelectionDragOffsetX = 0
            activeClipRequest = nil
            activeClipRequests = []
            isDraggingSelection = false
            isDraggingLoop = false
            onClipDoubleClicked?(request)
            return
        }

        if
            let selection = currentSelection,
            let endpointHit = selectionEndpointHit(at: point)
        {
            let endpoint = endpointHit.endpoint
            displayHoverProgress(nil)
            displayHighlightedSelectionEndpoint(endpoint)
            NSCursor.resizeLeftRight.set()
            activeDragMode = endpoint == .start ? .resizeSelectionStart : .resizeSelectionEnd
            selectionAnchorProgress = TimelineSelectionResizeInteraction.fixedProgress(
                for: endpoint,
                selection: selection
            )
            selectionAnchorPoint = point
            selectionAnchorTrackID = selection.trackID
            activeSelectionDragOffsetX = point.x - endpointHit.handleX
            resetSelectionDragVelocity(at: point, timestamp: CACurrentMediaTime())
            isDraggingSelection = false
            isDraggingLoop = false
            return
        }
        activeSelectionDragOffsetX = 0
        displayHighlightedSelectionEndpoint(nil)

        let togglesClipSelection = event.modifierFlags.contains(.command)
        let extendsClipSelection = event.modifierFlags.contains(.shift)
        if let propertyHit = clipPropertyHit(at: point) {
            if !propertyHit.request.trackLocalRange.isSelected {
                onClipSelected?(propertyHit.request, .replace)
            }
            activeClipRequest = propertyHit.request
            activeClipRequests = [propertyHit.request]
            activeClipPropertyControl = propertyHit.control
            activeClipPropertyPreview = propertyHit.preview
            activeDragMode = propertyHit.control == .fadeIn ? .clipFadeIn : .clipFadeOut
            selectionAnchorProgress = Double(timelineProgress)
            selectionAnchorPoint = point
            selectionAnchorTrackID = propertyHit.request.trackID
            isDraggingSelection = false
            NSCursor.resizeLeftRight.set()
            displayHoverProgress(nil)
            return
        }
        if let clipHit = clipHit(at: point) {
            let key = TimelineClipSelectionKey(clipHit.request)
            let wasSelected = clipHit.request.trackLocalRange.isSelected
            if togglesClipSelection || extendsClipSelection || !wasSelected {
                onClipSelected?(
                    clipHit.request,
                    togglesClipSelection ? .toggle : (extendsClipSelection ? .range : .replace)
                )
            }
            if togglesClipSelection, wasSelected {
                selectionAnchorProgress = nil
                selectionAnchorPoint = nil
                selectionAnchorTrackID = nil
                activeDragMode = nil
                activeClipRequest = nil
                activeClipRequests = []
                displayHoverProgress(nil)
                return
            }
            activeClipRequest = clipHit.request
            selectionAnchorProgress = Double(timelineProgress)
            selectionAnchorPoint = point
            selectionAnchorTrackID = clipHit.request.trackID
            isDraggingSelection = false
            isDraggingLoop = false
            if let edge = clipHit.edge {
                activeClipRequests = [clipHit.request]
                activeClipDragOffsetProgress = 0
                activeDragMode = edge == .leading ? .trimClipStart : .trimClipEnd
                NSCursor.resizeLeftRight.set()
            } else {
                var requests = selectedClipFocusRequests()
                if !wasSelected && !togglesClipSelection && !extendsClipSelection {
                    requests = [clipHit.request]
                } else if !requests.contains(where: { TimelineClipSelectionKey($0) == key }) {
                    requests.append(clipHit.request)
                }
                activeClipRequests = requests.isEmpty ? [clipHit.request] : requests
                activeClipDragOffsetProgress = timelineProgress - clipHit.request.projectStartProgress
                activeClipDragDuplicates = event.modifierFlags.contains(.option)
                activeDragMode = .moveClip
                NSCursor.closedHand.set()
            }
            prepareClipDragInteractionContext()
            displayHoverProgress(nil)
            return
        }

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
            activeSelectionDragOffsetX = 0
            isDraggingSelection = false
            isDraggingLoop = false
            return
        }

        if event.modifierFlags.contains(.command) {
            activeDragMode = .clipMarquee
            selectionAnchorProgress = Double(timelineProgress)
            selectionAnchorPoint = point
            selectionAnchorTrackID = nil
            isDraggingSelection = false
            displayHoverProgress(nil)
            return
        }

        onClipSelected?(nil, .replace)
        activeDragMode = .selection
        selectionAnchorProgress = preciseProgress(for: point)
        selectionAnchorPoint = point
        selectionAnchorTrackID = trackID(at: point)
        resetSelectionDragVelocity(at: point, timestamp: CACurrentMediaTime())
        isDraggingSelection = false
        isDraggingLoop = false
        displayHoverProgress(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isInteractionSuppressed else {
            return
        }

        let usesDisplayPacedPointerSampling = isDraggingSelection || isDraggingLoop || isAutomationDragActive
        if !usesDisplayPacedPointerSampling {
            PerformanceSampler.shared.recordTimelineInputEvent(kind: "mouse-dragged", at: event.timestamp)
        }
        if let activeTranscriptDrag {
            updateTranscriptDrag(activeTranscriptDrag, with: currentDragPoint(for: event))
            return
        }

        guard
            isSelectionEnabled,
            selectionAnchorProgress != nil
        else {
            super.mouseDragged(with: event)
            return
        }

        let point = currentDragPoint(for: event)
        if activeDragMode == .seek {
            let guideSpan = selectionAnchorPoint.flatMap { seekGutterHit(at: $0)?.span }
            displayHoverProgress(
                progress(for: point),
                isArmed: true,
                guideSpan: guideSpan,
                renderCadence: .coalescedInteraction
            )
            return
        }
        if isAutomationDragActive {
            if didMovePastSelectionThreshold(to: point) {
                activeAutomationDidDrag = true
            }
            // Drag events can arrive several times per display refresh. Keep
            // only the latest pointer position and let the display link build
            // one preview for each frame that can actually be presented.
            wakeDisplayPacedInteractionSampler()
            return
        }
        if activeDragMode == .timelineEnd {
            updateTimelineEndDrag(to: point)
            timelineEndOverlayView.isHandleHovered = true
            NSCursor.resizeLeftRight.set()
            return
        }
        if
            activeDragMode == .moveClip ||
                activeDragMode == .trimClipStart ||
                activeDragMode == .trimClipEnd
        {
            if didMovePastSelectionThreshold(to: point) {
                if !isDraggingSelection {
                    isDraggingSelection = true
                    edgeAutoPanLastTimestamp = nil
                    startTimelineDisplayLink()
                }
                // Raw pointer events only keep the display-paced sampler awake. The sampler owns
                // the one validation and preview publication for each frame that can be shown.
                wakeDisplayPacedInteractionSampler()
                if activeDragMode == .moveClip {
                    (activeClipPlacementIsAllowed ? NSCursor.closedHand : NSCursor.operationNotAllowed).set()
                } else {
                    NSCursor.resizeLeftRight.set()
                }
            }
            return
        }
        if activeDragMode == .clipMarquee {
            if !isDraggingSelection, didMovePastSelectionThreshold(to: point) {
                isDraggingSelection = true
            }
            if isDraggingSelection {
                displayClipMarquee(from: selectionAnchorPoint, to: point)
            }
            return
        }
        if
            activeDragMode == .clipFadeIn ||
                activeDragMode == .clipFadeOut
        {
            if didMovePastSelectionThreshold(to: point) {
                isDraggingSelection = true
            }
            if isDraggingSelection {
                updateClipPropertyPreview(to: point)
                NSCursor.resizeLeftRight.set()
            }
            return
        }
        if activeDragMode == .horizontalScrollbar || activeDragMode == .verticalScrollbar {
            updateScrollbarDrag(to: point)
            NSCursor.closedHand.set()
            return
        }
        if
            activeDragMode == .loopStart ||
                activeDragMode == .loopEnd ||
                activeDragMode == .loopRegion ||
                activeDragMode == .moveLoopRegion
        {
            if activeDragMode != .loopRegion {
                displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            }
            let crossedLoopDragThreshold = activeDragMode == .loopRegion ?
                didMovePastRegionCreationThreshold(to: point) :
                didMovePastSelectionThreshold(to: point)
            if !isDraggingLoop, crossedLoopDragThreshold {
                isDraggingLoop = true
                startTimelineDisplayLink()
                if activeDragMode == .loopStart || activeDragMode == .loopEnd {
                    edgeAutoPanLastTimestamp = nil
                }
                if activeDragMode == .loopRegion {
                    setLoopRangeEnabled(true, notifyChange: true)
                }
                if activeDragMode == .loopRegion || activeDragMode == .moveLoopRegion {
                    displayHighlightedLoopRegion(true, renderCadence: .coalescedInteraction)
                    displayLoopMoveGuides(
                        activeDragMode == .moveLoopRegion,
                        renderCadence: .coalescedInteraction
                    )
                }
            }

            // The display link samples the physical pointer and publishes one loop update per
            // presentable frame. Mouse hardware can otherwise flood this path far above 144 Hz.
            wakeDisplayPacedInteractionSampler()
            return
        }

        if
            activeDragMode == .resizeSelectionStart ||
                activeDragMode == .resizeSelectionEnd
        {
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            if !isDraggingSelection, didMovePastSelectionThreshold(to: point) {
                isDraggingSelection = true
                edgeAutoPanLastTimestamp = nil
                resetSelectionDragVelocity(at: point, timestamp: CACurrentMediaTime())
                startTimelineDisplayLink()
            }

            if isDraggingSelection {
                // Selection geometry is sampled once at display cadence. Publishing both here and
                // from the display link causes lock contention and unstable velocity samples.
                wakeDisplayPacedInteractionSampler()
            }
            return
        }

        if !isDraggingSelection, didMovePastRegionCreationThreshold(to: point) {
            isDraggingSelection = true
            resetSelectionDragVelocity(at: point, timestamp: CACurrentMediaTime())
            startTimelineDisplayLink()
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
        }

        if isDraggingSelection {
            wakeDisplayPacedInteractionSampler()
        } else {
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
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
            if
                !updateLoopHover(for: event),
                !updateSelectionEdgeHover(for: event),
                !updateTranscriptHover(for: event)
            {
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
        if activeDragMode == .seek {
            onSeekRequested?(timelineProgress)
            let guideSpan = selectionAnchorPoint.flatMap { seekGutterHit(at: $0)?.span }
            displayHoverProgress(
                timelineProgress,
                guideSpan: guideSpan
            )
        } else if activeDragMode == .automationPoint ||
            activeDragMode == .automationCurve ||
            activeDragMode == .automationMarquee {
            finishAutomationInteraction(at: point)
        } else if activeDragMode == .timelineEnd {
            updateTimelineEndDrag(to: point)
            NSCursor.resizeLeftRight.set()
        } else if
            let request = activeClipRequest,
            (activeDragMode == .moveClip ||
                activeDragMode == .trimClipStart ||
                activeDragMode == .trimClipEnd)
        {
            if isDraggingSelection {
                // Mouse-up can arrive between display ticks. Sample its exact position once before
                // committing so display pacing never trades away drop accuracy.
                updateClipDragPreview(to: point, renderCadence: .none)
                if activeDragMode == .moveClip, activeClipPlacementIsAllowed {
                    onClipDragCommitted?(activeClipDragPreviews, activeClipDragDuplicates)
                } else {
                    let destination = activeDragMode == .trimClipStart ?
                        activeClipDragPreviews.first?.presentedStartProjectProgress :
                        activeClipDragPreviews.first?.presentedEndProjectProgress
                    onClipTrimmed?(
                        request,
                        activeDragMode == .trimClipStart ? .leading : .trailing,
                        destination ?? progress(for: point, followsVisualFisheye: false)
                    )
                }
            }
            displayClipDragPreviews([])
            activeClipSnapGuideProgress = nil
            activeClipPlacementIsAllowed = true
            displayHoverProgress(nil)
        } else if activeDragMode == .clipMarquee {
            if isDraggingSelection {
                let requests = clipFocusRequests(intersecting: marqueeRect(from: selectionAnchorPoint, to: point))
                onClipMarqueeSelected?(requests, .additive)
            }
            displayClipMarquee(from: nil, to: nil)
        } else if
            let request = activeClipRequest,
            activeDragMode == .clipFadeIn ||
                activeDragMode == .clipFadeOut
        {
            if isDraggingSelection, let preview = activeClipPropertyPreview {
                onClipPropertiesChanged?(request, preview)
            }
            displayClipPropertyPreview(nil)
        } else if activeDragMode == .horizontalScrollbar || activeDragMode == .verticalScrollbar {
            updateScrollbarDrag(to: point)
            activeScrollbarAxis = nil
            activeScrollbarDragOffset = 0
            if let axis = currentScrollbarGeometry().axis(at: point) {
                setHoveredScrollbarAxis(axis)
                NSCursor.openHand.set()
            } else {
                setHoveredScrollbarAxis(nil)
                NSCursor.arrow.set()
            }
        } else if
            activeDragMode == .loopStart ||
                activeDragMode == .loopEnd ||
                activeDragMode == .loopRegion ||
                activeDragMode == .moveLoopRegion
        {
            if let activeDragMode {
                let dragProgress = progress(for: loopDragProgressPoint(from: point), followsVisualFisheye: false)
                if activeDragMode == .loopRegion {
                    if isDraggingLoop {
                        updateLoopRegionRange(
                            from: Float(selectionAnchorProgress),
                            to: dragProgress,
                            notifiesChange: false
                        )
                        onLoopRangeChanged?(loopRange)
                    } else if loopRegionContains(point) {
                        setLoopRangeEnabled(!isLoopRangeEnabled, notifyChange: true)
                    }
                    displayHoverProgress(nil)
                } else if activeDragMode == .moveLoopRegion {
                    if isDraggingLoop, let activeLoopMoveInitialRange {
                        updateMovingLoopRange(
                            initialRange: activeLoopMoveInitialRange,
                            anchorProgress: Float(selectionAnchorProgress),
                            currentProgress: dragProgress,
                            notifiesChange: false
                        )
                        onLoopRangeChanged?(loopRange)
                    } else if loopRegionContains(point) {
                        setLoopRangeEnabled(!isLoopRangeEnabled, notifyChange: true)
                    }
                    displayHoverProgress(nil)
                } else {
                    _ = updateLoopRange(
                        for: activeDragMode,
                        progress: dragProgress,
                        enforcesMinimumDuration: true,
                        notifiesChange: false
                    )
                    onLoopRangeChanged?(loopRange)
                }
            }
        } else if
            activeDragMode == .resizeSelectionStart ||
                activeDragMode == .resizeSelectionEnd
        {
            if isDraggingSelection {
                let dragProgress = preciseProgress(for: selectionResizeProgressPoint(from: point))
                updateSelection(
                    from: selectionAnchorProgress,
                    to: dragProgress,
                    notifyChange: true
                )
                startSelectionDragRenderPulse(duration: selectionDragWaveformRenderPulseDuration)
            }
        } else if isDraggingSelection {
            updateSelection(from: selectionAnchorProgress, to: preciseProgress(for: point), notifyChange: true)
            startSelectionDragRenderPulse(duration: selectionDragWaveformRenderPulseDuration)
        } else {
            displaySelection(nil)
            onSelectionChanged?(nil)
        }

        if activeDragMode == .moveLoopRegion {
            if loopRegionEndpointNear(point) != nil {
                NSCursor.resizeLeftRight.set()
            } else if loopRegionContains(point) {
                NSCursor.openHand.set()
            } else if loopInteractionBandRect().contains(point) {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        if
            activeDragMode == .loopStart ||
                activeDragMode == .loopEnd ||
                activeDragMode == .loopRegion ||
                activeDragMode == .moveLoopRegion
        {
            invalidateTimelineCursorRects()
        }

        self.selectionAnchorProgress = nil
        selectionAnchorPoint = nil
        selectionAnchorTrackID = nil
        resetSelectionDragVelocity()
        activeDragMode = nil
        activeSelectionDragOffsetX = 0
        displayClipDragPreviews([])
        activeClipPlacementIsAllowed = true
        activeClipRequest = nil
        activeClipRequests = []
        activeClipDragOffsetProgress = 0
        activeClipDragDuplicates = false
        clearClipDragInteractionContext()
        activeClipPropertyControl = nil
        activeClipPropertyPreview = nil
        displayClipMarquee(from: nil, to: nil)
        edgeAutoPanLastTimestamp = nil
        isDraggingSelection = false
        isDraggingLoop = false
        activeLoopDragOffsetX = 0
        activeLoopResizeFixedProgress = nil
        activeLoopMoveInitialRange = nil
        displayLoopMoveGuides(false)
        edgeAutoPanLastTimestamp = nil
        flushPendingCursorRectInvalidationIfNeeded()
        if
            !updateTimelineEndHover(for: event),
            !updateLoopHover(for: event),
            !updateAutomationHover(for: event),
            !updateSelectionEdgeHover(for: event),
            !updateClipHover(for: event)
        {
            updateHoverGuide(for: event)
        }
        stopTimelineDisplayLinkIfIdle()
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
        stopRightPanMomentum()
        stopZoomMomentum()
        let dragPoint = currentDragPoint(for: event)
        rightPanInitialPoint = dragPoint
        rightPanPreviousPoint = dragPoint
        rightPanPreviousTime = event.timestamp
        rightPanLastMovementTime = nil
        rightPanVelocityProgressPerSecond = 0
        isRightPanGestureActive = false
        isSelectionContextMenuArmed = shouldShowSelectionContextMenu(at: point)
        armedClipContextRequest = isSelectionContextMenuArmed ? nil : clipHit(at: point)?.request
        selectionAnchorProgress = nil
        selectionAnchorPoint = nil
        selectionAnchorTrackID = nil
        activeDragMode = nil
        activeSelectionDragOffsetX = 0
        isDraggingSelection = false
        isDraggingLoop = false
        displayHoverProgress(nil)
        displayLoopMoveGuides(false)
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

    private func showSelectionContextMenu(at point: CGPoint) {
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

        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func exportSelectionFromContextMenu(_ sender: Any?) {
        onSelectionRegionContextExportRequested?()
    }

    private func showClipContextMenu(
        for request: TimelineClipFocusRequest,
        at point: CGPoint
    ) {
        contextMenuClipRequest = request
        let menu = NSMenu(title: "Clip")
        let actions: [(String, Selector, String)] = [
            ("Open Clip Inspector", #selector(openClipFromContextMenu(_:)), ""),
            ("Export Clip as WAV...", #selector(exportClipWAVFromContextMenu(_:)), ""),
            ("Rename Clip...", #selector(renameClipFromContextMenu(_:)), ""),
            ("Duplicate Clip", #selector(duplicateClipFromContextMenu(_:)), ""),
            ("Repeat Selected Clips", #selector(repeatClipsFromContextMenu(_:)), ""),
            ("Mute / Unmute Selected Clips", #selector(toggleMuteFromContextMenu(_:)), ""),
            ("Lock / Unlock Selected Clips", #selector(toggleLockFromContextMenu(_:)), ""),
            ("Group Selected Clips", #selector(groupClipsFromContextMenu(_:)), ""),
            ("Ungroup Selected Clips", #selector(ungroupClipsFromContextMenu(_:)), ""),
            (
                request.trackLocalRange.fadeInProgress > 0 ? "Disable Crossfade In" : "Enable Crossfade In",
                #selector(toggleCrossfadeInFromContextMenu(_:)),
                ""
            ),
            (
                request.trackLocalRange.fadeOutProgress > 0 ? "Disable Crossfade Out" : "Enable Crossfade Out",
                #selector(toggleCrossfadeOutFromContextMenu(_:)),
                ""
            ),
            ("Crossfade Selected Clips", #selector(crossfadeClipsFromContextMenu(_:)), ""),
            ("Split at Playhead", #selector(splitClipFromContextMenu(_:)), ""),
            ("Delete Clip", #selector(deleteClipFromContextMenu(_:)), "")
        ]
        for (index, action) in actions.enumerated() {
            if index == actions.count - 1 {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: action.0, action: action.1, keyEquivalent: action.2)
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: self)
        contextMenuClipRequest = nil
    }

    private func performClipContextAction(_ action: TimelineClipContextAction) {
        guard let request = contextMenuClipRequest else {
            return
        }
        onClipContextAction?(request, action)
    }

    @objc private func openClipFromContextMenu(_ sender: Any?) {
        performClipContextAction(.open)
    }

    @objc private func exportClipWAVFromContextMenu(_ sender: Any?) {
        performClipContextAction(.exportWAV)
    }

    @objc private func renameClipFromContextMenu(_ sender: Any?) {
        performClipContextAction(.rename)
    }

    @objc private func duplicateClipFromContextMenu(_ sender: Any?) {
        performClipContextAction(.duplicate)
    }

    @objc private func repeatClipsFromContextMenu(_ sender: Any?) {
        performClipContextAction(.repeatClips)
    }

    @objc private func toggleMuteFromContextMenu(_ sender: Any?) {
        performClipContextAction(.toggleMute)
    }

    @objc private func toggleLockFromContextMenu(_ sender: Any?) {
        performClipContextAction(.toggleLock)
    }

    @objc private func groupClipsFromContextMenu(_ sender: Any?) {
        performClipContextAction(.group)
    }

    @objc private func ungroupClipsFromContextMenu(_ sender: Any?) {
        performClipContextAction(.ungroup)
    }

    @objc private func toggleCrossfadeInFromContextMenu(_ sender: Any?) {
        performClipContextAction(.toggleCrossfadeIn)
    }

    @objc private func toggleCrossfadeOutFromContextMenu(_ sender: Any?) {
        performClipContextAction(.toggleCrossfadeOut)
    }

    @objc private func crossfadeClipsFromContextMenu(_ sender: Any?) {
        performClipContextAction(.crossfade)
    }

    @objc private func splitClipFromContextMenu(_ sender: Any?) {
        performClipContextAction(.splitAtPlayhead)
    }

    @objc private func deleteClipFromContextMenu(_ sender: Any?) {
        performClipContextAction(.delete)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard !isInteractionSuppressed else {
            return
        }

        PerformanceSampler.shared.recordTimelineInputEvent(kind: "right-mouse-dragged", at: event.timestamp)
        guard
            isSelectionEnabled,
            let initialPoint = rightPanInitialPoint,
            let previousPoint = rightPanPreviousPoint,
            bounds.width > 0
        else {
            super.rightMouseDragged(with: event)
            return
        }

        let point = currentDragPoint(for: event)
        if !isRightPanGestureActive {
            guard TimelineSecondaryButtonGesture.hasCrossedPanThreshold(
                anchorX: initialPoint.x,
                currentX: point.x
            ) else {
                return
            }

            isRightPanGestureActive = true
            isSelectionContextMenuArmed = false
            armedClipContextRequest = nil
            onTimelineInteractionBegan?()
        }

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
            onNavigationScrollActivity?(.horizontal)
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

        let point = convert(event.locationInWindow, from: nil)
        let didPan = isRightPanGestureActive
        let shouldPresentContextMenu =
            TimelineSecondaryButtonGesture.shouldPresentContextMenu(
                wasEligibleAtMouseDown: isSelectionContextMenuArmed,
                didPan: didPan
            ) &&
            shouldShowSelectionContextMenu(at: point)
        let clipContextRequest = didPan ? nil : armedClipContextRequest

        if didPan, let lastMovementTime = rightPanLastMovementTime {
            let idleTime = max(event.timestamp - lastMovementTime, 0)
            let decayWindow = min(idleTime, rightPanMomentumReleaseWindow)
            let decay = Float(exp(-rightPanStationaryDecayRate * decayWindow))
            rightPanVelocityProgressPerSecond *= decay
        } else {
            rightPanVelocityProgressPerSecond = 0
        }

        resetRightPanGestureState()
        flushPendingCursorRectInvalidationIfNeeded()
        if didPan {
            startRightPanMomentumIfNeeded()
        }
        updateHoverGuide(for: event)
        if shouldPresentContextMenu {
            showSelectionContextMenu(at: point)
        } else if let clipContextRequest {
            showClipContextMenu(for: clipContextRequest, at: point)
        }
    }

    private func resetRightPanGestureState() {
        rightPanPreviousPoint = nil
        rightPanInitialPoint = nil
        rightPanPreviousTime = nil
        rightPanLastMovementTime = nil
        isRightPanGestureActive = false
        isSelectionContextMenuArmed = false
        armedClipContextRequest = nil
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

    private func applyShiftWheelPanMomentumInput(
        horizontalDeltaPixels: CGFloat
    ) {
        guard bounds.width > 0, horizontalDeltaPixels != 0 else {
            return
        }

        activeCameraTransition = nil
        settledViewport = viewport
        stopRightPanMomentum(clearVelocity: false)

        let progressDelta = TimelineNavigationPanGeometry.horizontalProgressDelta(
            scrollingDeltaX: horizontalDeltaPixels,
            viewportWidth: bounds.width,
            viewportDurationProgress: viewport.durationProgress
        )
        rightPanVelocityProgressPerSecond +=
            TimelineNavigationWheelGeometry.shiftedPanVelocityImpulse(
                progressDelta: progressDelta,
                momentumDecayRate: rightPanMomentumDecayRate
            )
        rightPanLastMovementTime = CACurrentMediaTime()
        startRightPanMomentumIfNeeded()
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
        onNavigationScrollActivity?(.horizontal)
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

    private func applyCommandWheelZoomMomentumInput(
        logScaleDelta: Float,
        anchorProgress: Float,
        timestamp: TimeInterval
    ) {
        guard logScaleDelta != 0 else {
            return
        }

        activeCameraTransition = nil
        settledViewport = viewport
        zoomMomentumAnchorProgress = anchorProgress
        let velocityImpulse = TimelineNavigationWheelGeometry.commandZoomVelocityImpulse(
            logScaleDelta: logScaleDelta,
            momentumDecayRate: zoomMomentumDecayRate
        )
        zoomVelocityLogScalePerSecond = min(
            max(
                zoomVelocityLogScalePerSecond + velocityImpulse,
                -zoomMomentumMaximumVelocity
            ),
            zoomMomentumMaximumVelocity
        )
        zoomPreviousTime = timestamp
        zoomLastInputTime = timestamp

        if zoomMomentumTimer == nil {
            startZoomMomentumIfNeeded()
        }
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
        activeCameraTransition = nil
        activeTrackScrollTransition = nil
        settledViewport = nextViewport
        applyViewport(
            nextViewport,
            kicksImmediateRender: kicksImmediateRender,
            transcriptCadence: transcriptCadence,
            invalidatesCursorRects: invalidatesCursorRects,
            renderCadence: renderCadence,
            marksInteraction: marksInteraction,
            notifiesChange: true
        )
    }

    private func cancelSelectionFocusTransition() {
        if activeCameraTransition != nil {
            activeCameraTransition = nil
            settledViewport = viewport
            onViewportChanged?(viewport)
        }
        activeTrackScrollTransition = nil
    }

    private func shouldSuppressNavigationGestureForSelectionFocus(_ event: NSEvent) -> Bool {
        guard suppressesNavigationGestureForSelectionFocus else {
            return false
        }
        if event.phase.contains(.began) {
            suppressesNavigationGestureForSelectionFocus = false
            return false
        }

        let hasGesturePhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        let isGestureEnding =
            event.phase.contains(.ended) ||
            event.phase.contains(.cancelled) ||
            event.momentumPhase.contains(.ended) ||
            event.momentumPhase.contains(.cancelled)
        if isGestureEnding || !hasGesturePhase {
            suppressesNavigationGestureForSelectionFocus = false
            scrollGestureMode = nil
            trackpadPanPreviousTime = nil
            trackpadPanVelocityProgressPerSecond = 0
            flushPendingCursorRectInvalidationIfNeeded()
        }
        return true
    }

    private func applyViewport(
        _ nextViewport: TimelineViewport,
        kicksImmediateRender: Bool,
        transcriptCadence: TimelineRenderCadence,
        invalidatesCursorRects: Bool,
        renderCadence: TimelineRenderCadence,
        marksInteraction: Bool,
        notifiesChange: Bool,
        updatesTranscript: Bool = true
    ) {
        guard viewport != nextViewport else {
            return
        }

        viewport = nextViewport
        updateBootstrapWaveformView()
        updateClipLabelOverlay()
        updateTimelineEndOverlay()
        updateOffscreenPlayheadButtons()
        onNavigationPresentationChanged?()
        if notifiesChange {
            onViewportChanged?(nextViewport)
        }
        if marksInteraction {
            timelineRenderer?.publishInteractionViewport(nextViewport)
        }
        if updatesTranscript {
            if transcriptCadence != .immediate {
                transcriptViewportRelayoutAllowedUntil = CACurrentMediaTime() + 0.18
            }
            updateTranscriptOverlay(cadence: transcriptCadence)
        }
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

    private func beginCameraTransition(
        from sourceCamera: TimelineCameraWindow,
        to targetViewport: TimelineViewport,
        projectDuration: TimeInterval,
        startTimestamp: CFTimeInterval = CACurrentMediaTime(),
        tuning: TimelineCameraTransition.Tuning = .editReframe,
        initialVelocity: TimelineCameraVelocity? = nil
    ) {
        let targetCamera = TimelineCameraWindow(
            viewport: targetViewport,
            projectDuration: projectDuration
        )
        let transition = TimelineCameraTransition(
            source: sourceCamera,
            target: targetCamera,
            startTimestamp: startTimestamp,
            tuning: tuning,
            initialVelocity: initialVelocity
        )
        settledViewport = targetViewport
        guard transition.isMeaningful(viewportWidth: bounds.width) else {
            activeCameraTransition = nil
            applyViewport(
                targetViewport,
                kicksImmediateRender: false,
                transcriptCadence: .immediate,
                invalidatesCursorRects: true,
                renderCadence: .immediate,
                marksInteraction: false,
                notifiesChange: true
            )
            return
        }

        activeCameraTransition = transition
        let sourceViewport = TimelineViewport.presentationViewport(
            for: sourceCamera,
            projectDuration: projectDuration
        )
        applyViewport(
            sourceViewport,
            kicksImmediateRender: true,
            transcriptCadence: .coalescedInteraction,
            invalidatesCursorRects: false,
            renderCadence: .coalescedInteraction,
            marksInteraction: true,
            notifiesChange: false
        )
        requestTimelineRender()
    }

    private func currentCameraMotion(
        sampledAt timestamp: CFTimeInterval
    ) -> (camera: TimelineCameraWindow, velocity: TimelineCameraVelocity) {
        let camera: TimelineCameraWindow
        var centerVelocity: TimeInterval = 0
        var logDurationVelocity: Double = 0

        if let activeCameraTransition {
            camera = activeCameraTransition.camera(at: timestamp)
            let transitionVelocity = activeCameraTransition.velocity(at: timestamp)
            centerVelocity = transitionVelocity.centerTimePerSecond
            logDurationVelocity = transitionVelocity.logVisibleDurationPerSecond
        } else {
            camera = TimelineCameraWindow(
                viewport: viewport,
                projectDuration: timelineDuration
            )
        }

        if rightPanMomentumTimer != nil || isRightPanGestureActive {
            centerVelocity += Double(rightPanVelocityProgressPerSecond) * timelineDuration
        }
        if scrollGestureMode == .pan {
            centerVelocity += Double(trackpadPanVelocityProgressPerSecond) * timelineDuration
        }
        if
            (zoomMomentumTimer != nil || scrollGestureMode == .zoom),
            let zoomMomentumAnchorProgress
        {
            let zoomLogDurationVelocity = -Double(zoomVelocityLogScalePerSecond)
            let anchorTime = Double(zoomMomentumAnchorProgress) * timelineDuration
            let anchorFraction = (anchorTime - camera.startTime) /
                max(camera.visibleDuration, 0.000_001)
            centerVelocity += (0.5 - anchorFraction) * camera.visibleDuration *
                zoomLogDurationVelocity
            logDurationVelocity += zoomLogDurationVelocity
        }

        return (
            camera,
            TimelineCameraVelocity(
                centerTimePerSecond: centerVelocity,
                logVisibleDurationPerSecond: logDurationVelocity
            )
        )
    }

    @discardableResult
    private func stepCameraTransition(sampledAt: CFTimeInterval) -> Bool {
        guard let transition = activeCameraTransition else {
            return false
        }

        let isComplete = transition.isComplete(at: sampledAt)
        let nextViewport = isComplete ? settledViewport : TimelineViewport.presentationViewport(
            for: transition.camera(at: sampledAt),
            projectDuration: timelineDuration
        )
        applyViewport(
            nextViewport,
            kicksImmediateRender: true,
            transcriptCadence: .coalescedInteraction,
            invalidatesCursorRects: false,
            renderCadence: .coalescedInteraction,
            marksInteraction: true,
            notifiesChange: false
        )
        if isComplete {
            activeCameraTransition = nil
            onViewportChanged?(settledViewport)
            invalidateTimelineCursorRects()
        }
        return true
    }

    private func zoomToSelection() {
        guard let selection = zoomFocusSelection() else {
            return
        }

        focusSelection(selection)
    }

    private func zoomFocusSelection() -> TimelineSelection? {
        Self.zoomFocusSelection(
            timeSelection: currentSelection,
            selectedClips: selectedClipFocusRequests(),
            trackOrder: currentTrackIDs
        )
    }

    static func zoomFocusSelection(
        timeSelection: TimelineSelection?,
        selectedClips: [TimelineClipFocusRequest],
        trackOrder: [UUID]
    ) -> TimelineSelection? {
        if let timeSelection, timeSelection.durationProgress > 0 {
            return timeSelection
        }

        guard
            let startProgress = selectedClips.map(\.projectStartProgress).min(),
            let endProgress = selectedClips.map(\.projectEndProgress).max(),
            endProgress > startProgress
        else {
            return nil
        }

        let selectedTrackIndices = Set(selectedClips.compactMap { clip in
            trackOrder.firstIndex(of: clip.trackID)
        })
        let focusTrackID: UUID?
        if
            let minimumTrackIndex = selectedTrackIndices.min(),
            let maximumTrackIndex = selectedTrackIndices.max()
        {
            focusTrackID = trackOrder[(minimumTrackIndex + maximumTrackIndex) / 2]
        } else {
            focusTrackID = selectedClips.first?.trackID
        }

        return TimelineSelection(
            startProgress: Double(startProgress),
            endProgress: Double(endProgress),
            trackID: focusTrackID
        )
    }

    func focusSelection(_ selection: TimelineSelection) {
        guard selection.durationProgress > 0 else {
            return
        }

        let resolvedLayout = resolvedTrackLayoutForCurrentBounds()
        let plan = TimelineSelectionFocusPlan(
            selection: selection,
            trackIndex: selection.trackID.flatMap { currentTrackIDs.firstIndex(of: $0) },
            trackLayout: resolvedLayout,
            viewportWidth: bounds.width
        )
        let startedAt = CACurrentMediaTime()
        let currentMotion = currentCameraMotion(sampledAt: startedAt)
        let targetCamera = TimelineCameraWindow(
            viewport: plan.viewport,
            projectDuration: timelineDuration
        )
        let isMovingAway = currentMotion.velocity.alignment(
            from: currentMotion.camera,
            toward: targetCamera
        ) < -0.000_001
        let transitionTuning: TimelineCameraTransition.Tuning = isMovingAway ?
            .selectionFocusOpposingMomentum :
            .selectionFocus
        let carriedVelocity = currentMotion.velocity.isEffectivelyZero ? nil :
            currentMotion.velocity.clampedForFocusRetarget(
                from: currentMotion.camera,
                toward: targetCamera,
                duration: transitionTuning.duration
            )
        if plan.viewport != viewport {
            onNavigationScrollActivity?(.horizontal)
        }
        if abs(plan.trackScrollOffset - resolvedLayout.scrollOffset) > 0.5 {
            onNavigationScrollActivity?(.vertical)
        }

        suppressesNavigationGestureForSelectionFocus =
            scrollGestureMode != nil ||
            rightPanMomentumTimer != nil ||
            zoomMomentumTimer != nil
        stopRightPanMomentum()
        stopZoomMomentum()
        scrollGestureMode = nil
        trackpadPanPreviousTime = nil
        trackpadPanVelocityProgressPerSecond = 0
        beginCameraTransition(
            from: currentMotion.camera,
            to: plan.viewport,
            projectDuration: timelineDuration,
            startTimestamp: startedAt,
            tuning: transitionTuning,
            initialVelocity: carriedVelocity
        )

        let scrollTransition = TimelineScalarTransition(
            source: resolvedLayout.scrollOffset,
            target: plan.trackScrollOffset,
            startTimestamp: startedAt,
            duration: transitionTuning.duration,
            easing: .easeOutCubic
        )
        if abs(scrollTransition.target - scrollTransition.source) > 0.5 {
            activeTrackScrollTransition = scrollTransition
        } else {
            activeTrackScrollTransition = nil
            applyTrackScrollOffset(plan.trackScrollOffset, updatesTranscript: true)
        }
        requestTimelineRender()
    }

    @discardableResult
    private func stepTrackScrollTransition(sampledAt timestamp: CFTimeInterval) -> Bool {
        guard let transition = activeTrackScrollTransition else {
            return false
        }
        let isComplete = transition.isComplete(at: timestamp)
        applyTrackScrollOffset(
            isComplete ? transition.target : transition.value(at: timestamp),
            updatesTranscript: true
        )
        if isComplete {
            activeTrackScrollTransition = nil
            invalidateTimelineCursorRects()
        }
        return true
    }

    private func applyTrackScrollOffset(_ scrollOffset: Float, updatesTranscript: Bool) {
        let nextLayout = trackLayout.withScrollOffset(
            scrollOffset,
            totalTrackCount: currentTrackIDs.count,
            viewportHeight: Float(max(bounds.height, 1))
        )
        guard nextLayout != trackLayout else {
            return
        }
        publishTrackLayout(
            nextLayout,
            requestRender: true,
            updatesTranscript: updatesTranscript
        )
        publishScrollbarPresentation()
    }

    func scrollTracks(byPixels deltaPixels: Float) {
        activeTrackScrollTransition = nil
        let nextTrackLayout = trackLayout.scrolled(
            by: deltaPixels,
            totalTrackCount: currentTrackIDs.count,
            viewportHeight: Float(max(bounds.height, 1))
        )
        guard nextTrackLayout != trackLayout else {
            return
        }

        onNavigationScrollActivity?(.vertical)
        trackLayout = nextTrackLayout
        updateTimelineRendererImmediately { renderer in
            renderer.displayTrackLayout(nextTrackLayout)
        }
        updateTrackLayoutForCurrentBounds(requestRender: false)
        updateTranscriptOverlay()
        updateClipLabelOverlay()
        publishScrollbarPresentation()
        requestTimelineRender()
    }

    private func applyTwoDimensionalPan(
        horizontalDeltaPixels: CGFloat,
        verticalDeltaPixels: CGFloat
    ) {
        var didChangeViewport = false
        var didChangeTrackLayout = false

        let horizontalProgressDelta = TimelineNavigationPanGeometry.horizontalProgressDelta(
            scrollingDeltaX: horizontalDeltaPixels,
            viewportWidth: bounds.width,
            viewportDurationProgress: settledViewport.durationProgress
        )
        if horizontalProgressDelta != 0 {
            let canonicalViewport = settledViewport.panned(byProgress: horizontalProgressDelta)
            let canonicalChanged = canonicalViewport != settledViewport
            if canonicalChanged {
                settledViewport = canonicalViewport
                applyViewport(
                    canonicalViewport,
                    kicksImmediateRender: false,
                    transcriptCadence: .coalescedInteraction,
                    invalidatesCursorRects: false,
                    renderCadence: .none,
                    marksInteraction: true,
                    notifiesChange: true,
                    updatesTranscript: false
                )
                didChangeViewport = true
            }
        }

        let verticalTrackDelta = TimelineNavigationPanGeometry.verticalTrackDelta(
            scrollingDeltaY: verticalDeltaPixels
        )
        if verticalTrackDelta != 0 {
            let resolvedCanonical = trackLayout.resolved(
                totalTrackCount: currentTrackIDs.count,
                viewportHeight: Float(max(bounds.height, 1))
            )
            let canonicalOffset = min(
                max(resolvedCanonical.scrollOffset + verticalTrackDelta, 0),
                resolvedCanonical.maximumScrollOffset
            )
            let nextTrackLayout = trackLayout.withScrollOffset(
                canonicalOffset,
                totalTrackCount: currentTrackIDs.count,
                viewportHeight: Float(max(bounds.height, 1))
            )
            if nextTrackLayout != trackLayout {
                publishTrackLayout(
                    nextTrackLayout,
                    requestRender: false,
                    updatesTranscript: false
                )
                didChangeTrackLayout = true
            }
        }

        guard didChangeViewport || didChangeTrackLayout else {
            return
        }
        if didChangeViewport {
            onNavigationScrollActivity?(.horizontal)
        }
        if didChangeTrackLayout {
            onNavigationScrollActivity?(.vertical)
        }
        transcriptViewportRelayoutAllowedUntil = CACurrentMediaTime() + 0.18
        updateTranscriptOverlay(cadence: .coalescedInteraction)
        if areEmbeddedScrollbarsEnabled {
            publishScrollbarPresentation()
        }
        requestCoalescedInteractionRender()
    }

    private func currentScrollbarGeometry() -> TimelineScrollbarGeometry {
        TimelineScrollbarGeometry.resolve(
            bounds: bounds,
            viewport: viewport,
            trackLayout: resolvedTrackLayoutForCurrentBounds()
        )
    }

    private func updateScrollbarHover(for event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard let axis = currentScrollbarGeometry().axis(at: point) else {
            setHoveredScrollbarAxis(nil)
            return false
        }
        displayHoverProgress(nil, renderCadence: .coalescedInteraction)
        displayHighlightedSelectionEndpoint(nil, renderCadence: .coalescedInteraction)
        displayHighlightedLoopEndpoint(nil, renderCadence: .coalescedInteraction)
        displayHighlightedLoopRegion(false, renderCadence: .coalescedInteraction)
        setHoveredScrollbarAxis(axis)
        NSCursor.openHand.set()
        return true
    }

    private func setHoveredScrollbarAxis(_ axis: TimelineScrollbarAxis?) {
        guard hoveredScrollbarAxis != axis else {
            return
        }
        scrollbarHoverPresentation = currentScrollbarHoverPresentation(at: CACurrentMediaTime())
        scrollbarHoverTransitionSource = scrollbarHoverPresentation
        hoveredScrollbarAxis = axis
        if let axis {
            scrollbarPresentationAxis = axis
        }
        scrollbarHoverTarget = axis == nil ? 0 : 1
        scrollbarHoverTransitionStartTime = CACurrentMediaTime()
        publishScrollbarPresentation()
        startTimelineDisplayLink()
    }

    private func currentScrollbarHoverPresentation(at timestamp: CFTimeInterval) -> Float {
        guard isScrollbarHoverAnimating else {
            return scrollbarHoverTarget
        }
        let raw = Float(min(max(
            (timestamp - scrollbarHoverTransitionStartTime) / scrollbarHoverTransitionDuration,
            0
        ), 1))
        let eased = easeInOutCubic(raw)
        return scrollbarHoverTransitionSource +
            (scrollbarHoverTarget - scrollbarHoverTransitionSource) * eased
    }

    private func publishScrollbarPresentation() {
        let axisValue: Int
        switch activeScrollbarAxis ?? hoveredScrollbarAxis ?? scrollbarPresentationAxis {
        case .horizontal:
            axisValue = 1
        case .vertical:
            axisValue = 2
        case nil:
            axisValue = 0
        }
        let amount = activeScrollbarAxis == nil ? scrollbarHoverPresentation : 1
        updateTimelineRendererImmediately { renderer in
            renderer.displayScrollbarHighlight(axis: axisValue, amount: amount)
        }
        requestTimelineRender()
    }

    private func updateScrollbarDrag(to point: CGPoint) {
        let geometry = currentScrollbarGeometry()
        if activeDragMode == .horizontalScrollbar {
            let travel = max(geometry.horizontalTrack.width - geometry.horizontalHandle.width, 0)
            guard travel > 0 else {
                return
            }
            let handleOrigin = min(max(
                point.x - activeScrollbarDragOffset,
                geometry.horizontalTrack.minX
            ), geometry.horizontalTrack.maxX - geometry.horizontalHandle.width)
            let fraction = Float((handleOrigin - geometry.horizontalTrack.minX) / travel)
            let nextStart = fraction * max(1 - viewport.durationProgress, 0)
            setViewport(
                TimelineViewport(startProgress: nextStart, durationProgress: viewport.durationProgress),
                transcriptCadence: .coalescedInteraction,
                invalidatesCursorRects: false,
                renderCadence: .coalescedInteraction
            )
        } else if activeDragMode == .verticalScrollbar {
            let resolved = resolvedTrackLayoutForCurrentBounds()
            let travel = max(geometry.verticalTrack.height - geometry.verticalHandle.height, 0)
            guard travel > 0, resolved.maximumScrollOffset > 0 else {
                return
            }
            let handleOrigin = min(max(
                point.y - activeScrollbarDragOffset,
                geometry.verticalTrack.minY
            ), geometry.verticalTrack.maxY - geometry.verticalHandle.height)
            let fraction = Float(
                (geometry.verticalTrack.maxY - geometry.verticalHandle.height - handleOrigin) / travel
            )
            let nextLayout = trackLayout.withScrollOffset(
                fraction * resolved.maximumScrollOffset,
                totalTrackCount: currentTrackIDs.count,
                viewportHeight: Float(max(bounds.height, 1))
            )
            publishTrackLayout(nextLayout, requestRender: true)
            publishScrollbarPresentation()
        }
    }

    var horizontalZoomNormalizedValue: Float {
        let minimumDuration: Float = 0.001
        let duration = min(max(viewport.durationProgress, minimumDuration), 1)
        return min(max(log(duration) / log(minimumDuration), 0), 1)
    }

    var verticalZoomNormalizedValue: Float {
        let range: ClosedRange<Float> = 48...320
        let height = resolvedTrackLayoutForCurrentBounds().trackHeight
        return min(max((height - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    var horizontalScrollNormalizedValue: Float {
        let travel = max(1 - viewport.durationProgress, 0)
        guard travel > 0.000_001 else {
            return 0
        }
        return min(max(viewport.startProgress / travel, 0), 1)
    }

    var horizontalVisibleFraction: Float {
        min(max(viewport.durationProgress, 0), 1)
    }

    var verticalScrollNormalizedValue: Float {
        let resolved = resolvedTrackLayoutForCurrentBounds()
        guard resolved.maximumScrollOffset > 0 else {
            return 0
        }
        return min(max(resolved.scrollOffset / resolved.maximumScrollOffset, 0), 1)
    }

    var verticalVisibleFraction: Float {
        let resolved = resolvedTrackLayoutForCurrentBounds()
        return min(max(resolved.trackViewportHeight / max(resolved.contentHeight, 1), 0), 1)
    }

    func setEmbeddedScrollbarsEnabled(_ isEnabled: Bool) {
        guard areEmbeddedScrollbarsEnabled != isEnabled else {
            return
        }
        areEmbeddedScrollbarsEnabled = isEnabled
        if !isEnabled {
            setHoveredScrollbarAxis(nil)
        }
        updateTimelineRendererImmediately { renderer in
            renderer.displayEmbeddedScrollbarsVisible(isEnabled)
        }
        invalidateTimelineCursorRects()
        requestTimelineRender()
    }

    func setHorizontalScrollNormalized(_ value: Float) {
        let travel = max(1 - settledViewport.durationProgress, 0)
        let start = min(max(value, 0), 1) * travel
        let nextViewport = TimelineViewport(
            startProgress: start,
            durationProgress: settledViewport.durationProgress
        )
        guard nextViewport != viewport else {
            return
        }
        activeCameraTransition = nil
        activeTrackScrollTransition = nil
        settledViewport = nextViewport
        applyViewport(
            nextViewport,
            kicksImmediateRender: false,
            transcriptCadence: .coalescedInteraction,
            invalidatesCursorRects: false,
            renderCadence: .none,
            marksInteraction: true,
            notifiesChange: true,
            updatesTranscript: false
        )
        transcriptViewportRelayoutAllowedUntil = CACurrentMediaTime() + 0.18
        updateTranscriptOverlay(cadence: .coalescedInteraction)
        requestCoalescedInteractionRender()
    }

    func setVerticalScrollNormalized(_ value: Float) {
        activeTrackScrollTransition = nil
        let resolved = resolvedTrackLayoutForCurrentBounds()
        guard resolved.maximumScrollOffset > 0 else {
            return
        }
        let nextLayout = trackLayout.withScrollOffset(
            min(max(value, 0), 1) * resolved.maximumScrollOffset,
            totalTrackCount: currentTrackIDs.count,
            viewportHeight: Float(max(bounds.height, 1))
        )
        publishTrackLayout(nextLayout, requestRender: true)
    }

    func finishNavigationScrollbarInteraction() {
        performTranscriptOverlayUpdate(forceLayoutRebuild: true)
        invalidateTimelineCursorRects()
        requestTimelineRender()
    }

    func setHorizontalZoomNormalized(_ value: Float) {
        isZoomControlInteractionActive = true
        let clamped = min(max(value, 0), 1)
        let minimumDuration: Float = 0.001
        let nextDuration = pow(minimumDuration, clamped)
        let center = viewport.startProgress + viewport.durationProgress * 0.5
        setViewport(TimelineViewport(
            startProgress: center - nextDuration * 0.5,
            durationProgress: nextDuration
        ), transcriptCadence: .coalescedInteraction, invalidatesCursorRects: false)
    }

    func setVerticalZoomNormalized(_ value: Float) {
        activeTrackScrollTransition = nil
        isZoomControlInteractionActive = true
        let clamped = min(max(value, 0), 1)
        let range: ClosedRange<Float> = 48...320
        let height = range.lowerBound + (range.upperBound - range.lowerBound) * clamped
        publishTrackLayout(trackLayout.withPreferredTrackHeight(height), requestRender: true)
        publishScrollbarPresentation()
    }

    func finishZoomControlInteraction() {
        guard isZoomControlInteractionActive else {
            return
        }
        isZoomControlInteractionActive = false
        performTranscriptOverlayUpdate(forceLayoutRebuild: true)
        invalidateTimelineCursorRects()
        requestTimelineRender()
    }

    func beginTrackReorder(trackID: UUID, yFromTop: Float) {
        guard let draggedIndex = currentTrackIDs.firstIndex(of: trackID) else {
            return
        }
        stopTrackInsertionAnimation(clearsLayout: true)
        trackReorderTrackID = trackID
        trackReorderDraggedIndex = draggedIndex
        trackReorderTargetIndex = draggedIndex
        trackReorderPointerYFromTop = yFromTop
        let base = trackLayout.trackPositions ?? (0..<currentTrackIDs.count).map(Float.init)
        trackReorderSourcePositions = base
        trackReorderTargetPositions = base
        trackReorderAnimationStartTime = CACurrentMediaTime()
        trackReorderLastTickTime = trackReorderAnimationStartTime
        startTimelineDisplayLink()
        updateTrackReorder(yFromTop: yFromTop)
    }

    func updateTrackReorder(yFromTop: Float) {
        guard
            let draggedIndex = trackReorderDraggedIndex,
            currentTrackIDs.indices.contains(draggedIndex)
        else {
            return
        }
        let resolved = resolvedTrackLayoutForCurrentBounds()
        guard let targetIndex = TimelineTrackReorderGeometry.targetIndex(
            yFromTop: yFromTop,
            layout: resolved
        ) else {
            return
        }
        trackReorderPointerYFromTop = yFromTop
        let draggedPosition = (yFromTop - resolved.rulerLaneHeight + resolved.scrollOffset) /
            max(resolved.trackHeight, 1) - 0.5
        let nextTargets = TimelineTrackReorderGeometry.trackPositions(
            count: currentTrackIDs.count,
            draggedIndex: draggedIndex,
            targetIndex: targetIndex,
            draggedPosition: draggedPosition
        )
        if targetIndex != trackReorderTargetIndex {
            trackReorderSourcePositions = currentTrackReorderPresentation(at: CACurrentMediaTime())
            trackReorderAnimationStartTime = CACurrentMediaTime()
            trackReorderTargetIndex = targetIndex
        }
        trackReorderTargetPositions = nextTargets
        publishTrackReorderPresentation(at: CACurrentMediaTime())
        startTimelineDisplayLink()
    }

    func endTrackReorder(cancelled: Bool) {
        guard let trackID = trackReorderTrackID else {
            return
        }
        let targetIndex = trackReorderTargetIndex
        if !cancelled, let targetIndex {
            onTrackReorderCommitted?(trackID, targetIndex)
        }
        trackReorderTrackID = nil
        trackReorderDraggedIndex = nil
        trackReorderTargetIndex = nil
        trackReorderPointerYFromTop = nil
        trackReorderSourcePositions = nil
        trackReorderTargetPositions = nil
        publishTrackLayout(trackLayout.withTrackPositions(nil), requestRender: true)
    }

    private func currentTrackReorderPresentation(at timestamp: CFTimeInterval) -> [Float] {
        guard
            let source = trackReorderSourcePositions,
            let target = trackReorderTargetPositions,
            source.count == target.count
        else {
            return trackLayout.trackPositions ?? (0..<currentTrackIDs.count).map(Float.init)
        }
        let raw = Float(min(max(
            (timestamp - trackReorderAnimationStartTime) / trackReorderAnimationDuration,
            0
        ), 1))
        let eased = easeInOutCubic(raw)
        var presentation = zip(source, target).map { pair in
            pair.0 + (pair.1 - pair.0) * eased
        }
        if
            let draggedIndex = trackReorderDraggedIndex,
            let pointerY = trackReorderPointerYFromTop,
            presentation.indices.contains(draggedIndex)
        {
            let resolved = resolvedTrackLayoutForCurrentBounds()
            presentation[draggedIndex] = min(max(
                (pointerY - resolved.rulerLaneHeight + resolved.scrollOffset) /
                    max(resolved.trackHeight, 1) - 0.5,
                0
            ), Float(max(currentTrackIDs.count - 1, 0)))
        }
        return presentation
    }

    @discardableResult
    private func publishTrackReorderPresentation(at timestamp: CFTimeInterval) -> Bool {
        guard trackReorderTrackID != nil else {
            return false
        }
        let positions = currentTrackReorderPresentation(at: timestamp)
        publishTrackLayout(trackLayout.withTrackPositions(positions), requestRender: true)
        return true
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

    private func publishTrackLayout(
        _ nextTrackLayout: TimelineTrackLayout,
        requestRender: Bool,
        updatesTranscript: Bool = true
    ) {
        let clampedLayout = nextTrackLayout.clamped(
            totalTrackCount: currentTrackIDs.count,
            viewportHeight: Float(max(bounds.height, 1))
        )
        trackLayout = clampedLayout
        updateBootstrapWaveformView()
        let resolvedLayout = resolvedTrackLayoutForCurrentBounds()
        clipLabelOverlayView.displayTrackLayout(resolvedLayout)
        if lastPublishedTrackLayout != resolvedLayout {
            lastPublishedTrackLayout = resolvedLayout
            onTrackLaneLayoutChanged?(resolvedLayout)
        }
        if updatesTranscript, transcriptDisplayMode != .hidden {
            updateTranscriptOverlay(
                cadence: trackReorderTrackID == nil ? .immediate : .coalescedInteraction
            )
        }
        let presentationTrackLayout = trackLayout
        updateTimelineRendererImmediately { renderer in
            renderer.displayTrackLayout(presentationTrackLayout, marksInteraction: requestRender)
        }
        if requestRender {
            requestTimelineRender()
        }
    }

    var clipLabelTrackLayoutForTesting: ResolvedTimelineTrackLayout? {
        clipLabelOverlayView.displayedTrackLayoutForTesting
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

        let presentationTrackLayout = trackLayout
        updateTimelineRendererImmediately { renderer in
            renderer.displayTrackLayout(presentationTrackLayout)
        }
        if requestRender {
            requestTimelineRender()
        }
    }

    private func updateClipLabelOverlay() {
        clipLabelOverlayView.configure(
            tracks: currentRenderTracks,
            timelineDuration: timelineDuration,
            viewport: viewport,
            trackLayout: resolvedTrackLayoutForCurrentBounds()
        )
    }

    private func updateClipAccessibilityElements() {
        guard let window, timelineDuration > 0, viewport.durationProgress > 0 else {
            clipAccessibilityElements = []
            return
        }
        let layout = resolvedTrackLayoutForCurrentBounds()
        var elements: [NSAccessibilityElement] = []
        elements.reserveCapacity(min(currentRenderTracks.reduce(0) { $0 + $1.clipRanges.count }, 256))
        for (trackIndex, track) in currentRenderTracks.enumerated() {
            guard let lane = layout.laneFrame(forTrackIndex: trackIndex) else { continue }
            let laneTop = CGFloat(lane.top) * bounds.height
            let laneBottom = CGFloat(lane.bottom) * bounds.height
            guard laneBottom > 0, laneTop < bounds.height else { continue }
            let trackDuration = track.durationHint ?? track.waveformOverview?.duration ?? 0
            guard trackDuration > 0 else { continue }
            let projectScale = trackDuration / timelineDuration
            for clip in track.clipRanges where !clip.isSilent {
                let projectStart = clip.startProgress * projectScale
                let projectEnd = clip.endProgress * projectScale
                guard projectEnd >= Double(viewport.startProgress),
                      projectStart <= Double(viewport.endProgress) else { continue }
                let startX = CGFloat((Float(projectStart) - viewport.startProgress) / viewport.durationProgress) * bounds.width
                let endX = CGFloat((Float(projectEnd) - viewport.startProgress) / viewport.durationProgress) * bounds.width
                let localRect = NSRect(
                    x: max(startX, 0),
                    y: max(bounds.height - laneBottom, 0),
                    width: max(min(endX, bounds.width) - max(startX, 0), 1),
                    height: max(min(laneBottom, bounds.height) - max(laneTop, 0), 1)
                )
                let windowRect = convert(localRect, to: nil)
                let screenRect = window.convertToScreen(windowRect)
                let request = TimelineClipFocusRequest(
                    clipID: clip.id,
                    trackID: track.id,
                    trackLocalRange: clip,
                    projectStartProgress: Float(projectStart),
                    projectEndProgress: Float(projectEnd)
                )
                let element = TimelineClipAccessibilityElement { [weak self] in
                    self?.onClipSelected?(request, .replace)
                }
                element.setAccessibilityParent(self)
                element.setAccessibilityRole(.button)
                element.setAccessibilityLabel(clip.name?.isEmpty == false ? clip.name! : "Audio clip")
                var state: [String] = []
                if clip.isSelected { state.append("selected") }
                if clip.isMissingMedia { state.append("missing media") }
                let startSeconds = projectStart * timelineDuration
                let endSeconds = projectEnd * timelineDuration
                state.append(String(format: "%.3f to %.3f seconds", startSeconds, endSeconds))
                element.setAccessibilityValue(state.joined(separator: ", "))
                element.setAccessibilityHelp(
                    clip.isMissingMedia ?
                        "Use Clip, Relink Missing Media to locate this clip's audio file." :
                        "Press to select this clip. Use the Clip menu for editing commands."
                )
                element.setAccessibilitySelected(clip.isSelected)
                element.setAccessibilityFrame(screenRect)
                element.setAccessibilityIdentifier("timeline.clip.\(clip.id.rawValue.uuidString.lowercased())")
                elements.append(element)
            }
        }
        clipAccessibilityElements = elements
    }

    private func updateAutomationAccessibilityElements() {
        guard
            isAutomationModeVisible,
            let window,
            timelineDuration > 0,
            viewport.durationProgress > 0
        else {
            automationAccessibilityElements = []
            return
        }
        let layout = resolvedTrackLayoutForCurrentBounds()
        let parameterID = TimelineAutomationParameterID(rawValue: displayedAutomationParameterID)
        let descriptor = TimelineAutomationParameterRegistry.descriptor(for: parameterID)
        var elements: [NSAccessibilityElement] = []
        for (trackIndex, track) in currentRenderTracks.enumerated() {
            guard
                let laneFrame = layout.laneFrame(forTrackIndex: trackIndex),
                let lane = track.automationLanes.first(where: {
                    $0.parameterID == displayedAutomationParameterID && $0.isEnabled
                })
            else { continue }
            let height = Float(max(bounds.height, 1))
            let laneTop = laneFrame.top * height
            let laneBottom = laneFrame.bottom * height
            let range = TimelineClipChromeMetrics.automationRange(
                laneTop: laneTop,
                laneBottom: laneBottom,
                viewportHeight: height
            )
            for point in lane.points where
                point.projectProgress >= Double(viewport.startProgress) &&
                point.projectProgress <= Double(viewport.endProgress) {
                let position = automationPointPosition(
                    point,
                    curveTop: range.top,
                    curveBottom: range.bottom
                )
                let localRect = NSRect(x: position.x - 9, y: position.y - 9, width: 18, height: 18)
                let screenRect = window.convertToScreen(convert(localRect, to: nil))
                let address = TimelineAutomationAddress.track(track.id, parameterID: parameterID)
                let element = TimelineAutomationPointAccessibilityElement(
                    selectHandler: { [weak self] in
                        self?.setAutomationSelection(TimelineAutomationSelection(
                            address: address,
                            pointIDs: [point.id],
                            anchorPointID: point.id
                        ))
                    },
                    adjustmentHandler: { [weak self] frameDelta, valueDelta in
                        self?.onAutomationEditRequested?(TimelineAutomationEditRequest(
                            trackID: track.id,
                            parameterID: parameterID.rawValue,
                            action: .nudge(
                                pointIDs: [point.id],
                                frameDelta: frameDelta,
                                normalizedValueDelta: valueDelta
                            )
                        ))
                    }
                )
                element.setAccessibilityParent(self)
                element.setAccessibilityRole(.slider)
                element.setAccessibilityLabel("\(descriptor?.displayName ?? parameterID.rawValue) automation point")
                let seconds = point.projectProgress * timelineDuration
                element.setAccessibilityValue(
                    "\(descriptor?.formattedValue(normalizedValue: point.normalizedValue) ?? String(format: "%.3f", point.normalizedValue)), \(String(format: "%.3f seconds", seconds))"
                )
                element.setAccessibilityHelp(
                    "Press to select. Use increment and decrement to adjust the value, or the Automation menu for editing commands."
                )
                element.setAccessibilitySelected(
                    automationSelection.address == address && automationSelection.pointIDs.contains(point.id)
                )
                element.setAccessibilityFrame(screenRect)
                element.setAccessibilityIdentifier("timeline.automation.\(point.id.uuidString.lowercased())")
                elements.append(element)
            }
        }
        automationAccessibilityElements = elements
    }

    override func accessibilityChildren() -> [Any]? {
        // Accessibility is a query-driven projection. Building clip elements in
        // the viewport hot path allocates AppKit objects and formatted strings
        // during every drag/zoom frame even when no assistive client is active.
        updateClipAccessibilityElements()
        updateAutomationAccessibilityElements()
        return clipAccessibilityElements + automationAccessibilityElements
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

    private func performTranscriptOverlayUpdate(forceLayoutRebuild: Bool = false) {
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
            if canReuseLiveGeometry && !forceLayoutRebuild {
                updateTranscriptOverlayLiveGeometry()
                return
            }
            if !forceLayoutRebuild && (
                shouldDeferTranscriptOverlayLayoutForNonViewportHotPath ||
                (shouldDeferTranscriptOverlayLayoutForHotPath &&
                    !isTranscriptViewportRelayoutAllowed)
            ) {
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
            isDraggingLoop ||
            trackReorderTrackID != nil ||
            isZoomControlInteractionActive ||
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

    private func layoutOffscreenPlayheadButtons() {
        let controlSize = CGSize(width: 36, height: 46)
        let availableTrackHeight = max(bounds.height - CGFloat(trackLayout.rulerLaneHeight), controlSize.height)
        let originY = max((availableTrackHeight - controlSize.height) * 0.5, 0)
        leftOffscreenPlayheadButton.frame = CGRect(
            x: 0,
            y: originY,
            width: controlSize.width,
            height: controlSize.height
        )
        rightOffscreenPlayheadButton.frame = CGRect(
            x: max(bounds.width - controlSize.width, 0),
            y: originY,
            width: controlSize.width,
            height: controlSize.height
        )
    }

    private func currentPresentationPlayheadProgress() -> Float {
        guard isTimelinePlaybackActive else {
            return presentationPlayheadProgress
        }
        let timestamp = max(CACurrentMediaTime(), latestSubmittedPresentationTimestamp)
        return projectedPresentationPlayheadProgress(at: timestamp) ?? presentationPlayheadProgress
    }

    private func updateOffscreenPlayheadButtons(playheadProgress: Float? = nil) {
        guard
            isSelectionEnabled,
            timelineDuration.isFinite,
            timelineDuration > 0,
            !isInteractionSuppressed
        else {
            leftOffscreenPlayheadButton.setPresented(false)
            rightOffscreenPlayheadButton.setPresented(false)
            return
        }

        let progress = playheadProgress ?? currentPresentationPlayheadProgress()
        let direction = TimelineOffscreenPlayheadNavigation.direction(
            playheadProgress: progress,
            viewport: viewport
        )
        leftOffscreenPlayheadButton.setPresented(direction == .left)
        rightOffscreenPlayheadButton.setPresented(direction == .right)
    }

    private func revealOffscreenPlayhead() {
        guard
            isSelectionEnabled,
            timelineDuration.isFinite,
            timelineDuration > 0
        else {
            return
        }

        let playheadProgress = currentPresentationPlayheadProgress()
        guard TimelineOffscreenPlayheadNavigation.direction(
            playheadProgress: playheadProgress,
            viewport: viewport
        ) != nil else {
            updateOffscreenPlayheadButtons(playheadProgress: playheadProgress)
            return
        }

        stopRightPanMomentum()
        stopZoomMomentum()
        scrollGestureMode = nil
        onTimelineInteractionBegan?()
        let sourceCamera = TimelineCameraWindow(
            viewport: viewport,
            projectDuration: timelineDuration
        )
        let targetViewport = TimelineOffscreenPlayheadNavigation.revealViewport(
            playheadProgress: playheadProgress,
            viewport: viewport
        )
        beginCameraTransition(
            from: sourceCamera,
            to: targetViewport,
            projectDuration: timelineDuration,
            tuning: .playheadReveal
        )
        requestTimelineRender()
    }

    private func updateHoverGuide(for event: NSEvent) {
        guard !isInteractionSuppressed else {
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            displayHighlightedSelectionEndpoint(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopEndpoint(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopRegion(false, renderCadence: .coalescedInteraction)
            return
        }

        guard
            isSelectionEnabled,
            activeDragMode == nil
        else {
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            displayHighlightedSelectionEndpoint(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopEndpoint(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopRegion(false, renderCadence: .coalescedInteraction)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            displayHighlightedSelectionEndpoint(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopEndpoint(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopRegion(false, renderCadence: .coalescedInteraction)
            return
        }

        guard let gutter = seekGutterHit(at: point) else {
            NSCursor.arrow.set()
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            return
        }

        NSCursor.arrow.set()
        displayHoverProgress(
            progress(for: point),
            guideSpan: gutter.span,
            renderCadence: .coalescedInteraction
        )
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
        displayHighlightedSelectionEndpoint(nil)
        displayHighlightedLoopEndpoint(nil)
        displayHighlightedLoopRegion(false)
        activeDragMode = nil
        activeSelectionDragOffsetX = 0
        selectionAnchorProgress = nil
        selectionAnchorPoint = nil
        selectionAnchorTrackID = hit.trackID
        isDraggingSelection = false
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

        guard loopInteractionBandRect().contains(point) else {
            displayHighlightedLoopEndpoint(nil, renderCadence: .coalescedInteraction)
            displayHighlightedLoopRegion(false, renderCadence: .coalescedInteraction)
            return false
        }

        displayHighlightedSelectionEndpoint(nil, renderCadence: .coalescedInteraction)
        displayHighlightedClipEdge(nil, renderCadence: .coalescedInteraction)
        let hoveredEndpoint = loopRegionEndpointNear(point)
        let isInsideLoopRegion = loopRegionContains(point)
        if hoveredEndpoint == nil, !isInsideLoopRegion {
            displayHoverProgress(
                progress(for: point),
                guideSpan: hoverGuideSpan(for: loopInteractionBandRect()),
                renderCadence: .coalescedInteraction
            )
        } else {
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
        }
        displayHighlightedLoopEndpoint(hoveredEndpoint, renderCadence: .coalescedInteraction)
        displayHighlightedLoopRegion(isInsideLoopRegion, renderCadence: .coalescedInteraction)
        return true
    }

    private func updateTimelineEndHover(for event: NSEvent) -> Bool {
        guard
            !isInteractionSuppressed,
            isSelectionEnabled,
            activeDragMode == nil
        else {
            if activeDragMode != .timelineEnd {
                timelineEndOverlayView.isHandleHovered = false
            }
            return false
        }

        let point = convert(event.locationInWindow, from: nil)
        let isHovered = bounds.contains(point) && timelineEndHandleHit(at: point)
        timelineEndOverlayView.isHandleHovered = isHovered
        guard isHovered else {
            return false
        }

        displayHoverProgress(nil, renderCadence: .coalescedInteraction)
        displayHighlightedLoopEndpoint(nil, renderCadence: .coalescedInteraction)
        displayHighlightedLoopRegion(false, renderCadence: .coalescedInteraction)
        displayHighlightedSelectionEndpoint(nil, renderCadence: .coalescedInteraction)
        displayHighlightedClipEdge(nil, renderCadence: .coalescedInteraction)
        updateTranscriptHover(nil)
        NSCursor.resizeLeftRight.set()
        return true
    }

    private func updateSelectionEdgeHover(for event: NSEvent) -> Bool {
        guard
            !isInteractionSuppressed,
            isSelectionEnabled,
            activeDragMode == nil
        else {
            displayHighlightedSelectionEndpoint(nil, renderCadence: .coalescedInteraction)
            return false
        }

        let point = convert(event.locationInWindow, from: nil)
        guard
            bounds.contains(point),
            let endpointHit = selectionEndpointHit(at: point)
        else {
            displayHighlightedSelectionEndpoint(nil, renderCadence: .coalescedInteraction)
            return false
        }

        displayHoverProgress(nil, renderCadence: .coalescedInteraction)
        displayHighlightedSelectionEndpoint(
            endpointHit.endpoint,
            renderCadence: .coalescedInteraction
        )
        NSCursor.resizeLeftRight.set()
        updateTranscriptHover(nil)
        return true
    }

    private func updateClipHover(for event: NSEvent) -> Bool {
        guard
            !isInteractionSuppressed,
            isSelectionEnabled,
            activeDragMode == nil
        else {
            displayHighlightedClipEdge(nil, renderCadence: .coalescedInteraction)
            displayClipPropertyHover(nil)
            return false
        }

        let point = convert(event.locationInWindow, from: nil)
        if let propertyHit = clipPropertyHit(at: point) {
            displayClipPropertyHover(TimelineClipPropertyHover(
                trackID: propertyHit.request.trackID,
                clipID: propertyHit.request.clipID,
                control: propertyHit.control
            ))
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            displayHighlightedClipEdge(nil, renderCadence: .coalescedInteraction)
            NSCursor.resizeLeftRight.set()
            updateTranscriptHover(nil)
            return true
        }
        displayClipPropertyHover(nil)
        guard bounds.contains(point), let hit = clipHit(at: point) else {
            displayHighlightedClipEdge(nil, renderCadence: .coalescedInteraction)
            return false
        }

        if hit.edge != nil {
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            displayHighlightedClipEdge(hit, renderCadence: .coalescedInteraction)
            NSCursor.resizeLeftRight.set()
            updateTranscriptHover(nil)
            return true
        }

        displayHighlightedClipEdge(nil, renderCadence: .coalescedInteraction)
        if hit.isHeader {
            displayHoverProgress(nil, renderCadence: .coalescedInteraction)
            NSCursor.openHand.set()
            updateTranscriptHover(nil)
            return true
        }
        return false
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

    private func updateSelectionResizeDrag(
        to point: CGPoint,
        timestamp: CFTimeInterval,
        schedulesRender: Bool
    ) {
        guard
            activeDragMode == .resizeSelectionStart ||
                activeDragMode == .resizeSelectionEnd,
            let selectionAnchorProgress
        else {
            return
        }

        let dragVelocity = updateSelectionDragVelocity(to: point, timestamp: timestamp)
        let dragProgress = preciseProgress(for: selectionResizeProgressPoint(from: point))
        displayHighlightedSelectionEndpoint(
            dragProgress <= selectionAnchorProgress ? .start : .end,
            renderCadence: schedulesRender ? .coalescedInteraction : .none
        )
        updateSelection(
            from: selectionAnchorProgress,
            to: dragProgress,
            notifyChange: false,
            liveLeadingProgress: dragProgress,
            liveVelocityPixelsPerSecond: dragVelocity.speed,
            liveDirection: dragVelocity.direction,
            liveTimestamp: timestamp,
            schedulesRender: schedulesRender
        )
    }

    @discardableResult
    private func updateActiveLoopDrag(
        to point: CGPoint,
        renderCadence: TimelineRenderCadence,
        notifiesChange: Bool
    ) -> Bool {
        guard
            isDraggingLoop,
            let activeDragMode,
            let selectionAnchorProgress
        else {
            return false
        }

        let previousRange = loopRange
        let dragProgress = progress(
            for: loopDragProgressPoint(from: point),
            followsVisualFisheye: false
        )
        switch activeDragMode {
        case .loopRegion:
            updateLoopRegionRange(
                from: Float(selectionAnchorProgress),
                to: dragProgress,
                renderCadence: renderCadence,
                invalidatesCursorRects: false,
                notifiesChange: notifiesChange
            )
            displayHoverProgress(
                dragProgress,
                isArmed: true,
                renderCadence: renderCadence
            )
        case .moveLoopRegion:
            guard let activeLoopMoveInitialRange else {
                return false
            }
            updateMovingLoopRange(
                initialRange: activeLoopMoveInitialRange,
                anchorProgress: Float(selectionAnchorProgress),
                currentProgress: dragProgress,
                renderCadence: renderCadence,
                invalidatesCursorRects: false,
                notifiesChange: notifiesChange
            )
            displayHoverProgress(nil, renderCadence: renderCadence)
        case .loopStart, .loopEnd:
            let draggedEndpoint = updateLoopRange(
                for: activeDragMode,
                progress: dragProgress,
                enforcesMinimumDuration: false,
                renderCadence: renderCadence,
                invalidatesCursorRects: false,
                notifiesChange: notifiesChange
            )
            if let draggedEndpoint {
                displayHighlightedLoopEndpoint(
                    draggedEndpoint,
                    renderCadence: renderCadence
                )
                let boundaryProgress = draggedEndpoint == .start ?
                    loopRange.startProgress :
                    loopRange.endProgress
                displayHoverProgress(
                    boundaryProgress,
                    isArmed: true,
                    renderCadence: renderCadence
                )
            }
        default:
            return false
        }
        return loopRange != previousRange
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

    private func setLoopRangeEnabled(_ isEnabled: Bool, notifyChange: Bool) {
        guard isLoopRangeEnabled != isEnabled else {
            return
        }

        isLoopRangeEnabled = isEnabled
        updateTimelineRendererImmediately { renderer in
            renderer.displayLoopRangeEnabled(isEnabled, animated: true)
        }
        startTransientRenderPulse(duration: TimelineLoopRegionStyleAnimation.renderPulseDuration)
        if notifyChange {
            onLoopRangeEnabledChanged?(isEnabled)
        }
        invalidateTimelineCursorRects()
        requestTimelineRender()
    }

    private func updateLoopRegionRange(
        from anchorProgress: Float,
        to currentProgress: Float,
        renderCadence: TimelineRenderCadence = .immediate,
        invalidatesCursorRects: Bool = true,
        notifiesChange: Bool = true
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
            if renderCadence == .immediate {
                updateTimelineRendererImmediately { renderer in
                    renderer.displayLoopRange(nextRange)
                }
            }
            return
        }

        loopRange = nextRange
        if renderCadence == .immediate {
            updateTimelineRendererImmediately { renderer in
                renderer.displayLoopRange(nextRange)
            }
        } else {
            timelineRenderer?.publishInteractionLoopRange(nextRange)
        }
        if invalidatesCursorRects {
            invalidateTimelineCursorRects()
        }
        if notifiesChange {
            onLoopRangeChanged?(nextRange)
        }
        requestRender(cadence: renderCadence)
    }

    @discardableResult
    private func updateLoopRange(
        for dragMode: TimelineDragMode,
        progress: Float,
        enforcesMinimumDuration: Bool = true,
        renderCadence: TimelineRenderCadence = .immediate,
        invalidatesCursorRects: Bool = true,
        notifiesChange: Bool = true
    ) -> TimelineLoopEndpoint? {
        let fallbackEndpoint: TimelineLoopEndpoint
        let fallbackFixedProgress: Float
        switch dragMode {
        case .loopStart:
            fallbackEndpoint = .start
            fallbackFixedProgress = loopRange.endProgress
        case .loopEnd:
            fallbackEndpoint = .end
            fallbackFixedProgress = loopRange.startProgress
        case .loopRegion, .moveLoopRegion:
            return nil
        case
            .seek,
            .selection,
            .resizeSelectionStart,
            .resizeSelectionEnd,
            .horizontalScrollbar,
            .verticalScrollbar,
            .timelineEnd,
            .moveClip,
            .trimClipStart,
            .trimClipEnd,
            .clipMarquee,
            .clipFadeIn,
            .clipFadeOut,
            .automationPoint,
            .automationCurve,
            .automationMarquee,
            .automationPencil,
            .automationRamp,
            .automationEraser:
            return nil
        }

        let result = TimelineLoopEdgeResizeInteraction.resize(
            fixedProgress: activeLoopResizeFixedProgress ?? fallbackFixedProgress,
            draggedProgress: progress,
            fallbackEndpoint: fallbackEndpoint,
            minimumDuration: enforcesMinimumDuration ? minimumLoopDurationProgress() : 0
        )
        let nextRange = result.range

        guard nextRange != loopRange else {
            if renderCadence == .immediate {
                updateTimelineRendererImmediately { renderer in
                    renderer.displayLoopRange(nextRange)
                }
            }
            return result.draggedEndpoint
        }

        loopRange = nextRange
        if renderCadence == .immediate {
            updateTimelineRendererImmediately { renderer in
                renderer.displayLoopRange(nextRange)
            }
        } else {
            timelineRenderer?.publishInteractionLoopRange(nextRange)
        }
        if invalidatesCursorRects {
            invalidateTimelineCursorRects()
        }
        if notifiesChange {
            onLoopRangeChanged?(nextRange)
        }
        requestRender(cadence: renderCadence)
        return result.draggedEndpoint
    }

    private func updateMovingLoopRange(
        initialRange: TimelineLoopRange,
        anchorProgress: Float,
        currentProgress: Float,
        renderCadence: TimelineRenderCadence = .immediate,
        invalidatesCursorRects: Bool = true,
        notifiesChange: Bool = true
    ) {
        let nextRange = initialRange.moving(by: currentProgress - anchorProgress)
        guard nextRange != loopRange else {
            if renderCadence == .immediate {
                updateTimelineRendererImmediately { renderer in
                    renderer.displayLoopRange(nextRange)
                }
            }
            return
        }

        loopRange = nextRange
        if renderCadence == .immediate {
            updateTimelineRendererImmediately { renderer in
                renderer.displayLoopRange(nextRange)
            }
        } else {
            timelineRenderer?.publishInteractionLoopRange(nextRange)
        }
        if invalidatesCursorRects {
            invalidateTimelineCursorRects()
        }
        if notifiesChange {
            onLoopRangeChanged?(nextRange)
        }
        requestRender(cadence: renderCadence)
    }

    private func minimumLoopDurationProgress() -> Float {
        let pixelDuration = bounds.width > 0 ?
            viewport.durationProgress * Float(4 / bounds.width) :
            0.0001
        return max(pixelDuration, 0.0001)
    }

    private func loopDragMode(for point: CGPoint) -> TimelineDragMode? {
        guard
            bounds.width > 0,
            loopInteractionBandRect().contains(point)
        else {
            return nil
        }

        if let endpoint = loopRegionEndpointNear(point) {
            return endpoint == .start ? .loopStart : .loopEnd
        }

        if loopRegionContains(point) {
            return .moveLoopRegion
        }

        return .loopRegion
    }

    private func legacyLoopEndpointDragMode(for point: CGPoint) -> TimelineDragMode? {
        guard
            bounds.width > 0,
            loopInteractionBandRect().contains(point)
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
        case
            .seek,
            .selection,
            .resizeSelectionStart,
            .resizeSelectionEnd,
            .loopRegion,
            .moveLoopRegion,
            .horizontalScrollbar,
            .verticalScrollbar,
            .timelineEnd,
            .moveClip,
            .trimClipStart,
            .trimClipEnd,
            .clipMarquee,
            .clipFadeIn,
            .clipFadeOut,
            .automationPoint,
            .automationCurve,
            .automationMarquee,
            .automationPencil,
            .automationRamp,
            .automationEraser:
            return nil
        }
    }

    private func selectionResizeProgressPoint(from point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - activeSelectionDragOffsetX, y: point.y)
    }

    private func selectionEndpointHit(
        at point: CGPoint
    ) -> (endpoint: TimelineSelectionEndpoint, handleX: CGFloat)? {
        guard
            let selection = currentSelection,
            selection.durationProgress > 0,
            let geometry = selectionEndpointGeometry(
                for: selection,
                at: CACurrentMediaTime()
            ),
            geometry.verticalRect.contains(point)
        else {
            return nil
        }

        let endpoint = TimelineSelectionResizeInteraction.endpoint(
            at: point,
            startX: geometry.startX,
            endX: geometry.endX,
            verticalRect: geometry.verticalRect,
            viewportWidth: bounds.width,
            hitWidth: selectionEdgeHitWidth
        ) ?? retainedSelectionEndpoint(at: point, geometry: geometry)
        guard
            let endpoint,
            let handleX = geometry.handleX(for: endpoint)
        else {
            return nil
        }

        return (
            endpoint: endpoint,
            handleX: handleX
        )
    }

    private struct SelectionEndpointGeometry {
        let startX: CGFloat?
        let endX: CGFloat?
        let verticalRect: NSRect

        func handleX(for endpoint: TimelineSelectionEndpoint) -> CGFloat? {
            endpoint == .start ? startX : endX
        }
    }

    private func selectionEndpointGeometry(
        for selection: TimelineSelection,
        at timestamp: CFTimeInterval
    ) -> SelectionEndpointGeometry? {
        guard
            let verticalRect = selectionVerticalHitRect(for: selection)
        else {
            return nil
        }

        let startX = selectionHandleX(
            forTimelineProgress: selection.startProgressFloat,
            trackID: selection.trackID,
            timestamp: timestamp
        )
        let endX = selectionHandleX(
            forTimelineProgress: selection.endProgressFloat,
            trackID: selection.trackID,
            timestamp: timestamp
        )
        guard startX != nil || endX != nil else {
            return nil
        }

        return SelectionEndpointGeometry(
            startX: startX,
            endX: endX,
            verticalRect: verticalRect
        )
    }

    private func retainedSelectionEndpoint(
        at point: CGPoint,
        geometry: SelectionEndpointGeometry
    ) -> TimelineSelectionEndpoint? {
        guard let hoveredSelectionEndpoint else {
            return nil
        }

        guard let handleX = geometry.handleX(for: hoveredSelectionEndpoint) else {
            return nil
        }
        let maximumDistance = retainedSelectionEdgeHitWidth * 0.5
        return abs(point.x - handleX) <= maximumDistance ? hoveredSelectionEndpoint : nil
    }

    private func selectionEdgeHitRect(
        for endpoint: TimelineSelectionEndpoint,
        geometry: SelectionEndpointGeometry
    ) -> NSRect? {
        guard let handleX = geometry.handleX(for: endpoint) else {
            return nil
        }

        return TimelineSelectionResizeInteraction.hitRect(
            endpointX: handleX,
            verticalRect: geometry.verticalRect,
            viewportWidth: bounds.width,
            hitWidth: selectionEdgeHitWidth
        )
    }

    private func selectionVerticalHitRect(for selection: TimelineSelection) -> NSRect? {
        let layout = resolvedTrackLayoutForCurrentBounds()
        if let trackID = selection.trackID {
            guard
                let trackIndex = currentTrackIDs.firstIndex(of: trackID),
                let laneFrame = layout.laneFrame(forTrackIndex: trackIndex),
                laneFrame.isVisible
            else {
                return nil
            }

            let laneTop = CGFloat(laneFrame.top) * bounds.height
            let laneBottom = CGFloat(laneFrame.bottom) * bounds.height
            return NSRect(
                x: 0,
                y: bounds.height - laneBottom,
                width: bounds.width,
                height: max(laneBottom - laneTop, 1)
            ).intersection(bounds)
        }

        let rulerHeight = CGFloat(layout.rulerLaneHeight)
        let trackHeight = max(bounds.height - rulerHeight, 0)
        guard trackHeight > 0 else {
            return nil
        }
        return NSRect(x: 0, y: 0, width: bounds.width, height: trackHeight)
    }

    private func selectionHandleX(
        forTimelineProgress progress: Float,
        trackID: UUID?,
        timestamp: CFTimeInterval
    ) -> CGFloat? {
        guard bounds.width > 0 else {
            return nil
        }

        let viewportProgress: Float
        if
            SoundtimeFeatureFlags.waveformFisheye,
            let timelineRenderer
        {
            viewportProgress = timelineRenderer.visualViewportProgress(
                forTimelineProgress: progress,
                trackID: trackID,
                timestamp: timestamp
            )
        } else {
            viewportProgress = viewport.viewportProgress(forTimelineProgress: progress)
        }
        guard viewportProgress >= 0, viewportProgress <= 1 else {
            return nil
        }
        return CGFloat(viewportProgress) * bounds.width
    }

    private func loopDragProgressPoint(from point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - activeLoopDragOffsetX, y: point.y)
    }

    private func loopRegionContains(_ point: CGPoint) -> Bool {
        loopRegionRect()?.contains(point) == true
    }

    private func loopRegionRect() -> NSRect? {
        guard
            loopRange.durationProgress < 0.999,
            bounds.width > 0
        else {
            return nil
        }

        let rulerRect = loopInteractionBandRect()
        let startX = CGFloat(viewport.viewportProgress(
            forTimelineProgress: loopRange.startProgress
        )) * bounds.width
        let endX = CGFloat(viewport.viewportProgress(
            forTimelineProgress: loopRange.endProgress
        )) * bounds.width
        let left = max(min(startX, endX), 0)
        let right = min(max(startX, endX), bounds.width)
        guard right > left else {
            return nil
        }

        return NSRect(
            x: left,
            y: rulerRect.minY,
            width: max(right - left, 0),
            height: rulerRect.height
        )
    }

    private func loopRegionEndpointNear(_ point: CGPoint) -> TimelineLoopEndpoint? {
        guard
            loopInteractionBandRect().contains(point),
            loopRange.durationProgress < 0.999
        else {
            return nil
        }

        var candidates: [(endpoint: TimelineLoopEndpoint, x: CGFloat)] = []
        if let startX = loopHandleX(forTimelineProgress: loopRange.startProgress) {
            candidates.append((.start, startX))
        }
        if let endX = loopHandleX(forTimelineProgress: loopRange.endProgress) {
            candidates.append((.end, endX))
        }
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

        let rulerRect = loopInteractionBandRect()
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

        let rulerRect = loopInteractionBandRect()
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

    private func loopInteractionBandRect() -> NSRect {
        let rulerRect = rulerLaneRect()
        let loopHeight = min(
            CGFloat(TimelineRulerLaneGeometry.loopBandHeight(for: Float(rulerRect.height))),
            rulerRect.height
        )
        return NSRect(
            x: rulerRect.minX,
            y: rulerRect.maxY - loopHeight,
            width: rulerRect.width,
            height: loopHeight
        )
    }

    private func rulerSeekBandRect() -> NSRect {
        let rulerRect = rulerLaneRect()
        let loopRect = loopInteractionBandRect()
        return NSRect(
            x: rulerRect.minX,
            y: rulerRect.minY,
            width: rulerRect.width,
            height: max(loopRect.minY - rulerRect.minY, 0)
        )
    }

    private enum SeekGutter {
        case ruler
        case bottom
    }

    private struct SeekGutterHit {
        let gutter: SeekGutter
        let span: TimelineHoverGuideSpan
    }

    private func hoverGuideSpan(for rect: NSRect) -> TimelineHoverGuideSpan? {
        guard bounds.height > 0, rect.height > 0 else {
            return nil
        }
        return TimelineHoverGuideSpan(
            normalizedTop: Float((bounds.height - rect.maxY) / bounds.height),
            normalizedBottom: Float((bounds.height - rect.minY) / bounds.height)
        )
    }

    private func seekGutterHit(at point: CGPoint) -> SeekGutterHit? {
        guard bounds.contains(point), bounds.height > 0 else {
            return nil
        }

        let seekRect = rulerSeekBandRect()
        if seekRect.contains(point), let span = hoverGuideSpan(for: seekRect) {
            return SeekGutterHit(
                gutter: .ruler,
                span: span
            )
        }

        guard let span = bottomSeekGutterSpan() else {
            return nil
        }
        let bottomGutterHeight = CGFloat(1 - span.normalizedTop) * bounds.height
        guard point.y <= bottomGutterHeight else {
            return nil
        }
        return SeekGutterHit(gutter: .bottom, span: span)
    }

    private func bottomSeekGutterSpan() -> TimelineHoverGuideSpan? {
        guard bounds.height > 0 else {
            return nil
        }

        let layout = resolvedTrackLayoutForCurrentBounds()
        let contentBottom = (0..<layout.totalTrackCount).reduce(
            layout.rulerLaneHeight / Float(bounds.height)
        ) { currentBottom, trackIndex in
            max(currentBottom, layout.laneFrame(forTrackIndex: trackIndex)?.bottom ?? currentBottom)
        }
        let normalizedTop = min(max(contentBottom, 0), 1)
        guard normalizedTop < 0.998 else {
            return nil
        }
        return TimelineHoverGuideSpan(normalizedTop: normalizedTop, normalizedBottom: 1)
    }

    var seekGutterSpansForTesting: (ruler: TimelineHoverGuideSpan, bottom: TimelineHoverGuideSpan?) {
        let seekRect = rulerSeekBandRect()
        return (
            hoverGuideSpan(for: seekRect) ?? TimelineHoverGuideSpan(normalizedTop: 0, normalizedBottom: 0),
            bottomSeekGutterSpan()
        )
    }

    var rulerInteractionRectsForTesting: (loop: NSRect, seek: NSRect) {
        (loopInteractionBandRect(), rulerSeekBandRect())
    }

    func loopBodyStartsMoveForTesting(at point: CGPoint) -> Bool {
        loopDragMode(for: point) == .moveLoopRegion
    }

    func loopCreationStartsForTesting(at point: CGPoint) -> Bool {
        loopDragMode(for: point) == .loopRegion
    }

    var onHoverGuideStatePublishedForTesting: ((
        _ progress: Float?,
        _ isArmed: Bool,
        _ guideSpan: TimelineHoverGuideSpan?
    ) -> Void)?

    private func projectTime(atRawX x: CGFloat) -> TimeInterval {
        guard timelineDuration > 0, bounds.width > 0 else { return 0 }
        let visibleStart = Double(viewport.startProgress) * timelineDuration
        let visibleDuration = Double(viewport.durationProgress) * timelineDuration
        return max(visibleStart + Double(x / bounds.width) * visibleDuration, 0)
    }

    private func timelineEndMarkerX() -> CGFloat? {
        guard
            let timelineEndTime,
            timelineDuration > 0,
            viewport.durationProgress > 0
        else { return nil }
        let progress = Float(timelineEndTime / timelineDuration)
        let viewportProgress = viewport.viewportProgress(forTimelineProgress: progress)
        guard viewportProgress >= 0, viewportProgress <= 1 else { return nil }
        return CGFloat(viewportProgress) * bounds.width
    }

    private func timelineEndHandleHit(at point: CGPoint) -> Bool {
        guard let markerX = timelineEndMarkerX(), rulerLaneRect().contains(point) else {
            return false
        }
        return point.x >= markerX - 6 &&
            point.x <= markerX + TimelineEndOverlayView.handleSideLength + 4
    }

    private func updateTimelineEndDrag(to point: CGPoint) {
        let nextEnd = projectTime(atRawX: point.x)
        timelineEndTime = nextEnd
        let nextDuration = max(contentDuration, nextEnd)
        if nextDuration != timelineDuration {
            let previousDuration = timelineDuration
            timelineDuration = nextDuration
            if previousDuration > 0, nextDuration > 0, !viewport.isFull {
                let preservedViewport = viewport.preservingAbsoluteTimes(
                    previousDuration: previousDuration,
                    nextDuration: nextDuration
                )
                viewport = preservedViewport
                settledViewport = preservedViewport
                updateTimelineRendererImmediately { renderer in
                    renderer.displayViewport(preservedViewport)
                }
            }
            updateTimelineRendererImmediately { renderer in
                renderer.displayProjectDuration(nextDuration)
            }
        }
        updateTimelineEndOverlay()
        onTimelineEndChanged?(nextEnd)
        requestTimelineRender()
    }

    private func updateTimelineEndOverlay() {
        timelineEndOverlayView.rulerHeight = CGFloat(
            resolvedTrackLayoutForCurrentBounds().rulerLaneHeight
        )
        guard let timelineEndTime, timelineDuration > 0 else {
            timelineEndOverlayView.markerX = nil
            timelineEndOverlayView.dimsEntireViewport = false
            return
        }
        let progress = Float(timelineEndTime / timelineDuration)
        let viewportProgress = viewport.viewportProgress(forTimelineProgress: progress)
        timelineEndOverlayView.dimsEntireViewport = viewportProgress < 0
        timelineEndOverlayView.markerX = (0...1).contains(viewportProgress) ?
            CGFloat(viewportProgress) * bounds.width : nil
    }

    private func didMovePastSelectionThreshold(to point: CGPoint) -> Bool {
        guard let selectionAnchorPoint else {
            return false
        }

        return abs(point.x - selectionAnchorPoint.x) >= selectionDragThreshold ||
            abs(point.y - selectionAnchorPoint.y) >= selectionDragThreshold
    }

    private func didMovePastRegionCreationThreshold(to point: CGPoint) -> Bool {
        guard let selectionAnchorPoint else {
            return false
        }

        return TimelineRegionCreationGesture.hasCrossedDragThreshold(
            anchorX: selectionAnchorPoint.x,
            currentX: point.x
        )
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

    private func updateAutomationHover(for event: NSEvent) -> Bool {
        guard isAutomationModeVisible else {
            displayAutomationHover(for: nil)
            return false
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = automationHit(at: point) else {
            displayAutomationHover(for: nil)
            return false
        }
        displayAutomationHover(for: hit)
        switch hit.kind {
        case .point:
            NSCursor.pointingHand.set()
        case .segment where automationTool == .curve:
            NSCursor.resizeUpDown.set()
        case .segment, .fence, .lane:
            NSCursor.crosshair.set()
        }
        return true
    }

    private func displayAutomationHover(for hit: AutomationHit?) {
        let hover: TimelineAutomationHover?
        if let hit {
            switch hit.kind {
            case let .point(pointID):
                hover = TimelineAutomationHover(
                    trackID: hit.trackID,
                    pointID: pointID,
                    segmentLeadingPointID: nil,
                    isLineHovered: false
                )
            case let .segment(pointID):
                hover = TimelineAutomationHover(
                    trackID: hit.trackID,
                    pointID: nil,
                    segmentLeadingPointID: pointID,
                    isLineHovered: true
                )
            case let .fence(leadingPointID):
                hover = TimelineAutomationHover(
                    trackID: hit.trackID,
                    pointID: nil,
                    segmentLeadingPointID: leadingPointID,
                    isLineHovered: true
                )
            case .lane:
                hover = nil
            }
        } else {
            hover = nil
        }
        timelineRenderer?.publishInteractionAutomationHover(hover)
        requestRender(cadence: .coalescedInteraction)
    }

    private func displayAutomationPreview(
        points: [TimelineRenderState.Track.AutomationPoint]?,
        hit: AutomationHit?
    ) {
        let preview = points.flatMap { points in
            hit.map {
                TimelineAutomationPreview(
                    trackID: $0.trackID,
                    parameterID: $0.parameterID,
                    points: points
                )
            }
        }
        timelineRenderer?.publishInteractionAutomationPreview(preview)
        requestRender(cadence: .coalescedInteraction)
    }

    private func setAutomationSelection(_ selection: TimelineAutomationSelection) {
        automationSelection = selection
        let presentation: TimelineAutomationSelectionPresentation?
        if
            let address = selection.address,
            case let .track(trackID) = address.owner,
            !selection.pointIDs.isEmpty
        {
            presentation = TimelineAutomationSelectionPresentation(
                trackID: trackID,
                parameterID: address.parameterID.rawValue,
                pointIDs: selection.pointIDs
            )
        } else {
            presentation = nil
        }
        timelineRenderer?.displayAutomationSelection(presentation)
        requestRender(cadence: .coalescedInteraction)
    }

    private func updateAutomationSelection(
        pointID: UUID,
        hit: AutomationHit,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        let address = TimelineAutomationAddress.track(
            hit.trackID,
            parameterID: TimelineAutomationParameterID(rawValue: hit.parameterID)
        )
        let isSameLane = automationSelection.address == address
        let usesToggle = modifierFlags.contains(.command)
        let usesRange = modifierFlags.contains(.shift)

        if usesRange, isSameLane, let anchor = automationSelection.anchorPointID,
           let anchorIndex = hit.points.firstIndex(where: { $0.id == anchor }),
           let pointIndex = hit.points.firstIndex(where: { $0.id == pointID }) {
            let range = min(anchorIndex, pointIndex) ... max(anchorIndex, pointIndex)
            setAutomationSelection(TimelineAutomationSelection(
                address: address,
                pointIDs: Set(hit.points[range].map(\.id)),
                anchorPointID: anchor
            ))
            return
        }

        if usesToggle, isSameLane {
            var pointIDs = automationSelection.pointIDs
            if !pointIDs.insert(pointID).inserted {
                pointIDs.remove(pointID)
            }
            setAutomationSelection(TimelineAutomationSelection(
                address: pointIDs.isEmpty ? nil : address,
                pointIDs: pointIDs,
                anchorPointID: pointIDs.contains(pointID) ? pointID : pointIDs.first
            ))
            return
        }

        if isSameLane, automationSelection.pointIDs.contains(pointID) {
            return
        }
        setAutomationSelection(TimelineAutomationSelection(
            address: address,
            pointIDs: [pointID],
            anchorPointID: pointID
        ))
    }

    private func automationHit(at point: CGPoint) -> AutomationHit? {
        guard
            isAutomationModeVisible,
            let trackID = trackID(at: point),
            let trackIndex = currentTrackIDs.firstIndex(of: trackID),
            currentRenderTracks.indices.contains(trackIndex),
            let laneFrame = resolvedTrackLayoutForCurrentBounds().laneFrame(forTrackIndex: trackIndex)
        else { return nil }

        let track = currentRenderTracks[trackIndex]
        guard let lane = track.automationLanes.first(where: {
            $0.parameterID == displayedAutomationParameterID
        }) else { return nil }

        let height = Float(max(bounds.height, 1))
        let yFromTop = Float(bounds.height - point.y)
        let layout = resolvedTrackLayoutForCurrentBounds()
        let laneTop = laneFrame.top * height
        let laneBottom = laneFrame.bottom * height
        let visibleTop = max(laneTop, layout.rulerLaneHeight)
        let visibleBottom = min(laneBottom, height)
        guard yFromTop >= visibleTop, yFromTop <= visibleBottom, laneBottom - laneTop > 8 else { return nil }
        let automationRange = TimelineClipChromeMetrics.automationRange(
            laneTop: laneTop,
            laneBottom: laneBottom,
            viewportHeight: height
        )
        let curveTop = automationRange.top
        let curveBottom = automationRange.bottom
        let projectProgress = preciseProgress(for: point, followsVisualFisheye: false)
        let normalizedValue = min(max((curveBottom - yFromTop) / max(curveBottom - curveTop, 1), 0), 1)
        let sortedPoints = lane.points.sorted {
            if $0.projectProgress == $1.projectProgress { return $0.id.uuidString < $1.id.uuidString }
            return $0.projectProgress < $1.projectProgress
        }

        let pointRadius: CGFloat = 9
        for automationPoint in sortedPoints {
            let center = automationPointPosition(
                automationPoint,
                curveTop: curveTop,
                curveBottom: curveBottom
            )
            if hypot(point.x - center.x, point.y - center.y) <= pointRadius {
                return AutomationHit(
                    kind: .point(automationPoint.id),
                    trackID: trackID,
                    parameterID: lane.parameterID,
                    projectProgress: projectProgress,
                    normalizedValue: normalizedValue,
                    points: sortedPoints,
                    initialCurve: automationPoint.curveToNext
                )
            }
        }

        if sortedPoints.count > 1 {
            for index in 0..<(sortedPoints.count - 1) {
                let left = sortedPoints[index]
                let right = sortedPoints[index + 1]
                guard projectProgress >= left.projectProgress, projectProgress <= right.projectProgress else { continue }
                let curveValue = automationValue(
                    between: left,
                    and: right,
                    at: projectProgress
                )
                let lineYFromTop = curveBottom - curveValue * max(curveBottom - curveTop, 1)
                let lineY = bounds.height - CGFloat(lineYFromTop)
                if abs(point.y - lineY) <= 7 {
                    return AutomationHit(
                        kind: .segment(left.id),
                        trackID: trackID,
                        parameterID: lane.parameterID,
                        projectProgress: projectProgress,
                        normalizedValue: normalizedValue,
                        points: sortedPoints,
                        initialCurve: left.curveToNext
                    )
                }
            }
        }

        let heldLine: (value: Float, leadingPointID: UUID?)?
        if let first = sortedPoints.first, projectProgress < first.projectProgress {
            heldLine = (first.normalizedValue, nil)
        } else if let last = sortedPoints.last, projectProgress > last.projectProgress {
            heldLine = (last.normalizedValue, last.id)
        } else if sortedPoints.isEmpty {
            heldLine = (lane.defaultNormalizedValue, nil)
        } else {
            heldLine = nil
        }
        if let heldLine {
            let lineYFromTop = curveBottom - heldLine.value * max(curveBottom - curveTop, 1)
            let lineY = bounds.height - CGFloat(lineYFromTop)
            if abs(point.y - lineY) <= 7 {
                return AutomationHit(
                    kind: .fence(heldLine.leadingPointID),
                    trackID: trackID,
                    parameterID: lane.parameterID,
                    projectProgress: projectProgress,
                    normalizedValue: normalizedValue,
                    points: sortedPoints,
                    initialCurve: 0
                )
            }
        }

        return AutomationHit(
            kind: .lane,
            trackID: trackID,
            parameterID: lane.parameterID,
            projectProgress: projectProgress,
            normalizedValue: normalizedValue,
            points: sortedPoints,
            initialCurve: 0
        )
    }

    private func automationPointPosition(
        _ point: TimelineRenderState.Track.AutomationPoint,
        curveTop: Float,
        curveBottom: Float
    ) -> CGPoint {
        let viewportProgress = viewport.viewportProgress(forTimelineProgress: Float(point.projectProgress))
        let x = CGFloat(viewportProgress) * bounds.width
        let yFromTop = curveBottom - point.normalizedValue * max(curveBottom - curveTop, 1)
        return CGPoint(x: x, y: bounds.height - CGFloat(yFromTop))
    }

    private func automationValue(
        between left: TimelineRenderState.Track.AutomationPoint,
        and right: TimelineRenderState.Track.AutomationPoint,
        at progress: Double
    ) -> Float {
        let duration = right.projectProgress - left.projectProgress
        guard duration > 0 else { return right.normalizedValue }
        let linear = Float(min(max((progress - left.projectProgress) / duration, 0), 1))
        let curved = TimelineAutomationCurve.progress(linear, curve: left.curveToNext)
        return left.normalizedValue + (right.normalizedValue - left.normalizedValue) * curved
    }

    private func pointsAddingAutomationPoint(
        from hit: AutomationHit
    ) -> [TimelineRenderState.Track.AutomationPoint] {
        var points = hit.points
        points.append(TimelineRenderState.Track.AutomationPoint(
            id: UUID(),
            projectProgress: hit.projectProgress,
            normalizedValue: hit.normalizedValue,
            curveToNext: 0
        ))
        return points.sorted { $0.projectProgress < $1.projectProgress }
    }

    private func updateAutomationDrag(to point: CGPoint) {
        guard let hit = activeAutomationHit else { return }
        let crossedThreshold = didMovePastSelectionThreshold(to: point)
        if crossedThreshold { activeAutomationDidDrag = true }
        guard activeAutomationDidDrag else { return }

        switch activeDragMode {
        case .automationPoint:
            guard case let .point(pointID) = hit.kind else { return }
            guard let nextHit = constrainedAutomationDestination(for: hit, at: point) else { return }
            let address = TimelineAutomationAddress.track(
                hit.trackID,
                parameterID: TimelineAutomationParameterID(rawValue: hit.parameterID)
            )
            let selectedPointIDs = automationSelection.address == address &&
                automationSelection.pointIDs.contains(pointID) ?
                automationSelection.pointIDs : [pointID]
            guard
                let anchorPoint = activeAutomationPoints.first(where: { $0.id == pointID })
            else { return }
            let selectedPoints = activeAutomationPoints.filter { selectedPointIDs.contains($0.id) }
            let minimumProgress = selectedPoints.map(\.projectProgress).min() ?? anchorPoint.projectProgress
            let maximumProgress = selectedPoints.map(\.projectProgress).max() ?? anchorPoint.projectProgress
            let minimumValue = selectedPoints.map(\.normalizedValue).min() ?? anchorPoint.normalizedValue
            let maximumValue = selectedPoints.map(\.normalizedValue).max() ?? anchorPoint.normalizedValue
            var progressDelta = min(
                max(nextHit.projectProgress - anchorPoint.projectProgress, -minimumProgress),
                1 - maximumProgress
            )
            if !NSEvent.modifierFlags.contains(.option) {
                let desiredAnchorProgress = anchorPoint.projectProgress + progressDelta
                let snappedAnchorProgress = snappedAutomationProgress(
                    desiredAnchorProgress,
                    trackID: hit.trackID,
                    excluding: selectedPointIDs
                )
                progressDelta = min(
                    max(snappedAnchorProgress - anchorPoint.projectProgress, -minimumProgress),
                    1 - maximumProgress
                )
            }
            let valueDelta = min(
                max(nextHit.normalizedValue - anchorPoint.normalizedValue, -minimumValue),
                1 - maximumValue
            )
            let points = activeAutomationPoints.map { existing in
                guard selectedPointIDs.contains(existing.id) else { return existing }
                return TimelineRenderState.Track.AutomationPoint(
                    id: existing.id,
                    projectProgress: existing.projectProgress + progressDelta,
                    normalizedValue: existing.normalizedValue + valueDelta,
                    curveToNext: existing.curveToNext
                )
            }.sorted { $0.projectProgress < $1.projectProgress }
            displayAutomationPreview(points: points, hit: hit)
            NSCursor.closedHand.set()
        case .automationCurve:
            guard
                case let .segment(pointID) = hit.kind,
                let anchor = selectionAnchorPoint
            else { return }
            let nextCurve = min(max(hit.initialCurve + Float((point.y - anchor.y) / 80), -1), 1)
            let points = activeAutomationPoints.map { existing in
                guard existing.id == pointID else { return existing }
                return TimelineRenderState.Track.AutomationPoint(
                    id: existing.id,
                    projectProgress: existing.projectProgress,
                    normalizedValue: existing.normalizedValue,
                    curveToNext: nextCurve
                )
            }
            displayAutomationPreview(points: points, hit: hit)
            NSCursor.resizeUpDown.set()
        case .automationMarquee:
            guard let anchor = selectionAnchorPoint else { return }
            let rect = marqueeRect(from: anchor, to: point)
            displayAutomationMarquee(from: anchor, to: point)
            let address = TimelineAutomationAddress.track(
                hit.trackID,
                parameterID: TimelineAutomationParameterID(rawValue: hit.parameterID)
            )
            var pointIDs = automationPointIDs(in: rect, for: hit)
            if automationMarqueeBaseSelection.address == address {
                pointIDs.formUnion(automationMarqueeBaseSelection.pointIDs)
            }
            setAutomationSelection(TimelineAutomationSelection(
                address: pointIDs.isEmpty ? nil : address,
                pointIDs: pointIDs,
                anchorPointID: pointIDs.first
            ))
            NSCursor.crosshair.set()
        case .automationPencil:
            guard let destination = automationHitForTrack(
                hit,
                at: point,
                projectProgress: preciseProgress(for: point, followsVisualFisheye: false)
            ) else { return }
            if let lastAutomationDrawPoint,
               hypot(point.x - lastAutomationDrawPoint.x, point.y - lastAutomationDrawPoint.y) < 2 {
                return
            }
            activeAutomationDrawSamples.append(TimelineAutomationDrawPresentationSample(
                frameProgress: destination.projectProgress,
                normalizedValue: destination.normalizedValue
            ))
            lastAutomationDrawPoint = point
            displayAutomationPreview(points: automationDrawingPreviewPoints(for: hit), hit: hit)
            NSCursor.crosshair.set()
        case .automationRamp:
            guard let destination = automationHitForTrack(
                hit,
                at: point,
                projectProgress: preciseProgress(for: point, followsVisualFisheye: false)
            ), let first = activeAutomationDrawSamples.first else { return }
            activeAutomationDrawSamples = [first, TimelineAutomationDrawPresentationSample(
                frameProgress: destination.projectProgress,
                normalizedValue: destination.normalizedValue
            )]
            displayAutomationPreview(points: automationDrawingPreviewPoints(for: hit), hit: hit)
            NSCursor.crosshair.set()
        case .automationEraser:
            if let current = automationHit(at: point),
               current.trackID == hit.trackID,
               current.parameterID == hit.parameterID,
               case let .point(pointID) = current.kind {
                activeAutomationErasedPointIDs.insert(pointID)
            }
            displayAutomationPreview(
                points: hit.points.filter { !activeAutomationErasedPointIDs.contains($0.id) },
                hit: hit
            )
            NSCursor.disappearingItem.set()
        default:
            break
        }
    }

    private func automationDrawingPreviewPoints(
        for hit: AutomationHit
    ) -> [TimelineRenderState.Track.AutomationPoint] {
        guard !activeAutomationDrawSamples.isEmpty else { return hit.points }
        let minimum = activeAutomationDrawSamples.map(\.frameProgress).min() ?? 0
        let maximum = activeAutomationDrawSamples.map(\.frameProgress).max() ?? minimum
        var points = hit.points.filter { $0.projectProgress < minimum || $0.projectProgress > maximum }
        points.append(contentsOf: activeAutomationDrawSamples.map { sample in
            TimelineRenderState.Track.AutomationPoint(
                id: sample.id,
                projectProgress: sample.frameProgress,
                normalizedValue: sample.normalizedValue,
                curveToNext: 0
            )
        })
        return points.sorted { $0.projectProgress < $1.projectProgress }
    }

    private func constrainedAutomationDestination(
        for hit: AutomationHit,
        at point: CGPoint
    ) -> AutomationHit? {
        let progress = preciseProgress(for: point, followsVisualFisheye: false)
        guard let destination = automationHitForTrack(hit, at: point, projectProgress: progress) else {
            return nil
        }
        let anchorPoint: TimelineRenderState.Track.AutomationPoint?
        if case let .point(pointID) = hit.kind {
            anchorPoint = activeAutomationPoints.first(where: { $0.id == pointID })
        } else {
            anchorPoint = nil
        }
        let flags = NSEvent.modifierFlags
        return AutomationHit(
            kind: destination.kind,
            trackID: destination.trackID,
            parameterID: destination.parameterID,
            projectProgress: flags.contains(.option) ?
                (anchorPoint?.projectProgress ?? destination.projectProgress) : destination.projectProgress,
            normalizedValue: flags.contains(.shift) ?
                (anchorPoint?.normalizedValue ?? destination.normalizedValue) : destination.normalizedValue,
            points: destination.points,
            initialCurve: destination.initialCurve
        )
    }

    private func snappedAutomationProgress(
        _ progress: Double,
        trackID: UUID,
        excluding pointIDs: Set<UUID>
    ) -> Double {
        let threshold = Double(max(viewport.durationProgress, 0.000_001)) * 7 / Double(max(bounds.width, 1))
        var targets: [Double] = [0, 1, Double(currentPresentationPlayheadProgress())]
        targets.append(contentsOf: activeAutomationPoints.compactMap {
            pointIDs.contains($0.id) ? nil : $0.projectProgress
        })
        if let track = currentRenderTracks.first(where: { $0.id == trackID }) {
            for range in track.clipRanges {
                targets.append(Double(range.startProgress))
                targets.append(Double(range.endProgress))
            }
        }
        guard let nearest = targets.min(by: { abs($0 - progress) < abs($1 - progress) }),
              abs(nearest - progress) <= threshold else {
            return progress
        }
        return nearest
    }

    private func automationPointIDs(in rect: CGRect, for hit: AutomationHit) -> Set<UUID> {
        guard
            let trackIndex = currentTrackIDs.firstIndex(of: hit.trackID),
            let laneFrame = resolvedTrackLayoutForCurrentBounds().laneFrame(forTrackIndex: trackIndex)
        else { return [] }
        let height = Float(max(bounds.height, 1))
        let laneTop = laneFrame.top * height
        let laneBottom = laneFrame.bottom * height
        let automationRange = TimelineClipChromeMetrics.automationRange(
            laneTop: laneTop,
            laneBottom: laneBottom,
            viewportHeight: height
        )
        return Set(hit.points.compactMap { point in
            rect.contains(automationPointPosition(
                point,
                curveTop: automationRange.top,
                curveBottom: automationRange.bottom
            )) ? point.id : nil
        })
    }

    /// AppKit may coalesce drag events independently of the display refresh.
    /// Sampling from the display link keeps the preview attached to the pointer
    /// on every presented frame without committing graph edits during the drag.
    private func refreshLiveAutomationFromCurrentMouse() -> Bool {
        guard
            isAutomationDragActive,
            activeAutomationHit != nil,
            let point = currentMousePointInTimeline()
        else {
            return false
        }

        let wasDragging = activeAutomationDidDrag
        updateAutomationDrag(to: point)
        return wasDragging || activeAutomationDidDrag
    }

    private func automationHitForTrack(
        _ hit: AutomationHit,
        at point: CGPoint,
        projectProgress: Double
    ) -> AutomationHit? {
        guard
            let trackIndex = currentTrackIDs.firstIndex(of: hit.trackID),
            let laneFrame = resolvedTrackLayoutForCurrentBounds().laneFrame(forTrackIndex: trackIndex)
        else { return nil }
        let height = Float(max(bounds.height, 1))
        let laneTop = laneFrame.top * height
        let laneBottom = laneFrame.bottom * height
        let automationRange = TimelineClipChromeMetrics.automationRange(
            laneTop: laneTop,
            laneBottom: laneBottom,
            viewportHeight: height
        )
        let curveTop = automationRange.top
        let curveBottom = automationRange.bottom
        let yFromTop = Float(bounds.height - point.y)
        let value = min(max((curveBottom - yFromTop) / max(curveBottom - curveTop, 1), 0), 1)
        return AutomationHit(
            kind: hit.kind,
            trackID: hit.trackID,
            parameterID: hit.parameterID,
            projectProgress: min(max(projectProgress, 0), 1),
            normalizedValue: value,
            points: hit.points,
            initialCurve: hit.initialCurve
        )
    }

    private func finishAutomationInteraction(at point: CGPoint) {
        guard let hit = activeAutomationHit else { return }
        switch (activeDragMode, hit.kind) {
        case (.automationMarquee, _):
            displayAutomationMarquee(from: nil, to: nil)
            automationMarqueeBaseSelection = .empty
        case (.automationPencil, _), (.automationRamp, _):
            if let minimum = activeAutomationDrawSamples.map(\.frameProgress).min(),
               let maximum = activeAutomationDrawSamples.map(\.frameProgress).max(),
               !activeAutomationDrawSamples.isEmpty {
                onAutomationEditRequested?(TimelineAutomationEditRequest(
                    trackID: hit.trackID,
                    parameterID: hit.parameterID,
                    action: .replaceRange(
                        startProgress: minimum,
                        endProgress: maximum,
                        samples: activeAutomationDrawSamples
                    )
                ))
            }
        case (.automationEraser, _):
            if !activeAutomationErasedPointIDs.isEmpty {
                onAutomationEditRequested?(TimelineAutomationEditRequest(
                    trackID: hit.trackID,
                    parameterID: hit.parameterID,
                    action: .remove(pointIDs: activeAutomationErasedPointIDs)
                ))
                setAutomationSelection(.empty)
            }
        case (.automationPoint, let .point(pointID)):
            if activeAutomationDidDrag,
               let unconstrainedDestination = constrainedAutomationDestination(for: hit, at: point) {
                let address = TimelineAutomationAddress.track(
                    hit.trackID,
                    parameterID: TimelineAutomationParameterID(rawValue: hit.parameterID)
                )
                let pointIDs = automationSelection.address == address &&
                    automationSelection.pointIDs.contains(pointID) ?
                    automationSelection.pointIDs : [pointID]
                let destinationProgress = NSEvent.modifierFlags.contains(.option) ?
                    unconstrainedDestination.projectProgress :
                    snappedAutomationProgress(
                        unconstrainedDestination.projectProgress,
                        trackID: hit.trackID,
                        excluding: pointIDs
                    )
                onAutomationEditRequested?(TimelineAutomationEditRequest(
                    trackID: hit.trackID,
                    parameterID: hit.parameterID,
                    action: .move(
                        pointIDs: pointIDs,
                        anchorPointID: pointID,
                        frameProgress: destinationProgress,
                        normalizedValue: unconstrainedDestination.normalizedValue
                    )
                ))
            } else if Self.shouldDeleteAutomationPointOnClick(
                didDrag: activeAutomationDidDrag,
                modifierFlags: activeAutomationMouseDownModifierFlags
            ) {
                onAutomationEditRequested?(TimelineAutomationEditRequest(
                    trackID: hit.trackID,
                    parameterID: hit.parameterID,
                    action: .remove(pointIDs: [pointID])
                ))
                setAutomationSelection(.empty)
            }
        case (.automationPoint, .segment), (.automationPoint, .fence), (.automationPoint, .lane):
            let pointID = UUID()
            onAutomationEditRequested?(TimelineAutomationEditRequest(
                trackID: hit.trackID,
                parameterID: hit.parameterID,
                action: .add(
                    pointID: pointID,
                    frameProgress: hit.projectProgress,
                    normalizedValue: hit.normalizedValue
                )
            ))
            setAutomationSelection(TimelineAutomationSelection(
                address: .track(
                    hit.trackID,
                    parameterID: TimelineAutomationParameterID(rawValue: hit.parameterID)
                ),
                pointIDs: [pointID],
                anchorPointID: pointID
            ))
        case (.automationCurve, let .segment(pointID)):
            let curve: Float
            if let anchor = selectionAnchorPoint {
                curve = min(max(hit.initialCurve + Float((point.y - anchor.y) / 80), -1), 1)
            } else {
                curve = hit.initialCurve
            }
            onAutomationEditRequested?(TimelineAutomationEditRequest(
                trackID: hit.trackID,
                parameterID: hit.parameterID,
                action: .setCurve(leavingPointID: pointID, curve: curve)
            ))
        default:
            break
        }
        displayAutomationPreview(points: nil, hit: nil)
        activeAutomationHit = nil
        activeAutomationPoints.removeAll(keepingCapacity: true)
        activeAutomationDidDrag = false
        activeAutomationMouseDownModifierFlags = []
        activeAutomationDrawSamples.removeAll(keepingCapacity: true)
        activeAutomationErasedPointIDs.removeAll(keepingCapacity: true)
        lastAutomationDrawPoint = nil
    }

    static func shouldDeleteAutomationPointOnClick(
        didDrag: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard !didDrag else { return false }
        let selectionModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        return modifierFlags.intersection(selectionModifiers).isEmpty
    }

    private func cycleDisplayedAutomationParameter() {
        let choices = [
            TimelineAutomationParameterID.volume.rawValue,
            TimelineAutomationParameterID.pan.rawValue,
            TimelineAutomationParameterID.mute.rawValue,
        ]
        let index = choices.firstIndex(of: displayedAutomationParameterID) ?? 0
        setDisplayedAutomationParameter(TimelineAutomationParameterID(
            rawValue: choices[(index + 1) % choices.count]
        ))
    }

    private struct ClipHit {
        let request: TimelineClipFocusRequest
        let edge: TimelineClipEdge?
        let isHeader: Bool
    }

    private struct ClipPropertyHit {
        let request: TimelineClipFocusRequest
        let control: TimelineClipPropertyControl
        let preview: TimelineClipPropertyPreview
    }

    private struct ClipPropertyGeometry {
        let startX: CGFloat
        let endX: CGFloat
        let bodyLowerY: CGFloat
        let bodyUpperY: CGFloat
        let fadeInPoint: CGPoint
        let fadeOutPoint: CGPoint
    }

    private func marqueeRect(from anchor: CGPoint?, to point: CGPoint) -> CGRect {
        guard let anchor else { return .zero }
        return CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
    }

    private func clipFocusRequests(intersecting rect: CGRect) -> [TimelineClipFocusRequest] {
        guard !rect.isEmpty, timelineDuration > 0 else { return [] }
        let layout = resolvedTrackLayoutForCurrentBounds()
        var requests: [TimelineClipFocusRequest] = []
        for (trackIndex, track) in currentRenderTracks.enumerated() {
            guard
                let lane = layout.laneFrame(forTrackIndex: trackIndex),
                currentTrackIDs.indices.contains(trackIndex)
            else { continue }
            let trackDuration = track.durationHint ?? track.waveformOverview?.duration ?? 0
            guard trackDuration > 0 else { continue }
            let scale = trackDuration / timelineDuration
            let laneRect = CGRect(
                x: 0,
                y: bounds.height - CGFloat(lane.bottom) * bounds.height,
                width: bounds.width,
                height: CGFloat(lane.height) * bounds.height
            )
            guard laneRect.intersects(rect) else { continue }
            for range in track.clipRanges where !range.isSilent {
                let start = Float(range.startProgress * scale)
                let end = Float(range.endProgress * scale)
                let clipRect = CGRect(
                    x: CGFloat(viewport.viewportProgress(forTimelineProgress: start)) * bounds.width,
                    y: laneRect.minY,
                    width: CGFloat((end - start) / viewport.durationProgress) * bounds.width,
                    height: laneRect.height
                )
                guard clipRect.intersects(rect) else { continue }
                requests.append(TimelineClipFocusRequest(
                    clipID: range.id,
                    trackID: track.id,
                    trackLocalRange: range,
                    projectStartProgress: start,
                    projectEndProgress: end
                ))
            }
        }
        return requests
    }

    private func clipPropertyHit(at point: CGPoint) -> ClipPropertyHit? {
        guard let hit = clipHit(at: point), hit.request.trackLocalRange.isSelected else { return nil }
        let request = hit.request
        guard
            let trackIndex = currentTrackIDs.firstIndex(of: request.trackID),
            let lane = resolvedTrackLayoutForCurrentBounds().laneFrame(forTrackIndex: trackIndex),
            let geometry = clipPropertyGeometry(for: request, lane: lane)
        else { return nil }
        let range = request.trackLocalRange
        var handleCandidates: [(TimelineClipPropertyControl, CGPoint)] = []
        if range.fadeInProgress > 0 {
            handleCandidates.append((.fadeIn, geometry.fadeInPoint))
        }
        if range.fadeOutProgress > 0 {
            handleCandidates.append((.fadeOut, geometry.fadeOutPoint))
        }
        if let handle = handleCandidates
            .map({ (control: $0.0, distance: hypot(point.x - $0.1.x, point.y - $0.1.y)) })
            .filter({ $0.distance <= 14 })
            .min(by: { $0.distance < $1.distance })
        {
            return ClipPropertyHit(
                request: request,
                control: handle.control,
                preview: TimelineClipPropertyPreview(
                    trackID: request.trackID,
                    clipID: request.clipID,
                    gain: range.gain,
                    fadeInProgress: range.fadeInProgress,
                    fadeOutProgress: range.fadeOutProgress
                )
            )
        }

        var lineCandidates: [(TimelineClipPropertyControl, CGFloat)] = []
        if range.fadeInProgress > 0 {
            lineCandidates.append((
                .fadeIn,
                distance(
                    from: point,
                    toSegmentFrom: CGPoint(x: geometry.startX, y: geometry.bodyLowerY),
                    to: geometry.fadeInPoint
                )
            ))
        }
        if range.fadeOutProgress > 0 {
            lineCandidates.append((
                .fadeOut,
                distance(
                    from: point,
                    toSegmentFrom: geometry.fadeOutPoint,
                    to: CGPoint(x: geometry.endX, y: geometry.bodyLowerY)
                )
            ))
        }
        guard let best = lineCandidates.filter({ $0.1 <= 7 }).min(by: { $0.1 < $1.1 }) else {
            return nil
        }
        return ClipPropertyHit(
            request: request,
            control: best.0,
            preview: TimelineClipPropertyPreview(
                trackID: request.trackID,
                clipID: request.clipID,
                gain: range.gain,
                fadeInProgress: range.fadeInProgress,
                fadeOutProgress: range.fadeOutProgress
            )
        )
    }

    private func clipPropertyGeometry(
        for request: TimelineClipFocusRequest,
        lane: TimelineTrackLaneFrame
    ) -> ClipPropertyGeometry? {
        let startX = CGFloat(viewport.viewportProgress(forTimelineProgress: request.projectStartProgress)) * bounds.width
        let endX = CGFloat(viewport.viewportProgress(forTimelineProgress: request.projectEndProgress)) * bounds.width
        let width = endX - startX
        guard width >= 36 else { return nil }

        let chromeGeometry = TimelineClipChromeMetrics.verticalGeometry(
            laneTop: Float(lane.top) * Float(bounds.height),
            laneBottom: Float(lane.bottom) * Float(bounds.height),
            viewportHeight: Float(bounds.height)
        )
        // Chrome metrics use top-down Metal coordinates; pointer geometry uses
        // AppKit's bottom-up coordinates.
        let clipTopY = bounds.height - CGFloat(chromeGeometry.clipTop)
        let clipBottomY = bounds.height - CGFloat(chromeGeometry.clipBottom)
        let headerHeight = CGFloat(chromeGeometry.headerHeight)
        let bodyUpperY = max(clipTopY - headerHeight, clipBottomY)
        let range = request.trackLocalRange
        let fadeInX = startX + width * CGFloat(range.fadeInProgress)
        let fadeOutX = endX - width * CGFloat(range.fadeOutProgress)
        return ClipPropertyGeometry(
            startX: startX,
            endX: endX,
            bodyLowerY: clipBottomY,
            bodyUpperY: bodyUpperY,
            fadeInPoint: CGPoint(x: fadeInX, y: bodyUpperY),
            fadeOutPoint: CGPoint(x: fadeOutX, y: bodyUpperY)
        )
    }

    private func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let lengthSquared = delta.x * delta.x + delta.y * delta.y
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let projection = ((point.x - start.x) * delta.x + (point.y - start.y) * delta.y) / lengthSquared
        let unit = min(max(projection, 0), 1)
        let closest = CGPoint(x: start.x + delta.x * unit, y: start.y + delta.y * unit)
        return hypot(point.x - closest.x, point.y - closest.y)
    }

    private func updateClipPropertyPreview(to point: CGPoint) {
        guard
            let request = activeClipRequest,
            let control = activeClipPropertyControl,
            var preview = activeClipPropertyPreview
        else { return }
        switch control {
        case .fadeIn:
            let progress = progress(for: point, followsVisualFisheye: false)
            preview = TimelineClipPropertyPreview(
                trackID: preview.trackID,
                clipID: preview.clipID,
                gain: preview.gain,
                fadeInProgress: Double(min(max((progress - request.projectStartProgress) / max(request.projectEndProgress - request.projectStartProgress, 0.000_001), 0), Float(1 - preview.fadeOutProgress))),
                fadeOutProgress: preview.fadeOutProgress
            )
        case .fadeOut:
            let progress = progress(for: point, followsVisualFisheye: false)
            preview = TimelineClipPropertyPreview(
                trackID: preview.trackID,
                clipID: preview.clipID,
                gain: preview.gain,
                fadeInProgress: preview.fadeInProgress,
                fadeOutProgress: Double(min(max((request.projectEndProgress - progress) / max(request.projectEndProgress - request.projectStartProgress, 0.000_001), 0), Float(1 - preview.fadeInProgress)))
            )
        }
        displayClipPropertyPreview(preview)
    }

    private func clipHit(at point: CGPoint) -> ClipHit? {
        guard
            timelineDuration > 0,
            let trackID = trackID(at: point),
            let trackIndex = currentTrackIDs.firstIndex(of: trackID),
            let track = currentRenderTracks.first(where: { $0.id == trackID }),
            let lane = resolvedTrackLayoutForCurrentBounds().laneFrame(forTrackIndex: trackIndex)
        else {
            return nil
        }
        let trackDuration = track.durationHint ?? track.waveformOverview?.duration ?? 0
        guard trackDuration > 0 else {
            return nil
        }
        let trackDurationProgress = min(max(trackDuration / timelineDuration, 0), 1)
        let projectProgress = Double(progress(for: point, followsVisualFisheye: false))
        let edgeTolerance = max(7 / max(bounds.width, 1) * CGFloat(viewport.durationProgress), 0.000_001)
        let yFromTop = bounds.height - point.y
        let laneTopPixels = CGFloat(lane.top) * bounds.height
        let isHeader = yFromTop >= laneTopPixels && yFromTop <= laneTopPixels + min(22, CGFloat(lane.height) * bounds.height)

        var best: (range: TimelineRenderState.ClipRange, edge: TimelineClipEdge?, distance: Double)?
        for range in track.clipRanges where !range.isSilent {
            let start = range.startProgress * trackDurationProgress
            let end = range.endProgress * trackDurationProgress
            let startDistance = abs(projectProgress - start)
            let endDistance = abs(projectProgress - end)
            let edge: TimelineClipEdge?
            let distance: Double
            if startDistance <= endDistance, startDistance <= Double(edgeTolerance) {
                edge = .leading
                distance = startDistance
            } else if endDistance < startDistance, endDistance <= Double(edgeTolerance) {
                edge = .trailing
                distance = endDistance
            } else if projectProgress >= start, projectProgress <= end {
                edge = nil
                distance = 0
            } else {
                continue
            }
            if best == nil || distance < best!.distance {
                best = (range, edge, distance)
            }
        }
        guard let best else {
            return nil
        }
        let request = TimelineClipFocusRequest(
            clipID: best.range.id,
            trackID: trackID,
            trackLocalRange: best.range,
            projectStartProgress: Float(best.range.startProgress * trackDurationProgress),
            projectEndProgress: Float(best.range.endProgress * trackDurationProgress)
        )
        return ClipHit(request: request, edge: best.edge, isHeader: isHeader)
    }

    private func clipFocusRequest(at point: CGPoint) -> TimelineClipFocusRequest? {
        if let hit = clipHit(at: point) {
            return hit.request
        }
        guard
            timelineDuration > 0,
            let trackID = trackID(at: point),
            let track = currentRenderTracks.first(where: { $0.id == trackID })
        else {
            return nil
        }

        let trackDuration = track.durationHint ?? track.waveformOverview?.duration ?? 0
        guard trackDuration > 0 else {
            return nil
        }

        let trackDurationProgress = min(max(trackDuration / timelineDuration, 0), 1)
        guard trackDurationProgress > 0 else {
            return nil
        }

        let projectProgress = Double(progress(for: point))
        let localProgress = min(max(projectProgress / trackDurationProgress, 0), 1)
        let epsilon = max(Double(viewport.durationProgress) / Double(max(bounds.width, 1)) * 2, 0.000_001)
        guard let clipRange = track.clipRanges.first(where: { range in
            !range.isSilent &&
            localProgress >= range.startProgress - epsilon &&
                localProgress <= range.endProgress + epsilon
        }) else {
            return nil
        }

        return TimelineClipFocusRequest(
            clipID: clipRange.id,
            trackID: trackID,
            trackLocalRange: clipRange,
            projectStartProgress: Float(clipRange.startProgress * trackDurationProgress),
            projectEndProgress: Float(clipRange.endProgress * trackDurationProgress)
        )
    }

    private func selectedClipFocusRequests() -> [TimelineClipFocusRequest] {
        guard timelineDuration > 0 else {
            return []
        }
        return currentRenderTracks.flatMap { track -> [TimelineClipFocusRequest] in
            let trackDuration = track.durationHint ?? track.waveformOverview?.duration ?? 0
            guard trackDuration > 0 else {
                return []
            }
            let trackDurationProgress = min(max(trackDuration / timelineDuration, 0), 1)
            return track.clipRanges.compactMap { range in
                guard range.isSelected, !range.isSilent else {
                    return nil
                }
                return TimelineClipFocusRequest(
                    clipID: range.id,
                    trackID: track.id,
                    trackLocalRange: range,
                    projectStartProgress: Float(range.startProgress * trackDurationProgress),
                    projectEndProgress: Float(range.endProgress * trackDurationProgress)
                )
            }
        }
    }
}
