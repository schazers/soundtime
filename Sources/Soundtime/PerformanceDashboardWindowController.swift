import AppKit
import Darwin
import Metal
import QuartzCore

struct PerformanceDashboardDiagnosticsSnapshot: Codable, Sendable {
    var frameStatsDisplayCount: Int
    var performanceSnapshotDisplayCount: Int
    var refreshRequestCount: Int
    var maxFrameStatsDisplayMilliseconds: Double
    var maxPerformanceSnapshotDisplayMilliseconds: Double
    var maxRefreshRequestMilliseconds: Double
}

final class PerformanceDashboardWindowController: NSWindowController, NSWindowDelegate {
    private enum LifecycleSmokeError: Error, CustomStringConvertible {
        case windowDidNotClose
        case eventLogDidNotRender
        case eventLogDidNotFollowBottom

        var description: String {
            switch self {
            case .windowDidNotClose:
                return "performance dashboard window remained visible after close"
            case .eventLogDidNotRender:
                return "performance dashboard did not render a diagnostic event in Recent Events"
            case .eventLogDidNotFollowBottom:
                return "performance dashboard event log did not stay pinned to the newest events"
            }
        }
    }

    private static var sharedController: PerformanceDashboardWindowController?
    private static let diagnosticsLock = NSLock()
    private static var diagnosticsFrameStatsDisplayCount = 0
    private static var diagnosticsPerformanceSnapshotDisplayCount = 0
    private static var diagnosticsRefreshRequestCount = 0
    private static var diagnosticsMaxFrameStatsDisplayMilliseconds: Double = 0
    private static var diagnosticsMaxPerformanceSnapshotDisplayMilliseconds: Double = 0
    private static var diagnosticsMaxRefreshRequestMilliseconds: Double = 0

    static var shared: PerformanceDashboardWindowController {
        if let sharedController {
            return sharedController
        }

        let controller = PerformanceDashboardWindowController()
        sharedController = controller
        return controller
    }

    static func displayIfVisible(frameStats: TimelineFrameStats) {
        guard let controller = sharedController, controller.window?.isVisible == true else {
            return
        }

        let startedAt = CACurrentMediaTime()
        controller.display(frameStats: frameStats)
        recordDiagnosticsWork(kind: .frameStats, elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000)
    }

    static func displayIfVisible(performanceSnapshot snapshot: PerformanceMetricsSnapshot) {
        guard let controller = sharedController, controller.window?.isVisible == true else {
            return
        }

        let startedAt = CACurrentMediaTime()
        controller.display(performanceSnapshot: snapshot)
        recordDiagnosticsWork(kind: .performanceSnapshot, elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000)
    }

    static func refreshIfVisible() {
        guard let controller = sharedController, controller.window?.isVisible == true else {
            return
        }

        let startedAt = CACurrentMediaTime()
        controller.refresh()
        recordDiagnosticsWork(kind: .refresh, elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000)
    }

    static func closeIfLoaded() {
        sharedController?.closeIfVisible()
    }

    static func diagnosticsSnapshotForSmokeTesting() -> PerformanceDashboardDiagnosticsSnapshot {
        diagnosticsLock.lock()
        defer {
            diagnosticsLock.unlock()
        }
        return PerformanceDashboardDiagnosticsSnapshot(
            frameStatsDisplayCount: diagnosticsFrameStatsDisplayCount,
            performanceSnapshotDisplayCount: diagnosticsPerformanceSnapshotDisplayCount,
            refreshRequestCount: diagnosticsRefreshRequestCount,
            maxFrameStatsDisplayMilliseconds: diagnosticsMaxFrameStatsDisplayMilliseconds,
            maxPerformanceSnapshotDisplayMilliseconds: diagnosticsMaxPerformanceSnapshotDisplayMilliseconds,
            maxRefreshRequestMilliseconds: diagnosticsMaxRefreshRequestMilliseconds
        )
    }

    static func resetDiagnosticsForSmokeTesting() {
        diagnosticsLock.lock()
        diagnosticsFrameStatsDisplayCount = 0
        diagnosticsPerformanceSnapshotDisplayCount = 0
        diagnosticsRefreshRequestCount = 0
        diagnosticsMaxFrameStatsDisplayMilliseconds = 0
        diagnosticsMaxPerformanceSnapshotDisplayMilliseconds = 0
        diagnosticsMaxRefreshRequestMilliseconds = 0
        diagnosticsLock.unlock()
    }

    private enum DiagnosticsWorkKind {
        case frameStats
        case performanceSnapshot
        case refresh
    }

    private static func recordDiagnosticsWork(kind: DiagnosticsWorkKind, elapsedMilliseconds: Double) {
        diagnosticsLock.lock()
        switch kind {
        case .frameStats:
            diagnosticsFrameStatsDisplayCount += 1
            diagnosticsMaxFrameStatsDisplayMilliseconds = max(
                diagnosticsMaxFrameStatsDisplayMilliseconds,
                elapsedMilliseconds
            )
        case .performanceSnapshot:
            diagnosticsPerformanceSnapshotDisplayCount += 1
            diagnosticsMaxPerformanceSnapshotDisplayMilliseconds = max(
                diagnosticsMaxPerformanceSnapshotDisplayMilliseconds,
                elapsedMilliseconds
            )
        case .refresh:
            diagnosticsRefreshRequestCount += 1
            diagnosticsMaxRefreshRequestMilliseconds = max(
                diagnosticsMaxRefreshRequestMilliseconds,
                elapsedMilliseconds
            )
        }
        diagnosticsLock.unlock()
    }

