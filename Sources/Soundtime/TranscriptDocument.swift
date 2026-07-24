import Foundation

struct TranscriptWord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var rawText: String?
    var punctuatedText: String?
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Float?
    var speakerID: String?
    var speakerConfidence: Float?
    var channelIndex: Int?

    init(
        id: UUID = UUID(),
        text: String,
        rawText: String? = nil,
        punctuatedText: String? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Float? = nil,
        speakerID: String? = nil,
        speakerConfidence: Float? = nil,
        channelIndex: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.rawText = rawText
        self.punctuatedText = punctuatedText
        self.startTime = max(startTime, 0)
        self.endTime = max(endTime, self.startTime)
        self.confidence = confidence
        self.speakerID = speakerID
        self.speakerConfidence = speakerConfidence
        self.channelIndex = channelIndex
    }
}

struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var speakerID: String?
    var speakerLabel: String?
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var words: [TranscriptWord]
    var confidence: Float?
    var speakerConfidence: Float?
    var channelIndex: Int?

    init(
        id: UUID = UUID(),
        speakerID: String? = nil,
        speakerLabel: String? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        words: [TranscriptWord] = [],
        confidence: Float? = nil,
        speakerConfidence: Float? = nil,
        channelIndex: Int? = nil
    ) {
        self.id = id
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
        self.startTime = max(startTime, 0)
        self.endTime = max(endTime, self.startTime)
        self.text = text
        self.words = words
        self.confidence = confidence
        self.speakerConfidence = speakerConfidence
        self.channelIndex = channelIndex
    }
}

struct TranscriptDocument: Codable, Equatable, Identifiable, Sendable {
    enum SourceKind: String, Codable, Sendable {
        case track
        case clip
        case mixdown
    }

    enum Validity: String, Codable, Sendable {
        case valid
        case remapped
        case partiallyStale
        case stale
    }

    struct StorageReference: Codable, Equatable, Sendable {
        var kind: String
        var path: String

        init(kind: String, path: String) {
            self.kind = kind
            self.path = path
        }
    }

    var id: UUID
    var sourceKind: SourceKind
    var trackID: UUID?
    var sourceRevision: Int
    var sourceDuration: TimeInterval
    var sourceFingerprint: String?
    var languageCode: String?
    var providerIdentifier: String
    var providerDisplayName: String
    var providerRequestID: String?
    var providerModelName: String?
    var createdAt: Date
    var validity: Validity?
    var sourceTimeMap: TranscriptSourceTimeMap?
    var storageReference: StorageReference?
    var segments: [TranscriptSegment]

    init(
        id: UUID = UUID(),
        sourceKind: SourceKind = .track,
        trackID: UUID?,
        sourceRevision: Int,
        sourceDuration: TimeInterval,
        sourceFingerprint: String? = nil,
        languageCode: String? = nil,
        providerIdentifier: String,
        providerDisplayName: String,
        providerRequestID: String? = nil,
        providerModelName: String? = nil,
        createdAt: Date = Date(),
        validity: Validity? = .valid,
        sourceTimeMap: TranscriptSourceTimeMap? = nil,
        storageReference: StorageReference? = nil,
        segments: [TranscriptSegment]
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.trackID = trackID
        self.sourceRevision = sourceRevision
        self.sourceDuration = max(sourceDuration, 0)
        self.sourceFingerprint = sourceFingerprint
        self.languageCode = languageCode
        self.providerIdentifier = providerIdentifier
        self.providerDisplayName = providerDisplayName
        self.providerRequestID = providerRequestID
        self.providerModelName = providerModelName
        self.createdAt = createdAt
        self.validity = validity
        self.sourceTimeMap = sourceTimeMap
        self.storageReference = storageReference
        self.segments = segments.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.endTime < rhs.endTime
            }
            return lhs.startTime < rhs.startTime
        }
    }

    var isEmpty: Bool {
        segments.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var words: [TranscriptWord] {
        segments.flatMap(\.words)
    }

    func segments(overlapping range: Range<TimeInterval>) -> [TranscriptSegment] {
        segments.filter { segment in
            segment.endTime >= range.lowerBound && segment.startTime <= range.upperBound
        }
    }

    func word(atSourceTime sourceTime: TimeInterval) -> TranscriptWord? {
        guard !segments.isEmpty else {
            return nil
        }

        var index = Self.firstSegmentIndex(overlapping: sourceTime..<max(sourceTime + 0.000_001, sourceTime), in: segments)
        while index < segments.count {
            let segment = segments[index]
            if segment.startTime > sourceTime {
                break
            }
            if segment.endTime >= sourceTime,
               let word = segment.words.first(where: { $0.startTime <= sourceTime && $0.endTime >= sourceTime }) {
                return word
            }
            index += 1
        }
        return nil
    }

    func words(overlapping range: Range<TimeInterval>) -> [TranscriptWord] {
        guard !range.isEmpty, !segments.isEmpty else {
            return []
        }

        var output: [TranscriptWord] = []
        var index = Self.firstSegmentIndex(overlapping: range, in: segments)
        while index < segments.count {
            let segment = segments[index]
            if segment.startTime > range.upperBound {
                break
            }
            if segment.endTime >= range.lowerBound {
                output.append(contentsOf: segment.words.filter { word in
                    word.endTime >= range.lowerBound && word.startTime <= range.upperBound
                })
            }
            index += 1
        }
        return output
    }

    func words(matching wordIDs: Set<UUID>) -> [TranscriptWord] {
        guard !wordIDs.isEmpty else {
            return []
        }

        var remaining = wordIDs
        var output: [TranscriptWord] = []
        output.reserveCapacity(wordIDs.count)
        for segment in segments {
            for word in segment.words where remaining.contains(word.id) {
                output.append(word)
                remaining.remove(word.id)
                if remaining.isEmpty {
                    return output
                }
            }
        }
        return output
    }

    private static func firstSegmentIndex(
        overlapping range: Range<TimeInterval>,
        in segments: [TranscriptSegment]
    ) -> Int {
        guard !range.isEmpty else {
            return segments.count
        }

        var low = 0
        var high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].endTime < range.lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}

typealias TranscriptStorageReference = TranscriptDocument.StorageReference

extension TranscriptDocument.StorageReference {
    static func defaultSidecar(transcriptID: UUID, trackID: UUID?) -> TranscriptDocument.StorageReference {
        let trackComponent = trackID?.uuidString ?? "project"
        return TranscriptDocument.StorageReference(
            kind: "project-sidecar-json",
            path: "Transcripts/\(trackComponent)-\(transcriptID.uuidString).json"
        )
    }
}
