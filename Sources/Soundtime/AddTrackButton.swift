import AppKit

final class AddTrackButton: NSControl {
    var onPressed: (() -> Void)?

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
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            isPressed = false
        }

        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            return
        }

        onPressed?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 1, dy: 1)
        let radius: CGFloat = 6
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let fill: NSColor
        let stroke: NSColor
        let symbol: NSColor

        if isPressed {
            fill = NSColor(white: 0.19, alpha: 1)
            stroke = NSColor(white: 0.52, alpha: 1)
            symbol = NSColor(white: 0.96, alpha: 1)
        } else if isHovered {
            fill = NSColor(white: 0.145, alpha: 1)
            stroke = NSColor(white: 0.38, alpha: 1)
            symbol = NSColor(white: 0.9, alpha: 1)
        } else {
            fill = NSColor(white: 0.09, alpha: 1)
            stroke = NSColor(white: 0.22, alpha: 1)
            symbol = NSColor(white: 0.68, alpha: 1)
        }

        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let armLength = min(bounds.width, bounds.height) * 0.22
        let plusPath = NSBezierPath()
        plusPath.move(to: CGPoint(x: center.x - armLength, y: center.y))
        plusPath.line(to: CGPoint(x: center.x + armLength, y: center.y))
        plusPath.move(to: CGPoint(x: center.x, y: center.y - armLength))
        plusPath.line(to: CGPoint(x: center.x, y: center.y + armLength))
        plusPath.lineCapStyle = .round
        plusPath.lineWidth = 2.2
        symbol.setStroke()
        plusPath.stroke()
    }
}
