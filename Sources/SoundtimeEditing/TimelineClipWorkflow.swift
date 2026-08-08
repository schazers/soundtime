import Foundation

public enum TimelineClipSnapTargetKind: String, Codable, Sendable {
    case timelineStart
    case timelineEnd
    case clipEdge
    case playhead
    case loopBoundary
    case marker
    case transient
    case grid
}

public struct TimelineClipSnapTarget: Equatable, Codable, Sendable {
    public let frame: Int
    public let kind: TimelineClipSnapTargetKind
    public let label: String?

    public init(frame: Int, kind: TimelineClipSnapTargetKind, label: String? = nil) {
        self.frame = frame
        self.kind = kind
        self.label = label
    }
}

public struct TimelineClipSnapConfiguration: Equatable, Sendable {
    public var isEnabled: Bool
    public var toleranceFrames: Int
    public var enabledKinds: Set<TimelineClipSnapTargetKind>

    public init(
        isEnabled: Bool = true,
        toleranceFrames: Int,
        enabledKinds: Set<TimelineClipSnapTargetKind> = Set([
            .timelineStart, .timelineEnd, .clipEdge, .playhead, .loopBoundary, .marker, .transient, .grid,
        ])
    ) {
        self.isEnabled = isEnabled
        self.toleranceFrames = max(toleranceFrames, 0)
        self.enabledKinds = enabledKinds
    }
}

public struct TimelineClipSnapResult: Equatable, Sendable {
    public let frame: Int
    public let delta: Int
    public let target: TimelineClipSnapTarget?

    public init(frame: Int, delta: Int, target: TimelineClipSnapTarget?) {
        self.frame = frame
        self.delta = delta
        self.target = target
    }
}

public enum TimelineClipSnapEngine {
    public static func snap(
        frame: Int,
        targets: [TimelineClipSnapTarget],
        configuration: TimelineClipSnapConfiguration
    ) -> TimelineClipSnapResult {
        guard configuration.isEnabled else {
            return TimelineClipSnapResult(frame: frame, delta: 0, target: nil)
        }
        let candidate = targets
            .filter { configuration.enabledKinds.contains($0.kind) }
            .map { ($0, $0.frame - frame) }
            .filter { abs($0.1) <= configuration.toleranceFrames }
            .min { lhs, rhs in
                if abs(lhs.1) != abs(rhs.1) { return abs(lhs.1) < abs(rhs.1) }
                if lhs.0.frame != rhs.0.frame { return lhs.0.frame < rhs.0.frame }
                return lhs.0.kind.rawValue < rhs.0.kind.rawValue
            }
        guard let candidate else {
            return TimelineClipSnapResult(frame: frame, delta: 0, target: nil)
        }
        return TimelineClipSnapResult(
            frame: frame + candidate.1,
            delta: candidate.1,
            target: candidate.0
        )
    }
}

public enum TimelineClipSelectionPlanner {
    public static func following(
        anchor: TimelineClipReference,
        in graph: TimelineClipGraph,
        acrossTracks: Bool
    ) throws -> Set<TimelineClipReference> {
        guard let location = graph.location(of: anchor.clipID) else {
            throw TimelineClipGraphError.missingClip(anchor.clipID)
        }
        let anchorClip = graph.tracks[location.trackIndex].clips[location.clipIndex]
        return Set(graph.tracks.flatMap { track -> [TimelineClipReference] in
            guard acrossTracks || track.id == anchor.trackID else { return [] }
            return track.clips.compactMap { clip -> TimelineClipReference? in
                clip.timelineRange.startFrame >= anchorClip.timelineRange.startFrame
                    ? TimelineClipReference(trackID: track.id, clipID: clip.id)
                    : nil
            }
        })
    }

    public static func contained(
        in range: TimelineFrameRange,
        graph: TimelineClipGraph,
        trackIDs: Set<UUID>? = nil
    ) -> Set<TimelineClipReference> {
        Set(graph.tracks.flatMap { track -> [TimelineClipReference] in
            guard trackIDs == nil || trackIDs!.contains(track.id) else { return [] }
            return track.clips.compactMap { clip -> TimelineClipReference? in
                clip.timelineRange.startFrame >= range.startFrame && clip.timelineRange.endFrame <= range.endFrame
                    ? TimelineClipReference(trackID: track.id, clipID: clip.id)
                    : nil
            }
        })
    }
}

public enum TimelineClipGrouping {
    public static let groupMetadataKey = "soundtime.clipGroupID"

    public static func groupID(for clip: TimelineClip) -> UUID? {
        clip.metadata[groupMetadataKey].flatMap(UUID.init(uuidString:))
    }

    public static func commands(
        references: Set<TimelineClipReference>,
        groupID: UUID?,
        graph: TimelineClipGraph
    ) throws -> [TimelineClipCommand] {
        try references.map { reference in
            guard
                let track = graph.track(id: reference.trackID),
                let clip = track.clip(id: reference.clipID)
            else { throw TimelineClipGraphError.missingClip(reference.clipID) }
            var metadata = clip.metadata
            if let groupID {
                metadata[groupMetadataKey] = groupID.uuidString
            } else {
                metadata.removeValue(forKey: groupMetadataKey)
            }
            return .setProperties(
                trackID: reference.trackID,
                clipIDs: [reference.clipID],
                patch: TimelineClipPropertiesPatch(metadata: metadata)
            )
        }
    }

