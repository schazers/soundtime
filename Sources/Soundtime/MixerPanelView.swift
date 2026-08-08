import AppKit
import Metal
import QuartzCore
import SoundtimeEditing

final class MixerPanelView: NSView {
    var onClose: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var onMuteChanged: ((UUID, Bool) -> Void)?
    var onSoloChanged: ((UUID, Bool) -> Void)?
    var onVolumeEditingBegan: ((UUID, Float) -> Void)?
    var onVolumeChanged: ((UUID, Float) -> Void)?
    var onVolumeEditingEnded: ((UUID) -> Void)?
    var onVolumeAutomationModeChanged: ((UUID, MixerAutomationMode) -> Void)?
    var onPanEditingBegan: ((UUID, Float) -> Void)?
    var onPanChanged: ((UUID, Float) -> Void)?
    var onPanEditingEnded: ((UUID) -> Void)?

    private let header = MixerHeaderView()
    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let meterBatchView = MixerMeterBatchView()
    private let masterStrip = MixerMasterStripView()
    private var channels: [MixerChannelPresentation] = []
    private var channelIndexByID: [UUID: Int] = [:]
    private var levelsByTrackID: [UUID: MixerMeterLevel] = [:]
    private var masterLevels: LoudnessMeterLevels = .silence
    private var lastGraphRevision: UInt64 = 0
    private var metersArePlaying = false

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func display(channels: [MixerChannelPresentation]) {
        guard self.channels != channels else {
            updateVisibleItems()
            return
        }
        let preservesStructure = self.channels.map(\.id) == channels.map(\.id)
        self.channels = channels
        channelIndexByID = Dictionary(
            uniqueKeysWithValues: channels.indices.map { (channels[$0].id, $0) }
        )
        if preservesStructure {
            updateVisibleItems()
            updateMeterGeometry()
            return
        }
        collectionView.reloadData()
        updateMeterGeometry()
    }

    func display(packet: MixerMeterPacket) {
        guard packet.graphRevision >= lastGraphRevision else { return }
        lastGraphRevision = packet.graphRevision
        levelsByTrackID = Dictionary(uniqueKeysWithValues: packet.levels.map { ($0.trackID, $0) })
        meterBatchView.markPacketReceived()
        updateMeterGeometry()
    }

    func displayMaster(levels: LoudnessMeterLevels) {
        masterLevels = levels
        updateMeterGeometry()
    }

    func tickMeters(isPlaying: Bool, at timestamp: TimeInterval = CACurrentMediaTime()) {
        metersArePlaying = isPlaying
        meterBatchView.tick(isPlaying: isPlaying, at: timestamp, rendersImmediately: true)
    }

    func diagnosticsSnapshot(audio: PlaybackTrackMeterDiagnostics) -> MixerDiagnosticsSnapshot {
        meterBatchView.diagnosticsSnapshot(
            visibleChannelCount: collectionView.visibleItems().count,
            packetAgeMilliseconds: max((CACurrentMediaTime() - meterBatchView.lastPacketTimestamp) * 1_000, 0),
            audio: audio
        )
    }

