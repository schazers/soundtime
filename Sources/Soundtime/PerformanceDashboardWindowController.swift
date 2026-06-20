import AppKit
import Darwin
import Metal
import QuartzCore

final class PerformanceDashboardWindowController: NSWindowController, NSWindowDelegate {
    private enum LifecycleSmokeError: Error, CustomStringConvertible {
        case windowDidNotClose

        var description: String {
            switch self {
            case .windowDidNotClose:
                return "performance dashboard window remained visible after close"
            }
        }
    }

    private static var sharedController: PerformanceDashboardWindowController?

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

        controller.display(frameStats: frameStats)
    }

    static func refreshIfVisible() {
        guard let controller = sharedController, controller.window?.isVisible == true else {
            return
        }

        controller.refresh()
    }

    static func closeIfLoaded() {
        sharedController?.closeIfVisible()
    }

    @MainActor
    static func runLifecycleSmoke() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let controller = PerformanceDashboardWindowController.shared
        controller.showDashboard(relativeTo: nil)

        for index in 0..<12 {
            controller.display(frameStats: TimelineFrameStats(
                framesPerSecond: index.isMultiple(of: 4) ? 72 : 144,
                averageFrameTimeMilliseconds: index.isMultiple(of: 4) ? 13.8 : 6.9,
                frameTimeJitterMilliseconds: 0.4,
                worstFrameTimeMilliseconds: index.isMultiple(of: 4) ? 18.0 : 8.2,
                waveformRenderer: "smoke",
                cpuWaveformVertexCount: 0,
                gpuWaveformDrawCount: 4,
                shaderBufferUploadCount: 0,
                shaderBufferCount: 2,
                shaderBufferByteCount: 2_048,
                shaderBufferUploadInFlightCount: 0,
                waveformMipCacheCount: 2,
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
    }

    func display(frameStats: TimelineFrameStats) {
        dashboardView.display(frameStats: frameStats)
    }

    func refresh() {
        dashboardView.refresh()
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
    private let cpuCard = PerformanceMetricCardView(title: "CPU", accent: NSColor(calibratedRed: 0.95, green: 0.98, blue: 1.00, alpha: 1))
    private let audioCard = PerformanceInfoCardView(title: "Audio Realtime")
    private let renderCard = PerformanceInfoCardView(title: "Render / GPU")
    private let threadCard = PerformanceInfoCardView(title: "Threading")
    private let traceCard = PerformanceInfoCardView(title: "Trace Capture")
    private let eventsView = PerformanceEventLogView()
    private let exportButton = PerformanceActionButton(title: "Export Trace")
    private let cpuSampler = ProcessCPUUsageSampler()
    private let dashboardRefreshInterval: TimeInterval = 0.5
    private let graphSampleInterval: TimeInterval = 1.0 / 15.0
    private var timer: Timer?
    private var latestFrameStats: TimelineFrameStats?
    private var lastRenderedFrameStats: TimelineFrameStats?
    private var lastFPSGraphSampleTime: CFTimeInterval = 0

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
        let now = CACurrentMediaTime()
        guard now - lastFPSGraphSampleTime >= graphSampleInterval else {
            return
        }

        lastFPSGraphSampleTime = now
        fpsCard.record(sample: CGFloat(frameStats.framesPerSecond))
    }

    func refresh() {
        updateDashboard()
    }

    func resume() {
        guard timer == nil else {
            updateDashboard()
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
        updateDashboard()
    }

    func pause() {
        timer?.invalidate()
        timer = nil
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
            threadCard.heightAnchor.constraint(equalToConstant: 118),

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
        let diagnostics = SoundtimeDiagnostics.shared.snapshot(limit: 240)
        let importBudget = ImportWorkBudget.shared.snapshot()
        let frameStats = latestFrameStats ?? diagnostics.frameStats
        let cpuPercent = cpuSampler.samplePercent()

        if let frameStats {
            if frameStats != lastRenderedFrameStats {
                fpsCard.update(
                    value: "\(frameStats.framesPerSecond)",
                    unit: "fps",
                    subtitle: String(format: "avg %.1f ms  worst %.1f ms", frameStats.averageFrameTimeMilliseconds, frameStats.worstFrameTimeMilliseconds),
                    sample: nil,
                    maximum: 144
                )
                renderCard.update(lines: [
                    "Renderer      \(frameStats.waveformRenderer.uppercased())",
                    "GPU draws     \(frameStats.gpuWaveformDrawCount)",
                    "Uploads       \(frameStats.shaderBufferUploadCount) / \(frameStats.shaderBufferUploadInFlightCount) in flight",
                    "GPU cache     \(frameStats.shaderBufferCount) buffers  \(frameStats.shaderBufferByteCount / 1_048_576) MB",
                    "Effects       \(frameStats.effectVertexCount) vertices  \(frameStats.deletionEffectCount) deletes",
                ])
                lastRenderedFrameStats = frameStats
            }
        } else {
            fpsCard.update(value: "0", unit: "fps", subtitle: "waiting for renderer", sample: 0, maximum: 144)
            renderCard.update(lines: ["Renderer      waiting", "GPU draws     0", "Uploads       0", "GPU cache     0 MB"])
        }

        cpuCard.update(
            value: "\(Int(cpuPercent.rounded()))",
            unit: "% CPU",
            subtitle: "process CPU across all cores",
            sample: CGFloat(cpuPercent),
            maximum: 400
        )

        if let audio = diagnostics.audioSnapshot {
            audioCard.update(lines: [
                "State         \(audio.isPlaying ? "playing" : "idle")",
                "Frame         \(audio.frameIndex) / \(audio.frameCount)",
                "Rendered      \(audio.renderedFrameCount)",
                "Underruns     \(audio.underrunCount)",
                "Dropped cmds  \(audio.droppedCommandCount)",
                "Callbacks     \(audio.callbackCount)",
                String(format: "Render ms     %.3f last  %.3f max", Double(audio.lastRenderNanoseconds) / 1_000_000, Double(audio.maxRenderNanoseconds) / 1_000_000),
                "Deadline miss \(audio.renderDeadlineMissCount)",
                "Sample rate   \(Int(audio.sampleRate.rounded())) Hz",
            ])
        } else {
            audioCard.update(lines: ["State         waiting", "Underruns     0", "Dropped cmds  0", "Deadline miss 0"])
        }

        threadCard.update(lines: [
            "Main stalls   \(diagnostics.mainThreadStallCount)",
            String(format: "Last stall    %.1f ms", diagnostics.lastMainThreadStallMilliseconds),
            "Heavy work    \(importBudget.exclusiveWorkInFlight) active",
            "Deferred      \(importBudget.deferredWorkCount)",
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

    init(title: String, accent: NSColor, usesLowValueDangerColor: Bool = false) {
        sparklineView = PerformanceSparklineView(
            accentColor: accent,
            usesLowValueDangerColor: usesLowValueDangerColor
        )
        super.init(frame: .zero)
        titleLabel.stringValue = title
        configure(accent: accent)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(value: String, unit: String, subtitle: String, sample: CGFloat?, maximum: CGFloat) {
        valueLabel.stringValue = value
        unitLabel.stringValue = unit
        subtitleLabel.stringValue = subtitle
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

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(lines: [String]) {
        bodyLabel.stringValue = lines.joined(separator: "\n")
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
    private let titleLabel = NSTextField(labelWithString: "Recent Events")
    private let textView = NSTextView()
    private let scrollView = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(events: [SoundtimeDiagnosticEvent]) {
        let lines = events.suffix(160).reversed().map { event -> String in
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
        textView.string = lines.isEmpty ? "No diagnostic events yet." : lines.joined(separator: "\n")
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

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        textView.textColor = NSColor(white: 0.82, alpha: 1)
        textView.textContainerInset = NSSize(width: 10, height: 8)
        scrollView.documentView = textView

        addSubview(titleLabel)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
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
    private let historyDuration: CFTimeInterval = 15
    private let historyExitDuration: CFTimeInterval = 1.25
    private let staleSampleHoldDuration: Float = 0.75
    private let maximumSampleCount = 160
    private let renderRefreshRate: TimeInterval = 30
    private let timeOrigin = CACurrentMediaTime()
    private let sampleLock = NSLock()
    private var samples: [SparkSample] = []
    private var displayTimer: Timer?
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

    init(accentColor: NSColor, usesLowValueDangerColor: Bool = false) {
        self.accentColor = Self.colorVector(from: accentColor)
        self.usesLowValueDangerColor = usesLowValueDangerColor
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        drawableBackingScaleOverride = 1
        configureSparklineRenderer()
    }

    required init?(coder: NSCoder) {
        self.accentColor = SIMD4<Float>(0.10, 0.86, 0.96, 1)
        self.usesLowValueDangerColor = false
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
            style: SIMD4<Float>(0.070, usesLowValueDangerColor ? 1.0 : 0.0, 0.0, 0.0)
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
        timer.tolerance = 1 / 120
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func requestRender() {
        guard window != nil else {
            return
        }

        render()
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
        float dangerEnabled = uniforms.style.y;
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
                    low_value_danger(previousSample, dangerEnabled),
                    low_value_danger(currentSample, dangerEnabled)
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
