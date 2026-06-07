import AppKit
import Darwin
import QuartzCore

final class PerformanceDashboardWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PerformanceDashboardWindowController()

    private let dashboardView = PerformanceDashboardView()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Soundtime Performance"
        window.minSize = NSSize(width: 760, height: 520)
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

    func windowWillClose(_ notification: Notification) {
        dashboardView.pause()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        dashboardView.resume()
    }
}

private final class PerformanceDashboardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Performance Monitor")
    private let subtitleLabel = NSTextField(labelWithString: "Audio, render, GPU, queues, and trace health")
    private let fpsCard = PerformanceMetricCardView(title: "FPS", accent: NSColor(calibratedRed: 0.10, green: 0.86, blue: 0.96, alpha: 1))
    private let cpuCard = PerformanceMetricCardView(title: "CPU", accent: NSColor(calibratedRed: 0.95, green: 0.98, blue: 1.00, alpha: 1))
    private let audioCard = PerformanceInfoCardView(title: "Audio Realtime")
    private let renderCard = PerformanceInfoCardView(title: "Render / GPU")
    private let threadCard = PerformanceInfoCardView(title: "Threading")
    private let traceCard = PerformanceInfoCardView(title: "Trace Capture")
    private let eventsView = PerformanceEventLogView()
    private let exportButton = PerformanceActionButton(title: "Export Trace")
    private let cpuSampler = ProcessCPUUsageSampler()
    private var timer: Timer?
    private var latestFrameStats: TimelineFrameStats?

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
        updateDashboard()
    }

    func resume() {
        guard timer == nil else {
            updateDashboard()
            return
        }

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateDashboard()
            }
        }
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
            fpsCard.heightAnchor.constraint(equalToConstant: 150),

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
        let diagnostics = SoundtimeDiagnostics.shared.snapshot(limit: 60)
        let importBudget = ImportWorkBudget.shared.snapshot()
        let frameStats = latestFrameStats ?? diagnostics.frameStats
        let cpuPercent = cpuSampler.samplePercent()

        if let frameStats {
            fpsCard.update(
                value: "\(frameStats.framesPerSecond)",
                unit: "fps",
                subtitle: String(format: "avg %.1f ms  worst %.1f ms", frameStats.averageFrameTimeMilliseconds, frameStats.worstFrameTimeMilliseconds),
                sample: CGFloat(frameStats.framesPerSecond),
                maximum: 144
            )
            renderCard.update(lines: [
                "Renderer      \(frameStats.waveformRenderer.uppercased())",
                "GPU draws     \(frameStats.gpuWaveformDrawCount)",
                "Uploads       \(frameStats.shaderBufferUploadCount) / \(frameStats.shaderBufferUploadInFlightCount) in flight",
                "GPU cache     \(frameStats.shaderBufferCount) buffers  \(frameStats.shaderBufferByteCount / 1_048_576) MB",
                "Effects       \(frameStats.effectVertexCount) vertices  \(frameStats.deletionEffectCount) deletes",
            ])
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

    init(title: String, accent: NSColor) {
        sparklineView = PerformanceSparklineView(accentColor: accent)
        super.init(frame: .zero)
        titleLabel.stringValue = title
        configure(accent: accent)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(value: String, unit: String, subtitle: String, sample: CGFloat, maximum: CGFloat) {
        valueLabel.stringValue = value
        unitLabel.stringValue = unit
        subtitleLabel.stringValue = subtitle
        sparklineView.maximumValue = maximum
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

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(unitLabel)
        addSubview(subtitleLabel)
        addSubview(sparklineView)

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
            sparklineView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
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
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        let lines = events.suffix(36).reversed().map { event -> String in
            let severity = event.severity.rawValue.uppercased()
            let fields = event.fields
                .sorted { $0.key < $1.key }
                .prefix(4)
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            return "[\(severity)] \(event.category.rawValue).\(event.name)  \(event.message)  \(fields)"
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

private final class PerformanceSparklineView: NSView {
    var maximumValue: CGFloat = 144 {
        didSet {
            needsDisplay = true
        }
    }

    private let accentColor: NSColor
    private var samples: [CGFloat] = []
    private let maximumSampleCount = 96

    init(accentColor: NSColor) {
        self.accentColor = accentColor
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    func append(_ sample: CGFloat) {
        samples.append(max(sample, 0))
        if samples.count > maximumSampleCount {
            samples.removeFirst(samples.count - maximumSampleCount)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 4, bounds.height > 4 else {
            return
        }

        let rect = bounds.insetBy(dx: 1, dy: 1)
        NSColor(calibratedWhite: 0.045, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()

        NSColor(calibratedWhite: 0.16, alpha: 1).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        border.lineWidth = 1
        border.stroke()

        guard samples.count > 1 else {
            return
        }

        let maxValue = max(maximumValue, 1)
        let path = NSBezierPath()
        for (index, sample) in samples.enumerated() {
            let x = rect.minX + CGFloat(index) / CGFloat(max(samples.count - 1, 1)) * rect.width
            let normalized = min(max(sample / maxValue, 0), 1)
            let y = rect.minY + normalized * rect.height
            if index == 0 {
                path.move(to: NSPoint(x: x, y: y))
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }

        accentColor.withAlphaComponent(0.32).setStroke()
        path.lineWidth = 5
        path.stroke()
        accentColor.setStroke()
        path.lineWidth = 1.6
        path.stroke()
    }
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

private final class ProcessCPUUsageSampler {
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
