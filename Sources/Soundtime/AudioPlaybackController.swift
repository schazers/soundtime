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
    private var scheduledPlaybackBuffer: AVAudioPCMBuffer?
    private var scheduledStartFrame = 0
    private var pausedFrame = 0
    private var isPlayerRunning = false

    var isPlaying: Bool {
        isPlayerRunning
    }

    var hasSource: Bool {
        playbackSource != nil
    }

    init() {
        engine.attach(playerNode)
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
        pausedFrame = 0
    }

    func updateZeroCrossingIndex(_ zeroCrossingIndex: AudioZeroCrossingIndex?) {
        self.zeroCrossingIndex = zeroCrossingIndex
    }

    @discardableResult
    func togglePlayback() throws -> Bool {
        if isPlayerRunning {
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
        playerNode.stop()

        switch playbackSource {
        case let .decoded(decodedAudioBuffer):
            let playbackBuffer = try makePlaybackBuffer(
                from: decodedAudioBuffer,
                startingAt: pausedFrame
            )
            scheduledPlaybackBuffer = playbackBuffer
            playerNode.scheduleBuffer(playbackBuffer, at: nil)
        case let .file(audioFile):
            let remainingFrameCount = sourceFrameCount - pausedFrame
            guard remainingFrameCount > 0 else {
                throw PlaybackError.invalidFormat
            }

            scheduledPlaybackBuffer = nil
            playerNode.scheduleSegment(
                audioFile,
                startingFrame: AVAudioFramePosition(pausedFrame),
                frameCount: AVAudioFrameCount(remainingFrameCount),
                at: nil
            )
        }

        if !engine.isRunning {
            try engine.start()
        }

        playerNode.play()
        isPlayerRunning = true
    }

    func pause() {
        guard let playbackSource else {
            return
        }

        pausedFrame = snappedFrameToZeroCrossing(
            currentFrame(),
            frameCount: playbackSource.frameCount,
            allowsEnd: true
        )
        playerNode.pause()
        isPlayerRunning = false
    }

    func seek(toProgress progress: Float) throws {
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
        let shouldResumePlayback = isPlayerRunning && snappedTargetFrame < sourceFrameCount

        playerNode.stop()
        scheduledPlaybackBuffer = nil
        scheduledStartFrame = snappedTargetFrame
        pausedFrame = snappedTargetFrame
        isPlayerRunning = false

        if shouldResumePlayback {
            try play()
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
        }

        return Snapshot(
            frameIndex: min(frameIndex, sourceFrameCount),
            frameCount: sourceFrameCount,
            isPlaying: isPlayerRunning
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
        playerNode.stop()
        scheduledPlaybackBuffer = nil
        pausedFrame = playbackSource?.frameCount ?? 0
        isPlayerRunning = false
    }

    private func stopEnginePlayback() {
        playerNode.stop()
        scheduledPlaybackBuffer = nil
        isPlayerRunning = false
        pausedFrame = 0
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
        startingAt startFrame: Int
    ) throws -> AVAudioPCMBuffer {
        let clampedStartFrame = min(max(startFrame, 0), decodedAudioBuffer.frameCount)
        let remainingFrameCount = decodedAudioBuffer.frameCount - clampedStartFrame
        guard remainingFrameCount > 0 else {
            throw PlaybackError.invalidFormat
        }

        let format = try playbackFormat(for: decodedAudioBuffer)

        guard
            let playbackBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(remainingFrameCount)
            )
        else {
            throw PlaybackError.bufferCreationFailed
        }

        playbackBuffer.frameLength = AVAudioFrameCount(remainingFrameCount)

        guard let channelData = playbackBuffer.floatChannelData else {
            throw PlaybackError.bufferCreationFailed
        }

        for channelIndex in 0..<decodedAudioBuffer.channelCount {
            let sourceSamples = decodedAudioBuffer.samplesByChannel[channelIndex]
            let destinationSamples = channelData[channelIndex]

            for frameIndex in 0..<remainingFrameCount {
                destinationSamples[frameIndex] = sourceSamples[clampedStartFrame + frameIndex]
            }
        }

        return playbackBuffer
    }
}
