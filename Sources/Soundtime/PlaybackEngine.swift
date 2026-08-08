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

struct PlaybackTrackMeterLevel: Sendable, Equatable {
    let trackID: UUID
    let channelCount: Int
    let leftRMS: Float
    let rightRMS: Float
    let leftPeak: Float
    let rightPeak: Float

    /// A mono strip has one meter even though pan can distribute that source
    /// across both output channels. Keep that one meter truthful at every pan
    /// position by displaying the louder post-pan contribution.
    func normalizedForMixerDisplay() -> PlaybackTrackMeterLevel {
        guard channelCount <= 1 else { return self }
        return PlaybackTrackMeterLevel(
            trackID: trackID,
            channelCount: 1,
            leftRMS: max(leftRMS, rightRMS),
            rightRMS: 0,
            leftPeak: max(leftPeak, rightPeak),
            rightPeak: 0
        )
    }
}

struct PlaybackTrackMeterPacket: Sendable, Equatable {
    let graphRevision: UInt64
    let sequence: UInt64
    let renderedFrameCount: Int
    let hostTimestamp: TimeInterval
    let levels: [PlaybackTrackMeterLevel]
}

struct PlaybackTrackMeterDiagnostics: Sendable, Equatable {
    let droppedPacketCount: UInt64
    let stalePacketCount: UInt64
    let realtimeWorkNanoseconds: UInt64
}

enum PlaybackError: LocalizedError {
    case noAudioLoaded
    case invalidFormat
    case bufferCreationFailed
    case outputDeviceFailed(OSStatus)
    case unsupportedProjectArrangement
    case automationRequiresRealtimeEngine

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
        case .unsupportedProjectArrangement:
            "This playback engine cannot preserve the project's clip arrangement."
        case .automationRequiresRealtimeEngine:
            "Track automation requires Soundtime's realtime playback engine."
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
        case fileSegments(
            url: URL,
            sourceFrameCount: Int,
            sourceSampleRate: Double,
            timelineSampleRate: Double,
            segments: [AudioTimelinePlaybackSegment],
            zeroCrossingProbe: WAVZeroCrossingProbe?
        )
        case timeline(
            audioTimeline: AudioEditTimeline,
            zeroCrossingIndex: AudioZeroCrossingIndex?
        )
    }

    let id: UUID
    /// Multiple source lanes can belong to one logical track. Mix controls are
    /// addressed through this stable logical identity.
    let logicalTrackID: UUID
    /// Channel layout of the logical strip, independent of this runtime
    /// source lane's media channel count.
    let logicalChannelCount: Int
    let source: Source
    let sourceRevision: Int
    /// Authoritative duration of the immutable project snapshot that produced
    /// this lane. Canonical clip-graph projections set this on every lane so
    /// transport time continues through implicit trailing gaps.
    let timelineDurationHint: TimeInterval?
    let volume: Float
    let pan: Float
    let isMuted: Bool
    let isSoloed: Bool
    let volumeAutomation: [TimelinePlaybackAutomationPoint]
    let panAutomation: [TimelinePlaybackAutomationPoint]
    let muteAutomation: [TimelinePlaybackAutomationPoint]

    init(
        id: UUID,
        logicalTrackID: UUID? = nil,
        logicalChannelCount: Int = 2,
        source: Source,
        sourceRevision: Int,
        timelineDurationHint: TimeInterval? = nil,
        volume: Float,
        pan: Float = 0,
        isMuted: Bool,
        isSoloed: Bool,
        volumeAutomation: [TimelinePlaybackAutomationPoint] = [],
        panAutomation: [TimelinePlaybackAutomationPoint] = [],
        muteAutomation: [TimelinePlaybackAutomationPoint] = []
    ) {
        self.id = id
        self.logicalTrackID = logicalTrackID ?? id
        self.logicalChannelCount = logicalChannelCount <= 1 ? 1 : 2
        self.source = source
        self.sourceRevision = sourceRevision
        self.timelineDurationHint = timelineDurationHint
        self.volume = volume
        self.pan = min(max(pan, -1), 1)
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.volumeAutomation = volumeAutomation
        self.panAutomation = panAutomation
        self.muteAutomation = muteAutomation
    }
}

struct ProjectPlaybackTrackMix: Sendable {
    let id: UUID
    let volume: Float
    let pan: Float
    let isMuted: Bool
    let isSoloed: Bool

    init(id: UUID, volume: Float, pan: Float = 0, isMuted: Bool, isSoloed: Bool) {
        self.id = id
        self.volume = volume
        self.pan = min(max(pan, -1), 1)
        self.isMuted = isMuted
        self.isSoloed = isSoloed
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
    func previewProjectTrackPan(trackID: UUID, pan: Float)
    @discardableResult
    func togglePlayback() throws -> Bool
    func play() throws
    func pause()
    func pause(atProgress progress: Float)
    func seek(toProgress progress: Float) throws
    func seekExactly(toProgress progress: Float) throws
    func snapshot() -> PlaybackSnapshot
    func drainMeterSamples() -> [PlaybackMeterSample]
    func setTrackMeteringEnabled(_ isEnabled: Bool)
    func drainTrackMeterPackets() -> [PlaybackTrackMeterPacket]
    func trackMeterDiagnostics() -> PlaybackTrackMeterDiagnostics
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
        case .fileTimeline, .fileSegments:
            throw PlaybackError.unsupportedProjectArrangement
        case let .timeline(audioTimeline, zeroCrossingIndex):
            try load(audioTimeline.render(), zeroCrossingIndex: zeroCrossingIndex)
        }
    }

    func updateProjectTrackMix(_ tracks: [ProjectPlaybackTrackMix]) {}

    func previewProjectTrackPan(trackID: UUID, pan: Float) {}

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

    func setTrackMeteringEnabled(_ isEnabled: Bool) {}

    func drainTrackMeterPackets() -> [PlaybackTrackMeterPacket] { [] }

    func trackMeterDiagnostics() -> PlaybackTrackMeterDiagnostics {
        PlaybackTrackMeterDiagnostics(
            droppedPacketCount: 0,
            stalePacketCount: 0,
            realtimeWorkNanoseconds: 0
        )
    }
}
