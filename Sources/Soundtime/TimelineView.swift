import MetalKit

final class TimelineView: MTKView {
    var onAudioFileDropped: ((URL) -> Void)?

    private var timelineRenderer: TimelineRenderer?
    private let supportedAudioExtensions: Set<String> = [
        "aif",
        "aiff",
        "flac",
        "m4a",
        "mp3",
        "wav",
        "wave",
    ]

    init() {
        let metalDevice = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: metalDevice)
        configure()
        configureRenderer(with: metalDevice)
    }

    required init(coder: NSCoder) {
        let metalDevice = MTLCreateSystemDefaultDevice()
        super.init(coder: coder)
        device = metalDevice
        configure()
        configureRenderer(with: metalDevice)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    private func configure() {
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        framebufferOnly = true
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
        autoResizeDrawable = true

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        registerForDraggedTypes([.fileURL])
    }

    private func configureRenderer(with metalDevice: MTLDevice?) {
        guard let metalDevice else {
            Swift.print("Soundtime could not create a Metal device.")
            return
        }

        do {
            let renderer = try TimelineRenderer(device: metalDevice, pixelFormat: colorPixelFormat)
            timelineRenderer = renderer
            delegate = renderer
        } catch {
            Swift.print("Soundtime could not create the timeline renderer: \\(error)")
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard firstSupportedAudioURL(from: sender.draggingPasteboard) != nil else {
            return []
        }

        setDropHighlightVisible(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlightVisible(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropHighlightVisible(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlightVisible(false)

        guard let url = firstSupportedAudioURL(from: sender.draggingPasteboard) else {
            return false
        }

        onAudioFileDropped?(url)
        return true
    }

    private func firstSupportedAudioURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]

        guard
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        else {
            return nil
        }

        return urls.first { url in
            supportedAudioExtensions.contains(url.pathExtension.lowercased())
        }
    }

    private func setDropHighlightVisible(_ isVisible: Bool) {
        layer?.borderColor = isVisible ? NSColor.systemTeal.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = isVisible ? 2 : 0
    }
}
