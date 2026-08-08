import Foundation

public enum TimelineClipTrimEdge: String, Codable, Sendable {
    case leading
    case trailing
}

public struct TimelineClipMove: Equatable, Sendable {
    public let clipID: AudioTimelineClipID
    public let destinationTrackID: UUID
    public let destinationStartFrame: Int

    public init(
        clipID: AudioTimelineClipID,
        destinationTrackID: UUID,
        destinationStartFrame: Int
    ) {
        self.clipID = clipID
        self.destinationTrackID = destinationTrackID
        self.destinationStartFrame = destinationStartFrame
    }
}

public struct TimelineClipDuplication: Equatable, Sendable {
    public let sourceTrackID: UUID
    public let clipID: AudioTimelineClipID
    public let destinationTrackID: UUID
    public let destinationStartFrame: Int
    public let newClipID: AudioTimelineClipID

    public init(
        sourceTrackID: UUID,
        clipID: AudioTimelineClipID,
        destinationTrackID: UUID,
        destinationStartFrame: Int,
        newClipID: AudioTimelineClipID
    ) {
        self.sourceTrackID = sourceTrackID
        self.clipID = clipID
        self.destinationTrackID = destinationTrackID
        self.destinationStartFrame = destinationStartFrame
        self.newClipID = newClipID
    }
}

public struct TimelineClipSourceReplacement: Equatable, Sendable {
    public let trackID: UUID
    public let clipID: AudioTimelineClipID
    public let sourceID: TimelineMediaSourceID
    public let sourceRange: TimelineFrameRange

    public init(trackID: UUID, clipID: AudioTimelineClipID, sourceID: TimelineMediaSourceID, sourceRange: TimelineFrameRange) {
        self.trackID = trackID
        self.clipID = clipID
        self.sourceID = sourceID
        self.sourceRange = sourceRange
    }
}

public struct TimelineClipReference: Equatable, Hashable, Sendable {
    public let trackID: UUID
    public let clipID: AudioTimelineClipID

    public init(trackID: UUID, clipID: AudioTimelineClipID) {
        self.trackID = trackID
        self.clipID = clipID
    }
}

public enum TimelineClipColorPatch: Equatable, Sendable {
    case unchanged
    case set(String?)
}

public struct TimelineClipPropertiesPatch: Equatable, Sendable {
    public var name: String?
    public var gain: Float?
    public var fades: TimelineClipFades?
    public var isMuted: Bool?
    public var isLocked: Bool?
    public var colorToken: TimelineClipColorPatch
    public var metadata: [String: String]?

    public init(
        name: String? = nil,
        gain: Float? = nil,
        fades: TimelineClipFades? = nil,
        isMuted: Bool? = nil,
        isLocked: Bool? = nil,
        colorToken: TimelineClipColorPatch = .unchanged,
        metadata: [String: String]? = nil
    ) {
        self.name = name
        self.gain = gain
        self.fades = fades
        self.isMuted = isMuted
        self.isLocked = isLocked
        self.colorToken = colorToken
        self.metadata = metadata
    }
}

public enum TimelineClipCommand: Equatable, Sendable {
    case insert(trackID: UUID, clip: TimelineClip)
    case remove(trackID: UUID, clipIDs: Set<AudioTimelineClipID>)
    case removeMany(Set<TimelineClipReference>)
    case split(
        trackID: UUID,
        clipID: AudioTimelineClipID,
        timelineFrame: Int,
        rightClipID: AudioTimelineClipID
    )
    case removeRegion(
        trackID: UUID,
        clipID: AudioTimelineClipID,
        localRange: TimelineFrameRange,
        rippleFollowingContent: Bool,
        rightClipID: AudioTimelineClipID
    )
    case move([TimelineClipMove])
    case trim(
        trackID: UUID,
        clipID: AudioTimelineClipID,
        edge: TimelineClipTrimEdge,
        timelineFrame: Int
    )
    case slip(trackID: UUID, clipID: AudioTimelineClipID, sourceFrameDelta: Int)
    case rollBoundary(trackID: UUID, leadingClipID: AudioTimelineClipID, trailingClipID: AudioTimelineClipID, timelineFrame: Int)
    case replaceSource(TimelineClipSourceReplacement)
    case duplicate(
        sourceTrackID: UUID,
        clipID: AudioTimelineClipID,
        destinationTrackID: UUID,
        destinationStartFrame: Int,
        newClipID: AudioTimelineClipID
    )
    case duplicateMany([TimelineClipDuplication])
    case insertTime(
        trackIDs: Set<UUID>,
        timelineFrame: Int,
        frameCount: Int,
        splitClipIDs: [AudioTimelineClipID: AudioTimelineClipID]
    )
    case mergeAdjacent(
        trackID: UUID,
        leadingClipID: AudioTimelineClipID,
        trailingClipID: AudioTimelineClipID
    )
    case setProperties(
        trackID: UUID,
        clipIDs: Set<AudioTimelineClipID>,
        patch: TimelineClipPropertiesPatch
    )
}

