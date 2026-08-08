import XCTest
@testable import SoundtimeEditing

final class TimelineMediaRelinkingTests: XCTestCase {
    func testRelinkPreservesIdentityAndClearsMissingState() throws {
        let fixture = try makeFixture(fingerprint: "original")
        let plan = try TimelineMediaRelinkPlanner.plan(
            sourceID: fixture.sourceID,
            candidate: TimelineMediaRelinkCandidate(
                resolvedAbsolutePath: "/new/voice.wav",
                relativePath: "Media/voice.wav",
                acceptedFingerprints: ["original", "alternate"],
                frameCount: 10_000,
                sampleRate: 48_000,
                channelCount: 1,
                metadata: ["locatedByUser": "true"]
            ),
            in: fixture.graph
        )

        XCTAssertEqual(plan.sourceAfter.id, fixture.sourceID)
        XCTAssertEqual(plan.sourceAfter.absolutePath, "/new/voice.wav")
        XCTAssertEqual(plan.sourceAfter.relativePath, "Media/voice.wav")
        XCTAssertNil(plan.sourceAfter.metadata["missingMedia"])
        XCTAssertEqual(plan.sourceAfter.metadata["mediaResolution"], "relinked")
        XCTAssertEqual(plan.affectedTrackIDs, [fixture.trackID])
        XCTAssertEqual(plan.affectedClipIDs, [fixture.clipID])
    }

    func testKnownFingerprintRejectsWrongFileEvenWhenShapeMatches() throws {
        let fixture = try makeFixture(fingerprint: "expected")
        XCTAssertThrowsError(try TimelineMediaRelinkPlanner.plan(
            sourceID: fixture.sourceID,
            candidate: TimelineMediaRelinkCandidate(
                resolvedAbsolutePath: "/wrong/voice.wav",
                acceptedFingerprints: ["different"],
                frameCount: 10_000,
                sampleRate: 48_000,
                channelCount: 1
            ),
            in: fixture.graph
        )) { error in
            XCTAssertEqual(
                error as? TimelineMediaRelinkError,
                .fingerprintMismatch(expected: "expected")
            )
        }
    }

    func testLegacySourceUsesConservativeStructuralMatch() throws {
        let fixture = try makeFixture(fingerprint: nil)
        XCTAssertThrowsError(try TimelineMediaRelinkPlanner.plan(
            sourceID: fixture.sourceID,
            candidate: TimelineMediaRelinkCandidate(
                resolvedAbsolutePath: "/new/voice.wav",
                frameCount: 10_000,
                sampleRate: 44_100,
                channelCount: 1
            ),
            in: fixture.graph
        )) { error in
            XCTAssertEqual(
                error as? TimelineMediaRelinkError,
                .incompatibleAudioFormat(
                    expectedSampleRate: 48_000,
                    actualSampleRate: 44_100,
                    expectedChannelCount: 1,
                    actualChannelCount: 1
                )
            )
        }
    }

    func testCandidateMustCoverEveryReferencedSourceRange() throws {
        let fixture = try makeFixture(fingerprint: nil)
        XCTAssertThrowsError(try TimelineMediaRelinkPlanner.plan(
            sourceID: fixture.sourceID,
            candidate: TimelineMediaRelinkCandidate(
                resolvedAbsolutePath: "/short/voice.wav",
                frameCount: 5_999,
                sampleRate: 48_000,
                channelCount: 1
            ),
            in: fixture.graph
        )) { error in
            XCTAssertEqual(
                error as? TimelineMediaRelinkError,
                .candidateTooShort(requiredFrameCount: 6_000, actualFrameCount: 5_999)
            )
        }
    }

