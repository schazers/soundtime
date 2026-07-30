import Foundation

/// Single read/write boundary for first-paint project artifacts.
///
/// Atomic generation bundles are authoritative. The standalone sidecars remain
/// read-compatible for projects created by older Soundtime builds and are only
/// written when publishing an atomic bundle fails.
enum ProjectLaunchCacheStore {
    static func manifest(for projectURL: URL) -> ProjectLaunchManifest? {
        ProjectLaunchCacheBundleStore.loadManifest(for: projectURL) ??
            ProjectLaunchManifestStore.load(for: projectURL)
    }

    static func firstFramePacket(for projectURL: URL) -> ProjectFirstFrameWaveformPacket? {
        ProjectLaunchCacheBundleStore.loadFirstFramePacketForFirstPaintIfAvailable(
            for: projectURL
        ) ?? ProjectFirstFrameWaveformPacketStore.loadForFirstPaintIfAvailable(
            for: projectURL
        )
    }

    static func snapshotForFirstPaint(for projectURL: URL) -> ProjectLaunchSnapshot? {
        ProjectLaunchCacheBundleStore.loadSnapshotForFirstPaintIfAvailable(
            for: projectURL
        ) ?? ProjectLaunchSnapshotStore.loadForFirstPaintIfAvailable(
            for: projectURL
        )
    }

    static func firstFramePacketShell(
        for projectURL: URL
    ) -> ProjectFirstFrameWaveformPacket? {
        ProjectFirstFrameWaveformPacketStore.loadShellForFirstPaintIfAvailable(
            for: projectURL
        )
    }

    static func snapshotShell(for projectURL: URL) -> ProjectLaunchSnapshot? {
        ProjectLaunchSnapshotStore.loadShellForFirstPaintIfAvailable(
            for: projectURL
        )
    }

    static func snapshot(for projectURL: URL) throws -> ProjectLaunchSnapshot {
        if let bundled = try? ProjectLaunchCacheBundleStore.loadSnapshot(for: projectURL) {
            return bundled
        }
        return try ProjectLaunchSnapshotStore.load(for: projectURL)
    }

    @discardableResult
    static func publish(
        manifest: ProjectLaunchManifest,
        firstFramePacket: ProjectFirstFrameWaveformPacket,
        snapshot: ProjectLaunchSnapshot,
        for projectURL: URL
    ) throws -> Bool {
        do {
            try ProjectLaunchCacheBundleStore.publish(
                manifest: manifest,
                firstFramePacket: firstFramePacket,
                snapshot: snapshot,
                for: projectURL
            )
            return true
        } catch {
            try ProjectLaunchSnapshotStore.save(snapshot, for: projectURL)
            try ProjectFirstFrameWaveformPacketStore.save(firstFramePacket, for: projectURL)
            try ProjectLaunchManifestStore.save(manifest, for: projectURL)
            return false
        }
    }
}
