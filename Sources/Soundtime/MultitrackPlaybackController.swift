import Foundation
import QuartzCore

@MainActor
final class MultitrackPlaybackController: PlaybackEngine {
    private struct TrackPlayer {
        var track: ProjectPlaybackTrack
        let controller: AudioPlaybackController
        let frameCount: Int
    }

    private var trackPlayers: [UUID: TrackPlayer] = [:]
    private var trackOrder: [UUID] = []
    private var masterPerceptualVolume: Float = 1

    var isPlaying: Bool {
        trackPlayers.values.contains { $0.controller.isPlaying }
    }

    var hasSource: Bool {
        !trackPlayers.isEmpty
    }

    func setPerceptualVolume(_ volume: Float) {
        masterPerceptualVolume = min(max(volume, 0), 1)
        applyTrackVolumes()
    }

    func load(
        _ decodedAudioBuffer: DecodedAudioBuffer,
        zeroCrossingIndex: AudioZeroCrossingIndex? = nil
    ) throws {
        try loadProjectTracks([
            ProjectPlaybackTrack(
                id: UUID(),
                source: .decoded(
                    decodedAudioBuffer: decodedAudioBuffer,
                    zeroCrossingIndex: zeroCrossingIndex
                ),
                volume: 1,
                isMuted: false,
                isSoloed: false
            ),
        ])
    }

    func loadFile(at url: URL, zeroCrossingProbe: WAVZeroCrossingProbe? = nil) throws {
        try loadProjectTracks([
            ProjectPlaybackTrack(
                id: UUID(),
                source: .file(url: url, zeroCrossingProbe: zeroCrossingProbe),
                volume: 1,
                isMuted: false,
                isSoloed: false
            ),
        ])
    }

    func replaceWithDecodedSource(
        _ decodedAudioBuffer: DecodedAudioBuffer,
        zeroCrossingIndex: AudioZeroCrossingIndex? = nil
    ) throws {
        let previousSnapshot = snapshot()
        let shouldResume = previousSnapshot.isPlaying

        try load(decodedAudioBuffer, zeroCrossingIndex: zeroCrossingIndex)
        try seek(toProgress: previousSnapshot.progress)

        if shouldResume {
            try play()
        }
    }

    func clear() {
        for player in trackPlayers.values {
            player.controller.clear()
        }

        trackPlayers.removeAll()
        trackOrder.removeAll()
    }

    func updateZeroCrossingIndex(_ zeroCrossingIndex: AudioZeroCrossingIndex?) {
        guard trackOrder.count == 1, let trackID = trackOrder.first else {
            return
        }

        trackPlayers[trackID]?.controller.updateZeroCrossingIndex(zeroCrossingIndex)
    }

    func loadProjectTracks(_ tracks: [ProjectPlaybackTrack]) throws {
        clear()

        for track in tracks {
            let controller = AudioPlaybackController()
            switch track.source {
            case let .decoded(decodedAudioBuffer, zeroCrossingIndex):
                try controller.load(
                    decodedAudioBuffer,
                    zeroCrossingIndex: zeroCrossingIndex
                )
            case let .file(url, zeroCrossingProbe):
                try controller.loadFile(at: url, zeroCrossingProbe: zeroCrossingProbe)
            }

            trackPlayers[track.id] = TrackPlayer(
                track: track,
                controller: controller,
                frameCount: controller.snapshot().frameCount
            )
            trackOrder.append(track.id)
        }

        applyTrackVolumes()
    }

    func updateProjectTrackMix(_ tracks: [ProjectPlaybackTrack]) {
        for track in tracks {
            guard var player = trackPlayers[track.id] else {
                continue
            }

            player.track = track
            trackPlayers[track.id] = player
        }

        applyTrackVolumes()
    }

    @discardableResult
    func togglePlayback() throws -> Bool {
        if isPlaying {
            pause()
            return false
        }

        try play()
        return true
    }

    func play() throws {
        guard hasSource else {
            throw PlaybackError.noAudioLoaded
        }

        let projectFrameCount = maxProjectFrameCount()
        guard projectFrameCount > 0 else {
            return
        }

        var projectFrame = snapshot().frameIndex
        if projectFrame >= projectFrameCount {
            projectFrame = 0
            try seek(toProgress: 0)
        }

        for trackID in trackOrder {
            guard let player = trackPlayers[trackID] else {
                continue
            }

            guard projectFrame < player.frameCount else {
                try player.controller.seek(toProgress: 1)
                continue
            }

            let trackProgress = min(max(Float(projectFrame) / Float(max(player.frameCount, 1)), 0), 1)
            try player.controller.seek(toProgress: trackProgress)
            try player.controller.play()
        }
    }

    func pause() {
        for player in trackPlayers.values {
            player.controller.pause()
        }
    }

    func seek(toProgress progress: Float) throws {
        guard hasSource else {
            throw PlaybackError.noAudioLoaded
        }

        let projectFrameCount = maxProjectFrameCount()
        guard projectFrameCount > 0 else {
            return
        }

        let clampedProgress = min(max(progress, 0), 1)
        let projectFrame = Int((clampedProgress * Float(projectFrameCount)).rounded(.down))
        for trackID in trackOrder {
            guard let player = trackPlayers[trackID] else {
                continue
            }

            let trackFrameCount = max(player.frameCount, 1)
            let trackProgress = min(max(Float(projectFrame) / Float(trackFrameCount), 0), 1)
            try player.controller.seek(toProgress: trackProgress)
        }
    }

    func snapshot() -> PlaybackSnapshot {
        guard hasSource else {
            return PlaybackSnapshot(
                frameIndex: 0,
                frameCount: 0,
                isPlaying: false,
                hostTimestamp: CACurrentMediaTime()
            )
        }

        let projectFrameCount = maxProjectFrameCount()
        guard projectFrameCount > 0 else {
            return PlaybackSnapshot(
                frameIndex: 0,
                frameCount: 0,
                isPlaying: isPlaying,
                hostTimestamp: CACurrentMediaTime()
            )
        }

        let longestPlayer = trackPlayers.values.max { lhs, rhs in
            lhs.frameCount < rhs.frameCount
        }
        let sourceSnapshot = longestPlayer?.controller.snapshot()
        let sourceProgress = sourceSnapshot?.progress ?? 0
        let frameIndex = min(
            max(Int((sourceProgress * Float(projectFrameCount)).rounded(.down)), 0),
            projectFrameCount
        )

        return PlaybackSnapshot(
            frameIndex: frameIndex,
            frameCount: projectFrameCount,
            isPlaying: isPlaying,
            hostTimestamp: sourceSnapshot?.hostTimestamp ?? CACurrentMediaTime()
        )
    }

    private func applyTrackVolumes() {
        let anySoloedTrack = trackPlayers.values.contains { $0.track.isSoloed }
        for player in trackPlayers.values {
            let shouldPlayTrack =
                !player.track.isMuted &&
                (!anySoloedTrack || player.track.isSoloed)
            let trackVolume = shouldPlayTrack ? player.track.volume : 0
            player.controller.setPerceptualVolume(masterPerceptualVolume * trackVolume)
        }
    }

    private func maxProjectFrameCount() -> Int {
        trackPlayers.values.reduce(0) { max($0, $1.frameCount) }
    }
}
