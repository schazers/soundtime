import Foundation

struct AudioFileMetadata: Equatable, Sendable {
    let url: URL
    let displayName: String
    let duration: TimeInterval?
    let fileSize: Int64?

    var formattedSummary: String {
        let durationText = duration.map(Self.formatDuration) ?? "unknown duration"
        let sizeText = fileSize.map(Self.formatFileSize) ?? "unknown size"
        return "\(displayName) - \(durationText) - \(sizeText)"
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration >= 0 else {
            return "unknown duration"
        }

        let roundedSeconds = Int(duration.rounded())
        let hours = roundedSeconds / 3_600
        let minutes = roundedSeconds % 3_600 / 60
        let seconds = roundedSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func formatFileSize(_ fileSize: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}
