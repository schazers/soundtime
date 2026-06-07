import AppKit
import QuartzCore
import UniformTypeIdentifiers

final class WorkspaceView: NSView {
    private static var defaultDebugToolsVisible: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private enum FisheyeDefaults {
        static let radius = 0.080
        static let power = 0.50
        static let start = 1.0
        static let full = 150.0
        static let curve = 1.0
        static let activationMilliseconds = 111.0
    }

    private enum FadeEffect {
        case fadeIn
        case fadeOut

        var displayName: String {
            switch self {
            case .fadeIn:
                return "fade in"
            case .fadeOut:
                return "fade out"
            }
        }
    }

    private enum LastEffect {
        case gain(decibels: Double)
        case normalize
        case fade(FadeEffect)
    }

    private enum ProjectTrackMixPublication {
        case immediate
        case coalesced
    }

    private enum EditScope: Int, CaseIterable {
        case track = 0
        case selected = 1
        case group = 2
        case all = 3

        var title: String {
            switch self {
            case .track:
                return "Track"
            case .selected:
                return "Selected"
            case .group:
                return "Group"
            case .all:
                return "All"
            }
        }
    }

    private struct ProjectTrack {
        var id: UUID
        var editGroupID: UUID? = nil
        var name: String
        var sourceURL: URL
        var durationHint: TimeInterval?
        var sourceWaveformOverview: WaveformOverview?
        var waveformOverview: WaveformOverview?
        var decodedAudioBuffer: DecodedAudioBuffer?
        var zeroCrossingIndex: AudioZeroCrossingIndex?
        var zeroCrossingProbe: WAVZeroCrossingProbe?
        var audioTimeline: AudioEditTimeline?
        var fileTimeline: AudioFileEditTimeline?
        var ownsSourceFile: Bool
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool
        var importID: UUID
        var editRevision: Int
    }

    private struct ProjectTrackUndoSnapshot {
        var tracks: [ProjectTrack]
        var activeTrackID: UUID?
        var selectedTrackID: UUID?
        var selectedTrackIDs: Set<UUID> = []
        var selectedTimelineRange: TimelineSelection?
        var restoreProgress: Float?
    }

    private enum UndoAction {
        case timeline(trackID: UUID?, timeline: AudioEditTimeline)
        case projectTracks(ProjectTrackUndoSnapshot)
    }

    private struct AudioClipboard: Sendable {
        let id: UUID
        let buffer: DecodedAudioBuffer?
        let waveformOverview: WaveformOverview
        let fileClipSourceURL: URL?
        let fileClip: AudioFileEditTimeline.Clip?

        init(
            id: UUID = UUID(),
            buffer: DecodedAudioBuffer?,
            waveformOverview: WaveformOverview,
            fileClipSourceURL: URL? = nil,
            fileClip: AudioFileEditTimeline.Clip? = nil
        ) {
            self.id = id
            self.buffer = buffer
            self.waveformOverview = waveformOverview
            self.fileClipSourceURL = fileClipSourceURL
            self.fileClip = fileClip
        }
    }

    private struct EditableSelectionTarget {
        let trackIndex: Int
        let displaySelection: TimelineSelection
        let editSelection: TimelineSelection
    }

    private struct RippleDeleteTrackEdit {
        let trackIndex: Int
        let trackID: UUID
        let displaySelection: TimelineSelection
        let editSelection: TimelineSelection
        let deletedDuration: TimeInterval
        let editedDuration: TimeInterval
        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
    }

    private struct ClearTrackEdit {
        let trackIndex: Int
        let trackID: UUID
        let editSelection: TimelineSelection
        let clearedDuration: TimeInterval
        let editedDuration: TimeInterval
        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
    }

    private struct SplitTrackEdit {
        let trackIndex: Int
        let trackID: UUID
        let editedDuration: TimeInterval
        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
    }

    private struct SilenceCleanupResult: Sendable {
        let frameRanges: [Range<Int>]
        let detectedRegionCount: Int
        let deletedFrameCount: Int
        let deletedDuration: TimeInterval
    }

    private struct DeadAirReviewCandidate: Sendable, Identifiable {
        let id: UUID
        let trackID: UUID
        let trackEditRevision: Int
        let displaySelection: TimelineSelection
        let editSelection: TimelineSelection
        let frameRange: Range<Int>
        let confidence: Float
        let reason: String
        let estimatedRemovedDuration: TimeInterval

        var displayStartProgress: Float {
            displaySelection.startProgressFloat
        }

        var displayEndProgress: Float {
            displaySelection.endProgressFloat
        }
    }

    private struct DeadAirReviewResult: Sendable {
        let candidates: [DeadAirReviewCandidate]
        let detectedRegionCount: Int
    }

    private enum ProjectMixTrackSource: Sendable {
        case decoded(DecodedAudioBuffer)
        case timeline(AudioEditTimeline)
        case file(URL)
        case fileTimeline(URL, AudioFileEditTimeline)
    }

    private struct ProjectMixTrackSnapshot: Sendable {
        let volume: Float
        let source: ProjectMixTrackSource
        let zeroCrossingIndex: AudioZeroCrossingIndex?
    }

    private struct ProjectMixResult: Sendable {
        let buffer: DecodedAudioBuffer
        let zeroCrossingIndex: AudioZeroCrossingIndex
        let trackCount: Int
    }

    private final class RecordingPreviewCoalescer: @unchecked Sendable {
        private let queue = DispatchQueue(label: "Soundtime.recording.preview.coalescer", qos: .userInteractive)
        private let minimumFlushInterval: TimeInterval = 1.0 / 45.0
        private var pendingChunks: [AudioRecordingChunk] = []
        private var isFlushScheduled = false
        private var lastFlushTimestamp = CACurrentMediaTime()

        func enqueue(
            _ chunk: AudioRecordingChunk,
            deliver: @escaping @Sendable ([AudioRecordingChunk]) -> Void
        ) {
            queue.async { [minimumFlushInterval] in
                self.pendingChunks.append(chunk)
                guard !self.isFlushScheduled else {
                    return
                }

                self.isFlushScheduled = true
                let now = CACurrentMediaTime()
                let delay = max(0, minimumFlushInterval - (now - self.lastFlushTimestamp))
                self.queue.asyncAfter(deadline: .now() + delay) {
                    let chunks = self.takePendingChunksLocked()
                    guard !chunks.isEmpty else {
                        return
                    }

                    deliver(chunks)
                }
            }
        }

        func reset() {
            queue.sync {
                pendingChunks.removeAll(keepingCapacity: true)
                isFlushScheduled = false
                lastFlushTimestamp = CACurrentMediaTime()
            }
        }

        func drainPending() -> [AudioRecordingChunk] {
            queue.sync {
                takePendingChunksLocked()
            }
        }

        private func takePendingChunksLocked() -> [AudioRecordingChunk] {
            let chunks = pendingChunks
            pendingChunks.removeAll(keepingCapacity: true)
            isFlushScheduled = false
            lastFlushTimestamp = CACurrentMediaTime()
            return chunks
        }
    }

    private var projectTracks: [ProjectTrack] = []
    private var activeTrackID: UUID?
    private var selectedTrackID: UUID?
    private var selectedTrackIDs: Set<UUID> = []
    private var trackSelectionAnchorID: UUID?
    private var defaultEditGroupID = UUID()
    private var currentProjectURL: URL?
    private var hasRestoredLastProject = false
    private var isLoadingProject = false
    private var audioClipboard: AudioClipboard? {
        didSet {
            updateEffectCommandState()
        }
    }
    private var activeImportID = UUID()
    private var selectedAudioFile: AudioFileMetadata?
    private var decodedAudioBuffer: DecodedAudioBuffer?
    private var audioTimeline: AudioEditTimeline?
    private var editUndoStack: [UndoAction] = [] {
        didSet {
            scheduleAutosaveIfNeeded()
        }
    }
    private var loadedAudioSummary: String?
    private var selectedTimelineRange: TimelineSelection?
    private var deadAirCandidates: [DeadAirReviewCandidate] = []
    private var activeDeadAirCandidateID: UUID?
    private var deadAirAuditionStopTask: Task<Void, Never>?
    private let highConfidenceSilenceThreshold: Float = 0.86
    private var lastEffect: LastEffect?
    private var currentPlayheadFrame = 0
    private var displayedFrameCount = 0
    private var displayedSampleRate: Double = 0
    private var currentPlaybackStatus = "idle"
    private var playbackTimer: Timer?
    private var loudnessMeterTimer: Timer?
    private var pendingProjectTrackMixUpdate = false
    private var scheduledProjectTrackMixWorkItem: DispatchWorkItem?
    private var lastProjectTrackMixPublishTimestamp = CACurrentMediaTime()
    private var keyDownMonitor: Any?
    private var audioDevicePreferencesObserver: NSObjectProtocol?
    private var debugToolsVisible = false
    private var editScope: EditScope = .group
    private let editMaterializationDelay: TimeInterval = 0.75
    private let deleteMaterializationDelay: TimeInterval = 2.0
    private let deleteVisualRefreshDelay: TimeInterval = 0.13
    private let editWaveformRefinementDelay: TimeInterval = 0.20
    private var editMaterializationTasks: [UUID: Task<Void, Never>] = [:]
    private var editMaterializationRequestIDs: [UUID: UUID] = [:]
    private var editWaveformRefinementTasks: [UUID: Task<Void, Never>] = [:]
    private var editWaveformRefinementRequestIDs: [UUID: UUID] = [:]
    private let inputRecorder = AudioInputRecorder()
    private var recordingTrackID: UUID?
    private var recordingTakeWriter: StreamingWAVTakeWriter?
    private var recordingStartUndoSnapshot: ProjectTrackUndoSnapshot?
    private var recordingStartUndoStackCount: Int?
    private var recordingSampleRate: Double = 0
    private var recordingAccumulator: LiveRecordingWaveformAccumulator?
    private let recordingPreviewCoalescer = RecordingPreviewCoalescer()
    private var lastRecordingVisualUpdateTimestamp = CACurrentMediaTime()
    private var trackControlViewsByID: [UUID: TrackControlView] = [:]
    private var trackControlReusePool: [TrackControlView] = []
    private var trackIndicesByID: [UUID: Int] = [:]
    private var trackIndexCacheTrackCount = 0
    private var currentTrackLaneLayout = ResolvedTimelineTrackLayout(
        totalTrackCount: 0,
        viewportHeight: 1,
        preferredTrackHeight: TimelineTrackLayout.defaultPreferredTrackHeight,
        requestedScrollOffset: 0
    )
    private let playbackController: PlaybackEngine = PlaybackEngineFactory.makeDefault()
    private let playbackRefreshRate: TimeInterval = 10
    private let loudnessMeterRefreshRate: TimeInterval = 60
    private let fallbackLoudnessMaximumAudibleTracks = 32
    private let fallbackLoudnessMaximumFrameCount = 384
    private let trackMixCoalescingInterval: TimeInterval = 1.0 / 72.0
    private var visualPlayheadProgress: Float = 0
    private var visualPlayheadAnchorTimestamp = CACurrentMediaTime()
    private var visualPlaybackActive = false
    private var displayedPlaybackActive: Bool?
    private var lastVisualAudioCorrectionTimestamp = CACurrentMediaTime()
    private let visualAudioSyncDeadband: TimeInterval = 0.006
    private let visualAudioSyncHardCorrectionThreshold: TimeInterval = 0.075
    private let visualAudioSyncResponseDuration: TimeInterval = 0.12
    private let visualAudioSyncMinimumCorrectionInterval: TimeInterval = 0.1
    private let wavPreviewLevels = [
        WAVPreviewLevel(targetBinCount: 512, samplesPerBin: 6),
        WAVPreviewLevel(targetBinCount: 768, samplesPerBin: 6),
        WAVPreviewLevel(targetBinCount: 1_024, samplesPerBin: 6),
        WAVPreviewLevel(targetBinCount: 1_536, samplesPerBin: 6),
        WAVPreviewLevel(targetBinCount: 2_048, samplesPerBin: 8),
        WAVPreviewLevel(targetBinCount: 3_072, samplesPerBin: 8),
        WAVPreviewLevel(targetBinCount: 4_096, samplesPerBin: 8),
        WAVPreviewLevel(targetBinCount: 6_144, samplesPerBin: 10),
        WAVPreviewLevel(targetBinCount: 8_192, samplesPerBin: 10),
        WAVPreviewLevel(targetBinCount: 12_288, samplesPerBin: 12),
        WAVPreviewLevel(targetBinCount: 16_384, samplesPerBin: 12),
        WAVPreviewLevel(targetBinCount: 24_576, samplesPerBin: 12),
        WAVPreviewLevel(targetBinCount: 32_768, samplesPerBin: 14),
        WAVPreviewLevel(targetBinCount: 49_152, samplesPerBin: 14),
        WAVPreviewLevel(targetBinCount: 65_536, samplesPerBin: 16),
        WAVPreviewLevel(targetBinCount: 98_304, samplesPerBin: 10),
        WAVPreviewLevel(targetBinCount: 131_072, samplesPerBin: 10),
        WAVPreviewLevel(targetBinCount: 196_608, samplesPerBin: 8),
        WAVPreviewLevel(targetBinCount: 262_144, samplesPerBin: 8),
        WAVPreviewLevel(targetBinCount: 393_216, samplesPerBin: 6),
        WAVPreviewLevel(targetBinCount: 524_288, samplesPerBin: 6),
        WAVPreviewLevel(targetBinCount: 786_432, samplesPerBin: 4),
        WAVPreviewLevel(targetBinCount: 1_048_576, samplesPerBin: 4),
        WAVPreviewLevel(targetBinCount: 1_572_864, samplesPerBin: 3),
        WAVPreviewLevel(targetBinCount: 2_097_152, samplesPerBin: 3),
        WAVPreviewLevel(targetBinCount: 3_145_728, samplesPerBin: 2),
        WAVPreviewLevel(targetBinCount: 4_194_304, samplesPerBin: 2),
    ]
    private let optimisticEditPreviewBinLimit = 262_144
    private let optimisticEditPreviewSamplesPerBin = 2

    private struct WAVPreviewLevel {
        let targetBinCount: Int
        let samplesPerBin: Int
    }

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Soundtime")
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = NSColor.labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let metadataLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Drop audio here")
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = NSColor.secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let timeReadoutLabel: NSTextField = {
        let label = NSTextField(labelWithString: "00:00.000 / 00:00.000")
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        label.alignment = .right
        label.textColor = NSColor.white
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let framesPerSecondLabel: NSTextField = {
        let label = NSTextField(labelWithString: "0 fps - +/-0.0 max 0.0")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .right
        label.textColor = NSColor.secondaryLabelColor
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let frameRateHistoryView = FrameRateHistoryView()
    private let performanceDashboardButton = PerformanceDashboardButton()
    private let volumeControl = VolumeControlView()
    private let loudnessMeter = LoudnessMeterView()
    private let transportControlPanel = TransportControlPanelView()
    private let editScopeStack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    private let editScopeTitleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Delete scope")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor.secondaryLabelColor
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    private let editScopeControl: NSSegmentedControl = {
        let control = NSSegmentedControl()
        control.segmentCount = EditScope.allCases.count
        for scope in EditScope.allCases {
            control.setLabel(scope.title, forSegment: scope.rawValue)
            control.setWidth(scope == .selected ? 72 : 54, forSegment: scope.rawValue)
        }
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        control.selectedSegment = EditScope.group.rawValue
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }()
    private let editScopeHintLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    private let agentCommandController = AgentCommandController()
    private let agentCommandBar = AgentCommandBarView()
    private let fisheyeRadiusControl = TimelineTuningSliderView(
        title: "Fish Radius",
        value: FisheyeDefaults.radius,
        range: 0.02...0.20,
        valueFormat: "%.3f"
    )
    private let fisheyePowerControl = TimelineTuningSliderView(
        title: "Fish Power",
        value: FisheyeDefaults.power,
        range: 0.30...0.95,
        valueFormat: "%.2f"
    )
    private let fisheyeStartControl = TimelineTuningSliderView(
        title: "Fish Start",
        value: FisheyeDefaults.start,
        range: 0...180,
        valueFormat: "%.0fs"
    )
    private let fisheyeFullControl = TimelineTuningSliderView(
        title: "Fish Full",
        value: FisheyeDefaults.full,
        range: 60...600,
        valueFormat: "%.0fs"
    )
    private let fisheyeCurveControl = TimelineTuningSliderView(
        title: "Fish Curve",
        value: FisheyeDefaults.curve,
        range: 0.35...3.00,
        valueFormat: "%.2f"
    )
    private let fisheyeActivateDurationControl = TimelineTuningSliderView(
        title: "Fish Activate Dur",
        value: FisheyeDefaults.activationMilliseconds,
        range: 40...1_200,
        valueFormat: "%.0fms"
    )
    private let fisheyeControlsStack: NSStackView = {
        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fill
        stackView.spacing = 10
        stackView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stackView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()
    private let trackControlsStack: TrackControlsViewportView = {
        let view = TrackControlsViewportView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    private let timelineSurface = TimelineView()
    private let addTrackButton = AddTrackButton()
    private let exportProgressOverlay = ExportProgressOverlayView()
    private let gainEffectOverlay = GainEffectOverlayView()
    private var framesPerSecondWidthConstraint: NSLayoutConstraint?
    private var trackControlsBelowDebugConstraint: NSLayoutConstraint?
    private var trackControlsBelowHeaderConstraint: NSLayoutConstraint?
    private var lastResponsiveLayoutWidth: CGFloat = -1
    private let autosaveID = UUID()
    private let autosaveDelay: TimeInterval = 1.5
    private var autosaveWorkItem: DispatchWorkItem?
    private var isAutosaveSuppressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func mouseDown(with event: NSEvent) {
        clearSelectedTrack()
        super.mouseDown(with: event)
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = SoundtimeColors.windowBackground.cgColor
        installTransportKeyMonitor()
        SoundtimeMainThreadStallMonitor.shared.start()

        timelineSurface.translatesAutoresizingMaskIntoConstraints = false
        frameRateHistoryView.translatesAutoresizingMaskIntoConstraints = false
        performanceDashboardButton.translatesAutoresizingMaskIntoConstraints = false
        addTrackButton.translatesAutoresizingMaskIntoConstraints = false
        transportControlPanel.translatesAutoresizingMaskIntoConstraints = false
        timelineSurface.onAudioFileDropped = { [weak self] url in
            self?.loadDroppedAudioFile(at: url)
        }
        timelineSurface.onTogglePlayback = { [weak self] in
            self?.togglePlayback()
        }
        timelineSurface.onDeleteSelection = { [weak self] in
            self?.deleteSelectedTrackOrSelection()
        }
        timelineSurface.onRemoveTimeRangeRequested = { [weak self] in
            self?.removeTimeRangeAcrossScope()
        }
        timelineSurface.onClearSelection = { [weak self] in
            self?.clearSelection()
        }
        timelineSurface.onCutSelection = { [weak self] in
            self?.cutSelection()
        }
        timelineSurface.onCopySelection = { [weak self] in
            self?.copySelection()
        }
        timelineSurface.onPasteAudio = { [weak self] in
            self?.pasteAudio()
        }
        timelineSurface.onDuplicateRegionRequested = { [weak self] in
            self?.duplicateRegion()
        }
        timelineSurface.onSplitAtPlayhead = { [weak self] in
            self?.splitAtPlayhead()
        }
        timelineSurface.onInsertSilenceRequested = { [weak self] in
            self?.insertSilenceOrTime()
        }
        timelineSurface.onHealAdjacentClipsRequested = { [weak self] in
            self?.healAdjacentClips()
        }
        timelineSurface.onNudgeSelectionRequested = { [weak self] direction in
            self?.nudgeSelection(direction: direction)
        }
        timelineSurface.onSlipClipContentsRequested = { [weak self] direction in
            self?.slipClipContents(direction: direction)
        }
        timelineSurface.onSnapSelectionRequested = { [weak self] in
            self?.snapSelectionToPlayheadEdgesOrSilence()
        }
        timelineSurface.onSelectTimeAcrossLinkedTracksRequested = { [weak self] in
            self?.selectTimeAcrossLinkedTracks()
        }
        timelineSurface.onSelectAllClipsOnTrackRequested = { [weak self] in
            self?.selectAllClipsOnTrack()
        }
        timelineSurface.onUndo = { [weak self] in
            self?.undoLastEdit()
        }
        timelineSurface.onExportRequested = { [weak self] in
            self?.exportCurrentAudio()
        }
        timelineSurface.onOpenProjectRequested = { [weak self] in
            self?.openProject()
        }
        timelineSurface.onOpenRecentProjectRequested = { [weak self] url in
            self?.loadProject(from: url)
        }
        timelineSurface.onClearRecentProjectsRequested = {
            SoundtimeProjectStore.clearRecentProjectURLs()
        }
        timelineSurface.onSaveProjectRequested = { [weak self] in
            self?.saveProject()
        }
        timelineSurface.onSaveProjectAsRequested = { [weak self] in
            self?.saveProjectAs()
        }
        timelineSurface.onToggleDebugTools = { [weak self] in
            self?.toggleDebugTools()
        }
        timelineSurface.onGainRequested = { [weak self] in
            self?.showGainEffect()
        }
        timelineSurface.onNormalizeRequested = { [weak self] in
            self?.applyNormalizeEffect()
        }
        timelineSurface.onDeleteSilenceRequested = { [weak self] in
            self?.reviewDeadAir()
        }
        timelineSurface.onAcceptDeadAirCandidateRequested = { [weak self] in
            self?.acceptActiveDeadAirCandidate()
        }
        timelineSurface.onAcceptHighConfidenceDeadAirCandidatesRequested = { [weak self] in
            self?.acceptHighConfidenceDeadAirCandidates()
        }
        timelineSurface.onRejectDeadAirCandidateRequested = { [weak self] in
            self?.rejectActiveDeadAirCandidate()
        }
        timelineSurface.onAuditionDeadAirCandidateRequested = { [weak self] in
            self?.auditionActiveDeadAirCandidate()
        }
        timelineSurface.onNextDeadAirCandidateRequested = { [weak self] in
            self?.stepActiveDeadAirCandidate(by: 1)
        }
        timelineSurface.onPreviousDeadAirCandidateRequested = { [weak self] in
            self?.stepActiveDeadAirCandidate(by: -1)
        }
        timelineSurface.onFadeInRequested = { [weak self] in
            self?.applyFadeEffect(.fadeIn)
        }
        timelineSurface.onFadeOutRequested = { [weak self] in
            self?.applyFadeEffect(.fadeOut)
        }
        timelineSurface.onReapplyLastEffect = { [weak self] in
            self?.reapplyLastEffect()
        }
        timelineSurface.onSeekRequested = { [weak self] progress in
            self?.seek(to: progress)
        }
        timelineSurface.onPlayFromProgress = { [weak self] progress in
            self?.play(from: progress)
        }
        timelineSurface.onSelectionChanged = { [weak self] selection in
            self?.updateSelection(selection)
        }
        timelineSurface.onTrimRequested = { [weak self] trimRange in
            self?.trimTimeline(to: trimRange)
        }
        timelineSurface.onClipBoundaryTrimRequested = { [weak self] trim in
            self?.trimClipBoundary(trim)
        }
        timelineSurface.onFrameStatsChanged = { [weak self] frameStats in
            self?.updateFrameStats(frameStats)
        }
        timelineSurface.onTimelineInteractionBegan = { [weak self] in
            self?.clearSelectedTrack()
        }
        timelineSurface.onTrackLaneLayoutChanged = { [weak self] layout in
            self?.updateTrackLaneLayout(layout)
        }
        addTrackButton.onPressed = { [weak self] in
            self?.addEmptyTrack()
        }
        trackControlsStack.onVerticalScroll = { [weak self] deltaPixels in
            self?.timelineSurface.scrollTracks(byPixels: deltaPixels)
        }
        volumeControl.onVolumeChanged = { [weak self] volume in
            self?.playbackController.setPerceptualVolume(volume)
        }
        volumeControl.onVolumeEditingEnded = { [weak self] in
            self?.updateLoudnessMeter()
        }
        performanceDashboardButton.onPressed = { [weak self] in
            PerformanceDashboardWindowController.shared.showDashboard(relativeTo: self?.window)
        }
        editScopeControl.target = self
        editScopeControl.action = #selector(editScopeChanged(_:))
        editScopeStack.addArrangedSubview(editScopeTitleLabel)
        editScopeStack.addArrangedSubview(editScopeControl)
        editScopeStack.addArrangedSubview(editScopeHintLabel)
        transportControlPanel.onAction = { [weak self] action in
            self?.handleTransportAction(action)
        }
        agentCommandBar.onSubmit = { [weak self] prompt in
            self?.agentCommandController.submit(prompt: prompt)
        }
        agentCommandBar.onBlurRequested = { [weak self] in
            guard let self else {
                return
            }
            self.window?.makeFirstResponder(self.timelineSurface)
        }
        agentCommandController.onStateChanged = { [weak self] state in
            self?.agentCommandBar.presentationState = state
        }
        agentCommandController.onRequestSubmitted = { [weak self] request in
            self?.updateStatus("agent: \(request.prompt)")
        }
        agentCommandController.onCommandRequested = { [weak self] command in
            self?.performAgentCommand(command) ??
                AgentCommandResult(
                    status: .failed,
                    message: "Agent command unavailable"
                )
        }
        agentCommandController.onResult = { [weak self] result in
            self?.updateStatus(result.message)
        }
        configureFisheyeTuningControls()
        installAudioDevicePreferencesObserver()
        gainEffectOverlay.onGainChanged = { [weak self] _, gain in
            self?.previewSelectedGain(gain)
        }
        gainEffectOverlay.onConfirm = { [weak self] decibels, gain in
            self?.confirmSelectedGain(decibels: decibels, gain: gain)
        }
        gainEffectOverlay.onCancel = { [weak self] in
            self?.cancelSelectedGainPreview()
        }

        addSubview(titleLabel)
        addSubview(metadataLabel)
        addSubview(framesPerSecondLabel)
        addSubview(performanceDashboardButton)
        addSubview(frameRateHistoryView)
        addSubview(transportControlPanel)
        addSubview(volumeControl)
        addSubview(timeReadoutLabel)
        addSubview(loudnessMeter)
        addSubview(editScopeStack)
        addSubview(fisheyeControlsStack)
        addSubview(trackControlsStack)
        addSubview(addTrackButton)
        addSubview(timelineSurface)
        addSubview(agentCommandBar)
        addSubview(exportProgressOverlay)
        addSubview(gainEffectOverlay)

        let fisheyeTrailingConstraint = fisheyeControlsStack.trailingAnchor.constraint(
            lessThanOrEqualTo: loudnessMeter.leadingAnchor,
            constant: -18
        )
        fisheyeTrailingConstraint.priority = .defaultLow
        let metadataToTransportConstraint = metadataLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: timeReadoutLabel.leadingAnchor,
            constant: -18
        )
        metadataToTransportConstraint.priority = .defaultLow
        let volumeToLoudnessConstraint = volumeControl.trailingAnchor.constraint(
            lessThanOrEqualTo: loudnessMeter.leadingAnchor,
            constant: -18
        )
        volumeToLoudnessConstraint.priority = .defaultLow
        let framesPerSecondWidthConstraint = framesPerSecondLabel.widthAnchor.constraint(equalToConstant: 390)
        framesPerSecondWidthConstraint.priority = .defaultLow
        let frameRateHistoryWidthConstraint = frameRateHistoryView.widthAnchor.constraint(equalToConstant: 132)
        frameRateHistoryWidthConstraint.priority = .defaultLow
        let transportPanelWidthConstraint = transportControlPanel.widthAnchor.constraint(equalToConstant: 104)
        transportPanelWidthConstraint.priority = .defaultHigh
        let volumeControlWidthConstraint = volumeControl.widthAnchor.constraint(equalToConstant: 150)
        volumeControlWidthConstraint.priority = .defaultLow
        let loudnessMeterWidthConstraint = loudnessMeter.widthAnchor.constraint(equalToConstant: 292)
        loudnessMeterWidthConstraint.priority = .defaultLow
        let agentCommandBarWidthConstraint = agentCommandBar.widthAnchor.constraint(equalToConstant: 620)
        agentCommandBarWidthConstraint.priority = .defaultHigh
        let trackControlsBelowDebugConstraint = trackControlsStack.topAnchor.constraint(
            equalTo: fisheyeControlsStack.bottomAnchor,
            constant: 14
        )
        let trackControlsBelowHeaderConstraint = trackControlsStack.topAnchor.constraint(
            equalTo: titleLabel.bottomAnchor,
            constant: 56
        )
        self.framesPerSecondWidthConstraint = framesPerSecondWidthConstraint
        self.trackControlsBelowDebugConstraint = trackControlsBelowDebugConstraint
        self.trackControlsBelowHeaderConstraint = trackControlsBelowHeaderConstraint

        NSLayoutConstraint.activate([
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: 66),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 84),

            metadataLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            metadataLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 14),
            metadataToTransportConstraint,

            framesPerSecondLabel.centerYAnchor.constraint(equalTo: frameRateHistoryView.centerYAnchor),
            framesPerSecondLabel.trailingAnchor.constraint(equalTo: performanceDashboardButton.leadingAnchor, constant: -8),
            framesPerSecondWidthConstraint,

            performanceDashboardButton.centerYAnchor.constraint(equalTo: frameRateHistoryView.centerYAnchor),
            performanceDashboardButton.trailingAnchor.constraint(equalTo: frameRateHistoryView.leadingAnchor, constant: -8),
            performanceDashboardButton.widthAnchor.constraint(equalToConstant: 30),
            performanceDashboardButton.heightAnchor.constraint(equalToConstant: 24),

            frameRateHistoryView.bottomAnchor.constraint(equalTo: loudnessMeter.topAnchor, constant: -6),
            frameRateHistoryView.trailingAnchor.constraint(equalTo: loudnessMeter.trailingAnchor),
            frameRateHistoryWidthConstraint,
            frameRateHistoryView.heightAnchor.constraint(equalToConstant: 24),

            transportControlPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            transportControlPanel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            transportPanelWidthConstraint,
            transportControlPanel.heightAnchor.constraint(equalToConstant: 96),

            volumeControl.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            volumeControl.leadingAnchor.constraint(equalTo: transportControlPanel.trailingAnchor, constant: 20),
            volumeControlWidthConstraint,
            volumeControl.heightAnchor.constraint(equalToConstant: 30),
            volumeToLoudnessConstraint,

            timeReadoutLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            timeReadoutLabel.trailingAnchor.constraint(equalTo: transportControlPanel.leadingAnchor, constant: -16),

            loudnessMeter.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            loudnessMeter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            loudnessMeterWidthConstraint,
            loudnessMeter.heightAnchor.constraint(equalToConstant: 34),

            editScopeStack.leadingAnchor.constraint(equalTo: trackControlsStack.trailingAnchor, constant: 10),
            editScopeStack.trailingAnchor.constraint(lessThanOrEqualTo: loudnessMeter.leadingAnchor, constant: -20),
            editScopeStack.bottomAnchor.constraint(equalTo: trackControlsStack.topAnchor, constant: -10),
            editScopeStack.heightAnchor.constraint(equalToConstant: 26),
            editScopeHintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),

            fisheyeControlsStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            fisheyeControlsStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            fisheyeTrailingConstraint,
            fisheyeControlsStack.heightAnchor.constraint(equalToConstant: 34),

            trackControlsBelowDebugConstraint,
            trackControlsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            trackControlsStack.bottomAnchor.constraint(equalTo: agentCommandBar.topAnchor, constant: -22),
            trackControlsStack.widthAnchor.constraint(equalToConstant: 158),

            addTrackButton.leadingAnchor.constraint(equalTo: trackControlsStack.leadingAnchor),
            addTrackButton.trailingAnchor.constraint(equalTo: trackControlsStack.trailingAnchor),
            addTrackButton.centerYAnchor.constraint(equalTo: agentCommandBar.centerYAnchor),
            addTrackButton.heightAnchor.constraint(equalToConstant: 36),

            timelineSurface.topAnchor.constraint(equalTo: trackControlsStack.topAnchor),
            timelineSurface.leadingAnchor.constraint(equalTo: trackControlsStack.trailingAnchor, constant: 10),
            timelineSurface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            timelineSurface.bottomAnchor.constraint(equalTo: trackControlsStack.bottomAnchor),

            agentCommandBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            agentCommandBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
            agentCommandBar.leadingAnchor.constraint(greaterThanOrEqualTo: addTrackButton.trailingAnchor, constant: 24),
            agentCommandBar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            agentCommandBarWidthConstraint,

            exportProgressOverlay.topAnchor.constraint(equalTo: topAnchor),
            exportProgressOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            exportProgressOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            exportProgressOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),

            gainEffectOverlay.topAnchor.constraint(equalTo: topAnchor),
            gainEffectOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            gainEffectOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            gainEffectOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        updateEffectCommandState()
        updateWaveformFisheyeTuning()
        setDebugToolsVisible(Self.defaultDebugToolsVisible)
        updateLoudnessMeter()
        updateTransportControlState(isPlaying: false)
        startLoudnessMeterTimer()
    }

    override func layout() {
        super.layout()
        updateResponsiveChromeVisibilityIfNeeded()
        layoutTrackControlViews()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else {
            return
        }

        tearDownRuntimeState()
    }

