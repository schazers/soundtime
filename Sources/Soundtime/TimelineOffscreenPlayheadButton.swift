import AppKit
import QuartzCore

final class TimelineOffscreenPlayheadButton: NSButton {
    let direction: TimelineOffscreenPlayheadDirection
    var onActivate: ((TimelineOffscreenPlayheadDirection) -> Void)?

    private let triangleShape = CAShapeLayer()
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false

    init(direction: TimelineOffscreenPlayheadDirection) {
        self.direction = direction
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func layout() {
        super.layout()
        triangleShape.frame = bounds
        triangleShape.path = TimelineOffscreenPlayheadIndicatorGeometry.path(
            direction: direction,
            in: bounds
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        hoverTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateAppearance(animated: true)
        startDirectionPulse()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        stopDirectionPulse()
        updateAppearance(animated: true)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func setPresented(_ isPresented: Bool) {
        guard isHidden == isPresented else {
            return
        }
        isHidden = !isPresented
        if !isPresented {
            stopDirectionPulse()
            isPointerInside = false
            updateAppearance(animated: false)
        }
    }

    private func configure() {
        isBordered = false
        title = ""
        target = self
        action = #selector(activate(_:))
        toolTip = direction == .left ?
            "Reveal playhead to the left" :
            "Reveal playhead to the right"
        setAccessibilityLabel(toolTip ?? "Reveal playhead")
        wantsLayer = true
        layer?.masksToBounds = false
        triangleShape.fillColor = nil
        triangleShape.lineWidth = 0
        layer?.addSublayer(triangleShape)
        isHidden = true
        updateAppearance(animated: false)
    }

    @objc private func activate(_ sender: NSButton) {
        onActivate?(direction)
    }

    private func updateAppearance(animated: Bool) {
        let duration = animated ? 0.06 : 0
        let cyan = NSColor(red: 0.10, green: 0.86, blue: 0.96, alpha: 1)
        let arrowColor = isPointerInside ?
            NSColor(red: 0.60, green: 0.98, blue: 1.0, alpha: 1) : cyan

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        triangleShape.fillColor = arrowColor.cgColor
        triangleShape.shadowColor = arrowColor.cgColor
        triangleShape.shadowOpacity = isPointerInside ? 0.72 : 0.28
        triangleShape.shadowRadius = isPointerInside ? 5 : 2
        triangleShape.shadowOffset = .zero
        CATransaction.commit()
    }

    private func startDirectionPulse() {
        guard isPointerInside,
              triangleShape.animation(forKey: "offscreen-playhead-direction-pulse") == nil else {
            return
        }
        let travel: CGFloat = direction == .left ? -3.5 : 3.5
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, travel, 0]
        animation.keyTimes = [0, 0.40, 1]
        animation.duration = 0.48
        animation.repeatCount = .infinity
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        animation.isRemovedOnCompletion = false
        triangleShape.add(animation, forKey: "offscreen-playhead-direction-pulse")
    }

    private func stopDirectionPulse() {
        triangleShape.removeAnimation(forKey: "offscreen-playhead-direction-pulse")
    }
}

enum TimelineOffscreenPlayheadIndicatorGeometry {
    static func vertices(
        direction: TimelineOffscreenPlayheadDirection,
        in rect: CGRect
    ) -> [CGPoint] {
        let sideLength: CGFloat = 18
        let halfHeight = sideLength * 0.5
        let halfWidth = sideLength * sqrt(3) * 0.25
        let directionSign: CGFloat = direction == .left ? -1 : 1
        let tip = CGPoint(
            x: rect.midX + directionSign * halfWidth,
            y: rect.midY
        )
        let baseX = rect.midX - directionSign * halfWidth
        return [
            CGPoint(x: baseX, y: rect.midY - halfHeight),
            tip,
            CGPoint(x: baseX, y: rect.midY + halfHeight),
        ]
    }

    static func path(
        direction: TimelineOffscreenPlayheadDirection,
        in rect: CGRect
    ) -> CGPath {
        let vertices = vertices(direction: direction, in: rect)
        let path = CGMutablePath()
        path.move(to: vertices[0])
        path.addLine(to: vertices[1])
        path.addLine(to: vertices[2])
        path.closeSubpath()
        return path
    }
}
