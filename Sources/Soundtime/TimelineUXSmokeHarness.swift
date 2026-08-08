import Darwin
import Foundation
import AppKit
@preconcurrency import Metal
import QuartzCore

enum TimelineUXSmokeHarness {
    // This intentionally leaves more than half of a 144 Hz frame for AppKit,
    // input delivery, and presentation. A tighter value proved less stable
    // than Metal command scheduling itself while the full-Retina smoke below
    // continues to enforce the end-to-end 6.94 ms frame budget.
    private static let selectionDragMicrobenchmarkBudgetMilliseconds = 3.0

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
        if arguments.contains("--track-layout-resize-only") {
            try verifyTrackLayoutGeometry()
            try verifyLiveResizeDrawableSizeContract()
            print("ok - track layout geometry remains pixel-stable during live resize")
            return
        }
        if arguments.contains("--track-header-resize-only") {
            try verifyTrackHeaderWidthPolicy()
            try verifyTrackHeaderAutomationModeLayout()
            print("ok - track header splitter preserves usable timeline geometry")
            return
        }
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

        try verifySourceWaveformLayerContinuity(waveformOverview: waveformOverview)

        var completedChecks: [String] = []
        func complete(_ name: String) {
            completedChecks.append(name)
            print("ok - \(name)")
        }

        complete("source-resident waveforms survive temporary resolution gaps")

