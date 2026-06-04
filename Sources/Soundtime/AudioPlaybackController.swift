import AVFoundation
import Foundation

@MainActor
final class AudioPlaybackController {
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
    }

    struct Snapshot {
        let frameIndex: Int
        let frameCount: Int
        let isPlaying: Bool

        var progress: Float {
            guard frameCount > 0 else {
                return 0
            }

            return min(max(Float(frameIndex) / Float(frameCount), 0), 1)
        }

        var isAtEnd: Bool {
            frameCount > 0 && frameIndex >= frameCount
        }
    }

    enum PlaybackError: LocalizedError {
        case noAudioLoaded
        case invalidFormat
        case bufferCreationFailed

        var errorDescription: String? {
            switch self {
            case .noAudioLoaded:
                "No decoded WAV is loaded."
            case .invalidFormat:
                "The decoded WAV has an unsupported playback format."
            case .bufferCreationFailed:
                "Could not create the playback buffer."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var playbackSource: PlaybackSource?
    private var zeroCrossingIndex: AudioZeroCrossingIndex?
    private var zeroCrossingProbe: WAVZeroCrossingProbe?
    private var scheduledPlaybackBuffers: [(endFrame: Int, buffer: AVAudioPCMBuffer)] = []
    private var scheduledStartFrame = 0
    private var scheduledEndFrame = 0
    private var pausedFrame = 0
    private var isPlayerRunning = false
    private var isRestartPending = false
    private var transportRampTask: Task<Void, Never>?
    private var masterVolume: Float = 1
    private var transportGain: Float = 1
    private let transportRampDuration: TimeInterval = 0.018
    private let playbackChunkDuration: TimeInterval = 1
    private let playbackScheduleAheadDuration: TimeInterval = 3

    var isPlaying: Bool {
        isPlayerRunning || isRestartPending
    }

    var hasSource: Bool {
        playbackSource != nil
    }

    init() {
        engine.attach(playerNode)
        playerNode.volume = 1
        applyOutputVolume()
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
        stopEnginePlayback()
        playbackSource = .decoded(decodedAudioBuffer)
        self.zeroCrossingIndex = zeroCrossingIndex
        zeroCrossingProbe = nil
        scheduledStartFrame = 0
        scheduledEndFrame = 0
        pausedFrame = 0

        let format = try playbackFormat(for: decodedAudioBuffer)
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    func loadFile(at url: URL, zeroCrossingProbe: WAVZeroCrossingProbe? = nil) throws {
        stopEnginePlayback()
        let audioFile = try AVAudioFile(forReading: url)
        playbackSource = .file(audioFile)
        zeroCrossingIndex = nil
        self.zeroCrossingProbe = zeroCrossingProbe
        scheduledStartFrame = 0
        scheduledEndFrame = 0
        pausedFrame = 0

        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: audioFile.processingFormat)
    }

    func clear() {
        stopEnginePlayback()
        playbackSource = nil
        zeroCrossingIndex = nil
        zeroCrossingProbe = nil
        scheduledStartFrame = 0
        scheduledEndFrame = 0
        pausedFrame = 0
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
        guard let playbackSource else {
            throw PlaybackError.noAudioLoaded
        }

        let sourceFrameCount = playbackSource.frameCount
        if pausedFrame >= sourceFrameCount {
            pausedFrame = 0
        }
        pausedFrame = snappedFrameToZeroCrossing(
            pausedFrame,
            frameCount: sourceFrameCount,
            allowsEnd: false
        )

        scheduledStartFrame = pausedFrame
        cancelTransportRamp()
        playerNode.stop()
        try schedulePlayback(startingAt: pausedFrame)

        if !engine.isRunning {
            try engine.start()
        }

        transportGain = 0
        applyOutputVolume()
        playerNode.play()
        isPlayerRunning = true
        isRestartPending = false
        beginTransportRamp(to: 1)
    }

    func pause() {
        guard let playbackSource else {
            return
        }

        let frame = currentFrame()
        pausedFrame = snappedFrameToZeroCrossing(
            frame,
            frameCount: playbackSource.frameCount,
            allowsEnd: true
        )
        isPlayerRunning = false
        isRestartPending = false
        beginTransportRamp(to: 0) { [weak self] in
            guard let self else {
                return
            }

            playerNode.pause()
            transportGain = 1
            applyOutputVolume()
        }
    }

    func seek(toProgress progress: Float) throws {
        try seek(toProgress: progress, shouldRampIfPlaying: true)
    }

    private func seek(toProgress progress: Float, shouldRampIfPlaying: Bool) throws {
        guard let playbackSource else {
            throw PlaybackError.noAudioLoaded
        }

        let sourceFrameCount = playbackSource.frameCount
        let clampedProgress = min(max(progress, 0), 1)
        let targetFrame = min(
            max(Int((clampedProgress * Float(sourceFrameCount)).rounded(.down)), 0),
            sourceFrameCount
        )
        let snappedTargetFrame = snappedFrameToZeroCrossing(
            targetFrame,
            frameCount: sourceFrameCount,
            allowsEnd: targetFrame >= sourceFrameCount
        )
        let shouldResumePlayback = isPlaying && snappedTargetFrame < sourceFrameCount

        scheduledPlaybackBuffers.removeAll()
        scheduledStartFrame = snappedTargetFrame
        scheduledEndFrame = snappedTargetFrame
        pausedFrame = snappedTargetFrame

        guard shouldResumePlayback else {
            cancelTransportRamp()
            playerNode.stop()
            scheduledPlaybackBuffers.removeAll()
            transportGain = 1
            applyOutputVolume()
            isPlayerRunning = false
            isRestartPending = false
            return
        }

        guard shouldRampIfPlaying else {
            cancelTransportRamp()
            playerNode.stop()
            scheduledPlaybackBuffers.removeAll()
            try schedulePlayback(startingAt: snappedTargetFrame)

            if !engine.isRunning {
                try engine.start()
            }

            transportGain = 0
            applyOutputVolume()
            playerNode.play()
            isPlayerRunning = true
            isRestartPending = false
            beginTransportRamp(to: 1)
            return
        }

        isPlayerRunning = false
        isRestartPending = true
        beginTransportRamp(to: 0) { [weak self] in
            guard let self else {
                return
            }

            playerNode.stop()
            scheduledPlaybackBuffers.removeAll()

            do {
                try schedulePlayback(startingAt: snappedTargetFrame)

                if !engine.isRunning {
                    try engine.start()
                }

                transportGain = 0
                applyOutputVolume()
                playerNode.play()
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

    func snapshot() -> Snapshot {
        guard let playbackSource else {
            return Snapshot(frameIndex: 0, frameCount: 0, isPlaying: false)
        }

        let sourceFrameCount = playbackSource.frameCount
        let frameIndex = currentFrame()
        if isPlayerRunning, frameIndex >= sourceFrameCount {
            finishAtEnd()
        } else if isPlayerRunning {
            do {
                try schedulePlaybackAhead(from: frameIndex)
                pruneScheduledPlaybackBuffers(before: frameIndex)
            } catch {
                finishAtEnd()
            }
        }

        return Snapshot(
            frameIndex: min(frameIndex, sourceFrameCount),
            frameCount: sourceFrameCount,
            isPlaying: isPlaying
        )
    }

    private func currentFrame() -> Int {
        guard let playbackSource else {
            return 0
        }
        guard isPlayerRunning else {
            return pausedFrame
        }
        guard
            let nodeTime = playerNode.lastRenderTime,
            let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else {
            return scheduledStartFrame
        }

        let elapsedFrames = max(Int(playerTime.sampleTime), 0)
        return min(scheduledStartFrame + elapsedFrames, playbackSource.frameCount)
    }

    private func finishAtEnd() {
        cancelTransportRamp()
        playerNode.stop()
        scheduledPlaybackBuffers.removeAll()
        pausedFrame = playbackSource?.frameCount ?? 0
        isPlayerRunning = false
        isRestartPending = false
        transportGain = 1
        applyOutputVolume()
    }

    private func stopEnginePlayback() {
        cancelTransportRamp()
        playerNode.stop()
        scheduledPlaybackBuffers.removeAll()
        isPlayerRunning = false
        isRestartPending = false
        pausedFrame = 0
        scheduledStartFrame = 0
        scheduledEndFrame = 0
        transportGain = 1
        applyOutputVolume()
    }

    private func schedulePlayback(startingAt startFrame: Int) throws {
        guard playbackSource != nil else {
            throw PlaybackError.noAudioLoaded
        }

        scheduledStartFrame = startFrame
        scheduledEndFrame = startFrame
        scheduledPlaybackBuffers.removeAll()
        try schedulePlaybackAhead(from: startFrame)
    }

    private func schedulePlaybackAhead(from frame: Int) throws {
        guard let playbackSource else {
            throw PlaybackError.noAudioLoaded
        }

        let sourceFrameCount = playbackSource.frameCount
        guard scheduledEndFrame < sourceFrameCount else {
            return
        }

        let scheduleAheadFrames = max(Int(playbackSource.sampleRate * playbackScheduleAheadDuration), 1)
        let targetEndFrame = min(max(frame, scheduledEndFrame) + scheduleAheadFrames, sourceFrameCount)

        while scheduledEndFrame < targetEndFrame {
            let chunkFrameCount = min(
                max(Int(playbackSource.sampleRate * playbackChunkDuration), 1),
                targetEndFrame - scheduledEndFrame
            )
            guard chunkFrameCount > 0 else {
                return
            }

            try schedulePlaybackChunk(startingAt: scheduledEndFrame, frameCount: chunkFrameCount)
            scheduledEndFrame += chunkFrameCount
        }
    }

    private func schedulePlaybackChunk(startingAt startFrame: Int, frameCount: Int) throws {
        guard let playbackSource else {
            throw PlaybackError.noAudioLoaded
        }

        switch playbackSource {
        case let .decoded(decodedAudioBuffer):
            let playbackBuffer = try makePlaybackBuffer(
                from: decodedAudioBuffer,
                startingAt: startFrame,
                frameCount: frameCount
            )
            scheduledPlaybackBuffers.append((endFrame: startFrame + frameCount, buffer: playbackBuffer))
            playerNode.scheduleBuffer(playbackBuffer, at: nil)
        case let .file(audioFile):
            guard frameCount > 0 else {
                throw PlaybackError.invalidFormat
            }

            playerNode.scheduleSegment(
                audioFile,
                startingFrame: AVAudioFramePosition(startFrame),
                frameCount: AVAudioFrameCount(frameCount),
                at: nil
            )
        }
    }

    private func pruneScheduledPlaybackBuffers(before frame: Int) {
        scheduledPlaybackBuffers.removeAll { scheduledBuffer in
            scheduledBuffer.endFrame < frame
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

    private func applyOutputVolume() {
        engine.mainMixerNode.outputVolume = masterVolume * transportGain
    }

    private func snappedFrameToZeroCrossing(
        _ frame: Int,
        frameCount: Int,
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
