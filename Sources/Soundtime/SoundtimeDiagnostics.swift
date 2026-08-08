import Foundation
import QuartzCore
import OSLog
import Darwin
import SoundtimeDiagnosticsCore

private func finishSoundtimeDiagnosticSessionAtProcessExit() {
    SoundtimeDiagnostics.shared.finishSession()
}

typealias SoundtimeDiagnosticSeverity = DiagnosticSeverity
typealias SoundtimeDiagnosticCategory = DiagnosticCategory
typealias SoundtimeDiagnosticEvent = DiagnosticEvent

struct SoundtimeDiagnosticsSnapshot: Sendable {
    let frameStats: TimelineFrameStats?
    let audioSnapshot: RealtimeAudioCoreSnapshot?
    let events: [SoundtimeDiagnosticEvent]
    let mainThreadStallCount: Int
    let lastMainThreadStallMilliseconds: Double
    let severeEventCount: Int
    let warningEventCount: Int
}

final class SoundtimeDiagnostics: @unchecked Sendable {
    struct Operation: Sendable {
        let id: UUID
        let kind: String
        let startedAt: TimeInterval
        let projectRevision: Int64?
        let graphRevision: Int64?
        var correlation: DiagnosticCorrelation { .init(operationID: id, operationKind: kind, projectRevision: projectRevision, graphRevision: graphRevision) }
    }
    static let shared = SoundtimeDiagnostics()
    static let didRecordEventNotification = Notification.Name("SoundtimeDiagnostics.didRecordEvent")
    static let recordedEventUserInfoKey = "event"

    private let lock = NSLock()
    private let maximumEventCount = 2_048
    private let traceWriteQueue = DispatchQueue(label: "Soundtime.diagnostics.trace", qos: .background)
    private let sessionID = UUID()
    private let buildVersion: String
    private let sessionStore: DiagnosticSessionStore?
    private let logger = Logger(subsystem: "com.soundtime.app", category: "diagnostics")
    private let signposter = OSSignposter(subsystem: "com.soundtime.app", category: "operations")
    private var nextSequence: UInt64 = 0
    private var activeOperationCorrelations: [String: DiagnosticCorrelation] = [:]
    private let severeTraceWriteThrottle: TimeInterval = 3
    private let automaticTraceQuietInterval: TimeInterval = 5
    private let frameDropEventThrottle: TimeInterval = 2
    private var events: [SoundtimeDiagnosticEvent] = []
    private var latestFrameStats: TimelineFrameStats?
    private var latestAudioSnapshot: RealtimeAudioCoreSnapshot?
    private var lastUnderrunCount = 0
    private var lastDroppedCommandCount = 0
    private var lastRenderDeadlineMissCount = 0
    private var lastRenderWorkDeadlineMissCount = 0
    private var lastCallbackSchedulingLateCount = 0
    private var lastTraceWriteByName: [String: TimeInterval] = [:]
    private var pendingAutomaticTraceWorkItem: DispatchWorkItem?
    private var lastFrameDropEventTime: TimeInterval = -Double.infinity
    private var lastMixerSnapshotEventTime: TimeInterval = -Double.infinity
    private var lastMixerDroppedPacketCount: UInt64 = 0
    private var lastMixerStalePacketCount: UInt64 = 0
    private var lastFrameDropEventSeverity: SoundtimeDiagnosticSeverity?
    private var suppressedFrameDropEventCount = 0
    private var mainThreadStallCount = 0
    private var lastMainThreadStallMilliseconds: Double = 0
    private var severeEventCount = 0
    private var warningEventCount = 0
    private var latestIncident: DiagnosticIncident?
    private var didFinishSession = false

    private init() {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "development"
        let build = info?["CFBundleVersion"] as? String ?? "local"
        buildVersion = "\(short) (\(build))"
        sessionStore = try? DiagnosticSessionStore(buildVersion: buildVersion, sessionID: sessionID)
        atexit(finishSoundtimeDiagnosticSessionAtProcessExit)
    }

