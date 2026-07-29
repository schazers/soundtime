import Foundation

struct CachedAudioImport: Sendable {
    let manifest: AudioImportManifest
    let proxyURL: URL
    let proxyFileInfo: WAVFileInfo
    let waveformOverview: WaveformOverview
    let zeroCrossingIndex: AudioZeroCrossingIndex
}

struct AudioImportCacheTransaction: Sendable {
    let id: UUID
    let fingerprint: AudioImportFingerprint
    let directory: URL
    let stagedProxyURL: URL
}

final class AudioImportCacheStore: @unchecked Sendable {
    static let shared = AudioImportCacheStore()

    private static let maximumManifestBytes = 64 * 1_024
    private static let maximumWaveformSidecarBytes = 32 * 1_024 * 1_024
    private static let maximumZeroCrossingSidecarBytes = 8 * 1_024 * 1_024

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    init(
        rootDirectory: URL = AudioImportCacheStore.defaultRootDirectory(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
        encoder.outputFormatting = [.sortedKeys]
    }

    static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Soundtime", isDirectory: true)
            .appendingPathComponent("ImportedAudio", isDirectory: true)
            .standardizedFileURL
    }

    func cachedImport(
        for fingerprint: AudioImportFingerprint,
        sourceURL: URL
    ) -> CachedAudioImport? {
        guard fingerprint.isCurrent(for: sourceURL) else {
            return nil
        }

        lock.lock()
        defer {
            lock.unlock()
        }
        let cached = loadCachedImportUnlocked(for: fingerprint)
        if cached == nil {
            quarantineInvalidCacheUnlocked(at: cacheDirectory(for: fingerprint))
        }
        return cached
    }

