import AppKit
import QuartzCore

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private static let fallbackContentSize = NSSize(width: 1104, height: 460)
    private static let launchAspectRatio: CGFloat = 2.4
    private static let launchScreenAreaFraction: CGFloat = 0.245
    private static let screenInset: CGFloat = 48
    var onWindowWillClose: ((MainWindowController) -> Void)?

    convenience init(restoresLastProject: Bool = true) {
        self.init(launchPlan: ProjectLaunchCoordinator.resolveLaunchPlan(restoresLastProject: restoresLastProject))
    }

    convenience init(launchPlan: ProjectLaunchPlan) {
        LaunchStartupTrace.shared.mark(
            .mainWindowControllerInitStart,
            fields: launchPlan.diagnosticFields
        )
        let contentViewController = WorkspaceViewController(
            launchPlan: launchPlan
        )
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
        if let layout = launchPlan.windowLayout {
            applyWindowLayout(layout)
        }
        LaunchStartupTrace.shared.mark(
            .windowFrameChosen,
            fields: [
                "source": launchPlan.windowLayout == nil ? "fallback" : "launch-plan",
                "width": String(format: "%.0f", window.frame.width),
                "height": String(format: "%.0f", window.frame.height),
            ].merging(launchPlan.diagnosticFields) { _, new in new }
        )
        LaunchStartupTrace.shared.mark(
            .mainWindowCreated,
            fields: [
                "restoresLastProject": "\(launchPlan.restoresProject)",
                "initialFirstFrame": "\(launchPlan.firstPaintFrame != nil)",
                "initialTracks": "\(launchPlan.expectedTrackCount)",
                "width": String(format: "%.0f", window.frame.width),
                "height": String(format: "%.0f", window.frame.height),
            ]
        )
    }

    func persistOpenProjectWindowLayout() {
        (window?.contentViewController?.view as? WorkspaceView)?.persistCurrentProjectWindowLayout()
    }

    func prepareForImmediateWindowClose() {
        (window?.contentViewController?.view as? WorkspaceView)?.prepareForImmediateWindowClose()
    }

    func restoreLastProjectIfNeeded() {
        (window?.contentViewController?.view as? WorkspaceView)?.restoreLastProjectIfNeeded()
    }

    func restoreLastProjectAfterLaunchPreviewRender() {
        (window?.contentViewController?.view as? WorkspaceView)?.restoreLastProjectAfterLaunchPreviewRender()
    }

    @discardableResult
    func submitDeferredLaunchPreviewRenderIfNeeded() -> Bool {
        (window?.contentViewController?.view as? WorkspaceView)?
            .submitDeferredLaunchPreviewRenderIfNeeded() ?? false
    }

    func prepareWindowLayoutForDeferredProjectRestore() {
        if applyDeferredProjectWindowLayoutIfAvailable() {
            LaunchStartupTrace.shared.mark(.deferredWindowLayoutApplied)
        }
    }

    func prepareVisualShellForDeferredProjectRestore() {
        (window?.contentViewController?.view as? WorkspaceView)?.prepareVisualShellForDeferredProjectRestore()
    }

    func prepareForDeferredProjectRestore() {
        (window?.contentViewController?.view as? WorkspaceView)?.prepareForDeferredProjectRestore()
    }

    func windowWillClose(_ notification: Notification) {
        let startedAt = CACurrentMediaTime()
        LaunchStartupTrace.shared.mark(.windowCloseRequested)
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: .info,
            name: "project-window-close-requested",
            message: "Project window close started.",
            fields: [:]
        )
        prepareForImmediateWindowClose()
        persistOpenProjectWindowLayout()
        onWindowWillClose?(self)
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        LaunchStartupTrace.shared.mark(
            .windowCloseFinished,
            fields: [
                "elapsedMs": String(format: "%.2f", elapsedMilliseconds),
                "launchSnapshotWrite": "false",
                "firstFramePacketWrite": "false",
            ]
        )
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: elapsedMilliseconds > 16 ? .warning : .info,
            name: "project-window-close-finished",
            message: "Project window close finished its synchronous work.",
            fields: [
                "elapsedMs": String(format: "%.2f", elapsedMilliseconds),
            ]
        )
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
        ProjectLaunchCoordinator.preferredWindowLayoutForLastProject()
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
