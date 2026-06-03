import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()

        let controller = MainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: "Soundtime", action: nil, keyEquivalent: "")
        mainMenu.addItem(appMenuItem)
        appMenuItem.submenu = makeApplicationMenu()

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)
        editMenuItem.submenu = makeEditMenu()

        NSApplication.shared.mainMenu = mainMenu
    }

    private func makeApplicationMenu() -> NSMenu {
        let menu = NSMenu(title: "Soundtime")

        menu.addItem(NSMenuItem(
            title: "Export...",
            action: #selector(TimelineView.exportAudio(_:)),
            keyEquivalent: "e"
        ))
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Soundtime",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)

        return menu
    }

    private func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")

        menu.addItem(NSMenuItem(
            title: "Undo",
            action: #selector(TimelineView.undoTimelineEdit(_:)),
            keyEquivalent: "z"
        ))

        return menu
    }
}