/// A narrow source-catalog delta retained by edit history.
///
/// A nil side means that the source did not exist in that graph state. Keeping
/// source changes beside track changes lets topology/media edits undo without
/// retaining an unrelated whole-project snapshot.
public struct TimelineMediaSourceChange: Equatable, Sendable {
    public let id: TimelineMediaSourceID
    public let before: TimelineMediaSource?
    public let after: TimelineMediaSource?

    public init(
        id: TimelineMediaSourceID,
        before: TimelineMediaSource?,
        after: TimelineMediaSource?
    ) {
        self.id = id
        self.before = before
        self.after = after
    }
}

public struct TimelineClipCommandResult: Equatable, Sendable {
    public let graph: TimelineClipGraph
    public let affectedTrackIDs: Set<UUID>
    public let beforeTracks: [TimelineTrack]
    public let afterTracks: [TimelineTrack]
    public let affectedClipIDs: Set<AudioTimelineClipID>
    public let beforeTrackOrder: [UUID]
    public let afterTrackOrder: [UUID]
    public let sourceChanges: [TimelineMediaSourceChange]
    public let beforeExplicitEndFrame: Int?
    public let afterExplicitEndFrame: Int?

    public init(
        graph: TimelineClipGraph,
        affectedTrackIDs: Set<UUID>? = nil,
        beforeTracks: [TimelineTrack],
        afterTracks: [TimelineTrack],
        affectedClipIDs: Set<AudioTimelineClipID>,
        beforeTrackOrder: [UUID]? = nil,
        afterTrackOrder: [UUID]? = nil,
        sourceChanges: [TimelineMediaSourceChange] = [],
        beforeExplicitEndFrame: Int?,
        afterExplicitEndFrame: Int?
    ) {
        self.graph = graph
        self.affectedTrackIDs = affectedTrackIDs ?? Set((beforeTracks + afterTracks).map(\.id))
        self.beforeTracks = beforeTracks
        self.afterTracks = afterTracks
        self.affectedClipIDs = affectedClipIDs
        let graphOrder = graph.tracks.map(\.id)
        self.beforeTrackOrder = beforeTrackOrder ?? graphOrder
        self.afterTrackOrder = afterTrackOrder ?? graphOrder
        self.sourceChanges = sourceChanges.sorted { $0.id < $1.id }
        self.beforeExplicitEndFrame = beforeExplicitEndFrame
        self.afterExplicitEndFrame = afterExplicitEndFrame
    }
}

public enum TimelineClipCommandExecutor {
    public static func apply(
        _ command: TimelineClipCommand,
        to graph: TimelineClipGraph,
        expectedRevision: UInt64
    ) throws -> TimelineClipCommandResult {
        guard graph.revision == expectedRevision else {
            throw TimelineClipGraphError.staleRevision(
                expected: expectedRevision,
                actual: graph.revision
            )
        }

        var tracksByID = Dictionary(uniqueKeysWithValues: graph.tracks.map { ($0.id, $0) })
        let affectedTrackIDs = try mutate(command, graph: graph, tracksByID: &tracksByID)
        let beforeTracks = graph.tracks.filter { affectedTrackIDs.contains($0.id) }
        let afterTracks = graph.tracks.compactMap { track in
            affectedTrackIDs.contains(track.id) ? tracksByID[track.id] : nil
        }
        let appendedTracks = affectedTrackIDs
            .subtracting(Set(graph.tracks.map(\.id)))
            .compactMap { tracksByID[$0] }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        var editedGraph = graph
        try editedGraph.replaceTracks(
            afterTracks + appendedTracks,
            revision: graph.revision &+ 1
        )
        if case let .insertTime(_, timelineFrame, frameCount, _) = command,
           let explicitEndFrame = graph.explicitEndFrame,
           timelineFrame <= explicitEndFrame {
            editedGraph.explicitEndFrame = explicitEndFrame + frameCount
        }
        return TimelineClipCommandResult(
            graph: editedGraph,
            affectedTrackIDs: affectedTrackIDs,
            beforeTracks: beforeTracks,
            afterTracks: afterTracks + appendedTracks,
            affectedClipIDs: affectedClipIDs(for: command),
            beforeExplicitEndFrame: graph.explicitEndFrame,
            afterExplicitEndFrame: editedGraph.explicitEndFrame
        )
    }

