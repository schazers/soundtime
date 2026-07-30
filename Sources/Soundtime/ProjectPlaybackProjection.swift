import Foundation

enum ProjectPlaybackProjection {
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
            source: source,
            sourceRevision: track.editRevision,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed
        )
    }

    static func mixes(from projectTracks: [ProjectTrack]) -> [ProjectPlaybackTrackMix] {
        projectTracks.map { track in
            ProjectPlaybackTrackMix(
                id: track.id,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed
            )
        }
    }

    static func applyingMixes(
        _ mixes: [ProjectPlaybackTrackMix],
        to tracks: [ProjectPlaybackTrack]
    ) -> [ProjectPlaybackTrack] {
        let mixesByID = Dictionary(uniqueKeysWithValues: mixes.map { ($0.id, $0) })
        return tracks.map { track in
            guard let mix = mixesByID[track.id] else {
                return track
            }
            return track.applying(mix)
        }
    }

}

extension ProjectPlaybackTrack {
    func applying(_ mix: ProjectPlaybackTrackMix) -> ProjectPlaybackTrack {
        guard id == mix.id else {
            return self
        }
        return ProjectPlaybackTrack(
            id: id,
            source: source,
            sourceRevision: sourceRevision,
            volume: mix.volume,
            isMuted: mix.isMuted,
            isSoloed: mix.isSoloed
        )
    }
}
