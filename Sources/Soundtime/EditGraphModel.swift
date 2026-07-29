import Foundation

struct ImportedAudioAsset: Equatable, Sendable {
    let id: UUID
    let originalURL: URL
    let format: AudioAssetFormat
    let displayName: String

    init(
        id: UUID = UUID(),
        originalURL: URL,
        format: AudioAssetFormat,
        displayName: String
    ) {
        self.id = id
        self.originalURL = originalURL.standardizedFileURL
        self.format = format
        self.displayName = displayName
    }
}

struct EditableAudioSourceID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

struct EditableAudioSource: Equatable, Codable, Sendable {
    let id: EditableAudioSourceID
    let importedAssetID: UUID?
    let originalURL: URL
    let editableURL: URL
    let formatOrigin: AudioAssetFormat
    let sourceFrameCount: Int
    let sourceSampleRate: Double
    let channelCount: Int
    let ownsEditableFile: Bool

    init(
        importedAssetID: UUID? = nil,
        originalURL: URL,
        editableURL: URL,
        formatOrigin: AudioAssetFormat,
        fileInfo: WAVFileInfo,
        ownsEditableFile: Bool
    ) {
        self.id = Self.stableID(
            importedAssetID: importedAssetID,
            originalURL: originalURL,
            editableURL: editableURL,
            formatOrigin: formatOrigin,
            sourceFrameCount: fileInfo.frameCount,
            sourceSampleRate: fileInfo.sampleRate,
            channelCount: fileInfo.channelCount,
            fileDiscriminator: [
                "\(fileInfo.bitsPerSample)",
                "\(fileInfo.dataRange.count)",
            ].joined(separator: "|")
        )
        self.importedAssetID = importedAssetID
        self.originalURL = originalURL.standardizedFileURL
        self.editableURL = editableURL.standardizedFileURL
        self.formatOrigin = formatOrigin
        self.sourceFrameCount = fileInfo.frameCount
        self.sourceSampleRate = fileInfo.sampleRate
        self.channelCount = fileInfo.channelCount
        self.ownsEditableFile = ownsEditableFile
    }

    init(
        importedAssetID: UUID,
        originalURL: URL,
        editableURL: URL,
        formatOrigin: AudioAssetFormat,
        sourceFrameCount: Int,
        sourceSampleRate: Double,
        channelCount: Int,
        ownsEditableFile: Bool
    ) {
        self.id = Self.stableID(
            importedAssetID: importedAssetID,
            originalURL: originalURL,
            editableURL: editableURL,
            formatOrigin: formatOrigin,
            sourceFrameCount: sourceFrameCount,
            sourceSampleRate: sourceSampleRate,
            channelCount: channelCount,
            fileDiscriminator: nil
        )
        self.importedAssetID = importedAssetID
        self.originalURL = originalURL.standardizedFileURL
        self.editableURL = editableURL.standardizedFileURL
        self.formatOrigin = formatOrigin
        self.sourceFrameCount = sourceFrameCount
        self.sourceSampleRate = sourceSampleRate
        self.channelCount = channelCount
        self.ownsEditableFile = ownsEditableFile
    }

    var duration: TimeInterval {
        guard sourceSampleRate > 0 else {
            return 0
        }
        return Double(sourceFrameCount) / sourceSampleRate
    }

    var isUsableForEditing: Bool {
        sourceFrameCount > 0 && sourceSampleRate > 0 && sourceSampleRate.isFinite
    }

    func isCompatible(with timeline: AudioFileEditTimeline) -> Bool {
        timeline.sourceFrameCount == sourceFrameCount &&
            abs(timeline.sourceSampleRate - sourceSampleRate) < 0.001
    }

    static func stableID(
        importedAssetID: UUID? = nil,
        originalURL: URL,
        editableURL: URL,
        formatOrigin: AudioAssetFormat,
        fileInfo: WAVFileInfo
    ) -> EditableAudioSourceID {
        stableID(
            importedAssetID: importedAssetID,
            originalURL: originalURL,
            editableURL: editableURL,
            formatOrigin: formatOrigin,
            sourceFrameCount: fileInfo.frameCount,
            sourceSampleRate: fileInfo.sampleRate,
            channelCount: fileInfo.channelCount,
            fileDiscriminator: [
                "\(fileInfo.bitsPerSample)",
                "\(fileInfo.dataRange.count)",
            ].joined(separator: "|")
        )
    }

    private static func stableID(
        importedAssetID: UUID?,
        originalURL: URL,
        editableURL: URL,
        formatOrigin: AudioAssetFormat,
        sourceFrameCount: Int,
        sourceSampleRate: Double,
        channelCount: Int,
        fileDiscriminator: String?
    ) -> EditableAudioSourceID {
        if let importedAssetID {
            return EditableAudioSourceID(rawValue: "imported-asset|\(importedAssetID.uuidString.lowercased())")
        }

        let originalPath = originalURL.standardizedFileURL.path
        let editablePath = editableURL.standardizedFileURL.path
        let sampleRate = String(format: "%.3f", sourceSampleRate)
        var components = [
            "source",
            formatOrigin.rawValue,
            originalPath,
            editablePath,
            "\(sourceFrameCount)",
            sampleRate,
            "\(channelCount)",
        ]
        if let fileDiscriminator {
            components.append(fileDiscriminator)
        }
        return EditableAudioSourceID(rawValue: components.joined(separator: "|"))
    }
}

