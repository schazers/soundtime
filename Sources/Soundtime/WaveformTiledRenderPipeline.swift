import Foundation

enum WaveformTiledRendererFeatureFlags {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SOUNDTIME_TILED_WAVEFORM_RENDERER"] == "1"
    }
}

struct WaveformTiledRenderFrame: Sendable {
    let requestedTiles: [WaveformTileRequest]
    let buildSummary: WaveformTileBuildWorkerBatchSummary
    let uploadSummary: WaveformTileUploadBatchSummary
    let renderSelection: WaveformTileRenderSelection
    let promotionPlan: WaveformTilePromotionPlan
    let residencySnapshot: WaveformTileGPUResidencySnapshot
}

final class WaveformTiledRenderPipeline: @unchecked Sendable {
    private let requestQueue: WaveformTileRequestQueue
    private let tileStore: WaveformTileStore
    private let residencyStore: WaveformTileGPUResidencyStore
    private let buildWorker: WaveformTileBuildWorker
    private let uploadCoordinator: WaveformTileUploadCoordinator
    private let renderSelector: WaveformTileRenderSelector
    private let promotionPlanner: WaveformTilePromotionPlanner
    private let lock = NSLock()
    private var registeredSourceIDs = Set<WaveformSourceID>()

    init(
        diskCacheStore: WaveformDiskCacheStore = WaveformDiskCacheStore(),
        maximumResidentBytes: Int = 128 * 1_024 * 1_024,
        promotionConfig: WaveformTilePromotionConfig = WaveformTilePromotionConfig()
    ) {
        let requestQueue = WaveformTileRequestQueue()
        let tileStore = WaveformTileStore()
        let residencyStore = WaveformTileGPUResidencyStore(maximumResidentBytes: maximumResidentBytes)
        self.requestQueue = requestQueue
        self.tileStore = tileStore
        self.residencyStore = residencyStore
        self.buildWorker = WaveformTileBuildWorker(
            requestQueue: requestQueue,
            tileStore: tileStore,
            diskCacheStore: diskCacheStore
        )
        self.uploadCoordinator = WaveformTileUploadCoordinator(
            tileStore: tileStore,
            residencyStore: residencyStore
        )
        self.renderSelector = WaveformTileRenderSelector(
            tileStore: tileStore,
            residencyStore: residencyStore
        )
        self.promotionPlanner = WaveformTilePromotionPlanner(config: promotionConfig)
    }

    func registerSources(_ sources: [WaveformTileBuildSource]) {
        let nextSourceIDs = Set(sources.map(\.sourceID))
        lock.lock()
        let staleSourceIDs = registeredSourceIDs.subtracting(nextSourceIDs)
        registeredSourceIDs = nextSourceIDs
        lock.unlock()

        for source in sources {
            buildWorker.registerSource(source)
        }
        for sourceID in staleSourceIDs {
            buildWorker.unregisterSource(sourceID)
            uploadCoordinator.removeAll(for: sourceID)
            tileStore.removeAll(for: sourceID)
            renderSelector.removeAll(for: sourceID)
            promotionPlanner.removeAll(for: sourceID)
        }
    }

    func prepareFrame(
        source: WaveformTileSourceMetadata,
        viewport: WaveformTileSchedulerViewport,
        predictedViewport: WaveformTileSchedulerViewport? = nil,
        timestamp: TimeInterval,
        schedulerConfig: WaveformTileSchedulerConfig = WaveformTileSchedulerConfig(),
        buildBatchLimit: Int = 8,
        uploadBudget: WaveformTileUploadBudget = WaveformTileUploadBudget(
            maximumBytesPerBatch: 2 * 1_024 * 1_024,
            maximumTilesPerBatch: 12
        ),
        upload: WaveformTileUploadCoordinator.UploadHandler
    ) -> WaveformTiledRenderFrame {
        let requests = WaveformTileScheduler.requests(
            for: source,
            viewport: viewport,
            predictedViewport: predictedViewport,
            config: schedulerConfig
        )
        requestQueue.enqueue(requests)
        let buildSummary = buildWorker.processNextBatch(maxCount: buildBatchLimit)

        let uploadAddresses = prioritizedUploadAddresses(
            requestedAddresses: requests.map(\.descriptor.address),
            sourceID: source.sourceID
        )
        let uploadSummary = uploadCoordinator.uploadNextBatch(
            prioritizedAddresses: uploadAddresses,
            budget: uploadBudget,
            upload: upload
        )
        let renderSelection = renderSelector.selectRenderableTiles(for: requests)
        let promotionPlan = promotionPlanner.plan(
            selection: renderSelection,
            timestamp: timestamp
        )

        return WaveformTiledRenderFrame(
            requestedTiles: requests,
            buildSummary: buildSummary,
            uploadSummary: uploadSummary,
            renderSelection: renderSelection,
            promotionPlan: promotionPlan,
            residencySnapshot: residencyStore.snapshot()
        )
    }

    func removeAll() {
        lock.lock()
        let sourceIDs = registeredSourceIDs
        registeredSourceIDs.removeAll()
        lock.unlock()

        for sourceID in sourceIDs {
            buildWorker.unregisterSource(sourceID)
            uploadCoordinator.removeAll(for: sourceID)
            tileStore.removeAll(for: sourceID)
            renderSelector.removeAll(for: sourceID)
            promotionPlanner.removeAll(for: sourceID)
        }
        tileStore.removeAll()
        renderSelector.removeAll()
        promotionPlanner.removeAll()
    }

    private func prioritizedUploadAddresses(
        requestedAddresses: [WaveformTileAddress],
        sourceID: WaveformSourceID
    ) -> [WaveformTileAddress] {
        var seenAddresses = Set<WaveformTileAddress>()
        var addresses: [WaveformTileAddress] = []
        for address in requestedAddresses where seenAddresses.insert(address).inserted {
            addresses.append(address)
        }
        for address in tileStore.committedAddresses(for: sourceID) where seenAddresses.insert(address).inserted {
            addresses.append(address)
        }
        return addresses
    }
}
