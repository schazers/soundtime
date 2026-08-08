import Foundation

public struct TimelineAutomationParameterID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let volume = Self(rawValue: "track.volume")
    public static let pan = Self(rawValue: "track.pan")
    public static let mute = Self(rawValue: "track.mute")
}

public enum TimelineAutomationOwner: Hashable, Codable, Sendable {
    case track(UUID)
    case clip(AudioTimelineClipID)
    case plugin(trackID: UUID, instanceID: UUID)
    case master
}

public struct TimelineAutomationAddress: Hashable, Codable, Sendable {
    public let owner: TimelineAutomationOwner
    public let parameterID: TimelineAutomationParameterID

    public init(owner: TimelineAutomationOwner, parameterID: TimelineAutomationParameterID) {
        self.owner = owner
        self.parameterID = parameterID
    }

    public static func track(_ trackID: UUID, parameterID: TimelineAutomationParameterID) -> Self {
        Self(owner: .track(trackID), parameterID: parameterID)
    }
}

public enum TimelineAutomationValueKind: String, Codable, Sendable {
    case continuous
    case stepped
}

public enum TimelineAutomationParameterCategory: String, Codable, Sendable {
    case level
    case spatial
    case switcher
    case timing
    case plugin
}

public enum TimelineAutomationParameterUnit: String, Codable, Sendable {
    case decibels
    case pan
    case boolean
    case percent
    case milliseconds
    case generic
}

public enum TimelineAutomationParameterMapping: String, Codable, Sendable {
    /// Soundtime's existing fader law. Preserving it keeps old projects audibly identical.
    case perceptualGainSquared
    /// Mixer fader law introduced with automation schema 2. The persisted
    /// normalized value is physical fader position, spanning silence to +12 dB.
    case mixerDecibelV2
    case bipolarLinear
    case linear
    case boolean
}

public enum TimelineMixerFaderLaw {
    public static let minimumDecibels: Float = -72
    public static let maximumDecibels: Float = 12
    public static let maximumGain: Float = pow(10, maximumDecibels / 20)
    public static let unityPosition: Float = 0.85

    public static func decibels(forGain gain: Float) -> Float {
        guard gain.isFinite, gain > 0.000_001 else { return minimumDecibels }
        return min(max(20 * log10(gain), minimumDecibels), maximumDecibels)
    }

    public static func gain(forPosition rawPosition: Float) -> Float {
        let position = min(max(rawPosition, 0), 1)
        let decibels: Float
        if position <= 0.42 {
            decibels = minimumDecibels + position / 0.42 * (-24 - minimumDecibels)
        } else if position <= unityPosition {
            decibels = -24 + (position - 0.42) / 0.43 * 24
        } else {
            decibels = (position - unityPosition) / 0.15 * maximumDecibels
        }
        guard decibels > minimumDecibels else { return 0 }
        return pow(10, decibels / 20)
    }

    public static func position(forGain gain: Float) -> Float {
        let decibels = decibels(forGain: gain)
        if decibels <= -24 {
            return (decibels - minimumDecibels) / (-24 - minimumDecibels) * 0.42
        }
        if decibels <= 0 {
            return 0.42 + (decibels + 24) / 24 * 0.43
        }
        return unityPosition + decibels / maximumDecibels * 0.15
    }
}

public enum TimelineAutomationSmoothingPolicy: Equatable, Sendable {
    case none
    case linear(milliseconds: Double)
    case deClick(milliseconds: Double)
}

public enum TimelineAutomationOwnerKind: String, Codable, CaseIterable, Sendable {
    case track
    case clip
    case plugin
    case master
}

public enum TimelineAutomationWriteMode: String, Codable, CaseIterable, Sendable {
    case off
    case read
    case touch
    case latch
    case write
    case trim
}

/// Monotonic cubic Bezier timing used by automation rendering and playback.
/// The fixed x handles are one-third and two-thirds through the segment, so
/// evaluating the curve at timeline progress does not require root finding.
public enum TimelineAutomationCurve {
    /// Persisted curve values in `[-1, 1]` retain the original variable ease
    /// behavior. Values above that range are stable named shapes shared by the
    /// editor, renderer, realtime engine, and exporter.
    public static let sCurve: Float = 2
    public static let stepped: Float = 3

    /// Keeps legacy variable-ease values and the named persisted shapes while
    /// rejecting malformed values at every model/playback boundary.
    public static func validated(_ curve: Float) -> Float {
        guard curve.isFinite else { return 0 }
        if abs(curve - stepped) < 0.25 { return stepped }
        if abs(curve - sCurve) < 0.25 { return sCurve }
        return min(max(curve, -1), 1)
    }

    public static func progress(_ progress: Float, curve: Float) -> Float {
        let progress = min(max(progress, 0), 1)
        let curve = validated(curve)
        if curve >= stepped - 0.25 {
            return progress < 1 ? 0 : 1
        }
        if curve >= sCurve - 0.25 {
            return progress * progress * (3 - 2 * progress)
        }
        guard abs(curve) > 0.000_1 else { return progress }

        let strength = abs(curve)
        let control1: Float
        let control2: Float
        if curve > 0 {
            control1 = (1 - strength) / 3
            control2 = 2 * (1 - strength) / 3
        } else {
            control1 = 1 / 3 + 2 * strength / 3
            control2 = 2 / 3 + strength / 3
        }
        let inverse = 1 - progress
        return 3 * inverse * inverse * progress * control1 +
            3 * inverse * progress * progress * control2 +
            progress * progress * progress
    }
}

