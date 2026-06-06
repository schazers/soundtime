import Foundation

struct AudioFileEditTimeline: Sendable {
    private static let gainEpsilon: Float = 0.000_001

    struct PersistentSegment: Codable, Sendable {
        var sourceStartFrame: Int
        var frameCount: Int
        var gainStart: Float
        var gainEnd: Float
    }

    struct PersistentState: Codable, Sendable {
        var sourceFrameCount: Int
        var sourceSampleRate: Double
        var segments: [PersistentSegment]
    }

    private struct Segment: Sendable {
        let sourceStartFrame: Int
        let frameCount: Int
        let gainStart: Float
        let gainEnd: Float

        var sourceEndFrame: Int {
            sourceStartFrame + frameCount
        }

        var hasConstantGain: Bool {
            abs(gainStart - gainEnd) <= AudioFileEditTimeline.gainEpsilon
        }

        func gain(at offset: Int) -> Float {
            guard frameCount > 1 else {
                return gainEnd
            }

            let clampedOffset = min(max(offset, 0), frameCount - 1)
            let progress = Float(clampedOffset) / Float(frameCount - 1)
            let curve = AudioFileEditTimeline.smoothstep(progress)
            return gainStart + (gainEnd - gainStart) * curve
        }

        func scaled(by gain: Float) -> Segment {
            Segment(
                sourceStartFrame: sourceStartFrame,
                frameCount: frameCount,
                gainStart: gainStart * gain,
                gainEnd: gainEnd * gain
            )
        }

        func scaled(startMultiplier: Float, endMultiplier: Float) -> Segment {
            Segment(
                sourceStartFrame: sourceStartFrame,
                frameCount: frameCount,
                gainStart: gainStart * startMultiplier,
                gainEnd: gainEnd * endMultiplier
            )
        }
    }

    let sourceFrameCount: Int
    let sourceSampleRate: Double
    private var segments: [Segment]

    init(fileInfo: WAVFileInfo) {
        sourceFrameCount = fileInfo.frameCount
        sourceSampleRate = fileInfo.sampleRate
        if fileInfo.frameCount > 0 {
            segments = [
                Segment(
                    sourceStartFrame: 0,
                    frameCount: fileInfo.frameCount,
                    gainStart: 1,
                    gainEnd: 1
                ),
            ]
        } else {
            segments = []
        }
    }

    init?(persistentState: PersistentState) {
        guard
            persistentState.sourceFrameCount >= 0,
            persistentState.sourceSampleRate > 0,
            persistentState.sourceSampleRate.isFinite
        else {
            return nil
        }

        sourceFrameCount = persistentState.sourceFrameCount
        sourceSampleRate = persistentState.sourceSampleRate
        segments = Self.validatedSegments(
            persistentState.segments.map { persistentSegment in
                Segment(
                    sourceStartFrame: persistentSegment.sourceStartFrame,
                    frameCount: persistentSegment.frameCount,
                    gainStart: persistentSegment.gainStart,
                    gainEnd: persistentSegment.gainEnd
                )
            },
            sourceFrameCount: persistentState.sourceFrameCount
        )

        guard persistentState.sourceFrameCount == 0 || !segments.isEmpty else {
            return nil
        }
    }

    init?(
        sourceFrameCount: Int,
        sourceSampleRate: Double,
        playbackSegments: [AudioEditTimeline.PlaybackSegment]
    ) {
        guard
            sourceFrameCount >= 0,
            sourceSampleRate > 0,
            sourceSampleRate.isFinite
        else {
            return nil
        }

        self.sourceFrameCount = sourceFrameCount
        self.sourceSampleRate = sourceSampleRate
        segments = Self.validatedSegments(
            playbackSegments.map { playbackSegment in
                Segment(
                    sourceStartFrame: playbackSegment.sourceStartFrame,
                    frameCount: playbackSegment.frameCount,
                    gainStart: playbackSegment.gainStart,
                    gainEnd: playbackSegment.gainEnd
                )
            },
            sourceFrameCount: sourceFrameCount
        )

        guard sourceFrameCount == 0 || !segments.isEmpty else {
            return nil
        }
    }

    var frameCount: Int {
        segments.reduce(0) { total, segment in
            total + segment.frameCount
        }
    }

    var duration: TimeInterval {
        guard sourceSampleRate > 0 else {
            return 0
        }
        return Double(frameCount) / sourceSampleRate
    }

