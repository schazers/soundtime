import Foundation
import QuartzCore

@MainActor
final class RealtimeCorePlaybackEngine: PlaybackEngine {
    private struct PreparedProjectTrack {
        let id: UUID
        let sourceRevision: Int
        let sourceIdentity: String?
        let sourceID: UUID?
        let source: PreparedRealtimeAudioSource
        let segments: [PreparedRealtimeAudioSegment]
        let segmentTimelineSampleRate: Double
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
    private var latestClockSample: RealtimeAudioClockSample?
    private var previousClockRenderedFrameCount: Int?
    private var clockProjectionFrameLimit = 0

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
        self.core.setTrackGainRampDuration(0.006)
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
        resetClockMirror()
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
        resetClockMirror()
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

        let preparedTracks = try prepareProjectTracks(tracks)

        let sampleRate = preparedTracks[0].source.sampleRate
        guard sampleRate > 0, preparedTracks.allSatisfy({ $0.source.sampleRate > 0 }) else {
            throw PlaybackError.invalidFormat
        }

        let didLoad = core.setPreparedTracks(
            realtimeTracks(from: preparedTracks, projectSampleRate: sampleRate),
            sampleRate: sampleRate
        )
        guard didLoad else {
            throw PlaybackError.invalidFormat
        }

        frameCount = projectFrameCount(for: preparedTracks, sampleRate: sampleRate)
        self.sampleRate = sampleRate
        mirroredFrameIndex = 0
        mirroredFrameCount = frameCount
        mirroredIsPlaying = false
        mirroredHostTimestamp = CACurrentMediaTime()
        pendingCommandRenderedFrameCount = nil
        resetClockMirror()
        preparedProjectTracks = preparedTracks
        let referenceTrack = zeroCrossingReferenceTrack(in: preparedTracks)
        zeroCrossingIndex = referenceTrack?.zeroCrossingIndex
        zeroCrossingProbe = referenceTrack?.zeroCrossingProbe
        sourceLoaded = true
        core.setGain(masterGain)
        try configureOutputDevice(sampleRate: sampleRate)
    }

    func updateProjectTracks(_ tracks: [ProjectPlaybackTrack]) throws {
        guard !tracks.isEmpty else {
            clear()
            return
        }

        guard !preparedProjectTracks.isEmpty, sourceLoaded else {
            try loadProjectTracks(tracks)
            return
        }

        let previousSnapshot = snapshot()
        let preparedTracks = try prepareProjectTracks(tracks)

        let sampleRate = preparedTracks[0].source.sampleRate
        guard sampleRate > 0, preparedTracks.allSatisfy({ $0.source.sampleRate > 0 }) else {
            throw PlaybackError.invalidFormat
        }

        if abs(sampleRate - self.sampleRate) > 0.000_001 {
            let shouldResume = previousSnapshot.isPlaying
            try loadProjectTracks(tracks)
            let updatedSnapshot = snapshot()
            try seekExactly(
                toProgress: updatedSnapshot.progressPreservingProjectTime(
                    from: previousSnapshot
                )
            )
            if shouldResume {
                try play()
            }
            return
        }

        let didPublish = core.updatePreparedTracks(
            realtimeTracks(from: preparedTracks, projectSampleRate: sampleRate)
        )
        guard didPublish else {
            throw PlaybackError.invalidFormat
        }

        frameCount = projectFrameCount(for: preparedTracks, sampleRate: sampleRate)
        self.sampleRate = sampleRate
        mirroredFrameIndex = min(max(mirroredFrameIndex, 0), frameCount)
        mirroredFrameCount = frameCount
        preparedProjectTracks = preparedTracks
        let referenceTrack = zeroCrossingReferenceTrack(in: preparedTracks)
        zeroCrossingIndex = referenceTrack?.zeroCrossingIndex
        zeroCrossingProbe = referenceTrack?.zeroCrossingProbe
        sourceLoaded = true
        core.setGain(masterGain)
    }

    func refreshOutputDevice() throws {
        guard hasSource, sampleRate > 0 else {
            return
        }

        let shouldResume = isPlaying
        if shouldResume {
            outputDevice.stop()
        }

        outputDevice.invalidateConfiguration()
        try configureOutputDevice(sampleRate: sampleRate)

        if shouldResume {
            try outputDevice.start()
        }
    }

