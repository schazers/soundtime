import Foundation

final class AudioExportStreamingWAVWriter: AudioExportSampleWriter, @unchecked Sendable {
    enum WriterError: LocalizedError {
        case invalidFormat
        case fileTooLarge
        case noSamplesWritten
        case writeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "The export audio format is invalid."
            case .fileTooLarge:
                return "The export is too large for a WAV file."
            case .noSamplesWritten:
                return "No audio samples were rendered."
            case let .writeFailed(error):
                return "Export write failed: \(error.localizedDescription)"
            }
        }
    }

    let url: URL

    private let fileHandle: FileHandle
    private let sampleRate: Double
    private let channelCount: Int
    private let encoding: AudioExportWAVEncoding
    private var frameCount = 0
    private var isFinished = false
    private var ditherState: UInt64 = 0x9E37_79B9_7F4A_7C15

    init(
        url: URL,
        sampleRate: Double,
        channelCount: Int,
        encoding: AudioExportWAVEncoding = .pcm24
    ) throws {
        guard
            sampleRate.isFinite,
            sampleRate > 0,
            sampleRate <= Double(UInt32.max),
            channelCount > 0,
            channelCount <= Int(UInt16.max)
        else {
            throw WriterError.invalidFormat
        }

        self.url = url.pathExtension.isEmpty ? url.appendingPathExtension("wav") : url
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.encoding = encoding

        guard !FileManager.default.fileExists(atPath: self.url.path) else {
            throw WriterError.writeFailed(
                CocoaError(.fileWriteFileExists)
            )
        }
        guard FileManager.default.createFile(atPath: self.url.path, contents: nil) else {
            throw WAVFileWriter.WriteError.couldNotCreateFile
        }

        fileHandle = try FileHandle(forWritingTo: self.url)
        try fileHandle.write(contentsOf: Self.makeHeader(
            sampleRate: UInt32(sampleRate.rounded()),
            channelCount: UInt16(channelCount),
            encoding: encoding,
            dataByteCount: 0
        ))
    }

    deinit {
        if !isFinished {
            try? fileHandle.close()
        }
    }

    func append(samplesByChannel: [[Float]], frameCount chunkFrameCount: Int) throws {
        guard !isFinished else {
            throw WriterError.invalidFormat
        }
        guard
            chunkFrameCount > 0,
            !samplesByChannel.isEmpty
        else {
            return
        }

        let bytesPerFrame = channelCount * encoding.bytesPerSample
        guard
            bytesPerFrame <= Int(UInt16.max),
            (frameCount + chunkFrameCount) <= Int(UInt32.max) / bytesPerFrame
        else {
            throw WriterError.fileTooLarge
        }

        var data = Data()
        data.reserveCapacity(chunkFrameCount * bytesPerFrame)
        for frameIndex in 0..<chunkFrameCount {
            for channelIndex in 0..<channelCount {
                let sourceChannel = channelIndex < samplesByChannel.count ? channelIndex : samplesByChannel.count - 1
                let samples = samplesByChannel[sourceChannel]
                let sample = frameIndex < samples.count ? samples[frameIndex] : 0
                switch encoding {
                case .pcm16:
                    data.appendExportInt16LE(quantizePCM16(sample))
                case .pcm24:
                    data.appendExportInt24LE(quantizePCM24(sample))
                case .float32:
                    data.appendExportFloat32LE(sample.isFinite ? sample : 0)
                }
            }
        }

        do {
            try fileHandle.write(contentsOf: data)
            frameCount += chunkFrameCount
        } catch {
            throw WriterError.writeFailed(error)
        }
    }

    func finish() throws -> URL {
        guard !isFinished else {
            return url
        }
        guard frameCount > 0 else {
            cancel()
            throw WriterError.noSamplesWritten
        }

        try patchHeader()
        try fileHandle.synchronize()
        try fileHandle.close()
        isFinished = true
        return url
    }

    func cancel() {
        guard !isFinished else {
            return
        }
        try? fileHandle.close()
        try? FileManager.default.removeItem(at: url)
        isFinished = true
    }

    private func patchHeader() throws {
        let dataByteCount = frameCount * channelCount * encoding.bytesPerSample
        guard dataByteCount <= Int(UInt32.max) else {
            throw WriterError.fileTooLarge
        }

        try fileHandle.seek(toOffset: 0)
        try fileHandle.write(contentsOf: Self.makeHeader(
            sampleRate: UInt32(sampleRate.rounded()),
            channelCount: UInt16(channelCount),
            encoding: encoding,
            dataByteCount: UInt32(dataByteCount)
        ))
    }

    private static func makeHeader(
        sampleRate: UInt32,
        channelCount: UInt16,
        encoding: AudioExportWAVEncoding,
        dataByteCount: UInt32
    ) -> Data {
        let bytesPerSample = UInt16(encoding.bytesPerSample)
        let bitsPerSample = bytesPerSample * 8
        let blockAlign = channelCount * bytesPerSample
        let formatTag: UInt16 = encoding == .float32 ? 3 : 1

        var data = Data()
        data.reserveCapacity(44)
        data.appendExportASCII("RIFF")
        data.appendExportUInt32LE(36 + dataByteCount)
        data.appendExportASCII("WAVE")
        data.appendExportASCII("fmt ")
        data.appendExportUInt32LE(16)
        data.appendExportUInt16LE(formatTag)
        data.appendExportUInt16LE(channelCount)
        data.appendExportUInt32LE(sampleRate)
        data.appendExportUInt32LE(sampleRate * UInt32(blockAlign))
        data.appendExportUInt16LE(blockAlign)
        data.appendExportUInt16LE(bitsPerSample)
        data.appendExportASCII("data")
        data.appendExportUInt32LE(dataByteCount)
        return data
    }

    private func quantizePCM16(_ sample: Float) -> Int16 {
        let dithered = sample + triangularDither(lsbScale: 1.0 / 32_768.0)
        let clippedSample = min(max(dithered, -1), 1)
        let scaledSample = clippedSample < 0 ? clippedSample * 32_768 : clippedSample * 32_767
        let roundedSample = Int(scaledSample.rounded())
        return Int16(min(max(roundedSample, Int(Int16.min)), Int(Int16.max)))
    }

    private func quantizePCM24(_ sample: Float) -> Int32 {
        let dithered = sample + triangularDither(lsbScale: 1.0 / 8_388_608.0)
        let clippedSample = min(max(dithered, -1), 1)
        let scaledSample = clippedSample < 0 ?
            clippedSample * 8_388_608 :
            clippedSample * 8_388_607
        return Int32(min(max(Int64(scaledSample.rounded()), -8_388_608), 8_388_607))
    }

    private func triangularDither(lsbScale: Float) -> Float {
        let first = nextDitherUnit()
        let second = nextDitherUnit()
        return (first - second) * lsbScale
    }

    private func nextDitherUnit() -> Float {
        ditherState ^= ditherState << 13
        ditherState ^= ditherState >> 7
        ditherState ^= ditherState << 17
        let mantissa = UInt32(truncatingIfNeeded: ditherState >> 40)
        return Float(mantissa) / Float(1 << 24)
    }
}

private extension Data {
    mutating func appendExportASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendExportUInt16LE(_ value: UInt16) {
        var littleEndianValue = value.littleEndian
        appendExportBytes(of: &littleEndianValue)
    }

    mutating func appendExportUInt32LE(_ value: UInt32) {
        var littleEndianValue = value.littleEndian
        appendExportBytes(of: &littleEndianValue)
    }

    mutating func appendExportInt16LE(_ value: Int16) {
        var littleEndianValue = value.littleEndian
        appendExportBytes(of: &littleEndianValue)
    }

    mutating func appendExportInt24LE(_ value: Int32) {
        let bitPattern = UInt32(bitPattern: value)
        append(UInt8(truncatingIfNeeded: bitPattern))
        append(UInt8(truncatingIfNeeded: bitPattern >> 8))
        append(UInt8(truncatingIfNeeded: bitPattern >> 16))
    }

    mutating func appendExportFloat32LE(_ value: Float) {
        var littleEndianValue = value.bitPattern.littleEndian
        appendExportBytes(of: &littleEndianValue)
    }

    private mutating func appendExportBytes<T>(of value: inout T) {
        Swift.withUnsafeBytes(of: &value) { buffer in
            append(contentsOf: buffer)
        }
    }
}