    private func loadCachedImportUnlocked(
        for fingerprint: AudioImportFingerprint
    ) -> CachedAudioImport? {
        let directory = cacheDirectory(for: fingerprint)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let waveformURL = directory.appendingPathComponent("waveform.json")
        let zeroCrossingURL = directory.appendingPathComponent("zero-crossings.json")
        guard
            fileByteCount(manifestURL).map({ $0 <= Self.maximumManifestBytes }) == true,
            fileByteCount(waveformURL).map({ $0 <= Self.maximumWaveformSidecarBytes }) == true,
            let manifestData = try? Data(contentsOf: manifestURL),
            let manifest = try? decoder.decode(AudioImportManifest.self, from: manifestData),
            manifest.version == AudioImportManifest.currentVersion,
            manifest.fingerprint == fingerprint,
            isSafeCacheFileName(manifest.proxyFileName),
            let waveformData = try? Data(contentsOf: waveformURL),
            let waveform = try? decoder.decode(AudioImportWaveformSidecar.self, from: waveformData),
            waveform.duration.isFinite,
            waveform.duration >= 0,
            !waveform.bins.isEmpty
        else {
            return nil
        }

        let proxyURL = directory.appendingPathComponent(manifest.proxyFileName)
        guard
            fileManager.fileExists(atPath: proxyURL.path),
            let fileInfo = try? WAVAudioDecoder.inspect(url: proxyURL),
            fileInfo.frameCount == manifest.proxyFrameCount,
            abs(fileInfo.sampleRate - manifest.proxySampleRate) < 0.5,
            fileInfo.channelCount == manifest.channelCount,
            abs(fileInfo.duration - waveform.duration) <= max(0.01, 2 / fileInfo.sampleRate)
        else {
            return nil
        }

        let zeroCrossingIndex: AudioZeroCrossingIndex
        if
            fileByteCount(zeroCrossingURL).map({
                $0 <= Self.maximumZeroCrossingSidecarBytes
            }) == true,
            let zeroCrossingData = try? Data(contentsOf: zeroCrossingURL),
            let sidecar = try? decoder.decode(
                AudioImportZeroCrossingSidecar.self,
                from: zeroCrossingData
            ),
            sidecar.frameCount == fileInfo.frameCount,
            isValidZeroCrossingSidecar(sidecar)
        {
            zeroCrossingIndex = sidecar.zeroCrossingIndex
        } else {
            zeroCrossingIndex = AudioZeroCrossingIndex(
                frameCount: fileInfo.frameCount,
                crossings: []
            )
        }

        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: directory.path
        )
        return CachedAudioImport(
            manifest: manifest,
            proxyURL: proxyURL,
            proxyFileInfo: fileInfo,
            waveformOverview: waveform.waveformOverview,
            zeroCrossingIndex: zeroCrossingIndex
        )
    }

    func beginTransaction(
        for fingerprint: AudioImportFingerprint
    ) throws -> AudioImportCacheTransaction {
        lock.lock()
        defer {
            lock.unlock()
        }

        let transactionID = UUID()
        let directory = stagingDirectory()
            .appendingPathComponent(transactionID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return AudioImportCacheTransaction(
            id: transactionID,
            fingerprint: fingerprint,
            directory: directory,
            stagedProxyURL: directory.appendingPathComponent("editable.wav")
        )
    }

    func commit(
        _ transaction: AudioImportCacheTransaction,
        manifest: AudioImportManifest,
        waveformOverview: WaveformOverview,
        zeroCrossingIndex: AudioZeroCrossingIndex
    ) throws -> CachedAudioImport {
        let targetDirectory = cacheDirectory(for: transaction.fingerprint)
        let temporaryManifestURL = transaction.directory.appendingPathComponent("manifest.json")
        let temporaryWaveformURL = transaction.directory.appendingPathComponent("waveform.json")
        let temporaryZeroCrossingURL = transaction.directory
            .appendingPathComponent("zero-crossings.json")

        try encoder.encode(manifest).write(to: temporaryManifestURL, options: [.atomic])
        try encoder.encode(AudioImportWaveformSidecar(waveformOverview))
            .write(to: temporaryWaveformURL, options: [.atomic])
        try encoder.encode(AudioImportZeroCrossingSidecar(zeroCrossingIndex))
            .write(to: temporaryZeroCrossingURL, options: [.atomic])

        lock.lock()
        defer {
            lock.unlock()
        }

        try fileManager.createDirectory(
            at: targetDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: targetDirectory.path) {
            if let existing = loadCachedImportUnlocked(for: transaction.fingerprint) {
                try? fileManager.removeItem(at: transaction.directory)
                return existing
            }
            quarantineInvalidCacheUnlocked(at: targetDirectory)
            try fileManager.moveItem(at: transaction.directory, to: targetDirectory)
        } else {
            try fileManager.moveItem(at: transaction.directory, to: targetDirectory)
        }

        guard let committed = loadCachedImportUnlocked(for: transaction.fingerprint) else {
            quarantineInvalidCacheUnlocked(at: targetDirectory)
            throw AudioAssetImporter.ImportError.proxyDirectoryUnavailable
        }
        return committed
    }

    func cancel(_ transaction: AudioImportCacheTransaction) {
        lock.lock()
        defer {
            lock.unlock()
        }
        try? fileManager.removeItem(at: transaction.directory)
    }

    func removeCache(for fingerprint: AudioImportFingerprint) {
        lock.lock()
        defer {
            lock.unlock()
        }
        try? fileManager.removeItem(at: cacheDirectory(for: fingerprint))
    }

    func cleanStaleTransactions(olderThan age: TimeInterval = 24 * 60 * 60) {
        let directory = stagingDirectory()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            if values?.contentModificationDate.map({ $0 < cutoff }) != false {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private func cacheDirectory(for fingerprint: AudioImportFingerprint) -> URL {
        rootDirectory
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent(fingerprint.cacheKey, isDirectory: true)
    }

    private func stagingDirectory() -> URL {
        let directory = rootDirectory.appendingPathComponent("Staging", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func quarantineInvalidCacheUnlocked(at directory: URL) {
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        let quarantineRoot = rootDirectory.appendingPathComponent(
            "Quarantine",
            isDirectory: true
        )
        try? fileManager.createDirectory(
            at: quarantineRoot,
            withIntermediateDirectories: true
        )
        let destination = quarantineRoot.appendingPathComponent(
            "\(directory.lastPathComponent)-\(UUID().uuidString)",
            isDirectory: true
        )
        if (try? fileManager.moveItem(at: directory, to: destination)) == nil {
            try? fileManager.removeItem(at: directory)
        }
    }

    private func fileByteCount(_ url: URL) -> Int? {
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let byteCount = (attributes[.size] as? NSNumber)?.intValue
        else {
            return nil
        }
        return byteCount
    }

    private func isSafeCacheFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty &&
            fileName == URL(fileURLWithPath: fileName).lastPathComponent &&
            !fileName.contains("/") &&
            !fileName.contains("\\")
    }

    private func isValidZeroCrossingSidecar(
        _ sidecar: AudioImportZeroCrossingSidecar
    ) -> Bool {
        guard sidecar.frameCount >= 0 else {
            return false
        }
        var previous = -1
        for crossing in sidecar.crossings {
            guard
                crossing >= 0,
                crossing <= sidecar.frameCount,
                crossing >= previous
            else {
                return false
            }
            previous = crossing
        }
        return true
    }
}