public struct TimelineAutomationParameterDescriptor: Equatable, Sendable {
    public let id: TimelineAutomationParameterID
    public let displayName: String
    public let category: TimelineAutomationParameterCategory
    public let kind: TimelineAutomationValueKind
    public let unit: TimelineAutomationParameterUnit
    public let mapping: TimelineAutomationParameterMapping
    public let minimumDomainValue: Float
    public let maximumDomainValue: Float
    public let defaultNormalizedValue: Float
    public let smoothingPolicy: TimelineAutomationSmoothingPolicy
    public let supportedOwners: Set<TimelineAutomationOwnerKind>
    public let isReadable: Bool
    public let isWritable: Bool

    public init(
        id: TimelineAutomationParameterID,
        displayName: String,
        category: TimelineAutomationParameterCategory = .plugin,
        kind: TimelineAutomationValueKind,
        unit: TimelineAutomationParameterUnit = .generic,
        mapping: TimelineAutomationParameterMapping = .linear,
        minimumDomainValue: Float = 0,
        maximumDomainValue: Float = 1,
        defaultNormalizedValue: Float,
        smoothingPolicy: TimelineAutomationSmoothingPolicy = .none,
        supportedOwners: Set<TimelineAutomationOwnerKind> = [.track],
        isReadable: Bool = true,
        isWritable: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.kind = kind
        self.unit = unit
        self.mapping = mapping
        self.minimumDomainValue = min(minimumDomainValue, maximumDomainValue)
        self.maximumDomainValue = max(minimumDomainValue, maximumDomainValue)
        self.defaultNormalizedValue = min(max(defaultNormalizedValue, 0), 1)
        self.smoothingPolicy = smoothingPolicy
        self.supportedOwners = supportedOwners
        self.isReadable = isReadable
        self.isWritable = isWritable
    }

    public func domainValue(fromNormalized normalizedValue: Float) -> Float {
        let normalizedValue = min(max(normalizedValue, 0), 1)
        switch mapping {
        case .perceptualGainSquared:
            return normalizedValue * normalizedValue
        case .mixerDecibelV2:
            return TimelineMixerFaderLaw.gain(forPosition: normalizedValue)
        case .bipolarLinear:
            return minimumDomainValue + (maximumDomainValue - minimumDomainValue) * normalizedValue
        case .linear:
            return minimumDomainValue + (maximumDomainValue - minimumDomainValue) * normalizedValue
        case .boolean:
            return normalizedValue >= 0.5 ? maximumDomainValue : minimumDomainValue
        }
    }

    public func normalizedValue(fromDomain domainValue: Float) -> Float {
        let domainValue = min(max(domainValue, minimumDomainValue), maximumDomainValue)
        switch mapping {
        case .perceptualGainSquared:
            return sqrt(max(domainValue, 0))
        case .mixerDecibelV2:
            return TimelineMixerFaderLaw.position(forGain: domainValue)
        case .bipolarLinear, .linear:
            let span = maximumDomainValue - minimumDomainValue
            return span > 0 ? (domainValue - minimumDomainValue) / span : 0
        case .boolean:
            return domainValue > minimumDomainValue ? 1 : 0
        }
    }

    public func formattedValue(normalizedValue: Float) -> String {
        let domainValue = domainValue(fromNormalized: normalizedValue)
        switch unit {
        case .decibels:
            guard domainValue > 0.000_001 else { return "-inf dB" }
            return String(format: "%.1f dB", 20 * log10(domainValue))
        case .pan:
            if abs(domainValue) < 0.005 { return "C" }
            let amount = Int((abs(domainValue) * 100).rounded())
            return domainValue < 0 ? "L\(amount)" : "R\(amount)"
        case .boolean:
            return domainValue > minimumDomainValue ? "On" : "Off"
        case .percent:
            return "\(Int((domainValue * 100).rounded()))%"
        case .milliseconds:
            return String(format: "%.1f ms", domainValue)
        case .generic:
            return String(format: "%.3f", domainValue)
        }
    }

