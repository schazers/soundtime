import XCTest
@testable import SoundtimeEditing

final class AudioSegmentArrangementTests: XCTestCase {
    func testSelectionNormalizesAndClampsBounds() {
        let trackID = UUID()
        let selection = TimelineSelection(
            startProgress: 1.4,
            endProgress: -0.2,
            trackID: trackID
        )

        XCTAssertEqual(selection.startProgress, 0)
        XCTAssertEqual(selection.endProgress, 1)
        XCTAssertEqual(selection.trackID, trackID)
        XCTAssertEqual(selection.duration(in: 12), 12)
    }

    func testSelectionTimeRangeUsesThePresentationDurationThatCreatedIt() {
        let selection = TimelineSelection(
            startProgress: 0.25,
            endProgress: 0.5
        )

        let presentationRange = selection.timeRange(in: 80)
        let unrelatedPlaybackRange = selection.timeRange(in: 120)

        XCTAssertEqual(presentationRange?.lowerBound, 20)
        XCTAssertEqual(presentationRange?.upperBound, 40)
        XCTAssertEqual(unrelatedPlaybackRange?.lowerBound, 30)
        XCTAssertEqual(unrelatedPlaybackRange?.upperBound, 60)
    }

    func testSelectionTimeRangeRejectsUnavailableTimelineDuration() {
        let selection = TimelineSelection(
            startProgress: 0.25,
            endProgress: 0.5
        )

        XCTAssertNil(selection.timeRange(in: 0))
        XCTAssertNil(selection.timeRange(in: .nan))
    }

    func testTimelineSegmentsProjectAcrossSampleRatesWithoutChangingTime() throws {
        let nativeSegment = AudioTimelinePlaybackSegment(
            outputStartFrame: 44_100,
            sourceStartFrame: 22_050,
            frameCount: 88_200,
            sourceFrameScale: 1,
            gainStart: 0.75,
            gainEnd: 0.5,
            startsNewClip: false
        )

        let projected = try XCTUnwrap(
            AudioTimelineSampleRateProjection.project(
                nativeSegment,
                timelineSampleRate: 44_100,
                outputSampleRate: 48_000
            )
        )

        XCTAssertEqual(projected.outputStartFrame, 48_000)
        XCTAssertEqual(projected.frameCount, 96_000)
        XCTAssertEqual(projected.sourceStartFrame, 22_050)
        XCTAssertEqual(projected.sourceFrameScale, 44_100.0 / 48_000.0, accuracy: 0.000_000_001)
        XCTAssertEqual(projected.gainStart, 0.75)
        XCTAssertEqual(projected.gainEnd, 0.5)
    }

    func testDeferredEditStateCanPublishOnlyAtCapturedRevision() {
        XCTAssertTrue(
            DeferredEditStatePublicationPolicy.mayReplaceCurrentState(
                capturedRevision: 7,
                currentRevision: 7
            )
        )
        XCTAssertFalse(
            DeferredEditStatePublicationPolicy.mayReplaceCurrentState(
                capturedRevision: 7,
                currentRevision: 8
            )
        )
    }

    func testRippleDeleteRemovesOnlySelectedFramesAndPreservesSourceIdentity() {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)

        let deleted = arrangement.delete(frameRange: 200..<350)

