import AppKit
import QuartzCore
import UniformTypeIdentifiers

final class WorkspaceView: NSView {
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

    private var activeImportID = UUID()
    private var selectedAudioFile: AudioFileMetadata?
    private var decodedAudioBuffer: DecodedAudioBuffer?
    private var audioTimeline: AudioEditTimeline?
    private var editUndoStack: [AudioEditTimeline] = []
    private var loadedAudioSummary: String?
    private var selectedTimelineRange: TimelineSelection?
    private var lastEffect: LastEffect?
    private var currentPlayheadFrame = 0
    private var displayedFrameCount = 0
    private var displayedSampleRate: Double = 0
    private var currentPlaybackStatus = "idle"
    private var playbackTimer: Timer?
    private let playbackController: PlaybackEngine = AudioPlaybackController()
    private let playbackRefreshRate: TimeInterval = 30
    private var visualPlayheadProgress: Float = 0
    private var visualPlayheadAnchorTimestamp = CACurrentMediaTime()
    private var visualPlaybackActive = false
    private var displayedPlaybackActive: Bool?
    private var lastVisualAudioCorrectionTimestamp = CACurrentMediaTime()
    private let visualAudioSyncDeadband: TimeInterval = 0.006
    private let visualAudioSyncHardCorrectionThreshold: TimeInterval = 0.075
    private let visualAudioSyncResponseDuration: TimeInterval = 0.12
    private let visualAudioSyncMinimumCorrectionInterval: TimeInterval = 1.0 / 30.0
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
    private let touchTrailDurationSlider = EffectTuningSliderView(
        title: "Trail",
        minimumValue: 80,
        maximumValue: 700,
        value: 440,
        valueFormatter: { String(format: "%.0f ms", $0) }
    )
    private let touchTrailCurveSlider = EffectTuningSliderView(
        title: "Curve",
        minimumValue: 0.35,
        maximumValue: 2.5,
        value: 2.11,
        valueFormatter: { String(format: "%.2f", $0) }
    )
    private let waveformGraySlider = EffectTuningSliderView(
        title: "Gray",
        minimumValue: 0.55,
        maximumValue: 0.95,
        value: 0.88,
        valueFormatter: { String(format: "%.2f", $0) }
    )
    private let tuningControlsStack: NSStackView = {
        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 16
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

        timelineSurface.translatesAutoresizingMaskIntoConstraints = false
        timelineSurface.onAudioFileDropped = { [weak self] url in
            self?.loadDroppedAudioFile(at: url)
        }
        timelineSurface.onTogglePlayback = { [weak self] in
            self?.togglePlayback()
        }
        timelineSurface.onDeleteSelection = { [weak self] in
            self?.deleteSelection()
        }
        timelineSurface.onUndo = { [weak self] in
            self?.undoLastEdit()
        }
        timelineSurface.onExportRequested = { [weak self] in
            self?.exportCurrentAudio()
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
        volumeControl.onVolumeChanged = { [weak self] volume in
            self?.playbackController.setPerceptualVolume(volume)
        }
        touchTrailDurationSlider.onValueChanged = { [weak self] _ in
            self?.updateWaveformTouchTuning()
        }
        touchTrailCurveSlider.onValueChanged = { [weak self] _ in
            self?.updateWaveformTouchTuning()
        }
        waveformGraySlider.onValueChanged = { [weak self] _ in
            self?.updateWaveformTouchTuning()
        }
        gainEffectOverlay.onGainChanged = { [weak self] _, gain in
            self?.previewSelectedGain(gain)
        }
        gainEffectOverlay.onConfirm = { [weak self] decibels, gain in
            self?.confirmSelectedGain(decibels: decibels, gain: gain)
        }
        gainEffectOverlay.onCancel = { [weak self] in
            self?.cancelSelectedGainPreview()
        }

        tuningControlsStack.addArrangedSubview(touchTrailDurationSlider)
        tuningControlsStack.addArrangedSubview(touchTrailCurveSlider)
        tuningControlsStack.addArrangedSubview(waveformGraySlider)

        addSubview(titleLabel)
        addSubview(metadataLabel)
        addSubview(framesPerSecondLabel)
        addSubview(volumeControl)
        addSubview(timeReadoutLabel)
        addSubview(tuningControlsStack)
        addSubview(timelineSurface)
        addSubview(exportProgressOverlay)
        addSubview(gainEffectOverlay)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 84),

            metadataLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            metadataLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 14),
            metadataLabel.trailingAnchor.constraint(equalTo: framesPerSecondLabel.leadingAnchor, constant: -14),

            framesPerSecondLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            framesPerSecondLabel.trailingAnchor.constraint(equalTo: volumeControl.leadingAnchor, constant: -12),
            framesPerSecondLabel.widthAnchor.constraint(equalToConstant: 164),