    var horizontalScrollOffset: CGFloat {
        get { scrollView.contentView.bounds.origin.x }
        set {
            let maximum = max(collectionView.bounds.width - scrollView.contentSize.width, 0)
            scrollView.contentView.scroll(to: NSPoint(x: min(max(newValue, 0), maximum), y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            updateMeterGeometry()
        }
    }

    var visibleTrackIDs: [UUID] {
        collectionView.visibleItems().compactMap { ($0 as? MixerChannelItem)?.trackID }
    }

    // MARK: - Deterministic smoke-test surface

    var testingChannelIDs: [UUID] { channels.map(\.id) }
    var testingVisibleChannelCount: Int { collectionView.visibleItems().count }
    var testingRenderedMeterCount: Int { meterBatchView.renderedMeterCount }
    var testingMeterPipelineIsReady: Bool { meterBatchView.isPipelineReady }
    var testingMeterGPUDrawCount: Int { meterBatchView.gpuDrawCount }
    var testingLastGraphRevision: UInt64 { lastGraphRevision }
    var testingMasterStripIsVisible: Bool {
        !masterStrip.isHidden && masterStrip.superview === self
    }
    var testingVisibleTrackIDs: [UUID] { visibleTrackIDs }
    var testingVisibleAccessibilityLabels: [String] {
        collectionView.visibleItems().flatMap { item in
            (item as? MixerChannelItem)?.testingAccessibilityLabels ?? []
        }
    }

    func testingLayout(in size: CGSize) {
        frame = CGRect(origin: .zero, size: size)
        layoutSubtreeIfNeeded()
        header.layoutSubtreeIfNeeded()
        collectionView.layoutSubtreeIfNeeded()
        updateVisibleItems()
        updateMeterGeometry()
    }

    func testingSetMute(trackID: UUID, value: Bool) { onMuteChanged?(trackID, value) }
    func testingSetSolo(trackID: UUID, value: Bool) { onSoloChanged?(trackID, value) }
    func testingSetVolume(trackID: UUID, value: Float) {
        onVolumeEditingBegan?(trackID, value)
        onVolumeChanged?(trackID, value)
        onVolumeEditingEnded?(trackID)
    }
    func testingSetPan(trackID: UUID, value: Float) {
        onPanEditingBegan?(trackID, value)
        onPanChanged?(trackID, value)
        onPanEditingEnded?(trackID)
    }
    func testingSetVolumeAutomationMode(trackID: UUID, mode: MixerAutomationMode) {
        onVolumeAutomationModeChanged?(trackID, mode)
    }
    func testingResetVolume(trackID: UUID) {
        guard let item = collectionView.visibleItems()
            .compactMap({ $0 as? MixerChannelItem })
            .first(where: { $0.trackID == trackID }) else { return }
        item.testingResetVolume()
    }
    func testingVisibleMix(trackID: UUID) -> (volume: Float, pan: Float)? {
        collectionView.visibleItems()
            .compactMap { $0 as? MixerChannelItem }
            .first(where: { $0.trackID == trackID })?
            .testingMix
    }
    func testingMutedPresentation(trackID: UUID) -> Bool? {
        collectionView.visibleItems()
            .compactMap { $0 as? MixerChannelItem }
            .first(where: { $0.trackID == trackID })?
            .testingMutedPresentation
    }
    var testingMixerChannelVerticalGaps: [CGFloat] {
        collectionView.visibleItems()
            .compactMap { $0 as? MixerChannelItem }
            .first?
            .testingVerticalControlGaps ?? []
    }
    var testingMixerCloseControlWinsHitTesting: Bool {
        header.testingCloseControlWinsHitTesting
    }
    var testingMixerCloseHoverPresentation: (isHovered: Bool, scale: CGFloat, isWhite: Bool) {
        header.testingCloseHoverPresentation
    }
    func testingSetMixerCloseHovered(_ isHovered: Bool) {
        header.testingSetCloseHovered(isHovered)
    }
    var testingMixerCursorRegionsAreDisjoint: Bool {
        let bodyPoint = CGPoint(x: bounds.midX, y: mixerBodyCursorRect.midY)
        let headerPoint = CGPoint(x: bounds.midX, y: header.frame.midY)
        return !mixerBodyCursorRect.isEmpty &&
            mixerBodyCursorRect.contains(bodyPoint) &&
            !mixerBodyCursorRect.contains(headerPoint) &&
            header.testingUsesResizeCursor(at: convert(headerPoint, to: header))
    }

    func displayAutomatedMix(
        volumeByTrackID: [UUID: Float],
        panByTrackID: [UUID: Float]
    ) {
        guard !volumeByTrackID.isEmpty || !panByTrackID.isEmpty else { return }
        for (trackID, volume) in volumeByTrackID {
            guard let index = channelIndexByID[trackID] else { continue }
            channels[index].volume = volume
        }
        for (trackID, pan) in panByTrackID {
            guard let index = channelIndexByID[trackID] else { continue }
            channels[index].pan = pan
        }
        updateVisibleItems()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.058, alpha: 0.99).cgColor
        layer?.borderColor = NSColor(white: 0.22, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.34
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: 3)

        header.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        meterBatchView.translatesAutoresizingMaskIntoConstraints = false
        masterStrip.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        // The real height is installed from `layout()`. Starting at one point
        // keeps AppKit's flow layout valid before the panel receives its first
        // window-sized layout pass.
        layout.itemSize = NSSize(width: 104, height: 1)
        layout.minimumInteritemSpacing = 1
        layout.minimumLineSpacing = 1
        layout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            MixerChannelItem.self,
            forItemWithIdentifier: MixerChannelItem.identifier
        )

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        header.onClose = { [weak self] in self?.onClose?() }
        header.onResize = { [weak self] delta in self?.onResize?(delta) }

        addSubview(header)
        addSubview(scrollView)
        addSubview(masterStrip)
        addSubview(meterBatchView, positioned: .above, relativeTo: masterStrip)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: masterStrip.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            masterStrip.widthAnchor.constraint(equalToConstant: 92),
            masterStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            masterStrip.topAnchor.constraint(equalTo: header.bottomAnchor),
            masterStrip.bottomAnchor.constraint(equalTo: bottomAnchor),

            meterBatchView.leadingAnchor.constraint(equalTo: leadingAnchor),
            meterBatchView.trailingAnchor.constraint(equalTo: trailingAnchor),
            meterBatchView.topAnchor.constraint(equalTo: topAnchor),
            meterBatchView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Mixer")
    }

    override func layout() {
        super.layout()
        updateTopEdgeShadowPath()
        if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.itemSize.height = max(scrollView.contentSize.height - 1, 1)
        }
        updateMeterGeometry()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // AppKit keeps the most recently selected cursor when the pointer moves
        // into a region with no cursor rect. The header owns resizeUpDown; the
        // rest of the mixer must explicitly restore the ordinary arrow.
        if !mixerBodyCursorRect.isEmpty {
            addCursorRect(mixerBodyCursorRect, cursor: .arrow)
        }
    }

    private var mixerBodyCursorRect: CGRect {
        bounds.intersection(CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: max(header.frame.minY - bounds.minY, 0)
        ))
    }

    private func updateTopEdgeShadowPath() {
        guard let layer, bounds.width > 0 else { return }
        let topEdge = CGRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowPath = CGPath(rect: topEdge, transform: nil)
        CATransaction.commit()
    }

    @objc private func scrollBoundsChanged() {
        updateMeterGeometry()
    }

    private func updateVisibleItems() {
        for case let item as MixerChannelItem in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: item), channels.indices.contains(indexPath.item) else {
                continue
            }
            configure(item, with: channels[indexPath.item])
        }
    }

    private func configure(_ item: MixerChannelItem, with channel: MixerChannelPresentation) {
        item.display(channel)
        item.onMuteChanged = onMuteChanged
        item.onSoloChanged = onSoloChanged
        item.onVolumeEditingBegan = onVolumeEditingBegan
        item.onVolumeChanged = onVolumeChanged
        item.onVolumeEditingEnded = onVolumeEditingEnded
        item.onVolumeAutomationModeChanged = onVolumeAutomationModeChanged
        item.onPanEditingBegan = onPanEditingBegan
        item.onPanChanged = onPanChanged
        item.onPanEditingEnded = onPanEditingEnded
    }

    private func updateMeterGeometry() {
        var bars: [MixerMeterBatchView.Bar] = []
        for case let item as MixerChannelItem in collectionView.visibleItems() {
            guard let trackID = item.trackID, let level = levelsByTrackID[trackID] else { continue }
            item.displayMeterAccessibility(level)
            let rects = item.meterRects(in: meterBatchView)
            bars.append(.init(trackID: trackID, rects: rects, level: level, isMuted: item.isMuted))
        }
        bars.append(.init(
            trackID: MixerMeterBatchView.masterMeterID,
            rects: masterStrip.meterRects(in: meterBatchView),
            level: MixerMeterLevel(
                trackID: MixerMeterBatchView.masterMeterID,
                channelCount: 2,
                leftRMS: masterLevels.leftRMS,
                rightRMS: masterLevels.rightRMS,
                leftPeak: masterLevels.leftPeak,
                rightPeak: masterLevels.rightPeak
            ),
            isMuted: false
        ))
        meterBatchView.display(bars: bars, isPlaying: metersArePlaying)
    }
}

