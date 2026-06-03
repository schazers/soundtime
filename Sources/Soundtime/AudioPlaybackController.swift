import AVFoundation
import Foundation

@MainActor
final class AudioPlaybackController {
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
    private var decodedAudioBuffer: DecodedAudioBuffer?
    private var scheduledPlaybackBuffer: AVAudioPCMBuffer?
    private var scheduledStartFrame = 0
    private var pausedFrame = 0
    private var isPlayerRunning = false
    private var playbackGeneration = 0

    var isPlaying: Bool {
        isPlayerRunning
    }

    init() {
        engine.attach(playerNode)
    }

    func load(_ decodedAudioBuffer: DecodedAudioBuffer) throws {
        stopEnginePlayback()
        self.decodedAudioBuffer = decodedAudioBuffer
        scheduledStartFrame = 0
        pausedFrame = 0

        let format = try playbackFormat(for: decodedAudioBuffer)
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    func clear() {
        stopEnginePlayback()
        decodedAudioBuffer = nil
        scheduledStartFrame = 0
        pausedFrame = 0
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
        guard let decodedAudioBuffer else {
            throw PlaybackError.noAudioLoaded
        }

        if pausedFrame >= decodedAudioBuffer.frameCount {
            pausedFrame = 0
        }

        let playbackBuffer = try makePlaybackBuffer(
            from: decodedAudioBuffer,
            startingAt: pausedFrame
        )

        playbackGeneration += 1
        let generation = playbackGeneration
        scheduledStartFrame = pausedFrame
        scheduledPlaybackBuffer = playbackBuffer
        playerNode.stop()
        playerNode.scheduleBuffer(playbackBuffer, at: nil) { [weak self] in
            Task { @MainActor in
                guard
                    let self,
                    self.playbackGeneration == generation,
                    self.isPlayerRunning
                else {
                    return
                }

                self.finishAtEnd()
            }
        }

        if !engine.isRunning {
            try engine.start()
        }

        playerNode.play()
        isPlayerRunning = true
    }

    func pause() {
        pausedFrame = currentFrame()
        playbackGeneration += 1
        playerNode.pause()
        isPlayerRunning = false
    }

    func snapshot() -> Snapshot {
        guard let decodedAudioBuffer else {
            return Snapshot(frameIndex: 0, frameCount: 0, isPlaying: false)
        }

        let frameIndex = currentFrame()
        if isPlayerRunning, frameIndex >= decodedAudioBuffer.frameCount {
            finishAtEnd()
        }

        return Snapshot(
            frameIndex: min(frameIndex, decodedAudioBuffer.frameCount),
            frameCount: decodedAudioBuffer.frameCount,
            isPlaying: isPlayerRunning
        )
    }

    private func currentFrame() -> Int {
        guard let decodedAudioBuffer else {
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
        return min(scheduledStartFrame + elapsedFrames, decodedAudioBuffer.frameCount)
    }

    private func finishAtEnd() {
        playerNode.stop()
        scheduledPlaybackBuffer = nil
        pausedFrame = decodedAudioBuffer?.frameCount ?? 0
        isPlayerRunning = false
    }

    private func stopEnginePlayback() {
        playbackGeneration += 1
        playerNode.stop()
        scheduledPlaybackBuffer = nil
        isPlayerRunning = false
        pausedFrame = 0
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
