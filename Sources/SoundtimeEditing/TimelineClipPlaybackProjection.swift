import Foundation

public struct TimelinePlaybackLaneID: Hashable, Codable, Sendable {
    public let trackID: UUID
    public let sourceID: TimelineMediaSourceID

    public init(trackID: UUID, sourceID: TimelineMediaSourceID) {
        self.trackID = trackID
        self.sourceID = sourceID
    }
}

public struct TimelinePlaybackAutomationPoint: Equatable, Sendable {
    public let frame: Int
    public let normalizedValue: Float
    public let curveToNext: Float

    public init(frame: Int, normalizedValue: Float, curveToNext: Float) {
        self.frame = max(frame, 0)
        self.normalizedValue = min(max(normalizedValue, 0), 1)
        self.curveToNext = TimelineAutomationCurve.validated(curveToNext)
    }
}

public struct TimelinePlaybackLane: Equatable, Sendable {
    public let id: TimelinePlaybackLaneID
    public let trackName: String
    /// Output topology of the owning logical track. This deliberately differs
    /// from `source.channelCount`: a stereo track can currently be rendering a
    /// mono source panned into either output channel.
    public let logicalChannelCount: Int
    public let source: TimelineMediaSource
    public let segments: [AudioTimelinePlaybackSegment]
    public let volume: Float
    public let pan: Float
    public let isMuted: Bool
    public let isSoloed: Bool
    public let volumeAutomation: [TimelinePlaybackAutomationPoint]
    public let panAutomation: [TimelinePlaybackAutomationPoint]
    public let muteAutomation: [TimelinePlaybackAutomationPoint]

    public init(
        id: TimelinePlaybackLaneID,
        trackName: String,
        logicalChannelCount: Int = 2,
        source: TimelineMediaSource,
        segments: [AudioTimelinePlaybackSegment],
        volume: Float,
        pan: Float = 0,
        isMuted: Bool,
        isSoloed: Bool,
        volumeAutomation: [TimelinePlaybackAutomationPoint] = [],
        panAutomation: [TimelinePlaybackAutomationPoint] = [],
        muteAutomation: [TimelinePlaybackAutomationPoint] = []
    ) {
        self.id = id
        self.trackName = trackName
        self.logicalChannelCount = logicalChannelCount <= 1 ? 1 : 2
        self.source = source
        self.segments = segments
        self.volume = volume
        self.pan = min(max(pan, -1), 1)
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.volumeAutomation = volumeAutomation
        self.panAutomation = panAutomation
        self.muteAutomation = muteAutomation
    }
}

/// Immutable media arrangement consumed by realtime playback and offline
/// export. Both adapters must translate this exact value rather than projecting
/// the mutable graph independently.
public struct TimelinePlaybackSnapshot: Equatable, Sendable {
    public let graphRevision: UInt64
    public let automationRevision: UInt64
    public let parameterBindingRevision: UInt64
    public let timelineSampleRate: Double
    public let endFrame: Int
    public let lanes: [TimelinePlaybackLane]

    public init(
        graphRevision: UInt64,
        automationRevision: UInt64 = 1,
        parameterBindingRevision: UInt64 = 1,
        timelineSampleRate: Double,
        endFrame: Int,
        lanes: [TimelinePlaybackLane]
    ) {
        self.graphRevision = graphRevision
        self.automationRevision = automationRevision
        self.parameterBindingRevision = max(parameterBindingRevision, 1)
        self.timelineSampleRate = timelineSampleRate
        self.endFrame = endFrame
        self.lanes = lanes
    }
}

public enum TimelineClipPlaybackProjection {
    public static func snapshot(
        from graph: TimelineClipGraph,
        automationGraph: TimelineAutomationGraph? = nil
    ) throws -> TimelinePlaybackSnapshot {
        try graph.validate()
        return TimelinePlaybackSnapshot(
            graphRevision: graph.revision,
            automationRevision: automationGraph?.revision ?? 1,
            timelineSampleRate: graph.timelineSampleRate,
            endFrame: graph.endFrame,
            lanes: try projectedLanes(from: graph, automationGraph: automationGraph)
        )
    }

    public static func lanes(from graph: TimelineClipGraph) throws -> [TimelinePlaybackLane] {
        try graph.validate()
        return try projectedLanes(from: graph, automationGraph: nil)
    }

