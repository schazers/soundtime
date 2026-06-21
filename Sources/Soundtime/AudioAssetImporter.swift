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

    var duration: TimeInterval? {
        wavFileInfo?.duration ?? metadata.duration
    }

    var sampleRate: Double? {
        wavFileInfo?.sampleRate
    }

    var channelCount: Int? {
        wavFileInfo?.channelCount
    }

    var frameCount: Int? {
        wavFileInfo?.frameCount
    }

    var supportsSparsePreview: Bool {
        wavFileInfo != nil
    }

    var supportsFileBackedEditing: Bool {
        wavFileInfo != nil
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

enum AudioAssetImporter {
    enum ImportError: LocalizedError {
        case unsupportedPreviewFormat(AudioAssetFormat)
        case unsupportedDecodeFormat(AudioAssetFormat)
        case missingWAVFileInfo

        var errorDescription: String? {
            switch self {
            case let .unsupportedPreviewFormat(format):
                "\(format.displayName) preview import is not wired up yet."
            case let .unsupportedDecodeFormat(format):
                "\(format.displayName) decode import is not wired up yet."
            case .missingWAVFileInfo:
                "The WAV fast path did not produce file information."
            }
        }
    }

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

    static func canImport(_ url: URL) -> Bool {
        commonAudioFileExtensions.contains(url.pathExtension.lowercased())
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

        let metadata = try AudioFileMetadataLoader.loadQuickMetadata(for: url, duration: nil)
        return AudioAssetInfo(
            url: url,
            format: format,
            metadata: metadata,
            wavFileInfo: nil
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
                guard assetInfo.format.isWAVFastPath else {
                    throw ImportError.unsupportedDecodeFormat(assetInfo.format)
                }

                let decodedAudioBuffer = try WAVAudioDecoder.decode(url: url)
                let waveformOverview = WaveformOverviewBuilder.build(from: decodedAudioBuffer)
                let zeroCrossingIndex = AudioZeroCrossingIndex.build(from: decodedAudioBuffer)
                return (assetInfo, decodedAudioBuffer, waveformOverview, zeroCrossingIndex)
            }
        }.value
    }
}
