import AppKit

final class WorkspaceView: NSView {
    private var activeImportID = UUID()
    private var selectedAudioFile: AudioFileMetadata?
    private var decodedAudioBuffer: DecodedAudioBuffer?
    private var loadedAudioSummary: String?
    private var playbackTimer: Timer?
    private let playbackController = AudioPlaybackController()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Soundtime")
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = NSColor.labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let metadataLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Drop audio here")
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = NSColor.secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let timelineSurface = TimelineView()

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
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        timelineSurface.translatesAutoresizingMaskIntoConstraints = false
        timelineSurface.onAudioFileDropped = { [weak self] url in
            self?.loadDroppedAudioFile(at: url)
        }
        timelineSurface.onTogglePlayback = { [weak self] in
            self?.togglePlayback()
        }

        addSubview(titleLabel)
        addSubview(metadataLabel)
        addSubview(timelineSurface)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),

            metadataLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            metadataLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 14),
            metadataLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -22),

            timelineSurface.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            timelineSurface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            timelineSurface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            timelineSurface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
        ])
    }

    private func loadDroppedAudioFile(at url: URL) {
        let importID = UUID()
        activeImportID = importID
        selectedAudioFile = nil
        decodedAudioBuffer = nil
        loadedAudioSummary = nil
        playbackTimer?.invalidate()
        playbackTimer = nil
        playbackController.clear()
        timelineSurface.displayWaveform(nil)
        timelineSurface.displayPlayheadProgress(0)
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
                    self.loadedAudioSummary = nil
                    self.playbackController.clear()
                    self.timelineSurface.displayPlayheadProgress(0)
                    self.metadataLabel.stringValue = "\(result.metadata.formattedSummary) - WAV decode not available yet"
                case let .decoded(decodedAudioBuffer, waveformOverview):
                    self.decodedAudioBuffer = decodedAudioBuffer
                    try self.playbackController.load(decodedAudioBuffer)
                    self.timelineSurface.displayWaveform(waveformOverview)
                    self.timelineSurface.displayPlayheadProgress(0)
                    self.loadedAudioSummary = "\(result.metadata.displayName) - \(decodedAudioBuffer.formattedSummary)"
                    self.updateStatus("press Space to play")
                case let .failed(message):
                    self.decodedAudioBuffer = nil
                    self.loadedAudioSummary = nil
                    self.playbackController.clear()
                    self.timelineSurface.displayPlayheadProgress(0)
                    self.timelineSurface.displayWaveform(nil)
                    self.metadataLabel.stringValue = "\(result.metadata.formattedSummary) - WAV decode failed: \(message)"
                }
            } catch {
                guard let self, self.activeImportID == importID else {
                    return
                }

                self.selectedAudioFile = nil
                self.decodedAudioBuffer = nil
                self.loadedAudioSummary = nil
                self.playbackController.clear()
                self.timelineSurface.displayPlayheadProgress(0)
                self.timelineSurface.displayWaveform(nil)
                self.metadataLabel.stringValue = "\(url.lastPathComponent) - could not load audio"
            }
        }
    }

    private func togglePlayback() {
        guard decodedAudioBuffer != nil else {
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
        timelineSurface.displayPlayheadProgress(snapshot.progress)

        if !snapshot.isPlaying {
            stopPlaybackTimer()
            if snapshot.isAtEnd {
                updateStatus("finished")
            }
        }
    }

    private func updateStatus(_ status: String) {
        guard let loadedAudioSummary else {
            metadataLabel.stringValue = status
            return
        }

        metadataLabel.stringValue = "\(loadedAudioSummary) - \(status)"
    }
}
