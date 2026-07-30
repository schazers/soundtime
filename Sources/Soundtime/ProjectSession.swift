import Foundation

struct ProjectTrack {
    var id: UUID
    var editGroupID: UUID? = nil
    var name: String
    var sourceURL: URL
    var durationHint: TimeInterval?
    var sourceWaveformOverview: WaveformOverview?
    var waveformOverview: WaveformOverview?
    var decodedAudioBuffer: DecodedAudioBuffer?
    var zeroCrossingIndex: AudioZeroCrossingIndex?
    var zeroCrossingProbe: WAVZeroCrossingProbe?
    var audioTimeline: AudioEditTimeline?
    var fileTimeline: AudioFileEditTimeline?
    var editableSource: EditableAudioSource?
    var ownsSourceFile: Bool
    var volume: Float
    var isMuted: Bool
    var isSoloed: Bool
    var importID: UUID
    var editRevision: Int
    var transcript: TranscriptDocument? = nil
    var importedAssetID: UUID? = nil
    var importSessionID: UUID? = nil
    var importStage: AudioImportStage? = nil
    var importProgress: Double = 1
    var importFingerprint: AudioImportFingerprint? = nil
    var importPreviewIsProgressive = false
}

/// The authoritative identity, edit, and selection state for an open project.
///
/// `WorkspaceView` currently forwards its legacy property names into this
/// object. That keeps the migration behavior-neutral while giving render,
/// playback, persistence, and editing coordinators one domain owner to target.
@MainActor
final class ProjectSession {
    var tracks: [ProjectTrack] = []
    var editGraph = EditGraph()
    var activeTrackID: UUID?
    var selectedTrackID: UUID?
    var selectedTrackIDs: Set<UUID> = []
    var selection: TimelineSelection?
    var trackSelectionAnchorID: UUID?
    var defaultEditGroupID = UUID()
    var projectURL: URL?
    var projectID = UUID()
    var editRevision: UInt64 = 1
    var publishedTimelineRevision: UInt64 = 1
    var publishedPlaybackRevision: UInt64 = 1
    var visualRevision: UInt64 = 1
    var launchStateRevision: UInt64 = 1
}