    func warmOutputForLowLatencyPlayback() throws {
        guard hasSource, sampleRate > 0 else {
            return
        }

        try configureOutputDevice(sampleRate: sampleRate)
        try outputDevice.start()
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
        try seekExactly(
            toProgress: snapshot().progressPreservingProjectTime(
                from: previousSnapshot
            )
        )

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
        resetClockMirror()
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
        do {
            try outputDevice.start()
        } catch {
            mirroredIsPlaying = false
            core.pause(atFrame: mirroredFrameIndex)
            throw error
        }
    }

    func pause() {
        let pauseTimestamp = CACurrentMediaTime()
        let detailedSnapshot = core.detailedSnapshot()
        pause(
            atFrame: currentProjectedFrameIndex(
                detailedSnapshot: detailedSnapshot,
                at: pauseTimestamp
            ),
            detailedSnapshot: detailedSnapshot,
            timestamp: pauseTimestamp
        )
    }

    func pause(atProgress progress: Float) {
        let pauseTimestamp = CACurrentMediaTime()
        let targetFrame = frameIndex(forProgress: progress)
        pause(
            atFrame: targetFrame,
            detailedSnapshot: core.detailedSnapshot(),
            timestamp: pauseTimestamp
        )
    }

    private func pause(
        atFrame frameIndex: Int,
        detailedSnapshot: RealtimeAudioCoreSnapshot,
        timestamp: TimeInterval
    ) {
        mirroredFrameIndex = min(max(frameIndex, 0), frameCount)
        mirroredFrameCount = frameCount
        mirroredIsPlaying = false
        mirroredHostTimestamp = timestamp
        pendingCommandRenderedFrameCount = detailedSnapshot.renderedFrameCount
        core.pause(atFrame: mirroredFrameIndex)
    }

    private func frameIndex(forProgress progress: Float) -> Int {
        let clampedProgress = min(max(progress, 0), 1)
        return min(
            max(Int((clampedProgress * Float(frameCount)).rounded(.down)), 0),
            frameCount
        )
    }

    private func snappedFrameIndex(forProgress progress: Float, snapsToZeroCrossing: Bool) -> Int {
        let targetFrame = frameIndex(forProgress: progress)
        return snapsToZeroCrossing ?
            snappedFrameToZeroCrossing(
                targetFrame,
                allowsEnd: targetFrame >= frameCount
            ) :
            targetFrame
    }

    func seek(toProgress progress: Float) throws {
        guard hasSource else {
            throw PlaybackError.noAudioLoaded
        }

        try seek(toProgress: progress, snapsToZeroCrossing: true)
    }

    func seekExactly(toProgress progress: Float) throws {
        guard hasSource else {
            throw PlaybackError.noAudioLoaded
        }

        try seek(toProgress: progress, snapsToZeroCrossing: false)
    }

    private func seek(toProgress progress: Float, snapsToZeroCrossing: Bool) throws {
        let snappedTargetFrame = snappedFrameIndex(
            forProgress: progress,
            snapsToZeroCrossing: snapsToZeroCrossing
        )
        let detailedSnapshot = core.detailedSnapshot()
        mirroredFrameIndex = snappedTargetFrame
        mirroredFrameCount = frameCount
        mirroredHostTimestamp = CACurrentMediaTime()
        pendingCommandRenderedFrameCount = detailedSnapshot.renderedFrameCount
        core.seek(toFrame: snappedTargetFrame)
    }

    func updateProjectTrackMix(_ tracks: [ProjectPlaybackTrackMix]) {
        guard !preparedProjectTracks.isEmpty else {
            return
        }

        var updatedPreparedTracks = preparedProjectTracks
        let indicesByID = Dictionary(uniqueKeysWithValues: updatedPreparedTracks.enumerated().map { index, track in
            (track.id, index)
        })
        for track in tracks {
            guard let preparedTrackIndex = indicesByID[track.id] else {
                continue
            }

            updatedPreparedTracks[preparedTrackIndex].volume = track.volume
            updatedPreparedTracks[preparedTrackIndex].isMuted = track.isMuted
            updatedPreparedTracks[preparedTrackIndex].isSoloed = track.isSoloed
        }

        let didPublish = core.updatePreparedTracks(
            realtimeTracks(from: updatedPreparedTracks, projectSampleRate: sampleRate)
        )
        if didPublish {
            preparedProjectTracks = updatedPreparedTracks
        }
    }

