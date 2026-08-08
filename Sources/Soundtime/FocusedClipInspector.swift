import AppKit
import QuartzCore

struct TimelineClipFocusRequest: Equatable, Sendable {
    let clipID: AudioTimelineClipID
    let trackID: UUID
    let trackLocalRange: TimelineRenderState.ClipRange
    let projectStartProgress: Float
    let projectEndProgress: Float
}

struct TimelineClipSelectionKey: Hashable, Sendable {
    let trackID: UUID
    let clipID: AudioTimelineClipID

    init(trackID: UUID, clipID: AudioTimelineClipID) {
        self.trackID = trackID
        self.clipID = clipID
    }

    init(_ request: TimelineClipFocusRequest) {
        self.init(trackID: request.trackID, clipID: request.clipID)
    }
}

enum TimelineClipSelectionIntent: Equatable, Sendable {
    case replace
    case toggle
    case range
    case additive
}

struct TimelineClipSelectionState: Equatable, Sendable {
    var keys: Set<TimelineClipSelectionKey> = []
    var primary: TimelineClipSelectionKey?

    mutating func apply(
        _ key: TimelineClipSelectionKey?,
        intent: TimelineClipSelectionIntent,
        orderedFallback: () -> TimelineClipSelectionKey? = { nil }
    ) {
        guard let key else {
            keys.removeAll()
            primary = nil
            return
        }

        switch intent {
        case .replace:
            keys = [key]
            primary = key
        case .toggle:
            if keys.remove(key) != nil {
                if primary == key {
                    primary = orderedFallback()
                }
            } else {
                keys.insert(key)
                primary = key
            }
        case .range, .additive:
            keys.insert(key)
            primary = key
        }
    }
}

enum TimelineClipEdge: Equatable, Sendable {
    case leading
    case trailing
}

enum TimelineClipDragPreviewKind: Equatable, Sendable {
    case move
    case duplicate
    case trimLeading
    case trimTrailing
}

struct TimelineClipDragPreview: Equatable, Sendable {
    /// The track that currently owns the canonical clip.
    let trackID: UUID
    /// The lane where the clip is presented and will be committed.
    let destinationTrackID: UUID
    let clipID: AudioTimelineClipID
    let originalStartProjectProgress: Float
    let originalEndProjectProgress: Float
    let presentedStartProjectProgress: Float
    let presentedEndProjectProgress: Float
    let kind: TimelineClipDragPreviewKind

    init(
        trackID: UUID,
        destinationTrackID: UUID? = nil,
        clipID: AudioTimelineClipID,
        originalStartProjectProgress: Float,
        originalEndProjectProgress: Float,
        presentedStartProjectProgress: Float,
        presentedEndProjectProgress: Float,
        kind: TimelineClipDragPreviewKind
    ) {
        self.trackID = trackID
        self.destinationTrackID = destinationTrackID ?? trackID
        self.clipID = clipID
        self.originalStartProjectProgress = originalStartProjectProgress
        self.originalEndProjectProgress = originalEndProjectProgress
        self.presentedStartProjectProgress = presentedStartProjectProgress
        self.presentedEndProjectProgress = presentedEndProjectProgress
        self.kind = kind
    }

    var projectDelta: Float {
        presentedStartProjectProgress - originalStartProjectProgress
    }
}

enum TimelineClipPropertyControl: Equatable, Sendable {
    case fadeIn
    case fadeOut
}

struct TimelineClipPropertyPreview: Equatable, Sendable {
    let trackID: UUID
    let clipID: AudioTimelineClipID
    let gain: Float
    let fadeInProgress: Double
    let fadeOutProgress: Double
}

struct TimelineClipPropertyHover: Equatable, Sendable {
    let trackID: UUID
    let clipID: AudioTimelineClipID
    let control: TimelineClipPropertyControl
}

enum TimelineClipContextAction: Equatable, Sendable {
    case open
    case exportWAV
    case rename
    case duplicate
    case repeatClips
    case toggleMute
    case toggleLock
    case group
    case ungroup
    case toggleCrossfadeIn
    case toggleCrossfadeOut
    case crossfade
    case splitAtPlayhead
    case delete
}

struct FocusedClipContext: Equatable, Sendable {
    let clipID: AudioTimelineClipID
    let trackID: UUID
    let trackName: String
    let trackLocalRange: TimelineRenderState.ClipRange
    let projectStartProgress: Float
    let projectEndProgress: Float
    let trackDuration: TimeInterval
    let clipDuration: TimeInterval

