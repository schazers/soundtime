import Foundation

struct WaveformOverview: Sendable {
    struct Bin: Sendable {
        let minimumSample: Float
        let maximumSample: Float
    }

    let duration: TimeInterval
    let bins: [Bin]

    var isEmpty: Bool {
        bins.isEmpty
    }
}
