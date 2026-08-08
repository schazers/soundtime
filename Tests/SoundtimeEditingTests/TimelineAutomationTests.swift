import Foundation
import Testing
@testable import SoundtimeEditing

@Test func automationParameterDescriptorsUseMixerFaderLawAndBipolarPan() throws {
    let volume = try #require(TimelineAutomationParameterRegistry.descriptor(for: .volume))
    let pan = try #require(TimelineAutomationParameterRegistry.descriptor(for: .pan))

    #expect(abs(volume.domainValue(fromNormalized: TimelineMixerFaderLaw.unityPosition) - 1) < 0.0001)
    #expect(abs(volume.normalizedValue(fromDomain: 1) - TimelineMixerFaderLaw.unityPosition) < 0.0001)
    #expect(volume.formattedValue(normalizedValue: 0) == "-inf dB")
    #expect(pan.domainValue(fromNormalized: 0) == -1)
    #expect(pan.domainValue(fromNormalized: 0.5) == 0)
    #expect(pan.domainValue(fromNormalized: 1) == 1)
    #expect(pan.normalizedValue(fromDomain: 0) == 0.5)
    #expect(pan.formattedValue(normalizedValue: 0.5) == "C")
    #expect(pan.formattedValue(normalizedValue: 0) == "L100")
    #expect(pan.formattedValue(normalizedValue: 1) == "R100")
}

@Test func automationParameterDescriptorsParseDisplayedUnits() throws {
    let volume = TimelineAutomationParameterRegistry.trackVolume
    let pan = TimelineAutomationParameterRegistry.trackPan
    let mute = TimelineAutomationParameterRegistry.trackMute

    let parsedMinusSix = try #require(volume.normalizedValue(parsing: "-6 dB"))
    #expect(abs(volume.domainValue(fromNormalized: parsedMinusSix) - pow(10, Float(-6) / 20)) < 0.001)
    #expect(pan.normalizedValue(parsing: "L25") == 0.375)
    #expect(pan.normalizedValue(parsing: "C") == 0.5)
    #expect(pan.normalizedValue(parsing: "R100") == 1)
    #expect(mute.normalizedValue(parsing: "On") == 1)
    #expect(mute.normalizedValue(parsing: "Off") == 0)
}

@Test func mixerFaderLawRoundTripsImportantAudibleValues() {
    for gain: Float in [0, 0.001, 0.063_095_7, 0.5, 1, 1.5, TimelineMixerFaderLaw.maximumGain] {
        let roundTrip = TimelineMixerFaderLaw.gain(
            forPosition: TimelineMixerFaderLaw.position(forGain: gain)
        )
        #expect(abs(roundTrip - gain) < max(gain * 0.000_1, 0.000_001))
    }
    #expect(TimelineMixerFaderLaw.position(forGain: 1) == TimelineMixerFaderLaw.unityPosition)
}

@Test func legacySquaredVolumeAutomationMigratesWithoutChangingGain() throws {
    let trackID = UUID()
    let lane = try TimelineAutomationLane(
        address: .track(trackID, parameterID: .volume),
        defaultNormalizedValue: 0.5,
        points: [TimelineAutomationPoint(frame: 120, normalizedValue: 0.75)]
    )
    let document = TimelineAutomationDocument(schemaVersion: 1, revision: 7, lanes: [lane])

    let migrated = try #require(document.makeGraph().lane(at: lane.address))
    let descriptor = TimelineAutomationParameterRegistry.trackVolume
    #expect(abs(descriptor.domainValue(fromNormalized: migrated.defaultNormalizedValue) - 0.25) < 0.000_1)
    #expect(abs(descriptor.domainValue(fromNormalized: migrated.points[0].normalizedValue) - 0.5625) < 0.000_1)
    #expect(migrated.points[0].id == lane.points[0].id)
}

@Test func automationCurvePresetsHaveDeterministicAudibleShapes() {
    #expect(TimelineAutomationCurve.progress(0.5, curve: TimelineAutomationCurvePreset.linear.persistedCurve) == 0.5)
    #expect(TimelineAutomationCurve.progress(0.25, curve: TimelineAutomationCurvePreset.sCurve.persistedCurve) == 0.15625)
    #expect(TimelineAutomationCurve.progress(0.999, curve: TimelineAutomationCurvePreset.stepped.persistedCurve) == 0)
    #expect(TimelineAutomationCurve.progress(1, curve: TimelineAutomationCurvePreset.stepped.persistedCurve) == 1)
}

