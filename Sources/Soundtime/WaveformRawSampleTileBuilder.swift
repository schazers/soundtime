import Foundation

enum WaveformRawSampleTileBuilder {
    static func buildWAVRawSampleTile(
        url: URL,
        descriptor: WaveformTileDescriptor,
        channelMode: WaveformChannelMode = .monoMix,
        shouldYieldForPlayback: Bool = true
    ) throws -> WaveformRawSampleTile {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let fileInfo = try WAVAudioDecoder.inspect(url: url)
        guard descriptor.address.kind == .rawSamples else {
            throw WaveformRawSampleTileBuilderError.expectedRawSampleDescriptor(descriptor.address)
        }

        let startFrame = min(max(0, descriptor.frameRange.startFrame), Int64(fileInfo.frameCount))
        let endFrame = min(max(startFrame, descriptor.frameRange.endFrame), Int64(fileInfo.frameCount))
        let frameCount = max(0, Int(endFrame - startFrame))
        let channels = outputChannels(for: channelMode, channelCount: fileInfo.channelCount)
        var samplesByChannel = Array(
            repeating: [Float](),
            count: channels.outputChannelCount
        )

        for index in samplesByChannel.indices {
            samplesByChannel[index].reserveCapacity(frameCount)
        }

        for frameOffset in 0..<frameCount {
            if shouldYieldForPlayback, frameOffset.isMultiple(of: 4096) {
                try ImportWorkBudget.shared.waitIfPlaybackActive(.previewRefinement)
            }

            let frameIndex = Int(startFrame) + frameOffset
            switch channels {
            case let .mono(indices):
                var mixedSample: Float = 0
                for channelIndex in indices {
                    mixedSample += try WAVAudioDecoder.sample(
                        in: data,
                        fileInfo: fileInfo,
                        frameIndex: frameIndex,
                        channelIndex: channelIndex
                    )
                }
                samplesByChannel[0].append(mixedSample / Float(max(indices.count, 1)))
            case let .stereo(leftIndex, rightIndex):
                samplesByChannel[0].append(try WAVAudioDecoder.sample(
                    in: data,
                    fileInfo: fileInfo,
                    frameIndex: frameIndex,
                    channelIndex: leftIndex
                ))
                samplesByChannel[1].append(try WAVAudioDecoder.sample(
                    in: data,
                    fileInfo: fileInfo,
                    frameIndex: frameIndex,
                    channelIndex: rightIndex
                ))
            }
        }

        return WaveformRawSampleTile(
            descriptor: WaveformTileDescriptor(
                address: descriptor.address,
                frameRange: WaveformFrameRange(startFrame: startFrame, endFrame: endFrame),
                framesPerBin: 1,
                expectedBinCount: frameCount
            ),
            samplesByChannel: samplesByChannel
        )
    }

    private enum ChannelLayout {
        case mono([Int])
        case stereo(left: Int, right: Int)

        var outputChannelCount: Int {
            switch self {
            case .mono:
                return 1
            case .stereo:
                return 2
            }
        }
    }

    private static func outputChannels(
        for channelMode: WaveformChannelMode,
        channelCount: Int
    ) -> ChannelLayout {
        let safeChannelCount = max(1, channelCount)
        switch channelMode {
        case .left:
            return .mono([0])
        case .right:
            return .mono([min(1, safeChannelCount - 1)])
        case .monoMix:
            return .mono(Array(0..<safeChannelCount))
        case .stereoPair:
            return .stereo(left: 0, right: min(1, safeChannelCount - 1))
        }
    }
}

enum WaveformRawSampleTileBuilderError: Error, CustomStringConvertible {
    case expectedRawSampleDescriptor(WaveformTileAddress)

    var description: String {
        switch self {
        case let .expectedRawSampleDescriptor(address):
            return "Expected a raw-sample tile descriptor, got \(address)."
        }
    }
}
