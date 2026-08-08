import AppKit

final class WorkspaceBottomPanelHostView: NSView {
    private(set) var mode: WorkspaceBottomPanelMode = .hidden
    private weak var displayedView: NSView?

    override var mouseDownCanMoveWindow: Bool { false }

    @discardableResult
    func moveFirstResponderOutOfDisplayedPanel(to responder: NSResponder?) -> Bool {
        guard owns(firstResponder: window?.firstResponder) else {
            return false
        }
        return window?.makeFirstResponder(responder) ?? false
    }

    func owns(firstResponder: NSResponder?) -> Bool {
        guard let responderView = firstResponder as? NSView else {
            return false
        }
        return responderView === self || responderView.isDescendant(of: self)
    }

    func display(_ view: NSView?, mode: WorkspaceBottomPanelMode) {
        guard displayedView !== view || self.mode != mode else { return }
        displayedView?.removeFromSuperview()
        displayedView = view
        self.mode = mode
        guard let view else {
            isHidden = true
            return
        }
        isHidden = false
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
