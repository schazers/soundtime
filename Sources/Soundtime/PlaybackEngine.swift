import Foundation

struct PlaybackSnapshot {
    let frameIndex: Int
    let frameCount: Int
    let sampleRate: Double
    let isPlaying: Bool
    let hostTimestamp: TimeInterval

    init(
        frameIndex: Int,
        frameCount: Int,
        sampleRate: Double = 0,
        isPlaying: Bool,
        hostTimestamp: TimeInterval
    ) {
        self.frameIndex = frameIndex
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.isPlaying = isPlaying
        self.hostTimestamp = hostTimestamp
    }

    var progress: Float {
        guard frameCount > 0 else {
            return 0
        }

        return min(max(Float(frameIndex) / Float(frameCount), 0), 1)
    }

    var isAtEnd: Bool {
        frameCount > 0 && frameIndex >= frameCount
    }

    var projectTime: TimeInterval? {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return nil
        }

        return TimeInterval(frameIndex) / sampleRate
    }

    var duration: TimeInterval? {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return nil
        }

        return TimeInterval(frameCount) / sampleRate
    }

    func progressPreservingProjectTime(from previousSnapshot: PlaybackSnapshot) -> Float {
        guard
            let previousProjectTime = previousSnapshot.projectTime,
            let duration,
            duration.isFinite,
            duration > 0
        else {
            return previousSnapshot.progress
        }

        return Float(min(max(previousProjectTime / duration, 0), 1))
    }
}

struct PlaybackMeterSample: Sendable {
    let startFrameIndex: Int
    let frameCount: Int
    let renderedFrameCount: Int
    let hostTimestamp: TimeInterval
    let isPlaying: Bool
    let leftRMS: Float
    let rightRMS: Float
    let leftPeak: Float
    let rightPeak: Float
    let leftClipPeak: Float
    let rightClipPeak: Float
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
        case fileTimeline(
            url: URL,
            timeline: AudioFileEditTimeline,
            zeroCrossingProbe: WAVZeroCrossingProbe?
        )
        case timeline(
            audioTimeline: AudioEditTimeline,
            zeroCrossingIndex: AudioZeroCrossingIndex?
        )
    }

    let id: UUID
    let source: Source
    let sourceRevision: Int
    let volume: Float
    let isMuted: Bool
    let isSoloed: Bool
}

struct ProjectPlaybackTrackMix: Sendable {
    let id: UUID
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
    func updateProjectTracks(_ tracks: [ProjectPlaybackTrack]) throws
    func refreshOutputDevice() throws
    func warmOutputForLowLatencyPlayback() throws
    func replaceWithDecodedSource(
        _ decodedAudioBuffer: DecodedAudioBuffer,
        zeroCrossingIndex: AudioZeroCrossingIndex?
    ) throws
    func clear()
    func updateZeroCrossingIndex(_ zeroCrossingIndex: AudioZeroCrossingIndex?)
    func updateProjectTrackMix(_ tracks: [ProjectPlaybackTrackMix])
    @discardableResult
    func togglePlayback() throws -> Bool
    func play() throws
    func pause()
    func pause(atProgress progress: Float)
    func seek(toProgress progress: Float) throws
    func seekExactly(toProgress progress: Float) throws
    func snapshot() -> PlaybackSnapshot
    func drainMeterSamples() -> [PlaybackMeterSample]
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
        case let .fileTimeline(url, _, zeroCrossingProbe):
            try loadFile(at: url, zeroCrossingProbe: zeroCrossingProbe)
        case let .timeline(audioTimeline, zeroCrossingIndex):
            try load(audioTimeline.render(), zeroCrossingIndex: zeroCrossingIndex)
        }
    }

    func updateProjectTrackMix(_ tracks: [ProjectPlaybackTrackMix]) {}

    func updateProjectTracks(_ tracks: [ProjectPlaybackTrack]) throws {
        try loadProjectTracks(tracks)
    }

    func refreshOutputDevice() throws {}

    func warmOutputForLowLatencyPlayback() throws {}

    func pause(atProgress progress: Float) {
        pause()
    }

    func seekExactly(toProgress progress: Float) throws {
        try seek(toProgress: progress)
    }

    func drainMeterSamples() -> [PlaybackMeterSample] {
        []
    }
}
