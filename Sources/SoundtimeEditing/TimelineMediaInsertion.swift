import Foundation

public enum TimelineMediaInsertionPolicy: Equatable, Sendable {
    case rejectOverlap
    case rippleExistingContent
}

public struct TimelineMediaInsertionRequest: Equatable, Sendable {
    public let trackID: UUID
    public let source: TimelineMediaSource
    public let sourceRange: TimelineFrameRange
    public let timelineStartFrame: Int
    public let timelineFrameCount: Int?
    public let clipID: AudioTimelineClipID
    public let clipName: String
    public let gain: Float
    public let gainEnvelope: TimelineClipGainEnvelope
    public let fades: TimelineClipFades
    public let isMuted: Bool
    public let isLocked: Bool
    public let colorToken: String?
    public let clipMetadata: [String: String]

    public init(
        trackID: UUID,
        source: TimelineMediaSource,
        sourceRange: TimelineFrameRange? = nil,
        timelineStartFrame: Int,
        timelineFrameCount: Int? = nil,
        clipID: AudioTimelineClipID = AudioTimelineClipID(),
        clipName: String,
        gain: Float = 1,
        gainEnvelope: TimelineClipGainEnvelope = TimelineClipGainEnvelope(),
        fades: TimelineClipFades = TimelineClipFades(),
        isMuted: Bool = false,
        isLocked: Bool = false,
        colorToken: String? = nil,
        clipMetadata: [String: String] = [:]
    ) {
        self.trackID = trackID
        self.source = source
        self.sourceRange = sourceRange ?? TimelineFrameRange(
            startFrame: 0,
            frameCount: source.frameCount
        )
        self.timelineStartFrame = timelineStartFrame
        self.timelineFrameCount = timelineFrameCount
        self.clipID = clipID
        self.clipName = clipName
        self.gain = gain
        self.gainEnvelope = gainEnvelope
        self.fades = fades
        self.isMuted = isMuted
        self.isLocked = isLocked
        self.colorToken = colorToken
        self.clipMetadata = clipMetadata
    }
}

public enum TimelineMediaInsertionService {
    /// Inserts a copied timeline span as one atomic ripple operation.
    ///
    /// The payload's complete duration is reserved once, including implicit
    /// gaps between fragments. Individual fragments are then placed inside
    /// that reserved span without shifting existing clips again.
    public static func insertTransfer(
        _ payload: TimelineClipTransferPayload,
        trackID: UUID,
        timelineStartFrame: Int,
        into graph: TimelineClipGraph,
        expectedRevision: UInt64
    ) throws -> TimelineClipCommandResult {
        guard payload.timelineSampleRate.isFinite, payload.timelineSampleRate > 0 else {
            throw TimelineClipGraphError.invalidTimelineSampleRate
        }
        let rateScale = graph.timelineSampleRate / payload.timelineSampleRate
        let reservedFrameCount = max(Int((Double(payload.frameCount) * rateScale).rounded()), 1)
        let requests = payload.fragments.map { fragment in
            TimelineMediaInsertionRequest(
                trackID: trackID,
                source: fragment.source,
                sourceRange: fragment.sourceRange,
                timelineStartFrame: timelineStartFrame + Int(
                    (Double(fragment.relativeTimelineStartFrame) * rateScale).rounded()
                ),
                timelineFrameCount: max(
                    Int((Double(fragment.timelineFrameCount) * rateScale).rounded()),
                    1
                ),
                clipName: fragment.name,
                gain: fragment.gain,
                gainEnvelope: fragment.gainEnvelope,
                fades: fragment.fades,
                isMuted: fragment.isMuted,
                colorToken: fragment.colorToken,
                clipMetadata: fragment.metadata
            )
        }
        guard !requests.isEmpty else {
            throw TimelineClipGraphError.invalidTimelineSampleRate
        }
        return try insertValidated(
            requests,
            into: graph,
            expectedRevision: expectedRevision,
            policy: .rippleExistingContent,
            rippleReservations: [trackID: (timelineStartFrame, reservedFrameCount)]
        )
    }

    public static func insert(
        _ request: TimelineMediaInsertionRequest,
        into graph: TimelineClipGraph,
        expectedRevision: UInt64,
        policy: TimelineMediaInsertionPolicy = .rejectOverlap
    ) throws -> TimelineClipCommandResult {
        try insert(
            [request],
            into: graph,
            expectedRevision: expectedRevision,
            policy: policy
        )
    }

