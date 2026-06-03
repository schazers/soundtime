import AppKit

final class MainWindowController: NSWindowController {
    convenience init() {
        let contentViewController = WorkspaceViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1500, height: 920),
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
}
