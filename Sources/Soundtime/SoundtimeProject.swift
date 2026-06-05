import Foundation

struct SoundtimeProject: Codable, Sendable {
    struct Track: Codable, Sendable {
        var id: UUID
        var name: String
        var filePath: String
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool
    }

    var tracks: [Track]
}

enum SoundtimeProjectStore {
    static let fileExtension = "soundtime"
    private static let lastProjectURLKey = "Soundtime.lastProjectURL"

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
    }

    static func lastProjectURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: lastProjectURLKey), !path.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: path)
    }
}
