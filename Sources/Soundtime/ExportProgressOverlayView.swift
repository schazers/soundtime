import AppKit

@MainActor
final class ExportProgressOverlayView: NSView {
    var onDismiss: (() -> Void)?

    private var isFinished = false

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

    private let progressIndicator: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.doubleValue = 0
        indicator.controlSize = .regular
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

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
        isHidden = false
        statusLabel.stringValue = "Exporting..."
        progressIndicator.doubleValue = 0
        okButton.isHidden = true
    }

    func updateProgress(_ progress: Double) {
        guard !isFinished else {
            return
        }

        progressIndicator.doubleValue = min(max(progress, 0), 1)
    }

    func showComplete() {
        isFinished = true
        statusLabel.stringValue = "Export complete."
        progressIndicator.doubleValue = 1
        okButton.isHidden = false
        window?.makeFirstResponder(okButton)
    }

    func showFailure(_ message: String) {
        isFinished = true
        statusLabel.stringValue = message
        okButton.isHidden = false
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
        panelView.addSubview(progressIndicator)
        panelView.addSubview(okButton)

        NSLayoutConstraint.activate([
            panelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            panelView.widthAnchor.constraint(equalToConstant: 340),

            statusLabel.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 22),
            statusLabel.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 22),
            statusLabel.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -22),

            progressIndicator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            progressIndicator.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 26),
            progressIndicator.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -26),

            okButton.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 20),
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
