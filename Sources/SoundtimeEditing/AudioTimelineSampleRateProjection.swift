import Foundation

public struct AudioTimelineProjectedSegment: Equatable, Sendable {
    public let outputStartFrame: Int
    public let sourceStartFrame: Int
    public let frameCount: Int
    public let sourceFrameScale: Double
    public let gainStart: Float
    public let gainEnd: Float

    public init(
        outputStartFrame: Int,
        sourceStartFrame: Int,
        frameCount: Int,
        sourceFrameScale: Double,
        gainStart: Float,
        gainEnd: Float
    ) {
        self.outputStartFrame = outputStartFrame
        self.sourceStartFrame = sourceStartFrame
        self.frameCount = frameCount
        self.sourceFrameScale = sourceFrameScale
        self.gainStart = gainStart
        self.gainEnd = gainEnd
    }
}

public enum AudioTimelineSampleRateProjection {
    public static func project(
        _ segment: AudioTimelinePlaybackSegment,
        timelineSampleRate: Double,
        outputSampleRate: Double
    ) -> AudioTimelineProjectedSegment? {
        guard
            timelineSampleRate.isFinite,
            timelineSampleRate > 0,
            outputSampleRate.isFinite,
            outputSampleRate > 0,
            segment.frameCount > 0
        else {
            return nil
        }

        let (nativeEndFrame, didOverflow) = segment.outputStartFrame.addingReportingOverflow(
            segment.frameCount
        )
        guard !didOverflow else {
            return nil
        }
        let outputStartFrame = projectFrame(
            segment.outputStartFrame,
            from: timelineSampleRate,
            to: outputSampleRate
        )
        let outputEndFrame = projectFrame(
            nativeEndFrame,
            from: timelineSampleRate,
            to: outputSampleRate
        )
        let nativeSourceFrameScale = segment.sourceFrameScale > 0 &&
            segment.sourceFrameScale.isFinite ?
            segment.sourceFrameScale :
            1

        let projectedFrameCount = outputEndFrame - outputStartFrame
        guard projectedFrameCount > 0 else {
            return nil
        }

        return AudioTimelineProjectedSegment(
            outputStartFrame: outputStartFrame,
            sourceStartFrame: segment.sourceStartFrame,
            frameCount: projectedFrameCount,
            sourceFrameScale: nativeSourceFrameScale *
                timelineSampleRate /
                outputSampleRate,
            gainStart: segment.gainStart,
            gainEnd: segment.gainEnd
        )
    }

    private static func projectFrame(
        _ frame: Int,
        from sourceSampleRate: Double,
        to outputSampleRate: Double
    ) -> Int {
        Int(
            (
                Double(max(frame, 0)) /
                    sourceSampleRate *
                    outputSampleRate
            ).rounded()
        )
    }
}
