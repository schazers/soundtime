import AppKit

final class WorkspaceViewController: NSViewController {
    override func loadView() {
        view = WorkspaceView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        (view as? WorkspaceView)?.restoreLastProjectIfNeeded()
    }
}