    @MainActor
    static func runLifecycleSmoke() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let controller = PerformanceDashboardWindowController.shared
        controller.showDashboard(relativeTo: nil)
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: .info,
            name: "performance-dashboard-event-smoke",
            message: "Performance dashboard event log smoke event."
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))

        if !controller.dashboardView.displayedEventLogText.contains("performance-dashboard-event-smoke") {
            throw LifecycleSmokeError.eventLogDidNotRender
        }
        for index in 0..<80 {
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .info,
                name: "performance-dashboard-scroll-smoke-\(index)",
                message: "Performance dashboard event log scroll smoke event \(index)."
            )
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
        if controller.dashboardView.eventLogBottomDistanceForSmoke > 8 {
            throw LifecycleSmokeError.eventLogDidNotFollowBottom
        }

        for index in 0..<12 {
            controller.display(frameStats: TimelineFrameStats(
                framesPerSecond: index.isMultiple(of: 4) ? 72 : 144,
                displayRefreshFramesPerSecond: 144,
                averageFrameTimeMilliseconds: index.isMultiple(of: 4) ? 13.8 : 6.9,
                frameTimeJitterMilliseconds: 0.4,
                worstFrameTimeMilliseconds: index.isMultiple(of: 4) ? 18.0 : 8.2,
                waveformRenderer: "smoke",
                cpuWaveformVertexCount: 0,
                gpuWaveformDrawCount: 4,
                shaderBufferUploadCount: 0,
                shaderBufferUploadByteCount: 0,
                shaderBufferCount: 2,
                shaderBufferByteCount: 2_048,
                shaderBufferUploadInFlightCount: 0,
                waveformMipCacheCount: 2,
                cpuWaveformFallbackDrawCount: 0,
                waveformFallbackDrawCount: 0,
                waveformLastGoodHoldCount: 0,
                waveformResidentMissCount: 0,
                waveformHotPathViolationCount: 0,
                waveformHotPathReason: "",
                gpuResidentWaveformMode: "smoke",
                gpuResidentShadowSourceCount: 0,
                gpuResidentShadowRequestCount: 0,
                gpuResidentShadowVisibleTileCount: 0,
                gpuResidentShadowDrawBatchCount: 0,
                gpuResidentShadowDrawInstanceCount: 0,
                effectVertexCount: 0,
                effectDroppedVertexCount: 0,
                transientParticleCount: 0,
                deletionEffectCount: 0,
                playheadContactEventCount: 0
            ))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.035))
        }

        controller.closeIfVisible()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        if controller.window?.isVisible == true {
            throw LifecycleSmokeError.windowDidNotClose
        }

        print("Soundtime performance dashboard lifecycle smoke passed")
    }

    private let dashboardView = PerformanceDashboardView()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Soundtime Development Console"
        window.isOpaque = true
        window.backgroundColor = NSColor(calibratedWhite: 0.045, alpha: 1)
        window.minSize = NSSize(width: 620, height: 720)
        window.isReleasedWhenClosed = false
        window.contentView = dashboardView
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showDashboard(relativeTo parentWindow: NSWindow?) {
        if let parentWindow, let window, !window.isVisible {
            let parentFrame = parentWindow.frame
            let targetSize = window.frame.size
            let origin = NSPoint(
                x: parentFrame.midX - targetSize.width * 0.5,
                y: parentFrame.midY - targetSize.height * 0.5
            )
            window.setFrameOrigin(origin)
        }

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: .info,
            name: "development-console-opened",
            message: "Development Console opened and diagnostics event display is active."
        )
    }

    func display(frameStats: TimelineFrameStats) {
        dashboardView.display(frameStats: frameStats)
    }

    func display(performanceSnapshot snapshot: PerformanceMetricsSnapshot) {
        dashboardView.display(performanceSnapshot: snapshot)
    }

    func refresh() {
        dashboardView.requestRefresh()
    }

    func closeIfVisible() {
        guard let window, window.isVisible else {
            return
        }

        window.close()
    }

    static func smokeRenderFPSGraphPixelSummary(
        values: [Float],
        width: Int = 192,
        height: Int = 64
    ) throws -> MetalPixelSmokeSummary {
        try PerformanceSparklineView.smokeRenderPixelSummary(
            values: values,
            maximumValue: 144,
            usesLowValueDangerColor: true,
            width: width,
            height: height
        )
    }

    static func smokeRenderCPUGraphPixelSummary(
        values: [Float],
        width: Int = 192,
        height: Int = 64
    ) throws -> MetalPixelSmokeSummary {
        try PerformanceSparklineView.smokeRenderPixelSummary(
            values: values,
            maximumValue: 400,
            usesLowValueDangerColor: false,
            width: width,
            height: height
        )
    }

    func windowWillClose(_ notification: Notification) {
        dashboardView.pause()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        dashboardView.resume()
    }
}

