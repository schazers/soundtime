import Foundation

struct WaveformTileSourceMetadata: Hashable, Sendable {
    let sourceID: WaveformSourceID
    let editGraphID: String?
    let duration: TimeInterval
    let frameCount: Int64
    let sampleRate: Double
    let channelMode: WaveformChannelMode

    init(
        sourceID: WaveformSourceID,
        editGraphID: String? = nil,
        duration: TimeInterval,
        frameCount: Int64,
        sampleRate: Double,
        channelMode: WaveformChannelMode = .monoMix
    ) {
        self.sourceID = sourceID
        self.editGraphID = editGraphID
        self.duration = max(0, duration)
        self.frameCount = max(0, frameCount)
        self.sampleRate = max(1, sampleRate)
        self.channelMode = channelMode
    }
}

struct WaveformTileSchedulerViewport: Hashable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let widthPixels: Double

    init(startTime: TimeInterval, endTime: TimeInterval, widthPixels: Double) {
        let clampedStart = max(0, startTime)
        self.startTime = clampedStart
        self.endTime = max(clampedStart, endTime)
        self.widthPixels = max(1, widthPixels)
    }

    init(timelineViewport: TimelineViewport, duration: TimeInterval, widthPixels: Double) {
        let clampedDuration = max(0, duration)
        self.init(
            startTime: Double(timelineViewport.startProgress) * clampedDuration,
            endTime: Double(timelineViewport.endProgress) * clampedDuration,
            widthPixels: widthPixels
        )
    }

    var duration: TimeInterval {
        max(0, endTime - startTime)
    }

    func samplesPerPixel(sampleRate: Double) -> Double {
        max(duration * max(sampleRate, 1) / widthPixels, 0)
    }

    func frameRange(sampleRate: Double, frameCount: Int64) -> WaveformFrameRange {
        let safeFrameCount = max(0, frameCount)
        let safeSampleRate = max(1, sampleRate)
        let startFrame = Int64(floor(startTime * safeSampleRate))
        let endFrame = Int64(ceil(endTime * safeSampleRate))
        return WaveformFrameRange(
            startFrame: min(max(0, startFrame), safeFrameCount),
            endFrame: min(max(0, endFrame), safeFrameCount)
        )
    }
}

enum WaveformTileRequestPurpose: Int, Sendable {
    case visible = 0
    case nearPrefetch = 1
    case predictedPrefetch = 2
    case background = 3
}

extension WaveformTileRequestPurpose: Comparable {
    static func < (lhs: WaveformTileRequestPurpose, rhs: WaveformTileRequestPurpose) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct WaveformTileRequest: Hashable, Sendable, Comparable {
    let descriptor: WaveformTileDescriptor
    let purpose: WaveformTileRequestPurpose
    let distanceFromVisibleTiles: Int
    let samplesPerPixel: Double

    init(
        descriptor: WaveformTileDescriptor,
        purpose: WaveformTileRequestPurpose,
        distanceFromVisibleTiles: Int,
        samplesPerPixel: Double
    ) {
        self.descriptor = descriptor
        self.purpose = purpose
        self.distanceFromVisibleTiles = max(0, distanceFromVisibleTiles)
        self.samplesPerPixel = max(0, samplesPerPixel)
    }

    static func < (lhs: WaveformTileRequest, rhs: WaveformTileRequest) -> Bool {
        if lhs.purpose != rhs.purpose {
            return lhs.purpose < rhs.purpose
        }
        if lhs.distanceFromVisibleTiles != rhs.distanceFromVisibleTiles {
            return lhs.distanceFromVisibleTiles < rhs.distanceFromVisibleTiles
        }
        return lhs.descriptor.address < rhs.descriptor.address
    }
}

struct WaveformTileSchedulerConfig: Hashable, Sendable {
    let peakFramesPerTile: Int64
    let rawFramesPerTile: Int64
    let minimumPeakFramesPerBin: Int
    let maximumPeakFramesPerBin: Int
    let targetPeakBinsPerPixel: Double
    let rawSamplesPerPixelThreshold: Double
    let nearPrefetchTileRadius: Int
    let predictedPrefetchTileRadius: Int
    let backgroundTileStride: Int
    let maximumBackgroundRequests: Int

