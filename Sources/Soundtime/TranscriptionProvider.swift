import Foundation

struct TranscriptionInputAsset: Sendable {
    let id: UUID
    let trackID: UUID?
    let url: URL
    let displayName: String
    let duration: TimeInterval
    let sourceRevision: Int
    var sourceFingerprint: String? = nil
    var scope: TranscriptionScope? = nil
    var timeMap: TranscriptSourceTimeMap? = nil
}

struct TranscriptionRequest: Sendable {
    let id: UUID
    let inputAsset: TranscriptionInputAsset
    let preferredLanguageCode: String?
}

enum TranscriptionProgressStage: String, Codable, Sendable {
    case preparing
    case uploading
    case queued
    case transcribing
    case aligning
    case saving
    case completed
    case canceling
}

struct TranscriptionProgress: Sendable {
    let requestID: UUID
    let stage: TranscriptionProgressStage
    let fractionCompleted: Double?
    let message: String
    let metadata: [String: String]

    init(
        requestID: UUID,
        stage: TranscriptionProgressStage,
        fractionCompleted: Double?,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.requestID = requestID
        self.stage = stage
        self.fractionCompleted = fractionCompleted
        self.message = message
        self.metadata = metadata
    }
}

struct TranscriptionResult: Sendable {
    let requestID: UUID
    let transcript: TranscriptDocument
    let summary: String
}

enum TranscriptionCancellationResult: Equatable, Sendable {
    case canceledRemotely
    case remoteCancellationUnsupported
}

typealias TranscriptionProgressHandler = @Sendable (TranscriptionProgress) -> Void

protocol TranscriptionProvider: Sendable {
    var identifier: String { get }
    var displayName: String { get }

    func transcribe(
        _ request: TranscriptionRequest,
        progress: @escaping TranscriptionProgressHandler
    ) async throws -> TranscriptionResult

    func cancel(requestID: UUID) async -> TranscriptionCancellationResult
}

extension TranscriptionProvider {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        try await transcribe(request, progress: { _ in })
    }

    func cancel(requestID: UUID) async -> TranscriptionCancellationResult {
        .remoteCancellationUnsupported
    }
}

final class LocalPlaceholderTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    enum ProcessingError: LocalizedError {
        case emptyInput

        var errorDescription: String? {
            switch self {
            case .emptyInput:
                "There is no track duration to transcribe."
            }
        }
    }

    let identifier = "local.soundtime.placeholder-transcription"
    let displayName = "Soundtime Placeholder Transcriber"

    private let phrase = [
        "this", "is", "placeholder", "transcript", "text",
        "ready", "for", "timeline", "alignment", "editing",
    ]

    func transcribe(
        _ request: TranscriptionRequest,
        progress: @escaping TranscriptionProgressHandler
    ) async throws -> TranscriptionResult {
        guard request.inputAsset.duration > 0 else {
            throw ProcessingError.emptyInput
        }

        progress(TranscriptionProgress(
            requestID: request.id,
            stage: .preparing,
            fractionCompleted: 0.05,
            message: "Preparing transcript request"
        ))
        try await Task.sleep(nanoseconds: 60_000_000)
        progress(TranscriptionProgress(
            requestID: request.id,
            stage: .transcribing,
            fractionCompleted: 0.45,
            message: "Creating placeholder transcript"
        ))
        try await Task.sleep(nanoseconds: 90_000_000)
        let transcript = makeTranscript(for: request)
        progress(TranscriptionProgress(
            requestID: request.id,
            stage: .aligning,
            fractionCompleted: 0.82,
            message: "Aligning placeholder words"
        ))
        try await Task.sleep(nanoseconds: 50_000_000)
        progress(TranscriptionProgress(
            requestID: request.id,
            stage: .completed,
            fractionCompleted: 1,
            message: "Transcript ready"
        ))
        return TranscriptionResult(
            requestID: request.id,
            transcript: transcript,
            summary: "created \(transcript.words.count) placeholder words"
        )
    }

    private func makeTranscript(for request: TranscriptionRequest) -> TranscriptDocument {
        let duration = request.inputAsset.duration
        let wordDuration = min(max(duration / 96.0, 0.24), 0.62)
        let gapDuration = wordDuration * 0.28
        let segmentWordCount = 9
        var segments: [TranscriptSegment] = []
        var segmentWords: [TranscriptWord] = []
        var time: TimeInterval = 0
        var wordIndex = 0

        while time < duration {
            let text = phrase[wordIndex % phrase.count]
            let endTime = min(time + wordDuration, duration)
            segmentWords.append(TranscriptWord(
                text: text,
                startTime: time,
                endTime: endTime,
                confidence: 0.5,
                speakerID: "speaker-1"
            ))

            if segmentWords.count == segmentWordCount || endTime >= duration {
                let segmentText = segmentWords.map(\.text).joined(separator: " ")
                segments.append(TranscriptSegment(
                    speakerID: "speaker-1",
                    speakerLabel: "Speaker 1",
                    startTime: segmentWords.first?.startTime ?? time,
                    endTime: segmentWords.last?.endTime ?? endTime,
                    text: segmentText,
                    words: segmentWords
                ))
                segmentWords.removeAll(keepingCapacity: true)
            }

            time = endTime + gapDuration
            wordIndex += 1
        }

        return TranscriptDocument(
            sourceKind: .track,
            trackID: request.inputAsset.trackID,
            sourceRevision: request.inputAsset.sourceRevision,
            sourceDuration: duration,
            languageCode: request.preferredLanguageCode,
            providerIdentifier: identifier,
            providerDisplayName: displayName,
            segments: segments
        )
    }
}

enum TranscriptionProviderFactory {
    static func makeDefaultProvider() -> TranscriptionProvider {
        if let deepgramProvider = DeepgramTranscriptionProvider() {
            return deepgramProvider
        }
        return LocalPlaceholderTranscriptionProvider()
    }
}
