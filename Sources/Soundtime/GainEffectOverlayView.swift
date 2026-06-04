import AppKit

@MainActor
final class GainEffectOverlayView: NSView {
    var onGainChanged: ((Double, Float) -> Void)?
    var onConfirm: ((Double, Float) -> Void)?
    var onCancel: (() -> Void)?

    private var currentDecibels: Double = 0

    private let panelView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.layer?.cornerRadius = 8
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.layer?.borderWidth = 1
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Gain")
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let valueLabel: NSTextField = {
        let label = NSTextField(labelWithString: "0.0 dB")
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.alignment = .right
        label.textColor = NSColor.secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let sliderView = GainSliderView()

    private let cancelButton: NSButton = {
        let button = NSButton(title: "Cancel", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let okButton: NSButton = {
        let button = NSButton(title: "OK", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

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

    func show(initialDecibels: Double = 0) {
        currentDecibels = initialDecibels
        sliderView.decibels = initialDecibels
        updateValueLabel()
        isHidden = false
        window?.makeFirstResponder(sliderView)
        onGainChanged?(currentDecibels, Self.linearGain(forDecibels: currentDecibels))
    }

    private func configure() {
        isHidden = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        okButton.target = self
        okButton.action = #selector(confirm)
        sliderView.translatesAutoresizingMaskIntoConstraints = false
        sliderView.onDecibelsChanged = { [weak self] decibels in
            guard let self else {
                return
            }

            currentDecibels = decibels
            updateValueLabel()
            onGainChanged?(decibels, Self.linearGain(forDecibels: decibels))
        }

        addSubview(panelView)
        panelView.addSubview(titleLabel)
        panelView.addSubview(valueLabel)
        panelView.addSubview(sliderView)
        panelView.addSubview(cancelButton)
        panelView.addSubview(okButton)

        NSLayoutConstraint.activate([
            panelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            panelView.widthAnchor.constraint(equalToConstant: 460),
            panelView.heightAnchor.constraint(equalToConstant: 210),

            titleLabel.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 26),
            titleLabel.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 28),

            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -28),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 14),

            sliderView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 28),
            sliderView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 30),
            sliderView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -30),
            sliderView.heightAnchor.constraint(equalToConstant: 46),

            cancelButton.trailingAnchor.constraint(equalTo: okButton.leadingAnchor, constant: -10),
            cancelButton.bottomAnchor.constraint(equalTo: panelView.bottomAnchor, constant: -24),
            cancelButton.widthAnchor.constraint(equalToConstant: 96),

            okButton.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -28),
            okButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            okButton.widthAnchor.constraint(equalToConstant: 86),
        ])
    }

    private func updateValueLabel() {
        valueLabel.stringValue = String(format: "%+.1f dB", currentDecibels)
    }

    @objc private func cancel() {
        isHidden = true
        onCancel?()
    }

    @objc private func confirm() {
        isHidden = true
        onConfirm?(currentDecibels, Self.linearGain(forDecibels: currentDecibels))
    }

    static func linearGain(forDecibels decibels: Double) -> Float {
        Float(pow(10, decibels / 20))
    }
}

@MainActor
private final class GainSliderView: NSView {
    var onDecibelsChanged: ((Double) -> Void)?

    var decibels: Double = 0 {
        didSet {
            decibels = min(max(decibels, Self.minimumDecibels), Self.maximumDecibels)
            needsDisplay = true
        }
    }

    private static let minimumDecibels: Double = -36
    private static let maximumDecibels: Double = 12
    private var isHovering = false
    private var isDragging = false
    private var trackingArea: NSTrackingArea?
    private let maximumKnobRadius: CGFloat = 8

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
        updateDecibels(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateDecibels(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        updateDecibels(for: event)
        isDragging = false
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? 0.5 : 1.0

        switch event.keyCode {
        case 123:
            setDecibels(decibels - step)
        case 124:
            setDecibels(decibels + step)
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let trackHeight: CGFloat = 6
        let trackLeft = maximumKnobRadius
        let trackRight = max(bounds.width - maximumKnobRadius, trackLeft)
        let trackWidth = max(trackRight - trackLeft, 1)
        let trackY = bounds.midY - trackHeight * 0.5
        let trackRect = NSRect(x: trackLeft, y: trackY, width: trackWidth, height: trackHeight)
        let zeroX = trackLeft + CGFloat(normalizedPosition(forDecibels: 0)) * trackWidth
        let knobX = trackLeft + CGFloat(normalizedPosition(forDecibels: decibels)) * trackWidth

        NSColor(calibratedWhite: 0.25, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: trackRect,
            xRadius: trackHeight * 0.5,
            yRadius: trackHeight * 0.5
        ).fill()

        let fillLeft = min(zeroX, knobX)
        let fillRight = max(zeroX, knobX)
        NSColor(calibratedWhite: 0.70, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: fillLeft, y: trackY, width: fillRight - fillLeft, height: trackHeight),
            xRadius: trackHeight * 0.5,
            yRadius: trackHeight * 0.5
        ).fill()

        NSColor(calibratedWhite: 0.42, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: zeroX - 1, y: trackY - 4, width: 2, height: trackHeight + 8),
            xRadius: 1,
            yRadius: 1
        ).fill()

        let knobRadius: CGFloat = isDragging ? 7.2 : (isHovering ? 6.8 : 6.2)
        let knobRect = NSRect(
            x: knobX - knobRadius,
            y: bounds.midY - knobRadius,
            width: knobRadius * 2,
            height: knobRadius * 2
        )

        NSColor(calibratedWhite: 0, alpha: isDragging ? 0.32 : 0.22).setFill()
        NSBezierPath(ovalIn: knobRect.insetBy(dx: -1.5, dy: -1.5)).fill()

        NSColor(calibratedWhite: isDragging || isHovering ? 0.97 : 0.84, alpha: 1).setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }

    private func updateDecibels(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let trackLeft = maximumKnobRadius
        let trackRight = max(bounds.width - maximumKnobRadius, trackLeft)
        let trackWidth = max(trackRight - trackLeft, 1)
        let normalizedPosition = Double((point.x - trackLeft) / trackWidth)
        setDecibels(decibels(forNormalizedPosition: normalizedPosition))
    }

    private func setDecibels(_ nextDecibels: Double) {
        decibels = nextDecibels
        onDecibelsChanged?(decibels)
    }

    private func normalizedPosition(forDecibels decibels: Double) -> Double {
        let clampedDecibels = min(max(decibels, Self.minimumDecibels), Self.maximumDecibels)
        return (clampedDecibels - Self.minimumDecibels) / (Self.maximumDecibels - Self.minimumDecibels)
    }

    private func decibels(forNormalizedPosition normalizedPosition: Double) -> Double {
        let clampedPosition = min(max(normalizedPosition, 0), 1)
        return Self.minimumDecibels + clampedPosition * (Self.maximumDecibels - Self.minimumDecibels)
    }
}
