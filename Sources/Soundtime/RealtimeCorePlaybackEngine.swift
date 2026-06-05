import Foundation
import QuartzCore

@MainActor
final class RealtimeCorePlaybackEngine: PlaybackEngine {
    private struct PreparedProjectTrack {
        let id: UUID
        let sourceRevision: Int
        let source: PreparedRealtimeAudioSource
        let zeroCrossingIndex: AudioZeroCrossingIndex?
        let zeroCrossingProbe: WAVZeroCrossingProbe?
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool
    }

    private let core: RealtimeAudioCore
    private let outputDevice: RealtimeAudioOutputDevice
    private var frameCount = 0
    private var sampleRate: Double = 0
    private var zeroCrossingIndex: AudioZeroCrossingIndex?
    private var zeroCrossingProbe: WAVZeroCrossingProbe?
    private var preparedProjectTracks: [PreparedProjectTrack] = []
    private var sourceLoaded = false
    private var masterGain: Float = 1
    private var mirroredFrameIndex = 0
    private var mirroredFrameCount = 0
    private var mirroredIsPlaying = false
    private var mirroredHostTimestamp = CACurrentMediaTime()
    private var pendingCommandRenderedFrameCount: Int?

    var isPlaying: Bool {
        snapshot().isPlaying
    }

    var hasSource: Bool {
        frameCount > 0
    }

    init?(outputDevice: RealtimeAudioOutputDevice = AudioUnitOutputDevice()) {
        guard let core = RealtimeAudioCore() else {
            return nil
        }

        self.core = core
        self.outputDevice = outputDevice
        self.core.setTransportRampDuration(0.018)
    }

    func setPerceptualVolume(_ volume: Float) {
        let clampedVolume = min(max(volume, 0), 1)
        masterGain = clampedVolume * clampedVolume
        core.setGain(masterGain)
    }

    func load(
        _ decodedAudioBuffer: DecodedAudioBuffer,
        zeroCrossingIndex: AudioZeroCrossingIndex? = nil
    ) throws {
        guard let preparedSource = PreparedRealtimeAudioSource.make(from: decodedAudioBuffer) else {
            throw PlaybackError.invalidFormat
        }

        try loadPreparedSource(preparedSource, zeroCrossingIndex: zeroCrossingIndex)
    }

    func loadPreparedSource(
        _ preparedSource: PreparedRealtimeAudioSource,
        zeroCrossingIndex: AudioZeroCrossingIndex? = nil
    ) throws {
        let didLoad = core.setPreparedSource(preparedSource)
        guard didLoad else {
            throw PlaybackError.invalidFormat
        }

        frameCount = preparedSource.frameCount
        sampleRate = preparedSource.sampleRate
        mirroredFrameIndex = 0
        mirroredFrameCount = preparedSource.frameCount
        mirroredIsPlaying = false
        mirroredHostTimestamp = CACurrentMediaTime()
        pendingCommandRenderedFrameCount = nil
        self.zeroCrossingIndex = zeroCrossingIndex
        zeroCrossingProbe = nil
        sourceLoaded = true
        preparedProjectTracks.removeAll()
        core.setGain(masterGain)
        try configureOutputDevice(sampleRate: preparedSource.sampleRate)
    }

    func loadFile(at url: URL, zeroCrossingProbe: WAVZeroCrossingProbe? = nil) throws {
        let fileInfo = try WAVAudioDecoder.inspect(url: url)
        core.setSourceInfo(
            frameCount: fileInfo.frameCount,
            channelCount: fileInfo.channelCount,
            sampleRate: fileInfo.sampleRate
        )

        frameCount = fileInfo.frameCount
        sampleRate = fileInfo.sampleRate
        mirroredFrameIndex = 0
        mirroredFrameCount = fileInfo.frameCount
        mirroredIsPlaying = false
        mirroredHostTimestamp = CACurrentMediaTime()
        pendingCommandRenderedFrameCount = nil
        zeroCrossingIndex = nil
        self.zeroCrossingProbe = zeroCrossingProbe
        preparedProjectTracks.removeAll()
        sourceLoaded = false
        core.setGain(masterGain)
        try configureOutputDevice(sampleRate: fileInfo.sampleRate)
    }

