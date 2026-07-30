import Foundation

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

    static func loadDecodedWAV(at url: URL) async throws -> (
        DecodedAudioBuffer,
        WaveformOverview,
        AudioZeroCrossingIndex
    ) {
        let (_, decodedAudioBuffer, waveformOverview, zeroCrossingIndex) =
            try await AudioAssetImporter.loadDecodedAsset(at: url)
        return (decodedAudioBuffer, waveformOverview, zeroCrossingIndex)
    }

}