    public func normalizedValue(parsing string: String) -> Float? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch unit {
        case .decibels:
            if ["-inf", "-inf db", "silence"].contains(trimmed) { return 0 }
            guard let decibels = Float(trimmed.replacingOccurrences(of: "db", with: "").trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return normalizedValue(fromDomain: pow(10, decibels / 20))
        case .pan:
            if ["c", "center", "centre"].contains(trimmed) { return 0.5 }
            let direction: Float
            if trimmed.hasPrefix("l") { direction = -1 }
            else if trimmed.hasPrefix("r") { direction = 1 }
            else { return Float(trimmed).map(normalizedValue(fromDomain:)) }
            guard let amount = Float(trimmed.dropFirst()) else { return nil }
            return normalizedValue(fromDomain: direction * min(max(amount / 100, 0), 1))
        case .boolean:
            if ["on", "true", "1", "yes"].contains(trimmed) { return 1 }
            if ["off", "false", "0", "no"].contains(trimmed) { return 0 }
            return nil
        case .percent:
            guard let percent = Float(trimmed.replacingOccurrences(of: "%", with: "")) else { return nil }
            return normalizedValue(fromDomain: percent / 100)
        case .milliseconds:
            guard let milliseconds = Float(trimmed.replacingOccurrences(of: "ms", with: "")) else { return nil }
            return normalizedValue(fromDomain: milliseconds)
        case .generic:
            return Float(trimmed).map(normalizedValue(fromDomain:))
        }
    }
}

public enum TimelineAutomationCurvePreset: String, Codable, CaseIterable, Sendable {
    case linear
    case easeIn
    case easeOut
    case sCurve
    case stepped

    public var persistedCurve: Float {
        switch self {
        case .linear: 0
        case .easeIn: 0.8
        case .easeOut: -0.8
        case .sCurve: TimelineAutomationCurve.sCurve
        case .stepped: TimelineAutomationCurve.stepped
        }
    }
}

public enum TimelineAutomationParameterRegistry {
    public static let trackVolume = TimelineAutomationParameterDescriptor(
        id: .volume,
        displayName: "Volume",
        category: .level,
        kind: .continuous,
        unit: .decibels,
        mapping: .mixerDecibelV2,
        minimumDomainValue: 0,
        maximumDomainValue: TimelineMixerFaderLaw.maximumGain,
        defaultNormalizedValue: TimelineMixerFaderLaw.unityPosition,
        smoothingPolicy: .linear(milliseconds: 3),
        supportedOwners: [.track, .master]
    )

    public static let trackPan = TimelineAutomationParameterDescriptor(
        id: .pan,
        displayName: "Pan",
        category: .spatial,
        kind: .continuous,
        unit: .pan,
        mapping: .bipolarLinear,
        minimumDomainValue: -1,
        maximumDomainValue: 1,
        defaultNormalizedValue: 0.5,
        smoothingPolicy: .linear(milliseconds: 3),
        supportedOwners: [.track]
    )

    public static let trackMute = TimelineAutomationParameterDescriptor(
        id: .mute,
        displayName: "Mute",
        category: .switcher,
        kind: .stepped,
        unit: .boolean,
        mapping: .boolean,
        minimumDomainValue: 0,
        maximumDomainValue: 1,
        defaultNormalizedValue: 0,
        smoothingPolicy: .deClick(milliseconds: 3),
        supportedOwners: [.track, .clip, .master]
    )

    public static let trackParameters = [trackVolume, trackPan, trackMute]

    public static func descriptor(
        for parameterID: TimelineAutomationParameterID
    ) -> TimelineAutomationParameterDescriptor? {
        trackParameters.first { $0.id == parameterID }
    }
}

/// Immutable lookup table used when binding persisted lanes to built-in or
/// plug-in parameters. IDs, never display names or enumeration order, are the
/// persistence contract.
public struct TimelineAutomationParameterCatalog: Sendable {
    private let descriptorsByID: [TimelineAutomationParameterID: TimelineAutomationParameterDescriptor]

    public init(
        descriptors: [TimelineAutomationParameterDescriptor] = TimelineAutomationParameterRegistry.trackParameters
    ) throws {
        var indexed: [TimelineAutomationParameterID: TimelineAutomationParameterDescriptor] = [:]
        for descriptor in descriptors {
            guard indexed[descriptor.id] == nil else {
                throw TimelineAutomationParameterCatalogError.duplicateParameterID(descriptor.id)
            }
            indexed[descriptor.id] = descriptor
        }
        descriptorsByID = indexed
    }

    public func descriptor(for id: TimelineAutomationParameterID) -> TimelineAutomationParameterDescriptor? {
        descriptorsByID[id]
    }

    public var descriptors: [TimelineAutomationParameterDescriptor] {
        descriptorsByID.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }
}

public enum TimelineAutomationParameterCatalogError: Error, Equatable, Sendable {
    case duplicateParameterID(TimelineAutomationParameterID)
}

public struct TimelineAutomationPoint: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var frame: Int
    public var normalizedValue: Float
    /// Shape of the segment leaving this point. Zero is linear, positive values
    /// ease in, and negative values ease out.
    public var curveToNext: Float

    public init(
        id: UUID = UUID(),
        frame: Int,
        normalizedValue: Float,
        curveToNext: Float = 0
    ) {
        self.id = id
        self.frame = max(frame, 0)
        self.normalizedValue = min(max(normalizedValue, 0), 1)
        self.curveToNext = Self.validatedCurve(curveToNext)
    }
}

public enum TimelineAutomationError: Error, Equatable, Sendable {
    case duplicatePointID(UUID)
    case duplicatePointFrame(Int)
    case invalidPointValue(UUID)
    case missingPoint(UUID)
}

