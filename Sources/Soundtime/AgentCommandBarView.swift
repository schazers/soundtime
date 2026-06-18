import AppKit

private enum AgentCommandBarMetrics {
    static let horizontalTextInset: CGFloat = 20
    static let minimumVerticalTextInset: CGFloat = 12
    static let textHeightPadding: CGFloat = 34
    static let minimumTextHeight: CGFloat = 54
    static let maximumTextHeight: CGFloat = 168
    static let outerVerticalInset: CGFloat = 10
    static let sendButtonDiameter: CGFloat = 52

    static func verticalTextInset(forContentHeight contentHeight: CGFloat, viewHeight: CGFloat) -> CGFloat {
        max(
            minimumVerticalTextInset,
            floor((viewHeight - contentHeight) * 0.5)
        )
    }
}

@MainActor
final class AgentCommandBarView: NSView, NSTextViewDelegate {
    var onSubmit: ((String) -> Void)?
    var onBlurRequested: (() -> Void)?

    var presentationState: AgentCommandController.PresentationState = .idle {
        didSet {
            updatePlaceholder()
        }
    }

    private let textView = AgentPromptTextView()
    private let placeholderLabel = AgentPlaceholderLabel(labelWithString: "How can I help you?")
    private let sendButton = AgentSendButton()
    private var textHeightConstraint: NSLayoutConstraint?
    private var outsideClickMonitor: Any?
    private var isTextFocused = false {
        didSet {
            textView.isPromptFocused = isTextFocused
            updatePlaceholder()
        }
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var intrinsicContentSize: NSSize {
        let textHeight = textHeightConstraint?.constant ?? 46
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: textHeight + AgentCommandBarMetrics.outerVerticalInset * 2
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeOutsideClickMonitor()
        } else {
            installOutsideClickMonitorIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        updateTextHeight()
        window?.invalidateCursorRects(for: self)
        window?.invalidateCursorRects(for: textView)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else {
            return nil
        }

        if sendHitRect().contains(point) {
            let sendPoint = sendButton.convert(point, from: self)
            return sendButton.hitTest(sendPoint) ?? sendButton
        }

        if promptHitRect().contains(point) {
            let textPoint = textView.convert(point, from: self)
            return textView.hitTest(textPoint) ?? textView
        }

        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if promptHitRect().contains(point) {
            focusPrompt()
            return
        }

        super.mouseDown(with: event)
    }

    func focusPrompt() {
        guard let window else {
            return
        }

        let didFocus = window.makeFirstResponder(textView)
        isTextFocused = didFocus || window.firstResponder === textView
        if didFocus, textView.selectedRange().location == NSNotFound {
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        }
    }

    private func blurPrompt() {
        guard window?.firstResponder === textView else {
            return
        }

        if let onBlurRequested {
            onBlurRequested()
        } else {
            window?.makeFirstResponder(nil)
        }
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        textView.onSubmitShortcut = { [weak self] in
            self?.submit()
        }
        textView.onCancelShortcut = { [weak self] in
            self?.blurPrompt()
        }
        textView.onHoverChanged = { [weak self] isHovered in
            self?.textView.isPromptHovered = isHovered
        }

        placeholderLabel.font = .systemFont(ofSize: 15, weight: .regular)
        placeholderLabel.textColor = NSColor(white: 0.58, alpha: 1)
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        sendButton.onPressed = { [weak self] in
            self?.submit()
        }
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.isEnabled = false

        addSubview(textView)
        addSubview(placeholderLabel)
        addSubview(sendButton)

        let textHeightConstraint = textView.heightAnchor.constraint(equalToConstant: AgentCommandBarMetrics.minimumTextHeight)
        self.textHeightConstraint = textHeightConstraint

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor, constant: AgentCommandBarMetrics.outerVerticalInset),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -12),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -AgentCommandBarMetrics.outerVerticalInset),
            textHeightConstraint,

            placeholderLabel.leadingAnchor.constraint(
                equalTo: textView.leadingAnchor,
                constant: AgentCommandBarMetrics.horizontalTextInset
            ),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: textView.trailingAnchor,
                constant: -AgentCommandBarMetrics.horizontalTextInset
            ),
            placeholderLabel.centerYAnchor.constraint(equalTo: textView.centerYAnchor),

            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: AgentCommandBarMetrics.sendButtonDiameter),
            sendButton.heightAnchor.constraint(equalToConstant: AgentCommandBarMetrics.sendButtonDiameter),
        ])

        updatePlaceholder()
    }

    private func promptHitRect() -> NSRect {
        convert(textView.bounds, from: textView).insetBy(dx: -2, dy: -2)
    }

    private func sendHitRect() -> NSRect {
        convert(sendButton.bounds, from: sendButton).insetBy(dx: -2, dy: -2)
    }

    private func submit() {
        let prompt = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.isEmpty == false else {
            return
        }

        onSubmit?(prompt)
        textView.string = ""
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    private func updatePlaceholder() {
        let isEmpty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholderLabel.isHidden = !isEmpty
        switch presentationState {
        case .idle:
            placeholderLabel.stringValue = isTextFocused ? "Ask Soundtime to edit..." : "How can I help you?"
        case .thinking:
            placeholderLabel.stringValue = "Thinking..."
        case .acting:
            placeholderLabel.stringValue = "Working..."
        }
    }

    private func updateTextHeight() {
        guard let textContainer = textView.textContainer, textView.bounds.width > 0 else {
            return
        }

        let containerWidth = max(
            textView.bounds.width - AgentCommandBarMetrics.horizontalTextInset * 2,
            1
        )
        textContainer.containerSize = NSSize(
            width: containerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.layoutManager?.ensureLayout(for: textContainer)
        let usedHeight = textView.normalizedContentHeight(
            textView.layoutManager?.usedRect(for: textContainer).height ?? 0
        )
        let nextHeight = min(
            max(ceil(usedHeight) + AgentCommandBarMetrics.textHeightPadding, AgentCommandBarMetrics.minimumTextHeight),
            AgentCommandBarMetrics.maximumTextHeight
        )
        if abs((textHeightConstraint?.constant ?? 0) - nextHeight) > 0.5 {
            textHeightConstraint?.constant = nextHeight
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
        textView.updateVerticalInset(forContentHeight: usedHeight, viewHeight: nextHeight)
    }

    private func installOutsideClickMonitorIfNeeded() {
        guard outsideClickMonitor == nil else {
            return
        }

        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else {
                return event
            }

            MainActor.assumeIsolated {
                self.blurPromptIfNeeded(for: event)
            }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        guard let outsideClickMonitor else {
            return
        }

        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    private func blurPromptIfNeeded(for event: NSEvent) {
        guard
            event.window === window,
            window?.firstResponder === textView
        else {
            return
        }

        if
            let point = pointInsideAgentBar(for: event),
            promptHitRect().contains(point)
        {
            return
        }

        blurPrompt()
    }

    private func pointInsideAgentBar(for event: NSEvent) -> NSPoint? {
        guard event.window === window, !isHidden, alphaValue > 0.01 else {
            return nil
        }

        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            return nil
        }

        return point
    }

    func textDidBeginEditing(_ notification: Notification) {
        isTextFocused = true
    }

    func textDidEndEditing(_ notification: Notification) {
        isTextFocused = false
    }

    func textDidChange(_ notification: Notification) {
        let hasPrompt = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        sendButton.isEnabled = hasPrompt
        updatePlaceholder()
        updateTextHeight()
    }
}

@MainActor
private final class AgentPlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class AgentPromptTextView: NSTextView {
    var onSubmitShortcut: (() -> Void)?
    var onCancelShortcut: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    var isPromptFocused = false {
        didSet {
            needsDisplay = true
        }
    }

    var isPromptHovered = false {
        didSet {
            guard oldValue != isPromptHovered else {
                return
            }
            needsDisplay = true
            onHoverChanged?(isPromptHovered)
        }
    }

    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else {
            return nil
        }

        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        trackingArea = nextTrackingArea
        addTrackingArea(nextTrackingArea)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoverAndCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverAndCursor(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateHoverAndCursor(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        isPromptHovered = false
    }

    private func updateHoverAndCursor(for event: NSEvent) {
        let eventPoint = convert(event.locationInWindow, from: nil)
        let isInside = bounds.contains(eventPoint)
        isPromptHovered = isInside
        if isInside {
            NSCursor.iBeam.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(rect.height * 0.5, 30)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let fillWhite: CGFloat = isPromptHovered ? 0.205 : 0.16
        let fillAlpha: CGFloat = isPromptHovered || isPromptFocused ? 0.96 : 0.92
        NSColor(white: fillWhite, alpha: fillAlpha).setFill()
        path.fill()

        super.draw(dirtyRect)
    }

    override init(frame frameRect: NSRect = .zero, textContainer container: NSTextContainer? = nil) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        super.init(frame: frameRect, textContainer: textContainer)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, flags.contains(.shift) == false {
            onSubmitShortcut?()
            return
        }

        if event.keyCode == 53 {
            onCancelShortcut?()
            return
        }

        super.keyDown(with: event)
    }

    private func configure() {
        let promptFont = NSFont.systemFont(ofSize: 15.5, weight: .regular)
        let initialTextInset = AgentCommandBarMetrics.verticalTextInset(
            forContentHeight: singleLineContentHeight(for: promptFont),
            viewHeight: AgentCommandBarMetrics.minimumTextHeight
        )

        drawsBackground = false
        isEditable = true
        isSelectable = true
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        importsGraphics = false
        allowsUndo = true
        isHorizontallyResizable = false
        isVerticallyResizable = true
        minSize = NSSize(width: 0, height: 40)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(
            width: AgentCommandBarMetrics.horizontalTextInset,
            height: initialTextInset
        )
        font = promptFont
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        paragraphStyle.paragraphSpacing = 0
        defaultParagraphStyle = paragraphStyle
        typingAttributes = [
            .font: promptFont,
            .foregroundColor: NSColor(white: 0.94, alpha: 1),
            .paragraphStyle: paragraphStyle,
        ]
        textColor = NSColor(white: 0.94, alpha: 1)
        insertionPointColor = NSColor(white: 1, alpha: 1)
    }

    func updateVerticalInset(forContentHeight contentHeight: CGFloat, viewHeight: CGFloat) {
        let nextInset = AgentCommandBarMetrics.verticalTextInset(
            forContentHeight: normalizedContentHeight(contentHeight),
            viewHeight: viewHeight
        )
        let nextSize = NSSize(width: AgentCommandBarMetrics.horizontalTextInset, height: nextInset)
        if textContainerInset != nextSize {
            textContainerInset = nextSize
        }
    }

    func normalizedContentHeight(_ measuredHeight: CGFloat) -> CGFloat {
        guard measuredHeight > 0.5 else {
            return singleLineContentHeight(for: font)
        }

        return measuredHeight
    }

    private func singleLineContentHeight(for font: NSFont?) -> CGFloat {
        let font = font ?? NSFont.systemFont(ofSize: 15.5, weight: .regular)
        return ceil(layoutManager?.defaultLineHeight(for: font) ?? (font.ascender - font.descender + font.leading))
    }
}

private final class AgentSendButton: NSControl {
    var onPressed: (() -> Void)?

    private var isHovered = false {
        didSet {
            needsDisplay = true
        }
    }
    private var isPressed = false {
        didSet {
            needsDisplay = true
        }
    }
    private var trackingArea: NSTrackingArea?

    override var isEnabled: Bool {
        didSet {
            needsDisplay = true
        }
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = nextTrackingArea
        addTrackingArea(nextTrackingArea)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            return
        }

        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            isPressed = false
        }

        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }

        onPressed?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let diameter = max(min(bounds.width, bounds.height) - 1, 1)
        let rect = NSRect(
            x: bounds.midX - diameter * 0.5,
            y: bounds.midY - diameter * 0.5,
            width: diameter,
            height: diameter
        )
        let buttonPath = NSBezierPath(ovalIn: rect)

        if isEnabled, isHovered || isPressed {
            let glowRect = rect.insetBy(dx: -2.5, dy: -2.5)
            let glowPath = NSBezierPath(ovalIn: glowRect)
            NSColor(white: 1, alpha: isPressed ? 0.16 : 0.10).setFill()
            glowPath.fill()
        }

        let fillColor: NSColor
        if isEnabled {
            fillColor = NSColor(white: isPressed ? 0.86 : (isHovered ? 0.96 : 0.91), alpha: 1)
        } else {
            fillColor = NSColor(white: 0.31, alpha: 0.48)
        }
        fillColor.setFill()
        buttonPath.fill()

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: center.x - 5.8, y: center.y - 7.2))
        arrow.line(to: CGPoint(x: center.x + 6.8, y: center.y))
        arrow.line(to: CGPoint(x: center.x - 5.8, y: center.y + 7.2))
        arrow.line(to: CGPoint(x: center.x - 2.5, y: center.y))
        arrow.close()

        NSColor(white: isEnabled ? 0.10 : 0.64, alpha: isEnabled ? 0.92 : 0.70).setFill()
        arrow.fill()
    }
}
