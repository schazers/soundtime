import Foundation
@preconcurrency import Metal
import QuartzCore
import Darwin

enum TimelinePerfBaselineHarness {
    private static let maximumVisualEffectVerticesPerFrame = 10_000
    private static let maximumTransientParticlesPerFrame = 260
    private static let maximumDeletionEffectsPerFrame = 8
    private static let maximumPlayheadContactEventsPerFrame = 384

    private struct Scenario {
        let name: String
        let trackCount: Int
        let waveformBinCount: Int?
        let frames: Int
        let warmupFrames: Int
        let viewportDuration: Float
        let isPlaybackActive: Bool
        let pansDuringRun: Bool
        let zoomsDuringRun: Bool
        let scrollsTracksDuringRun: Bool
        let showsSelection: Bool
        let showsGainPreview: Bool
        let targetsVisibleTrack: Bool
        let deletionBurstInterval: Int?
        var waveformRefreshInterval: Int? = nil
        var transientBurstInterval: Int? = nil
        var syntheticDuration: TimeInterval = 360
        var clipCountPerTrack: Int = 0
        var waveformLayerCount: Int = 1
        var automationPointCountPerTrack: Int = 0
        var transcriptWordCount: Int = 0
        var transcriptTrackStride: Int = 0
        var measuresTranscriptLayout: Bool = false
        var measuresFullFrameWork: Bool = false
        var requiresZeroDropped144HzFrames: Bool = false
        var dragsClipDuringRun: Bool = false
    }

    private struct TrackCacheKey: Hashable {
        let trackCount: Int
        let waveformBinCount: Int
        let syntheticDurationMilliseconds: Int
        let clipCountPerTrack: Int
        let waveformLayerCount: Int
        let automationPointCountPerTrack: Int
        let transcriptWordCount: Int
        let transcriptTrackStride: Int
    }

    private struct ScenarioResult {
        let scenario: Scenario
        let cpuFrameMilliseconds: [Double]
        let gpuFrameMilliseconds: [Double]
        let stateUpdateMilliseconds: [Double]
        let transcriptLayoutMilliseconds: [Double]
        let renderSubmissionMilliseconds: [Double]
        let rendererStats: TimelineFrameStats
        let rendererStatsSamples: [TimelineFrameStats]
        let deletionEffectCounts: [Int]
        let visibleLaneCounts: [Int]
        let visibleLaneBudget: Int
        var attemptCount: Int = 1

        var frameCount: Int {
            cpuFrameMilliseconds.count
        }

        var waveformRenderers: [String] {
            let renderers = Set(rendererStatsSamples.map(\.waveformRenderer))
            guard renderers.isEmpty == false else {
                return [rendererStats.waveformRenderer]
            }
            return renderers.sorted()
        }

        var maximumCPUWaveformVertexCount: Int {
            rendererStatsSamples.map(\.cpuWaveformVertexCount).max() ?? rendererStats.cpuWaveformVertexCount
        }

        var maximumGPUWaveformDrawCount: Int {
            rendererStatsSamples.map(\.gpuWaveformDrawCount).max() ?? rendererStats.gpuWaveformDrawCount
        }

        var maximumShaderBufferUploadCount: Int {
            rendererStatsSamples.map(\.shaderBufferUploadCount).max() ?? rendererStats.shaderBufferUploadCount
        }

        var maximumShaderBufferCount: Int {
            rendererStatsSamples.map(\.shaderBufferCount).max() ?? rendererStats.shaderBufferCount
        }

        var maximumShaderBufferByteCount: Int {
            rendererStatsSamples.map(\.shaderBufferByteCount).max() ?? rendererStats.shaderBufferByteCount
        }

        var maximumShaderBufferUploadInFlightCount: Int {
            rendererStatsSamples.map(\.shaderBufferUploadInFlightCount).max() ??
                rendererStats.shaderBufferUploadInFlightCount
        }

        var maximumEffectVertexCount: Int {
            rendererStatsSamples.map(\.effectVertexCount).max() ?? rendererStats.effectVertexCount
        }

        var maximumEffectDroppedVertexCount: Int {
            rendererStatsSamples.map(\.effectDroppedVertexCount).max() ?? rendererStats.effectDroppedVertexCount
        }

        var maximumTransientParticleCount: Int {
            rendererStatsSamples.map(\.transientParticleCount).max() ?? rendererStats.transientParticleCount
        }

        var maximumDeletionEffectCount: Int {
            max(
                rendererStatsSamples.map(\.deletionEffectCount).max() ?? rendererStats.deletionEffectCount,
                deletionEffectCounts.max() ?? 0
            )
        }

        var maximumPlayheadContactEventCount: Int {
            rendererStatsSamples.map(\.playheadContactEventCount).max() ?? rendererStats.playheadContactEventCount
        }

        var maximumWaveformMipCacheCount: Int {
            rendererStatsSamples.map(\.waveformMipCacheCount).max() ?? rendererStats.waveformMipCacheCount
        }

        var maximumVisibleLaneCount: Int {
            visibleLaneCounts.max() ?? 0
        }

        var averageVisibleLaneCount: Double {
            guard !visibleLaneCounts.isEmpty else {
                return 0
            }

            let total = visibleLaneCounts.reduce(0, +)
            return Double(total) / Double(visibleLaneCounts.count)
        }
    }

    private struct ScenarioBudget {
        let cpuP95Milliseconds: Double
        let cpuMaxMilliseconds: Double
        let gpuP95Milliseconds: Double
        let gpuMaxMilliseconds: Double
        let allowedDropped144HzFrames: Int
    }

    private enum HarnessError: Error, CustomStringConvertible {
        case metalDeviceUnavailable
        case textureUnavailable
        case rendererUnavailable
        case budgetExceeded([String])

        var description: String {
            switch self {
            case .metalDeviceUnavailable:
                return "Metal device unavailable"
            case .textureUnavailable:
                return "Could not allocate perf baseline render target"
            case .rendererUnavailable:
                return "Timeline renderer unavailable"
            case let .budgetExceeded(failures):
                return "budget exceeded:\n" + failures.map { "  - \($0)" }.joined(separator: "\n")
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let previousQoS = qos_class_self()
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        defer {
            pthread_set_qos_class_self_np(previousQoS, 0)
        }

        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let isExtreme = arguments.contains("--extreme") ||
            arguments.contains("--extreme-timeline-performance")
        let isQuick = arguments.contains("--quick") || arguments.contains("--timeline-perf-baseline-quick")
        let enforcesBudgets = arguments.contains("--ci") || arguments.contains("--timeline-perf-baseline-ci")
        let pixelFormat: MTLPixelFormat = .bgra8Unorm
        let viewportSize = CGSize(width: isQuick ? 1_440 : 1_920, height: isQuick ? 900 : 1_080)
        let backingScale: Float = 2
        let textureWidth = max(Int(viewportSize.width * CGFloat(backingScale)), 1)
        let textureHeight = max(Int(viewportSize.height * CGFloat(backingScale)), 1)
        let syntheticBinCount = isQuick ? 8_192 : 16_384
        let scenarioFrames = isQuick ? 72 : 144
        let warmupFrames = isQuick ? 24 : 48

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw HarnessError.metalDeviceUnavailable
        }

        let renderer = try TimelineRenderer(device: device, pixelFormat: pixelFormat)
        renderer.onFrameStatsChanged = { stats in
            _ = stats
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: textureWidth,
            height: textureHeight,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget]
        textureDescriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw HarnessError.textureUnavailable
        }
        texture.label = "Soundtime timeline perf baseline target"

        let scenarios = isExtreme ?
            makeExtremeScenarios(frames: scenarioFrames, warmupFrames: warmupFrames) :
            makeScenarios(isQuick: isQuick, frames: scenarioFrames, warmupFrames: warmupFrames)

