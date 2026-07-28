import Foundation

enum ApplicationUpdateChannel: String, Codable, CaseIterable, Sendable {
    case stable
    case beta

    var displayName: String {
        switch self {
        case .stable:
            return "Stable"
        case .beta:
            return "Beta"
        }
    }
}

enum ApplicationUpdateCheckOrigin: String, Codable, Sendable {
    case automatic
    case manual
}

enum ApplicationUpdateImportance: String, Codable, Sendable {
    case regular
    case critical
}

struct ApplicationVersion: Codable, Equatable, Sendable {
    var displayVersion: String
    var buildVersion: String

    static var current: ApplicationVersion {
        let bundle = Bundle.main
        return ApplicationVersion(
            displayVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
            buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        )
    }

    var fullDescription: String {
        "\(displayVersion) (\(buildVersion))"
    }
}

struct ApplicationUpdateRelease: Equatable, Sendable {
    var version: ApplicationVersion
    var title: String
    var summary: String?
    var releaseNotesURL: URL?
    var informationURL: URL?
    var minimumSystemVersion: String?
    var importance: ApplicationUpdateImportance
}

enum ApplicationUpdateFailureKind: String, Codable, Sendable {
    case network
    case invalidFeed
    case invalidSignature
    case incompatibleSystem
    case installation
    case unavailable
    case unknown
}

struct ApplicationUpdateFailure: Error, Equatable, Sendable {
    var kind: ApplicationUpdateFailureKind
    var title: String
    var message: String
    var recoverySuggestion: String?
}

enum ApplicationUpdateState: Equatable, Sendable {
    case idle
    case checking(origin: ApplicationUpdateCheckOrigin)
    case upToDate(current: ApplicationVersion)
    case available(ApplicationUpdateRelease)
    case downloading(release: ApplicationUpdateRelease, progress: Double?)
    case readyToInstall(ApplicationUpdateRelease)
    case installing(ApplicationUpdateRelease)
    case incompatible(ApplicationUpdateRelease, reason: String)
    case failed(ApplicationUpdateFailure)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }

    var release: ApplicationUpdateRelease? {
        switch self {
        case let .available(release),
             let .downloading(release, _),
             let .readyToInstall(release),
             let .installing(release),
             let .incompatible(release, _):
            return release
        default:
            return nil
        }
    }
}

enum ApplicationUpdateInstallDisposition: String, Codable, Sendable {
    case restartNow
    case installOnQuit
}

enum ApplicationUpdateRestartBlockerKind: String, Codable, Sendable {
    case unsavedProject
    case recording
    case export
    case importOrConversion
    case apiProcessing
    case projectWrite
}

struct ApplicationUpdateRestartBlocker: Equatable, Sendable {
    var kind: ApplicationUpdateRestartBlockerKind
    var title: String
    var message: String
    var canResolveAutomatically: Bool
}

struct ApplicationUpdatePreferences: Equatable, Sendable {
    var automaticallyChecksForUpdates: Bool
    var automaticallyDownloadsUpdates: Bool
    var channel: ApplicationUpdateChannel
}

