import Foundation

struct WaveformTileBuildSource: Sendable {
    let url: URL
    let fingerprint: WaveformFileFingerprint
    let sourceID: WaveformSourceID
    let duration: TimeInterval
    let frameCount: Int64
    let sampleRate: Double
    let channelMode: WaveformChannelMode

    init(
        url: URL,
        fingerprint: WaveformFileFingerprint,
        duration: TimeInterval,
        frameCount: Int64,
        sampleRate: Double,
        channelMode: WaveformChannelMode
    ) {
        self.url = url.standardizedFileURL
        self.fingerprint = fingerprint
        self.sourceID = WaveformSourceID(fingerprint: fingerprint)
        self.duration = max(0, duration)
        self.frameCount = max(0, frameCount)
        self.sampleRate = max(1, sampleRate)
        self.channelMode = channelMode
    }

    init(wavURL: URL, channelMode: WaveformChannelMode = .monoMix) throws {
        let fileInfo = try WAVAudioDecoder.inspect(url: wavURL)
        let fingerprint = try WaveformFileFingerprint(url: wavURL, wavFileInfo: fileInfo)
        self.init(
            url: wavURL,
            fingerprint: fingerprint,
            duration: fileInfo.duration,
            frameCount: Int64(fileInfo.frameCount),
            sampleRate: fileInfo.sampleRate,
            channelMode: channelMode
        )
    }

    var metadata: WaveformTileSourceMetadata {
        WaveformTileSourceMetadata(
            sourceID: sourceID,
            duration: duration,
            frameCount: frameCount,
            sampleRate: sampleRate,
            channelMode: channelMode
        )
    }
}

struct WaveformTileBuildWorkerBatchSummary: Equatable, Sendable {
    var dequeuedCount = 0
    var diskHitCount = 0
    var builtLevelCount = 0
    var builtRawTileCount = 0
    var alreadyAvailableCount = 0
    var committedCount = 0
    var staleCount = 0
    var failedCount = 0

    var resolvedCount: Int {
        diskHitCount + builtLevelCount + builtRawTileCount + alreadyAvailableCount
    }
}

final class WaveformTileBuildWorker: @unchecked Sendable {
    private let requestQueue: WaveformTileRequestQueue
    private let tileStore: WaveformTileStore
    private let diskCacheStore: WaveformDiskCacheStore
    private let lock = NSLock()
    private var sourcesByID: [WaveformSourceID: WaveformTileBuildSource] = [:]

    init(
        requestQueue: WaveformTileRequestQueue,
        tileStore: WaveformTileStore,
        diskCacheStore: WaveformDiskCacheStore = WaveformDiskCacheStore()
    ) {
        self.requestQueue = requestQueue
        self.tileStore = tileStore
        self.diskCacheStore = diskCacheStore
    }

    func registerSource(_ source: WaveformTileBuildSource) {
        lock.lock()
        sourcesByID[source.sourceID] = source
        lock.unlock()
    }

    func unregisterSource(_ sourceID: WaveformSourceID) {
        lock.lock()
        sourcesByID.removeValue(forKey: sourceID)
        lock.unlock()
        requestQueue.removeAll(for: sourceID)
    }

    @discardableResult
    func processNextBatch(
        maxCount: Int,
        beforeCommit: ((WaveformTileWorkItem) -> Void)? = nil
    ) -> WaveformTileBuildWorkerBatchSummary {
        let workItems = requestQueue.dequeue(maxCount: maxCount)
        var summary = WaveformTileBuildWorkerBatchSummary(dequeuedCount: workItems.count)

        for workItem in workItems {
            process(workItem, beforeCommit: beforeCommit, summary: &summary)
        }

        return summary
    }

