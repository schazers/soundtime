import AppKit

final class VolumeControlView: NSView {
    var onVolumeChanged: ((Float) -> Void)?
    var onVolumeEditingEnded: (() -> Void)?

    private let iconView = NSImageView()
    private let sliderView = VolumeSliderView()

    var perceptualVolume: Float {
        get {
            sliderView.value
        }
        set {
            sliderView.value = newValue
        }
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(
            systemSymbolName: "speaker.wave.2.fill",
            accessibilityDescription: "Volume"
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        iconView.contentTintColor = NSColor.secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        sliderView.translatesAutoresizingMaskIntoConstraints = false
        sliderView.onValueChanged = { [weak self] value in
            self?.onVolumeChanged?(value)
        }
        sliderView.onEditingEnded = { [weak self] in
            self?.onVolumeEditingEnded?()
        }

        addSubview(iconView)
        addSubview(sliderView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            sliderView.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            sliderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            sliderView.centerYAnchor.constraint(equalTo: centerYAnchor),
            sliderView.heightAnchor.constraint(equalToConstant: 24),
        ])
    }
}

private final class VolumeSliderView: NSView {
    var onValueChanged: ((Float) -> Void)?
    var onEditingEnded: (() -> Void)?

    var value: Float = 1 {
        didSet {
            let clampedValue = min(max(value, 0), 1)
            if value != clampedValue {
                value = clampedValue
            }
            needsDisplay = true
        }
    }

    private var isHovering = false
    private var isDragging = false
    private var trackingArea: NSTrackingArea?
    private let maximumKnobRadius: CGFloat = 7

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
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
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
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDragging = true
        updateValue(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateValue(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        updateValue(for: event)
        isDragging = false
        needsDisplay = true
        onEditingEnded?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let trackHeight: CGFloat = 5
        let trackLeft = maximumKnobRadius
        let trackRight = max(bounds.width - maximumKnobRadius, trackLeft)
        let trackWidth = max(trackRight - trackLeft, 1)
        let trackY = bounds.midY - trackHeight * 0.5
        let trackRect = NSRect(
            x: trackLeft,
            y: trackY,
            width: trackWidth,
            height: trackHeight
        )
        let knobX = trackLeft + CGFloat(value) * trackWidth

        NSColor(calibratedWhite: 0.28, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: trackRect,
            xRadius: trackHeight * 0.5,
            yRadius: trackHeight * 0.5
        ).fill()

        let filledRect = NSRect(
            x: trackLeft,
            y: trackY,
            width: max(knobX - trackLeft, 0),
            height: trackHeight
        )
        NSColor(calibratedWhite: 0.72, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: filledRect,
            xRadius: trackHeight * 0.5,
            yRadius: trackHeight * 0.5
        ).fill()

        let knobRadius: CGFloat = isDragging ? 6.4 : (isHovering ? 6 : 5.4)
        let knobRect = NSRect(
            x: knobX - knobRadius,
            y: bounds.midY - knobRadius,
            width: knobRadius * 2,
            height: knobRadius * 2
        )

        NSColor(calibratedWhite: 0, alpha: isDragging ? 0.30 : 0.22).setFill()
        NSBezierPath(ovalIn: knobRect.insetBy(dx: -1.5, dy: -1.5)).fill()

        NSColor(calibratedWhite: isDragging || isHovering ? 0.96 : 0.84, alpha: 1).setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }

    private func updateValue(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let trackLeft = maximumKnobRadius
        let trackRight = max(bounds.width - maximumKnobRadius, trackLeft)
        let trackWidth = max(trackRight - trackLeft, 1)
        let nextValue = min(max(Float((point.x - trackLeft) / trackWidth), 0), 1)
        guard abs(nextValue - value) > 0.000_5 else {
            return
        }

        value = nextValue
        onValueChanged?(nextValue)
    }
}
