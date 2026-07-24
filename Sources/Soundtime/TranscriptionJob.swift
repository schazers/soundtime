import Foundation

struct TranscriptionJob: Identifiable, Equatable {
    enum Status: Equatable {
        case preparing
        case running
        case canceling
        case completed
        case failed(String)
        case canceled
        case stale
    }

    let id: UUID
    let requestID: UUID
    let trackID: UUID
    let trackName: String
    let sourceRevision: Int
    let sourceDuration: TimeInterval
    let providerIdentifier: String
    let providerDisplayName: String
    let createdAt: Date
    var updatedAt: Date
    var status: Status
    var stage: TranscriptionProgressStage
    var fractionCompleted: Double?
    var message: String
    var chunkCount: Int?
    var completedChunkCount: Int?
    var providerRequestIDs: [String]
    var lastError: String?
    var resumeHint: String?
    var persistentSnapshot: PersistentSnapshot {
        PersistentSnapshot(job: self)
    }

    struct PersistentSnapshot: Codable, Equatable, Sendable {
        var id: UUID
        var requestID: UUID
        var trackID: UUID
        var trackName: String
        var sourceRevision: Int
        var sourceDuration: TimeInterval
        var providerIdentifier: String
        var providerDisplayName: String
        var createdAt: Date
        var updatedAt: Date
        var status: String
        var stage: TranscriptionProgressStage
        var fractionCompleted: Double?
        var message: String
        var chunkCount: Int?
        var completedChunkCount: Int?
        var providerRequestIDs: [String]?
        var lastError: String?
        var resumeHint: String?

        init(job: TranscriptionJob) {
            id = job.id
            requestID = job.requestID
            trackID = job.trackID
            trackName = job.trackName
            sourceRevision = job.sourceRevision
            sourceDuration = job.sourceDuration
            providerIdentifier = job.providerIdentifier
            providerDisplayName = job.providerDisplayName
            createdAt = job.createdAt
            updatedAt = job.updatedAt
            status = job.status.persistentName
            stage = job.stage
            fractionCompleted = job.fractionCompleted
            message = job.message
            chunkCount = job.chunkCount
            completedChunkCount = job.completedChunkCount
            providerRequestIDs = job.providerRequestIDs.isEmpty ? nil : job.providerRequestIDs
            lastError = job.lastError
            resumeHint = job.resumeHint
        }
    }

    init(
        id: UUID = UUID(),
        requestID: UUID,
        trackID: UUID,
        trackName: String,
        sourceRevision: Int,
        sourceDuration: TimeInterval,
        providerIdentifier: String,
        providerDisplayName: String
    ) {
        self.id = id
        self.requestID = requestID
        self.trackID = trackID
        self.trackName = trackName
        self.sourceRevision = sourceRevision
        self.sourceDuration = max(sourceDuration, 0)
        self.providerIdentifier = providerIdentifier
        self.providerDisplayName = providerDisplayName
        createdAt = Date()
        updatedAt = createdAt
        status = .preparing
        stage = .preparing
        fractionCompleted = 0
        message = "Preparing transcription"
        chunkCount = nil
        completedChunkCount = nil
        providerRequestIDs = []
        lastError = nil
        resumeHint = nil
    }

    mutating func apply(progress: TranscriptionProgress, at date: Date = Date()) {
        guard requestID == progress.requestID else {
            return
        }

        updatedAt = date
        stage = progress.stage
        fractionCompleted = progress.fractionCompleted.map { min(max($0, 0), 1) }
        message = progress.message
        status = progress.stage == .completed ? .completed : .running
        if let chunkCount = Int(progress.metadata["chunkCount"] ?? "") {
            self.chunkCount = chunkCount
        }
        if let completedChunkCount = Int(progress.metadata["completedChunkCount"] ?? "") {
            self.completedChunkCount = completedChunkCount
        }
        if let providerRequestID = progress.metadata["providerRequestID"],
           !providerRequestID.isEmpty,
           !providerRequestIDs.contains(providerRequestID)
        {
            providerRequestIDs.append(providerRequestID)
        }
        if let resumeHint = progress.metadata["resumeHint"], !resumeHint.isEmpty {
            self.resumeHint = resumeHint
        }
        if progress.stage == .completed {
            lastError = nil
        }
    }

    mutating func markCanceling(at date: Date = Date()) {
        updatedAt = date
        status = .canceling
        stage = .canceling
        fractionCompleted = nil
        message = "Canceling transcription"
        resumeHint = "Canceled locally; start transcription again to retry."
    }

    mutating func markCompleted(summary: String, at date: Date = Date()) {
        updatedAt = date
        status = .completed
        stage = .completed
        fractionCompleted = 1
        message = summary
        lastError = nil
        resumeHint = nil
    }

    mutating func markFailed(_ message: String, at date: Date = Date()) {
        updatedAt = date
        status = .failed(message)
        fractionCompleted = nil
        self.message = message
        lastError = message
        resumeHint = "Retry transcription; completed chunks can be reused by a future resumable provider."
    }

    mutating func markCanceled(at date: Date = Date()) {
        updatedAt = date
        status = .canceled
        stage = .canceling
        fractionCompleted = nil
        message = "Transcription canceled"
        resumeHint = "Canceled locally; start transcription again to retry."
    }

    mutating func markStale(at date: Date = Date()) {
        updatedAt = date
        status = .stale
        fractionCompleted = nil
        message = "Transcription skipped because the track changed"
        lastError = message
        resumeHint = "The source track changed; rerun transcription for the current edit."
    }
}

private extension TranscriptionJob.Status {
    var persistentName: String {
        switch self {
        case .preparing:
            return "preparing"
        case .running:
            return "running"
        case .canceling:
            return "canceling"
        case .completed:
            return "completed"
        case .failed:
            return "failed"
        case .canceled:
            return "canceled"
        case .stale:
            return "stale"
        }
    }
}
