import Foundation

enum AudioExportRenderer {
    typealias ProgressHandler = @Sendable (Double, AudioExportStage, String) -> Void

    static let defaultBlockFrameCount = 32_768

    static func renderMixdown(
        snapshot: AudioExportSnapshot,
        to writer: AudioExportSampleWriter,
        blockFrameCount: Int = defaultBlockFrameCount,
        progressHandler: ProgressHandler? = nil
    ) throws -> AudioExportRenderStats {
        guard snapshot.frameCount > 0 else {
            throw AudioExportStreamingWAVWriter.WriterError.noSamplesWritten
        }

        progressHandler?(0, .rendering, "Rendering mixdown")
        var renderedFrameCount = 0
        var stats = AudioExportRenderStats.empty
        var outputFrame = snapshot.exportFrameRange.lowerBound
        let blockFrameCount = max(blockFrameCount, 512)

        while outputFrame < snapshot.exportFrameRange.upperBound {
            try Task.checkCancellation()
            let blockEndFrame = min(outputFrame + blockFrameCount, snapshot.exportFrameRange.upperBound)
            let frameRange = outputFrame..<blockEndFrame
            let block = try renderMixdownBlock(
                snapshot: snapshot,
                outputFrameRange: frameRange
            )
            stats.merge(renderStats(for: block))
            try writer.append(samplesByChannel: block.samplesByChannel, frameCount: block.frameCount)
            renderedFrameCount += block.frameCount
            outputFrame = blockEndFrame

            let progress = Double(renderedFrameCount) / Double(max(snapshot.frameCount, 1))
            progressHandler?(progress, .rendering, "Rendering mixdown")
        }

        _ = try writer.finish()
        progressHandler?(1, .finishing, "Finished rendering")
        return stats
    }

    static func renderTrack(
        _ track: AudioExportTrackSnapshot,
        snapshot: AudioExportSnapshot,
        to writer: AudioExportSampleWriter,
        blockFrameCount: Int = defaultBlockFrameCount,
        progressHandler: ProgressHandler? = nil
    ) throws -> AudioExportRenderStats {
        guard snapshot.frameCount > 0 else {
            throw AudioExportStreamingWAVWriter.WriterError.noSamplesWritten
        }

        progressHandler?(0, .rendering, "Rendering \(track.name)")
        var renderedFrameCount = 0
        var stats = AudioExportRenderStats.empty
        var outputFrame = snapshot.exportFrameRange.lowerBound
        let blockFrameCount = max(blockFrameCount, 512)

        while outputFrame < snapshot.exportFrameRange.upperBound {
            try Task.checkCancellation()
            let blockEndFrame = min(outputFrame + blockFrameCount, snapshot.exportFrameRange.upperBound)
            let frameRange = outputFrame..<blockEndFrame
            let block = try renderTrackBlock(
                track,
                snapshot: snapshot,
                outputFrameRange: frameRange,
                appliesTrackVolume: true
            )
            stats.merge(renderStats(for: block))
            try writer.append(samplesByChannel: block.samplesByChannel, frameCount: block.frameCount)
            renderedFrameCount += block.frameCount
            outputFrame = blockEndFrame

            let progress = Double(renderedFrameCount) / Double(max(snapshot.frameCount, 1))
            progressHandler?(progress, .rendering, "Rendering \(track.name)")
        }

        _ = try writer.finish()
        progressHandler?(1, .finishing, "Finished \(track.name)")
        return stats
    }

    private static func renderMixdownBlock(
        snapshot: AudioExportSnapshot,
        outputFrameRange: Range<Int>
    ) throws -> AudioExportRenderedBlock {
        let frameCount = max(outputFrameRange.count, 0)
        var mixedSamples = (0..<snapshot.channelCount).map { _ in
            [Float](repeating: 0, count: frameCount)
        }

        guard frameCount > 0 else {
            return AudioExportRenderedBlock(samplesByChannel: mixedSamples, frameCount: 0)
        }

        for track in snapshot.tracks {
            try Task.checkCancellation()
            let trackBlock = try renderTrackBlock(
                track,
                snapshot: snapshot,
                outputFrameRange: outputFrameRange,
                appliesTrackVolume: true
            )
            for channelIndex in 0..<snapshot.channelCount {
                let sourceChannel = min(channelIndex, trackBlock.samplesByChannel.count - 1)
                let sourceSamples = trackBlock.samplesByChannel[sourceChannel]
                for frameIndex in 0..<min(frameCount, sourceSamples.count) {
                    mixedSamples[channelIndex][frameIndex] += sourceSamples[frameIndex]
                }
            }
        }

        return AudioExportRenderedBlock(samplesByChannel: mixedSamples, frameCount: frameCount)
    }

