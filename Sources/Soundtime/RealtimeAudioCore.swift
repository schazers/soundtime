import Foundation
import SoundtimeAudioCore

struct RealtimeAudioClockSample {
    let frameIndex: Int
    let renderedFrameCount: Int
    let hostTimestamp: TimeInterval
    let isPlaying: Bool
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

    var playbackSnapshot: PlaybackSnapshot {
        PlaybackSnapshot(
            frameIndex: frameIndex,
            frameCount: frameCount,
            isPlaying: isPlaying,
            hostTimestamp: hostTimestamp
        )
    }
}

final class RealtimeAudioCore {
    private var engine: OpaquePointer?

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

        return Self.withPlanarSamplePointers(decodedAudioBuffer.samplesByChannel) { channelPointers in
            soundtime_audio_core_set_planar_source(
                engine,
                channelPointers,
                UInt64(max(decodedAudioBuffer.frameCount, 0)),
                UInt32(max(decodedAudioBuffer.channelCount, 0)),
                decodedAudioBuffer.sampleRate
            )
        }
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
                droppedCommandCount: 0
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
            droppedCommandCount: Int(min(snapshot.droppedCommandCount, UInt64(Int.max)))
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

    private static func withPlanarSamplePointers<T>(
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
}
