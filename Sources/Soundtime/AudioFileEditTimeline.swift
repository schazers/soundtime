import Foundation

struct AudioFileEditTimeline: Sendable {
    private static let gainEpsilon: Float = 0.000_001

    struct PersistentSegment: Codable, Sendable {
        var sourceStartFrame: Int
        var frameCount: Int
        var gainStart: Float
        var gainEnd: Float
        var startsNewClip: Bool?

        init(
            sourceStartFrame: Int,
            frameCount: Int,
            gainStart: Float,
            gainEnd: Float,
            startsNewClip: Bool? = nil
        ) {
            self.sourceStartFrame = sourceStartFrame
            self.frameCount = frameCount
            self.gainStart = gainStart
            self.gainEnd = gainEnd
            self.startsNewClip = startsNewClip
        }
    }

    struct PersistentState: Codable, Sendable {
        var sourceFrameCount: Int
        var sourceSampleRate: Double
        var segments: [PersistentSegment]
    }

    struct Clip: Sendable {
        var sourceFrameCount: Int
        var sourceSampleRate: Double
        var segments: [PersistentSegment]

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
    }

    private struct Segment: Sendable {
        let sourceStartFrame: Int
        let frameCount: Int
        let gainStart: Float
        let gainEnd: Float
        let startsNewClip: Bool

