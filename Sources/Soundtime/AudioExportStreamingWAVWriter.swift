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
    private var frameCount = 0
    private var isFinished = false

    init(url: URL, sampleRate: Double, channelCount: Int) throws {
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

        try FileManager.default.removeItemIfPresentForExport(at: self.url)
        guard FileManager.default.createFile(atPath: self.url.path, contents: nil) else {
            throw WAVFileWriter.WriteError.couldNotCreateFile
        }

        fileHandle = try FileHandle(forWritingTo: self.url)
        try fileHandle.write(contentsOf: Self.makeHeader(
            sampleRate: UInt32(sampleRate.rounded()),
            channelCount: UInt16(channelCount),
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
                let sourceChannel = channelIndex < samplesByChannel.count ? channelIndex : samplesByChannel.count - 1
                let samples = samplesByChannel[sourceChannel]
                let sample = frameIndex < samples.count ? samples[frameIndex] : 0
                data.appendExportInt16LE(Self.quantizeSample(sample))
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
        let bytesPerSample: UInt16 = 2
        let bitsPerSample = bytesPerSample * 8
        let blockAlign = channelCount * bytesPerSample

        var data = Data()
        data.reserveCapacity(44)
        data.appendExportASCII("RIFF")
        data.appendExportUInt32LE(36 + dataByteCount)
        data.appendExportASCII("WAVE")
        data.appendExportASCII("fmt ")
        data.appendExportUInt32LE(16)
        data.appendExportUInt16LE(1)
        data.appendExportUInt16LE(channelCount)
        data.appendExportUInt32LE(sampleRate)
        data.appendExportUInt32LE(sampleRate * UInt32(blockAlign))
        data.appendExportUInt16LE(blockAlign)
        data.appendExportUInt16LE(bitsPerSample)
        data.appendExportASCII("data")
        data.appendExportUInt32LE(dataByteCount)
        return data
    }

    private static func quantizeSample(_ sample: Float) -> Int16 {
        let clippedSample = min(max(sample, -1), 1)
        let scaledSample = clippedSample < 0 ? clippedSample * 32_768 : clippedSample * 32_767
        let roundedSample = Int(scaledSample.rounded())
        return Int16(min(max(roundedSample, Int(Int16.min)), Int(Int16.max)))
    }
}

private extension FileManager {
    func removeItemIfPresentForExport(at url: URL) throws {
        guard fileExists(atPath: url.path) else {
            return
        }
        try removeItem(at: url)
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

    private mutating func appendExportBytes<T>(of value: inout T) {
        Swift.withUnsafeBytes(of: &value) { buffer in
            append(contentsOf: buffer)
        }
    }
}