    func snapshot() -> PlaybackSnapshot {
        let detailedSnapshot = core.detailedSnapshot()
        SoundtimeDiagnostics.shared.recordAudioCoreSnapshot(detailedSnapshot)
        let snapshotTimestamp = CACurrentMediaTime()
        let clockSample = consumeLatestClockSample()
        if
            let pendingCommandRenderedFrameCount,
            !hasCoreReachedPendingCommand(
                clockSample: clockSample,
                detailedSnapshot: detailedSnapshot,
                pendingCommandRenderedFrameCount: pendingCommandRenderedFrameCount
            )
        {
            return PlaybackSnapshot(
                frameIndex: mirroredFrameIndex,
                frameCount: mirroredFrameCount,
                sampleRate: sampleRate,
                isPlaying: mirroredIsPlaying,
                hostTimestamp: mirroredHostTimestamp
            )
        }

        pendingCommandRenderedFrameCount = nil
        mirroredFrameCount = frameCount
        let clockIsCurrent = clockSample.map {
            $0.renderedFrameCount >= detailedSnapshot.renderedFrameCount
        } ?? false
        if let clockSample, clockIsCurrent {
            mirroredIsPlaying = clockSample.isPlaying
            mirroredFrameIndex = projectedFrameIndex(
                baseFrameIndex: clockSample.frameIndex,
                baseHostTimestamp: clockSample.hostTimestamp,
                isPlaying: clockSample.isPlaying,
                at: snapshotTimestamp
            )
        } else {
            mirroredIsPlaying = detailedSnapshot.isPlaying
            mirroredFrameIndex = projectedFrameIndex(
                baseFrameIndex: detailedSnapshot.frameIndex,
                baseHostTimestamp: detailedSnapshot.hostTimestamp,
                isPlaying: detailedSnapshot.isPlaying,
                at: snapshotTimestamp
            )
        }
        if mirroredIsPlaying {
            mirroredHostTimestamp = snapshotTimestamp
        } else {
            mirroredHostTimestamp = clockSample?.hostTimestamp ??
                detailedSnapshot.hostTimestamp
        }

        return PlaybackSnapshot(
            frameIndex: mirroredFrameIndex,
            frameCount: mirroredFrameCount,
            sampleRate: sampleRate,
            isPlaying: mirroredIsPlaying,
            hostTimestamp: mirroredHostTimestamp
        )
    }

    func realtimeSnapshotForSafetySmoke() -> RealtimeAudioCoreSnapshot {
        core.detailedSnapshot()
    }

    private func hasCoreReachedPendingCommand(
        clockSample: RealtimeAudioClockSample?,
        detailedSnapshot: RealtimeAudioCoreSnapshot,
        pendingCommandRenderedFrameCount: Int
    ) -> Bool {
        if
            let clockSample,
            clockSample.renderedFrameCount > pendingCommandRenderedFrameCount
        {
            if mirroredIsPlaying {
                return clockSample.isPlaying
            }

            return !clockSample.isPlaying &&
                abs(clockSample.frameIndex - mirroredFrameIndex) <= 1
        }

        guard detailedSnapshot.renderedFrameCount > pendingCommandRenderedFrameCount else {
            return false
        }

        if mirroredIsPlaying {
            return detailedSnapshot.isPlaying
        }

        return !detailedSnapshot.isPlaying &&
            abs(detailedSnapshot.frameIndex - mirroredFrameIndex) <= 1
    }

    func drainMeterSamples() -> [PlaybackMeterSample] {
        var latestSample: PlaybackMeterSample?

        while let sample = core.popMeterSample() {
            latestSample = sample.playbackMeterSample
        }

        if let latestSample {
            return [latestSample]
        }

        return []
    }

