import AppKit

@MainActor
enum AgentCommandBarSmokeHarness {
    private enum SmokeError: Error, CustomStringConvertible {
        case checkFailed(String)

        var description: String {
            switch self {
            case let .checkFailed(message):
                return message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1_360, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let workspace = WorkspaceView(frame: NSRect(x: 0, y: 0, width: 1_360, height: 760))
        window.contentView = workspace
        window.makeKeyAndOrderFront(nil)
        workspace.layoutSubtreeIfNeeded()
        workspace.needsLayout = true
        workspace.layoutSubtreeIfNeeded()

        let agentBar = try requireValue(
            firstSubview(of: workspace, matching: AgentCommandBarView.self),
            "could not find agent command bar"
        )
        let textView = try requireValue(
            firstSubview(of: agentBar, matching: NSTextView.self),
            "could not find agent text view"
        )

        try require(textView.isEditable, "agent text view is not editable")
        try require(textView.isSelectable, "agent text view is not selectable")
        try require(textView.acceptsFirstResponder, "agent text view does not accept first responder")
        let directFocusSucceeded = window.makeFirstResponder(textView)
        try require(
            directFocusSucceeded && window.firstResponder === textView,
            "window could not make agent text view first responder directly; " +
                "direct result \(directFocusSucceeded) first responder \(String(describing: window.firstResponder))"
        )
        window.makeFirstResponder(workspace)

        let textCenterInAgent = agentBar.convert(NSPoint(x: textView.bounds.midX, y: textView.bounds.midY), from: textView)
        let hitView = agentBar.hitTest(textCenterInAgent)
        let textHitView = textView.hitTest(NSPoint(x: textView.bounds.midX, y: textView.bounds.midY))
        let panelFrame = agentBar.subviews.first?.frame ?? .zero
        try require(
            hitView === textView,
            "agent bar hit-test did not return the text view; got \(String(describing: hitView)); " +
                "text hit \(String(describing: textHitView)); " +
                "agent frame \(agentBar.frame) bounds \(agentBar.bounds) text frame \(textView.frame) " +
                "text bounds \(textView.bounds) panel frame \(panelFrame) click \(textCenterInAgent)"
        )

        let clickPointInWindow = agentBar.convert(textCenterInAgent, to: nil)
        let contentHitView = window.contentView?.hitTest(window.contentView?.convert(clickPointInWindow, from: nil) ?? .zero)
        try require(
            contentHitView === textView,
            "window content hit-test did not return agent text view; got \(String(describing: contentHitView)); " +
                "window point \(clickPointInWindow)"
        )
        window.makeFirstResponder(textView)
        workspace.layoutSubtreeIfNeeded()

        try require(
            window.firstResponder === textView,
            "agent text view did not become first responder; first responder \(String(describing: window.firstResponder))"
        )

        sendKey("a", keyCode: 0, to: window, at: clickPointInWindow)
        try require(textView.string == "a", "agent text view did not receive typed text after click")

        let addTrackButton = try requireValue(
            firstSubview(of: workspace, matching: AddTrackButton.self),
            "could not find add-track button"
        )
        let addTrackCenterInWindow = addTrackButton.convert(
            NSPoint(x: addTrackButton.bounds.midX, y: addTrackButton.bounds.midY),
            to: nil
        )
        let addTrackHitView = window.contentView?.hitTest(
            window.contentView?.convert(addTrackCenterInWindow, from: nil) ?? .zero
        )
        try require(
            addTrackHitView === addTrackButton,
            "add-track button hit-test was stolen; got \(String(describing: addTrackHitView)); " +
                "agent frame \(agentBar.frame) add button frame \(addTrackButton.frame) " +
                "window point \(addTrackCenterInWindow)"
        )

        window.close()
        print("Soundtime agent command bar smoke passed")
    }

    private static func sendKey(_ character: String, keyCode: UInt16, to window: NSWindow, at point: NSPoint) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        )
        if let event {
            window.sendEvent(event)
        }
    }

    private static func firstSubview<T: NSView>(of root: NSView, matching type: T.Type) -> T? {
        if let typed = root as? T {
            return typed
        }

        for subview in root.subviews {
            if let match = firstSubview(of: subview, matching: type) {
                return match
            }
        }

        return nil
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw SmokeError.checkFailed(message)
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw SmokeError.checkFailed(message)
        }
        return value
    }
}
