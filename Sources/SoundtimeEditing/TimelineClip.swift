import Foundation

public struct TimelineMediaSourceID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct TimelineMediaSource: Identifiable, Equatable, Codable, Sendable {
    public let id: TimelineMediaSourceID
    public var relativePath: String?
    public var absolutePath: String?
    public var fingerprint: String?
    public var frameCount: Int
    public var sampleRate: Double
    public var channelCount: Int
    public var metadata: [String: String]

    public init(
        id: TimelineMediaSourceID,
        relativePath: String? = nil,
        absolutePath: String? = nil,
        fingerprint: String? = nil,
        frameCount: Int,
        sampleRate: Double,
        channelCount: Int,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.fingerprint = fingerprint
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.metadata = metadata
    }

    public func validate() throws {
        guard
            frameCount >= 0,
            sampleRate.isFinite,
            sampleRate > 0,
            channelCount > 0
        else {
            throw TimelineClipGraphError.invalidSource(id)
        }
    }
}

public struct TimelineFrameRange: Equatable, Codable, Sendable {
    public var startFrame: Int
    public var frameCount: Int

    public init(startFrame: Int, frameCount: Int) {
        self.startFrame = startFrame
        self.frameCount = frameCount
    }

    public var endFrame: Int {
        startFrame + frameCount
    }

    public var range: Range<Int> {
        startFrame..<endFrame
    }

    public func intersects(_ other: Self) -> Bool {
        startFrame < other.endFrame && other.startFrame < endFrame
    }
}

public struct TimelineClipFades: Equatable, Codable, Sendable {
    public var fadeInFrames: Int
    public var fadeOutFrames: Int

    public init(fadeInFrames: Int = 0, fadeOutFrames: Int = 0) {
        self.fadeInFrames = fadeInFrames
        self.fadeOutFrames = fadeOutFrames
    }

    public var isFadeInEnabled: Bool {
        fadeInFrames > 0
    }

    public var isFadeOutEnabled: Bool {
        fadeOutFrames > 0
    }
}

public struct TimelineClipGainEnvelope: Equatable, Codable, Sendable {
    public var startMultiplier: Float
    public var endMultiplier: Float

    public init(startMultiplier: Float = 1, endMultiplier: Float = 1) {
        self.startMultiplier = startMultiplier
        self.endMultiplier = endMultiplier
    }
}

public struct TimelineClip: Identifiable, Equatable, Codable, Sendable {
    public let id: AudioTimelineClipID
    public var sourceID: TimelineMediaSourceID
    public var timelineRange: TimelineFrameRange
    public var sourceRange: TimelineFrameRange
    public var name: String
    public var gain: Float
    public var gainEnvelope: TimelineClipGainEnvelope
    public var fades: TimelineClipFades
    public var isMuted: Bool
    public var isLocked: Bool
    public var colorToken: String?
    public var metadata: [String: String]

    public init(
        id: AudioTimelineClipID = AudioTimelineClipID(),
        sourceID: TimelineMediaSourceID,
        timelineRange: TimelineFrameRange,
        sourceRange: TimelineFrameRange,
        name: String,
        gain: Float = 1,
        gainEnvelope: TimelineClipGainEnvelope = TimelineClipGainEnvelope(),
        fades: TimelineClipFades = TimelineClipFades(),
        isMuted: Bool = false,
        isLocked: Bool = false,
        colorToken: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sourceID = sourceID
        self.timelineRange = timelineRange
        self.sourceRange = sourceRange
        self.name = name
        self.gain = gain
        self.gainEnvelope = gainEnvelope
        self.fades = fades
        self.isMuted = isMuted
        self.isLocked = isLocked
        self.colorToken = colorToken
        self.metadata = metadata
    }

    public var sourceFrameScale: Double {
        guard timelineRange.frameCount > 0 else {
            return 1
        }
        return Double(sourceRange.frameCount) / Double(timelineRange.frameCount)
    }

    public func validate(against source: TimelineMediaSource?) throws {
        guard timelineRange.startFrame >= 0, timelineRange.frameCount > 0 else {
            throw TimelineClipGraphError.invalidTimelineRange(id)
        }
        guard sourceRange.startFrame >= 0, sourceRange.frameCount > 0 else {
            throw TimelineClipGraphError.invalidSourceRange(id)
        }
        guard
            gain.isFinite,
            gain >= 0,
            gainEnvelope.startMultiplier.isFinite,
            gainEnvelope.startMultiplier >= 0,
            gainEnvelope.endMultiplier.isFinite,
            gainEnvelope.endMultiplier >= 0
        else {
            throw TimelineClipGraphError.invalidGain(id)
        }
        guard
            fades.fadeInFrames >= 0,
            fades.fadeOutFrames >= 0,
            fades.fadeInFrames + fades.fadeOutFrames <= timelineRange.frameCount
        else {
            throw TimelineClipGraphError.invalidFades(id)
        }
        guard let source else {
            throw TimelineClipGraphError.missingSource(sourceID)
        }
        guard
            source.frameCount >= 0,
            source.sampleRate.isFinite,
            source.sampleRate > 0,
            source.channelCount > 0,
            sourceRange.endFrame <= source.frameCount
        else {
            throw TimelineClipGraphError.sourceRangeOutOfBounds(id, sourceID)
        }
    }
}

public enum TimelineClipGraphError: Error, Equatable, Sendable {
    case invalidTimelineSampleRate
    case invalidSource(TimelineMediaSourceID)
    case duplicateSource(TimelineMediaSourceID)
    case sourceIdentityConflict(TimelineMediaSourceID)
    case duplicateTrack(UUID)
    case duplicateClip(AudioTimelineClipID)
    case missingSource(TimelineMediaSourceID)
    case missingTrack(UUID)
    case missingClip(AudioTimelineClipID)
    case invalidTimelineRange(AudioTimelineClipID)
    case invalidSourceRange(AudioTimelineClipID)
    case sourceRangeOutOfBounds(AudioTimelineClipID, TimelineMediaSourceID)
    case invalidGain(AudioTimelineClipID)
    case invalidTrackVolume(UUID)
    case invalidTrackPan(UUID)
    case invalidFades(AudioTimelineClipID)
    case trackOverlap(trackID: UUID, first: AudioTimelineClipID, second: AudioTimelineClipID)
    case destinationOccupied(trackID: UUID, conflicts: [AudioTimelineClipID])
    case clipsNotAdjacent(AudioTimelineClipID, AudioTimelineClipID)
    case lockedClip(AudioTimelineClipID)
    case staleRevision(expected: UInt64, actual: UInt64)
}
