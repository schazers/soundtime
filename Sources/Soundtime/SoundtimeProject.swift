import Foundation

struct SoundtimeProject: Codable, Sendable {
    static let currentSchemaVersion = 4
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
                if
                    let modificationTime,
                    let currentModificationTime = currentValues?.contentModificationDate?.timeIntervalSince1970,
                    abs(modificationTime - currentModificationTime) > 0.001
                {
                    return false
                }

                return true
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
        var id: UUID
        var editGroupID: UUID? = nil
        var name: String
        var filePath: String
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool
        var editTimeline: AudioFileEditTimeline.PersistentState?
        var waveformPreview: WaveformPreview? = nil
    }

    var tracks: [Track]
    var windowLayout: WindowLayout?
    var masterVolume: Float?
    var timelineViewport: TimelineViewport?
    var silenceReviewState: SilenceReviewState?

    var schemaVersion: Int

    init(
        tracks: [Track],
        windowLayout: WindowLayout?,
        masterVolume: Float?,
        timelineViewport: TimelineViewport?,
        silenceReviewState: SilenceReviewState? = nil,
        schemaVersion: Int = SoundtimeProject.currentSchemaVersion
    ) {
        self.tracks = tracks
        self.windowLayout = windowLayout
        self.masterVolume = masterVolume
        self.timelineViewport = timelineViewport
        self.silenceReviewState = silenceReviewState
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case tracks
        case windowLayout
        case masterVolume
        case timelineViewport
        case silenceReviewState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        tracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        windowLayout = try container.decodeIfPresent(WindowLayout.self, forKey: .windowLayout)
        masterVolume = try container.decodeIfPresent(Float.self, forKey: .masterVolume)
        timelineViewport = try container.decodeIfPresent(TimelineViewport.self, forKey: .timelineViewport)
        silenceReviewState = try container.decodeIfPresent(SilenceReviewState.self, forKey: .silenceReviewState)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(tracks, forKey: .tracks)
        try container.encodeIfPresent(windowLayout, forKey: .windowLayout)
        try container.encodeIfPresent(masterVolume, forKey: .masterVolume)
        try container.encodeIfPresent(timelineViewport, forKey: .timelineViewport)
        try container.encodeIfPresent(silenceReviewState, forKey: .silenceReviewState)
    }
}

enum SoundtimeProjectStore {
    static let fileExtension = "soundtime"
    static let autosaveFileExtension = "soundtime-autosave"
    static let maximumRecentProjectCount = 8
    private static let lastProjectURLKey = "Soundtime.lastProjectURL"
    private static let recentProjectURLPathsKey = "Soundtime.recentProjectURLPaths"
    private static let projectWindowLayoutKeyPrefix = "Soundtime.projectWindowLayout."

    static func load(from url: URL) throws -> SoundtimeProject {
        let data = try Data(contentsOf: url)
        return migrate(try JSONDecoder().decode(SoundtimeProject.self, from: data))
    }

    static func loadRecoveringAutosave(from url: URL) throws -> SoundtimeProject {
        let autosaveURL = autosaveURL(for: url)
        guard
            FileManager.default.fileExists(atPath: autosaveURL.path),
            autosaveURL.isNewerThan(url)
        else {
            return try load(from: url)
        }

        return try load(from: autosaveURL)
    }

    static func save(_ project: SoundtimeProject, to url: URL) throws {
        try write(migrate(project), to: url)
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
        try write(migrate(project), to: url)
        return url
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
            .sorted { $0.modificationDateOrDistantPast > $1.modificationDateOrDistantPast }
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

    static func rememberLastProjectURL(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: lastProjectURLKey)
        rememberRecentProjectURL(url)
    }

    static func lastProjectURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: lastProjectURLKey), !path.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: path)
    }

    static func rememberRecentProjectURL(_ url: URL) {
        let path = url.path
        var paths = recentProjectURLPaths().filter { $0 != path }
        paths.insert(path, at: 0)
        if paths.count > maximumRecentProjectCount {
            paths = Array(paths.prefix(maximumRecentProjectCount))
        }

        UserDefaults.standard.set(paths, forKey: recentProjectURLPathsKey)
    }

    static func recentProjectURLs() -> [URL] {
        recentProjectURLPaths().map(URL.init(fileURLWithPath:))
    }

    static func clearRecentProjectURLs() {
        UserDefaults.standard.removeObject(forKey: recentProjectURLPathsKey)
        UserDefaults.standard.removeObject(forKey: lastProjectURLKey)
    }

    static func rememberWindowLayout(_ layout: SoundtimeProject.WindowLayout, for projectURL: URL) {
        guard let data = try? JSONEncoder().encode(layout) else {
            return
        }

        UserDefaults.standard.set(data, forKey: projectWindowLayoutKey(for: projectURL))
    }

    static func rememberedWindowLayout(for projectURL: URL) -> SoundtimeProject.WindowLayout? {
        guard let data = UserDefaults.standard.data(forKey: projectWindowLayoutKey(for: projectURL)) else {
            return nil
        }

        return try? JSONDecoder().decode(SoundtimeProject.WindowLayout.self, from: data)
    }

    private static func recentProjectURLPaths() -> [String] {
        (UserDefaults.standard.stringArray(forKey: recentProjectURLPathsKey) ?? [])
            .filter { !$0.isEmpty }
    }

    private static func projectWindowLayoutKey(for projectURL: URL) -> String {
        projectWindowLayoutKeyPrefix + stablePathHash(projectURL.standardizedFileURL.path)
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