extension MixerPanelView: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        channels.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: MixerChannelItem.identifier, for: indexPath)
        guard let mixerItem = item as? MixerChannelItem else { return item }
        configure(mixerItem, with: channels[indexPath.item])
        return mixerItem
    }

}

private final class MixerHeaderView: NSView {
    var onClose: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?
    private let title = NSTextField(labelWithString: "Mixer")
    private let closeButton = MixerCloseButton()
    private var dragStartY: CGFloat?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor(white: 0.82, alpha: 1)
        title.translatesAutoresizingMaskIntoConstraints = false
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.074, alpha: 1).cgColor
        layer?.borderColor = NSColor(white: 0.17, alpha: 1).cgColor
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in resizeCursorRects {
            addCursorRect(rect, cursor: .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) { dragStartY = event.locationInWindow.y }
    override func mouseDragged(with event: NSEvent) {
        guard let dragStartY else { return }
        onResize?(event.locationInWindow.y - dragStartY)
        self.dragStartY = event.locationInWindow.y
    }
    override func mouseUp(with event: NSEvent) {
        dragStartY = nil
        window?.invalidateCursorRects(for: self)
        let localPoint = convert(event.locationInWindow, from: nil)
        if !bounds.contains(localPoint) {
            // Mouse capture can finish after the pointer has left the moving
            // header. Do not leave its resize cursor globally installed while
            // waiting for AppKit's next cursor-rect transition.
            NSCursor.arrow.set()
        }
    }

    var testingCloseControlWinsHitTesting: Bool {
        let buttonCenter = convert(
            CGPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY),
            from: closeButton
        )
        return closeButton.superview === self &&
            closeButton.isEnabled &&
            closeButton.frame.contains(buttonCenter) &&
            !resizeCursorRects.contains(where: { $0.contains(buttonCenter) })
    }

    var testingCloseHoverPresentation: (isHovered: Bool, scale: CGFloat, isWhite: Bool) {
        closeButton.testingHoverPresentation
    }

    func testingSetCloseHovered(_ isHovered: Bool) {
        closeButton.testingSetHovered(isHovered, animated: false)
    }

    func testingUsesResizeCursor(at point: CGPoint) -> Bool {
        resizeCursorRects.contains(where: { $0.contains(point) })
    }

    private var resizeCursorRects: [CGRect] {
        let closeHitRect = closeButton.frame.insetBy(dx: -4, dy: -4)
        var rects: [CGRect] = []
        if closeHitRect.minX > bounds.minX {
            rects.append(CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: closeHitRect.minX - bounds.minX,
                height: bounds.height
            ))
        }
        if closeHitRect.maxX < bounds.maxX {
            rects.append(CGRect(
                x: closeHitRect.maxX,
                y: bounds.minY,
                width: bounds.maxX - closeHitRect.maxX,
                height: bounds.height
            ))
        }
        return rects
    }

    @objc private func close() { onClose?() }
}

private final class MixerCloseButton: NSButton {
    private static let restingScale: CGFloat = 1
    private static let hoveredScale: CGFloat = 1.16
    private var isPointerHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Mixer")
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        imageScaling = .scaleProportionallyDown
        bezelStyle = .inline
        isBordered = false
        contentTintColor = NSColor(white: 0.58, alpha: 1)
        toolTip = "Close Mixer"
        setAccessibilityLabel("Close Mixer")
        wantsLayer = true
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self
        ))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
        setHovered(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false, animated: true)
        window?.invalidateCursorRects(for: superview ?? self)
    }

    fileprivate var testingHoverPresentation: (isHovered: Bool, scale: CGFloat, isWhite: Bool) {
        (
            isPointerHovered,
            isPointerHovered ? Self.hoveredScale : Self.restingScale,
            contentTintColor == .white
        )
    }

    fileprivate func testingSetHovered(_ isHovered: Bool, animated: Bool) {
        setHovered(isHovered, animated: animated)
    }

    private func setHovered(_ isHovered: Bool, animated: Bool) {
        guard isPointerHovered != isHovered else { return }
        isPointerHovered = isHovered
        contentTintColor = isHovered ? .white : NSColor(white: 0.58, alpha: 1)

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.08 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        layer?.setAffineTransform(CGAffineTransform(
            scaleX: isHovered ? Self.hoveredScale : Self.restingScale,
            y: isHovered ? Self.hoveredScale : Self.restingScale
        ))
        CATransaction.commit()
    }
}

