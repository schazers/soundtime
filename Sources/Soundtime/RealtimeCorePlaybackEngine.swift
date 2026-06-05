import AVFoundation
import Foundation
import QuartzCore
import SoundtimeAudioCore

@MainActor
final class RealtimeCorePlaybackEngine: PlaybackEngine {
    private let core: RealtimeAudioCore
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var configuredSampleRate: Double?
    private var frameCount = 0
    private var sampleRate: Double = 0
    private var zeroCrossingIndex: AudioZeroCrossingIndex?
    private var zeroCrossingProbe: WAVZeroCrossingProbe?
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

    init?() {
        guard let core = RealtimeAudioCore() else {
            return nil
        }

        self.core = core
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
        core.setGain(masterGain)
        try configureCallbackGraph(sampleRate: preparedSource.sampleRate)
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
        sourceLoaded = false
        core.setGain(masterGain)
        try configureCallbackGraph(sampleRate: fileInfo.sampleRate)
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
        sourceLoaded = false
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

        if !engine.isRunning {
            try engine.start()
        }

        let detailedSnapshot = core.detailedSnapshot()
        if mirroredFrameIndex >= frameCount {
            mirroredFrameIndex = 0
        }
        mirroredFrameCount = frameCount
        mirroredIsPlaying = true
        mirroredHostTimestamp = CACurrentMediaTime()
        pendingCommandRenderedFrameCount = detailedSnapshot.renderedFrameCount
        core.play()
    }

    func pause() {
        let detailedSnapshot = core.detailedSnapshot()
        mirroredFrameIndex = min(max(detailedSnapshot.frameIndex, 0), frameCount)
        mirroredFrameCount = frameCount
        mirroredIsPlaying = false
        mirroredHostTimestamp = detailedSnapshot.hostTimestamp > 0 ?
            detailedSnapshot.hostTimestamp :
            CACurrentMediaTime()
        pendingCommandRenderedFrameCount = detailedSnapshot.renderedFrameCount
        core.pause()
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

    func snapshot() -> PlaybackSnapshot {
        let detailedSnapshot = core.detailedSnapshot()
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
        mirroredFrameIndex = detailedSnapshot.frameIndex
        mirroredFrameCount = detailedSnapshot.frameCount
        mirroredIsPlaying = detailedSnapshot.isPlaying
        mirroredHostTimestamp = detailedSnapshot.hostTimestamp
        return detailedSnapshot.playbackSnapshot
    }

    private func configureCallbackGraph(sampleRate: Double) throws {
        guard sampleRate > 0 else {
            throw PlaybackError.invalidFormat
        }
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 2,
                interleaved: false
            )
        else {
            throw PlaybackError.invalidFormat
        }

        if sourceNode == nil {
            guard let corePointer = core.enginePointer else {
                throw PlaybackError.invalidFormat
            }

            let sourceNode = AVAudioSourceNode { _, timestamp, frameCount, audioBufferList in
                let hostTimestamp = AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime)
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                let leftOutput = buffers.count > 0 ?
                    buffers[0].mData?.assumingMemoryBound(to: Float.self) :
                    nil
                let rightOutput = buffers.count > 1 ?
                    buffers[1].mData?.assumingMemoryBound(to: Float.self) :
                    nil
                var outputPointers = (leftOutput, rightOutput)

                withUnsafeMutablePointer(to: &outputPointers) { pointer in
                    pointer.withMemoryRebound(
                        to: Optional<UnsafeMutablePointer<Float>>.self,
                        capacity: 2
                    ) { outputs in
                        soundtime_audio_core_render_at_host_time(
                            corePointer,
                            outputs,
                            2,
                            frameCount,
                            hostTimestamp
                        )
                    }
                }

                return noErr
            }

            engine.attach(sourceNode)
            self.sourceNode = sourceNode
        }

        if configuredSampleRate != sampleRate {
            engine.stop()
            if let sourceNode {
                engine.disconnectNodeOutput(sourceNode)
                engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
            }
            configuredSampleRate = sampleRate
        }

        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
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
