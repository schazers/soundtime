import Foundation

public struct TimelineClipObjectClipboardItem: Equatable, Codable, Sendable {
    public let relativeTrackIndex: Int
    public let relativeStartFrame: Int
    public let clip: TimelineClip
    public let source: TimelineMediaSource

    public init(
        relativeTrackIndex: Int,
        relativeStartFrame: Int,
        clip: TimelineClip,
        source: TimelineMediaSource
    ) {
        self.relativeTrackIndex = relativeTrackIndex
        self.relativeStartFrame = relativeStartFrame
        self.clip = clip
        self.source = source
    }
}

public struct TimelineClipObjectClipboardDocument: Equatable, Codable, Sendable {
    public let timelineSampleRate: Double
    public let frameCount: Int
    public let trackSpan: Int
    public let items: [TimelineClipObjectClipboardItem]

    public init(
        timelineSampleRate: Double,
        frameCount: Int,
        trackSpan: Int,
        items: [TimelineClipObjectClipboardItem]
    ) {
        self.timelineSampleRate = timelineSampleRate
        self.frameCount = frameCount
        self.trackSpan = trackSpan
        self.items = items
    }
}

public enum TimelineClipObjectClipboardError: Error, Equatable, Sendable {
    case emptySelection
    case missingClip(AudioTimelineClipID)
    case missingSource(TimelineMediaSourceID)
    case missingAnchorTrack(UUID)
    case insufficientDestinationTracks(required: Int, available: Int)
}

public enum TimelineClipObjectClipboardService {
    public static func capture(
        _ references: Set<TimelineClipReference>,
        in graph: TimelineClipGraph
    ) throws -> TimelineClipObjectClipboardDocument {
        guard !references.isEmpty else {
            throw TimelineClipObjectClipboardError.emptySelection
        }
        let trackIndices = Dictionary(uniqueKeysWithValues: graph.tracks.enumerated().map { ($1.id, $0) })
        let resolved = try references.map { reference -> (Int, TimelineClip, TimelineMediaSource) in
            guard
                let trackIndex = trackIndices[reference.trackID],
                let clip = graph.track(id: reference.trackID)?.clip(id: reference.clipID)
            else {
                throw TimelineClipObjectClipboardError.missingClip(reference.clipID)
            }
            guard let source = graph.source(id: clip.sourceID) else {
                throw TimelineClipObjectClipboardError.missingSource(clip.sourceID)
            }
            return (trackIndex, clip, source)
        }
        let minimumTrackIndex = resolved.map(\.0).min() ?? 0
        let maximumTrackIndex = resolved.map(\.0).max() ?? minimumTrackIndex
        let minimumStartFrame = resolved.map { $0.1.timelineRange.startFrame }.min() ?? 0
        let maximumEndFrame = resolved.map { $0.1.timelineRange.endFrame }.max() ?? minimumStartFrame
        let items = resolved.map { trackIndex, clip, source in
            TimelineClipObjectClipboardItem(
                relativeTrackIndex: trackIndex - minimumTrackIndex,
                relativeStartFrame: clip.timelineRange.startFrame - minimumStartFrame,
                clip: clip,
                source: source
            )
        }.sorted {
            if $0.relativeTrackIndex != $1.relativeTrackIndex {
                return $0.relativeTrackIndex < $1.relativeTrackIndex
            }
            return $0.relativeStartFrame < $1.relativeStartFrame
        }
        return TimelineClipObjectClipboardDocument(
            timelineSampleRate: graph.timelineSampleRate,
            frameCount: max(maximumEndFrame - minimumStartFrame, 1),
            trackSpan: maximumTrackIndex - minimumTrackIndex + 1,
            items: items
        )
    }

    public static func insertionRequests(
        for document: TimelineClipObjectClipboardDocument,
        anchorTrackID: UUID,
        timelineStartFrame: Int,
        in graph: TimelineClipGraph
    ) throws -> [TimelineMediaInsertionRequest] {
        guard !document.items.isEmpty else {
            throw TimelineClipObjectClipboardError.emptySelection
        }
        guard let anchorIndex = graph.tracks.firstIndex(where: { $0.id == anchorTrackID }) else {
            throw TimelineClipObjectClipboardError.missingAnchorTrack(anchorTrackID)
        }
        let requiredEndIndex = anchorIndex + max(document.trackSpan, 1)
        guard requiredEndIndex <= graph.tracks.count else {
            throw TimelineClipObjectClipboardError.insufficientDestinationTracks(
                required: document.trackSpan,
                available: max(graph.tracks.count - anchorIndex, 0)
            )
        }
        let rateScale = graph.timelineSampleRate / max(document.timelineSampleRate, 1)
        return document.items.map { item in
            let destinationTrack = graph.tracks[anchorIndex + item.relativeTrackIndex]
            return TimelineMediaInsertionRequest(
                trackID: destinationTrack.id,
                source: item.source,
                sourceRange: item.clip.sourceRange,
                timelineStartFrame: timelineStartFrame + Int((Double(item.relativeStartFrame) * rateScale).rounded()),
                timelineFrameCount: max(Int((Double(item.clip.timelineRange.frameCount) * rateScale).rounded()), 1),
                clipID: AudioTimelineClipID(),
                clipName: item.clip.name,
                gain: item.clip.gain,
                gainEnvelope: item.clip.gainEnvelope,
                fades: item.clip.fades,
                isMuted: item.clip.isMuted,
                isLocked: item.clip.isLocked,
                colorToken: item.clip.colorToken,
                clipMetadata: item.clip.metadata
            )
        }
    }
}
