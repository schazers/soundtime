import Foundation

struct SoundtimeProject: Codable, Sendable {
    static let currentSchemaVersion = 9
    static let launchWaveformPreviewBinCount = 4_096

    struct WindowLayout: Codable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    struct TimelineViewport: Codable, Sendable {
        var startProgress: Float
        var durationProgress: Float
    }

    struct TimelineSelectionRange: Codable, Sendable {
        var startProgress: Double
        var endProgress: Double
        var trackID: UUID?
    }

    struct SilenceReviewCandidate: Codable, Sendable {
        var id: UUID
        var trackID: UUID
        var trackEditRevision: Int
        var displaySelection: TimelineSelectionRange
        var editSelection: TimelineSelectionRange
        var frameStart: Int
        var frameEnd: Int
        var confidence: Float
        var reason: String
        var estimatedRemovedDuration: TimeInterval
    }

    struct SilenceReviewState: Codable, Sendable {
        var candidates: [SilenceReviewCandidate]
        var activeCandidateID: UUID?
    }

    struct WaveformPreview: Codable, Sendable {
        struct FileFingerprint: Codable, Sendable, Equatable {
            var frameCount: Int
            var sampleRate: Double
            var channelCount: Int
            var bitsPerSample: Int
            var dataByteCount: Int
            var fileSize: Int64?
            var modificationTime: TimeInterval?

            init(
                frameCount: Int,
                sampleRate: Double,
                channelCount: Int,
                bitsPerSample: Int,
                dataByteCount: Int,
                fileSize: Int64?,
                modificationTime: TimeInterval?
            ) {
                self.frameCount = frameCount
                self.sampleRate = sampleRate
                self.channelCount = channelCount
                self.bitsPerSample = bitsPerSample
                self.dataByteCount = dataByteCount
                self.fileSize = fileSize
                self.modificationTime = modificationTime
            }

            init(fileInfo: WAVFileInfo) {
                frameCount = fileInfo.frameCount
                sampleRate = fileInfo.sampleRate
                channelCount = fileInfo.channelCount
                bitsPerSample = fileInfo.bitsPerSample
                dataByteCount = fileInfo.dataRange.count

                let resourceValues = try? fileInfo.url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                )
                fileSize = resourceValues?.fileSize.map(Int64.init)
                modificationTime = resourceValues?.contentModificationDate?.timeIntervalSince1970
            }

            func matches(fileInfo: WAVFileInfo) -> Bool {
                guard
                    frameCount == fileInfo.frameCount,
                    abs(sampleRate - fileInfo.sampleRate) < 0.001,
                    channelCount == fileInfo.channelCount,
                    bitsPerSample == fileInfo.bitsPerSample,
                    dataByteCount == fileInfo.dataRange.count
                else {
                    return false
                }

                let currentValues = try? fileInfo.url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                )
                if
                    let fileSize,
                    let currentFileSize = currentValues?.fileSize.map(Int64.init),
                    fileSize != currentFileSize
                {
                    return false
                }
                return true
            }