    public static func insert(
        _ requests: [TimelineMediaInsertionRequest],
        into graph: TimelineClipGraph,
        expectedRevision: UInt64,
        policy: TimelineMediaInsertionPolicy = .rejectOverlap
    ) throws -> TimelineClipCommandResult {
        try insertValidated(
            requests,
            into: graph,
            expectedRevision: expectedRevision,
            policy: policy,
            rippleReservations: [:]
        )
    }

    private static func insertValidated(
        _ requests: [TimelineMediaInsertionRequest],
        into graph: TimelineClipGraph,
        expectedRevision: UInt64,
        policy: TimelineMediaInsertionPolicy,
        rippleReservations: [UUID: (startFrame: Int, frameCount: Int)]
    ) throws -> TimelineClipCommandResult {
        guard graph.revision == expectedRevision else {
            throw TimelineClipGraphError.staleRevision(
                expected: expectedRevision,
                actual: graph.revision
            )
        }
        guard !requests.isEmpty else {
            throw TimelineClipGraphError.invalidTimelineSampleRate
        }
        var afterTracks = Dictionary(uniqueKeysWithValues: graph.tracks.map { ($0.id, $0) })
        var sources = graph.sources
        var placements: [TimelineClipPlacement] = []
        var clips: [TimelineClip] = []
        for request in requests {
            try request.source.validate()
            guard
                request.timelineStartFrame >= 0,
                request.sourceRange.startFrame >= 0,
                request.sourceRange.frameCount > 0,
                request.sourceRange.endFrame <= request.source.frameCount
            else { throw TimelineClipGraphError.invalidSourceRange(request.clipID) }
            guard afterTracks[request.trackID] != nil else {
                throw TimelineClipGraphError.missingTrack(request.trackID)
            }
            if let existingSource = sources[request.source.id], existingSource != request.source {
                throw TimelineClipGraphError.sourceIdentityConflict(request.source.id)
            }
            sources[request.source.id] = request.source
            let count = request.timelineFrameCount ?? max(Int(
                (Double(request.sourceRange.frameCount) / request.source.sampleRate * graph.timelineSampleRate).rounded()
            ), 1)
            guard count > 0 else {
                throw TimelineClipGraphError.invalidTimelineRange(request.clipID)
            }
            let clip = TimelineClip(
                id: request.clipID,
                sourceID: request.source.id,
                timelineRange: .init(startFrame: request.timelineStartFrame, frameCount: count),
                sourceRange: request.sourceRange,
                name: request.clipName,
                gain: request.gain,
                gainEnvelope: request.gainEnvelope,
                fades: request.fades,
                isMuted: request.isMuted,
                isLocked: request.isLocked,
                colorToken: request.colorToken,
                metadata: request.clipMetadata
            )
            clips.append(clip)
            placements.append(.init(
                clipID: clip.id,
                destinationTrackID: request.trackID,
                timelineRange: clip.timelineRange
            ))
        }
        var placementGraph = graph
        if policy == .rippleExistingContent {
            let grouped = Dictionary(grouping: zip(requests, clips), by: { $0.0.trackID })
            for (trackID, entries) in grouped {
                guard var track = afterTracks[trackID] else {
                    throw TimelineClipGraphError.missingTrack(trackID)
                }
                let insertionStart = rippleReservations[trackID]?.startFrame ??
                    entries.map { $0.1.timelineRange.startFrame }.min() ?? 0
                let insertionEnd = entries.map { $0.1.timelineRange.endFrame }.max() ?? insertionStart
                let insertedFrameCount = rippleReservations[trackID]?.frameCount ??
                    max(insertionEnd - insertionStart, 0)
                track = try rippling(
                    track,
                    at: insertionStart,
                    by: insertedFrameCount
                )
                afterTracks[trackID] = track
            }
            placementGraph = try graph.replacingTracksForValidation(
                graph.tracks.map { afterTracks[$0.id] ?? $0 }
            )
        }
        try TimelineClipPlacementValidator.requireAllowed(placements, in: placementGraph)
        for (request, clip) in zip(requests, clips) {
            guard var destination = afterTracks[request.trackID] else {
                throw TimelineClipGraphError.missingTrack(request.trackID)
            }
            destination.channelLayout = destination.channelLayout.promoted(
                forSourceChannelCount: request.source.channelCount
            )
            destination.upsertClip(clip)
            afterTracks[request.trackID] = destination
        }
        let affectedTrackIDs = Set(requests.map(\.trackID))
        let beforeTracks = graph.tracks.filter { affectedTrackIDs.contains($0.id) }
        let orderedTracks = graph.tracks.map { afterTracks[$0.id] ?? $0 }
        var nextExplicitEndFrame = graph.explicitEndFrame ?? graph.endFrame
        if policy == .rippleExistingContent, let explicitEndFrame = graph.explicitEndFrame {
            let grouped = Dictionary(grouping: zip(requests, clips), by: { $0.0.trackID })
            let globalExpansion = grouped.compactMap { trackID, entries -> Int? in
                let insertionStart = rippleReservations[trackID]?.startFrame ??
                    entries.map { $0.1.timelineRange.startFrame }.min() ?? 0
                guard insertionStart <= explicitEndFrame else { return nil }
                let insertionEnd = entries.map { $0.1.timelineRange.endFrame }.max() ?? insertionStart
                return rippleReservations[trackID]?.frameCount ?? max(insertionEnd - insertionStart, 0)
            }.max() ?? 0
            nextExplicitEndFrame = explicitEndFrame + globalExpansion
        }
        let insertedContentEndFrame = clips.map(\.timelineRange.endFrame).max() ?? 0
        nextExplicitEndFrame = max(nextExplicitEndFrame, insertedContentEndFrame)
        let editedGraph = try TimelineClipGraph(
            sources: Array(sources.values).sorted { $0.id < $1.id },
            tracks: orderedTracks,
            revision: graph.revision &+ 1,
            timelineSampleRate: graph.timelineSampleRate,
            explicitEndFrame: nextExplicitEndFrame
        )
        return TimelineClipCommandResult(
            graph: editedGraph,
            affectedTrackIDs: affectedTrackIDs,
            beforeTracks: beforeTracks,
            afterTracks: orderedTracks.filter { affectedTrackIDs.contains($0.id) },
            affectedClipIDs: Set(clips.map(\.id)),
            sourceChanges: requests
                .map(\.source)
                .reduce(into: [TimelineMediaSourceID: TimelineMediaSource]()) {
                    $0[$1.id] = $1
                }
                .values
                .filter { graph.sources[$0.id] != $0 }
                .map {
                    TimelineMediaSourceChange(
                        id: $0.id,
                        before: graph.sources[$0.id],
                        after: $0
                    )
                },
            beforeExplicitEndFrame: graph.explicitEndFrame,
            afterExplicitEndFrame: editedGraph.explicitEndFrame
        )
    }

