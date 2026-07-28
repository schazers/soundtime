import AppKit
import Sparkle

@MainActor
final class SparkleApplicationUpdateService: NSObject, ApplicationUpdateService {
    private enum DefaultsKey {
        static let channel = "SoundtimeUpdateChannel"
    }

    private(set) var state: ApplicationUpdateState = .idle {
        didSet {
            guard oldValue != state else {
                return
            }
            recordState(state)
            onStateChange?(state)
        }
    }

    var preferences: ApplicationUpdatePreferences {
        get {
            ApplicationUpdatePreferences(
                automaticallyChecksForUpdates: updater.automaticallyChecksForUpdates,
                automaticallyDownloadsUpdates: updater.automaticallyDownloadsUpdates,
                channel: channel
            )
        }
        set {
            updater.automaticallyChecksForUpdates = newValue.automaticallyChecksForUpdates
            updater.automaticallyDownloadsUpdates = newValue.automaticallyDownloadsUpdates
            channel = newValue.channel
            UserDefaults.standard.set(channel.rawValue, forKey: DefaultsKey.channel)
            updater.resetUpdateCycleAfterShortDelay()
        }
    }

    var canCheckForUpdates: Bool {
        updater.canCheckForUpdates
    }

    var onStateChange: ((ApplicationUpdateState) -> Void)?
    var restartBlockersProvider: (() -> [ApplicationUpdateRestartBlocker])?
    var onRestartBlocked: (([ApplicationUpdateRestartBlocker]) -> Void)?

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )
    private var updater: SPUUpdater { controller.updater }
    private var started = false
    private var activeRelease: ApplicationUpdateRelease?
    private var activeCheckOrigin: ApplicationUpdateCheckOrigin = .automatic
    private var postponedInstallHandler: (() -> Void)?
    private var channel: ApplicationUpdateChannel

    override init() {
        channel = UserDefaults.standard.string(forKey: DefaultsKey.channel)
            .flatMap(ApplicationUpdateChannel.init(rawValue:)) ?? .stable
        super.init()
    }

    func start() {
        guard !started else {
            return
        }
        started = true
        controller.startUpdater()
        _ = updater.clearFeedURLFromUserDefaults()
        record(
            name: "update-service-started",
            message: "Sparkle application update service started.",
            fields: [
                "channel": channel.rawValue,
                "automaticChecks": "\(updater.automaticallyChecksForUpdates)",
                "automaticDownloads": "\(updater.automaticallyDownloadsUpdates)",
            ]
        )
    }

    func checkForUpdates(origin: ApplicationUpdateCheckOrigin) {
        start()
        guard updater.canCheckForUpdates else {
            if origin == .manual {
                controller.checkForUpdates(nil)
            }
            return
        }

        activeCheckOrigin = origin
        state = .checking(origin: origin)
        switch origin {
        case .manual:
            controller.checkForUpdates(nil)
        case .automatic:
            updater.checkForUpdatesInBackground()
        }
    }

    func install(_ disposition: ApplicationUpdateInstallDisposition) {
        switch disposition {
        case .restartNow:
            if let postponedInstallHandler, currentRestartBlockers().isEmpty {
                self.postponedInstallHandler = nil
                postponedInstallHandler()
            } else {
                controller.checkForUpdates(nil)
            }
        case .installOnQuit:
            // Sparkle's standard driver keeps a downloaded update and schedules it
            // for installation on termination when the user chooses Later.
            controller.checkForUpdates(nil)
        }
    }

    func skipAvailableVersion() {
        // Skipping is intentionally handled by Sparkle's signed update alert so its
        // persisted skipped-version behavior remains the source of truth.
        controller.checkForUpdates(nil)
    }

    func resetPresentationState() {
        guard !state.isBusy else {
            return
        }
        state = .idle
    }

    func resumePostponedInstallationIfPossible() -> Bool {
        guard let postponedInstallHandler, currentRestartBlockers().isEmpty else {
            return false
        }
        self.postponedInstallHandler = nil
        postponedInstallHandler()
        return true
    }

    private func currentRestartBlockers() -> [ApplicationUpdateRestartBlocker] {
        restartBlockersProvider?() ?? []
    }

    private func release(from item: SUAppcastItem) -> ApplicationUpdateRelease {
        ApplicationUpdateRelease(
            version: ApplicationVersion(
                displayVersion: item.displayVersionString,
                buildVersion: item.versionString
            ),
            title: item.title ?? "Soundtime \(item.displayVersionString)",
            summary: nil,
            releaseNotesURL: item.releaseNotesURL,
            informationURL: item.infoURL,
            minimumSystemVersion: item.minimumSystemVersion,
            importance: item.isCriticalUpdate ? .critical : .regular
        )
    }

    private func failure(from error: Error) -> ApplicationUpdateFailure {
        let nsError = error as NSError
        let kind: ApplicationUpdateFailureKind
        if nsError.domain == NSURLErrorDomain {
            kind = .network
        } else if nsError.localizedDescription.localizedCaseInsensitiveContains("signature") {
            kind = .invalidSignature
        } else if nsError.localizedDescription.localizedCaseInsensitiveContains("system version") {
            kind = .incompatibleSystem
        } else {
            kind = .unknown
        }
        return ApplicationUpdateFailure(
            kind: kind,
            title: "Unable to check for updates",
            message: nsError.localizedDescription,
            recoverySuggestion: nsError.localizedRecoverySuggestion
        )
    }

    private func recordState(_ state: ApplicationUpdateState) {
        let stateName: String
        switch state {
        case .idle: stateName = "idle"
        case .checking: stateName = "checking"
        case .upToDate: stateName = "up-to-date"
        case .available: stateName = "available"
        case .downloading: stateName = "downloading"
        case .readyToInstall: stateName = "ready-to-install"
        case .installing: stateName = "installing"
        case .incompatible: stateName = "incompatible"
        case .failed: stateName = "failed"
        }
        record(
            name: "application-update-state-changed",
            message: "Application update state changed.",
            fields: [
                "state": stateName,
                "version": state.release?.version.fullDescription ?? "",
            ]
        )
    }

    private func record(name: String, message: String, fields: [String: String]) {
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: .info,
            name: name,
            message: message,
            fields: fields
        )
    }
}

