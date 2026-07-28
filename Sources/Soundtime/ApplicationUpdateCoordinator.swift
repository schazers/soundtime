import AppKit

@MainActor
final class ApplicationUpdateCoordinator: NSObject {
    let service: ApplicationUpdateService
    var restartBlockersProvider: (() -> [ApplicationUpdateRestartBlocker])? {
        didSet {
            sparkleService?.restartBlockersProvider = restartBlockersProvider
        }
    }

    private var delayedStartWorkItem: DispatchWorkItem?
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

    private static func presentRestartBlockers(_ blockers: [ApplicationUpdateRestartBlocker]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Finish current work before restarting"
        alert.informativeText = blockers.map(\.message).joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
