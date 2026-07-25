import AppKit

final class WorkspaceViewController: NSViewController {
    private let launchPlan: ProjectLaunchPlan

    init(launchPlan: ProjectLaunchPlan = .newProject()) {
        self.launchPlan = launchPlan
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        launchPlan = .newProject(reason: "coder")
        super.init(coder: coder)
    }

    override func loadView() {
        view = WorkspaceView(launchPlan: launchPlan)
    }
}
