import Foundation

enum AudioSilenceAnalyzer {
    struct Region: Sendable, Equatable {
        let startFrame: Int
        let endFrame: Int

        var frameCount: Int {
            max(endFrame - startFrame, 0)
        }

        func duration(sampleRate: Double) -> TimeInterval {
            guard sampleRate > 0 else {
                return 0
            }
            return Double(frameCount) / sampleRate
        }
    }

    struct Configuration: Sendable, Equatable {
        var thresholdDecibels: Float
        var minimumSilenceDuration: TimeInterval
        var paddingDuration: TimeInterval
        var roomToneHandleDuration: TimeInterval = 0.09

        static let podcastCleanup = Configuration(
            thresholdDecibels: -44,
            minimumSilenceDuration: 0.45,
            paddingDuration: 0.09,
            roomToneHandleDuration: 0.12
        )
    }

    static func detectSilence(
        in buffer: DecodedAudioBuffer,
        configuration: Configuration = .podcastCleanup
    ) -> [Region] {
        guard
            buffer.frameCount > 0,
            buffer.sampleRate > 0,
            !buffer.samplesByChannel.isEmpty
        else {
            return []
        }

        let thresholdAmplitude = pow(10, configuration.thresholdDecibels / 20)
        let minimumFrameCount = max(Int((configuration.minimumSilenceDuration * buffer.sampleRate).rounded()), 1)
        var regions: [Region] = []
        var silenceStartFrame: Int?

        for frameIndex in 0..<buffer.frameCount {
            var peak: Float = 0
            for channelSamples in buffer.samplesByChannel {
                guard frameIndex < channelSamples.count else {
                    continue
                }
                peak = max(peak, abs(channelSamples[frameIndex]))
            }

            if peak <= thresholdAmplitude {
                if silenceStartFrame == nil {
                    silenceStartFrame = frameIndex
                }
            } else if let startFrame = silenceStartFrame {
                appendRegion(
                    startFrame: startFrame,
                    endFrame: frameIndex,
                    minimumFrameCount: minimumFrameCount,
                    regions: &regions
                )
                silenceStartFrame = nil
            }
        }

        if let startFrame = silenceStartFrame {
            appendRegion(
                startFrame: startFrame,
                endFrame: buffer.frameCount,
                minimumFrameCount: minimumFrameCount,
                regions: &regions
            )
        }

        return regions
    }

    static func deletionRanges(
        for regions: [Region],
        sampleRate: Double,
        configuration: Configuration = .podcastCleanup
    ) -> [Range<Int>] {
        guard sampleRate > 0 else {
            return []
        }

        let paddingFrameCount = max(Int((configuration.paddingDuration * sampleRate).rounded()), 0)
        let roomToneFrameCount = max(Int((configuration.roomToneHandleDuration * sampleRate).rounded()), 0)
        let preservedFrameCount = max(paddingFrameCount, roomToneFrameCount)
        let minimumDeleteFrameCount = max(Int((0.04 * sampleRate).rounded()), 1)
        return regions.compactMap { region in
            let deleteStartFrame = region.startFrame + preservedFrameCount
            let deleteEndFrame = region.endFrame - preservedFrameCount
            guard deleteEndFrame - deleteStartFrame >= minimumDeleteFrameCount else {
                return nil
            }
            return deleteStartFrame..<deleteEndFrame
        }
    }

    private static func appendRegion(
        startFrame: Int,
        endFrame: Int,
        minimumFrameCount: Int,
        regions: inout [Region]
    ) {
        guard endFrame - startFrame >= minimumFrameCount else {
            return
        }
        regions.append(Region(startFrame: startFrame, endFrame: endFrame))
    }
}
