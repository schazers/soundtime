import Foundation

struct ProjectLaunchVisualFingerprint: Codable, Equatable, Sendable {
    static let algorithm = "soundtime-launch-visual-fnv1a-v1"

    var algorithm: String
    var value: String

    init(value: String, algorithm: String = ProjectLaunchVisualFingerprint.algorithm) {
        self.algorithm = algorithm
        self.value = value
    }

    static func make(
        projectPath: String,
        tracks: [ProjectLaunchSnapshot.TrackDraft]
    ) -> ProjectLaunchVisualFingerprint {
        var hasher = FNV1A64()
        hasher.append("schema:\(ProjectLaunchSnapshot.currentSchemaVersion)")
        hasher.append("project:\(projectPath)")
        hasher.append("tracks:\(tracks.count)")
        for (index, track) in tracks.enumerated() {
            hasher.append("track-index:\(index)")
            hasher.append("id:\(track.id.uuidString)")
            hasher.append("group:\(track.editGroupID?.uuidString ?? "nil")")
            hasher.append("path:\(URL(fileURLWithPath: track.filePath).standardizedFileURL.path)")
            hasher.append("duration:\(rounded(track.durationHint))")
            hasher.append("owns:\(track.ownsSourceFile.map(String.init) ?? "nil")")
            append(timeline: track.editTimeline, to: &hasher)
            append(editableSource: track.editableSource, to: &hasher)
        }
        return ProjectLaunchVisualFingerprint(value: hasher.hexDigest)
    }

    static func make(snapshot: ProjectLaunchSnapshot) -> ProjectLaunchVisualFingerprint {
        var hasher = FNV1A64()
        hasher.append("schema:\(snapshot.schemaVersion)")
        hasher.append("project:\(snapshot.projectPath)")
        hasher.append("tracks:\(snapshot.tracks.count)")
        for (index, track) in snapshot.tracks.enumerated() {
            hasher.append("track-index:\(index)")
            hasher.append("id:\(track.id.uuidString)")
            hasher.append("group:\(track.editGroupID?.uuidString ?? "nil")")
            hasher.append("path:\(URL(fileURLWithPath: track.filePath).standardizedFileURL.path)")
            hasher.append("duration:\(rounded(track.durationHint))")
            hasher.append("owns:\(track.ownsSourceFile.map(String.init) ?? "nil")")
            append(timeline: track.editTimeline, to: &hasher)
            append(editableSource: track.editableSource, to: &hasher)
        }
        return ProjectLaunchVisualFingerprint(value: hasher.hexDigest)
    }

    static func make(packet: ProjectFirstFrameWaveformPacket) -> ProjectLaunchVisualFingerprint {
        var hasher = FNV1A64()
        hasher.append("schema:\(packet.schemaVersion)")
        hasher.append("project:\(packet.projectPath)")
        hasher.append("tracks:\(packet.tracks.count)")
        for (index, track) in packet.tracks.enumerated() {
            hasher.append("track-index:\(index)")
            hasher.append("id:\(track.id.uuidString)")
            hasher.append("group:\(track.editGroupID?.uuidString ?? "nil")")
            hasher.append("path:\(URL(fileURLWithPath: track.filePath).standardizedFileURL.path)")
            hasher.append("duration:\(rounded(track.durationHint))")
            hasher.append("owns:\(track.ownsSourceFile.map(String.init) ?? "nil")")
            append(timeline: track.editTimeline, to: &hasher)
            append(editableSource: track.editableSource, to: &hasher)
        }
        return ProjectLaunchVisualFingerprint(value: hasher.hexDigest)
    }

    private static func append(
        timeline: AudioFileEditTimeline.PersistentState?,
        to hasher: inout FNV1A64
    ) {
        guard let timeline else {
            hasher.append("timeline:nil")
            return
        }
        hasher.append("timeline-source-frames:\(timeline.sourceFrameCount)")
        hasher.append("timeline-rate:\(rounded(timeline.sourceSampleRate))")
        hasher.append("timeline-segments:\(timeline.segments.count)")
        for segment in timeline.segments {
            hasher.append("segment-source:\(segment.sourceStartFrame)")
            hasher.append("segment-frames:\(segment.frameCount)")
            hasher.append("segment-gain-start:\(rounded(segment.gainStart))")
            hasher.append("segment-gain-end:\(rounded(segment.gainEnd))")
            hasher.append("segment-new-clip:\(segment.startsNewClip ?? false)")
        }
    }

