import Foundation

public enum TimelineClipCollisionPolicy: String, Codable, Sendable {
    case rejectOverlaps
}

/// The output topology of a timeline track.
///
/// This is persisted independently from the media currently placed on the
/// track. Inserting stereo media promotes a mono track to stereo; removing
/// that media never silently collapses the track back to mono.
public enum TrackChannelLayout: String, Codable, Sendable, CaseIterable {
    case mono
    case stereo

    public var channelCount: Int {
        switch self {
        case .mono: 1
        case .stereo: 2
        }
    }

    public static func forSourceChannelCount(_ channelCount: Int) -> Self {
        channelCount <= 1 ? .mono : .stereo
    }

    public func promoted(forSourceChannelCount channelCount: Int) -> Self {
        channelCount > 1 ? .stereo : self
    }
}

public struct TimelineTrack: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public private(set) var clips: [TimelineClip]
    public var volume: Float
    /// Static track pan in the audible domain: -1 is full left, 0 is center, 1 is full right.
    public var pan: Float
    public var isMuted: Bool
    public var isSoloed: Bool
    public var isLocked: Bool
    public var colorToken: String?
    public var metadata: [String: String]
    public var collisionPolicy: TimelineClipCollisionPolicy
    public var channelLayout: TrackChannelLayout

    public init(
        id: UUID = UUID(),
        name: String,
        clips: [TimelineClip] = [],
        volume: Float = 1,
        pan: Float = 0,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        isLocked: Bool = false,
        colorToken: String? = nil,
        metadata: [String: String] = [:],
        collisionPolicy: TimelineClipCollisionPolicy = .rejectOverlaps,
        channelLayout: TrackChannelLayout = .stereo
    ) {
        self.id = id
        self.name = name
        self.clips = Self.sorted(clips)
        self.volume = volume
        self.pan = min(max(pan, -1), 1)
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.isLocked = isLocked
        self.colorToken = colorToken
        self.metadata = metadata
        self.collisionPolicy = collisionPolicy
        self.channelLayout = channelLayout
    }

    public var endFrame: Int {
        // Clips are maintained in timeline order and validated as non-overlapping,
        // so the final clip is also the track's furthest extent. This accessor is
        // render- and hydration-adjacent and must remain O(1) for dense projects.
        clips.last?.timelineRange.endFrame ?? 0
    }

    public func implicitGaps(within bounds: TimelineFrameRange) -> [TimelineFrameRange] {
        guard bounds.frameCount > 0 else {
            return []
        }

        var cursor = bounds.startFrame
        var gaps: [TimelineFrameRange] = []
        for clip in clips {
            let clippedStart = max(clip.timelineRange.startFrame, bounds.startFrame)
            let clippedEnd = min(clip.timelineRange.endFrame, bounds.endFrame)
            guard clippedEnd > bounds.startFrame, clippedStart < bounds.endFrame else {
                continue
            }
            if clippedStart > cursor {
                gaps.append(TimelineFrameRange(startFrame: cursor, frameCount: clippedStart - cursor))
            }
            cursor = max(cursor, clippedEnd)
        }
        if cursor < bounds.endFrame {
            gaps.append(TimelineFrameRange(startFrame: cursor, frameCount: bounds.endFrame - cursor))
        }
        return gaps
    }

    public func clip(id: AudioTimelineClipID) -> TimelineClip? {
        clips.first { $0.id == id }
    }

    public func clipIndex(id: AudioTimelineClipID) -> Int? {
        clips.firstIndex { $0.id == id }
    }

    public func conflicts(
        with range: TimelineFrameRange,
        excluding excludedIDs: Set<AudioTimelineClipID> = []
    ) -> [TimelineClip] {
        clips.filter { clip in
            !excludedIDs.contains(clip.id) && clip.timelineRange.intersects(range)
        }
    }

    public mutating func replaceClips(_ clips: [TimelineClip]) {
        self.clips = Self.sorted(clips)
    }

    public mutating func upsertClip(_ clip: TimelineClip) {
        if let index = clipIndex(id: clip.id) {
            clips[index] = clip
        } else {
            clips.append(clip)
        }
        clips = Self.sorted(clips)
    }

    @discardableResult
    public mutating func removeClip(id: AudioTimelineClipID) -> TimelineClip? {
        guard let index = clipIndex(id: id) else {
            return nil
        }
        return clips.remove(at: index)
    }

    public func validate(sources: [TimelineMediaSourceID: TimelineMediaSource]) throws {
        guard volume.isFinite, volume >= 0 else {
            throw TimelineClipGraphError.invalidTrackVolume(id)
        }
        guard pan.isFinite, (-1 ... 1).contains(pan) else {
            throw TimelineClipGraphError.invalidTrackPan(id)
        }

        var seen = Set<AudioTimelineClipID>()
        for clip in clips {
            guard seen.insert(clip.id).inserted else {
                throw TimelineClipGraphError.duplicateClip(clip.id)
            }
            try clip.validate(against: sources[clip.sourceID])
        }

        guard collisionPolicy == .rejectOverlaps else {
            return
        }
        guard clips.count > 1 else {
            return
        }
        for pairIndex in 1..<clips.count {
            let previous = clips[pairIndex - 1]
            let current = clips[pairIndex]
            guard previous.timelineRange.endFrame <= current.timelineRange.startFrame else {
                throw TimelineClipGraphError.trackOverlap(
                    trackID: id,
                    first: previous.id,
                    second: current.id
                )
            }
        }
    }

    private static func sorted(_ clips: [TimelineClip]) -> [TimelineClip] {
        clips.sorted { lhs, rhs in
            if lhs.timelineRange.startFrame != rhs.timelineRange.startFrame {
                return lhs.timelineRange.startFrame < rhs.timelineRange.startFrame
            }
            return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case clips
        case volume
        case pan
        case isMuted
        case isSoloed
        case isLocked
        case colorToken
        case metadata
        case collisionPolicy
        case channelLayout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        clips = Self.sorted(try container.decodeIfPresent([TimelineClip].self, forKey: .clips) ?? [])
        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        pan = min(max(try container.decodeIfPresent(Float.self, forKey: .pan) ?? 0, -1), 1)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSoloed = try container.decodeIfPresent(Bool.self, forKey: .isSoloed) ?? false
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        colorToken = try container.decodeIfPresent(String.self, forKey: .colorToken)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        collisionPolicy = try container.decodeIfPresent(
            TimelineClipCollisionPolicy.self,
            forKey: .collisionPolicy
        ) ?? .rejectOverlaps
        channelLayout = try container.decodeIfPresent(
            TrackChannelLayout.self,
            forKey: .channelLayout
        ) ?? .stereo
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(clips, forKey: .clips)
        try container.encode(volume, forKey: .volume)
        try container.encode(pan, forKey: .pan)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(isSoloed, forKey: .isSoloed)
        try container.encode(isLocked, forKey: .isLocked)
        try container.encodeIfPresent(colorToken, forKey: .colorToken)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(collisionPolicy, forKey: .collisionPolicy)
        try container.encode(channelLayout, forKey: .channelLayout)
    }
}

