import QuartzCore

struct TimelineDisplayLinkFrame {
    let drawable: CAMetalDrawable
    let targetTimestamp: CFTimeInterval
    let targetPresentationTimestamp: CFTimeInterval
}

final class TimelineDisplayLink: NSObject, CAMetalDisplayLinkDelegate {
    var onFrame: ((TimelineDisplayLinkFrame) -> Void)?

    private let displayLink: CAMetalDisplayLink
    private var isInvalidated = false

    init(metalLayer: CAMetalLayer, preferredFramesPerSecond: Int) {
        displayLink = CAMetalDisplayLink(metalLayer: metalLayer)
        super.init()

        displayLink.delegate = self
        displayLink.preferredFrameLatency = 1
        updatePreferredFramesPerSecond(preferredFramesPerSecond)
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
    }

    deinit {
        invalidate()
    }

    func updatePreferredFramesPerSecond(_ preferredFramesPerSecond: Int) {
        guard !isInvalidated else {
            return
        }

        let preferred = Float(max(preferredFramesPerSecond, 60))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60,
            maximum: preferred,
            preferred: preferred
        )
    }

    func start() {
        guard !isInvalidated else {
            return
        }

        displayLink.isPaused = false
    }

    func stop() {
        guard !isInvalidated else {
            return
        }

        displayLink.isPaused = true
    }

    func invalidate() {
        guard !isInvalidated else {
            return
        }

        isInvalidated = true
        onFrame = nil
        displayLink.isPaused = true
        displayLink.delegate = nil
        displayLink.invalidate()
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        onFrame?(TimelineDisplayLinkFrame(
            drawable: update.drawable,
            targetTimestamp: update.targetTimestamp,
            targetPresentationTimestamp: update.targetPresentationTimestamp
        ))
    }
}
