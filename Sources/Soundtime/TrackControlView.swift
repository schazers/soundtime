import AppKit

final class TrackControlView: NSView {
    var onMuteChanged: ((Bool) -> Void)?
    var onSoloChanged: ((Bool) -> Void)?
    var onVolumeChanged: ((Float) -> Void)?
    var onVolumeEditingEnded: (() -> Void)?
    var onTrackSelected: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let volumeSlider = VerticalTrackVolumeSliderView()
    private let muteButton = TrackToggleButton(title: "M")
    private let soloButton = TrackToggleButton(title: "S")
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

        if hitView === titleLabel || hitView === buttonStack {
            return self
        }

        return hitView
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onTrackSelected?()
    }

    private func configure() {
        wantsLayer = true
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
        muteButton.onSelectedChanged = { [weak self] isSelected in
            self?.isMuted = isSelected
            self?.onMuteChanged?(isSelected)
        }
        soloButton.onSelectedChanged = { [weak self] isSelected in
            self?.isSoloed = isSelected
            self?.onSoloChanged?(isSelected)
        }

        buttonStack.orientation = .vertical
        buttonStack.alignment = .centerX
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.addArrangedSubview(soloButton)
        buttonStack.addArrangedSubview(muteButton)

        addSubview(titleLabel)
        addSubview(volumeSlider)
        addSubview(buttonStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            volumeSlider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            volumeSlider.leadingAnchor.constraint(equalTo: buttonStack.trailingAnchor, constant: 12),
            volumeSlider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            volumeSlider.widthAnchor.constraint(equalToConstant: 24),

            buttonStack.centerYAnchor.constraint(equalTo: volumeSlider.centerYAnchor),
            buttonStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            volumeSlider.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            soloButton.widthAnchor.constraint(equalToConstant: 34),
            soloButton.heightAnchor.constraint(equalToConstant: 28),
            muteButton.widthAnchor.constraint(equalToConstant: 34),
            muteButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func updateAppearance() {
        layer?.backgroundColor = NSColor(white: isTrackSelected ? 0.16 : 0.075, alpha: 1).cgColor
        layer?.borderColor = NSColor(white: isTrackSelected ? 0.46 : 0.17, alpha: 1).cgColor
        layer?.borderWidth = 1
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

private final class VerticalTrackVolumeSliderView: NSView {
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

        let trackWidth: CGFloat = 5
        let trackTop = knobRadius
        let trackBottom = max(bounds.height - knobRadius, trackTop)
        let trackHeight = max(trackBottom - trackTop, 1)
        let trackX = bounds.midX - trackWidth * 0.5
        let trackRect = NSRect(x: trackX, y: trackTop, width: trackWidth, height: trackHeight)
        let knobY = trackTop + CGFloat(value) * trackHeight

        NSColor(white: 0.19, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: trackRect,
            xRadius: trackWidth * 0.5,
            yRadius: trackWidth * 0.5
        ).fill()

        let fillRect = NSRect(
            x: trackX,
            y: trackTop,
            width: trackWidth,
            height: max(knobY - trackTop, 0)
        )
        NSColor(white: 0.82, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: fillRect,
            xRadius: trackWidth * 0.5,
            yRadius: trackWidth * 0.5
        ).fill()

        let knobRect = NSRect(
            x: bounds.midX - knobRadius,
            y: knobY - knobRadius,
            width: knobRadius * 2,
            height: knobRadius * 2
        )
        let knobColor = isDragging || isHovered ? NSColor.white : NSColor(white: 0.86, alpha: 1)
        knobColor.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }

    private func updateValue(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let trackTop = knobRadius
        let trackBottom = max(bounds.height - knobRadius, trackTop)
        let trackHeight = max(trackBottom - trackTop, 1)
        value = Float((point.y - trackTop) / trackHeight)
        onValueChanged?(value)
    }
}