            var stableSummary: String {
                [
                    "\(frameCount)",
                    String(format: "%.3f", sampleRate),
                    "\(channelCount)",
                    "\(bitsPerSample)",
                    "\(dataByteCount)",
                    fileSize.map(String.init) ?? "-",
                    modificationTime.map { String(format: "%.3f", $0) } ?? "-",
                ].joined(separator: "|")
            }
        }

        struct Overview: Codable, Sendable {
            struct Bin: Codable, Sendable {
                var minimumSample: Float
                var maximumSample: Float
                var rmsSample: Float
                var lowEnergy: Float
                var midEnergy: Float
                var highEnergy: Float

                init(_ bin: WaveformOverview.Bin) {
                    minimumSample = bin.minimumSample
                    maximumSample = bin.maximumSample
                    rmsSample = bin.rmsSample
                    lowEnergy = bin.lowEnergy
                    midEnergy = bin.midEnergy
                    highEnergy = bin.highEnergy
                }

                var waveformBin: WaveformOverview.Bin {
                    WaveformOverview.Bin(
                        minimumSample: minimumSample,
                        maximumSample: maximumSample,
                        rmsSample: rmsSample,
                        lowEnergy: lowEnergy,
                        midEnergy: midEnergy,
                        highEnergy: highEnergy
                    )
                }
            }

            var duration: TimeInterval
            var bins: [Bin]

            init(_ overview: WaveformOverview) {
                duration = overview.duration
                bins = overview.bins.map(Bin.init)
            }

            var waveformOverview: WaveformOverview {
                WaveformOverview(
                    duration: duration,
                    bins: bins.map(\.waveformBin)
                )
            }
        }

        var fileFingerprint: FileFingerprint
        var sourceOverview: Overview
        var displayOverview: Overview

        init?(
            sourceOverview: WaveformOverview?,
            displayOverview: WaveformOverview?,
            fileInfo: WAVFileInfo,
            maximumBinCount: Int = SoundtimeProject.launchWaveformPreviewBinCount
        ) {
            guard let displayOverview, !displayOverview.isEmpty else {
                return nil
            }

            let sourceOverview = sourceOverview?.isEmpty == false ? sourceOverview! : displayOverview
            fileFingerprint = FileFingerprint(fileInfo: fileInfo)
            self.sourceOverview = Overview(Self.reducedOverview(
                sourceOverview,
                maximumBinCount: maximumBinCount
            ))
            self.displayOverview = Overview(Self.reducedOverview(
                displayOverview,
                maximumBinCount: maximumBinCount
            ))
        }

        init?(
            sourceOverview: WaveformOverview?,
            displayOverview: WaveformOverview?,
            importedFingerprint: AudioImportFingerprint,
            maximumBinCount: Int = SoundtimeProject.launchWaveformPreviewBinCount
        ) {
            guard let displayOverview, !displayOverview.isEmpty else {
                return nil
            }

            let sourceOverview = sourceOverview?.isEmpty == false ? sourceOverview! : displayOverview
            fileFingerprint = FileFingerprint(
                frameCount: Int(importedFingerprint.frameCount),
                sampleRate: importedFingerprint.sampleRate,
                channelCount: importedFingerprint.channelCount,
                bitsPerSample: 0,
                dataByteCount: Int(clamping: importedFingerprint.fileSize),
                fileSize: importedFingerprint.fileSize,
                modificationTime: importedFingerprint.modificationTime
            )
            self.sourceOverview = Overview(Self.reducedOverview(
                sourceOverview,
                maximumBinCount: maximumBinCount
            ))
            self.displayOverview = Overview(Self.reducedOverview(
                displayOverview,
                maximumBinCount: maximumBinCount
            ))
        }

        func isValid(for fileInfo: WAVFileInfo) -> Bool {
            fileFingerprint.matches(fileInfo: fileInfo) &&
                sourceOverview.duration.isFinite &&
                displayOverview.duration.isFinite &&
                !sourceOverview.bins.isEmpty &&
                !displayOverview.bins.isEmpty
        }

        private static func reducedOverview(
            _ overview: WaveformOverview,
            maximumBinCount: Int
        ) -> WaveformOverview {
            guard overview.bins.count > maximumBinCount, maximumBinCount > 0 else {
                return overview
            }

            let sourceBins = overview.bins
            let sourceCount = sourceBins.count
            var bins: [WaveformOverview.Bin] = []
            bins.reserveCapacity(maximumBinCount)
            let binsPerOutput = Double(sourceCount) / Double(maximumBinCount)

            for outputIndex in 0..<maximumBinCount {
                let startIndex = min(max(Int((Double(outputIndex) * binsPerOutput).rounded(.down)), 0), sourceCount - 1)
                let rawEndIndex = Int((Double(outputIndex + 1) * binsPerOutput).rounded(.down))
                let endIndex = min(max(rawEndIndex, startIndex + 1), sourceCount)
                var accumulator = WaveformBinAccumulator()
                for sourceIndex in startIndex..<endIndex {
                    accumulator.addBin(sourceBins[sourceIndex])
                }
                bins.append(accumulator.makeBin())
            }

            return WaveformOverview(duration: overview.duration, bins: bins)
        }
    }

    struct Track: Codable, Sendable {
        struct ImportedAssetState: Codable, Sendable {
            var assetID: UUID
            var originalFilePath: String
            var format: AudioAssetFormat
            var fingerprint: AudioImportFingerprint
            var stage: AudioImportStage

            init(
                assetID: UUID,
                originalURL: URL,
                format: AudioAssetFormat,
                fingerprint: AudioImportFingerprint,
                stage: AudioImportStage
            ) {
                self.assetID = assetID
                originalFilePath = originalURL.standardizedFileURL.path
                self.format = format
                self.fingerprint = fingerprint
                self.stage = stage
            }
        }

        struct EditableSource: Codable, Sendable {
            var importedAssetID: UUID?
            var originalFilePath: String
            var editableFilePath: String
            var formatOrigin: AudioAssetFormat
            var sourceFrameCount: Int
            var sourceSampleRate: Double
            var channelCount: Int
            var ownsEditableFile: Bool

            init(_ source: EditableAudioSource) {
                importedAssetID = source.importedAssetID
                originalFilePath = source.originalURL.path
                editableFilePath = source.editableURL.path
                formatOrigin = source.formatOrigin
                sourceFrameCount = source.sourceFrameCount
                sourceSampleRate = source.sourceSampleRate
                channelCount = source.channelCount
                ownsEditableFile = source.ownsEditableFile
            }

            func editableAudioSource(fileInfo: WAVFileInfo) -> EditableAudioSource? {
                guard
                    sourceFrameCount == fileInfo.frameCount,
                    abs(sourceSampleRate - fileInfo.sampleRate) < 0.001,
                    channelCount == fileInfo.channelCount
                else {
                    return nil
                }

                let editableURL = URL(fileURLWithPath: editableFilePath).standardizedFileURL
                guard editableURL == fileInfo.url.standardizedFileURL else {
                    return nil
                }

                return EditableAudioSource(
                    importedAssetID: importedAssetID,
                    originalURL: URL(fileURLWithPath: originalFilePath),
                    editableURL: editableURL,
                    formatOrigin: formatOrigin,
                    fileInfo: fileInfo,
                    ownsEditableFile: ownsEditableFile
                )
            }

            func editableAudioSource() -> EditableAudioSource? {
                guard
                    let importedAssetID,
                    sourceFrameCount >= 0,
                    sourceSampleRate.isFinite,
                    sourceSampleRate > 0,
                    channelCount > 0
                else {
                    return nil
                }

                return EditableAudioSource(
                    importedAssetID: importedAssetID,
                    originalURL: URL(fileURLWithPath: originalFilePath),
                    editableURL: URL(fileURLWithPath: editableFilePath),
                    formatOrigin: formatOrigin,
                    sourceFrameCount: sourceFrameCount,
                    sourceSampleRate: sourceSampleRate,
                    channelCount: channelCount,
                    ownsEditableFile: ownsEditableFile
                )
            }
        }

        var id: UUID
        var editGroupID: UUID? = nil
        var name: String
        var filePath: String
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool
        var editTimeline: AudioFileEditTimeline.PersistentState?
        var editableSource: EditableSource? = nil
        var waveformPreview: WaveformPreview? = nil
        var ownsSourceFile: Bool? = nil
        var transcript: TranscriptDocument? = nil
        var importedAssetState: ImportedAssetState? = nil

        var audioSourceCandidateURLs: [URL] {
            let paths = [
                filePath,
                importedAssetState?.originalFilePath,
                editableSource?.editableFilePath,
                editableSource?.originalFilePath,
            ]
            var seenPaths = Set<String>()
            return paths.compactMap { path in
                guard let path, !path.isEmpty else {
                    return nil
                }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard seenPaths.insert(url.path).inserted else {
                    return nil
                }
                return url
            }
        }
    }

    var projectID: UUID
    var editGraphRevision: UInt64
    var visualRevision: UInt64
    var launchStateRevision: UInt64
    var tracks: [Track]
    var windowLayout: WindowLayout?
    var masterVolume: Float?
    var timelineViewport: TimelineViewport?
    var silenceReviewState: SilenceReviewState?
    var transcriptionJobs: [TranscriptionJob.PersistentSnapshot]?
    var transcriptDisplayMode: TranscriptTimelineDisplayMode?

    var schemaVersion: Int

    init(
        projectID: UUID = UUID(),
        editGraphRevision: UInt64 = 1,
        visualRevision: UInt64 = 1,
        launchStateRevision: UInt64 = 1,
        tracks: [Track],
        windowLayout: WindowLayout?,
        masterVolume: Float?,
        timelineViewport: TimelineViewport?,
        silenceReviewState: SilenceReviewState? = nil,
        transcriptionJobs: [TranscriptionJob.PersistentSnapshot]? = nil,
        transcriptDisplayMode: TranscriptTimelineDisplayMode? = nil,
        schemaVersion: Int = SoundtimeProject.currentSchemaVersion
    ) {
        self.projectID = projectID
        self.editGraphRevision = max(editGraphRevision, 1)
        self.visualRevision = max(visualRevision, 1)
        self.launchStateRevision = max(launchStateRevision, 1)
        self.tracks = tracks
        self.windowLayout = windowLayout
        self.masterVolume = masterVolume
        self.timelineViewport = timelineViewport
        self.silenceReviewState = silenceReviewState
        self.transcriptionJobs = transcriptionJobs
        self.transcriptDisplayMode = transcriptDisplayMode
        self.schemaVersion = schemaVersion
    }

    fileprivate func mergingMissingWaveformPreviews(from savedProject: SoundtimeProject) -> SoundtimeProject {
        var savedPreviewsByTrackKey: [String: WaveformPreview] = [:]
        var savedPreviewsByTrackID: [UUID: WaveformPreview] = [:]
        for track in savedProject.tracks {
            guard let waveformPreview = track.waveformPreview else {
                continue
            }

            savedPreviewsByTrackKey[SoundtimeProjectStore.waveformPreviewMergeKey(for: track)] = waveformPreview
            savedPreviewsByTrackID[track.id] = waveformPreview
        }

        var mergedProject = self
        mergedProject.tracks = tracks.map { track in
            guard track.waveformPreview == nil else {
                return track
            }

            guard
                let waveformPreview = savedPreviewsByTrackKey[SoundtimeProjectStore.waveformPreviewMergeKey(for: track)] ??
                    savedPreviewsByTrackID[track.id]
            else {
                return track
            }

            var mergedTrack = track
            mergedTrack.waveformPreview = waveformPreview
            return mergedTrack
        }
        return mergedProject
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projectID
        case editGraphRevision
        case visualRevision
        case launchStateRevision
        case tracks
        case windowLayout
        case masterVolume
        case timelineViewport
        case silenceReviewState
        case transcriptionJobs
        case transcriptDisplayMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID) ?? UUID()
        editGraphRevision = max(try container.decodeIfPresent(UInt64.self, forKey: .editGraphRevision) ?? 1, 1)
        visualRevision = max(try container.decodeIfPresent(UInt64.self, forKey: .visualRevision) ?? 1, 1)
        launchStateRevision = max(try container.decodeIfPresent(UInt64.self, forKey: .launchStateRevision) ?? 1, 1)
        tracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        windowLayout = try container.decodeIfPresent(WindowLayout.self, forKey: .windowLayout)
        masterVolume = try container.decodeIfPresent(Float.self, forKey: .masterVolume)
        timelineViewport = try container.decodeIfPresent(TimelineViewport.self, forKey: .timelineViewport)
        silenceReviewState = try container.decodeIfPresent(SilenceReviewState.self, forKey: .silenceReviewState)
        transcriptionJobs = try container.decodeIfPresent(
            [TranscriptionJob.PersistentSnapshot].self,
            forKey: .transcriptionJobs
        )
        transcriptDisplayMode = try container.decodeIfPresent(
            TranscriptTimelineDisplayMode.self,
            forKey: .transcriptDisplayMode
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(editGraphRevision, forKey: .editGraphRevision)
        try container.encode(visualRevision, forKey: .visualRevision)
        try container.encode(launchStateRevision, forKey: .launchStateRevision)
        try container.encode(tracks, forKey: .tracks)
        try container.encodeIfPresent(windowLayout, forKey: .windowLayout)
        try container.encodeIfPresent(masterVolume, forKey: .masterVolume)
        try container.encodeIfPresent(timelineViewport, forKey: .timelineViewport)
        try container.encodeIfPresent(silenceReviewState, forKey: .silenceReviewState)
        try container.encodeIfPresent(transcriptionJobs, forKey: .transcriptionJobs)
        try container.encodeIfPresent(transcriptDisplayMode, forKey: .transcriptDisplayMode)
    }
}