public struct TimelineAutomationLane: Hashable, Codable, Sendable {
    public let address: TimelineAutomationAddress
    public var defaultNormalizedValue: Float
    public private(set) var points: [TimelineAutomationPoint]
    public var isEnabled: Bool
    public var writeMode: TimelineAutomationWriteMode

    public init(
        address: TimelineAutomationAddress,
        defaultNormalizedValue: Float,
        points: [TimelineAutomationPoint] = [],
        isEnabled: Bool = true,
        writeMode: TimelineAutomationWriteMode = .read
    ) throws {
        self.address = address
        self.defaultNormalizedValue = min(max(defaultNormalizedValue, 0), 1)
        self.points = points.sorted(by: Self.pointOrdering)
        self.isEnabled = isEnabled
        self.writeMode = writeMode
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case address
        case defaultNormalizedValue
        case points
        case isEnabled
        case writeMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            address: container.decode(TimelineAutomationAddress.self, forKey: .address),
            defaultNormalizedValue: container.decode(Float.self, forKey: .defaultNormalizedValue),
            points: container.decodeIfPresent([TimelineAutomationPoint].self, forKey: .points) ?? [],
            isEnabled: container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            writeMode: container.decodeIfPresent(TimelineAutomationWriteMode.self, forKey: .writeMode) ?? .read
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(address, forKey: .address)
        try container.encode(defaultNormalizedValue, forKey: .defaultNormalizedValue)
        try container.encode(points, forKey: .points)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(writeMode, forKey: .writeMode)
    }

    public func validate() throws {
        var pointIDs = Set<UUID>()
        var frames = Set<Int>()
        for point in points {
            guard pointIDs.insert(point.id).inserted else {
                throw TimelineAutomationError.duplicatePointID(point.id)
            }
            guard frames.insert(point.frame).inserted else {
                throw TimelineAutomationError.duplicatePointFrame(point.frame)
            }
            guard
                point.frame >= 0,
                point.normalizedValue.isFinite,
                (0 ... 1).contains(point.normalizedValue),
                point.curveToNext.isFinite,
                Self.isValidCurve(point.curveToNext)
            else {
                throw TimelineAutomationError.invalidPointValue(point.id)
            }
        }
    }

    public func normalizedValue(at frame: Int) -> Float {
        guard isEnabled, let first = points.first else {
            return defaultNormalizedValue
        }
        let frame = max(frame, 0)
        guard frame > first.frame else { return first.normalizedValue }
        let last = points[points.count - 1]
        guard frame < last.frame else { return last.normalizedValue }

        let upperIndex = points.partitioningIndex { $0.frame > frame }
        let left = points[max(upperIndex - 1, 0)]
        let right = points[min(upperIndex, points.count - 1)]
        guard right.frame > left.frame else { return right.normalizedValue }

        let linearProgress = Float(frame - left.frame) / Float(right.frame - left.frame)
        let curvedProgress = TimelineAutomationCurve.progress(
            linearProgress,
            curve: left.curveToNext
        )
        return left.normalizedValue + (right.normalizedValue - left.normalizedValue) * curvedProgress
    }

    @discardableResult
    public mutating func setPoint(
        frame: Int,
        normalizedValue: Float,
        curveToNext: Float = 0,
        id: UUID = UUID()
    ) throws -> TimelineAutomationPoint {
        let frame = max(frame, 0)
        let point = TimelineAutomationPoint(
            id: points.first(where: { $0.frame == frame })?.id ?? id,
            frame: frame,
            normalizedValue: normalizedValue,
            curveToNext: curveToNext
        )
        points.removeAll { $0.frame == frame }
        points.append(point)
        points.sort(by: Self.pointOrdering)
        try validate()
        return point
    }

    public mutating func removePoint(id: UUID) throws {
        guard let index = points.firstIndex(where: { $0.id == id }) else {
            throw TimelineAutomationError.missingPoint(id)
        }
        points.remove(at: index)
    }

    public mutating func movePoint(
        id: UUID,
        toFrame frame: Int,
        normalizedValue: Float
    ) throws {
        guard let index = points.firstIndex(where: { $0.id == id }) else {
            throw TimelineAutomationError.missingPoint(id)
        }
        let destinationFrame = max(frame, 0)
        if points.contains(where: { $0.id != id && $0.frame == destinationFrame }) {
            throw TimelineAutomationError.duplicatePointFrame(destinationFrame)
        }
        points[index].frame = destinationFrame
        points[index].normalizedValue = min(max(normalizedValue, 0), 1)
        points.sort(by: Self.pointOrdering)
        try validate()
    }

    public mutating func setCurve(leavingPointID: UUID, curve: Float) throws {
        guard let index = points.firstIndex(where: { $0.id == leavingPointID }) else {
            throw TimelineAutomationError.missingPoint(leavingPointID)
        }
        points[index].curveToNext = TimelineAutomationPoint.validatedCurve(curve)
    }

