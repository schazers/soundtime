import Foundation

public struct DiagnosticIncident: Codable, Identifiable, Sendable {
    public let id: UUID; public let sessionID: UUID; public let markedAt: Date
    public let start: Date; public let end: Date; public let note: String?
    public init(sessionID: UUID, markedAt: Date = Date(), before: TimeInterval = 30, after: TimeInterval = 15, note: String? = nil) {
        id = UUID(); self.sessionID = sessionID; self.markedAt = markedAt
        start = markedAt.addingTimeInterval(-before); end = markedAt.addingTimeInterval(after); self.note = note
    }
}

public enum DiagnosticBundleExporter {
    public static func export(sessionURL: URL, incident: DiagnosticIncident? = nil,
                              outputURL: URL, includeIdentifiable: Bool = false,
                              supplemental: [String: Any] = [:]) throws -> URL {
        let events = try DiagnosticSessionStore.readEvents(at: sessionURL)
            .filter { incident == nil || ($0.wallTime >= incident!.start && $0.wallTime <= incident!.end) }
            .map { DiagnosticPrivacy.redact($0, includeIdentifiable: includeIdentifiable) }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Soundtime-Diagnostics-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        // JSONL requires exactly one complete JSON value per physical line.
        let jsonlEncoder = DiagnosticJSON.makeEncoder()
        let jsonl = try events.map { try jsonlEncoder.encode($0) }.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        try jsonl.write(to: staging.appendingPathComponent("events.jsonl"), options: .atomic)
        let severe = events.filter { $0.severity == .severe }
        let warnings = events.filter { $0.severity == .warning }
        let safeSupplemental = DiagnosticPrivacy.redactJSONObject(
            supplemental,
            includeIdentifiable: includeIdentifiable
        ) as? [String: Any] ?? [:]
        let manifest: [String: Any] = ["schemaVersion": 1, "createdAt": ISO8601DateFormatter().string(from: Date()),
            "eventCount": events.count, "warningCount": warnings.count, "severeCount": severe.count,
            "privacy": includeIdentifiable ? "identifiable" : "redacted", "supplemental": safeSupplemental,
            "crashReports": recentCrashReports()]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        let summary = Self.summary(events: events, incident: incident)
        try summary.write(to: staging.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        let performanceEvents = events.filter { [.render, .threading, .waveform, .interaction].contains($0.category) }
        let audioEvents = events.filter { $0.category == .audio || $0.category == .device || $0.category == .playback }
        let launchEvents = events.filter { $0.category == .launch || $0.name.localizedCaseInsensitiveContains("launch") }
        let operationEvents = events.filter { $0.correlation?.operationID != nil }
        try writeContext(name: "performance", snapshot: safeSupplemental["performance"], events: performanceEvents, staging: staging)
        try writeContext(name: "audio", snapshot: safeSupplemental["audio"], events: audioEvents, staging: staging)
        try writeContext(name: "launch", snapshot: safeSupplemental["launch"], events: launchEvents, staging: staging)
        try writeContext(name: "operations", snapshot: safeSupplemental["operations"], events: operationEvents, staging: staging)
        let revisions: [String: Any] = [
            "project": Array(Set(events.compactMap { $0.correlation?.projectRevision })).sorted(),
            "graph": Array(Set(events.compactMap { $0.correlation?.graphRevision })).sorted(),
        ]
        for (name, value) in [
            ("revisions", revisions),
            ("config", safeSupplemental["config"] ?? [:]),
            ("build", safeSupplemental["build"] ?? [:]),
            ("system", safeSupplemental["system"] ?? [:]),
        ] {
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: staging.appendingPathComponent("\(name).json"), options: .atomic)
        }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, outputURL.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return outputURL
    }
    private static func summary(events: [DiagnosticEvent], incident: DiagnosticIncident?) -> String {
        let firstSevere = events.first { $0.severity == .severe }
        let selected = events.filter { $0.name.contains("stall") || $0.name.contains("underrun") || $0.name.contains("graph") || $0.name.contains("waveform") }
        let formatter = ISO8601DateFormatter()
        let nearbyDetails = selected.prefix(20).map { event in
            "- \(formatter.string(from: event.wallTime)) [\(event.severity.rawValue.uppercased())] \(event.category.rawValue).\(event.name): \(event.message)"
        }.joined(separator: "\n")
        let activeOperations = events.compactMap { event -> String? in
            guard let kind = event.correlation?.operationKind else { return nil }
            return event.correlation?.operationID.map { "\(kind) (\($0.uuidString))" } ?? kind
        }.unique()
        return """
        # Soundtime Diagnostic Summary

        - Incident: \(incident?.id.uuidString ?? "session export")
        - Events: \(events.count)
        - First severe: \(firstSevere.map { "\($0.name): \($0.message)" } ?? "none")
        - Nearby stalls/underruns/waveform/graph events: \(selected.count)

        ## Active operations
        \(activeOperations.isEmpty ? "none" : activeOperations.joined(separator: ", "))

        ## Relevant event timeline
        \(nearbyDetails.isEmpty ? "No stall, underrun, waveform, or graph events were captured in this window." : nearbyDetails)
        """
    }

    private static func writeContext(
        name: String,
        snapshot: Any?,
        events: [DiagnosticEvent],
        staging: URL
    ) throws {
        let formatter = ISO8601DateFormatter()
        let eventValues: [[String: Any]] = events.map { event in
            var value: [String: Any] = [
                "eventID": event.eventID.uuidString,
                "sequence": event.sequence,
                "wallTime": formatter.string(from: event.wallTime),
                "category": event.category.rawValue,
                "severity": event.severity.rawValue,
                "name": event.name,
                "message": event.message,
                "fields": event.fields,
            ]
            if let operationID = event.correlation?.operationID {
                value["operationID"] = operationID.uuidString
            }
            return value
        }
        let value: [String: Any] = ["snapshot": snapshot ?? [:], "events": eventValues]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appendingPathComponent("\(name).json"), options: .atomic)
    }
    private static func recentCrashReports() -> [String] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.localizedCaseInsensitiveContains("Soundtime") && ["crash", "ips"].contains($0.pathExtension) }
            .filter { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > Date().addingTimeInterval(-7 * 86_400) }
            .map(\.lastPathComponent)
    }
}

private extension Sequence where Element: Hashable {
    func unique() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
