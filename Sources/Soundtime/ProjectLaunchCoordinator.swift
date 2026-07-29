import Foundation
import QuartzCore

struct ProjectLaunchFirstFrame: Sendable {
    enum Source: String, Sendable {
        case firstFrameWaveformShell
        case launchSnapshotShell
        case launchManifestShell
        case firstFrameWaveformPacket
        case launchSnapshot
        case savedProjectPreview
        case recoveredAutosavePreview
        case deferredLaunchSnapshot
        case deferredProjectPreview

        var isShellOnly: Bool {
            switch self {
            case .firstFrameWaveformShell, .launchSnapshotShell, .launchManifestShell:
                true
            default:
                false
            }
        }

        var diagnosticName: String {
            switch self {
            case .firstFrameWaveformShell:
                "launch-first-frame-waveform-shell-loaded"
            case .launchSnapshotShell:
                "launch-snapshot-shell-loaded"
            case .launchManifestShell:
                "launch-manifest-shell-loaded"
            case .firstFrameWaveformPacket:
                "launch-first-frame-waveform-packet-loaded"
            case .launchSnapshot:
                "launch-first-paint-snapshot-loaded"
            case .savedProjectPreview:
                "launch-saved-project-first-paint-preview-loaded"
            case .recoveredAutosavePreview:
                "launch-recovered-autosave-first-paint-preview-loaded"
            case .deferredLaunchSnapshot:
                "launch-snapshot-loaded"
            case .deferredProjectPreview:
                "launch-project-preview-loaded"
            }
        }

        var statusOverride: String {
            switch self {
            case .firstFrameWaveformShell, .launchSnapshotShell, .launchManifestShell:
                "opening project"
            case .firstFrameWaveformPacket, .launchSnapshot, .deferredLaunchSnapshot:
                "launch snapshot ready - opening project"
            case .savedProjectPreview, .recoveredAutosavePreview, .deferredProjectPreview:
                "opening last project"
            }
        }

        var recordSourceName: String {
            switch self {
            case .firstFrameWaveformShell:
                "first-frame-packet-shell"
            case .launchSnapshotShell:
                "snapshot-shell"
            case .launchManifestShell:
                "manifest-shell"
            case .firstFrameWaveformPacket:
                "first-frame-packet"
            case .launchSnapshot, .deferredLaunchSnapshot:
                "snapshot"
            case .savedProjectPreview, .recoveredAutosavePreview, .deferredProjectPreview:
                "project-preview"
            }
        }
    }

    struct Track: Sendable {
        var id: UUID
        var editGroupID: UUID?
        var name: String
        var sourceURL: URL
        var durationHint: TimeInterval?
        var sourceWaveformOverview: WaveformOverview?
        var displayWaveformOverview: WaveformOverview?
        var editTimeline: AudioFileEditTimeline.PersistentState?
        var editableSource: SoundtimeProject.Track.EditableSource?
        var ownsSourceFile: Bool?
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool
        var transcript: TranscriptDocument?
    }

    var projectURL: URL
    var source: Source
    var loadMilliseconds: Double
    var projectID: UUID?
    var editGraphRevision: UInt64?
    var visualRevision: UInt64?
    var launchStateRevision: UInt64?
    var windowLayout: SoundtimeProject.WindowLayout?
    var timelineViewport: SoundtimeProject.TimelineViewport?
    var masterVolume: Float?
    var transcriptDisplayMode: TranscriptTimelineDisplayMode?
    var tracks: [Track]
    var summary: ProjectLaunchVisualReadinessSummary

    var isShellOnly: Bool {
        source.isShellOnly
    }