private final class PerformanceDashboardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Development Console")
    private let subtitleLabel = NSTextField(labelWithString: "Audio, render, GPU, queues, and trace health")
    private let fpsCard = PerformanceMetricCardView(
        title: "FPS",
        accent: NSColor(calibratedRed: 0.10, green: 0.86, blue: 0.96, alpha: 1),
        usesLowValueDangerColor: true
    )
    private let cpuCard = PerformanceMetricCardView(
        title: "CPU",
        accent: NSColor(calibratedRed: 0.95, green: 0.98, blue: 1.00, alpha: 1),
        usesHighValueDangerColor: true
    )
    private let audioCard = PerformanceInfoCardView(title: "Audio Realtime")
    private let renderCard = PerformanceInfoCardView(title: "Render / GPU")
    private let threadCard = PerformanceInfoCardView(title: "Threading")
    private let traceCard = PerformanceInfoCardView(title: "Trace Capture")
    private let eventsView = PerformanceEventLogView()
    private let exportButton = PerformanceActionButton(title: "Export Trace")
    private let dashboardRefreshInterval: TimeInterval = 0.75
    private let dashboardRefreshCoalesceInterval: TimeInterval = 0.25
    private var timer: Timer?
    private var latestFrameStats: TimelineFrameStats?
    private var latestPerformanceSnapshot: PerformanceMetricsSnapshot?
    private var lastRenderedFrameStats: TimelineFrameStats?
    private var lastDashboardUpdateTime = CACurrentMediaTime()
    private var isDashboardRefreshPending = false
    private var diagnosticsEventObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            pause()
        } else {
            resume()
        }
    }

    func display(frameStats: TimelineFrameStats) {
        latestFrameStats = frameStats
    }

    func display(performanceSnapshot snapshot: PerformanceMetricsSnapshot) {
        latestPerformanceSnapshot = snapshot
    }

    func requestRefresh() {
        scheduleDashboardRefresh()
    }

    func refresh() {
        updateDashboard()
    }

    var displayedEventLogText: String {
        eventsView.displayedText
    }

    var eventLogBottomDistanceForSmoke: CGFloat {
        eventsView.bottomDistanceForSmoke
    }

    func resume() {
        installDiagnosticsEventObserverIfNeeded()
        guard timer == nil else {
            scheduleDashboardRefresh(immediate: true)
            return
        }

        let timer = Timer(timeInterval: dashboardRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDashboard()
            }
        }
        timer.tolerance = dashboardRefreshInterval * 0.25
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        scheduleDashboardRefresh(immediate: true)
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        if let diagnosticsEventObserver {
            NotificationCenter.default.removeObserver(diagnosticsEventObserver)
            self.diagnosticsEventObserver = nil
        }
        isDashboardRefreshPending = false
    }

    private func installDiagnosticsEventObserverIfNeeded() {
        guard diagnosticsEventObserver == nil else {
            return
        }

        diagnosticsEventObserver = NotificationCenter.default.addObserver(
            forName: SoundtimeDiagnostics.didRecordEventNotification,
            object: SoundtimeDiagnostics.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleDashboardRefresh()
            }
        }
    }

    private func scheduleDashboardRefresh(immediate: Bool = false) {
        guard window != nil else {
            return
        }

        if immediate {
            isDashboardRefreshPending = false
            updateDashboard()
            return
        }

        guard !isDashboardRefreshPending else {
            return
        }

        let now = CACurrentMediaTime()
        let delay = max(0, dashboardRefreshCoalesceInterval - (now - lastDashboardUpdateTime))
        isDashboardRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else {
                return
            }
            MainActor.assumeIsolated {
                guard self.isDashboardRefreshPending else {
                    return
                }
                self.isDashboardRefreshPending = false
                self.updateDashboard()
            }
        }
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.045, alpha: 1).cgColor

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.96, alpha: 1)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        subtitleLabel.textColor = NSColor(white: 0.60, alpha: 1)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        fpsCard.translatesAutoresizingMaskIntoConstraints = false
        cpuCard.translatesAutoresizingMaskIntoConstraints = false
        audioCard.translatesAutoresizingMaskIntoConstraints = false
        renderCard.translatesAutoresizingMaskIntoConstraints = false
        threadCard.translatesAutoresizingMaskIntoConstraints = false
        traceCard.translatesAutoresizingMaskIntoConstraints = false
        eventsView.translatesAutoresizingMaskIntoConstraints = false
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.onPressed = { [weak self] in
            self?.exportTrace()
        }

        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(fpsCard)
        addSubview(cpuCard)
        addSubview(audioCard)
        addSubview(renderCard)
        addSubview(threadCard)
        addSubview(traceCard)
        addSubview(eventsView)
        addSubview(exportButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            exportButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            exportButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            exportButton.widthAnchor.constraint(equalToConstant: 124),
            exportButton.heightAnchor.constraint(equalToConstant: 32),

            fpsCard.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 22),
            fpsCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            fpsCard.widthAnchor.constraint(equalTo: cpuCard.widthAnchor),
            fpsCard.heightAnchor.constraint(equalToConstant: 174),

            cpuCard.topAnchor.constraint(equalTo: fpsCard.topAnchor),
            cpuCard.leadingAnchor.constraint(equalTo: fpsCard.trailingAnchor, constant: 16),
            cpuCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            cpuCard.heightAnchor.constraint(equalTo: fpsCard.heightAnchor),

            audioCard.topAnchor.constraint(equalTo: fpsCard.bottomAnchor, constant: 16),
            audioCard.leadingAnchor.constraint(equalTo: fpsCard.leadingAnchor),
            audioCard.widthAnchor.constraint(equalTo: fpsCard.widthAnchor),
            audioCard.heightAnchor.constraint(equalToConstant: 124),

            renderCard.topAnchor.constraint(equalTo: audioCard.topAnchor),
            renderCard.leadingAnchor.constraint(equalTo: audioCard.trailingAnchor, constant: 16),
            renderCard.trailingAnchor.constraint(equalTo: cpuCard.trailingAnchor),
            renderCard.heightAnchor.constraint(equalTo: audioCard.heightAnchor),

            threadCard.topAnchor.constraint(equalTo: audioCard.bottomAnchor, constant: 16),
            threadCard.leadingAnchor.constraint(equalTo: audioCard.leadingAnchor),
            threadCard.widthAnchor.constraint(equalTo: audioCard.widthAnchor),
            threadCard.heightAnchor.constraint(equalToConstant: 138),

            traceCard.topAnchor.constraint(equalTo: threadCard.topAnchor),
            traceCard.leadingAnchor.constraint(equalTo: threadCard.trailingAnchor, constant: 16),
            traceCard.trailingAnchor.constraint(equalTo: renderCard.trailingAnchor),
            traceCard.heightAnchor.constraint(equalTo: threadCard.heightAnchor),

            eventsView.topAnchor.constraint(equalTo: threadCard.bottomAnchor, constant: 16),
            eventsView.leadingAnchor.constraint(equalTo: threadCard.leadingAnchor),
            eventsView.trailingAnchor.constraint(equalTo: traceCard.trailingAnchor),
            eventsView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])
    }

    private func updateDashboard() {
        lastDashboardUpdateTime = CACurrentMediaTime()
        let diagnostics = SoundtimeDiagnostics.shared.snapshot(limit: 240)
        let importBudget = ImportWorkBudget.shared.snapshot()
        let frameStats = latestFrameStats ?? diagnostics.frameStats
        let performanceSnapshot = latestPerformanceSnapshot ?? PerformanceSampler.shared.snapshot()

        if let frameStats {
            if frameStats != lastRenderedFrameStats {
                renderCard.update(lines: [
                    "Mode          \(frameStats.gpuResidentWaveformMode)",
                    "Renderer      \(frameStats.waveformRenderer.uppercased())  draws \(frameStats.gpuWaveformDrawCount)",
                    "Uploads       \(frameStats.shaderBufferUploadCount) / \(frameStats.shaderBufferUploadInFlightCount)  \(frameStats.shaderBufferUploadByteCount / 1_024) KB",
                    "GPU cache     \(frameStats.shaderBufferCount) buffers  \(frameStats.shaderBufferByteCount / 1_048_576) MB",
                    "Fallbacks     cpu \(frameStats.cpuWaveformFallbackDrawCount)  gpu \(frameStats.waveformFallbackDrawCount)",
                    "Residency     holds \(frameStats.waveformLastGoodHoldCount)  misses \(frameStats.waveformResidentMissCount)",
                    "Shadow        \(frameStats.gpuResidentShadowSourceCount) src  \(frameStats.gpuResidentShadowVisibleTileCount)/\(frameStats.gpuResidentShadowRequestCount) tiles",
                    "Batches       \(frameStats.gpuResidentShadowDrawBatchCount) groups  \(frameStats.gpuResidentShadowDrawInstanceCount) instances",
                    "Hot path      \(frameStats.waveformHotPathViolationCount)  \(frameStats.waveformHotPathReason.isEmpty ? "-" : frameStats.waveformHotPathReason)",
                    "Effects       \(frameStats.effectVertexCount) vertices  \(frameStats.deletionEffectCount) deletes",
                ])
                lastRenderedFrameStats = frameStats
            }
        } else {
            renderCard.update(lines: ["Renderer      waiting", "GPU draws     0", "Uploads       0", "GPU cache     0 MB"])
        }

        let fpsSubtitle: String
        if performanceSnapshot.renderDemand == .idle {
            fpsSubtitle = String(
                format: "responsive %.0f  target %.0f Hz",
                performanceSnapshot.mainThreadResponsivenessFramesPerSecond,
                performanceSnapshot.targetFramesPerSecond
            )
        } else {
            fpsSubtitle = String(
                format: "%@  presented %.0f  gpu done %.0f",
                performanceSnapshot.renderDemand.rawValue,
                performanceSnapshot.timelineFramesPerSecond,
                performanceSnapshot.timelineCompletedFramesPerSecond,
            )
        }
        fpsCard.update(
            value: "\(Int(performanceSnapshot.timelineGraphFramesPerSecond.rounded()))",
            unit: "fps",
            subtitle: fpsSubtitle,
            sample: CGFloat(performanceSnapshot.timelineGraphFramesPerSecond),
            maximum: max(CGFloat(performanceSnapshot.targetFramesPerSecond), 60)
        )

        cpuCard.update(
            value: "\(Int(performanceSnapshot.cpuPercent.rounded()))",
            unit: "% CPU",
            subtitle: "normalized process CPU",
            sample: CGFloat(performanceSnapshot.cpuPercent),
            maximum: 100
        )

        if let audio = diagnostics.audioSnapshot {
            audioCard.update(lines: [
                "State         \(audio.isPlaying ? "playing" : "idle")",
                "Frame         \(audio.frameIndex) / \(audio.frameCount)",
                "Rendered      \(audio.renderedFrameCount)",
                "Underruns     \(audio.underrunCount)",
                "Dropped cmds  \(audio.droppedCommandCount)",
                "Callbacks     \(audio.callbackCount)",
                String(format: "Wall ms       %.3f last  %.3f max", Double(audio.lastRenderNanoseconds) / 1_000_000, Double(audio.maxRenderNanoseconds) / 1_000_000),
                String(format: "Work ms       %.3f last  %.3f max", Double(audio.lastRenderWorkNanoseconds) / 1_000_000, Double(audio.maxRenderWorkNanoseconds) / 1_000_000),
                "Work misses   \(audio.renderWorkDeadlineMissCount)",
                "Wall misses   \(audio.renderDeadlineMissCount)",
                "Late delivery \(audio.callbackSchedulingLateCount)",
                "Sample rate   \(Int(audio.sampleRate.rounded())) Hz",
            ])
        } else {
            audioCard.update(lines: ["State         waiting", "Underruns     0", "Dropped cmds  0", "Deadline miss 0"])
        }

        let inputAgeText: String
        if let age = performanceSnapshot.lastTimelineInputEventAge {
            inputAgeText = String(format: "%.0f ms", age * 1_000)
        } else {
            inputAgeText = "-"
        }
        threadCard.update(lines: [
            "Main stalls   \(diagnostics.mainThreadStallCount)",
            String(format: "Last stall    %.1f ms", diagnostics.lastMainThreadStallMilliseconds),
            "Heavy work    \(importBudget.exclusiveWorkInFlight) active",
            "Deferred      \(importBudget.deferredWorkCount)",
            String(
                format: "Input         %.0f/s  %@",
                performanceSnapshot.timelineInputEventsPerSecond,
                performanceSnapshot.latestTimelineInputEventKind
            ),
            "Input age     \(inputAgeText)",
            "Last defer    \(importBudget.lastDeferredWorkClass)",
            "Warnings      \(diagnostics.warningEventCount)",
            "Severe        \(diagnostics.severeEventCount)",
        ])

        traceCard.update(lines: [
            "Ring buffer   2048 events",
            "Shown events  \(diagnostics.events.count)",
            "Auto export   severe events",
            "BG complete   \(importBudget.completedWorkCount)",
            String(format: "BG defer sec  %.2f", importBudget.totalDeferredSeconds),
            "Format        JSON",
            "Location      /tmp",
        ])

        eventsView.update(events: diagnostics.events)
    }

    private func exportTrace() {
        if let url = SoundtimeDiagnostics.shared.writeTrace(reason: "manual") {
            traceCard.update(lines: [
                "Trace saved",
                url.lastPathComponent,
                "Format        JSON",
                "Location      \(url.deletingLastPathComponent().path)",
            ])
        }
    }
}