private final class MixerChannelItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MixerChannelItem")
    var trackID: UUID?
    var isMuted = false
    var onMuteChanged: ((UUID, Bool) -> Void)?
    var onSoloChanged: ((UUID, Bool) -> Void)?
    var onVolumeEditingBegan: ((UUID, Float) -> Void)?
    var onVolumeChanged: ((UUID, Float) -> Void)?
    var onVolumeEditingEnded: ((UUID) -> Void)?
    var onVolumeAutomationModeChanged: ((UUID, MixerAutomationMode) -> Void)?
    var onPanEditingBegan: ((UUID, Float) -> Void)?
    var onPanChanged: ((UUID, Float) -> Void)?
    var onPanEditingEnded: ((UUID) -> Void)?

    private let strip = MixerChannelStripView()

    override func loadView() {
        view = strip
        strip.onMuteChanged = { [weak self] value in
            guard let self, let trackID else { return }
            onMuteChanged?(trackID, value)
        }
        strip.onSoloChanged = { [weak self] value in
            guard let self, let trackID else { return }
            onSoloChanged?(trackID, value)
        }
        strip.onVolumeEditingBegan = { [weak self] value in
            guard let self, let trackID else { return }
            onVolumeEditingBegan?(trackID, value)
        }
        strip.onVolumeChanged = { [weak self] value in
            guard let self, let trackID else { return }
            onVolumeChanged?(trackID, value)
        }
        strip.onVolumeEditingEnded = { [weak self] in
            guard let self, let trackID else { return }
            onVolumeEditingEnded?(trackID)
        }
        strip.onVolumeAutomationModeChanged = { [weak self] mode in
            guard let self, let trackID else { return }
            onVolumeAutomationModeChanged?(trackID, mode)
        }
        strip.onPanEditingBegan = { [weak self] value in
            guard let self, let trackID else { return }
            onPanEditingBegan?(trackID, value)
        }
        strip.onPanChanged = { [weak self] value in
            guard let self, let trackID else { return }
            onPanChanged?(trackID, value)
        }
        strip.onPanEditingEnded = { [weak self] in
            guard let self, let trackID else { return }
            onPanEditingEnded?(trackID)
        }
    }

    func display(_ channel: MixerChannelPresentation) {
        trackID = channel.id
        isMuted = channel.isMuted
        strip.display(channel)
    }

    func meterRects(in view: NSView) -> [CGRect] { strip.meterRects(in: view) }
    func displayMeterAccessibility(_ level: MixerMeterLevel) { strip.displayMeterAccessibility(level) }
    var testingAccessibilityLabels: [String] { strip.testingAccessibilityLabels }
    var testingMix: (volume: Float, pan: Float) { strip.testingMix }
    var testingMutedPresentation: Bool { strip.testingMutedPresentation }
    var testingVerticalControlGaps: [CGFloat] { strip.testingVerticalControlGaps }
    func testingResetVolume() { strip.testingResetVolume() }
}

private final class MixerMutedOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class MixerChannelStripView: NSView {
    private enum LayoutMetrics {
        static let outerTopPadding: CGFloat = 10
        static let controlSpacing: CGFloat = 8
        static let outerBottomPadding: CGFloat = 9
    }

    var onMuteChanged: ((Bool) -> Void)?
    var onSoloChanged: ((Bool) -> Void)?
    var onVolumeEditingBegan: ((Float) -> Void)?
    var onVolumeChanged: ((Float) -> Void)?
    var onVolumeEditingEnded: (() -> Void)?
    var onVolumeAutomationModeChanged: ((MixerAutomationMode) -> Void)?
    var onPanEditingBegan: ((Float) -> Void)?
    var onPanChanged: ((Float) -> Void)?
    var onPanEditingEnded: (() -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private let panKnob = TrackPanKnobView()
    private let soloButton = MixerToggleButton(title: "S")
    private let muteButton = MixerToggleButton(title: "M")
    private let automationModePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fader = MixerVerticalFaderView()
    private let dBLabel = NSTextField(labelWithString: "0.0")
    private let leftMeterGuide = NSView()
    private let rightMeterGuide = NSView()
    private let mutedOverlay = MixerMutedOverlayView()
    private var layout: TrackChannelLayout = .stereo

    var testingAccessibilityLabels: [String] {
        [
            accessibilityLabel(),
            soloButton.accessibilityLabel(),
            muteButton.accessibilityLabel(),
            panKnob.accessibilityLabel(),
            fader.accessibilityLabel(),
            automationModePopUp.accessibilityLabel(),
            leftMeterGuide.accessibilityLabel(),
            rightMeterGuide.accessibilityLabel(),
        ].compactMap { $0 }
    }
    var testingMix: (volume: Float, pan: Float) { (fader.gain, panKnob.value) }
    var testingMutedPresentation: Bool { !mutedOverlay.isHidden }
    var testingVerticalControlGaps: [CGFloat] {
        layoutSubtreeIfNeeded()
        return [
            nameLabel.frame.minY - panKnob.frame.maxY,
            panKnob.frame.minY - soloButton.frame.maxY,
            soloButton.frame.minY - automationModePopUp.frame.maxY,
            automationModePopUp.frame.minY - fader.frame.maxY,
        ]
    }
    func testingResetVolume() { fader.testingReset() }

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }
    required init?(coder: NSCoder) { nil }

    func display(_ channel: MixerChannelPresentation) {
        nameLabel.stringValue = channel.name
        nameLabel.toolTip = channel.name
        if !panKnob.isEditing {
            panKnob.value = channel.pan
        }
        soloButton.isSelected = channel.isSoloed
        muteButton.isSelected = channel.isMuted
        soloButton.accessibilityTrackName = channel.name
        muteButton.accessibilityTrackName = channel.name
        panKnob.setAccessibilityLabel("\(channel.name) pan")
        fader.accessibilityTrackName = channel.name
        if let index = MixerAutomationMode.allCases.firstIndex(of: channel.volumeAutomationMode),
           automationModePopUp.indexOfSelectedItem != index {
            automationModePopUp.selectItem(at: index)
        }
        if !fader.isEditing {
            fader.gain = channel.volume
            dBLabel.stringValue = MixerFaderLaw.displayString(forGain: channel.volume)
        }
        layout = channel.channelLayout
        rightMeterGuide.isHidden = layout == .mono
        mutedOverlay.isHidden = !channel.isMuted
        setAccessibilityLabel("Mixer channel: \(channel.name)")
    }