    private func currentProjectedFrameIndex(
        detailedSnapshot: RealtimeAudioCoreSnapshot,
        at timestamp: TimeInterval
    ) -> Int {
        let clockSample = consumeLatestClockSample()
        if
            let pendingCommandRenderedFrameCount,
            detailedSnapshot.renderedFrameCount <= pendingCommandRenderedFrameCount
        {
            return projectedFrameIndex(
                baseFrameIndex: mirroredFrameIndex,
                baseHostTimestamp: mirroredHostTimestamp,
                isPlaying: mirroredIsPlaying,
                at: timestamp
            )
        }

        if let clockSample {
            return projectedFrameIndex(
                baseFrameIndex: clockSample.frameIndex,
                baseHostTimestamp: clockSample.hostTimestamp,
                isPlaying: clockSample.isPlaying,
                at: timestamp
            )
        }

        return projectedFrameIndex(
            baseFrameIndex: detailedSnapshot.frameIndex,
            baseHostTimestamp: detailedSnapshot.hostTimestamp,
            isPlaying: detailedSnapshot.isPlaying,
            at: timestamp
        )
    }

    private func projectedFrameIndex(
        baseFrameIndex: Int,
        baseHostTimestamp: TimeInterval,
        isPlaying: Bool,
        at timestamp: TimeInterval
    ) -> Int {
        guard
            isPlaying,
            sampleRate.isFinite,
            sampleRate > 0,
            baseHostTimestamp > 0
        else {
            return min(max(baseFrameIndex, 0), frameCount)
        }

        let elapsedTime = timestamp - baseHostTimestamp
        let unboundedElapsedFrames = Int(
            (elapsedTime * sampleRate).rounded(.towardZero)
        )
        let elapsedFrames: Int
        if clockProjectionFrameLimit > 0 {
            elapsedFrames = min(
                max(unboundedElapsedFrames, -clockProjectionFrameLimit),
                clockProjectionFrameLimit
            )
        } else {
            elapsedFrames = 0
        }
        return min(max(baseFrameIndex + elapsedFrames, 0), frameCount)
    }

    private func consumeLatestClockSample() -> RealtimeAudioClockSample? {
        var newestSample = latestClockSample
        while let sample = core.popClockSample() {
            let previousRenderedFrameCount = previousClockRenderedFrameCount ??
                pendingCommandRenderedFrameCount
            if
                let previousRenderedFrameCount,
                sample.renderedFrameCount > previousRenderedFrameCount
            {
                clockProjectionFrameLimit = max(
                    sample.renderedFrameCount - previousRenderedFrameCount,
                    1
                )
            }
            previousClockRenderedFrameCount = sample.renderedFrameCount
            newestSample = sample
        }
        latestClockSample = newestSample
        return newestSample
    }

    private func resetClockMirror() {
        latestClockSample = nil
        previousClockRenderedFrameCount = nil
        clockProjectionFrameLimit = 0
        while core.popClockSample() != nil {}
    }

    private func configureOutputDevice(sampleRate: Double) throws {
        guard let corePointer = core.enginePointer else {
            throw PlaybackError.invalidFormat
        }

        try outputDevice.configure(corePointer: corePointer, sampleRate: sampleRate)
    }

    private func realtimeTracks(
        from preparedTracks: [PreparedProjectTrack],
        projectSampleRate: Double
    ) -> [PreparedRealtimeAudioTrack] {
        let anySoloedTrack = preparedTracks.contains { $0.isSoloed }
        return preparedTracks.map { preparedTrack in
            PreparedRealtimeAudioTrack(
                source: preparedTrack.source,
                gain: effectiveTrackGain(preparedTrack, anySoloedTrack: anySoloedTrack),
                segments: projectSegments(
                    for: preparedTrack,
                    projectSampleRate: projectSampleRate
                )
            )
        }
    }