private final class PerformanceMetricCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let unitLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let sparklineView: PerformanceSparklineView
    private var renderedValue = ""
    private var renderedUnit = ""
    private var renderedSubtitle = ""

    init(
        title: String,
        accent: NSColor,
        usesLowValueDangerColor: Bool = false,
        usesHighValueDangerColor: Bool = false
    ) {
        sparklineView = PerformanceSparklineView(
            accentColor: accent,
            usesLowValueDangerColor: usesLowValueDangerColor,
            usesHighValueDangerColor: usesHighValueDangerColor
        )
        super.init(frame: .zero)
        titleLabel.stringValue = title
        configure(accent: accent)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(value: String, unit: String, subtitle: String, sample: CGFloat?, maximum: CGFloat) {
        if value != renderedValue {
            valueLabel.stringValue = value
            renderedValue = value
        }
        if unit != renderedUnit {
            unitLabel.stringValue = unit
            renderedUnit = unit
        }
        if subtitle != renderedSubtitle {
            subtitleLabel.stringValue = subtitle
            renderedSubtitle = subtitle
        }
        sparklineView.maximumValue = maximum
        if let sample {
            sparklineView.append(sample)
        }
    }

    func record(sample: CGFloat) {
        sparklineView.append(sample)
    }

    private func configure(accent: NSColor) {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1).cgColor
        layer?.cornerRadius = 8
        layer?.borderColor = NSColor(calibratedWhite: 0.20, alpha: 1).cgColor
        layer?.borderWidth = 1

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.66, alpha: 1)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 46, weight: .semibold)
        valueLabel.textColor = accent
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        unitLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        unitLabel.textColor = NSColor(white: 0.70, alpha: 1)
        unitLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        subtitleLabel.textColor = NSColor(white: 0.56, alpha: 1)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        sparklineView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(sparklineView)
        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(unitLabel)
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            valueLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            unitLabel.firstBaselineAnchor.constraint(equalTo: valueLabel.firstBaselineAnchor),
            unitLabel.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 8),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 2),

            sparklineView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            sparklineView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            sparklineView.topAnchor.constraint(greaterThanOrEqualTo: subtitleLabel.bottomAnchor, constant: 18),
            sparklineView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            sparklineView.heightAnchor.constraint(equalToConstant: 34),
        ])
    }
}

private final class PerformanceInfoCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private var renderedBody = ""

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(lines: [String]) {
        let body = lines.joined(separator: "\n")
        guard body != renderedBody else {
            return
        }
        renderedBody = body
        bodyLabel.stringValue = body
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.072, alpha: 1).cgColor
        layer?.cornerRadius = 8
        layer?.borderColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
        layer?.borderWidth = 1

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.70, alpha: 1)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        bodyLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        bodyLabel.textColor = NSColor(white: 0.88, alpha: 1)
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(bodyLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bodyLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])
    }
}