@Test func automationClipboardPreservesRelativeTimingAndRegeneratesIDs() throws {
    let firstID = UUID()
    let secondID = UUID()
    let lane = try TimelineAutomationLane(
        address: .track(UUID(), parameterID: .pan),
        defaultNormalizedValue: 0.5,
        points: [
            TimelineAutomationPoint(id: firstID, frame: 100, normalizedValue: 0.25, curveToNext: TimelineAutomationCurve.sCurve),
            TimelineAutomationPoint(id: secondID, frame: 160, normalizedValue: 0.75, curveToNext: TimelineAutomationCurve.stepped),
        ]
    )
    let clipboard = try #require(TimelineAutomationPointClipboard(lane: lane, pointIDs: [firstID, secondID]))
    let pasted = clipboard.points(pastedAt: 1_000)

    #expect(clipboard.frameSpan == 60)
    #expect(pasted.map(\.frame) == [1_000, 1_060])
    #expect(pasted.map(\.normalizedValue) == [0.25, 0.75])
    #expect(pasted.map(\.curveToNext) == [TimelineAutomationCurve.sCurve, TimelineAutomationCurve.stepped])
    #expect(Set(pasted.map(\.id)).isDisjoint(with: [firstID, secondID]))
}

@Test func automationCommandsInsertClipboardAndSetMultipleCurvesAtomically() throws {
    let address = TimelineAutomationAddress.track(UUID(), parameterID: .volume)
    let first = TimelineAutomationPoint(frame: 10, normalizedValue: 0.2)
    let second = TimelineAutomationPoint(frame: 20, normalizedValue: 0.8)
    let inserted = try TimelineAutomationCommandExecutor.execute(
        .insertPoints(address: address, points: [first, second]),
        in: TimelineAutomationGraph()
    )
    let curved = try TimelineAutomationCommandExecutor.execute(
        .setSegmentCurves(
            address: address,
            leadingPointIDs: [first.id, second.id],
            curve: TimelineAutomationCurve.sCurve
        ),
        in: inserted.graph
    )

    #expect(curved.afterLane?.points.map(\.curveToNext) == [TimelineAutomationCurve.sCurve, TimelineAutomationCurve.sCurve])
    #expect(curved.graph.revision == inserted.graph.revision + 1)
}

@Test func typedAutomationCommandsKeepStableIDsAndRejectFrameCollisions() throws {
    let address = TimelineAutomationAddress.track(UUID(), parameterID: .pan)
    let firstID = UUID()
    let secondID = UUID()
    let empty = try TimelineAutomationGraph()
    let first = try TimelineAutomationCommandExecutor.execute(
        .addPoint(address: address, frame: 10, normalizedValue: 0.25, curveToNext: 0, pointID: firstID),
        in: empty
    )
    let second = try TimelineAutomationCommandExecutor.execute(
        .addPoint(address: address, frame: 20, normalizedValue: 0.75, curveToNext: 0, pointID: secondID),
        in: first.graph
    )
    let moved = try TimelineAutomationCommandExecutor.execute(
        .movePoints(
            address: address,
            pointIDs: [firstID],
            frameDelta: 5,
            normalizedValueDelta: 0.1
        ),
        in: second.graph
    )

    #expect(moved.afterLane?.points.map(\.id) == [firstID, secondID])
    #expect(moved.afterLane?.points.map(\.frame) == [15, 20])
    #expect(abs((moved.afterLane?.points[0].normalizedValue ?? 0) - 0.35) < 0.0001)

    #expect(throws: TimelineAutomationCommandError.pointCollision(20)) {
        try TimelineAutomationCommandExecutor.execute(
            .movePoints(
                address: address,
                pointIDs: [firstID],
                frameDelta: 5,
                normalizedValueDelta: 0
            ),
            in: moved.graph
        )
    }
}

