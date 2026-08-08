import Foundation

@MainActor
enum PlaybackEngineFactory {
    static func makeDefault() -> PlaybackEngine {
        if ProcessInfo.processInfo.environment["SOUNDTIME_LEGACY_PLAYBACK"] == "1" {
            // The single-file preview engine cannot represent clip gaps or
            // source remapping. Keep the legacy AVFoundation backend without
            // silently flattening a project arrangement into the whole file.
            return MultitrackPlaybackController()
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
