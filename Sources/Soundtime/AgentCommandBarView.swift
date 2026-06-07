import AppKit

@MainActor
final class AgentCommandBarView: NSView, NSTextViewDelegate {
    var onSubmit: ((String) -> Void)?
    var onBlurRequested: (() -> Void)?

    var presentationState: AgentCommandController.PresentationState = .idle {
        didSet {
            panelView.presentationState = presentationState
            updatePlaceholder()
        }
    }

    private let panelView = AgentCommandPanelView()
    private let textBackgroundView = AgentTextFieldBackgroundView()
    private let scrollView = NSScrollView()
    private let textView = AgentPromptTextView()
    private let placeholderLabel = AgentPlaceholderLabel(labelWithString: "How can I help you?")
    private let sendButton = AgentSendButton()
    private var textHeightConstraint: NSLayoutConstraint?
    private var outsideClickMonitor: Any?
    private var isTextFocused = false {
        didSet {
            panelView.isFocused = isTextFocused
            textBackgroundView.isFocused = isTextFocused
            updatePlaceholder()
        }
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var intrinsicContentSize: NSSize {
        let textHeight = textHeightConstraint?.constant ?? 46
        return NSSize(width: NSView.noIntrinsicMetric, height: textHeight + 22)
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
        syncTextViewFrame()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else {
            return nil
        }

        let textRect = convert(textBackgroundView.bounds, from: textBackgroundView).insetBy(dx: -2, dy: -2)
        let sendRect = convert(sendButton.bounds, from: sendButton).insetBy(dx: -2, dy: -2)
        guard textRect.contains(point) || sendRect.contains(point) else {
            return nil
        }

        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let textRect = convert(textBackgroundView.bounds, from: textBackgroundView).insetBy(dx: -2, dy: -2)
        let scrollRect = convert(scrollView.bounds, from: scrollView)
        if textRect.contains(point), scrollRect.contains(point) == false {
            focusPrompt()
            return
        }

        super.mouseDown(with: event)
    }

    func focusPrompt() {
        window?.makeFirstResponder(textView)
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

        panelView.translatesAutoresizingMaskIntoConstraints = false
        textBackgroundView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        textView.frame = NSRect(x: 0, y: 0, width: 1, height: 46)
        textView.autoresizingMask = [.width]

        textView.delegate = self
        textView.onSubmitShortcut = { [weak self] in
            self?.submit()
        }
        textView.onCancelShortcut = { [weak self] in
            self?.blurPrompt()
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
        panelView.onMouseDown = { [weak self] event in
            guard let self else {
                return false
            }

            let point = self.convert(event.locationInWindow, from: nil)
            let textRect = self.convert(self.textBackgroundView.bounds, from: self.textBackgroundView).insetBy(dx: -2, dy: -2)
            guard textRect.contains(point) else {
                return false
            }

            self.focusPrompt()
            return true
        }

        addSubview(panelView)
        panelView.addSubview(textBackgroundView)
        panelView.addSubview(scrollView)
        panelView.addSubview(placeholderLabel)
        panelView.addSubview(sendButton)

        let textHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 46)
        self.textHeightConstraint = textHeightConstraint

        NSLayoutConstraint.activate([
            panelView.topAnchor.constraint(equalTo: topAnchor),
            panelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            panelView.trailingAnchor.constraint(equalTo: trailingAnchor),
            panelView.bottomAnchor.constraint(equalTo: bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 11),
            scrollView.leadingAnchor.constraint(equalTo: textBackgroundView.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: textBackgroundView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor, constant: -11),
            textHeightConstraint,

            textBackgroundView.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: -2),
            textBackgroundView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 10),
            textBackgroundView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -12),
            textBackgroundView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 2),

            placeholderLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: textBackgroundView.centerYAnchor),

            sendButton.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -10),
            sendButton.topAnchor.constraint(equalTo: textBackgroundView.topAnchor),
            sendButton.bottomAnchor.constraint(equalTo: textBackgroundView.bottomAnchor),
            sendButton.widthAnchor.constraint(equalTo: sendButton.heightAnchor),
        ])

        updatePlaceholder()
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
        guard let textContainer = textView.textContainer, scrollView.bounds.width > 0 else {
            return
        }

        textContainer.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.layoutManager?.ensureLayout(for: textContainer)
        let usedHeight = textView.layoutManager?.usedRect(for: textContainer).height ?? 22
        let nextHeight = min(max(ceil(usedHeight) + 20, 46), 148)
        if abs((textHeightConstraint?.constant ?? 0) - nextHeight) > 0.5 {
            textHeightConstraint?.constant = nextHeight
            scrollView.hasVerticalScroller = nextHeight >= 148
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
        syncTextViewFrame(height: nextHeight)
    }

    private func syncTextViewFrame(height: CGFloat? = nil) {
        let contentSize = scrollView.contentSize
        guard contentSize.width > 0 else {
            return
        }

        let nextHeight = max(height ?? textHeightConstraint?.constant ?? contentSize.height, contentSize.height)
        let nextFrame = NSRect(
            x: 0,
            y: 0,
            width: contentSize.width,
            height: nextHeight
        )
        if textView.frame != nextFrame {
            textView.frame = nextFrame
        }
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

        let point = convert(event.locationInWindow, from: nil)
        let promptRect = convert(textBackgroundView.bounds, from: textBackgroundView).insetBy(dx: -2, dy: -2)
        if promptRect.contains(point) {
            return
        }

        blurPrompt()
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

@MainActor
private final class AgentPromptTextView: NSTextView {
    var onSubmitShortcut: (() -> Void)?
    var onCancelShortcut: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
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
        textContainerInset = NSSize(width: 0, height: 15)
        font = .systemFont(ofSize: 15.5, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        paragraphStyle.paragraphSpacing = 0
        defaultParagraphStyle = paragraphStyle
        typingAttributes = [
            .font: NSFont.systemFont(ofSize: 15.5, weight: .regular),
            .foregroundColor: NSColor(white: 0.94, alpha: 1),
            .paragraphStyle: paragraphStyle,
        ]
        textColor = NSColor(white: 0.94, alpha: 1)
        insertionPointColor = NSColor(calibratedRed: 0.42, green: 0.98, blue: 1.0, alpha: 1)
    }
}

@MainActor
private final class AgentCommandPanelView: NSView {
    var onMouseDown: ((NSEvent) -> Bool)?

    var isFocused = false {
        didSet {
            needsDisplay = true
        }
    }

    var presentationState: AgentCommandController.PresentationState = .idle {
        didSet {
            needsDisplay = true
        }
    }

    var animationTime = CACurrentMediaTime() {
        didSet {
            needsDisplay = true
        }
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        if onMouseDown?(event) == true {
            return
        }

        super.mouseDown(with: event)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }
}

@MainActor
private final class AgentTextFieldBackgroundView: NSView {
    var isFocused = false {
        didSet {
            needsDisplay = true
        }
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.masksToBounds = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius: CGFloat = 25
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSColor(white: 0.16, alpha: 0.92).setFill()
        path.fill()

        guard isFocused else {
            return
        }

        NSColor(white: 1, alpha: 0.70).setStroke()
        path.lineWidth = 1.4
        path.stroke()
    }
}

@MainActor
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
        arrow.move(to: CGPoint(x: center.x - 5.2, y: center.y - 6.4))
        arrow.line(to: CGPoint(x: center.x + 6.0, y: center.y))
        arrow.line(to: CGPoint(x: center.x - 5.2, y: center.y + 6.4))
        arrow.line(to: CGPoint(x: center.x - 2.3, y: center.y))
        arrow.close()

        NSColor(white: isEnabled ? 0.10 : 0.64, alpha: isEnabled ? 0.92 : 0.70).setFill()
        arrow.fill()
    }
}