    func loadProjectTracks(_ tracks: [ProjectPlaybackTrack]) throws {
        guard !tracks.isEmpty else {
            clear()
            return
        }

        let preparedTracks = try tracks.map { track in
            try preparedProjectTrack(from: track)
        }

        let sampleRate = preparedTracks[0].source.sampleRate
        guard
            sampleRate > 0,
            preparedTracks.allSatisfy({ $0.source.sampleRate == sampleRate })
        else {
            throw PlaybackError.invalidFormat
        }

        let didLoad = core.setPreparedTracks(
            preparedTracks.map { preparedTrack in
                PreparedRealtimeAudioTrack(
                    source: preparedTrack.source,
                    gain: effectiveTrackGain(preparedTrack, in: preparedTracks)
                )
            }
        )
        guard didLoad else {
            throw PlaybackError.invalidFormat
        }

        frameCount = preparedTracks.map { $0.source.frameCount }.max() ?? 0
        self.sampleRate = sampleRate
        mirroredFrameIndex = 0
        mirroredFrameCount = frameCount
        mirroredIsPlaying = false
        mirroredHostTimestamp = CACurrentMediaTime()
        pendingCommandRenderedFrameCount = nil
        preparedProjectTracks = preparedTracks
        let referenceTrack = zeroCrossingReferenceTrack(in: preparedTracks)
        zeroCrossingIndex = referenceTrack?.zeroCrossingIndex
        zeroCrossingProbe = referenceTrack?.zeroCrossingProbe
        sourceLoaded = true
        core.setGain(masterGain)
        try configureOutputDevice(sampleRate: sampleRate)
    }

    func replaceWithDecodedSource(
        _ decodedAudioBuffer: DecodedAudioBuffer,
        zeroCrossingIndex: AudioZeroCrossingIndex? = nil
    ) throws {
        guard hasSource else {
            try load(decodedAudioBuffer, zeroCrossingIndex: zeroCrossingIndex)
            return
        }

        let previousSnapshot = snapshot()
        try load(decodedAudioBuffer, zeroCrossingIndex: zeroCrossingIndex)
        try seek(toProgress: previousSnapshot.progress)

        if previousSnapshot.isPlaying {
            try play()
        }
    }

    func clear() {
        core.reset()
        frameCount = 0
        sampleRate = 0
        mirroredFrameIndex = 0
        mirroredFrameCount = 0
        mirroredIsPlaying = false
        mirroredHostTimestamp = CACurrentMediaTime()
        pendingCommandRenderedFrameCount = nil
        zeroCrossingIndex = nil
        zeroCrossingProbe = nil
        preparedProjectTracks.removeAll()
        sourceLoaded = false
        outputDevice.stop()
    }

    func updateZeroCrossingIndex(_ zeroCrossingIndex: AudioZeroCrossingIndex?) {
        self.zeroCrossingIndex = zeroCrossingIndex
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

        try outputDevice.start()

        let detailedSnapshot = core.detailedSnapshot()
        if mirroredFrameIndex >= frameCount {
            mirroredFrameIndex = 0
        } else {
            mirroredFrameIndex = min(max(mirroredFrameIndex, 0), max(frameCount - 1, 0))
        }
        mirroredFrameCount = frameCount
        mirroredIsPlaying = true
        mirroredHostTimestamp = CACurrentMediaTime()
        pendingCommandRenderedFrameCount = detailedSnapshot.renderedFrameCount
        core.seek(toFrame: mirroredFrameIndex)
        core.play()
    }

    func pause() {
        let pauseTimestamp = CACurrentMediaTime()
        let detailedSnapshot = core.detailedSnapshot()
        mirroredFrameIndex = projectedFrameIndex(
            from: detailedSnapshot,
            at: pauseTimestamp
        )
        mirroredFrameCount = frameCount
        mirroredIsPlaying = false
        mirroredHostTimestamp = pauseTimestamp
        pendingCommandRenderedFrameCount = detailedSnapshot.renderedFrameCount
        core.pause(atFrame: mirroredFrameIndex)
    }