    private static func append(
        editableSource: SoundtimeProject.Track.EditableSource?,
        to hasher: inout FNV1A64
    ) {
        guard let editableSource else {
            hasher.append("editable:nil")
            return
        }
        hasher.append("editable-id:\(editableSource.importedAssetID?.uuidString ?? "nil")")
        hasher.append("editable-original:\(URL(fileURLWithPath: editableSource.originalFilePath).standardizedFileURL.path)")
        hasher.append("editable-file:\(URL(fileURLWithPath: editableSource.editableFilePath).standardizedFileURL.path)")
        hasher.append("editable-origin:\(editableSource.formatOrigin.rawValue)")
        hasher.append("editable-frames:\(editableSource.sourceFrameCount)")
        hasher.append("editable-rate:\(rounded(editableSource.sourceSampleRate))")
        hasher.append("editable-owned:\(editableSource.ownsEditableFile)")
    }

    private static func rounded(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "nil"
        }
        return String(format: "%.9f", value)
    }

    private static func rounded(_ value: Float) -> String {
        guard value.isFinite else {
            return "nan"
        }
        return String(format: "%.6f", Double(value))
    }
}

struct ProjectLaunchManifest: Codable, Sendable {
    static let currentSchemaVersion = 1

    struct TrackShell: Codable, Sendable {
        var id: UUID
        var editGroupID: UUID?
        var name: String
        var filePath: String
        var durationHint: TimeInterval?
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool
    }

    var schemaVersion: Int
    var createdAt: TimeInterval
    var projectPath: String
    var projectMetadata: ProjectLaunchSnapshot.ProjectFileMetadata
    var projectID: UUID?
    var editGraphRevision: UInt64?
    var visualRevision: UInt64?
    var launchStateRevision: UInt64?
    var visualFingerprint: ProjectLaunchVisualFingerprint
    var windowLayout: SoundtimeProject.WindowLayout?
    var timelineViewport: SoundtimeProject.TimelineViewport?
    var masterVolume: Float?
    var transcriptDisplayMode: TranscriptTimelineDisplayMode?
    var tracks: [TrackShell]
    var snapshotByteCount: Int?
    var firstFramePacketByteCount: Int?
    var snapshotDrawable: Bool
    var firstFramePacketDrawable: Bool

    init(
        projectURL: URL,
        projectID: UUID? = nil,
        editGraphRevision: UInt64? = nil,
        visualRevision: UInt64? = nil,
        launchStateRevision: UInt64? = nil,
        windowLayout: SoundtimeProject.WindowLayout?,
        timelineViewport: SoundtimeProject.TimelineViewport?,
        masterVolume: Float?,
        transcriptDisplayMode: TranscriptTimelineDisplayMode?,
        tracks: [ProjectLaunchSnapshot.TrackDraft],
        snapshotByteCount: Int?,
        firstFramePacketByteCount: Int?,
        snapshotDrawable: Bool,
        firstFramePacketDrawable: Bool
    ) {
        let standardizedProjectURL = projectURL.standardizedFileURL
        schemaVersion = Self.currentSchemaVersion
        createdAt = Date().timeIntervalSince1970
        projectPath = standardizedProjectURL.path
        projectMetadata = ProjectLaunchSnapshot.ProjectFileMetadata(projectURL: standardizedProjectURL)
        self.projectID = projectID
        self.editGraphRevision = editGraphRevision
        self.visualRevision = visualRevision
        self.launchStateRevision = launchStateRevision
        visualFingerprint = ProjectLaunchVisualFingerprint.make(
            projectPath: standardizedProjectURL.path,
            tracks: tracks
        )
        self.windowLayout = windowLayout
        self.timelineViewport = timelineViewport
        self.masterVolume = masterVolume
        self.transcriptDisplayMode = transcriptDisplayMode
        self.tracks = tracks.map { track in
            TrackShell(
                id: track.id,
                editGroupID: track.editGroupID,
                name: track.name,
                filePath: track.filePath,
                durationHint: track.durationHint ??
                    track.displayWaveformOverview?.duration ??
                    track.sourceWaveformOverview?.duration ??
                    track.editTimeline?.launchManifestDuration,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed
            )
        }
        self.snapshotByteCount = snapshotByteCount
        self.firstFramePacketByteCount = firstFramePacketByteCount
        self.snapshotDrawable = snapshotDrawable
        self.firstFramePacketDrawable = firstFramePacketDrawable
    }

