import AVFoundation
import Foundation

enum AudioAssetFormat: String, Codable, Sendable {
    case wav
    case aiff
    case mp3
    case mpeg4Audio
    case aac
    case flac
    case caf
    case ogg
    case opus
    case wma
    case ac3
    case amr
    case au
    case unknown

    static func inferred(from url: URL) -> AudioAssetFormat {
        switch url.pathExtension.lowercased() {
        case "wav", "wave":
            return .wav
        case "aif", "aiff", "aifc":
            return .aiff
        case "mp3":
            return .mp3
        case "m4a", "mp4", "alac":
            return .mpeg4Audio
        case "aac":
            return .aac
        case "flac":
            return .flac
        case "caf":
            return .caf
        case "ogg", "oga":
            return .ogg
        case "opus":
            return .opus
        case "wma":
            return .wma
        case "ac3", "eac3":
            return .ac3
        case "amr":
            return .amr
        case "au", "snd":
            return .au
        default:
            return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .wav:
            return "WAV"
        case .aiff:
            return "AIFF"
        case .mp3:
            return "MP3"
        case .mpeg4Audio:
            return "MPEG-4 Audio"
        case .aac:
            return "AAC"
        case .flac:
            return "FLAC"
        case .caf:
            return "CAF"
        case .ogg:
            return "Ogg Vorbis"
        case .opus:
            return "Opus"
        case .wma:
            return "WMA"
        case .ac3:
            return "AC3"
        case .amr:
            return "AMR"
        case .au:
            return "AU"
        case .unknown:
            return "Unknown"
        }
    }

    var isWAVFastPath: Bool {
        self == .wav
    }
}

struct AudioAssetInfo: Sendable {
    let url: URL
    let format: AudioAssetFormat
    let metadata: AudioFileMetadata
    let wavFileInfo: WAVFileInfo?
    let nativeSampleRate: Double?
    let nativeChannelCount: Int?
    let nativeFrameCount: Int?
    let codecDescription: String?

    var duration: TimeInterval? {
        wavFileInfo?.duration ?? metadata.duration
    }

    var sampleRate: Double? {
        wavFileInfo?.sampleRate ?? nativeSampleRate
    }

    var channelCount: Int? {
        wavFileInfo?.channelCount ?? nativeChannelCount
    }

    var frameCount: Int? {
        wavFileInfo?.frameCount ?? nativeFrameCount
    }

    var supportsSparsePreview: Bool {
        wavFileInfo != nil
    }

    var supportsFileBackedEditing: Bool {
        wavFileInfo != nil
    }

    var requiresEditableProxy: Bool {
        wavFileInfo == nil
    }

    init(
        url: URL,
        format: AudioAssetFormat,
        metadata: AudioFileMetadata,
        wavFileInfo: WAVFileInfo?,
        nativeSampleRate: Double? = nil,
        nativeChannelCount: Int? = nil,
        nativeFrameCount: Int? = nil,
        codecDescription: String? = nil
    ) {
        self.url = url
        self.format = format
        self.metadata = metadata
        self.wavFileInfo = wavFileInfo
        self.nativeSampleRate = nativeSampleRate
        self.nativeChannelCount = nativeChannelCount
        self.nativeFrameCount = nativeFrameCount
        self.codecDescription = codecDescription
    }
}

struct AudioAssetPreviewResult: Sendable {
    let assetInfo: AudioAssetInfo
    let waveformOverview: WaveformOverview
    let zeroCrossingProbe: WAVZeroCrossingProbe?

    var wavPreviewResult: WAVPreviewImportResult? {
        guard let fileInfo = assetInfo.wavFileInfo else {
            return nil
        }

        return WAVPreviewImportResult(
            metadata: assetInfo.metadata,
            fileInfo: fileInfo,
            waveformOverview: waveformOverview,
            zeroCrossingProbe: zeroCrossingProbe
        )
    }
}

