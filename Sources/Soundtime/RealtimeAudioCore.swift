import Foundation
import Darwin
import SoundtimeAudioCore

struct RealtimeAudioClockSample {
    let frameIndex: Int
    let renderedFrameCount: Int
    let hostTimestamp: TimeInterval
    let isPlaying: Bool
}

struct RealtimeAudioMeterSample {
    let startFrameIndex: Int
    let frameCount: Int
    let renderedFrameCount: Int
    let hostTimestamp: TimeInterval
    let isPlaying: Bool
    let leftRMS: Float
    let rightRMS: Float
    let leftPeak: Float
    let rightPeak: Float
    let leftClipPeak: Float
    let rightClipPeak: Float

    var playbackMeterSample: PlaybackMeterSample {
        PlaybackMeterSample(
            startFrameIndex: startFrameIndex,
            frameCount: frameCount,
            renderedFrameCount: renderedFrameCount,
            hostTimestamp: hostTimestamp,
            isPlaying: isPlaying,
            leftRMS: leftRMS,
            rightRMS: rightRMS,
            leftPeak: leftPeak,
            rightPeak: rightPeak,
            leftClipPeak: leftClipPeak,
            rightClipPeak: rightClipPeak
        )
    }
}

struct RealtimeAudioCoreSnapshot {
    let frameIndex: Int
    let frameCount: Int
    let sampleRate: Double
    let hostTimestamp: TimeInterval
    let isPlaying: Bool
    let renderedFrameCount: Int
    let underrunCount: Int
    let droppedCommandCount: Int
    let callbackCount: Int
    let lastRenderNanoseconds: Int
    let maxRenderNanoseconds: Int
    let renderDeadlineMissCount: Int

    var playbackSnapshot: PlaybackSnapshot {
        PlaybackSnapshot(
            frameIndex: frameIndex,
            frameCount: frameCount,
            isPlaying: isPlaying,
            hostTimestamp: hostTimestamp
        )
    }
}

final class PreparedRealtimeAudioSource: @unchecked Sendable {
    fileprivate let sourcePointer: OpaquePointer
    let frameCount: Int
    let channelCount: Int
    let sampleRate: Double
    private let mappedAudioFile: MappedAudioFile?

    private init(
        sourcePointer: OpaquePointer,
        frameCount: Int,
        channelCount: Int,
        sampleRate: Double,
        mappedAudioFile: MappedAudioFile? = nil
    ) {
        self.sourcePointer = sourcePointer
        self.frameCount = frameCount
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.mappedAudioFile = mappedAudioFile
    }

    deinit {
        soundtime_audio_core_source_destroy(sourcePointer)
    }

    static func make(from decodedAudioBuffer: DecodedAudioBuffer) -> PreparedRealtimeAudioSource? {
        withPlanarSamplePointers(decodedAudioBuffer.samplesByChannel) { channelPointers in
            guard
                let sourcePointer = soundtime_audio_core_source_create_planar(
                    channelPointers,
                    UInt64(max(decodedAudioBuffer.frameCount, 0)),
                    UInt32(max(decodedAudioBuffer.channelCount, 0)),
                    decodedAudioBuffer.sampleRate
                )
            else {
                return nil
            }

            return PreparedRealtimeAudioSource(
                sourcePointer: sourcePointer,
                frameCount: decodedAudioBuffer.frameCount,
                channelCount: decodedAudioBuffer.channelCount,
                sampleRate: decodedAudioBuffer.sampleRate
            )
        }
    }

    static func makeMappedWAV(url: URL) throws -> PreparedRealtimeAudioSource? {
        let fileInfo = try WAVAudioDecoder.inspect(url: url)
        guard fileInfo.supportsDecoding else {
            return nil
        }

        guard let mappedAudioFile = MappedAudioFile(url: url) else {
            return nil
        }

        let sourcePointer = soundtime_audio_core_source_create_wav_bytes(
            mappedAudioFile.pointer.assumingMemoryBound(to: UInt8.self),
            UInt64(max(mappedAudioFile.byteCount, 0)),
            UInt64(max(fileInfo.dataRange.lowerBound, 0)),
            UInt64(max(fileInfo.frameCount, 0)),
            UInt32(max(fileInfo.channelCount, 0)),
            fileInfo.sampleRate,
            UInt32(max(fileInfo.blockAlign, 0)),
            fileInfo.formatTag,
            UInt16(max(fileInfo.bitsPerSample, 0))
        )

        guard let sourcePointer else {
            return nil
        }

        return PreparedRealtimeAudioSource(
            sourcePointer: sourcePointer,
            frameCount: fileInfo.frameCount,
            channelCount: fileInfo.channelCount,
            sampleRate: fileInfo.sampleRate,
            mappedAudioFile: mappedAudioFile
        )
    }
}

