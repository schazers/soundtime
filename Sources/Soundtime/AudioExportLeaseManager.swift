import Foundation

struct AudioExportAssetLease: Sendable {
    let id: UUID
    let urls: [URL]
}

final class AudioExportLeaseManager: @unchecked Sendable {
    static let shared = AudioExportLeaseManager()

    private let lock = NSLock()
    private var leasesByURL: [URL: Set<UUID>] = [:]
    private var deferredDeleteURLs = Set<URL>()

    private init() {}

    func acquire(urls: [URL], jobID: UUID) -> AudioExportAssetLease {
        let uniqueURLs = Array(Set(urls.map(canonicalURL)))
        lock.lock()
        for url in uniqueURLs {
            var leases = leasesByURL[url] ?? []
            leases.insert(jobID)
            leasesByURL[url] = leases
        }
        lock.unlock()

        if !uniqueURLs.isEmpty {
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .info,
                name: "export-asset-lease-acquired",
                message: "Export retained source assets for a background snapshot render.",
                fields: [
                    "jobID": jobID.uuidString,
                    "assetCount": "\(uniqueURLs.count)",
                ]
            )
        }

        return AudioExportAssetLease(id: jobID, urls: uniqueURLs)
    }

    func release(_ lease: AudioExportAssetLease) {
        var readyToDelete: [URL] = []
        lock.lock()
        for url in lease.urls {
            guard var leases = leasesByURL[url] else {
                continue
            }
            leases.remove(lease.id)
            leasesByURL[url] = leases.isEmpty ? nil : leases
            if leases.isEmpty, deferredDeleteURLs.remove(url) != nil {
                readyToDelete.append(url)
            }
        }
        lock.unlock()

        for url in readyToDelete {
            do {
                try FileManager.default.removeItem(at: url)
                SoundtimeDiagnostics.shared.record(
                    category: .system,
                    severity: .info,
                    name: "export-deferred-asset-delete-completed",
                    message: "Deferred source asset deletion completed after export leases were released.",
                    fields: [
                        "path": url.path,
                    ]
                )
            } catch {
                SoundtimeDiagnostics.shared.record(
                    category: .system,
                    severity: .warning,
                    name: "export-deferred-asset-delete-failed",
                    message: "Deferred source asset deletion failed after export completed.",
                    fields: [
                        "path": url.path,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }

        if !lease.urls.isEmpty {
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .info,
                name: "export-asset-lease-released",
                message: "Export released source asset leases.",
                fields: [
                    "jobID": lease.id.uuidString,
                    "assetCount": "\(lease.urls.count)",
                ]
            )
        }
    }

    func isLeased(_ url: URL) -> Bool {
        let normalizedURL = canonicalURL(url)
        lock.lock()
        defer {
            lock.unlock()
        }
        return leasesByURL[normalizedURL]?.isEmpty == false
    }

    func deferDeletionIfLeased(_ url: URL) -> Bool {
        let normalizedURL = canonicalURL(url)
        lock.lock()
        let isCurrentlyLeased = leasesByURL[normalizedURL]?.isEmpty == false
        if isCurrentlyLeased {
            deferredDeleteURLs.insert(normalizedURL)
        }
        lock.unlock()

        if isCurrentlyLeased {
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .info,
                name: "export-asset-delete-deferred",
                message: "Source asset deletion was deferred because a background export is using it.",
                fields: [
                    "path": normalizedURL.path,
                ]
            )
        }

        return isCurrentlyLeased
    }

    func deleteOrDefer(_ url: URL) throws {
        let normalizedURL = canonicalURL(url)
        if deferDeletionIfLeased(normalizedURL) {
            return
        }
        try FileManager.default.removeItem(at: normalizedURL)
    }

    private func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
