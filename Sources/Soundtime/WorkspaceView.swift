import AppKit
import UniformTypeIdentifiers

final class WorkspaceView: NSView {
    private var activeImportID = UUID()
    private var selectedAudioFile: AudioFileMetadata?
    private var decodedAudioBuffer: DecodedAudioBuffer?
    private var audioTimeline: AudioEditTimeline?
    private var editUndoStack: [AudioEditTimeline] = []
    private var loadedAudioSummary: String?
    private var selectedTimelineRange: TimelineSelection?
    private var currentPlayheadFrame = 0
    private var currentPlaybackStatus = "idle"
    private var playbackTimer: Timer?
    private let playbackController = AudioPlaybackController()

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

    private let timelineSurface = TimelineView()
    private let exportProgressOverlay = ExportProgressOverlayView()

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
        timelineSurface.onSeekRequested = { [weak self] progress in
            self?.seek(to: progress)
        }
        timelineSurface.onSelectionChanged = { [weak self] selection in
            self?.updateSelection(selection)
        }
        timelineSurface.onTrimRequested = { [weak self] trimRange in
            self?.trimTimeline(to: trimRange)
        }

        addSubview(titleLabel)
        addSubview(metadataLabel)
        addSubview(timeReadoutLabel)
        addSubview(timelineSurface)
        addSubview(exportProgressOverlay)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 84),

            metadataLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            metadataLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 14),
            metadataLabel.trailingAnchor.constraint(equalTo: timeReadoutLabel.leadingAnchor, constant: -14),

            timeReadoutLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            timeReadoutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),

            timelineSurface.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            timelineSurface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            timelineSurface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            timelineSurface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),

            exportProgressOverlay.topAnchor.constraint(equalTo: topAnchor),
            exportProgressOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            exportProgressOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            exportProgressOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
        currentPlayheadFrame = 0
        currentPlaybackStatus = "idle"
        playbackTimer?.invalidate()
        playbackTimer = nil
        playbackController.clear()
        timelineSurface.displayWaveform(nil)
        timelineSurface.displaySelection(nil)
        timelineSurface.displayPlayheadProgress(0)
        updateTimeReadout()
        metadataLabel.stringValue = "\(url.lastPathComponent) - loading..."

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
                    self.currentPlayheadFrame = 0
                    self.currentPlaybackStatus = "idle"
                    self.playbackController.clear()
                    self.timelineSurface.displaySelection(nil)
                    self.timelineSurface.displayPlayheadProgress(0)
                    self.updateTimeReadout()
                    self.metadataLabel.stringValue = "\(result.metadata.formattedSummary) - WAV decode not available yet"
                case let .decoded(decodedAudioBuffer, waveformOverview):
                    self.decodedAudioBuffer = decodedAudioBuffer
                    self.audioTimeline = AudioEditTimeline(sourceBuffer: decodedAudioBuffer)
                    self.editUndoStack.removeAll()
                    self.currentPlayheadFrame = 0
                    try self.playbackController.load(decodedAudioBuffer)
                    self.timelineSurface.displayWaveform(waveformOverview)
                    self.timelineSurface.displayPlayheadProgress(0)
                    self.loadedAudioSummary = "\(result.metadata.displayName) - \(decodedAudioBuffer.formattedSummary)"
                    self.selectedTimelineRange = nil
                    self.currentPlaybackStatus = "press Space to play"
                    self.updateStatus("press Space to play")
                case let .failed(message):
                    self.decodedAudioBuffer = nil
                    self.audioTimeline = nil
                    self.editUndoStack.removeAll()
                    self.loadedAudioSummary = nil
                    self.selectedTimelineRange = nil
                    self.currentPlayheadFrame = 0
                    self.currentPlaybackStatus = "idle"
                    self.playbackController.clear()
                    self.timelineSurface.displaySelection(nil)
                    self.timelineSurface.displayPlayheadProgress(0)
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
                self.currentPlayheadFrame = 0
                self.currentPlaybackStatus = "idle"
                self.playbackController.clear()
                self.timelineSurface.displaySelection(nil)
                self.timelineSurface.displayPlayheadProgress(0)
                self.timelineSurface.displayWaveform(nil)
                self.updateTimeReadout()
                self.metadataLabel.stringValue = "\(url.lastPathComponent) - could not load audio"
            }
        }
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

    private func undoLastEdit() {
        guard let previousTimeline = editUndoStack.popLast() else {
            return
        }

        applyTimeline(previousTimeline)
        updateStatus("undo")
    }

    private func togglePlayback() {
        guard let decodedAudioBuffer, decodedAudioBuffer.frameCount > 0 else {
            return
        }

        do {
            let isPlaying = try playbackController.togglePlayback()
            refreshPlaybackProgress()

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
        guard let decodedAudioBuffer, decodedAudioBuffer.frameCount > 0 else {
            return
        }

        do {
            try playbackController.seek(toProgress: progress)
            refreshPlaybackProgress()

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

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPlaybackProgress()
            }
        }

        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func refreshPlaybackProgress() {
        let snapshot = playbackController.snapshot()
        currentPlayheadFrame = snapshot.frameIndex
        timelineSurface.displayPlayheadProgress(snapshot.progress)
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
        updateStatus(currentPlaybackStatus)
    }

    private func updateStatus(_ status: String) {
        currentPlaybackStatus = status
        guard let loadedAudioSummary else {
            metadataLabel.stringValue = status
            return
        }

        if
            let selectedTimelineRange,
            let decodedAudioBuffer,
            selectedTimelineRange.durationProgress > 0
        {
            let selectedDuration = selectedTimelineRange.duration(in: decodedAudioBuffer.duration)
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
        currentPlayheadFrame = 0
        stopPlaybackTimer()

        let renderedBuffer = audioTimeline.render()
        decodedAudioBuffer = renderedBuffer
        timelineSurface.displaySelection(nil)
        timelineSurface.displayPlayheadProgress(0)
        playbackController.clear()

        if renderedBuffer.frameCount > 0 {
            do {
                try playbackController.load(renderedBuffer)
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
        guard let decodedAudioBuffer, decodedAudioBuffer.frameCount > 0 else {
            timeReadoutLabel.stringValue = "00:00.000 / 00:00.000"
            return
        }

        if let selectedTimelineRange, selectedTimelineRange.durationProgress > 0 {
            let selectionStart = TimeInterval(selectedTimelineRange.startProgress) * decodedAudioBuffer.duration
            let selectionEnd = TimeInterval(selectedTimelineRange.endProgress) * decodedAudioBuffer.duration
            timeReadoutLabel.stringValue = "sel \(formatClockTime(selectionStart))-\(formatClockTime(selectionEnd))"
            return
        }

        let playheadTime = Double(min(currentPlayheadFrame, decodedAudioBuffer.frameCount)) / decodedAudioBuffer.sampleRate
        timeReadoutLabel.stringValue = "\(formatClockTime(playheadTime)) / \(formatClockTime(decodedAudioBuffer.duration))"
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
}
