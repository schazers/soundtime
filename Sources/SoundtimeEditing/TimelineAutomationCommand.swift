import Foundation

public struct TimelineAutomationSelection: Equatable, Sendable {
    public var address: TimelineAutomationAddress?
    public var pointIDs: Set<UUID>
    public var anchorPointID: UUID?

    public init(
        address: TimelineAutomationAddress? = nil,
        pointIDs: Set<UUID> = [],
        anchorPointID: UUID? = nil
    ) {
        self.address = address
        self.pointIDs = pointIDs
        self.anchorPointID = anchorPointID
    }

    public static let empty = Self()
}

public enum TimelineAutomationCommand: Equatable, Sendable {
    case addPoint(
        address: TimelineAutomationAddress,
        frame: Int,
        normalizedValue: Float,
        curveToNext: Float,
        pointID: UUID
    )
    case insertPoints(address: TimelineAutomationAddress, points: [TimelineAutomationPoint])
    case removePoints(address: TimelineAutomationAddress, pointIDs: Set<UUID>)
    case movePoints(
        address: TimelineAutomationAddress,
        pointIDs: Set<UUID>,
        frameDelta: Int,
        normalizedValueDelta: Float
    )
    case setSegmentCurve(address: TimelineAutomationAddress, leadingPointID: UUID, curve: Float)
    case setSegmentCurves(address: TimelineAutomationAddress, leadingPointIDs: Set<UUID>, curve: Float)
    case setLaneEnabled(address: TimelineAutomationAddress, isEnabled: Bool)
    case setWriteMode(address: TimelineAutomationAddress, mode: TimelineAutomationWriteMode)
    case clearLane(address: TimelineAutomationAddress)
    case replaceRange(
        address: TimelineAutomationAddress,
        range: TimelineFrameRange,
        points: [TimelineAutomationPoint]
    )
    case shiftPoints(address: TimelineAutomationAddress, pointIDs: Set<UUID>, frameDelta: Int)
    case scaleValues(
        address: TimelineAutomationAddress,
        pointIDs: Set<UUID>,
        anchorNormalizedValue: Float,
        scale: Float
    )
}

public enum TimelineAutomationCommandError: Error, Equatable, Sendable {
    case missingLane(TimelineAutomationAddress)
    case emptyPointSelection
    case pointCollision(Int)
}

public struct TimelineAutomationCommandResult: Equatable, Sendable {
    public let graph: TimelineAutomationGraph
    public let address: TimelineAutomationAddress
    public let beforeLane: TimelineAutomationLane?
    public let afterLane: TimelineAutomationLane?
    public let affectedPointIDs: Set<UUID>

    public init(
        graph: TimelineAutomationGraph,
        address: TimelineAutomationAddress,
        beforeLane: TimelineAutomationLane?,
        afterLane: TimelineAutomationLane?,
        affectedPointIDs: Set<UUID>
    ) {
        self.graph = graph
        self.address = address
        self.beforeLane = beforeLane
        self.afterLane = afterLane
        self.affectedPointIDs = affectedPointIDs
    }
}

