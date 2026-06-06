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
        guard sampleRate > 0, preparedTracks.allSatisfy({ $0.source.sampleRate > 0 }) else {
            throw PlaybackError.invalidFormat
        }

        let didLoad = core.setPreparedTracks(realtimeTracks(from: preparedTracks))
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
        let preparedTracks = try tracks.map { track in
            try preparedProjectTrack(from: track)
        }

        let sampleRate = preparedTracks[0].source.sampleRate
        guard sampleRate > 0, preparedTracks.allSatisfy({ $0.source.sampleRate > 0 }) else {
            throw PlaybackError.invalidFormat
        }

        if abs(sampleRate - self.sampleRate) > 0.000_001 {
            let previousProgress = previousSnapshot.progress
            let shouldResume = previousSnapshot.isPlaying
            try loadProjectTracks(tracks)
            try seek(toProgress: previousProgress)
            if shouldResume {
                try play()
            }
            return
        }

        let didPublish = core.updatePreparedTracks(realtimeTracks(from: preparedTracks))
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
        guard sourceLoaded, sampleRate > 0 else {
            return
        }

        let shouldResume = isPlaying
        if shouldResume {
            outputDevice.stop()
        }

        try configureOutputDevice(sampleRate: sampleRate)

        if shouldResume {
            try outputDevice.start()
        }
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
            atFrame: projectedFrameIndex(
                from: detailedSnapshot,
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

        let didPublish = core.updatePreparedTracks(realtimeTracks(from: updatedPreparedTracks))
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

        let elapsedTime = timestamp - baseHostTimestamp
        let elapsedFrames = Int((elapsedTime * sampleRate).rounded(.towardZero))
        return min(max(baseFrameIndex + elapsedFrames, 0), frameCount)
    }

    private func configureOutputDevice(sampleRate: Double) throws {
        guard let corePointer = core.enginePointer else {
            throw PlaybackError.invalidFormat
        }

        try outputDevice.configure(corePointer: corePointer, sampleRate: sampleRate)
    }

    private func realtimeTracks(from preparedTracks: [PreparedProjectTrack]) -> [PreparedRealtimeAudioTrack] {
        preparedTracks.map { preparedTrack in
            PreparedRealtimeAudioTrack(
                source: preparedTrack.source,
                gain: effectiveTrackGain(preparedTrack, in: preparedTracks),
                segments: preparedTrack.segments
            )
        }
    }

    private func preparedProjectTrack(from track: ProjectPlaybackTrack) throws -> PreparedProjectTrack {
        let preparedSource: PreparedRealtimeAudioSource
        let segments: [PreparedRealtimeAudioSegment]
        let zeroCrossingIndex: AudioZeroCrossingIndex?
        let zeroCrossingProbe: WAVZeroCrossingProbe?
        let stableSourceIdentity = sourceIdentity(for: track.source)

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
                segments = existingPreparedTrack.segments
                zeroCrossingIndex = sourceZeroCrossingIndex
                zeroCrossingProbe = nil
                break
            }

            guard let source = PreparedRealtimeAudioSource.make(from: decodedAudioBuffer) else {
                throw PlaybackError.invalidFormat
            }
            preparedSource = source
            segments = []
            zeroCrossingIndex = sourceZeroCrossingIndex
            zeroCrossingProbe = nil
        case let .file(url, sourceZeroCrossingProbe):
            if let existingPreparedTrack = preparedProjectTracks.first(where: { existingTrack in
                existingTrack.id == track.id &&
                    existingTrack.sourceIdentity == stableSourceIdentity &&
                    existingTrack.source.frameCount > 0
            }) {
                preparedSource = existingPreparedTrack.source
                segments = []
                zeroCrossingIndex = nil
                zeroCrossingProbe = sourceZeroCrossingProbe
                break
            }

            guard let source = try PreparedRealtimeAudioSource.makeMappedWAV(url: url) else {
                throw PlaybackError.invalidFormat
            }
            preparedSource = source
            segments = []
            zeroCrossingIndex = nil
            zeroCrossingProbe = sourceZeroCrossingProbe
        case let .fileTimeline(url, audioFileTimeline, sourceZeroCrossingProbe):
            if let existingPreparedTrack = preparedProjectTracks.first(where: { existingTrack in
                existingTrack.id == track.id &&
                    existingTrack.sourceIdentity == stableSourceIdentity &&
                    existingTrack.source.frameCount > 0
            }) {
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
            zeroCrossingIndex = nil
            zeroCrossingProbe = sourceZeroCrossingProbe
        case let .timeline(audioTimeline, sourceZeroCrossingIndex):
            let sourceBuffer = audioTimeline.sourceAudioBuffer
            if let existingPreparedTrack = preparedProjectTracks.first(where: { existingTrack in
                existingTrack.id == track.id &&
                    existingTrack.sourceIdentity == stableSourceIdentity &&
                    existingTrack.source.frameCount == sourceBuffer.frameCount &&
                    existingTrack.source.channelCount == sourceBuffer.channelCount &&
                    existingTrack.source.sampleRate == sourceBuffer.sampleRate
            }) {
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
            zeroCrossingIndex: zeroCrossingIndex,
            zeroCrossingProbe: zeroCrossingProbe,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed
        )
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
        in tracks: [PreparedProjectTrack]
    ) -> Float {
        let anySoloedTrack = tracks.contains { $0.isSoloed }
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
            let segmentedFrameCount = track.segments.reduce(0) { result, segment in
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
                return track.segments.contains { segment in
                    projectFrame >= segment.outputStartFrame &&
                        projectFrame < segment.outputStartFrame + segment.frameCount
                }
            }

            let sourceFrame = Int((projectTime * track.source.sampleRate).rounded(.down))
            return sourceFrame > 0 && sourceFrame < track.source.frameCount
        }
    }

    private func sourceFrame(
        forProjectFrame projectFrame: Int,
        in track: PreparedProjectTrack
    ) -> Int {
        if
            let segment = track.segments.first(where: { segment in
                projectFrame >= segment.outputStartFrame &&
                    projectFrame < segment.outputStartFrame + segment.frameCount
            })
        {
            let offset = max(projectFrame - segment.outputStartFrame, 0)
            let sourceFrame = segment.sourceStartFrame + Int((Double(offset) * segment.sourceFrameScale).rounded(.down))
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
        if
            let segment = track.segments.first(where: { segment in
                sourceFrame >= segment.sourceStartFrame &&
                    sourceFrame < segment.sourceStartFrame +
                    Int((Double(segment.frameCount) * segment.sourceFrameScale).rounded(.up)) &&
                    nearProjectFrame >= segment.outputStartFrame &&
                    nearProjectFrame < segment.outputStartFrame + segment.frameCount
            })
        {
            let sourceOffset = max(sourceFrame - segment.sourceStartFrame, 0)
            let sourceFrameScale = max(segment.sourceFrameScale, .leastNonzeroMagnitude)
            let outputOffset = Int((Double(sourceOffset) / sourceFrameScale).rounded(.down))
            return segment.outputStartFrame + outputOffset
        }

        let snappedProjectTime = TimeInterval(sourceFrame) / track.source.sampleRate
        return Int((snappedProjectTime * sampleRate).rounded(.down))
    }

}
