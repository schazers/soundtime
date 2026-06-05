import Foundation

@MainActor
enum PlaybackEngineFactory {
    static func makeDefault() -> PlaybackEngine {
        if
            ProcessInfo.processInfo.environment["SOUNDTIME_REALTIME_PLAYBACK"] == "1",
            let realtimeEngine = RealtimeCorePlaybackEngine()
        {
            return realtimeEngine
        }

        return AudioPlaybackController()
    }
}
