import AppKit
import Metal
import QuartzCore

class TimelineMetalLayerView: NSView {
    let metalDevice: MTLDevice?
    var preferredFramesPerSecond = 60
    var colorPixelFormat: MTLPixelFormat = .bgra8Unorm {
        didSet {
            timelineMetalLayer?.pixelFormat = colorPixelFormat
        }
    }
    var clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
    var framebufferOnly = true {
        didSet {
            timelineMetalLayer?.framebufferOnly = framebufferOnly
        }
    }

    private var backingScale: CGFloat {
        if let windowScale = window?.backingScaleFactor, windowScale > 0 {
            return windowScale
        }

        if let layerScale = layer?.contentsScale, layerScale > 0 {
            return layerScale
        }

        if let screenScale = NSScreen.main?.backingScaleFactor, screenScale > 0 {
            return screenScale
        }

        return 1
    }

    var timelineMetalLayer: CAMetalLayer? {
        layer as? CAMetalLayer
    }

    init(frame frameRect: NSRect = .zero, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        metalDevice = device
        super.init(frame: frameRect)
        configureLayerHosting()
    }

    required init?(coder: NSCoder) {
        metalDevice = MTLCreateSystemDefaultDevice()
        super.init(coder: coder)
        configureLayerHosting()
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        configure(metalLayer: layer)
        return layer
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    func renderTimeline(using renderer: TimelineRenderer?) {
        guard
            let renderer,
            let target = makeRenderTarget()
        else {
            return
        }

        renderer.render(to: target)
    }

    func renderTimeline(using renderer: TimelineRenderer?, frame: TimelineDisplayLinkFrame) {
        guard
            let renderer,
            let target = makeRenderTarget(
                drawable: frame.drawable,
                displayTimestamp: frame.targetPresentationTimestamp
            )
        else {
            return
        }

        renderer.render(to: target)
    }

    private func configureLayerHosting() {
        wantsLayer = true
        configure(metalLayer: timelineMetalLayer)
        updateDrawableSize()
    }

    private func configure(metalLayer: CAMetalLayer?) {
        guard let metalLayer else {
            return
        }

        metalLayer.device = metalDevice
        metalLayer.pixelFormat = colorPixelFormat
        metalLayer.framebufferOnly = framebufferOnly
        metalLayer.isOpaque = true
        metalLayer.presentsWithTransaction = false
        metalLayer.displaySyncEnabled = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.contentsScale = backingScale
    }

    private func makeRenderTarget() -> TimelineRenderTarget? {
        guard
            bounds.width > 0,
            bounds.height > 0,
            let metalLayer = timelineMetalLayer
        else {
            return nil
        }

        updateDrawableSize()
        guard let drawable = metalLayer.nextDrawable() else {
            return nil
        }

        return makeRenderTarget(drawable: drawable, displayTimestamp: CACurrentMediaTime())
    }

    private func makeRenderTarget(
        drawable: CAMetalDrawable,
        displayTimestamp: CFTimeInterval
    ) -> TimelineRenderTarget? {
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = clearColor

        return TimelineRenderTarget(
            renderPassDescriptor: renderPassDescriptor,
            drawable: drawable,
            viewportSize: bounds.size,
            backingScale: Float(backingScale),
            displayTimestamp: displayTimestamp
        )
    }

    private func updateDrawableSize() {
        guard let metalLayer = timelineMetalLayer else {
            return
        }

        let scale = backingScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(bounds.width * scale, 1),
            height: max(bounds.height * scale, 1)
        )
    }
}
