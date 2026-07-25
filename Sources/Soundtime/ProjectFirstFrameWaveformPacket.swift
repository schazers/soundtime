import Foundation

struct ProjectFirstFrameWaveformPacket: Codable, Sendable {
    static let currentSchemaVersion = 2
    static let maximumOverviewBinCount = ProjectLaunchSnapshot.maximumOverviewBinCount

    struct Track: Codable, Sendable {
        var id: UUID
        var editGroupID: UUID?
        var name: String
        var filePath: String
        var sourceMetadata: ProjectLaunchSnapshot.ProjectFileMetadata?
        var durationHint: TimeInterval?
        var displayOverview: ProjectLaunchSnapshot.OverviewPayload?
        var editTimeline: AudioFileEditTimeline.PersistentState?
        var editableSource: SoundtimeProject.Track.EditableSource?
        var ownsSourceFile: Bool?
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool

        var displayWaveformOverview: WaveformOverview? {
            displayOverview?.waveformOverview()
        }
    }

    var schemaVersion: Int
    var createdAt: TimeInterval
    var projectPath: String
    var projectMetadata: ProjectLaunchSnapshot.ProjectFileMetadata
    var projectID: UUID?
    var editGraphRevision: UInt64?
    var visualRevision: UInt64?
    var launchStateRevision: UInt64?
    var visualFingerprint: ProjectLaunchVisualFingerprint?
    var windowLayout: SoundtimeProject.WindowLayout?
    var timelineViewport: SoundtimeProject.TimelineViewport?
    var masterVolume: Float?
    var transcriptDisplayMode: TranscriptTimelineDisplayMode?
    var tracks: [Track]

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
        tracks: [ProjectLaunchSnapshot.TrackDraft]
    ) {
        schemaVersion = Self.currentSchemaVersion
        createdAt = Date().timeIntervalSince1970
        projectPath = projectURL.standardizedFileURL.path
        projectMetadata = ProjectLaunchSnapshot.ProjectFileMetadata(projectURL: projectURL)
        self.projectID = projectID
        self.editGraphRevision = editGraphRevision
        self.visualRevision = visualRevision
        self.launchStateRevision = launchStateRevision
        visualFingerprint = ProjectLaunchVisualFingerprint.make(
            projectPath: projectPath,
            tracks: tracks
        )
        self.windowLayout = windowLayout
        self.timelineViewport = timelineViewport
        self.masterVolume = masterVolume
        self.transcriptDisplayMode = transcriptDisplayMode
        self.tracks = tracks.map { draft in
            let displayOverview = ProjectLaunchSnapshot.OverviewPayload(
                draft.displayWaveformOverview ?? draft.sourceWaveformOverview,
                maximumBinCount: Self.maximumOverviewBinCount
            )
            let durationHint = draft.durationHint ??
                draft.displayWaveformOverview?.duration ??
                draft.sourceWaveformOverview?.duration ??
                Self.launchSnapshotDuration(from: draft.editTimeline) ??
                Self.editableDuration(from: draft.editableSource)
            return Track(
                id: draft.id,
                editGroupID: draft.editGroupID,
                name: draft.name,
                filePath: draft.filePath,
                sourceMetadata: ProjectLaunchSnapshot.ProjectFileMetadata(
                    fileURL: URL(fileURLWithPath: draft.filePath)
                ),
                durationHint: durationHint,
                displayOverview: displayOverview,
                editTimeline: draft.editTimeline,
                editableSource: draft.editableSource,
                ownsSourceFile: draft.ownsSourceFile,
                volume: draft.volume,
                isMuted: draft.isMuted,
                isSoloed: draft.isSoloed
            )
        }
    }

    init(
        schemaVersion: Int,
        createdAt: TimeInterval,
        projectPath: String,
        projectMetadata: ProjectLaunchSnapshot.ProjectFileMetadata,
        projectID: UUID? = nil,
        editGraphRevision: UInt64? = nil,
        visualRevision: UInt64? = nil,
        launchStateRevision: UInt64? = nil,
        visualFingerprint: ProjectLaunchVisualFingerprint? = nil,
        windowLayout: SoundtimeProject.WindowLayout?,
        timelineViewport: SoundtimeProject.TimelineViewport?,
        masterVolume: Float?,
        transcriptDisplayMode: TranscriptTimelineDisplayMode?,
        tracks: [Track]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.projectPath = projectPath
        self.projectMetadata = projectMetadata
        self.projectID = projectID
        self.editGraphRevision = editGraphRevision
        self.visualRevision = visualRevision
        self.launchStateRevision = launchStateRevision
        self.visualFingerprint = visualFingerprint
        self.windowLayout = windowLayout
        self.timelineViewport = timelineViewport
        self.masterVolume = masterVolume
        self.transcriptDisplayMode = transcriptDisplayMode
        self.tracks = tracks
    }

    var isDrawable: Bool {
        schemaVersion == Self.currentSchemaVersion &&
            tracks.contains { $0.displayOverview != nil || $0.durationHint != nil }
    }

    func isCompatibleForFirstPaint(with projectURL: URL) -> Bool {
        let standardizedProjectURL = projectURL.standardizedFileURL
        guard projectPath == standardizedProjectURL.path else {
            return false
        }
        return projectMetadata.isCompatible(with: ProjectLaunchSnapshot.ProjectFileMetadata(projectURL: standardizedProjectURL))
    }

    private static func editableDuration(from source: SoundtimeProject.Track.EditableSource?) -> TimeInterval? {
        guard
            let source,
            source.sourceSampleRate > 0,
            source.sourceSampleRate.isFinite
        else {
            return nil
        }
        return Double(source.sourceFrameCount) / source.sourceSampleRate
    }

    private static func launchSnapshotDuration(from state: AudioFileEditTimeline.PersistentState?) -> TimeInterval? {
        guard
            let state,
            state.sourceSampleRate > 0,
            state.sourceSampleRate.isFinite
        else {
            return nil
        }
        let frameCount = state.segments.reduce(0) { $0 + max($1.frameCount, 0) }
        return Double(frameCount) / state.sourceSampleRate
    }
}

