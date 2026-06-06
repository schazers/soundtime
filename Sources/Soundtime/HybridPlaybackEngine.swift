import Foundation

@MainActor
final class HybridPlaybackEngine: PlaybackEngine {
    private enum ActiveEngine {
        case preview
        case realtime
        case multitrack
    }

    private let previewEngine = AudioPlaybackController()
    private let multitrackEngine = MultitrackPlaybackController()
    private let realtimeEngine: RealtimeCorePlaybackEngine?
    private var activeEngine: ActiveEngine = .preview
    private var perceptualVolume: Float = 1
    private var sourcePreparationTask: Task<Void, Never>?
    private var sourcePreparationID = UUID()

    private var currentEngine: PlaybackEngine {
        switch activeEngine {
        case .preview:
            return previewEngine
        case .realtime:
            return realtimeEngine ?? previewEngine
        case .multitrack:
            return multitrackEngine
        }
    }

    var isPlaying: Bool {
        currentEngine.isPlaying
    }

    var hasSource: Bool {
        currentEngine.hasSource
    }

    init(realtimeEngine: RealtimeCorePlaybackEngine? = RealtimeCorePlaybackEngine()) {
        self.realtimeEngine = realtimeEngine
        self.realtimeEngine?.setPerceptualVolume(perceptualVolume)
        previewEngine.setPerceptualVolume(perceptualVolume)
        multitrackEngine.setPerceptualVolume(perceptualVolume)
    }

    func setPerceptualVolume(_ volume: Float) {
        perceptualVolume = min(max(volume, 0), 1)
        previewEngine.setPerceptualVolume(perceptualVolume)
        realtimeEngine?.setPerceptualVolume(perceptualVolume)
        multitrackEngine.setPerceptualVolume(perceptualVolume)
    }

    func load(
        _ decodedAudioBuffer: DecodedAudioBuffer,
        zeroCrossingIndex: AudioZeroCrossingIndex? = nil
    ) throws {
        cancelSourcePreparation()
        multitrackEngine.clear()
        if let realtimeEngine {
            previewEngine.clear()
            try realtimeEngine.load(decodedAudioBuffer, zeroCrossingIndex: zeroCrossingIndex)
            realtimeEngine.setPerceptualVolume(perceptualVolume)
            activeEngine = .realtime
        } else {
            try previewEngine.load(decodedAudioBuffer, zeroCrossingIndex: zeroCrossingIndex)
            activeEngine = .preview
        }
    }

    func loadFile(at url: URL, zeroCrossingProbe: WAVZeroCrossingProbe? = nil) throws {
        cancelSourcePreparation()
        multitrackEngine.clear()
        realtimeEngine?.clear()
        try previewEngine.loadFile(at: url, zeroCrossingProbe: zeroCrossingProbe)
        previewEngine.setPerceptualVolume(perceptualVolume)
        activeEngine = .preview
    }

    func replaceWithDecodedSource(
        _ decodedAudioBuffer: DecodedAudioBuffer,
        zeroCrossingIndex: AudioZeroCrossingIndex? = nil
    ) throws {
        guard realtimeEngine != nil else {
            multitrackEngine.clear()
            try previewEngine.replaceWithDecodedSource(
                decodedAudioBuffer,
                zeroCrossingIndex: zeroCrossingIndex
            )
            activeEngine = .preview
            return
        }

        if !currentEngine.hasSource {
            multitrackEngine.clear()
            try previewEngine.load(decodedAudioBuffer, zeroCrossingIndex: zeroCrossingIndex)
            previewEngine.setPerceptualVolume(perceptualVolume)
            activeEngine = .preview
        }

        let preparationID = UUID()
        sourcePreparationID = preparationID
        sourcePreparationTask?.cancel()
        sourcePreparationTask = Task { [weak self, decodedAudioBuffer, zeroCrossingIndex, preparationID] in
            let preparedSource = await Task.detached(priority: .userInitiated) {
                PreparedRealtimeAudioSource.make(from: decodedAudioBuffer)
            }.value

            guard !Task.isCancelled else {
                return
            }

            guard let preparedSource else {
                return
            }

            guard let self, self.sourcePreparationID == preparationID else {
                return
            }

            self.activatePreparedRealtimeSource(
                preparedSource,
                zeroCrossingIndex: zeroCrossingIndex
            )
        }
    }