extension SparkleApplicationUpdateService: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel == .beta ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let release = release(from: item)
        activeRelease = release
        state = .available(release)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        activeRelease = nil
        state = .upToDate(current: .current)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        let release = release(from: item)
        activeRelease = release
        state = .downloading(release: release, progress: nil)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let release = release(from: item)
        activeRelease = release
        state = .readyToInstall(release)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        state = .failed(failure(from: error))
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        let release = release(from: item)
        activeRelease = release
        state = .installing(release)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let release = release(from: item)
        activeRelease = release
        state = .installing(release)
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        let blockers = currentRestartBlockers()
        guard !blockers.isEmpty else {
            return false
        }
        postponedInstallHandler = installHandler
        onRestartBlocked?(blockers)
        record(
            name: "application-update-restart-postponed",
            message: "Update restart was postponed until active work is safe.",
            fields: ["blockers": blockers.map(\.kind.rawValue).joined(separator: ",")]
        )
        return true
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        currentRestartBlockers().isEmpty
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        record(
            name: "application-update-will-relaunch",
            message: "Soundtime will relaunch to finish installing an update.",
            fields: ["version": activeRelease?.version.fullDescription ?? ""]
        )
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        activeRelease = release(from: item)
        state = .readyToInstall(activeRelease!)
        // Sparkle remains responsible for the termination-time install. Returning
        // false avoids holding a custom closure or blocking the application quit path.
        return false
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if let error {
            let nsError = error as NSError
            if nsError.code != 1001 {
                state = .failed(failure(from: error))
            }
        } else if case .checking = state {
            state = .idle
        }
    }
}

extension SparkleApplicationUpdateService: @preconcurrency SPUStandardUserDriverDelegate {
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state userState: SPUUserUpdateState
    ) {
        let release = release(from: update)
        activeRelease = release
        state = .available(release)
    }

    func standardUserDriverWillFinishUpdateSession() {
        if !state.isBusy {
            state = .idle
        }
    }
}

@MainActor
enum ApplicationUpdateServiceFactory {
    static func make() -> ApplicationUpdateService {
        let bundle = Bundle.main
        guard
            bundle.bundleURL.pathExtension == "app",
            bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil,
            bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil
        else {
            return DisabledApplicationUpdateService()
        }
        return SparkleApplicationUpdateService()
    }
}
