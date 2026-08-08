import AppKit

/// Retained, GPU-composited presentation for the authored timeline end. Hit
/// testing stays in `TimelineView`, so this view never intercepts interaction.
final class TimelineEndOverlayView: NSView {
    struct HandlePresentationSnapshot {
        let frame: CGRect
        let pathBounds: CGRect
        let fillColor: CGColor?
        let isHidden: Bool
    }

    var markerX: CGFloat? { didSet { updatePresentation() } }
    var rulerHeight: CGFloat = 32 { didSet { updatePresentation() } }
    var dimsEntireViewport = false { didSet { updatePresentation() } }
    var isHandleHovered = false { didSet { updateHandleColor(animated: true) } }

    private let dimLayer = CALayer()
    private let markerLayer = CALayer()
    private let handleLayer = CAShapeLayer()

    static let handleSideLength: CGFloat = 20
    static let handleAltitude: CGFloat = handleSideLength * sqrt(3) / 2
    private static let handleColor = NSColor(calibratedWhite: 0.68, alpha: 0.96).cgColor
    private static let hoveredHandleColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func handlePresentationSnapshotForSmokeTesting() -> HandlePresentationSnapshot {
        HandlePresentationSnapshot(
            frame: handleLayer.frame,
            pathBounds: handleLayer.path?.boundingBox ?? .null,
            fillColor: handleLayer.fillColor,
            isHidden: handleLayer.isHidden
        )
    }

    override func layout() {
        super.layout()
        updatePresentation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        handleLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func commonInit() {
        wantsLayer = true
        guard let layer else { return }
        layer.masksToBounds = true

        dimLayer.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.36).cgColor
        markerLayer.backgroundColor = NSColor(calibratedWhite: 0.82, alpha: 0.78).cgColor
        handleLayer.fillColor = Self.handleColor
        handleLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        layer.addSublayer(dimLayer)
        layer.addSublayer(markerLayer)
        layer.addSublayer(handleLayer)
        updatePresentation()
    }

    private func updateHandleColor(animated: Bool) {
        let color = isHandleHovered ? Self.hoveredHandleColor : Self.handleColor
        guard animated, handleLayer.superlayer != nil else {
            handleLayer.fillColor = color
            return
        }

        let animation = CABasicAnimation(keyPath: "fillColor")
        animation.fromValue = handleLayer.presentation()?.fillColor ?? handleLayer.fillColor
        animation.toValue = color
        animation.duration = 0.06
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        handleLayer.fillColor = color
        handleLayer.add(animation, forKey: "timeline-end-handle-hover")
    }

    private func updatePresentation() {
        guard wantsLayer, bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if dimsEntireViewport {
            dimLayer.isHidden = false
            dimLayer.frame = bounds
            markerLayer.isHidden = true
            handleLayer.isHidden = true
            return
        }

        guard let markerX, markerX.isFinite else {
            dimLayer.isHidden = true
            markerLayer.isHidden = true
            handleLayer.isHidden = true
            return
        }

        let x = min(max(markerX, 0), bounds.width)
        dimLayer.isHidden = x >= bounds.width
        dimLayer.frame = CGRect(x: x, y: 0, width: max(bounds.width - x, 0), height: bounds.height)

        markerLayer.isHidden = false
        markerLayer.frame = CGRect(
            x: x - 0.75,
            y: 0,
            width: 1.5,
            height: max(bounds.height - rulerHeight, 0)
        )

        let handleWidth = Self.handleSideLength
        let handleHeight = Self.handleAltitude
        handleLayer.isHidden = false
        handleLayer.frame = CGRect(
            x: x,
            y: bounds.height - handleHeight,
            width: handleWidth,
            height: handleHeight
        )
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: handleHeight / 2))
        path.addLine(to: CGPoint(x: handleWidth, y: 0))
        path.addLine(to: CGPoint(x: handleWidth, y: handleHeight))
        path.closeSubpath()
        handleLayer.path = path
    }
}
