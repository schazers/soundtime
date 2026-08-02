import AppKit
import QuartzCore
import UniformTypeIdentifiers

struct WorkspaceStartupCloseSmokeSnapshot: Sendable {
    var trackCount: Int
    var drawableWaveformTrackCount: Int
    var durationOnlyTrackCount: Int
    var blankTrackCount: Int
    var placeholderTrackCount: Int
    var mutedTrackCount: Int
    var soloedTrackCount: Int
    var readinessDescription: String
    var isVisualReady: Bool
    var playbackHasSource: Bool
    var playbackPrimedTrackCount: Int
    var isLaunchVisualPreviewPendingImmediateRender: Bool
    var isDeferredProjectRestorePending: Bool
    var isLoadingProject: Bool
    var hasCurrentProjectURL: Bool
    var isLaunchSnapshotWriteScheduled: Bool
    var isLaunchCacheWriteInFlight: Bool
    var hasPendingLaunchCacheWrite: Bool
    var pendingDeferredEditWorkCount: Int
    var pendingDeferredWorkspaceWorkCount: Int
    var statusText: String
}

struct WorkspaceUserPerceivedTimingSmokeSnapshot: Sendable {
    var trackCount: Int
    var drawableWaveformTrackCount: Int
    var playbackHasSource: Bool
    var playbackPrimedTrackCount: Int
    var isPlaying: Bool
    var playheadProgress: Float
    var selectedRangeStartProgress: Double?
    var selectedRangeEndProgress: Double?
    var selectedTrackID: UUID?
    var hasClipboard: Bool
    var editAnimationGeneration: Int
    var projectDuration: TimeInterval
    var currentProjectPath: String?
    var statusText: String
}

struct WorkspaceUserPerceivedTimingSmokeResult: Sendable {
    var accepted: Bool
    var elapsedMilliseconds: Double
    var message: String
    var editAnimationGenerationChanged: Bool
    var visualResponseMilliseconds: Double? = nil
    var expectedLeadingProgress: Double? = nil
    var renderedLeadingProgress: Double? = nil
    var selectionEdgeErrorPixels: Double? = nil
    var motionDirection: Double? = nil
    var isIntentionalSelectionCollapse = false
}

private struct EditTransactionStageTimings {
    var planMilliseconds = 0.0
    var prepareMilliseconds = 0.0
    var effectsMilliseconds = 0.0
    var commitMilliseconds = 0.0
    var finalizeMilliseconds = 0.0
}

private struct EditCommitStageTimings {
    var captureMilliseconds = 0.0
    var mutationMilliseconds = 0.0
    var renderProjectionMilliseconds = 0.0
    var playbackProjectionMilliseconds = 0.0
    var playbackMilliseconds = 0.0
    var historyMilliseconds = 0.0
}

private struct EditHistoryRestoreStageTimings {
    var indexMilliseconds = 0.0
    var tracksMilliseconds = 0.0
    var modelMilliseconds = 0.0
    var timelineMilliseconds = 0.0
    var playbackMilliseconds = 0.0
    var finalizeMilliseconds = 0.0
}

struct WorkspaceVisualInvariantSmokeSnapshot: Codable, Sendable {
    struct Track: Codable, Sendable {
        var id: UUID
        var name: String
        var hasDrawableWaveform: Bool
        var hasDurationHintOnly: Bool
        var isPlaceholder: Bool
        var isMuted: Bool
        var isSoloed: Bool
        var durationSeconds: TimeInterval
        var waveformBinCount: Int
        var sourceWaveformBinCount: Int
        var transcriptWordCount: Int
    }

    var trackCount: Int
    var drawableWaveformTrackCount: Int
    var durationOnlyTrackCount: Int
    var blankTrackCount: Int
    var placeholderTrackCount: Int
    var mutedTrackCount: Int
    var soloedTrackCount: Int
    var readinessDescription: String
    var isVisualReady: Bool
    var playbackHasSource: Bool
    var playbackPrimedTrackCount: Int
    var isLoadingProject: Bool
    var playheadProgress: Float
    var projectDurationSeconds: TimeInterval
    var selectedRangeStartProgress: Double?
    var selectedRangeEndProgress: Double?
    var selectedTrackID: UUID?
    var selectedDurationSeconds: TimeInterval?
    var hasClipboard: Bool
    var editAnimationGeneration: Int
    var transcriptLayerVisible: Bool
    var transcriptTrackCount: Int
    var transcriptWordCount: Int
    var activeTranscriptWordID: UUID?
    var timelineViewportStartProgress: Float?
    var timelineViewportDurationProgress: Float?
    var timelinePresentationDurationSeconds: TimeInterval
    var timelinePresentationMatchesProject: Bool
    var currentProjectPath: String?
    var statusText: String
    var tracks: [Track]
}

struct WorkspaceHotPathContractFrameStatsSnapshot: Codable, Sendable {
    var framesPerSecond: Int
    var displayRefreshFramesPerSecond: Int
    var averageFrameTimeMilliseconds: Double
    var frameTimeJitterMilliseconds: Double
    var worstFrameTimeMilliseconds: Double
    var waveformRenderer: String
    var cpuWaveformVertexCount: Int
    var gpuWaveformDrawCount: Int
    var shaderBufferUploadCount: Int
    var shaderBufferUploadByteCount: Int
    var shaderBufferUploadInFlightCount: Int
    var cpuWaveformFallbackDrawCount: Int
    var waveformFallbackDrawCount: Int
    var waveformLastGoodHoldCount: Int
    var waveformResidentMissCount: Int
    var waveformHotPathViolationCount: Int
    var waveformHotPathReason: String
    var effectVertexCount: Int
    var effectDroppedVertexCount: Int
    var deletionEffectCount: Int

    init(_ stats: TimelineFrameStats) {
        framesPerSecond = stats.framesPerSecond
        displayRefreshFramesPerSecond = stats.displayRefreshFramesPerSecond
        averageFrameTimeMilliseconds = stats.averageFrameTimeMilliseconds
        frameTimeJitterMilliseconds = stats.frameTimeJitterMilliseconds
        worstFrameTimeMilliseconds = stats.worstFrameTimeMilliseconds
        waveformRenderer = stats.waveformRenderer
        cpuWaveformVertexCount = stats.cpuWaveformVertexCount
        gpuWaveformDrawCount = stats.gpuWaveformDrawCount
        shaderBufferUploadCount = stats.shaderBufferUploadCount
        shaderBufferUploadByteCount = stats.shaderBufferUploadByteCount
        shaderBufferUploadInFlightCount = stats.shaderBufferUploadInFlightCount
        cpuWaveformFallbackDrawCount = stats.cpuWaveformFallbackDrawCount
        waveformFallbackDrawCount = stats.waveformFallbackDrawCount
        waveformLastGoodHoldCount = stats.waveformLastGoodHoldCount
        waveformResidentMissCount = stats.waveformResidentMissCount
        waveformHotPathViolationCount = stats.waveformHotPathViolationCount
        waveformHotPathReason = stats.waveformHotPathReason
        effectVertexCount = stats.effectVertexCount
        effectDroppedVertexCount = stats.effectDroppedVertexCount
        deletionEffectCount = stats.deletionEffectCount
    }
}

struct WorkspaceHotPathContractSmokeSnapshot: Codable, Sendable {
    var trackCount: Int
    var drawableWaveformTrackCount: Int
    var blankTrackCount: Int
    var isLoadingProject: Bool
    var playbackHasSource: Bool
    var playbackPrimedTrackCount: Int
    var isLaunchSnapshotWriteScheduled: Bool
    var isLaunchCacheWriteInFlight: Bool
    var hasPendingLaunchCacheWrite: Bool
    var isAutosaveScheduled: Bool
    var autosaveScheduleReason: String
    var frameStats: WorkspaceHotPathContractFrameStatsSnapshot?
    var transcriptOverlay: TimelineTranscriptOverlayDiagnosticsSnapshot
    var performanceDashboard: PerformanceDashboardDiagnosticsSnapshot
    var mainThreadStallCount: Int
    var lastMainThreadStallMilliseconds: Double
    var warningEventCount: Int
    var severeEventCount: Int
    var diagnosticEventNames: [String]
    var latestUndoRestoreStageMilliseconds: [String: Double]
    var lastPlaybackReloadErrorDescription: String?
    var statusText: String
}

final class WorkspaceView: NSView {
    private static var defaultDebugToolsVisible: Bool {
        #if DEBUG
        let isAutomatedInteractionReplay =
            CommandLine.arguments.contains("--interaction-replay-smoke")
        return
            ProcessInfo.processInfo.environment["SOUNDTIME_SHIPPABILITY_GATE"] != "1" &&
            !isAutomatedInteractionReplay
        #else
        false
        #endif
    }

    private enum FisheyeDefaults {
        static let radius = 0.080
        static let power = 0.50
        static let start = 1.0
        static let full = 150.0
        static let curve = 1.0
        static let activationMilliseconds = 111.0
    }

    private enum FadeEffect {
        case fadeIn
        case fadeOut

        var displayName: String {
            switch self {
            case .fadeIn:
                return "fade in"
            case .fadeOut:
                return "fade out"
            }
        }
    }

    private enum LastEffect {
        case gain(decibels: Double)
        case normalize
        case denoise
        case separateMusicStems
        case fade(FadeEffect)
    }

    private enum ProjectTrackMixPublication {
        case immediate
        case coalesced
    }

    private enum EditScope: Int, CaseIterable {
        case track = 0
        case selected = 1
        case group = 2
        case all = 3

        var title: String {
            switch self {
            case .track:
                return "Track"
            case .selected:
                return "Selected"
            case .group:
                return "Group"
            case .all:
                return "All"
            }
        }
    }

    private struct ProjectTrackUndoSnapshot {
        var tracks: [ProjectTrack]
        var editGraph: EditGraph? = nil
        var renderTracks: [TimelineRenderState.Track]? = nil
        var playbackTracks: [ProjectPlaybackTrack]? = nil
        var activeTrackID: UUID?
        var selectedTrackID: UUID?
        var selectedTrackIDs: Set<UUID> = []
        var selectedTimelineRange: TimelineSelection?
        var restoreProgress: Float?
    }

    private struct ProjectEditTransactionState {
        let revision: EditRevision
        var tracksByID: [UUID: ProjectTrack]
        let trackIndexesByID: [UUID: Int]
        let projectTrackIDs: [UUID]
        let projectDuration: TimeInterval
        let displayedSampleRate: Double
        let displayedFrameCount: Int
        let editGraph: EditGraph
        let renderTracks: [TimelineRenderState.Track]
        let playbackTracks: [ProjectPlaybackTrack]
        let activeTrackID: UUID?
        let selectedTrackID: UUID?
        let selectedTrackIDs: Set<UUID>
        let selectedTimelineRange: TimelineSelection?
        let playheadTime: ProjectTime
        let clipboard: AudioClipboard?
    }

    private struct ProjectEditTransactionRecord {
        let command: EditCommand
        var before: ProjectEditTransactionState
        var after: ProjectEditTransactionState
    }

    private struct PreparedProjectEditCommit {
        let plan: EditPlan
        let tracksByID: [UUID: ProjectTrack]
        var trackIndexesByID: [UUID: Int] = [:]
        let editGraph: EditGraph
        let selectedTimelineRange: TimelineSelection?
        let clipboard: AudioClipboard?
    }

    private struct PortablePasteRenderedAsset: Sendable {
        let url: URL
        let fileInfo: WAVFileInfo
    }

    private enum PortablePasteSource: Sendable {
        case decoded(
            DecodedAudioBuffer,
            [AudioEditTimeline.PlaybackSegment],
            Float
        )
        case file(
            URL,
            WAVFileInfo,
            [AudioEditTimeline.PlaybackSegment],
            Float
        )

        var sampleRate: Double {
            switch self {
            case let .decoded(buffer, _, _):
                buffer.sampleRate
            case let .file(_, fileInfo, _, _):
                fileInfo.sampleRate
            }
        }

        var segments: [AudioEditTimeline.PlaybackSegment] {
            switch self {
            case let .decoded(_, segments, _), let .file(_, _, segments, _):
                segments
            }
        }

        var gain: Float {
            switch self {
            case let .decoded(_, _, gain), let .file(_, _, _, gain):
                gain
            }
        }
    }

    private enum PortablePastePreparationResult: Sendable {
        case success(PortablePasteRenderedAsset)
        case failure(String)
        case canceled
    }

    private final class PortablePastePreparationJob: @unchecked Sendable {
        private let lock = NSLock()
        private var isCanceled = false

        func cancel() {
            lock.lock()
            isCanceled = true
            lock.unlock()
        }

        func checkCancellation() throws {
            lock.lock()
            let canceled = isCanceled
            lock.unlock()
            if canceled {
                throw CancellationError()
            }
        }
    }

    private struct AudioImportPrewarm {
        let url: URL
        let admissionTask: Task<AudioImportAdmission, Error>?
        let previewTask: Task<AudioAssetPreviewResult, Error>?
        let preparationTask: Task<AudioAssetProxyResult, Error>?
    }

    private enum LaunchWaveformCache {
        // First paint still comes from saved project previews. Once the shell is on
        // screen, project restore may synchronously read only this bounded binary
        // sidecar level; larger overviews are promoted asynchronously.
        static let synchronousBinLimit = 131_072
        static let firstRefinementBinCount = 131_072
        static let firstRefinementSamplesPerBin = 32
    }

    private func editableAudioSource(
        originalURL: URL,
        editableURL: URL,
        formatOrigin: AudioAssetFormat,
        fileInfo: WAVFileInfo,
        ownsEditableFile: Bool,
        importedAssetID: UUID? = nil
    ) -> EditableAudioSource {
        EditableAudioSource(
            importedAssetID: importedAssetID,
            originalURL: originalURL,
            editableURL: editableURL,
            formatOrigin: formatOrigin,
            fileInfo: fileInfo,
            ownsEditableFile: ownsEditableFile
        )
    }

    private func mirroredTrackArrangement(for track: ProjectTrack) -> TrackArrangement? {
        guard
            let editableSource = track.editableSource,
            let fileTimeline = track.fileTimeline,
            editableSource.isCompatible(with: fileTimeline)
        else {
            return nil
        }

        return TrackArrangement(
            trackID: track.id,
            sourceID: editableSource.id,
            timeline: fileTimeline
        )
    }

    private func trackArrangement(for track: ProjectTrack) -> TrackArrangement? {
        if
            let arrangement = projectEditGraph.arrangement(for: track.id),
            let source = projectEditGraph.source(for: arrangement),
            source.isCompatible(with: arrangement.timeline)
        {
            return arrangement
        }

        return mirroredTrackArrangement(for: track)
    }

    private func hasNormalizedEditableTimeline(_ track: ProjectTrack) -> Bool {
        trackArrangement(for: track) != nil
    }

    private func hasEditableTimelineState(_ track: ProjectTrack) -> Bool {
        hasNormalizedEditableTimeline(track) || track.audioTimeline != nil
    }

    private func currentEditGraph() -> EditGraph {
        var graph = EditGraph(
            sources: projectTracks.compactMap(\.editableSource),
            arrangements: projectTracks.compactMap(mirroredTrackArrangement)
        )
        graph.merge(projectEditGraph)
        graph.keepOnlyArrangements(for: Set(projectTracks.map(\.id)))
        return graph
    }

    private func rebuildProjectEditGraphFromTrackMirrors() {
        projectEditGraph = EditGraph(
            sources: projectTracks.compactMap(\.editableSource),
            arrangements: projectTracks.compactMap(mirroredTrackArrangement)
        )
    }

    private func applyEditableTimelineMirror(
        trackIndex: Int,
        source: EditableAudioSource,
        timeline: AudioFileEditTimeline,
        clearsDecodedAudio: Bool = true
    ) {
        guard projectTracks.indices.contains(trackIndex) else {
            return
        }

        let trackID = projectTracks[trackIndex].id
        projectEditGraph.upsert(source: source, trackID: trackID, timeline: timeline)
        projectTracks[trackIndex].editableSource = source
        projectTracks[trackIndex].fileTimeline = timeline
        projectTracks[trackIndex].audioTimeline = nil
        if clearsDecodedAudio {
            projectTracks[trackIndex].decodedAudioBuffer = nil
        }
        projectTracks[trackIndex].durationHint = timeline.duration
    }

    private func applyEditableTimelineMirror(
        trackIndex: Int,
        timeline: AudioFileEditTimeline,
        clearsDecodedAudio: Bool = true
    ) {
        guard
            projectTracks.indices.contains(trackIndex),
            let source = projectTracks[trackIndex].editableSource ?? projectEditGraph.source(for: projectTracks[trackIndex].id),
            source.isCompatible(with: timeline)
        else {
            return
        }

        applyEditableTimelineMirror(
            trackIndex: trackIndex,
            source: source,
            timeline: timeline,
            clearsDecodedAudio: clearsDecodedAudio
        )
    }

    private func removeEditableArrangementMirror(forTrackID trackID: UUID) {
        projectEditGraph.removeArrangement(for: trackID)
        guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        projectTracks[trackIndex].editableSource = nil
        projectTracks[trackIndex].fileTimeline = nil
    }

    private func pruneProjectEditGraphToCurrentTracks() {
        projectEditGraph.keepOnlyArrangements(for: Set(projectTracks.map(\.id)))
    }

    private func applyEditedTimelineState(
        trackIndex: Int,
        editedAudioTimeline: AudioEditTimeline?,
        editedFileTimeline: AudioFileEditTimeline?,
        editedDuration: TimeInterval,
        decodedAudioBuffer: DecodedAudioBuffer? = nil
    ) {
        guard projectTracks.indices.contains(trackIndex) else {
            return
        }

        if let editedFileTimeline {
            applyEditableTimelineMirror(
                trackIndex: trackIndex,
                timeline: editedFileTimeline
            )
        } else {
            let trackID = projectTracks[trackIndex].id
            projectEditGraph.removeArrangement(for: trackID)
            projectTracks[trackIndex].audioTimeline = editedAudioTimeline
            projectTracks[trackIndex].fileTimeline = nil
            projectTracks[trackIndex].editableSource = nil
            projectTracks[trackIndex].decodedAudioBuffer = decodedAudioBuffer
            projectTracks[trackIndex].durationHint = editedDuration
        }
    }

    private func projectEditRevision() -> EditRevision {
        EditRevision(rawValue: max(currentEditGraphRevision, 1))
    }

    private func currentProjectPlayheadTime() -> ProjectTime {
        let snapshot = playbackController.snapshot()
        let duration = max(projectSelectionDuration, displayedDuration, 0)
        return ProjectTime(seconds: Double(snapshot.progress) * duration)
    }

    private func captureProjectEditTransactionState(
        trackIDs: Set<UUID>,
        trackIndexesByID providedTrackIndexesByID: [UUID: Int]? = nil,
        playheadTime: ProjectTime? = nil,
        projectDuration providedProjectDuration: TimeInterval? = nil,
        renderTracks: [TimelineRenderState.Track]? = nil,
        playbackTracks: [ProjectPlaybackTrack]? = nil
    ) -> ProjectEditTransactionState {
        let targetTracks: [(Int, ProjectTrack)]
        if let providedTrackIndexesByID {
            targetTracks = providedTrackIndexesByID.values.sorted().compactMap { index in
                guard projectTracks.indices.contains(index) else {
                    return nil
                }
                let track = projectTracks[index]
                return trackIDs.contains(track.id) ? (index, track) : nil
            }
        } else {
            targetTracks = projectTracks.enumerated().compactMap { index, track in
                trackIDs.contains(track.id) ? (index, track) : nil
            }
        }
        let projectDuration = providedProjectDuration ?? projectSelectionDuration
        let sampleRate = displayedSampleRate > 0 ?
            displayedSampleRate :
            projectTracks.compactMap {
                $0.fileTimeline?.sourceSampleRate ??
                    $0.audioTimeline?.sourceAudioBuffer.sampleRate ??
                    $0.decodedAudioBuffer?.sampleRate
            }.first ?? 0
        let mixes = projectPlaybackTrackMixes()
        let capturedRenderTracks = applyingProjectTrackMixes(
            mixes,
            to: renderTracks ??
                (publishedTimelineRenderTracks.count == projectTracks.count ?
                    publishedTimelineRenderTracks :
                    timelineRenderTracks())
        )
        let capturedPlaybackTracks = ProjectPlaybackProjection.applyingMixes(
            mixes,
            to: playbackTracks ??
                (publishedProjectPlaybackTracks.count == projectTracks.count ?
                    publishedProjectPlaybackTracks :
                    projectPlaybackTracks())
        )
        return ProjectEditTransactionState(
            revision: projectEditRevision(),
            tracksByID: Dictionary(
                uniqueKeysWithValues: targetTracks.map { ($0.1.id, $0.1) }
            ),
            trackIndexesByID: Dictionary(
                uniqueKeysWithValues: targetTracks.map { ($0.1.id, $0.0) }
            ),
            projectTrackIDs: projectTracks.map(\.id),
            projectDuration: projectDuration,
            displayedSampleRate: sampleRate,
            displayedFrameCount: projectDuration > 0 && sampleRate > 0 ?
                Int((projectDuration * sampleRate).rounded(.up)) :
                0,
            editGraph: projectEditGraph,
            renderTracks: capturedRenderTracks,
            playbackTracks: capturedPlaybackTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            playheadTime: playheadTime ?? currentProjectPlayheadTime(),
            clipboard: audioClipboard
        )
    }

    private func transactionRenderTracks(
        replacing changedTrackIDs: Set<UUID>
    ) -> [TimelineRenderState.Track] {
        let previousTracksByID = Dictionary(
            uniqueKeysWithValues: publishedTimelineRenderTracks.map { ($0.id, $0) }
        )
        let mixesByID = Dictionary(
            uniqueKeysWithValues: projectPlaybackTrackMixes().map { ($0.id, $0) }
        )
        return projectTracks.map { projectTrack in
            guard
                let previousTrack = previousTracksByID[projectTrack.id],
                !changedTrackIDs.contains(projectTrack.id)
            else {
                return timelineRenderTrack(for: projectTrack)
            }
            guard let mix = mixesByID[projectTrack.id] else {
                return previousTrack
            }
            return previousTrack.applying(mix)
        }
    }

    private func transactionPlaybackTracks(
        replacing changedTrackIDs: Set<UUID>
    ) -> [ProjectPlaybackTrack] {
        let previousTracksByID = Dictionary(
            uniqueKeysWithValues: publishedProjectPlaybackTracks.map { ($0.id, $0) }
        )
        let mixesByID = Dictionary(
            uniqueKeysWithValues: projectPlaybackTrackMixes().map { ($0.id, $0) }
        )
        return projectTracks.compactMap { projectTrack in
            guard
                let previousTrack = previousTracksByID[projectTrack.id],
                !changedTrackIDs.contains(projectTrack.id)
            else {
                return projectPlaybackTrack(for: projectTrack)
            }
            guard let mix = mixesByID[projectTrack.id] else {
                return previousTrack
            }
            return previousTrack.applying(mix)
        }
    }

    private func editTrackDescriptor(for track: ProjectTrack) -> EditTrackDescriptor {
        let sampleRate: Double
        let frameCount: Int
        if let fileTimeline = track.fileTimeline {
            sampleRate = fileTimeline.sourceSampleRate
            frameCount = fileTimeline.frameCount
        } else if let audioTimeline = track.audioTimeline {
            sampleRate = audioTimeline.sourceAudioBuffer.sampleRate
            frameCount = audioTimeline.frameCount
        } else if let buffer = track.decodedAudioBuffer {
            sampleRate = buffer.sampleRate
            frameCount = buffer.frameCount
        } else if let fileInfo = decodableWAVFileInfo(for: track.sourceURL) {
            sampleRate = fileInfo.sampleRate
            frameCount = fileInfo.frameCount
        } else {
            sampleRate = 0
            frameCount = 0
        }
        return EditTrackDescriptor(
            trackID: track.id,
            sampleRate: sampleRate,
            frameCount: frameCount,
            isEditable: hasEditableTimelineState(track)
        )
    }

    private func editTrackDescriptors(for command: EditCommand) -> [EditTrackDescriptor] {
        let targetTrackIDs = Set(command.targetTrackIDs)
        return projectTracks.compactMap { track in
            targetTrackIDs.contains(track.id) ? editTrackDescriptor(for: track) : nil
        }
    }

    private func projectEditRange(
        from displaySelection: TimelineSelection
    ) -> ProjectEditRange? {
        guard let timeRange = displaySelection.timeRange(in: projectSelectionDuration) else {
            return nil
        }
        return ProjectEditRange(
            start: ProjectTime(seconds: timeRange.lowerBound),
            end: ProjectTime(seconds: timeRange.upperBound)
        )
    }

    private var canonicalProjectTimelineDuration: TimeInterval {
        projectTracks.reduce(TimeInterval(0)) { duration, track in
            max(duration, trackDuration(for: track))
        }
    }

    private func timelinePresentationMatchesCanonicalProject() -> Bool {
        guard publishedTimelineEditRevision == currentEditGraphRevision else {
            return false
        }
        guard publishedTimelineRenderTracks.count == projectTracks.count else {
            return false
        }

        let canonicalDuration = canonicalProjectTimelineDuration
        let presentedDuration = timelineSurface.currentTimelineDuration
        guard abs(canonicalDuration - presentedDuration) <= 0.000_001 else {
            return false
        }

        for index in projectTracks.indices {
            let projectTrack = projectTracks[index]
            let renderTrack = publishedTimelineRenderTracks[index]
            guard renderTrack.id == projectTrack.id else {
                return false
            }
            let duration = trackDuration(for: projectTrack)
            guard abs((renderTrack.durationHint ?? 0) - duration) <= 0.000_001 else {
                return false
            }
            guard renderTrack.clipRanges == timelineClipRanges(for: projectTrack) else {
                return false
            }

            let renderPayload = waveformRenderPayload(for: projectTrack)
            let expectedSegments = renderPayload.usesSourceSegments ?
                waveformSegmentsForRendering(projectTrack) :
                []
            guard renderTrack.waveformSegments == expectedSegments else {
                return false
            }
        }

        return true
    }

    private func timelinePresentationRequiresReconciliation() -> Bool {
        guard timelinePresentationDirtyTrackIDs.isEmpty else {
            return true
        }
        guard publishedTimelineEditRevision == currentEditGraphRevision else {
            return true
        }
        guard publishedTimelineRenderTracks.count == projectTracks.count else {
            return true
        }
        guard
            zip(projectTracks, publishedTimelineRenderTracks).allSatisfy({
                $0.0.id == $0.1.id
            })
        else {
            return true
        }
        return abs(
            timelineSurface.currentTimelineDuration -
                canonicalProjectTimelineDuration
        ) > 0.000_001
    }

    private func publishCanonicalTimelinePresentation(
        replacingTrackAt replacementTrackIndex: Int? = nil,
        sampleRateHint: Double? = nil,
        reason: String,
        recordsDiagnosticEvent: Bool = true
    ) {
        let previousPresentationDuration = timelineSurface.currentTimelineDuration
        let preservedSelectionRange = selectedTimelineRange.flatMap { selection -> ProjectEditRange? in
            guard previousPresentationDuration > 0, selection.durationProgress > 0 else {
                return nil
            }
            return ProjectEditRange(
                start: ProjectTime(
                    seconds: selection.startProgress * previousPresentationDuration
                ),
                end: ProjectTime(
                    seconds: selection.endProgress * previousPresentationDuration
                )
            )
        }

        let nextRenderTracks: [TimelineRenderState.Track]
        if
            let replacementTrackIndex,
            projectTracks.indices.contains(replacementTrackIndex),
            publishedTimelineRenderTracks.count == projectTracks.count,
            publishedTimelineRenderTracks.indices.contains(replacementTrackIndex),
            publishedTimelineRenderTracks[replacementTrackIndex].id ==
                projectTracks[replacementTrackIndex].id
        {
            var renderTracks = publishedTimelineRenderTracks
            renderTracks[replacementTrackIndex] = timelineRenderTrack(
                for: projectTracks[replacementTrackIndex],
                reusing: renderTracks[replacementTrackIndex]
            )
            nextRenderTracks = renderTracks
        } else {
            let previousTracksByID = Dictionary(
                uniqueKeysWithValues: publishedTimelineRenderTracks.map { ($0.id, $0) }
            )
            nextRenderTracks = projectTracks.map { track in
                if let previousTrack = previousTracksByID[track.id] {
                    return timelineRenderTrack(for: track, reusing: previousTrack)
                }
                return timelineRenderTrack(for: track)
            }
        }

        updateProjectDisplayTiming(sampleRateHint: sampleRateHint)
        publishedTimelineRenderTracks = nextRenderTracks
        publishedTimelineEditRevision = currentEditGraphRevision
        if let replacementTrackIndex, projectTracks.indices.contains(replacementTrackIndex) {
            timelinePresentationDirtyTrackIDs.remove(projectTracks[replacementTrackIndex].id)
        } else {
            timelinePresentationDirtyTrackIDs.removeAll()
        }
        timelineSurface.displayTracks(
            nextRenderTracks,
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false,
            updatesRendererImmediately: true
        )

        if
            let previousSelection = selectedTimelineRange,
            let preservedSelectionRange,
            let trackID = previousSelection.trackID,
            projectTracks.contains(where: { $0.id == trackID })
        {
            let remappedSelection = displaySelection(
                for: preservedSelectionRange,
                trackID: trackID,
                projectDuration: max(
                    timelineSurface.currentTimelineDuration,
                    canonicalProjectTimelineDuration
                )
            )
            selectedTimelineRange = remappedSelection
            timelineSurface.displaySelection(remappedSelection)
        }

        if recordsDiagnosticEvent {
            SoundtimeDiagnostics.shared.record(
                category: .edit,
                severity: .info,
                name: "timeline-presentation-reconciled",
                message: "The visible timeline was reconciled with the canonical edit projection.",
                fields: [
                    "reason": reason,
                    "previousDuration": String(format: "%.6f", previousPresentationDuration),
                    "canonicalDuration": String(format: "%.6f", canonicalProjectTimelineDuration),
                    "tracks": "\(nextRenderTracks.count)",
                ]
            )
        }
    }

    private func reconcileTimelinePresentationBeforeEdit(
        preservesVisiblePlayheadTime: Bool = false,
        reason: String
    ) {
        guard timelinePresentationRequiresReconciliation() else {
            return
        }

        let previousPresentationDuration = timelineSurface.currentTimelineDuration
        let visiblePlayheadTime = previousPresentationDuration > 0 ?
            Double(visualPlayheadProgress) * previousPresentationDuration :
            currentProjectPlayheadTime().seconds

        publishCanonicalTimelinePresentation(reason: reason)

        guard preservesVisiblePlayheadTime else {
            return
        }
        let duration = max(canonicalProjectTimelineDuration, 0.000_001)
        let progress = Float(min(max(visiblePlayheadTime / duration, 0), 1))
        if playbackController.hasSource {
            try? playbackController.seek(toProgress: progress)
        }
        snapPlayheadVisuals(
            toTimelineTime: visiblePlayheadTime,
            isPlaying: playbackController.isPlaying,
            synchronizesRenderer: true
        )
    }

    private func displaySelection(
        for range: ProjectEditRange,
        trackID: UUID,
        projectDuration: TimeInterval? = nil
    ) -> TimelineSelection {
        let duration = max(
            projectDuration ?? projectSelectionDuration,
            range.end.seconds,
            0.000_001
        )
        return TimelineSelection(
            startProgress: min(max(range.start.seconds / duration, 0), 1),
            endProgress: min(max(range.end.seconds / duration, 0), 1),
            trackID: trackID
        )
    }

    private func transactionScope(_ scope: EditScope) -> EditCommandScope {
        switch scope {
        case .track:
            return .track
        case .selected:
            return .selected
        case .group:
            return .group
        case .all:
            return .all
        }
    }

    private func makeRangeEditCommand(
        kind: EditCommandKind,
        target: EditableSelectionTarget,
        scope: EditScope
    ) throws -> EditCommand {
        guard
            projectTracks.indices.contains(target.trackIndex),
            let range = projectEditRange(from: target.displaySelection)
        else {
            throw EditTransactionError.missingRange
        }

        let anchorTrackID = projectTracks[target.trackIndex].id
        let targetTrackIDs = scopedTrackIndices(
            anchorTrackIndex: target.trackIndex,
            scope: scope
        ).compactMap { trackIndex in
            projectTracks.indices.contains(trackIndex) ? projectTracks[trackIndex].id : nil
        }

        return EditCommand(
            baseRevision: projectEditRevision(),
            kind: kind,
            scope: transactionScope(scope),
            anchorTrackID: anchorTrackID,
            targetTrackIDs: targetTrackIDs,
            range: range,
            wasPlaying: playbackController.isPlaying,
            playheadTimeAtDispatch: currentProjectPlayheadTime()
        )
    }

    private func makePasteCommand(
        trackID: UUID,
        insertionTime: ProjectTime,
        clipboardID: UUID
    ) -> EditCommand {
        EditCommand(
            baseRevision: projectEditRevision(),
            kind: .paste,
            scope: .track,
            anchorTrackID: trackID,
            targetTrackIDs: [trackID],
            insertionTime: insertionTime,
            clipboardID: clipboardID,
            wasPlaying: playbackController.isPlaying,
            playheadTimeAtDispatch: currentProjectPlayheadTime()
        )
    }

    private func prepareRangeEditCommit(
        command: EditCommand,
        clipboard: AudioClipboard?,
        precomputedPlan: EditPlan? = nil
    ) throws -> PreparedProjectEditCommit {
        let plan = try precomputedPlan ?? EditTransactionPlanner.plan(
            command: command,
            currentRevision: projectEditRevision(),
            tracks: editTrackDescriptors(for: command)
        )
        var nextTracksByID: [UUID: ProjectTrack] = [:]
        nextTracksByID.reserveCapacity(plan.trackEdits.count)
        var nextGraph = currentEditGraph()
        let targetTrackIDs = Set(plan.trackEdits.map(\.trackID))
        let targetTrackIndexes = Dictionary(
            uniqueKeysWithValues: projectTracks.enumerated().compactMap { index, track in
                targetTrackIDs.contains(track.id) ? (track.id, index) : nil
            }
        )
        guard targetTrackIndexes.count == targetTrackIDs.count else {
            throw EditTransactionError.missingTrack(plan.command.anchorTrackID)
        }

        for trackEdit in plan.trackEdits {
            guard
                let trackIndex = targetTrackIndexes[trackEdit.trackID],
                projectTracks.indices.contains(trackIndex)
            else {
                throw EditTransactionError.missingTrack(trackEdit.trackID)
            }
            let currentTrack = projectTracks[trackIndex]
            var nextTrack = currentTrack
            let changedFrameCount: Int

            if var fileTimeline = nextGraph.arrangement(for: trackEdit.trackID)?.timeline ?? currentTrack.fileTimeline {
                switch trackEdit.mutation {
                case let .delete(frameRange):
                    changedFrameCount = fileTimeline.delete(frameRange: frameRange)
                case let .clear(frameRange):
                    changedFrameCount = fileTimeline.clear(frameRange: frameRange)
                case let .insert(frame):
                    guard let clipboard else {
                        throw EditTransactionError.missingClipboard
                    }
                    guard command.clipboardID == clipboard.id else {
                        throw EditTransactionError.clipboardIDMismatch
                    }
                    guard
                        let clipboardSourceID = clipboard.fileClipSourceID,
                        let fileClip = clipboard.fileClip
                    else {
                        throw EditTransactionError.missingFileClipboardClip
                    }
                    let destinationSourceID =
                        nextGraph.arrangement(for: trackEdit.trackID)?.sourceID ??
                        currentTrack.editableSource?.id
                    guard clipboardSourceID == destinationSourceID else {
                        throw EditTransactionError.incompatibleClipboardSource
                    }
                    guard let insertedFrameCount = fileTimeline.insert(fileClip, atFrame: frame) else {
                        throw EditTransactionError.incompatibleClipboardClip
                    }
                    changedFrameCount = insertedFrameCount
                }

                if case let .delete(frameRange) = trackEdit.mutation {
                    try validateChangedFrameCount(
                        trackID: trackEdit.trackID,
                        expected: frameRange.count,
                        actual: changedFrameCount
                    )
                } else if case let .clear(frameRange) = trackEdit.mutation {
                    try validateChangedFrameCount(
                        trackID: trackEdit.trackID,
                        expected: frameRange.count,
                        actual: changedFrameCount
                    )
                }

                nextTrack.fileTimeline = fileTimeline
                nextTrack.audioTimeline = nil
                nextTrack.decodedAudioBuffer = nil
                nextTrack.durationHint = fileTimeline.duration
                if let bestSourceOverview = bestSourceWaveformOverview(
                    sourceOverview: currentTrack.sourceWaveformOverview,
                    fallbackOverview: currentTrack.waveformOverview,
                    fileTimeline: fileTimeline
                ) {
                    nextTrack.sourceWaveformOverview = bestSourceOverview
                    nextTrack.waveformOverview = bestSourceOverview
                }
                guard let source = currentTrack.editableSource ?? nextGraph.source(for: trackEdit.trackID) else {
                    throw EditTransactionError.uneditableTrack(trackEdit.trackID)
                }
                nextTrack.editableSource = source
                nextGraph.upsert(
                    source: source,
                    trackID: trackEdit.trackID,
                    timeline: fileTimeline
                )
            } else if var audioTimeline = currentTrack.audioTimeline {
                switch trackEdit.mutation {
                case let .delete(frameRange):
                    changedFrameCount = audioTimeline.delete(frameRange: frameRange)
                case let .clear(frameRange):
                    changedFrameCount = audioTimeline.clear(frameRange: frameRange)
                case let .insert(frame):
                    guard let clipboard else {
                        throw EditTransactionError.missingClipboard
                    }
                    guard command.clipboardID == clipboard.id else {
                        throw EditTransactionError.clipboardIDMismatch
                    }
                    guard let audioClip = clipboard.audioClip else {
                        throw EditTransactionError.missingMemoryClipboardClip
                    }
                    guard let insertedFrameCount = audioTimeline.insert(audioClip, atFrame: frame) else {
                        throw EditTransactionError.incompatibleClipboardClip
                    }
                    changedFrameCount = insertedFrameCount
                }

                if case let .delete(frameRange) = trackEdit.mutation {
                    try validateChangedFrameCount(
                        trackID: trackEdit.trackID,
                        expected: frameRange.count,
                        actual: changedFrameCount
                    )
                } else if case let .clear(frameRange) = trackEdit.mutation {
                    try validateChangedFrameCount(
                        trackID: trackEdit.trackID,
                        expected: frameRange.count,
                        actual: changedFrameCount
                    )
                }

                nextTrack.audioTimeline = audioTimeline
                nextTrack.fileTimeline = nil
                nextTrack.editableSource = nil
                nextTrack.decodedAudioBuffer = audioTimeline.sourceAudioBuffer
                nextTrack.durationHint = audioTimeline.duration
                if
                    let sourceOverview = currentTrack.sourceWaveformOverview ?? currentTrack.waveformOverview,
                    abs(sourceOverview.duration - audioTimeline.sourceAudioBuffer.duration) <=
                        max(0.01, audioTimeline.sourceAudioBuffer.duration * 0.000_01)
                {
                    nextTrack.sourceWaveformOverview = sourceOverview
                    nextTrack.waveformOverview = sourceOverview
                }
                nextGraph.removeArrangement(for: trackEdit.trackID)
            } else {
                throw EditTransactionError.uneditableTrack(trackEdit.trackID)
            }

            nextTrack.editRevision += 1
            if let transcript = nextTrack.transcript {
                let timelineDuration = trackDuration(for: nextTrack)
                let timeMap = transcriptSourceTimeMap(
                    for: nextTrack,
                    timelineDuration: timelineDuration
                )
                nextTrack.transcript = TranscriptValidityPolicy.reconciledTranscript(
                    transcript,
                    currentSourceRevision: nextTrack.editRevision,
                    currentSourceFingerprint: transcriptSourceFingerprint(for: nextTrack),
                    timeMap: timeMap
                )
            }
            nextTracksByID[trackEdit.trackID] = nextTrack
        }

        let resultingSelection: TimelineSelection?
        if command.kind == .paste,
           let insertionTime = command.insertionTime,
           let clipboard,
           let insertedDuration = clipboardDuration(clipboard),
           let range = ProjectEditRange(
               start: insertionTime,
               end: insertionTime + ProjectTime(seconds: insertedDuration)
           )
        {
            let nextDuration = nextTracksByID.values.reduce(projectSelectionDuration) {
                max($0, trackDuration(for: $1))
            }
            resultingSelection = displaySelection(
                for: range,
                trackID: command.anchorTrackID,
                projectDuration: nextDuration
            )
        } else {
            resultingSelection = nil
        }

        return PreparedProjectEditCommit(
            plan: plan,
            tracksByID: nextTracksByID,
            trackIndexesByID: targetTrackIndexes,
            editGraph: nextGraph,
            selectedTimelineRange: resultingSelection,
            clipboard: clipboard
        )
    }

    private func validateChangedFrameCount(
        trackID: UUID,
        expected: Int,
        actual: Int
    ) throws {
        guard expected == actual else {
            throw EditTransactionError.changedFrameCount(
                trackID: trackID,
                expected: expected,
                actual: actual
            )
        }
    }

    private func clipboardDuration(_ clipboard: AudioClipboard) -> TimeInterval? {
        if let fileClip = clipboard.fileClip {
            return fileClip.duration
        }
        if let audioClip = clipboard.audioClip {
            return audioClip.duration
        }
        if let buffer = clipboard.buffer {
            return buffer.duration
        }
        return clipboard.waveformOverview.duration > 0 ? clipboard.waveformOverview.duration : nil
    }

    private func commitPreparedProjectEdit(
        _ preparedCommit: PreparedProjectEditCommit,
        keepsTransitionVisual: Bool
    ) throws -> ProjectEditTransactionRecord {
        let commitStartedAt = CACurrentMediaTime()
        let plan = preparedCommit.plan
        guard projectEditRevision() == plan.command.baseRevision else {
            throw EditTransactionError.staleRevision(
                expected: plan.command.baseRevision,
                actual: projectEditRevision()
            )
        }

        let targetTrackIDs = Set(plan.trackEdits.map(\.trackID))
        guard Set(preparedCommit.tracksByID.keys) == targetTrackIDs else {
            throw EditTransactionError.missingTrack(plan.command.anchorTrackID)
        }
        let targetTrackIndexes: [UUID: Int]
        if preparedCommit.trackIndexesByID.count == targetTrackIDs.count {
            targetTrackIndexes = preparedCommit.trackIndexesByID
        } else {
            targetTrackIndexes = try Dictionary(
                uniqueKeysWithValues: targetTrackIDs.map { trackID in
                    guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
                        throw EditTransactionError.missingTrack(trackID)
                    }
                    return (trackID, trackIndex)
                }
            )
        }
        let before = captureProjectEditTransactionState(
            trackIDs: targetTrackIDs,
            trackIndexesByID: targetTrackIndexes,
            playheadTime: plan.command.playheadTimeAtDispatch
        )
        let capturedAt = CACurrentMediaTime()

        for trackID in targetTrackIDs {
            guard
                let nextTrack = preparedCommit.tracksByID[trackID],
                let trackIndex = targetTrackIndexes[trackID]
            else {
                throw EditTransactionError.missingTrack(trackID)
            }
            projectTracks[trackIndex] = nextTrack
        }
        let mutatedAt = CACurrentMediaTime()

        projectEditGraph = preparedCommit.editGraph
        currentEditGraphRevision = plan.nextRevision.rawValue
        selectedTimelineRange = preparedCommit.selectedTimelineRange
        clearTranscriptInteractionStateIfNeeded(
            forTracks: preparedCommit.tracksByID.values
        )
        audioClipboard = preparedCommit.clipboard
        syncActiveTrackFields()
        let nextRenderTracks = transactionRenderTracks(replacing: targetTrackIDs)
        let renderProjectedAt = CACurrentMediaTime()
        let nextPlaybackTracks = transactionPlaybackTracks(replacing: targetTrackIDs)
        let projectedAt = CACurrentMediaTime()

        if keepsTransitionVisual {
            publishedTimelineEditRevision = plan.nextRevision.rawValue
        } else {
            updateProjectDisplayTiming()
            publishedTimelineRenderTracks = nextRenderTracks
            timelineSurface.displayTracks(
                nextRenderTracks,
                animateWaveformTransition: false,
                allowImmediateWaveformPrewarm: false,
                allowImmediateInteractiveWaveformPrewarm: false
            )
            publishSelectedTracksToTimeline()
            publishedTimelineEditRevision = plan.nextRevision.rawValue
        }

        let nextDuration = max(
            projectTracks.reduce(TimeInterval(0)) { duration, track in
                max(duration, trackDuration(for: track))
            },
            0.000_001
        )
        // Read the realtime clock only after the edited playback graph is ready
        // to publish. Mapping an earlier key-down timestamp would replay the
        // preparation interval whenever a running ripple edit rewinds time.
        let transportBeforePublish = playbackController.snapshot()
        let livePlayheadBeforePublish = ProjectTime(
            seconds: transportBeforePublish.projectTime ?? currentProjectPlayheadTime().seconds
        )
        let postEditPlayheadTime = EditTransactionPlanner.resolvedPlayheadTime(
            for: plan,
            resultingProjectDuration: nextDuration,
            livePlaybackTime: transportBeforePublish.isPlaying ? livePlayheadBeforePublish : nil
        )
        reloadPlaybackFromProjectTracks(
            preserveProgress: false,
            targetProgress: Float(min(max(postEditPlayheadTime.seconds / nextDuration, 0), 1)),
            resumeIfPlaying: transportBeforePublish.isPlaying,
            playbackTracksOverride: nextPlaybackTracks,
            publishesVisualState: false
        )
        publishedPlaybackEditRevision = plan.nextRevision.rawValue
        // A transition continues to draw the pre-edit timeline until its visual
        // handoff. Publishing playback's post-edit normalized progress here
        // would shift the playhead against the old timeline duration. Keep the
        // current presentation until the handoff can publish the new duration
        // and its matching live or paused playhead time together.
        if !keepsTransitionVisual {
            snapPlayheadVisuals(
                toTimelineTime: postEditPlayheadTime.seconds,
                isPlaying: playbackController.isPlaying,
                synchronizesRenderer: true
            )
        }
        updateTransportControlState(isPlaying: playbackController.isPlaying)
        let playbackPublishedAt = CACurrentMediaTime()

        let after = captureProjectEditTransactionState(
            trackIDs: targetTrackIDs,
            trackIndexesByID: targetTrackIndexes,
            playheadTime: postEditPlayheadTime,
            projectDuration: nextDuration,
            renderTracks: nextRenderTracks,
            playbackTracks: nextPlaybackTracks
        )
        let record = ProjectEditTransactionRecord(
            command: plan.command,
            before: before,
            after: after
        )
        editUndoStack.append(.transaction(record))
        assertPublishedEditRevisionsMatch(context: plan.command.kind.rawValue)
        recordEditTransactionCommit(plan)
        let finishedAt = CACurrentMediaTime()
        latestEditCommitStageTimings = EditCommitStageTimings(
            captureMilliseconds: (capturedAt - commitStartedAt) * 1_000,
            mutationMilliseconds: (mutatedAt - capturedAt) * 1_000,
            renderProjectionMilliseconds: (renderProjectedAt - mutatedAt) * 1_000,
            playbackProjectionMilliseconds: (projectedAt - renderProjectedAt) * 1_000,
            playbackMilliseconds: (playbackPublishedAt - projectedAt) * 1_000,
            historyMilliseconds: (finishedAt - playbackPublishedAt) * 1_000
        )
        return record
    }

    private func assertPublishedEditRevisionsMatch(context: String) {
        guard publishedTimelineEditRevision == publishedPlaybackEditRevision else {
            SoundtimeDiagnostics.shared.record(
                category: .edit,
                severity: .severe,
                name: "edit-publication-revision-mismatch",
                message: "Timeline and playback published different edit revisions.",
                fields: [
                    "context": context,
                    "projectRevision": "\(currentEditGraphRevision)",
                    "timelineRevision": "\(publishedTimelineEditRevision)",
                    "playbackRevision": "\(publishedPlaybackEditRevision)",
                ]
            )
            return
        }
    }

    private func recordEditTransactionCommit(_ plan: EditPlan) {
        SoundtimeDiagnostics.shared.record(
            category: .edit,
            severity: .info,
            name: "edit-transaction-committed",
            message: "Committed an atomic project edit transaction.",
            fields: [
                "transactionID": plan.command.transactionID.description,
                "kind": plan.command.kind.rawValue,
                "beforeRevision": plan.command.baseRevision.description,
                "afterRevision": plan.nextRevision.description,
                "trackCount": "\(plan.trackEdits.count)",
            ]
        )
    }

    private enum UndoAction {
        case projectTracks(ProjectTrackUndoSnapshot)
        case transaction(ProjectEditTransactionRecord)
    }

    private func captureProjectTrackUndoSnapshot(
        selectedTrackID: UUID? = nil,
        restoreProgress: Float?
    ) -> ProjectTrackUndoSnapshot {
        ProjectTrackUndoSnapshot(
            tracks: projectTracks,
            editGraph: projectEditGraph,
            renderTracks: publishedTimelineRenderTracks,
            playbackTracks: publishedProjectPlaybackTracks,
            activeTrackID: activeTrackID,
            selectedTrackID: selectedTrackID ?? self.selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            selectedTimelineRange: selectedTimelineRange,
            restoreProgress: restoreProgress
        )
    }

    private enum ProjectReadinessState: Equatable {
        case empty
        case launchPreviewLoading
        case visualReady(trackCount: Int)
        case playbackHydrating(completed: Int, failed: Int, total: Int)
        case playbackReady(trackCount: Int)
        case playbackReadyWithFailures(completed: Int, failed: Int)
        case failed(String)

        var statusText: String {
            switch self {
            case .empty:
                return "idle"
            case .launchPreviewLoading:
                return "opening last project"
            case let .visualReady(trackCount):
                return trackCount == 1 ? "project preview ready" : "project preview ready - \(trackCount) tracks"
            case let .playbackHydrating(completed, failed, total):
                let failedSuffix = failed > 0 ? ", \(failed) failed" : ""
                return "loading playback \(completed)/\(total)\(failedSuffix)"
            case let .playbackReady(trackCount):
                return trackCount == 1 ? "project ready" : "project ready - \(trackCount) tracks"
            case let .playbackReadyWithFailures(completed, failed):
                return "project ready - \(completed) loaded, \(failed) failed"
            case let .failed(message):
                return message
            }
        }
    }

    private struct AudioClipboard: Sendable {
        let id: UUID
        let buffer: DecodedAudioBuffer?
        let waveformOverview: WaveformOverview
        let audioClip: AudioEditTimeline.Clip?
        let fileClipSourceID: EditableAudioSourceID?
        let fileClipSourceURL: URL?
        let fileClip: AudioFileEditTimeline.Clip?

        init(
            id: UUID = UUID(),
            buffer: DecodedAudioBuffer?,
            waveformOverview: WaveformOverview,
            audioClip: AudioEditTimeline.Clip? = nil,
            fileClipSourceID: EditableAudioSourceID? = nil,
            fileClipSourceURL: URL? = nil,
            fileClip: AudioFileEditTimeline.Clip? = nil
        ) {
            self.id = id
            self.buffer = buffer
            self.waveformOverview = waveformOverview
            self.audioClip = audioClip
            self.fileClipSourceID = fileClipSourceID
            self.fileClipSourceURL = fileClipSourceURL
            self.fileClip = fileClip
        }
    }

    private struct EditableSelectionTarget {
        let trackIndex: Int
        let displaySelection: TimelineSelection
        let editSelection: TimelineSelection
    }

    private struct DeleteTimingTrace {
        static let isDetailedTracingEnabled =
            ProcessInfo.processInfo.environment["SOUNDTIME_DETAILED_EDIT_TRACING"] == "1"

        let id = UUID()
        let operation: String
        let startedAt = CACurrentMediaTime()
        var lastMarkAt: CFTimeInterval

        var recordsDetailedTiming: Bool {
            Self.isDetailedTracingEnabled
        }

        init(operation: String) {
            self.operation = operation
            self.lastMarkAt = startedAt
        }

        mutating func mark(
            _ phase: String,
            message: String,
            severity: SoundtimeDiagnosticSeverity = .info,
            fields: @autoclosure () -> [String: String] = [:]
        ) {
            guard Self.isDetailedTracingEnabled || severity != .info else {
                return
            }

            let now = CACurrentMediaTime()
            let elapsedMilliseconds = (now - startedAt) * 1_000
            let deltaMilliseconds = (now - lastMarkAt) * 1_000
            lastMarkAt = now

            SoundtimeDiagnostics.shared.record(
                category: .edit,
                severity: severity,
                name: "delete-timing-\(phase)",
                message: message,
                fields: [
                    "traceID": id.uuidString,
                    "operation": operation,
                    "elapsedMs": String(format: "%.3f", elapsedMilliseconds),
                    "deltaMs": String(format: "%.3f", deltaMilliseconds),
                ].merging(fields()) { _, new in new }
            )
        }

        func markAfterRenderSubmitted(
            phase: String,
            message: String,
            submittedAt: CFTimeInterval,
            fields: @autoclosure () -> [String: String] = [:]
        ) {
            guard Self.isDetailedTracingEnabled else {
                return
            }

            SoundtimeDiagnostics.shared.record(
                category: .edit,
                severity: .info,
                name: "delete-timing-\(phase)",
                message: message,
                fields: [
                    "traceID": id.uuidString,
                    "operation": operation,
                    "elapsedMs": String(format: "%.3f", (submittedAt - startedAt) * 1_000),
                ].merging(fields()) { _, new in new }
            )
        }
    }

    private struct DenoiseProcessingResult: Sendable {
        let materialized: (
            buffer: DecodedAudioBuffer,
            timeline: AudioEditTimeline,
            waveformOverview: WaveformOverview,
            zeroCrossingIndex: AudioZeroCrossingIndex
        )
        let beforeBuffer: DecodedAudioBuffer
        let afterBuffer: DecodedAudioBuffer
        let processedFrameCount: Int
        let providerSummary: String
    }

    private struct PendingDenoiseReview {
        let requestID: UUID
        let trackID: UUID
        let editRevision: Int
        let displaySelection: TimelineSelection
        let editSelection: TimelineSelection
        let trackName: String
        let result: DenoiseProcessingResult
    }

    private struct StemSeparationStemResult: Sendable {
        let name: String
        let buffer: DecodedAudioBuffer
    }

    private struct StemSeparationProcessingResult: Sendable {
        let beforeBuffer: DecodedAudioBuffer
        let stems: [StemSeparationStemResult]
        let timelineStartTime: TimeInterval
        let providerSummary: String
    }

    private struct PendingStemSeparationReview {
        let requestID: UUID
        let trackID: UUID
        let editRevision: Int
        let displaySelection: TimelineSelection
        let editSelection: TimelineSelection
        let trackName: String
        let result: StemSeparationProcessingResult
    }

    private struct SplitTrackEdit {
        let trackIndex: Int
        let trackID: UUID
        let editedDuration: TimeInterval
        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
    }

    private struct SilenceCleanupResult: Sendable {
        let frameRanges: [Range<Int>]
        let detectedRegionCount: Int
        let deletedFrameCount: Int
        let deletedDuration: TimeInterval
    }

    private struct DeadAirReviewCandidate: Sendable, Identifiable {
        let id: UUID
        let trackID: UUID
        let trackEditRevision: Int
        let displaySelection: TimelineSelection
        let editSelection: TimelineSelection
        let frameRange: Range<Int>
        let confidence: Float
        let reason: String
        let estimatedRemovedDuration: TimeInterval

        var displayStartProgress: Float {
            displaySelection.startProgressFloat
        }

        var displayEndProgress: Float {
            displaySelection.endProgressFloat
        }
    }

    private struct DeadAirReviewResult: Sendable {
        let candidates: [DeadAirReviewCandidate]
        let detectedRegionCount: Int
    }

    private enum ProjectMixTrackSource: Sendable {
        case decoded(DecodedAudioBuffer)
        case timeline(AudioEditTimeline)
        case file(URL)
        case fileTimeline(URL, AudioFileEditTimeline)
    }

    private struct ProjectMixTrackSnapshot: Sendable {
        let id: UUID
        let name: String
        let volume: Float
        let source: ProjectMixTrackSource
        let zeroCrossingIndex: AudioZeroCrossingIndex?
    }

    private struct ProjectMixResult: Sendable {
        let buffer: DecodedAudioBuffer
        let zeroCrossingIndex: AudioZeroCrossingIndex
        let trackCount: Int
    }

    private enum WorkspaceAudioExportError: LocalizedError {
        case noAudioToExport
        case noSelectedTrackToExport
        case emptyExportRange

        var errorDescription: String? {
            switch self {
            case .noAudioToExport:
                return "There is no audio to export."
            case .noSelectedTrackToExport:
                return "The selected track is not available for export."
            case .emptyExportRange:
                return "The selected export range is empty."
            }
        }
    }

    private final class RecordingPreviewCoalescer: @unchecked Sendable {
        private let queue = DispatchQueue(label: "Soundtime.recording.preview.coalescer", qos: .userInteractive)
        private let minimumFlushInterval: TimeInterval = 1.0 / 45.0
        private var pendingChunks: [AudioRecordingChunk] = []
        private var isFlushScheduled = false
        private var lastFlushTimestamp = CACurrentMediaTime()

        func enqueue(
            _ chunk: AudioRecordingChunk,
            deliver: @escaping @Sendable ([AudioRecordingChunk]) -> Void
        ) {
            queue.async { [minimumFlushInterval] in
                self.pendingChunks.append(chunk)
                guard !self.isFlushScheduled else {
                    return
                }

                self.isFlushScheduled = true
                let now = CACurrentMediaTime()
                let delay = max(0, minimumFlushInterval - (now - self.lastFlushTimestamp))
                self.queue.asyncAfter(deadline: .now() + delay) {
                    let chunks = self.takePendingChunksLocked()
                    guard !chunks.isEmpty else {
                        return
                    }

                    deliver(chunks)
                }
            }
        }

        func reset() {
            queue.sync {
                pendingChunks.removeAll(keepingCapacity: true)
                isFlushScheduled = false
                lastFlushTimestamp = CACurrentMediaTime()
            }
        }

        func drainPending() -> [AudioRecordingChunk] {
            queue.sync {
                takePendingChunksLocked()
            }
        }

        private func takePendingChunksLocked() -> [AudioRecordingChunk] {
            let chunks = pendingChunks
            pendingChunks.removeAll(keepingCapacity: true)
            isFlushScheduled = false
            lastFlushTimestamp = CACurrentMediaTime()
            return chunks
        }
    }

    private let projectSession = ProjectSession()
    private var projectTracks: [ProjectTrack] {
        _read {
            yield projectSession.tracks
        }
        _modify {
            yield &projectSession.tracks
        }
    }
    private var projectEditGraph: EditGraph {
        _read {
            yield projectSession.editGraph
        }
        _modify {
            yield &projectSession.editGraph
        }
    }
    private var activeTrackID: UUID? {
        get { projectSession.activeTrackID }
        set { projectSession.activeTrackID = newValue }
    }
    private var selectedTrackID: UUID? {
        get { projectSession.selectedTrackID }
        set { projectSession.selectedTrackID = newValue }
    }
    private var selectedTrackIDs: Set<UUID> {
        _read {
            yield projectSession.selectedTrackIDs
        }
        _modify {
            yield &projectSession.selectedTrackIDs
        }
    }
    private var trackSelectionAnchorID: UUID? {
        get { projectSession.trackSelectionAnchorID }
        set { projectSession.trackSelectionAnchorID = newValue }
    }
    private var defaultEditGroupID: UUID {
        get { projectSession.defaultEditGroupID }
        set { projectSession.defaultEditGroupID = newValue }
    }
    private var currentProjectURL: URL? {
        get { projectSession.projectURL }
        set { projectSession.projectURL = newValue }
    }
    private var currentProjectID: UUID {
        get { projectSession.projectID }
        set { projectSession.projectID = newValue }
    }
    private var currentEditGraphRevision: UInt64 {
        get { projectSession.editRevision }
        set { projectSession.editRevision = newValue }
    }
    private var publishedTimelineEditRevision: UInt64 {
        get { projectSession.publishedTimelineRevision }
        set { projectSession.publishedTimelineRevision = newValue }
    }
    private var publishedPlaybackEditRevision: UInt64 {
        get { projectSession.publishedPlaybackRevision }
        set { projectSession.publishedPlaybackRevision = newValue }
    }
    private var currentVisualRevision: UInt64 {
        get { projectSession.visualRevision }
        set { projectSession.visualRevision = newValue }
    }
    private var currentLaunchStateRevision: UInt64 {
        get { projectSession.launchStateRevision }
        set { projectSession.launchStateRevision = newValue }
    }
    private var hasRestoredLastProject = false
    private var isDeferredProjectRestorePending = false
    private var isLoadingProject = false
    private var projectReadinessState: ProjectReadinessState = .empty
    private var projectLoadGeneration = 0
    private let projectCriticalLoadQueue = DispatchQueue(
        label: "com.soundtime.project-critical-load",
        qos: .userInitiated
    )
    private var launchPreviewLoadGeneration = 0
    private var isLaunchPreviewLoadInFlight = false
    private var pendingHydrationAfterLaunchPreviewLoad = false
    private var isLaunchVisualPreviewPendingImmediateRender = false
    private var projectHydrationQueue: ProjectHydrationQueue?
    private var projectPlaybackPrimedTrackIDs: Set<UUID> = []
    private var projectHydrationCompletedTrackIDs: Set<UUID> = []
    private var projectHydrationFailedTrackIDs: Set<UUID> = []
    private var projectHydrationLaunchCacheWriteScheduled = false
    private var projectHydrationImprovedLaunchWaveforms = false
    private var lastProjectReadinessHydrationDiagnosticTime: CFTimeInterval = -Double.infinity
    private var audioClipboard: AudioClipboard? {
        didSet {
            updateEffectCommandState()
        }
    }
    private var activeImportID = UUID()
    private var activeImportOperationIDs: Set<UUID> = []
    private var audioImportPrewarm: AudioImportPrewarm?
    private var selectedAudioFile: AudioFileMetadata?
    private var decodedAudioBuffer: DecodedAudioBuffer?
    private var audioTimeline: AudioEditTimeline?
    private let waveformOverviewDiskCache = WaveformOverviewDiskCacheStore()
    private var editUndoStack: [UndoAction] = [] {
        didSet {
            if !isNavigatingEditHistory, editUndoStack.count > oldValue.count {
                editRedoStack.removeAll(keepingCapacity: true)
            }
            scheduleAutosaveIfNeeded()
        }
    }
    private var editRedoStack: [UndoAction] = []
    private var isNavigatingEditHistory = false
    private var loadedAudioSummary: String?
    private var selectedTimelineRange: TimelineSelection? {
        get { projectSession.selection }
        set { projectSession.selection = newValue }
    }

    private func editGroupIDForNewProjectTrack() -> UUID {
        let primaryGroupID = EditGroupModel.primaryGroupID(
            from: projectTracks.map(\.editGroupID),
            fallback: defaultEditGroupID
        )
        defaultEditGroupID = primaryGroupID
        return primaryGroupID
    }

    private func normalizeLoadedProjectEditGroups(reason: String) {
        guard !projectTracks.isEmpty else {
            return
        }

        let previousGroupIDs = projectTracks.map(\.editGroupID)
        let primaryGroupID = EditGroupModel.primaryGroupID(
            from: previousGroupIDs,
            fallback: defaultEditGroupID
        )
        let needsNormalization = EditGroupModel.needsNormalization(
            previousGroupIDs,
            fallback: defaultEditGroupID
        )
        defaultEditGroupID = primaryGroupID
        for index in projectTracks.indices {
            projectTracks[index].editGroupID = primaryGroupID
        }

        guard needsNormalization else {
            return
        }

        let uniqueGroupCount = Set(previousGroupIDs.map { $0 ?? primaryGroupID }).count
        SoundtimeDiagnostics.shared.record(
            category: .edit,
            severity: .info,
            name: "project-edit-groups-normalized",
            message: "Loaded project tracks were normalized into one edit group for linked ripple editing.",
            fields: [
                "reason": reason,
                "trackCount": "\(projectTracks.count)",
                "previousGroupCount": "\(uniqueGroupCount)",
                "primaryGroupID": primaryGroupID.uuidString,
            ]
        )
    }

    private var deadAirCandidates: [DeadAirReviewCandidate] = []
    private var activeDeadAirCandidateID: UUID?
    private var deadAirAuditionStopTask: Task<Void, Never>?
    private let highConfidenceSilenceThreshold: Float = 0.86
    private var lastEffect: LastEffect?
    private var activeDenoiseRequestID: UUID?
    private var activeDenoiseProvider: AudioProcessingProvider?
    private var activeDenoiseTask: Task<Void, Never>?
    private var activeTranscriptionTask: Task<Void, Never>?
    private var activeTranscriptionProvider: TranscriptionProvider?
    private var activeTranscriptionController: TranscriptionController?
    private var activeTranscriptionJob: TranscriptionJob?
    private var selectedTranscriptSelection: TranscriptTokenSelection?
    private var activeTranscriptWordID: UUID?
    private var activeTranscriptWordProjectRange: TranscriptionTimeRange?
    private var transcriptAlignmentDebugVisible = false
    private var activeDenoiseTrackID: UUID?
    private var activeDenoiseDisplaySelection: TimelineSelection?
    private var denoiseHighlightFadeTask: Task<Void, Never>?
    private var transcriptionHighlightFadeTask: Task<Void, Never>?
    private var pendingDenoiseReview: PendingDenoiseReview?
    private var pendingStemSeparationReview: PendingStemSeparationReview?
    private var activeAudioProcessingOperation: AudioProcessingOperation?
    private var isDenoiseModalInteractionLocked = false
    private var currentPlayheadFrame = 0
    private var timelineLoopRange = TimelineLoopRange.default
    private var previousLoopPlaybackProgress: Float?
    private var displayedFrameCount = 0
    private var displayedSampleRate: Double = 0
    private var currentPlaybackStatus = "idle"
    private var playbackTimer: Timer?
    private var loudnessMeterTimer: Timer?
    private var performanceMeterTimer: Timer?
    private var latestTimelineFrameStats: TimelineFrameStats?
    private var pendingProjectTrackMixUpdate = false
    private var scheduledProjectTrackMixWorkItem: DispatchWorkItem?
    private var lastProjectTrackMixPublishTimestamp = CACurrentMediaTime()
    private var scheduledPlaybackReloadWorkItem: DispatchWorkItem?
    private var ownedSourceCleanupWorkItem: DispatchWorkItem?
    private var pendingOwnedSourceCleanupURLs: Set<URL> = []
    private var postDeleteRefreshWorkItem: DispatchWorkItem?
    private var deleteAnimationGeneration = 0
    private var deleteAutosaveProtectedUntil: CFTimeInterval = 0
    private var keyDownMonitor: Any?
    private var audioDevicePreferencesObserver: NSObjectProtocol?
    private var debugToolsVisible = false
    private var isTranscriptLayerVisible = false
    private var editScope: EditScope = .group
    private let editScopeFadeDuration: TimeInterval = 0.18
    private var editScopeLayoutAllowsDisplay = true
    private var editScopeVisibleForSelection = false
    private let editMaterializationDelay: TimeInterval = 0.75
    private let deletePostAnimationDisplayRefreshDelay: TimeInterval = 0.16
    private let deleteMaterializationDelay: TimeInterval = 0.18
    private let editWaveformRefinementDelay: TimeInterval = 0.20
    private let editMaterializationTasks = KeyedTaskRegistry<UUID>()
    private let portablePastePreparationQueue = DispatchQueue(
        label: "Soundtime.portable-paste-preparation",
        qos: .userInitiated
    )
    private let optimisticDeleteWaveformTasks = KeyedTaskRegistry<UUID>()
    private let editWaveformRefinementTasks = KeyedTaskRegistry<UUID>()
    private let launchWaveformCacheTasks = KeyedTaskRegistry<String>()
    private var launchSnapshotSaveWorkItem: DispatchWorkItem?
    private var launchSnapshotSaveGeneration = 0
    private var workspaceLifecycleGeneration = 0
    private let launchCacheWriteQueue = DispatchQueue(label: "Soundtime.launch-cache-writer", qos: .utility)
    private let statePersistenceQueue = DispatchQueue(label: "Soundtime.state-persistence", qos: .utility)
    private var launchCacheWriteInFlight = false
    private var pendingLaunchCacheWriteRequest: LaunchCacheWriteRequest?
    private var lastTimelineHotInteractionTime: CFTimeInterval = -Double.infinity
    private var hotPathContractSmokeProtectedUntil: CFTimeInterval = -Double.infinity
    private var lastLaunchCacheHotPathDeferralEventTimeByKey: [String: CFTimeInterval] = [:]
    private let launchCacheHotPathQuietInterval: CFTimeInterval = 0.75
    private let launchCacheHotPathDeferralEventInterval: CFTimeInterval = 2.0
    private var inputRecorderStorage: AudioInputRecorder?
    private var inputRecorder: AudioInputRecorder {
        if let recorder = inputRecorderStorage {
            return recorder
        }
        let recorder = AudioInputRecorder()
        inputRecorderStorage = recorder
        return recorder
    }
    private var recordingTrackID: UUID?
    private var recordingTakeWriter: StreamingWAVTakeWriter?
    private var recordingStartUndoSnapshot: ProjectTrackUndoSnapshot?
    private var trackReorderUndoSnapshot: ProjectTrackUndoSnapshot?
    private var recordingStartUndoStackCount: Int?
    private var recordingSampleRate: Double = 0
    private var recordingAccumulator: LiveRecordingWaveformAccumulator?
    private let recordingPreviewCoalescer = RecordingPreviewCoalescer()
    private var lastRecordingVisualUpdateTimestamp = CACurrentMediaTime()
    private var trackControlViewsByID: [UUID: TrackControlView] = [:]
    private var trackControlReusePool: [TrackControlView] = []
    private var trackIndicesByID: [UUID: Int] = [:]
    private var trackIndexCacheTrackCount = 0
    private var currentTrackLaneLayout = ResolvedTimelineTrackLayout(
        totalTrackCount: 0,
        viewportHeight: 1,
        preferredTrackHeight: TimelineTrackLayout.defaultPreferredTrackHeight,
        requestedScrollOffset: 0
    )
    private var playbackControllerStorage: PlaybackEngine?
    private var playbackController: PlaybackEngine {
        if let controller = playbackControllerStorage {
            return controller
        }
        let controller = PlaybackEngineFactory.makeDefault()
        controller.setPerceptualVolume(volumeControl.perceptualVolume)
        playbackControllerStorage = controller
        return controller
    }
    private var timelineLoopIsEnabled = true
    private var isTimelineLoopPlaybackBypassed = false
    private var playbackRefreshRate: TimeInterval {
        timelineLoopIsEnabled && timelineLoopRange.durationProgress < 0.999 ? 60 : 10
    }
    private let loudnessMeterRefreshRate: TimeInterval = 60
    private let performanceMeterRefreshRate: TimeInterval = 10
    private let fallbackLoudnessMaximumAudibleTracks = 32
    private let fallbackLoudnessMaximumFrameCount = 384
    private let trackMixCoalescingInterval: TimeInterval = 1.0 / 72.0
    private var visualPlayheadProgress: Float = 0
    private var visualPlayheadAnchorTimestamp = CACurrentMediaTime()
    private var visualPlaybackActive = false
    private var displayedPlaybackActive: Bool?
    private var lastVisualAudioCorrectionTimestamp = CACurrentMediaTime()
    private let visualAudioSyncDeadband: TimeInterval = 0.006
    private let visualAudioSyncHardCorrectionThreshold: TimeInterval = 0.075
    private let visualAudioSyncResponseDuration: TimeInterval = 0.12
    private let visualAudioSyncMinimumCorrectionInterval: TimeInterval = 0.1
    private let transportArrowSkipDuration: TimeInterval = 5
    private let wavPreviewLevels = WAVImportPreviewPolicy.allLevels.map {
        WAVPreviewLevel(targetBinCount: $0.targetBinCount, samplesPerBin: $0.samplesPerBin)
    }
    private let optimisticEditPreviewBinLimit = 262_144
    private let optimisticEditPreviewSamplesPerBin = 2

    private struct WAVPreviewLevel {
        let targetBinCount: Int
        let samplesPerBin: Int
    }

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Soundtime")
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = NSColor.labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let metadataLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Drop audio here")
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = NSColor.secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let timeReadoutLabel: NSTextField = {
        let label = NSTextField(labelWithString: "00:00.000 / 00:00.000")
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        label.alignment = .right
        label.textColor = NSColor.white
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let framesPerSecondLabel: NSTextField = {
        let label = NSTextField(labelWithString: "-- fps")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .right
        label.textColor = NSColor.secondaryLabelColor
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let frameRateHistoryView = FrameRateHistoryView()
    private let cpuUsageHistoryView = FrameRateHistoryView(metric: .cpuUsage)
    private let performanceDashboardButton = PerformanceDashboardButton()
    private let volumeControl = VolumeControlView()
    private let loudnessMeter = LoudnessMeterView()
    private let transportControlPanel = TransportControlPanelView()
    private let editScopeStack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.alphaValue = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    private let editScopeControlsRow: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    private let editScopeTitleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Delete scope")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor.secondaryLabelColor
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    private let editScopeControl: NSSegmentedControl = {
        let control = NSSegmentedControl()
        control.segmentCount = EditScope.allCases.count
        for scope in EditScope.allCases {
            control.setLabel(scope.title, forSegment: scope.rawValue)
            control.setWidth(scope == .selected ? 72 : 54, forSegment: scope.rawValue)
        }
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        control.selectedSegment = EditScope.group.rawValue
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }()
    private let editScopeHintLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    private let agentCommandController = AgentCommandController()
    private let agentCommandBar = AgentCommandBarView()
    private lazy var fisheyeRadiusControl = TimelineTuningSliderView(
        title: "Fish Radius",
        value: FisheyeDefaults.radius,
        range: 0.02...0.20,
        valueFormat: "%.3f"
    )
    private lazy var fisheyePowerControl = TimelineTuningSliderView(
        title: "Fish Power",
        value: FisheyeDefaults.power,
        range: 0.30...0.95,
        valueFormat: "%.2f"
    )
    private lazy var fisheyeStartControl = TimelineTuningSliderView(
        title: "Fish Start",
        value: FisheyeDefaults.start,
        range: 0...180,
        valueFormat: "%.0fs"
    )
    private lazy var fisheyeFullControl = TimelineTuningSliderView(
        title: "Fish Full",
        value: FisheyeDefaults.full,
        range: 60...600,
        valueFormat: "%.0fs"
    )
    private lazy var fisheyeCurveControl = TimelineTuningSliderView(
        title: "Fish Curve",
        value: FisheyeDefaults.curve,
        range: 0.35...3.00,
        valueFormat: "%.2f"
    )
    private lazy var fisheyeActivateDurationControl = TimelineTuningSliderView(
        title: "Fish Activate Dur",
        value: FisheyeDefaults.activationMilliseconds,
        range: 40...1_200,
        valueFormat: "%.0fms"
    )
    private let fisheyeControlsStack: NSStackView = {
        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fill
        stackView.spacing = 10
        stackView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stackView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()
    private let trackControlsStack: TrackControlsViewportView = {
        let view = TrackControlsViewportView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    private let timelineSurface = TimelineView()
    private let timelineZoomControls = TimelineZoomControlsView()
    private let horizontalTimelineScrollbar = TimelineNavigationScrollbarView(axis: .horizontal)
    private let verticalTimelineScrollbar = TimelineNavigationScrollbarView(axis: .vertical)
    private let addTrackButton = AddTrackButton()
    private var exportProgressOverlayStorage: ExportProgressOverlayView?
    private var exportProgressOverlay: ExportProgressOverlayView {
        if let overlay = exportProgressOverlayStorage {
            return overlay
        }
        let overlay = ExportProgressOverlayView()
        installFullScreenOverlay(overlay)
        exportProgressOverlayStorage = overlay
        return overlay
    }
    private lazy var audioExportService: AudioExportService = {
        let service = AudioExportService()
        service.onProgress = { [weak self] progress in
            self?.handleAudioExportProgress(progress)
        }
        service.onCompletion = { [weak self] jobID, result in
            self?.handleAudioExportCompletion(jobID: jobID, result)
        }
        return service
    }()
    private var audioExportWindowController: AudioExportWindowController?
    private var activeAudioExportJobID: UUID?
    private var latestAudioExportProgress: AudioExportProgress?
    private var lastDiagnosedAudioExportStage: AudioExportStage?
    private let audioExportStatusButton: NSButton = {
        let button = NSButton(title: "Export 0%", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = NSColor(white: 0.88, alpha: 1)
        button.isBordered = true
        button.isHidden = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private var gainEffectOverlayStorage: GainEffectOverlayView?
    private var gainEffectOverlay: GainEffectOverlayView {
        if let overlay = gainEffectOverlayStorage {
            return overlay
        }
        let overlay = GainEffectOverlayView()
        overlay.onGainChanged = { [weak self] _, gain in
            self?.previewSelectedGain(gain)
        }
        overlay.onConfirm = { [weak self] decibels, gain in
            self?.confirmSelectedGain(decibels: decibels, gain: gain)
        }
        overlay.onCancel = { [weak self] in
            self?.cancelSelectedGainPreview()
        }
        installFullScreenOverlay(overlay)
        gainEffectOverlayStorage = overlay
        return overlay
    }
    private var denoiseProgressOverlayStorage: DenoiseProgressOverlayView?
    private var denoiseProgressOverlay: DenoiseProgressOverlayView {
        if let overlay = denoiseProgressOverlayStorage {
            return overlay
        }
        let overlay = DenoiseProgressOverlayView()
        overlay.onCancel = { [weak self] in
            self?.cancelActiveDenoiseProcessing()
        }
        installFullScreenOverlay(overlay)
        denoiseProgressOverlayStorage = overlay
        return overlay
    }
    private var transcriptionProgressOverlayStorage: TranscriptionProgressOverlayView?
    private var transcriptionProgressOverlay: TranscriptionProgressOverlayView {
        if let overlay = transcriptionProgressOverlayStorage {
            return overlay
        }
        let overlay = TranscriptionProgressOverlayView()
        overlay.onCancel = { [weak self] in
            self?.cancelActiveTranscription()
        }
        installFullScreenOverlay(overlay)
        transcriptionProgressOverlayStorage = overlay
        return overlay
    }
    private var denoiseReviewOverlayStorage: DenoiseReviewOverlayView?
    private var denoiseReviewOverlay: DenoiseReviewOverlayView {
        if let overlay = denoiseReviewOverlayStorage {
            return overlay
        }
        let overlay = DenoiseReviewOverlayView()
        overlay.onAccept = { [weak self] in
            self?.acceptPendingDenoiseReview()
        }
        overlay.onReject = { [weak self] in
            self?.rejectPendingDenoiseReview()
        }
        installFullScreenOverlay(overlay)
        denoiseReviewOverlayStorage = overlay
        return overlay
    }
    private var stemSeparationReviewOverlayStorage: StemSeparationReviewOverlayView?
    private var stemSeparationReviewOverlay: StemSeparationReviewOverlayView {
        if let overlay = stemSeparationReviewOverlayStorage {
            return overlay
        }
        let overlay = StemSeparationReviewOverlayView()
        overlay.onAccept = { [weak self] in
            self?.acceptPendingStemSeparationReview()
        }
        overlay.onReject = { [weak self] in
            self?.rejectPendingStemSeparationReview()
        }
        installFullScreenOverlay(overlay)
        stemSeparationReviewOverlayStorage = overlay
        return overlay
    }
    private var debugTuningControlsConfigured = false
    private var framesPerSecondWidthConstraint: NSLayoutConstraint?
    private var trackControlsBelowDebugConstraint: NSLayoutConstraint?
    private var trackControlsBelowHeaderConstraint: NSLayoutConstraint?
    private var lastResponsiveLayoutWidth: CGFloat = -1
    private let autosaveID = UUID()
    private let autosaveDelay: TimeInterval = 1.5
    private var autosaveWorkItem: DispatchWorkItem?
    private var autosaveGeneration = 0
    private var latestAutosaveScheduleReason = "none"
    private let viewportPersistenceDelay: TimeInterval = 0.2
    private var viewportPersistenceWorkItem: DispatchWorkItem?
    private var latestTimelineViewportForPersistence: SoundtimeProject.TimelineViewport?
    private var projectSaveGeneration = 0
    private var isAutosaveSuppressed = false
    private var wavFileInfoCache: [URL: WAVFileInfo] = [:]
    private var invalidWAVFileInfoCache: Set<URL> = []
    private var waveformTileSourceCache: [URL: WaveformTileBuildSource] = [:]
    private var publishedTimelineRenderTracks: [TimelineRenderState.Track] = []
    private var timelinePresentationDirtyTrackIDs: Set<UUID> = []
    private var publishedProjectPlaybackTracks: [ProjectPlaybackTrack] = []
    private var lastPlaybackReloadErrorDescription: String?
    private var latestUndoRestoreStageMilliseconds: [String: Double] = [:]
    private var latestEditTransactionStageTimings = EditTransactionStageTimings()
    private var latestEditCommitStageTimings = EditCommitStageTimings()
    private var latestTransactionHistoryRestoreStageTimings = EditHistoryRestoreStageTimings()
    private let launchPlan: ProjectLaunchPlan

    override init(frame frameRect: NSRect) {
        launchPlan = .newProject()
        super.init(frame: frameRect)
        LaunchStartupTrace.shared.mark(
            .workspacePropertiesInitialized,
            recordsDiagnosticEvent: false
        )
        configure()
        LaunchStartupTrace.shared.mark(
            .workspaceConfigured,
            recordsDiagnosticEvent: false
        )
    }

    init(
        frame frameRect: NSRect = .zero,
        launchPlan: ProjectLaunchPlan
    ) {
        self.launchPlan = launchPlan
        super.init(frame: frameRect)
        LaunchStartupTrace.shared.mark(
            .workspacePropertiesInitialized,
            recordsDiagnosticEvent: false
        )
        configure()
        LaunchStartupTrace.shared.mark(
            .workspaceConfigured,
            recordsDiagnosticEvent: false
        )
        applyInitialLaunchPlanIfAvailable()
    }

    func applicationUpdateRestartBlockers() -> [ApplicationUpdateRestartBlocker] {
        var blockers: [ApplicationUpdateRestartBlocker] = []
        if recordingTrackID != nil {
            blockers.append(ApplicationUpdateRestartBlocker(
                kind: .recording,
                title: "Recording in progress",
                message: "Stop the current recording before Soundtime restarts to install the update.",
                canResolveAutomatically: false
            ))
        }
        if audioExportService.hasActiveExport {
            blockers.append(ApplicationUpdateRestartBlocker(
                kind: .export,
                title: "Export in progress",
                message: "Let the current export finish or cancel it before installing the update.",
                canResolveAutomatically: false
            ))
        }
        if !activeImportOperationIDs.isEmpty {
            blockers.append(ApplicationUpdateRestartBlocker(
                kind: .importOrConversion,
                title: "Audio import in progress",
                message: "Wait for the current audio import to finish before installing the update.",
                canResolveAutomatically: false
            ))
        }
        if activeDenoiseTask != nil || activeTranscriptionTask != nil {
            blockers.append(ApplicationUpdateRestartBlocker(
                kind: .apiProcessing,
                title: "Audio processing in progress",
                message: "Wait for the current processing job to finish or cancel it before installing the update.",
                canResolveAutomatically: false
            ))
        }
        return blockers
    }

    required init?(coder: NSCoder) {
        launchPlan = .newProject(reason: "coder")
        super.init(coder: coder)
        LaunchStartupTrace.shared.mark(
            .workspacePropertiesInitialized,
            recordsDiagnosticEvent: false
        )
        configure()
        LaunchStartupTrace.shared.mark(
            .workspaceConfigured,
            recordsDiagnosticEvent: false
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard !isDenoiseModalInteractionActive else {
            return
        }

        clearSelectedTrack()
        super.mouseDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isDenoiseModalInteractionActive {
            let overlay: NSView
            if pendingStemSeparationReview != nil {
                overlay = stemSeparationReviewOverlay
            } else if pendingDenoiseReview != nil {
                overlay = denoiseReviewOverlay
            } else {
                overlay = denoiseProgressOverlay
            }
            let overlayPoint = overlay.convert(point, from: self)
            return overlay.hitTest(overlayPoint) ?? overlay
        }

        if
            let overlay = stemSeparationReviewOverlayStorage,
            !overlay.isHidden,
            overlay.alphaValue > 0.01,
            overlay.frame.contains(point)
        {
            let overlayPoint = overlay.convert(point, from: self)
            return overlay.hitTest(overlayPoint) ?? overlay
        }

        if
            let overlay = denoiseReviewOverlayStorage,
            !overlay.isHidden,
            overlay.alphaValue > 0.01,
            overlay.frame.contains(point)
        {
            let overlayPoint = overlay.convert(point, from: self)
            return overlay.hitTest(overlayPoint) ?? overlay
        }

        if
            let overlay = denoiseProgressOverlayStorage,
            !overlay.isHidden,
            overlay.alphaValue > 0.01,
            overlay.frame.contains(point)
        {
            let overlayPoint = overlay.convert(point, from: self)
            return overlay.hitTest(overlayPoint) ?? overlay
        }

        if
            let overlay = transcriptionProgressOverlayStorage,
            !overlay.isHidden,
            overlay.alphaValue > 0.01,
            overlay.frame.contains(point)
        {
            let overlayPoint = overlay.convert(point, from: self)
            if let overlayHitView = overlay.hitTest(overlayPoint) {
                return overlayHitView
            }
        }

        if let addTrackHitView = hitTestAddTrackButton(point) {
            return addTrackHitView
        }

        if agentCommandBar.frame.contains(point) {
            let agentPoint = agentCommandBar.convert(point, from: self)
            if let agentHitView = agentCommandBar.hitTest(agentPoint) {
                return agentHitView
            }
        }

        let hitView = super.hitTest(point)
        if isAgentCommandBarHit(hitView) {
            return hitTestExcludingAgentCommandBar(point) ?? self
        }

        if hitView !== self {
            return hitView
        }

        return hitView
    }

    private var isDenoiseModalInteractionActive: Bool {
        isDenoiseModalInteractionLocked
    }

    private func setDenoiseModalInteractionLocked(_ isLocked: Bool) {
        guard isDenoiseModalInteractionLocked != isLocked else {
            timelineSurface.setInteractionSuppressed(isLocked)
            return
        }

        isDenoiseModalInteractionLocked = isLocked
        timelineSurface.setInteractionSuppressed(isLocked)
    }

    private func isAgentCommandBarHit(_ view: NSView?) -> Bool {
        var currentView = view
        while let view = currentView {
            if view === agentCommandBar {
                return true
            }
            currentView = view.superview
        }
        return false
    }

    private func hitTestAddTrackButton(_ point: NSPoint) -> NSView? {
        guard
            !addTrackButton.isHidden,
            addTrackButton.alphaValue > 0.01,
            addTrackButton.frame.contains(point)
        else {
            return nil
        }

        let buttonPoint = addTrackButton.convert(point, from: self)
        return addTrackButton.hitTest(buttonPoint) ?? addTrackButton
    }

    private func hitTestExcludingAgentCommandBar(_ point: NSPoint) -> NSView? {
        for subview in subviews.reversed() where subview !== agentCommandBar {
            let subviewPoint = subview.convert(point, from: self)
            if let hitView = subview.hitTest(subviewPoint) {
                return hitView
            }
        }
        return nil
    }

    private func installFullScreenOverlay(_ overlay: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = SoundtimeColors.windowBackground.cgColor
        installTransportKeyMonitor()
        SoundtimeMainThreadStallMonitor.shared.start()

        timelineSurface.translatesAutoresizingMaskIntoConstraints = false
        timelineSurface.setEmbeddedScrollbarsEnabled(false)
        frameRateHistoryView.translatesAutoresizingMaskIntoConstraints = false
        cpuUsageHistoryView.translatesAutoresizingMaskIntoConstraints = false
        performanceDashboardButton.translatesAutoresizingMaskIntoConstraints = false
        addTrackButton.translatesAutoresizingMaskIntoConstraints = false
        transportControlPanel.translatesAutoresizingMaskIntoConstraints = false
        timelineSurface.onAudioFileDropped = { [weak self] url in
            self?.loadDroppedAudioFile(at: url)
        }
        timelineSurface.onAudioFileDragEntered = { [weak self] url in
            self?.beginAudioImportPrewarm(for: url)
        }
        timelineSurface.onAudioFileDragExited = { [weak self] url in
            self?.cancelAudioImportPrewarm(for: url)
        }
        timelineSurface.onUnsupportedAudioFileDropped = { [weak self] url in
            self?.showUnsupportedAudioFileAlert(for: url)
        }
        timelineSurface.onTogglePlayback = { [weak self] in
            self?.togglePlayback()
        }
        timelineSurface.onDeleteSelection = { [weak self] in
            guard let self else {
                return
            }

            var trace = DeleteTimingTrace(operation: "delete-selection")
            trace.mark(
                "command-received",
                message: "Delete command reached the workspace.",
                fields: [
                    "scope": self.editScope.title,
                    "selectedTrackCount": "\(self.selectedTrackIDs.count + (self.selectedTrackID == nil ? 0 : 1))",
                    "hasTimelineSelection": "\(self.selectedTimelineRange != nil)",
                ]
            )
            self.deleteSelectedTrackOrSelection(trace: trace)
        }
        timelineSurface.onRemoveTimeRangeRequested = { [weak self] in
            guard let self else {
                return
            }

            var trace = DeleteTimingTrace(operation: "remove-time-range")
            trace.mark(
                "command-received",
                message: "Remove-time command reached the workspace.",
                fields: [
                    "scope": self.editScope.title,
                    "hasTimelineSelection": "\(self.selectedTimelineRange != nil)",
                ]
            )
            self.removeTimeRangeAcrossScope(trace: trace)
        }
        timelineSurface.onClearSelection = { [weak self] in
            self?.clearSelection()
        }
        timelineSurface.onCutSelection = { [weak self] in
            self?.cutSelection()
        }
        timelineSurface.onCopySelection = { [weak self] in
            self?.copySelection()
        }
        timelineSurface.onPasteAudio = { [weak self] in
            self?.pasteAudio()
        }
        timelineSurface.onDuplicateRegionRequested = { [weak self] in
            self?.duplicateRegion()
        }
        timelineSurface.onSplitAtPlayhead = { [weak self] in
            self?.splitAtPlayhead()
        }
        timelineSurface.onInsertSilenceRequested = { [weak self] in
            self?.insertSilenceOrTime()
        }
        timelineSurface.onHealAdjacentClipsRequested = { [weak self] in
            self?.healAdjacentClips()
        }
        timelineSurface.onNudgeSelectionRequested = { [weak self] direction in
            self?.nudgeSelection(direction: direction)
        }
        timelineSurface.onSlipClipContentsRequested = { [weak self] direction in
            self?.slipClipContents(direction: direction)
        }
        timelineSurface.onSnapSelectionRequested = { [weak self] in
            self?.snapSelectionToPlayheadEdgesOrSilence()
        }
        timelineSurface.onSelectTimeAcrossLinkedTracksRequested = { [weak self] in
            self?.selectTimeAcrossLinkedTracks()
        }
        timelineSurface.onSelectAllClipsOnTrackRequested = { [weak self] in
            self?.selectAllClipsOnTrack()
        }
        timelineSurface.onUndo = { [weak self] in
            self?.undoLastEdit()
        }
        timelineSurface.onRedo = { [weak self] in
            self?.redoLastEdit()
        }
        timelineSurface.onExportRequested = { [weak self] in
            self?.exportCurrentAudio()
        }
        timelineSurface.onImportAudioFileRequested = { [weak self] in
            self?.importAudioFile()
        }
        timelineSurface.onExportWAVRequested = { [weak self] in
            self?.exportWAVMixdown()
        }
        timelineSurface.onExportSelectedRegionRequested = { [weak self] in
            self?.exportSelectedRegion()
        }
        timelineSurface.onSelectionRegionContextExportRequested = { [weak self] in
            self?.exportSelectedRegionFromContextMenu()
        }
        timelineSurface.onExportMixdownAndStemsRequested = { [weak self] in
            self?.exportMixdownAndStems()
        }
        timelineSurface.onExportStemsRequested = { [weak self] in
            self?.exportStems()
        }
        timelineSurface.onOpenProjectRequested = { [weak self] in
            self?.openProject()
        }
        timelineSurface.onOpenRecentProjectRequested = { [weak self] url in
            self?.loadProject(from: url)
        }
        timelineSurface.onClearRecentProjectsRequested = {
            SoundtimeProjectStore.clearRecentProjectURLs()
        }
        timelineSurface.onSaveProjectRequested = { [weak self] in
            self?.saveProject()
        }
        timelineSurface.onSaveProjectAsRequested = { [weak self] in
            self?.saveProjectAs()
        }
        timelineSurface.onToggleDebugTools = { [weak self] in
            self?.toggleDebugTools()
        }
        timelineSurface.onGainRequested = { [weak self] in
            self?.showGainEffect()
        }
        timelineSurface.onNormalizeRequested = { [weak self] in
            self?.applyNormalizeEffect()
        }
        timelineSurface.onDenoiseRequested = { [weak self] in
            self?.applyDenoiseEffect()
        }
        timelineSurface.onSeparateMusicStemsRequested = { [weak self] in
            self?.applyStemSeparationEffect()
        }
        timelineSurface.onTranscribeSelectedTrackRequested = { [weak self] in
            self?.transcribeSelectedTrack()
        }
        timelineSurface.onToggleTranscriptLayerRequested = { [weak self] in
            self?.toggleTranscriptLayer()
        }
        timelineSurface.onTranscriptSelectionChanged = { [weak self] selection in
            self?.handleTranscriptSelection(selection)
        }
        timelineSurface.onTranscriptEditCommandRequested = { [weak self] command in
            self?.executeTranscriptEditCommand(command)
        }
        timelineSurface.onToggleTranscriptAlignmentDebugRequested = { [weak self] in
            self?.toggleTranscriptAlignmentDebug()
        }
        timelineSurface.onDeleteSilenceRequested = { [weak self] in
            self?.reviewDeadAir()
        }
        timelineSurface.onAcceptDeadAirCandidateRequested = { [weak self] in
            self?.acceptActiveDeadAirCandidate()
        }
        timelineSurface.onAcceptHighConfidenceDeadAirCandidatesRequested = { [weak self] in
            self?.acceptHighConfidenceDeadAirCandidates()
        }
        timelineSurface.onRejectDeadAirCandidateRequested = { [weak self] in
            self?.rejectActiveDeadAirCandidate()
        }
        timelineSurface.onAuditionDeadAirCandidateRequested = { [weak self] in
            self?.auditionActiveDeadAirCandidate()
        }
        timelineSurface.onNextDeadAirCandidateRequested = { [weak self] in
            self?.stepActiveDeadAirCandidate(by: 1)
        }
        timelineSurface.onPreviousDeadAirCandidateRequested = { [weak self] in
            self?.stepActiveDeadAirCandidate(by: -1)
        }
        timelineSurface.onFadeInRequested = { [weak self] in
            self?.applyFadeEffect(.fadeIn)
        }
        timelineSurface.onFadeOutRequested = { [weak self] in
            self?.applyFadeEffect(.fadeOut)
        }
        timelineSurface.onReapplyLastEffect = { [weak self] in
            self?.reapplyLastEffect()
        }
        timelineSurface.onSeekRequested = { [weak self] progress in
            self?.markTimelineHotInteraction(reason: "seek")
            self?.seek(to: progress)
        }
        timelineSurface.onPlayFromProgress = { [weak self] progress in
            self?.markTimelineHotInteraction(reason: "play-from-progress")
            self?.play(from: progress)
        }
        timelineSurface.onSelectionChanged = { [weak self] selection in
            self?.markTimelineHotInteraction(reason: "selection")
            self?.updateSelection(selection)
        }
        timelineSurface.onFrameStatsChanged = { [weak self] frameStats in
            self?.updateFrameStats(frameStats)
        }
        timelineSurface.onViewportChanged = { [weak self] viewport in
            self?.markTimelineHotInteraction(reason: "viewport")
            self?.timelineViewportDidChange(viewport)
        }
        timelineSurface.onTimelineInteractionBegan = { [weak self] in
            self?.markTimelineHotInteraction(reason: "timeline-began")
            self?.clearSelectedTrack()
        }
        timelineSurface.onTrackLaneLayoutChanged = { [weak self] layout in
            self?.updateTrackLaneLayout(layout)
        }
        timelineSurface.onTrackReorderCommitted = { [weak self] trackID, targetIndex in
            self?.commitTrackReorder(trackID: trackID, targetIndex: targetIndex)
        }
        timelineSurface.onLoopRangeChanged = { [weak self] loopRange in
            self?.updateTimelineLoopRange(loopRange)
        }
        timelineSurface.onLoopRangeEnabledChanged = { [weak self] isEnabled in
            self?.updateTimelineLoopRangeEnabled(isEnabled)
        }
        timelineSurface.onPlaybackVisualProgressChanged = { [weak self] progress in
            self?.updateTranscriptActiveWord(progress: progress)
        }
        addTrackButton.onPressed = { [weak self] in
            self?.addEmptyTrack()
        }
        trackControlsStack.onVerticalScroll = { [weak self] deltaPixels in
            self?.timelineSurface.scrollTracks(byPixels: deltaPixels)
        }
        timelineZoomControls.onHorizontalZoomChanged = { [weak self] value in
            self?.markTimelineHotInteraction(reason: "horizontal-zoom-control")
            self?.timelineSurface.setHorizontalZoomNormalized(value)
        }
        timelineZoomControls.onVerticalZoomChanged = { [weak self] value in
            self?.markTimelineHotInteraction(reason: "vertical-zoom-control")
            self?.timelineSurface.setVerticalZoomNormalized(value)
        }
        timelineZoomControls.onZoomEditingEnded = { [weak self] in
            self?.timelineSurface.finishZoomControlInteraction()
        }
        horizontalTimelineScrollbar.onValueChanged = { [weak self] value in
            self?.markTimelineHotInteraction(reason: "horizontal-scrollbar")
            self?.timelineSurface.setHorizontalScrollNormalized(value)
        }
        horizontalTimelineScrollbar.onEditingEnded = { [weak self] in
            self?.timelineSurface.finishNavigationScrollbarInteraction()
        }
        verticalTimelineScrollbar.onValueChanged = { [weak self] value in
            self?.markTimelineHotInteraction(reason: "vertical-scrollbar")
            self?.timelineSurface.setVerticalScrollNormalized(value)
        }
        verticalTimelineScrollbar.onEditingEnded = { [weak self] in
            self?.timelineSurface.finishNavigationScrollbarInteraction()
        }
        volumeControl.onVolumeChanged = { [weak self] volume in
            self?.playbackController.setPerceptualVolume(volume)
        }
        volumeControl.onVolumeEditingEnded = { [weak self] in
            self?.updateLoudnessMeter()
        }
        performanceDashboardButton.onPressed = { [weak self] in
            PerformanceDashboardWindowController.shared.showDashboard(relativeTo: self?.window)
        }
        audioExportStatusButton.target = self
        audioExportStatusButton.action = #selector(audioExportStatusButtonPressed(_:))
        editScopeControl.target = self
        editScopeControl.action = #selector(editScopeChanged(_:))
        editScopeControlsRow.addArrangedSubview(editScopeTitleLabel)
        editScopeControlsRow.addArrangedSubview(editScopeControl)
        editScopeControlsRow.addArrangedSubview(editScopeHintLabel)
        editScopeStack.addArrangedSubview(editScopeControlsRow)
        transportControlPanel.onAction = { [weak self] action in
            self?.handleTransportAction(action)
        }
        agentCommandBar.onSubmit = { [weak self] prompt in
            self?.agentCommandController.submit(prompt: prompt)
        }
        agentCommandBar.onBlurRequested = { [weak self] in
            guard let self else {
                return
            }
            self.window?.makeFirstResponder(self.timelineSurface)
        }
        agentCommandController.onStateChanged = { [weak self] state in
            self?.agentCommandBar.presentationState = state
        }
        agentCommandController.onRequestSubmitted = { [weak self] request in
            self?.updateStatus("agent: \(request.prompt)")
        }
        agentCommandController.onCommandRequested = { [weak self] command in
            self?.performAgentCommand(command) ??
                AgentCommandResult(
                    status: .failed,
                    message: "Agent command unavailable"
                )
        }
        agentCommandController.onResult = { [weak self] result in
            self?.updateStatus(result.message)
        }
        installAudioDevicePreferencesObserver()

        addSubview(titleLabel)
        addSubview(metadataLabel)
        addSubview(framesPerSecondLabel)
        addSubview(performanceDashboardButton)
        addSubview(audioExportStatusButton)
        addSubview(frameRateHistoryView)
        addSubview(cpuUsageHistoryView)
        addSubview(transportControlPanel)
        addSubview(volumeControl)
        addSubview(timeReadoutLabel)
        addSubview(loudnessMeter)
        addSubview(editScopeStack)
        addSubview(fisheyeControlsStack)
        addSubview(trackControlsStack)
        addSubview(addTrackButton)
        addSubview(timelineSurface)
        addSubview(timelineZoomControls)
        addSubview(horizontalTimelineScrollbar)
        addSubview(verticalTimelineScrollbar)
        addSubview(agentCommandBar)

        let fisheyeTrailingConstraint = fisheyeControlsStack.trailingAnchor.constraint(
            lessThanOrEqualTo: loudnessMeter.leadingAnchor,
            constant: -18
        )
        fisheyeTrailingConstraint.priority = .defaultLow
        let metadataToTransportConstraint = metadataLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: timeReadoutLabel.leadingAnchor,
            constant: -18
        )
        metadataToTransportConstraint.priority = .defaultLow
        let volumeToLoudnessConstraint = volumeControl.trailingAnchor.constraint(
            lessThanOrEqualTo: loudnessMeter.leadingAnchor,
            constant: -18
        )
        volumeToLoudnessConstraint.priority = .defaultLow
        let framesPerSecondWidthConstraint = framesPerSecondLabel.widthAnchor.constraint(equalToConstant: 390)
        framesPerSecondWidthConstraint.priority = .defaultLow
        let transportPanelWidthConstraint = transportControlPanel.widthAnchor.constraint(equalToConstant: 116)
        transportPanelWidthConstraint.priority = .defaultHigh
        let volumeControlWidthConstraint = volumeControl.widthAnchor.constraint(equalToConstant: 150)
        volumeControlWidthConstraint.priority = .defaultLow
        let loudnessMeterWidthConstraint = loudnessMeter.widthAnchor.constraint(equalToConstant: 292)
        loudnessMeterWidthConstraint.priority = .defaultLow
        let agentCommandBarWidthConstraint = agentCommandBar.widthAnchor.constraint(equalToConstant: 620)
        agentCommandBarWidthConstraint.priority = .defaultHigh
        let timelineZoomControlsLeadingConstraint = timelineZoomControls.leadingAnchor.constraint(
            greaterThanOrEqualTo: editScopeStack.trailingAnchor,
            constant: 16
        )
        timelineZoomControlsLeadingConstraint.priority = .defaultHigh
        let trackControlsBelowDebugConstraint = trackControlsStack.topAnchor.constraint(
            equalTo: fisheyeControlsStack.bottomAnchor,
            constant: 14
        )
        let trackControlsBelowHeaderConstraint = trackControlsStack.topAnchor.constraint(
            equalTo: titleLabel.bottomAnchor,
            constant: 56
        )
        self.framesPerSecondWidthConstraint = framesPerSecondWidthConstraint
        self.trackControlsBelowDebugConstraint = trackControlsBelowDebugConstraint
        self.trackControlsBelowHeaderConstraint = trackControlsBelowHeaderConstraint

        NSLayoutConstraint.activate([
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: 66),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 84),

            metadataLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            metadataLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 14),
            metadataToTransportConstraint,

            framesPerSecondLabel.centerYAnchor.constraint(equalTo: frameRateHistoryView.centerYAnchor),
            framesPerSecondLabel.trailingAnchor.constraint(equalTo: performanceDashboardButton.leadingAnchor, constant: -8),
            framesPerSecondWidthConstraint,

            performanceDashboardButton.centerYAnchor.constraint(equalTo: frameRateHistoryView.centerYAnchor),
            performanceDashboardButton.trailingAnchor.constraint(equalTo: frameRateHistoryView.leadingAnchor, constant: -8),
            performanceDashboardButton.widthAnchor.constraint(equalToConstant: 30),
            performanceDashboardButton.heightAnchor.constraint(equalToConstant: 24),

            audioExportStatusButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            audioExportStatusButton.trailingAnchor.constraint(equalTo: loudnessMeter.trailingAnchor),
            audioExportStatusButton.widthAnchor.constraint(equalToConstant: 150),
            audioExportStatusButton.heightAnchor.constraint(equalToConstant: 24),

            frameRateHistoryView.bottomAnchor.constraint(equalTo: loudnessMeter.topAnchor, constant: -6),
            frameRateHistoryView.leadingAnchor.constraint(equalTo: loudnessMeter.leadingAnchor),
            frameRateHistoryView.trailingAnchor.constraint(equalTo: cpuUsageHistoryView.leadingAnchor, constant: -8),
            frameRateHistoryView.heightAnchor.constraint(equalToConstant: 24),

            cpuUsageHistoryView.centerYAnchor.constraint(equalTo: frameRateHistoryView.centerYAnchor),
            cpuUsageHistoryView.trailingAnchor.constraint(equalTo: loudnessMeter.trailingAnchor),
            cpuUsageHistoryView.widthAnchor.constraint(equalTo: frameRateHistoryView.widthAnchor),
            cpuUsageHistoryView.heightAnchor.constraint(equalTo: frameRateHistoryView.heightAnchor),

            transportControlPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            transportControlPanel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            transportPanelWidthConstraint,
            transportControlPanel.heightAnchor.constraint(equalToConstant: 106),

            volumeControl.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            volumeControl.leadingAnchor.constraint(equalTo: transportControlPanel.trailingAnchor, constant: 20),
            volumeControlWidthConstraint,
            volumeControl.heightAnchor.constraint(equalToConstant: 30),
            volumeToLoudnessConstraint,

            timeReadoutLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            timeReadoutLabel.trailingAnchor.constraint(equalTo: transportControlPanel.leadingAnchor, constant: -16),

            loudnessMeter.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            loudnessMeter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            loudnessMeterWidthConstraint,
            loudnessMeter.heightAnchor.constraint(equalToConstant: 34),

            editScopeStack.leadingAnchor.constraint(equalTo: trackControlsStack.trailingAnchor, constant: 10),
            editScopeStack.trailingAnchor.constraint(lessThanOrEqualTo: loudnessMeter.leadingAnchor, constant: -20),
            editScopeStack.bottomAnchor.constraint(equalTo: trackControlsStack.topAnchor, constant: -10),
            editScopeControlsRow.heightAnchor.constraint(equalToConstant: 26),
            editScopeHintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            fisheyeControlsStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            fisheyeControlsStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            fisheyeTrailingConstraint,
            fisheyeControlsStack.heightAnchor.constraint(equalToConstant: 34),

            trackControlsBelowDebugConstraint,
            trackControlsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            trackControlsStack.bottomAnchor.constraint(equalTo: timelineSurface.bottomAnchor),
            trackControlsStack.widthAnchor.constraint(equalToConstant: 158),

            addTrackButton.leadingAnchor.constraint(equalTo: trackControlsStack.leadingAnchor),
            addTrackButton.trailingAnchor.constraint(equalTo: trackControlsStack.trailingAnchor),
            addTrackButton.centerYAnchor.constraint(equalTo: agentCommandBar.centerYAnchor),
            addTrackButton.heightAnchor.constraint(equalToConstant: 36),

            timelineSurface.topAnchor.constraint(equalTo: trackControlsStack.topAnchor),
            timelineSurface.leadingAnchor.constraint(equalTo: trackControlsStack.trailingAnchor, constant: 10),
            timelineSurface.trailingAnchor.constraint(equalTo: verticalTimelineScrollbar.leadingAnchor, constant: -6),
            timelineSurface.bottomAnchor.constraint(equalTo: horizontalTimelineScrollbar.topAnchor, constant: -6),

            verticalTimelineScrollbar.topAnchor.constraint(equalTo: timelineSurface.topAnchor),
            verticalTimelineScrollbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            verticalTimelineScrollbar.bottomAnchor.constraint(equalTo: timelineSurface.bottomAnchor),
            verticalTimelineScrollbar.widthAnchor.constraint(equalToConstant: 16),

            horizontalTimelineScrollbar.leadingAnchor.constraint(equalTo: timelineSurface.leadingAnchor),
            horizontalTimelineScrollbar.trailingAnchor.constraint(equalTo: timelineSurface.trailingAnchor),
            horizontalTimelineScrollbar.bottomAnchor.constraint(equalTo: agentCommandBar.topAnchor, constant: -8),
            horizontalTimelineScrollbar.heightAnchor.constraint(equalToConstant: 16),

            timelineZoomControls.trailingAnchor.constraint(equalTo: timelineSurface.trailingAnchor),
            timelineZoomControls.bottomAnchor.constraint(equalTo: timelineSurface.topAnchor, constant: -8),
            timelineZoomControlsLeadingConstraint,
            timelineZoomControls.widthAnchor.constraint(equalToConstant: 252),
            timelineZoomControls.heightAnchor.constraint(equalToConstant: 28),

            agentCommandBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            agentCommandBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
            agentCommandBar.leadingAnchor.constraint(greaterThanOrEqualTo: addTrackButton.trailingAnchor, constant: 24),
            agentCommandBar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            agentCommandBarWidthConstraint,

        ])

        updateEffectCommandState()
        applyDefaultWaveformInteractionTuning()
        setDebugToolsVisible(Self.defaultDebugToolsVisible)
        loudnessMeter.display(levels: .silence)
        transportControlPanel.displayOutputActivity(levels: .silence)
        transportControlPanel.isPlaying = false
        transportControlPanel.isTransportEnabled = false
        updateTimelineNavigationScrollbars()
        startLoudnessMeterTimer()
        startPerformanceMeterTimer()
    }

    override func layout() {
        super.layout()
        updateResponsiveChromeVisibilityIfNeeded()
        layoutTrackControlViews()
        updateTimelineNavigationScrollbars()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else {
            if !isDenoiseModalInteractionLocked, activeDenoiseRequestID == nil, pendingDenoiseReview == nil {
                timelineSurface.setInteractionSuppressed(false)
            }
            return
        }

        tearDownRuntimeState()
    }

    func prepareForImmediateWindowClose() {
        let startedAt = CACurrentMediaTime()
        cancelDeferredWorkspaceWorkForTeardown(reason: "window-close")
        persistLatestTimelineViewport(flushImmediately: false, schedulesLaunchSnapshot: false)

        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        LaunchStartupTrace.shared.mark(
            .windowClosePrepared,
            fields: [
                "elapsedMs": String(format: "%.2f", elapsedMilliseconds),
                "tracks": "\(projectTracks.count)",
                "launchSnapshotWrite": "false",
                "firstFramePacketWrite": "false",
            ]
        )
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: elapsedMilliseconds > 8 ? .warning : .info,
            name: "project-window-close-prepared",
            message: "Prepared window close without synchronously writing launch waveform caches.",
            fields: [
                "elapsedMs": String(format: "%.2f", elapsedMilliseconds),
                "tracks": "\(projectTracks.count)",
                "launchSnapshotWrite": "false",
                "firstFramePacketWrite": "false",
                "canceledAutosaveWork": "true",
                "canceledLaunchCacheWork": "true",
            ]
        )
    }

    func startupCloseSmokeSnapshot() -> WorkspaceStartupCloseSmokeSnapshot {
        let drawableWaveformTrackCount = projectTracks.filter {
            $0.waveformOverview?.isEmpty == false || $0.sourceWaveformOverview?.isEmpty == false
        }.count
        let durationOnlyTrackCount = projectTracks.filter {
            ($0.waveformOverview?.isEmpty ?? true) &&
                ($0.sourceWaveformOverview?.isEmpty ?? true) &&
                ($0.durationHint ?? 0) > 0
        }.count
        let blankTrackCount = projectTracks.count - drawableWaveformTrackCount - durationOnlyTrackCount
        let placeholderTrackCount = projectTracks.filter {
            $0.sourceURL.path == "/dev/null" &&
                ($0.waveformOverview?.isEmpty ?? true) &&
                ($0.sourceWaveformOverview?.isEmpty ?? true)
        }.count

        let visualReady: Bool
        switch projectReadinessState {
        case .empty, .launchPreviewLoading, .failed:
            visualReady = drawableWaveformTrackCount > 0 && blankTrackCount == 0
        case .visualReady, .playbackHydrating, .playbackReady, .playbackReadyWithFailures:
            visualReady = true
        }

        let pendingDeferredEditWorkCount =
            editMaterializationTasks.count +
            optimisticDeleteWaveformTasks.count +
            editWaveformRefinementTasks.count +
            (postDeleteRefreshWorkItem == nil ? 0 : 1) +
            (scheduledPlaybackReloadWorkItem == nil ? 0 : 1)
        let pendingDeferredWorkspaceWorkCount =
            pendingDeferredEditWorkCount +
            launchWaveformCacheTasks.count +
            activeImportOperationIDs.count +
            (audioImportPrewarm == nil ? 0 : 1) +
            (projectHydrationQueue == nil ? 0 : 1) +
            (viewportPersistenceWorkItem == nil ? 0 : 1) +
            (autosaveWorkItem == nil ? 0 : 1) +
            (launchSnapshotSaveWorkItem == nil ? 0 : 1) +
            (pendingLaunchCacheWriteRequest == nil ? 0 : 1) +
            (scheduledProjectTrackMixWorkItem == nil ? 0 : 1) +
            (deadAirAuditionStopTask == nil ? 0 : 1) +
            (denoiseHighlightFadeTask == nil ? 0 : 1) +
            (transcriptionHighlightFadeTask == nil ? 0 : 1)

        return WorkspaceStartupCloseSmokeSnapshot(
            trackCount: projectTracks.count,
            drawableWaveformTrackCount: drawableWaveformTrackCount,
            durationOnlyTrackCount: durationOnlyTrackCount,
            blankTrackCount: max(0, blankTrackCount),
            placeholderTrackCount: placeholderTrackCount,
            mutedTrackCount: projectTracks.filter(\.isMuted).count,
            soloedTrackCount: projectTracks.filter(\.isSoloed).count,
            readinessDescription: projectReadinessState.statusText,
            isVisualReady: visualReady,
            playbackHasSource: playbackControllerStorage?.hasSource ?? false,
            playbackPrimedTrackCount: projectPlaybackPrimedTrackIDs.count,
            isLaunchVisualPreviewPendingImmediateRender: isLaunchVisualPreviewPendingImmediateRender,
            isDeferredProjectRestorePending: isDeferredProjectRestorePending,
            isLoadingProject: isLoadingProject,
            hasCurrentProjectURL: currentProjectURL != nil,
            isLaunchSnapshotWriteScheduled: launchSnapshotSaveWorkItem != nil,
            isLaunchCacheWriteInFlight: launchCacheWriteInFlight,
            hasPendingLaunchCacheWrite: pendingLaunchCacheWriteRequest != nil,
            pendingDeferredEditWorkCount: pendingDeferredEditWorkCount,
            pendingDeferredWorkspaceWorkCount: pendingDeferredWorkspaceWorkCount,
            statusText: currentPlaybackStatus
        )
    }

    func startupCloseSmokeRequestLaunchCacheDuringHotInteraction() -> Bool {
        markTimelineHotInteraction(reason: "startup-close-smoke")
        return scheduleLaunchSnapshotSaveIfNeeded(reason: "startup-close-hot-path-smoke", delay: 0)
    }

    func userPerceivedTimingSmokeSnapshot() -> WorkspaceUserPerceivedTimingSmokeSnapshot {
        let startupSnapshot = startupCloseSmokeSnapshot()
        let playbackSnapshot = playbackController.snapshot()
        return WorkspaceUserPerceivedTimingSmokeSnapshot(
            trackCount: startupSnapshot.trackCount,
            drawableWaveformTrackCount: startupSnapshot.drawableWaveformTrackCount,
            playbackHasSource: startupSnapshot.playbackHasSource,
            playbackPrimedTrackCount: startupSnapshot.playbackPrimedTrackCount,
            isPlaying: playbackSnapshot.isPlaying,
            playheadProgress: visualPlayheadProgress,
            selectedRangeStartProgress: selectedTimelineRange?.startProgress,
            selectedRangeEndProgress: selectedTimelineRange?.endProgress,
            selectedTrackID: selectedTimelineRange?.trackID,
            hasClipboard: audioClipboard != nil,
            editAnimationGeneration: deleteAnimationGeneration,
            projectDuration: projectSelectionDuration,
            currentProjectPath: currentProjectURL?.path,
            statusText: currentPlaybackStatus
        )
    }

    func visualInvariantSmokeSnapshot() -> WorkspaceVisualInvariantSmokeSnapshot {
        let startupSnapshot = startupCloseSmokeSnapshot()
        let projectDuration = projectSelectionDuration
        let renderedPlayheadProgress =
            timelineSurface.displayedPlayheadProgress() ??
            visualPlayheadProgress
        let selectedDuration = selectedTimelineRange.map {
            $0.duration(in: projectDuration)
        }
        let timelineViewport = currentTimelineViewport()
        let trackSnapshots = projectTracks.map { track in
            let hasDrawableWaveform = track.waveformOverview?.isEmpty == false ||
                track.sourceWaveformOverview?.isEmpty == false
            let hasDurationHintOnly = !hasDrawableWaveform && (track.durationHint ?? 0) > 0
            let isPlaceholder = track.sourceURL.path == "/dev/null" && !hasDrawableWaveform
            return WorkspaceVisualInvariantSmokeSnapshot.Track(
                id: track.id,
                name: track.name,
                hasDrawableWaveform: hasDrawableWaveform,
                hasDurationHintOnly: hasDurationHintOnly,
                isPlaceholder: isPlaceholder,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed,
                durationSeconds: trackDuration(for: track),
                waveformBinCount: track.waveformOverview?.bins.count ?? 0,
                sourceWaveformBinCount: track.sourceWaveformOverview?.bins.count ?? 0,
                transcriptWordCount: track.transcript?.words.count ?? 0
            )
        }

        return WorkspaceVisualInvariantSmokeSnapshot(
            trackCount: startupSnapshot.trackCount,
            drawableWaveformTrackCount: startupSnapshot.drawableWaveformTrackCount,
            durationOnlyTrackCount: startupSnapshot.durationOnlyTrackCount,
            blankTrackCount: startupSnapshot.blankTrackCount,
            placeholderTrackCount: startupSnapshot.placeholderTrackCount,
            mutedTrackCount: startupSnapshot.mutedTrackCount,
            soloedTrackCount: startupSnapshot.soloedTrackCount,
            readinessDescription: startupSnapshot.readinessDescription,
            isVisualReady: startupSnapshot.isVisualReady,
            playbackHasSource: startupSnapshot.playbackHasSource,
            playbackPrimedTrackCount: startupSnapshot.playbackPrimedTrackCount,
            isLoadingProject: startupSnapshot.isLoadingProject,
            playheadProgress: renderedPlayheadProgress,
            projectDurationSeconds: projectDuration,
            selectedRangeStartProgress: selectedTimelineRange?.startProgress,
            selectedRangeEndProgress: selectedTimelineRange?.endProgress,
            selectedTrackID: selectedTimelineRange?.trackID,
            selectedDurationSeconds: selectedDuration,
            hasClipboard: audioClipboard != nil,
            editAnimationGeneration: deleteAnimationGeneration,
            transcriptLayerVisible: isTranscriptLayerVisible,
            transcriptTrackCount: projectTracks.filter { $0.transcript != nil }.count,
            transcriptWordCount: projectTracks.reduce(0) { $0 + ($1.transcript?.words.count ?? 0) },
            activeTranscriptWordID: activeTranscriptWordID,
            timelineViewportStartProgress: timelineViewport?.startProgress,
            timelineViewportDurationProgress: timelineViewport?.durationProgress,
            timelinePresentationDurationSeconds: timelineSurface.currentTimelineDuration,
            timelinePresentationMatchesProject: timelinePresentationMatchesCanonicalProject(),
            currentProjectPath: currentProjectURL?.path,
            statusText: currentPlaybackStatus,
            tracks: trackSnapshots
        )
    }

    func visualInvariantSmokeLastCommittedEditRange() -> Range<TimeInterval>? {
        guard
            case let .transaction(record)? = editUndoStack.last,
            let range = record.command.range
        else {
            return nil
        }
        return range.start.seconds..<range.end.seconds
    }

    func hotPathContractSmokeResetDiagnostics() {
        latestTimelineFrameStats = nil
        latestUndoRestoreStageMilliseconds = [:]
        timelineSurface.hotPathContractSmokeResetTranscriptDiagnostics()
        PerformanceDashboardWindowController.resetDiagnosticsForSmokeTesting()
        SoundtimeMainThreadStallMonitor.shared.resetForSmokeTesting()
        SoundtimeDiagnostics.shared.resetForSmokeTesting()
    }

    func hotPathContractSmokeBeginFrameStatsWindow(duration: CFTimeInterval = 0.45) {
        hotPathContractSmokeProtectedUntil = max(
            hotPathContractSmokeProtectedUntil,
            CACurrentMediaTime() + max(duration, 0.01) + launchCacheHotPathQuietInterval
        )
        timelineSurface.hotPathContractSmokeBeginFrameStatsWindow(duration: duration)
    }

    func hotPathContractSmokeHasFrameStats() -> Bool {
        latestTimelineFrameStats != nil
    }

    func hotPathContractSmokeIsRendererReady() -> Bool {
        timelineSurface.hotPathContractSmokeIsRendererReady()
    }

    func hotPathContractSmokeIsProjectFullyHydrated() -> Bool {
        guard !projectTracks.isEmpty else {
            return projectHydrationQueue == nil
        }
        return projectHydrationQueue == nil &&
            projectHydrationCompletedTrackIDs.count + projectHydrationFailedTrackIDs.count >= projectTracks.count
    }

    func interactionReplaySmokeHasUndoState() -> Bool {
        !editUndoStack.isEmpty
    }

    func interactionReplaySmokeUndoDepth() -> Int {
        editUndoStack.count
    }

    func hotPathContractSmokeZoomBurst(stepCount: Int = 8, around anchorProgress: Float = 0.5) {
        timelineSurface.hotPathContractSmokeZoomBurst(stepCount: stepCount, around: anchorProgress)
    }

    func interactionReplaySmokeZoomStep(
        direction: Float,
        around anchorProgress: Float = 0.5
    ) -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let elapsedMilliseconds = timelineSurface.interactionReplaySmokeZoomStep(
            direction: direction,
            around: anchorProgress
        )
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: true,
            elapsedMilliseconds: elapsedMilliseconds,
            message: "zoom step submitted",
            editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration
        )
    }

    func interactionReplaySmokePanBurst(stepCount: Int = 12, progressDistance: Float = 0.18) -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let submissionMilliseconds = timelineSurface.interactionReplaySmokePanBurst(stepCount: stepCount, progressDistance: progressDistance)
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: true,
            elapsedMilliseconds: submissionMilliseconds,
            message: "pan replay submitted",
            editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration
        )
    }

    func visualInvariantSmokePanAndSelectRange(
        trackIndex: Int,
        viewportStartProgress: Float,
        viewportDurationProgress: Float,
        startViewportProgress: Double,
        endViewportProgress: Double,
        viewportAfterSelectionStartProgress: Float? = nil,
        viewportAfterSelectionDurationProgress: Float? = nil,
        stagedZoomMomentumVelocity: Float? = nil
    ) -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        guard projectTracks.indices.contains(trackIndex) else {
            return WorkspaceUserPerceivedTimingSmokeResult(
                accepted: false,
                elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
                message: "pan-selection target track was missing",
                editAnimationGenerationChanged: false
            )
        }

        let selection = timelineSurface.visualInvariantSmokePanAndSelectRange(
            trackID: projectTracks[trackIndex].id,
            viewport: TimelineViewport(
                startProgress: viewportStartProgress,
                durationProgress: viewportDurationProgress
            ),
            startViewportProgress: startViewportProgress,
            endViewportProgress: endViewportProgress,
            viewportAfterSelection: {
                guard
                    let viewportAfterSelectionStartProgress,
                    let viewportAfterSelectionDurationProgress
                else {
                    return nil
                }
                return TimelineViewport(
                    startProgress: viewportAfterSelectionStartProgress,
                    durationProgress: viewportAfterSelectionDurationProgress
                )
            }(),
            stagedZoomMomentumVelocity: stagedZoomMomentumVelocity
        )
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: selection?.durationProgress ?? 0 > 0,
            elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
            message: selection == nil ?
                "pan-selection replay could not resolve a visible track lane" :
                "pan-selection replay submitted",
            editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration
        )
    }

    func visualInvariantSmokeAdvancePendingZoomMomentum() -> Bool {
        timelineSurface.visualInvariantSmokeAdvancePendingZoomMomentum()
    }

    func interactionReplaySmokeSetLoopRange(
        startProgress: Float,
        durationSeconds: TimeInterval
    ) -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        let projectDuration = max(projectSelectionDuration, 0.001)
        let durationProgress = Float(max(durationSeconds / projectDuration, 0.0005))
        let start = min(max(startProgress, 0), max(0, 1 - durationProgress))
        let loopRange = TimelineLoopRange(startProgress: start, endProgress: min(start + durationProgress, 1))
        updateTimelineLoopRange(loopRange)
        updateTimelineLoopRangeEnabled(true)
        timelineSurface.displayLoopRange(loopRange)
        timelineSurface.displayLoopRangeEnabled(true)
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: loopRange.durationProgress > 0,
            elapsedMilliseconds: elapsedMilliseconds,
            message: "loop range replay state submitted",
            editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration
        )
    }

    func interactionReplaySmokeUndoLastEdit() -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        let hadUndo = !editUndoStack.isEmpty
        undoLastEdit()
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: hadUndo,
            elapsedMilliseconds: elapsedMilliseconds,
            message: hadUndo ?
                "undo replay completed \(transactionHistoryRestoreStageSummary())" :
                "undo replay skipped without undo state",
            editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration
        )
    }

    func interactionReplaySmokeRedoLastEdit() -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        let hadRedo = !editRedoStack.isEmpty
        redoLastEdit()
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: hadRedo,
            elapsedMilliseconds: elapsedMilliseconds,
            message: hadRedo ?
                "redo replay completed \(transactionHistoryRestoreStageSummary())" :
                "redo replay skipped without redo state",
            editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration
        )
    }

    func interactionReplaySmokeTranscriptHoverClickSelect() -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        hotPathContractSmokeShowTranscriptLayerIfAvailable()
        let accepted = timelineSurface.interactionReplaySmokeTranscriptHoverClickSelect()
        if accepted {
            updateTranscriptActiveWord(progress: playbackController.snapshot().progress)
        }
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: accepted,
            elapsedMilliseconds: elapsedMilliseconds,
            message: accepted ? "transcript interaction replay submitted" : "transcript interaction replay found no visible words",
            editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration
        )
    }

    func hotPathContractSmokeShowDevelopmentConsole() {
        PerformanceDashboardWindowController.shared.showDashboard(relativeTo: window)
    }

    func hotPathContractSmokeCloseDevelopmentConsole() {
        PerformanceDashboardWindowController.closeIfLoaded()
    }

    func hotPathContractSmokeShowTranscriptLayerIfAvailable() {
        guard projectTracks.contains(where: { $0.transcript != nil }) else {
            return
        }
        isTranscriptLayerVisible = true
        timelineSurface.displayTranscriptMode(.waveformOverlay)
        refreshTranscriptActiveWordForCurrentVisualPlayhead()
    }

    func hotPathContractSmokeLayoutSignature() -> String {
        timelineSurface.hotPathContractSmokeLayoutSignature()
    }

    func hotPathContractSmokeFlushLayout() {
        guard let contentView = window?.contentView else {
            needsLayout = true
            layoutSubtreeIfNeeded()
            timelineSurface.layoutSubtreeIfNeeded()
            return
        }

        // Constraint changes owned by WorkspaceView can invalidate ancestors
        // before they affect the timeline's final frame. Lay out from the
        // window root downward so a replay never measures deferred AppKit work
        // from the preceding interaction.
        contentView.needsLayout = true
        needsLayout = true
        contentView.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        timelineSurface.layoutSubtreeIfNeeded()
    }

    func hotPathContractSmokeSnapshot() -> WorkspaceHotPathContractSmokeSnapshot {
        let startupSnapshot = startupCloseSmokeSnapshot()
        let diagnostics = SoundtimeDiagnostics.shared.snapshot(limit: 256)
        return WorkspaceHotPathContractSmokeSnapshot(
            trackCount: startupSnapshot.trackCount,
            drawableWaveformTrackCount: startupSnapshot.drawableWaveformTrackCount,
            blankTrackCount: startupSnapshot.blankTrackCount,
            isLoadingProject: startupSnapshot.isLoadingProject,
            playbackHasSource: startupSnapshot.playbackHasSource,
            playbackPrimedTrackCount: startupSnapshot.playbackPrimedTrackCount,
            isLaunchSnapshotWriteScheduled: startupSnapshot.isLaunchSnapshotWriteScheduled,
            isLaunchCacheWriteInFlight: startupSnapshot.isLaunchCacheWriteInFlight,
            hasPendingLaunchCacheWrite: startupSnapshot.hasPendingLaunchCacheWrite,
            isAutosaveScheduled: autosaveWorkItem != nil,
            autosaveScheduleReason: latestAutosaveScheduleReason,
            frameStats: latestTimelineFrameStats.map(WorkspaceHotPathContractFrameStatsSnapshot.init),
            transcriptOverlay: timelineSurface.hotPathContractSmokeTranscriptDiagnosticsSnapshot(),
            performanceDashboard: PerformanceDashboardWindowController.diagnosticsSnapshotForSmokeTesting(),
            mainThreadStallCount: diagnostics.mainThreadStallCount,
            lastMainThreadStallMilliseconds: diagnostics.lastMainThreadStallMilliseconds,
            warningEventCount: diagnostics.warningEventCount,
            severeEventCount: diagnostics.severeEventCount,
            diagnosticEventNames: diagnostics.events.map(\.name),
            latestUndoRestoreStageMilliseconds: latestUndoRestoreStageMilliseconds,
            lastPlaybackReloadErrorDescription: lastPlaybackReloadErrorDescription,
            statusText: currentPlaybackStatus
        )
    }

    func userPerceivedTimingSmokeStartPlayback() -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        if !playbackController.isPlaying {
            togglePlayback()
        }
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        let isPlaying = playbackController.snapshot().isPlaying
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: isPlaying,
            elapsedMilliseconds: elapsedMilliseconds,
            message: isPlaying ? "playback started" : "playback did not start",
            editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration
        )
    }

    func userPerceivedTimingSmokePausePlayback() -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        if playbackController.isPlaying {
            togglePlayback()
        }
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        let isPaused = !playbackController.snapshot().isPlaying
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: isPaused,
            elapsedMilliseconds: elapsedMilliseconds,
            message: isPaused ? "playback paused" : "playback did not pause",
            editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration
        )
    }

    func userPerceivedTimingSmokeSeek(to progress: Float) -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        seek(to: min(max(progress, 0), 1))
        displayPlaybackVisuals(
            progress: playbackController.snapshot().progress,
            isPlaying: playbackController.snapshot().isPlaying,
            syncPlayhead: true,
            synchronizesRenderer: true
        )
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: playbackController.hasSource,
            elapsedMilliseconds: elapsedMilliseconds,
            message: playbackController.hasSource ? "seek visual state published" : "seek skipped without playback source",
            editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration
        )
    }

    func userPerceivedTimingSmokeSelectRange(
        trackIndex: Int,
        startProgress: Double,
        endProgress: Double,
        velocityPixelsPerSecond: CGFloat,
        motionDirection: CGFloat? = nil
    ) -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        guard projectTracks.indices.contains(trackIndex) else {
            return WorkspaceUserPerceivedTimingSmokeResult(
                accepted: false,
                elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
                message: "selection target track was missing",
                editAnimationGenerationChanged: false
            )
        }

        let trackID = projectTracks[trackIndex].id
        let selection = TimelineSelection(
            startProgress: startProgress,
            endProgress: endProgress,
            trackID: trackID
        )
        activeTrackID = trackID
        selectedTrackID = nil
        selectedTrackIDs.removeAll()
        trackSelectionAnchorID = nil
        selectedTimelineRange = selection
        mirrorTimelineSelectionToTranscript(selection)
        publishSelectedTracksToTimeline()
        syncActiveTrackFields()
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        let resolvedMotionDirection = motionDirection ?? (endProgress >= startProgress ? 1 : -1)
        timelineSurface.userPerceivedTimingSmokeDisplayLiveSelection(
            selection,
            leadingProgress: endProgress,
            velocityPixelsPerSecond: velocityPixelsPerSecond,
            direction: resolvedMotionDirection
        )
        updateEffectCommandState()
        updateStatus(currentPlaybackStatus)
        let renderedSelection = timelineSurface.userPerceivedTimingSmokeSelectionDragSnapshot()

        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: selection.durationProgress > 0,
            elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
            message: "selection visual state published",
            editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration,
            expectedLeadingProgress: endProgress,
            renderedLeadingProgress: renderedSelection.map { Double($0.leadingProgress) },
            selectionEdgeErrorPixels: renderedSelection?.edgeErrorPixels(expectedLeadingProgress: endProgress),
            motionDirection: Double(resolvedMotionDirection)
        )
    }

    func interactionReplaySmokePublishLiveSelection(
        trackIndex: Int,
        startProgress: Double,
        endProgress: Double,
        velocityPixelsPerSecond: CGFloat,
        motionDirection: CGFloat
    ) -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        guard projectTracks.indices.contains(trackIndex) else {
            return WorkspaceUserPerceivedTimingSmokeResult(
                accepted: false,
                elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
                message: "live selection target track was missing",
                editAnimationGenerationChanged: false
            )
        }

        let selection = TimelineSelection(
            startProgress: startProgress,
            endProgress: endProgress,
            trackID: projectTracks[trackIndex].id
        )
        timelineSurface.userPerceivedTimingSmokeDisplayLiveSelection(
            selection,
            leadingProgress: endProgress,
            velocityPixelsPerSecond: velocityPixelsPerSecond,
            direction: motionDirection
        )
        let renderedSelection = timelineSurface.userPerceivedTimingSmokeSelectionDragSnapshot()
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: selection.durationProgress > 0,
            elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
            message: "live selection drag state published",
            editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration,
            expectedLeadingProgress: endProgress,
            renderedLeadingProgress: renderedSelection.map { Double($0.leadingProgress) },
            selectionEdgeErrorPixels: renderedSelection?.edgeErrorPixels(expectedLeadingProgress: endProgress),
            motionDirection: Double(motionDirection)
        )
    }

    func userPerceivedTimingSmokeCollapseSelection(
        trackIndex: Int,
        at anchorProgress: Double
    ) -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        guard projectTracks.indices.contains(trackIndex) else {
            return WorkspaceUserPerceivedTimingSmokeResult(
                accepted: false,
                elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
                message: "selection collapse target track was missing",
                editAnimationGenerationChanged: false,
                isIntentionalSelectionCollapse: true
            )
        }

        selectedTimelineRange = nil
        selectedTranscriptSelection = nil
        timelineSurface.displaySelection(nil)
        updateEffectCommandState()
        updateStatus(currentPlaybackStatus)
        let didCollapse = selectedTimelineRange == nil &&
            timelineSurface.userPerceivedTimingSmokeSelectionDragSnapshot() == nil
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: didCollapse,
            elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
            message: didCollapse ? "selection intentionally collapsed" : "selection collapse remained visible",
            editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration,
            expectedLeadingProgress: anchorProgress,
            renderedLeadingProgress: nil,
            selectionEdgeErrorPixels: 0,
            motionDirection: 0,
            isIntentionalSelectionCollapse: true
        )
    }

    func userPerceivedTimingSmokePrepareClipboardFromSelection(
        includePortableBuffer: Bool = false
    ) -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        guard currentEditableSelectionTarget() != nil else {
            return WorkspaceUserPerceivedTimingSmokeResult(
                accepted: false,
                elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
                message: "no editable selection to copy",
                editAnimationGenerationChanged: false
            )
        }

        let previousClipboardID = audioClipboard?.id
        copySelection()
        if
            includePortableBuffer,
            let clipboard = audioClipboard,
            clipboard.id != previousClipboardID,
            clipboard.buffer == nil,
            let duration = clipboardDuration(clipboard)
        {
            audioClipboard = AudioClipboard(
                id: clipboard.id,
                buffer: userPerceivedTimingSmokeClipboardBuffer(duration: duration),
                waveformOverview: clipboard.waveformOverview,
                audioClip: clipboard.audioClip,
                fileClipSourceID: clipboard.fileClipSourceID,
                fileClipSourceURL: clipboard.fileClipSourceURL,
                fileClip: clipboard.fileClip
            )
        }

        let didPrepareClipboard = audioClipboard?.id != previousClipboardID
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: didPrepareClipboard,
            elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
            message: didPrepareClipboard ? "clipboard prepared" : currentPlaybackStatus,
            editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration
        )
    }

    private func userPerceivedTimingSmokeClipboardBuffer(duration: TimeInterval) -> DecodedAudioBuffer {
        let sampleRate = 48_000.0
        let frameCount = max(Int((duration * sampleRate).rounded()), 1)
        var samples = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let phase = Double(frame) / sampleRate
            let envelope = Float(sin(Double.pi * Double(frame) / Double(max(frameCount - 1, 1))))
            samples[frame] = Float(sin(phase * 2 * Double.pi * 440)) * 0.18 * envelope
        }
        return DecodedAudioBuffer(
            url: URL(fileURLWithPath: "/tmp/soundtime-user-perceived-timing-clipboard.wav"),
            sampleRate: sampleRate,
            channelCount: 1,
            frameCount: frameCount,
            samplesByChannel: [samples]
        )
    }

    func userPerceivedTimingSmokeDeleteSelection(useGroupScope: Bool = false) -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        let visualResponseMilliseconds = performTransactionalRangeEdit(
            kind: .rippleDelete,
            scope: useGroupScope ? .group : .track
        )
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        let generationChanged = generationBefore != deleteAnimationGeneration
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: generationChanged,
            elapsedMilliseconds: elapsedMilliseconds,
            message: generationChanged ?
                "delete visual state submitted (\(useGroupScope ? "group" : "track") scope) " +
                    editTransactionStageSummary() :
                "delete visual state did not start",
            editAnimationGenerationChanged: generationChanged,
            visualResponseMilliseconds: visualResponseMilliseconds
        )
    }

    private func editTransactionStageSummary() -> String {
        let transaction = latestEditTransactionStageTimings
        let commit = latestEditCommitStageTimings
        return "planMs=\(formatEditStageMilliseconds(transaction.planMilliseconds)) " +
            "prepareMs=\(formatEditStageMilliseconds(transaction.prepareMilliseconds)) " +
            "effectsMs=\(formatEditStageMilliseconds(transaction.effectsMilliseconds)) " +
            "commitMs=\(formatEditStageMilliseconds(transaction.commitMilliseconds)) " +
            "finalizeMs=\(formatEditStageMilliseconds(transaction.finalizeMilliseconds)) " +
            "commit[captureMs=\(formatEditStageMilliseconds(commit.captureMilliseconds)) " +
            "mutationMs=\(formatEditStageMilliseconds(commit.mutationMilliseconds)) " +
            "renderProjectionMs=\(formatEditStageMilliseconds(commit.renderProjectionMilliseconds)) " +
            "playbackProjectionMs=\(formatEditStageMilliseconds(commit.playbackProjectionMilliseconds)) " +
            "playbackMs=\(formatEditStageMilliseconds(commit.playbackMilliseconds)) " +
            "historyMs=\(formatEditStageMilliseconds(commit.historyMilliseconds))]"
    }

    private func transactionHistoryRestoreStageSummary() -> String {
        let timings = latestTransactionHistoryRestoreStageTimings
        return "indexMs=\(formatEditStageMilliseconds(timings.indexMilliseconds)) " +
            "tracksMs=\(formatEditStageMilliseconds(timings.tracksMilliseconds)) " +
            "modelMs=\(formatEditStageMilliseconds(timings.modelMilliseconds)) " +
            "timelineMs=\(formatEditStageMilliseconds(timings.timelineMilliseconds)) " +
            "playbackMs=\(formatEditStageMilliseconds(timings.playbackMilliseconds)) " +
            "finalizeMs=\(formatEditStageMilliseconds(timings.finalizeMilliseconds))"
    }

    private func formatEditStageMilliseconds(_ milliseconds: Double) -> String {
        String(format: "%.3f", milliseconds)
    }

    func userPerceivedTimingSmokePasteAtPlayhead() -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        let visualResponseMilliseconds = pasteAudio()
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        let generationChanged = generationBefore != deleteAnimationGeneration
        return WorkspaceUserPerceivedTimingSmokeResult(
            accepted: generationChanged,
            elapsedMilliseconds: elapsedMilliseconds,
            message: generationChanged ?
                "paste visual state submitted \(editTransactionStageSummary())" :
                "paste visual state did not start (\(currentPlaybackStatus))",
            editAnimationGenerationChanged: generationChanged,
            visualResponseMilliseconds: visualResponseMilliseconds
        )
    }

    func userPerceivedTimingSmokeWriteCompactProjectSnapshot(to url: URL) -> WorkspaceUserPerceivedTimingSmokeResult {
        let generationBefore = deleteAnimationGeneration
        let startedAt = CACurrentMediaTime()
        do {
            try prepareProjectForSerialization()
            let project = currentProject(includeWaveformPreviews: false)
            try SoundtimeProjectStore.save(project, to: normalizedProjectURL(url))
            return WorkspaceUserPerceivedTimingSmokeResult(
                accepted: true,
                elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
                message: "compact project save completed",
                editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration
            )
        } catch {
            return WorkspaceUserPerceivedTimingSmokeResult(
                accepted: false,
                elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
                message: "compact project save failed: \(error.localizedDescription)",
                editAnimationGenerationChanged: generationBefore != deleteAnimationGeneration
            )
        }
    }

    private func tearDownRuntimeState() {
        cancelDeferredWorkspaceWorkForTeardown(reason: "view-detached")
        persistLatestTimelineViewport(flushImmediately: false, schedulesLaunchSnapshot: false)
        PerformanceDashboardWindowController.closeIfLoaded()
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let audioDevicePreferencesObserver {
            NotificationCenter.default.removeObserver(audioDevicePreferencesObserver)
            self.audioDevicePreferencesObserver = nil
        }
        stopPlaybackTimer()
        scheduledProjectTrackMixWorkItem?.cancel()
        scheduledProjectTrackMixWorkItem = nil
        pendingProjectTrackMixUpdate = false
        loudnessMeterTimer?.invalidate()
        loudnessMeterTimer = nil
        performanceMeterTimer?.invalidate()
        performanceMeterTimer = nil
        activeDenoiseTask?.cancel()
        activeDenoiseTask = nil
        activeTranscriptionTask?.cancel()
        activeTranscriptionTask = nil
        activeTranscriptionProvider = nil
        activeTranscriptionController = nil
        activeTranscriptionJob = nil
        activeDenoiseRequestID = nil
        activeDenoiseProvider = nil
        activeDenoiseTrackID = nil
        activeDenoiseDisplaySelection = nil
        pendingDenoiseReview = nil
        pendingStemSeparationReview = nil
        activeAudioProcessingOperation = nil
        denoiseProgressOverlayStorage?.hide(animated: false)
        transcriptionProgressOverlayStorage?.hide(animated: false)
        denoiseReviewOverlayStorage?.hide(animated: false)
        stemSeparationReviewOverlayStorage?.hide(animated: false)
        setDenoiseModalInteractionLocked(false)
        timelineSurface.displayModalBackdropActive(false)
        timelineSurface.displayProcessingSelectionProgress(selection: nil, fractionCompleted: nil)
        timelineSurface.displayProcessingTrackHighlight(trackID: nil, alpha: 0)
        denoiseHighlightFadeTask?.cancel()
        denoiseHighlightFadeTask = nil
        transcriptionHighlightFadeTask?.cancel()
        transcriptionHighlightFadeTask = nil
        inputRecorderStorage?.stop()
        inputRecorderStorage?.onChunk = nil
        recordingTakeWriter?.cancel()
        recordingTakeWriter = nil
        recordingTrackID = nil
        recordingStartUndoSnapshot = nil
        recordingStartUndoStackCount = nil
        recordingSampleRate = 0
        recordingAccumulator = nil
        playbackControllerStorage?.clear()
        deleteAllOwnedSourceFiles(async: true)
        ImportWorkBudget.shared.setPlaybackActive(false)
    }

    private func cancelDeferredWorkspaceWorkForTeardown(reason: String) {
        workspaceLifecycleGeneration += 1
        projectLoadGeneration += 1
        launchPreviewLoadGeneration += 1
        isLaunchPreviewLoadInFlight = false
        pendingHydrationAfterLaunchPreviewLoad = false
        isDeferredProjectRestorePending = false

        activeImportID = UUID()
        activeImportOperationIDs.removeAll()
        audioImportPrewarm?.admissionTask?.cancel()
        audioImportPrewarm?.previewTask?.cancel()
        audioImportPrewarm?.preparationTask?.cancel()
        audioImportPrewarm = nil
        let importSessionIDs = projectTracks.compactMap(\.importSessionID)
        if !importSessionIDs.isEmpty {
            Task {
                for sessionID in importSessionIDs {
                    await AudioImportCoordinator.shared.cancel(sessionID: sessionID)
                    await AudioImportCoordinator.shared.forget(sessionID: sessionID)
                }
            }
        }

        viewportPersistenceWorkItem?.cancel()
        viewportPersistenceWorkItem = nil
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        autosaveGeneration += 1
        latestAutosaveScheduleReason = reason

        launchSnapshotSaveWorkItem?.cancel()
        launchSnapshotSaveWorkItem = nil
        launchSnapshotSaveGeneration += 1
        pendingLaunchCacheWriteRequest = nil
        launchWaveformCacheTasks.cancelAll()

        projectHydrationQueue?.cancel()
        projectHydrationQueue = nil
        projectHydrationLaunchCacheWriteScheduled = false
        projectHydrationImprovedLaunchWaveforms = false
        cancelAllEditMaterialization()

        scheduledProjectTrackMixWorkItem?.cancel()
        scheduledProjectTrackMixWorkItem = nil
        pendingProjectTrackMixUpdate = false
        deadAirAuditionStopTask?.cancel()
        deadAirAuditionStopTask = nil
        denoiseHighlightFadeTask?.cancel()
        denoiseHighlightFadeTask = nil
        transcriptionHighlightFadeTask?.cancel()
        transcriptionHighlightFadeTask = nil
    }

    private func configureFisheyeTuningControls() {
        let controls = [
            fisheyeRadiusControl,
            fisheyePowerControl,
            fisheyeStartControl,
            fisheyeFullControl,
            fisheyeCurveControl,
            fisheyeActivateDurationControl,
        ]
        for control in controls {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.onValueChanged = { [weak self] _ in
                self?.updateWaveformFisheyeTuning()
            }
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            fisheyeControlsStack.addArrangedSubview(control)
            let widthConstraint = control.widthAnchor.constraint(equalToConstant: 136)
            widthConstraint.priority = .defaultLow
            widthConstraint.isActive = true
        }
    }

    private func ensureDebugTuningControlsConfigured() {
        guard !debugTuningControlsConfigured else {
            return
        }
        debugTuningControlsConfigured = true
        configureFisheyeTuningControls()
    }

    private func toggleDebugTools() {
        setDebugToolsVisible(!debugToolsVisible)
    }

    private func setDebugToolsVisible(_ isVisible: Bool) {
        if isVisible {
            ensureDebugTuningControlsConfigured()
        }
        debugToolsVisible = isVisible
        timelineSurface.isDebugToolsVisible = isVisible
        lastResponsiveLayoutWidth = -1
        updateResponsiveChromeVisibilityIfNeeded()
        needsLayout = true
    }

    private func updateResponsiveChromeVisibilityIfNeeded() {
        guard abs(bounds.width - lastResponsiveLayoutWidth) > 0.5 else {
            return
        }

        lastResponsiveLayoutWidth = bounds.width
        let width = bounds.width
        let showsTitle = width >= 290
        let showsMetadata = width >= 560
        let showsTime = width >= 440
        let showsVolume = width >= 620
        let showsLoudness = width >= 760
        let showsFrameHistory = width >= 380
        let showsEditScope = width >= 720
        let showsFrameStatsText = width >= 500
        let showsDebugText = debugToolsVisible && width >= 760
        let showsDebugSliders = SoundtimeFeatureFlags.waveformFisheye && debugToolsVisible && width >= 980

        titleLabel.isHidden = !showsTitle
        metadataLabel.isHidden = !showsMetadata
        timeReadoutLabel.isHidden = !showsTime
        volumeControl.isHidden = !showsVolume
        loudnessMeter.isHidden = !showsLoudness
        frameRateHistoryView.isHidden = !showsFrameHistory
        cpuUsageHistoryView.isHidden = !showsFrameHistory || !showsLoudness
        framesPerSecondLabel.isHidden = !showsFrameStatsText
        editScopeLayoutAllowsDisplay = showsEditScope
        updateEditScopeVisibility(animated: false)
        fisheyeControlsStack.isHidden = !showsDebugSliders
        framesPerSecondWidthConstraint?.constant = showsDebugText ? 390 : 58
        updateDebugTuningLayout()
    }

    private func updateDebugTuningLayout() {
        let width = bounds.width
        let showsDebugSliders = SoundtimeFeatureFlags.waveformFisheye && debugToolsVisible && width >= 980
        trackControlsBelowDebugConstraint?.isActive = showsDebugSliders
        trackControlsBelowHeaderConstraint?.isActive = !showsDebugSliders
    }

    private var hasSelectedTimelineRegion: Bool {
        guard let selectedTimelineRange else {
            return false
        }

        return selectedTimelineRange.durationProgress > 0
    }

    private func updateEditScopeVisibility(animated: Bool) {
        let shouldShow = editScopeLayoutAllowsDisplay && hasSelectedTimelineRegion
        editScopeTitleLabel.isEnabled = shouldShow
        editScopeControl.isEnabled = shouldShow
        editScopeHintLabel.isEnabled = shouldShow
        updateDebugTuningLayout()

        guard editScopeLayoutAllowsDisplay else {
            editScopeStack.isHidden = true
            editScopeStack.alphaValue = 0
            editScopeVisibleForSelection = false
            return
        }

        editScopeStack.isHidden = false
        let targetAlpha: CGFloat = shouldShow ? 1 : 0
        let didChange =
            editScopeVisibleForSelection != shouldShow ||
            abs(editScopeStack.alphaValue - targetAlpha) > 0.001
        editScopeVisibleForSelection = shouldShow
        guard didChange else {
            return
        }

        guard animated, window != nil else {
            editScopeStack.alphaValue = targetAlpha
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = editScopeFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: shouldShow ? .easeOut : .easeIn)
            editScopeStack.animator().alphaValue = targetAlpha
        }
    }

    @objc private func editScopeChanged(_ sender: NSSegmentedControl) {
        guard let nextScope = EditScope(rawValue: sender.selectedSegment) else {
            sender.selectedSegment = editScope.rawValue
            return
        }

        editScope = nextScope
        updateEditScopeHint()
        updateStatus(currentPlaybackStatus)
        window?.makeFirstResponder(timelineSurface)
    }

    private func handleTransportAction(_ action: TransportControlPanelView.TransportAction) {
        guard !isDenoiseProcessingActive else {
            updateTransportControlState(isPlaying: false)
            return
        }

        switch action {
        case .togglePlayback:
            togglePlayback()
        }

        window?.makeFirstResponder(timelineSurface)
        updateTransportControlState(isPlaying: playbackController.isPlaying)
    }

    private func updateTransportControlState(isPlaying: Bool) {
        let isDenoiseModalActive = isDenoiseModalInteractionLocked
        transportControlPanel.isPlaying = isDenoiseModalActive ? false : isPlaying
        transportControlPanel.isTransportEnabled = !isDenoiseModalActive &&
            (playbackController.hasSource || recordingTrackID != nil)
    }

    private func updateWaveformFisheyeTuning() {
        timelineSurface.updateWaveformFisheyeTuning(
            radius: Float(fisheyeRadiusControl.value),
            exponent: Float(fisheyePowerControl.value),
            minimumVisibleDuration: fisheyeStartControl.value,
            maximumVisibleDuration: fisheyeFullControl.value,
            fadeCurve: Float(fisheyeCurveControl.value),
            activationDuration: fisheyeActivateDurationControl.value / 1_000
        )
    }

    private func applyDefaultWaveformInteractionTuning() {
        timelineSurface.updateWaveformFisheyeTuning(
            radius: Float(FisheyeDefaults.radius),
            exponent: Float(FisheyeDefaults.power),
            minimumVisibleDuration: FisheyeDefaults.start,
            maximumVisibleDuration: FisheyeDefaults.full,
            fadeCurve: Float(FisheyeDefaults.curve),
            activationDuration: FisheyeDefaults.activationMilliseconds / 1_000
        )
        timelineSurface.updateSelectionDragWaveformTuning(.defaultValue)
    }

    private func resetWaveformFisheyeTuningToDefaults() {
        guard debugTuningControlsConfigured else {
            applyDefaultWaveformInteractionTuning()
            return
        }
        fisheyeRadiusControl.value = FisheyeDefaults.radius
        fisheyePowerControl.value = FisheyeDefaults.power
        fisheyeStartControl.value = FisheyeDefaults.start
        fisheyeFullControl.value = FisheyeDefaults.full
        fisheyeCurveControl.value = FisheyeDefaults.curve
        fisheyeActivateDurationControl.value = FisheyeDefaults.activationMilliseconds
        updateWaveformFisheyeTuning()
    }

    private func installTransportKeyMonitor() {
        guard keyDownMonitor == nil else {
            return
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            return self.handleWindowKeyDown(event)
        }
    }

    private func installAudioDevicePreferencesObserver() {
        guard audioDevicePreferencesObserver == nil else {
            return
        }

        audioDevicePreferencesObserver = NotificationCenter.default.addObserver(
            forName: AudioDevicePreferences.didChangeNotification,
            object: AudioDevicePreferences.shared,
            queue: .main
        ) { [weak self] notification in
            let changedDeviceKind = notification.userInfo?[
                AudioDevicePreferences.changedDeviceKindUserInfoKey
            ] as? String
            Task { @MainActor in
                self?.handleAudioDevicePreferencesChanged(changedDeviceKind: changedDeviceKind)
            }
        }
    }

    private func handleAudioDevicePreferencesChanged(changedDeviceKind: String?) {
        if changedDeviceKind == "input", recordingTrackID != nil {
            stopRecording()
        }

        do {
            try playbackController.refreshOutputDevice()
            updateStatus("audio device updated")
        } catch {
            stopPlaybackTimer()
            updateStatus("audio device failed: \(error.localizedDescription)")
        }
    }

    private func handleWindowKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else {
            return event
        }

        if pendingDenoiseReview != nil {
            if event.keyCode == 49 {
                guard !event.isARepeat else {
                    return nil
                }
                denoiseReviewOverlay.togglePreviewPlayback()
                return nil
            }
            if event.keyCode == 53 {
                rejectPendingDenoiseReview()
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                acceptPendingDenoiseReview()
                return nil
            }
            return event.modifierFlags.contains(.command) ? event : nil
        }

        if pendingStemSeparationReview != nil {
            if event.keyCode == 49 {
                guard !event.isARepeat else {
                    return nil
                }
                stemSeparationReviewOverlay.togglePreviewPlayback()
                return nil
            }
            if event.keyCode == 53 {
                rejectPendingStemSeparationReview()
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                acceptPendingStemSeparationReview()
                return nil
            }
            return event.modifierFlags.contains(.command) ? event : nil
        }

        if isDenoiseModalInteractionLocked {
            return event.modifierFlags.contains(.command) ? event : nil
        }

        if window?.firstResponder is NSTextView {
            return event
        }

        let shortcutModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if
            event.charactersIgnoringModifiers?.lowercased() == "d",
            shortcutModifiers == [.command, .shift]
        {
            toggleDebugTools()
            return nil
        }

        if event.keyCode == 6, event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.shift) {
                redoLastEdit()
            } else {
                undoLastEdit()
            }
            return nil
        }

        if
            event.charactersIgnoringModifiers?.lowercased() == "b",
            event.modifierFlags.contains(.command)
        {
            splitAtPlayhead()
            return nil
        }

        if event.keyCode == 53 {
            dismissTimelineSelection()
            return nil
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            if event.modifierFlags.contains(.command) {
                clearSelection()
                return nil
            }

            if selectedTrackID != nil || (selectedTimelineRange?.durationProgress ?? 0) > 0 {
                var trace = DeleteTimingTrace(operation: "delete-selection")
                trace.mark(
                    "command-received",
                    message: "Delete command reached the workspace key monitor.",
                    fields: [
                        "scope": editScope.title,
                        "selectedTrackCount": "\(selectedTrackIDs.count + (selectedTrackID == nil ? 0 : 1))",
                        "hasTimelineSelection": "\(selectedTimelineRange != nil)",
                        "keyCode": "\(event.keyCode)",
                    ]
                )
                deleteSelectedTrackOrSelection(trace: trace)
                return nil
            }
        }

        if
            shortcutModifiers.isEmpty,
            event.keyCode == 123 || event.keyCode == 124
        {
            skipPlayback(by: event.keyCode == 124 ? transportArrowSkipDuration : -transportArrowSkipDuration)
            return nil
        }

        let transportModifierMask: NSEvent.ModifierFlags = [.command, .control, .option]
        guard
            event.keyCode == 49,
            event.modifierFlags.intersection(transportModifierMask).isEmpty
        else {
            return event
        }

        guard !event.isARepeat else {
            return nil
        }

        togglePlayback()
        return nil
    }

    func restoreLastProjectIfNeeded() {
        guard !hasRestoredLastProject else {
            return
        }
        hasRestoredLastProject = true
        defer {
            finishDeferredProjectRestore()
        }

        if
            launchPlan.restoresProject,
            let targetProjectURL = launchPlan.targetProjectURL
        {
            if FileManager.default.fileExists(atPath: targetProjectURL.path) {
                if launchPlan.usesAutosaveRecovery {
                    loadProject(from: targetProjectURL)
                } else {
                    loadRecoveredAutosave(from: targetProjectURL)
                }
                return
            }

            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .warning,
                name: "launch-plan-target-missing",
                message: "The launch plan target disappeared before project hydration.",
                fields: launchPlan.diagnosticFields
            )
        }

        if let lastProjectURL = SoundtimeProjectStore.lastProjectURL() {
            if FileManager.default.fileExists(atPath: lastProjectURL.path) {
                loadProject(from: lastProjectURL)
                return
            } else {
                SoundtimeProjectStore.forgetLastProjectURL()
                updateStatus("last project file was missing")
            }
        }

        if let recoveryURL = SoundtimeProjectStore.recoverableAutosaveURLs().first {
            loadRecoveredAutosave(from: recoveryURL)
        }
    }

    func restoreLastProjectAfterLaunchPreviewRender() {
        guard isDeferredProjectRestorePending else {
            restoreLastProjectIfNeeded()
            return
        }

        if isLaunchPreviewLoadInFlight {
            pendingHydrationAfterLaunchPreviewLoad = true
            let generation = launchPreviewLoadGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                guard
                    let self,
                    self.isDeferredProjectRestorePending,
                    self.isLaunchPreviewLoadInFlight,
                    self.launchPreviewLoadGeneration == generation,
                    self.pendingHydrationAfterLaunchPreviewLoad
                else {
                    return
                }

                self.pendingHydrationAfterLaunchPreviewLoad = false
                SoundtimeDiagnostics.shared.record(
                    category: .system,
                    severity: .info,
                    name: "launch-preview-load-timeout",
                    message: "Full project hydration started before a launch preview became available.",
                    fields: [:]
                )
                self.restoreLastProjectIfNeeded()
            }
            return
        }

        let submittedPreviewRender = submitDeferredLaunchPreviewRenderIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isDeferredProjectRestorePending else {
                return
            }

            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .info,
                name: "launch-hydration-start",
                message: "Starting full project hydration after the launch preview was applied.",
                fields: [
                    "reason": submittedPreviewRender ?
                        "preview-render-requested" :
                        "preview-render-not-required",
                ]
            )
            self.restoreLastProjectIfNeeded()
        }
    }

    func prepareForDeferredProjectRestore() {
        guard
            !hasRestoredLastProject,
            let launchTarget = deferredProjectRestoreTarget()
        else {
            return
        }

        isDeferredProjectRestorePending = true
        setProjectReadinessState(.launchPreviewLoading)
        LaunchStartupTrace.shared.mark(.deferredProjectRestorePrepared)

        if hasDrawableDeferredLaunchPreviewApplied {
            setProjectReadinessState(
                .visualReady(trackCount: projectTracks.count),
                statusOverride: ProjectLaunchFirstFrame.Source.firstFrameWaveformPacket.statusOverride
            )
            return
        }

        if let firstFrame = ProjectLaunchCoordinator.loadCachedFirstPaintFrame(
            projectURL: launchTarget.visualCacheURL
        ) ?? ProjectLaunchCoordinator.loadShell(projectURL: launchTarget.visualCacheURL) {
            applyLaunchFirstFrame(firstFrame, stateProjectURL: launchTarget.projectURL)
            recordLaunchFirstFrameLoaded(firstFrame, firstPaint: true)
            return
        }

        loadDeferredLaunchPreviewAsync(
            projectURL: launchTarget.projectURL,
            usesAutosaveRecovery: launchTarget.usesAutosaveRecovery
        )
    }

    func prepareVisualShellForDeferredProjectRestore() {
        guard
            !hasRestoredLastProject,
            let launchTarget = deferredProjectRestoreTarget()
        else {
            return
        }
        guard projectTracks.isEmpty else {
            assertNoDefaultPlaceholderWasInstalledDuringRestore(reason: "deferred-shell-skipped")
            return
        }

        isDeferredProjectRestorePending = true
        setProjectReadinessState(.launchPreviewLoading)

        if let firstFrame = ProjectLaunchCoordinator.loadCachedFirstPaintFrame(
            projectURL: launchTarget.visualCacheURL
        ) {
            applyLaunchFirstFrame(firstFrame, stateProjectURL: launchTarget.projectURL)
            recordLaunchFirstFrameLoaded(firstFrame, firstPaint: false)
            return
        }

        guard let shell = ProjectLaunchCoordinator.loadShell(projectURL: launchTarget.visualCacheURL) else {
            return
        }

        applyLaunchFirstFrame(shell, stateProjectURL: launchTarget.projectURL)
        recordLaunchFirstFrameLoaded(shell, firstPaint: false)
    }

    private func applyInitialLaunchPlanIfAvailable() {
        guard launchPlan.restoresProject else {
            return
        }

        isDeferredProjectRestorePending = true
        if let firstPaintFrame = launchPlan.firstPaintFrame {
            applyLaunchFirstFrame(firstPaintFrame, stateProjectURL: launchPlan.targetProjectURL)
            assertNoDefaultPlaceholderWasInstalledDuringRestore(reason: "initial-first-paint")
            recordLaunchFirstFrameLoaded(firstPaintFrame, firstPaint: false)
            LaunchStartupTrace.shared.mark(
                .workspaceFirstPaintSourceRecorded,
                recordsDiagnosticEvent: false
            )
            LaunchStartupTrace.shared.mark(
                .workspaceFirstPaintInstalled,
                fields: launchPlan.diagnosticFields
            )
        } else {
            setProjectReadinessState(.launchPreviewLoading, statusOverride: "opening project")
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .severe,
                name: "startup-first-paint-frame-missing",
                message: "A restorable project had no cached first-paint frame or shell before window construction.",
                fields: launchPlan.diagnosticFields
            )
            LaunchStartupTrace.shared.mark(
                .launchPreviewUnavailable,
                fields: launchPlan.diagnosticFields
            )
        }
    }

    private func assertNoDefaultPlaceholderWasInstalledDuringRestore(reason: String) {
        guard launchPlan.restoresProject else {
            return
        }
        guard
            projectTracks.count == 1,
            projectTracks.first?.sourceURL.path == "/dev/null",
            projectTracks.first?.waveformOverview == nil,
            projectTracks.first?.sourceWaveformOverview == nil
        else {
            return
        }

        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: .severe,
            name: "startup-placeholder-window-displayed",
            message: "Restore-mode startup installed the default empty-project placeholder track.",
            fields: launchPlan.diagnosticFields.merging([
                "reason": reason,
            ]) { _, new in new }
        )
        assertionFailure("Restore startup must not install the default empty-project placeholder.")
    }

    private var hasDrawableDeferredLaunchPreviewApplied: Bool {
        !projectTracks.isEmpty &&
            projectTracks.contains { track in
                track.waveformOverview != nil || track.sourceWaveformOverview != nil
            }
    }

    private struct DeferredProjectRestoreTarget {
        var projectURL: URL
        var visualCacheURL: URL
        var usesAutosaveRecovery: Bool
    }

    private func deferredProjectRestoreTarget() -> DeferredProjectRestoreTarget? {
        if
            launchPlan.restoresProject,
            let targetProjectURL = launchPlan.targetProjectURL
        {
            return DeferredProjectRestoreTarget(
                projectURL: targetProjectURL.standardizedFileURL,
                visualCacheURL: (launchPlan.visualCacheURL ?? targetProjectURL).standardizedFileURL,
                usesAutosaveRecovery: launchPlan.usesAutosaveRecovery
            )
        }

        if let url = restorableLaunchProjectURL() {
            return DeferredProjectRestoreTarget(
                projectURL: url.standardizedFileURL,
                visualCacheURL: (
                    SoundtimeProjectStore.recoverableAutosaveURL(for: url) ?? url
                ).standardizedFileURL,
                usesAutosaveRecovery: true
            )
        }

        guard let recoveryURL = SoundtimeProjectStore.recoverableAutosaveURLs().first else {
            return nil
        }
        return DeferredProjectRestoreTarget(
            projectURL: recoveryURL.standardizedFileURL,
            visualCacheURL: recoveryURL.standardizedFileURL,
            usesAutosaveRecovery: false
        )
    }

    private func applyLaunchFirstFrame(
        _ firstFrame: ProjectLaunchFirstFrame,
        stateProjectURL: URL? = nil
    ) {
        let applyStartedAt = CACurrentMediaTime()
        let stateProjectURL = (stateProjectURL ?? firstFrame.projectURL).standardizedFileURL
        withoutAutosave {
            clearProjectForLoad(publishesTimeline: false)
            LaunchStartupTrace.shared.mark(
                .workspaceFirstPaintProjectCleared,
                recordsDiagnosticEvent: false
            )
            currentProjectURL = stateProjectURL
            applyLaunchFirstFrameIdentity(firstFrame)
            applyProjectMasterVolume(firstFrame.masterVolume)
            applyProjectTimelineViewport(
                SoundtimeProjectStore.rememberedTimelineViewport(for: stateProjectURL) ??
                    firstFrame.timelineViewport
            )
            applyProjectTranscriptDisplayMode(firstFrame.transcriptDisplayMode)
            resetWaveformFisheyeTuningToDefaults()
            LaunchStartupTrace.shared.mark(
                .workspaceFirstPaintViewStateApplied,
                recordsDiagnosticEvent: false
            )
        }
        applyWindowLayout(
            SoundtimeProjectStore.rememberedWindowLayout(for: stateProjectURL) ??
                firstFrame.windowLayout
        )

        projectTracks = firstFrame.tracks.map { track in
            launchPreviewTrack(from: track)
        }
        normalizeLoadedProjectEditGroups(reason: firstFrame.source.recordSourceName)
        LaunchStartupTrace.shared.mark(
            .workspaceFirstPaintTracksPrepared,
            recordsDiagnosticEvent: false
        )
        activeTrackID = projectTracks.first?.id
        selectedTrackID = nil
        selectedTrackIDs.removeAll()
        selectedTimelineRange = nil
        selectedTranscriptSelection = nil
        activeTranscriptWordID = nil
        loadedAudioSummary = nil
        currentPlaybackStatus = "opening last project"

        if firstFrame.isShellOnly {
            setProjectReadinessState(.launchPreviewLoading, statusOverride: firstFrame.source.statusOverride)
            isLaunchVisualPreviewPendingImmediateRender = false
        } else {
            setProjectReadinessState(
                .visualReady(trackCount: projectTracks.count),
                statusOverride: firstFrame.source.statusOverride
            )
            isLaunchVisualPreviewPendingImmediateRender = firstFrame.summary.hasAnyDrawableWaveform
        }
        LaunchStartupTrace.shared.mark(
            .workspaceFirstPaintStatePrepared,
            recordsDiagnosticEvent: false
        )

        window?.title = projectWindowTitle()
        timelineSurface.prepareLaunchPreviewFirstPaint(
            selectedTrackIDs: selectedTrackIDs,
            primaryTrackID: selectedTrackID
        )
        refreshProjectTimelineDisplay(
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: !firstFrame.isShellOnly,
            allowImmediateInteractiveWaveformPrewarm: false,
            updatesRendererImmediately: true
        )
        updateProjectDisplayTiming()
        LaunchStartupTrace.shared.mark(
            .workspaceFirstPaintDisplayTimingUpdated,
            recordsDiagnosticEvent: false
        )
        syncActiveTrackFields()
        LaunchStartupTrace.shared.mark(
            .workspaceFirstPaintActiveTrackSynchronized,
            recordsDiagnosticEvent: false
        )
        updateEffectCommandState()
        LaunchStartupTrace.shared.mark(
            .workspaceFirstPaintContentSynchronized,
            recordsDiagnosticEvent: false
        )

        if !firstFrame.isShellOnly {
            recordLaunchVisualSkeletonApplied(
                source: firstFrame.source.recordSourceName,
                projectURL: stateProjectURL,
                summary: firstFrame.summary,
                applyMilliseconds: (CACurrentMediaTime() - applyStartedAt) * 1_000
            )
        }
        LaunchStartupTrace.shared.mark(
            .workspaceFirstPaintVisualReadinessRecorded,
            recordsDiagnosticEvent: false
        )
    }

    private func recordLaunchFirstFrameLoaded(
        _ firstFrame: ProjectLaunchFirstFrame,
        firstPaint: Bool
    ) {
        var fields = firstFrame.summary.diagnosticFields
        fields["file"] = firstFrame.projectURL.lastPathComponent
        fields["source"] = firstFrame.source.rawValue
        fields["loadMs"] = String(format: "%.2f", firstFrame.loadMilliseconds)
        fields["firstPaint"] = "\(firstPaint)"

        switch firstFrame.source {
        case .firstFrameWaveformPacket:
            LaunchStartupTrace.shared.mark(
                .firstFrameWaveformPacketLoaded,
                fields: fields
            )
            LaunchStartupTrace.shared.mark(
                .firstFrameWaveformPacketInstalled,
                fields: fields
            )
        case .launchSnapshot:
            LaunchStartupTrace.shared.mark(.launchSnapshotLoaded, fields: fields)
        case .savedProjectPreview, .recoveredAutosavePreview:
            LaunchStartupTrace.shared.mark(.launchProjectPreviewLoaded, fields: fields)
        case .deferredLaunchSnapshot:
            LaunchStartupTrace.shared.mark(.launchSnapshotLoaded, fields: fields)
        case .deferredProjectPreview:
            LaunchStartupTrace.shared.mark(.launchProjectPreviewLoaded, fields: fields)
        case .firstFrameWaveformShell, .launchSnapshotShell, .launchManifestShell:
            break
        }

        let severity: SoundtimeDiagnosticSeverity
        if firstFrame.isShellOnly {
            severity = firstFrame.loadMilliseconds > 8 ? .warning : .info
        } else if firstFrame.source == .deferredProjectPreview {
            severity = firstFrame.loadMilliseconds > 50 ? .warning : .info
        } else {
            severity = firstFrame.loadMilliseconds > 35 ? .warning : .info
        }

        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: severity,
            name: firstFrame.source.diagnosticName,
            message: launchFirstFrameDiagnosticMessage(firstFrame),
            fields: fields
        )
    }

    private func launchFirstFrameDiagnosticMessage(_ firstFrame: ProjectLaunchFirstFrame) -> String {
        switch firstFrame.source {
        case .firstFrameWaveformShell:
            "First-frame waveform manifest was applied before the launch window became visible."
        case .launchSnapshotShell:
            "Launch snapshot manifest was applied before the launch window became visible."
        case .launchManifestShell:
            "Tiny launch manifest was applied before the launch window became visible."
        case .firstFrameWaveformPacket:
            "First-frame waveform packet was applied before project hydration."
        case .launchSnapshot:
            "Compact binary launch snapshot was applied before the first window paint."
        case .savedProjectPreview:
            firstFrame.summary.hasAnyDrawableWaveform ?
                "Saved project preview was applied before the first window paint." :
                "Saved project preview was applied before first paint, but no cached waveform was available yet."
        case .recoveredAutosavePreview:
            firstFrame.summary.hasAnyDrawableWaveform ?
                "Recovered autosave preview was applied before the first window paint." :
                "Recovered autosave preview was applied before first paint, but no cached waveform was available yet."
        case .deferredLaunchSnapshot:
            "Launch snapshot was loaded off the first window-paint path."
        case .deferredProjectPreview:
            "Project preview was loaded off the first window-paint path."
        }
    }

    private func loadDeferredLaunchPreviewAsync(projectURL: URL, usesAutosaveRecovery: Bool) {
        launchPreviewLoadGeneration += 1
        let generation = launchPreviewLoadGeneration
        isLaunchPreviewLoadInFlight = true
        pendingHydrationAfterLaunchPreviewLoad = false
        let standardizedProjectURL = projectURL.standardizedFileURL
        let launchPreviewCache = waveformOverviewDiskCache
        LaunchStartupTrace.shared.mark(
            .launchPreviewLoadStarted,
            fields: ["file": standardizedProjectURL.lastPathComponent]
        )

        projectCriticalLoadQueue.async {
            let result = ProjectLaunchCoordinator.loadDeferredFirstFrame(
                projectURL: standardizedProjectURL,
                usesAutosaveRecovery: usesAutosaveRecovery,
                waveformOverviewDiskCache: launchPreviewCache
            )

            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    self.launchPreviewLoadGeneration == generation,
                    !self.hasRestoredLastProject
                else {
                    return
                }

                self.isLaunchPreviewLoadInFlight = false
                var didApplyLaunchPreview = false
                switch result {
                case let .firstFrame(firstFrame):
                    LaunchStartupTrace.shared.mark(
                        firstFrame.source == .deferredLaunchSnapshot ?
                            .launchSnapshotLoaded :
                            .launchProjectPreviewLoaded,
                        fields: [
                            "file": firstFrame.projectURL.lastPathComponent,
                            "loadMs": String(format: "%.2f", firstFrame.loadMilliseconds),
                        ]
                    )
                    self.applyLaunchFirstFrame(firstFrame, stateProjectURL: standardizedProjectURL)
                    didApplyLaunchPreview = true
                    self.recordLaunchFirstFrameLoaded(firstFrame, firstPaint: false)
                case let .unavailable(url, message, loadMilliseconds):
                    LaunchStartupTrace.shared.mark(
                        .launchPreviewUnavailable,
                        fields: [
                            "file": url.lastPathComponent,
                            "error": message,
                            "loadMs": String(format: "%.2f", loadMilliseconds),
                        ]
                    )
                    SoundtimeDiagnostics.shared.record(
                        category: .system,
                        severity: .info,
                        name: "launch-snapshot-miss",
                        message: "No usable launch snapshot or launch preview was available before project restore.",
                        fields: [
                            "file": url.lastPathComponent,
                            "error": message,
                            "loadMs": String(format: "%.2f", loadMilliseconds),
                        ]
                    )
                }

                if didApplyLaunchPreview {
                    self.submitDeferredLaunchPreviewRenderIfNeeded()
                }

                if self.pendingHydrationAfterLaunchPreviewLoad {
                    self.pendingHydrationAfterLaunchPreviewLoad = false
                    self.restoreLastProjectAfterLaunchPreviewRender()
                }
            }
        }
    }

    private func recordLaunchVisualSkeletonApplied(
        source: String,
        projectURL: URL,
        summary: ProjectLaunchVisualReadinessSummary,
        applyMilliseconds: Double
    ) {
        var fields = summary.diagnosticFields
        fields["file"] = projectURL.lastPathComponent
        fields["source"] = source
        fields["applyMs"] = String(format: "%.2f", applyMilliseconds)

        LaunchStartupTrace.shared.mark(.visualSkeletonApplied, fields: fields)
        if summary.hasAnyDrawableWaveform {
            LaunchStartupTrace.shared.mark(.visualPreviewReady, fields: fields)
        }

        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: summary.isFirstFrameUsable ? .info : .warning,
            name: "launch-visual-skeleton-applied",
            message: summary.isFirstFrameUsable ?
                "Launch visual skeleton has enough data for the first frame." :
                "Launch visual skeleton has blank tracks that need hydration before they can draw.",
            fields: fields
        )

        timelineSurface.notifyAfterNextSubmittedTimelineRender { submittedAt in
            LaunchStartupTrace.shared.markOnce(
                .firstTimelineRenderSubmitted,
                fields: ["submittedAt": String(format: "%.3f", submittedAt)]
            )
            LaunchStartupTrace.shared.markOnce(.firstWaveformVisibleFrame, fields: fields)
        }
    }

    private struct ProjectLaunchTrackSkeleton {
        var id: UUID
        var editGroupID: UUID?
        var name: String
        var sourceURL: URL
        var durationHint: TimeInterval?
        var sourceWaveformOverview: WaveformOverview?
        var displayWaveformOverview: WaveformOverview?
        var fileTimeline: AudioFileEditTimeline?
        var volume: Float
        var isMuted: Bool
        var isSoloed: Bool
        var transcript: TranscriptDocument?
        var importedAssetID: UUID?
        var importFingerprint: AudioImportFingerprint?

        init(track: SoundtimeProject.Track, sourceURL: URL) {
            let previewSourceOverview = track.waveformPreview?.sourceOverview.waveformOverview
            let previewDisplayOverview = track.waveformPreview?.displayOverview.waveformOverview
            let fileTimeline = track.editTimeline.flatMap(AudioFileEditTimeline.init)
            let editableDuration = Self.editableDuration(from: track.editableSource)
            id = track.id
            editGroupID = track.editGroupID
            name = track.name
            self.sourceURL = sourceURL.standardizedFileURL
            durationHint = fileTimeline?.duration ??
                previewDisplayOverview?.duration ??
                previewSourceOverview?.duration ??
                editableDuration
            sourceWaveformOverview = previewSourceOverview
            displayWaveformOverview = previewDisplayOverview ?? previewSourceOverview
            self.fileTimeline = fileTimeline
            volume = track.volume
            isMuted = track.isMuted
            isSoloed = track.isSoloed
            transcript = track.transcript
            importedAssetID = track.importedAssetState?.assetID ?? track.editableSource?.importedAssetID
            importFingerprint = track.importedAssetState?.fingerprint
        }

        init(track: ProjectLaunchFirstFrame.Track) {
            let previewSourceOverview = track.sourceWaveformOverview
            let previewDisplayOverview = track.displayWaveformOverview
            let fileTimeline = track.editTimeline.flatMap(AudioFileEditTimeline.init)
            let editableDuration = Self.editableDuration(from: track.editableSource)
            id = track.id
            editGroupID = track.editGroupID
            name = track.name
            sourceURL = track.sourceURL.standardizedFileURL
            durationHint = fileTimeline?.duration ??
                previewDisplayOverview?.duration ??
                previewSourceOverview?.duration ??
                track.durationHint ??
                editableDuration
            sourceWaveformOverview = previewSourceOverview
            displayWaveformOverview = previewDisplayOverview ?? previewSourceOverview
            self.fileTimeline = fileTimeline
            volume = track.volume
            isMuted = track.isMuted
            isSoloed = track.isSoloed
            transcript = track.transcript
            importedAssetID = track.editableSource?.importedAssetID
            importFingerprint = nil
        }

        func projectTrack(defaultEditGroupID: UUID) -> ProjectTrack {
            ProjectTrack(
                id: id,
                editGroupID: editGroupID ?? defaultEditGroupID,
                name: name,
                sourceURL: sourceURL,
                durationHint: durationHint,
                sourceWaveformOverview: sourceWaveformOverview,
                waveformOverview: displayWaveformOverview ?? sourceWaveformOverview,
                decodedAudioBuffer: nil,
                zeroCrossingIndex: nil,
                zeroCrossingProbe: nil,
                audioTimeline: nil,
                fileTimeline: fileTimeline,
                editableSource: nil,
                ownsSourceFile: false,
                volume: volume,
                isMuted: isMuted,
                isSoloed: isSoloed,
                importID: UUID(),
                editRevision: fileTimeline?.hasEdits == true ? 1 : 0,
                transcript: transcript,
                importedAssetID: importedAssetID,
                importFingerprint: importFingerprint
            )
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

    private func launchPreviewTrack(
        from track: SoundtimeProject.Track,
        projectURL _: URL
    ) -> ProjectTrack {
        ProjectLaunchTrackSkeleton(
            track: track,
            sourceURL: storedProjectTrackSourceURL(for: track)
        )
        .projectTrack(defaultEditGroupID: defaultEditGroupID)
    }

    private func launchPreviewTrack(
        from track: ProjectLaunchFirstFrame.Track
    ) -> ProjectTrack {
        ProjectLaunchTrackSkeleton(track: track)
            .projectTrack(defaultEditGroupID: defaultEditGroupID)
    }

    @discardableResult
    func submitDeferredLaunchPreviewRenderIfNeeded() -> Bool {
        guard isLaunchVisualPreviewPendingImmediateRender else {
            return false
        }

        let didSubmit = timelineSurface.submitImmediateTimelineRenderForFirstPaint()
        guard didSubmit else {
            return false
        }

        isLaunchVisualPreviewPendingImmediateRender = false
        SoundtimeDiagnostics.shared.record(
            category: .render,
            severity: .info,
            name: "launch-first-paint-render-submitted",
            message: "Submitted cached launch waveform preview immediately after the window became drawable.",
            fields: [
                "tracks": "\(projectTracks.count)",
            ]
        )
        return true
    }

    private func finishDeferredProjectRestore() {
        guard isDeferredProjectRestorePending else {
            return
        }

        isDeferredProjectRestorePending = false
        isLaunchPreviewLoadInFlight = false
        pendingHydrationAfterLaunchPreviewLoad = false
        isLaunchVisualPreviewPendingImmediateRender = false
        if !isDenoiseModalInteractionLocked, activeDenoiseRequestID == nil, pendingDenoiseReview == nil {
            timelineSurface.setInteractionSuppressed(false)
        }
    }

    private func restorableLaunchProjectURL() -> URL? {
        guard let lastProjectURL = SoundtimeProjectStore.lastProjectURL() else {
            return nil
        }

        guard FileManager.default.fileExists(atPath: lastProjectURL.path) else {
            return nil
        }

        return lastProjectURL
    }

    private func setProjectReadinessState(
        _ state: ProjectReadinessState,
        statusOverride: String? = nil
    ) {
        guard projectReadinessState != state else {
            if let statusOverride {
                updateStatus(statusOverride)
            }
            return
        }

        let previousState = projectReadinessState
        projectReadinessState = state
        updateStatus(statusOverride ?? state.statusText)
        guard shouldRecordProjectReadinessDiagnosticTransition(from: previousState, to: state) else {
            return
        }
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: .info,
            name: "project-readiness-state",
            message: "Project readiness state changed.",
            fields: projectReadinessDiagnosticFields(for: state)
        )
    }

    private func shouldRecordProjectReadinessDiagnosticTransition(
        from _: ProjectReadinessState,
        to state: ProjectReadinessState
    ) -> Bool {
        switch state {
        case let .playbackHydrating(completed, failed, total):
            let finishedCount = completed + failed
            if finishedCount == 0 || finishedCount >= total {
                lastProjectReadinessHydrationDiagnosticTime = CACurrentMediaTime()
                return true
            }

            let progressStride = max(10, total / 10)
            let now = CACurrentMediaTime()
            if finishedCount.isMultiple(of: progressStride) ||
                now - lastProjectReadinessHydrationDiagnosticTime >= 0.5
            {
                lastProjectReadinessHydrationDiagnosticTime = now
                return true
            }
            return false
        default:
            lastProjectReadinessHydrationDiagnosticTime = -Double.infinity
            return true
        }
    }

    private func projectReadinessDiagnosticFields(for state: ProjectReadinessState) -> [String: String] {
        var fields: [String: String] = [
            "state": "\(state)",
            "visualReady": "false",
            "timelineInteractive": "false",
            "playbackReady": "false",
        ]

        switch state {
        case .empty:
            break
        case .launchPreviewLoading:
            fields["visualReady"] = "\(projectTracks.contains { $0.waveformOverview != nil || $0.sourceWaveformOverview != nil })"
        case let .visualReady(trackCount):
            fields["visualReady"] = "true"
            fields["timelineInteractive"] = "true"
            fields["tracks"] = "\(trackCount)"
        case let .playbackHydrating(completed, failed, total):
            fields["visualReady"] = "true"
            fields["timelineInteractive"] = "true"
            fields["playbackReady"] = "partial"
            fields["hydrated"] = "\(completed)"
            fields["failed"] = "\(failed)"
            fields["tracks"] = "\(total)"
        case let .playbackReady(trackCount):
            fields["visualReady"] = "true"
            fields["timelineInteractive"] = "true"
            fields["playbackReady"] = "true"
            fields["tracks"] = "\(trackCount)"
        case let .playbackReadyWithFailures(completed, failed):
            fields["visualReady"] = "true"
            fields["timelineInteractive"] = "true"
            fields["playbackReady"] = "partial"
            fields["hydrated"] = "\(completed)"
            fields["failed"] = "\(failed)"
        case let .failed(message):
            fields["error"] = message
        }

        return fields
    }

    private func refreshProjectTimelineDisplay(
        rebuildControls: Bool = true,
        animateWaveformTransition: Bool = true,
        allowImmediateWaveformPrewarm: Bool = true,
        allowImmediateInteractiveWaveformPrewarm: Bool = true,
        updatesRendererImmediately: Bool = false
    ) {
        if !isDenoiseModalInteractionLocked, activeDenoiseRequestID == nil, pendingDenoiseReview == nil {
            timelineSurface.setInteractionSuppressed(false)
        }
        reconcileProjectTranscriptsIfNeeded()
        let renderTracks = timelineRenderTracks()
        publishedTimelineRenderTracks = renderTracks
        publishedTimelineEditRevision = currentEditGraphRevision
        timelinePresentationDirtyTrackIDs.removeAll()
        timelineSurface.displayTracks(
            renderTracks,
            animateWaveformTransition: animateWaveformTransition,
            allowImmediateWaveformPrewarm: allowImmediateWaveformPrewarm,
            allowImmediateInteractiveWaveformPrewarm: allowImmediateInteractiveWaveformPrewarm,
            updatesRendererImmediately: updatesRendererImmediately
        )
        if updatesRendererImmediately {
            LaunchStartupTrace.shared.mark(
                .workspaceFirstPaintTimelinePublished,
                recordsDiagnosticEvent: false
            )
        }
        publishSelectedTracksToTimeline()
        if rebuildControls {
            refreshTrackControls()
        }
        if updatesRendererImmediately {
            LaunchStartupTrace.shared.mark(
                .workspaceFirstPaintControlsPublished,
                recordsDiagnosticEvent: false
            )
        }
    }

    private var shouldAnimateWaveformDataPromotion: Bool {
        !playbackController.isPlaying && !visualPlaybackActive
    }

    private func refreshProjectTrackMixDisplay() {
        if !isDenoiseModalInteractionLocked, activeDenoiseRequestID == nil, pendingDenoiseReview == nil {
            timelineSurface.setInteractionSuppressed(false)
        }
        let mixes = projectPlaybackTrackMixes()
        publishedTimelineRenderTracks = applyingProjectTrackMixes(
            mixes,
            to: publishedTimelineRenderTracks
        )
        publishedProjectPlaybackTracks = ProjectPlaybackProjection.applyingMixes(
            mixes,
            to: publishedProjectPlaybackTracks
        )
        timelineSurface.displayTrackMixSettings(timelineMixRenderTracks())
    }

    private func applyingProjectTrackMixes(
        _ mixes: [ProjectPlaybackTrackMix],
        to renderTracks: [TimelineRenderState.Track]
    ) -> [TimelineRenderState.Track] {
        let mixesByID = Dictionary(uniqueKeysWithValues: mixes.map { ($0.id, $0) })
        return renderTracks.map { track in
            guard let mix = mixesByID[track.id] else {
                return track
            }
            return track.applying(mix)
        }
    }

    private func timelineRenderTracks() -> [TimelineRenderState.Track] {
        projectTracks.map { timelineRenderTrack(for: $0) }
    }

    private func timelineRenderTrack(
        for track: ProjectTrack
    ) -> TimelineRenderState.Track {
        let renderPayload = waveformRenderPayload(for: track)
        return TimelineRenderState.Track(
            id: track.id,
            waveformVersion: waveformVersion(for: track, renderPayload: renderPayload),
            waveformOverview: renderPayload.overview,
            durationHint: track.audioTimeline?.duration ??
                track.fileTimeline?.duration ??
                renderPayload.overview?.duration ??
                track.decodedAudioBuffer?.duration ??
                track.durationHint,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            clipRanges: timelineClipRanges(for: track),
            waveformSegments: renderPayload.usesSourceSegments ? waveformSegmentsForRendering(track) : [],
            waveformTileSource: waveformTileSource(for: track),
            transcript: track.transcript
        )
    }

    private func timelineRenderTrack(
        for track: ProjectTrack,
        reusing previousTrack: TimelineRenderState.Track
    ) -> TimelineRenderState.Track {
        guard previousTrack.id == track.id else {
            return timelineRenderTrack(for: track)
        }

        let renderPayload = waveformRenderPayload(for: track)
        let canReuseWaveformSource =
            renderPayload.usesSourceSegments &&
            previousTrack.waveformOverview?.bins.count == renderPayload.overview?.bins.count &&
            previousTrack.waveformOverview?.duration == renderPayload.overview?.duration

        return TimelineRenderState.Track(
            id: track.id,
            waveformVersion: canReuseWaveformSource ?
                previousTrack.waveformVersion :
                waveformVersion(for: track, renderPayload: renderPayload),
            waveformOverview: canReuseWaveformSource ?
                previousTrack.waveformOverview :
                renderPayload.overview,
            durationHint: track.audioTimeline?.duration ??
                track.fileTimeline?.duration ??
                renderPayload.overview?.duration ??
                track.decodedAudioBuffer?.duration ??
                track.durationHint,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            hasWaveform: canReuseWaveformSource ?
                previousTrack.hasWaveform :
                nil,
            clipRanges: timelineClipRanges(for: track),
            waveformSegments: renderPayload.usesSourceSegments ?
                waveformSegmentsForRendering(track) :
                [],
            waveformTileSource: canReuseWaveformSource ?
                previousTrack.waveformTileSource :
                waveformTileSource(for: track),
            transcript: track.transcript
        )
    }

    private func timelineMixRenderTracks() -> [TimelineRenderState.Track] {
        projectTracks.map { track in
            let durationHint = track.audioTimeline?.duration ??
                track.fileTimeline?.duration ??
                track.waveformOverview?.duration ??
                track.decodedAudioBuffer?.duration ??
                track.durationHint
            return TimelineRenderState.Track(
                id: track.id,
                waveformVersion: track.editRevision,
                waveformOverview: nil,
                durationHint: durationHint,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed,
                hasWaveform: track.waveformOverview?.isEmpty == false,
                clipRanges: timelineClipRanges(for: track),
                waveformSegments: waveformSegmentsForRendering(track),
                waveformTileSource: waveformTileSource(for: track),
                transcript: track.transcript
            )
        }
    }

    private struct WaveformRenderPayload {
        let overview: WaveformOverview?
        let usesSourceSegments: Bool
    }

    private func waveformRenderPayload(for track: ProjectTrack) -> WaveformRenderPayload {
        if let fileTimeline = track.fileTimeline {
            return waveformRenderPayload(
                sourceOverview: track.sourceWaveformOverview,
                displayOverview: track.waveformOverview,
                fileTimeline: fileTimeline
            )
        }

        if let audioTimeline = track.audioTimeline {
            let sourceDuration = audioTimeline.sourceAudioBuffer.duration
            let durationTolerance = max(0.01, sourceDuration * 0.000_01)
            let sourceOverview = track.sourceWaveformOverview ?? track.waveformOverview
            if
                let sourceOverview,
                abs(sourceOverview.duration - sourceDuration) <= durationTolerance
            {
                return WaveformRenderPayload(
                    overview: sourceOverview,
                    usesSourceSegments: true
                )
            }
        }

        return WaveformRenderPayload(overview: track.waveformOverview, usesSourceSegments: false)
    }

    private func waveformRenderPayload(
        sourceOverview: WaveformOverview?,
        displayOverview: WaveformOverview?,
        fileTimeline: AudioFileEditTimeline
    ) -> WaveformRenderPayload {
        let sourceDuration = Double(fileTimeline.sourceFrameCount) / max(fileTimeline.sourceSampleRate, 1)
        let durationTolerance = max(0.01, sourceDuration * 0.000_01)

        func matchesSourceDuration(_ overview: WaveformOverview?) -> Bool {
            guard let overview, overview.duration.isFinite else {
                return false
            }

            return abs(overview.duration - sourceDuration) <= durationTolerance
        }

        let sourceMatchesSource = matchesSourceDuration(sourceOverview)
        let displayMatchesSource = matchesSourceDuration(displayOverview)

        if sourceMatchesSource || displayMatchesSource {
            if
                displayMatchesSource,
                (!sourceMatchesSource || (displayOverview?.bins.count ?? 0) > (sourceOverview?.bins.count ?? 0))
            {
                return WaveformRenderPayload(overview: displayOverview, usesSourceSegments: true)
            }

            return WaveformRenderPayload(overview: sourceOverview, usesSourceSegments: true)
        }

        // Edited file timelines can also carry a display-domain optimistic preview.
        // That preview already represents output time, so source-remap segments
        // must be disabled or the shader will stretch/repeat it until the true
        // source-domain overview arrives.
        if let displayOverview {
            return WaveformRenderPayload(overview: displayOverview, usesSourceSegments: false)
        }

        return WaveformRenderPayload(overview: sourceOverview, usesSourceSegments: false)
    }

    private func bestSourceWaveformOverview(
        sourceOverview: WaveformOverview?,
        fallbackOverview: WaveformOverview?,
        fileTimeline: AudioFileEditTimeline
    ) -> WaveformOverview? {
        let sourceDuration = Double(fileTimeline.sourceFrameCount) / max(fileTimeline.sourceSampleRate, 1)
        let durationTolerance = max(0.01, sourceDuration * 0.000_01)

        func matchesSourceDuration(_ overview: WaveformOverview?) -> Bool {
            guard let overview, overview.duration.isFinite else {
                return false
            }

            return abs(overview.duration - sourceDuration) <= durationTolerance
        }

        let fallbackMatchesSource = matchesSourceDuration(fallbackOverview)
        let sourceMatchesSource = matchesSourceDuration(sourceOverview)

        if
            let fallbackOverview,
            fallbackMatchesSource,
            (!sourceMatchesSource || fallbackOverview.bins.count > (sourceOverview?.bins.count ?? 0))
        {
            return fallbackOverview
        }

        if sourceMatchesSource {
            return sourceOverview
        }

        return nil
    }

    private func waveformSegmentsForRendering(_ track: ProjectTrack) -> [TimelineRenderState.Track.WaveformSegment] {
        if let fileTimeline = track.fileTimeline {
            return waveformSegmentsForRendering(
                playbackSegments: fileTimeline.playbackSegments,
                frameCount: fileTimeline.frameCount,
                sourceFrameCount: fileTimeline.sourceFrameCount
            )
        }

        if let audioTimeline = track.audioTimeline {
            return waveformSegmentsForRendering(
                playbackSegments: audioTimeline.playbackSegments,
                frameCount: audioTimeline.frameCount,
                sourceFrameCount: audioTimeline.sourceAudioBuffer.frameCount
            )
        }

        return []
    }

    private func waveformSegmentsForRendering(
        playbackSegments: [AudioEditTimeline.PlaybackSegment],
        frameCount: Int,
        sourceFrameCount: Int
    ) -> [TimelineRenderState.Track.WaveformSegment] {
        let safeFrameCount = max(frameCount, 1)
        let safeSourceFrameCount = max(sourceFrameCount, 1)
        return playbackSegments.compactMap { segment in
            guard segment.frameCount > 0 else {
                return nil
            }

            return TimelineRenderState.Track.WaveformSegment(
                outputStartProgress: Float(segment.outputStartFrame) / Float(safeFrameCount),
                outputEndProgress: Float(segment.outputStartFrame + segment.frameCount) / Float(safeFrameCount),
                sourceStartProgress: Float(segment.sourceStartFrame) / Float(safeSourceFrameCount),
                sourceEndProgress: Float(segment.sourceStartFrame + segment.frameCount) / Float(safeSourceFrameCount),
                gainStart: segment.gainStart,
                gainEnd: segment.gainEnd
            )
        }
    }

    private func waveformTileSource(for track: ProjectTrack) -> WaveformTileBuildSource? {
        guard WaveformTiledRendererFeatureFlags.isEnabled,
              track.audioTimeline == nil
        else {
            return nil
        }

        let normalizedURL = track.sourceURL.standardizedFileURL
        if let cachedSource = waveformTileSourceCache[normalizedURL] {
            return cachedSource
        }
        guard decodableWAVFileInfo(for: normalizedURL) != nil,
              let source = try? WaveformTileBuildSource(
                  wavURL: normalizedURL,
                  channelMode: .monoMix
              )
        else {
            return nil
        }
        waveformTileSourceCache[normalizedURL] = source
        return source
    }

    private func timelineClipRanges(for track: ProjectTrack) -> [TimelineRenderState.ClipRange] {
        let ranges: [TimelineRenderState.ClipRange]
        if let fileTimeline = track.fileTimeline {
            ranges = fileTimeline.clipRanges.map {
                TimelineRenderState.ClipRange(
                    startProgress: $0.startProgress,
                    endProgress: $0.endProgress
                )
            }
        } else if let audioTimeline = track.audioTimeline {
            ranges = audioTimeline.clipRanges.map {
                TimelineRenderState.ClipRange(
                    startProgress: $0.startProgress,
                    endProgress: $0.endProgress
                )
            }
        } else {
            ranges = []
        }

        if !ranges.isEmpty {
            return ranges
        }

        return trackDuration(for: track) > 0 ? [
            TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)
        ] : []
    }

    private func waveformVersion(
        for track: ProjectTrack,
        renderPayload: WaveformRenderPayload? = nil
    ) -> Int {
        var hasher = Hasher()
        let renderPayload = renderPayload ?? waveformRenderPayload(for: track)
        if !renderPayload.usesSourceSegments {
            hasher.combine(track.editRevision)
        }
        guard let waveformOverview = renderPayload.overview else {
            return hasher.finalize()
        }

        hasher.combine(waveformOverview.bins.count)
        hasher.combine(waveformOverview.duration)
        for index in waveformFingerprintIndices(for: waveformOverview.bins.count) {
            let bin = waveformOverview.bins[index]
            hasher.combine(bin.minimumSample)
            hasher.combine(bin.maximumSample)
            hasher.combine(bin.rmsSample)
            hasher.combine(bin.lowEnergy)
            hasher.combine(bin.midEnergy)
            hasher.combine(bin.highEnergy)
        }

        return hasher.finalize()
    }

    private func waveformFingerprintIndices(for binCount: Int) -> [Int] {
        guard binCount > 0 else {
            return []
        }

        return [
            0,
            binCount / 3,
            binCount / 2,
            min((binCount * 2) / 3, binCount - 1),
            binCount - 1,
        ]
    }

    private func refreshTrackControls() {
        rebuildTrackIndexCache()
        let visibleTracks = currentTrackLaneLayout.visibleTrackIndices(overscan: 1).compactMap { index in
            projectTracks.indices.contains(index) ? projectTracks[index] : nil
        }
        let visibleTrackIDs = Set(visibleTracks.map(\.id))
        for (trackID, controlView) in trackControlViewsByID where !visibleTrackIDs.contains(trackID) {
            controlView.removeFromSuperview()
            controlView.onTrackSelected = nil
            controlView.onMuteChanged = nil
            controlView.onSoloChanged = nil
            controlView.onRecordRequested = nil
            controlView.onVolumeChanged = nil
            controlView.onVolumeEditingEnded = nil
            controlView.onCancelImport = nil
            controlView.onReorderBegan = nil
            controlView.onReorderChanged = nil
            controlView.onReorderEnded = nil
            trackControlReusePool.append(controlView)
            trackControlViewsByID[trackID] = nil
        }

        for track in visibleTracks {
            let controlView: TrackControlView
            if let cachedControlView = trackControlViewsByID[track.id] {
                controlView = cachedControlView
            } else if let reusedControlView = trackControlReusePool.popLast() {
                controlView = reusedControlView
                trackControlViewsByID[track.id] = controlView
            } else {
                controlView = TrackControlView(title: track.name)
                trackControlViewsByID[track.id] = controlView
            }
            if controlView.superview !== trackControlsStack {
                trackControlsStack.addSubview(controlView)
            }

            controlView.configure(
                title: track.name,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed,
                volume: track.volume,
                isTrackSelected: selectedTrackIDs.contains(track.id),
                isRecording: track.id == recordingTrackID,
                importProgress: activeImportProgress(for: track)
            )
            controlView.onTrackSelected = { [weak self, trackID = track.id] modifierFlags in
                self?.selectTrack(trackID, modifierFlags: modifierFlags)
            }
            controlView.onMuteChanged = { [weak self, trackID = track.id] isMuted in
                self?.updateTrack(trackID) { $0.isMuted = isMuted }
            }
            controlView.onSoloChanged = { [weak self, trackID = track.id] isSoloed in
                self?.updateTrack(trackID) { $0.isSoloed = isSoloed }
            }
            controlView.onRecordRequested = { [weak self, trackID = track.id] in
                self?.toggleRecording(on: trackID)
            }
            controlView.onVolumeChanged = { [weak self, trackID = track.id] volume in
                self?.updateTrack(trackID, mixPublication: .coalesced) { $0.volume = volume }
            }
            controlView.onVolumeEditingEnded = { [weak self] in
                self?.publishProjectTrackMixImmediately()
            }
            controlView.onCancelImport = { [weak self, trackID = track.id] in
                self?.cancelAudioImport(for: trackID)
            }
            controlView.onReorderBegan = { [weak self, weak controlView, trackID = track.id] windowPoint in
                self?.beginTrackReorder(trackID: trackID, controlView: controlView, windowPoint: windowPoint)
            }
            controlView.onReorderChanged = { [weak self] windowPoint in
                self?.updateTrackReorder(windowPoint: windowPoint)
            }
            controlView.onReorderEnded = { [weak self, weak controlView] windowPoint, cancelled in
                self?.endTrackReorder(controlView: controlView, windowPoint: windowPoint, cancelled: cancelled)
            }
        }

        layoutTrackControlViews()
    }

    private func refreshExistingTrackControlStates() {
        let tracksByID = Dictionary(uniqueKeysWithValues: projectTracks.map { ($0.id, $0) })
        for (trackID, controlView) in trackControlViewsByID {
            guard let track = tracksByID[trackID] else {
                refreshTrackControls()
                return
            }
            controlView.configure(
                title: track.name,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed,
                volume: track.volume,
                isTrackSelected: selectedTrackIDs.contains(track.id),
                isRecording: track.id == recordingTrackID,
                importProgress: activeImportProgress(for: track)
            )
        }
    }

    private func activeImportProgress(for track: ProjectTrack) -> Double? {
        guard
            let stage = track.importStage,
            !stage.isTerminal,
            stage != .editableReady
        else {
            return nil
        }
        return min(max(track.importProgress, 0), 1)
    }

    private func cancelAudioImport(for trackID: UUID) {
        guard
            let track = projectTracks.first(where: { $0.id == trackID }),
            let sessionID = track.importSessionID
        else {
            return
        }
        Task {
            await AudioImportCoordinator.shared.cancel(sessionID: sessionID)
            await AudioImportCoordinator.shared.forget(sessionID: sessionID)
        }
        removeProjectTrack(trackID)
        updateStatus("Import canceled")
    }

    private func rebuildTrackIndexCache() {
        trackIndicesByID.removeAll(keepingCapacity: true)
        trackIndicesByID.reserveCapacity(projectTracks.count)
        for (index, track) in projectTracks.enumerated() {
            trackIndicesByID[track.id] = index
        }
        trackIndexCacheTrackCount = projectTracks.count
    }

    private func updateTrackLaneLayout(_ layout: ResolvedTimelineTrackLayout) {
        let previousLayout = currentTrackLaneLayout
        guard currentTrackLaneLayout != layout else {
            layoutTrackControlViews()
            updateTimelineNavigationScrollbars()
            return
        }

        currentTrackLaneLayout = layout
        timelineZoomControls.display(
            horizontal: timelineSurface.horizontalZoomNormalizedValue,
            vertical: timelineSurface.verticalZoomNormalizedValue
        )
        updateTimelineNavigationScrollbars()
        let expectedVisibleTrackIDs = Set(layout.visibleTrackIndices(overscan: 1).compactMap { index in
            projectTracks.indices.contains(index) ? projectTracks[index].id : nil
        })
        if previousLayout.totalTrackCount == layout.totalTrackCount,
           Set(trackControlViewsByID.keys) == expectedVisibleTrackIDs {
            layoutTrackControlViews()
        } else {
            refreshTrackControls()
        }
    }

    private func updateTimelineLoopRange(_ loopRange: TimelineLoopRange) {
        let playbackProgress = projectedUnconstrainedVisualPlayheadProgress(
            at: CACurrentMediaTime(),
            duration: displayedDuration
        )
        let isPlaying = playbackController.isPlaying
        timelineLoopRange = loopRange
        previousLoopPlaybackProgress = nil
        setTimelineLoopPlaybackBypassed(
            TimelineLoopPlaybackPolicy.bypassesLoopAfterRangeChange(
                playbackProgress: playbackProgress,
                whilePlaying: isPlaying,
                loopRange: loopRange,
                isLoopEnabled: timelineLoopIsEnabled
            )
        )
        if isPlaying {
            startPlaybackTimer()
        }
    }

    private func updateTimelineLoopRangeEnabled(_ isEnabled: Bool) {
        let playbackSnapshot = playbackController.snapshot()
        timelineLoopIsEnabled = isEnabled
        previousLoopPlaybackProgress = nil
        setTimelineLoopPlaybackBypassed(
            isEnabled && TimelineLoopPlaybackPolicy.bypassesLoopWhenEnabledDuringPlayback(
                playbackProgress: playbackSnapshot.progress,
                whilePlaying: playbackSnapshot.isPlaying,
                loopRange: timelineLoopRange
            )
        )
        timelineSurface.displayLoopRangeEnabled(isEnabled)
        if playbackSnapshot.isPlaying {
            startPlaybackTimer()
        }
    }

    private func layoutTrackControlViews() {
        let viewportHeight = max(trackControlsStack.bounds.height, 1)
        let viewportWidth = max(trackControlsStack.bounds.width, 1)
        if trackIndexCacheTrackCount != projectTracks.count {
            rebuildTrackIndexCache()
        }

        for (trackID, controlView) in trackControlViewsByID {
            guard
                let trackIndex = trackIndicesByID[trackID],
                let laneFrame = currentTrackLaneLayout.laneFrame(forTrackIndex: trackIndex)
            else {
                controlView.isHidden = true
                continue
            }

            let top = CGFloat(laneFrame.top) * viewportHeight
            let bottom = CGFloat(laneFrame.bottom) * viewportHeight
            let clampedTop = min(max(top, 0), viewportHeight)
            let clampedBottom = min(max(bottom, 0), viewportHeight)
            let height = max(clampedBottom - clampedTop, 1)
            controlView.isHidden = clampedBottom <= 0 || clampedTop >= viewportHeight
            controlView.frame = NSRect(
                x: 0,
                y: viewportHeight - clampedBottom,
                width: viewportWidth,
                height: height
            )
        }
    }

    private func trackReorderYFromTop(windowPoint: CGPoint) -> Float {
        let localPoint = trackControlsStack.convert(windowPoint, from: nil)
        return Float(trackControlsStack.bounds.maxY - localPoint.y)
    }

    private func beginTrackReorder(
        trackID: UUID,
        controlView: TrackControlView?,
        windowPoint: CGPoint
    ) {
        guard projectTracks.contains(where: { $0.id == trackID }) else {
            return
        }
        trackReorderUndoSnapshot = captureProjectTrackUndoSnapshot(restoreProgress: nil)
        if let controlView {
            trackControlsStack.addSubview(controlView, positioned: .above, relativeTo: nil)
        }
        timelineSurface.beginTrackReorder(
            trackID: trackID,
            yFromTop: trackReorderYFromTop(windowPoint: windowPoint)
        )
    }

    private func updateTrackReorder(windowPoint: CGPoint) {
        timelineSurface.updateTrackReorder(
            yFromTop: trackReorderYFromTop(windowPoint: windowPoint)
        )
    }

    private func endTrackReorder(
        controlView: TrackControlView?,
        windowPoint: CGPoint,
        cancelled: Bool
    ) {
        if !cancelled {
            updateTrackReorder(windowPoint: windowPoint)
        }
        timelineSurface.endTrackReorder(cancelled: cancelled)
        controlView?.isBeingReordered = false
        trackReorderUndoSnapshot = nil
        refreshTrackControls()
    }

    private func commitTrackReorder(trackID: UUID, targetIndex: Int) {
        guard
            let sourceIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            !projectTracks.isEmpty
        else {
            return
        }
        let clampedTarget = min(max(targetIndex, 0), projectTracks.count - 1)
        guard sourceIndex != clampedTarget else {
            return
        }

        if let trackReorderUndoSnapshot {
            editUndoStack.append(.projectTracks(trackReorderUndoSnapshot))
        }
        let movedTrack = projectTracks.remove(at: sourceIndex)
        projectTracks.insert(movedTrack, at: clampedTarget)
        rebuildTrackIndexCache()

        let renderTracksByID = Dictionary(
            uniqueKeysWithValues: publishedTimelineRenderTracks.map { ($0.id, $0) }
        )
        publishedTimelineRenderTracks = projectTracks.compactMap { renderTracksByID[$0.id] }
        timelineSurface.displayTracks(
            publishedTimelineRenderTracks,
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false
        )

        let playbackTracksByID = Dictionary(
            uniqueKeysWithValues: publishedProjectPlaybackTracks.map { ($0.id, $0) }
        )
        publishedProjectPlaybackTracks = projectTracks.compactMap { playbackTracksByID[$0.id] }
        updateLoadedProjectSummary()
        scheduleAutosaveIfNeeded()
    }

    private func addEmptyTrack() {
        let snapshot = captureProjectTrackUndoSnapshot(restoreProgress: nil)
        editUndoStack.append(.projectTracks(snapshot))

        let trackID = UUID()
        let trackName = "Track \(projectTracks.count + 1)"
        let insertionIndex = projectTracks.count
        let track = ProjectTrack(
            id: trackID,
            editGroupID: editGroupIDForNewProjectTrack(),
            name: trackName,
            sourceURL: URL(fileURLWithPath: "/dev/null"),
            durationHint: nil,
            sourceWaveformOverview: nil,
            waveformOverview: nil,
            decodedAudioBuffer: nil,
            zeroCrossingIndex: nil,
            zeroCrossingProbe: nil,
            audioTimeline: nil,
            fileTimeline: nil,
            editableSource: nil,
            ownsSourceFile: false,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            importID: UUID(),
            editRevision: 0
        )

        timelineSurface.prepareTrackInsertionAnimation(at: insertionIndex)
        projectTracks.append(track)
        activeTrackID = trackID
        selectedTimelineRange = nil
        refreshProjectTimelineDisplay(animateWaveformTransition: false)
        timelineSurface.startPreparedTrackInsertionAnimation()
        selectTrack(trackID)
        updateProjectDisplayTiming()
        updateEffectCommandState()
        window?.title = projectWindowTitle()
        updateStatus("\(trackName) added")
    }

    private func toggleRecording(on trackID: UUID) {
        if recordingTrackID == trackID {
            stopRecording()
            return
        }

        startRecording(on: trackID)
    }

    private func startRecording(on trackID: UUID) {
        guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        if recordingTrackID != nil {
            stopRecording()
        }

        if playbackController.isPlaying {
            playbackController.pause()
            stopPlaybackTimer()
        }

        let recordingURL = recordingFileURL(trackName: projectTracks[trackIndex].name)
        let takeWriter: StreamingWAVTakeWriter
        do {
            takeWriter = try StreamingWAVTakeWriter(url: recordingURL)
        } catch {
            updateStatus("recording failed: \(error.localizedDescription)")
            return
        }

        recordingPreviewCoalescer.reset()
        inputRecorder.onChunk = { [weak self, takeWriter] chunk in
            takeWriter.append(chunk)
            self?.recordingPreviewCoalescer.enqueue(chunk) { chunks in
                Task { @MainActor in
                    self?.appendRecordingChunks(chunks)
                }
            }
        }

        do {
            try inputRecorder.start()
        } catch {
            inputRecorder.onChunk = nil
            takeWriter.cancel()
            updateStatus("recording failed: \(error.localizedDescription)")
            return
        }

        let snapshot = captureProjectTrackUndoSnapshot(restoreProgress: nil)
        recordingStartUndoSnapshot = snapshot
        recordingStartUndoStackCount = editUndoStack.count
        editUndoStack.append(.projectTracks(snapshot))

        recordingTrackID = trackID
        recordingTakeWriter = takeWriter
        recordingSampleRate = 0
        recordingAccumulator = nil
        lastRecordingVisualUpdateTimestamp = 0

        projectTracks[trackIndex].sourceURL = URL(fileURLWithPath: "/dev/null")
        projectTracks[trackIndex].durationHint = nil
        projectTracks[trackIndex].waveformOverview = nil
        projectTracks[trackIndex].decodedAudioBuffer = nil
        projectTracks[trackIndex].zeroCrossingIndex = nil
        projectTracks[trackIndex].zeroCrossingProbe = nil
        removeEditableArrangementMirror(forTrackID: trackID)
        projectTracks[trackIndex].audioTimeline = nil
        projectTracks[trackIndex].ownsSourceFile = false
        projectTracks[trackIndex].editRevision += 1
        activeTrackID = trackID
        selectedTrackID = nil
        selectedTrackIDs.removeAll()
        trackSelectionAnchorID = nil
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        publishSelectedTracksToTimeline()
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming()
        currentPlaybackStatus = "recording"
        displayPlaybackVisuals(
            progress: 1,
            isPlaying: true,
            syncPlayhead: true,
            restartsFisheyeActivation: true,
            restartsPlayheadKick: true
        )
        timelineSurface.displayRecordingActive(true)
        window?.makeFirstResponder(timelineSurface)
        updateStatus("recording \(projectTracks[trackIndex].name)")
    }

    private func stopRecording() {
        guard let trackID = recordingTrackID else {
            return
        }

        inputRecorder.stop()
        appendRecordingChunks(recordingPreviewCoalescer.drainPending())
        applyLiveRecordingOverview(force: true)
        let takeWriter = recordingTakeWriter
        recordingTakeWriter = nil
        inputRecorder.onChunk = nil
        recordingPreviewCoalescer.reset()

        recordingTrackID = nil
        timelineSurface.displayRecordingActive(false)
        displayPlaybackVisuals(progress: 1, isPlaying: false, syncPlayhead: true)
        refreshTrackControls()
        window?.makeFirstResponder(timelineSurface)

        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            let takeWriter
        else {
            recordingSampleRate = 0
            recordingAccumulator = nil
            recordingStartUndoSnapshot = nil
            recordingStartUndoStackCount = nil
            updateProjectDisplayTiming()
            updateStatus("recording stopped")
            return
        }

        let recordedTake: RecordedTakeFile
        do {
            recordedTake = try takeWriter.finish()
        } catch {
            takeWriter.cancel()
            restoreAfterDiscardedRecording(
                status: recordingDiscardStatus(for: error)
            )
            return
        }

        let fileInfo = try? WAVAudioDecoder.inspect(url: recordedTake.url)
        let zeroCrossingProbe = fileInfo.flatMap {
            try? WAVAudioDecoder.makeZeroCrossingProbe(url: recordedTake.url, fileInfo: $0)
        }
        let waveformOverview = recordingAccumulator?.makeOverview(sampleRate: recordedTake.sampleRate) ??
            (try? WAVAudioDecoder.buildSparsePreview(url: recordedTake.url).1)
        let importID = UUID()

        projectTracks[trackIndex].sourceURL = recordedTake.url
        projectTracks[trackIndex].durationHint = fileInfo?.duration ?? recordedTake.duration
        projectTracks[trackIndex].sourceWaveformOverview = waveformOverview
        projectTracks[trackIndex].waveformOverview = waveformOverview
        projectTracks[trackIndex].decodedAudioBuffer = nil
        projectTracks[trackIndex].zeroCrossingIndex = nil
        projectTracks[trackIndex].zeroCrossingProbe = zeroCrossingProbe
        projectTracks[trackIndex].audioTimeline = nil
        if let fileInfo {
            let fileTimeline = AudioFileEditTimeline(fileInfo: fileInfo)
            let editableSource = editableAudioSource(
                originalURL: recordedTake.url,
                editableURL: recordedTake.url,
                formatOrigin: .wav,
                fileInfo: fileInfo,
                ownsEditableFile: true
            )
            applyEditableTimelineMirror(
                trackIndex: trackIndex,
                source: editableSource,
                timeline: fileTimeline
            )
        } else {
            removeEditableArrangementMirror(forTrackID: trackID)
        }
        projectTracks[trackIndex].ownsSourceFile = true
        projectTracks[trackIndex].importID = importID
        projectTracks[trackIndex].editRevision = 0
        activeTrackID = trackID

        recordingSampleRate = 0
        recordingAccumulator = nil
        recordingStartUndoSnapshot = nil
        recordingStartUndoStackCount = nil
        syncActiveTrackFields()
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming(sampleRateHint: recordedTake.sampleRate)
        reloadPlaybackFromProjectTracks(preserveProgress: false)
        if let fileInfo {
            ensureLaunchDetailWaveformCache(
                fileInfo: fileInfo,
                candidateOverview: waveformOverview,
                trackID: trackID,
                trackName: projectTracks[trackIndex].name,
                reason: "recording-finished"
            )
        }
        startRecordedTakePreviewRefinement(trackID: trackID, importID: importID, url: recordedTake.url)
        updateEffectCommandState()
        updateStatus("recorded \(formatDuration(recordedTake.duration))")
    }

    private func restoreAfterDiscardedRecording(status: String) {
        recordingSampleRate = 0
        recordingAccumulator = nil

        if
            let undoStackCount = recordingStartUndoStackCount,
            editUndoStack.count == undoStackCount + 1
        {
            _ = editUndoStack.popLast()
        }

        if let snapshot = recordingStartUndoSnapshot {
            recordingStartUndoSnapshot = nil
            recordingStartUndoStackCount = nil
            restoreProjectTracks(from: snapshot)
        } else {
            recordingStartUndoStackCount = nil
            refreshProjectTimelineDisplay()
            updateProjectDisplayTiming()
        }

        updateStatus(status)
    }

    private func recordingDiscardStatus(for error: Error) -> String {
        if let writerError = error as? StreamingWAVTakeWriter.WriterError,
           case .noSamplesWritten = writerError
        {
            return "recording canceled"
        }

        return "recording failed: \(error.localizedDescription)"
    }

    private func appendRecordingChunks(_ chunks: [AudioRecordingChunk]) {
        guard !chunks.isEmpty else {
            return
        }

        for chunk in chunks {
            appendRecordingChunkSamples(chunk)
        }

        let now = CACurrentMediaTime()
        if now - lastRecordingVisualUpdateTimestamp >= 1.0 / 45.0 {
            applyLiveRecordingOverview(force: false)
            lastRecordingVisualUpdateTimestamp = now
        }
    }

    private func appendRecordingChunkSamples(_ chunk: AudioRecordingChunk) {
        guard recordingTrackID != nil, chunk.frameCount > 0, chunk.sampleRate > 0 else {
            return
        }

        let frameCount = min(
            chunk.frameCount,
            chunk.samplesByChannel.map(\.count).min() ?? chunk.frameCount
        )
        guard frameCount > 0 else {
            return
        }

        if recordingAccumulator == nil || recordingSampleRate != chunk.sampleRate {
            recordingSampleRate = chunk.sampleRate
            recordingAccumulator = LiveRecordingWaveformAccumulator(sampleRate: chunk.sampleRate)
        }

        recordingAccumulator?.append(
            samplesByChannel: chunk.samplesByChannel,
            frameCount: frameCount
        )
    }

    private func applyLiveRecordingOverview(force: Bool) {
        guard
            let recordingTrackID,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == recordingTrackID }),
            let recordingAccumulator,
            recordingSampleRate > 0
        else {
            return
        }

        let overview = recordingAccumulator.makeOverview(sampleRate: recordingSampleRate)
        guard force || overview.bins.isEmpty == false else {
            return
        }

        projectTracks[trackIndex].waveformOverview = overview
        projectTracks[trackIndex].durationHint = overview.duration
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming(sampleRateHint: recordingSampleRate)
        currentPlayheadFrame = displayedFrameCount
        let now = CACurrentMediaTime()
        visualPlayheadProgress = 1
        visualPlayheadAnchorTimestamp = now
        visualPlaybackActive = true
        timelineSurface.displayPlayheadProgress(
            1,
            syncRenderer: true,
            anchorTimestamp: now,
            resetsTouchStart: false
        )
        timelineSurface.displayRecordingActive(true)
        updateTimeReadout()
    }

    private func startRecordedTakePreviewRefinement(trackID: UUID, importID: UUID, url: URL) {
        let wavPreviewLevels = wavPreviewLevels
        Task { [weak self, trackID, importID, url, wavPreviewLevels] in
            var latestPreviewBinCount = 0
            for previewLevel in wavPreviewLevels {
                guard let self, self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                    return
                }
                guard await self.waitForImportWorkBudget(trackID: trackID, importID: importID) else {
                    return
                }

                do {
                    let (fileInfo, waveformOverview) = try await AudioImportPipeline.loadWAVPreviewOverview(
                        at: url,
                        targetBinCount: previewLevel.targetBinCount,
                        samplesPerBin: previewLevel.samplesPerBin
                    )
                    guard self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                        return
                    }
                    guard waveformOverview.bins.count > latestPreviewBinCount else {
                        continue
                    }

                    latestPreviewBinCount = waveformOverview.bins.count
                    self.applyTrackPreviewRefinement(
                        trackID: trackID,
                        fileInfo: fileInfo,
                        waveformOverview: waveformOverview
                    )
                    self.cacheWaveformOverview(
                        waveformOverview,
                        targetBinCount: previewLevel.targetBinCount,
                        samplesPerBin: previewLevel.samplesPerBin,
                        fileInfo: fileInfo
                    )
                } catch {
                    guard self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                        return
                    }
                    self.updateStatus("recording preview refinement failed: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    private func recordingFileURL(trackName: String) -> URL {
        let recordingsDirectory = recordingsDirectoryURL()
        try? FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )

        let safeTrackName = sanitizedSourceStem(trackName)
        let fileName = "\(safeTrackName.isEmpty ? "Recording" : safeTrackName)-\(UUID().uuidString).wav"
        return recordingsDirectory.appendingPathComponent(fileName)
    }

    private func audioProcessingDirectoryURL() -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return baseDirectory
            .appendingPathComponent("Soundtime", isDirectory: true)
            .appendingPathComponent("APIProcessing", isDirectory: true)
            .standardizedFileURL
    }

    private func audioProcessingInputURL(trackName: String) -> URL {
        let processingDirectory = audioProcessingDirectoryURL()
        try? FileManager.default.createDirectory(
            at: processingDirectory,
            withIntermediateDirectories: true
        )

        let safeTrackName = sanitizedSourceStem(trackName)
        let fileName = "\(safeTrackName.isEmpty ? "Audio" : safeTrackName)-Processing-Input-\(UUID().uuidString).wav"
        return processingDirectory.appendingPathComponent(fileName).standardizedFileURL
    }

    private func recordingsDirectoryURL() -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return baseDirectory
            .appendingPathComponent("Soundtime", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
            .standardizedFileURL
    }

    private func normalizedOwnedURL(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    private func isOwnedRecordingURL(_ url: URL) -> Bool {
        let recordingsDirectory = recordingsDirectoryURL()
        let candidate = normalizedOwnedURL(url)
        return candidate.path.hasPrefix(recordingsDirectory.path + "/")
            && candidate.pathExtension.lowercased() == "wav"
    }

    private func decodableWAVFileInfo(for url: URL) -> WAVFileInfo? {
        let normalizedURL = url.standardizedFileURL
        guard WAVAudioDecoder.canDecode(normalizedURL) else {
            return nil
        }

        if let cachedFileInfo = wavFileInfoCache[normalizedURL] {
            return cachedFileInfo
        }
        if invalidWAVFileInfoCache.contains(normalizedURL) {
            return nil
        }

        do {
            let fileInfo = try WAVAudioDecoder.inspect(url: normalizedURL)
            wavFileInfoCache[normalizedURL] = fileInfo
            return fileInfo
        } catch {
            invalidWAVFileInfoCache.insert(normalizedURL)
            return nil
        }
    }

    private func projectTrackSourceURL(
        for track: SoundtimeProject.Track,
        projectURL: URL
    ) -> URL {
        let url = storedProjectTrackSourceURL(for: track)
        guard
            track.editTimeline == nil,
            isOwnedRecordingURL(url),
            let ownedFileInfo = decodableWAVFileInfo(for: url),
            ownedFileInfo.duration > 0,
            ownedFileInfo.duration < 30
        else {
            return url
        }

        return recoveredOriginalSourceURL(
            forOwnedURL: url,
            ownedFileInfo: ownedFileInfo,
            projectURL: projectURL
        ) ?? url
    }

    private func storedProjectTrackSourceURL(for track: SoundtimeProject.Track) -> URL {
        URL(fileURLWithPath: track.filePath).standardizedFileURL
    }

    private func projectTrackSourceURL(
        for track: ProjectLaunchSnapshot.Track,
        projectURL: URL
    ) -> URL {
        let url = URL(fileURLWithPath: track.filePath).standardizedFileURL
        guard
            track.editTimeline == nil,
            isOwnedRecordingURL(url),
            let ownedFileInfo = decodableWAVFileInfo(for: url),
            ownedFileInfo.duration > 0,
            ownedFileInfo.duration < 30
        else {
            return url
        }

        return recoveredOriginalSourceURL(
            forOwnedURL: url,
            ownedFileInfo: ownedFileInfo,
            projectURL: projectURL
        ) ?? url
    }

    private func recoveredOriginalSourceURL(
        forOwnedURL ownedURL: URL,
        ownedFileInfo: WAVFileInfo,
        projectURL: URL
    ) -> URL? {
        let ownedStem = sanitizedSourceStem(ownedURL.deletingPathExtension().lastPathComponent)
        guard !ownedStem.isEmpty else {
            return nil
        }

        let minimumRecoveredDuration = max(ownedFileInfo.duration * 4, 30)
        return projectSourceRecoveryCandidateURLs(projectURL: projectURL)
            .filter { $0.standardizedFileURL != ownedURL.standardizedFileURL }
            .first { candidateURL in
                let candidateStem = sanitizedSourceStem(candidateURL.deletingPathExtension().lastPathComponent)
                guard
                    !candidateStem.isEmpty,
                    ownedStem == candidateStem || ownedStem.hasPrefix(candidateStem + "-"),
                    let candidateFileInfo = decodableWAVFileInfo(for: candidateURL)
                else {
                    return false
                }

                return candidateFileInfo.duration >= minimumRecoveredDuration
            }
    }

    private func projectSourceRecoveryCandidateURLs(projectURL: URL) -> [URL] {
        let projectDirectory = projectURL.deletingLastPathComponent()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.filter(WAVAudioDecoder.canDecode)
    }

    private func sanitizedSourceStem(_ value: String) -> String {
        value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private func ownedSourceURLs(in tracks: [ProjectTrack]) -> Set<URL> {
        Set(
            tracks.compactMap { track in
                guard track.ownsSourceFile, isOwnedRecordingURL(track.sourceURL) else {
                    return nil
                }
                return normalizedOwnedURL(track.sourceURL)
            }
        )
    }

    private func ownedSourceURLs(in undoStack: [UndoAction]) -> Set<URL> {
        undoStack.reduce(into: Set<URL>()) { urls, action in
            switch action {
            case let .projectTracks(snapshot):
                urls.formUnion(ownedSourceURLs(in: snapshot.tracks))
            case let .transaction(record):
                urls.formUnion(ownedSourceURLs(in: Array(record.before.tracksByID.values)))
                urls.formUnion(ownedSourceURLs(in: Array(record.after.tracksByID.values)))
            }
        }
    }

    private func deleteOwnedSourceFiles(_ urls: Set<URL>, async: Bool = false) {
        let recordingsDirectoryPath = recordingsDirectoryURL().path
        let deleteAction: @Sendable () -> Void = {
            for url in urls {
                let candidate = url.standardizedFileURL
                guard
                    candidate.path.hasPrefix(recordingsDirectoryPath + "/"),
                    candidate.pathExtension.lowercased() == "wav"
                else {
                    continue
                }

                try? AudioExportLeaseManager.shared.deleteOrDefer(candidate)
            }
        }

        if async {
            DispatchQueue.global(qos: .utility).async(execute: deleteAction)
        } else {
            deleteAction()
        }
    }

    private func cleanupOwnedSourceFiles(replacedTracks: [ProjectTrack]) {
        let candidateURLs = ownedSourceURLs(in: replacedTracks)
        guard candidateURLs.isEmpty == false else {
            return
        }

        pendingOwnedSourceCleanupURLs.formUnion(candidateURLs)
        ownedSourceCleanupWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            let candidates = self.pendingOwnedSourceCleanupURLs
            self.pendingOwnedSourceCleanupURLs.removeAll()
            self.ownedSourceCleanupWorkItem = nil
            var protectedURLs = self.ownedSourceURLs(in: self.projectTracks)
            protectedURLs.formUnion(self.ownedSourceURLs(in: self.editUndoStack))
            protectedURLs.formUnion(self.ownedSourceURLs(in: self.editRedoStack))
            self.deleteOwnedSourceFiles(
                candidates.subtracting(protectedURLs),
                async: true
            )
        }
        ownedSourceCleanupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func deleteAllOwnedSourceFiles(async: Bool = false) {
        ownedSourceCleanupWorkItem?.cancel()
        ownedSourceCleanupWorkItem = nil
        var urls = ownedSourceURLs(in: projectTracks)
        urls.formUnion(ownedSourceURLs(in: editUndoStack))
        urls.formUnion(ownedSourceURLs(in: editRedoStack))
        urls.formUnion(pendingOwnedSourceCleanupURLs)
        pendingOwnedSourceCleanupURLs.removeAll()
        deleteOwnedSourceFiles(urls, async: async)
    }

    private func markProjectSourceFilesAsSaved() {
        for index in projectTracks.indices where projectTracks[index].ownsSourceFile {
            projectTracks[index].ownsSourceFile = false
        }
        for undoIndex in editUndoStack.indices {
            switch editUndoStack[undoIndex] {
            case var .projectTracks(snapshot):
                for trackIndex in snapshot.tracks.indices where snapshot.tracks[trackIndex].ownsSourceFile {
                    snapshot.tracks[trackIndex].ownsSourceFile = false
                }
                editUndoStack[undoIndex] = .projectTracks(snapshot)
            case var .transaction(record):
                markTransactionSourcesAsSaved(&record)
                editUndoStack[undoIndex] = .transaction(record)
            }
        }
        for redoIndex in editRedoStack.indices {
            switch editRedoStack[redoIndex] {
            case var .projectTracks(snapshot):
                for trackIndex in snapshot.tracks.indices where snapshot.tracks[trackIndex].ownsSourceFile {
                    snapshot.tracks[trackIndex].ownsSourceFile = false
                }
                editRedoStack[redoIndex] = .projectTracks(snapshot)
            case var .transaction(record):
                markTransactionSourcesAsSaved(&record)
                editRedoStack[redoIndex] = .transaction(record)
            }
        }
    }

    private func markTransactionSourcesAsSaved(
        _ record: inout ProjectEditTransactionRecord
    ) {
        for trackID in record.before.tracksByID.keys {
            record.before.tracksByID[trackID]?.ownsSourceFile = false
        }
        for trackID in record.after.tracksByID.keys {
            record.after.tracksByID[trackID]?.ownsSourceFile = false
        }
    }

    private func selectTrack(_ trackID: UUID, modifierFlags: NSEvent.ModifierFlags = []) {
        guard let clickedIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        let usesRangeSelection = modifierFlags.contains(.shift)
        let togglesSelection = modifierFlags.contains(.command)

        if usesRangeSelection,
           let anchorID = trackSelectionAnchorID,
           let anchorIndex = projectTracks.firstIndex(where: { $0.id == anchorID })
        {
            let bounds = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            selectedTrackIDs = Set(bounds.map { projectTracks[$0].id })
            selectedTrackID = trackID
        } else if togglesSelection {
            if selectedTrackIDs.contains(trackID) {
                selectedTrackIDs.remove(trackID)
                if selectedTrackID == trackID {
                    selectedTrackID = selectedTrackIDs
                        .compactMap { id in projectTracks.firstIndex(where: { $0.id == id }).map { (index: $0, id: id) } }
                        .sorted { $0.index < $1.index }
                        .first?
                        .id
                }
            } else {
                selectedTrackIDs.insert(trackID)
                selectedTrackID = trackID
                trackSelectionAnchorID = trackID
            }
        } else {
            selectedTrackIDs = [trackID]
            selectedTrackID = trackID
            trackSelectionAnchorID = trackID
        }

        selectedTrackIDs = Set(projectTracks.map(\.id)).intersection(selectedTrackIDs)
        if let selectedTrackID, !selectedTrackIDs.contains(selectedTrackID) {
            self.selectedTrackID = selectedTrackIDs.first
        }
        activeTrackID = selectedTrackID ?? trackID
        let fullTrackSelection = selectedTrackID.map(fullTrackDisplaySelection)
        selectedTimelineRange = fullTrackSelection
        timelineSurface.displaySelection(fullTrackSelection)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        publishSelectedTracksToTimeline()
        refreshTrackControls()
        syncActiveTrackFields()
        window?.makeFirstResponder(timelineSurface)
        updateEffectCommandState()
        updateStatus(currentPlaybackStatus)
    }

    private func clearSelectedTrack() {
        guard !selectedTrackIDs.isEmpty || selectedTrackID != nil else {
            return
        }

        let trackID = selectedTrackID
        selectedTrackID = nil
        selectedTrackIDs.removeAll()
        trackSelectionAnchorID = nil
        if let trackID, isFullTrackSelection(selectedTimelineRange, trackID: trackID) {
            selectedTimelineRange = nil
            timelineSurface.displaySelection(nil)
            timelineSurface.displayGainPreview(selection: nil, gain: 1)
            updateEffectCommandState()
        }
        publishSelectedTracksToTimeline()
        refreshTrackControls()
    }

    private func dismissTimelineSelection() {
        clearDeadAirReview(publish: true)
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        clearSelectedTrack()
        updateEffectCommandState()
        updateStatus(currentPlaybackStatus)
    }

    private func publishSelectedTracksToTimeline() {
        let liveTrackIDs = Set(projectTracks.map(\.id))
        selectedTrackIDs = selectedTrackIDs.intersection(liveTrackIDs)
        if let selectedTrackID, !selectedTrackIDs.contains(selectedTrackID) {
            self.selectedTrackID = selectedTrackIDs.first
        }
        timelineSurface.displaySelectedTracks(selectedTrackIDs, primaryTrackID: selectedTrackID)
    }

    private func updateTrack(
        _ trackID: UUID,
        mixPublication: ProjectTrackMixPublication = .immediate,
        update: (inout ProjectTrack) -> Void
    ) {
        guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        update(&projectTracks[trackIndex])
        activeTrackID = trackID
        refreshProjectTrackMixDisplay()
        switch mixPublication {
        case .immediate:
            publishProjectTrackMixImmediately()
        case .coalesced:
            scheduleProjectTrackMixUpdate()
        }
        updateStatus(currentPlaybackStatus)
        if !isLoadingProject {
            scheduleAutosaveIfNeeded()
        }
    }

    private func reloadProjectPlaybackImmediately() {
        reloadPlaybackFromProjectTracks(preserveProgress: true)
    }

    private func loadDroppedAudioFile(at url: URL) {
        if WAVAudioDecoder.canDecode(url) {
            addDroppedWAVTrack(
                at: url,
                prewarm: consumeAudioImportPrewarm(for: url)
            )
            return
        }

        if AudioAssetImporter.canImport(url) {
            addDroppedAudioAssetTrack(
                at: url,
                prewarm: consumeAudioImportPrewarm(for: url)
            )
            return
        }
        showUnsupportedAudioFileAlert(for: url)
    }

    private func beginAudioImportPrewarm(for url: URL) {
        let normalizedURL = url.standardizedFileURL
        guard AudioAssetImporter.canImport(normalizedURL) else {
            return
        }
        if audioImportPrewarm?.url == normalizedURL {
            return
        }

        cancelAudioImportPrewarm()
        let isWAV = WAVAudioDecoder.canDecode(normalizedURL)
        let admissionTask: Task<AudioImportAdmission, Error>? = isWAV ? nil : Task.detached(
            priority: .userInitiated
        ) {
            try Task.checkCancellation()
            return try await AudioImportCoordinator.shared.admit(sourceURL: normalizedURL)
        }
        // Compressed formats are decoded once after drop. Their sequential proxy
        // pass publishes progressive waveform data, so prewarming a second
        // random-seek decoder would only compete with the authoritative work.
        let previewTask: Task<AudioAssetPreviewResult, Error>? = isWAV ? Task.detached(
            priority: .userInitiated
        ) {
            try Task.checkCancellation()
            return try await AudioImportPipeline.loadPreview(
                at: normalizedURL,
                targetBinCount: WAVImportPreviewPolicy.immediate.targetBinCount,
                samplesPerBin: WAVImportPreviewPolicy.immediate.samplesPerBin
            )
        } : nil
        let preparationTask: Task<AudioAssetProxyResult, Error>? = isWAV ? nil : Task.detached(
            priority: .userInitiated
        ) {
            guard let admissionTask else {
                throw CancellationError()
            }
            let admission = try await admissionTask.value
            try Task.checkCancellation()
            let task = await AudioImportCoordinator.shared.startPreparingEditableAsset(
                admission: admission
            )
            return try await task.value
        }
        audioImportPrewarm = AudioImportPrewarm(
            url: normalizedURL,
            admissionTask: admissionTask,
            previewTask: previewTask,
            preparationTask: preparationTask
        )
        SoundtimeDiagnostics.shared.record(
            category: .audio,
            severity: .info,
            name: "audio-import-prewarm-start",
            message: "Started prewarming an audio import while the file is hovering over the timeline.",
            fields: [
                "file": normalizedURL.lastPathComponent,
                "format": AudioAssetFormat.inferred(from: normalizedURL).displayName,
            ]
        )
        PerformanceDashboardWindowController.refreshIfVisible()
    }

    private func cancelAudioImportPrewarm(for url: URL? = nil) {
        guard let prewarm = audioImportPrewarm else {
            return
        }
        if let url, prewarm.url != url.standardizedFileURL {
            return
        }

        audioImportPrewarm = nil
        prewarm.admissionTask?.cancel()
        prewarm.previewTask?.cancel()
        prewarm.preparationTask?.cancel()
        Task {
            if let admissionTask = prewarm.admissionTask,
               let admission = try? await admissionTask.value
            {
                await AudioImportCoordinator.shared.forget(sessionID: admission.sessionID)
            }
        }
        SoundtimeDiagnostics.shared.record(
            category: .audio,
            severity: .info,
            name: "audio-import-prewarm-cancel",
            message: "Canceled audio import prewarm because the file drag left the timeline.",
            fields: [
                "file": prewarm.url.lastPathComponent,
                "format": AudioAssetFormat.inferred(from: prewarm.url).displayName,
            ]
        )
        PerformanceDashboardWindowController.refreshIfVisible()
    }

    private func consumeAudioImportPrewarm(for url: URL) -> AudioImportPrewarm? {
        let normalizedURL = url.standardizedFileURL
        guard let prewarm = audioImportPrewarm, prewarm.url == normalizedURL else {
            return nil
        }

        audioImportPrewarm = nil
        SoundtimeDiagnostics.shared.record(
            category: .audio,
            severity: .info,
            name: "audio-import-prewarm-consume",
            message: "Using prewarmed audio import work for a dropped file.",
            fields: [
                "file": normalizedURL.lastPathComponent,
                "format": AudioAssetFormat.inferred(from: normalizedURL).displayName,
            ]
        )
        PerformanceDashboardWindowController.refreshIfVisible()
        return prewarm
    }

    private func showUnsupportedAudioFileAlert(for url: URL) {
        let fileExtension = url.pathExtension.isEmpty ? "no file extension" : ".\(url.pathExtension.lowercased())"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unsupported Audio File"
        alert.informativeText = """
        Soundtime can't import "\(url.lastPathComponent)" because \(fileExtension) is not one of the supported audio formats.

        Supported formats: \(AudioAssetImporter.supportedAudioFormatSummary).
        """
        alert.addButton(withTitle: "OK")

        SoundtimeDiagnostics.shared.record(
            category: .audio,
            severity: .warning,
            name: "unsupported-audio-import",
            message: "User dropped an unsupported audio file type.",
            fields: [
                "file": url.lastPathComponent,
                "extension": fileExtension,
            ]
        )
        PerformanceDashboardWindowController.refreshIfVisible()

        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func addDroppedAudioAssetTrack(
        at url: URL,
        prewarm: AudioImportPrewarm? = nil
    ) {
        let importName = url.deletingPathExtension().lastPathComponent
        updateStatus("\(importName) opening")
        SoundtimeDiagnostics.shared.record(
            category: .audio,
            severity: .info,
            name: "audio-import-start",
            message: "Started staged import of a non-WAV audio file.",
            fields: [
                "file": url.lastPathComponent,
                "format": AudioAssetFormat.inferred(from: url).displayName,
            ]
        )
        PerformanceDashboardWindowController.refreshIfVisible()

        let normalizedURL = url.standardizedFileURL
        let importOperationID = UUID()
        activeImportOperationIDs.insert(importOperationID)
        Task { [weak self, importOperationID, normalizedURL, importName] in
            guard let self else {
                return
            }
            var pendingTrackIdentity: (trackID: UUID, importID: UUID)?
            var admittedSessionID: UUID?
            defer {
                self.activeImportOperationIDs.remove(importOperationID)
            }
            do {
                let admission: AudioImportAdmission
                if let admissionTask = prewarm?.admissionTask {
                    admission = try await admissionTask.value
                } else {
                    admission = try await AudioImportCoordinator.shared.admit(
                        sourceURL: normalizedURL
                    )
                }
                admittedSessionID = admission.sessionID

                let importIdentity = self.addPendingAudioAssetTrack(
                    admission: admission,
                    displayName: importName
                )
                pendingTrackIdentity = importIdentity
                prewarm?.previewTask?.cancel()
                let preparationTask = await AudioImportCoordinator.shared.startPreparingEditableAsset(
                    admission: admission
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.applyAudioImportProgress(
                            trackID: importIdentity.trackID,
                            importID: importIdentity.importID,
                            progress: progress
                        )
                    }
                }
                let proxyResult = try await preparationTask.value

                guard self.isTrackImportCurrent(
                    trackID: importIdentity.trackID,
                    importID: importIdentity.importID
                ) else {
                    await AudioImportCoordinator.shared.forget(
                        sessionID: admission.sessionID
                    )
                    admittedSessionID = nil
                    return
                }

                self.finishPendingAudioAssetImport(
                    trackID: importIdentity.trackID,
                    importID: importIdentity.importID,
                    proxyResult: proxyResult,
                    displayName: importName
                )
                let sourceRate = proxyResult.originalInfo.sampleRate.map { String(format: "%.0f", $0) } ?? "unknown"
                let proxyRate = String(format: "%.0f", proxyResult.proxyFileInfo.sampleRate)
                self.updateStatus("\(importName) imported")
                SoundtimeDiagnostics.shared.record(
                    category: .audio,
                    severity: .info,
                    name: "audio-import-complete",
                    message: "Imported audio through an editable WAV proxy.",
                    fields: [
                        "file": normalizedURL.lastPathComponent,
                        "format": proxyResult.originalInfo.format.displayName,
                        "sourceSampleRate": sourceRate,
                        "proxySampleRate": proxyRate,
                        "proxy": proxyResult.proxyURL.lastPathComponent,
                        "cacheHit": "\(proxyResult.cacheHit)",
                        "preparationMilliseconds": String(
                            format: "%.3f",
                            proxyResult.preparationMilliseconds
                        ),
                        "peakWorkingSetBytes": "\(proxyResult.peakWorkingSetBytes)",
                    ]
                )
                PerformanceDashboardWindowController.refreshIfVisible()
                await AudioImportCoordinator.shared.forget(
                    sessionID: admission.sessionID
                )
                admittedSessionID = nil
            } catch is CancellationError {
                if let admittedSessionID {
                    await AudioImportCoordinator.shared.forget(
                        sessionID: admittedSessionID
                    )
                }
                return
            } catch {
                if let admittedSessionID {
                    await AudioImportCoordinator.shared.forget(
                        sessionID: admittedSessionID
                    )
                }
                if
                    let pendingTrackIdentity,
                    let trackIndex = self.projectTracks.firstIndex(where: {
                        $0.id == pendingTrackIdentity.trackID &&
                            $0.importID == pendingTrackIdentity.importID
                    })
                {
                    self.projectTracks[trackIndex].importStage = .failed
                    self.projectTracks[trackIndex].importSessionID = nil
                    self.scheduleAutosaveIfNeeded()
                }
                self.updateStatus("\(importName) import failed: \(error.localizedDescription)")
                SoundtimeDiagnostics.shared.record(
                    category: .audio,
                    severity: .warning,
                    name: "audio-import-failed",
                    message: "Could not import audio through an editable proxy.",
                    fields: [
                        "file": normalizedURL.lastPathComponent,
                        "format": AudioAssetFormat.inferred(from: normalizedURL).displayName,
                        "error": error.localizedDescription,
                    ]
                )
                PerformanceDashboardWindowController.refreshIfVisible()
            }
        }
    }

    @discardableResult
    private func addPendingAudioAssetTrack(
        admission: AudioImportAdmission,
        displayName: String
    ) -> (trackID: UUID, importID: UUID) {
        let url = admission.sourceURL
        let assetInfo = admission.assetInfo
        let trackID = UUID()
        let importID = admission.assetID
        let trackName = displayName.isEmpty ? assetInfo.metadata.displayName : displayName
        let sourceFrameCount = max(assetInfo.frameCount ?? 0, 0)
        let sourceSampleRate = assetInfo.sampleRate ?? 0
        let channelCount = max(assetInfo.channelCount ?? 0, 0)
        let fileTimeline: AudioFileEditTimeline?
        let editableSource: EditableAudioSource?
        if sourceFrameCount > 0, sourceSampleRate.isFinite, sourceSampleRate > 0, channelCount > 0 {
            fileTimeline = AudioFileEditTimeline(
                sourceFrameCount: sourceFrameCount,
                sourceSampleRate: sourceSampleRate
            )
            editableSource = EditableAudioSource(
                importedAssetID: admission.assetID,
                originalURL: url,
                editableURL: url,
                formatOrigin: assetInfo.format,
                sourceFrameCount: sourceFrameCount,
                sourceSampleRate: sourceSampleRate,
                channelCount: channelCount,
                ownsEditableFile: false
            )
        } else {
            fileTimeline = nil
            editableSource = nil
        }
        let cachedOverview = admission.cachedImport?.waveformOverview
        let track = ProjectTrack(
            id: trackID,
            editGroupID: editGroupIDForNewProjectTrack(),
            name: trackName,
            sourceURL: url,
            durationHint: assetInfo.duration,
            sourceWaveformOverview: cachedOverview,
            waveformOverview: cachedOverview,
            decodedAudioBuffer: nil,
            zeroCrossingIndex: nil,
            zeroCrossingProbe: nil,
            audioTimeline: nil,
            fileTimeline: fileTimeline,
            editableSource: editableSource,
            ownsSourceFile: false,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            importID: importID,
            editRevision: 0,
            importedAssetID: admission.assetID,
            importSessionID: admission.sessionID,
            importStage: admission.initialStage,
            importProgress: admission.cachedImport == nil ? 0 : 1,
            importFingerprint: admission.fingerprint
        )

        projectTracks.append(track)
        if let fileTimeline, let editableSource {
            applyEditableTimelineMirror(
                trackIndex: projectTracks.count - 1,
                source: editableSource,
                timeline: fileTimeline
            )
        }
        activeTrackID = trackID
        selectedTrackID = nil
        selectedTrackIDs.removeAll()
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        publishSelectedTracksToTimeline()
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming(sampleRateHint: assetInfo.sampleRate)
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        updateEffectCommandState()
        syncActiveTrackFields()
        scheduleAutosaveIfNeeded()
        updateStatus(
            admission.cachedImport == nil ?
                "\(trackName) playable - preparing editable audio" :
                "\(trackName) editable audio restored from cache"
        )

        SoundtimeDiagnostics.shared.record(
            category: .audio,
            severity: .info,
            name: "audio-import-track-admitted",
            message: "Admitted an audio asset with an immediate logical edit timeline and original-file playback.",
            fields: [
                "file": url.lastPathComponent,
                "format": assetInfo.format.displayName,
                "duration": assetInfo.duration.map { String(format: "%.3f", $0) } ?? "unknown",
                "cacheHit": "\(admission.cachedImport != nil)",
                "assetID": admission.assetID.uuidString,
                "admissionMilliseconds": String(
                    format: "%.3f",
                    admission.admissionMilliseconds
                ),
            ]
        )
        PerformanceDashboardWindowController.refreshIfVisible()

        return (trackID, importID)
    }

    private func applyAudioImportProgress(
        trackID: UUID,
        importID: UUID,
        progress: AudioImportProgress
    ) {
        guard let trackIndex = projectTracks.firstIndex(where: {
            $0.id == trackID && $0.importID == importID
        }) else {
            return
        }

        projectTracks[trackIndex].importStage = progress.stage
        projectTracks[trackIndex].importProgress = progress.fraction
        if
            let previewOverview = progress.previewOverview,
            !previewOverview.bins.isEmpty,
            (
                projectTracks[trackIndex].sourceWaveformOverview == nil ||
                projectTracks[trackIndex].importPreviewIsProgressive
            )
        {
            let isFirstWaveform = projectTracks[trackIndex].sourceWaveformOverview == nil
            projectTracks[trackIndex].importPreviewIsProgressive = true
            projectTracks[trackIndex].sourceWaveformOverview = previewOverview
            projectTracks[trackIndex].waveformOverview =
                projectTracks[trackIndex].fileTimeline?.waveformOverview(
                    from: previewOverview
                ) ?? previewOverview
            refreshProjectTimelineDisplay(
                rebuildControls: false,
                animateWaveformTransition: false,
                allowImmediateWaveformPrewarm: true,
                allowImmediateInteractiveWaveformPrewarm: false,
                updatesRendererImmediately: true
            )
            if isFirstWaveform {
                SoundtimeDiagnostics.shared.record(
                    category: .waveform,
                    severity: .info,
                    name: "native-audio-first-waveform-published",
                    message: "Published the first waveform from the unified sequential import decode.",
                    fields: [
                        "trackID": trackID.uuidString,
                        "bins": "\(previewOverview.bins.count)",
                        "progress": String(format: "%.4f", progress.fraction),
                    ]
                )
            } else if progress.stage == .editableReady {
                SoundtimeDiagnostics.shared.record(
                    category: .waveform,
                    severity: .info,
                    name: "native-audio-screen-detail-waveform-published",
                    message: "Published the completed high-detail waveform before cache commit.",
                    fields: [
                        "trackID": trackID.uuidString,
                        "bins": "\(previewOverview.bins.count)",
                    ]
                )
            }
        }
        if let controlView = trackControlViewsByID[trackID] {
            controlView.configure(
                title: projectTracks[trackIndex].name,
                isMuted: projectTracks[trackIndex].isMuted,
                isSoloed: projectTracks[trackIndex].isSoloed,
                volume: projectTracks[trackIndex].volume,
                isTrackSelected: selectedTrackIDs.contains(trackID),
                isRecording: trackID == recordingTrackID,
                importProgress: activeImportProgress(for: projectTracks[trackIndex])
            )
        }
        updateStatus("\(projectTracks[trackIndex].name) \(progress.message.lowercased())")
    }

    private func finishPendingAudioAssetImport(
        trackID: UUID,
        importID: UUID,
        proxyResult: AudioAssetProxyResult,
        displayName: String
    ) {
        guard let trackIndex = projectTracks.firstIndex(where: {
            $0.id == trackID && $0.importID == importID
        }) else {
            return
        }
        let proxyURL = proxyResult.proxyURL.standardizedFileURL
        wavFileInfoCache[proxyURL] = proxyResult.proxyFileInfo
        invalidWAVFileInfoCache.remove(proxyURL)
        let zeroCrossingProbe = try? WAVAudioDecoder.makeZeroCrossingProbe(
            url: proxyURL,
            fileInfo: proxyResult.proxyFileInfo
        )

        projectTracks[trackIndex].name = displayName
        projectTracks[trackIndex].sourceURL = proxyURL
        projectTracks[trackIndex].durationHint = proxyResult.proxyFileInfo.duration
        projectTracks[trackIndex].importPreviewIsProgressive = false
        projectTracks[trackIndex].sourceWaveformOverview = proxyResult.waveformOverview
        projectTracks[trackIndex].waveformOverview = proxyResult.waveformOverview
        projectTracks[trackIndex].decodedAudioBuffer = nil
        // File-backed proxies use the bounded on-demand probe so very long imports
        // never need to retain every crossing in memory.
        projectTracks[trackIndex].zeroCrossingIndex = nil
        projectTracks[trackIndex].zeroCrossingProbe = zeroCrossingProbe
        let fileTimeline = projectTracks[trackIndex].fileTimeline?.remapped(
            toSourceFrameCount: proxyResult.proxyFileInfo.frameCount,
            sampleRate: proxyResult.proxyFileInfo.sampleRate
        ) ?? AudioFileEditTimeline(fileInfo: proxyResult.proxyFileInfo)
        let editableSource = editableAudioSource(
            originalURL: proxyResult.originalInfo.url,
            editableURL: proxyURL,
            formatOrigin: proxyResult.originalInfo.format,
            fileInfo: proxyResult.proxyFileInfo,
            ownsEditableFile: false,
            importedAssetID: proxyResult.assetID
        )
        applyEditableTimelineMirror(
            trackIndex: trackIndex,
            source: editableSource,
            timeline: fileTimeline
        )
        projectTracks[trackIndex].ownsSourceFile = false
        projectTracks[trackIndex].editRevision = fileTimeline.hasEdits ?
            max(projectTracks[trackIndex].editRevision, 1) :
            projectTracks[trackIndex].editRevision
        projectTracks[trackIndex].importID = UUID()
        projectTracks[trackIndex].importedAssetID = proxyResult.assetID
        projectTracks[trackIndex].importSessionID = nil
        projectTracks[trackIndex].importStage = .complete
        projectTracks[trackIndex].importProgress = 1
        projectTracks[trackIndex].importFingerprint = proxyResult.fingerprint

        activeTrackID = trackID
        window?.title = projectWindowTitle()
        refreshProjectTimelineDisplay(
            rebuildControls: false,
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: true,
            allowImmediateInteractiveWaveformPrewarm: false,
            updatesRendererImmediately: true
        )
        updateProjectDisplayTiming(sampleRateHint: proxyResult.proxyFileInfo.sampleRate)
        updateTimeReadout()
        syncActiveTrackFields()
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        updateEffectCommandState()
        scheduleAutosaveIfNeeded()

        cacheWaveformOverview(
            proxyResult.waveformOverview,
            targetBinCount: proxyResult.waveformOverview.bins.count,
            samplesPerBin: 1,
            fileInfo: proxyResult.proxyFileInfo
        )
        ensureLaunchDetailWaveformCache(
            fileInfo: proxyResult.proxyFileInfo,
            candidateOverview: proxyResult.waveformOverview,
            trackID: trackID,
            trackName: displayName,
            reason: "audio-import-complete"
        )
    }

    private func resumeImportedAudioPreparationIfNeeded(trackID: UUID) {
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            projectTracks[trackIndex].importSessionID == nil,
            let assetID = projectTracks[trackIndex].importedAssetID,
            !WAVAudioDecoder.canDecode(projectTracks[trackIndex].sourceURL),
            AudioAssetImporter.canImport(projectTracks[trackIndex].sourceURL)
        else {
            return
        }

        let sourceURL = projectTracks[trackIndex].sourceURL
        let displayName = projectTracks[trackIndex].name
        Task { [weak self, trackID, assetID, sourceURL, displayName] in
            guard let self else {
                return
            }
            var admittedSessionID: UUID?
            do {
                let admission = try await AudioImportCoordinator.shared.admit(
                    sourceURL: sourceURL,
                    assetID: assetID
                )
                admittedSessionID = admission.sessionID
                guard let currentIndex = self.projectTracks.firstIndex(where: { $0.id == trackID }) else {
                    await AudioImportCoordinator.shared.forget(sessionID: admission.sessionID)
                    admittedSessionID = nil
                    return
                }
                self.projectTracks[currentIndex].importID = assetID
                self.projectTracks[currentIndex].importSessionID = admission.sessionID
                self.projectTracks[currentIndex].importStage = admission.initialStage
                self.projectTracks[currentIndex].importFingerprint = admission.fingerprint
                if let cached = admission.cachedImport {
                    self.projectTracks[currentIndex].sourceWaveformOverview = cached.waveformOverview
                    self.projectTracks[currentIndex].waveformOverview =
                        self.projectTracks[currentIndex].fileTimeline?.waveformOverview(
                            from: cached.waveformOverview
                        ) ?? cached.waveformOverview
                    self.refreshProjectTimelineDisplay(
                        rebuildControls: false,
                        animateWaveformTransition: false
                    )
                }

                let task = await AudioImportCoordinator.shared.startPreparingEditableAsset(
                    admission: admission
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.applyAudioImportProgress(
                            trackID: trackID,
                            importID: assetID,
                            progress: progress
                        )
                    }
                }
                let result = try await task.value
                guard self.isTrackImportCurrent(trackID: trackID, importID: assetID) else {
                    await AudioImportCoordinator.shared.forget(
                        sessionID: admission.sessionID
                    )
                    admittedSessionID = nil
                    return
                }
                self.finishPendingAudioAssetImport(
                    trackID: trackID,
                    importID: assetID,
                    proxyResult: result,
                    displayName: displayName
                )
                await AudioImportCoordinator.shared.forget(
                    sessionID: admission.sessionID
                )
                admittedSessionID = nil
            } catch is CancellationError {
                if let admittedSessionID {
                    await AudioImportCoordinator.shared.forget(
                        sessionID: admittedSessionID
                    )
                }
                return
            } catch {
                if let admittedSessionID {
                    await AudioImportCoordinator.shared.forget(
                        sessionID: admittedSessionID
                    )
                }
                guard let currentIndex = self.projectTracks.firstIndex(where: { $0.id == trackID }) else {
                    return
                }
                self.projectTracks[currentIndex].importStage = .failed
                self.projectTracks[currentIndex].importSessionID = nil
                self.updateStatus("\(displayName) remains playable; editable proxy failed")
                SoundtimeDiagnostics.shared.record(
                    category: .audio,
                    severity: .warning,
                    name: "audio-import-resume-failed",
                    message: "A saved native import stayed playable but its editable proxy could not resume.",
                    fields: [
                        "file": sourceURL.lastPathComponent,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    private func addDroppedWAVTrack(
        at url: URL,
        settings: SoundtimeProject.Track? = nil,
        displayName: String? = nil,
        ownsSourceFile: Bool = false,
        prewarm: AudioImportPrewarm? = nil
    ) {
        let importStartedAt = DispatchTime.now().uptimeNanoseconds
        let trackID = settings?.id ?? UUID()
        let importID = UUID()
        let trackName = settings?.name ?? displayName ?? url.deletingPathExtension().lastPathComponent
        let fileInfo = try? WAVAudioDecoder.inspect(url: url)
        let launchPreview = fileInfo.flatMap { fileInfo -> SoundtimeProject.WaveformPreview? in
            guard
                let waveformPreview = settings?.waveformPreview,
                waveformPreview.isValid(for: fileInfo)
            else {
                return nil
            }

            return waveformPreview
        }
        let persistedFileTimeline: AudioFileEditTimeline?
        if
            let editTimeline = settings?.editTimeline,
            let restoredTimeline = AudioFileEditTimeline(persistentState: editTimeline),
            let fileInfo,
            restoredTimeline.isCompatible(with: fileInfo)
        {
            persistedFileTimeline = restoredTimeline
        } else {
            persistedFileTimeline = nil
        }
        let canonicalFileTimeline = persistedFileTimeline ?? fileInfo.map(AudioFileEditTimeline.init(fileInfo:))
        let restoredEditableSource = fileInfo.flatMap { fileInfo in
            settings?.editableSource?.editableAudioSource(fileInfo: fileInfo)
        }
        let editableSource = restoredEditableSource ?? fileInfo.map { fileInfo in
            editableAudioSource(
                originalURL: url,
                editableURL: url,
                formatOrigin: AudioAssetFormat.inferred(from: url),
                fileInfo: fileInfo,
                ownsEditableFile: settings?.ownsSourceFile ?? ownsSourceFile
            )
        }
        // Project restore may synchronously use its bounded launch cache before
        // first paint. A newly dropped file must publish its lane first and do
        // every cache lookup off the main thread.
        let shouldCheckLaunchCacheSynchronously = settings != nil && launchPreview == nil
        let cachedLaunchEntry = shouldCheckLaunchCacheSynchronously ? fileInfo.flatMap { fileInfo in
            cachedWaveformOverviewForLaunch(
                at: url,
                fileInfo: fileInfo,
                maximumBinCount: LaunchWaveformCache.synchronousBinLimit
            )
        } : nil
        let cachedEditedLaunchEntry: EditedWaveformOverviewDiskCacheEntry?
        if
            shouldCheckLaunchCacheSynchronously,
            let fileInfo,
            let persistedFileTimeline,
            persistedFileTimeline.hasEdits
        {
            cachedEditedLaunchEntry = cachedEditedWaveformOverviewForLaunch(
                at: url,
                fileInfo: fileInfo,
                fileTimeline: persistedFileTimeline
            )
        } else {
            cachedEditedLaunchEntry = nil
        }
        let previewSourceOverview = launchPreview?.sourceOverview.waveformOverview
        let previewDisplayOverview = launchPreview?.displayOverview.waveformOverview
        let launchSourceOverview = bestAvailableLaunchOverview(
            cachedLaunchEntry?.overview,
            previewSourceOverview
        )
        let launchDisplayOverview: WaveformOverview?
        if persistedFileTimeline != nil {
            launchDisplayOverview = cachedEditedLaunchEntry?.overview ??
                previewDisplayOverview ??
                launchSourceOverview
        } else {
            launchDisplayOverview = bestAvailableLaunchOverview(
                cachedLaunchEntry?.overview,
                previewDisplayOverview
            )
        }
        let launchPreviewBinCount = max(
            launchSourceOverview?.bins.count ?? 0,
            launchDisplayOverview?.bins.count ?? 0
        )
        let durationHint = canonicalFileTimeline?.duration ?? launchDisplayOverview?.duration ?? fileInfo?.duration
        let track = ProjectTrack(
            id: trackID,
            editGroupID: settings?.editGroupID ?? editGroupIDForNewProjectTrack(),
            name: trackName,
            sourceURL: url,
            durationHint: durationHint,
            sourceWaveformOverview: launchSourceOverview,
            waveformOverview: launchDisplayOverview,
            decodedAudioBuffer: nil,
            zeroCrossingIndex: nil,
            zeroCrossingProbe: nil,
            audioTimeline: nil,
            fileTimeline: canonicalFileTimeline,
            editableSource: editableSource,
            ownsSourceFile: settings?.ownsSourceFile ?? ownsSourceFile,
            volume: settings?.volume ?? 1,
            isMuted: settings?.isMuted ?? false,
            isSoloed: settings?.isSoloed ?? false,
            importID: importID,
            editRevision: persistedFileTimeline?.hasEdits == true ? 1 : 0,
            transcript: settings?.transcript
        )

        projectTracks.append(track)
        recordDroppedWAVImportMilestone(
            name: "wav-import-track-published",
            message: "Published the dropped WAV track lane.",
            startedAt: importStartedAt,
            trackID: trackID,
            sourceURL: url,
            binCount: launchDisplayOverview?.bins.count
        )
        if let editableSource, let canonicalFileTimeline {
            projectEditGraph.upsert(
                source: editableSource,
                trackID: trackID,
                timeline: canonicalFileTimeline
            )
        }
        if !isLoadingProject {
            scheduleAutosaveIfNeeded()
        }
        activeTrackID = trackID
        selectedTimelineRange = nil
        updateEffectCommandState()
        if !isLoadingProject {
            refreshProjectTimelineDisplay()
            updateProjectDisplayTiming()
        }
        if !isLoadingProject {
            reloadPlaybackFromProjectTracks(preserveProgress: true)
            recordDroppedWAVImportMilestone(
                name: "wav-import-playback-ready",
                message: "Published file-backed playback for a dropped WAV.",
                startedAt: importStartedAt,
                trackID: trackID,
                sourceURL: url,
                binCount: launchDisplayOverview?.bins.count
            )
        }
        let launchPreviewReason: String
        if launchPreview != nil {
            launchPreviewReason = "valid"
        } else if settings?.waveformPreview != nil {
            launchPreviewReason = fileInfo == nil ? "file-inspection-failed" : "fingerprint-mismatch"
        } else {
            launchPreviewReason = "not-stored"
        }
        recordWaveformCacheDecision(
            name: launchPreview == nil ? "launch-preview-miss" : "launch-preview-hit",
            message: launchPreview == nil ?
                "No saved project launch waveform preview was usable for this track." :
                "Loaded saved project launch waveform preview for this track.",
            tier: "projectLaunchPreview",
            result: launchPreview == nil ? "miss" : "hit",
            trackID: trackID,
            trackName: trackName,
            sourceURL: url,
            binCount: previewDisplayOverview?.bins.count,
            reason: launchPreviewReason
        )
        if fileInfo != nil {
            recordWaveformCacheDecision(
                name: cachedLaunchEntry == nil ? "launch-raw-overview-cache-miss" : "launch-raw-overview-cache-hit",
                message: cachedLaunchEntry == nil ?
                    "No high-resolution raw waveform overview was available before the first project draw." :
                    "Loaded high-resolution raw waveform overview before the first project draw.",
                tier: "rawOverviewDiskCacheLaunch",
                result: cachedLaunchEntry == nil ? "miss" : "hit",
                trackID: trackID,
                trackName: trackName,
                sourceURL: url,
                binCount: cachedLaunchEntry?.overview.bins.count,
                targetBinCount: cachedLaunchEntry?.level.targetBinCount,
                samplesPerBin: cachedLaunchEntry?.level.samplesPerBin,
                reason: cachedLaunchEntry == nil ?
                    (shouldCheckLaunchCacheSynchronously ? "not-found" : "deferred-until-after-first-draw") :
                    nil
            )
            if persistedFileTimeline?.hasEdits == true {
                recordWaveformCacheDecision(
                    name: cachedEditedLaunchEntry == nil ?
                        "launch-edited-overview-cache-miss" :
                        "launch-edited-overview-cache-hit",
                    message: cachedEditedLaunchEntry == nil ?
                        "No edited waveform overview was available before the first project draw; source overview plus edit segments will render instead." :
                        "Loaded edited waveform overview before the first project draw.",
                    tier: "editedOverviewDiskCacheLaunch",
                    result: cachedEditedLaunchEntry == nil ? "miss" : "hit",
                    trackID: trackID,
                    trackName: trackName,
                    sourceURL: url,
                    binCount: cachedEditedLaunchEntry?.overview.bins.count,
                    editRevision: persistedFileTimeline?.hasEdits == true ? track.editRevision : nil,
                    reason: cachedEditedLaunchEntry == nil ?
                        (shouldCheckLaunchCacheSynchronously ?
                            "not-found-for-edit-state" :
                            "deferred-until-after-first-draw") :
                        nil
                )
            }
        }
        if cachedLaunchEntry != nil || cachedEditedLaunchEntry != nil {
            updateStatus("waveform cache ready - resolving waveform")
        } else {
            updateStatus(launchPreview == nil ? "\(trackName) loading" : "launch preview ready - resolving waveform")
        }

        let wavPreviewLevels = wavPreviewLevels
        Task { [weak self, trackID, importID, url, fileInfo, wavPreviewLevels, launchPreviewBinCount, prewarm] in
            do {
                guard let initialPreviewLevel = wavPreviewLevels.first else {
                    return
                }

                guard let self, self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                    return
                }

                var latestPreviewBinCount = launchPreviewBinCount
                var latestFileInfo = fileInfo
                if latestPreviewBinCount < min(initialPreviewLevel.targetBinCount, fileInfo?.frameCount ?? Int.max) {
                    let previewResult: AudioAssetPreviewResult
                    if let previewTask = prewarm?.previewTask {
                        previewResult = try await previewTask.value
                    } else {
                        previewResult = try await Task.detached(priority: .userInitiated) {
                            try await AudioImportPipeline.loadPreview(
                                at: url,
                                targetBinCount: initialPreviewLevel.targetBinCount,
                                samplesPerBin: initialPreviewLevel.samplesPerBin
                            )
                        }.value
                    }

                    guard
                        self.isTrackImportCurrent(trackID: trackID, importID: importID),
                        let previewResult = previewResult.wavPreviewResult
                    else {
                        return
                    }

                    self.applyDroppedWAVInitialPreview(
                        trackID: trackID,
                        previewResult: previewResult
                    )
                    self.cacheWaveformOverview(
                        previewResult.waveformOverview,
                        targetBinCount: initialPreviewLevel.targetBinCount,
                        samplesPerBin: initialPreviewLevel.samplesPerBin,
                        fileInfo: previewResult.fileInfo
                    )
                    latestPreviewBinCount = previewResult.waveformOverview.bins.count
                    latestFileInfo = previewResult.fileInfo
                    self.recordDroppedWAVImportMilestone(
                        name: "wav-import-first-waveform-published",
                        message: "Published the first interactive waveform for a dropped WAV.",
                        startedAt: importStartedAt,
                        trackID: trackID,
                        sourceURL: url,
                        binCount: latestPreviewBinCount
                    )

                    let zeroCrossingProbe = try? await Task.detached(priority: .utility) {
                        try WAVAudioDecoder.makeZeroCrossingProbe(
                            url: url,
                            fileInfo: previewResult.fileInfo
                        )
                    }.value
                    if
                        self.isTrackImportCurrent(trackID: trackID, importID: importID),
                        let trackIndex = self.projectTracks.firstIndex(where: { $0.id == trackID })
                    {
                        self.projectTracks[trackIndex].zeroCrossingProbe = zeroCrossingProbe
                    }
                } else {
                    prewarm?.previewTask?.cancel()
                    if let admissionTask = prewarm?.admissionTask,
                       let admission = try? await admissionTask.value
                    {
                        await AudioImportCoordinator.shared.forget(sessionID: admission.sessionID)
                    }
                    self.updateStatus(WAVImportPreviewPolicy.readyStatus)
                }

                if let fileInfo {
                    let fastCachedEntry = await self.cachedWaveformOverview(
                        at: url,
                        fileInfo: fileInfo,
                        maximumBinCount: LaunchWaveformCache.firstRefinementBinCount
                    )
                    if
                        let fastCachedEntry,
                        self.isTrackImportCurrent(trackID: trackID, importID: importID),
                        fastCachedEntry.overview.bins.count > latestPreviewBinCount
                    {
                        self.recordWaveformCacheDecision(
                            name: "raw-overview-fast-cache-hit",
                            message: "Loaded fast launch-detail waveform overview from disk cache.",
                            tier: "rawOverviewDiskCache",
                            result: "hit",
                            trackID: trackID,
                            trackName: trackName,
                            sourceURL: url,
                            binCount: fastCachedEntry.overview.bins.count,
                            targetBinCount: fastCachedEntry.level.targetBinCount,
                            samplesPerBin: fastCachedEntry.level.samplesPerBin
                        )
                        latestPreviewBinCount = fastCachedEntry.overview.bins.count
                        latestFileInfo = fastCachedEntry.fileInfo
                        let editedDisplayOverview = await self.cachedEditedDisplayOverviewForTrack(
                            trackID: trackID,
                            sourceURL: url,
                            fileInfo: fastCachedEntry.fileInfo
                        )
                        self.applyTrackPreviewRefinement(
                            trackID: trackID,
                            fileInfo: fastCachedEntry.fileInfo,
                            waveformOverview: fastCachedEntry.overview,
                            displayOverviewOverride: editedDisplayOverview
                        )
                    } else if self.isTrackImportCurrent(trackID: trackID, importID: importID) {
                        self.recordWaveformCacheDecision(
                            name: "raw-overview-fast-cache-miss",
                            message: "Fast launch-detail waveform overview disk cache was unavailable or not finer than the current preview.",
                            tier: "rawOverviewDiskCache",
                            result: fastCachedEntry == nil ? "miss" : "skipped",
                            trackID: trackID,
                            trackName: trackName,
                            sourceURL: url,
                            binCount: fastCachedEntry?.overview.bins.count,
                            targetBinCount: fastCachedEntry?.level.targetBinCount,
                            samplesPerBin: fastCachedEntry?.level.samplesPerBin,
                            reason: fastCachedEntry == nil ? "not-found" : "not-finer-than-current-preview"
                        )
                    }

                } else {
                    self.recordWaveformCacheDecision(
                        name: "raw-overview-cache-miss",
                        message: "Raw waveform overview disk cache could not be checked because the WAV file was not inspectable.",
                        tier: "rawOverviewDiskCache",
                        result: "miss",
                        trackID: trackID,
                        trackName: trackName,
                        sourceURL: url,
                        reason: "file-inspection-failed"
                    )
                }

                for previewLevel in wavPreviewLevels.dropFirst() {
                    guard self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                        return
                    }
                    guard await self.waitForImportWorkBudget(trackID: trackID, importID: importID) else {
                        return
                    }

                    let nextBinCount = min(previewLevel.targetBinCount, latestFileInfo?.frameCount ?? Int.max)
                    guard nextBinCount > latestPreviewBinCount else {
                        continue
                    }

                    do {
                        self.recordWaveformCacheDecision(
                            name: "preview-refinement-rebuild",
                            message: "Building finer waveform preview level in the background.",
                            tier: "backgroundRebuild",
                            result: "build",
                            trackID: trackID,
                            trackName: trackName,
                            sourceURL: url,
                            targetBinCount: previewLevel.targetBinCount,
                            samplesPerBin: previewLevel.samplesPerBin
                        )
                        let (fileInfo, waveformOverview) = try await AudioImportPipeline.loadWAVPreviewOverview(
                            at: url,
                            targetBinCount: previewLevel.targetBinCount,
                            samplesPerBin: previewLevel.samplesPerBin
                        )

                        guard self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                            return
                        }
                        guard await self.waitForImportWorkBudget(trackID: trackID, importID: importID) else {
                            return
                        }

                        latestPreviewBinCount = waveformOverview.bins.count
                        latestFileInfo = fileInfo
                        let editedDisplayOverview = await self.cachedEditedDisplayOverviewForTrack(
                            trackID: trackID,
                            sourceURL: url,
                            fileInfo: fileInfo
                        )
                        self.applyTrackPreviewRefinement(
                            trackID: trackID,
                            fileInfo: fileInfo,
                            waveformOverview: waveformOverview,
                            displayOverviewOverride: editedDisplayOverview
                        )
                        self.cacheWaveformOverview(
                            waveformOverview,
                            targetBinCount: previewLevel.targetBinCount,
                            samplesPerBin: previewLevel.samplesPerBin,
                            fileInfo: fileInfo
                        )
                    } catch {
                        break
                    }
                }

                self.recordDroppedWAVImportMilestone(
                    name: "wav-import-background-refinement-complete",
                    message: "Completed bounded background waveform refinement for a dropped WAV.",
                    startedAt: importStartedAt,
                    trackID: trackID,
                    sourceURL: url,
                    binCount: latestPreviewBinCount
                )
            } catch {
                guard let self, self.isTrackImportCurrent(trackID: trackID, importID: importID) else {
                    return
                }

                if let admissionTask = prewarm?.admissionTask,
                   let admission = try? await admissionTask.value
                {
                    await AudioImportCoordinator.shared.forget(sessionID: admission.sessionID)
                }

                self.removeProjectTrack(trackID)
                self.updateStatus("\(url.lastPathComponent) preview failed: \(error.localizedDescription)")
            }
        }
    }

    private func isTrackImportCurrent(trackID: UUID, importID: UUID) -> Bool {
        projectTracks.contains { $0.id == trackID && $0.importID == importID }
    }

    private func recordDroppedWAVImportMilestone(
        name: String,
        message: String,
        startedAt: UInt64,
        trackID: UUID,
        sourceURL: URL,
        binCount: Int?
    ) {
        var fields = [
            "elapsedMs": String(
                format: "%.3f",
                Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000
            ),
            "file": sourceURL.lastPathComponent,
            "trackID": trackID.uuidString,
        ]
        if let binCount {
            fields["bins"] = "\(binCount)"
        }
        SoundtimeDiagnostics.shared.record(
            category: .waveform,
            severity: .info,
            name: name,
            message: message,
            fields: fields
        )
        PerformanceDashboardWindowController.refreshIfVisible()
    }

    private func waitForImportWorkBudget(
        trackID: UUID,
        importID: UUID,
        idleSettleDuration: TimeInterval = 0.18
    ) async -> Bool {
        await waitForImportWorkBudget(
            idleSettleDuration: idleSettleDuration,
            isCurrent: { [weak self] in
                self?.isTrackImportCurrent(trackID: trackID, importID: importID) == true
            }
        )
    }

    private func waitForSingleFileImportWorkBudget(
        importID: UUID,
        idleSettleDuration: TimeInterval = 0.18
    ) async -> Bool {
        await waitForImportWorkBudget(
            idleSettleDuration: idleSettleDuration,
            isCurrent: { [weak self] in
                self?.activeImportID == importID
            }
        )
    }

    private func waitForImportWorkBudget(
        idleSettleDuration: TimeInterval,
        isCurrent: () -> Bool
    ) async -> Bool {
        guard isCurrent(), !Task.isCancelled else {
            return false
        }

        do {
            try await ImportWorkBudget.shared.waitForAsyncTurn(
                idleSettleDuration >= 0.5 ? .backgroundDecode : .previewRefinement
            )
        } catch {
            return false
        }
        await Task.yield()
        return isCurrent() && !Task.isCancelled
    }

    private func cachedWaveformOverview(
        at url: URL,
        fileInfo: WAVFileInfo,
        maximumBinCount: Int? = WaveformOverviewDiskCacheStore.maximumCachedBinCount
    ) async -> WaveformOverviewDiskCacheEntry? {
        let cache = waveformOverviewDiskCache
        return await Task.detached(priority: .userInitiated) {
            try? cache.loadBestOverview(
                for: url,
                fileInfo: fileInfo,
                maximumBinCount: maximumBinCount
            )
        }.value
    }

    private func cachedWaveformOverviewForLaunch(
        at url: URL,
        fileInfo: WAVFileInfo,
        maximumBinCount: Int? = WaveformOverviewDiskCacheStore.maximumCachedBinCount
    ) -> WaveformOverviewDiskCacheEntry? {
        try? waveformOverviewDiskCache.loadBestOverview(
            for: url,
            fileInfo: fileInfo,
            maximumBinCount: maximumBinCount
        )
    }

    private func cachedEditedWaveformOverviewForLaunch(
        at url: URL,
        fileInfo: WAVFileInfo,
        fileTimeline: AudioFileEditTimeline
    ) -> EditedWaveformOverviewDiskCacheEntry? {
        try? waveformOverviewDiskCache.loadEditedOverview(
            for: url,
            fileInfo: fileInfo,
            editTimeline: fileTimeline
        )
    }

    private func bestAvailableLaunchOverview(
        _ first: WaveformOverview?,
        _ second: WaveformOverview?
    ) -> WaveformOverview? {
        guard let first else {
            return second
        }
        guard let second else {
            return first
        }

        return first.bins.count >= second.bins.count ? first : second
    }

    private func recordWaveformCacheDecision(
        name: String,
        message: String,
        tier: String,
        result: String,
        trackID: UUID? = nil,
        trackName: String? = nil,
        sourceURL: URL? = nil,
        binCount: Int? = nil,
        targetBinCount: Int? = nil,
        samplesPerBin: Int? = nil,
        editRevision: Int? = nil,
        reason: String? = nil
    ) {
        var fields: [String: String] = [
            "tier": tier,
            "result": result,
        ]
        if let trackID {
            fields["trackID"] = trackID.uuidString
        }
        if let trackName {
            fields["trackName"] = trackName
        }
        if let sourceURL {
            fields["file"] = sourceURL.lastPathComponent
        }
        if let binCount {
            fields["bins"] = "\(binCount)"
        }
        if let targetBinCount {
            fields["targetBins"] = "\(targetBinCount)"
        }
        if let samplesPerBin {
            fields["samplesPerBin"] = "\(samplesPerBin)"
        }
        if let editRevision {
            fields["editRevision"] = "\(editRevision)"
        }
        if let reason {
            fields["reason"] = reason
        }

        SoundtimeDiagnostics.shared.record(
            category: .waveform,
            severity: .info,
            name: name,
            message: message,
            fields: fields
        )
        PerformanceDashboardWindowController.refreshIfVisible()
    }

    private func cachedWAVPreviewResult(
        at url: URL,
        fileInfo: WAVFileInfo
    ) async -> WAVPreviewImportResult? {
        let cache = waveformOverviewDiskCache
        return await Task.detached(priority: .userInitiated) {
            guard
                let cachedEntry = try? cache.loadBestOverview(
                    for: url,
                    fileInfo: fileInfo
                )
            else {
                return nil
            }

            let metadata: AudioFileMetadata
            do {
                metadata = try AudioFileMetadataLoader.loadQuickMetadata(
                    for: url,
                    duration: fileInfo.duration
                )
            } catch {
                return nil
            }
            let zeroCrossingProbe = try? WAVAudioDecoder.makeZeroCrossingProbe(
                url: url,
                fileInfo: fileInfo
            )
            return WAVPreviewImportResult(
                metadata: metadata,
                fileInfo: fileInfo,
                waveformOverview: cachedEntry.overview,
                zeroCrossingProbe: zeroCrossingProbe
            )
        }.value
    }

    private func cacheWaveformOverview(
        _ overview: WaveformOverview,
        targetBinCount: Int,
        samplesPerBin: Int,
        fileInfo: WAVFileInfo
    ) {
        let cache = waveformOverviewDiskCache
        Task.detached(priority: .utility) {
            _ = try? cache.saveOverview(
                overview,
                targetBinCount: targetBinCount,
                samplesPerBin: samplesPerBin,
                fileInfo: fileInfo
            )
        }
    }

    private func ensureLaunchDetailWaveformCache(
        fileInfo: WAVFileInfo,
        candidateOverview: WaveformOverview?,
        trackID: UUID? = nil,
        trackName: String? = nil,
        reason: String
    ) {
        let targetBinCount = min(LaunchWaveformCache.firstRefinementBinCount, fileInfo.frameCount)
        guard targetBinCount > 0 else {
            return
        }

        let cacheKey = fileInfo.url.standardizedFileURL.path
        guard !launchWaveformCacheTasks.contains(cacheKey) else {
            return
        }

        let cache = waveformOverviewDiskCache
        let sourceURL = fileInfo.url
        launchWaveformCacheTasks.startDetached(for: cacheKey, priority: .utility) { [
            cache,
            fileInfo,
            sourceURL,
            candidateOverview,
            targetBinCount,
            trackID,
            trackName,
            reason
        ] in
            if Task.isCancelled {
                return
            }

            if
                let existingEntry = try? cache.loadBestOverview(
                    for: sourceURL,
                    fileInfo: fileInfo,
                    maximumBinCount: LaunchWaveformCache.synchronousBinLimit
                ),
                existingEntry.overview.bins.count >= targetBinCount
            {
                return
            }

            do {
                let overview: WaveformOverview
                let cacheSource: String
                if let candidateOverview, candidateOverview.bins.count >= targetBinCount {
                    overview = Self.sparseOverview(
                        from: candidateOverview,
                        targetBinCount: targetBinCount,
                        samplesPerBin: LaunchWaveformCache.firstRefinementSamplesPerBin
                    )
                    cacheSource = "memory-downsample"
                } else {
                    let (_, builtOverview) = try await AudioImportPipeline.loadWAVPreviewOverview(
                        at: sourceURL,
                        targetBinCount: LaunchWaveformCache.firstRefinementBinCount,
                        samplesPerBin: LaunchWaveformCache.firstRefinementSamplesPerBin
                    )
                    overview = builtOverview
                    cacheSource = "wav-preview"
                }

                if Task.isCancelled {
                    return
                }

                try cache.saveOverview(
                    overview,
                    targetBinCount: LaunchWaveformCache.firstRefinementBinCount,
                    samplesPerBin: LaunchWaveformCache.firstRefinementSamplesPerBin,
                    fileInfo: fileInfo
                )

                SoundtimeDiagnostics.shared.record(
                    category: .waveform,
                    severity: .info,
                    name: "launch-detail-waveform-cache-ready",
                    message: "Prepared launch-detail waveform overview for a future project open.",
                    fields: Self.launchDetailWaveformCacheFields(
                        fileInfo: fileInfo,
                        trackID: trackID,
                        trackName: trackName,
                        binCount: overview.bins.count,
                        reason: reason,
                        source: cacheSource
                    )
                )
                DispatchQueue.main.async {
                    PerformanceDashboardWindowController.refreshIfVisible()
                }
            } catch {
                SoundtimeDiagnostics.shared.record(
                    category: .waveform,
                    severity: .warning,
                    name: "launch-detail-waveform-cache-failed",
                    message: "Could not prepare launch-detail waveform overview.",
                    fields: Self.launchDetailWaveformCacheFields(
                        fileInfo: fileInfo,
                        trackID: trackID,
                        trackName: trackName,
                        binCount: nil,
                        reason: reason,
                        source: "failed",
                        error: error.localizedDescription
                    )
                )
                DispatchQueue.main.async {
                    PerformanceDashboardWindowController.refreshIfVisible()
                }
            }
        }
    }

    private nonisolated static func launchDetailWaveformCacheFields(
        fileInfo: WAVFileInfo,
        trackID: UUID?,
        trackName: String?,
        binCount: Int?,
        reason: String,
        source: String,
        error: String? = nil
    ) -> [String: String] {
        var fields: [String: String] = [
            "file": fileInfo.url.lastPathComponent,
            "targetBins": "\(LaunchWaveformCache.firstRefinementBinCount)",
            "samplesPerBin": "\(LaunchWaveformCache.firstRefinementSamplesPerBin)",
            "reason": reason,
            "source": source,
        ]
        if let trackID {
            fields["trackID"] = trackID.uuidString
        }
        if let trackName {
            fields["trackName"] = trackName
        }
        if let binCount {
            fields["bins"] = "\(binCount)"
        }
        if let error {
            fields["error"] = error
        }
        return fields
    }

    private func cachedEditedWaveformOverview(
        at url: URL,
        fileInfo: WAVFileInfo,
        fileTimeline: AudioFileEditTimeline
    ) async -> EditedWaveformOverviewDiskCacheEntry? {
        let cache = waveformOverviewDiskCache
        return await Task.detached(priority: .userInitiated) {
            try? cache.loadEditedOverview(
                for: url,
                fileInfo: fileInfo,
                editTimeline: fileTimeline
            )
        }.value
    }

    private func cachedEditedDisplayOverviewForTrack(
        trackID: UUID,
        sourceURL: URL,
        fileInfo: WAVFileInfo
    ) async -> WaveformOverview? {
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            let fileTimeline = projectTracks[trackIndex].fileTimeline,
            fileTimeline.hasEdits
        else {
            return nil
        }

        let trackName = projectTracks[trackIndex].name
        let editRevision = projectTracks[trackIndex].editRevision
        let cachedOverview = await cachedEditedWaveformOverview(
            at: sourceURL,
            fileInfo: fileInfo,
            fileTimeline: fileTimeline
        )?.overview
        recordWaveformCacheDecision(
            name: cachedOverview == nil ? "edited-overview-cache-miss" : "edited-overview-cache-hit",
            message: cachedOverview == nil ?
                "No edited waveform overview disk cache was available for this track state." :
                "Loaded edited waveform overview from disk cache.",
            tier: "editedOverviewDiskCache",
            result: cachedOverview == nil ? "miss" : "hit",
            trackID: trackID,
            trackName: trackName,
            sourceURL: sourceURL,
            binCount: cachedOverview?.bins.count,
            editRevision: editRevision,
            reason: cachedOverview == nil ? "not-found-for-edit-state" : nil
        )
        return cachedOverview
    }

    private func cacheEditedWaveformOverview(
        _ overview: WaveformOverview,
        fileInfo: WAVFileInfo,
        fileTimeline: AudioFileEditTimeline
    ) {
        let cache = waveformOverviewDiskCache
        Task.detached(priority: .utility) {
            try? cache.saveEditedOverview(
                overview,
                fileInfo: fileInfo,
                editTimeline: fileTimeline
            )
        }
    }

    private func removeProjectTrack(_ trackID: UUID) {
        if recordingTrackID == trackID {
            stopRecording()
        }

        if
            let sessionID = projectTracks.first(where: { $0.id == trackID })?.importSessionID
        {
            Task {
                await AudioImportCoordinator.shared.cancel(sessionID: sessionID)
                await AudioImportCoordinator.shared.forget(sessionID: sessionID)
            }
        }
        let replacedTracks = projectTracks
        projectTracks.removeAll { $0.id == trackID }
        projectEditGraph.removeArrangement(for: trackID)
        pruneProjectEditGraphToCurrentTracks()
        if activeTrackID == trackID {
            activeTrackID = projectTracks.last?.id
        }
        if selectedTrackID == trackID {
            selectedTrackID = nil
        }
        selectedTrackIDs.remove(trackID)
        if trackSelectionAnchorID == trackID {
            trackSelectionAnchorID = nil
        }
        publishSelectedTracksToTimeline()
        syncActiveTrackFields()
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(preserveProgress: false)
        cleanupOwnedSourceFiles(replacedTracks: replacedTracks)
    }

    private func applyTrackPreview(
        trackID: UUID,
        previewResult: WAVPreviewImportResult,
        displayOverviewOverride: WaveformOverview? = nil
    ) {
        guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        projectTracks[trackIndex].name = previewResult.metadata.displayName
        let fileTimeline = projectTracks[trackIndex].fileTimeline
        projectTracks[trackIndex].durationHint = fileTimeline?.duration ?? previewResult.fileInfo.duration
        projectTracks[trackIndex].sourceWaveformOverview = previewResult.waveformOverview
        projectTracks[trackIndex].waveformOverview = displayOverviewOverride ?? fileTimeline?.waveformOverview(
            from: previewResult.waveformOverview
        ) ?? previewResult.waveformOverview
        projectTracks[trackIndex].zeroCrossingProbe = previewResult.zeroCrossingProbe
        activeTrackID = trackID
        window?.title = projectWindowTitle()
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming()
        syncActiveTrackFields()
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        updateStatus("preview ready - resolving waveform")
        scheduleLaunchSnapshotSaveIfNeeded(reason: "preview-ready", delay: 0.35)
    }

    private func applyDroppedWAVInitialPreview(
        trackID: UUID,
        previewResult: WAVPreviewImportResult
    ) {
        guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        let fileTimeline = projectTracks[trackIndex].fileTimeline
        projectTracks[trackIndex].name = previewResult.metadata.displayName
        projectTracks[trackIndex].durationHint = fileTimeline?.duration ?? previewResult.fileInfo.duration
        projectTracks[trackIndex].sourceWaveformOverview = previewResult.waveformOverview
        projectTracks[trackIndex].waveformOverview = fileTimeline?.waveformOverview(
            from: previewResult.waveformOverview
        ) ?? previewResult.waveformOverview
        window?.title = projectWindowTitle()
        refreshProjectTimelineDisplay(
            rebuildControls: false,
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: true,
            allowImmediateInteractiveWaveformPrewarm: false,
            updatesRendererImmediately: true
        )
        updateProjectDisplayTiming(sampleRateHint: previewResult.fileInfo.sampleRate)
        updateTimeReadout()
        updateStatus(WAVImportPreviewPolicy.readyStatus)
        scheduleLaunchSnapshotSaveIfNeeded(reason: "preview-ready", delay: 0.35)
    }

    private func applyTrackPreviewRefinement(
        trackID: UUID,
        fileInfo: WAVFileInfo,
        waveformOverview: WaveformOverview,
        displayOverviewOverride: WaveformOverview? = nil
    ) {
        guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        let currentTrack = projectTracks[trackIndex]
        let currentRenderOverview = waveformRenderPayload(for: currentTrack).overview
        let fileTimeline = currentTrack.fileTimeline
        let proposedSourceOverview = bestAvailableLaunchOverview(
            waveformOverview,
            currentTrack.sourceWaveformOverview
        )
        let proposedDisplayOverview = displayOverviewOverride ??
            fileTimeline.flatMap { fileTimeline in
                proposedSourceOverview.map { fileTimeline.waveformOverview(from: $0) }
            } ??
            proposedSourceOverview ??
            waveformOverview
        let proposedRenderOverview = fileTimeline.flatMap { fileTimeline in
            waveformRenderPayload(
                sourceOverview: proposedSourceOverview,
                displayOverview: proposedDisplayOverview,
                fileTimeline: fileTimeline
            ).overview
        } ?? proposedDisplayOverview
        if
            let currentRenderOverview,
            proposedRenderOverview.bins.count < currentRenderOverview.bins.count
        {
            recordWaveformCacheDecision(
                name: "waveform-preview-refinement-display-skipped",
                message: "Skipped waveform preview refinement because it would reduce visible waveform detail.",
                tier: "backgroundRebuild",
                result: "skipped",
                trackID: trackID,
                trackName: currentTrack.name,
                sourceURL: currentTrack.sourceURL,
                binCount: proposedRenderOverview.bins.count,
                targetBinCount: currentRenderOverview.bins.count,
                samplesPerBin: nil,
                editRevision: currentTrack.editRevision,
                reason: "lower-bin-count-than-current-render"
            )
            projectTracks[trackIndex].durationHint = fileTimeline?.duration ?? fileInfo.duration
            updateProjectDisplayTiming(sampleRateHint: fileInfo.sampleRate)
            updateTimeReadout()
            return
        }

        projectTracks[trackIndex].sourceWaveformOverview = proposedSourceOverview
        projectTracks[trackIndex].waveformOverview = proposedDisplayOverview
        projectTracks[trackIndex].durationHint = fileTimeline?.duration ?? fileInfo.duration
        refreshProjectTimelineDisplay(
            rebuildControls: false,
            animateWaveformTransition: shouldAnimateWaveformDataPromotion
        )
        updateProjectDisplayTiming(sampleRateHint: fileInfo.sampleRate)
        updateTimeReadout()
        scheduleLaunchSnapshotSaveIfNeeded(reason: "preview-refinement", delay: 0.5)
    }

    private func applyTrackDecodedWAV(
        trackID: UUID,
        decodedAudioBuffer: DecodedAudioBuffer,
        waveformOverview: WaveformOverview,
        zeroCrossingIndex: AudioZeroCrossingIndex
    ) {
        guard let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }

        let decodedFileInfo = (try? WAVAudioDecoder.inspect(url: projectTracks[trackIndex].sourceURL)) ??
            WAVFileInfo(
                url: projectTracks[trackIndex].sourceURL,
                formatTag: 1,
                channelCount: decodedAudioBuffer.channelCount,
                sampleRate: decodedAudioBuffer.sampleRate,
                blockAlign: max(decodedAudioBuffer.channelCount, 1) * 2,
                bitsPerSample: 16,
                dataRange: 44..<(44 + max(decodedAudioBuffer.frameCount, 0) * max(decodedAudioBuffer.channelCount, 1) * 2)
            )
        let existingFileTimeline = projectTracks[trackIndex].fileTimeline
        if let existingFileTimeline {
            let existingEditedOverview = projectTracks[trackIndex].editRevision > 0 ?
                projectTracks[trackIndex].waveformOverview :
                nil
            let editRevision = projectTracks[trackIndex].editRevision
            let editableSource = projectTracks[trackIndex].editableSource ??
                editableAudioSource(
                    originalURL: projectTracks[trackIndex].sourceURL,
                    editableURL: projectTracks[trackIndex].sourceURL,
                    formatOrigin: AudioAssetFormat.inferred(from: projectTracks[trackIndex].sourceURL),
                    fileInfo: decodedFileInfo,
                    ownsEditableFile: projectTracks[trackIndex].ownsSourceFile
                )

            projectTracks[trackIndex].decodedAudioBuffer = nil
            projectTracks[trackIndex].sourceWaveformOverview = waveformOverview
            projectTracks[trackIndex].waveformOverview = existingEditedOverview ?? waveformOverview
            projectTracks[trackIndex].zeroCrossingIndex = zeroCrossingIndex
            applyEditableTimelineMirror(
                trackIndex: trackIndex,
                source: editableSource,
                timeline: existingFileTimeline
            )
            activeTrackID = trackID
            syncActiveTrackFields()
            refreshProjectTimelineDisplay(
                rebuildControls: false,
                animateWaveformTransition: shouldAnimateWaveformDataPromotion
            )
            updateProjectDisplayTiming(sampleRateHint: decodedAudioBuffer.sampleRate)
            if !playbackController.hasSource {
                reloadPlaybackFromProjectTracks(preserveProgress: true)
            } else {
                updateProjectPlaybackTrackMix()
            }
            updateEffectCommandState()
            updateStatus("track ready")
            scheduleLaunchSnapshotSaveIfNeeded(reason: "track-ready", delay: 0.5)

            if existingFileTimeline.hasEdits {
                scheduleFileTimelineWaveformRefinement(
                    trackID: trackID,
                    fileTimeline: existingFileTimeline,
                    sourceOverview: waveformOverview,
                    editRevision: editRevision
                )
            }
            return
        }

        let fileTimeline = AudioFileEditTimeline(fileInfo: decodedFileInfo)
        let editableSource = editableAudioSource(
            originalURL: projectTracks[trackIndex].sourceURL,
            editableURL: projectTracks[trackIndex].sourceURL,
            formatOrigin: AudioAssetFormat.inferred(from: projectTracks[trackIndex].sourceURL),
            fileInfo: decodedFileInfo,
            ownsEditableFile: projectTracks[trackIndex].ownsSourceFile
        )
        projectTracks[trackIndex].decodedAudioBuffer = nil
        projectTracks[trackIndex].sourceWaveformOverview = waveformOverview
        projectTracks[trackIndex].waveformOverview = waveformOverview
        projectTracks[trackIndex].zeroCrossingIndex = zeroCrossingIndex
        applyEditableTimelineMirror(
            trackIndex: trackIndex,
            source: editableSource,
            timeline: fileTimeline
        )
        activeTrackID = trackID
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(
            rebuildControls: false,
            animateWaveformTransition: shouldAnimateWaveformDataPromotion
        )
        updateProjectDisplayTiming(sampleRateHint: decodedAudioBuffer.sampleRate)
        if !playbackController.hasSource {
            reloadPlaybackFromProjectTracks(preserveProgress: true)
        } else {
            updateProjectPlaybackTrackMix()
        }
        updateEffectCommandState()
        updateStatus("track ready")
        scheduleLaunchSnapshotSaveIfNeeded(reason: "track-ready", delay: 0.5)
    }

    private func syncActiveTrackFields() {
        guard let activeTrack = activeProjectTrack else {
            decodedAudioBuffer = nil
            audioTimeline = nil
            selectedAudioFile = nil
            return
        }

        decodedAudioBuffer = activeTrack.decodedAudioBuffer
        audioTimeline = activeTrack.audioTimeline
        let duration = trackDuration(for: activeTrack)
        if duration > 0 {
            selectedAudioFile = AudioFileMetadata(
                url: activeTrack.sourceURL,
                displayName: activeTrack.name,
                duration: duration,
                fileSize: nil
            )
        } else {
            selectedAudioFile = nil
        }
    }

    private var activeProjectTrack: ProjectTrack? {
        guard let activeTrackID else {
            return projectTracks.last
        }

        return projectTracks.first { $0.id == activeTrackID } ?? projectTracks.last
    }

    private func updateProjectDisplayTiming(sampleRateHint: Double? = nil) {
        let projectDuration = projectTracks.reduce(TimeInterval(0)) { result, track in
            max(result, trackDuration(for: track))
        }
        let sampleRate = sampleRateHint ??
            projectTracks.compactMap { $0.decodedAudioBuffer?.sampleRate }.first ??
            displayedSampleRate

        if projectDuration > 0, sampleRate > 0 {
            displayedSampleRate = sampleRate
            displayedFrameCount = Int((projectDuration * sampleRate).rounded(.up))
        } else {
            displayedSampleRate = 0
            displayedFrameCount = 0
        }

        updateLoadedProjectSummary()
        updateTimeReadout()
    }

    private func updateLoadedProjectSummary() {
        if projectTracks.isEmpty {
            loadedAudioSummary = nil
        } else {
            let trackText = projectTracks.count == 1 ? "1 track" : "\(projectTracks.count) tracks"
            if let currentProjectURL {
                loadedAudioSummary = "\(currentProjectURL.deletingPathExtension().lastPathComponent) - \(trackText)"
            } else {
                loadedAudioSummary = "Untitled Project - \(trackText)"
            }
        }
    }

    private func projectWindowTitle() -> String {
        if let currentProjectURL {
            return "Soundtime - \(currentProjectURL.deletingPathExtension().lastPathComponent)"
        }

        if projectTracks.isEmpty {
            return "Soundtime"
        }

        return "Soundtime - Untitled Project"
    }

    private func reloadPlaybackFromProjectTracks(
        preserveProgress: Bool,
        targetProgress: Float? = nil,
        resumeIfPlaying: Bool? = nil,
        playbackTracksOverride: [ProjectPlaybackTrack]? = nil,
        publishesVisualState: Bool = true,
        preservesRunningTransportContinuity: Bool = false
    ) {
        scheduledPlaybackReloadWorkItem?.cancel()
        scheduledPlaybackReloadWorkItem = nil

        let previousSnapshot = playbackController.snapshot()
        let shouldResume = resumeIfPlaying ?? (preserveProgress && previousSnapshot.isPlaying)
        let playbackTracks = playbackTracksOverride ?? projectPlaybackTracks()
        publishedProjectPlaybackTracks = playbackTracks

        guard !playbackTracks.isEmpty else {
            playbackController.clear()
            currentPlayheadFrame = 0
            if publishesVisualState {
                displayPlaybackVisuals(progress: 0, isPlaying: false, synchronizesRenderer: false)
                updateTimeReadout()
                updateTransportControlState(isPlaying: false)
            }
            return
        }

        do {
            if playbackController.hasSource {
                try playbackController.updateProjectTracks(playbackTracks)
            } else {
                try playbackController.loadProjectTracks(playbackTracks)
            }
            if preserveProgress || targetProgress != nil {
                let keptRunningTransport = preservesRunningTransportContinuity &&
                    previousSnapshot.isPlaying &&
                    playbackController.isPlaying
                if !keptRunningTransport {
                    let updatedSnapshot = playbackController.snapshot()
                    let restoredProgress = targetProgress ??
                        updatedSnapshot.progressPreservingProjectTime(
                            from: previousSnapshot
                        )
                    try playbackController.seekExactly(toProgress: restoredProgress)
                }
                if shouldResume && !playbackController.isPlaying {
                    try playbackController.play()
                }
            } else if playbackController.hasSource {
                playbackController.pause()
                try playbackController.seek(toProgress: 0)
            }

            if publishesVisualState {
                let snapshot = playbackController.snapshot()
                displayPlaybackVisuals(
                    progress: snapshot.progress,
                    isPlaying: snapshot.isPlaying,
                    syncPlayhead: true,
                    anchorTimestamp: snapshot.hostTimestamp,
                    synchronizesRenderer: snapshot.isPlaying
                )
            }
            lastPlaybackReloadErrorDescription = nil
        } catch {
            lastPlaybackReloadErrorDescription = error.localizedDescription
            SoundtimeDiagnostics.shared.record(
                category: .audio,
                severity: .severe,
                name: "project-playback-reload-failed",
                message: "The project playback graph could not be published.",
                fields: [
                    "error": error.localizedDescription,
                    "trackCount": "\(playbackTracks.count)",
                    "usedSnapshotOverride": "\(playbackTracksOverride != nil)",
                    "preserveProgress": "\(preserveProgress)",
                ]
            )
            stopPlaybackTimer()
            if publishesVisualState {
                displayPlaybackVisuals(progress: 0, isPlaying: false, synchronizesRenderer: false)
            }
            updateStatus("project playback failed: \(error.localizedDescription)")
        }
        if publishesVisualState {
            updateTimeReadout()
            updateTransportControlState(isPlaying: playbackController.isPlaying)
        }
    }

    private func schedulePlaybackReloadFromProjectTracks(
        preserveProgress: Bool,
        targetProgress: Float? = nil,
        resumeIfPlaying: Bool? = nil,
        delay: TimeInterval
    ) {
        scheduledPlaybackReloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.scheduledPlaybackReloadWorkItem = nil
                self.reloadPlaybackFromProjectTracks(
                    preserveProgress: preserveProgress,
                    targetProgress: targetProgress,
                    resumeIfPlaying: resumeIfPlaying
                )
            }
        }
        scheduledPlaybackReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func flushScheduledPlaybackReloadIfNeeded() {
        guard let workItem = scheduledPlaybackReloadWorkItem else {
            return
        }

        scheduledPlaybackReloadWorkItem = nil
        workItem.perform()
        workItem.cancel()
    }

    private func updateProjectPlaybackTrackMix() {
        playbackController.updateProjectTrackMix(projectPlaybackTrackMixes())
        lastProjectTrackMixPublishTimestamp = CACurrentMediaTime()
    }

    private func scheduleProjectTrackMixUpdate() {
        pendingProjectTrackMixUpdate = true
        guard scheduledProjectTrackMixWorkItem == nil else {
            return
        }

        let elapsed = CACurrentMediaTime() - lastProjectTrackMixPublishTimestamp
        let delay = max(trackMixCoalescingInterval - elapsed, 0)
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.flushScheduledProjectTrackMixUpdate()
            }
        }
        scheduledProjectTrackMixWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func flushScheduledProjectTrackMixUpdate() {
        scheduledProjectTrackMixWorkItem = nil
        guard pendingProjectTrackMixUpdate else {
            return
        }

        pendingProjectTrackMixUpdate = false
        updateProjectPlaybackTrackMix()
    }

    private func publishProjectTrackMixImmediately() {
        scheduledProjectTrackMixWorkItem?.cancel()
        scheduledProjectTrackMixWorkItem = nil
        pendingProjectTrackMixUpdate = false
        updateProjectPlaybackTrackMix()
    }

    private func projectPlaybackTracks() -> [ProjectPlaybackTrack] {
        ProjectPlaybackProjection.tracks(
            from: projectTracks,
            isDirectFilePlayable: { [unowned self] url in
                self.decodableWAVFileInfo(for: url) != nil
            }
        )
    }

    private func projectPlaybackTrack(
        for track: ProjectTrack
    ) -> ProjectPlaybackTrack? {
        ProjectPlaybackProjection.track(
            from: track,
            isDirectFilePlayable: { [unowned self] url in
                self.decodableWAVFileInfo(for: url) != nil
            }
        )
    }

    private func projectPlaybackTrackMixes() -> [ProjectPlaybackTrackMix] {
        ProjectPlaybackProjection.mixes(from: projectTracks)
    }

    private func projectMixTrackSnapshots() -> [ProjectMixTrackSnapshot] {
        audibleProjectTracks.compactMap(projectMixTrackSnapshot)
    }

    private func projectStemTrackSnapshots() -> [ProjectMixTrackSnapshot] {
        projectTracks.compactMap(projectMixTrackSnapshot)
    }

    private func projectMixTrackSnapshot(for track: ProjectTrack) -> ProjectMixTrackSnapshot? {
        let source: ProjectMixTrackSource
        if
            let fileTimeline = track.fileTimeline,
            let fileInfo = decodableWAVFileInfo(for: track.sourceURL),
            fileTimeline.isCompatible(with: fileInfo)
        {
            source = .fileTimeline(track.sourceURL, fileTimeline)
        } else if track.editRevision == 0, decodableWAVFileInfo(for: track.sourceURL) != nil {
            source = .file(track.sourceURL)
        } else if let audioTimeline = track.audioTimeline {
            source = .timeline(audioTimeline)
        } else if let decodedAudioBuffer = track.decodedAudioBuffer {
            source = .decoded(decodedAudioBuffer)
        } else {
            return nil
        }

        return ProjectMixTrackSnapshot(
            id: track.id,
            name: track.name,
            volume: track.volume,
            source: source,
            zeroCrossingIndex: track.zeroCrossingIndex
        )
    }

    private nonisolated static func decodedMixBuffer(
        for track: ProjectMixTrackSnapshot
    ) throws -> DecodedAudioBuffer {
        switch track.source {
        case let .decoded(buffer):
            return buffer
        case let .timeline(timeline):
            return timeline.render()
        case let .file(url):
            return try WAVAudioDecoder.decode(url: url)
        case let .fileTimeline(url, fileTimeline):
            let sourceBuffer = try WAVAudioDecoder.decode(url: url)
            return fileTimeline.audioTimeline(sourceBuffer: sourceBuffer).render()
        }
    }

    private nonisolated static func makeProjectMix(
        from decodedTracks: [ProjectMixTrackSnapshot],
        outputURL: URL
    ) throws -> ProjectMixResult? {
        guard let firstTrack = decodedTracks.first else {
            return nil
        }

        let firstBuffer = try decodedMixBuffer(for: firstTrack)
        if
            decodedTracks.count == 1,
            abs(firstTrack.volume - 1) <= Float.ulpOfOne
        {
            let zeroCrossingIndex: AudioZeroCrossingIndex
            if
                let existingZeroCrossingIndex = firstTrack.zeroCrossingIndex,
                existingZeroCrossingIndex.frameCount == firstBuffer.frameCount
            {
                zeroCrossingIndex = existingZeroCrossingIndex
            } else {
                zeroCrossingIndex = AudioZeroCrossingIndex.build(from: firstBuffer)
            }

            return ProjectMixResult(
                buffer: firstBuffer,
                zeroCrossingIndex: zeroCrossingIndex,
                trackCount: decodedTracks.count
            )
        }

        let sampleRate = firstBuffer.sampleRate
        var renderedTracks: [(volume: Float, buffer: DecodedAudioBuffer)] = [
            (volume: firstTrack.volume, buffer: firstBuffer),
        ]
        renderedTracks.reserveCapacity(decodedTracks.count)
        for track in decodedTracks.dropFirst() {
            renderedTracks.append((volume: track.volume, buffer: try decodedMixBuffer(for: track)))
        }

        let channelCount = max(renderedTracks.map(\.buffer.channelCount).max() ?? 2, 2)
        let frameCount = renderedTracks.reduce(0) { result, item in
            max(result, item.buffer.frameCount)
        }
        guard frameCount > 0 else {
            return nil
        }

        var samplesByChannel = (0..<channelCount).map { _ in
            [Float](repeating: 0, count: frameCount)
        }

        for track in renderedTracks {
            let buffer = track.buffer
            let gain = track.volume * track.volume
            for outputChannel in 0..<channelCount {
                let sourceChannel = buffer.channelCount == 1 ? 0 : min(outputChannel, buffer.channelCount - 1)
                let sourceSamples = buffer.samplesByChannel[sourceChannel]
                for frameIndex in 0..<buffer.frameCount {
                    let mixedSample =
                        samplesByChannel[outputChannel][frameIndex] + sourceSamples[frameIndex] * gain
                    samplesByChannel[outputChannel][frameIndex] = min(max(mixedSample, -1), 1)
                }
            }
        }

        let buffer = DecodedAudioBuffer(
            url: outputURL,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            samplesByChannel: samplesByChannel
        )
        return ProjectMixResult(
            buffer: buffer,
            zeroCrossingIndex: AudioZeroCrossingIndex.build(from: buffer),
            trackCount: decodedTracks.count
        )
    }

    private var audibleProjectTracks: [ProjectTrack] {
        let anySoloedTrack = projectTracks.contains { $0.isSoloed }
        return projectTracks.filter { track in
            isProjectTrackAudible(track, anySoloedTrack: anySoloedTrack) && track.volume > 0
        }
    }

    private func isProjectTrackAudible(
        _ track: ProjectTrack,
        anySoloedTrack: Bool
    ) -> Bool {
        anySoloedTrack ? track.isSoloed : !track.isMuted
    }

    private func activeProjectTrackIndex() -> Int? {
        if let selectedTrackID = selectedTimelineRange?.trackID,
           let selectedTrackIndex = projectTracks.firstIndex(where: { $0.id == selectedTrackID })
        {
            return selectedTrackIndex
        }

        if let selectedTrackID,
           let selectedTrackIndex = projectTracks.firstIndex(where: { $0.id == selectedTrackID })
        {
            return selectedTrackIndex
        }

        if let activeTrackID,
           let trackIndex = projectTracks.firstIndex(where: { $0.id == activeTrackID })
        {
            return trackIndex
        }

        guard !projectTracks.isEmpty else {
            return nil
        }

        return projectTracks.count - 1
    }

    private func trackDuration(for track: ProjectTrack) -> TimeInterval {
        track.audioTimeline?.duration ??
            track.fileTimeline?.duration ??
            track.waveformOverview?.duration ??
            track.decodedAudioBuffer?.duration ??
            track.durationHint ??
            0
    }

    private var projectSelectionDuration: TimeInterval {
        let presentationDuration = timelineSurface.currentTimelineDuration
        if presentationDuration.isFinite, presentationDuration > 0 {
            return presentationDuration
        }

        let canonicalDuration = canonicalProjectTimelineDuration
        if canonicalDuration.isFinite, canonicalDuration > 0 {
            return canonicalDuration
        }

        return max(displayedDuration, 0)
    }

    private func playbackProgress(forTimelineTime timelineTime: TimeInterval) -> Float {
        guard displayedDuration > 0 else {
            return 0
        }

        let clampedTime = min(max(timelineTime, 0), displayedDuration)
        return min(max(Float(clampedTime / displayedDuration), 0), 1)
    }

    private func snapPlayheadVisuals(
        toTimelineTime timelineTime: TimeInterval,
        isPlaying: Bool,
        synchronizesRenderer: Bool
    ) {
        let progress = playbackProgress(forTimelineTime: timelineTime)
        currentPlayheadFrame = Int(
            (Double(progress) * Double(max(displayedFrameCount, 0))).rounded(.down)
        )
        previousLoopPlaybackProgress = nil
        displayPlaybackVisuals(
            progress: progress,
            isPlaying: isPlaying,
            syncPlayhead: true,
            anchorTimestamp: CACurrentMediaTime(),
            synchronizesRenderer: synchronizesRenderer
        )
        updateTimeReadout()
    }

    private func fullTrackDisplaySelection(for trackID: UUID) -> TimelineSelection {
        guard
            let track = projectTracks.first(where: { $0.id == trackID })
        else {
            return TimelineSelection(startProgress: 0, endProgress: 1, trackID: trackID)
        }

        let projectDuration = projectSelectionDuration
        let trackDuration = trackDuration(for: track)
        let endProgress = projectDuration > 0 && trackDuration > 0 ?
            min(max(trackDuration / projectDuration, 0), 1) :
            1
        return TimelineSelection(
            startProgress: 0,
            endProgress: endProgress,
            trackID: trackID
        )
    }

    private func fullTrackEditSelection(for trackID: UUID) -> TimelineSelection {
        TimelineSelection(startProgress: 0, endProgress: 1, trackID: trackID)
    }

    private func isFullTrackSelection(_ selection: TimelineSelection?, trackID: UUID) -> Bool {
        guard let selection, selection.trackID == trackID else {
            return false
        }

        let expectedSelection = fullTrackDisplaySelection(for: trackID)
        let epsilon = 0.000_001
        if
            abs(selection.startProgress - expectedSelection.startProgress) <= epsilon,
            abs(selection.endProgress - expectedSelection.endProgress) <= epsilon
        {
            return true
        }

        return selection.startProgress <= epsilon && selection.endProgress >= 1 - epsilon
    }

    private func editSelection(
        from displaySelection: TimelineSelection,
        trackIndex: Int
    ) -> TimelineSelection? {
        guard projectTracks.indices.contains(trackIndex) else {
            return nil
        }

        let track = projectTracks[trackIndex]
        let projectDuration = projectSelectionDuration
        let trackDuration = trackDuration(for: track)
        guard projectDuration > 0, trackDuration > 0 else {
            return nil
        }

        let startTime = displaySelection.startProgress * projectDuration
        let endTime = displaySelection.endProgress * projectDuration
        let clampedStartTime = min(max(startTime, 0), trackDuration)
        let clampedEndTime = min(max(endTime, 0), trackDuration)
        let selection = TimelineSelection(
            startProgress: clampedStartTime / trackDuration,
            endProgress: clampedEndTime / trackDuration,
            trackID: track.id
        )
        return selection.durationProgress > 0 ? selection : nil
    }

    private func editInsertionSelection(
        forPlaybackProgress progress: Float,
        trackIndex: Int
    ) -> TimelineSelection {
        guard projectTracks.indices.contains(trackIndex) else {
            let clampedProgress = Double(min(max(progress, 0), 1))
            return TimelineSelection(startProgress: clampedProgress, endProgress: clampedProgress)
        }

        let track = projectTracks[trackIndex]
        let projectDuration = projectSelectionDuration
        let trackDuration = trackDuration(for: track)
        let insertionProgress: Double
        if projectDuration > 0, trackDuration > 0 {
            let insertionTime = Double(min(max(progress, 0), 1)) * projectDuration
            insertionProgress = min(max(insertionTime / trackDuration, 0), 1)
        } else {
            insertionProgress = Double(min(max(progress, 0), 1))
        }

        return TimelineSelection(
            startProgress: insertionProgress,
            endProgress: insertionProgress,
            trackID: track.id
        )
    }

    private func displaySelectionForInsertedAudio(
        trackID: UUID,
        startTime: TimeInterval,
        insertedDuration: TimeInterval,
        projectDuration: TimeInterval
    ) -> TimelineSelection {
        let timelineDuration = max(projectDuration, startTime + insertedDuration, insertedDuration, 0.000_001)
        let startProgress = min(max(startTime / timelineDuration, 0), 1)
        let endProgress = min(max((startTime + insertedDuration) / timelineDuration, startProgress), 1)
        return TimelineSelection(
            startProgress: startProgress,
            endProgress: endProgress,
            trackID: trackID
        )
    }

    private func beginPasteVisualEffect(
        trackID: UUID,
        startTime: TimeInterval,
        insertedDuration: TimeInterval,
        projectDurationBeforePaste: TimeInterval,
        waveformOverview: WaveformOverview?
    ) -> (generation: Int, visualSelection: TimelineSelection) {
        let visualSelection = displaySelectionForInsertedAudio(
            trackID: trackID,
            startTime: startTime,
            insertedDuration: insertedDuration,
            projectDuration: projectDurationBeforePaste
        )
        let immediatePlaybackProgress = visualSelection.startProgressFloat
        currentPlayheadFrame = Int(
            (Double(immediatePlaybackProgress) * Double(max(displayedFrameCount, 0))).rounded(.down)
        )
        previousLoopPlaybackProgress = nil
        displayPlaybackVisuals(
            progress: immediatePlaybackProgress,
            isPlaying: playbackController.isPlaying,
            syncPlayhead: true,
            anchorTimestamp: CACurrentMediaTime(),
            synchronizesRenderer: true
        )

        let pasteGeneration = beginDeleteAnimationCriticalSection()
        // Let the paste-effect shader draw the growing selected region. Publishing
        // the normal full-width selection here makes paste look like it snapped
        // into place before the animation has a chance to run. Keep the preview
        // out of canonical workspace state as well: the edit transaction must
        // capture the real pre-paste selection for undo.
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        timelineSurface.triggerPasteEffect(selection: visualSelection, waveformOverview: waveformOverview)
        return (pasteGeneration, visualSelection)
    }

    private func finishPasteVisualHandoff(
        generation: Int,
        finalSelection: TimelineSelection,
        pasteStartTime: TimeInterval,
        reloadPlaybackSource: Bool,
        resumeIfPlaying wasPlayingAtPaste: Bool
    ) {
        guard deleteAnimationGeneration == generation else {
            return
        }

        postDeleteRefreshWorkItem?.cancel()
        postDeleteRefreshWorkItem = nil
        timelineSurface.clearDeletionEffects()
        selectedTimelineRange = finalSelection
        refreshProjectTimelineDisplay(
            rebuildControls: false,
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false
        )
        timelineSurface.displaySelection(finalSelection)
        if reloadPlaybackSource {
            let nextDuration = max(projectSelectionDuration, pasteStartTime, 0.000_001)
            let targetProgress = Float(min(max(pasteStartTime / nextDuration, 0), 1))
            reloadPlaybackFromProjectTracks(
                preserveProgress: true,
                targetProgress: targetProgress,
                resumeIfPlaying: wasPlayingAtPaste
            )
        } else {
            snapPlayheadVisuals(
                toTimelineTime: pasteStartTime,
                isPlaying: playbackController.isPlaying,
                synchronizesRenderer: true
            )
        }
        updateEffectCommandState()
    }

    private func trackIndex(for selection: TimelineSelection) -> Int? {
        if let trackID = selection.trackID {
            return projectTracks.firstIndex(where: { $0.id == trackID })
        }

        if let activeTrackID,
           let activeIndex = projectTracks.firstIndex(where: { $0.id == activeTrackID })
        {
            return activeIndex
        }

        return projectTracks.count == 1 ? 0 : nil
    }

    private func currentEditableSelectionTarget() -> EditableSelectionTarget? {
        if
            let selection = selectedTimelineRange,
            selection.durationProgress > 0,
            let trackIndex = trackIndex(for: selection),
            projectTracks.indices.contains(trackIndex),
            let editSelection = editSelection(from: selection, trackIndex: trackIndex)
        {
            let trackID = projectTracks[trackIndex].id
            let displaySelection = TimelineSelection(
                startProgress: selection.startProgress,
                endProgress: selection.endProgress,
                trackID: trackID
            )
            return EditableSelectionTarget(
                trackIndex: trackIndex,
                displaySelection: displaySelection,
                editSelection: editSelection
            )
        }

        if
            let selectedTrackID,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == selectedTrackID })
        {
            return EditableSelectionTarget(
                trackIndex: trackIndex,
                displaySelection: fullTrackDisplaySelection(for: selectedTrackID),
                editSelection: fullTrackEditSelection(for: selectedTrackID)
            )
        }

        return nil
    }

    private func editableClipAtPlayheadTarget() -> EditableSelectionTarget? {
        guard
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            return nil
        }

        let track = projectTracks[trackIndex]
        let projectDuration = projectSelectionDuration
        let trackDuration = trackDuration(for: track)
        guard projectDuration > 0, trackDuration > 0 else {
            return nil
        }

        let playheadProgress = playbackControllerStorage?.snapshot().progress ?? visualPlayheadProgress
        let playheadTime = Double(playheadProgress) * projectDuration
        let localProgress = min(max(playheadTime / trackDuration, 0), 1)
        let clipRanges = timelineClipRanges(for: track)
        guard let clipRange = clipRanges.first(where: {
            localProgress >= $0.startProgress && localProgress <= $0.endProgress
        }) ?? clipRanges.first else {
            return nil
        }

        let trackDurationProgress = trackDuration / projectDuration
        let displaySelection = TimelineSelection(
            startProgress: clipRange.startProgress * trackDurationProgress,
            endProgress: clipRange.endProgress * trackDurationProgress,
            trackID: track.id
        )
        let editSelection = TimelineSelection(
            startProgress: clipRange.startProgress,
            endProgress: clipRange.endProgress,
            trackID: track.id
        )
        guard editSelection.durationProgress > 0 else {
            return nil
        }

        return EditableSelectionTarget(
            trackIndex: trackIndex,
            displaySelection: displaySelection,
            editSelection: editSelection
        )
    }

    private func editableClipSlipTarget() -> EditableSelectionTarget? {
        guard
            let baseTarget = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget(),
            projectTracks.indices.contains(baseTarget.trackIndex)
        else {
            return nil
        }

        let track = projectTracks[baseTarget.trackIndex]
        let midpointProgress = (
            baseTarget.editSelection.startProgress +
                baseTarget.editSelection.endProgress
        ) * 0.5
        guard
            let clipRange = timelineClipRanges(for: track).first(where: {
                midpointProgress >= $0.startProgress && midpointProgress <= $0.endProgress
            })
        else {
            return baseTarget
        }

        let projectDuration = projectSelectionDuration
        let trackDuration = trackDuration(for: track)
        let trackDurationProgress = projectDuration > 0 ? trackDuration / projectDuration : 1
        let displaySelection = TimelineSelection(
            startProgress: clipRange.startProgress * trackDurationProgress,
            endProgress: clipRange.endProgress * trackDurationProgress,
            trackID: track.id
        )
        let editSelection = TimelineSelection(
            startProgress: clipRange.startProgress,
            endProgress: clipRange.endProgress,
            trackID: track.id
        )
        return EditableSelectionTarget(
            trackIndex: baseTarget.trackIndex,
            displaySelection: displaySelection,
            editSelection: editSelection
        )
    }

    private func materializeEditedTimeline(
        trackID: UUID,
        timeline: AudioEditTimeline,
        editRevision: Int,
        status: String,
        preservePlaybackProgress: Bool = false,
        startDelay: TimeInterval = 0,
        animateWaveformTransition: Bool = true
    ) {
        editMaterializationTasks.replaceTask(for: trackID) { requestID in
            Task { [
                weak self,
                trackID,
                timeline,
                editRevision,
                status,
                preservePlaybackProgress,
                startDelay,
                animateWaveformTransition,
                requestID
            ] in
                if startDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
                }

                guard !Task.isCancelled else {
                    self?.clearEditMaterializationTask(trackID: trackID, requestID: requestID)
                    return
                }

                let materialized = await Task.detached(priority: .utility) {
                    Self.materializeTimeline(timeline)
                }.value

                guard let self else {
                    return
                }

                guard
                    !Task.isCancelled,
                    self.editMaterializationTasks.isCurrent(trackID, generation: requestID)
                else {
                    self.clearEditMaterializationTask(trackID: trackID, requestID: requestID)
                    return
                }

                self.clearEditMaterializationTask(trackID: trackID, requestID: requestID)
                self.applyMaterializedTrackEdit(
                    trackID: trackID,
                    editRevision: editRevision,
                    materialized: materialized,
                    status: status,
                    preservePlaybackProgress: preservePlaybackProgress,
                    animateWaveformTransition: animateWaveformTransition
                )
            }
        }
    }

    private func preparePortablePaste(
        clipboard: AudioClipboard,
        command: EditCommand,
        destinationTrack: ProjectTrack
    ) {
        guard
            command.kind == .paste,
            command.clipboardID == clipboard.id,
            let clipboardBuffer = clipboard.buffer
        else {
            updateStatus("paste failed: copied audio is not ready")
            return
        }

        let plan: EditPlan
        do {
            plan = try EditTransactionPlanner.plan(
                command: command,
                currentRevision: projectEditRevision(),
                tracks: editTrackDescriptors(for: command)
            )
        } catch {
            updateStatus("paste failed: \(error.localizedDescription)")
            return
        }

        guard
            let trackEdit = plan.trackEdits.first,
            case let .insert(insertionFrame) = trackEdit.mutation
        else {
            updateStatus("paste failed: invalid insertion plan")
            return
        }

        let outputURL = recordingFileURL(trackName: "\(destinationTrack.name)-Paste")
        let renderSnapshot: AudioExportSnapshot
        do {
            renderSnapshot = try portablePasteRenderSnapshot(
                clipboardBuffer: clipboardBuffer,
                destinationTrack: destinationTrack,
                insertionFrame: insertionFrame,
                outputURL: outputURL
            )
        } catch {
            updateStatus("paste failed: \(error.localizedDescription)")
            return
        }

        let trackID = destinationTrack.id
        editMaterializationTasks.cancel(trackID)
        let previousSelection = selectedTimelineRange
        let destinationFrameCount =
            destinationTrack.fileTimeline?.frameCount ??
            destinationTrack.audioTimeline?.frameCount ??
            destinationTrack.decodedAudioBuffer?.frameCount ??
            0
        let insertionProgress = destinationFrameCount > 0
            ? Double(insertionFrame) / Double(destinationFrameCount)
            : 0
        let optimisticOverview = optimisticWaveformOverview(
            destinationTrack.waveformOverview ?? destinationTrack.sourceWaveformOverview,
            replacing: TimelineSelection(
                startProgress: insertionProgress,
                endProgress: insertionProgress,
                trackID: trackID
            ),
            with: clipboard.waveformOverview,
            targetDuration: renderSnapshot.duration,
            preservesResolution: true
        )
        let pasteVisual = beginPasteVisualEffect(
            trackID: trackID,
            startTime: command.insertionTime?.seconds ?? 0,
            insertedDuration: clipboardBuffer.duration,
            projectDurationBeforePaste: projectSelectionDuration,
            waveformOverview: clipboard.waveformOverview
        )
        updateStatus("preparing pasted audio")

        let job = PortablePastePreparationJob()
        // Beginning the visual enters the shared edit critical section and
        // cancels stale preparation. Register this request only after that reset.
        let requestID = editMaterializationTasks.replaceExternal(
            for: trackID,
            cancel: {
                job.cancel()
            }
        )
        let lease = AudioExportLeaseManager.shared.acquire(
            urls: renderSnapshot.leasedURLs,
            jobID: requestID
        )
        portablePastePreparationQueue.async { [
            clipboard,
            clipboardBuffer,
            command,
            destinationTrack,
            job,
            lease,
            optimisticOverview,
            plan,
            renderSnapshot,
            requestID,
            trackID,
            previousSelection,
            pasteVisual,
        ] in
            let preparationStartedAt = CACurrentMediaTime()
            let result: PortablePastePreparationResult
            do {
                try job.checkCancellation()
                let asset = try Self.renderPortablePasteAsset(
                    snapshot: renderSnapshot,
                    cancellationCheck: job.checkCancellation
                )
                try job.checkCancellation()
                result = .success(asset)
            } catch is CancellationError {
                try? AudioExportLeaseManager.shared.deleteOrDefer(
                    renderSnapshot.request.destinationURL
                )
                result = .canceled
            } catch {
                result = .failure(error.localizedDescription)
            }
            AudioExportLeaseManager.shared.release(lease)
            SoundtimeDiagnostics.shared.record(
                category: .edit,
                severity: .info,
                name: "portable-paste-preparation-complete",
                message: "Cross-source paste media preparation finished.",
                fields: [
                    "elapsedMs": String(
                        format: "%.3f",
                        (CACurrentMediaTime() - preparationStartedAt) * 1_000
                    ),
                    "trackID": trackID.uuidString,
                ]
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    if case let .success(asset) = result {
                        try? AudioExportLeaseManager.shared.deleteOrDefer(asset.url)
                    }
                    return
                }
                guard
                    self.editMaterializationTasks.isCurrent(
                        trackID,
                        generation: requestID
                    )
                else {
                    if case let .success(asset) = result {
                        try? AudioExportLeaseManager.shared.deleteOrDefer(asset.url)
                    }
                    return
                }
                self.clearPortablePastePreparationJob(
                    trackID: trackID,
                    requestID: requestID
                )

                guard
                    self.projectEditRevision() == command.baseRevision,
                    self.audioClipboard?.id == clipboard.id,
                    self.projectTracks.contains(where: { $0.id == trackID })
                else {
                    if case let .success(asset) = result {
                        try? AudioExportLeaseManager.shared.deleteOrDefer(asset.url)
                    }
                    self.rollbackPortablePasteVisual(
                        generation: pasteVisual.generation,
                        previousSelection: previousSelection
                    )
                    self.updateStatus("paste canceled because the project changed")
                    return
                }

                switch result {
                case let .success(asset):
                let fileTimeline = AudioFileEditTimeline(fileInfo: asset.fileInfo)
                let editableSource = self.editableAudioSource(
                    originalURL: asset.url,
                    editableURL: asset.url,
                    formatOrigin: .wav,
                    fileInfo: asset.fileInfo,
                    ownsEditableFile: true
                )
                var nextTrack = destinationTrack
                nextTrack.sourceURL = asset.url
                nextTrack.sourceWaveformOverview = optimisticOverview
                nextTrack.waveformOverview = optimisticOverview
                nextTrack.decodedAudioBuffer = nil
                nextTrack.zeroCrossingIndex = nil
                nextTrack.zeroCrossingProbe = try? WAVAudioDecoder.makeZeroCrossingProbe(
                    url: asset.url,
                    fileInfo: asset.fileInfo
                )
                nextTrack.audioTimeline = nil
                nextTrack.fileTimeline = fileTimeline
                nextTrack.editableSource = editableSource
                nextTrack.ownsSourceFile = true
                nextTrack.durationHint = fileTimeline.duration
                nextTrack.importID = UUID()
                nextTrack.importedAssetID = nil
                nextTrack.importSessionID = nil
                nextTrack.importStage = nil
                nextTrack.importProgress = 1
                nextTrack.importFingerprint = nil
                nextTrack.importPreviewIsProgressive = false
                nextTrack.editRevision += 1
                nextTrack.transcript = Self.transcript(
                    destinationTrack.transcript,
                    insertingDuration: clipboardBuffer.duration,
                    at: command.insertionTime?.seconds ?? 0,
                    sourceRevision: nextTrack.editRevision,
                    sourceDuration: fileTimeline.duration
                )

                var nextGraph = self.currentEditGraph()
                nextGraph.upsert(
                    source: editableSource,
                    trackID: trackID,
                    timeline: fileTimeline
                )
                let insertedRange = ProjectEditRange(
                    start: command.insertionTime ?? .zero,
                    end: (command.insertionTime ?? .zero) +
                        ProjectTime(seconds: clipboardBuffer.duration)
                )
                let nextProjectDuration = max(
                    self.projectSelectionDuration,
                    fileTimeline.duration
                )
                let finalSelection = insertedRange.map {
                    self.displaySelection(
                        for: $0,
                        trackID: trackID,
                        projectDuration: nextProjectDuration
                    )
                } ?? pasteVisual.visualSelection
                let preparedCommit = PreparedProjectEditCommit(
                    plan: plan,
                    tracksByID: [trackID: nextTrack],
                    editGraph: nextGraph,
                    selectedTimelineRange: finalSelection,
                    clipboard: clipboard
                )
                do {
                    let transaction = try self.commitPreparedProjectEdit(
                        preparedCommit,
                        keepsTransitionVisual: true
                    )
                    self.scheduleTransactionVisualHandoff(
                        generation: pasteVisual.generation,
                        state: transaction.after,
                        preservesLivePlayhead: command.wasPlaying
                    )
                    self.updateEffectCommandState()
                    self.updateStatus("pasted \(self.formatDuration(clipboardBuffer.duration))")
                    self.cleanupOwnedSourceFiles(replacedTracks: [destinationTrack])
                } catch {
                    try? AudioExportLeaseManager.shared.deleteOrDefer(asset.url)
                    self.rollbackPortablePasteVisual(
                        generation: pasteVisual.generation,
                        previousSelection: previousSelection
                    )
                    self.updateStatus("paste failed: \(error.localizedDescription)")
                }

                case let .failure(message):
                    self.rollbackPortablePasteVisual(
                        generation: pasteVisual.generation,
                        previousSelection: previousSelection
                    )
                    self.updateStatus("paste failed: \(message)")

                case .canceled:
                    self.rollbackPortablePasteVisual(
                        generation: pasteVisual.generation,
                        previousSelection: previousSelection
                    )
                }
            }
        }
    }

    private func portablePasteRenderSnapshot(
        clipboardBuffer: DecodedAudioBuffer,
        destinationTrack: ProjectTrack,
        insertionFrame: Int,
        outputURL: URL
    ) throws -> AudioExportSnapshot {
        let destinationSource: AudioExportTrackSource
        let destinationSampleRate: Double
        let destinationChannelCount: Int
        let destinationFrameCount: Int
        let destinationSourceURL: URL?

        if let timeline = destinationTrack.audioTimeline {
            destinationSampleRate = timeline.sourceAudioBuffer.sampleRate
            destinationChannelCount = timeline.sourceAudioBuffer.channelCount
            destinationFrameCount = timeline.frameCount
            destinationSourceURL = timeline.sourceAudioBuffer.url
            let insertedFrameCount = Int(
                (clipboardBuffer.duration * destinationSampleRate).rounded()
            )
            destinationSource = .decodedSegments(
                timeline.sourceAudioBuffer,
                Self.playbackSegments(
                    timeline.playbackSegments,
                    insertingGapAt: insertionFrame,
                    frameCount: insertedFrameCount
                )
            )
        } else {
            guard
                let fileInfo = decodableWAVFileInfo(for: destinationTrack.sourceURL)
            else {
                throw PlaybackError.invalidFormat
            }
            let timeline = destinationTrack.fileTimeline ??
                AudioFileEditTimeline(fileInfo: fileInfo)
            destinationSampleRate = fileInfo.sampleRate
            destinationChannelCount = fileInfo.channelCount
            destinationFrameCount = timeline.frameCount
            destinationSourceURL = destinationTrack.sourceURL
            let insertedFrameCount = Int(
                (clipboardBuffer.duration * destinationSampleRate).rounded()
            )
            destinationSource = .fileSegments(
                destinationTrack.sourceURL,
                fileInfo,
                Self.playbackSegments(
                    timeline.playbackSegments,
                    insertingGapAt: insertionFrame,
                    frameCount: insertedFrameCount
                )
            )
        }

        guard
            destinationSampleRate.isFinite,
            destinationSampleRate > 0,
            clipboardBuffer.sampleRate.isFinite,
            clipboardBuffer.sampleRate > 0,
            clipboardBuffer.frameCount > 0
        else {
            throw PlaybackError.invalidFormat
        }

        let clampedInsertionFrame = min(max(insertionFrame, 0), destinationFrameCount)
        let insertedDestinationFrameCount = max(
            Int((clipboardBuffer.duration * destinationSampleRate).rounded()),
            1
        )
        let clipboardOutputStartFrame = Int(
            (
                Double(clampedInsertionFrame) /
                    destinationSampleRate *
                    clipboardBuffer.sampleRate
            ).rounded()
        )
        let clipboardSegment = AudioEditTimeline.PlaybackSegment(
            outputStartFrame: clipboardOutputStartFrame,
            sourceStartFrame: 0,
            frameCount: clipboardBuffer.frameCount,
            sourceFrameScale: 0,
            gainStart: 1,
            gainEnd: 1,
            startsNewClip: true
        )

        let destinationSnapshot = AudioExportTrackSnapshot(
            id: destinationTrack.id,
            name: destinationTrack.name,
            volume: 1,
            source: destinationSource
        )
        let clipboardSnapshot = AudioExportTrackSnapshot(
            id: UUID(),
            name: "Clipboard",
            volume: 1,
            source: .decodedSegments(clipboardBuffer, [clipboardSegment])
        )
        let request = AudioExportRequest(
            projectName: "Portable Paste",
            scope: .fullMixdown,
            format: .wav,
            destinationURL: outputURL,
            wavEncoding: .float32
        )
        let fullFrameCount = destinationFrameCount + insertedDestinationFrameCount
        return AudioExportSnapshot(
            id: request.id,
            createdAt: request.createdAt,
            request: request,
            tracks: [destinationSnapshot, clipboardSnapshot],
            sampleRate: destinationSampleRate,
            channelCount: max(
                destinationChannelCount,
                clipboardBuffer.channelCount,
                1
            ),
            fullDurationFrameCount: fullFrameCount,
            exportFrameRange: 0..<fullFrameCount,
            leasedURLs: destinationSourceURL.map { [$0] } ?? []
        )
    }

    private nonisolated static func playbackSegments(
        _ segments: [AudioEditTimeline.PlaybackSegment],
        insertingGapAt requestedInsertionFrame: Int,
        frameCount requestedInsertedFrameCount: Int
    ) -> [AudioEditTimeline.PlaybackSegment] {
        let insertionFrame = max(requestedInsertionFrame, 0)
        let insertedFrameCount = max(requestedInsertedFrameCount, 0)
        guard insertedFrameCount > 0 else {
            return segments
        }

        var output: [AudioEditTimeline.PlaybackSegment] = []
        output.reserveCapacity(segments.count + 1)
        for segment in segments {
            let segmentStart = segment.outputStartFrame
            let segmentEnd = segment.outputStartFrame + segment.frameCount
            if segmentEnd <= insertionFrame {
                output.append(segment)
                continue
            }
            if segmentStart >= insertionFrame {
                output.append(AudioEditTimeline.PlaybackSegment(
                    outputStartFrame: segmentStart + insertedFrameCount,
                    sourceStartFrame: segment.sourceStartFrame,
                    frameCount: segment.frameCount,
                    sourceFrameScale: segment.sourceFrameScale,
                    gainStart: segment.gainStart,
                    gainEnd: segment.gainEnd,
                    startsNewClip: segment.startsNewClip
                ))
                continue
            }

            let leadingFrameCount = insertionFrame - segmentStart
            let trailingFrameCount = segmentEnd - insertionFrame
            let sourceScale = segment.sourceFrameScale > 0
                ? segment.sourceFrameScale
                : 1
            let leadingEndGain = Self.segmentGain(
                segment,
                at: max(leadingFrameCount - 1, 0)
            )
            let trailingStartGain = Self.segmentGain(
                segment,
                at: leadingFrameCount
            )
            if leadingFrameCount > 0 {
                output.append(AudioEditTimeline.PlaybackSegment(
                    outputStartFrame: segmentStart,
                    sourceStartFrame: segment.sourceStartFrame,
                    frameCount: leadingFrameCount,
                    sourceFrameScale: segment.sourceFrameScale,
                    gainStart: segment.gainStart,
                    gainEnd: leadingEndGain,
                    startsNewClip: segment.startsNewClip
                ))
            }
            if trailingFrameCount > 0 {
                output.append(AudioEditTimeline.PlaybackSegment(
                    outputStartFrame: insertionFrame + insertedFrameCount,
                    sourceStartFrame: segment.sourceStartFrame +
                        Int((Double(leadingFrameCount) * sourceScale).rounded()),
                    frameCount: trailingFrameCount,
                    sourceFrameScale: segment.sourceFrameScale,
                    gainStart: trailingStartGain,
                    gainEnd: segment.gainEnd,
                    startsNewClip: true
                ))
            }
        }
        return output
    }

    private nonisolated static func segmentGain(
        _ segment: AudioEditTimeline.PlaybackSegment,
        at requestedOffset: Int
    ) -> Float {
        guard segment.frameCount > 1 else {
            return segment.gainEnd
        }
        let offset = min(max(requestedOffset, 0), segment.frameCount - 1)
        let progress = Float(offset) / Float(segment.frameCount - 1)
        let curve = progress * progress * (3 - 2 * progress)
        return segment.gainStart + (segment.gainEnd - segment.gainStart) * curve
    }

    private nonisolated static func renderPortablePasteAsset(
        snapshot: AudioExportSnapshot,
        cancellationCheck: AudioExportRenderer.CancellationCheck? = nil
    ) throws -> PortablePasteRenderedAsset {
        let writer = try AudioExportStreamingWAVWriter(
            url: snapshot.request.destinationURL,
            sampleRate: snapshot.sampleRate,
            channelCount: snapshot.channelCount,
            encoding: .float32
        )
        do {
            let usedFastPath = try renderPortablePasteFastPath(
                snapshot: snapshot,
                writer: writer,
                cancellationCheck: cancellationCheck
            )
            if !usedFastPath {
                _ = try AudioExportRenderer.renderMixdown(
                    snapshot: snapshot,
                    to: writer,
                    cancellationCheck: cancellationCheck
                )
            }
            let fileInfo = try WAVAudioDecoder.inspect(url: writer.url)
            return PortablePasteRenderedAsset(
                url: writer.url,
                fileInfo: fileInfo
            )
        } catch {
            writer.cancel()
            throw error
        }
    }

    private nonisolated static func renderPortablePasteFastPath(
        snapshot: AudioExportSnapshot,
        writer: AudioExportStreamingWAVWriter,
        cancellationCheck: AudioExportRenderer.CancellationCheck?
    ) throws -> Bool {
        let hasSoloedTrack = snapshot.tracks.contains(where: \.isSoloed)
        let audibleTracks = snapshot.tracks.filter { track in
            hasSoloedTrack ? track.isSoloed : !track.isMuted
        }
        let sources: [PortablePasteSource] = audibleTracks.compactMap { track in
            let gain = max(track.volume, 0) * max(track.volume, 0)
            switch track.source {
            case let .decodedSegments(buffer, segments):
                return .decoded(buffer, segments, gain)
            case let .fileSegments(url, fileInfo, segments):
                return .file(url, fileInfo, segments, gain)
            default:
                return nil
            }
        }
        guard
            sources.count == audibleTracks.count,
            sources.allSatisfy({
                abs($0.sampleRate - snapshot.sampleRate) < 0.001 &&
                    $0.segments.allSatisfy {
                        $0.sourceFrameScale == 0 ||
                            abs($0.sourceFrameScale - 1) < 0.000_000_001
                    }
            })
        else {
            return false
        }

        // Cross-source paste is a background operation, so use a larger bounded
        // block than realtime export to reduce mapped-file and writer overhead.
        let blockFrameCount = 262_144
        var outputFrame = snapshot.exportFrameRange.lowerBound
        while outputFrame < snapshot.exportFrameRange.upperBound {
            try cancellationCheck?()
            let outputEndFrame = min(
                outputFrame + blockFrameCount,
                snapshot.exportFrameRange.upperBound
            )
            let frameCount = outputEndFrame - outputFrame
            var outputSamples = [[Float]](
                repeating: [Float](repeating: 0, count: frameCount),
                count: max(snapshot.channelCount, 1)
            )

            for source in sources {
                for segment in source.segments {
                    let segmentRange = segment.outputStartFrame..<(
                        segment.outputStartFrame + segment.frameCount
                    )
                    let intersectionStart = max(outputFrame, segmentRange.lowerBound)
                    let intersectionEnd = min(outputEndFrame, segmentRange.upperBound)
                    guard intersectionStart < intersectionEnd else {
                        continue
                    }

                    let segmentOffset = intersectionStart - segment.outputStartFrame
                    let sourceStartFrame = segment.sourceStartFrame + segmentOffset
                    let sourceFrameCount = intersectionEnd - intersectionStart
                    let sourceBuffer: DecodedAudioBuffer
                    switch source {
                    case let .decoded(buffer, _, _):
                        sourceBuffer = buffer
                    case let .file(url, _, _, _):
                        sourceBuffer = try WAVAudioDecoder.decode(
                            url: url,
                            frameRange: sourceStartFrame..<(sourceStartFrame + sourceFrameCount)
                        )
                    }

                    let sourceBufferStartFrame: Int
                    switch source {
                    case .decoded:
                        sourceBufferStartFrame = sourceStartFrame
                    case .file:
                        sourceBufferStartFrame = 0
                    }
                    let outputOffset = intersectionStart - outputFrame
                    let sourceRange = sourceBufferStartFrame..<(
                        sourceBufferStartFrame + sourceFrameCount
                    )
                    guard
                        outputOffset >= 0,
                        outputOffset + sourceFrameCount <= frameCount,
                        sourceRange.lowerBound >= 0
                    else {
                        throw PlaybackError.invalidFormat
                    }

                    let constantSegmentGain = segment.gainStart == segment.gainEnd
                        ? source.gain * segment.gainStart
                        : nil
                    for outputChannel in outputSamples.indices {
                        let sourceChannel = sourceBuffer.channelCount == 1
                            ? 0
                            : outputChannel
                        guard
                            sourceBuffer.samplesByChannel.indices.contains(sourceChannel),
                            sourceRange.upperBound <=
                                sourceBuffer.samplesByChannel[sourceChannel].count
                        else {
                            continue
                        }
                        let sourceSamples = sourceBuffer.samplesByChannel[sourceChannel]
                        outputSamples[outputChannel].withUnsafeMutableBufferPointer { output in
                            sourceSamples.withUnsafeBufferPointer { input in
                                if let constantSegmentGain {
                                    for localFrame in 0..<sourceFrameCount {
                                        output[outputOffset + localFrame] +=
                                            input[sourceBufferStartFrame + localFrame] *
                                                constantSegmentGain
                                    }
                                } else {
                                    let denominator = Float(max(segment.frameCount - 1, 1))
                                    for localFrame in 0..<sourceFrameCount {
                                        let progress = Float(
                                            min(
                                                max(segmentOffset + localFrame, 0),
                                                segment.frameCount - 1
                                            )
                                        ) / denominator
                                        let curve = progress * progress * (3 - 2 * progress)
                                        let segmentGain = segment.gainStart +
                                            (segment.gainEnd - segment.gainStart) * curve
                                        output[outputOffset + localFrame] +=
                                            input[sourceBufferStartFrame + localFrame] *
                                                source.gain *
                                                segmentGain
                                    }
                                }
                            }
                        }
                    }
                }
            }

            try writer.append(
                samplesByChannel: outputSamples,
                frameCount: frameCount
            )
            outputFrame = outputEndFrame
        }
        _ = try writer.finish()
        return true
    }

    private nonisolated static func transcript(
        _ transcript: TranscriptDocument?,
        insertingDuration: TimeInterval,
        at insertionTime: TimeInterval,
        sourceRevision: Int,
        sourceDuration: TimeInterval
    ) -> TranscriptDocument? {
        guard var transcript else {
            return nil
        }
        let duration = max(insertingDuration, 0)
        let insertionTime = max(insertionTime, 0)
        guard duration > 0 else {
            return transcript
        }

        transcript.segments = transcript.segments.map { segment in
            var segment = segment
            segment.words = segment.words.map { word in
                var word = word
                if word.startTime >= insertionTime {
                    word.startTime += duration
                    word.endTime += duration
                } else if word.endTime > insertionTime {
                    word.endTime += duration
                }
                return word
            }
            if segment.startTime >= insertionTime {
                segment.startTime += duration
                segment.endTime += duration
            } else if segment.endTime > insertionTime {
                segment.endTime += duration
            }
            return segment
        }
        transcript.sourceRevision = sourceRevision
        transcript.sourceDuration = max(sourceDuration, 0)
        transcript.validity = .remapped
        transcript.sourceFingerprint = nil
        return transcript
    }

    private func rollbackPortablePasteVisual(
        generation: Int,
        previousSelection: TimelineSelection?
    ) {
        guard deleteAnimationGeneration == generation else {
            return
        }
        timelineSurface.clearDeletionEffects()
        selectedTimelineRange = previousSelection
        timelineSurface.displaySelection(previousSelection)
    }


    private func clearEditMaterializationTask(trackID: UUID, requestID: UUID) {
        editMaterializationTasks.finish(key: trackID, generation: requestID)
    }

    private func clearPortablePastePreparationJob(
        trackID: UUID,
        requestID: UUID
    ) {
        editMaterializationTasks.finish(key: trackID, generation: requestID)
    }

    private func scheduleFileTimelineWaveformRefinement(
        trackID: UUID,
        fileTimeline: AudioFileEditTimeline?,
        sourceOverview: WaveformOverview?,
        editRevision: Int,
        delay: TimeInterval? = nil
    ) {
        guard
            let fileTimeline,
            let sourceOverview,
            sourceOverview.bins.count > optimisticEditPreviewBinLimit
        else {
            cancelEditWaveformRefinement(for: trackID)
            return
        }
        guard
            bestSourceWaveformOverview(
                sourceOverview: sourceOverview,
                fallbackOverview: nil,
                fileTimeline: fileTimeline
            ) != nil
        else {
            cancelEditWaveformRefinement(for: trackID)
            return
        }
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            let fileInfo = decodableWAVFileInfo(for: projectTracks[trackIndex].sourceURL)
        else {
            cancelEditWaveformRefinement(for: trackID)
            return
        }
        let sourceURL = projectTracks[trackIndex].sourceURL
        let trackName = projectTracks[trackIndex].name

        editWaveformRefinementTasks.replaceTask(for: trackID) { requestID in
            Task { [
                weak self,
                trackID,
                sourceURL,
                fileInfo,
                fileTimeline,
                sourceOverview,
                editRevision,
                trackName,
                editWaveformRefinementDelay = delay ?? editWaveformRefinementDelay,
                requestID
            ] in
                try? await Task.sleep(nanoseconds: UInt64(editWaveformRefinementDelay * 1_000_000_000))
                guard !Task.isCancelled else {
                    self?.clearEditWaveformRefinementTask(trackID: trackID, requestID: requestID)
                    return
                }

                let cachedOverview = await self?.cachedEditedWaveformOverview(
                    at: sourceURL,
                    fileInfo: fileInfo,
                    fileTimeline: fileTimeline
                )?.overview
                let refinedOverview: WaveformOverview
                let didLoadCachedOverview: Bool
                if let cachedOverview {
                    self?.recordWaveformCacheDecision(
                        name: "edited-overview-cache-hit",
                        message: "Loaded edited waveform refinement from disk cache.",
                        tier: "editedOverviewDiskCache",
                        result: "hit",
                        trackID: trackID,
                        trackName: trackName,
                        sourceURL: sourceURL,
                        binCount: cachedOverview.bins.count,
                        editRevision: editRevision
                    )
                    refinedOverview = cachedOverview
                    didLoadCachedOverview = true
                } else {
                    self?.recordWaveformCacheDecision(
                        name: "edited-overview-cache-miss",
                        message: "Edited waveform refinement cache was unavailable; rebuilding from edit timeline.",
                        tier: "editedOverviewDiskCache",
                        result: "miss",
                        trackID: trackID,
                        trackName: trackName,
                        sourceURL: sourceURL,
                        editRevision: editRevision,
                        reason: "not-found-for-edit-state"
                    )
                    self?.recordWaveformCacheDecision(
                        name: "edited-overview-rebuild",
                        message: "Building edited waveform overview in the background.",
                        tier: "backgroundRebuild",
                        result: "build",
                        trackID: trackID,
                        trackName: trackName,
                        sourceURL: sourceURL,
                        binCount: sourceOverview.bins.count,
                        editRevision: editRevision
                    )
                    refinedOverview = await Task.detached(priority: .utility) {
                        fileTimeline.waveformOverview(from: sourceOverview)
                    }.value
                    didLoadCachedOverview = false
                }

                guard let self else {
                    return
                }

                guard
                    !Task.isCancelled,
                    self.editWaveformRefinementTasks.isCurrent(
                        trackID,
                        generation: requestID
                    ),
                    let trackIndex = self.projectTracks.firstIndex(where: { $0.id == trackID }),
                    self.projectTracks[trackIndex].editRevision == editRevision,
                    self.projectTracks[trackIndex].fileTimeline != nil
                else {
                    self.clearEditWaveformRefinementTask(trackID: trackID, requestID: requestID)
                    return
                }

                let visibleBinCount = self.projectTracks[trackIndex].waveformOverview?.bins.count ?? 0
                let refinedBinCount = refinedOverview.bins.count
                let minimumDisplayBinCount = visibleBinCount > self.optimisticEditPreviewBinLimit ?
                    max(
                        Int((Double(visibleBinCount) * 0.90).rounded(.down)),
                        self.optimisticEditPreviewBinLimit
                    ) :
                    1
                let refinementIsDisplayable =
                    refinedBinCount >= minimumDisplayBinCount ||
                    visibleBinCount == 0

                self.clearEditWaveformRefinementTask(trackID: trackID, requestID: requestID)
                guard refinementIsDisplayable else {
                    self.recordWaveformCacheDecision(
                        name: "edited-overview-refinement-display-skipped",
                        message: "Skipped displaying edited waveform refinement because it would reduce visible detail.",
                        tier: "backgroundRebuild",
                        result: "skipped",
                        trackID: trackID,
                        trackName: trackName,
                        sourceURL: sourceURL,
                        binCount: refinedBinCount,
                        targetBinCount: visibleBinCount,
                        editRevision: editRevision,
                        reason: refinedBinCount == 0 ? "empty-refinement" : "lower-bin-count-than-visible-preview"
                    )
                    if !didLoadCachedOverview {
                        self.cacheEditedWaveformOverview(
                            refinedOverview,
                            fileInfo: fileInfo,
                            fileTimeline: fileTimeline
                        )
                    }
                    return
                }

                self.projectTracks[trackIndex].waveformOverview = refinedOverview
                self.refreshProjectTimelineDisplay(
                    rebuildControls: false,
                    animateWaveformTransition: false
                )
                self.updateProjectDisplayTiming()
                if !didLoadCachedOverview {
                    self.cacheEditedWaveformOverview(
                        refinedOverview,
                        fileInfo: fileInfo,
                        fileTimeline: fileTimeline
                    )
                }
            }
        }
    }

    private func clearEditWaveformRefinementTask(trackID: UUID, requestID: UUID) {
        editWaveformRefinementTasks.finish(key: trackID, generation: requestID)
    }

    private func applyMaterializedTrackEdit(
        trackID: UUID,
        editRevision: Int,
        materialized: (
            buffer: DecodedAudioBuffer,
            timeline: AudioEditTimeline,
            waveformOverview: WaveformOverview,
            zeroCrossingIndex: AudioZeroCrossingIndex
        ),
        status: String,
        preservePlaybackProgress: Bool = false,
        reloadPlaybackSource: Bool = false,
        preserveTimelineSource: Bool = true,
        animateWaveformTransition: Bool = true
    ) {
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            projectTracks[trackIndex].editRevision == editRevision
        else {
            return
        }

        let existingTimeline = projectTracks[trackIndex].audioTimeline
        let shouldPreserveTimelineSource = preserveTimelineSource && existingTimeline != nil
        let timeline = shouldPreserveTimelineSource ? existingTimeline : materialized.timeline
        applyEditedTimelineState(
            trackIndex: trackIndex,
            editedAudioTimeline: timeline,
            editedFileTimeline: nil,
            editedDuration: timeline?.duration ?? materialized.buffer.duration,
            decodedAudioBuffer: materialized.buffer
        )
        if !shouldPreserveTimelineSource || projectTracks[trackIndex].sourceWaveformOverview == nil {
            projectTracks[trackIndex].sourceWaveformOverview = materialized.waveformOverview
        }
        projectTracks[trackIndex].waveformOverview = materialized.waveformOverview
        if !shouldPreserveTimelineSource {
            projectTracks[trackIndex].zeroCrossingIndex = materialized.zeroCrossingIndex
        }
        activeTrackID = trackID
        syncActiveTrackFields()
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        refreshProjectTimelineDisplay(
            rebuildControls: false,
            animateWaveformTransition: animateWaveformTransition
        )
        updateProjectDisplayTiming(sampleRateHint: materialized.buffer.sampleRate)
        if !shouldPreserveTimelineSource || reloadPlaybackSource {
            if playbackController.isPlaying, !reloadPlaybackSource {
                updateProjectPlaybackTrackMix()
            } else {
                reloadPlaybackFromProjectTracks(preserveProgress: preservePlaybackProgress)
            }
        }
        updateEffectCommandState()
        updateStatus(status)
    }

    private nonisolated static func materializeTimeline(_ timeline: AudioEditTimeline) -> (
        buffer: DecodedAudioBuffer,
        timeline: AudioEditTimeline,
        waveformOverview: WaveformOverview,
        zeroCrossingIndex: AudioZeroCrossingIndex
    ) {
        let buffer = timeline.render()
        return (
            buffer: buffer,
            timeline: timeline,
            waveformOverview: WaveformOverviewBuilder.build(from: buffer),
            zeroCrossingIndex: AudioZeroCrossingIndex.build(from: buffer)
        )
    }

    private nonisolated static func materializePaste(
        timeline: AudioEditTimeline,
        selection: TimelineSelection,
        clipboardBuffer: DecodedAudioBuffer
    ) throws -> (
        buffer: DecodedAudioBuffer,
        timeline: AudioEditTimeline,
        waveformOverview: WaveformOverview,
        zeroCrossingIndex: AudioZeroCrossingIndex
    ) {
        let sourceBuffer = timeline.render()
        guard
            sourceBuffer.sampleRate > 0,
            clipboardBuffer.sampleRate > 0,
            abs(sourceBuffer.sampleRate - clipboardBuffer.sampleRate) < 0.001
        else {
            throw PlaybackError.invalidFormat
        }

        let replaceRange = timeline.frameRange(for: selection)
        let channelCount = max(sourceBuffer.channelCount, clipboardBuffer.channelCount)
        let nextFrameCount = replaceRange.lowerBound +
            clipboardBuffer.frameCount +
            max(sourceBuffer.frameCount - replaceRange.upperBound, 0)
        var samplesByChannel = (0..<channelCount).map { _ in
            [Float]()
        }

        for channelIndex in samplesByChannel.indices {
            samplesByChannel[channelIndex].reserveCapacity(nextFrameCount)
            let sourceChannel = sourceBuffer.channelCount == 1 ?
                0 :
                min(channelIndex, sourceBuffer.channelCount - 1)
            let clipboardChannel = clipboardBuffer.channelCount == 1 ?
                0 :
                min(channelIndex, clipboardBuffer.channelCount - 1)
            let sourceSamples = sourceBuffer.samplesByChannel[sourceChannel]
            let clipboardSamples = clipboardBuffer.samplesByChannel[clipboardChannel]

            if replaceRange.lowerBound > 0 {
                samplesByChannel[channelIndex].append(contentsOf: sourceSamples[0..<replaceRange.lowerBound])
            }
            samplesByChannel[channelIndex].append(contentsOf: clipboardSamples)
            if replaceRange.upperBound < sourceSamples.count {
                samplesByChannel[channelIndex].append(contentsOf: sourceSamples[replaceRange.upperBound..<sourceSamples.count])
            }
        }

        let buffer = DecodedAudioBuffer(
            url: sourceBuffer.url,
            sampleRate: sourceBuffer.sampleRate,
            channelCount: channelCount,
            frameCount: nextFrameCount,
            samplesByChannel: samplesByChannel
        )
        let timeline = AudioEditTimeline(sourceBuffer: buffer)
        return (
            buffer: buffer,
            timeline: timeline,
            waveformOverview: WaveformOverviewBuilder.build(from: buffer),
            zeroCrossingIndex: AudioZeroCrossingIndex.build(from: buffer)
        )
    }

    private nonisolated static func materializePaste(
        timeline: AudioEditTimeline,
        insertionFrame: Int,
        clipboardBuffer: DecodedAudioBuffer
    ) throws -> (
        buffer: DecodedAudioBuffer,
        timeline: AudioEditTimeline,
        waveformOverview: WaveformOverview,
        zeroCrossingIndex: AudioZeroCrossingIndex
    ) {
        let frame = min(max(insertionFrame, 0), timeline.frameCount)
        let progress = timeline.frameCount > 0
            ? Double(frame) / Double(timeline.frameCount)
            : 0
        return try materializePaste(
            timeline: timeline,
            selection: TimelineSelection(
                startProgress: progress,
                endProgress: progress,
                trackID: nil
            ),
            clipboardBuffer: clipboardBuffer
        )
    }

    private func optimisticWaveformOverview(
        _ overview: WaveformOverview?,
        replacing selection: TimelineSelection,
        with replacement: WaveformOverview?,
        targetDuration: TimeInterval? = nil,
        preservesResolution: Bool = false
    ) -> WaveformOverview? {
        guard let overview else {
            return replacement.map(overviewForOptimisticEdit)
        }

        let sourceOverview = preservesResolution ? overview : overviewForOptimisticEdit(overview)
        let replacementOverview = replacement.map(overviewForOptimisticEdit)
        let binCount = sourceOverview.bins.count
        guard binCount > 0 else {
            return replacementOverview ?? sourceOverview
        }

        let startIndex = min(max(Int((selection.startProgress * Double(binCount)).rounded(.down)), 0), binCount)
        let endIndex: Int
        if
            replacementOverview == nil,
            let targetDuration,
            targetDuration.isFinite,
            targetDuration >= 0,
            sourceOverview.duration.isFinite,
            sourceOverview.duration > 0
        {
            let targetBinCount = min(
                max(Int((Double(binCount) * targetDuration / sourceOverview.duration).rounded()), 0),
                binCount
            )
            let targetRemovedBinCount = min(max(binCount - targetBinCount, 0), binCount - startIndex)
            endIndex = min(startIndex + targetRemovedBinCount, binCount)
        } else {
            endIndex = min(max(Int((selection.endProgress * Double(binCount)).rounded(.up)), startIndex), binCount)
        }
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount - (endIndex - startIndex) + (replacementOverview?.bins.count ?? 0))
        if startIndex > 0 {
            bins.append(contentsOf: sourceOverview.bins[0..<startIndex])
        }
        if let replacementOverview {
            bins.append(contentsOf: replacementOverview.bins)
        }
        if endIndex < binCount {
            bins.append(contentsOf: sourceOverview.bins[endIndex..<binCount])
        }

        let removedDuration = sourceOverview.duration * TimeInterval(selection.durationProgress)
        let nextDuration = targetDuration.map { max($0, 0) } ??
            max(sourceOverview.duration - removedDuration + (replacementOverview?.duration ?? 0), 0)
        return WaveformOverview(duration: nextDuration, bins: bins)
    }

    private func optimisticWaveformOverview(
        _ overview: WaveformOverview?,
        applyingGain gain: Float,
        to selection: TimelineSelection
    ) -> WaveformOverview? {
        guard let overview else {
            return nil
        }

        let sourceOverview = overviewForOptimisticEdit(overview)
        let binCount = sourceOverview.bins.count
        guard binCount > 0 else {
            return sourceOverview
        }

        let startIndex = min(max(Int((selection.startProgress * Double(binCount)).rounded(.down)), 0), binCount)
        let endIndex = min(max(Int((selection.endProgress * Double(binCount)).rounded(.up)), startIndex), binCount)
        guard startIndex < endIndex else {
            return sourceOverview
        }

        var bins = sourceOverview.bins
        for index in startIndex..<endIndex {
            bins[index] = bins[index].scaled(by: gain)
        }

        return WaveformOverview(duration: sourceOverview.duration, bins: bins)
    }

    private func optimisticWaveformOverview(
        _ overview: WaveformOverview?,
        applyingFade fadeDirection: AudioEditTimeline.FadeDirection,
        to selection: TimelineSelection
    ) -> WaveformOverview? {
        guard let overview else {
            return nil
        }

        let sourceOverview = overviewForOptimisticEdit(overview)
        let binCount = sourceOverview.bins.count
        guard binCount > 0 else {
            return sourceOverview
        }

        let startIndex = min(max(Int((selection.startProgress * Double(binCount)).rounded(.down)), 0), binCount)
        let endIndex = min(max(Int((selection.endProgress * Double(binCount)).rounded(.up)), startIndex), binCount)
        guard startIndex < endIndex else {
            return sourceOverview
        }

        let selectedCount = max(endIndex - startIndex, 1)
        var bins = sourceOverview.bins
        for index in startIndex..<endIndex {
            let selectedOffset = index - startIndex
            let progress = selectedCount > 1 ?
                Float(selectedOffset) / Float(selectedCount - 1) :
                1
            let curve = smoothStep(progress)
            let multiplier: Float
            switch fadeDirection {
            case .fadeIn:
                multiplier = curve
            case .fadeOut:
                multiplier = 1 - curve
            }
            bins[index] = bins[index].scaled(by: multiplier)
        }

        return WaveformOverview(duration: sourceOverview.duration, bins: bins)
    }

    private func smoothStep(_ progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        return clampedProgress * clampedProgress * (3 - 2 * clampedProgress)
    }

    private func selectedPeakMagnitude(for target: EditableSelectionTarget) -> Float? {
        guard
            projectTracks.indices.contains(target.trackIndex),
            let overview = projectTracks[target.trackIndex].waveformOverview
        else {
            return nil
        }

        let sourceOverview = overviewForOptimisticEdit(overview)
        let binCount = sourceOverview.bins.count
        guard binCount > 0 else {
            return nil
        }

        let startIndex = min(
            max(Int((target.editSelection.startProgress * Double(binCount)).rounded(.down)), 0),
            binCount
        )
        let endIndex = min(
            max(Int((target.editSelection.endProgress * Double(binCount)).rounded(.up)), startIndex),
            binCount
        )
        guard startIndex < endIndex else {
            return nil
        }

        var peak: Float = 0
        for index in startIndex..<endIndex {
            peak = max(peak, sourceOverview.bins[index].peakMagnitude)
        }
        return peak
    }

    private func selectedWaveformOverview(
        from overview: WaveformOverview?,
        selection: TimelineSelection
    ) -> WaveformOverview? {
        guard let overview else {
            return nil
        }

        let sourceOverview = overviewForOptimisticEdit(overview)
        let binCount = sourceOverview.bins.count
        guard binCount > 0 else {
            return nil
        }

        let startIndex = min(
            max(Int((selection.startProgress * Double(binCount)).rounded(.down)), 0),
            binCount
        )
        let endIndex = min(
            max(Int((selection.endProgress * Double(binCount)).rounded(.up)), startIndex),
            binCount
        )
        guard startIndex < endIndex else {
            return nil
        }

        return WaveformOverview(
            duration: selection.duration(in: sourceOverview.duration),
            bins: Array(sourceOverview.bins[startIndex..<endIndex])
        )
    }

    private nonisolated static func selectionsMatch(
        _ lhs: TimelineSelection,
        _ rhs: TimelineSelection
    ) -> Bool {
        let epsilon = 0.000_001
        return lhs.trackID == rhs.trackID &&
            abs(lhs.startProgress - rhs.startProgress) <= epsilon &&
            abs(lhs.endProgress - rhs.endProgress) <= epsilon
    }

    private nonisolated static func exactPeakMagnitude(
        audioTimeline: AudioEditTimeline?,
        fileTimeline: AudioFileEditTimeline?,
        sourceURL: URL,
        selection: TimelineSelection
    ) throws -> Float {
        if let audioTimeline {
            return peakMagnitude(in: audioTimeline.render(selection: selection))
        }

        if let fileTimeline {
            let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
            let audioTimeline = fileTimeline.audioTimeline(sourceBuffer: sourceBuffer)
            return peakMagnitude(in: audioTimeline.render(selection: selection))
        }

        throw PlaybackError.noAudioLoaded
    }

    private nonisolated static func peakMagnitude(in buffer: DecodedAudioBuffer) -> Float {
        var peak: Float = 0
        for samples in buffer.samplesByChannel {
            for sample in samples {
                peak = max(peak, abs(sample))
            }
        }
        return peak
    }

    private func overviewForOptimisticEdit(_ overview: WaveformOverview) -> WaveformOverview {
        guard overview.bins.count > optimisticEditPreviewBinLimit else {
            return overview
        }

        return sparseOverview(
            from: overview,
            targetBinCount: optimisticEditPreviewBinLimit,
            samplesPerBin: optimisticEditPreviewSamplesPerBin
        )
    }

    private func sparseOverview(
        from overview: WaveformOverview,
        targetBinCount: Int,
        samplesPerBin: Int
    ) -> WaveformOverview {
        let sourceBins = overview.bins
        let sourceBinCount = sourceBins.count
        let targetBinCount = min(max(targetBinCount, 1), sourceBinCount)
        let samplesPerBin = max(samplesPerBin, 1)
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(targetBinCount)

        for targetIndex in 0..<targetBinCount {
            let sourceStartIndex = targetIndex * sourceBinCount / targetBinCount
            let sourceEndIndex = max(sourceStartIndex + 1, (targetIndex + 1) * sourceBinCount / targetBinCount)
            let sourceSpan = sourceEndIndex - sourceStartIndex
            let stride = max(sourceSpan / samplesPerBin, 1)
            var accumulator = WaveformBinAccumulator()
            var sampledIndex = sourceStartIndex
            var sampledCount = 0

            while sampledIndex < sourceEndIndex, sampledCount < samplesPerBin {
                accumulator.addBin(sourceBins[sampledIndex])
                sampledIndex += stride
                sampledCount += 1
            }

            if sourceSpan > 1 {
                accumulator.addBin(sourceBins[sourceEndIndex - 1])
            }

            bins.append(accumulator.makeBin())
        }

        return WaveformOverview(duration: overview.duration, bins: bins)
    }

    private func loadDroppedWAVFile(at url: URL, importID: UUID) {
        let wavPreviewLevels = wavPreviewLevels

        Task { [weak self, importID, url, wavPreviewLevels] in
            do {
                guard let initialPreviewLevel = wavPreviewLevels.first else {
                    return
                }

                guard let self, self.activeImportID == importID else {
                    return
                }

                var latestPreviewBinCount = 0
                var latestFileInfo: WAVFileInfo?
                if let fileInfo = try? WAVAudioDecoder.inspect(url: url) {
                    let cachedPreview = await self.cachedWAVPreviewResult(at: url, fileInfo: fileInfo)
                    if let cachedPreview, self.activeImportID == importID {
                        self.recordWaveformCacheDecision(
                            name: "raw-overview-cache-hit",
                            message: "Loaded raw waveform overview from disk cache for single-file preview.",
                            tier: "rawOverviewDiskCache",
                            result: "hit",
                            trackName: cachedPreview.metadata.displayName,
                            sourceURL: url,
                            binCount: cachedPreview.waveformOverview.bins.count
                        )
                        self.applyPreview(cachedPreview)
                        latestPreviewBinCount = cachedPreview.waveformOverview.bins.count
                        latestFileInfo = cachedPreview.fileInfo
                    } else if self.activeImportID == importID {
                        self.recordWaveformCacheDecision(
                            name: "raw-overview-cache-miss",
                            message: "Raw waveform overview disk cache was unavailable for single-file preview.",
                            tier: "rawOverviewDiskCache",
                            result: "miss",
                            trackName: url.deletingPathExtension().lastPathComponent,
                            sourceURL: url,
                            reason: "not-found"
                        )
                    }
                } else {
                    self.recordWaveformCacheDecision(
                        name: "raw-overview-cache-miss",
                        message: "Raw waveform overview disk cache could not be checked because the WAV file was not inspectable.",
                        tier: "rawOverviewDiskCache",
                        result: "miss",
                        trackName: url.deletingPathExtension().lastPathComponent,
                        sourceURL: url,
                        reason: "file-inspection-failed"
                    )
                }

                if latestPreviewBinCount < min(initialPreviewLevel.targetBinCount, latestFileInfo?.frameCount ?? Int.max) {
                    self.recordWaveformCacheDecision(
                        name: "preview-rebuild",
                        message: "Building initial waveform preview in the background for single-file preview.",
                        tier: "backgroundRebuild",
                        result: "build",
                        trackName: url.deletingPathExtension().lastPathComponent,
                        sourceURL: url,
                        targetBinCount: initialPreviewLevel.targetBinCount,
                        samplesPerBin: initialPreviewLevel.samplesPerBin,
                        reason: "cache-missing-or-too-coarse"
                    )
                    let previewResult = try await AudioImportPipeline.loadWAVPreview(
                        at: url,
                        targetBinCount: initialPreviewLevel.targetBinCount,
                        samplesPerBin: initialPreviewLevel.samplesPerBin
                    )

                    guard self.activeImportID == importID else {
                        return
                    }

                    self.applyPreview(previewResult)
                    self.cacheWaveformOverview(
                        previewResult.waveformOverview,
                        targetBinCount: initialPreviewLevel.targetBinCount,
                        samplesPerBin: initialPreviewLevel.samplesPerBin,
                        fileInfo: previewResult.fileInfo
                    )
                    latestPreviewBinCount = previewResult.waveformOverview.bins.count
                    latestFileInfo = previewResult.fileInfo
                }

                for previewLevel in wavPreviewLevels.dropFirst() {
                    guard self.activeImportID == importID else {
                        return
                    }
                    guard await self.waitForSingleFileImportWorkBudget(importID: importID) else {
                        return
                    }

                    let nextBinCount = min(previewLevel.targetBinCount, latestFileInfo?.frameCount ?? Int.max)
                    guard nextBinCount > latestPreviewBinCount else {
                        continue
                    }

                    do {
                        self.recordWaveformCacheDecision(
                            name: "preview-refinement-rebuild",
                            message: "Building finer waveform preview level in the background for single-file preview.",
                            tier: "backgroundRebuild",
                            result: "build",
                            trackName: url.deletingPathExtension().lastPathComponent,
                            sourceURL: url,
                            targetBinCount: previewLevel.targetBinCount,
                            samplesPerBin: previewLevel.samplesPerBin
                        )
                        let (fileInfo, waveformOverview) = try await AudioImportPipeline.loadWAVPreviewOverview(
                            at: url,
                            targetBinCount: previewLevel.targetBinCount,
                            samplesPerBin: previewLevel.samplesPerBin
                        )

                        guard self.activeImportID == importID else {
                            return
                        }
                        guard await self.waitForSingleFileImportWorkBudget(importID: importID) else {
                            return
                        }

                        latestPreviewBinCount = waveformOverview.bins.count
                        latestFileInfo = fileInfo
                        self.applyPreviewRefinement(
                            fileInfo: fileInfo,
                            waveformOverview: waveformOverview
                        )
                        self.cacheWaveformOverview(
                            waveformOverview,
                            targetBinCount: previewLevel.targetBinCount,
                            samplesPerBin: previewLevel.samplesPerBin,
                            fileInfo: fileInfo
                        )
                    } catch {
                        break
                    }
                }

                do {
                    guard await self.waitForSingleFileImportWorkBudget(
                        importID: importID,
                        idleSettleDuration: 0.65
                    ) else {
                        return
                    }

                    self.recordWaveformCacheDecision(
                        name: "full-waveform-decode",
                        message: "Building full-resolution waveform overview from decoded WAV audio for single-file preview.",
                        tier: "backgroundRebuild",
                        result: "build",
                        trackName: url.deletingPathExtension().lastPathComponent,
                        sourceURL: url,
                        reason: "final-decode"
                    )
                    let (decodedAudioBuffer, waveformOverview, zeroCrossingIndex) =
                        try await AudioImportPipeline.loadDecodedWAV(at: url)

                    guard self.activeImportID == importID else {
                        return
                    }
                    guard await self.waitForSingleFileImportWorkBudget(importID: importID) else {
                        return
                    }

                    self.applyDecodedWAV(
                        decodedAudioBuffer: decodedAudioBuffer,
                        waveformOverview: waveformOverview,
                        zeroCrossingIndex: zeroCrossingIndex
                    )
                    if let latestFileInfo {
                        self.cacheWaveformOverview(
                            waveformOverview,
                            targetBinCount: waveformOverview.bins.count,
                            samplesPerBin: 1,
                            fileInfo: latestFileInfo
                        )
                    }
                } catch {
                    guard self.activeImportID == importID else {
                        return
                    }

                    self.currentPlaybackStatus = "preview ready - edit decode failed: \(error.localizedDescription)"
                    self.updateStatus(self.currentPlaybackStatus)
                }
            } catch {
                guard let self, self.activeImportID == importID else {
                    return
                }

                self.selectedAudioFile = nil
                self.decodedAudioBuffer = nil
                self.audioTimeline = nil
                self.editUndoStack.removeAll()
                self.loadedAudioSummary = nil
                self.selectedTimelineRange = nil
                self.updateEffectCommandState()
                self.currentPlayheadFrame = 0
                self.displayedFrameCount = 0
                self.displayedSampleRate = 0
                self.currentPlaybackStatus = "idle"
                self.playbackController.clear()
                self.timelineSurface.displaySelection(nil)
                self.displayPlaybackVisuals(progress: 0, isPlaying: false)
                self.timelineSurface.displayWaveform(nil)
                self.updateTimeReadout()
                self.metadataLabel.stringValue = "\(url.lastPathComponent) - WAV preview failed: \(error.localizedDescription)"
            }
        }
    }

    private func applyPreview(_ previewResult: WAVPreviewImportResult) {
        selectedAudioFile = previewResult.metadata
        decodedAudioBuffer = nil
        audioTimeline = nil
        editUndoStack.removeAll()
        selectedTimelineRange = nil
        updateEffectCommandState()
        currentPlayheadFrame = 0
        displayedFrameCount = previewResult.fileInfo.frameCount
        displayedSampleRate = previewResult.fileInfo.sampleRate
        window?.title = "Soundtime - \(previewResult.metadata.displayName)"
        loadedAudioSummary = "\(previewResult.metadata.displayName) - \(previewResult.fileInfo.formattedSummary)"

        timelineSurface.displayWaveform(previewResult.waveformOverview)
        timelineSurface.displaySelection(nil)
        displayPlaybackVisuals(progress: 0, isPlaying: false)

        do {
            try playbackController.loadFile(
                at: previewResult.metadata.url,
                zeroCrossingProbe: previewResult.zeroCrossingProbe
            )
            currentPlaybackStatus = "press Space to play - resolving waveform"
            updateTransportControlState(isPlaying: false)
        } catch {
            playbackController.clear()
            currentPlaybackStatus = "preview ready - playback failed: \(error.localizedDescription)"
            updateTransportControlState(isPlaying: false)
        }

        updateStatus(currentPlaybackStatus)
    }

    private func applyPreviewRefinement(
        fileInfo: WAVFileInfo,
        waveformOverview: WaveformOverview
    ) {
        guard decodedAudioBuffer == nil else {
            return
        }

        displayedFrameCount = fileInfo.frameCount
        displayedSampleRate = fileInfo.sampleRate
        timelineSurface.displayWaveform(waveformOverview)
        let snapshot = playbackController.snapshot()
        displayPlaybackVisuals(
            progress: snapshot.progress,
            isPlaying: snapshot.isPlaying,
            syncPlayhead: !snapshot.isPlaying,
            anchorTimestamp: snapshot.hostTimestamp
        )
        updateTimeReadout()
    }

    private func applyDecodedWAV(
        decodedAudioBuffer: DecodedAudioBuffer,
        waveformOverview: WaveformOverview,
        zeroCrossingIndex: AudioZeroCrossingIndex
    ) {
        self.decodedAudioBuffer = decodedAudioBuffer
        audioTimeline = AudioEditTimeline(sourceBuffer: decodedAudioBuffer)
        editUndoStack.removeAll()
        displayedFrameCount = decodedAudioBuffer.frameCount
        displayedSampleRate = decodedAudioBuffer.sampleRate
        updateEffectCommandState()

        if !playbackController.hasSource {
            try? playbackController.load(decodedAudioBuffer, zeroCrossingIndex: zeroCrossingIndex)
        } else {
            try? playbackController.replaceWithDecodedSource(
                decodedAudioBuffer,
                zeroCrossingIndex: zeroCrossingIndex
            )
        }

        timelineSurface.displayWaveform(waveformOverview)
        let snapshot = playbackController.snapshot()
        displayPlaybackVisuals(
            progress: snapshot.progress,
            isPlaying: snapshot.isPlaying,
            syncPlayhead: !snapshot.isPlaying,
            anchorTimestamp: snapshot.hostTimestamp
        )
        updateLoadedAudioSummary(for: decodedAudioBuffer)
        currentPlaybackStatus = playbackController.isPlaying ? "playing" : "press Space to play"
        updateStatus(currentPlaybackStatus)
    }

    private func performAgentCommand(_ command: AgentResolvedCommand) -> AgentCommandResult {
        switch command {
        case .play:
            guard playbackController.hasSource else {
                return AgentCommandResult(status: .failed, message: "Agent: no audio loaded")
            }
            if !playbackController.isPlaying {
                togglePlayback()
            }
            return AgentCommandResult(status: .accepted, message: "Agent: playing")
        case .pause:
            if recordingTrackID != nil {
                stopRecording()
                return AgentCommandResult(status: .accepted, message: "Agent: recording stopped")
            }
            if playbackController.isPlaying {
                togglePlayback()
            }
            return AgentCommandResult(status: .accepted, message: "Agent: paused")
        case .togglePlayback:
            guard playbackController.hasSource || recordingTrackID != nil else {
                return AgentCommandResult(status: .failed, message: "Agent: no audio loaded")
            }
            togglePlayback()
            return AgentCommandResult(status: .accepted, message: "Agent: playback toggled")
        case .deleteSelection:
            guard selectedTrackID != nil || currentEditableSelectionTarget() != nil else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio or a track first")
            }
            deleteSelectedTrackOrSelection()
            return AgentCommandResult(status: .accepted, message: "Agent: delete requested")
        case .clearSelection:
            guard currentEditableSelectionTarget() != nil else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio to clear")
            }
            clearSelection()
            return AgentCommandResult(status: .accepted, message: "Agent: clear requested")
        case .cutSelection:
            guard currentEditableSelectionTarget() != nil else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio to cut")
            }
            cutSelection()
            return AgentCommandResult(status: .accepted, message: "Agent: cut requested")
        case .copySelection:
            guard currentEditableSelectionTarget() != nil else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio to copy")
            }
            copySelection()
            return AgentCommandResult(status: .accepted, message: "Agent: copy requested")
        case .pasteAudio:
            guard audioClipboard != nil else {
                return AgentCommandResult(status: .failed, message: "Agent: clipboard is empty")
            }
            pasteAudio()
            return AgentCommandResult(status: .accepted, message: "Agent: paste requested")
        case .splitAtPlayhead:
            guard canSplitAtPlayhead else {
                return AgentCommandResult(status: .failed, message: "Agent: move the playhead inside a track")
            }
            splitAtPlayhead()
            return AgentCommandResult(status: .accepted, message: "Agent: split requested")
        case .showGain:
            guard canApplyGainEffect else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio for gain")
            }
            showGainEffect()
            return AgentCommandResult(status: .accepted, message: "Agent: gain opened")
        case .deleteSilence:
            guard canDeleteSilence else {
                return AgentCommandResult(status: .failed, message: "Agent: select a track to clean")
            }
            reviewDeadAir()
            return AgentCommandResult(status: .accepted, message: "Agent: dead air review started")
        case .normalizeSelection:
            guard canApplyGainEffect else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio to normalize")
            }
            applyNormalizeEffect()
            return AgentCommandResult(status: .accepted, message: "Agent: normalize requested")
        case .fadeInSelection:
            guard canApplyFadeEffect else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio for fade in")
            }
            applyFadeEffect(.fadeIn)
            return AgentCommandResult(status: .accepted, message: "Agent: fade in requested")
        case .fadeOutSelection:
            guard canApplyFadeEffect else {
                return AgentCommandResult(status: .failed, message: "Agent: select audio for fade out")
            }
            applyFadeEffect(.fadeOut)
            return AgentCommandResult(status: .accepted, message: "Agent: fade out requested")
        case .transcribeSelectedTrack:
            guard canTranscribeSelectedTrack else {
                return AgentCommandResult(status: .failed, message: "Agent: select a track to transcribe")
            }
            transcribeSelectedTrack()
            return AgentCommandResult(status: .accepted, message: "Agent: transcription requested")
        }
    }

    private func deleteSelection(trace: DeleteTimingTrace? = nil) {
        performTransactionalRangeEdit(kind: .rippleDelete, scope: editScope)
    }

    private func removeTimeRangeAcrossScope(trace: DeleteTimingTrace? = nil) {
        performTransactionalRangeEdit(kind: .rippleDelete, scope: editScope)
    }

    private func deleteTimingFields(for target: EditableSelectionTarget) -> [String: String] {
        let trackID = projectTracks.indices.contains(target.trackIndex) ?
            projectTracks[target.trackIndex].id.uuidString :
            "invalid"
        return [
            "trackIndex": "\(target.trackIndex)",
            "trackID": trackID,
            "displayStartProgress": String(format: "%.9f", target.displaySelection.startProgress),
            "displayEndProgress": String(format: "%.9f", target.displaySelection.endProgress),
            "editStartProgress": String(format: "%.9f", target.editSelection.startProgress),
            "editEndProgress": String(format: "%.9f", target.editSelection.endProgress),
            "displayDurationProgress": String(format: "%.9f", target.displaySelection.durationProgress),
            "editDurationProgress": String(format: "%.9f", target.editSelection.durationProgress),
        ]
    }

    private func clearSelection() {
        performTransactionalRangeEdit(kind: .clearGap, scope: editScope)
    }

    private func deleteSelectedTrackOrSelection(trace: DeleteTimingTrace? = nil) {
        if selectedTrackID != nil || !selectedTrackIDs.isEmpty {
            var trace = trace ?? DeleteTimingTrace(operation: "delete-track")
            trace.mark(
                "delete-track-path",
                message: "Delete command selected the whole-track deletion path.",
                fields: [
                    "selectedTrackCount": "\(selectedTrackIDs.count + (selectedTrackID == nil ? 0 : 1))",
                ]
            )
            deleteSelectedTrack()
        } else {
            deleteSelection(trace: trace)
        }
    }

    private func splitAtPlayhead() {
        guard
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            updateStatus("select a track to split")
            return
        }

        let snapshot = playbackController.snapshot()
        let projectProgress = min(max(snapshot.progress, 0), 1)
        let scopedTrackIndices = scopedTrackIndices(anchorTrackIndex: trackIndex, scope: editScope)
        let trackEdits: [SplitTrackEdit]
        do {
            trackEdits = try scopedTrackIndices.compactMap {
                try preparedSplitTrackEdit(trackIndex: $0, projectProgress: projectProgress)
            }
        } catch {
            updateStatus("split failed: \(error.localizedDescription)")
            return
        }
        guard !trackEdits.isEmpty else {
            updateStatus("move the playhead inside the track to split")
            return
        }

        let undoSnapshot = captureProjectTrackUndoSnapshot(
            restoreProgress: projectProgress
        )

        editUndoStack.append(.projectTracks(undoSnapshot))
        for edit in trackEdits {
            guard projectTracks.indices.contains(edit.trackIndex) else {
                continue
            }

            projectTracks[edit.trackIndex].editRevision += 1
            applyEditedTimelineState(
                trackIndex: edit.trackIndex,
                editedAudioTimeline: edit.editedAudioTimeline,
                editedFileTimeline: edit.editedFileTimeline,
                editedDuration: edit.editedDuration
            )
        }

        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        reloadPlaybackFromProjectTracks(
            preserveProgress: true,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()
        let scopeSuffix = trackEdits.count > 1 ? " across \(trackEdits.count) tracks" : ""
        updateStatus("split at \(formatClockTime(Double(projectProgress) * displayedDuration))\(scopeSuffix)")
    }

    private func insertSilenceOrTime() {
        let snapshot = playbackController.snapshot()
        let projectDuration = projectSelectionDuration
        guard projectDuration > 0 else {
            updateStatus("load audio before inserting time")
            return
        }

        let anchorTrackIndex: Int
        let insertionProjectProgress: Float
        let insertedDuration: TimeInterval
        if
            let target = currentEditableSelectionTarget(),
            projectTracks.indices.contains(target.trackIndex)
        {
            anchorTrackIndex = target.trackIndex
            insertionProjectProgress = target.displaySelection.startProgressFloat
            insertedDuration = max(target.displaySelection.duration(in: projectDuration), 0)
        } else if
            let activeTrackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(activeTrackIndex)
        {
            anchorTrackIndex = activeTrackIndex
            insertionProjectProgress = min(max(snapshot.progress, 0), 1)
            insertedDuration = 1
        } else {
            updateStatus("select a track to insert time")
            return
        }

        guard insertedDuration > 0 else {
            updateStatus("select time to insert")
            return
        }

        let scopedTrackIndices = scopedTrackIndices(anchorTrackIndex: anchorTrackIndex, scope: editScope)
        let undoSnapshot = captureProjectTrackUndoSnapshot(
            restoreProgress: insertionProjectProgress
        )

        var editedTrackCount = 0
        var materializationEdits: [(trackID: UUID, timeline: AudioEditTimeline, editRevision: Int)] = []
        for trackIndex in scopedTrackIndices where projectTracks.indices.contains(trackIndex) {
            let track = projectTracks[trackIndex]
            let trackDuration = trackDuration(for: track)
            guard trackDuration > 0 else {
                continue
            }

            let insertionTime = Double(insertionProjectProgress) * projectDuration
            let localProgress = min(max(insertionTime / trackDuration, 0), 1)
            let insertedFrameCount: Int
            let editedAudioTimeline: AudioEditTimeline?
            let editedFileTimeline: AudioFileEditTimeline?
            let editedDuration: TimeInterval

            if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
                var timeline = currentFileTimeline
                let frameCount = max(Int((insertedDuration * timeline.sourceSampleRate).rounded()), 1)
                insertedFrameCount = timeline.insertSilence(frameCount: frameCount, atProgress: localProgress)
                editedAudioTimeline = nil
                editedFileTimeline = timeline
                editedDuration = timeline.duration
            } else if let currentTimeline = projectTracks[trackIndex].audioTimeline {
                var timeline = currentTimeline
                let frameCount = max(Int((insertedDuration * timeline.sourceAudioBuffer.sampleRate).rounded()), 1)
                insertedFrameCount = timeline.insertSilence(frameCount: frameCount, atProgress: localProgress)
                editedAudioTimeline = timeline
                editedFileTimeline = nil
                editedDuration = timeline.duration
            } else {
                continue
            }

            guard insertedFrameCount > 0 else {
                continue
            }

            if editedTrackCount == 0 {
                editUndoStack.append(.projectTracks(undoSnapshot))
            }
            editedTrackCount += 1
            let trackID = projectTracks[trackIndex].id
            cancelEditMaterialization(for: trackID)
            projectTracks[trackIndex].editRevision += 1
            let editRevision = projectTracks[trackIndex].editRevision
            applyEditedTimelineState(
                trackIndex: trackIndex,
                editedAudioTimeline: editedAudioTimeline,
                editedFileTimeline: editedFileTimeline,
                editedDuration: editedDuration
            )

            let currentOverview = projectTracks[trackIndex].waveformOverview
            if let editedFileTimeline {
                projectTracks[trackIndex].waveformOverview =
                    optimisticWaveformOverview(
                        for: editedFileTimeline,
                        sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                        fallbackOverview: currentOverview
                    )
                scheduleFileTimelineWaveformRefinement(
                    trackID: trackID,
                    fileTimeline: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                    editRevision: editRevision,
                    delay: editMaterializationDelay
                )
            } else if let currentOverview {
                projectTracks[trackIndex].waveformOverview = WaveformOverview(
                    duration: editedDuration,
                    bins: currentOverview.bins
                )
            }

            if let editedAudioTimeline {
                materializationEdits.append((trackID, editedAudioTimeline, editRevision))
            }
        }

        guard editedTrackCount > 0 else {
            updateStatus("could not insert time")
            return
        }

        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: true)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(
            preserveProgress: true,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()

        let scopeSuffix = editedTrackCount > 1 ? " across \(editedTrackCount) tracks" : ""
        let status = "inserted \(formatDuration(insertedDuration)) silence\(scopeSuffix)"
        updateStatus(status)
        for edit in materializationEdits {
            materializeEditedTimeline(
                trackID: edit.trackID,
                timeline: edit.timeline,
                editRevision: edit.editRevision,
                status: status,
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay,
                animateWaveformTransition: false
            )
        }
    }

    private func healAdjacentClips() {
        guard
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            updateStatus("select a track to heal")
            return
        }

        let projectDuration = projectSelectionDuration
        let track = projectTracks[trackIndex]
        let trackDuration = trackDuration(for: track)
        guard projectDuration > 0, trackDuration > 0 else {
            updateStatus("cannot heal clips without audio")
            return
        }

        let projectProgress = selectedTimelineRange?.startProgressFloat ?? playbackController.snapshot().progress
        let projectTime = Double(min(max(projectProgress, 0), 1)) * projectDuration
        let localProgress = min(max(projectTime / trackDuration, 0), 1)

        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
        let editedDuration: TimeInterval
        if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            guard timeline.healNearestClipBoundary(atProgress: localProgress) else {
                updateStatus("no clip boundary to heal")
                return
            }
            editedAudioTimeline = nil
            editedFileTimeline = timeline
            editedDuration = timeline.duration
        } else if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            var timeline = currentTimeline
            guard timeline.healNearestClipBoundary(atProgress: localProgress) else {
                updateStatus("no clip boundary to heal")
                return
            }
            editedAudioTimeline = timeline
            editedFileTimeline = nil
            editedDuration = timeline.duration
        } else {
            updateStatus("track is not ready to heal")
            return
        }

        let undoSnapshot = captureProjectTrackUndoSnapshot(
            restoreProgress: projectProgress
        )
        editUndoStack.append(.projectTracks(undoSnapshot))

        let trackID = projectTracks[trackIndex].id
        cancelEditMaterialization(for: trackID)
        projectTracks[trackIndex].editRevision += 1
        let editRevision = projectTracks[trackIndex].editRevision
        applyEditedTimelineState(
            trackIndex: trackIndex,
            editedAudioTimeline: editedAudioTimeline,
            editedFileTimeline: editedFileTimeline,
            editedDuration: editedDuration
        )

        let currentOverview = projectTracks[trackIndex].waveformOverview
        if let editedFileTimeline {
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    for: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trackID,
                fileTimeline: editedFileTimeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision,
                delay: editMaterializationDelay
            )
        } else if let currentOverview {
            projectTracks[trackIndex].waveformOverview = WaveformOverview(
                duration: editedDuration,
                bins: currentOverview.bins
            )
        }

        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        reloadPlaybackFromProjectTracks(
            preserveProgress: true,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()
        updateStatus("healed adjacent clips")

        if let editedAudioTimeline {
            materializeEditedTimeline(
                trackID: trackID,
                timeline: editedAudioTimeline,
                editRevision: editRevision,
                status: "healed adjacent clips",
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay,
                animateWaveformTransition: false
            )
        }
    }

    private func slipClipContents(direction: Int) {
        guard
            direction != 0,
            let target = editableClipSlipTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            updateStatus("select a clip to slip")
            return
        }

        let trackIndex = target.trackIndex
        let trackID = projectTracks[trackIndex].id
        let currentOverview = projectTracks[trackIndex].waveformOverview
        let undoSnapshot = captureProjectTrackUndoSnapshot(
            restoreProgress: playbackController.snapshot().progress
        )

        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
        let appliedFrameDelta: Int
        let appliedSampleRate: Double
        if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
            let requestedFrameDelta = Int((currentFileTimeline.sourceSampleRate * 0.05).rounded()) * direction
            var timeline = currentFileTimeline
            appliedFrameDelta = timeline.slipClip(
                AudioFileEditTimeline.ClipRange(
                    startProgress: target.editSelection.startProgress,
                    endProgress: target.editSelection.endProgress
                ),
                byFrameCount: requestedFrameDelta
            )
            guard appliedFrameDelta != 0 else {
                updateStatus("clip is at source edge")
                return
            }
            appliedSampleRate = currentFileTimeline.sourceSampleRate
            editedAudioTimeline = nil
            editedFileTimeline = timeline
        } else if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            let requestedFrameDelta = Int((currentTimeline.sourceAudioBuffer.sampleRate * 0.05).rounded()) * direction
            var timeline = currentTimeline
            appliedFrameDelta = timeline.slipClip(
                AudioEditTimeline.ClipRange(
                    startProgress: target.editSelection.startProgress,
                    endProgress: target.editSelection.endProgress
                ),
                byFrameCount: requestedFrameDelta
            )
            guard appliedFrameDelta != 0 else {
                updateStatus("clip is at source edge")
                return
            }
            appliedSampleRate = currentTimeline.sourceAudioBuffer.sampleRate
            editedAudioTimeline = timeline
            editedFileTimeline = nil
        } else {
            updateStatus("track is not ready to slip")
            return
        }

        editUndoStack.append(.projectTracks(undoSnapshot))
        cancelEditMaterialization(for: trackID)
        projectTracks[trackIndex].editRevision += 1
        let editRevision = projectTracks[trackIndex].editRevision
        applyEditedTimelineState(
            trackIndex: trackIndex,
            editedAudioTimeline: editedAudioTimeline,
            editedFileTimeline: editedFileTimeline,
            editedDuration: editedFileTimeline?.duration ?? editedAudioTimeline?.duration ?? 0
        )

        if let editedFileTimeline {
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    for: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trackID,
                fileTimeline: editedFileTimeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision
            )
        } else if let currentOverview {
            projectTracks[trackIndex].waveformOverview = WaveformOverview(
                duration: editedAudioTimeline?.duration ?? currentOverview.duration,
                bins: currentOverview.bins
            )
            cancelEditWaveformRefinement(for: trackID)
        }

        activeTrackID = trackID
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: true)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(
            preserveProgress: true,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()
        let slippedDuration = abs(Double(appliedFrameDelta)) / max(appliedSampleRate, 1)
        updateStatus("slipped clip \(direction < 0 ? "left" : "right") \(formatDuration(slippedDuration))")

        if let editedAudioTimeline {
            materializeEditedTimeline(
                trackID: trackID,
                timeline: editedAudioTimeline,
                editRevision: editRevision,
                status: "slipped clip \(formatDuration(slippedDuration))",
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay,
                animateWaveformTransition: false
            )
        }
    }

    private func nudgeSelection(direction: Int) {
        guard
            let selection = selectedTimelineRange,
            selection.durationProgress > 0
        else {
            updateStatus("select time to nudge")
            return
        }

        let projectDuration = projectSelectionDuration
        guard projectDuration > 0 else {
            updateStatus("load audio before nudging")
            return
        }

        let nudgeDuration: TimeInterval = 0.05
        let deltaProgress = Double(direction) * nudgeDuration / projectDuration
        let selectionDuration = selection.durationProgress
        let nextStart = min(max(selection.startProgress + deltaProgress, 0), max(1 - selectionDuration, 0))
        let nudgedSelection = TimelineSelection(
            startProgress: nextStart,
            endProgress: nextStart + selectionDuration,
            trackID: selection.trackID
        )
        selectedTimelineRange = nudgedSelection
        timelineSurface.displaySelection(nudgedSelection)
        updateEffectCommandState()
        updateStatus("nudged selection \(direction < 0 ? "left" : "right") \(formatDuration(nudgeDuration))")
    }

    private func snapSelectionToPlayheadEdgesOrSilence() {
        if let candidate = activeDeadAirCandidate() {
            selectedTimelineRange = candidate.displaySelection
            activeTrackID = candidate.trackID
            timelineSurface.displaySelection(candidate.displaySelection)
            timelineSurface.focusSelection(candidate.displaySelection)
            updateEffectCommandState()
            updateStatus("snapped selection to silence candidate")
            return
        }

        guard
            let selection = selectedTimelineRange,
            selection.durationProgress > 0
        else {
            updateStatus("select time to snap")
            return
        }

        let projectDuration = projectSelectionDuration
        guard projectDuration > 0 else {
            updateStatus("load audio before snapping")
            return
        }

        var snappedSelection: TimelineSelection?
        if
            let trackIndex = trackIndex(for: selection),
            projectTracks.indices.contains(trackIndex)
        {
            let track = projectTracks[trackIndex]
            let trackDuration = trackDuration(for: track)
            if trackDuration > 0 {
                let trackDurationProgress = trackDuration / projectDuration
                let boundaryProgresses = timelineClipRanges(for: track).flatMap { clipRange in
                    [
                        clipRange.startProgress * trackDurationProgress,
                        clipRange.endProgress * trackDurationProgress,
                    ]
                }
                if !boundaryProgresses.isEmpty {
                    let snappedStart = nearestProgress(to: selection.startProgress, in: boundaryProgresses)
                    let snappedEnd = nearestProgress(to: selection.endProgress, in: boundaryProgresses)
                    if snappedEnd > snappedStart {
                        snappedSelection = TimelineSelection(
                            startProgress: snappedStart,
                            endProgress: snappedEnd,
                            trackID: track.id
                        )
                    }
                }
            }
        }

        if snappedSelection == nil {
            let playheadProgress = Double(min(max(playbackController.snapshot().progress, 0), 1))
            let startDistance = abs(selection.startProgress - playheadProgress)
            let endDistance = abs(selection.endProgress - playheadProgress)
            snappedSelection = startDistance <= endDistance ?
                TimelineSelection(
                    startProgress: playheadProgress,
                    endProgress: selection.endProgress,
                    trackID: selection.trackID
                ) :
                TimelineSelection(
                    startProgress: selection.startProgress,
                    endProgress: playheadProgress,
                    trackID: selection.trackID
                )
        }

        guard let snappedSelection, snappedSelection.durationProgress > 0 else {
            updateStatus("no snap target found")
            return
        }

        selectedTimelineRange = snappedSelection
        timelineSurface.displaySelection(snappedSelection)
        timelineSurface.focusSelection(snappedSelection)
        updateEffectCommandState()
        updateStatus("snapped selection")
    }

    private func nearestProgress(to progress: Double, in candidates: [Double]) -> Double {
        candidates.min { lhs, rhs in
            abs(lhs - progress) < abs(rhs - progress)
        } ?? progress
    }

    private func selectTimeAcrossLinkedTracks() {
        guard
            let selection = selectedTimelineRange,
            selection.durationProgress > 0,
            let trackIndex = trackIndex(for: selection),
            projectTracks.indices.contains(trackIndex)
        else {
            updateStatus("select time on a linked track")
            return
        }

        guard let editGroupID = projectTracks[trackIndex].editGroupID else {
            updateStatus("track has no linked edit group")
            return
        }

        let linkedTrackIDs = Set(projectTracks.filter { $0.editGroupID == editGroupID }.map(\.id))
        guard !linkedTrackIDs.isEmpty else {
            updateStatus("no linked tracks found")
            return
        }

        selectedTrackID = projectTracks[trackIndex].id
        selectedTrackIDs = linkedTrackIDs
        activeTrackID = projectTracks[trackIndex].id
        editScope = .group
        publishSelectedTracksToTimeline()
        refreshTrackControls()
        updateEditScopeHint()
        updateEffectCommandState()
        updateStatus("selected time across \(linkedTrackIDs.count) linked \(linkedTrackIDs.count == 1 ? "track" : "tracks")")
    }

    private func selectAllClipsOnTrack() {
        guard
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            updateStatus("select a track")
            return
        }

        let trackID = projectTracks[trackIndex].id
        let selection = fullTrackDisplaySelection(for: trackID)
        selectedTimelineRange = selection
        activeTrackID = trackID
        selectedTrackID = nil
        selectedTrackIDs.removeAll()
        publishSelectedTracksToTimeline()
        refreshTrackControls()
        timelineSurface.displaySelection(selection)
        timelineSurface.focusSelection(selection)
        updateEffectCommandState()
        updateStatus("selected all clips on track")
    }

    private func silenceCleanupTarget() -> EditableSelectionTarget? {
        if let target = currentEditableSelectionTarget() {
            return target
        }

        guard
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            return nil
        }

        let trackID = projectTracks[trackIndex].id
        return EditableSelectionTarget(
            trackIndex: trackIndex,
            displaySelection: fullTrackDisplaySelection(for: trackID),
            editSelection: fullTrackEditSelection(for: trackID)
        )
    }

    private func reviewDeadAir() {
        guard
            let target = silenceCleanupTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            updateStatus("select a track to review")
            return
        }

        let trackIndex = target.trackIndex
        let track = projectTracks[trackIndex]
        let sourceURL = track.sourceURL
        let trackID = track.id
        let editRevision = track.editRevision
        let audioTimeline = track.audioTimeline
        let fileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex)
        let displaySelection = target.displaySelection
        let editSelection = target.editSelection
        let configuration = AudioSilenceAnalyzer.Configuration.podcastCleanup

        clearDeadAirReview(publish: true)
        updateStatus("reviewing shorten silence")
        Task { [weak self, sourceURL, audioTimeline, fileTimeline, displaySelection, editSelection, trackID, editRevision, configuration] in
            let result = await Task.detached(priority: .userInitiated) {
                try Self.detectDeadAirReviewCandidates(
                    sourceURL: sourceURL,
                    audioTimeline: audioTimeline,
                    fileTimeline: fileTimeline,
                    displaySelection: displaySelection,
                    editSelection: editSelection,
                    trackID: trackID,
                    trackEditRevision: editRevision,
                    configuration: configuration
                )
            }.result

            guard let self else {
                return
            }

            switch result {
            case let .success(reviewResult):
                self.publishDeadAirReviewResult(
                    reviewResult,
                    trackID: trackID,
                    expectedEditRevision: editRevision
                )
            case let .failure(error):
                self.updateStatus("shorten silence review failed: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func detectDeadAirReviewCandidates(
        sourceURL: URL,
        audioTimeline: AudioEditTimeline?,
        fileTimeline: AudioFileEditTimeline?,
        displaySelection: TimelineSelection,
        editSelection: TimelineSelection,
        trackID: UUID,
        trackEditRevision: Int,
        configuration: AudioSilenceAnalyzer.Configuration
    ) throws -> DeadAirReviewResult {
        let renderedBuffer: DecodedAudioBuffer
        let timelineFrameCount: Int

        if let fileTimeline {
            let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
            renderedBuffer = fileTimeline.audioTimeline(sourceBuffer: sourceBuffer).render(selection: editSelection)
            timelineFrameCount = fileTimeline.frameCount
        } else if let audioTimeline {
            renderedBuffer = audioTimeline.render(selection: editSelection)
            timelineFrameCount = audioTimeline.frameCount
        } else {
            let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
            let timeline = AudioEditTimeline(sourceBuffer: sourceBuffer)
            renderedBuffer = timeline.render(selection: editSelection)
            timelineFrameCount = timeline.frameCount
        }

        guard timelineFrameCount > 0, renderedBuffer.frameCount > 0 else {
            return DeadAirReviewResult(candidates: [], detectedRegionCount: 0)
        }

        let detectedRegions = AudioSilenceAnalyzer.detectSilence(
            in: renderedBuffer,
            configuration: configuration
        )
        let localDeletionRanges = AudioSilenceAnalyzer.deletionRanges(
            for: detectedRegions,
            sampleRate: renderedBuffer.sampleRate,
            configuration: configuration
        )
        let selectionStartFrame = min(
            max(Int((editSelection.startProgress * Double(timelineFrameCount)).rounded(.down)), 0),
            timelineFrameCount
        )
        let renderedFrameCount = max(renderedBuffer.frameCount, 1)
        let timelineFrameCountDouble = Double(timelineFrameCount)

        let candidates = localDeletionRanges.compactMap { localRange -> DeadAirReviewCandidate? in
            let lowerBound = min(max(selectionStartFrame + localRange.lowerBound, 0), timelineFrameCount)
            let upperBound = min(max(selectionStartFrame + localRange.upperBound, lowerBound), timelineFrameCount)
            guard lowerBound < upperBound else {
                return nil
            }

            let localStartFraction = min(max(Double(localRange.lowerBound) / Double(renderedFrameCount), 0), 1)
            let localEndFraction = min(max(Double(localRange.upperBound) / Double(renderedFrameCount), localStartFraction), 1)
            let displayStart = displaySelection.startProgress +
                displaySelection.durationProgress * localStartFraction
            let displayEnd = displaySelection.startProgress +
                displaySelection.durationProgress * localEndFraction
            let candidateDisplaySelection = TimelineSelection(
                startProgress: displayStart,
                endProgress: displayEnd,
                trackID: trackID
            )
            let candidateEditSelection = TimelineSelection(
                startProgress: Double(lowerBound) / timelineFrameCountDouble,
                endProgress: Double(upperBound) / timelineFrameCountDouble,
                trackID: trackID
            )
            guard candidateDisplaySelection.durationProgress > 0, candidateEditSelection.durationProgress > 0 else {
                return nil
            }

            let estimatedRemovedDuration = renderedBuffer.sampleRate > 0 ?
                Double(localRange.count) / renderedBuffer.sampleRate :
                0
            let confidence = silenceReviewConfidence(
                estimatedRemovedDuration: estimatedRemovedDuration
            )
            let reason = silenceReviewReason(
                estimatedRemovedDuration: estimatedRemovedDuration
            )

            return DeadAirReviewCandidate(
                id: UUID(),
                trackID: trackID,
                trackEditRevision: trackEditRevision,
                displaySelection: candidateDisplaySelection,
                editSelection: candidateEditSelection,
                frameRange: lowerBound..<upperBound,
                confidence: confidence,
                reason: reason,
                estimatedRemovedDuration: estimatedRemovedDuration
            )
        }

        return DeadAirReviewResult(
            candidates: candidates,
            detectedRegionCount: detectedRegions.count
        )
    }

    private nonisolated static func silenceReviewConfidence(
        estimatedRemovedDuration: TimeInterval
    ) -> Float {
        guard estimatedRemovedDuration.isFinite, estimatedRemovedDuration > 0 else {
            return 0
        }

        let durationScore = min(max((estimatedRemovedDuration - 0.18) / 1.2, 0), 1)
        return Float(min(0.98, 0.72 + durationScore * 0.26))
    }

    private nonisolated static func silenceReviewReason(
        estimatedRemovedDuration: TimeInterval
    ) -> String {
        if estimatedRemovedDuration >= 1.0 {
            return "long continuous silence"
        }
        if estimatedRemovedDuration >= 0.45 {
            return "clear pause"
        }
        return "short pause"
    }

    private func deadAirCandidateStatusText(
        _ candidate: DeadAirReviewCandidate,
        index: Int,
        total: Int
    ) -> String {
        let duration = formatDuration(candidate.estimatedRemovedDuration)
        let confidence = Int((candidate.confidence * 100).rounded())
        return "silence \(index + 1)/\(total): \(duration), \(confidence)% confidence, \(candidate.reason)"
    }

    private func currentSilenceReviewState() -> SoundtimeProject.SilenceReviewState? {
        guard !deadAirCandidates.isEmpty else {
            return nil
        }

        return SoundtimeProject.SilenceReviewState(
            candidates: deadAirCandidates.map { candidate in
                SoundtimeProject.SilenceReviewCandidate(
                    id: candidate.id,
                    trackID: candidate.trackID,
                    trackEditRevision: candidate.trackEditRevision,
                    displaySelection: projectSelectionRange(candidate.displaySelection),
                    editSelection: projectSelectionRange(candidate.editSelection),
                    frameStart: candidate.frameRange.lowerBound,
                    frameEnd: candidate.frameRange.upperBound,
                    confidence: candidate.confidence,
                    reason: candidate.reason,
                    estimatedRemovedDuration: candidate.estimatedRemovedDuration
                )
            },
            activeCandidateID: activeDeadAirCandidateID
        )
    }

    private func restoreSilenceReviewState(_ state: SoundtimeProject.SilenceReviewState?) {
        guard let state, !state.candidates.isEmpty else {
            clearDeadAirReview(publish: true)
            return
        }

        let restoredCandidates = state.candidates.compactMap { candidate -> DeadAirReviewCandidate? in
            guard
                let track = projectTracks.first(where: { $0.id == candidate.trackID }),
                track.editRevision == candidate.trackEditRevision,
                candidate.frameEnd > candidate.frameStart
            else {
                return nil
            }

            let displaySelection = timelineSelection(from: candidate.displaySelection)
            let editSelection = timelineSelection(from: candidate.editSelection)
            guard displaySelection.durationProgress > 0, editSelection.durationProgress > 0 else {
                return nil
            }

            return DeadAirReviewCandidate(
                id: candidate.id,
                trackID: candidate.trackID,
                trackEditRevision: candidate.trackEditRevision,
                displaySelection: displaySelection,
                editSelection: editSelection,
                frameRange: candidate.frameStart..<candidate.frameEnd,
                confidence: candidate.confidence,
                reason: candidate.reason,
                estimatedRemovedDuration: candidate.estimatedRemovedDuration
            )
        }

        guard !restoredCandidates.isEmpty else {
            clearDeadAirReview(publish: true)
            return
        }

        deadAirCandidates = restoredCandidates
        activeDeadAirCandidateID = state.activeCandidateID.flatMap { activeID in
            restoredCandidates.contains { $0.id == activeID } ? activeID : nil
        } ?? restoredCandidates.first?.id
        publishDeadAirCandidateRegions()
        updateEffectCommandState()
    }

    private func projectSelectionRange(
        _ selection: TimelineSelection
    ) -> SoundtimeProject.TimelineSelectionRange {
        SoundtimeProject.TimelineSelectionRange(
            startProgress: selection.startProgress,
            endProgress: selection.endProgress,
            trackID: selection.trackID
        )
    }

    private func timelineSelection(
        from range: SoundtimeProject.TimelineSelectionRange
    ) -> TimelineSelection {
        TimelineSelection(
            startProgress: range.startProgress,
            endProgress: range.endProgress,
            trackID: range.trackID
        )
    }

    private func publishDeadAirReviewResult(
        _ result: DeadAirReviewResult,
        trackID: UUID,
        expectedEditRevision: Int
    ) {
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            projectTracks[trackIndex].editRevision == expectedEditRevision
        else {
            updateStatus("shorten silence review skipped: track changed")
            return
        }

        guard !result.candidates.isEmpty else {
            clearDeadAirReview(publish: true)
            updateStatus("no removable silence found")
            return
        }

        deadAirCandidates = result.candidates
        activeDeadAirCandidateID = result.candidates.first?.id
        publishDeadAirCandidateRegions()
        updateEffectCommandState()
        let candidateWord = result.candidates.count == 1 ? "candidate" : "candidates"
        let totalRemovedDuration = result.candidates.reduce(0) { total, candidate in
            total + candidate.estimatedRemovedDuration
        }
        let totalDuration = formatDuration(totalRemovedDuration)
        if let firstCandidate = result.candidates.first {
            updateStatus(
                "found \(result.candidates.count) silence \(candidateWord), " +
                    "\(totalDuration) removable - " +
                    deadAirCandidateStatusText(firstCandidate, index: 0, total: result.candidates.count)
            )
        } else {
            updateStatus("found \(result.candidates.count) silence \(candidateWord), \(totalDuration) removable")
        }
    }

    private func activeDeadAirCandidate() -> DeadAirReviewCandidate? {
        guard let activeDeadAirCandidateID else {
            return deadAirCandidates.first
        }
        return deadAirCandidates.first { $0.id == activeDeadAirCandidateID } ?? deadAirCandidates.first
    }

    private func stepActiveDeadAirCandidate(by offset: Int) {
        guard !deadAirCandidates.isEmpty else {
            updateStatus("no silence candidates")
            return
        }

        let currentIndex = activeDeadAirCandidateID.flatMap { activeID in
            deadAirCandidates.firstIndex { $0.id == activeID }
        } ?? 0
        let candidateCount = deadAirCandidates.count
        let nextIndex = (currentIndex + offset + candidateCount) % candidateCount
        let candidate = deadAirCandidates[nextIndex]
        activeDeadAirCandidateID = candidate.id
        publishDeadAirCandidateRegions()
        timelineSurface.focusSelection(candidate.displaySelection)
        updateEffectCommandState()
        updateStatus(deadAirCandidateStatusText(candidate, index: nextIndex, total: candidateCount))
    }

    private func publishDeadAirCandidateRegions() {
        let activeID = activeDeadAirCandidate()?.id
        let regions = deadAirCandidates.map { candidate in
            TimelineRenderState.CandidateRegion(
                id: candidate.id,
                selection: candidate.displaySelection,
                isActive: candidate.id == activeID
            )
        }
        timelineSurface.displayCandidateRegions(regions)
    }

    private func clearDeadAirReview(publish: Bool) {
        deadAirAuditionStopTask?.cancel()
        deadAirAuditionStopTask = nil
        deadAirCandidates.removeAll()
        activeDeadAirCandidateID = nil
        if publish {
            timelineSurface.displayCandidateRegions([])
        }
        updateEffectCommandState()
    }

    private func acceptActiveDeadAirCandidate() {
        guard let candidate = activeDeadAirCandidate() else {
            updateStatus("no silence candidate to accept")
            return
        }
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == candidate.trackID }),
            projectTracks[trackIndex].editRevision == candidate.trackEditRevision
        else {
            clearDeadAirReview(publish: true)
            updateStatus("silence candidate expired; review again")
            return
        }

        let target = EditableSelectionTarget(
            trackIndex: trackIndex,
            displaySelection: candidate.displaySelection,
            editSelection: candidate.editSelection
        )
        clearDeadAirReview(publish: true)
        performTransactionalRangeEdit(
            kind: .rippleDelete,
            scope: .track,
            target: target
        )
    }

    private func acceptHighConfidenceDeadAirCandidates() {
        let eligibleCandidates = deadAirCandidates.filter {
            $0.confidence >= highConfidenceSilenceThreshold
        }
        guard !eligibleCandidates.isEmpty else {
            updateStatus("no high-confidence silence candidates")
            return
        }

        guard let firstCandidate = eligibleCandidates.first else {
            updateStatus("no high-confidence silence candidates")
            return
        }
        guard eligibleCandidates.allSatisfy({ $0.trackID == firstCandidate.trackID }) else {
            updateStatus("high-confidence candidates span tracks; review individually")
            return
        }
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == firstCandidate.trackID }),
            projectTracks[trackIndex].editRevision == firstCandidate.trackEditRevision
        else {
            clearDeadAirReview(publish: true)
            updateStatus("silence candidates expired; review again")
            return
        }

        let frameRanges = eligibleCandidates.map(\.frameRange)
        let deletedFrameCount = frameRanges.reduce(0) { total, frameRange in
            total + frameRange.count
        }
        let deletedDuration = eligibleCandidates.reduce(0) { total, candidate in
            total + candidate.estimatedRemovedDuration
        }
        let cleanupResult = SilenceCleanupResult(
            frameRanges: frameRanges,
            detectedRegionCount: eligibleCandidates.count,
            deletedFrameCount: deletedFrameCount,
            deletedDuration: deletedDuration
        )

        clearDeadAirReview(publish: true)
        applySilenceCleanupResult(
            cleanupResult,
            trackID: firstCandidate.trackID,
            expectedEditRevision: firstCandidate.trackEditRevision
        )
    }

    private func rejectActiveDeadAirCandidate() {
        guard let candidate = activeDeadAirCandidate(),
              let candidateIndex = deadAirCandidates.firstIndex(where: { $0.id == candidate.id })
        else {
            updateStatus("no silence candidate to reject")
            return
        }

        deadAirCandidates.remove(at: candidateIndex)
        activeDeadAirCandidateID = deadAirCandidates.indices.contains(candidateIndex) ?
            deadAirCandidates[candidateIndex].id :
            deadAirCandidates.first?.id
        if deadAirCandidates.isEmpty {
            clearDeadAirReview(publish: true)
            updateStatus("shorten silence review complete")
        } else {
            publishDeadAirCandidateRegions()
            updateEffectCommandState()
            updateStatus("rejected silence candidate")
        }
    }

    private func auditionActiveDeadAirCandidate() {
        guard let candidate = activeDeadAirCandidate() else {
            updateStatus("no silence candidate to audition")
            return
        }
        guard playbackController.hasSource else {
            updateStatus("load audio before auditioning")
            return
        }

        let projectDuration = projectSelectionDuration
        guard projectDuration > 0 else {
            updateStatus("cannot audition without project duration")
            return
        }

        let preRoll: TimeInterval = 1.25
        let postRoll: TimeInterval = 1.25
        let startTime = max(TimeInterval(candidate.displayStartProgress) * projectDuration - preRoll, 0)
        let endTime = min(TimeInterval(candidate.displayEndProgress) * projectDuration + postRoll, projectDuration)
        let startProgress = Float(startTime / projectDuration)
        let auditionDuration = max(endTime - startTime, 0.1)

        do {
            try playbackController.seek(toProgress: startProgress)
            if !playbackController.isPlaying {
                try playbackController.play()
            }
            refreshPlaybackProgress(syncPlayheadWhenPlaying: true)
            startPlaybackTimer()
            updateStatus("auditioning silence candidate")
        } catch {
            stopPlaybackTimer()
            updateStatus("audition failed: \(error.localizedDescription)")
            return
        }

        deadAirAuditionStopTask?.cancel()
        deadAirAuditionStopTask = Task { [weak self, candidateID = candidate.id, auditionDuration] in
            try? await Task.sleep(nanoseconds: UInt64(auditionDuration * 1_000_000_000))
            await MainActor.run { [weak self] in
                guard
                    let self,
                    self.activeDeadAirCandidateID == candidateID,
                    self.playbackController.isPlaying
                else {
                    return
                }
                self.playbackController.pause()
                self.refreshPlaybackProgress(syncPlayheadWhenPlaying: false)
                self.stopPlaybackTimer()
                self.updateStatus("auditioned silence candidate")
            }
        }
    }

    private func deleteDetectedSilence() {
        guard
            let target = silenceCleanupTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            updateStatus("select a track to clean")
            return
        }

        let trackIndex = target.trackIndex
        let track = projectTracks[trackIndex]
        let sourceURL = track.sourceURL
        let trackID = track.id
        let editRevision = track.editRevision
        let audioTimeline = track.audioTimeline
        let fileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex)
        let editSelection = target.editSelection
        let configuration = AudioSilenceAnalyzer.Configuration.podcastCleanup

        updateStatus("detecting silence")
        Task { [weak self, sourceURL, audioTimeline, fileTimeline, editSelection, trackID, editRevision, configuration] in
            let result = await Task.detached(priority: .userInitiated) {
                try Self.detectSilenceCleanupRanges(
                    sourceURL: sourceURL,
                    audioTimeline: audioTimeline,
                    fileTimeline: fileTimeline,
                    editSelection: editSelection,
                    configuration: configuration
                )
            }.result

            guard let self else {
                return
            }

            switch result {
            case let .success(cleanupResult):
                self.applySilenceCleanupResult(
                    cleanupResult,
                    trackID: trackID,
                    expectedEditRevision: editRevision
                )
            case let .failure(error):
                self.updateStatus("silence cleanup failed: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func detectSilenceCleanupRanges(
        sourceURL: URL,
        audioTimeline: AudioEditTimeline?,
        fileTimeline: AudioFileEditTimeline?,
        editSelection: TimelineSelection,
        configuration: AudioSilenceAnalyzer.Configuration
    ) throws -> SilenceCleanupResult {
        let renderedBuffer: DecodedAudioBuffer
        let timelineFrameCount: Int
        let timelineSampleRate: Double

        if let fileTimeline {
            let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
            renderedBuffer = fileTimeline.audioTimeline(sourceBuffer: sourceBuffer).render(selection: editSelection)
            timelineFrameCount = fileTimeline.frameCount
            timelineSampleRate = fileTimeline.sourceSampleRate
        } else if let audioTimeline {
            renderedBuffer = audioTimeline.render(selection: editSelection)
            timelineFrameCount = audioTimeline.frameCount
            timelineSampleRate = audioTimeline.sourceAudioBuffer.sampleRate
        } else {
            let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
            let timeline = AudioEditTimeline(sourceBuffer: sourceBuffer)
            renderedBuffer = timeline.render(selection: editSelection)
            timelineFrameCount = timeline.frameCount
            timelineSampleRate = sourceBuffer.sampleRate
        }

        let detectedRegions = AudioSilenceAnalyzer.detectSilence(
            in: renderedBuffer,
            configuration: configuration
        )
        let localDeletionRanges = AudioSilenceAnalyzer.deletionRanges(
            for: detectedRegions,
            sampleRate: renderedBuffer.sampleRate,
            configuration: configuration
        )
        let selectionStartFrame = min(
            max(Int((editSelection.startProgress * Double(timelineFrameCount)).rounded(.down)), 0),
            timelineFrameCount
        )
        let frameRanges = localDeletionRanges.compactMap { localRange -> Range<Int>? in
            let lowerBound = min(max(selectionStartFrame + localRange.lowerBound, 0), timelineFrameCount)
            let upperBound = min(max(selectionStartFrame + localRange.upperBound, lowerBound), timelineFrameCount)
            guard lowerBound < upperBound else {
                return nil
            }
            return lowerBound..<upperBound
        }
        let deletedFrameCount = frameRanges.reduce(0) { total, range in
            total + range.count
        }
        let deletedDuration = timelineSampleRate > 0 ?
            Double(deletedFrameCount) / timelineSampleRate :
            0

        return SilenceCleanupResult(
            frameRanges: frameRanges,
            detectedRegionCount: detectedRegions.count,
            deletedFrameCount: deletedFrameCount,
            deletedDuration: deletedDuration
        )
    }

    private func applySilenceCleanupResult(
        _ result: SilenceCleanupResult,
        trackID: UUID,
        expectedEditRevision: Int
    ) {
        guard !result.frameRanges.isEmpty, result.deletedFrameCount > 0 else {
            updateStatus("no removable silence found")
            return
        }
        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            projectTracks[trackIndex].editRevision == expectedEditRevision
        else {
            updateStatus("silence cleanup skipped: track changed")
            return
        }

        let snapshot = playbackController.snapshot()
        let undoSnapshot = captureProjectTrackUndoSnapshot(
            restoreProgress: snapshot.progress
        )

        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
        let editedDuration: TimeInterval
        var removedFrameCount = 0

        if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            for frameRange in result.frameRanges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
                removedFrameCount += timeline.delete(frameRange: frameRange)
            }
            editedAudioTimeline = nil
            editedFileTimeline = timeline
            editedDuration = timeline.duration
        } else if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            var timeline = currentTimeline
            for frameRange in result.frameRanges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
                removedFrameCount += timeline.delete(frameRange: frameRange)
            }
            editedAudioTimeline = timeline
            editedFileTimeline = nil
            editedDuration = timeline.duration
        } else {
            updateStatus("track is not ready to clean")
            return
        }

        guard removedFrameCount > 0 else {
            updateStatus("no removable silence found")
            return
        }

        editUndoStack.append(.projectTracks(undoSnapshot))
        cancelEditMaterialization(for: trackID)
        projectTracks[trackIndex].editRevision += 1
        let editRevision = projectTracks[trackIndex].editRevision
        applyEditedTimelineState(
            trackIndex: trackIndex,
            editedAudioTimeline: editedAudioTimeline,
            editedFileTimeline: editedFileTimeline,
            editedDuration: editedDuration
        )

        let currentOverview = projectTracks[trackIndex].waveformOverview
        if let editedFileTimeline {
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    for: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trackID,
                fileTimeline: editedFileTimeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision,
                delay: editMaterializationDelay
            )
        } else if let currentOverview {
            projectTracks[trackIndex].waveformOverview = WaveformOverview(
                duration: editedDuration,
                bins: currentOverview.bins
            )
        }

        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(
            preserveProgress: true,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()
        let statusDuration = formatDuration(Double(removedFrameCount) / max(projectTracks[trackIndex].fileTimeline?.sourceSampleRate ?? projectTracks[trackIndex].audioTimeline?.sourceAudioBuffer.sampleRate ?? 1, 1))
        updateStatus(
            "deleted \(statusDuration) silence in \(result.detectedRegionCount) " +
                "\(result.detectedRegionCount == 1 ? "gap" : "gaps")"
        )

        if let editedAudioTimeline {
            materializeEditedTimeline(
                trackID: trackID,
                timeline: editedAudioTimeline,
                editRevision: editRevision,
                status: "deleted silence",
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay,
                animateWaveformTransition: false
            )
        }
    }

    private func deleteSelectedTrack() {
        guard
            let primaryTrackID = selectedTrackID ?? selectedTrackIDs.first,
            projectTracks.contains(where: { $0.id == primaryTrackID })
        else {
            return
        }
        let trackIDsToDelete = selectedTrackIDs.isEmpty ? [primaryTrackID] : selectedTrackIDs
        let indexedTrackIDsToDelete = projectTracks.enumerated()
            .filter { trackIDsToDelete.contains($0.element.id) }
            .map { (index: $0.offset, id: $0.element.id, name: $0.element.name) }
        guard !indexedTrackIDsToDelete.isEmpty else {
            return
        }

        let snapshot = captureProjectTrackUndoSnapshot(
            selectedTrackID: primaryTrackID,
            restoreProgress: nil
        )
        editUndoStack.append(.projectTracks(snapshot))

        let deletedTrackNames = indexedTrackIDsToDelete.map(\.name)
        for trackID in indexedTrackIDsToDelete.map(\.id) {
            cancelEditMaterialization(for: trackID)
            projectEditGraph.removeArrangement(for: trackID)
        }
        for trackIndex in indexedTrackIDsToDelete.map(\.index).sorted(by: >) {
            projectTracks.remove(at: trackIndex)
        }
        pruneProjectEditGraphToCurrentTracks()
        if projectTracks.isEmpty {
            activeTrackID = nil
        } else {
            let fallbackIndex = min(indexedTrackIDsToDelete.map(\.index).min() ?? 0, projectTracks.count - 1)
            activeTrackID = projectTracks[fallbackIndex].id
        }
        self.selectedTrackID = nil
        selectedTrackIDs.removeAll()
        trackSelectionAnchorID = nil
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        publishSelectedTracksToTimeline()
        syncActiveTrackFields()
        refreshProjectTimelineDisplay()
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        updateEffectCommandState()
        if deletedTrackNames.count == 1, let deletedTrackName = deletedTrackNames.first {
            updateStatus("deleted track \(deletedTrackName)")
        } else {
            updateStatus("deleted \(deletedTrackNames.count) tracks")
        }
    }

    private func cutSelection() {
        performTransactionalRangeEdit(kind: .cut, scope: .track)
    }

    private func copySelection() {
        reconcileTimelinePresentationBeforeEdit(reason: "copy")
        guard
            let target = currentEditableSelectionTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            return
        }

        timelineSurface.triggerSelectionCopyFlash()
        do {
            let command = try makeRangeEditCommand(
                kind: .cut,
                target: target,
                scope: .track
            )
            let plan = try EditTransactionPlanner.plan(
                command: command,
                currentRevision: projectEditRevision(),
                tracks: editTrackDescriptors(for: command)
            )
            let clipboard = try captureClipboard(command: command, plan: plan)
            audioClipboard = clipboard
            updateStatus("copied \(formatDuration(clipboardDuration(clipboard) ?? 0))")
            enrichClipboardInBackground(
                clipboard,
                command: command,
                plan: plan
            )
        } catch {
            updateStatus("copy failed: \(error.localizedDescription)")
        }
    }

    private func captureClipboard(
        command: EditCommand,
        plan: EditPlan
    ) throws -> AudioClipboard {
        guard
            let range = command.range,
            let trackEdit = plan.trackEdits.first(where: { $0.trackID == command.anchorTrackID }),
            let track = projectTracks.first(where: { $0.id == command.anchorTrackID })
        else {
            throw EditTransactionError.missingRange
        }
        guard case let .delete(frameRange) = trackEdit.mutation else {
            throw EditTransactionError.missingRange
        }

        let trackSelection = displaySelection(
            for: range,
            trackID: track.id,
            projectDuration: max(trackDuration(for: track), range.end.seconds)
        )

        if
            let arrangement = projectEditGraph.arrangement(for: track.id) ??
                mirroredTrackArrangement(for: track)
        {
            let fileTimeline = arrangement.timeline
            guard let fileClip = fileTimeline.clip(for: frameRange) else {
                throw EditTransactionError.noAudioInRange
            }
            let waveformOverview = selectedWaveformOverview(
                from: track.waveformOverview ?? track.sourceWaveformOverview,
                selection: trackSelection
            ) ?? WaveformOverview(duration: fileClip.duration, bins: [])
            return AudioClipboard(
                buffer: nil,
                waveformOverview: waveformOverview,
                fileClipSourceID: arrangement.sourceID,
                fileClipSourceURL: track.sourceURL,
                fileClip: fileClip
            )
        }

        if let audioTimeline = track.audioTimeline {
            guard let audioClip = audioTimeline.clip(for: frameRange) else {
                throw EditTransactionError.noAudioInRange
            }
            let waveformOverview = selectedWaveformOverview(
                from: track.waveformOverview ?? track.sourceWaveformOverview,
                selection: trackSelection
            ) ?? WaveformOverview(duration: audioClip.duration, bins: [])
            return AudioClipboard(
                buffer: nil,
                waveformOverview: waveformOverview,
                audioClip: audioClip
            )
        }

        throw EditTransactionError.uneditableTrack(track.id)
    }

    private func enrichClipboardInBackground(
        _ clipboard: AudioClipboard,
        command: EditCommand,
        plan: EditPlan
    ) {
        guard
            let trackEdit = plan.trackEdits.first(where: { $0.trackID == command.anchorTrackID }),
            case let .delete(frameRange) = trackEdit.mutation,
            let track = projectTracks.first(where: { $0.id == command.anchorTrackID })
        else {
            return
        }

        let selection = timelineSelection(
            for: frameRange,
            frameCount: max(
                track.fileTimeline?.frameCount ??
                    track.audioTimeline?.frameCount ??
                    track.decodedAudioBuffer?.frameCount ??
                    0,
                1
            ),
            trackID: track.id
        )
        let fileTimeline = projectEditGraph.arrangement(for: track.id)?.timeline ?? track.fileTimeline
        let audioTimeline = track.audioTimeline
        let sourceURL = track.sourceURL
        let clipboardID = clipboard.id

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let buffer: DecodedAudioBuffer
                if let audioTimeline {
                    buffer = audioTimeline.render(selection: selection)
                } else if let fileTimeline {
                    let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
                    buffer = fileTimeline.audioTimeline(sourceBuffer: sourceBuffer)
                        .render(selection: selection)
                } else {
                    throw EditTransactionError.uneditableTrack(command.anchorTrackID)
                }
                return AudioClipboard(
                    id: clipboardID,
                    buffer: buffer,
                    waveformOverview: WaveformOverviewBuilder.build(from: buffer),
                    audioClip: clipboard.audioClip,
                    fileClipSourceID: clipboard.fileClipSourceID,
                    fileClipSourceURL: clipboard.fileClipSourceURL,
                    fileClip: clipboard.fileClip
                )
            }.result

            guard let self, self.audioClipboard?.id == clipboardID else {
                return
            }
            if case let .success(enrichedClipboard) = result {
                self.audioClipboard = enrichedClipboard
            }
        }
    }

    private func timelineSelection(
        for frameRange: Range<Int>,
        frameCount: Int,
        trackID: UUID
    ) -> TimelineSelection {
        let denominator = Double(max(frameCount, 1))
        return TimelineSelection(
            startProgress: Double(frameRange.lowerBound) / denominator,
            endProgress: Double(frameRange.upperBound) / denominator,
            trackID: trackID
        )
    }

    private func editableFileTimeline(forTrackAt trackIndex: Int) throws -> AudioFileEditTimeline {
        if
            projectTracks.indices.contains(trackIndex),
            let arrangement = projectEditGraph.arrangement(for: projectTracks[trackIndex].id)
        {
            return arrangement.timeline
        }

        guard try normalizeEditableTrackIfPossible(trackIndex: trackIndex),
              let arrangement = projectEditGraph.arrangement(for: projectTracks[trackIndex].id)
        else {
            throw PlaybackError.noAudioLoaded
        }

        return arrangement.timeline
    }

    @discardableResult
    private func normalizeEditableTrackIfPossible(trackIndex: Int) throws -> Bool {
        guard projectTracks.indices.contains(trackIndex) else {
            return false
        }

        if hasNormalizedEditableTimeline(projectTracks[trackIndex]) {
            return true
        }

        let sourceURL = projectTracks[trackIndex].sourceURL
        guard let fileInfo = decodableWAVFileInfo(for: sourceURL) else {
            return false
        }

        let fileTimeline: AudioFileEditTimeline
        if
            let existingFileTimeline = projectTracks[trackIndex].fileTimeline,
            existingFileTimeline.isCompatible(with: fileInfo)
        {
            fileTimeline = existingFileTimeline
        } else if
            let audioTimeline = projectTracks[trackIndex].audioTimeline,
            audioTimeline.sourceAudioBuffer.frameCount == fileInfo.frameCount,
            abs(audioTimeline.sourceAudioBuffer.sampleRate - fileInfo.sampleRate) < 0.001,
            let compatibleTimeline = AudioFileEditTimeline(
                sourceFrameCount: fileInfo.frameCount,
                sourceSampleRate: fileInfo.sampleRate,
                playbackSegments: audioTimeline.playbackSegments
            ),
            compatibleTimeline.isCompatible(with: fileInfo)
        {
            fileTimeline = compatibleTimeline
        } else {
            fileTimeline = AudioFileEditTimeline(fileInfo: fileInfo)
        }

        let editableSource = editableAudioSource(
            originalURL: sourceURL,
            editableURL: sourceURL,
            formatOrigin: AudioAssetFormat.inferred(from: sourceURL),
            fileInfo: fileInfo,
            ownsEditableFile: projectTracks[trackIndex].ownsSourceFile
        )
        applyEditableTimelineMirror(
            trackIndex: trackIndex,
            source: editableSource,
            timeline: fileTimeline
        )
        return hasNormalizedEditableTimeline(projectTracks[trackIndex])
    }

    private func compatibleFileTimeline(
        from audioTimeline: AudioEditTimeline,
        sourceURL: URL
    ) -> AudioFileEditTimeline? {
        guard
            let fileInfo = decodableWAVFileInfo(for: sourceURL),
            audioTimeline.sourceAudioBuffer.frameCount == fileInfo.frameCount,
            abs(audioTimeline.sourceAudioBuffer.sampleRate - fileInfo.sampleRate) < 0.001,
            let fileTimeline = AudioFileEditTimeline(
                sourceFrameCount: fileInfo.frameCount,
                sourceSampleRate: fileInfo.sampleRate,
                playbackSegments: audioTimeline.playbackSegments
            ),
            fileTimeline.isCompatible(with: fileInfo)
        else {
            return nil
        }

        return fileTimeline
    }

    private func preferredFileTimelineForEditing(trackIndex: Int) throws -> AudioFileEditTimeline? {
        guard projectTracks.indices.contains(trackIndex) else {
            return nil
        }

        if let arrangement = projectEditGraph.arrangement(for: projectTracks[trackIndex].id)
        {
            return arrangement.timeline
        }

        guard try normalizeEditableTrackIfPossible(trackIndex: trackIndex) else {
            return nil
        }

        return projectEditGraph.arrangement(for: projectTracks[trackIndex].id)?.timeline
    }

    private func waveformOverview(
        for fileTimeline: AudioFileEditTimeline,
        sourceOverview: WaveformOverview?,
        fallbackOverview: WaveformOverview?
    ) -> WaveformOverview? {
        guard
            let sourceOverview = bestSourceWaveformOverview(
                sourceOverview: sourceOverview,
                fallbackOverview: fallbackOverview,
                fileTimeline: fileTimeline
            )
        else {
            return nil
        }

        return fileTimeline.waveformOverview(from: sourceOverview)
    }

    private func optimisticWaveformOverview(
        for fileTimeline: AudioFileEditTimeline,
        sourceOverview: WaveformOverview?,
        fallbackOverview: WaveformOverview?
    ) -> WaveformOverview? {
        guard
            let sourceOverview = bestSourceWaveformOverview(
                sourceOverview: sourceOverview,
                fallbackOverview: fallbackOverview,
                fileTimeline: fileTimeline
            )
        else {
            return nil
        }

        return fileTimeline.waveformOverview(from: overviewForOptimisticEdit(sourceOverview))
    }

    private func scheduleOptimisticDeleteWaveformOverviewUpdate(
        trackID: UUID,
        editRevision: Int,
        currentOverview: WaveformOverview?,
        editSelection: TimelineSelection,
        editedDuration: TimeInterval,
        editedFileTimeline: AudioFileEditTimeline?,
        sourceOverview: WaveformOverview?,
        minimumDisplayDelay: TimeInterval
    ) {
        let deleteGeneration = deleteAnimationGeneration
        let previewBinLimit = optimisticEditPreviewBinLimit
        let previewSamplesPerBin = optimisticEditPreviewSamplesPerBin
        let startedAt = CACurrentMediaTime()
        optimisticDeleteWaveformTasks.replaceTask(for: trackID) { requestID in
            Task { [weak self,
                    trackID,
                    editRevision,
                    currentOverview,
                    editSelection,
                    editedDuration,
                    editedFileTimeline,
                    sourceOverview,
                    previewBinLimit,
                    previewSamplesPerBin,
                    minimumDisplayDelay,
                    requestID,
                    deleteGeneration] in
                let optimisticOverview = await Task.detached(priority: .userInitiated) {
                    Self.makeOptimisticDeleteWaveformOverview(
                        currentOverview,
                        replacing: editSelection,
                        targetDuration: editedDuration,
                        previewBinLimit: previewBinLimit,
                        previewSamplesPerBin: previewSamplesPerBin
                    ) ?? Self.makeOptimisticFileTimelineWaveformOverview(
                        for: editedFileTimeline,
                        sourceOverview: sourceOverview,
                        fallbackOverview: currentOverview,
                        previewBinLimit: previewBinLimit,
                        previewSamplesPerBin: previewSamplesPerBin
                    )
                }.value

                let elapsed = CACurrentMediaTime() - startedAt
                let remainingDelay = minimumDisplayDelay - elapsed
                if remainingDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
                }
                guard !Task.isCancelled else {
                    self?.clearOptimisticDeleteWaveformTask(trackID: trackID, requestID: requestID)
                    return
                }

                await MainActor.run {
                    guard let self else {
                        return
                    }
                    guard self.optimisticDeleteWaveformTasks.isCurrent(
                        trackID,
                        generation: requestID
                    ) else {
                        return
                    }
                    defer {
                        self.clearOptimisticDeleteWaveformTask(trackID: trackID, requestID: requestID)
                    }
                    guard
                        self.deleteAnimationGeneration == deleteGeneration,
                        let trackIndex = self.projectTracks.firstIndex(where: { $0.id == trackID }),
                        self.projectTracks[trackIndex].editRevision == editRevision
                    else {
                        return
                    }

                    if let optimisticOverview {
                        self.projectTracks[trackIndex].waveformOverview = optimisticOverview
                    }
                    self.refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
                    self.updateProjectDisplayTiming()
                }
            }
        }
    }

    private func clearOptimisticDeleteWaveformTask(trackID: UUID, requestID: UUID) {
        optimisticDeleteWaveformTasks.finish(key: trackID, generation: requestID)
    }

    private nonisolated static func makeOptimisticDeleteWaveformOverview(
        _ overview: WaveformOverview?,
        replacing selection: TimelineSelection,
        targetDuration: TimeInterval,
        previewBinLimit: Int,
        previewSamplesPerBin: Int
    ) -> WaveformOverview? {
        guard let overview else {
            return nil
        }

        let sourceOverview = overviewForOptimisticEdit(
            overview,
            previewBinLimit: previewBinLimit,
            previewSamplesPerBin: previewSamplesPerBin
        )
        let binCount = sourceOverview.bins.count
        guard binCount > 0 else {
            return sourceOverview
        }

        let startIndex = min(max(Int((selection.startProgress * Double(binCount)).rounded(.down)), 0), binCount)
        let targetBinCount: Int
        if
            targetDuration.isFinite,
            targetDuration >= 0,
            sourceOverview.duration.isFinite,
            sourceOverview.duration > 0
        {
            targetBinCount = min(
                max(Int((Double(binCount) * targetDuration / sourceOverview.duration).rounded()), 0),
                binCount
            )
        } else {
            targetBinCount = max(
                binCount - Int((selection.durationProgress * Double(binCount)).rounded()),
                0
            )
        }
        let targetRemovedBinCount = min(max(binCount - targetBinCount, 0), binCount - startIndex)
        let endIndex = min(startIndex + targetRemovedBinCount, binCount)

        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount - (endIndex - startIndex))
        if startIndex > 0 {
            bins.append(contentsOf: sourceOverview.bins[0..<startIndex])
        }
        if endIndex < binCount {
            bins.append(contentsOf: sourceOverview.bins[endIndex..<binCount])
        }

        return WaveformOverview(duration: max(targetDuration, 0), bins: bins)
    }

    private nonisolated static func makeOptimisticFileTimelineWaveformOverview(
        for fileTimeline: AudioFileEditTimeline?,
        sourceOverview: WaveformOverview?,
        fallbackOverview: WaveformOverview?,
        previewBinLimit: Int,
        previewSamplesPerBin: Int
    ) -> WaveformOverview? {
        guard
            let fileTimeline,
            let sourceOverview = sourceOverview ?? fallbackOverview
        else {
            return nil
        }

        return fileTimeline.waveformOverview(
            from: overviewForOptimisticEdit(
                sourceOverview,
                previewBinLimit: previewBinLimit,
                previewSamplesPerBin: previewSamplesPerBin
            )
        )
    }

    private nonisolated static func overviewForOptimisticEdit(
        _ overview: WaveformOverview,
        previewBinLimit: Int,
        previewSamplesPerBin: Int
    ) -> WaveformOverview {
        guard overview.bins.count > previewBinLimit else {
            return overview
        }

        return sparseOverview(
            from: overview,
            targetBinCount: previewBinLimit,
            samplesPerBin: previewSamplesPerBin
        )
    }

    private nonisolated static func sparseOverview(
        from overview: WaveformOverview,
        targetBinCount: Int,
        samplesPerBin: Int
    ) -> WaveformOverview {
        let sourceBins = overview.bins
        let sourceBinCount = sourceBins.count
        let targetBinCount = min(max(targetBinCount, 1), sourceBinCount)
        let samplesPerBin = max(samplesPerBin, 1)
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(targetBinCount)

        for targetIndex in 0..<targetBinCount {
            let sourceStartIndex = targetIndex * sourceBinCount / targetBinCount
            let sourceEndIndex = max(sourceStartIndex + 1, (targetIndex + 1) * sourceBinCount / targetBinCount)
            let sourceSpan = sourceEndIndex - sourceStartIndex
            let stride = max(sourceSpan / samplesPerBin, 1)
            var accumulator = WaveformBinAccumulator()
            var sampledIndex = sourceStartIndex
            var sampledCount = 0

            while sampledIndex < sourceEndIndex, sampledCount < samplesPerBin {
                accumulator.addBin(sourceBins[sampledIndex])
                sampledIndex += stride
                sampledCount += 1
            }

            if sourceSpan > 1 {
                accumulator.addBin(sourceBins[sourceEndIndex - 1])
            }

            bins.append(accumulator.makeBin())
        }

        return WaveformOverview(duration: overview.duration, bins: bins)
    }

    @discardableResult
    private func pasteAudio() -> Double? {
        let transactionStartedAt = CACurrentMediaTime()
        timelineSurface.prepareForEditTransaction()
        reconcileTimelinePresentationBeforeEdit(
            preservesVisiblePlayheadTime: true,
            reason: "paste"
        )
        guard
            let clipboard = audioClipboard,
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            updateStatus("paste failed: clipboard or destination is unavailable")
            return nil
        }

        let track = projectTracks[trackIndex]
        let insertionTime = currentProjectPlayheadTime()
        let command = makePasteCommand(
            trackID: track.id,
            insertionTime: insertionTime,
            clipboardID: clipboard.id
        )
        let plannedAt = CACurrentMediaTime()

        do {
            let preparedCommit = try prepareRangeEditCommit(
                command: command,
                clipboard: clipboard
            )
            let preparedAt = CACurrentMediaTime()
            let insertedDuration = clipboardDuration(clipboard) ?? 0
            let pasteVisual = beginPasteVisualEffect(
                trackID: track.id,
                startTime: insertionTime.seconds,
                insertedDuration: insertedDuration,
                projectDurationBeforePaste: projectSelectionDuration,
                waveformOverview: clipboard.waveformOverview
            )
            let effectsSubmittedAt = CACurrentMediaTime()
            let visualResponseMilliseconds = (effectsSubmittedAt - transactionStartedAt) * 1_000
            let transaction = try commitPreparedProjectEdit(
                preparedCommit,
                keepsTransitionVisual: true
            )
            let committedAt = CACurrentMediaTime()
            scheduleTransactionVisualHandoff(
                generation: pasteVisual.generation,
                state: transaction.after,
                preservesLivePlayhead: command.wasPlaying
            )
            updateEffectCommandState()
            updateStatus("pasted \(formatDuration(insertedDuration))")
            let finishedAt = CACurrentMediaTime()
            latestEditTransactionStageTimings = EditTransactionStageTimings(
                planMilliseconds: (plannedAt - transactionStartedAt) * 1_000,
                prepareMilliseconds: (preparedAt - plannedAt) * 1_000,
                effectsMilliseconds: (effectsSubmittedAt - preparedAt) * 1_000,
                commitMilliseconds: (committedAt - effectsSubmittedAt) * 1_000,
                finalizeMilliseconds: (finishedAt - committedAt) * 1_000
            )
            return visualResponseMilliseconds
        } catch EditTransactionError.incompatibleClipboardSource,
                EditTransactionError.incompatibleClipboardClip {
            preparePortablePaste(
                clipboard: clipboard,
                command: command,
                destinationTrack: track
            )
            return nil
        } catch {
            updateStatus("paste failed: \(error.localizedDescription)")
            return nil
        }
    }


    private func duplicateRegion() {
        guard
            let target = currentEditableSelectionTarget(),
            projectTracks.indices.contains(target.trackIndex),
            target.editSelection.durationProgress > 0
        else {
            updateStatus("select audio to duplicate")
            return
        }

        let trackIndex = target.trackIndex
        let trackID = projectTracks[trackIndex].id
        let selectionToDuplicate = target.editSelection
        let insertionSelection = TimelineSelection(
            startProgress: selectionToDuplicate.endProgress,
            endProgress: selectionToDuplicate.endProgress,
            trackID: trackID
        )
        let currentOverview = projectTracks[trackIndex].waveformOverview
        let duplicatedOverview = selectedWaveformOverview(
            from: currentOverview,
            selection: selectionToDuplicate
        )
        let undoSnapshot = captureProjectTrackUndoSnapshot(
            restoreProgress: playbackController.snapshot().progress
        )

        if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            guard
                let clip = timeline.clip(for: selectionToDuplicate),
                let insertedFrameCount = timeline.replace(insertionSelection, with: clip),
                insertedFrameCount > 0
            else {
                updateStatus("duplicate failed")
                return
            }

            editUndoStack.append(.projectTracks(undoSnapshot))
            cancelEditMaterialization(for: trackID)
            projectTracks[trackIndex].editRevision += 1
            let editRevision = projectTracks[trackIndex].editRevision
            applyEditedTimelineState(
                trackIndex: trackIndex,
                editedAudioTimeline: nil,
                editedFileTimeline: timeline,
                editedDuration: timeline.duration
            )
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    currentOverview,
                    replacing: insertionSelection,
                    with: duplicatedOverview,
                    targetDuration: timeline.duration
                ) ??
                optimisticWaveformOverview(
                    for: timeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trackID,
                fileTimeline: timeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision
            )
            finishDuplicateRegion(
                trackID: trackID,
                duration: Double(insertedFrameCount) / max(timeline.sourceSampleRate, 1),
                preservePlaybackProgress: true
            )
            return
        }

        guard let currentTimeline = projectTracks[trackIndex].audioTimeline else {
            updateStatus("track is not ready to duplicate")
            return
        }

        var timeline = currentTimeline
        guard
            let clip = timeline.clip(for: selectionToDuplicate),
            let insertedFrameCount = timeline.replace(insertionSelection, with: clip),
            insertedFrameCount > 0
        else {
            updateStatus("duplicate failed")
            return
        }

        editUndoStack.append(.projectTracks(undoSnapshot))
        cancelEditMaterialization(for: trackID)
        projectTracks[trackIndex].editRevision += 1
        let editRevision = projectTracks[trackIndex].editRevision
        applyEditedTimelineState(
            trackIndex: trackIndex,
            editedAudioTimeline: timeline,
            editedFileTimeline: nil,
            editedDuration: timeline.duration
        )
        projectTracks[trackIndex].waveformOverview = optimisticWaveformOverview(
            currentOverview,
            replacing: insertionSelection,
            with: duplicatedOverview,
            targetDuration: timeline.duration
        )
        cancelEditWaveformRefinement(for: trackID)
        finishDuplicateRegion(
            trackID: trackID,
            duration: Double(insertedFrameCount) / max(timeline.sourceAudioBuffer.sampleRate, 1),
            preservePlaybackProgress: true
        )
        materializeEditedTimeline(
            trackID: trackID,
            timeline: timeline,
            editRevision: editRevision,
            status: "duplicated \(formatDuration(Double(insertedFrameCount) / max(timeline.sourceAudioBuffer.sampleRate, 1)))",
            preservePlaybackProgress: true,
            startDelay: editMaterializationDelay,
            animateWaveformTransition: false
        )
    }

    private func finishDuplicateRegion(
        trackID: UUID,
        duration: TimeInterval,
        preservePlaybackProgress: Bool
    ) {
        activeTrackID = trackID
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(
            preserveProgress: preservePlaybackProgress,
            resumeIfPlaying: playbackController.isPlaying
        )
        updateEffectCommandState()
        updateStatus("duplicated \(formatDuration(duration))")
    }

    @discardableResult
    private func performTransactionalRangeEdit(
        kind: EditCommandKind,
        scope: EditScope,
        target providedTarget: EditableSelectionTarget? = nil
    ) -> Double? {
        let transactionStartedAt = CACurrentMediaTime()
        timelineSurface.prepareForEditTransaction()
        let previousPlayheadTime = currentProjectPlayheadTime().seconds
        var deleteVisualGeneration: Int?
        reconcileTimelinePresentationBeforeEdit(reason: kind.rawValue)
        guard let target = providedTarget ?? currentEditableSelectionTarget() else {
            updateStatus(kind == .clearGap ? "select audio to clear" : "select audio to delete")
            return nil
        }

        do {
            let command = try makeRangeEditCommand(
                kind: kind,
                target: target,
                scope: scope
            )
            if kind != .clearGap {
                guard let range = command.range else {
                    throw EditTransactionError.missingRange
                }
                if !command.wasPlaying {
                    snapPlayheadVisuals(
                        toTimelineTime: range.start.seconds,
                        isPlaying: false,
                        synchronizesRenderer: true
                    )
                }
                deleteVisualGeneration = beginDeleteAnimationCriticalSection()
            }
            let plan = try EditTransactionPlanner.plan(
                command: command,
                currentRevision: projectEditRevision(),
                tracks: editTrackDescriptors(for: command)
            )
            let plannedAt = CACurrentMediaTime()
            let nextClipboard: AudioClipboard?
            if kind == .cut {
                nextClipboard = try captureClipboard(command: command, plan: plan)
            } else {
                nextClipboard = audioClipboard
            }
            let preparedCommit = try prepareRangeEditCommit(
                command: command,
                clipboard: nextClipboard,
                precomputedPlan: plan
            )
            let preparedAt = CACurrentMediaTime()

            if kind == .clearGap {
                _ = try commitPreparedProjectEdit(
                    preparedCommit,
                    keepsTransitionVisual: false
                )
                let committedAt = CACurrentMediaTime()
                timelineSurface.displaySelection(nil)
                timelineSurface.displayGainPreview(selection: nil, gain: 1)
                updateEffectCommandState()
                updateStatus(
                    transactionStatus(
                        verb: "cleared",
                        command: command,
                        trackCount: plan.trackEdits.count
                    )
                )
                let finishedAt = CACurrentMediaTime()
                latestEditTransactionStageTimings = EditTransactionStageTimings(
                    planMilliseconds: (plannedAt - transactionStartedAt) * 1_000,
                    prepareMilliseconds: (preparedAt - plannedAt) * 1_000,
                    commitMilliseconds: (committedAt - preparedAt) * 1_000,
                    finalizeMilliseconds: (finishedAt - committedAt) * 1_000
                )
                return (committedAt - transactionStartedAt) * 1_000
            }

            guard let range = command.range else {
                throw EditTransactionError.missingRange
            }
            guard let generation = deleteVisualGeneration else {
                throw EditTransactionError.missingRange
            }
            let deletionEffectRequests = try plan.trackEdits.map { trackEdit in
                guard
                    let trackIndex = preparedCommit.trackIndexesByID[trackEdit.trackID],
                    projectTracks.indices.contains(trackIndex)
                else {
                    throw EditTransactionError.missingTrack(trackEdit.trackID)
                }
                let track = projectTracks[trackIndex]
                let visualSelection = displaySelection(
                    for: range,
                    trackID: track.id
                )
                let sourceDuration = max(trackDuration(for: track), range.end.seconds, 0.000_001)
                let sourceSelection = TimelineSelection(
                    startProgress: min(max(range.start.seconds / sourceDuration, 0), 1),
                    endProgress: min(max(range.end.seconds / sourceDuration, 0), 1),
                    trackID: track.id
                )
                return TimelineDeletionEffectRequest(
                    selection: visualSelection,
                    sourceSelection: sourceSelection
                )
            }
            timelineSurface.triggerDeletionEffects(deletionEffectRequests)
            let effectsSubmittedAt = CACurrentMediaTime()
            let visualResponseMilliseconds = (effectsSubmittedAt - transactionStartedAt) * 1_000

            let transaction = try commitPreparedProjectEdit(
                preparedCommit,
                keepsTransitionVisual: true
            )
            let committedAt = CACurrentMediaTime()
            if kind == .cut, let nextClipboard {
                enrichClipboardInBackground(
                    nextClipboard,
                    command: command,
                    plan: plan
                )
            }
            timelineSurface.displaySelection(nil)
            timelineSurface.displayGainPreview(selection: nil, gain: 1)
            updateEffectCommandState()
            scheduleTransactionVisualHandoff(
                generation: generation,
                state: transaction.after,
                preservesLivePlayhead: command.wasPlaying
            )
            updateStatus(
                transactionStatus(
                    verb: kind == .cut ? "cut" : "deleted",
                    command: command,
                    trackCount: plan.trackEdits.count
                )
            )
            let finishedAt = CACurrentMediaTime()
            latestEditTransactionStageTimings = EditTransactionStageTimings(
                planMilliseconds: (plannedAt - transactionStartedAt) * 1_000,
                prepareMilliseconds: (preparedAt - plannedAt) * 1_000,
                effectsMilliseconds: (effectsSubmittedAt - preparedAt) * 1_000,
                commitMilliseconds: (committedAt - effectsSubmittedAt) * 1_000,
                finalizeMilliseconds: (finishedAt - committedAt) * 1_000
            )
            return visualResponseMilliseconds
        } catch {
            if deleteVisualGeneration != nil {
                cancelDeleteVisualHandoff()
                snapPlayheadVisuals(
                    toTimelineTime: previousPlayheadTime,
                    isPlaying: playbackController.isPlaying,
                    synchronizesRenderer: true
                )
            }
            timelineSurface.clearDeletionEffects()
            timelineSurface.displaySelection(selectedTimelineRange)
            updateStatus("\(kind.rawValue) failed: \(error.localizedDescription)")
            SoundtimeDiagnostics.shared.record(
                category: .edit,
                severity: .warning,
                name: "edit-transaction-rejected",
                message: "An edit transaction failed before atomic publication.",
                fields: [
                    "kind": kind.rawValue,
                    "error": error.localizedDescription,
                ]
            )
            return nil
        }
    }

    private func transactionStatus(
        verb: String,
        command: EditCommand,
        trackCount: Int
    ) -> String {
        let duration = command.range?.duration.seconds ?? 0
        let scopeSuffix = trackCount > 1 ? " across \(trackCount) tracks" : ""
        return "\(verb) \(formatDuration(duration))\(scopeSuffix)"
    }

    private func scheduleTransactionVisualHandoff(
        generation: Int,
        state: ProjectEditTransactionState,
        preservesLivePlayhead: Bool
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.deleteAnimationGeneration == generation else {
                return
            }
            self.postDeleteRefreshWorkItem = nil
            self.timelineSurface.clearDeletionEffects()
            self.updateProjectDisplayTiming()
            let renderTracks = self.applyingProjectTrackMixes(
                self.projectPlaybackTrackMixes(),
                to: state.renderTracks
            )
            self.publishedTimelineRenderTracks = renderTracks
            self.timelineSurface.displayTracks(
                renderTracks,
                animateWaveformTransition: false,
                allowImmediateWaveformPrewarm: false,
                allowImmediateInteractiveWaveformPrewarm: false,
                viewportTransition: .animatedEditReframe
            )
            self.publishSelectedTracksToTimeline()
            self.selectedTimelineRange = state.selectedTimelineRange
            self.timelineSurface.displaySelection(state.selectedTimelineRange)
            let handoffPlayheadTime = preservesLivePlayhead ?
                self.currentProjectPlayheadTime().seconds :
                state.playheadTime.seconds
            self.snapPlayheadVisuals(
                toTimelineTime: handoffPlayheadTime,
                isPlaying: self.playbackController.isPlaying,
                synchronizesRenderer: true
            )
        }
        postDeleteRefreshWorkItem?.cancel()
        postDeleteRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + deletePostAnimationDisplayRefreshDelay,
            execute: workItem
        )
    }


    private func scopedTrackIndices(
        anchorTrackIndex: Int,
        scope: EditScope
    ) -> [Int] {
        guard projectTracks.indices.contains(anchorTrackIndex) else {
            return []
        }

        switch scope {
        case .track:
            return [anchorTrackIndex]
        case .selected:
            let selectedIDs = selectedTrackIDs.isEmpty ?
                Set([projectTracks[anchorTrackIndex].id]) :
                selectedTrackIDs
            return projectTracks.indices.filter { selectedIDs.contains(projectTracks[$0].id) }
        case .group:
            guard let editGroupID = projectTracks[anchorTrackIndex].editGroupID else {
                return [anchorTrackIndex]
            }
            return projectTracks.indices.filter { projectTracks[$0].editGroupID == editGroupID }
        case .all:
            return Array(projectTracks.indices)
        }
    }


    private func preparedSplitTrackEdit(
        trackIndex: Int,
        projectProgress: Float
    ) throws -> SplitTrackEdit? {
        guard projectTracks.indices.contains(trackIndex) else {
            return nil
        }

        let insertionSelection = editInsertionSelection(
            forPlaybackProgress: projectProgress,
            trackIndex: trackIndex
        )
        guard insertionSelection.startProgress > 0, insertionSelection.startProgress < 1 else {
            return nil
        }

        let trackID = projectTracks[trackIndex].id
        if let currentFileTimeline = try preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            guard timeline.split(atProgress: insertionSelection.startProgress) else {
                return nil
            }
            return SplitTrackEdit(
                trackIndex: trackIndex,
                trackID: trackID,
                editedDuration: timeline.duration,
                editedAudioTimeline: nil,
                editedFileTimeline: timeline
            )
        }

        if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            var timeline = currentTimeline
            guard timeline.split(atProgress: insertionSelection.startProgress) else {
                return nil
            }
            return SplitTrackEdit(
                trackIndex: trackIndex,
                trackID: trackID,
                editedDuration: timeline.duration,
                editedAudioTimeline: timeline,
                editedFileTimeline: nil
            )
        }

        return nil
    }

    private func showGainEffect() {
        guard canApplyGainEffect else {
            return
        }

        gainEffectOverlay.show()
    }

    private func reapplyLastEffect() {
        guard let lastEffect else {
            return
        }

        switch lastEffect {
        case let .gain(decibels):
            guard canApplyGainEffect else {
                return
            }
            let gain = GainEffectOverlayView.linearGain(forDecibels: decibels)
            applyGainEffect(decibels: decibels, gain: gain)
        case .normalize:
            guard canApplyGainEffect else {
                return
            }
            applyNormalizeEffect()
        case .denoise:
            guard canApplyDenoiseEffect else {
                return
            }
            applyDenoiseEffect()
        case .separateMusicStems:
            guard canApplyStemSeparationEffect else {
                return
            }
            applyStemSeparationEffect()
        case let .fade(fadeEffect):
            guard canApplyFadeEffect else {
                return
            }
            applyFadeEffect(fadeEffect)
        }
    }

    private func applyNormalizeEffect() {
        guard
            let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            updateStatus("select audio to normalize")
            return
        }

        if let selectedPeak = selectedPeakMagnitude(for: target) {
            applyNormalizeEffect(withPeak: selectedPeak)
            return
        }

        let trackIndex = target.trackIndex
        let trackID = projectTracks[trackIndex].id
        let editRevision = projectTracks[trackIndex].editRevision
        let sourceURL = projectTracks[trackIndex].sourceURL
        let audioTimeline = projectTracks[trackIndex].audioTimeline
        let fileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex)
        let selectionToNormalize = target.editSelection
        let displaySelection = target.displaySelection
        updateStatus("normalizing")
        Task { [weak self, trackID, editRevision, sourceURL, audioTimeline, fileTimeline, selectionToNormalize, displaySelection] in
            let peakResult = await Task.detached(priority: .userInitiated) {
                try Self.exactPeakMagnitude(
                    audioTimeline: audioTimeline,
                    fileTimeline: fileTimeline,
                    sourceURL: sourceURL,
                    selection: selectionToNormalize
                )
            }.result

            guard let self else {
                return
            }

            guard
                let currentTarget = self.currentEditableSelectionTarget() ?? self.editableClipAtPlayheadTarget(),
                self.projectTracks.indices.contains(currentTarget.trackIndex),
                self.projectTracks[currentTarget.trackIndex].id == trackID,
                self.projectTracks[currentTarget.trackIndex].editRevision == editRevision,
                Self.selectionsMatch(currentTarget.displaySelection, displaySelection),
                Self.selectionsMatch(currentTarget.editSelection, selectionToNormalize)
            else {
                self.updateStatus("normalize skipped: selection changed")
                return
            }

            switch peakResult {
            case let .success(selectedPeak):
                self.applyNormalizeEffect(withPeak: selectedPeak)
            case let .failure(error):
                self.updateStatus("normalize failed: \(error.localizedDescription)")
            }
        }
    }

    private func applyNormalizeEffect(withPeak selectedPeak: Float) {
        guard selectedPeak > 0.000_001 else {
            updateStatus("normalize skipped: selected audio is silent")
            return
        }

        let gain = min(max(1 / selectedPeak, 0), 64)
        let decibels = 20 * log10(Double(gain))
        applyGainEffect(
            decibels: decibels,
            gain: gain,
            status: String(format: "normalized %+.1f dB", decibels),
            lastEffect: .normalize
        )
    }

    private func applyDenoiseEffect() {
        guard !isDenoiseProcessingActive else {
            updateStatus("denoise already running")
            return
        }

        guard
            let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            updateStatus("select audio to denoise")
            return
        }

        let trackIndex = target.trackIndex
        let track = projectTracks[trackIndex]
        let trackID = track.id
        let editRevision = track.editRevision
        let selectionToProcess = target.editSelection
        let displaySelection = target.displaySelection
        let sourceURL = track.sourceURL
        let trackName = track.name
        let inputURL = audioProcessingInputURL(trackName: trackName)
        let outputDirectory = audioProcessingDirectoryURL()
        let currentTimeline = track.audioTimeline
        let currentFileTimeline: AudioFileEditTimeline?
        do {
            currentFileTimeline = currentTimeline == nil ?
                try preferredFileTimelineForEditing(trackIndex: trackIndex) :
                nil
        } catch {
            updateStatus("denoise failed: \(error.localizedDescription)")
            return
        }

        guard currentTimeline != nil || currentFileTimeline != nil else {
            updateStatus("track is not ready to denoise")
            return
        }

        let requestID = UUID()
        let provider = AudioProcessingProviderFactory.makeDenoiseProvider()
        let providerDisplayName = provider.displayName
        updateStatus("denoising selection with \(providerDisplayName)")
        beginDenoiseProcessing(
            requestID: requestID,
            provider: provider,
            trackID: trackID,
            displaySelection: displaySelection,
            trackName: trackName,
            providerName: providerDisplayName
        )
        SoundtimeDiagnostics.shared.record(
            category: .api,
            severity: .info,
            name: "denoise-selection",
            message: "User requested provider-backed denoise processing.",
            fields: [
                "provider": provider.identifier,
                "providerName": providerDisplayName,
                "requestID": requestID.uuidString,
                "trackID": trackID.uuidString,
                "trackName": trackName,
                "startProgress": String(format: "%.9f", selectionToProcess.startProgress),
                "endProgress": String(format: "%.9f", selectionToProcess.endProgress),
            ]
        )
        PerformanceDashboardWindowController.refreshIfVisible()

        let progressHandler: AudioProcessingProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.handleDenoiseProgress(progress)
            }
        }

        activeDenoiseTask = Task { [
            weak self,
            provider,
            requestID,
            trackID,
            editRevision,
            trackName,
            sourceURL,
            currentTimeline,
            currentFileTimeline,
            selectionToProcess,
            displaySelection,
            inputURL,
            outputDirectory
        ] in
            let processingResult = await Task.detached(priority: .userInitiated) {
                try await Self.processDenoiseSelection(
                    requestID: requestID,
                    provider: provider,
                    trackID: trackID,
                    trackName: trackName,
                    sourceURL: sourceURL,
                    currentTimeline: currentTimeline,
                    currentFileTimeline: currentFileTimeline,
                    selection: selectionToProcess,
                    inputURL: inputURL,
                    outputDirectory: outputDirectory,
                    progress: progressHandler
                )
            }.result

            guard let self else {
                return
            }
            guard self.activeDenoiseRequestID == requestID else {
                return
            }

            guard
                let currentTrackIndex = self.projectTracks.firstIndex(where: { $0.id == trackID }),
                self.projectTracks[currentTrackIndex].editRevision == editRevision
            else {
                self.finishDenoiseProcessing(
                    requestID: requestID,
                    status: "denoise skipped: track changed",
                    fadesHighlight: true
                )
                return
            }

            switch processingResult {
            case let .success(result):
                self.recordDenoiseAPIEvent(
                    severity: .info,
                    name: "denoise-request-completed",
                    message: "Audio processing provider returned a denoise result.",
                    provider: provider,
                    requestID: requestID,
                    trackID: trackID,
                    trackName: trackName,
                    selection: selectionToProcess,
                    extraFields: [
                        "processedFrames": "\(result.processedFrameCount)",
                        "summary": result.providerSummary,
                    ]
                )
                self.handleDenoiseProgress(AudioProcessingProgress(
                    requestID: requestID,
                    stage: .applying,
                    fractionCompleted: 0.96,
                    message: "preparing denoise review"
                ))
                self.showDenoiseReview(
                    requestID: requestID,
                    trackID: trackID,
                    editRevision: editRevision,
                    displaySelection: displaySelection,
                    editSelection: selectionToProcess,
                    trackName: trackName,
                    result: result
                )
            case let .failure(error):
                if Self.isCancellation(error) {
                    self.recordDenoiseAPIEvent(
                        severity: .info,
                        name: "denoise-request-canceled",
                        message: "Audio processing request was canceled.",
                        provider: provider,
                        requestID: requestID,
                        trackID: trackID,
                        trackName: trackName,
                        selection: selectionToProcess
                    )
                    self.finishDenoiseProcessing(
                        requestID: requestID,
                        status: "denoise canceled",
                        fadesHighlight: true
                    )
                } else {
                    self.recordDenoiseAPIEvent(
                        severity: .warning,
                        name: "denoise-request-failed",
                        message: "Audio processing provider failed the denoise request.",
                        provider: provider,
                        requestID: requestID,
                        trackID: trackID,
                        trackName: trackName,
                        selection: selectionToProcess,
                        error: error
                    )
                    self.finishDenoiseProcessing(
                        requestID: requestID,
                        status: "denoise failed: \(error.localizedDescription)",
                        fadesHighlight: true,
                        showsStatus: false
                    )
                }
            }
        }
    }

    private func applyStemSeparationEffect() {
        guard !isDenoiseProcessingActive else {
            updateStatus("audio processing already running")
            return
        }

        guard
            let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            updateStatus("select music to separate")
            return
        }

        let provider: AudioProcessingProvider
        do {
            provider = try AudioProcessingProviderFactory.makeMusicStemProvider()
        } catch {
            updateStatus("stem separation failed: \(error.localizedDescription)")
            SoundtimeDiagnostics.shared.record(
                category: .api,
                severity: .warning,
                name: "music-stem-request-unavailable",
                message: "AudioShake Music Stems provider could not be created.",
                fields: ["error": error.localizedDescription]
            )
            PerformanceDashboardWindowController.refreshIfVisible()
            return
        }

        let trackIndex = target.trackIndex
        let track = projectTracks[trackIndex]
        let trackID = track.id
        let editRevision = track.editRevision
        let selectionToProcess = target.editSelection
        let displaySelection = target.displaySelection
        let sourceURL = track.sourceURL
        let trackName = track.name
        let inputURL = audioProcessingInputURL(trackName: "\(trackName)-Stems")
        let outputDirectory = audioProcessingDirectoryURL()
        let currentTimeline = track.audioTimeline
        let currentFileTimeline: AudioFileEditTimeline?
        do {
            currentFileTimeline = currentTimeline == nil ?
                try preferredFileTimelineForEditing(trackIndex: trackIndex) :
                nil
        } catch {
            updateStatus("stem separation failed: \(error.localizedDescription)")
            return
        }

        guard currentTimeline != nil || currentFileTimeline != nil else {
            updateStatus("track is not ready for stem separation")
            return
        }

        let requestID = UUID()
        let providerDisplayName = provider.displayName
        updateStatus("separating music stems with \(providerDisplayName)")
        beginDenoiseProcessing(
            requestID: requestID,
            provider: provider,
            trackID: trackID,
            displaySelection: displaySelection,
            trackName: trackName,
            providerName: providerDisplayName,
            title: "Separating Stems",
            operation: .separateMusicStems
        )
        SoundtimeDiagnostics.shared.record(
            category: .api,
            severity: .info,
            name: "music-stem-separation",
            message: "User requested AudioShake-backed music stem separation.",
            fields: [
                "provider": provider.identifier,
                "providerName": providerDisplayName,
                "requestID": requestID.uuidString,
                "trackID": trackID.uuidString,
                "trackName": trackName,
                "startProgress": String(format: "%.9f", selectionToProcess.startProgress),
                "endProgress": String(format: "%.9f", selectionToProcess.endProgress),
            ]
        )
        PerformanceDashboardWindowController.refreshIfVisible()

        let progressHandler: AudioProcessingProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.handleDenoiseProgress(progress)
            }
        }

        activeDenoiseTask = Task { [
            weak self,
            provider,
            requestID,
            trackID,
            editRevision,
            trackName,
            sourceURL,
            currentTimeline,
            currentFileTimeline,
            selectionToProcess,
            displaySelection,
            inputURL,
            outputDirectory
        ] in
            let processingResult = await Task.detached(priority: .userInitiated) {
                try await Self.processStemSeparationSelection(
                    requestID: requestID,
                    provider: provider,
                    trackID: trackID,
                    trackName: trackName,
                    sourceURL: sourceURL,
                    currentTimeline: currentTimeline,
                    currentFileTimeline: currentFileTimeline,
                    selection: selectionToProcess,
                    inputURL: inputURL,
                    outputDirectory: outputDirectory,
                    progress: progressHandler
                )
            }.result

            guard let self else {
                return
            }
            guard self.activeDenoiseRequestID == requestID else {
                return
            }

            guard
                let currentTrackIndex = self.projectTracks.firstIndex(where: { $0.id == trackID }),
                self.projectTracks[currentTrackIndex].editRevision == editRevision
            else {
                self.finishDenoiseProcessing(
                    requestID: requestID,
                    status: "stem separation skipped: track changed",
                    fadesHighlight: true
                )
                return
            }

            switch processingResult {
            case let .success(result):
                self.recordDenoiseAPIEvent(
                    severity: .info,
                    name: "music-stem-request-completed",
                    message: "Audio processing provider returned separated music stems.",
                    provider: provider,
                    requestID: requestID,
                    trackID: trackID,
                    trackName: trackName,
                    selection: selectionToProcess,
                    extraFields: [
                        "stemCount": "\(result.stems.count)",
                        "summary": result.providerSummary,
                    ]
                )
                self.handleDenoiseProgress(AudioProcessingProgress(
                    requestID: requestID,
                    stage: .applying,
                    fractionCompleted: 0.96,
                    message: "preparing stem review"
                ))
                self.showStemSeparationReview(
                    requestID: requestID,
                    trackID: trackID,
                    editRevision: editRevision,
                    displaySelection: displaySelection,
                    editSelection: selectionToProcess,
                    trackName: trackName,
                    result: result
                )
            case let .failure(error):
                if Self.isCancellation(error) {
                    self.recordDenoiseAPIEvent(
                        severity: .info,
                        name: "music-stem-request-canceled",
                        message: "Music stem separation request was canceled.",
                        provider: provider,
                        requestID: requestID,
                        trackID: trackID,
                        trackName: trackName,
                        selection: selectionToProcess
                    )
                    self.finishDenoiseProcessing(
                        requestID: requestID,
                        status: "stem separation canceled",
                        fadesHighlight: true
                    )
                } else {
                    self.recordDenoiseAPIEvent(
                        severity: .warning,
                        name: "music-stem-request-failed",
                        message: "Audio processing provider failed the music stem separation request.",
                        provider: provider,
                        requestID: requestID,
                        trackID: trackID,
                        trackName: trackName,
                        selection: selectionToProcess,
                        error: error
                    )
                    self.finishDenoiseProcessing(
                        requestID: requestID,
                        status: "stem separation failed: \(error.localizedDescription)",
                        fadesHighlight: true,
                        showsStatus: false
                    )
                }
            }
        }
    }

    private func toggleTranscriptLayer() {
        isTranscriptLayerVisible.toggle()
        timelineSurface.displayTranscriptMode(isTranscriptLayerVisible ? .waveformOverlay : .hidden)
        refreshTranscriptActiveWordForCurrentVisualPlayhead()
        updateStatus(isTranscriptLayerVisible ? "transcript layer shown" : "transcript layer hidden")
    }

    private func toggleTranscriptAlignmentDebug() {
        transcriptAlignmentDebugVisible.toggle()
        timelineSurface.displayTranscriptAlignmentDebug(transcriptAlignmentDebugVisible)
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: .info,
            name: "transcript-alignment-debug-toggled",
            message: transcriptAlignmentDebugVisible ?
                "Transcript alignment debug view enabled." :
                "Transcript alignment debug view disabled.",
            fields: ["enabled": "\(transcriptAlignmentDebugVisible)"]
        )
        updateStatus(transcriptAlignmentDebugVisible ? "transcript alignment debug shown" : "transcript alignment debug hidden")
    }

    private func handleTranscriptSelection(_ selection: TranscriptTokenSelection?) {
        selectedTranscriptSelection = selection
        timelineSurface.displayTranscriptSelection(selection)

        guard let selection else {
            selectedTimelineRange = nil
            timelineSurface.displaySelection(nil)
            updateEffectCommandState()
            updateStatus(currentPlaybackStatus)
            return
        }

        guard projectTracks.contains(where: { $0.id == selection.trackID }) else {
            selectedTranscriptSelection = nil
            timelineSurface.displayTranscriptSelection(nil)
            return
        }

        selectedTrackID = nil
        selectedTrackIDs.removeAll()
        trackSelectionAnchorID = nil
        activeTrackID = selection.trackID
        let timelineSelection = selection.timelineSelection(timelineDuration: projectSelectionDuration)
        selectedTimelineRange = timelineSelection
        timelineSurface.displaySelection(timelineSelection)
        publishSelectedTracksToTimeline()
        syncActiveTrackFields()
        updateEffectCommandState()
        updateStatus("selected transcript \(formatDuration(timelineSelection.duration(in: projectSelectionDuration)))")
    }

    private func executeTranscriptEditCommand(_ command: TranscriptEditCommand) {
        if let message = TranscriptEditPlanner.validationMessage(for: command) {
            updateStatus(message)
            return
        }

        SoundtimeDiagnostics.shared.record(
            category: .edit,
            severity: .info,
            name: "transcript-edit-command",
            message: "Executing transcript edit command.",
            fields: [
                "kind": command.kind.rawValue,
                "trackID": command.selection?.trackID.uuidString ?? "",
                "wordCount": "\(command.selection?.wordIDs.count ?? 0)",
            ]
        )

        switch command.kind {
        case .deleteWordsRipple:
            guard let selection = command.selection else {
                return
            }
            handleTranscriptSelection(selection)
            performTransactionalRangeEdit(kind: .rippleDelete, scope: .track)
        case .clearWordsLeaveGap:
            guard let selection = command.selection else {
                return
            }
            handleTranscriptSelection(selection)
            clearSelection()
        case .shortenPause:
            executeShortenTranscriptPause(command)
        case .splitAtWordBoundary:
            executeTranscriptSplit(command)
        case .nudgeWordBoundary:
            executeTranscriptBoundaryNudge(command)
        case .correctText:
            executeTranscriptTextReplacement(command)
        case .renameSpeaker:
            executeTranscriptSpeakerRename(command)
        }
    }

    private func executeShortenTranscriptPause(_ command: TranscriptEditCommand) {
        guard let selection = command.selection else {
            return
        }

        let currentDuration = selection.projectRange.duration
        let targetDuration = min(max(command.targetDuration ?? 0.25, 0), currentDuration)
        let removeDuration = currentDuration - targetDuration
        guard removeDuration > 0.005, projectSelectionDuration > 0 else {
            updateStatus("pause already short enough")
            return
        }

        let removeStart = selection.projectRange.startTime + targetDuration
        let removeEnd = selection.projectRange.endTime
        let timelineSelection = TimelineSelection(
            startProgress: removeStart / projectSelectionDuration,
            endProgress: removeEnd / projectSelectionDuration,
            trackID: selection.trackID
        )
        selectedTimelineRange = timelineSelection
        timelineSurface.displaySelection(timelineSelection)
        selectedTranscriptSelection = selection
        performTransactionalRangeEdit(kind: .rippleDelete, scope: .track)
    }

    private func executeTranscriptSplit(_ command: TranscriptEditCommand) {
        guard let selection = command.selection, projectSelectionDuration > 0 else {
            return
        }

        let progress = Float(min(max(selection.projectRange.startTime / projectSelectionDuration, 0), 1))
        do {
            try playbackController.seekExactly(toProgress: progress)
            currentPlayheadFrame = Int((Double(progress) * Double(max(displayedFrameCount, 0))).rounded(.down))
            displayPlaybackVisuals(progress: progress, isPlaying: playbackController.isPlaying, syncPlayhead: true)
            activeTrackID = selection.trackID
            syncActiveTrackFields()
            splitAtPlayhead()
        } catch {
            updateStatus("transcript split failed: \(error.localizedDescription)")
        }
    }

    private func executeTranscriptBoundaryNudge(_ command: TranscriptEditCommand) {
        guard
            let selection = command.selection,
            let delta = command.targetDuration,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == selection.trackID }),
            var transcript = projectTracks[trackIndex].transcript
        else {
            return
        }

        let wordIDs = Set(selection.wordIDs)
        guard !wordIDs.isEmpty else {
            updateStatus("select transcript words to nudge")
            return
        }

        let undoSnapshot = captureProjectTrackUndoSnapshot(
            restoreProgress: playbackController.snapshot().progress
        )
        editUndoStack.append(.projectTracks(undoSnapshot))

        transcript.segments = transcript.segments.map { segment in
            var segment = segment
            segment.words = segment.words.map { word in
                guard wordIDs.contains(word.id) else {
                    return word
                }
                var word = word
                word.startTime = min(max(word.startTime + delta, 0), transcript.sourceDuration)
                word.endTime = min(max(word.endTime + delta, word.startTime), transcript.sourceDuration)
                return word
            }
            if let first = segment.words.first, let last = segment.words.last {
                segment.startTime = first.startTime
                segment.endTime = last.endTime
            }
            segment.text = segment.words.map(\.text).joined(separator: " ")
            return segment
        }
        projectTracks[trackIndex].transcript = transcript
        refreshTranscriptAfterTextOnlyEdit(selection: command.selection)
        updateStatus("nudged transcript words \(formatDuration(abs(delta)))")
    }

    private func executeTranscriptTextReplacement(_ command: TranscriptEditCommand) {
        guard
            let selection = command.selection,
            let replacementText = command.replacementText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !replacementText.isEmpty,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == selection.trackID }),
            var transcript = projectTracks[trackIndex].transcript
        else {
            return
        }

        let wordIDs = Set(selection.wordIDs)
        guard !wordIDs.isEmpty else {
            updateStatus("select transcript words to correct")
            return
        }

        let undoSnapshot = captureProjectTrackUndoSnapshot(
            restoreProgress: playbackController.snapshot().progress
        )
        editUndoStack.append(.projectTracks(undoSnapshot))

        var replacementWordID: UUID?
        transcript.segments = transcript.segments.map { segment in
            var segment = segment
            var words: [TranscriptWord] = []
            words.reserveCapacity(segment.words.count)
            for sourceWord in segment.words {
                guard wordIDs.contains(sourceWord.id) else {
                    words.append(sourceWord)
                    continue
                }
                if replacementWordID == nil {
                    var word = sourceWord
                    word.text = replacementText
                    word.punctuatedText = replacementText
                    replacementWordID = word.id
                    words.append(word)
                }
            }
            segment.words = words
            segment.text = segment.words.map(\.text).joined(separator: " ")
            return segment
        }
        projectTracks[trackIndex].transcript = transcript
        refreshTranscriptAfterTextOnlyEdit(selection: command.selection)
        updateStatus("corrected transcript text")
    }

    private func executeTranscriptSpeakerRename(_ command: TranscriptEditCommand) {
        guard
            let selection = command.selection,
            let speakerName = command.replacementText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !speakerName.isEmpty,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == selection.trackID }),
            var transcript = projectTracks[trackIndex].transcript
        else {
            return
        }

        let selectedWordIDs = Set(selection.wordIDs)
        let speakerIDs = Set(transcript.words(matching: selectedWordIDs).compactMap(\.speakerID))
        guard !speakerIDs.isEmpty else {
            updateStatus("selected words do not have a speaker")
            return
        }

        let undoSnapshot = captureProjectTrackUndoSnapshot(
            restoreProgress: playbackController.snapshot().progress
        )
        editUndoStack.append(.projectTracks(undoSnapshot))

        transcript.segments = transcript.segments.map { segment in
            var segment = segment
            if let speakerID = segment.speakerID, speakerIDs.contains(speakerID) {
                segment.speakerLabel = speakerName
            }
            return segment
        }
        projectTracks[trackIndex].transcript = transcript
        refreshTranscriptAfterTextOnlyEdit(selection: command.selection)
        updateStatus("renamed transcript speaker")
    }

    private func refreshTranscriptAfterTextOnlyEdit(selection: TranscriptTokenSelection?) {
        selectedTranscriptSelection = selection
        timelineSurface.displayTranscriptSelection(selection)
        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        scheduleAutosaveIfNeeded()
        updateEffectCommandState()
        PerformanceDashboardWindowController.refreshIfVisible()
    }

    private func updateTranscriptActiveWord(progress: Float) {
        guard isTranscriptLayerVisible, projectSelectionDuration > 0 else {
            guard activeTranscriptWordID != nil else {
                return
            }
            activeTranscriptWordID = nil
            activeTranscriptWordProjectRange = nil
            timelineSurface.displayTranscriptActiveWord(nil)
            return
        }

        let projectTime = TimeInterval(min(max(progress, 0), 1)) * projectSelectionDuration
        if
            let activeRange = activeTranscriptWordProjectRange,
            projectTime >= activeRange.startTime,
            projectTime < activeRange.endTime
        {
            return
        }

        guard let active = activeTranscriptWord(atProjectTime: projectTime) else {
            guard activeTranscriptWordID != nil else {
                return
            }
            activeTranscriptWordID = nil
            activeTranscriptWordProjectRange = nil
            timelineSurface.displayTranscriptActiveWord(nil)
            return
        }

        guard active.wordID != activeTranscriptWordID else {
            activeTranscriptWordProjectRange = active.projectRange
            return
        }

        activeTranscriptWordID = active.wordID
        activeTranscriptWordProjectRange = active.projectRange
        timelineSurface.displayTranscriptActiveWord(active.wordID)
    }

    private func activeTranscriptWord(
        atProjectTime projectTime: TimeInterval
    ) -> (wordID: UUID, projectRange: TranscriptionTimeRange)? {
        for track in projectTracks {
            guard let transcript = track.transcript else {
                continue
            }

            let timeMap = transcriptSourceTimeMap(
                for: track,
                timelineDuration: trackDuration(for: track)
            )
            guard let sourceTime = timeMap.sourceTime(forProjectTime: projectTime) else {
                continue
            }

            guard let word = transcript.word(atSourceTime: sourceTime) else {
                continue
            }
            let projectRanges = timeMap.projectRanges(forSourceRange: word.startTime..<max(word.endTime, word.startTime + 0.001))
            let projectRange = projectRanges
                .first { $0.lowerBound <= projectTime && $0.upperBound >= projectTime }
                ?? projectRanges.first
            return (
                word.id,
                TranscriptionTimeRange(
                    startTime: projectRange?.lowerBound ?? projectTime,
                    endTime: projectRange?.upperBound ?? projectTime
                )
            )
        }

        return nil
    }

    private func refreshTranscriptActiveWordForCurrentVisualPlayhead() {
        guard displayedDuration > 0 else {
            updateTranscriptActiveWord(progress: visualPlayheadProgress)
            return
        }

        let progress = projectedVisualPlayheadProgress(
            at: CACurrentMediaTime(),
            duration: displayedDuration
        )
        updateTranscriptActiveWord(progress: progress)
    }

    private func transcribeSelectedTrack() {
        guard activeTranscriptionJob == nil else {
            updateStatus("transcription already running")
            return
        }

        guard
            let trackIndex = transcriptionTargetTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            updateStatus("select a track to transcribe")
            return
        }

        let track = projectTracks[trackIndex]
        let duration = trackDuration(for: track)
        guard duration > 0 else {
            updateStatus("track has no audio to transcribe")
            return
        }

        let provider = TranscriptionProviderFactory.makeDefaultProvider()
        let controller = TranscriptionController(provider: provider)
        let requestID = UUID()
        let resolvedScope = resolvedTranscriptionScope(forTrackAt: trackIndex)
        let trackID = track.id
        let editRevision = track.editRevision
        let job = TranscriptionJob(
            requestID: requestID,
            trackID: trackID,
            trackName: track.name,
            sourceRevision: editRevision,
            sourceDuration: duration,
            providerIdentifier: controller.providerIdentifier,
            providerDisplayName: controller.providerDisplayName
        )
        beginTranscriptionJob(job, provider: provider, controller: controller)
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: .info,
            name: "transcription-started",
            message: "Started track transcription.",
            fields: [
                "provider": provider.identifier,
                "trackID": trackID.uuidString,
                "trackName": track.name,
                "duration": String(format: "%.3f", duration),
                "revision": "\(editRevision)",
                "scope": resolvedScope.requestedScope.kind.rawValue,
                "renderMode": resolvedScope.requestedScope.renderMode.rawValue,
                "audioDomain": resolvedScope.requestedScope.audioDomain.rawValue,
            ]
        )
        PerformanceDashboardWindowController.refreshIfVisible()

        let progressHandler: TranscriptionProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.handleTranscriptionProgress(progress)
            }
        }

        activeTranscriptionTask = Task { [weak self, controller, resolvedScope, requestID, trackID, editRevision] in
            do {
                let result = try await controller.transcribe(
                    scope: resolvedScope,
                    requestID: requestID,
                    progress: progressHandler
                )
                await MainActor.run { [weak self] in
                    self?.handleTranscriptionResult(
                        result.providerResult,
                        requestID: requestID,
                        trackID: trackID,
                        editRevision: editRevision
                    )
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.finishTranscriptionJob(
                        requestID: requestID,
                        status: .canceled,
                        message: "transcription canceled",
                        fadesHighlight: true
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.finishTranscriptionJob(
                        requestID: requestID,
                        status: .failed(error.localizedDescription),
                        message: "transcription failed: \(error.localizedDescription)",
                        fadesHighlight: true
                    )
                    SoundtimeDiagnostics.shared.record(
                        category: .system,
                        severity: .severe,
                        name: "transcription-failed",
                        message: "Track transcription failed.",
                        fields: [
                            "trackID": trackID.uuidString,
                            "error": error.localizedDescription,
                        ]
                    )
                    PerformanceDashboardWindowController.refreshIfVisible()
                }
            }
        }
        updateEffectCommandState()
    }

    private func beginTranscriptionJob(
        _ job: TranscriptionJob,
        provider: TranscriptionProvider,
        controller: TranscriptionController
    ) {
        activeTranscriptionJob = job
        activeTranscriptionProvider = provider
        activeTranscriptionController = controller
        transcriptionHighlightFadeTask?.cancel()
        transcriptionHighlightFadeTask = nil
        transcriptionProgressOverlay.show(job: job)
        timelineSurface.displayProcessingTrackHighlight(trackID: job.trackID, alpha: 1)
        updateStatus("transcribing \(job.trackName)")
    }

    private func handleTranscriptionProgress(_ progress: TranscriptionProgress) {
        guard activeTranscriptionJob?.requestID == progress.requestID else {
            return
        }

        activeTranscriptionJob?.apply(progress: progress)
        if let job = activeTranscriptionJob {
            transcriptionProgressOverlay.update(job: job)
        }
        let percentage: String
        if let fractionCompleted = progress.fractionCompleted {
            percentage = " \(Int((fractionCompleted * 100).rounded()))%"
        } else {
            percentage = ""
        }
        updateStatus("\(progress.message)\(percentage)")
    }

    private func handleTranscriptionResult(
        _ result: TranscriptionResult,
        requestID: UUID,
        trackID: UUID,
        editRevision: Int
    ) {
        guard activeTranscriptionJob?.requestID == requestID else {
            return
        }

        guard
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            projectTracks[trackIndex].editRevision == editRevision
        else {
            finishTranscriptionJob(
                requestID: requestID,
                status: .stale,
                message: "transcription skipped: track changed",
                fadesHighlight: true
            )
            return
        }

        projectTracks[trackIndex].transcript = result.transcript
        isTranscriptLayerVisible = true
        timelineSurface.displayTranscriptMode(.waveformOverlay)
        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        scheduleAutosaveIfNeeded()
        finishTranscriptionJob(
            requestID: requestID,
            status: .completed,
            message: "transcript ready: \(result.summary)",
            fadesHighlight: true
        )
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: .info,
            name: "transcription-completed",
            message: "Track transcription completed.",
            fields: [
                "trackID": trackID.uuidString,
                "segments": "\(result.transcript.segments.count)",
                "words": "\(result.transcript.words.count)",
                "provider": result.transcript.providerIdentifier,
            ]
        )
        PerformanceDashboardWindowController.refreshIfVisible()
    }

    private func cancelActiveTranscription() {
        guard
            let job = activeTranscriptionJob,
            let controller = activeTranscriptionController
        else {
            return
        }

        var cancelingJob = job
        cancelingJob.markCanceling()
        activeTranscriptionJob = cancelingJob
        transcriptionProgressOverlay.update(job: cancelingJob)
        updateStatus("canceling transcription")
        activeTranscriptionTask?.cancel()

        Task { [weak self, controller, requestID = job.requestID] in
            let cancellationResult = await controller.cancel(requestID: requestID)
            await MainActor.run { [weak self] in
                guard self?.activeTranscriptionJob?.requestID == requestID else {
                    return
                }

                switch cancellationResult {
                case .canceledRemotely:
                    SoundtimeDiagnostics.shared.record(
                        category: .system,
                        severity: .info,
                        name: "transcription-canceled-remotely",
                        message: "Transcription provider accepted cancellation.",
                        fields: ["requestID": requestID.uuidString]
                    )
                case .remoteCancellationUnsupported:
                    SoundtimeDiagnostics.shared.record(
                        category: .system,
                        severity: .info,
                        name: "transcription-cancel-unsupported",
                        message: "Transcription provider does not support remote cancellation.",
                        fields: ["requestID": requestID.uuidString]
                    )
                }
                PerformanceDashboardWindowController.refreshIfVisible()
            }
        }
    }

    private func finishTranscriptionJob(
        requestID: UUID,
        status: TranscriptionJob.Status,
        message: String,
        fadesHighlight: Bool
    ) {
        guard var job = activeTranscriptionJob, job.requestID == requestID else {
            return
        }

        switch status {
        case .completed:
            job.markCompleted(summary: message)
        case .failed(let failure):
            job.markFailed(failure)
        case .canceled:
            job.markCanceled()
        case .stale:
            job.markStale()
        case .canceling:
            job.markCanceling()
        case .preparing, .running:
            job.status = status
            job.message = message
        }

        transcriptionProgressOverlay.update(job: job)
        activeTranscriptionTask = nil
        activeTranscriptionProvider = nil
        activeTranscriptionController = nil
        activeTranscriptionJob = nil
        updateEffectCommandState()
        updateStatus(message)
        clearTranscriptionProcessingHighlight(trackID: job.trackID, fadesHighlight: fadesHighlight)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 380_000_000)
            self?.transcriptionProgressOverlay.hide()
        }
    }

    private func clearTranscriptionProcessingHighlight(trackID: UUID?, fadesHighlight: Bool) {
        transcriptionHighlightFadeTask?.cancel()
        transcriptionHighlightFadeTask = nil

        guard let trackID, fadesHighlight else {
            timelineSurface.displayProcessingTrackHighlight(trackID: nil, alpha: 0)
            return
        }

        transcriptionHighlightFadeTask = Task { [weak self, trackID] in
            let steps = 12
            for step in 0...steps {
                try? await Task.sleep(nanoseconds: 16_000_000)
                let progress = Float(step) / Float(steps)
                let alpha = 1 - progress * progress * (3 - 2 * progress)
                await MainActor.run { [weak self] in
                    self?.timelineSurface.displayProcessingTrackHighlight(trackID: trackID, alpha: alpha)
                }
            }
            await MainActor.run { [weak self] in
                self?.timelineSurface.displayProcessingTrackHighlight(trackID: nil, alpha: 0)
                self?.transcriptionHighlightFadeTask = nil
            }
        }
    }

    private func transcriptionTargetTrackIndex() -> Int? {
        if
            let trackID = selectedTimelineRange?.trackID,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID })
        {
            return trackIndex
        }

        if
            let selectedTrackID,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == selectedTrackID })
        {
            return trackIndex
        }

        if let activeTrackIndex = activeProjectTrackIndex() {
            return activeTrackIndex
        }

        return projectTracks.firstIndex { trackDuration(for: $0) > 0 }
    }

    private func resolvedTranscriptionScope(forTrackAt trackIndex: Int) -> ResolvedTranscriptionScope {
        let track = projectTracks[trackIndex]
        let timelineDuration = trackDuration(for: track)
        let timeMap = transcriptSourceTimeMap(for: track, timelineDuration: timelineDuration)
        let sourceDuration = timeMap.sourceDuration > 0 ? timeMap.sourceDuration : timelineDuration

        let scope = TranscriptionScope(
            kind: .wholeTrack,
            trackIDs: [track.id],
            range: TranscriptionTimeRange(startTime: 0, endTime: timelineDuration),
            renderMode: .perTrack,
            audioDomain: track.fileTimeline == nil ? .rawSource : .postEditGraph
        )
        let sourceFingerprint = transcriptSourceFingerprint(for: track)

        return ResolvedTranscriptionScope(
            requestedScope: scope,
            sources: [
                ResolvedTranscriptionSource(
                    trackID: track.id,
                    trackName: track.name,
                    sourceURL: track.sourceURL,
                    sourceRevision: track.editRevision,
                    sourceDuration: sourceDuration,
                    timelineDuration: timelineDuration,
                    sourceFingerprint: sourceFingerprint,
                    timeMap: timeMap
                ),
            ]
        )
    }

    private func reconcileProjectTranscriptsIfNeeded() {
        for trackIndex in projectTracks.indices {
            guard let transcript = projectTracks[trackIndex].transcript else {
                continue
            }
            let track = projectTracks[trackIndex]
            let timelineDuration = trackDuration(for: track)
            let timeMap = transcriptSourceTimeMap(for: track, timelineDuration: timelineDuration)
            let reconciled = TranscriptValidityPolicy.reconciledTranscript(
                transcript,
                currentSourceRevision: track.editRevision,
                currentSourceFingerprint: transcriptSourceFingerprint(for: track),
                timeMap: timeMap
            )
            if reconciled != transcript {
                projectTracks[trackIndex].transcript = reconciled
            }
        }
    }

    private func transcriptSourceTimeMap(
        for track: ProjectTrack,
        timelineDuration: TimeInterval
    ) -> TranscriptSourceTimeMap {
        if let fileTimeline = track.fileTimeline {
            return TranscriptSourceTimeMap.fromTimeline(fileTimeline)
        }
        if let audioTimeline = track.audioTimeline {
            return TranscriptSourceTimeMap.fromTimeline(audioTimeline)
        }
        return .identity(duration: timelineDuration)
    }

    private func transcriptSourceFingerprint(for track: ProjectTrack) -> String? {
        track.editableSource?.id.rawValue ??
            decodableWAVFileInfo(for: track.sourceURL).map {
                SoundtimeProject.WaveformPreview.FileFingerprint(fileInfo: $0).stableSummary
            }
    }

    private func beginDenoiseProcessing(
        requestID: UUID,
        provider: AudioProcessingProvider,
        trackID: UUID,
        displaySelection: TimelineSelection,
        trackName: String,
        providerName: String,
        title: String = "Denoising",
        operation: AudioProcessingOperation = .denoise
    ) {
        denoiseHighlightFadeTask?.cancel()
        denoiseHighlightFadeTask = nil
        activeDenoiseRequestID = requestID
        activeDenoiseProvider = provider
        activeDenoiseTrackID = trackID
        activeDenoiseDisplaySelection = displaySelection
        activeAudioProcessingOperation = operation
        if playbackController.isPlaying {
            playbackController.pause()
            stopPlaybackTimer()
            refreshPlaybackProgress(syncPlayheadWhenPlaying: false)
        }
        denoiseProgressOverlay.show(trackName: trackName, providerName: providerName, title: title)
        timelineSurface.displaySelection(displaySelection)
        timelineSurface.displayProcessingSelectionProgress(selection: displaySelection, fractionCompleted: 0.04)
        setDenoiseModalInteractionLocked(true)
        timelineSurface.displayModalBackdropActive(true)
        timelineSurface.displayProcessingTrackHighlight(trackID: trackID, alpha: 1)
        updateTransportControlState(isPlaying: false)
        window?.makeFirstResponder(denoiseProgressOverlay)
        updateEffectCommandState()
    }

    private func handleDenoiseProgress(_ progress: AudioProcessingProgress) {
        guard activeDenoiseRequestID == progress.requestID else {
            return
        }

        denoiseProgressOverlay.update(progress: progress)
        if let displaySelection = activeDenoiseDisplaySelection {
            timelineSurface.displayProcessingSelectionProgress(
                selection: displaySelection,
                fractionCompleted: progress.fractionCompleted.map(Float.init)
            )
        }
        updateStatus(progress.message)
    }

    private func recordDenoiseAPIEvent(
        severity: SoundtimeDiagnosticSeverity,
        name: String,
        message: String,
        provider: AudioProcessingProvider,
        requestID: UUID,
        trackID: UUID,
        trackName: String,
        selection: TimelineSelection,
        error: Error? = nil,
        extraFields: [String: String] = [:]
    ) {
        var fields: [String: String] = [
            "provider": provider.identifier,
            "providerName": provider.displayName,
            "requestID": requestID.uuidString,
            "trackID": trackID.uuidString,
            "trackName": trackName,
            "startProgress": String(format: "%.9f", selection.startProgress),
            "endProgress": String(format: "%.9f", selection.endProgress),
        ]
        fields.merge(extraFields) { _, new in new }
        if let error {
            fields["error"] = error.localizedDescription
            fields["errorType"] = String(reflecting: type(of: error))
            if let audioShakeError = error as? AudioShakeAudioProcessingProvider.ProcessingError {
                fields.merge(Self.audioShakeDiagnosticFields(for: audioShakeError)) { _, new in new }
            }
        }

        SoundtimeDiagnostics.shared.record(
            category: .api,
            severity: severity,
            name: name,
            message: message,
            fields: fields
        )
        PerformanceDashboardWindowController.refreshIfVisible()
    }

    private nonisolated static func audioShakeDiagnosticFields(
        for error: AudioShakeAudioProcessingProvider.ProcessingError
    ) -> [String: String] {
        switch error {
        case .unsupportedOperation:
            return ["providerError": "unsupportedOperation"]
        case .missingAPIKey:
            return ["providerError": "missingAPIKey"]
        case .missingInput:
            return ["providerError": "missingInput"]
        case .failedToCreateOutputDirectory:
            return ["providerError": "failedToCreateOutputDirectory"]
        case let .invalidResponse(message):
            return [
                "providerError": "invalidResponse",
                "providerMessage": message,
            ]
        case let .httpError(statusCode, body):
            return [
                "providerError": "httpError",
                "statusCode": "\(statusCode)",
                "response": body,
            ]
        case .taskTimedOut:
            return ["providerError": "taskTimedOut"]
        case let .targetFailed(message):
            return [
                "providerError": "targetFailed",
                "providerMessage": message,
            ]
        case .missingOutput:
            return ["providerError": "missingOutput"]
        case let .invalidDownloadURL(value):
            return [
                "providerError": "invalidDownloadURL",
                "downloadURL": value,
            ]
        }
    }

    private func showDenoiseReview(
        requestID: UUID,
        trackID: UUID,
        editRevision: Int,
        displaySelection: TimelineSelection,
        editSelection: TimelineSelection,
        trackName: String,
        result: DenoiseProcessingResult
    ) {
        guard activeDenoiseRequestID == requestID else {
            return
        }

        activeDenoiseTask = nil
        activeDenoiseProvider = nil
        pendingDenoiseReview = PendingDenoiseReview(
            requestID: requestID,
            trackID: trackID,
            editRevision: editRevision,
            displaySelection: displaySelection,
            editSelection: editSelection,
            trackName: trackName,
            result: result
        )
        denoiseProgressOverlay.hide()
        timelineSurface.displayProcessingSelectionProgress(selection: nil, fractionCompleted: nil)
        setDenoiseModalInteractionLocked(true)
        timelineSurface.displayModalBackdropActive(true)
        updateEffectCommandState()
        updateTransportControlState(isPlaying: false)

        do {
            if playbackController.isPlaying {
                playbackController.pause()
                stopPlaybackTimer()
                refreshPlaybackProgress(syncPlayheadWhenPlaying: false)
            }
            try denoiseReviewOverlay.show(
                beforeBuffer: result.beforeBuffer,
                afterBuffer: result.afterBuffer,
                trackName: trackName,
                providerSummary: result.providerSummary
            )
            updateStatus("review denoise result")
        } catch {
            finishDenoiseProcessing(
                requestID: requestID,
                status: "denoise review failed: \(error.localizedDescription)",
                fadesHighlight: true
            )
        }
    }

    private func acceptPendingDenoiseReview() {
        guard
            let review = pendingDenoiseReview,
            activeDenoiseRequestID == review.requestID
        else {
            return
        }

        guard
            let currentTrackIndex = projectTracks.firstIndex(where: { $0.id == review.trackID }),
            projectTracks[currentTrackIndex].editRevision == review.editRevision
        else {
            finishDenoiseProcessing(
                requestID: review.requestID,
                status: "denoise skipped: track changed",
                fadesHighlight: true
            )
            return
        }

        let undoSnapshot = captureProjectTrackUndoSnapshot(
            restoreProgress: review.displaySelection.startProgressFloat
        )
        editUndoStack.append(.projectTracks(undoSnapshot))
        cancelEditMaterialization(for: review.trackID)
        projectTracks[currentTrackIndex].editRevision += 1
        let nextRevision = projectTracks[currentTrackIndex].editRevision
        lastEffect = .denoise
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        denoiseReviewOverlay.hide()

        let duration = Double(review.result.processedFrameCount) /
            max(review.result.materialized.buffer.sampleRate, 1)
        let status = "\(review.result.providerSummary) - \(formatDuration(duration))"
        applyMaterializedTrackEdit(
            trackID: review.trackID,
            editRevision: nextRevision,
            materialized: review.result.materialized,
            status: status,
            preservePlaybackProgress: true,
            reloadPlaybackSource: true,
            preserveTimelineSource: false,
            animateWaveformTransition: true
        )
        finishDenoiseProcessing(
            requestID: review.requestID,
            status: status,
            fadesHighlight: true
        )
    }

    private func showStemSeparationReview(
        requestID: UUID,
        trackID: UUID,
        editRevision: Int,
        displaySelection: TimelineSelection,
        editSelection: TimelineSelection,
        trackName: String,
        result: StemSeparationProcessingResult
    ) {
        guard activeDenoiseRequestID == requestID else {
            return
        }

        activeDenoiseTask = nil
        activeDenoiseProvider = nil
        pendingStemSeparationReview = PendingStemSeparationReview(
            requestID: requestID,
            trackID: trackID,
            editRevision: editRevision,
            displaySelection: displaySelection,
            editSelection: editSelection,
            trackName: trackName,
            result: result
        )
        denoiseProgressOverlay.hide()
        timelineSurface.displayProcessingSelectionProgress(selection: nil, fractionCompleted: nil)
        setDenoiseModalInteractionLocked(true)
        timelineSurface.displayModalBackdropActive(true)
        updateEffectCommandState()
        updateTransportControlState(isPlaying: false)

        do {
            if playbackController.isPlaying {
                playbackController.pause()
                stopPlaybackTimer()
                refreshPlaybackProgress(syncPlayheadWhenPlaying: false)
            }
            try stemSeparationReviewOverlay.show(
                originalBuffer: result.beforeBuffer,
                stems: result.stems.map {
                    StemSeparationPreviewItem(name: $0.name, buffer: $0.buffer)
                },
                trackName: trackName,
                providerSummary: result.providerSummary
            )
            updateStatus("review music stems")
        } catch {
            finishDenoiseProcessing(
                requestID: requestID,
                status: "stem review failed: \(error.localizedDescription)",
                fadesHighlight: true
            )
        }
    }

    private func acceptPendingStemSeparationReview() {
        guard
            let review = pendingStemSeparationReview,
            activeDenoiseRequestID == review.requestID
        else {
            return
        }

        guard
            let currentTrackIndex = projectTracks.firstIndex(where: { $0.id == review.trackID }),
            projectTracks[currentTrackIndex].editRevision == review.editRevision
        else {
            finishDenoiseProcessing(
                requestID: review.requestID,
                status: "stem separation skipped: track changed",
                fadesHighlight: true
            )
            return
        }

        do {
            let undoSnapshot = captureProjectTrackUndoSnapshot(
                restoreProgress: review.displaySelection.startProgressFloat
            )
            let newTracks = try makeStemSeparationTracks(
                sourceTrack: projectTracks[currentTrackIndex],
                result: review.result
            )
            guard !newTracks.isEmpty else {
                throw AudioShakeAudioProcessingProvider.ProcessingError.missingOutput
            }

            editUndoStack.append(.projectTracks(undoSnapshot))
            let insertionIndex = min(currentTrackIndex + 1, projectTracks.count)
            projectTracks.insert(contentsOf: newTracks, at: insertionIndex)
            rebuildProjectEditGraphFromTrackMirrors()
            activeTrackID = newTracks.first?.id
            selectedTrackID = newTracks.first?.id
            selectedTrackIDs = Set(newTracks.map(\.id))
            trackSelectionAnchorID = selectedTrackID
            selectedTimelineRange = nil
            timelineSurface.displaySelection(nil)
            timelineSurface.displayGainPreview(selection: nil, gain: 1)
            stemSeparationReviewOverlay.hide()
            lastEffect = .separateMusicStems

            syncActiveTrackFields()
            publishSelectedTracksToTimeline()
            refreshProjectTimelineDisplay()
            updateProjectDisplayTiming()
            reloadPlaybackFromProjectTracks(preserveProgress: true)
            scheduleAutosaveIfNeeded()

            let status = "added \(newTracks.count) music stem\(newTracks.count == 1 ? "" : "s")"
            finishDenoiseProcessing(
                requestID: review.requestID,
                status: status,
                fadesHighlight: true
            )
        } catch {
            finishDenoiseProcessing(
                requestID: review.requestID,
                status: "stem accept failed: \(error.localizedDescription)",
                fadesHighlight: true
            )
        }
    }

    private func rejectPendingStemSeparationReview() {
        guard
            let review = pendingStemSeparationReview,
            activeDenoiseRequestID == review.requestID
        else {
            return
        }

        finishDenoiseProcessing(
            requestID: review.requestID,
            status: "stem separation rejected",
            fadesHighlight: true
        )
    }

    private func makeStemSeparationTracks(
        sourceTrack: ProjectTrack,
        result: StemSeparationProcessingResult
    ) throws -> [ProjectTrack] {
        try result.stems.map { stem in
            let paddedBuffer = Self.bufferByPaddingLeadingSilence(
                stem.buffer,
                leadingDuration: result.timelineStartTime
            )
            let trackName = "\(sourceTrack.name) - \(stem.name)"
            let destinationURL = recordingFileURL(trackName: trackName)
            try WAVFileWriter.write(paddedBuffer, to: destinationURL)
            let fileInfo = try WAVAudioDecoder.inspect(url: destinationURL)
            let waveformOverview = WaveformOverviewBuilder.build(from: paddedBuffer)
            let fileTimeline = AudioFileEditTimeline(fileInfo: fileInfo)
            let editableSource = editableAudioSource(
                originalURL: destinationURL,
                editableURL: destinationURL,
                formatOrigin: .wav,
                fileInfo: fileInfo,
                ownsEditableFile: true
            )
            return ProjectTrack(
                id: UUID(),
                editGroupID: sourceTrack.editGroupID ?? defaultEditGroupID,
                name: trackName,
                sourceURL: destinationURL,
                durationHint: fileTimeline.duration,
                sourceWaveformOverview: waveformOverview,
                waveformOverview: waveformOverview,
                decodedAudioBuffer: nil,
                zeroCrossingIndex: AudioZeroCrossingIndex.build(from: paddedBuffer),
                zeroCrossingProbe: try? WAVAudioDecoder.makeZeroCrossingProbe(
                    url: destinationURL,
                    fileInfo: fileInfo
                ),
                audioTimeline: nil,
                fileTimeline: fileTimeline,
                editableSource: editableSource,
                ownsSourceFile: true,
                volume: sourceTrack.volume,
                isMuted: false,
                isSoloed: false,
                importID: UUID(),
                editRevision: 0
            )
        }
    }

    private func rejectPendingDenoiseReview() {
        guard
            let review = pendingDenoiseReview,
            activeDenoiseRequestID == review.requestID
        else {
            return
        }

        finishDenoiseProcessing(
            requestID: review.requestID,
            status: "denoise rejected",
            fadesHighlight: true
        )
    }

    private func cancelActiveDenoiseProcessing() {
        guard
            let requestID = activeDenoiseRequestID,
            let provider = activeDenoiseProvider
        else {
            return
        }

        let isStemSeparation = activeAudioProcessingOperation == .separateMusicStems
        denoiseProgressOverlay.showCanceling(
            message: isStemSeparation ? "Canceling stem separation" : "Canceling denoise"
        )
        updateStatus(isStemSeparation ? "canceling stem separation" : "canceling denoise")
        activeDenoiseTask?.cancel()
        Task { [weak self, provider, requestID] in
            let cancellationResult = await provider.cancel(requestID: requestID)
            await MainActor.run {
                guard let self, self.activeDenoiseRequestID == requestID else {
                    return
                }

                let status: String
                let eventName: String
                switch cancellationResult {
                case .canceledRemotely:
                    status = isStemSeparation ? "stem separation canceled" : "denoise canceled"
                    eventName = isStemSeparation ?
                        "music-stem-request-canceled-remotely" :
                        "denoise-request-canceled-remotely"
                case .remoteCancellationUnsupported:
                    status = isStemSeparation ?
                        "stem separation canceled locally; provider cancellation unavailable" :
                        "denoise canceled locally; provider cancellation unavailable"
                    eventName = isStemSeparation ?
                        "music-stem-request-cancel-unsupported" :
                        "denoise-request-cancel-unsupported"
                }
                if
                    let trackID = self.activeDenoiseTrackID,
                    let displaySelection = self.activeDenoiseDisplaySelection
                {
                    let trackName = self.projectTracks.first(where: { $0.id == trackID })?.name ?? "Unknown Track"
                    self.recordDenoiseAPIEvent(
                        severity: cancellationResult == .canceledRemotely ? .info : .warning,
                        name: eventName,
                        message: status,
                        provider: provider,
                        requestID: requestID,
                        trackID: trackID,
                        trackName: trackName,
                        selection: displaySelection
                    )
                }
                self.finishDenoiseProcessing(
                    requestID: requestID,
                    status: status,
                    fadesHighlight: true
                )
            }
        }
    }

    private func finishDenoiseProcessing(
        requestID: UUID,
        status: String,
        fadesHighlight: Bool,
        showsStatus: Bool = true
    ) {
        guard activeDenoiseRequestID == requestID else {
            return
        }

        let trackID = activeDenoiseTrackID
        activeDenoiseTask = nil
        activeDenoiseProvider = nil
        activeDenoiseRequestID = nil
        activeDenoiseTrackID = nil
        activeDenoiseDisplaySelection = nil
        pendingDenoiseReview = nil
        pendingStemSeparationReview = nil
        activeAudioProcessingOperation = nil
        denoiseProgressOverlay.hide()
        denoiseReviewOverlay.hide()
        stemSeparationReviewOverlay.hide()
        timelineSurface.displayProcessingSelectionProgress(selection: nil, fractionCompleted: nil)
        setDenoiseModalInteractionLocked(false)
        timelineSurface.displayModalBackdropActive(false)
        updateStatus(showsStatus ? status : "ready")
        updateEffectCommandState()
        updateTransportControlState(isPlaying: playbackController.isPlaying)
        clearDenoiseProcessingHighlight(trackID: trackID, fadesHighlight: fadesHighlight)
        window?.makeFirstResponder(timelineSurface)
    }

    private func clearDenoiseProcessingHighlight(trackID: UUID?, fadesHighlight: Bool) {
        denoiseHighlightFadeTask?.cancel()
        denoiseHighlightFadeTask = nil

        guard let trackID, fadesHighlight else {
            timelineSurface.displayProcessingTrackHighlight(trackID: nil, alpha: 0)
            return
        }

        denoiseHighlightFadeTask = Task { [weak self, trackID] in
            let steps = 12
            for step in 0...steps {
                if Task.isCancelled {
                    return
                }

                let progress = Float(step) / Float(steps)
                let alpha = 1 - progress * progress * (3 - 2 * progress)
                await MainActor.run {
                    self?.timelineSurface.displayProcessingTrackHighlight(trackID: trackID, alpha: alpha)
                }
                try? await Task.sleep(for: .milliseconds(14))
            }

            await MainActor.run { [weak self] in
                self?.timelineSurface.displayProcessingTrackHighlight(trackID: nil, alpha: 0)
                self?.denoiseHighlightFadeTask = nil
            }
        }
    }

    private nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }

    private nonisolated static func processDenoiseSelection(
        requestID: UUID,
        provider: AudioProcessingProvider,
        trackID: UUID,
        trackName: String,
        sourceURL: URL,
        currentTimeline: AudioEditTimeline?,
        currentFileTimeline: AudioFileEditTimeline?,
        selection: TimelineSelection,
        inputURL: URL,
        outputDirectory: URL,
        progress: @escaping AudioProcessingProgressHandler
    ) async throws -> DenoiseProcessingResult {
        progress(AudioProcessingProgress(
            requestID: requestID,
            stage: .preparing,
            fractionCompleted: 0.04,
            message: "rendering selected audio"
        ))
        let timeline: AudioEditTimeline
        if let currentTimeline {
            timeline = currentTimeline
        } else if let currentFileTimeline {
            let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
            timeline = currentFileTimeline.audioTimeline(sourceBuffer: sourceBuffer)
        } else {
            throw PlaybackError.invalidFormat
        }

        let renderedSelection = timeline.render(selection: selection)
        guard renderedSelection.frameCount > 0 else {
            throw PlaybackError.noAudioLoaded
        }

        try WAVFileWriter.write(renderedSelection, to: inputURL)
        try Task.checkCancellation()
        let inputAsset = AudioProcessingInputAsset(
            id: UUID(),
            trackID: trackID,
            url: inputURL,
            displayName: trackName,
            sampleRate: renderedSelection.sampleRate,
            channelCount: renderedSelection.channelCount,
            frameCount: renderedSelection.frameCount,
            timelineStartTime: selection.startProgress * timeline.duration
        )
        let request = AudioProcessingRequest(
            id: requestID,
            operation: .denoise,
            renderMode: .perTrackSelection,
            inputAssets: [inputAsset],
            outputDirectory: outputDirectory
        )
        let processedResult = try await provider.process(request, progress: progress)
        guard
            let outputAsset = processedResult.outputAssets.first(where: { $0.inputAssetID == inputAsset.id }) ??
                processedResult.outputAssets.first
        else {
            throw LocalDenoiseAudioProcessingProvider.ProcessingError.missingInput
        }

        progress(AudioProcessingProgress(
            requestID: requestID,
            stage: .applying,
            fractionCompleted: 0.92,
            message: "preparing denoised waveform"
        ))
        let rawProcessedBuffer = try WAVAudioDecoder.decode(url: outputAsset.url)
        let processedBuffer = normalizedProcessingOutput(
            rawProcessedBuffer,
            toMatch: renderedSelection
        )
        return DenoiseProcessingResult(
            materialized: try materializePaste(
                timeline: timeline,
                selection: selection,
                clipboardBuffer: processedBuffer
            ),
            beforeBuffer: renderedSelection,
            afterBuffer: processedBuffer,
            processedFrameCount: processedBuffer.frameCount,
            providerSummary: processedResult.summary
        )
    }

    private nonisolated static func processStemSeparationSelection(
        requestID: UUID,
        provider: AudioProcessingProvider,
        trackID: UUID,
        trackName: String,
        sourceURL: URL,
        currentTimeline: AudioEditTimeline?,
        currentFileTimeline: AudioFileEditTimeline?,
        selection: TimelineSelection,
        inputURL: URL,
        outputDirectory: URL,
        progress: @escaping AudioProcessingProgressHandler
    ) async throws -> StemSeparationProcessingResult {
        progress(AudioProcessingProgress(
            requestID: requestID,
            stage: .preparing,
            fractionCompleted: 0.04,
            message: "rendering selected music"
        ))
        let timeline: AudioEditTimeline
        if let currentTimeline {
            timeline = currentTimeline
        } else if let currentFileTimeline {
            let sourceBuffer = try WAVAudioDecoder.decode(url: sourceURL)
            timeline = currentFileTimeline.audioTimeline(sourceBuffer: sourceBuffer)
        } else {
            throw PlaybackError.invalidFormat
        }

        let renderedSelection = timeline.render(selection: selection)
        guard renderedSelection.frameCount > 0 else {
            throw PlaybackError.noAudioLoaded
        }

        try WAVFileWriter.write(renderedSelection, to: inputURL)
        try Task.checkCancellation()
        let inputAsset = AudioProcessingInputAsset(
            id: UUID(),
            trackID: trackID,
            url: inputURL,
            displayName: trackName,
            sampleRate: renderedSelection.sampleRate,
            channelCount: renderedSelection.channelCount,
            frameCount: renderedSelection.frameCount,
            timelineStartTime: selection.startProgress * timeline.duration
        )
        let request = AudioProcessingRequest(
            id: requestID,
            operation: .separateMusicStems,
            renderMode: .perTrackSelection,
            inputAssets: [inputAsset],
            outputDirectory: outputDirectory
        )
        let processedResult = try await provider.process(request, progress: progress)
        let matchingOutputs = processedResult.outputAssets.filter { $0.inputAssetID == inputAsset.id }
        let outputAssets = matchingOutputs.isEmpty ? processedResult.outputAssets : matchingOutputs
        guard !outputAssets.isEmpty else {
            throw AudioShakeAudioProcessingProvider.ProcessingError.missingOutput
        }

        progress(AudioProcessingProgress(
            requestID: requestID,
            stage: .applying,
            fractionCompleted: 0.92,
            message: "preparing separated waveforms"
        ))
        let stems = try outputAssets.map { outputAsset in
            let rawStemBuffer = try WAVAudioDecoder.decode(url: outputAsset.url)
            let stemBuffer = normalizedProcessingOutput(rawStemBuffer, toMatch: renderedSelection)
            return StemSeparationStemResult(
                name: outputAsset.displayName ?? outputAsset.url.deletingPathExtension().lastPathComponent,
                buffer: stemBuffer
            )
        }
        return StemSeparationProcessingResult(
            beforeBuffer: renderedSelection,
            stems: stems,
            timelineStartTime: inputAsset.timelineStartTime,
            providerSummary: processedResult.summary
        )
    }

    private nonisolated static func normalizedProcessingOutput(
        _ processedBuffer: DecodedAudioBuffer,
        toMatch referenceBuffer: DecodedAudioBuffer
    ) -> DecodedAudioBuffer {
        guard
            referenceBuffer.frameCount > 0,
            referenceBuffer.channelCount > 0,
            referenceBuffer.sampleRate > 0
        else {
            return processedBuffer
        }

        let channelCount = referenceBuffer.channelCount
        let frameCount = referenceBuffer.frameCount
        let sourceFrameCount = max(processedBuffer.frameCount, 1)
        var samplesByChannel = (0..<channelCount).map { _ in
            [Float](repeating: 0, count: frameCount)
        }

        for channelIndex in 0..<channelCount {
            let sourceChannel = processedBuffer.channelCount == 1 ?
                0 :
                min(channelIndex, max(processedBuffer.channelCount - 1, 0))
            guard
                processedBuffer.samplesByChannel.indices.contains(sourceChannel),
                !processedBuffer.samplesByChannel[sourceChannel].isEmpty
            else {
                continue
            }

            let sourceSamples = processedBuffer.samplesByChannel[sourceChannel]
            if sourceSamples.count == frameCount {
                samplesByChannel[channelIndex] = sourceSamples
                continue
            }

            for frameIndex in 0..<frameCount {
                let sourcePosition = Double(frameIndex) *
                    Double(max(sourceFrameCount - 1, 0)) /
                    Double(max(frameCount - 1, 1))
                let lowerIndex = min(max(Int(sourcePosition.rounded(.down)), 0), sourceSamples.count - 1)
                let upperIndex = min(lowerIndex + 1, sourceSamples.count - 1)
                let fraction = Float(sourcePosition - Double(lowerIndex))
                samplesByChannel[channelIndex][frameIndex] =
                    sourceSamples[lowerIndex] +
                    (sourceSamples[upperIndex] - sourceSamples[lowerIndex]) * fraction
            }
        }

        return DecodedAudioBuffer(
            url: processedBuffer.url,
            sampleRate: referenceBuffer.sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            samplesByChannel: samplesByChannel
        )
    }

    private nonisolated static func bufferByPaddingLeadingSilence(
        _ buffer: DecodedAudioBuffer,
        leadingDuration: TimeInterval
    ) -> DecodedAudioBuffer {
        let leadingFrameCount = max(Int((leadingDuration * buffer.sampleRate).rounded()), 0)
        guard leadingFrameCount > 0, buffer.channelCount > 0 else {
            return buffer
        }

        let samplesByChannel = buffer.samplesByChannel.map { samples in
            [Float](repeating: 0, count: leadingFrameCount) + samples
        }
        return DecodedAudioBuffer(
            url: buffer.url,
            sampleRate: buffer.sampleRate,
            channelCount: buffer.channelCount,
            frameCount: leadingFrameCount + buffer.frameCount,
            samplesByChannel: samplesByChannel
        )
    }

    private func previewSelectedGain(_ gain: Float) {
        guard let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget(), canApplyGainEffect else {
            timelineSurface.displayGainPreview(selection: nil, gain: 1)
            return
        }

        timelineSurface.displayGainPreview(selection: target.displaySelection, gain: gain)
    }

    private func cancelSelectedGainPreview() {
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        updateStatus(currentPlaybackStatus)
    }

    private func confirmSelectedGain(decibels: Double, gain: Float) {
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        applyGainEffect(decibels: decibels, gain: gain)
    }

    private func applyGainEffect(
        decibels: Double,
        gain: Float,
        status: String? = nil,
        lastEffect: LastEffect? = nil
    ) {
        guard
            let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget()
        else {
            return
        }

        let trackIndex = target.trackIndex
        let selectionToApply = target.editSelection
        let trackID = projectTracks[trackIndex].id
        let editRevision: Int
        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
        let undoSnapshot = captureProjectTrackUndoSnapshot(restoreProgress: nil)

        if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            let affectedFrameCount = timeline.applyGain(gain, to: selectionToApply)
            guard affectedFrameCount > 0 else {
                return
            }

            editUndoStack.append(.projectTracks(undoSnapshot))
            editedAudioTimeline = nil
            editedFileTimeline = timeline
        } else if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            var timeline = currentTimeline
            let affectedFrameCount = timeline.applyGain(gain, to: selectionToApply)
            guard affectedFrameCount > 0 else {
                return
            }

            editUndoStack.append(.projectTracks(undoSnapshot))
            editedAudioTimeline = timeline
            editedFileTimeline = nil
        } else {
            let currentFileTimeline: AudioFileEditTimeline
            do {
                currentFileTimeline = try editableFileTimeline(forTrackAt: trackIndex)
            } catch {
                updateStatus("gain failed: \(error.localizedDescription)")
                return
            }

            var timeline = currentFileTimeline
            let affectedFrameCount = timeline.applyGain(gain, to: selectionToApply)
            guard affectedFrameCount > 0 else {
                return
            }

            editUndoStack.append(.projectTracks(undoSnapshot))
            editedAudioTimeline = nil
            editedFileTimeline = timeline
        }

        projectTracks[trackIndex].editRevision += 1
        editRevision = projectTracks[trackIndex].editRevision
        applyEditedTimelineState(
            trackIndex: trackIndex,
            editedAudioTimeline: editedAudioTimeline,
            editedFileTimeline: editedFileTimeline,
            editedDuration: editedFileTimeline?.duration ?? editedAudioTimeline?.duration ?? 0
        )
        let currentOverview = projectTracks[trackIndex].waveformOverview
        if let editedFileTimeline {
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    currentOverview,
                    applyingGain: gain,
                    to: selectionToApply
                ) ??
                optimisticWaveformOverview(
                    for: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trackID,
                fileTimeline: editedFileTimeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision
            )
        } else {
            projectTracks[trackIndex].waveformOverview = optimisticWaveformOverview(
                currentOverview,
                applyingGain: gain,
                to: selectionToApply
            )
            cancelEditWaveformRefinement(for: trackID)
        }
        let status = status ?? String(format: "gain %+.1f dB", decibels)
        self.lastEffect = lastEffect ?? .gain(decibels: decibels)
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        updateEffectCommandState()
        updateStatus(status)

        if let editedAudioTimeline {
            materializeEditedTimeline(
                trackID: trackID,
                timeline: editedAudioTimeline,
                editRevision: editRevision,
                status: status,
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay
            )
        }
    }

    private func applyFadeEffect(_ fadeEffect: FadeEffect) {
        guard
            let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget()
        else {
            return
        }

        let trackIndex = target.trackIndex
        let selectionToApply = target.editSelection
        let timelineFadeDirection: AudioEditTimeline.FadeDirection
        switch fadeEffect {
        case .fadeIn:
            timelineFadeDirection = .fadeIn
        case .fadeOut:
            timelineFadeDirection = .fadeOut
        }

        let trackID = projectTracks[trackIndex].id
        activeTrackID = trackID
        let selectedDuration: TimeInterval
        let editRevision: Int
        let editedAudioTimeline: AudioEditTimeline?
        let editedFileTimeline: AudioFileEditTimeline?
        let undoSnapshot = captureProjectTrackUndoSnapshot(restoreProgress: nil)

        if let currentFileTimeline = try? preferredFileTimelineForEditing(trackIndex: trackIndex) {
            var timeline = currentFileTimeline
            let affectedFrameCount = timeline.applyFade(timelineFadeDirection, to: selectionToApply)
            guard affectedFrameCount > 1 else {
                return
            }

            selectedDuration = selectionToApply.duration(in: currentFileTimeline.duration)
            editUndoStack.append(.projectTracks(undoSnapshot))
            editedAudioTimeline = nil
            editedFileTimeline = timeline
        } else if let currentTimeline = projectTracks[trackIndex].audioTimeline {
            var timeline = currentTimeline
            let affectedFrameCount = timeline.applyFade(timelineFadeDirection, to: selectionToApply)
            guard affectedFrameCount > 1 else {
                return
            }

            selectedDuration = selectionToApply.duration(in: currentTimeline.duration)
            editUndoStack.append(.projectTracks(undoSnapshot))
            editedAudioTimeline = timeline
            editedFileTimeline = nil
        } else {
            let currentFileTimeline: AudioFileEditTimeline
            do {
                currentFileTimeline = try editableFileTimeline(forTrackAt: trackIndex)
            } catch {
                updateStatus("\(fadeEffect.displayName) failed: \(error.localizedDescription)")
                return
            }

            var timeline = currentFileTimeline
            let affectedFrameCount = timeline.applyFade(timelineFadeDirection, to: selectionToApply)
            guard affectedFrameCount > 1 else {
                return
            }

            selectedDuration = selectionToApply.duration(in: currentFileTimeline.duration)
            editUndoStack.append(.projectTracks(undoSnapshot))
            editedAudioTimeline = nil
            editedFileTimeline = timeline
        }

        projectTracks[trackIndex].editRevision += 1
        editRevision = projectTracks[trackIndex].editRevision
        applyEditedTimelineState(
            trackIndex: trackIndex,
            editedAudioTimeline: editedAudioTimeline,
            editedFileTimeline: editedFileTimeline,
            editedDuration: editedFileTimeline?.duration ?? editedAudioTimeline?.duration ?? 0
        )
        let currentOverview = projectTracks[trackIndex].waveformOverview
        if let editedFileTimeline {
            projectTracks[trackIndex].waveformOverview =
                optimisticWaveformOverview(
                    currentOverview,
                    applyingFade: timelineFadeDirection,
                    to: selectionToApply
                ) ??
                optimisticWaveformOverview(
                    for: editedFileTimeline,
                    sourceOverview: projectTracks[trackIndex].sourceWaveformOverview,
                    fallbackOverview: currentOverview
                )
            scheduleFileTimelineWaveformRefinement(
                trackID: trackID,
                fileTimeline: editedFileTimeline,
                sourceOverview: projectTracks[trackIndex].sourceWaveformOverview ?? currentOverview,
                editRevision: editRevision
            )
        } else {
            projectTracks[trackIndex].waveformOverview = optimisticWaveformOverview(
                currentOverview,
                applyingFade: timelineFadeDirection,
                to: selectionToApply
            )
            cancelEditWaveformRefinement(for: trackID)
        }
        lastEffect = .fade(fadeEffect)
        selectedTimelineRange = nil
        timelineSurface.displaySelection(nil)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        updateEffectCommandState()
        let status = "\(fadeEffect.displayName) \(formatDuration(selectedDuration))"
        updateStatus(status)

        if let editedAudioTimeline {
            materializeEditedTimeline(
                trackID: trackID,
                timeline: editedAudioTimeline,
                editRevision: editRevision,
                status: status,
                preservePlaybackProgress: true,
                startDelay: editMaterializationDelay
            )
        }
    }

    private func undoLastEdit() {
        guard !editUndoStack.isEmpty else {
            return
        }

        isNavigatingEditHistory = true
        defer {
            isNavigatingEditHistory = false
        }
        guard let undoAction = editUndoStack.popLast() else {
            return
        }

        switch undoAction {
        case let .projectTracks(snapshot):
            let redoSnapshot = captureProjectTrackUndoSnapshot(
                restoreProgress: playbackController.snapshot().progress
            )
            restoreProjectTracks(from: snapshot)
            editRedoStack.append(.projectTracks(redoSnapshot))
        case let .transaction(record):
            do {
                try restoreProjectEditTransactionState(
                    record.before,
                    command: record.command,
                    direction: .undo,
                    operation: "undo",
                    clearsSelection: record.command.kind == .paste
                )
                editRedoStack.append(.transaction(record))
            } catch {
                editUndoStack.append(.transaction(record))
                updateStatus("undo failed: \(error.localizedDescription)")
            }
        }
    }

    private func redoLastEdit() {
        guard !editRedoStack.isEmpty else {
            return
        }

        isNavigatingEditHistory = true
        defer {
            isNavigatingEditHistory = false
        }
        guard let redoAction = editRedoStack.popLast() else {
            return
        }
        switch redoAction {
        case let .projectTracks(snapshot):
            let undoSnapshot = captureProjectTrackUndoSnapshot(
                restoreProgress: playbackController.snapshot().progress
            )
            restoreProjectTracks(from: snapshot)
            editUndoStack.append(.projectTracks(undoSnapshot))
            updateStatus("redo")
        case let .transaction(record):
            do {
                try restoreProjectEditTransactionState(
                    record.after,
                    command: record.command,
                    direction: .redo,
                    operation: "redo"
                )
                editUndoStack.append(.transaction(record))
            } catch {
                editRedoStack.append(.transaction(record))
                updateStatus("redo failed: \(error.localizedDescription)")
            }
        }
    }

    private func restoreProjectEditTransactionState(
        _ state: ProjectEditTransactionState,
        command: EditCommand,
        direction: EditHistoryDirection,
        operation: String,
        clearsSelection: Bool = false
    ) throws {
        let startedAt = CACurrentMediaTime()
        let restoredTrackIDs = Set(state.tracksByID.keys)
        guard projectTracks.map(\.id) == state.projectTrackIDs else {
            throw EditTransactionError.changedProjectTopology
        }
        let trackIndexesByID = state.trackIndexesByID
        let hasValidTrackIndexes = restoredTrackIDs.allSatisfy { trackID in
            guard
                let index = trackIndexesByID[trackID],
                projectTracks.indices.contains(index)
            else {
                return false
            }
            return projectTracks[index].id == trackID
        }
        guard
            trackIndexesByID.count == restoredTrackIDs.count,
            hasValidTrackIndexes
        else {
            throw EditTransactionError.missingTrack(
                restoredTrackIDs.first ?? state.projectTrackIDs.first ?? UUID()
            )
        }
        let indexedAt = CACurrentMediaTime()

        var nextTracks = projectTracks
        for (trackID, restoredTrack) in state.tracksByID {
            guard let index = trackIndexesByID[trackID] else {
                throw EditTransactionError.missingTrack(trackID)
            }
            nextTracks[index] = restoredTrack
        }
        let tracksPreparedAt = CACurrentMediaTime()

        for trackID in restoredTrackIDs {
            cancelEditMaterialization(for: trackID)
        }
        cancelDeleteVisualHandoff()
        let nextRevision = projectEditRevision().advanced()
        projectTracks = nextTracks
        projectEditGraph = state.editGraph
        currentEditGraphRevision = nextRevision.rawValue
        clearTranscriptInteractionStateIfNeeded(
            forTracks: state.tracksByID.values
        )

        activeTrackID = state.activeTrackID ?? projectTracks.last?.id
        selectedTrackID = state.selectedTrackID
        selectedTrackIDs = state.selectedTrackIDs
        if let selectedTrackID {
            selectedTrackIDs.insert(selectedTrackID)
        }
        trackSelectionAnchorID = selectedTrackID
        selectedTimelineRange = clearsSelection ? nil : state.selectedTimelineRange
        audioClipboard = state.clipboard
        syncActiveTrackFields()
        displayedSampleRate = state.displayedSampleRate
        displayedFrameCount = state.displayedFrameCount
        let modelRestoredAt = CACurrentMediaTime()

        timelineSurface.clearDeletionEffects()
        timelineSurface.displaySelection(selectedTimelineRange)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        let mixes = projectPlaybackTrackMixes()
        let renderTracks = applyingProjectTrackMixes(
            mixes,
            to: state.renderTracks
        )
        publishedTimelineRenderTracks = renderTracks
        timelineSurface.displayTracks(
            renderTracks,
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false,
            viewportTransition: .animatedEditReframe
        )
        publishSelectedTracksToTimeline()
        publishedTimelineEditRevision = nextRevision.rawValue
        let timelinePublishedAt = CACurrentMediaTime()

        let duration = max(state.projectDuration, 0.000_001)
        // History restoration can spend several milliseconds rebuilding its
        // projections. Sample the running transport at the publication boundary
        // so undo/redo remaps the audio that is actually about to play.
        let transportBeforePublish = playbackController.snapshot()
        let wasPlaying = transportBeforePublish.isPlaying
        let livePlayheadTime = ProjectTime(
            seconds: transportBeforePublish.projectTime ?? currentProjectPlayheadTime().seconds
        )
        let restoredPlayheadTime = EditTransactionPlanner.resolvedHistoryPlayheadTime(
            command: command,
            direction: direction,
            historicalPlayheadTime: state.playheadTime,
            livePlayheadTime: livePlayheadTime,
            isPlaying: wasPlaying,
            restoredProjectDuration: duration
        )
        let remapsRunningPlayhead = wasPlaying && restoredPlayheadTime != livePlayheadTime
        reloadPlaybackFromProjectTracks(
            preserveProgress: false,
            targetProgress: Float(
                min(max(restoredPlayheadTime.seconds / duration, 0), 1)
            ),
            resumeIfPlaying: wasPlaying,
            playbackTracksOverride: ProjectPlaybackProjection.applyingMixes(
                mixes,
                to: state.playbackTracks
            ),
            publishesVisualState: false,
            preservesRunningTransportContinuity: wasPlaying && !remapsRunningPlayhead
        )
        publishedPlaybackEditRevision = nextRevision.rawValue
        let playbackAfterRestore = playbackController.snapshot()
        let displayedPlayheadTime: TimeInterval
        if wasPlaying {
            displayedPlayheadTime = playbackAfterRestore.projectTime ?? restoredPlayheadTime.seconds
        } else {
            displayedPlayheadTime = restoredPlayheadTime.seconds
        }
        snapPlayheadVisuals(
            toTimelineTime: displayedPlayheadTime,
            isPlaying: playbackAfterRestore.isPlaying,
            synchronizesRenderer: true
        )
        updateTransportControlState(isPlaying: playbackController.isPlaying)
        let playbackPublishedAt = CACurrentMediaTime()
        assertPublishedEditRevisionsMatch(context: operation)
        let finishedAt = CACurrentMediaTime()
        latestTransactionHistoryRestoreStageTimings = EditHistoryRestoreStageTimings(
            indexMilliseconds: (indexedAt - startedAt) * 1_000,
            tracksMilliseconds: (tracksPreparedAt - indexedAt) * 1_000,
            modelMilliseconds: (modelRestoredAt - tracksPreparedAt) * 1_000,
            timelineMilliseconds: (timelinePublishedAt - modelRestoredAt) * 1_000,
            playbackMilliseconds: (playbackPublishedAt - timelinePublishedAt) * 1_000,
            finalizeMilliseconds: (finishedAt - playbackPublishedAt) * 1_000
        )
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                self.currentEditGraphRevision == nextRevision.rawValue
            else {
                return
            }
            self.refreshExistingTrackControlStates()
            self.updateLoadedProjectSummary()
            self.updateEffectCommandState()
            self.updateStatus(operation)
        }

        SoundtimeDiagnostics.shared.record(
            category: .edit,
            severity: .info,
            name: "edit-transaction-\(operation)",
            message: "Published an edit transaction history state.",
            fields: [
                "transactionID": command.transactionID.description,
                "kind": command.kind.rawValue,
                "sourceRevision": state.revision.description,
                "publishedRevision": nextRevision.description,
                "trackCount": "\(restoredTrackIDs.count)",
                "elapsedMs": String(format: "%.3f", (finishedAt - startedAt) * 1_000),
            ]
        )
    }

    private func clearTranscriptInteractionStateIfNeeded<Tracks: Sequence>(
        forTracks tracks: Tracks
    ) where Tracks.Element == ProjectTrack {
        guard tracks.contains(where: { $0.transcript != nil }) else {
            return
        }
        selectedTranscriptSelection = nil
        activeTranscriptWordID = nil
        activeTranscriptWordProjectRange = nil
        timelineSurface.displayTranscriptSelection(nil)
        timelineSurface.displayTranscriptActiveWord(nil)
    }

    private func cancelDeleteVisualHandoff() {
        postDeleteRefreshWorkItem?.cancel()
        postDeleteRefreshWorkItem = nil
        deleteAnimationGeneration += 1
    }

    private func restoreProjectTracks(from snapshot: ProjectTrackUndoSnapshot) {
        let restoreStartedAt = CACurrentMediaTime()
        let replacedTracks = projectTracks
        let previousSelectedTrackID = selectedTrackID
        let previousSelectedTrackIDs = selectedTrackIDs
        let preservesTrackTopology = replacedTracks.map(\.id) == snapshot.tracks.map(\.id)
        let preservesTrackControlState = preservesTrackTopology &&
            zip(replacedTracks, snapshot.tracks).allSatisfy { currentTrack, restoredTrack in
                currentTrack.name == restoredTrack.name &&
                    currentTrack.volume == restoredTrack.volume &&
                    currentTrack.isMuted == restoredTrack.isMuted &&
                    currentTrack.isSoloed == restoredTrack.isSoloed
            }
        SoundtimeDiagnostics.shared.record(
            category: .edit,
            severity: .info,
            name: "undo-project-tracks",
            message: "Restoring project tracks from undo snapshot.",
            fields: [
                "trackCount": "\(snapshot.tracks.count)",
                "restoreProgress": snapshot.restoreProgress.map { String(format: "%.9f", $0) } ?? "preserve",
            ]
        )
        cancelAllEditMaterialization()
        projectTracks = snapshot.tracks
        let tracksRestoredAt = CACurrentMediaTime()
        if let editGraph = snapshot.editGraph {
            projectEditGraph = editGraph
            pruneProjectEditGraphToCurrentTracks()
        } else {
            rebuildProjectEditGraphFromTrackMirrors()
        }
        let editGraphRestoredAt = CACurrentMediaTime()
        activeTrackID = snapshot.activeTrackID.flatMap { activeID in
            projectTracks.contains(where: { $0.id == activeID }) ? activeID : nil
        } ?? projectTracks.last?.id
        selectedTrackID = snapshot.selectedTrackID.flatMap { selectedID in
            projectTracks.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }
        let liveTrackIDs = Set(projectTracks.map(\.id))
        selectedTrackIDs = snapshot.selectedTrackIDs.intersection(liveTrackIDs)
        if let selectedTrackID {
            selectedTrackIDs.insert(selectedTrackID)
        }
        trackSelectionAnchorID = selectedTrackID
        selectedTimelineRange = snapshot.selectedTimelineRange
        syncActiveTrackFields()
        updateProjectDisplayTiming()
        timelineSurface.clearDeletionEffects()
        timelineSurface.displaySelection(selectedTimelineRange)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        let restoredRenderTracks = snapshot.renderTracks ?? timelineRenderTracks()
        publishedTimelineRenderTracks = restoredRenderTracks
        timelineSurface.displayTracks(
            restoredRenderTracks,
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false,
            viewportTransition: .animatedEditReframe
        )
        publishSelectedTracksToTimeline()
        if preservesTrackTopology {
            if
                !preservesTrackControlState ||
                previousSelectedTrackID != selectedTrackID ||
                previousSelectedTrackIDs != selectedTrackIDs
            {
                refreshExistingTrackControlStates()
            }
        } else {
            refreshTrackControls()
        }
        let timelinePublishedAt = CACurrentMediaTime()
        reloadPlaybackFromProjectTracks(
            preserveProgress: snapshot.restoreProgress == nil,
            targetProgress: snapshot.restoreProgress,
            playbackTracksOverride: snapshot.playbackTracks
        )
        let playbackPublishedAt = CACurrentMediaTime()
        updateStatus("undo")
        let finishedAt = CACurrentMediaTime()
        let totalMilliseconds = (finishedAt - restoreStartedAt) * 1_000
        latestUndoRestoreStageMilliseconds = [
            "tracksMs": (tracksRestoredAt - restoreStartedAt) * 1_000,
            "editGraphMs": (editGraphRestoredAt - tracksRestoredAt) * 1_000,
            "timelineMs": (timelinePublishedAt - editGraphRestoredAt) * 1_000,
            "playbackMs": (playbackPublishedAt - timelinePublishedAt) * 1_000,
            "finalizeMs": (finishedAt - playbackPublishedAt) * 1_000,
            "totalMs": totalMilliseconds,
        ]
        if totalMilliseconds > 16 {
            SoundtimeDiagnostics.shared.record(
                category: .edit,
                severity: .warning,
                name: "undo-project-tracks-complete",
                message: "Project track undo restoration exceeded its interaction budget.",
                fields: [
                    "trackCount": "\(snapshot.tracks.count)",
                    "tracksMs": String(format: "%.3f", (tracksRestoredAt - restoreStartedAt) * 1_000),
                    "editGraphMs": String(format: "%.3f", (editGraphRestoredAt - tracksRestoredAt) * 1_000),
                    "timelineMs": String(format: "%.3f", (timelinePublishedAt - editGraphRestoredAt) * 1_000),
                    "playbackMs": String(format: "%.3f", (playbackPublishedAt - timelinePublishedAt) * 1_000),
                    "finalizeMs": String(format: "%.3f", (finishedAt - playbackPublishedAt) * 1_000),
                    "totalMs": String(format: "%.3f", totalMilliseconds),
                ]
            )
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateEffectCommandState()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.cleanupOwnedSourceFiles(replacedTracks: replacedTracks)
        }
    }

    private func cancelEditMaterialization(for trackID: UUID) {
        editMaterializationTasks.cancel(trackID)
        cancelOptimisticDeleteWaveformUpdate(for: trackID)
        cancelEditWaveformRefinement(for: trackID)
    }

    private func cancelOptimisticDeleteWaveformUpdate(for trackID: UUID) {
        optimisticDeleteWaveformTasks.cancel(trackID)
    }

    private func cancelEditWaveformRefinement(for trackID: UUID) {
        editWaveformRefinementTasks.cancel(trackID)
    }

    private func cancelAllEditMaterialization() {
        cancelPendingPostDeleteRefresh()
        scheduledPlaybackReloadWorkItem?.cancel()
        scheduledPlaybackReloadWorkItem = nil
        editMaterializationTasks.cancelAll()
        optimisticDeleteWaveformTasks.cancelAll()
        editWaveformRefinementTasks.cancelAll()
    }

    private func beginDeleteAnimationCriticalSection() -> Int {
        cancelPendingPostDeleteRefresh()
        scheduledPlaybackReloadWorkItem?.cancel()
        scheduledPlaybackReloadWorkItem = nil
        editMaterializationTasks.cancelAll()
        editWaveformRefinementTasks.cancelAll()
        optimisticDeleteWaveformTasks.cancelAll()
        deleteAnimationGeneration += 1
        deleteAutosaveProtectedUntil = max(
            deleteAutosaveProtectedUntil,
            CACurrentMediaTime() + max(deletePostAnimationDisplayRefreshDelay, deleteMaterializationDelay) + 0.25
        )
        if autosaveWorkItem != nil {
            scheduleAutosaveIfNeeded()
        }
        return deleteAnimationGeneration
    }

    private func cancelPendingPostDeleteRefresh() {
        postDeleteRefreshWorkItem?.cancel()
        postDeleteRefreshWorkItem = nil
        deleteAnimationGeneration += 1
    }

    private func togglePlayback() {
        guard !isDenoiseProcessingActive else {
            updateTransportControlState(isPlaying: false)
            return
        }

        if recordingTrackID != nil {
            stopRecording()
            return
        }

        flushScheduledPlaybackReloadIfNeeded()

        guard playbackController.hasSource else {
            return
        }

        do {
            let snapshot = playbackController.snapshot()
            let wasPlaying = snapshot.isPlaying
            let isPlaying: Bool
            if wasPlaying {
                let pauseProgress = displayedDuration > 0 ?
                    timelineSurface.pausePresentationPlayheadProgress() :
                    nil
                playbackController.pause(atProgress: max(pauseProgress ?? snapshot.progress, snapshot.progress))
                setTimelineLoopPlaybackBypassed(false)
                isPlaying = false
            } else {
                setTimelineLoopPlaybackBypassed(false)
                if let loopStartProgress = activeTimelineLoopStartProgress() {
                    try playbackController.seekExactly(toProgress: loopStartProgress)
                }
                try playbackController.play()
                isPlaying = true
            }
            previousLoopPlaybackProgress = nil
            refreshPlaybackProgress(syncPlayheadWhenPlaying: true)

            if isPlaying {
                startPlaybackTimer()
                updateStatus("playing")
            } else {
                stopPlaybackTimer()
                updateStatus("paused")
            }
        } catch {
            stopPlaybackTimer()
            updateStatus("playback failed: \(error.localizedDescription)")
        }
    }

    private func seek(to progress: Float) {
        guard playbackController.hasSource else {
            return
        }

        let previousLoopPlaybackBypass = isTimelineLoopPlaybackBypassed
        do {
            let wasPlaying = playbackController.isPlaying
            previousLoopPlaybackProgress = nil
            updateTimelineLoopPlaybackBypassForExplicitSeek(
                to: progress,
                whilePlaying: wasPlaying
            )
            try playbackController.seek(toProgress: progress)
            refreshPlaybackProgress(
                syncPlayheadWhenPlaying: true,
                restartsFisheyeActivation: wasPlaying && playbackController.isPlaying,
                restartsPlayheadKick: wasPlaying && playbackController.isPlaying
            )

            if playbackController.isPlaying {
                startPlaybackTimer()
                updateStatus("playing")
            } else {
                stopPlaybackTimer()
                updateStatus("ready")
            }
        } catch {
            setTimelineLoopPlaybackBypassed(previousLoopPlaybackBypass)
            stopPlaybackTimer()
            updateStatus("seek failed: \(error.localizedDescription)")
        }
    }

    private func skipPlayback(by delta: TimeInterval) {
        guard playbackController.hasSource else {
            return
        }
        markTimelineHotInteraction(reason: "keyboard-skip")

        let duration = projectSelectionDuration
        guard duration > 0 else {
            return
        }

        let snapshot = playbackController.snapshot()
        let currentTime = min(max(TimeInterval(snapshot.progress) * duration, 0), duration)
        let targetTime = min(max(currentTime + delta, 0), duration)
        let actualDelta = targetTime - currentTime
        let targetProgress = Float(targetTime / duration)

        let previousLoopPlaybackBypass = isTimelineLoopPlaybackBypassed
        do {
            let wasPlaying = snapshot.isPlaying
            previousLoopPlaybackProgress = nil
            updateTimelineLoopPlaybackBypassForExplicitSeek(
                to: targetProgress,
                whilePlaying: wasPlaying
            )
            try playbackController.seekExactly(toProgress: targetProgress)
            refreshPlaybackProgress(
                syncPlayheadWhenPlaying: true,
                restartsFisheyeActivation: wasPlaying && playbackController.isPlaying,
                restartsPlayheadKick: false
            )
            timelineSurface.displayPlayheadJumpTrail(
                from: Float(currentTime / duration),
                to: targetProgress
            )
            if playbackController.isPlaying {
                startPlaybackTimer()
            } else {
                stopPlaybackTimer()
            }
            updateStatus(
                actualDelta >= 0 ?
                    "skipped ahead \(formatDuration(abs(actualDelta)))" :
                    "skipped back \(formatDuration(abs(actualDelta)))"
            )
        } catch {
            setTimelineLoopPlaybackBypassed(previousLoopPlaybackBypass)
            stopPlaybackTimer()
            updateStatus("skip failed: \(error.localizedDescription)")
        }
    }

    private func play(from progress: Float) {
        guard playbackController.hasSource else {
            return
        }
        markTimelineHotInteraction(reason: "play-from-progress")

        let previousLoopPlaybackBypass = isTimelineLoopPlaybackBypassed
        do {
            let wasPlaying = playbackController.isPlaying
            previousLoopPlaybackProgress = nil
            updateTimelineLoopPlaybackBypassForExplicitSeek(
                to: progress,
                whilePlaying: true
            )
            try playbackController.seek(toProgress: progress)

            if !playbackController.isPlaying {
                try playbackController.play()
            }

            refreshPlaybackProgress(
                syncPlayheadWhenPlaying: true,
                restartsFisheyeActivation: wasPlaying && playbackController.isPlaying,
                restartsPlayheadKick: wasPlaying && playbackController.isPlaying
            )
            startPlaybackTimer()
            updateStatus("playing")
        } catch {
            setTimelineLoopPlaybackBypassed(previousLoopPlaybackBypass)
            stopPlaybackTimer()
            updateStatus("playback failed: \(error.localizedDescription)")
        }
    }

    private func exportCurrentAudio() {
        guard canPresentNewAudioExport() else {
            return
        }
        guard canCreateAudioExportSnapshot(for: .fullMixdown) else {
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Export Audio"
        savePanel.nameFieldStringValue = suggestedExportFilename()
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.allowedContentTypes = supportedAudioExportContentTypes()
        let exportOptions = AudioExportOptionsAccessoryView(
            includesCompressedOptions: true,
            includesStemOptions: false
        )
        savePanel.accessoryView = exportOptions

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard
                response == .OK,
                let destinationURL = savePanel.url
            else {
                return
            }

            self?.beginAudioExport(
                scope: .fullMixdown,
                destinationURL: destinationURL,
                format: AudioExportFormat(destinationURL: destinationURL),
                wavEncoding: exportOptions.wavEncoding,
                compressedQuality: exportOptions.compressedQuality
            )
        }

        if let window {
            savePanel.beginSheetModal(for: window, completionHandler: completion)
        } else if savePanel.runModal() == .OK, let destinationURL = savePanel.url {
            beginAudioExport(
                scope: .fullMixdown,
                destinationURL: destinationURL,
                format: AudioExportFormat(destinationURL: destinationURL),
                wavEncoding: exportOptions.wavEncoding,
                compressedQuality: exportOptions.compressedQuality
            )
        }
    }

    private func exportWAVMixdown() {
        guard canPresentNewAudioExport() else {
            return
        }
        guard canCreateAudioExportSnapshot(for: .fullMixdown) else {
            updateStatus("load audio before exporting")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Export WAV"
        savePanel.nameFieldStringValue = suggestedExportFilename()
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.allowedContentTypes = [.wav]
        let exportOptions = AudioExportOptionsAccessoryView(
            includesCompressedOptions: false,
            includesStemOptions: false
        )
        savePanel.accessoryView = exportOptions

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destinationURL = savePanel.url else {
                return
            }

            self?.beginAudioExport(
                scope: .fullMixdown,
                destinationURL: destinationURL,
                format: .wav,
                wavEncoding: exportOptions.wavEncoding
            )
        }

        if let window {
            savePanel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(savePanel.runModal())
        }
    }

    private func exportSelectedRegion() {
        guard
            let selectedTimelineRange,
            selectedTimelineRange.durationProgress > 0
        else {
            updateStatus("select audio to export")
            return
        }

        let scope = AudioExportScope.timeRange(selectedTimelineRange)
        presentSelectedRegionExportPanel(scope: scope)
    }

    private func exportSelectedRegionFromContextMenu() {
        guard
            let selectedTimelineRange,
            selectedTimelineRange.durationProgress > 0
        else {
            updateStatus("select audio to export")
            return
        }

        let scope: AudioExportScope
        if let trackID = selectedTimelineRange.trackID {
            scope = .trackRange(trackID: trackID, selection: selectedTimelineRange)
        } else {
            scope = .timeRange(selectedTimelineRange)
        }
        presentSelectedRegionExportPanel(scope: scope)
    }

    private func presentSelectedRegionExportPanel(scope: AudioExportScope) {
        guard canPresentNewAudioExport() else {
            return
        }
        guard canCreateAudioExportSnapshot(for: scope) else {
            updateStatus("load audio before exporting")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Export Selected Region"
        savePanel.nameFieldStringValue = suggestedSelectedRegionExportFilename()
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.allowedContentTypes = supportedAudioExportContentTypes()
        let exportOptions = AudioExportOptionsAccessoryView(
            includesCompressedOptions: true,
            includesStemOptions: false
        )
        savePanel.accessoryView = exportOptions

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destinationURL = savePanel.url else {
                return
            }

            self?.beginAudioExport(
                scope: scope,
                destinationURL: destinationURL,
                format: AudioExportFormat(destinationURL: destinationURL),
                wavEncoding: exportOptions.wavEncoding,
                compressedQuality: exportOptions.compressedQuality
            )
        }

        if let window {
            savePanel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(savePanel.runModal())
        }
    }

    private func exportMixdownAndStems() {
        exportStemSet(includeMixdown: true)
    }

    private func exportStems() {
        exportStemSet(includeMixdown: false)
    }

    private func exportStemSet(includeMixdown: Bool) {
        guard canPresentNewAudioExport() else {
            return
        }
        let scope = AudioExportScope.stems(includeMixdown: includeMixdown, selection: nil)
        guard canCreateAudioExportSnapshot(for: scope) else {
            updateStatus("load tracks before exporting stems")
            return
        }

        let openPanel = NSOpenPanel()
        openPanel.title = includeMixdown ? "Export Mixdown Plus Stems" : "Export Stems"
        openPanel.prompt = "Export"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        let exportOptions = AudioExportOptionsAccessoryView(
            includesCompressedOptions: false,
            includesStemOptions: true
        )
        openPanel.accessoryView = exportOptions

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let folderURL = openPanel.url else {
                return
            }

            self?.beginAudioExport(
                scope: scope,
                destinationURL: folderURL,
                format: .wav,
                wavEncoding: exportOptions.wavEncoding,
                stemOptions: exportOptions.stemOptions
            )
        }

        if let window {
            openPanel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(openPanel.runModal())
        }
    }

    private func beginAudioExport(
        scope: AudioExportScope,
        destinationURL: URL,
        format: AudioExportFormat,
        wavEncoding: AudioExportWAVEncoding = .pcm24,
        compressedQuality: AudioExportCompressedQuality = .standard,
        stemOptions: AudioExportStemOptions = .v1Default
    ) {
        guard !audioExportService.hasActiveExport else {
            presentActiveExportConflict()
            return
        }
        let request = AudioExportRequest(
            projectName: suggestedProjectFilename(),
            scope: scope,
            format: format,
            destinationURL: destinationURL,
            wavEncoding: wavEncoding,
            compressedQuality: compressedQuality,
            stemOptions: stemOptions
        )

        do {
            let snapshotStartedAt = CACurrentMediaTime()
            let snapshot = try makeAudioExportSnapshot(request: request)
            let snapshotElapsedMilliseconds =
                (CACurrentMediaTime() - snapshotStartedAt) * 1_000
            let initialProgress = AudioExportProgress.initial(request: request)
            activeAudioExportJobID = request.id
            lastDiagnosedAudioExportStage = nil
            latestAudioExportProgress = initialProgress
            showAudioExportWindow()
            handleAudioExportProgress(initialProgress)
            updateStatus("exporting \(scope.displayName.lowercased()) in background")
            try audioExportService.start(snapshot: snapshot)
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .info,
                name: "audio-export-started",
                message: "Audio export started from an immutable snapshot.",
                fields: [
                    "jobID": request.id.uuidString,
                    "scope": scope.displayName,
                    "format": format.displayName,
                    "trackCount": "\(snapshot.tracks.count)",
                    "frameCount": "\(snapshot.frameCount)",
                    "snapshotMs": String(
                        format: "%.2f",
                        snapshotElapsedMilliseconds
                    ),
                ]
            )
            if snapshotElapsedMilliseconds > 16 {
                SoundtimeDiagnostics.shared.record(
                    category: .threading,
                    severity: .warning,
                    name: "audio-export-snapshot-budget-exceeded",
                    message: "Capturing the immutable export snapshot exceeded one 60 Hz frame.",
                    fields: [
                        "jobID": request.id.uuidString,
                        "elapsedMs": String(
                            format: "%.2f",
                            snapshotElapsedMilliseconds
                        ),
                        "trackCount": "\(snapshot.tracks.count)",
                    ]
                )
            }
        } catch {
            activeAudioExportJobID = nil
            if latestAudioExportProgress?.jobID == request.id {
                handleAudioExportProgress(AudioExportProgress(
                    jobID: request.id,
                    request: request,
                    stage: .failed,
                    fractionCompleted: 0,
                    message: error.localizedDescription,
                    outputURLs: []
                ))
            }
            updateStatus("export failed: \(error.localizedDescription)")
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .warning,
                name: "audio-export-start-failed",
                message: "Audio export could not start.",
                fields: [
                    "scope": scope.displayName,
                    "format": format.displayName,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private func supportedAudioExportContentTypes() -> [UTType] {
        AudioExportFormat.allCases.compactMap { format in
            guard format.isSystemEncoderAvailable else {
                return nil
            }
            return format == .wav ?
                .wav :
                UTType(filenameExtension: format.fileExtension)
        }
    }

    private func presentActiveExportConflict() {
        let alert = NSAlert()
        alert.messageText = "An Export Is Already Running"
        alert.informativeText = "Keep the current export running, or cancel it before starting another export."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Keep Current Export")
        alert.addButton(withTitle: "Cancel Current Export")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertSecondButtonReturn else {
                return
            }
            self?.audioExportWindowController?.markCancellationRequested()
            self?.audioExportService.cancel()
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private func canPresentNewAudioExport() -> Bool {
        guard !audioExportService.hasActiveExport else {
            presentActiveExportConflict()
            return false
        }
        return true
    }

    private func canCreateAudioExportSnapshot(for scope: AudioExportScope) -> Bool {
        !audioExportTrackSnapshots(for: scope).isEmpty || fallbackAudioExportTrackSnapshot() != nil
    }

    private func makeAudioExportSnapshot(request: AudioExportRequest) throws -> AudioExportSnapshot {
        var tracks = audioExportTrackSnapshots(
            for: request.scope,
            stemOptions: request.stemOptions
        )
        if tracks.isEmpty, let fallbackTrack = fallbackAudioExportTrackSnapshot() {
            tracks = [fallbackTrack]
        }
        guard !tracks.isEmpty else {
            throw WorkspaceAudioExportError.noAudioToExport
        }

        let timings = tracks.map { Self.audioExportTiming(for: $0.source) }
        guard let firstTiming = timings.first else {
            throw WorkspaceAudioExportError.noAudioToExport
        }

        let sampleRate = firstTiming.sampleRate > 0 ? firstTiming.sampleRate : max(displayedSampleRate, 44_100)
        let channelCount = max(timings.map(\.channelCount).max() ?? 2, 2)
        let exportedTracksDurationFrameCount = timings.reduce(0) { result, timing in
            let convertedFrameCount = Int((Double(timing.frameCount) / max(timing.sampleRate, 1) * sampleRate).rounded(.up))
            return max(result, convertedFrameCount)
        }
        let projectDurationFrameCount = Int(
            (max(projectSelectionDuration, 0) * sampleRate).rounded(.up)
        )
        let fullDurationFrameCount = max(
            exportedTracksDurationFrameCount,
            projectDurationFrameCount
        )
        guard fullDurationFrameCount > 0 else {
            throw WorkspaceAudioExportError.noAudioToExport
        }

        let exportFrameRange: Range<Int>
        if let selection = request.scope.selection {
            let lowerBound = min(
                max(Int((selection.startProgress * Double(fullDurationFrameCount)).rounded(.down)), 0),
                fullDurationFrameCount
            )
            let upperBound = min(
                max(Int((selection.endProgress * Double(fullDurationFrameCount)).rounded(.up)), lowerBound),
                fullDurationFrameCount
            )
            guard lowerBound < upperBound else {
                throw WorkspaceAudioExportError.emptyExportRange
            }
            exportFrameRange = lowerBound..<upperBound
        } else {
            exportFrameRange = 0..<fullDurationFrameCount
        }

        return AudioExportSnapshot(
            id: request.id,
            createdAt: request.createdAt,
            request: request,
            tracks: tracks,
            sampleRate: sampleRate,
            channelCount: channelCount,
            fullDurationFrameCount: fullDurationFrameCount,
            exportFrameRange: exportFrameRange,
            leasedURLs: Array(Set(tracks.compactMap(\.sourceURL)))
        )
    }

    private func audioExportTrackSnapshots(
        for scope: AudioExportScope,
        stemOptions: AudioExportStemOptions = .v1Default
    ) -> [AudioExportTrackSnapshot] {
        let sourceTracks: [ProjectTrack]
        switch scope {
        case .fullMixdown, .timeRange:
            sourceTracks = projectTracks
        case let .trackRange(trackID, _):
            sourceTracks = projectTracks.filter { $0.id == trackID }
        case .stems:
            switch stemOptions.trackInclusion {
            case .allTracks:
                sourceTracks = projectTracks
            case .audibleTracks:
                sourceTracks = audibleProjectTracks
            }
        }

        return sourceTracks.compactMap(audioExportTrackSnapshot(for:))
    }

    private func audioExportTrackSnapshot(for track: ProjectTrack) -> AudioExportTrackSnapshot? {
        let normalizedSourceURL = track.sourceURL.standardizedFileURL
        let knownFileInfo = wavFileInfoCache[normalizedSourceURL]

        let source: AudioExportTrackSource
        if
            let fileTimeline = track.fileTimeline,
            let fileInfo = knownFileInfo ?? decodableWAVFileInfo(for: track.sourceURL),
            fileTimeline.isCompatible(with: fileInfo)
        {
            source = .fileTimeline(track.sourceURL, fileInfo, fileTimeline)
        } else if let audioTimeline = track.audioTimeline {
            source = .timeline(audioTimeline)
        } else if let knownFileInfo {
            source = .file(track.sourceURL, knownFileInfo)
        } else if let decodedAudioBuffer = track.decodedAudioBuffer {
            source = .decoded(decodedAudioBuffer)
        } else if let fileInfo = decodableWAVFileInfo(for: track.sourceURL) {
            source = .file(track.sourceURL, fileInfo)
        } else {
            return nil
        }

        return AudioExportTrackSnapshot(
            id: track.id,
            name: track.name,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            source: source
        )
    }

    private func fallbackAudioExportTrackSnapshot() -> AudioExportTrackSnapshot? {
        guard projectTracks.isEmpty, let decodedAudioBuffer, decodedAudioBuffer.frameCount > 0 else {
            return nil
        }

        return AudioExportTrackSnapshot(
            id: UUID(),
            name: selectedAudioFile?.url.deletingPathExtension().lastPathComponent ?? "Audio",
            volume: 1,
            source: .decoded(decodedAudioBuffer)
        )
    }

    private nonisolated static func audioExportTiming(
        for source: AudioExportTrackSource
    ) -> (sampleRate: Double, channelCount: Int, frameCount: Int) {
        switch source {
        case let .decoded(buffer):
            return (buffer.sampleRate, buffer.channelCount, buffer.frameCount)
        case let .decodedSegments(buffer, segments):
            return (
                buffer.sampleRate,
                buffer.channelCount,
                segments.map { $0.outputStartFrame + $0.frameCount }.max() ?? 0
            )
        case let .timeline(timeline):
            return (timeline.sourceAudioBuffer.sampleRate, timeline.sourceAudioBuffer.channelCount, timeline.frameCount)
        case let .file(_, fileInfo):
            return (fileInfo.sampleRate, fileInfo.channelCount, fileInfo.frameCount)
        case let .fileSegments(_, fileInfo, segments):
            return (
                fileInfo.sampleRate,
                fileInfo.channelCount,
                segments.map { $0.outputStartFrame + $0.frameCount }.max() ?? 0
            )
        case let .fileTimeline(_, fileInfo, fileTimeline):
            return (fileInfo.sampleRate, fileInfo.channelCount, fileTimeline.frameCount)
        }
    }

    private func showAudioExportWindow() {
        let controller: AudioExportWindowController
        if let existingController = audioExportWindowController {
            controller = existingController
        } else {
            controller = AudioExportWindowController()
            controller.onCancel = { [weak self] in
                guard let self else {
                    return
                }
                if self.audioExportService.hasActiveExport {
                    self.audioExportWindowController?.markCancellationRequested()
                    self.audioExportService.cancel()
                } else {
                    self.audioExportWindowController?.close()
                }
            }
            controller.onClosed = { [weak self] in
                self?.audioExportWindowController = nil
                self?.updateAudioExportStatusButton()
            }
            audioExportWindowController = controller
        }

        if let latestAudioExportProgress {
            controller.update(progress: latestAudioExportProgress)
        }
        controller.show(relativeTo: window)
        updateAudioExportStatusButton()
    }

    private func handleAudioExportProgress(_ progress: AudioExportProgress) {
        guard shouldAcceptAudioExportUpdate(jobID: progress.jobID) else {
            return
        }

        latestAudioExportProgress = progress
        audioExportWindowController?.update(progress: progress)
        if lastDiagnosedAudioExportStage != progress.stage {
            lastDiagnosedAudioExportStage = progress.stage
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: progress.stage == .failed ? .warning : .info,
                name: "audio-export-stage",
                message: "Audio export changed stage.",
                fields: [
                    "jobID": progress.jobID.uuidString,
                    "stage": progress.stage.rawValue,
                    "fraction": String(
                        format: "%.3f",
                        progress.fractionCompleted
                    ),
                    "message": progress.message,
                ]
            )
        }
        if progress.stage == .completed || progress.stage == .canceled || progress.stage == .failed {
            activeAudioExportJobID = nil
        }
        updateAudioExportStatusButton()
    }

    private func handleAudioExportCompletion(jobID: UUID, _ result: Result<AudioExportResult, Error>) {
        if !shouldAcceptAudioExportUpdate(jobID: jobID) {
            return
        }

        switch result {
        case let .success(exportResult):
            updateStatus("exported \(exportResult.outputURLs.count) file\(exportResult.outputURLs.count == 1 ? "" : "s")")
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .info,
                name: "audio-export-completed",
                message: "Audio export completed.",
                fields: [
                    "jobID": exportResult.request.id.uuidString,
                    "fileCount": "\(exportResult.outputURLs.count)",
                    "elapsedMs": String(format: "%.1f", exportResult.elapsedSeconds * 1_000),
                    "renderedFrameCount": "\(exportResult.renderedFrameCount)",
                    "peakMagnitude": String(format: "%.3f", exportResult.renderStats.peakMagnitude),
                    "clippedSamples": "\(exportResult.renderStats.clippedSampleCount)",
                ]
            )
        case let .failure(error as CancellationError):
            updateStatus("export canceled")
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .info,
                name: "audio-export-canceled",
                message: "Audio export was canceled.",
                fields: [
                    "error": error.localizedDescription,
                ]
            )
        case let .failure(error):
            updateStatus("export failed: \(error.localizedDescription)")
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .warning,
                name: "audio-export-failed",
                message: "Audio export failed.",
                fields: [
                    "error": error.localizedDescription,
                ]
            )
        }
        activeAudioExportJobID = nil
        updateAudioExportStatusButton()
    }

    private func shouldAcceptAudioExportUpdate(jobID: UUID) -> Bool {
        if let activeAudioExportJobID {
            return activeAudioExportJobID == jobID
        }
        return latestAudioExportProgress?.jobID == jobID
    }

    private func updateAudioExportStatusButton() {
        guard let progress = latestAudioExportProgress else {
            audioExportStatusButton.isHidden = true
            return
        }

        let percent = Int((min(max(progress.fractionCompleted, 0), 1) * 100).rounded())
        switch progress.stage {
        case .completed:
            audioExportStatusButton.title = "Export complete"
        case .failed:
            audioExportStatusButton.title = "Export failed"
        case .canceled:
            audioExportStatusButton.title = "Export canceled"
        case .preparing, .rendering, .encoding, .validating, .committing, .finishing:
            audioExportStatusButton.title = "Export \(percent)%"
        }
        audioExportStatusButton.isHidden = audioExportWindowController?.window?.isVisible == true
    }

    @objc private func audioExportStatusButtonPressed(_ sender: Any?) {
        showAudioExportWindow()
    }

    private func importAudioFile() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Import Audio File"
        openPanel.prompt = "Import"
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        let supportedTypes = AudioAssetImporter.supportedAudioFileExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        openPanel.allowedContentTypes = supportedTypes.isEmpty ? [.audio] : supportedTypes

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = openPanel.url else {
                return
            }

            self?.loadDroppedAudioFile(at: url)
        }

        if let window {
            openPanel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(openPanel.runModal())
        }
    }

    private func openProject() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Open Soundtime Project"
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [UTType(filenameExtension: SoundtimeProjectStore.fileExtension) ?? .json]

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = openPanel.url else {
                return
            }

            self?.loadProject(from: url)
        }

        if let window {
            openPanel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(openPanel.runModal())
        }
    }

    private func saveProject() {
        if let currentProjectURL {
            writeProject(to: currentProjectURL)
        } else {
            saveProjectAs()
        }
    }

    private func saveProjectAs() {
        let savePanel = NSSavePanel()
        savePanel.title = "Save Soundtime Project"
        savePanel.nameFieldStringValue = suggestedProjectFilename()
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.allowedContentTypes = [UTType(filenameExtension: SoundtimeProjectStore.fileExtension) ?? .json]

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = savePanel.url else {
                return
            }

            self?.writeProject(to: url)
        }

        if let window {
            savePanel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(savePanel.runModal())
        }
    }

    private func writeProject(to url: URL) {
        do {
            try prepareProjectForSerialization()
            let projectURL = normalizedProjectURL(url)
            let project = currentProject()
            scheduleLaunchDetailWaveformCachesForCurrentProject(reason: "project-save")
            scheduleLaunchSnapshotSaveIfNeeded(reason: "project-save", delay: 0, projectURL: projectURL)
            projectSaveGeneration += 1
            let saveGeneration = projectSaveGeneration
            updateStatus("saving...")

            DispatchQueue.global(qos: .utility).async { [project, projectURL] in
                let result = Result {
                    try SoundtimeProjectStore.save(project, to: projectURL)
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self, self.projectSaveGeneration == saveGeneration else {
                        return
                    }

                    switch result {
                    case .success:
                        self.withoutAutosave {
                            self.currentProjectURL = projectURL
                            self.markProjectSourceFilesAsSaved()
                        }
                        SoundtimeProjectStore.removeAutosave(projectURL: projectURL, autosaveID: self.autosaveID)
                        SoundtimeProjectStore.rememberLastProjectURL(projectURL)
                        self.window?.title = self.projectWindowTitle()
                        self.updateLoadedProjectSummary()
                        self.updateStatus("saved")
                        self.scheduleLaunchSnapshotSaveIfNeeded(reason: "project-save-complete", delay: 0)
                    case let .failure(error):
                        self.updateStatus("project save failed: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            updateStatus("project save failed: \(error.localizedDescription)")
        }
    }

    func persistCurrentProjectWindowLayout() {
        let startedAt = CACurrentMediaTime()
        viewportPersistenceWorkItem?.cancel()
        viewportPersistenceWorkItem = nil

        guard let currentProjectURL else {
            return
        }

        let viewport = latestTimelineViewportForPersistence ?? currentTimelineViewport()
        latestTimelineViewportForPersistence = viewport
        let layout = currentWindowLayout()
        if layout != nil || viewport != nil {
            advanceLaunchStateRevision()
        }
        let overlay = currentLaunchStateOverlay(windowLayout: layout)
        let trackCount = projectTracks.count
        statePersistenceQueue.async { [layout, viewport, overlay, currentProjectURL] in
            if let layout {
                SoundtimeProjectStore.rememberWindowLayout(layout, for: currentProjectURL)
            }
            if let viewport {
                SoundtimeProjectStore.rememberTimelineViewport(viewport, for: currentProjectURL)
            }
            if let overlay {
                SoundtimeProjectStore.rememberLaunchStateOverlay(overlay, for: currentProjectURL)
            }
        }

        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        LaunchStartupTrace.shared.mark(
            .windowCloseStatePersisted,
            fields: [
                "elapsedMs": String(format: "%.2f", elapsedMilliseconds),
                "tracks": "\(trackCount)",
                "launchSnapshotWrite": "false",
                "firstFramePacketWrite": "false",
                "launchOverlaySync": "false",
                "launchOverlayAsync": "\(overlay != nil)",
            ]
        )
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: elapsedMilliseconds > 10 ? .warning : .info,
            name: "project-close-state-persisted",
            message: "Persisted lightweight project launch state without synchronously writing waveform previews.",
            fields: [
                "elapsedMs": String(format: "%.2f", elapsedMilliseconds),
                "tracks": "\(projectTracks.count)",
                "launchSnapshotWrite": "false",
                "firstFramePacketWrite": "false",
                "launchOverlaySync": "false",
                "launchOverlayAsync": "\(overlay != nil)",
            ]
        )
    }

    private func timelineViewportDidChange(_ viewport: TimelineViewport) {
        timelineZoomControls.display(
            horizontal: timelineSurface.horizontalZoomNormalizedValue,
            vertical: timelineSurface.verticalZoomNormalizedValue
        )
        updateTimelineNavigationScrollbars()
        guard
            !isAutosaveSuppressed,
            !isLoadingProject,
            !projectTracks.isEmpty,
            let projectViewport = projectTimelineViewport(for: viewport)
        else {
            return
        }

        latestTimelineViewportForPersistence = projectViewport
        scheduleTimelineViewportPersistence()
    }

    private func updateTimelineNavigationScrollbars() {
        horizontalTimelineScrollbar.display(
            value: timelineSurface.horizontalScrollNormalizedValue,
            visibleFraction: timelineSurface.horizontalVisibleFraction
        )
        verticalTimelineScrollbar.display(
            value: timelineSurface.verticalScrollNormalizedValue,
            visibleFraction: timelineSurface.verticalVisibleFraction
        )
    }

    private func markTimelineHotInteraction(reason: String) {
        _ = reason
        lastTimelineHotInteractionTime = CACurrentMediaTime()
    }

    private func scheduleTimelineViewportPersistence(delay: TimeInterval? = nil) {
        viewportPersistenceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistLatestTimelineViewport()
        }
        viewportPersistenceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (delay ?? viewportPersistenceDelay),
            execute: workItem
        )
    }

    private func persistLatestTimelineViewport(
        flushImmediately: Bool = false,
        schedulesLaunchSnapshot: Bool = true
    ) {
        viewportPersistenceWorkItem?.cancel()
        viewportPersistenceWorkItem = nil

        if schedulesLaunchSnapshot,
           let deferralReason = launchCacheHotPathDeferralReason()
        {
            scheduleTimelineViewportPersistence(delay: launchCacheHotPathQuietInterval)
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .info,
                name: "launch-state-overlay-persist-deferred-hot-path",
                message: "Timeline launch-state persistence was deferred until interaction became quiet.",
                fields: [
                    "deferral": deferralReason,
                    "delayMs": String(format: "%.0f", launchCacheHotPathQuietInterval * 1_000),
                ]
            )
            return
        }

        guard let currentProjectURL else {
            return
        }

        let viewport = latestTimelineViewportForPersistence ?? currentTimelineViewport()
        guard let viewport else {
            return
        }

        latestTimelineViewportForPersistence = viewport
        advanceLaunchStateRevision()
        let overlay = schedulesLaunchSnapshot ?
            currentLaunchStateOverlay(windowLayout: currentWindowLayout()) :
            nil
        let trackCount = projectTracks.count
        statePersistenceQueue.async { [viewport, overlay, currentProjectURL] in
            SoundtimeProjectStore.rememberTimelineViewport(viewport, for: currentProjectURL)
            if let overlay {
                SoundtimeProjectStore.rememberLaunchStateOverlay(overlay, for: currentProjectURL)
            }
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .info,
                name: "launch-state-overlay-persisted",
                message: "Persisted lightweight launch state off the main thread.",
                fields: [
                    "reason": "timeline-viewport",
                    "tracks": "\(trackCount)",
                    "mainThread": "\(Thread.isMainThread)",
                ]
            )
        }
        if flushImmediately {
            statePersistenceQueue.async {
                SoundtimeProjectStore.synchronizePersistence()
            }
        }
    }

    private func currentLaunchStateOverlay(
        windowLayout: SoundtimeProject.WindowLayout?
    ) -> SoundtimeProjectLaunchStateOverlay? {
        guard !projectTracks.isEmpty else {
            return nil
        }

        return SoundtimeProjectLaunchStateOverlay(
            createdAt: Date().timeIntervalSince1970,
            windowLayout: windowLayout ?? currentWindowLayout(),
            timelineViewport: currentTimelineViewport(),
            masterVolume: volumeControl.perceptualVolume,
            transcriptDisplayMode: isTranscriptLayerVisible ? .waveformOverlay : .hidden,
            tracks: projectTracks.map { track in
                SoundtimeProjectLaunchStateOverlay.TrackState(
                    id: track.id,
                    volume: track.volume,
                    isMuted: track.isMuted,
                    isSoloed: track.isSoloed
                )
            }
        )
    }

    private func scheduleAutosaveIfNeeded(
        reason: String = #function,
        minimumDelay: TimeInterval? = nil
    ) {
        guard
            !isAutosaveSuppressed,
            !isLoadingProject,
            !projectTracks.isEmpty
        else {
            return
        }

        latestAutosaveScheduleReason = reason
        autosaveWorkItem?.cancel()
        autosaveGeneration += 1
        let generation = autosaveGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.autosaveGeneration == generation else {
                return
            }

            self.autosaveWorkItem = nil
            self.writeProjectAutosave(generation: generation)
        }
        autosaveWorkItem = workItem
        let now = CACurrentMediaTime()
        let deleteProtectedDelay = max(deleteAutosaveProtectedUntil - now + 0.08, 0)
        let delay = max(minimumDelay ?? autosaveDelay, deleteProtectedDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func writeProjectAutosave(generation: Int) {
        guard
            !isAutosaveSuppressed,
            !isLoadingProject,
            !projectTracks.isEmpty
        else {
            return
        }
        guard CACurrentMediaTime() >= deleteAutosaveProtectedUntil else {
            scheduleAutosaveIfNeeded()
            return
        }
        if let deferralReason = launchCacheHotPathDeferralReason() {
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .info,
                name: "project-autosave-deferred-hot-path",
                message: "Project autosave deferred until the timeline is quiet.",
                fields: [
                    "deferral": deferralReason,
                    "delayMs": String(format: "%.0f", launchCacheHotPathQuietInterval * 1_000),
                ]
            )
            scheduleAutosaveIfNeeded(minimumDelay: launchCacheHotPathQuietInterval)
            return
        }

        let snapshotStartedAt = CACurrentMediaTime()
        let project = currentProject(includeWaveformPreviews: false)
        let projectURL = currentProjectURL
        let snapshotDurationMilliseconds = (CACurrentMediaTime() - snapshotStartedAt) * 1_000
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: snapshotDurationMilliseconds > 8 ? .warning : .info,
            name: "project-autosave-main-thread-snapshot",
            message: "Project autosave captured its main-thread value snapshot.",
            fields: [
                "trackCount": "\(projectTracks.count)",
                "waveformPreviews": "false",
                "snapshotMs": String(format: "%.2f", snapshotDurationMilliseconds),
                "scheduleReason": latestAutosaveScheduleReason,
            ]
        )
        let autosaveID = autosaveID
        let trackCount = projectTracks.count

        DispatchQueue.global(qos: .utility).async { [project, projectURL, autosaveID] in
            let writeStartedAt = CACurrentMediaTime()
            let result = Result {
                try SoundtimeProjectStore.saveAutosave(
                    project,
                    projectURL: projectURL,
                    autosaveID: autosaveID
                )
            }
            let writeDurationMilliseconds = (CACurrentMediaTime() - writeStartedAt) * 1_000

            DispatchQueue.main.async { [weak self] in
                guard let self, self.autosaveGeneration == generation else {
                    return
                }

                let timingFields = [
                    "trackCount": "\(trackCount)",
                    "waveformPreviews": "false",
                    "snapshotMs": String(format: "%.2f", snapshotDurationMilliseconds),
                    "writeMs": String(format: "%.2f", writeDurationMilliseconds),
                    "scheduleReason": self.latestAutosaveScheduleReason,
                ]

                switch result {
                case let .success(url):
                    SoundtimeDiagnostics.shared.record(
                        category: .system,
                        severity: snapshotDurationMilliseconds > 8 ? .warning : .info,
                        name: "project-autosave",
                        message: "Project autosave was written without launch waveform sidecar work.",
                        fields: timingFields.merging([
                            "file": url.lastPathComponent,
                            "launchBundle": "false",
                            "launchSnapshot": "false",
                            "firstFramePacket": "false",
                        ]) { _, new in new }
                    )
                case let .failure(error):
                    SoundtimeDiagnostics.shared.record(
                        category: .system,
                        severity: .warning,
                        name: "project-autosave-failed",
                        message: "Project autosave failed.",
                        fields: timingFields.merging([
                            "error": error.localizedDescription,
                        ]) { _, new in new }
                    )
                }
            }
        }
    }

    @discardableResult
    private func scheduleLaunchSnapshotSaveIfNeeded(
        reason: String,
        delay: TimeInterval = 0.35,
        projectURL projectURLOverride: URL? = nil
    ) -> Bool {
        guard
            !isAutosaveSuppressed,
            !isLoadingProject,
            !projectTracks.isEmpty
        else {
            return false
        }
        let projectURL = projectURLOverride ?? currentProjectURL
        guard let projectURL else {
            return false
        }

        let request = LaunchCacheWriteRequest(projectURL: projectURL, reason: reason)
        if delay <= 0, let deferralReason = launchCacheHotPathDeferralReason() {
            recordLaunchCacheHotPathDeferral(
                request: request,
                deferralReason: deferralReason
            )
            return scheduleLaunchSnapshotSaveIfNeeded(
                reason: reason,
                delay: launchCacheHotPathQuietInterval,
                projectURL: projectURL
            )
        }

        launchSnapshotSaveWorkItem?.cancel()
        launchSnapshotSaveGeneration += 1
        let generation = launchSnapshotSaveGeneration
        let workItem = DispatchWorkItem { [weak self] in
            self?.writeLaunchSnapshotIfCurrent(
                request: request,
                generation: generation
            )
        }
        launchSnapshotSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return true
    }

    private func writeLaunchSnapshotIfCurrent(
        request: LaunchCacheWriteRequest,
        generation: Int
    ) {
        guard
            generation == launchSnapshotSaveGeneration,
            currentProjectURL == request.projectURL,
            !projectTracks.isEmpty
        else {
            return
        }

        launchSnapshotSaveWorkItem = nil
        if let deferralReason = launchCacheHotPathDeferralReason() {
            recordLaunchCacheHotPathDeferral(
                request: request,
                deferralReason: deferralReason
            )
            scheduleLaunchSnapshotSaveIfNeeded(
                reason: request.reason,
                delay: launchCacheHotPathQuietInterval,
                projectURL: request.projectURL
            )
            return
        }

        if launchCacheWriteInFlight {
            pendingLaunchCacheWriteRequest = request
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .info,
                name: "launch-cache-write-coalesced",
                message: "Launch waveform cache write coalesced behind an in-flight write.",
                fields: [
                    "reason": request.reason,
                    "file": request.projectURL.lastPathComponent,
                ]
            )
            return
        }

        launchCacheWriteInFlight = true
        let lifecycleGeneration = workspaceLifecycleGeneration
        SoundtimeDiagnostics.shared.record(
            category: .render,
            severity: .info,
            name: "launch-cache-write-started",
            message: "Launch waveform cache write started outside a protected interaction window.",
            fields: [
                "reason": request.reason,
                "file": request.projectURL.lastPathComponent,
                "tracks": "\(projectTracks.count)",
            ]
        )
        let draftStartedAt = CACurrentMediaTime()
        let draft = currentLaunchSnapshotDraft(projectURL: request.projectURL)
        let draftDurationMilliseconds = (CACurrentMediaTime() - draftStartedAt) * 1_000
        let trackCount = draft.tracks.count
        if draftDurationMilliseconds > 8 {
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .warning,
                name: "launch-cache-draft-main-thread-cost",
                message: "Launch waveform cache draft took too long on the main thread.",
                fields: [
                    "reason": request.reason,
                    "file": request.projectURL.lastPathComponent,
                    "tracks": "\(trackCount)",
                    "draftMs": String(format: "%.2f", draftDurationMilliseconds),
                ]
            )
        }

        launchCacheWriteQueue.async {
            [draft, request, trackCount, draftDurationMilliseconds, lifecycleGeneration] in
            let startedAt = CACurrentMediaTime()
            let result = Result { () -> (packetDrawable: Bool, launchBundleSaved: Bool) in
                let snapshot = ProjectLaunchSnapshot(
                    projectURL: request.projectURL,
                    projectID: draft.projectID,
                    editGraphRevision: draft.editGraphRevision,
                    visualRevision: draft.visualRevision,
                    launchStateRevision: draft.launchStateRevision,
                    windowLayout: draft.windowLayout,
                    timelineViewport: draft.timelineViewport,
                    masterVolume: draft.masterVolume,
                    transcriptDisplayMode: draft.transcriptDisplayMode,
                    tracks: draft.tracks
                )
                let packet = ProjectFirstFrameWaveformPacket(
                    projectURL: request.projectURL,
                    projectID: draft.projectID,
                    editGraphRevision: draft.editGraphRevision,
                    visualRevision: draft.visualRevision,
                    launchStateRevision: draft.launchStateRevision,
                    windowLayout: draft.windowLayout,
                    timelineViewport: draft.timelineViewport,
                    masterVolume: draft.masterVolume,
                    transcriptDisplayMode: draft.transcriptDisplayMode,
                    tracks: draft.tracks
                )
                let snapshotData = try ProjectLaunchSnapshotBinaryCodec.encode(snapshot)
                let packetData = try ProjectFirstFrameWaveformPacketBinaryCodec.encode(packet)
                let packetDrawable = ProjectLaunchReadinessClassifier.summarize(packet: packet).hasAnyDrawableWaveform
                let manifest = ProjectLaunchManifest(
                    projectURL: request.projectURL,
                    projectID: draft.projectID,
                    editGraphRevision: draft.editGraphRevision,
                    visualRevision: draft.visualRevision,
                    launchStateRevision: draft.launchStateRevision,
                    windowLayout: draft.windowLayout,
                    timelineViewport: draft.timelineViewport,
                    masterVolume: draft.masterVolume,
                    transcriptDisplayMode: draft.transcriptDisplayMode,
                    tracks: draft.tracks,
                    snapshotByteCount: snapshotData.count,
                    firstFramePacketByteCount: packetData.count,
                    snapshotDrawable: ProjectLaunchReadinessClassifier.summarize(snapshot: snapshot).hasAnyDrawableWaveform,
                    firstFramePacketDrawable: packetDrawable
                )
                let launchBundleSaved = try ProjectLaunchCacheStore.publish(
                    manifest: manifest,
                    firstFramePacket: packet,
                    snapshot: snapshot,
                    for: request.projectURL
                )
                return (packetDrawable, launchBundleSaved)
            }
            let durationMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000

            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    self.workspaceLifecycleGeneration == lifecycleGeneration
                else {
                    return
                }
                self.launchCacheWriteInFlight = false
                let pendingRequest = self.pendingLaunchCacheWriteRequest
                self.pendingLaunchCacheWriteRequest = nil

                switch result {
                case let .success((packetDrawable, launchBundleSaved)):
                    SoundtimeDiagnostics.shared.record(
                        category: .system,
                        severity: durationMilliseconds > 40 ? .warning : .info,
                        name: "launch-snapshot-saved",
                        message: "Project launch snapshot and first-frame waveform packet were written.",
                        fields: [
                            "file": request.projectURL.lastPathComponent,
                            "reason": request.reason,
                            "tracks": "\(trackCount)",
                            "launchBundle": "\(launchBundleSaved)",
                            "firstFramePacketDrawable": "\(packetDrawable)",
                            "draftMs": String(format: "%.2f", draftDurationMilliseconds),
                            "writeMs": String(format: "%.2f", durationMilliseconds),
                        ]
                    )
                case let .failure(error):
                    SoundtimeDiagnostics.shared.record(
                        category: .system,
                        severity: .warning,
                        name: "launch-snapshot-save-failed",
                        message: "Project launch snapshot could not be written.",
                        fields: [
                            "file": request.projectURL.lastPathComponent,
                            "reason": request.reason,
                            "error": error.localizedDescription,
                        ]
                    )
                }

                guard self.window != nil, let pendingRequest else {
                    return
                }

                self.scheduleLaunchSnapshotSaveIfNeeded(
                    reason: pendingRequest.reason,
                    delay: 0.15,
                    projectURL: pendingRequest.projectURL
                )
            }
        }
    }

    private func recordLaunchCacheHotPathDeferral(
        request: LaunchCacheWriteRequest,
        deferralReason: String
    ) {
        let now = CACurrentMediaTime()
        let eventKey = "\(request.reason):\(deferralReason)"
        let lastEventTime = lastLaunchCacheHotPathDeferralEventTimeByKey[eventKey] ?? -Double.infinity
        guard now - lastEventTime >= launchCacheHotPathDeferralEventInterval else {
            return
        }

        lastLaunchCacheHotPathDeferralEventTimeByKey[eventKey] = now
        SoundtimeDiagnostics.shared.record(
            category: .render,
            severity: .info,
            name: "launch-cache-write-deferred-hot-path",
            message: "Launch waveform cache write deferred until the timeline is quiet.",
            fields: [
                "reason": request.reason,
                "deferral": deferralReason,
                "delayMs": String(format: "%.0f", launchCacheHotPathQuietInterval * 1_000),
            ]
        )
    }

    private func launchCacheHotPathDeferralReason() -> String? {
        let now = CACurrentMediaTime()
        if now < hotPathContractSmokeProtectedUntil {
            return "hot-path-contract-smoke"
        }
        if now < deleteAutosaveProtectedUntil {
            return "edit-animation"
        }
        if postDeleteRefreshWorkItem != nil {
            return "edit-handoff"
        }
        if scheduledPlaybackReloadWorkItem != nil {
            return "playback-reload"
        }
        if playbackController.isPlaying || visualPlaybackActive {
            return "playback"
        }
        if now - lastTimelineHotInteractionTime < launchCacheHotPathQuietInterval {
            return "timeline-interaction"
        }
        return nil
    }

    private struct LaunchCacheWriteRequest: Sendable {
        var projectURL: URL
        var reason: String
    }

    private struct LaunchSnapshotDraft {
        var projectID: UUID
        var editGraphRevision: UInt64
        var visualRevision: UInt64
        var launchStateRevision: UInt64
        var windowLayout: SoundtimeProject.WindowLayout?
        var timelineViewport: SoundtimeProject.TimelineViewport?
        var masterVolume: Float?
        var transcriptDisplayMode: TranscriptTimelineDisplayMode?
        var tracks: [ProjectLaunchSnapshot.TrackDraft]
    }

    private nonisolated static func fileByteCount(_ url: URL) -> Int? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let byteCount = (attributes[.size] as? NSNumber)?.intValue
        else {
            return nil
        }
        return byteCount
    }

    private func currentLaunchSnapshotDraft(projectURL: URL) -> LaunchSnapshotDraft {
        LaunchSnapshotDraft(
            projectID: currentProjectID,
            editGraphRevision: currentEditGraphRevision,
            visualRevision: currentVisualRevision,
            launchStateRevision: currentLaunchStateRevision,
            windowLayout: currentWindowLayout(),
            timelineViewport: currentTimelineViewport(),
            masterVolume: volumeControl.perceptualVolume,
            transcriptDisplayMode: isTranscriptLayerVisible ? .waveformOverlay : .hidden,
            tracks: projectTracks.map { track in
                ProjectLaunchSnapshot.TrackDraft(
                    id: track.id,
                    editGroupID: track.editGroupID,
                    name: track.name,
                    filePath: track.sourceURL.standardizedFileURL.path,
                    durationHint: track.audioTimeline?.duration ??
                        track.fileTimeline?.duration ??
                        track.waveformOverview?.duration ??
                        track.sourceWaveformOverview?.duration ??
                        track.decodedAudioBuffer?.duration ??
                        track.durationHint,
                    sourceWaveformOverview: track.sourceWaveformOverview,
                    displayWaveformOverview: track.waveformOverview ?? track.sourceWaveformOverview,
                    editTimeline: track.fileTimeline?.persistentState,
                    editableSource: track.editableSource.map(SoundtimeProject.Track.EditableSource.init),
                    ownsSourceFile: track.ownsSourceFile,
                    volume: track.volume,
                    isMuted: track.isMuted,
                    isSoloed: track.isSoloed
                )
            }
        )
    }

    private func withoutAutosave(_ body: () throws -> Void) rethrows {
        let previousValue = isAutosaveSuppressed
        isAutosaveSuppressed = true
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        autosaveGeneration += 1
        defer {
            isAutosaveSuppressed = previousValue
        }
        try body()
    }

    private func loadProject(from url: URL) {
        if currentProjectURL != nil, currentProjectURL != url {
            persistCurrentProjectWindowLayout()
        }

        projectLoadGeneration += 1
        let generation = projectLoadGeneration
        let projectURL = url.standardizedFileURL
        projectHydrationQueue?.cancel()
        projectHydrationQueue = nil
        projectPlaybackPrimedTrackIDs.removeAll()
        projectHydrationCompletedTrackIDs.removeAll()
        projectHydrationFailedTrackIDs.removeAll()
        projectHydrationLaunchCacheWriteScheduled = false
        projectHydrationImprovedLaunchWaveforms = false
        isLoadingProject = true
        updateStatus("opening project")
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: .info,
            name: "project-load-requested",
            message: "Project load was scheduled off the main thread.",
            fields: ["file": projectURL.lastPathComponent]
        )

        projectCriticalLoadQueue.async {
            let startedAt = CACurrentMediaTime()
            let result = Result {
                try SoundtimeProjectStore.loadRecoveringAutosave(from: projectURL)
            }
            let loadDurationMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000

            DispatchQueue.main.async { [weak self] in
                guard let self, self.projectLoadGeneration == generation else {
                    return
                }

                switch result {
                case let .success(project):
                    self.applyLoadedProjectSkeleton(
                        project,
                        projectURL: projectURL,
                        loadGeneration: generation,
                        loadDurationMilliseconds: loadDurationMilliseconds,
                        statusPrefix: "project"
                    )
                case let .failure(error):
                    self.isLoadingProject = false
                    self.setProjectReadinessState(
                        .failed("project open failed: \(error.localizedDescription)")
                    )
                    SoundtimeDiagnostics.shared.record(
                        category: .system,
                        severity: .warning,
                        name: "project-load-failed",
                        message: "Project could not be loaded.",
                        fields: [
                            "file": projectURL.lastPathComponent,
                            "error": error.localizedDescription,
                        ]
                    )
                }
            }
        }
    }

    private func loadRecoveredAutosave(from url: URL) {
        projectLoadGeneration += 1
        let generation = projectLoadGeneration
        let autosaveURL = url.standardizedFileURL
        projectHydrationQueue?.cancel()
        projectHydrationQueue = nil
        projectHydrationCompletedTrackIDs.removeAll()
        projectHydrationFailedTrackIDs.removeAll()
        projectHydrationLaunchCacheWriteScheduled = false
        projectHydrationImprovedLaunchWaveforms = false
        isLoadingProject = true
        updateStatus("opening recovered autosave")

        DispatchQueue.global(qos: .userInitiated).async {
            let startedAt = CACurrentMediaTime()
            let result = Result {
                try SoundtimeProjectStore.loadRecoveredAutosave(from: autosaveURL)
            }
            let loadDurationMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000

            DispatchQueue.main.async { [weak self] in
                guard let self, self.projectLoadGeneration == generation else {
                    return
                }

                switch result {
                case let .success(recoveredAutosave):
                    let canonicalProjectURL = recoveredAutosave.canonicalProjectURL
                    self.applyLoadedProjectSkeleton(
                        recoveredAutosave.project,
                        projectURL: canonicalProjectURL ?? autosaveURL,
                        loadGeneration: generation,
                        loadDurationMilliseconds: loadDurationMilliseconds,
                        statusPrefix: "recovered autosave",
                        remembersProjectURL: canonicalProjectURL != nil
                    )
                case let .failure(error):
                    self.isLoadingProject = false
                    self.setProjectReadinessState(
                        .failed("autosave recovery failed: \(error.localizedDescription)")
                    )
                }
            }
        }
    }

    private struct LoadedProjectTrackHydration: Sendable {
        var trackID: UUID
        var sourceURL: URL
        var fileInfo: WAVFileInfo?
        var sampleRate: Double
        var sourceOverview: WaveformOverview?
        var displayOverview: WaveformOverview?
        var fileTimeline: AudioFileEditTimeline
        var editableSource: EditableAudioSource
        var zeroCrossingProbe: WAVZeroCrossingProbe?
        var ownsSourceFile: Bool
        var editRevision: Int
    }

    private enum LoadedProjectTrackHydrationResult: Sendable {
        case success(LoadedProjectTrackHydration)
        case failure(trackID: UUID, trackName: String, fileName: String, message: String)
    }

    private final class ProjectHydrationQueue: @unchecked Sendable {
        private struct Job {
            var track: SoundtimeProject.Track
            var priority: Int
            var order: Int
        }

        private let workQueue = DispatchQueue(label: "com.soundtime.project-hydration-queue")
        private let workerQueue = DispatchQueue.global(qos: .userInitiated)
        private let maximumConcurrentJobs: Int
        private let projectURL: URL
        private let waveformOverviewDiskCache: WaveformOverviewDiskCacheStore
        private let deliverResult: (LoadedProjectTrackHydrationResult) -> Void
        private let minimumJobDuration: TimeInterval
        private var pendingJobs: [Job]
        private var activeJobCount = 0
        private var isCancelled = false

        init(
            tracks: [SoundtimeProject.Track],
            projectURL: URL,
            waveformOverviewDiskCache: WaveformOverviewDiskCacheStore,
            activeTrackID: UUID?,
            selectedTrackIDs: Set<UUID>,
            maximumConcurrentJobs: Int = ProjectLaunchHydrationDefaults.maximumConcurrentTrackHydrations,
            minimumJobDuration: TimeInterval = 0,
            deliverResult: @escaping (LoadedProjectTrackHydrationResult) -> Void
        ) {
            self.projectURL = projectURL
            self.waveformOverviewDiskCache = waveformOverviewDiskCache
            self.maximumConcurrentJobs = max(1, maximumConcurrentJobs)
            self.minimumJobDuration = max(minimumJobDuration, 0)
            self.deliverResult = deliverResult
            pendingJobs = ProjectLaunchHydrationPlanner
                .orderedTracks(
                    tracks,
                    activeTrackID: activeTrackID,
                    selectedTrackIDs: selectedTrackIDs
                )
                .enumerated()
                .map { index, track in
                    Job(
                        track: track,
                        priority: ProjectLaunchHydrationPlanner.priority(
                            forTrackID: track.id,
                            order: index,
                            activeTrackID: activeTrackID,
                            selectedTrackIDs: selectedTrackIDs
                        ),
                        order: index
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.priority == rhs.priority {
                        return lhs.order < rhs.order
                    }
                    return lhs.priority < rhs.priority
                }
        }

        func start() {
            workQueue.async { [weak self] in
                self?.scheduleNextJobs()
            }
        }

        func cancel() {
            workQueue.async { [weak self] in
                guard let self else {
                    return
                }
                isCancelled = true
                pendingJobs.removeAll()
            }
        }

        private func scheduleNextJobs() {
            guard !isCancelled else {
                return
            }

            while activeJobCount < maximumConcurrentJobs, !pendingJobs.isEmpty {
                let job = pendingJobs.removeFirst()
                activeJobCount += 1
                workerQueue.async { [weak self] in
                    guard let self else {
                        return
                    }

                    let startedAt = CACurrentMediaTime()
                    let result = WorkspaceView.hydrateLoadedProjectTrack(
                        job.track,
                        projectURL: projectURL,
                        waveformOverviewDiskCache: waveformOverviewDiskCache
                    )
                    let remainingDuration =
                        minimumJobDuration - (CACurrentMediaTime() - startedAt)
                    if remainingDuration > 0 {
                        Thread.sleep(forTimeInterval: remainingDuration)
                    }

                    workQueue.async { [weak self] in
                        guard let self else {
                            return
                        }
                        activeJobCount = max(0, activeJobCount - 1)
                        let shouldDeliverResult = !isCancelled
                        scheduleNextJobs()
                        if shouldDeliverResult {
                            DispatchQueue.main.async { [deliverResult] in
                                deliverResult(result)
                            }
                        }
                    }
                }
            }
        }

    }

    private func applyLoadedProjectSkeleton(
        _ project: SoundtimeProject,
        projectURL: URL,
        loadGeneration: Int,
        loadDurationMilliseconds: Double,
        statusPrefix: String,
        remembersProjectURL: Bool = true
    ) {
        var existingPreviewTracksByID: [UUID: ProjectTrack] = [:]
        for track in projectTracks {
            existingPreviewTracksByID[track.id] = track
        }
        withoutAutosave {
            clearProjectForLoad(publishesTimeline: false)
            currentProjectURL = remembersProjectURL ? projectURL : nil
            applyProjectIdentity(project)
        }
        if remembersProjectURL {
            SoundtimeProjectStore.rememberLastProjectURL(projectURL)
        }
        applyWindowLayout(
            remembersProjectURL ?
                (SoundtimeProjectStore.rememberedWindowLayout(for: projectURL) ?? project.windowLayout) :
                project.windowLayout
        )
        withoutAutosave {
            applyProjectMasterVolume(project.masterVolume)
            applyProjectTimelineViewport(
                remembersProjectURL ?
                    (SoundtimeProjectStore.rememberedTimelineViewport(for: projectURL) ?? project.timelineViewport) :
                    project.timelineViewport
            )
            applyProjectTranscriptDisplayMode(project.transcriptDisplayMode)
            resetWaveformFisheyeTuningToDefaults()
        }
        projectHydrationCompletedTrackIDs.removeAll()
        projectHydrationFailedTrackIDs.removeAll()
        projectHydrationLaunchCacheWriteScheduled = false
        projectHydrationImprovedLaunchWaveforms = false
        let cachedPreviewTrackCount = project.tracks.filter { $0.waveformPreview != nil }.count

        isLoadingProject = true
        projectTracks = project.tracks.map { track in
            var skeletonTrack = launchPreviewTrack(from: track, projectURL: projectURL)
            if let existingTrack = existingPreviewTracksByID[skeletonTrack.id] {
                skeletonTrack.sourceWaveformOverview = bestAvailableLaunchOverview(
                    existingTrack.sourceWaveformOverview,
                    skeletonTrack.sourceWaveformOverview
                )
                skeletonTrack.waveformOverview = bestAvailableLaunchOverview(
                    existingTrack.waveformOverview,
                    skeletonTrack.waveformOverview
                )
                skeletonTrack.durationHint = skeletonTrack.durationHint ??
                    existingTrack.durationHint ??
                    existingTrack.waveformOverview?.duration ??
                    existingTrack.sourceWaveformOverview?.duration
            }
            return skeletonTrack
        }
        normalizeLoadedProjectEditGroups(reason: "project-load")
        isLoadingProject = false

        activeTrackID = projectTracks.first?.id
        selectedTrackID = nil
        selectedTrackIDs.removeAll()
        selectedTimelineRange = nil
        selectedTranscriptSelection = nil
        activeTranscriptWordID = nil
        currentPlaybackStatus = "\(statusPrefix) preview ready"
        restoreSilenceReviewState(project.silenceReviewState)
        refreshProjectTimelineDisplay(
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: true,
            allowImmediateInteractiveWaveformPrewarm: false,
            updatesRendererImmediately: true
        )
        updateProjectDisplayTiming()
        syncActiveTrackFields()
        playbackControllerStorage?.clear()
        updateTransportControlState(isPlaying: false)
        window?.title = projectWindowTitle()
        updateLoadedProjectSummary()
        setProjectReadinessState(
            .visualReady(trackCount: projectTracks.count),
            statusOverride: "\(statusPrefix) preview ready - loading playback"
        )
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: loadDurationMilliseconds > 60 ? .warning : .info,
            name: "project-skeleton-applied",
            message: "Project visual skeleton was applied before track hydration.",
            fields: [
                "file": projectURL.lastPathComponent,
                "tracks": "\(project.tracks.count)",
                "cachedPreviews": "\(cachedPreviewTrackCount)",
                "loadMs": String(format: "%.2f", loadDurationMilliseconds),
            ]
        )

        attachCachedLaunchPreviewsAfterSkeleton(
            project,
            projectURL: projectURL,
            loadGeneration: loadGeneration
        )

        primeLoadedProjectPlayback(
            project,
            projectURL: projectURL,
            loadGeneration: loadGeneration,
            statusPrefix: statusPrefix
        ) { [weak self] in
            self?.hydrateLoadedProjectTracks(
                project,
                projectURL: projectURL,
                loadGeneration: loadGeneration,
                statusPrefix: statusPrefix
            )
        }
    }

    private func attachCachedLaunchPreviewsAfterSkeleton(
        _ project: SoundtimeProject,
        projectURL: URL,
        loadGeneration: Int
    ) {
        guard !project.tracks.isEmpty else {
            return
        }

        let cache = waveformOverviewDiskCache
        let orderedTracks = ProjectLaunchHydrationPlanner.orderedTracks(
            project.tracks,
            activeTrackID: activeTrackID,
            selectedTrackIDs: selectedTrackIDs
        )
        let expectedTrackCount = orderedTracks.count
        let startedAt = CACurrentMediaTime()

        for (order, track) in orderedTracks.enumerated() {
            DispatchQueue.global(qos: .userInitiated).async {
                let hydratedTrack = ProjectLaunchPreviewWaveformCacheHydrator.hydratedTrack(
                    track,
                    waveformOverviewDiskCache: cache
                )
                guard hydratedTrack.waveformPreview != nil else {
                    return
                }

                let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
                DispatchQueue.main.async { [weak self] in
                    self?.applyCachedLaunchPreviewTrack(
                        hydratedTrack,
                        projectURL: projectURL,
                        loadGeneration: loadGeneration,
                        order: order,
                        expectedTrackCount: expectedTrackCount,
                        elapsedMilliseconds: elapsedMilliseconds
                    )
                }
            }
        }
    }

    private func applyCachedLaunchPreviewTrack(
        _ track: SoundtimeProject.Track,
        projectURL: URL,
        loadGeneration: Int,
        order: Int,
        expectedTrackCount: Int,
        elapsedMilliseconds: Double
    ) {
        guard
            projectLoadGeneration == loadGeneration,
            let waveformPreview = track.waveformPreview,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == track.id })
        else {
            return
        }

        let previousDisplayBinCount = projectTracks[trackIndex].waveformOverview?.bins.count ?? 0
        let previousSourceBinCount = projectTracks[trackIndex].sourceWaveformOverview?.bins.count ?? 0
        let sourceOverview = waveformPreview.sourceOverview.waveformOverview
        let displayOverview = waveformPreview.displayOverview.waveformOverview
        projectTracks[trackIndex].sourceWaveformOverview = bestAvailableLaunchOverview(
            sourceOverview,
            projectTracks[trackIndex].sourceWaveformOverview
        )
        projectTracks[trackIndex].waveformOverview = bestAvailableLaunchOverview(
            displayOverview,
            projectTracks[trackIndex].waveformOverview
        ) ?? projectTracks[trackIndex].sourceWaveformOverview
        projectTracks[trackIndex].durationHint = projectTracks[trackIndex].durationHint ??
            displayOverview.duration

        let newDisplayBinCount = projectTracks[trackIndex].waveformOverview?.bins.count ?? 0
        let newSourceBinCount = projectTracks[trackIndex].sourceWaveformOverview?.bins.count ?? 0
        guard newDisplayBinCount > previousDisplayBinCount || newSourceBinCount > previousSourceBinCount else {
            return
        }

        refreshProjectTimelineDisplay(
            rebuildControls: false,
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: true,
            allowImmediateInteractiveWaveformPrewarm: false,
            updatesRendererImmediately: true
        )
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: elapsedMilliseconds > 120 ? .warning : .info,
            name: "project-launch-preview-attached",
            message: "A cached waveform preview was attached after the visual project skeleton.",
            fields: [
                "file": projectURL.lastPathComponent,
                "trackID": track.id.uuidString,
                "track": track.name,
                "order": "\(order + 1)",
                "tracks": "\(expectedTrackCount)",
                "bins": "\(newDisplayBinCount)",
                "elapsedMs": String(format: "%.2f", elapsedMilliseconds),
            ]
        )
    }

    private func primeLoadedProjectPlayback(
        _ project: SoundtimeProject,
        projectURL: URL,
        loadGeneration: Int,
        statusPrefix: String,
        startsFullHydration: @escaping @MainActor () -> Void
    ) {
        projectPlaybackPrimedTrackIDs.removeAll()

        guard !project.tracks.isEmpty else {
            startsFullHydration()
            return
        }

        let activeTrackID = activeTrackID
        let selectedTrackIDs = selectedTrackIDs
        LaunchStartupTrace.shared.mark(
            .playbackPrimeStarted,
            fields: [
                "file": projectURL.lastPathComponent,
                "tracks": "\(project.tracks.count)",
            ]
        )

        projectCriticalLoadQueue.async { [weak self] in
            let result = ProjectLaunchPlaybackPrimer.prime(
                project: project,
                projectURL: projectURL,
                activeTrackID: activeTrackID,
                selectedTrackIDs: selectedTrackIDs
            )
            DispatchQueue.main.async {
                guard let self, self.projectLoadGeneration == loadGeneration else {
                    return
                }

                self.applyLoadedProjectPlaybackPrime(
                    result,
                    loadGeneration: loadGeneration,
                    statusPrefix: statusPrefix
                )
                startsFullHydration()
            }
        }
    }

    private func applyLoadedProjectPlaybackPrime(
        _ result: ProjectLaunchPlaybackPrimeResult,
        loadGeneration: Int,
        statusPrefix: String
    ) {
        guard projectLoadGeneration == loadGeneration else {
            return
        }

        if result.hasPlayableTracks {
            do {
                let playbackTracks = result.tracks.map(\.playbackTrack)
                try playbackController.loadProjectTracks(playbackTracks)
                publishedProjectPlaybackTracks = playbackTracks
                lastPlaybackReloadErrorDescription = nil
                projectPlaybackPrimedTrackIDs = Set(result.tracks.map(\.trackID))
                applyLoadedProjectPlaybackPrimeTracks(result.tracks)
                let outputWarmStartedAt = CACurrentMediaTime()
                var outputWarmFields: [String: String] = [
                    "tracks": "\(result.tracks.count)",
                ]
                do {
                    try playbackController.warmOutputForLowLatencyPlayback()
                    outputWarmFields["warmMs"] = String(format: "%.2f", (CACurrentMediaTime() - outputWarmStartedAt) * 1_000)
                    SoundtimeDiagnostics.shared.record(
                        category: .device,
                        severity: .info,
                        name: "project-output-device-warmed",
                        message: "Realtime output device was started silently for low-latency playback.",
                        fields: outputWarmFields
                    )
                } catch {
                    outputWarmFields["warmMs"] = String(format: "%.2f", (CACurrentMediaTime() - outputWarmStartedAt) * 1_000)
                    outputWarmFields["error"] = error.localizedDescription
                    SoundtimeDiagnostics.shared.record(
                        category: .device,
                        severity: .warning,
                        name: "project-output-device-warm-failed",
                        message: "Realtime output device could not be warmed during project playback prime.",
                        fields: outputWarmFields
                    )
                }

                let snapshot = playbackController.snapshot()
                displayPlaybackVisuals(
                    progress: snapshot.progress,
                    isPlaying: snapshot.isPlaying,
                    syncPlayhead: true,
                    anchorTimestamp: snapshot.hostTimestamp,
                    synchronizesRenderer: false
                )
                updateTimeReadout()
                updateTransportControlState(isPlaying: false)

                let status = result.isComplete ?
                    "\(statusPrefix) playback ready - hydrating details" :
                    "\(statusPrefix) playback partially ready - hydrating details"
                setProjectReadinessState(
                    .playbackHydrating(
                        completed: projectHydrationCompletedTrackIDs.count,
                        failed: projectHydrationFailedTrackIDs.count,
                        total: result.expectedTrackCount
                    ),
                    statusOverride: status
                )
                LaunchStartupTrace.shared.mark(
                    result.isComplete ? .playbackPrimeReady : .playbackPrimeReadyWithFailures,
                    fields: [
                        "primed": "\(result.tracks.count)",
                        "failed": "\(result.failures.count)",
                        "tracks": "\(result.expectedTrackCount)",
                        "primeMs": String(format: "%.2f", result.elapsedMilliseconds),
                    ]
                )
                SoundtimeDiagnostics.shared.record(
                    category: .system,
                    severity: result.isComplete ? .info : .warning,
                    name: result.isComplete ? "project-playback-primed" : "project-playback-primed-with-failures",
                    message: result.isComplete ?
                        "Project playback became available before full track hydration." :
                        "Project playback became partially available before full track hydration.",
                    fields: [
                        "primed": "\(result.tracks.count)",
                        "failed": "\(result.failures.count)",
                        "tracks": "\(result.expectedTrackCount)",
                        "primeMs": String(format: "%.2f", result.elapsedMilliseconds),
                    ]
                )
            } catch {
                publishedProjectPlaybackTracks.removeAll()
                lastPlaybackReloadErrorDescription = error.localizedDescription
                projectPlaybackPrimedTrackIDs.removeAll()
                LaunchStartupTrace.shared.mark(
                    .playbackPrimeReadyWithFailures,
                    fields: [
                        "primed": "0",
                        "failed": "\(result.expectedTrackCount)",
                        "tracks": "\(result.expectedTrackCount)",
                        "primeMs": String(format: "%.2f", result.elapsedMilliseconds),
                        "error": error.localizedDescription,
                    ]
                )
                SoundtimeDiagnostics.shared.record(
                    category: .system,
                    severity: .warning,
                    name: "project-playback-prime-load-failed",
                    message: "Project playback prime data was prepared, but the playback engine could not load it.",
                    fields: [
                        "error": error.localizedDescription,
                        "primeMs": String(format: "%.2f", result.elapsedMilliseconds),
                    ]
                )
            }
        } else {
            publishedProjectPlaybackTracks.removeAll()
            projectPlaybackPrimedTrackIDs.removeAll()
            LaunchStartupTrace.shared.mark(
                .playbackPrimeReadyWithFailures,
                fields: [
                    "primed": "0",
                    "failed": "\(result.failures.count)",
                    "tracks": "\(result.expectedTrackCount)",
                    "primeMs": String(format: "%.2f", result.elapsedMilliseconds),
                ]
            )
        }

        for failure in result.failures {
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .warning,
                name: "project-playback-prime-track-failed",
                message: "Project track could not be primed for immediate playback.",
                fields: [
                    "trackID": failure.trackID.uuidString,
                    "trackName": failure.trackName,
                    "file": failure.fileName,
                    "error": failure.message,
                ]
            )
        }
    }

    private func applyLoadedProjectPlaybackPrimeTracks(_ tracks: [ProjectLaunchPlaybackPrimeTrack]) {
        for primeTrack in tracks {
            guard let trackIndex = projectTracks.firstIndex(where: { $0.id == primeTrack.trackID }) else {
                continue
            }

            if let fileInfo = primeTrack.fileInfo {
                wavFileInfoCache[primeTrack.sourceURL] = fileInfo
            }
            projectTracks[trackIndex].sourceURL = primeTrack.sourceURL
            projectTracks[trackIndex].durationHint = projectTracks[trackIndex].durationHint ??
                primeTrack.fileTimeline?.duration
            projectTracks[trackIndex].fileTimeline = primeTrack.fileTimeline
            projectTracks[trackIndex].editableSource = primeTrack.editableSource
            projectTracks[trackIndex].ownsSourceFile = primeTrack.ownsSourceFile
            projectTracks[trackIndex].editRevision = primeTrack.editRevision
        }

        updateProjectDisplayTiming(sampleRateHint: tracks.first?.sampleRate)
        updateEffectCommandState()
    }

    private func hydrateLoadedProjectTracks(
        _ project: SoundtimeProject,
        projectURL: URL,
        loadGeneration: Int,
        statusPrefix: String
    ) {
        guard !project.tracks.isEmpty else {
            setProjectReadinessState(.playbackReady(trackCount: 0), statusOverride: "\(statusPrefix) ready")
            return
        }

        let cache = waveformOverviewDiskCache
        let expectedTrackCount = project.tracks.count
        let hydrationBaseEditRevision = currentEditGraphRevision
        let hydrationBaseTrackEditRevisions = Dictionary(
            uniqueKeysWithValues: projectTracks.map { ($0.id, $0.editRevision) }
        )
        projectHydrationLaunchCacheWriteScheduled = false
        projectHydrationImprovedLaunchWaveforms = false
        let hydrationQueue = ProjectHydrationQueue(
            tracks: project.tracks,
            projectURL: projectURL,
            waveformOverviewDiskCache: cache,
            activeTrackID: activeTrackID,
            selectedTrackIDs: selectedTrackIDs,
            minimumJobDuration: CommandLine.arguments.contains("--visual-invariants-smoke") ?
                0.05 :
                0
        ) { [weak self] hydrationResult in
            self?.applyLoadedProjectTrackHydration(
                hydrationResult,
                loadGeneration: loadGeneration,
                expectedTrackCount: expectedTrackCount,
                hydrationBaseEditRevision: hydrationBaseEditRevision,
                hydrationBaseTrackEditRevisions: hydrationBaseTrackEditRevisions,
                statusPrefix: statusPrefix
            )
        }
        projectHydrationQueue = hydrationQueue
        setProjectReadinessState(
            .playbackHydrating(completed: 0, failed: 0, total: expectedTrackCount),
            statusOverride: playbackController.hasSource ?
                "\(statusPrefix) playback ready - hydrating details 0/\(expectedTrackCount)" :
                "\(statusPrefix) loading playback 0/\(expectedTrackCount)"
        )
        LaunchStartupTrace.shared.mark(
            .playbackHydrationStarted,
            fields: [
                "file": projectURL.lastPathComponent,
                "tracks": "\(expectedTrackCount)",
                "maxConcurrent": "\(ProjectLaunchHydrationDefaults.maximumConcurrentTrackHydrations)",
            ]
        )
        hydrationQueue.start()
        SoundtimeDiagnostics.shared.record(
            category: .system,
            severity: .info,
            name: "project-hydration-queue-started",
            message: "Project track hydration is bounded and prioritized.",
            fields: [
                "tracks": "\(expectedTrackCount)",
                "maxConcurrent": "\(ProjectLaunchHydrationDefaults.maximumConcurrentTrackHydrations)",
            ]
        )
    }

    private func finishLoadedProjectHydrationIfReady(
        expectedTrackCount: Int,
        hydrationBaseEditRevision: UInt64,
        statusPrefix: String
    ) {
        let completedTrackCount = projectHydrationCompletedTrackIDs.count
        let failedTrackCount = projectHydrationFailedTrackIDs.count
        guard completedTrackCount + failedTrackCount >= expectedTrackCount else {
            return
        }

        projectHydrationQueue = nil
        isLoadingProject = false
        updateProjectDisplayTiming()
        updateTimeReadout()
        if
            DeferredEditStatePublicationPolicy.mayReplaceCurrentState(
                capturedRevision: hydrationBaseEditRevision,
                currentRevision: currentEditGraphRevision
            ),
            projectPlaybackPrimedTrackIDs.count < completedTrackCount
        {
            reloadPlaybackFromProjectTracks(preserveProgress: true)
        } else {
            updateTransportControlState(isPlaying: playbackController.isPlaying)
        }
        updateEffectCommandState()
        if completedTrackCount >= expectedTrackCount {
            setProjectReadinessState(
                .playbackReady(trackCount: completedTrackCount),
                statusOverride: "\(statusPrefix) ready"
            )
            LaunchStartupTrace.shared.mark(
                .playbackReady,
                fields: [
                    "hydrated": "\(completedTrackCount)",
                    "tracks": "\(expectedTrackCount)",
                ]
            )
        } else {
            setProjectReadinessState(
                .playbackReadyWithFailures(completed: completedTrackCount, failed: failedTrackCount),
                statusOverride: "\(statusPrefix) ready with \(failedTrackCount) missing track\(failedTrackCount == 1 ? "" : "s")"
            )
            LaunchStartupTrace.shared.mark(
                .playbackReadyWithFailures,
                fields: [
                    "hydrated": "\(completedTrackCount)",
                    "failed": "\(failedTrackCount)",
                    "tracks": "\(expectedTrackCount)",
                ]
            )
        }

        if !projectHydrationLaunchCacheWriteScheduled {
            projectHydrationLaunchCacheWriteScheduled = true
            if projectHydrationImprovedLaunchWaveforms {
                scheduleLaunchSnapshotSaveIfNeeded(reason: "project-hydration-complete", delay: 0.75)
            }
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: failedTrackCount == 0 ? .info : .warning,
                name: "project-hydration-complete",
                message: failedTrackCount == 0 ?
                    "Project track hydration completed." :
                    "Project track hydration completed with missing tracks.",
                fields: [
                    "hydrated": "\(completedTrackCount)",
                    "failed": "\(failedTrackCount)",
                    "tracks": "\(expectedTrackCount)",
                    "launchCacheRefresh": "\(projectHydrationImprovedLaunchWaveforms)",
                ]
            )
        }
    }

    private nonisolated static func hydrateLoadedProjectTrack(
        _ track: SoundtimeProject.Track,
        projectURL: URL,
        waveformOverviewDiskCache: WaveformOverviewDiskCacheStore
    ) -> LoadedProjectTrackHydrationResult {
        var lastError: Error?
        for sourceURL in track.audioSourceCandidateURLs {
            do {
            guard let fileInfo = try? WAVAudioDecoder.inspect(url: sourceURL) else {
                let assetInfo = try AudioAssetImporter.inspectSynchronously(url: sourceURL)
                guard
                    let sourceFrameCount = assetInfo.frameCount,
                    let sourceSampleRate = assetInfo.sampleRate,
                    let channelCount = assetInfo.channelCount,
                    sourceFrameCount > 0,
                    sourceSampleRate > 0,
                    channelCount > 0
                else {
                    throw AudioAssetImporter.ImportError.unreadableNativeAudio(assetInfo.format)
                }
                let persistedTimeline = track.editTimeline
                    .flatMap(AudioFileEditTimeline.init)
                    .flatMap { timeline in
                        timeline.sourceFrameCount == sourceFrameCount &&
                            abs(timeline.sourceSampleRate - sourceSampleRate) < 0.001 ?
                            timeline :
                            nil
                    }
                let canonicalTimeline = persistedTimeline ?? AudioFileEditTimeline(
                    sourceFrameCount: sourceFrameCount,
                    sourceSampleRate: sourceSampleRate
                )
                let assetID = track.importedAssetState?.assetID ??
                    track.editableSource?.importedAssetID ??
                    UUID()
                let restoredEditableSource = track.editableSource?.editableAudioSource()
                let editableSource =
                    restoredEditableSource.flatMap { source in
                        source.editableURL.standardizedFileURL == sourceURL ? source : nil
                    } ??
                    EditableAudioSource(
                        importedAssetID: assetID,
                        originalURL: track.importedAssetState.map {
                            URL(fileURLWithPath: $0.originalFilePath)
                        } ?? sourceURL,
                        editableURL: sourceURL,
                        formatOrigin: track.importedAssetState?.format ?? assetInfo.format,
                        sourceFrameCount: sourceFrameCount,
                        sourceSampleRate: sourceSampleRate,
                        channelCount: channelCount,
                        ownsEditableFile: false
                    )
                let sourceOverview = track.waveformPreview?.sourceOverview.waveformOverview
                let displayOverview = track.waveformPreview?.displayOverview.waveformOverview ??
                    sourceOverview

                return .success(LoadedProjectTrackHydration(
                    trackID: track.id,
                    sourceURL: sourceURL,
                    fileInfo: nil,
                    sampleRate: sourceSampleRate,
                    sourceOverview: sourceOverview,
                    displayOverview: displayOverview,
                    fileTimeline: canonicalTimeline,
                    editableSource: editableSource,
                    zeroCrossingProbe: nil,
                    ownsSourceFile: false,
                    editRevision: canonicalTimeline.hasEdits ? 1 : 0
                ))
            }
            let persistedFileTimeline: AudioFileEditTimeline?
            if
                let editTimeline = track.editTimeline,
                let restoredTimeline = AudioFileEditTimeline(persistentState: editTimeline),
                restoredTimeline.isCompatible(with: fileInfo)
            {
                persistedFileTimeline = restoredTimeline
            } else {
                persistedFileTimeline = nil
            }
            let canonicalFileTimeline = persistedFileTimeline ?? AudioFileEditTimeline(fileInfo: fileInfo)
            let editableSource = track.editableSource?.editableAudioSource(fileInfo: fileInfo) ??
                EditableAudioSource(
                    importedAssetID: track.editableSource?.importedAssetID,
                    originalURL: track.editableSource.map { URL(fileURLWithPath: $0.originalFilePath) } ?? sourceURL,
                    editableURL: sourceURL,
                    formatOrigin: track.editableSource?.formatOrigin ?? AudioAssetFormat.inferred(from: sourceURL),
                    fileInfo: fileInfo,
                    ownsEditableFile: track.ownsSourceFile ?? false
                )
            let launchPreview = track.waveformPreview?.isValid(for: fileInfo) == true ? track.waveformPreview : nil
            let cachedLaunchEntry = try? waveformOverviewDiskCache.loadBestOverview(
                for: sourceURL,
                fileInfo: fileInfo,
                maximumBinCount: ProjectLaunchHydrationDefaults.firstRefinementBinCount
            )
            let cachedEditedLaunchEntry: EditedWaveformOverviewDiskCacheEntry?
            if let persistedFileTimeline, persistedFileTimeline.hasEdits {
                cachedEditedLaunchEntry = try? waveformOverviewDiskCache.loadEditedOverview(
                    for: sourceURL,
                    fileInfo: fileInfo,
                    editTimeline: persistedFileTimeline
                )
            } else {
                cachedEditedLaunchEntry = nil
            }

            let previewSourceOverview = launchPreview?.sourceOverview.waveformOverview
            let previewDisplayOverview = launchPreview?.displayOverview.waveformOverview
            let sourceOverview = bestLaunchOverview(
                cachedLaunchEntry?.overview,
                previewSourceOverview
            )
            let displayOverview: WaveformOverview?
            if persistedFileTimeline != nil {
                displayOverview = cachedEditedLaunchEntry?.overview ??
                    previewDisplayOverview ??
                    sourceOverview
            } else {
                displayOverview = bestLaunchOverview(
                    cachedLaunchEntry?.overview,
                    previewDisplayOverview
                )
            }
            let zeroCrossingProbe = try? WAVAudioDecoder.makeZeroCrossingProbe(
                url: sourceURL,
                fileInfo: fileInfo
            )

            return .success(LoadedProjectTrackHydration(
                trackID: track.id,
                sourceURL: sourceURL,
                fileInfo: fileInfo,
                sampleRate: fileInfo.sampleRate,
                sourceOverview: sourceOverview,
                displayOverview: displayOverview,
                fileTimeline: canonicalFileTimeline,
                editableSource: editableSource,
                zeroCrossingProbe: zeroCrossingProbe,
                ownsSourceFile: track.ownsSourceFile ?? false,
                editRevision: canonicalFileTimeline.hasEdits ? 1 : 0
            ))
            } catch {
                lastError = error
            }
        }

        return .failure(
            trackID: track.id,
            trackName: track.name,
            fileName: projectURL.lastPathComponent,
            message: lastError?.localizedDescription ?? "No saved audio source is available."
        )
    }

    private func applyLoadedProjectTrackHydration(
        _ result: LoadedProjectTrackHydrationResult,
        loadGeneration: Int,
        expectedTrackCount: Int,
        hydrationBaseEditRevision: UInt64,
        hydrationBaseTrackEditRevisions: [UUID: Int],
        statusPrefix: String
    ) {
        guard projectLoadGeneration == loadGeneration else {
            return
        }

        switch result {
        case let .success(hydration):
            projectHydrationCompletedTrackIDs.insert(hydration.trackID)
            guard let trackIndex = projectTracks.firstIndex(where: { $0.id == hydration.trackID }) else {
                finishLoadedProjectHydrationIfReady(
                    expectedTrackCount: expectedTrackCount,
                    hydrationBaseEditRevision: hydrationBaseEditRevision,
                    statusPrefix: statusPrefix
                )
                return
            }

            let canApplyHydratedEditState = hydrationBaseTrackEditRevisions[hydration.trackID].map {
                DeferredEditStatePublicationPolicy.mayReplaceCurrentState(
                    capturedRevision: $0,
                    currentRevision: projectTracks[trackIndex].editRevision
                )
            } ?? false
            if let fileInfo = hydration.fileInfo {
                wavFileInfoCache[hydration.sourceURL] = fileInfo
            }
            projectTracks[trackIndex].sourceURL = hydration.sourceURL
            let previousDuration = trackDuration(for: projectTracks[trackIndex])
            let previousSourceBinCount = projectTracks[trackIndex].sourceWaveformOverview?.bins.count ?? 0
            let previousDisplayBinCount = projectTracks[trackIndex].waveformOverview?.bins.count ?? 0
            projectTracks[trackIndex].sourceWaveformOverview = bestAvailableLaunchOverview(
                hydration.sourceOverview,
                projectTracks[trackIndex].sourceWaveformOverview
            )
            if canApplyHydratedEditState {
                projectTracks[trackIndex].waveformOverview = bestAvailableLaunchOverview(
                    hydration.displayOverview,
                    projectTracks[trackIndex].waveformOverview
                ) ?? projectTracks[trackIndex].sourceWaveformOverview
            }
            let hydratedSourceBinCount = projectTracks[trackIndex].sourceWaveformOverview?.bins.count ?? 0
            let hydratedDisplayBinCount = projectTracks[trackIndex].waveformOverview?.bins.count ?? 0
            let waveformImproved = hydratedSourceBinCount > previousSourceBinCount ||
                hydratedDisplayBinCount > previousDisplayBinCount
            if waveformImproved {
                projectHydrationImprovedLaunchWaveforms = true
            }
            projectTracks[trackIndex].zeroCrossingProbe = hydration.zeroCrossingProbe
            projectTracks[trackIndex].ownsSourceFile = hydration.ownsSourceFile
            if canApplyHydratedEditState {
                projectTracks[trackIndex].editRevision = hydration.editRevision
                applyEditableTimelineMirror(
                    trackIndex: trackIndex,
                    source: hydration.editableSource,
                    timeline: hydration.fileTimeline
                )
            } else {
                SoundtimeDiagnostics.shared.record(
                    category: .edit,
                    severity: .info,
                    name: "project-track-hydration-edit-state-skipped",
                    message: "A late hydration result preserved a newer user edit.",
                    fields: [
                        "trackID": hydration.trackID.uuidString,
                        "hydrationRevision": "\(hydrationBaseTrackEditRevisions[hydration.trackID] ?? -1)",
                        "currentRevision": "\(projectTracks[trackIndex].editRevision)",
                    ]
                )
            }
            timelinePresentationDirtyTrackIDs.insert(hydration.trackID)
            if hydration.fileInfo == nil, canApplyHydratedEditState {
                projectTracks[trackIndex].importedAssetID =
                    projectTracks[trackIndex].importedAssetID ??
                    hydration.editableSource.importedAssetID
                resumeImportedAudioPreparationIfNeeded(trackID: hydration.trackID)
            }

            let hydratedTrackCount = projectTracks.filter { $0.editableSource != nil }.count
            let completedTrackCount = projectHydrationCompletedTrackIDs.count
            let shouldPublishHydrationProgress = shouldRecordTrackHydratedDiagnostic(
                completedTrackCount: completedTrackCount,
                expectedTrackCount: expectedTrackCount
            )
            let waveformBecameDrawable =
                previousSourceBinCount == 0 &&
                previousDisplayBinCount == 0 &&
                (hydratedSourceBinCount > 0 || hydratedDisplayBinCount > 0)
            let durationChanged =
                abs(trackDuration(for: projectTracks[trackIndex]) - previousDuration) > 0.000_001
            if
                waveformBecameDrawable ||
                durationChanged ||
                shouldPublishHydrationProgress
            {
                publishCanonicalTimelinePresentation(
                    replacingTrackAt: timelinePresentationDirtyTrackIDs.count == 1 ?
                        trackIndex :
                        nil,
                    sampleRateHint: hydration.sampleRate,
                    reason: "track-hydration",
                    recordsDiagnosticEvent: shouldPublishHydrationProgress
                )
            }
            if durationChanged && shouldPublishHydrationProgress {
                updateTimeReadout()
            }
            let statusOverride: String
            if playbackController.hasSource, completedTrackCount < expectedTrackCount {
                statusOverride = "\(statusPrefix) playback ready - hydrating details \(completedTrackCount)/\(expectedTrackCount)"
            } else if hydratedTrackCount >= expectedTrackCount {
                statusOverride = "\(statusPrefix) ready"
            } else {
                statusOverride = "\(statusPrefix) loading playback \(hydratedTrackCount)/\(expectedTrackCount)"
            }
            if shouldPublishHydrationProgress {
                setProjectReadinessState(
                    .playbackHydrating(
                        completed: completedTrackCount,
                        failed: projectHydrationFailedTrackIDs.count,
                        total: expectedTrackCount
                    ),
                    statusOverride: statusOverride
                )
                SoundtimeDiagnostics.shared.record(
                    category: .system,
                    severity: .info,
                    name: "project-track-hydrated",
                    message: "Project track became ready for playback/editing.",
                    fields: [
                        "trackID": hydration.trackID.uuidString,
                        "file": hydration.sourceURL.lastPathComponent,
                        "hydrated": "\(hydratedTrackCount)",
                        "tracks": "\(expectedTrackCount)",
                        "bins": "\(hydration.displayOverview?.bins.count ?? hydration.sourceOverview?.bins.count ?? 0)",
                    ]
                )
            }
            LaunchStartupTrace.shared.mark(
                .playbackTrackReady,
                fields: [
                    "trackID": hydration.trackID.uuidString,
                    "file": hydration.sourceURL.lastPathComponent,
                    "hydrated": "\(projectHydrationCompletedTrackIDs.count)",
                    "failed": "\(projectHydrationFailedTrackIDs.count)",
                    "tracks": "\(expectedTrackCount)",
                ],
                recordsDiagnosticEvent: shouldPublishHydrationProgress
            )
            finishLoadedProjectHydrationIfReady(
                expectedTrackCount: expectedTrackCount,
                hydrationBaseEditRevision: hydrationBaseEditRevision,
                statusPrefix: statusPrefix
            )
        case let .failure(trackID, trackName, fileName, message):
            projectHydrationFailedTrackIDs.insert(trackID)
            setProjectReadinessState(
                .playbackHydrating(
                    completed: projectHydrationCompletedTrackIDs.count,
                    failed: projectHydrationFailedTrackIDs.count,
                    total: expectedTrackCount
                )
            )
            finishLoadedProjectHydrationIfReady(
                expectedTrackCount: expectedTrackCount,
                hydrationBaseEditRevision: hydrationBaseEditRevision,
                statusPrefix: statusPrefix
            )
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .warning,
                name: "project-track-hydration-failed",
                message: "Project track could not be hydrated for playback/editing.",
                fields: [
                    "trackID": trackID.uuidString,
                    "trackName": trackName,
                    "file": fileName,
                    "error": message,
                ]
            )
        }
    }

    private func shouldRecordTrackHydratedDiagnostic(
        completedTrackCount: Int,
        expectedTrackCount: Int
    ) -> Bool {
        guard expectedTrackCount > 12 else {
            return true
        }
        if completedTrackCount <= 1 || completedTrackCount >= expectedTrackCount {
            return true
        }
        let stride = max(10, expectedTrackCount / 10)
        return completedTrackCount.isMultiple(of: stride)
    }

    private nonisolated static func bestLaunchOverview(
        _ first: WaveformOverview?,
        _ second: WaveformOverview?
    ) -> WaveformOverview? {
        guard let first else {
            return second
        }
        guard let second else {
            return first
        }
        return first.bins.count >= second.bins.count ? first : second
    }

    private func resetProjectIdentityForNewDocument() {
        currentProjectID = UUID()
        currentEditGraphRevision = 1
        currentVisualRevision = 1
        currentLaunchStateRevision = 1
    }

    private func applyProjectIdentity(_ project: SoundtimeProject) {
        currentProjectID = project.projectID
        currentEditGraphRevision = max(project.editGraphRevision, 1)
        currentVisualRevision = max(project.visualRevision, 1)
        currentLaunchStateRevision = max(project.launchStateRevision, 1)
    }

    private func applyLaunchFirstFrameIdentity(_ firstFrame: ProjectLaunchFirstFrame) {
        if let projectID = firstFrame.projectID {
            currentProjectID = projectID
        }
        if let editGraphRevision = firstFrame.editGraphRevision {
            currentEditGraphRevision = max(editGraphRevision, 1)
        }
        if let visualRevision = firstFrame.visualRevision {
            currentVisualRevision = max(visualRevision, 1)
        }
        if let launchStateRevision = firstFrame.launchStateRevision {
            currentLaunchStateRevision = max(launchStateRevision, 1)
        }
    }

    private func advanceLaunchStateRevision() {
        currentLaunchStateRevision = currentLaunchStateRevision &+ 1
        if currentLaunchStateRevision == 0 {
            currentLaunchStateRevision = 1
        }
    }

    private func clearProjectForLoad(publishesTimeline: Bool = true) {
        projectHydrationQueue?.cancel()
        projectHydrationQueue = nil
        projectHydrationCompletedTrackIDs.removeAll()
        projectHydrationFailedTrackIDs.removeAll()
        projectHydrationLaunchCacheWriteScheduled = false
        projectHydrationImprovedLaunchWaveforms = false
        projectReadinessState = .empty
        viewportPersistenceWorkItem?.cancel()
        viewportPersistenceWorkItem = nil
        launchWaveformCacheTasks.cancelAll()
        latestTimelineViewportForPersistence = nil
        deleteAllOwnedSourceFiles()
        playbackControllerStorage?.clear()
        publishedProjectPlaybackTracks.removeAll()
        projectTracks.removeAll()
        projectEditGraph = EditGraph()
        activeTrackID = nil
        selectedTrackID = nil
        selectedTrackIDs.removeAll()
        trackSelectionAnchorID = nil
        defaultEditGroupID = UUID()
        resetProjectIdentityForNewDocument()
        decodedAudioBuffer = nil
        audioTimeline = nil
        editUndoStack.removeAll()
        selectedAudioFile = nil
        selectedTimelineRange = nil
        selectedTranscriptSelection = nil
        activeTranscriptWordID = nil
        loadedAudioSummary = nil
        currentPlayheadFrame = 0
        displayedFrameCount = 0
        displayedSampleRate = 0
        currentPlaybackStatus = "idle"
        stopPlaybackTimer()
        if publishesTimeline {
            timelineSurface.displaySelection(nil)
            timelineSurface.displayTranscriptSelection(nil)
            timelineSurface.displayTranscriptActiveWord(nil)
            publishSelectedTracksToTimeline()
            timelineSurface.displayGainPreview(selection: nil, gain: 1)
            refreshProjectTimelineDisplay()
            displayPlaybackVisuals(progress: 0, isPlaying: false, synchronizesRenderer: false)
            updateTimeReadout()
            updateEffectCommandState()
        }
    }

    private func prepareProjectForSerialization() throws {
        if recordingTrackID != nil {
            stopRecording()
        }
    }

    private func scheduleLaunchDetailWaveformCachesForCurrentProject(reason: String) {
        for track in projectTracks {
            guard let fileInfo = decodableWAVFileInfo(for: track.sourceURL) else {
                continue
            }

            let candidateOverview: WaveformOverview?
            if let fileTimeline = track.fileTimeline {
                candidateOverview = bestSourceWaveformOverview(
                    sourceOverview: track.sourceWaveformOverview,
                    fallbackOverview: track.waveformOverview,
                    fileTimeline: fileTimeline
                )
            } else {
                candidateOverview = track.sourceWaveformOverview ?? track.waveformOverview
            }

            ensureLaunchDetailWaveformCache(
                fileInfo: fileInfo,
                candidateOverview: candidateOverview,
                trackID: track.id,
                trackName: track.name,
                reason: reason
            )
        }
    }

    private func materializeInMemoryEditedProjectTracksForSerialization() throws {
        var replacedTracks: [ProjectTrack] = []
        var didMaterializeTrack = false

        for trackIndex in projectTracks.indices {
            guard needsOwnedSourceMaterializationForSave(projectTracks[trackIndex]) else {
                continue
            }

            guard let buffer = projectTracks[trackIndex].decodedAudioBuffer ??
                projectTracks[trackIndex].audioTimeline?.render()
            else {
                continue
            }

            replacedTracks.append(projectTracks[trackIndex])
            let materializedURL = recordingFileURL(trackName: "\(projectTracks[trackIndex].name)-Edit")
            try WAVFileWriter.write(buffer, to: materializedURL)
            let fileInfo = try WAVAudioDecoder.inspect(url: materializedURL)
            let waveformOverview = WaveformOverviewBuilder.build(from: buffer)

            projectTracks[trackIndex].sourceURL = materializedURL
            projectTracks[trackIndex].durationHint = buffer.duration
            projectTracks[trackIndex].sourceWaveformOverview = waveformOverview
            projectTracks[trackIndex].waveformOverview = waveformOverview
            projectTracks[trackIndex].decodedAudioBuffer = buffer
            projectTracks[trackIndex].zeroCrossingIndex = AudioZeroCrossingIndex.build(from: buffer)
            projectTracks[trackIndex].zeroCrossingProbe = try? WAVAudioDecoder.makeZeroCrossingProbe(
                url: materializedURL,
                fileInfo: fileInfo
            )
            let fileTimeline = AudioFileEditTimeline(fileInfo: fileInfo)
            let editableSource = editableAudioSource(
                originalURL: materializedURL,
                editableURL: materializedURL,
                formatOrigin: .wav,
                fileInfo: fileInfo,
                ownsEditableFile: true
            )
            applyEditableTimelineMirror(
                trackIndex: trackIndex,
                source: editableSource,
                timeline: fileTimeline,
                clearsDecodedAudio: false
            )
            projectTracks[trackIndex].ownsSourceFile = true
            projectTracks[trackIndex].importID = UUID()
            projectTracks[trackIndex].editRevision += 1
            didMaterializeTrack = true
        }

        guard didMaterializeTrack else {
            return
        }

        syncActiveTrackFields()
        refreshProjectTimelineDisplay(rebuildControls: false, animateWaveformTransition: false)
        updateProjectDisplayTiming()
        reloadPlaybackFromProjectTracks(preserveProgress: true)
        cleanupOwnedSourceFiles(replacedTracks: replacedTracks)
    }

    private func needsOwnedSourceMaterializationForSave(_ track: ProjectTrack) -> Bool {
        guard track.audioTimeline != nil else {
            return false
        }

        return persistedEditTimeline(for: track) == nil
    }

    private func currentProject(includeWaveformPreviews: Bool = true) -> SoundtimeProject {
        SoundtimeProject(
            projectID: currentProjectID,
            editGraphRevision: currentEditGraphRevision,
            visualRevision: currentVisualRevision,
            launchStateRevision: currentLaunchStateRevision,
            tracks: projectTracks.compactMap { track in
                let fileInfo = decodableWAVFileInfo(for: track.sourceURL)
                guard
                    fileInfo != nil ||
                    (
                        AudioAssetImporter.canImport(track.sourceURL) &&
                        track.importedAssetID != nil &&
                        track.editableSource != nil
                    )
                else {
                    return nil
                }

                let waveformPreview: SoundtimeProject.WaveformPreview?
                if let fileInfo {
                    waveformPreview = includeWaveformPreviews ?
                        SoundtimeProject.WaveformPreview(
                            sourceOverview: track.sourceWaveformOverview,
                            displayOverview: track.waveformOverview,
                            fileInfo: fileInfo
                        ) :
                        nil
                } else if let importFingerprint = track.importFingerprint {
                    waveformPreview = includeWaveformPreviews ?
                        SoundtimeProject.WaveformPreview(
                            sourceOverview: track.sourceWaveformOverview,
                            displayOverview: track.waveformOverview,
                            importedFingerprint: importFingerprint
                        ) :
                        nil
                } else {
                    waveformPreview = nil
                }
                let importedAssetState: SoundtimeProject.Track.ImportedAssetState?
                if
                    let assetID = track.importedAssetID,
                    let fingerprint = track.importFingerprint,
                    let editableSource = track.editableSource
                {
                    importedAssetState = SoundtimeProject.Track.ImportedAssetState(
                        assetID: assetID,
                        originalURL: editableSource.originalURL,
                        format: editableSource.formatOrigin,
                        fingerprint: fingerprint,
                        stage: track.importStage ?? .complete
                    )
                } else {
                    importedAssetState = nil
                }

                return SoundtimeProject.Track(
                    id: track.id,
                    editGroupID: track.editGroupID,
                    name: track.name,
                    filePath: track.sourceURL.path,
                    volume: track.volume,
                    isMuted: track.isMuted,
                    isSoloed: track.isSoloed,
                    editTimeline: persistedEditTimeline(for: track),
                    editableSource: track.editableSource.map(SoundtimeProject.Track.EditableSource.init),
                    waveformPreview: waveformPreview,
                    ownsSourceFile: track.ownsSourceFile,
                    transcript: track.transcript,
                    importedAssetState: importedAssetState
                )
            },
            windowLayout: currentWindowLayout(),
            masterVolume: volumeControl.perceptualVolume,
            timelineViewport: currentTimelineViewport(),
            silenceReviewState: currentSilenceReviewState(),
            transcriptionJobs: activeTranscriptionJob.map { [$0.persistentSnapshot] },
            transcriptDisplayMode: isTranscriptLayerVisible ? .waveformOverlay : .hidden
        )
    }

    private func applyProjectMasterVolume(_ volume: Float?) {
        guard let volume, volume.isFinite else {
            return
        }

        let clampedVolume = min(max(volume, 0), 1)
        volumeControl.perceptualVolume = clampedVolume
        playbackControllerStorage?.setPerceptualVolume(clampedVolume)
    }

    private func currentTimelineViewport() -> SoundtimeProject.TimelineViewport? {
        projectTimelineViewport(for: timelineSurface.currentViewport)
    }

    private func projectTimelineViewport(for viewport: TimelineViewport) -> SoundtimeProject.TimelineViewport? {
        guard
            viewport.startProgress.isFinite,
            viewport.durationProgress.isFinite,
            viewport.durationProgress > 0
        else {
            return nil
        }

        return SoundtimeProject.TimelineViewport(
            startProgress: viewport.startProgress,
            durationProgress: viewport.durationProgress
        )
    }

    private func applyProjectTimelineViewport(_ viewport: SoundtimeProject.TimelineViewport?) {
        guard
            let viewport,
            viewport.startProgress.isFinite,
            viewport.durationProgress.isFinite,
            viewport.durationProgress > 0
        else {
            timelineSurface.restoreViewport(nil)
            return
        }

        timelineSurface.restoreViewport(TimelineViewport(
            startProgress: viewport.startProgress,
            durationProgress: viewport.durationProgress
        ))
    }

    private func applyProjectTranscriptDisplayMode(_ mode: TranscriptTimelineDisplayMode?) {
        let displayMode = mode ?? .hidden
        isTranscriptLayerVisible = displayMode != .hidden
        timelineSurface.displayTranscriptMode(displayMode)
    }

    private func persistedEditTimeline(for track: ProjectTrack) -> AudioFileEditTimeline.PersistentState? {
        guard decodableWAVFileInfo(for: track.sourceURL) != nil else {
            return nil
        }

        if let fileTimeline = track.fileTimeline, fileTimeline.hasEdits {
            return fileTimeline.persistentState
        }

        guard
            let audioTimeline = track.audioTimeline,
            let fileInfo = try? WAVAudioDecoder.inspect(url: track.sourceURL),
            audioTimeline.sourceAudioBuffer.frameCount == fileInfo.frameCount,
            abs(audioTimeline.sourceAudioBuffer.sampleRate - fileInfo.sampleRate) < 0.001,
            let fileTimeline = AudioFileEditTimeline(
                sourceFrameCount: fileInfo.frameCount,
                sourceSampleRate: fileInfo.sampleRate,
                playbackSegments: audioTimeline.playbackSegments
            ),
            fileTimeline.hasEdits,
            fileTimeline.isCompatible(with: fileInfo)
        else {
            return nil
        }

        return fileTimeline.persistentState
    }

    private func currentWindowLayout() -> SoundtimeProject.WindowLayout? {
        guard let frame = window?.frame else {
            return nil
        }

        guard
            frame.origin.x.isFinite,
            frame.origin.y.isFinite,
            frame.width.isFinite,
            frame.height.isFinite,
            frame.width > 0,
            frame.height > 0
        else {
            return nil
        }

        return SoundtimeProject.WindowLayout(
            x: Double(frame.origin.x),
            y: Double(frame.origin.y),
            width: Double(frame.width),
            height: Double(frame.height)
        )
    }

    private func applyWindowLayout(_ layout: SoundtimeProject.WindowLayout?) {
        guard
            let layout,
            let window,
            layout.x.isFinite,
            layout.y.isFinite,
            layout.width.isFinite,
            layout.height.isFinite,
            layout.width > 0,
            layout.height > 0
        else {
            return
        }

        var frame = NSRect(
            x: CGFloat(layout.x),
            y: CGFloat(layout.y),
            width: CGFloat(layout.width),
            height: CGFloat(layout.height)
        )
        frame.size.width = max(frame.width, window.minSize.width)
        frame.size.height = max(frame.height, window.minSize.height)

        guard let visibleFrame = bestVisibleFrame(for: frame, window: window) else {
            window.setFrame(frame, display: true, animate: false)
            return
        }

        if frame.width <= visibleFrame.width {
            frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
        } else {
            frame.origin.x = visibleFrame.minX
        }

        if frame.height <= visibleFrame.height {
            frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        } else {
            frame.origin.y = visibleFrame.maxY - frame.height
        }
        window.setFrame(frame, display: true, animate: false)
    }

    private func bestVisibleFrame(for frame: NSRect, window: NSWindow) -> NSRect? {
        let intersectingScreen = NSScreen.screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(frame).area < rhs.visibleFrame.intersection(frame).area
        }
        if let intersectingScreen, intersectingScreen.visibleFrame.intersects(frame) {
            return intersectingScreen.visibleFrame
        }

        return window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    }

    private func prepareAndWriteExport(
        projectMixSnapshots: [ProjectMixTrackSnapshot],
        fallbackDecodedAudioBuffer: DecodedAudioBuffer?,
        to destinationURL: URL
    ) {
        updateStatus("preparing export")
        Task { [weak self, projectMixSnapshots, fallbackDecodedAudioBuffer, destinationURL] in
            let result = await Task.detached(priority: .userInitiated) {
                if !projectMixSnapshots.isEmpty {
                    return try Self.makeProjectMix(
                        from: projectMixSnapshots,
                        outputURL: destinationURL
                    )?.buffer
                }

                return fallbackDecodedAudioBuffer
            }.result

            guard let self else {
                return
            }

            switch result {
            case let .success(buffer):
                guard let buffer, buffer.frameCount > 0 else {
                    self.updateStatus("export failed: no audio to write")
                    return
                }

                self.writeExport(buffer, to: destinationURL)
            case let .failure(error):
                self.updateStatus("export failed: \(error.localizedDescription)")
            }
        }
    }

    private func prepareAndWriteWAVExport(
        projectMixSnapshots: [ProjectMixTrackSnapshot],
        fallbackDecodedAudioBuffer: DecodedAudioBuffer?,
        to destinationURL: URL,
        selection: TimelineSelection?
    ) {
        updateStatus(selection == nil ? "preparing WAV export" : "preparing region export")
        Task { [weak self, projectMixSnapshots, fallbackDecodedAudioBuffer, destinationURL, selection] in
            let result: Result<DecodedAudioBuffer?, Error> = await Task.detached(priority: .userInitiated) {
                let fullBuffer: DecodedAudioBuffer?
                if !projectMixSnapshots.isEmpty {
                    fullBuffer = try Self.makeProjectMix(
                        from: projectMixSnapshots,
                        outputURL: destinationURL
                    )?.buffer
                } else {
                    fullBuffer = fallbackDecodedAudioBuffer
                }

                guard let fullBuffer else {
                    return nil
                }

                if let selection {
                    return Self.croppedBuffer(fullBuffer, to: selection)
                }
                return fullBuffer
            }.result

            guard let self else {
                return
            }

            switch result {
            case let .success(buffer):
                guard let buffer, buffer.frameCount > 0 else {
                    self.updateStatus("export failed: no audio to write")
                    return
                }

                self.writeWAVBuffer(
                    buffer,
                    to: destinationURL,
                    completionStatusPrefix: selection == nil ? "exported WAV" : "exported selection"
                )
            case let .failure(error):
                self.updateStatus("export failed: \(error.localizedDescription)")
            }
        }
    }

    private func writeExport(_ decodedAudioBuffer: DecodedAudioBuffer, to destinationURL: URL) {
        updateStatus("exporting...")
        exportProgressOverlay.showExporting()
        let exportProgressOverlay = exportProgressOverlay

        Task { [weak self, decodedAudioBuffer, destinationURL] in
            do {
                let (exportURL, analysis) = try await Task.detached(priority: .userInitiated) {
                    let masteredExport = try PodcastExportProcessor.masteredForPodcast(decodedAudioBuffer)
                    Task { @MainActor in
                        exportProgressOverlay.updateProgress(0.2)
                    }

                    let exportURL = Self.normalizedAudioExportURL(destinationURL)
                    if CompressedAudioFileWriter.canWrite(to: exportURL) {
                        try CompressedAudioFileWriter.write(masteredExport.buffer, to: exportURL)
                        Task { @MainActor in
                            exportProgressOverlay.updateProgress(1)
                        }
                    } else {
                        try WAVFileWriter.write(masteredExport.buffer, to: exportURL) { progress in
                            Task { @MainActor in
                                exportProgressOverlay.updateProgress(0.2 + progress * 0.8)
                            }
                        }
                    }

                    return (exportURL, masteredExport.analysis)
                }.value

                guard let self else {
                    return
                }

                self.exportProgressOverlay.showComplete()
                self.updateStatus(
                    String(
                        format: "exported %@ (%.1f LUFS, %.1f dBTP)",
                        exportURL.lastPathComponent,
                        analysis.outputIntegratedLUFS,
                        analysis.outputTruePeakDBTP
                    )
                )
            } catch {
                guard let self else {
                    return
                }

                self.exportProgressOverlay.showFailure("Export failed.")
                self.updateStatus("export failed: \(error.localizedDescription)")
            }
        }
    }

    private func writeWAVBuffer(
        _ decodedAudioBuffer: DecodedAudioBuffer,
        to destinationURL: URL,
        completionStatusPrefix: String
    ) {
        updateStatus("exporting WAV...")
        exportProgressOverlay.showExporting()
        let exportProgressOverlay = exportProgressOverlay

        Task { [weak self, decodedAudioBuffer, destinationURL, completionStatusPrefix] in
            do {
                let exportURL = try await Task.detached(priority: .userInitiated) {
                    let exportURL = Self.normalizedWAVExportURL(destinationURL)
                    try WAVFileWriter.write(decodedAudioBuffer, to: exportURL) { progress in
                        Task { @MainActor in
                            exportProgressOverlay.updateProgress(progress)
                        }
                    }
                    return exportURL
                }.value

                guard let self else {
                    return
                }

                self.exportProgressOverlay.showComplete()
                self.updateStatus("\(completionStatusPrefix) \(exportURL.lastPathComponent)")
            } catch {
                guard let self else {
                    return
                }

                self.exportProgressOverlay.showFailure("Export failed.")
                self.updateStatus("export failed: \(error.localizedDescription)")
            }
        }
    }

    private func writeStemExports(
        stemSnapshots: [ProjectMixTrackSnapshot],
        mixSnapshots: [ProjectMixTrackSnapshot],
        to folderURL: URL,
        includeMixdown: Bool
    ) {
        updateStatus(includeMixdown ? "exporting mixdown and stems..." : "exporting stems...")
        exportProgressOverlay.showExporting()
        let exportProgressOverlay = exportProgressOverlay
        let projectName = suggestedProjectFilename()

        Task { [weak self, stemSnapshots, mixSnapshots, folderURL, includeMixdown, projectName] in
            do {
                let writtenURLs = try await Task.detached(priority: .userInitiated) {
                    var usedNames = Set<String>()
                    var writtenURLs: [URL] = []
                    let totalWriteCount = stemSnapshots.count + ((includeMixdown && !mixSnapshots.isEmpty) ? 1 : 0)
                    var completedWriteCount = 0

                    if includeMixdown, !mixSnapshots.isEmpty,
                       let mixBuffer = try Self.makeProjectMix(
                        from: mixSnapshots,
                        outputURL: folderURL.appendingPathComponent("\(projectName)-mixdown.wav")
                       )?.buffer
                    {
                        let mixURL = Self.uniqueWAVURL(
                            in: folderURL,
                            baseName: "\(projectName)-mixdown",
                            usedNames: &usedNames
                        )
                        try WAVFileWriter.write(mixBuffer, to: mixURL)
                        writtenURLs.append(mixURL)
                        completedWriteCount += 1
                        let progressValue = Double(completedWriteCount) / Double(max(totalWriteCount, 1))
                        Task { @MainActor in
                            exportProgressOverlay.updateProgress(progressValue)
                        }
                    }

                    for stemSnapshot in stemSnapshots {
                        let decodedBuffer = try Self.decodedMixBuffer(for: stemSnapshot)
                        let stemBuffer = Self.bufferByApplyingVolume(
                            stemSnapshot.volume,
                            to: decodedBuffer,
                            outputURL: folderURL
                        )
                        let stemURL = Self.uniqueWAVURL(
                            in: folderURL,
                            baseName: "\(projectName)-\(stemSnapshot.name)-stem",
                            usedNames: &usedNames
                        )
                        try WAVFileWriter.write(stemBuffer, to: stemURL)
                        writtenURLs.append(stemURL)
                        completedWriteCount += 1
                        let progressValue = Double(completedWriteCount) / Double(max(totalWriteCount, 1))
                        Task { @MainActor in
                            exportProgressOverlay.updateProgress(progressValue)
                        }
                    }

                    return writtenURLs
                }.value

                guard let self else {
                    return
                }

                self.exportProgressOverlay.showComplete()
                self.updateStatus("exported \(writtenURLs.count) file\(writtenURLs.count == 1 ? "" : "s")")
            } catch {
                guard let self else {
                    return
                }

                self.exportProgressOverlay.showFailure("Export failed.")
                self.updateStatus("export failed: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func normalizedAudioExportURL(_ destinationURL: URL) -> URL {
        destinationURL.pathExtension.isEmpty ? destinationURL.appendingPathExtension("wav") : destinationURL
    }

    private nonisolated static func normalizedWAVExportURL(_ destinationURL: URL) -> URL {
        destinationURL.pathExtension.lowercased() == "wav" ?
            destinationURL :
            destinationURL.deletingPathExtension().appendingPathExtension("wav")
    }

    private nonisolated static func croppedBuffer(
        _ buffer: DecodedAudioBuffer,
        to selection: TimelineSelection
    ) -> DecodedAudioBuffer? {
        guard
            buffer.frameCount > 0,
            selection.durationProgress > 0
        else {
            return nil
        }

        let startFrame = min(
            max(Int((selection.startProgress * Double(buffer.frameCount)).rounded(.down)), 0),
            buffer.frameCount
        )
        let endFrame = min(
            max(Int((selection.endProgress * Double(buffer.frameCount)).rounded(.up)), startFrame),
            buffer.frameCount
        )
        guard startFrame < endFrame else {
            return nil
        }

        let samplesByChannel = buffer.samplesByChannel.map { samples in
            let channelEndFrame = min(endFrame, samples.count)
            let channelStartFrame = min(startFrame, channelEndFrame)
            return Array(samples[channelStartFrame..<channelEndFrame])
        }
        return DecodedAudioBuffer(
            url: buffer.url,
            sampleRate: buffer.sampleRate,
            channelCount: buffer.channelCount,
            frameCount: endFrame - startFrame,
            samplesByChannel: samplesByChannel
        )
    }

    private nonisolated static func bufferByApplyingVolume(
        _ volume: Float,
        to buffer: DecodedAudioBuffer,
        outputURL: URL
    ) -> DecodedAudioBuffer {
        let gain = volume * volume
        guard abs(gain - 1) > Float.ulpOfOne else {
            return DecodedAudioBuffer(
                url: outputURL,
                sampleRate: buffer.sampleRate,
                channelCount: buffer.channelCount,
                frameCount: buffer.frameCount,
                samplesByChannel: buffer.samplesByChannel
            )
        }

        let samplesByChannel = buffer.samplesByChannel.map { samples in
            samples.map { min(max($0 * gain, -1), 1) }
        }
        return DecodedAudioBuffer(
            url: outputURL,
            sampleRate: buffer.sampleRate,
            channelCount: buffer.channelCount,
            frameCount: buffer.frameCount,
            samplesByChannel: samplesByChannel
        )
    }

    private nonisolated static func uniqueWAVURL(
        in folderURL: URL,
        baseName: String,
        usedNames: inout Set<String>
    ) -> URL {
        let sanitizedBaseName = sanitizedFilenameComponent(baseName)
        var suffix = 0
        while true {
            let name = suffix == 0 ? sanitizedBaseName : "\(sanitizedBaseName)-\(suffix + 1)"
            let filename = "\(name).wav"
            if !usedNames.contains(filename) {
                usedNames.insert(filename)
                return folderURL.appendingPathComponent(filename)
            }
            suffix += 1
        }
    }

    private nonisolated static func sanitizedFilenameComponent(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let components = value.components(separatedBy: invalidCharacters)
        let sanitized = components.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Soundtime" : sanitized
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()

        let timer = Timer(timeInterval: 1 / playbackRefreshRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPlaybackProgress(syncPlayheadWhenPlaying: false)
            }
        }
        timer.tolerance = 1 / playbackRefreshRate * 0.2

        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func startLoudnessMeterTimer() {
        loudnessMeterTimer?.invalidate()

        let timer = Timer(timeInterval: 1 / loudnessMeterRefreshRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateLoudnessMeter()
            }
        }
        timer.tolerance = 1 / loudnessMeterRefreshRate * 0.25

        loudnessMeterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startPerformanceMeterTimer() {
        performanceMeterTimer?.invalidate()

        let timer = Timer(timeInterval: 1 / performanceMeterRefreshRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePerformanceMeters()
            }
        }
        timer.tolerance = 1 / performanceMeterRefreshRate * 0.25

        performanceMeterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updatePerformanceMeters()
    }

    private func updatePerformanceMeters() {
        let timestamp = CACurrentMediaTime()
        PerformanceSampler.shared.recordMainThreadHeartbeat(
            at: timestamp,
            isApplicationActive: NSApp.isActive,
            expectedInterval: 1 / performanceMeterRefreshRate
        )
        let snapshot = PerformanceSampler.shared.sampleAndSnapshot(at: timestamp)
        frameRateHistoryView.display(performanceSnapshot: snapshot)
        cpuUsageHistoryView.display(cpuPercent: snapshot.cpuPercent)
        updatePerformanceMeterLabel(snapshot: snapshot)
        PerformanceDashboardWindowController.displayIfVisible(performanceSnapshot: snapshot)
    }

    private func updatePerformanceMeterLabel(snapshot: PerformanceMetricsSnapshot) {
        let frameRateText = performanceFrameRateText(for: snapshot)
        guard debugToolsVisible, let frameStats = latestTimelineFrameStats else {
            framesPerSecondLabel.stringValue = frameRateText
            return
        }

        let shaderBufferMegabytes = Int((Double(frameStats.shaderBufferByteCount) / 1_048_576).rounded())
        framesPerSecondLabel.stringValue = String(
            format: "%@ %@ c%d g%d fx%d/%d p%d d%d k%d b%d/%dMB u%d/%d m%d +/-%.1f max %.1f",
            frameRateText,
            frameStats.waveformRenderer,
            frameStats.cpuWaveformVertexCount,
            frameStats.gpuWaveformDrawCount,
            frameStats.effectVertexCount,
            frameStats.effectDroppedVertexCount,
            frameStats.transientParticleCount,
            frameStats.deletionEffectCount,
            frameStats.playheadContactEventCount,
            frameStats.shaderBufferCount,
            shaderBufferMegabytes,
            frameStats.shaderBufferUploadCount,
            frameStats.shaderBufferUploadInFlightCount,
            frameStats.waveformMipCacheCount,
            frameStats.frameTimeJitterMilliseconds,
            frameStats.worstFrameTimeMilliseconds
        )
    }

    private func performanceFrameRateText(for snapshot: PerformanceMetricsSnapshot) -> String {
        String(format: "%d fps", Int(snapshot.timelineGraphFramesPerSecond.rounded()))
    }

    private func updateLoudnessMeter() {
        let levels = currentLoudnessMeterLevels()
        loudnessMeter.display(levels: levels)
        transportControlPanel.displayOutputActivity(levels: levels)
    }

    private func currentLoudnessMeterLevels() -> LoudnessMeterLevels {
        if let latestMeterSample = playbackController.drainMeterSamples().last {
            return LoudnessMeterLevels(
                leftRMS: latestMeterSample.leftRMS,
                rightRMS: latestMeterSample.rightRMS,
                leftPeak: latestMeterSample.leftPeak,
                rightPeak: latestMeterSample.rightPeak
            )
        }

        let snapshot = playbackController.snapshot()
        guard snapshot.isPlaying, displayedDuration > 0 else {
            return .silence
        }

        let playheadProgress = projectedVisualPlayheadProgress(
            at: CACurrentMediaTime(),
            duration: displayedDuration
        )
        let playheadTime = min(max(TimeInterval(playheadProgress) * displayedDuration, 0), displayedDuration)
        return mixedLoudnessLevels(endingAt: playheadTime)
    }

    private func mixedLoudnessLevels(endingAt playheadTime: TimeInterval) -> LoudnessMeterLevels {
        guard !projectTracks.isEmpty else {
            return .silence
        }

        let outputSampleRate = max(displayedSampleRate, 44_100)
        let windowFrameCount = min(
            max(Int(outputSampleRate * 0.025), 192),
            fallbackLoudnessMaximumFrameCount
        )
        let windowDuration = Double(windowFrameCount - 1) / outputSampleRate
        let startTime = max(playheadTime - windowDuration, 0)
        let anySoloedTrack = projectTracks.contains { $0.isSoloed }
        let masterGain = volumeControl.perceptualVolume * volumeControl.perceptualVolume
        let audibleTracks = Array(projectTracks.lazy.filter { track in
            self.isProjectTrackAudible(track, anySoloedTrack: anySoloedTrack) &&
                track.volume > 0
        }.prefix(fallbackLoudnessMaximumAudibleTracks))
        guard !audibleTracks.isEmpty else {
            return .silence
        }

        var leftSquareSum: Double = 0
        var rightSquareSum: Double = 0
        var leftPeak: Float = 0
        var rightPeak: Float = 0
        var measuredFrameCount = 0

        for outputFrame in 0..<windowFrameCount {
            let sampleTime = startTime + Double(outputFrame) / outputSampleRate
            var leftSample: Float = 0
            var rightSample: Float = 0

            for track in audibleTracks {
                let trackGain = masterGain * track.volume * track.volume
                let trackSamples = loudnessSamples(
                    for: track,
                    at: sampleTime,
                    outputFrameIndex: outputFrame
                )
                leftSample += trackSamples.left * trackGain
                rightSample += trackSamples.right * trackGain
            }

            leftSquareSum += Double(leftSample) * Double(leftSample)
            rightSquareSum += Double(rightSample) * Double(rightSample)
            leftPeak = max(leftPeak, abs(leftSample))
            rightPeak = max(rightPeak, abs(rightSample))
            measuredFrameCount += 1
        }

        guard measuredFrameCount > 0 else {
            return .silence
        }

        return LoudnessMeterLevels(
            leftRMS: Float(sqrt(leftSquareSum / Double(measuredFrameCount))),
            rightRMS: Float(sqrt(rightSquareSum / Double(measuredFrameCount))),
            leftPeak: leftPeak,
            rightPeak: rightPeak
        )
    }

    private func loudnessSamples(
        for track: ProjectTrack,
        at sampleTime: TimeInterval,
        outputFrameIndex: Int
    ) -> (left: Float, right: Float) {
        if let decodedAudioBuffer = track.decodedAudioBuffer {
            guard
                sampleTime >= 0,
                sampleTime < decodedAudioBuffer.duration,
                decodedAudioBuffer.frameCount > 0
            else {
                return (0, 0)
            }

            let sourceFrame = min(
                max(Int((sampleTime * decodedAudioBuffer.sampleRate).rounded(.down)), 0),
                decodedAudioBuffer.frameCount - 1
            )
            let leftSample = loudnessSample(from: decodedAudioBuffer, channel: 0, frame: sourceFrame)
            let rightSample = decodedAudioBuffer.channelCount > 1 ?
                loudnessSample(from: decodedAudioBuffer, channel: 1, frame: sourceFrame) :
                leftSample
            return (leftSample, rightSample)
        }

        guard
            let overview = track.waveformOverview,
            overview.duration > 0,
            !overview.bins.isEmpty,
            sampleTime >= 0,
            sampleTime < overview.duration
        else {
            return (0, 0)
        }

        let progress = min(max(sampleTime / overview.duration, 0), 0.999_999)
        let binIndex = min(max(Int(progress * Double(overview.bins.count)), 0), overview.bins.count - 1)
        let bin = overview.bins[binIndex]
        let polarity: Float = outputFrameIndex.isMultiple(of: 2) ? 1 : -1
        let monoSample = max(bin.rmsSample, bin.peakMagnitude * 0.55) * polarity
        return (monoSample, monoSample)
    }

    private func loudnessSample(
        from decodedAudioBuffer: DecodedAudioBuffer,
        channel requestedChannel: Int,
        frame requestedFrame: Int
    ) -> Float {
        guard !decodedAudioBuffer.samplesByChannel.isEmpty else {
            return 0
        }

        let channel = min(max(requestedChannel, 0), decodedAudioBuffer.samplesByChannel.count - 1)
        let samples = decodedAudioBuffer.samplesByChannel[channel]
        guard !samples.isEmpty else {
            return 0
        }

        let frame = min(max(requestedFrame, 0), samples.count - 1)
        return samples[frame]
    }

    private func displayPlaybackVisuals(
        progress: Float,
        isPlaying: Bool,
        syncPlayhead: Bool = true,
        anchorTimestamp: TimeInterval? = nil,
        restartsFisheyeActivation: Bool = false,
        restartsPlayheadKick: Bool = false,
        synchronizesRenderer: Bool = true
    ) {
        let timestamp = anchorTimestamp ?? CACurrentMediaTime()
        let clampedProgress = min(max(progress, 0), 1)

        guard isPlaying, !syncPlayhead, visualPlaybackActive else {
            hardSyncPlaybackVisuals(
                progress: clampedProgress,
                isPlaying: isPlaying,
                anchorTimestamp: timestamp,
                restartsFisheyeActivation: restartsFisheyeActivation,
                restartsPlayheadKick: restartsPlayheadKick,
                synchronizesRenderer: synchronizesRenderer
            )
            return
        }

        gentlySyncPlaybackVisuals(
            progress: clampedProgress,
            anchorTimestamp: timestamp
        )
        displayPlaybackActiveIfNeeded(isPlaying, forceTimelineUpdate: true)
    }

    private func hardSyncPlaybackVisuals(
        progress: Float,
        isPlaying: Bool,
        anchorTimestamp: TimeInterval,
        restartsFisheyeActivation: Bool = false,
        restartsPlayheadKick: Bool = false,
        synchronizesRenderer: Bool = true
    ) {
        let wasVisuallyPlaying = visualPlaybackActive
        visualPlayheadProgress = min(max(progress, 0), 1)
        visualPlayheadAnchorTimestamp = anchorTimestamp
        visualPlaybackActive = isPlaying
        lastVisualAudioCorrectionTimestamp = anchorTimestamp

        timelineSurface.displayPlayheadProgress(
            visualPlayheadProgress,
            syncRenderer: synchronizesRenderer,
            anchorTimestamp: anchorTimestamp,
            resetsTouchStart: isPlaying || !wasVisuallyPlaying,
            restartsFisheyeActivation: restartsFisheyeActivation,
            restartsPlayheadKick: restartsPlayheadKick
        )
        updateTranscriptActiveWord(progress: visualPlayheadProgress)
        displayPlaybackActiveIfNeeded(isPlaying)
    }

    private func gentlySyncPlaybackVisuals(
        progress audioProgress: Float,
        anchorTimestamp audioTimestamp: TimeInterval
    ) {
        guard displayedDuration > 0 else {
            hardSyncPlaybackVisuals(
                progress: audioProgress,
                isPlaying: true,
                anchorTimestamp: audioTimestamp
            )
            return
        }

        let projectedProgress = projectedVisualPlayheadProgress(
            at: audioTimestamp,
            duration: displayedDuration
        )
        let correctionProgress = audioProgress - projectedProgress
        let correctionSeconds = TimeInterval(correctionProgress) * displayedDuration
        let absoluteCorrectionSeconds = abs(correctionSeconds)

        guard absoluteCorrectionSeconds > visualAudioSyncDeadband else {
            return
        }

        guard absoluteCorrectionSeconds < visualAudioSyncHardCorrectionThreshold else {
            hardSyncPlaybackVisuals(
                progress: audioProgress,
                isPlaying: true,
                anchorTimestamp: audioTimestamp
            )
            return
        }

        guard audioTimestamp - lastVisualAudioCorrectionTimestamp >= visualAudioSyncMinimumCorrectionInterval else {
            return
        }

        let correctionWeight = min(
            max(absoluteCorrectionSeconds / visualAudioSyncResponseDuration, 0.06),
            0.28
        )
        let correctedProgress = projectedProgress + correctionProgress * Float(correctionWeight)
        visualPlayheadProgress = min(max(correctedProgress, 0), 1)
        visualPlayheadAnchorTimestamp = audioTimestamp
        visualPlaybackActive = true
        lastVisualAudioCorrectionTimestamp = audioTimestamp

        timelineSurface.displayPlayheadProgress(
            visualPlayheadProgress,
            syncRenderer: false,
            anchorTimestamp: audioTimestamp
        )
        updateTranscriptActiveWord(progress: visualPlayheadProgress)
    }

    private func projectedVisualPlayheadProgress(
        at timestamp: TimeInterval,
        duration: TimeInterval
    ) -> Float {
        loopConstrainedVisualProgress(
            projectedUnconstrainedVisualPlayheadProgress(
                at: timestamp,
                duration: duration
            )
        )
    }

    private func projectedUnconstrainedVisualPlayheadProgress(
        at timestamp: TimeInterval,
        duration: TimeInterval
    ) -> Float {
        guard visualPlaybackActive, duration.isFinite, duration > 0 else {
            return visualPlayheadProgress
        }

        let elapsedTime = timestamp - visualPlayheadAnchorTimestamp
        return min(
            max(visualPlayheadProgress + Float(elapsedTime / duration), 0),
            1
        )
    }

    private func loopConstrainedVisualProgress(_ progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        guard timelineLoopIsEnabled, !isTimelineLoopPlaybackBypassed else {
            return clampedProgress
        }

        let start = timelineLoopRange.startProgress
        let end = timelineLoopRange.endProgress
        let duration = end - start
        guard duration > 0.0001, duration < 0.999, end > start else {
            return clampedProgress
        }

        guard clampedProgress > end else {
            return clampedProgress
        }

        // The audio engine owns the actual loop seek. If the visual projection
        // wraps independently first, the TimelineView can page the viewport to
        // the loop start while the renderer/audio snapshot is still at the loop
        // end, which makes waveform layers appear to jump between time regions.
        return end
    }

    private func activeTimelineLoopStartProgress() -> Float? {
        guard
            timelineLoopIsEnabled,
            timelineLoopRange.durationProgress > 0.0001,
            timelineLoopRange.durationProgress < 0.999,
            timelineLoopRange.endProgress > timelineLoopRange.startProgress
        else {
            return nil
        }

        return timelineLoopRange.startProgress
    }

    private func updateTimelineLoopPlaybackBypassForExplicitSeek(
        to progress: Float,
        whilePlaying: Bool
    ) {
        setTimelineLoopPlaybackBypassed(
            TimelineLoopPlaybackPolicy.bypassesLoopForExplicitSeek(
                to: progress,
                whilePlaying: whilePlaying,
                loopRange: timelineLoopRange,
                isLoopEnabled: timelineLoopIsEnabled
            )
        )
    }

    private func setTimelineLoopPlaybackBypassed(_ isBypassed: Bool) {
        guard isTimelineLoopPlaybackBypassed != isBypassed else {
            return
        }

        isTimelineLoopPlaybackBypassed = isBypassed
        timelineSurface.displayLoopPlaybackBypassed(isBypassed)
    }

    private func displayPlaybackActiveIfNeeded(_ isPlaying: Bool, forceTimelineUpdate: Bool = false) {
        visualPlaybackActive = isPlaying
        ImportWorkBudget.shared.setPlaybackActive(isPlaying)
        updateTransportControlState(isPlaying: isPlaying)
        guard forceTimelineUpdate || displayedPlaybackActive != isPlaying else {
            return
        }

        displayedPlaybackActive = isPlaying
        timelineSurface.displayPlaybackActive(isPlaying)
    }

    private func refreshPlaybackProgress(
        syncPlayheadWhenPlaying: Bool = false,
        restartsFisheyeActivation: Bool = false,
        restartsPlayheadKick: Bool = false
    ) {
        var snapshot = playbackController.snapshot()
        var didLoopPlayback = false
        snapshot = applyTimelineLoopIfNeeded(to: snapshot, didLoop: &didLoopPlayback)
        currentPlayheadFrame = snapshot.frameIndex
        updateEffectCommandState()
        displayPlaybackVisuals(
            progress: snapshot.progress,
            isPlaying: snapshot.isPlaying,
            syncPlayhead: !snapshot.isPlaying || syncPlayheadWhenPlaying || didLoopPlayback,
            anchorTimestamp: snapshot.hostTimestamp,
            restartsFisheyeActivation: restartsFisheyeActivation || didLoopPlayback,
            restartsPlayheadKick: restartsPlayheadKick || didLoopPlayback
        )
        updateTimeReadout()

        if !snapshot.isPlaying {
            previousLoopPlaybackProgress = nil
            setTimelineLoopPlaybackBypassed(false)
            stopPlaybackTimer()
            if snapshot.isAtEnd {
                updateStatus("finished")
            }
        }
    }

    private func applyTimelineLoopIfNeeded(
        to snapshot: PlaybackSnapshot,
        didLoop: inout Bool
    ) -> PlaybackSnapshot {
        guard
            snapshot.isPlaying,
            TimelineLoopPlaybackPolicy.shouldWrapPlayback(
                at: snapshot.progress,
                loopRange: timelineLoopRange,
                isLoopEnabled: timelineLoopIsEnabled,
                isBypassed: isTimelineLoopPlaybackBypassed
            )
        else {
            return snapshot
        }

        let start = timelineLoopRange.startProgress
        let end = timelineLoopRange.endProgress
        let currentProgress = snapshot.progress
        guard end > start else {
            previousLoopPlaybackProgress = currentProgress
            return snapshot
        }

        guard currentProgress >= end else {
            previousLoopPlaybackProgress = currentProgress
            return snapshot
        }

        do {
            try playbackController.seekExactly(toProgress: start)
            previousLoopPlaybackProgress = start
            didLoop = true
            timelineSurface.triggerLoopRangeFlash()
            return playbackController.snapshot()
        } catch {
            updateStatus("loop seek failed: \(error.localizedDescription)")
            return snapshot
        }
    }

    private func updateSelection(_ selection: TimelineSelection?) {
        if !deadAirCandidates.isEmpty {
            clearDeadAirReview(publish: true)
        }
        if selectedTrackID != nil || !selectedTrackIDs.isEmpty {
            selectedTrackID = nil
            selectedTrackIDs.removeAll()
            trackSelectionAnchorID = nil
            publishSelectedTracksToTimeline()
            refreshTrackControls()
        }
        if let trackID = selection?.trackID {
            activeTrackID = trackID
            syncActiveTrackFields()
        }
        selectedTimelineRange = selection
        mirrorTimelineSelectionToTranscript(selection)
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        updateEffectCommandState()
        updateStatus(currentPlaybackStatus)
    }

    private func mirrorTimelineSelectionToTranscript(_ selection: TimelineSelection?) {
        guard let transcriptSelection = transcriptSelection(overlapping: selection) else {
            selectedTranscriptSelection = nil
            timelineSurface.displayTranscriptSelection(nil)
            timelineSurface.displayTranscriptMirroredTimelineSelection(selection)
            return
        }

        selectedTranscriptSelection = transcriptSelection
        timelineSurface.displayTranscriptSelection(transcriptSelection)
    }

    private func transcriptSelection(overlapping selection: TimelineSelection?) -> TranscriptTokenSelection? {
        guard
            let selection,
            selection.durationProgress > 0,
            let trackID = selection.trackID,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == trackID }),
            let transcript = projectTracks[trackIndex].transcript
        else {
            return nil
        }

        let timelineDuration = projectSelectionDuration
        guard timelineDuration > 0 else {
            return nil
        }

        let projectRange = TranscriptionTimeRange(
            startTime: selection.startProgress * timelineDuration,
            endTime: selection.endProgress * timelineDuration
        )
        let timeMap = transcriptSourceTimeMap(
            for: projectTracks[trackIndex],
            timelineDuration: trackDuration(for: projectTracks[trackIndex])
        )
        guard let sourceRange = timeMap.sourceRangeCoveringProjectRange(projectRange.startTime..<projectRange.endTime) else {
            return nil
        }

        let wordIDs = transcript.words(overlapping: sourceRange)
            .map(\.id)
        guard !wordIDs.isEmpty else {
            return nil
        }
        return TranscriptEditPlanner.selection(
            forWords: Set(wordIDs),
            in: transcript,
            trackID: trackID,
            timeMap: timeMap
        )
    }

    private func updateFrameStats(_ frameStats: TimelineFrameStats) {
        latestTimelineFrameStats = frameStats
        SoundtimeDiagnostics.shared.recordFrameStats(frameStats)
        PerformanceDashboardWindowController.displayIfVisible(frameStats: frameStats)
    }

    private var isDenoiseProcessingActive: Bool {
        activeDenoiseRequestID != nil
    }

    private var canPerformTimelineEditCommand: Bool {
        !isDenoiseProcessingActive
    }

    private var canApplyGainEffect: Bool {
        guard canPerformTimelineEditCommand else {
            return false
        }

        guard
            let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            return false
        }

        let track = projectTracks[target.trackIndex]
        return hasEditableTimelineState(track) && target.editSelection.durationProgress > 0
    }

    private var canApplyFadeEffect: Bool {
        guard canPerformTimelineEditCommand else {
            return false
        }

        guard
            let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            return false
        }

        let track = projectTracks[target.trackIndex]
        return hasEditableTimelineState(track) && target.editSelection.durationProgress > 0
    }

    private var canApplyDenoiseEffect: Bool {
        guard canPerformTimelineEditCommand else {
            return false
        }

        guard
            let target = currentEditableSelectionTarget() ?? editableClipAtPlayheadTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            return false
        }

        let track = projectTracks[target.trackIndex]
        return hasEditableTimelineState(track) && target.editSelection.durationProgress > 0
    }

    private var canApplyStemSeparationEffect: Bool {
        canApplyDenoiseEffect
    }

    private var canTranscribeSelectedTrack: Bool {
        guard activeTranscriptionJob == nil else {
            return false
        }

        guard canPerformTimelineEditCommand else {
            return false
        }

        guard let trackIndex = transcriptionTargetTrackIndex() else {
            return false
        }

        return trackDuration(for: projectTracks[trackIndex]) > 0
    }

    private var canSplitAtPlayhead: Bool {
        guard canPerformTimelineEditCommand else {
            return false
        }

        guard
            let trackIndex = activeProjectTrackIndex(),
            projectTracks.indices.contains(trackIndex)
        else {
            return false
        }

        let projectProgress = playbackControllerStorage?.snapshot().progress ?? visualPlayheadProgress
        return scopedTrackIndices(anchorTrackIndex: trackIndex, scope: editScope).contains { scopedTrackIndex in
            canSplitTrack(at: scopedTrackIndex, projectProgress: projectProgress)
        }
    }

    private func canSplitTrack(at trackIndex: Int, projectProgress: Float) -> Bool {
        guard projectTracks.indices.contains(trackIndex) else {
            return false
        }

        let track = projectTracks[trackIndex]
        guard hasEditableTimelineState(track) else {
            return false
        }

        let insertionSelection = editInsertionSelection(
            forPlaybackProgress: projectProgress,
            trackIndex: trackIndex
        )
        return insertionSelection.startProgress > 0 && insertionSelection.startProgress < 1
    }

    private var canDeleteSilence: Bool {
        guard canPerformTimelineEditCommand else {
            return false
        }

        guard
            let target = silenceCleanupTarget(),
            projectTracks.indices.contains(target.trackIndex)
        else {
            return false
        }

        let track = projectTracks[target.trackIndex]
        return hasEditableTimelineState(track)
    }

    private var canDeleteSelection: Bool {
        guard canPerformTimelineEditCommand else {
            return false
        }

        if !selectedTrackIDs.isEmpty || selectedTrackID != nil {
            return true
        }

        guard let target = currentEditableSelectionTarget() else {
            return false
        }
        return plannedEditableTargetCount(for: target, scope: editScope) > 0
    }

    private var canClearSelection: Bool {
        guard canPerformTimelineEditCommand else {
            return false
        }

        return currentEditableSelectionTarget() != nil
    }

    private var canCopySelection: Bool {
        guard canPerformTimelineEditCommand else {
            return false
        }

        return currentEditableSelectionTarget() != nil
    }

    private var canCutSelection: Bool {
        guard canPerformTimelineEditCommand else {
            return false
        }

        return currentEditableSelectionTarget() != nil
    }

    private var canPasteAudio: Bool {
        guard canPerformTimelineEditCommand else {
            return false
        }

        return audioClipboard != nil && activeProjectTrackIndex() != nil
    }

    private func isEditableRippleDeleteTarget(_ target: EditableSelectionTarget) -> Bool {
        guard
            projectTracks.indices.contains(target.trackIndex),
            target.editSelection.durationProgress > 0
        else {
            return false
        }

        let track = projectTracks[target.trackIndex]
        return hasEditableTimelineState(track)
    }

    private func plannedEditableTargetCount(
        for target: EditableSelectionTarget,
        scope: EditScope
    ) -> Int {
        do {
            let command = try makeRangeEditCommand(
                kind: .rippleDelete,
                target: target,
                scope: scope
            )
            return try EditTransactionPlanner.plan(
                command: command,
                currentRevision: projectEditRevision(),
                tracks: editTrackDescriptors(for: command)
            ).trackEdits.count
        } catch {
            return 0
        }
    }

    private func updateEditScopeHint() {
        editScopeControl.selectedSegment = editScope.rawValue
        updateEditScopeVisibility(animated: true)

        guard
            let selectedTimelineRange,
            selectedTimelineRange.durationProgress > 0
        else {
            editScopeHintLabel.stringValue = ""
            return
        }

        if
            let selectedTrackID,
            isFullTrackSelection(selectedTimelineRange, trackID: selectedTrackID)
        {
            editScopeHintLabel.stringValue = "Backspace deletes track"
            return
        }

        guard let target = currentEditableSelectionTarget() else {
            editScopeHintLabel.stringValue = ""
            return
        }

        let affectedTrackCount = plannedEditableTargetCount(
            for: target,
            scope: editScope
        )
        guard affectedTrackCount > 0 else {
            editScopeHintLabel.stringValue = "No overlapping audio"
            return
        }

        switch editScope {
        case .track:
            editScopeHintLabel.stringValue = "Delete affects this track"
        case .selected:
            editScopeHintLabel.stringValue = affectedTrackCount == 1 ?
                "Delete affects selected track" :
                "Delete affects \(affectedTrackCount) selected tracks"
        case .group:
            editScopeHintLabel.stringValue = affectedTrackCount == 1 ?
                "Delete affects this group" :
                "Delete affects \(affectedTrackCount) grouped tracks"
        case .all:
            editScopeHintLabel.stringValue = affectedTrackCount == 1 ?
                "Delete affects 1 track" :
                "Delete affects \(affectedTrackCount) tracks"
        }
    }

    private func updateEffectCommandState() {
        timelineSurface.canApplyGainEffect = canApplyGainEffect
        timelineSurface.canApplyFadeEffect = canApplyFadeEffect
        timelineSurface.canApplyDenoiseEffect = canApplyDenoiseEffect
        timelineSurface.canApplyStemSeparationEffect = canApplyStemSeparationEffect
        timelineSurface.canTranscribeSelectedTrack = canTranscribeSelectedTrack
        timelineSurface.canReapplyLastEffect = canReapplyLastEffect
        timelineSurface.canSplitAtPlayhead = canSplitAtPlayhead
        timelineSurface.canCutSelection = canCutSelection
        timelineSurface.canCopySelection = canCopySelection
        timelineSurface.canPasteAudio = canPasteAudio
        timelineSurface.canDeleteSelection = canDeleteSelection
        timelineSurface.canClearSelection = canClearSelection
        timelineSurface.canDeleteSilence = canDeleteSilence
        timelineSurface.canUseDeadAirCandidate = canPerformTimelineEditCommand && activeDeadAirCandidate() != nil
        updateEditScopeHint()
    }

    private var canReapplyLastEffect: Bool {
        guard let lastEffect else {
            return false
        }

        switch lastEffect {
        case .gain, .normalize:
            return canApplyGainEffect
        case .denoise:
            return canApplyDenoiseEffect
        case .separateMusicStems:
            return canApplyStemSeparationEffect
        case .fade:
            return canApplyFadeEffect
        }
    }

    private func updateStatus(_ status: String) {
        currentPlaybackStatus = status
        guard let loadedAudioSummary else {
            metadataLabel.stringValue = status
            return
        }

        if
            let selectedTimelineRange,
            displayedDuration > 0,
            selectedTimelineRange.durationProgress > 0
        {
            let selectedDuration = selectedTimelineRange.duration(in: displayedDuration)
            metadataLabel.stringValue = "\(loadedAudioSummary) - \(status) - selected \(formatDuration(selectedDuration))"
        } else {
            metadataLabel.stringValue = "\(loadedAudioSummary) - \(status)"
        }

        updateTimeReadout()
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1_000)
        }

        if duration < 60 {
            return String(format: "%.2f sec", duration)
        }

        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func updateLoadedAudioSummary(for decodedAudioBuffer: DecodedAudioBuffer) {
        if let selectedAudioFile {
            loadedAudioSummary = "\(selectedAudioFile.displayName) - \(decodedAudioBuffer.formattedSummary)"
        } else {
            loadedAudioSummary = decodedAudioBuffer.formattedSummary
        }
    }

    private func suggestedExportFilename() -> String {
        let baseName = selectedAudioFile?.url.deletingPathExtension().lastPathComponent ?? "Soundtime Export"
        return "\(baseName)-edited.wav"
    }

    private func suggestedSelectedRegionExportFilename() -> String {
        let baseName = selectedAudioFile?.url.deletingPathExtension().lastPathComponent ?? "Soundtime Export"
        return "\(baseName)-selection.wav"
    }

    private func suggestedProjectFilename() -> String {
        if let currentProjectURL {
            return currentProjectURL.deletingPathExtension().lastPathComponent
        }

        if let firstTrack = projectTracks.first {
            return firstTrack.name
        }

        return "Untitled"
    }

    private func normalizedProjectURL(_ url: URL) -> URL {
        let projectExtension = SoundtimeProjectStore.fileExtension
        var normalizedURL = url

        while normalizedURL.pathExtension == projectExtension {
            normalizedURL.deletePathExtension()
        }

        return normalizedURL.appendingPathExtension(projectExtension)
    }

    private func applyTimeline(_ audioTimeline: AudioEditTimeline) {
        self.audioTimeline = audioTimeline
        selectedTimelineRange = nil
        timelineSurface.displayGainPreview(selection: nil, gain: 1)
        updateEffectCommandState()
        currentPlayheadFrame = 0
        timelineSurface.displaySelection(nil)
        displayPlaybackVisuals(progress: 0, isPlaying: false)

        if
            let activeTrackID,
            let trackIndex = projectTracks.firstIndex(where: { $0.id == activeTrackID })
        {
            projectTracks[trackIndex].editRevision += 1
            let editRevision = projectTracks[trackIndex].editRevision
            applyEditedTimelineState(
                trackIndex: trackIndex,
                editedAudioTimeline: audioTimeline,
                editedFileTimeline: nil,
                editedDuration: audioTimeline.duration
            )
            projectTracks[trackIndex].zeroCrossingIndex = nil

            decodedAudioBuffer = nil
            displayedFrameCount = audioTimeline.frameCount
            displayedSampleRate = audioTimeline.sourceAudioBuffer.sampleRate
            syncActiveTrackFields()
            refreshProjectTimelineDisplay()
            reloadPlaybackFromProjectTracks(preserveProgress: false)
            updateTimeReadout()

            materializeEditedTimeline(
                trackID: activeTrackID,
                timeline: audioTimeline,
                editRevision: editRevision,
                status: "track ready",
                startDelay: editMaterializationDelay
            )
        } else {
            decodedAudioBuffer = nil
            displayedFrameCount = audioTimeline.frameCount
            displayedSampleRate = audioTimeline.sourceAudioBuffer.sampleRate
            refreshProjectTimelineDisplay()
            updateTimeReadout()
        }
    }

    private func updateTimeReadout() {
        guard displayedFrameCount > 0, displayedSampleRate > 0 else {
            timeReadoutLabel.stringValue = "00:00.000 / 00:00.000"
            return
        }

        if let selectedTimelineRange, selectedTimelineRange.durationProgress > 0 {
            let selectionStart = TimeInterval(selectedTimelineRange.startProgress) * displayedDuration
            let selectionEnd = TimeInterval(selectedTimelineRange.endProgress) * displayedDuration
            timeReadoutLabel.stringValue = "sel \(formatClockTime(selectionStart))-\(formatClockTime(selectionEnd))"
            return
        }

        let playheadFrame: Int
        if visualPlaybackActive {
            let projectedProgress = projectedVisualPlayheadProgress(
                at: CACurrentMediaTime(),
                duration: displayedDuration
            )
            playheadFrame = Int((projectedProgress * Float(displayedFrameCount)).rounded(.down))
        } else {
            playheadFrame = currentPlayheadFrame
        }

        let playheadTime = Double(min(playheadFrame, displayedFrameCount)) / displayedSampleRate
        timeReadoutLabel.stringValue = "\(formatClockTime(playheadTime)) / \(formatClockTime(displayedDuration))"
    }

    private var displayedDuration: TimeInterval {
        guard displayedFrameCount > 0, displayedSampleRate > 0 else {
            return 0
        }

        return Double(displayedFrameCount) / displayedSampleRate
    }

    private func formatClockTime(_ duration: TimeInterval) -> String {
        let clampedDuration = max(duration, 0)
        let totalMilliseconds = Int((clampedDuration * 1_000).rounded(.down))
        let milliseconds = totalMilliseconds % 1_000
        let totalSeconds = totalMilliseconds / 1_000
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
        }

        return String(format: "%02d:%02d.%03d", minutes, seconds, milliseconds)
    }

    private func clampAudioSample(_ sample: Float) -> Float {
        min(max(sample, -1), 1)
    }

    private func smoothstep(_ progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        return clampedProgress * clampedProgress * (3 - 2 * clampedProgress)
    }
}

private final class TimelineTuningSliderView: NSView {
    var onValueChanged: ((Double) -> Void)?

    var value: Double {
        get {
            slider.doubleValue
        }
        set {
            slider.doubleValue = min(max(newValue, range.lowerBound), range.upperBound)
            updateValueLabel()
        }
    }

    private let titleLabel: NSTextField
    private let valueLabel: NSTextField
    private let slider = NSSlider()
    private let range: ClosedRange<Double>
    private let valueFormat: String

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    init(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        valueFormat: String
    ) {
        self.range = range
        self.valueFormat = valueFormat
        titleLabel = NSTextField(labelWithString: title)
        valueLabel = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        configure()
        self.value = value
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = NSColor(white: 0.72, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        valueLabel.textColor = NSColor(white: 0.88, alpha: 1)
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byClipping
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(slider)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -6),

            valueLabel.topAnchor.constraint(equalTo: topAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 42),

            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -2),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        updateValueLabel()
        onValueChanged?(sender.doubleValue)
    }

    private func updateValueLabel() {
        valueLabel.stringValue = String(format: valueFormat, slider.doubleValue)
    }
}

private extension CGRect {
    var area: CGFloat {
        max(width, 0) * max(height, 0)
    }
}