        try verifyTrackVolumeUpdatePreservesResidentWaveform(
            waveformOverview: waveformOverview,
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("track volume updates preserve resident waveform amplitude")

        try verifyAutomationEnvelopeRenders(
            waveformOverview: waveformOverview,
            trackID: trackID,
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("automation envelope survives GPU waveform projection and renders visibly")

        try MainActor.assumeIsolated {
            try verifyAutomationVisibilityCommandRouting()
            try verifyAutomationPointClickPolicy()
            try verifyClipSelectionFocusResolution()
        }
        complete("automation visibility command delegates to its workspace owner")
        complete("automation point clicks delete without conflicting with drag or selection gestures")
        complete("selection focus prioritizes time ranges and unions selected clip bounds")

        try verifyAutomationPreviewPublicationIsLatestWins(
            trackID: trackID,
            renderer: renderer
        )
        complete("automation curve drag preview publication is latest-wins")

        try verifyAutomationCurveTessellationPolicy()
        complete("automation curves use adaptive bounded screen-space tessellation")

        try verifyAutomationMaximumAlignsWithClipHeader()
        complete("automation maximum aligns with the clip header bottom")

        try verifyRenderDataPublicationCannotLoseFollowUpFrame()
        complete("async render data publication preserves its follow-up frame")

        try verifySelectedClipControlGeometry()
        complete("selected clip controls remain pixel-sized instead of filling the clip")

        try verifyClipBodyOwnsItsWaveformCenterline(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("clip waveform body begins below its header and owns its centerline")

        try verifyLiveRecordingClipFollowsDisplayClock(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("live recording clip edge follows the display clock between audio publications")

        try verifyClipDragCanExtendWaveformPastCommittedTrackEnd()
        complete("live clip drags can extend waveforms past the committed track end")

        try MainActor.assumeIsolated {
            try verifyTimelineEndTrianglePresentation()
            try verifyClipInspectorResizeHoverOwnsCursor()
            try verifyClipCommandAndAccessibilitySurface()
            try verifyClipLabelsFollowVerticalZoom(track: track)
            try verifyInactiveLoopBodyStartsMoveGesture(track: track)
            try verifyLoopEdgeResizeCrossesOppositeBoundary(track: track)
            try verifyWindowDragStripContract()
            try verifyClipLabelDeleteProjectionRequiresExplicitHandoff()
        }
        complete("timeline end handle is an anchored equilateral hover triangle")
        complete("clip inspector resize hover keeps the up-down cursor above the timeline")
        complete("clip menus, callbacks, and accessibility expose missing-media workflows")
        complete("clip labels follow live vertical lane zoom")
        complete("inactive loop bodies retain the same move gesture as active loops")
        complete("loop edge resize crosses and swaps logical endpoints")
        complete("top window drag strip owns its full transparent hit area")
        complete("settled clip labels sleep while retaining canonical handoff geometry")

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

        try verifyEmptyCanonicalLaneDoesNotBlockLongWaveformPromotion(
            device: device,
            pixelFormat: pixelFormat,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("empty canonical lanes do not block long waveform promotion")

        try verifyLongWaveformRemainsVisibleAcrossZoomSweep(
            device: device,
            pixelFormat: pixelFormat,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("long waveforms remain visible across full, intermediate, and detail zoom")

        try verifyResidentTilesRefineDeepZoom(
            wavURL: wavURL,
            decodedBuffer: decodedBuffer,
            device: device,
            pixelFormat: pixelFormat,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("deep zoom promotes from continuity preview to resident source tiles")

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

        try verifyCommittedMixedSourceWaveformsRenderInDestinationLane(
            device: device,
            pixelFormat: pixelFormat,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("committed mixed-source clips retain waveforms in their destination lane")

        try verifyClipChromeFollowsDeletionProjection(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("clip bodies and trailing edges animate with ripple delete")

        try MainActor.assumeIsolated {
            try verifySeekGuttersOwnTimelineSeeking(track: track)
        }
        complete("upper ruler creates loops while lower ruler seeks during playback")

        try verifyFixedRulerOccludesVerticallyScrolledTracks(
            waveformOverview: waveformOverview,
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("fixed ruler occludes vertically scrolled track content")

        try MainActor.assumeIsolated {
            try verifyClipDragFloodPublishesAtDisplayCadence(track: track)
        }
        complete("raw clip-drag floods collapse to display-paced preview publication")

        try verifyFadeMappingRendersOnFirstFrame(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            frameStatsBox: frameStatsBox
        )
        complete("fade gain mapping renders immediately without slowing retained-selection resize")

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

        try verifyRulerSeparatorIsContinuous(
            device: device,
            pixelFormat: pixelFormat,
            track: track
        )
        complete("ruler separator remains continuous across every pixel")

        try verifyTrackLayoutGeometry()
        complete("track layout geometry keeps lanes aligned and hit-testable")

        try verifyTrackNavigationGeometry()
        complete("track reorder, scrolling, and zoom geometry remain synchronized")

        try verifyTwoDimensionalTrackpadNavigation()
        try verifyModifierWheelNavigation()
        complete("trackpad navigation composes horizontal and vertical panning")

        try verifySelectionEdgeResizeSemantics()
        complete("selection edges resize around a fixed anchor without starting a new selection")

        try verifyRegionCreationDragThreshold()
        complete("new audio and loop regions require three points of horizontal drag")

        try verifySecondaryClickDefersMenuUntilMouseUp()
        complete("secondary click distinguishes context menu from timeline pan")

        try verifyLoopRangeMoveSemantics()
        complete("loop body movement preserves its width and clamps to timeline bounds")

        try verifySharedLoopRangeProjection()
        complete("main timeline and track inspector project one shared loop through absolute time")

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

        try verifyLoopRegionStyleTransition()
        complete("loop hover and enabled styling transitions continuously")

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

        try verifyClipPlaybackStaysWithinFrameBudget(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("clip chrome stays retained while playback advances at display cadence")

        try verifyPanImmediatelyAfterZoomStaysResponsive(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            frameStatsBox: frameStatsBox
        )
        complete("pan remains frame-safe immediately after zoom refinement changes")

        try verifyDeletionEffectLifecycle(
            renderer: renderer,
            track: track,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        complete("delete animation remains projected until canonical handoff")

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

        try verifyEditCameraTransition()
        complete("edit camera reframing is continuous and lands exactly")

        try verifySelectionFocusCameraTransition()
        complete("selection focus preserves 64-point margins and track height")

        try verifyFocusedClipInspectorProjection()
        complete("track inspector maps project time and preserves every clip and render segment")

        try verifyMultiClipSelectionReduction()
        complete("clip selection supports toggle, additive, and range reduction")

        try verifyClipMovePreviewTranslatesWaveformRigidly()
        complete("cross-track move and duplicate previews preserve waveform source geometry")

        try verifyResidentTileMovePreviewTranslatesRigidly()
        complete("resident waveform tiles follow live clip drags without compression")

        try verifyLegacyClipIdentityMigration()
        complete("legacy edit timelines restore deterministic stable clip identities")

        try verifyOffscreenPlayheadNavigation()
        complete("offscreen playhead arrows share an exact reveal target")

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
            try verifyTrackLaneClicksDoNotSeek(track: track)
            try verifyClipDoubleClickOpensTrackInspector(track: track)
            try verifyClipEdgeDragOwnsTrimGesture(track: track)
            try verifyFullTimelineClipCanMove(track: track)
            try verifyOffscreenPlayheadDoesNotPageTimeline(track: track)
            try verifySelectionFocusScrollbarUsesPresentedCamera(track: track)
            try verifyMainFPSGraphPixels()
            try verifyPerformanceDashboardGraphPixels()
        }
        complete("track-lane and stationary clip clicks never seek")
        complete("clip double-click opens the track inspector without starting an edit")
        complete("clip edge drag trims the existing clip instead of seeking or selecting")
        complete("full-timeline clips can move beyond the current project end")
        complete("offscreen playback never moves the timeline without an explicit reveal")
        complete("selection focus scrollbar follows the presented camera")
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

    @MainActor
    private static func verifyTimelineEndTrianglePresentation() throws {
        let markerX: CGFloat = 123
        let overlay = TimelineEndOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        overlay.rulerHeight = 32
        overlay.markerX = markerX
        overlay.layoutSubtreeIfNeeded()

        let resting = overlay.handlePresentationSnapshotForSmokeTesting()
        try require(!resting.isHidden, "timeline end triangle was unexpectedly hidden")
        try require(
            abs(resting.frame.minX - markerX) < 0.001,
            "timeline end triangle did not anchor its left point to the marker line"
        )
        try require(
            abs(resting.frame.width - TimelineEndOverlayView.handleSideLength) < 0.001 &&
                abs(resting.frame.height - TimelineEndOverlayView.handleAltitude) < 0.001,
            "timeline end triangle did not use equilateral dimensions"
        )
        try require(
            resting.pathBounds.minX >= 0 &&
                abs(resting.pathBounds.maxX - resting.frame.width) < 0.001 &&
                abs(resting.pathBounds.height - resting.frame.height) < 0.001,
            "timeline end triangle path escaped its right-side handle frame"
        )

        overlay.isHandleHovered = true
        let hovered = overlay.handlePresentationSnapshotForSmokeTesting()
        try require(
            grayscaleComponent(of: hovered.fillColor) > grayscaleComponent(of: resting.fillColor),
            "timeline end triangle did not brighten on hover"
        )
    }

    private static func grayscaleComponent(of color: CGColor?) -> CGFloat {
        guard let components = color?.components, !components.isEmpty else {
            return 0
        }
        return components.count >= 3 ?
            (components[0] + components[1] + components[2]) / 3 :
            components[0]
    }

    private static func verifyRenderDataPublicationCannotLoseFollowUpFrame() throws {
        let submittedGeneration: UInt64 = 41
        guard !TimelineView.renderRequestRemainsPendingAfterSubmission(
            submittedGeneration: submittedGeneration,
            currentGeneration: submittedGeneration
        ) else {
            throw SmokeError.checkFailed("a completed frame kept a request that it already consumed")
        }

        guard TimelineView.renderRequestRemainsPendingAfterSubmission(
            submittedGeneration: submittedGeneration,
            currentGeneration: submittedGeneration + 1
        ) else {
            throw SmokeError.checkFailed(
                "waveform data published during an in-flight frame lost its required follow-up render"
            )
        }
    }

    @MainActor
    private static func verifyClipInspectorResizeHoverOwnsCursor() throws {
        let inspectorSize = NSSize(width: 900, height: 300)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: inspectorSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let inspector = FocusedClipInspectorView(frame: NSRect(origin: .zero, size: inspectorSize))
        window.contentView = inspector
        inspector.layoutSubtreeIfNeeded()

        let resizePoint = NSPoint(x: inspector.bounds.midX, y: inspector.bounds.maxY - 14)
        guard
            let resizeHitView = inspector.hitTest(resizePoint),
            resizeHitView !== inspector,
            resizeHitView !== inspector.timelineView
        else {
            throw SmokeError.checkFailed(
                "clip inspector resize zone did not own hit testing before mouse-down"
            )
        }

        let windowPoint = inspector.convert(resizePoint, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) else {
            throw SmokeError.checkFailed("could not create clip inspector cursor smoke event")
        }

        NSCursor.arrow.set()
        resizeHitView.mouseMoved(with: event)
        try require(
            NSCursor.current == .resizeUpDown,
            "clip inspector resize zone did not show the up-down cursor before mouse-down"
        )

        inspector.timelineView.mouseMoved(with: event)
        try require(
            NSCursor.current == .resizeUpDown,
            "underlying timeline tracking overwrote the clip inspector resize cursor"
        )
        NSCursor.arrow.set()
    }

    @MainActor
    private static func verifyClipCommandAndAccessibilitySurface() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 240),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let timeline = TimelineView()
        timeline.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 800, height: 240)
        timeline.autoresizingMask = [.width, .height]
        window.contentView = timeline
        timeline.layoutSubtreeIfNeeded()

        var relinkCount = 0
        var cancelRelinkCount = 0
        var inspectorCount = 0
        var focusedSplitCount = 0
        var moveDirections: [Int] = []
        var selectedClipID: AudioTimelineClipID?
        timeline.onRelinkMissingMediaRequested = { relinkCount += 1 }
        timeline.onCancelMissingMediaRelinkRequested = { cancelRelinkCount += 1 }
        timeline.onOpenSelectedClipInspectorRequested = { inspectorCount += 1 }
        timeline.onSplitFocusedClipRequested = { focusedSplitCount += 1 }
        timeline.onMoveSelectedClipsAcrossTracksRequested = { moveDirections.append($0) }
        timeline.onClipSelected = { request, _ in selectedClipID = request?.clipID }

        timeline.clipCommandContext = TimelineClipCommandContext(
            selectedClipCount: 1,
            totalClipCount: 2,
            hasTimeSelection: true,
            hasActiveTrack: true,
            hasFocusedInspector: true,
            hasMissingMedia: true,
            isRelinkingMedia: false,
            canMoveSelectionToTrackAbove: true,
            canMoveSelectionToTrackBelow: true
        )
        timeline.canUseFocusedClipCommands = true

        let relinkItem = NSMenuItem(
            title: "Relink Missing Media...",
            action: #selector(TimelineView.relinkMissingMedia(_:)),
            keyEquivalent: ""
        )
        let inspectorItem = NSMenuItem(
            title: "Open Selected Clip in Track Inspector",
            action: #selector(TimelineView.openSelectedClipInspector(_:)),
            keyEquivalent: ""
        )
        let cancelRelinkItem = NSMenuItem(
            title: "Cancel Media Relink",
            action: #selector(TimelineView.cancelMissingMediaRelink(_:)),
            keyEquivalent: ""
        )
        let moveAboveItem = NSMenuItem(
            title: "Move Selected Clips to Track Above",
            action: #selector(TimelineView.moveSelectedClipsToTrackAbove(_:)),
            keyEquivalent: ""
        )
        try require(timeline.validateMenuItem(relinkItem), "missing-media relink menu was disabled")
        try require(timeline.validateMenuItem(inspectorItem), "single-clip inspector menu was disabled")
        try require(timeline.validateMenuItem(moveAboveItem), "valid cross-track move menu was disabled")

        timeline.relinkMissingMedia(nil)
        timeline.openSelectedClipInspector(nil)
        timeline.moveSelectedClipsToTrackAbove(nil)
        timeline.moveSelectedClipsToTrackBelow(nil)
        timeline.splitFocusedClipAtPlayhead(nil)
        try require(relinkCount == 1, "relink menu did not dispatch its workflow")
        try require(inspectorCount == 1, "inspector menu did not dispatch its workflow")
        try require(moveDirections == [-1, 1], "cross-track menu commands used the wrong direction")
        try require(focusedSplitCount == 1, "focused command was inert on the main timeline responder")

        timeline.clipCommandContext.isRelinkingMedia = true
        try require(!timeline.validateMenuItem(relinkItem), "relink menu stayed enabled during an active relink")
        try require(timeline.validateMenuItem(cancelRelinkItem), "cancel relink menu was disabled during an active relink")
        timeline.cancelMissingMediaRelink(nil)
        try require(cancelRelinkCount == 1, "cancel relink menu did not dispatch its workflow")

        let clipID = AudioTimelineClipID(
            rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000077")!
        )
        let trackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000078")!
        timeline.displayTracks(
            [TimelineRenderState.Track(
                id: trackID,
                waveformVersion: 1,
                waveformOverview: nil,
                durationHint: 10,
                volume: 1,
                isMuted: false,
                isSoloed: false,
                hasWaveform: false,
                clipRanges: [TimelineRenderState.ClipRange(
                    id: clipID,
                    startProgress: 0.1,
                    endProgress: 0.6,
                    name: "Interview audio",
                    isSelected: true,
                    isMissingMedia: true
                )]
            )],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false,
            updatesRendererImmediately: false
        )

        try require(timeline.accessibilityRole() == .group, "timeline accessibility role was not a group")
        try require(timeline.accessibilityLabel() == "Audio timeline", "timeline accessibility label was missing")
        let children = timeline.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        try require(children.count == 1, "visible clip was not exposed as one accessibility child")
        let clipElement = children[0]
        try require(clipElement.accessibilityRole() == .button, "accessible clip was not actionable")
        try require(clipElement.accessibilityLabel() == "Interview audio", "accessible clip lost its name")
        let accessibilityValue = clipElement.accessibilityValue() as? String
        try require(
            accessibilityValue?.contains("missing media") == true,
            "accessible clip did not announce missing media"
        )
        try require(
            accessibilityValue?.contains("selected") == true,
            "accessible clip did not announce selection"
        )
        try require(clipElement.accessibilityPerformPress(), "accessible clip did not support press")
        try require(selectedClipID == clipID, "accessible clip press selected the wrong clip")
    }

    private static func verifyFocusedClipInspectorProjection() throws {
        let trackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000099") ?? UUID()
        let clipID = AudioTimelineClipID(
            rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000098") ?? UUID()
        )
        let secondClipID = AudioTimelineClipID(
            rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000095") ?? UUID()
        )
        let request = TimelineClipFocusRequest(
            clipID: clipID,
            trackID: trackID,
            trackLocalRange: TimelineRenderState.ClipRange(
                id: clipID,
                startProgress: 0.25,
                endProgress: 0.75
            ),
            projectStartProgress: 0.2,
            projectEndProgress: 0.5
        )
        let context = FocusedClipContext(
            request: request,
            trackName: "Inspected track",
            trackDuration: 24,
            projectDuration: 40
        )
        try require(
            abs(context.projectProgress(forLocalProgress: 0.5) - 0.3) < 0.000_001,
            "track-local midpoint did not map to the canonical project midpoint"
        )
        try require(
            abs(context.localProgress(forProjectProgress: 0.45) - 0.75) < 0.000_001,
            "project progress did not map back into track-local time"
        )
        try require(
            abs((context.focusedClipLocalProgress(forTrackProgress: 0.5) ?? -1) - 0.5) < 0.000_001 &&
                context.focusedClipLocalProgress(forTrackProgress: 0.1) == nil,
            "focused clip targeting did not remain distinct from track-inspector time"
        )
        let projectSelection = try requireValue(
            context.projectSelection(fromLocalSelection: TimelineSelection(
                startProgress: 0.1,
                endProgress: 0.6,
                trackID: trackID
            )),
            "clip-local selection did not map into project time"
        )
        try require(
            abs(projectSelection.startProgress - 0.06) < 0.000_001 &&
                abs(projectSelection.endProgress - 0.36) < 0.000_001,
            "track-local selection mapped to the wrong project range"
        )

        let transcript = TranscriptDocument(
            trackID: trackID,
            sourceRevision: 7,
            sourceDuration: 10,
            providerIdentifier: "timeline-ux-smoke",
            providerDisplayName: "Timeline UX Smoke",
            sourceTimeMap: TranscriptSourceTimeMap(
                sourceDuration: 10,
                timelineDuration: 20,
                segments: [
                    TranscriptSourceTimeMap.Segment(
                        outputStartTime: 0,
                        outputEndTime: 10,
                        sourceStartTime: 0,
                        sourceEndTime: 10
                    ),
                    TranscriptSourceTimeMap.Segment(
                        outputStartTime: 10,
                        outputEndTime: 20,
                        sourceStartTime: 0,
                        sourceEndTime: 10
                    ),
                ]
            ),
            segments: [
                TranscriptSegment(
                    startTime: 2,
                    endTime: 3,
                    text: "again",
                    words: [TranscriptWord(text: "again", startTime: 2, endTime: 3)]
                ),
            ]
        )
        let sourceTrack = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 7,
            waveformOverview: nil,
            durationHint: 24,
            volume: 0.8,
            isMuted: true,
            isSoloed: false,
            hasWaveform: false,
            clipRanges: [
                TimelineRenderState.ClipRange(
                    id: clipID,
                    startProgress: 0.25,
                    endProgress: 0.75,
                    name: "Opening"
                ),
                TimelineRenderState.ClipRange(
                    id: secondClipID,
                    startProgress: 0.8,
                    endProgress: 1,
                    name: "Closing"
                ),
            ],
            waveformSegments: [
                TimelineRenderState.Track.WaveformSegment(
                    outputStartProgress: 0,
                    outputEndProgress: 0.5,
                    sourceStartProgress: 0,
                    sourceEndProgress: 0.5,
                    gainStart: 0,
                    gainEnd: 1
                ),
                TimelineRenderState.Track.WaveformSegment(
                    outputStartProgress: 0.5,
                    outputEndProgress: 1,
                    sourceStartProgress: 0.5,
                    sourceEndProgress: 1,
                    gainStart: 1,
                    gainEnd: 0
                ),
            ],
            transcript: transcript
        )
        let projectedTrack = FocusedClipProjection.renderTrack(from: sourceTrack, context: context)
        try require(
            projectedTrack.clipRanges.count == 2 &&
                projectedTrack.clipRanges[0].id == clipID &&
                projectedTrack.clipRanges[0].isSelected &&
                projectedTrack.clipRanges[1].id == secondClipID &&
                !projectedTrack.clipRanges[1].isSelected,
            "track inspector did not retain all clips or identify the focused clip"
        )
        try require(projectedTrack.waveformSegments.count == 2, "track inspector lost a waveform segment")
        let firstRenderSegment = projectedTrack.waveformSegments[0]
        let secondRenderSegment = projectedTrack.waveformSegments[1]
        try require(
            abs(firstRenderSegment.outputStartProgress) < 0.000_001 &&
                abs(firstRenderSegment.outputEndProgress - 0.5) < 0.000_001 &&
                abs(firstRenderSegment.sourceStartProgress) < 0.000_001 &&
                abs(firstRenderSegment.gainStart) < 0.000_001,
            "track inspector altered the leading waveform segment"
        )
        try require(
            abs(secondRenderSegment.outputStartProgress - 0.5) < 0.000_001 &&
                abs(secondRenderSegment.outputEndProgress - 1) < 0.000_001 &&
                abs(secondRenderSegment.sourceEndProgress - 1) < 0.000_001 &&
                abs(secondRenderSegment.gainEnd) < 0.000_001,
            "track inspector altered the trailing waveform segment"
        )
        try require(
            projectedTrack.transcript == transcript &&
                abs((projectedTrack.durationHint ?? 0) - 24) < 0.000_001,
            "track inspector altered the transcript or track duration"
        )

        let persistedInspectorState = SoundtimeProject.FocusedClipInspectorState(
            trackID: trackID,
            clipID: clipID.rawValue,
            preferredHeight: 318,
            viewport: SoundtimeProject.TimelineViewport(
                startProgress: 0.125,
                durationProgress: 0.375
            ),
            localPlayheadProgress: 0.42,
            localSelection: SoundtimeProject.TimelineSelectionRange(
                startProgress: 0.2,
                endProgress: 0.55,
                trackID: trackID
            ),
            displaysWholeTrack: true
        )
        let persistedProject = SoundtimeProject(
            tracks: [
                SoundtimeProject.Track(
                    id: trackID,
                    name: "Voice",
                    filePath: "/tmp/voice.wav",
                    volume: 1,
                    isMuted: false,
                    isSoloed: false,
                    clipNames: [
                        clipID.rawValue: "Opening",
                        secondClipID.rawValue: "Closing",
                    ]
                ),
            ],
            windowLayout: nil,
            masterVolume: nil,
            timelineViewport: nil,
            focusedClipInspectorState: persistedInspectorState,
            selectedClipState: SoundtimeProject.SelectedClipState(
                trackID: trackID,
                clipID: clipID.rawValue
            ),
            selectedClipStates: [
                SoundtimeProject.SelectedClipState(
                    trackID: trackID,
                    clipID: clipID.rawValue
                ),
                SoundtimeProject.SelectedClipState(
                    trackID: trackID,
                    clipID: secondClipID.rawValue
                ),
            ],
            timelineEndTime: 31.25
        )
        let restoredProject = try JSONDecoder().decode(
            SoundtimeProject.self,
            from: JSONEncoder().encode(persistedProject)
        )
        let restoredInspectorState = try requireValue(
            restoredProject.focusedClipInspectorState,
            "focused clip inspector state was lost during project persistence"
        )
        try require(
            restoredInspectorState.trackID == trackID &&
                restoredInspectorState.clipID == clipID.rawValue &&
                abs(restoredInspectorState.preferredHeight - 318) < 0.000_001 &&
                abs((restoredInspectorState.viewport?.startProgress ?? -1) - 0.125) < 0.000_001 &&
                abs((restoredInspectorState.viewport?.durationProgress ?? -1) - 0.375) < 0.000_001 &&
                abs(restoredInspectorState.localPlayheadProgress - 0.42) < 0.000_001 &&
                abs((restoredInspectorState.localSelection?.startProgress ?? -1) - 0.2) < 0.000_001 &&
                abs((restoredInspectorState.localSelection?.endProgress ?? -1) - 0.55) < 0.000_001 &&
                restoredInspectorState.displaysWholeTrack == true,
            "track inspector state changed during project persistence"
        )
        try require(
            restoredProject.tracks.first?.clipNames?[clipID.rawValue] == "Opening" &&
                restoredProject.selectedClipState?.trackID == trackID &&
                restoredProject.selectedClipState?.clipID == clipID.rawValue &&
                restoredProject.selectedClipStates?.count == 2 &&
                Set(restoredProject.selectedClipStates?.map(\.clipID) ?? []) == [
                    clipID.rawValue,
                    secondClipID.rawValue,
                ] &&
                abs((restoredProject.timelineEndTime ?? -1) - 31.25) < 0.000_001,
            "clip selection set, identity, or authored timeline end was lost during project persistence"
        )
    }

    private static func verifyMultiClipSelectionReduction() throws {
        let trackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000094") ?? UUID()
        let first = TimelineClipSelectionKey(
            trackID: trackID,
            clipID: AudioTimelineClipID(
                rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000093") ?? UUID()
            )
        )
        let second = TimelineClipSelectionKey(
            trackID: trackID,
            clipID: AudioTimelineClipID(
                rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000092") ?? UUID()
            )
        )
        var selection = TimelineClipSelectionState()

        selection.apply(first, intent: .replace)
        selection.apply(second, intent: .toggle)
        try require(
            selection.keys == [first, second] && selection.primary == second,
            "command-click did not add a second clip while making it primary"
        )

        selection.apply(first, intent: .toggle)
        try require(
            selection.keys == [second] && selection.primary == second,
            "command-clicking a non-primary selected clip disturbed the remaining primary"
        )

        selection.apply(second, intent: .toggle)
        try require(
            selection.keys.isEmpty && selection.primary == nil,
            "command-clicking the final selected clip did not clear clip selection"
        )

        selection.apply(first, intent: .replace)
        selection.apply(second, intent: .additive)
        try require(
            selection.keys == [first, second] && selection.primary == second,
            "additive marquee selection did not retain the existing clip selection"
        )

        selection.apply(first, intent: .range)
        try require(
            selection.keys == [first, second] && selection.primary == first,
            "range selection did not preserve the selected set while advancing the anchor target"
        )
    }

    private static func verifyClipMovePreviewTranslatesWaveformRigidly() throws {
        let trackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000097") ?? UUID()
        let destinationTrackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000095") ?? UUID()
        let clipID = AudioTimelineClipID(
            rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000096") ?? UUID()
        )
        let segment = TimelineRenderState.Track.WaveformSegment(
            outputStartProgress: 0.25,
            outputEndProgress: 0.75,
            sourceStartProgress: 0.10,
            sourceEndProgress: 0.90,
            gainStart: 0.35,
            gainEnd: 0.80
        )
        let preview = TimelineClipDragPreview(
            trackID: trackID,
            destinationTrackID: destinationTrackID,
            clipID: clipID,
            originalStartProjectProgress: 0.05,
            originalEndProjectProgress: 0.15,
            presentedStartProjectProgress: 0.70,
            presentedEndProjectProgress: 0.80,
            kind: .move
        )
        let presentation = try requireValue(
            TimelineRenderer.clipDragPresentedWaveformSegment(
                segment,
                trackID: trackID,
                trackDurationProgress: 0.20,
                preview: preview
            ),
            "clip move preview discarded its waveform segment"
        )

        try require(
            abs(presentation.outputStartProjectProgress - 0.70) < 0.000_001 &&
                abs(presentation.outputEndProjectProgress - 0.80) < 0.000_001,
            "clip move preview did not move both waveform edges by the clip delta"
        )
        try require(
            abs(
                (presentation.outputEndProjectProgress - presentation.outputStartProjectProgress) - 0.10
            ) < 0.000_001,
            "clip move preview changed the waveform's rendered width"
        )
        try require(
            presentation.segment.sourceStartProgress == segment.sourceStartProgress &&
                presentation.segment.sourceEndProgress == segment.sourceEndProgress &&
                presentation.segment.gainStart == segment.gainStart &&
                presentation.segment.gainEnd == segment.gainEnd,
            "clip move preview changed source samples or gain while translating the waveform"
        )
        try require(
            presentation.outputStartProjectProgress > 0.20,
            "clip move preview was clamped to the track's previously committed end"
        )
        try require(
            preview.destinationTrackID == destinationTrackID,
            "cross-track preview lost its destination lane identity"
        )

        let duplicatePreview = TimelineClipDragPreview(
            trackID: trackID,
            destinationTrackID: destinationTrackID,
            clipID: clipID,
            originalStartProjectProgress: 0.05,
            originalEndProjectProgress: 0.15,
            presentedStartProjectProgress: 0.40,
            presentedEndProjectProgress: 0.50,
            kind: .duplicate
        )
        let duplicatePresentation = try requireValue(
            TimelineRenderer.clipDragPresentedWaveformSegment(
                segment,
                trackID: trackID,
                trackDurationProgress: 0.20,
                preview: duplicatePreview
            ),
            "option-drag duplicate preview discarded its waveform segment"
        )
        try require(
            abs(duplicatePresentation.outputStartProjectProgress - 0.40) < 0.000_001 &&
                abs(duplicatePresentation.outputEndProjectProgress - 0.50) < 0.000_001 &&
                duplicatePresentation.segment.sourceStartProgress == segment.sourceStartProgress &&
                duplicatePresentation.segment.sourceEndProgress == segment.sourceEndProgress,
            "option-drag duplicate preview changed source geometry instead of translating it"
        )
    }

    private static func verifyResidentTileMovePreviewTranslatesRigidly() throws {
        let trackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000087") ?? UUID()
        let destinationTrackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000088") ?? UUID()
        let preview = TimelineClipDragPreview(
            trackID: trackID,
            destinationTrackID: destinationTrackID,
            clipID: AudioTimelineClipID(
                rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000089") ?? UUID()
            ),
            originalStartProjectProgress: 0.10,
            originalEndProjectProgress: 0.40,
            presentedStartProjectProgress: 0.45,
            presentedEndProjectProgress: 0.75,
            kind: .move
        )
        let sourceStart = 18.0
        let sourceEnd = 30.0
        let presentations = TimelineRenderer.clipDragPresentedResidentWaveformTiles(
            trackID: trackID,
            outputStartProjectProgress: 0.22,
            outputEndProjectProgress: 0.34,
            sourceStartTime: sourceStart,
            sourceEndTime: sourceEnd,
            previews: [preview]
        )
        let presentation = try requireValue(
            presentations.first,
            "resident tile move preview discarded a drawable tile"
        )
        try require(
            presentations.count == 1 &&
                presentation.destinationTrackID == destinationTrackID,
            "resident tile move preview remained in its committed lane"
        )
        try require(
            abs(presentation.outputStartProjectProgress - 0.57) < 0.000_001 &&
                abs(presentation.outputEndProjectProgress - 0.69) < 0.000_001,
            "resident tile move preview did not translate both output edges equally"
        )
        try require(
            abs(
                (presentation.outputEndProjectProgress - presentation.outputStartProjectProgress) - 0.12
            ) < 0.000_001,
            "resident tile move preview compressed the waveform during drag"
        )
        try require(
            presentation.sourceStartTime == sourceStart &&
                presentation.sourceEndTime == sourceEnd,
            "resident tile move preview changed the sampled source interval"
        )

        let duplicatePreview = TimelineClipDragPreview(
            trackID: trackID,
            destinationTrackID: destinationTrackID,
            clipID: preview.clipID,
            originalStartProjectProgress: 0.10,
            originalEndProjectProgress: 0.40,
            presentedStartProjectProgress: 0.50,
            presentedEndProjectProgress: 0.80,
            kind: .duplicate
        )
        let duplicatePresentations = TimelineRenderer.clipDragPresentedResidentWaveformTiles(
            trackID: trackID,
            outputStartProjectProgress: 0.22,
            outputEndProjectProgress: 0.34,
            sourceStartTime: sourceStart,
            sourceEndTime: sourceEnd,
            previews: [duplicatePreview]
        )
        try require(
            duplicatePresentations.count == 2 &&
                duplicatePresentations[0].destinationTrackID == trackID &&
                duplicatePresentations[1].destinationTrackID == destinationTrackID,
            "resident tile duplicate preview did not retain original and translated instances"
        )
    }

    private static func verifyClipDragCanExtendWaveformPastCommittedTrackEnd() throws {
        let committedTrackEnd: Float = 0.24
        let movedStart: Float = 0.31
        let movedEnd: Float = 0.55
        let domain = TimelineRenderer.waveformShaderOutputDomain(
            trackDurationProgress: committedTrackEnd,
            defaultOutputStartProjectProgress: 0,
            defaultOutputEndProjectProgress: committedTrackEnd,
            requestedOutputRange: SIMD2<Float>(movedStart, movedEnd)
        )

        try require(
            abs(domain.outputStartProjectProgress - movedStart) < 0.000_001 &&
                abs(domain.outputEndProjectProgress - movedEnd) < 0.000_001,
            "live clip drag clamped the moving waveform to its original track endpoint"
        )
        try require(
            abs(
                (domain.outputEndProjectProgress - domain.outputStartProjectProgress) -
                    (movedEnd - movedStart)
            ) < 0.000_001,
            "live clip drag compressed the waveform after crossing its original right edge"
        )
        try require(
            abs(domain.renderEndProjectProgress - movedEnd) < 0.000_001,
            "waveform shader retained the committed track end instead of the live drag endpoint"
        )
    }

    private static func verifyCommittedMixedSourceWaveformsRenderInDestinationLane(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let renderer = try TimelineRenderer(device: device, pixelFormat: pixelFormat)
        let sourceLaneID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000091") ?? UUID()
        let destinationLaneID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000092") ?? UUID()
        let firstLayerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000093") ?? UUID()
        let secondLayerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000094") ?? UUID()
        let firstSegment = TimelineRenderState.Track.WaveformSegment(
            outputStartProgress: 0.08,
            outputEndProgress: 0.38,
            sourceStartProgress: 0,
            sourceEndProgress: 1
        )
        let secondSegment = TimelineRenderState.Track.WaveformSegment(
            outputStartProgress: 0.58,
            outputEndProgress: 0.92,
            sourceStartProgress: 0,
            sourceEndProgress: 1
        )
        let firstLayer = TimelineRenderState.Track.WaveformLayer(
            id: firstLayerID,
            sourceID: TimelineMediaSourceID(rawValue: "smoke-source-a"),
            waveformVersion: 1,
            waveformOverview: makeDetailedWaveformOverview(duration: 8, binCount: 4_096, seed: 19),
            waveformSegments: [firstSegment]
        )
        let secondLayer = TimelineRenderState.Track.WaveformLayer(
            id: secondLayerID,
            sourceID: TimelineMediaSourceID(rawValue: "smoke-source-b"),
            waveformVersion: 1,
            waveformOverview: makeDetailedWaveformOverview(duration: 11, binCount: 4_096, seed: 73),
            waveformSegments: [secondSegment]
        )
        let sourceLaneAfterMove = TimelineRenderState.Track(
            id: sourceLaneID,
            waveformVersion: 0,
            waveformOverview: nil,
            durationHint: 12,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            hasWaveform: false,
            usesSourceWaveformLayers: true
        )
        let sourceLaneBeforeMove = TimelineRenderState.Track(
            id: sourceLaneID,
            waveformVersion: 0,
            waveformOverview: nil,
            durationHint: 12,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            usesSourceWaveformLayers: true,
            waveformLayers: [firstLayer]
        )
        let destinationWithoutWaveforms = TimelineRenderState.Track(
            id: destinationLaneID,
            waveformVersion: 0,
            waveformOverview: nil,
            durationHint: 12,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            hasWaveform: false,
            clipRanges: [
                TimelineRenderState.ClipRange(startProgress: 0.08, endProgress: 0.38),
                TimelineRenderState.ClipRange(startProgress: 0.58, endProgress: 0.92),
            ],
            usesSourceWaveformLayers: true
        )
        let destinationBeforeMove = TimelineRenderState.Track(
            id: destinationLaneID,
            waveformVersion: 0,
            waveformOverview: nil,
            durationHint: 12,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: destinationWithoutWaveforms.clipRanges,
            usesSourceWaveformLayers: true,
            waveformLayers: [secondLayer]
        )
        let destinationWithWaveforms = TimelineRenderState.Track(
            id: destinationLaneID,
            waveformVersion: 0,
            waveformOverview: nil,
            durationHint: 12,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: destinationWithoutWaveforms.clipRanges,
            usesSourceWaveformLayers: true,
            waveformLayers: [firstLayer, secondLayer]
        )
        let timestamp = CACurrentMediaTime()
        let baseFrame = try renderTimeline(
            renderer: renderer,
            tracks: [sourceLaneAfterMove, destinationWithoutWaveforms],
            viewport: .full,
            playheadProgress: 0.49,
            isPlaybackActive: false,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        renderer.displayTracks(
            [sourceLaneBeforeMove, destinationBeforeMove],
            animateWaveformTransition: false
        )
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: timestamp + 0.01
        )
        let beforeMoveFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp + 0.25,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        renderer.displayTracks(
            [sourceLaneAfterMove, destinationWithWaveforms],
            animateWaveformTransition: false
        )
        let waveformFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp + 0.30,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let layout = TimelineTrackLayout.default.resolved(
            totalTrackCount: 2,
            viewportHeight: Float(waveformFrame.summary.height)
        )
        let sourceFrame = try requireValue(
            layout.laneFrame(forTrackIndex: 0),
            "mixed-source smoke had no source lane"
        )
        let destinationFrame = try requireValue(
            layout.laneFrame(forTrackIndex: 1),
            "mixed-source smoke had no destination lane"
        )
        func rows(for lane: TimelineTrackLaneFrame) -> Range<Int> {
            max(Int(ceil(lane.top * Float(waveformFrame.summary.height))) + 4, 0)..<min(
                Int(floor(lane.bottom * Float(waveformFrame.summary.height))) - 4,
                waveformFrame.summary.height
            )
        }
        func columns(_ start: Float, _ end: Float) -> Range<Int> {
            max(Int(Float(waveformFrame.summary.width) * start), 0)..<min(
                Int(Float(waveformFrame.summary.width) * end),
                waveformFrame.summary.width
            )
        }

        let firstSourceDifference = pixelDifferenceCount(
            baseFrame.bytes,
            waveformFrame.bytes,
            width: waveformFrame.summary.width,
            columns: columns(0.10, 0.36),
            rows: rows(for: destinationFrame),
            threshold: 8
        )
        let secondSourceDifference = pixelDifferenceCount(
            baseFrame.bytes,
            waveformFrame.bytes,
            width: waveformFrame.summary.width,
            columns: columns(0.60, 0.90),
            rows: rows(for: destinationFrame),
            threshold: 8
        )
        let oldLaneDifference = pixelDifferenceCount(
            baseFrame.bytes,
            waveformFrame.bytes,
            width: waveformFrame.summary.width,
            columns: columns(0.10, 0.90),
            rows: rows(for: sourceFrame),
            threshold: 8
        )
        let sourceWasVisibleBeforeMove = pixelDifferenceCount(
            baseFrame.bytes,
            beforeMoveFrame.bytes,
            width: waveformFrame.summary.width,
            columns: columns(0.10, 0.36),
            rows: rows(for: sourceFrame),
            threshold: 8
        )
        try require(
            sourceWasVisibleBeforeMove > 500,
            "mixed-source smoke never rendered the source before its cross-track move"
        )
        try require(
            firstSourceDifference > 500,
            "first committed source layer did not render in the destination lane"
        )
        try require(
            secondSourceDifference > 500,
            "cross-track source layer disappeared after the move committed"
        )
        try require(
            oldLaneDifference < waveformFrame.summary.width * 2,
            "committed cross-track waveform remained in its previous lane (changed pixels: \(oldLaneDifference))"
        )

        let drawableSources = renderer.visibleWaveformDrawableBinCounts(
            drawableSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            drawableSources.count >= 2,
            "mixed-source destination did not retain both source-resident GPU buffers"
        )
    }

    private static func verifyLegacyClipIdentityMigration() throws {
        let state = AudioFileEditTimeline.PersistentState(
            sourceFrameCount: 1_000,
            sourceSampleRate: 48_000,
            segments: [
                AudioFileEditTimeline.PersistentSegment(
                    sourceStartFrame: 0,
                    frameCount: 400,
                    gainStart: 1,
                    gainEnd: 1
                ),
                AudioFileEditTimeline.PersistentSegment(
                    sourceStartFrame: 400,
                    frameCount: 600,
                    gainStart: 1,
                    gainEnd: 1,
                    startsNewClip: true
                ),
            ]
        )
        let firstRestore = try requireValue(
            AudioFileEditTimeline(persistentState: state),
            "first legacy timeline restore failed"
        )
        let secondRestore = try requireValue(
            AudioFileEditTimeline(persistentState: state),
            "second legacy timeline restore failed"
        )
        let firstIDs = firstRestore.clipRanges.map(\.id)
        let secondIDs = secondRestore.clipRanges.map(\.id)
        try require(firstIDs.count == 2, "legacy boundaries did not restore two clips")
        try require(firstIDs == secondIDs, "legacy clip identities changed between restores")
        try require(firstIDs[0] != firstIDs[1], "legacy clip boundaries shared one identity")

        var pasteTimeline = AudioFileEditTimeline(sourceFrameCount: 1_000, sourceSampleRate: 48_000)
        let copiedClip = try requireValue(
            pasteTimeline.clip(for: 0..<100),
            "file-backed timeline did not copy a clip"
        )
        try require(
            pasteTimeline.insert(copiedClip, atFrame: 1_000) == 100 &&
                pasteTimeline.insert(copiedClip, atFrame: 1_100) == 100,
            "file-backed timeline did not insert repeated clipboard clips"
        )
        let pastedIDs = pasteTimeline.clipRanges.map(\.id)
        try require(Set(pastedIDs).count == 3, "repeated paste reused a clip identity")
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

        guard let importedOverview = residentTrack.waveformOverview else {
            throw SmokeError.checkFailed("pending import fixture had no waveform to publish")
        }
        let resolvedImportedTrack = TimelineRenderState.Track(
            id: pendingTrack.id,
            waveformVersion: 1,
            waveformOverview: importedOverview,
            durationHint: importedOverview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
        )
        renderer.displayTracks(
            [residentTrack, resolvedImportedTrack],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: true,
            allowImmediateInteractiveWaveformPrewarm: false
        )
        try require(
            renderer.prepareFirstPaintWaveformShaderBuffers(
                drawableSize: viewportSize,
                backingScale: backingScale
            ),
            "freshly imported waveform did not become resident for its first paint"
        )
        let resolvedFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp + 0.02,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let resolvedSecondLaneWaveformPixels = nonBackgroundPixelCount(
            inRows: secondRows,
            bytes: resolvedFrame.bytes,
            width: resolvedFrame.summary.width,
            backgroundLuminanceThreshold: 110
        )
        try require(
            resolvedSecondLaneWaveformPixels > 1_500,
            "freshly imported waveform stayed blank after first-preview publication"
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

    private static func verifyEmptyCanonicalLaneDoesNotBlockLongWaveformPromotion(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let renderer = try TimelineRenderer(device: device, pixelFormat: pixelFormat)
        let shortTrackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000401") ?? UUID()
        let longTrackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000402") ?? UUID()
        let longLayerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000403") ?? UUID()
        let longDuration = 7_436.855
        let viewport = TimelineViewport(startProgress: 0, durationProgress: 0.004_6)
        let shortLaunchOverview = makeDetailedWaveformOverview(duration: 150, binCount: 4_096, seed: 31)
        let longLaunchOverview = makeDetailedWaveformOverview(
            duration: longDuration,
            binCount: 32_768,
            seed: 47
        )
        let longCanonicalOverview = makeDetailedWaveformOverview(
            duration: longDuration,
            binCount: 32_768,
            seed: 47
        )
        let launchTracks = [
            TimelineRenderState.Track(
                id: shortTrackID,
                waveformVersion: 1,
                waveformOverview: shortLaunchOverview,
                durationHint: shortLaunchOverview.duration,
                volume: 1,
                isMuted: false,
                isSoloed: false,
                clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
            ),
            TimelineRenderState.Track(
                id: longTrackID,
                waveformVersion: 1,
                waveformOverview: longLaunchOverview,
                durationHint: longDuration,
                volume: 1,
                isMuted: false,
                isSoloed: false,
                clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
            ),
        ]
        let canonicalLongLayer = TimelineRenderState.Track.WaveformLayer(
            id: longLayerID,
            sourceID: TimelineMediaSourceID(rawValue: "long-mp3-source"),
            waveformVersion: 2,
            waveformOverview: longCanonicalOverview,
            waveformSegments: [
                TimelineRenderState.Track.WaveformSegment(
                    outputStartProgress: 0,
                    outputEndProgress: 1,
                    sourceStartProgress: 0,
                    sourceEndProgress: 1
                ),
            ]
        )
        let canonicalTracks = [
            TimelineRenderState.Track(
                id: shortTrackID,
                waveformVersion: 1,
                waveformOverview: nil,
                durationHint: 0,
                volume: 1,
                isMuted: false,
                isSoloed: false,
                hasWaveform: true,
                usesSourceWaveformLayers: true,
                waveformLayers: []
            ),
            TimelineRenderState.Track(
                id: longTrackID,
                waveformVersion: 2,
                waveformOverview: nil,
                durationHint: longDuration,
                volume: 1,
                isMuted: false,
                isSoloed: false,
                clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)],
                usesSourceWaveformLayers: true,
                waveformLayers: [canonicalLongLayer]
            ),
        ]
        let blankLongTrack = TimelineRenderState.Track(
            id: longTrackID,
            waveformVersion: 0,
            waveformOverview: nil,
            durationHint: longDuration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            hasWaveform: false,
            clipRanges: canonicalTracks[1].clipRanges,
            usesSourceWaveformLayers: true
        )
        let timestamp = CACurrentMediaTime()
        let blankFrame = try renderTimeline(
            renderer: renderer,
            tracks: [canonicalTracks[0], blankLongTrack],
            viewport: viewport,
            playheadProgress: 0.002,
            isPlaybackActive: false,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        renderer.displayTracks(launchTracks, animateWaveformTransition: false)
        renderer.displayViewport(viewport, marksInteraction: false)
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: timestamp + 0.05
        )
        renderer.displayTracks(canonicalTracks, animateWaveformTransition: true)
        renderer.prepareFirstPaintWaveformShaderBuffers(
            drawableSize: viewportSize,
            backingScale: backingScale
        )
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: timestamp + 0.20,
            maximumAttempts: 300,
            failureContext: "empty canonical lane beside a long source"
        )
        let promotedFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp + 0.55,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        try require(
            !renderer.visibleWaveformDrawableBinCounts(
                drawableSize: viewportSize,
                backingScale: backingScale
            ).isEmpty,
            "an empty canonical lane with stale launch-preview metadata blocked the long source's continuity waveform"
        )
        let layout = TimelineTrackLayout.default.resolved(
            totalTrackCount: 2,
            viewportHeight: Float(promotedFrame.summary.height)
        )
        let longLane = try requireValue(
            layout.laneFrame(forTrackIndex: 1),
            "empty canonical lane smoke had no long waveform lane"
        )
        let rows = max(Int(ceil(longLane.top * Float(promotedFrame.summary.height))) + 4, 0)..<min(
            Int(floor(longLane.bottom * Float(promotedFrame.summary.height))) - 4,
            promotedFrame.summary.height
        )
        let changedPixels = pixelDifferenceCount(
            blankFrame.bytes,
            promotedFrame.bytes,
            width: promotedFrame.summary.width,
            columns: 0..<promotedFrame.summary.width,
            rows: rows,
            threshold: 8
        )
        try require(
            changedPixels > 1_000,
            "long canonical waveform remained visually blank after promotion (changed pixels: \(changedPixels))"
        )
    }

    private static func verifyLongWaveformRemainsVisibleAcrossZoomSweep(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let renderer = try TimelineRenderer(device: device, pixelFormat: pixelFormat)
        let trackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000411") ?? UUID()
        let layerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000412") ?? UUID()
        let duration = 7_436.855
        let overview = makeDetailedWaveformOverview(
            duration: duration,
            binCount: 32_768,
            seed: 61
        )
        let layer = TimelineRenderState.Track.WaveformLayer(
            id: layerID,
            sourceID: TimelineMediaSourceID(rawValue: "long-zoom-sweep-source"),
            waveformVersion: 1,
            waveformOverview: overview,
            waveformSegments: [
                TimelineRenderState.Track.WaveformSegment(
                    outputStartProgress: 0,
                    outputEndProgress: 1,
                    sourceStartProgress: 0,
                    sourceEndProgress: 1
                ),
            ]
        )
        let track = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 1,
            waveformOverview: nil,
            durationHint: duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)],
            usesSourceWaveformLayers: true,
            waveformLayers: [layer]
        )
        let blankTrack = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 0,
            waveformOverview: nil,
            durationHint: duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            hasWaveform: false,
            clipRanges: track.clipRanges,
            usesSourceWaveformLayers: true
        )
        let zoomLevels: [Float] = [1, 0.20, 0.08, 0.04, 0.02, 0.008, 0.002]
        let timestamp = CACurrentMediaTime()

        for (index, durationProgress) in zoomLevels.enumerated() {
            let maximumStart = max(1 - durationProgress, 0)
            let startProgress = min(max(0.41 - durationProgress * 0.5, 0), maximumStart)
            let viewport = TimelineViewport(
                startProgress: startProgress,
                durationProgress: durationProgress
            )
            let blankFrame = try renderTimeline(
                renderer: renderer,
                tracks: [blankTrack],
                viewport: viewport,
                playheadProgress: startProgress + durationProgress * 0.5,
                isPlaybackActive: false,
                displayTimestamp: timestamp + Double(index),
                texture: texture,
                viewportSize: viewportSize,
                backingScale: backingScale
            )
            renderer.displayTracks([track], animateWaveformTransition: false)
            renderer.displayViewport(viewport, marksInteraction: false)
            renderer.prepareFirstPaintWaveformShaderBuffers(
                drawableSize: viewportSize,
                backingScale: backingScale
            )
            try waitForVisibleWaveformBuffers(
                renderer: renderer,
                texture: texture,
                viewportSize: viewportSize,
                backingScale: backingScale,
                displayTimestamp: timestamp + Double(index) + 0.05,
                maximumAttempts: 160,
                failureContext: "long waveform zoom sweep at duration progress \(durationProgress)"
            )
            let waveformFrame = try renderCurrentTimeline(
                renderer: renderer,
                displayTimestamp: timestamp + Double(index) + 0.25,
                texture: texture,
                viewportSize: viewportSize,
                backingScale: backingScale
            )
            let changedPixels = pixelDifferenceCount(
                blankFrame.bytes,
                waveformFrame.bytes,
                width: waveformFrame.summary.width,
                columns: 0..<waveformFrame.summary.width,
                rows: 28..<waveformFrame.summary.height,
                threshold: 8
            )
            try require(
                changedPixels > 900,
                "long waveform disappeared at duration progress \(durationProgress) (changed pixels: \(changedPixels))"
            )
            try require(
                !renderer.visibleWaveformDrawableBinCounts(
                    drawableSize: viewportSize,
                    backingScale: backingScale
                ).isEmpty,
                "long waveform had no drawable mip at duration progress \(durationProgress)"
            )
        }
    }

    private static func verifyResidentTilesRefineDeepZoom(
        wavURL: URL,
        decodedBuffer: DecodedAudioBuffer,
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let renderer = try TimelineRenderer(device: device, pixelFormat: pixelFormat)
        let tileSource = try WaveformTileBuildSource(wavURL: wavURL, channelMode: .monoMix)
        let trackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000421") ?? UUID()
        let layerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000422") ?? UUID()
        let coarseOverview = WaveformOverviewBuilder.build(from: decodedBuffer, targetBinCount: 256)
        let layer = TimelineRenderState.Track.WaveformLayer(
            id: layerID,
            sourceID: TimelineMediaSourceID(rawValue: "resident-detail-source"),
            waveformVersion: 1,
            waveformOverview: coarseOverview,
            waveformSegments: [
                TimelineRenderState.Track.WaveformSegment(
                    outputStartProgress: 0,
                    outputEndProgress: 1,
                    sourceStartProgress: 0,
                    sourceEndProgress: 1
                ),
            ],
            waveformTileSource: tileSource
        )
        let track = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 1,
            waveformOverview: nil,
            durationHint: coarseOverview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)],
            usesSourceWaveformLayers: true,
            waveformLayers: [layer]
        )
        let viewport = TimelineViewport(startProgress: 0.42, durationProgress: 0.002)
        let timestamp = CACurrentMediaTime()
        let continuityFrame = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: viewport,
            playheadProgress: 0.421,
            isPlaybackActive: false,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        var detailedFrame = continuityFrame
        var residentDrawCount = 0
        for attempt in 0..<120 where residentDrawCount == 0 {
            usleep(20_000)
            detailedFrame = try renderCurrentTimeline(
                renderer: renderer,
                displayTimestamp: timestamp + 0.15 + Double(attempt) * 0.02,
                texture: texture,
                viewportSize: viewportSize,
                backingScale: backingScale
            )
            residentDrawCount = renderer.gpuResidentWaveformDrawInstanceCountForSmokeTesting()
        }

