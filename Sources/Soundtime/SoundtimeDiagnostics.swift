import Foundation
import QuartzCore

enum SoundtimeDiagnosticSeverity: String, Codable, Sendable {
    case info
    case warning
    case severe
}

enum SoundtimeDiagnosticCategory: String, Codable, Sendable {
    case audio
    case render
    case edit
    case device
    case interaction
    case system
}

struct SoundtimeDiagnosticEvent: Codable, Sendable {
    let timestamp: TimeInterval
    let category: SoundtimeDiagnosticCategory
    let severity: SoundtimeDiagnosticSeverity
    let name: String
    let message: String
    let fields: [String: String]
}

final class SoundtimeDiagnostics: @unchecked Sendable {
    static let shared = SoundtimeDiagnostics()

    private let lock = NSLock()
    private let maximumEventCount = 2_048
    private let traceWriteQueue = DispatchQueue(label: "Soundtime.diagnostics.trace", qos: .utility)
    private let severeTraceWriteThrottle: TimeInterval = 3
    private var events: [SoundtimeDiagnosticEvent] = []
    private var lastUnderrunCount = 0
    private var lastDroppedCommandCount = 0
    private var lastTraceWriteByName: [String: TimeInterval] = [:]

    private init() {}

    func record(
        category: SoundtimeDiagnosticCategory,
        severity: SoundtimeDiagnosticSeverity,
        name: String,
        message: String,
        fields: [String: String] = [:]
    ) {
        let event = SoundtimeDiagnosticEvent(
            timestamp: CACurrentMediaTime(),
            category: category,
            severity: severity,
            name: name,
            message: message,
            fields: fields
        )
        append(event)
        if severity == .severe {
            writeTraceIfNeeded(for: event)
        }
    }

    func recordFrameStats(_ stats: TimelineFrameStats) {
        let severity: SoundtimeDiagnosticSeverity
        if stats.framesPerSecond <= 60 || stats.worstFrameTimeMilliseconds >= 32 {
            severity = .severe
        } else if stats.framesPerSecond < 100 || stats.worstFrameTimeMilliseconds >= 16 {
            severity = .warning
        } else {
            return
        }

        record(
            category: .render,
            severity: severity,
            name: "timeline-frame-drop",
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
                "shaderMB": "\(stats.shaderBufferByteCount / 1_048_576)",
                "effects": "\(stats.effectVertexCount)",
                "deletes": "\(stats.deletionEffectCount)",
            ]
        )
    }

    func recordAudioCoreSnapshot(_ snapshot: RealtimeAudioCoreSnapshot) {
        let underrunDelta: Int
        let droppedCommandDelta: Int
        lock.lock()
        underrunDelta = max(snapshot.underrunCount - lastUnderrunCount, 0)
        droppedCommandDelta = max(snapshot.droppedCommandCount - lastDroppedCommandCount, 0)
        lastUnderrunCount = max(lastUnderrunCount, snapshot.underrunCount)
        lastDroppedCommandCount = max(lastDroppedCommandCount, snapshot.droppedCommandCount)
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
        let snapshot = recentEvents(limit: maximumEventCount)
        guard !snapshot.isEmpty else {
            return nil
        }

        let sanitizedReason = reason
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let fileName = "soundtime-diagnostics-\(Int(CACurrentMediaTime()))-\(sanitizedReason.isEmpty ? "trace" : sanitizedReason).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        traceWriteQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: [.atomic])
            } catch {
                Swift.print("Soundtime could not write diagnostics trace: \(error)")
            }
        }
        return url
    }

    private func append(_ event: SoundtimeDiagnosticEvent) {
        lock.lock()
        events.append(event)
        if events.count > maximumEventCount {
            events.removeFirst(events.count - maximumEventCount)
        }
        lock.unlock()
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

        if shouldWrite {
            _ = writeTrace(reason: event.name)
        }
    }
}
