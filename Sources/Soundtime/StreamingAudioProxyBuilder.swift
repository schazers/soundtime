@preconcurrency import AVFoundation
import Accelerate
import Foundation

private final class StreamingAudioConversionInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func store(error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}

struct StreamingAudioProxyBuildResult: Sendable {
    let proxyURL: URL
    let fileInfo: WAVFileInfo
    let waveformOverview: WaveformOverview
    let zeroCrossingIndex: AudioZeroCrossingIndex
    let peakWorkingSetBytes: Int
}

enum StreamingAudioProxyBuilder {
    private static let inputChunkFrames: AVAudioFrameCount = 16_384
    // Build screen-detail waveform data during the one sequential decode that
    // also writes the editable proxy. This avoids a later whole-file pass.
    // This is already substantially denser than a full-screen timeline. A
    // 131K launch/zoom level is refined later from the editable WAV proxy so it
    // cannot delay the first complete cold-import waveform.
    static let waveformBinCount = 32_768
    static let progressWaveformBinCount = 8_192

    static func build(
        sourceURL: URL,
        destinationURL: URL,
        targetSampleRate: Double,
        progress: (@Sendable (AudioImportProgress) -> Void)? = nil
    ) throws -> StreamingAudioProxyBuildResult {
        let sourceFile = try AVAudioFile(
            forReading: sourceURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let sourceFormat = sourceFile.processingFormat
        guard
            sourceFormat.sampleRate.isFinite,
            sourceFormat.sampleRate > 0,
            targetSampleRate.isFinite,
            targetSampleRate > 0,
            sourceFormat.channelCount > 0
        else {
            throw AudioAssetImporter.ImportError.invalidSampleRate
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        ) else {
            throw AudioAssetImporter.ImportError.unsupportedNativePCMLayout
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destinationURL)
        let outputFile = try StreamingWAVFileWriter(
            url: destinationURL,
            sampleRate: targetSampleRate,
            channelCount: Int(sourceFormat.channelCount)
        )

        let expectedOutputFrames = max(
            Int64((Double(sourceFile.length) * targetSampleRate / sourceFormat.sampleRate).rounded()),
            0
        )
        let binCount = min(max(Int(expectedOutputFrames), 1), waveformBinCount)
        var analyzer = StreamingAnalyzer(
            expectedFrameCount: expectedOutputFrames,
            sampleRate: targetSampleRate,
            binCount: binCount
        )
        var progressPublisher = StreamingProgressPublisher()
        var peakWorkingSetBytes = 0

        if abs(sourceFormat.sampleRate - targetSampleRate) < 0.5 {
            try copyWithoutResampling(
                sourceFile: sourceFile,
                outputFile: outputFile,
                format: outputFormat,
                analyzer: &analyzer,
                progressPublisher: &progressPublisher,
                peakWorkingSetBytes: &peakWorkingSetBytes,
                progress: progress
            )
        } else {
            try convertWithResampling(
                sourceFile: sourceFile,
                outputFile: outputFile,
                sourceFormat: sourceFormat,
                outputFormat: outputFormat,
                analyzer: &analyzer,
                progressPublisher: &progressPublisher,
                peakWorkingSetBytes: &peakWorkingSetBytes,
                progress: progress
            )
        }

        try Task.checkCancellation()
        try outputFile.finish()
        let fileInfo = try WAVAudioDecoder.inspect(url: destinationURL)
        let analysis = analyzer.finish(actualFrameCount: Int64(fileInfo.frameCount))
        progress?(AudioImportProgress(
            stage: .editableReady,
            completedFrames: Int64(fileInfo.frameCount),
            totalFrames: Int64(fileInfo.frameCount),
            message: "Editable audio ready",
            previewOverview: analysis.overview
        ))
        return StreamingAudioProxyBuildResult(
            proxyURL: destinationURL,
            fileInfo: fileInfo,
            waveformOverview: analysis.overview,
            zeroCrossingIndex: analysis.zeroCrossingIndex,
            peakWorkingSetBytes: peakWorkingSetBytes
        )
    }

    private static func copyWithoutResampling(
        sourceFile: AVAudioFile,
        outputFile: StreamingWAVFileWriter,
        format: AVAudioFormat,
        analyzer: inout StreamingAnalyzer,
        progressPublisher: inout StreamingProgressPublisher,
        peakWorkingSetBytes: inout Int,
        progress: (@Sendable (AudioImportProgress) -> Void)?
    ) throws {
        while sourceFile.framePosition < sourceFile.length {
            try Task.checkCancellation()
            let remaining = sourceFile.length - sourceFile.framePosition
            let requested = AVAudioFrameCount(min(Int64(inputChunkFrames), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: requested) else {
                throw AudioAssetImporter.ImportError.unsupportedNativePCMLayout
            }
            try sourceFile.read(into: buffer, frameCount: requested)
            guard buffer.frameLength > 0 else {
                break
            }
            try outputFile.append(buffer)
            analyzer.consume(buffer)
            peakWorkingSetBytes = max(
                peakWorkingSetBytes,
                estimatedBytes(buffer) + analyzer.estimatedWorkingSetBytes
            )
            publishProgress(
                analyzer: analyzer,
                publisher: &progressPublisher,
                progress: progress
            )
        }
    }

    private static func convertWithResampling(
        sourceFile: AVAudioFile,
        outputFile: StreamingWAVFileWriter,
        sourceFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        analyzer: inout StreamingAnalyzer,
        progressPublisher: inout StreamingProgressPublisher,
        peakWorkingSetBytes: inout Int,
        progress: (@Sendable (AudioImportProgress) -> Void)?
    ) throws {
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw AudioAssetImporter.ImportError.unsupportedNativePCMLayout
        }

        let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(
            max(Int((Double(inputChunkFrames) * ratio).rounded(.up)) + 256, 1)
        )
        var reachedEnd = false
        var localPeakWorkingSetBytes = peakWorkingSetBytes
        let maximumInputBufferBytes = Int(inputChunkFrames) *
            Int(sourceFormat.channelCount) *
            MemoryLayout<Float>.size
        let maximumOutputBufferBytes = Int(outputCapacity) *
            Int(outputFormat.channelCount) *
            MemoryLayout<Float>.size

        while !reachedEnd {
            try Task.checkCancellation()
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw AudioAssetImporter.ImportError.unsupportedNativePCMLayout
            }

            let inputState = StreamingAudioConversionInputState()
            var converterError: NSError?
            let status = converter.convert(to: outputBuffer, error: &converterError) {
                requestedFrames,
                inputStatus in
                if sourceFile.framePosition >= sourceFile.length {
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                let remaining = sourceFile.length - sourceFile.framePosition
                let frameCount = AVAudioFrameCount(
                    min(Int64(max(requestedFrames, 1)), remaining)
                )
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: frameCount
                ) else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }

                do {
                    try sourceFile.read(into: inputBuffer, frameCount: frameCount)
                    inputStatus.pointee = inputBuffer.frameLength > 0 ? .haveData : .endOfStream
                    return inputBuffer.frameLength > 0 ? inputBuffer : nil
                } catch {
                    inputState.store(error: error)
                    inputStatus.pointee = .noDataNow
                    return nil
                }
            }

            if let inputError = inputState.error {
                throw inputError
            }
            if let converterError {
                throw converterError
            }
            if outputBuffer.frameLength > 0 {
                try outputFile.append(outputBuffer)
                analyzer.consume(outputBuffer)
                localPeakWorkingSetBytes = max(
                    localPeakWorkingSetBytes,
                    maximumInputBufferBytes +
                        maximumOutputBufferBytes +
                        analyzer.estimatedWorkingSetBytes
                )
                publishProgress(
                    analyzer: analyzer,
                    publisher: &progressPublisher,
                    progress: progress
                )
            }

            switch status {
            case .endOfStream:
                reachedEnd = true
            case .error:
                throw converterError ?? AudioAssetImporter.ImportError.unreadableNativeAudio(
                    AudioAssetFormat.inferred(from: sourceFile.url)
                )
            case .haveData, .inputRanDry:
                if sourceFile.framePosition >= sourceFile.length, outputBuffer.frameLength == 0 {
                    reachedEnd = true
                }
            @unknown default:
                reachedEnd = true
            }
        }
        peakWorkingSetBytes = max(peakWorkingSetBytes, localPeakWorkingSetBytes)
    }

    private static func publishProgress(
        analyzer: StreamingAnalyzer,
        publisher: inout StreamingProgressPublisher,
        progress: (@Sendable (AudioImportProgress) -> Void)?
    ) {
        guard publisher.shouldPublish(
            completedFrames: analyzer.consumedFrameCount,
            totalFrames: analyzer.expectedFrameCount
        ) else {
            return
        }
        let previewOverview = publisher.shouldPublishWaveformPreview() ?
            analyzer.makePreview(maximumBinCount: progressWaveformBinCount) :
            nil
        progress?(AudioImportProgress(
            stage: .proxying,
            completedFrames: analyzer.consumedFrameCount,
            totalFrames: analyzer.expectedFrameCount,
            message: "Converting to editable audio",
            previewOverview: previewOverview
        ))
    }

    private static func estimatedBytes(_ buffer: AVAudioPCMBuffer) -> Int {
        Int(buffer.frameCapacity) *
            Int(buffer.format.channelCount) *
            MemoryLayout<Float>.size
    }
}

