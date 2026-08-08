import Foundation

public struct TimelineClipGraphDocument: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var graph: TimelineClipGraph

    public init(graph: TimelineClipGraph, schemaVersion: Int = currentSchemaVersion) throws {
        try graph.validate()
        self.schemaVersion = schemaVersion
        self.graph = graph
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported clip graph schema \(schemaVersion)."
            )
        }
        graph = try container.decode(TimelineClipGraph.self, forKey: .graph)
        try graph.validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case graph
    }
}

public struct LegacyTimelineClipGraphProject: Decodable, Sendable {
    public struct Source: Decodable, Sendable {
        public let id: String
        public let path: String
        public let frameCount: Int
        public let sampleRate: Double
        public let channelCount: Int
    }

    public struct Segment: Decodable, Sendable {
        public let sourceStartFrame: Int
        public let frameCount: Int
        public let sourceFrameScale: Double
        public let gainStart: Float
        public let gainEnd: Float
        public let startsNewClip: Bool
        public let clipID: UUID

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sourceStartFrame = try container.decode(Int.self, forKey: .sourceStartFrame)
            frameCount = try container.decode(Int.self, forKey: .frameCount)
            sourceFrameScale = try container.decodeIfPresent(Double.self, forKey: .sourceFrameScale) ?? 1
            gainStart = try container.decode(Float.self, forKey: .gainStart)
            gainEnd = try container.decode(Float.self, forKey: .gainEnd)
            startsNewClip = try container.decode(Bool.self, forKey: .startsNewClip)
            clipID = try container.decode(UUID.self, forKey: .clipID)
        }

        private enum CodingKeys: String, CodingKey {
            case sourceStartFrame
            case frameCount
            case sourceFrameScale
            case gainStart
            case gainEnd
            case startsNewClip
            case clipID
        }
    }

    public struct Track: Decodable, Sendable {
        public let id: UUID
        public let name: String
        public let source: Source
        public let clipNames: [UUID: String]
        public let segments: [Segment]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            source = try container.decode(Source.self, forKey: .source)
            segments = try container.decode([Segment].self, forKey: .segments)
            let namesByString = try container.decode([String: String].self, forKey: .clipNames)
            clipNames = Dictionary(uniqueKeysWithValues: namesByString.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case source
            case clipNames
            case segments
        }
    }

    public let fixtureVersion: Int
    public let name: String
    public let timelineSampleRate: Double
    public let tracks: [Track]
}

public enum TimelineClipGraphLegacyMigrator {
    public static func migrate(_ legacy: LegacyTimelineClipGraphProject) throws -> TimelineClipGraphDocument {
        let sources = Array(Dictionary(
            legacy.tracks.map { track in
                let source = TimelineMediaSource(
                id: TimelineMediaSourceID(rawValue: track.source.id),
                relativePath: track.source.path,
                frameCount: track.source.frameCount,
                sampleRate: track.source.sampleRate,
                channelCount: track.source.channelCount
                )
                return (source.id, source)
            },
            uniquingKeysWith: { existing, _ in existing }
        ).values)

        let tracks = legacy.tracks.map { legacyTrack in
            let sourceID = TimelineMediaSourceID(rawValue: legacyTrack.source.id)
            var outputFrame = 0
            var usedIDs = Set<AudioTimelineClipID>()
            var occurrenceByLegacyID: [UUID: Int] = [:]
            var clips: [TimelineClip] = []

            for segment in legacyTrack.segments {
                defer { outputFrame += max(segment.frameCount, 0) }
                guard segment.frameCount > 0 else {
                    continue
                }

                // Old preserve-position edits inserted a separate all-zero clip.
                // Its duration remains as an implicit gap in the new graph.
                if segment.gainStart == 0, segment.gainEnd == 0 {
                    continue
                }

                let occurrence = occurrenceByLegacyID[segment.clipID, default: 0]
                occurrenceByLegacyID[segment.clipID] = occurrence + 1
                let originalID = AudioTimelineClipID(rawValue: segment.clipID)
                let clipID = occurrence == 0 && !usedIDs.contains(originalID)
                    ? originalID
                    : derivedID(from: originalID, component: occurrence)
                usedIDs.insert(clipID)

                let baseName = legacyTrack.clipNames[segment.clipID] ?? legacyTrack.name
                let name = occurrence == 0
                    ? baseName
                    : "\(baseName) \(occurrence + 1)"
                let sourceFrameCount = max(
                    Int((Double(segment.frameCount) * segment.sourceFrameScale).rounded()),
                    1
                )
                clips.append(TimelineClip(
                    id: clipID,
                    sourceID: sourceID,
                    timelineRange: TimelineFrameRange(
                        startFrame: outputFrame,
                        frameCount: segment.frameCount
                    ),
                    sourceRange: TimelineFrameRange(
                        startFrame: segment.sourceStartFrame,
                        frameCount: sourceFrameCount
                    ),
                    name: name,
                    gain: 1,
                    gainEnvelope: TimelineClipGainEnvelope(
                        startMultiplier: segment.gainStart,
                        endMultiplier: segment.gainEnd
                    ),
                    metadata: [
                        "legacyClipID": segment.clipID.uuidString.lowercased(),
                        "legacyStartsNewClip": segment.startsNewClip ? "true" : "false",
                    ]
                ))
            }

            return TimelineTrack(id: legacyTrack.id, name: legacyTrack.name, clips: clips)
        }

        let graph = try TimelineClipGraph(
            sources: sources,
            tracks: tracks,
            timelineSampleRate: legacy.timelineSampleRate
        )
        return try TimelineClipGraphDocument(graph: graph)
    }

    public static func derivedID(
        from baseID: AudioTimelineClipID,
        component: Int
    ) -> AudioTimelineClipID {
        let input = "\(baseID.rawValue.uuidString.lowercased())|\(component)"
        var first: UInt64 = 14_695_981_039_346_656_037
        var second: UInt64 = 10_995_116_282_11
        for byte in input.utf8 {
            first = (first ^ UInt64(byte)) &* 1_099_511_628_211
            second = (second &* 1_099_511_628_211) ^ UInt64(byte)
        }
        let bytes = withUnsafeBytes(of: (first.bigEndian, second.bigEndian)) { Array($0) }
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return AudioTimelineClipID(rawValue: uuid)
    }
}