    func applyingOverlay(_ overlay: SoundtimeProjectLaunchStateOverlay?) -> ProjectLaunchFirstFrame {
        guard let overlay else {
            return self
        }

        var firstFrame = self
        firstFrame.windowLayout = overlay.windowLayout ?? firstFrame.windowLayout
        firstFrame.timelineViewport = overlay.timelineViewport ?? firstFrame.timelineViewport
        firstFrame.masterVolume = overlay.masterVolume ?? firstFrame.masterVolume
        firstFrame.transcriptDisplayMode = overlay.transcriptDisplayMode ?? firstFrame.transcriptDisplayMode

        let overlayTracksByID = Dictionary(uniqueKeysWithValues: overlay.tracks.map { ($0.id, $0) })
        firstFrame.tracks = firstFrame.tracks.map { track in
            guard let overlayTrack = overlayTracksByID[track.id] else {
                return track
            }

            var mergedTrack = track
            mergedTrack.volume = min(max(overlayTrack.volume, 0), 1)
            mergedTrack.isMuted = overlayTrack.isMuted
            mergedTrack.isSoloed = overlayTrack.isSoloed
            return mergedTrack
        }
        return firstFrame
    }
}

struct ProjectLaunchPlan: Sendable {
    enum Mode: String, Sendable {
        case newProject
        case restoreProject
    }

    var mode: Mode
    var targetProjectURL: URL?
    var visualCacheURL: URL?
    var usesAutosaveRecovery: Bool
    var firstPaintFrame: ProjectLaunchFirstFrame?
    var windowLayout: SoundtimeProject.WindowLayout?
    var source: ProjectLaunchFirstFrame.Source?
    var expectedTrackCount: Int
    var hasWaveformPacket: Bool
    var hasShell: Bool
    var reason: String
    var resolveMilliseconds: Double

    var restoresProject: Bool {
        mode == .restoreProject
    }

    static func newProject(reason: String = "new-project") -> ProjectLaunchPlan {
        ProjectLaunchPlan(
            mode: .newProject,
            targetProjectURL: nil,
            visualCacheURL: nil,
            usesAutosaveRecovery: false,
            firstPaintFrame: nil,
            windowLayout: nil,
            source: nil,
            expectedTrackCount: 0,
            hasWaveformPacket: false,
            hasShell: false,
            reason: reason,
            resolveMilliseconds: 0
        )
    }

    var diagnosticFields: [String: String] {
        [
            "mode": mode.rawValue,
            "target": targetProjectURL?.lastPathComponent ?? "none",
            "visualCache": visualCacheURL?.lastPathComponent ?? "none",
            "usesAutosaveRecovery": "\(usesAutosaveRecovery)",
            "source": source?.rawValue ?? "none",
            "tracks": "\(expectedTrackCount)",
            "hasWaveformPacket": "\(hasWaveformPacket)",
            "hasShell": "\(hasShell)",
            "reason": reason,
            "resolveMs": String(format: "%.2f", resolveMilliseconds),
        ]
    }
}

enum ProjectLaunchCoordinator {
    private static let recoveredAutosaveSynchronousByteLimit = 4 * 1_024 * 1_024
    private static let savedProjectSynchronousByteLimit = 8 * 1_024 * 1_024

    enum DeferredResult: Sendable {
        case firstFrame(ProjectLaunchFirstFrame)
        case unavailable(URL, String, Double)
    }

    private struct RestorableLaunchTarget {
        var targetProjectURL: URL
        var visualCacheURL: URL
        var usesAutosaveRecovery: Bool
        var reason: String
    }

    static func resolveLaunchPlan(restoresLastProject: Bool) -> ProjectLaunchPlan {
        let startedAt = CACurrentMediaTime()
        guard restoresLastProject else {
            var plan = ProjectLaunchPlan.newProject(reason: "explicit-new-project")
            plan.resolveMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
            return plan
        }

        guard let target = restorableLaunchTarget() else {
            var plan = ProjectLaunchPlan.newProject(reason: "no-restorable-project")
            plan.resolveMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
            return plan
        }

        return resolveLaunchPlan(target: target, startedAt: startedAt)
    }