        try require(
            residentDrawCount > 0,
            "deep zoom never promoted to a resident source waveform tile"
        )
        let changedPixels = pixelDifferenceCount(
            continuityFrame.bytes,
            detailedFrame.bytes,
            width: detailedFrame.summary.width,
            columns: 0..<detailedFrame.summary.width,
            rows: 28..<detailedFrame.summary.height,
            threshold: 6
        )
        try require(
            changedPixels > 100,
            "resident source tile did not visibly refine the deep-zoom waveform (changed pixels: \(changedPixels))"
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

    private static func verifyFadeMappingRendersOnFirstFrame(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float,
        frameStatsBox: FrameStatsBox
    ) throws {
        let baseFrame = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: .full,
            playheadProgress: 0,
            isPlaybackActive: false,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let fadedTrack = TimelineRenderState.Track(
            id: track.id,
            waveformVersion: track.waveformVersion,
            waveformOverview: track.waveformOverview,
            durationHint: track.durationHint,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            hasWaveform: track.hasWaveform,
            clipRanges: track.clipRanges,
            waveformSegments: [
                TimelineRenderState.Track.WaveformSegment(
                    outputStartProgress: 0,
                    outputEndProgress: 1,
                    sourceStartProgress: 0,
                    sourceEndProgress: 1,
                    gainStart: 0,
                    gainEnd: 1
                ),
            ],
            waveformTileSource: track.waveformTileSource,
            transcript: track.transcript
        )
        let fadedFrame = try renderTimeline(
            renderer: renderer,
            tracks: [fadedTrack],
            viewport: .full,
            playheadProgress: 0,
            isPlaybackActive: false,
            animateWaveformTransition: false,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let width = fadedFrame.summary.width
        let height = fadedFrame.summary.height
        let waveformRows = (height / 8)..<(height - height / 12)
        let fadeStartColumns = (width / 16)..<(width / 4)
        let fadeEndColumns = (width * 15 / 16)..<(width - 2)
        let changedNearFadeStart = pixelDifferenceCount(
            baseFrame.bytes,
            fadedFrame.bytes,
            width: width,
            columns: fadeStartColumns,
            rows: waveformRows,
            threshold: 8
        )
        let changedNearFadeEnd = pixelDifferenceCount(
            baseFrame.bytes,
            fadedFrame.bytes,
            width: width,
            columns: fadeEndColumns,
            rows: waveformRows,
            threshold: 8
        )
        try require(
            changedNearFadeStart > 500,
            "fade mapping did not change enough waveform pixels on its first rendered frame"
        )
        try require(
            changedNearFadeStart > changedNearFadeEnd * 2,
            "fade mapping did not visibly ramp from its attenuated start to its unchanged end"
        )

        // A completed effect changes only the segment mapping. Resizing the
        // retained selection must continue to reuse the resident source
        // waveform instead of rebuilding geometry or uploading bins.
        frameStatsBox.samples.removeAll()
        var frameDurations: [Double] = []
        frameDurations.reserveCapacity(36)
        let dragStartTimestamp = CACurrentMediaTime()
        for frameIndex in 0..<36 {
            let fraction = Double(frameIndex) / 35.0
            let selection = TimelineSelection(
                startProgress: 0.08,
                endProgress: 0.18 + fraction * 0.62,
                trackID: fadedTrack.id
            )
            let timestamp = dragStartTimestamp + Double(frameIndex) / 144.0
            renderer.publishInteractionSelectionDragSnapshot(TimelineSelectionDragSnapshot(
                selection: selection,
                leadingProgress: selection.endProgressFloat,
                velocityPixelsPerSecond: 1_400,
                direction: 1,
                timestamp: timestamp
            ))

            let renderPassDescriptor = makeRenderPassDescriptor(texture: texture)
            let renderStart = CACurrentMediaTime()
            let commandBuffer = renderer.renderOffscreen(
                renderPassDescriptor: renderPassDescriptor,
                viewportSize: viewportSize,
                backingScale: backingScale,
                displayTimestamp: timestamp,
                waitUntilCompleted: false
            )
            commandBuffer?.waitUntilCompleted()
            frameDurations.append((CACurrentMediaTime() - renderStart) * 1_000)
        }

        let p95Milliseconds = percentile(frameDurations, percentile: 0.95)
        try require(
            p95Milliseconds < selectionDragMicrobenchmarkBudgetMilliseconds,
            String(format: "post-effect selection resize p95 was too slow: %.2fms", p95Milliseconds)
        )
        let hotPathViolations = frameStatsBox.samples.filter {
            $0.waveformHotPathReason == "selection-drag" &&
                ($0.cpuWaveformVertexCount > 0 ||
                    $0.cpuWaveformFallbackDrawCount > 0 ||
                    $0.shaderBufferUploadCount > 0 ||
                    $0.shaderBufferUploadByteCount > 0)
        }
        try require(
            hotPathViolations.isEmpty,
            "post-effect selection resize rebuilt or uploaded waveform data"
        )
        renderer.publishInteractionSelectionDragSnapshot(nil)
        renderer.publishInteractionSelection(nil)
        renderer.displaySelection(nil, marksInteraction: false)
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

    private static func verifyRulerSeparatorIsContinuous(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        track: TimelineRenderState.Track
    ) throws {
        let viewportSize = CGSize(width: 960, height: 360)
        let backingScale: Float = 2
        let texture = try makeTexture(
            device: device,
            pixelFormat: pixelFormat,
            width: Int(viewportSize.width * CGFloat(backingScale)),
            height: Int(viewportSize.height * CGFloat(backingScale))
        )
        let renderer = try TimelineRenderer(device: device, pixelFormat: pixelFormat)
        let frame = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: .full,
            playheadProgress: 0.43,
            isPlaybackActive: false,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let separatorRow = max(
            Int((TimelineTrackLayout.defaultRulerLaneHeight * backingScale).rounded(.up)) - 1,
            0
        )
        var darkColumns: [Int] = []
        for column in 0..<frame.summary.width {
            let byteIndex = (separatorRow * frame.summary.width + column) * 4
            let blue = Int(frame.bytes[byteIndex])
            let green = Int(frame.bytes[byteIndex + 1])
            let red = Int(frame.bytes[byteIndex + 2])
            let luminance = (red * 54 + green * 183 + blue * 19) / 256
            if luminance < 34 {
                darkColumns.append(column)
            }
        }

        try require(
            darkColumns.isEmpty,
            "ruler separator contained dark gaps at columns \(darkColumns.prefix(12))"
        )
    }

    private static func verifyTrackLayoutGeometry() throws {
        let oneTrackLayout = TimelineTrackLayout.default.resolved(totalTrackCount: 1, viewportHeight: 360)
        try require(
            abs(oneTrackLayout.trackHeight - TimelineTrackLayout.defaultPreferredTrackHeight) < 0.000_1,
            "single-track layout stretched instead of using the default fixed track height"
        )
        try require(
            abs(oneTrackLayout.contentHeight - TimelineTrackLayout.defaultPreferredTrackHeight) < 0.000_1,
            "single-track content height did not match the fixed track height"
        )

        let threeTrackLayout = TimelineTrackLayout.default.resolved(totalTrackCount: 3, viewportHeight: 360)
        try require(
            abs(threeTrackLayout.trackHeight - TimelineTrackLayout.defaultPreferredTrackHeight) < 0.000_1,
            "3-track layout changed the default fixed track height"
        )
        try require(
            abs(threeTrackLayout.contentHeight - TimelineTrackLayout.defaultPreferredTrackHeight * 3) < 0.000_1,
            "3-track content height did not preserve three fixed-height lanes"
        )
        try require(threeTrackLayout.isScrollable, "3 fixed-height tracks should scroll in a short viewport")
        try require(threeTrackLayout.visibleRange(overscan: 0) == 0..<2, "3-track visible range was wrong")
        try require(threeTrackLayout.trackIndex(atYFromTop: 1) == nil, "ruler y should not hit a track")
        try require(
            threeTrackLayout.trackIndex(atYFromTop: threeTrackLayout.rulerLaneHeight + 1) == 0,
            "first track y did not hit first track"
        )
        try require(threeTrackLayout.trackIndex(atYFromTop: 180) == 0, "middle y did not hit first fixed-height track")
        try require(threeTrackLayout.trackIndex(atYFromTop: 359) == 1, "bottom y did not hit second track")

        let fiveTrackLayout = TimelineTrackLayout.default.resolved(totalTrackCount: 5, viewportHeight: 360)
        try require(
            abs(fiveTrackLayout.trackHeight - TimelineTrackLayout.defaultPreferredTrackHeight) < 0.000_1,
            "5-track layout did not use preferred track height"
        )
        try require(fiveTrackLayout.isScrollable, "5-track layout should scroll")
        try require(fiveTrackLayout.visibleRange(overscan: 0) == 0..<2, "5-track initial visible range was wrong")

        let scrolled = TimelineTrackLayout(scrollOffset: 260).resolved(totalTrackCount: 5, viewportHeight: 360)
        try require(scrolled.visibleRange(overscan: 0) == 1..<3, "scrolled visible range was wrong")
        try require(scrolled.trackIndex(atYFromTop: 1) == nil, "scrolled ruler y should not hit a track")
        try require(
            scrolled.trackIndex(atYFromTop: scrolled.rulerLaneHeight + 1) == 1,
            "scrolled first track y did not hit expected track"
        )
        try require(scrolled.trackIndex(atYFromTop: 359) == 2, "scrolled bottom y did not hit expected track")

        guard let partiallyVisibleBottomLane = scrolled.lanePixelFrame(forTrackIndex: 2) else {
            throw SmokeError.checkFailed("partially visible bottom lane geometry was unavailable")
        }
        let projectedBottomLane = partiallyVisibleBottomLane.appKitFrame(
            viewportWidth: 240,
            viewportHeight: 360
        )
        try require(
            abs(Float(projectedBottomLane.height) - scrolled.trackHeight) < 0.000_1,
            "partially visible AppKit lane was compressed to its visible fragment"
        )
        try require(
            projectedBottomLane.minY < 0 && partiallyVisibleBottomLane.intersectsViewport(height: 360),
            "partially visible AppKit lane did not extend through the viewport boundary"
        )

        let partialChrome = TimelineClipChromeMetrics.verticalGeometry(
            laneTop: 300,
            laneBottom: 500,
            viewportHeight: 360
        )
        try require(
            abs(partialChrome.clipBottom - partialChrome.clipTop - 200) < 0.000_1,
            "partially visible clip chrome was compressed to the viewport"
        )
        try require(
            abs(partialChrome.headerHeight - TimelineClipChromeMetrics.maximumHeaderHeight) < 0.000_1,
            "partially visible clip header changed height at the viewport boundary"
        )
        let partialAutomationRange = TimelineClipChromeMetrics.automationRange(
            laneTop: 300,
            laneBottom: 500,
            viewportHeight: 360
        )
        try require(
            partialAutomationRange.bottom > 360 &&
                abs(partialAutomationRange.top - partialChrome.headerBottom) < 0.000_1,
            "partially visible automation geometry was compressed to the viewport"
        )
        try require(
            TimelineClipChromeMetrics.cornerArcSegments >= 4,
            "narrow clip corners regressed to visibly beveled polygon geometry"
        )

        let userZoomedLayout = TimelineTrackLayout.default.withPreferredTrackHeight(236)
        let oneZoomedTrack = userZoomedLayout.resolved(totalTrackCount: 1, viewportHeight: 600)
        let fourZoomedTracks = userZoomedLayout.resolved(totalTrackCount: 4, viewportHeight: 600)
        try require(
            abs(oneZoomedTrack.trackHeight - 236) < 0.000_1 &&
                abs(fourZoomedTracks.trackHeight - 236) < 0.000_1,
            "adding tracks did not preserve the user's vertical zoom height"
        )

        let tallerViewportLayout = TimelineTrackLayout.default.resolved(
            totalTrackCount: 3,
            viewportHeight: 640
        )
        guard
            let compactFirstLane = threeTrackLayout.lanePixelFrame(forTrackIndex: 0),
            let compactSecondLane = threeTrackLayout.lanePixelFrame(forTrackIndex: 1),
            let tallFirstLane = tallerViewportLayout.lanePixelFrame(forTrackIndex: 0),
            let tallSecondLane = tallerViewportLayout.lanePixelFrame(forTrackIndex: 1)
        else {
            throw SmokeError.checkFailed("live-resize lane pixel geometry was unavailable")
        }
        try require(
            compactFirstLane == tallFirstLane && compactSecondLane == tallSecondLane,
            "fixed-height lanes moved vertically when only the viewport height changed"
        )
        guard let compactFirstNormalizedLane = threeTrackLayout.laneFrame(forTrackIndex: 0) else {
            throw SmokeError.checkFailed("live-resize normalized lane geometry was unavailable")
        }
        try require(
            threeTrackLayout.pixelFrame(for: compactFirstNormalizedLane) == compactFirstLane,
            "a resolved layout did not project its normalized lane through its own viewport"
        )

        for trackIndex in 0..<5 {
            guard let laneFrame = scrolled.laneFrame(forTrackIndex: trackIndex) else {
                throw SmokeError.checkFailed("missing lane frame for track \(trackIndex)")
            }
            try require(laneFrame.bottom > laneFrame.top, "lane \(trackIndex) had inverted geometry")
        }
    }

    private static func verifyLiveResizeDrawableSizeContract() throws {
        try require(
            TimelineMetalLayerView.drawablePixelSizeMatches(
                viewportSize: CGSize(width: 900, height: 360),
                backingScale: 2,
                textureWidth: 1_800,
                textureHeight: 720
            ),
            "current-size Metal drawable was rejected"
        )
        try require(
            TimelineMetalLayerView.drawablePixelSizeMatches(
                viewportSize: CGSize(width: 900, height: 360),
                backingScale: 2,
                textureWidth: 1_801,
                textureHeight: 719
            ),
            "drawable rounding tolerance was rejected"
        )
        try require(
            !TimelineMetalLayerView.drawablePixelSizeMatches(
                viewportSize: CGSize(width: 900, height: 520),
                backingScale: 2,
                textureWidth: 1_800,
                textureHeight: 720
            ),
            "stale-height Metal drawable was accepted during live resize"
        )
    }

    private static func verifyTrackHeaderWidthPolicy() throws {
        try require(
            TimelineTrackHeaderWidthPolicy.resolvedWidth(
                preferredWidth: TimelineTrackHeaderWidthPolicy.defaultWidth,
                workspaceWidth: 1_200
            ) == TimelineTrackHeaderWidthPolicy.defaultWidth,
            "default track header width changed in a roomy workspace"
        )
        try require(
            TimelineTrackHeaderWidthPolicy.resolvedWidth(
                preferredWidth: 20,
                workspaceWidth: 1_200
            ) == TimelineTrackHeaderWidthPolicy.minimumWidth,
            "track header splitter crossed its minimum width"
        )
        try require(
            TimelineTrackHeaderWidthPolicy.resolvedWidth(
                preferredWidth: 900,
                workspaceWidth: 1_200
            ) == TimelineTrackHeaderWidthPolicy.maximumWidth,
            "track header splitter crossed its maximum width"
        )

        let constrainedWorkspaceWidth: CGFloat = 650
        let constrainedWidth = TimelineTrackHeaderWidthPolicy.resolvedWidth(
            preferredWidth: TimelineTrackHeaderWidthPolicy.maximumWidth,
            workspaceWidth: constrainedWorkspaceWidth
        )
        let remainingTimelineWidth = constrainedWorkspaceWidth
            - TimelineTrackHeaderWidthPolicy.workspaceLeadingInset
            - TimelineTrackHeaderWidthPolicy.workspaceTrailingInset
            - TimelineTrackHeaderWidthPolicy.dividerWidth
            - constrainedWidth
        try require(
            remainingTimelineWidth >= TimelineTrackHeaderWidthPolicy.minimumTimelineWidth,
            "track header splitter consumed the minimum usable timeline width"
        )
    }

    private static func verifyTrackHeaderAutomationModeLayout() throws {
        let defaultModeWidth = TrackControlAutomationRowLayout.modeWidth(
            forHeaderWidth: TimelineTrackHeaderWidthPolicy.defaultWidth
        )
        try require(
            defaultModeWidth >= 70,
            "automation mode control did not leave enough room for its mode label at the default header width"
        )

        try require(
            TrackControlAutomationRowLayout.modeWidth(forHeaderWidth: 300) > defaultModeWidth,
            "automation mode control did not use additional space in a wider track header"
        )
    }

    private static func verifyFixedRulerOccludesVerticallyScrolledTracks(
        waveformOverview: WaveformOverview,
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let trackLayout = TimelineTrackLayout(scrollOffset: 110)
        let contentTracks = (0..<3).map { index in
            TimelineRenderState.Track(
                id: UUID(),
                waveformVersion: 1,
                waveformOverview: waveformOverview,
                durationHint: waveformOverview.duration,
                volume: 1,
                isMuted: false,
                isSoloed: false,
                clipRanges: [TimelineRenderState.ClipRange(
                    startProgress: 0,
                    endProgress: 1,
                    name: "Scrolled track \(index + 1)",
                    isSelected: true
                )]
            )
        }
        let blankTracks = contentTracks.map { track in
            TimelineRenderState.Track(
                id: track.id,
                waveformVersion: 0,
                waveformOverview: nil,
                durationHint: waveformOverview.duration,
                volume: 1,
                isMuted: false,
                isSoloed: false
            )
        }
        let timestamp = CACurrentMediaTime()
        let blankFrame = try renderTimeline(
            renderer: renderer,
            tracks: blankTracks,
            viewport: .full,
            playheadProgress: 0.73,
            isPlaybackActive: false,
            displayTimestamp: timestamp,
            trackLayout: trackLayout,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let contentFrame = try renderTimeline(
            renderer: renderer,
            tracks: contentTracks,
            viewport: .full,
            playheadProgress: 0.73,
            isPlaybackActive: false,
            displayTimestamp: timestamp + 0.01,
            trackLayout: trackLayout,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let resolvedLayout = trackLayout.resolved(
            totalTrackCount: contentTracks.count,
            viewportHeight: Float(contentFrame.summary.height)
        )
        let rulerRows = 0..<min(
            Int(resolvedLayout.rulerLaneHeight.rounded(.down)),
            contentFrame.summary.height
        )
        let rulerDifference = pixelDifferenceCount(
            blankFrame.bytes,
            contentFrame.bytes,
            width: contentFrame.summary.width,
            columns: 0..<contentFrame.summary.width,
            rows: rulerRows,
            threshold: 2
        )
        try require(
            rulerDifference == 0,
            "vertically scrolled track content changed \(rulerDifference) ruler pixels"
        )
    }

    private static func verifyTrackNavigationGeometry() throws {
        let zoomedLayout = TimelineTrackLayout.default
            .withPreferredTrackHeight(240)
            .resolved(totalTrackCount: 8, viewportHeight: 480)
        try require(
            abs(zoomedLayout.trackHeight - 240) < 0.000_1,
            "vertical zoom did not preserve its requested fixed track height"
        )
        try require(zoomedLayout.isScrollable, "vertically zoomed tracks should be scrollable")

        let viewport = TimelineViewport(startProgress: 0.35, durationProgress: 0.25)
        let geometry = TimelineScrollbarGeometry.resolve(
            bounds: CGRect(x: 0, y: 0, width: 1_000, height: 480),
            viewport: viewport,
            trackLayout: zoomedLayout
        )
        try require(
            abs(geometry.horizontalHandle.width / geometry.horizontalTrack.width - 0.25) < 0.01,
            "horizontal scrollbar handle did not represent the visible duration"
        )
        try require(
            geometry.horizontalHandle.minX > geometry.horizontalTrack.minX,
            "horizontal scrollbar handle did not represent the panned viewport"
        )
        try require(
            geometry.verticalHandle.height < geometry.verticalTrack.height,
            "vertical scrollbar handle did not represent hidden tracks"
        )
        try require(
            geometry.axis(at: CGPoint(x: geometry.horizontalHandle.midX, y: geometry.horizontalHandle.midY)) == .horizontal,
            "horizontal scrollbar handle was not hit-testable"
        )
        try require(
            geometry.axis(at: CGPoint(x: geometry.verticalHandle.midX, y: geometry.verticalHandle.midY)) == .vertical,
            "vertical scrollbar handle was not hit-testable"
        )
        try require(geometry.isHorizontalScrollable, "zoomed viewport did not expose horizontal scrolling")
        try require(geometry.isVerticalScrollable, "zoomed track layout did not expose vertical scrolling")

        let unscrollableGeometry = TimelineScrollbarGeometry.resolve(
            bounds: CGRect(x: 0, y: 0, width: 1_000, height: 480),
            viewport: .full,
            trackLayout: TimelineTrackLayout.default.resolved(totalTrackCount: 2, viewportHeight: 480)
        )
        try require(!unscrollableGeometry.isHorizontalScrollable, "full viewport exposed a horizontal scrollbar")
        try require(!unscrollableGeometry.isVerticalScrollable, "fitted tracks exposed a vertical scrollbar")
        try require(
            unscrollableGeometry.axis(at: CGPoint(
                x: unscrollableGeometry.horizontalHandle.midX,
                y: unscrollableGeometry.horizontalHandle.midY
            )) == nil,
            "hidden horizontal scrollbar intercepted timeline input"
        )
        try require(
            unscrollableGeometry.axis(at: CGPoint(
                x: unscrollableGeometry.verticalHandle.midX,
                y: unscrollableGeometry.verticalHandle.midY
            )) == nil,
            "hidden vertical scrollbar intercepted timeline input"
        )

        try require(
            TimelineNavigationScrollbarDragGeometry.interactionFramesPerSecond == 144,
            "navigation scrollbar drag was not paced at the timeline presentation rate"
        )
        try require(
            abs(TimelineNavigationScrollbarVisibilityTiming.fadeInDuration - 0.15) < 0.000_1,
            "navigation scrollbar fade-in did not preserve the 150 ms interaction timing"
        )
        try require(
            abs(TimelineNavigationScrollbarVisibilityTiming.lingerDuration - 0.60) < 0.000_1,
            "navigation scrollbar did not remain visible for 600 ms after scrolling"
        )
        try require(
            abs(TimelineNavigationScrollbarVisibilityTiming.fadeOutDuration - 0.15) < 0.000_1,
            "navigation scrollbar fade-out did not preserve the 150 ms interaction timing"
        )
        try require(
            TimelineNavigationScrollbarVisibilityTiming.fadeInDuration ==
                TimelineNavigationScrollbarVisibilityTiming.fadeOutDuration,
            "navigation scrollbar fade-in and fade-out timings diverged"
        )
        let leadingClampedDrag = TimelineNavigationScrollbarDragGeometry.normalizedValue(
            primaryPosition: -0.08,
            dragOffset: 0.10,
            handleLength: 0.40
        )
        let trailingClampedDrag = TimelineNavigationScrollbarDragGeometry.normalizedValue(
            primaryPosition: 0.78,
            dragOffset: 0.10,
            handleLength: 0.40
        )
        try require(
            leadingClampedDrag == 0 && trailingClampedDrag == 1,
            "navigation scrollbar drag did not clamp cleanly at both timeline boundaries"
        )
        try require(
            TimelineNavigationScrollbarDragGeometry.shouldContinueDisplayPacedDrag(
                hasDragOffset: true,
                pressedMouseButtons: 1
            ),
            "navigation scrollbar drag stopped while the physical left button was held"
        )
        try require(
            !TimelineNavigationScrollbarDragGeometry.shouldContinueDisplayPacedDrag(
                hasDragOffset: true,
                pressedMouseButtons: 0
            ),
            "navigation scrollbar retained camera ownership after the physical drag ended"
        )
        try require(
            !TimelineNavigationScrollbarDragGeometry.shouldContinueDisplayPacedDrag(
                hasDragOffset: false,
                pressedMouseButtons: 1
            ),
            "navigation scrollbar started display-paced updates without an active drag"
        )
        let displayPacedValues = (0...144).map { sampleIndex in
            TimelineNavigationScrollbarDragGeometry.normalizedValue(
                primaryPosition: 0.1 + CGFloat(sampleIndex) / 144 * 0.6,
                dragOffset: 0.1,
                handleLength: 0.4
            )
        }
        try require(
            abs((displayPacedValues.last ?? -1) - 1) < 0.000_1,
            "display-paced scrollbar drag did not reach its exact final value"
        )
        let maximumStep = zip(displayPacedValues, displayPacedValues.dropFirst())
            .map { abs($1 - $0) }
            .max() ?? 1
        try require(
            maximumStep < 0.008,
            "display-paced scrollbar drag skipped intermediate viewport positions"
        )

        let positions = TimelineTrackReorderGeometry.trackPositions(
            count: 5,
            draggedIndex: 1,
            targetIndex: 4,
            draggedPosition: 3.6
        )
        try require(positions == [0, 3.6, 1, 2, 3], "downward track reorder positions were incorrect")
        let target = TimelineTrackReorderGeometry.targetIndex(
            yFromTop: zoomedLayout.rulerLaneHeight + zoomedLayout.trackHeight * 3.55,
            layout: zoomedLayout
        )
        try require(target == 3, "track reorder target did not follow the pointer lane")
    }

    @MainActor
    private static func verifyClipLabelsFollowVerticalZoom(
        track: TimelineRenderState.Track
    ) throws {
        let timeline = TimelineView()
        timeline.frame = NSRect(x: 0, y: 0, width: 960, height: 500)
        timeline.displayTracks(
            [track],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false
        )
        timeline.layoutSubtreeIfNeeded()

        timeline.setVerticalZoomNormalized(1)
        guard let labelLayout = timeline.clipLabelTrackLayoutForTesting else {
            throw SmokeError.checkFailed("clip label overlay did not receive a track layout")
        }
        let renderedLayout = TimelineTrackLayout.default
            .withPreferredTrackHeight(320)
            .resolved(totalTrackCount: 1, viewportHeight: 500)
        try require(
            abs(labelLayout.trackHeight - renderedLayout.trackHeight) < 0.000_1 &&
                labelLayout.laneFrame(forTrackIndex: 0) == renderedLayout.laneFrame(forTrackIndex: 0),
            "clip label overlay retained stale lane geometry during vertical zoom"
        )
    }

    private static func verifyTwoDimensionalTrackpadNavigation() throws {
        let viewport = TimelineViewport(startProgress: 0.35, durationProgress: 0.25)
        let horizontalDelta = TimelineNavigationPanGeometry.horizontalProgressDelta(
            scrollingDeltaX: 120,
            viewportWidth: 1_000,
            viewportDurationProgress: viewport.durationProgress
        )
        let verticalDelta = TimelineNavigationPanGeometry.verticalTrackDelta(scrollingDeltaY: -48)
        let pannedViewport = viewport.panned(byProgress: horizontalDelta)
        let pannedLayout = TimelineTrackLayout.default
            .withPreferredTrackHeight(220)
            .scrolled(by: verticalDelta, totalTrackCount: 8, viewportHeight: 480)

        try require(
            abs(horizontalDelta + 0.03) < 0.000_1,
            "horizontal trackpad motion did not scale through the visible viewport"
        )
        try require(
            abs(pannedViewport.startProgress - 0.32) < 0.000_1,
            "horizontal trackpad motion did not pan timeline time"
        )
        try require(
            abs(pannedLayout.scrollOffset - 48) < 0.000_1,
            "vertical trackpad motion did not scroll track lanes"
        )
    }

    private static func verifyModifierWheelNavigation() throws {
        let shiftedHorizontalDelta = TimelineNavigationWheelGeometry.shiftedHorizontalDelta(
            scrollingDeltaX: 12,
            scrollingDeltaY: 0
        )
        let shiftedVerticalWheelDelta = TimelineNavigationWheelGeometry.shiftedHorizontalDelta(
            scrollingDeltaX: 0,
            scrollingDeltaY: -9
        )
        try require(
            abs(shiftedHorizontalDelta - 48) < 0.000_1,
            "shift-wheel horizontal pan was not accelerated by four"
        )
        try require(
            abs(shiftedVerticalWheelDelta + 36) < 0.000_1,
            "shift-wheel vertical input did not map to accelerated horizontal pan"
        )

        let zoomIn = TimelineNavigationWheelGeometry.commandZoomLogScaleDelta(
            scrollingDeltaX: 0,
            scrollingDeltaY: 4,
            hasPreciseScrollingDeltas: false
        )
        let zoomOut = TimelineNavigationWheelGeometry.commandZoomLogScaleDelta(
            scrollingDeltaX: 0,
            scrollingDeltaY: -4,
            hasPreciseScrollingDeltas: false
        )
        let viewport = TimelineViewport(startProgress: 0.25, durationProgress: 0.5)
        try require(zoomIn > 0 && zoomOut < 0, "command-wheel zoom direction was incorrect")
        try require(
            viewport.zoomed(by: exp(zoomIn), around: 0.5).durationProgress < viewport.durationProgress,
            "command-wheel upward input did not zoom in horizontally"
        )
        try require(
            viewport.zoomed(by: exp(zoomOut), around: 0.5).durationProgress > viewport.durationProgress,
            "command-wheel downward input did not zoom out horizontally"
        )

        let velocityImpulse = TimelineNavigationWheelGeometry.commandZoomVelocityImpulse(
            logScaleDelta: zoomIn,
            momentumDecayRate: 8.4
        )
        try require(
            velocityImpulse > 0,
            "command-wheel input did not produce forward zoom momentum"
        )
        try require(
            abs((velocityImpulse / 8.4) - zoomIn) < 0.000_1,
            "command-wheel momentum did not preserve the requested zoom distance"
        )

        let shiftedPanProgressDelta = TimelineNavigationPanGeometry.horizontalProgressDelta(
            scrollingDeltaX: shiftedVerticalWheelDelta,
            viewportWidth: 1_000,
            viewportDurationProgress: viewport.durationProgress
        )
        let shiftedPanVelocityImpulse = TimelineNavigationWheelGeometry.shiftedPanVelocityImpulse(
            progressDelta: shiftedPanProgressDelta,
            momentumDecayRate: 3.85
        )
        try require(
            shiftedPanVelocityImpulse > 0,
            "shift-wheel input did not preserve horizontal pan direction"
        )
        try require(
            abs((shiftedPanVelocityImpulse / 3.85) - shiftedPanProgressDelta) < 0.000_1,
            "shift-wheel momentum did not preserve the accelerated pan distance"
        )
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
                hitWidth: 24
            ) == .start,
            "selection start edge was not hit within its resize target"
        )
        try require(
            TimelineSelectionResizeInteraction.endpoint(
                nearX: 656,
                startX: 250,
                endX: 650,
                hitWidth: 24
            ) == .end,
            "selection end edge was not hit within its resize target"
        )
        try require(
            TimelineSelectionResizeInteraction.endpoint(
                nearX: 661,
                startX: 250,
                endX: 650,
                hitWidth: 24
            ) == .end,
            "selection edge did not retain the production resize acquisition width"
        )
        try require(
            TimelineSelectionResizeInteraction.endpoint(
                nearX: 663,
                startX: 250,
                endX: 650,
                hitWidth: 24
            ) == nil,
            "selection resize acquisition extended beyond its bounded edge target"
        )
        try require(
            TimelineSelectionResizeInteraction.endpoint(
                nearX: 450,
                startX: 250,
                endX: 650,
                hitWidth: 24
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
                hitWidth: 24
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
                hitWidth: 24
            ) == .end,
            "selection resize cursor target and mouse-down target disagreed at the right viewport edge"
        )
        try require(
            TimelineSelectionResizeInteraction.endpoint(
                at: CGPoint(x: 250, y: 100),
                startX: 250,
                endX: nil,
                verticalRect: verticalRect,
                viewportWidth: 1_000,
                hitWidth: 24
            ) == .start,
            "an offscreen selection end disabled the visible start resize target"
        )
        try require(
            TimelineSelectionResizeInteraction.endpoint(
                at: CGPoint(x: 650, y: 100),
                startX: nil,
                endX: 650,
                verticalRect: verticalRect,
                viewportWidth: 1_000,
                hitWidth: 24
            ) == .end,
            "an offscreen selection start disabled the visible end resize target"
        )
        try require(
            TimelineSelectionResizeInteraction.endpoint(
                at: CGPoint(x: 500, y: 100),
                startX: nil,
                endX: nil,
                verticalRect: verticalRect,
                viewportWidth: 1_000,
                hitWidth: 24
            ) == nil,
            "a fully offscreen selection exposed a phantom resize target"
        )
        try require(
            TimelineSelectionResizeInteraction.endpoint(
                at: CGPoint(x: 250, y: 205),
                startX: 250,
                endX: 650,
                verticalRect: verticalRect,
                viewportWidth: 1_000,
                hitWidth: 24
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

        let endCrossedStart = TimelineLoopEdgeResizeInteraction.resize(
            fixedProgress: original.startProgress,
            draggedProgress: 0.12,
            fallbackEndpoint: .end
        )
        try require(
            endCrossedStart.range == TimelineLoopRange(startProgress: 0.12, endProgress: 0.25) &&
                endCrossedStart.draggedEndpoint == .start,
            "dragging the loop end through the start did not swap its logical endpoint"
        )

        let startCrossedEnd = TimelineLoopEdgeResizeInteraction.resize(
            fixedProgress: original.endProgress,
            draggedProgress: 0.82,
            fallbackEndpoint: .start
        )
        try require(
            startCrossedEnd.range == TimelineLoopRange(startProgress: 0.55, endProgress: 0.82) &&
                startCrossedEnd.draggedEndpoint == .end,
            "dragging the loop start through the end did not swap its logical endpoint"
        )

        let collapsedAtAnchor = TimelineLoopEdgeResizeInteraction.resize(
            fixedProgress: original.startProgress,
            draggedProgress: original.startProgress,
            fallbackEndpoint: .end
        )
        try require(
            collapsedAtAnchor.range.durationProgress == 0,
            "live loop resize could not pass continuously through its fixed anchor"
        )

        let finalizedNearAnchor = TimelineLoopEdgeResizeInteraction.resize(
            fixedProgress: original.startProgress,
            draggedProgress: original.startProgress,
            fallbackEndpoint: .end,
            minimumDuration: 0.02
        )
        try require(
            abs(finalizedNearAnchor.range.startProgress - original.startProgress) < 0.000_001 &&
                abs(finalizedNearAnchor.range.endProgress - 0.27) < 0.000_001,
            "finished loop resize did not restore the minimum loop duration"
        )

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

    @MainActor
    private static func verifyInactiveLoopBodyStartsMoveGesture(
        track: TimelineRenderState.Track
    ) throws {
        let timeline = TimelineView()
        timeline.frame = NSRect(x: 0, y: 0, width: 960, height: 360)
        timeline.displayTracks(
            [track],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false
        )
        timeline.displayLoopRange(TimelineLoopRange(startProgress: 0.25, endProgress: 0.55))
        timeline.displayLoopRangeEnabled(false)

        let pointInsideLoopBody = CGPoint(
            x: timeline.bounds.width * 0.40,
            y: timeline.bounds.height - 8
        )
        try require(
            timeline.loopBodyStartsMoveForTesting(at: pointInsideLoopBody),
            "an inactive loop body started a replacement loop gesture instead of moving"
        )

        let destination = CGPoint(
            x: timeline.bounds.width * 0.50,
            y: pointInsideLoopBody.y
        )
        var movedRange: TimelineLoopRange?
        var enabledChanges: [Bool] = []
        timeline.onLoopRangeChanged = { movedRange = $0 }
        timeline.onLoopRangeEnabledChanged = { enabledChanges.append($0) }
        guard
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: pointInsideLoopBody,
                modifierFlags: [],
                timestamp: 4,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ),
            let dragged = NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: destination,
                modifierFlags: [],
                timestamp: 4.02,
                windowNumber: 0,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1
            ),
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: destination,
                modifierFlags: [],
                timestamp: 4.04,
                windowNumber: 0,
                context: nil,
                eventNumber: 3,
                clickCount: 1,
                pressure: 0
            )
        else {
            throw SmokeError.checkFailed("could not create inactive loop move events")
        }

        timeline.mouseDown(with: down)
        timeline.mouseDragged(with: dragged)
        timeline.mouseUp(with: up)

        let range = try requireValue(movedRange, "inactive loop body drag did not publish a moved range")
        try require(
            abs(range.startProgress - 0.35) < 0.000_1 &&
                abs(range.endProgress - 0.65) < 0.000_1,
            "inactive loop body drag did not preserve and translate its range"
        )
        try require(
            enabledChanges.isEmpty,
            "moving an inactive loop body unexpectedly activated looping"
        )
    }

    @MainActor
    private static func verifyLoopEdgeResizeCrossesOppositeBoundary(
        track: TimelineRenderState.Track
    ) throws {
        let timeline = TimelineView()
        timeline.frame = NSRect(x: 0, y: 0, width: 960, height: 360)
        timeline.displayTracks(
            [track],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false
        )

        func dragLoopEdge(from sourceProgress: Float, to destinationProgress: Float) throws -> TimelineLoopRange {
            let y = timeline.bounds.height - 8
            let source = CGPoint(x: timeline.bounds.width * CGFloat(sourceProgress), y: y)
            let destination = CGPoint(x: timeline.bounds.width * CGFloat(destinationProgress), y: y)
            var changedRange: TimelineLoopRange?
            timeline.onLoopRangeChanged = { changedRange = $0 }

            guard
                let down = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: source,
                    modifierFlags: [],
                    timestamp: 5,
                    windowNumber: 0,
                    context: nil,
                    eventNumber: 1,
                    clickCount: 1,
                    pressure: 1
                ),
                let dragged = NSEvent.mouseEvent(
                    with: .leftMouseDragged,
                    location: destination,
                    modifierFlags: [],
                    timestamp: 5.02,
                    windowNumber: 0,
                    context: nil,
                    eventNumber: 2,
                    clickCount: 1,
                    pressure: 1
                ),
                let up = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: destination,
                    modifierFlags: [],
                    timestamp: 5.04,
                    windowNumber: 0,
                    context: nil,
                    eventNumber: 3,
                    clickCount: 1,
                    pressure: 0
                )
            else {
                throw SmokeError.checkFailed("could not create loop edge crossing events")
            }

            timeline.mouseDown(with: down)
            timeline.mouseDragged(with: dragged)
            timeline.mouseUp(with: up)
            return try requireValue(changedRange, "loop edge crossing did not publish its range")
        }

        timeline.displayLoopRange(TimelineLoopRange(startProgress: 0.25, endProgress: 0.55))
        let endCrossedStart = try dragLoopEdge(from: 0.55, to: 0.12)
        try require(
            abs(endCrossedStart.startProgress - 0.12) < 0.001 &&
                abs(endCrossedStart.endProgress - 0.25) < 0.001,
            "dragging the rendered loop end through its start did not preserve the fixed edge"
        )

        timeline.displayLoopRange(TimelineLoopRange(startProgress: 0.25, endProgress: 0.55))
        let startCrossedEnd = try dragLoopEdge(from: 0.25, to: 0.82)
        try require(
            abs(startCrossedEnd.startProgress - 0.55) < 0.001 &&
                abs(startCrossedEnd.endProgress - 0.82) < 0.001,
            "dragging the rendered loop start through its end did not preserve the fixed edge"
        )
    }

    @MainActor
    private static func verifyWindowDragStripContract() throws {
        let strip = WindowDragStripView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 960,
                height: WindowDragStripView.preferredHeight
            )
        )
        try require(
            strip.mouseDownCanMoveWindow,
            "top drag strip did not opt into background window movement"
        )
        try require(
            strip.hitTest(NSPoint(x: strip.bounds.midX, y: strip.bounds.midY)) === strip,
            "transparent top drag strip did not retain pointer ownership"
        )
        try require(
            WindowDragStripView.preferredHeight == 20,
            "top drag strip no longer preserves the intended 20-point window affordance"
        )
    }

    @MainActor
    private static func verifyClipLabelDeleteProjectionRequiresExplicitHandoff() throws {
        let overlay = TimelineClipLabelOverlayView()
        let startTimestamp = CACurrentMediaTime()
        overlay.displayDeletionEffects(
            [
                TimelineDeletionEffectRequest(
                    selection: TimelineSelection(startProgress: 0.2, endProgress: 0.4),
                    sourceSelection: nil
                ),
            ],
            startTimestamp: startTimestamp
        )
        try require(
            !overlay.advanceDeletionPresentation(
                at: startTimestamp + TimelineDeletionEffectRequest.lifetime + 0.20
            ),
            "settled clip label delete projection continued requesting display-link frames"
        )
        overlay.clearDeletionEffects()
        try require(
            !overlay.advanceDeletionPresentation(at: startTimestamp + 1),
            "clip label delete projection remained active after explicit handoff"
        )
    }

    private static func verifySharedLoopRangeProjection() throws {
        let projectRange = TimelineLoopRange(startProgress: 0.25, endProgress: 0.50)
        let localRange = try requireValue(
            TimelineLoopRangeProjection.localRange(
                forProjectRange: projectRange,
                projectDuration: 120,
                localDuration: 60
            ),
            "shared loop did not project into the inspector timeline"
        )
        try require(
            abs(localRange.startProgress - 0.50) < 0.000_001 &&
                abs(localRange.endProgress - 1.0) < 0.000_001,
            "shared loop did not preserve its absolute times at the inspector zoom scale"
        )

        let roundTrippedRange = try requireValue(
            TimelineLoopRangeProjection.projectRange(
                forLocalRange: localRange,
                localDuration: 60,
                projectDuration: 120
            ),
            "inspector loop did not project back into project time"
        )
        try require(
            abs(roundTrippedRange.startProgress - projectRange.startProgress) < 0.000_001 &&
                abs(roundTrippedRange.endProgress - projectRange.endProgress) < 0.000_001,
            "editing the inspector loop changed its absolute project-time boundaries"
        )

        let clippedRange = try requireValue(
            TimelineLoopRangeProjection.localRange(
                forProjectRange: TimelineLoopRange(startProgress: 0.40, endProgress: 0.70),
                projectDuration: 100,
                localDuration: 50
            ),
            "partially visible shared loop was hidden from the inspector"
        )
        try require(
            abs(clippedRange.startProgress - 0.80) < 0.000_001 &&
                abs(clippedRange.endProgress - 1.0) < 0.000_001,
            "inspector loop did not clip cleanly at the track-time boundary"
        )

        try require(
            TimelineLoopRangeProjection.localRange(
                forProjectRange: TimelineLoopRange(startProgress: 0.60, endProgress: 0.80),
                projectDuration: 100,
                localDuration: 50
            ) == nil,
            "inspector rendered a loop whose absolute range is outside the inspected track"
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

        try require(
            TimelineLoopPlaybackPolicy.bypassesLoopWhenEnabledDuringPlayback(
                playbackProgress: 0.78,
                whilePlaying: true,
                loopRange: loopRange
            ),
            "enabling a loop behind an active playhead did not preserve the current playback pass"
        )
        try require(
            !TimelineLoopPlaybackPolicy.bypassesLoopWhenEnabledDuringPlayback(
                playbackProgress: 0.50,
                whilePlaying: true,
                loopRange: loopRange
            ),
            "enabling a loop around an active playhead incorrectly bypassed its upcoming boundary"
        )
        try require(
            !TimelineLoopPlaybackPolicy.bypassesLoopWhenEnabledDuringPlayback(
                playbackProgress: 0.78,
                whilePlaying: false,
                loopRange: loopRange
            ),
            "enabling a loop while paused incorrectly bypassed start-from-loop playback"
        )
    }

    private static func verifyLoopRegionStyleTransition() throws {
        let startTimestamp: CFTimeInterval = 4
        let duration = TimelineLoopRegionStyleAnimation.duration
        let hoverOn = TimelineLoopRegionStyleTransition(
            source: 0,
            target: 1,
            startTimestamp: startTimestamp
        )

        try require(
            abs(duration - 0.060) < 0.000_001,
            "loop style transition duration drifted from the 60 ms interaction target"
        )
        try require(hoverOn.value(at: startTimestamp) == 0, "loop hover transition did not start at its source")
        let halfwayTimestamp = startTimestamp + duration * 0.5
        let halfwayValue = hoverOn.value(at: halfwayTimestamp)
        try require(
            halfwayValue > 0 && halfwayValue < 1,
            "loop hover transition snapped instead of producing an intermediate style"
        )
        try require(
            hoverOn.value(at: startTimestamp + duration) == 1,
            "loop hover transition did not land exactly on its target"
        )

        let hoverOff = TimelineLoopRegionStyleTransition(
            source: halfwayValue,
            target: 0,
            startTimestamp: halfwayTimestamp
        )
        try require(
            abs(hoverOff.value(at: halfwayTimestamp) - halfwayValue) < 0.000_001,
            "reversing a loop style transition introduced a visual discontinuity"
        )
        try require(
            hoverOff.value(at: halfwayTimestamp + duration) == 0,
            "reversed loop style transition did not finish at its inactive state"
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
        let lane = try requireValue(
            layout.laneFrame(forTrackIndex: 0),
            "fixed-height selection test did not resolve its track lane"
        )
        let topRow = Int(layout.rulerLaneHeight.rounded(.down))
        let bottomRow = Int((lane.bottom * Float(height)).rounded(.down))
        let cornerRows = max(topRow + 2, 0)..<min(topRow + 7, height)
        let bottomCornerRows = max(bottomRow - 7, 0)..<min(max(bottomRow - 2, 0), height)
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
            p95Milliseconds < selectionDragMicrobenchmarkBudgetMilliseconds,
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
        let p99Milliseconds = percentile(frameDurations, percentile: 0.99)
        let maxMilliseconds = frameDurations.max() ?? 0
        try require(
            p95Milliseconds < 6.9,
            String(format: "hover guide render p95 was too slow: %.2fms", p95Milliseconds)
        )
        try require(
            p99Milliseconds < 12,
            String(format: "hover guide render p99 was too slow: %.2fms", p99Milliseconds)
        )
        try require(
            maxMilliseconds < 25,
            String(format: "hover guide render had a catastrophic outlier: %.2fms", maxMilliseconds)
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

    private static func verifyPanImmediatelyAfterZoomStaysResponsive(
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float,
        frameStatsBox: FrameStatsBox
    ) throws {
        let overview = makeDetailedWaveformOverview(
            duration: 600,
            binCount: 131_072,
            seed: 91
        )
        let track = TimelineRenderState.Track(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000091") ?? UUID(),
            waveformVersion: 1,
            waveformOverview: overview,
            durationHint: overview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)]
        )
        let baseTimestamp = CACurrentMediaTime()
        renderer.displayTracks([track], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default, marksInteraction: false)
        renderer.displayViewport(.full, marksInteraction: false)
        renderer.displayPlaybackActive(false)
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: baseTimestamp
        )

        for frameIndex in 0..<12 {
            let t = Float(frameIndex + 1) / 12
            renderer.displayViewport(TimelineViewport(
                startProgress: 0.08 * t,
                durationProgress: 1 - 0.82 * t
            ))
            _ = try renderCurrentTimeline(
                renderer: renderer,
                displayTimestamp: baseTimestamp + Double(frameIndex + 1) / 144,
                texture: texture,
                viewportSize: viewportSize,
                backingScale: backingScale
            )
        }

        try require(
            ImportWorkBudget.shared.snapshot().isTimelineInteractionActive,
            "zoom did not protect the following pan from background refinement"
        )
        frameStatsBox.samples.removeAll()
        var panFrameDurations: [Double] = []
        panFrameDurations.reserveCapacity(40)
        for frameIndex in 0..<40 {
            let t = Float(frameIndex) / 39
            renderer.displayViewport(TimelineViewport(
                startProgress: 0.08 + 0.42 * t,
                durationProgress: 0.18
            ))
            let renderPassDescriptor = makeRenderPassDescriptor(texture: texture)
            let startedAt = CACurrentMediaTime()
            let commandBuffer = renderer.renderOffscreen(
                renderPassDescriptor: renderPassDescriptor,
                viewportSize: viewportSize,
                backingScale: backingScale,
                displayTimestamp: baseTimestamp + Double(frameIndex + 13) / 144,
                waitUntilCompleted: false
            )
            commandBuffer?.waitUntilCompleted()
            panFrameDurations.append((CACurrentMediaTime() - startedAt) * 1_000)
        }

        let p95Milliseconds = percentile(panFrameDurations, percentile: 0.95)
        let maxMilliseconds = panFrameDurations.max() ?? 0
        try require(
            p95Milliseconds < 6.9,
            String(format: "post-zoom pan render p95 was too slow: %.2fms", p95Milliseconds)
        )
        try require(
            maxMilliseconds < 12,
            String(format: "post-zoom pan render outlier was too slow: %.2fms", maxMilliseconds)
        )

        let panStats = frameStatsBox.samples.filter { $0.waveformHotPathReason == "viewport-interaction" }
        try require(!panStats.isEmpty, "post-zoom pan did not publish viewport hot-path stats")
        let violations = panStats.filter {
            $0.cpuWaveformVertexCount > 0 ||
                $0.cpuWaveformFallbackDrawCount > 0 ||
                $0.shaderBufferUploadByteCount > 0 ||
                $0.shaderBufferUploadCount > 0
        }
        try require(
            violations.isEmpty,
            "post-zoom pan performed waveform fallback or upload work in \(violations.count) frames"
        )
    }

    private static func verifyClipPlaybackStaysWithinFrameBudget(
        renderer: TimelineRenderer,
        track: TimelineRenderState.Track,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let clipTrack = TimelineRenderState.Track(
            id: track.id,
            waveformVersion: track.waveformVersion,
            waveformOverview: track.waveformOverview,
            durationHint: track.durationHint,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            hasWaveform: track.hasWaveform,
            clipRanges: [
                TimelineRenderState.ClipRange(
                    id: AudioTimelineClipID(
                        rawValue: UUID(uuidString: "AC1D0000-0000-0000-0000-000000000144") ?? UUID()
                    ),
                    startProgress: 0.08,
                    endProgress: 0.92,
                    name: "Playback cadence"
                ),
            ],
            waveformSegments: track.waveformSegments,
            waveformTileSource: track.waveformTileSource,
            transcript: track.transcript
        )
        let baseTimestamp = CACurrentMediaTime()
        var frameDurations: [Double] = []
        frameDurations.reserveCapacity(72)

        defer {
            renderer.displayPlaybackActive(false)
            renderer.displayTracks([track], animateWaveformTransition: false)
        }

        renderer.displayTracks([clipTrack], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default, marksInteraction: false)
        renderer.displayViewport(.full, marksInteraction: false)
        renderer.displayPlayheadProgress(
            0.10,
            force: true,
            anchorTimestamp: baseTimestamp,
            resetsTouchStart: false
        )
        renderer.displayPlaybackActive(true)
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: baseTimestamp
        )

        let firstFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: baseTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        for frameIndex in 1..<8 {
            let renderPassDescriptor = makeRenderPassDescriptor(texture: texture)
            let commandBuffer = renderer.renderOffscreen(
                renderPassDescriptor: renderPassDescriptor,
                viewportSize: viewportSize,
                backingScale: backingScale,
                displayTimestamp: baseTimestamp + Double(frameIndex) / 144,
                waitUntilCompleted: false
            )
            commandBuffer?.waitUntilCompleted()
        }

        for frameIndex in 8..<80 {
            let renderPassDescriptor = makeRenderPassDescriptor(texture: texture)
            let startedAt = CACurrentMediaTime()
            guard let commandBuffer = renderer.renderOffscreen(
                renderPassDescriptor: renderPassDescriptor,
                viewportSize: viewportSize,
                backingScale: backingScale,
                displayTimestamp: baseTimestamp + Double(frameIndex) / 144,
                waitUntilCompleted: false
            ) else {
                throw SmokeError.renderFailed
            }
            commandBuffer.waitUntilCompleted()
            frameDurations.append((CACurrentMediaTime() - startedAt) * 1_000)
        }

        let lastFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: baseTimestamp + 79.0 / 144.0,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            pixelDifferenceCount(firstFrame.bytes, lastFrame.bytes, threshold: 10) > 300,
            "clip playback cadence check did not advance the playhead visually"
        )

        let p95Milliseconds = percentile(frameDurations, percentile: 0.95)
        let maximumMilliseconds = frameDurations.max() ?? 0
        try require(
            p95Milliseconds < 6.9,
            String(format: "clip playback render p95 missed 144 Hz: %.2fms", p95Milliseconds)
        )
        try require(
            maximumMilliseconds < 12,
            String(format: "clip playback render outlier was too slow: %.2fms", maximumMilliseconds)
        )
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

        let retainedFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: baseTimestamp + 2.20,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let settledTimestamp = baseTimestamp + 2.56
        let stillRetainedFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: settledTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        try require(
            renderer.activeDeletionEffectCountForPerformanceTest() == 1,
            "delete projection expired before the canonical visual handoff"
        )
        let retainedDifference = pixelDifferenceCount(
            retainedFrame.bytes,
            stillRetainedFrame.bytes,
            threshold: 12
        )
        try require(
            retainedDifference < 120,
            "settled delete projection changed while waiting for canonical handoff; pixel delta \(retainedDifference)"
        )
        renderer.clearDeletionEffects()
        let clearedFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: settledTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let expiryDifference = pixelDifferenceCount(clearedFrame.bytes, stillRetainedFrame.bytes, threshold: 12)
        try require(
            expiryDifference > 120,
            "explicit delete handoff did not release the retained projection; pixel delta \(expiryDifference)"
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

    private static func verifyClipChromeFollowsDeletionProjection(
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        renderer.clearDeletionEffects()
        let affectedTrackID = UUID()
        let unaffectedTrackID = UUID()
        let spanningClipID = AudioTimelineClipID()
        let rightClipID = AudioTimelineClipID()
        let unaffectedClipID = AudioTimelineClipID()
        let affectedTrack = TimelineRenderState.Track(
            id: affectedTrackID,
            waveformVersion: 1,
            waveformOverview: nil,
            durationHint: 10,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [
                TimelineRenderState.ClipRange(
                    id: spanningClipID,
                    startProgress: 0.10,
                    endProgress: 0.70,
                    name: "Spanning"
                ),
                TimelineRenderState.ClipRange(
                    id: rightClipID,
                    startProgress: 0.75,
                    endProgress: 0.90,
                    name: "Right"
                ),
            ]
        )
        let unaffectedTrack = TimelineRenderState.Track(
            id: unaffectedTrackID,
            waveformVersion: 1,
            waveformOverview: nil,
            durationHint: 10,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [
                TimelineRenderState.ClipRange(
                    id: unaffectedClipID,
                    startProgress: 0.75,
                    endProgress: 0.90,
                    name: "Unaffected"
                ),
            ]
        )
        let startTimestamp = CACurrentMediaTime()
        _ = try renderTimeline(
            renderer: renderer,
            tracks: [affectedTrack, unaffectedTrack],
            viewport: .full,
            playheadProgress: 0,
            isPlaybackActive: false,
            displayTimestamp: startTimestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        renderer.triggerDeletionEffects(
            [
                TimelineDeletionEffectRequest(
                    selection: TimelineSelection(
                        startProgress: 0.20,
                        endProgress: 0.40,
                        trackID: affectedTrackID
                    ),
                    sourceSelection: nil
                ),
            ],
            at: startTimestamp
        )
        _ = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: startTimestamp + TimelineDeletionEffectRequest.animationDuration * 0.5,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let snapshots = renderer.clipChromePresentationsForPerformanceTest()
        let spanning = try requireValue(
            snapshots.first { $0.clipID == spanningClipID },
            "spanning clip chrome disappeared during delete animation"
        )
        let right = try requireValue(
            snapshots.first { $0.clipID == rightClipID },
            "right-side clip chrome disappeared during delete animation"
        )
        let unaffected = try requireValue(
            snapshots.first { $0.clipID == unaffectedClipID },
            "unaffected clip chrome disappeared during delete animation"
        )
        try require(
            abs(spanning.left - 0.10) < 0.003 && abs(spanning.right - 0.60) < 0.003,
            "spanning clip chrome projected to \(spanning.left)...\(spanning.right), expected 0.10...0.60"
        )
        try require(
            abs(right.left - 0.65) < 0.003 && abs(right.right - 0.80) < 0.003,
            "right-side clip chrome projected to \(right.left)...\(right.right), expected 0.65...0.80"
        )
        try require(
            abs(unaffected.left - 0.75) < 0.003 && abs(unaffected.right - 0.90) < 0.003,
            "delete animation moved clip chrome on an unaffected track"
        )

        _ = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: startTimestamp + TimelineDeletionEffectRequest.lifetime + 0.20,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let settledSnapshots = renderer.clipChromePresentationsForPerformanceTest()
        let settledSpanning = try requireValue(
            settledSnapshots.first { $0.clipID == spanningClipID },
            "spanning clip chrome disappeared before canonical delete handoff"
        )
        let settledRight = try requireValue(
            settledSnapshots.first { $0.clipID == rightClipID },
            "right-side clip chrome disappeared before canonical delete handoff"
        )
        try require(
            abs(settledSpanning.left - 0.10) < 0.003 && abs(settledSpanning.right - 0.50) < 0.003,
            "settled spanning clip snapped to stale geometry before handoff: \(settledSpanning.left)...\(settledSpanning.right)"
        )
        try require(
            abs(settledRight.left - 0.55) < 0.003 && abs(settledRight.right - 0.70) < 0.003,
            "settled right-side clip snapped to stale geometry before handoff: \(settledRight.left)...\(settledRight.right)"
        )
        try require(
            renderer.activeDeletionEffectCountForPerformanceTest() == 1,
            "delete projection expired before canonical clip geometry was published"
        )
        renderer.clearDeletionEffects()
    }

    private static func verifyLiveRecordingClipFollowsDisplayClock(
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let trackID = UUID()
        let clipID = AudioTimelineClipID()
        let track = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 1,
            waveformOverview: nil,
            durationHint: 10,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(
                id: clipID,
                startProgress: 0.20,
                endProgress: 0.25,
                name: "Recording",
                isSelected: true,
                isLiveRecordingPreview: true
            )]
        )
        let startedAt = CACurrentMediaTime()
        renderer.displayTracks([track], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default)
        renderer.displayViewport(.full)
        renderer.displayPlaybackActive(true)
        renderer.displayPlayheadProgress(
            0.25,
            force: true,
            anchorTimestamp: startedAt,
            resetsTouchStart: true
        )
        renderer.displayRecordingActive(true)
        defer {
            renderer.displayRecordingActive(false)
            renderer.displayPlaybackActive(false)
        }

        _ = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: startedAt + 0.40,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let first = try requireValue(
            renderer.clipChromePresentationsForPerformanceTest().first { $0.clipID == clipID },
            "live recording clip did not use dynamic clip chrome"
        )

        _ = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: startedAt + 0.80,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let second = try requireValue(
            renderer.clipChromePresentationsForPerformanceTest().first { $0.clipID == clipID },
            "live recording clip chrome disappeared between audio publications"
        )

        try require(abs(first.left - 0.20) < 0.003, "live recording clip start drifted")
        try require(
            abs(first.right - 0.29) < 0.004,
            "live recording edge did not project from the display clock: \(first.right)"
        )
        try require(
            abs(second.right - 0.33) < 0.004,
            "live recording edge did not continue between chunk publications: \(second.right)"
        )
        try require(
            second.right > first.right + 0.035,
            "live recording edge remained quantized to its last audio publication"
        )
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

    @MainActor
    private static func verifySeekGuttersOwnTimelineSeeking(
        track: TimelineRenderState.Track
    ) throws {
        let timelineView = TimelineView()
        timelineView.frame = NSRect(x: 0, y: 0, width: 960, height: 360)
        // Seeking belongs to the ruler and the empty footer beneath the last track.
        // Clip endpoints intentionally own their resize hit zones, so omit clip chrome.
        let seekTrack = TimelineRenderState.Track(
            id: track.id,
            waveformVersion: track.waveformVersion,
            waveformOverview: track.waveformOverview,
            durationHint: track.durationHint,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            hasWaveform: track.hasWaveform,
            waveformSegments: track.waveformSegments,
            waveformTileSource: track.waveformTileSource,
            transcript: track.transcript
        )
        timelineView.displayTracks(
            [seekTrack],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false
        )
        timelineView.displayPlaybackActive(true)

        var requestedProgresses: [Float] = []
        var publishedGuide: (
            progress: Float?,
            isArmed: Bool,
            guideSpan: TimelineHoverGuideSpan?
        )?
        timelineView.onSeekRequested = { requestedProgresses.append($0) }
        timelineView.onHoverGuideStatePublishedForTesting = { progress, isArmed, guideSpan in
            publishedGuide = (progress, isArmed, guideSpan)
        }
        let spans = timelineView.seekGutterSpansForTesting
        let rulerRects = timelineView.rulerInteractionRectsForTesting
        let footerSpan = try requireValue(spans.bottom, "fixed-height timeline did not expose a footer seek gutter")
        try require(spans.ruler.normalizedBottom > 0, "ruler seek gutter had no height")
        try require(
            abs(rulerRects.loop.height - rulerRects.seek.height) < 0.001,
            "ruler loop and seek bands did not split the ruler evenly"
        )
        try require(
            abs(
                rulerRects.loop.height + rulerRects.seek.height -
                    CGFloat(TimelineTrackLayout.defaultRulerLaneHeight)
            ) < 0.001,
            "ruler interaction bands did not cover the taller ruler"
        )
        try require(
            rulerRects.loop.minY == rulerRects.seek.maxY,
            "ruler loop and seek bands overlapped or left an interaction gap"
        )
        try require(
            timelineView.loopCreationStartsForTesting(at: NSPoint(x: 700, y: rulerRects.loop.midY)),
            "upper ruler band did not own loop creation"
        )
        try require(
            !timelineView.loopCreationStartsForTesting(at: NSPoint(x: 700, y: rulerRects.seek.midY)),
            "lower ruler seek band incorrectly started loop creation"
        )
        try require(footerSpan.normalizedTop < 1, "footer seek gutter had no height")

        let clickPoints = [
            NSPoint(x: 1, y: 1),
            NSPoint(x: timelineView.bounds.width * 0.72, y: rulerRects.seek.midY),
        ]
        for (index, clickPoint) in clickPoints.enumerated() {
            guard
                let mouseDown = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: clickPoint,
                    modifierFlags: [],
                    timestamp: 1 + Double(index),
                    windowNumber: 0,
                    context: nil,
                    eventNumber: index * 2 + 1,
                    clickCount: 1,
                    pressure: 1
                ),
                let mouseUp = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: clickPoint,
                    modifierFlags: [],
                    timestamp: 1.01 + Double(index),
                    windowNumber: 0,
                    context: nil,
                    eventNumber: index * 2 + 2,
                    clickCount: 1,
                    pressure: 0
                )
            else {
                throw SmokeError.checkFailed("could not create seek-gutter click events")
            }
            publishedGuide = nil
            timelineView.mouseDown(with: mouseDown)
            let pressedGuide = try requireValue(
                publishedGuide,
                "seek-gutter mouse down did not publish a hover guide"
            )
            try require(
                pressedGuide.isArmed,
                "seek-gutter guide did not brighten while the mouse was held"
            )
            let expectedSpan = index == 0 ? footerSpan : spans.ruler
            try require(
                pressedGuide.guideSpan == expectedSpan,
                "seek-gutter mouse down changed the guide's vertical span"
            )
            timelineView.mouseUp(with: mouseUp)
        }

        try require(requestedProgresses.count == 2, "ruler/footer clicks did not both seek")
        try require(requestedProgresses[0] < 0.01, "footer start click sought to \(requestedProgresses[0])")
        try require(abs(requestedProgresses[1] - 0.72) < 0.01, "ruler click sought to \(requestedProgresses[1])")
    }

    @MainActor
    private static func verifyClipEdgeDragOwnsTrimGesture(
        track: TimelineRenderState.Track
    ) throws {
        let clipID = AudioTimelineClipID(rawValue: UUID(uuidString: "AC1D0000-0000-0000-0000-000000000001") ?? UUID())
        let clipTrack = TimelineRenderState.Track(
            id: track.id,
            waveformVersion: track.waveformVersion,
            waveformOverview: track.waveformOverview,
            durationHint: track.durationHint,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            hasWaveform: track.hasWaveform,
            clipRanges: [
                TimelineRenderState.ClipRange(
                    id: clipID,
                    startProgress: 0.2,
                    endProgress: 0.6
                )
            ],
            waveformSegments: track.waveformSegments,
            waveformTileSource: track.waveformTileSource,
            transcript: track.transcript
        )
        let timelineView = TimelineView()
        timelineView.frame = NSRect(x: 0, y: 0, width: 960, height: 360)
        timelineView.displayTracks(
            [clipTrack],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false
        )

        var publishedTrim: (TimelineClipFocusRequest, TimelineClipEdge, Float)?
        var seekCount = 0
        timelineView.onClipTrimmed = { publishedTrim = ($0, $1, $2) }
        timelineView.onSeekRequested = { _ in seekCount += 1 }

        let layout = TimelineTrackLayout.default.resolved(
            totalTrackCount: 1,
            viewportHeight: Float(timelineView.bounds.height)
        )
        let lane = try requireValue(
            layout.laneFrame(forTrackIndex: 0),
            "clip trim test did not resolve its fixed-height lane"
        )
        let laneCenterY = timelineView.bounds.height * CGFloat(1 - lane.center)
        let start = NSPoint(x: timelineView.bounds.width * 0.2, y: laneCenterY)
        let destination = NSPoint(x: timelineView.bounds.width * 0.27, y: laneCenterY)
        guard
            let mouseDown = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: start,
                modifierFlags: [],
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ),
            let mouseDragged = NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: destination,
                modifierFlags: [],
                timestamp: 1.02,
                windowNumber: 0,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1
            ),
            let mouseUp = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: destination,
                modifierFlags: [],
                timestamp: 1.04,
                windowNumber: 0,
                context: nil,
                eventNumber: 3,
                clickCount: 1,
                pressure: 0
            )
        else {
            throw SmokeError.checkFailed("could not create clip trim events")
        }

        timelineView.mouseDown(with: mouseDown)
        timelineView.mouseDragged(with: mouseDragged)
        timelineView.mouseUp(with: mouseUp)

        let trim = try requireValue(publishedTrim, "clip edge drag did not publish a trim")
        try require(trim.0.clipID == clipID, "clip edge drag targeted a different clip")
        try require(trim.1 == .leading, "clip leading edge drag published the wrong endpoint")
        try require(abs(trim.2 - 0.27) < 0.01, "clip trim landed at \(trim.2), expected 0.27")
        try require(seekCount == 0, "clip edge drag also published a timeline seek")
    }

    @MainActor
    private static func verifyFullTimelineClipCanMove(
        track: TimelineRenderState.Track
    ) throws {
        let clipID = AudioTimelineClipID(
            rawValue: UUID(uuidString: "AC1D0000-0000-0000-0000-000000000004") ?? UUID()
        )
        let clipTrack = TimelineRenderState.Track(
            id: track.id,
            waveformVersion: track.waveformVersion,
            waveformOverview: track.waveformOverview,
            durationHint: track.durationHint,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            hasWaveform: track.hasWaveform,
            clipRanges: [TimelineRenderState.ClipRange(
                id: clipID,
                startProgress: 0,
                endProgress: 1,
                name: "Full timeline clip",
                isSelected: true
            )],
            waveformSegments: track.waveformSegments,
            waveformTileSource: track.waveformTileSource,
            transcript: track.transcript
        )
        let timeline = TimelineView()
        timeline.frame = NSRect(x: 0, y: 0, width: 960, height: 360)
        timeline.displayTracks(
            [clipTrack],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false
        )

        let layout = TimelineTrackLayout.default.resolved(
            totalTrackCount: 1,
            viewportHeight: Float(timeline.bounds.height)
        )
        let lane = try requireValue(
            layout.laneFrame(forTrackIndex: 0),
            "full-timeline clip move test did not resolve its lane"
        )
        let y = timeline.bounds.height * CGFloat(1 - lane.center)
        let start = NSPoint(x: timeline.bounds.width * 0.5, y: y)
        let destination = NSPoint(x: timeline.bounds.width * 0.75, y: y)
        var committedPreviews: [TimelineClipDragPreview] = []
        var duplicates = false
        timeline.onClipDragCommitted = {
            committedPreviews = $0
            duplicates = $1
        }

        guard
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: start,
                modifierFlags: [],
                timestamp: 3,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ),
            let dragged = NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: destination,
                modifierFlags: [],
                timestamp: 3.02,
                windowNumber: 0,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1
            ),
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: destination,
                modifierFlags: [],
                timestamp: 3.04,
                windowNumber: 0,
                context: nil,
                eventNumber: 3,
                clickCount: 1,
                pressure: 0
            )
        else {
            throw SmokeError.checkFailed("could not create full-timeline clip move events")
        }

        timeline.mouseDown(with: down)
        timeline.mouseDragged(with: dragged)
        timeline.mouseUp(with: up)

        try require(committedPreviews.count == 1, "full-timeline clip move did not commit exactly one clip")
        let preview = committedPreviews[0]
        try require(preview.clipID == clipID, "full-timeline clip move targeted a different clip")
        try require(preview.presentedStartProjectProgress > 0.2, "full-timeline clip remained pinned at project zero")
        try require(preview.presentedEndProjectProgress > 1.2, "full-timeline clip remained clamped to the old project end")
        try require(
            abs(
                (preview.presentedEndProjectProgress - preview.presentedStartProjectProgress) -
                    (preview.originalEndProjectProgress - preview.originalStartProjectProgress)
            ) < 0.000_1,
            "full-timeline clip changed duration while moving"
        )
        try require(!duplicates, "ordinary full-timeline clip drag unexpectedly duplicated the clip")
    }

    @MainActor
    private static func verifyClipDragFloodPublishesAtDisplayCadence(
        track: TimelineRenderState.Track
    ) throws {
        let clipID = AudioTimelineClipID(
            rawValue: UUID(uuidString: "AC1D0000-0000-0000-0000-000000000005") ?? UUID()
        )
        let clipTrack = TimelineRenderState.Track(
            id: track.id,
            waveformVersion: track.waveformVersion,
            waveformOverview: track.waveformOverview,
            durationHint: track.durationHint,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            hasWaveform: track.hasWaveform,
            clipRanges: [TimelineRenderState.ClipRange(
                id: clipID,
                startProgress: 0.1,
                endProgress: 0.3,
                name: "Display-paced drag",
                isSelected: true
            )],
            waveformSegments: track.waveformSegments,
            waveformTileSource: track.waveformTileSource,
            transcript: track.transcript
        )
        let timeline = TimelineView()
        timeline.frame = NSRect(x: 0, y: 0, width: 960, height: 360)
        timeline.displayTracks(
            [clipTrack],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false
        )

        let layout = TimelineTrackLayout.default.resolved(
            totalTrackCount: 1,
            viewportHeight: Float(timeline.bounds.height)
        )
        let lane = try requireValue(
            layout.laneFrame(forTrackIndex: 0),
            "display-paced clip drag test did not resolve its lane"
        )
        let y = timeline.bounds.height * CGFloat(1 - lane.center)
        let start = NSPoint(x: timeline.bounds.width * 0.2, y: y)
        let destination = NSPoint(x: timeline.bounds.width * 0.7, y: y)
        var validationCount = 0
        var committedPreviews: [TimelineClipDragPreview] = []
        timeline.onValidateClipDragPreviews = { previews in
            validationCount += 1
            return !previews.isEmpty
        }
        timeline.onClipDragCommitted = { previews, _ in
            committedPreviews = previews
        }

        let down = try requireValue(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: start,
                modifierFlags: [],
                timestamp: 11,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ),
            "could not create display-paced clip mouse-down event"
        )
        timeline.mouseDown(with: down)
        for index in 1...500 {
            let fraction = CGFloat(index) / 500
            let point = NSPoint(
                x: start.x + (destination.x - start.x) * fraction,
                y: y
            )
            let dragged = try requireValue(
                NSEvent.mouseEvent(
                    with: .leftMouseDragged,
                    location: point,
                    modifierFlags: [],
                    timestamp: 11 + Double(index) * 0.000_2,
                    windowNumber: 0,
                    context: nil,
                    eventNumber: index + 1,
                    clickCount: 1,
                    pressure: 1
                ),
                "could not create display-paced clip drag event"
            )
            timeline.mouseDragged(with: dragged)
        }
        try require(
            validationCount == 0,
            "raw clip drag events performed \(validationCount) synchronous validations before presentation"
        )

        let up = try requireValue(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: destination,
                modifierFlags: [],
                timestamp: 11.2,
                windowNumber: 0,
                context: nil,
                eventNumber: 502,
                clickCount: 1,
                pressure: 0
            ),
            "could not create display-paced clip mouse-up event"
        )
        timeline.mouseUp(with: up)

        try require(validationCount == 1, "clip mouse-up did not perform exactly one final validation")
        let preview = try requireValue(
            committedPreviews.first,
            "display-paced clip drag did not commit its exact final preview"
        )
        try require(
            abs(preview.presentedStartProjectProgress - 0.6) < 0.01,
            "display-paced clip drag committed at \(preview.presentedStartProjectProgress), expected 0.6"
        )
    }

    @MainActor
    private static func verifyTrackLaneClicksDoNotSeek(
        track: TimelineRenderState.Track
    ) throws {
        let clipID = AudioTimelineClipID(
            rawValue: UUID(uuidString: "AC1D0000-0000-0000-0000-000000000002") ?? UUID()
        )
        let clipTrack = TimelineRenderState.Track(
            id: track.id,
            waveformVersion: track.waveformVersion,
            waveformOverview: track.waveformOverview,
            durationHint: track.durationHint,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            hasWaveform: track.hasWaveform,
            clipRanges: [
                TimelineRenderState.ClipRange(
                    id: clipID,
                    startProgress: 0.2,
                    endProgress: 0.6
                )
            ],
            waveformSegments: track.waveformSegments,
            waveformTileSource: track.waveformTileSource,
            transcript: track.transcript
        )
        let timeline = TimelineView()
        timeline.frame = NSRect(x: 0, y: 0, width: 960, height: 360)
        timeline.displayTracks(
            [clipTrack],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false
        )

        let layout = TimelineTrackLayout.default.resolved(
            totalTrackCount: 1,
            viewportHeight: Float(timeline.bounds.height)
        )
        let lane = try requireValue(
            layout.laneFrame(forTrackIndex: 0),
            "clip click seek test did not resolve its lane"
        )
        let y = timeline.bounds.height * CGFloat(1 - lane.center)
        var seeks: [Float] = []
        var trims = 0
        var moves = 0
        timeline.onSeekRequested = { seeks.append($0) }
        timeline.onClipTrimmed = { _, _, _ in trims += 1 }
        timeline.onClipDragCommitted = { _, _ in moves += 1 }

        for (index, progress) in [Float(0.4), Float(0.2), Float(0.8)].enumerated() {
            let point = NSPoint(x: timeline.bounds.width * CGFloat(progress), y: y)
            guard
                let down = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: point,
                    modifierFlags: [],
                    timestamp: 2 + Double(index),
                    windowNumber: 0,
                    context: nil,
                    eventNumber: index * 2 + 1,
                    clickCount: 1,
                    pressure: 1
                ),
                let up = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: point,
                    modifierFlags: [],
                    timestamp: 2.01 + Double(index),
                    windowNumber: 0,
                    context: nil,
                    eventNumber: index * 2 + 2,
                    clickCount: 1,
                    pressure: 0
                )
            else {
                throw SmokeError.checkFailed("could not create stationary clip click events")
            }
            timeline.mouseDown(with: down)
            timeline.mouseUp(with: up)
        }

        try require(seeks.isEmpty, "track-lane click unexpectedly sought to \(seeks)")
        try require(trims == 0 && moves == 0, "stationary clip clicks committed an edit")
    }

    @MainActor
    private static func verifyClipDoubleClickOpensTrackInspector(
        track: TimelineRenderState.Track
    ) throws {
        let clipID = AudioTimelineClipID(
            rawValue: UUID(uuidString: "AC1D0000-0000-0000-0000-000000000003") ?? UUID()
        )
        let clipTrack = TimelineRenderState.Track(
            id: track.id,
            waveformVersion: track.waveformVersion,
            waveformOverview: track.waveformOverview,
            durationHint: track.durationHint,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            hasWaveform: track.hasWaveform,
            clipRanges: [TimelineRenderState.ClipRange(
                id: clipID,
                startProgress: 0.2,
                endProgress: 0.6,
                name: "Inspector smoke clip"
            )],
            waveformSegments: track.waveformSegments,
            waveformTileSource: track.waveformTileSource,
            transcript: track.transcript
        )
        let timeline = TimelineView()
        timeline.frame = NSRect(x: 0, y: 0, width: 960, height: 360)
        timeline.displayTracks(
            [clipTrack],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false
        )

        let layout = TimelineTrackLayout.default.resolved(
            totalTrackCount: 1,
            viewportHeight: Float(timeline.bounds.height)
        )
        let lane = try requireValue(
            layout.laneFrame(forTrackIndex: 0),
            "clip double-click test did not resolve its lane"
        )
        let point = NSPoint(
            x: timeline.bounds.width * 0.4,
            y: timeline.bounds.height * CGFloat(1 - lane.center)
        )
        var openedRequest: TimelineClipFocusRequest?
        var seekCount = 0
        var editCount = 0
        timeline.onClipDoubleClicked = { openedRequest = $0 }
        timeline.onSeekRequested = { _ in seekCount += 1 }
        timeline.onClipDragCommitted = { _, _ in editCount += 1 }
        timeline.onClipTrimmed = { _, _, _ in editCount += 1 }

        guard
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: point,
                modifierFlags: [],
                timestamp: 7,
                windowNumber: 0,
                context: nil,
                eventNumber: 701,
                clickCount: 2,
                pressure: 1
            ),
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: point,
                modifierFlags: [],
                timestamp: 7.01,
                windowNumber: 0,
                context: nil,
                eventNumber: 702,
                clickCount: 2,
                pressure: 0
            )
        else {
            throw SmokeError.checkFailed("could not create clip double-click events")
        }

        timeline.mouseDown(with: down)
        timeline.mouseUp(with: up)

        try require(openedRequest?.clipID == clipID, "clip double-click did not open the clicked clip")
        try require(openedRequest?.trackID == track.id, "clip double-click opened the wrong track")
        try require(seekCount == 0, "clip double-click sought the main timeline")
        try require(editCount == 0, "clip double-click committed a clip edit")
    }

    @MainActor
    private static func verifyOffscreenPlayheadDoesNotPageTimeline(
        track: TimelineRenderState.Track
    ) throws {
        let timelineView = TimelineView()
        timelineView.frame = NSRect(x: 0, y: 0, width: 960, height: 360)
        timelineView.displayTracks(
            [track],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false
        )
        let viewport = TimelineViewport(startProgress: 0.20, durationProgress: 0.30)
        timelineView.restoreViewport(viewport)
        timelineView.displayPlaybackActive(true)
        timelineView.displayPlayheadProgress(0.90)
        try require(
            timelineView.currentViewport == viewport,
            "an offscreen right playhead paged the timeline without an explicit reveal"
        )
        timelineView.displayPlayheadProgress(0.05)
        try require(
            timelineView.currentViewport == viewport,
            "an offscreen left playhead paged the timeline without an explicit reveal"
        )
    }

    @MainActor
    private static func verifySelectionFocusScrollbarUsesPresentedCamera(
        track: TimelineRenderState.Track
    ) throws {
        let timelineView = TimelineView()
        timelineView.frame = NSRect(x: 0, y: 0, width: 960, height: 360)
        timelineView.displayTracks(
            [track],
            animateWaveformTransition: false,
            allowImmediateWaveformPrewarm: false,
            allowImmediateInteractiveWaveformPrewarm: false
        )
        let sourceViewport = TimelineViewport(startProgress: 0.10, durationProgress: 0.70)
        timelineView.restoreViewport(sourceViewport)
        var presentationUpdateCount = 0
        timelineView.onNavigationPresentationChanged = {
            presentationUpdateCount += 1
        }
        timelineView.restoreViewport(TimelineViewport(startProgress: 0.12, durationProgress: 0.68))
        try require(
            presentationUpdateCount == 1,
            "timeline viewport presentation did not notify navigation chrome"
        )

        let presentedViewport = timelineView.currentViewport
        let selection = TimelineSelection(
            startProgress: 0.52,
            endProgress: 0.62,
            trackID: track.id
        )
        timelineView.focusSelection(selection)
        try require(
            abs(timelineView.horizontalVisibleFraction - presentedViewport.durationProgress) < 0.000_001,
            "selection focus scrollbar jumped to the settled camera before animation began"
        )
        let expectedTravel = max(1 - presentedViewport.durationProgress, 0)
        let expectedValue = expectedTravel > 0.000_001 ?
            presentedViewport.startProgress / expectedTravel : 0
        try require(
            abs(timelineView.horizontalScrollNormalizedValue - expectedValue) < 0.000_001,
            "selection focus scrollbar thumb did not reflect the presented camera position"
        )
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

    private static func verifyEditCameraTransition() throws {
        let beforeDuration = 120.0
        let afterDuration = 82.0
        let source = TimelineCameraWindow(
            viewport: .full,
            projectDuration: beforeDuration
        )
        let targetViewport = TimelineViewport.full
        let target = TimelineCameraWindow(
            viewport: targetViewport,
            projectDuration: afterDuration
        )
        let tuning = TimelineCameraTransition.Tuning(
            duration: 0.18,
            minimumTranslationPixels: 2,
            minimumZoomRatioDelta: 0.005
        )
        let transition = TimelineCameraTransition(
            source: source,
            target: target,
            startTimestamp: 10,
            tuning: tuning
        )

        try require(
            transition.isMeaningful(viewportWidth: 1_440),
            "large edit camera reframe was incorrectly treated as imperceptible"
        )
        let first = transition.camera(at: 10)
        let middle = transition.camera(at: 10.09)
        let final = transition.camera(at: 10.18)
        try require(first == source, "camera transition did not begin at the exact source camera")
        try require(final == target, "camera transition did not finish at the exact target camera")
        try require(
            middle.visibleDuration < source.visibleDuration &&
                middle.visibleDuration > target.visibleDuration,
            "camera field of view did not move monotonically between edit endpoints"
        )
        try require(
            middle.centerTime < source.centerTime && middle.centerTime > target.centerTime,
            "camera center did not move monotonically between edit endpoints"
        )

        let sourcePresentationViewport = TimelineViewport.presentationViewport(
            for: source,
            projectDuration: afterDuration
        )
        try require(
            abs(Double(sourcePresentationViewport.durationProgress) * afterDuration - beforeDuration) < 0.000_1,
            "first edit camera frame did not preserve the old absolute field of view"
        )
        try require(
            sourcePresentationViewport.durationProgress > 1,
            "shrinking a fit timeline did not retain temporary presentation overscan"
        )

        let zoomedViewport = TimelineViewport(startProgress: 0.20, durationProgress: 0.30)
        let zoomedSource = TimelineCameraWindow(
            viewport: zoomedViewport,
            projectDuration: beforeDuration
        )
        let preserved = zoomedViewport.preservingAbsoluteTimes(
            previousDuration: beforeDuration,
            nextDuration: afterDuration
        )
        let zoomedTarget = TimelineCameraWindow(
            viewport: preserved,
            projectDuration: afterDuration
        )
        let fixedCameraTransition = TimelineCameraTransition(
            source: zoomedSource,
            target: zoomedTarget,
            startTimestamp: 20,
            tuning: tuning
        )
        try require(
            !fixedCameraTransition.isMeaningful(viewportWidth: 1_440),
            "an edit moved a zoomed camera whose absolute time window was still valid"
        )
    }

    private static func verifySelectionFocusCameraTransition() throws {
        let selection = TimelineSelection(
            startProgress: 0.25,
            endProgress: 0.50,
            trackID: UUID()
        )
        let layout = TimelineTrackLayout(
            scrollOffset: 0,
            preferredTrackHeight: 100,
            automaticallyFitsTrackHeight: false,
            rulerLaneHeight: 32
        ).resolved(totalTrackCount: 8, viewportHeight: 500)
        let plan = TimelineSelectionFocusPlan(
            selection: selection,
            trackIndex: 4,
            trackLayout: layout,
            viewportWidth: 1_440
        )

        let expectedDuration = Float(0.25 / ((1_440.0 - 128.0) / 1_440.0))
        let expectedStart = Float(0.25) - expectedDuration * Float(64.0 / 1_440.0)
        try require(
            abs(plan.viewport.startProgress - expectedStart) < 0.000_001 &&
                abs(plan.viewport.durationProgress - expectedDuration) < 0.000_001,
            "selection focus did not preserve 64-point horizontal margins"
        )
        let leadingMargin = (
            Float(selection.startProgress) - plan.viewport.startProgress
        ) / plan.viewport.durationProgress * 1_440
        let trailingMargin = (
            plan.viewport.endProgress - Float(selection.endProgress)
        ) / plan.viewport.durationProgress * 1_440
        try require(
            abs(leadingMargin - 64) < 0.001 && abs(trailingMargin - 64) < 0.001,
            "selection focus did not place the selected region 64 points from both edges"
        )
        try require(
            abs(plan.trackScrollOffset - 216) < 0.001,
            "selection focus did not center the selected track"
        )
        let focusedLayout = TimelineTrackLayout(
            scrollOffset: plan.trackScrollOffset,
            preferredTrackHeight: 100,
            automaticallyFitsTrackHeight: false,
            rulerLaneHeight: 32
        ).resolved(totalTrackCount: 8, viewportHeight: 500)
        try require(
            focusedLayout.trackHeight == layout.trackHeight,
            "selection focus changed vertical track height"
        )

        let transition = TimelineCameraTransition(
            source: TimelineCameraWindow(viewport: .full, projectDuration: 120),
            target: TimelineCameraWindow(viewport: plan.viewport, projectDuration: 120),
            startTimestamp: 10,
            tuning: .selectionFocus
        )
        let quarter = transition.camera(
            at: 10 + TimelineCameraTransition.Tuning.selectionFocus.duration * 0.25
        )
        let focusedVisibleDuration = Double(expectedDuration) * 120
        let linearQuarterDuration = 120 + (focusedVisibleDuration - 120) * 0.25
        try require(
            quarter.visibleDuration < linearQuarterDuration,
            "selection focus camera did not use the requested quick ease-out curve"
        )
        try require(
            abs(transition.camera(at: transition.endTimestamp).visibleDuration - focusedVisibleDuration) < 0.000_001,
            "selection focus camera did not land on the padded selected duration"
        )

        let towardSource = TimelineCameraWindow(centerTime: 24, visibleDuration: 36)
        let towardTarget = TimelineCameraWindow(centerTime: 68, visibleDuration: 14)
        let towardVelocity = TimelineCameraVelocity(
            centerTimePerSecond: 30,
            logVisibleDurationPerSecond: -0.7
        )
        try require(
            towardVelocity.alignment(from: towardSource, toward: towardTarget) > 0,
            "selection focus did not recognize camera momentum toward its target"
        )
        let towardTransition = TimelineCameraTransition(
            source: towardSource,
            target: towardTarget,
            startTimestamp: 20,
            tuning: .selectionFocus,
            initialVelocity: towardVelocity
        )
        let towardInitialVelocity = towardTransition.velocity(at: 20)
        try require(
            abs(towardInitialVelocity.centerTimePerSecond - towardVelocity.centerTimePerSecond) < 0.000_001 &&
                abs(towardInitialVelocity.logVisibleDurationPerSecond - towardVelocity.logVisibleDurationPerSecond) <
                0.000_001,
            "selection focus discarded useful incoming camera momentum"
        )
        let towardFirstFrame = towardTransition.camera(at: 20 + 1.0 / 144.0)
        try require(
            towardFirstFrame.centerTime > towardSource.centerTime &&
                towardFirstFrame.visibleDuration < towardSource.visibleDuration,
            "selection focus did not continue camera motion already aimed toward the selection"
        )
        try require(
            towardTransition.camera(at: towardTransition.endTimestamp) == towardTarget &&
                towardTransition.velocity(at: towardTransition.endTimestamp) == .zero,
            "momentum-aware selection focus did not settle exactly at rest on its target"
        )

        let opposingSource = TimelineCameraWindow(centerTime: 60, visibleDuration: 24)
        let opposingTarget = TimelineCameraWindow(centerTime: 28, visibleDuration: 12)
        let opposingVelocity = TimelineCameraVelocity(
            centerTimePerSecond: 18,
            logVisibleDurationPerSecond: 0.35
        )
        try require(
            opposingVelocity.alignment(from: opposingSource, toward: opposingTarget) < 0,
            "selection focus did not recognize camera momentum moving away from its target"
        )
        let opposingTransition = TimelineCameraTransition(
            source: opposingSource,
            target: opposingTarget,
            startTimestamp: 30,
            tuning: .selectionFocusOpposingMomentum,
            initialVelocity: opposingVelocity
        )
        let opposingEarlyCamera = opposingTransition.camera(at: 30 + 0.002)
        let opposingMidVelocity = opposingTransition.velocity(
            at: 30 + TimelineCameraTransition.Tuning.selectionFocusOpposingMomentum.duration * 0.5
        )
        try require(
            opposingEarlyCamera.centerTime > opposingSource.centerTime,
            "selection focus snapped against opposing momentum instead of braking it"
        )
        try require(
            opposingMidVelocity.centerTimePerSecond < 0,
            "selection focus did not reverse smoothly after braking opposing momentum"
        )
        try require(
            opposingTransition.camera(at: opposingTransition.endTimestamp) == opposingTarget &&
                opposingTransition.velocity(at: opposingTransition.endTimestamp) == .zero,
            "opposing-momentum selection focus did not settle exactly on its target"
        )
    }

    @MainActor
    private static func verifyClipSelectionFocusResolution() throws {
        let firstTrackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-0000000000C1") ?? UUID()
        let middleTrackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-0000000000C2") ?? UUID()
        let lastTrackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-0000000000C3") ?? UUID()
        let trackOrder = [firstTrackID, middleTrackID, lastTrackID]
        let firstClip = TimelineClipFocusRequest(
            clipID: AudioTimelineClipID(),
            trackID: firstTrackID,
            trackLocalRange: TimelineRenderState.ClipRange(startProgress: 0.2, endProgress: 0.3),
            projectStartProgress: 0.2,
            projectEndProgress: 0.3
        )
        let lastClip = TimelineClipFocusRequest(
            clipID: AudioTimelineClipID(),
            trackID: lastTrackID,
            trackLocalRange: TimelineRenderState.ClipRange(startProgress: 0.7, endProgress: 0.85),
            projectStartProgress: 0.7,
            projectEndProgress: 0.85
        )

        let singleClipFocus = try requireValue(
            TimelineView.zoomFocusSelection(
                timeSelection: nil,
                selectedClips: [firstClip],
                trackOrder: trackOrder
            ),
            "a single selected clip did not produce a zoom target"
        )
        try require(
            abs(singleClipFocus.startProgress - 0.2) < 0.000_001 &&
                abs(singleClipFocus.endProgress - 0.3) < 0.000_001 &&
                singleClipFocus.trackID == firstTrackID,
            "single-clip focus did not preserve the clip's exact project bounds and track"
        )

        let clipFocus = try requireValue(
            TimelineView.zoomFocusSelection(
                timeSelection: nil,
                selectedClips: [lastClip, firstClip],
                trackOrder: trackOrder
            ),
            "selected clips did not produce a zoom target"
        )
        try require(
            abs(clipFocus.startProgress - 0.2) < 0.000_001 &&
                abs(clipFocus.endProgress - 0.85) < 0.000_001,
            "selected clips did not use their outermost project-space boundaries"
        )
        try require(
            clipFocus.trackID == middleTrackID,
            "multi-track clip focus did not center the selected track span"
        )

        let timeSelection = TimelineSelection(
            startProgress: 0.4,
            endProgress: 0.5,
            trackID: firstTrackID
        )
        let timeFocus = try requireValue(
            TimelineView.zoomFocusSelection(
                timeSelection: timeSelection,
                selectedClips: [firstClip, lastClip],
                trackOrder: trackOrder
            ),
            "time selection did not produce a zoom target"
        )
        try require(
            timeFocus == timeSelection,
            "clip bounds took precedence over an active time selection"
        )

        try require(
            TimelineView.zoomFocusSelection(
                timeSelection: nil,
                selectedClips: [],
                trackOrder: trackOrder
            ) == nil,
            "an empty selection unexpectedly enabled selection focus"
        )
    }

    private static func verifyOffscreenPlayheadNavigation() throws {
        let indicatorBounds = CGRect(x: 0, y: 0, width: 36, height: 46)
        let leftVertices = TimelineOffscreenPlayheadIndicatorGeometry.vertices(
            direction: .left,
            in: indicatorBounds
        )
        let rightVertices = TimelineOffscreenPlayheadIndicatorGeometry.vertices(
            direction: .right,
            in: indicatorBounds
        )
        try require(
            leftVertices[1].x < leftVertices[0].x &&
                rightVertices[1].x > rightVertices[0].x,
            "offscreen playhead indicators did not point toward their respective edges"
        )
        try require(
            abs(leftVertices[0].x - leftVertices[2].x) < 0.000_01 &&
                abs(rightVertices[0].x - rightVertices[2].x) < 0.000_01 &&
                abs(leftVertices[1].y - indicatorBounds.midY) < 0.000_01 &&
                abs(rightVertices[1].y - indicatorBounds.midY) < 0.000_01,
            "offscreen playhead indicators are not closed triangles"
        )
        let leftSideLengths = [
            hypot(
                leftVertices[1].x - leftVertices[0].x,
                leftVertices[1].y - leftVertices[0].y
            ),
            hypot(
                leftVertices[2].x - leftVertices[1].x,
                leftVertices[2].y - leftVertices[1].y
            ),
            hypot(
                leftVertices[0].x - leftVertices[2].x,
                leftVertices[0].y - leftVertices[2].y
            ),
        ]
        try require(
            leftSideLengths.allSatisfy { abs($0 - leftSideLengths[0]) < 0.000_01 },
            "offscreen playhead indicator is not equilateral"
        )

        let viewport = TimelineViewport(startProgress: 0.20, durationProgress: 0.30)
        try require(
            TimelineOffscreenPlayheadNavigation.direction(
                playheadProgress: 0.05,
                viewport: viewport
            ) == .left,
            "a playhead left of the viewport did not select the left reveal arrow"
        )
        try require(
            TimelineOffscreenPlayheadNavigation.direction(
                playheadProgress: 0.85,
                viewport: viewport
            ) == .right,
            "a playhead right of the viewport did not select the right reveal arrow"
        )
        try require(
            TimelineOffscreenPlayheadNavigation.direction(
                playheadProgress: 0.35,
                viewport: viewport
            ) == nil,
            "an onscreen playhead incorrectly selected an offscreen reveal arrow"
        )

        for playheadProgress: Float in [0.14, 0.60] {
            let revealed = TimelineOffscreenPlayheadNavigation.revealViewport(
                playheadProgress: playheadProgress,
                viewport: viewport
            )
            let landingFraction = revealed.viewportProgress(
                forTimelineProgress: playheadProgress
            )
            try require(
                abs(landingFraction - TimelineOffscreenPlayheadNavigation.revealAnchorFraction) < 0.000_01,
                "playhead reveal landed at \(landingFraction), expected the shared near-left anchor"
            )
            try require(
                abs(revealed.durationProgress - viewport.durationProgress) < 0.000_001,
                "playhead reveal unexpectedly changed the timeline zoom"
            )
        }

        let endClamped = TimelineOffscreenPlayheadNavigation.revealViewport(
            playheadProgress: 0.98,
            viewport: viewport
        )
        try require(
            abs(endClamped.endProgress - 1) < 0.000_001,
            "near-end playhead reveal did not preserve the timeline's no-overscroll boundary"
        )

        let transition = TimelineCameraTransition(
            source: TimelineCameraWindow(viewport: viewport, projectDuration: 120),
            target: TimelineCameraWindow(
                viewport: TimelineOffscreenPlayheadNavigation.revealViewport(
                    playheadProgress: 0.85,
                    viewport: viewport
                ),
                projectDuration: 120
            ),
            startTimestamp: 10,
            tuning: .playheadReveal
        )
        try require(
            transition.camera(at: transition.endTimestamp) == transition.target,
            "offscreen playhead reveal did not land exactly on its target camera"
        )
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
        let renderFlightGate = TimelineRenderFlightGate()
        try require(renderFlightGate.begin(), "render flight gate rejected the first frame")
        try require(
            !renderFlightGate.begin(),
            "render flight gate allowed a second frame before GPU completion"
        )
        renderFlightGate.finish()
        try require(
            renderFlightGate.begin(),
            "render flight gate did not reopen after GPU completion"
        )
        renderFlightGate.finish()

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

        let gpuBackpressureHealth = PerformanceSampler.effectiveRenderHealthFramesPerSecond(
            submittedFramesPerSecond: 144,
            completedFramesPerSecond: 72,
            targetFramesPerSecond: 144,
            renderDemand: .interaction,
            activeDemandAge: 1
        )
        try require(
            gpuBackpressureHealth == 72,
            "GPU completion lag was hidden by the submitted frame cadence"
        )

        let submissionBackpressureHealth = PerformanceSampler.effectiveRenderHealthFramesPerSecond(
            submittedFramesPerSecond: 88,
            completedFramesPerSecond: 144,
            targetFramesPerSecond: 144,
            renderDemand: .interaction,
            activeDemandAge: 1
        )
        try require(
            submissionBackpressureHealth == 88,
            "render submission lag was hidden by the completed frame cadence"
        )

        let idleRenderHealth = PerformanceSampler.effectiveRenderHealthFramesPerSecond(
            submittedFramesPerSecond: 12,
            completedFramesPerSecond: 0,
            targetFramesPerSecond: 144,
            renderDemand: .idle,
            activeDemandAge: 5
        )
        try require(idleRenderHealth == 144, "idle render health no longer reports full responsiveness")

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

    private static func verifyClipBodyOwnsItsWaveformCenterline(
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let track = TimelineRenderState.Track(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-0000000000C1") ?? UUID(),
            waveformVersion: 0,
            waveformOverview: nil,
            durationHint: 10,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            hasWaveform: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0.25, endProgress: 0.75)]
        )
        let frame = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: .full,
            playheadProgress: 0.92,
            isPlaybackActive: false,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        let layout = TimelineTrackLayout.default.resolved(
            totalTrackCount: 1,
            viewportHeight: Float(frame.summary.height)
        )
        let lane = try requireValue(
            layout.laneFrame(forTrackIndex: 0),
            "clip body smoke had no track lane"
        )
        let chrome = TimelineClipChromeMetrics.verticalGeometry(
            laneTop: lane.top * Float(frame.summary.height),
            laneBottom: lane.bottom * Float(frame.summary.height),
            viewportHeight: Float(frame.summary.height)
        )
        let centerRow = Int(((chrome.headerBottom + chrome.clipBottom) * 0.5).rounded())
        let bodyRow = min(centerRow + 5, Int(chrome.clipBottom) - 2)
        let insideColumn = frame.summary.width / 2
        let outsideColumn = frame.summary.width / 10
        let insideCenter = pixelLuminance(
            frame.bytes,
            width: frame.summary.width,
            column: insideColumn,
            row: centerRow
        )
        let insideBody = pixelLuminance(
            frame.bytes,
            width: frame.summary.width,
            column: insideColumn,
            row: bodyRow
        )
        let outsideCenter = pixelLuminance(
            frame.bytes,
            width: frame.summary.width,
            column: outsideColumn,
            row: centerRow
        )
        let outsideBody = pixelLuminance(
            frame.bytes,
            width: frame.summary.width,
            column: outsideColumn,
            row: bodyRow
        )
        try require(
            insideCenter >= insideBody + 12,
            "clip centerline was not visible at the waveform-body midpoint"
        )
        try require(
            abs(outsideCenter - outsideBody) <= 3,
            "track-wide centerline remained visible outside clip bounds"
        )
        try require(
            chrome.headerBottom > chrome.clipTop && chrome.headerBottom < chrome.clipBottom,
            "clip header did not reserve a distinct waveform body below it"
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
        displayTimestamp: CFTimeInterval,
        maximumAttempts: Int = 80,
        failureContext: String = "grouped delete"
    ) throws {
        for attempt in 0..<maximumAttempts {
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
            "large waveform buffers did not become resident for \(failureContext): \(renderer.debugVisibleWaveformMipBinState(drawableSize: viewportSize, backingScale: backingScale))"
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

    private static func pixelLuminance(
        _ bytes: [UInt8],
        width: Int,
        column: Int,
        row: Int
    ) -> Int {
        guard width > 0 else { return 0 }
        let pixelCount = bytes.count / 4
        let height = pixelCount / width
        guard column >= 0, column < width, row >= 0, row < height else { return 0 }
        let byteIndex = (row * width + column) * 4
        let blue = Int(bytes[byteIndex])
        let green = Int(bytes[byteIndex + 1])
        let red = Int(bytes[byteIndex + 2])
        return (red * 54 + green * 183 + blue * 19) / 256
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

    private static func verifySelectedClipControlGeometry() throws {
        let drawableSize = CGSize(width: 960, height: 360)
        let backingScale: Float = 2
        let radius = TimelineRenderer.normalizedClipControlHalfExtent(
            pixels: 3.5,
            drawableSize: drawableSize,
            backingScale: backingScale
        )
        let diameterInPixels = SIMD2<Float>(
            radius.x * Float(drawableSize.width) * 2 * backingScale,
            radius.y * Float(drawableSize.height) * 2 * backingScale
        )

        try require(
            abs(diameterInPixels.x - 7) < 0.01 && abs(diameterInPixels.y - 7) < 0.01,
            "selected clip handles escaped pixel space (\(diameterInPixels.x)x\(diameterInPixels.y)px)"
        )
        try require(
            radius.x < 0.01 && radius.y < 0.01,
            "selected clip handle radius was large enough to wash out the clip body"
        )
    }

    private static func verifyAutomationMaximumAlignsWithClipHeader() throws {
        let laneTop: Float = 80
        let laneBottom: Float = 280
        let viewportHeight: Float = 1_000
        let chrome = TimelineClipChromeMetrics.verticalGeometry(
            laneTop: laneTop,
            laneBottom: laneBottom,
            viewportHeight: viewportHeight
        )
        let automation = TimelineClipChromeMetrics.automationRange(
            laneTop: laneTop,
            laneBottom: laneBottom,
            viewportHeight: viewportHeight
        )
        try require(
            abs(automation.top - chrome.headerBottom) < 0.001,
            "automation maximum \(automation.top) did not align with clip header bottom \(chrome.headerBottom)"
        )
        try require(
            abs(chrome.clipTop - laneTop) < 0.001 &&
                abs(chrome.clipBottom - laneBottom) < 0.001,
            "clip chrome did not align exactly with its lane boundaries"
        )
        try require(
            abs(automation.top - (laneTop + 20)) < 0.001,
            "responsive clip header geometry unexpectedly resolved to \(automation.top)"
        )
    }

    private static func verifySourceWaveformLayerContinuity(
        waveformOverview: WaveformOverview
    ) throws {
        let trackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000020") ?? UUID()
        let layerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000021") ?? UUID()
        let sourceID = TimelineMediaSourceID(rawValue: "timeline-ux-long-mp3")
        let previousSegment = TimelineRenderState.Track.WaveformSegment(
            outputStartProgress: 0,
            outputEndProgress: 0.5,
            sourceStartProgress: 0,
            sourceEndProgress: 0.5
        )
        let incomingSegment = TimelineRenderState.Track.WaveformSegment(
            outputStartProgress: 0.25,
            outputEndProgress: 0.75,
            sourceStartProgress: 0.1,
            sourceEndProgress: 0.6
        )
        let previousTrack = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 1,
            waveformOverview: nil,
            durationHint: waveformOverview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            usesSourceWaveformLayers: true,
            waveformLayers: [TimelineRenderState.Track.WaveformLayer(
                id: layerID,
                sourceID: sourceID,
                waveformVersion: 41,
                waveformOverview: waveformOverview,
                waveformSegments: [previousSegment]
            )]
        )
        let resolvingTrack = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 2,
            waveformOverview: nil,
            durationHint: waveformOverview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            usesSourceWaveformLayers: true,
            waveformLayers: [TimelineRenderState.Track.WaveformLayer(
                id: layerID,
                sourceID: sourceID,
                waveformVersion: 0,
                waveformOverview: nil,
                waveformSegments: [incomingSegment]
            )]
        )

        let resolvedLayers = resolvingTrack.resolvingWaveformLayers(using: previousTrack)
        try require(resolvedLayers.count == 1, "temporary source resolution removed the waveform layer")
        let resolvedLayer = try requireValue(resolvedLayers.first, "resolved source layer was missing")
        try require(
            resolvedLayer.waveformOverview?.bins.count == waveformOverview.bins.count,
            "temporary source resolution did not retain the last drawable overview"
        )
        try require(
            resolvedLayer.waveformVersion == 41,
            "temporary source resolution did not retain the drawable source revision"
        )
        try require(
            resolvedLayer.waveformSegments.first?.outputStartProgress == incomingSegment.outputStartProgress &&
                resolvedLayer.waveformSegments.first?.outputEndProgress == incomingSegment.outputEndProgress,
            "temporary source resolution retained stale clip placement geometry"
        )

        let legacyPreviewTrack = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 29,
            waveformOverview: waveformOverview,
            durationHint: waveformOverview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            waveformSegments: [previousSegment]
        )
        let legacyHandoffLayers = resolvingTrack.resolvingWaveformLayers(using: legacyPreviewTrack)
        let legacyHandoffLayer = try requireValue(
            legacyHandoffLayers.first,
            "legacy first-frame preview was lost during canonical source handoff"
        )
        try require(
            legacyHandoffLayer.waveformOverview?.bins.count == waveformOverview.bins.count &&
                legacyHandoffLayer.waveformVersion == 29,
            "canonical source handoff did not retain the drawable first-frame preview"
        )
        try require(
            legacyHandoffLayer.sourceID == sourceID &&
                legacyHandoffLayer.waveformSegments.first?.outputStartProgress == incomingSegment.outputStartProgress &&
                legacyHandoffLayer.waveformSegments.first?.outputEndProgress == incomingSegment.outputEndProgress,
            "legacy first-frame handoff replaced canonical source identity or placement"
        )

        let secondSourceID = TimelineMediaSourceID(rawValue: "timeline-ux-second-source")
        let multiSourceResolvingTrack = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 3,
            waveformOverview: nil,
            durationHint: waveformOverview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            usesSourceWaveformLayers: true,
            waveformLayers: [
                resolvingTrack.waveformLayers[0],
                TimelineRenderState.Track.WaveformLayer(
                    id: UUID(),
                    sourceID: secondSourceID,
                    waveformVersion: 0,
                    waveformOverview: nil,
                    waveformSegments: [incomingSegment]
                )
            ]
        )
        try require(
            multiSourceResolvingTrack
                .resolvingWaveformLayers(using: legacyPreviewTrack)
                .allSatisfy { $0.waveformOverview == nil },
            "a track-oriented preview was unsafely reused for a mixed-source destination track"
        )

        let removedTrack = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 3,
            waveformOverview: nil,
            durationHint: waveformOverview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            usesSourceWaveformLayers: true,
            waveformLayers: []
        )
        try require(
            removedTrack.resolvingWaveformLayers(using: previousTrack).isEmpty,
            "a removed media source retained a stale waveform layer"
        )
    }

    private static func verifyAutomationEnvelopeRenders(
        waveformOverview: WaveformOverview,
        trackID: UUID,
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let parameterID = TimelineAutomationParameterID.volume.rawValue
        let track = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 91,
            waveformOverview: nil,
            durationHint: waveformOverview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)],
            automationLanes: [TimelineRenderState.Track.AutomationLane(
                parameterID: parameterID,
                defaultNormalizedValue: 0.5,
                points: [
                    TimelineRenderState.Track.AutomationPoint(
                        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-0000000000A1") ?? UUID(),
                        projectProgress: 0.18,
                        normalizedValue: 0.22,
                        curveToNext: 0.8
                    ),
                    TimelineRenderState.Track.AutomationPoint(
                        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-0000000000A2") ?? UUID(),
                        projectProgress: 0.76,
                        normalizedValue: 0.82,
                        curveToNext: 0
                    ),
                ],
                isEnabled: true
            )]
        )
        let timestamp = CACurrentMediaTime()
        renderer.displayAutomationParameter(nil)
        let hiddenFrame = try renderTimeline(
            renderer: renderer,
            tracks: [track],
            viewport: .full,
            playheadProgress: 0,
            isPlaybackActive: false,
            displayTimestamp: timestamp,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        // Automation lanes stay resident while hidden. The View menu and A key
        // must therefore be a constant-time visibility change, not a track
        // payload rebuild on the interaction path.
        renderer.displayAutomationParameter(parameterID)
        let visibleFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp + 0.01,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )
        renderer.displayAutomationParameter(nil)
        let hiddenAgainFrame = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: timestamp + 0.02,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        let changedPixels = pixelDifferenceCount(
            hiddenFrame.bytes,
            visibleFrame.bytes,
            threshold: 8
        )
        try require(
            changedPixels > 8_000,
            "automation mode changed only \(changedPixels) pixels; its envelope was not rendered"
        )
        let hiddenAgainChangedPixels = pixelDifferenceCount(
            visibleFrame.bytes,
            hiddenAgainFrame.bytes,
            threshold: 8
        )
        try require(
            hiddenAgainChangedPixels > 8_000,
            "leaving automation mode changed only \(hiddenAgainChangedPixels) pixels; its envelope remained visible"
        )

        let layout = TimelineTrackLayout.default.resolved(
            totalTrackCount: 1,
            viewportHeight: Float(visibleFrame.summary.height)
        )
        let laneFrame = try requireValue(
            layout.laneFrame(forTrackIndex: 0),
            "automation smoke could not resolve its track lane"
        )
        let laneTop = max(laneFrame.clampedTop * Float(visibleFrame.summary.height), layout.rulerLaneHeight)
        let laneBottom = min(laneFrame.clampedBottom * Float(visibleFrame.summary.height), Float(visibleFrame.summary.height))
        let curveTop = min(laneTop + 22, laneBottom - 4)
        let curveBottom = max(laneBottom - 10, curveTop + 1)
        for (progress, value) in [(Float(0.18), Float(0.22)), (Float(0.76), Float(0.82))] {
            let x = Int(progress * Float(visibleFrame.summary.width))
            let y = Int(curveBottom - value * max(curveBottom - curveTop, 1))
            let pointDifference = pixelDifferenceCount(
                hiddenFrame.bytes,
                visibleFrame.bytes,
                width: visibleFrame.summary.width,
                columns: (x - 7)..<(x + 8),
                rows: (y - 7)..<(y + 8),
                threshold: 40
            )
            try require(
                pointDifference > 12,
                "automation point at \(progress) did not produce visible point geometry"
            )
        }

        // Validate the connecting stroke away from either control point. The
        // lane backdrop and point quads alone used to let this smoke pass even
        // when the dedicated line pipeline emitted no visible fragments.
        let midpointProgress = Float(0.47)
        let midpointValue = Float(0.22) +
            (Float(0.82) - Float(0.22)) * TimelineAutomationCurve.progress(0.5, curve: 0.8)
        let midpointX = Int(midpointProgress * Float(visibleFrame.summary.width))
        let midpointY = Int(curveBottom - midpointValue * max(curveBottom - curveTop, 1))
        let linePixelDifference = brightPixelDifferenceCount(
            hiddenFrame.bytes,
            visibleFrame.bytes,
            width: visibleFrame.summary.width,
            columns: (midpointX - 4)..<(midpointX + 5),
            rows: (midpointY - 4)..<(midpointY + 5),
            threshold: 28,
            minimumLuminance: 96
        )
        try require(
            linePixelDifference > 2,
            "automation control points rendered without their connecting line"
        )
    }

    @MainActor
    private static func verifyAutomationVisibilityCommandRouting() throws {
        let timeline = TimelineView()
        var requestCount = 0
        timeline.onToggleAutomationModeRequested = {
            requestCount += 1
        }

        guard let keyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) else {
            throw SmokeError.checkFailed("could not create the automation shortcut event")
        }
        timeline.keyDown(with: keyEvent)
        try require(
            requestCount == 1,
            "automation visibility did not delegate to the workspace owner"
        )
        try require(
            !timeline.isAutomationModeVisible,
            "a delegated automation command also mutated local visibility"
        )

        timeline.setAutomationModeVisible(true)
        try require(
            timeline.isAutomationModeVisible,
            "the workspace could not publish automation visibility to its timeline"
        )
    }

    @MainActor
    private static func verifyAutomationPointClickPolicy() throws {
        try require(
            TimelineView.shouldDeleteAutomationPointOnClick(
                didDrag: false,
                modifierFlags: []
            ),
            "a plain automation point click did not request point removal"
        )
        try require(
            !TimelineView.shouldDeleteAutomationPointOnClick(
                didDrag: true,
                modifierFlags: []
            ),
            "dragging an automation point could also remove it on mouse-up"
        )
        for modifier: NSEvent.ModifierFlags in [.command, .shift, .option, .control] {
            try require(
                !TimelineView.shouldDeleteAutomationPointOnClick(
                    didDrag: false,
                    modifierFlags: modifier
                ),
                "a modified automation point click could destructively remove the point"
            )
        }
    }

    private static func verifyAutomationPreviewPublicationIsLatestWins(
        trackID: UUID,
        renderer: TimelineRenderer
    ) throws {
        let parameterID = TimelineAutomationParameterID.volume.rawValue
        let pointID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-0000000000B1") ?? UUID()
        let sampleCount = 2_000
        let startedAt = DispatchTime.now().uptimeNanoseconds
        for sample in 0..<sampleCount {
            let curve = Float(sample) / Float(sampleCount - 1) * 2 - 1
            renderer.publishInteractionAutomationPreview(TimelineAutomationPreview(
                trackID: trackID,
                parameterID: parameterID,
                points: [TimelineRenderState.Track.AutomationPoint(
                    id: pointID,
                    projectProgress: 0.25,
                    normalizedValue: 0.5,
                    curveToNext: curve
                )]
            ))
        }
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        let preview = try requireValue(
            renderer.automationPreviewForSmoke(),
            "automation preview mailbox lost its most recent drag sample"
        )
        try require(
            preview.points.first?.curveToNext == 1,
            "automation preview mailbox retained a stale curve sample"
        )
        try require(
            elapsedMilliseconds < 25,
            "automation preview publication took \(String(format: "%.2f", elapsedMilliseconds)) ms for \(sampleCount) samples"
        )
        renderer.publishInteractionAutomationPreview(nil)
    }

    private static func verifyAutomationCurveTessellationPolicy() throws {
        let linear = TimelineRenderer.automationCurveSamples(
            pixelSpan: 300,
            leftY: 20,
            rightY: 180,
            curve: 0
        )
        try require(
            linear.count == 2,
            "linear automation unnecessarily generated curved subdivisions"
        )
        let curved = TimelineRenderer.automationCurveSamples(
            pixelSpan: 300,
            leftY: 20,
            rightY: 180,
            curve: 0.8
        )
        try require(
            curved.count > 8,
            "curved automation did not add detail around its bends"
        )
        try require(
            curved.count <= 513,
            "adaptive automation tessellation exceeded its bounded recursion budget"
        )
    }

    private static func verifyTrackVolumeUpdatePreservesResidentWaveform(
        waveformOverview: WaveformOverview,
        renderer: TimelineRenderer,
        texture: MTLTexture,
        viewportSize: CGSize,
        backingScale: Float
    ) throws {
        let trackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000022") ?? UUID()
        let segment = TimelineRenderState.Track.WaveformSegment(
            outputStartProgress: 0,
            outputEndProgress: 1,
            sourceStartProgress: 0,
            sourceEndProgress: 1
        )
        let residentTrack = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 1,
            waveformOverview: nil,
            durationHint: waveformOverview.duration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            clipRanges: [TimelineRenderState.ClipRange(startProgress: 0, endProgress: 1)],
            usesSourceWaveformLayers: true,
            waveformLayers: [TimelineRenderState.Track.WaveformLayer(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000023") ?? UUID(),
                sourceID: TimelineMediaSourceID(rawValue: "timeline-ux-volume-source"),
                waveformVersion: 1,
                waveformOverview: waveformOverview,
                waveformSegments: [segment]
            )]
        )
        let baseTimestamp = CACurrentMediaTime()
        renderer.displayTracks([residentTrack], animateWaveformTransition: false)
        renderer.displayTrackLayout(.default, marksInteraction: false)
        renderer.displayViewport(.full, marksInteraction: false)
        renderer.displayPlaybackActive(false)
        try waitForVisibleWaveformBuffers(
            renderer: renderer,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale,
            displayTimestamp: baseTimestamp
        )
        let before = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: baseTimestamp + 1.0 / 144,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        // Track-control updates intentionally carry no waveform payload. The first
        // slider sample must update only mix uniforms and retain all resident data.
        renderer.displayTrackMixSettings([TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 0,
            waveformOverview: nil,
            durationHint: waveformOverview.duration,
            volume: 0.55,
            isMuted: false,
            isSoloed: false
        )])
        let after = try renderCurrentTimeline(
            renderer: renderer,
            displayTimestamp: baseTimestamp + 2.0 / 144,
            texture: texture,
            viewportSize: viewportSize,
            backingScale: backingScale
        )

        try require(
            after.summary.nonBackgroundPixelCount > 5_000,
            "first volume slider sample removed the resident waveform"
        )
        try require(
            after.summary.nonBackgroundPixelCount >= before.summary.nonBackgroundPixelCount / 2,
            "volume update discarded most drawable waveform pixels"
        )
        let changedPixels = pixelDifferenceCount(before.bytes, after.bytes, threshold: 4)
        try require(
            changedPixels < 100,
            "track volume changed source waveform geometry (changed pixels: \(changedPixels))"
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
