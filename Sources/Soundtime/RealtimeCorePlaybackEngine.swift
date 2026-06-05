import Foundation
import QuartzCore

@MainActor
final class RealtimeCorePlaybackEngine: PlaybackEngine {
    private let core: RealtimeAudioCore
    private let outputDevice: RealtimeAudioOutputDevice
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

    init?(outputDevice: RealtimeAudioOutputDevice = AVAudioSourceNodeOutputDevice()) {
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
        sourceLoaded = false
        core.setGain(masterGain)
        try configureOutputDevice(sampleRate: fileInfo.sampleRate)
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
        core.seek(toFrame: mirroredFrameIndex)
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
