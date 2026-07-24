import Foundation

struct ProjectLaunchSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumOverviewBinCount = 32_768

    struct ProjectFileMetadata: Codable, Sendable, Equatable {
        var canonicalPath: String?
        var fileSize: Int64?
        var modificationTime: TimeInterval?

        init(projectURL: URL) {
            self.init(fileURL: projectURL)
        }

        init(fileURL: URL) {
            canonicalPath = fileURL.standardizedFileURL.path
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: fileURL.standardizedFileURL.path
            )
            fileSize = (attributes?[.size] as? NSNumber)?.int64Value
            modificationTime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
        }

        func isCompatible(with other: ProjectFileMetadata) -> Bool {
            if let canonicalPath {
                guard let otherCanonicalPath = other.canonicalPath, canonicalPath == otherCanonicalPath else {
                    return false
                }
            }

            if let fileSize {
                guard let otherFileSize = other.fileSize, fileSize == otherFileSize else {
                    return false
                }
            }

            if let modificationTime {
                guard
                    let otherModificationTime = other.modificationTime,
                    abs(modificationTime - otherModificationTime) <= 0.001
                else {
                    return false
                }
            }

            return true
        }
    }

    struct OverviewPayload: Codable, Sendable {
        var duration: TimeInterval
        var binCount: Int
        var encodedBins: Data

        init?(_ overview: WaveformOverview?, maximumBinCount: Int = ProjectLaunchSnapshot.maximumOverviewBinCount) {
            guard let overview, !overview.isEmpty, overview.duration.isFinite else {
                return nil
            }

            let reducedOverview = overview.reducedForLaunchSnapshot(maximumBinCount: maximumBinCount)
            duration = reducedOverview.duration
            binCount = reducedOverview.bins.count
            encodedBins = WaveformOverviewBinaryCodec.encode(reducedOverview)
        }

        init(duration: TimeInterval, binCount: Int, encodedBins: Data) {
            self.duration = duration
            self.binCount = binCount
            self.encodedBins = encodedBins
        }

        func waveformOverview() -> WaveformOverview? {
            try? WaveformOverviewBinaryCodec.decode(
                encodedBins,
                duration: duration,
                expectedBinCount: binCount
            )
        }
    }

    struct Track: Codable, Sendable {
        var id: UUID
        var editGroupID: UUID?
        var name: String
        var filePath: String
        var sourceMetadata: ProjectFileMetadata?
        var durationHint: TimeInterval?
        var sourceOverview: OverviewPayload?
        var displayOverview: OverviewPayload?
        var editTimeline: AudioFileEditTimeline.PersistentState?
        var editableSource: SoundtimeProject.Track.EditableSource?
        var ownsSourceFile: Bool?
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool

        var sourceWaveformOverview: WaveformOverview? {
            sourceOverview?.waveformOverview()
        }

        var displayWaveformOverview: WaveformOverview? {
            displayOverview?.waveformOverview()
        }

        var hasCompatibleSourceFile: Bool {
            guard let sourceMetadata else {
                return true
            }

            let sourceURL = URL(fileURLWithPath: filePath).standardizedFileURL
            return sourceMetadata.isCompatible(with: ProjectFileMetadata(fileURL: sourceURL))
        }

        func validatedForLaunch() -> Track {
            guard !hasCompatibleSourceFile else {
                return self
            }

            var track = self
            track.durationHint = nil
            track.sourceOverview = nil
            track.displayOverview = nil
            track.editTimeline = nil
            return track
        }
    }

    struct TrackDraft: Sendable {
        var id: UUID
        var editGroupID: UUID?
        var name: String
        var filePath: String
        var durationHint: TimeInterval?
        var sourceWaveformOverview: WaveformOverview?
        var displayWaveformOverview: WaveformOverview?
        var editTimeline: AudioFileEditTimeline.PersistentState?
        var editableSource: SoundtimeProject.Track.EditableSource?
        var ownsSourceFile: Bool?
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool
    }

    var schemaVersion: Int
    var createdAt: TimeInterval
    var projectPath: String
    var projectMetadata: ProjectFileMetadata
    var windowLayout: SoundtimeProject.WindowLayout?
    var timelineViewport: SoundtimeProject.TimelineViewport?
    var masterVolume: Float?
    var transcriptDisplayMode: TranscriptTimelineDisplayMode?
    var tracks: [Track]

    init(
        projectURL: URL,
        windowLayout: SoundtimeProject.WindowLayout?,
        timelineViewport: SoundtimeProject.TimelineViewport?,
        masterVolume: Float?,
        transcriptDisplayMode: TranscriptTimelineDisplayMode?,
        tracks: [TrackDraft]
    ) {
        schemaVersion = Self.currentSchemaVersion
        createdAt = Date().timeIntervalSince1970
        projectPath = projectURL.standardizedFileURL.path
        projectMetadata = ProjectFileMetadata(projectURL: projectURL)
        self.windowLayout = windowLayout
        self.timelineViewport = timelineViewport
        self.masterVolume = masterVolume
        self.transcriptDisplayMode = transcriptDisplayMode
        self.tracks = tracks.map { draft in
            let sourceOverview = OverviewPayload(draft.sourceWaveformOverview)
            let displayOverview = OverviewPayload(
                draft.displayWaveformOverview ?? draft.sourceWaveformOverview
            )
            let durationHint = draft.durationHint ??
                draft.displayWaveformOverview?.duration ??
                draft.sourceWaveformOverview?.duration ??
                draft.editTimeline?.launchSnapshotDuration
            return Track(
                id: draft.id,
                editGroupID: draft.editGroupID,
                name: draft.name,
                filePath: draft.filePath,
                sourceMetadata: ProjectFileMetadata(fileURL: URL(fileURLWithPath: draft.filePath)),
                durationHint: durationHint,
                sourceOverview: sourceOverview,
                displayOverview: displayOverview ?? sourceOverview,
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
        projectMetadata: ProjectFileMetadata,
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
        self.windowLayout = windowLayout
        self.timelineViewport = timelineViewport
        self.masterVolume = masterVolume
        self.transcriptDisplayMode = transcriptDisplayMode
        self.tracks = tracks
    }

    var isDrawable: Bool {
        schemaVersion == Self.currentSchemaVersion &&
            tracks.contains { $0.displayOverview != nil || $0.sourceOverview != nil || $0.durationHint != nil }
    }

    func isCompatible(with projectURL: URL) -> Bool {
        let standardizedProjectPath = projectURL.standardizedFileURL.path
        guard projectPath == standardizedProjectPath else {
            return false
        }

        return projectMetadata.isCompatible(with: ProjectFileMetadata(projectURL: projectURL))
    }

    func validatedForLaunch(projectURL: URL) -> ProjectLaunchSnapshot {
        var snapshot = self
        snapshot.tracks = tracks.map { $0.validatedForLaunch() }
        return snapshot
    }
}

enum ProjectLaunchSnapshotStore {
    private static let fileExtension = "soundtime-launch-snapshot"
    static let firstPaintSynchronousByteLimit = 32 * 1_024 * 1_024

    static func load(for projectURL: URL) throws -> ProjectLaunchSnapshot {
        let data = try Data(contentsOf: snapshotURL(for: projectURL))
        let snapshot: ProjectLaunchSnapshot
        do {
            snapshot = try ProjectLaunchSnapshotBinaryCodec.decode(data)
        } catch ProjectLaunchSnapshotBinaryCodec.CodecError.notBinarySnapshot {
            snapshot = try JSONDecoder().decode(ProjectLaunchSnapshot.self, from: data)
        }
        guard snapshot.schemaVersion == ProjectLaunchSnapshot.currentSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard snapshot.isCompatible(with: projectURL) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return snapshot.validatedForLaunch(projectURL: projectURL)
    }

    static func loadForFirstPaintIfAvailable(for projectURL: URL) -> ProjectLaunchSnapshot? {
        let url = snapshotURL(for: projectURL)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let fileSize = (attributes[.size] as? NSNumber)?.intValue,
            fileSize > 0,
            fileSize <= firstPaintSynchronousByteLimit,
            let data = try? Data(contentsOf: url),
            ProjectLaunchSnapshotBinaryCodec.hasBinaryMagic(data),
            let snapshot = try? ProjectLaunchSnapshotBinaryCodec.decode(data),
            snapshot.schemaVersion == ProjectLaunchSnapshot.currentSchemaVersion,
            snapshot.isCompatible(with: projectURL)
        else {
            return nil
        }

        return snapshot.validatedForLaunch(projectURL: projectURL)
    }

    static func save(_ snapshot: ProjectLaunchSnapshot, for projectURL: URL) throws {
        let url = snapshotURL(for: projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try ProjectLaunchSnapshotBinaryCodec.encode(snapshot)
        try data.write(to: url, options: [.atomic])
    }

    static func remove(for projectURL: URL) {
        try? FileManager.default.removeItem(at: snapshotURL(for: projectURL))
    }

    static func snapshotURL(for projectURL: URL) -> URL {
        snapshotsDirectoryURL()
            .appendingPathComponent(SoundtimeProjectStore.stableProjectKey(for: projectURL))
            .appendingPathExtension(fileExtension)
            .standardizedFileURL
    }

    private static func snapshotsDirectoryURL() -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return baseDirectory
            .appendingPathComponent("Soundtime", isDirectory: true)
            .appendingPathComponent("LaunchSnapshots", isDirectory: true)
            .standardizedFileURL
    }
}

enum ProjectLaunchSnapshotBinaryCodec {
    enum CodecError: Error {
        case notBinarySnapshot
        case invalidPayload
    }

    private static let magic = Array("STLSNP02".utf8)
    private static let containerVersion: UInt32 = 1

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
        var sourceOverview: OverviewDescriptor?
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
        var windowLayout: SoundtimeProject.WindowLayout?
        var timelineViewport: SoundtimeProject.TimelineViewport?
        var masterVolume: Float?
        var transcriptDisplayMode: TranscriptTimelineDisplayMode?
        var tracks: [TrackManifest]
    }

    static func encode(_ snapshot: ProjectLaunchSnapshot) throws -> Data {
        var overviewBlob = Data()
        overviewBlob.reserveCapacity(snapshot.tracks.reduce(0) { total, track in
            total +
                (track.sourceOverview?.encodedBins.count ?? 0) +
                (track.displayOverview?.encodedBins.count ?? 0)
        })

        let trackManifests = snapshot.tracks.map { track in
            TrackManifest(
                id: track.id,
                editGroupID: track.editGroupID,
                name: track.name,
                filePath: track.filePath,
                sourceMetadata: track.sourceMetadata,
                durationHint: track.durationHint,
                sourceOverview: appendOverview(track.sourceOverview, to: &overviewBlob),
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
            schemaVersion: snapshot.schemaVersion,
            createdAt: snapshot.createdAt,
            projectPath: snapshot.projectPath,
            projectMetadata: snapshot.projectMetadata,
            windowLayout: snapshot.windowLayout,
            timelineViewport: snapshot.timelineViewport,
            masterVolume: snapshot.masterVolume,
            transcriptDisplayMode: snapshot.transcriptDisplayMode,
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

    static func decode(_ data: Data) throws -> ProjectLaunchSnapshot {
        guard data.count >= magic.count, Array(data.prefix(magic.count)) == magic else {
            throw CodecError.notBinarySnapshot
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
            ProjectLaunchSnapshot.Track(
                id: track.id,
                editGroupID: track.editGroupID,
                name: track.name,
                filePath: track.filePath,
                sourceMetadata: track.sourceMetadata,
                durationHint: track.durationHint,
                sourceOverview: try overviewPayload(track.sourceOverview, blobStart: blobStart, data: data),
                displayOverview: try overviewPayload(track.displayOverview, blobStart: blobStart, data: data),
                editTimeline: track.editTimeline,
                editableSource: track.editableSource,
                ownsSourceFile: track.ownsSourceFile,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed
            )
        }

        return ProjectLaunchSnapshot(
            schemaVersion: manifest.schemaVersion,
            createdAt: manifest.createdAt,
            projectPath: manifest.projectPath,
            projectMetadata: manifest.projectMetadata,
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

enum ProjectLaunchHydrationDefaults {
    static let firstRefinementBinCount = 131_072
    static let maximumConcurrentTrackHydrations = 2
}

struct ProjectLaunchVisualReadinessSummary: Sendable, Equatable {
    var trackCount: Int
    var drawableWaveformTrackCount: Int
    var durationOnlyTrackCount: Int
    var blankTrackCount: Int
    var playbackMetadataTrackCount: Int

    var hasTracks: Bool {
        trackCount > 0
    }

    var hasAnyDrawableWaveform: Bool {
        drawableWaveformTrackCount > 0
    }

    var isFirstFrameUsable: Bool {
        hasTracks && blankTrackCount == 0
    }

    var diagnosticFields: [String: String] {
        [
            "tracks": "\(trackCount)",
            "drawableWaveforms": "\(drawableWaveformTrackCount)",
            "durationOnly": "\(durationOnlyTrackCount)",
            "blank": "\(blankTrackCount)",
            "playbackMetadata": "\(playbackMetadataTrackCount)",
            "firstFrameUsable": "\(isFirstFrameUsable)",
        ]
    }
}

enum ProjectLaunchReadinessClassifier {
    static func summarize(snapshot: ProjectLaunchSnapshot) -> ProjectLaunchVisualReadinessSummary {
        summarize(snapshot.tracks.map { track in
            TrackReadiness(
                hasDrawableWaveform: track.displayOverview != nil || track.sourceOverview != nil,
                hasDurationHint: track.durationHint != nil ||
                    track.displayOverview?.duration.isFinite == true ||
                    track.sourceOverview?.duration.isFinite == true ||
                    track.editTimeline?.launchSnapshotDuration != nil ||
                    editableDuration(from: track.editableSource) != nil,
                hasPlaybackMetadata: track.editableSource != nil || track.editTimeline != nil
            )
        })
    }

    static func summarize(project: SoundtimeProject) -> ProjectLaunchVisualReadinessSummary {
        summarize(project.tracks.map { track in
            TrackReadiness(
                hasDrawableWaveform: track.waveformPreview?.sourceOverview.bins.isEmpty == false ||
                    track.waveformPreview?.displayOverview.bins.isEmpty == false,
                hasDurationHint: track.editTimeline?.launchSnapshotDuration != nil ||
                    track.waveformPreview?.sourceOverview.duration.isFinite == true ||
                    track.waveformPreview?.displayOverview.duration.isFinite == true ||
                    editableDuration(from: track.editableSource) != nil,
                hasPlaybackMetadata: track.editableSource != nil || track.editTimeline != nil
            )
        })
    }

    private struct TrackReadiness {
        var hasDrawableWaveform: Bool
        var hasDurationHint: Bool
        var hasPlaybackMetadata: Bool
    }

    private static func summarize(_ tracks: [TrackReadiness]) -> ProjectLaunchVisualReadinessSummary {
        var drawableWaveformTrackCount = 0
        var durationOnlyTrackCount = 0
        var blankTrackCount = 0
        var playbackMetadataTrackCount = 0

        for track in tracks {
            if track.hasDrawableWaveform {
                drawableWaveformTrackCount += 1
            } else if track.hasDurationHint {
                durationOnlyTrackCount += 1
            } else {
                blankTrackCount += 1
            }

            if track.hasPlaybackMetadata {
                playbackMetadataTrackCount += 1
            }
        }

        return ProjectLaunchVisualReadinessSummary(
            trackCount: tracks.count,
            drawableWaveformTrackCount: drawableWaveformTrackCount,
            durationOnlyTrackCount: durationOnlyTrackCount,
            blankTrackCount: blankTrackCount,
            playbackMetadataTrackCount: playbackMetadataTrackCount
        )
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
}

enum ProjectLaunchHydrationPlanner {
    static func orderedTracks(
        _ tracks: [SoundtimeProject.Track],
        activeTrackID: UUID?,
        selectedTrackIDs: Set<UUID>
    ) -> [SoundtimeProject.Track] {
        tracks.enumerated()
            .sorted { lhs, rhs in
                let lhsPriority = priority(
                    forTrackID: lhs.element.id,
                    order: lhs.offset,
                    activeTrackID: activeTrackID,
                    selectedTrackIDs: selectedTrackIDs
                )
                let rhsPriority = priority(
                    forTrackID: rhs.element.id,
                    order: rhs.offset,
                    activeTrackID: activeTrackID,
                    selectedTrackIDs: selectedTrackIDs
                )
                if lhsPriority == rhsPriority {
                    return lhs.offset < rhs.offset
                }
                return lhsPriority < rhsPriority
            }
            .map(\.element)
    }

    static func priority(
        forTrackID trackID: UUID,
        order: Int,
        activeTrackID: UUID?,
        selectedTrackIDs: Set<UUID>
    ) -> Int {
        if trackID == activeTrackID {
            return order
        }
        if selectedTrackIDs.contains(trackID) {
            return 1_000 + order
        }
        return 10_000 + order
    }
}

private extension AudioFileEditTimeline.PersistentState {
    var launchSnapshotDuration: TimeInterval? {
        guard sourceSampleRate > 0, sourceSampleRate.isFinite else {
            return nil
        }
        let frameCount = segments.reduce(0) { $0 + max($1.frameCount, 0) }
        return Double(frameCount) / sourceSampleRate
    }
}

private extension WaveformOverview {
    func reducedForLaunchSnapshot(maximumBinCount: Int) -> WaveformOverview {
        guard bins.count > maximumBinCount, maximumBinCount > 0 else {
            return self
        }

        let sourceCount = bins.count
        let binsPerOutput = Double(sourceCount) / Double(maximumBinCount)
        var reducedBins: [WaveformOverview.Bin] = []
        reducedBins.reserveCapacity(maximumBinCount)

        for outputIndex in 0..<maximumBinCount {
            let startIndex = min(
                max(Int((Double(outputIndex) * binsPerOutput).rounded(.down)), 0),
                sourceCount - 1
            )
            let rawEndIndex = Int((Double(outputIndex + 1) * binsPerOutput).rounded(.down))
            let endIndex = min(max(rawEndIndex, startIndex + 1), sourceCount)
            var accumulator = WaveformBinAccumulator()
            for sourceIndex in startIndex..<endIndex {
                accumulator.addBin(bins[sourceIndex])
            }
            reducedBins.append(accumulator.makeBin())
        }

        return WaveformOverview(duration: duration, bins: reducedBins)
    }
}
