import Foundation

/// Converts canonical timeline frames into the track-local progress consumed by
/// the renderer. Clip and waveform geometry in a render track must use this
/// domain; the renderer converts it to project progress exactly once by applying
/// the track-duration/project-duration ratio.
enum TimelineRenderTrackProgress {
    static func normalized(frame: Int, trackEndFrame: Int) -> Double {
        Double(frame) / Double(max(trackEndFrame, 1))
    }

    static func projectProgress(
        trackProgress: Double,
        trackEndFrame: Int,
        projectEndFrame: Int
    ) -> Double {
        trackProgress * Double(max(trackEndFrame, 0)) / Double(max(projectEndFrame, 1))
    }
}

struct TimelineAutomationHover: Equatable, Sendable {
    let trackID: UUID
    let pointID: UUID?
    let segmentLeadingPointID: UUID?
    let isLineHovered: Bool
}

struct TimelineAutomationPreview: Equatable, Sendable {
    let trackID: UUID
    let parameterID: String
    let points: [TimelineRenderState.Track.AutomationPoint]
}

struct TimelineAutomationSelectionPresentation: Equatable, Sendable {
    let trackID: UUID
    let parameterID: String
    let pointIDs: Set<UUID>
}

struct TimelineRenderState: Sendable {
    struct ClipRange: Equatable, Sendable {
        let id: AudioTimelineClipID
        /// Progress within this track's duration, not the whole project.
        let startProgress: Double
        let endProgress: Double
        let name: String?
        let isSelected: Bool
        let isSilent: Bool
        let isMissingMedia: Bool
        /// True only for the temporary clip that is growing while input is recorded.
        /// Its visual end is projected from the display-frame transport clock.
        let isLiveRecordingPreview: Bool
        let gain: Float
        let fadeInProgress: Double
        let fadeOutProgress: Double

        init(
            id: AudioTimelineClipID = AudioTimelineClipID(),
            startProgress: Double,
            endProgress: Double,
            name: String? = nil,
            isSelected: Bool = false,
            isSilent: Bool = false,
            isMissingMedia: Bool = false,
            isLiveRecordingPreview: Bool = false,
            gain: Float = 1,
            fadeInProgress: Double = 0,
            fadeOutProgress: Double = 0
        ) {
            self.id = id
            let clampedStart = min(max(startProgress, 0), 1)
            let clampedEnd = min(max(endProgress, 0), 1)
            self.startProgress = min(clampedStart, clampedEnd)
            self.endProgress = max(clampedStart, clampedEnd)
            self.name = name
            self.isSelected = isSelected
            self.isSilent = isSilent
            self.isMissingMedia = isMissingMedia
            self.isLiveRecordingPreview = isLiveRecordingPreview
            self.gain = max(gain, 0)
            self.fadeInProgress = min(max(fadeInProgress, 0), 1)
            self.fadeOutProgress = min(max(fadeOutProgress, 0), 1)
        }

        var durationProgress: Double {
            endProgress - startProgress
        }
    }

    struct Track: Sendable {
        struct AutomationPoint: Equatable, Sendable {
            let id: UUID
            let projectProgress: Double
            let normalizedValue: Float
            let curveToNext: Float
        }

        struct AutomationLane: Equatable, Sendable {
            let revision: UInt64
            let parameterID: String
            let defaultNormalizedValue: Float
            let points: [AutomationPoint]
            let isEnabled: Bool

            init(
                revision: UInt64 = 1,
                parameterID: String,
                defaultNormalizedValue: Float,
                points: [AutomationPoint],
                isEnabled: Bool
            ) {
                self.revision = revision
                self.parameterID = parameterID
                self.defaultNormalizedValue = defaultNormalizedValue
                self.points = points
                self.isEnabled = isEnabled
            }
        }

        struct WaveformSegment: Sendable, Hashable {
            /// Output progress within the destination track's duration.
            let outputStartProgress: Float
            let outputEndProgress: Float
            let sourceStartProgress: Float
            let sourceEndProgress: Float
            let gainStart: Float
            let gainEnd: Float