public enum TimelineAutomationCommandExecutor {
    public static func execute(
        _ command: TimelineAutomationCommand,
        in graph: TimelineAutomationGraph,
        defaultNormalizedValue: (TimelineAutomationAddress) -> Float = { address in
            TimelineAutomationParameterRegistry.descriptor(for: address.parameterID)?.defaultNormalizedValue ?? 0
        }
    ) throws -> TimelineAutomationCommandResult {
        let address = command.address
        let beforeLane = graph.lane(at: address)
        var lane = try beforeLane ?? TimelineAutomationLane(
            address: address,
            defaultNormalizedValue: defaultNormalizedValue(address)
        )
        var affectedPointIDs = Set<UUID>()

        switch command {
        case let .addPoint(_, frame, normalizedValue, curveToNext, pointID):
            let point = try lane.setPoint(
                frame: frame,
                normalizedValue: normalizedValue,
                curveToNext: curveToNext,
                id: pointID
            )
            affectedPointIDs = [point.id]

        case let .insertPoints(_, points):
            guard !points.isEmpty else { throw TimelineAutomationCommandError.emptyPointSelection }
            var occupiedFrames = Set(lane.points.map(\.frame))
            for point in points {
                guard occupiedFrames.insert(point.frame).inserted else {
                    throw TimelineAutomationCommandError.pointCollision(point.frame)
                }
            }
            lane = try TimelineAutomationLane(
                address: address,
                defaultNormalizedValue: lane.defaultNormalizedValue,
                points: lane.points + points,
                isEnabled: lane.isEnabled,
                writeMode: lane.writeMode
            )
            affectedPointIDs = Set(points.map(\.id))

        case let .removePoints(_, pointIDs):
            guard !pointIDs.isEmpty else { throw TimelineAutomationCommandError.emptyPointSelection }
            for pointID in pointIDs where lane.points.contains(where: { $0.id == pointID }) {
                try lane.removePoint(id: pointID)
                affectedPointIDs.insert(pointID)
            }

        case let .movePoints(_, pointIDs, frameDelta, valueDelta):
            guard !pointIDs.isEmpty else { throw TimelineAutomationCommandError.emptyPointSelection }
            lane = try moving(
                pointIDs: pointIDs,
                in: lane,
                frameDelta: frameDelta,
                normalizedValueDelta: valueDelta
            )
            affectedPointIDs = pointIDs

        case let .setSegmentCurve(_, leadingPointID, curve):
            try lane.setCurve(leavingPointID: leadingPointID, curve: curve)
            affectedPointIDs = [leadingPointID]

        case let .setSegmentCurves(_, leadingPointIDs, curve):
            guard !leadingPointIDs.isEmpty else { throw TimelineAutomationCommandError.emptyPointSelection }
            for pointID in leadingPointIDs {
                try lane.setCurve(leavingPointID: pointID, curve: curve)
            }
            affectedPointIDs = leadingPointIDs

        case let .setLaneEnabled(_, isEnabled):
            lane.isEnabled = isEnabled

        case let .setWriteMode(_, mode):
            lane.writeMode = mode
            lane.isEnabled = mode != .off

        case .clearLane:
            lane = try TimelineAutomationLane(
                address: address,
                defaultNormalizedValue: lane.defaultNormalizedValue,
                isEnabled: lane.isEnabled,
                writeMode: lane.writeMode
            )
            affectedPointIDs = Set(beforeLane?.points.map(\.id) ?? [])

        case let .replaceRange(_, range, points):
            let retained = lane.points.filter { !range.contains(frame: $0.frame) }
            let replacementIDs = Set(points.map(\.id))
            let duplicates = Set(retained.map(\.frame)).intersection(points.map(\.frame))
            if let frame = duplicates.first {
                throw TimelineAutomationCommandError.pointCollision(frame)
            }
            lane = try TimelineAutomationLane(
                address: address,
                defaultNormalizedValue: lane.defaultNormalizedValue,
                points: retained + points,
                isEnabled: lane.isEnabled,
                writeMode: lane.writeMode
            )
            affectedPointIDs = replacementIDs

        case let .shiftPoints(_, pointIDs, frameDelta):
            lane = try moving(
                pointIDs: pointIDs,
                in: lane,
                frameDelta: frameDelta,
                normalizedValueDelta: 0
            )
            affectedPointIDs = pointIDs

        case let .scaleValues(_, pointIDs, anchor, scale):
            guard !pointIDs.isEmpty else { throw TimelineAutomationCommandError.emptyPointSelection }
            let selected = lane.points.filter { pointIDs.contains($0.id) }
            var next = lane.points.filter { !pointIDs.contains($0.id) }
            next.append(contentsOf: selected.map { point in
                var point = point
                point.normalizedValue = min(max(anchor + (point.normalizedValue - anchor) * scale, 0), 1)
                return point
            })
            lane = try TimelineAutomationLane(
                address: address,
                defaultNormalizedValue: lane.defaultNormalizedValue,
                points: next,
                isEnabled: lane.isEnabled,
                writeMode: lane.writeMode
            )
            affectedPointIDs = pointIDs
        }

        var nextGraph = graph
        let retainsExplicitEmptyLane: Bool
        switch command {
        case .setLaneEnabled, .setWriteMode:
            retainsExplicitEmptyLane = true
        default:
            retainsExplicitEmptyLane = false
        }
        let afterLane: TimelineAutomationLane? =
            lane.points.isEmpty && beforeLane == nil && !retainsExplicitEmptyLane ? nil : lane
        if let afterLane {
            try nextGraph.upsertLane(afterLane)
        } else {
            nextGraph.removeLane(at: address)
        }
        return TimelineAutomationCommandResult(
            graph: nextGraph,
            address: address,
            beforeLane: beforeLane,
            afterLane: afterLane,
            affectedPointIDs: affectedPointIDs
        )
    }

    private static func moving(
        pointIDs: Set<UUID>,
        in lane: TimelineAutomationLane,
        frameDelta: Int,
        normalizedValueDelta: Float
    ) throws -> TimelineAutomationLane {
        guard !pointIDs.isEmpty else { throw TimelineAutomationCommandError.emptyPointSelection }
        let selected = lane.points.filter { pointIDs.contains($0.id) }
        let retained = lane.points.filter { !pointIDs.contains($0.id) }
        let moved = selected.map { point -> TimelineAutomationPoint in
            var point = point
            point.frame = max(point.frame + frameDelta, 0)
            point.normalizedValue = min(max(point.normalizedValue + normalizedValueDelta, 0), 1)
            return point
        }
        var frames = Set(retained.map(\.frame))
        for point in moved {
            guard frames.insert(point.frame).inserted else {
                throw TimelineAutomationCommandError.pointCollision(point.frame)
            }
        }
        return try TimelineAutomationLane(
            address: lane.address,
            defaultNormalizedValue: lane.defaultNormalizedValue,
            points: retained + moved,
            isEnabled: lane.isEnabled,
            writeMode: lane.writeMode
        )
    }
}

private extension TimelineAutomationCommand {
    var address: TimelineAutomationAddress {
        switch self {
        case let .addPoint(address, _, _, _, _),
             let .insertPoints(address, _),
             let .removePoints(address, _),
             let .movePoints(address, _, _, _),
             let .setSegmentCurve(address, _, _),
             let .setSegmentCurves(address, _, _),
             let .setLaneEnabled(address, _),
             let .setWriteMode(address, _),
             let .clearLane(address),
             let .replaceRange(address, _, _),
             let .shiftPoints(address, _, _),
             let .scaleValues(address, _, _, _):
            return address
        }
    }
}

private extension TimelineFrameRange {
    func contains(frame: Int) -> Bool {
        frame >= startFrame && frame < endFrame
    }
}