    func seek(toProgress progress: Float) throws {
        guard hasSource else {
            throw PlaybackError.noAudioLoaded
        }

        let clampedProgress = min(max(progress, 0), 1)
        let targetFrame = min(
            max(Int((clampedProgress * Float(frameCount)).rounded(.down)), 0),
            frameCount
        )
        let snappedTargetFrame = snappedFrameToZeroCrossing(
            targetFrame,
            allowsEnd: targetFrame >= frameCount
        )
        let detailedSnapshot = core.detailedSnapshot()
        mirroredFrameIndex = snappedTargetFrame
        mirroredFrameCount = frameCount
        mirroredHostTimestamp = CACurrentMediaTime()
        pendingCommandRenderedFrameCount = detailedSnapshot.renderedFrameCount
        core.seek(toFrame: snappedTargetFrame)
    }

    func updateProjectTrackMix(_ tracks: [ProjectPlaybackTrack]) {
        guard !preparedProjectTracks.isEmpty else {
            return
        }

        var updatedPreparedTracks = preparedProjectTracks
        for track in tracks {
            guard let preparedTrackIndex = updatedPreparedTracks.firstIndex(where: { $0.id == track.id }) else {
                continue
            }

            updatedPreparedTracks[preparedTrackIndex].volume = track.volume
            updatedPreparedTracks[preparedTrackIndex].isMuted = track.isMuted
            updatedPreparedTracks[preparedTrackIndex].isSoloed = track.isSoloed
        }

        let didPublish = core.updatePreparedTracks(
            updatedPreparedTracks.map { preparedTrack in
                PreparedRealtimeAudioTrack(
                    source: preparedTrack.source,
                    gain: effectiveTrackGain(preparedTrack, in: updatedPreparedTracks)
                )
            }
        )
        if didPublish {
            preparedProjectTracks = updatedPreparedTracks
        }
    }

    func snapshot() -> PlaybackSnapshot {
        let detailedSnapshot = core.detailedSnapshot()
        let snapshotTimestamp = CACurrentMediaTime()
        if
            let pendingCommandRenderedFrameCount,
            detailedSnapshot.renderedFrameCount <= pendingCommandRenderedFrameCount
        {
            return PlaybackSnapshot(
                frameIndex: mirroredFrameIndex,
                frameCount: mirroredFrameCount,
                isPlaying: mirroredIsPlaying,
                hostTimestamp: mirroredHostTimestamp
            )
        }

        pendingCommandRenderedFrameCount = nil
        mirroredFrameCount = detailedSnapshot.frameCount
        mirroredIsPlaying = detailedSnapshot.isPlaying
        if detailedSnapshot.isPlaying {
            mirroredFrameIndex = projectedFrameIndex(
                from: detailedSnapshot,
                at: snapshotTimestamp
            )
            mirroredHostTimestamp = snapshotTimestamp
        } else {
            mirroredFrameIndex = detailedSnapshot.frameIndex
            mirroredHostTimestamp = detailedSnapshot.hostTimestamp
        }

        return PlaybackSnapshot(
            frameIndex: mirroredFrameIndex,
            frameCount: mirroredFrameCount,
            isPlaying: mirroredIsPlaying,
            hostTimestamp: mirroredHostTimestamp
        )
    }

    private func projectedFrameIndex(
        from detailedSnapshot: RealtimeAudioCoreSnapshot,
        at timestamp: TimeInterval
    ) -> Int {
        let baseFrameIndex: Int
        let baseHostTimestamp: TimeInterval
        let baseIsPlaying: Bool
        if
            let pendingCommandRenderedFrameCount,
            detailedSnapshot.renderedFrameCount <= pendingCommandRenderedFrameCount
        {
            baseFrameIndex = mirroredFrameIndex
            baseHostTimestamp = mirroredHostTimestamp
            baseIsPlaying = mirroredIsPlaying
        } else {
            baseFrameIndex = detailedSnapshot.frameIndex
            baseHostTimestamp = detailedSnapshot.hostTimestamp
            baseIsPlaying = detailedSnapshot.isPlaying
        }

        guard
            baseIsPlaying,
            sampleRate.isFinite,
            sampleRate > 0,
            baseHostTimestamp > 0
        else {
            return min(max(baseFrameIndex, 0), frameCount)
        }

        let elapsedTime = max(timestamp - baseHostTimestamp, 0)
        let elapsedFrames = Int((elapsedTime * sampleRate).rounded(.down))
        return min(max(baseFrameIndex + elapsedFrames, 0), frameCount)
    }

