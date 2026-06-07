import Foundation

struct TimelineClipBoundaryTrim: Equatable, Sendable {
    enum Edge: Sendable {
        case leading
        case trailing
    }

    let trackID: UUID
    let clipRange: TimelineRenderState.ClipRange
    let edge: Edge
    let targetProgress: Double
}
