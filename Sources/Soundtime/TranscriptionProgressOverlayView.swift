import AppKit

@MainActor
final class TranscriptionProgressOverlayView: NSView {
    var onCancel: (() -> Void)?

    private let panelView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 0.96).cgColor
        view.layer?.cornerRadius = 14
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.34
        view.layer?.shadowRadius = 20
        view.layer?.shadowOffset = CGSize(width: 0, height: -6)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Transcribing")
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let stageLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Preparing transcription")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.70)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let detailLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.46)
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
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else {
            return nil
        }

        let panelPoint = panelView.convert(point, from: self)
        guard panelView.bounds.contains(panelPoint) else {
            return nil
        }

        return panelView.hitTest(panelPoint) ?? panelView
    }

    func show(job: TranscriptionJob) {
        update(job: job)
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

    func update(job: TranscriptionJob) {
        titleLabel.stringValue = "Transcribing \(job.trackName)"
        stageLabel.stringValue = Self.capitalizedFirstLetter(job.message)
        detailLabel.stringValue = "\(job.providerDisplayName) • \(Self.formattedDuration(job.sourceDuration))"

        switch job.status {
        case .canceling:
            showCanceling()
        case .completed:
            progressIndicator.isIndeterminate = false
            progressIndicator.stopAnimation(nil)
            progressIndicator.doubleValue = 1
            cancelButton.isEnabled = false
        case .failed, .canceled, .stale:
            progressIndicator.isIndeterminate = false
            progressIndicator.stopAnimation(nil)
            cancelButton.isEnabled = false
        case .preparing, .running:
            cancelButton.isEnabled = true
            cancelButton.title = "Cancel"
            if let fractionCompleted = job.fractionCompleted {
                progressIndicator.isIndeterminate = false
                progressIndicator.stopAnimation(nil)
                progressIndicator.doubleValue = min(max(fractionCompleted, 0), 1)
            } else {
                progressIndicator.isIndeterminate = true
                progressIndicator.startAnimation(nil)
            }
        }
    }

    func showCanceling() {
        cancelButton.isEnabled = false
        cancelButton.title = "Canceling..."
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        stageLabel.stringValue = "Canceling transcription"
    }

    func hide(animated: Bool = true) {
        progressIndicator.stopAnimation(nil)
        guard animated else {
            isHidden = true
            alphaValue = 0
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.isHidden = true
                self?.alphaValue = 0
            }
        }
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        alphaValue = 0

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))

        addSubview(panelView)
        panelView.addSubview(titleLabel)
        panelView.addSubview(stageLabel)
        panelView.addSubview(detailLabel)
        panelView.addSubview(progressIndicator)
        panelView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            panelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -94),
            panelView.widthAnchor.constraint(equalToConstant: 420),

            titleLabel.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -14),

            stageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            stageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stageLabel.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -22),

            detailLabel.topAnchor.constraint(equalTo: stageLabel.bottomAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -22),

            progressIndicator.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 14),
            progressIndicator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -22),
            progressIndicator.heightAnchor.constraint(equalToConstant: 8),
            progressIndicator.bottomAnchor.constraint(equalTo: panelView.bottomAnchor, constant: -18),

            cancelButton.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -18),
            cancelButton.widthAnchor.constraint(equalToConstant: 88),
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

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}
