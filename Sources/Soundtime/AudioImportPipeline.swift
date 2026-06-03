import Foundation

struct AudioImportResult: Sendable {
    enum DecodeStatus: Sendable {
        case unsupported
        case decoded(DecodedAudioBuffer)
        case failed(String)
    }

    let metadata: AudioFileMetadata
    let decodeStatus: DecodeStatus
}

enum AudioImportPipeline {
    static func loadDroppedFile(at url: URL) async throws -> AudioImportResult {
        try await Task.detached(priority: .userInitiated) {
            let metadata = try await AudioFileMetadataLoader.loadMetadata(for: url)

            guard WAVAudioDecoder.canDecode(url) else {
                return AudioImportResult(metadata: metadata, decodeStatus: .unsupported)
            }

            do {
                let decodedAudioBuffer = try WAVAudioDecoder.decode(url: url)
                return AudioImportResult(
                    metadata: metadata,
                    decodeStatus: .decoded(decodedAudioBuffer)
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
