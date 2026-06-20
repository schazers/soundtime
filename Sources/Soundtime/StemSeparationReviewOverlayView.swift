import AppKit
import AVFoundation
import QuartzCore

struct StemSeparationPreviewItem {
    let name: String
    let buffer: DecodedAudioBuffer
}

final class StemSeparationReviewOverlayView: NSView {
    var onAccept: (() -> Void)?
    var onReject: (() -> Void)?

    private let panelView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.095, alpha: 0.985).cgColor
        view.layer?.cornerRadius = 18
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.48
        view.layer?.shadowRadius = 28
        view.layer?.shadowOffset = CGSize(width: 0, height: -10)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Accept Music Stems?")
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let detailLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.62)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let rejectButton = StemReviewIconButton(kind: .reject)
    private let acceptButton = StemReviewIconButton(kind: .accept)
    private let playPauseButton = StemReviewPlayPauseButton()
    private let waveformView = StemSeparationWaveformView()
    private let previewPlayer = StemSeparationPreviewPlayer()

    private var progressTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            rejectPressed(nil)
            return
        }
        if event.keyCode == 49 {
            togglePreviewPlayback()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            acceptPressed(nil)
            return
        }
        super.keyDown(with: event)
    }

    func show(
        originalBuffer: DecodedAudioBuffer,
        stems: [StemSeparationPreviewItem],
        trackName: String,
        providerSummary: String
    ) throws {
        detailLabel.stringValue = "\(trackName) - \(providerSummary)"
        var items = [StemSeparationPreviewItem(name: "Original", buffer: originalBuffer)]
        items.append(contentsOf: stems)
        waveformView.display(items: items)
        try previewPlayer.load(items: items)
        waveformView.activeIndex = min(1, max(items.count - 1, 0))
        previewPlayer.activeIndex = waveformView.activeIndex
        isHidden = false
        alphaValue = 0
        window?.makeFirstResponder(self)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        previewPlayer.play()
        playPauseButton.isPlaying = true
        startProgressTimer()
    }

    func hide(animated: Bool = true) {
        stopProgressTimer()
        previewPlayer.stop()
        let completion = { [weak self] in
            self?.isHidden = true
            self?.alphaValue = 0
        }
        guard animated else {
            completion()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: {
            completion()
        }
    }

    func togglePreviewPlayback() {
        previewPlayer.togglePlayback()
        playPauseButton.isPlaying = previewPlayer.isPlaying
        updatePreviewProgress()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.28).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        alphaValue = 0

        rejectButton.target = self
        rejectButton.action = #selector(rejectPressed(_:))
        acceptButton.target = self
        acceptButton.action = #selector(acceptPressed(_:))
        playPauseButton.target = self
        playPauseButton.action = #selector(playPausePressed(_:))

        waveformView.onChoiceChanged = { [weak self] index in
            guard let self else {
                return
            }
            previewPlayer.activeIndex = index
            if !previewPlayer.isPlaying {
                previewPlayer.play()
            }
            updatePreviewProgress()
        }
        waveformView.onSeekRequested = { [weak self] progress in
            self?.previewPlayer.seek(to: progress)
            self?.updatePreviewProgress()
        }

        addSubview(panelView)
        panelView.addSubview(titleLabel)
        panelView.addSubview(detailLabel)
        panelView.addSubview(rejectButton)
        panelView.addSubview(acceptButton)
        panelView.addSubview(playPauseButton)
        panelView.addSubview(waveformView)

        let preferredWidth = panelView.widthAnchor.constraint(equalToConstant: 920)
        preferredWidth.priority = .defaultHigh
        let preferredHeight = panelView.heightAnchor.constraint(equalToConstant: 560)
        preferredHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            panelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            panelView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            panelView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -32),
            panelView.widthAnchor.constraint(greaterThanOrEqualToConstant: 620),
            panelView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
            preferredWidth,
            preferredHeight,

            rejectButton.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 22),
            rejectButton.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 20),
            rejectButton.widthAnchor.constraint(equalToConstant: 36),
            rejectButton.heightAnchor.constraint(equalToConstant: 36),

            acceptButton.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -22),
            acceptButton.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 20),
            acceptButton.widthAnchor.constraint(equalToConstant: 36),
            acceptButton.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.centerYAnchor.constraint(equalTo: rejectButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: rejectButton.trailingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: acceptButton.leadingAnchor, constant: -16),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            detailLabel.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 36),
            detailLabel.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -36),

            playPauseButton.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 14),
            playPauseButton.centerXAnchor.constraint(equalTo: panelView.centerXAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),

            waveformView.topAnchor.constraint(equalTo: playPauseButton.bottomAnchor, constant: 16),
            waveformView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 24),
            waveformView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -24),
            waveformView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor, constant: -26),
        ])
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePreviewProgress()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updatePreviewProgress() {
        let snapshot = previewPlayer.snapshot()
        playPauseButton.isPlaying = snapshot.isPlaying
        waveformView.playheadProgress = snapshot.progress
        if snapshot.isAtEnd {
            previewPlayer.seek(to: 0)
            waveformView.playheadProgress = 0
            playPauseButton.isPlaying = false
        }
    }

    @objc private func acceptPressed(_ sender: Any?) {
        onAccept?()
    }

    @objc private func rejectPressed(_ sender: Any?) {
        onReject?()
    }

    @objc private func playPausePressed(_ sender: Any?) {
        togglePreviewPlayback()
    }
}

