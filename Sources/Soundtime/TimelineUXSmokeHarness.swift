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

        try verifyUltraZoomSparsePreviewStillRenders(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("ultra-zoom sparse preview render remains visible while final mip is pending")

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

        try verifyHoverGuideUpdatesStayResponsive(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("rapid hover guide updates stay responsive and visible")

        try verifyDeletionEffectLifecycle(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("delete animation effect appears and expires")

        try verifyDeleteAnimationKeepsLeftSideStable(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("delete animation keeps pre-selection waveform pixels stable")

        try verifyGroupedDeleteKeepsLargeWaveformsDetailed(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("grouped delete keeps large visible waveforms detailed")

        try verifyHitTestingMathSurvivesDurationChanges()
        complete("timeline hit-testing maps clicked x before and after edits")

        try verifyViewportPreservesAbsoluteTimeAfterDelete()
        complete("delete refresh preserves visible time window")

        try verifyDeleteSelectionDeletesExactFrameRange()
        complete("delete selection removes exact selected frame range")

        try verifyRenderLoopStatsStayAlive(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            frameStatsBox: frameStatsBox
        )
        complete("render-loop hot frames publish without CPU waveform fallback")

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

    private static func verifyUltraZoomSparsePreviewStillRenders(
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let overview = makeLongSparseWaveformOverview(duration: 480, binCount: 4_096)
        let track = TimelineRenderState.Track(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000099") ?? UUID(),
            waveformVersion: 1,
            waveformOverview: overview,
            durationHint: overview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
        )
        let viewport = TimelineViewport(startProgress: 0.516, durationProgress: 0.002)
        let frame = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: viewport,
            playheadProgress: 0.517,
            isPlaybackActive: false,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            frame.summary.nonBackgroundPixelCount > 1_500,
            "ultra-zoom sparse preview went blank before high-res waveform was ready"
        )
        try require(
            frame.summary.brightPixelCount > 120,
            "ultra-zoom sparse preview did not show detectable waveform pixels"
        )
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
        let expectedTrackViewportHeight = 360 - TimelineTrackLayout.defaultRulerLaneHeight
        try require(
            abs(threeTrackLayout.trackHeight - expectedTrackViewportHeight / 3) < 0.000_1,
            "3-track layout did not fill track viewport equally"
        )
        try require(
            abs(threeTrackLayout.contentHeight - expectedTrackViewportHeight) < 0.000_1,
            "3-track content height did not match track viewport"
        )
        try require(threeTrackLayout.maximumScrollOffset == 0, "3-track layout should not scroll")
        try require(threeTrackLayout.visibleRange(overscan: 0) == 0..<3, "3-track visible range was wrong")
        try require(threeTrackLayout.trackIndex(atYFromTop: 1) == nil, "ruler y should not hit a track")
        try require(threeTrackLayout.trackIndex(atYFromTop: 33) == 0, "first track y did not hit first track")
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
        try require(scrolled.visibleRange(overscan: 0) == 1..<4, "scrolled visible range was wrong")
        try require(scrolled.trackIndex(atYFromTop: 1) == nil, "scrolled ruler y should not hit a track")
        try require(scrolled.trackIndex(atYFromTop: 33) == 1, "scrolled first track y did not hit expected track")
        try require(scrolled.trackIndex(atYFromTop: 359) == 3, "scrolled bottom y did not hit expected track")

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
        renderer.publishInteractionSelection(firstSelection)
        renderer.publishInteractionSelectionDrag(
            firstSelection,
            leadingProgress: firstSelection.endProgressFloat,
            velocityPixelsPerSecond: 920,
            direction: 1,
            timestamp: baseTimestamp
        )
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
            let selection = TimelineSelection(
                startProgress: 0.10,
                endProgress: 0.14 + Double(warmupIndex) * 0.01,
                trackID: track.id
            )
            renderer.publishInteractionSelection(selection)
            renderer.publishInteractionSelectionDrag(
                selection,
                leadingProgress: selection.endProgressFloat,
                velocityPixelsPerSecond: 980,
                direction: 1,
                timestamp: baseTimestamp + Double(warmupIndex + 1) / 144.0
            )
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
            renderer.publishInteractionSelection(selection)
            renderer.publishInteractionSelectionDrag(
                selection,
                leadingProgress: selection.endProgressFloat,
                velocityPixelsPerSecond: 1_250,
                direction: 1,
                timestamp: baseTimestamp + Double(frameIndex + 10) / 144.0
            )

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

        let finalSelection = TimelineSelection(startProgress: 0.10, endProgress: 0.80, trackID: track.id)
        renderer.publishInteractionSelection(finalSelection)
        renderer.publishInteractionSelectionDrag(
            finalSelection,
            leadingProgress: finalSelection.endProgressFloat,
            velocityPixelsPerSecond: 1_250,
            direction: 1,
            timestamp: baseTimestamp + 0.5
        )
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

    private static func verifyHoverGuideUpdatesStayResponsive(
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

        renderer.displayHoverProgress(0.15, isArmed: true)
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
            renderer.displayHoverProgress(0.16 + Float(warmupIndex) * 0.01, isArmed: true)
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
            let t = Float(frameIndex) / 53.0
            renderer.displayHoverProgress(0.15 + t * 0.70, isArmed: true)

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

        renderer.displayHoverProgress(0.85, isArmed: true)
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
            String(format: "hover guide render p95 was too slow: %.2fms", p95Milliseconds)
        )
        try require(
            maxMilliseconds < 8,
            String(format: "hover guide render outlier was too slow: %.2fms", maxMilliseconds)
        )

        let changedPixels = pixelDifferenceCount(firstFrame.bytes, lastFrame.bytes, threshold: 8)
        renderer.displayHoverProgress(nil, isArmed: false)
        try require(changedPixels > 600, "hover guide did not visibly update final position: \(changedPixels)")
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
            displayTimestamp: baseTimestamp + 2.20,
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

    private static func verifyDeleteAnimationKeepsLeftSideStable(
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        renderer.clearDeletionEffects()
        let durationBeforeDelete = 20.0
        let selection = TimelineSelection(
            startProgress: 0.36,
            endProgress: 0.46,
            trackID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000901") ?? UUID()
        )
        let durationAfterDelete = durationBeforeDelete * (1 - selection.durationProgress)
        let overviewBeforeDelete = makeLongSparseWaveformOverview(
            duration: durationBeforeDelete,
            binCount: 4_096
        )
        let overviewAfterDelete = deleteOverview(
            overviewBeforeDelete,
            selection: selection,
            targetDuration: durationAfterDelete
        )
        let trackID = selection.trackID ?? UUID()
        let trackBeforeDelete = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 1,
            waveformOverview: overviewBeforeDelete,
            durationHint: durationBeforeDelete,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
        )
        let trackAfterDelete = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 2,
            waveformOverview: overviewAfterDelete,
            durationHint: durationAfterDelete,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
        )
        let viewportBeforeDelete = TimelineViewport(startProgress: 0.20, durationProgress: 0.40)
        let viewportAfterDelete = viewportBeforeDelete.preservingAbsoluteTimes(
            previousDuration: durationBeforeDelete,
            nextDuration: durationAfterDelete
        )
        let displayTimestamp = CACurrentMediaTime()
        let beforeFrame = try renderTimeline(
            renderer: renderer,
            tracks: [trackBeforeDelete],
            viewport: viewportBeforeDelete,
            playheadProgress: 0,
            isPlaybackActive: false,
            displayTimestamp: displayTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        renderer.triggerDeletionEffect(selection: selection)
        let afterFrame = try renderTimeline(
            renderer: renderer,
            tracks: [trackAfterDelete],
            viewport: viewportAfterDelete,
            playheadProgress: 0,
            isPlaybackActive: false,
            displayTimestamp: displayTimestamp + 0.035,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let width = texture.width
        let height = texture.height
        let selectionStartX = Int(
            (viewportBeforeDelete.viewportProgress(
                forTimelineProgress: selection.startProgressFloat
            ) * Float(width)).rounded(.down)
        )
        let stableColumns = 0..<max(selectionStartX - 128, 0)
        let laneRows = Int(Double(height) * 0.18)..<Int(Double(height) * 0.86)
        let changedPixels = brightPixelDifferenceCount(
            beforeFrame.bytes,
            afterFrame.bytes,
            width: width,
            columns: stableColumns,
            rows: laneRows,
            threshold: 18,
            minimumLuminance: 76
        )
        let stablePixelBudget = max(stableColumns.count * laneRows.count / 180, 24)
        try require(
            changedPixels <= stablePixelBudget,
            "delete animation changed \(changedPixels) stable left-side pixels, budget \(stablePixelBudget)"
        )
        renderer.clearDeletionEffects()
    }

    private static func verifyGroupedDeleteKeepsLargeWaveformsDetailed(
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        renderer.clearDeletionEffects()
        let durationBeforeDelete = 120.0
        let selection = TimelineSelection(startProgress: 0.34, endProgress: 0.40)
        let durationAfterDelete = durationBeforeDelete * (1 - selection.durationProgress)
        let viewportBeforeDelete = TimelineViewport(startProgress: 0.16, durationProgress: 0.54)
        let viewportAfterDelete = viewportBeforeDelete.preservingAbsoluteTimes(
            previousDuration: durationBeforeDelete,
            nextDuration: durationAfterDelete
        )
        let trackIDs = [
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000A01") ?? UUID(),
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000A02") ?? UUID(),
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000A03") ?? UUID(),
        ]
        let beforeTracks = trackIDs.enumerated().map { index, trackID in
            let overview = makeDetailedWaveformOverview(
                duration: durationBeforeDelete,
                binCount: 65_536,
                seed: UInt32(index + 11)
            )
            return TimelineRenderState.Track(
                id: trackID,
                waveformVersion: 10 + index,
                waveformOverview: overview,
                durationHint: durationBeforeDelete,
                volume: 1,
                isMuted: false,
                isSoloed: false,
                clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
            )
        }
        let displayTimestamp = CACurrentMediaTime()
        _ = try renderTimeline(
            renderer: renderer,
            tracks: beforeTracks,
            viewport: viewportBeforeDelete,
            playheadProgress: 0,
            isPlaybackActive: false,
            displayTimestamp: displayTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        renderer.prepareVisibleWaveformShaderBuffersForDeletion()
        let beforeFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: displayTimestamp + 0.08,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let afterTracks = beforeTracks.map { track in
            let sourceOverview = track.waveformOverview!
            let editedOverview = deleteOverview(
                sourceOverview,
                selection: selection,
                targetDuration: durationAfterDelete
            )
            return TimelineRenderState.Track(
                id: track.id,
                waveformVersion: track.waveformVersion + 100,
                waveformOverview: editedOverview,
                durationHint: durationAfterDelete,
                volume: track.volume,
                isMuted: false,
                isSoloed: false,
                clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
            )
        }
        for trackID in trackIDs {
            renderer.triggerDeletionEffect(
                selection: TimelineSelection(
                    startProgress: selection.startProgress,
                    endProgress: selection.endProgress,
                    trackID: trackID
                )
            )
        }
        let afterFrame = try renderTimeline(
            renderer: renderer,
            tracks: afterTracks,
            viewport: viewportAfterDelete,
            playheadProgress: 0,
            isPlaybackActive: false,
            displayTimestamp: displayTimestamp + 0.10,
            animateWaveformTransition: true,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let width = texture.width
        let height = texture.height
        let selectionStartX = Int(
            (viewportBeforeDelete.viewportProgress(
                forTimelineProgress: selection.startProgressFloat
            ) * Float(width)).rounded(.down)
        )
        let selectionEndX = Int(
            (viewportBeforeDelete.viewportProgress(
                forTimelineProgress: selection.endProgressFloat
            ) * Float(width)).rounded(.up)
        )
        let midAnimationFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: displayTimestamp + 0.76,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let movingColumns = min(selectionEndX + 18, width)..<width
        let movingRows = Int(Double(height) * 0.18)..<Int(Double(height) * 0.93)
        let movedPixels = pixelDifferenceCount(
            afterFrame.bytes,
            midAnimationFrame.bytes,
            width: width,
            columns: movingColumns,
            rows: movingRows,
            threshold: 12
        )
        try require(
            movedPixels > 500,
            "grouped delete only moved \(movedPixels) right-side pixels during the deletion animation"
        )
        let stableColumns = 0..<max(selectionStartX - 180, 0)
        let laneRows = Int(Double(height) * 0.18)..<Int(Double(height) * 0.93)
        let changedPixels = brightPixelDifferenceCount(
            beforeFrame.bytes,
            afterFrame.bytes,
            width: width,
            columns: stableColumns,
            rows: laneRows,
            threshold: 20,
            minimumLuminance: 58
        )
        let stablePixelBudget = max(stableColumns.count * laneRows.count / 80, 600)
        try require(
            changedPixels <= stablePixelBudget,
            "grouped delete changed \(changedPixels) stable high-detail pixels, budget \(stablePixelBudget)"
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

    private static func verifyDeleteSelectionDeletesExactFrameRange() throws {
        let frameCount = 120
        let samples = (0..<frameCount).map { Float($0) }
        let buffer = DecodedAudioBuffer(
            url: URL(fileURLWithPath: "/tmp/SoundtimeDeleteSelectionSmoke.wav"),
            sampleRate: 100,
            channelCount: 1,
            frameCount: frameCount,
            samplesByChannel: [samples]
        )
        let selection = TimelineSelection(startProgress: 0.25, endProgress: 0.50)

        var audioTimeline = AudioEditTimeline(sourceBuffer: buffer)
        let audioRange = audioTimeline.frameRange(for: selection)
        try require(audioRange == 30..<60, "audio delete frame range was \(audioRange), expected 30..<60")
        let audioDeletedFrames = audioTimeline.delete(selection)
        try require(audioDeletedFrames == 30, "audio delete removed \(audioDeletedFrames) frames, expected 30")
        let rendered = audioTimeline.render()
        try require(rendered.frameCount == 90, "audio delete rendered \(rendered.frameCount) frames, expected 90")
        let renderedSamples = rendered.samplesByChannel[0]
        try require(renderedSamples.count == 90, "audio delete sample count was \(renderedSamples.count), expected 90")
        for frame in 0..<30 {
            try require(renderedSamples[frame] == Float(frame), "audio delete changed frame \(frame)")
        }
        for frame in 30..<90 {
            let expected = Float(frame + 30)
            try require(renderedSamples[frame] == expected, "audio delete output frame \(frame) was \(renderedSamples[frame]), expected \(expected)")
        }

        guard var fileTimeline = AudioFileEditTimeline(
            sourceFrameCount: frameCount,
            sourceSampleRate: 100,
            playbackSegments: [
                AudioEditTimeline.PlaybackSegment(
                    outputStartFrame: 0,
                    sourceStartFrame: 0,
                    frameCount: frameCount,
                    sourceFrameScale: 1,
                    gainStart: 1,
                    gainEnd: 1
                ),
            ]
        ) else {
            throw SmokeError.checkFailed("could not construct file-backed delete timeline")
        }
        let fileRange = fileTimeline.frameRange(for: selection)
        try require(fileRange == 30..<60, "file delete frame range was \(fileRange), expected 30..<60")
        let fileDeletedFrames = fileTimeline.delete(selection)
        try require(fileDeletedFrames == 30, "file delete removed \(fileDeletedFrames) frames, expected 30")
        try require(fileTimeline.frameCount == 90, "file delete left \(fileTimeline.frameCount) frames, expected 90")
    }

    private static func verifyViewportPreservesAbsoluteTimeAfterDelete() throws {
        let beforeDuration = 120.0
        let afterDuration = 100.0
        let viewport = TimelineViewport(startProgress: 0.25, durationProgress: 0.25)
        let preserved = viewport.preservingAbsoluteTimes(
            previousDuration: beforeDuration,
            nextDuration: afterDuration
        )
        let preservedStartTime = Double(preserved.startProgress) * afterDuration
        let preservedVisibleDuration = Double(preserved.durationProgress) * afterDuration
        try require(
            abs(preservedStartTime - 30.0) < 0.000_1,
            "preserved viewport start time was \(preservedStartTime), expected 30s"
        )
        try require(
            abs(preservedVisibleDuration - 30.0) < 0.000_1,
            "preserved viewport duration was \(preservedVisibleDuration), expected 30s"
        )

        let nearEndViewport = TimelineViewport(startProgress: 0.75, durationProgress: 0.20)
        let clamped = nearEndViewport.preservingAbsoluteTimes(
            previousDuration: beforeDuration,
            nextDuration: afterDuration
        )
        try require(clamped.endProgress <= 1.000_001, "preserved near-end viewport exceeded timeline bounds")
        try require(clamped.durationProgress <= 1, "preserved near-end viewport duration exceeded full timeline")
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
        let hotSamples = frameStatsBox.samples.filter { !$0.waveformHotPathReason.isEmpty }
        try require(!hotSamples.isEmpty, "renderer never marked playback/interaction frames as hot")
        let cpuFallbackSamples = hotSamples.filter {
            $0.cpuWaveformVertexCount > 0 || $0.waveformFallbackDrawCount > 0
        }
        try require(
            cpuFallbackSamples.isEmpty,
            "hot render loop used CPU waveform fallback in \(cpuFallbackSamples.count) frames"
        )
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
        animateWaveformTransition: Bool = false,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws -> RenderedFrame {
        renderer.displayTracks(tracks, animateWaveformTransition: animateWaveformTransition)
        renderer.displayTrackLayout(trackLayout)
        renderer.displayViewport(viewport)
        renderer.displayPlaybackActive(isPlaybackActive)
        renderer.displayPlayheadProgress(
            playheadProgress,
            force: true,
            anchorTimestamp: playheadAnchorTimestamp ?? displayTimestamp,
            resetsTouchStart: true
        )

        return try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: displayTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
    }

    private static func renderCurrentTimeline(
        renderer: TimelineRenderer,
        displayTimestamp: CFTimeInterval = CACurrentMediaTime(),
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws -> RenderedFrame {
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

    private static func waitForVisibleWaveformBuffers(
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float,
        displayTimestamp: CFTimeInterval
    ) throws {
        for attempt in 0..<80 {
            if renderer.visibleWaveformShaderBuffersAreResident(drawableSize: viewportSize) {
                return
            }
            _ = try renderCurrentTimeline(
                renderer: renderer,
                displayTimestamp: displayTimestamp + Double(attempt) * 0.01,
                texture: texture,
                viewportSize: viewportSize,
                backingScale: backingScale
            )
            usleep(10_000)
        }
        try require(
            renderer.visibleWaveformShaderBuffersAreResident(drawableSize: viewportSize),
            "large waveform buffers did not become resident before grouped delete smoke"
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

    private static func makeLongSparseWaveformOverview(
        duration: TimeInterval,
        binCount: Int
    ) -> WaveformOverview {
        let bins = (0..<binCount).map { index -> WaveformOverview.Bin in
            let t = Float(index) / Float(max(binCount - 1, 1))
            let phrase = 0.18 + 0.76 * abs(sin(t * .pi * 12.0))
            let tremor = 0.52 + 0.48 * abs(sin(t * .pi * 37.0))
            let peak = min(max(phrase * tremor, 0.05), 0.95)
            return WaveformOverview.Bin(
                minimumSample: -peak,
                maximumSample: peak,
                rmsSample: peak * 0.58,
                lowEnergy: 0.26,
                midEnergy: 0.42,
                highEnergy: 0.32
            )
        }
        return WaveformOverview(duration: duration, bins: bins)
    }

    private static func makeDetailedWaveformOverview(
        duration: TimeInterval,
        binCount: Int,
        seed: UInt32
    ) -> WaveformOverview {
        let bins = (0..<binCount).map { index -> WaveformOverview.Bin in
            let t = Float(index) / Float(max(binCount - 1, 1))
            let phrase = 0.20 + 0.78 * abs(sin(t * .pi * 17.0 + Float(seed) * 0.13))
            let fast = 0.28 + 0.72 * abs(sin(t * .pi * 941.0 + Float(seed) * 0.71))
            let hashed = Float(timelineSmokeHash(UInt32(index) &* 1_103_515_245 &+ seed) & 0xFFFF) / 65_535.0
            let spike: Float = hashed > 0.968 ? 1.0 : 0.0
            let peak = min(max(phrase * fast * (0.44 + hashed * 0.42) + spike * 0.38, 0.02), 0.98)
            return WaveformOverview.Bin(
                minimumSample: -peak,
                maximumSample: peak * (0.86 + 0.14 * hashed),
                rmsSample: peak * 0.42,
                lowEnergy: 0.22 + hashed * 0.10,
                midEnergy: 0.38 + hashed * 0.18,
                highEnergy: 0.18 + hashed * 0.22
            )
        }
        return WaveformOverview(duration: duration, bins: bins)
    }

    private static func timelineSmokeHash(_ value: UInt32) -> UInt32 {
        var x = value
        x ^= x >> 16
        x &*= 0x7FEB_352D
        x ^= x >> 15
        x &*= 0x846C_A68B
        x ^= x >> 16
        return x
    }

    private static func deleteOverview(
        _ overview: WaveformOverview,
        selection: TimelineSelection,
        targetDuration: TimeInterval
    ) -> WaveformOverview {
        let binCount = overview.bins.count
        guard binCount > 0 else {
            return WaveformOverview(duration: targetDuration, bins: [])
        }

        let startIndex = min(
            max(Int((selection.startProgress * Double(binCount)).rounded(.down)), 0),
            binCount
        )
        let targetBinCount = min(
            max(Int((Double(binCount) * targetDuration / max(overview.duration, 0.000_001)).rounded()), 0),
            binCount
        )
        let removedBinCount = min(max(binCount - targetBinCount, 0), binCount - startIndex)
        let endIndex = min(startIndex + removedBinCount, binCount)
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount - (endIndex - startIndex))
        if startIndex > 0 {
            bins.append(contentsOf: overview.bins[0..<startIndex])
        }
        if endIndex < binCount {
            bins.append(contentsOf: overview.bins[endIndex..<binCount])
        }
        return WaveformOverview(duration: targetDuration, bins: bins)
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

    private static func pixelDifferenceCount(
        _ lhs: [UInt8],
        _ rhs: [UInt8],
        width: Int,
        columns: Range<Int>,
        rows: Range<Int>,
        threshold: Int = 20
    ) -> Int {
        guard width > 0, !columns.isEmpty, !rows.isEmpty else {
            return 0
        }

        let pixelCount = min(lhs.count, rhs.count) / 4
        let height = pixelCount / width
        let clampedColumns = max(columns.lowerBound, 0)..<min(columns.upperBound, width)
        let clampedRows = max(rows.lowerBound, 0)..<min(rows.upperBound, height)
        guard !clampedColumns.isEmpty, !clampedRows.isEmpty else {
            return 0
        }

        var count = 0
        for row in clampedRows {
            for column in clampedColumns {
                let byteIndex = (row * width + column) * 4
                let blueDelta = abs(Int(lhs[byteIndex]) - Int(rhs[byteIndex]))
                let greenDelta = abs(Int(lhs[byteIndex + 1]) - Int(rhs[byteIndex + 1]))
                let redDelta = abs(Int(lhs[byteIndex + 2]) - Int(rhs[byteIndex + 2]))
                if max(blueDelta, greenDelta, redDelta) > threshold {
                    count += 1
                }
            }
        }
        return count
    }

    private static func brightPixelDifferenceCount(
        _ lhs: [UInt8],
        _ rhs: [UInt8],
        width: Int,
        columns: Range<Int>,
        rows: Range<Int>,
        threshold: Int = 20,
        minimumLuminance: Int
    ) -> Int {
        guard width > 0, !columns.isEmpty, !rows.isEmpty else {
            return 0
        }

        let pixelCount = min(lhs.count, rhs.count) / 4
        let height = pixelCount / width
        let clampedColumns = max(columns.lowerBound, 0)..<min(columns.upperBound, width)
        let clampedRows = max(rows.lowerBound, 0)..<min(rows.upperBound, height)
        guard !clampedColumns.isEmpty, !clampedRows.isEmpty else {
            return 0
        }

        var count = 0
        for row in clampedRows {
            for column in clampedColumns {
                let byteIndex = (row * width + column) * 4
                let lhsBlue = Int(lhs[byteIndex])
                let lhsGreen = Int(lhs[byteIndex + 1])
                let lhsRed = Int(lhs[byteIndex + 2])
                let rhsBlue = Int(rhs[byteIndex])
                let rhsGreen = Int(rhs[byteIndex + 1])
                let rhsRed = Int(rhs[byteIndex + 2])
                let lhsLuminance = (lhsRed * 54 + lhsGreen * 183 + lhsBlue * 19) / 256
                let rhsLuminance = (rhsRed * 54 + rhsGreen * 183 + rhsBlue * 19) / 256
                guard lhsLuminance >= minimumLuminance || rhsLuminance >= minimumLuminance else {
                    continue
                }

                let blueDelta = abs(lhsBlue - rhsBlue)
                let greenDelta = abs(lhsGreen - rhsGreen)
                let redDelta = abs(lhsRed - rhsRed)
                if max(blueDelta, greenDelta, redDelta) > threshold {
                    count += 1
                }
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
