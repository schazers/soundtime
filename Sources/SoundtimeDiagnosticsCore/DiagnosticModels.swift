import Foundation

public enum DiagnosticJSON {
    public static func makeEncoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalFormatter().string(from: date))
        }
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = fractionalFormatter().date(from: value) ?? ISO8601DateFormatter().date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(value)")
        }
        return decoder
    }

    private static func fractionalFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

public enum DiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    case info, warning, severe
}

public enum DiagnosticCategory: String, Codable, CaseIterable, Sendable {
    case api, audio, render, edit, device, interaction, waveform, threading, system
    case launch, `import`, playback, export, transcription, hydration
}

public enum DiagnosticFieldValue: Codable, Hashable, Sendable {
    case string(String), integer(Int64), number(Double), boolean(Bool), null

    public var stringValue: String {
        switch self {
        case .string(let value): value
        case .integer(let value): String(value)
        case .number(let value): String(value)
        case .boolean(let value): String(value)
        case .null: "null"
        }
    }

    public init(_ value: String) { self = .string(value) }

    public static func inferred(from value: String) -> Self {
        if value == "true" { return .boolean(true) }
        if value == "false" { return .boolean(false) }
        if let integer = Int64(value), String(integer) == value { return .integer(integer) }
        if let number = Double(value), value.contains(".") { return .number(number) }
        return .string(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct DiagnosticCorrelation: Codable, Hashable, Sendable {
    public var operationID: UUID?
    public var operationKind: String?
    public var projectRevision: Int64?
    public var graphRevision: Int64?

    public init(operationID: UUID? = nil, operationKind: String? = nil,
                projectRevision: Int64? = nil, graphRevision: Int64? = nil) {
        self.operationID = operationID
        self.operationKind = operationKind
        self.projectRevision = projectRevision
        self.graphRevision = graphRevision
    }
}

public struct DiagnosticEvent: Codable, Hashable, Identifiable, Sendable {
    public static let currentSchemaVersion = 2
    public let schemaVersion: Int
    public let eventID: UUID
    public let sequence: UInt64
    public let wallTime: Date
    public let monotonicTime: TimeInterval
    public let sessionID: UUID
    public let buildVersion: String
    public let processID: Int32
    public let subsystem: String
    public let category: DiagnosticCategory
    public let severity: DiagnosticSeverity
    public let name: String
    public let message: String
    public let typedFields: [String: DiagnosticFieldValue]
    public let correlation: DiagnosticCorrelation?

    public var id: UUID { eventID }
    public var timestamp: TimeInterval { monotonicTime }
    public var fields: [String: String] { typedFields.mapValues(\.stringValue) }

    public init(sequence: UInt64, wallTime: Date = Date(), monotonicTime: TimeInterval,
                sessionID: UUID, buildVersion: String, processID: Int32 = ProcessInfo.processInfo.processIdentifier,
                subsystem: String = "com.soundtime.app", category: DiagnosticCategory,
                severity: DiagnosticSeverity, name: String, message: String,
                typedFields: [String: DiagnosticFieldValue] = [:], correlation: DiagnosticCorrelation? = nil,
                eventID: UUID = UUID()) {
        schemaVersion = Self.currentSchemaVersion
        self.eventID = eventID; self.sequence = sequence; self.wallTime = wallTime
        self.monotonicTime = monotonicTime; self.sessionID = sessionID; self.buildVersion = buildVersion
        self.processID = processID; self.subsystem = subsystem; self.category = category
        self.severity = severity; self.name = name; self.message = message
        self.typedFields = typedFields; self.correlation = correlation
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, eventID, sequence, wallTime, monotonicTime, timestamp, sessionID
        case buildVersion, processID, subsystem, category, severity, name, message, typedFields, fields, correlation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        eventID = try c.decodeIfPresent(UUID.self, forKey: .eventID) ?? UUID()
        sequence = try c.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
        wallTime = try c.decodeIfPresent(Date.self, forKey: .wallTime) ?? Date()
        monotonicTime = try c.decodeIfPresent(Double.self, forKey: .monotonicTime)
            ?? c.decodeIfPresent(Double.self, forKey: .timestamp) ?? 0
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID) ?? UUID()
        buildVersion = try c.decodeIfPresent(String.self, forKey: .buildVersion) ?? "legacy"
        processID = try c.decodeIfPresent(Int32.self, forKey: .processID) ?? 0
        subsystem = try c.decodeIfPresent(String.self, forKey: .subsystem) ?? "com.soundtime.legacy"
        category = try c.decode(DiagnosticCategory.self, forKey: .category)
        severity = try c.decode(DiagnosticSeverity.self, forKey: .severity)
        name = try c.decode(String.self, forKey: .name)
        message = try c.decode(String.self, forKey: .message)
        if let values = try c.decodeIfPresent([String: DiagnosticFieldValue].self, forKey: .typedFields) {
            typedFields = values
        } else {
            typedFields = (try c.decodeIfPresent([String: String].self, forKey: .fields) ?? [:]).mapValues(DiagnosticFieldValue.string)
        }
        correlation = try c.decodeIfPresent(DiagnosticCorrelation.self, forKey: .correlation)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(eventID, forKey: .eventID); try c.encode(sequence, forKey: .sequence)
        try c.encode(wallTime, forKey: .wallTime); try c.encode(monotonicTime, forKey: .monotonicTime)
        try c.encode(sessionID, forKey: .sessionID); try c.encode(buildVersion, forKey: .buildVersion)
        try c.encode(processID, forKey: .processID); try c.encode(subsystem, forKey: .subsystem)
        try c.encode(category, forKey: .category); try c.encode(severity, forKey: .severity)
        try c.encode(name, forKey: .name); try c.encode(message, forKey: .message)
        try c.encode(typedFields, forKey: .typedFields); try c.encodeIfPresent(correlation, forKey: .correlation)
    }
}

public enum DiagnosticEventCatalog {
    public struct Definition: Sendable {
        public let name: String
        public let category: DiagnosticCategory
        public let defaultSeverity: DiagnosticSeverity
        public let expectedFields: Set<String>

        public init(
            name: String,
            category: DiagnosticCategory,
            defaultSeverity: DiagnosticSeverity = .info,
            expectedFields: Set<String>
        ) {
            self.name = name
            self.category = category
            self.defaultSeverity = defaultSeverity
            self.expectedFields = expectedFields
        }
    }

    public static let appLaunch = Definition(name: "app-launch", category: .launch, expectedFields: [])
    public static let importStarted = Definition(name: "import-started", category: .import, expectedFields: ["operationID"])
    public static let playbackStarted = Definition(name: "playback-started", category: .playback, expectedFields: ["graphRevision"])
    public static let deleteStarted = Definition(name: "delete-started", category: .edit, expectedFields: ["operationID", "graphRevision"])
    public static let pasteStarted = Definition(name: "paste-started", category: .edit, expectedFields: ["operationID", "graphRevision"])
    public static let undoStarted = Definition(name: "undo-started", category: .edit, expectedFields: ["operationID", "graphRevision"])
    public static let exportStarted = Definition(name: "export-started", category: .export, expectedFields: ["operationID"])
    public static let transcriptionStarted = Definition(name: "transcription-started", category: .transcription, expectedFields: ["operationID"])
    public static let hydrationStarted = Definition(name: "hydration-started", category: .hydration, expectedFields: ["operationID"])
    public static let timelineFrameDrop = Definition(
        name: "timeline-frame-drop",
        category: .render,
        defaultSeverity: .warning,
        expectedFields: ["fps", "averageFrameMs", "worstFrameMs"]
    )

    public static let definitions: [String: Definition] = [
        appLaunch.name: appLaunch,
        importStarted.name: importStarted,
        playbackStarted.name: playbackStarted,
        deleteStarted.name: deleteStarted,
        pasteStarted.name: pasteStarted,
        undoStarted.name: undoStarted,
        exportStarted.name: exportStarted,
        transcriptionStarted.name: transcriptionStarted,
        hydrationStarted.name: hydrationStarted,
        timelineFrameDrop.name: timelineFrameDrop,
    ]
}
