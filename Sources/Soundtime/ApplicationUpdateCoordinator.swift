import AppKit

@MainActor
final class ApplicationUpdateCoordinator: NSObject {
    let service: ApplicationUpdateService
    var presentationWindowProvider: (() -> NSWindow?)?
    var restartBlockersProvider: (() -> [ApplicationUpdateRestartBlocker])? {
        didSet {
            sparkleService?.restartBlockersProvider = restartBlockersProvider
        }
    }

    private var delayedStartWorkItem: DispatchWorkItem?
    private lazy var statusWindowController: ApplicationUpdateStatusWindowController = {
        let controller = ApplicationUpdateStatusWindowController()
        controller.onAction = { [weak self] action in
            self?.handleStatusAction(action)
        }
        return controller
    }()
    private var sparkleService: SparkleApplicationUpdateService? {
        service as? SparkleApplicationUpdateService
    }

    override convenience init() {
        self.init(service: ApplicationUpdateServiceFactory.make())
    }

    init(service: ApplicationUpdateService) {
        self.service = service
        super.init()
        sparkleService?.onRestartBlocked = { blockers in
            Self.presentRestartBlockers(blockers)
        }
        service.onStateChange = { [weak self] state in
            self?.handleStateChange(state)
        }
    }

    func startAfterLaunchSettles(delay: TimeInterval = 3.0) {
        delayedStartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.service.start()
        }
        delayedStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func checkForUpdates() {
        delayedStartWorkItem?.cancel()
        delayedStartWorkItem = nil
        service.checkForUpdates(origin: .manual)
    }

    func applicationWillTerminate() {
        delayedStartWorkItem?.cancel()
        delayedStartWorkItem = nil
    }

    private func handleStateChange(_ state: ApplicationUpdateState) {
        guard service is DisabledApplicationUpdateService else {
            return
        }
        guard let presentation = ApplicationUpdateStatusPresentation.make(for: state) else {
            return
        }
        statusWindowController.present(
            presentation,
            relativeTo: presentationWindowProvider?() ?? NSApplication.shared.keyWindow
        )
    }

    private func handleStatusAction(_ action: ApplicationUpdateStatusPresentation.Action) {
        switch action {
        case .dismiss:
            service.resetPresentationState()
        case .installAndRestart:
            service.install(.restartNow)
        case .installOnQuit:
            service.install(.installOnQuit)
        }
    }

    private static func presentRestartBlockers(_ blockers: [ApplicationUpdateRestartBlocker]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Finish current work before restarting"
        alert.informativeText = blockers.map(\.message).joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
