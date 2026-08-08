import Testing

@testable import SoundtimeEditing

@Suite("Ripple-delete visual projection")
struct TimelineRippleDeletePresentationTests {
    @Test("Geometry before the deleted range remains fixed")
    func geometryBeforeRangeRemainsFixed() {
        let projected = TimelineRippleDeletePresentation.project(
            0.15,
            deleting: 0.20...0.40,
            progress: 1
        )

        #expect(projected == 0.15)
    }

    @Test("A clip entirely after the deleted range translates as one object")
    func rightHandClipTranslatesWithoutResizing() {
        let projected = TimelineRippleDeletePresentation.project(
            0.60...0.80,
            deleting: 0.20...0.40,
            progress: 0.5
        )

        #expect(abs(projected.lowerBound - 0.50) < 0.000_001)
        #expect(abs(projected.upperBound - 0.70) < 0.000_001)
        #expect(abs((projected.upperBound - projected.lowerBound) - 0.20) < 0.000_001)
    }

    @Test("A clip spanning the edit contracts at its trailing edge")
    func spanningClipContracts() {
        let projected = TimelineRippleDeletePresentation.project(
            0.10...0.70,
            deleting: 0.20...0.40,
            progress: 1
        )

        #expect(abs(projected.lowerBound - 0.10) < 0.000_001)
        #expect(abs(projected.upperBound - 0.50) < 0.000_001)
    }

    @Test("Geometry consumed by the deletion collapses at the left boundary")
    func consumedGeometryCollapsesAtBoundary() {
        let projected = TimelineRippleDeletePresentation.project(
            0.25...0.35,
            deleting: 0.20...0.40,
            progress: 1
        )

        #expect(projected.lowerBound == 0.20)
        #expect(projected.upperBound == 0.20)
    }

    @Test("The presentation easing preserves endpoints and remains monotonic")
    func easingContract() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.05).map {
            TimelineRippleDeletePresentation.easedProgress($0)
        }

        #expect(samples.first == 0)
        #expect(samples.last == 1)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
    }
}
