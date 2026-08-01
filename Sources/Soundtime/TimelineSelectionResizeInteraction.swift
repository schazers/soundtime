import Foundation

enum TimelineSelectionEndpoint: Sendable, Equatable {
    case start
    case end
}

enum TimelineSelectionResizeInteraction {
    static func hitRect(
        endpointX: CGFloat,
        verticalRect: CGRect,
        viewportWidth: CGFloat,
        hitWidth: CGFloat
    ) -> CGRect? {
        guard
            viewportWidth > 0,
            verticalRect.height > 0,
            endpointX >= 0,
            endpointX <= viewportWidth
        else {
            return nil
        }

        let width = min(max(hitWidth, 1), viewportWidth)
        return CGRect(
            x: min(max(endpointX - width * 0.5, 0), max(viewportWidth - width, 0)),
            y: verticalRect.minY,
            width: width,
            height: verticalRect.height
        )
    }

    static func endpoint(
        at point: CGPoint,
        startX: CGFloat?,
        endX: CGFloat?,
        verticalRect: CGRect,
        viewportWidth: CGFloat,
        hitWidth: CGFloat
    ) -> TimelineSelectionEndpoint? {
        let candidates: [(endpoint: TimelineSelectionEndpoint, x: CGFloat?)]
        if let startX, let endX {
            candidates = [
                (.start, min(startX, endX)),
                (.end, max(startX, endX)),
            ]
        } else {
            candidates = [
                (.start, startX),
                (.end, endX),
            ]
        }

        return candidates
            .compactMap { candidate -> (
                endpoint: TimelineSelectionEndpoint,
                distance: CGFloat
            )? in
                guard
                    let endpointX = candidate.x,
                    let rect = hitRect(
                        endpointX: endpointX,
                        verticalRect: verticalRect,
                        viewportWidth: viewportWidth,
                        hitWidth: hitWidth
                    ),
                    rect.contains(point)
                else {
                    return nil
                }

                return (
                    endpoint: candidate.endpoint,
                    distance: abs(point.x - endpointX)
                )
            }
            .min { $0.distance < $1.distance }?
            .endpoint
    }

    static func endpoint(
        nearX x: CGFloat,
        startX: CGFloat,
        endX: CGFloat,
        hitWidth: CGFloat
    ) -> TimelineSelectionEndpoint? {
        let candidates: [(endpoint: TimelineSelectionEndpoint, x: CGFloat)] = [
            (.start, min(startX, endX)),
            (.end, max(startX, endX)),
        ]
        let maximumDistance = max(hitWidth, 1) * 0.5
        return candidates
            .map { candidate in
                (endpoint: candidate.endpoint, distance: abs(x - candidate.x))
            }
            .filter { $0.distance <= maximumDistance }
            .min { $0.distance < $1.distance }?
            .endpoint
    }

    static func fixedProgress(
        for endpoint: TimelineSelectionEndpoint,
        selection: TimelineSelection
    ) -> Double {
        switch endpoint {
        case .start:
            return selection.endProgress
        case .end:
            return selection.startProgress
        }
    }

    static func resizedSelection(
        _ selection: TimelineSelection,
        moving endpoint: TimelineSelectionEndpoint,
        to progress: Double
    ) -> TimelineSelection {
        TimelineSelection(
            startProgress: fixedProgress(for: endpoint, selection: selection),
            endProgress: progress,
            trackID: selection.trackID
        )
    }
}
