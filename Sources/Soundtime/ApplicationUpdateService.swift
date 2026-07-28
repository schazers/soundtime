import Foundation

@MainActor
protocol ApplicationUpdateService: AnyObject {
    var state: ApplicationUpdateState { get }
    var preferences: ApplicationUpdatePreferences { get set }
    var canCheckForUpdates: Bool { get }
    var onStateChange: ((ApplicationUpdateState) -> Void)? { get set }

    func start()
    func checkForUpdates(origin: ApplicationUpdateCheckOrigin)
    func install(_ disposition: ApplicationUpdateInstallDisposition)
    func skipAvailableVersion()
    func resetPresentationState()
}

@MainActor
final class DisabledApplicationUpdateService: ApplicationUpdateService {
    private(set) var state: ApplicationUpdateState = .idle {
        didSet {
            onStateChange?(state)
        }
    }

    var preferences = ApplicationUpdatePreferences(
        automaticallyChecksForUpdates: false,
        automaticallyDownloadsUpdates: false,
        channel: .stable
    )
    var canCheckForUpdates: Bool { true }
    var onStateChange: ((ApplicationUpdateState) -> Void)?

    func start() {}

    func checkForUpdates(origin: ApplicationUpdateCheckOrigin) {
        state = .failed(ApplicationUpdateFailure(
            kind: .unavailable,
            title: "Updates are unavailable",
            message: "This development build is not packaged for application updates.",
            recoverySuggestion: "Use a signed Soundtime application bundle to test updates."
        ))
    }

    func install(_ disposition: ApplicationUpdateInstallDisposition) {}
    func skipAvailableVersion() {}
    func resetPresentationState() {
        state = .idle
    }
}

@MainActor
final class TestApplicationUpdateService: ApplicationUpdateService {
    private(set) var state: ApplicationUpdateState = .idle {
        didSet {
            onStateChange?(state)
        }
    }

    var preferences = ApplicationUpdatePreferences(
        automaticallyChecksForUpdates: true,
        automaticallyDownloadsUpdates: false,
        channel: .stable
    )
    var canCheckForUpdates = true
    var onStateChange: ((ApplicationUpdateState) -> Void)?
    private(set) var requestedChecks: [ApplicationUpdateCheckOrigin] = []
    private(set) var requestedInstallDisposition: ApplicationUpdateInstallDisposition?
    private(set) var skippedVersion = false

    func start() {}

    func checkForUpdates(origin: ApplicationUpdateCheckOrigin) {
        requestedChecks.append(origin)
        state = .checking(origin: origin)
    }

    func install(_ disposition: ApplicationUpdateInstallDisposition) {
        requestedInstallDisposition = disposition
        if let release = state.release {
            state = .installing(release)
        }
    }

    func skipAvailableVersion() {
        skippedVersion = true
        state = .idle
    }

    func resetPresentationState() {
        state = .idle
    }

    func publish(_ state: ApplicationUpdateState) {
        self.state = state
    }
}
