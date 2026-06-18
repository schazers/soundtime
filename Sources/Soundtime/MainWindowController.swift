import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private static let fallbackContentSize = NSSize(width: 1104, height: 460)
    private static let launchAspectRatio: CGFloat = 2.4
    private static let launchScreenAreaFraction: CGFloat = 0.245
    private static let screenInset: CGFloat = 48
    var onWindowWillClose: ((MainWindowController) -> Void)?

    convenience init(restoresLastProject: Bool = true) {
        let contentViewController = WorkspaceViewController(restoresLastProject: restoresLastProject)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.fallbackContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Soundtime"
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = SoundtimeColors.windowBackground
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = true
        Self.applyWindowSizeLimits(to: window)
        window.contentViewController = contentViewController
        Self.applyWindowSizeLimits(to: window)

        if let launchFrame = Self.launchWindowFrame() {
            window.setFrame(launchFrame, display: false)
        } else {
            window.center()
        }

        self.init(window: window)
        window.delegate = self
    }

    func persistOpenProjectWindowLayout() {
        (window?.contentViewController?.view as? WorkspaceView)?.persistCurrentProjectWindowLayout()
    }

    func restoreLastProjectIfNeeded() {
        (window?.contentViewController?.view as? WorkspaceView)?.restoreLastProjectIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        persistOpenProjectWindowLayout()
        onWindowWillClose?(self)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, Self.windowMinWidth),
            height: max(frameSize.height, Self.windowMinHeight)
        )
    }

    private static func applyWindowSizeLimits(to window: NSWindow) {
        let minimumSize = NSSize(width: windowMinWidth, height: windowMinHeight)
        let maximumSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        window.minSize = minimumSize
        window.contentMinSize = minimumSize
        window.maxSize = maximumSize
        window.contentMaxSize = maximumSize
    }

    private static func launchWindowFrame() -> NSRect? {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return nil
        }

        let screenArea = visibleFrame.width * visibleFrame.height
        let targetArea = screenArea * launchScreenAreaFraction
        let maximumWidth = max(visibleFrame.width - screenInset * 2, windowMinWidth)
        let maximumHeight = max(visibleFrame.height - screenInset * 2, windowMinHeight)

        var launchWidth = sqrt(targetArea * launchAspectRatio)
        var launchHeight = launchWidth / launchAspectRatio

        if launchWidth > maximumWidth {
            launchWidth = maximumWidth
            launchHeight = launchWidth / launchAspectRatio
        }

        if launchHeight > maximumHeight {
            launchHeight = maximumHeight
            launchWidth = launchHeight * launchAspectRatio
        }

        let minimumWidthForAspect = max(windowMinWidth, windowMinHeight * launchAspectRatio)
        if launchWidth < minimumWidthForAspect, minimumWidthForAspect <= maximumWidth {
            launchWidth = minimumWidthForAspect
            launchHeight = launchWidth / launchAspectRatio
        }

        let launchSize = NSSize(width: launchWidth, height: launchHeight)
        return NSRect(
            x: visibleFrame.midX - launchSize.width * 0.5,
            y: visibleFrame.midY - launchSize.height * 0.5,
            width: launchSize.width,
            height: launchSize.height
        )
    }

    private static var windowMinWidth: CGFloat {
        200
    }

    private static var windowMinHeight: CGFloat {
        200
    }
}
