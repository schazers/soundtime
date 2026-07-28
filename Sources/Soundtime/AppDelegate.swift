import AppKit
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [MainWindowController] = []
    private weak var openRecentMenu: NSMenu?
    private weak var checkForUpdatesMenuItem: NSMenuItem?
    private let updateCoordinator = ApplicationUpdateCoordinator()
    private lazy var audioPreferencesWindowController = AudioDevicePreferencesWindowController(
        updateService: updateCoordinator.service
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchStartupTrace.shared.mark(.appDelegateDidFinishLaunching)
        configureMainMenu()

        openProjectWindow(restoresLastProject: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
        updateCoordinator.restartBlockersProvider = { [weak self] in
            self?.windowControllers.flatMap { $0.applicationUpdateRestartBlockers() } ?? []
        }
        updateCoordinator.startAfterLaunchSettles()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateCoordinator.applicationWillTerminate()
        let startedAt = CACurrentMediaTime()
        LaunchStartupTrace.shared.mark(
            .appTerminateStarted,
            fields: ["windows": "\(windowControllers.count)"]
        )
        for controller in windowControllers {
            controller.prepareForImmediateWindowClose()
            controller.persistOpenProjectWindowLayout()
        }
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        LaunchStartupTrace.shared.mark(
            .appTerminateFinished,
            fields: [
                "elapsedMs": String(format: "%.2f", elapsedMilliseconds),
                "windows": "\(windowControllers.count)",
                "launchSnapshotWrite": "false",
                "firstFramePacketWrite": "false",
            ]
        )
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: elapsedMilliseconds > 16 ? .warning : .info,
            name: "app-terminate-project-state-persisted",
            message: "Application termination persisted only lightweight launch state synchronously.",
            fields: [
                "elapsedMs": String(format: "%.2f", elapsedMilliseconds),
                "windows": "\(windowControllers.count)",
                "launchSnapshotWrite": "false",
                "firstFramePacketWrite": "false",
            ]
        )
    }

    @objc private func newProject(_ sender: Any?) {
        openProjectWindow(restoresLastProject: false)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func showPreferences(_ sender: Any?) {
        audioPreferencesWindowController.showWindow(sender)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updateCoordinator.checkForUpdates()
    }

    @discardableResult
    private func openProjectWindow(restoresLastProject: Bool) -> MainWindowController {
        let launchPlan = ProjectLaunchCoordinator.resolveLaunchPlan(restoresLastProject: restoresLastProject)
        LaunchStartupTrace.shared.mark(
            .launchPlanResolved,
            fields: launchPlan.diagnosticFields
        )
        let controller = MainWindowController(launchPlan: launchPlan)
        controller.onWindowWillClose = { [weak self, weak controller] closingController in
            guard let controller else {
                return
            }

            self?.windowControllers.removeAll { $0 === closingController || $0 === controller }
        }
        windowControllers.append(controller)
        LaunchStartupTrace.shared.mark(
            .windowShowRequested,
            fields: launchPlan.diagnosticFields
        )
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        if launchPlan.restoresProject, controller.submitDeferredLaunchPreviewRenderIfNeeded() {
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            controller.window?.displayIfNeeded()
        }
        LaunchStartupTrace.shared.mark(
            .windowVisible,
            fields: [
                "restoresLastProject": "\(launchPlan.restoresProject)",
                "isVisible": "\(controller.window?.isVisible == true)",
            ]
        )
        if launchPlan.restoresProject {
            DispatchQueue.main.async { [weak controller] in
                guard let controller else {
                    return
                }

                controller.prepareForDeferredProjectRestore()
                controller.submitDeferredLaunchPreviewRenderIfNeeded()
                controller.restoreLastProjectAfterLaunchPreviewRender()
            }
        }
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
        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)
        checkForUpdatesMenuItem = checkForUpdatesItem
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Open Project...",
            action: #selector(TimelineView.openProject(_:)),
            keyEquivalent: "o"
        ))
        let importAudioItem = NSMenuItem(
            title: "Import Audio File...",
            action: #selector(TimelineView.importAudioFile(_:)),
            keyEquivalent: "i"
        )
        importAudioItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(importAudioItem)
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
        menu.addItem(NSMenuItem(
            title: "Export WAV...",
            action: #selector(TimelineView.exportWAVAudio(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Export Selected Region...",
            action: #selector(TimelineView.exportSelectedRegion(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Export Mixdown Plus Stems...",
            action: #selector(TimelineView.exportMixdownAndStems(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Export Stems...",
            action: #selector(TimelineView.exportStems(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        let hideItem = NSMenuItem(
            title: "Hide Soundtime",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApplication.shared
        menu.addItem(hideItem)
        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApplication.shared
        menu.addItem(hideOthersItem)
        let showAllItem = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApplication.shared
        menu.addItem(showAllItem)
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
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        menu.addItem(NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        menu.addItem(NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        menu.addItem(NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))
        menu.addItem(NSMenuItem(
            title: "Duplicate Region",
            action: #selector(TimelineView.duplicateTimelineRegion(_:)),
            keyEquivalent: "d"
        ))
        menu.addItem(.separator())
        let deleteTimeItem = NSMenuItem(
            title: "Delete Time",
            action: #selector(TimelineView.deleteTimelineSelection(_:)),
            keyEquivalent: "\u{7F}"
        )
        deleteTimeItem.keyEquivalentModifierMask = []
        menu.addItem(deleteTimeItem)
        menu.addItem(NSMenuItem(
            title: "Remove Time Range Across Scope",
            action: #selector(TimelineView.removeTimeRangeAcrossScope(_:)),
            keyEquivalent: ""
        ))

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
            title: "Heal Adjacent Clips",
            action: #selector(TimelineView.healAdjacentClips(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Nudge Selection Left",
            action: #selector(TimelineView.nudgeSelectionLeft(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Nudge Selection Right",
            action: #selector(TimelineView.nudgeSelectionRight(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Slip Clip Contents Left",
            action: #selector(TimelineView.slipClipContentsLeft(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Slip Clip Contents Right",
            action: #selector(TimelineView.slipClipContentsRight(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Snap Selection to Playhead/Edges/Silence",
            action: #selector(TimelineView.snapSelectionToPlayheadEdgesOrSilence(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Select Time Across Linked Tracks",
            action: #selector(TimelineView.selectTimeAcrossLinkedTracks(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Select All Clips on Track",
            action: #selector(TimelineView.selectAllClipsOnTrack(_:)),
            keyEquivalent: ""
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
            title: "Denoise Selection",
            action: #selector(TimelineView.denoiseTimelineSelection(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Separate Music Stems",
            action: #selector(TimelineView.separateMusicStemsTimelineSelection(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Transcribe Selected Track",
            action: #selector(TimelineView.transcribeSelectedTrack(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Show Transcript Layer",
            action: #selector(TimelineView.toggleTranscriptLayer(_:)),
            keyEquivalent: "t"
        ))
        let alignmentDebugItem = NSMenuItem(
            title: "Show Transcript Alignment Debug",
            action: #selector(TimelineView.toggleTranscriptAlignmentDebug(_:)),
            keyEquivalent: "t"
        )
        alignmentDebugItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(alignmentDebugItem)
        menu.addItem(NSMenuItem(
            title: "Delete Transcript Text",
            action: #selector(TimelineView.deleteTranscriptText(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Clear Transcript Text",
            action: #selector(TimelineView.clearTranscriptText(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Split At Transcript Word",
            action: #selector(TimelineView.splitAtTranscriptWord(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
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

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === checkForUpdatesMenuItem {
            return updateCoordinator.service.canCheckForUpdates
        }
        return true
    }
}
