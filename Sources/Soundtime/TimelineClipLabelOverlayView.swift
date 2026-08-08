import AppKit
import SoundtimeEditing

@MainActor
final class TimelineClipLabelOverlayView: NSView {
    private struct LabelBinding {
        let key: TimelineClipSelectionKey
        let isDragPreview: Bool
    }

    private var tracks: [TimelineRenderState.Track] = []
    private var timelineDuration: TimeInterval = 0
    private var viewport = TimelineViewport.full
    private var trackLayout: ResolvedTimelineTrackLayout?
    private var dragPreviews: [TimelineClipDragPreview] = []
    private var deletionEffects: [TimelineDeletionEffectRequest] = []
    private var deletionEffectStartTimestamp: CFTimeInterval?
    private var labelPool: [NSTextField] = []
    private var labelBindings: [LabelBinding?] = []

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        updateVisibleLabels()
    }

    func configure(
        tracks: [TimelineRenderState.Track],
        timelineDuration: TimeInterval,
        viewport: TimelineViewport,
        trackLayout: ResolvedTimelineTrackLayout
    ) {
        self.tracks = tracks
        self.timelineDuration = timelineDuration
        self.viewport = viewport
        self.trackLayout = trackLayout
        updateVisibleLabels()
    }

    func displayTrackLayout(_ trackLayout: ResolvedTimelineTrackLayout) {
        guard self.trackLayout != trackLayout else {
            return
        }
        self.trackLayout = trackLayout
        updateVisibleLabels()
    }

    var displayedTrackLayoutForTesting: ResolvedTimelineTrackLayout? {
        trackLayout
    }

    func displayDragPreviews(_ previews: [TimelineClipDragPreview]) {
        guard dragPreviews != previews else {
            return
        }
        let previousPreviews = dragPreviews
        dragPreviews = previews
        if applyHorizontalDragTranslation(from: previousPreviews, to: previews) {
            return
        }
        updateVisibleLabels()
    }

    private func applyHorizontalDragTranslation(
        from previousPreviews: [TimelineClipDragPreview],
        to previews: [TimelineClipDragPreview]
    ) -> Bool {
        guard
            !previousPreviews.isEmpty,
            previousPreviews.count == previews.count,
            viewport.durationProgress > 0,
            bounds.width > 0
        else {
            return false
        }
        let previousByKey = Dictionary(
            uniqueKeysWithValues: previousPreviews.map {
                (TimelineClipSelectionKey(trackID: $0.trackID, clipID: $0.clipID), $0)
            }
        )
        var translationsByKey: [TimelineClipSelectionKey: CGFloat] = [:]
        translationsByKey.reserveCapacity(previews.count)
        for preview in previews {
            let key = TimelineClipSelectionKey(trackID: preview.trackID, clipID: preview.clipID)
            guard
                let previous = previousByKey[key],
                previous.kind == preview.kind,
                previous.destinationTrackID == preview.destinationTrackID,
                previous.presentedStartProjectProgress >= viewport.startProgress,
                previous.presentedEndProjectProgress <= viewport.endProgress,
                preview.presentedStartProjectProgress >= viewport.startProgress,
                preview.presentedEndProjectProgress <= viewport.endProgress
            else {
                return false
            }
            translationsByKey[key] = CGFloat(
                (preview.presentedStartProjectProgress - previous.presentedStartProjectProgress) /
                    viewport.durationProgress
            ) * bounds.width
        }
        var movedLabelCount = 0
        for index in labelPool.indices {
            guard
                labelBindings.indices.contains(index),
                let binding = labelBindings[index],
                binding.isDragPreview,
                let translation = translationsByKey[binding.key]
            else {
                continue
            }
            labelPool[index].frame.origin.x += translation
            movedLabelCount += 1
        }
        return movedLabelCount > 0
    }

    func displayDeletionEffects(
        _ effects: [TimelineDeletionEffectRequest],
        startTimestamp: CFTimeInterval
    ) {
        deletionEffects = effects
        deletionEffectStartTimestamp = startTimestamp
        updateVisibleLabels(at: startTimestamp)
    }

    func clearDeletionEffects() {
        guard !deletionEffects.isEmpty || deletionEffectStartTimestamp != nil else {
            return
        }
        deletionEffects = []
        deletionEffectStartTimestamp = nil
        updateVisibleLabels()
    }

    @discardableResult
    func advanceDeletionPresentation(at timestamp: CFTimeInterval) -> Bool {
        guard let startTimestamp = deletionEffectStartTimestamp else {
            return false
        }
        let animationEndTimestamp = startTimestamp + TimelineDeletionEffectRequest.animationDuration
        updateVisibleLabels(at: min(timestamp, animationEndTimestamp))
        return timestamp < animationEndTimestamp
    }

    private func updateVisibleLabels(at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard timelineDuration > 0, viewport.durationProgress > 0, let trackLayout else {
            hideLabels(startingAt: 0)
            return
        }

        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        let trackViewportRect = NSRect(
            x: 0,
            y: CGFloat(trackLayout.rulerLaneHeight),
            width: bounds.width,
            height: max(bounds.height - CGFloat(trackLayout.rulerLaneHeight), 0)
        )
        let visibleTrackIndices = trackLayout.visibleTrackIndices(overscan: 0)
        let trackIndicesByID: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: visibleTrackIndices.compactMap { trackIndex -> (UUID, Int)? in
                guard tracks.indices.contains(trackIndex) else { return nil }
                return (tracks[trackIndex].id, trackIndex)
            }
        )
        var nextLabelIndex = 0

        for trackIndex in visibleTrackIndices {
            guard tracks.indices.contains(trackIndex) else { continue }
            let track = tracks[trackIndex]
            guard let lane = trackLayout.laneFrame(forTrackIndex: trackIndex) else {
                continue
            }
            let trackDuration = track.durationHint ?? track.waveformOverview?.duration ?? 0
            guard trackDuration > 0 else {
                continue
            }
            let trackProjectScale = trackDuration / timelineDuration
            for clip in track.clipRanges where !clip.isSilent {
                let preview = dragPreviews.first {
                    $0.trackID == track.id && $0.clipID == clip.id
                }
                let destinationLane = preview.flatMap { preview in
                    guard preview.destinationTrackID != track.id,
                          let destinationIndex = trackIndicesByID[preview.destinationTrackID]
                    else { return lane }
                    return trackLayout.laneFrame(forTrackIndex: destinationIndex)
                } ?? lane
                let rawName = clip.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = clip.isMissingMedia ?
                    "Missing Media" + ((rawName?.isEmpty == false) ? " - \(rawName!)" : "") :
                    rawName
                guard let name, !name.isEmpty else {
                    continue
                }
                let originalStart = Float(clip.startProgress * trackProjectScale)
                let originalEnd = Float(clip.endProgress * trackProjectScale)
                var presentations: [(
                    lane: TimelineTrackLaneFrame,
                    start: Float,
                    end: Float,
                    isDragPreview: Bool
                )] = []
                if preview?.kind == .duplicate {
                    presentations.append((lane, originalStart, originalEnd, false))
                }
                presentations.append((
                    destinationLane,
                    preview?.presentedStartProjectProgress ?? originalStart,
                    preview?.presentedEndProjectProgress ?? originalEnd,
                    preview != nil
                ))

                for var presentation in presentations {
                    if preview == nil {
                        let projected = projectedRange(
                            presentation.start...presentation.end,
                            trackID: track.id,
                            at: timestamp
                        )
                        presentation.start = projected.lowerBound
                        presentation.end = projected.upperBound
                    }
                    guard presentation.end >= viewport.startProgress,
                          presentation.start <= viewport.endProgress else { continue }
                    // During live resize AppKit may lay this overlay out before
                    // TimelineView publishes the next resolved layout. Project
                    // through the layout's source viewport so labels remain
                    // attached to their lanes rather than briefly scaling with
                    // stale normalized coordinates.
                    let lanePixels = trackLayout.pixelFrame(for: presentation.lane)
                    let laneTop = lanePixels.top
                    let laneBottom = lanePixels.bottom
                    let chromeGeometry = TimelineClipChromeMetrics.verticalGeometry(
                        laneTop: laneTop,
                        laneBottom: laneBottom,
                        viewportHeight: Float(bounds.height)
                    )
                    let startX = CGFloat((presentation.start - viewport.startProgress) / viewport.durationProgress) * bounds.width
                    let endX = CGFloat((presentation.end - viewport.startProgress) / viewport.durationProgress) * bounds.width
                    let headerRect = NSRect(
                        x: max(startX, 0),
                        y: CGFloat(chromeGeometry.clipTop),
                        width: min(endX, bounds.width) - max(startX, 0),
                        height: CGFloat(chromeGeometry.headerHeight)
                    )
                    let visibleRect = headerRect.intersection(trackViewportRect).intersection(bounds)
                    guard
                        visibleRect.width >= 24,
                        visibleRect.height >= textHeight,
                        !visibleRect.isNull
                    else { continue }

                    let label = reusableLabel(at: nextLabelIndex)
                    labelBindings[nextLabelIndex] = LabelBinding(
                        key: TimelineClipSelectionKey(trackID: track.id, clipID: clip.id),
                        isDragPreview: presentation.isDragPreview
                    )
                    nextLabelIndex += 1
                    label.stringValue = name
                    label.textColor = clip.isMissingMedia ?
                        NSColor(calibratedRed: 1, green: 0.68, blue: 0.32, alpha: 0.96) : clip.isSelected ?
                        NSColor(calibratedWhite: 0.98, alpha: 0.92) :
                        NSColor(calibratedWhite: 0.86, alpha: 0.78)
                    let horizontalInset: CGFloat = 7
                    label.frame = NSRect(
                        x: visibleRect.minX + horizontalInset,
                        y: floor(visibleRect.midY - textHeight * 0.5),
                        width: max(visibleRect.width - horizontalInset * 2, 0),
                        height: textHeight
                    )
                    label.isHidden = false
                }
            }
        }

        hideLabels(startingAt: nextLabelIndex)
    }

    private func projectedRange(
        _ range: ClosedRange<Float>,
        trackID: UUID,
        at timestamp: CFTimeInterval
    ) -> ClosedRange<Float> {
        guard
            let startTimestamp = deletionEffectStartTimestamp,
            let effect = deletionEffects.first(where: {
                $0.selection.trackID == nil || $0.selection.trackID == trackID
            })
        else {
            return range
        }

        let rawProgress = min(max(
            (timestamp - startTimestamp) / TimelineDeletionEffectRequest.animationDuration,
            0
        ), 1)
        let progress = TimelineRippleDeletePresentation.easedProgress(rawProgress)
        let deletionRange = effect.selection.startProgress...effect.selection.endProgress
        let projected = TimelineRippleDeletePresentation.project(
            Double(range.lowerBound)...Double(range.upperBound),
            deleting: deletionRange,
            progress: progress
        )
        return Float(projected.lowerBound)...Float(projected.upperBound)
    }

    private func reusableLabel(at index: Int) -> NSTextField {
        if labelPool.indices.contains(index) {
            return labelPool[index]
        }

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)
        labelPool.append(label)
        labelBindings.append(nil)
        return label
    }

    private func hideLabels(startingAt index: Int) {
        guard index < labelPool.count else { return }
        for hiddenIndex in index..<labelPool.count {
            labelPool[hiddenIndex].isHidden = true
            labelBindings[hiddenIndex] = nil
        }
    }
}