    var hasEdits: Bool {
        guard segments.count == 1, let segment = segments.first else {
            return true
        }

        return segment.sourceStartFrame != 0 ||
            segment.frameCount != sourceFrameCount ||
            abs(segment.gainStart - 1) > Float.ulpOfOne ||
            abs(segment.gainEnd - 1) > Float.ulpOfOne
    }

    var persistentState: PersistentState? {
        guard sourceFrameCount >= 0, sourceSampleRate > 0, sourceSampleRate.isFinite else {
            return nil
        }

        return PersistentState(
            sourceFrameCount: sourceFrameCount,
            sourceSampleRate: sourceSampleRate,
            segments: segments.map { segment in
                PersistentSegment(
                    sourceStartFrame: segment.sourceStartFrame,
                    frameCount: segment.frameCount,
                    gainStart: segment.gainStart,
                    gainEnd: segment.gainEnd
                )
            }
        )
    }

    var playbackSegments: [AudioEditTimeline.PlaybackSegment] {
        var outputStartFrame = 0
        return segments.map { segment in
            defer {
                outputStartFrame += segment.frameCount
            }

            return AudioEditTimeline.PlaybackSegment(
                outputStartFrame: outputStartFrame,
                sourceStartFrame: segment.sourceStartFrame,
                frameCount: segment.frameCount,
                sourceFrameScale: 0,
                gainStart: segment.gainStart,
                gainEnd: segment.gainEnd
            )
        }
    }

    func audioTimeline(sourceBuffer: DecodedAudioBuffer) -> AudioEditTimeline {
        AudioEditTimeline(
            sourceBuffer: sourceBuffer,
            playbackSegments: playbackSegments
        )
    }

    func isCompatible(with fileInfo: WAVFileInfo) -> Bool {
        sourceFrameCount == fileInfo.frameCount &&
            abs(sourceSampleRate - fileInfo.sampleRate) < 0.001
    }

    func waveformOverview(from sourceOverview: WaveformOverview) -> WaveformOverview {
        guard sourceFrameCount > 0, !sourceOverview.bins.isEmpty else {
            return WaveformOverview(duration: duration, bins: [])
        }

        var editedBins: [WaveformOverview.Bin] = []
        let sourceBinCount = sourceOverview.bins.count
        let sourceFramesPerBin = Double(sourceFrameCount) / Double(sourceBinCount)
        for segment in segments {
            let startBin = min(
                max(Int((Double(segment.sourceStartFrame) / sourceFramesPerBin).rounded(.down)), 0),
                sourceBinCount
            )
            let endBin = min(
                max(Int((Double(segment.sourceEndFrame) / sourceFramesPerBin).rounded(.up)), startBin),
                sourceBinCount
            )
            guard startBin < endBin else {
                continue
            }

            editedBins.reserveCapacity(editedBins.count + endBin - startBin)
            for sourceBinIndex in startBin..<endBin {
                let binCenterFrame = min(
                    max(Int((Double(sourceBinIndex) + 0.5) * sourceFramesPerBin), segment.sourceStartFrame),
                    max(segment.sourceEndFrame - 1, segment.sourceStartFrame)
                )
                editedBins.append(sourceOverview.bins[sourceBinIndex].scaled(
                    by: segment.gain(at: binCenterFrame - segment.sourceStartFrame)
                ))
            }
        }

        return WaveformOverview(duration: duration, bins: editedBins)
    }

    mutating func delete(_ selection: TimelineSelection) -> Int {
        deleteFrames(in: frameRange(for: selection))
    }

    mutating func applyGain(_ gain: Float, to selection: TimelineSelection) -> Int {
        applyGain(gain, toFramesIn: frameRange(for: selection))
    }

    mutating func applyFade(_ direction: AudioEditTimeline.FadeDirection, to selection: TimelineSelection) -> Int {
        applyFade(direction, toFramesIn: frameRange(for: selection))
    }

    private func frameRange(for selection: TimelineSelection) -> Range<Int> {
        let startFrame = Int((selection.startProgress * Double(frameCount)).rounded(.down))
        let endFrame = Int((selection.endProgress * Double(frameCount)).rounded(.up))
        return max(startFrame, 0)..<min(max(endFrame, startFrame), frameCount)
    }

