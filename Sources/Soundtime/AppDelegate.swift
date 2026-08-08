import AppKit
import QuartzCore
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [MainWindowController] = []
    private weak var openRecentMenu: NSMenu?
    private weak var checkForUpdatesMenuItem: NSMenuItem?
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private let updateCoordinator = ApplicationUpdateCoordinator()
    private lazy var audioPreferencesWindowController = AudioDevicePreferencesWindowController(
        updateService: updateCoordinator.service
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchStartupTrace.shared.mark(.appDelegateDidFinishLaunching)
        installGracefulTerminationSignalHandlers()
        SoundtimeProjectStore.removeAutomationArtifactsFromUserHistory()
        configureMainMenu()

        openProjectWindow(restoresLastProject: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
        updateCoordinator.restartBlockersProvider = { [weak self] in
            self?.windowControllers.flatMap { $0.applicationUpdateRestartBlockers() } ?? []
        }
        updateCoordinator.presentationWindowProvider = { [weak self] in
            NSApplication.shared.keyWindow ??
                self?.windowControllers.last?.window
        }
        updateCoordinator.startAfterLaunchSettles()
        offerPreviousDiagnosticsIfNeeded()
    }

    private func installGracefulTerminationSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                NSApplication.shared.terminate(nil)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
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
        SoundtimeDiagnostics.shared.finishSession()
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

        let clipMenuItem = NSMenuItem(title: "Clip", action: nil, keyEquivalent: "")
        mainMenu.addItem(clipMenuItem)
        clipMenuItem.submenu = makeClipMenu()

        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)
        viewMenuItem.submenu = makeViewMenu()

        let effectsMenuItem = NSMenuItem(title: "Effects", action: nil, keyEquivalent: "")
        mainMenu.addItem(effectsMenuItem)
        effectsMenuItem.submenu = makeEffectsMenu()

        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        mainMenu.addItem(helpMenuItem)
        helpMenuItem.submenu = makeHelpMenu()

        NSApplication.shared.mainMenu = mainMenu
    }

    private func makeHelpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        let mark = NSMenuItem(title: "Mark Diagnostic Incident", action: #selector(markDiagnosticIncident(_:)), keyEquivalent: "")
        mark.target = self; menu.addItem(mark)
        let reveal = NSMenuItem(title: "Reveal Logs", action: #selector(revealDiagnosticLogs(_:)), keyEquivalent: "")
        reveal.target = self; menu.addItem(reveal)
        let export = NSMenuItem(title: "Export Diagnostic Bundle...", action: #selector(exportDiagnosticBundle(_:)), keyEquivalent: "")
        export.target = self; menu.addItem(export)
        return menu
    }

    @objc private func markDiagnosticIncident(_ sender: Any?) {
        _ = SoundtimeDiagnostics.shared.markIncident()
    }

    @objc private func revealDiagnosticLogs(_ sender: Any?) {
        NSWorkspace.shared.open(SoundtimeDiagnostics.shared.logsDirectoryURL)
    }

    @objc private func exportDiagnosticBundle(_ sender: Any?) {
        if let url = SoundtimeDiagnostics.shared.exportDiagnosticBundle() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func offerPreviousDiagnosticsIfNeeded() {
        let incompleteSessionIDs = SoundtimeDiagnostics.shared.unacknowledgedIncompleteSessionIDs
        guard let newestIncompleteSessionID = incompleteSessionIDs.first,
              ProcessInfo.processInfo.environment["SOUNDTIME_AUTOMATION"] != "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let alert = NSAlert()
            alert.messageText = "Soundtime did not finish its previous session"
            alert.informativeText = "A diagnostic session is available. Exporting it can help investigate a crash or forced quit."
            alert.addButton(withTitle: "Export Diagnostics")
            alert.addButton(withTitle: "Not Now")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn,
               let url = SoundtimeDiagnostics.shared.exportIncompleteSessionBundle(
                   sessionID: newestIncompleteSessionID
               ) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            for sessionID in incompleteSessionIDs {
                _ = SoundtimeDiagnostics.shared.acknowledgeRecoveryPrompt(for: sessionID)
            }
        }
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
        let redoItem = NSMenuItem(
            title: "Redo",
            action: #selector(TimelineView.redoTimelineEdit(_:)),
            keyEquivalent: "Z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redoItem)
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
            title: "Select Previous Clip",
            action: #selector(TimelineView.selectPreviousClip(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Select Next Clip",
            action: #selector(TimelineView.selectNextClip(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Mute/Unmute Selected Clips",
            action: #selector(TimelineView.toggleSelectedClipMute(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Lock/Unlock Selected Clips",
            action: #selector(TimelineView.toggleSelectedClipLock(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Group Selected Clips",
            action: #selector(TimelineView.groupSelectedClips(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Ungroup Selected Clips",
            action: #selector(TimelineView.ungroupSelectedClips(_:)),
            keyEquivalent: ""
        ))
        let repeatClipsItem = NSMenuItem(
            title: "Repeat Selected Clips",
            action: #selector(TimelineView.repeatSelectedClips(_:)),
            keyEquivalent: "r"
        )
        repeatClipsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(repeatClipsItem)
        menu.addItem(NSMenuItem(
            title: "Crossfade Selected Clips",
            action: #selector(TimelineView.crossfadeSelectedClips(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Snap Clips",
            action: #selector(TimelineView.toggleClipSnapping(_:)),
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
            title: "Select Following Clips on Track",
            action: #selector(TimelineView.selectFollowingClips(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Select Clips in Time Selection",
            action: #selector(TimelineView.selectClipsInTimeSelection(_:)),
            keyEquivalent: ""
        ))
        return menu
    }

    private func makeViewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        let mixerItem = NSMenuItem(
            title: MixerCommandContract.menuTitle,
            action: #selector(WorkspaceView.toggleMixer(_:)),
            keyEquivalent: MixerCommandContract.keyEquivalent
        )
        mixerItem.keyEquivalentModifierMask = MixerCommandContract.keyEquivalentModifierMask
        menu.addItem(mixerItem)
        menu.addItem(.separator())
        let zoomToSelectedRegionItem = NSMenuItem(
            title: "Zoom to Selected Region",
            action: #selector(TimelineView.zoomToSelection(_:)),
            keyEquivalent: "z"
        )
        zoomToSelectedRegionItem.keyEquivalentModifierMask = []
        menu.addItem(zoomToSelectedRegionItem)
        menu.addItem(.separator())
        let automationItem = NSMenuItem(
            title: "Show Track Automation",
            action: #selector(WorkspaceView.toggleTrackAutomation(_:)),
            keyEquivalent: "a"
        )
        automationItem.keyEquivalentModifierMask = []
        menu.addItem(automationItem)
        let pointToolItem = NSMenuItem(
            title: "Automation Point Tool",
            action: #selector(TimelineView.selectAutomationPointTool(_:)),
            keyEquivalent: ""
        )
        menu.addItem(pointToolItem)
        let curveToolItem = NSMenuItem(
            title: "Automation Curve Tool",
            action: #selector(TimelineView.selectAutomationCurveTool(_:)),
            keyEquivalent: "c"
        )
        curveToolItem.keyEquivalentModifierMask = []
        menu.addItem(curveToolItem)
        for (title, action, key) in [
            ("Automation Pencil Tool", #selector(TimelineView.selectAutomationPencilTool(_:)), "p"),
            ("Automation Ramp Tool", #selector(TimelineView.selectAutomationRampTool(_:)), "r"),
            ("Automation Eraser Tool", #selector(TimelineView.selectAutomationEraserTool(_:)), "e"),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.control]
            menu.addItem(item)
        }
        let curvePresets = NSMenu(title: "Automation Curve Preset")
        for (title, action) in [
            ("Linear", #selector(TimelineView.setAutomationCurveLinear(_:))),
            ("Ease In", #selector(TimelineView.setAutomationCurveEaseIn(_:))),
            ("Ease Out", #selector(TimelineView.setAutomationCurveEaseOut(_:))),
            ("S-Curve", #selector(TimelineView.setAutomationCurveSCurve(_:))),
            ("Stepped", #selector(TimelineView.setAutomationCurveStepped(_:))),
        ] {
            curvePresets.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        let curvePresetItem = NSMenuItem(title: "Automation Curve Preset", action: nil, keyEquivalent: "")
        curvePresetItem.submenu = curvePresets
        menu.addItem(curvePresetItem)
        return menu
    }

    private func makeClipMenu() -> NSMenu {
        let menu = NSMenu(title: "Clip")
        menu.addItem(NSMenuItem(
            title: "Relink Missing Media...",
            action: #selector(TimelineView.relinkMissingMedia(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Cancel Media Relink",
            action: #selector(TimelineView.cancelMissingMediaRelink(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        let openInspector = NSMenuItem(
            title: "Open Selected Clip in Track Inspector",
            action: #selector(TimelineView.openSelectedClipInspector(_:)),
            keyEquivalent: "i"
        )
        openInspector.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(openInspector)
        let moveAbove = NSMenuItem(
            title: "Move Selected Clips to Track Above",
            action: #selector(TimelineView.moveSelectedClipsToTrackAbove(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        )
        moveAbove.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(moveAbove)
        let moveBelow = NSMenuItem(
            title: "Move Selected Clips to Track Below",
            action: #selector(TimelineView.moveSelectedClipsToTrackBelow(_:)),
            keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        )
        moveBelow.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(moveBelow)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Split Focused Clip at Playhead",
            action: #selector(TimelineView.splitFocusedClipAtPlayhead(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Trim Focused Clip Start to Playhead",
            action: #selector(TimelineView.trimFocusedClipStartToPlayhead(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Trim Focused Clip End to Playhead",
            action: #selector(TimelineView.trimFocusedClipEndToPlayhead(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Move Focused Clip Earlier",
            action: #selector(TimelineView.moveFocusedClipEarlier(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Move Focused Clip Later",
            action: #selector(TimelineView.moveFocusedClipLater(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Duplicate Focused Clip",
            action: #selector(TimelineView.duplicateFocusedClip(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Rename Focused Clip...",
            action: #selector(TimelineView.renameFocusedClip(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Delete Focused Clip",
            action: #selector(TimelineView.deleteFocusedClip(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Close Clip Inspector",
            action: #selector(TimelineView.closeFocusedClipInspector(_:)),
            keyEquivalent: ""
        ))
        return menu
    }

    private func makeEffectsMenu() -> NSMenu {
        let menu = NSMenu(title: "Effects")

        let reapplyEffectItem = NSMenuItem(
            title: "Reapply last effect",
            action: #selector(TimelineView.reapplyLastEffect(_:)),
            keyEquivalent: "r"
        )
        reapplyEffectItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(reapplyEffectItem)
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
