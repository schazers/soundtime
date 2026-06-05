import AppKit

final class WorkspaceViewController: NSViewController {
    private let restoresLastProject: Bool

    init(restoresLastProject: Bool = true) {
        self.restoresLastProject = restoresLastProject
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        restoresLastProject = true
        super.init(coder: coder)
    }

    override func loadView() {
        view = WorkspaceView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if restoresLastProject {
            (view as? WorkspaceView)?.restoreLastProjectIfNeeded()
        }
    }
}
