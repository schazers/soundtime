import AppKit
import QuartzCore
import UniformTypeIdentifiers

final class WorkspaceView: NSView {
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
        case fade(FadeEffect)
    }

    private struct ProjectTrack {
        var id: UUID
        var name: String
        var sourceURL: URL
        var durationHint: TimeInterval?
        var waveformOverview: WaveformOverview?
        var decodedAudioBuffer: DecodedAudioBuffer?
        var zeroCrossingIndex: AudioZeroCrossingIndex?
        var zeroCrossingProbe: WAVZeroCrossingProbe?
        var audioTimeline: AudioEditTimeline?
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
        var selectedTimelineRange: TimelineSelection?
    }

    private enum UndoAction {
        case timeline(trackID: UUID?, timeline: AudioEditTimeline)
        case projectTracks(ProjectTrackUndoSnapshot)
    }

    private struct AudioClipboard: Sendable {
        let buffer: DecodedAudioBuffer
        let waveformOverview: WaveformOverview
    }

    private struct ProjectMixTrackSnapshot: Sendable {
        let volume: Float
        let decodedAudioBuffer: DecodedAudioBuffer
        let zeroCrossingIndex: AudioZeroCrossingIndex?
    }

    private struct ProjectMixResult: Sendable {
        let buffer: DecodedAudioBuffer
        let zeroCrossingIndex: AudioZeroCrossingIndex
        let trackCount: Int
    }

    private var projectTracks: [ProjectTrack] = []
    private var activeTrackID: UUID?
    private var selectedTrackID: UUID?
    private var currentProjectURL: URL?
    private var hasRestoredLastProject = false
    private var isLoadingProject = false
    private var audioClipboard: AudioClipboard?
    private var activeImportID = UUID()
    private var selectedAudioFile: AudioFileMetadata?
    private var decodedAudioBuffer: DecodedAudioBuffer?
    private var audioTimeline: AudioEditTimeline?
    private var editUndoStack: [UndoAction] = []
    private var loadedAudioSummary: String?
    private var selectedTimelineRange: TimelineSelection?
    private var lastEffect: LastEffect?
    private var currentPlayheadFrame = 0
    private var displayedFrameCount = 0
    private var displayedSampleRate: Double = 0
    private var currentPlaybackStatus = "idle"
    private var playbackTimer: Timer?
    private var loudnessMeterTimer: Timer?
    private var keyDownMonitor: Any?
    private let playbackController: PlaybackEngine = PlaybackEngineFactory.makeDefault()
    private let playbackRefreshRate: TimeInterval = 10
    private let loudnessMeterRefreshRate: TimeInterval = 60
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
    ]
    private let optimisticEditPreviewBinLimit = 65_536
    private let optimisticEditPreviewSamplesPerBin = 4

    private struct WAVPreviewLevel {
        let targetBinCount: Int
        let samplesPerBin: Int
    }

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Soundtime")
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = NSColor.labelColor
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
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
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.alignment = .right
        label.textColor = NSColor.secondaryLabelColor
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let framesPerSecondLabel: NSTextField = {
        let label = NSTextField(labelWithString: "0 fps - +/-0.0 max 0.0")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .right
        label.textColor = NSColor.secondaryLabelColor
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let volumeControl = VolumeControlView()
    private let loudnessMeter = LoudnessMeterView()
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
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()
    private let trackControlsStack: NSStackView = {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.distribution = .fillEqually
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()
    private let timelineSurface = TimelineView()
    private let exportProgressOverlay = ExportProgressOverlayView()
    private let gainEffectOverlay = GainEffectOverlayView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = SoundtimeColors.windowBackground.cgColor
        installTransportKeyMonitor()

        timelineSurface.translatesAutoresizingMaskIntoConstraints = false
        timelineSurface.onAudioFileDropped = { [weak self] url in
            self?.loadDroppedAudioFile(at: url)
        }
        timelineSurface.onTogglePlayback = { [weak self] in
            self?.togglePlayback()
        }
        timelineSurface.onDeleteSelection = { [weak self] in
            self?.deleteSelectedTrackOrSelection()
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
        timelineSurface.onGainRequested = { [weak self] in
            self?.showGainEffect()
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
        timelineSurface.onFrameStatsChanged = { [weak self] frameStats in
            self?.updateFrameStats(frameStats)
        }
        timelineSurface.onTimelineInteractionBegan = { [weak self] in
            self?.clearSelectedTrack()
        }
        volumeControl.onVolumeChanged = { [weak self] volume in
            self?.playbackController.setPerceptualVolume(volume)
            self?.updateLoudnessMeter()
        }
        configureFisheyeTuningControls()
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
        addSubview(volumeControl)
        addSubview(timeReadoutLabel)
        addSubview(loudnessMeter)
        addSubview(fisheyeControlsStack)
        addSubview(trackControlsStack)
        addSubview(timelineSurface)
        addSubview(exportProgressOverlay)
        addSubview(gainEffectOverlay)

        let fisheyeTrailingConstraint = fisheyeControlsStack.trailingAnchor.constraint(
            lessThanOrEqualTo: loudnessMeter.leadingAnchor,
            constant: -18
        )
        fisheyeTrailingConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 84),

            metadataLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            metadataLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 14),
            metadataLabel.trailingAnchor.constraint(equalTo: framesPerSecondLabel.leadingAnchor, constant: -14),

            framesPerSecondLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            framesPerSecondLabel.trailingAnchor.constraint(equalTo: volumeControl.leadingAnchor, constant: -12),
            framesPerSecondLabel.widthAnchor.constraint(equalToConstant: 248),

            volumeControl.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            volumeControl.trailingAnchor.constraint(equalTo: timeReadoutLabel.leadingAnchor, constant: -18),
            volumeControl.widthAnchor.constraint(equalToConstant: 150),
            volumeControl.heightAnchor.constraint(equalToConstant: 24),

            timeReadoutLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            timeReadoutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),

            loudnessMeter.topAnchor.constraint(equalTo: volumeControl.bottomAnchor, constant: 6),
            loudnessMeter.trailingAnchor.constraint(equalTo: timeReadoutLabel.trailingAnchor),
            loudnessMeter.widthAnchor.constraint(equalToConstant: 292),
            loudnessMeter.heightAnchor.constraint(equalToConstant: 34),

            fisheyeControlsStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            fisheyeControlsStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            fisheyeTrailingConstraint,
            fisheyeControlsStack.heightAnchor.constraint(equalToConstant: 34),

            trackControlsStack.topAnchor.constraint(equalTo: fisheyeControlsStack.bottomAnchor, constant: 14),
            trackControlsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            trackControlsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
            trackControlsStack.widthAnchor.constraint(equalToConstant: 118),

            timelineSurface.topAnchor.constraint(equalTo: trackControlsStack.topAnchor),
            timelineSurface.leadingAnchor.constraint(equalTo: trackControlsStack.trailingAnchor, constant: 10),
            timelineSurface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            timelineSurface.bottomAnchor.constraint(equalTo: trackControlsStack.bottomAnchor),

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
        updateLoudnessMeter()
        startLoudnessMeterTimer()
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
            fisheyeControlsStack.addArrangedSubview(control)
            control.widthAnchor.constraint(equalToConstant: 136).isActive = true
        }
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

    private func handleWindowKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else {
            return event
        }

        if event.keyCode == 6, event.modifierFlags.contains(.command) {
            undoLastEdit()
            return nil
        }

        if
            (event.keyCode == 51 || event.keyCode == 117),
            selectedTrackID != nil,
            !event.modifierFlags.contains(.command)
        {
            deleteSelectedTrack()
            return nil
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

        guard let lastProjectURL = SoundtimeProjectStore.lastProjectURL() else {
            return
        }

        loadProject(from: lastProjectURL)
    }

    private func refreshProjectTimelineDisplay(rebuildControls: Bool = true) {
        timelineSurface.displayTracks(timelineRenderTracks())
        timelineSurface.displaySelectedTrack(selectedTrackID)
        if rebuildControls {
            refreshTrackControls()
        }
    }

    private func refreshProjectTrackMixDisplay() {
        timelineSurface.displayTrackMixSettings(timelineRenderTracks())
    }

    private func timelineRenderTracks() -> [TimelineRenderState.Track] {
        projectTracks.map { track in
            TimelineRenderState.Track(
                id: track.id,
                waveformVersion: waveformVersion(for: track),
                waveformOverview: track.waveformOverview,
                durationHint: track.waveformOverview?.duration ?? track.decodedAudioBuffer?.duration ?? track.durationHint,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed
            )
        }
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
        let existingSubviews = trackControlsStack.arrangedSubviews
        for subview in existingSubviews {
            trackControlsStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        for track in projectTracks {
            let controlView = TrackControlView(title: track.name)
            controlView.isMuted = track.isMuted
            controlView.isSoloed = track.isSoloed
            controlView.volume = track.volume
            controlView.isTrackSelected = track.id == selectedTrackID
            controlView.onTrackSelected = { [weak self, trackID = track.id] in
                self?.selectTrack(trackID)
            }
            controlView.onMuteChanged = { [weak self, trackID = track.id] isMuted in
                self?.updateTrack(trackID) { $0.isMuted = isMuted }
            }
            controlView.onSoloChanged = { [weak self, trackID = track.id] isSoloed in
                self?.updateTrack(trackID) { $0.isSoloed = isSoloed }
            }
            controlView.onVolumeChanged = { [weak self, trackID = track.id] volume in
                self?.updateTrack(trackID) { $0.volume = volume }
            }
            controlView.onVolumeEditingEnded = { [weak self] in
                self?.updateProjectPlaybackTrackMix()
            }
            trackControlsStack.addArrangedSubview(controlView)
        }
    }

    private func selectTrack(_ trackID: UUID) {
        guard projectTracks.contains(where: { $0.id == trackID }) else {
            return
        }

        selectedTrackID = trackID
        activeTrackID = trackID
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        timelineSurface.displaySelectedTrack(trackID)
        refreshTrackControls()
        syncActiveTrackFields()
        updateEffectCommandState()
        updateStatus(currentPlaybackStatus)
    }

    private func clearSelectedTrack() {
        guard selectedTrackID != nil else {
            return
        }

        selectedTrackID = nil
        timelineSurface.displaySelectedTrack(nil)
        refreshTrackControls()
    }

    private func updateTrack(
        _ trackID: UUID,
        update: (inout ProjectTrack) -> Void
    ) {
        guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        update(&projectTracks[trackIndex])
        activeTrackID = trackID
        refreshProjectTrackMixDisplay()
        updateProjectPlaybackTrackMix()
        updateStatus(currentPlaybackStatus)
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
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        timelineSurface.displaySelectedTrack(nil)
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
        let durationHint = try? WAVAudioDecoder.inspect(url: url).duration
        let track = ProjectTrack(
            id: trackID,
            name: trackName,
            sourceURL: url,
            durationHint: durationHint,
            waveformOverview: nil,
            decodedAudioBuffer: nil,
            zeroCrossingIndex: nil,
            zeroCrossingProbe: nil,
            audioTimeline: nil,
            volume: settings?.volume ?? 1,
            isMuted: settings?.isMuted ?? false,
            isSoloed: settings?.isSoloed ?? false,
            importID: importID,
            editRevision: 0
        )

        projectTracks.append(track)
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

        await Task.yield()
        return isCurrent() && !Task.isCancelled
    }

    private func removeProjectTrack(_ trackID: UUID) {
        projectTracks.removeAll { $0.id == trackID }
        if activeTrackID == trackID {
            activeTrackID = projectTracks.last?.id
        }
        if selectedTrackID == trackID {
            selectedTrackID = nil
            timelineSurface.displaySelectedTrack(nil)
        }
        syncActiveTrackFields()
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(preserveProgress: false)
    }

    private func applyTrackPreview(trackID: UUID, previewResult: WAVPreviewImportResult) {
        guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        projectTracks[trackIndex].name = previewResult.metadata.displayName
        projectTracks[trackIndex].durationHint = previewResult.fileInfo.duration
        projectTracks[trackIndex].waveformOverview = previewResult.waveformOverview
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

        projectTracks[trackIndex].waveformOverview = waveformOverview
        projectTracks[trackIndex].durationHint = fileInfo.duration
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

        projectTracks[trackIndex].decodedAudioBuffer = decodedAudioBuffer
        projectTracks[trackIndex].waveformOverview = waveformOverview
        projectTracks[trackIndex].durationHint = decodedAudioBuffer.duration
        projectTracks[trackIndex].zeroCrossingIndex = zeroCrossingIndex
        projectTracks[trackIndex].audioTimeline = AudioEditTimeline(sourceBuffer: decodedAudioBuffer)
        let shouldReloadPlayback = projectTracks[trackIndex].editRevision != 0 || !playbackController.hasSource
        activeTrackID = trackID
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming(sampleRateHint: decodedAudioBuffer.sampleRate)
        if shouldReloadPlayback {
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

        decodedAudioBuffer = activeTrack.decodedAudioBuffer ?? decodedAudioBuffer
        audioTimeline = activeTrack.audioTimeline
        if let duration = activeTrack.waveformOverview?.duration {
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
            max(result, track.waveformOverview?.duration ?? track.decodedAudioBuffer?.duration ?? track.durationHint ?? 0)
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

    private func reloadPlaybackFromProjectTracks(preserveProgress: Bool) {
        let previousSnapshot = playbackController.snapshot()
        let previousProgress = previousSnapshot.progress
        let wasPlaying = previousSnapshot.isPlaying
        let playbackTracks = projectPlaybackTracks()

        guard !playbackTracks.isEmpty else {
            playbackController.clear()
            currentPlayheadFrame = 0
            displayPlaybackVisuals(progress: 0, isPlaying: false)
            updateTimeReadout()
            return
        }

        do {
            try playbackController.loadProjectTracks(playbackTracks)
            if preserveProgress {
                try playbackController.seek(toProgress: previousProgress)
                if wasPlaying {
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
        playbackController.updateProjectTrackMix(projectPlaybackTracks())
    }

    private func projectMixBuffer() -> DecodedAudioBuffer? {
        Self.makeProjectMix(
            from: projectMixTrackSnapshots(),
            outputURL: currentProjectURL ?? URL(fileURLWithPath: "Soundtime Project Mix.wav")
        )?.buffer
    }

    private func projectPlaybackTracks() -> [ProjectPlaybackTrack] {
        return projectTracks.compactMap { track -> ProjectPlaybackTrack? in
            let source: ProjectPlaybackTrack.Source
            if track.editRevision == 0, WAVAudioDecoder.canDecode(track.sourceURL) {
                source = .file(
                    url: track.sourceURL,
                    zeroCrossingProbe: track.zeroCrossingProbe
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

    private func projectMixTrackSnapshots() -> [ProjectMixTrackSnapshot] {
        audibleProjectTracks.compactMap { track in
            guard let decodedAudioBuffer = track.decodedAudioBuffer else {
                return nil
            }

            return ProjectMixTrackSnapshot(
                volume: track.volume,
                decodedAudioBuffer: decodedAudioBuffer,
                zeroCrossingIndex: track.zeroCrossingIndex
            )
        }
    }

    private nonisolated static func makeProjectMix(
        from decodedTracks: [ProjectMixTrackSnapshot],
        outputURL: URL
    ) -> ProjectMixResult? {
        guard let firstTrack = decodedTracks.first else {
            return nil
        }

        let firstBuffer = firstTrack.decodedAudioBuffer
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
        let channelCount = max(decodedTracks.map(\.decodedAudioBuffer.channelCount).max() ?? 2, 2)
        let frameCount = decodedTracks.reduce(0) { result, item in
            max(result, item.decodedAudioBuffer.frameCount)
        }
        guard frameCount > 0 else {
            return nil
        }

        var samplesByChannel = (0..<channelCount).map { _ in
            [Float](repeating: 0, count: frameCount)
        }

        for track in decodedTracks {
            let buffer = track.decodedAudioBuffer
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

    private func materializeEditedTimeline(
        trackID: UUID,
        timeline: AudioEditTimeline,
        editRevision: Int,
        status: String,
        preservePlaybackProgress: Bool = false
    ) {
        Task { [weak self, trackID, timeline, editRevision, status, preservePlaybackProgress] in
            let materialized = await Task.detached(priority: .userInitiated) {
                Self.materializeTimeline(timeline)
            }.value

            guard let self else {
                return
            }

            self.applyMaterializedTrackEdit(
                trackID: trackID,
                editRevision: editRevision,
                materialized: materialized,
                status: status,
                preservePlaybackProgress: preservePlaybackProgress
            )
        }
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
        preservePlaybackProgress: Bool = false
    ) {
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            projectTracks[trackIndex].editRevision == editRevision
        else {
            return
        }

        projectTracks[trackIndex].decodedAudioBuffer = materialized.buffer
        projectTracks[trackIndex].audioTimeline = materialized.timeline
        projectTracks[trackIndex].waveformOverview = materialized.waveformOverview
        projectTracks[trackIndex].zeroCrossingIndex = materialized.zeroCrossingIndex
        activeTrackID = trackID
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming(sampleRateHint: materialized.buffer.sampleRate)
        reloadPlaybackFromProjectTracks(preserveProgress: preservePlaybackProgress)
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
        with replacement: WaveformOverview?
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

        let startIndex = min(max(Int((selection.startProgress * Float(binCount)).rounded(.down)), 0), binCount)
        let endIndex = min(max(Int((selection.endProgress * Float(binCount)).rounded(.up)), startIndex), binCount)
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
        let nextDuration = max(sourceOverview.duration - removedDuration + (replacementOverview?.duration ?? 0), 0)
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

        let startIndex = min(max(Int((selection.startProgress * Float(binCount)).rounded(.down)), 0), binCount)
        let endIndex = min(max(Int((selection.endProgress * Float(binCount)).rounded(.up)), startIndex), binCount)
        guard startIndex < endIndex else {
            return sourceOverview
        }

        var bins = sourceOverview.bins
        for index in startIndex..<endIndex {
            bins[index] = bins[index].scaled(by: gain)
        }

        return WaveformOverview(duration: sourceOverview.duration, bins: bins)
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

    private func deleteSelection() {
        performOptimisticDelete(copyBeforeDeleting: false)
    }

    private func deleteSelectedTrackOrSelection() {
        if selectedTrackID != nil {
            deleteSelectedTrack()
        } else {
            deleteSelection()
        }
    }

    private func deleteSelectedTrack() {
        guard
            let selectedTrackID,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == selectedTrackID })
        else {
            return
        }

        let snapshot = ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTimelineRange: selectedTimelineRange
        )
        editUndoStack.append(.projectTracks(snapshot))

        let deletedTrackName = projectTracks[trackIndex].name
        projectTracks.remove(at: trackIndex)
        if projectTracks.isEmpty {
            activeTrackID = nil
        } else {
            activeTrackID = projectTracks[min(trackIndex, projectTracks.count - 1)].id
        }
        self.selectedTrackID = nil
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        timelineSurface.displaySelectedTrack(nil)
        syncActiveTrackFields()
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        updateEffectCommandState()
        updateStatus("deleted track \(deletedTrackName)")
    }

    private func cutSelection() {
        performOptimisticDelete(copyBeforeDeleting: true)
    }

    private func copySelection() {
        guard
            let currentTimeline = activeProjectTrack?.audioTimeline,
            let selectedTimelineRange,
            selectedTimelineRange.durationProgress > 0
        else {
            return
        }

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
            self.updateStatus("copied \(self.formatDuration(clipboard.buffer.duration))")
        }
    }

    private func pasteAudio() {
        guard
            let audioClipboard,
            let trackIndex = activeProjectTrackIndex(),
            let currentTimeline = projectTracks[trackIndex].audioTimeline
        else {
            return
        }

        let pasteSelection = selectedTimelineRange ??
            TimelineSelection(
                startProgress: playbackController.snapshot().progress,
                endProgress: playbackController.snapshot().progress,
                trackID: projectTracks[trackIndex].id
            )
        let currentOverview = projectTracks[trackIndex].waveformOverview
        let trackID = projectTracks[trackIndex].id
        editUndoStack.append(.timeline(trackID: trackID, timeline: currentTimeline))
        projectTracks[trackIndex].editRevision += 1
        let editRevision = projectTracks[trackIndex].editRevision

        projectTracks[trackIndex].waveformOverview = optimisticWaveformOverview(
            currentOverview,
            replacing: pasteSelection,
            with: audioClipboard.waveformOverview
        )
        projectTracks[trackIndex].decodedAudioBuffer = nil
        projectTracks[trackIndex].zeroCrossingIndex = nil
        projectTracks[trackIndex].audioTimeline = nil
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        stopPlaybackTimer()
        playbackController.clear()
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming()
        updateEffectCommandState()
        updateStatus("pasting")

        Task { [weak self, currentTimeline, pasteSelection, audioClipboard, trackID, editRevision] in
            do {
                let materialized = try await Task.detached(priority: .userInitiated) {
                    try Self.materializePaste(
                        timeline: currentTimeline,
                        selection: pasteSelection,
                        clipboardBuffer: audioClipboard.buffer
                    )
                }.value

                guard let self else {
                    return
                }

                self.applyMaterializedTrackEdit(
                    trackID: trackID,
                    editRevision: editRevision,
                    materialized: materialized,
                    status: "pasted \(self.formatDuration(audioClipboard.buffer.duration))"
                )
            } catch {
                guard let self else {
                    return
                }
                self.updateStatus("paste failed: \(error.localizedDescription)")
            }
        }
    }

    private func performOptimisticDelete(copyBeforeDeleting: Bool) {
        guard
            let trackIndex = activeProjectTrackIndex(),
            let selectionToDelete = selectedTimelineRange,
            selectionToDelete.durationProgress > 0,
            let currentTimeline = projectTracks[trackIndex].audioTimeline
        else {
            return
        }

        if copyBeforeDeleting {
            copySelection()
        }

        var editedTimeline = currentTimeline
        let deletedStartProgress = selectionToDelete.startProgress
        let deletedDuration = selectionToDelete.duration(in: currentTimeline.duration)
        let deletedFrameCount = editedTimeline.delete(selectionToDelete)
        guard deletedFrameCount > 0 else {
            return
        }

        let trackID = projectTracks[trackIndex].id
        editUndoStack.append(.timeline(trackID: trackID, timeline: currentTimeline))
        projectTracks[trackIndex].editRevision += 1
        let editRevision = projectTracks[trackIndex].editRevision
        projectTracks[trackIndex].audioTimeline = editedTimeline
        projectTracks[trackIndex].decodedAudioBuffer = nil
        projectTracks[trackIndex].zeroCrossingIndex = nil
        projectTracks[trackIndex].waveformOverview = optimisticWaveformOverview(
            projectTracks[trackIndex].waveformOverview,
            replacing: selectionToDelete,
            with: nil
        )

        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        stopPlaybackTimer()
        playbackController.clear()
        displayPlaybackVisuals(progress: deletedStartProgress, isPlaying: false)
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming()
        updateEffectCommandState()
        updateStatus("\(copyBeforeDeleting ? "cut" : "deleted") \(formatDuration(deletedDuration))")

        materializeEditedTimeline(
            trackID: trackID,
            timeline: editedTimeline,
            editRevision: editRevision,
            status: "\(copyBeforeDeleting ? "cut" : "deleted") \(formatDuration(deletedDuration))"
        )
    }

    private func trimTimeline(to trimRange: TimelineTrimRange) {
        guard
            let currentTimeline = audioTimeline,
            trimRange.trimsAudio
        else {
            return
        }

        var editedTimeline = currentTimeline
        let originalDuration = currentTimeline.duration
        let trimmedFrameCount = editedTimeline.trim(to: trimRange)
        guard trimmedFrameCount > 0 else {
            return
        }

        editUndoStack.append(.timeline(trackID: activeTrackID, timeline: currentTimeline))
        applyTimeline(editedTimeline)
        updateStatus("trimmed \(formatDuration(originalDuration - editedTimeline.duration))")
    }

    private func showGainEffect() {
        guard canApplyGainEffect else {
            return
        }

        gainEffectOverlay.show()
    }

    private func reapplyLastEffect() {
        guard
            canApplyGainEffect,
            let lastEffect
        else {
            return
        }

        switch lastEffect {
        case let .gain(decibels):
            let gain = GainEffectOverlayView.linearGain(forDecibels: decibels)
            applyGainEffect(decibels: decibels, gain: gain)
        case let .fade(fadeEffect):
            applyFadeEffect(fadeEffect)
        }
    }

    private func previewSelectedGain(_ gain: Float) {
        guard let selectedTimelineRange, canApplyGainEffect else {
            timelineSurface.displayGainPreview(selection: nil, gain: 1)
            return
        }

        timelineSurface.displayGainPreview(selection: selectedTimelineRange, gain: gain)
    }

    private func cancelSelectedGainPreview() {
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        updateStatus(currentPlaybackStatus)
    }

    private func confirmSelectedGain(decibels: Double, gain: Float) {
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        applyGainEffect(decibels: decibels, gain: gain)
    }

    private func applyGainEffect(decibels: Double, gain: Float) {
        guard
            let trackIndex = activeProjectTrackIndex(),
            let selectionToApply = selectedTimelineRange,
            selectionToApply.durationProgress > 0,
            let currentTimeline = projectTracks[trackIndex].audioTimeline
        else {
            return
        }

        var editedTimeline = currentTimeline
        let affectedFrameCount = editedTimeline.applyGain(gain, to: selectionToApply)
        guard affectedFrameCount > 0 else {
            return
        }

        let trackID = projectTracks[trackIndex].id
        editUndoStack.append(.timeline(trackID: trackID, timeline: currentTimeline))
        projectTracks[trackIndex].editRevision += 1
        let editRevision = projectTracks[trackIndex].editRevision
        projectTracks[trackIndex].audioTimeline = editedTimeline
        projectTracks[trackIndex].decodedAudioBuffer = nil
        projectTracks[trackIndex].zeroCrossingIndex = nil
        projectTracks[trackIndex].waveformOverview = optimisticWaveformOverview(
            projectTracks[trackIndex].waveformOverview,
            applyingGain: gain,
            to: selectionToApply
        )
        lastEffect = .gain(decibels: decibels)
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming()
        updateEffectCommandState()
        updateStatus(String(format: "gain %+.1f dB", decibels))

        materializeEditedTimeline(
            trackID: trackID,
            timeline: editedTimeline,
            editRevision: editRevision,
            status: String(format: "gain %+.1f dB", decibels),
            preservePlaybackProgress: true
        )
    }

    private func applyFadeEffect(_ fadeEffect: FadeEffect) {
        guard
            let currentTimeline = audioTimeline,
            let selectedTimelineRange,
            selectedTimelineRange.durationProgress > 0
        else {
            return
        }

        let renderedBuffer = currentTimeline.render()
        let startFrame = min(
            max(Int((selectedTimelineRange.startProgress * Float(renderedBuffer.frameCount)).rounded(.down)), 0),
            renderedBuffer.frameCount
        )
        let endFrame = min(
            max(Int((selectedTimelineRange.endProgress * Float(renderedBuffer.frameCount)).rounded(.up)), startFrame),
            renderedBuffer.frameCount
        )
        guard endFrame - startFrame > 1 else {
            return
        }

        var samplesByChannel = renderedBuffer.samplesByChannel
        let selectedFrameCount = endFrame - startFrame
        for channelIndex in samplesByChannel.indices {
            guard startFrame < samplesByChannel[channelIndex].count else {
                continue
            }

            let clampedEndFrame = min(endFrame, samplesByChannel[channelIndex].count)
            for frameIndex in startFrame..<clampedEndFrame {
                let offset = frameIndex - startFrame
                let progress = Float(offset) / Float(max(selectedFrameCount - 1, 1))
                let curve = smoothstep(progress)
                let gain: Float
                switch fadeEffect {
                case .fadeIn:
                    gain = curve
                case .fadeOut:
                    gain = 1 - curve
                }

                samplesByChannel[channelIndex][frameIndex] = clampAudioSample(
                    samplesByChannel[channelIndex][frameIndex] * gain
                )
            }
        }

        let editedBuffer = DecodedAudioBuffer(
            url: renderedBuffer.url,
            sampleRate: renderedBuffer.sampleRate,
            channelCount: renderedBuffer.channelCount,
            frameCount: renderedBuffer.frameCount,
            samplesByChannel: samplesByChannel
        )
        let editedTimeline = AudioEditTimeline(sourceBuffer: editedBuffer)
        editUndoStack.append(.timeline(trackID: activeTrackID, timeline: currentTimeline))
        lastEffect = .fade(fadeEffect)
        applyTimeline(editedTimeline)
        updateStatus("\(fadeEffect.displayName) \(formatDuration(selectedTimelineRange.duration(in: renderedBuffer.duration)))")
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
        projectTracks = snapshot.tracks
        activeTrackID = snapshot.activeTrackID.flatMap { activeID in
            projectTracks.contains(where: { $0.id == activeID }) ? activeID : nil
        } ?? projectTracks.last?.id
        selectedTrackID = snapshot.selectedTrackID.flatMap { selectedID in
            projectTracks.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }
        selectedTimelineRange = snapshot.selectedTimelineRange
        syncActiveTrackFields()
        timelineSurface.displaySelection(selectedTimelineRange)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        timelineSurface.displaySelectedTrack(selectedTrackID)
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        updateEffectCommandState()
        updateStatus("undo track delete")
    }

    private func togglePlayback() {
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
        let exportBuffer = projectMixBuffer() ?? decodedAudioBuffer
        guard let exportBuffer, exportBuffer.frameCount > 0 else {
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Export WAV"
        savePanel.nameFieldStringValue = suggestedExportFilename()
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.allowedContentTypes = [.wav]

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, exportBuffer] response in
            guard
                response == .OK,
                let destinationURL = savePanel.url
            else {
                return
            }

            self?.writeExport(exportBuffer, to: destinationURL)
        }

        if let window {
            savePanel.beginSheetModal(for: window, completionHandler: completion)
        } else if savePanel.runModal() == .OK, let destinationURL = savePanel.url {
            writeExport(exportBuffer, to: destinationURL)
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
            let projectURL = normalizedProjectURL(url)
            try SoundtimeProjectStore.save(currentProject(), to: projectURL)
            currentProjectURL = projectURL
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
            try SoundtimeProjectStore.save(currentProject(), to: currentProjectURL)
        } catch {
            updateStatus("project window save failed: \(error.localizedDescription)")
        }
    }

    private func loadProject(from url: URL) {
        if currentProjectURL != nil, currentProjectURL != url {
            persistCurrentProjectWindowLayout()
        }

        do {
            let project = try SoundtimeProjectStore.load(from: url)
            clearProjectForLoad()
            currentProjectURL = url
            SoundtimeProjectStore.rememberLastProjectURL(url)
            applyWindowLayout(project.windowLayout)
            resetWaveformFisheyeTuningToDefaults()
            isLoadingProject = true
            for track in project.tracks {
                addDroppedWAVTrack(
                    at: URL(fileURLWithPath: track.filePath),
                    settings: track
                )
            }
            isLoadingProject = false
            reloadPlaybackFromProjectTracks(preserveProgress: false)
            window?.title = projectWindowTitle()
            updateLoadedProjectSummary()
            updateStatus(playbackController.hasSource ? "project ready - resolving waveforms" : "project loading")
        } catch {
            isLoadingProject = false
            updateStatus("project open failed: \(error.localizedDescription)")
        }
    }

    private func clearProjectForLoad() {
        playbackController.clear()
        projectTracks.removeAll()
        activeTrackID = nil
        selectedTrackID = nil
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
        timelineSurface.displaySelectedTrack(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        refreshProjectTimelineDisplay()
        displayPlaybackVisuals(progress: 0, isPlaying: false)
        updateTimeReadout()
        updateEffectCommandState()
    }

    private func currentProject() -> SoundtimeProject {
        SoundtimeProject(
            tracks: projectTracks.map { track in
                SoundtimeProject.Track(
                    id: track.id,
                    name: track.name,
                    filePath: track.sourceURL.path,
                    volume: track.volume,
                    isMuted: track.isMuted,
                    isSoloed: track.isSoloed
                )
            },
            windowLayout: currentWindowLayout()
        )
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

        frame.size.width = min(frame.width, visibleFrame.width)
        frame.size.height = min(frame.height, visibleFrame.height)
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
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

    private func writeExport(_ decodedAudioBuffer: DecodedAudioBuffer, to destinationURL: URL) {
        updateStatus("exporting...")
        exportProgressOverlay.showExporting()
        let exportProgressOverlay = exportProgressOverlay

        Task { [weak self, decodedAudioBuffer, destinationURL] in
            do {
                let exportURL = destinationURL.pathExtension.isEmpty ?
                    destinationURL.appendingPathExtension("wav") :
                    destinationURL

                try await Task.detached(priority: .userInitiated) {
                    try WAVFileWriter.write(decodedAudioBuffer, to: exportURL) { progress in
                        Task { @MainActor in
                            exportProgressOverlay.updateProgress(progress)
                        }
                    }
                }.value

                guard let self else {
                    return
                }

                self.exportProgressOverlay.showComplete()
                self.updateStatus("exported \(exportURL.lastPathComponent)")
            } catch {
                guard let self else {
                    return
                }

                self.exportProgressOverlay.showFailure("Export failed.")
                self.updateStatus("export failed: \(error.localizedDescription)")
            }
        }
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
        loudnessMeter.display(levels: currentLoudnessMeterLevels())
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
        let windowFrameCount = min(max(Int(outputSampleRate * 0.025), 384), 1_024)
        let windowDuration = Double(windowFrameCount - 1) / outputSampleRate
        let startTime = max(playheadTime - windowDuration, 0)
        let anySoloedTrack = projectTracks.contains { $0.isSoloed }
        let masterGain = volumeControl.perceptualVolume * volumeControl.perceptualVolume

        var leftSquareSum: Double = 0
        var rightSquareSum: Double = 0
        var leftPeak: Float = 0
        var rightPeak: Float = 0
        var measuredFrameCount = 0

        for outputFrame in 0..<windowFrameCount {
            let sampleTime = startTime + Double(outputFrame) / outputSampleRate
            var leftSample: Float = 0
            var rightSample: Float = 0

            for track in projectTracks {
                guard
                    isProjectTrackAudible(track, anySoloedTrack: anySoloedTrack),
                    track.volume > 0
                else {
                    continue
                }

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
        selectedTimelineRange = selection
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        updateEffectCommandState()
        updateStatus(currentPlaybackStatus)
    }

    private func updateFrameStats(_ frameStats: TimelineFrameStats) {
        framesPerSecondLabel.stringValue = String(
            format: "%d fps %@ c%d g%d u%d +/-%.1f max %.1f",
            frameStats.framesPerSecond,
            frameStats.waveformRenderer,
            frameStats.cpuWaveformVertexCount,
            frameStats.gpuWaveformDrawCount,
            frameStats.shaderBufferUploadCount,
            frameStats.frameTimeJitterMilliseconds,
            frameStats.worstFrameTimeMilliseconds
        )
    }

    private var canApplyGainEffect: Bool {
        guard
            let trackIndex = activeProjectTrackIndex(),
            projectTracks[trackIndex].audioTimeline != nil,
            projectTracks[trackIndex].decodedAudioBuffer != nil,
            let selectedTimelineRange
        else {
            return false
        }

        return selectedTimelineRange.durationProgress > 0
    }

    private func updateEffectCommandState() {
        timelineSurface.canApplyGainEffect = canApplyGainEffect
        timelineSurface.canApplyFadeEffect = canApplyGainEffect
        timelineSurface.canReapplyLastEffect = lastEffect != nil && canApplyGainEffect
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
        stopPlaybackTimer()

        let renderedBuffer = audioTimeline.render()
        decodedAudioBuffer = renderedBuffer
        displayedFrameCount = renderedBuffer.frameCount
        displayedSampleRate = renderedBuffer.sampleRate
        timelineSurface.displaySelection(nil)
        displayPlaybackVisuals(progress: 0, isPlaying: false)

        let waveformOverview = WaveformOverviewBuilder.build(from: renderedBuffer)
        let zeroCrossingIndex = AudioZeroCrossingIndex.build(from: renderedBuffer)
        if
            let activeTrackID,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == activeTrackID })
        {
            projectTracks[trackIndex].decodedAudioBuffer = renderedBuffer
            projectTracks[trackIndex].audioTimeline = audioTimeline
            projectTracks[trackIndex].waveformOverview = waveformOverview
            projectTracks[trackIndex].zeroCrossingIndex = zeroCrossingIndex
        }

        refreshProjectTimelineDisplay()
        reloadPlaybackFromProjectTracks(preserveProgress: false)
        updateLoadedAudioSummary(for: renderedBuffer)
        updateTimeReadout()
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
