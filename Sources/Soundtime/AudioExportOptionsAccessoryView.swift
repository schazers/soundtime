import AppKit

@MainActor
final class AudioExportOptionsAccessoryView: NSView {
    private let wavEncodingPopup = NSPopUpButton()
    private let compressedQualityPopup = NSPopUpButton()
    private let stemInclusionPopup = NSPopUpButton()
    private let stemGainPopup = NSPopUpButton()

    var wavEncoding: AudioExportWAVEncoding {
        AudioExportWAVEncoding.allCases[
            min(max(wavEncodingPopup.indexOfSelectedItem, 0), AudioExportWAVEncoding.allCases.count - 1)
        ]
    }

    var stemOptions: AudioExportStemOptions {
        AudioExportStemOptions(
            trackInclusion: stemInclusionPopup.indexOfSelectedItem == 1 ?
                .audibleTracks :
                .allTracks,
            gainPosition: stemGainPopup.indexOfSelectedItem == 1 ?
                .preFader :
                .postFader
        )
    }

    var compressedQuality: AudioExportCompressedQuality {
        AudioExportCompressedQuality.allCases[
            min(
                max(compressedQualityPopup.indexOfSelectedItem, 0),
                AudioExportCompressedQuality.allCases.count - 1
            )
        ]
    }

    init(includesCompressedOptions: Bool, includesStemOptions: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        wavEncodingPopup.addItems(
            withTitles: AudioExportWAVEncoding.allCases.map(\.displayName)
        )
        wavEncodingPopup.selectItem(
            at: AudioExportWAVEncoding.allCases.firstIndex(of: .pcm24) ?? 0
        )

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.addArrangedSubview(
            optionRow(label: "WAV encoding", control: wavEncodingPopup)
        )

        if includesCompressedOptions {
            compressedQualityPopup.addItems(
                withTitles: AudioExportCompressedQuality.allCases.map(\.displayName)
            )
            compressedQualityPopup.selectItem(
                at: AudioExportCompressedQuality.allCases.firstIndex(of: .standard) ?? 0
            )
            stack.addArrangedSubview(
                optionRow(label: "Compression", control: compressedQualityPopup)
            )
        }

        if includesStemOptions {
            stemInclusionPopup.addItems(withTitles: ["All tracks", "Audible tracks"])
            stemGainPopup.addItems(withTitles: ["Post-fader", "Pre-fader"])
            stack.addArrangedSubview(
                optionRow(label: "Stem tracks", control: stemInclusionPopup)
            )
            stack.addArrangedSubview(
                optionRow(label: "Stem gain", control: stemGainPopup)
            )
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 330),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func optionRow(label: String, control: NSView) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12, weight: .medium)
        labelField.textColor = .secondaryLabelColor
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.widthAnchor.constraint(equalToConstant: 92).isActive = true

        let row = NSStackView(views: [labelField, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        return row
    }
}
