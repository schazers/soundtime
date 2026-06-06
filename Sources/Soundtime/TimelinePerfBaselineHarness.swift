import Foundation
@preconcurrency import Metal
import QuartzCore

enum TimelinePerfBaselineHarness {
    private struct Scenario {
        let name: String
        let trackCount: Int
        let frames: Int
        let warmupFrames: Int
        let viewportDuration: Float
        let isPlaybackActive: Bool
        let pansDuringRun: Bool
        let zoomsDuringRun: Bool
        let showsSelection: Bool
        let showsGainPreview: Bool
        let deletionBurstInterval: Int?
    }

    private struct ScenarioResult {
        let scenario: Scenario
        let cpuFrameMilliseconds: [Double]
        let gpuFrameMilliseconds: [Double]
        let rendererStats: TimelineFrameStats
        let rendererStatsSamples: [TimelineFrameStats]

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

        var maximumShaderBufferUploadCount: Int {
            rendererStatsSamples.map(\.shaderBufferUploadCount).max() ?? rendererStats.shaderBufferUploadCount
        }

        var maximumShaderBufferUploadInFlightCount: Int {
            rendererStatsSamples.map(\.shaderBufferUploadInFlightCount).max() ??
                rendererStats.shaderBufferUploadInFlightCount
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

        let scenarios = makeScenarios(
            isQuick: isQuick,
            frames: scenarioFrames,
            warmupFrames: warmupFrames
        )

        print("Soundtime timeline perf baseline")
        print("device=\(device.name) mode=\(isQuick ? "quick" : "full") viewport=\(Int(viewportSize.width))x\(Int(viewportSize.height)) scale=\(backingScale) bins=\(syntheticBinCount)")

        var trackCache: [Int: [TimelineRenderState.Track]] = [:]
        var budgetFailures: [String] = []
        for scenario in scenarios {
            let tracks: [TimelineRenderState.Track]
            if let cachedTracks = trackCache[scenario.trackCount] {
                tracks = cachedTracks
            } else {
                tracks = makeSyntheticTracks(
                    count: scenario.trackCount,
                    duration: 360,
                    binCount: syntheticBinCount
                )
                trackCache[scenario.trackCount] = tracks
            }

            renderer.displayTracks(tracks)
            renderer.displayPlaybackActive(scenario.isPlaybackActive)

            let result = run(
                scenario: scenario,
                renderer: renderer,
                texture: texture,
                viewportSize: viewportSize,
                backingScale: backingScale,
                rendererStats: { renderer.currentFrameStatsSnapshot() }
            )
            print(jsonLine(for: result, deviceName: device.name))
            if enforcesBudgets {
                budgetFailures.append(contentsOf: budgetFailuresFor(result))
            }
        }

        if !budgetFailures.isEmpty {
            throw HarnessError.budgetExceeded(budgetFailures)
        }
    }

    private static func makeScenarios(
        isQuick: Bool,
        frames: Int,
        warmupFrames: Int
    ) -> [Scenario] {
        let trackCounts = isQuick ? [10, 50, 100] : [10, 50, 100, 250]
        return trackCounts.flatMap { trackCount in
            [
                Scenario(
                    name: "zoomed-out playback",
                    trackCount: trackCount,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 1,
                    isPlaybackActive: true,
                    pansDuringRun: false,
                    zoomsDuringRun: false,
                    showsSelection: false,
                    showsGainPreview: false,
                    deletionBurstInterval: nil
                ),
                Scenario(
                    name: "zoomed-in playback",
                    trackCount: trackCount,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 0.035,
                    isPlaybackActive: true,
                    pansDuringRun: false,
                    zoomsDuringRun: false,
                    showsSelection: false,
                    showsGainPreview: false,
                    deletionBurstInterval: nil
                ),
                Scenario(
                    name: "pan sweep",
                    trackCount: trackCount,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 0.12,
                    isPlaybackActive: false,
                    pansDuringRun: true,
                    zoomsDuringRun: false,
                    showsSelection: false,
                    showsGainPreview: false,
                    deletionBurstInterval: nil
                ),
                Scenario(
                    name: "zoom pulse",
                    trackCount: trackCount,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 0.18,
                    isPlaybackActive: true,
                    pansDuringRun: true,
                    zoomsDuringRun: true,
                    showsSelection: false,
                    showsGainPreview: false,
                    deletionBurstInterval: nil
                ),
                Scenario(
                    name: "edit overlays",
                    trackCount: trackCount,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 0.10,
                    isPlaybackActive: true,
                    pansDuringRun: true,
                    zoomsDuringRun: false,
                    showsSelection: true,
                    showsGainPreview: true,
                    deletionBurstInterval: nil
                ),
                Scenario(
                    name: "delete bursts",
                    trackCount: trackCount,
                    frames: frames,
                    warmupFrames: warmupFrames,
                    viewportDuration: 0.16,
                    isPlaybackActive: false,
                    pansDuringRun: true,
                    zoomsDuringRun: false,
                    showsSelection: false,
                    showsGainPreview: false,
                    deletionBurstInterval: isQuick ? 30 : 45
                ),
            ]
        }
    }

