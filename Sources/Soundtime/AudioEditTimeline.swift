import Foundation

struct AudioEditTimeline: Sendable {
    private static let spliceFadeDuration: TimeInterval = 0.005

    typealias FadeDirection = AudioTimelineFadeDirection
    typealias PlaybackSegment = AudioTimelinePlaybackSegment
    typealias ClipRange = AudioTimelineClipRange
    typealias ClipEdge = AudioTimelineClipEdge

    struct Clip: Sendable {
        fileprivate var segments: [AudioTimelineSegment]
        fileprivate let sourceID: UUID
        fileprivate let sourceSampleRate: Double

        var frameCount: Int {
            AudioSegmentArrangement.totalFrameCount(segments)
        }

        var duration: TimeInterval {
            guard sourceSampleRate > 0 else {
                return 0
            }
            return Double(frameCount) / sourceSampleRate
        }
    }

    private let sourceBuffer: DecodedAudioBuffer
    let sourceID: UUID
    private var arrangement: AudioSegmentArrangement

    init(sourceBuffer: DecodedAudioBuffer) {
        self.sourceBuffer = sourceBuffer
        sourceID = UUID()
        arrangement = AudioSegmentArrangement(
            sourceFrameCount: sourceBuffer.frameCount
        )
    }

    init(sourceBuffer: DecodedAudioBuffer, playbackSegments: [PlaybackSegment]) {
        self.sourceBuffer = sourceBuffer
        sourceID = UUID()
        arrangement = AudioSegmentArrangement(
            sourceFrameCount: sourceBuffer.frameCount,
            segments: playbackSegments.map { segment in
                AudioTimelineSegment(
                    sourceStartFrame: segment.sourceStartFrame,
                    frameCount: segment.frameCount,
                    gainStart: max(segment.gainStart, 0),
                    gainEnd: max(segment.gainEnd, 0),
                    startsNewClip: segment.startsNewClip,
                    clipID: segment.clipID
                )
            }
        )
    }

    var frameCount: Int {
        arrangement.frameCount
    }

    var sourceAudioBuffer: DecodedAudioBuffer {
        sourceBuffer
    }

    var playbackSegments: [PlaybackSegment] {
        arrangement.playbackSegments
    }

    var clipRanges: [ClipRange] {
        arrangement.clipRanges
    }

    func clipRange(id: AudioTimelineClipID) -> ClipRange? {
        arrangement.clipRange(id: id)
    }

    func frameRange(forClipID id: AudioTimelineClipID) -> Range<Int>? {
        arrangement.frameRange(forClipID: id)
    }

    var duration: TimeInterval {
        guard sourceBuffer.sampleRate > 0 else {
            return 0
        }
        return Double(frameCount) / sourceBuffer.sampleRate
    }

    func frameRange(for selection: TimelineSelection) -> Range<Int> {
        arrangement.frameRange(for: selection)
    }

    mutating func delete(_ selection: TimelineSelection) -> Int {
        arrangement.delete(frameRange: frameRange(for: selection))
    }

    mutating func delete(frameRange: Range<Int>) -> Int {
        arrangement.delete(frameRange: frameRange)
    }

    mutating func deleteClip(id: AudioTimelineClipID) -> Int {
        arrangement.deleteClip(id: id)
    }

    mutating func deleteClips(ids: Set<AudioTimelineClipID>) -> Int {
        arrangement.deleteClips(ids: ids)
    }

    mutating func deleteWithinClip(
        id: AudioTimelineClipID,
        localFrameRange: Range<Int>,
        followingClipPolicy: AudioTimelineFollowingClipPolicy
    ) -> Int {
        arrangement.deleteWithinClip(
            id: id,
            localFrameRange: localFrameRange,
            followingClipPolicy: followingClipPolicy
        )
    }

    mutating func clearWithinClip(
        id: AudioTimelineClipID,
        localFrameRange: Range<Int>
    ) -> Int {
        arrangement.clearWithinClip(id: id, localFrameRange: localFrameRange)
    }

    mutating func duplicateClip(id: AudioTimelineClipID, atFrame frame: Int) -> AudioTimelineClipID? {
        arrangement.duplicateClip(id: id, atFrame: frame)
    }

    mutating func moveClip(id: AudioTimelineClipID, toFrame frame: Int) -> Range<Int>? {
        arrangement.moveClip(id: id, toFrame: frame)
    }

    mutating func relocateClip(id: AudioTimelineClipID, toFrame frame: Int) -> Range<Int>? {
        arrangement.relocateClip(id: id, toFrame: frame)
    }