    public func insertingTime(at frame: Int, frameCount: Int) throws -> Self {
        guard frameCount > 0 else { return self }
        let insertionFrame = max(frame, 0)
        let heldValue = normalizedValue(at: insertionFrame)
        var nextPoints = points.map { point in
            guard point.frame >= insertionFrame else { return point }
            var shifted = point
            shifted.frame += frameCount
            return shifted
        }
        nextPoints.removeAll { $0.frame == insertionFrame || $0.frame == insertionFrame + frameCount }
        nextPoints.append(TimelineAutomationPoint(frame: insertionFrame, normalizedValue: heldValue))
        nextPoints.append(TimelineAutomationPoint(
            frame: insertionFrame + frameCount,
            normalizedValue: heldValue
        ))
        return try Self(
            address: address,
            defaultNormalizedValue: defaultNormalizedValue,
            points: nextPoints,
            isEnabled: isEnabled,
            writeMode: writeMode
        )
    }

    public func rippleDeleting(_ range: TimelineFrameRange) throws -> Self {
        guard range.frameCount > 0 else { return self }
        let joinedValue = normalizedValue(at: range.endFrame)
        var nextPoints = points.compactMap { point -> TimelineAutomationPoint? in
            if point.frame < range.startFrame { return point }
            if point.frame < range.endFrame { return nil }
            var shifted = point
            shifted.frame -= range.frameCount
            return shifted
        }
        nextPoints.removeAll { $0.frame == range.startFrame }
        nextPoints.append(TimelineAutomationPoint(
            frame: range.startFrame,
            normalizedValue: joinedValue
        ))
        return try Self(
            address: address,
            defaultNormalizedValue: defaultNormalizedValue,
            points: nextPoints,
            isEnabled: isEnabled,
            writeMode: writeMode
        )
    }

    private static func pointOrdering(_ lhs: TimelineAutomationPoint, _ rhs: TimelineAutomationPoint) -> Bool {
        if lhs.frame == rhs.frame { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.frame < rhs.frame
    }

    private static func isValidCurve(_ curve: Float) -> Bool {
        TimelineAutomationPoint.isValidCurve(curve)
    }

}

private extension TimelineAutomationPoint {
    static func validatedCurve(_ curve: Float) -> Float {
        TimelineAutomationCurve.validated(curve)
    }

    static func isValidCurve(_ curve: Float) -> Bool {
        curve.isFinite && (
            (-1 ... 1).contains(curve) ||
            curve == TimelineAutomationCurve.sCurve ||
            curve == TimelineAutomationCurve.stepped
        )
    }
}

public struct TimelineAutomationPointClipboard: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let relativeFrame: Int
        public let normalizedValue: Float
        public let curveToNext: Float

        public init(relativeFrame: Int, normalizedValue: Float, curveToNext: Float) {
            self.relativeFrame = max(relativeFrame, 0)
            self.normalizedValue = min(max(normalizedValue, 0), 1)
            self.curveToNext = TimelineAutomationPoint.validatedCurve(curveToNext)
        }
    }

    public let sourceParameterID: TimelineAutomationParameterID
    public let entries: [Entry]
    public let frameSpan: Int

    public init?(
        lane: TimelineAutomationLane,
        pointIDs: Set<UUID>
    ) {
        let selected = lane.points.filter { pointIDs.contains($0.id) }
        guard let firstFrame = selected.first?.frame else { return nil }
        sourceParameterID = lane.address.parameterID
        entries = selected.map {
            Entry(
                relativeFrame: $0.frame - firstFrame,
                normalizedValue: $0.normalizedValue,
                curveToNext: $0.curveToNext
            )
        }
        frameSpan = max((selected.last?.frame ?? firstFrame) - firstFrame, 0)
    }

    public func points(
        pastedAt startFrame: Int,
        regeneratingIDs: () -> UUID = UUID.init
    ) -> [TimelineAutomationPoint] {
        let startFrame = max(startFrame, 0)
        return entries.map {
            TimelineAutomationPoint(
                id: regeneratingIDs(),
                frame: startFrame + $0.relativeFrame,
                normalizedValue: $0.normalizedValue,
                curveToNext: $0.curveToNext
            )
        }
    }
}

public struct TimelineAutomationDrawSample: Equatable, Sendable {
    public let frame: Int
    public let normalizedValue: Float

    public init(frame: Int, normalizedValue: Float) {
        self.frame = max(frame, 0)
        self.normalizedValue = min(max(normalizedValue, 0), 1)
    }
}

public enum TimelineAutomationParameterBindingState: Equatable, Sendable {
    case available
    case missingOwner
    case missingParameter
    case readOnly
}

public struct TimelineAutomationParameterBinding: Equatable, Sendable {
    public let address: TimelineAutomationAddress
    public let descriptor: TimelineAutomationParameterDescriptor?
    public let state: TimelineAutomationParameterBindingState

    public init(
        address: TimelineAutomationAddress,
        descriptor: TimelineAutomationParameterDescriptor?,
        state: TimelineAutomationParameterBindingState
    ) {
        self.address = address
        self.descriptor = descriptor
        self.state = state
    }
}

