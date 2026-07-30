import Foundation

struct TranscriptSourceTimeMap: Codable, Equatable, Sendable {
    struct Projection: Equatable, Sendable {
        var sourceRange: Range<TimeInterval>
        var outputRange: Range<TimeInterval>
    }

    struct Segment: Codable, Equatable, Sendable {
        var outputStartTime: TimeInterval
        var outputEndTime: TimeInterval
        var sourceStartTime: TimeInterval
        var sourceEndTime: TimeInterval
        var gainStart: Float
        var gainEnd: Float

        init(
            outputStartTime: TimeInterval,
            outputEndTime: TimeInterval,
            sourceStartTime: TimeInterval,
            sourceEndTime: TimeInterval,
            gainStart: Float = 1,
            gainEnd: Float = 1
        ) {
            self.outputStartTime = min(max(outputStartTime, 0), max(outputEndTime, 0))
            self.outputEndTime = max(max(outputStartTime, 0), max(outputEndTime, 0))
            self.sourceStartTime = max(sourceStartTime, 0)
            self.sourceEndTime = max(sourceEndTime, 0)
            self.gainStart = gainStart
            self.gainEnd = gainEnd
        }

        var outputDuration: TimeInterval {
            max(outputEndTime - outputStartTime, 0)
        }

        var sourceDuration: TimeInterval {
            abs(sourceEndTime - sourceStartTime)
        }

        var isReversed: Bool {
            sourceEndTime < sourceStartTime
        }

        func sourceTime(forOutputTime outputTime: TimeInterval) -> TimeInterval? {
            guard outputDuration > 0 else {
                return nil
            }
            guard outputTime >= outputStartTime, outputTime <= outputEndTime else {
                return nil
            }
            let progress = min(max((outputTime - outputStartTime) / outputDuration, 0), 1)
            return sourceStartTime + (sourceEndTime - sourceStartTime) * progress
        }

        func outputRange(forSourceRange range: Range<TimeInterval>) -> Range<TimeInterval>? {
            guard outputDuration > 0, sourceDuration > 0 else {
                return nil
            }
            let lower = min(sourceStartTime, sourceEndTime)
            let upper = max(sourceStartTime, sourceEndTime)
            let overlapStart = max(range.lowerBound, lower)
            let overlapEnd = min(range.upperBound, upper)
            guard overlapEnd > overlapStart else {
                return nil
            }

            let startProgress = (overlapStart - lower) / sourceDuration
            let endProgress = (overlapEnd - lower) / sourceDuration
            if isReversed {
                let outputStart = outputStartTime + (1 - endProgress) * outputDuration
                let outputEnd = outputStartTime + (1 - startProgress) * outputDuration
                return min(outputStart, outputEnd)..<max(outputStart, outputEnd)
            }

            let outputStart = outputStartTime + startProgress * outputDuration
            let outputEnd = outputStartTime + endProgress * outputDuration
            return min(outputStart, outputEnd)..<max(outputStart, outputEnd)
        }
    }

    var sourceDuration: TimeInterval
    var timelineDuration: TimeInterval
    var segments: [Segment]

    init(sourceDuration: TimeInterval, timelineDuration: TimeInterval, segments: [Segment]) {
        self.sourceDuration = max(sourceDuration, 0)
        self.timelineDuration = max(timelineDuration, 0)
        self.segments = segments
            .filter { $0.outputDuration > 0 }
            .sorted { lhs, rhs in
                if lhs.outputStartTime == rhs.outputStartTime {
                    return lhs.outputEndTime < rhs.outputEndTime
                }
                return lhs.outputStartTime < rhs.outputStartTime
            }
    }

    static func identity(duration: TimeInterval) -> TranscriptSourceTimeMap {
        let duration = max(duration, 0)
        return TranscriptSourceTimeMap(
            sourceDuration: duration,
            timelineDuration: duration,
            segments: duration > 0 ? [
                Segment(
                    outputStartTime: 0,
                    outputEndTime: duration,
                    sourceStartTime: 0,
                    sourceEndTime: duration
                ),
            ] : []
        )
    }

    static func fromTimeline(_ timeline: AudioFileEditTimeline) -> TranscriptSourceTimeMap {
        fromPlaybackSegments(
            timeline.playbackSegments,
            sampleRate: timeline.sourceSampleRate,
            sourceFrameCount: timeline.sourceFrameCount,
            timelineFrameCount: timeline.frameCount
        )
    }

    static func fromTimeline(_ timeline: AudioEditTimeline) -> TranscriptSourceTimeMap {
        fromPlaybackSegments(
            timeline.playbackSegments,
            sampleRate: timeline.sourceAudioBuffer.sampleRate,
            sourceFrameCount: timeline.sourceAudioBuffer.frameCount,
            timelineFrameCount: timeline.frameCount
        )
    }