            init(
                outputStartProgress: Float,
                outputEndProgress: Float,
                sourceStartProgress: Float,
                sourceEndProgress: Float,
                gainStart: Float = 1,
                gainEnd: Float = 1
            ) {
                self.outputStartProgress = min(max(outputStartProgress, 0), 1)
                self.outputEndProgress = min(max(outputEndProgress, self.outputStartProgress), 1)
                self.sourceStartProgress = min(max(sourceStartProgress, 0), 1)
                self.sourceEndProgress = min(max(sourceEndProgress, 0), 1)
                self.gainStart = gainStart
                self.gainEnd = gainEnd
            }
        }

        /// A source-resident waveform projected into this logical track lane.
        ///
        /// A track can contain clips from several media sources. Keeping each
        /// source in its own layer lets the renderer reuse resident GPU data
        /// while clip segments provide the timeline mapping.
        struct WaveformLayer: Sendable {
            let id: UUID
            let sourceID: TimelineMediaSourceID?
            let waveformVersion: Int
            let waveformOverview: WaveformOverview?
            let waveformSegments: [WaveformSegment]
            let waveformTileSource: WaveformTileBuildSource?
            let isLiveRecordingPreview: Bool

            init(
                id: UUID,
                sourceID: TimelineMediaSourceID? = nil,
                waveformVersion: Int,
                waveformOverview: WaveformOverview?,
                waveformSegments: [WaveformSegment],
                waveformTileSource: WaveformTileBuildSource? = nil,
                isLiveRecordingPreview: Bool = false
            ) {
                self.id = id
                self.sourceID = sourceID
                self.waveformVersion = waveformVersion
                self.waveformOverview = waveformOverview
                self.waveformSegments = waveformSegments.filter {
                    $0.outputEndProgress > $0.outputStartProgress
                }
                self.waveformTileSource = waveformTileSource
                self.isLiveRecordingPreview = isLiveRecordingPreview
            }
        }

        let id: UUID
        let waveformVersion: Int
        let waveformOverview: WaveformOverview?
        let durationHint: TimeInterval?
        let hasWaveform: Bool
        let volume: Float
        let isMuted: Bool
        let isSoloed: Bool
        let clipRanges: [ClipRange]
        let waveformSegments: [WaveformSegment]
        let waveformTileSource: WaveformTileBuildSource?
        let usesSourceWaveformLayers: Bool
        let waveformLayers: [WaveformLayer]
        let transcript: TranscriptDocument?
        let automationLanes: [AutomationLane]

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
            waveformSegments: [WaveformSegment] = [],
            waveformTileSource: WaveformTileBuildSource? = nil,
            usesSourceWaveformLayers: Bool = false,
            waveformLayers: [WaveformLayer] = [],
            transcript: TranscriptDocument? = nil,
            automationLanes: [AutomationLane] = []
        ) {
            self.id = id
            self.waveformVersion = waveformVersion
            self.waveformOverview = waveformOverview
            self.durationHint = durationHint
            self.volume = volume
            self.isMuted = isMuted
            self.isSoloed = isSoloed
            self.hasWaveform = hasWaveform ?? (
                waveformOverview?.isEmpty == false ||
                waveformLayers.contains { $0.waveformOverview?.isEmpty == false }
            )
            self.clipRanges = clipRanges.filter { $0.durationProgress > 0 }
            self.waveformSegments = waveformSegments.filter { $0.outputEndProgress > $0.outputStartProgress }
            self.waveformTileSource = waveformTileSource
            self.usesSourceWaveformLayers = usesSourceWaveformLayers || !waveformLayers.isEmpty
            self.waveformLayers = waveformLayers
            self.transcript = transcript
            self.automationLanes = automationLanes
        }

        var resolvedWaveformLayers: [WaveformLayer] {
            if usesSourceWaveformLayers {
                return waveformLayers
            }
            guard waveformOverview?.isEmpty == false else {
                return []
            }
            return [WaveformLayer(
                id: id,
                waveformVersion: waveformVersion,
                waveformOverview: waveformOverview,
                waveformSegments: waveformSegments,
                waveformTileSource: waveformTileSource
            )]
        }

