import AppKit
import AudioToolbox
import AVFoundation
import QuartzCore

final class DenoiseReviewOverlayView: NSView {
    enum PreviewChoice {
        case before
        case after
    }

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
        let label = NSTextField(labelWithString: "Accept Denoise?")
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

    private let rejectButton = DenoiseReviewIconButton(kind: .reject)
    private let acceptButton = DenoiseReviewIconButton(kind: .accept)
    private let playPauseButton = DenoiseReviewPlayPauseButton()
    private let waveformView = DenoiseReviewWaveformView()
    private let previewPlayer = DenoiseReviewPreviewPlayer()

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

    func togglePreviewPlayback() {
        previewPlayer.togglePlayback()
        playPauseButton.isPlaying = previewPlayer.isPlaying
        updatePreviewProgress()
    }

    func show(
        beforeBuffer: DecodedAudioBuffer,
        afterBuffer: DecodedAudioBuffer,
        trackName: String,
        providerSummary: String
    ) throws {
        detailLabel.stringValue = "\(trackName) - \(providerSummary)"
        waveformView.display(beforeBuffer: beforeBuffer, afterBuffer: afterBuffer)
        try previewPlayer.load(beforeBuffer: beforeBuffer, afterBuffer: afterBuffer)
        waveformView.activeChoice = .after
        previewPlayer.activeChoice = .after
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

        waveformView.onChoiceChanged = { [weak self] choice in
            guard let self else {
                return
            }
            previewPlayer.activeChoice = choice
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

        let preferredWidth = panelView.widthAnchor.constraint(equalToConstant: 860)
        preferredWidth.priority = .defaultHigh
        let minimumWidth = panelView.widthAnchor.constraint(greaterThanOrEqualToConstant: 560)
        minimumWidth.priority = .defaultLow
        let preferredHeight = panelView.heightAnchor.constraint(equalToConstant: 430)
        preferredHeight.priority = .defaultHigh
        let minimumHeight = panelView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)
        minimumHeight.priority = .defaultLow

        NSLayoutConstraint.activate([
            panelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            panelView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            panelView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -32),
            preferredWidth,
            minimumWidth,
            preferredHeight,
            minimumHeight,

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

private final class DenoiseReviewWaveformView: NSView {
    var onChoiceChanged: ((DenoiseReviewOverlayView.PreviewChoice) -> Void)?
    var onSeekRequested: ((Float) -> Void)?

    var activeChoice = DenoiseReviewOverlayView.PreviewChoice.after {
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

    private var beforeOverview = WaveformOverview(duration: 0, bins: [])
    private var afterOverview = WaveformOverview(duration: 0, bins: [])
    private var hoveredChoice: DenoiseReviewOverlayView.PreviewChoice?
    private var trackingArea: NSTrackingArea?
    private let labelWidth: CGFloat = 112

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
        addCursorRect(labelRect(for: .before), cursor: .pointingHand)
        addCursorRect(labelRect(for: .after), cursor: .pointingHand)
        addCursorRect(rowWaveformHitRect(for: .before), cursor: .pointingHand)
        addCursorRect(rowWaveformHitRect(for: .after), cursor: .pointingHand)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredChoice = nil
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if choice(at: point) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if labelRect(for: .before).contains(point) {
            activeChoice = .before
            onChoiceChanged?(.before)
            return
        }
        if labelRect(for: .after).contains(point) {
            activeChoice = .after
            onChoiceChanged?(.after)
            return
        }
        if let waveformChoice = waveformChoice(at: point) {
            activeChoice = waveformChoice
            onChoiceChanged?(waveformChoice)
            let progressRect = waveformProgressRect
            let progress = Float((point.x - progressRect.minX) / max(progressRect.width, 1))
            onSeekRequested?(min(max(progress, 0), 1))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        bounds.fill()

        drawRow(
            choice: .before,
            overview: beforeOverview,
            rowRect: rowRect(for: .before)
        )
        drawRow(
            choice: .after,
            overview: afterOverview,
            rowRect: rowRect(for: .after)
        )
        drawPlayhead()
    }

    func display(beforeBuffer: DecodedAudioBuffer, afterBuffer: DecodedAudioBuffer) {
        beforeOverview = Self.fastOverview(from: beforeBuffer, targetBinCount: 1_600)
        afterOverview = Self.fastOverview(from: afterBuffer, targetBinCount: 1_600)
        playheadProgress = 0
        needsDisplay = true
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let nextHover = choice(at: point)
        guard hoveredChoice != nextHover else {
            return
        }
        hoveredChoice = nextHover
        needsDisplay = true
    }

    private var waveformRect: NSRect {
        bounds.insetBy(dx: 0, dy: 0).divided(atDistance: labelWidth, from: .minXEdge).remainder
    }

    private var waveformProgressRect: NSRect {
        NSRect(
            x: labelWidth,
            y: 0,
            width: max(bounds.width - labelWidth - 16, 1),
            height: bounds.height
        )
    }

    private func rowRect(for choice: DenoiseReviewOverlayView.PreviewChoice) -> NSRect {
        let gap: CGFloat = 10
        let rowHeight = (bounds.height - gap) * 0.5
        switch choice {
        case .before:
            return NSRect(x: 0, y: rowHeight + gap, width: bounds.width, height: rowHeight)
        case .after:
            return NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight)
        }
    }

    private func labelRect(for choice: DenoiseReviewOverlayView.PreviewChoice) -> NSRect {
        let row = rowRect(for: choice)
        return NSRect(x: row.minX, y: row.minY, width: labelWidth, height: row.height)
    }

    private func rowWaveformHitRect(for choice: DenoiseReviewOverlayView.PreviewChoice) -> NSRect {
        let row = rowRect(for: choice)
        return NSRect(
            x: row.minX + labelWidth,
            y: row.minY,
            width: max(row.width - labelWidth, 0),
            height: row.height
        )
    }

    private func choice(at point: CGPoint) -> DenoiseReviewOverlayView.PreviewChoice? {
        if labelRect(for: .before).contains(point) || rowWaveformHitRect(for: .before).contains(point) {
            return .before
        }
        if labelRect(for: .after).contains(point) || rowWaveformHitRect(for: .after).contains(point) {
            return .after
        }
        return nil
    }

    private func waveformChoice(at point: CGPoint) -> DenoiseReviewOverlayView.PreviewChoice? {
        if rowWaveformHitRect(for: .before).contains(point) {
            return .before
        }
        if rowWaveformHitRect(for: .after).contains(point) {
            return .after
        }
        return nil
    }

    private func drawRow(
        choice: DenoiseReviewOverlayView.PreviewChoice,
        overview: WaveformOverview,
        rowRect: NSRect
    ) {
        let isActive = activeChoice == choice
        let isHovered = hoveredChoice == choice
        let rowPath = NSBezierPath(roundedRect: rowRect, xRadius: 9, yRadius: 9)
        let fillWhite: CGFloat = isActive ? 0.145 : (isHovered ? 0.118 : 0.092)
        NSColor(calibratedWhite: fillWhite, alpha: 1).setFill()
        rowPath.fill()

        let labelRect = labelRect(for: choice)
        let labelText = choice == .before ? "Before" : "After"
        let labelColor = isActive ?
            NSColor(calibratedRed: 0.78, green: 0.98, blue: 1, alpha: 1) :
            NSColor(calibratedWhite: isHovered ? 0.92 : 0.68, alpha: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: labelColor,
            .paragraphStyle: paragraph,
        ]
        let textRect = NSRect(
            x: labelRect.minX + 8,
            y: labelRect.midY - 10,
            width: labelRect.width - 16,
            height: 22
        )
        labelText.draw(in: textRect, withAttributes: attributes)

        let waveRect = NSRect(
            x: rowRect.minX + labelWidth,
            y: rowRect.minY + 12,
            width: rowRect.width - labelWidth - 16,
            height: rowRect.height - 24
        )
        NSColor(calibratedWhite: 1, alpha: 0.055).setStroke()
        let midline = NSBezierPath()
        midline.move(to: NSPoint(x: waveRect.minX, y: waveRect.midY))
        midline.line(to: NSPoint(x: waveRect.maxX, y: waveRect.midY))
        midline.lineWidth = 1
        midline.stroke()

        drawWaveform(overview, in: waveRect, isActive: isActive)
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

        let fillAlpha: CGFloat = isActive ? 0.72 : 0.36
        NSColor(calibratedWhite: 1, alpha: fillAlpha).setFill()
        path.fill()

        let corePath = NSBezierPath()
        for index in bins.indices {
            let x = rect.minX + CGFloat(index) / CGFloat(max(bins.count - 1, 1)) * rect.width
            let rms = CGFloat(bins[index].rmsSample)
            let y = midY + rms * height * 0.42
            if index == bins.startIndex {
                corePath.move(to: NSPoint(x: x, y: y))
            } else {
                corePath.line(to: NSPoint(x: x, y: y))
            }
        }
        for index in bins.indices.reversed() {
            let x = rect.minX + CGFloat(index) / CGFloat(max(bins.count - 1, 1)) * rect.width
            let rms = CGFloat(bins[index].rmsSample)
            let y = midY - rms * height * 0.42
            corePath.line(to: NSPoint(x: x, y: y))
        }
        corePath.close()
        NSColor(calibratedWhite: 1, alpha: isActive ? 0.82 : 0.42).setFill()
        corePath.fill()
    }

    private func drawPlayhead() {
        let waveRect = waveformProgressRect
        guard waveRect.width > 1 else {
            return
        }

        let x = waveRect.minX + CGFloat(min(max(playheadProgress, 0), 1)) * waveRect.width
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

private final class DenoiseReviewIconButton: NSControl {
    enum Kind {
        case reject
        case accept
    }

    private let kind: Kind
    private var isHovered = false {
        didSet {
            needsDisplay = true
        }
    }
    private var isPressed = false {
        didSet {
            needsDisplay = true
        }
    }
    private var trackingArea: NSTrackingArea?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        kind = .reject
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
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

        switch kind {
        case .reject:
            NSColor(calibratedWhite: isPressed ? 0.24 : (isHovered ? 0.31 : 0.25), alpha: 1).setFill()
        case .accept:
            NSColor(
                calibratedRed: isPressed ? 0.07 : (isHovered ? 0.14 : 0.08),
                green: isPressed ? 0.72 : (isHovered ? 0.96 : 0.86),
                blue: isPressed ? 0.82 : (isHovered ? 1.0 : 0.96),
                alpha: 1
            ).setFill()
        }
        path.fill()

        NSColor.white.setStroke()
        let icon = NSBezierPath()
        icon.lineWidth = 2.2
        icon.lineCapStyle = .round
        icon.lineJoinStyle = .round
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let size: CGFloat = 9.5
        switch kind {
        case .reject:
            icon.move(to: NSPoint(x: center.x - size * 0.55, y: center.y - size * 0.55))
            icon.line(to: NSPoint(x: center.x + size * 0.55, y: center.y + size * 0.55))
            icon.move(to: NSPoint(x: center.x + size * 0.55, y: center.y - size * 0.55))
            icon.line(to: NSPoint(x: center.x - size * 0.55, y: center.y + size * 0.55))
        case .accept:
            icon.move(to: NSPoint(x: center.x - size * 0.72, y: center.y - size * 0.02))
            icon.line(to: NSPoint(x: center.x - size * 0.18, y: center.y - size * 0.55))
            icon.line(to: NSPoint(x: center.x + size * 0.76, y: center.y + size * 0.52))
        }
        icon.stroke()
    }
}

private final class DenoiseReviewPlayPauseButton: NSControl {
    var isPlaying = false {
        didSet {
            guard oldValue != isPlaying else {
                return
            }
            needsDisplay = true
        }
    }

    private var isHovered = false {
        didSet {
            needsDisplay = true
        }
    }
    private var isPressed = false {
        didSet {
            needsDisplay = true
        }
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

        let glow = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: radius + 2, yRadius: radius + 2)
        NSColor(
            calibratedRed: 0.20,
            green: 0.92,
            blue: 1.0,
            alpha: isHovered || isPlaying ? 0.18 : 0.08
        ).setStroke()
        glow.lineWidth = 2
        glow.stroke()

        NSColor.white.setFill()
        if isPlaying {
            let barWidth = rect.width * 0.11
            let barHeight = rect.height * 0.36
            let gap = rect.width * 0.09
            let leftBar = NSRect(
                x: rect.midX - gap * 0.5 - barWidth,
                y: rect.midY - barHeight * 0.5,
                width: barWidth,
                height: barHeight
            )
            let rightBar = NSRect(
                x: rect.midX + gap * 0.5,
                y: rect.midY - barHeight * 0.5,
                width: barWidth,
                height: barHeight
            )
            NSBezierPath(roundedRect: leftBar, xRadius: 1.5, yRadius: 1.5).fill()
            NSBezierPath(roundedRect: rightBar, xRadius: 1.5, yRadius: 1.5).fill()
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

private final class DenoiseReviewPreviewPlayer {
    private let engine = AVAudioEngine()
    private lazy var sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
        self?.render(frameCount: Int(frameCount), audioBufferList: audioBufferList) ?? noErr
    }
    private var isSourceNodeAttached = false
    private var beforeBuffer: DecodedAudioBuffer?
    private var afterBuffer: DecodedAudioBuffer?
    private let stateLock = NSLock()
    private var readFrame = 0
    private var activeChoiceStorage = DenoiseReviewOverlayView.PreviewChoice.after
    private(set) var isPlaying = false

    var activeChoice: DenoiseReviewOverlayView.PreviewChoice {
        get {
            stateLock.lock()
            let choice = activeChoiceStorage
            stateLock.unlock()
            return choice
        }
        set {
            stateLock.lock()
            activeChoiceStorage = newValue
            stateLock.unlock()
        }
    }

    init() {
        engine.mainMixerNode.outputVolume = 1
    }

    func load(beforeBuffer: DecodedAudioBuffer, afterBuffer: DecodedAudioBuffer) throws {
        stop()
        self.beforeBuffer = beforeBuffer
        self.afterBuffer = afterBuffer
        let format = try playbackFormat(for: beforeBuffer)
        if !isSourceNodeAttached {
            engine.attach(sourceNode)
            isSourceNodeAttached = true
        }
        engine.disconnectNodeOutput(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        stateLock.lock()
        readFrame = 0
        isPlaying = false
        activeChoiceStorage = .after
        stateLock.unlock()
        if !engine.isRunning {
            try engine.start()
        }
    }

    func play() {
        guard beforeBuffer != nil, afterBuffer != nil else {
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
        guard let buffer = activeBuffer, sharedFrameCount > 0 else {
            return PlaybackSnapshot(frameIndex: 0, frameCount: 0, isPlaying: false, hostTimestamp: CACurrentMediaTime())
        }
        let now = CACurrentMediaTime()
        stateLock.lock()
        let frameIndex = min(max(readFrame, 0), sharedFrameCount)
        let playing = isPlaying
        stateLock.unlock()
        return PlaybackSnapshot(
            frameIndex: frameIndex,
            frameCount: min(buffer.frameCount, sharedFrameCount),
            isPlaying: playing,
            hostTimestamp: now
        )
    }

    private var activeBuffer: DecodedAudioBuffer? {
        switch activeChoice {
        case .before:
            return beforeBuffer
        case .after:
            return afterBuffer
        }
    }

    private var sharedFrameCount: Int {
        min(beforeBuffer?.frameCount ?? 0, afterBuffer?.frameCount ?? 0)
    }

    private func render(frameCount requestedFrameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard requestedFrameCount > 0 else {
            return noErr
        }

        stateLock.lock()
        let localIsPlaying = isPlaying
        let localChoice = activeChoiceStorage
        let startFrame = readFrame
        let frameLimit = sharedFrameCount
        stateLock.unlock()

        guard
            localIsPlaying,
            frameLimit > 0,
            let sourceBuffer = localChoice == .before ? beforeBuffer : afterBuffer
        else {
            clear(outputBuffers: outputBuffers, frameCount: requestedFrameCount)
            return noErr
        }

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

    private func playbackFormat(for buffer: DecodedAudioBuffer) throws -> AVAudioFormat {
        guard
            buffer.sampleRate > 0,
            buffer.channelCount > 0,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.sampleRate,
                channels: AVAudioChannelCount(buffer.channelCount),
                interleaved: false
            )
        else {
            throw PlaybackError.invalidFormat
        }
        return format
    }

    private func clear(outputBuffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        for outputBuffer in outputBuffers {
            guard let outputPointer = outputBuffer.mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            for frameOffset in 0..<frameCount {
                outputPointer[frameOffset] = 0
            }
        }
    }
}
