import Foundation

struct PreparedMissingMediaRelink: Sendable {
    let candidate: TimelineMediaRelinkCandidate
    let waveformOverview: WaveformOverview
    let proxyURL: URL
}

enum MissingMediaRelinkService {
    static func prepare(
        selectedURL: URL,
        expectedSource: TimelineMediaSource,
        projectURL: URL?
    ) async throws -> PreparedMissingMediaRelink {
        let admission = try await AudioImportCoordinator.shared.admit(sourceURL: selectedURL)
        defer {
            Task {
                await AudioImportCoordinator.shared.forget(sessionID: admission.sessionID)
            }
        }

        var acceptedFingerprints: Set<String> = [admission.fingerprint.cacheKey]
        if let fileInfo = admission.assetInfo.wavFileInfo {
            acceptedFingerprints.insert(
                SoundtimeProject.WaveformPreview.FileFingerprint(fileInfo: fileInfo).stableSummary
            )
        }
        if let expected = expectedSource.metadata[TimelineMediaRelinkPlanner.contentFingerprintMetadataKey],
           !expected.isEmpty,
           expected != admission.fingerprint.sampledContentDigest {
            throw TimelineMediaRelinkError.fingerprintMismatch(expected: expected)
        } else if expectedSource.metadata[TimelineMediaRelinkPlanner.contentFingerprintMetadataKey] == nil,
           let expected = expectedSource.fingerprint,
           !expected.isEmpty,
           !acceptedFingerprints.contains(expected) {
            throw TimelineMediaRelinkError.fingerprintMismatch(expected: expected)
        }

        let task = await AudioImportCoordinator.shared.startPreparingEditableAsset(
            admission: admission
        )
        let prepared = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        let relativePath = projectURL.flatMap {
            relativePathIfContained(prepared.proxyURL, in: $0.deletingLastPathComponent())
        }
        let candidate = TimelineMediaRelinkCandidate(
            resolvedAbsolutePath: prepared.proxyURL.standardizedFileURL.path,
            relativePath: relativePath,
            acceptedFingerprints: acceptedFingerprints,
            frameCount: prepared.proxyFileInfo.frameCount,
            sampleRate: prepared.proxyFileInfo.sampleRate,
            channelCount: prepared.proxyFileInfo.channelCount,
            metadata: [
                "originalPath": selectedURL.standardizedFileURL.path,
                "format": admission.assetInfo.format.displayName,
                TimelineMediaRelinkPlanner.contentFingerprintMetadataKey:
                    admission.fingerprint.sampledContentDigest,
                "relinkedAt": ISO8601DateFormatter().string(from: Date()),
            ]
        )
        return PreparedMissingMediaRelink(
            candidate: candidate,
            waveformOverview: prepared.waveformOverview,
            proxyURL: prepared.proxyURL
        )
    }

    private static func relativePathIfContained(_ url: URL, in directory: URL) -> String? {
        let filePath = url.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }
}

extension TimelineMediaRelinkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingSource:
            "The missing media source is no longer part of this project."
        case .invalidCandidate:
            "The selected file does not contain valid audio media."
        case .fingerprintMismatch:
            "The selected file is not the original media used by these clips."
        case let .incompatibleAudioFormat(expectedRate, actualRate, expectedChannels, actualChannels):
            "The selected audio has \(actualChannels) channel(s) at \(Int(actualRate)) Hz; " +
                "the missing source requires \(expectedChannels) channel(s) at \(Int(expectedRate)) Hz."
        case let .candidateTooShort(required, actual):
            "The selected audio contains \(actual) frames, but existing clips require at least \(required)."
        }
    }
}