    init(
        peakFramesPerTile: Int64 = WaveformPeakTileBuilder.defaultFramesPerTile,
        rawFramesPerTile: Int64 = 16_384,
        minimumPeakFramesPerBin: Int = 8,
        maximumPeakFramesPerBin: Int = 16_384,
        targetPeakBinsPerPixel: Double = 0.75,
        rawSamplesPerPixelThreshold: Double = 2,
        nearPrefetchTileRadius: Int = 2,
        predictedPrefetchTileRadius: Int = 1,
        backgroundTileStride: Int = 8,
        maximumBackgroundRequests: Int = 48
    ) {
        self.peakFramesPerTile = max(1, peakFramesPerTile)
        self.rawFramesPerTile = max(1, rawFramesPerTile)
        self.minimumPeakFramesPerBin = max(1, minimumPeakFramesPerBin)
        self.maximumPeakFramesPerBin = max(self.minimumPeakFramesPerBin, maximumPeakFramesPerBin)
        self.targetPeakBinsPerPixel = max(0.05, targetPeakBinsPerPixel)
        self.rawSamplesPerPixelThreshold = max(0, rawSamplesPerPixelThreshold)
        self.nearPrefetchTileRadius = max(0, nearPrefetchTileRadius)
        self.predictedPrefetchTileRadius = max(0, predictedPrefetchTileRadius)
        self.backgroundTileStride = max(1, backgroundTileStride)
        self.maximumBackgroundRequests = max(0, maximumBackgroundRequests)
    }
}

enum WaveformTileScheduler {
    static func requests(
        for source: WaveformTileSourceMetadata,
        viewport: WaveformTileSchedulerViewport,
        predictedViewport: WaveformTileSchedulerViewport? = nil,
        config: WaveformTileSchedulerConfig = WaveformTileSchedulerConfig()
    ) -> [WaveformTileRequest] {
        guard source.frameCount > 0, source.duration > 0 else {
            return []
        }

        let preferred = preferredTileShape(
            source: source,
            viewport: viewport,
            config: config
        )
        let visibleRange = viewport.frameRange(
            sampleRate: source.sampleRate,
            frameCount: source.frameCount
        )
        guard let visibleSpan = tileSpan(
            for: visibleRange,
            framesPerTile: preferred.framesPerTile,
            frameCount: source.frameCount
        ) else {
            return []
        }

        let visibleTileSet = Set(visibleSpan)
        var requestsByAddress: [WaveformTileAddress: WaveformTileRequest] = [:]

        for tileIndex in visibleSpan {
            insertRequest(
                tileIndex: tileIndex,
                purpose: .visible,
                distance: 0,
                source: source,
                shape: preferred,
                samplesPerPixel: preferred.samplesPerPixel,
                frameCount: source.frameCount,
                into: &requestsByAddress
            )
        }

        insertPrefetchRequests(
            around: visibleSpan,
            radius: config.nearPrefetchTileRadius,
            excluding: visibleTileSet,
            purpose: .nearPrefetch,
            source: source,
            shape: preferred,
            frameCount: source.frameCount,
            into: &requestsByAddress
        )

        if let predictedViewport {
            let predictedRange = predictedViewport.frameRange(
                sampleRate: source.sampleRate,
                frameCount: source.frameCount
            )
            if let predictedSpan = tileSpan(
                for: predictedRange,
                framesPerTile: preferred.framesPerTile,
                frameCount: source.frameCount
            ) {
                insertPrefetchRequests(
                    around: predictedSpan,
                    radius: config.predictedPrefetchTileRadius,
                    excluding: visibleTileSet,
                    purpose: .predictedPrefetch,
                    source: source,
                    shape: preferred,
                    frameCount: source.frameCount,
                    into: &requestsByAddress
                )
            }
        }

        if preferred.kind == .peak, config.maximumBackgroundRequests > 0 {
            insertBackgroundRequests(
                visibleSpan: visibleSpan,
                source: source,
                shape: preferred,
                config: config,
                frameCount: source.frameCount,
                into: &requestsByAddress
            )
        }

        return requestsByAddress.values.sorted()
    }

    private struct TileShape {
        let kind: WaveformTileKind
        let level: Int
        let framesPerTile: Int64
        let framesPerBin: Int
        let samplesPerPixel: Double
    }

    private static func preferredTileShape(
        source: WaveformTileSourceMetadata,
        viewport: WaveformTileSchedulerViewport,
        config: WaveformTileSchedulerConfig
    ) -> TileShape {
        let samplesPerPixel = viewport.samplesPerPixel(sampleRate: source.sampleRate)
        if samplesPerPixel <= config.rawSamplesPerPixelThreshold {
            return TileShape(
                kind: .rawSamples,
                level: 0,
                framesPerTile: config.rawFramesPerTile,
                framesPerBin: 1,
                samplesPerPixel: samplesPerPixel
            )
        }

        let targetFramesPerBin = max(1, Int(ceil(samplesPerPixel / config.targetPeakBinsPerPixel)))
        let framesPerBin = min(
            max(nextPowerOfTwo(targetFramesPerBin), config.minimumPeakFramesPerBin),
            config.maximumPeakFramesPerBin
        )
        return TileShape(
            kind: .peak,
            level: integerLog2(framesPerBin),
            framesPerTile: config.peakFramesPerTile,
            framesPerBin: framesPerBin,
            samplesPerPixel: samplesPerPixel
        )
    }

