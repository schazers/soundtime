import AppKit

final class WorkspaceView: NSView {
    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Soundtime")
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = NSColor.labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let timelineSurface = TimelinePlaceholderView()

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
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        timelineSurface.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(timelineSurface)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),

            timelineSurface.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            timelineSurface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            timelineSurface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            timelineSurface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
        ])
    }
}