    private static func renderTrackBlock(
        _ track: AudioExportTrackSnapshot,
        snapshot: AudioExportSnapshot,
        outputFrameRange: Range<Int>,
        appliesTrackVolume: Bool
    ) throws -> AudioExportRenderedBlock {
        let frameCount = max(outputFrameRange.count, 0)
        var samples = (0..<snapshot.channelCount).map { _ in
            [Float](repeating: 0, count: frameCount)
        }
        guard frameCount > 0 else {
            return AudioExportRenderedBlock(samplesByChannel: samples, frameCount: 0)
        }

        let source = try TrackBlockSource(track.source)
        let gain = appliesTrackVolume ? track.volume * track.volume : 1
        guard gain > 0 else {
            return AudioExportRenderedBlock(samplesByChannel: samples, frameCount: frameCount)
        }

        let sourceSampleRate = max(source.sampleRate, 1)
        let outputSampleRate = max(snapshot.sampleRate, 1)
        let segmentFadeFrameCount = max(Int(outputSampleRate * 0.005), 1)
        let segments = source.playbackSegments

        for (segmentIndex, segment) in segments.enumerated() where segment.frameCount > 0 {
            let segmentOutputStart = Int((Double(segment.outputStartFrame) / sourceSampleRate * outputSampleRate).rounded())
            let segmentOutputEnd = Int((Double(segment.outputStartFrame + segment.frameCount) / sourceSampleRate * outputSampleRate).rounded())
            let renderStart = max(segmentOutputStart, outputFrameRange.lowerBound)
            let renderEnd = min(segmentOutputEnd, outputFrameRange.upperBound)
            guard renderStart < renderEnd else {
                continue
            }

            let sourceStart = sourceFrame(
                forOutputFrame: renderStart,
                segmentOutputStart: segmentOutputStart,
                segment: segment,
                sourceSampleRate: sourceSampleRate,
                outputSampleRate: outputSampleRate
            )
            let sourceEnd = min(
                source.sourceFrameCount,
                sourceFrame(
                    forOutputFrame: renderEnd - 1,
                    segmentOutputStart: segmentOutputStart,
                    segment: segment,
                    sourceSampleRate: sourceSampleRate,
                    outputSampleRate: outputSampleRate
                ) + 1
            )
            guard sourceStart < sourceEnd else {
                continue
            }

            let sourceBlock = try source.samples(frameRange: sourceStart..<sourceEnd)
            let isFirstSegment = segmentIndex == 0
            let isLastSegment = segmentIndex == segments.count - 1
            for absoluteOutputFrame in renderStart..<renderEnd {
                let outputIndex = absoluteOutputFrame - outputFrameRange.lowerBound
                let currentSourceFrame = sourceFrame(
                    forOutputFrame: absoluteOutputFrame,
                    segmentOutputStart: segmentOutputStart,
                    segment: segment,
                    sourceSampleRate: sourceSampleRate,
                    outputSampleRate: outputSampleRate
                )
                let sourceIndex = currentSourceFrame - sourceStart
                guard sourceIndex >= 0, sourceIndex < sourceBlock.frameCount else {
                    continue
                }

                let segmentOffset = min(max(currentSourceFrame - segment.sourceStartFrame, 0), segment.frameCount - 1)
                let segmentGain = gainAt(offset: segmentOffset, frameCount: segment.frameCount, start: segment.gainStart, end: segment.gainEnd)
                let spliceGain = spliceGain(
                    absoluteOutputFrame: absoluteOutputFrame,
                    segmentOutputStart: segmentOutputStart,
                    segmentOutputEnd: segmentOutputEnd,
                    fadeFrameCount: segmentFadeFrameCount,
                    fadesIn: !isFirstSegment || segment.startsNewClip,
                    fadesOut: !isLastSegment
                )
                let finalGain = gain * segmentGain * spliceGain
                guard finalGain > 0 else {
                    continue
                }

                for outputChannel in 0..<snapshot.channelCount {
                    let sourceChannel = sourceBlock.channelCount == 1 ?
                        0 :
                        min(outputChannel, sourceBlock.channelCount - 1)
                    let channelSamples = sourceBlock.samplesByChannel[sourceChannel]
                    guard sourceIndex < channelSamples.count else {
                        continue
                    }
                    samples[outputChannel][outputIndex] = clampAudioSample(
                        samples[outputChannel][outputIndex] + channelSamples[sourceIndex] * finalGain
                    )
                }
            }
        }

        return AudioExportRenderedBlock(samplesByChannel: samples, frameCount: frameCount)
    }