/// Resolves persisted automation by stable owner and parameter identifiers.
/// Missing parameters remain in the graph and become visible unavailable
/// bindings instead of being discarded or rebound by display name/order.
public enum TimelineAutomationParameterBindingResolver {
    public static func resolve(
        graph: TimelineAutomationGraph,
        liveTrackIDs: Set<UUID>,
        liveClipIDs: Set<AudioTimelineClipID>,
        livePluginInstanceIDs: Set<UUID>,
        descriptor: (TimelineAutomationParameterID) -> TimelineAutomationParameterDescriptor?
    ) -> [TimelineAutomationParameterBinding] {
        graph.lanes.map { lane in
            let ownerExists: Bool
            switch lane.address.owner {
            case let .track(id): ownerExists = liveTrackIDs.contains(id)
            case let .clip(id): ownerExists = liveClipIDs.contains(id)
            case let .plugin(trackID, instanceID):
                ownerExists = liveTrackIDs.contains(trackID) && livePluginInstanceIDs.contains(instanceID)
            case .master: ownerExists = true
            }
            let resolvedDescriptor = descriptor(lane.address.parameterID)
            let state: TimelineAutomationParameterBindingState
            if !ownerExists {
                state = .missingOwner
            } else if resolvedDescriptor == nil {
                state = .missingParameter
            } else if resolvedDescriptor?.isWritable == false {
                state = .readOnly
            } else {
                state = .available
            }
            return TimelineAutomationParameterBinding(
                address: lane.address,
                descriptor: resolvedDescriptor,
                state: state
            )
        }
    }
}

public struct TimelineAutomationWriteCapture: Equatable, Sendable {
    public let address: TimelineAutomationAddress
    public let mode: TimelineAutomationWriteMode
    public let originalLane: TimelineAutomationLane
    public private(set) var samples: [TimelineAutomationDrawSample]

    public init(
        address: TimelineAutomationAddress,
        mode: TimelineAutomationWriteMode,
        originalLane: TimelineAutomationLane,
        startFrame: Int,
        normalizedValue: Float
    ) {
        precondition([.write, .touch, .latch].contains(mode))
        self.address = address
        self.mode = mode
        self.originalLane = originalLane
        samples = [TimelineAutomationDrawSample(
            frame: startFrame,
            normalizedValue: normalizedValue
        )]
    }

    public mutating func append(frame: Int, normalizedValue: Float) {
        let sample = TimelineAutomationDrawSample(frame: frame, normalizedValue: normalizedValue)
        if samples.last?.frame == sample.frame {
            samples[samples.count - 1] = sample
        } else if sample.frame > (samples.last?.frame ?? -1) {
            samples.append(sample)
        }
    }

    public func command(
        endingAt endFrame: Int,
        frameTolerance: Int,
        valueTolerance: Float
    ) -> TimelineAutomationCommand {
        let startFrame = samples.first?.frame ?? max(endFrame, 0)
        let endFrame = max(endFrame, samples.last?.frame ?? startFrame)
        var captured = samples
        if (mode == .latch || mode == .write), let last = captured.last, last.frame < endFrame {
            captured.append(TimelineAutomationDrawSample(
                frame: endFrame,
                normalizedValue: last.normalizedValue
            ))
        }
        var simplified = TimelineAutomationDrawSimplifier.simplified(
            captured,
            frameTolerance: max(frameTolerance, 1),
            valueTolerance: max(valueTolerance, 0.000_1)
        )
        if mode == .touch {
            let restoreFrame = endFrame + 1
            simplified.append(TimelineAutomationDrawSample(
                frame: restoreFrame,
                normalizedValue: originalLane.normalizedValue(at: restoreFrame)
            ))
        }
        let points = simplified.map {
            TimelineAutomationPoint(
                frame: $0.frame,
                normalizedValue: $0.normalizedValue
            )
        }
        return .replaceRange(
            address: address,
            range: TimelineFrameRange(
                startFrame: startFrame,
                frameCount: max((points.last?.frame ?? endFrame) - startFrame + 1, 1)
            ),
            points: points
        )
    }
}

/// Deterministic, iterative Ramer-Douglas-Peucker reduction. Coordinates are
/// normalized by independent time and value tolerances, so simplification is
/// stable regardless of project duration or lane height.
public enum TimelineAutomationDrawSimplifier {
    public static func simplified(
        _ samples: [TimelineAutomationDrawSample],
        frameTolerance: Int,
        valueTolerance: Float
    ) -> [TimelineAutomationDrawSample] {
        let ordered = samples.sorted { lhs, rhs in
            lhs.frame == rhs.frame ? lhs.normalizedValue < rhs.normalizedValue : lhs.frame < rhs.frame
        }
        var unique: [TimelineAutomationDrawSample] = []
        unique.reserveCapacity(ordered.count)
        for sample in ordered {
            if unique.last?.frame == sample.frame {
                unique[unique.count - 1] = sample
            } else {
                unique.append(sample)
            }
        }
        guard unique.count > 2 else { return unique }

        let frameScale = Double(max(frameTolerance, 1))
        let valueScale = Double(max(valueTolerance, 0.000_001))
        var keep = Array(repeating: false, count: unique.count)
        keep[0] = true
        keep[unique.count - 1] = true
        var stack: [(Int, Int)] = [(0, unique.count - 1)]

        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            let ax = Double(unique[start].frame) / frameScale
            let ay = Double(unique[start].normalizedValue) / valueScale
            let bx = Double(unique[end].frame) / frameScale
            let by = Double(unique[end].normalizedValue) / valueScale
            let dx = bx - ax
            let dy = by - ay
            let denominator = max(dx * dx + dy * dy, 0.000_000_1)
            var farthestIndex = -1
            var farthestDistanceSquared = 1.0
            for index in (start + 1) ..< end {
                let px = Double(unique[index].frame) / frameScale
                let py = Double(unique[index].normalizedValue) / valueScale
                let t = min(max(((px - ax) * dx + (py - ay) * dy) / denominator, 0), 1)
                let distanceX = px - (ax + t * dx)
                let distanceY = py - (ay + t * dy)
                let distanceSquared = distanceX * distanceX + distanceY * distanceY
                if distanceSquared > farthestDistanceSquared {
                    farthestDistanceSquared = distanceSquared
                    farthestIndex = index
                }
            }
            if farthestIndex >= 0 {
                keep[farthestIndex] = true
                stack.append((start, farthestIndex))
                stack.append((farthestIndex, end))
            }
        }
        return zip(unique, keep).compactMap { $0.1 ? $0.0 : nil }
    }
}