    private static func projectedLanes(
        from graph: TimelineClipGraph,
        automationGraph: TimelineAutomationGraph?
    ) throws -> [TimelinePlaybackLane] {
        var lanes: [TimelinePlaybackLane] = []

        for track in graph.tracks {
            let volumeAutomation = automationGraph?
                .lane(at: .track(track.id, parameterID: .volume))
                .flatMap { $0.isEnabled ? $0.points : nil }?
                .map {
                    TimelinePlaybackAutomationPoint(
                        frame: $0.frame,
                        normalizedValue: $0.normalizedValue,
                        curveToNext: $0.curveToNext
                    )
                } ?? []
            let panAutomation = automationGraph?
                .lane(at: .track(track.id, parameterID: .pan))
                .flatMap { $0.isEnabled ? $0.points : nil }?
                .map {
                    TimelinePlaybackAutomationPoint(
                        frame: $0.frame,
                        normalizedValue: $0.normalizedValue,
                        curveToNext: $0.curveToNext
                    )
                } ?? []
            let muteAutomation = automationGraph?
                .lane(at: .track(track.id, parameterID: .mute))
                .flatMap { $0.isEnabled ? $0.points : nil }?
                .map {
                    TimelinePlaybackAutomationPoint(
                        frame: $0.frame,
                        normalizedValue: $0.normalizedValue,
                        curveToNext: TimelineAutomationCurve.stepped
                    )
                } ?? []
            let clipsBySource = Dictionary(grouping: track.clips, by: \.sourceID)
            for sourceID in clipsBySource.keys.sorted() {
                guard let source = graph.sources[sourceID] else {
                    throw TimelineClipGraphError.missingSource(sourceID)
                }
                let clips = clipsBySource[sourceID] ?? []
                lanes.append(TimelinePlaybackLane(
                    id: TimelinePlaybackLaneID(trackID: track.id, sourceID: sourceID),
                    trackName: track.name,
                    logicalChannelCount: track.channelLayout.channelCount,
                    source: source,
                    segments: clips.flatMap(playbackSegments(for:)),
                    volume: track.volume,
                    pan: track.pan,
                    isMuted: track.isMuted,
                    isSoloed: track.isSoloed,
                    volumeAutomation: volumeAutomation,
                    panAutomation: panAutomation,
                    muteAutomation: muteAutomation
                ))
            }
        }
        return lanes
    }

    public static func playbackSegments(for clip: TimelineClip) -> [AudioTimelinePlaybackSegment] {
        let fadeIn = min(clip.fades.fadeInFrames, clip.timelineRange.frameCount)
        let fadeOut = min(
            clip.fades.fadeOutFrames,
            clip.timelineRange.frameCount - fadeIn
        )
        let body = clip.timelineRange.frameCount - fadeIn - fadeOut
        let baseGain: Float = clip.isMuted ? 0 : clip.gain
        var pieces: [(frameCount: Int, gainStart: Float, gainEnd: Float)] = []
        if fadeIn > 0 {
            pieces.append((fadeIn, 0, baseGain))
        }
        if body > 0 {
            pieces.append((body, baseGain, baseGain))
        }
        if fadeOut > 0 {
            pieces.append((fadeOut, baseGain, 0))
        }

        func envelopeMultiplier(at outputFrame: Int) -> Float {
            guard clip.timelineRange.frameCount > 1 else {
                return clip.gainEnvelope.endMultiplier
            }
            let progress = Float(outputFrame) / Float(clip.timelineRange.frameCount - 1)
            let curve = progress * progress * (3 - 2 * progress)
            return clip.gainEnvelope.startMultiplier +
                (clip.gainEnvelope.endMultiplier - clip.gainEnvelope.startMultiplier) * curve
        }

        var outputOffset = 0
        return pieces.enumerated().map { index, piece in
            let sourceOffset = Int((Double(outputOffset) * clip.sourceFrameScale).rounded())
            let pieceStart = outputOffset
            let pieceEnd = outputOffset + max(piece.frameCount - 1, 0)
            defer { outputOffset += piece.frameCount }
            return AudioTimelinePlaybackSegment(
                outputStartFrame: clip.timelineRange.startFrame + outputOffset,
                sourceStartFrame: clip.sourceRange.startFrame + sourceOffset,
                frameCount: piece.frameCount,
                sourceFrameScale: clip.sourceFrameScale,
                gainStart: piece.gainStart * envelopeMultiplier(at: pieceStart),
                gainEnd: piece.gainEnd * envelopeMultiplier(at: pieceEnd),
                startsNewClip: index == 0,
                clipID: clip.id
            )
        }
    }
}