    private static func insertPrefetchRequests(
        around span: ClosedRange<Int>,
        radius: Int,
        excluding visibleTileSet: Set<Int>,
        purpose: WaveformTileRequestPurpose,
        source: WaveformTileSourceMetadata,
        shape: TileShape,
        frameCount: Int64,
        into requestsByAddress: inout [WaveformTileAddress: WaveformTileRequest]
    ) {
        guard radius > 0 else {
            return
        }
        let maxTileIndex = maximumTileIndex(frameCount: frameCount, framesPerTile: shape.framesPerTile)
        let start = max(0, span.lowerBound - radius)
        let end = min(maxTileIndex, span.upperBound + radius)
        guard start <= end else {
            return
        }

        for tileIndex in start...end where !visibleTileSet.contains(tileIndex) {
            insertRequest(
                tileIndex: tileIndex,
                purpose: purpose,
                distance: distance(from: tileIndex, to: span),
                source: source,
                shape: shape,
                samplesPerPixel: shape.samplesPerPixel,
                frameCount: frameCount,
                into: &requestsByAddress
            )
        }
    }

    private static func insertBackgroundRequests(
        visibleSpan: ClosedRange<Int>,
        source: WaveformTileSourceMetadata,
        shape: TileShape,
        config: WaveformTileSchedulerConfig,
        frameCount: Int64,
        into requestsByAddress: inout [WaveformTileAddress: WaveformTileRequest]
    ) {
        let maxTileIndex = maximumTileIndex(frameCount: frameCount, framesPerTile: shape.framesPerTile)
        guard maxTileIndex >= 0 else {
            return
        }

        var inserted = 0
        var tileIndex = 0
        while tileIndex <= maxTileIndex, inserted < config.maximumBackgroundRequests {
            insertRequest(
                tileIndex: tileIndex,
                purpose: .background,
                distance: distance(from: tileIndex, to: visibleSpan),
                source: source,
                shape: shape,
                samplesPerPixel: shape.samplesPerPixel,
                frameCount: frameCount,
                into: &requestsByAddress
            )
            inserted += 1
            tileIndex += config.backgroundTileStride
        }
    }

    private static func insertRequest(
        tileIndex: Int,
        purpose: WaveformTileRequestPurpose,
        distance: Int,
        source: WaveformTileSourceMetadata,
        shape: TileShape,
        samplesPerPixel: Double,
        frameCount: Int64,
        into requestsByAddress: inout [WaveformTileAddress: WaveformTileRequest]
    ) {
        let descriptor = descriptor(
            tileIndex: tileIndex,
            source: source,
            shape: shape,
            frameCount: frameCount
        )
        let request = WaveformTileRequest(
            descriptor: descriptor,
            purpose: purpose,
            distanceFromVisibleTiles: distance,
            samplesPerPixel: samplesPerPixel
        )

        if let existing = requestsByAddress[descriptor.address], existing <= request {
            return
        }
        requestsByAddress[descriptor.address] = request
    }

    private static func descriptor(
        tileIndex: Int,
        source: WaveformTileSourceMetadata,
        shape: TileShape,
        frameCount: Int64
    ) -> WaveformTileDescriptor {
        let startFrame = Int64(tileIndex) * shape.framesPerTile
        let endFrame = min(startFrame + shape.framesPerTile, frameCount)
        let frameRange = WaveformFrameRange(startFrame: startFrame, endFrame: endFrame)
        let expectedBinCount: Int
        switch shape.kind {
        case .peak:
            expectedBinCount = Int((frameRange.frameCount + Int64(shape.framesPerBin) - 1) / Int64(shape.framesPerBin))
        case .rawSamples:
            expectedBinCount = Int(frameRange.frameCount)
        }

        return WaveformTileDescriptor(
            address: WaveformTileAddress(
                sourceID: source.sourceID,
                editGraphID: source.editGraphID,
                kind: shape.kind,
                channelMode: source.channelMode,
                level: shape.level,
                tileIndex: tileIndex
            ),
            frameRange: frameRange,
            framesPerBin: shape.framesPerBin,
            expectedBinCount: expectedBinCount
        )
    }

    private static func tileSpan(
        for frameRange: WaveformFrameRange,
        framesPerTile: Int64,
        frameCount: Int64
    ) -> ClosedRange<Int>? {
        let safeFramesPerTile = max(1, framesPerTile)
        guard frameCount > 0, !frameRange.isEmpty else {
            return nil
        }
        let startFrame = min(max(0, frameRange.startFrame), frameCount - 1)
        let endFrame = min(max(startFrame + 1, frameRange.endFrame), frameCount)
        let startIndex = Int(startFrame / safeFramesPerTile)
        let endIndex = Int((endFrame - 1) / safeFramesPerTile)
        return startIndex...max(startIndex, endIndex)
    }

    private static func maximumTileIndex(frameCount: Int64, framesPerTile: Int64) -> Int {
        guard frameCount > 0 else {
            return -1
        }
        return Int((frameCount - 1) / max(1, framesPerTile))
    }

    private static func distance(from tileIndex: Int, to span: ClosedRange<Int>) -> Int {
        if span.contains(tileIndex) {
            return 0
        }
        if tileIndex < span.lowerBound {
            return span.lowerBound - tileIndex
        }
        return tileIndex - span.upperBound
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var power = 1
        while power < value {
            power <<= 1
        }
        return power
    }

    private static func integerLog2(_ value: Int) -> Int {
        var level = 0
        var remaining = max(1, value)
        while remaining > 1 {
            remaining >>= 1
            level += 1
        }
        return level
    }
}
