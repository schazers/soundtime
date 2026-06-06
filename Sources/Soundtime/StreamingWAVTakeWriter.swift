import Foundation

struct RecordedTakeFile: Sendable {
    let url: URL
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int

    var duration: TimeInterval {
        sampleRate > 0 ? Double(frameCount) / sampleRate : 0
    }
}

final class StreamingWAVTakeWriter: @unchecked Sendable {
    enum WriterError: LocalizedError {
        case invalidFormat
        case fileTooLarge
        case noSamplesWritten
        case writeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                "The recorded audio format is invalid."
            case .fileTooLarge:
                "The recording is too large for a WAV file."
            case .noSamplesWritten:
                "No audio samples were recorded."
            case let .writeFailed(error):
                "Recording write failed: \(error.localizedDescription)"
            }
        }
    }

    let url: URL

    private let fileHandle: FileHandle
    private var sampleRate: Double = 0
    private var channelCount = 0
    private var frameCount = 0
    private var hasWrittenHeader = false
    private var isFinished = false
    private var storedError: Error?

    init(url: URL) throws {
        self.url = url.pathExtension.isEmpty ? url.appendingPathExtension("wav") : url
        try FileManager.default.removeItemIfPresent(at: self.url)
        guard FileManager.default.createFile(atPath: self.url.path, contents: nil) else {
            throw WAVFileWriter.WriteError.couldNotCreateFile
        }
        fileHandle = try FileHandle(forWritingTo: self.url)
    }

    deinit {
        if !isFinished {
            try? fileHandle.close()
        }
    }

    func append(_ chunk: AudioRecordingChunk) {
        guard storedError == nil, !isFinished else {
            return
        }

        do {
            try appendThrowing(chunk)
        } catch {
            storedError = error
        }
    }

    func finish() throws -> RecordedTakeFile {
        if let storedError {
            cancel()
            throw storedError
        }
        guard hasWrittenHeader, frameCount > 0 else {
            cancel()
            throw WriterError.noSamplesWritten
        }

        try patchHeader()
        try fileHandle.close()
        isFinished = true
        return RecordedTakeFile(
            url: url,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount
        )
    }

    func cancel() {
        guard !isFinished else {
            return
        }

        try? fileHandle.close()
        try? FileManager.default.removeItem(at: url)
        isFinished = true
    }

    private func appendThrowing(_ chunk: AudioRecordingChunk) throws {
        let chunkFrameCount = min(
            chunk.frameCount,
            chunk.samplesByChannel.map(\.count).min() ?? chunk.frameCount
        )
        guard
            chunkFrameCount > 0,
            chunk.sampleRate.isFinite,
            chunk.sampleRate > 0,
            chunk.sampleRate <= Double(UInt32.max),
            chunk.channelCount > 0,
            chunk.channelCount <= Int(UInt16.max),
            !chunk.samplesByChannel.isEmpty
        else {
            throw WriterError.invalidFormat
        }

        if !hasWrittenHeader {
            sampleRate = chunk.sampleRate
            channelCount = max(chunk.channelCount, 1)
            try fileHandle.write(contentsOf: Self.makeHeader(
                sampleRate: UInt32(sampleRate.rounded()),
                channelCount: UInt16(channelCount),
                dataByteCount: 0
            ))
            hasWrittenHeader = true
        }

        guard
            abs(sampleRate - chunk.sampleRate) <= 0.5,
            channelCount == chunk.channelCount
        else {
            throw WriterError.invalidFormat
        }

        let bytesPerFrame = channelCount * 2
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
                let samples = chunk.samplesByChannel[min(channelIndex, chunk.samplesByChannel.count - 1)]
                data.appendInt16LE(Self.quantizeSample(samples[frameIndex]))
            }
        }

        do {
            try fileHandle.write(contentsOf: data)
            frameCount += chunkFrameCount
        } catch {
            throw WriterError.writeFailed(error)
        }
    }

    private func patchHeader() throws {
        let dataByteCount = frameCount * channelCount * 2
        guard dataByteCount <= Int(UInt32.max) else {
            throw WriterError.fileTooLarge
        }

        try fileHandle.seek(toOffset: 0)
        try fileHandle.write(contentsOf: Self.makeHeader(
            sampleRate: UInt32(sampleRate.rounded()),
            channelCount: UInt16(channelCount),
            dataByteCount: UInt32(dataByteCount)
        ))
    }

    private static func makeHeader(
        sampleRate: UInt32,
        channelCount: UInt16,
        dataByteCount: UInt32
    ) -> Data {
        let bitsPerSample: UInt16 = 16
        let blockAlign = UInt16(channelCount * 2)
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

    private static func quantizeSample(_ sample: Float) -> Int16 {
        let clippedSample = min(max(sample, -1), 1)
        let scaledSample = clippedSample < 0 ? clippedSample * 32_768 : clippedSample * 32_767
        let roundedSample = Int(scaledSample.rounded())
        return Int16(min(max(roundedSample, Int(Int16.min)), Int(Int16.max)))
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

private extension FileManager {
    func removeItemIfPresent(at url: URL) throws {
        guard fileExists(atPath: url.path) else {
            return
        }

        try removeItem(at: url)
    }
}
