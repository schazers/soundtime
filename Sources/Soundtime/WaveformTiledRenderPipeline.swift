import Foundation

enum WaveformGPUResidentWaveformsFeatureFlags {
    private static let environmentKey = "SOUNDTIME_GPU_RESIDENT_WAVEFORMS"

    static var isEnabled: Bool {
        environmentFlagIsTruthy(ProcessInfo.processInfo.environment[environmentKey])
    }

    static var isShadowModeEnabled: Bool {
        isEnabled
    }

    static var modeDescription: String {
        if isShadowModeEnabled {
            return "gpu-resident-shadow"
        }
        if WaveformTiledRendererFeatureFlags.isLegacyEnabled {
            return "tiled-legacy"
        }
        return "legacy"
    }

    fileprivate static func environmentFlagIsTruthy(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }

        return normalized == "1" ||
            normalized == "true" ||
            normalized == "yes" ||
            normalized == "on" ||
            normalized == "shadow"
    }
}

enum WaveformTiledRendererFeatureFlags {
    static var isLegacyEnabled: Bool {
        WaveformGPUResidentWaveformsFeatureFlags.environmentFlagIsTruthy(
            ProcessInfo.processInfo.environment["SOUNDTIME_TILED_WAVEFORM_RENDERER"]
        )
    }