    private func preparedProjectTrack(
        from track: ProjectPlaybackTrack,
        existingPreparedTrack: PreparedProjectTrack?
    ) throws -> PreparedProjectTrack {
        let preparedSource: PreparedRealtimeAudioSource
        let segments: [PreparedRealtimeAudioSegment]
        let segmentTimelineSampleRate: Double
        let zeroCrossingIndex: AudioZeroCrossingIndex?
        let zeroCrossingProbe: WAVZeroCrossingProbe?
        let stableSourceIdentity = sourceIdentity(for: track.source)

        switch track.source {
        case let .decoded(decodedAudioBuffer, sourceZeroCrossingIndex):
            if
                let existingPreparedTrack,
                existingPreparedTrack.sourceRevision == track.sourceRevision &&
                    existingPreparedTrack.source.frameCount == decodedAudioBuffer.frameCount &&
                    existingPreparedTrack.source.channelCount == decodedAudioBuffer.channelCount &&
                    existingPreparedTrack.source.sampleRate == decodedAudioBuffer.sampleRate
            {
                preparedSource = existingPreparedTrack.source
                segments = existingPreparedTrack.segments
                segmentTimelineSampleRate = existingPreparedTrack.segmentTimelineSampleRate
                zeroCrossingIndex = sourceZeroCrossingIndex
                zeroCrossingProbe = nil
                break
            }

            guard let source = PreparedRealtimeAudioSource.make(from: decodedAudioBuffer) else {
                throw PlaybackError.invalidFormat
            }
            preparedSource = source
            segments = []
            segmentTimelineSampleRate = source.sampleRate
            zeroCrossingIndex = sourceZeroCrossingIndex
            zeroCrossingProbe = nil
        case let .file(url, sourceZeroCrossingProbe):
            if
                let existingPreparedTrack,
                existingPreparedTrack.sourceIdentity == stableSourceIdentity &&
                    existingPreparedTrack.source.frameCount > 0
            {
                preparedSource = existingPreparedTrack.source
                segments = []
                segmentTimelineSampleRate = existingPreparedTrack.source.sampleRate
                zeroCrossingIndex = nil
                zeroCrossingProbe = sourceZeroCrossingProbe
                break
            }

            guard let source = try PreparedRealtimeAudioSource.makeMappedWAV(url: url) else {
                throw PlaybackError.invalidFormat
            }
            preparedSource = source
            segments = []
            segmentTimelineSampleRate = source.sampleRate
            zeroCrossingIndex = nil
            zeroCrossingProbe = sourceZeroCrossingProbe
        case let .fileTimeline(url, audioFileTimeline, sourceZeroCrossingProbe):
            if
                let existingPreparedTrack,
                existingPreparedTrack.sourceIdentity == stableSourceIdentity &&
                    existingPreparedTrack.source.frameCount > 0
            {
                preparedSource = existingPreparedTrack.source
            } else {
                guard let source = try PreparedRealtimeAudioSource.makeMappedWAV(url: url) else {
                    throw PlaybackError.invalidFormat
                }
                preparedSource = source
            }
            segments = audioFileTimeline.playbackSegments.map { segment in
                PreparedRealtimeAudioSegment(
                    outputStartFrame: segment.outputStartFrame,
                    sourceStartFrame: segment.sourceStartFrame,
                    frameCount: segment.frameCount,
                    sourceFrameScale: segment.sourceFrameScale,
                    gainStart: segment.gainStart,
                    gainEnd: segment.gainEnd
                )
            }
            segmentTimelineSampleRate = audioFileTimeline.sourceSampleRate
            zeroCrossingIndex = nil
            zeroCrossingProbe = sourceZeroCrossingProbe
        case let .timeline(audioTimeline, sourceZeroCrossingIndex):
            let sourceBuffer = audioTimeline.sourceAudioBuffer
            if
                let existingPreparedTrack,
                existingPreparedTrack.sourceIdentity == stableSourceIdentity &&
                    existingPreparedTrack.source.frameCount == sourceBuffer.frameCount &&
                    existingPreparedTrack.source.channelCount == sourceBuffer.channelCount &&
                    existingPreparedTrack.source.sampleRate == sourceBuffer.sampleRate
            {
                preparedSource = existingPreparedTrack.source
            } else {
                guard let source = PreparedRealtimeAudioSource.make(from: sourceBuffer) else {
                    throw PlaybackError.invalidFormat
                }
                preparedSource = source
            }
            segments = audioTimeline.playbackSegments.map { segment in
                PreparedRealtimeAudioSegment(
                    outputStartFrame: segment.outputStartFrame,
                    sourceStartFrame: segment.sourceStartFrame,
                    frameCount: segment.frameCount,
                    sourceFrameScale: segment.sourceFrameScale,
                    gainStart: segment.gainStart,
                    gainEnd: segment.gainEnd
                )
            }
            segmentTimelineSampleRate = sourceBuffer.sampleRate
            zeroCrossingIndex = sourceZeroCrossingIndex
            zeroCrossingProbe = nil
        }

        return PreparedProjectTrack(
            id: track.id,
            sourceRevision: track.sourceRevision,
            sourceIdentity: stableSourceIdentity,
            sourceID: sourceID(for: track.source),
            source: preparedSource,
            segments: segments,
            segmentTimelineSampleRate: segmentTimelineSampleRate,
            zeroCrossingIndex: zeroCrossingIndex,
            zeroCrossingProbe: zeroCrossingProbe,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed
        )
    }

