import AppKit

final class TimelinePlaceholderView: NSView {
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor(calibratedWhite: 0.08, alpha: 1.0).setFill()
        bounds.fill()

        drawTimelineGrid()
        drawPlayhead()
        drawEmptyState()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    private func drawTimelineGrid() {
        let gridColor = NSColor(calibratedWhite: 0.24, alpha: 1.0)
        gridColor.setStroke()

        let path = NSBezierPath()
        path.lineWidth = 1

        let majorStep: CGFloat = 96
        var x: CGFloat = 0
        while x <= bounds.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.line(to: CGPoint(x: x, y: bounds.height))
            x += majorStep
        }

        let centerY = bounds.midY
        path.move(to: CGPoint(x: 0, y: centerY))
        path.line(to: CGPoint(x: bounds.width, y: centerY))

        path.stroke()
    }

    private func drawPlayhead() {
        NSColor.systemTeal.setStroke()

        let path = NSBezierPath()
        path.lineWidth = 2
        path.move(to: CGPoint(x: 80, y: 0))
        path.line(to: CGPoint(x: 80, y: bounds.height))
        path.stroke()
    }

    private func drawEmptyState() {
        let message = "Drop audio here"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = message.size(withAttributes: attributes)
        let origin = CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )

        message.draw(at: origin, withAttributes: attributes)
    }
}