public struct TimelineAutomationGraph: Equatable, Sendable {
    public private(set) var revision: UInt64
    private var lanesByAddress: [TimelineAutomationAddress: TimelineAutomationLane]
    private var addressesByOwner: [TimelineAutomationOwner: Set<TimelineAutomationAddress>]

    public init(revision: UInt64 = 1, lanes: [TimelineAutomationLane] = []) throws {
        self.revision = max(revision, 1)
        lanesByAddress = [:]
        addressesByOwner = [:]
        for lane in lanes {
            try lane.validate()
            lanesByAddress[lane.address] = lane
            addressesByOwner[lane.address.owner, default: []].insert(lane.address)
        }
    }

    public var lanes: [TimelineAutomationLane] {
        lanesByAddress.values.sorted { lhs, rhs in
            Self.sortKey(lhs.address) < Self.sortKey(rhs.address)
        }
    }

    public func lane(at address: TimelineAutomationAddress) -> TimelineAutomationLane? {
        lanesByAddress[address]
    }

    /// Returns only the lanes owned by one model object. Keeping this lookup
    /// indexed prevents track publication from repeatedly scanning and sorting
    /// the complete automation graph in large projects.
    public func lanes(ownedBy owner: TimelineAutomationOwner) -> [TimelineAutomationLane] {
        guard let addresses = addressesByOwner[owner] else { return [] }
        return addresses.compactMap { lanesByAddress[$0] }.sorted { lhs, rhs in
            lhs.address.parameterID.rawValue < rhs.address.parameterID.rawValue
        }
    }

    public mutating func upsertLane(_ lane: TimelineAutomationLane) throws {
        try lane.validate()
        lanesByAddress[lane.address] = lane
        addressesByOwner[lane.address.owner, default: []].insert(lane.address)
        revision &+= 1
    }

    public mutating func removeLane(at address: TimelineAutomationAddress) {
        guard lanesByAddress.removeValue(forKey: address) != nil else { return }
        removeAddressFromOwnerIndex(address)
        revision &+= 1
    }

    public mutating func restoreLane(
        at address: TimelineAutomationAddress,
        to lane: TimelineAutomationLane?
    ) throws {
        if let lane {
            guard lane.address == address else {
                preconditionFailure("Automation lane address does not match its restoration key")
            }
            try lane.validate()
            lanesByAddress[address] = lane
        } else {
            lanesByAddress.removeValue(forKey: address)
            removeAddressFromOwnerIndex(address)
        }
        if lane != nil {
            addressesByOwner[address.owner, default: []].insert(address)
        }
        revision &+= 1
    }

    public mutating func removeLaneWithoutAdvancingRevision(at address: TimelineAutomationAddress) {
        guard lanesByAddress.removeValue(forKey: address) != nil else { return }
        removeAddressFromOwnerIndex(address)
    }

    public mutating func setRevision(_ revision: UInt64) {
        self.revision = max(revision, 1)
    }

    public func transformedForClipMove(
        clipID: AudioTimelineClipID,
        destinationTrackID: UUID,
        supportsParameter: (TimelineAutomationParameterID, UUID) -> Bool
    ) throws -> Self {
        var next = self
        for lane in lanes where lane.address.owner == .clip(clipID) {
            var updated = lane
            updated.isEnabled = supportsParameter(lane.address.parameterID, destinationTrackID)
            try next.upsertLane(updated)
        }
        return next
    }