    private func process(
        _ workItem: WaveformTileWorkItem,
        beforeCommit: ((WaveformTileWorkItem) -> Void)?,
        summary: inout WaveformTileBuildWorkerBatchSummary
    ) {
        let descriptor = workItem.request.descriptor
        let address = descriptor.address

        guard requestQueue.isCurrent(workItem) else {
            summary.staleCount += 1
            return
        }

        guard tileStore.payload(for: address) == nil else {
            beforeCommit?(workItem)
            if requestQueue.complete(workItem) {
                summary.alreadyAvailableCount += 1
                summary.committedCount += 1
            } else {
                summary.staleCount += 1
            }
            return
        }

        guard let source = source(for: address.sourceID) else {
            if requestQueue.fail(workItem, message: "No registered waveform tile source for \(address.sourceID.rawValue)") {
                summary.failedCount += 1
            } else {
                summary.staleCount += 1
            }
            return
        }

        do {
            let payload: WaveformTilePayload
            switch address.kind {
            case .peak:
                let resolvedTile: WaveformPeakTile
                if let diskTile = try peakTileFromDisk(source: source, descriptor: descriptor) {
                    resolvedTile = diskTile
                    summary.diskHitCount += 1
                } else {
                    resolvedTile = try buildPeakLevelAndReturnRequestedTile(source: source, descriptor: descriptor)
                    summary.builtLevelCount += 1
                }
                payload = .peak(resolvedTile)
            case .rawSamples:
                let resolvedTile = try WaveformRawSampleTileBuilder.buildWAVRawSampleTile(
                    url: source.url,
                    descriptor: descriptor,
                    channelMode: descriptor.address.channelMode,
                    shouldYieldForPlayback: true
                )
                payload = .rawSamples(resolvedTile)
                summary.builtRawTileCount += 1
            }

            beforeCommit?(workItem)
            if requestQueue.complete(workItem) {
                tileStore.commit(payload)
                summary.committedCount += 1
            } else {
                summary.staleCount += 1
            }
        } catch {
            if requestQueue.fail(workItem, message: String(describing: error)) {
                summary.failedCount += 1
            } else {
                summary.staleCount += 1
            }
        }
    }

    private func source(for sourceID: WaveformSourceID) -> WaveformTileBuildSource? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return sourcesByID[sourceID]
    }

    private func peakTileFromDisk(
        source: WaveformTileBuildSource,
        descriptor: WaveformTileDescriptor
    ) throws -> WaveformPeakTile? {
        guard let manifest = try diskCacheStore.loadManifest(for: source.fingerprint),
              let level = manifest.levels.first(where: { level in
                  level.kind == descriptor.address.kind &&
                      level.channelMode == descriptor.address.channelMode &&
                      level.level == descriptor.address.level &&
                      level.framesPerBin == descriptor.framesPerBin &&
                      level.framesPerTile == inferredFramesPerTile(from: descriptor)
              })
        else {
            return nil
        }

        return try diskCacheStore
            .loadPeakLevel(manifest: manifest, level: level)
            .first { tile in
                tile.descriptor.address == descriptor.address
            }
    }

    private func buildPeakLevelAndReturnRequestedTile(
        source: WaveformTileBuildSource,
        descriptor: WaveformTileDescriptor
    ) throws -> WaveformPeakTile {
        let framesPerTile = inferredFramesPerTile(from: descriptor)
        let result = try WaveformPeakTileBuilder.buildWAVPeakLevel(
            url: source.url,
            framesPerBin: descriptor.framesPerBin,
            framesPerTile: framesPerTile,
            level: descriptor.address.level,
            channelMode: descriptor.address.channelMode,
            shouldYieldForPlayback: true
        )
        _ = try diskCacheStore.savePeakLevel(result)

        if let tile = result.tiles.first(where: { tile in
            tile.descriptor.address == descriptor.address
        }) {
            return tile
        }

        throw WaveformTileBuildWorkerError.builtLevelMissingRequestedTile(descriptor.address)
    }

    private func inferredFramesPerTile(from descriptor: WaveformTileDescriptor) -> Int64 {
        let tileIndex = max(0, descriptor.address.tileIndex)
        if tileIndex > 0 {
            return max(1, descriptor.frameRange.startFrame / Int64(tileIndex))
        }
        return max(1, descriptor.frameRange.frameCount)
    }
}

enum WaveformTileBuildWorkerError: Error, CustomStringConvertible {
    case builtLevelMissingRequestedTile(WaveformTileAddress)

    var description: String {
        switch self {
        case let .builtLevelMissingRequestedTile(address):
            return "Built peak level did not contain requested tile \(address)."
        }
    }
}
