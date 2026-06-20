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

struct WaveformOverviewDiskCacheManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    struct Level: Codable, Equatable, Sendable {
        let targetBinCount: Int
        let actualBinCount: Int
        let samplesPerBin: Int
        let fileName: String

        init(
            targetBinCount: Int,
            actualBinCount: Int,
            samplesPerBin: Int,
            fileName: String
        ) {
            self.targetBinCount = max(1, targetBinCount)
            self.actualBinCount = max(0, actualBinCount)
            self.samplesPerBin = max(1, samplesPerBin)
            self.fileName = fileName
        }
    }

    let formatVersion: Int
    let sourceID: WaveformSourceID
    let fingerprint: WaveformFileFingerprint
    let duration: TimeInterval
    let frameCount: Int64
    let levels: [Level]

    init(
        sourceID: WaveformSourceID,
        fingerprint: WaveformFileFingerprint,
        duration: TimeInterval,
        frameCount: Int64,
        levels: [Level] = []
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

    func bestLevel(maximumBinCount: Int? = nil) -> Level? {
        levels
            .filter { level in
                level.actualBinCount > 0 &&
                    maximumBinCount.map { level.actualBinCount <= $0 } ?? true
            }
            .max { $0.actualBinCount < $1.actualBinCount }
    }
}

enum WaveformOverviewDiskCacheError: Error, LocalizedError {
    case invalidManifest(WaveformOverviewDiskCacheManifest)
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            return "The waveform overview cache manifest does not match the source file."
        case .invalidPayload:
            return "The waveform overview cache payload is invalid."
        }
    }
}

struct WaveformOverviewDiskCacheEntry: Sendable {
    let fileInfo: WAVFileInfo
    let fingerprint: WaveformFileFingerprint
    let level: WaveformOverviewDiskCacheManifest.Level
    let overview: WaveformOverview
}

struct EditedWaveformOverviewDiskCacheEntry: Sendable {
    let fileInfo: WAVFileInfo
    let sourceFingerprint: WaveformFileFingerprint
    let editFingerprint: WaveformEditFingerprint
    let overview: WaveformOverview
}

struct WaveformEditFingerprint: Hashable, Codable, Sendable {
    static let cacheFormatVersion = 1

    let sourceFingerprint: WaveformFileFingerprint
    let editStateHash: String
    let cacheFormatVersion: Int

    init?(
        sourceFingerprint: WaveformFileFingerprint,
        persistentState: AudioFileEditTimeline.PersistentState
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(persistentState) else {
            return nil
        }

        self.sourceFingerprint = sourceFingerprint
        self.editStateHash = Self.stableHexHash(data)
        self.cacheFormatVersion = Self.cacheFormatVersion
    }

    var cacheKey: String {
        Self.stableHexHash([
            sourceFingerprint.cacheKey,
            editStateHash,
            "\(cacheFormatVersion)",
        ])
    }

    private static func stableHexHash(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(format: "%016llx", hash)
    }

    private static func stableHexHash(_ components: [String]) -> String {
        stableHexHash(Data(components.joined(separator: "\u{1f}").utf8))
    }
}

private struct EditedWaveformOverviewDiskCacheManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let sourceFingerprint: WaveformFileFingerprint
    let editFingerprint: WaveformEditFingerprint
    let duration: TimeInterval
    let frameCount: Int64
    let binCount: Int
    let fileName: String

    init(
        sourceFingerprint: WaveformFileFingerprint,
        editFingerprint: WaveformEditFingerprint,
        duration: TimeInterval,
        frameCount: Int64,
        binCount: Int,
        fileName: String
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.sourceFingerprint = sourceFingerprint
        self.editFingerprint = editFingerprint
        self.duration = max(0, duration)
        self.frameCount = max(0, frameCount)
        self.binCount = max(0, binCount)
        self.fileName = fileName
    }

    func isValid(
        for expectedSourceFingerprint: WaveformFileFingerprint,
        editFingerprint expectedEditFingerprint: WaveformEditFingerprint
    ) -> Bool {
        formatVersion == Self.currentFormatVersion &&
            sourceFingerprint == expectedSourceFingerprint &&
            editFingerprint == expectedEditFingerprint &&
            editFingerprint.sourceFingerprint == expectedSourceFingerprint
    }
}

