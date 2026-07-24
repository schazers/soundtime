import Foundation

enum TranscriptionRenderMode: String, Codable, CaseIterable, Sendable {
    case perTrack
    case mixdown
    case stems
}

enum TranscriptionAudioDomain: String, Codable, CaseIterable, Sendable {
    case rawSource
    case postEditGraph
    case preMaster
}

enum TranscriptionScopeKind: String, Codable, CaseIterable, Sendable {
    case selectedRange
    case wholeTrack
    case clip
    case trackRange
    case editGroupRange
    case projectRange
    case selection
}

struct TranscriptionTimeRange: Codable, Equatable, Sendable {
    var startTime: TimeInterval
    var endTime: TimeInterval

    init(startTime: TimeInterval, endTime: TimeInterval) {
        let safeStart = startTime.isFinite ? max(startTime, 0) : 0
        let safeEnd = endTime.isFinite ? max(endTime, 0) : safeStart
        self.startTime = min(safeStart, safeEnd)
        self.endTime = max(safeStart, safeEnd)
    }

    var duration: TimeInterval {
        max(endTime - startTime, 0)
    }

    var isEmpty: Bool {
        duration <= 0
    }
}

struct TranscriptionScope: Codable, Equatable, Sendable {
    var kind: TranscriptionScopeKind
    var trackIDs: [UUID]
    var range: TranscriptionTimeRange?
    var renderMode: TranscriptionRenderMode
    var audioDomain: TranscriptionAudioDomain
    var languageCode: String?

    init(
        kind: TranscriptionScopeKind,
        trackIDs: [UUID] = [],
        range: TranscriptionTimeRange? = nil,
        renderMode: TranscriptionRenderMode = .perTrack,
        audioDomain: TranscriptionAudioDomain = .postEditGraph,
        languageCode: String? = nil
    ) {
        self.kind = kind
        self.trackIDs = Array(Set(trackIDs)).sorted { $0.uuidString < $1.uuidString }
        self.range = range
        self.renderMode = renderMode
        self.audioDomain = audioDomain
        self.languageCode = languageCode
    }
}

struct ResolvedTranscriptionSource: Codable, Equatable, Sendable {
    var trackID: UUID
    var trackName: String
    var sourceURL: URL
    var sourceRevision: Int
    var sourceDuration: TimeInterval
    var timelineDuration: TimeInterval
    var sourceFingerprint: String?
    var timeMap: TranscriptSourceTimeMap

    init(
        trackID: UUID,
        trackName: String,
        sourceURL: URL,
        sourceRevision: Int,
        sourceDuration: TimeInterval,
        timelineDuration: TimeInterval,
        sourceFingerprint: String? = nil,
        timeMap: TranscriptSourceTimeMap
    ) {
        self.trackID = trackID
        self.trackName = trackName
        self.sourceURL = sourceURL.standardizedFileURL
        self.sourceRevision = sourceRevision
        self.sourceDuration = max(sourceDuration, 0)
        self.timelineDuration = max(timelineDuration, 0)
        self.sourceFingerprint = sourceFingerprint
        self.timeMap = timeMap
    }
}

struct ResolvedTranscriptionScope: Codable, Equatable, Sendable {
    var id: UUID
    var requestedScope: TranscriptionScope
    var sources: [ResolvedTranscriptionSource]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        requestedScope: TranscriptionScope,
        sources: [ResolvedTranscriptionSource],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.requestedScope = requestedScope
        self.sources = sources
        self.createdAt = createdAt
    }

    var primarySource: ResolvedTranscriptionSource? {
        sources.first
    }

    var isEmpty: Bool {
        sources.isEmpty || sources.allSatisfy { $0.timelineDuration <= 0 }
    }
}
