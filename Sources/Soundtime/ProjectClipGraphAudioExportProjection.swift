import Foundation
import SoundtimeEditing

enum ProjectClipGraphAudioExportProjection {
    static func isolatingClip(
        _ clipID: AudioTimelineClipID,
        on trackID: UUID,
        from graph: TimelineClipGraph
    ) throws -> TimelineClipGraph? {
        guard
            var track = graph.track(id: trackID),
            let clip = track.clip(id: clipID),
            let source = graph.source(id: clip.sourceID)
        else {
            return nil
        }

        track.replaceClips([clip])
        return try TimelineClipGraph(
            sources: [source],
            tracks: [track],
            revision: graph.revision,
            timelineSampleRate: graph.timelineSampleRate,
            explicitEndFrame: graph.explicitEndFrame
        )
    }

    static func tracks(
        from graph: TimelineClipGraph,
        includedTrackIDs: Set<UUID>?,
        fileInfo: (URL) -> WAVFileInfo?
    ) throws -> [AudioExportTrackSnapshot] {
        try tracks(
            from: TimelineClipPlaybackProjection.snapshot(from: graph),
            includedTrackIDs: includedTrackIDs,
            fileInfo: fileInfo
        )
    }

    static func tracks(
        from snapshot: TimelinePlaybackSnapshot,
        includedTrackIDs: Set<UUID>?,
        fileInfo: (URL) -> WAVFileInfo?
    ) throws -> [AudioExportTrackSnapshot] {
        try snapshot.lanes.compactMap { lane in
            guard includedTrackIDs?.contains(lane.id.trackID) ?? true else {
                return nil
            }
            guard let path = lane.source.absolutePath ?? lane.source.relativePath, !path.isEmpty else {
                throw ProjectClipGraphProjectionError.missingMediaPath(lane.source.id)
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard let info = fileInfo(url) else {
                throw ProjectClipGraphProjectionError.unreadableMedia(lane.source.id, url.path)
            }
            return AudioExportTrackSnapshot(
                id: TimelineLaneIdentity.uuid(for: lane.id),
                logicalTrackID: lane.id.trackID,
                name: lane.trackName,
                volume: lane.volume,
                pan: lane.pan,
                isMuted: lane.isMuted,
                isSoloed: lane.isSoloed,
                volumeAutomation: lane.volumeAutomation,
                panAutomation: lane.panAutomation,
                muteAutomation: lane.muteAutomation,
                source: .fileSegments(url, info, lane.segments)
            )
        }
    }
}