    public static func members(of clipID: AudioTimelineClipID, in graph: TimelineClipGraph) -> Set<TimelineClipReference> {
        guard
            let location = graph.location(of: clipID),
            let targetGroupID = groupID(for: graph.tracks[location.trackIndex].clips[location.clipIndex])
        else { return [] }
        return Set(graph.tracks.flatMap { track -> [TimelineClipReference] in
            track.clips.compactMap { clip -> TimelineClipReference? in
                groupID(for: clip) == targetGroupID ? TimelineClipReference(trackID: track.id, clipID: clip.id) : nil
            }
        })
    }
}

public enum TimelineClipRepeatPlanner {
    public static func duplications(
        reference: TimelineClipReference,
        count: Int,
        gapFrames: Int = 0,
        in graph: TimelineClipGraph,
        makeID: () -> AudioTimelineClipID = { AudioTimelineClipID() }
    ) throws -> [TimelineClipDuplication] {
        guard let location = graph.location(of: reference.clipID) else {
            throw TimelineClipGraphError.missingClip(reference.clipID)
        }
        let clip = graph.tracks[location.trackIndex].clips[location.clipIndex]
        guard count > 0, gapFrames >= 0 else { return [] }
        return (1...count).map { index in
            TimelineClipDuplication(
                sourceTrackID: reference.trackID,
                clipID: reference.clipID,
                destinationTrackID: reference.trackID,
                destinationStartFrame: clip.timelineRange.startFrame + index * (clip.timelineRange.frameCount + gapFrames),
                newClipID: makeID()
            )
        }
    }
}

public struct TimelineClipCrossfadePlan: Equatable, Sendable {
    public let leading: TimelineClipReference
    public let trailing: TimelineClipReference
    public let durationFrames: Int

    public init(leading: TimelineClipReference, trailing: TimelineClipReference, durationFrames: Int) {
        self.leading = leading
        self.trailing = trailing
        self.durationFrames = durationFrames
    }
}

public enum TimelineClipCrossfadePlanner {
    public static func plan(
        trackID: UUID,
        leadingClipID: AudioTimelineClipID,
        trailingClipID: AudioTimelineClipID,
        durationFrames: Int,
        graph: TimelineClipGraph
    ) throws -> TimelineClipCrossfadePlan {
        guard let track = graph.track(id: trackID) else { throw TimelineClipGraphError.missingTrack(trackID) }
        guard let leading = track.clip(id: leadingClipID) else { throw TimelineClipGraphError.missingClip(leadingClipID) }
        guard let trailing = track.clip(id: trailingClipID) else { throw TimelineClipGraphError.missingClip(trailingClipID) }
        guard leading.timelineRange.endFrame == trailing.timelineRange.startFrame else {
            throw TimelineClipGraphError.clipsNotAdjacent(leadingClipID, trailingClipID)
        }
        let duration = min(max(durationFrames, 0), leading.timelineRange.frameCount, trailing.timelineRange.frameCount)
        return TimelineClipCrossfadePlan(
            leading: TimelineClipReference(trackID: trackID, clipID: leadingClipID),
            trailing: TimelineClipReference(trackID: trackID, clipID: trailingClipID),
            durationFrames: duration
        )
    }
}

public struct TimelineClipConsolidationPlan: Equatable, Sendable {
    public let trackID: UUID
    public let clipIDs: [AudioTimelineClipID]
    public let renderRange: TimelineFrameRange
    public let destinationName: String

    public init(trackID: UUID, clipIDs: [AudioTimelineClipID], renderRange: TimelineFrameRange, destinationName: String) {
        self.trackID = trackID
        self.clipIDs = clipIDs
        self.renderRange = renderRange
        self.destinationName = destinationName
    }
}

public enum TimelineClipConsolidationPlanner {
    public static func plan(
        trackID: UUID,
        clipIDs: Set<AudioTimelineClipID>,
        destinationName: String,
        graph: TimelineClipGraph
    ) throws -> TimelineClipConsolidationPlan {
        guard let track = graph.track(id: trackID) else { throw TimelineClipGraphError.missingTrack(trackID) }
        let clips = track.clips.filter { clipIDs.contains($0.id) }
        guard clips.count == clipIDs.count, let start = clips.map(\.timelineRange.startFrame).min(),
              let end = clips.map(\.timelineRange.endFrame).max() else {
            throw TimelineClipGraphError.missingClip(clipIDs.first ?? AudioTimelineClipID())
        }
        return TimelineClipConsolidationPlan(
            trackID: trackID,
            clipIDs: clips.sorted { $0.timelineRange.startFrame < $1.timelineRange.startFrame }.map(\.id),
            renderRange: TimelineFrameRange(startFrame: start, frameCount: end - start),
            destinationName: destinationName
        )
    }
}

public struct TimelineTakeLane: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var clipIDs: [AudioTimelineClipID]
    public var isActive: Bool

    public init(id: UUID = UUID(), name: String, clipIDs: [AudioTimelineClipID], isActive: Bool = false) {
        self.id = id
        self.name = name
        self.clipIDs = clipIDs
        self.isActive = isActive
    }
}

public struct TimelineCompSection: Equatable, Codable, Sendable {
    public let laneID: UUID
    public let timelineRange: TimelineFrameRange

    public init(laneID: UUID, timelineRange: TimelineFrameRange) {
        self.laneID = laneID
        self.timelineRange = timelineRange
    }
}
