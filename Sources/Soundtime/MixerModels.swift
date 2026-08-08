import AppKit
import Foundation
import SoundtimeEditing

enum WorkspaceBottomPanelMode: Equatable {
    case hidden
    case trackInspector
    case mixer
}

enum MixerCommandContract {
    static let menuTitle = "Mixer"
    static let keyEquivalent = "x"
    static let keyEquivalentModifierMask: NSEvent.ModifierFlags = []
}

enum MixerAutomationMode: String, CaseIterable, Codable, Sendable {
    case read
    case touch
    case latch
    case write

    var displayName: String {
        switch self {
        case .read: "Read"
        case .touch: "Touch"
        case .latch: "Latch"
        case .write: "Write"
        }
    }
}

struct MixerChannelPresentation: Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var channelLayout: TrackChannelLayout
    var volume: Float
    var pan: Float
    var isMuted: Bool
    var isSoloed: Bool
    var isVolumeAutomated: Bool
    var isPanAutomated: Bool
    var volumeAutomationMode: MixerAutomationMode
    var panAutomationMode: MixerAutomationMode
}

struct MixerMeterLevel: Equatable, Sendable {
    var trackID: UUID
    var channelCount: Int
    var leftRMS: Float
    var rightRMS: Float
    var leftPeak: Float
    var rightPeak: Float
}

struct MixerMeterPacket: Equatable, Sendable {
    var graphRevision: UInt64
    var sequence: UInt64
    var hostTimestamp: TimeInterval
    var levels: [MixerMeterLevel]
}

struct MixerDiagnosticsSnapshot: Equatable, Sendable {
    var packetAgeMilliseconds: Double
    var droppedPacketCount: UInt64
    var stalePacketCount: UInt64
    var realtimeWorkNanoseconds: UInt64
    var visibleChannelCount: Int
    var renderedMeterCount: Int
    var gpuDrawCount: Int
    var drawDurationMilliseconds: Double
    var maximumDrawDurationMilliseconds: Double
}

enum MixerFaderLaw {
    static let minimumDecibels = TimelineMixerFaderLaw.minimumDecibels
    static let maximumDecibels = TimelineMixerFaderLaw.maximumDecibels
    static let unityDetentWidth: Float = 0.012

    static func decibels(forGain gain: Float) -> Float {
        TimelineMixerFaderLaw.decibels(forGain: gain)
    }

    static func gain(forDecibels decibels: Float) -> Float {
        guard decibels.isFinite, decibels > minimumDecibels else { return 0 }
        return pow(10, min(decibels, maximumDecibels) / 20)
    }

    /// Fader travel reserves more physical space around unity than a linear
    /// dB mapping, while remaining exactly reversible.
    static func position(forGain gain: Float) -> Float {
        TimelineMixerFaderLaw.position(forGain: gain)
    }

    static func gain(forPosition rawPosition: Float) -> Float {
        let position = min(max(rawPosition, 0), 1)
        let unityPosition: Float = 0.85
        if abs(position - unityPosition) <= unityDetentWidth {
            return 1
        }
        return TimelineMixerFaderLaw.gain(forPosition: position)
    }

    static func displayString(forGain gain: Float) -> String {
        let dB = decibels(forGain: gain)
        return dB <= minimumDecibels ? "-inf" : String(format: "%+.1f", dB)
    }
}
