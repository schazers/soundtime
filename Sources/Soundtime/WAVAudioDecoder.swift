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

    private struct WAVFormat {
        let formatTag: UInt16
        let channelCount: Int
        let sampleRate: Double
        let blockAlign: Int
        let bitsPerSample: Int
    }

    static func canDecode(_ url: URL) -> Bool {
        ["wav", "wave"].contains(url.pathExtension.lowercased())
    }

    static func decode(url: URL) throws -> DecodedAudioBuffer {
        guard canDecode(url) else {
            throw DecodeError.unsupportedFileType
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
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

        let format = try parseFormat(in: data, chunk: formatChunk)
        return try decodeSamples(
            in: data,
            chunk: dataChunk,
            format: format,
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

    private static func parseFormat(in data: Data, chunk: Range<Int>) throws -> WAVFormat {
        guard chunk.count >= 16 else {
            throw DecodeError.invalidFormat
        }

        var formatTag = try readUInt16LE(in: data, at: chunk.lowerBound)
        let channelCount = Int(try readUInt16LE(in: data, at: chunk.lowerBound + 2))
        let sampleRate = Double(try readUInt32LE(in: data, at: chunk.lowerBound + 4))
        let blockAlign = Int(try readUInt16LE(in: data, at: chunk.lowerBound + 12))
        let bitsPerSample = Int(try readUInt16LE(in: data, at: chunk.lowerBound + 14))

        if formatTag == 0xFFFE {
            guard chunk.count >= 40 else {
                throw DecodeError.invalidFormat
            }

            formatTag = try readUInt16LE(in: data, at: chunk.lowerBound + 24)
        }

        guard channelCount > 0, sampleRate > 0, blockAlign > 0, bitsPerSample > 0 else {
            throw DecodeError.invalidFormat
        }

        return WAVFormat(
            formatTag: formatTag,
            channelCount: channelCount,
            sampleRate: sampleRate,
            blockAlign: blockAlign,
            bitsPerSample: bitsPerSample
        )
    }

    private static func decodeSamples(
        in data: Data,
        chunk: Range<Int>,
        format: WAVFormat,
        url: URL
    ) throws -> DecodedAudioBuffer {
        guard format.formatTag == 1 || format.formatTag == 3 else {
            throw DecodeError.unsupportedFormat(format.formatTag)
        }
        guard format.bitsPerSample % 8 == 0 else {
            throw DecodeError.unsupportedBitDepth(format.bitsPerSample)
        }

        let bytesPerSample = format.bitsPerSample / 8
        guard format.blockAlign >= bytesPerSample * format.channelCount else {
            throw DecodeError.invalidFormat
        }

        let frameCount = chunk.count / format.blockAlign
        var samplesByChannel = (0..<format.channelCount).map { _ in
            [Float]()
        }

        for channelIndex in samplesByChannel.indices {
            samplesByChannel[channelIndex].reserveCapacity(frameCount)
        }

        for frameIndex in 0..<frameCount {
            let frameOffset = chunk.lowerBound + frameIndex * format.blockAlign

            for channelIndex in 0..<format.channelCount {
                let sampleOffset = frameOffset + channelIndex * bytesPerSample
                let sample = try decodeSample(
                    in: data,
                    at: sampleOffset,
                    formatTag: format.formatTag,
                    bitsPerSample: format.bitsPerSample
                )
                samplesByChannel[channelIndex].append(sample)
            }
        }

        return DecodedAudioBuffer(
            url: url,
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            frameCount: frameCount,
            samplesByChannel: samplesByChannel
        )
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