final class WaveformOverviewDiskCacheStore: @unchecked Sendable {
    static let maximumCachedBinCount = 262_144

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

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

    func cacheDirectory(for fingerprint: WaveformFileFingerprint) -> URL {
        rootDirectory
            .appendingPathComponent(fingerprint.cacheKey, isDirectory: true)
            .appendingPathComponent("overviews", isDirectory: true)
            .standardizedFileURL
    }

    func manifestURL(for fingerprint: WaveformFileFingerprint) -> URL {
        cacheDirectory(for: fingerprint)
            .appendingPathComponent("manifest")
            .appendingPathExtension("json")
    }

    func overviewLevelURL(
        for fingerprint: WaveformFileFingerprint,
        level: WaveformOverviewDiskCacheManifest.Level
    ) -> URL {
        cacheDirectory(for: fingerprint)
            .appendingPathComponent(level.fileName)
            .standardizedFileURL
    }

    func editedCacheDirectory(
        for sourceFingerprint: WaveformFileFingerprint,
        editFingerprint: WaveformEditFingerprint
    ) -> URL {
        cacheDirectory(for: sourceFingerprint)
            .appendingPathComponent("edited", isDirectory: true)
            .appendingPathComponent(editFingerprint.cacheKey, isDirectory: true)
            .standardizedFileURL
    }

    private func editedManifestURL(
        for sourceFingerprint: WaveformFileFingerprint,
        editFingerprint: WaveformEditFingerprint
    ) -> URL {
        editedCacheDirectory(
            for: sourceFingerprint,
            editFingerprint: editFingerprint
        )
        .appendingPathComponent("manifest")
        .appendingPathExtension("json")
    }

    private func editedOverviewURL(
        for sourceFingerprint: WaveformFileFingerprint,
        editFingerprint: WaveformEditFingerprint,
        manifest: EditedWaveformOverviewDiskCacheManifest
    ) -> URL {
        editedCacheDirectory(
            for: sourceFingerprint,
            editFingerprint: editFingerprint
        )
        .appendingPathComponent(manifest.fileName)
        .standardizedFileURL
    }

    func loadBestOverview(
        for url: URL,
        fileInfo: WAVFileInfo,
        maximumBinCount: Int? = maximumCachedBinCount
    ) throws -> WaveformOverviewDiskCacheEntry? {
        let fingerprint = try WaveformFileFingerprint(url: url, wavFileInfo: fileInfo)
        lock.lock()
        defer {
            lock.unlock()
        }

        guard
            let manifest = try loadManifestLocked(for: fingerprint),
            let level = manifest.bestLevel(maximumBinCount: maximumBinCount)
        else {
            return nil
        }

        let overview = try loadOverviewLocked(
            manifest: manifest,
            level: level
        )
        return WaveformOverviewDiskCacheEntry(
            fileInfo: fileInfo,
            fingerprint: fingerprint,
            level: level,
            overview: overview
        )
    }

