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
        let smokeRunID = UUID().uuidString
        let wavURL = smokeDirectory.appendingPathComponent("SoundtimeTimelineUXSmoke-\(smokeRunID).wav")
        let projectURL = smokeDirectory.appendingPathComponent("SoundtimeTimelineUXSmoke-\(smokeRunID).soundtime")
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: projectURL)
        }
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

        try verifyPendingImportUsesFinalTrackLanes(
            device: device,
            pixelFormat: pixelFormat,
            residentTrack: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("pending track import keeps resident waveforms in their final lanes")

        try verifyInitialWaveformPublishSurvivesHover(
            waveformOverview: waveformOverview,
            device: device,
            pixelFormat: pixelFormat,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("initial waveform publish survives active hover")

        try verifyLaunchRestoreRendersWaveformsOnFirstFrame(
            waveformOverview: waveformOverview,
            device: device,
            pixelFormat: pixelFormat,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("launch restore renders cached waveforms on first frame")

        try verifyLaunchPreviewHandoffKeepsWaveformsDrawable(
            device: device,
            pixelFormat: pixelFormat,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("launch preview handoff keeps waveforms drawable")

        try verifyRefinedWaveformPromotesBeyondLaunchPreview(
            device: device,
            pixelFormat: pixelFormat,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("refined waveform promotes beyond launch preview")

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

        try verifyLoopWrapKeepsPlayheadMapped(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            frameStatsBox: frameStatsBox
        )
        complete("loop wrap keeps playhead effects mapped")

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

        try verifySelectionEdgeResizeSemantics()
        complete("selection edges resize around a fixed anchor without starting a new selection")

        try verifyRegionCreationDragThreshold()
        complete("new audio and loop regions require three points of horizontal drag")

        try verifySecondaryClickDefersMenuUntilMouseUp()
        complete("secondary click distinguishes context menu from timeline pan")

        try verifyLoopRangeMoveSemantics()
        complete("loop body movement preserves its width and clamps to timeline bounds")

        try verifyLoopMoveGuidesRenderBothEndpoints(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("loop body movement draws both full-height boundary guides")

        try verifyLoopPlaybackBypassSemantics()
        complete("explicit seek beyond loop bypasses the current loop cycle")

        try verifyLoopRangeViewportCornerSemantics()
        complete("loop region rounds only endpoints visible inside the viewport")

        try verifyClippedLoopRangeCornersRenderSquare(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("offscreen loop endpoints render square at viewport edges")

        try verifyClippedRangeEndpointsSuppressEdgeEffects(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("offscreen selection and loop endpoints suppress glass edge effects")

        try verifyLiveLoopMoveUpdatesPlayheadProjection(
            renderer: renderer,
            track: track
        )
        complete("live loop movement replaces stale playhead loop boundaries")

        try verifyEdgeAutoPanCurve()
        complete("selection and loop edge autopan accelerates smoothly toward timeline boundaries")

        try verifySelectionEdgeHoverRendering(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("selection edge hover renders on the targeted rounded edge")

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
            backingScale: backingScale,
            frameStatsBox: frameStatsBox
        )
        complete("rapid selection drag updates stay responsive and visible")

        try verifyRetinaSelectionDragStaysWithinFrameBudget(
            renderer: renderer,
            track: track,
            device: device,
            pixelFormat: pixelFormat
        )
        complete("Retina selection drag stays within the 144 Hz frame budget")

        try verifyHoverGuideUpdatesStayResponsive(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            frameStatsBox: frameStatsBox
        )
        complete("rapid hover guide updates stay responsive and visible")

        try verifyViewportInteractionUpdatesStayResponsive(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            frameStatsBox: frameStatsBox
        )
        complete("rapid viewport interaction updates stay GPU-only and visible")

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
        try verifyFrameHealthMetricSemantics()
        complete("main FPS graph draws visible cyan/red pixels")
        complete("performance monitor FPS/CPU graphs draw visible pixels")
        complete("FPS meter reports target health while idle and measured drops while active")

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

    private static func verifyPendingImportUsesFinalTrackLanes(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        residentTrack: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let renderer = try TimelineRenderer(device: device, pixelFormat: pixelFormat)
        let timestamp = CACurrentMediaTime()
        renderer.displayTracks([residentTrack], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default)
        renderer.displayViewport(.full)
        renderer.displayPlaybackActive(false)
        renderer.displayPlayheadProgress(
            0.25,
            force: true,
            anchorTimestamp: timestamp,
            resetsTouchStart: true
        )
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: timestamp
        )

        let pendingTrack = TimelineRenderState.Track(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-0000000000A2") ?? UUID(),
            waveformVersion: 0,
            waveformOverview: nil,
            durationHint: residentTrack.durationHint,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            hasWaveform: false
        )
        renderer.displayTracks(
            [residentTrack, pendingTrack],
            animateWaveformTransition: true,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false
        )
        let frame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp + 0.01,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let layout = TimelineTrackLayout.default.resolved(
            totalTrackCount: 2,
            viewportHeight: Float(frame.summary.height)
        )
        let firstLane = try requireValue(layout.laneFrame(forTrackIndex: 0), "pending import had no first lane")
        let secondLane = try requireValue(layout.laneFrame(forTrackIndex: 1), "pending import had no second lane")
        let firstRowStart = max(Int(ceil(firstLane.top * Float(frame.summary.height))) + 2, 0)
        let firstRowEnd = min(
            Int(floor(firstLane.bottom * Float(frame.summary.height))) - 2,
            frame.summary.height
        )
        let secondRowStart = max(Int(ceil(secondLane.top * Float(frame.summary.height))) + 2, 0)
        let secondRowEnd = min(
            Int(floor(secondLane.bottom * Float(frame.summary.height))) - 2,
            frame.summary.height
        )
        let firstRows = firstRowStart..<firstRowEnd
        let secondRows = secondRowStart..<secondRowEnd
        let firstLaneWaveformPixels = nonBackgroundPixelCount(
            inRows: firstRows,
            bytes: frame.bytes,
            width: frame.summary.width,
            backgroundLuminanceThreshold: 110
        )
        let secondLaneWaveformPixels = nonBackgroundPixelCount(
            inRows: secondRows,
            bytes: frame.bytes,
            width: frame.summary.width,
            backgroundLuminanceThreshold: 110
        )
        try require(
            firstLaneWaveformPixels > 1_500,
            "resident waveform did not move into its final first-track lane during import"
        )
        try require(
            secondLaneWaveformPixels < firstLaneWaveformPixels / 4 + 500,
            "resident waveform leaked into pending import lane: \(secondLaneWaveformPixels) vs \(firstLaneWaveformPixels)"
        )
    }

    private static func verifyInitialWaveformPublishSurvivesHover(
        waveformOverview: WaveformOverview,
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let renderer = try TimelineRenderer(device: device, pixelFormat: pixelFormat)
        let track = TimelineRenderState.Track(
            id: UUID(),
            waveformVersion: 9001,
            waveformOverview: waveformOverview,
            durationHint: waveformOverview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
        )
        let baseTimestamp = CACurrentMediaTime()
        renderer.displayTracks([track], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default)
        renderer.displayViewport(.full)
        renderer.displayPlaybackActive(false)
        renderer.displayPlayheadProgress(
            0.12,
            force: true,
            anchorTimestamp: baseTimestamp,
            resetsTouchStart: true
        )
        renderer.displayHoverProgress(0.42, isArmed: true)

        var lastFrame: RenderedFrame?
        for attempt in 0..<80 {
            lastFrame = try renderCurrentTimeline(
                renderer: renderer,
                displayTimestamp: baseTimestamp + Double(attempt) * 0.012,
                texture: texture,
                viewportSize: viewportSize,
                backingScale: backingScale
            )
            if (lastFrame?.summary.nonBackgroundPixelCount ?? 0) > 10_000 {
                renderer.displayHoverProgress(nil, isArmed: false)
                return
            }
            usleep(10_000)
        }

        renderer.displayHoverProgress(nil, isArmed: false)
        try require(
            (lastFrame?.summary.nonBackgroundPixelCount ?? 0) > 10_000,
            "initial waveform render stayed blank while hover was active"
        )
    }

    private static func verifyLaunchRestoreRendersWaveformsOnFirstFrame(
        waveformOverview: WaveformOverview,
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let renderer = try TimelineRenderer(device: device, pixelFormat: pixelFormat)
        let restoredViewport = TimelineViewport(startProgress: 0.18, durationProgress: 0.62)
        let tracks = (0..<3).map { index in
            TimelineRenderState.Track(
                id: UUID(),
                waveformVersion: 31 + index,
                waveformOverview: waveformOverview,
                durationHint: waveformOverview.duration,
                volume: 1,
                isMuted: false,
                isSoloed: false,
                clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
            )
        }
        let displayTimestamp = CACurrentMediaTime()
        renderer.displayViewport(restoredViewport, marksInteraction: false)
        renderer.displayTrackLayout(.default, marksInteraction: false)
        renderer.displaySelection(nil, marksInteraction: false)
        renderer.displayTracks(
            tracks,
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: true,
            allowImmediateInteractiveWaveformPrewarm: false
        )

        let firstFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: displayTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        try require(
            firstFrame.summary.brightPixelCount > 2_400,
            "launch restore first frame did not contain enough waveform pixels: \(firstFrame.summary.brightPixelCount)"
        )
        let drawableBinCounts = renderer.visibleWaveformDrawableBinCounts(
            drawableSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            drawableBinCounts.count == tracks.count,
            "launch restore did not make every cached waveform drawable before first frame: \(drawableBinCounts)"
        )
    }

    private static func verifyLaunchPreviewHandoffKeepsWaveformsDrawable(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let renderer = try TimelineRenderer(device: device, pixelFormat: pixelFormat)
        let launchOverview = makeDetailedWaveformOverview(duration: 520, binCount: 32_768, seed: 61)
        let savedProjectOverview = makeDetailedWaveformOverview(duration: 520, binCount: 4_096, seed: 61)
        let trackIDs = (0..<3).map { _ in UUID() }
        let launchTracks = trackIDs.enumerated().map { index, id in
            TimelineRenderState.Track(
                id: id,
                waveformVersion: 80 + index,
                waveformOverview: launchOverview,
                durationHint: launchOverview.duration,
                volume: 1,
                isMuted: false,
                isSoloed: false,
                clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
            )
        }
        let savedProjectTracks = trackIDs.enumerated().map { index, id in
            TimelineRenderState.Track(
                id: id,
                waveformVersion: 80 + index,
                waveformOverview: savedProjectOverview,
                durationHint: savedProjectOverview.duration,
                volume: 1,
                isMuted: false,
                isSoloed: false,
                clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
            )
        }

        renderer.displayViewport(.full, marksInteraction: false)
        renderer.displayTrackLayout(.default, marksInteraction: false)
        renderer.displaySelection(nil, marksInteraction: false)
        renderer.displayTracks(
            launchTracks,
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: true,
            allowImmediateInteractiveWaveformPrewarm: false
        )
        renderer.prepareFirstPaintWaveformShaderBuffers(
            drawableSize: viewportSize,
            backingScale: backingScale
        )
        let launchFrame = try renderCurrentTimeline(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            launchFrame.summary.brightPixelCount > 2_400,
            "launch handoff setup did not draw cached waveforms: \(launchFrame.summary.brightPixelCount)"
        )
        let launchDrawableBinCounts = renderer.visibleWaveformDrawableBinCounts(
            drawableSize: viewportSize,
            backingScale: backingScale
        )
        let launchMipState = renderer.debugVisibleWaveformMipBinState(
            drawableSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            (launchDrawableBinCounts.min() ?? 0) >= 32_768,
            "launch handoff setup did not use high-quality cached waveforms: \(launchDrawableBinCounts) state=\(launchMipState)"
        )

        renderer.displayTracks(
            savedProjectTracks,
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false
        )
        renderer.prepareFirstPaintWaveformShaderBuffers(
            drawableSize: viewportSize,
            backingScale: backingScale
        )
        let handoffFrame = try renderCurrentTimeline(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            handoffFrame.summary.brightPixelCount > 2_400,
            "saved-project handoff blanked cached launch waveforms: \(handoffFrame.summary.brightPixelCount)"
        )

        let drawableBinCounts = renderer.visibleWaveformDrawableBinCounts(
            drawableSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            drawableBinCounts.count == savedProjectTracks.count,
            "saved-project handoff left tracks without drawable buffers: \(drawableBinCounts)"
        )
        try require(
            (drawableBinCounts.min() ?? 0) >= 32_768,
            "saved-project handoff downgraded cached launch waveform quality: \(drawableBinCounts) launchState=\(launchMipState) handoffState=\(renderer.debugVisibleWaveformMipBinState(drawableSize: viewportSize, backingScale: backingScale))"
        )
    }

    private static func verifyRefinedWaveformPromotesBeyondLaunchPreview(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let renderer = try TimelineRenderer(device: device, pixelFormat: pixelFormat)
        let trackID = UUID()
        let duration: TimeInterval = 60
        let coarseOverview = makeDetailedWaveformOverview(
            duration: duration,
            binCount: 4_096,
            seed: 0xC0A4_5E
        )
        let refinedOverview = makeDetailedWaveformOverview(
            duration: duration,
            binCount: 32_768,
            seed: 0xF17E_1D
        )
        let coarseTrack = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 1,
            waveformOverview: coarseOverview,
            durationHint: duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
        )
        let refinedTrack = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 2,
            waveformOverview: refinedOverview,
            durationHint: duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
        )
        let baseTimestamp = CACurrentMediaTime()
        renderer.displayTracks([coarseTrack], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default)
        renderer.displayViewport(TimelineViewport(startProgress: 0.18, durationProgress: 0.10))
        renderer.displayPlaybackActive(false)
        renderer.displayPlayheadProgress(
            0,
            force: true,
            anchorTimestamp: baseTimestamp,
            resetsTouchStart: true
        )
        renderer.displayHoverProgress(0.45, isArmed: true)

        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: baseTimestamp
        )
        let coarseBinCounts = renderer.visibleWaveformDrawableBinCounts(
            drawableSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            (coarseBinCounts.max() ?? 0) <= 8_192,
            "coarse launch preview unexpectedly rendered with \(coarseBinCounts.max() ?? 0) bins"
        )

        renderer.displayTracks([refinedTrack], animateWaveformTransition: false)
        renderer.displayHoverProgress(0.45, isArmed: true)

        for attempt in 0..<60 {
            _ = try renderCurrentTimeline(
                renderer: renderer,
                displayTimestamp: baseTimestamp + 0.1 + Double(attempt) * 0.016,
                texture: texture,
                viewportSize: viewportSize,
                backingScale: backingScale
            )
            let binCounts = renderer.visibleWaveformDrawableBinCounts(
                drawableSize: viewportSize,
                backingScale: backingScale
            )
            try require(
                (binCounts.max() ?? 0) < 32_768,
                "refined waveform promoted while hover interaction was active; visible bins \(binCounts)"
            )
            usleep(8_000)
        }

        renderer.displayHoverProgress(nil, isArmed: false)
        usleep(450_000)
        for _ in 0..<220 {
            _ = try renderCurrentTimeline(
                renderer: renderer,
                displayTimestamp: CACurrentMediaTime(),
                texture: texture,
                viewportSize: viewportSize,
                backingScale: backingScale
            )
            let binCounts = renderer.visibleWaveformDrawableBinCounts(
                drawableSize: viewportSize,
                backingScale: backingScale
            )
            if (binCounts.max() ?? 0) >= 32_768 {
                return
            }
            usleep(8_000)
        }

        let finalBinCounts = renderer.visibleWaveformDrawableBinCounts(
            drawableSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            (finalBinCounts.max() ?? 0) >= 32_768,
            "refined waveform never promoted beyond coarse preview; visible bins \(finalBinCounts)"
        )
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

    private static func verifyLoopWrapKeepsPlayheadMapped(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float,
        frameStatsBox: FrameStatsBox
    ) throws {
        let loopRange = TimelineLoopRange(startProgress: 0.25, endProgress: 0.45)
        let initialPlayheadProgress: Float = 0.44
        let duration = try requireValue(track.durationHint, "loop-wrap smoke track had no duration")
        let baseTimestamp = CACurrentMediaTime()
        let wrappedTimestamp = baseTimestamp + duration * 0.04
        let projectedProgress = initialPlayheadProgress + Float((wrappedTimestamp - baseTimestamp) / duration)
        let expectedProgress = loopRange.startProgress +
            (projectedProgress - loopRange.endProgress).truncatingRemainder(dividingBy: loopRange.durationProgress)

        renderer.displayTracks([track], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default)
        renderer.displayViewport(.full)
        renderer.displayLoopRange(loopRange)
        renderer.displayLoopRangeEnabled(true)
        renderer.displayPlaybackActive(true)
        renderer.displayPlayheadProgress(
            initialPlayheadProgress,
            force: true,
            anchorTimestamp: baseTimestamp,
            resetsTouchStart: true
        )
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: baseTimestamp
        )
        frameStatsBox.samples.removeAll()

        let frame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: wrappedTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try requireCyanX(
            frame.summary,
            expectedX: Double(frame.summary.width) * Double(expectedProgress),
            tolerance: 44,
            label: "loop wrap"
        )

        renderer.displayLoopPlaybackBypassed(true)
        let bypassedProgress = try requireValue(
            renderer.projectedPlayheadProgress(at: wrappedTimestamp),
            "explicit seek beyond loop did not project a playhead"
        )
        try require(
            abs(bypassedProgress - projectedProgress) < 0.000_001,
            "explicit seek beyond loop projected \(bypassedProgress) instead of \(projectedProgress)"
        )
        renderer.displayLoopPlaybackBypassed(false)

        // Frame diagnostics intentionally publish over a short sample window.
        // Exercise enough wrapped playback frames to produce a representative
        // hot-path sample instead of relying on stats left by an earlier check.
        for frameIndex in 1...12 {
            _ = try renderCurrentTimeline(
                renderer: renderer,
                displayTimestamp: wrappedTimestamp + Double(frameIndex) / 120,
                texture: texture,
                viewportSize: viewportSize,
                backingScale: backingScale
            )
        }
        let playbackStats = frameStatsBox.samples.filter { $0.waveformHotPathReason == "playback" }
        try require(!playbackStats.isEmpty, "loop-wrap playback did not publish frame stats")
        let hotPathViolations = playbackStats.filter {
            $0.cpuWaveformVertexCount > 0 ||
                $0.cpuWaveformFallbackDrawCount > 0 ||
                $0.shaderBufferUploadByteCount > 0 ||
                $0.shaderBufferUploadCount > 0
        }
        try require(
            hotPathViolations.isEmpty,
            "loop-wrap playback used CPU fallback or shader uploads in \(hotPathViolations.count) frames"
        )

        renderer.displayPlaybackActive(false)
        renderer.displayLoopRange(.default)
        renderer.displayLoopRangeEnabled(true)
        renderer.displayLoopPlaybackBypassed(false)
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

    private static func verifySelectionEdgeResizeSemantics() throws {
        let trackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000077") ?? UUID()
        let selection = TimelineSelection(
            startProgress: 0.25,
            endProgress: 0.65,
            trackID: trackID
        )

        try require(
            TimelineSelectionResizeInteraction.endpoint(
                nearX: 247,
                startX: 250,
                endX: 650,
                hitWidth: 14
            ) == .start,
            "selection start edge was not hit within its resize target"
        )
        try require(
            TimelineSelectionResizeInteraction.endpoint(
                nearX: 656,
                startX: 250,
                endX: 650,
                hitWidth: 14
            ) == .end,
            "selection end edge was not hit within its resize target"
        )
        try require(
            TimelineSelectionResizeInteraction.endpoint(
                nearX: 450,
                startX: 250,
                endX: 650,
                hitWidth: 14
            ) == nil,
            "selection center incorrectly behaved like a resize edge"
        )

        let verticalRect = CGRect(x: 0, y: 20, width: 1_000, height: 180)
        try require(
            TimelineSelectionResizeInteraction.endpoint(
                at: CGPoint(x: 10, y: 100),
                startX: 0,
                endX: 650,
                verticalRect: verticalRect,
                viewportWidth: 1_000,
                hitWidth: 14
            ) == .start,
            "selection resize cursor target and mouse-down target disagreed at the left viewport edge"
        )
        try require(
            TimelineSelectionResizeInteraction.endpoint(
                at: CGPoint(x: 990, y: 100),
                startX: 250,
                endX: 1_000,
                verticalRect: verticalRect,
                viewportWidth: 1_000,
                hitWidth: 14
            ) == .end,
            "selection resize cursor target and mouse-down target disagreed at the right viewport edge"
        )
        try require(
            TimelineSelectionResizeInteraction.endpoint(
                at: CGPoint(x: 250, y: 205),
                startX: 250,
                endX: 650,
                verticalRect: verticalRect,
                viewportWidth: 1_000,
                hitWidth: 14
            ) == nil,
            "selection resize endpoint accepted a point outside the selected track lane"
        )

        let resizedStart = TimelineSelectionResizeInteraction.resizedSelection(
            selection,
            moving: .start,
            to: 0.15
        )
        try require(
            abs(resizedStart.startProgress - 0.15) < 0.000_001 &&
                abs(resizedStart.endProgress - 0.65) < 0.000_001 &&
                resizedStart.trackID == trackID,
            "resizing the selection start did not preserve the end anchor and track"
        )

        let resizedEnd = TimelineSelectionResizeInteraction.resizedSelection(
            selection,
            moving: .end,
            to: 0.82
        )
        try require(
            abs(resizedEnd.startProgress - 0.25) < 0.000_001 &&
                abs(resizedEnd.endProgress - 0.82) < 0.000_001 &&
                resizedEnd.trackID == trackID,
            "resizing the selection end did not preserve the start anchor and track"
        )

        let crossedAnchor = TimelineSelectionResizeInteraction.resizedSelection(
            selection,
            moving: .start,
            to: 0.78
        )
        try require(
            abs(crossedAnchor.startProgress - 0.65) < 0.000_001 &&
                abs(crossedAnchor.endProgress - 0.78) < 0.000_001 &&
                crossedAnchor.trackID == trackID,
            "selection resize did not remain normalized after crossing the fixed anchor"
        )
    }

    private static func verifyLoopRangeMoveSemantics() throws {
        let original = TimelineLoopRange(startProgress: 0.25, endProgress: 0.55)

        let movedRight = original.moving(by: 0.18)
        try require(
            abs(movedRight.startProgress - 0.43) < 0.000_001 &&
                abs(movedRight.endProgress - 0.73) < 0.000_001,
            "moving a loop body did not translate both boundaries by the same amount"
        )
        try require(
            abs(movedRight.durationProgress - original.durationProgress) < 0.000_001,
            "moving a loop body changed its duration"
        )

        let clampedLeft = original.moving(by: -0.80)
        try require(
            abs(clampedLeft.startProgress) < 0.000_001 &&
                abs(clampedLeft.endProgress - original.durationProgress) < 0.000_001,
            "moving a loop body past the timeline start did not clamp as one range"
        )

        let clampedRight = original.moving(by: 0.80)
        try require(
            abs(clampedRight.endProgress - 1) < 0.000_001 &&
                abs(clampedRight.startProgress - (1 - original.durationProgress)) < 0.000_001,
            "moving a loop body past the timeline end did not clamp as one range"
        )
        try require(
            abs(clampedRight.durationProgress - original.durationProgress) < 0.000_001,
            "right-edge clamping changed the loop duration"
        )
    }

    private static func verifyRegionCreationDragThreshold() throws {
        let threshold = TimelineRegionCreationGesture.minimumHorizontalDragDistance

        try require(
            !TimelineRegionCreationGesture.hasCrossedDragThreshold(
                anchorX: 100,
                currentX: 100 + threshold - 0.01
            ),
            "a sub-threshold rightward gesture started a new region"
        )
        try require(
            !TimelineRegionCreationGesture.hasCrossedDragThreshold(
                anchorX: 100,
                currentX: 100 - threshold + 0.01
            ),
            "a sub-threshold leftward gesture started a new region"
        )
        try require(
            TimelineRegionCreationGesture.hasCrossedDragThreshold(
                anchorX: 100,
                currentX: 100 + threshold
            ),
            "a three-point rightward gesture did not start a new region"
        )
        try require(
            TimelineRegionCreationGesture.hasCrossedDragThreshold(
                anchorX: 100,
                currentX: 100 - threshold
            ),
            "a three-point leftward gesture did not start a new region"
        )
    }

    private static func verifySecondaryClickDefersMenuUntilMouseUp() throws {
        let threshold = TimelineSecondaryButtonGesture.minimumPanDistance

        try require(
            !TimelineSecondaryButtonGesture.hasCrossedPanThreshold(
                anchorX: 100,
                currentX: 100 + threshold - 0.01
            ),
            "a stationary secondary click was claimed by timeline pan"
        )
        try require(
            TimelineSecondaryButtonGesture.shouldPresentContextMenu(
                wasEligibleAtMouseDown: true,
                didPan: false
            ),
            "an eligible stationary secondary click did not present its menu"
        )
        try require(
            TimelineSecondaryButtonGesture.hasCrossedPanThreshold(
                anchorX: 100,
                currentX: 100 - threshold
            ),
            "a secondary-button drag did not activate timeline pan"
        )
        try require(
            !TimelineSecondaryButtonGesture.shouldPresentContextMenu(
                wasEligibleAtMouseDown: true,
                didPan: true
            ),
            "timeline pan still presented the selection context menu"
        )
        try require(
            !TimelineSecondaryButtonGesture.shouldPresentContextMenu(
                wasEligibleAtMouseDown: false,
                didPan: false
            ),
            "a secondary click outside the selection presented its context menu"
        )
    }

    private static func verifyLoopMoveGuidesRenderBothEndpoints(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let loopRange = TimelineLoopRange(startProgress: 0.24, endProgress: 0.71)
        let timestamp = CACurrentMediaTime()

        renderer.displayTracks([track], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default)
        renderer.displayViewport(.full)
        renderer.displayPlaybackActive(false)
        renderer.displayPlayheadProgress(
            0.04,
            force: true,
            anchorTimestamp: timestamp,
            resetsTouchStart: true
        )
        renderer.displayLoopRange(loopRange)
        renderer.displayHoverProgress(nil, isArmed: false)
        renderer.publishInteractionLoopMoveGuides(false)
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: timestamp
        )

        let baseFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        renderer.publishInteractionLoopMoveGuides(true)
        let guidedFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp + 1.0 / 144.0,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        renderer.publishInteractionLoopMoveGuides(false)

        let width = guidedFrame.summary.width
        let height = guidedFrame.summary.height
        let layout = TimelineTrackLayout.default.resolved(
            totalTrackCount: 1,
            viewportHeight: Float(height)
        )
        let guideRows = min(Int(layout.rulerLaneHeight.rounded(.up)) + 2, height)..<height

        func columns(around progress: Float) -> Range<Int> {
            let x = Int((progress * Float(width)).rounded())
            return max(x - 2, 0)..<min(x + 3, width)
        }

        let leftDifference = pixelDifferenceCount(
            baseFrame.bytes,
            guidedFrame.bytes,
            width: width,
            columns: columns(around: loopRange.startProgress),
            rows: guideRows,
            threshold: 2
        )
        let rightDifference = pixelDifferenceCount(
            baseFrame.bytes,
            guidedFrame.bytes,
            width: width,
            columns: columns(around: loopRange.endProgress),
            rows: guideRows,
            threshold: 2
        )
        let centerDifference = pixelDifferenceCount(
            baseFrame.bytes,
            guidedFrame.bytes,
            width: width,
            columns: columns(around: (loopRange.startProgress + loopRange.endProgress) * 0.5),
            rows: guideRows,
            threshold: 2
        )

        try require(
            leftDifference > guideRows.count / 2,
            "moving the full loop region did not draw its left boundary guide"
        )
        try require(
            rightDifference > guideRows.count / 2,
            "moving the full loop region did not draw its right boundary guide"
        )
        try require(
            centerDifference < guideRows.count / 8,
            "moving the full loop region incorrectly kept a cursor-centered guide"
        )
    }

    private static func verifyLoopPlaybackBypassSemantics() throws {
        let loopRange = TimelineLoopRange(startProgress: 0.20, endProgress: 0.60)

        try require(
            TimelineLoopPlaybackPolicy.bypassesLoopForExplicitSeek(
                to: 0.78,
                whilePlaying: true,
                loopRange: loopRange,
                isLoopEnabled: true
            ),
            "playing seek beyond the loop end did not bypass the current loop cycle"
        )
        try require(
            !TimelineLoopPlaybackPolicy.bypassesLoopForExplicitSeek(
                to: 0.50,
                whilePlaying: true,
                loopRange: loopRange,
                isLoopEnabled: true
            ),
            "playing seek inside the loop incorrectly bypassed looping"
        )
        try require(
            !TimelineLoopPlaybackPolicy.bypassesLoopForExplicitSeek(
                to: 0.78,
                whilePlaying: false,
                loopRange: loopRange,
                isLoopEnabled: true
            ),
            "paused seek beyond the loop end bypassed the next normal play"
        )
        try require(
            !TimelineLoopPlaybackPolicy.shouldWrapPlayback(
                at: 0.78,
                loopRange: loopRange,
                isLoopEnabled: true,
                isBypassed: true
            ),
            "bypassed playback still wrapped at the loop boundary"
        )
        try require(
            TimelineLoopPlaybackPolicy.shouldWrapPlayback(
                at: 0.60,
                loopRange: loopRange,
                isLoopEnabled: true,
                isBypassed: false
            ),
            "natural playback crossing did not wrap at the loop boundary"
        )

        let loopMovedAhead = TimelineLoopRange(startProgress: 0.62, endProgress: 0.82)
        try require(
            !TimelineLoopPlaybackPolicy.bypassesLoopAfterRangeChange(
                playbackProgress: 0.48,
                whilePlaying: true,
                loopRange: loopMovedAhead,
                isLoopEnabled: true
            ),
            "moving the loop ahead of playback incorrectly disabled the next loop"
        )
        try require(
            TimelineLoopPlaybackPolicy.shouldWrapPlayback(
                at: loopMovedAhead.endProgress,
                loopRange: loopMovedAhead,
                isLoopEnabled: true,
                isBypassed: false
            ),
            "playback did not remain armed to wrap after reaching a loop moved ahead"
        )

        let loopMovedBehind = TimelineLoopRange(startProgress: 0.12, endProgress: 0.32)
        try require(
            TimelineLoopPlaybackPolicy.bypassesLoopAfterRangeChange(
                playbackProgress: 0.48,
                whilePlaying: true,
                loopRange: loopMovedBehind,
                isLoopEnabled: true
            ),
            "moving the loop behind playback did not bypass it for the current pass"
        )
        try require(
            !TimelineLoopPlaybackPolicy.bypassesLoopAfterRangeChange(
                playbackProgress: 0.48,
                whilePlaying: false,
                loopRange: loopMovedBehind,
                isLoopEnabled: true
            ),
            "moving a loop while paused incorrectly bypassed the next playback pass"
        )
    }

    private static func verifyLiveLoopMoveUpdatesPlayheadProjection(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track
    ) throws {
        let timestamp = CACurrentMediaTime()
        let originalRange = TimelineLoopRange(startProgress: 0.20, endProgress: 0.40)
        let movedRange = TimelineLoopRange(startProgress: 0.60, endProgress: 0.80)

        renderer.displayTracks([track], animateWaveformTransition: false)
        renderer.displayLoopRange(originalRange)
        renderer.displayLoopRangeEnabled(true)
        renderer.displayLoopPlaybackBypassed(false)
        renderer.displayPlaybackActive(true)
        renderer.displayPlayheadProgress(
            0.50,
            force: true,
            anchorTimestamp: timestamp,
            resetsTouchStart: true
        )

        let originalProjection = renderer.projectedPlayheadProgress(at: timestamp) ?? -1
        try require(
            abs(originalProjection - 0.30) < 0.000_1,
            "test setup did not project through the original loop range"
        )

        renderer.publishInteractionLoopRange(movedRange)
        let liveProjection = renderer.projectedPlayheadProgress(at: timestamp) ?? -1
        try require(
            abs(liveProjection - 0.50) < 0.000_1,
            "playhead projection kept using the stale loop while its body moved"
        )

        renderer.displayLoopRange(movedRange)
        let committedProjection = renderer.projectedPlayheadProgress(at: timestamp) ?? -1
        try require(
            abs(committedProjection - 0.50) < 0.000_1,
            "committing a moved loop restored stale loop boundaries"
        )

        renderer.displayPlaybackActive(false)
        renderer.displayLoopPlaybackBypassed(false)
        renderer.displayLoopRangeEnabled(false)
        renderer.displayLoopRange(.default)
        renderer.publishInteractionLoopMoveGuides(false)
        renderer.displayHighlightedLoopEndpoint(nil)
        renderer.displayHighlightedSelectionEndpoint(nil)
        renderer.displaySelection(nil, marksInteraction: false)
    }

    private static func verifyEdgeAutoPanCurve() throws {
        let viewportWidth: CGFloat = 1_000
        let activationDistance: CGFloat = 84

        let centerVelocity = TimelineEdgeAutoPan.normalizedVelocity(
            pointerX: viewportWidth * 0.5,
            viewportWidth: viewportWidth,
            activationDistance: activationDistance
        )
        try require(centerVelocity == 0, "edge autopan activated away from the timeline edge")

        let leftEntryVelocity = TimelineEdgeAutoPan.normalizedVelocity(
            pointerX: 72,
            viewportWidth: viewportWidth,
            activationDistance: activationDistance
        )
        let leftNearVelocity = TimelineEdgeAutoPan.normalizedVelocity(
            pointerX: 12,
            viewportWidth: viewportWidth,
            activationDistance: activationDistance
        )
        let rightNearVelocity = TimelineEdgeAutoPan.normalizedVelocity(
            pointerX: viewportWidth - 12,
            viewportWidth: viewportWidth,
            activationDistance: activationDistance
        )
        try require(
            leftEntryVelocity < 0 &&
                leftNearVelocity < leftEntryVelocity,
            "left edge autopan did not accelerate toward the boundary"
        )
        try require(
            rightNearVelocity > 0 &&
                abs(leftNearVelocity + rightNearVelocity) < 0.000_001,
            "edge autopan was not directionally symmetric"
        )

        let outsideLeftVelocity = TimelineEdgeAutoPan.normalizedVelocity(
            pointerX: -40,
            viewportWidth: viewportWidth,
            activationDistance: activationDistance
        )
        let outsideRightVelocity = TimelineEdgeAutoPan.normalizedVelocity(
            pointerX: viewportWidth + 40,
            viewportWidth: viewportWidth,
            activationDistance: activationDistance
        )
        try require(
            outsideLeftVelocity == -1 && outsideRightVelocity == 1,
            "edge autopan did not clamp to maximum speed outside the timeline"
        )

        let progressDelta = TimelineEdgeAutoPan.progressDelta(
            normalizedVelocity: 0.5,
            viewportDurationProgress: 0.2,
            elapsedTime: 0.1,
            maximumViewportWidthsPerSecond: 0.9
        )
        try require(
            abs(progressDelta - 0.009) < 0.000_001,
            "edge autopan progress was not time- and zoom-relative"
        )
    }

    private static func verifyLoopRangeViewportCornerSemantics() throws {
        let loopRange = TimelineLoopRange(startProgress: 0.20, endProgress: 0.80)

        try require(
            loopRange.cornerVisibility(in: .full) == TimelineLoopCornerVisibility(
                roundsLeftCorner: true,
                roundsRightCorner: true
            ),
            "fully visible loop range did not round both endpoint corners"
        )
        try require(
            loopRange.cornerVisibility(
                in: TimelineViewport(startProgress: 0.30, durationProgress: 0.70)
            ) == TimelineLoopCornerVisibility(
                roundsLeftCorner: false,
                roundsRightCorner: true
            ),
            "left-clipped loop range still rounded its viewport continuation"
        )
        try require(
            loopRange.cornerVisibility(
                in: TimelineViewport(startProgress: 0, durationProgress: 0.70)
            ) == TimelineLoopCornerVisibility(
                roundsLeftCorner: true,
                roundsRightCorner: false
            ),
            "right-clipped loop range still rounded its viewport continuation"
        )
        try require(
            loopRange.cornerVisibility(
                in: TimelineViewport(startProgress: 0.30, durationProgress: 0.30)
            ) == TimelineLoopCornerVisibility(
                roundsLeftCorner: false,
                roundsRightCorner: false
            ),
            "loop range spanning both viewport edges rounded a clipped side"
        )
        try require(
            loopRange.cornerVisibility(
                in: TimelineViewport(startProgress: 0.20, durationProgress: 0.60)
            ) == TimelineLoopCornerVisibility(
                roundsLeftCorner: true,
                roundsRightCorner: true
            ),
            "loop endpoints exactly on viewport boundaries were treated as clipped"
        )
        try require(
            TimelineLoopCornerVisibility.projected(
                rawLeft: -120,
                rawRight: 1_080,
                viewportWidth: 960
            ) == TimelineLoopCornerVisibility(
                roundsLeftCorner: false,
                roundsRightCorner: false
            ),
            "projected loop bounds did not suppress corners at both clipped viewport edges"
        )
    }

    private static func verifyClippedLoopRangeCornersRenderSquare(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let timestamp = CACurrentMediaTime()
        renderer.displayTracks([track], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default)
        renderer.displayViewport(TimelineViewport(startProgress: 0.30, durationProgress: 0.30))
        renderer.displayPlaybackActive(false)
        renderer.displayPlayheadProgress(
            0.45,
            force: true,
            anchorTimestamp: timestamp,
            resetsTouchStart: true
        )
        renderer.displayLoopRange(.default)
        let baseFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        renderer.displayLoopRange(TimelineLoopRange(startProgress: 0.20, endProgress: 0.80))
        renderer.displayLoopRangeEnabled(true)
        let clippedFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let width = clippedFrame.summary.width
        let height = clippedFrame.summary.height
        let cornerRows = 3..<min(8, height)
        let leftCornerDifference = pixelDifferenceCount(
            baseFrame.bytes,
            clippedFrame.bytes,
            width: width,
            columns: 0..<min(4, width),
            rows: cornerRows,
            threshold: 3
        )
        let rightCornerDifference = pixelDifferenceCount(
            baseFrame.bytes,
            clippedFrame.bytes,
            width: width,
            columns: max(width - 4, 0)..<width,
            rows: cornerRows,
            threshold: 3
        )
        try require(
            leftCornerDifference >= 12,
            "left-clipped loop endpoint still rendered a rounded viewport corner"
        )
        try require(
            rightCornerDifference >= 12,
            "right-clipped loop endpoint still rendered a rounded viewport corner"
        )

        renderer.displayLoopRange(.default)
        renderer.displayViewport(.full)
    }

    private static func verifyClippedRangeEndpointsSuppressEdgeEffects(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let timestamp = CACurrentMediaTime()
        let viewport = TimelineViewport(startProgress: 0.30, durationProgress: 0.30)
        let selection = TimelineSelection(
            startProgress: 0.20,
            endProgress: 0.80,
            trackID: track.id
        )
        renderer.displayTracks([track], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default)
        renderer.displayViewport(viewport)
        renderer.displayPlaybackActive(false)
        renderer.displayPlayheadProgress(
            0.45,
            force: true,
            anchorTimestamp: timestamp,
            resetsTouchStart: true
        )
        renderer.displayLoopRange(.default)
        renderer.displaySelection(nil, marksInteraction: false)
        let noSelectionFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        renderer.displaySelection(selection, marksInteraction: false)
        renderer.displayHighlightedSelectionEndpoint(nil)
        let selectionBaseFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let width = selectionBaseFrame.summary.width
        let height = selectionBaseFrame.summary.height
        let layout = TimelineTrackLayout.default.resolved(
            totalTrackCount: 1,
            viewportHeight: Float(height)
        )
        let topRow = Int(layout.rulerLaneHeight.rounded(.down))
        let cornerRows = max(topRow + 2, 0)..<min(topRow + 7, height)
        let bottomCornerRows = max(height - 7, 0)..<max(height - 2, 0)
        let leftColumns = 0..<min(4, width)
        let rightColumns = max(width - 4, 0)..<width
        let leftCornerDifference =
            pixelDifferenceCount(
                noSelectionFrame.bytes,
                selectionBaseFrame.bytes,
                width: width,
                columns: leftColumns,
                rows: cornerRows,
                threshold: 3
            ) +
            pixelDifferenceCount(
                noSelectionFrame.bytes,
                selectionBaseFrame.bytes,
                width: width,
                columns: leftColumns,
                rows: bottomCornerRows,
                threshold: 3
            )
        let rightCornerDifference =
            pixelDifferenceCount(
                noSelectionFrame.bytes,
                selectionBaseFrame.bytes,
                width: width,
                columns: rightColumns,
                rows: cornerRows,
                threshold: 3
            ) +
            pixelDifferenceCount(
                noSelectionFrame.bytes,
                selectionBaseFrame.bytes,
                width: width,
                columns: rightColumns,
                rows: bottomCornerRows,
                threshold: 3
            )
        try require(
            leftCornerDifference >= 24,
            "left-clipped selection still rounded its viewport continuation"
        )
        try require(
            rightCornerDifference >= 24,
            "right-clipped selection still rounded its viewport continuation"
        )

        renderer.displayHighlightedSelectionEndpoint(.start)
        let selectionStartHoverFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        renderer.displayHighlightedSelectionEndpoint(.end)
        let selectionEndHoverFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            pixelDifferenceCount(selectionBaseFrame.bytes, selectionStartHoverFrame.bytes, threshold: 0) == 0,
            "left-clipped selection endpoint still rendered a hover/glass edge"
        )
        try require(
            pixelDifferenceCount(selectionBaseFrame.bytes, selectionEndHoverFrame.bytes, threshold: 0) == 0,
            "right-clipped selection endpoint still rendered a hover/glass edge"
        )

        renderer.displayHighlightedSelectionEndpoint(nil)
        renderer.displaySelection(nil, marksInteraction: false)
        renderer.displayLoopRange(TimelineLoopRange(startProgress: 0.20, endProgress: 0.80))
        renderer.displayLoopRangeEnabled(true)
        renderer.displayHighlightedLoopEndpoint(nil)
        let loopBaseFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        renderer.displayHighlightedLoopEndpoint(.start)
        let loopStartHoverFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        renderer.displayHighlightedLoopEndpoint(.end)
        let loopEndHoverFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            pixelDifferenceCount(loopBaseFrame.bytes, loopStartHoverFrame.bytes, threshold: 0) == 0,
            "left-clipped loop endpoint still rendered a hover/glass edge"
        )
        try require(
            pixelDifferenceCount(loopBaseFrame.bytes, loopEndHoverFrame.bytes, threshold: 0) == 0,
            "right-clipped loop endpoint still rendered a hover/glass edge"
        )

        renderer.displayHighlightedLoopEndpoint(nil)
        renderer.displayLoopRange(.default)
        renderer.displayViewport(.full)
    }

    private static func verifySelectionEdgeHoverRendering(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let selection = TimelineSelection(
            startProgress: 0.24,
            endProgress: 0.68,
            trackID: track.id
        )
        let timestamp = CACurrentMediaTime()
        renderer.displayTracks([track], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default)
        renderer.displayViewport(.full)
        renderer.displayPlaybackActive(false)
        renderer.displayPlayheadProgress(
            0.08,
            force: true,
            anchorTimestamp: timestamp,
            resetsTouchStart: true
        )
        renderer.displaySelection(selection, marksInteraction: false)
        renderer.displayHighlightedSelectionEndpoint(nil)
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: timestamp
        )
        let baseFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        renderer.displayHighlightedSelectionEndpoint(.start)
        let startHoverFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        renderer.displayHighlightedSelectionEndpoint(.end)
        let endHoverFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let width = baseFrame.summary.width
        let height = baseFrame.summary.height
        let startX = Int(
            Float(width) * renderer.visualViewportProgress(
                forTimelineProgress: selection.startProgressFloat,
                trackID: selection.trackID,
                timestamp: timestamp
            )
        )
        let endX = Int(
            Float(width) * renderer.visualViewportProgress(
                forTimelineProgress: selection.endProgressFloat,
                trackID: selection.trackID,
                timestamp: timestamp
            )
        )
        let rows = 0..<height
        let startColumns = max(startX - 10, 0)..<min(startX + 11, width)
        let endColumns = max(endX - 10, 0)..<min(endX + 11, width)
        let startHoverAtStart = pixelDifferenceCount(
            baseFrame.bytes,
            startHoverFrame.bytes,
            width: width,
            columns: startColumns,
            rows: rows,
            threshold: 4
        )
        let startHoverAtEnd = pixelDifferenceCount(
            baseFrame.bytes,
            startHoverFrame.bytes,
            width: width,
            columns: endColumns,
            rows: rows,
            threshold: 4
        )
        let endHoverAtEnd = pixelDifferenceCount(
            baseFrame.bytes,
            endHoverFrame.bytes,
            width: width,
            columns: endColumns,
            rows: rows,
            threshold: 4
        )
        let endHoverAtStart = pixelDifferenceCount(
            baseFrame.bytes,
            endHoverFrame.bytes,
            width: width,
            columns: startColumns,
            rows: rows,
            threshold: 4
        )
        let startHoverTotal = pixelDifferenceCount(
            baseFrame.bytes,
            startHoverFrame.bytes,
            threshold: 0
        )
        let endHoverTotal = pixelDifferenceCount(
            baseFrame.bytes,
            endHoverFrame.bytes,
            threshold: 0
        )
        try require(
            startHoverAtStart > 100 && startHoverAtStart > startHoverAtEnd * 2,
            "selection start hover did not stay localized to the start edge " +
                "(start=\(startHoverAtStart), end=\(startHoverAtEnd), total=\(startHoverTotal))"
        )
        try require(
            endHoverAtEnd > 100 && endHoverAtEnd > endHoverAtStart * 2,
            "selection end hover did not stay localized to the end edge " +
                "(end=\(endHoverAtEnd), start=\(endHoverAtStart), total=\(endHoverTotal))"
        )

        renderer.displayHighlightedSelectionEndpoint(nil)
        renderer.displaySelection(nil, marksInteraction: false)
    }

    private static func verifySelectionDragUpdatesStayResponsive(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float,
        frameStatsBox: FrameStatsBox
    ) throws {
        let dragOverview = makeDetailedWaveformOverview(
            duration: 480,
            binCount: 131_072,
            seed: 0x5E1E_C710
        )
        let dragTrack = TimelineRenderState.Track(
            id: track.id,
            waveformVersion: track.waveformVersion + 10_000,
            waveformOverview: dragOverview,
            durationHint: dragOverview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
        )
        let dragViewport = TimelineViewport(startProgress: 0.08, durationProgress: 0.08)
        var frameDurations: [Double] = []
        frameDurations.reserveCapacity(54)
        let baseTimestamp = CACurrentMediaTime()

        renderer.displayTracks([dragTrack], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default)
        renderer.displayViewport(dragViewport)
        renderer.displayPlaybackActive(false)
        frameStatsBox.samples.removeAll()
        renderer.displayPlayheadProgress(
            0.10,
            force: true,
            anchorTimestamp: baseTimestamp,
            resetsTouchStart: true
        )
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: baseTimestamp
        )

        func publishDrag(
            _ selection: TimelineSelection,
            velocityPixelsPerSecond: Float = 1_250,
            timestamp: CFTimeInterval
        ) {
            renderer.publishInteractionSelectionDragSnapshot(TimelineSelectionDragSnapshot(
                selection: selection,
                leadingProgress: selection.endProgressFloat,
                velocityPixelsPerSecond: velocityPixelsPerSecond,
                direction: 1,
                timestamp: timestamp
            ))
        }

        let firstSelection = TimelineSelection(startProgress: 0.10, endProgress: 0.12, trackID: track.id)
        publishDrag(firstSelection, velocityPixelsPerSecond: 920, timestamp: baseTimestamp)
        let firstFrame = try renderCurrentTimeline(
            renderer: renderer,
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
            publishDrag(
                selection,
                velocityPixelsPerSecond: 980,
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
            publishDrag(
                selection,
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
            commandBuffer?.waitUntilCompleted()
            frameDurations.append((CACurrentMediaTime() - startTime) * 1_000)
        }

        let burstTimestamp = baseTimestamp + 0.86
        for burstIndex in 0..<240 {
            let t = Double(burstIndex) / 239.0
            let selection = TimelineSelection(
                startProgress: 0.10,
                endProgress: 0.12 + t * 0.68,
                trackID: track.id
            )
            publishDrag(
                selection,
                velocityPixelsPerSecond: 1_800,
                timestamp: burstTimestamp + Double(burstIndex) / 12_000.0
            )
        }
        let burstRenderPassDescriptor = makeRenderPassDescriptor(texture: texture)
        let burstStartTime = CACurrentMediaTime()
        let burstCommandBuffer = renderer.renderOffscreen(
            renderPassDescriptor: burstRenderPassDescriptor,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: burstTimestamp + 1.0 / 144.0,
            waitUntilCompleted: false
        )
        burstCommandBuffer?.waitUntilCompleted()
        let burstDurationMilliseconds = (CACurrentMediaTime() - burstStartTime) * 1_000

        let finalSelection = TimelineSelection(startProgress: 0.10, endProgress: 0.80, trackID: track.id)
        publishDrag(
            finalSelection,
            timestamp: baseTimestamp + 0.5
        )
        let lastFrame = try renderCurrentTimeline(
            renderer: renderer,
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
        try require(
            burstDurationMilliseconds < 8,
            String(format: "selection drag burst render was too slow: %.2fms", burstDurationMilliseconds)
        )

        let dragStats = frameStatsBox.samples.filter { $0.waveformHotPathReason == "selection-drag" }
        try require(!dragStats.isEmpty, "selection drag did not publish hot-path frame stats")
        let fallbackStats = dragStats.filter {
            $0.cpuWaveformVertexCount > 0 ||
                $0.cpuWaveformFallbackDrawCount > 0 ||
                $0.shaderBufferUploadByteCount > 0 ||
                $0.shaderBufferUploadCount > 0
        }
        try require(
            fallbackStats.isEmpty,
            "selection drag used CPU fallback or shader uploads in \(fallbackStats.count) frames"
        )

        let changedPixels = pixelDifferenceCount(firstFrame.bytes, lastFrame.bytes, threshold: 8)
        renderer.publishInteractionSelectionDragSnapshot(nil)
        renderer.publishInteractionSelection(nil)
        renderer.displaySelection(nil)
        try require(changedPixels > 8_000, "selection drag did not visibly update final selection: \(changedPixels)")
    }

    private static func verifyRetinaSelectionDragStaysWithinFrameBudget(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        device: MTLDevice,
        pixelFormat: MTLPixelFormat
    ) throws {
        // Exercise the actual high-fill-rate case that exposed the regression:
        // a nearly full-screen selection over a multi-track project in a large
        // Retina editor window, with the loop overlay present too.
        let viewportSize = CGSize(width: 1_920, height: 900)
        let backingScale: Float = 2
        let tracks = [
            track,
            renderTrack(
                from: track,
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000102") ?? UUID(),
                volume: 0.72
            ),
            renderTrack(
                from: track,
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000103") ?? UUID(),
                volume: 0.48
            ),
        ]
        let texture = try makeTexture(
            device: device,
            pixelFormat: pixelFormat,
            width: Int(viewportSize.width * CGFloat(backingScale)),
            height: Int(viewportSize.height * CGFloat(backingScale))
        )
        let baseTimestamp = CACurrentMediaTime()
        var frameDurations: [Double] = []
        frameDurations.reserveCapacity(32)

        defer {
            renderer.publishInteractionSelectionDragSnapshot(nil)
            renderer.publishInteractionSelection(nil)
            renderer.displayLoopRange(.default)
            renderer.displayTracks([track], animateWaveformTransition: false)
            renderer.displaySelection(nil)
        }

        renderer.displayTracks(tracks, animateWaveformTransition: false)
        renderer.displayTrackLayout(.default)
        renderer.displayViewport(.full)
        renderer.displayLoopRange(TimelineLoopRange(startProgress: 0.18, endProgress: 0.72))
        renderer.displayLoopRangeEnabled(true)
        renderer.displayPlaybackActive(false)
        renderer.displayPlayheadProgress(
            0.10,
            force: true,
            anchorTimestamp: baseTimestamp,
            resetsTouchStart: true
        )
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: baseTimestamp
        )

        func publishDrag(frameIndex: Int) {
            let progress = 0.16 + Double(frameIndex) / 39.0 * 0.70
            let selection = TimelineSelection(
                startProgress: 0.08,
                endProgress: progress,
                trackID: track.id
            )
            renderer.publishInteractionSelectionDragSnapshot(TimelineSelectionDragSnapshot(
                selection: selection,
                leadingProgress: selection.endProgressFloat,
                velocityPixelsPerSecond: 1_450,
                direction: 1,
                timestamp: baseTimestamp + Double(frameIndex) / 144.0
            ))
        }

        for warmupIndex in 0..<8 {
            publishDrag(frameIndex: warmupIndex)
            let commandBuffer = renderer.renderOffscreen(
                renderPassDescriptor: makeRenderPassDescriptor(texture: texture),
                viewportSize: viewportSize,
                backingScale: backingScale,
                displayTimestamp: baseTimestamp + Double(warmupIndex) / 144.0,
                waitUntilCompleted: false
            )
            commandBuffer?.waitUntilCompleted()
        }

        for frameIndex in 8..<40 {
            publishDrag(frameIndex: frameIndex)
            let loopEnd = 0.58 + Float(frameIndex - 8) / 31 * 0.22
            renderer.publishInteractionLoopRange(
                TimelineLoopRange(startProgress: 0.18, endProgress: loopEnd)
            )
            let startedAt = CACurrentMediaTime()
            let commandBuffer = renderer.renderOffscreen(
                renderPassDescriptor: makeRenderPassDescriptor(texture: texture),
                viewportSize: viewportSize,
                backingScale: backingScale,
                displayTimestamp: baseTimestamp + Double(frameIndex) / 144.0,
                waitUntilCompleted: false
            )
            commandBuffer?.waitUntilCompleted()
            frameDurations.append((CACurrentMediaTime() - startedAt) * 1_000)
        }

        let p95Milliseconds = percentile(frameDurations, percentile: 0.95)
        let maxMilliseconds = frameDurations.max() ?? 0
        try require(
            p95Milliseconds < 6.9,
            String(format: "Retina selection drag render p95 missed 144 Hz: %.2fms", p95Milliseconds)
        )
        try require(
            maxMilliseconds < 14,
            String(format: "Retina selection drag render had a severe outlier: %.2fms", maxMilliseconds)
        )
    }

    private static func verifyHoverGuideUpdatesStayResponsive(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float,
        frameStatsBox: FrameStatsBox
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
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: baseTimestamp
        )
        frameStatsBox.samples.removeAll()

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
            commandBuffer?.waitUntilCompleted()
            frameDurations.append((CACurrentMediaTime() - startTime) * 1_000)
            usleep(8_000)
        }

        let burstTimestamp = baseTimestamp + 0.72
        for burstIndex in 0..<240 {
            let t = Float(burstIndex) / 239.0
            renderer.publishInteractionHover(progress: 0.15 + t * 0.70, isArmed: true)
        }
        let burstRenderPassDescriptor = makeRenderPassDescriptor(texture: texture)
        let burstStartTime = CACurrentMediaTime()
        let burstCommandBuffer = renderer.renderOffscreen(
            renderPassDescriptor: burstRenderPassDescriptor,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: burstTimestamp + 1.0 / 144.0,
            waitUntilCompleted: false
        )
        burstCommandBuffer?.waitUntilCompleted()
        let burstDurationMilliseconds = (CACurrentMediaTime() - burstStartTime) * 1_000

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
            p95Milliseconds < 6.9,
            String(format: "hover guide render p95 was too slow: %.2fms", p95Milliseconds)
        )
        try require(
            maxMilliseconds < 12,
            String(format: "hover guide render outlier was too slow: %.2fms", maxMilliseconds)
        )
        try require(
            burstDurationMilliseconds < 8,
            String(format: "hover guide burst render was too slow: %.2fms", burstDurationMilliseconds)
        )

        let hoverStats = frameStatsBox.samples.filter { $0.waveformHotPathReason == "hover" }
        try require(!hoverStats.isEmpty, "hover guide did not publish hot-path frame stats")
        let fallbackStats = hoverStats.filter {
            $0.cpuWaveformVertexCount > 0 ||
                $0.cpuWaveformFallbackDrawCount > 0 ||
                $0.shaderBufferUploadByteCount > 0 ||
                $0.shaderBufferUploadCount > 0
        }
        try require(
            fallbackStats.isEmpty,
            "hover guide used CPU fallback or shader uploads in \(fallbackStats.count) frames"
        )

        let changedPixels = pixelDifferenceCount(firstFrame.bytes, lastFrame.bytes, threshold: 8)
        renderer.displayHoverProgress(nil, isArmed: false)
        try require(changedPixels > 600, "hover guide did not visibly update final position: \(changedPixels)")
    }

    private static func verifyViewportInteractionUpdatesStayResponsive(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float,
        frameStatsBox: FrameStatsBox
    ) throws {
        var frameDurations: [Double] = []
        frameDurations.reserveCapacity(54)
        let baseTimestamp = CACurrentMediaTime()
        let startViewport = TimelineViewport(startProgress: 0.02, durationProgress: 0.24)

        renderer.displayTracks([track], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default)
        renderer.displayViewport(startViewport)
        renderer.displayPlaybackActive(false)
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: baseTimestamp
        )
        frameStatsBox.samples.removeAll()

        renderer.publishInteractionViewport(startViewport)
        let firstFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: baseTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        for frameIndex in 0..<54 {
            let t = Float(frameIndex) / 53.0
            let viewport = TimelineViewport(
                startProgress: 0.02 + t * 0.28,
                durationProgress: 0.24 - t * 0.06
            )
            renderer.publishInteractionViewport(viewport)

            let renderPassDescriptor = makeRenderPassDescriptor(texture: texture)
            let startTime = CACurrentMediaTime()
            let commandBuffer = renderer.renderOffscreen(
                renderPassDescriptor: renderPassDescriptor,
                viewportSize: viewportSize,
                backingScale: backingScale,
                displayTimestamp: baseTimestamp + Double(frameIndex + 1) / 144.0,
                waitUntilCompleted: false
            )
            commandBuffer?.waitUntilCompleted()
            frameDurations.append((CACurrentMediaTime() - startTime) * 1_000)
            usleep(8_000)
        }

        let burstTimestamp = baseTimestamp + 0.72
        let finalInteractionViewport = TimelineViewport(
            startProgress: 0.30,
            durationProgress: 0.18
        )
        for burstIndex in 0..<240 {
            let t = Float(burstIndex) / 239.0
            renderer.publishInteractionViewport(TimelineViewport(
                startProgress: 0.02 + t * 0.28,
                durationProgress: 0.18
            ))
        }
        let probeViewportProgress: Float = 0.20
        let probeTimelineProgress = finalInteractionViewport.timelineProgress(
            forViewportProgress: probeViewportProgress
        )
        let resolvedProbeViewportProgress = renderer.currentPresentationViewportProgress(
            forTimelineProgress: probeTimelineProgress
        )
        try require(
            abs(resolvedProbeViewportProgress - probeViewportProgress) < 0.000_01,
            String(
                format: "interactive viewport mapping was stale after pan: expected %.5f, got %.5f",
                probeViewportProgress,
                resolvedProbeViewportProgress
            )
        )
        let burstRenderPassDescriptor = makeRenderPassDescriptor(texture: texture)
        let burstStartTime = CACurrentMediaTime()
        let burstCommandBuffer = renderer.renderOffscreen(
            renderPassDescriptor: burstRenderPassDescriptor,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: burstTimestamp + 1.0 / 144.0,
            waitUntilCompleted: false
        )
        burstCommandBuffer?.waitUntilCompleted()
        let burstDurationMilliseconds = (CACurrentMediaTime() - burstStartTime) * 1_000

        let lastFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: baseTimestamp + 1,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let p95Milliseconds = percentile(frameDurations, percentile: 0.95)
        let maxMilliseconds = frameDurations.max() ?? 0
        try require(
            p95Milliseconds < 6.9,
            String(format: "viewport interaction render p95 was too slow: %.2fms", p95Milliseconds)
        )
        try require(
            maxMilliseconds < 12,
            String(format: "viewport interaction render outlier was too slow: %.2fms", maxMilliseconds)
        )
        try require(
            burstDurationMilliseconds < 8,
            String(format: "viewport interaction burst render was too slow: %.2fms", burstDurationMilliseconds)
        )

        let viewportStats = frameStatsBox.samples.filter { $0.waveformHotPathReason == "viewport-interaction" }
        try require(!viewportStats.isEmpty, "viewport interaction did not publish hot-path frame stats")
        let fallbackStats = viewportStats.filter {
            $0.cpuWaveformVertexCount > 0 ||
                $0.cpuWaveformFallbackDrawCount > 0 ||
                $0.shaderBufferUploadByteCount > 0 ||
                $0.shaderBufferUploadCount > 0
        }
        try require(
            fallbackStats.isEmpty,
            "viewport interaction used CPU fallback or shader uploads in \(fallbackStats.count) frames"
        )

        let changedPixels = pixelDifferenceCount(firstFrame.bytes, lastFrame.bytes, threshold: 8)
        try require(changedPixels > 4_000, "viewport interaction did not visibly update waveform: \(changedPixels)")
    }

    private static func verifyDeletionEffectLifecycle(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        renderer.clearDeletionEffects()
        renderer.displayLoopRange(.default)
        renderer.displayLoopRangeEnabled(true)
        renderer.displayHoverProgress(nil, isArmed: false)
        renderer.displaySelection(nil)
        let selection = TimelineSelection(startProgress: 0.24, endProgress: 0.32, trackID: track.id)
        let baseTimestamp = CACurrentMediaTime()
        renderer.displayTracks([track], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default)
        renderer.displayViewport(.full)
        renderer.displayPlaybackActive(false)
        renderer.displayPlayheadProgress(
            0.24,
            force: true,
            anchorTimestamp: baseTimestamp,
            resetsTouchStart: true
        )
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: baseTimestamp
        )
        let baseFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: baseTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        renderer.triggerDeletionEffect(selection: selection)
        let activeFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: baseTimestamp + 0.02,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            pixelDifferenceCount(baseFrame.bytes, activeFrame.bytes, threshold: 12) > 1_500,
            "delete animation effect did not visibly alter the render"
        )

        _ = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: baseTimestamp + 2.20,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let settledTimestamp = baseTimestamp + 2.56
        let expiredFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: settledTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        renderer.clearDeletionEffects()
        let clearedFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: settledTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let expiryDifference = pixelDifferenceCount(clearedFrame.bytes, expiredFrame.bytes, threshold: 12)
        try require(
            expiryDifference < 120,
            "delete animation effect did not visually expire; pixel delta \(expiryDifference)"
        )
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
        _ = try renderTimeline(
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
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: displayTimestamp + 0.01
        )
        let beforeFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: displayTimestamp + 0.035,
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
        let stablePixelBudget = max(stableColumns.count * laneRows.count / 100, 24)
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
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: displayTimestamp + 0.02
        )
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
        let stablePixelBudget = max(stableColumns.count * laneRows.count / 80, 720)
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
            $0.cpuWaveformVertexCount > 0 || $0.cpuWaveformFallbackDrawCount > 0
        }
        try require(
            cpuFallbackSamples.isEmpty,
            "hot render loop used CPU waveform fallback in \(cpuFallbackSamples.count) frames"
        )
        let uploadSamples = hotSamples.filter {
            $0.shaderBufferUploadCount > 0 || $0.shaderBufferUploadByteCount > 0
        }
        try require(
            uploadSamples.isEmpty,
            "hot render loop published shader buffers in \(uploadSamples.count) frames"
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

    private static func verifyFrameHealthMetricSemantics() throws {
        let idleHealth = PerformanceSampler.effectiveFrameHealthFramesPerSecond(
            measuredFramesPerSecond: 23,
            targetFramesPerSecond: 144,
            renderDemand: .idle,
            activeDemandAge: 12
        )
        try require(idleHealth == 144, "idle frame health retained sparse render cadence")

        let warmupHealth = PerformanceSampler.effectiveFrameHealthFramesPerSecond(
            measuredFramesPerSecond: 0,
            targetFramesPerSecond: 144,
            renderDemand: .interaction,
            activeDemandAge: 0.04
        )
        try require(warmupHealth == 144, "active measurement warm-up reported a false frame drop")

        let droppedHealth = PerformanceSampler.effectiveFrameHealthFramesPerSecond(
            measuredFramesPerSecond: 72,
            targetFramesPerSecond: 144,
            renderDemand: .playback,
            activeDemandAge: 1
        )
        try require(droppedHealth == 72, "active frame drop was hidden by the target rate")

        let stalledHealth = PerformanceSampler.effectiveFrameHealthFramesPerSecond(
            measuredFramesPerSecond: 0,
            targetFramesPerSecond: 144,
            renderDemand: .animation,
            activeDemandAge: 0.5
        )
        try require(stalledHealth == 0, "active render stall was hidden by the target rate")

        let sampler = PerformanceSampler.shared
        let heartbeatStart = CACurrentMediaTime()
        sampler.updateTargetFramesPerSecond(144)
        sampler.updateRenderDemand(.idle)
        sampler.recordMainThreadHeartbeat(
            at: heartbeatStart,
            isApplicationActive: false,
            expectedInterval: 0.1
        )
        sampler.recordMainThreadHeartbeat(
            at: heartbeatStart,
            isApplicationActive: true,
            expectedInterval: 0.1
        )
        sampler.recordMainThreadHeartbeat(
            at: heartbeatStart + 0.1,
            isApplicationActive: true,
            expectedInterval: 0.1
        )
        let healthyHeartbeatSnapshot = sampler.snapshot(at: heartbeatStart + 0.1)
        try require(
            healthyHeartbeatSnapshot.timelineGraphFramesPerSecond == 144,
            "healthy 10 Hz performance heartbeat reported a false frame drop"
        )
        sampler.recordMainThreadHeartbeat(
            at: heartbeatStart + 0.22,
            isApplicationActive: true,
            expectedInterval: 0.1
        )
        let jitteredHeartbeatSnapshot = sampler.snapshot(at: heartbeatStart + 0.22)
        try require(
            jitteredHeartbeatSnapshot.timelineGraphFramesPerSecond == 144,
            "normal performance timer jitter reported a false frame drop"
        )
        sampler.recordMainThreadHeartbeat(
            at: heartbeatStart + 0.60,
            isApplicationActive: true,
            expectedInterval: 0.1
        )
        let heartbeatSnapshot = sampler.snapshot(at: heartbeatStart + 0.60)
        try require(
            heartbeatSnapshot.timelineGraphFramesPerSecond < 144,
            "idle main-thread stall did not lower effective frame health"
        )
        let activeGraphFPS = PerformanceSampler.effectiveGraphFramesPerSecond(
            renderHealthFramesPerSecond: 144,
            mainThreadResponsivenessFramesPerSecond: 10,
            renderDemand: .playback
        )
        try require(
            activeGraphFPS == 144,
            "diagnostics heartbeat overrode authoritative active render cadence"
        )
        sampler.recordMainThreadHeartbeat(
            at: heartbeatStart + 2,
            isApplicationActive: false,
            expectedInterval: 0.1
        )
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