    private mutating func deleteFrames(in frameRange: Range<Int>) -> Int {
        guard
            frameRange.lowerBound < frameRange.upperBound,
            frameRange.lowerBound < frameCount,
            frameRange.upperBound > 0
        else {
            return 0
        }

        let clampedRange = max(frameRange.lowerBound, 0)..<min(frameRange.upperBound, frameCount)
        var nextSegments: [Segment] = []
        var timelineFrame = 0

        for segment in segments {
            let segmentStartFrame = timelineFrame
            let segmentEndFrame = timelineFrame + segment.frameCount
            timelineFrame = segmentEndFrame

            let overlapStartFrame = max(segmentStartFrame, clampedRange.lowerBound)
            let overlapEndFrame = min(segmentEndFrame, clampedRange.upperBound)

            guard overlapStartFrame < overlapEndFrame else {
                nextSegments.append(segment)
                continue
            }

            let beforeCount = overlapStartFrame - segmentStartFrame
            if beforeCount > 0 {
                nextSegments.append(Segment(
                    sourceStartFrame: segment.sourceStartFrame,
                    frameCount: beforeCount,
                    gainStart: segment.gainStart,
                    gainEnd: segment.gainEnd
                ))
            }

            let afterCount = segmentEndFrame - overlapEndFrame
            if afterCount > 0 {
                nextSegments.append(Segment(
                    sourceStartFrame: segment.sourceStartFrame + overlapEndFrame - segmentStartFrame,
                    frameCount: afterCount,
                    gainStart: segment.gainStart,
                    gainEnd: segment.gainEnd
                ))
            }
        }

        let deletedFrameCount = frameCount - nextSegments.reduce(0) { total, segment in
            total + segment.frameCount
        }
        segments = Self.coalescedSegments(nextSegments)
        return deletedFrameCount
    }

    private mutating func applyGain(_ gain: Float, toFramesIn frameRange: Range<Int>) -> Int {
        guard
            frameRange.lowerBound < frameRange.upperBound,
            frameRange.lowerBound < frameCount,
            frameRange.upperBound > 0,
            gain >= 0,
            gain.isFinite
        else {
            return 0
        }

        let clampedRange = max(frameRange.lowerBound, 0)..<min(frameRange.upperBound, frameCount)
        var nextSegments: [Segment] = []
        var timelineFrame = 0
        var affectedFrameCount = 0

        for segment in segments {
            let segmentStartFrame = timelineFrame
            let segmentEndFrame = timelineFrame + segment.frameCount
            timelineFrame = segmentEndFrame

            let overlapStartFrame = max(segmentStartFrame, clampedRange.lowerBound)
            let overlapEndFrame = min(segmentEndFrame, clampedRange.upperBound)

            guard overlapStartFrame < overlapEndFrame else {
                nextSegments.append(segment)
                continue
            }

            let beforeCount = overlapStartFrame - segmentStartFrame
            if beforeCount > 0 {
                nextSegments.append(slice(segment, offset: 0, count: beforeCount))
            }

            let selectedCount = overlapEndFrame - overlapStartFrame
            nextSegments.append(slice(
                segment,
                offset: overlapStartFrame - segmentStartFrame,
                count: selectedCount
            ).scaled(by: gain))
            affectedFrameCount += selectedCount

            let afterCount = segmentEndFrame - overlapEndFrame
            if afterCount > 0 {
                nextSegments.append(slice(
                    segment,
                    offset: overlapEndFrame - segmentStartFrame,
                    count: afterCount
                ))
            }
        }

        segments = Self.coalescedSegments(nextSegments)
        return affectedFrameCount
    }