    private static func run(
        scenario: Scenario,
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float,
        rendererStats: () -> TimelineFrameStats
    ) -> ScenarioResult {
        var cpuMilliseconds: [Double] = []
        var gpuMilliseconds: [Double] = []
        var rendererStatsSamples: [TimelineFrameStats] = []
        cpuMilliseconds.reserveCapacity(scenario.frames)
        gpuMilliseconds.reserveCapacity(scenario.frames)
        rendererStatsSamples.reserveCapacity(scenario.frames)

        let totalFrames = scenario.warmupFrames + scenario.frames
        let maximumSettleFrames = 240
        let baseTimestamp = CACurrentMediaTime()
        var frame = 0
        var hasSettledRendererResidency = false
        while cpuMilliseconds.count < scenario.frames {
            autoreleasepool {
                let displayTimestamp = baseTimestamp + Double(frame) / 144.0
                let viewport = viewport(for: scenario, frame: frame, totalFrames: totalFrames)
                let playheadProgress = playheadProgress(for: scenario, frame: frame, totalFrames: totalFrames)

                renderer.displayViewport(viewport)
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
                    totalFrames: totalFrames
                )

                let renderPassDescriptor = makeRenderPassDescriptor(texture: texture)
                let startTime = CACurrentMediaTime()
                let commandBuffer = renderer.renderOffscreen(
                    renderPassDescriptor: renderPassDescriptor,
                    viewportSize: viewportSize,
                    backingScale: backingScale,
                    displayTimestamp: displayTimestamp,
                    waitUntilCompleted: false
                )
                let elapsedMilliseconds = (CACurrentMediaTime() - startTime) * 1_000
                commandBuffer?.waitUntilCompleted()

                let statsAfterFrame = rendererStats()
                if !hasSettledRendererResidency, frame >= scenario.warmupFrames {
                    let isResidencySettled = statsAfterFrame.shaderBufferUploadCount == 0 &&
                        statsAfterFrame.shaderBufferUploadInFlightCount == 0
                    let exceededSettleBudget = frame >= scenario.warmupFrames + maximumSettleFrames
                    if isResidencySettled || exceededSettleBudget {
                        hasSettledRendererResidency = true
                    }
                }

                if hasSettledRendererResidency {
                    cpuMilliseconds.append(elapsedMilliseconds)
                    if let gpuMillisecondsForFrame = commandBufferGPUMilliseconds(from: commandBuffer) {
                        gpuMilliseconds.append(gpuMillisecondsForFrame)
                    }
                    rendererStatsSamples.append(statsAfterFrame)
                }
            }
            frame += 1
        }

