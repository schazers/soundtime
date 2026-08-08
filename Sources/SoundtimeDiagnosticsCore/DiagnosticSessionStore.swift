import Foundation
import Darwin

public struct DiagnosticSessionMetadata: Codable, Sendable {
    public let sessionID: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var complete: Bool
    public var pinned: Bool
    public var eventCount: UInt64
    public var processID: Int32
    public var buildVersion: String
    public var recoveryPromptAcknowledgedAt: Date?
}

public struct DiagnosticSessionFiles: Sendable {
    public let eventsURL: URL
    public let metadataURL: URL
    public let metadata: DiagnosticSessionMetadata

    public init(eventsURL: URL, metadataURL: URL, metadata: DiagnosticSessionMetadata) {
        self.eventsURL = eventsURL
        self.metadataURL = metadataURL
        self.metadata = metadata
    }
}

public final class DiagnosticSessionStore: @unchecked Sendable {
    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Soundtime/Sessions", isDirectory: true)
    }
    public let rootURL: URL
    public let sessionID: UUID
    public let eventsURL: URL
    public let metadataURL: URL
    private let queue = DispatchQueue(label: "Soundtime.Diagnostics.SessionStore", qos: .utility)
    private var handle: FileHandle?
    private var metadata: DiagnosticSessionMetadata
    private let encoder: JSONEncoder
    private var pendingFlushCount = 0

    public init(rootURL: URL = defaultRootURL, buildVersion: String = "development", sessionID: UUID = UUID()) throws {
        self.rootURL = rootURL; self.sessionID = sessionID
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = "\(stamp)-\(sessionID.uuidString.lowercased())"
        eventsURL = rootURL.appendingPathComponent(base + ".jsonl")
        metadataURL = rootURL.appendingPathComponent(base + ".meta.json")
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: eventsURL)
        metadata = .init(sessionID: sessionID, startedAt: Date(), endedAt: nil, complete: false,
            pinned: false, eventCount: 0, processID: ProcessInfo.processInfo.processIdentifier,
            buildVersion: buildVersion, recoveryPromptAcknowledgedAt: nil)
        encoder = DiagnosticJSON.makeEncoder()
        try writeMetadata()
        try Self.updateLatest(rootURL: rootURL, eventsURL: eventsURL, metadataURL: metadataURL)
        try Self.rotate(rootURL: rootURL)
    }

    public func append(_ event: DiagnosticEvent, flush: Bool = false) {
        queue.async { [self] in
            do {
                var data = try encoder.encode(event); data.append(0x0A)
                try handle?.write(contentsOf: data)
                metadata.eventCount += 1; pendingFlushCount += 1
                if flush || pendingFlushCount >= 32 { try handle?.synchronize(); pendingFlushCount = 0; try writeMetadata() }
            } catch { Self.emergency(error, rootURL: rootURL) }
        }
    }

    public func pin() { queue.async { self.metadata.pinned = true; try? self.writeMetadata() } }
    public func finish() {
        queue.sync {
            metadata.complete = true; metadata.endedAt = Date()
            try? handle?.synchronize(); try? handle?.close(); handle = nil; try? writeMetadata()
        }
    }
    public func flush() { queue.sync { try? handle?.synchronize(); pendingFlushCount = 0; try? writeMetadata() } }

    private func writeMetadata() throws {
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    public static func readEvents(at url: URL) throws -> [DiagnosticEvent] {
        let data = try Data(contentsOf: url)
        let decoder = DiagnosticJSON.makeDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(DiagnosticEvent.self, from: Data($0)) }
    }
    public static func sessionFiles(rootURL: URL = defaultRootURL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    public static func incompleteSessions(rootURL: URL = defaultRootURL) -> [DiagnosticSessionMetadata] {
        incompleteSessionFiles(rootURL: rootURL).map(\.metadata)
    }

    public static func unacknowledgedIncompleteSessionFiles(
        rootURL: URL = defaultRootURL
    ) -> [DiagnosticSessionFiles] {
        incompleteSessionFiles(rootURL: rootURL).filter {
            guard $0.metadata.recoveryPromptAcknowledgedAt == nil else {
                return false
            }
            let eventFileSize = (try? $0.eventsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return $0.metadata.eventCount > 0 || eventFileSize > 0
        }
    }

    @discardableResult
    public static func acknowledgeRecoveryPrompt(
        sessionID: UUID,
        rootURL: URL = defaultRootURL,
        acknowledgedAt: Date = Date()
    ) -> Bool {
        guard let files = incompleteSessionFiles(rootURL: rootURL).first(where: {
            $0.metadata.sessionID == sessionID
        }) else {
            return false
        }

        var metadata = files.metadata
        metadata.recoveryPromptAcknowledgedAt = acknowledgedAt
        do {
            let data = try DiagnosticJSON.makeEncoder().encode(metadata)
            try data.write(to: files.metadataURL, options: .atomic)
            return true
        } catch {
            emergency(error, rootURL: rootURL)
            return false
        }
    }
    public static func incompleteSessionFiles(rootURL: URL = defaultRootURL) -> [DiagnosticSessionFiles] {
        let decoder = DiagnosticJSON.makeDecoder()
        return ((try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".meta.json") }
            .compactMap { metadataURL -> DiagnosticSessionFiles? in
                guard let metadata = try? decoder.decode(
                    DiagnosticSessionMetadata.self,
                    from: Data(contentsOf: metadataURL)
                ) else { return nil }
                let base = metadataURL.lastPathComponent.replacingOccurrences(of: ".meta.json", with: "")
                return DiagnosticSessionFiles(
                    eventsURL: rootURL.appendingPathComponent(base + ".jsonl"),
                    metadataURL: metadataURL,
                    metadata: metadata
                )
            }
            .filter {
                !$0.metadata.complete &&
                    $0.metadata.processID != ProcessInfo.processInfo.processIdentifier &&
                    kill($0.metadata.processID, 0) != 0 &&
                    FileManager.default.fileExists(atPath: $0.eventsURL.path)
            }
            .sorted { $0.metadata.startedAt > $1.metadata.startedAt }
    }
    private static func updateLatest(rootURL: URL, eventsURL: URL, metadataURL: URL) throws {
        let pointer = ["events": eventsURL.lastPathComponent, "metadata": metadataURL.lastPathComponent]
        let data = try JSONSerialization.data(withJSONObject: pointer, options: [.sortedKeys])
        try data.write(to: rootURL.appendingPathComponent("Latest.json"), options: .atomic)
    }
    private static func rotate(rootURL: URL, maxSessions: Int = 20, maxBytes: Int64 = 100 * 1_024 * 1_024) throws {
        var files = sessionFiles(rootURL: rootURL)
        var total = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let decoder = DiagnosticJSON.makeDecoder()
        while files.count > maxSessions || total > maxBytes, let candidate = files.last {
            let metaURL = URL(fileURLWithPath: candidate.path.replacingOccurrences(of: ".jsonl", with: ".meta.json"))
            let pinned = (try? Data(contentsOf: metaURL)).flatMap {
                try? decoder.decode(DiagnosticSessionMetadata.self, from: $0)
            }?.pinned ?? false
            if pinned { files.removeLast(); continue }
            let size = Int64((try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: candidate); try? FileManager.default.removeItem(at: metaURL)
            total -= size; files.removeLast()
        }
    }
    private static func emergency(_ error: Error, rootURL: URL) {
        let text = "\(Date()) diagnostics write failed: \(error)\n"
        guard let data = text.data(using: .utf8) else { return }
        let url = rootURL.appendingPathComponent("write-errors.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