    func record(
        category: SoundtimeDiagnosticCategory,
        severity: SoundtimeDiagnosticSeverity,
        name: String,
        message: String,
        fields: [String: String] = [:],
        correlation: DiagnosticCorrelation? = nil
    ) {
        lock.lock()
        nextSequence &+= 1
        let sequence = nextSequence
        let resolvedCorrelation = resolveCorrelationLocked(
            name: name,
            fields: fields,
            provided: correlation
        )
        var typedFields = fields.mapValues(DiagnosticFieldValue.inferred)
        if let operationID = resolvedCorrelation?.operationID { typedFields["operationID"] = .string(operationID.uuidString) }
        if let graphRevision = resolvedCorrelation?.graphRevision { typedFields["graphRevision"] = .integer(graphRevision) }
        if let projectRevision = resolvedCorrelation?.projectRevision { typedFields["projectRevision"] = .integer(projectRevision) }
        let event = SoundtimeDiagnosticEvent(
            sequence: sequence,
            monotonicTime: CACurrentMediaTime(),
            sessionID: sessionID,
            buildVersion: buildVersion,
            category: category,
            severity: severity,
            name: name,
            message: message,
            typedFields: typedFields,
            correlation: resolvedCorrelation
        )
        appendLocked(event)
        sessionStore?.append(event, flush: event.severity == .severe)
        lock.unlock()
        publish(event)
        if severity == .severe {
            writeTraceIfNeeded(for: event)
        }
    }

    func recordFrameStats(_ stats: TimelineFrameStats) {
        lock.lock()
        latestFrameStats = stats
        lock.unlock()

        let severity: SoundtimeDiagnosticSeverity
        if stats.framesPerSecond <= 60 ||
            stats.averageFrameTimeMilliseconds >= 16 ||
            stats.worstFrameTimeMilliseconds >= 48
        {
            severity = .severe
        } else if stats.framesPerSecond < 100 ||
            stats.averageFrameTimeMilliseconds >= 10.5 ||
            stats.worstFrameTimeMilliseconds >= 24
        {
            severity = .warning
        } else {
            return
        }

        let now = CACurrentMediaTime()
        lock.lock()
        let severityEscalated = severity == .severe && lastFrameDropEventSeverity != .severe
        let shouldRecord = now - lastFrameDropEventTime >= frameDropEventThrottle || severityEscalated
        let suppressedCount = suppressedFrameDropEventCount
        if shouldRecord {
            lastFrameDropEventTime = now
            lastFrameDropEventSeverity = severity
            suppressedFrameDropEventCount = 0
        } else {
            suppressedFrameDropEventCount += 1
        }
        lock.unlock()

        guard shouldRecord else {
            return
        }

        record(
            category: .render,
            severity: severity,
            name: DiagnosticEventCatalog.timelineFrameDrop.name,
            message: "Timeline frame pacing fell below target.",
            fields: [
                "fps": "\(stats.framesPerSecond)",
                "averageFrameMs": String(format: "%.3f", stats.averageFrameTimeMilliseconds),
                "worstFrameMs": String(format: "%.3f", stats.worstFrameTimeMilliseconds),
                "jitterMs": String(format: "%.3f", stats.frameTimeJitterMilliseconds),
                "renderer": stats.waveformRenderer,
                "gpuDraws": "\(stats.gpuWaveformDrawCount)",
                "cpuVertices": "\(stats.cpuWaveformVertexCount)",
                "shaderUploads": "\(stats.shaderBufferUploadCount)",
                "shaderUploadBytes": "\(stats.shaderBufferUploadByteCount)",
                "shaderMB": "\(stats.shaderBufferByteCount / 1_048_576)",
                "cpuFallbackDraws": "\(stats.cpuWaveformFallbackDrawCount)",
                "fallbackDraws": "\(stats.waveformFallbackDrawCount)",
                "lastGoodHolds": "\(stats.waveformLastGoodHoldCount)",
                "residentMisses": "\(stats.waveformResidentMissCount)",
                "hotPathReason": stats.waveformHotPathReason,
                "hotPathViolations": "\(stats.waveformHotPathViolationCount)",
                "gpuResidentMode": stats.gpuResidentWaveformMode,
                "gpuResidentShadowSources": "\(stats.gpuResidentShadowSourceCount)",
                "gpuResidentShadowTiles": "\(stats.gpuResidentShadowVisibleTileCount)/\(stats.gpuResidentShadowRequestCount)",
                "gpuResidentShadowBatches": "\(stats.gpuResidentShadowDrawBatchCount)",
                "gpuResidentShadowInstances": "\(stats.gpuResidentShadowDrawInstanceCount)",
                "effects": "\(stats.effectVertexCount)",
                "deletes": "\(stats.deletionEffectCount)",
                "suppressedSimilarEvents": "\(suppressedCount)",
            ]
        )
    }

