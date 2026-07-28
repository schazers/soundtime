import AppKit

@MainActor
final class AudioExportWindowController: NSWindowController, NSWindowDelegate {
    var onCancel: (() -> Void)?
    var onClosed: (() -> Void)?

    private let titleField = NSTextField(labelWithString: "Export")
    private let subtitleField = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "0%")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal", target: nil, action: nil)
    private var outputURLs: [URL] = []

    init() {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 210))
        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Soundtime Export"
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configure(contentView: contentView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(progress: AudioExportProgress) {
        titleField.stringValue = "\(progress.request.scope.displayName) Export"
        subtitleField.stringValue = progress.message
        progressIndicator.doubleValue = min(max(progress.fractionCompleted, 0), 1)
        progressLabel.stringValue = String(format: "%.0f%%", progressIndicator.doubleValue * 100)
        outputURLs = progress.outputURLs

        switch progress.stage {
        case .completed:
            cancelButton.title = "Close"
            revealButton.isHidden = outputURLs.isEmpty
        case .canceled, .failed:
            cancelButton.title = "Close"
            revealButton.isHidden = true
        case .preparing, .rendering, .encoding, .finishing:
            cancelButton.title = "Cancel"
            revealButton.isHidden = true
        }
    }

    func show(relativeTo parentWindow: NSWindow?) {
        if let parentWindow, let window {
            parentWindow.addChildWindow(window, ordered: .above)
            let parentFrame = parentWindow.frame
            let frame = window.frame
            window.setFrameOrigin(NSPoint(
                x: parentFrame.midX - frame.width * 0.5,
                y: parentFrame.midY - frame.height * 0.5
            ))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window, let parent = window.parent {
            parent.removeChildWindow(window)
        }
        onClosed?()
    }

    private func configure(contentView: NSView) {
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor

        [titleField, subtitleField, progressIndicator, progressLabel, cancelButton, revealButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        titleField.font = .systemFont(ofSize: 22, weight: .semibold)
        titleField.textColor = NSColor(white: 0.92, alpha: 1)
        subtitleField.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleField.textColor = NSColor(white: 0.66, alpha: 1)
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        progressLabel.textColor = NSColor(white: 0.82, alpha: 1)

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.controlSize = .regular

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        revealButton.target = self
        revealButton.action = #selector(revealPressed(_:))
        revealButton.isHidden = true

        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            titleField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -28),

            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 8),
            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),

            progressIndicator.topAnchor.constraint(equalTo: subtitleField.bottomAnchor, constant: 28),
            progressIndicator.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: progressLabel.leadingAnchor, constant: -12),

            progressLabel.centerYAnchor.constraint(equalTo: progressIndicator.centerYAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            progressLabel.widthAnchor.constraint(equalToConstant: 48),

            revealButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -10),
            revealButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),
            revealButton.widthAnchor.constraint(equalToConstant: 92),

            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),
            cancelButton.widthAnchor.constraint(equalToConstant: 92),
        ])
    }

    @objc private func cancelPressed(_ sender: Any?) {
        if cancelButton.title == "Close" {
            close()
            return
        }
        onCancel?()
    }

    @objc private func revealPressed(_ sender: Any?) {
        guard !outputURLs.isEmpty else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(outputURLs)
    }
}