        return ScenarioResult(
            scenario: scenario,
            cpuFrameMilliseconds: cpuMilliseconds,
            gpuFrameMilliseconds: gpuMilliseconds,
            rendererStats: rendererStats(),
            rendererStatsSamples: rendererStatsSamples
        )
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
        let duration = scenario.zoomsDuringRun ?
            scenario.viewportDuration * (0.62 + 0.38 * pulse(frame: frame, period: 96)) :
            scenario.viewportDuration
        let maximumStart = max(1 - duration, 0)
        let panProgress: Float
        if scenario.pansDuringRun {
            panProgress = min(maximumStart, maximumStart * Float(frame) / Float(max(totalFrames - 1, 1)))
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

    private static func displayEditOverlays(
        scenario: Scenario,
        renderer: TimelineRenderer,
        frame: Int,
        totalFrames: Int
    ) {
        guard scenario.showsSelection || scenario.showsGainPreview || scenario.deletionBurstInterval != nil else {
            renderer.displaySelection(nil)
            renderer.displayGainPreview(selection: nil, gain: 1)
            return
        }

        let viewport = viewport(for: scenario, frame: frame, totalFrames: totalFrames)
        let startProgress = min(max(Double(viewport.startProgress + viewport.durationProgress * 0.32), 0), 0.98)
        let endProgress = min(max(startProgress + Double(viewport.durationProgress * 0.18), startProgress), 1)
        let selection = TimelineSelection(
            startProgress: startProgress,
            endProgress: endProgress,
            trackID: nil
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

    private static func pulse(frame: Int, period: Int) -> Float {
        let phase = Float(frame % period) / Float(max(period, 1))
        return 0.5 - 0.5 * cos(phase * 2 * .pi)
    }

    private static func makeSyntheticTracks(
        count: Int,
        duration: TimeInterval,
        binCount: Int
    ) -> [TimelineRenderState.Track] {
        let overview = makeSyntheticWaveform(duration: duration, binCount: binCount)
        return (0..<count).map { index in
            TimelineRenderState.Track(
                id: UUID(),
                waveformVersion: 1,
                waveformOverview: overview,
                durationHint: duration,
                volume: 0.72 + Float(index % 5) * 0.07,
                isMuted: false,
                isSoloed: false
            )
        }
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
            let transient = (index % 193) < 4 ? Float(0.34) : 0
            let peak = min(max(0.08 + slowEnvelope * phraseEnvelope * (0.22 + beat * 0.42) + transient, 0), 0.98)
            let asymmetry = sin(t * 2 * .pi * 29.0) * 0.12
            let minimum = -peak * min(max(0.86 - asymmetry, 0.25), 1)
            let maximum = peak * min(max(0.86 + asymmetry, 0.25), 1)
            let highEnergy = min(max(0.22 + beat * 0.52 + transient * 0.6, 0), 1)
            let midEnergy = min(max(0.34 + abs(sin(t * 2 * .pi * 13.0)) * 0.2, 0), 1)
            let lowEnergy = min(max(0.44 + slowEnvelope * 0.2, 0), 1)

            bins.append(WaveformOverview.Bin(
                minimumSample: minimum,
                maximumSample: maximum,
                rmsSample: peak * 0.48,
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
        let stats = result.rendererStats
        let waveformRenderers = result.waveformRenderers
        let payload: [String: Any] = [
            "scenario": result.scenario.name,
            "device": deviceName,
            "tracks": result.scenario.trackCount,
            "frames": result.frameCount,
            "cpu_submit_p50_ms": rounded(percentile(cpu, 0.50)),
            "cpu_submit_p95_ms": rounded(percentile(cpu, 0.95)),
            "cpu_submit_p99_ms": rounded(percentile(cpu, 0.99)),
            "cpu_submit_max_ms": rounded(cpu.max() ?? 0),
            "gpu_p50_ms": rounded(percentile(gpu, 0.50)),
            "gpu_p95_ms": rounded(percentile(gpu, 0.95)),
            "gpu_max_ms": rounded(gpu.max() ?? 0),
            "dropped_144hz_frames": dropped144,
            "dropped_60hz_frames": dropped60,
            "renderer": waveformRenderers.joined(separator: "+"),
            "selection": result.scenario.showsSelection,
            "gain_preview": result.scenario.showsGainPreview,
            "delete_bursts": result.scenario.deletionBurstInterval != nil,
            "gpu_waveform_draws": stats.gpuWaveformDrawCount,
            "cpu_waveform_vertices": result.maximumCPUWaveformVertexCount,
            "shader_uploads": result.maximumShaderBufferUploadCount,
            "shader_uploads_in_flight": result.maximumShaderBufferUploadInFlightCount,
            "shader_buffers": stats.shaderBufferCount,
            "shader_mb": rounded(Double(stats.shaderBufferByteCount) / (1_024 * 1_024)),
            "mip_cache_entries": stats.waveformMipCacheCount,
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
        let budget = budget(for: result.scenario.trackCount)
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
        if result.maximumShaderBufferUploadCount > 0 || result.maximumShaderBufferUploadInFlightCount > 0 {
            failures.append(
                "\(label) uploaded shader buffers during measured frames " +
                "(uploads=\(result.maximumShaderBufferUploadCount), " +
                "inFlight=\(result.maximumShaderBufferUploadInFlightCount))"
            )
        }

        return failures
    }

    private static func budget(for trackCount: Int) -> ScenarioBudget {
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
                cpuMaxMilliseconds: 12.0,
                gpuP95Milliseconds: 5.5,
                gpuMaxMilliseconds: 10.0,
                allowedDropped144HzFrames: 0
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