    private func canReusePreparedArrangement(
        _ preparedTrack: PreparedProjectTrack,
        for track: ProjectPlaybackTrack
    ) -> Bool {
        guard
            preparedTrack.id == track.id,
            preparedTrack.sourceRevision == track.sourceRevision
        else {
            return false
        }

        switch track.source {
        case let .decoded(buffer, _):
            return preparedTrack.sourceIdentity == nil &&
                preparedTrack.sourceID == nil &&
                preparedTrack.source.frameCount == buffer.frameCount &&
                preparedTrack.source.channelCount == buffer.channelCount &&
                preparedTrack.source.sampleRate == buffer.sampleRate
        case .file, .fileTimeline:
            return preparedTrack.sourceIdentity == sourceIdentity(for: track.source)
        case let .timeline(audioTimeline, _):
            return preparedTrack.sourceID == audioTimeline.sourceID
        }
    }

    private func replacingMix(
        of preparedTrack: PreparedProjectTrack,
        with track: ProjectPlaybackTrack
    ) -> PreparedProjectTrack {
        var result = preparedTrack
        result.volume = track.volume
        result.isMuted = track.isMuted
        result.isSoloed = track.isSoloed
        return result
    }

    private func prepareProjectTracks(_ tracks: [ProjectPlaybackTrack]) throws -> [PreparedProjectTrack] {
        if
            tracks.count == preparedProjectTracks.count,
            tracks.indices.allSatisfy({ tracks[$0].id == preparedProjectTracks[$0].id })
        {
            var result: [PreparedProjectTrack] = []
            result.reserveCapacity(tracks.count)
            for index in tracks.indices {
                let track = tracks[index]
                let existingTrack = preparedProjectTracks[index]
                if canReusePreparedArrangement(existingTrack, for: track) {
                    result.append(replacingMix(of: existingTrack, with: track))
                } else {
                    result.append(try preparedProjectTrack(
                        from: track,
                        existingPreparedTrack: existingTrack
                    ))
                }
            }
            return result
        }

        let existingTracksByID = Dictionary(uniqueKeysWithValues: preparedProjectTracks.map { ($0.id, $0) })
        var reusableTracksBySourceIdentity: [String: PreparedProjectTrack] = [:]
        reusableTracksBySourceIdentity.reserveCapacity(preparedProjectTracks.count + tracks.count)
        for preparedTrack in preparedProjectTracks {
            if let sourceIdentity = preparedTrack.sourceIdentity {
                reusableTracksBySourceIdentity[sourceIdentity] = preparedTrack
            }
        }

        var preparedTracks: [PreparedProjectTrack] = []
        preparedTracks.reserveCapacity(tracks.count)
        for track in tracks {
            let stableSourceIdentity = sourceIdentity(for: track.source)
            let reusablePreparedTrack = existingTracksByID[track.id] ??
                stableSourceIdentity.flatMap { reusableTracksBySourceIdentity[$0] }
            let preparedTrack = try preparedProjectTrack(
                from: track,
                existingPreparedTrack: reusablePreparedTrack
            )
            preparedTracks.append(preparedTrack)
            if let sourceIdentity = preparedTrack.sourceIdentity {
                reusableTracksBySourceIdentity[sourceIdentity] = preparedTrack
            }
        }

        return preparedTracks
    }

    private func sourceIdentity(for source: ProjectPlaybackTrack.Source) -> String? {
        switch source {
        case .decoded:
            return nil
        case let .file(url, _), let .fileTimeline(url, _, _):
            return "file:\(url.standardizedFileURL.path)"
        case let .timeline(audioTimeline, _):
            return "timeline:\(audioTimeline.sourceID.uuidString)"
        }
    }

    private func sourceID(for source: ProjectPlaybackTrack.Source) -> UUID? {
        if case let .timeline(audioTimeline, _) = source {
            return audioTimeline.sourceID
        }
        return nil
    }