    func displayMeterAccessibility(_ level: MixerMeterLevel) {
        let leftValue = meterAccessibilityValue(level.leftPeak)
        leftMeterGuide.setAccessibilityValue(leftValue)
        if layout == .stereo {
            rightMeterGuide.setAccessibilityValue(meterAccessibilityValue(level.rightPeak))
        }
    }

    func meterRects(in target: NSView) -> [CGRect] {
        let left = target.convert(leftMeterGuide.bounds, from: leftMeterGuide)
        guard layout == .stereo else { return [left] }
        return [left, target.convert(rightMeterGuide.bounds, from: rightMeterGuide)]
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.065, alpha: 1).cgColor
        layer?.borderColor = NSColor(white: 0.15, alpha: 1).cgColor
        layer?.borderWidth = 1

        nameLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        nameLabel.textColor = NSColor(white: 0.82, alpha: 1)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.alignment = .center
        dBLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        dBLabel.textColor = NSColor(white: 0.63, alpha: 1)
        dBLabel.alignment = .center
        automationModePopUp.addItems(withTitles: MixerAutomationMode.allCases.map(\.displayName))
        automationModePopUp.controlSize = .mini
        automationModePopUp.font = .systemFont(ofSize: 9, weight: .medium)
        automationModePopUp.target = self
        automationModePopUp.action = #selector(automationModeChanged)
        automationModePopUp.setAccessibilityLabel("Volume automation mode")
        automationModePopUp.toolTip = "Volume automation mode"
        for view in [nameLabel, panKnob, soloButton, muteButton, automationModePopUp, fader, dBLabel, leftMeterGuide, rightMeterGuide] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        mutedOverlay.translatesAutoresizingMaskIntoConstraints = false
        mutedOverlay.wantsLayer = true
        mutedOverlay.layer?.backgroundColor = NSColor(white: 0.015, alpha: 0.42).cgColor
        mutedOverlay.isHidden = true
        addSubview(mutedOverlay, positioned: .above, relativeTo: nil)
        leftMeterGuide.isHidden = false
        leftMeterGuide.alphaValue = 0
        rightMeterGuide.alphaValue = 0
        configureMeterAccessibility(leftMeterGuide, label: "Left output level")
        configureMeterAccessibility(rightMeterGuide, label: "Right output level")
        soloButton.onToggle = { [weak self] in self?.onSoloChanged?($0) }
        muteButton.onToggle = { [weak self] in self?.onMuteChanged?($0) }
        fader.onEditingBegan = { [weak self] gain in self?.onVolumeEditingBegan?(gain) }
        fader.onValueChanged = { [weak self] gain in
            self?.dBLabel.stringValue = MixerFaderLaw.displayString(forGain: gain)
            self?.onVolumeChanged?(gain)
        }
        fader.onEditingEnded = { [weak self] in self?.onVolumeEditingEnded?() }
        panKnob.onEditingBegan = { [weak self] in self?.onPanEditingBegan?($0) }
        panKnob.onValueChanged = { [weak self] in self?.onPanChanged?($0) }
        panKnob.onEditingEnded = { [weak self] in self?.onPanEditingEnded?() }

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: LayoutMetrics.outerTopPadding),
            panKnob.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: LayoutMetrics.controlSpacing),
            panKnob.centerXAnchor.constraint(equalTo: centerXAnchor),
            panKnob.widthAnchor.constraint(equalToConstant: 38),
            panKnob.heightAnchor.constraint(equalToConstant: 38),
            soloButton.topAnchor.constraint(equalTo: panKnob.bottomAnchor, constant: LayoutMetrics.controlSpacing),
            soloButton.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -2),
            muteButton.topAnchor.constraint(equalTo: soloButton.topAnchor),
            muteButton.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 2),
            soloButton.widthAnchor.constraint(equalToConstant: 24),
            muteButton.widthAnchor.constraint(equalToConstant: 24),
            soloButton.heightAnchor.constraint(equalToConstant: 22),
            muteButton.heightAnchor.constraint(equalToConstant: 22),
            automationModePopUp.topAnchor.constraint(equalTo: soloButton.bottomAnchor, constant: LayoutMetrics.controlSpacing),
            automationModePopUp.centerXAnchor.constraint(equalTo: centerXAnchor),
            automationModePopUp.widthAnchor.constraint(equalToConstant: 58),
            automationModePopUp.heightAnchor.constraint(equalToConstant: 20),
            fader.topAnchor.constraint(equalTo: automationModePopUp.bottomAnchor, constant: LayoutMetrics.controlSpacing),
            fader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            fader.widthAnchor.constraint(equalToConstant: 34),
            fader.bottomAnchor.constraint(equalTo: dBLabel.topAnchor, constant: -4),
            leftMeterGuide.leadingAnchor.constraint(equalTo: fader.trailingAnchor, constant: 9),
            leftMeterGuide.widthAnchor.constraint(equalToConstant: 7),
            leftMeterGuide.topAnchor.constraint(equalTo: fader.topAnchor),
            leftMeterGuide.bottomAnchor.constraint(equalTo: fader.bottomAnchor),
            rightMeterGuide.leadingAnchor.constraint(equalTo: leftMeterGuide.trailingAnchor, constant: 3),
            rightMeterGuide.widthAnchor.constraint(equalToConstant: 7),
            rightMeterGuide.topAnchor.constraint(equalTo: fader.topAnchor),
            rightMeterGuide.bottomAnchor.constraint(equalTo: fader.bottomAnchor),
            dBLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            dBLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            dBLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -LayoutMetrics.outerBottomPadding),
            dBLabel.heightAnchor.constraint(equalToConstant: 14),
            mutedOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            mutedOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            mutedOverlay.topAnchor.constraint(equalTo: topAnchor),
            mutedOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    private func configureMeterAccessibility(_ view: NSView, label: String) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.levelIndicator)
        view.setAccessibilityLabel(label)
        view.setAccessibilityMinValue(-72)
        view.setAccessibilityMaxValue(0)
        view.setAccessibilityValue(-72)
    }

    private func meterAccessibilityValue(_ amplitude: Float) -> Float {
        max(20 * log10(max(amplitude, 0.000_25)), -72)
    }

    @objc private func automationModeChanged() {
        let index = automationModePopUp.indexOfSelectedItem
        guard MixerAutomationMode.allCases.indices.contains(index) else { return }
        onVolumeAutomationModeChanged?(MixerAutomationMode.allCases[index])
    }
}

