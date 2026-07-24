import Foundation

actor TranscriptionChunkRecoveryStore {
    private struct CachedChunkTranscript: Codable, Sendable {
        var providerIdentifier: String
        var providerModelName: String?
        var sourceFingerprint: String
        var sourceRevision: Int
        var sourceDuration: TimeInterval
        var chunk: TranscriptionChunk
        var transcript: TranscriptDocument
    }

    private let rootURL: URL
    private let fileManager: FileManager

    init(
        rootURL: URL = TranscriptionChunkRecoveryStore.defaultRootURL(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func transcript(
        request: TranscriptionRequest,
        providerIdentifier: String,
        providerModelName: String?,
        chunk: TranscriptionChunk
    ) -> TranscriptDocument? {
        let url = chunkURL(
            request: request,
            providerIdentifier: providerIdentifier,
            providerModelName: providerModelName,
            chunk: chunk
        )
        guard
            let data = try? Data(contentsOf: url),
            let cached = try? JSONDecoder().decode(CachedChunkTranscript.self, from: data),
            cached.providerIdentifier == providerIdentifier,
            cached.providerModelName == providerModelName,
            cached.sourceFingerprint == Self.sourceFingerprint(for: request),
            cached.sourceRevision == request.inputAsset.sourceRevision,
            abs(cached.sourceDuration - request.inputAsset.duration) < 0.001,
            cached.chunk == chunk
        else {
            return nil
        }

        return cached.transcript
    }

    func store(
        _ transcript: TranscriptDocument,
        request: TranscriptionRequest,
        providerIdentifier: String,
        providerModelName: String?,
        chunk: TranscriptionChunk
    ) {
        let url = chunkURL(
            request: request,
            providerIdentifier: providerIdentifier,
            providerModelName: providerModelName,
            chunk: chunk
        )
        let cached = CachedChunkTranscript(
            providerIdentifier: providerIdentifier,
            providerModelName: providerModelName,
            sourceFingerprint: Self.sourceFingerprint(for: request),
            sourceRevision: request.inputAsset.sourceRevision,
            sourceDuration: request.inputAsset.duration,
            chunk: chunk,
            transcript: transcript
        )

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(cached).write(to: url, options: [.atomic])
        } catch {
            SoundtimeDiagnostics.shared.record(
                category: .api,
                severity: .warning,
                name: "transcription-chunk-cache-write-failed",
                message: "Could not cache transcription chunk for recovery.",
                fields: [
                    "provider": providerIdentifier,
                    "chunk": "\(chunk.index + 1)",
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func cachedChunkCount(
        request: TranscriptionRequest,
        providerIdentifier: String,
        providerModelName: String?,
        chunks: [TranscriptionChunk]
    ) -> Int {
        chunks.reduce(0) { count, chunk in
            let url = chunkURL(
                request: request,
                providerIdentifier: providerIdentifier,
                providerModelName: providerModelName,
                chunk: chunk
            )
            return count + (fileManager.fileExists(atPath: url.path) ? 1 : 0)
        }
    }

    private func chunkURL(
        request: TranscriptionRequest,
        providerIdentifier: String,
        providerModelName: String?,
        chunk: TranscriptionChunk
    ) -> URL {
        rootURL
            .appendingPathComponent(safePathComponent(providerIdentifier), isDirectory: true)
            .appendingPathComponent(safePathComponent(providerModelName ?? "default"), isDirectory: true)
            .appendingPathComponent(Self.cacheKey(for: request), isDirectory: true)
            .appendingPathComponent("chunk-\(chunk.index)-\(Self.chunkKey(chunk)).json")
    }

    private func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let component = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return component.isEmpty ? "unknown" : component
    }

    static func cacheKey(for request: TranscriptionRequest) -> String {
        stableHexDigest(
            [
                sourceFingerprint(for: request),
                "\(request.inputAsset.sourceRevision)",
                String(format: "%.3f", request.inputAsset.duration),
                request.preferredLanguageCode ?? "",
            ].joined(separator: "|")
        )
    }

    static func sourceFingerprint(for request: TranscriptionRequest) -> String {
        if let fingerprint = request.inputAsset.sourceFingerprint, !fingerprint.isEmpty {
            return fingerprint
        }

        let url = request.inputAsset.url.standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes?[.size].map { "\($0)" } ?? "-"
        let modificationTime = (attributes?[.modificationDate] as? Date).map {
            String(format: "%.3f", $0.timeIntervalSince1970)
        } ?? "-"
        return [
            url.path,
            request.inputAsset.displayName,
            fileSize,
            modificationTime,
        ].joined(separator: "|")
    }

    private static func chunkKey(_ chunk: TranscriptionChunk) -> String {
        stableHexDigest(
            [
                "\(chunk.index)",
                String(format: "%.3f", chunk.requestedStartTime),
                String(format: "%.3f", chunk.requestedEndTime),
                String(format: "%.3f", chunk.contextStartTime),
                String(format: "%.3f", chunk.contextEndTime),
            ].joined(separator: "|")
        )
    }

    private static func stableHexDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func defaultRootURL() -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseDirectory
            .appendingPathComponent("Soundtime", isDirectory: true)
            .appendingPathComponent("TranscriptionChunkCache", isDirectory: true)
    }
}
