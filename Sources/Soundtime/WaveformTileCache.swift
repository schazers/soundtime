import Foundation

struct WaveformSourceID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(fingerprint: WaveformFileFingerprint) {
        self.rawValue = "file-\(fingerprint.cacheKey)"
    }

    var description: String {
        rawValue
    }
}

struct WaveformFileFingerprint: Hashable, Codable, Sendable {
    static let cacheFormatVersion = 1

    let canonicalPath: String
    let fileSize: Int64
    let modificationTime: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let decoderIdentifier: String
    let cacheFormatVersion: Int

    init(
        url: URL,
        fileSize: Int64,
        modificationDate: Date,
        sampleRate: Double,
        channelCount: Int,
        decoderIdentifier: String = "wav-pcm"
    ) {
        self.canonicalPath = url.standardizedFileURL.path
        self.fileSize = fileSize
        self.modificationTime = modificationDate.timeIntervalSinceReferenceDate
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.decoderIdentifier = decoderIdentifier
        self.cacheFormatVersion = Self.cacheFormatVersion
    }

    init(url: URL, wavFileInfo: WAVFileInfo) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
        self.init(
            url: url,
            fileSize: fileSize,
            modificationDate: modificationDate,
            sampleRate: wavFileInfo.sampleRate,
            channelCount: wavFileInfo.channelCount,
            decoderIdentifier: "wav-\(wavFileInfo.formatTag)-\(wavFileInfo.bitsPerSample)-bit"
        )
    }

    var cacheKey: String {
        Self.stableHexHash([
            canonicalPath,
            "\(fileSize)",
            String(format: "%.6f", modificationTime),
            String(format: "%.3f", sampleRate),
            "\(channelCount)",
            decoderIdentifier,
            "\(cacheFormatVersion)",
        ])
    }

    private static func stableHexHash(_ components: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in components.joined(separator: "\u{1f}").utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(format: "%016llx", hash)
    }
}

enum WaveformTileKind: String, Codable, Sendable {
    case peak
    case rawSamples
}

enum WaveformChannelMode: String, Codable, Sendable {
    case monoMix
    case left
    case right
    case stereoPair
}

struct WaveformFrameRange: Hashable, Codable, Sendable {
    let startFrame: Int64
    let endFrame: Int64

    init(startFrame: Int64, endFrame: Int64) {
        self.startFrame = max(0, startFrame)
        self.endFrame = max(self.startFrame, endFrame)
    }

    var frameCount: Int64 {
        endFrame - startFrame
    }

    var isEmpty: Bool {
        frameCount == 0
    }

    func contains(frame: Int64) -> Bool {
        frame >= startFrame && frame < endFrame
    }

    func intersects(_ other: WaveformFrameRange) -> Bool {
        startFrame < other.endFrame && other.startFrame < endFrame
    }
}

struct WaveformTileAddress: Hashable, Codable, Sendable, Comparable {
    let sourceID: WaveformSourceID
    let editGraphID: String?
    let kind: WaveformTileKind
    let channelMode: WaveformChannelMode
    let level: Int
    let tileIndex: Int

    init(
        sourceID: WaveformSourceID,
        editGraphID: String? = nil,
        kind: WaveformTileKind,
        channelMode: WaveformChannelMode,
        level: Int,
        tileIndex: Int
    ) {
        self.sourceID = sourceID
        self.editGraphID = editGraphID
        self.kind = kind
        self.channelMode = channelMode
        self.level = max(0, level)
        self.tileIndex = max(0, tileIndex)
    }

    static func < (lhs: WaveformTileAddress, rhs: WaveformTileAddress) -> Bool {
        (
            lhs.sourceID.rawValue,
            lhs.editGraphID ?? "",
            lhs.kind.rawValue,
            lhs.channelMode.rawValue,
            lhs.level,
            lhs.tileIndex
        ) < (
            rhs.sourceID.rawValue,
            rhs.editGraphID ?? "",
            rhs.kind.rawValue,
            rhs.channelMode.rawValue,
            rhs.level,
            rhs.tileIndex
        )
    }
}