    private func tearDownRuntimeState() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let audioDevicePreferencesObserver {
            NotificationCenter.default.removeObserver(audioDevicePreferencesObserver)
            self.audioDevicePreferencesObserver = nil
        }
        stopPlaybackTimer()
        scheduledProjectTrackMixWorkItem?.cancel()
        scheduledProjectTrackMixWorkItem = nil
        pendingProjectTrackMixUpdate = false
        loudnessMeterTimer?.invalidate()
        loudnessMeterTimer = nil
        inputRecorder.stop()
        inputRecorder.onChunk = nil
        recordingTakeWriter?.cancel()
        recordingTakeWriter = nil
        recordingTrackID = nil
        recordingStartUndoSnapshot = nil
        recordingStartUndoStackCount = nil
        recordingSampleRate = 0
        recordingAccumulator = nil
        playbackController.clear()
        deleteAllOwnedSourceFiles()
        ImportWorkBudget.shared.setPlaybackActive(false)
    }

    private func configureFisheyeTuningControls() {
        let controls = [
            fisheyeRadiusControl,
            fisheyePowerControl,
            fisheyeStartControl,
            fisheyeFullControl,
            fisheyeCurveControl,
            fisheyeActivateDurationControl,
        ]
        for control in controls {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.onValueChanged = { [weak self] _ in
                self?.updateWaveformFisheyeTuning()
            }
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            fisheyeControlsStack.addArrangedSubview(control)
            let widthConstraint = control.widthAnchor.constraint(equalToConstant: 136)
            widthConstraint.priority = .defaultLow
            widthConstraint.isActive = true
        }
    }

    private func toggleDebugTools() {
        setDebugToolsVisible(!debugToolsVisible)
    }

    private func setDebugToolsVisible(_ isVisible: Bool) {
        debugToolsVisible = isVisible
        timelineSurface.isDebugToolsVisible = isVisible
        lastResponsiveLayoutWidth = -1
        updateResponsiveChromeVisibilityIfNeeded()
        needsLayout = true
    }

    private func updateResponsiveChromeVisibilityIfNeeded() {
        guard abs(bounds.width - lastResponsiveLayoutWidth) > 0.5 else {
            return
        }

        lastResponsiveLayoutWidth = bounds.width
        let width = bounds.width
        let showsTitle = width >= 290
        let showsMetadata = width >= 560
        let showsTime = width >= 440
        let showsVolume = width >= 620
        let showsLoudness = width >= 760
        let showsFrameHistory = width >= 380
        let showsEditScope = width >= 720
        let showsDebugText = debugToolsVisible && width >= 760
        let showsDebugSliders = SoundtimeFeatureFlags.waveformFisheye && debugToolsVisible && width >= 980

        titleLabel.isHidden = !showsTitle
        metadataLabel.isHidden = !showsMetadata
        timeReadoutLabel.isHidden = !showsTime
        volumeControl.isHidden = !showsVolume
        loudnessMeter.isHidden = !showsLoudness
        frameRateHistoryView.isHidden = !showsFrameHistory
        framesPerSecondLabel.isHidden = !showsDebugText
        editScopeStack.isHidden = !showsEditScope
        fisheyeControlsStack.isHidden = !showsDebugSliders
        framesPerSecondWidthConstraint?.constant = showsDebugText ? 390 : 0
        trackControlsBelowDebugConstraint?.isActive = showsDebugSliders
        trackControlsBelowHeaderConstraint?.isActive = !showsDebugSliders
    }

    @objc private func editScopeChanged(_ sender: NSSegmentedControl) {
        guard let nextScope = EditScope(rawValue: sender.selectedSegment) else {
            sender.selectedSegment = editScope.rawValue
            return
        }

        editScope = nextScope
        updateEditScopeHint()
        updateStatus(currentPlaybackStatus)
        window?.makeFirstResponder(timelineSurface)
    }

    private func handleTransportAction(_ action: TransportControlPanelView.TransportAction) {
        switch action {
        case .togglePlayback:
            togglePlayback()
        }

        window?.makeFirstResponder(timelineSurface)
        updateTransportControlState(isPlaying: playbackController.isPlaying)
    }

    private func updateTransportControlState(isPlaying: Bool) {
        transportControlPanel.isPlaying = isPlaying
        transportControlPanel.isTransportEnabled = playbackController.hasSource || recordingTrackID != nil
    }

    private func updateWaveformFisheyeTuning() {
        timelineSurface.updateWaveformFisheyeTuning(
            radius: Float(fisheyeRadiusControl.value),
            exponent: Float(fisheyePowerControl.value),
            minimumVisibleDuration: fisheyeStartControl.value,
            maximumVisibleDuration: fisheyeFullControl.value,
            fadeCurve: Float(fisheyeCurveControl.value),
            activationDuration: fisheyeActivateDurationControl.value / 1_000
        )
    }

    private func resetWaveformFisheyeTuningToDefaults() {
        fisheyeRadiusControl.value = FisheyeDefaults.radius
        fisheyePowerControl.value = FisheyeDefaults.power
        fisheyeStartControl.value = FisheyeDefaults.start
        fisheyeFullControl.value = FisheyeDefaults.full
        fisheyeCurveControl.value = FisheyeDefaults.curve
        fisheyeActivateDurationControl.value = FisheyeDefaults.activationMilliseconds
        updateWaveformFisheyeTuning()
    }

    private func installTransportKeyMonitor() {
        guard keyDownMonitor == nil else {
            return
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            return self.handleWindowKeyDown(event)
        }
    }

    private func installAudioDevicePreferencesObserver() {
        guard audioDevicePreferencesObserver == nil else {
            return
        }

        audioDevicePreferencesObserver = NotificationCenter.default.addObserver(
            forName: AudioDevicePreferences.didChangeNotification,
            object: AudioDevicePreferences.shared,
            queue: .main
        ) { [weak self] notification in
            let changedDeviceKind = notification.userInfo?[
                AudioDevicePreferences.changedDeviceKindUserInfoKey
            ] as? String
            Task { @MainActor in
                self?.handleAudioDevicePreferencesChanged(changedDeviceKind: changedDeviceKind)
            }
        }
    }

    private func handleAudioDevicePreferencesChanged(changedDeviceKind: String?) {
        if changedDeviceKind == "input", recordingTrackID != nil {
            stopRecording()
        }

        do {
            try playbackController.refreshOutputDevice()
            updateStatus("audio device updated")
        } catch {
            stopPlaybackTimer()
            updateStatus("audio device failed: \(error.localizedDescription)")
        }
    }

    private func handleWindowKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else {
            return event
        }

        if window?.firstResponder is NSTextView {
            return event
        }

        let shortcutModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if
            event.charactersIgnoringModifiers?.lowercased() == "d",
            shortcutModifiers == [.command, .shift]
        {
            toggleDebugTools()
            return nil
        }

        if event.keyCode == 6, event.modifierFlags.contains(.command) {
            undoLastEdit()
            return nil
        }

        if
            event.charactersIgnoringModifiers?.lowercased() == "b",
            event.modifierFlags.contains(.command)
        {
            splitAtPlayhead()
            return nil
        }

        if event.keyCode == 53 {
            dismissTimelineSelection()
            return nil
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            if event.modifierFlags.contains(.command) {
                clearSelection()
                return nil
            }

            if selectedTrackID != nil || (selectedTimelineRange?.durationProgress ?? 0) > 0 {
                deleteSelectedTrackOrSelection()
                return nil
            }
        }

        let transportModifierMask: NSEvent.ModifierFlags = [.command, .control, .option]
        guard
            event.keyCode == 49,
            event.modifierFlags.intersection(transportModifierMask).isEmpty
        else {
            return event
        }

        guard !event.isARepeat else {
            return nil
        }

        togglePlayback()
        return nil
    }

    func restoreLastProjectIfNeeded() {
        guard !hasRestoredLastProject else {
            return
        }
        hasRestoredLastProject = true

        if let lastProjectURL = SoundtimeProjectStore.lastProjectURL() {
            loadProject(from: lastProjectURL)
            return
        }

        if let recoveryURL = SoundtimeProjectStore.recoverableAutosaveURLs().first {
            loadRecoveredAutosave(from: recoveryURL)
        }
    }

    private func refreshProjectTimelineDisplay(
        rebuildControls: Bool = true,
        animateWaveformTransition: Bool = true
    ) {
        timelineSurface.displayTracks(
            timelineRenderTracks(),
            animateWaveformTransition: animateWaveformTransition
        )
        publishSelectedTracksToTimeline()
        if rebuildControls {
            refreshTrackControls()
        }
    }

    private func refreshProjectTrackMixDisplay() {
        timelineSurface.displayTrackMixSettings(timelineMixRenderTracks())
    }

    private func timelineRenderTracks() -> [TimelineRenderState.Track] {
        projectTracks.map { track in
            TimelineRenderState.Track(
                id: track.id,
                waveformVersion: waveformVersion(for: track),
                waveformOverview: track.waveformOverview,
                durationHint: track.waveformOverview?.duration ??
                    track.audioTimeline?.duration ??
                    track.fileTimeline?.duration ??
                    track.decodedAudioBuffer?.duration ??
                    track.durationHint,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed,
                clipRanges: timelineClipRanges(for: track)
            )
        }
    }

    private func timelineMixRenderTracks() -> [TimelineRenderState.Track] {
        projectTracks.map { track in
            let durationHint = track.waveformOverview?.duration ??
                track.audioTimeline?.duration ??
                track.fileTimeline?.duration ??
                track.decodedAudioBuffer?.duration ??
                track.durationHint
            return TimelineRenderState.Track(
                id: track.id,
                waveformVersion: track.editRevision,
                waveformOverview: nil,
                durationHint: durationHint,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed,
                hasWaveform: track.waveformOverview?.isEmpty == false,
                clipRanges: timelineClipRanges(for: track)
            )
        }
    }

    private func timelineClipRanges(for track: ProjectTrack) -> [TimelineRenderState.ClipRange] {
        let ranges: [TimelineRenderState.ClipRange]
        if let fileTimeline = track.fileTimeline {
            ranges = fileTimeline.clipRanges.map {
                TimelineRenderState.ClipRange(
                    startProgress: $0.startProgress,
                    endProgress: $0.endProgress
                )
            }
        } else if let audioTimeline = track.audioTimeline {
            ranges = audioTimeline.clipRanges.map {
                TimelineRenderState.ClipRange(
                    startProgress: $0.startProgress,
                    endProgress: $0.endProgress
                )
            }
        } else {
            ranges = []
        }

        if !ranges.isEmpty {
            return ranges
        }

        return trackDuration(for: track) > 0 ? [
            TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)
        ] : []
    }

    private func waveformVersion(for track: ProjectTrack) -> Int {
        var hasher = Hasher()
        hasher.combine(track.editRevision)
        guard let waveformOverview = track.waveformOverview else {
            return hasher.finalize()
        }

        hasher.combine(waveformOverview.bins.count)
        hasher.combine(waveformOverview.duration)
        for index in waveformFingerprintIndices(for: waveformOverview.bins.count) {
            let bin = waveformOverview.bins[index]
            hasher.combine(bin.minimumSample)
            hasher.combine(bin.maximumSample)
            hasher.combine(bin.rmsSample)
            hasher.combine(bin.lowEnergy)
            hasher.combine(bin.midEnergy)
            hasher.combine(bin.highEnergy)
        }

        return hasher.finalize()
    }

    private func waveformFingerprintIndices(for binCount: Int) -> [Int] {
        guard binCount > 0 else {
            return []
        }

        return [
            0,
            binCount / 3,
            binCount / 2,
            min((binCount * 2) / 3, binCount - 1),
            binCount - 1,
        ]
    }

    private func refreshTrackControls() {
        rebuildTrackIndexCache()
        let visibleRange = currentTrackLaneLayout.visibleRange(overscan: 1)
        let visibleLowerBound = min(max(visibleRange.lowerBound, 0), projectTracks.count)
        let visibleUpperBound = min(max(visibleRange.upperBound, visibleLowerBound), projectTracks.count)
        let visibleTracks = projectTracks[visibleLowerBound..<visibleUpperBound]
        let visibleTrackIDs = Set(visibleTracks.map(\.id))
        for (trackID, controlView) in trackControlViewsByID where !visibleTrackIDs.contains(trackID) {
            controlView.removeFromSuperview()
            controlView.onTrackSelected = nil
            controlView.onMuteChanged = nil
            controlView.onSoloChanged = nil
            controlView.onRecordRequested = nil
            controlView.onVolumeChanged = nil
            controlView.onVolumeEditingEnded = nil
            trackControlReusePool.append(controlView)
            trackControlViewsByID[trackID] = nil
        }

        for track in visibleTracks {
            let controlView: TrackControlView
            if let cachedControlView = trackControlViewsByID[track.id] {
                controlView = cachedControlView
            } else if let reusedControlView = trackControlReusePool.popLast() {
                controlView = reusedControlView
                trackControlViewsByID[track.id] = controlView
            } else {
                controlView = TrackControlView(title: track.name)
                trackControlViewsByID[track.id] = controlView
            }
            if controlView.superview !== trackControlsStack {
                trackControlsStack.addSubview(controlView)
            }

            controlView.configure(
                title: track.name,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed,
                volume: track.volume,
                isTrackSelected: selectedTrackIDs.contains(track.id),
                isRecording: track.id == recordingTrackID
            )
            controlView.onTrackSelected = { [weak self, trackID = track.id] modifierFlags in
                self?.selectTrack(trackID, modifierFlags: modifierFlags)
            }
            controlView.onMuteChanged = { [weak self, trackID = track.id] isMuted in
                self?.updateTrack(trackID) { $0.isMuted = isMuted }
            }
            controlView.onSoloChanged = { [weak self, trackID = track.id] isSoloed in
                self?.updateTrack(trackID) { $0.isSoloed = isSoloed }
            }
            controlView.onRecordRequested = { [weak self, trackID = track.id] in
                self?.toggleRecording(on: trackID)
            }
            controlView.onVolumeChanged = { [weak self, trackID = track.id] volume in
                self?.updateTrack(trackID, mixPublication: .coalesced) { $0.volume = volume }
            }
            controlView.onVolumeEditingEnded = { [weak self] in
                self?.publishProjectTrackMixImmediately()
            }
        }

        layoutTrackControlViews()
    }

    private func rebuildTrackIndexCache() {
        trackIndicesByID.removeAll(keepingCapacity: true)
        trackIndicesByID.reserveCapacity(projectTracks.count)
        for (index, track) in projectTracks.enumerated() {
            trackIndicesByID[track.id] = index
        }
        trackIndexCacheTrackCount = projectTracks.count
    }

    private func updateTrackLaneLayout(_ layout: ResolvedTimelineTrackLayout) {
        guard currentTrackLaneLayout != layout else {
            layoutTrackControlViews()
            return
        }

        currentTrackLaneLayout = layout
        refreshTrackControls()
    }

    private func layoutTrackControlViews() {
        let viewportHeight = max(trackControlsStack.bounds.height, 1)
        let viewportWidth = max(trackControlsStack.bounds.width, 1)
        if trackIndexCacheTrackCount != projectTracks.count {
            rebuildTrackIndexCache()
        }

        for (trackID, controlView) in trackControlViewsByID {
            guard
                let trackIndex = trackIndicesByID[trackID],
                let laneFrame = currentTrackLaneLayout.laneFrame(forTrackIndex: trackIndex)
            else {
                controlView.isHidden = true
                continue
            }

            let top = CGFloat(laneFrame.top) * viewportHeight
            let bottom = CGFloat(laneFrame.bottom) * viewportHeight
            let clampedTop = min(max(top, 0), viewportHeight)
            let clampedBottom = min(max(bottom, 0), viewportHeight)
            let height = max(clampedBottom - clampedTop, 1)
            controlView.isHidden = clampedBottom <= 0 || clampedTop >= viewportHeight
            controlView.frame = NSRect(
                x: 0,
                y: viewportHeight - clampedBottom,
                width: viewportWidth,
                height: height
            )
        }
    }

    private func addEmptyTrack() {
        let snapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: nil
        )
        editUndoStack.append(.projectTracks(snapshot))

        let trackID = UUID()
        let trackName = "Track \(projectTracks.count + 1)"
        let track = ProjectTrack(
            id: trackID,
            editGroupID: defaultEditGroupID,
            name: trackName,
            sourceURL: URL(fileURLWithPath: "/dev/null"),
            durationHint: nil,
            sourceWaveformOverview: nil,
            waveformOverview: nil,
            decodedAudioBuffer: nil,
            zeroCrossingIndex: nil,
            zeroCrossingProbe: nil,
            audioTimeline: nil,
            fileTimeline: nil,
            ownsSourceFile: false,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            importID: UUID(),
            editRevision: 0
        )

        projectTracks.append(track)
        activeTrackID = trackID
        selectedTimelineRange = nil
        refreshProjectTimelineDisplay()
        selectTrack(trackID)
        updateProjectDisplayTiming()
        updateEffectCommandState()
        window?.title = projectWindowTitle()
        updateStatus("\(trackName) added")
    }

    private func toggleRecording(on trackID: UUID) {
        if recordingTrackID == trackID {
            stopRecording()
            return
        }

        startRecording(on: trackID)
    }

    private func startRecording(on trackID: UUID) {
        guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        if recordingTrackID != nil {
            stopRecording()
        }

        if playbackController.isPlaying {
            playbackController.pause()
            stopPlaybackTimer()
        }

        let recordingURL = recordingFileURL(trackName: projectTracks[trackIndex].name)
        let takeWriter: StreamingWAVTakeWriter
        do {
            takeWriter = try StreamingWAVTakeWriter(url: recordingURL)
        } catch {
            updateStatus("recording failed: \(error.localizedDescription)")
            return
        }

        recordingPreviewCoalescer.reset()
        inputRecorder.onChunk = { [weak self, takeWriter] chunk in
            takeWriter.append(chunk)
            self?.recordingPreviewCoalescer.enqueue(chunk) { chunks in
                Task { @MainActor in
                    self?.appendRecordingChunks(chunks)
                }
            }
        }

        do {
            try inputRecorder.start()
        } catch {
            inputRecorder.onChunk = nil
            takeWriter.cancel()
            updateStatus("recording failed: \(error.localizedDescription)")
            return
        }

        let snapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: nil
        )
        recordingStartUndoSnapshot = snapshot
        recordingStartUndoStackCount = editUndoStack.count
        editUndoStack.append(.projectTracks(snapshot))

        recordingTrackID = trackID
        recordingTakeWriter = takeWriter
        recordingSampleRate = 0
        recordingAccumulator = nil
        lastRecordingVisualUpdateTimestamp = 0

        projectTracks[trackIndex].sourceURL = URL(fileURLWithPath: "/dev/null")
        projectTracks[trackIndex].durationHint = nil
        projectTracks[trackIndex].waveformOverview = nil
        projectTracks[trackIndex].decodedAudioBuffer = nil
        projectTracks[trackIndex].zeroCrossingIndex = nil
        projectTracks[trackIndex].zeroCrossingProbe = nil
        projectTracks[trackIndex].audioTimeline = nil
        projectTracks[trackIndex].ownsSourceFile = false
        projectTracks[trackIndex].editRevision += 1
        activeTrackID = trackID
        selectedTrackID = nil
        selectedTrackIDs.removeAll()
        trackSelectionAnchorID = nil
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        publishSelectedTracksToTimeline()
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming()
        currentPlaybackStatus = "recording"
        displayPlaybackVisuals(
            progress: 1,
            isPlaying: true,
            syncPlayhead: true,
            restartsFisheyeActivation: true,
            restartsPlayheadKick: true
        )
        timelineSurface.displayRecordingActive(true)
        window?.makeFirstResponder(timelineSurface)
        updateStatus("recording \(projectTracks[trackIndex].name)")
    }

    private func stopRecording() {
        guard let trackID = recordingTrackID else {
            return
        }

        inputRecorder.stop()
        appendRecordingChunks(recordingPreviewCoalescer.drainPending())
        applyLiveRecordingOverview(force: true)
        let takeWriter = recordingTakeWriter
        recordingTakeWriter = nil
        inputRecorder.onChunk = nil
        recordingPreviewCoalescer.reset()

        recordingTrackID = nil
        timelineSurface.displayRecordingActive(false)
        displayPlaybackVisuals(progress: 1, isPlaying: false, syncPlayhead: true)
        refreshTrackControls()
        window?.makeFirstResponder(timelineSurface)

        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            let takeWriter
        else {
            recordingSampleRate = 0
            recordingAccumulator = nil
            recordingStartUndoSnapshot = nil
            recordingStartUndoStackCount = nil
            updateProjectDisplayTiming()
            updateStatus("recording stopped")
            return
        }

        let recordedTake: RecordedTakeFile
        do {
            recordedTake = try takeWriter.finish()
        } catch {
            takeWriter.cancel()
            restoreAfterDiscardedRecording(
                status: recordingDiscardStatus(for: error)
            )
            return
        }

        let fileInfo = try? WAVAudioDecoder.inspect(url: recordedTake.url)
        let zeroCrossingProbe = fileInfo.flatMap {
            try? WAVAudioDecoder.makeZeroCrossingProbe(url: recordedTake.url, fileInfo: $0)
        }
        let waveformOverview = recordingAccumulator?.makeOverview(sampleRate: recordedTake.sampleRate) ??
            (try? WAVAudioDecoder.buildSparsePreview(url: recordedTake.url).1)
        let importID = UUID()

        projectTracks[trackIndex].sourceURL = recordedTake.url
        projectTracks[trackIndex].durationHint = fileInfo?.duration ?? recordedTake.duration
        projectTracks[trackIndex].sourceWaveformOverview = waveformOverview
        projectTracks[trackIndex].waveformOverview = waveformOverview
        projectTracks[trackIndex].decodedAudioBuffer = nil
        projectTracks[trackIndex].zeroCrossingIndex = nil
        projectTracks[trackIndex].zeroCrossingProbe = zeroCrossingProbe
        projectTracks[trackIndex].audioTimeline = nil
        projectTracks[trackIndex].ownsSourceFile = true
        projectTracks[trackIndex].importID = importID
        projectTracks[trackIndex].editRevision = 0
        activeTrackID = trackID

        recordingSampleRate = 0
        recordingAccumulator = nil
        recordingStartUndoSnapshot = nil
        recordingStartUndoStackCount = nil
        syncActiveTrackFields()
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming(sampleRateHint: recordedTake.sampleRate)
        reloadPlaybackFromProjectTracks(preserveProgress: false)
        startRecordedTakePreviewRefinement(trackID: trackID, importID: importID, url: recordedTake.url)
        updateEffectCommandState()
        updateStatus("recorded \(formatDuration(recordedTake.duration))")
    }

    private func restoreAfterDiscardedRecording(status: String) {
        recordingSampleRate = 0
        recordingAccumulator = nil

        if
            let undoStackCount = recordingStartUndoStackCount,
            editUndoStack.count == undoStackCount + 1
        {
            _ = editUndoStack.popLast()
        }

        if let snapshot = recordingStartUndoSnapshot {
            recordingStartUndoSnapshot = nil
            recordingStartUndoStackCount = nil
            restoreProjectTracks(from: snapshot)
        } else {
            recordingStartUndoStackCount = nil
            refreshProjectTimelineDisplay()
            updateProjectDisplayTiming()
        }

        updateStatus(status)
    }

    private func recordingDiscardStatus(for error: Error) -> String {
        if let writerError = error as? StreamingWAVTakeWriter.WriterError,
           case .noSamplesWritten = writerError
        {
            return "recording canceled"
        }

        return "recording failed: \(error.localizedDescription)"
    }

    private func appendRecordingChunks(_ chunks: [AudioRecordingChunk]) {
        guard !chunks.isEmpty else {
            return
        }

        for chunk in chunks {
            appendRecordingChunkSamples(chunk)
        }

        let now = CACurrentMediaTime()
        if now - lastRecordingVisualUpdateTimestamp >= 1.0 / 45.0 {
            applyLiveRecordingOverview(force: false)
            lastRecordingVisualUpdateTimestamp = now
        }
    }

    private func appendRecordingChunkSamples(_ chunk: AudioRecordingChunk) {
        guard recordingTrackID != nil, chunk.frameCount > 0, chunk.sampleRate > 0 else {
            return
        }

        let frameCount = min(
            chunk.frameCount,
            chunk.samplesByChannel.map(\.count).min() ?? chunk.frameCount
        )
        guard frameCount > 0 else {
            return
        }

        if recordingAccumulator == nil || recordingSampleRate != chunk.sampleRate {
            recordingSampleRate = chunk.sampleRate
            recordingAccumulator = LiveRecordingWaveformAccumulator(sampleRate: chunk.sampleRate)
        }

        recordingAccumulator?.append(
            samplesByChannel: chunk.samplesByChannel,
            frameCount: frameCount
        )
    }

    private func applyLiveRecordingOverview(force: Bool) {
        guard
            let recordingTrackID,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == recordingTrackID }),
            let recordingAccumulator,
            recordingSampleRate > 0
        else {
            return
        }

        let overview = recordingAccumulator.makeOverview(sampleRate: recordingSampleRate)
        guard force || overview.bins.isEmpty == false else {
            return
        }

        projectTracks[trackIndex].waveformOverview = overview
        projectTracks[trackIndex].durationHint = overview.duration
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming(sampleRateHint: recordingSampleRate)
        currentPlayheadFrame = displayedFrameCount
        let now = CACurrentMediaTime()
        visualPlayheadProgress = 1
        visualPlayheadAnchorTimestamp = now
        visualPlaybackActive = true
        timelineSurface.displayPlayheadProgress(
            1,
            syncRenderer: true,
            anchorTimestamp: now,
            resetsTouchStart: false
        )
        timelineSurface.displayRecordingActive(true)
        updateTimeReadout()
    }

    private func startRecordedTakePreviewRefinement(trackID: UUID, importID: UUID, url: URL) {
        let wavPreviewLevels = wavPreviewLevels
        Task { [weak self, trackID, importID, url, wavPreviewLevels] in
            var latestPreviewBinCount = 0
            for previewLevel in wavPreviewLevels {
                guard let self, self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                    return
                }
                guard await self.waitForImportWorkBudget(trackID: trackID, importID: importID) else {
                    return
                }

                do {
                    let (fileInfo, waveformOverview) = try await AudioImportPipeline.loadWAVPreviewOverview(
                        at: url,
                        targetBinCount: previewLevel.targetBinCount,
                        samplesPerBin: previewLevel.samplesPerBin
                    )
                    guard self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                        return
                    }
                    guard waveformOverview.bins.count > latestPreviewBinCount else {
                        continue
                    }

                    latestPreviewBinCount = waveformOverview.bins.count
                    self.applyTrackPreviewRefinement(
                        trackID: trackID,
                        fileInfo: fileInfo,
                        waveformOverview: waveformOverview
                    )
                } catch {
                    guard self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                        return
                    }
                    self.updateStatus("recording preview refinement failed: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    private func recordingFileURL(trackName: String) -> URL {
        let recordingsDirectory = recordingsDirectoryURL()
        try? FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )

        let safeTrackName = trackName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fileName = "\(safeTrackName.isEmpty ? "Recording" : safeTrackName)-\(UUID().uuidString).wav"
        return recordingsDirectory.appendingPathComponent(fileName)
    }

    private func recordingsDirectoryURL() -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return baseDirectory
            .appendingPathComponent("Soundtime", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
            .standardizedFileURL
    }

    private func normalizedOwnedURL(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    private func isOwnedRecordingURL(_ url: URL) -> Bool {
        let recordingsDirectory = recordingsDirectoryURL()
        let candidate = normalizedOwnedURL(url)
        return candidate.path.hasPrefix(recordingsDirectory.path + "/")
            && candidate.pathExtension.lowercased() == "wav"
    }

    private func ownedSourceURLs(in tracks: [ProjectTrack]) -> Set<URL> {
        Set(
            tracks.compactMap { track in
                guard track.ownsSourceFile, isOwnedRecordingURL(track.sourceURL) else {
                    return nil
                }
                return normalizedOwnedURL(track.sourceURL)
            }
        )
    }

    private func ownedSourceURLs(in undoStack: [UndoAction]) -> Set<URL> {
        undoStack.reduce(into: Set<URL>()) { urls, action in
            guard case let .projectTracks(snapshot) = action else {
                return
            }
            urls.formUnion(ownedSourceURLs(in: snapshot.tracks))
        }
    }

    private func deleteOwnedSourceFiles(_ urls: Set<URL>) {
        for url in urls where isOwnedRecordingURL(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func cleanupOwnedSourceFiles(replacedTracks: [ProjectTrack]) {
        let candidateURLs = ownedSourceURLs(in: replacedTracks)
        guard candidateURLs.isEmpty == false else {
            return
        }

        var protectedURLs = ownedSourceURLs(in: projectTracks)
        protectedURLs.formUnion(ownedSourceURLs(in: editUndoStack))
        deleteOwnedSourceFiles(candidateURLs.subtracting(protectedURLs))
    }

    private func deleteAllOwnedSourceFiles() {
        var urls = ownedSourceURLs(in: projectTracks)
        urls.formUnion(ownedSourceURLs(in: editUndoStack))
        deleteOwnedSourceFiles(urls)
    }

    private func markProjectSourceFilesAsSaved() {
        for index in projectTracks.indices where projectTracks[index].ownsSourceFile {
            projectTracks[index].ownsSourceFile = false
        }
        for undoIndex in editUndoStack.indices {
            guard case var .projectTracks(snapshot) = editUndoStack[undoIndex] else {
                continue
            }
            for trackIndex in snapshot.tracks.indices where snapshot.tracks[trackIndex].ownsSourceFile {
                snapshot.tracks[trackIndex].ownsSourceFile = false
            }
            editUndoStack[undoIndex] = .projectTracks(snapshot)
        }
    }

    private func selectTrack(_ trackID: UUID, modifierFlags: NSEvent.ModifierFlags = []) {
        guard let clickedIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        let usesRangeSelection = modifierFlags.contains(.shift)
        let togglesSelection = modifierFlags.contains(.command)

        if usesRangeSelection,
           let anchorID = trackSelectionAnchorID,
           let anchorIndex = projectTracks.firstIndex(where: { $0.id == anchorID })
        {
            let bounds = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            selectedTrackIDs = Set(bounds.map { projectTracks[$0].id })
            selectedTrackID = trackID
        } else if togglesSelection {
            if selectedTrackIDs.contains(trackID) {
                selectedTrackIDs.remove(trackID)
                if selectedTrackID == trackID {
                    selectedTrackID = selectedTrackIDs
                        .compactMap { id in projectTracks.firstIndex(where: { $0.id == id }).map { (index: $0, id: id) } }
                        .sorted { $0.index < $1.index }
                        .first?
                        .id
                }
            } else {
                selectedTrackIDs.insert(trackID)
                selectedTrackID = trackID
                trackSelectionAnchorID = trackID
            }
        } else {
            selectedTrackIDs = [trackID]
            selectedTrackID = trackID
            trackSelectionAnchorID = trackID
        }

        selectedTrackIDs = Set(projectTracks.map(\.id)).intersection(selectedTrackIDs)
        if let selectedTrackID, !selectedTrackIDs.contains(selectedTrackID) {
            self.selectedTrackID = selectedTrackIDs.first
        }
        activeTrackID = selectedTrackID ?? trackID
        let fullTrackSelection = selectedTrackID.map(fullTrackDisplaySelection)
        selectedTimelineRange = fullTrackSelection
        timelineSurface.displaySelection(fullTrackSelection)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        publishSelectedTracksToTimeline()
        refreshTrackControls()
        syncActiveTrackFields()
        window?.makeFirstResponder(timelineSurface)
        updateEffectCommandState()
        updateStatus(currentPlaybackStatus)
    }

    private func clearSelectedTrack() {
        guard !selectedTrackIDs.isEmpty || selectedTrackID != nil else {
            return
        }

        let trackID = selectedTrackID
        selectedTrackID = nil
        selectedTrackIDs.removeAll()
        trackSelectionAnchorID = nil
        if let trackID, isFullTrackSelection(selectedTimelineRange, trackID: trackID) {
            selectedTimelineRange = nil
            timelineSurface.displaySelection(nil)
            timelineSurface.displayGainPreview(selection: nil, gain: 1)
            updateEffectCommandState()
        }
        publishSelectedTracksToTimeline()
        refreshTrackControls()
    }

    private func dismissTimelineSelection() {
        clearDeadAirReview(publish: true)
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        clearSelectedTrack()
        updateEffectCommandState()
        updateStatus(currentPlaybackStatus)
    }

    private func publishSelectedTracksToTimeline() {
        let liveTrackIDs = Set(projectTracks.map(\.id))
        selectedTrackIDs = selectedTrackIDs.intersection(liveTrackIDs)
        if let selectedTrackID, !selectedTrackIDs.contains(selectedTrackID) {
            self.selectedTrackID = selectedTrackIDs.first
        }
        timelineSurface.displaySelectedTracks(selectedTrackIDs, primaryTrackID: selectedTrackID)
    }

    private func updateTrack(
        _ trackID: UUID,
        mixPublication: ProjectTrackMixPublication = .immediate,
        update: (inout ProjectTrack) -> Void
    ) {
        guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        update(&projectTracks[trackIndex])
        activeTrackID = trackID
        refreshProjectTrackMixDisplay()
        switch mixPublication {
        case .immediate:
            publishProjectTrackMixImmediately()
        case .coalesced:
            scheduleProjectTrackMixUpdate()
        }
        updateStatus(currentPlaybackStatus)
        scheduleAutosaveIfNeeded()
    }

    private func reloadProjectPlaybackImmediately() {
        reloadPlaybackFromProjectTracks(preserveProgress: true)
    }

    private func loadDroppedAudioFile(at url: URL) {
        if WAVAudioDecoder.canDecode(url) {
            addDroppedWAVTrack(at: url)
            return
        }

        let importID = UUID()
        activeImportID = importID
        selectedAudioFile = nil
        decodedAudioBuffer = nil
        audioTimeline = nil
        editUndoStack.removeAll()
        loadedAudioSummary = nil
        selectedTimelineRange = nil
        selectedTrackID = nil
        selectedTrackIDs.removeAll()
        trackSelectionAnchorID = nil
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        publishSelectedTracksToTimeline()
        updateEffectCommandState()
        currentPlayheadFrame = 0
        displayedFrameCount = 0
        displayedSampleRate = 0
        currentPlaybackStatus = "idle"
        playbackTimer?.invalidate()
        playbackTimer = nil
        playbackController.clear()
        timelineSurface.displayWaveform(nil)
        timelineSurface.displaySelection(nil)
        displayPlaybackVisuals(progress: 0, isPlaying: false)
        updateTimeReadout()
        metadataLabel.stringValue = "\(url.lastPathComponent) - loading..."

        if WAVAudioDecoder.canDecode(url) {
            loadDroppedWAVFile(at: url, importID: importID)
            return
        }

        Task { [weak self, importID, url] in
            do {
                let result = try await AudioImportPipeline.loadDroppedFile(at: url)

                guard let self, self.activeImportID == importID else {
                    return
                }

                self.selectedAudioFile = result.metadata
                self.window?.title = "Soundtime - \(result.metadata.displayName)"

                switch result.decodeStatus {
                case .unsupported:
                    self.decodedAudioBuffer = nil
                    self.audioTimeline = nil
                    self.editUndoStack.removeAll()
                    self.loadedAudioSummary = nil
                    self.selectedTimelineRange = nil
                    self.updateEffectCommandState()
                    self.currentPlayheadFrame = 0
                    self.displayedFrameCount = 0
                    self.displayedSampleRate = 0
                    self.currentPlaybackStatus = "idle"
                    self.playbackController.clear()
                    self.timelineSurface.displaySelection(nil)
                    self.displayPlaybackVisuals(progress: 0, isPlaying: false)
                    self.updateTimeReadout()
                    self.metadataLabel.stringValue = "\(result.metadata.formattedSummary) - WAV decode not available yet"
                case let .decoded(decodedAudioBuffer, waveformOverview, zeroCrossingIndex):
                    self.decodedAudioBuffer = decodedAudioBuffer
                    self.audioTimeline = AudioEditTimeline(sourceBuffer: decodedAudioBuffer)
                    self.editUndoStack.removeAll()
                    self.currentPlayheadFrame = 0
                    self.displayedFrameCount = decodedAudioBuffer.frameCount
                    self.displayedSampleRate = decodedAudioBuffer.sampleRate
                    try self.playbackController.load(
                        decodedAudioBuffer,
                        zeroCrossingIndex: zeroCrossingIndex
                    )
                    self.timelineSurface.displayWaveform(waveformOverview)
                    self.displayPlaybackVisuals(progress: 0, isPlaying: false)
                    self.loadedAudioSummary = "\(result.metadata.displayName) - \(decodedAudioBuffer.formattedSummary)"
                    self.selectedTimelineRange = nil
                    self.updateEffectCommandState()
                    self.currentPlaybackStatus = "press Space to play"
                    self.updateStatus("press Space to play")
                case let .failed(message):
                    self.decodedAudioBuffer = nil
                    self.audioTimeline = nil
                    self.editUndoStack.removeAll()
                    self.loadedAudioSummary = nil
                    self.selectedTimelineRange = nil
                    self.updateEffectCommandState()
                    self.currentPlayheadFrame = 0
                    self.displayedFrameCount = 0
                    self.displayedSampleRate = 0
                    self.currentPlaybackStatus = "idle"
                    self.playbackController.clear()
                    self.timelineSurface.displaySelection(nil)
                    self.displayPlaybackVisuals(progress: 0, isPlaying: false)
                    self.timelineSurface.displayWaveform(nil)
                    self.updateTimeReadout()
                    self.metadataLabel.stringValue = "\(result.metadata.formattedSummary) - WAV decode failed: \(message)"
                }
            } catch {
                guard let self, self.activeImportID == importID else {
                    return
                }

                self.selectedAudioFile = nil
                self.decodedAudioBuffer = nil
                self.audioTimeline = nil
                self.editUndoStack.removeAll()
                self.loadedAudioSummary = nil
                self.selectedTimelineRange = nil
                self.updateEffectCommandState()
                self.currentPlayheadFrame = 0
                self.displayedFrameCount = 0
                self.displayedSampleRate = 0
                self.currentPlaybackStatus = "idle"
                self.playbackController.clear()
                self.timelineSurface.displaySelection(nil)
                self.displayPlaybackVisuals(progress: 0, isPlaying: false)
                self.timelineSurface.displayWaveform(nil)
                self.updateTimeReadout()
                self.metadataLabel.stringValue = "\(url.lastPathComponent) - could not load audio"
            }
        }
    }

    private func addDroppedWAVTrack(at url: URL, settings: SoundtimeProject.Track? = nil) {
        let trackID = settings?.id ?? UUID()
        let importID = UUID()
        let trackName = settings?.name ?? url.deletingPathExtension().lastPathComponent
        let fileInfo = try? WAVAudioDecoder.inspect(url: url)
        let persistedFileTimeline: AudioFileEditTimeline?
        if
            let editTimeline = settings?.editTimeline,
            let restoredTimeline = AudioFileEditTimeline(persistentState: editTimeline),
            let fileInfo,
            restoredTimeline.isCompatible(with: fileInfo)
        {
            persistedFileTimeline = restoredTimeline
        } else {
            persistedFileTimeline = nil
        }
        let durationHint = persistedFileTimeline?.duration ?? fileInfo?.duration
        let track = ProjectTrack(
            id: trackID,
            editGroupID: settings?.editGroupID ?? defaultEditGroupID,
            name: trackName,
            sourceURL: url,
            durationHint: durationHint,
            sourceWaveformOverview: nil,
            waveformOverview: nil,
            decodedAudioBuffer: nil,
            zeroCrossingIndex: nil,
            zeroCrossingProbe: nil,
            audioTimeline: nil,
            fileTimeline: persistedFileTimeline,
            ownsSourceFile: false,
            volume: settings?.volume ?? 1,
            isMuted: settings?.isMuted ?? false,
            isSoloed: settings?.isSoloed ?? false,
            importID: importID,
            editRevision: persistedFileTimeline?.hasEdits == true ? 1 : 0
        )

        projectTracks.append(track)
        scheduleAutosaveIfNeeded()
        activeTrackID = trackID
        selectedTimelineRange = nil
        updateEffectCommandState()
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming()
        if !isLoadingProject {
            reloadPlaybackFromProjectTracks(preserveProgress: true)
        }
        updateStatus("\(trackName) loading")

        let wavPreviewLevels = wavPreviewLevels
        Task { [weak self, trackID, importID, url, wavPreviewLevels] in
            do {
                guard let initialPreviewLevel = wavPreviewLevels.first else {
                    return
                }

                let previewResult = try await AudioImportPipeline.loadWAVPreview(
                    at: url,
                    targetBinCount: initialPreviewLevel.targetBinCount,
                    samplesPerBin: initialPreviewLevel.samplesPerBin
                )

                guard let self, self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                    return
                }

                self.applyTrackPreview(trackID: trackID, previewResult: previewResult)
                var latestPreviewBinCount = previewResult.waveformOverview.bins.count

                for previewLevel in wavPreviewLevels.dropFirst() {
                    guard self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                        return
                    }
                    guard await self.waitForImportWorkBudget(trackID: trackID, importID: importID) else {
                        return
                    }

                    let nextBinCount = min(previewLevel.targetBinCount, previewResult.fileInfo.frameCount)
                    guard nextBinCount > latestPreviewBinCount else {
                        continue
                    }

                    do {
                        let (fileInfo, waveformOverview) = try await AudioImportPipeline.loadWAVPreviewOverview(
                            at: url,
                            targetBinCount: previewLevel.targetBinCount,
                            samplesPerBin: previewLevel.samplesPerBin
                        )

                        guard self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                            return
                        }
                        guard await self.waitForImportWorkBudget(trackID: trackID, importID: importID) else {
                            return
                        }

                        latestPreviewBinCount = waveformOverview.bins.count
                        self.applyTrackPreviewRefinement(
                            trackID: trackID,
                            fileInfo: fileInfo,
                            waveformOverview: waveformOverview
                        )
                    } catch {
                        break
                    }
                }

                do {
                    guard await self.waitForImportWorkBudget(
                        trackID: trackID,
                        importID: importID,
                        idleSettleDuration: 0.65
                    ) else {
                        return
                    }

                    let (decodedAudioBuffer, waveformOverview, zeroCrossingIndex) =
                        try await AudioImportPipeline.loadDecodedWAV(at: url)

                    guard self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                        return
                    }
                    guard await self.waitForImportWorkBudget(trackID: trackID, importID: importID) else {
                        return
                    }

                    self.applyTrackDecodedWAV(
                        trackID: trackID,
                        decodedAudioBuffer: decodedAudioBuffer,
                        waveformOverview: waveformOverview,
                        zeroCrossingIndex: zeroCrossingIndex
                    )
                } catch {
                    guard self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                        return
                    }

                    self.updateStatus("track decode failed: \(error.localizedDescription)")
                }
            } catch {
                guard let self, self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                    return
                }

                self.removeProjectTrack(trackID)
                self.updateStatus("\(url.lastPathComponent) preview failed: \(error.localizedDescription)")
            }
        }
    }

    private func isTrackImportCurrent(trackID: UUID, importID: UUID) -> Bool {
        projectTracks.contains { $0.id == trackID && $0.importID == importID }
    }

    private func waitForImportWorkBudget(
        trackID: UUID,
        importID: UUID,
        idleSettleDuration: TimeInterval = 0.18
    ) async -> Bool {
        await waitForImportWorkBudget(
            idleSettleDuration: idleSettleDuration,
            isCurrent: { [weak self] in
                self?.isTrackImportCurrent(trackID: trackID, importID: importID) == true
            }
        )
    }

    private func waitForSingleFileImportWorkBudget(
        importID: UUID,
        idleSettleDuration: TimeInterval = 0.18
    ) async -> Bool {
        await waitForImportWorkBudget(
            idleSettleDuration: idleSettleDuration,
            isCurrent: { [weak self] in
                self?.activeImportID == importID
            }
        )
    }

    private func waitForImportWorkBudget(
        idleSettleDuration: TimeInterval,
        isCurrent: () -> Bool
    ) async -> Bool {
        guard isCurrent(), !Task.isCancelled else {
            return false
        }

        do {
            try await ImportWorkBudget.shared.waitForAsyncTurn(
                idleSettleDuration >= 0.5 ? .backgroundDecode : .previewRefinement
            )
        } catch {
            return false
        }
        await Task.yield()
        return isCurrent() && !Task.isCancelled
    }

    private func removeProjectTrack(_ trackID: UUID) {
        if recordingTrackID == trackID {
            stopRecording()
        }

        let replacedTracks = projectTracks
        projectTracks.removeAll { $0.id == trackID }
        if activeTrackID == trackID {
            activeTrackID = projectTracks.last?.id
        }
        if selectedTrackID == trackID {
            selectedTrackID = nil
        }
        selectedTrackIDs.remove(trackID)
        if trackSelectionAnchorID == trackID {
            trackSelectionAnchorID = nil
        }
        publishSelectedTracksToTimeline()
        syncActiveTrackFields()
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(preserveProgress: false)
        cleanupOwnedSourceFiles(replacedTracks: replacedTracks)
    }

    private func applyTrackPreview(trackID: UUID, previewResult: WAVPreviewImportResult) {
        guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        projectTracks[trackIndex].name = previewResult.metadata.displayName
        let fileTimeline = projectTracks[trackIndex].fileTimeline
        projectTracks[trackIndex].durationHint = fileTimeline?.duration ?? previewResult.fileInfo.duration
        projectTracks[trackIndex].sourceWaveformOverview = previewResult.waveformOverview
        projectTracks[trackIndex].waveformOverview = fileTimeline?.waveformOverview(
            from: previewResult.waveformOverview
        ) ?? previewResult.waveformOverview
        projectTracks[trackIndex].zeroCrossingProbe = previewResult.zeroCrossingProbe
        activeTrackID = trackID
        window?.title = projectWindowTitle()
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming()
        syncActiveTrackFields()
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        updateStatus("preview ready - resolving waveform")
    }

    private func applyTrackPreviewRefinement(
        trackID: UUID,
        fileInfo: WAVFileInfo,
        waveformOverview: WaveformOverview
    ) {
        guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        let fileTimeline = projectTracks[trackIndex].fileTimeline
        projectTracks[trackIndex].sourceWaveformOverview = waveformOverview
        projectTracks[trackIndex].waveformOverview = fileTimeline?.waveformOverview(from: waveformOverview) ??
            waveformOverview
        projectTracks[trackIndex].durationHint = fileTimeline?.duration ?? fileInfo.duration
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming(sampleRateHint: fileInfo.sampleRate)
        updateTimeReadout()
    }

    private func applyTrackDecodedWAV(
        trackID: UUID,
        decodedAudioBuffer: DecodedAudioBuffer,
        waveformOverview: WaveformOverview,
        zeroCrossingIndex: AudioZeroCrossingIndex
    ) {
        guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        let existingFileTimeline = projectTracks[trackIndex].fileTimeline
        if let existingFileTimeline {
            let existingEditedOverview = projectTracks[trackIndex].editRevision > 0 ?
                projectTracks[trackIndex].waveformOverview :
                nil
            let editRevision = projectTracks[trackIndex].editRevision

            projectTracks[trackIndex].decodedAudioBuffer = nil
            projectTracks[trackIndex].sourceWaveformOverview = waveformOverview
            projectTracks[trackIndex].waveformOverview = existingEditedOverview ?? waveformOverview
            projectTracks[trackIndex].durationHint = existingFileTimeline.duration
            projectTracks[trackIndex].zeroCrossingIndex = zeroCrossingIndex
            projectTracks[trackIndex].audioTimeline = nil
            projectTracks[trackIndex].fileTimeline = existingFileTimeline
            activeTrackID = trackID
            syncActiveTrackFields()
            refreshProjectTimelineDisplay(rebuildControls: false)
            updateProjectDisplayTiming(sampleRateHint: decodedAudioBuffer.sampleRate)
            if !playbackController.hasSource {
                reloadPlaybackFromProjectTracks(preserveProgress: true)
            } else {
                updateProjectPlaybackTrackMix()
            }
            updateEffectCommandState()
            updateStatus("track ready")

            if existingFileTimeline.hasEdits {
                scheduleFileTimelineWaveformRefinement(
                    trackID: trackID,
                    fileTimeline: existingFileTimeline,
                    sourceOverview: waveformOverview,
                    editRevision: editRevision
                )
            }
            return
        }

        let decodedTimeline = AudioEditTimeline(sourceBuffer: decodedAudioBuffer)
        projectTracks[trackIndex].decodedAudioBuffer = decodedAudioBuffer
        projectTracks[trackIndex].sourceWaveformOverview = waveformOverview
        projectTracks[trackIndex].waveformOverview = waveformOverview
        projectTracks[trackIndex].durationHint = decodedTimeline.duration
        projectTracks[trackIndex].zeroCrossingIndex = zeroCrossingIndex
        projectTracks[trackIndex].audioTimeline = decodedTimeline
        projectTracks[trackIndex].fileTimeline = nil
        activeTrackID = trackID
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming(sampleRateHint: decodedAudioBuffer.sampleRate)
        if !playbackController.hasSource {
            reloadPlaybackFromProjectTracks(preserveProgress: true)
        } else {
            updateProjectPlaybackTrackMix()
        }
        updateEffectCommandState()
        updateStatus("track ready")
    }

    private func syncActiveTrackFields() {
        guard let activeTrack = activeProjectTrack else {
            decodedAudioBuffer = nil
            audioTimeline = nil
            selectedAudioFile = nil
            return
        }

        decodedAudioBuffer = activeTrack.decodedAudioBuffer
        audioTimeline = activeTrack.audioTimeline
        let duration = trackDuration(for: activeTrack)
        if duration > 0 {
            selectedAudioFile = AudioFileMetadata(
                url: activeTrack.sourceURL,
                displayName: activeTrack.name,
                duration: duration,
                fileSize: nil
            )
        } else {
            selectedAudioFile = nil
        }
    }

    private var activeProjectTrack: ProjectTrack? {
        guard let activeTrackID else {
            return projectTracks.last
        }

        return projectTracks.first { $0.id == activeTrackID } ?? projectTracks.last
    }

    private func updateProjectDisplayTiming(sampleRateHint: Double? = nil) {
        let projectDuration = projectTracks.reduce(TimeInterval(0)) { result, track in
            max(result, trackDuration(for: track))
        }
        let sampleRate = sampleRateHint ??
            projectTracks.compactMap { $0.decodedAudioBuffer?.sampleRate }.first ??
            displayedSampleRate

        if projectDuration > 0, sampleRate > 0 {
            displayedSampleRate = sampleRate
            displayedFrameCount = Int((projectDuration * sampleRate).rounded(.up))
        } else {
            displayedSampleRate = 0
            displayedFrameCount = 0
        }

        updateLoadedProjectSummary()
        updateTimeReadout()
    }

    private func updateLoadedProjectSummary() {
        if projectTracks.isEmpty {
            loadedAudioSummary = nil
        } else {
            let trackText = projectTracks.count == 1 ? "1 track" : "\(projectTracks.count) tracks"
            if let currentProjectURL {
                loadedAudioSummary = "\(currentProjectURL.deletingPathExtension().lastPathComponent) - \(trackText)"
            } else {
                loadedAudioSummary = "Untitled Project - \(trackText)"
            }
        }
    }

    private func projectWindowTitle() -> String {
        if let currentProjectURL {
            return "Soundtime - \(currentProjectURL.deletingPathExtension().lastPathComponent)"
        }

        if projectTracks.isEmpty {
            return "Soundtime"
        }

        return "Soundtime - Untitled Project"
    }

    private func reloadPlaybackFromProjectTracks(
        preserveProgress: Bool,
        targetProgress: Float? = nil,
        resumeIfPlaying: Bool? = nil
    ) {
        let previousSnapshot = playbackController.snapshot()
        let previousProgress = targetProgress ?? previousSnapshot.progress
        let shouldResume = resumeIfPlaying ?? (preserveProgress && previousSnapshot.isPlaying)
        let playbackTracks = projectPlaybackTracks()

        guard !playbackTracks.isEmpty else {
            playbackController.clear()
            currentPlayheadFrame = 0
            displayPlaybackVisuals(progress: 0, isPlaying: false)
            updateTimeReadout()
            return
        }

        do {
            if playbackController.hasSource {
                try playbackController.updateProjectTracks(playbackTracks)
            } else {
                try playbackController.loadProjectTracks(playbackTracks)
            }
            if preserveProgress || targetProgress != nil {
                try playbackController.seek(toProgress: previousProgress)
                if shouldResume && !playbackController.isPlaying {
                    try playbackController.play()
                }
            } else if playbackController.hasSource {
                playbackController.pause()
                try playbackController.seek(toProgress: 0)
            }

            let snapshot = playbackController.snapshot()
            displayPlaybackVisuals(
                progress: snapshot.progress,
                isPlaying: snapshot.isPlaying,
                syncPlayhead: true,
                anchorTimestamp: snapshot.hostTimestamp
            )
        } catch {
            updateStatus("project playback failed: \(error.localizedDescription)")
        }
        updateTimeReadout()
    }

    private func updateProjectPlaybackTrackMix() {
        playbackController.updateProjectTrackMix(projectPlaybackTrackMixes())
        lastProjectTrackMixPublishTimestamp = CACurrentMediaTime()
    }

    private func scheduleProjectTrackMixUpdate() {
        pendingProjectTrackMixUpdate = true
        guard scheduledProjectTrackMixWorkItem == nil else {
            return
        }

        let elapsed = CACurrentMediaTime() - lastProjectTrackMixPublishTimestamp
        let delay = max(trackMixCoalescingInterval - elapsed, 0)
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.flushScheduledProjectTrackMixUpdate()
            }
        }
        scheduledProjectTrackMixWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func flushScheduledProjectTrackMixUpdate() {
        scheduledProjectTrackMixWorkItem = nil
        guard pendingProjectTrackMixUpdate else {
            return
        }

        pendingProjectTrackMixUpdate = false
        updateProjectPlaybackTrackMix()
    }

    private func publishProjectTrackMixImmediately() {
        scheduledProjectTrackMixWorkItem?.cancel()
        scheduledProjectTrackMixWorkItem = nil
        pendingProjectTrackMixUpdate = false
        updateProjectPlaybackTrackMix()
    }

    private func projectPlaybackTracks() -> [ProjectPlaybackTrack] {
        return projectTracks.compactMap { track -> ProjectPlaybackTrack? in
            let source: ProjectPlaybackTrack.Source
            if let fileTimeline = track.fileTimeline, WAVAudioDecoder.canDecode(track.sourceURL) {
                source = .fileTimeline(
                    url: track.sourceURL,
                    timeline: fileTimeline,
                    zeroCrossingProbe: track.zeroCrossingProbe
                )
            } else if track.editRevision == 0, WAVAudioDecoder.canDecode(track.sourceURL) {
                source = .file(
                    url: track.sourceURL,
                    zeroCrossingProbe: track.zeroCrossingProbe
                )
            } else if let audioTimeline = track.audioTimeline {
                source = .timeline(
                    audioTimeline: audioTimeline,
                    zeroCrossingIndex: track.zeroCrossingIndex
                )
            } else if let decodedAudioBuffer = track.decodedAudioBuffer {
                source = .decoded(
                    decodedAudioBuffer: decodedAudioBuffer,
                    zeroCrossingIndex: track.zeroCrossingIndex
                )
            } else {
                return nil
            }

            return ProjectPlaybackTrack(
                id: track.id,
                source: source,
                sourceRevision: track.editRevision,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed
            )
        }
    }

    private func projectPlaybackTrackMixes() -> [ProjectPlaybackTrackMix] {
        projectTracks.map { track in
            ProjectPlaybackTrackMix(
                id: track.id,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed
            )
        }
    }

    private func projectMixTrackSnapshots() -> [ProjectMixTrackSnapshot] {
        audibleProjectTracks.compactMap { track in
            let source: ProjectMixTrackSource
            if let fileTimeline = track.fileTimeline, WAVAudioDecoder.canDecode(track.sourceURL) {
                source = .fileTimeline(track.sourceURL, fileTimeline)
            } else if track.editRevision == 0, WAVAudioDecoder.canDecode(track.sourceURL) {
                source = .file(track.sourceURL)
            } else if let audioTimeline = track.audioTimeline {
                source = .timeline(audioTimeline)
            } else if let decodedAudioBuffer = track.decodedAudioBuffer {
                source = .decoded(decodedAudioBuffer)
            } else {
                return nil
            }

            return ProjectMixTrackSnapshot(
                volume: track.volume,
                source: source,
                zeroCrossingIndex: track.zeroCrossingIndex
            )
        }
    }

    private nonisolated static func decodedMixBuffer(
        for track: ProjectMixTrackSnapshot
    ) throws -> DecodedAudioBuffer {
        switch track.source {
        case let .decoded(buffer):
            return buffer
        case let .timeline(timeline):
            return timeline.render()
        case let .file(url):
            return try WAVAudioDecoder.decode(url: url)
        case let .fileTimeline(url, fileTimeline):
            let sourceBuffer = try WAVAudioDecoder.decode(url: url)
            return fileTimeline.audioTimeline(sourceBuffer: sourceBuffer).render()
        }
    }

    private nonisolated static func makeProjectMix(
        from decodedTracks: [ProjectMixTrackSnapshot],
        outputURL: URL
    ) throws -> ProjectMixResult? {
        guard let firstTrack = decodedTracks.first else {
            return nil
        }

        let firstBuffer = try decodedMixBuffer(for: firstTrack)
        if
            decodedTracks.count == 1,
            abs(firstTrack.volume - 1) <= Float.ulpOfOne
        {
            let zeroCrossingIndex: AudioZeroCrossingIndex
            if
                let existingZeroCrossingIndex = firstTrack.zeroCrossingIndex,
                existingZeroCrossingIndex.frameCount == firstBuffer.frameCount
            {
                zeroCrossingIndex = existingZeroCrossingIndex
            } else {
                zeroCrossingIndex = AudioZeroCrossingIndex.build(from: firstBuffer)
            }

            return ProjectMixResult(
                buffer: firstBuffer,
                zeroCrossingIndex: zeroCrossingIndex,
                trackCount: decodedTracks.count
            )
        }

        let sampleRate = firstBuffer.sampleRate
        var renderedTracks: [(volume: Float, buffer: DecodedAudioBuffer)] = [
            (volume: firstTrack.volume, buffer: firstBuffer),
        ]
        renderedTracks.reserveCapacity(decodedTracks.count)
        for track in decodedTracks.dropFirst() {
            renderedTracks.append((volume: track.volume, buffer: try decodedMixBuffer(for: track)))
        }

        let channelCount = max(renderedTracks.map(\.buffer.channelCount).max() ?? 2, 2)
        let frameCount = renderedTracks.reduce(0) { result, item in
            max(result, item.buffer.frameCount)
        }
        guard frameCount > 0 else {
            return nil
        }

        var samplesByChannel = (0..<channelCount).map { _ in
            [Float](repeating: 0, count: frameCount)
        }

        for track in renderedTracks {
            let buffer = track.buffer
            let gain = track.volume * track.volume
            for outputChannel in 0..<channelCount {
                let sourceChannel = buffer.channelCount == 1 ? 0 : min(outputChannel, buffer.channelCount - 1)
                let sourceSamples = buffer.samplesByChannel[sourceChannel]
                for frameIndex in 0..<buffer.frameCount {
                    let mixedSample =
                        samplesByChannel[outputChannel][frameIndex] + sourceSamples[frameIndex] * gain
                    samplesByChannel[outputChannel][frameIndex] = min(max(mixedSample, -1), 1)
                }
            }
        }

        let buffer = DecodedAudioBuffer(
            url: outputURL,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            samplesByChannel: samplesByChannel
        )
        return ProjectMixResult(
            buffer: buffer,
            zeroCrossingIndex: AudioZeroCrossingIndex.build(from: buffer),
            trackCount: decodedTracks.count
        )
    }

    private var audibleProjectTracks: [ProjectTrack] {
        let anySoloedTrack = projectTracks.contains { $0.isSoloed }
        return projectTracks.filter { track in
            isProjectTrackAudible(track, anySoloedTrack: anySoloedTrack) && track.volume > 0
        }
    }

    private func isProjectTrackAudible(
        _ track: ProjectTrack,
        anySoloedTrack: Bool
    ) -> Bool {
        anySoloedTrack ? track.isSoloed : !track.isMuted
    }

    private func activeProjectTrackIndex() -> Int? {
        if let selectedTrackID = selectedTimelineRange?.trackID,
           let selectedTrackIndex = projectTracks.firstIndex(where: { $0.id == selectedTrackID })
        {
            return selectedTrackIndex
        }

        if let selectedTrackID,
           let selectedTrackIndex = projectTracks.firstIndex(where: { $0.id == selectedTrackID })
        {
            return selectedTrackIndex
        }

        if let activeTrackID,
           let trackIndex = projectTracks.firstIndex(where: { $0.id == activeTrackID })
        {
            return trackIndex
        }

        guard !projectTracks.isEmpty else {
            return nil
        }

        return projectTracks.count - 1
    }

    private func trackDuration(for track: ProjectTrack) -> TimeInterval {
        track.waveformOverview?.duration ??
            track.audioTimeline?.duration ??
            track.fileTimeline?.duration ??
            track.decodedAudioBuffer?.duration ??
            track.durationHint ??
            0
    }

    private var projectSelectionDuration: TimeInterval {
        let duration = displayedDuration
        if duration > 0 {
            return duration
        }

        return projectTracks.reduce(TimeInterval(0)) { result, track in
            max(result, trackDuration(for: track))
        }
    }

    private func fullTrackDisplaySelection(for trackID: UUID) -> TimelineSelection {
        guard
            let track = projectTracks.first(where: { $0.id == trackID })
        else {
            return TimelineSelection(startProgress: 0, endProgress: 1, trackID: trackID)
        }

        let projectDuration = projectSelectionDuration
        let trackDuration = trackDuration(for: track)
        let endProgress = projectDuration > 0 && trackDuration > 0 ?
            min(max(trackDuration / projectDuration, 0), 1) :
            1
        return TimelineSelection(
            startProgress: 0,
            endProgress: endProgress,
            trackID: trackID
        )
    }

    private func fullTrackEditSelection(for trackID: UUID) -> TimelineSelection {
        TimelineSelection(startProgress: 0, endProgress: 1, trackID: trackID)
    }

    private func isFullTrackSelection(_ selection: TimelineSelection?, trackID: UUID) -> Bool {
        guard let selection, selection.trackID == trackID else {
            return false
        }

        let expectedSelection = fullTrackDisplaySelection(for: trackID)
        let epsilon = 0.000_001
        if
            abs(selection.startProgress - expectedSelection.startProgress) <= epsilon,
            abs(selection.endProgress - expectedSelection.endProgress) <= epsilon
        {
            return true
        }

        return selection.startProgress <= epsilon && selection.endProgress >= 1 - epsilon
    }

    private func editSelection(
        from displaySelection: TimelineSelection,
        trackIndex: Int
    ) -> TimelineSelection? {
        guard projectTracks.indices.contains(trackIndex) else {
            return nil
        }

        let track = projectTracks[trackIndex]
        let projectDuration = projectSelectionDuration
        let trackDuration = trackDuration(for: track)
        guard projectDuration > 0, trackDuration > 0 else {
            return nil
        }

        let startTime = displaySelection.startProgress * projectDuration
        let endTime = displaySelection.endProgress * projectDuration
        let clampedStartTime = min(max(startTime, 0), trackDuration)
        let clampedEndTime = min(max(endTime, 0), trackDuration)
        let selection = TimelineSelection(
            startProgress: clampedStartTime / trackDuration,
            endProgress: clampedEndTime / trackDuration,
            trackID: track.id
        )
        return selection.durationProgress > 0 ? selection : nil
    }

    private func editInsertionSelection(
        forPlaybackProgress progress: Float,
        trackIndex: Int
    ) -> TimelineSelection {
        guard projectTracks.indices.contains(trackIndex) else {
            let clampedProgress = Double(min(max(progress, 0), 1))
            return TimelineSelection(startProgress: clampedProgress, endProgress: clampedProgress)
        }

        let track = projectTracks[trackIndex]
        let projectDuration = projectSelectionDuration
        let trackDuration = trackDuration(for: track)
        let insertionProgress: Double
        if projectDuration > 0, trackDuration > 0 {
            let insertionTime = Double(min(max(progress, 0), 1)) * projectDuration
            insertionProgress = min(max(insertionTime / trackDuration, 0), 1)
        } else {
            insertionProgress = Double(min(max(progress, 0), 1))
        }

        return TimelineSelection(
            startProgress: insertionProgress,
            endProgress: insertionProgress,
            trackID: track.id
        )
    }

    private func trackIndex(for selection: TimelineSelection) -> Int? {
        if let trackID = selection.trackID {
            return projectTracks.firstIndex(where: { $0.id == trackID })
        }

        if let activeTrackID,
           let activeIndex = projectTracks.firstIndex(where: { $0.id == activeTrackID })
        {
            return activeIndex
        }

        return projectTracks.count == 1 ? 0 : nil
    }

    private func currentEditableSelectionTarget() -> EditableSelectionTarget? {
        if
            let selection = selectedTimelineRange,
            selection.durationProgress > 0,
            let trackIndex = trackIndex(for: selection),
            projectTracks.indices.contains(trackIndex),
            let editSelection = editSelection(from: selection, trackIndex: trackIndex)
        {
            let trackID = projectTracks[trackIndex].id
            let displaySelection = TimelineSelection(
                startProgress: selection.startProgress,
                endProgress: selection.endProgress,
                trackID: trackID
            )
            return EditableSelectionTarget(
                trackIndex: trackIndex,
                displaySelection: displaySelection,
                editSelection: editSelection
            )
        }

        if
            let selectedTrackID,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == selectedTrackID })
        {
            return EditableSelectionTarget(
                trackIndex: trackIndex,
                displaySelection: fullTrackDisplaySelection(for: selectedTrackID),
                editSelection: fullTrackEditSelection(for: selectedTrackID)
            )
        }

        return nil
    }

    private func editableClipAtPlayheadTarget() -> EditableSelectionTarget? {
        guard
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            return nil
        }

        let track = projectTracks[trackIndex]
        let projectDuration = projectSelectionDuration
        let trackDuration = trackDuration(for: track)
        guard projectDuration > 0, trackDuration > 0 else {
            return nil
        }

        let playheadTime = Double(playbackController.snapshot().progress) * projectDuration
        let localProgress = min(max(playheadTime / trackDuration, 0), 1)
        let clipRanges = timelineClipRanges(for: track)
        guard let clipRange = clipRanges.first(where: {
            localProgress >= $0.startProgress && localProgress <= $0.endProgress
        }) ?? clipRanges.first else {
            return nil
        }

        let trackDurationProgress = trackDuration / projectDuration
        let displaySelection = TimelineSelection(
            startProgress: clipRange.startProgress * trackDurationProgress,
            endProgress: clipRange.endProgress * trackDurationProgress,
            trackID: track.id
        )
        let editSelection = TimelineSelection(
            startProgress: clipRange.startProgress,
            endProgress: clipRange.endProgress,
            trackID: track.id
        )
        guard editSelection.durationProgress > 0 else {
            return nil
        }

        return EditableSelectionTarget(
            trackIndex: trackIndex,
            displaySelection: displaySelection,
            editSelection: editSelection
        )
    }

    private func editableClipSlipTarget() -> EditableSelectionTarget? {
        guard
            let baseTarget = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget(),
            projectTracks.indices.contains(baseTarget.trackIndex)
        else {
            return nil
        }

        let track = projectTracks[baseTarget.trackIndex]
        let midpointProgress = (
            baseTarget.editSelection.startProgress +
                baseTarget.editSelection.endProgress
        ) * 0.5
        guard
            let clipRange = timelineClipRanges(for: track).first(where: {
                midpointProgress >= $0.startProgress && midpointProgress <= $0.endProgress
            })
        else {
            return baseTarget
        }

        let projectDuration = projectSelectionDuration
        let trackDuration = trackDuration(for: track)
        let trackDurationProgress = projectDuration > 0 ? trackDuration / projectDuration : 1
        let displaySelection = TimelineSelection(
            startProgress: clipRange.startProgress * trackDurationProgress,
            endProgress: clipRange.endProgress * trackDurationProgress,
            trackID: track.id
        )
        let editSelection = TimelineSelection(
            startProgress: clipRange.startProgress,
            endProgress: clipRange.endProgress,
            trackID: track.id
        )
        return EditableSelectionTarget(
            trackIndex: baseTarget.trackIndex,
            displaySelection: displaySelection,
            editSelection: editSelection
        )
    }

    private func materializeEditedTimeline(
        trackID: UUID,
        timeline: AudioEditTimeline,
        editRevision: Int,
        status: String,
        preservePlaybackProgress: Bool = false,
        startDelay: TimeInterval = 0,
        animateWaveformTransition: Bool = true
    ) {
        editMaterializationTasks[trackID]?.cancel()
        let requestID = UUID()
        editMaterializationRequestIDs[trackID] = requestID

        let task = Task { [
            weak self,
            trackID,
            timeline,
            editRevision,
            status,
            preservePlaybackProgress,
            startDelay,
            animateWaveformTransition,
            requestID
        ] in
            if startDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
            }

            guard !Task.isCancelled else {
                self?.clearEditMaterializationTask(trackID: trackID, requestID: requestID)
                return
            }

            let materialized = await Task.detached(priority: .utility) {
                Self.materializeTimeline(timeline)
            }.value

            guard let self else {
                return
            }

            guard
                !Task.isCancelled,
                self.editMaterializationRequestIDs[trackID] == requestID
            else {
                self.clearEditMaterializationTask(trackID: trackID, requestID: requestID)
                return
            }

            self.clearEditMaterializationTask(trackID: trackID, requestID: requestID)
            self.applyMaterializedTrackEdit(
                trackID: trackID,
                editRevision: editRevision,
                materialized: materialized,
                status: status,
                preservePlaybackProgress: preservePlaybackProgress,
                animateWaveformTransition: animateWaveformTransition
            )
        }
        editMaterializationTasks[trackID] = task
    }

    private func clearEditMaterializationTask(trackID: UUID, requestID: UUID) {
        guard editMaterializationRequestIDs[trackID] == requestID else {
            return
        }

        editMaterializationTasks[trackID] = nil
        editMaterializationRequestIDs[trackID] = nil
    }

    private func scheduleFileTimelineWaveformRefinement(
        trackID: UUID,
        fileTimeline: AudioFileEditTimeline?,
        sourceOverview: WaveformOverview?,
        editRevision: Int,
        delay: TimeInterval? = nil
    ) {
        guard
            let fileTimeline,
            let sourceOverview,
            sourceOverview.bins.count > optimisticEditPreviewBinLimit
        else {
            cancelEditWaveformRefinement(for: trackID)
            return
        }

        editWaveformRefinementTasks[trackID]?.cancel()
        let requestID = UUID()
        editWaveformRefinementRequestIDs[trackID] = requestID

        let task = Task { [
            weak self,
            trackID,
            fileTimeline,
            sourceOverview,
            editRevision,
            editWaveformRefinementDelay = delay ?? editWaveformRefinementDelay,
            requestID
        ] in
            try? await Task.sleep(nanoseconds: UInt64(editWaveformRefinementDelay * 1_000_000_000))
            guard !Task.isCancelled else {
                self?.clearEditWaveformRefinementTask(trackID: trackID, requestID: requestID)
                return
            }

            let refinedOverview = await Task.detached(priority: .utility) {
                fileTimeline.waveformOverview(from: sourceOverview)
            }.value

            guard let self else {
                return
            }

            guard
                !Task.isCancelled,
                self.editWaveformRefinementRequestIDs[trackID] == requestID,
                let trackIndex = self.projectTracks.firstIndex(where: { $0.id == trackID }),
                self.projectTracks[trackIndex].editRevision == editRevision,
                self.projectTracks[trackIndex].fileTimeline != nil
            else {
                self.clearEditWaveformRefinementTask(trackID: trackID, requestID: requestID)
                return
            }

            self.clearEditWaveformRefinementTask(trackID: trackID, requestID: requestID)
            self.projectTracks[trackIndex].waveformOverview = refinedOverview
            self.refreshProjectTimelineDisplay(
                rebuildControls: false,
                animateWaveformTransition: false
            )
            self.updateProjectDisplayTiming()
        }
        editWaveformRefinementTasks[trackID] = task
    }

    private func clearEditWaveformRefinementTask(trackID: UUID, requestID: UUID) {
        guard editWaveformRefinementRequestIDs[trackID] == requestID else {
            return
        }

        editWaveformRefinementTasks[trackID] = nil
        editWaveformRefinementRequestIDs[trackID] = nil
    }

    private func applyMaterializedTrackEdit(
        trackID: UUID,
        editRevision: Int,
        materialized: (
            buffer: DecodedAudioBuffer,
            timeline: AudioEditTimeline,
            waveformOverview: WaveformOverview,
            zeroCrossingIndex: AudioZeroCrossingIndex
        ),
        status: String,
        preservePlaybackProgress: Bool = false,
        reloadPlaybackSource: Bool = false,
        preserveTimelineSource: Bool = true,
        animateWaveformTransition: Bool = true
    ) {
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            projectTracks[trackIndex].editRevision == editRevision
        else {
            return
        }

        let existingTimeline = projectTracks[trackIndex].audioTimeline
        let shouldPreserveTimelineSource = preserveTimelineSource && existingTimeline != nil
        projectTracks[trackIndex].decodedAudioBuffer = materialized.buffer
        projectTracks[trackIndex].audioTimeline = shouldPreserveTimelineSource ?
            existingTimeline :
            materialized.timeline
        projectTracks[trackIndex].fileTimeline = nil
        if !shouldPreserveTimelineSource || projectTracks[trackIndex].sourceWaveformOverview == nil {
            projectTracks[trackIndex].sourceWaveformOverview = materialized.waveformOverview
        }
        projectTracks[trackIndex].waveformOverview = materialized.waveformOverview
        if !shouldPreserveTimelineSource {
            projectTracks[trackIndex].zeroCrossingIndex = materialized.zeroCrossingIndex
        }
        activeTrackID = trackID
        syncActiveTrackFields()
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        refreshProjectTimelineDisplay(
            rebuildControls: false,
            animateWaveformTransition: animateWaveformTransition
        )
        updateProjectDisplayTiming(sampleRateHint: materialized.buffer.sampleRate)
        if !shouldPreserveTimelineSource || reloadPlaybackSource {
            if playbackController.isPlaying, !reloadPlaybackSource {
                updateProjectPlaybackTrackMix()
            } else {
                reloadPlaybackFromProjectTracks(preserveProgress: preservePlaybackProgress)
            }
        }
        updateEffectCommandState()
        updateStatus(status)
    }

    private nonisolated static func materializeTimeline(_ timeline: AudioEditTimeline) -> (
        buffer: DecodedAudioBuffer,
        timeline: AudioEditTimeline,
        waveformOverview: WaveformOverview,
        zeroCrossingIndex: AudioZeroCrossingIndex
    ) {
        let buffer = timeline.render()
        return (
            buffer: buffer,
            timeline: timeline,
            waveformOverview: WaveformOverviewBuilder.build(from: buffer),
            zeroCrossingIndex: AudioZeroCrossingIndex.build(from: buffer)
        )
    }

    private nonisolated static func materializePaste(
        timeline: AudioEditTimeline,
        selection: TimelineSelection,
        clipboardBuffer: DecodedAudioBuffer
    ) throws -> (
        buffer: DecodedAudioBuffer,
        timeline: AudioEditTimeline,
        waveformOverview: WaveformOverview,
        zeroCrossingIndex: AudioZeroCrossingIndex
    ) {
        let sourceBuffer = timeline.render()
        guard
            sourceBuffer.sampleRate > 0,
            clipboardBuffer.sampleRate > 0,
            abs(sourceBuffer.sampleRate - clipboardBuffer.sampleRate) < 0.001
        else {
            throw PlaybackError.invalidFormat
        }

        let replaceRange = timeline.frameRange(for: selection)
        let channelCount = max(sourceBuffer.channelCount, clipboardBuffer.channelCount)
        let nextFrameCount = replaceRange.lowerBound +
            clipboardBuffer.frameCount +
            max(sourceBuffer.frameCount - replaceRange.upperBound, 0)
        var samplesByChannel = (0..<channelCount).map { _ in
            [Float]()
        }

        for channelIndex in samplesByChannel.indices {
            samplesByChannel[channelIndex].reserveCapacity(nextFrameCount)
            let sourceChannel = sourceBuffer.channelCount == 1 ?
                0 :
                min(channelIndex, sourceBuffer.channelCount - 1)
            let clipboardChannel = clipboardBuffer.channelCount == 1 ?
                0 :
                min(channelIndex, clipboardBuffer.channelCount - 1)
            let sourceSamples = sourceBuffer.samplesByChannel[sourceChannel]
            let clipboardSamples = clipboardBuffer.samplesByChannel[clipboardChannel]

            if replaceRange.lowerBound > 0 {
                samplesByChannel[channelIndex].append(contentsOf: sourceSamples[0..<replaceRange.lowerBound])
            }
            samplesByChannel[channelIndex].append(contentsOf: clipboardSamples)
            if replaceRange.upperBound < sourceSamples.count {
                samplesByChannel[channelIndex].append(contentsOf: sourceSamples[replaceRange.upperBound..<sourceSamples.count])
            }
        }

        let buffer = DecodedAudioBuffer(
            url: sourceBuffer.url,
            sampleRate: sourceBuffer.sampleRate,
            channelCount: channelCount,
            frameCount: nextFrameCount,
            samplesByChannel: samplesByChannel
        )
        let timeline = AudioEditTimeline(sourceBuffer: buffer)
        return (
            buffer: buffer,
            timeline: timeline,
            waveformOverview: WaveformOverviewBuilder.build(from: buffer),
            zeroCrossingIndex: AudioZeroCrossingIndex.build(from: buffer)
        )
    }

    private func optimisticWaveformOverview(
        _ overview: WaveformOverview?,
        replacing selection: TimelineSelection,
        with replacement: WaveformOverview?,
        targetDuration: TimeInterval? = nil
    ) -> WaveformOverview? {
        guard let overview else {
            return replacement.map(overviewForOptimisticEdit)
        }

        let sourceOverview = overviewForOptimisticEdit(overview)
        let replacementOverview = replacement.map(overviewForOptimisticEdit)
        let binCount = sourceOverview.bins.count
        guard binCount > 0 else {
            return replacementOverview ?? sourceOverview
        }

        let startIndex = min(max(Int((selection.startProgress * Double(binCount)).rounded(.down)), 0), binCount)
        let endIndex: Int
        if
            replacementOverview == nil,
            let targetDuration,
            targetDuration.isFinite,
            targetDuration >= 0,
            sourceOverview.duration.isFinite,
            sourceOverview.duration > 0
        {
            let targetBinCount = min(
                max(Int((Double(binCount) * targetDuration / sourceOverview.duration).rounded()), 0),
                binCount
            )
            let targetRemovedBinCount = min(max(binCount - targetBinCount, 0), binCount - startIndex)
            endIndex = min(startIndex + targetRemovedBinCount, binCount)
        } else {
            endIndex = min(max(Int((selection.endProgress * Double(binCount)).rounded(.up)), startIndex), binCount)
        }
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount - (endIndex - startIndex) + (replacementOverview?.bins.count ?? 0))
        if startIndex > 0 {
            bins.append(contentsOf: sourceOverview.bins[0..<startIndex])
        }
        if let replacementOverview {
            bins.append(contentsOf: replacementOverview.bins)
        }
        if endIndex < binCount {
            bins.append(contentsOf: sourceOverview.bins[endIndex..<binCount])
        }

        let removedDuration = sourceOverview.duration * TimeInterval(selection.durationProgress)
        let nextDuration = targetDuration.map { max($0, 0) } ??
            max(sourceOverview.duration - removedDuration + (replacementOverview?.duration ?? 0), 0)
        return WaveformOverview(duration: nextDuration, bins: bins)
    }

    private func optimisticWaveformOverview(
        _ overview: WaveformOverview?,
        applyingGain gain: Float,
        to selection: TimelineSelection
    ) -> WaveformOverview? {
        guard let overview else {
            return nil
        }

        let sourceOverview = overviewForOptimisticEdit(overview)
        let binCount = sourceOverview.bins.count
        guard binCount > 0 else {
            return sourceOverview
        }

        let startIndex = min(max(Int((selection.startProgress * Double(binCount)).rounded(.down)), 0), binCount)
        let endIndex = min(max(Int((selection.endProgress * Double(binCount)).rounded(.up)), startIndex), binCount)
        guard startIndex < endIndex else {
            return sourceOverview
        }

        var bins = sourceOverview.bins
        for index in startIndex..<endIndex {
            bins[index] = bins[index].scaled(by: gain)
        }

        return WaveformOverview(duration: sourceOverview.duration, bins: bins)
    }

    private func optimisticWaveformOverview(
        _ overview: WaveformOverview?,
        applyingFade fadeDirection: AudioEditTimeline.FadeDirection,
        to selection: TimelineSelection
    ) -> WaveformOverview? {
        guard let overview else {
            return nil
        }

        let sourceOverview = overviewForOptimisticEdit(overview)
        let binCount = sourceOverview.bins.count
        guard binCount > 0 else {
            return sourceOverview
        }

        let startIndex = min(max(Int((selection.startProgress * Double(binCount)).rounded(.down)), 0), binCount)
        let endIndex = min(max(Int((selection.endProgress * Double(binCount)).rounded(.up)), startIndex), binCount)
        guard startIndex < endIndex else {
            return sourceOverview
        }

        let selectedCount = max(endIndex - startIndex, 1)
        var bins = sourceOverview.bins
        for index in startIndex..<endIndex {
            let selectedOffset = index - startIndex
            let progress = selectedCount > 1 ?
                Float(selectedOffset) / Float(selectedCount - 1) :
                1
            let curve = smoothStep(progress)
            let multiplier: Float
            switch fadeDirection {
            case .fadeIn:
                multiplier = curve
            case .fadeOut:
                multiplier = 1 - curve
            }
            bins[index] = bins[index].scaled(by: multiplier)
        }

        return WaveformOverview(duration: sourceOverview.duration, bins: bins)
    }

    private func smoothStep(_ progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        return clampedProgress * clampedProgress * (3 - 2 * clampedProgress)
    }

    private func selectedPeakMagnitude(for target: EditableSelectionTarget) -> Float? {
        guard
            projectTracks.indices.contains(target.trackIndex),
            let overview = projectTracks[target.trackIndex].waveformOverview
        else {
            return nil
        }

        let sourceOverview = overviewForOptimisticEdit(overview)
        let binCount = sourceOverview.bins.count
        guard binCount > 0 else {
            return nil
        }

        let startIndex = min(
            max(Int((target.editSelection.startProgress * Double(binCount)).rounded(.down)), 0),
            binCount
        )
        let endIndex = min(
            max(Int((target.editSelection.endProgress * Double(binCount)).rounded(.up)), startIndex),
            binCount
        )
        guard startIndex < endIndex else {
            return nil
        }

        var peak: Float = 0
        for index in startIndex..<endIndex {
            peak = max(peak, sourceOverview.bins[index].peakMagnitude)
        }
        return peak
    }

    private func selectedWaveformOverview(
        from overview: WaveformOverview?,
        selection: TimelineSelection
    ) -> WaveformOverview? {
        guard let overview else {
            return nil
        }

        let sourceOverview = overviewForOptimisticEdit(overview)
        let binCount = sourceOverview.bins.count
        guard binCount > 0 else {
            return nil
        }

        let startIndex = min(
            max(Int((selection.startProgress * Double(binCount)).rounded(.down)), 0),
            binCount
        )
        let endIndex = min(
            max(Int((selection.endProgress * Double(binCount)).rounded(.up)), startIndex),
            binCount
        )
        guard startIndex < endIndex else {
            return nil
        }

        return WaveformOverview(
            duration: selection.duration(in: sourceOverview.duration),
            bins: Array(sourceOverview.bins[startIndex..<endIndex])
        )
    }

    private nonisolated static func selectionsMatch(
        _ lhs: TimelineSelection,
        _ rhs: TimelineSelection
    ) -> Bool {
        let epsilon = 0.000_001
        return lhs.trackID == rhs.trackID &&
            abs(lhs.startProgress - rhs.startProgress) <= epsilon &&
            abs(lhs.endProgress - rhs.endProgress) <= epsilon
    }

    private nonisolated static func exactPeakMagnitude(
        audioTimeline: AudioEditTimeline?,
        fileTimeline: AudioFileEditTimeline?,
        sourceURL: URL,
        selection: TimelineSelection
    ) throws -> Float {
        if let audioTimeline {
            return peakMagnitude(in: audioTimeline.render(selection: selection))
        }

        if let fileTimeline {
            let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
            let audioTimeline = fileTimeline.audioTimeline(sourceBuffer: sourceBuffer)
            return peakMagnitude(in: audioTimeline.render(selection: selection))
        }

        throw PlaybackError.noAudioLoaded
    }

    private nonisolated static func peakMagnitude(in buffer: DecodedAudioBuffer) -> Float {
        var peak: Float = 0
        for samples in buffer.samplesByChannel {
            for sample in samples {
                peak = max(peak, abs(sample))
            }
        }
        return peak
    }

    private func overviewForOptimisticEdit(_ overview: WaveformOverview) -> WaveformOverview {
        guard overview.bins.count > optimisticEditPreviewBinLimit else {
            return overview
        }

        return sparseOverview(
            from: overview,
            targetBinCount: optimisticEditPreviewBinLimit,
            samplesPerBin: optimisticEditPreviewSamplesPerBin
        )
    }

    private func sparseOverview(
        from overview: WaveformOverview,
        targetBinCount: Int,
        samplesPerBin: Int
    ) -> WaveformOverview {
        let sourceBins = overview.bins
        let sourceBinCount = sourceBins.count
        let targetBinCount = min(max(targetBinCount, 1), sourceBinCount)
        let samplesPerBin = max(samplesPerBin, 1)
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(targetBinCount)

        for targetIndex in 0..<targetBinCount {
            let sourceStartIndex = targetIndex * sourceBinCount / targetBinCount
            let sourceEndIndex = max(sourceStartIndex + 1, (targetIndex + 1) * sourceBinCount / targetBinCount)
            let sourceSpan = sourceEndIndex - sourceStartIndex
            let stride = max(sourceSpan / samplesPerBin, 1)
            var accumulator = WaveformBinAccumulator()
            var sampledIndex = sourceStartIndex
            var sampledCount = 0

            while sampledIndex < sourceEndIndex, sampledCount < samplesPerBin {
                accumulator.addBin(sourceBins[sampledIndex])
                sampledIndex += stride
                sampledCount += 1
            }

            if sourceSpan > 1 {
                accumulator.addBin(sourceBins[sourceEndIndex - 1])
            }

            bins.append(accumulator.makeBin())
        }

        return WaveformOverview(duration: overview.duration, bins: bins)
    }

    private func loadDroppedWAVFile(at url: URL, importID: UUID) {
        let wavPreviewLevels = wavPreviewLevels

        Task { [weak self, importID, url, wavPreviewLevels] in
            do {
                guard let initialPreviewLevel = wavPreviewLevels.first else {
                    return
                }

                let previewResult = try await AudioImportPipeline.loadWAVPreview(
                    at: url,
                    targetBinCount: initialPreviewLevel.targetBinCount,
                    samplesPerBin: initialPreviewLevel.samplesPerBin
                )

                guard let self, self.activeImportID == importID else {
                    return
                }

                self.applyPreview(previewResult)
                var latestPreviewBinCount = previewResult.waveformOverview.bins.count

                for previewLevel in wavPreviewLevels.dropFirst() {
                    guard self.activeImportID == importID else {
                        return
                    }
                    guard await self.waitForSingleFileImportWorkBudget(importID: importID) else {
                        return
                    }

                    let nextBinCount = min(previewLevel.targetBinCount, previewResult.fileInfo.frameCount)
                    guard nextBinCount > latestPreviewBinCount else {
                        continue
                    }

                    do {
                        let (fileInfo, waveformOverview) = try await AudioImportPipeline.loadWAVPreviewOverview(
                            at: url,
                            targetBinCount: previewLevel.targetBinCount,
                            samplesPerBin: previewLevel.samplesPerBin
                        )

                        guard self.activeImportID == importID else {
                            return
                        }
                        guard await self.waitForSingleFileImportWorkBudget(importID: importID) else {
                            return
                        }

                        latestPreviewBinCount = waveformOverview.bins.count
                        self.applyPreviewRefinement(
                            fileInfo: fileInfo,
                            waveformOverview: waveformOverview
                        )
                    } catch {
                        break
                    }
                }

                do {
                    guard await self.waitForSingleFileImportWorkBudget(
                        importID: importID,
                        idleSettleDuration: 0.65
                    ) else {
                        return
                    }

                    let (decodedAudioBuffer, waveformOverview, zeroCrossingIndex) =
                        try await AudioImportPipeline.loadDecodedWAV(at: url)

                    guard self.activeImportID == importID else {
                        return
                    }
                    guard await self.waitForSingleFileImportWorkBudget(importID: importID) else {
                        return
                    }

                    self.applyDecodedWAV(
                        decodedAudioBuffer: decodedAudioBuffer,
                        waveformOverview: waveformOverview,
                        zeroCrossingIndex: zeroCrossingIndex
                    )
                } catch {
                    guard self.activeImportID == importID else {
                        return
                    }

                    self.currentPlaybackStatus = "preview ready - edit decode failed: \(error.localizedDescription)"
                    self.updateStatus(self.currentPlaybackStatus)
                }
            } catch {
                guard let self, self.activeImportID == importID else {
                    return
                }

                self.selectedAudioFile = nil
                self.decodedAudioBuffer = nil
                self.audioTimeline = nil
                self.editUndoStack.removeAll()
                self.loadedAudioSummary = nil
                self.selectedTimelineRange = nil
                self.updateEffectCommandState()
                self.currentPlayheadFrame = 0
                self.displayedFrameCount = 0
                self.displayedSampleRate = 0
                self.currentPlaybackStatus = "idle"
                self.playbackController.clear()
                self.timelineSurface.displaySelection(nil)
                self.displayPlaybackVisuals(progress: 0, isPlaying: false)
                self.timelineSurface.displayWaveform(nil)
                self.updateTimeReadout()
                self.metadataLabel.stringValue = "\(url.lastPathComponent) - WAV preview failed: \(error.localizedDescription)"
            }
        }
    }

    private func applyPreview(_ previewResult: WAVPreviewImportResult) {
        selectedAudioFile = previewResult.metadata
        decodedAudioBuffer = nil
        audioTimeline = nil
        editUndoStack.removeAll()
        selectedTimelineRange = nil
        updateEffectCommandState()
        currentPlayheadFrame = 0
        displayedFrameCount = previewResult.fileInfo.frameCount
        displayedSampleRate = previewResult.fileInfo.sampleRate
        window?.title = "Soundtime - \(previewResult.metadata.displayName)"
        loadedAudioSummary = "\(previewResult.metadata.displayName) - \(previewResult.fileInfo.formattedSummary)"

        timelineSurface.displayWaveform(previewResult.waveformOverview)
        timelineSurface.displaySelection(nil)
        displayPlaybackVisuals(progress: 0, isPlaying: false)

        do {
            try playbackController.loadFile(
                at: previewResult.metadata.url,
                zeroCrossingProbe: previewResult.zeroCrossingProbe
            )
            currentPlaybackStatus = "press Space to play - resolving waveform"
        } catch {
            playbackController.clear()
            currentPlaybackStatus = "preview ready - playback failed: \(error.localizedDescription)"
        }

        updateStatus(currentPlaybackStatus)
    }

    private func applyPreviewRefinement(
        fileInfo: WAVFileInfo,
        waveformOverview: WaveformOverview
    ) {
        guard decodedAudioBuffer == nil else {
            return
        }

        displayedFrameCount = fileInfo.frameCount
        displayedSampleRate = fileInfo.sampleRate
        timelineSurface.displayWaveform(waveformOverview)
        let snapshot = playbackController.snapshot()
        displayPlaybackVisuals(
            progress: snapshot.progress,
            isPlaying: snapshot.isPlaying,
            syncPlayhead: !snapshot.isPlaying,
            anchorTimestamp: snapshot.hostTimestamp
        )
        updateTimeReadout()
    }

    private func applyDecodedWAV(
        decodedAudioBuffer: DecodedAudioBuffer,
        waveformOverview: WaveformOverview,
        zeroCrossingIndex: AudioZeroCrossingIndex
    ) {
        self.decodedAudioBuffer = decodedAudioBuffer
        audioTimeline = AudioEditTimeline(sourceBuffer: decodedAudioBuffer)
        editUndoStack.removeAll()
        displayedFrameCount = decodedAudioBuffer.frameCount
        displayedSampleRate = decodedAudioBuffer.sampleRate
        updateEffectCommandState()

        if !playbackController.hasSource {
            try? playbackController.load(decodedAudioBuffer, zeroCrossingIndex: zeroCrossingIndex)
        } else {
            try? playbackController.replaceWithDecodedSource(
                decodedAudioBuffer,
                zeroCrossingIndex: zeroCrossingIndex
            )
        }

        timelineSurface.displayWaveform(waveformOverview)
        let snapshot = playbackController.snapshot()
        displayPlaybackVisuals(
            progress: snapshot.progress,
            isPlaying: snapshot.isPlaying,
            syncPlayhead: !snapshot.isPlaying,
            anchorTimestamp: snapshot.hostTimestamp
        )
        updateLoadedAudioSummary(for: decodedAudioBuffer)
        currentPlaybackStatus = playbackController.isPlaying ? "playing" : "press Space to play"
        updateStatus(currentPlaybackStatus)
    }

    private func performAgentCommand(_ command: AgentResolvedCommand) -> AgentCommandResult {
        switch command {
        case .play:
            guard playbackController.hasSource else {
                return AgentCommandResult(status: .failed, message: "Agent: no audio loaded")
            }
            if !playbackController.isPlaying {
                togglePlayback()
            }
            return AgentCommandResult(status: .accepted, message: "Agent: playing")
        case .pause:
            if recordingTrackID != nil {
                stopRecording()
                return AgentCommandResult(status: .accepted, message: "Agent: recording stopped")
            }
            if playbackController.isPlaying {
                togglePlayback()
            }
            return AgentCommandResult(status: .accepted, message: "Agent: paused")
        case .togglePlayback:
            guard playbackController.hasSource || recordingTrackID != nil else {
                return AgentCommandResult(status: .failed, message: "Agent: no audio loaded")
            }
            togglePlayback()
            return AgentCommandResult(status: .accepted, message: "Agent: playback toggled")
        case .deleteSelection:
            guard selectedTrackID != nil || currentEditableSelectionTarget() != nil else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio or a track first")
            }
            deleteSelectedTrackOrSelection()
            return AgentCommandResult(status: .accepted, message: "Agent: delete requested")
        case .clearSelection:
            guard currentEditableSelectionTarget() != nil else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio to clear")
            }
            clearSelection()
            return AgentCommandResult(status: .accepted, message: "Agent: clear requested")
        case .cutSelection:
            guard currentEditableSelectionTarget() != nil else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio to cut")
            }
            cutSelection()
            return AgentCommandResult(status: .accepted, message: "Agent: cut requested")
        case .copySelection:
            guard currentEditableSelectionTarget() != nil else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio to copy")
            }
            copySelection()
            return AgentCommandResult(status: .accepted, message: "Agent: copy requested")
        case .pasteAudio:
            guard audioClipboard != nil else {
                return AgentCommandResult(status: .failed, message: "Agent: clipboard is empty")
            }
            pasteAudio()
            return AgentCommandResult(status: .accepted, message: "Agent: paste requested")
        case .splitAtPlayhead:
            guard canSplitAtPlayhead else {
                return AgentCommandResult(status: .failed, message: "Agent: move the playhead inside a track")
            }
            splitAtPlayhead()
            return AgentCommandResult(status: .accepted, message: "Agent: split requested")
        case .showGain:
            guard canApplyGainEffect else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio for gain")
            }
            showGainEffect()
            return AgentCommandResult(status: .accepted, message: "Agent: gain opened")
        case .deleteSilence:
            guard canDeleteSilence else {
                return AgentCommandResult(status: .failed, message: "Agent: select a track to clean")
            }
            reviewDeadAir()
            return AgentCommandResult(status: .accepted, message: "Agent: dead air review started")
        case .normalizeSelection:
            guard canApplyGainEffect else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio to normalize")
            }
            applyNormalizeEffect()
            return AgentCommandResult(status: .accepted, message: "Agent: normalize requested")
        case .fadeInSelection:
            guard canApplyFadeEffect else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio for fade in")
            }
            applyFadeEffect(.fadeIn)
            return AgentCommandResult(status: .accepted, message: "Agent: fade in requested")
        case .fadeOutSelection:
            guard canApplyFadeEffect else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio for fade out")
            }
            applyFadeEffect(.fadeOut)
            return AgentCommandResult(status: .accepted, message: "Agent: fade out requested")
        }
    }

    private func deleteSelection() {
        performOptimisticDelete(copyBeforeDeleting: false, scope: editScope)
    }

    private func removeTimeRangeAcrossScope() {
        performOptimisticDelete(copyBeforeDeleting: false, scope: editScope)
    }

    private func clearSelection() {
        guard
            let target = currentEditableSelectionTarget()
        else {
            updateStatus("select audio to clear")
            return
        }

        let displaySelectionToClear = target.displaySelection
        let clearTargets = rippleDeleteTargets(for: target, scope: editScope)
        let trackEdits: [ClearTrackEdit]
        do {
            trackEdits = try clearTargets.compactMap { try preparedClearTrackEdit(for: $0) }
        } catch {
            updateStatus("clear failed: \(error.localizedDescription)")
            return
        }
        guard !trackEdits.isEmpty else {
            updateStatus("no audio in selected time")
            return
        }

        let undoSnapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: displaySelectionToClear.startProgressFloat
        )

        SoundtimeDiagnostics.shared.record(
            category: .edit,
            severity: .info,
            name: "clear-selection",
            message: "User requested a scoped non-ripple clear edit.",
            fields: [
                "scope": editScope.title,
                "trackCount": "\(trackEdits.count)",
                "startProgress": String(format: "%.9f", displaySelectionToClear.startProgress),
                "endProgress": String(format: "%.9f", displaySelectionToClear.endProgress),
            ]
        )

        editUndoStack.append(.projectTracks(undoSnapshot))
        var materializationEdits: [(trackID: UUID, timeline: AudioEditTimeline, editRevision: Int)] = []
        var statusDuration = TimeInterval(0)
        for edit in trackEdits {
            guard projectTracks.indices.contains(edit.trackIndex) else {
                continue
            }

            projectTracks[edit.trackIndex].editRevision += 1
            let editRevision = projectTracks[edit.trackIndex].editRevision
            projectTracks[edit.trackIndex].audioTimeline = edit.editedAudioTimeline
            projectTracks[edit.trackIndex].fileTimeline = edit.editedFileTimeline
            projectTracks[edit.trackIndex].decodedAudioBuffer = nil
            projectTracks[edit.trackIndex].durationHint = edit.editedDuration
            let currentOverview = projectTracks[edit.trackIndex].waveformOverview
            if let editedFileTimeline = edit.editedFileTimeline {
                projectTracks[edit.trackIndex].waveformOverview =
                    optimisticWaveformOverview(
                        currentOverview,
                        applyingGain: 0,
                        to: edit.editSelection
                    ) ??
                    optimisticWaveformOverview(
                        for: editedFileTimeline,
                        sourceOverview: projectTracks[edit.trackIndex].sourceWaveformOverview,
                        fallbackOverview: currentOverview
                    )
                scheduleFileTimelineWaveformRefinement(
                    trackID: edit.trackID,
                    fileTimeline: editedFileTimeline,
                    sourceOverview: projectTracks[edit.trackIndex].sourceWaveformOverview ?? currentOverview,
                    editRevision: editRevision
                )
            } else {
                projectTracks[edit.trackIndex].waveformOverview = optimisticWaveformOverview(
                    currentOverview,
                    applyingGain: 0,
                    to: edit.editSelection
                )
                cancelEditWaveformRefinement(for: edit.trackID)
            }

            statusDuration = max(statusDuration, edit.clearedDuration)
            if let editedAudioTimeline = edit.editedAudioTimeline {
                materializationEdits.append((
                    trackID: edit.trackID,
                    timeline: editedAudioTimeline,
                    editRevision: editRevision
                ))
            }
        }

        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        updateEffectCommandState()
        let scopeSuffix: String
        if trackEdits.count > 1 {
            switch editScope {
            case .track:
                scopeSuffix = ""
            case .selected:
                scopeSuffix = " across \(trackEdits.count) selected tracks"
            case .group:
                scopeSuffix = " across \(trackEdits.count) grouped tracks"
            case .all:
                scopeSuffix = " across \(trackEdits.count) tracks"
            }
        } else {
            scopeSuffix = ""
        }
        let status = "cleared \(formatDuration(statusDuration))\(scopeSuffix)"
        updateStatus(status)

        for edit in materializationEdits {
            materializeEditedTimeline(
                trackID: edit.trackID,
                timeline: edit.timeline,
                editRevision: edit.editRevision,
                status: status,
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay,
                animateWaveformTransition: false
            )
        }
    }

    private func deleteSelectedTrackOrSelection() {
        if selectedTrackID != nil || !selectedTrackIDs.isEmpty {
            deleteSelectedTrack()
        } else {
            deleteSelection()
        }
    }

    private func splitAtPlayhead() {
        guard
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            updateStatus("select a track to split")
            return
        }

        let snapshot = playbackController.snapshot()
        let projectProgress = min(max(snapshot.progress, 0), 1)
        let scopedTrackIndices = scopedTrackIndices(anchorTrackIndex: trackIndex, scope: editScope)
        let trackEdits: [SplitTrackEdit]
        do {
            trackEdits = try scopedTrackIndices.compactMap {
                try preparedSplitTrackEdit(trackIndex: $0, projectProgress: projectProgress)
            }
        } catch {
            updateStatus("split failed: \(error.localizedDescription)")
            return
        }
        guard !trackEdits.isEmpty else {
            updateStatus("move the playhead inside the track to split")
            return
        }

        let undoSnapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: projectProgress
        )

        editUndoStack.append(.projectTracks(undoSnapshot))
        for edit in trackEdits {
            guard projectTracks.indices.contains(edit.trackIndex) else {
                continue
            }

            projectTracks[edit.trackIndex].editRevision += 1
            projectTracks[edit.trackIndex].audioTimeline = edit.editedAudioTimeline
            projectTracks[edit.trackIndex].fileTimeline = edit.editedFileTimeline
            projectTracks[edit.trackIndex].decodedAudioBuffer = edit.editedAudioTimeline?.sourceAudioBuffer
            projectTracks[edit.trackIndex].durationHint = edit.editedDuration
        }

        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        reloadPlaybackFromProjectTracks(
            preserveProgress: true,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()
        let scopeSuffix = trackEdits.count > 1 ? " across \(trackEdits.count) tracks" : ""
        updateStatus("split at \(formatClockTime(Double(projectProgress) * displayedDuration))\(scopeSuffix)")
    }

    private func insertSilenceOrTime() {
        let snapshot = playbackController.snapshot()
        let projectDuration = projectSelectionDuration
        guard projectDuration > 0 else {
            updateStatus("load audio before inserting time")
            return
        }

        let anchorTrackIndex: Int
        let insertionProjectProgress: Float
        let insertedDuration: TimeInterval
        if
            let target = currentEditableSelectionTarget(),
            projectTracks.indices.contains(target.trackIndex)
        {
            anchorTrackIndex = target.trackIndex
            insertionProjectProgress = target.displaySelection.startProgressFloat
            insertedDuration = max(target.displaySelection.duration(in: projectDuration), 0)
        } else if
            let activeTrackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(activeTrackIndex)
        {
            anchorTrackIndex = activeTrackIndex
            insertionProjectProgress = min(max(snapshot.progress, 0), 1)
            insertedDuration = 1
        } else {
            updateStatus("select a track to insert time")
            return
        }

        guard insertedDuration > 0 else {
            updateStatus("select time to insert")
            return
        }

        let scopedTrackIndices = scopedTrackIndices(anchorTrackIndex: anchorTrackIndex, scope: editScope)
        let undoSnapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: insertionProjectProgress
        )

        var editedTrackCount = 0
        var materializationEdits: [(trackID: UUID, timeline: AudioEditTimeline, editRevision: Int)] = []
        for trackIndex in scopedTrackIndices where projectTracks.indices.contains(trackIndex) {
            let track = projectTracks[trackIndex]
            let trackDuration = trackDuration(for: track)
            guard trackDuration > 0 else {
                continue
            }

            let insertionTime = Double(insertionProjectProgress) * projectDuration
            let localProgress = min(max(insertionTime / trackDuration, 0), 1)
            let insertedFrameCount: Int
            let editedAudioTimeline: AudioEditTimeline?
            let editedFileTimeline: AudioFileEditTimeline?
            let editedDuration: TimeInterval

            if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
                var timeline = currentFileTimeline
                let frameCount = max(Int((insertedDuration * timeline.sourceSampleRate).rounded()), 1)
                insertedFrameCount = timeline.insertSilence(frameCount: frameCount, atProgress: localProgress)
                editedAudioTimeline = nil
                editedFileTimeline = timeline
                editedDuration = timeline.duration
            } else if let currentTimeline = projectTracks[trackIndex].audioTimeline {
                var timeline = currentTimeline
                let frameCount = max(Int((insertedDuration * timeline.sourceAudioBuffer.sampleRate).rounded()), 1)
                insertedFrameCount = timeline.insertSilence(frameCount: frameCount, atProgress: localProgress)
                editedAudioTimeline = timeline
                editedFileTimeline = nil
                editedDuration = timeline.duration
            } else {
                continue
            }

            guard insertedFrameCount > 0 else {
                continue
            }

            if editedTrackCount == 0 {
                editUndoStack.append(.projectTracks(undoSnapshot))
            }
            editedTrackCount += 1
            let trackID = projectTracks[trackIndex].id
            cancelEditMaterialization(for: trackID)
            projectTracks[trackIndex].editRevision += 1
            let editRevision = projectTracks[trackIndex].editRevision
            projectTracks[trackIndex].audioTimeline = editedAudioTimeline
            projectTracks[trackIndex].fileTimeline = editedFileTimeline
            projectTracks[trackIndex].decodedAudioBuffer = editedAudioTimeline?.sourceAudioBuffer
            projectTracks[trackIndex].durationHint = editedDuration

            let currentOverview = projectTracks[trackIndex].waveformOverview
            if let editedFileTimeline {
                projectTracks[trackIndex].waveformOverview =
                    optimisticWaveformOverview(
                        for: editedFileTimeline,
                        sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                        fallbackOverview: currentOverview
                    )
                scheduleFileTimelineWaveformRefinement(
                    trackID: trackID,
                    fileTimeline: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                    editRevision: editRevision,
                    delay: editMaterializationDelay
                )
            } else if let currentOverview {
                projectTracks[trackIndex].waveformOverview = WaveformOverview(
                    duration: editedDuration,
                    bins: currentOverview.bins
                )
            }

            if let editedAudioTimeline {
                materializationEdits.append((trackID, editedAudioTimeline, editRevision))
            }
        }

        guard editedTrackCount > 0 else {
            updateStatus("could not insert time")
            return
        }

        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(
            preserveProgress: true,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()

        let scopeSuffix = editedTrackCount > 1 ? " across \(editedTrackCount) tracks" : ""
        let status = "inserted \(formatDuration(insertedDuration)) silence\(scopeSuffix)"
        updateStatus(status)
        for edit in materializationEdits {
            materializeEditedTimeline(
                trackID: edit.trackID,
                timeline: edit.timeline,
                editRevision: edit.editRevision,
                status: status,
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay,
                animateWaveformTransition: false
            )
        }
    }

    private func healAdjacentClips() {
        guard
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            updateStatus("select a track to heal")
            return
        }

        let projectDuration = projectSelectionDuration
        let track = projectTracks[trackIndex]
        let trackDuration = trackDuration(for: track)
        guard projectDuration > 0, trackDuration > 0 else {
            updateStatus("cannot heal clips without audio")
            return
        }

        let projectProgress = selectedTimelineRange?.startProgressFloat ?? playbackController.snapshot().progress
        let projectTime = Double(min(max(projectProgress, 0), 1)) * projectDuration
        let localProgress = min(max(projectTime / trackDuration, 0), 1)

        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
        let editedDuration: TimeInterval
        if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            guard timeline.healNearestClipBoundary(atProgress: localProgress) else {
                updateStatus("no clip boundary to heal")
                return
            }
            editedAudioTimeline = nil
            editedFileTimeline = timeline
            editedDuration = timeline.duration
        } else if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            var timeline = currentTimeline
            guard timeline.healNearestClipBoundary(atProgress: localProgress) else {
                updateStatus("no clip boundary to heal")
                return
            }
            editedAudioTimeline = timeline
            editedFileTimeline = nil
            editedDuration = timeline.duration
        } else {
            updateStatus("track is not ready to heal")
            return
        }

        let undoSnapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: projectProgress
        )
        editUndoStack.append(.projectTracks(undoSnapshot))

        let trackID = projectTracks[trackIndex].id
        cancelEditMaterialization(for: trackID)
        projectTracks[trackIndex].editRevision += 1
        let editRevision = projectTracks[trackIndex].editRevision
        projectTracks[trackIndex].audioTimeline = editedAudioTimeline
        projectTracks[trackIndex].fileTimeline = editedFileTimeline
        projectTracks[trackIndex].decodedAudioBuffer = editedAudioTimeline?.sourceAudioBuffer
        projectTracks[trackIndex].durationHint = editedDuration

        let currentOverview = projectTracks[trackIndex].waveformOverview
        if let editedFileTimeline {
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    for: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trackID,
                fileTimeline: editedFileTimeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision,
                delay: editMaterializationDelay
            )
        } else if let currentOverview {
            projectTracks[trackIndex].waveformOverview = WaveformOverview(
                duration: editedDuration,
                bins: currentOverview.bins
            )
        }

        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        reloadPlaybackFromProjectTracks(
            preserveProgress: true,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()
        updateStatus("healed adjacent clips")

        if let editedAudioTimeline {
            materializeEditedTimeline(
                trackID: trackID,
                timeline: editedAudioTimeline,
                editRevision: editRevision,
                status: "healed adjacent clips",
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay,
                animateWaveformTransition: false
            )
        }
    }

    private func slipClipContents(direction: Int) {
        guard
            direction != 0,
            let target = editableClipSlipTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            updateStatus("select a clip to slip")
            return
        }

        let trackIndex = target.trackIndex
        let trackID = projectTracks[trackIndex].id
        let currentOverview = projectTracks[trackIndex].waveformOverview
        let undoSnapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: playbackController.snapshot().progress
        )

        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
        let appliedFrameDelta: Int
        let appliedSampleRate: Double
        if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
            let requestedFrameDelta = Int((currentFileTimeline.sourceSampleRate * 0.05).rounded()) * direction
            var timeline = currentFileTimeline
            appliedFrameDelta = timeline.slipClip(
                AudioFileEditTimeline.ClipRange(
                    startProgress: target.editSelection.startProgress,
                    endProgress: target.editSelection.endProgress
                ),
                byFrameCount: requestedFrameDelta
            )
            guard appliedFrameDelta != 0 else {
                updateStatus("clip is at source edge")
                return
            }
            appliedSampleRate = currentFileTimeline.sourceSampleRate
            editedAudioTimeline = nil
            editedFileTimeline = timeline
        } else if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            let requestedFrameDelta = Int((currentTimeline.sourceAudioBuffer.sampleRate * 0.05).rounded()) * direction
            var timeline = currentTimeline
            appliedFrameDelta = timeline.slipClip(
                AudioEditTimeline.ClipRange(
                    startProgress: target.editSelection.startProgress,
                    endProgress: target.editSelection.endProgress
                ),
                byFrameCount: requestedFrameDelta
            )
            guard appliedFrameDelta != 0 else {
                updateStatus("clip is at source edge")
                return
            }
            appliedSampleRate = currentTimeline.sourceAudioBuffer.sampleRate
            editedAudioTimeline = timeline
            editedFileTimeline = nil
        } else {
            updateStatus("track is not ready to slip")
            return
        }

        editUndoStack.append(.projectTracks(undoSnapshot))
        cancelEditMaterialization(for: trackID)
        projectTracks[trackIndex].editRevision += 1
        let editRevision = projectTracks[trackIndex].editRevision
        projectTracks[trackIndex].audioTimeline = editedAudioTimeline
        projectTracks[trackIndex].fileTimeline = editedFileTimeline
        projectTracks[trackIndex].decodedAudioBuffer = editedAudioTimeline?.sourceAudioBuffer
        projectTracks[trackIndex].durationHint = editedFileTimeline?.duration ?? editedAudioTimeline?.duration

        if let editedFileTimeline {
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    for: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trackID,
                fileTimeline: editedFileTimeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision
            )
        } else if let currentOverview {
            projectTracks[trackIndex].waveformOverview = WaveformOverview(
                duration: editedAudioTimeline?.duration ?? currentOverview.duration,
                bins: currentOverview.bins
            )
            cancelEditWaveformRefinement(for: trackID)
        }

        activeTrackID = trackID
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(
            preserveProgress: true,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()
        let slippedDuration = abs(Double(appliedFrameDelta)) / max(appliedSampleRate, 1)
        updateStatus("slipped clip \(direction < 0 ? "left" : "right") \(formatDuration(slippedDuration))")

        if let editedAudioTimeline {
            materializeEditedTimeline(
                trackID: trackID,
                timeline: editedAudioTimeline,
                editRevision: editRevision,
                status: "slipped clip \(formatDuration(slippedDuration))",
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay,
                animateWaveformTransition: false
            )
        }
    }

    private func nudgeSelection(direction: Int) {
        guard
            let selection = selectedTimelineRange,
            selection.durationProgress > 0
        else {
            updateStatus("select time to nudge")
            return
        }

        let projectDuration = projectSelectionDuration
        guard projectDuration > 0 else {
            updateStatus("load audio before nudging")
            return
        }

        let nudgeDuration: TimeInterval = 0.05
        let deltaProgress = Double(direction) * nudgeDuration / projectDuration
        let selectionDuration = selection.durationProgress
        let nextStart = min(max(selection.startProgress + deltaProgress, 0), max(1 - selectionDuration, 0))
        let nudgedSelection = TimelineSelection(
            startProgress: nextStart,
            endProgress: nextStart + selectionDuration,
            trackID: selection.trackID
        )
        selectedTimelineRange = nudgedSelection
        timelineSurface.displaySelection(nudgedSelection)
        updateEffectCommandState()
        updateStatus("nudged selection \(direction < 0 ? "left" : "right") \(formatDuration(nudgeDuration))")
    }

    private func snapSelectionToPlayheadEdgesOrSilence() {
        if let candidate = activeDeadAirCandidate() {
            selectedTimelineRange = candidate.displaySelection
            activeTrackID = candidate.trackID
            timelineSurface.displaySelection(candidate.displaySelection)
            timelineSurface.focusSelection(candidate.displaySelection)
            updateEffectCommandState()
            updateStatus("snapped selection to silence candidate")
            return
        }

        guard
            let selection = selectedTimelineRange,
            selection.durationProgress > 0
        else {
            updateStatus("select time to snap")
            return
        }

        let projectDuration = projectSelectionDuration
        guard projectDuration > 0 else {
            updateStatus("load audio before snapping")
            return
        }

        var snappedSelection: TimelineSelection?
        if
            let trackIndex = trackIndex(for: selection),
            projectTracks.indices.contains(trackIndex)
        {
            let track = projectTracks[trackIndex]
            let trackDuration = trackDuration(for: track)
            if trackDuration > 0 {
                let trackDurationProgress = trackDuration / projectDuration
                let boundaryProgresses = timelineClipRanges(for: track).flatMap { clipRange in
                    [
                        clipRange.startProgress * trackDurationProgress,
                        clipRange.endProgress * trackDurationProgress,
                    ]
                }
                if !boundaryProgresses.isEmpty {
                    let snappedStart = nearestProgress(to: selection.startProgress, in: boundaryProgresses)
                    let snappedEnd = nearestProgress(to: selection.endProgress, in: boundaryProgresses)
                    if snappedEnd > snappedStart {
                        snappedSelection = TimelineSelection(
                            startProgress: snappedStart,
                            endProgress: snappedEnd,
                            trackID: track.id
                        )
                    }
                }
            }
        }

        if snappedSelection == nil {
            let playheadProgress = Double(min(max(playbackController.snapshot().progress, 0), 1))
            let startDistance = abs(selection.startProgress - playheadProgress)
            let endDistance = abs(selection.endProgress - playheadProgress)
            snappedSelection = startDistance <= endDistance ?
                TimelineSelection(
                    startProgress: playheadProgress,
                    endProgress: selection.endProgress,
                    trackID: selection.trackID
                ) :
                TimelineSelection(
                    startProgress: selection.startProgress,
                    endProgress: playheadProgress,
                    trackID: selection.trackID
                )
        }

        guard let snappedSelection, snappedSelection.durationProgress > 0 else {
            updateStatus("no snap target found")
            return
        }

        selectedTimelineRange = snappedSelection
        timelineSurface.displaySelection(snappedSelection)
        timelineSurface.focusSelection(snappedSelection)
        updateEffectCommandState()
        updateStatus("snapped selection")
    }

    private func nearestProgress(to progress: Double, in candidates: [Double]) -> Double {
        candidates.min { lhs, rhs in
            abs(lhs - progress) < abs(rhs - progress)
        } ?? progress
    }

    private func selectTimeAcrossLinkedTracks() {
        guard
            let selection = selectedTimelineRange,
            selection.durationProgress > 0,
            let trackIndex = trackIndex(for: selection),
            projectTracks.indices.contains(trackIndex)
        else {
            updateStatus("select time on a linked track")
            return
        }

        guard let editGroupID = projectTracks[trackIndex].editGroupID else {
            updateStatus("track has no linked edit group")
            return
        }

        let linkedTrackIDs = Set(projectTracks.filter { $0.editGroupID == editGroupID }.map(\.id))
        guard !linkedTrackIDs.isEmpty else {
            updateStatus("no linked tracks found")
            return
        }

        selectedTrackID = projectTracks[trackIndex].id
        selectedTrackIDs = linkedTrackIDs
        activeTrackID = projectTracks[trackIndex].id
        editScope = .group
        publishSelectedTracksToTimeline()
        refreshTrackControls()
        updateEditScopeHint()
        updateEffectCommandState()
        updateStatus("selected time across \(linkedTrackIDs.count) linked \(linkedTrackIDs.count == 1 ? "track" : "tracks")")
    }

    private func selectAllClipsOnTrack() {
        guard
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            updateStatus("select a track")
            return
        }

        let trackID = projectTracks[trackIndex].id
        let selection = fullTrackDisplaySelection(for: trackID)
        selectedTimelineRange = selection
        activeTrackID = trackID
        selectedTrackID = nil
        selectedTrackIDs.removeAll()
        publishSelectedTracksToTimeline()
        refreshTrackControls()
        timelineSurface.displaySelection(selection)
        timelineSurface.focusSelection(selection)
        updateEffectCommandState()
        updateStatus("selected all clips on track")
    }

    private func silenceCleanupTarget() -> EditableSelectionTarget? {
        if let target = currentEditableSelectionTarget() {
            return target
        }

        guard
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            return nil
        }

        let trackID = projectTracks[trackIndex].id
        return EditableSelectionTarget(
            trackIndex: trackIndex,
            displaySelection: fullTrackDisplaySelection(for: trackID),
            editSelection: fullTrackEditSelection(for: trackID)
        )
    }

    private func reviewDeadAir() {
        guard
            let target = silenceCleanupTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            updateStatus("select a track to review")
            return
        }

        let trackIndex = target.trackIndex
        let track = projectTracks[trackIndex]
        let sourceURL = track.sourceURL
        let trackID = track.id
        let editRevision = track.editRevision
        let audioTimeline = track.audioTimeline
        let fileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex)
        let displaySelection = target.displaySelection
        let editSelection = target.editSelection
        let configuration = AudioSilenceAnalyzer.Configuration.podcastCleanup

        clearDeadAirReview(publish: true)
        updateStatus("reviewing shorten silence")
        Task { [weak self, sourceURL, audioTimeline, fileTimeline, displaySelection, editSelection, trackID, editRevision, configuration] in
            let result = await Task.detached(priority: .userInitiated) {
                try Self.detectDeadAirReviewCandidates(
                    sourceURL: sourceURL,
                    audioTimeline: audioTimeline,
                    fileTimeline: fileTimeline,
                    displaySelection: displaySelection,
                    editSelection: editSelection,
                    trackID: trackID,
                    trackEditRevision: editRevision,
                    configuration: configuration
                )
            }.result

            guard let self else {
                return
            }

            switch result {
            case let .success(reviewResult):
                self.publishDeadAirReviewResult(
                    reviewResult,
                    trackID: trackID,
                    expectedEditRevision: editRevision
                )
            case let .failure(error):
                self.updateStatus("shorten silence review failed: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func detectDeadAirReviewCandidates(
        sourceURL: URL,
        audioTimeline: AudioEditTimeline?,
        fileTimeline: AudioFileEditTimeline?,
        displaySelection: TimelineSelection,
        editSelection: TimelineSelection,
        trackID: UUID,
        trackEditRevision: Int,
        configuration: AudioSilenceAnalyzer.Configuration
    ) throws -> DeadAirReviewResult {
        let renderedBuffer: DecodedAudioBuffer
        let timelineFrameCount: Int

        if let fileTimeline {
            let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
            renderedBuffer = fileTimeline.audioTimeline(sourceBuffer: sourceBuffer).render(selection: editSelection)
            timelineFrameCount = fileTimeline.frameCount
        } else if let audioTimeline {
            renderedBuffer = audioTimeline.render(selection: editSelection)
            timelineFrameCount = audioTimeline.frameCount
        } else {
            let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
            let timeline = AudioEditTimeline(sourceBuffer: sourceBuffer)
            renderedBuffer = timeline.render(selection: editSelection)
            timelineFrameCount = timeline.frameCount
        }

        guard timelineFrameCount > 0, renderedBuffer.frameCount > 0 else {
            return DeadAirReviewResult(candidates: [], detectedRegionCount: 0)
        }

        let detectedRegions = AudioSilenceAnalyzer.detectSilence(
            in: renderedBuffer,
            configuration: configuration
        )
        let localDeletionRanges = AudioSilenceAnalyzer.deletionRanges(
            for: detectedRegions,
            sampleRate: renderedBuffer.sampleRate,
            configuration: configuration
        )
        let selectionStartFrame = min(
            max(Int((editSelection.startProgress * Double(timelineFrameCount)).rounded(.down)), 0),
            timelineFrameCount
        )
        let renderedFrameCount = max(renderedBuffer.frameCount, 1)
        let timelineFrameCountDouble = Double(timelineFrameCount)

        let candidates = localDeletionRanges.compactMap { localRange -> DeadAirReviewCandidate? in
            let lowerBound = min(max(selectionStartFrame + localRange.lowerBound, 0), timelineFrameCount)
            let upperBound = min(max(selectionStartFrame + localRange.upperBound, lowerBound), timelineFrameCount)
            guard lowerBound < upperBound else {
                return nil
            }

            let localStartFraction = min(max(Double(localRange.lowerBound) / Double(renderedFrameCount), 0), 1)
            let localEndFraction = min(max(Double(localRange.upperBound) / Double(renderedFrameCount), localStartFraction), 1)
            let displayStart = displaySelection.startProgress +
                displaySelection.durationProgress * localStartFraction
            let displayEnd = displaySelection.startProgress +
                displaySelection.durationProgress * localEndFraction
            let candidateDisplaySelection = TimelineSelection(
                startProgress: displayStart,
                endProgress: displayEnd,
                trackID: trackID
            )
            let candidateEditSelection = TimelineSelection(
                startProgress: Double(lowerBound) / timelineFrameCountDouble,
                endProgress: Double(upperBound) / timelineFrameCountDouble,
                trackID: trackID
            )
            guard candidateDisplaySelection.durationProgress > 0, candidateEditSelection.durationProgress > 0 else {
                return nil
            }

            let estimatedRemovedDuration = renderedBuffer.sampleRate > 0 ?
                Double(localRange.count) / renderedBuffer.sampleRate :
                0
            let confidence = silenceReviewConfidence(
                estimatedRemovedDuration: estimatedRemovedDuration
            )
            let reason = silenceReviewReason(
                estimatedRemovedDuration: estimatedRemovedDuration
            )

            return DeadAirReviewCandidate(
                id: UUID(),
                trackID: trackID,
                trackEditRevision: trackEditRevision,
                displaySelection: candidateDisplaySelection,
                editSelection: candidateEditSelection,
                frameRange: lowerBound..<upperBound,
                confidence: confidence,
                reason: reason,
                estimatedRemovedDuration: estimatedRemovedDuration
            )
        }

        return DeadAirReviewResult(
            candidates: candidates,
            detectedRegionCount: detectedRegions.count
        )
    }

    private nonisolated static func silenceReviewConfidence(
        estimatedRemovedDuration: TimeInterval
    ) -> Float {
        guard estimatedRemovedDuration.isFinite, estimatedRemovedDuration > 0 else {
            return 0
        }

        let durationScore = min(max((estimatedRemovedDuration - 0.18) / 1.2, 0), 1)
        return Float(min(0.98, 0.72 + durationScore * 0.26))
    }

    private nonisolated static func silenceReviewReason(
        estimatedRemovedDuration: TimeInterval
    ) -> String {
        if estimatedRemovedDuration >= 1.0 {
            return "long continuous silence"
        }
        if estimatedRemovedDuration >= 0.45 {
            return "clear pause"
        }
        return "short pause"
    }

    private func deadAirCandidateStatusText(
        _ candidate: DeadAirReviewCandidate,
        index: Int,
        total: Int
    ) -> String {
        let duration = formatDuration(candidate.estimatedRemovedDuration)
        let confidence = Int((candidate.confidence * 100).rounded())
        return "silence \(index + 1)/\(total): \(duration), \(confidence)% confidence, \(candidate.reason)"
    }

    private func currentSilenceReviewState() -> SoundtimeProject.SilenceReviewState? {
        guard !deadAirCandidates.isEmpty else {
            return nil
        }

        return SoundtimeProject.SilenceReviewState(
            candidates: deadAirCandidates.map { candidate in
                SoundtimeProject.SilenceReviewCandidate(
                    id: candidate.id,
                    trackID: candidate.trackID,
                    trackEditRevision: candidate.trackEditRevision,
                    displaySelection: projectSelectionRange(candidate.displaySelection),
                    editSelection: projectSelectionRange(candidate.editSelection),
                    frameStart: candidate.frameRange.lowerBound,
                    frameEnd: candidate.frameRange.upperBound,
                    confidence: candidate.confidence,
                    reason: candidate.reason,
                    estimatedRemovedDuration: candidate.estimatedRemovedDuration
                )
            },
            activeCandidateID: activeDeadAirCandidateID
        )
    }

    private func restoreSilenceReviewState(_ state: SoundtimeProject.SilenceReviewState?) {
        guard let state, !state.candidates.isEmpty else {
            clearDeadAirReview(publish: true)
            return
        }

        let restoredCandidates = state.candidates.compactMap { candidate -> DeadAirReviewCandidate? in
            guard
                let track = projectTracks.first(where: { $0.id == candidate.trackID }),
                track.editRevision == candidate.trackEditRevision,
                candidate.frameEnd > candidate.frameStart
            else {
                return nil
            }

            let displaySelection = timelineSelection(from: candidate.displaySelection)
            let editSelection = timelineSelection(from: candidate.editSelection)
            guard displaySelection.durationProgress > 0, editSelection.durationProgress > 0 else {
                return nil
            }

            return DeadAirReviewCandidate(
                id: candidate.id,
                trackID: candidate.trackID,
                trackEditRevision: candidate.trackEditRevision,
                displaySelection: displaySelection,
                editSelection: editSelection,
                frameRange: candidate.frameStart..<candidate.frameEnd,
                confidence: candidate.confidence,
                reason: candidate.reason,
                estimatedRemovedDuration: candidate.estimatedRemovedDuration
            )
        }

        guard !restoredCandidates.isEmpty else {
            clearDeadAirReview(publish: true)
            return
        }

        deadAirCandidates = restoredCandidates
        activeDeadAirCandidateID = state.activeCandidateID.flatMap { activeID in
            restoredCandidates.contains { $0.id == activeID } ? activeID : nil
        } ?? restoredCandidates.first?.id
        publishDeadAirCandidateRegions()
        updateEffectCommandState()
    }

    private func projectSelectionRange(
        _ selection: TimelineSelection
    ) -> SoundtimeProject.TimelineSelectionRange {
        SoundtimeProject.TimelineSelectionRange(
            startProgress: selection.startProgress,
            endProgress: selection.endProgress,
            trackID: selection.trackID
        )
    }

    private func timelineSelection(
        from range: SoundtimeProject.TimelineSelectionRange
    ) -> TimelineSelection {
        TimelineSelection(
            startProgress: range.startProgress,
            endProgress: range.endProgress,
            trackID: range.trackID
        )
    }

    private func publishDeadAirReviewResult(
        _ result: DeadAirReviewResult,
        trackID: UUID,
        expectedEditRevision: Int
    ) {
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            projectTracks[trackIndex].editRevision == expectedEditRevision
        else {
            updateStatus("shorten silence review skipped: track changed")
            return
        }

        guard !result.candidates.isEmpty else {
            clearDeadAirReview(publish: true)
            updateStatus("no removable silence found")
            return
        }

        deadAirCandidates = result.candidates
        activeDeadAirCandidateID = result.candidates.first?.id
        publishDeadAirCandidateRegions()
        updateEffectCommandState()
        let candidateWord = result.candidates.count == 1 ? "candidate" : "candidates"
        let totalRemovedDuration = result.candidates.reduce(0) { total, candidate in
            total + candidate.estimatedRemovedDuration
        }
        let totalDuration = formatDuration(totalRemovedDuration)
        if let firstCandidate = result.candidates.first {
            updateStatus(
                "found \(result.candidates.count) silence \(candidateWord), " +
                    "\(totalDuration) removable - " +
                    deadAirCandidateStatusText(firstCandidate, index: 0, total: result.candidates.count)
            )
        } else {
            updateStatus("found \(result.candidates.count) silence \(candidateWord), \(totalDuration) removable")
        }
    }

    private func activeDeadAirCandidate() -> DeadAirReviewCandidate? {
        guard let activeDeadAirCandidateID else {
            return deadAirCandidates.first
        }
        return deadAirCandidates.first { $0.id == activeDeadAirCandidateID } ?? deadAirCandidates.first
    }

    private func stepActiveDeadAirCandidate(by offset: Int) {
        guard !deadAirCandidates.isEmpty else {
            updateStatus("no silence candidates")
            return
        }

        let currentIndex = activeDeadAirCandidateID.flatMap { activeID in
            deadAirCandidates.firstIndex { $0.id == activeID }
        } ?? 0
        let candidateCount = deadAirCandidates.count
        let nextIndex = (currentIndex + offset + candidateCount) % candidateCount
        let candidate = deadAirCandidates[nextIndex]
        activeDeadAirCandidateID = candidate.id
        publishDeadAirCandidateRegions()
        timelineSurface.focusSelection(candidate.displaySelection)
        updateEffectCommandState()
        updateStatus(deadAirCandidateStatusText(candidate, index: nextIndex, total: candidateCount))
    }

    private func publishDeadAirCandidateRegions() {
        let activeID = activeDeadAirCandidate()?.id
        let regions = deadAirCandidates.map { candidate in
            TimelineRenderState.CandidateRegion(
                id: candidate.id,
                selection: candidate.displaySelection,
                isActive: candidate.id == activeID
            )
        }
        timelineSurface.displayCandidateRegions(regions)
    }

    private func clearDeadAirReview(publish: Bool) {
        deadAirAuditionStopTask?.cancel()
        deadAirAuditionStopTask = nil
        deadAirCandidates.removeAll()
        activeDeadAirCandidateID = nil
        if publish {
            timelineSurface.displayCandidateRegions([])
        }
        updateEffectCommandState()
    }

    private func acceptActiveDeadAirCandidate() {
        guard let candidate = activeDeadAirCandidate() else {
            updateStatus("no silence candidate to accept")
            return
        }
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == candidate.trackID }),
            projectTracks[trackIndex].editRevision == candidate.trackEditRevision
        else {
            clearDeadAirReview(publish: true)
            updateStatus("silence candidate expired; review again")
            return
        }

        let target = EditableSelectionTarget(
            trackIndex: trackIndex,
            displaySelection: candidate.displaySelection,
            editSelection: candidate.editSelection
        )
        clearDeadAirReview(publish: true)
        performOptimisticDelete(
            target: target,
            copyBeforeDeleting: false,
            scope: .track
        )
    }

    private func acceptHighConfidenceDeadAirCandidates() {
        let eligibleCandidates = deadAirCandidates.filter {
            $0.confidence >= highConfidenceSilenceThreshold
        }
        guard !eligibleCandidates.isEmpty else {
            updateStatus("no high-confidence silence candidates")
            return
        }

        guard let firstCandidate = eligibleCandidates.first else {
            updateStatus("no high-confidence silence candidates")
            return
        }
        guard eligibleCandidates.allSatisfy({ $0.trackID == firstCandidate.trackID }) else {
            updateStatus("high-confidence candidates span tracks; review individually")
            return
        }
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == firstCandidate.trackID }),
            projectTracks[trackIndex].editRevision == firstCandidate.trackEditRevision
        else {
            clearDeadAirReview(publish: true)
            updateStatus("silence candidates expired; review again")
            return
        }

        let frameRanges = eligibleCandidates.map(\.frameRange)
        let deletedFrameCount = frameRanges.reduce(0) { total, frameRange in
            total + frameRange.count
        }
        let deletedDuration = eligibleCandidates.reduce(0) { total, candidate in
            total + candidate.estimatedRemovedDuration
        }
        let cleanupResult = SilenceCleanupResult(
            frameRanges: frameRanges,
            detectedRegionCount: eligibleCandidates.count,
            deletedFrameCount: deletedFrameCount,
            deletedDuration: deletedDuration
        )

        clearDeadAirReview(publish: true)
        applySilenceCleanupResult(
            cleanupResult,
            trackID: firstCandidate.trackID,
            expectedEditRevision: firstCandidate.trackEditRevision
        )
    }

    private func rejectActiveDeadAirCandidate() {
        guard let candidate = activeDeadAirCandidate(),
              let candidateIndex = deadAirCandidates.firstIndex(where: { $0.id == candidate.id })
        else {
            updateStatus("no silence candidate to reject")
            return
        }

        deadAirCandidates.remove(at: candidateIndex)
        activeDeadAirCandidateID = deadAirCandidates.indices.contains(candidateIndex) ?
            deadAirCandidates[candidateIndex].id :
            deadAirCandidates.first?.id
        if deadAirCandidates.isEmpty {
            clearDeadAirReview(publish: true)
            updateStatus("shorten silence review complete")
        } else {
            publishDeadAirCandidateRegions()
            updateEffectCommandState()
            updateStatus("rejected silence candidate")
        }
    }

    private func auditionActiveDeadAirCandidate() {
        guard let candidate = activeDeadAirCandidate() else {
            updateStatus("no silence candidate to audition")
            return
        }
        guard playbackController.hasSource else {
            updateStatus("load audio before auditioning")
            return
        }

        let projectDuration = projectSelectionDuration
        guard projectDuration > 0 else {
            updateStatus("cannot audition without project duration")
            return
        }

        let preRoll: TimeInterval = 1.25
        let postRoll: TimeInterval = 1.25
        let startTime = max(TimeInterval(candidate.displayStartProgress) * projectDuration - preRoll, 0)
        let endTime = min(TimeInterval(candidate.displayEndProgress) * projectDuration + postRoll, projectDuration)
        let startProgress = Float(startTime / projectDuration)
        let auditionDuration = max(endTime - startTime, 0.1)

        do {
            try playbackController.seek(toProgress: startProgress)
            if !playbackController.isPlaying {
                try playbackController.play()
            }
            refreshPlaybackProgress(syncPlayheadWhenPlaying: true)
            startPlaybackTimer()
            updateStatus("auditioning silence candidate")
        } catch {
            stopPlaybackTimer()
            updateStatus("audition failed: \(error.localizedDescription)")
            return
        }

        deadAirAuditionStopTask?.cancel()
        deadAirAuditionStopTask = Task { [weak self, candidateID = candidate.id, auditionDuration] in
            try? await Task.sleep(nanoseconds: UInt64(auditionDuration * 1_000_000_000))
            await MainActor.run { [weak self] in
                guard
                    let self,
                    self.activeDeadAirCandidateID == candidateID,
                    self.playbackController.isPlaying
                else {
                    return
                }
                self.playbackController.pause()
                self.refreshPlaybackProgress(syncPlayheadWhenPlaying: false)
                self.stopPlaybackTimer()
                self.updateStatus("auditioned silence candidate")
            }
        }
    }

    private func deleteDetectedSilence() {
        guard
            let target = silenceCleanupTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            updateStatus("select a track to clean")
            return
        }

        let trackIndex = target.trackIndex
        let track = projectTracks[trackIndex]
        let sourceURL = track.sourceURL
        let trackID = track.id
        let editRevision = track.editRevision
        let audioTimeline = track.audioTimeline
        let fileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex)
        let editSelection = target.editSelection
        let configuration = AudioSilenceAnalyzer.Configuration.podcastCleanup

        updateStatus("detecting silence")
        Task { [weak self, sourceURL, audioTimeline, fileTimeline, editSelection, trackID, editRevision, configuration] in
            let result = await Task.detached(priority: .userInitiated) {
                try Self.detectSilenceCleanupRanges(
                    sourceURL: sourceURL,
                    audioTimeline: audioTimeline,
                    fileTimeline: fileTimeline,
                    editSelection: editSelection,
                    configuration: configuration
                )
            }.result

            guard let self else {
                return
            }

            switch result {
            case let .success(cleanupResult):
                self.applySilenceCleanupResult(
                    cleanupResult,
                    trackID: trackID,
                    expectedEditRevision: editRevision
                )
            case let .failure(error):
                self.updateStatus("silence cleanup failed: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func detectSilenceCleanupRanges(
        sourceURL: URL,
        audioTimeline: AudioEditTimeline?,
        fileTimeline: AudioFileEditTimeline?,
        editSelection: TimelineSelection,
        configuration: AudioSilenceAnalyzer.Configuration
    ) throws -> SilenceCleanupResult {
        let renderedBuffer: DecodedAudioBuffer
        let timelineFrameCount: Int
        let timelineSampleRate: Double

        if let fileTimeline {
            let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
            renderedBuffer = fileTimeline.audioTimeline(sourceBuffer: sourceBuffer).render(selection: editSelection)
            timelineFrameCount = fileTimeline.frameCount
            timelineSampleRate = fileTimeline.sourceSampleRate
        } else if let audioTimeline {
            renderedBuffer = audioTimeline.render(selection: editSelection)
            timelineFrameCount = audioTimeline.frameCount
            timelineSampleRate = audioTimeline.sourceAudioBuffer.sampleRate
        } else {
            let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
            let timeline = AudioEditTimeline(sourceBuffer: sourceBuffer)
            renderedBuffer = timeline.render(selection: editSelection)
            timelineFrameCount = timeline.frameCount
            timelineSampleRate = sourceBuffer.sampleRate
        }

        let detectedRegions = AudioSilenceAnalyzer.detectSilence(
            in: renderedBuffer,
            configuration: configuration
        )
        let localDeletionRanges = AudioSilenceAnalyzer.deletionRanges(
            for: detectedRegions,
            sampleRate: renderedBuffer.sampleRate,
            configuration: configuration
        )
        let selectionStartFrame = min(
            max(Int((editSelection.startProgress * Double(timelineFrameCount)).rounded(.down)), 0),
            timelineFrameCount
        )
        let frameRanges = localDeletionRanges.compactMap { localRange -> Range<Int>? in
            let lowerBound = min(max(selectionStartFrame + localRange.lowerBound, 0), timelineFrameCount)
            let upperBound = min(max(selectionStartFrame + localRange.upperBound, lowerBound), timelineFrameCount)
            guard lowerBound < upperBound else {
                return nil
            }
            return lowerBound..<upperBound
        }
        let deletedFrameCount = frameRanges.reduce(0) { total, range in
            total + range.count
        }
        let deletedDuration = timelineSampleRate > 0 ?
            Double(deletedFrameCount) / timelineSampleRate :
            0

        return SilenceCleanupResult(
            frameRanges: frameRanges,
            detectedRegionCount: detectedRegions.count,
            deletedFrameCount: deletedFrameCount,
            deletedDuration: deletedDuration
        )
    }

    private func applySilenceCleanupResult(
        _ result: SilenceCleanupResult,
        trackID: UUID,
        expectedEditRevision: Int
    ) {
        guard !result.frameRanges.isEmpty, result.deletedFrameCount > 0 else {
            updateStatus("no removable silence found")
            return
        }
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            projectTracks[trackIndex].editRevision == expectedEditRevision
        else {
            updateStatus("silence cleanup skipped: track changed")
            return
        }

        let snapshot = playbackController.snapshot()
        let undoSnapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: snapshot.progress
        )

        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
        let editedDuration: TimeInterval
        var removedFrameCount = 0

        if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            for frameRange in result.frameRanges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
                removedFrameCount += timeline.delete(frameRange: frameRange)
            }
            editedAudioTimeline = nil
            editedFileTimeline = timeline
            editedDuration = timeline.duration
        } else if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            var timeline = currentTimeline
            for frameRange in result.frameRanges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
                removedFrameCount += timeline.delete(frameRange: frameRange)
            }
            editedAudioTimeline = timeline
            editedFileTimeline = nil
            editedDuration = timeline.duration
        } else {
            updateStatus("track is not ready to clean")
            return
        }

        guard removedFrameCount > 0 else {
            updateStatus("no removable silence found")
            return
        }

        editUndoStack.append(.projectTracks(undoSnapshot))
        cancelEditMaterialization(for: trackID)
        projectTracks[trackIndex].editRevision += 1
        let editRevision = projectTracks[trackIndex].editRevision
        projectTracks[trackIndex].audioTimeline = editedAudioTimeline
        projectTracks[trackIndex].fileTimeline = editedFileTimeline
        projectTracks[trackIndex].decodedAudioBuffer = editedAudioTimeline?.sourceAudioBuffer
        projectTracks[trackIndex].durationHint = editedDuration

        let currentOverview = projectTracks[trackIndex].waveformOverview
        if let editedFileTimeline {
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    for: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trackID,
                fileTimeline: editedFileTimeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision,
                delay: editMaterializationDelay
            )
        } else if let currentOverview {
            projectTracks[trackIndex].waveformOverview = WaveformOverview(
                duration: editedDuration,
                bins: currentOverview.bins
            )
        }

        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(
            preserveProgress: true,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()
        let statusDuration = formatDuration(Double(removedFrameCount) / max(projectTracks[trackIndex].fileTimeline?.sourceSampleRate ?? projectTracks[trackIndex].audioTimeline?.sourceAudioBuffer.sampleRate ?? 1, 1))
        updateStatus(
            "deleted \(statusDuration) silence in \(result.detectedRegionCount) " +
                "\(result.detectedRegionCount == 1 ? "gap" : "gaps")"
        )

        if let editedAudioTimeline {
            materializeEditedTimeline(
                trackID: trackID,
                timeline: editedAudioTimeline,
                editRevision: editRevision,
                status: "deleted silence",
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay,
                animateWaveformTransition: false
            )
        }
    }

    private func deleteSelectedTrack() {
        guard
            let primaryTrackID = selectedTrackID ?? selectedTrackIDs.first,
            projectTracks.contains(where: { $0.id == primaryTrackID })
        else {
            return
        }
        let trackIDsToDelete = selectedTrackIDs.isEmpty ? [primaryTrackID] : selectedTrackIDs
        let indexedTrackIDsToDelete = projectTracks.enumerated()
            .filter { trackIDsToDelete.contains($0.element.id) }
            .map { (index: $0.offset, id: $0.element.id, name: $0.element.name) }
        guard !indexedTrackIDsToDelete.isEmpty else {
            return
        }

        let snapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: primaryTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: nil
        )
        editUndoStack.append(.projectTracks(snapshot))

        let deletedTrackNames = indexedTrackIDsToDelete.map(\.name)
        for trackID in indexedTrackIDsToDelete.map(\.id) {
            cancelEditMaterialization(for: trackID)
        }
        for trackIndex in indexedTrackIDsToDelete.map(\.index).sorted(by: >) {
            projectTracks.remove(at: trackIndex)
        }
        if projectTracks.isEmpty {
            activeTrackID = nil
        } else {
            let fallbackIndex = min(indexedTrackIDsToDelete.map(\.index).min() ?? 0, projectTracks.count - 1)
            activeTrackID = projectTracks[fallbackIndex].id
        }
        self.selectedTrackID = nil
        selectedTrackIDs.removeAll()
        trackSelectionAnchorID = nil
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        publishSelectedTracksToTimeline()
        syncActiveTrackFields()
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        updateEffectCommandState()
        if deletedTrackNames.count == 1, let deletedTrackName = deletedTrackNames.first {
            updateStatus("deleted track \(deletedTrackName)")
        } else {
            updateStatus("deleted \(deletedTrackNames.count) tracks")
        }
    }

    private func cutSelection() {
        performOptimisticDelete(copyBeforeDeleting: true, scope: .track)
    }

    private func copySelection() {
        guard
            let target = currentEditableSelectionTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            return
        }

        let trackIndex = target.trackIndex
        let selectedTimelineRange = target.editSelection
        if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            updateStatus("copying selection")
            Task { [weak self, currentTimeline, selectedTimelineRange] in
                let clipboard = await Task.detached(priority: .userInitiated) {
                    let buffer = currentTimeline.render(selection: selectedTimelineRange)
                    return AudioClipboard(
                        buffer: buffer,
                        waveformOverview: WaveformOverviewBuilder.build(from: buffer)
                    )
                }.value

                guard let self else {
                    return
                }

                self.audioClipboard = clipboard
                self.updateStatus("copied \(self.formatDuration(clipboard.buffer?.duration ?? 0))")
            }
            return
        }

        let fileTimeline: AudioFileEditTimeline
        do {
            fileTimeline = try editableFileTimeline(forTrackAt: trackIndex)
        } catch {
            updateStatus("copy failed: \(error.localizedDescription)")
            return
        }

        let sourceURL = projectTracks[trackIndex].sourceURL
        let fileClip = fileTimeline.clip(for: selectedTimelineRange)
        let clipboardID = UUID()
        if let fileClip {
            let waveformOverview = selectedWaveformOverview(
                from: projectTracks[trackIndex].waveformOverview,
                selection: selectedTimelineRange
            ) ?? WaveformOverview(duration: fileClip.duration, bins: [])
            audioClipboard = AudioClipboard(
                id: clipboardID,
                buffer: nil,
                waveformOverview: waveformOverview,
                fileClipSourceURL: sourceURL,
                fileClip: fileClip
            )
            updateStatus("copied \(formatDuration(fileClip.duration))")
        } else {
            updateStatus("copying selection")
        }
        Task { [weak self, fileTimeline, selectedTimelineRange, sourceURL, fileClip, clipboardID] in
            let clipboard = await Task.detached(priority: .userInitiated) {
                let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
                let timeline = fileTimeline.audioTimeline(sourceBuffer: sourceBuffer)
                let buffer = timeline.render(selection: selectedTimelineRange)
                return AudioClipboard(
                    id: clipboardID,
                    buffer: buffer,
                    waveformOverview: WaveformOverviewBuilder.build(from: buffer),
                    fileClipSourceURL: fileClip == nil ? nil : sourceURL,
                    fileClip: fileClip
                )
            }.result

            guard let self else {
                return
            }

            switch clipboard {
            case let .success(clipboard):
                if
                    let currentClipboard = self.audioClipboard,
                    currentClipboard.id != clipboard.id
                {
                    return
                }
                self.audioClipboard = clipboard
                self.updateStatus("copied \(self.formatDuration(clipboard.buffer?.duration ?? 0))")
            case let .failure(error):
                self.updateStatus("copy failed: \(error.localizedDescription)")
            }
        }
    }

    private func editableFileTimeline(forTrackAt trackIndex: Int) throws -> AudioFileEditTimeline {
        if let fileTimeline = projectTracks[trackIndex].fileTimeline {
            return fileTimeline
        }

        return AudioFileEditTimeline(
            fileInfo: try WAVAudioDecoder.inspect(url: projectTracks[trackIndex].sourceURL)
        )
    }

    private func compatibleFileTimeline(
        from audioTimeline: AudioEditTimeline,
        sourceURL: URL
    ) -> AudioFileEditTimeline? {
        guard
            WAVAudioDecoder.canDecode(sourceURL),
            let fileInfo = try? WAVAudioDecoder.inspect(url: sourceURL),
            audioTimeline.sourceAudioBuffer.frameCount == fileInfo.frameCount,
            abs(audioTimeline.sourceAudioBuffer.sampleRate - fileInfo.sampleRate) < 0.001,
            let fileTimeline = AudioFileEditTimeline(
                sourceFrameCount: fileInfo.frameCount,
                sourceSampleRate: fileInfo.sampleRate,
                playbackSegments: audioTimeline.playbackSegments
            ),
            fileTimeline.isCompatible(with: fileInfo)
        else {
            return nil
        }

        return fileTimeline
    }

    private func preferredFileTimelineForEditing(trackIndex: Int) throws -> AudioFileEditTimeline? {
        guard projectTracks.indices.contains(trackIndex) else {
            return nil
        }

        if let fileTimeline = projectTracks[trackIndex].fileTimeline {
            return fileTimeline
        }

        if
            let audioTimeline = projectTracks[trackIndex].audioTimeline,
            let fileTimeline = compatibleFileTimeline(
                from: audioTimeline,
                sourceURL: projectTracks[trackIndex].sourceURL
            )
        {
            return fileTimeline
        }

        guard WAVAudioDecoder.canDecode(projectTracks[trackIndex].sourceURL) else {
            return nil
        }

        return try editableFileTimeline(forTrackAt: trackIndex)
    }

    private func waveformOverview(
        for fileTimeline: AudioFileEditTimeline,
        sourceOverview: WaveformOverview?,
        fallbackOverview: WaveformOverview?
    ) -> WaveformOverview? {
        guard let sourceOverview = sourceOverview ?? fallbackOverview else {
            return nil
        }

        return fileTimeline.waveformOverview(from: sourceOverview)
    }

    private func optimisticWaveformOverview(
        for fileTimeline: AudioFileEditTimeline,
        sourceOverview: WaveformOverview?,
        fallbackOverview: WaveformOverview?
    ) -> WaveformOverview? {
        guard let sourceOverview = sourceOverview ?? fallbackOverview else {
            return nil
        }

        return fileTimeline.waveformOverview(from: overviewForOptimisticEdit(sourceOverview))
    }

    private func pasteAudio() {
        guard
            let audioClipboard,
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            return
        }

        let currentTimeline = projectTracks[trackIndex].audioTimeline
        let currentFileTimeline: AudioFileEditTimeline?
        if currentTimeline == nil {
            do {
                currentFileTimeline = try editableFileTimeline(forTrackAt: trackIndex)
            } catch {
                updateStatus("paste failed: \(error.localizedDescription)")
                return
            }
        } else {
            currentFileTimeline = nil
        }

        let pasteSelection =
            selectedTimelineRange.flatMap { editSelection(from: $0, trackIndex: trackIndex) } ??
            currentEditableSelectionTarget()?.editSelection ??
            editInsertionSelection(
                forPlaybackProgress: playbackController.snapshot().progress,
                trackIndex: trackIndex
            )
        let currentOverview = projectTracks[trackIndex].waveformOverview
        let trackID = projectTracks[trackIndex].id
        let sourceURL = projectTracks[trackIndex].sourceURL
        if
            currentTimeline == nil,
            let currentFileTimeline,
            let fileClipSourceURL = audioClipboard.fileClipSourceURL,
            let fileClip = audioClipboard.fileClip,
            fileClipSourceURL.standardizedFileURL == sourceURL.standardizedFileURL,
            currentFileTimeline.isCompatible(with: fileClip)
        {
            var editedFileTimeline = currentFileTimeline
            guard let insertedFrameCount = editedFileTimeline.replace(pasteSelection, with: fileClip) else {
                updateStatus("paste failed: incompatible clipboard")
                return
            }

            let snapshot = ProjectTrackUndoSnapshot(
                tracks: projectTracks,
                activeTrackID: activeTrackID,
                selectedTrackID: selectedTrackID,
                selectedTrackIDs: selectedTrackIDs,
                selectedTimelineRange: selectedTimelineRange,
                restoreProgress: nil
            )
            editUndoStack.append(.projectTracks(snapshot))
            cancelEditMaterialization(for: trackID)
            projectTracks[trackIndex].editRevision += 1
            let editRevision = projectTracks[trackIndex].editRevision

            projectTracks[trackIndex].audioTimeline = nil
            projectTracks[trackIndex].fileTimeline = editedFileTimeline
            projectTracks[trackIndex].decodedAudioBuffer = nil
            projectTracks[trackIndex].durationHint = editedFileTimeline.duration
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    currentOverview,
                    replacing: pasteSelection,
                    with: audioClipboard.waveformOverview,
                    targetDuration: editedFileTimeline.duration
                ) ??
                optimisticWaveformOverview(
                    for: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trackID,
                fileTimeline: editedFileTimeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision
            )

            selectedTimelineRange = nil
            timelineSurface.displaySelection(nil)
            timelineSurface.displayGainPreview(selection: nil, gain: 1)
            refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
            updateProjectDisplayTiming()
            reloadPlaybackFromProjectTracks(preserveProgress: true)
            updateEffectCommandState()
            let insertedDuration = Double(insertedFrameCount) / max(editedFileTimeline.sourceSampleRate, 1)
            updateStatus("pasted \(formatDuration(insertedDuration))")
            return
        }

        guard let clipboardBuffer = audioClipboard.buffer else {
            updateStatus("paste waiting for copied audio")
            return
        }

        if let currentTimeline {
            editUndoStack.append(.timeline(trackID: trackID, timeline: currentTimeline))
        } else {
            let snapshot = ProjectTrackUndoSnapshot(
                tracks: projectTracks,
                activeTrackID: activeTrackID,
                selectedTrackID: selectedTrackID,
                selectedTrackIDs: selectedTrackIDs,
                selectedTimelineRange: selectedTimelineRange,
                restoreProgress: nil
            )
            editUndoStack.append(.projectTracks(snapshot))
        }
        projectTracks[trackIndex].editRevision += 1
        let editRevision = projectTracks[trackIndex].editRevision

        projectTracks[trackIndex].waveformOverview = optimisticWaveformOverview(
            currentOverview,
            replacing: pasteSelection,
            with: audioClipboard.waveformOverview
        )
        if let currentTimeline {
            projectTracks[trackIndex].audioTimeline = currentTimeline
            projectTracks[trackIndex].fileTimeline = nil
            projectTracks[trackIndex].decodedAudioBuffer = nil
        } else if let currentFileTimeline {
            projectTracks[trackIndex].audioTimeline = nil
            projectTracks[trackIndex].fileTimeline = currentFileTimeline
            projectTracks[trackIndex].decodedAudioBuffer = nil
        }
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming()
        updateEffectCommandState()
        updateStatus("pasting - playback updates shortly")

        Task {
            [weak self, currentTimeline, currentFileTimeline, pasteSelection, clipboardBuffer, sourceURL, trackID, editRevision] in
            do {
                let materialized = try await Task.detached(priority: .userInitiated) {
                    let timeline: AudioEditTimeline
                    if let currentTimeline {
                        timeline = currentTimeline
                    } else if let currentFileTimeline {
                        let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
                        timeline = currentFileTimeline.audioTimeline(sourceBuffer: sourceBuffer)
                    } else {
                        throw PlaybackError.invalidFormat
                    }

                    return try Self.materializePaste(
                        timeline: timeline,
                        selection: pasteSelection,
                        clipboardBuffer: clipboardBuffer
                    )
                }.value

                guard let self else {
                    return
                }

                self.applyMaterializedTrackEdit(
                    trackID: trackID,
                    editRevision: editRevision,
                    materialized: materialized,
                    status: "pasted \(self.formatDuration(clipboardBuffer.duration))",
                    preservePlaybackProgress: true,
                    reloadPlaybackSource: true,
                    preserveTimelineSource: false
                )
            } catch {
                guard let self else {
                    return
                }
                self.updateStatus("paste failed: \(error.localizedDescription)")
            }
        }
    }

    private func duplicateRegion() {
        guard
            let target = currentEditableSelectionTarget(),
            projectTracks.indices.contains(target.trackIndex),
            target.editSelection.durationProgress > 0
        else {
            updateStatus("select audio to duplicate")
            return
        }

        let trackIndex = target.trackIndex
        let trackID = projectTracks[trackIndex].id
        let selectionToDuplicate = target.editSelection
        let insertionSelection = TimelineSelection(
            startProgress: selectionToDuplicate.endProgress,
            endProgress: selectionToDuplicate.endProgress,
            trackID: trackID
        )
        let currentOverview = projectTracks[trackIndex].waveformOverview
        let duplicatedOverview = selectedWaveformOverview(
            from: currentOverview,
            selection: selectionToDuplicate
        )
        let undoSnapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: playbackController.snapshot().progress
        )

        if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            guard
                let clip = timeline.clip(for: selectionToDuplicate),
                let insertedFrameCount = timeline.replace(insertionSelection, with: clip),
                insertedFrameCount > 0
            else {
                updateStatus("duplicate failed")
                return
            }

            editUndoStack.append(.projectTracks(undoSnapshot))
            cancelEditMaterialization(for: trackID)
            projectTracks[trackIndex].editRevision += 1
            let editRevision = projectTracks[trackIndex].editRevision
            projectTracks[trackIndex].audioTimeline = nil
            projectTracks[trackIndex].fileTimeline = timeline
            projectTracks[trackIndex].decodedAudioBuffer = nil
            projectTracks[trackIndex].durationHint = timeline.duration
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    currentOverview,
                    replacing: insertionSelection,
                    with: duplicatedOverview,
                    targetDuration: timeline.duration
                ) ??
                optimisticWaveformOverview(
                    for: timeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trackID,
                fileTimeline: timeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision
            )
            finishDuplicateRegion(
                trackID: trackID,
                duration: Double(insertedFrameCount) / max(timeline.sourceSampleRate, 1),
                preservePlaybackProgress: true
            )
            return
        }

        guard let currentTimeline = projectTracks[trackIndex].audioTimeline else {
            updateStatus("track is not ready to duplicate")
            return
        }

        var timeline = currentTimeline
        guard
            let clip = timeline.clip(for: selectionToDuplicate),
            let insertedFrameCount = timeline.replace(insertionSelection, with: clip),
            insertedFrameCount > 0
        else {
            updateStatus("duplicate failed")
            return
        }

        editUndoStack.append(.projectTracks(undoSnapshot))
        cancelEditMaterialization(for: trackID)
        projectTracks[trackIndex].editRevision += 1
        let editRevision = projectTracks[trackIndex].editRevision
        projectTracks[trackIndex].audioTimeline = timeline
        projectTracks[trackIndex].fileTimeline = nil
        projectTracks[trackIndex].decodedAudioBuffer = nil
        projectTracks[trackIndex].durationHint = timeline.duration
        projectTracks[trackIndex].waveformOverview = optimisticWaveformOverview(
            currentOverview,
            replacing: insertionSelection,
            with: duplicatedOverview,
            targetDuration: timeline.duration
        )
        cancelEditWaveformRefinement(for: trackID)
        finishDuplicateRegion(
            trackID: trackID,
            duration: Double(insertedFrameCount) / max(timeline.sourceAudioBuffer.sampleRate, 1),
            preservePlaybackProgress: true
        )
        materializeEditedTimeline(
            trackID: trackID,
            timeline: timeline,
            editRevision: editRevision,
            status: "duplicated \(formatDuration(Double(insertedFrameCount) / max(timeline.sourceAudioBuffer.sampleRate, 1)))",
            preservePlaybackProgress: true,
            startDelay: editMaterializationDelay,
            animateWaveformTransition: false
        )
    }

    private func finishDuplicateRegion(
        trackID: UUID,
        duration: TimeInterval,
        preservePlaybackProgress: Bool
    ) {
        activeTrackID = trackID
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(
            preserveProgress: preservePlaybackProgress,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()
        updateStatus("duplicated \(formatDuration(duration))")
    }

    private func performOptimisticDelete(copyBeforeDeleting: Bool, scope: EditScope) {
        guard
            let target = currentEditableSelectionTarget()
        else {
            updateStatus("select audio to delete")
            return
        }

        performOptimisticDelete(
            target: target,
            copyBeforeDeleting: copyBeforeDeleting,
            scope: scope
        )
    }

    private func performOptimisticDelete(
        target: EditableSelectionTarget,
        copyBeforeDeleting: Bool,
        scope: EditScope
    ) {

        guard
            projectTracks.indices.contains(target.trackIndex)
        else {
            updateStatus("no track selected")
            return
        }

        let displaySelectionToDelete = target.displaySelection
        let projectDurationBeforeDelete = projectSelectionDuration
        let targetPlaybackTime = min(
            max(displaySelectionToDelete.startProgress * projectDurationBeforeDelete, 0),
            projectDurationBeforeDelete
        )
        let deleteTargets = rippleDeleteTargets(for: target, scope: scope)
        let trackEdits: [RippleDeleteTrackEdit]
        do {
            trackEdits = try deleteTargets.compactMap { try preparedRippleDeleteTrackEdit(for: $0) }
        } catch {
            updateStatus("delete failed: \(error.localizedDescription)")
            return
        }
        guard !trackEdits.isEmpty else {
            updateStatus("no audio in selected time")
            return
        }

        SoundtimeDiagnostics.shared.record(
            category: .edit,
            severity: .info,
            name: copyBeforeDeleting ? "cut-selection" : "delete-time",
            message: "User requested an optimistic audio edit.",
            fields: [
                "scope": scope.title,
                "trackCount": "\(trackEdits.count)",
                "startProgress": String(format: "%.9f", displaySelectionToDelete.startProgress),
                "endProgress": String(format: "%.9f", displaySelectionToDelete.endProgress),
            ]
        )
        let undoSnapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: displaySelectionToDelete.startProgressFloat
        )

        if copyBeforeDeleting {
            copySelection()
        }

        editUndoStack.append(.projectTracks(undoSnapshot))

        var materializationEdits: [(trackID: UUID, timeline: AudioEditTimeline, editRevision: Int)] = []
        var statusDuration = TimeInterval(0)
        for edit in trackEdits {
            guard projectTracks.indices.contains(edit.trackIndex) else {
                continue
            }

            timelineSurface.triggerDeletionEffect(
                selection: edit.displaySelection,
                sourceSelection: edit.editSelection
            )
            projectTracks[edit.trackIndex].editRevision += 1
            let editRevision = projectTracks[edit.trackIndex].editRevision
            projectTracks[edit.trackIndex].audioTimeline = edit.editedAudioTimeline
            projectTracks[edit.trackIndex].fileTimeline = edit.editedFileTimeline
            projectTracks[edit.trackIndex].decodedAudioBuffer = nil
            projectTracks[edit.trackIndex].durationHint = edit.editedDuration
            let currentOverview = projectTracks[edit.trackIndex].waveformOverview
            if let editedFileTimeline = edit.editedFileTimeline {
                projectTracks[edit.trackIndex].waveformOverview =
                    optimisticWaveformOverview(
                        currentOverview,
                        replacing: edit.editSelection,
                        with: nil,
                        targetDuration: edit.editedDuration
                    ) ??
                    optimisticWaveformOverview(
                        for: editedFileTimeline,
                        sourceOverview: projectTracks[edit.trackIndex].sourceWaveformOverview,
                        fallbackOverview: currentOverview
                    )
                scheduleFileTimelineWaveformRefinement(
                    trackID: edit.trackID,
                    fileTimeline: editedFileTimeline,
                    sourceOverview: projectTracks[edit.trackIndex].sourceWaveformOverview ?? currentOverview,
                    editRevision: editRevision,
                    delay: deleteMaterializationDelay
                )
            } else {
                projectTracks[edit.trackIndex].waveformOverview = optimisticWaveformOverview(
                    currentOverview,
                    replacing: edit.editSelection,
                    with: nil,
                    targetDuration: edit.editedDuration
                )
                cancelEditWaveformRefinement(for: edit.trackID)
            }

            statusDuration = max(statusDuration, edit.deletedDuration)
            scheduleDeleteVisualRefresh(trackID: edit.trackID, editRevision: editRevision)
            if let editedAudioTimeline = edit.editedAudioTimeline {
                materializationEdits.append((
                    trackID: edit.trackID,
                    timeline: editedAudioTimeline,
                    editRevision: editRevision
                ))
            }
        }

        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        syncActiveTrackFields()
        updateProjectDisplayTiming()
        let clampedTargetPlaybackTime = min(
            targetPlaybackTime,
            max(displayedDuration, 0)
        )
        let targetPlaybackProgress = displayedDuration > 0 ?
            min(max(Float(clampedTargetPlaybackTime / displayedDuration), 0), 1) :
            0
        reloadPlaybackFromProjectTracks(
            preserveProgress: false,
            targetProgress: targetPlaybackProgress,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()
        let scopeSuffix: String
        if trackEdits.count > 1 {
            switch scope {
            case .track:
                scopeSuffix = ""
            case .selected:
                scopeSuffix = " across \(trackEdits.count) selected tracks"
            case .group:
                scopeSuffix = " across \(trackEdits.count) grouped tracks"
            case .all:
                scopeSuffix = " across \(trackEdits.count) tracks"
            }
        } else {
            scopeSuffix = ""
        }
        let status = "\(copyBeforeDeleting ? "cut" : "deleted") \(formatDuration(statusDuration))\(scopeSuffix)"
        updateStatus(status)

        for edit in materializationEdits {
            materializeEditedTimeline(
                trackID: edit.trackID,
                timeline: edit.timeline,
                editRevision: edit.editRevision,
                status: status,
                preservePlaybackProgress: true,
                startDelay: deleteMaterializationDelay,
                animateWaveformTransition: false
            )
        }
    }

    private func rippleDeleteTargets(
        for target: EditableSelectionTarget,
        scope: EditScope
    ) -> [EditableSelectionTarget] {
        scopedTrackIndices(anchorTrackIndex: target.trackIndex, scope: scope).compactMap { trackIndex in
            if trackIndex == target.trackIndex {
                return target
            }
            return rippleDeleteTarget(
                matching: target.displaySelection,
                trackIndex: trackIndex
            )
        }
    }

    private func scopedTrackIndices(
        anchorTrackIndex: Int,
        scope: EditScope
    ) -> [Int] {
        guard projectTracks.indices.contains(anchorTrackIndex) else {
            return []
        }

        switch scope {
        case .track:
            return [anchorTrackIndex]
        case .selected:
            let selectedIDs = selectedTrackIDs.isEmpty ?
                Set([projectTracks[anchorTrackIndex].id]) :
                selectedTrackIDs
            return projectTracks.indices.filter { selectedIDs.contains(projectTracks[$0].id) }
        case .group:
            guard let editGroupID = projectTracks[anchorTrackIndex].editGroupID else {
                return [anchorTrackIndex]
            }
            return projectTracks.indices.filter { projectTracks[$0].editGroupID == editGroupID }
        case .all:
            return Array(projectTracks.indices)
        }
    }

    private func rippleDeleteTarget(
        matching displaySelection: TimelineSelection,
        trackIndex: Int
    ) -> EditableSelectionTarget? {
        guard projectTracks.indices.contains(trackIndex) else {
            return nil
        }

        let trackID = projectTracks[trackIndex].id
        let trackDisplaySelection = TimelineSelection(
            startProgress: displaySelection.startProgress,
            endProgress: displaySelection.endProgress,
            trackID: trackID
        )
        guard let editSelection = editSelection(from: trackDisplaySelection, trackIndex: trackIndex) else {
            return nil
        }
        return EditableSelectionTarget(
            trackIndex: trackIndex,
            displaySelection: trackDisplaySelection,
            editSelection: editSelection
        )
    }

    private func preparedRippleDeleteTrackEdit(
        for target: EditableSelectionTarget
    ) throws -> RippleDeleteTrackEdit? {
        guard projectTracks.indices.contains(target.trackIndex) else {
            return nil
        }

        let trackIndex = target.trackIndex
        let trackID = projectTracks[trackIndex].id
        let selectionToDelete = target.editSelection

        if let currentFileTimeline = try preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            let deletedDuration = selectionToDelete.duration(in: currentFileTimeline.duration)
            let deletedFrameCount = timeline.delete(selectionToDelete)
            guard deletedFrameCount > 0 else {
                return nil
            }
            return RippleDeleteTrackEdit(
                trackIndex: trackIndex,
                trackID: trackID,
                displaySelection: target.displaySelection,
                editSelection: selectionToDelete,
                deletedDuration: deletedDuration,
                editedDuration: timeline.duration,
                editedAudioTimeline: nil,
                editedFileTimeline: timeline
            )
        }

        if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            var timeline = currentTimeline
            let deletedDuration = selectionToDelete.duration(in: currentTimeline.duration)
            let deletedFrameCount = timeline.delete(selectionToDelete)
            guard deletedFrameCount > 0 else {
                return nil
            }
            return RippleDeleteTrackEdit(
                trackIndex: trackIndex,
                trackID: trackID,
                displaySelection: target.displaySelection,
                editSelection: selectionToDelete,
                deletedDuration: deletedDuration,
                editedDuration: timeline.duration,
                editedAudioTimeline: timeline,
                editedFileTimeline: nil
            )
        }

        return nil
    }

    private func preparedClearTrackEdit(
        for target: EditableSelectionTarget
    ) throws -> ClearTrackEdit? {
        guard projectTracks.indices.contains(target.trackIndex) else {
            return nil
        }

        let trackIndex = target.trackIndex
        let trackID = projectTracks[trackIndex].id
        let selectionToClear = target.editSelection

        if let currentFileTimeline = try preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            let clearedDuration = selectionToClear.duration(in: currentFileTimeline.duration)
            let affectedFrameCount = timeline.clear(selectionToClear)
            guard affectedFrameCount > 0 else {
                return nil
            }
            return ClearTrackEdit(
                trackIndex: trackIndex,
                trackID: trackID,
                editSelection: selectionToClear,
                clearedDuration: clearedDuration,
                editedDuration: timeline.duration,
                editedAudioTimeline: nil,
                editedFileTimeline: timeline
            )
        }

        if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            var timeline = currentTimeline
            let clearedDuration = selectionToClear.duration(in: currentTimeline.duration)
            let affectedFrameCount = timeline.clear(selectionToClear)
            guard affectedFrameCount > 0 else {
                return nil
            }
            return ClearTrackEdit(
                trackIndex: trackIndex,
                trackID: trackID,
                editSelection: selectionToClear,
                clearedDuration: clearedDuration,
                editedDuration: timeline.duration,
                editedAudioTimeline: timeline,
                editedFileTimeline: nil
            )
        }

        return nil
    }

    private func preparedSplitTrackEdit(
        trackIndex: Int,
        projectProgress: Float
    ) throws -> SplitTrackEdit? {
        guard projectTracks.indices.contains(trackIndex) else {
            return nil
        }

        let insertionSelection = editInsertionSelection(
            forPlaybackProgress: projectProgress,
            trackIndex: trackIndex
        )
        guard insertionSelection.startProgress > 0, insertionSelection.startProgress < 1 else {
            return nil
        }

        let trackID = projectTracks[trackIndex].id
        if let currentFileTimeline = try preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            guard timeline.split(atProgress: insertionSelection.startProgress) else {
                return nil
            }
            return SplitTrackEdit(
                trackIndex: trackIndex,
                trackID: trackID,
                editedDuration: timeline.duration,
                editedAudioTimeline: nil,
                editedFileTimeline: timeline
            )
        }

        if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            var timeline = currentTimeline
            guard timeline.split(atProgress: insertionSelection.startProgress) else {
                return nil
            }
            return SplitTrackEdit(
                trackIndex: trackIndex,
                trackID: trackID,
                editedDuration: timeline.duration,
                editedAudioTimeline: timeline,
                editedFileTimeline: nil
            )
        }

        return nil
    }

    private func scheduleDeleteVisualRefresh(trackID: UUID, editRevision: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + deleteVisualRefreshDelay) { [weak self] in
            guard
                let self,
                let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
                projectTracks[trackIndex].editRevision == editRevision
            else {
                return
            }

            refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        }
    }

    private func trimTimeline(to trimRange: TimelineTrimRange) {
        guard
            trimRange.trimsAudio,
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            return
        }

        let trackID = projectTracks[trackIndex].id
        let undoSnapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: playbackController.snapshot().progress
        )
        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
        let trimmedDuration: TimeInterval

        if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            let originalDuration = currentFileTimeline.duration
            let trimmedFrameCount = timeline.trim(to: trimRange)
            guard trimmedFrameCount > 0 else {
                return
            }
            trimmedDuration = max(originalDuration - timeline.duration, 0)
            editedAudioTimeline = nil
            editedFileTimeline = timeline
        } else if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            var timeline = currentTimeline
            let originalDuration = currentTimeline.duration
            let trimmedFrameCount = timeline.trim(to: trimRange)
            guard trimmedFrameCount > 0 else {
                return
            }
            trimmedDuration = max(originalDuration - timeline.duration, 0)
            editedAudioTimeline = timeline
            editedFileTimeline = nil
        } else {
            updateStatus("track is not ready to trim")
            return
        }

        editUndoStack.append(.projectTracks(undoSnapshot))
        cancelEditMaterialization(for: trackID)
        projectTracks[trackIndex].editRevision += 1
        let editRevision = projectTracks[trackIndex].editRevision
        projectTracks[trackIndex].audioTimeline = editedAudioTimeline
        projectTracks[trackIndex].fileTimeline = editedFileTimeline
        projectTracks[trackIndex].decodedAudioBuffer = editedAudioTimeline?.sourceAudioBuffer
        projectTracks[trackIndex].durationHint = editedFileTimeline?.duration ?? editedAudioTimeline?.duration
        let currentOverview = projectTracks[trackIndex].waveformOverview
        if let editedFileTimeline {
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    for: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trackID,
                fileTimeline: editedFileTimeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision,
                delay: editMaterializationDelay
            )
        } else if let currentOverview {
            projectTracks[trackIndex].waveformOverview = WaveformOverview(
                duration: editedAudioTimeline?.duration ?? currentOverview.duration,
                bins: currentOverview.bins
            )
            cancelEditWaveformRefinement(for: trackID)
        }

        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(
            preserveProgress: true,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()
        let status = "trimmed \(formatDuration(trimmedDuration))"
        updateStatus(status)

        if let editedAudioTimeline {
            materializeEditedTimeline(
                trackID: trackID,
                timeline: editedAudioTimeline,
                editRevision: editRevision,
                status: status,
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay,
                animateWaveformTransition: false
            )
        }
    }

    private func trimClipBoundary(_ trim: TimelineClipBoundaryTrim) {
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trim.trackID }),
            projectTracks.indices.contains(trackIndex)
        else {
            return
        }

        let undoSnapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: playbackController.snapshot().progress
        )
        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
        let trimmedDuration: TimeInterval

        if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            let originalDuration = currentFileTimeline.duration
            let trimmedFrameCount = timeline.trimClip(
                AudioFileEditTimeline.ClipRange(
                    startProgress: trim.clipRange.startProgress,
                    endProgress: trim.clipRange.endProgress
                ),
                edge: trim.edge == .leading ? .leading : .trailing,
                toProgress: trim.targetProgress
            )
            guard trimmedFrameCount > 0 else {
                return
            }
            trimmedDuration = max(originalDuration - timeline.duration, 0)
            editedAudioTimeline = nil
            editedFileTimeline = timeline
        } else if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            var timeline = currentTimeline
            let originalDuration = currentTimeline.duration
            let trimmedFrameCount = timeline.trimClip(
                AudioEditTimeline.ClipRange(
                    startProgress: trim.clipRange.startProgress,
                    endProgress: trim.clipRange.endProgress
                ),
                edge: trim.edge == .leading ? .leading : .trailing,
                toProgress: trim.targetProgress
            )
            guard trimmedFrameCount > 0 else {
                return
            }
            trimmedDuration = max(originalDuration - timeline.duration, 0)
            editedAudioTimeline = timeline
            editedFileTimeline = nil
        } else {
            updateStatus("track is not ready to trim")
            return
        }

        editUndoStack.append(.projectTracks(undoSnapshot))
        cancelEditMaterialization(for: trim.trackID)
        projectTracks[trackIndex].editRevision += 1
        let editRevision = projectTracks[trackIndex].editRevision
        projectTracks[trackIndex].audioTimeline = editedAudioTimeline
        projectTracks[trackIndex].fileTimeline = editedFileTimeline
        projectTracks[trackIndex].decodedAudioBuffer = editedAudioTimeline?.sourceAudioBuffer
        projectTracks[trackIndex].durationHint = editedFileTimeline?.duration ?? editedAudioTimeline?.duration
        let currentOverview = projectTracks[trackIndex].waveformOverview
        if let editedFileTimeline {
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    for: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trim.trackID,
                fileTimeline: editedFileTimeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision,
                delay: editMaterializationDelay
            )
        } else if let currentOverview {
            projectTracks[trackIndex].waveformOverview = WaveformOverview(
                duration: editedAudioTimeline?.duration ?? currentOverview.duration,
                bins: currentOverview.bins
            )
            cancelEditWaveformRefinement(for: trim.trackID)
        }

        activeTrackID = trim.trackID
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(
            preserveProgress: true,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()
        let edgeName = trim.edge == .leading ? "start" : "end"
        let status = "trimmed clip \(edgeName) \(formatDuration(trimmedDuration))"
        updateStatus(status)

        if let editedAudioTimeline {
            materializeEditedTimeline(
                trackID: trim.trackID,
                timeline: editedAudioTimeline,
                editRevision: editRevision,
                status: status,
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay,
                animateWaveformTransition: false
            )
        }
    }

    private func showGainEffect() {
        guard canApplyGainEffect else {
            return
        }

        gainEffectOverlay.show()
    }

    private func reapplyLastEffect() {
        guard let lastEffect else {
            return
        }

        switch lastEffect {
        case let .gain(decibels):
            guard canApplyGainEffect else {
                return
            }
            let gain = GainEffectOverlayView.linearGain(forDecibels: decibels)
            applyGainEffect(decibels: decibels, gain: gain)
        case .normalize:
            guard canApplyGainEffect else {
                return
            }
            applyNormalizeEffect()
        case let .fade(fadeEffect):
            guard canApplyFadeEffect else {
                return
            }
            applyFadeEffect(fadeEffect)
        }
    }

    private func applyNormalizeEffect() {
        guard
            let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            updateStatus("select audio to normalize")
            return
        }

        if let selectedPeak = selectedPeakMagnitude(for: target) {
            applyNormalizeEffect(withPeak: selectedPeak)
            return
        }

        let trackIndex = target.trackIndex
        let trackID = projectTracks[trackIndex].id
        let editRevision = projectTracks[trackIndex].editRevision
        let sourceURL = projectTracks[trackIndex].sourceURL
        let audioTimeline = projectTracks[trackIndex].audioTimeline
        let fileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex)
        let selectionToNormalize = target.editSelection
        let displaySelection = target.displaySelection
        updateStatus("normalizing")
        Task { [weak self, trackID, editRevision, sourceURL, audioTimeline, fileTimeline, selectionToNormalize, displaySelection] in
            let peakResult = await Task.detached(priority: .userInitiated) {
                try Self.exactPeakMagnitude(
                    audioTimeline: audioTimeline,
                    fileTimeline: fileTimeline,
                    sourceURL: sourceURL,
                    selection: selectionToNormalize
                )
            }.result

            guard let self else {
                return
            }

            guard
                let currentTarget = self.currentEditableSelectionTarget() ?? self.editableClipAtPlayheadTarget(),
                self.projectTracks.indices.contains(currentTarget.trackIndex),
                self.projectTracks[currentTarget.trackIndex].id == trackID,
                self.projectTracks[currentTarget.trackIndex].editRevision == editRevision,
                Self.selectionsMatch(currentTarget.displaySelection, displaySelection),
                Self.selectionsMatch(currentTarget.editSelection, selectionToNormalize)
            else {
                self.updateStatus("normalize skipped: selection changed")
                return
            }

            switch peakResult {
            case let .success(selectedPeak):
                self.applyNormalizeEffect(withPeak: selectedPeak)
            case let .failure(error):
                self.updateStatus("normalize failed: \(error.localizedDescription)")
            }
        }
    }

    private func applyNormalizeEffect(withPeak selectedPeak: Float) {
        guard selectedPeak > 0.000_001 else {
            updateStatus("normalize skipped: selected audio is silent")
            return
        }

        let gain = min(max(1 / selectedPeak, 0), 64)
        let decibels = 20 * log10(Double(gain))
        applyGainEffect(
            decibels: decibels,
            gain: gain,
            status: String(format: "normalized %+.1f dB", decibels),
            lastEffect: .normalize
        )
    }

    private func previewSelectedGain(_ gain: Float) {
        guard let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget(), canApplyGainEffect else {
            timelineSurface.displayGainPreview(selection: nil, gain: 1)
            return
        }

        timelineSurface.displayGainPreview(selection: target.displaySelection, gain: gain)
    }

    private func cancelSelectedGainPreview() {
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        updateStatus(currentPlaybackStatus)
    }

    private func confirmSelectedGain(decibels: Double, gain: Float) {
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        applyGainEffect(decibels: decibels, gain: gain)
    }

    private func applyGainEffect(
        decibels: Double,
        gain: Float,
        status: String? = nil,
        lastEffect: LastEffect? = nil
    ) {
        guard
            let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget()
        else {
            return
        }

        let trackIndex = target.trackIndex
        let selectionToApply = target.editSelection
        let trackID = projectTracks[trackIndex].id
        let editRevision: Int
        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
        let undoSnapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: nil
        )

        if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            let affectedFrameCount = timeline.applyGain(gain, to: selectionToApply)
            guard affectedFrameCount > 0 else {
                return
            }

            editUndoStack.append(.projectTracks(undoSnapshot))
            editedAudioTimeline = nil
            editedFileTimeline = timeline
        } else if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            var timeline = currentTimeline
            let affectedFrameCount = timeline.applyGain(gain, to: selectionToApply)
            guard affectedFrameCount > 0 else {
                return
            }

            editUndoStack.append(.projectTracks(undoSnapshot))
            editedAudioTimeline = timeline
            editedFileTimeline = nil
        } else {
            let currentFileTimeline: AudioFileEditTimeline
            do {
                currentFileTimeline = try editableFileTimeline(forTrackAt: trackIndex)
            } catch {
                updateStatus("gain failed: \(error.localizedDescription)")
                return
            }

            var timeline = currentFileTimeline
            let affectedFrameCount = timeline.applyGain(gain, to: selectionToApply)
            guard affectedFrameCount > 0 else {
                return
            }

            editUndoStack.append(.projectTracks(undoSnapshot))
            editedAudioTimeline = nil
            editedFileTimeline = timeline
        }

        projectTracks[trackIndex].editRevision += 1
        editRevision = projectTracks[trackIndex].editRevision
        projectTracks[trackIndex].audioTimeline = editedAudioTimeline
        projectTracks[trackIndex].fileTimeline = editedFileTimeline
        projectTracks[trackIndex].decodedAudioBuffer = nil
        projectTracks[trackIndex].durationHint = editedFileTimeline?.duration ?? editedAudioTimeline?.duration
        let currentOverview = projectTracks[trackIndex].waveformOverview
        if let editedFileTimeline {
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    currentOverview,
                    applyingGain: gain,
                    to: selectionToApply
                ) ??
                optimisticWaveformOverview(
                    for: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trackID,
                fileTimeline: editedFileTimeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision
            )
        } else {
            projectTracks[trackIndex].waveformOverview = optimisticWaveformOverview(
                currentOverview,
                applyingGain: gain,
                to: selectionToApply
            )
            cancelEditWaveformRefinement(for: trackID)
        }
        let status = status ?? String(format: "gain %+.1f dB", decibels)
        self.lastEffect = lastEffect ?? .gain(decibels: decibels)
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        updateEffectCommandState()
        updateStatus(status)

        if let editedAudioTimeline {
            materializeEditedTimeline(
                trackID: trackID,
                timeline: editedAudioTimeline,
                editRevision: editRevision,
                status: status,
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay
            )
        }
    }

    private func applyFadeEffect(_ fadeEffect: FadeEffect) {
        guard
            let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget()
        else {
            return
        }

        let trackIndex = target.trackIndex
        let selectionToApply = target.editSelection
        let timelineFadeDirection: AudioEditTimeline.FadeDirection
        switch fadeEffect {
        case .fadeIn:
            timelineFadeDirection = .fadeIn
        case .fadeOut:
            timelineFadeDirection = .fadeOut
        }

        let trackID = projectTracks[trackIndex].id
        activeTrackID = trackID
        let selectedDuration: TimeInterval
        let editRevision: Int
        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
        let undoSnapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: nil
        )

        if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            let affectedFrameCount = timeline.applyFade(timelineFadeDirection, to: selectionToApply)
            guard affectedFrameCount > 1 else {
                return
            }

            selectedDuration = selectionToApply.duration(in: currentFileTimeline.duration)
            editUndoStack.append(.projectTracks(undoSnapshot))
            editedAudioTimeline = nil
            editedFileTimeline = timeline
        } else if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            var timeline = currentTimeline
            let affectedFrameCount = timeline.applyFade(timelineFadeDirection, to: selectionToApply)
            guard affectedFrameCount > 1 else {
                return
            }

            selectedDuration = selectionToApply.duration(in: currentTimeline.duration)
            editUndoStack.append(.projectTracks(undoSnapshot))
            editedAudioTimeline = timeline
            editedFileTimeline = nil
        } else {
            let currentFileTimeline: AudioFileEditTimeline
            do {
                currentFileTimeline = try editableFileTimeline(forTrackAt: trackIndex)
            } catch {
                updateStatus("\(fadeEffect.displayName) failed: \(error.localizedDescription)")
                return
            }

            var timeline = currentFileTimeline
            let affectedFrameCount = timeline.applyFade(timelineFadeDirection, to: selectionToApply)
            guard affectedFrameCount > 1 else {
                return
            }

            selectedDuration = selectionToApply.duration(in: currentFileTimeline.duration)
            editUndoStack.append(.projectTracks(undoSnapshot))
            editedAudioTimeline = nil
            editedFileTimeline = timeline
        }

        projectTracks[trackIndex].editRevision += 1
        editRevision = projectTracks[trackIndex].editRevision
        projectTracks[trackIndex].audioTimeline = editedAudioTimeline
        projectTracks[trackIndex].fileTimeline = editedFileTimeline
        projectTracks[trackIndex].decodedAudioBuffer = nil
        projectTracks[trackIndex].durationHint = editedFileTimeline?.duration ?? editedAudioTimeline?.duration
        let currentOverview = projectTracks[trackIndex].waveformOverview
        if let editedFileTimeline {
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    currentOverview,
                    applyingFade: timelineFadeDirection,
                    to: selectionToApply
                ) ??
                optimisticWaveformOverview(
                    for: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trackID,
                fileTimeline: editedFileTimeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision
            )
        } else {
            projectTracks[trackIndex].waveformOverview = optimisticWaveformOverview(
                currentOverview,
                applyingFade: timelineFadeDirection,
                to: selectionToApply
            )
            cancelEditWaveformRefinement(for: trackID)
        }
        lastEffect = .fade(fadeEffect)
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        updateEffectCommandState()
        let status = "\(fadeEffect.displayName) \(formatDuration(selectedDuration))"
        updateStatus(status)

        if let editedAudioTimeline {
            materializeEditedTimeline(
                trackID: trackID,
                timeline: editedAudioTimeline,
                editRevision: editRevision,
                status: status,
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay
            )
        }
    }

    private func undoLastEdit() {
        guard let undoAction = editUndoStack.popLast() else {
            return
        }

        switch undoAction {
        case let .timeline(trackID, previousTimeline):
            if let trackID, projectTracks.contains(where: { $0.id == trackID }) {
                activeTrackID = trackID
            }
            applyTimeline(previousTimeline)
            updateStatus("undo")
        case let .projectTracks(snapshot):
            restoreProjectTracks(from: snapshot)
        }
    }

    private func restoreProjectTracks(from snapshot: ProjectTrackUndoSnapshot) {
        let replacedTracks = projectTracks
        SoundtimeDiagnostics.shared.record(
            category: .edit,
            severity: .info,
            name: "undo-project-tracks",
            message: "Restoring project tracks from undo snapshot.",
            fields: [
                "trackCount": "\(snapshot.tracks.count)",
                "restoreProgress": snapshot.restoreProgress.map { String(format: "%.9f", $0) } ?? "preserve",
            ]
        )
        cancelAllEditMaterialization()
        projectTracks = snapshot.tracks
        activeTrackID = snapshot.activeTrackID.flatMap { activeID in
            projectTracks.contains(where: { $0.id == activeID }) ? activeID : nil
        } ?? projectTracks.last?.id
        selectedTrackID = snapshot.selectedTrackID.flatMap { selectedID in
            projectTracks.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }
        let liveTrackIDs = Set(projectTracks.map(\.id))
        selectedTrackIDs = snapshot.selectedTrackIDs.intersection(liveTrackIDs)
        if let selectedTrackID {
            selectedTrackIDs.insert(selectedTrackID)
        }
        trackSelectionAnchorID = selectedTrackID
        selectedTimelineRange = snapshot.selectedTimelineRange
        syncActiveTrackFields()
        updateProjectDisplayTiming()
        timelineSurface.clearDeletionEffects()
        timelineSurface.displaySelection(selectedTimelineRange)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        publishSelectedTracksToTimeline()
        refreshProjectTimelineDisplay(animateWaveformTransition: false)
        reloadPlaybackFromProjectTracks(
            preserveProgress: snapshot.restoreProgress == nil,
            targetProgress: snapshot.restoreProgress
        )
        updateEffectCommandState()
        cleanupOwnedSourceFiles(replacedTracks: replacedTracks)
        updateStatus("undo")
    }

    private func cancelEditMaterialization(for trackID: UUID) {
        editMaterializationTasks[trackID]?.cancel()
        editMaterializationTasks[trackID] = nil
        editMaterializationRequestIDs[trackID] = nil
        cancelEditWaveformRefinement(for: trackID)
    }

    private func cancelEditWaveformRefinement(for trackID: UUID) {
        editWaveformRefinementTasks[trackID]?.cancel()
        editWaveformRefinementTasks[trackID] = nil
        editWaveformRefinementRequestIDs[trackID] = nil
    }

    private func cancelAllEditMaterialization() {
        for task in editMaterializationTasks.values {
            task.cancel()
        }
        editMaterializationTasks.removeAll()
        editMaterializationRequestIDs.removeAll()
        for task in editWaveformRefinementTasks.values {
            task.cancel()
        }
        editWaveformRefinementTasks.removeAll()
        editWaveformRefinementRequestIDs.removeAll()
    }

    private func togglePlayback() {
        if recordingTrackID != nil {
            stopRecording()
            return
        }

        guard playbackController.hasSource else {
            return
        }

        do {
            let snapshot = playbackController.snapshot()
            let wasPlaying = snapshot.isPlaying
            let isPlaying: Bool
            if wasPlaying {
                let pauseProgress = displayedDuration > 0 ?
                    timelineSurface.pausePresentationPlayheadProgress() :
                    nil
                playbackController.pause(atProgress: max(pauseProgress ?? snapshot.progress, snapshot.progress))
                isPlaying = false
            } else {
                try playbackController.play()
                isPlaying = true
            }
            refreshPlaybackProgress(syncPlayheadWhenPlaying: true)

            if isPlaying {
                startPlaybackTimer()
                updateStatus("playing")
            } else {
                stopPlaybackTimer()
                updateStatus("paused")
            }
        } catch {
            stopPlaybackTimer()
            updateStatus("playback failed: \(error.localizedDescription)")
        }
    }

    private func seek(to progress: Float) {
        guard playbackController.hasSource else {
            return
        }

        do {
            let wasPlaying = playbackController.isPlaying
            try playbackController.seek(toProgress: progress)
            refreshPlaybackProgress(
                syncPlayheadWhenPlaying: true,
                restartsFisheyeActivation: wasPlaying && playbackController.isPlaying,
                restartsPlayheadKick: wasPlaying && playbackController.isPlaying
            )

            if playbackController.isPlaying {
                startPlaybackTimer()
                updateStatus("playing")
            } else {
                stopPlaybackTimer()
                updateStatus("ready")
            }
        } catch {
            stopPlaybackTimer()
            updateStatus("seek failed: \(error.localizedDescription)")
        }
    }

    private func play(from progress: Float) {
        guard playbackController.hasSource else {
            return
        }

        do {
            let wasPlaying = playbackController.isPlaying
            try playbackController.seek(toProgress: progress)

            if !playbackController.isPlaying {
                try playbackController.play()
            }

            refreshPlaybackProgress(
                syncPlayheadWhenPlaying: true,
                restartsFisheyeActivation: wasPlaying && playbackController.isPlaying,
                restartsPlayheadKick: wasPlaying && playbackController.isPlaying
            )
            startPlaybackTimer()
            updateStatus("playing")
        } catch {
            stopPlaybackTimer()
            updateStatus("playback failed: \(error.localizedDescription)")
        }
    }

    private func exportCurrentAudio() {
        let projectMixSnapshots = projectMixTrackSnapshots()
        let fallbackDecodedAudioBuffer = decodedAudioBuffer
        guard !projectMixSnapshots.isEmpty || (fallbackDecodedAudioBuffer?.frameCount ?? 0) > 0 else {
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Export Audio"
        savePanel.nameFieldStringValue = suggestedExportFilename()
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.allowedContentTypes = [
            .wav,
            UTType(filenameExtension: "m4a") ?? .audio,
            UTType(filenameExtension: "mp3") ?? .audio,
        ]

        let completion: (NSApplication.ModalResponse) -> Void = {
            [weak self, projectMixSnapshots, fallbackDecodedAudioBuffer] response in
            guard
                response == .OK,
                let destinationURL = savePanel.url
            else {
                return
            }

            self?.prepareAndWriteExport(
                projectMixSnapshots: projectMixSnapshots,
                fallbackDecodedAudioBuffer: fallbackDecodedAudioBuffer,
                to: destinationURL
            )
        }

        if let window {
            savePanel.beginSheetModal(for: window, completionHandler: completion)
        } else if savePanel.runModal() == .OK, let destinationURL = savePanel.url {
            prepareAndWriteExport(
                projectMixSnapshots: projectMixSnapshots,
                fallbackDecodedAudioBuffer: fallbackDecodedAudioBuffer,
                to: destinationURL
            )
        }
    }

    private func openProject() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Open Soundtime Project"
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [UTType(filenameExtension: SoundtimeProjectStore.fileExtension) ?? .json]

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = openPanel.url else {
                return
            }

            self?.loadProject(from: url)
        }

        if let window {
            openPanel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(openPanel.runModal())
        }
    }

    private func saveProject() {
        if let currentProjectURL {
            writeProject(to: currentProjectURL)
        } else {
            saveProjectAs()
        }
    }

    private func saveProjectAs() {
        let savePanel = NSSavePanel()
        savePanel.title = "Save Soundtime Project"
        savePanel.nameFieldStringValue = suggestedProjectFilename()
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.allowedContentTypes = [UTType(filenameExtension: SoundtimeProjectStore.fileExtension) ?? .json]

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = savePanel.url else {
                return
            }

            self?.writeProject(to: url)
        }

        if let window {
            savePanel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(savePanel.runModal())
        }
    }

    private func writeProject(to url: URL) {
        do {
            try prepareProjectForSerialization()
            let projectURL = normalizedProjectURL(url)
            try SoundtimeProjectStore.save(currentProject(), to: projectURL)
            withoutAutosave {
                currentProjectURL = projectURL
                markProjectSourceFilesAsSaved()
            }
            SoundtimeProjectStore.removeAutosave(projectURL: projectURL, autosaveID: autosaveID)
            SoundtimeProjectStore.rememberLastProjectURL(projectURL)
            window?.title = projectWindowTitle()
            updateLoadedProjectSummary()
            updateStatus("saved")
        } catch {
            updateStatus("project save failed: \(error.localizedDescription)")
        }
    }

    func persistCurrentProjectWindowLayout() {
        guard let currentProjectURL else {
            return
        }

        do {
            try prepareProjectForSerialization()
            try SoundtimeProjectStore.save(currentProject(), to: currentProjectURL)
            withoutAutosave {
                markProjectSourceFilesAsSaved()
            }
        } catch {
            updateStatus("project window save failed: \(error.localizedDescription)")
        }
    }

    private func scheduleAutosaveIfNeeded() {
        guard
            !isAutosaveSuppressed,
            !isLoadingProject,
            !projectTracks.isEmpty
        else {
            return
        }

        autosaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.writeProjectAutosave()
        }
        autosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDelay, execute: workItem)
    }

    private func writeProjectAutosave() {
        guard
            !isAutosaveSuppressed,
            !isLoadingProject,
            !projectTracks.isEmpty
        else {
            return
        }

        do {
            let url = try SoundtimeProjectStore.saveAutosave(
                currentProject(),
                projectURL: currentProjectURL,
                autosaveID: autosaveID
            )
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .info,
                name: "project-autosave",
                message: "Project autosave was written.",
                fields: [
                    "file": url.lastPathComponent,
                    "trackCount": "\(projectTracks.count)",
                ]
            )
        } catch {
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .warning,
                name: "project-autosave-failed",
                message: "Project autosave failed.",
                fields: [
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private func withoutAutosave(_ body: () throws -> Void) rethrows {
        let previousValue = isAutosaveSuppressed
        isAutosaveSuppressed = true
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        defer {
            isAutosaveSuppressed = previousValue
        }
        try body()
    }

    private func loadProject(from url: URL) {
        if currentProjectURL != nil, currentProjectURL != url {
            persistCurrentProjectWindowLayout()
        }

        do {
            let project = try SoundtimeProjectStore.loadRecoveringAutosave(from: url)
            withoutAutosave {
                clearProjectForLoad()
                currentProjectURL = url
            }
            SoundtimeProjectStore.rememberLastProjectURL(url)
            applyWindowLayout(project.windowLayout)
            applyProjectMasterVolume(project.masterVolume)
            applyProjectTimelineViewport(project.timelineViewport)
            resetWaveformFisheyeTuningToDefaults()
            isLoadingProject = true
            for track in project.tracks {
                addDroppedWAVTrack(
                    at: URL(fileURLWithPath: track.filePath),
                    settings: track
                )
            }
            isLoadingProject = false
            restoreSilenceReviewState(project.silenceReviewState)
            reloadPlaybackFromProjectTracks(preserveProgress: false)
            window?.title = projectWindowTitle()
            updateLoadedProjectSummary()
            updateStatus(playbackController.hasSource ? "project ready - resolving waveforms" : "project loading")
        } catch {
            isLoadingProject = false
            updateStatus("project open failed: \(error.localizedDescription)")
        }
    }

    private func loadRecoveredAutosave(from url: URL) {
        do {
            let project = try SoundtimeProjectStore.load(from: url)
            withoutAutosave {
                clearProjectForLoad()
                currentProjectURL = nil
            }
            applyWindowLayout(project.windowLayout)
            applyProjectMasterVolume(project.masterVolume)
            applyProjectTimelineViewport(project.timelineViewport)
            resetWaveformFisheyeTuningToDefaults()
            isLoadingProject = true
            for track in project.tracks {
                addDroppedWAVTrack(
                    at: URL(fileURLWithPath: track.filePath),
                    settings: track
                )
            }
            isLoadingProject = false
            restoreSilenceReviewState(project.silenceReviewState)
            reloadPlaybackFromProjectTracks(preserveProgress: false)
            window?.title = projectWindowTitle()
            updateLoadedProjectSummary()
            updateStatus(playbackController.hasSource ? "recovered autosave - resolving waveforms" : "recovered autosave")
        } catch {
            isLoadingProject = false
            updateStatus("autosave recovery failed: \(error.localizedDescription)")
        }
    }

    private func clearProjectForLoad() {
        deleteAllOwnedSourceFiles()
        playbackController.clear()
        projectTracks.removeAll()
        activeTrackID = nil
        selectedTrackID = nil
        selectedTrackIDs.removeAll()
        trackSelectionAnchorID = nil
        defaultEditGroupID = UUID()
        decodedAudioBuffer = nil
        audioTimeline = nil
        editUndoStack.removeAll()
        selectedAudioFile = nil
        selectedTimelineRange = nil
        loadedAudioSummary = nil
        currentPlayheadFrame = 0
        displayedFrameCount = 0
        displayedSampleRate = 0
        currentPlaybackStatus = "idle"
        stopPlaybackTimer()
        timelineSurface.displaySelection(nil)
        publishSelectedTracksToTimeline()
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        refreshProjectTimelineDisplay()
        displayPlaybackVisuals(progress: 0, isPlaying: false)
        updateTimeReadout()
        updateEffectCommandState()
    }

    private func prepareProjectForSerialization() throws {
        if recordingTrackID != nil {
            stopRecording()
        }
        try materializeInMemoryEditedProjectTracksForSerialization()
    }

    private func materializeInMemoryEditedProjectTracksForSerialization() throws {
        var replacedTracks: [ProjectTrack] = []
        var didMaterializeTrack = false

        for trackIndex in projectTracks.indices {
            guard needsOwnedSourceMaterializationForSave(projectTracks[trackIndex]) else {
                continue
            }

            guard let buffer = projectTracks[trackIndex].decodedAudioBuffer ??
                projectTracks[trackIndex].audioTimeline?.render()
            else {
                continue
            }

            replacedTracks.append(projectTracks[trackIndex])
            let materializedURL = recordingFileURL(trackName: "\(projectTracks[trackIndex].name)-Edit")
            try WAVFileWriter.write(buffer, to: materializedURL)
            let fileInfo = try WAVAudioDecoder.inspect(url: materializedURL)
            let waveformOverview = WaveformOverviewBuilder.build(from: buffer)

            projectTracks[trackIndex].sourceURL = materializedURL
            projectTracks[trackIndex].durationHint = buffer.duration
            projectTracks[trackIndex].sourceWaveformOverview = waveformOverview
            projectTracks[trackIndex].waveformOverview = waveformOverview
            projectTracks[trackIndex].decodedAudioBuffer = buffer
            projectTracks[trackIndex].zeroCrossingIndex = AudioZeroCrossingIndex.build(from: buffer)
            projectTracks[trackIndex].zeroCrossingProbe = try? WAVAudioDecoder.makeZeroCrossingProbe(
                url: materializedURL,
                fileInfo: fileInfo
            )
            projectTracks[trackIndex].audioTimeline = nil
            projectTracks[trackIndex].fileTimeline = nil
            projectTracks[trackIndex].ownsSourceFile = true
            projectTracks[trackIndex].importID = UUID()
            projectTracks[trackIndex].editRevision += 1
            didMaterializeTrack = true
        }

        guard didMaterializeTrack else {
            return
        }

        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        cleanupOwnedSourceFiles(replacedTracks: replacedTracks)
    }

    private func needsOwnedSourceMaterializationForSave(_ track: ProjectTrack) -> Bool {
        guard track.audioTimeline != nil else {
            return false
        }

        return persistedEditTimeline(for: track) == nil
    }

    private func currentProject() -> SoundtimeProject {
        SoundtimeProject(
            tracks: projectTracks.compactMap { track in
                guard WAVAudioDecoder.canDecode(track.sourceURL) else {
                    return nil
                }

                return SoundtimeProject.Track(
                    id: track.id,
                    editGroupID: track.editGroupID,
                    name: track.name,
                    filePath: track.sourceURL.path,
                    volume: track.volume,
                    isMuted: track.isMuted,
                    isSoloed: track.isSoloed,
                    editTimeline: persistedEditTimeline(for: track)
                )
            },
            windowLayout: currentWindowLayout(),
            masterVolume: volumeControl.perceptualVolume,
            timelineViewport: currentTimelineViewport(),
            silenceReviewState: currentSilenceReviewState()
        )
    }

    private func applyProjectMasterVolume(_ volume: Float?) {
        guard let volume, volume.isFinite else {
            return
        }

        let clampedVolume = min(max(volume, 0), 1)
        volumeControl.perceptualVolume = clampedVolume
        playbackController.setPerceptualVolume(clampedVolume)
    }

    private func currentTimelineViewport() -> SoundtimeProject.TimelineViewport? {
        let viewport = timelineSurface.currentViewport
        guard
            viewport.startProgress.isFinite,
            viewport.durationProgress.isFinite,
            viewport.durationProgress > 0
        else {
            return nil
        }

        return SoundtimeProject.TimelineViewport(
            startProgress: viewport.startProgress,
            durationProgress: viewport.durationProgress
        )
    }

    private func applyProjectTimelineViewport(_ viewport: SoundtimeProject.TimelineViewport?) {
        guard
            let viewport,
            viewport.startProgress.isFinite,
            viewport.durationProgress.isFinite,
            viewport.durationProgress > 0
        else {
            timelineSurface.restoreViewport(nil)
            return
        }

        timelineSurface.restoreViewport(TimelineViewport(
            startProgress: viewport.startProgress,
            durationProgress: viewport.durationProgress
        ))
    }

    private func persistedEditTimeline(for track: ProjectTrack) -> AudioFileEditTimeline.PersistentState? {
        guard WAVAudioDecoder.canDecode(track.sourceURL) else {
            return nil
        }

        if let fileTimeline = track.fileTimeline, fileTimeline.hasEdits {
            return fileTimeline.persistentState
        }

        guard
            let audioTimeline = track.audioTimeline,
            let fileInfo = try? WAVAudioDecoder.inspect(url: track.sourceURL),
            audioTimeline.sourceAudioBuffer.frameCount == fileInfo.frameCount,
            abs(audioTimeline.sourceAudioBuffer.sampleRate - fileInfo.sampleRate) < 0.001,
            let fileTimeline = AudioFileEditTimeline(
                sourceFrameCount: fileInfo.frameCount,
                sourceSampleRate: fileInfo.sampleRate,
                playbackSegments: audioTimeline.playbackSegments
            ),
            fileTimeline.hasEdits,
            fileTimeline.isCompatible(with: fileInfo)
        else {
            return nil
        }

        return fileTimeline.persistentState
    }

    private func currentWindowLayout() -> SoundtimeProject.WindowLayout? {
        guard let frame = window?.frame else {
            return nil
        }

        guard
            frame.origin.x.isFinite,
            frame.origin.y.isFinite,
            frame.width.isFinite,
            frame.height.isFinite,
            frame.width > 0,
            frame.height > 0
        else {
            return nil
        }

        return SoundtimeProject.WindowLayout(
            x: Double(frame.origin.x),
            y: Double(frame.origin.y),
            width: Double(frame.width),
            height: Double(frame.height)
        )
    }

    private func applyWindowLayout(_ layout: SoundtimeProject.WindowLayout?) {
        guard
            let layout,
            let window,
            layout.x.isFinite,
            layout.y.isFinite,
            layout.width.isFinite,
            layout.height.isFinite,
            layout.width > 0,
            layout.height > 0
        else {
            return
        }

        var frame = NSRect(
            x: CGFloat(layout.x),
            y: CGFloat(layout.y),
            width: CGFloat(layout.width),
            height: CGFloat(layout.height)
        )
        frame.size.width = max(frame.width, window.minSize.width)
        frame.size.height = max(frame.height, window.minSize.height)

        guard let visibleFrame = bestVisibleFrame(for: frame, window: window) else {
            window.setFrame(frame, display: true, animate: false)
            return
        }

        if frame.width <= visibleFrame.width {
            frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
        } else {
            frame.origin.x = visibleFrame.minX
        }

        if frame.height <= visibleFrame.height {
            frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        } else {
            frame.origin.y = visibleFrame.maxY - frame.height
        }
        window.setFrame(frame, display: true, animate: false)
    }

    private func bestVisibleFrame(for frame: NSRect, window: NSWindow) -> NSRect? {
        let intersectingScreen = NSScreen.screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(frame).area < rhs.visibleFrame.intersection(frame).area
        }
        if let intersectingScreen, intersectingScreen.visibleFrame.intersects(frame) {
            return intersectingScreen.visibleFrame
        }

        return window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    }

    private func prepareAndWriteExport(
        projectMixSnapshots: [ProjectMixTrackSnapshot],
        fallbackDecodedAudioBuffer: DecodedAudioBuffer?,
        to destinationURL: URL
    ) {
        updateStatus("preparing export")
        Task { [weak self, projectMixSnapshots, fallbackDecodedAudioBuffer, destinationURL] in
            let result = await Task.detached(priority: .userInitiated) {
                if !projectMixSnapshots.isEmpty {
                    return try Self.makeProjectMix(
                        from: projectMixSnapshots,
                        outputURL: destinationURL
                    )?.buffer
                }

                return fallbackDecodedAudioBuffer
            }.result

            guard let self else {
                return
            }

            switch result {
            case let .success(buffer):
                guard let buffer, buffer.frameCount > 0 else {
                    self.updateStatus("export failed: no audio to write")
                    return
                }

                self.writeExport(buffer, to: destinationURL)
            case let .failure(error):
                self.updateStatus("export failed: \(error.localizedDescription)")
            }
        }
    }

    private func writeExport(_ decodedAudioBuffer: DecodedAudioBuffer, to destinationURL: URL) {
        updateStatus("exporting...")
        exportProgressOverlay.showExporting()
        let exportProgressOverlay = exportProgressOverlay

        Task { [weak self, decodedAudioBuffer, destinationURL] in
            do {
                let (exportURL, analysis) = try await Task.detached(priority: .userInitiated) {
                    let masteredExport = try PodcastExportProcessor.masteredForPodcast(decodedAudioBuffer)
                    Task { @MainActor in
                        exportProgressOverlay.updateProgress(0.2)
                    }

                    let exportURL = Self.normalizedAudioExportURL(destinationURL)
                    if CompressedAudioFileWriter.canWrite(to: exportURL) {
                        try CompressedAudioFileWriter.write(masteredExport.buffer, to: exportURL)
                        Task { @MainActor in
                            exportProgressOverlay.updateProgress(1)
                        }
                    } else {
                        try WAVFileWriter.write(masteredExport.buffer, to: exportURL) { progress in
                            Task { @MainActor in
                                exportProgressOverlay.updateProgress(0.2 + progress * 0.8)
                            }
                        }
                    }

                    return (exportURL, masteredExport.analysis)
                }.value

                guard let self else {
                    return
                }

                self.exportProgressOverlay.showComplete()
                self.updateStatus(
                    String(
                        format: "exported %@ (%.1f LUFS, %.1f dBTP)",
                        exportURL.lastPathComponent,
                        analysis.outputIntegratedLUFS,
                        analysis.outputTruePeakDBTP
                    )
                )
            } catch {
                guard let self else {
                    return
                }

                self.exportProgressOverlay.showFailure("Export failed.")
                self.updateStatus("export failed: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func normalizedAudioExportURL(_ destinationURL: URL) -> URL {
        destinationURL.pathExtension.isEmpty ? destinationURL.appendingPathExtension("wav") : destinationURL
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()

        let timer = Timer(timeInterval: 1 / playbackRefreshRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPlaybackProgress(syncPlayheadWhenPlaying: false)
            }
        }
        timer.tolerance = 1 / playbackRefreshRate * 0.2

        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func startLoudnessMeterTimer() {
        loudnessMeterTimer?.invalidate()

        let timer = Timer(timeInterval: 1 / loudnessMeterRefreshRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateLoudnessMeter()
            }
        }
        timer.tolerance = 1 / loudnessMeterRefreshRate * 0.25

        loudnessMeterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateLoudnessMeter() {
        let levels = currentLoudnessMeterLevels()
        loudnessMeter.display(levels: levels)
        transportControlPanel.displayOutputActivity(levels: levels)
    }

    private func currentLoudnessMeterLevels() -> LoudnessMeterLevels {
        if let latestMeterSample = playbackController.drainMeterSamples().last {
            return LoudnessMeterLevels(
                leftRMS: latestMeterSample.leftRMS,
                rightRMS: latestMeterSample.rightRMS,
                leftPeak: latestMeterSample.leftPeak,
                rightPeak: latestMeterSample.rightPeak
            )
        }

        let snapshot = playbackController.snapshot()
        guard snapshot.isPlaying, displayedDuration > 0 else {
            return .silence
        }

        let playheadProgress = projectedVisualPlayheadProgress(
            at: CACurrentMediaTime(),
            duration: displayedDuration
        )
        let playheadTime = min(max(TimeInterval(playheadProgress) * displayedDuration, 0), displayedDuration)
        return mixedLoudnessLevels(endingAt: playheadTime)
    }

    private func mixedLoudnessLevels(endingAt playheadTime: TimeInterval) -> LoudnessMeterLevels {
        guard !projectTracks.isEmpty else {
            return .silence
        }

        let outputSampleRate = max(displayedSampleRate, 44_100)
        let windowFrameCount = min(
            max(Int(outputSampleRate * 0.025), 192),
            fallbackLoudnessMaximumFrameCount
        )
        let windowDuration = Double(windowFrameCount - 1) / outputSampleRate
        let startTime = max(playheadTime - windowDuration, 0)
        let anySoloedTrack = projectTracks.contains { $0.isSoloed }
        let masterGain = volumeControl.perceptualVolume * volumeControl.perceptualVolume
        let audibleTracks = Array(projectTracks.lazy.filter { track in
            self.isProjectTrackAudible(track, anySoloedTrack: anySoloedTrack) &&
                track.volume > 0
        }.prefix(fallbackLoudnessMaximumAudibleTracks))
        guard !audibleTracks.isEmpty else {
            return .silence
        }

        var leftSquareSum: Double = 0
        var rightSquareSum: Double = 0
        var leftPeak: Float = 0
        var rightPeak: Float = 0
        var measuredFrameCount = 0

        for outputFrame in 0..<windowFrameCount {
            let sampleTime = startTime + Double(outputFrame) / outputSampleRate
            var leftSample: Float = 0
            var rightSample: Float = 0

            for track in audibleTracks {
                let trackGain = masterGain * track.volume * track.volume
                let trackSamples = loudnessSamples(
                    for: track,
                    at: sampleTime,
                    outputFrameIndex: outputFrame
                )
                leftSample += trackSamples.left * trackGain
                rightSample += trackSamples.right * trackGain
            }

            leftSquareSum += Double(leftSample) * Double(leftSample)
            rightSquareSum += Double(rightSample) * Double(rightSample)
            leftPeak = max(leftPeak, abs(leftSample))
            rightPeak = max(rightPeak, abs(rightSample))
            measuredFrameCount += 1
        }

        guard measuredFrameCount > 0 else {
            return .silence
        }

        return LoudnessMeterLevels(
            leftRMS: Float(sqrt(leftSquareSum / Double(measuredFrameCount))),
            rightRMS: Float(sqrt(rightSquareSum / Double(measuredFrameCount))),
            leftPeak: leftPeak,
            rightPeak: rightPeak
        )
    }

    private func loudnessSamples(
        for track: ProjectTrack,
        at sampleTime: TimeInterval,
        outputFrameIndex: Int
    ) -> (left: Float, right: Float) {
        if let decodedAudioBuffer = track.decodedAudioBuffer {
            guard
                sampleTime >= 0,
                sampleTime < decodedAudioBuffer.duration,
                decodedAudioBuffer.frameCount > 0
            else {
                return (0, 0)
            }

            let sourceFrame = min(
                max(Int((sampleTime * decodedAudioBuffer.sampleRate).rounded(.down)), 0),
                decodedAudioBuffer.frameCount - 1
            )
            let leftSample = loudnessSample(from: decodedAudioBuffer, channel: 0, frame: sourceFrame)
            let rightSample = decodedAudioBuffer.channelCount > 1 ?
                loudnessSample(from: decodedAudioBuffer, channel: 1, frame: sourceFrame) :
                leftSample
            return (leftSample, rightSample)
        }

        guard
            let overview = track.waveformOverview,
            overview.duration > 0,
            !overview.bins.isEmpty,
            sampleTime >= 0,
            sampleTime < overview.duration
        else {
            return (0, 0)
        }

        let progress = min(max(sampleTime / overview.duration, 0), 0.999_999)
        let binIndex = min(max(Int(progress * Double(overview.bins.count)), 0), overview.bins.count - 1)
        let bin = overview.bins[binIndex]
        let polarity: Float = outputFrameIndex.isMultiple(of: 2) ? 1 : -1
        let monoSample = max(bin.rmsSample, bin.peakMagnitude * 0.55) * polarity
        return (monoSample, monoSample)
    }

    private func loudnessSample(
        from decodedAudioBuffer: DecodedAudioBuffer,
        channel requestedChannel: Int,
        frame requestedFrame: Int
    ) -> Float {
        guard !decodedAudioBuffer.samplesByChannel.isEmpty else {
            return 0
        }

        let channel = min(max(requestedChannel, 0), decodedAudioBuffer.samplesByChannel.count - 1)
        let samples = decodedAudioBuffer.samplesByChannel[channel]
        guard !samples.isEmpty else {
            return 0
        }

        let frame = min(max(requestedFrame, 0), samples.count - 1)
        return samples[frame]
    }

    private func displayPlaybackVisuals(
        progress: Float,
        isPlaying: Bool,
        syncPlayhead: Bool = true,
        anchorTimestamp: TimeInterval? = nil,
        restartsFisheyeActivation: Bool = false,
        restartsPlayheadKick: Bool = false
    ) {
        let timestamp = anchorTimestamp ?? CACurrentMediaTime()
        let clampedProgress = min(max(progress, 0), 1)

        guard isPlaying, !syncPlayhead, visualPlaybackActive else {
            hardSyncPlaybackVisuals(
                progress: clampedProgress,
                isPlaying: isPlaying,
                anchorTimestamp: timestamp,
                restartsFisheyeActivation: restartsFisheyeActivation,
                restartsPlayheadKick: restartsPlayheadKick
            )
            return
        }

        gentlySyncPlaybackVisuals(
            progress: clampedProgress,
            anchorTimestamp: timestamp
        )
        displayPlaybackActiveIfNeeded(isPlaying)
    }

    private func hardSyncPlaybackVisuals(
        progress: Float,
        isPlaying: Bool,
        anchorTimestamp: TimeInterval,
        restartsFisheyeActivation: Bool = false,
        restartsPlayheadKick: Bool = false
    ) {
        let wasVisuallyPlaying = visualPlaybackActive
        visualPlayheadProgress = min(max(progress, 0), 1)
        visualPlayheadAnchorTimestamp = anchorTimestamp
        visualPlaybackActive = isPlaying
        lastVisualAudioCorrectionTimestamp = anchorTimestamp

        timelineSurface.displayPlayheadProgress(
            visualPlayheadProgress,
            syncRenderer: true,
            anchorTimestamp: anchorTimestamp,
            resetsTouchStart: isPlaying || !wasVisuallyPlaying,
            restartsFisheyeActivation: restartsFisheyeActivation,
            restartsPlayheadKick: restartsPlayheadKick
        )
        displayPlaybackActiveIfNeeded(isPlaying)
    }

    private func gentlySyncPlaybackVisuals(
        progress audioProgress: Float,
        anchorTimestamp audioTimestamp: TimeInterval
    ) {
        guard displayedDuration > 0 else {
            hardSyncPlaybackVisuals(
                progress: audioProgress,
                isPlaying: true,
                anchorTimestamp: audioTimestamp
            )
            return
        }

        let projectedProgress = projectedVisualPlayheadProgress(
            at: audioTimestamp,
            duration: displayedDuration
        )
        let correctionProgress = audioProgress - projectedProgress
        let correctionSeconds = TimeInterval(correctionProgress) * displayedDuration
        let absoluteCorrectionSeconds = abs(correctionSeconds)

        guard absoluteCorrectionSeconds > visualAudioSyncDeadband else {
            return
        }

        guard absoluteCorrectionSeconds < visualAudioSyncHardCorrectionThreshold else {
            hardSyncPlaybackVisuals(
                progress: audioProgress,
                isPlaying: true,
                anchorTimestamp: audioTimestamp
            )
            return
        }

        guard audioTimestamp - lastVisualAudioCorrectionTimestamp >= visualAudioSyncMinimumCorrectionInterval else {
            return
        }

        let correctionWeight = min(
            max(absoluteCorrectionSeconds / visualAudioSyncResponseDuration, 0.06),
            0.28
        )
        let correctedProgress = projectedProgress + correctionProgress * Float(correctionWeight)
        visualPlayheadProgress = min(max(correctedProgress, 0), 1)
        visualPlayheadAnchorTimestamp = audioTimestamp
        visualPlaybackActive = true
        lastVisualAudioCorrectionTimestamp = audioTimestamp

        timelineSurface.displayPlayheadProgress(
            visualPlayheadProgress,
            syncRenderer: false,
            anchorTimestamp: audioTimestamp
        )
    }

    private func projectedVisualPlayheadProgress(
        at timestamp: TimeInterval,
        duration: TimeInterval
    ) -> Float {
        guard visualPlaybackActive, duration.isFinite, duration > 0 else {
            return visualPlayheadProgress
        }

        let elapsedTime = timestamp - visualPlayheadAnchorTimestamp
        let projectedProgress = visualPlayheadProgress + Float(elapsedTime / duration)
        return min(max(projectedProgress, 0), 1)
    }

    private func displayPlaybackActiveIfNeeded(_ isPlaying: Bool) {
        visualPlaybackActive = isPlaying
        ImportWorkBudget.shared.setPlaybackActive(isPlaying)
        updateTransportControlState(isPlaying: isPlaying)
        guard displayedPlaybackActive != isPlaying else {
            return
        }

        displayedPlaybackActive = isPlaying
        timelineSurface.displayPlaybackActive(isPlaying)
    }

    private func refreshPlaybackProgress(
        syncPlayheadWhenPlaying: Bool = false,
        restartsFisheyeActivation: Bool = false,
        restartsPlayheadKick: Bool = false
    ) {
        let snapshot = playbackController.snapshot()
        currentPlayheadFrame = snapshot.frameIndex
        updateEffectCommandState()
        displayPlaybackVisuals(
            progress: snapshot.progress,
            isPlaying: snapshot.isPlaying,
            syncPlayhead: !snapshot.isPlaying || syncPlayheadWhenPlaying,
            anchorTimestamp: snapshot.hostTimestamp,
            restartsFisheyeActivation: restartsFisheyeActivation,
            restartsPlayheadKick: restartsPlayheadKick
        )
        updateTimeReadout()

        if !snapshot.isPlaying {
            stopPlaybackTimer()
            if snapshot.isAtEnd {
                updateStatus("finished")
            }
        }
    }

    private func updateSelection(_ selection: TimelineSelection?) {
        if !deadAirCandidates.isEmpty {
            clearDeadAirReview(publish: true)
        }
        if selectedTrackID != nil || !selectedTrackIDs.isEmpty {
            selectedTrackID = nil
            selectedTrackIDs.removeAll()
            trackSelectionAnchorID = nil
            publishSelectedTracksToTimeline()
            refreshTrackControls()
        }
        if let trackID = selection?.trackID {
            activeTrackID = trackID
            syncActiveTrackFields()
        }
        selectedTimelineRange = selection
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        updateEffectCommandState()
        updateStatus(currentPlaybackStatus)
    }

    private func updateFrameStats(_ frameStats: TimelineFrameStats) {
        SoundtimeDiagnostics.shared.recordFrameStats(frameStats)
        PerformanceDashboardWindowController.shared.display(frameStats: frameStats)
        frameRateHistoryView.display(frameStats: frameStats)
        guard debugToolsVisible else {
            return
        }

        let shaderBufferMegabytes = Int((Double(frameStats.shaderBufferByteCount) / 1_048_576).rounded())
        framesPerSecondLabel.stringValue = String(
            format: "%d fps %@ c%d g%d fx%d/%d p%d d%d k%d b%d/%dMB u%d/%d m%d +/-%.1f max %.1f",
            frameStats.framesPerSecond,
            frameStats.waveformRenderer,
            frameStats.cpuWaveformVertexCount,
            frameStats.gpuWaveformDrawCount,
            frameStats.effectVertexCount,
            frameStats.effectDroppedVertexCount,
            frameStats.transientParticleCount,
            frameStats.deletionEffectCount,
            frameStats.playheadContactEventCount,
            frameStats.shaderBufferCount,
            shaderBufferMegabytes,
            frameStats.shaderBufferUploadCount,
            frameStats.shaderBufferUploadInFlightCount,
            frameStats.waveformMipCacheCount,
            frameStats.frameTimeJitterMilliseconds,
            frameStats.worstFrameTimeMilliseconds
        )
    }

    private var canApplyGainEffect: Bool {
        guard
            let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            return false
        }

        let track = projectTracks[target.trackIndex]
        let hasEditableTimeline =
            track.audioTimeline != nil ||
            track.fileTimeline != nil ||
            WAVAudioDecoder.canDecode(track.sourceURL)
        return hasEditableTimeline && target.editSelection.durationProgress > 0
    }

    private var canApplyFadeEffect: Bool {
        guard
            let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            return false
        }

        let track = projectTracks[target.trackIndex]
        let hasEditableTimeline =
            track.audioTimeline != nil ||
            track.fileTimeline != nil ||
            WAVAudioDecoder.canDecode(track.sourceURL)
        return hasEditableTimeline && target.editSelection.durationProgress > 0
    }

    private var canSplitAtPlayhead: Bool {
        guard
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            return false
        }

        let projectProgress = playbackController.snapshot().progress
        return scopedTrackIndices(anchorTrackIndex: trackIndex, scope: editScope).contains { scopedTrackIndex in
            canSplitTrack(at: scopedTrackIndex, projectProgress: projectProgress)
        }
    }

    private func canSplitTrack(at trackIndex: Int, projectProgress: Float) -> Bool {
        guard projectTracks.indices.contains(trackIndex) else {
            return false
        }

        let track = projectTracks[trackIndex]
        let hasEditableTimeline =
            track.audioTimeline != nil ||
            track.fileTimeline != nil ||
            WAVAudioDecoder.canDecode(track.sourceURL)
        guard hasEditableTimeline else {
            return false
        }

        let insertionSelection = editInsertionSelection(
            forPlaybackProgress: projectProgress,
            trackIndex: trackIndex
        )
        return insertionSelection.startProgress > 0 && insertionSelection.startProgress < 1
    }

    private var canDeleteSilence: Bool {
        guard
            let target = silenceCleanupTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            return false
        }

        let track = projectTracks[target.trackIndex]
        return track.audioTimeline != nil ||
            track.fileTimeline != nil ||
            WAVAudioDecoder.canDecode(track.sourceURL)
    }

    private var canDeleteSelection: Bool {
        !selectedTrackIDs.isEmpty || selectedTrackID != nil || currentEditableSelectionTarget() != nil
    }

    private var canClearSelection: Bool {
        currentEditableSelectionTarget() != nil
    }

    private var canCopySelection: Bool {
        currentEditableSelectionTarget() != nil
    }

    private var canCutSelection: Bool {
        currentEditableSelectionTarget() != nil
    }

    private var canPasteAudio: Bool {
        audioClipboard != nil && activeProjectTrackIndex() != nil
    }

    private func isEditableRippleDeleteTarget(_ target: EditableSelectionTarget) -> Bool {
        guard
            projectTracks.indices.contains(target.trackIndex),
            target.editSelection.durationProgress > 0
        else {
            return false
        }

        let track = projectTracks[target.trackIndex]
        return track.audioTimeline != nil ||
            track.fileTimeline != nil ||
            WAVAudioDecoder.canDecode(track.sourceURL)
    }

    private func updateEditScopeHint() {
        editScopeControl.selectedSegment = editScope.rawValue

        guard
            let selectedTimelineRange,
            selectedTimelineRange.durationProgress > 0
        else {
            editScopeHintLabel.stringValue = ""
            return
        }

        if
            let selectedTrackID,
            isFullTrackSelection(selectedTimelineRange, trackID: selectedTrackID)
        {
            editScopeHintLabel.stringValue = "Backspace deletes track"
            return
        }

        guard let target = currentEditableSelectionTarget() else {
            editScopeHintLabel.stringValue = ""
            return
        }

        let affectedTrackCount = rippleDeleteTargets(for: target, scope: editScope)
            .filter(isEditableRippleDeleteTarget)
            .count
        guard affectedTrackCount > 0 else {
            editScopeHintLabel.stringValue = "No overlapping audio"
            return
        }

        switch editScope {
        case .track:
            editScopeHintLabel.stringValue = "Delete affects this track"
        case .selected:
            editScopeHintLabel.stringValue = affectedTrackCount == 1 ?
                "Delete affects selected track" :
                "Delete affects \(affectedTrackCount) selected tracks"
        case .group:
            editScopeHintLabel.stringValue = affectedTrackCount == 1 ?
                "Delete affects this group" :
                "Delete affects \(affectedTrackCount) grouped tracks"
        case .all:
            editScopeHintLabel.stringValue = affectedTrackCount == 1 ?
                "Delete affects 1 track" :
                "Delete affects \(affectedTrackCount) tracks"
        }
    }

    private func updateEffectCommandState() {
        timelineSurface.canApplyGainEffect = canApplyGainEffect
        timelineSurface.canApplyFadeEffect = canApplyFadeEffect
        timelineSurface.canReapplyLastEffect = canReapplyLastEffect
        timelineSurface.canSplitAtPlayhead = canSplitAtPlayhead
        timelineSurface.canCutSelection = canCutSelection
        timelineSurface.canCopySelection = canCopySelection
        timelineSurface.canPasteAudio = canPasteAudio
        timelineSurface.canDeleteSelection = canDeleteSelection
        timelineSurface.canClearSelection = canClearSelection
        timelineSurface.canDeleteSilence = canDeleteSilence
        timelineSurface.canUseDeadAirCandidate = activeDeadAirCandidate() != nil
        updateEditScopeHint()
    }

    private var canReapplyLastEffect: Bool {
        guard let lastEffect else {
            return false
        }

        switch lastEffect {
        case .gain, .normalize:
            return canApplyGainEffect
        case .fade:
            return canApplyFadeEffect
        }
    }

    private func updateStatus(_ status: String) {
        currentPlaybackStatus = status
        guard let loadedAudioSummary else {
            metadataLabel.stringValue = status
            return
        }

        if
            let selectedTimelineRange,
            displayedDuration > 0,
            selectedTimelineRange.durationProgress > 0
        {
            let selectedDuration = selectedTimelineRange.duration(in: displayedDuration)
            metadataLabel.stringValue = "\(loadedAudioSummary) - \(status) - selected \(formatDuration(selectedDuration))"
        } else {
            metadataLabel.stringValue = "\(loadedAudioSummary) - \(status)"
        }

        updateTimeReadout()
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1_000)
        }

        if duration < 60 {
            return String(format: "%.2f sec", duration)
        }

        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func updateLoadedAudioSummary(for decodedAudioBuffer: DecodedAudioBuffer) {
        if let selectedAudioFile {
            loadedAudioSummary = "\(selectedAudioFile.displayName) - \(decodedAudioBuffer.formattedSummary)"
        } else {
            loadedAudioSummary = decodedAudioBuffer.formattedSummary
        }
    }

    private func suggestedExportFilename() -> String {
        let baseName = selectedAudioFile?.url.deletingPathExtension().lastPathComponent ?? "Soundtime Export"
        return "\(baseName)-edited.wav"
    }

    private func suggestedProjectFilename() -> String {
        if let currentProjectURL {
            return currentProjectURL.deletingPathExtension().lastPathComponent
        }

        if let firstTrack = projectTracks.first {
            return firstTrack.name
        }

        return "Untitled"
    }

    private func normalizedProjectURL(_ url: URL) -> URL {
        let projectExtension = SoundtimeProjectStore.fileExtension
        var normalizedURL = url

        while normalizedURL.pathExtension == projectExtension {
            normalizedURL.deletePathExtension()
        }

        return normalizedURL.appendingPathExtension(projectExtension)
    }

    private func applyTimeline(_ audioTimeline: AudioEditTimeline) {
        self.audioTimeline = audioTimeline
        selectedTimelineRange = nil
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        updateEffectCommandState()
        currentPlayheadFrame = 0
        timelineSurface.displaySelection(nil)
        displayPlaybackVisuals(progress: 0, isPlaying: false)

        if
            let activeTrackID,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == activeTrackID })
        {
            projectTracks[trackIndex].editRevision += 1
            let editRevision = projectTracks[trackIndex].editRevision
            projectTracks[trackIndex].audioTimeline = audioTimeline
            projectTracks[trackIndex].decodedAudioBuffer = nil
            projectTracks[trackIndex].zeroCrossingIndex = nil
            projectTracks[trackIndex].durationHint = audioTimeline.duration

            decodedAudioBuffer = nil
            displayedFrameCount = audioTimeline.frameCount
            displayedSampleRate = audioTimeline.sourceAudioBuffer.sampleRate
            syncActiveTrackFields()
            refreshProjectTimelineDisplay()
            reloadPlaybackFromProjectTracks(preserveProgress: false)
            updateTimeReadout()

            materializeEditedTimeline(
                trackID: activeTrackID,
                timeline: audioTimeline,
                editRevision: editRevision,
                status: "track ready",
                startDelay: editMaterializationDelay
            )
        } else {
            decodedAudioBuffer = nil
            displayedFrameCount = audioTimeline.frameCount
            displayedSampleRate = audioTimeline.sourceAudioBuffer.sampleRate
            refreshProjectTimelineDisplay()
            updateTimeReadout()
        }
    }

    private func updateTimeReadout() {
        guard displayedFrameCount > 0, displayedSampleRate > 0 else {
            timeReadoutLabel.stringValue = "00:00.000 / 00:00.000"
            return
        }

        if let selectedTimelineRange, selectedTimelineRange.durationProgress > 0 {
            let selectionStart = TimeInterval(selectedTimelineRange.startProgress) * displayedDuration
            let selectionEnd = TimeInterval(selectedTimelineRange.endProgress) * displayedDuration
            timeReadoutLabel.stringValue = "sel \(formatClockTime(selectionStart))-\(formatClockTime(selectionEnd))"
            return
        }

        let playheadFrame: Int
        if visualPlaybackActive {
            let projectedProgress = projectedVisualPlayheadProgress(
                at: CACurrentMediaTime(),
                duration: displayedDuration
            )
            playheadFrame = Int((projectedProgress * Float(displayedFrameCount)).rounded(.down))
        } else {
            playheadFrame = currentPlayheadFrame
        }

        let playheadTime = Double(min(playheadFrame, displayedFrameCount)) / displayedSampleRate
        timeReadoutLabel.stringValue = "\(formatClockTime(playheadTime)) / \(formatClockTime(displayedDuration))"
    }

    private var displayedDuration: TimeInterval {
        guard displayedFrameCount > 0, displayedSampleRate > 0 else {
            return 0
        }

        return Double(displayedFrameCount) / displayedSampleRate
    }

    private func formatClockTime(_ duration: TimeInterval) -> String {
        let clampedDuration = max(duration, 0)
        let totalMilliseconds = Int((clampedDuration * 1_000).rounded(.down))
        let milliseconds = totalMilliseconds % 1_000
        let totalSeconds = totalMilliseconds / 1_000
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
        }

        return String(format: "%02d:%02d.%03d", minutes, seconds, milliseconds)
    }

    private func clampAudioSample(_ sample: Float) -> Float {
        min(max(sample, -1), 1)
    }

    private func smoothstep(_ progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        return clampedProgress * clampedProgress * (3 - 2 * clampedProgress)
    }
}