    func loadEditedOverview(
        for url: URL,
        fileInfo: WAVFileInfo,
        editTimeline: AudioFileEditTimeline
    ) throws -> EditedWaveformOverviewDiskCacheEntry? {
        guard
            let persistentState = editTimeline.persistentState,
            editTimeline.hasEdits
        else {
            return nil
        }

        let sourceFingerprint = try WaveformFileFingerprint(url: url, wavFileInfo: fileInfo)
        guard let editFingerprint = WaveformEditFingerprint(
            sourceFingerprint: sourceFingerprint,
            persistentState: persistentState
        ) else {
            return nil
        }

        lock.lock()
        defer {
            lock.unlock()
        }

        let manifestURL = editedManifestURL(
            for: sourceFingerprint,
            editFingerprint: editFingerprint
        )
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try decoder.decode(EditedWaveformOverviewDiskCacheManifest.self, from: data)
        guard manifest.isValid(
            for: sourceFingerprint,
            editFingerprint: editFingerprint
        ) else {
            throw WaveformOverviewDiskCacheError.invalidPayload
        }

        let overviewData = try Data(contentsOf: editedOverviewURL(
            for: sourceFingerprint,
            editFingerprint: editFingerprint,
            manifest: manifest
        ))
        let overview = try WaveformOverviewBinaryCodec.decode(
            overviewData,
            duration: manifest.duration,
            expectedBinCount: manifest.binCount
        )
        return EditedWaveformOverviewDiskCacheEntry(
            fileInfo: fileInfo,
            sourceFingerprint: sourceFingerprint,
            editFingerprint: editFingerprint,
            overview: overview
        )
    }

    @discardableResult
    func saveOverview(
        _ overview: WaveformOverview,
        targetBinCount: Int,
        samplesPerBin: Int,
        fileInfo: WAVFileInfo
    ) throws -> WaveformOverviewDiskCacheManifest? {
        guard
            !overview.isEmpty,
            overview.bins.count <= Self.maximumCachedBinCount
        else {
            return nil
        }

        let fingerprint = try WaveformFileFingerprint(url: fileInfo.url, wavFileInfo: fileInfo)
        let level = WaveformOverviewDiskCacheManifest.Level(
            targetBinCount: targetBinCount,
            actualBinCount: overview.bins.count,
            samplesPerBin: samplesPerBin,
            fileName: "overview-\(targetBinCount)-\(overview.bins.count).bin"
        )

        lock.lock()
        defer {
            lock.unlock()
        }

        let directory = cacheDirectory(for: fingerprint)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let payload = WaveformOverviewBinaryCodec.encode(overview)
        try payload.write(to: overviewLevelURL(for: fingerprint, level: level), options: [.atomic])

        let existingLevels = (try? loadManifestLocked(for: fingerprint))?.levels ?? []
        let mergedLevels = (existingLevels.filter {
            $0.targetBinCount != level.targetBinCount &&
                $0.actualBinCount != level.actualBinCount
        } + [level])
            .sorted { $0.actualBinCount < $1.actualBinCount }
        let manifest = WaveformOverviewDiskCacheManifest(
            sourceID: WaveformSourceID(fingerprint: fingerprint),
            fingerprint: fingerprint,
            duration: fileInfo.duration,
            frameCount: Int64(fileInfo.frameCount),
            levels: mergedLevels
        )
        try saveManifestLocked(manifest)
        return manifest
    }