    func recordAudioCoreSnapshot(_ snapshot: RealtimeAudioCoreSnapshot) {
        let underrunDelta: Int
        let droppedCommandDelta: Int
        let renderDeadlineMissDelta: Int
        let renderWorkDeadlineMissDelta: Int
        let callbackSchedulingLateDelta: Int
        lock.lock()
        latestAudioSnapshot = snapshot
        underrunDelta = max(snapshot.underrunCount - lastUnderrunCount, 0)
        droppedCommandDelta = max(snapshot.droppedCommandCount - lastDroppedCommandCount, 0)
        renderDeadlineMissDelta = max(snapshot.renderDeadlineMissCount - lastRenderDeadlineMissCount, 0)
        renderWorkDeadlineMissDelta = max(
            snapshot.renderWorkDeadlineMissCount - lastRenderWorkDeadlineMissCount,
            0
        )
        callbackSchedulingLateDelta = max(
            snapshot.callbackSchedulingLateCount - lastCallbackSchedulingLateCount,
            0
        )
        lastUnderrunCount = max(lastUnderrunCount, snapshot.underrunCount)
        lastDroppedCommandCount = max(lastDroppedCommandCount, snapshot.droppedCommandCount)
        lastRenderDeadlineMissCount = max(lastRenderDeadlineMissCount, snapshot.renderDeadlineMissCount)
        lastRenderWorkDeadlineMissCount = max(
            lastRenderWorkDeadlineMissCount,
            snapshot.renderWorkDeadlineMissCount
        )
        lastCallbackSchedulingLateCount = max(
            lastCallbackSchedulingLateCount,
            snapshot.callbackSchedulingLateCount
        )
        lock.unlock()

        if underrunDelta > 0 {
            record(
                category: .audio,
                severity: .severe,
                name: "audio-underrun",
                message: "Realtime audio core reported underruns.",
                fields: [
                    "delta": "\(underrunDelta)",
                    "total": "\(snapshot.underrunCount)",
                    "frameIndex": "\(snapshot.frameIndex)",
                    "renderedFrames": "\(snapshot.renderedFrameCount)",
                    "callbacks": "\(snapshot.callbackCount)",
                    "lastRenderMs": String(format: "%.3f", Double(snapshot.lastRenderNanoseconds) / 1_000_000),
                    "maxRenderMs": String(format: "%.3f", Double(snapshot.maxRenderNanoseconds) / 1_000_000),
                    "lastRenderWorkMs": String(format: "%.3f", Double(snapshot.lastRenderWorkNanoseconds) / 1_000_000),
                    "maxRenderWorkMs": String(format: "%.3f", Double(snapshot.maxRenderWorkNanoseconds) / 1_000_000),
                    "sampleRate": String(format: "%.1f", snapshot.sampleRate),
                    "isPlaying": "\(snapshot.isPlaying)",
                ]
            )
        }

        if droppedCommandDelta > 0 {
            record(
                category: .audio,
                severity: .warning,
                name: "audio-dropped-command",
                message: "Realtime audio core dropped control commands.",
                fields: [
                    "delta": "\(droppedCommandDelta)",
                    "total": "\(snapshot.droppedCommandCount)",
                    "renderedFrames": "\(snapshot.renderedFrameCount)",
                ]
            )
        }

        if renderDeadlineMissDelta > 0 {
            record(
                category: .audio,
                severity: .warning,
                name: "audio-callback-deadline-miss",
                message: "Realtime audio callback wall occupancy exceeded its block deadline.",
                fields: [
                    "delta": "\(renderDeadlineMissDelta)",
                    "total": "\(snapshot.renderDeadlineMissCount)",
                    "workMissDelta": "\(renderWorkDeadlineMissDelta)",
                    "workMissTotal": "\(snapshot.renderWorkDeadlineMissCount)",
                    "callbacks": "\(snapshot.callbackCount)",
                    "lastRenderMs": String(format: "%.3f", Double(snapshot.lastRenderNanoseconds) / 1_000_000),
                    "maxRenderMs": String(format: "%.3f", Double(snapshot.maxRenderNanoseconds) / 1_000_000),
                    "lastRenderWorkMs": String(format: "%.3f", Double(snapshot.lastRenderWorkNanoseconds) / 1_000_000),
                    "maxRenderWorkMs": String(format: "%.3f", Double(snapshot.maxRenderWorkNanoseconds) / 1_000_000),
                    "frameCount": "\(snapshot.frameCount)",
                    "frameIndex": "\(snapshot.frameIndex)",
                ]
            )
        }

        if renderWorkDeadlineMissDelta > 0 {
            record(
                category: .audio,
                severity: .severe,
                name: "audio-render-work-deadline-miss",
                message: "Realtime audio CPU work exceeded its render block deadline.",
                fields: [
                    "delta": "\(renderWorkDeadlineMissDelta)",
                    "total": "\(snapshot.renderWorkDeadlineMissCount)",
                    "callbacks": "\(snapshot.callbackCount)",
                    "lastRenderWorkMs": String(format: "%.3f", Double(snapshot.lastRenderWorkNanoseconds) / 1_000_000),
                    "maxRenderWorkMs": String(format: "%.3f", Double(snapshot.maxRenderWorkNanoseconds) / 1_000_000),
                    "frameCount": "\(snapshot.frameCount)",
                    "frameIndex": "\(snapshot.frameIndex)",
                ]
            )
        }

        if callbackSchedulingLateDelta > 0 {
            record(
                category: .audio,
                severity: .warning,
                name: "audio-callback-scheduling-late",
                message: "Audio callback delivery arrived later than its expected host-time interval.",
                fields: [
                    "delta": "\(callbackSchedulingLateDelta)",
                    "total": "\(snapshot.callbackSchedulingLateCount)",
                    "maxLatenessMs": String(
                        format: "%.3f",
                        Double(snapshot.maxCallbackSchedulingLatenessNanoseconds) / 1_000_000
                    ),
                    "callbacks": "\(snapshot.callbackCount)",
                    "frameCount": "\(snapshot.frameCount)",
                    "frameIndex": "\(snapshot.frameIndex)",
                ]
            )
        }
    }