private final class PerformanceEventLogView: NSView {
    private static let eventTextColor = NSColor(white: 0.82, alpha: 1)
    private static let eventTextFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)

    private let titleLabel = NSTextField(labelWithString: "Recent Events")
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let jumpToLatestButton = PerformanceEventJumpButton()
    private var displayedEventFingerprint = ""
    private var displayedEventCount = -1
    private var hasUnseenBottomEvents = false
    private var isFollowingTail = true
    private var isApplyingEventText = false
    private var isForcingBottomScroll = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        updateTextDocumentGeometry()
        if isFollowingTail {
            forceClipViewToBottom()
        }
        updateJumpButtonVisibility()
    }

    func update(events: [SoundtimeDiagnosticEvent]) {
        let shouldFollowTail = isFollowingTail || isPinnedToBottom()
        let previousFingerprint = displayedEventFingerprint
        let nextFingerprint = eventFingerprint(for: events.last)
        let eventCount = events.count
        guard nextFingerprint != previousFingerprint || eventCount != displayedEventCount else {
            return
        }
        let hasNewTailEvent = !nextFingerprint.isEmpty && nextFingerprint != previousFingerprint
        displayedEventFingerprint = nextFingerprint
        displayedEventCount = eventCount

        titleLabel.stringValue = "Recent Events (\(eventCount))"
        let lines = events.suffix(160).map { event -> String in
            let severity = event.severity.rawValue.uppercased()
            let fields = event.fields
                .sorted { $0.key < $1.key }
                .prefix(8)
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            let timestamp = String(format: "%8.3f", event.timestamp)
            let suffix = fields.isEmpty ? "" : "  \(fields)"
            return "\(timestamp)  [\(severity)] \(event.category.rawValue).\(event.name)  \(event.message)\(suffix)"
        }
        let text = lines.isEmpty ? "No diagnostic events yet." : lines.joined(separator: "\n")
        isApplyingEventText = true
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: eventTextAttributes()
        ))
        updateTextDocumentGeometry()
        isApplyingEventText = false
        textView.needsDisplay = true
        scrollView.contentView.needsDisplay = true

        if shouldFollowTail || previousFingerprint.isEmpty {
            isFollowingTail = true
            scrollToBottom(deferred: true)
            hasUnseenBottomEvents = false
        } else if hasNewTailEvent {
            hasUnseenBottomEvents = true
        }
        updateJumpButtonVisibility()
    }

    var displayedText: String {
        textView.string
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.060, alpha: 1).cgColor
        layer?.cornerRadius = 8
        layer?.borderColor = NSColor(calibratedWhite: 0.17, alpha: 1).cgColor
        layer?.borderWidth = 1

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.70, alpha: 1)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = Self.eventTextFont
        textView.textColor = Self.eventTextColor
        textView.insertionPointColor = Self.eventTextColor
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        jumpToLatestButton.translatesAutoresizingMaskIntoConstraints = false
        jumpToLatestButton.isHidden = true
        jumpToLatestButton.onPressed = { [weak self] in
            self?.scrollToBottom(deferred: true)
            self?.hasUnseenBottomEvents = false
            self?.updateJumpButtonVisibility()
        }

        addSubview(titleLabel)
        addSubview(scrollView)
        addSubview(jumpToLatestButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            jumpToLatestButton.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            jumpToLatestButton.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -14),
            jumpToLatestButton.widthAnchor.constraint(equalToConstant: 34),
            jumpToLatestButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func eventTextAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 1.5
        return [
            .font: Self.eventTextFont,
            .foregroundColor: Self.eventTextColor,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private func updateTextDocumentGeometry() {
        let viewport = scrollView.contentView.bounds
        let width = max(1, viewport.width)
        let viewportHeight = max(1, viewport.height)
        textView.minSize = NSSize(width: 0, height: viewportHeight)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        var targetHeight = viewportHeight
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
            let usedHeight = textView.layoutManager?.usedRect(for: textContainer).height ?? 0
            targetHeight = max(viewportHeight, ceil(usedHeight + textView.textContainerInset.height * 2))
        }
        textView.frame = NSRect(x: 0, y: 0, width: width, height: targetHeight)
    }

    private func eventFingerprint(for event: SoundtimeDiagnosticEvent?) -> String {
        guard let event else {
            return ""
        }
        return [
            String(format: "%.6f", event.timestamp),
            event.category.rawValue,
            event.severity.rawValue,
            event.name,
            event.message,
        ].joined(separator: "|")
    }

    var bottomDistanceForSmoke: CGFloat {
        bottomDistance()
    }

    private func scrollToBottom(deferred: Bool) {
        forceScrollToBottom()
        guard deferred else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.forceScrollToBottom()
            self?.isFollowingTail = true
            self?.hasUnseenBottomEvents = false
            self?.updateJumpButtonVisibility()
        }
    }

    private func isPinnedToBottom() -> Bool {
        bottomDistance() <= 8
    }

    private func bottomDistance() -> CGFloat {
        guard let documentView = scrollView.documentView else {
            return 0
        }
        return max(0, textContentBottomY() - documentView.visibleRect.maxY)
    }

    private func forceScrollToBottom() {
        updateTextDocumentGeometry()
        forceClipViewToBottom()
    }

    private func forceClipViewToBottom() {
        guard let documentView = scrollView.documentView else {
            return
        }
        let visibleHeight = max(1, documentView.visibleRect.height)
        let bottomY = max(documentView.bounds.minY, textContentBottomY() - visibleHeight)
        let targetRect = NSRect(
            x: documentView.bounds.minX,
            y: bottomY,
            width: max(1, documentView.bounds.width),
            height: visibleHeight
        )
        isForcingBottomScroll = true
        documentView.scrollToVisible(targetRect)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isForcingBottomScroll = false
    }

    private func textContentBottomY() -> CGFloat {
        guard let textContainer = textView.textContainer else {
            return textView.bounds.maxY
        }
        textView.layoutManager?.ensureLayout(for: textContainer)
        let usedRect = textView.layoutManager?.usedRect(for: textContainer) ?? .zero
        let contentBottom = usedRect.maxY + textView.textContainerInset.height
        return min(textView.bounds.maxY, max(textView.bounds.minY, contentBottom))
    }

    @objc private func scrollBoundsDidChange(_ notification: Notification) {
        guard !isForcingBottomScroll, !isApplyingEventText else {
            return
        }
        if isPinnedToBottom() {
            isFollowingTail = true
            hasUnseenBottomEvents = false
        } else {
            isFollowingTail = false
        }
        updateJumpButtonVisibility()
    }

    private func updateJumpButtonVisibility() {
        jumpToLatestButton.isHidden = !hasUnseenBottomEvents || isPinnedToBottom()
    }
}

