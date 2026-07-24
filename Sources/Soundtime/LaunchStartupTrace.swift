import Foundation
import QuartzCore

enum LaunchStartupMilestone: String, Sendable {
    case processEntry = "process-entry"
    case appDelegateDidFinishLaunching = "app-delegate-did-finish-launching"
    case mainWindowControllerInitStart = "main-window-controller-init-start"
    case mainWindowCreated = "main-window-created"
    case deferredWindowLayoutApplied = "deferred-window-layout-applied"
    case deferredProjectRestorePrepared = "deferred-project-restore-prepared"
    case windowShowRequested = "window-show-requested"
    case windowVisible = "window-visible"
    case launchPreviewLoadStarted = "launch-preview-load-started"
    case launchSnapshotLoaded = "launch-snapshot-loaded"
    case launchProjectPreviewLoaded = "launch-project-preview-loaded"
    case launchPreviewUnavailable = "launch-preview-unavailable"
    case visualSkeletonApplied = "visual-skeleton-applied"
    case visualPreviewReady = "visual-preview-ready"
    case firstTimelineRenderSubmitted = "first-timeline-render-submitted"
    case firstWaveformVisibleFrame = "first-waveform-visible-frame"
    case playbackPrimeStarted = "playback-prime-started"
    case playbackPrimeReady = "playback-prime-ready"
    case playbackPrimeReadyWithFailures = "playback-prime-ready-with-failures"
    case playbackHydrationStarted = "playback-hydration-started"
    case playbackTrackReady = "playback-track-ready"
    case playbackReady = "playback-ready"
    case playbackReadyWithFailures = "playback-ready-with-failures"
    case launchFailed = "launch-failed"
}

struct LaunchStartupTraceEvent: Sendable {
    var milestone: LaunchStartupMilestone
    var timestamp: CFTimeInterval
    var elapsedMilliseconds: Double
    var deltaMilliseconds: Double
    var fields: [String: String]
}

final class LaunchStartupTrace: @unchecked Sendable {
    static let shared = LaunchStartupTrace()

    private let lock = NSLock()
    private var startTimestamp: CFTimeInterval
    private var lastTimestamp: CFTimeInterval
    private var events: [LaunchStartupTraceEvent] = []

    private init(startTimestamp: CFTimeInterval = CACurrentMediaTime()) {
        self.startTimestamp = startTimestamp
        self.lastTimestamp = startTimestamp
    }

    @discardableResult
    func mark(
        _ milestone: LaunchStartupMilestone,
        fields: [String: String] = [:],
        recordsDiagnosticEvent: Bool = true
    ) -> LaunchStartupTraceEvent {
        let timestamp = CACurrentMediaTime()
        let event: LaunchStartupTraceEvent
        lock.lock()
        let elapsedMilliseconds = (timestamp - startTimestamp) * 1_000
        let deltaMilliseconds = (timestamp - lastTimestamp) * 1_000
        lastTimestamp = timestamp
        event = LaunchStartupTraceEvent(
            milestone: milestone,
            timestamp: timestamp,
            elapsedMilliseconds: elapsedMilliseconds,
            deltaMilliseconds: deltaMilliseconds,
            fields: fields
        )
        events.append(event)
        if events.count > 128 {
            events.removeFirst(events.count - 128)
        }
        lock.unlock()

        if recordsDiagnosticEvent {
            recordDiagnosticEvent(event)
        }
        return event
    }