@Test func typedAutomationCommandsMoveMultiplePointsAsOneTransaction() throws {
    let address = TimelineAutomationAddress.track(UUID(), parameterID: .volume)
    let firstID = UUID()
    let secondID = UUID()
    let lane = try TimelineAutomationLane(
        address: address,
        defaultNormalizedValue: 1,
        points: [
            TimelineAutomationPoint(id: firstID, frame: 20, normalizedValue: 0.2),
            TimelineAutomationPoint(id: secondID, frame: 40, normalizedValue: 0.7),
        ]
    )
    let graph = try TimelineAutomationGraph(lanes: [lane])

    let result = try TimelineAutomationCommandExecutor.execute(
        .movePoints(
            address: address,
            pointIDs: [firstID, secondID],
            frameDelta: 12,
            normalizedValueDelta: 0.1
        ),
        in: graph
    )

    #expect(result.afterLane?.points.map(\.id) == [firstID, secondID])
    #expect(result.afterLane?.points.map(\.frame) == [32, 52])
    #expect(result.afterLane?.points.map(\.normalizedValue) == [0.3, 0.8])
    #expect(result.graph.revision == graph.revision + 1)
}

@Test func automationWriteModePersistsForAnEmptyLane() throws {
    let address = TimelineAutomationAddress.track(UUID(), parameterID: .pan)
    let result = try TimelineAutomationCommandExecutor.execute(
        .setWriteMode(address: address, mode: .off),
        in: TimelineAutomationGraph()
    )

    #expect(result.afterLane?.writeMode == .off)
    #expect(result.afterLane?.isEnabled == false)
    #expect(result.afterLane?.points.isEmpty == true)
}

@Test func legacyAutomationLaneWithoutWriteModeDecodesAsRead() throws {
    let trackID = UUID()
    let encoded = try JSONEncoder().encode(
        try TimelineAutomationLane(
            address: .track(trackID, parameterID: .volume),
            defaultNormalizedValue: 1
        )
    )
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "writeMode")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(TimelineAutomationLane.self, from: legacyData)

    #expect(decoded.writeMode == .read)
    #expect(decoded.isEnabled)
}

@Test func automationParameterCatalogRejectsDuplicateStableIDs() {
    let descriptor = TimelineAutomationParameterRegistry.trackVolume
    #expect(throws: TimelineAutomationParameterCatalogError.duplicateParameterID(.volume)) {
        try TimelineAutomationParameterCatalog(descriptors: [descriptor, descriptor])
    }
}