    private static func fromPlaybackSegments(
        _ playbackSegments: [AudioEditTimeline.PlaybackSegment],
        sampleRate: Double,
        sourceFrameCount: Int,
        timelineFrameCount: Int
    ) -> TranscriptSourceTimeMap {
        guard sampleRate > 0 else {
            return .identity(duration: 0)
        }
        let sourceDuration = TimeInterval(sourceFrameCount) / sampleRate
        let timelineDuration = TimeInterval(timelineFrameCount) / sampleRate
        let segments = playbackSegments.compactMap { segment -> Segment? in
            guard max(segment.gainStart, segment.gainEnd) > AudioSegmentArrangement.gainEpsilon else {
                return nil
            }
            return Segment(
                outputStartTime: TimeInterval(segment.outputStartFrame) / sampleRate,
                outputEndTime: TimeInterval(segment.outputStartFrame + segment.frameCount) / sampleRate,
                sourceStartTime: TimeInterval(segment.sourceStartFrame) / sampleRate,
                sourceEndTime: TimeInterval(segment.sourceStartFrame + segment.frameCount) / sampleRate,
                gainStart: segment.gainStart,
                gainEnd: segment.gainEnd
            )
        }
        return TranscriptSourceTimeMap(
            sourceDuration: sourceDuration,
            timelineDuration: timelineDuration,
            segments: segments
        )
    }

    static func fromRenderTrack(_ track: TimelineRenderState.Track) -> TranscriptSourceTimeMap {
        let outputDuration = max(track.durationHint ?? track.waveformOverview?.duration ?? 0, 0)
        let sourceDuration = max(track.transcript?.sourceDuration ?? outputDuration, outputDuration)
        guard outputDuration > 0, sourceDuration > 0 else {
            return .identity(duration: 0)
        }
        guard !track.waveformSegments.isEmpty else {
            return .identity(duration: outputDuration)
        }

        let segments = track.waveformSegments.map { segment in
            Segment(
                outputStartTime: TimeInterval(segment.outputStartProgress) * outputDuration,
                outputEndTime: TimeInterval(segment.outputEndProgress) * outputDuration,
                sourceStartTime: TimeInterval(segment.sourceStartProgress) * sourceDuration,
                sourceEndTime: TimeInterval(segment.sourceEndProgress) * sourceDuration,
                gainStart: segment.gainStart,
                gainEnd: segment.gainEnd
            )
        }
        return TranscriptSourceTimeMap(
            sourceDuration: sourceDuration,
            timelineDuration: outputDuration,
            segments: segments
        )
    }

    func sourceTime(forProjectTime projectTime: TimeInterval) -> TimeInterval? {
        for segment in segments {
            if let sourceTime = segment.sourceTime(forOutputTime: projectTime) {
                return sourceTime
            }
        }
        return nil
    }

    func projectRanges(forSourceRange sourceRange: Range<TimeInterval>) -> [Range<TimeInterval>] {
        projections(forSourceRange: sourceRange).map(\.outputRange)
    }

    func projections(forSourceRange sourceRange: Range<TimeInterval>) -> [Projection] {
        segments.compactMap { segment in
            let segmentSourceRange = Range(
                uncheckedBounds: (
                    lower: min(segment.sourceStartTime, segment.sourceEndTime),
                    upper: max(segment.sourceStartTime, segment.sourceEndTime)
                )
            )
            let overlapStart = max(sourceRange.lowerBound, segmentSourceRange.lowerBound)
            let overlapEnd = min(sourceRange.upperBound, segmentSourceRange.upperBound)
            guard overlapEnd > overlapStart,
                  let outputRange = segment.outputRange(
                      forSourceRange: overlapStart..<overlapEnd
                  )
            else {
                return nil
            }
            return Projection(
                sourceRange: overlapStart..<overlapEnd,
                outputRange: outputRange
            )
        }
        .sorted { lhs, rhs in
            if lhs.outputRange.lowerBound == rhs.outputRange.lowerBound {
                return lhs.outputRange.upperBound < rhs.outputRange.upperBound
            }
            return lhs.outputRange.lowerBound < rhs.outputRange.lowerBound
        }
    }

    func sourceRangeCoveringProjectRange(_ projectRange: Range<TimeInterval>) -> Range<TimeInterval>? {
        guard !projectRange.isEmpty else {
            return nil
        }

        var lower = TimeInterval.greatestFiniteMagnitude
        var upper = -TimeInterval.greatestFiniteMagnitude
        for segment in segments {
            guard segment.outputEndTime >= projectRange.lowerBound,
                  segment.outputStartTime <= projectRange.upperBound
            else {
                continue
            }
            if let sourceStart = segment.sourceTime(forOutputTime: max(projectRange.lowerBound, segment.outputStartTime)),
               let sourceEnd = segment.sourceTime(forOutputTime: min(projectRange.upperBound, segment.outputEndTime)) {
                lower = min(lower, sourceStart, sourceEnd)
                upper = max(upper, sourceStart, sourceEnd)
            }
        }

        guard lower.isFinite, upper.isFinite, upper > lower else {
            return nil
        }
        return lower..<upper
    }

    func remappedDocument(_ transcript: TranscriptDocument, sourceRevision: Int) -> TranscriptDocument {
        var remapped = transcript
        remapped.sourceRevision = sourceRevision
        remapped.sourceDuration = sourceDuration
        remapped.validity = .remapped
        remapped.sourceTimeMap = self
        return remapped
    }
}
