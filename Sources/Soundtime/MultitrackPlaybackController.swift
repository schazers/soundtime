import AVFoundation
import Foundation
import QuartzCore

@MainActor
final class MultitrackPlaybackController: PlaybackEngine {
    private enum PlaybackSource {
        case decoded(DecodedAudioBuffer)
        case file(AVAudioFile)

        var frameCount: Int {
            switch self {
            case let .decoded(decodedAudioBuffer):
                decodedAudioBuffer.frameCount
            case let .file(audioFile):
                Int(audioFile.length)
            }
        }

        var sampleRate: Double {
            switch self {
            case let .decoded(decodedAudioBuffer):
                decodedAudioBuffer.sampleRate
            case let .file(audioFile):
                audioFile.processingFormat.sampleRate
            }
        }

        var duration: TimeInterval {
            guard sampleRate > 0 else {
                return 0
            }

            return Double(frameCount) / sampleRate
        }
    }

    private struct TrackPlayer {
        var track: ProjectPlaybackTrack
        let playerNode: AVAudioPlayerNode
        let source: PlaybackSource
        let zeroCrossingIndex: AudioZeroCrossingIndex?
        let zeroCrossingProbe: WAVZeroCrossingProbe?

        var frameCount: Int {
            source.frameCount
        }

        var sampleRate: Double {
            source.sampleRate
        }

        var duration: TimeInterval {
            source.duration
        }
    }

    private let engine = AVAudioEngine()
    private var trackPlayers: [UUID: TrackPlayer] = [:]
    private var trackOrder: [UUID] = []
    private var scheduledDecodedBuffers: [(endProjectFrame: Int, buffer: AVAudioPCMBuffer)] = []
    private var scheduledStartProjectFrame = 0
    private var scheduledEndProjectFrame = 0
    private var pausedProjectFrame = 0
    private var pausedFrameHostTimestamp = CACurrentMediaTime()
    private var playbackStartProjectFrame = 0
    private var playbackStartHostTimestamp = CACurrentMediaTime()
    private var isPlayerRunning = false
    private var isRestartPending = false
    private var transportRampTask: Task<Void, Never>?
    private var masterVolume: Float = 1
    private var transportGain: Float = 1
    private let transportRampDuration: TimeInterval = 0.018
    private let synchronizedStartDelay: TimeInterval = 0.02
    private let playbackChunkDuration: TimeInterval = 0.25
    private let playbackInitialScheduleAheadDuration: TimeInterval = 0.4
    private let playbackScheduleAheadDuration: TimeInterval = 1.4

    var isPlaying: Bool {
        isPlayerRunning || isRestartPending
    }

    var hasSource: Bool {
        !trackPlayers.isEmpty && projectFrameCount() > 0
    }