        /// Keeps a source's last drawable payload while a newer presentation
        /// update is still resolving that source. The incoming clip segments
        /// remain authoritative so moved, trimmed, and removed clips never
        /// retain stale timeline geometry.
        func resolvingWaveformLayers(using lastGoodTrack: Track?) -> [WaveformLayer] {
            guard usesSourceWaveformLayers else {
                return waveformLayers
            }

            let lastGoodLayers = lastGoodTrack?.waveformLayers ?? []
            let legacySingleSourceFallback: WaveformLayer? = {
                guard
                    waveformLayers.count == 1,
                    lastGoodTrack?.usesSourceWaveformLayers == false,
                    let overview = lastGoodTrack?.waveformOverview,
                    !overview.isEmpty
                else {
                    return nil
                }

                return WaveformLayer(
                    id: waveformLayers[0].id,
                    sourceID: waveformLayers[0].sourceID,
                    waveformVersion: lastGoodTrack?.waveformVersion ?? 0,
                    waveformOverview: overview,
                    waveformSegments: waveformLayers[0].waveformSegments,
                    waveformTileSource: lastGoodTrack?.waveformTileSource,
                    isLiveRecordingPreview: waveformLayers[0].isLiveRecordingPreview
                )
            }()
            return waveformLayers.map { incomingLayer in
                guard incomingLayer.waveformOverview?.isEmpty != false else {
                    return incomingLayer
                }
                let lastGoodLayer = lastGoodLayers.first(where: { candidate in
                    if let sourceID = incomingLayer.sourceID {
                        return candidate.sourceID == sourceID
                    }
                    return candidate.id == incomingLayer.id
                }) ?? legacySingleSourceFallback
                guard let lastGoodLayer, lastGoodLayer.waveformOverview?.isEmpty == false else {
                    return incomingLayer
                }

                return WaveformLayer(
                    id: incomingLayer.id,
                    sourceID: incomingLayer.sourceID,
                    waveformVersion: lastGoodLayer.waveformVersion,
                    waveformOverview: lastGoodLayer.waveformOverview,
                    waveformSegments: incomingLayer.waveformSegments,
                    waveformTileSource: lastGoodLayer.waveformTileSource,
                    isLiveRecordingPreview: incomingLayer.isLiveRecordingPreview
                )
            }
        }

        func sourceTrack(for layer: WaveformLayer) -> Track {
            // This is a source-residency view used only by waveform selection,
            // promotion, and drawing. Destination-lane clip chrome, transcript,
            // and automation data are deliberately not copied into it. Keeping
            // this projection lightweight matters when a visible lane contains
            // hundreds of clip instances backed by several shared sources.
            Track(
                id: layer.id,
                waveformVersion: layer.waveformVersion,
                waveformOverview: layer.waveformOverview,
                durationHint: durationHint,
                volume: volume,
                isMuted: isMuted,
                isSoloed: isSoloed,
                hasWaveform: layer.waveformOverview?.isEmpty == false,
                clipRanges: [],
                waveformSegments: layer.waveformSegments,
                waveformTileSource: layer.waveformTileSource,
                transcript: nil,
                automationLanes: []
            )
        }

        func applying(_ mix: ProjectPlaybackTrackMix) -> Track {
            guard id == mix.id else {
                return self
            }
            return Track(
                id: id,
                waveformVersion: waveformVersion,
                waveformOverview: waveformOverview,
                durationHint: durationHint,
                volume: mix.volume,
                isMuted: mix.isMuted,
                isSoloed: mix.isSoloed,
                hasWaveform: hasWaveform,
                clipRanges: clipRanges,
                waveformSegments: waveformSegments,
                waveformTileSource: waveformTileSource,
                usesSourceWaveformLayers: usesSourceWaveformLayers,
                waveformLayers: waveformLayers,
                transcript: transcript,
                automationLanes: automationLanes
            )
        }

        func replacingAutomationLanes(_ automationLanes: [AutomationLane]) -> Track {
            Track(
                id: id,
                waveformVersion: waveformVersion,
                waveformOverview: waveformOverview,
                durationHint: durationHint,
                volume: volume,
                isMuted: isMuted,
                isSoloed: isSoloed,
                hasWaveform: hasWaveform,
                clipRanges: clipRanges,
                waveformSegments: waveformSegments,
                waveformTileSource: waveformTileSource,
                usesSourceWaveformLayers: usesSourceWaveformLayers,
                waveformLayers: waveformLayers,
                transcript: transcript,
                automationLanes: automationLanes
            )
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

    func withTracks(_ tracks: [Track], duration: TimeInterval? = nil) -> TimelineRenderState {
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
            gainPreview: nil,
            duration: duration
        )
    }

    func withDuration(_ duration: TimeInterval?) -> TimelineRenderState {
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