struct PreparedRealtimeAudioSegment: Sendable {
    let outputStartFrame: Int
    let sourceStartFrame: Int
    let frameCount: Int
    let sourceFrameScale: Double
    let gainStart: Float
    let gainEnd: Float
}

struct PreparedRealtimeAudioTrack: Sendable {
    let source: PreparedRealtimeAudioSource
    let gain: Float
    let segments: [PreparedRealtimeAudioSegment]

    init(
        source: PreparedRealtimeAudioSource,
        gain: Float,
        segments: [PreparedRealtimeAudioSegment] = []
    ) {
        self.source = source
        self.gain = gain
        self.segments = segments
    }
}

final class RealtimeAudioCore {
    private var engine: OpaquePointer?
    private var segmentConfigScratch: [SoundtimeAudioCoreSegmentConfig] = []
    private var segmentedTrackConfigScratch: [SoundtimeAudioCoreSegmentedTrackConfig] = []

    var enginePointer: OpaquePointer? {
        engine
    }

    init?() {
        guard let engine = soundtime_audio_core_create() else {
            return nil
        }

        self.engine = engine
    }

    deinit {
        if let engine {
            soundtime_audio_core_destroy(engine)
        }
    }

    func setSourceInfo(frameCount: Int, channelCount: Int, sampleRate: Double) {
        guard let engine else {
            return
        }

        soundtime_audio_core_set_source_info(
            engine,
            UInt64(max(frameCount, 0)),
            UInt32(max(channelCount, 0)),
            sampleRate
        )
    }

    func setInterleavedSource(_ samples: [Float], frameCount: Int, channelCount: Int, sampleRate: Double) -> Bool {
        guard let engine else {
            return false
        }

        return samples.withUnsafeBufferPointer { sampleBuffer in
            soundtime_audio_core_set_interleaved_source(
                engine,
                sampleBuffer.baseAddress,
                UInt64(max(frameCount, 0)),
                UInt32(max(channelCount, 0)),
                sampleRate
            )
        }
    }

    func setPlanarSource(from decodedAudioBuffer: DecodedAudioBuffer) -> Bool {
        guard let engine else {
            return false
        }

        return withPlanarSamplePointers(decodedAudioBuffer.samplesByChannel) { channelPointers in
            soundtime_audio_core_set_planar_source(
                engine,
                channelPointers,
                UInt64(max(decodedAudioBuffer.frameCount, 0)),
                UInt32(max(decodedAudioBuffer.channelCount, 0)),
                decodedAudioBuffer.sampleRate
            )
        }
    }

    func setPreparedSource(_ preparedSource: PreparedRealtimeAudioSource) -> Bool {
        guard let engine else {
            return false
        }

        return soundtime_audio_core_set_prepared_source(
            engine,
            preparedSource.sourcePointer
        )
    }

    func setPreparedTracks(_ tracks: [PreparedRealtimeAudioTrack]) -> Bool {
        guard let engine, !tracks.isEmpty else {
            return false
        }

        return withSegmentedTrackConfigs(tracks) { trackConfigs in
            soundtime_audio_core_set_prepared_segmented_tracks(
                engine,
                trackConfigs.baseAddress,
                UInt32(trackConfigs.count)
            )
        }
    }

    func updatePreparedTracks(_ tracks: [PreparedRealtimeAudioTrack]) -> Bool {
        guard let engine, !tracks.isEmpty else {
            return false
        }

        return withSegmentedTrackConfigs(tracks) { trackConfigs in
            soundtime_audio_core_update_prepared_segmented_tracks(
                engine,
                trackConfigs.baseAddress,
                UInt32(trackConfigs.count)
            )
        }
    }

