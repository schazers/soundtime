import Foundation
import Testing

@testable import SoundtimeEditing

struct ClipBehaviorContractTests {
    @Test
    func goldenLegacyFixtureIsStableAndMixed() throws {
        let url = try #require(Bundle.module.url(
            forResource: "st-clip-contract-001-legacy-mixed",
            withExtension: "json"
        ))
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(LegacyFixture.self, from: data)

        #expect(fixture.fixtureVersion == 1)
        #expect(fixture.timelineSampleRate == 48_000)
        #expect(fixture.tracks.count == 2)
        #expect(Set(fixture.tracks.map(\.source.id)).count == 2)
        #expect(fixture.tracks.flatMap(\.segments).contains { segment in
            segment.gainStart == 0 && segment.gainEnd == 0
        })
    }
}

private struct LegacyFixture: Decodable {
    struct Source: Decodable {
        let id: String
    }

    struct Segment: Decodable {
        let gainStart: Float
        let gainEnd: Float
    }

    struct Track: Decodable {
        let source: Source
        let segments: [Segment]
    }

    let fixtureVersion: Int
    let timelineSampleRate: Double
    let tracks: [Track]
}
