import Foundation

struct DecodedAudioBuffer: Sendable {
    let url: URL
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let samplesByChannel: [[Float]]

    var duration: TimeInterval {
        guard sampleRate > 0 else {
            return 0
        }

        return Double(frameCount) / sampleRate
    }

    var formattedSummary: String {
        let sampleRateText = Self.formatSampleRate(sampleRate)
        let channelText = channelCount == 1 ? "mono" : "\(channelCount) channels"
        let frameText = NumberFormatter.localizedString(
            from: NSNumber(value: frameCount),
            number: .decimal
        )

        return "\(sampleRateText) - \(channelText) - \(frameText) frames decoded"
    }

    private static func formatSampleRate(_ sampleRate: Double) -> String {
        if sampleRate >= 1_000 {
            return String(format: "%.1f kHz", sampleRate / 1_000)
        }

        return String(format: "%.0f Hz", sampleRate)
    }
}