    static var isEnabled: Bool {
        isLegacyEnabled || WaveformGPUResidentWaveformsFeatureFlags.isEnabled
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
    private final class AsyncWorkCallbacks: @unchecked Sendable {
        let discardUpload: ((WaveformTileAddress, WaveformTileGPUResource) -> Void)?
        let evictUpload: (([WaveformTileAddress]) -> Void)?
        let upload: WaveformTileUploadCoordinator.UploadHandler
        let onWorkCompleted: (() -> Void)?

        init(
            discardUpload: ((WaveformTileAddress, WaveformTileGPUResource) -> Void)?,
            evictUpload: (([WaveformTileAddress]) -> Void)?,
            upload: @escaping WaveformTileUploadCoordinator.UploadHandler,
            onWorkCompleted: (() -> Void)?
        ) {
            self.discardUpload = discardUpload
            self.evictUpload = evictUpload
            self.upload = upload
            self.onWorkCompleted = onWorkCompleted
        }
    }

    private let requestQueue: WaveformTileRequestQueue
    private let tileStore: WaveformTileStore
    private let residencyStore: WaveformTileGPUResidencyStore
    private let buildWorker: WaveformTileBuildWorker
    private let uploadCoordinator: WaveformTileUploadCoordinator
    private let renderSelector: WaveformTileRenderSelector
    private let promotionPlanner: WaveformTilePromotionPlanner
    private let lock = NSLock()
    private var registeredSourceIDs = Set<WaveformSourceID>()
    private let workQueue = DispatchQueue(
        label: "Soundtime.waveform.tiles.pipeline",
        qos: .userInitiated
    )
    private var isAsyncWorkScheduled = false
    private var pendingAsyncUploadPriorityAddresses: [WaveformTileAddress] = []
    private var completedAsyncBuildSummary = WaveformTileBuildWorkerBatchSummary()
    private var completedAsyncUploadSummary = WaveformTileUploadBatchSummary()

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

    @discardableResult
    func registerSources(_ sources: [WaveformTileBuildSource]) -> Set<WaveformSourceID> {
        var uniqueSources: [WaveformSourceID: WaveformTileBuildSource] = [:]
        uniqueSources.reserveCapacity(sources.count)
        for source in sources {
            uniqueSources[source.sourceID] = source
        }
        let nextSourceIDs = Set(uniqueSources.keys)
        lock.lock()
        let staleSourceIDs = registeredSourceIDs.subtracting(nextSourceIDs)
        let newSourceIDs = nextSourceIDs.subtracting(registeredSourceIDs)
        registeredSourceIDs = nextSourceIDs
        lock.unlock()

        for sourceID in newSourceIDs {
            if let source = uniqueSources[sourceID] {
                buildWorker.registerSource(source)
            }
        }
        for sourceID in staleSourceIDs {
            buildWorker.unregisterSource(sourceID)
            uploadCoordinator.removeAll(for: sourceID)
            tileStore.removeAll(for: sourceID)
            renderSelector.removeAll(for: sourceID)
            promotionPlanner.removeAll(for: sourceID)
        }
        return staleSourceIDs
    }

    func prepareFrame(
        source: WaveformTileSourceMetadata,
        viewport: WaveformTileSchedulerViewport,
        segments: [WaveformTileSchedulerSegment] = [],
        predictedViewport: WaveformTileSchedulerViewport? = nil,
        timestamp: TimeInterval,
        schedulerConfig: WaveformTileSchedulerConfig = WaveformTileSchedulerConfig(),
        buildBatchLimit: Int = 8,
        uploadBudget: WaveformTileUploadBudget = WaveformTileUploadBudget(
            maximumBytesPerBatch: 2 * 1_024 * 1_024,
            maximumTilesPerBatch: 12
        ),
        discardUpload: ((WaveformTileAddress, WaveformTileGPUResource) -> Void)? = nil,
        upload: WaveformTileUploadCoordinator.UploadHandler
    ) -> WaveformTiledRenderFrame {
        let requests = tileRequests(
            source: source,
            viewport: viewport,
            segments: segments,
            predictedViewport: predictedViewport,
            schedulerConfig: schedulerConfig
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
            discardUpload: discardUpload,
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

    func prepareResidentFrame(
        source: WaveformTileSourceMetadata,
        viewport: WaveformTileSchedulerViewport,
        segments: [WaveformTileSchedulerSegment] = [],
        predictedViewport: WaveformTileSchedulerViewport? = nil,
        timestamp: TimeInterval,
        schedulerConfig: WaveformTileSchedulerConfig = WaveformTileSchedulerConfig(),
        buildBatchLimit: Int = 8,
        uploadBudget: WaveformTileUploadBudget = WaveformTileUploadBudget(
            maximumBytesPerBatch: 2 * 1_024 * 1_024,
            maximumTilesPerBatch: 12
        ),
        discardUpload: ((WaveformTileAddress, WaveformTileGPUResource) -> Void)? = nil,
        evictUpload: (([WaveformTileAddress]) -> Void)? = nil,
        upload: @escaping WaveformTileUploadCoordinator.UploadHandler,
        onWorkCompleted: (() -> Void)? = nil
    ) -> WaveformTiledRenderFrame {
        let requests = tileRequests(
            source: source,
            viewport: viewport,
            segments: segments,
            predictedViewport: predictedViewport,
            schedulerConfig: schedulerConfig
        )
        requestQueue.enqueue(requests)
        scheduleAsyncWork(
            priorityAddresses: requests.map(\.descriptor.address),
            buildBatchLimit: buildBatchLimit,
            uploadBudget: uploadBudget,
            discardUpload: discardUpload,
            evictUpload: evictUpload,
            upload: upload,
            onWorkCompleted: onWorkCompleted
        )

        let renderSelection = renderSelector.selectRenderableTiles(for: requests)
        let promotionPlan = promotionPlanner.plan(
            selection: renderSelection,
            timestamp: timestamp
        )

        return WaveformTiledRenderFrame(
            requestedTiles: requests,
            buildSummary: WaveformTileBuildWorkerBatchSummary(),
            uploadSummary: WaveformTileUploadBatchSummary(),
            renderSelection: renderSelection,
            promotionPlan: promotionPlan,
            residencySnapshot: residencyStore.snapshot()
        )
    }

    private func tileRequests(
        source: WaveformTileSourceMetadata,
        viewport: WaveformTileSchedulerViewport,
        segments: [WaveformTileSchedulerSegment],
        predictedViewport: WaveformTileSchedulerViewport?,
        schedulerConfig: WaveformTileSchedulerConfig
    ) -> [WaveformTileRequest] {
        if segments.isEmpty {
            return WaveformTileScheduler.requests(
                for: source,
                viewport: viewport,
                predictedViewport: predictedViewport,
                config: schedulerConfig
            )
        }

        return WaveformTileScheduler.requests(
            for: source,
            viewport: viewport,
            segments: segments,
            predictedViewport: predictedViewport,
            config: schedulerConfig
        )
    }

    func drainCompletedAsyncWork() -> (
        buildSummary: WaveformTileBuildWorkerBatchSummary,
        uploadSummary: WaveformTileUploadBatchSummary
    ) {
        lock.lock()
        let buildSummary = completedAsyncBuildSummary
        let uploadSummary = completedAsyncUploadSummary
        completedAsyncBuildSummary = WaveformTileBuildWorkerBatchSummary()
        completedAsyncUploadSummary = WaveformTileUploadBatchSummary()
        lock.unlock()
        return (buildSummary, uploadSummary)
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
        lock.lock()
        pendingAsyncUploadPriorityAddresses.removeAll()
        completedAsyncBuildSummary = WaveformTileBuildWorkerBatchSummary()
        completedAsyncUploadSummary = WaveformTileUploadBatchSummary()
        lock.unlock()
    }

    private func scheduleAsyncWork(
        priorityAddresses: [WaveformTileAddress],
        buildBatchLimit: Int,
        uploadBudget: WaveformTileUploadBudget,
        discardUpload: ((WaveformTileAddress, WaveformTileGPUResource) -> Void)?,
        evictUpload: (([WaveformTileAddress]) -> Void)?,
        upload: @escaping WaveformTileUploadCoordinator.UploadHandler,
        onWorkCompleted: (() -> Void)?
    ) {
        lock.lock()
        pendingAsyncUploadPriorityAddresses.append(contentsOf: priorityAddresses)
        guard !isAsyncWorkScheduled else {
            lock.unlock()
            return
        }
        isAsyncWorkScheduled = true
        lock.unlock()

        let callbacks = AsyncWorkCallbacks(
            discardUpload: discardUpload,
            evictUpload: evictUpload,
            upload: upload,
            onWorkCompleted: onWorkCompleted
        )
        workQueue.async { [weak self] in
            self?.runAsyncWorkPass(
                buildBatchLimit: buildBatchLimit,
                uploadBudget: uploadBudget,
                callbacks: callbacks
            )
        }
    }

    private func runAsyncWorkPass(
        buildBatchLimit: Int,
        uploadBudget: WaveformTileUploadBudget,
        callbacks: AsyncWorkCallbacks
    ) {
        lock.lock()
        let priorityAddresses = pendingAsyncUploadPriorityAddresses
        pendingAsyncUploadPriorityAddresses.removeAll()
        let sourceIDs = registeredSourceIDs
        lock.unlock()

        let buildSummary = buildWorker.processNextBatch(maxCount: buildBatchLimit)
        let uploadAddresses = prioritizedUploadAddresses(
            requestedAddresses: priorityAddresses,
            sourceIDs: sourceIDs
        )
        let uploadSummary = uploadCoordinator.uploadNextBatch(
            prioritizedAddresses: uploadAddresses,
            budget: uploadBudget,
            discardUpload: callbacks.discardUpload,
            upload: callbacks.upload
        )
        if !uploadSummary.evictedAddresses.isEmpty {
            callbacks.evictUpload?(uploadSummary.evictedAddresses)
        }

        lock.lock()
        completedAsyncBuildSummary.merge(buildSummary)
        completedAsyncUploadSummary.merge(uploadSummary)
        let hasQueuedPriorityAddresses = !pendingAsyncUploadPriorityAddresses.isEmpty
        isAsyncWorkScheduled = false
        lock.unlock()

        if
            buildSummary.resolvedCount > 0 ||
            uploadSummary.uploadedCount > 0 ||
            uploadSummary.evictedCount > 0
        {
            callbacks.onWorkCompleted?()
        }

        let requestSnapshot = requestQueue.snapshot()
        let shouldContinue =
            hasQueuedPriorityAddresses ||
            requestSnapshot.pendingCount > 0 ||
            uploadSummary.skippedBudgetCount > 0 ||
            buildSummary.committedCount > uploadSummary.uploadedCount
        if shouldContinue {
            scheduleAsyncWork(
                priorityAddresses: [],
                buildBatchLimit: buildBatchLimit,
                uploadBudget: uploadBudget,
                discardUpload: callbacks.discardUpload,
                evictUpload: callbacks.evictUpload,
                upload: callbacks.upload,
                onWorkCompleted: callbacks.onWorkCompleted
            )
        }
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

    private func prioritizedUploadAddresses(
        requestedAddresses: [WaveformTileAddress],
        sourceIDs: Set<WaveformSourceID>
    ) -> [WaveformTileAddress] {
        var seenAddresses = Set<WaveformTileAddress>()
        var addresses: [WaveformTileAddress] = []
        for address in requestedAddresses where seenAddresses.insert(address).inserted {
            addresses.append(address)
        }
        for sourceID in sourceIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            for address in tileStore.committedAddresses(for: sourceID) where seenAddresses.insert(address).inserted {
                addresses.append(address)
            }
        }
        return addresses
    }
}

private extension WaveformTileBuildWorkerBatchSummary {
    mutating func merge(_ other: WaveformTileBuildWorkerBatchSummary) {
        dequeuedCount += other.dequeuedCount
        diskHitCount += other.diskHitCount
        builtLevelCount += other.builtLevelCount
        builtRawTileCount += other.builtRawTileCount
        alreadyAvailableCount += other.alreadyAvailableCount
        committedCount += other.committedCount
        staleCount += other.staleCount
        failedCount += other.failedCount
    }
}

private extension WaveformTileUploadBatchSummary {
    mutating func merge(_ other: WaveformTileUploadBatchSummary) {
        consideredCount += other.consideredCount
        uploadedCount += other.uploadedCount
        uploadedBytes += other.uploadedBytes
        uploadedAddresses.append(contentsOf: other.uploadedAddresses)
        skippedResidentCount += other.skippedResidentCount
        skippedMissingPayloadCount += other.skippedMissingPayloadCount
        skippedBudgetCount += other.skippedBudgetCount
        staleUploadCount += other.staleUploadCount
        evictedCount += other.evictedCount
        evictedAddresses.append(contentsOf: other.evictedAddresses)
    }
}