    init(
        request: TimelineClipFocusRequest,
        trackName: String,
        trackDuration: TimeInterval,
        projectDuration: TimeInterval
    ) {
        clipID = request.clipID
        trackID = request.trackID
        self.trackName = trackName
        trackLocalRange = request.trackLocalRange
        projectStartProgress = 0
        let safeTrackDuration = max(trackDuration, 0)
        let safeProjectDuration = max(projectDuration, safeTrackDuration, 0.000_001)
        projectEndProgress = min(max(Float(safeTrackDuration / safeProjectDuration), 0), 1)
        self.trackDuration = safeTrackDuration
        clipDuration = safeTrackDuration * request.trackLocalRange.durationProgress
    }

    var projectDurationProgress: Float {
        max(projectEndProgress - projectStartProgress, 0)
    }

    func projectProgress(forLocalProgress progress: Float) -> Float {
        let local = min(max(progress, 0), 1)
        return projectStartProgress + projectDurationProgress * local
    }

    func localProgress(forProjectProgress progress: Float) -> Float {
        guard projectDurationProgress > 0 else {
            return 0
        }
        return min(max((progress - projectStartProgress) / projectDurationProgress, 0), 1)
    }

    func focusedClipLocalProgress(forTrackProgress progress: Float) -> Float? {
        let start = Float(trackLocalRange.startProgress)
        let duration = Float(trackLocalRange.durationProgress)
        guard duration > 0, progress >= start, progress <= Float(trackLocalRange.endProgress) else {
            return nil
        }
        return min(max((progress - start) / duration, 0), 1)
    }

    func projectSelection(fromLocalSelection selection: TimelineSelection?) -> TimelineSelection? {
        guard let selection else {
            return nil
        }
        return TimelineSelection(
            startProgress: Double(projectProgress(forLocalProgress: selection.startProgressFloat)),
            endProgress: Double(projectProgress(forLocalProgress: selection.endProgressFloat)),
            trackID: trackID
        )
    }

    func localSelection(fromProjectSelection selection: TimelineSelection?) -> TimelineSelection? {
        guard
            let selection,
            selection.trackID == nil || selection.trackID == trackID,
            selection.endProgressFloat >= projectStartProgress,
            selection.startProgressFloat <= projectEndProgress
        else {
            return nil
        }
        return TimelineSelection(
            startProgress: Double(localProgress(forProjectProgress: selection.startProgressFloat)),
            endProgress: Double(localProgress(forProjectProgress: selection.endProgressFloat)),
            trackID: trackID
        )
    }
}

enum FocusedClipProjection {
    static func renderTrack(
        from source: TimelineRenderState.Track,
        context: FocusedClipContext
    ) -> TimelineRenderState.Track {
        return TimelineRenderState.Track(
            id: source.id,
            waveformVersion: source.waveformVersion,
            waveformOverview: source.waveformOverview,
            durationHint: context.trackDuration,
            volume: source.volume,
            isMuted: false,
            isSoloed: true,
            hasWaveform: source.hasWaveform,
            clipRanges: source.clipRanges.map { range in
                TimelineRenderState.ClipRange(
                    id: range.id,
                    startProgress: range.startProgress,
                    endProgress: range.endProgress,
                    name: range.name,
                    isSelected: range.id == context.clipID,
                    isSilent: range.isSilent
                )
            },
            waveformSegments: source.waveformSegments,
            waveformTileSource: source.waveformTileSource,
            transcript: source.transcript,
            automationLanes: source.automationLanes
        )
    }
}

final class FocusedClipInspectorView: NSView {
    let timelineView = TimelineView()

    var onClose: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var onBecameActive: (() -> Void)?
    var onSplit: (() -> Void)?
    var onTrimStart: (() -> Void)?
    var onTrimEnd: (() -> Void)?
    var onMoveEarlier: (() -> Void)?
    var onMoveLater: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onDeleteClip: (() -> Void)?
    var onRename: (() -> Void)?

    private let resizeHandle = ClipInspectorResizeHandleView()
    private let titleLabel = NSTextField(labelWithString: "Track Inspector")
    private let detailLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let splitButton = NSButton()
    private let trimStartButton = NSButton()
    private let trimEndButton = NSButton()
    private let moveEarlierButton = NSButton()
    private let moveLaterButton = NSButton()
    private let duplicateButton = NSButton()
    private let renameButton = NSButton()
    private let deleteButton = NSButton()
    private let headerSeparator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func present(context: FocusedClipContext, renderTrack: TimelineRenderState.Track) {
        timelineView.canUseFocusedClipCommands = true
        titleLabel.stringValue = context.trackName
        detailLabel.stringValue = Self.detailText(context: context, clipCount: renderTrack.clipRanges.count)
        timelineView.displayTracks(
            [renderTrack],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: true,
            allowImmediateInteractiveWaveformPrewarm: false,
            updatesRendererImmediately: true
        )
        timelineView.displayPlayheadProgress(0)
        timelineView.displaySelection(nil)
        timelineView.displayPlaybackActive(false)
        timelineView.displayTranscriptMode(renderTrack.transcript == nil ? .hidden : .waveformOverlay)
    }