enum ProjectFirstFrameWaveformPacketStore {
    private static let fileExtension = "soundtime-first-frame-waveforms"
    static let firstPaintSynchronousByteLimit = 8 * 1_024 * 1_024
    static let firstPaintManifestByteLimit = 512 * 1_024

    static func loadForFirstPaintIfAvailable(for projectURL: URL) -> ProjectFirstFrameWaveformPacket? {
        let url = packetURL(for: projectURL)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let fileSize = (attributes[.size] as? NSNumber)?.intValue,
            fileSize > 0,
            fileSize <= firstPaintSynchronousByteLimit,
            let data = try? Data(contentsOf: url),
            ProjectFirstFrameWaveformPacketBinaryCodec.hasBinaryMagic(data),
            let packet = try? ProjectFirstFrameWaveformPacketBinaryCodec.decode(data),
            packet.schemaVersion == ProjectFirstFrameWaveformPacket.currentSchemaVersion,
            packet.isCompatibleForFirstPaint(with: projectURL)
        else {
            return nil
        }

        return packet
    }

    static func loadShellForFirstPaintIfAvailable(for projectURL: URL) -> ProjectFirstFrameWaveformPacket? {
        let url = packetURL(for: projectURL)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let fileSize = (attributes[.size] as? NSNumber)?.intValue,
            fileSize > 0,
            let fileHandle = try? FileHandle(forReadingFrom: url)
        else {
            return nil
        }

        defer {
            try? fileHandle.close()
        }

        let headerData = fileHandle.readData(ofLength: ProjectFirstFrameWaveformPacketBinaryCodec.headerByteCount)
        guard
            let manifestByteCount = try? ProjectFirstFrameWaveformPacketBinaryCodec.manifestByteCount(
                fromHeader: headerData
            ),
            manifestByteCount > 0,
            manifestByteCount <= firstPaintManifestByteLimit
        else {
            return nil
        }

        let manifestData = fileHandle.readData(ofLength: manifestByteCount)
        guard
            manifestData.count == manifestByteCount,
            let packet = try? ProjectFirstFrameWaveformPacketBinaryCodec.decodeManifestOnly(manifestData),
            packet.schemaVersion == ProjectFirstFrameWaveformPacket.currentSchemaVersion,
            packet.isCompatibleForFirstPaint(with: projectURL)
        else {
            return nil
        }

        return packet
    }