    private static func mutate(
        _ command: TimelineClipCommand,
        graph: TimelineClipGraph,
        tracksByID: inout [UUID: TimelineTrack]
    ) throws -> Set<UUID> {
        switch command {
        case let .insert(trackID, clip):
            guard graph.sources[clip.sourceID] != nil else {
                throw TimelineClipGraphError.missingSource(clip.sourceID)
            }
            try TimelineClipPlacementValidator.requireAllowed(
                [TimelineClipPlacement(
                    clipID: clip.id,
                    destinationTrackID: trackID,
                    timelineRange: clip.timelineRange
                )],
                in: graph
            )
            var track = try requireTrack(trackID, tracksByID)
            track.upsertClip(clip)
            tracksByID[trackID] = track
            return [trackID]

        case let .remove(trackID, clipIDs):
            var track = try requireTrack(trackID, tracksByID)
            for clipID in clipIDs {
                let clip = try requireClip(clipID, in: track)
                guard !clip.isLocked else {
                    throw TimelineClipGraphError.lockedClip(clipID)
                }
                track.removeClip(id: clipID)
            }
            tracksByID[trackID] = track
            return [trackID]

        case let .removeMany(references):
            guard !references.isEmpty else { return [] }
            let referencesByTrack = Dictionary(grouping: references, by: \.trackID)
            for (trackID, trackReferences) in referencesByTrack {
                var track = try requireTrack(trackID, tracksByID)
                for reference in trackReferences {
                    let clip = try requireClip(reference.clipID, in: track)
                    guard !clip.isLocked else {
                        throw TimelineClipGraphError.lockedClip(reference.clipID)
                    }
                    track.removeClip(id: reference.clipID)
                }
                tracksByID[trackID] = track
            }
            return Set(referencesByTrack.keys)

        case let .split(trackID, clipID, timelineFrame, rightClipID):
            var track = try requireTrack(trackID, tracksByID)
            let clip = try requireClip(clipID, in: track)
            guard !clip.isLocked else {
                throw TimelineClipGraphError.lockedClip(clipID)
            }
            guard clip.timelineRange.range.contains(timelineFrame), timelineFrame > clip.timelineRange.startFrame else {
                throw TimelineClipGraphError.invalidTimelineRange(clipID)
            }
            guard graph.location(of: rightClipID) == nil else {
                throw TimelineClipGraphError.duplicateClip(rightClipID)
            }
            let leftFrames = timelineFrame - clip.timelineRange.startFrame
            let rightFrames = clip.timelineRange.frameCount - leftFrames
            let leftSourceFrames = Int((Double(leftFrames) * clip.sourceFrameScale).rounded())
            let rightSourceFrames = clip.sourceRange.frameCount - leftSourceFrames
            let names = AudioTimelineClipSplitNames.derived(from: clip.name)
            let envelopeMid = envelopeMultiplier(for: clip, at: leftFrames)

            var left = clip
            left.timelineRange.frameCount = leftFrames
            left.sourceRange.frameCount = leftSourceFrames
            left.name = names.left
            left.fades.fadeOutFrames = 0
            left.fades.fadeInFrames = min(left.fades.fadeInFrames, leftFrames)
            left.gainEnvelope.endMultiplier = envelopeMid

            var right = TimelineClip(
                id: rightClipID,
                sourceID: clip.sourceID,
                timelineRange: TimelineFrameRange(startFrame: timelineFrame, frameCount: rightFrames),
                sourceRange: TimelineFrameRange(
                    startFrame: clip.sourceRange.startFrame + leftSourceFrames,
                    frameCount: rightSourceFrames
                ),
                name: names.right,
                gain: clip.gain,
                gainEnvelope: TimelineClipGainEnvelope(
                    startMultiplier: envelopeMid,
                    endMultiplier: clip.gainEnvelope.endMultiplier
                ),
                fades: clip.fades,
                isMuted: clip.isMuted,
                isLocked: clip.isLocked,
                colorToken: clip.colorToken,
                metadata: clip.metadata
            )
            right.fades.fadeInFrames = 0
            right.fades.fadeOutFrames = min(right.fades.fadeOutFrames, rightFrames)
            track.upsertClip(left)
            track.upsertClip(right)
            tracksByID[trackID] = track
            return [trackID]

        case let .removeRegion(trackID, clipID, localRange, rippleFollowingContent, rightClipID):
            var track = try requireTrack(trackID, tracksByID)
            let clip = try requireClip(clipID, in: track)
            guard !clip.isLocked else { throw TimelineClipGraphError.lockedClip(clipID) }
            guard
                localRange.startFrame >= 0,
                localRange.frameCount > 0,
                localRange.endFrame <= clip.timelineRange.frameCount
            else {
                throw TimelineClipGraphError.invalidTimelineRange(clipID)
            }

            let removedTimelineFrames = localRange.frameCount
            let sourceScale = clip.sourceFrameScale
            let removedSourceStart = Int((Double(localRange.startFrame) * sourceScale).rounded())
            let removedSourceFrames = Int((Double(localRange.frameCount) * sourceScale).rounded())
            let leftTimelineFrames = localRange.startFrame
            let rightTimelineFrames = clip.timelineRange.frameCount - localRange.endFrame
            let leftSourceFrames = removedSourceStart
            let rightSourceStart = clip.sourceRange.startFrame + removedSourceStart + removedSourceFrames
            let rightSourceFrames = max(clip.sourceRange.endFrame - rightSourceStart, 0)

            track.removeClip(id: clipID)
            if leftTimelineFrames > 0, leftSourceFrames > 0 {
                var left = clip
                left.timelineRange.frameCount = leftTimelineFrames
                left.sourceRange.frameCount = leftSourceFrames
                left.fades.fadeOutFrames = 0
                track.upsertClip(left)
            }
            if rightTimelineFrames > 0, rightSourceFrames > 0 {
                let right = TimelineClip(
                    id: leftTimelineFrames > 0 ? rightClipID : clipID,
                    sourceID: clip.sourceID,
                    timelineRange: TimelineFrameRange(
                        startFrame: clip.timelineRange.startFrame +
                            (rippleFollowingContent ? leftTimelineFrames : localRange.endFrame),
                        frameCount: rightTimelineFrames
                    ),
                    sourceRange: TimelineFrameRange(
                        startFrame: rightSourceStart,
                        frameCount: rightSourceFrames
                    ),
                    name: leftTimelineFrames > 0 ? AudioTimelineClipSplitNames.derived(from: clip.name).right : clip.name,
                    gain: clip.gain,
                    gainEnvelope: clip.gainEnvelope,
                    fades: TimelineClipFades(fadeInFrames: 0, fadeOutFrames: min(clip.fades.fadeOutFrames, rightTimelineFrames)),
                    isMuted: clip.isMuted,
                    isLocked: clip.isLocked,
                    colorToken: clip.colorToken,
                    metadata: clip.metadata
                )
                track.upsertClip(right)
            }
            if rippleFollowingContent {
                track.replaceClips(track.clips.map { candidate in
                    guard
                        candidate.id != clipID,
                        candidate.id != rightClipID,
                        candidate.timelineRange.startFrame >= clip.timelineRange.endFrame
                    else { return candidate }
                    var shifted = candidate
                    shifted.timelineRange.startFrame -= removedTimelineFrames
                    return shifted
                })
            }
            tracksByID[trackID] = track
            return [trackID]

        case let .move(moves):
            let placements = try moves.map { move -> TimelineClipPlacement in
                guard let location = graph.location(of: move.clipID) else {
                    throw TimelineClipGraphError.missingClip(move.clipID)
                }
                let clip = graph.tracks[location.trackIndex].clips[location.clipIndex]
                return TimelineClipPlacement(
                    clipID: clip.id,
                    destinationTrackID: move.destinationTrackID,
                    timelineRange: TimelineFrameRange(
                        startFrame: move.destinationStartFrame,
                        frameCount: clip.timelineRange.frameCount
                    )
                )
            }
            try TimelineClipPlacementValidator.requireAllowed(placements, in: graph)
            var movedClips: [AudioTimelineClipID: TimelineClip] = [:]
            var affectedTrackIDs = Set<UUID>()
            for move in moves {
                guard let location = graph.location(of: move.clipID) else {
                    throw TimelineClipGraphError.missingClip(move.clipID)
                }
                let sourceTrackID = graph.tracks[location.trackIndex].id
                var sourceTrack = try requireTrack(sourceTrackID, tracksByID)
                let clip = try requireClip(move.clipID, in: sourceTrack)
                guard !clip.isLocked else {
                    throw TimelineClipGraphError.lockedClip(move.clipID)
                }
                sourceTrack.removeClip(id: move.clipID)
                tracksByID[sourceTrackID] = sourceTrack
                movedClips[move.clipID] = clip
                affectedTrackIDs.insert(sourceTrackID)
                affectedTrackIDs.insert(move.destinationTrackID)
            }
            for move in moves {
                var destination = try requireTrack(move.destinationTrackID, tracksByID)
                guard var clip = movedClips[move.clipID] else {
                    throw TimelineClipGraphError.missingClip(move.clipID)
                }
                clip.timelineRange.startFrame = move.destinationStartFrame
                destination.upsertClip(clip)
                tracksByID[move.destinationTrackID] = destination
            }
            return affectedTrackIDs

        case let .trim(trackID, clipID, edge, timelineFrame):
            var track = try requireTrack(trackID, tracksByID)
            var clip = try requireClip(clipID, in: track)
            let originalSourceFrameScale = clip.sourceFrameScale
            guard !clip.isLocked else {
                throw TimelineClipGraphError.lockedClip(clipID)
            }
            switch edge {
            case .leading:
                let delta = timelineFrame - clip.timelineRange.startFrame
                guard delta >= 0, delta < clip.timelineRange.frameCount else {
                    throw TimelineClipGraphError.invalidTimelineRange(clipID)
                }
                let sourceDelta = Int((Double(delta) * clip.sourceFrameScale).rounded())
                clip.timelineRange.startFrame += delta
                clip.timelineRange.frameCount -= delta
                clip.sourceRange.startFrame += sourceDelta
                clip.sourceRange.frameCount -= sourceDelta
                clip.fades.fadeInFrames = min(clip.fades.fadeInFrames, clip.timelineRange.frameCount)
            case .trailing:
                let newFrameCount = timelineFrame - clip.timelineRange.startFrame
                guard newFrameCount > 0, newFrameCount <= clip.timelineRange.frameCount else {
                    throw TimelineClipGraphError.invalidTimelineRange(clipID)
                }
                clip.timelineRange.frameCount = newFrameCount
                clip.sourceRange.frameCount = max(
                    Int((Double(newFrameCount) * originalSourceFrameScale).rounded()),
                    1
                )
                clip.fades.fadeOutFrames = min(clip.fades.fadeOutFrames, clip.timelineRange.frameCount)
            }
            if clip.fades.fadeInFrames + clip.fades.fadeOutFrames > clip.timelineRange.frameCount {
                clip.fades = TimelineClipFades()
            }
            track.upsertClip(clip)
            tracksByID[trackID] = track
            return [trackID]

        case let .slip(trackID, clipID, sourceFrameDelta):
            var track = try requireTrack(trackID, tracksByID)
            var clip = try requireClip(clipID, in: track)
            guard !clip.isLocked else {
                throw TimelineClipGraphError.lockedClip(clipID)
            }
            guard let source = graph.source(id: clip.sourceID) else {
                throw TimelineClipGraphError.missingSource(clip.sourceID)
            }
            let nextSourceStart = clip.sourceRange.startFrame + sourceFrameDelta
            guard nextSourceStart >= 0, nextSourceStart + clip.sourceRange.frameCount <= source.frameCount else {
                throw TimelineClipGraphError.sourceRangeOutOfBounds(clipID, clip.sourceID)
            }
            clip.sourceRange.startFrame = nextSourceStart
            track.upsertClip(clip)
            tracksByID[trackID] = track
            return [trackID]

        case let .rollBoundary(trackID, leadingClipID, trailingClipID, timelineFrame):
            var track = try requireTrack(trackID, tracksByID)
            var leading = try requireClip(leadingClipID, in: track)
            var trailing = try requireClip(trailingClipID, in: track)
            guard !leading.isLocked, !trailing.isLocked else {
                throw TimelineClipGraphError.lockedClip(leading.isLocked ? leading.id : trailing.id)
            }
            guard leading.timelineRange.endFrame == trailing.timelineRange.startFrame else {
                throw TimelineClipGraphError.clipsNotAdjacent(leadingClipID, trailingClipID)
            }
            let delta = timelineFrame - leading.timelineRange.endFrame
            let leadingCount = leading.timelineRange.frameCount + delta
            let trailingCount = trailing.timelineRange.frameCount - delta
            guard leadingCount > 0, trailingCount > 0 else {
                throw TimelineClipGraphError.invalidTimelineRange(delta < 0 ? leadingClipID : trailingClipID)
            }
            let leadingSourceDelta = Int((Double(delta) * leading.sourceFrameScale).rounded())
            let trailingSourceDelta = Int((Double(delta) * trailing.sourceFrameScale).rounded())
            guard
                let leadingSource = graph.source(id: leading.sourceID),
                let trailingSource = graph.source(id: trailing.sourceID),
                leading.sourceRange.frameCount + leadingSourceDelta > 0,
                leading.sourceRange.endFrame + leadingSourceDelta <= leadingSource.frameCount,
                trailing.sourceRange.startFrame + trailingSourceDelta >= 0,
                trailing.sourceRange.frameCount - trailingSourceDelta > 0,
                trailing.sourceRange.endFrame <= trailingSource.frameCount
            else { throw TimelineClipGraphError.invalidSourceRange(delta < 0 ? leadingClipID : trailingClipID) }
            leading.timelineRange.frameCount = leadingCount
            leading.sourceRange.frameCount += leadingSourceDelta
            leading.fades.fadeOutFrames = min(leading.fades.fadeOutFrames, leadingCount)
            trailing.timelineRange.startFrame = timelineFrame
            trailing.timelineRange.frameCount = trailingCount
            trailing.sourceRange.startFrame += trailingSourceDelta
            trailing.sourceRange.frameCount -= trailingSourceDelta
            trailing.fades.fadeInFrames = min(trailing.fades.fadeInFrames, trailingCount)
            track.upsertClip(leading)
            track.upsertClip(trailing)
            tracksByID[trackID] = track
            return [trackID]

        case let .replaceSource(replacement):
            var track = try requireTrack(replacement.trackID, tracksByID)
            var clip = try requireClip(replacement.clipID, in: track)
            guard !clip.isLocked else { throw TimelineClipGraphError.lockedClip(clip.id) }
            guard let source = graph.source(id: replacement.sourceID) else {
                throw TimelineClipGraphError.missingSource(replacement.sourceID)
            }
            guard replacement.sourceRange.startFrame >= 0,
                  replacement.sourceRange.frameCount > 0,
                  replacement.sourceRange.endFrame <= source.frameCount else {
                throw TimelineClipGraphError.sourceRangeOutOfBounds(clip.id, replacement.sourceID)
            }
            clip.sourceID = replacement.sourceID
            clip.sourceRange = replacement.sourceRange
            track.upsertClip(clip)
            tracksByID[replacement.trackID] = track
            return [replacement.trackID]

        case let .duplicate(sourceTrackID, clipID, destinationTrackID, destinationStartFrame, newClipID):
            let sourceTrack = try requireTrack(sourceTrackID, tracksByID)
            var destination = try requireTrack(destinationTrackID, tracksByID)
            var copy = try requireClip(clipID, in: sourceTrack)
            guard graph.location(of: newClipID) == nil else {
                throw TimelineClipGraphError.duplicateClip(newClipID)
            }
            try TimelineClipPlacementValidator.requireAllowed(
                [TimelineClipPlacement(
                    clipID: newClipID,
                    destinationTrackID: destinationTrackID,
                    timelineRange: TimelineFrameRange(
                        startFrame: destinationStartFrame,
                        frameCount: copy.timelineRange.frameCount
                    )
                )],
                in: graph
            )
            copy = TimelineClip(
                id: newClipID,
                sourceID: copy.sourceID,
                timelineRange: TimelineFrameRange(
                    startFrame: destinationStartFrame,
                    frameCount: copy.timelineRange.frameCount
                ),
                sourceRange: copy.sourceRange,
                name: "\(copy.name) copy",
                gain: copy.gain,
                gainEnvelope: copy.gainEnvelope,
                fades: copy.fades,
                isMuted: copy.isMuted,
                isLocked: false,
                colorToken: copy.colorToken,
                metadata: copy.metadata
            )
            destination.upsertClip(copy)
            tracksByID[destinationTrackID] = destination
            return [sourceTrackID, destinationTrackID]

        case let .duplicateMany(duplications):
            guard !duplications.isEmpty else { return [] }
            let newIDs = duplications.map(\.newClipID)
            guard Set(newIDs).count == newIDs.count else {
                throw TimelineClipGraphError.duplicateClip(newIDs[0])
            }
            for newID in newIDs where graph.location(of: newID) != nil {
                throw TimelineClipGraphError.duplicateClip(newID)
            }
            let placements = try duplications.map { duplication -> TimelineClipPlacement in
                let sourceTrack = try requireTrack(duplication.sourceTrackID, tracksByID)
                let clip = try requireClip(duplication.clipID, in: sourceTrack)
                guard !clip.isLocked else {
                    throw TimelineClipGraphError.lockedClip(duplication.clipID)
                }
                return TimelineClipPlacement(
                    clipID: duplication.newClipID,
                    destinationTrackID: duplication.destinationTrackID,
                    timelineRange: TimelineFrameRange(
                        startFrame: duplication.destinationStartFrame,
                        frameCount: clip.timelineRange.frameCount
                    )
                )
            }
            try TimelineClipPlacementValidator.requireAllowed(placements, in: graph)

            var affectedTrackIDs = Set<UUID>()
            for duplication in duplications {
                let sourceTrack = try requireTrack(duplication.sourceTrackID, tracksByID)
                var destination = try requireTrack(duplication.destinationTrackID, tracksByID)
                let source = try requireClip(duplication.clipID, in: sourceTrack)
                let copy = TimelineClip(
                    id: duplication.newClipID,
                    sourceID: source.sourceID,
                    timelineRange: TimelineFrameRange(
                        startFrame: duplication.destinationStartFrame,
                        frameCount: source.timelineRange.frameCount
                    ),
                    sourceRange: source.sourceRange,
                    name: "\(source.name) copy",
                    gain: source.gain,
                    gainEnvelope: source.gainEnvelope,
                    fades: source.fades,
                    isMuted: source.isMuted,
                    isLocked: false,
                    colorToken: source.colorToken,
                    metadata: source.metadata
                )
                destination.upsertClip(copy)
                tracksByID[duplication.destinationTrackID] = destination
                affectedTrackIDs.formUnion([
                    duplication.sourceTrackID,
                    duplication.destinationTrackID,
                ])
            }
            return affectedTrackIDs

        case let .insertTime(trackIDs, timelineFrame, frameCount, splitClipIDs):
            guard timelineFrame >= 0, frameCount > 0 else {
                throw TimelineClipGraphError.invalidTimelineSampleRate
            }
            for trackID in trackIDs {
                var track = try requireTrack(trackID, tracksByID)
                var output: [TimelineClip] = []
                for clip in track.clips {
                    if clip.timelineRange.endFrame <= timelineFrame {
                        output.append(clip)
                    } else if clip.timelineRange.startFrame >= timelineFrame {
                        guard !clip.isLocked else { throw TimelineClipGraphError.lockedClip(clip.id) }
                        var shifted = clip
                        shifted.timelineRange.startFrame += frameCount
                        output.append(shifted)
                    } else {
                        guard !clip.isLocked else { throw TimelineClipGraphError.lockedClip(clip.id) }
                        guard
                            let rightClipID = splitClipIDs[clip.id],
                            graph.location(of: rightClipID) == nil
                        else { throw TimelineClipGraphError.duplicateClip(splitClipIDs[clip.id] ?? clip.id) }
                        let split = splitClip(
                            clip,
                            timelineFrame: timelineFrame,
                            rightClipID: rightClipID,
                            rightTimelineStartFrame: timelineFrame + frameCount
                        )
                        output.append(split.left)
                        output.append(split.right)
                    }
                }
                track.replaceClips(output)
                tracksByID[trackID] = track
            }
            return trackIDs

        case let .mergeAdjacent(trackID, leadingClipID, trailingClipID):
            var track = try requireTrack(trackID, tracksByID)
            let leading = try requireClip(leadingClipID, in: track)
            let trailing = try requireClip(trailingClipID, in: track)
            guard !leading.isLocked, !trailing.isLocked else {
                throw TimelineClipGraphError.lockedClip(leading.isLocked ? leading.id : trailing.id)
            }
            guard
                leading.sourceID == trailing.sourceID,
                leading.timelineRange.endFrame == trailing.timelineRange.startFrame,
                leading.sourceRange.endFrame == trailing.sourceRange.startFrame,
                leading.gain == trailing.gain,
                leading.isMuted == trailing.isMuted,
                leading.colorToken == trailing.colorToken,
                leading.metadata == trailing.metadata,
                leading.gainEnvelope.endMultiplier == trailing.gainEnvelope.startMultiplier
            else { throw TimelineClipGraphError.invalidTimelineRange(leadingClipID) }

            var merged = leading
            merged.timelineRange.frameCount += trailing.timelineRange.frameCount
            merged.sourceRange.frameCount += trailing.sourceRange.frameCount
            merged.gainEnvelope.endMultiplier = trailing.gainEnvelope.endMultiplier
            merged.fades = TimelineClipFades(
                fadeInFrames: leading.fades.fadeInFrames,
                fadeOutFrames: trailing.fades.fadeOutFrames
            )
            track.removeClip(id: trailingClipID)
            track.upsertClip(merged)
            tracksByID[trackID] = track
            return [trackID]

        case let .setProperties(trackID, clipIDs, patch):
            var track = try requireTrack(trackID, tracksByID)
            for clipID in clipIDs {
                var clip = try requireClip(clipID, in: track)
                if let name = patch.name { clip.name = name }
                if let gain = patch.gain { clip.gain = gain }
                if let fades = patch.fades { clip.fades = fades }
                if let isMuted = patch.isMuted { clip.isMuted = isMuted }
                if let isLocked = patch.isLocked { clip.isLocked = isLocked }
                if case let .set(colorToken) = patch.colorToken {
                    clip.colorToken = colorToken
                }
                if let metadata = patch.metadata { clip.metadata = metadata }
                track.upsertClip(clip)
            }
            tracksByID[trackID] = track
            return [trackID]
        }
    }

