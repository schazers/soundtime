import Foundation

public struct TimelinePreparedStem: Equatable, Sendable {
    public let trackID: UUID
    public let source: TimelineMediaSource
    public let partName: String

    public init(
        trackID: UUID = UUID(),
        source: TimelineMediaSource,
        partName: String
    ) {
        self.trackID = trackID
        self.source = source
        self.partName = partName
    }
}

public struct TimelineStemAcceptanceResult: Equatable, Sendable {
    public let graph: TimelineClipGraph
    public let addedTrackIDs: [UUID]
    public let addedTrackNames: [String]

    public init(
        graph: TimelineClipGraph,
        addedTrackIDs: [UUID],
        addedTrackNames: [String]
    ) {
        self.graph = graph
        self.addedTrackIDs = addedTrackIDs
        self.addedTrackNames = addedTrackNames
    }
}

public enum TimelineStemAcceptanceService {
    public static func accept(
        _ stems: [TimelinePreparedStem],
        sourceTrackID: UUID,
        timelineStartFrame: Int,
        into graph: TimelineClipGraph
    ) throws -> TimelineStemAcceptanceResult {
        guard let sourceTrackIndex = graph.tracks.firstIndex(where: { $0.id == sourceTrackID }) else {
            throw TimelineClipGraphError.missingTrack(sourceTrackID)
        }
        guard !stems.isEmpty else {
            return TimelineStemAcceptanceResult(
                graph: graph,
                addedTrackIDs: [],
                addedTrackNames: []
            )
        }

        let sourceTrack = graph.tracks[sourceTrackIndex]
        var mutedSourceTrack = sourceTrack
        mutedSourceTrack.isMuted = true
        mutedSourceTrack.isSoloed = false

        var sources = graph.sources
        var stemTracks: [TimelineTrack] = []
        stemTracks.reserveCapacity(stems.count)
        for stem in stems {
            if let existing = sources[stem.source.id], existing != stem.source {
                throw TimelineClipGraphError.sourceIdentityConflict(stem.source.id)
            }
            sources[stem.source.id] = stem.source

            let trackName = stemTrackName(
                sourceTrackName: sourceTrack.name,
                partName: stem.partName
            )
            let timelineFrameCount = max(
                Int((stem.source.duration * graph.timelineSampleRate).rounded()),
                1
            )
            stemTracks.append(TimelineTrack(
                id: stem.trackID,
                name: trackName,
                clips: [TimelineClip(
                    sourceID: stem.source.id,
                    timelineRange: TimelineFrameRange(
                        startFrame: max(timelineStartFrame, 0),
                        frameCount: timelineFrameCount
                    ),
                    sourceRange: TimelineFrameRange(
                        startFrame: 0,
                        frameCount: stem.source.frameCount
                    ),
                    name: trackName,
                    metadata: ["kind": "separatedStem"]
                )],
                volume: sourceTrack.volume,
                isMuted: false,
                isSoloed: false,
                metadata: [
                    "kind": "separatedStem",
                    "sourceTrackID": sourceTrackID.uuidString,
                ]
            ))
        }

        var tracks = graph.tracks
        tracks[sourceTrackIndex] = mutedSourceTrack
        tracks.insert(contentsOf: stemTracks, at: sourceTrackIndex + 1)
        let resultGraph = try TimelineClipGraph(
            sources: Array(sources.values),
            tracks: tracks,
            revision: graph.revision &+ 1,
            timelineSampleRate: graph.timelineSampleRate,
            explicitEndFrame: graph.explicitEndFrame
        )
        return TimelineStemAcceptanceResult(
            graph: resultGraph,
            addedTrackIDs: stemTracks.map(\.id),
            addedTrackNames: stemTracks.map(\.name)
        )
    }

    public static func stemTrackName(sourceTrackName: String, partName: String) -> String {
        "\(sourceTrackName) (\(normalizedPartName(partName)))"
    }

    public static func normalizedPartName(_ rawName: String) -> String {
        let cleaned = rawName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercase = cleaned.lowercased()
        if lowercase.contains("bass") { return "Bass" }
        if lowercase.contains("drum") { return "Drums" }
        if lowercase.contains("vocal") || lowercase.contains("voice") { return "Vocals" }
        if lowercase.contains("other") { return "Other" }
        if lowercase.contains("instrument") { return "Instrumental" }
        if lowercase.contains("music") { return "Music" }
        return cleaned.isEmpty ? "Stem" : cleaned.capitalized
    }
}

private extension TimelineMediaSource {
    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(frameCount) / sampleRate
    }
}