    func setPerceptualVolume(_ volume: Float) {
        let clampedVolume = min(max(volume, 0), 1)
        masterVolume = clampedVolume * clampedVolume
        applyOutputVolume()
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
                sourceRevision: 0,
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
                sourceRevision: 0,
                volume: 1,
                isMuted: false,
                isSoloed: false
            ),
        ])
    }

    func loadProjectTracks(_ tracks: [ProjectPlaybackTrack]) throws {
        clear()

        do {
            for track in tracks {
                let trackPlayer = try makeTrackPlayer(for: track)
                trackPlayers[track.id] = trackPlayer
                trackOrder.append(track.id)
            }
        } catch {
            clear()
            throw error
        }

        applyTrackVolumes()
        pausedProjectFrame = 0
        pausedFrameHostTimestamp = CACurrentMediaTime()
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
        cancelTransportRamp()
        stopAllPlayerNodes()
        for player in trackPlayers.values {
            engine.detach(player.playerNode)
        }

        engine.stop()
        trackPlayers.removeAll()
        trackOrder.removeAll()
        scheduledDecodedBuffers.removeAll()
        scheduledStartProjectFrame = 0
        scheduledEndProjectFrame = 0
        pausedProjectFrame = 0
        pausedFrameHostTimestamp = CACurrentMediaTime()
        playbackStartProjectFrame = 0
        playbackStartHostTimestamp = CACurrentMediaTime()
        isPlayerRunning = false
        isRestartPending = false
        transportGain = 1
        applyOutputVolume()
    }

    func updateZeroCrossingIndex(_ zeroCrossingIndex: AudioZeroCrossingIndex?) {}

    func updateProjectTrackMix(_ tracks: [ProjectPlaybackTrackMix]) {
        for trackMix in tracks {
            guard var player = trackPlayers[trackMix.id] else {
                continue
            }

            player.track = ProjectPlaybackTrack(
                id: player.track.id,
                source: player.track.source,
                sourceRevision: player.track.sourceRevision,
                volume: trackMix.volume,
                isMuted: trackMix.isMuted,
                isSoloed: trackMix.isSoloed
            )
            trackPlayers[trackMix.id] = player
        }

        applyTrackVolumes()
        applyOutputVolume()
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

        let frameCount = projectFrameCount()
        if pausedProjectFrame >= frameCount {
            pausedProjectFrame = 0
        } else {
            pausedProjectFrame = min(max(pausedProjectFrame, 0), max(frameCount - 1, 0))
        }

        pausedProjectFrame = snappedProjectFrameToZeroCrossing(
            pausedProjectFrame,
            allowsEnd: false
        )
        scheduledStartProjectFrame = pausedProjectFrame
        scheduledEndProjectFrame = pausedProjectFrame
        scheduledDecodedBuffers.removeAll()
        cancelTransportRamp()
        stopAllPlayerNodes()
        try schedulePlaybackAhead(
            from: pausedProjectFrame,
            aheadDuration: playbackInitialScheduleAheadDuration
        )

        transportGain = 0
        applyOutputVolume()
        let startHostTimestamp = try startAllPlayerNodesSynchronously()

        playbackStartProjectFrame = pausedProjectFrame
        playbackStartHostTimestamp = startHostTimestamp
        isPlayerRunning = true
        isRestartPending = false
        beginTransportRamp(to: 1)
    }

    func pause() {
        guard hasSource else {
            return
        }

        let timedFrame = currentTimedProjectFrame()
        pausedProjectFrame = min(max(timedFrame.frameIndex, 0), projectFrameCount())
        pausedFrameHostTimestamp = timedFrame.hostTimestamp
        isPlayerRunning = false
        isRestartPending = false
        beginTransportRamp(to: 0) { [weak self] in
            guard let self else {
                return
            }

            for player in trackPlayers.values {
                player.playerNode.pause()
            }
            transportGain = 1
            applyOutputVolume()
        }
    }

    func pause(atProgress progress: Float) {
        guard hasSource else {
            return
        }

        let timedFrame = currentTimedProjectFrame()
        let frameCount = projectFrameCount()
        pausedProjectFrame = min(
            max(Int((min(max(progress, 0), 1) * Float(frameCount)).rounded(.down)), 0),
            frameCount
        )
        pausedFrameHostTimestamp = timedFrame.hostTimestamp
        isPlayerRunning = false
        isRestartPending = false
        beginTransportRamp(to: 0) { [weak self] in
            guard let self else {
                return
            }

            for player in trackPlayers.values {
                player.playerNode.pause()
            }
            transportGain = 1
            applyOutputVolume()
        }
    }

    func seek(toProgress progress: Float) throws {
        try seek(toProgress: progress, snapsToZeroCrossing: true)
    }

    func seekExactly(toProgress progress: Float) throws {
        try seek(toProgress: progress, snapsToZeroCrossing: false)
    }

    private func seek(toProgress progress: Float, snapsToZeroCrossing: Bool) throws {
        guard hasSource else {
            throw PlaybackError.noAudioLoaded
        }

        let frameCount = projectFrameCount()
        let clampedProgress = min(max(progress, 0), 1)
        let targetFrame = min(
            max(Int((clampedProgress * Float(frameCount)).rounded(.down)), 0),
            frameCount
        )
        let snappedTargetFrame = snapsToZeroCrossing ?
            snappedProjectFrameToZeroCrossing(
                targetFrame,
                allowsEnd: targetFrame >= frameCount
            ) :
            targetFrame
        let shouldResumePlayback = isPlaying && snappedTargetFrame < frameCount

        scheduledDecodedBuffers.removeAll()
        scheduledStartProjectFrame = snappedTargetFrame
        scheduledEndProjectFrame = snappedTargetFrame
        pausedProjectFrame = snappedTargetFrame
        pausedFrameHostTimestamp = CACurrentMediaTime()

        guard shouldResumePlayback else {
            cancelTransportRamp()
            stopAllPlayerNodes()
            transportGain = 1
            applyOutputVolume()
            isPlayerRunning = false
            isRestartPending = false
            return
        }

        isPlayerRunning = false
        isRestartPending = true
        beginTransportRamp(to: 0) { [weak self] in
            guard let self else {
                return
            }

            stopAllPlayerNodes()
            scheduledDecodedBuffers.removeAll()
            do {
                try schedulePlaybackAhead(
                    from: snappedTargetFrame,
                    aheadDuration: playbackInitialScheduleAheadDuration
                )

                transportGain = 0
                applyOutputVolume()
                let startHostTimestamp = try startAllPlayerNodesSynchronously()

                playbackStartProjectFrame = snappedTargetFrame
                playbackStartHostTimestamp = startHostTimestamp
                isPlayerRunning = true
                isRestartPending = false
                beginTransportRamp(to: 1)
            } catch {
                transportGain = 1
                applyOutputVolume()
                isPlayerRunning = false
                isRestartPending = false
            }
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

        let frameCount = projectFrameCount()
        let timedFrame = currentTimedProjectFrame()
        let frameIndex = timedFrame.frameIndex
        if isPlayerRunning, frameIndex >= frameCount {
            finishAtEnd()
        } else if isPlayerRunning {
            do {
                try schedulePlaybackAhead(from: frameIndex)
                pruneScheduledDecodedBuffers(before: frameIndex)
            } catch {
                finishAtEnd()
            }
        }

        return PlaybackSnapshot(
            frameIndex: min(frameIndex, frameCount),
            frameCount: frameCount,
            isPlaying: isPlaying,
            hostTimestamp: timedFrame.hostTimestamp
        )
    }

    private func makeTrackPlayer(for track: ProjectPlaybackTrack) throws -> TrackPlayer {
        let source: PlaybackSource
        let format: AVAudioFormat
        let zeroCrossingIndex: AudioZeroCrossingIndex?
        let zeroCrossingProbe: WAVZeroCrossingProbe?

        switch track.source {
        case let .decoded(decodedAudioBuffer, sourceZeroCrossingIndex):
            source = .decoded(decodedAudioBuffer)
            format = try playbackFormat(for: decodedAudioBuffer)
            zeroCrossingIndex = sourceZeroCrossingIndex
            zeroCrossingProbe = nil
        case let .file(url, sourceZeroCrossingProbe):
            let audioFile = try AVAudioFile(forReading: url)
            source = .file(audioFile)
            format = audioFile.processingFormat
            zeroCrossingIndex = nil
            zeroCrossingProbe = sourceZeroCrossingProbe
        case let .fileTimeline(url, _, sourceZeroCrossingProbe):
            let audioFile = try AVAudioFile(forReading: url)
            source = .file(audioFile)
            format = audioFile.processingFormat
            zeroCrossingIndex = nil
            zeroCrossingProbe = sourceZeroCrossingProbe
        case let .timeline(audioTimeline, sourceZeroCrossingIndex):
            let decodedAudioBuffer = audioTimeline.render()
            source = .decoded(decodedAudioBuffer)
            format = try playbackFormat(for: decodedAudioBuffer)
            zeroCrossingIndex = sourceZeroCrossingIndex
            zeroCrossingProbe = nil
        }

        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        return TrackPlayer(
            track: track,
            playerNode: playerNode,
            source: source,
            zeroCrossingIndex: zeroCrossingIndex,
            zeroCrossingProbe: zeroCrossingProbe
        )
    }

    private func startAllPlayerNodesSynchronously() throws -> TimeInterval {
        if !engine.isRunning {
            try engine.start()
        }

        let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: synchronizedStartDelay)
        let startTime = AVAudioTime(hostTime: startHostTime)
        for trackID in trackOrder {
            trackPlayers[trackID]?.playerNode.play(at: startTime)
        }
        return AVAudioTime.seconds(forHostTime: startHostTime)
    }

    private func currentTimedProjectFrame() -> (frameIndex: Int, hostTimestamp: TimeInterval) {
        let currentHostTimestamp = CACurrentMediaTime()
        guard isPlayerRunning else {
            return (pausedProjectFrame, pausedFrameHostTimestamp)
        }

        let elapsedTime = currentHostTimestamp - playbackStartHostTimestamp
        let frameIndex = min(
            max(playbackStartProjectFrame + Int((elapsedTime * projectSampleRate()).rounded(.towardZero)), 0),
            projectFrameCount()
        )
        return (frameIndex, currentHostTimestamp)
    }

    private func finishAtEnd() {
        cancelTransportRamp()
        stopAllPlayerNodes()
        scheduledDecodedBuffers.removeAll()
        pausedProjectFrame = projectFrameCount()
        pausedFrameHostTimestamp = CACurrentMediaTime()
        isPlayerRunning = false
        isRestartPending = false
        transportGain = 1
        applyOutputVolume()
    }

    private func stopAllPlayerNodes() {
        for player in trackPlayers.values {
            player.playerNode.stop()
        }
    }

    private func schedulePlaybackAhead(
        from projectFrame: Int,
        aheadDuration: TimeInterval? = nil
    ) throws {
        let frameCount = projectFrameCount()
        guard scheduledEndProjectFrame < frameCount else {
            return
        }

        let sampleRate = projectSampleRate()
        let aheadFrames = max(Int(sampleRate * (aheadDuration ?? playbackScheduleAheadDuration)), 1)
        let targetEndProjectFrame = min(projectFrame + aheadFrames, frameCount)
        guard scheduledEndProjectFrame < targetEndProjectFrame else {
            return
        }

        while scheduledEndProjectFrame < targetEndProjectFrame {
            let chunkProjectFrameCount = min(
                max(Int(sampleRate * playbackChunkDuration), 1),
                targetEndProjectFrame - scheduledEndProjectFrame
            )
            guard chunkProjectFrameCount > 0 else {
                return
            }

            try schedulePlaybackChunk(
                startingAt: scheduledEndProjectFrame,
                frameCount: chunkProjectFrameCount
            )
            scheduledEndProjectFrame += chunkProjectFrameCount
        }
    }

    private func schedulePlaybackChunk(
        startingAt projectStartFrame: Int,
        frameCount projectFrameCount: Int
    ) throws {
        let projectStartTime = TimeInterval(projectStartFrame) / projectSampleRate()
        let projectEndTime = TimeInterval(projectStartFrame + projectFrameCount) / projectSampleRate()

        for trackID in trackOrder {
            guard let player = trackPlayers[trackID] else {
                continue
            }

            let sourceStartFrame = min(
                max(Int((projectStartTime * player.sampleRate).rounded(.down)), 0),
                player.frameCount
            )
            let sourceEndFrame = min(
                max(Int((projectEndTime * player.sampleRate).rounded(.up)), sourceStartFrame),
                player.frameCount
            )
            let sourceFrameCount = sourceEndFrame - sourceStartFrame
            guard sourceFrameCount > 0 else {
                continue
            }

            switch player.source {
            case let .decoded(decodedAudioBuffer):
                let playbackBuffer = try makePlaybackBuffer(
                    from: decodedAudioBuffer,
                    startingAt: sourceStartFrame,
                    frameCount: sourceFrameCount
                )
                scheduledDecodedBuffers.append((
                    endProjectFrame: projectStartFrame + projectFrameCount,
                    buffer: playbackBuffer
                ))
                player.playerNode.scheduleBuffer(playbackBuffer, at: nil)
            case let .file(audioFile):
                player.playerNode.scheduleSegment(
                    audioFile,
                    startingFrame: AVAudioFramePosition(sourceStartFrame),
                    frameCount: AVAudioFrameCount(sourceFrameCount),
                    at: nil
                )
            }
        }
    }

    private func pruneScheduledDecodedBuffers(before frame: Int) {
        scheduledDecodedBuffers.removeAll { scheduledBuffer in
            scheduledBuffer.endProjectFrame < frame
        }
    }

    private func beginTransportRamp(to targetVolume: Float, completion: (() -> Void)? = nil) {
        transportRampTask?.cancel()

        let initialVolume = transportGain
        let stepCount = 18
        let stepDuration = transportRampDuration / Double(stepCount)

        transportRampTask = Task { @MainActor in
            for stepIndex in 1...stepCount {
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
                guard !Task.isCancelled else {
                    return
                }

                let progress = Float(stepIndex) / Float(stepCount)
                let easedProgress = progress * progress * (3 - 2 * progress)
                transportGain = initialVolume + (targetVolume - initialVolume) * easedProgress
                applyOutputVolume()
            }

            guard !Task.isCancelled else {
                return
            }

            completion?()
        }
    }

    private func cancelTransportRamp() {
        transportRampTask?.cancel()
        transportRampTask = nil
    }

    private func applyTrackVolumes() {
        let anySoloedTrack = trackPlayers.values.contains { $0.track.isSoloed }
        for player in trackPlayers.values {
            let shouldPlayTrack = isTrackAudible(player.track, anySoloedTrack: anySoloedTrack)
            let clampedTrackVolume = min(max(player.track.volume, 0), 1)
            player.playerNode.volume = shouldPlayTrack ? clampedTrackVolume * clampedTrackVolume : 0
        }
    }

    private func applyOutputVolume() {
        engine.mainMixerNode.outputVolume = masterVolume * transportGain
    }

    private func snappedProjectFrameToZeroCrossing(_ frame: Int, allowsEnd: Bool) -> Int {
        let frameCount = projectFrameCount()
        let clampedFrame = min(max(frame, 0), frameCount)
        guard clampedFrame > 0, clampedFrame < frameCount else {
            return clampedFrame
        }

        guard let referencePlayer = zeroCrossingReferencePlayer(containingProjectFrame: clampedFrame) else {
            return clampedFrame
        }

        let projectTime = TimeInterval(clampedFrame) / projectSampleRate()
        let sourceFrame = min(
            max(Int((projectTime * referencePlayer.sampleRate).rounded(.down)), 0),
            referencePlayer.frameCount
        )

        let snappedSourceFrame: Int
        if
            let zeroCrossingIndex = referencePlayer.zeroCrossingIndex,
            zeroCrossingIndex.frameCount == referencePlayer.frameCount
        {
            snappedSourceFrame = zeroCrossingIndex.nearestFrame(to: sourceFrame)
        } else if let zeroCrossingProbe = referencePlayer.zeroCrossingProbe {
            snappedSourceFrame = zeroCrossingProbe.nearestFrame(to: sourceFrame)
        } else {
            snappedSourceFrame = sourceFrame
        }

        let snappedProjectTime = TimeInterval(snappedSourceFrame) / referencePlayer.sampleRate
        let snappedProjectFrame = Int((snappedProjectTime * projectSampleRate()).rounded(.down))
        let boundedFrame = min(max(snappedProjectFrame, 0), frameCount)
        if !allowsEnd, boundedFrame >= frameCount {
            return max(frameCount - 1, 0)
        }

        return boundedFrame
    }

    private func zeroCrossingReferencePlayer(containingProjectFrame projectFrame: Int) -> TrackPlayer? {
        let sampleRate = projectSampleRate()
        guard sampleRate.isFinite, sampleRate > 0 else {
            return nil
        }

        let projectTime = TimeInterval(projectFrame) / sampleRate
        let anySoloedTrack = trackPlayers.values.contains { $0.track.isSoloed }
        for trackID in trackOrder {
            guard let player = trackPlayers[trackID] else {
                continue
            }

            guard isTrackAudible(player.track, anySoloedTrack: anySoloedTrack) else {
                continue
            }

            let sourceFrame = Int((projectTime * player.sampleRate).rounded(.down))
            if sourceFrame > 0, sourceFrame < player.frameCount {
                return player
            }
        }

        return nil
    }

    private func isTrackAudible(
        _ track: ProjectPlaybackTrack,
        anySoloedTrack: Bool
    ) -> Bool {
        anySoloedTrack ? track.isSoloed : !track.isMuted
    }

    private func projectSampleRate() -> Double {
        trackOrder.compactMap { trackPlayers[$0]?.sampleRate }.first ?? 44_100
    }

    private func projectDuration() -> TimeInterval {
        trackPlayers.values.reduce(TimeInterval(0)) { max($0, $1.duration) }
    }

    private func projectFrameCount() -> Int {
        let sampleRate = projectSampleRate()
        guard sampleRate > 0 else {
            return 0
        }

        return Int((projectDuration() * sampleRate).rounded(.up))
    }

    private func playbackFormat(for decodedAudioBuffer: DecodedAudioBuffer) throws -> AVAudioFormat {
        guard
            decodedAudioBuffer.sampleRate > 0,
            decodedAudioBuffer.channelCount > 0,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: decodedAudioBuffer.sampleRate,
                channels: AVAudioChannelCount(decodedAudioBuffer.channelCount),
                interleaved: false
            )
        else {
            throw PlaybackError.invalidFormat
        }

        return format
    }

    private func makePlaybackBuffer(
        from decodedAudioBuffer: DecodedAudioBuffer,
        startingAt startFrame: Int,
        frameCount requestedFrameCount: Int
    ) throws -> AVAudioPCMBuffer {
        let clampedStartFrame = min(max(startFrame, 0), decodedAudioBuffer.frameCount)
        let frameCount = min(max(requestedFrameCount, 0), decodedAudioBuffer.frameCount - clampedStartFrame)
        guard frameCount > 0 else {
            throw PlaybackError.invalidFormat
        }

        let format = try playbackFormat(for: decodedAudioBuffer)
        guard
            let playbackBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        else {
            throw PlaybackError.bufferCreationFailed
        }

        playbackBuffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channelData = playbackBuffer.floatChannelData else {
            throw PlaybackError.bufferCreationFailed
        }

        for channelIndex in 0..<decodedAudioBuffer.channelCount {
            let sourceSamples = decodedAudioBuffer.samplesByChannel[channelIndex]
            let destinationSamples = channelData[channelIndex]

            for frameIndex in 0..<frameCount {
                destinationSamples[frameIndex] = sourceSamples[clampedStartFrame + frameIndex]
            }
        }

        return playbackBuffer
    }
}
