import AVFoundation
import Foundation

enum AudioExportPreflight {
    private static let staleArtifactAge: TimeInterval = 24 * 60 * 60

    enum PreflightError: LocalizedError {
        case destinationMatchesSource(URL)
        case destinationIsNotWritable(URL)
        case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
        case unsupportedCodec(AudioExportFormat)
        case sourceChanged(URL)
        case wavRIFFLimitExceeded

        var errorDescription: String? {
            switch self {
            case let .destinationMatchesSource(url):
                return "The export destination is also a project source file: \(url.lastPathComponent). Choose a different destination."
            case let .destinationIsNotWritable(url):
                return "Soundtime cannot write exports to \(url.path)."
            case let .insufficientDiskSpace(requiredBytes, availableBytes):
                return "The export needs about \(Self.megabytes(requiredBytes)) MB, but only \(Self.megabytes(availableBytes)) MB is available."
            case let .unsupportedCodec(format):
                return "\(format.displayName) encoding is not available on this Mac."
            case let .sourceChanged(url):
                return "\(url.lastPathComponent) changed after export began. No output was replaced."
            case .wavRIFFLimitExceeded:
                return "This export is too large for a standard RIFF WAV file. Export a shorter range or use a compressed format."
            }
        }

        private static func megabytes(_ bytes: Int64) -> Int64 {
            max(bytes / 1_048_576, 1)
        }
    }

    static func validate(snapshot: AudioExportSnapshot) throws {
        removeStaleArtifacts(near: snapshot.request.destinationURL)
        try validateDestinationDoesNotMatchSource(snapshot: snapshot)
        try validateSourceIdentities(snapshot: snapshot)
        try validateWritableDestination(snapshot: snapshot)
        try validateDiskCapacity(snapshot: snapshot)
        try validateWAVCapacity(snapshot: snapshot)
        try validateCodec(snapshot: snapshot)
    }

    static func removeStaleArtifacts(
        near destinationURL: URL,
        now: Date = Date()
    ) {
        let directory = nearestExistingDirectory(
            startingAt: destinationURL.deletingLastPathComponent()
        )
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return
        }

        for url in urls {
            let name = url.lastPathComponent
            guard
                name.hasPrefix(".soundtime-export-") ||
                name.hasPrefix(".soundtime-stems-")
            else {
                continue
            }
            let modifiedAt = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            guard
                let modifiedAt,
                now.timeIntervalSince(modifiedAt) >= staleArtifactAge
            else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func validateSourceIdentities(snapshot: AudioExportSnapshot) throws {
        for track in snapshot.tracks {
            guard
                let original = track.sourceFingerprint,
                let url = track.sourceURL
            else {
                continue
            }
            guard AudioExportSourceFingerprint.capture(url: url) == original else {
                throw PreflightError.sourceChanged(url)
            }
        }
    }

    private static func validateDestinationDoesNotMatchSource(
        snapshot: AudioExportSnapshot
    ) throws {
        guard !snapshot.request.scope.exportsStems else {
            return
        }
        let destination = canonicalURL(
            AudioExportService.normalizedURL(
                snapshot.request.destinationURL,
                format: snapshot.request.format
            )
        )
        for sourceURL in snapshot.leasedURLs where canonicalURL(sourceURL) == destination {
            throw PreflightError.destinationMatchesSource(sourceURL)
        }
    }

    private static func validateWritableDestination(
        snapshot: AudioExportSnapshot
    ) throws {
        let destination = snapshot.request.destinationURL.standardizedFileURL
        let directory = snapshot.request.scope.exportsStems ?
            destination :
            destination.deletingLastPathComponent()
        let existingDirectory = nearestExistingDirectory(startingAt: directory)
        guard FileManager.default.isWritableFile(atPath: existingDirectory.path) else {
            throw PreflightError.destinationIsNotWritable(directory)
        }

        let probeURL = existingDirectory.appendingPathComponent(
            ".soundtime-write-probe-\(UUID().uuidString)"
        )
        guard FileManager.default.createFile(atPath: probeURL.path, contents: Data()) else {
            throw PreflightError.destinationIsNotWritable(directory)
        }
        try? FileManager.default.removeItem(at: probeURL)
    }

    private static func validateDiskCapacity(snapshot: AudioExportSnapshot) throws {
        let destination = snapshot.request.destinationURL.standardizedFileURL
        let directory = nearestExistingDirectory(startingAt: destination.deletingLastPathComponent())
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            return
        }

        let perFileBytes = estimatedFileBytes(snapshot: snapshot)
        let fileCount: Int
        if case let .stems(includeMixdown, _) = snapshot.request.scope {
            fileCount = snapshot.tracks.count + (includeMixdown ? 1 : 0)
        } else {
            fileCount = 1
        }
        let required = perFileBytes
            .multipliedReportingOverflow(by: Int64(max(fileCount, 1)))
        let requiredBytes = required.overflow ? Int64.max : required.partialValue
        let safetyMargin = max(Int64(64 * 1_048_576), requiredBytes / 10)
        guard available >= requiredBytes + safetyMargin else {
            throw PreflightError.insufficientDiskSpace(
                requiredBytes: requiredBytes + safetyMargin,
                availableBytes: available
            )
        }
    }

    private static func validateCodec(snapshot: AudioExportSnapshot) throws {
        guard snapshot.request.format.isCompressed else {
            return
        }
        guard snapshot.request.format.isSystemEncoderAvailable else {
            throw PreflightError.unsupportedCodec(snapshot.request.format)
        }

        let probeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundtime-codec-probe-\(UUID().uuidString)")
            .appendingPathExtension(snapshot.request.format.fileExtension)
        do {
            let writer = try AudioExportStreamingCompressedWriter(
                url: probeURL,
                format: snapshot.request.format,
                sampleRate: snapshot.sampleRate,
                channelCount: snapshot.channelCount,
                bitRate: snapshot.request.compressedQuality.rawValue
            )
            writer.cancel()
        } catch {
            throw PreflightError.unsupportedCodec(snapshot.request.format)
        }
    }

    private static func validateWAVCapacity(snapshot: AudioExportSnapshot) throws {
        guard snapshot.request.format == .wav else {
            return
        }
        let bytesPerFile = estimatedFileBytes(snapshot: snapshot)
        guard bytesPerFile <= Int64(UInt32.max) else {
            throw PreflightError.wavRIFFLimitExceeded
        }
    }

    private static func estimatedFileBytes(snapshot: AudioExportSnapshot) -> Int64 {
        let frames = Int64(max(snapshot.frameCount, 0))
        let channels = Int64(max(snapshot.channelCount, 1))
        if snapshot.request.format == .wav {
            return 4_096 + frames * channels * Int64(snapshot.request.wavEncoding.bytesPerSample)
        }

        // Use uncompressed float size as a deliberately conservative capacity estimate.
        return 4_096 + frames * channels * 4
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func nearestExistingDirectory(startingAt url: URL) -> URL {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate {
                break
            }
            candidate = parent
        }
        return candidate
    }
}
