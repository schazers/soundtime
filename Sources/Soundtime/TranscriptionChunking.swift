import Foundation

struct TranscriptionChunk: Codable, Equatable, Sendable {
    let index: Int
    let requestedStartTime: TimeInterval
    let requestedEndTime: TimeInterval
    let contextStartTime: TimeInterval
    let contextEndTime: TimeInterval

    var requestedDuration: TimeInterval {
        requestedEndTime - requestedStartTime
    }

    var contextDuration: TimeInterval {
        contextEndTime - contextStartTime
    }
}

enum TranscriptionChunker {
    static func chunks(
        sourceDuration: TimeInterval,
        maximumChunkDuration: TimeInterval = 10 * 60,
        contextOverlap: TimeInterval = 2
    ) -> [TranscriptionChunk] {
        guard sourceDuration > 0 else {
            return []
        }

        let safeMaximumChunkDuration = max(maximumChunkDuration, 1)
        let safeContextOverlap = min(max(contextOverlap, 0), safeMaximumChunkDuration * 0.25)
        var chunks: [TranscriptionChunk] = []
        var requestedStart: TimeInterval = 0
        var index = 0

        while requestedStart < sourceDuration {
            let requestedEnd = min(requestedStart + safeMaximumChunkDuration, sourceDuration)
            chunks.append(TranscriptionChunk(
                index: index,
                requestedStartTime: requestedStart,
                requestedEndTime: requestedEnd,
                contextStartTime: max(requestedStart - safeContextOverlap, 0),
                contextEndTime: min(requestedEnd + safeContextOverlap, sourceDuration)
            ))
            guard requestedEnd < sourceDuration else {
                break
            }
            requestedStart = requestedEnd
            index += 1
        }

        return chunks
    }
}

enum TranscriptStitcher {
    static func stitch(
        chunkTranscripts: [(chunk: TranscriptionChunk, transcript: TranscriptDocument)],
        trackID: UUID?,
        sourceRevision: Int,
        sourceDuration: TimeInterval,
        languageCode: String?,
        providerIdentifier: String,
        providerDisplayName: String
    ) -> TranscriptDocument {
        var stitchedSegments: [TranscriptSegment] = []
        var acceptedWords: [TranscriptWord] = []

        for (chunk, transcript) in chunkTranscripts.sorted(by: { $0.chunk.index < $1.chunk.index }) {
            for segment in transcript.segments {
                let shiftedSegmentStart = segment.startTime + chunk.contextStartTime
                let shiftedSegmentEnd = segment.endTime + chunk.contextStartTime
                guard shiftedSegmentEnd >= chunk.requestedStartTime,
                      shiftedSegmentStart <= chunk.requestedEndTime
                else {
                    continue
                }

                let words = segment.words.compactMap { word -> TranscriptWord? in
                    let startTime = word.startTime + chunk.contextStartTime
                    let endTime = word.endTime + chunk.contextStartTime
                    guard
                        endTime >= chunk.requestedStartTime,
                        startTime <= chunk.requestedEndTime
                    else {
                        return nil
                    }

                    let candidate = TranscriptWord(
                        id: word.id,
                        text: word.text,
                        rawText: word.rawText,
                        punctuatedText: word.punctuatedText,
                        startTime: min(max(startTime, 0), sourceDuration),
                        endTime: min(max(endTime, startTime), sourceDuration),
                        confidence: word.confidence,
                        speakerID: word.speakerID,
                        speakerConfidence: word.speakerConfidence,
                        channelIndex: word.channelIndex
                    )
                    acceptedWords.removeAll { $0.endTime < candidate.startTime - 8 }
                    guard !acceptedWords.contains(where: { isDuplicateWord($0, candidate) }) else {
                        return nil
                    }
                    acceptedWords.append(candidate)
                    return candidate
                }
                guard !words.isEmpty else {
                    continue
                }

                stitchedSegments.append(TranscriptSegment(
                    id: segment.id,
                    speakerID: segment.speakerID,
                    speakerLabel: segment.speakerLabel,
                    startTime: words.first?.startTime ?? min(max(shiftedSegmentStart, 0), sourceDuration),
                    endTime: words.last?.endTime ?? min(max(shiftedSegmentEnd, 0), sourceDuration),
                    text: words.map(\.text).joined(separator: " "),
                    words: words,
                    confidence: segment.confidence,
                    speakerConfidence: segment.speakerConfidence,
                    channelIndex: segment.channelIndex
                ))
            }
        }

        return TranscriptDocument(
            sourceKind: .track,
            trackID: trackID,
            sourceRevision: sourceRevision,
            sourceDuration: sourceDuration,
            languageCode: languageCode,
            providerIdentifier: providerIdentifier,
            providerDisplayName: providerDisplayName,
            providerRequestID: chunkTranscripts
                .sorted(by: { $0.chunk.index < $1.chunk.index })
                .compactMap(\.transcript.providerRequestID)
                .joined(separator: ","),
            providerModelName: chunkTranscripts
                .sorted(by: { $0.chunk.index < $1.chunk.index })
                .compactMap(\.transcript.providerModelName)
                .first,
            segments: mergeAdjacentSegments(stitchedSegments)
        )
    }

    private static func isDuplicateWord(_ lhs: TranscriptWord, _ rhs: TranscriptWord) -> Bool {
        guard normalizedText(lhs.text) == normalizedText(rhs.text) else {
            return false
        }

        let overlapStart = max(lhs.startTime, rhs.startTime)
        let overlapEnd = min(lhs.endTime, rhs.endTime)
        let overlap = max(0, overlapEnd - overlapStart)
        let shorterDuration = max(min(lhs.endTime - lhs.startTime, rhs.endTime - rhs.startTime), 0.001)
        if overlap / shorterDuration >= 0.45 {
            return true
        }

        let lhsMidpoint = (lhs.startTime + lhs.endTime) * 0.5
        let rhsMidpoint = (rhs.startTime + rhs.endTime) * 0.5
        return abs(lhsMidpoint - rhsMidpoint) <= 0.18
    }

    private static func normalizedText(_ value: String) -> String {
        value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    private static func mergeAdjacentSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let sortedSegments = segments.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.endTime < rhs.endTime
            }
            return lhs.startTime < rhs.startTime
        }
        guard !sortedSegments.isEmpty else {
            return []
        }

        var merged: [TranscriptSegment] = []
        for segment in sortedSegments {
            guard
                let last = merged.last,
                last.speakerID == segment.speakerID,
                segment.startTime - last.endTime <= 1.25
            else {
                merged.append(segment)
                continue
            }

            let combinedWords = last.words + segment.words
            merged[merged.count - 1] = TranscriptSegment(
                id: last.id,
                speakerID: last.speakerID,
                speakerLabel: last.speakerLabel,
                startTime: last.startTime,
                endTime: max(last.endTime, segment.endTime),
                text: combinedWords.map(\.text).joined(separator: " "),
                words: combinedWords,
                confidence: last.confidence ?? segment.confidence,
                speakerConfidence: last.speakerConfidence ?? segment.speakerConfidence,
                channelIndex: last.channelIndex ?? segment.channelIndex
            )
        }

        return merged
    }
}
