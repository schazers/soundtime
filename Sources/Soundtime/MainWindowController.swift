import AppKit

final class MainWindowController: NSWindowController {
    private static let fallbackContentSize = NSSize(width: 1500, height: 920)
    private static let screenInset: CGFloat = 12

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

        return visibleFrame.insetBy(dx: screenInset, dy: screenInset)
    }
}
