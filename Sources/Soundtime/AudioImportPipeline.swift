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
        try await Task.detached(priority: .userInitiated) {
            let (fileInfo, waveformOverview) = try WAVAudioDecoder.buildSparsePreview(
                url: url,
                targetBinCount: targetBinCount,
                samplesPerBin: samplesPerBin
            )
            let metadata = try AudioFileMetadataLoader.loadQuickMetadata(
                for: url,
                duration: fileInfo.duration
            )
            let zeroCrossingProbe = try? WAVAudioDecoder.makeZeroCrossingProbe(
                url: url,
                fileInfo: fileInfo
            )

            return WAVPreviewImportResult(
                metadata: metadata,
                fileInfo: fileInfo,
                waveformOverview: waveformOverview,
                zeroCrossingProbe: zeroCrossingProbe
            )
        }.value
    }

    static func loadWAVPreviewOverview(
        at url: URL,
        targetBinCount: Int,
        samplesPerBin: Int
    ) async throws -> (WAVFileInfo, WaveformOverview) {
        try await Task.detached(priority: .utility) {
            try WAVAudioDecoder.buildSparsePreview(
                url: url,
                targetBinCount: targetBinCount,
                samplesPerBin: samplesPerBin
            )
        }.value
    }

    static func loadDecodedWAV(at url: URL) async throws -> (
        DecodedAudioBuffer,
        WaveformOverview,
        AudioZeroCrossingIndex
    ) {
        try await Task.detached(priority: .background) {
            let decodedAudioBuffer = try WAVAudioDecoder.decode(url: url)
            let waveformOverview = WaveformOverviewBuilder.build(from: decodedAudioBuffer)
            let zeroCrossingIndex = AudioZeroCrossingIndex.build(from: decodedAudioBuffer)
            return (decodedAudioBuffer, waveformOverview, zeroCrossingIndex)
        }.value
    }

    static func loadDroppedFile(at url: URL) async throws -> AudioImportResult {
        try await Task.detached(priority: .userInitiated) {
            let metadata = try await AudioFileMetadataLoader.loadMetadata(for: url)

            guard WAVAudioDecoder.canDecode(url) else {
                return AudioImportResult(metadata: metadata, decodeStatus: .unsupported)
            }

            do {
                let decodedAudioBuffer = try WAVAudioDecoder.decode(url: url)
                let waveformOverview = WaveformOverviewBuilder.build(from: decodedAudioBuffer)
                let zeroCrossingIndex = AudioZeroCrossingIndex.build(from: decodedAudioBuffer)
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