    func testRelinkSourceChangeRoundTripsThroughTypedUndo() throws {
        let fixture = try makeFixture(fingerprint: "expected")
        let plan = try TimelineMediaRelinkPlanner.plan(
            sourceID: fixture.sourceID,
            candidate: TimelineMediaRelinkCandidate(
                resolvedAbsolutePath: "/new/voice.wav",
                acceptedFingerprints: ["expected"],
                frameCount: 10_000,
                sampleRate: 48_000,
                channelCount: 1
            ),
            in: fixture.graph
        )
        var relinked = fixture.graph
        relinked.upsertSource(plan.sourceAfter)
        relinked.setRevision(fixture.graph.revision + 1)
        let result = TimelineClipCommandResult(
            graph: relinked,
            affectedTrackIDs: plan.affectedTrackIDs,
            beforeTracks: fixture.graph.tracks,
            afterTracks: relinked.tracks,
            affectedClipIDs: plan.affectedClipIDs,
            sourceChanges: [.init(
                id: fixture.sourceID,
                before: plan.sourceBefore,
                after: plan.sourceAfter
            )],
            beforeExplicitEndFrame: fixture.graph.explicitEndFrame,
            afterExplicitEndFrame: relinked.explicitEndFrame
        )
        var history = TimelineClipUndoHistory()
        history.record(TimelineClipUndoTransaction(
            label: "Relink Media",
            commandResult: result,
            beforeSelection: .init(),
            afterSelection: .init(),
            beforeTransport: .init(playheadFrame: 0, isPlaying: false),
            afterTransport: .init(playheadFrame: 0, isPlaying: false)
        ))

        let undone = try XCTUnwrap(history.undo(graph: relinked))
        XCTAssertEqual(
            undone.graph.source(id: fixture.sourceID)?.absolutePath,
            "/missing/voice.wav"
        )
        let redone = try XCTUnwrap(history.redo(graph: undone.graph))
        XCTAssertEqual(
            redone.graph.source(id: fixture.sourceID)?.absolutePath,
            "/new/voice.wav"
        )
    }

    func testContentFingerprintAllowsRelinkWhenLocationFingerprintChanged() throws {
        let contentFingerprint = "stable-content"
        let fixture = try makeFixture(fingerprint: "old-location-cache-key")
        var graph = fixture.graph
        var source = try XCTUnwrap(graph.source(id: fixture.sourceID))
        source.metadata[TimelineMediaRelinkPlanner.contentFingerprintMetadataKey] = contentFingerprint
        graph.upsertSource(source)
        let candidate = TimelineMediaRelinkCandidate(
            resolvedAbsolutePath: "/new/location/voice.wav",
            acceptedFingerprints: ["new-location-cache-key"],
            frameCount: 10_000,
            sampleRate: 48_000,
            channelCount: 1,
            metadata: [TimelineMediaRelinkPlanner.contentFingerprintMetadataKey: contentFingerprint]
        )

        let plan = try TimelineMediaRelinkPlanner.plan(
            sourceID: fixture.sourceID,
            candidate: candidate,
            in: graph
        )

        XCTAssertEqual(plan.sourceAfter.id, fixture.sourceID)
        XCTAssertEqual(plan.sourceAfter.absolutePath, candidate.resolvedAbsolutePath)
    }

    func testContentFingerprintRejectsDifferentMediaAtCompatibleFormat() throws {
        let fixture = try makeFixture(fingerprint: "old-location-cache-key")
        var graph = fixture.graph
        var source = try XCTUnwrap(graph.source(id: fixture.sourceID))
        source.metadata[TimelineMediaRelinkPlanner.contentFingerprintMetadataKey] = "expected-content"
        graph.upsertSource(source)
        let candidate = TimelineMediaRelinkCandidate(
            resolvedAbsolutePath: "/replacement.wav",
            acceptedFingerprints: ["old-location-cache-key"],
            frameCount: 10_000,
            sampleRate: 48_000,
            channelCount: 1,
            metadata: [TimelineMediaRelinkPlanner.contentFingerprintMetadataKey: "different-content"]
        )

        XCTAssertThrowsError(try TimelineMediaRelinkPlanner.plan(
            sourceID: fixture.sourceID,
            candidate: candidate,
            in: graph
        )) { error in
            XCTAssertEqual(
                error as? TimelineMediaRelinkError,
                .fingerprintMismatch(expected: "expected-content")
            )
        }
    }

    private func makeFixture(
        fingerprint: String?
    ) throws -> (
        graph: TimelineClipGraph,
        sourceID: TimelineMediaSourceID,
        trackID: UUID,
        clipID: AudioTimelineClipID
    ) {
        let sourceID = TimelineMediaSourceID(rawValue: "voice-source")
        let trackID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000001")!
        let clipID = AudioTimelineClipID(
            rawValue: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000002")!
        )
        let source = TimelineMediaSource(
            id: sourceID,
            absolutePath: "/missing/voice.wav",
            fingerprint: fingerprint,
            frameCount: 10_000,
            sampleRate: 48_000,
            channelCount: 1,
            metadata: ["missingMedia": "true"]
        )
        let clip = TimelineClip(
            id: clipID,
            sourceID: sourceID,
            timelineRange: TimelineFrameRange(startFrame: 100, frameCount: 5_000),
            sourceRange: TimelineFrameRange(startFrame: 1_000, frameCount: 5_000),
            name: "Voice"
        )
        let graph = try TimelineClipGraph(
            sources: [source],
            tracks: [TimelineTrack(id: trackID, name: "Voice", clips: [clip])],
            timelineSampleRate: 48_000
        )
        return (graph, sourceID, trackID, clipID)
    }
}
