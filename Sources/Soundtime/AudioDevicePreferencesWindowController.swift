import AppKit
import CoreAudio

@MainActor
final class AudioDevicePreferencesWindowController: NSWindowController {
    private let inputPopup = NSPopUpButton()
    private let outputPopup = NSPopUpButton()

    init() {
        let contentView = NSView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Soundtime Preferences"
        window.contentView = contentView
        window.center()
        super.init(window: window)
        configure(contentView: contentView)
        reloadDevices()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        reloadDevices()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    private func configure(contentView: NSView) {
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor

        let titleLabel = NSTextField(labelWithString: "Audio Devices")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .labelColor

        let inputLabel = makeLabel("Input")
        let outputLabel = makeLabel("Output")

        inputPopup.target = self
        inputPopup.action = #selector(inputChanged(_:))
        outputPopup.target = self
        outputPopup.action = #selector(outputChanged(_:))
        inputPopup.translatesAutoresizingMaskIntoConstraints = false
        outputPopup.translatesAutoresizingMaskIntoConstraints = false

        let formStack = NSStackView()
        formStack.orientation = .vertical
        formStack.spacing = 14
        formStack.translatesAutoresizingMaskIntoConstraints = false

        formStack.addArrangedSubview(makeRow(label: inputLabel, popup: inputPopup))
        formStack.addArrangedSubview(makeRow(label: outputLabel, popup: outputPopup))

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)
        contentView.addSubview(formStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),

            formStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
            formStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            formStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
        ])
    }

    private func makeLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 0.72, alpha: 1)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeRow(label: NSTextField, popup: NSPopUpButton) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(popup)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 32),

            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 72),

            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 14),
            popup.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return row
    }

    private func reloadDevices() {
        reload(
            popup: inputPopup,
            devices: AudioDeviceRegistry.inputDevices(),
            selectedDeviceID: AudioDevicePreferences.shared.explicitlySelectedInputDeviceID(),
            defaultTitle: "System Default Input"
        )
        reload(
            popup: outputPopup,
            devices: AudioDeviceRegistry.outputDevices(),
            selectedDeviceID: AudioDevicePreferences.shared.explicitlySelectedOutputDeviceID(),
            defaultTitle: "System Default Output"
        )
    }

    private func reload(
        popup: NSPopUpButton,
        devices: [AudioDeviceInfo],
        selectedDeviceID: AudioDeviceID?,
        defaultTitle: String
    ) {
        popup.removeAllItems()
        popup.addItem(withTitle: defaultTitle)
        popup.lastItem?.tag = -1

        for device in devices {
            popup.addItem(withTitle: device.name)
            popup.lastItem?.tag = Int(device.id)
        }

        if let selectedDeviceID {
            popup.selectItem(withTag: Int(selectedDeviceID))
        } else {
            popup.selectItem(withTag: -1)
        }
    }

    @objc private func inputChanged(_ sender: NSPopUpButton) {
        AudioDevicePreferences.shared.setSelectedInputDeviceID(deviceID(from: sender))
    }

    @objc private func outputChanged(_ sender: NSPopUpButton) {
        AudioDevicePreferences.shared.setSelectedOutputDeviceID(deviceID(from: sender))
    }

    private func deviceID(from popup: NSPopUpButton) -> AudioDeviceID? {
        let tag = popup.selectedItem?.tag ?? -1
        guard tag > 0 else {
            return nil
        }

        return AudioDeviceID(tag)
    }
}
