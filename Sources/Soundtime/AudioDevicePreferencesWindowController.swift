import AppKit
import CoreAudio

@MainActor
final class AudioDevicePreferencesWindowController: NSWindowController {
    private let inputPopup = NSPopUpButton()
    private let outputPopup = NSPopUpButton()
    private let audioShakeAPIKeyField = NSSecureTextField()
    private let audioShakeAPIKeyStatusLabel = NSTextField(labelWithString: "")

    init() {
        let contentView = NSView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 330),
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
        reloadAudioShakeAPIKey()
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
        let apiTitleLabel = NSTextField(labelWithString: "Audio Processing")
        apiTitleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        apiTitleLabel.textColor = .labelColor
        apiTitleLabel.translatesAutoresizingMaskIntoConstraints = false

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

        audioShakeAPIKeyField.placeholderString = "AudioShake API key"
        audioShakeAPIKeyField.target = self
        audioShakeAPIKeyField.action = #selector(saveAudioShakeAPIKey(_:))
        audioShakeAPIKeyField.translatesAutoresizingMaskIntoConstraints = false

        let saveAPIKeyButton = NSButton(title: "Save", target: self, action: #selector(saveAudioShakeAPIKey(_:)))
        saveAPIKeyButton.bezelStyle = .rounded
        saveAPIKeyButton.translatesAutoresizingMaskIntoConstraints = false

        let clearAPIKeyButton = NSButton(title: "Clear", target: self, action: #selector(clearAudioShakeAPIKey(_:)))
        clearAPIKeyButton.bezelStyle = .rounded
        clearAPIKeyButton.translatesAutoresizingMaskIntoConstraints = false

        audioShakeAPIKeyStatusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        audioShakeAPIKeyStatusLabel.textColor = NSColor(white: 0.58, alpha: 1)
        audioShakeAPIKeyStatusLabel.lineBreakMode = .byWordWrapping
        audioShakeAPIKeyStatusLabel.maximumNumberOfLines = 2
        audioShakeAPIKeyStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let apiKeyLabel = makeLabel("AudioShake")
        let apiKeyRow = makeAPIKeyRow(
            label: apiKeyLabel,
            field: audioShakeAPIKeyField,
            saveButton: saveAPIKeyButton,
            clearButton: clearAPIKeyButton
        )

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)
        contentView.addSubview(formStack)
        contentView.addSubview(apiTitleLabel)
        contentView.addSubview(apiKeyRow)
        contentView.addSubview(audioShakeAPIKeyStatusLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),

            formStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
            formStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            formStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),

            apiTitleLabel.topAnchor.constraint(equalTo: formStack.bottomAnchor, constant: 30),
            apiTitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            apiTitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),

            apiKeyRow.topAnchor.constraint(equalTo: apiTitleLabel.bottomAnchor, constant: 20),
            apiKeyRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            apiKeyRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),

            audioShakeAPIKeyStatusLabel.topAnchor.constraint(equalTo: apiKeyRow.bottomAnchor, constant: 8),
            audioShakeAPIKeyStatusLabel.leadingAnchor.constraint(equalTo: audioShakeAPIKeyField.leadingAnchor),
            audioShakeAPIKeyStatusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
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

    private func makeAPIKeyRow(
        label: NSTextField,
        field: NSSecureTextField,
        saveButton: NSButton,
        clearButton: NSButton
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(field)
        row.addSubview(saveButton)
        row.addSubview(clearButton)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 32),

            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 92),

            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 14),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            saveButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 10),
            saveButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: 68),

            clearButton.leadingAnchor.constraint(equalTo: saveButton.trailingAnchor, constant: 8),
            clearButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            clearButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 68),
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

    private func reloadAudioShakeAPIKey() {
        do {
            if let apiKey = try AudioProcessingCredentials.storedAudioShakeAPIKey() {
                audioShakeAPIKeyField.stringValue = apiKey
                audioShakeAPIKeyStatusLabel.stringValue = "AudioShake denoise is enabled."
            } else {
                audioShakeAPIKeyField.stringValue = ""
                audioShakeAPIKeyStatusLabel.stringValue = "No AudioShake key saved. Denoise will use the local fallback provider."
            }
        } catch {
            audioShakeAPIKeyStatusLabel.stringValue = error.localizedDescription
        }
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

    @objc private func saveAudioShakeAPIKey(_ sender: Any?) {
        do {
            try AudioProcessingCredentials.setStoredAudioShakeAPIKey(audioShakeAPIKeyField.stringValue)
            reloadAudioShakeAPIKey()
        } catch {
            audioShakeAPIKeyStatusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func clearAudioShakeAPIKey(_ sender: Any?) {
        do {
            try AudioProcessingCredentials.deleteStoredAudioShakeAPIKey()
            reloadAudioShakeAPIKey()
        } catch {
            audioShakeAPIKeyStatusLabel.stringValue = error.localizedDescription
        }
    }

    private func deviceID(from popup: NSPopUpButton) -> AudioDeviceID? {
        let tag = popup.selectedItem?.tag ?? -1
        guard tag > 0 else {
            return nil
        }

        return AudioDeviceID(tag)
    }
}
