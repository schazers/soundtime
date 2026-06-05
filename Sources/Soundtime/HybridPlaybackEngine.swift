import Foundation

@MainActor
final class HybridPlaybackEngine: PlaybackEngine {
    private enum ActiveEngine {
        case preview
        case realtime
    }

    private let previewEngine = AudioPlaybackController()
    private let realtimeEngine: RealtimeCorePlaybackEngine?
    private var activeEngine: ActiveEngine = .preview
    private var perceptualVolume: Float = 1

    private var currentEngine: PlaybackEngine {
        switch activeEngine {
        case .preview:
            return previewEngine
        case .realtime:
            return realtimeEngine ?? previewEngine
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
    }

    func setPerceptualVolume(_ volume: Float) {
        perceptualVolume = min(max(volume, 0), 1)
        previewEngine.setPerceptualVolume(perceptualVolume)
        realtimeEngine?.setPerceptualVolume(perceptualVolume)
    }

    func load(
        _ decodedAudioBuffer: DecodedAudioBuffer,
        zeroCrossingIndex: AudioZeroCrossingIndex? = nil
    ) throws {
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
        realtimeEngine?.clear()
        try previewEngine.loadFile(at: url, zeroCrossingProbe: zeroCrossingProbe)
        previewEngine.setPerceptualVolume(perceptualVolume)
        activeEngine = .preview
    }

    func replaceWithDecodedSource(
        _ decodedAudioBuffer: DecodedAudioBuffer,
        zeroCrossingIndex: AudioZeroCrossingIndex? = nil
    ) throws {
        guard let realtimeEngine else {
            try previewEngine.replaceWithDecodedSource(
                decodedAudioBuffer,
                zeroCrossingIndex: zeroCrossingIndex
            )
            activeEngine = .preview
            return
        }

        let previousSnapshot = currentEngine.snapshot()
        let shouldResume = previousSnapshot.isPlaying
        previewEngine.pause()
        try realtimeEngine.load(decodedAudioBuffer, zeroCrossingIndex: zeroCrossingIndex)
        realtimeEngine.setPerceptualVolume(perceptualVolume)
        try realtimeEngine.seek(toProgress: previousSnapshot.progress)

        if shouldResume {
            try realtimeEngine.play()
        }

        activeEngine = .realtime
    }

    func clear() {
        previewEngine.clear()
        realtimeEngine?.clear()
        activeEngine = .preview
    }

    func updateZeroCrossingIndex(_ zeroCrossingIndex: AudioZeroCrossingIndex?) {
        previewEngine.updateZeroCrossingIndex(zeroCrossingIndex)
        realtimeEngine?.updateZeroCrossingIndex(zeroCrossingIndex)
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

    func seek(toProgress progress: Float) throws {
        try currentEngine.seek(toProgress: progress)
    }

    func snapshot() -> PlaybackSnapshot {
        currentEngine.snapshot()
    }
}