private final class StemSeparationWaveformView: NSView {
    var onChoiceChanged: ((Int) -> Void)?
    var onSeekRequested: ((Float) -> Void)?

    var activeIndex = 0 {
        didSet {
            needsDisplay = true
        }
    }

    var playheadProgress: Float = 0 {
        didSet {
            guard oldValue != playheadProgress else {
                return
            }
            needsDisplay = true
        }
    }

    private struct Row {
        let name: String
        let overview: WaveformOverview
    }

    private var rows: [Row] = []
    private var hoveredIndex: Int?
    private var trackingArea: NSTrackingArea?
    private let labelWidth: CGFloat = 128

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for index in rows.indices {
            addCursorRect(rowRect(for: index), cursor: .pointingHand)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let nextHover = rowIndex(at: point)
        guard hoveredIndex != nextHover else {
            return
        }
        hoveredIndex = nextHover
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if rowIndex(at: point) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point) else {
            return
        }

        activeIndex = index
        onChoiceChanged?(index)
        if waveformHitRect(for: index).contains(point) {
            let rect = waveformProgressRect
            let progress = Float((point.x - rect.minX) / max(rect.width, 1))
            onSeekRequested?(min(max(progress, 0), 1))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        bounds.fill()
        for index in rows.indices {
            drawRow(index: index, rowRect: rowRect(for: index))
        }
        drawPlayhead()
    }

