import Foundation

struct WAVFileInfo: Sendable {
    let url: URL
    let formatTag: UInt16
    let channelCount: Int
    let sampleRate: Double
    let blockAlign: Int
    let bitsPerSample: Int
    let dataRange: Range<Int>

    var frameCount: Int {
        dataRange.count / blockAlign
    }

    var duration: TimeInterval {
        guard sampleRate > 0 else {
            return 0
        }

        return Double(frameCount) / sampleRate
    }

    var supportsDecoding: Bool {
        (formatTag == 1 || formatTag == 3) && bitsPerSample % 8 == 0
    }

    var formattedSummary: String {
        let sampleRateText: String
        if sampleRate >= 1_000 {
            sampleRateText = String(format: "%.1f kHz", sampleRate / 1_000)
        } else {
            sampleRateText = String(format: "%.0f Hz", sampleRate)
        }

        let channelText = channelCount == 1 ? "mono" : "\(channelCount) channels"
        let frameText = NumberFormatter.localizedString(
            from: NSNumber(value: frameCount),
            number: .decimal
        )
        return "\(sampleRateText) - \(channelText) - \(frameText) frames"
    }
}

struct WAVPreviewImportResult: Sendable {
    let metadata: AudioFileMetadata
    let fileInfo: WAVFileInfo
    let waveformOverview: WaveformOverview
    let zeroCrossingProbe: WAVZeroCrossingProbe?
}
