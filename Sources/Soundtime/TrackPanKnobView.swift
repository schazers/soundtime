import AppKit

private enum TrackPanKnobGeometry {
    static let maximumSweep = CGFloat.pi * 0.72
    static let dragPointsPerUnit: CGFloat = 52

    static func value(startingAt value: Float, verticalDelta: CGFloat) -> Float {
        min(max(value + Float(verticalDelta / dragPointsPerUnit), -1), 1)
    }

    static func standardAngle(for value: Float) -> CGFloat {
        .pi / 2 - CGFloat(value) * maximumSweep
    }
}

final class TrackPanKnobView: NSControl {
    var isEditing: Bool { isDragging }
    var onEditingBegan: ((Float) -> Void)?
    var onValueChanged: ((Float) -> Void)?
    var onEditingEnded: (() -> Void)?

    var value: Float = 0 {
        didSet {
            let clamped = min(max(value, -1), 1)
            if clamped != value {
                value = clamped
                return
            }
            setAccessibilityValue(accessibilityValueText)
            needsDisplay = true
        }
    }

    private var trackingArea: NSTrackingArea?
    private var dragStartY: CGFloat?
    private var dragStartValue: Float = 0
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isDragging = false { didSet { needsDisplay = true } }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
        toolTip = "Pan"
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.arrow.set()
    }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onEditingBegan?(value)
        if event.modifierFlags.contains(.command) || event.clickCount == 2 {
            setValue(0, notify: true)
            onEditingEnded?()
            return
        }
        dragStartY = event.locationInWindow.y
        dragStartValue = value
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartY else { return }
        let deltaY = event.locationInWindow.y - dragStartY
        setValue(
            TrackPanKnobGeometry.value(startingAt: dragStartValue, verticalDelta: deltaY),
            notify: true
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartY != nil else { return }
        dragStartY = nil
        isDragging = false
        onEditingEnded?()
    }

    override func keyDown(with event: NSEvent) {
        let coarse: Float = event.modifierFlags.contains(.option) ? 0.01 : 0.05
        switch event.keyCode {
        case 123, 125:
            onEditingBegan?(value)
            setValue(value - coarse, notify: true)
            onEditingEnded?()
        case 124, 126:
            onEditingBegan?(value)
            setValue(value + coarse, notify: true)
            onEditingEnded?()
        case 36, 49, 115:
            onEditingBegan?(value)
            setValue(0, notify: true)
            onEditingEnded?()
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        onEditingBegan?(value)
        setValue(value + 0.02, notify: true)
        onEditingEnded?()
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onEditingBegan?(value)
        setValue(value - 0.02, notify: true)
        onEditingEnded?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let controlSide = min(bounds.width, bounds.height)
        let side = controlSide * 0.65
        let circle = CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
        let active = isHovered || isDragging
        let center = CGPoint(x: circle.midX, y: circle.midY)
        // Keep the widest glow stroke inside the control bounds so AppKit never clips it.
        let arcRadius = controlSide * 0.38
        drawPanArc(in: context, center: center, radius: arcRadius, active: active)

        context.setFillColor(NSColor(white: active ? 0.22 : 0.14, alpha: 1).cgColor)
        context.fillEllipse(in: circle)
        context.setStrokeColor(NSColor(
            red: active ? 0.24 : 0.42,
            green: active ? 0.72 : 0.42,
            blue: active ? 0.76 : 0.44,
            alpha: 1
        ).cgColor)
        context.setLineWidth(active ? 1.5 : 1)
        context.strokeEllipse(in: circle.insetBy(dx: 0.5, dy: 0.5))

        let angle = CGFloat(value) * TrackPanKnobGeometry.maximumSweep
        let radius = side * 0.31
        let end = CGPoint(
            x: center.x + sin(angle) * radius,
            y: center.y + cos(angle) * radius
        )
        context.setStrokeColor(NSColor(white: active ? 0.94 : 0.76, alpha: 1).cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.move(to: center)
        context.addLine(to: end)
        context.strokePath()
    }

    private func drawPanArc(
        in context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        active: Bool
    ) {
        let leftAngle = CGFloat.pi / 2 + TrackPanKnobGeometry.maximumSweep
        let rightAngle = CGFloat.pi / 2 - TrackPanKnobGeometry.maximumSweep

        context.setLineCap(.round)
        context.setStrokeColor(NSColor(white: active ? 0.35 : 0.27, alpha: 0.82).cgColor)
        context.setLineWidth(2.2)
        context.addArc(
            center: center,
            radius: radius,
            startAngle: leftAngle,
            endAngle: rightAngle,
            clockwise: true
        )
        context.strokePath()

        guard abs(value) > 0.002 else { return }
        let endAngle = TrackPanKnobGeometry.standardAngle(for: value)
        let clockwise = value > 0
        let glow = NSColor(
            red: active ? 0.22 : 0.16,
            green: active ? 0.82 : 0.70,
            blue: active ? 0.96 : 0.88,
            alpha: 1
        )

        strokeArc(
            in: context,
            center: center,
            radius: radius,
            endAngle: endAngle,
            clockwise: clockwise,
            color: glow.withAlphaComponent(active ? 0.20 : 0.14),
            width: 7
        )
        strokeArc(
            in: context,
            center: center,
            radius: radius,
            endAngle: endAngle,
            clockwise: clockwise,
            color: glow.withAlphaComponent(active ? 0.48 : 0.34),
            width: 4.2
        )
        strokeArc(
            in: context,
            center: center,
            radius: radius,
            endAngle: endAngle,
            clockwise: clockwise,
            color: glow,
            width: 2.1
        )
    }

    private func strokeArc(
        in context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        endAngle: CGFloat,
        clockwise: Bool,
        color: NSColor,
        width: CGFloat
    ) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.addArc(
            center: center,
            radius: radius,
            startAngle: .pi / 2,
            endAngle: endAngle,
            clockwise: clockwise
        )
        context.strokePath()
    }

    private func setValue(_ nextValue: Float, notify: Bool) {
        let clamped = min(max(nextValue, -1), 1)
        guard abs(clamped - value) > 0.000_1 else { return }
        value = clamped
        if notify { onValueChanged?(clamped) }
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Track pan")
        setAccessibilityHelp("Drag up or down, or use the Arrow keys. Hold Option for fine adjustment. Double-click, Command-click, or press Home to center.")
        setAccessibilityMinValue(-1)
        setAccessibilityMaxValue(1)
        setAccessibilityValue(accessibilityValueText)
    }

    private var accessibilityValueText: String {
        if abs(value) < 0.005 { return "Center" }
        return value < 0 ? "Left \(Int((-value * 100).rounded())) percent" : "Right \(Int((value * 100).rounded())) percent"
    }
}
