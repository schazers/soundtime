import Foundation

public struct DiagnosticQuery: Sendable {
    public let source: String
    public init(_ source: String) { self.source = source }

    public func matches(_ event: DiagnosticEvent, now: Date = Date()) -> Bool {
        for token in Self.tokens(source) {
            if token.hasPrefix("category:") {
                guard event.category.rawValue == String(token.dropFirst(9)) else { return false }
            } else if token.hasPrefix("severity:") {
                guard event.severity.rawValue == String(token.dropFirst(9)) else { return false }
            } else if token.hasPrefix("name:") {
                guard event.name.localizedCaseInsensitiveContains(String(token.dropFirst(5))) else { return false }
            } else if token.hasPrefix("field.") {
                let pair = token.dropFirst(6).split(separator: ":", maxSplits: 1).map(String.init)
                if pair.count != 2 || event.fields[pair[0]]?.localizedCaseInsensitiveContains(pair[1]) != true { return false }
            } else if token.hasPrefix("after:-") {
                guard let seconds = Self.duration(String(token.dropFirst(7))), event.wallTime >= now.addingTimeInterval(-seconds) else { return false }
            } else if token.hasPrefix("text:") {
                let value = String(token.dropFirst(5))
                if !Self.searchText(event).localizedCaseInsensitiveContains(value) { return false }
            } else if token.contains(":") {
                let pair = token.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2,
                      event.fields[pair[0]]?.localizedCaseInsensitiveContains(pair[1]) == true
                else { return false }
            } else if !Self.searchText(event).localizedCaseInsensitiveContains(token) {
                return false
            }
        }
        return true
    }

    private static func searchText(_ event: DiagnosticEvent) -> String {
        ([event.category.rawValue, event.severity.rawValue, event.name, event.message] + event.fields.flatMap { [$0.key, $0.value] }).joined(separator: " ")
    }
    private static func tokens(_ input: String) -> [String] {
        input.split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }
    private static func duration(_ value: String) -> TimeInterval? {
        guard let unit = value.last else { return nil }
        let amount = Double(value.dropLast()) ?? Double(value) ?? 0
        switch unit { case "s": return amount; case "m": return amount * 60; case "h": return amount * 3600; default: return Double(value) }
    }
}

public enum DiagnosticPrivacy {
    public static let sensitiveKeys = ["apiKey", "token", "transcript", "path", "project", "username", "email"]
    public static func redact(_ event: DiagnosticEvent, includeIdentifiable: Bool) -> DiagnosticEvent {
        guard !includeIdentifiable else { return event }
        let values = event.typedFields.mapValues { value -> DiagnosticFieldValue in
            if case .string(let text) = value { return .string(redactText(text)) }
            return value
        }.filter { key, _ in !sensitiveKeys.contains(where: { key.localizedCaseInsensitiveContains($0) }) }
        return DiagnosticEvent(sequence: event.sequence, wallTime: event.wallTime, monotonicTime: event.monotonicTime,
            sessionID: event.sessionID, buildVersion: event.buildVersion, processID: event.processID,
            subsystem: event.subsystem, category: event.category, severity: event.severity,
            name: event.name, message: redactText(event.message), typedFields: values,
            correlation: event.correlation, eventID: event.eventID)
    }
    private static func redactText(_ text: String) -> String {
        text.replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "/Users/<redacted>", options: .regularExpression)
    }

    public static func redactJSONObject(_ value: Any, includeIdentifiable: Bool) -> Any {
        guard !includeIdentifiable else { return value }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                guard !sensitiveKeys.contains(where: { pair.key.localizedCaseInsensitiveContains($0) }) else {
                    return
                }
                result[pair.key] = redactJSONObject(pair.value, includeIdentifiable: false)
            }
        }
        if let array = value as? [Any] {
            return array.map { redactJSONObject($0, includeIdentifiable: false) }
        }
        if let text = value as? String { return redactText(text) }
        return value
    }
}