public struct TimelineClipGraph: Equatable, Codable, Sendable {
    public private(set) var sources: [TimelineMediaSourceID: TimelineMediaSource]
    public private(set) var tracks: [TimelineTrack]
    public private(set) var revision: UInt64
    public var timelineSampleRate: Double
    public var explicitEndFrame: Int?

    public init(
        sources: [TimelineMediaSource] = [],
        tracks: [TimelineTrack] = [],
        revision: UInt64 = 1,
        timelineSampleRate: Double,
        explicitEndFrame: Int? = nil
    ) throws {
        var sourceCatalog: [TimelineMediaSourceID: TimelineMediaSource] = [:]
        for source in sources {
            guard sourceCatalog.updateValue(source, forKey: source.id) == nil else {
                throw TimelineClipGraphError.duplicateSource(source.id)
            }
        }
        var seenTrackIDs = Set<UUID>()
        for track in tracks {
            guard seenTrackIDs.insert(track.id).inserted else {
                throw TimelineClipGraphError.duplicateTrack(track.id)
            }
        }

        self.sources = sourceCatalog
        self.tracks = tracks
        self.revision = max(revision, 1)
        self.timelineSampleRate = timelineSampleRate
        self.explicitEndFrame = explicitEndFrame
        try validate()
    }

    public var endFrame: Int {
        max(
            explicitEndFrame ?? 0,
            tracks.reduce(into: 0) { maximum, track in
                maximum = max(maximum, track.endFrame)
            }
        )
    }