    private func withSegmentedTrackConfigs<T>(
        _ tracks: [PreparedRealtimeAudioTrack],
        _ body: (UnsafeBufferPointer<SoundtimeAudioCoreSegmentedTrackConfig>) -> T
    ) -> T {
        let totalSegmentCount = tracks.reduce(0) { result, track in
            result + track.segments.count
        }
        segmentConfigScratch.removeAll(keepingCapacity: true)
        segmentConfigScratch.reserveCapacity(totalSegmentCount)
        for track in tracks {
            for segment in track.segments {
                segmentConfigScratch.append(SoundtimeAudioCoreSegmentConfig(
                    outputStartFrame: UInt64(max(segment.outputStartFrame, 0)),
                    sourceStartFrame: UInt64(max(segment.sourceStartFrame, 0)),
                    frameCount: UInt64(max(segment.frameCount, 0)),
                    sourceFrameScale: segment.sourceFrameScale,
                    gainStart: max(segment.gainStart, 0),
                    gainEnd: max(segment.gainEnd, 0)
                ))
            }
        }

        return segmentConfigScratch.withUnsafeBufferPointer { segmentBuffer in
            var segmentOffset = 0
            segmentedTrackConfigScratch.removeAll(keepingCapacity: true)
            segmentedTrackConfigScratch.reserveCapacity(tracks.count)
            for track in tracks {
                let segmentCount = track.segments.count
                let segmentPointer = segmentCount > 0 ?
                    segmentBuffer.baseAddress?.advanced(by: segmentOffset) :
                    nil
                segmentOffset += segmentCount
                segmentedTrackConfigScratch.append(SoundtimeAudioCoreSegmentedTrackConfig(
                    source: track.source.sourcePointer,
                    segments: segmentPointer,
                    segmentCount: UInt32(max(segmentCount, 0)),
                    gain: max(track.gain, 0)
                ))
            }

            return segmentedTrackConfigScratch.withUnsafeBufferPointer(body)
        }
    }

    private func withTrackConfigs<T>(
        _ tracks: [PreparedRealtimeAudioTrack],
        _ body: (UnsafeBufferPointer<SoundtimeAudioCoreTrackConfig>) -> T
    ) -> T {
        let trackConfigs = tracks.map { track in
            SoundtimeAudioCoreTrackConfig(
                source: track.source.sourcePointer,
                gain: max(track.gain, 0)
            )
        }

        return trackConfigs.withUnsafeBufferPointer(body)
    }

    func play() {
        guard let engine else {
            return
        }

        soundtime_audio_core_play(engine)
    }

    func pause() {
        guard let engine else {
            return
        }

        soundtime_audio_core_pause(engine)
    }

    func pause(atFrame frameIndex: Int) {
        guard let engine else {
            return
        }

        soundtime_audio_core_pause_at(engine, UInt64(max(frameIndex, 0)))
    }

    func seek(toFrame frameIndex: Int) {
        guard let engine else {
            return
        }

        soundtime_audio_core_seek(engine, UInt64(max(frameIndex, 0)))
    }

    func setGain(_ gain: Float) {
        guard let engine else {
            return
        }

        soundtime_audio_core_set_gain(engine, gain)
    }

    func setTransportRampDuration(_ duration: TimeInterval) {
        guard let engine else {
            return
        }

        soundtime_audio_core_set_transport_ramp_duration(engine, max(duration, 0))
    }

    func reset() {
        guard let engine else {
            return
        }

        soundtime_audio_core_reset(engine)
    }

    func snapshot() -> PlaybackSnapshot {
        detailedSnapshot().playbackSnapshot
    }

