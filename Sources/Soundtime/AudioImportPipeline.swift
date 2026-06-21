import Foundation

struct AudioImportResult: Sendable {
    enum DecodeStatus: Sendable {
        case unsupported
        case decoded(DecodedAudioBuffer, WaveformOverview, AudioZeroCrossingIndex)
        case failed(String)
    }

    let metadata: AudioFileMetadata
    let decodeStatus: DecodeStatus
}

enum AudioImportPipeline {
    static func loadWAVPreview(
        at url: URL,
        targetBinCount: Int = 512,
        samplesPerBin: Int = 8
    ) async throws -> WAVPreviewImportResult {
        let preview = try await AudioAssetImporter.loadPreview(
            at: url,
            targetBinCount: targetBinCount,
            samplesPerBin: samplesPerBin
        )
        guard let wavPreview = preview.wavPreviewResult else {
            throw AudioAssetImporter.ImportError.missingWAVFileInfo
        }
        return wavPreview
    }

    static func loadPreview(
        at url: URL,
        targetBinCount: Int = 512,
        samplesPerBin: Int = 8
    ) async throws -> AudioAssetPreviewResult {
        try await AudioAssetImporter.loadPreview(
            at: url,
            targetBinCount: targetBinCount,
            samplesPerBin: samplesPerBin
        )
    }

    static func loadWAVPreviewOverview(
        at url: URL,
        targetBinCount: Int,
        samplesPerBin: Int
    ) async throws -> (WAVFileInfo, WaveformOverview) {
        let (assetInfo, waveformOverview) = try await AudioAssetImporter.loadPreviewOverview(
            at: url,
            targetBinCount: targetBinCount,
            samplesPerBin: samplesPerBin
        )
        guard let fileInfo = assetInfo.wavFileInfo else {
            throw AudioAssetImporter.ImportError.missingWAVFileInfo
        }
        return (fileInfo, waveformOverview)
    }

    static func loadPreviewOverview(
        at url: URL,
        targetBinCount: Int,
        samplesPerBin: Int
    ) async throws -> (AudioAssetInfo, WaveformOverview) {
        try await AudioAssetImporter.loadPreviewOverview(
            at: url,
            targetBinCount: targetBinCount,
            samplesPerBin: samplesPerBin
        )
    }

    static func loadDecodedWAV(at url: URL) async throws -> (
        DecodedAudioBuffer,
        WaveformOverview,
        AudioZeroCrossingIndex
    ) {
        let (_, decodedAudioBuffer, waveformOverview, zeroCrossingIndex) =
            try await AudioAssetImporter.loadDecodedAsset(at: url)
        return (decodedAudioBuffer, waveformOverview, zeroCrossingIndex)
    }

    static func loadDecodedAsset(at url: URL) async throws -> (
        AudioAssetInfo,
        DecodedAudioBuffer,
        WaveformOverview,
        AudioZeroCrossingIndex
    ) {
        try await AudioAssetImporter.loadDecodedAsset(at: url)
    }

    static func loadDroppedFile(at url: URL) async throws -> AudioImportResult {
        try await Task.detached(priority: .userInitiated) {
            let metadata = try await AudioFileMetadataLoader.loadMetadata(for: url)

            guard AudioAssetImporter.canImport(url) else {
                return AudioImportResult(metadata: metadata, decodeStatus: .unsupported)
            }
            guard AudioAssetFormat.inferred(from: url).isWAVFastPath else {
                return AudioImportResult(metadata: metadata, decodeStatus: .unsupported)
            }

            do {
                let (_, decodedAudioBuffer, waveformOverview, zeroCrossingIndex) =
                    try await AudioAssetImporter.loadDecodedAsset(at: url)
                return AudioImportResult(
                    metadata: metadata,
                    decodeStatus: .decoded(decodedAudioBuffer, waveformOverview, zeroCrossingIndex)
                )
            } catch {
                return AudioImportResult(
                    metadata: metadata,
                    decodeStatus: .failed(error.localizedDescription)
                )
            }
        }.value
    }
}