    func saveEditedOverview(
        _ overview: WaveformOverview,
        fileInfo: WAVFileInfo,
        editTimeline: AudioFileEditTimeline
    ) throws {
        guard
            !overview.isEmpty,
            editTimeline.hasEdits,
            let persistentState = editTimeline.persistentState
        else {
            return
        }

        let sourceFingerprint = try WaveformFileFingerprint(url: fileInfo.url, wavFileInfo: fileInfo)
        guard let editFingerprint = WaveformEditFingerprint(
            sourceFingerprint: sourceFingerprint,
            persistentState: persistentState
        ) else {
            return
        }

        lock.lock()
        defer {
            lock.unlock()
        }

        let directory = editedCacheDirectory(
            for: sourceFingerprint,
            editFingerprint: editFingerprint
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let manifest = EditedWaveformOverviewDiskCacheManifest(
            sourceFingerprint: sourceFingerprint,
            editFingerprint: editFingerprint,
            duration: overview.duration,
            frameCount: Int64(editTimeline.frameCount),
            binCount: overview.bins.count,
            fileName: "overview.bin"
        )
        try WaveformOverviewBinaryCodec.encode(overview).write(
            to: editedOverviewURL(
                for: sourceFingerprint,
                editFingerprint: editFingerprint,
                manifest: manifest
            ),
            options: [.atomic]
        )
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(
            to: editedManifestURL(
                for: sourceFingerprint,
                editFingerprint: editFingerprint
            ),
            options: [.atomic]
        )
    }

    func removeCache(for fingerprint: WaveformFileFingerprint) throws {
        lock.lock()
        defer {
            lock.unlock()
        }

        let directory = cacheDirectory(for: fingerprint)
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        try fileManager.removeItem(at: directory)
    }

    private func loadManifestLocked(
        for fingerprint: WaveformFileFingerprint
    ) throws -> WaveformOverviewDiskCacheManifest? {
        let url = manifestURL(for: fingerprint)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let manifest = try decoder.decode(WaveformOverviewDiskCacheManifest.self, from: data)
        guard manifest.isValid(for: fingerprint) else {
            throw WaveformOverviewDiskCacheError.invalidManifest(manifest)
        }
        return manifest
    }

    private func saveManifestLocked(_ manifest: WaveformOverviewDiskCacheManifest) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(for: manifest.fingerprint), options: [.atomic])
    }

    private func loadOverviewLocked(
        manifest: WaveformOverviewDiskCacheManifest,
        level: WaveformOverviewDiskCacheManifest.Level
    ) throws -> WaveformOverview {
        guard manifest.levels.contains(level) else {
            throw WaveformOverviewDiskCacheError.invalidPayload
        }

        let data = try Data(contentsOf: overviewLevelURL(for: manifest.fingerprint, level: level))
        return try WaveformOverviewBinaryCodec.decode(
            data,
            duration: manifest.duration,
            expectedBinCount: level.actualBinCount
        )
    }
}

private enum WaveformOverviewBinaryCodec {
    static func encode(_ overview: WaveformOverview) -> Data {
        var data = Data()
        data.reserveCapacity(overview.bins.count * 6 * MemoryLayout<UInt32>.size)
        for bin in overview.bins {
            appendFloat(bin.minimumSample, to: &data)
            appendFloat(bin.maximumSample, to: &data)
            appendFloat(bin.rmsSample, to: &data)
            appendFloat(bin.lowEnergy, to: &data)
            appendFloat(bin.midEnergy, to: &data)
            appendFloat(bin.highEnergy, to: &data)
        }
        return data
    }

    static func decode(
        _ data: Data,
        duration: TimeInterval,
        expectedBinCount: Int
    ) throws -> WaveformOverview {
        let floatsPerBin = 6
        let bytesPerFloat = MemoryLayout<UInt32>.size
        let expectedByteCount = max(expectedBinCount, 0) * floatsPerBin * bytesPerFloat
        guard data.count == expectedByteCount else {
            throw WaveformOverviewDiskCacheError.invalidPayload
        }

        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(expectedBinCount)
        var offset = 0
        for _ in 0..<expectedBinCount {
            let minimumSample = try readFloat(from: data, offset: &offset)
            let maximumSample = try readFloat(from: data, offset: &offset)
            let rmsSample = try readFloat(from: data, offset: &offset)
            let lowEnergy = try readFloat(from: data, offset: &offset)
            let midEnergy = try readFloat(from: data, offset: &offset)
            let highEnergy = try readFloat(from: data, offset: &offset)
            bins.append(WaveformOverview.Bin(
                minimumSample: minimumSample,
                maximumSample: maximumSample,
                rmsSample: rmsSample,
                lowEnergy: lowEnergy,
                midEnergy: midEnergy,
                highEnergy: highEnergy
            ))
        }

        return WaveformOverview(duration: duration, bins: bins)
    }

    private static func appendFloat(_ value: Float, to data: inout Data) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func readFloat(from data: Data, offset: inout Int) throws -> Float {
        guard offset + 4 <= data.count else {
            throw WaveformOverviewDiskCacheError.invalidPayload
        }

        var bits: UInt32 = 0
        bits |= UInt32(data[offset])
        bits |= UInt32(data[offset + 1]) << 8
        bits |= UInt32(data[offset + 2]) << 16
        bits |= UInt32(data[offset + 3]) << 24
        offset += 4
        return Float(bitPattern: bits)
    }
}
