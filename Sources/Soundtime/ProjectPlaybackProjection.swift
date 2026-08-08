import Foundation
import SoundtimeEditing

enum ProjectClipGraphProjectionError: LocalizedError, Equatable {
    case missingMediaPath(TimelineMediaSourceID)
    case unreadableMedia(TimelineMediaSourceID, String)

    var errorDescription: String? {
        switch self {
        case let .missingMediaPath(sourceID):
            return "Clip media \(sourceID.rawValue) has no resolvable file path."
        case let .unreadableMedia(sourceID, path):
            return "Clip media \(sourceID.rawValue) could not be read at \(path)."
        }
    }
}

enum ProjectPlaybackProjection {
    static func tracks(
        from graph: TimelineClipGraph,
        fileInfo: (URL) -> WAVFileInfo?,
        zeroCrossingProbe: (TimelineMediaSource, URL) -> WAVZeroCrossingProbe?
    ) throws -> [ProjectPlaybackTrack] {
        try tracks(
            from: TimelineClipPlaybackProjection.snapshot(from: graph),
            fileInfo: fileInfo,
            zeroCrossingProbe: zeroCrossingProbe
        )
    }

    static func tracks(
        from snapshot: TimelinePlaybackSnapshot,
        fileInfo: (URL) -> WAVFileInfo?,
        zeroCrossingProbe: (TimelineMediaSource, URL) -> WAVZeroCrossingProbe?
    ) throws -> [ProjectPlaybackTrack] {
        let timelineDuration = TimeInterval(snapshot.endFrame) / snapshot.timelineSampleRate
        return try snapshot.lanes.map { lane in
            guard let path = lane.source.absolutePath ?? lane.source.relativePath, !path.isEmpty else {
                throw ProjectClipGraphProjectionError.missingMediaPath(lane.source.id)
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard fileInfo(url) != nil else {
                throw ProjectClipGraphProjectionError.unreadableMedia(lane.source.id, url.path)
            }
            return ProjectPlaybackTrack(
                id: TimelineLaneIdentity.uuid(for: lane.id),
                logicalTrackID: lane.id.trackID,
                logicalChannelCount: lane.logicalChannelCount,
                source: .fileSegments(
                    url: url,
                    sourceFrameCount: lane.source.frameCount,
                    sourceSampleRate: lane.source.sampleRate,
                    timelineSampleRate: snapshot.timelineSampleRate,
                    segments: lane.segments,
                    zeroCrossingProbe: zeroCrossingProbe(lane.source, url)
                ),
                sourceRevision: Int(clamping: snapshot.graphRevision),
                timelineDurationHint: timelineDuration,
                volume: lane.volume,
                pan: lane.pan,
                isMuted: lane.isMuted,
                isSoloed: lane.isSoloed,
                volumeAutomation: lane.volumeAutomation,
                panAutomation: lane.panAutomation,
                muteAutomation: lane.muteAutomation
            )
        }
    }

    static func tracks(
        from projectTracks: [ProjectTrack],
        isDirectFilePlayable: (URL) -> Bool
    ) -> [ProjectPlaybackTrack] {
        projectTracks.compactMap {
            track(from: $0, isDirectFilePlayable: isDirectFilePlayable)
        }
    }

    static func track(
        from track: ProjectTrack,
        isDirectFilePlayable: (URL) -> Bool
    ) -> ProjectPlaybackTrack? {
        let source: ProjectPlaybackTrack.Source
        if
            let fileTimeline = track.fileTimeline,
            let editableSource = track.editableSource,
            editableSource.editableURL == track.sourceURL.standardizedFileURL,
            editableSource.isCompatible(with: fileTimeline)
        {
            source = .fileTimeline(
                url: track.sourceURL,
                timeline: fileTimeline,
                zeroCrossingProbe: track.zeroCrossingProbe
            )
        } else if track.editRevision == 0, isDirectFilePlayable(track.sourceURL) {
            source = .file(
                url: track.sourceURL,
                zeroCrossingProbe: track.zeroCrossingProbe
            )
        } else if track.editRevision == 0, AudioAssetImporter.canImport(track.sourceURL) {
            source = .file(
                url: track.sourceURL,
                zeroCrossingProbe: nil
            )
        } else if let audioTimeline = track.audioTimeline {
            source = .timeline(
                audioTimeline: audioTimeline,
                zeroCrossingIndex: track.zeroCrossingIndex
            )
        } else if let decodedAudioBuffer = track.decodedAudioBuffer {
            source = .decoded(
                decodedAudioBuffer: decodedAudioBuffer,
                zeroCrossingIndex: track.zeroCrossingIndex
            )
        } else {
            return nil
        }

        return ProjectPlaybackTrack(
            id: track.id,
            logicalChannelCount: track.channelLayout.channelCount,
            source: source,
            sourceRevision: track.editRevision,
            timelineDurationHint: nil,
            volume: track.volume,
            pan: track.pan,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed
        )
    }

    static func mixes(from projectTracks: [ProjectTrack]) -> [ProjectPlaybackTrackMix] {
        projectTracks.map { track in
            ProjectPlaybackTrackMix(
                id: track.id,
                volume: track.volume,
                pan: track.pan,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed
            )
        }
    }

    static func mixes(from graph: TimelineClipGraph) -> [ProjectPlaybackTrackMix] {
        graph.tracks.map {
            ProjectPlaybackTrackMix(
                id: $0.id,
                volume: $0.volume,
                pan: $0.pan,
                isMuted: $0.isMuted,
                isSoloed: $0.isSoloed
            )
        }
    }

    static func applyingMixes(
        _ mixes: [ProjectPlaybackTrackMix],
        to tracks: [ProjectPlaybackTrack]
    ) -> [ProjectPlaybackTrack] {
        let mixesByID = Dictionary(uniqueKeysWithValues: mixes.map { ($0.id, $0) })
        return tracks.map { track in
            guard let mix = mixesByID[track.logicalTrackID] else {
                return track
            }
            return track.applying(mix)
        }
    }

}

extension ProjectPlaybackTrack {
    func applying(_ mix: ProjectPlaybackTrackMix) -> ProjectPlaybackTrack {
        guard logicalTrackID == mix.id else {
            return self
        }
        return ProjectPlaybackTrack(
            id: id,
            logicalTrackID: logicalTrackID,
            logicalChannelCount: logicalChannelCount,
            source: source,
            sourceRevision: sourceRevision,
            timelineDurationHint: timelineDurationHint,
            volume: mix.volume,
            pan: mix.pan,
            isMuted: mix.isMuted,
            isSoloed: mix.isSoloed,
            volumeAutomation: volumeAutomation,
            panAutomation: panAutomation
        )
    }
}
