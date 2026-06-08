import Darwin
import Foundation
@preconcurrency import Metal
import QuartzCore

enum TimelineUXSmokeHarness {
    private struct RenderedFrame {
        let bytes: [UInt8]
        let summary: MetalPixelSmokeSummary
    }

    private final class FrameStatsBox {
        var samples: [TimelineFrameStats] = []
    }

    private enum SmokeError: Error, CustomStringConvertible {
        case metalDeviceUnavailable
        case textureUnavailable
        case renderFailed
        case checkFailed(String)

        var description: String {
            switch self {
            case .metalDeviceUnavailable:
                return "Metal device unavailable"
            case .textureUnavailable:
                return "Could not allocate timeline UX smoke render target"
            case .renderFailed:
                return "Timeline UX smoke render failed"
            case let .checkFailed(message):
                return message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SmokeError.metalDeviceUnavailable
        }

        let pixelFormat: MTLPixelFormat = .bgra8Unorm
        let viewportSize = CGSize(width: 960, height: 360)
        let backingScale: Float = 1
        let textureWidth = Int(viewportSize.width)
        let textureHeight = Int(viewportSize.height)
        let texture = try makeTexture(
            device: device,
            pixelFormat: pixelFormat,
            width: textureWidth,
            height: textureHeight
        )
        let renderer = try TimelineRenderer(device: device, pixelFormat: pixelFormat)
        let frameStatsBox = FrameStatsBox()
        renderer.onFrameStatsChanged = { stats in
            frameStatsBox.samples.append(stats)
        }

        let smokeDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let wavURL = smokeDirectory.appendingPathComponent("SoundtimeTimelineUXSmoke.wav")
        let projectURL = smokeDirectory.appendingPathComponent("SoundtimeTimelineUXSmoke.soundtime")
        let buffer = makeSyntheticAudioBuffer(url: wavURL)
        try WAVFileWriter.write(buffer, to: wavURL)
        let decodedBuffer = try WAVAudioDecoder.decode(url: wavURL)
        let waveformOverview = WaveformOverviewBuilder.build(from: decodedBuffer, targetBinCount: 4_096)
        let trackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000001") ?? UUID()
        let track = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 1,
            waveformOverview: waveformOverview,
            durationHint: waveformOverview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
        )

        var completedChecks: [String] = []
        func complete(_ name: String) {
            completedChecks.append(name)
            print("ok - \(name)")
        }