struct TimelineClipSegment: Equatable, Codable, Sendable {
    let outputStartFrame: Int
    let sourceStartFrame: Int
    let frameCount: Int
    let gainStart: Float
    let gainEnd: Float
    let startsNewClip: Bool

    var outputEndFrame: Int {
        outputStartFrame + frameCount
    }

    var sourceEndFrame: Int {
        sourceStartFrame + frameCount
    }
}

struct TrackArrangement: Sendable {
    let trackID: UUID
    let sourceID: EditableAudioSourceID
    var timeline: AudioFileEditTimeline

    var duration: TimeInterval {
        timeline.duration
    }

    var frameCount: Int {
        timeline.frameCount
    }

    var clipSegments: [TimelineClipSegment] {
        timeline.playbackSegments.map { segment in
            TimelineClipSegment(
                outputStartFrame: segment.outputStartFrame,
                sourceStartFrame: segment.sourceStartFrame,
                frameCount: segment.frameCount,
                gainStart: segment.gainStart,
                gainEnd: segment.gainEnd,
                startsNewClip: segment.startsNewClip
            )
        }
    }

    func deleting(_ selection: TimelineSelection) -> (arrangement: TrackArrangement, deletedFrameCount: Int) {
        var editedTimeline = timeline
        let deletedFrameCount = editedTimeline.delete(selection)
        return (
            TrackArrangement(
                trackID: trackID,
                sourceID: sourceID,
                timeline: editedTimeline
            ),
            deletedFrameCount
        )
    }

    func withTimeline(_ timeline: AudioFileEditTimeline) -> TrackArrangement {
        TrackArrangement(
            trackID: trackID,
            sourceID: sourceID,
            timeline: timeline
        )
    }
}

struct EditGraph: Sendable {
    var sources: [EditableAudioSourceID: EditableAudioSource]
    var arrangements: [UUID: TrackArrangement]

    init(
        sources: [EditableAudioSource] = [],
        arrangements: [TrackArrangement] = []
    ) {
        self.sources = Self.canonicalSourceCatalog(from: sources)
        self.arrangements = Self.canonicalArrangementCatalog(from: arrangements)
    }

    private static func canonicalSourceCatalog(
        from sources: [EditableAudioSource]
    ) -> [EditableAudioSourceID: EditableAudioSource] {
        var catalog: [EditableAudioSourceID: EditableAudioSource] = [:]
        catalog.reserveCapacity(sources.count)
        for source in sources {
            if let existingSource = catalog[source.id] {
                catalog[source.id] = canonicalEditableSource(existingSource, source)
            } else {
                catalog[source.id] = source
            }
        }
        return catalog
    }

    private static func canonicalEditableSource(
        _ lhs: EditableAudioSource,
        _ rhs: EditableAudioSource
    ) -> EditableAudioSource {
        if lhs.importedAssetID == nil, rhs.importedAssetID != nil {
            return rhs
        }
        if !lhs.ownsEditableFile, rhs.ownsEditableFile {
            return rhs
        }
        return lhs
    }

    private static func canonicalArrangementCatalog(
        from arrangements: [TrackArrangement]
    ) -> [UUID: TrackArrangement] {
        var catalog: [UUID: TrackArrangement] = [:]
        catalog.reserveCapacity(arrangements.count)
        for arrangement in arrangements {
            catalog[arrangement.trackID] = arrangement
        }
        return catalog
    }

    func arrangement(for trackID: UUID) -> TrackArrangement? {
        arrangements[trackID]
    }

    func source(for arrangement: TrackArrangement) -> EditableAudioSource? {
        sources[arrangement.sourceID]
    }

    func source(for trackID: UUID) -> EditableAudioSource? {
        guard let arrangement = arrangements[trackID] else {
            return nil
        }
        return sources[arrangement.sourceID]
    }

    mutating func upsert(source: EditableAudioSource, arrangement: TrackArrangement) {
        sources[source.id] = source
        arrangements[arrangement.trackID] = arrangement
    }

    mutating func upsert(source: EditableAudioSource, trackID: UUID, timeline: AudioFileEditTimeline) {
        upsert(
            source: source,
            arrangement: TrackArrangement(
                trackID: trackID,
                sourceID: source.id,
                timeline: timeline
            )
        )
    }

    mutating func updateArrangement(trackID: UUID, timeline: AudioFileEditTimeline) -> TrackArrangement? {
        guard let arrangement = arrangements[trackID] else {
            return nil
        }

        let editedArrangement = arrangement.withTimeline(timeline)
        arrangements[trackID] = editedArrangement
        return editedArrangement
    }

    mutating func removeArrangement(for trackID: UUID) {
        arrangements.removeValue(forKey: trackID)
    }

    mutating func keepOnlyArrangements(for trackIDs: Set<UUID>) {
        arrangements = arrangements.filter { trackIDs.contains($0.key) }
        let liveSourceIDs = Set(arrangements.values.map(\.sourceID))
        sources = sources.filter { liveSourceIDs.contains($0.key) }
    }

    mutating func merge(_ other: EditGraph) {
        for source in other.sources.values {
            sources[source.id] = source
        }
        for arrangement in other.arrangements.values {
            arrangements[arrangement.trackID] = arrangement
        }
    }

    var sortedSources: [EditableAudioSource] {
        sources.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    var sortedArrangements: [TrackArrangement] {
        arrangements.values.sorted { $0.trackID.uuidString < $1.trackID.uuidString }
    }

    var isEmpty: Bool {
        sources.isEmpty && arrangements.isEmpty
    }
}
