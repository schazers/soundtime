import Foundation

enum WAVImportPreviewPolicy {
    struct Level: Equatable, Sendable {
        let targetBinCount: Int
        let samplesPerBin: Int
    }

    // This comfortably exceeds the horizontal resolution of the timeline while
    // remaining cheap enough to build during drag hover on a cold cache.
    static let immediate = Level(targetBinCount: 8_192, samplesPerBin: 16)

    // Import refinement is deliberately bounded. Deeper zoom detail belongs to
    // viewport-driven waveform tiles, not repeated whole-file import passes.
    static let refinements = [
        Level(targetBinCount: 32_768, samplesPerBin: 24),
        Level(targetBinCount: 131_072, samplesPerBin: 32),
    ]

    static let allLevels = [immediate] + refinements
    static let readyStatus = "ready"

    static func estimatedSampledFrameCount(sourceFrameCount: Int) -> Int {
        guard sourceFrameCount > 0 else {
            return 0
        }
        return allLevels.reduce(into: 0) { total, level in
            let binCount = min(level.targetBinCount, sourceFrameCount)
            total += binCount * max(level.samplesPerBin, 16)
        }
    }
}
