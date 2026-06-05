import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private weak var openRecentMenu: NSMenu?

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

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.persistOpenProjectWindowLayout()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: "Soundtime", action: nil, keyEquivalent: "")
        mainMenu.addItem(appMenuItem)
        appMenuItem.submenu = makeApplicationMenu()

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)
        editMenuItem.submenu = makeEditMenu()

        let effectsMenuItem = NSMenuItem(title: "Effects", action: nil, keyEquivalent: "")
        mainMenu.addItem(effectsMenuItem)
        effectsMenuItem.submenu = makeEffectsMenu()

        NSApplication.shared.mainMenu = mainMenu
    }

    private func makeApplicationMenu() -> NSMenu {
        let menu = NSMenu(title: "Soundtime")

        menu.addItem(NSMenuItem(
            title: "Open Project...",
            action: #selector(TimelineView.openProject(_:)),
            keyEquivalent: "o"
        ))
        menu.addItem(makeOpenRecentMenuItem())
        menu.addItem(NSMenuItem(
            title: "Save",
            action: #selector(TimelineView.saveProject(_:)),
            keyEquivalent: "s"
        ))
        let saveAsItem = NSMenuItem(
            title: "Save Project As...",
            action: #selector(TimelineView.saveProjectAs(_:)),
            keyEquivalent: "s"
        )
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(saveAsItem)
        menu.addItem(.separator())
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

    private func makeOpenRecentMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Open Recent")
        submenu.delegate = self
        menuItem.submenu = submenu
        openRecentMenu = submenu
        rebuildOpenRecentMenu(submenu)
        return menuItem
    }

    private func rebuildOpenRecentMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let recentURLs = SoundtimeProjectStore.recentProjectURLs()
        if recentURLs.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Projects", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for url in recentURLs.prefix(SoundtimeProjectStore.maximumRecentProjectCount) {
                let item = NSMenuItem(
                    title: url.deletingPathExtension().lastPathComponent,
                    action: #selector(TimelineView.openRecentProject(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = url
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let clearItem = NSMenuItem(
            title: "Clear Recents",
            action: #selector(TimelineView.clearRecentProjects(_:)),
            keyEquivalent: ""
        )
        clearItem.isEnabled = !recentURLs.isEmpty
        menu.addItem(clearItem)
    }

    private func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")

        menu.addItem(NSMenuItem(
            title: "Undo",
            action: #selector(TimelineView.undoTimelineEdit(_:)),
            keyEquivalent: "z"
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Cut",
            action: #selector(TimelineView.cutTimelineSelection(_:)),
            keyEquivalent: "x"
        ))
        menu.addItem(NSMenuItem(
            title: "Copy",
            action: #selector(TimelineView.copyTimelineSelection(_:)),
            keyEquivalent: "c"
        ))
        menu.addItem(NSMenuItem(
            title: "Paste",
            action: #selector(TimelineView.pasteTimelineAudio(_:)),
            keyEquivalent: "v"
        ))

        return menu
    }

    private func makeEffectsMenu() -> NSMenu {
        let menu = NSMenu(title: "Effects")

        menu.addItem(NSMenuItem(
            title: "Reapply last effect",
            action: #selector(TimelineView.reapplyLastEffect(_:)),
            keyEquivalent: "r"
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Gain...",
            action: #selector(TimelineView.showGainEffect(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Fade In",
            action: #selector(TimelineView.applyFadeInEffect(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Fade Out",
            action: #selector(TimelineView.applyFadeOutEffect(_:)),
            keyEquivalent: ""
        ))

        return menu
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === openRecentMenu {
            rebuildOpenRecentMenu(menu)
        }
    }
}
