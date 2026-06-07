import Foundation

struct SoundtimeProject: Codable, Sendable {
    static let currentSchemaVersion = 2

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

    struct Track: Codable, Sendable {
        var id: UUID
        var editGroupID: UUID? = nil
        var name: String
        var filePath: String
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool
        var editTimeline: AudioFileEditTimeline.PersistentState?
    }

    var tracks: [Track]
    var windowLayout: WindowLayout?
    var masterVolume: Float?
    var timelineViewport: TimelineViewport?

    var schemaVersion: Int

    init(
        tracks: [Track],
        windowLayout: WindowLayout?,
        masterVolume: Float?,
        timelineViewport: TimelineViewport?,
        schemaVersion: Int = SoundtimeProject.currentSchemaVersion
    ) {
        self.tracks = tracks
        self.windowLayout = windowLayout
        self.masterVolume = masterVolume
        self.timelineViewport = timelineViewport
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case tracks
        case windowLayout
        case masterVolume
        case timelineViewport
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        tracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        windowLayout = try container.decodeIfPresent(WindowLayout.self, forKey: .windowLayout)
        masterVolume = try container.decodeIfPresent(Float.self, forKey: .masterVolume)
        timelineViewport = try container.decodeIfPresent(TimelineViewport.self, forKey: .timelineViewport)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(tracks, forKey: .tracks)
        try container.encodeIfPresent(windowLayout, forKey: .windowLayout)
        try container.encodeIfPresent(masterVolume, forKey: .masterVolume)
        try container.encodeIfPresent(timelineViewport, forKey: .timelineViewport)
    }
}

enum SoundtimeProjectStore {
    static let fileExtension = "soundtime"
    static let autosaveFileExtension = "soundtime-autosave"
    static let maximumRecentProjectCount = 8
    private static let lastProjectURLKey = "Soundtime.lastProjectURL"
    private static let recentProjectURLPathsKey = "Soundtime.recentProjectURLPaths"

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

    private static func recentProjectURLPaths() -> [String] {
        (UserDefaults.standard.stringArray(forKey: recentProjectURLPathsKey) ?? [])
            .filter { !$0.isEmpty }
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
