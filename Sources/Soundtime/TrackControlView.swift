import AppKit

final class TrackControlView: NSView {
    var onMuteChanged: ((Bool) -> Void)?
    var onSoloChanged: ((Bool) -> Void)?
    var onRecordRequested: (() -> Void)?
    var onVolumeChanged: ((Float) -> Void)?
    var onVolumeEditingEnded: (() -> Void)?
    var onTrackSelected: (() -> Void)?

    private let panelView = NSView()
    private let contentStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let volumeSlider = HorizontalTrackVolumeSliderView()
    private let muteButton = TrackToggleButton(title: "M")
    private let soloButton = TrackToggleButton(title: "S")
    private let recordButton = TrackIconButton(systemSymbolName: "mic.fill")
    private let buttonStack = NSStackView()

    var isTrackSelected = false {
        didSet {
            updateAppearance()
        }
    }

    var isMuted = false {
        didSet {
            muteButton.isSelected = isMuted
        }
    }

    var isSoloed = false {
        didSet {
            soloButton.isSelected = isSoloed
        }
    }

    var isRecording = false {
        didSet {
            recordButton.isSelected = isRecording
        }
    }

    var volume: Float {
        get {
            volumeSlider.value
        }
        set {
            volumeSlider.value = newValue
        }
    }

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitView = super.hitTest(point) else {
            return nil
        }

        if hitView === titleLabel ||
            hitView === buttonStack ||
            hitView === contentStack ||
            hitView === panelView
        {
            return self
        }

        return hitView
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onTrackSelected?()
    }

    func configure(
        title: String,
        isMuted: Bool,
        isSoloed: Bool,
        volume: Float,
        isTrackSelected: Bool,
        isRecording: Bool
    ) {
        if titleLabel.stringValue != title {
            titleLabel.stringValue = title
        }
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.volume = volume
        self.isTrackSelected = isTrackSelected
        self.isRecording = isRecording
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        panelView.wantsLayer = true
        panelView.translatesAutoresizingMaskIntoConstraints = false
        updateAppearance()

        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = NSColor(white: 0.78, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.onValueChanged = { [weak self] value in
            self?.onVolumeChanged?(value)
        }
        volumeSlider.onEditingEnded = { [weak self] in
            self?.onVolumeEditingEnded?()
        }

        muteButton.translatesAutoresizingMaskIntoConstraints = false
        soloButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        muteButton.onSelectedChanged = { [weak self] isSelected in
            self?.isMuted = isSelected
            self?.onMuteChanged?(isSelected)
        }
        soloButton.onSelectedChanged = { [weak self] isSelected in
            self?.isSoloed = isSelected
            self?.onSoloChanged?(isSelected)
        }
        recordButton.onPressed = { [weak self] in
            self?.onRecordRequested?()
        }

        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 6
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.addArrangedSubview(soloButton)
        buttonStack.addArrangedSubview(muteButton)
        buttonStack.addArrangedSubview(recordButton)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(volumeSlider)
        contentStack.addArrangedSubview(buttonStack)

        addSubview(panelView)
        panelView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            panelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            panelView.trailingAnchor.constraint(equalTo: trailingAnchor),
            panelView.topAnchor.constraint(equalTo: topAnchor),
            panelView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStack.centerYAnchor.constraint(equalTo: panelView.centerYAnchor),
            contentStack.topAnchor.constraint(greaterThanOrEqualTo: panelView.topAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: panelView.trailingAnchor, constant: -12),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: panelView.bottomAnchor, constant: -8),

            titleLabel.widthAnchor.constraint(equalTo: panelView.widthAnchor, constant: -24),

            volumeSlider.widthAnchor.constraint(equalToConstant: 104),
            volumeSlider.heightAnchor.constraint(equalToConstant: 20),

            soloButton.widthAnchor.constraint(equalToConstant: 31),
            soloButton.heightAnchor.constraint(equalToConstant: 26),
            muteButton.widthAnchor.constraint(equalToConstant: 31),
            muteButton.heightAnchor.constraint(equalToConstant: 26),
            recordButton.widthAnchor.constraint(equalToConstant: 31),
            recordButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func updateAppearance() {
        panelView.layer?.backgroundColor = NSColor(white: isTrackSelected ? 0.16 : 0.075, alpha: 1).cgColor
        panelView.layer?.borderColor = NSColor(white: isTrackSelected ? 0.46 : 0.17, alpha: 1).cgColor
        panelView.layer?.borderWidth = 1
    }
}