    @discardableResult
    func markOnce(
        _ milestone: LaunchStartupMilestone,
        fields: [String: String] = [:],
        recordsDiagnosticEvent: Bool = true
    ) -> LaunchStartupTraceEvent? {
        let timestamp = CACurrentMediaTime()
        let event: LaunchStartupTraceEvent
        lock.lock()
        guard !events.contains(where: { $0.milestone == milestone }) else {
            lock.unlock()
            return nil
        }

        let elapsedMilliseconds = (timestamp - startTimestamp) * 1_000
        let deltaMilliseconds = (timestamp - lastTimestamp) * 1_000
        lastTimestamp = timestamp
        event = LaunchStartupTraceEvent(
            milestone: milestone,
            timestamp: timestamp,
            elapsedMilliseconds: elapsedMilliseconds,
            deltaMilliseconds: deltaMilliseconds,
            fields: fields
        )
        events.append(event)
        if events.count > 128 {
            events.removeFirst(events.count - 128)
        }
        lock.unlock()

        if recordsDiagnosticEvent {
            recordDiagnosticEvent(event)
        }
        return event
    }

    func snapshot() -> [LaunchStartupTraceEvent] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return events
    }

    func contains(_ milestone: LaunchStartupMilestone) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return events.contains { $0.milestone == milestone }
    }

    func elapsedMilliseconds(to milestone: LaunchStartupMilestone) -> Double? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return events.first { $0.milestone == milestone }?.elapsedMilliseconds
    }

    func resetForSmokeTesting() {
        let timestamp = CACurrentMediaTime()
        lock.lock()
        events.removeAll(keepingCapacity: true)
        startTimestamp = timestamp
        lastTimestamp = timestamp
        lock.unlock()
    }

    private func recordDiagnosticEvent(_ event: LaunchStartupTraceEvent) {
        var fields = event.fields
        fields["milestone"] = event.milestone.rawValue
        fields["elapsedMs"] = String(format: "%.2f", event.elapsedMilliseconds)
        fields["deltaMs"] = String(format: "%.2f", event.deltaMilliseconds)
        let severity = severity(for: event)

        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: severity,
            name: "launch-milestone",
            message: "Launch startup milestone reached.",
            fields: fields
        )

        guard severity != .info, let budget = budget(for: event.milestone) else {
            return
        }

        var stallFields = fields
        stallFields["budgetMs"] = String(format: "%.0f", budget.milliseconds)
        stallFields["budgetKind"] = budget.kind
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: severity,
            name: "launch-stall",
            message: "Launch startup milestone exceeded its budget.",
            fields: stallFields
        )
    }

    private func severity(for event: LaunchStartupTraceEvent) -> SoundtimeDiagnosticSeverity {
        switch event.milestone {
        case .windowVisible:
            return event.elapsedMilliseconds > 1_000 ? .severe :
                (event.elapsedMilliseconds > 350 ? .warning : .info)
        case .visualPreviewReady, .firstWaveformVisibleFrame:
            return event.elapsedMilliseconds > 1_500 ? .severe :
                (event.elapsedMilliseconds > 500 ? .warning : .info)
        case .playbackPrimeReady, .playbackPrimeReadyWithFailures:
            return event.elapsedMilliseconds > 3_000 ? .severe :
                (event.elapsedMilliseconds > 1_000 ? .warning : .info)
        case .playbackReady, .playbackReadyWithFailures:
            return event.elapsedMilliseconds > 6_000 ? .severe :
                (event.elapsedMilliseconds > 2_500 ? .warning : .info)
        case .launchSnapshotLoaded:
            return event.deltaMilliseconds > 75 ? .warning : .info
        case .launchProjectPreviewLoaded:
            return event.deltaMilliseconds > 120 ? .warning : .info
        case .launchFailed:
            return .warning
        default:
            return .info
        }
    }

    private func budget(for milestone: LaunchStartupMilestone) -> (milliseconds: Double, kind: String)? {
        switch milestone {
        case .windowVisible:
            return (350, "elapsed")
        case .visualPreviewReady, .firstWaveformVisibleFrame:
            return (500, "elapsed")
        case .playbackPrimeReady, .playbackPrimeReadyWithFailures:
            return (1_000, "elapsed")
        case .playbackReady, .playbackReadyWithFailures:
            return (2_500, "elapsed")
        case .launchSnapshotLoaded:
            return (75, "delta")
        case .launchProjectPreviewLoaded:
            return (120, "delta")
        default:
            return nil
        }
    }
}
