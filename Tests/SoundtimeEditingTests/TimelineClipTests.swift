import Testing

@testable import SoundtimeEditing

struct TimelineClipTests {
    @Test
    func clipCrossfadeEdgesAreDisabledByDefaultAndEnabledByDuration() {
        let defaults = TimelineClipFades()
        #expect(defaults.isFadeInEnabled == false)
        #expect(defaults.isFadeOutEnabled == false)

        let enabled = TimelineClipFades(fadeInFrames: 120, fadeOutFrames: 240)
        #expect(enabled.isFadeInEnabled)
        #expect(enabled.isFadeOutEnabled)
    }

    @Test
    func mediaSourceValidationRejectsInvalidFormatFacts() {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "invalid"),
            frameCount: -1,
            sampleRate: 0,
            channelCount: 0
        )
        #expect(throws: TimelineClipGraphError.invalidSource(source.id)) {
            try source.validate()
        }
    }

    @Test
    func clipKeepsTimelineAndSourceTimeIndependent() throws {
        let sourceID = TimelineMediaSourceID(rawValue: "voice-a")
        let source = TimelineMediaSource(
            id: sourceID,
            frameCount: 96_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let clip = TimelineClip(
            sourceID: sourceID,
            timelineRange: TimelineFrameRange(startFrame: 240_000, frameCount: 48_000),
            sourceRange: TimelineFrameRange(startFrame: 12_000, frameCount: 24_000),
            name: "Answer",
            gain: 0.8,
            fades: TimelineClipFades(fadeInFrames: 240, fadeOutFrames: 480)
        )

        try clip.validate(against: source)
        #expect(clip.timelineRange.startFrame == 240_000)
        #expect(clip.sourceRange.startFrame == 12_000)
        #expect(clip.sourceFrameScale == 0.5)
    }

    @Test
    func clipValidationRejectsInvalidRangesAndFades() {
        let sourceID = TimelineMediaSourceID(rawValue: "voice-a")
        let source = TimelineMediaSource(
            id: sourceID,
            frameCount: 1_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let clip = TimelineClip(
            sourceID: sourceID,
            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 100),
            sourceRange: TimelineFrameRange(startFrame: 950, frameCount: 100),
            name: "Invalid",
            fades: TimelineClipFades(fadeInFrames: 75, fadeOutFrames: 75)
        )

        #expect(throws: TimelineClipGraphError.self) {
            try clip.validate(against: source)
        }
    }
}
