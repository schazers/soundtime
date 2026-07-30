import AppKit

struct ApplicationUpdateStatusPresentation: Equatable {
    enum Action: Equatable {
        case dismiss
        case installAndRestart
        case installOnQuit
    }

    var title: String
    var message: String
    var detail: String?
    var primaryButtonTitle: String
    var primaryAction: Action
    var secondaryButtonTitle: String?
    var secondaryAction: Action?

    static func make(for state: ApplicationUpdateState) -> ApplicationUpdateStatusPresentation? {
        switch state {
        case let .upToDate(current):
            return ApplicationUpdateStatusPresentation(
                title: "You're up to date!",
                message: "Soundtime \(current.fullDescription) is currently the newest version available.",
                detail: nil,
                primaryButtonTitle: "OK",
                primaryAction: .dismiss,
                secondaryButtonTitle: nil,
                secondaryAction: nil
            )
        case let .available(release), let .readyToInstall(release):
            return ApplicationUpdateStatusPresentation(
                title: "A new version is ready",
                message: "Soundtime \(release.version.fullDescription) is available.",
                detail: release.summary,
                primaryButtonTitle: "Install & Restart",
                primaryAction: .installAndRestart,
                secondaryButtonTitle: "Later",
                secondaryAction: .installOnQuit
            )
        case let .incompatible(release, reason):
            return ApplicationUpdateStatusPresentation(
                title: "This update requires a newer system",
                message: "Soundtime \(release.version.fullDescription) cannot be installed on this Mac.",
                detail: reason,
                primaryButtonTitle: "OK",
                primaryAction: .dismiss,
                secondaryButtonTitle: nil,
                secondaryAction: nil
            )
        case let .failed(failure):
            return ApplicationUpdateStatusPresentation(
                title: failure.title,
                message: failure.message,
                detail: failure.recoverySuggestion,
                primaryButtonTitle: "OK",
                primaryAction: .dismiss,
                secondaryButtonTitle: nil,
                secondaryAction: nil
            )
        case .idle, .checking, .downloading, .installing:
            return nil
        }
    }
}

@MainActor
final class ApplicationUpdateStatusWindowController: NSWindowController {
    var onAction: ((ApplicationUpdateStatusPresentation.Action) -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()
    private var presentation: ApplicationUpdateStatusPresentation?

    init() {
        let contentView = NSView()
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Soundtime Update"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(white: 0.11, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = contentView

        super.init(window: window)
        configure(contentView: contentView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present(
        _ presentation: ApplicationUpdateStatusPresentation,
        relativeTo parentWindow: NSWindow?
    ) {
        self.presentation = presentation
        apply(presentation)

        guard let window else {
            return
        }
        if window.sheetParent != nil || window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if let parentWindow, window.sheetParent == nil {
            parentWindow.beginSheet(window)
        } else {
            window.center()
            showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func configure(contentView: NSView) {
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor

        iconView.image = NSApplication.shared.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = NSColor(white: 0.96, alpha: 1)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        messageLabel.textColor = NSColor(white: 0.92, alpha: 1)
        messageLabel.maximumNumberOfLines = 3
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = NSColor(white: 0.68, alpha: 1)
        detailLabel.maximumNumberOfLines = 3
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        configureButton(primaryButton, title: "OK", action: #selector(primaryButtonPressed(_:)))
        configureButton(secondaryButton, title: "Later", action: #selector(secondaryButtonPressed(_:)))

        let textStack = NSStackView(views: [titleLabel, messageLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .centerX
        textStack.spacing = 14
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = NSStackView(views: [primaryButton, secondaryButton])
        buttonStack.orientation = .vertical
        buttonStack.alignment = .width
        buttonStack.spacing = 9
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(iconView)
        contentView.addSubview(textStack)
        contentView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 48),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96),

            textStack.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 26),
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 44),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -44),

            messageLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: buttonStack.topAnchor, constant: -20),

            buttonStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -36),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -28),

            primaryButton.heightAnchor.constraint(equalToConstant: 48),
            secondaryButton.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    private func configureButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 16, weight: .semibold)
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func apply(_ presentation: ApplicationUpdateStatusPresentation) {
        titleLabel.stringValue = presentation.title
        messageLabel.stringValue = presentation.message
        detailLabel.stringValue = presentation.detail ?? ""
        detailLabel.isHidden = presentation.detail?.isEmpty != false

        primaryButton.title = presentation.primaryButtonTitle
        primaryButton.keyEquivalent = "\r"

        secondaryButton.title = presentation.secondaryButtonTitle ?? ""
        secondaryButton.isHidden = presentation.secondaryButtonTitle == nil
        window?.defaultButtonCell = primaryButton.cell as? NSButtonCell
    }

    @objc private func primaryButtonPressed(_ sender: Any?) {
        guard let action = presentation?.primaryAction else {
            return
        }
        dismiss()
        onAction?(action)
    }

    @objc private func secondaryButtonPressed(_ sender: Any?) {
        guard let action = presentation?.secondaryAction else {
            return
        }
        dismiss()
        onAction?(action)
    }

    private func dismiss() {
        guard let window else {
            return
        }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }
}