private final class MixerToggleButton: NSControl {
    var onToggle: ((Bool) -> Void)?
    var accessibilityTrackName = "Track" { didSet { updateAccessibility() } }
    var isSelected = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isSelected ? 1 : 0)
        }
    }
    private let title: String
    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        toolTip = title == "M" ? "Mute" : "Solo"
        updateAccessibility()
    }
    required init?(coder: NSCoder) { nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        toggle()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            toggle()
        } else {
            super.keyDown(with: event)
        }
    }
    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        (isSelected ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.11, alpha: 1)).setFill(); path.fill()
        NSColor(white: isSelected ? 0.08 : 0.32, alpha: 1).setStroke(); path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: isSelected ? NSColor.black : NSColor(white: 0.72, alpha: 1),
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    private func toggle() {
        isSelected.toggle()
        onToggle?(isSelected)
    }

    private func updateAccessibility() {
        let controlName = title == "M" ? "Mute" : "Solo"
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("\(accessibilityTrackName) \(controlName)")
        setAccessibilityValue(isSelected ? 1 : 0)
    }
}

private final class MixerVerticalFaderView: NSControl {
    var onEditingBegan: ((Float) -> Void)?
    var onValueChanged: ((Float) -> Void)?
    var onEditingEnded: (() -> Void)?
    private(set) var isEditing = false
    var accessibilityTrackName = "Track" { didSet { updateAccessibility() } }
    private var storedGain: Float = 1
    var gain: Float {
        get { storedGain }
        set {
            storedGain = min(max(newValue.isFinite ? newValue : 1, 0), TimelineMixerFaderLaw.maximumGain)
            setAccessibilityValue(MixerFaderLaw.displayString(forGain: storedGain))
            needsDisplay = true
        }
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        updateAccessibility()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        updateAccessibility()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onEditingBegan?(gain)
        if event.clickCount == 2 || event.modifierFlags.contains(.command) {
            gain = 1; onValueChanged?(gain); onEditingEnded?(); return
        }
        isEditing = true; update(event)
    }
    override func mouseDragged(with event: NSEvent) { update(event) }
    override func mouseUp(with event: NSEvent) { update(event); isEditing = false; onEditingEnded?() }
    override func keyDown(with event: NSEvent) {
        let step: Float = event.modifierFlags.contains(.option) ? 0.1 : 1
        switch event.keyCode {
        case 123, 125:
            adjust(decibels: -step)
        case 124, 126:
            adjust(decibels: step)
        case 115, 36:
            resetToUnity()
        default:
            super.keyDown(with: event)
        }
    }
    override func accessibilityPerformIncrement() -> Bool { adjust(decibels: 1); return true }
    override func accessibilityPerformDecrement() -> Bool { adjust(decibels: -1); return true }
    private func update(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let position = Float(min(max((point.y - 8) / max(bounds.height - 16, 1), 0), 1))
        gain = MixerFaderLaw.gain(forPosition: position)
        onValueChanged?(gain)
    }
    override func draw(_ dirtyRect: NSRect) {
        let x = bounds.midX
        NSColor(white: 0.18, alpha: 1).setStroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: x, y: 8)); line.line(to: NSPoint(x: x, y: bounds.height - 8)); line.lineWidth = 4; line.lineCapStyle = .round; line.stroke()
        let position = CGFloat(MixerFaderLaw.position(forGain: gain))
        let y = 8 + position * max(bounds.height - 16, 1)
        let knob = NSRect(x: 3, y: y - 6, width: bounds.width - 6, height: 12)
        NSColor(white: isEditing ? 0.92 : 0.75, alpha: 1).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 3, yRadius: 3).fill()
    }

    private func adjust(decibels delta: Float) {
        onEditingBegan?(gain)
        let current = max(MixerFaderLaw.decibels(forGain: gain), MixerFaderLaw.minimumDecibels)
        gain = MixerFaderLaw.gain(forDecibels: min(max(current + delta, MixerFaderLaw.minimumDecibels), MixerFaderLaw.maximumDecibels))
        onValueChanged?(gain)
        onEditingEnded?()
    }

    private func resetToUnity() {
        onEditingBegan?(gain)
        gain = 1
        onValueChanged?(gain)
        onEditingEnded?()
    }

    func testingReset() { resetToUnity() }

    private func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("\(accessibilityTrackName) volume")
        setAccessibilityHelp("Use the Arrow keys to adjust. Hold Option for fine adjustment. Press Home or Return to reset to 0 dB.")
        setAccessibilityMinValue(MixerFaderLaw.minimumDecibels)
        setAccessibilityMaxValue(MixerFaderLaw.maximumDecibels)
        setAccessibilityValue(MixerFaderLaw.displayString(forGain: storedGain))
    }
}