    func display(items: [StemSeparationPreviewItem]) {
        rows = items.map {
            Row(name: $0.name, overview: Self.fastOverview(from: $0.buffer, targetBinCount: 1_600))
        }
        activeIndex = min(activeIndex, max(rows.count - 1, 0))
        playheadProgress = 0
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    private var waveformProgressRect: NSRect {
        NSRect(
            x: labelWidth,
            y: 0,
            width: max(bounds.width - labelWidth - 16, 1),
            height: bounds.height
        )
    }

    private func rowRect(for index: Int) -> NSRect {
        guard !rows.isEmpty else {
            return .zero
        }
        let gap: CGFloat = 8
        let rowCount = CGFloat(rows.count)
        let rowHeight = max((bounds.height - gap * max(rowCount - 1, 0)) / rowCount, 24)
        let y = bounds.maxY - CGFloat(index + 1) * rowHeight - CGFloat(index) * gap
        return NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
    }

    private func labelRect(for index: Int) -> NSRect {
        let row = rowRect(for: index)
        return NSRect(x: row.minX, y: row.minY, width: labelWidth, height: row.height)
    }

    private func waveformHitRect(for index: Int) -> NSRect {
        let row = rowRect(for: index)
        return NSRect(
            x: row.minX + labelWidth,
            y: row.minY,
            width: max(row.width - labelWidth, 0),
            height: row.height
        )
    }

    private func rowIndex(at point: CGPoint) -> Int? {
        rows.indices.first { rowRect(for: $0).contains(point) }
    }

    private func drawRow(index: Int, rowRect: NSRect) {
        let isActive = activeIndex == index
        let isHovered = hoveredIndex == index
        let rowPath = NSBezierPath(roundedRect: rowRect, xRadius: 9, yRadius: 9)
        let fillWhite: CGFloat = isActive ? 0.145 : (isHovered ? 0.118 : 0.092)
        NSColor(calibratedWhite: fillWhite, alpha: 1).setFill()
        rowPath.fill()

        let labelColor = isActive ?
            NSColor(calibratedRed: 0.78, green: 0.98, blue: 1, alpha: 1) :
            NSColor(calibratedWhite: isHovered ? 0.92 : 0.68, alpha: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let label = rows[index].name
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: labelColor,
            .paragraphStyle: paragraph,
        ]
        let labelRect = labelRect(for: index)
        label.draw(
            in: NSRect(x: labelRect.minX + 8, y: labelRect.midY - 10, width: labelRect.width - 16, height: 22),
            withAttributes: attributes
        )

        let waveRect = NSRect(
            x: rowRect.minX + labelWidth,
            y: rowRect.minY + 8,
            width: rowRect.width - labelWidth - 16,
            height: rowRect.height - 16
        )
        NSColor(calibratedWhite: 1, alpha: 0.055).setStroke()
        let midline = NSBezierPath()
        midline.move(to: NSPoint(x: waveRect.minX, y: waveRect.midY))
        midline.line(to: NSPoint(x: waveRect.maxX, y: waveRect.midY))
        midline.lineWidth = 1
        midline.stroke()
        drawWaveform(rows[index].overview, in: waveRect, isActive: isActive)
    }

    private func drawWaveform(_ overview: WaveformOverview, in rect: NSRect, isActive: Bool) {
        guard !overview.bins.isEmpty, rect.width > 1, rect.height > 1 else {
            return
        }

        let bins = overview.bins
        let height = rect.height * 0.44
        let midY = rect.midY
        let path = NSBezierPath()
        for index in bins.indices {
            let x = rect.minX + CGFloat(index) / CGFloat(max(bins.count - 1, 1)) * rect.width
            let y = midY + CGFloat(bins[index].maximumSample) * height
            if index == bins.startIndex {
                path.move(to: NSPoint(x: x, y: y))
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }
        for index in bins.indices.reversed() {
            let x = rect.minX + CGFloat(index) / CGFloat(max(bins.count - 1, 1)) * rect.width
            let y = midY + CGFloat(bins[index].minimumSample) * height
            path.line(to: NSPoint(x: x, y: y))
        }
        path.close()
        NSColor(calibratedWhite: 1, alpha: isActive ? 0.72 : 0.36).setFill()
        path.fill()
    }

    private func drawPlayhead() {
        let rect = waveformProgressRect
        guard rect.width > 1 else {
            return
        }

        let x = rect.minX + CGFloat(min(max(playheadProgress, 0), 1)) * rect.width
        let glowRect = NSRect(x: x - 2, y: bounds.minY + 2, width: 4, height: bounds.height - 4)
        NSColor(calibratedRed: 0.20, green: 0.90, blue: 1, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: glowRect, xRadius: 2, yRadius: 2).fill()

        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: bounds.minY + 4))
        line.line(to: NSPoint(x: x, y: bounds.maxY - 4))
        line.lineWidth = 1.5
        NSColor(calibratedRed: 0.44, green: 0.98, blue: 1, alpha: 0.95).setStroke()
        line.stroke()
    }

    private static func fastOverview(from buffer: DecodedAudioBuffer, targetBinCount: Int) -> WaveformOverview {
        guard buffer.frameCount > 0, buffer.channelCount > 0 else {
            return WaveformOverview(duration: buffer.duration, bins: [])
        }

        let binCount = min(max(targetBinCount, 1), buffer.frameCount)
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount)
        for binIndex in 0..<binCount {
            let startFrame = binIndex * buffer.frameCount / binCount
            let endFrame = max((binIndex + 1) * buffer.frameCount / binCount, startFrame + 1)
            let frameSpan = max(endFrame - startFrame, 1)
            let sampledCount = min(frameSpan, 96)
            var accumulator = WaveformBinAccumulator()
            for sampleIndex in 0..<sampledCount {
                let frameIndex = startFrame + sampleIndex * frameSpan / sampledCount
                var mixedSample: Float = 0
                var mixedChannelCount: Float = 0
                for channelSamples in buffer.samplesByChannel where frameIndex < channelSamples.count {
                    mixedSample += channelSamples[frameIndex]
                    mixedChannelCount += 1
                }
                accumulator.addSample(mixedChannelCount > 0 ? mixedSample / mixedChannelCount : 0)
            }
            bins.append(accumulator.makeBin())
        }
        return WaveformOverview(duration: buffer.duration, bins: bins)
    }
}

