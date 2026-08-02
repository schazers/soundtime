import AppKit

final class TimelineZoomControlsView: NSView {
    var onHorizontalZoomChanged: ((Float) -> Void)?
    var onVerticalZoomChanged: ((Float) -> Void)?
    var onZoomEditingEnded: (() -> Void)?

    private let horizontalSlider = TimelineZoomSlider()
    private let verticalSlider = TimelineZoomSlider()

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

    func display(horizontal: Float, vertical: Float) {
        horizontalSlider.displayValue(horizontal)
        verticalSlider.displayValue(vertical)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.92).cgColor
        layer?.borderColor = NSColor(white: 0.28, alpha: 0.7).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6

        let horizontalRow = makeRow(
            symbolName: "arrow.left.and.right",
            tooltip: "Horizontal timeline zoom",
            slider: horizontalSlider
        )
        let verticalRow = makeRow(
            symbolName: "arrow.up.and.down",
            tooltip: "Vertical track zoom",
            slider: verticalSlider
        )
        let stack = NSStackView(views: [horizontalRow, verticalRow])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        horizontalSlider.onValueChanged = { [weak self] value in
            self?.onHorizontalZoomChanged?(value)
        }
        verticalSlider.onValueChanged = { [weak self] value in
            self?.onVerticalZoomChanged?(value)
        }
        horizontalSlider.onEditingEnded = { [weak self] in
            self?.onZoomEditingEnded?()
        }
        verticalSlider.onEditingEnded = { [weak self] in
            self?.onZoomEditingEnded?()
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    private func makeRow(symbolName: String, tooltip: String, slider: TimelineZoomSlider) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        icon.contentTintColor = NSColor(white: 0.72, alpha: 1)
        icon.toolTip = tooltip
        icon.translatesAutoresizingMaskIntoConstraints = false
        slider.toolTip = tooltip
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setAccessibilityLabel(tooltip)

        let row = NSStackView(views: [icon, slider])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            slider.widthAnchor.constraint(equalToConstant: 92),
            slider.heightAnchor.constraint(equalToConstant: 18),
        ])
        return row
    }
}

private final class TimelineZoomSlider: NSView {
    var onValueChanged: ((Float) -> Void)?
    var onEditingEnded: (() -> Void)?

    private var value: Float = 0
    private var isDragging = false
    private var isPointerNearKnob = false
    private var trackingArea: NSTrackingArea?
    private var hoverAmount: CGFloat = 0
    private var hoverSource: CGFloat = 0
    private var hoverTarget: CGFloat = 0
    private var hoverStartTime = CACurrentMediaTime()
    private let hoverDuration: CFTimeInterval = 0.06
    private var hoverTimer: Timer?

    override var acceptsFirstResponder: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var isFlipped: Bool {
        true
    }

    func displayValue(_ value: Float) {
        let nextValue = min(max(value, 0), 1)
        guard self.value != nextValue else {
            return
        }
        self.value = nextValue
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        trackingArea = nextTrackingArea
        addTrackingArea(nextTrackingArea)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(knobRect.insetBy(dx: -5, dy: -4), cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        updatePointerState(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointerState(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else {
            return
        }
        isPointerNearKnob = false
        transitionHover(to: 0)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDragging = true
        transitionHover(to: 1)
        updateValue(at: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else {
            return
        }
        updateValue(at: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else {
            return
        }
        updateValue(at: convert(event.locationInWindow, from: nil).x)
        isDragging = false
        onEditingEnded?()
        updatePointerState(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        let step: Float
        switch event.keyCode {
        case 123:
            step = -0.02
        case 124:
            step = 0.02
        default:
            super.keyDown(with: event)
            return
        }
        setValue(value + step, publishes: true)
        transitionHover(to: 1)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 123 || event.keyCode == 124 {
            onEditingEnded?()
            transitionHover(to: isPointerNearKnob ? 1 : 0)
        } else {
            super.keyUp(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if isDragging {
            isDragging = false
            onEditingEnded?()
        }
        transitionHover(to: 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let railRect = NSRect(x: 7, y: bounds.midY - 2, width: max(bounds.width - 14, 1), height: 4)
        let railPath = NSBezierPath(roundedRect: railRect, xRadius: 2, yRadius: 2)
        NSColor(white: 0.20, alpha: 1).setFill()
        railPath.fill()

        let fillWidth = max(knobRect.midX - railRect.minX, 2)
        let fillRect = NSRect(x: railRect.minX, y: railRect.minY, width: fillWidth, height: railRect.height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2)
        blendedColor(
            from: NSColor(white: 0.61, alpha: 1),
            to: NSColor(red: 0.23, green: 0.53, blue: 0.55, alpha: 1)
        ).setFill()
        fillPath.fill()

        let knobPath = NSBezierPath(ovalIn: knobRect)
        blendedColor(
            from: NSColor(white: 0.76, alpha: 1),
            to: NSColor(red: 0.30, green: 0.62, blue: 0.64, alpha: 1)
        ).setFill()
        knobPath.fill()
        NSColor(white: 1, alpha: 0.16 + hoverAmount * 0.16).setStroke()
        knobPath.lineWidth = 1
        knobPath.stroke()
    }

    private var knobRect: NSRect {
        let diameter: CGFloat = 14
        let travel = max(bounds.width - diameter, 1)
        return NSRect(
            x: CGFloat(value) * travel,
            y: bounds.midY - diameter * 0.5,
            width: diameter,
            height: diameter
        )
    }

    private func updatePointerState(at point: NSPoint) {
        let nextIsNear = knobRect.insetBy(dx: -7, dy: -5).contains(point)
        guard nextIsNear != isPointerNearKnob || isDragging else {
            return
        }
        isPointerNearKnob = nextIsNear
        transitionHover(to: nextIsNear || isDragging ? 1 : 0)
    }

    private func updateValue(at x: CGFloat) {
        let diameter: CGFloat = 14
        let travel = max(bounds.width - diameter, 1)
        setValue(Float((x - diameter * 0.5) / travel), publishes: true)
    }

    private func setValue(_ value: Float, publishes: Bool) {
        let nextValue = min(max(value, 0), 1)
        guard self.value != nextValue else {
            return
        }
        self.value = nextValue
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        if publishes {
            onValueChanged?(nextValue)
        }
    }

    private func transitionHover(to target: CGFloat) {
        let now = CACurrentMediaTime()
        hoverAmount = currentHoverAmount(at: now)
        hoverSource = hoverAmount
        hoverTarget = min(max(target, 0), 1)
        hoverStartTime = now
        hoverTimer?.invalidate()
        guard abs(hoverTarget - hoverAmount) > 0.001 else {
            hoverAmount = hoverTarget
            needsDisplay = true
            return
        }
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceHoverTransition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func currentHoverAmount(at timestamp: CFTimeInterval) -> CGFloat {
        let progress = CGFloat(min(max((timestamp - hoverStartTime) / hoverDuration, 0), 1))
        let eased = progress < 0.5
            ? 4 * progress * progress * progress
            : 1 - pow(-2 * progress + 2, 3) * 0.5
        return hoverSource + (hoverTarget - hoverSource) * eased
    }

    private func advanceHoverTransition() {
        hoverAmount = currentHoverAmount(at: CACurrentMediaTime())
        needsDisplay = true
        if abs(hoverAmount - hoverTarget) < 0.001 {
            hoverAmount = hoverTarget
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    private func blendedColor(from: NSColor, to: NSColor) -> NSColor {
        from.blended(withFraction: hoverAmount, of: to) ?? to
    }
}