    private static func rippling(
        _ track: TimelineTrack,
        at insertionFrame: Int,
        by insertedFrameCount: Int
    ) throws -> TimelineTrack {
        guard insertedFrameCount > 0 else { return track }
        var result: [TimelineClip] = []
        for clip in track.clips {
            if clip.timelineRange.endFrame <= insertionFrame {
                result.append(clip)
                continue
            }
            if clip.timelineRange.startFrame >= insertionFrame {
                var shifted = clip
                shifted.timelineRange.startFrame += insertedFrameCount
                result.append(shifted)
                continue
            }

            guard !clip.isLocked else {
                throw TimelineClipGraphError.lockedClip(clip.id)
            }
            let leftTimelineFrames = insertionFrame - clip.timelineRange.startFrame
            let leftSourceFrames = max(
                Int((Double(leftTimelineFrames) * clip.sourceFrameScale).rounded()),
                1
            )
            let names = AudioTimelineClipSplitNames.derived(from: clip.name)
            var left = clip
            left.timelineRange.frameCount = leftTimelineFrames
            left.sourceRange.frameCount = leftSourceFrames
            left.name = names.left
            left.fades.fadeOutFrames = 0

            var rightFades = clip.fades
            rightFades.fadeInFrames = 0
            let right = TimelineClip(
                id: AudioTimelineClipID(),
                sourceID: clip.sourceID,
                timelineRange: TimelineFrameRange(
                    startFrame: insertionFrame + insertedFrameCount,
                    frameCount: clip.timelineRange.endFrame - insertionFrame
                ),
                sourceRange: TimelineFrameRange(
                    startFrame: clip.sourceRange.startFrame + leftSourceFrames,
                    frameCount: clip.sourceRange.frameCount - leftSourceFrames
                ),
                name: names.right,
                gain: clip.gain,
                gainEnvelope: clip.gainEnvelope,
                fades: rightFades,
                isMuted: clip.isMuted,
                isLocked: clip.isLocked,
                colorToken: clip.colorToken,
                metadata: clip.metadata
            )
            result.append(left)
            result.append(right)
        }
        var edited = track
        edited.replaceClips(result)
        return edited
    }
}

private extension TimelineClipGraph {
    func replacingTracksForValidation(_ tracks: [TimelineTrack]) throws -> TimelineClipGraph {
        try TimelineClipGraph(
            sources: Array(sources.values),
            tracks: tracks,
            revision: revision,
            timelineSampleRate: timelineSampleRate,
            explicitEndFrame: explicitEndFrame
        )
    }
}
