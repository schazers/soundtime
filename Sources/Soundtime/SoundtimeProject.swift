import Foundation

struct SoundtimeProject: Codable, Sendable {
    struct WindowLayout: Codable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    struct Track: Codable, Sendable {
        var id: UUID
        var name: String
        var filePath: String
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool
    }

    var tracks: [Track]
    var windowLayout: WindowLayout?
}

enum SoundtimeProjectStore {
    static let fileExtension = "soundtime"
    static let maximumRecentProjectCount = 8
    private static let lastProjectURLKey = "Soundtime.lastProjectURL"
    private static let recentProjectURLPathsKey = "Soundtime.recentProjectURLPaths"

    static func load(from url: URL) throws -> SoundtimeProject {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SoundtimeProject.self, from: data)
    }

    static func save(_ project: SoundtimeProject, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: url, options: [.atomic])
        rememberLastProjectURL(url)
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
    }

    private static func recentProjectURLPaths() -> [String] {
        (UserDefaults.standard.stringArray(forKey: recentProjectURLPathsKey) ?? [])
            .filter { !$0.isEmpty }
    }
}
