import Foundation

struct WaveformPeakLevelBuildResult: Sendable {
    let sourceID: WaveformSourceID
    let fingerprint: WaveformFileFingerprint
    let fileInfo: WAVFileInfo
    let level: WaveformDiskCacheManifest.TileLevel
    let tiles: [WaveformPeakTile]
}

enum WaveformPeakTileBuilder {
    static let defaultFramesPerBin = 64
    static let defaultFramesPerTile: Int64 = 65_536

    static func buildWAVPeakLevel(
        url: URL,
        framesPerBin: Int = defaultFramesPerBin,
        framesPerTile: Int64 = defaultFramesPerTile,
        level: Int = 0,
        channelMode: WaveformChannelMode = .monoMix,
        shouldYieldForPlayback: Bool = true
    ) throws -> WaveformPeakLevelBuildResult {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let fileInfo = try WAVAudioDecoder.inspect(url: url)
        let fingerprint = try WaveformFileFingerprint(url: url, wavFileInfo: fileInfo)
        let sourceID = WaveformSourceID(fingerprint: fingerprint)
        let framesPerBin = max(1, framesPerBin)
        let framesPerTile = max(1, framesPerTile)
        let tileCount = Int((Int64(fileInfo.frameCount) + framesPerTile - 1) / framesPerTile)
        let fileName = peakLevelFileName(
            kind: .peak,
            channelMode: channelMode,
            level: level
        )
        var tiles: [WaveformPeakTile] = []
        tiles.reserveCapacity(tileCount)

        for tileIndex in 0..<tileCount {
            if shouldYieldForPlayback, tileIndex.isMultiple(of: 4) {
                try ImportWorkBudget.shared.waitIfPlaybackActive(.previewRefinement)
            }

            let startFrame = Int64(tileIndex) * framesPerTile
            let endFrame = min(startFrame + framesPerTile, Int64(fileInfo.frameCount))
            let descriptor = WaveformTileDescriptor(
                address: WaveformTileAddress(
                    sourceID: sourceID,
                    kind: .peak,
                    channelMode: channelMode,
                    level: level,
                    tileIndex: tileIndex
                ),
                frameRange: WaveformFrameRange(startFrame: startFrame, endFrame: endFrame),
                framesPerBin: framesPerBin,
                expectedBinCount: Int((endFrame - startFrame + Int64(framesPerBin) - 1) / Int64(framesPerBin))
            )
            let bins = try buildBins(
                data: data,
                fileInfo: fileInfo,
                descriptor: descriptor,
                channelMode: channelMode,
                shouldYieldForPlayback: shouldYieldForPlayback
            )
            tiles.append(WaveformPeakTile(descriptor: descriptor, bins: bins))
        }

        let level = WaveformDiskCacheManifest.TileLevel(
            kind: .peak,
            channelMode: channelMode,
            level: level,
            framesPerBin: framesPerBin,
            framesPerTile: framesPerTile,
            tileCount: tileCount,
            fileName: fileName
        )

        return WaveformPeakLevelBuildResult(
            sourceID: sourceID,
            fingerprint: fingerprint,
            fileInfo: fileInfo,
            level: level,
            tiles: tiles
        )
    }

    static func peakLevelFileName(
        kind: WaveformTileKind,
        channelMode: WaveformChannelMode,
        level: Int
    ) -> String {
        "\(kind.rawValue)-\(channelMode.rawValue)-l\(String(format: "%03d", max(0, level))).bin"
    }

    private static func buildBins(
        data: Data,
        fileInfo: WAVFileInfo,
        descriptor: WaveformTileDescriptor,
        channelMode: WaveformChannelMode,
        shouldYieldForPlayback: Bool
    ) throws -> [WaveformOverview.Bin] {
        guard !descriptor.frameRange.isEmpty else {
            return []
        }

        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(descriptor.expectedBinCount)
        var binStartFrame = descriptor.frameRange.startFrame

        while binStartFrame < descriptor.frameRange.endFrame {
            if shouldYieldForPlayback, bins.count.isMultiple(of: 512) {
                try ImportWorkBudget.shared.waitIfPlaybackActive(.previewRefinement)
            }

            let binEndFrame = min(
                binStartFrame + Int64(descriptor.framesPerBin),
                descriptor.frameRange.endFrame
            )
            var accumulator = WaveformBinAccumulator()

            for frame in binStartFrame..<binEndFrame {
                for channelIndex in channelIndices(for: channelMode, channelCount: fileInfo.channelCount) {
                    let sample = try WAVAudioDecoder.sample(
                        in: data,
                        fileInfo: fileInfo,
                        frameIndex: Int(frame),
                        channelIndex: channelIndex
                    )
                    accumulator.addSample(sample)
                }
            }

            bins.append(accumulator.makeBin())
            binStartFrame = binEndFrame
        }

        return bins
    }

