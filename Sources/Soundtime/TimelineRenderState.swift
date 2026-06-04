import Foundation

struct TimelineRenderState: Sendable {
    struct GainPreview: Sendable {
        let selection: TimelineSelection
        let gain: Float
    }

    static let empty = TimelineRenderState(
        waveformOverview: nil,
        viewport: .full,
        playheadProgress: 0,
        playheadAnchorTimestamp: 0,
        isPlaybackActive: false,
        hoverProgress: nil,
        isHoverGuideArmed: false,
        selection: nil,
        trimPreview: nil,
        gainPreview: nil
    )

    let waveformOverview: WaveformOverview?
    let viewport: TimelineViewport
    let playheadProgress: Float
    let playheadAnchorTimestamp: CFTimeInterval
    let isPlaybackActive: Bool
    let hoverProgress: Float?
    let isHoverGuideArmed: Bool
    let selection: TimelineSelection?
    let trimPreview: TimelineTrimRange?
    let gainPreview: GainPreview?

    func withWaveformOverview(_ waveformOverview: WaveformOverview?) -> TimelineRenderState {
        TimelineRenderState(
            waveformOverview: waveformOverview,
            viewport: viewport,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            trimPreview: trimPreview,
            gainPreview: nil
        )
    }

    func withViewport(_ viewport: TimelineViewport) -> TimelineRenderState {
        TimelineRenderState(
            waveformOverview: waveformOverview,
            viewport: viewport,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            trimPreview: trimPreview,
            gainPreview: gainPreview
        )
    }

    func withPlayheadProgress(
        _ playheadProgress: Float,
        anchorTimestamp: CFTimeInterval? = nil
    ) -> TimelineRenderState {
        TimelineRenderState(
            waveformOverview: waveformOverview,
            viewport: viewport,
            playheadProgress: min(max(playheadProgress, 0), 1),
            playheadAnchorTimestamp: anchorTimestamp ?? playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            trimPreview: trimPreview,
            gainPreview: gainPreview
        )
    }

    func withPlaybackActive(_ isPlaybackActive: Bool) -> TimelineRenderState {
        TimelineRenderState(
            waveformOverview: waveformOverview,
            viewport: viewport,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            trimPreview: trimPreview,
            gainPreview: gainPreview
        )
    }

    func withHover(progress: Float?, isArmed: Bool) -> TimelineRenderState {
        let clampedProgress = progress.map { min(max($0, 0), 1) }
        return TimelineRenderState(
            waveformOverview: waveformOverview,
            viewport: viewport,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            hoverProgress: clampedProgress,
            isHoverGuideArmed: clampedProgress != nil && isArmed,
            selection: selection,
            trimPreview: trimPreview,
            gainPreview: gainPreview
        )
    }

    func withSelection(_ selection: TimelineSelection?) -> TimelineRenderState {
        TimelineRenderState(
            waveformOverview: waveformOverview,
            viewport: viewport,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            trimPreview: trimPreview,
            gainPreview: gainPreview
        )
    }

    func withTrimPreview(_ trimPreview: TimelineTrimRange?) -> TimelineRenderState {
        TimelineRenderState(
            waveformOverview: waveformOverview,
            viewport: viewport,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            trimPreview: trimPreview,
            gainPreview: gainPreview
        )
    }

    func withGainPreview(_ gainPreview: GainPreview?) -> TimelineRenderState {
        TimelineRenderState(
            waveformOverview: waveformOverview,
            viewport: viewport,
            playheadProgress: playheadProgress,
            playheadAnchorTimestamp: playheadAnchorTimestamp,
            isPlaybackActive: isPlaybackActive,
            hoverProgress: hoverProgress,
            isHoverGuideArmed: isHoverGuideArmed,
            selection: selection,
            trimPreview: trimPreview,
            gainPreview: gainPreview
        )
    }
}