            volumeControl.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            volumeControl.trailingAnchor.constraint(equalTo: timeReadoutLabel.leadingAnchor, constant: -18),
            volumeControl.widthAnchor.constraint(equalToConstant: 150),
            volumeControl.heightAnchor.constraint(equalToConstant: 24),

            timeReadoutLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            timeReadoutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),

            tuningControlsStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            tuningControlsStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            tuningControlsStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -22),
            tuningControlsStack.heightAnchor.constraint(equalToConstant: 28),

            touchTrailDurationSlider.widthAnchor.constraint(equalToConstant: 238),
            touchTrailCurveSlider.widthAnchor.constraint(equalToConstant: 220),
            waveformGraySlider.widthAnchor.constraint(equalToConstant: 220),

            timelineSurface.topAnchor.constraint(equalTo: tuningControlsStack.bottomAnchor, constant: 14),
            timelineSurface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            timelineSurface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            timelineSurface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),

            exportProgressOverlay.topAnchor.constraint(equalTo: topAnchor),
            exportProgressOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            exportProgressOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            exportProgressOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),

            gainEffectOverlay.topAnchor.constraint(equalTo: topAnchor),
            gainEffectOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            gainEffectOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            gainEffectOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        updateWaveformTouchTuning()
        updateEffectCommandState()
    }

    private func loadDroppedAudioFile(at url: URL) {
        let importID = UUID()
        activeImportID = importID
        selectedAudioFile = nil
        decodedAudioBuffer = nil
        audioTimeline = nil
        editUndoStack.removeAll()
        loadedAudioSummary = nil
        selectedTimelineRange = nil
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
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
                    let (decodedAudioBuffer, waveformOverview, zeroCrossingIndex) =
                        try await AudioImportPipeline.loadDecodedWAV(at: url)

                    guard self.activeImportID == importID else {
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
            playbackController.updateZeroCrossingIndex(zeroCrossingIndex)
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
        guard
            let currentTimeline = audioTimeline,
            let selectedTimelineRange,
            selectedTimelineRange.durationProgress > 0
        else {
            return
        }

        var editedTimeline = currentTimeline
        let deletedDuration = selectedTimelineRange.duration(in: currentTimeline.duration)
        let deletedFrameCount = editedTimeline.delete(selectedTimelineRange)
        guard deletedFrameCount > 0 else {
            return
        }

        editUndoStack.append(currentTimeline)
        applyTimeline(editedTimeline)
        updateStatus("deleted \(formatDuration(deletedDuration))")
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

        editUndoStack.append(currentTimeline)
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
        guard startFrame < endFrame else {
            return
        }

        var samplesByChannel = renderedBuffer.samplesByChannel
        for channelIndex in samplesByChannel.indices {
            guard startFrame < samplesByChannel[channelIndex].count else {
                continue
            }

            let clampedEndFrame = min(endFrame, samplesByChannel[channelIndex].count)
            for frameIndex in startFrame..<clampedEndFrame {
                samplesByChannel[channelIndex][frameIndex] = clampAudioSample(samplesByChannel[channelIndex][frameIndex] * gain)
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
        editUndoStack.append(currentTimeline)
        lastEffect = .gain(decibels: decibels)
        applyTimeline(editedTimeline)
        updateStatus(String(format: "gain %+.1f dB", decibels))
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
        editUndoStack.append(currentTimeline)
        lastEffect = .fade(fadeEffect)
        applyTimeline(editedTimeline)
        updateStatus("\(fadeEffect.displayName) \(formatDuration(selectedTimelineRange.duration(in: renderedBuffer.duration)))")
    }

    private func undoLastEdit() {
        guard let previousTimeline = editUndoStack.popLast() else {
            return
        }

        applyTimeline(previousTimeline)
        updateStatus("undo")
    }

    private func togglePlayback() {
        guard playbackController.hasSource else {
            return
        }

        do {
            let isPlaying = try playbackController.togglePlayback()
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
            try playbackController.seek(toProgress: progress)
            refreshPlaybackProgress(syncPlayheadWhenPlaying: true)

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
            try playbackController.seek(toProgress: progress)

            if !playbackController.isPlaying {
                try playbackController.play()
            }

            refreshPlaybackProgress(syncPlayheadWhenPlaying: true)
            startPlaybackTimer()
            updateStatus("playing")
        } catch {
            stopPlaybackTimer()
            updateStatus("playback failed: \(error.localizedDescription)")
        }
    }

    private func exportCurrentAudio() {
        guard let decodedAudioBuffer, decodedAudioBuffer.frameCount > 0 else {
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Export WAV"
        savePanel.nameFieldStringValue = suggestedExportFilename()
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.allowedContentTypes = [.wav]

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, decodedAudioBuffer] response in
            guard
                response == .OK,
                let destinationURL = savePanel.url
            else {
                return
            }

            self?.writeExport(decodedAudioBuffer, to: destinationURL)
        }

        if let window {
            savePanel.beginSheetModal(for: window, completionHandler: completion)
        } else if savePanel.runModal() == .OK, let destinationURL = savePanel.url {
            writeExport(decodedAudioBuffer, to: destinationURL)
        }
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

    private func displayPlaybackVisuals(
        progress: Float,
        isPlaying: Bool,
        syncPlayhead: Bool = true,
        anchorTimestamp: TimeInterval? = nil
    ) {
        let timestamp = anchorTimestamp ?? CACurrentMediaTime()
        let clampedProgress = min(max(progress, 0), 1)

        guard isPlaying, !syncPlayhead, visualPlaybackActive else {
            hardSyncPlaybackVisuals(
                progress: clampedProgress,
                isPlaying: isPlaying,
                anchorTimestamp: timestamp
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
        anchorTimestamp: TimeInterval
    ) {
        visualPlayheadProgress = min(max(progress, 0), 1)
        visualPlayheadAnchorTimestamp = anchorTimestamp
        visualPlaybackActive = isPlaying
        lastVisualAudioCorrectionTimestamp = anchorTimestamp

        timelineSurface.displayPlayheadProgress(
            visualPlayheadProgress,
            syncRenderer: true,
            anchorTimestamp: anchorTimestamp
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

        let elapsedTime = max(timestamp - visualPlayheadAnchorTimestamp, 0)
        let projectedProgress = visualPlayheadProgress + Float(elapsedTime / duration)
        return min(max(projectedProgress, 0), 1)
    }

    private func displayPlaybackActiveIfNeeded(_ isPlaying: Bool) {
        visualPlaybackActive = isPlaying
        guard displayedPlaybackActive != isPlaying else {
            return
        }

        displayedPlaybackActive = isPlaying
        timelineSurface.displayPlaybackActive(isPlaying)
    }

    private func refreshPlaybackProgress(syncPlayheadWhenPlaying: Bool = false) {
        let snapshot = playbackController.snapshot()
        currentPlayheadFrame = snapshot.frameIndex
        displayPlaybackVisuals(
            progress: snapshot.progress,
            isPlaying: snapshot.isPlaying,
            syncPlayhead: !snapshot.isPlaying || syncPlayheadWhenPlaying,
            anchorTimestamp: snapshot.hostTimestamp
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
            format: "%d fps - +/-%.1f max %.1f",
            frameStats.framesPerSecond,
            frameStats.frameTimeJitterMilliseconds,
            frameStats.worstFrameTimeMilliseconds
        )
    }

    private func updateWaveformTouchTuning() {
        timelineSurface.updateWaveformTouchTuning(
            trailDuration: touchTrailDurationSlider.value / 1_000,
            trailFalloffSteepness: Float(touchTrailCurveSlider.value),
            waveformGray: Float(waveformGraySlider.value)
        )
    }

    private var canApplyGainEffect: Bool {
        guard
            audioTimeline != nil,
            decodedAudioBuffer != nil,
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
        playbackController.clear()

        if renderedBuffer.frameCount > 0 {
            do {
                let zeroCrossingIndex = AudioZeroCrossingIndex.build(from: renderedBuffer)
                try playbackController.load(renderedBuffer, zeroCrossingIndex: zeroCrossingIndex)
            } catch {
                updateStatus("playback failed: \(error.localizedDescription)")
            }
        }

        let waveformOverview = WaveformOverviewBuilder.build(from: renderedBuffer)
        timelineSurface.displayWaveform(waveformOverview)
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

        let playheadTime = Double(min(currentPlayheadFrame, displayedFrameCount)) / displayedSampleRate
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

private final class EffectTuningSliderView: NSView {
    var value: Double {
        slider.doubleValue
    }

    var onValueChanged: ((Double) -> Void)?

    private let titleLabel: NSTextField
    private let valueLabel: NSTextField
    private let slider: NSSlider
    private let valueFormatter: (Double) -> String

    init(
        title: String,
        minimumValue: Double,
        maximumValue: Double,
        value: Double,
        valueFormatter: @escaping (Double) -> String
    ) {
        titleLabel = NSTextField(labelWithString: title)
        valueLabel = NSTextField(labelWithString: valueFormatter(value))
        slider = NSSlider(value: value, minValue: minimumValue, maxValue: maximumValue, target: nil, action: nil)
        self.valueFormatter = valueFormatter
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = NSColor.secondaryLabelColor
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.textColor = NSColor.secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(slider)
        addSubview(valueLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 36),

            slider.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),

            valueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 58),
        ])
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        valueLabel.stringValue = valueFormatter(sender.doubleValue)
        onValueChanged?(sender.doubleValue)
    }
}
