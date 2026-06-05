import Foundation
import SoundtimeAudioCore

final class RealtimeAudioCore {
    private var engine: OpaquePointer?

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

    func reset() {
        guard let engine else {
            return
        }

        soundtime_audio_core_reset(engine)
    }

    func snapshot() -> PlaybackSnapshot {
        guard let engine else {
            return PlaybackSnapshot(frameIndex: 0, frameCount: 0, isPlaying: false, hostTimestamp: 0)
        }

        let snapshot = soundtime_audio_core_snapshot(engine)
        return PlaybackSnapshot(
            frameIndex: Int(min(snapshot.frameIndex, UInt64(Int.max))),
            frameCount: Int(min(snapshot.frameCount, UInt64(Int.max))),
            isPlaying: snapshot.isPlaying,
            hostTimestamp: 0
        )
    }
}