    static func save(_ packet: ProjectFirstFrameWaveformPacket, for projectURL: URL) throws {
        let url = packetURL(for: projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try ProjectFirstFrameWaveformPacketBinaryCodec.encode(packet)
        try data.write(to: url, options: [.atomic])
    }

    static func remove(for projectURL: URL) {
        try? FileManager.default.removeItem(at: packetURL(for: projectURL))
    }

    static func packetURL(for projectURL: URL) -> URL {
        packetsDirectoryURL()
            .appendingPathComponent(SoundtimeProjectStore.stableProjectKey(for: projectURL))
            .appendingPathExtension(fileExtension)
            .standardizedFileURL
    }

    private static func packetsDirectoryURL() -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return baseDirectory
            .appendingPathComponent("Soundtime", isDirectory: true)
            .appendingPathComponent("FirstFrameWaveforms", isDirectory: true)
            .standardizedFileURL
    }
}

enum ProjectFirstFrameWaveformPacketBinaryCodec {
    enum CodecError: Error {
        case notBinaryPacket
        case invalidPayload
    }

    private static let magic = Array("STFFWP01".utf8)
    private static let containerVersion: UInt32 = 1
    static var headerByteCount: Int {
        magic.count + 4 + 8 + 8
    }

    private struct OverviewDescriptor: Codable, Sendable {
        var duration: TimeInterval
        var binCount: Int
        var offset: Int
        var byteCount: Int
    }

    private struct TrackManifest: Codable, Sendable {
        var id: UUID
        var editGroupID: UUID?
        var name: String
        var filePath: String
        var sourceMetadata: ProjectLaunchSnapshot.ProjectFileMetadata?
        var durationHint: TimeInterval?
        var displayOverview: OverviewDescriptor?
        var editTimeline: AudioFileEditTimeline.PersistentState?
        var editableSource: SoundtimeProject.Track.EditableSource?
        var ownsSourceFile: Bool?
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool
    }

    private struct Manifest: Codable, Sendable {
        var containerVersion: UInt32
        var schemaVersion: Int
        var createdAt: TimeInterval
        var projectPath: String
        var projectMetadata: ProjectLaunchSnapshot.ProjectFileMetadata
        var projectID: UUID?
        var editGraphRevision: UInt64?
        var visualRevision: UInt64?
        var launchStateRevision: UInt64?
        var visualFingerprint: ProjectLaunchVisualFingerprint?
        var windowLayout: SoundtimeProject.WindowLayout?
        var timelineViewport: SoundtimeProject.TimelineViewport?
        var masterVolume: Float?
        var transcriptDisplayMode: TranscriptTimelineDisplayMode?
        var tracks: [TrackManifest]
    }

    static func encode(_ packet: ProjectFirstFrameWaveformPacket) throws -> Data {
        var overviewBlob = Data()
        overviewBlob.reserveCapacity(packet.tracks.reduce(0) { total, track in
            total + (track.displayOverview?.encodedBins.count ?? 0)
        })

        let trackManifests = packet.tracks.map { track in
            TrackManifest(
                id: track.id,
                editGroupID: track.editGroupID,
                name: track.name,
                filePath: track.filePath,
                sourceMetadata: track.sourceMetadata,
                durationHint: track.durationHint,
                displayOverview: appendOverview(track.displayOverview, to: &overviewBlob),
                editTimeline: track.editTimeline,
                editableSource: track.editableSource,
                ownsSourceFile: track.ownsSourceFile,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed
            )
        }

        let manifest = Manifest(
            containerVersion: containerVersion,
            schemaVersion: packet.schemaVersion,
            createdAt: packet.createdAt,
            projectPath: packet.projectPath,
            projectMetadata: packet.projectMetadata,
            projectID: packet.projectID,
            editGraphRevision: packet.editGraphRevision,
            visualRevision: packet.visualRevision,
            launchStateRevision: packet.launchStateRevision,
            visualFingerprint: packet.visualFingerprint,
            windowLayout: packet.windowLayout,
            timelineViewport: packet.timelineViewport,
            masterVolume: packet.masterVolume,
            transcriptDisplayMode: packet.transcriptDisplayMode,
            tracks: trackManifests
        )
        let manifestData = try JSONEncoder().encode(manifest)

        var data = Data()
        data.reserveCapacity(magic.count + 20 + manifestData.count + overviewBlob.count)
        data.append(contentsOf: magic)
        appendUInt32(containerVersion, to: &data)
        appendUInt64(UInt64(manifestData.count), to: &data)
        appendUInt64(UInt64(overviewBlob.count), to: &data)
        data.append(manifestData)
        data.append(overviewBlob)
        return data
    }

