import AppKit

final class PerformanceDashboardButton: NSControl {
    var onPressed: (() -> Void)?

    private var isHovered = false {
        didSet {
            needsDisplay = true
        }
    }

    private var trackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool {
        false
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
        let fill = isHovered ?
            NSColor(calibratedRed: 0.12, green: 0.25, blue: 0.27, alpha: 1) :
            NSColor(calibratedWhite: 0.090, alpha: 1)
        fill.setFill()
        path.fill()
        NSColor(calibratedRed: 0.10, green: 0.82, blue: 0.90, alpha: isHovered ? 0.72 : 0.38).setStroke()
        path.lineWidth = 1
        path.stroke()

        let meterRect = rect.insetBy(dx: 8, dy: 8)
        let barWidth = max(meterRect.width / 5, 1.5)
        let heights: [CGFloat] = [0.36, 0.68, 0.50]
        for (index, heightScale) in heights.enumerated() {
            let x = meterRect.minX + CGFloat(index) * barWidth * 1.45
            let barHeight = meterRect.height * heightScale
            let bar = NSRect(
                x: x,
                y: meterRect.minY,
                width: barWidth,
                height: barHeight
            )
            let barPath = NSBezierPath(roundedRect: bar, xRadius: barWidth * 0.5, yRadius: barWidth * 0.5)
            NSColor(calibratedRed: 0.72, green: 0.98, blue: 1.0, alpha: isHovered ? 1.0 : 0.82).setFill()
            barPath.fill()
        }

        let linePath = NSBezierPath()
        linePath.move(to: NSPoint(x: meterRect.minX, y: meterRect.maxY - 2))
        linePath.curve(
            to: NSPoint(x: meterRect.maxX, y: meterRect.midY),
            controlPoint1: NSPoint(x: meterRect.minX + meterRect.width * 0.28, y: meterRect.maxY + 2),
            controlPoint2: NSPoint(x: meterRect.minX + meterRect.width * 0.68, y: meterRect.midY - 4)
        )
        NSColor(calibratedRed: 0.10, green: 0.86, blue: 0.96, alpha: isHovered ? 0.95 : 0.62).setStroke()
        linePath.lineWidth = 1.4
        linePath.stroke()
    }
}
