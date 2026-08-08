import Foundation

public struct TimelineMediaRelinkCandidate: Equatable, Sendable {
    public var resolvedAbsolutePath: String
    public var relativePath: String?
    public var acceptedFingerprints: Set<String>
    public var frameCount: Int
    public var sampleRate: Double
    public var channelCount: Int
    public var metadata: [String: String]

    public init(
        resolvedAbsolutePath: String,
        relativePath: String? = nil,
        acceptedFingerprints: Set<String> = [],
        frameCount: Int,
        sampleRate: Double,
        channelCount: Int,
        metadata: [String: String] = [:]
    ) {
        self.resolvedAbsolutePath = resolvedAbsolutePath
        self.relativePath = relativePath
        self.acceptedFingerprints = acceptedFingerprints
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.metadata = metadata
    }
}

public struct TimelineMediaRelinkPlan: Equatable, Sendable {
    public let sourceBefore: TimelineMediaSource
    public let sourceAfter: TimelineMediaSource
    public let affectedTrackIDs: Set<UUID>
    public let affectedClipIDs: Set<AudioTimelineClipID>

    public init(
        sourceBefore: TimelineMediaSource,
        sourceAfter: TimelineMediaSource,
        affectedTrackIDs: Set<UUID>,
        affectedClipIDs: Set<AudioTimelineClipID>
    ) {
        self.sourceBefore = sourceBefore
        self.sourceAfter = sourceAfter
        self.affectedTrackIDs = affectedTrackIDs
        self.affectedClipIDs = affectedClipIDs
    }
}

public enum TimelineMediaRelinkError: Error, Equatable, Sendable {
    case missingSource(TimelineMediaSourceID)
    case invalidCandidate
    case fingerprintMismatch(expected: String)
    case incompatibleAudioFormat(
        expectedSampleRate: Double,
        actualSampleRate: Double,
        expectedChannelCount: Int,
        actualChannelCount: Int
    )
    case candidateTooShort(requiredFrameCount: Int, actualFrameCount: Int)
}

/// Validates a located media file without changing clip or source identity.
///
/// A known fingerprint is authoritative. Older projects without one use a
/// conservative structural match and still require enough frames for every
/// source range already referenced by the graph.
public enum TimelineMediaRelinkPlanner {
    public static let contentFingerprintMetadataKey = "contentFingerprint"

    public static func plan(
        sourceID: TimelineMediaSourceID,
        candidate: TimelineMediaRelinkCandidate,
        in graph: TimelineClipGraph
    ) throws -> TimelineMediaRelinkPlan {
        guard let source = graph.source(id: sourceID) else {
            throw TimelineMediaRelinkError.missingSource(sourceID)
        }
        guard
            !candidate.resolvedAbsolutePath.isEmpty,
            candidate.frameCount >= 0,
            candidate.sampleRate.isFinite,
            candidate.sampleRate > 0,
            candidate.channelCount > 0
        else {
            throw TimelineMediaRelinkError.invalidCandidate
        }

        if let fingerprint = source.metadata[contentFingerprintMetadataKey], !fingerprint.isEmpty {
            guard candidate.metadata[contentFingerprintMetadataKey] == fingerprint else {
                throw TimelineMediaRelinkError.fingerprintMismatch(expected: fingerprint)
            }
        } else if let fingerprint = source.fingerprint, !fingerprint.isEmpty {
            guard candidate.acceptedFingerprints.contains(fingerprint) else {
                throw TimelineMediaRelinkError.fingerprintMismatch(expected: fingerprint)
            }
        } else {
            guard
                abs(candidate.sampleRate - source.sampleRate) < 0.000_1,
                candidate.channelCount == source.channelCount
            else {
                throw TimelineMediaRelinkError.incompatibleAudioFormat(
                    expectedSampleRate: source.sampleRate,
                    actualSampleRate: candidate.sampleRate,
                    expectedChannelCount: source.channelCount,
                    actualChannelCount: candidate.channelCount
                )
            }
        }

        let references = graph.tracks.flatMap { track in
            track.clips.compactMap { clip -> (UUID, TimelineClip)? in
                clip.sourceID == sourceID ? (track.id, clip) : nil
            }
        }
        let requiredFrameCount = references.map { $0.1.sourceRange.endFrame }.max() ?? 0
        guard candidate.frameCount >= requiredFrameCount else {
            throw TimelineMediaRelinkError.candidateTooShort(
                requiredFrameCount: requiredFrameCount,
                actualFrameCount: candidate.frameCount
            )
        }

        var updated = source
        updated.absolutePath = candidate.resolvedAbsolutePath
        updated.relativePath = candidate.relativePath
        updated.frameCount = candidate.frameCount
        updated.sampleRate = candidate.sampleRate
        updated.channelCount = candidate.channelCount
        updated.metadata.merge(candidate.metadata) { _, replacement in replacement }
        updated.metadata.removeValue(forKey: "missingMedia")
        updated.metadata["mediaResolution"] = "relinked"

        return TimelineMediaRelinkPlan(
            sourceBefore: source,
            sourceAfter: updated,
            affectedTrackIDs: Set(references.map(\.0)),
            affectedClipIDs: Set(references.map { $0.1.id })
        )
    }
}