    func detailedSnapshot() -> RealtimeAudioCoreSnapshot {
        guard let engine else {
            return RealtimeAudioCoreSnapshot(
                frameIndex: 0,
                frameCount: 0,
                sampleRate: 0,
                hostTimestamp: 0,
                isPlaying: false,
                renderedFrameCount: 0,
                underrunCount: 0,
                droppedCommandCount: 0,
                callbackCount: 0,
                lastRenderNanoseconds: 0,
                maxRenderNanoseconds: 0,
                renderDeadlineMissCount: 0
            )
        }

        let snapshot = soundtime_audio_core_snapshot(engine)
        return RealtimeAudioCoreSnapshot(
            frameIndex: Int(min(snapshot.frameIndex, UInt64(Int.max))),
            frameCount: Int(min(snapshot.frameCount, UInt64(Int.max))),
            sampleRate: snapshot.sampleRate,
            hostTimestamp: snapshot.hostTimestamp,
            isPlaying: snapshot.isPlaying,
            renderedFrameCount: Int(min(snapshot.renderedFrameCount, UInt64(Int.max))),
            underrunCount: Int(min(snapshot.underrunCount, UInt64(Int.max))),
            droppedCommandCount: Int(min(snapshot.droppedCommandCount, UInt64(Int.max))),
            callbackCount: Int(min(snapshot.callbackCount, UInt64(Int.max))),
            lastRenderNanoseconds: Int(min(snapshot.lastRenderNanoseconds, UInt64(Int.max))),
            maxRenderNanoseconds: Int(min(snapshot.maxRenderNanoseconds, UInt64(Int.max))),
            renderDeadlineMissCount: Int(min(snapshot.renderDeadlineMissCount, UInt64(Int.max)))
        )
    }

    func popClockSample() -> RealtimeAudioClockSample? {
        guard let engine else {
            return nil
        }

        var sample = SoundtimeAudioCoreClockSample()
        guard soundtime_audio_core_pop_clock_sample(engine, &sample) else {
            return nil
        }

        return RealtimeAudioClockSample(
            frameIndex: Int(min(sample.frameIndex, UInt64(Int.max))),
            renderedFrameCount: Int(min(sample.renderedFrameCount, UInt64(Int.max))),
            hostTimestamp: sample.hostTimestamp,
            isPlaying: sample.isPlaying
        )
    }

    func popMeterSample() -> RealtimeAudioMeterSample? {
        guard let engine else {
            return nil
        }

        var sample = SoundtimeAudioCoreMeterSample()
        guard soundtime_audio_core_pop_meter_sample(engine, &sample) else {
            return nil
        }

        return RealtimeAudioMeterSample(
            startFrameIndex: Int(min(sample.startFrameIndex, UInt64(Int.max))),
            frameCount: Int(min(sample.frameCount, UInt64(Int.max))),
            renderedFrameCount: Int(min(sample.renderedFrameCount, UInt64(Int.max))),
            hostTimestamp: sample.hostTimestamp,
            isPlaying: sample.isPlaying,
            leftRMS: sample.leftRMS,
            rightRMS: sample.rightRMS,
            leftPeak: sample.leftPeak,
            rightPeak: sample.rightPeak,
            leftClipPeak: sample.leftClipPeak,
            rightClipPeak: sample.rightClipPeak
        )
    }

}

private final class MappedAudioFile: @unchecked Sendable {
    let pointer: UnsafeRawPointer
    let byteCount: Int

    init?(url: URL) {
        let fileDescriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }

            return Darwin.open(path, O_RDONLY)
        }
        guard fileDescriptor >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fileDescriptor)
        }

        var fileStat = stat()
        guard Darwin.fstat(fileDescriptor, &fileStat) == 0 else {
            return nil
        }

        let size = Int(fileStat.st_size)
        guard size > 0 else {
            return nil
        }

        let mappedPointer = Darwin.mmap(
            nil,
            size,
            PROT_READ,
            MAP_PRIVATE,
            fileDescriptor,
            0
        )
        guard let mappedPointer, mappedPointer != MAP_FAILED else {
            return nil
        }

        pointer = UnsafeRawPointer(mappedPointer)
        byteCount = size
    }

    deinit {
        Darwin.munmap(UnsafeMutableRawPointer(mutating: pointer), byteCount)
    }
}

private func withPlanarSamplePointers<T>(
    _ samplesByChannel: [[Float]],
    _ body: (UnsafePointer<UnsafePointer<Float>?>?) -> T
) -> T {
    var channelPointers = [UnsafePointer<Float>?](
        repeating: nil,
        count: samplesByChannel.count
    )

    func bindChannel(at channelIndex: Int) -> T {
        guard channelIndex < samplesByChannel.count else {
            return channelPointers.withUnsafeBufferPointer { pointerBuffer in
                body(pointerBuffer.baseAddress)
            }
        }

        return samplesByChannel[channelIndex].withUnsafeBufferPointer { sampleBuffer in
            channelPointers[channelIndex] = sampleBuffer.baseAddress
            return bindChannel(at: channelIndex + 1)
        }
    }

    return bindChannel(at: 0)
}