    private static func requireTrack(
        _ id: UUID,
        _ tracksByID: [UUID: TimelineTrack]
    ) throws -> TimelineTrack {
        guard let track = tracksByID[id] else {
            throw TimelineClipGraphError.missingTrack(id)
        }
        return track
    }

    private static func requireClip(
        _ id: AudioTimelineClipID,
        in track: TimelineTrack
    ) throws -> TimelineClip {
        guard let clip = track.clip(id: id) else {
            throw TimelineClipGraphError.missingClip(id)
        }
        return clip
    }

    private static func envelopeMultiplier(for clip: TimelineClip, at frame: Int) -> Float {
        guard clip.timelineRange.frameCount > 1 else {
            return clip.gainEnvelope.endMultiplier
        }
        let progress = Float(frame) / Float(clip.timelineRange.frameCount - 1)
        let curve = progress * progress * (3 - 2 * progress)
        return clip.gainEnvelope.startMultiplier +
            (clip.gainEnvelope.endMultiplier - clip.gainEnvelope.startMultiplier) * curve
    }

    private static func splitClip(
        _ clip: TimelineClip,
        timelineFrame: Int,
        rightClipID: AudioTimelineClipID,
        rightTimelineStartFrame: Int
    ) -> (left: TimelineClip, right: TimelineClip) {
        let leftFrames = timelineFrame - clip.timelineRange.startFrame
        let rightFrames = clip.timelineRange.frameCount - leftFrames
        let leftSourceFrames = Int((Double(leftFrames) * clip.sourceFrameScale).rounded())
        let names = AudioTimelineClipSplitNames.derived(from: clip.name)
        let envelopeMid = envelopeMultiplier(for: clip, at: leftFrames)

        var left = clip
        left.timelineRange.frameCount = leftFrames
        left.sourceRange.frameCount = leftSourceFrames
        left.name = names.left
        left.fades.fadeOutFrames = 0
        left.fades.fadeInFrames = min(left.fades.fadeInFrames, leftFrames)
        left.gainEnvelope.endMultiplier = envelopeMid

        let right = TimelineClip(
            id: rightClipID,
            sourceID: clip.sourceID,
            timelineRange: TimelineFrameRange(startFrame: rightTimelineStartFrame, frameCount: rightFrames),
            sourceRange: TimelineFrameRange(
                startFrame: clip.sourceRange.startFrame + leftSourceFrames,
                frameCount: clip.sourceRange.frameCount - leftSourceFrames
            ),
            name: names.right,
            gain: clip.gain,
            gainEnvelope: TimelineClipGainEnvelope(
                startMultiplier: envelopeMid,
                endMultiplier: clip.gainEnvelope.endMultiplier
            ),
            fades: TimelineClipFades(
                fadeInFrames: 0,
                fadeOutFrames: min(clip.fades.fadeOutFrames, rightFrames)
            ),
            isMuted: clip.isMuted,
            isLocked: clip.isLocked,
            colorToken: clip.colorToken,
            metadata: clip.metadata
        )
        return (left, right)
    }