        XCTAssertEqual(deleted, 150)
        XCTAssertEqual(arrangement.frameCount, 850)
        XCTAssertEqual(arrangement.playbackSegments.count, 2)
        XCTAssertEqual(arrangement.playbackSegments[0].sourceStartFrame, 0)
        XCTAssertEqual(arrangement.playbackSegments[0].frameCount, 200)
        XCTAssertEqual(arrangement.playbackSegments[1].sourceStartFrame, 350)
        XCTAssertEqual(arrangement.playbackSegments[1].frameCount, 650)
        XCTAssertEqual(arrangement.playbackSegments[1].outputStartFrame, 200)
    }

    func testClearPreservesTimelineLengthWithSilence() {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)

        let cleared = arrangement.clear(frameRange: 200..<350)

        XCTAssertEqual(cleared, 150)
        XCTAssertEqual(arrangement.frameCount, 1_000)
        XCTAssertEqual(arrangement.playbackSegments.count, 3)
        XCTAssertEqual(arrangement.playbackSegments[1].sourceStartFrame, 200)
        XCTAssertEqual(arrangement.playbackSegments[1].frameCount, 150)
        XCTAssertEqual(arrangement.playbackSegments[1].gainStart, 0)
        XCTAssertEqual(arrangement.playbackSegments[1].gainEnd, 0)
    }

    func testCopyInsertAndReplaceKeepExactFrameCounts() {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)
        let copied = arrangement.segments(in: 100..<220)

        XCTAssertEqual(arrangement.insert(copied, atFrame: 500), 120)
        XCTAssertEqual(arrangement.frameCount, 1_120)
        XCTAssertEqual(arrangement.segments(in: 500..<620), copied)

        let removed = arrangement.replace(frameRange: 700..<760, with: copied)
        XCTAssertEqual(removed, 120)
        XCTAssertEqual(arrangement.frameCount, 1_180)
        XCTAssertEqual(arrangement.segments(in: 700..<820), copied)
    }

    func testSplitCreatesBoundaryAndHealRemovesIt() {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)

        XCTAssertTrue(arrangement.split(atFrame: 400))
        XCTAssertEqual(arrangement.clipRanges.count, 2)
        XCTAssertTrue(arrangement.segments[1].startsNewClip)

        XCTAssertTrue(arrangement.healNearestClipBoundary(atProgress: 0.4))
        XCTAssertEqual(arrangement.clipRanges.count, 1)
        XCTAssertFalse(arrangement.segments.dropFirst().contains(where: \.startsNewClip))
    }

    func testClipIdentitySurvivesInternalEditsAndLegacyBoundaries() throws {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)
        let originalID = try XCTUnwrap(arrangement.clipRanges.first?.id)

        XCTAssertTrue(arrangement.splitClip(id: originalID, atLocalFrame: 400) != nil)
        XCTAssertEqual(arrangement.clipRanges.count, 2)
        XCTAssertEqual(arrangement.clipRanges.first?.id, originalID)

        let firstRange = try XCTUnwrap(arrangement.frameRange(forClipID: originalID))
        XCTAssertEqual(firstRange, 0..<400)
        XCTAssertEqual(arrangement.deleteWithinClip(
            id: originalID,
            localFrameRange: 100..<200,
            followingClipPolicy: .ripple
        ), 100)
        XCTAssertEqual(arrangement.frameRange(forClipID: originalID), 0..<300)
    }

    func testClipLocalDeleteCanPreserveLaterClipPositions() throws {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)
        let firstID = try XCTUnwrap(arrangement.clipRanges.first?.id)
        let secondID = try XCTUnwrap(arrangement.splitClip(id: firstID, atLocalFrame: 400))
        let secondRangeBefore = try XCTUnwrap(arrangement.frameRange(forClipID: secondID))

        XCTAssertEqual(arrangement.deleteWithinClip(
            id: firstID,
            localFrameRange: 100..<250,
            followingClipPolicy: .preserveTimelinePositions
        ), 150)

        XCTAssertEqual(arrangement.frameCount, 1_000)
        XCTAssertEqual(arrangement.frameRange(forClipID: firstID), 0..<250)
        XCTAssertEqual(arrangement.frameRange(forClipID: secondID), secondRangeBefore)
        let insertedGap = arrangement.playbackSegments.first {
            $0.outputStartFrame == 250 && $0.frameCount == 150
        }
        XCTAssertEqual(insertedGap?.gainStart, 0)
        XCTAssertEqual(insertedGap?.gainEnd, 0)
    }

    func testClipLocalPasteExtendsFocusedClipAndRipplesFollowingClip() throws {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)
        let firstID = try XCTUnwrap(arrangement.clipRanges.first?.id)
        let secondID = try XCTUnwrap(arrangement.splitClip(id: firstID, atLocalFrame: 400))
        let copied = arrangement.segments(in: 50..<150)

        XCTAssertEqual(arrangement.insertWithinClip(
            id: firstID,
            localFrame: 200,
            segments: copied
        ), 100)

        XCTAssertEqual(arrangement.frameCount, 1_100)
        XCTAssertEqual(arrangement.frameRange(forClipID: firstID), 0..<500)
        XCTAssertEqual(arrangement.frameRange(forClipID: secondID), 500..<1_100)
        XCTAssertTrue(arrangement.segments(in: 200..<300).allSatisfy { $0.clipID == firstID })
    }

    func testMovingAndDuplicatingClipsKeepStableDistinctIdentities() throws {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)
        let firstID = try XCTUnwrap(arrangement.clipRanges.first?.id)
        let secondID = try XCTUnwrap(arrangement.splitClip(id: firstID, atLocalFrame: 400))
        let duplicateID = try XCTUnwrap(arrangement.duplicateClip(id: firstID, atFrame: 1_000))

        XCTAssertNotEqual(duplicateID, firstID)
        XCTAssertEqual(arrangement.frameRange(forClipID: duplicateID), 1_000..<1_400)
        XCTAssertEqual(arrangement.moveClip(id: duplicateID, toFrame: 0), 0..<400)
        XCTAssertEqual(arrangement.frameRange(forClipID: duplicateID), 0..<400)
        XCTAssertNotNil(arrangement.frameRange(forClipID: firstID))
        XCTAssertNotNil(arrangement.frameRange(forClipID: secondID))
    }

    func testRelocatingClipLeavesSilenceAndPreservesTimelinePositions() throws {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)
        let clipID = try XCTUnwrap(arrangement.clipRanges.first?.id)

        XCTAssertEqual(arrangement.relocateClip(id: clipID, toFrame: 1_200), 1_200..<2_200)
        XCTAssertEqual(arrangement.frameCount, 2_200)
        XCTAssertEqual(arrangement.frameRange(forClipID: clipID), 1_200..<2_200)
        XCTAssertTrue(arrangement.playbackSegments.filter {
            $0.outputStartFrame < 1_000
        }.allSatisfy {
            $0.gainStart == 0 && $0.gainEnd == 0
        })
    }

    func testRelocatingClipRejectsOccupiedDestinationTransactionally() throws {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)
        let firstID = try XCTUnwrap(arrangement.clipRanges.first?.id)
        let secondID = try XCTUnwrap(arrangement.splitClip(id: firstID, atLocalFrame: 400))
        let originalSegments = arrangement.segments

        XCTAssertNil(arrangement.relocateClip(id: firstID, toFrame: 500))
        XCTAssertEqual(arrangement.segments, originalSegments)
        XCTAssertEqual(arrangement.frameRange(forClipID: firstID), 0..<400)
        XCTAssertEqual(arrangement.frameRange(forClipID: secondID), 400..<1_000)
    }

    func testRelocatingClipGroupPreservesSpacingAndIdentity() throws {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 300)
        let firstID = try XCTUnwrap(arrangement.clipRanges.first?.id)
        let secondID = try XCTUnwrap(arrangement.splitClip(id: firstID, atLocalFrame: 100))
        let thirdID = try XCTUnwrap(arrangement.splitClip(id: secondID, atLocalFrame: 100))
        XCTAssertEqual(arrangement.relocateClip(id: thirdID, toFrame: 500), 500..<600)

        let relocated = try XCTUnwrap(arrangement.relocateClips(
            ids: [firstID, secondID],
            byFrames: 200
        ))

        XCTAssertEqual(relocated[firstID], 200..<300)
        XCTAssertEqual(relocated[secondID], 300..<400)
        XCTAssertEqual(arrangement.frameRange(forClipID: firstID), 200..<300)
        XCTAssertEqual(arrangement.frameRange(forClipID: secondID), 300..<400)
        XCTAssertEqual(arrangement.frameRange(forClipID: thirdID), 500..<600)
    }

    func testRelocatingClipGroupRejectsBlockedDestinationTransactionally() throws {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 300)
        let firstID = try XCTUnwrap(arrangement.clipRanges.first?.id)
        let secondID = try XCTUnwrap(arrangement.splitClip(id: firstID, atLocalFrame: 100))
        let thirdID = try XCTUnwrap(arrangement.splitClip(id: secondID, atLocalFrame: 100))
        let originalSegments = arrangement.segments

        XCTAssertNil(arrangement.relocateClips(
            ids: [firstID, secondID],
            byFrames: 100
        ))
        XCTAssertEqual(arrangement.segments, originalSegments)
        XCTAssertEqual(arrangement.frameRange(forClipID: firstID), 0..<100)
        XCTAssertEqual(arrangement.frameRange(forClipID: secondID), 100..<200)
        XCTAssertEqual(arrangement.frameRange(forClipID: thirdID), 200..<300)
    }

    func testTrimClipStartPreservesTimelinePositionAndClipIdentity() throws {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)
        let clipID = try XCTUnwrap(arrangement.clipRanges.first?.id)

        XCTAssertEqual(arrangement.trimClipStart(id: clipID, toLocalFrame: 200), 200)

        XCTAssertEqual(arrangement.frameCount, 1_000)
        XCTAssertEqual(arrangement.frameRange(forClipID: clipID), 200..<1_000)
        let leadingGap = try XCTUnwrap(arrangement.playbackSegments.first)
        XCTAssertEqual(leadingGap.outputStartFrame, 0)
        XCTAssertEqual(leadingGap.frameCount, 200)
        XCTAssertEqual(leadingGap.gainStart, 0)
        XCTAssertEqual(leadingGap.gainEnd, 0)
        XCTAssertNotEqual(leadingGap.clipID, clipID)
    }

    func testTrimClipEndPreservesFollowingClipPositionAndClipIdentity() throws {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)
        let firstID = try XCTUnwrap(arrangement.clipRanges.first?.id)
        let secondID = try XCTUnwrap(arrangement.splitClip(id: firstID, atLocalFrame: 600))
        let secondRangeBefore = try XCTUnwrap(arrangement.frameRange(forClipID: secondID))

        XCTAssertEqual(arrangement.trimClipEnd(id: firstID, toLocalFrame: 350), 250)

        XCTAssertEqual(arrangement.frameCount, 1_000)
        XCTAssertEqual(arrangement.frameRange(forClipID: firstID), 0..<350)
        XCTAssertEqual(arrangement.frameRange(forClipID: secondID), secondRangeBefore)
        let trailingGap = try XCTUnwrap(arrangement.playbackSegments.first {
            $0.outputStartFrame == 350 && $0.frameCount == 250
        })
        XCTAssertEqual(trailingGap.gainStart, 0)
        XCTAssertEqual(trailingGap.gainEnd, 0)
        XCTAssertNotEqual(trailingGap.clipID, firstID)
    }

    func testDeleteClipRemovesOnlyTargetAndRipplesFollowingClips() throws {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)
        let firstID = try XCTUnwrap(arrangement.clipRanges.first?.id)
        let secondID = try XCTUnwrap(arrangement.splitClip(id: firstID, atLocalFrame: 300))
        let thirdID = try XCTUnwrap(arrangement.splitClip(id: secondID, atLocalFrame: 300))

        XCTAssertEqual(arrangement.deleteClip(id: secondID), 300)

        XCTAssertNil(arrangement.frameRange(forClipID: secondID))
        XCTAssertEqual(arrangement.frameRange(forClipID: firstID), 0..<300)
        XCTAssertEqual(arrangement.frameRange(forClipID: thirdID), 300..<700)
        XCTAssertEqual(arrangement.frameCount, 700)
    }

    func testDeletingClipGroupIsAtomicAndRipplesRemainingClipOnce() throws {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 900)
        let firstID = try XCTUnwrap(arrangement.clipRanges.first?.id)
        let secondID = try XCTUnwrap(arrangement.splitClip(id: firstID, atLocalFrame: 300))
        let thirdID = try XCTUnwrap(arrangement.splitClip(id: secondID, atLocalFrame: 300))

        XCTAssertEqual(arrangement.deleteClips(ids: [firstID, thirdID]), 600)

        XCTAssertNil(arrangement.frameRange(forClipID: firstID))
        XCTAssertEqual(arrangement.frameRange(forClipID: secondID), 0..<300)
        XCTAssertNil(arrangement.frameRange(forClipID: thirdID))
        XCTAssertEqual(arrangement.frameCount, 300)
    }

    func testMoveDestinationInsideClipIsStableNoOp() throws {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)
        let clipID = try XCTUnwrap(arrangement.clipRanges.first?.id)
        let segmentsBefore = arrangement.segments

        XCTAssertEqual(arrangement.moveClip(id: clipID, toFrame: 500), 0..<1_000)
        XCTAssertEqual(arrangement.segments, segmentsBefore)
        XCTAssertEqual(arrangement.frameRange(forClipID: clipID), 0..<1_000)
    }

    func testGainAndFadeChangeOnlyRequestedRange() {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)

        XCTAssertEqual(arrangement.applyGain(0.5, frameRange: 200..<400), 200)
        XCTAssertEqual(
            arrangement.applyFade(.fadeOut, frameRange: 600..<800),
            200
        )

        let gained = arrangement.segments(in: 200..<400)
        XCTAssertTrue(gained.allSatisfy {
            abs($0.gainStart - 0.5) < 0.000_001 &&
                abs($0.gainEnd - 0.5) < 0.000_001
        })
        let faded = arrangement.segments(in: 600..<800)
        XCTAssertEqual(faded.first?.gainStart, 1)
        XCTAssertEqual(faded.last?.gainEnd, 0)
    }

    func testTrimUsesNormalizedRangeWithoutChangingSourceFrames() {
        var arrangement = AudioSegmentArrangement(sourceFrameCount: 1_000)

        let removed = arrangement.trim(
            to: TimelineTrimRange(startProgress: 0.2, endProgress: 0.8)
        )

        XCTAssertEqual(removed, 400)
        XCTAssertEqual(arrangement.frameCount, 600)
        XCTAssertEqual(arrangement.playbackSegments.count, 1)
        XCTAssertEqual(arrangement.playbackSegments[0].sourceStartFrame, 200)
        XCTAssertEqual(arrangement.playbackSegments[0].frameCount, 600)
    }

    func testInvalidPersistedSegmentsAreClampedOrDiscarded() {
        let arrangement = AudioSegmentArrangement(
            sourceFrameCount: 100,
            segments: [
                AudioTimelineSegment(
                    sourceStartFrame: -50,
                    frameCount: 20,
                    gainStart: 1,
                    gainEnd: 1
                ),
                AudioTimelineSegment(
                    sourceStartFrame: 90,
                    frameCount: 50,
                    gainStart: 1,
                    gainEnd: 1
                ),
                AudioTimelineSegment(
                    sourceStartFrame: -1,
                    frameCount: 15,
                    gainStart: 1,
                    gainEnd: 1
                ),
            ]
        )

        XCTAssertEqual(arrangement.segments.count, 1)
        XCTAssertEqual(arrangement.segments[0].sourceStartFrame, 90)
        XCTAssertEqual(arrangement.segments[0].frameCount, 10)
        XCTAssertEqual(arrangement.frameCount, 10)
    }
}
