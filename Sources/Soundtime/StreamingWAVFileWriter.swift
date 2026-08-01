import AVFoundation
import Accelerate
import Foundation

final class StreamingWAVFileWriter {
    private let fileHandle: FileHandle
    private let channelCount: Int
    private let blockAlign: Int
    private var dataByteCount: UInt64 = 0
    private var isFinished = false
    private var interleavedSamples: [Int16] = []
    private var convertedChannel: [Float] = []

    init(url: URL, sampleRate: Double, channelCount: Int) throws {
        guard
            sampleRate.isFinite,
            sampleRate > 0,
            sampleRate <= Double(UInt32.max),
            channelCount > 0,
            channelCount <= Int(UInt16.max)
        else {
            throw WAVFileWriter.WriteError.invalidFormat
        }

        self.channelCount = channelCount
        blockAlign = channelCount * MemoryLayout<Int16>.size
        guard blockAlign <= Int(UInt16.max) else {
            throw WAVFileWriter.WriteError.invalidFormat
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw WAVFileWriter.WriteError.couldNotCreateFile
        }
        fileHandle = try FileHandle(forWritingTo: url)
        try fileHandle.write(contentsOf: Self.header(
            sampleRate: UInt32(sampleRate.rounded()),
            channelCount: UInt16(channelCount),
            blockAlign: UInt16(blockAlign),
            dataByteCount: 0
        ))
    }

    deinit {
        try? fileHandle.close()
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard !isFinished else {
            throw WAVFileWriter.WriteError.couldNotCreateFile
        }
        guard
            Int(buffer.format.channelCount) == channelCount,
            let channels = buffer.floatChannelData
        else {
            throw WAVFileWriter.WriteError.invalidFormat
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return
        }
        let appendedByteCount = UInt64(frameCount * blockAlign)
        guard dataByteCount + appendedByteCount <= UInt64(UInt32.max) else {
            throw WAVFileWriter.WriteError.fileTooLarge
        }

        let interleavedSampleCount = frameCount * channelCount
        if interleavedSamples.count < interleavedSampleCount {
            interleavedSamples = [Int16](repeating: 0, count: interleavedSampleCount)
        }
        if convertedChannel.count < frameCount {
            convertedChannel = [Float](repeating: 0, count: frameCount)
        }
        var lowerBound: Float = -1
        var upperBound: Float = 1
        var scale: Float = Float(Int16.max)
        try interleavedSamples.withUnsafeMutableBufferPointer { destination in
            guard let destinationBaseAddress = destination.baseAddress else {
                throw WAVFileWriter.WriteError.couldNotCreateFile
            }
            for channel in 0..<channelCount {
                convertedChannel.withUnsafeMutableBufferPointer { converted in
                    guard let convertedBaseAddress = converted.baseAddress else {
                        return
                    }
                    vDSP_vclip(
                        channels[channel],
                        1,
                        &lowerBound,
                        &upperBound,
                        convertedBaseAddress,
                        1,
                        vDSP_Length(frameCount)
                    )
                    vDSP_vsmul(
                        convertedBaseAddress,
                        1,
                        &scale,
                        convertedBaseAddress,
                        1,
                        vDSP_Length(frameCount)
                    )
                    vDSP_vfix16(
                        convertedBaseAddress,
                        1,
                        destinationBaseAddress.advanced(by: channel),
                        vDSP_Stride(channelCount),
                        vDSP_Length(frameCount)
                    )
                }
            }
        }
        let data = interleavedSamples.withUnsafeBytes { bytes in
            Data(
                bytes: bytes.baseAddress!,
                count: Int(appendedByteCount)
            )
        }
        try fileHandle.write(contentsOf: data)
        dataByteCount += appendedByteCount
    }

    func finish() throws {
        guard !isFinished else {
            return
        }
        guard dataByteCount <= UInt64(UInt32.max - 36) else {
            throw WAVFileWriter.WriteError.fileTooLarge
        }

        try fileHandle.seek(toOffset: 4)
        try fileHandle.write(contentsOf: Data.uint32LE(UInt32(36 + dataByteCount)))
        try fileHandle.seek(toOffset: 40)
        try fileHandle.write(contentsOf: Data.uint32LE(UInt32(dataByteCount)))
        try fileHandle.synchronize()
        try fileHandle.close()
        isFinished = true
    }

    private static func header(
        sampleRate: UInt32,
        channelCount: UInt16,
        blockAlign: UInt16,
        dataByteCount: UInt32
    ) -> Data {
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: Data.uint32LE(36 + dataByteCount))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: Data.uint32LE(16))
        data.append(contentsOf: Data.uint16LE(1))
        data.append(contentsOf: Data.uint16LE(channelCount))
        data.append(contentsOf: Data.uint32LE(sampleRate))
        data.append(contentsOf: Data.uint32LE(sampleRate * UInt32(blockAlign)))
        data.append(contentsOf: Data.uint16LE(blockAlign))
        data.append(contentsOf: Data.uint16LE(16))
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: Data.uint32LE(dataByteCount))
        return data
    }

}

private extension Data {
    static func uint16LE(_ value: UInt16) -> Data {
        var value = value.littleEndian
        return Swift.withUnsafeBytes(of: &value) { Data($0) }
    }

    static func uint32LE(_ value: UInt32) -> Data {
        var value = value.littleEndian
        return Swift.withUnsafeBytes(of: &value) { Data($0) }
    }

}