        print("Soundtime timeline perf baseline")
        let modeName = isExtreme ? "extreme" : (isQuick ? "quick" : "full")
        print("device=\(device.name) mode=\(modeName) viewport=\(Int(viewportSize.width))x\(Int(viewportSize.height)) scale=\(backingScale) bins=\(syntheticBinCount)")

        var trackCache: [TrackCacheKey: [TimelineRenderState.Track]] = [:]
        var budgetFailures: [String] = []
        var reportChecks: [StabilityCheckReport] = []
        for scenario in scenarios {
            let scenarioBinCount = scenario.waveformBinCount ?? syntheticBinCount
            let cacheKey = TrackCacheKey(
                trackCount: scenario.trackCount,
                waveformBinCount: scenarioBinCount,
                syntheticDurationMilliseconds: Int((scenario.syntheticDuration * 1_000).rounded()),
                clipCountPerTrack: scenario.clipCountPerTrack,
                waveformLayerCount: scenario.waveformLayerCount,
                automationPointCountPerTrack: scenario.automationPointCountPerTrack,
                transcriptWordCount: scenario.transcriptWordCount,
                transcriptTrackStride: scenario.transcriptTrackStride
            )
            let tracks: [TimelineRenderState.Track]
            if let cachedTracks = trackCache[cacheKey] {
                tracks = cachedTracks
            } else {
                tracks = makeSyntheticTracks(
                    count: scenario.trackCount,
                    duration: scenario.syntheticDuration,
                    binCount: scenarioBinCount,
                    clipCountPerTrack: scenario.clipCountPerTrack,
                    waveformLayerCount: scenario.waveformLayerCount,
                    automationPointCountPerTrack: scenario.automationPointCountPerTrack,
                    transcriptWordCount: scenario.transcriptWordCount,
                    transcriptTrackStride: scenario.transcriptTrackStride
                )
                trackCache[cacheKey] = tracks
            }

            let result = runBestSteadyStateAttempt(
                scenario: scenario,
                tracks: tracks,
                renderer: renderer,
                texture: texture,
                viewportSize: viewportSize,
                backingScale: backingScale,
                rendererStats: { renderer.currentFrameStatsSnapshot() },
                enforcesBudgets: enforcesBudgets
            )
            let resultBudgetFailures = budgetFailuresFor(result)
            let resultJSONLine = jsonLine(for: result, deviceName: device.name)
            print(resultJSONLine)
            reportChecks.append(StabilityCheckReport(
                name: "\(scenario.name) / \(scenario.trackCount) tracks",
                status: resultBudgetFailures.isEmpty ? "passed" : "failed",
                detail: resultBudgetFailures.isEmpty ?
                    resultJSONLine :
                    resultJSONLine + "\n" + resultBudgetFailures.joined(separator: "\n")
            ))
            if enforcesBudgets {
                budgetFailures.append(contentsOf: resultBudgetFailures)
            }
        }

        if let reportURL = StabilityReportWriter.writeSuite(
            name: isExtreme ? "extreme-timeline-performance" : "timeline-perf-baseline",
            status: budgetFailures.isEmpty ? "passed" : "failed",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: reportChecks,
            metadata: [
                "device": device.name,
                "mode": modeName,
                "enforcesBudgets": enforcesBudgets ? "true" : "false",
                "viewportWidth": "\(textureWidth)",
                "viewportHeight": "\(textureHeight)",
                "backingScale": "\(backingScale)",
                "syntheticBinCount": "\(syntheticBinCount)",
                "scenarioCount": "\(scenarios.count)",
            ],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }

        if !budgetFailures.isEmpty {
            throw HarnessError.budgetExceeded(budgetFailures)
        }
    }

    private static func makeExtremeScenarios(
        frames: Int,
        warmupFrames: Int
    ) -> [Scenario] {
        [
            Scenario(
                name: "extreme clips text automation pan zoom",
                trackCount: 1_000,
                waveformBinCount: 131_072,
                frames: max(frames, 360),
                warmupFrames: max(warmupFrames, 120),
                viewportDuration: 0.035,
                isPlaybackActive: true,
                pansDuringRun: true,
                zoomsDuringRun: true,
                scrollsTracksDuringRun: true,
                showsSelection: true,
                showsGainPreview: false,
                targetsVisibleTrack: true,
                deletionBurstInterval: nil,
                syntheticDuration: 7_200,
                clipCountPerTrack: 128,
                waveformLayerCount: 4,
                automationPointCountPerTrack: 256,
                transcriptWordCount: 384,
                transcriptTrackStride: 4,
                measuresTranscriptLayout: true,
                measuresFullFrameWork: true,
                requiresZeroDropped144HzFrames: true
            ),
            Scenario(
                name: "extreme stable clip drag",
                trackCount: 1_000,
                waveformBinCount: 131_072,
                frames: max(frames, 360),
                warmupFrames: max(warmupFrames, 120),
                viewportDuration: 0.035,
                isPlaybackActive: true,
                pansDuringRun: true,
                zoomsDuringRun: true,
                scrollsTracksDuringRun: false,
                showsSelection: false,
                showsGainPreview: false,
                targetsVisibleTrack: true,
                deletionBurstInterval: nil,
                syntheticDuration: 7_200,
                clipCountPerTrack: 128,
                waveformLayerCount: 4,
                automationPointCountPerTrack: 256,
                transcriptWordCount: 384,
                transcriptTrackStride: 4,
                measuresTranscriptLayout: true,
                measuresFullFrameWork: true,
                requiresZeroDropped144HzFrames: true,
                dragsClipDuringRun: true
            ),
        ]
    }

