import XCTest
@testable import SoundtimeEditing

final class TimelineClipCommandAvailabilityTests: XCTestCase {
    func testSelectionCommandsRequireSelectionAndCrossfadeRequiresTwoClips() {
        let empty = TimelineClipCommandContext(totalClipCount: 3, hasActiveTrack: true)
        XCTAssertFalse(empty.isEnabled(.openInspector))
        XCTAssertFalse(empty.isEnabled(.duplicate))
        XCTAssertFalse(empty.isEnabled(.crossfade))
        XCTAssertTrue(empty.isEnabled(.selectPreviousOrNext))

        let one = TimelineClipCommandContext(selectedClipCount: 1, totalClipCount: 3)
        XCTAssertTrue(one.isEnabled(.openInspector))
        XCTAssertTrue(one.isEnabled(.duplicate))
        XCTAssertFalse(one.isEnabled(.crossfade))

        let two = TimelineClipCommandContext(selectedClipCount: 2, totalClipCount: 3)
        XCTAssertFalse(two.isEnabled(.openInspector))
        XCTAssertTrue(two.isEnabled(.crossfade))
    }

    func testCrossTrackCommandsUseExplicitBoundaryKnowledge() {
        let context = TimelineClipCommandContext(
            selectedClipCount: 2,
            totalClipCount: 4,
            canMoveSelectionToTrackAbove: false,
            canMoveSelectionToTrackBelow: true
        )
        XCTAssertFalse(context.isEnabled(.moveToTrackAbove))
        XCTAssertTrue(context.isEnabled(.moveToTrackBelow))
    }

    func testRelinkIsDisabledWhileWorkflowIsActive() {
        XCTAssertTrue(TimelineClipCommandContext(hasMissingMedia: true).isEnabled(.relinkMissingMedia))
        XCTAssertFalse(TimelineClipCommandContext(hasMissingMedia: true).isEnabled(.cancelMediaRelink))
        XCTAssertFalse(TimelineClipCommandContext(
            hasMissingMedia: true,
            isRelinkingMedia: true
        ).isEnabled(.relinkMissingMedia))
        XCTAssertTrue(TimelineClipCommandContext(
            hasMissingMedia: true,
            isRelinkingMedia: true
        ).isEnabled(.cancelMediaRelink))
    }

    func testTimeRangeSelectionCommandRequiresBothRangeAndContent() {
        XCTAssertFalse(TimelineClipCommandContext(
            totalClipCount: 2,
            hasTimeSelection: false
        ).isEnabled(.selectInTimeRange))
        XCTAssertTrue(TimelineClipCommandContext(
            totalClipCount: 2,
            hasTimeSelection: true
        ).isEnabled(.selectInTimeRange))
    }
}
