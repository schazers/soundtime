import CryptoKit
import Foundation

enum AudioImportStage: String, Codable, Sendable {
    case inspecting
    case admitted
    case previewing
    case previewReady
    case playbackReady
    case proxying
    case editableReady
    case complete
    case canceled
    case failed

    var isTerminal: Bool {
        self == .complete || self == .canceled || self == .failed
    }
}

struct AudioImportProgress: Sendable {
    let stage: AudioImportStage
    let completedFrames: Int64
    let totalFrames: Int64
    let message: String
    let previewOverview: WaveformOverview?

    init(
        stage: AudioImportStage,
        completedFrames: Int64,
        totalFrames: Int64,
        message: String,
        previewOverview: WaveformOverview? = nil
    ) {
        self.stage = stage
        self.completedFrames = completedFrames
        self.totalFrames = totalFrames
        self.message = message
        self.previewOverview = previewOverview
    }

    var fraction: Double {
        guard totalFrames > 0 else {
            return stage == .complete ? 1 : 0
        }
        return min(max(Double(completedFrames) / Double(totalFrames), 0), 1)
    }
}

struct AudioImportFingerprint: Hashable, Codable, Sendable {
    static let cacheFormatVersion = 3
    static let decoderIdentifier = "avfoundation-streaming-v2"

    let fileSize: Int64
    let modificationTime: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int64
    let sampledContentDigest: String
    let decoderIdentifier: String
    let cacheFormatVersion: Int

    init(url: URL, assetInfo: AudioAssetInfo) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        modificationTime = (attributes[.modificationDate] as? Date ?? .distantPast)
            .timeIntervalSinceReferenceDate
        sampleRate = assetInfo.sampleRate ?? 0
        channelCount = assetInfo.channelCount ?? 0
        frameCount = Int64(assetInfo.frameCount ?? 0)
        sampledContentDigest = try Self.sampledDigest(
            url: url,
            fileSize: fileSize
        )
        decoderIdentifier = Self.decoderIdentifier
        cacheFormatVersion = Self.cacheFormatVersion
    }

    var cacheKey: String {
        let components = [
            "\(fileSize)",
            String(format: "%.6f", modificationTime),
            String(format: "%.3f", sampleRate),
            "\(channelCount)",
            "\(frameCount)",
            sampledContentDigest,
            decoderIdentifier,
            "\(cacheFormatVersion)",
        ]
        let digest = SHA256.hash(data: Data(components.joined(separator: "\u{1f}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func isCurrent(for url: URL) -> Bool {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let currentSize = (attributes[.size] as? NSNumber)?.int64Value,
            let currentDate = attributes[.modificationDate] as? Date
        else {
            return false
        }

        return currentSize == fileSize &&
            abs(currentDate.timeIntervalSinceReferenceDate - modificationTime) < 0.001
    }

    private static func sampledDigest(url: URL, fileSize: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        let sampleLength = 64 * 1_024
        var hasher = SHA256()
        hasher.update(data: Data("\(fileSize)".utf8))
        hasher.update(data: try handle.read(upToCount: sampleLength) ?? Data())
        if fileSize > Int64(sampleLength) {
            try handle.seek(toOffset: UInt64(max(fileSize - Int64(sampleLength), 0)))
            hasher.update(data: try handle.read(upToCount: sampleLength) ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct AudioImportManifest: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let assetID: UUID
    let fingerprint: AudioImportFingerprint
    let originalPath: String
    let format: AudioAssetFormat
    let displayName: String
    let proxyFileName: String
    let sourceSampleRate: Double
    let sourceFrameCount: Int64
    let proxySampleRate: Double
    let proxyFrameCount: Int64
    let channelCount: Int
    let createdAt: Date

    init(
        assetID: UUID,
        fingerprint: AudioImportFingerprint,
        originalURL: URL,
        format: AudioAssetFormat,
        displayName: String,
        proxyFileName: String,
        sourceSampleRate: Double,
        sourceFrameCount: Int64,
        proxySampleRate: Double,
        proxyFrameCount: Int64,
        channelCount: Int
    ) {
        version = Self.currentVersion
        self.assetID = assetID
        self.fingerprint = fingerprint
        originalPath = originalURL.standardizedFileURL.path
        self.format = format
        self.displayName = displayName
        self.proxyFileName = proxyFileName
        self.sourceSampleRate = sourceSampleRate
        self.sourceFrameCount = sourceFrameCount
        self.proxySampleRate = proxySampleRate
        self.proxyFrameCount = proxyFrameCount
        self.channelCount = channelCount
        createdAt = Date()
    }
}

struct AudioImportWaveformSidecar: Codable, Sendable {
    struct Bin: Codable, Sendable {
        let minimumSample: Float
        let maximumSample: Float
        let rmsSample: Float
        let lowEnergy: Float
        let midEnergy: Float
        let highEnergy: Float

        init(_ bin: WaveformOverview.Bin) {
            minimumSample = bin.minimumSample
            maximumSample = bin.maximumSample
            rmsSample = bin.rmsSample
            lowEnergy = bin.lowEnergy
            midEnergy = bin.midEnergy
            highEnergy = bin.highEnergy
        }

        var waveformBin: WaveformOverview.Bin {
            WaveformOverview.Bin(
                minimumSample: minimumSample,
                maximumSample: maximumSample,
                rmsSample: rmsSample,
                lowEnergy: lowEnergy,
                midEnergy: midEnergy,
                highEnergy: highEnergy
            )
        }
    }

    let duration: TimeInterval
    let bins: [Bin]

    init(_ overview: WaveformOverview) {
        duration = overview.duration
        bins = overview.bins.map(Bin.init)
    }

    var waveformOverview: WaveformOverview {
        WaveformOverview(duration: duration, bins: bins.map(\.waveformBin))
    }
}

struct AudioImportZeroCrossingSidecar: Codable, Sendable {
    let frameCount: Int
    let crossings: [Int]

    init(_ index: AudioZeroCrossingIndex) {
        frameCount = index.frameCount
        crossings = index.persistedCrossings
    }

    var zeroCrossingIndex: AudioZeroCrossingIndex {
        AudioZeroCrossingIndex(frameCount: frameCount, crossings: crossings)
    }
}

struct AudioImportSessionSnapshot: Sendable {
    let id: UUID
    let assetID: UUID
    let sourceURL: URL
    let stage: AudioImportStage
    let progress: Double
    let message: String
}

enum AudioImportPerformanceContract {
    static let admittedMilliseconds = 50.0
    static let cachedPreviewMilliseconds = 100.0
    static let firstProgressiveWaveformMilliseconds = 250.0
    static let firstLargeCompressedWaveformMilliseconds = 300.0
    static let largeCompressedRefinedWaveformMilliseconds = 1_500.0
    static let coldScreenDetailMilliseconds = 2_000.0
    static let playbackReadyMilliseconds = 500.0
    static let maximumWorkingSetBytes = 32 * 1_024 * 1_024
}