    private static func sourceFrame(
        forOutputFrame outputFrame: Int,
        segmentOutputStart: Int,
        segment: AudioEditTimeline.PlaybackSegment,
        sourceSampleRate: Double,
        outputSampleRate: Double
    ) -> Int {
        let outputOffset = max(outputFrame - segmentOutputStart, 0)
        let sourceFrameScale = effectiveSourceFrameScale(
            segment: segment,
            sourceSampleRate: sourceSampleRate,
            outputSampleRate: outputSampleRate
        )
        let sourceOffset = Int((Double(outputOffset) * sourceFrameScale).rounded(.down))
        return min(max(segment.sourceStartFrame + sourceOffset, segment.sourceStartFrame), segment.sourceStartFrame + segment.frameCount - 1)
    }

    private static func effectiveSourceFrameScale(
        segment: AudioEditTimeline.PlaybackSegment,
        sourceSampleRate: Double,
        outputSampleRate: Double
    ) -> Double {
        if segment.sourceFrameScale > 0, segment.sourceFrameScale.isFinite {
            return segment.sourceFrameScale
        }

        guard
            sourceSampleRate.isFinite,
            sourceSampleRate > 0,
            outputSampleRate.isFinite,
            outputSampleRate > 0
        else {
            return 1
        }

        return max(sourceSampleRate / outputSampleRate, .leastNonzeroMagnitude)
    }

    private static func gainAt(offset: Int, frameCount: Int, start: Float, end: Float) -> Float {
        guard frameCount > 1 else {
            return end
        }

        let progress = Float(min(max(offset, 0), frameCount - 1)) / Float(frameCount - 1)
        let curve = smoothstep(progress)
        return start + (end - start) * curve
    }

    private static func spliceGain(
        absoluteOutputFrame: Int,
        segmentOutputStart: Int,
        segmentOutputEnd: Int,
        fadeFrameCount: Int,
        fadesIn: Bool,
        fadesOut: Bool
    ) -> Float {
        var gain: Float = 1
        if fadesIn, fadeFrameCount > 1 {
            let offset = absoluteOutputFrame - segmentOutputStart
            if offset < fadeFrameCount {
                gain *= smoothstep(Float(offset) / Float(fadeFrameCount - 1))
            }
        }
        if fadesOut, fadeFrameCount > 1 {
            let remaining = segmentOutputEnd - absoluteOutputFrame - 1
            if remaining < fadeFrameCount {
                gain *= smoothstep(Float(max(remaining, 0)) / Float(fadeFrameCount - 1))
            }
        }
        return gain
    }

    private static func smoothstep(_ progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        return clampedProgress * clampedProgress * (3 - 2 * clampedProgress)
    }

    private static func clampAudioSample(_ sample: Float) -> Float {
        min(max(sample, -1), 1)
    }

