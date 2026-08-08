import XCTest
@testable import SoundtimeEditing

final class AudioTimelineClipNamingTests: XCTestCase {
    func testUnnumberedNameNumbersBothSplitClips() {
        XCTAssertEqual(
            AudioTimelineClipSplitNames.derived(from: "Interview"),
            AudioTimelineClipSplitNames(left: "Interview 1", right: "Interview 2")
        )
    }

    func testNumberedNameKeepsLeftAndIncrementsRight() {
        XCTAssertEqual(
            AudioTimelineClipSplitNames.derived(from: "Interview 2"),
            AudioTimelineClipSplitNames(left: "Interview 2", right: "Interview 3")
        )
    }

    func testAttachedNumberIsRecognizedAsTrailingSuffix() {
        XCTAssertEqual(
            AudioTimelineClipSplitNames.derived(from: "Take7"),
            AudioTimelineClipSplitNames(left: "Take7", right: "Take8")
        )
    }

    func testIncrementPreservesExistingZeroPadding() {
        XCTAssertEqual(
            AudioTimelineClipSplitNames.derived(from: "Take 009"),
            AudioTimelineClipSplitNames(left: "Take 009", right: "Take 010")
        )
    }

    func testIncrementCarriesBeyondExistingSuffixWidth() {
        XCTAssertEqual(
            AudioTimelineClipSplitNames.derived(from: "Take 99"),
            AudioTimelineClipSplitNames(left: "Take 99", right: "Take 100")
        )
    }
}
