import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [MainWindowController] = []
    private weak var openRecentMenu: NSMenu?
    private lazy var audioPreferencesWindowController = AudioDevicePreferencesWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()

        openProjectWindow(restoresLastProject: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in windowControllers {
            controller.persistOpenProjectWindowLayout()
        }
    }

    @objc private func newProject(_ sender: Any?) {
        openProjectWindow(restoresLastProject: false)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func showPreferences(_ sender: Any?) {
        audioPreferencesWindowController.showWindow(sender)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @discardableResult
    private func openProjectWindow(restoresLastProject: Bool) -> MainWindowController {
        let controller = MainWindowController(restoresLastProject: restoresLastProject)
        controller.onWindowWillClose = { [weak self, weak controller] closingController in
            guard let controller else {
                return
            }

            self?.windowControllers.removeAll { $0 === closingController || $0 === controller }
        }
        windowControllers.append(controller)
        controller.showWindow(nil)
        return controller
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

        let newProjectItem = NSMenuItem(
            title: "New Project",
            action: #selector(newProject(_:)),
            keyEquivalent: "n"
        )
        newProjectItem.target = self
        menu.addItem(newProjectItem)
        let preferencesItem = NSMenuItem(
            title: "Preferences...",
            action: #selector(showPreferences(_:)),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        menu.addItem(preferencesItem)
        menu.addItem(.separator())
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
        let debugToolsItem = NSMenuItem(
            title: "Show Debug Tools",
            action: #selector(TimelineView.toggleDebugTools(_:)),
            keyEquivalent: "d"
        )
        debugToolsItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(debugToolsItem)
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
        menu.addItem(.separator())
        let deleteTimeItem = NSMenuItem(
            title: "Delete Time",
            action: #selector(TimelineView.deleteTimelineSelection(_:)),
            keyEquivalent: "\u{7F}"
        )
        deleteTimeItem.keyEquivalentModifierMask = []
        menu.addItem(deleteTimeItem)

        let clearSelectionItem = NSMenuItem(
            title: "Clear and Leave Gap",
            action: #selector(TimelineView.clearTimelineSelection(_:)),
            keyEquivalent: "\u{7F}"
        )
        clearSelectionItem.keyEquivalentModifierMask = [.command]
        menu.addItem(clearSelectionItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Split at Playhead",
            action: #selector(TimelineView.splitAtPlayhead(_:)),
            keyEquivalent: "b"
        ))
        menu.addItem(NSMenuItem(
            title: "Insert Silence/Time",
            action: #selector(TimelineView.insertSilenceAtPlayhead(_:)),
            keyEquivalent: "i"
        ))
        menu.addItem(NSMenuItem(
            title: "Zoom to Selection",
            action: #selector(TimelineView.zoomToSelection(_:)),
            keyEquivalent: "j"
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
            title: "Normalize",
            action: #selector(TimelineView.normalizeTimelineSelection(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Review Shorten Silence",
            action: #selector(TimelineView.deleteSilence(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Audition Silence Candidate",
            action: #selector(TimelineView.auditionDeadAirCandidate(_:)),
            keyEquivalent: ""
        ))
        let acceptCandidateItem = NSMenuItem(
            title: "Accept Silence Candidate",
            action: #selector(TimelineView.acceptDeadAirCandidate(_:)),
            keyEquivalent: "\r"
        )
        acceptCandidateItem.keyEquivalentModifierMask = [.command]
        menu.addItem(acceptCandidateItem)
        let acceptHighConfidenceItem = NSMenuItem(
            title: "Accept High-Confidence Silence Candidates",
            action: #selector(TimelineView.acceptHighConfidenceDeadAirCandidates(_:)),
            keyEquivalent: "\r"
        )
        acceptHighConfidenceItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(acceptHighConfidenceItem)
        menu.addItem(NSMenuItem(
            title: "Reject Silence Candidate",
            action: #selector(TimelineView.rejectDeadAirCandidate(_:)),
            keyEquivalent: ""
        ))
        let previousCandidateItem = NSMenuItem(
            title: "Previous Silence Candidate",
            action: #selector(TimelineView.previousDeadAirCandidate(_:)),
            keyEquivalent: "["
        )
        previousCandidateItem.keyEquivalentModifierMask = [.command]
        menu.addItem(previousCandidateItem)
        let nextCandidateItem = NSMenuItem(
            title: "Next Silence Candidate",
            action: #selector(TimelineView.nextDeadAirCandidate(_:)),
            keyEquivalent: "]"
        )
        nextCandidateItem.keyEquivalentModifierMask = [.command]
        menu.addItem(nextCandidateItem)
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