private final class MixerMeterBatchView: NSView {
    static let masterMeterID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!

    struct Bar {
        var trackID: UUID
        var rects: [CGRect]
        var level: MixerMeterLevel
        var isMuted: Bool
    }

    private struct MeterID: Hashable {
        var trackID: UUID
        var channel: Int
    }

    private struct Ballistics {
        var rms: Float = 0
        var peak: Float = 0
        var peakHoldUntil: TimeInterval = 0
    }

    private struct GPUInstance {
        var rect: SIMD4<Float>
        var levels: SIMD4<Float>
        var style: SIMD4<Float>
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct MeterInstance { float4 rect; float4 levels; float4 style; };
    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float2 size;
        float4 levels;
        float4 style;
    };

    vertex VertexOut mixerMeterVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant MeterInstance* instances [[buffer(0)]],
        constant float2& viewport [[buffer(1)]])
    {
        constexpr float2 corners[4] = {
            float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1)
        };
        MeterInstance instance = instances[instanceID];
        float2 uv = corners[vertexID];
        float2 pixel = instance.rect.xy + uv * instance.rect.zw;
        VertexOut out;
        out.position = float4(pixel / viewport * 2.0 - 1.0, 0, 1);
        out.uv = uv;
        out.size = instance.rect.zw;
        out.levels = instance.levels;
        out.style = instance.style;
        return out;
    }

    fragment float4 mixerMeterFragment(VertexOut in [[stage_in]]) {
        float radius = min(3.0, min(in.size.x, in.size.y) * 0.5);
        float2 p = in.uv * in.size;
        float2 q = abs(p - in.size * 0.5) - (in.size * 0.5 - radius);
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        float coverage = 1.0 - smoothstep(-0.75, 0.75, distance);
        float mutedAlpha = in.style.x;
        float railGlass = 0.90 + 0.10 * (1.0 - abs(in.uv.x * 2.0 - 1.0));
        float3 railColor = float3(0.118, 0.124, 0.128) * railGlass;
        float4 background = float4(railColor, 0.98);

        float y = in.uv.y;
        float3 low = float3(0.25, 0.72, 0.71);
        float3 middle = float3(0.88, 0.76, 0.28);
        float3 high = float3(0.94, 0.22, 0.18);
        float3 meterColor = y < 0.82 ? low : mix(middle, high, smoothstep(0.82, 1.0, y));
        float glass = 0.78 + 0.22 * (1.0 - abs(in.uv.x * 2.0 - 1.0));
        float fillMask = 1.0 - smoothstep(in.levels.x - 0.006, in.levels.x + 0.006, y);
        float peakWidth = max(1.25 / max(in.size.y, 1.0), 0.004);
        float peakMask = 1.0 - smoothstep(peakWidth, peakWidth * 1.8, abs(y - in.levels.y));
        float4 fill = float4(meterColor * glass, 0.92 * mutedAlpha);
        float4 color = mix(background, fill, fillMask);
        color = mix(color, float4(0.98, 0.99, 1.0, mutedAlpha), peakMask);
        color.a *= coverage;
        return color;
    }
    """

    private var bars: [Bar] = []
    private var ballisticsByID: [MeterID: Ballistics] = [:]
    private var instances: [GPUInstance] = []
    private var instanceBuffer: MTLBuffer?
    private var instanceBufferCapacity = 0
    private var lastTickTimestamp = CACurrentMediaTime()
    private(set) var lastPacketTimestamp = CACurrentMediaTime()
    private(set) var gpuDrawCount = 0
    private var drawDurationMilliseconds = 0.0
    private var maximumDrawDurationMilliseconds = 0.0
    var renderedMeterCount: Int { instances.count }
    var isPipelineReady: Bool { device != nil && commandQueue != nil && pipeline != nil }
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()
        if let device,
           let library = try? BundledMetalLibrary.load(
               named: "MixerMeterShaders",
               device: device,
               developmentSource: Self.shaderSource
           ),
           let vertex = library.makeFunction(name: "mixerMeterVertex"),
           let fragment = library.makeFunction(name: "mixerMeterFragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        } else {
            pipeline = nil
        }
        super.init(frame: frameRect)
        wantsLayer = true
        configureMetalLayer()
    }

    required init?(coder: NSCoder) {
        device = nil
        commandQueue = nil
        pipeline = nil
        super.init(coder: coder)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureMetalLayer()
    }

    override func layout() {
        super.layout()
        configureMetalLayer()
    }

    func markPacketReceived(at timestamp: TimeInterval = CACurrentMediaTime()) {
        lastPacketTimestamp = timestamp
    }

    func display(bars: [Bar], isPlaying: Bool) {
        self.bars = bars
        tick(isPlaying: isPlaying)
    }

    func tick(
        isPlaying: Bool,
        at timestamp: TimeInterval = CACurrentMediaTime(),
        rendersImmediately: Bool = false
    ) {
        let elapsed = min(max(timestamp - lastTickTimestamp, 0), 0.1)
        lastTickTimestamp = timestamp
        let visibleIDs = Set(bars.flatMap { bar in
            bar.rects.indices.map { MeterID(trackID: bar.trackID, channel: $0) }
        })
        ballisticsByID = ballisticsByID.filter { visibleIDs.contains($0.key) }
        instances.removeAll(keepingCapacity: true)

        for bar in bars {
            let rmsValues = meterValues(for: bar.level, peak: false, channelCount: bar.rects.count)
            let peakValues = meterValues(for: bar.level, peak: true, channelCount: bar.rects.count)
            for channel in bar.rects.indices {
                let id = MeterID(trackID: bar.trackID, channel: channel)
                var state = ballisticsByID[id] ?? Ballistics()
                let targetRMS = isPlaying ? normalizedDecibels(rmsValues[channel]) : 0
                let targetPeak = isPlaying ? normalizedDecibels(peakValues[channel]) : 0
                let decay = Float(18.0 / 72.0 * elapsed)
                state.rms = targetRMS >= state.rms ? targetRMS : max(state.rms - decay, targetRMS)
                if targetPeak >= state.peak {
                    state.peak = targetPeak
                    state.peakHoldUntil = timestamp + 0.78
                } else if timestamp >= state.peakHoldUntil {
                    state.peak = max(state.peak - decay, targetPeak)
                }
                ballisticsByID[id] = state
                let rect = bar.rects[channel]
                instances.append(GPUInstance(
                    rect: SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
                    levels: SIMD4(state.rms, state.peak, 0, 0),
                    style: SIMD4(bar.isMuted ? 0.38 : 1, 0, 0, 0)
                ))
            }
        }
        if rendersImmediately, window != nil {
            // Transparent CAMetalLayer siblings do not reliably receive
            // AppKit's deferred updateLayer pass. The caller is already paced
            // by the meter display link, so encode one deterministic draw now.
            render()
        } else {
            needsDisplay = true
            layer?.setNeedsDisplay()
        }
    }

    func diagnosticsSnapshot(
        visibleChannelCount: Int,
        packetAgeMilliseconds: Double,
        audio: PlaybackTrackMeterDiagnostics
    ) -> MixerDiagnosticsSnapshot {
        MixerDiagnosticsSnapshot(
            packetAgeMilliseconds: packetAgeMilliseconds,
            droppedPacketCount: audio.droppedPacketCount,
            stalePacketCount: audio.stalePacketCount,
            realtimeWorkNanoseconds: audio.realtimeWorkNanoseconds,
            visibleChannelCount: visibleChannelCount,
            renderedMeterCount: instances.count,
            gpuDrawCount: gpuDrawCount,
            drawDurationMilliseconds: drawDurationMilliseconds,
            maximumDrawDurationMilliseconds: maximumDrawDurationMilliseconds
        )
    }

    override func updateLayer() {
        render()
    }

    private func configureMetalLayer() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.drawableSize = CGSize(
            width: max(bounds.width * metalLayer.contentsScale, 1),
            height: max(bounds.height * metalLayer.contentsScale, 1)
        )
    }

    private func render() {
        let startedAt = CACurrentMediaTime()
        guard
            !instances.isEmpty,
            bounds.width > 0,
            bounds.height > 0,
            let metalLayer = layer as? CAMetalLayer,
            let drawable = metalLayer.nextDrawable(),
            let commandBuffer = commandQueue?.makeCommandBuffer(),
            let pipeline
        else { return }

        ensureInstanceBufferCapacity(instances.count)
        guard let instanceBuffer else { return }
        instances.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            instanceBuffer.contents().copyMemory(from: source, byteCount: bytes.count)
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        var viewport = SIMD2(Float(bounds.width), Float(bounds.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        gpuDrawCount += 1
        drawDurationMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        maximumDrawDurationMilliseconds = max(
            maximumDrawDurationMilliseconds,
            drawDurationMilliseconds
        )
    }

    private func ensureInstanceBufferCapacity(_ count: Int) {
        guard let device, count > instanceBufferCapacity else { return }
        instanceBufferCapacity = max(16, 1 << Int(ceil(log2(Double(max(count, 1))))))
        instanceBuffer = device.makeBuffer(
            length: instanceBufferCapacity * MemoryLayout<GPUInstance>.stride,
            options: .storageModeShared
        )
    }

    private func meterValues(
        for level: MixerMeterLevel,
        peak: Bool,
        channelCount: Int
    ) -> [Float] {
        let left = peak ? level.leftPeak : level.leftRMS
        let right = peak ? level.rightPeak : level.rightRMS
        return channelCount == 1 ? [max(left, right)] : [left, right]
    }

    private func normalizedDecibels(_ amplitude: Float) -> Float {
        min(max((20 * log10(max(amplitude, 0.000_25)) + 72) / 72, 0), 1)
    }
}

private final class MixerMasterStripView: NSView {
    private let title = NSTextField(labelWithString: "MASTER")
    private let leftMeterGuide = NSView()
    private let rightMeterGuide = NSView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 9, weight: .bold); title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        leftMeterGuide.translatesAutoresizingMaskIntoConstraints = false
        rightMeterGuide.translatesAutoresizingMaskIntoConstraints = false
        leftMeterGuide.alphaValue = 0
        rightMeterGuide.alphaValue = 0
        addSubview(title)
        addSubview(leftMeterGuide)
        addSubview(rightMeterGuide)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10), title.leadingAnchor.constraint(equalTo: leadingAnchor), title.trailingAnchor.constraint(equalTo: trailingAnchor),
            leftMeterGuide.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            leftMeterGuide.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            leftMeterGuide.widthAnchor.constraint(equalToConstant: 9),
            leftMeterGuide.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -2),
            rightMeterGuide.topAnchor.constraint(equalTo: leftMeterGuide.topAnchor),
            rightMeterGuide.bottomAnchor.constraint(equalTo: leftMeterGuide.bottomAnchor),
            rightMeterGuide.widthAnchor.constraint(equalToConstant: 9),
            rightMeterGuide.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 2),
        ])
        wantsLayer = true; layer?.backgroundColor = NSColor(white: 0.075, alpha: 1).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Master output")
    }
    required init?(coder: NSCoder) { nil }
    func meterRects(in target: NSView) -> [CGRect] {
        [
            target.convert(leftMeterGuide.bounds, from: leftMeterGuide),
            target.convert(rightMeterGuide.bounds, from: rightMeterGuide),
        ]
    }
}