    private static func affectedClipIDs(for command: TimelineClipCommand) -> Set<AudioTimelineClipID> {
        switch command {
        case let .insert(_, clip): return [clip.id]
        case let .remove(_, clipIDs): return clipIDs
        case let .removeMany(references): return Set(references.map(\.clipID))
        case let .split(_, clipID, _, rightClipID): return [clipID, rightClipID]
        case let .removeRegion(_, clipID, _, _, rightClipID): return [clipID, rightClipID]
        case let .move(moves): return Set(moves.map(\.clipID))
        case let .trim(_, clipID, _, _): return [clipID]
        case let .slip(_, clipID, _): return [clipID]
        case let .rollBoundary(_, leadingClipID, trailingClipID, _): return [leadingClipID, trailingClipID]
        case let .replaceSource(replacement): return [replacement.clipID]
        case let .duplicate(_, clipID, _, _, newClipID): return [clipID, newClipID]
        case let .duplicateMany(duplications):
            return Set(duplications.flatMap { [$0.clipID, $0.newClipID] })
        case let .insertTime(_, _, _, splitClipIDs):
            return Set(splitClipIDs.keys).union(splitClipIDs.values)
        case let .mergeAdjacent(_, leadingClipID, trailingClipID):
            return [leadingClipID, trailingClipID]
        case let .setProperties(_, clipIDs, _): return clipIDs
        }
    }
}
