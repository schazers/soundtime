import Foundation

enum TimelineEdgeAutoPan {
    static func normalizedVelocity(
        pointerX: CGFloat,
        viewportWidth: CGFloat,
        activationDistance: CGFloat
    ) -> Float {
        guard viewportWidth > 0, activationDistance > 0 else {
            return 0
        }

        let effectiveDistance = min(activationDistance, viewportWidth * 0.45)
        let leftDistance = pointerX
        let rightDistance = viewportWidth - pointerX
        let isCloserToLeft = leftDistance <= rightDistance
        let nearestDistance = isCloserToLeft ? leftDistance : rightDistance
        guard nearestDistance < effectiveDistance else {
            return 0
        }

        let proximity = Float(min(max(1 - nearestDistance / effectiveDistance, 0), 1))
        let easedProximity = proximity * proximity * (3 - 2 * proximity)
        return isCloserToLeft ? -easedProximity : easedProximity
    }

    static func progressDelta(
        normalizedVelocity: Float,
        viewportDurationProgress: Float,
        elapsedTime: CFTimeInterval,
        maximumViewportWidthsPerSecond: Float
    ) -> Float {
        normalizedVelocity *
            viewportDurationProgress *
            maximumViewportWidthsPerSecond *
            Float(max(elapsedTime, 0))
    }
}