private final class StemReviewIconButton: NSControl {
    enum Kind {
        case accept
        case reject
    }

    private let kind: Kind
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var isPressed = false {
        didSet { needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        kind = .reject
        super.init(coder: coder)
        configure()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let shouldSend = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if shouldSend {
            sendAction(action, to: target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.5, yRadius: rect.height * 0.5)
        switch kind {
        case .accept:
            NSColor(
                calibratedRed: isPressed ? 0.05 : (isHovered ? 0.18 : 0.10),
                green: isPressed ? 0.70 : (isHovered ? 0.98 : 0.86),
                blue: isPressed ? 0.82 : (isHovered ? 1.0 : 0.96),
                alpha: 1
            ).setFill()
        case .reject:
            NSColor(calibratedWhite: isPressed ? 0.20 : (isHovered ? 0.30 : 0.24), alpha: 1).setFill()
        }
        path.fill()

        NSColor.white.setStroke()
        let icon = NSBezierPath()
        icon.lineCapStyle = .round
        icon.lineJoinStyle = .round
        icon.lineWidth = 2.4
        switch kind {
        case .accept:
            icon.move(to: NSPoint(x: rect.midX - 8, y: rect.midY - 1))
            icon.line(to: NSPoint(x: rect.midX - 2, y: rect.midY - 7))
            icon.line(to: NSPoint(x: rect.midX + 9, y: rect.midY + 7))
        case .reject:
            icon.move(to: NSPoint(x: rect.midX - 7, y: rect.midY - 7))
            icon.line(to: NSPoint(x: rect.midX + 7, y: rect.midY + 7))
            icon.move(to: NSPoint(x: rect.midX + 7, y: rect.midY - 7))
            icon.line(to: NSPoint(x: rect.midX - 7, y: rect.midY + 7))
        }
        icon.stroke()
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }
}

private final class StemReviewPlayPauseButton: NSControl {
    var isPlaying = false {
        didSet { needsDisplay = true }
    }

    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var isPressed = false {
        didSet { needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let shouldSend = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if shouldSend {
            sendAction(action, to: target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let radius = rect.height * 0.5
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor(
            calibratedRed: isPressed ? 0.07 : (isHovered ? 0.13 : 0.09),
            green: isPressed ? 0.68 : (isHovered ? 0.94 : 0.82),
            blue: isPressed ? 0.80 : (isHovered ? 1.0 : 0.94),
            alpha: isPlaying ? 1.0 : 0.88
        ).setFill()
        path.fill()

        NSColor.white.setFill()
        if isPlaying {
            let barWidth = rect.width * 0.11
            let barHeight = rect.height * 0.36
            let gap = rect.width * 0.09
            NSBezierPath(roundedRect: NSRect(x: rect.midX - gap * 0.5 - barWidth, y: rect.midY - barHeight * 0.5, width: barWidth, height: barHeight), xRadius: 1.5, yRadius: 1.5).fill()
            NSBezierPath(roundedRect: NSRect(x: rect.midX + gap * 0.5, y: rect.midY - barHeight * 0.5, width: barWidth, height: barHeight), xRadius: 1.5, yRadius: 1.5).fill()
        } else {
            let icon = NSBezierPath()
            let size = rect.height * 0.34
            icon.move(to: NSPoint(x: rect.midX - size * 0.32, y: rect.midY - size * 0.58))
            icon.line(to: NSPoint(x: rect.midX - size * 0.32, y: rect.midY + size * 0.58))
            icon.line(to: NSPoint(x: rect.midX + size * 0.62, y: rect.midY))
            icon.close()
            icon.fill()
        }
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }
}

private final class StemSeparationPreviewPlayer {
    private let engine = AVAudioEngine()
    private lazy var sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
        self?.render(frameCount: Int(frameCount), audioBufferList: audioBufferList) ?? noErr
    }
    private var isSourceNodeAttached = false
    private var items: [StemSeparationPreviewItem] = []
    private let stateLock = NSLock()
    private var readFrame = 0
    private var activeIndexStorage = 0
    private(set) var isPlaying = false

    var activeIndex: Int {
        get {
            stateLock.lock()
            let index = activeIndexStorage
            stateLock.unlock()
            return index
        }
        set {
            stateLock.lock()
            activeIndexStorage = min(max(newValue, 0), max(items.count - 1, 0))
            stateLock.unlock()
        }
    }

    init() {
        engine.mainMixerNode.outputVolume = 1
    }

    func load(items: [StemSeparationPreviewItem]) throws {
        stop()
        self.items = items
        guard let firstBuffer = items.first?.buffer else {
            throw PlaybackError.noAudioLoaded
        }
        let format = try playbackFormat(for: firstBuffer)
        if !isSourceNodeAttached {
            engine.attach(sourceNode)
            isSourceNodeAttached = true
        }
        engine.disconnectNodeOutput(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        stateLock.lock()
        readFrame = 0
        activeIndexStorage = min(1, max(items.count - 1, 0))
        isPlaying = false
        stateLock.unlock()
        if !engine.isRunning {
            try engine.start()
        }
    }

    func play() {
        guard !items.isEmpty else {
            return
        }
        if !engine.isRunning {
            try? engine.start()
        }
        stateLock.lock()
        if readFrame >= sharedFrameCount {
            readFrame = 0
        }
        isPlaying = true
        stateLock.unlock()
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func pause() {
        stateLock.lock()
        isPlaying = false
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        isPlaying = false
        readFrame = 0
        stateLock.unlock()
        engine.stop()
    }

    func seek(to progress: Float) {
        let frameCount = sharedFrameCount
        guard frameCount > 0 else {
            return
        }
        let frame = min(max(Int(Float(frameCount) * min(max(progress, 0), 1)), 0), frameCount)
        stateLock.lock()
        readFrame = frame
        stateLock.unlock()
    }

    func snapshot() -> PlaybackSnapshot {
        guard sharedFrameCount > 0 else {
            return PlaybackSnapshot(frameIndex: 0, frameCount: 0, isPlaying: false, hostTimestamp: CACurrentMediaTime())
        }
        let now = CACurrentMediaTime()
        stateLock.lock()
        let frameIndex = min(max(readFrame, 0), sharedFrameCount)
        let playing = isPlaying
        stateLock.unlock()
        return PlaybackSnapshot(
            frameIndex: frameIndex,
            frameCount: sharedFrameCount,
            isPlaying: playing,
            hostTimestamp: now
        )
    }

    private var activeBuffer: DecodedAudioBuffer? {
        stateLock.lock()
        let index = activeIndexStorage
        stateLock.unlock()
        guard items.indices.contains(index) else {
            return nil
        }
        return items[index].buffer
    }

    private var sharedFrameCount: Int {
        items.map(\.buffer.frameCount).min() ?? 0
    }

    private func render(frameCount requestedFrameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard requestedFrameCount > 0 else {
            return noErr
        }

        stateLock.lock()
        let localIsPlaying = isPlaying
        let localIndex = activeIndexStorage
        let startFrame = readFrame
        let frameLimit = sharedFrameCount
        stateLock.unlock()

        guard
            localIsPlaying,
            frameLimit > 0,
            items.indices.contains(localIndex)
        else {
            clear(outputBuffers: outputBuffers, frameCount: requestedFrameCount)
            return noErr
        }

        let sourceBuffer = items[localIndex].buffer
        for outputChannelIndex in 0..<outputBuffers.count {
            let outputBuffer = outputBuffers[outputChannelIndex]
            guard let outputPointer = outputBuffer.mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }

            let sourceChannelIndex = sourceBuffer.channelCount == 1 ?
                0 :
                min(outputChannelIndex, max(sourceBuffer.channelCount - 1, 0))
            let sourceSamples = sourceBuffer.samplesByChannel.indices.contains(sourceChannelIndex) ?
                sourceBuffer.samplesByChannel[sourceChannelIndex] :
                []

            for frameOffset in 0..<requestedFrameCount {
                let frame = startFrame + frameOffset
                outputPointer[frameOffset] =
                    frame < frameLimit && frame < sourceSamples.count ? sourceSamples[frame] : 0
            }
        }

        stateLock.lock()
        readFrame = min(startFrame + requestedFrameCount, frameLimit)
        if readFrame >= frameLimit {
            isPlaying = false
        }
        stateLock.unlock()
        return noErr
    }

    private func clear(outputBuffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        for outputBuffer in outputBuffers {
            guard let pointer = outputBuffer.mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            pointer.update(repeating: 0, count: frameCount)
        }
    }

    private func playbackFormat(for buffer: DecodedAudioBuffer) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.sampleRate,
            channels: AVAudioChannelCount(max(buffer.channelCount, 1)),
            interleaved: false
        ) else {
            throw PlaybackError.invalidFormat
        }
        return format
    }
}