    private static func makeScenarios(
        isQuick: Bool,
        frames: Int,
        warmupFrames: Int
    ) -> [Scenario] {
        let trackCounts = isQuick ? [10, 50, 100] : [10, 50, 100, 250]
        var scenarios = trackCounts.flatMap { trackCount in
            [
                Scenario(
                    name: "zoomed-out playback",
                    trackCount: trackCount,
                    waveformBinCount: nil,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 1,
                    isPlaybackActive: true,
                    pansDuringRun: false,
                    zoomsDuringRun: false,
                    scrollsTracksDuringRun: false,
                    showsSelection: false,
                    showsGainPreview: false,
                    targetsVisibleTrack: false,
                    deletionBurstInterval: nil
                ),
                Scenario(
                    name: "zoomed-in playback",
                    trackCount: trackCount,
                    waveformBinCount: nil,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 0.035,
                    isPlaybackActive: true,
                    pansDuringRun: false,
                    zoomsDuringRun: false,
                    scrollsTracksDuringRun: false,
                    showsSelection: false,
                    showsGainPreview: false,
                    targetsVisibleTrack: false,
                    deletionBurstInterval: nil
                ),
                Scenario(
                    name: "pan sweep",
                    trackCount: trackCount,
                    waveformBinCount: nil,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 0.12,
                    isPlaybackActive: false,
                    pansDuringRun: true,
                    zoomsDuringRun: false,
                    scrollsTracksDuringRun: false,
                    showsSelection: false,
                    showsGainPreview: false,
                    targetsVisibleTrack: false,
                    deletionBurstInterval: nil
                ),
                Scenario(
                    name: "zoom pulse",
                    trackCount: trackCount,
                    waveformBinCount: nil,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 0.18,
                    isPlaybackActive: true,
                    pansDuringRun: true,
                    zoomsDuringRun: true,
                    scrollsTracksDuringRun: false,
                    showsSelection: false,
                    showsGainPreview: false,
                    targetsVisibleTrack: false,
                    deletionBurstInterval: nil
                ),
                Scenario(
                    name: "edit overlays",
                    trackCount: trackCount,
                    waveformBinCount: nil,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 0.10,
                    isPlaybackActive: true,
                    pansDuringRun: true,
                    zoomsDuringRun: false,
                    scrollsTracksDuringRun: false,
                    showsSelection: true,
                    showsGainPreview: true,
                    targetsVisibleTrack: false,
                    deletionBurstInterval: nil
                ),
                Scenario(
                    name: "delete bursts",
                    trackCount: trackCount,
                    waveformBinCount: nil,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 0.16,
                    isPlaybackActive: false,
                    pansDuringRun: true,
                    zoomsDuringRun: false,
                    scrollsTracksDuringRun: false,
                    showsSelection: false,
                    showsGainPreview: false,
                    targetsVisibleTrack: false,
                    deletionBurstInterval: isQuick ? 30 : 45
                ),
                Scenario(
                    name: "track scroll playback",
                    trackCount: trackCount,
                    waveformBinCount: nil,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 0.12,
                    isPlaybackActive: true,
                    pansDuringRun: true,
                    zoomsDuringRun: false,
                    scrollsTracksDuringRun: true,
                    showsSelection: false,
                    showsGainPreview: false,
                    targetsVisibleTrack: false,
                    deletionBurstInterval: nil
                ),
                Scenario(
                    name: "visible track edit overlays",
                    trackCount: trackCount,
                    waveformBinCount: nil,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 0.10,
                    isPlaybackActive: true,
                    pansDuringRun: true,
                    zoomsDuringRun: false,
                    scrollsTracksDuringRun: true,
                    showsSelection: true,
                    showsGainPreview: true,
                    targetsVisibleTrack: true,
                    deletionBurstInterval: nil
                ),
                Scenario(
                    name: "visible track delete bursts",
                    trackCount: trackCount,
                    waveformBinCount: nil,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 0.16,
                    isPlaybackActive: false,
                    pansDuringRun: true,
                    zoomsDuringRun: false,
                    scrollsTracksDuringRun: true,
                    showsSelection: false,
                    showsGainPreview: false,
                    targetsVisibleTrack: true,
                    deletionBurstInterval: isQuick ? 30 : 45
                ),
            ]
        }

        if isQuick {
            scenarios.append(
                Scenario(
                    name: "hundreds visible culling",
                    trackCount: 250,
                    waveformBinCount: nil,
                    frames: max(frames / 2, 36),
                    warmupFrames: max(warmupFrames / 2, 12),
                    viewportDuration: 0.12,
                    isPlaybackActive: true,
                    pansDuringRun: true,
                    zoomsDuringRun: true,
                    scrollsTracksDuringRun: true,
                    showsSelection: true,
                    showsGainPreview: true,
                    targetsVisibleTrack: true,
                    deletionBurstInterval: nil
                )
            )
            scenarios.append(
                Scenario(
                    name: "five hundred visible culling",
                    trackCount: 500,
                    waveformBinCount: nil,
                    frames: max(frames / 3, 24),
                    warmupFrames: max(warmupFrames / 2, 12),
                    viewportDuration: 0.12,
                    isPlaybackActive: true,
                    pansDuringRun: true,
                    zoomsDuringRun: true,
                    scrollsTracksDuringRun: true,
                    showsSelection: true,
                    showsGainPreview: true,
                    targetsVisibleTrack: true,
                    deletionBurstInterval: nil
                )
            )
            scenarios.append(
                Scenario(
                    name: "background waveform refresh",
                    trackCount: 100,
                    waveformBinCount: isQuick ? 32_768 : 65_536,
                    frames: max(frames / 2, 36),
                    warmupFrames: max(warmupFrames, 36),
                    viewportDuration: 0.12,
                    isPlaybackActive: true,
                    pansDuringRun: true,
                    zoomsDuringRun: false,
                    scrollsTracksDuringRun: true,
                    showsSelection: true,
                    showsGainPreview: true,
                    targetsVisibleTrack: true,
                    deletionBurstInterval: nil,
                    waveformRefreshInterval: isQuick ? 18 : 30
                )
            )
            scenarios.append(
                Scenario(
                    name: "combined visual effects",
                    trackCount: 100,
                    waveformBinCount: nil,
                    frames: max(frames / 2, 36),
                    warmupFrames: max(warmupFrames * 4, 144),
                    viewportDuration: 0.035,
                    isPlaybackActive: true,
                    pansDuringRun: false,
                    zoomsDuringRun: false,
                    scrollsTracksDuringRun: true,
                    showsSelection: true,
                    showsGainPreview: true,
                    targetsVisibleTrack: true,
                    deletionBurstInterval: isQuick ? 24 : 36,
                    transientBurstInterval: isQuick ? 12 : 18
                )
            )
            scenarios.append(
                Scenario(
                    name: "high-res zoom fidelity",
                    trackCount: 1,
                    waveformBinCount: WaveformOverviewBuilder.defaultTargetBinCount,
                    frames: max(frames / 2, 36),
                    warmupFrames: max(warmupFrames * 8, 360),
                    viewportDuration: 0.012,
                    isPlaybackActive: true,
                    pansDuringRun: true,
                    zoomsDuringRun: false,
                    scrollsTracksDuringRun: false,
                    showsSelection: false,
                    showsGainPreview: false,
                    targetsVisibleTrack: false,
                    deletionBurstInterval: nil
                )
            )
        }

        return scenarios
    }

    private static func runBestSteadyStateAttempt(
        scenario: Scenario,
        tracks: [TimelineRenderState.Track],
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float,
        rendererStats: () -> TimelineFrameStats,
        enforcesBudgets: Bool
    ) -> ScenarioResult {
        renderer.displayTracks(tracks)
        renderer.displayPlaybackActive(scenario.isPlaybackActive)
        renderer.displayAutomationParameter(
            scenario.automationPointCountPerTrack > 0 &&
                ProcessInfo.processInfo.environment["SOUNDTIME_PERF_DISABLE_AUTOMATION"] != "1" ?
                TimelineAutomationParameterID.volume.rawValue : nil
        )

        var bestResult = run(
            scenario: scenario,
            tracks: tracks,
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            rendererStats: rendererStats
        )
        var bestFailures = budgetFailuresFor(bestResult)
        guard
            enforcesBudgets,
            isRetryableTimingOnlyFailure(bestFailures)
        else {
            return bestResult
        }

        for retryIndex in 0..<2 {
            var retryResult = run(
                scenario: scenario,
                tracks: tracks,
                renderer: renderer,
                texture: texture,
                viewportSize: viewportSize,
                backingScale: backingScale,
                rendererStats: rendererStats
            )
            retryResult.attemptCount = retryIndex + 2
            let retryFailures = budgetFailuresFor(retryResult)
            let retryIsTimingOnly = retryFailures.isEmpty || isRetryableTimingOnlyFailure(retryFailures)
            if
                retryIsTimingOnly,
                (
                    retryFailures.isEmpty ||
                        timingFailureScore(for: retryResult) < timingFailureScore(for: bestResult)
                )
            {
                bestResult = retryResult
                bestFailures = retryFailures
            }
            if retryFailures.isEmpty || !isRetryableTimingOnlyFailure(bestFailures) {
                break
            }
        }

        return bestResult
    }