struct WaveformTileDescriptor: Hashable, Codable, Sendable {
    let address: WaveformTileAddress
    let frameRange: WaveformFrameRange
    let framesPerBin: Int
    let expectedBinCount: Int

    init(
        address: WaveformTileAddress,
        frameRange: WaveformFrameRange,
        framesPerBin: Int,
        expectedBinCount: Int
    ) {
        self.address = address
        self.frameRange = frameRange
        self.framesPerBin = max(1, framesPerBin)
        self.expectedBinCount = max(0, expectedBinCount)
    }
}

struct WaveformPeakTile: Sendable {
    let descriptor: WaveformTileDescriptor
    let bins: [WaveformOverview.Bin]

    init(descriptor: WaveformTileDescriptor, bins: [WaveformOverview.Bin]) {
        self.descriptor = descriptor
        self.bins = bins
    }
}

struct WaveformRawSampleTile: Sendable {
    let descriptor: WaveformTileDescriptor
    let samplesByChannel: [[Float]]

    init(descriptor: WaveformTileDescriptor, samplesByChannel: [[Float]]) {
        self.descriptor = descriptor
        self.samplesByChannel = samplesByChannel
    }
}

enum WaveformTilePayload: Sendable {
    case peak(WaveformPeakTile)
    case rawSamples(WaveformRawSampleTile)

    var descriptor: WaveformTileDescriptor {
        switch self {
        case let .peak(tile):
            return tile.descriptor
        case let .rawSamples(tile):
            return tile.descriptor
        }
    }
}

enum WaveformTileState: Equatable, Sendable {
    case missing
    case building
    case committedCPU
    case residentGPU
    case failed(String)
}

final class WaveformTileStore: @unchecked Sendable {
    private struct Record {
        var descriptor: WaveformTileDescriptor
        var state: WaveformTileState
        var payload: WaveformTilePayload?
    }

    private let lock = NSLock()
    private var records: [WaveformTileAddress: Record] = [:]

    func state(for address: WaveformTileAddress) -> WaveformTileState {
        lock.lock()
        defer {
            lock.unlock()
        }
        return records[address]?.state ?? .missing
    }

    func markBuilding(_ descriptor: WaveformTileDescriptor) {
        lock.lock()
        records[descriptor.address] = Record(
            descriptor: descriptor,
            state: .building,
            payload: nil
        )
        lock.unlock()
    }

    func commit(_ payload: WaveformTilePayload) {
        let descriptor = payload.descriptor
        lock.lock()
        records[descriptor.address] = Record(
            descriptor: descriptor,
            state: .committedCPU,
            payload: payload
        )
        lock.unlock()
    }

    func markGPUResident(_ address: WaveformTileAddress) {
        lock.lock()
        if var record = records[address], record.payload != nil {
            record.state = .residentGPU
            records[address] = record
        }
        lock.unlock()
    }

    func markGPUEvicted(_ address: WaveformTileAddress) {
        lock.lock()
        if var record = records[address], record.payload != nil {
            record.state = .committedCPU
            records[address] = record
        }
        lock.unlock()
    }

    func markFailed(_ address: WaveformTileAddress, message: String) {
        lock.lock()
        if var record = records[address] {
            record.state = .failed(message)
            records[address] = record
        }
        lock.unlock()
    }

    func payload(for address: WaveformTileAddress) -> WaveformTilePayload? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return records[address]?.payload
    }

    func committedPeakTile(for address: WaveformTileAddress) -> WaveformPeakTile? {
        guard let payload = payload(for: address) else {
            return nil
        }

        if case let .peak(tile) = payload {
            return tile
        }

        return nil
    }

    func committedAddresses(for sourceID: WaveformSourceID? = nil) -> [WaveformTileAddress] {
        lock.lock()
        defer {
            lock.unlock()
        }

        return records.compactMap { address, record in
            guard record.payload != nil else {
                return nil
            }
            if let sourceID, address.sourceID != sourceID {
                return nil
            }
            return address
        }
        .sorted()
    }

    func removeAll(for sourceID: WaveformSourceID) {
        lock.lock()
        records = records.filter { address, _ in
            address.sourceID != sourceID
        }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        records.removeAll()
        lock.unlock()
    }
}