struct AudioAssetProxyResult: Sendable {
    let assetID: UUID
    let originalInfo: AudioAssetInfo
    let fingerprint: AudioImportFingerprint
    let proxyURL: URL
    let proxyFileInfo: WAVFileInfo
    let waveformOverview: WaveformOverview
    let zeroCrossingIndex: AudioZeroCrossingIndex
    let usesOriginalFile: Bool
    let cacheHit: Bool
    let peakWorkingSetBytes: Int
    let preparationMilliseconds: Double
}

enum AudioAssetImporter {
    enum ImportError: LocalizedError {
        case unsupportedPreviewFormat(AudioAssetFormat)
        case unsupportedDecodeFormat(AudioAssetFormat)
        case missingWAVFileInfo
        case unreadableNativeAudio(AudioAssetFormat)
        case nativeAudioFileTooLarge
        case unsupportedNativePCMLayout
        case invalidSampleRate
        case proxyDirectoryUnavailable

        var errorDescription: String? {
            switch self {
            case let .unsupportedPreviewFormat(format):
                "\(format.displayName) preview import is not wired up yet."
            case let .unsupportedDecodeFormat(format):
                "\(format.displayName) decode import is not wired up yet."
            case .missingWAVFileInfo:
                "The WAV fast path did not produce file information."
            case let .unreadableNativeAudio(format):
                "\(format.displayName) could not be decoded by the system audio importer."
            case .nativeAudioFileTooLarge:
                "This audio file is too large to decode into an editable proxy in one pass."
            case .unsupportedNativePCMLayout:
                "The decoded audio layout could not be converted into Soundtime's track format."
            case .invalidSampleRate:
                "The decoded audio file has an invalid sample rate."
            case .proxyDirectoryUnavailable:
                "Soundtime could not create the audio proxy directory."
            }
        }
    }

    static let editableProxySampleRate = 48_000.0

    static let commonAudioFileExtensions: Set<String> = [
        "wav", "wave",
        "aif", "aiff", "aifc",
        "mp3",
        "m4a", "mp4", "aac", "alac",
        "flac",
        "caf",
        "ogg", "oga", "opus",
        "wma",
        "ac3", "eac3",
        "amr",
        "au", "snd",
    ]

    static let supportedAudioFileExtensions: Set<String> = [
        "wav", "wave",
        "aif", "aiff", "aifc",
        "mp3",
        "m4a", "mp4", "aac", "alac",
        "flac",
        "caf",
        "ac3", "eac3",
        "amr",
        "au", "snd",
    ]

    static let supportedAudioFormatSummary =
        "WAV, AIFF, MP3, M4A/AAC/ALAC, FLAC, CAF, AC3/EAC3, AMR, AU, and SND"

    static func canImport(_ url: URL) -> Bool {
        supportedAudioFileExtensions.contains(url.pathExtension.lowercased())
    }

    static func inspect(url: URL) async throws -> AudioAssetInfo {
        try Task.checkCancellation()
        return try inspectSynchronously(url: url)
    }

    static func inspectSynchronously(url: URL) throws -> AudioAssetInfo {
        let format = AudioAssetFormat.inferred(from: url)
        guard canImport(url) else {
            throw ImportError.unsupportedDecodeFormat(format)
        }
        if format.isWAVFastPath, WAVAudioDecoder.canDecode(url) {
            let fileInfo = try WAVAudioDecoder.inspect(url: url)
            let metadata = try AudioFileMetadataLoader.loadQuickMetadata(
                for: url,
                duration: fileInfo.duration
            )
            return AudioAssetInfo(
                url: url,
                format: .wav,
                metadata: metadata,
                wavFileInfo: fileInfo
            )
        }

        let nativeInfo = try inspectNativeAudioSynchronously(url: url, format: format)
        let metadata = try AudioFileMetadataLoader.loadQuickMetadata(
            for: url,
            duration: nativeInfo.duration
        )
        return AudioAssetInfo(
            url: url,
            format: format,
            metadata: metadata,
            wavFileInfo: nil,
            nativeSampleRate: nativeInfo.sampleRate,
            nativeChannelCount: nativeInfo.channelCount,
            nativeFrameCount: nativeInfo.frameCount,
            codecDescription: nativeInfo.codecDescription
        )
    }