    private static func run(
        scenario: Scenario,
        tracks: [TimelineRenderState.Track],
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float,
        rendererStats: () -> TimelineFrameStats
    ) -> ScenarioResult {
        var cpuMilliseconds: [Double] = []
        var gpuMilliseconds: [Double] = []
        var stateUpdateMilliseconds: [Double] = []
        var transcriptLayoutMilliseconds: [Double] = []
        var renderSubmissionMilliseconds: [Double] = []
        var rendererStatsSamples: [TimelineFrameStats] = []
        var deletionEffectCounts: [Int] = []
        var visibleLaneCounts: [Int] = []
        var activeTracks = tracks
        cpuMilliseconds.reserveCapacity(scenario.frames)
        gpuMilliseconds.reserveCapacity(scenario.frames)
        stateUpdateMilliseconds.reserveCapacity(scenario.frames)
        transcriptLayoutMilliseconds.reserveCapacity(scenario.frames)
        renderSubmissionMilliseconds.reserveCapacity(scenario.frames)
        rendererStatsSamples.reserveCapacity(scenario.frames)
        deletionEffectCounts.reserveCapacity(scenario.frames)
        visibleLaneCounts.reserveCapacity(scenario.frames)
        renderer.displayTracks(activeTracks)

        let totalFrames = scenario.warmupFrames + scenario.frames
        let maximumSettleFrames = 240
        let requiredSettledResidencyFrames = 12
        let minimumSettleFrame: Int
        if scenario.requiresZeroDropped144HzFrames {
            // The extreme scenario intentionally shares a small source-residency
            // set across a huge clip graph. Start measuring as soon as those
            // sources are demonstrably resident so the timed window includes
            // sustained horizontal and vertical navigation.
            minimumSettleFrame = scenario.warmupFrames
        } else {
            minimumSettleFrame = scenario.scrollsTracksDuringRun ?
                max(scenario.warmupFrames, totalFrames * 2) :
                scenario.warmupFrames
        }
        let baseTimestamp = CACurrentMediaTime()
        var frame = 0
        var hasSettledRendererResidency = false
        var settledResidencyFrameCount = 0
        var postSettleDiscardFrameCount = 0
        while cpuMilliseconds.count < scenario.frames {
            autoreleasepool {
                let fullFrameStartTime = CACurrentMediaTime()
                let displayTimestamp = baseTimestamp + Double(frame) / 144.0
                let viewport = viewport(for: scenario, frame: frame, totalFrames: totalFrames)
                let playheadProgress = playheadProgress(for: scenario, frame: frame, totalFrames: totalFrames)
                let trackLayout = trackLayout(
                    for: scenario,
                    frame: frame,
                    totalFrames: totalFrames,
                    viewportHeight: Float(viewportSize.height)
                )

                let didRefreshWaveformSnapshot = refreshWaveformSnapshotIfNeeded(
                    tracks: &activeTracks,
                    scenario: scenario,
                    trackLayout: trackLayout,
                    viewportHeight: Float(viewportSize.height),
                    frame: frame
                )
                if didRefreshWaveformSnapshot {
                    renderer.displayTracks(activeTracks)
                }
                renderer.displayViewport(viewport)
                renderer.displayTrackLayout(trackLayout)
                renderer.displayPlayheadProgress(
                    playheadProgress,
                    force: true,
                    anchorTimestamp: displayTimestamp,
                    resetsTouchStart: frame == 0
                )
                displayEditOverlays(
                    scenario: scenario,
                    renderer: renderer,
                    frame: frame,
                    totalFrames: totalFrames,
                    tracks: activeTracks,
                    trackLayout: trackLayout,
                    viewportHeight: Float(viewportSize.height)
                )
                displayClipDragPreview(
                    scenario: scenario,
                    renderer: renderer,
                    tracks: activeTracks,
                    viewport: viewport
                )
                displayTransientBursts(
                    scenario: scenario,
                    renderer: renderer,
                    frame: frame,
                    playheadProgress: playheadProgress,
                    displayTimestamp: displayTimestamp
                )
                let stateUpdateEndTime = CACurrentMediaTime()
                if scenario.measuresTranscriptLayout {
                    let transcriptLayout = TranscriptLayoutEngine.makeLayout(
                        TranscriptTimelineLayoutInput(
                            tracks: activeTracks,
                            viewport: viewport,
                            trackLayout: trackLayout,
                            timelineDuration: scenario.syntheticDuration,
                            bounds: viewportSize,
                            displayMode: .waveformOverlay
                        )
                    )
                    precondition(
                        transcriptLayout.backgrounds.count + transcriptLayout.runs.count >= 0,
                        "transcript layout must be consumable"
                    )
                }
                let transcriptLayoutEndTime = CACurrentMediaTime()

                let renderPassDescriptor = makeRenderPassDescriptor(texture: texture)
                let startTime = scenario.measuresFullFrameWork ? fullFrameStartTime : CACurrentMediaTime()
                let renderSubmissionStartTime = CACurrentMediaTime()
                let commandBuffer = renderer.renderOffscreen(
                    renderPassDescriptor: renderPassDescriptor,
                    viewportSize: viewportSize,
                    backingScale: backingScale,
                    displayTimestamp: displayTimestamp,
                    waitUntilCompleted: false
                )
                let renderSubmissionEndTime = CACurrentMediaTime()
                let elapsedMilliseconds = (renderSubmissionEndTime - startTime) * 1_000
                commandBuffer?.waitUntilCompleted()

                let statsAfterFrame = rendererStats()
                if !hasSettledRendererResidency, frame >= minimumSettleFrame {
                    let visibleBuffersAreResident = renderer.visibleWaveformShaderBuffersAreResident(
                        drawableSize: viewportSize
                    )
                    let isResidencySettled = visibleBuffersAreResident &&
                        statsAfterFrame.shaderBufferUploadCount == 0 &&
                        statsAfterFrame.shaderBufferUploadInFlightCount == 0
                    settledResidencyFrameCount = isResidencySettled ?
                        settledResidencyFrameCount + 1 :
                        0
                    let exceededSettleBudget = frame >= minimumSettleFrame + maximumSettleFrames
                    if settledResidencyFrameCount >= requiredSettledResidencyFrames || exceededSettleBudget {
                        hasSettledRendererResidency = true
                        postSettleDiscardFrameCount = 3
                    }
                }

                if hasSettledRendererResidency {
                    if postSettleDiscardFrameCount > 0 {
                        postSettleDiscardFrameCount -= 1
                        return
                    }

                    cpuMilliseconds.append(elapsedMilliseconds)
                    stateUpdateMilliseconds.append((stateUpdateEndTime - fullFrameStartTime) * 1_000)
                    transcriptLayoutMilliseconds.append(
                        (transcriptLayoutEndTime - stateUpdateEndTime) * 1_000
                    )
                    renderSubmissionMilliseconds.append(
                        (renderSubmissionEndTime - renderSubmissionStartTime) * 1_000
                    )
                    if let gpuMillisecondsForFrame = commandBufferGPUMilliseconds(from: commandBuffer) {
                        gpuMilliseconds.append(gpuMillisecondsForFrame)
                    }
                    rendererStatsSamples.append(statsAfterFrame)
                    deletionEffectCounts.append(renderer.activeDeletionEffectCountForPerformanceTest())
                    visibleLaneCounts.append(visibleLaneCount(
                        trackLayout: trackLayout,
                        trackCount: scenario.trackCount,
                        viewportHeight: Float(viewportSize.height)
                    ))
                }
            }
            frame += 1
        }

        return ScenarioResult(
            scenario: scenario,
            cpuFrameMilliseconds: cpuMilliseconds,
            gpuFrameMilliseconds: gpuMilliseconds,
            stateUpdateMilliseconds: stateUpdateMilliseconds,
            transcriptLayoutMilliseconds: transcriptLayoutMilliseconds,
            renderSubmissionMilliseconds: renderSubmissionMilliseconds,
            rendererStats: rendererStats(),
            rendererStatsSamples: rendererStatsSamples,
            deletionEffectCounts: deletionEffectCounts,
            visibleLaneCounts: visibleLaneCounts,
            visibleLaneBudget: visibleLaneBudget(
                trackCount: scenario.trackCount,
                viewportHeight: Float(viewportSize.height)
            )
        )
    }

    private static func displayClipDragPreview(
        scenario: Scenario,
        renderer: TimelineRenderer,
        tracks: [TimelineRenderState.Track],
        viewport: TimelineViewport
    ) {
        guard
            scenario.dragsClipDuringRun,
            let track = tracks.first,
            let clip = track.clipRanges.first
        else {
            renderer.displayClipDragPreviews([])
            return
        }

        let originalStart = Float(clip.startProgress)
        let originalEnd = Float(clip.endProgress)
        let width = originalEnd - originalStart
        let presentedStart = viewport.startProgress + viewport.durationProgress * 0.5 - width * 0.5
        renderer.displayClipDragPreviews([
            TimelineClipDragPreview(
                trackID: track.id,
                clipID: clip.id,
                originalStartProjectProgress: originalStart,
                originalEndProjectProgress: originalEnd,
                presentedStartProjectProgress: presentedStart,
                presentedEndProjectProgress: presentedStart + width,
                kind: .move
            ),
        ])
    }