    private func configureOutputDevice(sampleRate: Double) throws {
        guard let corePointer = core.enginePointer else {
            throw PlaybackError.invalidFormat
        }

        try outputDevice.configure(corePointer: corePointer, sampleRate: sampleRate)
    }

    private func preparedProjectTrack(from track: ProjectPlaybackTrack) throws -> PreparedProjectTrack {
        let preparedSource: PreparedRealtimeAudioSource
        let zeroCrossingIndex: AudioZeroCrossingIndex?
        let zeroCrossingProbe: WAVZeroCrossingProbe?

        switch track.source {
        case let .decoded(decodedAudioBuffer, sourceZeroCrossingIndex):
            if let existingPreparedTrack = preparedProjectTracks.first(where: { existingTrack in
                existingTrack.id == track.id &&
                    existingTrack.sourceRevision == track.sourceRevision &&
                    existingTrack.source.frameCount == decodedAudioBuffer.frameCount &&
                    existingTrack.source.channelCount == decodedAudioBuffer.channelCount &&
                    existingTrack.source.sampleRate == decodedAudioBuffer.sampleRate
            }) {
                preparedSource = existingPreparedTrack.source
                zeroCrossingIndex = sourceZeroCrossingIndex
                zeroCrossingProbe = nil
                break
            }

            guard let source = PreparedRealtimeAudioSource.make(from: decodedAudioBuffer) else {
                throw PlaybackError.invalidFormat
            }
            preparedSource = source
            zeroCrossingIndex = sourceZeroCrossingIndex
            zeroCrossingProbe = nil
        case .file:
            throw PlaybackError.invalidFormat
        }

        return PreparedProjectTrack(
            id: track.id,
            sourceRevision: track.sourceRevision,
            source: preparedSource,
            zeroCrossingIndex: zeroCrossingIndex,
            zeroCrossingProbe: zeroCrossingProbe,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed
        )
    }

    private func effectiveTrackGain(
        _ track: PreparedProjectTrack,
        in tracks: [PreparedProjectTrack]
    ) -> Float {
        let anySoloedTrack = tracks.contains { $0.isSoloed }
        guard
            !track.isMuted,
            !anySoloedTrack || track.isSoloed
        else {
            return 0
        }

        let clampedVolume = min(max(track.volume, 0), 1)
        return clampedVolume * clampedVolume
    }

    private func zeroCrossingReferenceTrack(in tracks: [PreparedProjectTrack]) -> PreparedProjectTrack? {
        let anySoloedTrack = tracks.contains { $0.isSoloed }
        return tracks.first { track in
            !track.isMuted && (!anySoloedTrack || track.isSoloed)
        } ?? tracks.first
    }

    private func snappedFrameToZeroCrossing(
        _ frame: Int,
        allowsEnd: Bool
    ) -> Int {
        let clampedFrame = min(max(frame, 0), frameCount)
        guard clampedFrame > 0, clampedFrame < frameCount else {
            return clampedFrame
        }

        let snappedFrame: Int
        if let zeroCrossingIndex, zeroCrossingIndex.frameCount == frameCount {
            snappedFrame = zeroCrossingIndex.nearestFrame(to: clampedFrame)
        } else if let zeroCrossingProbe {
            snappedFrame = zeroCrossingProbe.nearestFrame(to: clampedFrame)
        } else {
            snappedFrame = clampedFrame
        }

        let boundedFrame = min(max(snappedFrame, 0), frameCount)
        if !allowsEnd, boundedFrame >= frameCount {
            return max(frameCount - 1, 0)
        }

        return boundedFrame
    }

}
