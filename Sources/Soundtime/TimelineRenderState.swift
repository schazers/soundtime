import Foundation

struct TimelineRenderState: Sendable {
    struct ClipRange: Equatable, Sendable {
        let startProgress: Double
        let endProgress: Double

        init(startProgress: Double, endProgress: Double) {
            let clampedStart = min(max(startProgress, 0), 1)
            let clampedEnd = min(max(endProgress, 0), 1)
            self.startProgress = min(clampedStart, clampedEnd)
            self.endProgress = max(clampedStart, clampedEnd)
        }

        var durationProgress: Double {
            endProgress - startProgress
        }
    }

    struct Track: Sendable {
        let id: UUID
        let waveformVersion: Int
        let waveformOverview: WaveformOverview?
        let durationHint: TimeInterval?
        let hasWaveform: Bool
        let volume: Float
        let isMuted: Bool
        let isSoloed: Bool
        let clipRanges: [ClipRange]
        let waveformTileSource: WaveformTileBuildSource?

        init(
            id: UUID,
            waveformVersion: Int,
            waveformOverview: WaveformOverview?,
            durationHint: TimeInterval?,
            volume: Float,
            isMuted: Bool,
            isSoloed: Bool,
            hasWaveform: Bool? = nil,
            clipRanges: [ClipRange] = [],
            waveformTileSource: WaveformTileBuildSource? = nil
        ) {
            self.id = id
            self.waveformVersion = waveformVersion
            self.waveformOverview = waveformOverview
            self.durationHint = durationHint
            self.volume = volume
            self.isMuted = isMuted
            self.isSoloed = isSoloed
            self.hasWaveform = hasWaveform ?? (waveformOverview?.isEmpty == false)
            self.clipRanges = clipRanges.filter { $0.durationProgress > 0 }
            self.waveformTileSource = waveformTileSource
        }
    }

    struct GainPreview: Sendable {
        let selection: TimelineSelection
        let gain: Float
    }

    struct CandidateRegion: Sendable {
        let id: UUID
        let selection: TimelineSelection
        let isActive: Bool

        init(id: UUID, selection: TimelineSelection, isActive: Bool = false) {
            self.id = id
            self.selection = selection
            self.isActive = isActive
        }
    }

    struct ProcessingTrackHighlight: Sendable {
        let trackID: UUID
        let alpha: Float

        init(trackID: UUID, alpha: Float) {
            self.trackID = trackID
            self.alpha = min(max(alpha, 0), 1)
        }
    }

    static let empty = TimelineRenderState(
        tracks: [],
        viewport: .full,
        trackLayout: .default,
        playheadProgress: 0,
        playheadAnchorTimestamp: 0,
        isPlaybackActive: false,
        isRecordingActive: false,
        hoverProgress: nil,
        isHoverGuideArmed: false,
        selection: nil,
        selectedTrackID: nil,
        candidateRegions: [],
        processingTrackHighlight: nil,
        trimPreview: nil,
        gainPreview: nil
    )

    let tracks: [Track]
    let duration: TimeInterval?
    let hasWaveforms: Bool
    let hasSoloedTrack: Bool
    let viewport: TimelineViewport
    let trackLayout: TimelineTrackLayout
    let playheadProgress: Float
    let playheadAnchorTimestamp: CFTimeInterval
    let isPlaybackActive: Bool
    let isRecordingActive: Bool
    let hoverProgress: Float?
    let isHoverGuideArmed: Bool
    let selection: TimelineSelection?
    let selectedTrackID: UUID?
    let selectedTrackIDs: Set<UUID>
    let candidateRegions: [CandidateRegion]
    let processingTrackHighlight: ProcessingTrackHighlight?
    let trimPreview: TimelineTrimRange?
    let gainPreview: GainPreview?

    init(
        tracks: [Track],
        viewport: TimelineViewport,
        trackLayout: TimelineTrackLayout = .default,
        playheadProgress: Float,
        playheadAnchorTimestamp: CFTimeInterval,
        isPlaybackActive: Bool,
        isRecordingActive: Bool,
        hoverProgress: Float?,
        isHoverGuideArmed: Bool,
        selection: TimelineSelection?,
        selectedTrackID: UUID?,
        selectedTrackIDs: Set<UUID>? = nil,
        candidateRegions: [CandidateRegion] = [],
        processingTrackHighlight: ProcessingTrackHighlight? = nil,
        trimPreview: TimelineTrimRange?,
        gainPreview: GainPreview?,
        duration: TimeInterval? = nil,
        hasWaveforms: Bool? = nil,
        hasSoloedTrack: Bool? = nil
    ) {
        self.tracks = tracks
        self.duration = duration ?? Self.projectDuration(for: tracks)
        self.hasWaveforms = hasWaveforms ?? tracks.contains { $0.hasWaveform }
        self.hasSoloedTrack = hasSoloedTrack ?? tracks.contains { $0.isSoloed }
        self.viewport = viewport
        self.trackLayout = trackLayout
        self.playheadProgress = playheadProgress
        self.playheadAnchorTimestamp = playheadAnchorTimestamp
        self.isPlaybackActive = isPlaybackActive
        self.isRecordingActive = isRecordingActive
        self.hoverProgress = hoverProgress
        self.isHoverGuideArmed = isHoverGuideArmed
        self.selection = selection
        self.selectedTrackID = selectedTrackID
        self.selectedTrackIDs = selectedTrackIDs ?? selectedTrackID.map { [$0] } ?? []
        self.candidateRegions = candidateRegions
        self.processingTrackHighlight = processingTrackHighlight
        self.trimPreview = trimPreview
        self.gainPreview = gainPreview
    }

