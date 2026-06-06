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
        trimPreview: TimelineTrimRange?,
        gainPreview: GainPreview?
    ) {
        self.tracks = tracks
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
        self.trimPreview = trimPreview
        self.gainPreview = gainPreview
    }

    var waveformOverview: WaveformOverview? {
        tracks.first?.waveformOverview
    }

    var hasWaveforms: Bool {
        tracks.contains { $0.hasWaveform }
    }

    var duration: TimeInterval? {
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
            trimPreview: trimPreview,
            gainPreview: gainPreview
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
            trimPreview: trimPreview,
            gainPreview: gainPreview
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
            trimPreview: trimPreview,
            gainPreview: gainPreview
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
            trimPreview: trimPreview,
            gainPreview: gainPreview
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
            trimPreview: trimPreview,
            gainPreview: gainPreview
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
            trimPreview: trimPreview,
            gainPreview: gainPreview
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
            trimPreview: trimPreview,
            gainPreview: gainPreview
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
            trimPreview: trimPreview,
            gainPreview: gainPreview
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
            trimPreview: trimPreview,
            gainPreview: gainPreview
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
            trimPreview: trimPreview,
            gainPreview: gainPreview
        )
    }
}
