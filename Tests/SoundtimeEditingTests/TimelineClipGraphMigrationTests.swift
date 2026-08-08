import Foundation
import Testing

@testable import SoundtimeEditing

struct TimelineClipGraphMigrationTests {
    @Test
    func legacyMixedFixtureMigratesDeterministicallyWithImplicitGap() throws {
        let url = try #require(Bundle.module.url(
            forResource: "st-clip-contract-001-legacy-mixed",
            withExtension: "json"
        ))
        let data = try Data(contentsOf: url)
        let legacy = try JSONDecoder().decode(LegacyTimelineClipGraphProject.self, from: data)

        let first = try TimelineClipGraphLegacyMigrator.migrate(legacy)
        let second = try TimelineClipGraphLegacyMigrator.migrate(legacy)
        #expect(first == second)
        #expect(first.graph.tracks.count == 2)
        #expect(first.graph.sources.count == 2)

        let dialogue = try #require(first.graph.tracks.first)
        #expect(dialogue.clips.count == 2)
        #expect(dialogue.clips[0].id.rawValue.uuidString == "20000000-0000-0000-0000-000000000001")
        #expect(dialogue.clips[1].timelineRange.startFrame == 144_000)
        #expect(dialogue.implicitGaps(within: TimelineFrameRange(startFrame: 0, frameCount: 288_000)) == [
            TimelineFrameRange(startFrame: 96_000, frameCount: 48_000),
        ])

        let encoded = try JSONEncoder().encode(first)
        let decoded = try JSONDecoder().decode(TimelineClipGraphDocument.self, from: encoded)
        #expect(decoded == first)
    }
}