private final class PerformanceEventJumpButton: NSControl {
    var onPressed: (() -> Void)?
    private var isHovered = false {
        didSet {
            needsDisplay = true
        }
    }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        onPressed?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.5, yRadius: rect.height * 0.5)
        let fill = isHovered
            ? NSColor(calibratedRed: 0.18, green: 0.27, blue: 0.30, alpha: 0.96)
            : NSColor(calibratedWhite: 0.13, alpha: 0.92)
        fill.setFill()
        path.fill()

        NSColor(calibratedRed: 0.72, green: 0.95, blue: 1.0, alpha: isHovered ? 1.0 : 0.82).setStroke()
        let arrow = NSBezierPath()
        let center = NSPoint(x: bounds.midX, y: bounds.midY - 1)
        arrow.lineWidth = 2.2
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: center.x - 6, y: center.y + 3))
        arrow.line(to: NSPoint(x: center.x, y: center.y - 4))
        arrow.line(to: NSPoint(x: center.x + 6, y: center.y + 3))
        arrow.stroke()
    }
}

private final class PerformanceSparklineView: TimelineMetalLayerView {
    private struct SparkVertex {
        var position: SIMD2<Float>
    }

    private struct SparkSample {
        var timestamp: Float
        var value: Float
    }

    private struct SparkUniforms {
        var viewport: SIMD4<Float>
        var timing: SIMD4<Float>
        var accentColor: SIMD4<Float>
        var style: SIMD4<Float>
    }

    var maximumValue: CGFloat = 144 {
        didSet {
            if oldValue != maximumValue {
                requestRender()
            }
        }
    }

    private let accentColor: SIMD4<Float>
    private let usesLowValueDangerColor: Bool
    private let usesHighValueDangerColor: Bool
    private let historyDuration: CFTimeInterval = 15
    private let historyExitDuration: CFTimeInterval = 1.25
    private let staleSampleHoldDuration: Float = 0.75
    private let maximumSampleCount = 96
    private let renderRefreshRate: TimeInterval = 15
    private let timeOrigin = CACurrentMediaTime()
    private let sampleLock = NSLock()
    private var samples: [SparkSample] = []
    private var displayTimer: Timer?
    private var lastRenderTime: CFTimeInterval = -Double.infinity
    private var isRenderRequestPending = false
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var isLiveResizePaused = false
    private var vertices: [SparkVertex] = [
        SparkVertex(position: SIMD2<Float>(0, 0)),
        SparkVertex(position: SIMD2<Float>(1, 0)),
        SparkVertex(position: SIMD2<Float>(0, 1)),
        SparkVertex(position: SIMD2<Float>(1, 0)),
        SparkVertex(position: SIMD2<Float>(1, 1)),
        SparkVertex(position: SIMD2<Float>(0, 1)),
    ]

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    init(
        accentColor: NSColor,
        usesLowValueDangerColor: Bool = false,
        usesHighValueDangerColor: Bool = false
    ) {
        self.accentColor = Self.colorVector(from: accentColor)
        self.usesLowValueDangerColor = usesLowValueDangerColor
        self.usesHighValueDangerColor = usesHighValueDangerColor
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        drawableBackingScaleOverride = 1
        configureSparklineRenderer()
    }

