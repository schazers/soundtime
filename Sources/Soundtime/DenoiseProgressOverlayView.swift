import AppKit

final class DenoiseProgressOverlayView: NSView {
    var onCancel: (() -> Void)?

    private let panelView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 0.98).cgColor
        view.layer?.cornerRadius = 14
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.42
        view.layer?.shadowRadius = 24
        view.layer?.shadowOffset = CGSize(width: 0, height: -8)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Denoising")
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let detailLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Preparing audio")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.68)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let progressIndicator: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.doubleValue = 0
        indicator.controlSize = .small
        indicator.style = .bar
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    private let cancelButton: NSButton = {
        let button = NSButton(title: "Cancel", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(point) else {
            return nil
        }

        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {}

    override func scrollWheel(with event: NSEvent) {}

    func show(trackName: String, providerName: String, title: String = "Denoising") {
        titleLabel.stringValue = title
        detailLabel.stringValue = Self.capitalizedFirstLetter("\(trackName) with \(providerName)")
        progressIndicator.doubleValue = 0.04
        progressIndicator.isIndeterminate = false
        cancelButton.isEnabled = true
        cancelButton.title = "Cancel"
        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func update(progress: AudioProcessingProgress) {
        detailLabel.stringValue = Self.capitalizedFirstLetter(progress.message)
        if let fractionCompleted = progress.fractionCompleted {
            progressIndicator.isIndeterminate = false
            progressIndicator.stopAnimation(nil)
            progressIndicator.doubleValue = min(max(fractionCompleted, 0), 1)
        } else {
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
        }
    }

    func showCanceling(message: String = "Canceling denoise") {
        cancelButton.isEnabled = false
        cancelButton.title = "Canceling..."
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        detailLabel.stringValue = message
    }

    func hide(animated: Bool = true) {
        progressIndicator.stopAnimation(nil)
        let completion = { [weak self] in
            self?.isHidden = true
            self?.alphaValue = 0
        }
        guard animated else {
            completion()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: {
            completion()
        }
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.20).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        alphaValue = 0

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))

        addSubview(panelView)
        panelView.addSubview(titleLabel)
        panelView.addSubview(detailLabel)
        panelView.addSubview(progressIndicator)
        panelView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            panelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            panelView.widthAnchor.constraint(equalToConstant: 360),

            titleLabel.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -24),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            detailLabel.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 24),
            detailLabel.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -24),

            progressIndicator.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 20),
            progressIndicator.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 30),
            progressIndicator.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -30),
            progressIndicator.heightAnchor.constraint(equalToConstant: 8),

            cancelButton.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 22),
            cancelButton.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -24),
            cancelButton.bottomAnchor.constraint(equalTo: panelView.bottomAnchor, constant: -20),
            cancelButton.widthAnchor.constraint(equalToConstant: 96),
        ])
    }

    @objc private func cancelPressed(_ sender: Any?) {
        onCancel?()
    }

    private static func capitalizedFirstLetter(_ string: String) -> String {
        guard let first = string.first else {
            return string
        }

        return String(first).uppercased() + string.dropFirst()
    }
}
