import Foundation

enum SoundtimeFeatureFlags {
    static let waveformFisheye = false
    static let firstFrameWaveformPacket = ProcessInfo.processInfo
        .environment["SOUNDTIME_FIRST_FRAME_WAVEFORM_PACKET"] != "0"
}
