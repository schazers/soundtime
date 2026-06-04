import Foundation

enum WAVAudioDecoder {
    enum DecodeError: LocalizedError {
        case unsupportedFileType
        case invalidHeader
        case invalidChunk
        case missingFormatChunk
        case missingDataChunk
        case unsupportedFormat(UInt16)
        case unsupportedBitDepth(Int)
        case invalidFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedFileType:
                "Only WAV files can be decoded in this milestone."
            case .invalidHeader:
                "The file is not a valid RIFF/WAVE file."
            case .invalidChunk:
                "The WAV file contains an invalid chunk."
            case .missingFormatChunk:
                "The WAV file is missing its format chunk."
            case .missingDataChunk:
                "The WAV file is missing its audio data chunk."
            case let .unsupportedFormat(format):
                "Unsupported WAV audio format \(format)."
            case let .unsupportedBitDepth(bitDepth):
                "Unsupported WAV bit depth \(bitDepth)."
            case .invalidFormat:
                "The WAV file format is invalid."
            }
        }
    }

    static func canDecode(_ url: URL) -> Bool {
        ["wav", "wave"].contains(url.pathExtension.lowercased())
    }

    static func inspect(url: URL) throws -> WAVFileInfo {
        guard canDecode(url) else {
            throw DecodeError.unsupportedFileType
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try inspect(in: data, url: url)
    }

    static func buildSparsePreview(
        url: URL,
        targetBinCount: Int = 512,
        samplesPerBin: Int = 8
    ) throws -> (WAVFileInfo, WaveformOverview) {
        guard canDecode(url) else {
            throw DecodeError.unsupportedFileType
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let fileInfo = try inspect(in: data, url: url)
        let waveformOverview = try buildSparsePreview(
            in: data,
            fileInfo: fileInfo,
            targetBinCount: targetBinCount,
            samplesPerBin: samplesPerBin
        )
        return (fileInfo, waveformOverview)
    }

    static func decode(url: URL) throws -> DecodedAudioBuffer {
        guard canDecode(url) else {
            throw DecodeError.unsupportedFileType
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let fileInfo = try inspect(in: data, url: url)
        return try decodeSamples(in: data, fileInfo: fileInfo)
    }

    static func makeZeroCrossingProbe(url: URL, fileInfo: WAVFileInfo) throws -> WAVZeroCrossingProbe {
        try validateDecodable(fileInfo)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return WAVZeroCrossingProbe(data: data, fileInfo: fileInfo)
    }

    static func mixedSample(in data: Data, fileInfo: WAVFileInfo, frameIndex: Int) throws -> Float {
        guard fileInfo.frameCount > 0 else {
            return 0
        }

        let bytesPerSample = bytesPerSample(for: fileInfo)
        let clampedFrameIndex = min(max(frameIndex, 0), fileInfo.frameCount - 1)
        let frameOffset = fileInfo.dataRange.lowerBound + clampedFrameIndex * fileInfo.blockAlign
        var sample: Float = 0

        for channelIndex in 0..<fileInfo.channelCount {
            let sampleOffset = frameOffset + channelIndex * bytesPerSample
            sample += try decodeSample(
                in: data,
                at: sampleOffset,
                formatTag: fileInfo.formatTag,
                bitsPerSample: fileInfo.bitsPerSample
            )
        }

        return sample / Float(fileInfo.channelCount)
    }

    private static func inspect(in data: Data, url: URL) throws -> WAVFileInfo {
        guard
            data.count >= 12,
            try readFourCC(in: data, at: 0) == "RIFF",
            try readFourCC(in: data, at: 8) == "WAVE"
        else {
            throw DecodeError.invalidHeader
        }

        let chunks = try scanChunks(in: data)
        guard let formatChunk = chunks["fmt "] else {
            throw DecodeError.missingFormatChunk
        }
        guard let dataChunk = chunks["data"] else {
            throw DecodeError.missingDataChunk
        }

        return try parseFileInfo(
            in: data,
            formatChunk: formatChunk,
            dataChunk: dataChunk,
            url: url
        )
    }

    private static func scanChunks(in data: Data) throws -> [String: Range<Int>] {
        var chunks: [String: Range<Int>] = [:]
        var offset = 12

        while offset + 8 <= data.count {
            let id = try readFourCC(in: data, at: offset)
            let chunkSize = Int(try readUInt32LE(in: data, at: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + chunkSize

            guard payloadEnd <= data.count else {
                throw DecodeError.invalidChunk
            }

            chunks[id] = payloadStart..<payloadEnd
            offset = payloadEnd + chunkSize % 2
        }

        return chunks
    }

    private static func parseFileInfo(
        in data: Data,
        formatChunk: Range<Int>,
        dataChunk: Range<Int>,
        url: URL
    ) throws -> WAVFileInfo {
        guard formatChunk.count >= 16 else {
            throw DecodeError.invalidFormat
        }

        var formatTag = try readUInt16LE(in: data, at: formatChunk.lowerBound)
        let channelCount = Int(try readUInt16LE(in: data, at: formatChunk.lowerBound + 2))
        let sampleRate = Double(try readUInt32LE(in: data, at: formatChunk.lowerBound + 4))
        let blockAlign = Int(try readUInt16LE(in: data, at: formatChunk.lowerBound + 12))
        let bitsPerSample = Int(try readUInt16LE(in: data, at: formatChunk.lowerBound + 14))

        if formatTag == 0xFFFE {
            guard formatChunk.count >= 40 else {
                throw DecodeError.invalidFormat
            }

            formatTag = try readUInt16LE(in: data, at: formatChunk.lowerBound + 24)
        }

        guard channelCount > 0, sampleRate > 0, blockAlign > 0, bitsPerSample > 0 else {
            throw DecodeError.invalidFormat
        }

        return WAVFileInfo(
            url: url,
            formatTag: formatTag,
            channelCount: channelCount,
            sampleRate: sampleRate,
            blockAlign: blockAlign,
            bitsPerSample: bitsPerSample,
            dataRange: dataChunk
        )
    }

    private static func buildSparsePreview(
        in data: Data,
        fileInfo: WAVFileInfo,
        targetBinCount: Int,
        samplesPerBin: Int
    ) throws -> WaveformOverview {
        try validateDecodable(fileInfo)

        guard fileInfo.frameCount > 0 else {
            return WaveformOverview(duration: fileInfo.duration, bins: [])
        }

        let binCount = min(max(targetBinCount, 1), fileInfo.frameCount)
        let sampledFrameCount = max(samplesPerBin, 1)
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount)

        for binIndex in 0..<binCount {
            let startFrame = binIndex * fileInfo.frameCount / binCount
            let endFrame = max((binIndex + 1) * fileInfo.frameCount / binCount, startFrame + 1)
            let frameSpan = endFrame - startFrame
            let binSampleCount = min(sampledFrameCount, frameSpan)
            var minimumSample: Float = 1
            var maximumSample: Float = -1

            for sampleIndex in 0..<binSampleCount {
                let frameOffset: Int
                if binSampleCount == 1 {
                    frameOffset = frameSpan / 2
                } else {
                    frameOffset = sampleIndex * (frameSpan - 1) / (binSampleCount - 1)
                }

                let frameIndex = startFrame + frameOffset
                let frameByteOffset = fileInfo.dataRange.lowerBound + frameIndex * fileInfo.blockAlign

                for channelIndex in 0..<fileInfo.channelCount {
                    let sampleOffset = frameByteOffset + channelIndex * bytesPerSample(for: fileInfo)
                    let sample = try decodeSample(
                        in: data,
                        at: sampleOffset,
                        formatTag: fileInfo.formatTag,
                        bitsPerSample: fileInfo.bitsPerSample
                    )
                    minimumSample = min(minimumSample, sample)
                    maximumSample = max(maximumSample, sample)
                }
            }

            if minimumSample > maximumSample {
                minimumSample = 0
                maximumSample = 0
            }

            bins.append(WaveformOverview.Bin(
                minimumSample: minimumSample,
                maximumSample: maximumSample
            ))
        }

        return WaveformOverview(duration: fileInfo.duration, bins: bins)
    }

    private static func decodeSamples(in data: Data, fileInfo: WAVFileInfo) throws -> DecodedAudioBuffer {
        try validateDecodable(fileInfo)

        let bytesPerSample = bytesPerSample(for: fileInfo)
        let frameCount = fileInfo.frameCount
        var samplesByChannel = (0..<fileInfo.channelCount).map { _ in
            [Float]()
        }

        for channelIndex in samplesByChannel.indices {
            samplesByChannel[channelIndex].reserveCapacity(frameCount)
        }

        for frameIndex in 0..<frameCount {
            let frameOffset = fileInfo.dataRange.lowerBound + frameIndex * fileInfo.blockAlign

            for channelIndex in 0..<fileInfo.channelCount {
                let sampleOffset = frameOffset + channelIndex * bytesPerSample
                let sample = try decodeSample(
                    in: data,
                    at: sampleOffset,
                    formatTag: fileInfo.formatTag,
                    bitsPerSample: fileInfo.bitsPerSample
                )
                samplesByChannel[channelIndex].append(sample)
            }
        }

        return DecodedAudioBuffer(
            url: fileInfo.url,
            sampleRate: fileInfo.sampleRate,
            channelCount: fileInfo.channelCount,
            frameCount: frameCount,
            samplesByChannel: samplesByChannel
        )
    }

    private static func validateDecodable(_ fileInfo: WAVFileInfo) throws {
        guard fileInfo.formatTag == 1 || fileInfo.formatTag == 3 else {
            throw DecodeError.unsupportedFormat(fileInfo.formatTag)
        }
        guard fileInfo.bitsPerSample % 8 == 0 else {
            throw DecodeError.unsupportedBitDepth(fileInfo.bitsPerSample)
        }
        guard fileInfo.blockAlign >= bytesPerSample(for: fileInfo) * fileInfo.channelCount else {
            throw DecodeError.invalidFormat
        }
    }

    private static func bytesPerSample(for fileInfo: WAVFileInfo) -> Int {
        fileInfo.bitsPerSample / 8
    }

    private static func decodeSample(
        in data: Data,
        at offset: Int,
        formatTag: UInt16,
        bitsPerSample: Int
    ) throws -> Float {
        switch (formatTag, bitsPerSample) {
        case (1, 8):
            return (Float(Int(data[offset]) - 128) / 128).clampedToAudioRange()
        case (1, 16):
            let sample = Int16(bitPattern: try readUInt16LE(in: data, at: offset))
            return (Float(sample) / 32_768).clampedToAudioRange()
        case (1, 24):
            let sample = try readInt24LE(in: data, at: offset)
            return (Float(sample) / 8_388_608).clampedToAudioRange()
        case (1, 32):
            let sample = Int32(bitPattern: try readUInt32LE(in: data, at: offset))
            return (Float(sample) / 2_147_483_648).clampedToAudioRange()
        case (3, 32):
            return Float(bitPattern: try readUInt32LE(in: data, at: offset)).clampedToAudioRange()
        case (3, 64):
            return Float(Double(bitPattern: try readUInt64LE(in: data, at: offset))).clampedToAudioRange()
        default:
            throw DecodeError.unsupportedBitDepth(bitsPerSample)
        }
    }

    private static func readFourCC(in data: Data, at offset: Int) throws -> String {
        guard offset + 4 <= data.count else {
            throw DecodeError.invalidChunk
        }

        let bytes = [
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
        ]

        guard let value = String(bytes: bytes, encoding: .ascii) else {
            throw DecodeError.invalidChunk
        }

        return value
    }

    private static func readUInt16LE(in data: Data, at offset: Int) throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw DecodeError.invalidChunk
        }

        return UInt16(data[offset]) |
            UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32LE(in data: Data, at offset: Int) throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw DecodeError.invalidChunk
        }

        return UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }

    private static func readUInt64LE(in data: Data, at offset: Int) throws -> UInt64 {
        guard offset + 8 <= data.count else {
            throw DecodeError.invalidChunk
        }

        var value = UInt64(data[offset])
        value |= UInt64(data[offset + 1]) << 8
        value |= UInt64(data[offset + 2]) << 16
        value |= UInt64(data[offset + 3]) << 24
        value |= UInt64(data[offset + 4]) << 32
        value |= UInt64(data[offset + 5]) << 40
        value |= UInt64(data[offset + 6]) << 48
        value |= UInt64(data[offset + 7]) << 56

        return value
    }

    private static func readInt24LE(in data: Data, at offset: Int) throws -> Int32 {
        guard offset + 3 <= data.count else {
            throw DecodeError.invalidChunk
        }

        var value = Int32(
            UInt32(data[offset]) |
                UInt32(data[offset + 1]) << 8 |
                UInt32(data[offset + 2]) << 16
        )

        if value & 0x0080_0000 != 0 {
            value |= ~0x00FF_FFFF
        }

        return value
    }
}

private extension Float {
    func clampedToAudioRange() -> Float {
        min(max(self, -1), 1)
    }
}