private final class TrackIconButton: NSControl {
    var onPressed: (() -> Void)?

    var isSelected = false {
        didSet {
            updateBlinkTimer()
            needsDisplay = true
        }
    }

    private var isHovered = false {
        didSet {
            needsDisplay = true
        }
    }

    private var trackingArea: NSTrackingArea?
    private var blinkTimer: Timer?
    private var showsRecordingFill = true

    init(systemSymbolName: String) {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            blinkTimer?.invalidate()
            blinkTimer = nil
        } else if isSelected, blinkTimer == nil {
            updateBlinkTimer()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = nextTrackingArea
        addTrackingArea(nextTrackingArea)
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

    private func updateBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        showsRecordingFill = true

        guard isSelected else {
            return
        }

        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(toggleRecordingBlink),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    @objc private func toggleRecordingBlink() {
        showsRecordingFill.toggle()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 1, dy: 1)
        let fill: NSColor
        let stroke: NSColor
        let symbolColor: NSColor
        if isSelected {
            if showsRecordingFill {
                fill = NSColor(calibratedRed: 0.84, green: 0.10, blue: 0.12, alpha: 1)
                stroke = NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.36, alpha: 1)
                symbolColor = NSColor.white
            } else {
                fill = NSColor(white: 0.08, alpha: 1)
                stroke = NSColor(calibratedRed: 0.84, green: 0.10, blue: 0.12, alpha: 1)
                symbolColor = NSColor(calibratedRed: 0.96, green: 0.12, blue: 0.14, alpha: 1)
            }
        } else if isHovered {
            fill = NSColor(white: 0.19, alpha: 1)
            stroke = NSColor(white: 0.42, alpha: 1)
            symbolColor = NSColor.white
        } else {
            fill = NSColor(white: 0.12, alpha: 1)
            stroke = NSColor(white: 0.25, alpha: 1)
            symbolColor = NSColor.white
        }

        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let imageSize = CGSize(width: 14, height: 14)
        let imageRect = NSRect(
            x: bounds.midX - imageSize.width * 0.5,
            y: bounds.midY - imageSize.height * 0.5,
            width: imageSize.width,
            height: imageSize.height
        )
        drawMicrophoneIcon(in: imageRect, color: symbolColor)
    }

    private func drawMicrophoneIcon(in rect: NSRect, color: NSColor) {
        color.setFill()
        color.setStroke()

        let capsuleWidth = rect.width * 0.43
        let capsuleHeight = rect.height * 0.58
        let capsuleRect = NSRect(
            x: rect.midX - capsuleWidth * 0.5,
            y: rect.minY + rect.height * 0.34,
            width: capsuleWidth,
            height: capsuleHeight
        )
        NSBezierPath(
            roundedRect: capsuleRect,
            xRadius: capsuleWidth * 0.5,
            yRadius: capsuleWidth * 0.5
        ).fill()

        let stemPath = NSBezierPath()
        stemPath.lineWidth = 1.9
        stemPath.lineCapStyle = .round
        stemPath.move(to: NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.22))
        stemPath.line(to: NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.39))
        stemPath.stroke()

        let basePath = NSBezierPath()
        basePath.lineWidth = 1.9
        basePath.lineCapStyle = .round
        basePath.move(to: NSPoint(x: rect.midX - rect.width * 0.22, y: rect.minY + rect.height * 0.18))
        basePath.line(to: NSPoint(x: rect.midX + rect.width * 0.22, y: rect.minY + rect.height * 0.18))
        basePath.stroke()

        let yokePath = NSBezierPath()
        yokePath.lineWidth = 1.7
        yokePath.lineCapStyle = .round
        yokePath.move(to: NSPoint(x: rect.minX + rect.width * 0.23, y: rect.minY + rect.height * 0.48))
        yokePath.curve(
            to: NSPoint(x: rect.maxX - rect.width * 0.23, y: rect.minY + rect.height * 0.48),
            controlPoint1: NSPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.24),
            controlPoint2: NSPoint(x: rect.maxX - rect.width * 0.25, y: rect.minY + rect.height * 0.24)
        )
        yokePath.stroke()
    }
}