        try verifyKnownProjectRender(
            projectURL: projectURL,
            wavURL: wavURL,
            trackID: trackID,
            track: track,
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("known project render has visible waveform pixels")

        try verifySyntheticWAVImport(
            wavURL: wavURL,
            waveformOverview: waveformOverview,
            renderedTrack: track,
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("new project WAV import renders a track waveform")

        try verifyPlayheadAdvances(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("playback projects playhead movement visually")

        try verifySeekPlacesPlayhead(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("seek places playhead at expected timeline x")

        try verifyZoomChangesViewportRendering(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("zoom changes viewport rendering and keeps playhead mapped")

        try verifyPanChangesViewportRendering(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("pan changes viewport rendering and playhead x")

        try verifyUltraZoomStillRenders(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("ultra-zoom timeline render remains nonblank")

        try verifyMultipleTrackLanesRender(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("multi-track lane render keeps every visible lane alive")

        try verifyTrackLayoutGeometry()
        complete("track layout geometry keeps lanes aligned and hit-testable")

        try verifyScrolledTrackLanesRender(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("scrolled multi-track render keeps visible lanes alive")

        try verifySelectionDragUpdatesStayResponsive(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("rapid selection drag updates stay responsive and visible")

        try verifyDeletionEffectLifecycle(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("delete animation effect appears and expires")

        try verifyHitTestingMathSurvivesDurationChanges()
        complete("timeline hit-testing maps clicked x before and after edits")

        try verifyRenderLoopStatsStayAlive(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            frameStatsBox: frameStatsBox
        )
        complete("render-loop frame stats publish during interaction/playback")

        try MainActor.assumeIsolated {
            try verifyMainFPSGraphPixels()
            try verifyPerformanceDashboardGraphPixels()
        }
        complete("main FPS graph draws visible cyan/red pixels")
        complete("performance monitor FPS/CPU graphs draw visible pixels")

        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "timeline-ux-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: completedChecks,
            metadata: [
                "viewportWidth": "\(textureWidth)",
                "viewportHeight": "\(textureHeight)",
                "syntheticWAV": wavURL.path,
            ],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }
        print("Soundtime timeline UX smoke passed: \(completedChecks.count) checks")
    }

    private static func verifyKnownProjectRender(
        projectURL: URL,
        wavURL: URL,
        trackID: UUID,
        track: TimelineRenderState.Track,
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let project = SoundtimeProject(
            tracks: [
                SoundtimeProject.Track(
                    id: trackID,
                    name: "UX Smoke",
                    filePath: wavURL.path,
                    volume: 1,
                    isMuted: false,
                    isSoloed: false,
                    editTimeline: nil
                ),
            ],
            windowLayout: SoundtimeProject.WindowLayout(x: 40, y: 40, width: 1_200, height: 720),
            masterVolume: 0.9,
            timelineViewport: SoundtimeProject.TimelineViewport(startProgress: 0, durationProgress: 1)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: projectURL, options: [.atomic])
        let restoredProject = try SoundtimeProjectStore.load(from: projectURL)
        try require(restoredProject.tracks.count == 1, "known project did not restore one track")
        try require(restoredProject.tracks.first?.filePath == wavURL.path, "known project restored the wrong WAV path")

        let frame = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: .full,
            playheadProgress: 0,
            isPlaybackActive: false,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(frame.summary.brightPixelCount > 1_500, "known project render did not contain enough waveform pixels")
    }

    private static func verifySyntheticWAVImport(
        wavURL: URL,
        waveformOverview: WaveformOverview,
        renderedTrack: TimelineRenderState.Track,
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let fileInfo = try WAVAudioDecoder.inspect(url: wavURL)
        try require(fileInfo.frameCount > 0, "synthetic drag WAV had no frames")
        try require(!waveformOverview.bins.isEmpty, "synthetic drag WAV built an empty waveform")
        try require(renderedTrack.hasWaveform, "synthetic drag WAV did not create an interactive render track")

        let frame = try renderTimeline(
            renderer: renderer,
            tracks: [renderedTrack],
            viewport: .full,
            playheadProgress: 0.25,
            isPlaybackActive: false,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(frame.summary.nonBackgroundPixelCount > 10_000, "new project WAV render was effectively blank")
    }

    private static func verifyPlayheadAdvances(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let baseTimestamp = CACurrentMediaTime()
        let first = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: .full,
            playheadProgress: 0.10,
            isPlaybackActive: true,
            displayTimestamp: baseTimestamp + 0.05,
            playheadAnchorTimestamp: baseTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let second = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: .full,
            playheadProgress: 0.10,
            isPlaybackActive: true,
            displayTimestamp: baseTimestamp + 1.0,
            playheadAnchorTimestamp: baseTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let firstX = try requireValue(first.summary.cyanCentroidX, "play smoke could not find initial playhead pixels")
        let secondX = try requireValue(second.summary.cyanCentroidX, "play smoke could not find advanced playhead pixels")
        try require(secondX > firstX + 18, "playhead did not advance visually: \(firstX) -> \(secondX)")
    }

    private static func verifySeekPlacesPlayhead(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let frame = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: .full,
            playheadProgress: 0.75,
            isPlaybackActive: false,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try requireCyanX(frame.summary, expectedX: Double(frame.summary.width) * 0.75, tolerance: 42, label: "seek")
    }

    private static func verifyZoomChangesViewportRendering(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let full = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: .full,
            playheadProgress: 0.60,
            isPlaybackActive: false,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let zoomedViewport = TimelineViewport(startProgress: 0.45, durationProgress: 0.30)
        let zoomed = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: zoomedViewport,
            playheadProgress: 0.60,
            isPlaybackActive: false,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(pixelDifferenceCount(full.bytes, zoomed.bytes) > 4_000, "zoom did not materially change timeline pixels")
        let expectedX = Double(zoomed.summary.width) *
            Double(zoomedViewport.viewportProgress(forTimelineProgress: 0.60))
        try requireCyanX(zoomed.summary, expectedX: expectedX, tolerance: 42, label: "zoom")
    }

    private static func verifyPanChangesViewportRendering(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let firstViewport = TimelineViewport(startProgress: 0.10, durationProgress: 0.50)
        let secondViewport = firstViewport.panned(byProgress: 0.10)
        let first = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: firstViewport,
            playheadProgress: 0.35,
            isPlaybackActive: false,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let second = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: secondViewport,
            playheadProgress: 0.35,
            isPlaybackActive: false,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(pixelDifferenceCount(first.bytes, second.bytes) > 3_000, "pan did not materially change timeline pixels")
        let firstX = try requireValue(first.summary.cyanCentroidX, "pan smoke could not find first playhead")
        let secondX = try requireValue(second.summary.cyanCentroidX, "pan smoke could not find panned playhead")
        try require(secondX < firstX - 80, "panning did not move playhead left as viewport moved right: \(firstX) -> \(secondX)")
    }

    private static func verifyUltraZoomStillRenders(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let viewport = TimelineViewport(startProgress: 0.318, durationProgress: 0.004)
        let frame = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: viewport,
            playheadProgress: 0.3198,
            isPlaybackActive: false,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(frame.summary.nonBackgroundPixelCount > 9_000, "ultra-zoom timeline render went mostly blank")
        try require(frame.summary.brightPixelCount > 900, "ultra-zoom waveform was too dim to detect")
    }

    private static func verifyMultipleTrackLanesRender(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let tracks = [
            track,
            renderTrack(from: track, id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000002") ?? UUID(), volume: 0.72),
            renderTrack(from: track, id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000003") ?? UUID(), volume: 0.48),
        ]
        let frame = try renderTimeline(
            renderer: renderer,
            tracks: tracks,
            viewport: .full,
            playheadProgress: 0.40,
            isPlaybackActive: false,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let laneHeight = max(frame.summary.height / tracks.count, 1)
        for laneIndex in tracks.indices {
            let startRow = laneIndex * laneHeight
            let endRow = laneIndex == tracks.count - 1 ? frame.summary.height : min(startRow + laneHeight, frame.summary.height)
            let count = nonBackgroundPixelCount(inRows: startRow..<endRow, bytes: frame.bytes, width: frame.summary.width)
            try require(count > 2_500, "multi-track lane \(laneIndex) rendered too few waveform pixels: \(count)")
        }
    }

    private static func verifyTrackLayoutGeometry() throws {
        let threeTrackLayout = TimelineTrackLayout.default.resolved(totalTrackCount: 3, viewportHeight: 360)
        try require(abs(threeTrackLayout.trackHeight - 120) < 0.000_1, "3-track layout did not fill viewport equally")
        try require(abs(threeTrackLayout.contentHeight - 360) < 0.000_1, "3-track content height did not match viewport")
        try require(threeTrackLayout.maximumScrollOffset == 0, "3-track layout should not scroll")
        try require(threeTrackLayout.visibleRange(overscan: 0) == 0..<3, "3-track visible range was wrong")
        try require(threeTrackLayout.trackIndex(atYFromTop: 1) == 0, "top y did not hit first track")
        try require(threeTrackLayout.trackIndex(atYFromTop: 180) == 1, "middle y did not hit second track")
        try require(threeTrackLayout.trackIndex(atYFromTop: 359) == 2, "bottom y did not hit third track")

        let fiveTrackLayout = TimelineTrackLayout.default.resolved(totalTrackCount: 5, viewportHeight: 360)
        try require(
            abs(fiveTrackLayout.trackHeight - TimelineTrackLayout.defaultPreferredTrackHeight) < 0.000_1,
            "5-track layout did not use preferred track height"
        )
        try require(fiveTrackLayout.isScrollable, "5-track layout should scroll")
        try require(fiveTrackLayout.visibleRange(overscan: 0) == 0..<3, "5-track initial visible range was wrong")

        let scrolled = TimelineTrackLayout(scrollOffset: 260).resolved(totalTrackCount: 5, viewportHeight: 360)
        try require(scrolled.visibleRange(overscan: 0) == 1..<5, "scrolled visible range was wrong")
        try require(scrolled.trackIndex(atYFromTop: 1) == 1, "scrolled top y did not hit expected track")
        try require(scrolled.trackIndex(atYFromTop: 359) == 4, "scrolled bottom y did not hit expected track")

        for trackIndex in 0..<5 {
            guard let laneFrame = scrolled.laneFrame(forTrackIndex: trackIndex) else {
                throw SmokeError.checkFailed("missing lane frame for track \(trackIndex)")
            }
            try require(laneFrame.bottom > laneFrame.top, "lane \(trackIndex) had inverted geometry")
        }
    }

    private static func verifyScrolledTrackLanesRender(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let tracks = (0..<6).map { index in
            renderTrack(
                from: track,
                id: UUID(uuidString: String(format: "AAAAAAAA-BBBB-CCCC-DDDD-%012d", index + 10)) ?? UUID(),
                volume: 0.42 + Float(index) * 0.08
            )
        }
        let trackLayout = TimelineTrackLayout(scrollOffset: 222)
        let frame = try renderTimeline(
            renderer: renderer,
            tracks: tracks,
            viewport: .full,
            playheadProgress: 0.40,
            isPlaybackActive: false,
            trackLayout: trackLayout,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let resolvedLayout = trackLayout.resolved(
            totalTrackCount: tracks.count,
            viewportHeight: Float(frame.summary.height)
        )
        for trackIndex in resolvedLayout.visibleRange(overscan: 0) {
            guard let laneFrame = resolvedLayout.laneFrame(forTrackIndex: trackIndex), laneFrame.isVisible else {
                throw SmokeError.checkFailed("visible lane \(trackIndex) did not produce a visible lane frame")
            }

            let startRow = max(Int(floor(Float(frame.summary.height) * max(laneFrame.top, 0))), 0)
            let endRow = min(Int(ceil(Float(frame.summary.height) * min(laneFrame.bottom, 1))), frame.summary.height)
            let count = nonBackgroundPixelCount(
                inRows: startRow..<endRow,
                bytes: frame.bytes,
                width: frame.summary.width
            )
            try require(count > 1_800, "scrolled visible lane \(trackIndex) rendered too few pixels: \(count)")
        }
    }

    private static func verifySelectionDragUpdatesStayResponsive(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        var frameDurations: [Double] = []
        frameDurations.reserveCapacity(54)
        let baseTimestamp = CACurrentMediaTime()

        renderer.displayTracks([track], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default)
        renderer.displayViewport(.full)
        renderer.displayPlaybackActive(false)
        renderer.displayPlayheadProgress(
            0.04,
            force: true,
            anchorTimestamp: baseTimestamp,
            resetsTouchStart: true
        )

        let firstSelection = TimelineSelection(startProgress: 0.10, endProgress: 0.12, trackID: track.id)
        renderer.displaySelection(firstSelection)
        let firstFrame = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: .full,
            playheadProgress: 0.04,
            isPlaybackActive: false,
            displayTimestamp: baseTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        for warmupIndex in 0..<8 {
            renderer.displaySelection(TimelineSelection(
                startProgress: 0.10,
                endProgress: 0.14 + Double(warmupIndex) * 0.01,
                trackID: track.id
            ))
            let renderPassDescriptor = makeRenderPassDescriptor(texture: texture)
            _ = renderer.renderOffscreen(
                renderPassDescriptor: renderPassDescriptor,
                viewportSize: viewportSize,
                backingScale: backingScale,
                displayTimestamp: baseTimestamp + Double(warmupIndex + 1) / 144.0,
                waitUntilCompleted: true
            )
        }

        for frameIndex in 0..<54 {
            let t = Double(frameIndex) / 53.0
            let selection = TimelineSelection(
                startProgress: 0.10,
                endProgress: 0.12 + t * 0.68,
                trackID: track.id
            )
            renderer.displaySelection(selection)

            let renderPassDescriptor = makeRenderPassDescriptor(texture: texture)
            let startTime = CACurrentMediaTime()
            let commandBuffer = renderer.renderOffscreen(
                renderPassDescriptor: renderPassDescriptor,
                viewportSize: viewportSize,
                backingScale: backingScale,
                displayTimestamp: baseTimestamp + Double(frameIndex + 10) / 144.0,
                waitUntilCompleted: false
            )
            frameDurations.append((CACurrentMediaTime() - startTime) * 1_000)
            commandBuffer?.waitUntilCompleted()
        }

        renderer.displaySelection(TimelineSelection(startProgress: 0.10, endProgress: 0.80, trackID: track.id))
        let lastFrame = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: .full,
            playheadProgress: 0.04,
            isPlaybackActive: false,
            displayTimestamp: baseTimestamp + 1,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let p95Milliseconds = percentile(frameDurations, percentile: 0.95)
        let maxMilliseconds = frameDurations.max() ?? 0
        try require(
            p95Milliseconds < 2.5,
            String(format: "selection drag render p95 was too slow: %.2fms", p95Milliseconds)
        )
        try require(
            maxMilliseconds < 8,
            String(format: "selection drag render outlier was too slow: %.2fms", maxMilliseconds)
        )

        let changedPixels = pixelDifferenceCount(firstFrame.bytes, lastFrame.bytes, threshold: 8)
        renderer.displaySelection(nil)
        try require(changedPixels > 8_000, "selection drag did not visibly update final selection: \(changedPixels)")
    }

    private static func verifyDeletionEffectLifecycle(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        renderer.clearDeletionEffects()
        let selection = TimelineSelection(startProgress: 0.24, endProgress: 0.32, trackID: track.id)
        let baseTimestamp = CACurrentMediaTime()
        let baseFrame = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: .full,
            playheadProgress: 0.24,
            isPlaybackActive: false,
            displayTimestamp: baseTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        renderer.triggerDeletionEffect(selection: selection)
        let activeFrame = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: .full,
            playheadProgress: 0.24,
            isPlaybackActive: false,
            displayTimestamp: baseTimestamp + 0.02,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            pixelDifferenceCount(baseFrame.bytes, activeFrame.bytes, threshold: 12) > 1_500,
            "delete animation effect did not visibly alter the render"
        )

        let expiredFrame = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: .full,
            playheadProgress: 0.24,
            isPlaybackActive: false,
            displayTimestamp: baseTimestamp + 0.30,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            pixelDifferenceCount(baseFrame.bytes, expiredFrame.bytes, threshold: 12) < 600,
            "delete animation effect did not visually expire"
        )
        renderer.clearDeletionEffects()
    }

    private static func verifyHitTestingMathSurvivesDurationChanges() throws {
        let viewport = TimelineViewport(startProgress: 0.20, durationProgress: 0.50)
        let clickedViewportProgress: Float = 0.60
        let progressBeforeEdit = viewport.timelineProgress(forViewportProgress: clickedViewportProgress)
        try require(abs(progressBeforeEdit - 0.50) < 0.000_001, "pre-edit hit test mapped to \(progressBeforeEdit), expected 0.50")

        let durationBeforeEdit = 8.0
        let deletedDuration = 2.0
        let durationAfterEdit = durationBeforeEdit - deletedDuration
        let timeBeforeEdit = Double(progressBeforeEdit) * durationBeforeEdit
        let timeAfterEdit = Double(progressBeforeEdit) * durationAfterEdit
        try require(abs(timeBeforeEdit - 4.0) < 0.000_001, "pre-edit click time mismatch")
        try require(abs(timeAfterEdit - 3.0) < 0.000_001, "post-edit click time mismatch")

        let pannedViewport = viewport.panned(byProgress: 0.10)
        let progressAfterPan = pannedViewport.timelineProgress(forViewportProgress: clickedViewportProgress)
        try require(abs(progressAfterPan - 0.60) < 0.000_001, "panned hit test mapped to \(progressAfterPan), expected 0.60")
    }

    private static func verifyRenderLoopStatsStayAlive(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float,
        frameStatsBox: FrameStatsBox
    ) throws {
        frameStatsBox.samples.removeAll()
        let baseTimestamp = CACurrentMediaTime()
        for frameIndex in 0..<72 {
            let t = Float(frameIndex) / 71
            let viewport = TimelineViewport(startProgress: min(t * 0.30, 0.45), durationProgress: 0.42 - t * 0.12)
            renderer.displaySelection(TimelineSelection(
                startProgress: Double(0.20 + t * 0.08),
                endProgress: Double(0.30 + t * 0.08),
                trackID: track.id
            ))
            _ = try renderTimeline(
                renderer: renderer,
                tracks: [track],
                viewport: viewport,
                playheadProgress: 0.15 + t * 0.50,
                isPlaybackActive: true,
                displayTimestamp: baseTimestamp + Double(frameIndex) / 144.0,
                playheadAnchorTimestamp: baseTimestamp,
                texture: texture,
                viewportSize: viewportSize,
                backingScale: backingScale
            )
            usleep(8_000)
        }
        renderer.displaySelection(nil)
        try require(!frameStatsBox.samples.isEmpty, "renderer never published frame stats during liveness smoke")
        try require((frameStatsBox.samples.last?.framesPerSecond ?? 0) > 0, "renderer published non-positive FPS")
    }

    @MainActor
    private static func verifyMainFPSGraphPixels() throws {
        let calmSummary = try FrameRateHistoryView.smokeRenderPixelSummary(samples: [
            (timestamp: 1, framesPerSecond: 144),
            (timestamp: 8, framesPerSecond: 120),
            (timestamp: 16, framesPerSecond: 100),
        ])
        try require(calmSummary.cyanPixelCount > 12, "main FPS graph calm render had no cyan line")

        let dangerSummary = try FrameRateHistoryView.smokeRenderPixelSummary(samples: [
            (timestamp: 1, framesPerSecond: 144),
            (timestamp: 8, framesPerSecond: 70),
            (timestamp: 16, framesPerSecond: 55),
        ])
        try require(dangerSummary.redPixelCount > 12, "main FPS graph danger render had no red line")
    }

    @MainActor
    private static func verifyPerformanceDashboardGraphPixels() throws {
        let fpsSummary = try PerformanceDashboardWindowController.smokeRenderFPSGraphPixelSummary(values: [144, 120, 82, 70, 55])
        try require(fpsSummary.redPixelCount > 12, "performance monitor FPS graph had no red danger pixels")
        try require(fpsSummary.cyanPixelCount > 12 || fpsSummary.brightPixelCount > 12, "performance monitor FPS graph was blank")

        let cpuSummary = try PerformanceDashboardWindowController.smokeRenderCPUGraphPixelSummary(values: [10, 35, 82, 50, 125])
        try require(cpuSummary.brightPixelCount > 12, "performance monitor CPU graph was blank")
    }

    private static func renderTimeline(
        renderer: TimelineRenderer,
        tracks: [TimelineRenderState.Track],
        viewport: TimelineViewport,
        playheadProgress: Float,
        isPlaybackActive: Bool,
        displayTimestamp: CFTimeInterval = CACurrentMediaTime(),
        playheadAnchorTimestamp: CFTimeInterval? = nil,
        trackLayout: TimelineTrackLayout = .default,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws -> RenderedFrame {
        renderer.displayTracks(tracks, animateWaveformTransition: false)
        renderer.displayTrackLayout(trackLayout)
        renderer.displayViewport(viewport)
        renderer.displayPlaybackActive(isPlaybackActive)
        renderer.displayPlayheadProgress(
            playheadProgress,
            force: true,
            anchorTimestamp: playheadAnchorTimestamp ?? displayTimestamp,
            resetsTouchStart: true
        )

        let renderPassDescriptor = makeRenderPassDescriptor(texture: texture)
        guard renderer.renderOffscreen(
            renderPassDescriptor: renderPassDescriptor,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: displayTimestamp,
            waitUntilCompleted: true
        ) != nil else {
            throw SmokeError.renderFailed
        }

        let width = texture.width
        let height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(
            &bytes,
            bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        return RenderedFrame(
            bytes: bytes,
            summary: MetalPixelSmokeSummary.analyzeBGRA8(bytes, width: width, height: height)
        )
    }

    private static func makeSyntheticAudioBuffer(url: URL) -> DecodedAudioBuffer {
        let sampleRate = 48_000.0
        let frameCount = Int(sampleRate * 8)
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let t = Double(frame) / sampleRate
            let phrase = 0.35 + 0.65 * abs(sin(t * .pi * 0.72))
            let carrier = sin(t * .pi * 2 * 220) * 0.45 +
                sin(t * .pi * 2 * 443) * 0.22 +
                sin(t * .pi * 2 * 1_120) * 0.08
            let value = Float(max(min(carrier * phrase, 0.95), -0.95))
            left[frame] = value
            right[frame] = value * Float(0.86 + 0.10 * sin(t * .pi * 2 * 0.31))
        }

        return DecodedAudioBuffer(
            url: url,
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [left, right]
        )
    }

    private static func renderTrack(
        from track: TimelineRenderState.Track,
        id: UUID,
        volume: Float
    ) -> TimelineRenderState.Track {
        TimelineRenderState.Track(
            id: id,
            waveformVersion: track.waveformVersion,
            waveformOverview: track.waveformOverview,
            durationHint: track.durationHint,
            volume: volume,
            isMuted: false,
            isSoloed: false,
            clipRanges: track.clipRanges
        )
    }

    private static func makeTexture(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw SmokeError.textureUnavailable
        }
        texture.label = "Soundtime timeline UX smoke target"
        return texture
    }

    private static func makeRenderPassDescriptor(texture: MTLTexture) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        return descriptor
    }

    private static func pixelDifferenceCount(
        _ lhs: [UInt8],
        _ rhs: [UInt8],
        threshold: Int = 20
    ) -> Int {
        let pixelCount = min(lhs.count, rhs.count) / 4
        var count = 0
        for index in 0..<pixelCount {
            let byteIndex = index * 4
            let blueDelta = abs(Int(lhs[byteIndex]) - Int(rhs[byteIndex]))
            let greenDelta = abs(Int(lhs[byteIndex + 1]) - Int(rhs[byteIndex + 1]))
            let redDelta = abs(Int(lhs[byteIndex + 2]) - Int(rhs[byteIndex + 2]))
            if max(blueDelta, greenDelta, redDelta) > threshold {
                count += 1
            }
        }
        return count
    }

    private static func nonBackgroundPixelCount(
        inRows rows: Range<Int>,
        bytes: [UInt8],
        width: Int,
        backgroundLuminanceThreshold: Int = 34
    ) -> Int {
        guard width > 0, !rows.isEmpty else {
            return 0
        }

        var count = 0
        for row in rows {
            guard row >= 0 else {
                continue
            }
            let rowStart = row * width * 4
            guard rowStart >= 0, rowStart + width * 4 <= bytes.count else {
                continue
            }

            for column in 0..<width {
                let byteIndex = rowStart + column * 4
                let blue = Int(bytes[byteIndex])
                let green = Int(bytes[byteIndex + 1])
                let red = Int(bytes[byteIndex + 2])
                let luminance = (red * 54 + green * 183 + blue * 19) / 256
                if luminance > backgroundLuminanceThreshold {
                    count += 1
                }
            }
        }
        return count
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else {
            return 0
        }

        let sortedValues = values.sorted()
        let clampedPercentile = min(max(percentile, 0), 1)
        let index = min(
            max(Int((Double(sortedValues.count - 1) * clampedPercentile).rounded()), 0),
            sortedValues.count - 1
        )
        return sortedValues[index]
    }

    private static func requireCyanX(
        _ summary: MetalPixelSmokeSummary,
        expectedX: Double,
        tolerance: Double,
        label: String
    ) throws {
        let actualX = try requireValue(summary.cyanCentroidX, "\(label) render had no cyan playhead pixels")
        try require(
            abs(actualX - expectedX) <= tolerance,
            "\(label) playhead x \(actualX) was not within \(tolerance)px of expected \(expectedX)"
        )
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SmokeError.checkFailed(message)
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw SmokeError.checkFailed(message)
        }
        return value
    }
}
