import Foundation

enum ShippabilityTimingBudgets {
    struct Budget {
        var warningMilliseconds: Double
        var failureMilliseconds: Double
    }

    // Measured inside debug `swift run` smoke processes, so this includes cold
    // AppKit/window-controller setup. First-frame waveform and playback
    // readiness have separate, much stricter budgets below.
    static let windowVisible = Budget(warningMilliseconds: 350, failureMilliseconds: 500)
    static let firstWaveformVisible = Budget(warningMilliseconds: 60, failureMilliseconds: 100)
    static let playbackReady = Budget(warningMilliseconds: 250, failureMilliseconds: 500)
    static let firstPlayCommand = Budget(warningMilliseconds: 10, failureMilliseconds: 18)
    static let clickToSeekVisual = Budget(warningMilliseconds: 8, failureMilliseconds: 16)
    static let selectionDragEdge = Budget(warningMilliseconds: 8, failureMilliseconds: 16)
    static let deleteAnimationStart = Budget(warningMilliseconds: 8, failureMilliseconds: 16)
    static let pasteAnimationStart = Budget(warningMilliseconds: 8, failureMilliseconds: 16)
    static let saveLatency = Budget(warningMilliseconds: 50, failureMilliseconds: 120)
    static let closeLatency = Budget(warningMilliseconds: 12, failureMilliseconds: 25)
}
