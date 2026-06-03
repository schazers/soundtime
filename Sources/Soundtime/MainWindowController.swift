import AppKit

final class MainWindowController: NSWindowController {
    private static let fallbackContentSize = NSSize(width: 1200, height: 600)
    private static let launchAspectRatio: CGFloat = 2
    private static let launchScreenAreaFraction: CGFloat = 0.5
    private static let minimumLaunchWidth: CGFloat = 1120
    private static let screenInset: CGFloat = 48

    convenience init() {
        let contentViewController = WorkspaceViewController()
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
        window.minSize = NSSize(width: 760, height: 460)
        window.contentViewController = contentViewController

        if let launchFrame = Self.launchWindowFrame() {
            window.setFrame(launchFrame, display: false)
        } else {
            window.center()
        }

        self.init(window: window)
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

        launchWidth = min(max(launchWidth, min(minimumLaunchWidth, maximumWidth)), maximumWidth)
        launchHeight = min(launchWidth / launchAspectRatio, maximumHeight)

        let launchSize = NSSize(width: launchWidth, height: launchHeight)
        return NSRect(
            x: visibleFrame.midX - launchSize.width * 0.5,
            y: visibleFrame.midY - launchSize.height * 0.5,
            width: launchSize.width,
            height: launchSize.height
        )
    }

    private static var windowMinWidth: CGFloat {
        760
    }

    private static var windowMinHeight: CGFloat {
        460
    }
}