    /// Copies automation whose time domain belongs to a clip. Point frames are
    /// clip-local, so no time translation is required when the duplicated clip
    /// is placed on the timeline. Fresh point IDs keep subsequent edits and
    /// undo transactions independent from the source clip.
    public func duplicatingClipAutomation(
        from sourceClipID: AudioTimelineClipID,
        to destinationClipID: AudioTimelineClipID,
        makePointID: () -> UUID = UUID.init
    ) throws -> Self {
        var next = self
        for lane in lanes(ownedBy: .clip(sourceClipID)) {
            let copiedPoints = lane.points.map { point in
                TimelineAutomationPoint(
                    id: makePointID(),
                    frame: point.frame,
                    normalizedValue: point.normalizedValue,
                    curveToNext: point.curveToNext
                )
            }
            let copiedLane = try TimelineAutomationLane(
                address: TimelineAutomationAddress(
                    owner: .clip(destinationClipID),
                    parameterID: lane.address.parameterID
                ),
                defaultNormalizedValue: lane.defaultNormalizedValue,
                points: copiedPoints,
                isEnabled: lane.isEnabled,
                writeMode: lane.writeMode
            )
            try next.upsertLane(copiedLane)
        }
        return next
    }

    /// Removes lanes whose owning model object no longer exists.
    /// Track deletion must not leave audible automation behind, while moving a
    /// clip preserves its clip-owned lanes because its identity remains live.
    public func pruningOrphanedOwners(
        liveTrackIDs: Set<UUID>,
        liveClipIDs: Set<AudioTimelineClipID>
    ) -> Self {
        var next = self
        for lane in lanes {
            let ownerIsLive: Bool
            switch lane.address.owner {
            case let .track(trackID):
                ownerIsLive = liveTrackIDs.contains(trackID)
            case let .clip(clipID):
                ownerIsLive = liveClipIDs.contains(clipID)
            case let .plugin(trackID, _):
                ownerIsLive = liveTrackIDs.contains(trackID)
            case .master:
                ownerIsLive = true
            }
            if !ownerIsLive {
                next.removeLane(at: lane.address)
            }
        }
        return next
    }

    public func rippleDeleting(
        _ range: TimelineFrameRange,
        affectedTrackIDs: Set<UUID>,
        followsTrackAutomation: Bool
    ) throws -> Self {
        guard followsTrackAutomation else { return self }
        var next = self
        for lane in lanes {
            guard case let .track(trackID) = lane.address.owner, affectedTrackIDs.contains(trackID) else {
                continue
            }
            try next.upsertLane(lane.rippleDeleting(range))
        }
        return next
    }

    public func insertingTime(
        at frame: Int,
        frameCount: Int,
        affectedTrackIDs: Set<UUID>,
        followsTrackAutomation: Bool
    ) throws -> Self {
        guard followsTrackAutomation else { return self }
        var next = self
        for lane in lanes {
            guard case let .track(trackID) = lane.address.owner, affectedTrackIDs.contains(trackID) else {
                continue
            }
            try next.upsertLane(lane.insertingTime(at: frame, frameCount: frameCount))
        }
        return next
    }

    private static func sortKey(_ address: TimelineAutomationAddress) -> String {
        let owner: String
        switch address.owner {
        case let .track(id): owner = "track:\(id.uuidString)"
        case let .clip(id): owner = "clip:\(id.rawValue.uuidString)"
        case let .plugin(trackID, instanceID):
            owner = "plugin:\(trackID.uuidString):\(instanceID.uuidString)"
        case .master: owner = "master"
        }
        return "\(owner):\(address.parameterID.rawValue)"
    }

    private mutating func removeAddressFromOwnerIndex(_ address: TimelineAutomationAddress) {
        addressesByOwner[address.owner]?.remove(address)
        if addressesByOwner[address.owner]?.isEmpty == true {
            addressesByOwner.removeValue(forKey: address.owner)
        }
    }
}

public struct TimelineAutomationDocument: Codable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let revision: UInt64
    public let lanes: [TimelineAutomationLane]

    public init(schemaVersion: Int, revision: UInt64, lanes: [TimelineAutomationLane]) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.lanes = lanes
    }

    public init(graph: TimelineAutomationGraph) {
        schemaVersion = Self.currentSchemaVersion
        revision = graph.revision
        lanes = graph.lanes
    }

    public func makeGraph() throws -> TimelineAutomationGraph {
        let migratedLanes = schemaVersion < 2 ? try lanes.map(Self.migratingLegacyVolumeLane) : lanes
        return try TimelineAutomationGraph(revision: revision, lanes: migratedLanes)
    }

    private static func migratingLegacyVolumeLane(
        _ lane: TimelineAutomationLane
    ) throws -> TimelineAutomationLane {
        guard lane.address.parameterID == .volume else { return lane }
        let migratedDefault = TimelineMixerFaderLaw.position(
            forGain: lane.defaultNormalizedValue * lane.defaultNormalizedValue
        )
        let migratedPoints = lane.points.map { point in
            TimelineAutomationPoint(
                id: point.id,
                frame: point.frame,
                normalizedValue: TimelineMixerFaderLaw.position(
                    forGain: point.normalizedValue * point.normalizedValue
                ),
                curveToNext: point.curveToNext
            )
        }
        return try TimelineAutomationLane(
            address: lane.address,
            defaultNormalizedValue: migratedDefault,
            points: migratedPoints,
            isEnabled: lane.isEnabled,
            writeMode: lane.writeMode
        )
    }
}

private extension Array {
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var lowerBound = 0
        var upperBound = count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if predicate(self[middle]) {
                upperBound = middle
            } else {
                lowerBound = middle + 1
            }
        }
        return lowerBound
    }
}