private final class TimelineTuningSliderView: NSView {
    var onValueChanged: ((Double) -> Void)?

    var value: Double {
        get {
            slider.doubleValue
        }
        set {
            slider.doubleValue = min(max(newValue, range.lowerBound), range.upperBound)
            updateValueLabel()
        }
    }

    private let titleLabel: NSTextField
    private let valueLabel: NSTextField
    private let slider = NSSlider()
    private let range: ClosedRange<Double>
    private let valueFormat: String

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    init(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        valueFormat: String
    ) {
        self.range = range
        self.valueFormat = valueFormat
        titleLabel = NSTextField(labelWithString: title)
        valueLabel = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        slider.doubleValue = min(max(value, range.lowerBound), range.upperBound)
        configure()
        updateValueLabel()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = NSColor(white: 0.72, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        valueLabel.textColor = NSColor(white: 0.88, alpha: 1)
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byClipping
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(slider)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -6),

            valueLabel.topAnchor.constraint(equalTo: topAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 48),

            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -2),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        updateValueLabel()
        onValueChanged?(sender.doubleValue)
    }

    private func updateValueLabel() {
        valueLabel.stringValue = String(format: valueFormat, slider.doubleValue)
    }
}

private extension CGRect {
    var area: CGFloat {
        max(width, 0) * max(height, 0)
    }
}
