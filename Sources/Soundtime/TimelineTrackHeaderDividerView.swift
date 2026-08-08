import AppKit

enum TimelineTrackHeaderWidthPolicy {
    static let defaultWidth: CGFloat = 190
    static let minimumWidth: CGFloat = 148
    static let maximumWidth: CGFloat = 420
    static let minimumTimelineWidth: CGFloat = 360
    static let workspaceLeadingInset: CGFloat = 22
    static let workspaceTrailingInset: CGFloat = 12
    static let dividerWidth: CGFloat = 10

    static func sanitizedPreferredWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    static func resolvedWidth(preferredWidth: CGFloat, workspaceWidth: CGFloat) -> CGFloat {
        let preferred = sanitizedPreferredWidth(preferredWidth)
        let maximumAvailableWidth = max(
            minimumWidth,
            workspaceWidth
                - workspaceLeadingInset
                - workspaceTrailingInset
                - dividerWidth
                - minimumTimelineWidth
        )
        return min(preferred, maximumAvailableWidth)
    }
}

final class TimelineTrackHeaderDividerView: NSView {
    var onResizeBegan: (() -> Void)?
    var onResizeChanged: ((CGFloat) -> Void)?
    var onResizeEnded: (() -> Void)?
    var onResizeCancelled: (() -> Void)?
    var onResetRequested: (() -> Void)?
    var onKeyboardAdjustment: ((CGFloat) -> Void)?

    private var mouseDownWindowX: CGFloat?
    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            needsDisplay = true
        }
    }
    private var trackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

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
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        guard mouseDownWindowX == nil else { return }
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            onResetRequested?()
            return
        }
        mouseDownWindowX = event.locationInWindow.x
        isHovered = true
        onResizeBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownWindowX else { return }
        onResizeChanged?(event.locationInWindow.x - mouseDownWindowX)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownWindowX != nil else { return }
        mouseDownWindowX = nil
        onResizeEnded?()
        isHovered = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func cancelOperation(_ sender: Any?) {
        guard mouseDownWindowX != nil else { return }
        mouseDownWindowX = nil
        onResizeCancelled?()
        isHovered = false
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 24 : 8
        switch event.keyCode {
        case 123:
            onKeyboardAdjustment?(-step)
        case 124:
            onKeyboardAdjustment?(step)
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let lineWidth = 1 / max(scale, 1)
        let x = (bounds.midX * scale).rounded() / scale
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.move(to: NSPoint(x: x, y: bounds.minY))
        path.line(to: NSPoint(x: x, y: bounds.maxY))
        let white = isHovered || mouseDownWindowX != nil ? 0.58 : 0.27
        NSColor(white: white, alpha: isHovered ? 0.95 : 0.72).setStroke()
        path.stroke()
    }

    func displayAccessibilityValue(_ width: CGFloat) {
        setAccessibilityValue(Double(width.rounded()))
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Track header width")
        setAccessibilityHelp("Drag horizontally, or use Left and Right Arrow, to resize the track headers.")
        setAccessibilityMinValue(Double(TimelineTrackHeaderWidthPolicy.minimumWidth))
        setAccessibilityMaxValue(Double(TimelineTrackHeaderWidthPolicy.maximumWidth))
        toolTip = "Drag to resize track headers. Double-click to reset."
    }
}