    required init?(coder: NSCoder) {
        self.accentColor = SIMD4<Float>(0.10, 0.86, 0.96, 1)
        self.usesLowValueDangerColor = false
        self.usesHighValueDangerColor = false
        super.init(coder: coder)
        drawableBackingScaleOverride = 1
        configureSparklineRenderer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopDisplayTimer()
        } else {
            startDisplayTimerIfNeeded()
            render()
        }
    }

    override var isHidden: Bool {
        didSet {
            if isHidden {
                stopDisplayTimer()
            } else {
                startDisplayTimerIfNeeded()
                render()
            }
        }
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isLiveResizePaused = true
        stopDisplayTimer()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isLiveResizePaused = false
        startDisplayTimerIfNeeded()
        render()
    }

    override func layout() {
        super.layout()
        requestRender()
    }

    func append(_ sample: CGFloat) {
        let now = relativeTimestamp()
        sampleLock.lock()
        samples.append(SparkSample(timestamp: now, value: Float(max(sample, 0))))
        trimSamples(now: now)
        sampleLock.unlock()

        startDisplayTimerIfNeeded()
        requestRender()
    }

    private func configureSparklineRenderer() {
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.045, green: 0.046, blue: 0.047, alpha: 1)
        framebufferOnly = true

        guard
            let device = metalDevice,
            let commandQueue = device.makeCommandQueue()
        else {
            return
        }

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard
                let vertexFunction = library.makeFunction(name: "performance_sparkline_vertex"),
                let fragmentFunction = library.makeFunction(name: "performance_sparkline_fragment")
            else {
                return
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            self.commandQueue = commandQueue
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Swift.print("Soundtime could not create performance sparkline renderer: \(error)")
        }
    }

    private func render() {
        guard !isLiveResizePaused, !isHiddenOrHasHiddenAncestor else {
            return
        }

        guard
            let renderTarget = makeTimelineRenderTarget(),
            let commandQueue,
            let pipelineState,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderTarget.renderPassDescriptor)
        else {
            return
        }

        lastRenderTime = CACurrentMediaTime()
        let now = relativeTimestamp()
        let renderSamples = currentRenderSamples(now: now)
        var uniforms = SparkUniforms(
            viewport: SIMD4<Float>(
                Float(renderTarget.viewportSize.width),
                Float(renderTarget.viewportSize.height),
                renderTarget.backingScale,
                Float(max(maximumValue, 1))
            ),
            timing: SIMD4<Float>(
                now,
                Float(historyDuration),
                Float(renderSamples.count),
                0
            ),
            accentColor: accentColor,
            style: SIMD4<Float>(
                0.070,
                usesLowValueDangerColor ? 1.0 : 0.0,
                usesHighValueDangerColor ? 1.0 : 0.0,
                0.0
            )
        )

        encoder.setRenderPipelineState(pipelineState)
        vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            encoder.setVertexBytes(baseAddress, length: bytes.count, index: 0)
        }
        renderSamples.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress, !bytes.isEmpty {
                encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 0)
            } else {
                var emptySample = SparkSample(timestamp: now, value: 0)
                encoder.setFragmentBytes(&emptySample, length: MemoryLayout<SparkSample>.stride, index: 0)
            }
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SparkUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        commandBuffer.present(renderTarget.drawable)
        commandBuffer.commit()
    }

    private func currentRenderSamples(now: Float) -> [SparkSample] {
        sampleLock.lock()
        trimSamples(now: now)
        var renderSamples = samples
        sampleLock.unlock()

        if let latestSample = renderSamples.last, now > latestSample.timestamp {
            if renderSamples.count == 1 {
                renderSamples.insert(SparkSample(
                    timestamp: now - Float(historyDuration),
                    value: latestSample.value
                ), at: 0)
            }
            // Rendering is demand-driven, so an idle timeline can stop publishing
            // samples. Hold briefly to avoid a snap-to-zero, then let stale values
            // scroll away as history instead of turning them into current data.
            if now - latestSample.timestamp <= staleSampleHoldDuration {
                renderSamples.append(SparkSample(timestamp: now, value: latestSample.value))
            }
        }

        if renderSamples.count > maximumSampleCount {
            renderSamples.removeFirst(renderSamples.count - maximumSampleCount)
        }
        return renderSamples
    }

    private func startDisplayTimerIfNeeded() {
        guard
            displayTimer == nil,
            window != nil,
            !isLiveResizePaused,
            !isHiddenOrHasHiddenAncestor
        else {
            return
        }

        let timer = Timer(timeInterval: 1 / renderRefreshRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.render()
            }
        }
        timer.tolerance = 1 / 30
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
        isRenderRequestPending = false
    }

    private func requestRender() {
        guard window != nil else {
            return
        }

        let now = CACurrentMediaTime()
        let minimumInterval = 1 / max(renderRefreshRate, 1)
        guard now - lastRenderTime < minimumInterval else {
            render()
            return
        }

        guard !isRenderRequestPending else {
            return
        }

        isRenderRequestPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + minimumInterval) { [weak self] in
            guard let self else {
                return
            }
            MainActor.assumeIsolated {
                self.isRenderRequestPending = false
                self.render()
            }
        }
    }

    private func trimSamples(now: Float) {
        let oldestTimestamp = now - Float(historyDuration + historyExitDuration)
        while samples.count > 1 &&
            (samples.count > maximumSampleCount || (samples.first?.timestamp ?? now) < oldestTimestamp)
        {
            samples.removeFirst()
        }
    }

    private func relativeTimestamp() -> Float {
        Float(CACurrentMediaTime() - timeOrigin)
    }

    private static func colorVector(from color: NSColor) -> SIMD4<Float> {
        let resolvedColor = color.usingColorSpace(.deviceRGB) ?? color
        return SIMD4<Float>(
            Float(resolvedColor.redComponent),
            Float(resolvedColor.greenComponent),
            Float(resolvedColor.blueComponent),
            Float(resolvedColor.alphaComponent)
        )
    }

    static func smokeRenderPixelSummary(
        values: [Float],
        maximumValue: Float,
        usesLowValueDangerColor: Bool,
        now: Float = 16,
        width: Int = 192,
        height: Int = 64
    ) throws -> MetalPixelSmokeSummary {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalPixelSmokeError.metalDeviceUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalPixelSmokeError.commandQueueUnavailable
        }
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        guard
            let vertexFunction = library.makeFunction(name: "performance_sparkline_vertex"),
            let fragmentFunction = library.makeFunction(name: "performance_sparkline_fragment")
        else {
            throw MetalPixelSmokeError.libraryUnavailable
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.renderTarget]
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw MetalPixelSmokeError.textureUnavailable
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.045, green: 0.046, blue: 0.047, alpha: 1)

        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            throw MetalPixelSmokeError.commandBufferUnavailable
        }

        let vertices = [
            SparkVertex(position: SIMD2<Float>(0, 0)),
            SparkVertex(position: SIMD2<Float>(1, 0)),
            SparkVertex(position: SIMD2<Float>(0, 1)),
            SparkVertex(position: SIMD2<Float>(1, 0)),
            SparkVertex(position: SIMD2<Float>(1, 1)),
            SparkVertex(position: SIMD2<Float>(0, 1)),
        ]
        let clampedValues = values.isEmpty ? [Float(0)] : Array(values.prefix(192))
        let spacing = 15 / Float(max(clampedValues.count - 1, 1))
        let samples = clampedValues.enumerated().map { index, value in
            SparkSample(timestamp: now - 15 + Float(index) * spacing, value: max(value, 0))
        }
        var uniforms = SparkUniforms(
            viewport: SIMD4<Float>(Float(width), Float(height), 1, max(maximumValue, 1)),
            timing: SIMD4<Float>(now, 15, Float(samples.count), 0),
            accentColor: SIMD4<Float>(0.10, 0.86, 0.96, 1),
            style: SIMD4<Float>(0.070, usesLowValueDangerColor ? 1.0 : 0.0, 0.0, 0.0)
        )

        encoder.setRenderPipelineState(pipelineState)
        vertices.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                encoder.setVertexBytes(baseAddress, length: bytes.count, index: 0)
            }
        }
        samples.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 0)
            }
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SparkUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return MetalPixelSmokeSummary.analyzeBGRA8(bytes, width: width, height: height)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct SparkVertex {
        float2 position;
    };

    struct SparkSample {
        float timestamp;
        float value;
    };

    struct SparkUniforms {
        float4 viewport;
        float4 timing;
        float4 accentColor;
        float4 style;
    };

    struct RasterizedVertex {
        float4 position [[position]];
        float2 uv;
    };

    vertex RasterizedVertex performance_sparkline_vertex(
        uint vertexID [[vertex_id]],
        constant SparkVertex *vertices [[buffer(0)]]
    ) {
        float2 position = vertices[vertexID].position;
        RasterizedVertex out;
        out.position = float4(position.x * 2.0 - 1.0, position.y * 2.0 - 1.0, 0.0, 1.0);
        out.uv = position;
        return out;
    }

    static float rect_alpha(float2 p, float left, float right, float bottom, float top) {
        float2 distance = min(p - float2(left, bottom), float2(right, top) - p);
        float edgeDistance = min(distance.x, distance.y);
        float aa = max(max(fwidth(p.x), fwidth(p.y)), 0.001);
        return smoothstep(0.0, aa, edgeDistance);
    }

    static float line_alpha(float value, float target, float width) {
        float distance = abs(value - target);
        float aa = max(fwidth(value), 0.001);
        return 1.0 - smoothstep(width, width + aa, distance);
    }

    static float segment_distance(float2 point, float2 start, float2 end) {
        float2 segment = end - start;
        float segmentLengthSquared = max(dot(segment, segment), 0.000001);
        float amount = clamp(dot(point - start, segment) / segmentLengthSquared, 0.0, 1.0);
        return length(point - (start + segment * amount));
    }

    static float sample_x(SparkSample sample, float now, float duration) {
        return 1.0 - ((now - sample.timestamp) / max(duration, 0.001));
    }

    static float sample_y(SparkSample sample, float maxValue, float bottom, float top) {
        float normalizedValue = clamp(sample.value / max(maxValue, 1.0), 0.0, 1.0);
        return mix(bottom, top, normalizedValue);
    }

    static float low_value_danger(SparkSample sample, float enabled) {
        if (enabled < 0.5) {
            return 0.0;
        }

        return 1.0 - smoothstep(60.0, 80.0, sample.value);
    }

    static float high_value_danger(SparkSample sample, float enabled) {
        if (enabled < 0.5) {
            return 0.0;
        }

        return smoothstep(80.0, 100.0, sample.value);
    }

    fragment float4 performance_sparkline_fragment(
        RasterizedVertex in [[stage_in]],
        constant SparkSample *samples [[buffer(0)]],
        constant SparkUniforms &uniforms [[buffer(1)]]
    ) {
        float2 uv = in.uv;
        float width = max(uniforms.viewport.x, 1.0);
        float height = max(uniforms.viewport.y, 1.0);
        float maxValue = max(uniforms.viewport.w, 1.0);
        float now = uniforms.timing.x;
        float duration = max(uniforms.timing.y, 0.001);
        uint sampleCount = min(uint(max(uniforms.timing.z, 0.0)), 192u);

        float left = 0.012;
        float right = 0.988;
        float bottom = 0.14;
        float top = 0.88;
        float body = rect_alpha(uv, left, right, bottom, top);
        float3 accent = uniforms.accentColor.rgb;
        float3 color = float3(0.043, 0.045, 0.046);
        color = mix(color, float3(0.057, 0.063, 0.066), body);

        float grid = 0.0;
        for (float amount = 0.25; amount < 1.0; amount += 0.25) {
            float y = mix(bottom, top, amount);
            grid += line_alpha(uv.y, y, 0.0012) * 0.18 * body;
        }
        color = mix(color, accent * 0.34, clamp(grid, 0.0, 1.0));

        float aspect = width / height;
        float2 scaledUV = float2(uv.x * aspect, uv.y);
        float edgeFadeWidth = max(uniforms.style.x, 0.001);
        float edgeFade = smoothstep(left, left + edgeFadeWidth, uv.x) *
            (1.0 - smoothstep(right - edgeFadeWidth, right, uv.x));
        float lowDangerEnabled = uniforms.style.y;
        float highDangerEnabled = uniforms.style.z;
        float line = 0.0;
        float glow = 0.0;
        float lineDanger = 0.0;
        float glowDanger = 0.0;
        float underFill = 0.0;

        if (sampleCount >= 2u) {
            for (uint i = 1u; i < sampleCount; ++i) {
                SparkSample previousSample = samples[i - 1u];
                SparkSample currentSample = samples[i];
                float x0 = mix(left, right, sample_x(previousSample, now, duration));
                float x1 = mix(left, right, sample_x(currentSample, now, duration));
                if ((x0 < left && x1 < left) || (x0 > right && x1 > right)) {
                    continue;
                }

                float y0 = sample_y(previousSample, maxValue, bottom, top);
                float y1 = sample_y(currentSample, maxValue, bottom, top);
                float2 p0 = float2(x0 * aspect, y0);
                float2 p1 = float2(x1 * aspect, y1);
                float distance = segment_distance(scaledUV, p0, p1);
                float lineWidth = 1.35 / height;
                float glowWidth = 8.5 / height;
                float segmentLine = (1.0 - smoothstep(lineWidth, lineWidth + 1.3 / height, distance)) * edgeFade;
                float segmentGlow = (1.0 - smoothstep(lineWidth, glowWidth, distance)) * edgeFade;
                float danger = max(
                    max(
                        low_value_danger(previousSample, lowDangerEnabled),
                        high_value_danger(previousSample, highDangerEnabled)
                    ),
                    max(
                        low_value_danger(currentSample, lowDangerEnabled),
                        high_value_danger(currentSample, highDangerEnabled)
                    )
                );
                line = max(line, segmentLine);
                glow = max(glow, segmentGlow);
                lineDanger = max(lineDanger, segmentLine * danger);
                glowDanger = max(glowDanger, segmentGlow * danger);

                float segmentLeft = min(x0, x1);
                float segmentRight = max(x0, x1);
                float segmentT = clamp((uv.x - x0) / max(x1 - x0, 0.000001), 0.0, 1.0);
                float yOnSegment = mix(y0, y1, segmentT);
                float inSegment = smoothstep(segmentLeft, segmentLeft + 0.004, uv.x) *
                    (1.0 - smoothstep(segmentRight - 0.004, segmentRight, uv.x));
                underFill = max(underFill, inSegment * smoothstep(bottom, yOnSegment, uv.y) *
                    (1.0 - smoothstep(yOnSegment, yOnSegment + 0.018, uv.y)) * edgeFade);
            }
        }

        float glowDangerAmount = clamp(glowDanger / max(glow, 0.0001), 0.0, 1.0);
        float lineDangerAmount = clamp(lineDanger / max(line, 0.0001), 0.0, 1.0);
        float3 dangerGlowColor = float3(1.0, 0.13, 0.08);
        float3 dangerLineColor = mix(float3(0.96, 0.20, 0.12), float3(1.0, 0.62, 0.50), line * 0.30);
        float3 glowColor = mix(accent, dangerGlowColor, glowDangerAmount);
        color += glowColor * glow * 0.26 * body;
        color = mix(color, accent * 0.28, underFill * 0.16 * body);
        float3 calmLineColor = mix(accent, float3(0.94, 0.99, 1.0), line * 0.35);
        float3 lineColor = mix(calmLineColor, dangerLineColor, lineDangerAmount);
        color = mix(color, lineColor, line * body);

        float sheen = smoothstep(top, top - 0.14, uv.y) * body * 0.05;
        color += accent * sheen;

        return float4(color, 1.0);
    }
    """
}

private final class PerformanceActionButton: NSControl {
    var onPressed: (() -> Void)?
    private var isHovered = false {
        didSet {
            needsDisplay = true
        }
    }
    private let title: String
    private var trackingArea: NSTrackingArea?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        onPressed?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        (isHovered ? NSColor(white: 0.90, alpha: 1) : NSColor(white: 0.70, alpha: 1)).setFill()
        path.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor(white: 0.08, alpha: 1),
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(x: bounds.midX - size.width * 0.5, y: bounds.midY - size.height * 0.5),
            withAttributes: attributes
        )
    }
}

final class ProcessCPUUsageSampler {
    private var previousWallTime = CACurrentMediaTime()
    private var previousCPUTime = ProcessCPUUsageSampler.currentCPUTime()

    func samplePercent() -> Double {
        let now = CACurrentMediaTime()
        let cpuTime = Self.currentCPUTime()
        defer {
            previousWallTime = now
            previousCPUTime = cpuTime
        }

        let wallDelta = max(now - previousWallTime, 0.001)
        let cpuDelta = max(cpuTime - previousCPUTime, 0)
        return min(max(cpuDelta / wallDelta * 100, 0), 999)
    }

    private static func currentCPUTime() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return 0
        }

        let user = TimeInterval(usage.ru_utime.tv_sec) +
            TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
        let system = TimeInterval(usage.ru_stime.tv_sec) +
            TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