    static func loadPreview(
        at url: URL,
        targetBinCount: Int = 512,
        samplesPerBin: Int = 8
    ) async throws -> AudioAssetPreviewResult {
        try Task.checkCancellation()
        let assetInfo = try inspectSynchronously(url: url)
        let waveformOverview: WaveformOverview
        let zeroCrossingProbe: WAVZeroCrossingProbe?
        if assetInfo.format.isWAVFastPath, let fileInfo = assetInfo.wavFileInfo {
            (_, waveformOverview) = try WAVAudioDecoder.buildSparsePreview(
                url: url,
                targetBinCount: targetBinCount,
                samplesPerBin: samplesPerBin
            )
            zeroCrossingProbe = try? WAVAudioDecoder.makeZeroCrossingProbe(
                url: url,
                fileInfo: fileInfo
            )
        } else {
            waveformOverview = try buildNativeSparsePreview(
                url: url,
                assetInfo: assetInfo,
                targetBinCount: targetBinCount,
                samplesPerBin: samplesPerBin
            )
            zeroCrossingProbe = nil
        }
        return AudioAssetPreviewResult(
            assetInfo: assetInfo,
            waveformOverview: waveformOverview,
            zeroCrossingProbe: zeroCrossingProbe
        )
    }

    static func loadPreviewOverview(
        at url: URL,
        targetBinCount: Int,
        samplesPerBin: Int
    ) async throws -> (AudioAssetInfo, WaveformOverview) {
        try ImportWorkBudget.shared.performScheduledHeavyWork(.previewRefinement) {
            let assetInfo = try inspectSynchronously(url: url)
            guard assetInfo.format.isWAVFastPath else {
                throw ImportError.unsupportedPreviewFormat(assetInfo.format)
            }
            let (_, waveformOverview) = try WAVAudioDecoder.buildSparsePreview(
                url: url,
                targetBinCount: targetBinCount,
                samplesPerBin: samplesPerBin
            )
            return (assetInfo, waveformOverview)
        }
    }

    static func loadDecodedAsset(at url: URL) async throws -> (
        AudioAssetInfo,
        DecodedAudioBuffer,
        WaveformOverview,
        AudioZeroCrossingIndex
    ) {
        try ImportWorkBudget.shared.performScheduledHeavyWork(.backgroundDecode) {
            let assetInfo = try inspectSynchronously(url: url)
            let decodedAudioBuffer: DecodedAudioBuffer
            if assetInfo.format.isWAVFastPath {
                decodedAudioBuffer = try WAVAudioDecoder.decode(url: url)
            } else {
                decodedAudioBuffer = try decodeNativeAudioSynchronously(url: url, format: assetInfo.format)
            }

            let waveformOverview = WaveformOverviewBuilder.build(from: decodedAudioBuffer)
            let zeroCrossingIndex = AudioZeroCrossingIndex.build(from: decodedAudioBuffer)
            return (assetInfo, decodedAudioBuffer, waveformOverview, zeroCrossingIndex)
        }
    }

    static func importEditableAsset(
        at url: URL,
        targetSampleRate: Double = editableProxySampleRate,
        assetID: UUID = UUID(),
        progress: (@Sendable (AudioImportProgress) -> Void)? = nil
    ) async throws -> AudioAssetProxyResult {
        try ImportWorkBudget.shared.performScheduledHeavyWork(.backgroundDecode) {
            try Task.checkCancellation()
            let originalInfo = try inspectSynchronously(url: url)
            let fingerprint = try AudioImportFingerprint(
                url: url,
                assetInfo: originalInfo
            )
            return try prepareEditableAsset(
                originalInfo: originalInfo,
                fingerprint: fingerprint,
                targetSampleRate: targetSampleRate,
                assetID: assetID,
                progress: progress
            )
        }
    }