    private static func renderStats(for block: AudioExportRenderedBlock) -> AudioExportRenderStats {
        var peak: Float = 0
        var clippedSampleCount = 0
        for channelSamples in block.samplesByChannel {
            for sample in channelSamples.prefix(block.frameCount) {
                let magnitude = abs(sample)
                peak = max(peak, magnitude)
                if magnitude > 1 {
                    clippedSampleCount += 1
                }
            }
        }
        return AudioExportRenderStats(
            renderedFrameCount: block.frameCount,
            peakMagnitude: peak,
            clippedSampleCount: clippedSampleCount
        )
    }
}

private struct AudioExportRenderedBlock {
    let samplesByChannel: [[Float]]
    let frameCount: Int
}

private struct TrackBlockSource {
    let sampleRate: Double
    let channelCount: Int
    let sourceFrameCount: Int
    let playbackSegments: [AudioEditTimeline.PlaybackSegment]
    private let sampleProvider: @Sendable (Range<Int>) throws -> DecodedAudioBuffer

    init(_ source: AudioExportTrackSource) throws {
        switch source {
        case let .decoded(buffer):
            sampleRate = buffer.sampleRate
            channelCount = buffer.channelCount
            sourceFrameCount = buffer.frameCount
            playbackSegments = [
                AudioEditTimeline.PlaybackSegment(
                    outputStartFrame: 0,
                    sourceStartFrame: 0,
                    frameCount: buffer.frameCount,
                    sourceFrameScale: 0,
                    gainStart: 1,
                    gainEnd: 1
                ),
            ]
            sampleProvider = { frameRange in
                Self.slice(buffer, frameRange: frameRange)
            }
        case let .timeline(timeline):
            let sourceBuffer = timeline.sourceAudioBuffer
            sampleRate = sourceBuffer.sampleRate
            channelCount = sourceBuffer.channelCount
            sourceFrameCount = sourceBuffer.frameCount
            playbackSegments = timeline.playbackSegments
            sampleProvider = { frameRange in
                Self.slice(sourceBuffer, frameRange: frameRange)
            }
        case let .file(url, fileInfo):
            sampleRate = fileInfo.sampleRate
            channelCount = fileInfo.channelCount
            sourceFrameCount = fileInfo.frameCount
            playbackSegments = [
                AudioEditTimeline.PlaybackSegment(
                    outputStartFrame: 0,
                    sourceStartFrame: 0,
                    frameCount: fileInfo.frameCount,
                    sourceFrameScale: 0,
                    gainStart: 1,
                    gainEnd: 1
                ),
            ]
            sampleProvider = { frameRange in
                try WAVAudioDecoder.decode(url: url, frameRange: frameRange)
            }
        case let .fileTimeline(url, fileInfo, fileTimeline):
            sampleRate = fileInfo.sampleRate
            channelCount = fileInfo.channelCount
            sourceFrameCount = fileInfo.frameCount
            playbackSegments = fileTimeline.playbackSegments
            sampleProvider = { frameRange in
                try WAVAudioDecoder.decode(url: url, frameRange: frameRange)
            }
        }
    }

    func samples(frameRange requestedFrameRange: Range<Int>) throws -> DecodedAudioBuffer {
        let lowerBound = min(max(requestedFrameRange.lowerBound, 0), sourceFrameCount)
        let upperBound = min(max(requestedFrameRange.upperBound, lowerBound), sourceFrameCount)
        return try sampleProvider(lowerBound..<upperBound)
    }

    private static func slice(
        _ buffer: DecodedAudioBuffer,
        frameRange requestedFrameRange: Range<Int>
    ) -> DecodedAudioBuffer {
        let lowerBound = min(max(requestedFrameRange.lowerBound, 0), buffer.frameCount)
        let upperBound = min(max(requestedFrameRange.upperBound, lowerBound), buffer.frameCount)
        let samplesByChannel = buffer.samplesByChannel.map { samples in
            let end = min(upperBound, samples.count)
            let start = min(lowerBound, end)
            return Array(samples[start..<end])
        }
        return DecodedAudioBuffer(
            url: buffer.url,
            sampleRate: buffer.sampleRate,
            channelCount: buffer.channelCount,
            frameCount: max(upperBound - lowerBound, 0),
            samplesByChannel: samplesByChannel
        )
    }
}