    private func effectiveTrackGain(
        _ track: PreparedProjectTrack,
        anySoloedTrack: Bool
    ) -> Float {
        guard isTrackAudible(track, anySoloedTrack: anySoloedTrack) else {
            return 0
        }

        let clampedVolume = min(max(track.volume, 0), 1)
        return clampedVolume * clampedVolume
    }

    private func projectFrameCount(
        for tracks: [PreparedProjectTrack],
        sampleRate: Double
    ) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return 0
        }

        let duration = tracks.reduce(0.0) { longestDuration, track in
            let projectSegments = projectSegments(
                for: track,
                projectSampleRate: sampleRate
            )
            let segmentedFrameCount = projectSegments.reduce(0) { result, segment in
                max(result, segment.outputStartFrame + segment.frameCount)
            }
            if segmentedFrameCount > 0 {
                return max(longestDuration, Double(segmentedFrameCount) / sampleRate)
            }

            guard track.source.sampleRate.isFinite, track.source.sampleRate > 0 else {
                return longestDuration
            }

            return max(longestDuration, Double(track.source.frameCount) / track.source.sampleRate)
        }

        guard duration.isFinite, duration > 0 else {
            return 0
        }

        return Int((duration * sampleRate).rounded(.up))
    }

    private func zeroCrossingReferenceTrack(in tracks: [PreparedProjectTrack]) -> PreparedProjectTrack? {
        let anySoloedTrack = tracks.contains { $0.isSoloed }
        return tracks.first { track in
            isTrackAudible(track, anySoloedTrack: anySoloedTrack)
        } ?? tracks.first
    }

    private func isTrackAudible(
        _ track: PreparedProjectTrack,
        anySoloedTrack: Bool
    ) -> Bool {
        anySoloedTrack ? track.isSoloed : !track.isMuted
    }

    private func snappedFrameToZeroCrossing(
        _ frame: Int,
        allowsEnd: Bool
    ) -> Int {
        if !preparedProjectTracks.isEmpty {
            return snappedProjectFrameToZeroCrossing(frame, allowsEnd: allowsEnd)
        }

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

    private func snappedProjectFrameToZeroCrossing(
        _ frame: Int,
        allowsEnd: Bool
    ) -> Int {
        let clampedFrame = min(max(frame, 0), frameCount)
        guard clampedFrame > 0, clampedFrame < frameCount else {
            return clampedFrame
        }

        guard let referenceTrack = zeroCrossingReferenceTrack(containingProjectFrame: clampedFrame) else {
            return clampedFrame
        }

        let sourceFrame = sourceFrame(forProjectFrame: clampedFrame, in: referenceTrack)
        guard sourceFrame > 0, sourceFrame < referenceTrack.source.frameCount else {
            return clampedFrame
        }

        let snappedSourceFrame: Int
        if
            let zeroCrossingIndex = referenceTrack.zeroCrossingIndex,
            zeroCrossingIndex.frameCount == referenceTrack.source.frameCount
        {
            snappedSourceFrame = zeroCrossingIndex.nearestFrame(to: sourceFrame)
        } else if let zeroCrossingProbe = referenceTrack.zeroCrossingProbe {
            snappedSourceFrame = zeroCrossingProbe.nearestFrame(to: sourceFrame)
        } else {
            snappedSourceFrame = sourceFrame
        }

        let snappedProjectFrame = projectFrame(
            forSourceFrame: snappedSourceFrame,
            nearProjectFrame: clampedFrame,
            in: referenceTrack
        )
        let boundedFrame = min(max(snappedProjectFrame, 0), frameCount)
        if !allowsEnd, boundedFrame >= frameCount {
            return max(frameCount - 1, 0)
        }

        return boundedFrame
    }

    private func zeroCrossingReferenceTrack(containingProjectFrame projectFrame: Int) -> PreparedProjectTrack? {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return nil
        }

        let projectTime = TimeInterval(projectFrame) / sampleRate
        let anySoloedTrack = preparedProjectTracks.contains { $0.isSoloed }
        return preparedProjectTracks.first { track in
            guard isTrackAudible(track, anySoloedTrack: anySoloedTrack) else {
                return false
            }

            if !track.segments.isEmpty {
                return segment(containingProjectFrame: projectFrame, in: track) != nil
            }

            let sourceFrame = Int((projectTime * track.source.sampleRate).rounded(.down))
            return sourceFrame > 0 && sourceFrame < track.source.frameCount
        }
    }

    private func sourceFrame(
        forProjectFrame projectFrame: Int,
        in track: PreparedProjectTrack
    ) -> Int {
        if let segment = segment(containingProjectFrame: projectFrame, in: track) {
            let offset = max(projectFrame - segment.outputStartFrame, 0)
            let sourceFrameScale = effectiveSourceFrameScale(for: track, segment: segment)
            let sourceFrame = segment.sourceStartFrame + Int((Double(offset) * sourceFrameScale).rounded(.down))
            return min(max(sourceFrame, 0), track.source.frameCount)
        }

        let projectTime = TimeInterval(projectFrame) / sampleRate
        return min(
            max(Int((projectTime * track.source.sampleRate).rounded(.down)), 0),
            track.source.frameCount
        )
    }

    private func projectFrame(
        forSourceFrame sourceFrame: Int,
        nearProjectFrame: Int,
        in track: PreparedProjectTrack
    ) -> Int {
        if let segment = segment(containingProjectFrame: nearProjectFrame, in: track) {
            let sourceFrameScale = effectiveSourceFrameScale(for: track, segment: segment)
            guard
                sourceFrame >= segment.sourceStartFrame,
                sourceFrame < segment.sourceStartFrame +
                    Int((Double(segment.frameCount) * sourceFrameScale).rounded(.up))
            else {
                return nearProjectFrame
            }

            let sourceOffset = max(sourceFrame - segment.sourceStartFrame, 0)
            let boundedSourceFrameScale = max(sourceFrameScale, .leastNonzeroMagnitude)
            let outputOffset = Int((Double(sourceOffset) / boundedSourceFrameScale).rounded(.down))
            return segment.outputStartFrame + outputOffset
        }

        let snappedProjectTime = TimeInterval(sourceFrame) / track.source.sampleRate
        return Int((snappedProjectTime * sampleRate).rounded(.down))
    }

    private func segment(
        containingProjectFrame projectFrame: Int,
        in track: PreparedProjectTrack
    ) -> PreparedRealtimeAudioSegment? {
        let segments = projectSegments(
            for: track,
            projectSampleRate: sampleRate
        )
        var lowerBound = 0
        var upperBound = segments.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            let segment = segments[middle]
            if projectFrame < segment.outputStartFrame {
                upperBound = middle
            } else if projectFrame >= segment.outputStartFrame + segment.frameCount {
                lowerBound = middle + 1
            } else {
                return segment
            }
        }

        return nil
    }

    private func projectSegments(
        for track: PreparedProjectTrack,
        projectSampleRate: Double
    ) -> [PreparedRealtimeAudioSegment] {
        guard !track.segments.isEmpty else {
            return []
        }

        return track.segments.compactMap { segment in
            let timelineSegment = AudioTimelinePlaybackSegment(
                outputStartFrame: segment.outputStartFrame,
                sourceStartFrame: segment.sourceStartFrame,
                frameCount: segment.frameCount,
                sourceFrameScale: segment.sourceFrameScale,
                gainStart: segment.gainStart,
                gainEnd: segment.gainEnd,
                startsNewClip: false
            )
            guard let projected = AudioTimelineSampleRateProjection.project(
                timelineSegment,
                timelineSampleRate: track.segmentTimelineSampleRate,
                outputSampleRate: projectSampleRate
            ) else {
                return nil
            }
            return PreparedRealtimeAudioSegment(
                outputStartFrame: projected.outputStartFrame,
                sourceStartFrame: projected.sourceStartFrame,
                frameCount: projected.frameCount,
                sourceFrameScale: projected.sourceFrameScale,
                gainStart: projected.gainStart,
                gainEnd: projected.gainEnd
            )
        }
    }

    private func effectiveSourceFrameScale(
        for track: PreparedProjectTrack,
        segment: PreparedRealtimeAudioSegment
    ) -> Double {
        if segment.sourceFrameScale > 0, segment.sourceFrameScale.isFinite {
            return segment.sourceFrameScale
        }

        guard sampleRate.isFinite, sampleRate > 0, track.source.sampleRate.isFinite else {
            return 1
        }

        return max(track.source.sampleRate / sampleRate, .leastNonzeroMagnitude)
    }

}