    func update(context: FocusedClipContext, renderTrack: TimelineRenderState.Track) {
        timelineView.canUseFocusedClipCommands = true
        titleLabel.stringValue = context.trackName
        detailLabel.stringValue = Self.detailText(context: context, clipCount: renderTrack.clipRanges.count)
        timelineView.displayTracks(
            [renderTrack],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false,
            updatesRendererImmediately: true
        )
        timelineView.displayTranscriptMode(renderTrack.transcript == nil ? .hidden : .waveformOverlay)
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.055, alpha: 0.985).cgColor
        layer?.borderColor = NSColor(white: 0.28, alpha: 0.82).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        clipsToBounds = true

        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.setAccessibilityElement(true)
        resizeHandle.setAccessibilityRole(.splitter)
        resizeHandle.setAccessibilityLabel("Track inspector height")
        resizeHandle.setAccessibilityHelp("Drag vertically to resize the track inspector.")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        splitButton.translatesAutoresizingMaskIntoConstraints = false
        trimStartButton.translatesAutoresizingMaskIntoConstraints = false
        trimEndButton.translatesAutoresizingMaskIntoConstraints = false
        moveEarlierButton.translatesAutoresizingMaskIntoConstraints = false
        moveLaterButton.translatesAutoresizingMaskIntoConstraints = false
        duplicateButton.translatesAutoresizingMaskIntoConstraints = false
        renameButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        timelineView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.9, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        detailLabel.textColor = NSColor(white: 0.58, alpha: 1)

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Track Inspector")
        closeButton.contentTintColor = NSColor(white: 0.72, alpha: 1)
        closeButton.toolTip = "Close Track Inspector"
        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))
        closeButton.setAccessibilityLabel("Close Track Inspector")

        configureHeaderButton(
            splitButton,
            symbol: "scissors",
            tooltip: "Split Clip at Inspector Playhead",
            action: #selector(splitPressed(_:))
        )
        configureHeaderButton(
            trimStartButton,
            symbol: "backward.end.fill",
            tooltip: "Trim Clip Start to Inspector Playhead",
            action: #selector(trimStartPressed(_:))
        )
        configureHeaderButton(
            trimEndButton,
            symbol: "forward.end.fill",
            tooltip: "Trim Clip End to Inspector Playhead",
            action: #selector(trimEndPressed(_:))
        )
        configureHeaderButton(
            moveEarlierButton,
            symbol: "arrow.left",
            tooltip: "Move Clip Earlier",
            action: #selector(moveEarlierPressed(_:))
        )
        configureHeaderButton(
            moveLaterButton,
            symbol: "arrow.right",
            tooltip: "Move Clip Later",
            action: #selector(moveLaterPressed(_:))
        )
        configureHeaderButton(
            duplicateButton,
            symbol: "plus.square.on.square",
            tooltip: "Duplicate Clip",
            action: #selector(duplicatePressed(_:))
        )
        configureHeaderButton(
            renameButton,
            symbol: "pencil",
            tooltip: "Rename Clip",
            action: #selector(renamePressed(_:))
        )
        configureHeaderButton(
            deleteButton,
            symbol: "trash",
            tooltip: "Delete Clip",
            action: #selector(deletePressed(_:))
        )

        headerSeparator.boxType = .separator
        timelineView.setEmbeddedScrollbarsEnabled(true)

        resizeHandle.onDrag = { [weak self] deltaY in
            self?.onResize?(deltaY)
        }

        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(splitButton)
        addSubview(trimStartButton)
        addSubview(trimEndButton)
        addSubview(moveEarlierButton)
        addSubview(moveLaterButton)
        addSubview(duplicateButton)
        addSubview(renameButton)
        addSubview(deleteButton)
        addSubview(closeButton)
        addSubview(headerSeparator)
        addSubview(timelineView)
        addSubview(resizeHandle, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            resizeHandle.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            resizeHandle.centerXAnchor.constraint(equalTo: centerXAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 72),
            resizeHandle.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: resizeHandle.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: resizeHandle.leadingAnchor, constant: -12),

            detailLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: resizeHandle.trailingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(equalTo: trimStartButton.leadingAnchor, constant: -10),

            trimStartButton.trailingAnchor.constraint(equalTo: trimEndButton.leadingAnchor, constant: -2),
            trimEndButton.trailingAnchor.constraint(equalTo: moveEarlierButton.leadingAnchor, constant: -2),
            moveEarlierButton.trailingAnchor.constraint(equalTo: moveLaterButton.leadingAnchor, constant: -2),
            moveLaterButton.trailingAnchor.constraint(equalTo: splitButton.leadingAnchor, constant: -2),
            splitButton.trailingAnchor.constraint(equalTo: duplicateButton.leadingAnchor, constant: -2),
            duplicateButton.trailingAnchor.constraint(equalTo: renameButton.leadingAnchor, constant: -2),
            renameButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -2),
            deleteButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            trimStartButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            trimEndButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            moveEarlierButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            moveLaterButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            splitButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            duplicateButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            renameButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            deleteButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            trimStartButton.widthAnchor.constraint(equalToConstant: 24),
            trimEndButton.widthAnchor.constraint(equalToConstant: 24),
            moveEarlierButton.widthAnchor.constraint(equalToConstant: 24),
            moveLaterButton.widthAnchor.constraint(equalToConstant: 24),
            splitButton.widthAnchor.constraint(equalToConstant: 24),
            duplicateButton.widthAnchor.constraint(equalToConstant: 24),
            renameButton.widthAnchor.constraint(equalToConstant: 24),
            deleteButton.widthAnchor.constraint(equalToConstant: 24),
            trimStartButton.heightAnchor.constraint(equalToConstant: 22),
            trimEndButton.heightAnchor.constraint(equalToConstant: 22),
            moveEarlierButton.heightAnchor.constraint(equalToConstant: 22),
            moveLaterButton.heightAnchor.constraint(equalToConstant: 22),
            splitButton.heightAnchor.constraint(equalToConstant: 22),
            duplicateButton.heightAnchor.constraint(equalToConstant: 22),
            renameButton.heightAnchor.constraint(equalToConstant: 22),
            deleteButton.heightAnchor.constraint(equalToConstant: 22),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 26),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            headerSeparator.topAnchor.constraint(equalTo: topAnchor, constant: 38),
            headerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),

            timelineView.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            timelineView.leadingAnchor.constraint(equalTo: leadingAnchor),
            timelineView.trailingAnchor.constraint(equalTo: trailingAnchor),
            timelineView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func mouseDown(with event: NSEvent) {
        onBecameActive?()
        super.mouseDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let resizePoint = resizeHandle.convert(point, from: self)
        if !resizeHandle.isHidden, resizeHandle.bounds.contains(resizePoint) {
            return resizeHandle
        }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
        window?.invalidateCursorRects(for: resizeHandle)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !resizeHandle.isHidden else {
            return
        }
        addCursorRect(resizeHandle.frame, cursor: .resizeUpDown)
    }

    @objc private func closePressed(_ sender: NSButton) {
        onClose?()
    }

    @objc private func splitPressed(_ sender: NSButton) {
        onSplit?()
    }

    @objc private func trimStartPressed(_ sender: NSButton) {
        onTrimStart?()
    }

    @objc private func trimEndPressed(_ sender: NSButton) {
        onTrimEnd?()
    }

    @objc private func moveEarlierPressed(_ sender: NSButton) {
        onMoveEarlier?()
    }

    @objc private func moveLaterPressed(_ sender: NSButton) {
        onMoveLater?()
    }

    @objc private func duplicatePressed(_ sender: NSButton) {
        onDuplicate?()
    }

    @objc private func renamePressed(_ sender: NSButton) {
        onRename?()
    }

    @objc private func deletePressed(_ sender: NSButton) {
        onDeleteClip?()
    }

    private func configureHeaderButton(
        _ button: NSButton,
        symbol: String,
        tooltip: String,
        action: Selector
    ) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.contentTintColor = NSColor(white: 0.66, alpha: 1)
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.target = self
        button.action = action
    }

    private static func detailText(context: FocusedClipContext, clipCount: Int) -> String {
        let clipLabel = clipCount == 1 ? "clip" : "clips"
        return "Track  \(formatDuration(context.trackDuration))  ·  \(clipCount) \(clipLabel)"
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let milliseconds = max(Int((duration * 1_000).rounded()), 0)
        let minutes = milliseconds / 60_000
        let seconds = (milliseconds % 60_000) / 1_000
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d.%03d", minutes, seconds, remainder)
    }

}

private final class ClipInspectorResizeHandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var previousWindowY: CGFloat?
    private var hoverTrackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
                .cursorUpdate,
            ],
            owner: self,
            userInfo: nil
        )
        hoverTrackingArea = trackingArea
        addTrackingArea(trackingArea)
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeUpDown.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeUpDown.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.resizeUpDown.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        previousWindowY = event.locationInWindow.y
        NSCursor.resizeUpDown.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previousWindowY else {
            return
        }
        let nextY = event.locationInWindow.y
        self.previousWindowY = nextY
        onDrag?(nextY - previousWindowY)
    }

    override func mouseUp(with event: NSEvent) {
        previousWindowY = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let width: CGFloat = 34
        let rect = NSRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - 1,
            width: width,
            height: 2
        )
        NSColor(white: 0.48, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }
}
