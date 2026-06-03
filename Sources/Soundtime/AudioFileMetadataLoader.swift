import AVFoundation
import Foundation

enum AudioFileMetadataLoader {
    static func loadMetadata(for url: URL) async throws -> AudioFileMetadata {
        async let duration = loadDuration(for: url)
        async let fileSize = loadFileSize(for: url)

        return AudioFileMetadata(
            url: url,
            displayName: displayName(for: url),
            duration: try await duration,
            fileSize: try await fileSize
        )
    }

    private static func loadDuration(for url: URL) async throws -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds

        guard seconds.isFinite, seconds >= 0 else {
            return nil
        }

        return seconds
    }

    private static func loadFileSize(for url: URL) async throws -> Int64? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64
    }

    private static func displayName(for url: URL) -> String {
        let resourceValues = try? url.resourceValues(forKeys: [.localizedNameKey])
        return resourceValues?.localizedName ?? url.lastPathComponent
    }
}