    static func importEditableAsset(
        admission: AudioImportAdmission,
        targetSampleRate: Double = editableProxySampleRate,
        progress: (@Sendable (AudioImportProgress) -> Void)? = nil
    ) async throws -> AudioAssetProxyResult {
        try ImportWorkBudget.shared.performScheduledHeavyWork(.backgroundDecode) {
            try prepareEditableAsset(
                originalInfo: admission.assetInfo,
                fingerprint: admission.fingerprint,
                targetSampleRate: targetSampleRate,
                assetID: admission.assetID,
                progress: progress
            )
        }
    }

    private static func prepareEditableAsset(
        originalInfo: AudioAssetInfo,
        fingerprint: AudioImportFingerprint,
        targetSampleRate: Double,
        assetID: UUID,
        progress: (@Sendable (AudioImportProgress) -> Void)?
    ) throws -> AudioAssetProxyResult {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        func elapsedMilliseconds() -> Double {
            Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000
        }
        try Task.checkCancellation()
        let url = originalInfo.url
        guard fingerprint.isCurrent(for: url) else {
            throw CocoaError(.fileReadUnknown)
        }

        if originalInfo.format.isWAVFastPath {
            guard let proxyFileInfo = originalInfo.wavFileInfo else {
                throw ImportError.missingWAVFileInfo
            }
            let (_, waveformOverview) = try WAVAudioDecoder.buildSparsePreview(
                url: url,
                targetBinCount: 16_384,
                samplesPerBin: 32
            )
            progress?(AudioImportProgress(
                stage: .complete,
                completedFrames: Int64(proxyFileInfo.frameCount),
                totalFrames: Int64(proxyFileInfo.frameCount),
                message: "Audio ready"
            ))
            return AudioAssetProxyResult(
                assetID: assetID,
                originalInfo: originalInfo,
                fingerprint: fingerprint,
                proxyURL: url,
                proxyFileInfo: proxyFileInfo,
                waveformOverview: waveformOverview,
                zeroCrossingIndex: AudioZeroCrossingIndex(
                    frameCount: proxyFileInfo.frameCount,
                    crossings: []
                ),
                usesOriginalFile: true,
                cacheHit: true,
                peakWorkingSetBytes: 0,
                preparationMilliseconds: elapsedMilliseconds()
            )
        }

        if let cached = AudioImportCacheStore.shared.cachedImport(
            for: fingerprint,
            sourceURL: url
        ) {
            progress?(AudioImportProgress(
                stage: .complete,
                completedFrames: Int64(cached.proxyFileInfo.frameCount),
                totalFrames: Int64(cached.proxyFileInfo.frameCount),
                message: "Loaded cached editable audio"
            ))
            return AudioAssetProxyResult(
                assetID: assetID,
                originalInfo: originalInfo,
                fingerprint: fingerprint,
                proxyURL: cached.proxyURL,
                proxyFileInfo: cached.proxyFileInfo,
                waveformOverview: cached.waveformOverview,
                zeroCrossingIndex: cached.zeroCrossingIndex,
                usesOriginalFile: false,
                cacheHit: true,
                peakWorkingSetBytes: 0,
                preparationMilliseconds: elapsedMilliseconds()
            )
        }

        let transaction = try AudioImportCacheStore.shared.beginTransaction(
            for: fingerprint
        )
        do {
            progress?(AudioImportProgress(
                stage: .proxying,
                completedFrames: 0,
                totalFrames: Int64(originalInfo.frameCount ?? 0),
                message: "Converting to editable audio"
            ))
            let built = try StreamingAudioProxyBuilder.build(
                sourceURL: url,
                destinationURL: transaction.stagedProxyURL,
                targetSampleRate: targetSampleRate,
                progress: progress
            )
            try Task.checkCancellation()
            let manifest = AudioImportManifest(
                assetID: assetID,
                fingerprint: fingerprint,
                originalURL: url,
                format: originalInfo.format,
                displayName: originalInfo.metadata.displayName,
                proxyFileName: transaction.stagedProxyURL.lastPathComponent,
                sourceSampleRate: originalInfo.sampleRate ?? 0,
                sourceFrameCount: Int64(originalInfo.frameCount ?? 0),
                proxySampleRate: built.fileInfo.sampleRate,
                proxyFrameCount: Int64(built.fileInfo.frameCount),
                channelCount: built.fileInfo.channelCount
            )
            let cached = try AudioImportCacheStore.shared.commit(
                transaction,
                manifest: manifest,
                waveformOverview: built.waveformOverview,
                zeroCrossingIndex: built.zeroCrossingIndex
            )
            progress?(AudioImportProgress(
                stage: .complete,
                completedFrames: Int64(cached.proxyFileInfo.frameCount),
                totalFrames: Int64(cached.proxyFileInfo.frameCount),
                message: "Import complete"
            ))
            return AudioAssetProxyResult(
                assetID: assetID,
                originalInfo: originalInfo,
                fingerprint: fingerprint,
                proxyURL: cached.proxyURL,
                proxyFileInfo: cached.proxyFileInfo,
                waveformOverview: cached.waveformOverview,
                zeroCrossingIndex: cached.zeroCrossingIndex,
                usesOriginalFile: false,
                cacheHit: false,
                peakWorkingSetBytes: built.peakWorkingSetBytes,
                preparationMilliseconds: elapsedMilliseconds()
            )
        } catch {
            AudioImportCacheStore.shared.cancel(transaction)
            throw error
        }
    }

