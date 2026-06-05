import Foundation

struct PlaybackSnapshot {
    let frameIndex: Int
    let frameCount: Int
    let isPlaying: Bool
    let hostTimestamp: TimeInterval

    var progress: Float {
        guard frameCount > 0 else {
            return 0
        }

        return min(max(Float(frameIndex) / Float(frameCount), 0), 1)
    }

    var isAtEnd: Bool {
        frameCount > 0 && frameIndex >= frameCount
    }
}

enum PlaybackError: LocalizedError {
    case noAudioLoaded
    case invalidFormat
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .noAudioLoaded:
            "No decoded WAV is loaded."
        case .invalidFormat:
            "The decoded WAV has an unsupported playback format."
        case .bufferCreationFailed:
            "Could not create the playback buffer."
        }
    }
}

@MainActor
protocol PlaybackEngine: AnyObject {
    var isPlaying: Bool { get }
    var hasSource: Bool { get }

    func setPerceptualVolume(_ volume: Float)
    func load(
        _ decodedAudioBuffer: DecodedAudioBuffer,
        zeroCrossingIndex: AudioZeroCrossingIndex?
    ) throws
    func loadFile(at url: URL, zeroCrossingProbe: WAVZeroCrossingProbe?) throws
    func clear()
    func updateZeroCrossingIndex(_ zeroCrossingIndex: AudioZeroCrossingIndex?)
    @discardableResult
    func togglePlayback() throws -> Bool
    func play() throws
    func pause()
    func seek(toProgress progress: Float) throws
    func snapshot() -> PlaybackSnapshot
}
