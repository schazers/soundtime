import Foundation

struct TimelineRenderState: Sendable {
    struct Track: Sendable {
        let id: UUID
        let waveformVersion: Int
        let waveformOverview: WaveformOverview?
        let durationHint: TimeInterval?
        let hasWaveform: Bool
        let volume: Float
        let isMuted: Bool
        let isSoloed: Bool

        init(
            id: UUID,
            waveformVersion: Int,
            waveformOverview: WaveformOverview?,
            durationHint: TimeInterval?,
            volume: Float,
            isMuted: Bool,
            isSoloed: Bool,
            hasWaveform: Bool? = nil
        ) {
            self.id = id
            self.waveformVersion = waveformVersion
            self.waveformOverview = waveformOverview
            self.durationHint = durationHint
            self.volume = volume
            self.isMuted = isMuted
            self.isSoloed = isSoloed
            self.hasWaveform = hasWaveform ?? (waveformOverview?.isEmpty == false)
        }
    }

    struct GainPreview: Sendable {
        let selection: TimelineSelection
        let gain: Float
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
            trimPreview: trimPreview,
            gainPreview: gainPreview,
            duration: duration,
            hasWaveforms: hasWaveforms,
            hasSoloedTrack: hasSoloedTrack
        )
    }
}