struct SoundtimeProjectLaunchStateOverlay: Codable, Sendable {
    struct TrackState: Codable, Sendable {
        var id: UUID
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool
    }

    var createdAt: TimeInterval
    var windowLayout: SoundtimeProject.WindowLayout?
    var timelineViewport: SoundtimeProject.TimelineViewport?
    var masterVolume: Float?
    var transcriptDisplayMode: TranscriptTimelineDisplayMode?
    var tracks: [TrackState]
}

struct SoundtimeRecoveredAutosave: Sendable {
    var project: SoundtimeProject
    var canonicalProjectURL: URL?
}

enum SoundtimeProjectStore {
    static let fileExtension = "soundtime"
    static let autosaveFileExtension = "soundtime-autosave"
    static let maximumRecentProjectCount = 8
    private static let persistenceSuiteEnvironmentKey = "SOUNDTIME_PERSISTENCE_SUITE"
    private static let persistenceRootEnvironmentKey = "SOUNDTIME_PERSISTENCE_ROOT"
    private static let lastProjectURLKey = "Soundtime.lastProjectURL"
    private static let recentProjectURLPathsKey = "Soundtime.recentProjectURLPaths"
    private static let projectWindowLayoutKeyPrefix = "Soundtime.projectWindowLayout."
    private static let projectTimelineViewportKeyPrefix = "Soundtime.projectTimelineViewport."
    private static let projectLaunchStateOverlayKeyPrefix = "Soundtime.projectLaunchStateOverlay."
    nonisolated(unsafe) private static let defaults: UserDefaults = {
        guard
            let suiteName = ProcessInfo.processInfo.environment[persistenceSuiteEnvironmentKey],
            !suiteName.isEmpty,
            let defaults = UserDefaults(suiteName: suiteName)
        else {
            return .standard
        }
        return defaults
    }()

