import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private static let fallbackContentSize = NSSize(width: 1104, height: 460)
    private static let launchAspectRatio: CGFloat = 2.4
    private static let launchScreenAreaFraction: CGFloat = 0.245
    private static let screenInset: CGFloat = 48
    var onWindowWillClose: ((MainWindowController) -> Void)?

    convenience init(restoresLastProject: Bool = true) {
        LaunchStartupTrace.shared.mark(
            .mainWindowControllerInitStart,
            fields: ["restoresLastProject": "\(restoresLastProject)"]
        )
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
        LaunchStartupTrace.shared.mark(
            .mainWindowCreated,
            fields: [
                "restoresLastProject": "\(restoresLastProject)",
                "width": String(format: "%.0f", window.frame.width),
                "height": String(format: "%.0f", window.frame.height),
            ]
        )
    }

    func persistOpenProjectWindowLayout() {
        (window?.contentViewController?.view as? WorkspaceView)?.persistCurrentProjectWindowLayout()
    }

    func restoreLastProjectIfNeeded() {
        (window?.contentViewController?.view as? WorkspaceView)?.restoreLastProjectIfNeeded()
    }

    func restoreLastProjectAfterLaunchPreviewRender() {
        (window?.contentViewController?.view as? WorkspaceView)?.restoreLastProjectAfterLaunchPreviewRender()
    }

    func prepareForDeferredProjectRestore() {
        if applyDeferredProjectWindowLayoutIfAvailable() {
            LaunchStartupTrace.shared.mark(.deferredWindowLayoutApplied)
        }
        (window?.contentViewController?.view as? WorkspaceView)?.prepareForDeferredProjectRestore()
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

    @discardableResult
    private func applyDeferredProjectWindowLayoutIfAvailable() -> Bool {
        guard let layout = Self.deferredProjectWindowLayout() else {
            return false
        }

        applyWindowLayout(layout)
        return true
    }

    private static func deferredProjectWindowLayout() -> SoundtimeProject.WindowLayout? {
        if
            let lastProjectURL = SoundtimeProjectStore.lastProjectURL(),
            FileManager.default.fileExists(atPath: lastProjectURL.path)
        {
            return SoundtimeProjectStore.rememberedWindowLayout(for: lastProjectURL)
        }

        return nil
    }

    private func applyWindowLayout(_ layout: SoundtimeProject.WindowLayout) {
        guard
            let window,
            layout.x.isFinite,
            layout.y.isFinite,
            layout.width.isFinite,
            layout.height.isFinite,
            layout.width > 0,
            layout.height > 0
        else {
            return
        }

        var frame = NSRect(
            x: CGFloat(layout.x),
            y: CGFloat(layout.y),
            width: CGFloat(layout.width),
            height: CGFloat(layout.height)
        )
        frame.size.width = max(frame.width, window.minSize.width)
        frame.size.height = max(frame.height, window.minSize.height)

        if let visibleFrame = Self.bestVisibleFrame(for: frame, window: window) {
            if frame.width <= visibleFrame.width {
                frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
            } else {
                frame.origin.x = visibleFrame.minX
            }

            if frame.height <= visibleFrame.height {
                frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
            } else {
                frame.origin.y = visibleFrame.maxY - frame.height
            }
        }

        window.setFrame(frame, display: false, animate: false)
    }

    private static func bestVisibleFrame(for frame: NSRect, window: NSWindow) -> NSRect? {
        let intersectingScreen = NSScreen.screens.max { lhs, rhs in
            intersectionArea(lhs.visibleFrame, frame) < intersectionArea(rhs.visibleFrame, frame)
        }
        if let intersectingScreen, intersectingScreen.visibleFrame.intersects(frame) {
            return intersectingScreen.visibleFrame
        }

        return window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return max(intersection.width, 0) * max(intersection.height, 0)
    }

    private static var windowMinWidth: CGFloat {
        200
    }

    private static var windowMinHeight: CGFloat {
        200
    }
}