    mutating func relocateClips(
        ids: Set<AudioTimelineClipID>,
        byFrames delta: Int
    ) -> [AudioTimelineClipID: Range<Int>]? {
        arrangement.relocateClips(ids: ids, byFrames: delta)
    }

    mutating func splitClip(id: AudioTimelineClipID, atLocalFrame frame: Int) -> AudioTimelineClipID? {
        arrangement.splitClip(id: id, atLocalFrame: frame)
    }

    mutating func trimClipStart(id: AudioTimelineClipID, toLocalFrame frame: Int) -> Int {
        arrangement.trimClipStart(id: id, toLocalFrame: frame)
    }

    mutating func trimClipEnd(id: AudioTimelineClipID, toLocalFrame frame: Int) -> Int {
        arrangement.trimClipEnd(id: id, toLocalFrame: frame)
    }

    mutating func clear(_ selection: TimelineSelection) -> Int {
        arrangement.clear(frameRange: frameRange(for: selection))
    }

    mutating func clear(frameRange: Range<Int>) -> Int {
        arrangement.clear(frameRange: frameRange)
    }

    func clip(for selection: TimelineSelection) -> Clip? {
        clip(for: frameRange(for: selection))
    }

    func clip(for frameRange: Range<Int>) -> Clip? {
        let selectedSegments = arrangement.segments(in: frameRange)
        guard !selectedSegments.isEmpty else {
            return nil
        }
        let copiedClipID = AudioTimelineClipID()
        return Clip(
            segments: selectedSegments.enumerated().map { index, segment in
                segment.withClipID(copiedClipID, startsNewClip: index == 0)
            },
            sourceID: sourceID,
            sourceSampleRate: sourceBuffer.sampleRate
        )
    }

    func isCompatible(with clip: Clip) -> Bool {
        sourceID == clip.sourceID &&
            abs(sourceBuffer.sampleRate - clip.sourceSampleRate) < 0.001
    }

    mutating func replace(_ selection: TimelineSelection, with clip: Clip) -> Int? {
        replace(frameRange: frameRange(for: selection), with: clip)
    }

    mutating func replace(frameRange: Range<Int>, with clip: Clip) -> Int? {
        guard isCompatible(with: clip) else {
            return nil
        }
        return arrangement.replace(
            frameRange: frameRange,
            with: clip.segments
        )
    }

    mutating func insert(_ clip: Clip, atFrame frame: Int) -> Int? {
        guard isCompatible(with: clip) else {
            return nil
        }
        return arrangement.insert(clip.segments, atFrame: frame)
    }

    mutating func insertWithinClip(
        id: AudioTimelineClipID,
        localFrame: Int,
        clip: Clip
    ) -> Int? {
        guard isCompatible(with: clip) else {
            return nil
        }
        return arrangement.insertWithinClip(
            id: id,
            localFrame: localFrame,
            segments: clip.segments
        )
    }

    mutating func insertSilence(frameCount: Int, atProgress progress: Double) -> Int {
        arrangement.insertSilence(
            frameCount: frameCount,
            atProgress: progress
        )
    }

    mutating func applyGain(_ gain: Float, to selection: TimelineSelection) -> Int {
        arrangement.applyGain(gain, frameRange: frameRange(for: selection))
    }

    mutating func applyFade(_ direction: FadeDirection, to selection: TimelineSelection) -> Int {
        arrangement.applyFade(direction, frameRange: frameRange(for: selection))
    }

    mutating func split(atProgress progress: Double) -> Bool {
        arrangement.split(atProgress: progress)
    }

    mutating func healNearestClipBoundary(atProgress progress: Double) -> Bool {
        arrangement.healNearestClipBoundary(atProgress: progress)
    }

    mutating func slipClip(
        _ clipRange: ClipRange,
        byFrameCount frameDelta: Int
    ) -> Int {
        arrangement.slipClip(clipRange, byFrameCount: frameDelta)
    }

    mutating func trim(to trimRange: TimelineTrimRange) -> Int {
        arrangement.trim(to: trimRange)
    }

    mutating func trimClip(
        _ clipRange: ClipRange,
        edge: ClipEdge,
        toProgress targetProgress: Double
    ) -> Int {
        arrangement.trimClip(
            clipRange,
            edge: edge,
            toProgress: targetProgress
        )
    }

    func render() -> DecodedAudioBuffer {
        render(frameRange: 0..<frameCount)
    }

    func render(selection: TimelineSelection) -> DecodedAudioBuffer {
        render(frameRange: frameRange(for: selection))
    }