    var isCompatibleForFirstPaint: Bool {
        schemaVersion == Self.currentSchemaVersion &&
            projectPath == projectMetadata.canonicalPath &&
            projectMetadata.isCompatible(with: ProjectLaunchSnapshot.ProjectFileMetadata(fileURL: URL(fileURLWithPath: projectPath)))
    }
}

enum ProjectLaunchManifestStore {
    private static let fileExtension = "soundtime-launch-manifest"
    static let firstPaintSynchronousByteLimit = 512 * 1_024

    static func load(for projectURL: URL) -> ProjectLaunchManifest? {
        let url = manifestURL(for: projectURL)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let fileSize = (attributes[.size] as? NSNumber)?.intValue,
            fileSize > 0,
            fileSize <= firstPaintSynchronousByteLimit,
            let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(ProjectLaunchManifest.self, from: data),
            manifest.schemaVersion == ProjectLaunchManifest.currentSchemaVersion,
            manifest.projectPath == projectURL.standardizedFileURL.path,
            manifest.isCompatibleForFirstPaint
        else {
            return nil
        }
        return manifest
    }

    static func save(_ manifest: ProjectLaunchManifest, for projectURL: URL) throws {
        let url = manifestURL(for: projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    static func remove(for projectURL: URL) {
        try? FileManager.default.removeItem(at: manifestURL(for: projectURL))
    }

    static func manifestURL(for projectURL: URL) -> URL {
        manifestsDirectoryURL()
            .appendingPathComponent(SoundtimeProjectStore.stableProjectKey(for: projectURL))
            .appendingPathExtension(fileExtension)
            .standardizedFileURL
    }

    private static func manifestsDirectoryURL() -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return baseDirectory
            .appendingPathComponent("Soundtime", isDirectory: true)
            .appendingPathComponent("LaunchManifests", isDirectory: true)
            .standardizedFileURL
    }
}

extension ProjectLaunchReadinessClassifier {
    static func summarize(manifest: ProjectLaunchManifest) -> ProjectLaunchVisualReadinessSummary {
        var durationOnlyTrackCount = 0
        var blankTrackCount = 0
        for track in manifest.tracks {
            if track.durationHint != nil {
                durationOnlyTrackCount += 1
            } else {
                blankTrackCount += 1
            }
        }
        return ProjectLaunchVisualReadinessSummary(
            trackCount: manifest.tracks.count,
            drawableWaveformTrackCount: 0,
            durationOnlyTrackCount: durationOnlyTrackCount,
            blankTrackCount: blankTrackCount,
            playbackMetadataTrackCount: 0
        )
    }
}

private struct FNV1A64 {
    private var value: UInt64 = 14_695_981_039_346_656_037

    mutating func append(_ string: String) {
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value = value &* 1_099_511_628_211
        }
        value ^= 0xff
        value = value &* 1_099_511_628_211
    }

    var hexDigest: String {
        String(format: "%016llx", value)
    }
}

private extension AudioFileEditTimeline.PersistentState {
    var launchManifestDuration: TimeInterval? {
        guard sourceSampleRate > 0, sourceSampleRate.isFinite else {
            return nil
        }
        let frameCount = segments.reduce(0) { $0 + max($1.frameCount, 0) }
        return Double(frameCount) / sourceSampleRate
    }
}
