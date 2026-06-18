import Foundation

struct WaveformDiskCacheManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    struct TileLevel: Codable, Equatable, Sendable {
        let kind: WaveformTileKind
        let channelMode: WaveformChannelMode
        let level: Int
        let framesPerBin: Int
        let framesPerTile: Int64
        let tileCount: Int
        let fileName: String

        init(
            kind: WaveformTileKind,
            channelMode: WaveformChannelMode,
            level: Int,
            framesPerBin: Int,
            framesPerTile: Int64,
            tileCount: Int,
            fileName: String
        ) {
            self.kind = kind
            self.channelMode = channelMode
            self.level = max(0, level)
            self.framesPerBin = max(1, framesPerBin)
            self.framesPerTile = max(1, framesPerTile)
            self.tileCount = max(0, tileCount)
            self.fileName = fileName
        }
    }

    let formatVersion: Int
    let sourceID: WaveformSourceID
    let fingerprint: WaveformFileFingerprint
    let duration: TimeInterval
    let frameCount: Int64
    let levels: [TileLevel]

    init(
        sourceID: WaveformSourceID,
        fingerprint: WaveformFileFingerprint,
        duration: TimeInterval,
        frameCount: Int64,
        levels: [TileLevel] = []
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.sourceID = sourceID
        self.fingerprint = fingerprint
        self.duration = max(0, duration)
        self.frameCount = max(0, frameCount)
        self.levels = levels
    }

    func isValid(for expectedFingerprint: WaveformFileFingerprint) -> Bool {
        formatVersion == Self.currentFormatVersion &&
            fingerprint == expectedFingerprint &&
            sourceID == WaveformSourceID(fingerprint: expectedFingerprint)
    }
}

enum WaveformDiskCacheError: Error, LocalizedError {
    case invalidManifest(WaveformDiskCacheManifest)

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            return "The waveform cache manifest does not match the source file."
        }
    }
}

final class WaveformDiskCacheStore: @unchecked Sendable {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        rootDirectory: URL = WaveformDiskCacheStore.defaultRootDirectory(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    static func defaultRootDirectory() -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return baseDirectory
            .appendingPathComponent("Soundtime", isDirectory: true)
            .appendingPathComponent("WaveformCache", isDirectory: true)
            .standardizedFileURL
    }

    func cacheDirectory(for fingerprint: WaveformFileFingerprint) -> URL {
        rootDirectory
            .appendingPathComponent(fingerprint.cacheKey, isDirectory: true)
            .standardizedFileURL
    }

    func manifestURL(for fingerprint: WaveformFileFingerprint) -> URL {
        cacheDirectory(for: fingerprint)
            .appendingPathComponent("manifest")
            .appendingPathExtension("json")
    }

    func tileLevelURL(
        for fingerprint: WaveformFileFingerprint,
        level: WaveformDiskCacheManifest.TileLevel
    ) -> URL {
        cacheDirectory(for: fingerprint)
            .appendingPathComponent(level.fileName)
            .standardizedFileURL
    }

    func loadManifest(for fingerprint: WaveformFileFingerprint) throws -> WaveformDiskCacheManifest? {
        let url = manifestURL(for: fingerprint)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let manifest = try decoder.decode(WaveformDiskCacheManifest.self, from: data)
        guard manifest.isValid(for: fingerprint) else {
            throw WaveformDiskCacheError.invalidManifest(manifest)
        }
        return manifest
    }

    func saveManifest(_ manifest: WaveformDiskCacheManifest) throws {
        let directory = cacheDirectory(for: manifest.fingerprint)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(for: manifest.fingerprint), options: [.atomic])
    }

    func savePeakLevel(_ result: WaveformPeakLevelBuildResult) throws -> WaveformDiskCacheManifest {
        let manifest = WaveformDiskCacheManifest(
            sourceID: result.sourceID,
            fingerprint: result.fingerprint,
            duration: result.fileInfo.duration,
            frameCount: Int64(result.fileInfo.frameCount),
            levels: [result.level]
        )
        let directory = cacheDirectory(for: result.fingerprint)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let tileData = WaveformPeakTileBinaryCodec.encode(result.tiles)
        try tileData.write(to: tileLevelURL(for: result.fingerprint, level: result.level), options: [.atomic])
        try saveManifest(manifest)
        return manifest
    }

    func loadPeakLevel(
        manifest: WaveformDiskCacheManifest,
        level: WaveformDiskCacheManifest.TileLevel
    ) throws -> [WaveformPeakTile] {
        guard manifest.levels.contains(level) else {
            return []
        }

        let data = try Data(contentsOf: tileLevelURL(for: manifest.fingerprint, level: level))
        return try WaveformPeakTileBinaryCodec.decode(
            data: data,
            level: level,
            sourceID: manifest.sourceID
        )
    }

    func removeCache(for fingerprint: WaveformFileFingerprint) throws {
        let directory = cacheDirectory(for: fingerprint)
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        try fileManager.removeItem(at: directory)
    }

    func makeEmptyManifest(
        for fingerprint: WaveformFileFingerprint,
        duration: TimeInterval,
        frameCount: Int64
    ) -> WaveformDiskCacheManifest {
        WaveformDiskCacheManifest(
            sourceID: WaveformSourceID(fingerprint: fingerprint),
            fingerprint: fingerprint,
            duration: duration,
            frameCount: frameCount
        )
    }
}