    private static func channelIndices(for channelMode: WaveformChannelMode, channelCount: Int) -> Range<Int> {
        switch channelMode {
        case .left:
            return 0..<min(channelCount, 1)
        case .right:
            guard channelCount > 1 else {
                return 0..<min(channelCount, 1)
            }
            return 1..<2
        case .monoMix, .stereoPair:
            return 0..<channelCount
        }
    }
}

enum WaveformPeakTileBinaryCodec {
    static let floatsPerBin = 6

    static func encode(_ tiles: [WaveformPeakTile]) -> Data {
        var data = Data()
        for tile in tiles {
            for bin in tile.bins {
                appendFloat(bin.minimumSample, to: &data)
                appendFloat(bin.maximumSample, to: &data)
                appendFloat(bin.rmsSample, to: &data)
                appendFloat(bin.lowEnergy, to: &data)
                appendFloat(bin.midEnergy, to: &data)
                appendFloat(bin.highEnergy, to: &data)
            }
        }
        return data
    }

    static func decode(
        data: Data,
        level: WaveformDiskCacheManifest.TileLevel,
        sourceID: WaveformSourceID
    ) throws -> [WaveformPeakTile] {
        let byteStride = MemoryLayout<Float>.size * floatsPerBin
        guard byteStride > 0, data.count % byteStride == 0 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Peak tile data length is not aligned to bin stride."
            ))
        }

        let totalBinCount = data.count / byteStride
        var tiles: [WaveformPeakTile] = []
        tiles.reserveCapacity(level.tileCount)
        var binOffset = 0

        for tileIndex in 0..<level.tileCount {
            let remainingBins = totalBinCount - binOffset
            guard remainingBins > 0 else {
                break
            }

            let startFrame = Int64(tileIndex) * level.framesPerTile
            let idealBinCount = Int((level.framesPerTile + Int64(level.framesPerBin) - 1) / Int64(level.framesPerBin))
            let binCount = min(remainingBins, idealBinCount)
            let endFrame = startFrame + Int64(binCount * level.framesPerBin)
            let descriptor = WaveformTileDescriptor(
                address: WaveformTileAddress(
                    sourceID: sourceID,
                    kind: level.kind,
                    channelMode: level.channelMode,
                    level: level.level,
                    tileIndex: tileIndex
                ),
                frameRange: WaveformFrameRange(startFrame: startFrame, endFrame: endFrame),
                framesPerBin: level.framesPerBin,
                expectedBinCount: binCount
            )
            var bins: [WaveformOverview.Bin] = []
            bins.reserveCapacity(binCount)
            for _ in 0..<binCount {
                bins.append(WaveformOverview.Bin(
                    minimumSample: readFloat(in: data, binOffset: binOffset, component: 0),
                    maximumSample: readFloat(in: data, binOffset: binOffset, component: 1),
                    rmsSample: readFloat(in: data, binOffset: binOffset, component: 2),
                    lowEnergy: readFloat(in: data, binOffset: binOffset, component: 3),
                    midEnergy: readFloat(in: data, binOffset: binOffset, component: 4),
                    highEnergy: readFloat(in: data, binOffset: binOffset, component: 5)
                ))
                binOffset += 1
            }
            tiles.append(WaveformPeakTile(descriptor: descriptor, bins: bins))
        }

        return tiles
    }

    private static func appendFloat(_ value: Float, to data: inout Data) {
        var bitPattern = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bitPattern) {
            data.append(contentsOf: $0)
        }
    }

    private static func readFloat(in data: Data, binOffset: Int, component: Int) -> Float {
        let byteOffset = (binOffset * floatsPerBin + component) * MemoryLayout<Float>.size
        let value = data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self)
        }
        return Float(bitPattern: UInt32(littleEndian: value))
    }
}