    private struct AutosaveEnvelope: Codable {
        static let currentFormatVersion = 1

        var formatVersion: Int
        var sourceProjectPath: String?
        var autosaveID: UUID
        var savedAt: TimeInterval
        var project: SoundtimeProject
    }

    static func configurePersistenceForCommandLine(arguments: [String]) {
        guard arguments.dropFirst().contains(where: isAutomationCommandLineArgument) else {
            return
        }

        let processID = ProcessInfo.processInfo.processIdentifier
        let suiteName = "com.soundtime.automation.\(processID)"
        let persistenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Soundtime-Automation", isDirectory: true)
            .appendingPathComponent(String(processID), isDirectory: true)
            .standardizedFileURL
        setenv(persistenceSuiteEnvironmentKey, suiteName, 1)
        setenv(persistenceRootEnvironmentKey, persistenceRoot.path, 1)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private static func isAutomationCommandLineArgument(_ argument: String) -> Bool {
        guard argument.hasPrefix("--") else {
            return false
        }
        return argument.contains("smoke") ||
            argument.contains("gate") ||
            argument.contains("fixture") ||
            argument.contains("baseline") ||
            argument.contains("production-readiness")
    }

    static func load(from url: URL) throws -> SoundtimeProject {
        if url.pathExtension == autosaveFileExtension {
            return try loadRecoveredAutosave(from: url).project
        }
        let migratedProject = try loadRaw(from: url)
        return TranscriptSidecarStore.projectResolvingSidecars(migratedProject, projectURL: url)
    }

    static func loadLaunchPreviewRecoveringAutosave(from url: URL) throws -> SoundtimeProject {
        let autosaveURL = autosaveURL(for: url)
        let savedProjectResult = Result {
            try loadRaw(from: url)
        }
        guard
            FileManager.default.fileExists(atPath: autosaveURL.path),
            autosaveURL.isNewerThan(url)
        else {
            return try savedProjectResult.get()
        }

        let autosaveProject = try loadAutosaveRaw(from: autosaveURL).project
        guard case let .success(savedProject) = savedProjectResult else {
            return autosaveProject
        }

        return autosaveProject.mergingMissingWaveformPreviews(from: savedProject)
    }

    static func loadLaunchPreview(from url: URL) throws -> SoundtimeProject {
        if url.pathExtension == autosaveFileExtension {
            return try loadAutosaveRaw(from: url).project
        }
        return try loadRaw(from: url)
    }

    private static func loadRaw(from url: URL) throws -> SoundtimeProject {
        let data = try Data(contentsOf: url)
        return migrate(try JSONDecoder().decode(SoundtimeProject.self, from: data))
    }

    static func loadRecoveringAutosave(from url: URL) throws -> SoundtimeProject {
        let autosaveURL = autosaveURL(for: url)
        let savedProjectResult = Result {
            try load(from: url)
        }
        guard
            FileManager.default.fileExists(atPath: autosaveURL.path),
            autosaveURL.isNewerThan(url)
        else {
            return try savedProjectResult.get()
        }

        let autosaveProject = try loadRecoveredAutosave(from: autosaveURL).project
        guard case let .success(savedProject) = savedProjectResult else {
            return autosaveProject
        }

        return autosaveProject.mergingMissingWaveformPreviews(from: savedProject)
    }

    static func save(_ project: SoundtimeProject, to url: URL) throws {
        let migratedProject = migrate(project)
        let projectWithSidecars = try TranscriptSidecarStore.projectWithSidecarReferences(
            migratedProject,
            projectURL: url
        )
        try write(projectWithSidecars, to: url)
        rememberLastProjectURL(url)
    }

    @discardableResult
    static func saveAutosave(
        _ project: SoundtimeProject,
        projectURL: URL?,
        autosaveID: UUID
    ) throws -> URL {
        let url = autosaveURL(projectURL: projectURL, autosaveID: autosaveID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let migratedProject = migrate(project)
        let projectWithSidecars = try TranscriptSidecarStore.projectWithSidecarReferences(
            migratedProject,
            projectURL: url
        )
        let envelope = AutosaveEnvelope(
            formatVersion: AutosaveEnvelope.currentFormatVersion,
            sourceProjectPath: projectURL?.standardizedFileURL.path,
            autosaveID: autosaveID,
            savedAt: Date().timeIntervalSince1970,
            project: projectWithSidecars
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(envelope).write(to: url, options: [.atomic])
        return url
    }

    static func loadRecoveredAutosave(from url: URL) throws -> SoundtimeRecoveredAutosave {
        let decoded = try loadAutosaveRaw(from: url)
        let project = TranscriptSidecarStore.projectResolvingSidecars(
            decoded.project,
            projectURL: url
        )
        let canonicalProjectURL = decoded.sourceProjectPath
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        return SoundtimeRecoveredAutosave(
            project: project,
            canonicalProjectURL: canonicalProjectURL
        )
    }

    static func canonicalProjectURL(forAutosaveAt url: URL) -> URL? {
        guard
            let decoded = try? loadAutosaveRaw(from: url),
            let sourceProjectPath = decoded.sourceProjectPath
        else {
            return nil
        }
        let projectURL = URL(fileURLWithPath: sourceProjectPath).standardizedFileURL
        return FileManager.default.fileExists(atPath: projectURL.path) ? projectURL : nil
    }

    static var usesIsolatedAutomationPersistence: Bool {
        ProcessInfo.processInfo.environment[persistenceSuiteEnvironmentKey] != nil
    }

    static func removeAutosave(projectURL: URL?, autosaveID: UUID) {
        let urls = [
            autosaveURL(projectURL: projectURL, autosaveID: autosaveID),
            autosaveURL(projectURL: nil, autosaveID: autosaveID),
        ]
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func recoverableAutosaveURLs() -> [URL] {
        let directory = autosavesDirectoryURL()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == autosaveFileExtension }
            .filter { !isLegacyAutomationAutosave($0) }
            .sorted { $0.modificationDateOrDistantPast > $1.modificationDateOrDistantPast }
    }

    static func recoverableAutosaveURL(for projectURL: URL) -> URL? {
        let autosaveURL = autosaveURL(for: projectURL)
        guard
            FileManager.default.fileExists(atPath: autosaveURL.path),
            autosaveURL.isNewerThan(projectURL)
        else {
            return nil
        }
        return autosaveURL
    }

    private static func write(_ project: SoundtimeProject, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: url, options: [.atomic])
    }

    private static func migrate(_ project: SoundtimeProject) -> SoundtimeProject {
        guard project.schemaVersion < SoundtimeProject.currentSchemaVersion else {
            return project
        }

        var migratedProject = project
        migratedProject.schemaVersion = SoundtimeProject.currentSchemaVersion
        return migratedProject
    }

    fileprivate static func waveformPreviewMergeKey(for track: SoundtimeProject.Track) -> String {
        let standardizedPath = URL(fileURLWithPath: track.filePath).standardizedFileURL.path
        return "\(track.id.uuidString)|\(standardizedPath)"
    }

    static func rememberLastProjectURL(_ url: URL) {
        defaults.set(url.path, forKey: lastProjectURLKey)
        rememberRecentProjectURL(url)
    }

    static func lastProjectURL() -> URL? {
        guard let path = defaults.string(forKey: lastProjectURLKey), !path.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: path)
    }

    static func forgetLastProjectURL() {
        defaults.removeObject(forKey: lastProjectURLKey)
    }

    static func rememberRecentProjectURL(_ url: URL) {
        let path = url.path
        var paths = recentProjectURLPaths().filter { $0 != path }
        paths.insert(path, at: 0)
        if paths.count > maximumRecentProjectCount {
            paths = Array(paths.prefix(maximumRecentProjectCount))
        }

        defaults.set(paths, forKey: recentProjectURLPathsKey)
    }

    static func recentProjectURLs() -> [URL] {
        recentProjectURLPaths().map(URL.init(fileURLWithPath:))
    }

    static func clearRecentProjectURLs() {
        defaults.removeObject(forKey: recentProjectURLPathsKey)
        defaults.removeObject(forKey: lastProjectURLKey)
    }

    static func synchronizePersistence() {
        defaults.synchronize()
    }

    static func removeAutomationArtifactsFromUserHistory() {
        guard ProcessInfo.processInfo.environment[persistenceSuiteEnvironmentKey] == nil else {
            return
        }

        let paths = defaults.stringArray(forKey: recentProjectURLPathsKey) ?? []
        let filteredPaths = paths.filter { !isKnownAutomationArtifactPath($0) }
        if filteredPaths != paths {
            defaults.set(filteredPaths, forKey: recentProjectURLPathsKey)
        }

        if
            let lastProjectPath = defaults.string(forKey: lastProjectURLKey),
            isKnownAutomationArtifactPath(lastProjectPath)
        {
            defaults.removeObject(forKey: lastProjectURLKey)
        }
    }

    static func rememberWindowLayout(_ layout: SoundtimeProject.WindowLayout, for projectURL: URL) {
        guard let data = try? JSONEncoder().encode(layout) else {
            return
        }

        defaults.set(data, forKey: projectWindowLayoutKey(for: projectURL))
    }

    static func rememberedWindowLayout(for projectURL: URL) -> SoundtimeProject.WindowLayout? {
        guard let data = defaults.data(forKey: projectWindowLayoutKey(for: projectURL)) else {
            return nil
        }

        return try? JSONDecoder().decode(SoundtimeProject.WindowLayout.self, from: data)
    }

    static func rememberTimelineViewport(
        _ viewport: SoundtimeProject.TimelineViewport,
        for projectURL: URL
    ) {
        guard let data = try? JSONEncoder().encode(viewport) else {
            return
        }

        defaults.set(data, forKey: projectTimelineViewportKey(for: projectURL))
    }

    static func rememberedTimelineViewport(for projectURL: URL) -> SoundtimeProject.TimelineViewport? {
        guard let data = defaults.data(forKey: projectTimelineViewportKey(for: projectURL)) else {
            return nil
        }

        return try? JSONDecoder().decode(SoundtimeProject.TimelineViewport.self, from: data)
    }

    static func rememberLaunchStateOverlay(
        _ overlay: SoundtimeProjectLaunchStateOverlay,
        for projectURL: URL
    ) {
        guard let data = try? JSONEncoder().encode(overlay) else {
            return
        }

        defaults.set(data, forKey: projectLaunchStateOverlayKey(for: projectURL))
    }

    static func rememberedLaunchStateOverlay(for projectURL: URL) -> SoundtimeProjectLaunchStateOverlay? {
        guard let data = defaults.data(forKey: projectLaunchStateOverlayKey(for: projectURL)) else {
            return nil
        }

        return try? JSONDecoder().decode(SoundtimeProjectLaunchStateOverlay.self, from: data)
    }

    private static func recentProjectURLPaths() -> [String] {
        (defaults.stringArray(forKey: recentProjectURLPathsKey) ?? [])
            .filter { !$0.isEmpty }
    }

    private static func loadAutosaveRaw(
        from url: URL
    ) throws -> (project: SoundtimeProject, sourceProjectPath: String?) {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(AutosaveEnvelope.self, from: data) {
            return (migrate(envelope.project), envelope.sourceProjectPath)
        }
        return (migrate(try decoder.decode(SoundtimeProject.self, from: data)), nil)
    }

    private static func isKnownAutomationArtifactPath(_ path: String) -> Bool {
        let lowercasedPath = path.lowercased()
        return lowercasedPath.contains("soundtime-transcript-sidecar-smoke-") ||
            lowercasedPath.contains("soundtimetimelineuxsmoke-") ||
            lowercasedPath.contains("soundtimestartupcloselifecycle-") ||
            lowercasedPath.contains("soundtimeaudioexportsmoke-") ||
            lowercasedPath.contains("soundtimeaudioprocessingsmoke-") ||
            lowercasedPath.contains("soundtime-transcription-chunk-recovery-smoke-") ||
            lowercasedPath.contains("soundtime-shippability") ||
            lowercasedPath.contains("/fixtures/shippability/") ||
            lowercasedPath.contains("/.build/shippability-fixtures/") ||
            lowercasedPath.contains("/process-sandbox/") ||
            lowercasedPath.contains("/soundtime-automation/")
    }

    private static func isLegacyAutomationAutosave(_ url: URL) -> Bool {
        guard !usesIsolatedAutomationPersistence else {
            return false
        }
        guard let decoded = try? loadAutosaveRaw(from: url) else {
            return false
        }
        if
            let sourceProjectPath = decoded.sourceProjectPath,
            isKnownAutomationArtifactPath(sourceProjectPath)
        {
            return true
        }

        let sourcePaths = decoded.project.tracks
            .flatMap(\.audioSourceCandidateURLs)
            .map(\.path)
        return !sourcePaths.isEmpty &&
            sourcePaths.allSatisfy(isKnownAutomationArtifactPath)
    }

    private static func projectWindowLayoutKey(for projectURL: URL) -> String {
        projectWindowLayoutKeyPrefix + stablePathHash(projectURL.standardizedFileURL.path)
    }

    private static func projectTimelineViewportKey(for projectURL: URL) -> String {
        projectTimelineViewportKeyPrefix + stablePathHash(projectURL.standardizedFileURL.path)
    }

    private static func projectLaunchStateOverlayKey(for projectURL: URL) -> String {
        projectLaunchStateOverlayKeyPrefix + stablePathHash(projectURL.standardizedFileURL.path)
    }

    static func stableProjectKey(for projectURL: URL) -> String {
        stablePathHash(projectURL.standardizedFileURL.path)
    }

    private static func autosaveURL(projectURL: URL?, autosaveID: UUID) -> URL {
        let identifier: String
        if let projectURL {
            identifier = "project-\(stablePathHash(projectURL.standardizedFileURL.path))"
        } else {
            identifier = "untitled-\(autosaveID.uuidString)"
        }
        return autosavesDirectoryURL()
            .appendingPathComponent(identifier)
            .appendingPathExtension(autosaveFileExtension)
    }

    private static func autosaveURL(for projectURL: URL) -> URL {
        autosaveURL(projectURL: projectURL, autosaveID: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID())
    }

    private static func autosavesDirectoryURL() -> URL {
        if
            let persistenceRootPath = ProcessInfo.processInfo.environment[persistenceRootEnvironmentKey],
            !persistenceRootPath.isEmpty
        {
            return URL(fileURLWithPath: persistenceRootPath, isDirectory: true)
                .appendingPathComponent("Autosaves", isDirectory: true)
                .standardizedFileURL
        }
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return baseDirectory
            .appendingPathComponent("Soundtime", isDirectory: true)
            .appendingPathComponent("Autosaves", isDirectory: true)
            .standardizedFileURL
    }

    private static func stablePathHash(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

private extension URL {
    var modificationDateOrDistantPast: Date {
        (try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    func isNewerThan(_ otherURL: URL) -> Bool {
        modificationDateOrDistantPast > otherURL.modificationDateOrDistantPast
    }
}