@Test func legacyTimelineTrackWithoutPanDecodesCentered() throws {
    let trackID = UUID()
    let json = """
    {
      "id": "\(trackID.uuidString)",
      "name": "Legacy",
      "clips": [],
      "volume": 0.8,
      "isMuted": false,
      "isSoloed": false,
      "isLocked": false,
      "metadata": {},
      "collisionPolicy": "rejectOverlaps"
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(TimelineTrack.self, from: json)
    #expect(decoded.pan == 0)
    #expect(decoded.id == trackID)
}

@Test func automationLaneUsesHorizontalFencePostsAndLinearSegments() throws {
    let trackID = UUID()
    let lane = try TimelineAutomationLane(
        address: .track(trackID, parameterID: .volume),
        defaultNormalizedValue: 0.75,
        points: [
            TimelineAutomationPoint(frame: 100, normalizedValue: 0.2),
            TimelineAutomationPoint(frame: 200, normalizedValue: 0.8),
        ]
    )

    #expect(lane.normalizedValue(at: 0) == 0.2)
    #expect(lane.normalizedValue(at: 100) == 0.2)
    #expect(abs(lane.normalizedValue(at: 150) - 0.5) < 0.0001)
    #expect(lane.normalizedValue(at: 200) == 0.8)
    #expect(lane.normalizedValue(at: 10_000) == 0.8)
}

@Test func automationLaneCurvesSegmentsWithoutChangingEndpoints() throws {
    let trackID = UUID()
    let easeIn = try TimelineAutomationLane(
        address: .track(trackID, parameterID: .volume),
        defaultNormalizedValue: 0,
        points: [
            TimelineAutomationPoint(frame: 0, normalizedValue: 0, curveToNext: 0.8),
            TimelineAutomationPoint(frame: 100, normalizedValue: 1),
        ]
    )
    let easeOut = try TimelineAutomationLane(
        address: .track(trackID, parameterID: .volume),
        defaultNormalizedValue: 0,
        points: [
            TimelineAutomationPoint(frame: 0, normalizedValue: 0, curveToNext: -0.8),
            TimelineAutomationPoint(frame: 100, normalizedValue: 1),
        ]
    )

    #expect(easeIn.normalizedValue(at: 50) < 0.5)
    #expect(easeOut.normalizedValue(at: 50) > 0.5)
    #expect(easeIn.normalizedValue(at: 0) == 0)
    #expect(easeIn.normalizedValue(at: 100) == 1)
}

@Test func automationCurveUsesCubicBezierTiming() {
    #expect(abs(TimelineAutomationCurve.progress(0.5, curve: 1) - 0.125) < 0.0001)
    #expect(abs(TimelineAutomationCurve.progress(0.5, curve: -1) - 0.875) < 0.0001)
    #expect(TimelineAutomationCurve.progress(0, curve: 1) == 0)
    #expect(TimelineAutomationCurve.progress(1, curve: -1) == 1)
}

@Test func changingAutomationCurveDoesNotCreateControlPoints() throws {
    let trackID = UUID()
    let firstID = UUID()
    let secondID = UUID()
    var lane = try TimelineAutomationLane(
        address: .track(trackID, parameterID: .volume),
        defaultNormalizedValue: 1,
        points: [
            TimelineAutomationPoint(id: firstID, frame: 100, normalizedValue: 0.8),
            TimelineAutomationPoint(id: secondID, frame: 200, normalizedValue: 0.2),
        ]
    )

    try lane.setCurve(leavingPointID: firstID, curve: 0.72)

    #expect(lane.points.count == 2)
    #expect(lane.points.map(\.id) == [firstID, secondID])
    #expect(lane.points.map(\.frame) == [100, 200])
    #expect(lane.points[0].curveToNext == 0.72)
}

@Test func automationPointMutationMaintainsStableIdentityAndOrdering() throws {
    let trackID = UUID()
    var lane = try TimelineAutomationLane(
        address: .track(trackID, parameterID: .volume),
        defaultNormalizedValue: 1
    )
    let first = try lane.setPoint(frame: 40, normalizedValue: 0.4)
    _ = try lane.setPoint(frame: 10, normalizedValue: 0.1)
    let replacement = try lane.setPoint(frame: 40, normalizedValue: 0.8)

    #expect(first.id == replacement.id)
    #expect(lane.points.map(\.frame) == [10, 40])
    #expect(lane.points.last?.normalizedValue == 0.8)

    try lane.movePoint(id: first.id, toFrame: 25, normalizedValue: 0.6)
    #expect(lane.points.map(\.frame) == [10, 25])
    try lane.removePoint(id: first.id)
    #expect(lane.points.map(\.frame) == [10])
}

@Test func rippleDeleteMovesOnlyAffectedTrackAutomation() throws {
    let affectedTrackID = UUID()
    let untouchedTrackID = UUID()
    let affectedLane = try TimelineAutomationLane(
        address: .track(affectedTrackID, parameterID: .volume),
        defaultNormalizedValue: 1,
        points: [
            TimelineAutomationPoint(frame: 10, normalizedValue: 0.1),
            TimelineAutomationPoint(frame: 50, normalizedValue: 0.5),
            TimelineAutomationPoint(frame: 100, normalizedValue: 0.9),
        ]
    )
    let untouchedLane = try TimelineAutomationLane(
        address: .track(untouchedTrackID, parameterID: .volume),
        defaultNormalizedValue: 1,
        points: [TimelineAutomationPoint(frame: 100, normalizedValue: 0.7)]
    )
    let graph = try TimelineAutomationGraph(lanes: [affectedLane, untouchedLane])
    let range = TimelineFrameRange(startFrame: 40, frameCount: 30)

    let transformed = try graph.rippleDeleting(
        range,
        affectedTrackIDs: [affectedTrackID],
        followsTrackAutomation: true
    )

    #expect(transformed.lane(at: affectedLane.address)?.points.map(\.frame) == [10, 40, 70])
    #expect(transformed.lane(at: untouchedLane.address) == untouchedLane)
}

@Test func clipOwnedAutomationSurvivesCrossTrackMove() throws {
    let clipID = AudioTimelineClipID()
    let lane = try TimelineAutomationLane(
        address: TimelineAutomationAddress(owner: .clip(clipID), parameterID: .volume),
        defaultNormalizedValue: 1,
        points: [TimelineAutomationPoint(frame: 20, normalizedValue: 0.5)]
    )
    let graph = try TimelineAutomationGraph(lanes: [lane])
    let destinationTrackID = UUID()

    let supported = try graph.transformedForClipMove(
        clipID: clipID,
        destinationTrackID: destinationTrackID,
        supportsParameter: { _, _ in true }
    )
    #expect(supported.lane(at: lane.address)?.isEnabled == true)

    let unsupported = try graph.transformedForClipMove(
        clipID: clipID,
        destinationTrackID: destinationTrackID,
        supportsParameter: { _, _ in false }
    )
    #expect(unsupported.lane(at: lane.address)?.isEnabled == false)
    #expect(unsupported.lane(at: lane.address)?.points == lane.points)
}

@Test func clipOwnedAutomationDuplicatesWithFreshIdentities() throws {
    let sourceClipID = AudioTimelineClipID()
    let destinationClipID = AudioTimelineClipID()
    let sourceLane = try TimelineAutomationLane(
        address: TimelineAutomationAddress(owner: .clip(sourceClipID), parameterID: .volume),
        defaultNormalizedValue: 0.72,
        points: [
            TimelineAutomationPoint(frame: 12, normalizedValue: 0.2, curveToNext: -0.4),
            TimelineAutomationPoint(frame: 48, normalizedValue: 0.9, curveToNext: 0.6),
        ],
        isEnabled: true,
        writeMode: .read
    )
    let graph = try TimelineAutomationGraph(lanes: [sourceLane])

    let duplicated = try graph.duplicatingClipAutomation(
        from: sourceClipID,
        to: destinationClipID
    )
    let copiedLane = try #require(duplicated.lane(at: TimelineAutomationAddress(
        owner: .clip(destinationClipID),
        parameterID: .volume
    )))

    #expect(copiedLane.defaultNormalizedValue == sourceLane.defaultNormalizedValue)
    #expect(copiedLane.points.map(\.frame) == sourceLane.points.map(\.frame))
    #expect(copiedLane.points.map(\.normalizedValue) == sourceLane.points.map(\.normalizedValue))
    #expect(copiedLane.points.map(\.curveToNext) == sourceLane.points.map(\.curveToNext))
    #expect(Set(copiedLane.points.map(\.id)).isDisjoint(with: sourceLane.points.map(\.id)))
    #expect(duplicated.lane(at: sourceLane.address) == sourceLane)
}

@Test func automationDocumentRoundTrips() throws {
    let lane = try TimelineAutomationLane(
        address: .track(UUID(), parameterID: .volume),
        defaultNormalizedValue: 0.65,
        points: [TimelineAutomationPoint(frame: 240, normalizedValue: 0.3)]
    )
    let graph = try TimelineAutomationGraph(revision: 42, lanes: [lane])
    let data = try JSONEncoder().encode(TimelineAutomationDocument(graph: graph))
    let decoded = try JSONDecoder().decode(TimelineAutomationDocument.self, from: data)

    #expect(try decoded.makeGraph() == graph)
}

@Test func automationGraphMaintainsOwnerIndexAcrossMutations() throws {
    let firstTrackID = UUID()
    let secondTrackID = UUID()
    let firstVolumeAddress = TimelineAutomationAddress.track(firstTrackID, parameterID: .volume)
    let firstPanAddress = TimelineAutomationAddress.track(firstTrackID, parameterID: .pan)
    let secondVolumeAddress = TimelineAutomationAddress.track(secondTrackID, parameterID: .volume)
    let firstVolume = try TimelineAutomationLane(
        address: firstVolumeAddress,
        defaultNormalizedValue: 0.8
    )
    let firstPan = try TimelineAutomationLane(
        address: firstPanAddress,
        defaultNormalizedValue: 0.5
    )
    let secondVolume = try TimelineAutomationLane(
        address: secondVolumeAddress,
        defaultNormalizedValue: 0.7
    )
    var graph = try TimelineAutomationGraph(lanes: [firstVolume, secondVolume])

    #expect(graph.lanes(ownedBy: .track(firstTrackID)) == [firstVolume])
    #expect(graph.lanes(ownedBy: .track(secondTrackID)) == [secondVolume])

    try graph.upsertLane(firstPan)
    #expect(graph.lanes(ownedBy: .track(firstTrackID)).map(\.address) == [firstPanAddress, firstVolumeAddress])

    graph.removeLane(at: firstVolumeAddress)
    #expect(graph.lanes(ownedBy: .track(firstTrackID)) == [firstPan])

    try graph.restoreLane(at: firstVolumeAddress, to: firstVolume)
    #expect(graph.lanes(ownedBy: .track(firstTrackID)).map(\.address) == [firstPanAddress, firstVolumeAddress])

    graph.removeLaneWithoutAdvancingRevision(at: firstPanAddress)
    #expect(graph.lanes(ownedBy: .track(firstTrackID)) == [firstVolume])
}

@Test func pruningOrphansPreservesMovedClipAutomationAndMasterLane() throws {
    let liveTrackID = UUID()
    let removedTrackID = UUID()
    let liveClipID = AudioTimelineClipID()
    let removedClipID = AudioTimelineClipID()
    let lanes = try [
        TimelineAutomationLane(
            address: .track(liveTrackID, parameterID: .volume),
            defaultNormalizedValue: 1
        ),
        TimelineAutomationLane(
            address: .track(removedTrackID, parameterID: .volume),
            defaultNormalizedValue: 1
        ),
        TimelineAutomationLane(
            address: TimelineAutomationAddress(owner: .clip(liveClipID), parameterID: .volume),
            defaultNormalizedValue: 1
        ),
        TimelineAutomationLane(
            address: TimelineAutomationAddress(owner: .clip(removedClipID), parameterID: .volume),
            defaultNormalizedValue: 1
        ),
        TimelineAutomationLane(
            address: TimelineAutomationAddress(owner: .master, parameterID: .volume),
            defaultNormalizedValue: 1
        ),
    ]
    let graph = try TimelineAutomationGraph(lanes: lanes)

    let pruned = graph.pruningOrphanedOwners(
        liveTrackIDs: [liveTrackID],
        liveClipIDs: [liveClipID]
    )

    #expect(pruned.lane(at: .track(liveTrackID, parameterID: .volume)) != nil)
    #expect(pruned.lane(at: .track(removedTrackID, parameterID: .volume)) == nil)
    #expect(pruned.lane(at: TimelineAutomationAddress(owner: .clip(liveClipID), parameterID: .volume)) != nil)
    #expect(pruned.lane(at: TimelineAutomationAddress(owner: .clip(removedClipID), parameterID: .volume)) == nil)
    #expect(pruned.lane(at: TimelineAutomationAddress(owner: .master, parameterID: .volume)) != nil)
}

@Test func freehandSimplifierPreservesShapeEndpointsAndBoundsPointCount() {
    let samples = (0 ... 10_000).map { frame in
        TimelineAutomationDrawSample(
            frame: frame,
            normalizedValue: 0.5 + 0.25 * sin(Float(frame) / 1_000)
        )
    }
    let simplified = TimelineAutomationDrawSimplifier.simplified(
        samples,
        frameTolerance: 48,
        valueTolerance: 0.005
    )

    #expect(simplified.first == samples.first)
    #expect(simplified.last == samples.last)
    #expect(simplified.count < 300)
    #expect(zip(simplified, simplified.dropFirst()).allSatisfy { $0.frame < $1.frame })
}

@Test func touchWriteCaptureRestoresThePriorLaneAfterTheGesture() throws {
    let address = TimelineAutomationAddress.track(UUID(), parameterID: .volume)
    let lane = try TimelineAutomationLane(
        address: address,
        defaultNormalizedValue: 1,
        points: [
            TimelineAutomationPoint(frame: 0, normalizedValue: 0.8),
            TimelineAutomationPoint(frame: 1_000, normalizedValue: 0.6),
        ],
        writeMode: .touch
    )
    var capture = TimelineAutomationWriteCapture(
        address: address,
        mode: .touch,
        originalLane: lane,
        startFrame: 200,
        normalizedValue: 0.4
    )
    capture.append(frame: 300, normalizedValue: 0.3)
    let result = try TimelineAutomationCommandExecutor.execute(
        capture.command(endingAt: 300, frameTolerance: 1, valueTolerance: 0.0001),
        in: try TimelineAutomationGraph(lanes: [lane])
    )
    #expect(result.afterLane?.normalizedValue(at: 300) == 0.3)
    #expect(result.afterLane?.normalizedValue(at: 301) == lane.normalizedValue(at: 301))
}

@Test func latchWriteCaptureHoldsTheLastTouchedValueUntilPunchOut() throws {
    let address = TimelineAutomationAddress.track(UUID(), parameterID: .pan)
    let lane = try TimelineAutomationLane(
        address: address,
        defaultNormalizedValue: 0.5,
        writeMode: .latch
    )
    var capture = TimelineAutomationWriteCapture(
        address: address,
        mode: .latch,
        originalLane: lane,
        startFrame: 10,
        normalizedValue: 0.25
    )
    capture.append(frame: 20, normalizedValue: 0.75)
    let result = try TimelineAutomationCommandExecutor.execute(
        capture.command(endingAt: 100, frameTolerance: 1, valueTolerance: 0.0001),
        in: try TimelineAutomationGraph(lanes: [lane])
    )
    #expect(result.afterLane?.points.last?.frame == 100)
    #expect(result.afterLane?.points.last?.normalizedValue == 0.75)
}

@Test func writeCaptureReplacesTheEntireCapturedTransportRange() throws {
    let address = TimelineAutomationAddress.track(UUID(), parameterID: .volume)
    let lane = try TimelineAutomationLane(
        address: address,
        defaultNormalizedValue: 0.5,
        points: [
            TimelineAutomationPoint(frame: 0, normalizedValue: 0.2),
            TimelineAutomationPoint(frame: 500, normalizedValue: 0.8),
        ],
        writeMode: .write
    )
    var capture = TimelineAutomationWriteCapture(
        address: address,
        mode: .write,
        originalLane: lane,
        startFrame: 100,
        normalizedValue: 0.6
    )
    capture.append(frame: 200, normalizedValue: 0.4)
    capture.append(frame: 300, normalizedValue: 0.7)
    let command = capture.command(endingAt: 400, frameTolerance: 1, valueTolerance: 0.0001)
    let result = try TimelineAutomationCommandExecutor.execute(
        command,
        in: try TimelineAutomationGraph(lanes: [lane])
    )
    #expect(result.afterLane?.normalizedValue(at: 100) == 0.6)
    #expect(result.afterLane?.normalizedValue(at: 200) == 0.4)
    #expect(result.afterLane?.normalizedValue(at: 300) == 0.7)
    #expect(result.afterLane?.normalizedValue(at: 400) == 0.7)
    #expect(result.afterLane?.normalizedValue(at: 500) == lane.normalizedValue(at: 500))
}

@Test func pluginBindingUsesStableIDsAndPreservesMissingParameters() throws {
    let trackID = UUID()
    let pluginID = UUID()
    let unknownID = TimelineAutomationParameterID(rawValue: "plugin.vendor.stable-parameter")
    let lane = try TimelineAutomationLane(
        address: TimelineAutomationAddress(
            owner: .plugin(trackID: trackID, instanceID: pluginID),
            parameterID: unknownID
        ),
        defaultNormalizedValue: 0.5
    )
    let graph = try TimelineAutomationGraph(lanes: [lane])
    let bindings = TimelineAutomationParameterBindingResolver.resolve(
        graph: graph,
        liveTrackIDs: [trackID],
        liveClipIDs: [],
        livePluginInstanceIDs: [pluginID],
        descriptor: { _ in nil }
    )
    #expect(bindings == [TimelineAutomationParameterBinding(
        address: lane.address,
        descriptor: nil,
        state: .missingParameter
    )])
    #expect(graph.lane(at: lane.address) == lane)
}
