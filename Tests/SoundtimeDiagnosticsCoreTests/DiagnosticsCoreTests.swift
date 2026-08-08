import XCTest
@testable import SoundtimeDiagnosticsCore

final class DiagnosticsCoreTests: XCTestCase {
    private func event(sequence: UInt64 = 1, severity: DiagnosticSeverity = .info,
                       fields: [String: DiagnosticFieldValue] = [:], wallTime: Date = Date()) -> DiagnosticEvent {
        DiagnosticEvent(sequence: sequence, wallTime: wallTime, monotonicTime: Double(sequence),
            sessionID: UUID(), buildVersion: "test", category: .edit, severity: severity,
            name: "delete-started", message: "Deleted /Users/jason/private.wav", typedFields: fields,
            correlation: .init(operationID: UUID(), operationKind: "delete", projectRevision: 2, graphRevision: 42))
    }

    func testSchemaTwoRoundTripAndLegacyMigration() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = DiagnosticJSON.makeDecoder()
        XCTAssertEqual(try decoder.decode(DiagnosticEvent.self, from: encoder.encode(event())).schemaVersion, 2)
        let legacy = #"{"timestamp":12.5,"category":"edit","severity":"warning","name":"old","message":"legacy","fields":{"value":"7"}}"#.data(using: .utf8)!
        let decoded = try decoder.decode(DiagnosticEvent.self, from: legacy)
        XCTAssertEqual(decoded.timestamp, 12.5); XCTAssertEqual(decoded.fields["value"], "7")
    }

    func testQueryGrammar() {
        let value = event(severity: .severe, fields: ["graphRevision": .integer(42)])
        XCTAssertTrue(DiagnosticQuery("severity:severe field.graphRevision:42 delete").matches(value))
        XCTAssertTrue(DiagnosticQuery("graphRevision:42").matches(value))
        XCTAssertFalse(DiagnosticQuery("category:audio").matches(value))
        XCTAssertFalse(DiagnosticQuery("unknown:value").matches(value))
        XCTAssertTrue(DiagnosticQuery("after:-30s").matches(value))
    }

    func testRedaction() {
        let value = event(fields: ["apiKey": .string("secret"), "frame": .integer(2)])
        let redacted = DiagnosticPrivacy.redact(value, includeIdentifiable: false)
        XCTAssertNil(redacted.fields["apiKey"]); XCTAssertEqual(redacted.fields["frame"], "2")
        XCTAssertFalse(redacted.message.contains("jason"))
    }

    func testConcurrentAppendAndTruncatedRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiagnosticSessionStore(rootURL: root, buildVersion: "test")
        let sessionID = UUID()
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            store.append(DiagnosticEvent(sequence: UInt64(index), monotonicTime: Double(index),
                sessionID: sessionID, buildVersion: "test", category: .system, severity: .info,
                name: "concurrent", message: "event"))
        }
        store.flush()
        try FileHandle(forWritingTo: store.eventsURL).seekToEndAndWrite(Data("{truncated".utf8))
        XCTAssertEqual(try DiagnosticSessionStore.readEvents(at: store.eventsURL).count, 100)
        store.finish()
    }

    func testIncidentBundleContainsRequiredFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiagnosticSessionStore(rootURL: root, buildVersion: "test")
        store.append(event(severity: .severe), flush: true); store.flush()
        let output = root.appendingPathComponent("bundle.zip")
        _ = try DiagnosticBundleExporter.export(sessionURL: store.eventsURL,
            incident: DiagnosticIncident(sessionID: store.sessionID), outputURL: output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let listing = try run("/usr/bin/unzip", ["-l", output.path])
        for name in ["manifest.json", "events.jsonl", "summary.md", "audio.json", "performance.json", "launch.json"] {
            XCTAssertTrue(listing.contains(name), name)
        }
        store.finish()
    }

    func testIncidentBundleIncludesOnlyTheMarkedWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiagnosticSessionStore(rootURL: root, buildVersion: "test")
        let markedAt = Date()
        store.append(event(sequence: 1, wallTime: markedAt.addingTimeInterval(-31)))
        store.append(event(sequence: 2, wallTime: markedAt.addingTimeInterval(-29.9)))
        store.append(event(sequence: 3, wallTime: markedAt.addingTimeInterval(14.9)))
        store.append(event(sequence: 4, wallTime: markedAt.addingTimeInterval(16)))
        store.flush()

        let output = root.appendingPathComponent("window.soundtimediagnostics.zip")
        _ = try DiagnosticBundleExporter.export(
            sessionURL: store.eventsURL,
            incident: DiagnosticIncident(sessionID: store.sessionID, markedAt: markedAt),
            outputURL: output
        )
        let destination = root.appendingPathComponent("expanded")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try run("/usr/bin/ditto", ["-x", "-k", output.path, destination.path])
        let bundledEvents = try DiagnosticSessionStore.readEvents(
            at: destination.appendingPathComponent("events.jsonl")
        )
        XCTAssertEqual(bundledEvents.map(\.sequence), [2, 3])
        store.finish()
    }

    func testBundleRedactsSupplementalMetadataByDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiagnosticSessionStore(rootURL: root, buildVersion: "test")
        store.append(event(fields: ["sourcePath": .string("/Users/jason/private.wav")]), flush: true)
        store.flush()
        let output = root.appendingPathComponent("redacted.soundtimediagnostics.zip")
        _ = try DiagnosticBundleExporter.export(
            sessionURL: store.eventsURL,
            outputURL: output,
            supplemental: [
                "config": ["projectPath": "/Users/jason/secret.soundtime", "mode": "debug"],
                "system": ["home": "/Users/jason"],
            ]
        )
        let destination = root.appendingPathComponent("redacted-expanded")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try run("/usr/bin/ditto", ["-x", "-k", output.path, destination.path])
        let bundleText = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            .filter { ["json", "jsonl", "md"].contains($0.pathExtension) }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(bundleText.contains("jason"))
        XCTAssertFalse(bundleText.contains("secret.soundtime"))
        XCTAssertTrue(bundleText.contains("debug"))
        store.finish()
    }

    func testMidSessionStorageFailureNeverEscapesToCaller() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try DiagnosticSessionStore(rootURL: root, buildVersion: "test")
        try FileManager.default.removeItem(at: root)
        store.append(event(), flush: true)
        store.flush()
        store.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testIncompleteSessionRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiagnosticSessionStore(rootURL: root, buildVersion: "test")
        store.append(event(), flush: true)
        store.flush()
        let decoder = DiagnosticJSON.makeDecoder()
        var metadata = try decoder.decode(DiagnosticSessionMetadata.self, from: Data(contentsOf: store.metadataURL))
        metadata.processID = 999_999
        let encoder = DiagnosticJSON.makeEncoder()
        try encoder.encode(metadata).write(to: store.metadataURL, options: .atomic)
        XCTAssertEqual(DiagnosticSessionStore.incompleteSessions(rootURL: root).count, 1)
        XCTAssertEqual(
            DiagnosticSessionStore.unacknowledgedIncompleteSessionFiles(rootURL: root).count,
            1
        )
        XCTAssertTrue(
            DiagnosticSessionStore.acknowledgeRecoveryPrompt(
                sessionID: metadata.sessionID,
                rootURL: root
            )
        )
        XCTAssertEqual(DiagnosticSessionStore.incompleteSessions(rootURL: root).count, 1)
        XCTAssertTrue(
            DiagnosticSessionStore.unacknowledgedIncompleteSessionFiles(rootURL: root).isEmpty
        )
    }

    func testEmptyIncompleteSessionDoesNotRequestRecoveryPrompt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiagnosticSessionStore(rootURL: root, buildVersion: "test")
        store.flush()

        let decoder = DiagnosticJSON.makeDecoder()
        var metadata = try decoder.decode(
            DiagnosticSessionMetadata.self,
            from: Data(contentsOf: store.metadataURL)
        )
        metadata.processID = 999_999
        try DiagnosticJSON.makeEncoder().encode(metadata).write(to: store.metadataURL, options: .atomic)

        XCTAssertEqual(DiagnosticSessionStore.incompleteSessions(rootURL: root).count, 1)
        XCTAssertTrue(
            DiagnosticSessionStore.unacknowledgedIncompleteSessionFiles(rootURL: root).isEmpty
        )
    }

    func testInvalidStorageRootFailsWithoutAffectingCaller() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try DiagnosticSessionStore(rootURL: root, buildVersion: "test"))
    }

    func testRetentionCapsUnpinnedSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<23 {
            let store = try DiagnosticSessionStore(rootURL: root, buildVersion: "test")
            store.append(event()); store.finish()
        }
        XCTAssertLessThanOrEqual(DiagnosticSessionStore.sessionFiles(rootURL: root).count, 20)
    }

    func testRetentionNeverDeletesPinnedSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pinned = try DiagnosticSessionStore(rootURL: root, buildVersion: "test")
        let pinnedURL = pinned.eventsURL
        pinned.pin()
        pinned.flush()
        pinned.finish()
        for _ in 0..<24 {
            let store = try DiagnosticSessionStore(rootURL: root, buildVersion: "test")
            store.append(event())
            store.finish()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedURL.path))
    }

    func testTypedFieldInference() {
        XCTAssertEqual(DiagnosticFieldValue.inferred(from: "42"), .integer(42))
        XCTAssertEqual(DiagnosticFieldValue.inferred(from: "3.5"), .number(3.5))
        XCTAssertEqual(DiagnosticFieldValue.inferred(from: "true"), .boolean(true))
        XCTAssertEqual(DiagnosticFieldValue.inferred(from: "0042"), .string("0042"))
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let pipe = Pipe(); let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.standardOutput = pipe; try process.run(); process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

private extension FileHandle {
    func seekToEndAndWrite(_ data: Data) throws { _ = try seekToEnd(); try write(contentsOf: data); try close() }
}