private final class TrackToggleButton: NSControl {
    var onSelectedChanged: ((Bool) -> Void)?

    var isSelected = false {
        didSet {
            needsDisplay = true
        }
    }

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

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = nextTrackingArea
        addTrackingArea(nextTrackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        isSelected.toggle()
        onSelectedChanged?(isSelected)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 1, dy: 1)
        let fill: NSColor
        let stroke: NSColor
        let text: NSColor
        if isSelected {
            fill = NSColor(white: 0.88, alpha: 1)
            stroke = NSColor(white: 0.98, alpha: 1)
            text = NSColor(white: 0.07, alpha: 1)
        } else if isHovered {
            fill = NSColor(white: 0.19, alpha: 1)
            stroke = NSColor(white: 0.42, alpha: 1)
            text = NSColor(white: 0.86, alpha: 1)
        } else {
            fill = NSColor(white: 0.12, alpha: 1)
            stroke = NSColor(white: 0.25, alpha: 1)
            text = NSColor(white: 0.64, alpha: 1)
        }

        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: text,
        ]
        let textSize = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(
                x: bounds.midX - textSize.width * 0.5,
                y: bounds.midY - textSize.height * 0.5 - 0.5
            ),
            withAttributes: attributes
        )
    }
}

private final class HorizontalTrackVolumeSliderView: NSView {
    var value: Float = 1 {
        didSet {
            value = min(max(value, 0), 1)
            needsDisplay = true
        }
    }

    var onValueChanged: ((Float) -> Void)?
    var onEditingEnded: (() -> Void)?

    private var isHovered = false {
        didSet {
            needsDisplay = true
        }
    }

    private var isDragging = false {
        didSet {
            needsDisplay = true
        }
    }

    private var trackingArea: NSTrackingArea?
    private let knobRadius: CGFloat = 7

    override var acceptsFirstResponder: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = nextTrackingArea
        addTrackingArea(nextTrackingArea)
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
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDragging = true
        updateValue(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateValue(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        updateValue(with: event)
        isDragging = false
        onEditingEnded?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let trackHeight: CGFloat = 5
        let trackLeft = knobRadius
        let trackRight = max(bounds.width - knobRadius, trackLeft)
        let trackWidth = max(trackRight - trackLeft, 1)
        let trackY = bounds.midY - trackHeight * 0.5
        let trackRect = NSRect(x: trackLeft, y: trackY, width: trackWidth, height: trackHeight)
        let knobX = trackLeft + CGFloat(value) * trackWidth

        NSColor(white: 0.19, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: trackRect,
            xRadius: trackHeight * 0.5,
            yRadius: trackHeight * 0.5
        ).fill()

        let fillRect = NSRect(
            x: trackLeft,
            y: trackY,
            width: max(knobX - trackLeft, 0),
            height: trackHeight
        )
        NSColor(white: 0.82, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: fillRect,
            xRadius: trackHeight * 0.5,
            yRadius: trackHeight * 0.5
        ).fill()

        let knobRect = NSRect(
            x: knobX - knobRadius,
            y: bounds.midY - knobRadius,
            width: knobRadius * 2,
            height: knobRadius * 2
        )
        let knobColor = isDragging || isHovered ? NSColor.white : NSColor(white: 0.86, alpha: 1)
        knobColor.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }

    private func updateValue(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let trackLeft = knobRadius
        let trackRight = max(bounds.width - knobRadius, trackLeft)
        let trackWidth = max(trackRight - trackLeft, 1)
        value = Float((point.x - trackLeft) / trackWidth)
        onValueChanged?(value)
    }
}
