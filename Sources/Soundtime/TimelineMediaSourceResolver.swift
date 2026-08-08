import Foundation

struct TimelineMediaSourceResolution: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case resolvedRelative
        case resolvedAbsolute
        case missing
    }

    var source: TimelineMediaSource
    var status: Status
}

/// Resolves persisted source locations without changing canonical source or
/// clip identity. Relative project media wins; an existing absolute path is a
/// fallback. It never guesses by filename, which could silently attach a clip
/// to unrelated audio.
enum TimelineMediaSourceResolver {
    static func resolve(
        _ source: TimelineMediaSource,
        projectURL: URL,
        fileManager: FileManager = .default
    ) -> TimelineMediaSourceResolution {
        var resolved = source
        let projectDirectory = projectURL.deletingLastPathComponent()

        if let relativePath = source.relativePath, !relativePath.isEmpty {
            let candidate = projectDirectory
                .appendingPathComponent(relativePath)
                .standardizedFileURL
            if fileManager.fileExists(atPath: candidate.path) {
                resolved.absolutePath = candidate.path
                resolved.metadata["mediaResolution"] = TimelineMediaSourceResolution.Status.resolvedRelative.rawValue
                resolved.metadata.removeValue(forKey: "missingMedia")
                return TimelineMediaSourceResolution(source: resolved, status: .resolvedRelative)
            }
        }

        if let absolutePath = source.absolutePath, !absolutePath.isEmpty {
            let candidate = URL(fileURLWithPath: absolutePath).standardizedFileURL
            if fileManager.fileExists(atPath: candidate.path) {
                resolved.absolutePath = candidate.path
                resolved.metadata["mediaResolution"] = TimelineMediaSourceResolution.Status.resolvedAbsolute.rawValue
                resolved.metadata.removeValue(forKey: "missingMedia")
                return TimelineMediaSourceResolution(source: resolved, status: .resolvedAbsolute)
            }
        }

        resolved.metadata["mediaResolution"] = TimelineMediaSourceResolution.Status.missing.rawValue
        resolved.metadata["missingMedia"] = "true"
        return TimelineMediaSourceResolution(source: resolved, status: .missing)
    }
}
