import AppKit

final class MainWindowController: NSWindowController {
    private static let fallbackLaunchSize = NSSize(width: 1500, height: 920)
    private static let minimumLaunchSize = NSSize(width: 760, height: 460)
    private static let preferredLaunchSize = NSSize(width: 2200, height: 1300)
    private static let screenInset: CGFloat = 48

    convenience init() {
        let contentViewController = WorkspaceViewController()
        let window = NSWindow(
            contentRect: Self.launchContentRect(),
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
        window.center()

        self.init(window: window)
    }

    private static func launchContentRect() -> NSRect {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return NSRect(origin: .zero, size: fallbackLaunchSize)
        }

        let availableWidth = max(visibleFrame.width - screenInset * 2, minimumLaunchSize.width)
        let availableHeight = max(visibleFrame.height - screenInset * 2, minimumLaunchSize.height)
        let launchSize = NSSize(
            width: min(preferredLaunchSize.width, availableWidth),
            height: min(preferredLaunchSize.height, availableHeight)
        )

        return NSRect(origin: .zero, size: launchSize)
    }
}