    public func track(id: UUID) -> TimelineTrack? {
        tracks.first { $0.id == id }
    }

    public func source(id: TimelineMediaSourceID) -> TimelineMediaSource? {
        sources[id]
    }

    public func location(of clipID: AudioTimelineClipID) -> (trackIndex: Int, clipIndex: Int)? {
        for (trackIndex, track) in tracks.enumerated() {
            if let clipIndex = track.clipIndex(id: clipID) {
                return (trackIndex, clipIndex)
            }
        }
        return nil
    }

    public mutating func upsertSource(_ source: TimelineMediaSource) {
        sources[source.id] = source
    }

    public mutating func replaceTrack(_ track: TimelineTrack) throws {
        try track.validate(sources: sources)
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[index] = track
        } else {
            tracks.append(track)
        }
        revision &+= 1
    }

    public mutating func replaceTracks(_ replacements: [TimelineTrack], revision: UInt64) throws {
        var replacementByID = Dictionary(uniqueKeysWithValues: replacements.map { ($0.id, $0) })
        tracks = tracks.compactMap { track in
            replacementByID.removeValue(forKey: track.id) ?? track
        }
        tracks.append(contentsOf: replacementByID.values.sorted { $0.id.uuidString < $1.id.uuidString })
        self.revision = max(revision, 1)
        try validate()
    }

    public mutating func replaceAffectedTracks(
        ids: Set<UUID>,
        with replacements: [TimelineTrack],
        revision: UInt64
    ) throws {
        let replacementByID = Dictionary(uniqueKeysWithValues: replacements.map { ($0.id, $0) })
        tracks = tracks.compactMap { track in
            guard ids.contains(track.id) else { return track }
            return replacementByID[track.id]
        }
        let existingIDs = Set(tracks.map(\.id))
        tracks.append(contentsOf: replacements.filter { !existingIDs.contains($0.id) })
        self.revision = max(revision, 1)
        try validate()
    }

    public mutating func setRevision(_ revision: UInt64) {
        self.revision = max(revision, 1)
    }

    public func replacingAllTracks(_ tracks: [TimelineTrack]) throws -> TimelineClipGraph {
        try TimelineClipGraph(
            sources: Array(sources.values),
            tracks: tracks,
            revision: revision &+ 1,
            timelineSampleRate: timelineSampleRate,
            explicitEndFrame: explicitEndFrame
        )
    }

    /// Returns a graph whose source catalog contains exactly the media still
    /// referenced by live clips. Undo history retains removed source records
    /// separately, so live graph publication never accumulates dead media.
    public func pruningUnreferencedSources() throws -> TimelineClipGraph {
        let referencedSourceIDs = Set(tracks.flatMap(\.clips).map(\.sourceID))
        return try TimelineClipGraph(
            sources: sources.values.filter { referencedSourceIDs.contains($0.id) },
            tracks: tracks,
            revision: revision,
            timelineSampleRate: timelineSampleRate,
            explicitEndFrame: explicitEndFrame
        )
    }

    public func validate() throws {
        guard timelineSampleRate.isFinite, timelineSampleRate > 0 else {
            throw TimelineClipGraphError.invalidTimelineSampleRate
        }
        for source in sources.values {
            try source.validate()
        }
        var seenTrackIDs = Set<UUID>()
        var seenClipIDs = Set<AudioTimelineClipID>()
        for track in tracks {
            guard seenTrackIDs.insert(track.id).inserted else {
                throw TimelineClipGraphError.duplicateTrack(track.id)
            }
            try track.validate(sources: sources)
            for clip in track.clips {
                guard seenClipIDs.insert(clip.id).inserted else {
                    throw TimelineClipGraphError.duplicateClip(clip.id)
                }
            }
        }
    }
}
