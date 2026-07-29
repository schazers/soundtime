import Foundation

enum MetalRendererInitialization {
    static let timelineQueue = DispatchQueue(
        label: "Soundtime.metal.timeline-initialization",
        qos: .userInitiated
    )
    static let auxiliaryQueue = DispatchQueue(
        label: "Soundtime.metal.auxiliary-initialization",
        qos: .utility
    )
}
