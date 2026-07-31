import Foundation

enum TimelineRegionCreationGesture {
    static let minimumHorizontalDragDistance: CGFloat = 3

    static func hasCrossedDragThreshold(anchorX: CGFloat, currentX: CGFloat) -> Bool {
        abs(currentX - anchorX) >= minimumHorizontalDragDistance
    }
}

enum TimelineSecondaryButtonGesture {
    static let minimumPanDistance = TimelineRegionCreationGesture.minimumHorizontalDragDistance

    static func hasCrossedPanThreshold(anchorX: CGFloat, currentX: CGFloat) -> Bool {
        abs(currentX - anchorX) >= minimumPanDistance
    }

    static func shouldPresentContextMenu(
        wasEligibleAtMouseDown: Bool,
        didPan: Bool
    ) -> Bool {
        wasEligibleAtMouseDown && !didPan
    }
}