    func recordMainThreadStall(milliseconds: Double) {
        lock.lock()
        mainThreadStallCount += 1
        lastMainThreadStallMilliseconds = milliseconds
        lock.unlock()

        record(
            category: .threading,
            severity: milliseconds >= 120 ? .severe : .warning,
            name: "main-thread-stall",
            message: "Main thread heartbeat was delayed.",
            fields: [
                "delayMs": String(format: "%.2f", milliseconds),
            ]
        )
    }

    func recordMixerSnapshot(_ snapshot: MixerDiagnosticsSnapshot, isPlaying: Bool) {
        let now = CACurrentMediaTime()
        lock.lock()
        let droppedDelta = snapshot.droppedPacketCount &- min(
            snapshot.droppedPacketCount,
            lastMixerDroppedPacketCount
        )
        let staleDelta = snapshot.stalePacketCount &- min(
            snapshot.stalePacketCount,
            lastMixerStalePacketCount
        )
        let hasProblem = droppedDelta > 0 || staleDelta > 0 ||
            (isPlaying && snapshot.packetAgeMilliseconds > 100) ||
            snapshot.drawDurationMilliseconds > 2
        let shouldRecord = hasProblem || now - lastMixerSnapshotEventTime >= 2
        if shouldRecord {
            lastMixerSnapshotEventTime = now
            lastMixerDroppedPacketCount = snapshot.droppedPacketCount
            lastMixerStalePacketCount = snapshot.stalePacketCount
        }
        lock.unlock()
        guard shouldRecord else { return }

        record(
            category: .render,
            severity: hasProblem ? .warning : .info,
            name: "mixer-performance-snapshot",
            message: hasProblem ?
                "Mixer metering exceeded its expected delivery or render budget." :
                "Mixer metering is operating within budget.",
            fields: [
                "packetAgeMs": String(format: "%.3f", snapshot.packetAgeMilliseconds),
                "droppedPackets": "\(snapshot.droppedPacketCount)",
                "droppedPacketDelta": "\(droppedDelta)",
                "stalePackets": "\(snapshot.stalePacketCount)",
                "stalePacketDelta": "\(staleDelta)",
                "realtimeMeterWorkUs": String(format: "%.3f", Double(snapshot.realtimeWorkNanoseconds) / 1_000),
                "visibleStrips": "\(snapshot.visibleChannelCount)",
                "renderedMeters": "\(snapshot.renderedMeterCount)",
                "gpuDraws": "\(snapshot.gpuDrawCount)",
                "drawMs": String(format: "%.3f", snapshot.drawDurationMilliseconds),
                "maximumDrawMs": String(format: "%.3f", snapshot.maximumDrawDurationMilliseconds),
                "isPlaying": "\(isPlaying)",
            ]
        )
    }