private struct StreamingProgressPublisher {
    private static let minimumIntervalNanoseconds: UInt64 = 50_000_000
    private static let minimumFractionDelta = 0.005
    private static let waveformIntervalNanoseconds: UInt64 = 100_000_000

    private var lastPublishNanoseconds: UInt64 = 0
    private var lastFraction = 0.0
    private var lastWaveformPublishNanoseconds: UInt64 = 0

    mutating func shouldPublish(completedFrames: Int64, totalFrames: Int64) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let fraction = totalFrames > 0 ?
            min(max(Double(completedFrames) / Double(totalFrames), 0), 1) :
            0
        guard
            lastPublishNanoseconds == 0 ||
            (
                now &- lastPublishNanoseconds >= Self.minimumIntervalNanoseconds &&
                fraction - lastFraction >= Self.minimumFractionDelta
            )
        else {
            return false
        }
        lastPublishNanoseconds = now
        lastFraction = fraction
        return true
    }

    mutating func shouldPublishWaveformPreview() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard
            lastWaveformPublishNanoseconds == 0 ||
            now &- lastWaveformPublishNanoseconds >= Self.waveformIntervalNanoseconds
        else {
            return false
        }
        lastWaveformPublishNanoseconds = now
        return true
    }
}

private struct StreamingAnalyzer {
    struct Result {
        let overview: WaveformOverview
        let zeroCrossingIndex: AudioZeroCrossingIndex
    }

