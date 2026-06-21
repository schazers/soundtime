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
    let originalInfo: AudioAssetInfo
    let proxyURL: URL
    let proxyFileInfo: WAVFileInfo
    let decodedAudioBuffer: DecodedAudioBuffer
    let waveformOverview: WaveformOverview
    let zeroCrossingIndex: AudioZeroCrossingIndex
    let usesOriginalFile: Bool
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

    static func canImport(_ url: URL) -> Bool {
        supportedAudioFileExtensions.contains(url.pathExtension.lowercased())
    }

    static func inspect(url: URL) async throws -> AudioAssetInfo {
        try await Task.detached(priority: .userInitiated) {
            try inspectSynchronously(url: url)
        }.value
    }

    static func inspectSynchronously(url: URL) throws -> AudioAssetInfo {
        let format = AudioAssetFormat.inferred(from: url)
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

        let nativeInfo = try? inspectNativeAudioSynchronously(url: url, format: format)
        let metadata = try AudioFileMetadataLoader.loadQuickMetadata(
            for: url,
            duration: nativeInfo?.duration
        )
        return AudioAssetInfo(
            url: url,
            format: format,
            metadata: metadata,
            wavFileInfo: nil,
            nativeSampleRate: nativeInfo?.sampleRate,
            nativeChannelCount: nativeInfo?.channelCount,
            nativeFrameCount: nativeInfo?.frameCount,
            codecDescription: nativeInfo?.codecDescription
        )
    }

    static func loadPreview(
        at url: URL,
        targetBinCount: Int = 512,
        samplesPerBin: Int = 8
    ) async throws -> AudioAssetPreviewResult {
        try await Task.detached(priority: .userInitiated) {
            let assetInfo = try inspectSynchronously(url: url)
            guard
                assetInfo.format.isWAVFastPath,
                let fileInfo = assetInfo.wavFileInfo
            else {
                throw ImportError.unsupportedPreviewFormat(assetInfo.format)
            }

            let (_, waveformOverview) = try WAVAudioDecoder.buildSparsePreview(
                url: url,
                targetBinCount: targetBinCount,
                samplesPerBin: samplesPerBin
            )
            let zeroCrossingProbe = try? WAVAudioDecoder.makeZeroCrossingProbe(
                url: url,
                fileInfo: fileInfo
            )
            return AudioAssetPreviewResult(
                assetInfo: assetInfo,
                waveformOverview: waveformOverview,
                zeroCrossingProbe: zeroCrossingProbe
            )
        }.value
    }

    static func loadPreviewOverview(
        at url: URL,
        targetBinCount: Int,
        samplesPerBin: Int
    ) async throws -> (AudioAssetInfo, WaveformOverview) {
        try await Task.detached(priority: .utility) {
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
        }.value
    }

    static func loadDecodedAsset(at url: URL) async throws -> (
        AudioAssetInfo,
        DecodedAudioBuffer,
        WaveformOverview,
        AudioZeroCrossingIndex
    ) {
        try await Task.detached(priority: .background) {
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
        }.value
    }

    static func importEditableAsset(
        at url: URL,
        targetSampleRate: Double = editableProxySampleRate
    ) async throws -> AudioAssetProxyResult {
        try await Task.detached(priority: .userInitiated) {
            try ImportWorkBudget.shared.performScheduledHeavyWork(.backgroundDecode) {
                let originalInfo = try inspectSynchronously(url: url)
                if originalInfo.format.isWAVFastPath {
                    guard let proxyFileInfo = originalInfo.wavFileInfo else {
                        throw ImportError.missingWAVFileInfo
                    }
                    let decodedAudioBuffer = try WAVAudioDecoder.decode(url: url)
                    let waveformOverview = WaveformOverviewBuilder.build(from: decodedAudioBuffer)
                    let zeroCrossingIndex = AudioZeroCrossingIndex.build(from: decodedAudioBuffer)
                    return AudioAssetProxyResult(
                        originalInfo: originalInfo,
                        proxyURL: url,
                        proxyFileInfo: proxyFileInfo,
                        decodedAudioBuffer: decodedAudioBuffer,
                        waveformOverview: waveformOverview,
                        zeroCrossingIndex: zeroCrossingIndex,
                        usesOriginalFile: true
                    )
                }

                var decodedAudioBuffer = try decodeNativeAudioSynchronously(
                    url: url,
                    format: originalInfo.format
                )
                decodedAudioBuffer = try resampleIfNeeded(
                    decodedAudioBuffer,
                    targetSampleRate: targetSampleRate
                )

                let proxyURL = try makeEditableProxyURL(for: url, format: originalInfo.format)
                let proxyBuffer = DecodedAudioBuffer(
                    url: proxyURL,
                    sampleRate: decodedAudioBuffer.sampleRate,
                    channelCount: decodedAudioBuffer.channelCount,
                    frameCount: decodedAudioBuffer.frameCount,
                    samplesByChannel: decodedAudioBuffer.samplesByChannel
                )
                try WAVFileWriter.write(proxyBuffer, to: proxyURL)
                let proxyFileInfo = try WAVAudioDecoder.inspect(url: proxyURL)
                let waveformOverview = WaveformOverviewBuilder.build(from: proxyBuffer)
                let zeroCrossingIndex = AudioZeroCrossingIndex.build(from: proxyBuffer)
                return AudioAssetProxyResult(
                    originalInfo: originalInfo,
                    proxyURL: proxyURL,
                    proxyFileInfo: proxyFileInfo,
                    decodedAudioBuffer: proxyBuffer,
                    waveformOverview: waveformOverview,
                    zeroCrossingIndex: zeroCrossingIndex,
                    usesOriginalFile: false
                )
            }
        }.value
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

    private static func resampleIfNeeded(
        _ buffer: DecodedAudioBuffer,
        targetSampleRate: Double
    ) throws -> DecodedAudioBuffer {
        guard targetSampleRate.isFinite, targetSampleRate > 0 else {
            throw ImportError.invalidSampleRate
        }
        guard buffer.sampleRate.isFinite, buffer.sampleRate > 0 else {
            throw ImportError.invalidSampleRate
        }
        guard abs(buffer.sampleRate - targetSampleRate) >= 0.5 else {
            return buffer
        }

        let ratio = targetSampleRate / buffer.sampleRate
        let targetFrameCount = max(0, Int((Double(buffer.frameCount) * ratio).rounded()))
        guard targetFrameCount > 0 else {
            return DecodedAudioBuffer(
                url: buffer.url,
                sampleRate: targetSampleRate,
                channelCount: buffer.channelCount,
                frameCount: 0,
                samplesByChannel: Array(repeating: [], count: buffer.channelCount)
            )
        }

        var resampledChannels: [[Float]] = []
        resampledChannels.reserveCapacity(buffer.channelCount)
        for channelIndex in 0..<buffer.channelCount {
            let source = channelIndex < buffer.samplesByChannel.count ?
                buffer.samplesByChannel[channelIndex] :
                []
            guard !source.isEmpty else {
                resampledChannels.append([Float](repeating: 0, count: targetFrameCount))
                continue
            }

            var output = [Float](repeating: 0, count: targetFrameCount)
            let sourceLastIndex = max(source.count - 1, 0)
            for targetIndex in 0..<targetFrameCount {
                let sourcePosition = Double(targetIndex) / ratio
                let lowerIndex = min(max(Int(sourcePosition.rounded(.down)), 0), sourceLastIndex)
                let upperIndex = min(lowerIndex + 1, sourceLastIndex)
                let fraction = Float(sourcePosition - Double(lowerIndex))
                output[targetIndex] = source[lowerIndex] + (source[upperIndex] - source[lowerIndex]) * fraction
            }
            resampledChannels.append(output)
        }

        return DecodedAudioBuffer(
            url: buffer.url,
            sampleRate: targetSampleRate,
            channelCount: buffer.channelCount,
            frameCount: targetFrameCount,
            samplesByChannel: resampledChannels
        )
    }

    private static func makeEditableProxyURL(
        for url: URL,
        format: AudioAssetFormat
    ) throws -> URL {
        let directory = try editableProxyDirectory()
        let baseName = sanitizedFilenameStem(url.deletingPathExtension().lastPathComponent)
        let formatName = format.rawValue
        return directory.appendingPathComponent(
            "\(baseName)-\(formatName)-\(UUID().uuidString).wav",
            isDirectory: false
        )
    }

    private static func editableProxyDirectory() throws -> URL {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ImportError.proxyDirectoryUnavailable
        }
        let directory = applicationSupportURL
            .appendingPathComponent("Soundtime", isDirectory: true)
            .appendingPathComponent("AudioProxies", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func sanitizedFilenameStem(_ value: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowedScalars.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "ImportedAudio" : String(collapsed.prefix(64))
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
