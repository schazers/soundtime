import Foundation

@MainActor
enum PlaybackEngineFactory {
    static func makeDefault() -> PlaybackEngine {
        if ProcessInfo.processInfo.environment["SOUNDTIME_LEGACY_PLAYBACK"] == "1" {
            return AudioPlaybackController()
        }

        if
            ProcessInfo.processInfo.environment["SOUNDTIME_REALTIME_PLAYBACK"] == "1",
            let realtimeEngine = makeRealtimeEngine()
        {
            return realtimeEngine
        }

        return HybridPlaybackEngine(realtimeEngine: makeRealtimeEngine())
    }

    private static func makeRealtimeEngine() -> RealtimeCorePlaybackEngine? {
        if ProcessInfo.processInfo.environment["SOUNDTIME_AUDIO_UNIT_OUTPUT"] == "1" {
            return RealtimeCorePlaybackEngine(outputDevice: AudioUnitOutputDevice())
        }

        return RealtimeCorePlaybackEngine()
    }
}