    private struct NativeAudioInspection {
        let sampleRate: Double?
        let channelCount: Int?
        let frameCount: Int?
        let duration: TimeInterval?
        let codecDescription: String?
    }

    private static func inspectNativeAudioSynchronously(
        url: URL,
        format: AudioAssetFormat
    ) throws -> NativeAudioInspection {
        guard canImport(url) else {
            throw ImportError.unsupportedDecodeFormat(format)
        }

        do {
            let file = try AVAudioFile(forReading: url)
            let processingFormat = file.processingFormat
            let sampleRate = processingFormat.sampleRate.isFinite && processingFormat.sampleRate > 0 ?
                processingFormat.sampleRate :
                nil
            let frameCount = file.length > 0 && file.length <= AVAudioFramePosition(Int.max) ?
                Int(file.length) :
                nil
            let duration = sampleRate.flatMap { sampleRate -> TimeInterval? in
                guard let frameCount else {
                    return nil
                }
                return Double(frameCount) / sampleRate
            }
            return NativeAudioInspection(
                sampleRate: sampleRate,
                channelCount: Int(processingFormat.channelCount),
                frameCount: frameCount,
                duration: duration,
                codecDescription: processingFormat.streamDescription.pointee.formatDescription
            )
        } catch {
            throw ImportError.unreadableNativeAudio(format)
        }
    }

