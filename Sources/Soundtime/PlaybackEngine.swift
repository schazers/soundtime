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
    case outputDeviceFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noAudioLoaded:
            "No decoded WAV is loaded."
        case .invalidFormat:
            "The decoded WAV has an unsupported playback format."
        case .bufferCreationFailed:
            "Could not create the playback buffer."
        case let .outputDeviceFailed(status):
            "The audio output device failed with status \(status)."
        }
    }
}

struct ProjectPlaybackTrack: Sendable {
    enum Source: Sendable {
        case decoded(
            decodedAudioBuffer: DecodedAudioBuffer,
            zeroCrossingIndex: AudioZeroCrossingIndex?
        )
        case file(
            url: URL,
            zeroCrossingProbe: WAVZeroCrossingProbe?
        )
    }

    let id: UUID
    let source: Source
    let sourceRevision: Int
    let volume: Float
    let isMuted: Bool
    let isSoloed: Bool
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
    func loadProjectTracks(_ tracks: [ProjectPlaybackTrack]) throws
    func replaceWithDecodedSource(
        _ decodedAudioBuffer: DecodedAudioBuffer,
        zeroCrossingIndex: AudioZeroCrossingIndex?
    ) throws
    func clear()
    func updateZeroCrossingIndex(_ zeroCrossingIndex: AudioZeroCrossingIndex?)
    func updateProjectTrackMix(_ tracks: [ProjectPlaybackTrack])
    @discardableResult
    func togglePlayback() throws -> Bool
    func play() throws
    func pause()
    func pause(atProgress progress: Float)
    func seek(toProgress progress: Float) throws
    func seekExactly(toProgress progress: Float) throws
    func snapshot() -> PlaybackSnapshot
}

@MainActor
extension PlaybackEngine {
    func loadProjectTracks(_ tracks: [ProjectPlaybackTrack]) throws {
        guard let firstTrack = tracks.first else {
            clear()
            return
        }

        switch firstTrack.source {
        case let .decoded(decodedAudioBuffer, zeroCrossingIndex):
            try load(decodedAudioBuffer, zeroCrossingIndex: zeroCrossingIndex)
        case let .file(url, zeroCrossingProbe):
            try loadFile(at: url, zeroCrossingProbe: zeroCrossingProbe)
        }
    }

    func updateProjectTrackMix(_ tracks: [ProjectPlaybackTrack]) {}

    func pause(atProgress progress: Float) {
        pause()
    }

    func seekExactly(toProgress progress: Float) throws {
        try seek(toProgress: progress)
    }
}
