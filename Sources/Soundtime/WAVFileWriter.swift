import Foundation

enum WAVFileWriter {
    enum WriteError: LocalizedError {
        case invalidFormat
        case fileTooLarge
        case couldNotCreateFile

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                "The audio buffer cannot be exported as WAV."
            case .fileTooLarge:
                "The WAV file is too large for this exporter."
            case .couldNotCreateFile:
                "Could not create the export file."
            }
        }
    }

    static func write(_ buffer: DecodedAudioBuffer, to url: URL) throws {
        guard
            buffer.sampleRate.isFinite,
            buffer.sampleRate > 0,
            buffer.sampleRate <= Double(UInt32.max),
            buffer.channelCount > 0,
            buffer.channelCount <= Int(UInt16.max),
            buffer.frameCount >= 0
        else {
            throw WriteError.invalidFormat
        }

        let bytesPerSample = 2
        let bitsPerSample = UInt16(bytesPerSample * 8)
        let blockAlign = buffer.channelCount * bytesPerSample
        let dataByteCount = buffer.frameCount * blockAlign

        guard
            blockAlign <= Int(UInt16.max),
            dataByteCount <= Int(UInt32.max),
            36 + dataByteCount <= Int(UInt32.max),
            buffer.sampleRate <= Double(UInt32.max / UInt32(blockAlign))
        else {
            throw WriteError.fileTooLarge
        }

        let exportURL = url.pathExtension.isEmpty ? url.appendingPathExtension("wav") : url
        try FileManager.default.removeItemIfPresent(at: exportURL)

        guard FileManager.default.createFile(atPath: exportURL.path, contents: nil) else {
            throw WriteError.couldNotCreateFile
        }

        let fileHandle = try FileHandle(forWritingTo: exportURL)
        defer {
            try? fileHandle.close()
        }

        try fileHandle.write(contentsOf: makeHeader(
            sampleRate: UInt32(buffer.sampleRate.rounded()),
            channelCount: UInt16(buffer.channelCount),
            bitsPerSample: bitsPerSample,
            blockAlign: UInt16(blockAlign),
            dataByteCount: UInt32(dataByteCount)
        ))
        try writeSamples(from: buffer, to: fileHandle)
    }

    private static func makeHeader(
        sampleRate: UInt32,
        channelCount: UInt16,
        bitsPerSample: UInt16,
        blockAlign: UInt16,
        dataByteCount: UInt32
    ) -> Data {
        var data = Data()
        data.reserveCapacity(44)

        data.appendASCII("RIFF")
        data.appendUInt32LE(36 + dataByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(channelCount)
        data.appendUInt32LE(sampleRate)
        data.appendUInt32LE(sampleRate * UInt32(blockAlign))
        data.appendUInt16LE(blockAlign)
        data.appendUInt16LE(bitsPerSample)
        data.appendASCII("data")
        data.appendUInt32LE(dataByteCount)

        return data
    }

    private static func writeSamples(
        from buffer: DecodedAudioBuffer,
        to fileHandle: FileHandle
    ) throws {
        let framesPerChunk = 4_096
        var frameIndex = 0

        while frameIndex < buffer.frameCount {
            let endFrame = min(frameIndex + framesPerChunk, buffer.frameCount)
            var data = Data()
            data.reserveCapacity((endFrame - frameIndex) * buffer.channelCount * 2)

            for frame in frameIndex..<endFrame {
                for channel in 0..<buffer.channelCount {
                    let sample = sampleValue(in: buffer, channel: channel, frame: frame)
                    data.appendInt16LE(quantizeSample(sample))
                }
            }

            try fileHandle.write(contentsOf: data)
            frameIndex = endFrame
        }
    }

    private static func sampleValue(
        in buffer: DecodedAudioBuffer,
        channel: Int,
        frame: Int
    ) -> Float {
        guard
            channel < buffer.samplesByChannel.count,
            frame < buffer.samplesByChannel[channel].count
        else {
            return 0
        }

        return buffer.samplesByChannel[channel][frame]
    }

    private static func quantizeSample(_ sample: Float) -> Int16 {
        let clippedSample = min(max(sample, -1), 1)
        let scaledSample = clippedSample < 0 ? clippedSample * 32_768 : clippedSample * 32_767
        let roundedSample = Int(scaledSample.rounded())
        return Int16(min(max(roundedSample, Int(Int16.min)), Int(Int16.max)))
    }
}

private extension FileManager {
    func removeItemIfPresent(at url: URL) throws {
        guard fileExists(atPath: url.path) else {
            return
        }

        try removeItem(at: url)
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndianValue = value.littleEndian
        appendBytes(of: &littleEndianValue)
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndianValue = value.littleEndian
        appendBytes(of: &littleEndianValue)
    }

    mutating func appendInt16LE(_ value: Int16) {
        var littleEndianValue = value.littleEndian
        appendBytes(of: &littleEndianValue)
    }

    private mutating func appendBytes<T>(of value: inout T) {
        Swift.withUnsafeBytes(of: &value) { buffer in
            append(contentsOf: buffer)
        }
    }
}