    let expectedFrameCount: Int64
    let sampleRate: Double
    private var accumulators: [WaveformBinAccumulator]
    private var previewAccumulators: [WaveformBinAccumulator]
    private(set) var consumedFrameCount: Int64 = 0

    var estimatedWorkingSetBytes: Int {
        accumulators.capacity * MemoryLayout<WaveformBinAccumulator>.stride +
            previewAccumulators.capacity * MemoryLayout<WaveformBinAccumulator>.stride
    }

    func makePreview(maximumBinCount: Int) -> WaveformOverview {
        let sourceAccumulators = maximumBinCount <= previewAccumulators.count ?
            previewAccumulators : accumulators
        let outputCount = min(max(maximumBinCount, 1), sourceAccumulators.count)
        let duration = sampleRate > 0 ?
            Double(expectedFrameCount) / sampleRate :
            0
        guard outputCount < sourceAccumulators.count else {
            return WaveformOverview(
                duration: duration,
                bins: sourceAccumulators.map { $0.makeBin() }
            )
        }

        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(outputCount)
        for outputIndex in 0..<outputCount {
            let start = outputIndex * sourceAccumulators.count / outputCount
            let end = max(
                (outputIndex + 1) * sourceAccumulators.count / outputCount,
                start + 1
            )
            var accumulator = WaveformBinAccumulator()
            for sourceIndex in start..<min(end, sourceAccumulators.count) {
                accumulator.addBin(sourceAccumulators[sourceIndex].makeBin())
            }
            bins.append(accumulator.makeBin())
        }
        return WaveformOverview(duration: duration, bins: bins)
    }

