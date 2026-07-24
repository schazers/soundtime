import Foundation

struct TranscriptionControllerResult: Sendable {
    let scope: ResolvedTranscriptionScope
    let providerResult: TranscriptionResult
}

final class TranscriptionController: @unchecked Sendable {
    private let provider: TranscriptionProvider

    init(provider: TranscriptionProvider) {
        self.provider = provider
    }

    var providerIdentifier: String {
        provider.identifier
    }

    var providerDisplayName: String {
        provider.displayName
    }

    func transcribe(
        scope: ResolvedTranscriptionScope,
        requestID: UUID,
        progress: @escaping TranscriptionProgressHandler
    ) async throws -> TranscriptionControllerResult {
        guard let primarySource = scope.primarySource else {
            throw LocalPlaceholderTranscriptionProvider.ProcessingError.emptyInput
        }
        var languageCode = scope.requestedScope.languageCode
        if languageCode?.isEmpty == true {
            languageCode = nil
        }
        let request = TranscriptionRequest(
            id: requestID,
            inputAsset: TranscriptionInputAsset(
                id: scope.id,
                trackID: primarySource.trackID,
                url: primarySource.sourceURL,
                displayName: primarySource.trackName,
                duration: primarySource.sourceDuration,
                sourceRevision: primarySource.sourceRevision,
                sourceFingerprint: primarySource.sourceFingerprint,
                scope: scope.requestedScope,
                timeMap: primarySource.timeMap
            ),
            preferredLanguageCode: languageCode
        )
        let result = try await provider.transcribe(request, progress: progress)
        var transcript = result.transcript
        transcript.sourceTimeMap = primarySource.timeMap
        transcript.sourceFingerprint = primarySource.sourceFingerprint
        transcript.validity = .valid
        transcript.storageReference = TranscriptStorageReference.defaultSidecar(
            transcriptID: transcript.id,
            trackID: primarySource.trackID
        )
        return TranscriptionControllerResult(
            scope: scope,
            providerResult: TranscriptionResult(
                requestID: result.requestID,
                transcript: transcript,
                summary: result.summary
            )
        )
    }

    func cancel(requestID: UUID) async -> TranscriptionCancellationResult {
        await provider.cancel(requestID: requestID)
    }
}