    static func resolveLaunchPlanForProject(
        projectURL: URL,
        reason: String = "explicit-project"
    ) -> ProjectLaunchPlan {
        let startedAt = CACurrentMediaTime()
        let standardizedProjectURL = projectURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedProjectURL.path) else {
            var plan = ProjectLaunchPlan.newProject(reason: "\(reason)-missing")
            plan.resolveMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
            return plan
        }

        return resolveLaunchPlan(
            target: RestorableLaunchTarget(
                targetProjectURL: standardizedProjectURL,
                visualCacheURL: standardizedProjectURL,
                usesAutosaveRecovery: true,
                reason: reason
            ),
            startedAt: startedAt
        )
    }

    private static func resolveLaunchPlan(
        target: RestorableLaunchTarget,
        startedAt: CFTimeInterval
    ) -> ProjectLaunchPlan {
        let overlay = SoundtimeProjectStore.rememberedLaunchStateOverlay(for: target.targetProjectURL)
        let firstPaintFrame = (
            loadCachedFirstPaintFrame(projectURL: target.visualCacheURL) ??
                loadShell(projectURL: target.visualCacheURL)
        )?
            .applyingOverlay(overlay)
        let windowLayout = firstPaintFrame?.windowLayout ??
            overlay?.windowLayout ??
            SoundtimeProjectStore.rememberedWindowLayout(for: target.targetProjectURL)
        let source = firstPaintFrame?.source
        let resolveMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        return ProjectLaunchPlan(
            mode: .restoreProject,
            targetProjectURL: target.targetProjectURL,
            visualCacheURL: target.visualCacheURL,
            usesAutosaveRecovery: target.usesAutosaveRecovery,
            firstPaintFrame: firstPaintFrame,
            windowLayout: windowLayout,
            source: source,
            expectedTrackCount: firstPaintFrame?.tracks.count ?? 0,
            hasWaveformPacket: source == .firstFrameWaveformPacket,
            hasShell: firstPaintFrame?.isShellOnly == true,
            reason: target.reason,
            resolveMilliseconds: resolveMilliseconds
        )
    }

    static func preferredWindowLayoutForLastProject() -> SoundtimeProject.WindowLayout? {
        guard
            let projectURL = SoundtimeProjectStore.lastProjectURL(),
            FileManager.default.fileExists(atPath: projectURL.path)
        else {
            return nil
        }

        let overlay = SoundtimeProjectStore.rememberedLaunchStateOverlay(for: projectURL)
        let manifest = ProjectLaunchCacheBundleStore.loadManifest(for: projectURL) ??
            ProjectLaunchManifestStore.load(for: projectURL)
        return overlay?.windowLayout ??
            manifest?.windowLayout ??
            SoundtimeProjectStore.rememberedWindowLayout(for: projectURL)
    }

    static func cachedFirstPaintFrameForRestorableProject() -> ProjectLaunchFirstFrame? {
        resolveLaunchPlan(restoresLastProject: true).firstPaintFrame
    }

    static func loadShell(projectURL: URL) -> ProjectLaunchFirstFrame? {
        let standardizedProjectURL = projectURL.standardizedFileURL
        let startedAt = CACurrentMediaTime()

        if let manifest = ProjectLaunchCacheBundleStore.loadManifest(for: standardizedProjectURL) ??
            ProjectLaunchManifestStore.load(for: standardizedProjectURL)
        {
            let summary = ProjectLaunchReadinessClassifier.summarize(manifest: manifest)
            guard summary.hasTracks else {
                return nil
            }
            return firstFrame(
                from: manifest,
                projectURL: standardizedProjectURL,
                source: .launchManifestShell,
                loadMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
                summary: summary
            )
        }

        if
            SoundtimeFeatureFlags.firstFrameWaveformPacket,
            let packet = ProjectFirstFrameWaveformPacketStore
                .loadShellForFirstPaintIfAvailable(for: standardizedProjectURL)
        {
            let summary = ProjectLaunchReadinessClassifier.summarize(packet: packet)
            guard summary.hasTracks else {
                return nil
            }
            return firstFrame(
                from: packet,
                projectURL: standardizedProjectURL,
                source: .firstFrameWaveformShell,
                loadMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
                summary: summary
            )
        }

        guard let snapshot = ProjectLaunchSnapshotStore
            .loadShellForFirstPaintIfAvailable(for: standardizedProjectURL)
        else {
            return nil
        }
        let summary = ProjectLaunchReadinessClassifier.summarize(snapshot: snapshot)
        guard summary.hasTracks else {
            return nil
        }
        return firstFrame(
            from: snapshot,
            projectURL: standardizedProjectURL,
            source: .launchSnapshotShell,
            loadMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
            summary: summary
        )
    }

    static func loadFirstFrame(
        projectURL: URL,
        usesAutosaveRecovery: Bool,
        waveformOverviewDiskCache: WaveformOverviewDiskCacheStore
    ) -> ProjectLaunchFirstFrame? {
        let standardizedProjectURL = projectURL.standardizedFileURL

        if
            SoundtimeFeatureFlags.firstFrameWaveformPacket,
            let packetFrame = loadPacketFirstFrame(projectURL: standardizedProjectURL)
        {
            return packetFrame
        }

        if let snapshotFrame = loadSnapshotFirstFrame(projectURL: standardizedProjectURL) {
            return snapshotFrame
        }

        return loadProjectPreviewFirstFrame(
            projectURL: standardizedProjectURL,
            usesAutosaveRecovery: usesAutosaveRecovery,
            waveformOverviewDiskCache: waveformOverviewDiskCache
        )
    }

    static func loadCachedFirstPaintFrame(projectURL: URL) -> ProjectLaunchFirstFrame? {
        let standardizedProjectURL = projectURL.standardizedFileURL
        if let packetFrame = loadPacketFirstFrame(projectURL: standardizedProjectURL) {
            return packetFrame
        }
        return loadSnapshotFirstFrame(projectURL: standardizedProjectURL)
    }

    private static func restorableLaunchTarget() -> RestorableLaunchTarget? {
        if
            let lastProjectURL = SoundtimeProjectStore.lastProjectURL(),
            FileManager.default.fileExists(atPath: lastProjectURL.path)
        {
            let standardizedProjectURL = lastProjectURL.standardizedFileURL
            if let autosaveURL = SoundtimeProjectStore.recoverableAutosaveURL(for: standardizedProjectURL) {
                return RestorableLaunchTarget(
                    targetProjectURL: standardizedProjectURL,
                    visualCacheURL: autosaveURL.standardizedFileURL,
                    usesAutosaveRecovery: true,
                    reason: "remembered-project-recovered-autosave"
                )
            }
            return RestorableLaunchTarget(
                targetProjectURL: standardizedProjectURL,
                visualCacheURL: standardizedProjectURL,
                usesAutosaveRecovery: true,
                reason: "remembered-project"
            )
        }

        guard let recoveryURL = SoundtimeProjectStore.recoverableAutosaveURLs().first else {
            return nil
        }
        let standardizedRecoveryURL = recoveryURL.standardizedFileURL
        if let canonicalProjectURL = SoundtimeProjectStore.canonicalProjectURL(
            forAutosaveAt: standardizedRecoveryURL
        ) {
            return RestorableLaunchTarget(
                targetProjectURL: canonicalProjectURL,
                visualCacheURL: standardizedRecoveryURL,
                usesAutosaveRecovery: true,
                reason: "autosave-provenance-restored-project"
            )
        }
        return RestorableLaunchTarget(
            targetProjectURL: standardizedRecoveryURL,
            visualCacheURL: standardizedRecoveryURL,
            usesAutosaveRecovery: false,
            reason: "standalone-recovered-autosave"
        )
    }

    static func loadDeferredFirstFrame(
        projectURL: URL,
        usesAutosaveRecovery: Bool,
        waveformOverviewDiskCache: WaveformOverviewDiskCacheStore
    ) -> DeferredResult {
        let standardizedProjectURL = projectURL.standardizedFileURL
        let startedAt = CACurrentMediaTime()

        if
            let snapshot = (try? ProjectLaunchCacheBundleStore.loadSnapshot(for: standardizedProjectURL)) ??
                (try? ProjectLaunchSnapshotStore.load(for: standardizedProjectURL)),
            snapshot.isDrawable
        {
            let summary = ProjectLaunchReadinessClassifier.summarize(snapshot: snapshot)
            if summary.hasAnyDrawableWaveform {
                let frame = firstFrame(
                    from: snapshot,
                    projectURL: standardizedProjectURL,
                    source: .deferredLaunchSnapshot,
                    loadMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
                    summary: summary
                )
                return .firstFrame(frame)
            }
        }

        do {
            let project = usesAutosaveRecovery ?
                try SoundtimeProjectStore.loadLaunchPreviewRecoveringAutosave(from: standardizedProjectURL) :
                try SoundtimeProjectStore.loadLaunchPreview(from: standardizedProjectURL)
            let hydratedProject = ProjectLaunchPreviewWaveformCacheHydrator.hydratedProject(
                project,
                waveformOverviewDiskCache: waveformOverviewDiskCache
            )
            let summary = ProjectLaunchReadinessClassifier.summarize(project: hydratedProject)
            guard summary.hasTracks else {
                return .unavailable(
                    standardizedProjectURL,
                    "project preview had no tracks",
                    (CACurrentMediaTime() - startedAt) * 1_000
                )
            }
            let frame = firstFrame(
                from: hydratedProject,
                projectURL: standardizedProjectURL,
                source: .deferredProjectPreview,
                loadMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
                summary: summary
            )
            return .firstFrame(frame)
        } catch {
            return .unavailable(
                standardizedProjectURL,
                error.localizedDescription,
                (CACurrentMediaTime() - startedAt) * 1_000
            )
        }
    }

    private static func loadPacketFirstFrame(projectURL: URL) -> ProjectLaunchFirstFrame? {
        let startedAt = CACurrentMediaTime()
        guard
            let packet = ProjectLaunchCacheBundleStore.loadFirstFramePacketForFirstPaintIfAvailable(for: projectURL) ??
                ProjectFirstFrameWaveformPacketStore.loadForFirstPaintIfAvailable(for: projectURL),
            packet.isDrawable
        else {
            return nil
        }
        if
            let manifest = ProjectLaunchCacheBundleStore.loadManifest(for: projectURL) ??
                ProjectLaunchManifestStore.load(for: projectURL),
            let packetFingerprint = packet.visualFingerprint,
            packetFingerprint != manifest.visualFingerprint
        {
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .warning,
                name: "launch-first-frame-packet-rejected",
                message: "First-frame waveform packet was rejected because its visual fingerprint did not match the launch manifest.",
                fields: [
                    "file": projectURL.lastPathComponent,
                    "packetFingerprint": packetFingerprint.value,
                    "manifestFingerprint": manifest.visualFingerprint.value,
                ]
            )
            return nil
        }

        let summary = ProjectLaunchReadinessClassifier.summarize(packet: packet)
        guard summary.hasAnyDrawableWaveform else {
            return nil
        }
        return firstFrame(
            from: packet,
            projectURL: projectURL,
            source: .firstFrameWaveformPacket,
            loadMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
            summary: summary
        )
    }

    private static func loadSnapshotFirstFrame(projectURL: URL) -> ProjectLaunchFirstFrame? {
        let startedAt = CACurrentMediaTime()
        guard
            let snapshot = ProjectLaunchCacheBundleStore.loadSnapshotForFirstPaintIfAvailable(for: projectURL) ??
                ProjectLaunchSnapshotStore.loadForFirstPaintIfAvailable(for: projectURL),
            snapshot.isDrawable
        else {
            return nil
        }
        if
            let manifest = ProjectLaunchCacheBundleStore.loadManifest(for: projectURL) ??
                ProjectLaunchManifestStore.load(for: projectURL),
            let snapshotFingerprint = snapshot.visualFingerprint,
            snapshotFingerprint != manifest.visualFingerprint
        {
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .warning,
                name: "launch-snapshot-rejected",
                message: "Launch snapshot was rejected because its visual fingerprint did not match the launch manifest.",
                fields: [
                    "file": projectURL.lastPathComponent,
                    "snapshotFingerprint": snapshotFingerprint.value,
                    "manifestFingerprint": manifest.visualFingerprint.value,
                ]
            )
            return nil
        }

        let summary = ProjectLaunchReadinessClassifier.summarize(snapshot: snapshot)
        guard summary.hasAnyDrawableWaveform else {
            return nil
        }
        return firstFrame(
            from: snapshot,
            projectURL: projectURL,
            source: .launchSnapshot,
            loadMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
            summary: summary
        )
    }

    private static func loadProjectPreviewFirstFrame(
        projectURL: URL,
        usesAutosaveRecovery: Bool,
        waveformOverviewDiskCache: WaveformOverviewDiskCacheStore
    ) -> ProjectLaunchFirstFrame? {
        let startedAt = CACurrentMediaTime()
        let byteLimit = usesAutosaveRecovery ?
            savedProjectSynchronousByteLimit :
            recoveredAutosaveSynchronousByteLimit
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: projectURL.path),
            let fileSize = (attributes[.size] as? NSNumber)?.intValue,
            fileSize > 0,
            fileSize <= byteLimit
        else {
            return nil
        }

        guard
            let project = try? (usesAutosaveRecovery ?
                SoundtimeProjectStore.loadLaunchPreviewRecoveringAutosave(from: projectURL) :
                SoundtimeProjectStore.loadLaunchPreview(from: projectURL))
        else {
            return nil
        }

        let hydratedProject = ProjectLaunchPreviewWaveformCacheHydrator.hydratedProject(
            project,
            waveformOverviewDiskCache: waveformOverviewDiskCache
        )
        let summary = ProjectLaunchReadinessClassifier.summarize(project: hydratedProject)
        guard summary.hasTracks else {
            return nil
        }
        return firstFrame(
            from: hydratedProject,
            projectURL: projectURL,
            source: usesAutosaveRecovery ? .savedProjectPreview : .recoveredAutosavePreview,
            loadMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
            summary: summary
        )
    }

    private static func firstFrame(
        from packet: ProjectFirstFrameWaveformPacket,
        projectURL: URL,
        source: ProjectLaunchFirstFrame.Source,
        loadMilliseconds: Double,
        summary: ProjectLaunchVisualReadinessSummary
    ) -> ProjectLaunchFirstFrame {
        ProjectLaunchFirstFrame(
            projectURL: projectURL,
            source: source,
            loadMilliseconds: loadMilliseconds,
            projectID: packet.projectID,
            editGraphRevision: packet.editGraphRevision,
            visualRevision: packet.visualRevision,
            launchStateRevision: packet.launchStateRevision,
            windowLayout: packet.windowLayout,
            timelineViewport: packet.timelineViewport,
            masterVolume: packet.masterVolume,
            transcriptDisplayMode: packet.transcriptDisplayMode,
            tracks: packet.tracks.map(track(from:)),
            summary: summary
        )
        .applyingOverlay(SoundtimeProjectStore.rememberedLaunchStateOverlay(for: projectURL))
    }

    private static func firstFrame(
        from snapshot: ProjectLaunchSnapshot,
        projectURL: URL,
        source: ProjectLaunchFirstFrame.Source,
        loadMilliseconds: Double,
        summary: ProjectLaunchVisualReadinessSummary
    ) -> ProjectLaunchFirstFrame {
        ProjectLaunchFirstFrame(
            projectURL: projectURL,
            source: source,
            loadMilliseconds: loadMilliseconds,
            projectID: snapshot.projectID,
            editGraphRevision: snapshot.editGraphRevision,
            visualRevision: snapshot.visualRevision,
            launchStateRevision: snapshot.launchStateRevision,
            windowLayout: snapshot.windowLayout,
            timelineViewport: snapshot.timelineViewport,
            masterVolume: snapshot.masterVolume,
            transcriptDisplayMode: snapshot.transcriptDisplayMode,
            tracks: snapshot.tracks.map(track(from:)),
            summary: summary
        )
        .applyingOverlay(SoundtimeProjectStore.rememberedLaunchStateOverlay(for: projectURL))
    }

    private static func firstFrame(
        from manifest: ProjectLaunchManifest,
        projectURL: URL,
        source: ProjectLaunchFirstFrame.Source,
        loadMilliseconds: Double,
        summary: ProjectLaunchVisualReadinessSummary
    ) -> ProjectLaunchFirstFrame {
        ProjectLaunchFirstFrame(
            projectURL: projectURL,
            source: source,
            loadMilliseconds: loadMilliseconds,
            projectID: manifest.projectID,
            editGraphRevision: manifest.editGraphRevision,
            visualRevision: manifest.visualRevision,
            launchStateRevision: manifest.launchStateRevision,
            windowLayout: manifest.windowLayout,
            timelineViewport: manifest.timelineViewport,
            masterVolume: manifest.masterVolume,
            transcriptDisplayMode: manifest.transcriptDisplayMode,
            tracks: manifest.tracks.map(track(from:)),
            summary: summary
        )
        .applyingOverlay(SoundtimeProjectStore.rememberedLaunchStateOverlay(for: projectURL))
    }

    private static func firstFrame(
        from project: SoundtimeProject,
        projectURL: URL,
        source: ProjectLaunchFirstFrame.Source,
        loadMilliseconds: Double,
        summary: ProjectLaunchVisualReadinessSummary
    ) -> ProjectLaunchFirstFrame {
        ProjectLaunchFirstFrame(
            projectURL: projectURL,
            source: source,
            loadMilliseconds: loadMilliseconds,
            projectID: project.projectID,
            editGraphRevision: project.editGraphRevision,
            visualRevision: project.visualRevision,
            launchStateRevision: project.launchStateRevision,
            windowLayout: project.windowLayout,
            timelineViewport: project.timelineViewport,
            masterVolume: project.masterVolume,
            transcriptDisplayMode: project.transcriptDisplayMode,
            tracks: project.tracks.map(track(from:)),
            summary: summary
        )
        .applyingOverlay(SoundtimeProjectStore.rememberedLaunchStateOverlay(for: projectURL))
    }

    private static func track(from track: ProjectFirstFrameWaveformPacket.Track) -> ProjectLaunchFirstFrame.Track {
        let previewDisplayOverview = track.displayWaveformOverview
        return ProjectLaunchFirstFrame.Track(
            id: track.id,
            editGroupID: track.editGroupID,
            name: track.name,
            sourceURL: URL(fileURLWithPath: track.filePath).standardizedFileURL,
            durationHint: durationHint(
                explicit: track.durationHint,
                displayOverview: previewDisplayOverview,
                sourceOverview: previewDisplayOverview,
                editTimeline: track.editTimeline,
                editableSource: track.editableSource
            ),
            sourceWaveformOverview: previewDisplayOverview,
            displayWaveformOverview: previewDisplayOverview,
            editTimeline: track.editTimeline,
            editableSource: track.editableSource,
            ownsSourceFile: track.ownsSourceFile,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            transcript: nil
        )
    }

    private static func track(from track: ProjectLaunchSnapshot.Track) -> ProjectLaunchFirstFrame.Track {
        let previewSourceOverview = track.sourceWaveformOverview
        let previewDisplayOverview = track.displayWaveformOverview
        return ProjectLaunchFirstFrame.Track(
            id: track.id,
            editGroupID: track.editGroupID,
            name: track.name,
            sourceURL: URL(fileURLWithPath: track.filePath).standardizedFileURL,
            durationHint: durationHint(
                explicit: track.durationHint,
                displayOverview: previewDisplayOverview,
                sourceOverview: previewSourceOverview,
                editTimeline: track.editTimeline,
                editableSource: track.editableSource
            ),
            sourceWaveformOverview: previewSourceOverview,
            displayWaveformOverview: previewDisplayOverview ?? previewSourceOverview,
            editTimeline: track.editTimeline,
            editableSource: track.editableSource,
            ownsSourceFile: track.ownsSourceFile,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            transcript: nil
        )
    }

    private static func track(from track: ProjectLaunchManifest.TrackShell) -> ProjectLaunchFirstFrame.Track {
        ProjectLaunchFirstFrame.Track(
            id: track.id,
            editGroupID: track.editGroupID,
            name: track.name,
            sourceURL: URL(fileURLWithPath: track.filePath).standardizedFileURL,
            durationHint: track.durationHint,
            sourceWaveformOverview: nil,
            displayWaveformOverview: nil,
            editTimeline: nil,
            editableSource: nil,
            ownsSourceFile: nil,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            transcript: nil
        )
    }

    private static func track(from track: SoundtimeProject.Track) -> ProjectLaunchFirstFrame.Track {
        let previewSourceOverview = track.waveformPreview?.sourceOverview.waveformOverview
        let previewDisplayOverview = track.waveformPreview?.displayOverview.waveformOverview
        return ProjectLaunchFirstFrame.Track(
            id: track.id,
            editGroupID: track.editGroupID,
            name: track.name,
            sourceURL: URL(fileURLWithPath: track.filePath).standardizedFileURL,
            durationHint: durationHint(
                explicit: nil,
                displayOverview: previewDisplayOverview,
                sourceOverview: previewSourceOverview,
                editTimeline: track.editTimeline,
                editableSource: track.editableSource
            ),
            sourceWaveformOverview: previewSourceOverview,
            displayWaveformOverview: previewDisplayOverview ?? previewSourceOverview,
            editTimeline: track.editTimeline,
            editableSource: track.editableSource,
            ownsSourceFile: track.ownsSourceFile,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            transcript: track.transcript
        )
    }

    private static func durationHint(
        explicit: TimeInterval?,
        displayOverview: WaveformOverview?,
        sourceOverview: WaveformOverview?,
        editTimeline: AudioFileEditTimeline.PersistentState?,
        editableSource: SoundtimeProject.Track.EditableSource?
    ) -> TimeInterval? {
        explicit ??
            displayOverview?.duration ??
            sourceOverview?.duration ??
            editTimelineDuration(from: editTimeline) ??
            editableDuration(from: editableSource)
    }

    private static func editTimelineDuration(
        from state: AudioFileEditTimeline.PersistentState?
    ) -> TimeInterval? {
        guard
            let state,
            state.sourceSampleRate > 0,
            state.sourceSampleRate.isFinite
        else {
            return nil
        }

        let frameCount = state.segments.reduce(0) { total, segment in
            total + max(segment.frameCount, 0)
        }
        return Double(frameCount) / state.sourceSampleRate
    }

    private static func editableDuration(from source: SoundtimeProject.Track.EditableSource?) -> TimeInterval? {
        guard
            let source,
            source.sourceSampleRate > 0,
            source.sourceSampleRate.isFinite
        else {
            return nil
        }
        return Double(source.sourceFrameCount) / source.sourceSampleRate
    }
}