    static func decode(_ data: Data) throws -> ProjectFirstFrameWaveformPacket {
        guard data.count >= magic.count, Array(data.prefix(magic.count)) == magic else {
            throw CodecError.notBinaryPacket
        }

        var offset = magic.count
        let version = try readUInt32(from: data, offset: &offset)
        guard version == containerVersion else {
            throw CodecError.invalidPayload
        }
        let manifestLength = Int(try readUInt64(from: data, offset: &offset))
        let blobLength = Int(try readUInt64(from: data, offset: &offset))
        guard
            manifestLength >= 0,
            blobLength >= 0,
            offset + manifestLength + blobLength == data.count
        else {
            throw CodecError.invalidPayload
        }

        let manifestData = data.subdata(in: offset..<(offset + manifestLength))
        offset += manifestLength
        let blobStart = offset
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.containerVersion == containerVersion else {
            throw CodecError.invalidPayload
        }

        let tracks = try manifest.tracks.map { track in
            ProjectFirstFrameWaveformPacket.Track(
                id: track.id,
                editGroupID: track.editGroupID,
                name: track.name,
                filePath: track.filePath,
                sourceMetadata: track.sourceMetadata,
                durationHint: track.durationHint,
                displayOverview: try overviewPayload(track.displayOverview, blobStart: blobStart, data: data),
                editTimeline: track.editTimeline,
                editableSource: track.editableSource,
                ownsSourceFile: track.ownsSourceFile,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed
            )
        }

        return ProjectFirstFrameWaveformPacket(
            schemaVersion: manifest.schemaVersion,
            createdAt: manifest.createdAt,
            projectPath: manifest.projectPath,
            projectMetadata: manifest.projectMetadata,
            projectID: manifest.projectID,
            editGraphRevision: manifest.editGraphRevision,
            visualRevision: manifest.visualRevision,
            launchStateRevision: manifest.launchStateRevision,
            visualFingerprint: manifest.visualFingerprint,
            windowLayout: manifest.windowLayout,
            timelineViewport: manifest.timelineViewport,
            masterVolume: manifest.masterVolume,
            transcriptDisplayMode: manifest.transcriptDisplayMode,
            tracks: tracks
        )
    }

    static func manifestByteCount(fromHeader data: Data) throws -> Int {
        guard data.count == headerByteCount, Array(data.prefix(magic.count)) == magic else {
            throw CodecError.notBinaryPacket
        }

        var offset = magic.count
        let version = try readUInt32(from: data, offset: &offset)
        guard version == containerVersion else {
            throw CodecError.invalidPayload
        }

        let manifestLength = Int(try readUInt64(from: data, offset: &offset))
        _ = try readUInt64(from: data, offset: &offset)
        guard manifestLength >= 0 else {
            throw CodecError.invalidPayload
        }

        return manifestLength
    }

    static func decodeManifestOnly(_ manifestData: Data) throws -> ProjectFirstFrameWaveformPacket {
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.containerVersion == containerVersion else {
            throw CodecError.invalidPayload
        }

        let tracks = manifest.tracks.map { track in
            ProjectFirstFrameWaveformPacket.Track(
                id: track.id,
                editGroupID: track.editGroupID,
                name: track.name,
                filePath: track.filePath,
                sourceMetadata: track.sourceMetadata,
                durationHint: track.durationHint ?? track.displayOverview?.duration,
                displayOverview: nil,
                editTimeline: track.editTimeline,
                editableSource: track.editableSource,
                ownsSourceFile: track.ownsSourceFile,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed
            )
        }

        return ProjectFirstFrameWaveformPacket(
            schemaVersion: manifest.schemaVersion,
            createdAt: manifest.createdAt,
            projectPath: manifest.projectPath,
            projectMetadata: manifest.projectMetadata,
            projectID: manifest.projectID,
            editGraphRevision: manifest.editGraphRevision,
            visualRevision: manifest.visualRevision,
            launchStateRevision: manifest.launchStateRevision,
            visualFingerprint: manifest.visualFingerprint,
            windowLayout: manifest.windowLayout,
            timelineViewport: manifest.timelineViewport,
            masterVolume: manifest.masterVolume,
            transcriptDisplayMode: manifest.transcriptDisplayMode,
            tracks: tracks
        )
    }