    func snapshot(limit: Int = 128) -> SoundtimeDiagnosticsSnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }
        return SoundtimeDiagnosticsSnapshot(
            frameStats: latestFrameStats,
            audioSnapshot: latestAudioSnapshot,
            events: Array(events.suffix(max(limit, 0))),
            mainThreadStallCount: mainThreadStallCount,
            lastMainThreadStallMilliseconds: lastMainThreadStallMilliseconds,
            severeEventCount: severeEventCount,
            warningEventCount: warningEventCount
        )
    }

    func recentEvents(limit: Int = 256) -> [SoundtimeDiagnosticEvent] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return Array(events.suffix(max(limit, 0)))
    }

    @discardableResult
    func writeTrace(reason: String) -> URL? {
        guard let store = sessionStore, !recentEvents(limit: 1).isEmpty else { return nil }
        let directory = logsDirectoryURL.appendingPathComponent("Automatic Bundles", isDirectory: true)
        let safeReason = reason.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let url = directory.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(safeReason).zip")
        traceWriteQueue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store.flush()
            _ = try? DiagnosticBundleExporter.export(sessionURL: store.eventsURL, outputURL: url)
        }
        return url
    }

    @discardableResult
    func writeTraceSynchronouslyForSmokeTesting(reason: String) -> URL? {
        let snapshot = recentEvents(limit: maximumEventCount)
        guard !snapshot.isEmpty else {
            return nil
        }

        let url = traceURL(reason: reason)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            Swift.print("Soundtime could not write diagnostics smoke trace: \(error)")
            return nil
        }
    }

    func resetForSmokeTesting() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        activeOperationCorrelations.removeAll(keepingCapacity: true)
        latestIncident = nil
        latestFrameStats = nil
        latestAudioSnapshot = nil
        lastUnderrunCount = 0
        lastDroppedCommandCount = 0
        lastRenderDeadlineMissCount = 0
        lastRenderWorkDeadlineMissCount = 0
        lastCallbackSchedulingLateCount = 0
        pendingAutomaticTraceWorkItem?.cancel()
        pendingAutomaticTraceWorkItem = nil
        lastTraceWriteByName.removeAll(keepingCapacity: true)
        lastFrameDropEventTime = -Double.infinity
        lastMixerSnapshotEventTime = -Double.infinity
        lastMixerDroppedPacketCount = 0
        lastMixerStalePacketCount = 0
        lastFrameDropEventSeverity = nil
        suppressedFrameDropEventCount = 0
        mainThreadStallCount = 0
        lastMainThreadStallMilliseconds = 0
        severeEventCount = 0
        warningEventCount = 0
        lock.unlock()
    }

    private func appendLocked(_ event: SoundtimeDiagnosticEvent) {
        events.append(event)
        switch event.severity {
        case .info:
            break
        case .warning:
            warningEventCount += 1
        case .severe:
            severeEventCount += 1
        }
        if events.count > maximumEventCount {
            events.removeFirst(events.count - maximumEventCount)
        }
    }

    private func publish(_ event: SoundtimeDiagnosticEvent) {
        if event.severity != .info {
            logger.log(level: event.severity == .severe ? .fault : .error, "\(event.name, privacy: .public): \(event.message, privacy: .public)")
            signposter.emitEvent("DiagnosticEvent", id: signposter.makeSignpostID(), "name=\(event.name, privacy: .public)")
        } else if event.category == .launch || event.name.hasSuffix("-started") || event.name.hasSuffix("-finished") {
            logger.info("\(event.name, privacy: .public): \(event.message, privacy: .public)")
            signposter.emitEvent("LifecycleEvent", id: signposter.makeSignpostID(), "name=\(event.name, privacy: .public)")
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.didRecordEventNotification,
                object: self,
                userInfo: [Self.recordedEventUserInfoKey: event]
            )
        }
    }

    private func writeTraceIfNeeded(for event: SoundtimeDiagnosticEvent) {
        let now = event.timestamp
        let shouldWrite: Bool
        lock.lock()
        let lastWrite = lastTraceWriteByName[event.name] ?? -Double.infinity
        shouldWrite = now - lastWrite >= severeTraceWriteThrottle
        if shouldWrite {
            lastTraceWriteByName[event.name] = now
        }
        lock.unlock()

        guard shouldWrite else { return }
        scheduleAutomaticTrace(reason: event.name)
    }

    private func scheduleAutomaticTrace(reason: String) {
        guard sessionStore != nil,
              ProcessInfo.processInfo.environment["SOUNDTIME_DISABLE_AUTOMATIC_DIAGNOSTIC_BUNDLES"] != "1"
        else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pendingAutomaticTraceWorkItem = nil
            self.lock.unlock()
            _ = self.writeTrace(reason: reason)
        }

        lock.lock()
        pendingAutomaticTraceWorkItem?.cancel()
        pendingAutomaticTraceWorkItem = workItem
        lock.unlock()
        traceWriteQueue.asyncAfter(
            deadline: .now() + automaticTraceQuietInterval,
            execute: workItem
        )
    }

    private func traceURL(reason: String) -> URL {
        let sanitizedReason = reason
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let fileName = "soundtime-diagnostics-\(Int(CACurrentMediaTime()))-\(sanitizedReason.isEmpty ? "trace" : sanitizedReason).json"
        return FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    }

    var logsDirectoryURL: URL { DiagnosticSessionStore.defaultRootURL }
    var currentSessionEventsURL: URL? { sessionStore?.eventsURL }
    var hasIncompletePreviousSession: Bool { !DiagnosticSessionStore.incompleteSessions().isEmpty }
    var unacknowledgedIncompleteSessionIDs: [UUID] {
        DiagnosticSessionStore.unacknowledgedIncompleteSessionFiles().map(\.metadata.sessionID)
    }

    @discardableResult
    func markIncident(note: String? = nil) -> DiagnosticIncident? {
        guard let store = sessionStore else { return nil }
        let incident = DiagnosticIncident(sessionID: sessionID, note: note)
        lock.lock()
        latestIncident = incident
        lock.unlock()
        store.pin()
        let encoder = DiagnosticJSON.makeEncoder(prettyPrinted: true)
        let url = logsDirectoryURL.appendingPathComponent("incident-\(incident.id.uuidString.lowercased()).json")
        if let data = try? encoder.encode(incident) { try? data.write(to: url, options: .atomic) }
        record(category: .system, severity: .warning, name: "incident-marked", message: "Developer marked an incident.", fields: ["incidentID": incident.id.uuidString])
        return incident
    }

    @discardableResult
    func exportDiagnosticBundle(incident: DiagnosticIncident? = nil, includeIdentifiable: Bool = false) -> URL? {
        guard let store = sessionStore else { return nil }
        lock.lock()
        let selectedIncident = incident ?? latestIncident
        lock.unlock()
        store.flush()
        let output = diagnosticBundleOutputURL()
        return try? DiagnosticBundleExporter.export(sessionURL: store.eventsURL, incident: selectedIncident,
            outputURL: output, includeIdentifiable: includeIdentifiable,
            supplemental: diagnosticSupplementalContext())
    }

    @discardableResult
    func exportLatestIncompleteSessionBundle(includeIdentifiable: Bool = false) -> URL? {
        guard let previous = DiagnosticSessionStore.incompleteSessionFiles().first else { return nil }
        return exportIncompleteSessionBundle(previous, includeIdentifiable: includeIdentifiable)
    }

    @discardableResult
    func exportIncompleteSessionBundle(
        sessionID: UUID,
        includeIdentifiable: Bool = false
    ) -> URL? {
        guard let previous = DiagnosticSessionStore.incompleteSessionFiles().first(where: {
            $0.metadata.sessionID == sessionID
        }) else {
            return nil
        }
        return exportIncompleteSessionBundle(previous, includeIdentifiable: includeIdentifiable)
    }

    private func exportIncompleteSessionBundle(
        _ previous: DiagnosticSessionFiles,
        includeIdentifiable: Bool
    ) -> URL? {
        return try? DiagnosticBundleExporter.export(
            sessionURL: previous.eventsURL,
            outputURL: diagnosticBundleOutputURL(prefix: "Soundtime-Recovered-Diagnostics"),
            includeIdentifiable: includeIdentifiable,
            supplemental: [
                "build": ["currentVersion": buildVersion, "sessionVersion": previous.metadata.buildVersion],
                "system": ["os": ProcessInfo.processInfo.operatingSystemVersionString],
                "config": ["recoveredSession": true],
            ]
        )
    }

    @discardableResult
    func acknowledgeRecoveryPrompt(for sessionID: UUID) -> Bool {
        DiagnosticSessionStore.acknowledgeRecoveryPrompt(sessionID: sessionID)
    }

    func finishSession() {
        lock.lock()
        let shouldFinish = !didFinishSession
        didFinishSession = true
        lock.unlock()
        if shouldFinish {
            sessionStore?.finish()
        }
    }

    @discardableResult
    func beginOperation(kind: String, category: SoundtimeDiagnosticCategory,
                        projectRevision: Int64? = nil, graphRevision: Int64? = nil,
                        fields: [String: String] = [:]) -> Operation {
        let operation = Operation(id: UUID(), kind: kind, startedAt: CACurrentMediaTime(),
            projectRevision: projectRevision, graphRevision: graphRevision)
        record(category: category, severity: .info, name: "\(kind)-started",
            message: "\(kind.capitalized) operation started.", fields: fields, correlation: operation.correlation)
        return operation
    }

    func endOperation(_ operation: Operation, category: SoundtimeDiagnosticCategory,
                      severity: SoundtimeDiagnosticSeverity = .info, fields: [String: String] = [:]) {
        var values = fields
        values["durationMs"] = String(format: "%.2f", (CACurrentMediaTime() - operation.startedAt) * 1_000)
        record(category: category, severity: severity, name: "\(operation.kind)-finished",
            message: "\(operation.kind.capitalized) operation finished.", fields: values, correlation: operation.correlation)
    }

    private func resolveCorrelationLocked(
        name: String,
        fields: [String: String],
        provided: DiagnosticCorrelation?
    ) -> DiagnosticCorrelation? {
        var inferred = provided ?? Self.inferredCorrelation(name: name, fields: fields)
        guard let kind = inferred?.operationKind else { return inferred }
        let lowered = name.lowercased()
        let startsOperation = lowered.contains("start") || lowered.contains("begin") ||
            lowered.contains("request") || lowered.contains("queued")
        let endsOperation = lowered.contains("finish") || lowered.contains("complete") ||
            lowered.contains("failed") || lowered.contains("cancel") || lowered.contains("stopped")

        if startsOperation || activeOperationCorrelations[kind] == nil {
            if inferred?.operationID == nil { inferred?.operationID = UUID() }
        } else if let active = activeOperationCorrelations[kind], var value = inferred {
            value.operationID = value.operationID ?? active.operationID
            value.projectRevision = value.projectRevision ?? active.projectRevision
            value.graphRevision = value.graphRevision ?? active.graphRevision
            inferred = value
        }

        if endsOperation {
            activeOperationCorrelations.removeValue(forKey: kind)
        } else if let inferred {
            activeOperationCorrelations[kind] = inferred
        }
        return inferred
    }

    private func diagnosticBundleOutputURL(prefix: String = "Soundtime-Diagnostics") -> URL {
        let directory = logsDirectoryURL.deletingLastPathComponent()
            .appendingPathComponent("Bundles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent(
            "\(prefix)-\(timestamp)-\(UUID().uuidString.lowercased()).soundtimediagnostics.zip"
        )
    }

    private func diagnosticSupplementalContext() -> [String: Any] {
        let value = snapshot()
        var performance: [String: Any] = [
            "mainThreadStallCount": value.mainThreadStallCount,
            "lastMainThreadStallMilliseconds": value.lastMainThreadStallMilliseconds,
        ]
        if let frame = value.frameStats {
            performance.merge([
                "fps": frame.framesPerSecond,
                "displayRefreshFPS": frame.displayRefreshFramesPerSecond,
                "averageFrameMilliseconds": frame.averageFrameTimeMilliseconds,
                "worstFrameMilliseconds": frame.worstFrameTimeMilliseconds,
                "frameJitterMilliseconds": frame.frameTimeJitterMilliseconds,
                "waveformRenderer": frame.waveformRenderer,
                "waveformResidentMisses": frame.waveformResidentMissCount,
            ]) { _, new in new }
        }
        var audio: [String: Any] = [:]
        if let snapshot = value.audioSnapshot {
            audio = [
                "frameIndex": snapshot.frameIndex,
                "frameCount": snapshot.frameCount,
                "sampleRate": snapshot.sampleRate,
                "isPlaying": snapshot.isPlaying,
                "underrunCount": snapshot.underrunCount,
                "droppedCommandCount": snapshot.droppedCommandCount,
                "renderDeadlineMissCount": snapshot.renderDeadlineMissCount,
                "renderWorkDeadlineMissCount": snapshot.renderWorkDeadlineMissCount,
                "callbackSchedulingLateCount": snapshot.callbackSchedulingLateCount,
            ]
        }
        return [
            "performance": performance,
            "audio": audio,
            "build": ["version": buildVersion],
            "system": [
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "processorCount": ProcessInfo.processInfo.processorCount,
                "physicalMemory": ProcessInfo.processInfo.physicalMemory,
            ],
            "config": ["eventSchemaVersion": DiagnosticEvent.currentSchemaVersion],
        ]
    }

    private static func inferredCorrelation(name: String, fields: [String: String]) -> DiagnosticCorrelation? {
        let lowered = name.lowercased()
        let kinds = ["launch", "import", "playback", "delete", "paste", "undo", "export", "transcription", "hydration"]
        guard let kind = kinds.first(where: lowered.contains) else { return nil }
        let operationText = ["operationID", "jobID", "importID", "exportID", "requestID", "generation"]
            .compactMap { fields[$0] }.first
        let operationID = operationText.map { UUID(uuidString: $0) ?? stableOperationUUID(kind: kind, value: $0) }
        let graphRevision = ["graphRevision", "revision"].compactMap { fields[$0].flatMap(Int64.init) }.first
        let projectRevision = fields["projectRevision"].flatMap(Int64.init)
        return DiagnosticCorrelation(operationID: operationID, operationKind: kind,
            projectRevision: projectRevision, graphRevision: graphRevision)
    }

    private static func stableOperationUUID(kind: String, value: String) -> UUID {
        func hash(seed: UInt64) -> UInt64 {
            (kind + ":" + value).utf8.reduce(seed) { current, byte in
                (current ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        var bytes = withUnsafeBytes(of: hash(seed: 14_695_981_039_346_656_037).bigEndian, Array.init)
        bytes.append(contentsOf: withUnsafeBytes(of: hash(seed: 10_995_116_282_11).bigEndian, Array.init))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
