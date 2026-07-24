import Foundation

enum TranscriptExportFormat: String, Codable, CaseIterable, Sendable {
    case plainText
    case srt
    case vtt
    case json
}

enum TranscriptExporter {
    static func export(_ transcript: TranscriptDocument, as format: TranscriptExportFormat) throws -> Data {
        switch format {
        case .plainText:
            return plainText(transcript).data(using: .utf8) ?? Data()
        case .srt:
            return srt(transcript).data(using: .utf8) ?? Data()
        case .vtt:
            return vtt(transcript).data(using: .utf8) ?? Data()
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(transcript)
        }
    }

    static func plainText(_ transcript: TranscriptDocument) -> String {
        transcript.segments
            .map { segment in
                let speakerPrefix = segment.speakerLabel.map { "\($0): " } ?? ""
                return speakerPrefix + segment.text
            }
            .joined(separator: "\n\n")
    }

    static func srt(_ transcript: TranscriptDocument) -> String {
        transcript.segments.enumerated().map { index, segment in
            [
                "\(index + 1)",
                "\(srtTimestamp(segment.startTime)) --> \(srtTimestamp(segment.endTime))",
                segmentText(segment),
            ].joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }

    static func vtt(_ transcript: TranscriptDocument) -> String {
        let body = transcript.segments.map { segment in
            [
                "\(vttTimestamp(segment.startTime)) --> \(vttTimestamp(segment.endTime))",
                segmentText(segment),
            ].joined(separator: "\n")
        }.joined(separator: "\n\n")
        return "WEBVTT\n\n\(body)\n"
    }

    private static func segmentText(_ segment: TranscriptSegment) -> String {
        if let speakerLabel = segment.speakerLabel, !speakerLabel.isEmpty {
            return "<v \(speakerLabel)>\(segment.text)"
        }
        return segment.text
    }

    private static func srtTimestamp(_ time: TimeInterval) -> String {
        timestamp(time, decimalSeparator: ",")
    }

    private static func vttTimestamp(_ time: TimeInterval) -> String {
        timestamp(time, decimalSeparator: ".")
    }

    private static func timestamp(_ time: TimeInterval, decimalSeparator: String) -> String {
        let milliseconds = max(Int((time * 1_000).rounded()), 0)
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let seconds = (milliseconds % 60_000) / 1_000
        let millis = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, decimalSeparator, millis)
    }
}
