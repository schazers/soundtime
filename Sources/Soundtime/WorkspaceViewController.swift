import AppKit

final class WorkspaceViewController: NSViewController {
    init(restoresLastProject: Bool = true) {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func loadView() {
        view = WorkspaceView()
    }
}
