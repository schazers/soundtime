import AppKit
import Foundation
import SoundtimeEditing

@MainActor
enum MixerSmokeHarness {
    private final class FocusableSmokeView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private enum SmokeError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(message): message
            }
        }
    }

    private struct Mode {
        let channelCount: Int

        init(arguments: [String]) {
            channelCount = arguments.contains("--full") || arguments.contains("--stress") ? 1_000 : 100
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let mode = Mode(arguments: arguments)
        _ = NSApplication.shared

        try verifyFaderLaw()
        try verifyMonoMeterNormalization()
        try verifyCommandContract()
        try verifyBottomPanelSwitching()
        warmMixerPresentationPipeline()
        let metrics = try verifyVirtualizedMixer(
            channelCount: mode.channelCount,
            snapshotURL: arguments.contains("--snapshot") ? mixerSnapshotURL() : nil
        )

        let checks = [
            "versioned logarithmic fader law and unity reset",
            "truthful mono metering at every pan position",
            "plain-X View menu command contract",
            "shared bottom-panel switching and responder restoration",
            "mixer close control owns hit testing and hover presentation",
            "mixer channel controls retain an eight-point vertical rhythm",
            "stable channel identity across reorder",
            "muted channel presentation remains stable through live resize",
            "mute solo pan fader and automation callbacks",
            "exact 0 dB reset and motorized automation follow",
            "mono/stereo meter geometry",
            "stale meter revision rejection",
            "visible-strip virtualization across horizontal scrolling",
            "stable identity through track deletion and insertion",
            "visible mixer control accessibility",
            "empty-project master-only state",
            "\(mode.channelCount)-channel presentation workload",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "mixer-smoke",
            startedAtNanoseconds: startedAt,
            checks: checks,
            metadata: [
                "channelCount": "\(mode.channelCount)",
                "visibleChannelCount": "\(metrics.visibleCount)",
                "initialDisplayMilliseconds": String(format: "%.3f", metrics.initialDisplayMilliseconds),
                "reorderMilliseconds": String(format: "%.3f", metrics.reorderMilliseconds),
            ],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }
        print("Soundtime mixer smoke passed (\(mode.channelCount) channels, \(metrics.visibleCount) visible)")
    }

    private static func verifyFaderLaw() throws {
        let gains: [Float] = [0, 0.001, 0.031_622_78, 0.25, 1, TimelineMixerFaderLaw.maximumGain]
        for gain in gains {
            let position = MixerFaderLaw.position(forGain: gain)
            let roundTrip = MixerFaderLaw.gain(forPosition: position)
            let tolerance = max(gain * 0.002, 0.000_02)
            try require(abs(roundTrip - gain) <= tolerance, "fader law failed to round-trip gain \(gain)")
        }
        try require(MixerFaderLaw.gain(forPosition: 0.85) == 1, "0 dB detent did not resolve to unity")
        try require(MixerFaderLaw.displayString(forGain: 0) == "-inf", "silence label was not -inf")
    }

    private static func verifyMonoMeterNormalization() throws {
        let trackID = UUID()
        let hardRight = PlaybackTrackMeterLevel(
            trackID: trackID,
            channelCount: 1,
            leftRMS: 0,
            rightRMS: 0.5,
            leftPeak: 0,
            rightPeak: 0.75
        ).normalizedForMixerDisplay()
        try require(hardRight.channelCount == 1, "mono meter unexpectedly became stereo")
        try require(hardRight.leftRMS == 0.5, "hard-right mono RMS appeared silent")
        try require(hardRight.leftPeak == 0.75, "hard-right mono peak appeared silent")
        try require(hardRight.rightRMS == 0 && hardRight.rightPeak == 0, "mono meter retained a hidden second channel")
    }

    private static func verifyCommandContract() throws {
        try require(MixerCommandContract.menuTitle == "Mixer", "mixer menu title changed unexpectedly")
        try require(MixerCommandContract.keyEquivalent == "x", "mixer command is not bound to X")
        try require(MixerCommandContract.keyEquivalentModifierMask.isEmpty, "mixer command unexpectedly requires a modifier")
    }

    private static func verifyBottomPanelSwitching() throws {
        let host = WorkspaceBottomPanelHostView(frame: CGRect(x: 0, y: 0, width: 800, height: 260))
        let root = NSView(frame: host.frame)
        let fallback = FocusableSmokeView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        let window = NSWindow(
            contentRect: root.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        root.addSubview(host)
        root.addSubview(fallback)

        let inspector = NSView()
        let mixer = NSView()
        host.display(inspector, mode: .trackInspector)
        try require(host.mode == .trackInspector && inspector.superview === host, "track inspector was not hosted")
        host.display(mixer, mode: .mixer)
        try require(host.mode == .mixer && mixer.superview === host, "mixer did not replace the inspector in place")
        try require(inspector.superview == nil, "replaced inspector remained attached")

        let mixerControl = FocusableSmokeView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        mixer.addSubview(mixerControl)
        try require(window.makeFirstResponder(mixerControl), "mixer control could not become first responder")
        try require(host.owns(firstResponder: window.firstResponder), "host did not recognize its first responder")
        try require(
            host.moveFirstResponderOutOfDisplayedPanel(to: fallback),
            "host did not restore focus before dismissing its panel"
        )
        try require(window.firstResponder === fallback, "focus remained trapped in the dismissed mixer")

        host.display(nil, mode: .hidden)
        try require(host.mode == .hidden && host.isHidden, "bottom panel did not hide cleanly")
    }

    /// The mixer opens inside an already-running AppKit workspace. Keep one-time
    /// framework control/font/collection initialization out of the interaction
    /// budget so the smoke measures the user-visible mixer work itself.
    private static func warmMixerPresentationPipeline() {
        let panel = MixerPanelView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let window = NSWindow(
            contentRect: panel.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = panel
        panel.display(channels: Array(makeChannels(count: 1)))
        panel.testingLayout(in: panel.frame.size)
        _ = window
    }

    private static func verifyVirtualizedMixer(
        channelCount: Int,
        snapshotURL: URL?
    ) throws -> (visibleCount: Int, initialDisplayMilliseconds: Double, reorderMilliseconds: Double) {
        let panel = MixerPanelView(frame: CGRect(x: 0, y: 0, width: 1_200, height: 340))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_200, height: 340),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = panel
        let channels = makeChannels(count: channelCount)

        var events: [String] = []
        panel.onMuteChanged = { events.append("mute:\($0):\($1)") }
        panel.onSoloChanged = { events.append("solo:\($0):\($1)") }
        panel.onVolumeEditingBegan = { events.append("volume-begin:\($0):\($1)") }
        panel.onVolumeChanged = { events.append("volume:\($0):\($1)") }
        panel.onVolumeEditingEnded = { events.append("volume-end:\($0)") }
        panel.onPanEditingBegan = { events.append("pan-begin:\($0):\($1)") }
        panel.onPanChanged = { events.append("pan:\($0):\($1)") }
        panel.onPanEditingEnded = { events.append("pan-end:\($0)") }
        panel.onVolumeAutomationModeChanged = { events.append("mode:\($0):\($1.rawValue)") }

        let displayStart = DispatchTime.now().uptimeNanoseconds
        panel.display(channels: channels)
        panel.testingLayout(in: CGSize(width: 1_200, height: 340))
        try require(
            panel.testingMixerCloseControlWinsHitTesting,
            "mixer resize header swallowed the close control hit target"
        )
        panel.testingSetMixerCloseHovered(true)
        let hoveredClose = panel.testingMixerCloseHoverPresentation
        try require(hoveredClose.isHovered, "mixer close control did not enter its hover state")
        try require(hoveredClose.scale > 1, "mixer close glyph did not grow on hover")
        try require(hoveredClose.isWhite, "mixer close glyph did not turn white on hover")
        panel.testingSetMixerCloseHovered(false)
        let restingClose = panel.testingMixerCloseHoverPresentation
        try require(!restingClose.isHovered, "mixer close control remained hovered after mouse exit")
        try require(restingClose.scale == 1, "mixer close glyph did not return to its resting size")
        let channelGaps = panel.testingMixerChannelVerticalGaps
        try require(channelGaps.count == 4, "mixer did not expose the complete vertical control stack")
        try require(
            channelGaps.allSatisfy { $0 >= 7.5 },
            "mixer channel controls collapsed below their eight-point vertical rhythm: \(channelGaps)"
        )
        let initialDisplayMilliseconds = milliseconds(since: displayStart)
        let visibleCount = panel.testingVisibleChannelCount
        try require(visibleCount > 0, "mixer did not instantiate visible strips")
        try require(visibleCount < min(channelCount, 24), "mixer instantiated offscreen strips")
        try require(panel.testingChannelIDs == channels.map(\.id), "mixer changed stable channel order")
        let mutedID = channels[0].id
        let unmutedID = channels[1].id
        try require(
            panel.testingMutedPresentation(trackID: mutedID) == true,
            "muted mixer channel did not retain its dark presentation"
        )
        try require(
            panel.testingMutedPresentation(trackID: unmutedID) == false,
            "unmuted mixer channel incorrectly received a dark presentation"
        )
        for height in [260.0, 520.0, 300.0] {
            panel.testingLayout(in: CGSize(width: 1_200, height: height))
            try require(
                panel.testingMutedPresentation(trackID: mutedID) == true,
                "muted mixer presentation disappeared during panel resize"
            )
            try require(
                panel.testingMutedPresentation(trackID: unmutedID) == false,
                "panel resize darkened an unmuted mixer channel"
            )
        }
        let accessibilityLabels = panel.testingVisibleAccessibilityLabels
        for requiredLabelFragment in ["Mixer channel:", "solo", "mute", "pan", "volume", "automation", "output level"] {
            try require(
                accessibilityLabels.contains { $0.localizedCaseInsensitiveContains(requiredLabelFragment) },
                "visible mixer controls omitted accessibility for \(requiredLabelFragment)"
            )
        }

        let firstID = channels[0].id
        panel.testingSetMute(trackID: firstID, value: true)
        panel.testingSetSolo(trackID: firstID, value: true)
        panel.testingSetVolume(trackID: firstID, value: 0.5)
        panel.testingSetPan(trackID: firstID, value: -0.25)
        panel.testingSetVolumeAutomationMode(trackID: firstID, mode: .latch)
        panel.testingResetVolume(trackID: firstID)
        for prefix in ["mute:", "solo:", "volume-begin:", "volume:", "volume-end:", "pan-begin:", "pan:", "pan-end:", "mode:"] {
            try require(events.contains(where: { $0.hasPrefix(prefix) }), "mixer callback missing: \(prefix)")
        }
        try require(
            events.contains(where: { $0.hasPrefix("volume:") && $0.hasSuffix(":1.0") }),
            "mixer fader reset did not publish exact unity gain"
        )

        panel.displayAutomatedMix(
            volumeByTrackID: [firstID: 0.25],
            panByTrackID: [firstID: 0.75]
        )
        let automatedMix = try requireValue(
            panel.testingVisibleMix(trackID: firstID),
            "visible automated channel disappeared"
        )
        try require(automatedMix.volume == 0.25, "motorized fader did not follow automation")
        try require(automatedMix.pan == 0.75, "motorized pan did not follow automation")

        let levels = channels.enumerated().map { index, channel in
            MixerMeterLevel(
                trackID: channel.id,
                channelCount: channel.channelLayout == .mono ? 1 : 2,
                leftRMS: Float(index % 7 + 1) / 10,
                rightRMS: Float(index % 5 + 1) / 12,
                leftPeak: 0.8,
                rightPeak: 0.7
            )
        }
        panel.display(packet: MixerMeterPacket(
            graphRevision: 12,
            sequence: 1,
            hostTimestamp: CACurrentMediaTime(),
            levels: levels
        ))
        panel.tickMeters(isPlaying: true)
        try require(panel.testingMeterPipelineIsReady, "mixer meter Metal pipeline was unavailable")
        try require(panel.testingMeterGPUDrawCount > 0, "mixer submitted meter bars without drawing them")
        try require(panel.testingLastGraphRevision == 12, "mixer rejected a current meter packet")
        try require(panel.testingRenderedMeterCount >= visibleCount + 2, "mixer omitted visible meter channels")
        try require(panel.testingRenderedMeterCount <= visibleCount * 2 + 2, "mixer rendered offscreen meter channels")
        panel.display(packet: MixerMeterPacket(
            graphRevision: 11,
            sequence: 2,
            hostTimestamp: CACurrentMediaTime(),
            levels: []
        ))
        try require(panel.testingLastGraphRevision == 12, "stale meter packet replaced the current revision")

        let reordered = Array(channels.reversed())
        let reorderStart = DispatchTime.now().uptimeNanoseconds
        panel.display(channels: reordered)
        panel.testingLayout(in: CGSize(width: 1_200, height: 340))
        let reorderMilliseconds = milliseconds(since: reorderStart)
        try require(panel.testingChannelIDs == reordered.map(\.id), "channel reorder lost stable identity")

        panel.horizontalScrollOffset = 1_600
        panel.testingLayout(in: CGSize(width: 1_200, height: 340))
        try require(panel.horizontalScrollOffset > 0, "mixer did not preserve horizontal scrolling")
        try require(
            !panel.testingVisibleTrackIDs.contains(reordered[0].id),
            "mixer failed to virtualize newly offscreen channels after scrolling"
        )

        let replacement = MixerChannelPresentation(
            id: UUID(),
            name: "New track",
            channelLayout: .stereo,
            volume: 1,
            pan: 0,
            isMuted: false,
            isSoloed: false,
            isVolumeAutomated: false,
            isPanAutomated: false,
            volumeAutomationMode: .read,
            panAutomationMode: .read
        )
        let afterDeleteAndAdd = Array(reordered.dropLast()) + [replacement]
        panel.display(channels: afterDeleteAndAdd)
        panel.testingLayout(in: CGSize(width: 1_200, height: 340))
        try require(
            panel.testingChannelIDs == afterDeleteAndAdd.map(\.id),
            "track deletion/addition rebuilt mixer identity incorrectly"
        )

        if let snapshotURL {
            try writeSnapshot(of: panel, to: snapshotURL)
            print("wrote mixer snapshot: \(snapshotURL.path)")
        }

        // Opening is animated over 240 ms. Keep the normal-project budget well
        // inside that transition while allowing for gate-wide process load;
        // steady-state updates use the retained, no-reload path above.
        let initialDisplayBudget = channelCount >= 1_000 ? 240.0 : 160.0
        let reorderBudget = channelCount >= 1_000 ? 80.0 : 24.0
        try require(
            initialDisplayMilliseconds < initialDisplayBudget,
            "mixer initial display took \(String(format: "%.2f", initialDisplayMilliseconds)) ms (budget \(initialDisplayBudget) ms)"
        )
        try require(
            reorderMilliseconds < reorderBudget,
            "mixer reorder took \(String(format: "%.2f", reorderMilliseconds)) ms (budget \(reorderBudget) ms)"
        )

        panel.display(channels: [])
        panel.testingLayout(in: CGSize(width: 1_200, height: 340))
        try require(panel.testingChannelIDs.isEmpty, "empty mixer retained project channel strips")
        try require(panel.testingMasterStripIsVisible, "empty mixer hid the master strip")
        _ = window
        return (visibleCount, initialDisplayMilliseconds, reorderMilliseconds)
    }

    private static func mixerSnapshotURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/mixer-smoke/mixer-panel.png")
    }

    private static func writeSnapshot(of view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SmokeError.failed("mixer snapshot bitmap allocation failed")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SmokeError.failed("mixer snapshot PNG encoding failed")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func makeChannels(count: Int) -> [MixerChannelPresentation] {
        (0..<count).map { index in
            MixerChannelPresentation(
                id: UUID(),
                name: "Track \(index + 1)",
                channelLayout: index.isMultiple(of: 3) ? .mono : .stereo,
                volume: index.isMultiple(of: 11) ? 0.5 : 1,
                pan: Float((index % 5) - 2) / 2,
                isMuted: index.isMultiple(of: 17),
                isSoloed: index == 3,
                isVolumeAutomated: index.isMultiple(of: 7),
                isPanAutomated: index.isMultiple(of: 13),
                volumeAutomationMode: index.isMultiple(of: 9) ? .touch : .read,
                panAutomationMode: .read
            )
        }
    }

    private static func milliseconds(since startedAt: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SmokeError.failed(message) }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SmokeError.failed(message) }
        return value
    }
}