    init(expectedFrameCount: Int64, sampleRate: Double, binCount: Int) {
        self.expectedFrameCount = max(expectedFrameCount, 1)
        self.sampleRate = sampleRate
        accumulators = Array(repeating: WaveformBinAccumulator(), count: max(binCount, 1))
        previewAccumulators = Array(
            repeating: WaveformBinAccumulator(),
            count: min(max(StreamingAudioProxyBuilder.progressWaveformBinCount, 1), max(binCount, 1))
        )
    }

    mutating func consume(_ buffer: AVAudioPCMBuffer) {
        guard
            let channelData = buffer.floatChannelData,
            buffer.frameLength > 0,
            buffer.format.channelCount > 0
        else {
            return
        }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var localStart = 0
        while localStart < frameLength {
            let absoluteStart = consumedFrameCount + Int64(localStart)
            let finalBinIndex = binIndex(
                for: absoluteStart,
                binCount: accumulators.count
            )
            let previewBinIndex = binIndex(
                for: absoluteStart,
                binCount: previewAccumulators.count
            )
            let absoluteEnd = min(
                consumedFrameCount + Int64(frameLength),
                nextBinBoundary(after: absoluteStart, binCount: accumulators.count),
                nextBinBoundary(after: absoluteStart, binCount: previewAccumulators.count)
            )
            let localEnd = min(
                max(Int(absoluteEnd - consumedFrameCount), localStart + 1),
                frameLength
            )
            let count = localEnd - localStart

            for channel in 0..<channelCount {
                let samples = channelData[channel].advanced(by: localStart)
                var minimum: Float = 0
                var maximum: Float = 0
                var squareSum: Float = 0
                vDSP_minv(samples, 1, &minimum, vDSP_Length(count))
                vDSP_maxv(samples, 1, &maximum, vDSP_Length(count))
                vDSP_svesq(samples, 1, &squareSum, vDSP_Length(count))
                accumulators[finalBinIndex].addSamples(
                    minimum: minimum,
                    maximum: maximum,
                    squareSum: squareSum,
                    count: count
                )
                previewAccumulators[previewBinIndex].addSamples(
                    minimum: minimum,
                    maximum: maximum,
                    squareSum: squareSum,
                    count: count
                )
            }
            localStart = localEnd
        }
        consumedFrameCount += Int64(frameLength)
    }

    private func binIndex(for frame: Int64, binCount: Int) -> Int {
        min(
            max(Int(frame * Int64(binCount) / expectedFrameCount), 0),
            binCount - 1
        )
    }

    private func nextBinBoundary(after frame: Int64, binCount: Int) -> Int64 {
        let index = binIndex(for: frame, binCount: binCount)
        return max(
            Int64(index + 1) * expectedFrameCount / Int64(binCount),
            frame + 1
        )
    }

    mutating func finish(actualFrameCount: Int64) -> Result {
        let actualFrameCount = max(actualFrameCount, 0)
        let duration = sampleRate > 0 ? Double(actualFrameCount) / sampleRate : 0
        return Result(
            overview: WaveformOverview(
                duration: duration,
                bins: accumulators.map { $0.makeBin() }
            ),
            zeroCrossingIndex: AudioZeroCrossingIndex(
                frameCount: Int(actualFrameCount),
                crossings: []
            )
        )
    }
}