    static func hasBinaryMagic(_ data: Data) -> Bool {
        data.count >= magic.count && Array(data.prefix(magic.count)) == magic
    }

    private static func appendOverview(
        _ overview: ProjectLaunchSnapshot.OverviewPayload?,
        to data: inout Data
    ) -> OverviewDescriptor? {
        guard let overview else {
            return nil
        }

        let offset = data.count
        data.append(overview.encodedBins)
        return OverviewDescriptor(
            duration: overview.duration,
            binCount: overview.binCount,
            offset: offset,
            byteCount: overview.encodedBins.count
        )
    }

    private static func overviewPayload(
        _ descriptor: OverviewDescriptor?,
        blobStart: Int,
        data: Data
    ) throws -> ProjectLaunchSnapshot.OverviewPayload? {
        guard let descriptor else {
            return nil
        }
        guard
            descriptor.offset >= 0,
            descriptor.byteCount >= 0,
            blobStart + descriptor.offset + descriptor.byteCount <= data.count
        else {
            throw CodecError.invalidPayload
        }

        let start = blobStart + descriptor.offset
        let end = start + descriptor.byteCount
        return ProjectLaunchSnapshot.OverviewPayload(
            duration: descriptor.duration,
            binCount: descriptor.binCount,
            encodedBins: data.subdata(in: start..<end)
        )
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func readUInt32(from data: Data, offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw CodecError.invalidPayload
        }

        var value: UInt32 = 0
        value |= UInt32(data[offset])
        value |= UInt32(data[offset + 1]) << 8
        value |= UInt32(data[offset + 2]) << 16
        value |= UInt32(data[offset + 3]) << 24
        offset += 4
        return value
    }

    private static func readUInt64(from data: Data, offset: inout Int) throws -> UInt64 {
        guard offset + 8 <= data.count else {
            throw CodecError.invalidPayload
        }

        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        offset += 8
        return value
    }
}

extension ProjectLaunchReadinessClassifier {
    static func summarize(packet: ProjectFirstFrameWaveformPacket) -> ProjectLaunchVisualReadinessSummary {
        var drawableWaveformTrackCount = 0
        var durationOnlyTrackCount = 0
        var blankTrackCount = 0
        var playbackMetadataTrackCount = 0

        for track in packet.tracks {
            let hasDrawableWaveform = track.displayOverview != nil
            let hasDurationHint = track.durationHint != nil ||
                track.displayOverview?.duration.isFinite == true ||
                packetLaunchSnapshotDuration(from: track.editTimeline) != nil ||
                packetEditableDuration(from: track.editableSource) != nil

            if hasDrawableWaveform {
                drawableWaveformTrackCount += 1
            } else if hasDurationHint {
                durationOnlyTrackCount += 1
            } else {
                blankTrackCount += 1
            }

            if track.editTimeline != nil || track.editableSource != nil {
                playbackMetadataTrackCount += 1
            }
        }

        return ProjectLaunchVisualReadinessSummary(
            trackCount: packet.tracks.count,
            drawableWaveformTrackCount: drawableWaveformTrackCount,
            durationOnlyTrackCount: durationOnlyTrackCount,
            blankTrackCount: blankTrackCount,
            playbackMetadataTrackCount: playbackMetadataTrackCount
        )
    }

    private static func packetLaunchSnapshotDuration(from state: AudioFileEditTimeline.PersistentState?) -> TimeInterval? {
        guard
            let state,
            state.sourceSampleRate > 0,
            state.sourceSampleRate.isFinite
        else {
            return nil
        }
        let frameCount = state.segments.reduce(0) { $0 + max($1.frameCount, 0) }
        return Double(frameCount) / state.sourceSampleRate
    }

    private static func packetEditableDuration(from source: SoundtimeProject.Track.EditableSource?) -> TimeInterval? {
        guard
            let source,
            source.sourceSampleRate > 0,
            source.sourceSampleRate.isFinite
        else {
            return nil
        }
        return Double(source.sourceFrameCount) / source.sourceSampleRate
    }
}