    func render(frameRange requestedFrameRange: Range<Int>) -> DecodedAudioBuffer {
        let frameRange = arrangement.clampedFrameRange(requestedFrameRange)
        var samplesByChannel = (0..<sourceBuffer.channelCount).map { _ in
            [Float]()
        }
        for channelIndex in samplesByChannel.indices {
            samplesByChannel[channelIndex].reserveCapacity(frameRange.count)
        }

        var isFirstRenderedSegment = true
        let spliceFadeFrameCount = max(
            Int(sourceBuffer.sampleRate * Self.spliceFadeDuration),
            1
        )
        var timelineFrame = 0
        for segment in arrangement.segments where segment.frameCount > 0 {
            let segmentTimelineStart = timelineFrame
            let segmentTimelineEnd = timelineFrame + segment.frameCount
            timelineFrame = segmentTimelineEnd
            let renderStart = max(segmentTimelineStart, frameRange.lowerBound)
            let renderEnd = min(segmentTimelineEnd, frameRange.upperBound)
            guard renderStart < renderEnd else {
                continue
            }

            let segmentOffset = renderStart - segmentTimelineStart
            let sourceStartFrame = segment.sourceStartFrame + segmentOffset
            let sourceEndFrame = sourceStartFrame + renderEnd - renderStart
            for channelIndex in samplesByChannel.indices {
                let sourceSamples = sourceBuffer.samplesByChannel[channelIndex]
                let boundedEnd = min(sourceEndFrame, sourceSamples.count)
                guard sourceStartFrame < boundedEnd else {
                    continue
                }
                if !isFirstRenderedSegment {
                    applySpliceFadeOut(
                        outputSamples: &samplesByChannel[channelIndex],
                        fadeFrameCount: spliceFadeFrameCount
                    )
                }
                appendSegmentSamples(
                    to: &samplesByChannel[channelIndex],
                    sourceSamples: sourceSamples,
                    sourceStartFrame: sourceStartFrame,
                    sourceEndFrame: boundedEnd,
                    fadeInFrameCount: isFirstRenderedSegment ? 0 : spliceFadeFrameCount,
                    segment: segment,
                    segmentOffset: segmentOffset
                )
            }
            isFirstRenderedSegment = false
        }

        return DecodedAudioBuffer(
            url: sourceBuffer.url,
            sampleRate: sourceBuffer.sampleRate,
            channelCount: sourceBuffer.channelCount,
            frameCount: frameRange.count,
            samplesByChannel: samplesByChannel
        )
    }

    private func applySpliceFadeOut(
        outputSamples: inout [Float],
        fadeFrameCount: Int
    ) {
        let count = min(fadeFrameCount, outputSamples.count)
        guard count > 1 else {
            return
        }
        let start = outputSamples.count - count
        for offset in 0..<count {
            let progress = Float(offset) / Float(count - 1)
            outputSamples[start + offset] *= 1 - AudioSegmentArrangement.smoothstep(progress)
        }
    }

    private func appendSegmentSamples(
        to outputSamples: inout [Float],
        sourceSamples: [Float],
        sourceStartFrame: Int,
        sourceEndFrame: Int,
        fadeInFrameCount: Int,
        segment: AudioTimelineSegment,
        segmentOffset: Int
    ) {
        guard sourceStartFrame < sourceEndFrame else {
            return
        }

        let fadeFrameCount = min(
            fadeInFrameCount,
            sourceEndFrame - sourceStartFrame
        )
        if fadeFrameCount > 1 {
            for offset in 0..<fadeFrameCount {
                let progress = Float(offset) / Float(fadeFrameCount - 1)
                let gain = segment.gain(at: segmentOffset + offset)
                outputSamples.append(
                    clampAudioSample(sourceSamples[sourceStartFrame + offset] * gain) *
                        AudioSegmentArrangement.smoothstep(progress)
                )
            }
        }

        let remainingStartFrame = sourceStartFrame + (fadeFrameCount > 1 ? fadeFrameCount : 0)
        guard remainingStartFrame < sourceEndFrame else {
            return
        }
        if segment.hasConstantGain, abs(segment.gainStart - 1) <= AudioSegmentArrangement.gainEpsilon {
            outputSamples.append(contentsOf: sourceSamples[remainingStartFrame..<sourceEndFrame])
        } else {
            for frameIndex in remainingStartFrame..<sourceEndFrame {
                let gain = segment.gain(
                    at: segmentOffset + frameIndex - sourceStartFrame
                )
                outputSamples.append(
                    clampAudioSample(sourceSamples[frameIndex] * gain)
                )
            }
        }
    }

    private func clampAudioSample(_ sample: Float) -> Float {
        min(max(sample, -1), 1)
    }
}
