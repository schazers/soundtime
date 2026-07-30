import Foundation

@MainActor
enum ApplicationUpdateSmokeHarness {
    enum SmokeError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(message):
                return message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let service = TestApplicationUpdateService()
        var observedStates: [ApplicationUpdateState] = []
        service.onStateChange = { observedStates.append($0) }

        service.checkForUpdates(origin: .manual)
        try require(service.requestedChecks == [.manual], "manual update check was not routed through the service")
        try require(observedStates.last == .checking(origin: .manual), "checking state was not published")

        let regularRelease = ApplicationUpdateRelease(
            version: ApplicationVersion(displayVersion: "2.0.0", buildVersion: "200"),
            title: "Soundtime 2.0",
            summary: "Update fixture",
            releaseNotesURL: URL(string: "https://updates.soundtime.app/notes/2.0.0"),
            informationURL: nil,
            minimumSystemVersion: "14.0",
            importance: .regular
        )
        service.publish(.available(regularRelease))
        service.install(.restartNow)
        try require(
            service.requestedInstallDisposition == .restartNow,
            "restart-now installation disposition was not preserved"
        )

        service.publish(.available(regularRelease))
        service.skipAvailableVersion()
        try require(service.skippedVersion, "skip action was not preserved")

        service.preferences = ApplicationUpdatePreferences(
            automaticallyChecksForUpdates: true,
            automaticallyDownloadsUpdates: true,
            channel: .beta
        )
        try require(service.preferences.channel == .beta, "beta update preference was not preserved")

        try validateStatusPresentations()
        let root = repositoryRoot()
        try validateBundleConfiguration(root: root)
        try validateAppcastFixture(root: root)
        try validateReleaseScripts(root: root)
        try validateNoPrivateUpdateKey(root: root)

        print("Soundtime application update smoke passed")
    }

    private static func validateStatusPresentations() throws {
        let unavailable = ApplicationUpdateFailure(
            kind: .unavailable,
            title: "Updates are unavailable",
            message: "This development build is not packaged for application updates.",
            recoverySuggestion: "Use a signed Soundtime application bundle to test updates."
        )
        let unavailablePresentation = ApplicationUpdateStatusPresentation.make(
            for: .failed(unavailable)
        )
        try require(
            unavailablePresentation?.title == unavailable.title,
            "unavailable update title is not presented"
        )
        try require(
            unavailablePresentation?.detail == unavailable.recoverySuggestion,
            "unavailable update recovery suggestion is not presented"
        )
        try require(
            unavailablePresentation?.primaryAction == .dismiss,
            "unavailable update dialog must be dismissible"
        )

        let current = ApplicationVersion(displayVersion: "1.2.3", buildVersion: "123")
        let upToDatePresentation = ApplicationUpdateStatusPresentation.make(
            for: .upToDate(current: current)
        )
        try require(
            upToDatePresentation?.message.contains(current.fullDescription) == true,
            "up-to-date dialog must identify the installed version"
        )
    }

    private static func validateBundleConfiguration(root: URL) throws {
        let infoURL = root.appendingPathComponent("Config/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = plist as? [String: Any] else {
            throw SmokeError.failed("Info.plist is not a dictionary")
        }
        try require(dictionary["CFBundleExecutable"] as? String == "Soundtime", "bundle executable is incorrect")
        try require(dictionary["CFBundleIconName"] as? String == "AppIcon", "bundle icon is not configured")
        try require(dictionary["SUAllowsAutomaticUpdates"] as? Bool == true, "automatic update support is disabled")
        try require(dictionary["SUSendProfileInfo"] as? Bool == false, "update checks must not send a system profile")

        let entitlementsData = try Data(contentsOf: root.appendingPathComponent("Config/Soundtime.entitlements"))
        let entitlements = try PropertyListSerialization.propertyList(from: entitlementsData, format: nil)
        guard let entitlementDictionary = entitlements as? [String: Any] else {
            throw SmokeError.failed("entitlements file is not a dictionary")
        }
        try require(
            entitlementDictionary["com.apple.security.device.audio-input"] as? Bool == true,
            "audio-input entitlement is missing"
        )
    }

    private static func validateAppcastFixture(root: URL) throws {
        let appcast = try String(
            contentsOf: root.appendingPathComponent("Config/Appcast/appcast-example.xml"),
            encoding: .utf8
        )
        try require(appcast.contains("<sparkle:criticalUpdate/>"), "critical update fixture is missing")
        try require(appcast.contains("<sparkle:channel>beta</sparkle:channel>"), "beta channel fixture is missing")
        try require(appcast.contains("<sparkle:phasedRolloutInterval>"), "phased rollout fixture is missing")
        try require(!appcast.contains("http://updates.soundtime"), "appcast archive URLs must use HTTPS")
    }

    private static func validateReleaseScripts(root: URL) throws {
        let packageScript = try String(
            contentsOf: root.appendingPathComponent("scripts/package-release.sh"),
            encoding: .utf8
        )
        for requiredCommand in [
            "codesign --verify",
            "notarytool submit",
            "stapler staple",
            "stapler validate",
            "spctl --assess",
            "verify-release.sh",
            "ditto -c -k",
        ] {
            try require(packageScript.contains(requiredCommand), "release script is missing \(requiredCommand)")
        }
        try require(
            packageScript.contains("SOUNDTIME_NOTARY_PROFILE:?"),
            "production packaging must require notarization credentials"
        )

        let buildScript = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        try require(
            buildScript.contains("Sparkle-LICENSE.txt"),
            "application bundle must include Sparkle's third-party license notices"
        )

        let appcastScript = try String(
            contentsOf: root.appendingPathComponent("scripts/generate-appcast.sh"),
            encoding: .utf8
        )
        try require(appcastScript.contains("generate_appcast"), "appcast generator is not wired")
        try require(appcastScript.contains("https://"), "appcast generator does not enforce HTTPS")
    }

    private static func validateNoPrivateUpdateKey(root: URL) throws {
        let candidateDirectories = ["Config", "Docs", "Sources", "scripts"]
        let forbiddenMarkers = [
            ["BEGIN", "PRIVATE", "KEY"].joined(separator: " "),
            ["BEGIN", "OPENSSH", "PRIVATE", "KEY"].joined(separator: " "),
        ]
        for directory in candidateDirectories {
            let directoryURL = root.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                guard
                    (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                    let contents = try? String(contentsOf: fileURL, encoding: .utf8)
                else {
                    continue
                }
                for marker in forbiddenMarkers {
                    try require(!contents.contains(marker), "private update key material found in \(fileURL.path)")
                }
            }
        }
    }

    private static func repositoryRoot() -> URL {
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw SmokeError.failed(message)
        }
    }
}
