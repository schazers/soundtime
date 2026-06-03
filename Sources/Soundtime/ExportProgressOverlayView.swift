import AppKit

@MainActor
final class ExportProgressOverlayView: NSView {
    var onDismiss: (() -> Void)?

    private var isFinished = false
    private var presentationGeneration = 0

    private let panelView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.layer?.cornerRadius = 8
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.layer?.borderWidth = 1
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Exporting...")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.alignment = .center
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let progressBar = ExportProgressBarView()

    private let okButton: NSButton = {
        let button = NSButton(title: "OK", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
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

    func showExporting() {
        isFinished = false
        presentationGeneration += 1
        isHidden = false
        statusLabel.stringValue = "Exporting..."
        progressBar.progress = 0
        okButton.isHidden = true
    }

    func updateProgress(_ progress: Double) {
        guard !isFinished else {
            return
        }

        progressBar.progress = progress
    }

    func showComplete() {
        isFinished = true
        presentationGeneration += 1
        let generation = presentationGeneration
        progressBar.progress = 1
        okButton.isHidden = true
        okButton.isEnabled = false

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard
                let self,
                self.isFinished,
                self.presentationGeneration == generation
            else {
                return
            }

            self.statusLabel.stringValue = "Export complete."
            self.okButton.isHidden = false
            self.okButton.isEnabled = true
            self.window?.makeFirstResponder(self.okButton)
        }
    }

    func showFailure(_ message: String) {
        isFinished = true
        presentationGeneration += 1
        statusLabel.stringValue = message
        okButton.isHidden = false
        okButton.isEnabled = true
        window?.makeFirstResponder(okButton)
    }

    private func configure() {
        isHidden = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        okButton.target = self
        okButton.action = #selector(dismiss)

        addSubview(panelView)
        panelView.addSubview(statusLabel)
        panelView.addSubview(progressBar)
        panelView.addSubview(okButton)

        NSLayoutConstraint.activate([
            panelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            panelView.widthAnchor.constraint(equalToConstant: 340),

            statusLabel.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 22),
            statusLabel.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 22),
            statusLabel.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -22),

            progressBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            progressBar.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 26),
            progressBar.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -26),
            progressBar.heightAnchor.constraint(equalToConstant: 10),

            okButton.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 20),
            okButton.centerXAnchor.constraint(equalTo: panelView.centerXAnchor),
            okButton.bottomAnchor.constraint(equalTo: panelView.bottomAnchor, constant: -18),
            okButton.widthAnchor.constraint(equalToConstant: 84),
        ])
    }

    @objc private func dismiss() {
        isHidden = true
        onDismiss?()
    }
}

@MainActor
private final class ExportProgressBarView: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private var clampedProgress: Double = 0

    var progress: Double {
        get {
            clampedProgress
        }
        set {
            clampedProgress = min(max(newValue, 0), 1)
            updateFillLayerFrame()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        trackLayer.cornerRadius = bounds.height / 2
        fillLayer.cornerRadius = bounds.height / 2
        updateFillLayerFrame()
        CATransaction.commit()
    }

    private func configure() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        trackLayer.backgroundColor = NSColor.controlBackgroundColor.cgColor
        fillLayer.backgroundColor = NSColor.systemTeal.cgColor

        layer?.addSublayer(trackLayer)
        trackLayer.addSublayer(fillLayer)
    }

    private func updateFillLayerFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width * clampedProgress,
            height: bounds.height
        )
        CATransaction.commit()
    }
}