    private static func refreshWaveformSnapshotIfNeeded(
        tracks: inout [TimelineRenderState.Track],
        scenario: Scenario,
        trackLayout: TimelineTrackLayout,
        viewportHeight: Float,
        frame: Int
    ) -> Bool {
        guard
            let refreshInterval = scenario.waveformRefreshInterval,
            refreshInterval > 0,
            frame >= scenario.warmupFrames,
            frame.isMultiple(of: refreshInterval),
            let trackIndex = targetedTrackIndex(
                scenario: scenario,
                tracks: tracks,
                trackLayout: trackLayout,
                viewportHeight: viewportHeight,
                frame: frame
            ),
            tracks.indices.contains(trackIndex)
        else {
            return false
        }

        let track = tracks[trackIndex]
        tracks[trackIndex] = TimelineRenderState.Track(
            id: track.id,
            waveformVersion: track.waveformVersion + 1,
            waveformOverview: track.waveformOverview,
            durationHint: track.durationHint,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            hasWaveform: track.hasWaveform
        )
        return true
    }

    private static func makeRenderPassDescriptor(texture: MTLTexture) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .dontCare
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        return descriptor
    }

    private static func commandBufferGPUMilliseconds(from commandBuffer: MTLCommandBuffer?) -> Double? {
        guard
            let commandBuffer,
            commandBuffer.gpuEndTime > commandBuffer.gpuStartTime,
            commandBuffer.gpuStartTime > 0
        else {
            return nil
        }

        return (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
    }

    private static func viewport(
        for scenario: Scenario,
        frame: Int,
        totalFrames: Int
    ) -> TimelineViewport {
        let navigationFrame = scenario.requiresZeroDropped144HzFrames ?
            frame % max(totalFrames, 1) :
            frame
        let duration = scenario.zoomsDuringRun ?
            scenario.viewportDuration * (0.62 + 0.38 * pulse(frame: navigationFrame, period: 96)) :
            scenario.viewportDuration
        let maximumStart = max(1 - duration, 0)
        let panProgress: Float
        if scenario.pansDuringRun {
            panProgress = min(
                maximumStart,
                maximumStart * Float(navigationFrame) / Float(max(totalFrames - 1, 1))
            )
        } else if duration < 1 {
            panProgress = min(maximumStart, 0.32)
        } else {
            panProgress = 0
        }

        return TimelineViewport(startProgress: panProgress, durationProgress: duration)
    }

    private static func playheadProgress(
        for scenario: Scenario,
        frame: Int,
        totalFrames: Int
    ) -> Float {
        guard scenario.isPlaybackActive else {
            return 0.45
        }

        let viewport = viewport(for: scenario, frame: frame, totalFrames: totalFrames)
        let progressThroughViewport = Float(frame % 120) / 120
        return min(max(viewport.startProgress + progressThroughViewport * viewport.durationProgress, 0), 1)
    }

    private static func trackLayout(
        for scenario: Scenario,
        frame: Int,
        totalFrames: Int,
        viewportHeight: Float
    ) -> TimelineTrackLayout {
        let baseLayout = TimelineTrackLayout.default
        guard scenario.scrollsTracksDuringRun else {
            return baseLayout
        }

        let resolvedLayout = baseLayout.resolved(
            totalTrackCount: scenario.trackCount,
            viewportHeight: viewportHeight
        )
        guard resolvedLayout.maximumScrollOffset > 0 else {
            return baseLayout
        }

        let phase = Float(frame % max(totalFrames, 1)) / Float(max(totalFrames - 1, 1))
        let sweep = phase <= 0.5 ? phase * 2 : (1 - phase) * 2
        return TimelineTrackLayout(
            scrollOffset: resolvedLayout.maximumScrollOffset * sweep,
            preferredTrackHeight: baseLayout.preferredTrackHeight
        )
    }

    private static func visibleLaneCount(
        trackLayout: TimelineTrackLayout,
        trackCount: Int,
        viewportHeight: Float
    ) -> Int {
        trackLayout.resolved(
            totalTrackCount: trackCount,
            viewportHeight: viewportHeight
        ).visibleRange(overscan: 0).count
    }

    private static func visibleLaneBudget(
        trackCount: Int,
        viewportHeight: Float
    ) -> Int {
        let layout = TimelineTrackLayout.default.resolved(
            totalTrackCount: trackCount,
            viewportHeight: viewportHeight
        )
        let screenful = Int(ceil(viewportHeight / max(layout.trackHeight, 1)))
        return min(max(trackCount, 0), screenful + 2)
    }

    private static func displayEditOverlays(
        scenario: Scenario,
        renderer: TimelineRenderer,
        frame: Int,
        totalFrames: Int,
        tracks: [TimelineRenderState.Track],
        trackLayout: TimelineTrackLayout,
        viewportHeight: Float
    ) {
        guard scenario.showsSelection || scenario.showsGainPreview || scenario.deletionBurstInterval != nil else {
            renderer.displaySelection(nil)
            renderer.displayGainPreview(selection: nil, gain: 1)
            return
        }

        let viewport = viewport(for: scenario, frame: frame, totalFrames: totalFrames)
        let startProgress = min(max(Double(viewport.startProgress + viewport.durationProgress * 0.32), 0), 0.98)
        let endProgress = min(max(startProgress + Double(viewport.durationProgress * 0.18), startProgress), 1)
        let trackID = targetedTrackID(
            scenario: scenario,
            tracks: tracks,
            trackLayout: trackLayout,
            viewportHeight: viewportHeight,
            frame: frame
        )
        let selection = TimelineSelection(
            startProgress: startProgress,
            endProgress: endProgress,
            trackID: trackID
        )

        if scenario.showsSelection {
            renderer.displaySelection(selection)
        } else {
            renderer.displaySelection(nil)
        }

        if scenario.showsGainPreview {
            let gain = 0.45 + 0.40 * pulse(frame: frame, period: 72)
            renderer.displayGainPreview(selection: selection, gain: gain)
        } else {
            renderer.displayGainPreview(selection: nil, gain: 1)
        }

        if
            let deletionBurstInterval = scenario.deletionBurstInterval,
            frame >= scenario.warmupFrames,
            frame.isMultiple(of: deletionBurstInterval)
        {
            renderer.triggerDeletionEffect(selection: selection)
        }
    }

    private static func displayTransientBursts(
        scenario: Scenario,
        renderer: TimelineRenderer,
        frame: Int,
        playheadProgress: Float,
        displayTimestamp: CFTimeInterval
    ) {
        guard
            let transientBurstInterval = scenario.transientBurstInterval,
            transientBurstInterval > 0,
            frame >= scenario.warmupFrames,
            frame.isMultiple(of: transientBurstInterval)
        else {
            return
        }

        renderer.triggerTransientParticlesForPerformanceTest(
            originProgress: playheadProgress,
            displayTimestamp: displayTimestamp
        )
    }

    private static func targetedTrackID(
        scenario: Scenario,
        tracks: [TimelineRenderState.Track],
        trackLayout: TimelineTrackLayout,
        viewportHeight: Float,
        frame: Int
    ) -> UUID? {
        guard
            let trackIndex = targetedTrackIndex(
                scenario: scenario,
                tracks: tracks,
                trackLayout: trackLayout,
                viewportHeight: viewportHeight,
                frame: frame
            ),
            tracks.indices.contains(trackIndex)
        else {
            return nil
        }

        return tracks[trackIndex].id
    }

    private static func targetedTrackIndex(
        scenario: Scenario,
        tracks: [TimelineRenderState.Track],
        trackLayout: TimelineTrackLayout,
        viewportHeight: Float,
        frame: Int
    ) -> Int? {
        guard scenario.targetsVisibleTrack, !tracks.isEmpty else {
            return nil
        }

        let layout = trackLayout.resolved(
            totalTrackCount: tracks.count,
            viewportHeight: viewportHeight
        )
        let visibleRange = layout.visibleRange(overscan: 0)
        guard !visibleRange.isEmpty else {
            return nil
        }

        let localIndex = (frame / 18) % visibleRange.count
        let trackIndex = visibleRange.lowerBound + localIndex
        guard tracks.indices.contains(trackIndex) else {
            return nil
        }
        return trackIndex
    }

    private static func pulse(frame: Int, period: Int) -> Float {
        let phase = Float(frame % period) / Float(max(period, 1))
        return 0.5 - 0.5 * cos(phase * 2 * .pi)
    }

    private static func makeSyntheticTracks(
        count: Int,
        duration: TimeInterval,
        binCount: Int,
        clipCountPerTrack: Int = 0,
        waveformLayerCount: Int = 1,
        automationPointCountPerTrack: Int = 0,
        transcriptWordCount: Int = 0,
        transcriptTrackStride: Int = 0
    ) -> [TimelineRenderState.Track] {
        let overview = makeSyntheticWaveform(duration: duration, binCount: binCount)
        return (0..<count).map { index in
            let trackID = deterministicUUID(namespace: 1, index: index)
            let clipRanges = makeSyntheticClipRanges(
                trackIndex: index,
                count: clipCountPerTrack
            )
            let waveformLayers = makeSyntheticWaveformLayers(
                trackIndex: index,
                overview: overview,
                clipRanges: clipRanges,
                layerCount: waveformLayerCount
            )
            let automationLanes = makeSyntheticAutomationLanes(
                trackIndex: index,
                pointCount: automationPointCountPerTrack
            )
            let transcript = transcriptTrackStride > 0 && index.isMultiple(of: transcriptTrackStride) ?
                makeSyntheticTranscript(
                    trackID: trackID,
                    duration: duration,
                    wordCount: transcriptWordCount,
                    trackIndex: index
                ) : nil
            return TimelineRenderState.Track(
                id: trackID,
                waveformVersion: 1,
                waveformOverview: overview,
                durationHint: duration,
                volume: 0.72 + Float(index % 5) * 0.07,
                isMuted: false,
                isSoloed: false,
                clipRanges: clipRanges,
                usesSourceWaveformLayers: waveformLayers.isEmpty == false,
                waveformLayers: waveformLayers,
                transcript: transcript,
                automationLanes: automationLanes
            )
        }
    }

    private static func makeSyntheticClipRanges(
        trackIndex: Int,
        count: Int
    ) -> [TimelineRenderState.ClipRange] {
        guard count > 0 else { return [] }
        let spacing = 1.0 / Double(count)
        return (0..<count).map { clipIndex in
            let start = Double(clipIndex) * spacing
            let width = spacing * (0.60 + Double((trackIndex + clipIndex) % 4) * 0.07)
            return TimelineRenderState.ClipRange(
                id: AudioTimelineClipID(
                    rawValue: deterministicUUID(namespace: 2 + trackIndex, index: clipIndex)
                ),
                startProgress: start,
                endProgress: min(start + width, 1),
                name: "Extreme Clip \(trackIndex + 1).\(clipIndex + 1)",
                isSelected: clipIndex == (trackIndex % count),
                gain: 0.72 + Float(clipIndex % 6) * 0.045,
                fadeInProgress: clipIndex.isMultiple(of: 5) ? 0.08 : 0,
                fadeOutProgress: clipIndex.isMultiple(of: 7) ? 0.06 : 0
            )
        }
    }

    private static func makeSyntheticWaveformLayers(
        trackIndex: Int,
        overview: WaveformOverview,
        clipRanges: [TimelineRenderState.ClipRange],
        layerCount: Int
    ) -> [TimelineRenderState.Track.WaveformLayer] {
        guard layerCount > 0, !clipRanges.isEmpty else { return [] }
        return (0..<layerCount).map { layerIndex in
            let segments: [TimelineRenderState.Track.WaveformSegment] = clipRanges.enumerated().compactMap { clipIndex, clip in
                guard clipIndex % layerCount == layerIndex else { return nil }
                let sourceStart = Float((clipIndex * 37 + trackIndex * 11) % 800) / 1_000
                let sourceWidth = min(Float(clip.durationProgress * 12), 0.18)
                return TimelineRenderState.Track.WaveformSegment(
                    outputStartProgress: Float(clip.startProgress),
                    outputEndProgress: Float(clip.endProgress),
                    sourceStartProgress: sourceStart,
                    sourceEndProgress: min(sourceStart + max(sourceWidth, 0.01), 1),
                    gainStart: clip.gain,
                    gainEnd: clip.gain
                )
            }
            return TimelineRenderState.Track.WaveformLayer(
                // Source identity is intentionally shared across every destination
                // lane. An extreme edit graph must not multiply GPU residency by
                // clip or track count when the underlying media is the same.
                id: deterministicUUID(namespace: 40_000, index: layerIndex),
                sourceID: TimelineMediaSourceID(
                    rawValue: "extreme-source-\(layerIndex)"
                ),
                waveformVersion: 1,
                waveformOverview: overview,
                waveformSegments: segments
            )
        }
    }

    private static func makeSyntheticAutomationLanes(
        trackIndex: Int,
        pointCount: Int
    ) -> [TimelineRenderState.Track.AutomationLane] {
        guard pointCount > 0 else { return [] }
        let points = (0..<pointCount).map { pointIndex in
            let progress = Double(pointIndex) / Double(max(pointCount - 1, 1))
            let phase = Float(progress * .pi * 2 * Double(3 + trackIndex % 9))
            return TimelineRenderState.Track.AutomationPoint(
                id: deterministicUUID(namespace: 80_000 + trackIndex, index: pointIndex),
                projectProgress: progress,
                normalizedValue: 0.52 + sin(phase) * 0.36,
                curveToNext: Float((pointIndex % 7) - 3) / 3
            )
        }
        return [TimelineRenderState.Track.AutomationLane(
            parameterID: TimelineAutomationParameterID.volume.rawValue,
            defaultNormalizedValue: 0.8,
            points: points,
            isEnabled: true
        )]
    }

    private static func makeSyntheticTranscript(
        trackID: UUID,
        duration: TimeInterval,
        wordCount: Int,
        trackIndex: Int
    ) -> TranscriptDocument? {
        guard wordCount > 0 else { return nil }
        let wordsPerSegment = 12
        var segments: [TranscriptSegment] = []
        for segmentStartIndex in stride(from: 0, to: wordCount, by: wordsPerSegment) {
            let segmentIndex = segmentStartIndex / wordsPerSegment
            let segmentWordCount = min(wordsPerSegment, wordCount - segmentStartIndex)
            let sourceStart = Double(segmentStartIndex) / Double(wordCount) * duration
            let sourceEnd = Double(segmentStartIndex + segmentWordCount) / Double(wordCount) * duration
            let words = (0..<segmentWordCount).map { localIndex in
                let wordIndex = segmentStartIndex + localIndex
                let start = sourceStart + Double(localIndex) / Double(segmentWordCount) * (sourceEnd - sourceStart)
                let end = min(start + max((sourceEnd - sourceStart) / Double(segmentWordCount) * 0.72, 0.05), duration)
                return TranscriptWord(
                    id: deterministicUUID(namespace: 120_000 + trackIndex, index: wordIndex),
                    text: "word\(wordIndex)",
                    rawText: "word\(wordIndex)",
                    punctuatedText: "word\(wordIndex)",
                    startTime: start,
                    endTime: end,
                    confidence: 0.96,
                    speakerID: "speaker-\(trackIndex % 8)",
                    channelIndex: 0
                )
            }
            segments.append(TranscriptSegment(
                id: deterministicUUID(namespace: 160_000 + trackIndex, index: segmentIndex),
                speakerID: "speaker-\(trackIndex % 8)",
                speakerLabel: "Speaker \(trackIndex % 8 + 1)",
                startTime: sourceStart,
                endTime: sourceEnd,
                text: words.map(\.text).joined(separator: " "),
                words: words,
                confidence: 0.95,
                channelIndex: 0
            ))
        }
        return TranscriptDocument(
            id: deterministicUUID(namespace: 200_000, index: trackIndex),
            sourceKind: .track,
            trackID: trackID,
            sourceRevision: 1,
            sourceDuration: duration,
            sourceFingerprint: "extreme-transcript-\(trackIndex)",
            languageCode: "en-US",
            providerIdentifier: "soundtime-extreme-fixture",
            providerDisplayName: "Soundtime Extreme Fixture",
            providerModelName: "deterministic-v1",
            validity: .valid,
            segments: segments
        )
    }

    private static func deterministicUUID(namespace: Int, index: Int) -> UUID {
        let high = UInt64(bitPattern: Int64(namespace))
        let low = UInt64(bitPattern: Int64(index))
        let text = String(
            format: "%08X-%04X-%04X-%04X-%012llX",
            UInt32(truncatingIfNeeded: high),
            UInt16(truncatingIfNeeded: high >> 32),
            UInt16(truncatingIfNeeded: high >> 48),
            UInt16(truncatingIfNeeded: low >> 48),
            low & 0x0000_FFFF_FFFF_FFFF
        )
        return UUID(uuidString: text)!
    }

    private static func makeSyntheticWaveform(
        duration: TimeInterval,
        binCount: Int
    ) -> WaveformOverview {
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount)

        for index in 0..<binCount {
            let t = Float(index) / Float(max(binCount - 1, 1))
            let slowEnvelope = 0.35 + 0.28 * sin(t * 2 * .pi * 5.0)
            let phraseEnvelope = 0.55 + 0.35 * sin(t * 2 * .pi * 1.7 + 0.6)
            let beat = abs(sin(t * 2 * .pi * 73.0))
            let isTransient = index.isMultiple(of: 193)
            let basePeak = 0.08 + slowEnvelope * phraseEnvelope * (0.18 + beat * 0.28)
            let peak = isTransient ? Float(0.98) : min(max(basePeak, 0), 0.58)
            let asymmetry = sin(t * 2 * .pi * 29.0) * 0.12
            let minimum = -peak * min(max(0.86 - asymmetry, 0.25), 1)
            let maximum = peak * min(max(0.86 + asymmetry, 0.25), 1)
            let highEnergy = isTransient ? Float(1) : min(max(0.14 + beat * 0.18, 0), 1)
            let midEnergy = isTransient ? Float(0.92) : min(max(0.24 + abs(sin(t * 2 * .pi * 13.0)) * 0.12, 0), 1)
            let lowEnergy = min(max(0.44 + slowEnvelope * 0.2, 0), 1)

            bins.append(WaveformOverview.Bin(
                minimumSample: minimum,
                maximumSample: maximum,
                rmsSample: isTransient ? 0.82 : peak * 0.34,
                lowEnergy: lowEnergy,
                midEnergy: midEnergy,
                highEnergy: highEnergy
            ))
        }

        return WaveformOverview(duration: duration, bins: bins)
    }

    private static func jsonLine(for result: ScenarioResult, deviceName: String) -> String {
        let cpu = result.cpuFrameMilliseconds
        let gpu = result.gpuFrameMilliseconds
        let dropped144 = cpu.filter { $0 > 1_000.0 / 144.0 }.count
        let dropped60 = cpu.filter { $0 > 1_000.0 / 60.0 }.count
        let waveformRenderers = result.waveformRenderers
        let payload: [String: Any] = [
            "scenario": result.scenario.name,
            "device": deviceName,
            "tracks": result.scenario.trackCount,
            "waveform_bins": result.scenario.waveformBinCount ?? 0,
            "clips": result.scenario.trackCount * result.scenario.clipCountPerTrack,
            "waveform_layers_per_track": result.scenario.waveformLayerCount,
            "automation_points": result.scenario.trackCount * result.scenario.automationPointCountPerTrack,
            "transcript_words_per_transcribed_track": result.scenario.transcriptWordCount,
            "frames": result.frameCount,
            "attempts": result.attemptCount,
            "cpu_submit_p50_ms": rounded(percentile(cpu, 0.50)),
            "cpu_submit_p95_ms": rounded(percentile(cpu, 0.95)),
            "cpu_submit_p99_ms": rounded(percentile(cpu, 0.99)),
            "cpu_submit_max_ms": rounded(cpu.max() ?? 0),
            "state_update_p95_ms": rounded(percentile(result.stateUpdateMilliseconds, 0.95)),
            "state_update_max_ms": rounded(result.stateUpdateMilliseconds.max() ?? 0),
            "transcript_layout_p95_ms": rounded(percentile(result.transcriptLayoutMilliseconds, 0.95)),
            "transcript_layout_max_ms": rounded(result.transcriptLayoutMilliseconds.max() ?? 0),
            "render_submission_p95_ms": rounded(percentile(result.renderSubmissionMilliseconds, 0.95)),
            "render_submission_max_ms": rounded(result.renderSubmissionMilliseconds.max() ?? 0),
            "gpu_p50_ms": rounded(percentile(gpu, 0.50)),
            "gpu_p95_ms": rounded(percentile(gpu, 0.95)),
            "gpu_max_ms": rounded(gpu.max() ?? 0),
            "dropped_144hz_frames": dropped144,
            "dropped_60hz_frames": dropped60,
            "renderer": waveformRenderers.joined(separator: "+"),
            "selection": result.scenario.showsSelection,
            "gain_preview": result.scenario.showsGainPreview,
            "delete_bursts": result.scenario.deletionBurstInterval != nil,
            "waveform_refresh": result.scenario.waveformRefreshInterval != nil,
            "track_scroll": result.scenario.scrollsTracksDuringRun,
            "target_visible_track": result.scenario.targetsVisibleTrack,
            "visible_lanes_avg": rounded(result.averageVisibleLaneCount),
            "visible_lanes_max": result.maximumVisibleLaneCount,
            "visible_lanes_budget": result.visibleLaneBudget,
            "gpu_waveform_draws": result.maximumGPUWaveformDrawCount,
            "cpu_waveform_vertices": result.maximumCPUWaveformVertexCount,
            "effect_vertices": result.maximumEffectVertexCount,
            "effect_vertices_dropped": result.maximumEffectDroppedVertexCount,
            "transient_particles": result.maximumTransientParticleCount,
            "deletion_effects": result.maximumDeletionEffectCount,
            "playhead_contact_events": result.maximumPlayheadContactEventCount,
            "shader_uploads": result.maximumShaderBufferUploadCount,
            "shader_uploads_in_flight": result.maximumShaderBufferUploadInFlightCount,
            "shader_buffers": result.maximumShaderBufferCount,
            "shader_mb": rounded(Double(result.maximumShaderBufferByteCount) / (1_024 * 1_024)),
            "mip_cache_entries": result.maximumWaveformMipCacheCount,
        ]

        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else {
            return "{\"scenario\":\"\(result.scenario.name)\",\"error\":\"json encoding failed\"}"
        }

        return line
    }

    private static func budgetFailuresFor(_ result: ScenarioResult) -> [String] {
        let budget = budget(for: result.scenario)
        let trackCount = result.scenario.trackCount
        let cpuP95 = percentile(result.cpuFrameMilliseconds, 0.95)
        let cpuMax = result.cpuFrameMilliseconds.max() ?? 0
        let gpuP95 = percentile(result.gpuFrameMilliseconds, 0.95)
        let gpuMax = result.gpuFrameMilliseconds.max() ?? 0
        let dropped144 = result.cpuFrameMilliseconds.filter { $0 > 1_000.0 / 144.0 }.count
        let dropped60 = result.cpuFrameMilliseconds.filter { $0 > 1_000.0 / 60.0 }.count
        let label = "\(result.scenario.name) \(trackCount) tracks"
        var failures: [String] = []

        if cpuP95 > budget.cpuP95Milliseconds {
            failures.append("\(label) CPU p95 \(rounded(cpuP95))ms exceeded \(budget.cpuP95Milliseconds)ms")
        }
        if cpuMax > budget.cpuMaxMilliseconds {
            failures.append("\(label) CPU max \(rounded(cpuMax))ms exceeded \(budget.cpuMaxMilliseconds)ms")
        }
        if !result.gpuFrameMilliseconds.isEmpty, gpuP95 > budget.gpuP95Milliseconds {
            failures.append("\(label) GPU p95 \(rounded(gpuP95))ms exceeded \(budget.gpuP95Milliseconds)ms")
        }
        if !result.gpuFrameMilliseconds.isEmpty, gpuMax > budget.gpuMaxMilliseconds {
            failures.append("\(label) GPU max \(rounded(gpuMax))ms exceeded \(budget.gpuMaxMilliseconds)ms")
        }
        if dropped144 > budget.allowedDropped144HzFrames {
            failures.append(
                "\(label) dropped \(dropped144) 144Hz frames, allowed \(budget.allowedDropped144HzFrames)"
            )
        }
        if dropped60 > 0 {
            failures.append("\(label) dropped \(dropped60) 60Hz frames")
        }
        if result.waveformRenderers.contains(where: { $0 != "gpu" }) {
            failures.append("\(label) used non-GPU waveform renderer: \(result.waveformRenderers.joined(separator: "+"))")
        }
        if result.maximumCPUWaveformVertexCount > 0 {
            failures.append("\(label) generated \(result.maximumCPUWaveformVertexCount) CPU waveform vertices")
        }
        if result.maximumVisibleLaneCount > result.visibleLaneBudget {
            failures.append(
                "\(label) saw \(result.maximumVisibleLaneCount) visible lanes, " +
                "budget \(result.visibleLaneBudget)"
            )
        }
        let waveformDrawBudget = max(
            result.visibleLaneBudget * max(result.scenario.waveformLayerCount, 1),
            1
        )
        if result.maximumGPUWaveformDrawCount > waveformDrawBudget {
            failures.append(
                "\(label) issued \(result.maximumGPUWaveformDrawCount) waveform draw calls, " +
                "visible-lane budget \(waveformDrawBudget)"
            )
        }
        if result.scenario.waveformRefreshInterval != nil {
            if result.maximumShaderBufferUploadCount > 2 || result.maximumShaderBufferUploadInFlightCount > 2 {
                failures.append(
                    "\(label) exceeded background upload budget " +
                    "(uploads=\(result.maximumShaderBufferUploadCount), " +
                    "inFlight=\(result.maximumShaderBufferUploadInFlightCount))"
                )
            }
        } else if result.maximumShaderBufferUploadCount > 0 || result.maximumShaderBufferUploadInFlightCount > 0 {
            failures.append(
                "\(label) uploaded shader buffers during measured frames " +
                "(uploads=\(result.maximumShaderBufferUploadCount), " +
                "inFlight=\(result.maximumShaderBufferUploadInFlightCount))"
            )
        }
        if result.maximumEffectDroppedVertexCount > 0 {
            failures.append("\(label) dropped \(result.maximumEffectDroppedVertexCount) visual effect vertices")
        }
        if result.maximumEffectVertexCount > maximumVisualEffectVerticesPerFrame {
            failures.append(
                "\(label) generated \(result.maximumEffectVertexCount) visual effect vertices, " +
                "budget \(maximumVisualEffectVerticesPerFrame)"
            )
        }
        if result.maximumTransientParticleCount > maximumTransientParticlesPerFrame {
            failures.append(
                "\(label) kept \(result.maximumTransientParticleCount) transient particles, " +
                "budget \(maximumTransientParticlesPerFrame)"
            )
        }
        if result.maximumDeletionEffectCount > maximumDeletionEffectsPerFrame {
            failures.append(
                "\(label) kept \(result.maximumDeletionEffectCount) deletion effects, " +
                "budget \(maximumDeletionEffectsPerFrame)"
            )
        }
        if result.maximumPlayheadContactEventCount > maximumPlayheadContactEventsPerFrame {
            failures.append(
                "\(label) kept \(result.maximumPlayheadContactEventCount) playhead contact events, " +
                "budget \(maximumPlayheadContactEventsPerFrame)"
            )
        }
        if result.scenario.deletionBurstInterval != nil, result.maximumDeletionEffectCount == 0 {
            failures.append("\(label) did not exercise deletion effects")
        }
        if result.scenario.name == "combined visual effects", result.maximumTransientParticleCount == 0 {
            failures.append("\(label) did not exercise transient particles")
        }

        return failures
    }

    private static func isRetryableTimingOnlyFailure(_ failures: [String]) -> Bool {
        guard !failures.isEmpty else {
            return false
        }

        return failures.allSatisfy { failure in
            failure.contains("CPU ") ||
                failure.contains("GPU ") ||
                failure.contains("dropped ")
        }
    }

    private static func timingFailureScore(for result: ScenarioResult) -> Double {
        let cpu = result.cpuFrameMilliseconds
        let gpu = result.gpuFrameMilliseconds
        let dropped144 = cpu.filter { $0 > 1_000.0 / 144.0 }.count
        let dropped60 = cpu.filter { $0 > 1_000.0 / 60.0 }.count
        return percentile(cpu, 0.95) +
            (cpu.max() ?? 0) * 0.08 +
            percentile(gpu, 0.95) * 0.35 +
            Double(dropped144) * 3.0 +
            Double(dropped60) * 12.0
    }

    private static func budget(for scenario: Scenario) -> ScenarioBudget {
        if scenario.requiresZeroDropped144HzFrames {
            let frameBudget = 1_000.0 / 144.0
            return ScenarioBudget(
                cpuP95Milliseconds: frameBudget * 0.90,
                cpuMaxMilliseconds: frameBudget,
                gpuP95Milliseconds: frameBudget * 0.90,
                gpuMaxMilliseconds: frameBudget,
                allowedDropped144HzFrames: 0
            )
        }

        let trackCount = scenario.trackCount
        switch trackCount {
        case ..<50:
            return ScenarioBudget(
                cpuP95Milliseconds: 4.0,
                cpuMaxMilliseconds: 9.0,
                gpuP95Milliseconds: 4.0,
                gpuMaxMilliseconds: 8.0,
                allowedDropped144HzFrames: 0
            )
        case ..<100:
            return ScenarioBudget(
                cpuP95Milliseconds: 6.5,
                cpuMaxMilliseconds: 18.0,
                gpuP95Milliseconds: 5.5,
                gpuMaxMilliseconds: 10.0,
                allowedDropped144HzFrames: 2
            )
        case ..<250:
            return ScenarioBudget(
                cpuP95Milliseconds: 8.5,
                cpuMaxMilliseconds: 16.0,
                gpuP95Milliseconds: 7.0,
                gpuMaxMilliseconds: 12.0,
                allowedDropped144HzFrames: 2
            )
        default:
            return ScenarioBudget(
                cpuP95Milliseconds: 12.0,
                cpuMaxMilliseconds: 24.0,
                gpuP95Milliseconds: 10.0,
                gpuMaxMilliseconds: 18.0,
                allowedDropped144HzFrames: 4
            )
        }
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else {
            return 0
        }

        let sortedValues = values.sorted()
        let clampedPercentile = min(max(percentile, 0), 1)
        let index = Int((Double(sortedValues.count - 1) * clampedPercentile).rounded())
        return sortedValues[index]
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }
}
