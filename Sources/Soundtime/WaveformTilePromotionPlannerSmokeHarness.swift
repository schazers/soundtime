import Foundation

enum WaveformTilePromotionPlannerSmokeHarness {
    private enum SmokeError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(message):
                return message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds

        try verifyFirstDrawHasNoFade()
        try verifyExactPromotionCrossfadesOverTime()
        try verifyCoarserReplacementCrossfades()
        try verifyExpiredTransitionDropsPreviousLayer()
        try verifySourceRemovalClearsPromotionState()

        let checks = [
            "first draw has no fade",
            "exact promotion crossfades over time",
            "coarser replacement crossfades",
            "expired transition drops previous layer",
            "source removal clears promotion state",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "waveform-tile-promotion-planner-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: ["rendererIntegration": "disabled"],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }
        print("Soundtime waveform tile promotion planner smoke passed")
    }

    private static func verifyFirstDrawHasNoFade() throws {
        let planner = WaveformTilePromotionPlanner(config: config())
        let tile = renderableTile(level: 6, resourceSuffix: "coarse")

        let plan = planner.plan(selection: selection([tile]), timestamp: 10)

        try require(plan.tiles.count == 1, "first draw did not produce one tile")
        try require(plan.drawLayerCount == 1, "first draw should have one draw layer")
        try require(plan.tiles[0].current.alpha == 1, "first draw current alpha should be 1")
        try require(plan.tiles[0].previous == nil, "first draw should not include a previous layer")
        try require(!plan.tiles[0].isTransitioning, "first draw should not be transitioning")
    }

    private static func verifyExactPromotionCrossfadesOverTime() throws {
        let planner = WaveformTilePromotionPlanner(config: config())
        let coarse = renderableTile(level: 8, resourceSuffix: "coarse")
        let exact = renderableTile(level: 5, resourceSuffix: "exact")

        _ = planner.plan(selection: selection([coarse]), timestamp: 0)
        let startPlan = planner.plan(selection: selection([exact]), timestamp: 1)
        let midPlan = planner.plan(selection: selection([exact]), timestamp: 1.05)

        try require(startPlan.tiles[0].current.alpha == 0, "promotion should start with incoming alpha 0")
        try require(startPlan.tiles[0].previous?.alpha == 1, "promotion should start with previous alpha 1")
        try require(startPlan.tiles[0].isTransitioning, "promotion start should be transitioning")
        try require(midPlan.tiles[0].current.alpha > 0.45 && midPlan.tiles[0].current.alpha < 0.55, "mid promotion should be roughly half faded in")
        try require(midPlan.tiles[0].previous?.alpha ?? 0 > 0.45, "mid promotion previous layer should still be visible")
    }

    private static func verifyCoarserReplacementCrossfades() throws {
        let planner = WaveformTilePromotionPlanner(config: config())
        let exact = renderableTile(level: 5, resourceSuffix: "exact")
        let coarser = renderableTile(level: 7, resourceSuffix: "coarser")

        _ = planner.plan(selection: selection([exact]), timestamp: 0)
        let plan = planner.plan(selection: selection([coarser]), timestamp: 0.025)

        try require(plan.tiles[0].previous?.descriptor.address == exact.selectedDescriptor.address, "coarser replacement should keep exact tile underneath")
        try require(plan.tiles[0].current.descriptor.address == coarser.selectedDescriptor.address, "coarser replacement current layer was wrong")
        try require(plan.tiles[0].isTransitioning, "coarser replacement should transition instead of popping")
    }

    private static func verifyExpiredTransitionDropsPreviousLayer() throws {
        let planner = WaveformTilePromotionPlanner(config: config())
        let coarse = renderableTile(level: 8, resourceSuffix: "coarse")
        let exact = renderableTile(level: 5, resourceSuffix: "exact")

        _ = planner.plan(selection: selection([coarse]), timestamp: 0)
        _ = planner.plan(selection: selection([exact]), timestamp: 1)
        let finished = planner.plan(selection: selection([exact]), timestamp: 1.2)

        try require(finished.tiles[0].previous == nil, "finished promotion should drop previous layer")
        try require(finished.tiles[0].current.alpha == 1, "finished promotion current alpha should be 1")
        try require(!finished.tiles[0].isTransitioning, "finished promotion should not be transitioning")
    }

    private static func verifySourceRemovalClearsPromotionState() throws {
        let planner = WaveformTilePromotionPlanner(config: config())
        let sourceID = WaveformSourceID(rawValue: "promotion-removed-source")
        let coarse = renderableTile(sourceID: sourceID, level: 8, resourceSuffix: "coarse")
        let exact = renderableTile(sourceID: sourceID, level: 5, resourceSuffix: "exact")

        _ = planner.plan(selection: selection([coarse]), timestamp: 0)
        _ = planner.plan(selection: selection([exact]), timestamp: 0.02)
        planner.removeAll(for: sourceID)
        let afterRemoval = planner.plan(selection: selection([exact]), timestamp: 0.03)

        try require(afterRemoval.tiles[0].previous == nil, "source removal should clear old promotion state")
        try require(afterRemoval.tiles[0].current.alpha == 1, "source removal should make next draw immediate")
    }

    private static func config() -> WaveformTilePromotionConfig {
        WaveformTilePromotionConfig(crossfadeDuration: 0.1)
    }

    private static func selection(_ tiles: [WaveformRenderableTile]) -> WaveformTileRenderSelection {
        WaveformTileRenderSelection(
            tiles: tiles,
            requestedCount: tiles.count,
            exactResidentCount: tiles.filter { $0.source == .exactResident }.count,
            coarserResidentCount: tiles.filter { $0.source == .coarserResident }.count,
            lastGoodResidentCount: tiles.filter { $0.source == .lastGoodResident }.count,
            skippedCount: 0
        )
    }

    private static func renderableTile(
        sourceID: WaveformSourceID = WaveformSourceID(rawValue: "promotion-source"),
        level: Int,
        resourceSuffix: String
    ) -> WaveformRenderableTile {
        let requestedDescriptor = descriptor(sourceID: sourceID, level: 5, tileIndex: 0)
        let selectedDescriptor = descriptor(sourceID: sourceID, level: level, tileIndex: 0)
        return WaveformRenderableTile(
            requestedDescriptor: requestedDescriptor,
            selectedDescriptor: selectedDescriptor,
            resource: WaveformTileGPUResource(
                id: WaveformTileGPUResourceID(rawValue: "gpu-\(resourceSuffix)"),
                byteCount: max(1, 1_024 / max(1, level))
            ),
            source: level == requestedDescriptor.address.level ? .exactResident : .coarserResident
        )
    }

    private static func descriptor(
        sourceID: WaveformSourceID,
        level: Int,
        tileIndex: Int
    ) -> WaveformTileDescriptor {
        WaveformTileDescriptor(
            address: WaveformTileAddress(
                sourceID: sourceID,
                kind: .peak,
                channelMode: .monoMix,
                level: level,
                tileIndex: tileIndex
            ),
            frameRange: WaveformFrameRange(startFrame: 0, endFrame: 1_024),
            framesPerBin: max(1, 1 << level),
            expectedBinCount: max(1, 1_024 / max(1, 1 << level))
        )
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw SmokeError.failed(message)
        }
    }
}