    var waveformOverview: WaveformOverview? {
        tracks.first?.waveformOverview
    }

    private static func projectDuration(for tracks: [Track]) -> TimeInterval? {
        let duration = tracks.reduce(TimeInterval(0)) { result, track in
            max(result, track.durationHint ?? track.waveformOverview?.duration ?? 0)
        }
        return duration > 0 ? duration : nil
    }

    func withWaveformOverview(_ waveformOverview: WaveformOverview?) -> TimelineRenderState {
        let tracks = waveformOverview.map {
            [Track(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
                waveformVersion: 0,
                waveformOverview: $0,
                durationHint: $0.duration,
                volume: 1,
                isMuted: false,
                isSoloed: false
            )]
        } ?? []
        return withTracks(tracks)
    }

    func withTracks(_ tracks: [Track]) -> TimelineRenderState {
        TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: nil
        )
    }

    func replacingTracks(_ tracks: [Track]) -> TimelineRenderState {
        TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: gainPreview
        )
    }

    func withTrackLayout(_ trackLayout: TimelineTrackLayout) -> TimelineRenderState {
        TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: gainPreview,
            duration: duration,
            hasWaveforms: hasWaveforms,
            hasSoloedTrack: hasSoloedTrack
        )
    }

    func withViewport(_ viewport: TimelineViewport) -> TimelineRenderState {
        TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: gainPreview,
            duration: duration,
            hasWaveforms: hasWaveforms,
            hasSoloedTrack: hasSoloedTrack
        )
    }

    func withPlayheadProgress(
        _ playheadProgress: Float,
        anchorTimestamp: CFTimeInterval? = nil
    ) -> TimelineRenderState {
        TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: min(max(playheadProgress, 0), 1),
            playheadAnchorTimestamp: anchorTimestamp ?? playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: gainPreview,
            duration: duration,
            hasWaveforms: hasWaveforms,
            hasSoloedTrack: hasSoloedTrack
        )
    }

    func withPlaybackActive(_ isPlaybackActive: Bool) -> TimelineRenderState {
        TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: gainPreview,
            duration: duration,
            hasWaveforms: hasWaveforms,
            hasSoloedTrack: hasSoloedTrack
        )
    }

    func withRecordingActive(_ isRecordingActive: Bool) -> TimelineRenderState {
        TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: gainPreview,
            duration: duration,
            hasWaveforms: hasWaveforms,
            hasSoloedTrack: hasSoloedTrack
        )
    }

    func withHover(progress: Float?, isArmed: Bool) -> TimelineRenderState {
        let clampedProgress = progress.map { min(max($0, 0), 1) }
        return TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: clampedProgress,
            isHoverGuideArmed: clampedProgress != nil && isArmed,
            selection: selection,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: gainPreview,
            duration: duration,
            hasWaveforms: hasWaveforms,
            hasSoloedTrack: hasSoloedTrack
        )
    }

    func withSelection(_ selection: TimelineSelection?) -> TimelineRenderState {
        TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: gainPreview,
            duration: duration,
            hasWaveforms: hasWaveforms,
            hasSoloedTrack: hasSoloedTrack
        )
    }

    func withSelectedTrackID(_ selectedTrackID: UUID?) -> TimelineRenderState {
        TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackID.map { [$0] } ?? [],
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: gainPreview,
            duration: duration,
            hasWaveforms: hasWaveforms,
            hasSoloedTrack: hasSoloedTrack
        )
    }

    func withSelectedTrackIDs(_ selectedTrackIDs: Set<UUID>, primaryTrackID: UUID?) -> TimelineRenderState {
        TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            selectedTrackID: primaryTrackID,
            selectedTrackIDs: selectedTrackIDs,
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: gainPreview,
            duration: duration,
            hasWaveforms: hasWaveforms,
            hasSoloedTrack: hasSoloedTrack
        )
    }

    func withTrimPreview(_ trimPreview: TimelineTrimRange?) -> TimelineRenderState {
        TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: gainPreview,
            duration: duration,
            hasWaveforms: hasWaveforms,
            hasSoloedTrack: hasSoloedTrack
        )
    }

    func withGainPreview(_ gainPreview: GainPreview?) -> TimelineRenderState {
        TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: gainPreview,
            duration: duration,
            hasWaveforms: hasWaveforms,
            hasSoloedTrack: hasSoloedTrack
        )
    }

    func withCandidateRegions(_ candidateRegions: [CandidateRegion]) -> TimelineRenderState {
        TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: gainPreview,
            duration: duration,
            hasWaveforms: hasWaveforms,
            hasSoloedTrack: hasSoloedTrack
        )
    }

    func withProcessingTrackHighlight(_ processingTrackHighlight: ProcessingTrackHighlight?) -> TimelineRenderState {
        TimelineRenderState(
            tracks: tracks,
            viewport: viewport,
            trackLayout: trackLayout,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            isRecordingActive: isRecordingActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            selectedTrackID: selectedTrackID,
            selectedTrackIDs: selectedTrackIDs,
            candidateRegions: candidateRegions,
            processingTrackHighlight: processingTrackHighlight,
            trimPreview: trimPreview,
            gainPreview: gainPreview,
            duration: duration,
            hasWaveforms: hasWaveforms,
            hasSoloedTrack: hasSoloedTrack
        )
    }
}