        init(
            sourceStartFrame: Int,
            frameCount: Int,
            gainStart: Float,
            gainEnd: Float,
            startsNewClip: Bool = false
        ) {
            self.sourceStartFrame = sourceStartFrame
            self.frameCount = frameCount
            self.gainStart = gainStart
            self.gainEnd = gainEnd
            self.startsNewClip = startsNewClip
        }

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
                gainEnd: gainEnd * gain,
                startsNewClip: startsNewClip
            )
        }

        func scaled(startMultiplier: Float, endMultiplier: Float) -> Segment {
            Segment(
                sourceStartFrame: sourceStartFrame,
                frameCount: frameCount,
                gainStart: gainStart * startMultiplier,
                gainEnd: gainEnd * endMultiplier,
                startsNewClip: startsNewClip
            )
        }

        func withClipBoundary(_ startsNewClip: Bool) -> Segment {
            Segment(
                sourceStartFrame: sourceStartFrame,
                frameCount: frameCount,
                gainStart: gainStart,
                gainEnd: gainEnd,
                startsNewClip: startsNewClip
            )
        }
    }

    let sourceFrameCount: Int
    let sourceSampleRate: Double
    private var segments: [Segment]
    private var timelineFrameCount: Int

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
            timelineFrameCount = fileInfo.frameCount
        } else {
            segments = []
            timelineFrameCount = 0
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
                    gainEnd: persistentSegment.gainEnd,
                    startsNewClip: persistentSegment.startsNewClip == true
                )
            },
            sourceFrameCount: persistentState.sourceFrameCount
        )
        timelineFrameCount = Self.totalFrameCount(segments)

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
                    gainEnd: playbackSegment.gainEnd,
                    startsNewClip: playbackSegment.startsNewClip
                )
            },
            sourceFrameCount: sourceFrameCount
        )
        timelineFrameCount = Self.totalFrameCount(segments)

        guard sourceFrameCount == 0 || !segments.isEmpty else {
            return nil
        }
    }

    var frameCount: Int {
        timelineFrameCount
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
                    gainEnd: segment.gainEnd,
                    startsNewClip: segment.startsNewClip ? true : nil
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
                gainEnd: segment.gainEnd,
                startsNewClip: segment.startsNewClip
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

    func isCompatible(with clip: Clip) -> Bool {
        sourceFrameCount == clip.sourceFrameCount &&
            abs(sourceSampleRate - clip.sourceSampleRate) < 0.001
    }

    func clip(for selection: TimelineSelection) -> Clip? {
        let selectedSegments = segments(in: frameRange(for: selection))
        guard !selectedSegments.isEmpty else {
            return nil
        }

        return Clip(
            sourceFrameCount: sourceFrameCount,
            sourceSampleRate: sourceSampleRate,
            segments: selectedSegments.map { segment in
                PersistentSegment(
                    sourceStartFrame: segment.sourceStartFrame,
                    frameCount: segment.frameCount,
                    gainStart: segment.gainStart,
                    gainEnd: segment.gainEnd,
                    startsNewClip: segment.startsNewClip ? true : nil
                )
            }
        )
    }

    mutating func replace(_ selection: TimelineSelection, with clip: Clip) -> Int? {
        guard isCompatible(with: clip) else {
            return nil
        }

        let replacementSegments = Self.validatedSegments(
            clip.segments.map { persistentSegment in
                Segment(
                    sourceStartFrame: persistentSegment.sourceStartFrame,
                    frameCount: persistentSegment.frameCount,
                    gainStart: persistentSegment.gainStart,
                    gainEnd: persistentSegment.gainEnd,
                    startsNewClip: persistentSegment.startsNewClip == true
                )
            },
            sourceFrameCount: sourceFrameCount
        )
        guard !replacementSegments.isEmpty else {
            return nil
        }

        let replacementRange = clampedFrameRange(for: selection)
        let beforeSegments = segments(in: 0..<replacementRange.lowerBound)
        let afterSegments = segments(in: replacementRange.upperBound..<frameCount)
        segments = Self.coalescedSegments(beforeSegments + replacementSegments + afterSegments)
        let replacementFrameCount = Self.totalFrameCount(replacementSegments)
        timelineFrameCount = timelineFrameCount - replacementRange.count + replacementFrameCount
        return replacementFrameCount
    }

    func waveformOverview(from sourceOverview: WaveformOverview) -> WaveformOverview {
        guard sourceFrameCount > 0, !sourceOverview.bins.isEmpty else {
            return WaveformOverview(duration: duration, bins: [])
        }

        let sourceBinCount = sourceOverview.bins.count
        var editedBins: [WaveformOverview.Bin] = []
        editedBins.reserveCapacity(sourceBinCount)
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

            if segment.hasConstantGain {
                let gain = segment.gainStart
                if abs(gain - 1) <= Self.gainEpsilon {
                    editedBins.append(contentsOf: sourceOverview.bins[startBin..<endBin])
                } else {
                    for sourceBinIndex in startBin..<endBin {
                        editedBins.append(sourceOverview.bins[sourceBinIndex].scaled(by: gain))
                    }
                }
                continue
            }

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

    mutating func delete(frameRange: Range<Int>) -> Int {
        deleteFrames(in: frameRange)
    }

    mutating func applyGain(_ gain: Float, to selection: TimelineSelection) -> Int {
        applyGain(gain, toFramesIn: frameRange(for: selection))
    }

    mutating func applyFade(_ direction: AudioEditTimeline.FadeDirection, to selection: TimelineSelection) -> Int {
        applyFade(direction, toFramesIn: frameRange(for: selection))
    }

    mutating func split(atProgress progress: Double) -> Bool {
        guard progress.isFinite, timelineFrameCount > 1 else {
            return false
        }

        let splitFrame = Int((progress * Double(timelineFrameCount)).rounded())
        return split(atFrame: splitFrame)
    }

    private func frameRange(for selection: TimelineSelection) -> Range<Int> {
        let startFrame = Int((selection.startProgress * Double(frameCount)).rounded(.down))
        let endFrame = Int((selection.endProgress * Double(frameCount)).rounded(.up))
        return max(startFrame, 0)..<min(max(endFrame, startFrame), frameCount)
    }

    private func clampedFrameRange(for selection: TimelineSelection) -> Range<Int> {
        let startFrame = Int((selection.startProgress * Double(frameCount)).rounded(.down))
        let endFrame = Int((selection.endProgress * Double(frameCount)).rounded(.up))
        let lowerBound = min(max(startFrame, 0), frameCount)
        let upperBound = min(max(endFrame, lowerBound), frameCount)
        return lowerBound..<upperBound
    }

    private func segments(in frameRange: Range<Int>) -> [Segment] {
        guard
            frameRange.lowerBound < frameRange.upperBound,
            frameRange.lowerBound < frameCount,
            frameRange.upperBound > 0
        else {
            return []
        }

        let clampedRange = max(frameRange.lowerBound, 0)..<min(frameRange.upperBound, frameCount)
        var outputSegments: [Segment] = []
        outputSegments.reserveCapacity(segments.count)
        var timelineFrame = 0

        for segment in segments {
            let segmentStartFrame = timelineFrame
            let segmentEndFrame = timelineFrame + segment.frameCount
            timelineFrame = segmentEndFrame

            let overlapStartFrame = max(segmentStartFrame, clampedRange.lowerBound)
            let overlapEndFrame = min(segmentEndFrame, clampedRange.upperBound)

            guard overlapStartFrame < overlapEndFrame else {
                continue
            }

            outputSegments.append(slice(
                segment,
                offset: overlapStartFrame - segmentStartFrame,
                count: overlapEndFrame - overlapStartFrame
            ))
        }

        return Self.coalescedSegments(outputSegments)
    }

    private mutating func deleteFrames(in frameRange: Range<Int>) -> Int {
        guard
            frameRange.lowerBound < frameRange.upperBound,
            frameRange.lowerBound < timelineFrameCount,
            frameRange.upperBound > 0
        else {
            return 0
        }

        let originalFrameCount = timelineFrameCount
        let clampedRange = max(frameRange.lowerBound, 0)..<min(frameRange.upperBound, originalFrameCount)
        var nextSegments: [Segment] = []
        nextSegments.reserveCapacity(segments.count + 2)
        var timelineFrame = 0
        var deletedFrameCount = 0

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

            deletedFrameCount += overlapEndFrame - overlapStartFrame
            let beforeCount = overlapStartFrame - segmentStartFrame
            if beforeCount > 0 {
                nextSegments.append(Segment(
                    sourceStartFrame: segment.sourceStartFrame,
                    frameCount: beforeCount,
                    gainStart: segment.gainStart,
                    gainEnd: segment.gainEnd,
                    startsNewClip: segment.startsNewClip
                ))
            }

            let afterCount = segmentEndFrame - overlapEndFrame
            if afterCount > 0 {
                nextSegments.append(Segment(
                    sourceStartFrame: segment.sourceStartFrame + overlapEndFrame - segmentStartFrame,
                    frameCount: afterCount,
                    gainStart: segment.gainStart,
                    gainEnd: segment.gainEnd,
                    startsNewClip: overlapEndFrame == segmentStartFrame ? segment.startsNewClip : false
                ))
            }
        }

        segments = Self.coalescedSegments(nextSegments)
        timelineFrameCount = originalFrameCount - deletedFrameCount
        return deletedFrameCount
    }

    private mutating func applyGain(_ gain: Float, toFramesIn frameRange: Range<Int>) -> Int {
        guard
            frameRange.lowerBound < frameRange.upperBound,
            frameRange.lowerBound < timelineFrameCount,
            frameRange.upperBound > 0,
            gain >= 0,
            gain.isFinite
        else {
            return 0
        }

        let clampedRange = max(frameRange.lowerBound, 0)..<min(frameRange.upperBound, timelineFrameCount)
        var nextSegments: [Segment] = []
        nextSegments.reserveCapacity(segments.count + 2)
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
            frameRange.lowerBound < timelineFrameCount,
            frameRange.upperBound > 0
        else {
            return 0
        }

        let clampedRange = max(frameRange.lowerBound, 0)..<min(frameRange.upperBound, timelineFrameCount)
        let selectedFrameCount = clampedRange.count
        var nextSegments: [Segment] = []
        nextSegments.reserveCapacity(segments.count + 2)
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
                gainEnd: segment.gain(at: offset),
                startsNewClip: offset == 0 && segment.startsNewClip
            )
        }

        return Segment(
            sourceStartFrame: segment.sourceStartFrame + offset,
            frameCount: count,
            gainStart: segment.gain(at: offset),
            gainEnd: segment.gain(at: offset + count - 1),
            startsNewClip: offset == 0 && segment.startsNewClip
        )
    }

    private mutating func split(atFrame requestedFrame: Int) -> Bool {
        guard requestedFrame > 0, requestedFrame < timelineFrameCount else {
            return false
        }

        var nextSegments: [Segment] = []
        nextSegments.reserveCapacity(segments.count + 1)
        var timelineFrame = 0
        var didSplit = false

        for segment in segments {
            let segmentStartFrame = timelineFrame
            let segmentEndFrame = timelineFrame + segment.frameCount
            timelineFrame = segmentEndFrame

            if requestedFrame == segmentStartFrame, !nextSegments.isEmpty {
                if segment.startsNewClip {
                    nextSegments.append(segment)
                } else {
                    nextSegments.append(segment.withClipBoundary(true))
                    didSplit = true
                }
                continue
            }

            guard requestedFrame > segmentStartFrame, requestedFrame < segmentEndFrame else {
                nextSegments.append(segment)
                continue
            }

            let beforeCount = requestedFrame - segmentStartFrame
            let afterCount = segmentEndFrame - requestedFrame
            nextSegments.append(slice(segment, offset: 0, count: beforeCount))
            nextSegments.append(slice(segment, offset: beforeCount, count: afterCount).withClipBoundary(true))
            didSplit = true
        }

        guard didSplit else {
            return false
        }

        segments = Self.coalescedSegments(nextSegments)
        timelineFrameCount = Self.totalFrameCount(segments)
        return true
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

        for rawSegment in segments where rawSegment.frameCount > 0 {
            let segment = result.isEmpty ? rawSegment.withClipBoundary(false) : rawSegment
            guard let previous = result.last else {
                result.append(segment)
                continue
            }

            if
                !segment.startsNewClip,
                previous.sourceEndFrame == segment.sourceStartFrame,
                previous.hasConstantGain,
                segment.hasConstantGain,
                abs(previous.gainStart - segment.gainStart) <= Self.gainEpsilon
            {
                result[result.count - 1] = Segment(
                    sourceStartFrame: previous.sourceStartFrame,
                    frameCount: previous.frameCount + segment.frameCount,
                    gainStart: previous.gainStart,
                    gainEnd: previous.gainEnd,
                    startsNewClip: previous.startsNewClip
                )
            } else {
                result.append(segment)
            }
        }

        return result
    }

    private static func totalFrameCount(_ segments: [Segment]) -> Int {
        segments.reduce(0) { total, segment in
            total + segment.frameCount
        }
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
                gainEnd: segment.gainEnd,
                startsNewClip: segment.startsNewClip
            )
        })
    }
}