    private static func decodeNativeAudioSynchronously(
        url: URL,
        format: AudioAssetFormat
    ) throws -> DecodedAudioBuffer {
        guard canImport(url) else {
            throw ImportError.unsupportedDecodeFormat(format)
        }

        do {
            let file = try AVAudioFile(
                forReading: url,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let processingFormat = file.processingFormat
            let sampleRate = processingFormat.sampleRate
            guard sampleRate.isFinite, sampleRate > 0 else {
                throw ImportError.invalidSampleRate
            }
            guard file.length >= 0, file.length <= AVAudioFramePosition(UInt32.max) else {
                throw ImportError.nativeAudioFileTooLarge
            }

            let frameCapacity = AVAudioFrameCount(file.length)
            guard
                let pcmBuffer = AVAudioPCMBuffer(
                    pcmFormat: processingFormat,
                    frameCapacity: frameCapacity
                )
            else {
                throw ImportError.unsupportedNativePCMLayout
            }
            try file.read(into: pcmBuffer)

            guard let floatChannelData = pcmBuffer.floatChannelData else {
                throw ImportError.unsupportedNativePCMLayout
            }

            let frameCount = Int(pcmBuffer.frameLength)
            let channelCount = Int(processingFormat.channelCount)
            guard channelCount > 0 else {
                throw ImportError.unsupportedNativePCMLayout
            }

            var samplesByChannel: [[Float]] = []
            samplesByChannel.reserveCapacity(channelCount)
            for channelIndex in 0..<channelCount {
                let channelPointer = floatChannelData[channelIndex]
                let samples = Array(UnsafeBufferPointer(start: channelPointer, count: frameCount))
                samplesByChannel.append(samples)
            }

            return DecodedAudioBuffer(
                url: url,
                sampleRate: sampleRate,
                channelCount: channelCount,
                frameCount: frameCount,
                samplesByChannel: samplesByChannel
            )
        } catch let importError as ImportError {
            throw importError
        } catch {
            throw ImportError.unreadableNativeAudio(format)
        }
    }

    private static func buildNativeSparsePreview(
        url: URL,
        assetInfo: AudioAssetInfo,
        targetBinCount: Int,
        samplesPerBin: Int
    ) throws -> WaveformOverview {
        guard canImport(url) else {
            throw ImportError.unsupportedPreviewFormat(assetInfo.format)
        }

        do {
            let file = try AVAudioFile(
                forReading: url,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let processingFormat = file.processingFormat
            let sampleRate = processingFormat.sampleRate
            guard sampleRate.isFinite, sampleRate > 0 else {
                throw ImportError.invalidSampleRate
            }
            guard file.length > 0, file.length <= AVAudioFramePosition(Int.max) else {
                return WaveformOverview(duration: assetInfo.duration ?? 0, bins: [])
            }

            let frameCount = Int(file.length)
            let binCount = min(max(targetBinCount, 1), frameCount)
            let previewWindowFrameCount = max(samplesPerBin, 16)
            var bins: [WaveformOverview.Bin] = []
            bins.reserveCapacity(binCount)

            for binIndex in 0..<binCount {
                if binIndex.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }

                let startFrame = binIndex * frameCount / binCount
                let endFrame = max((binIndex + 1) * frameCount / binCount, startFrame + 1)
                let frameSpan = endFrame - startFrame
                let framesToRead = min(previewWindowFrameCount, frameSpan)
                let readStartFrame: Int
                if frameSpan <= framesToRead {
                    readStartFrame = startFrame
                } else {
                    readStartFrame = startFrame + max((frameSpan - framesToRead) / 2, 0)
                }

                file.framePosition = AVAudioFramePosition(readStartFrame)
                guard
                    let buffer = AVAudioPCMBuffer(
                        pcmFormat: processingFormat,
                        frameCapacity: AVAudioFrameCount(framesToRead)
                    )
                else {
                    throw ImportError.unsupportedNativePCMLayout
                }
                try file.read(
                    into: buffer,
                    frameCount: AVAudioFrameCount(min(framesToRead, frameCount - readStartFrame))
                )

                var accumulator = WaveformBinAccumulator()
                if let floatChannelData = buffer.floatChannelData {
                    let channelCount = Int(processingFormat.channelCount)
                    let readFrameCount = Int(buffer.frameLength)
                    for channelIndex in 0..<channelCount {
                        let channelPointer = floatChannelData[channelIndex]
                        for frameIndex in 0..<readFrameCount {
                            accumulator.addSample(channelPointer[frameIndex])
                        }
                    }
                }
                bins.append(accumulator.makeBin())
            }

            let duration = assetInfo.duration ?? (Double(frameCount) / sampleRate)
            return WaveformOverview(duration: duration, bins: bins)
        } catch let importError as ImportError {
            throw importError
        } catch {
            throw ImportError.unreadableNativeAudio(assetInfo.format)
        }
    }

}

private extension AudioStreamBasicDescription {
    var formatDescription: String {
        let formatID = String(formatID: mFormatID)
        return "\(formatID) \(Int(mSampleRate.rounded())) Hz \(Int(mChannelsPerFrame)) ch"
    }
}

private extension String {
    init(formatID: AudioFormatID) {
        let bytes = [
            UInt8((formatID >> 24) & 0xFF),
            UInt8((formatID >> 16) & 0xFF),
            UInt8((formatID >> 8) & 0xFF),
            UInt8(formatID & 0xFF),
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
            self = String(bytes: bytes, encoding: .ascii) ?? "\(formatID)"
        } else {
            self = "\(formatID)"
        }
    }
}