    func clear() {
        cancelSourcePreparation()
        previewEngine.clear()
        multitrackEngine.clear()
        realtimeEngine?.clear()
        activeEngine = .preview
    }

    func updateZeroCrossingIndex(_ zeroCrossingIndex: AudioZeroCrossingIndex?) {
        previewEngine.updateZeroCrossingIndex(zeroCrossingIndex)
        multitrackEngine.updateZeroCrossingIndex(zeroCrossingIndex)
        realtimeEngine?.updateZeroCrossingIndex(zeroCrossingIndex)
    }

    func loadProjectTracks(_ tracks: [ProjectPlaybackTrack]) throws {
        cancelSourcePreparation()
        previewEngine.clear()
        let requiresSampleSynchronousPlayback = tracks.count > 1
        if let realtimeEngine {
            multitrackEngine.clear()
            do {
                try realtimeEngine.loadProjectTracks(tracks)
                realtimeEngine.setPerceptualVolume(perceptualVolume)
                activeEngine = .realtime
                return
            } catch {
                realtimeEngine.clear()
                guard !requiresSampleSynchronousPlayback else {
                    throw error
                }
            }
        }

        guard !requiresSampleSynchronousPlayback else {
            throw PlaybackError.invalidFormat
        }

        try multitrackEngine.loadProjectTracks(tracks)
        multitrackEngine.setPerceptualVolume(perceptualVolume)
        activeEngine = .multitrack
    }

    func updateProjectTracks(_ tracks: [ProjectPlaybackTrack]) throws {
        cancelSourcePreparation()
        guard !tracks.isEmpty else {
            clear()
            return
        }

        if activeEngine == .realtime, let realtimeEngine {
            try realtimeEngine.updateProjectTracks(tracks)
            realtimeEngine.setPerceptualVolume(perceptualVolume)
            return
        }

        try loadProjectTracks(tracks)
    }

    func updateProjectTrackMix(_ tracks: [ProjectPlaybackTrack]) {
        switch activeEngine {
        case .realtime:
            realtimeEngine?.updateProjectTrackMix(tracks)
        case .multitrack:
            multitrackEngine.updateProjectTrackMix(tracks)
        case .preview:
            break
        }
    }

    @discardableResult
    func togglePlayback() throws -> Bool {
        try currentEngine.togglePlayback()
    }

    func play() throws {
        try currentEngine.play()
    }

    func pause() {
        currentEngine.pause()
    }

    func pause(atProgress progress: Float) {
        currentEngine.pause(atProgress: progress)
    }

    func seek(toProgress progress: Float) throws {
        try currentEngine.seek(toProgress: progress)
    }

    func seekExactly(toProgress progress: Float) throws {
        try currentEngine.seekExactly(toProgress: progress)
    }

    func snapshot() -> PlaybackSnapshot {
        currentEngine.snapshot()
    }

    func drainMeterSamples() -> [PlaybackMeterSample] {
        currentEngine.drainMeterSamples()
    }

    private func activatePreparedRealtimeSource(
        _ preparedSource: PreparedRealtimeAudioSource,
        zeroCrossingIndex: AudioZeroCrossingIndex?
    ) {
        guard let realtimeEngine else {
            return
        }

        let previousSnapshot = currentEngine.snapshot()
        let shouldResume = previousSnapshot.isPlaying

        do {
            try realtimeEngine.loadPreparedSource(
                preparedSource,
                zeroCrossingIndex: zeroCrossingIndex
            )
            realtimeEngine.setPerceptualVolume(perceptualVolume)
            try realtimeEngine.seek(toProgress: previousSnapshot.progress)

            if shouldResume {
                previewEngine.pause()
                try realtimeEngine.play()
            } else {
                previewEngine.pause()
            }

            activeEngine = .realtime
        } catch {
            previewEngine.updateZeroCrossingIndex(zeroCrossingIndex)
        }
    }

    private func cancelSourcePreparation() {
        sourcePreparationTask?.cancel()
        sourcePreparationTask = nil
        sourcePreparationID = UUID()
    }
}
