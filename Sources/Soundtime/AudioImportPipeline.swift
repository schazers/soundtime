import Foundation

struct AudioImportResult: Sendable {
    enum DecodeStatus: Sendable {
        case unsupported
        case decoded(DecodedAudioBuffer, WaveformOverview)
        case failed(String)
    }

    let metadata: AudioFileMetadata
    let decodeStatus: DecodeStatus
}

enum AudioImportPipeline {
    static func loadWAVPreview(at url: URL) async throws -> WAVPreviewImportResult {
        try await Task.detached(priority: .userInitiated) {
            let (fileInfo, waveformOverview) = try WAVAudioDecoder.buildSparsePreview(url: url)
            let metadata = try AudioFileMetadataLoader.loadQuickMetadata(
                for: url,
                duration: fileInfo.duration
            )

            return WAVPreviewImportResult(
                metadata: metadata,
                fileInfo: fileInfo,
                waveformOverview: waveformOverview
            )
        }.value
    }

    static func loadDecodedWAV(at url: URL) async throws -> (DecodedAudioBuffer, WaveformOverview) {
        try await Task.detached(priority: .userInitiated) {
            let decodedAudioBuffer = try WAVAudioDecoder.decode(url: url)
            let waveformOverview = WaveformOverviewBuilder.build(from: decodedAudioBuffer)
            return (decodedAudioBuffer, waveformOverview)
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
                return AudioImportResult(
                    metadata: metadata,
                    decodeStatus: .decoded(decodedAudioBuffer, waveformOverview)
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