    private mutating func applyFade(
        _ direction: AudioEditTimeline.FadeDirection,
        toFramesIn frameRange: Range<Int>
    ) -> Int {
        guard
            frameRange.lowerBound < frameRange.upperBound,
            frameRange.lowerBound < frameCount,
            frameRange.upperBound > 0
        else {
            return 0
        }

        let clampedRange = max(frameRange.lowerBound, 0)..<min(frameRange.upperBound, frameCount)
        let selectedFrameCount = clampedRange.count
        var nextSegments: [Segment] = []
        var timelineFrame = 0
        var affectedFrameCount = 0

        for segment in segments {
            let segmentStartFrame = timelineFrame
            let segmentEndFrame = timelineFrame + segment.frameCount
            timelineFrame = segmentEndFrame

            let overlapStartFrame = max(segmentStartFrame, clampedRange.lowerBound)
            let overlapEndFrame = min(segmentEndFrame, clampedRange.upperBound)

            guard overlapStartFrame < overlapEndFrame else {
                nextSegments.append(segment)
                continue
            }

            let beforeCount = overlapStartFrame - segmentStartFrame
            if beforeCount > 0 {
                nextSegments.append(slice(segment, offset: 0, count: beforeCount))
            }

            let selectedCount = overlapEndFrame - overlapStartFrame
            let selectedStartOffset = overlapStartFrame - clampedRange.lowerBound
            let selectedEndOffset = selectedStartOffset + selectedCount - 1
            let startMultiplier = Self.fadeMultiplier(
                for: direction,
                selectedOffset: selectedStartOffset,
                selectedFrameCount: selectedFrameCount
            )
            let endMultiplier = Self.fadeMultiplier(
                for: direction,
                selectedOffset: selectedEndOffset,
                selectedFrameCount: selectedFrameCount
            )
            nextSegments.append(slice(
                segment,
                offset: overlapStartFrame - segmentStartFrame,
                count: selectedCount
            ).scaled(startMultiplier: startMultiplier, endMultiplier: endMultiplier))
            affectedFrameCount += selectedCount

            let afterCount = segmentEndFrame - overlapEndFrame
            if afterCount > 0 {
                nextSegments.append(slice(
                    segment,
                    offset: overlapEndFrame - segmentStartFrame,
                    count: afterCount
                ))
            }
        }

        segments = Self.coalescedSegments(nextSegments)
        return affectedFrameCount
    }

    private func slice(_ segment: Segment, offset: Int, count: Int) -> Segment {
        guard count > 0 else {
            return Segment(
                sourceStartFrame: segment.sourceStartFrame + offset,
                frameCount: 0,
                gainStart: segment.gain(at: offset),
                gainEnd: segment.gain(at: offset)
            )
        }

        return Segment(
            sourceStartFrame: segment.sourceStartFrame + offset,
            frameCount: count,
            gainStart: segment.gain(at: offset),
            gainEnd: segment.gain(at: offset + count - 1)
        )
    }

    private static func smoothstep(_ progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        return clampedProgress * clampedProgress * (3 - 2 * clampedProgress)
    }

    private static func fadeMultiplier(
        for direction: AudioEditTimeline.FadeDirection,
        selectedOffset: Int,
        selectedFrameCount: Int
    ) -> Float {
        guard selectedFrameCount > 1 else {
            return direction == .fadeIn ? 1 : 0
        }

        let progress = Float(min(max(selectedOffset, 0), selectedFrameCount - 1)) /
            Float(selectedFrameCount - 1)
        let curve = smoothstep(progress)
        switch direction {
        case .fadeIn:
            return curve
        case .fadeOut:
            return 1 - curve
        }
    }

    private static func coalescedSegments(_ segments: [Segment]) -> [Segment] {
        var result: [Segment] = []
        result.reserveCapacity(segments.count)

        for segment in segments where segment.frameCount > 0 {
            guard let previous = result.last else {
                result.append(segment)
                continue
            }

            if
                previous.sourceEndFrame == segment.sourceStartFrame,
                previous.hasConstantGain,
                segment.hasConstantGain,
                abs(previous.gainStart - segment.gainStart) <= Self.gainEpsilon
            {
                result[result.count - 1] = Segment(
                    sourceStartFrame: previous.sourceStartFrame,
                    frameCount: previous.frameCount + segment.frameCount,
                    gainStart: previous.gainStart,
                    gainEnd: previous.gainEnd
                )
            } else {
                result.append(segment)
            }
        }

        return result
    }

    private static func validatedSegments(
        _ segments: [Segment],
        sourceFrameCount: Int
    ) -> [Segment] {
        coalescedSegments(segments.compactMap { segment in
            guard
                segment.sourceStartFrame >= 0,
                segment.frameCount > 0,
                segment.sourceStartFrame < sourceFrameCount,
                segment.gainStart >= 0,
                segment.gainStart.isFinite,
                segment.gainEnd >= 0,
                segment.gainEnd.isFinite
            else {
                return nil
            }

            let frameCount = min(segment.frameCount, sourceFrameCount - segment.sourceStartFrame)
            guard frameCount > 0 else {
                return nil
            }

            return Segment(
                sourceStartFrame: segment.sourceStartFrame,
                frameCount: frameCount,
                gainStart: segment.gainStart,
                gainEnd: segment.gainEnd
            )
        })
    }
}
