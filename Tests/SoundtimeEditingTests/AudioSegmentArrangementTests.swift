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
