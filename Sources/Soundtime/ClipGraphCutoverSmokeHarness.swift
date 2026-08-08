import Foundation
import SoundtimeEditing

enum ClipGraphCutoverSmokeHarness {
    private struct SmokeFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func runFromCommandLine(arguments: [String]) throws {
        let graph = try makeMixedSourceGraph()
        let snapshot = try TimelineClipPlaybackProjection.snapshot(from: graph)
        let info: (URL) -> WAVFileInfo? = { url in
            syntheticFileInfo(url: url, frameCount: url.lastPathComponent == "voice.wav" ? 96_000 : 192_000)
        }

        let playbackTracks = try ProjectPlaybackProjection.tracks(
            from: snapshot,
            fileInfo: info,
            zeroCrossingProbe: { _, _ in nil }
        )
        let exportTracks = try ProjectClipGraphAudioExportProjection.tracks(
            from: snapshot,
            includedTrackIDs: nil,
            fileInfo: info
        )
        try require(playbackTracks.count == 2, "mixed-source playback did not publish one lane per source")
        try require(exportTracks.count == 2, "mixed-source export did not publish one lane per source")
        try require(playbackTracks.allSatisfy { UInt64($0.sourceRevision) == snapshot.graphRevision }, "playback lost the graph revision")
        try require(playbackTracks.map(\.logicalTrackID) == exportTracks.map(\.logicalTrackID), "playback/export logical track identity diverged")
        let playbackTimelineSampleRates = try playbackTracks.map(timelineSampleRate(from:))
        try require(
            playbackTimelineSampleRates.allSatisfy { $0 == snapshot.timelineSampleRate },
            "playback lanes mislabeled project-time clip frames with a media source sample rate"
        )

        let playbackSegments = try playbackTracks.map(segments(from:))
        let exportSegments = try exportTracks.map(segments(from:))
        try require(playbackSegments == exportSegments, "playback/export segment geometry diverged")
        try require(
            playbackSegments.flatMap { $0 }.map(\.outputStartFrame).sorted() == [0, 72_000],
            "implicit mixed-source gap was materialized or collapsed"
        )

        let document = try TimelineClipGraphDocument(graph: graph)
        let persisted = try JSONDecoder().decode(
            TimelineClipGraphDocument.self,
            from: JSONEncoder().encode(document)
        )
        try require(persisted.graph == graph, "save/reopen changed canonical graph values")
        try require(
            persisted.graph.tracks.flatMap(\.clips).map(\.id) == graph.tracks.flatMap(\.clips).map(\.id),
            "save/reopen changed clip identities"
        )

        do {
            _ = try ProjectPlaybackProjection.tracks(
                from: snapshot,
                fileInfo: { _ in nil },
                zeroCrossingProbe: { _, _ in nil }
            )
            throw SmokeFailure(message: "missing media was silently omitted from playback")
        } catch is ProjectClipGraphProjectionError {
            // Expected: a canonical lane may not disappear silently.
        }
        do {
            _ = try ProjectClipGraphAudioExportProjection.tracks(
                from: snapshot,
                includedTrackIDs: nil,
                fileInfo: { _ in nil }
            )
            throw SmokeFailure(message: "missing media was silently omitted from export")
        } catch is ProjectClipGraphProjectionError {
            // Expected.
        }

        try runCanonicalInsertionAndCollisionChecks()
        try runTrackLocalRenderProgressChecks()
        try runMediaResolutionChecks()
        try runProductionClipWorkflowChecks()
        try runThousandClipEditUndoWorkload(arguments: arguments)
        print("PASS clip graph cutover: mixed-source playback/export parity")
        print("PASS clip graph cutover: stable graph persistence and missing-media failure")
        print("PASS clip graph cutover: canonical mixed-source insertion and collision rejection")
        print("PASS clip graph cutover: asymmetric track waveform geometry remains project-time accurate")
        print("PASS clip graph cutover: stable media identity and deterministic missing-media resolution")
        print("PASS clip graph cutover: production clip workflows and take-lane persistence")
        print("PASS clip graph cutover: 1,000 clips with repeated typed edit/undo")
    }

    private static func runTrackLocalRenderProgressChecks() throws {
        let sampleRate = 48_000
        let shortTrackEndFrame = 7_203_387
        let projectEndFrame = 356_969_047
        let clipStartFrame = 28_035
        let clipEndFrame = clipStartFrame + shortTrackEndFrame
        let trackEndFrame = clipEndFrame

        let localStart = TimelineRenderTrackProgress.normalized(
            frame: clipStartFrame,
            trackEndFrame: trackEndFrame
        )
        let localEnd = TimelineRenderTrackProgress.normalized(
            frame: clipEndFrame,
            trackEndFrame: trackEndFrame
        )
        let renderedStart = TimelineRenderTrackProgress.projectProgress(
            trackProgress: localStart,
            trackEndFrame: trackEndFrame,
            projectEndFrame: projectEndFrame
        )
        let renderedEnd = TimelineRenderTrackProgress.projectProgress(
            trackProgress: localEnd,
            trackEndFrame: trackEndFrame,
            projectEndFrame: projectEndFrame
        )
        let renderedDurationFrames = Int(
            ((renderedEnd - renderedStart) * Double(projectEndFrame)).rounded()
        )

        try require(
            abs(renderedDurationFrames - shortTrackEndFrame) <= 1,
            "track-local waveform geometry was scaled by the project ratio more than once"
        )
        try require(
            abs(Double(renderedDurationFrames) / Double(sampleRate) - 150.070_562_5) < 0.000_1,
            "150-second imported clip did not retain its visible duration beside a multi-hour track"
        )
    }

    @MainActor
    private static func runProductionClipWorkflowChecks() throws {
        var graph = try makeMixedSourceGraph()
        let sourceTrack = graph.tracks[0]
        let destinationTrackID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let destination = TimelineTrack(id: destinationTrackID, name: "Destination")
        try graph.replaceTrack(destination)

        let clip = sourceTrack.clips[0]
        let move = TimelineClipMove(clipID: clip.id, destinationTrackID: destinationTrackID, destinationStartFrame: 100_000)
        let moveResult = try TimelineClipCommandExecutor.apply(.move([move]), to: graph, expectedRevision: graph.revision)
        try require(
            moveResult.graph.track(id: destinationTrackID)?.clip(id: clip.id)?.timelineRange.startFrame == 100_000,
            "cross-track move did not preserve clip identity"
        )

        let session = ProjectSession()
        try session.installClipGraph(graph)
        let selection = TimelineClipSelectionSnapshot(selectedClips: [
            TimelineClipSelectionSnapshot.SelectedClip(trackID: sourceTrack.id, clipID: clip.id),
        ])
        let transport = TimelineTransportSnapshot(playheadFrame: 12_000, isPlaying: false)
        _ = try session.executeClipCommand(
            .move([move]),
            label: "Cross-track lifecycle move",
            beforeSelection: selection,
            afterSelection: TimelineClipSelectionSnapshot(selectedClips: [
                TimelineClipSelectionSnapshot.SelectedClip(trackID: destinationTrackID, clipID: clip.id),
            ]),
            beforeTransport: transport,
            afterTransport: transport
        )
        let sessionMovedClip = session.clipGraph.track(id: destinationTrackID)?.clip(id: clip.id)
        try require(sessionMovedClip != nil, "session move did not reach destination")
        _ = try session.undoClipCommand()
        let sessionUndoneClip = session.clipGraph.track(id: sourceTrack.id)?.clip(id: clip.id)
        try require(sessionUndoneClip != nil, "cross-track undo lost the source clip")
        _ = try session.redoClipCommand()
        let sessionRedoneClip = session.clipGraph.track(id: destinationTrackID)?.clip(id: clip.id)
        try require(sessionRedoneClip != nil, "cross-track redo lost the destination clip")

        let sessionGraph = session.clipGraph
        let reopened = try JSONDecoder().decode(
            TimelineClipGraphDocument.self,
            from: JSONEncoder().encode(TimelineClipGraphDocument(graph: sessionGraph))
        ).graph
        try require(reopened == sessionGraph, "cross-track save/reopen changed the graph")
        let reopenedSnapshot = try TimelineClipPlaybackProjection.snapshot(from: reopened)
        let reopenedPlayback = try ProjectPlaybackProjection.tracks(
            from: reopenedSnapshot,
            fileInfo: { url in syntheticFileInfo(url: url, frameCount: url.lastPathComponent == "voice.wav" ? 96_000 : 192_000) },
            zeroCrossingProbe: { _, _ in nil }
        )
        let reopenedExport = try ProjectClipGraphAudioExportProjection.tracks(
            from: reopenedSnapshot,
            includedTrackIDs: nil,
            fileInfo: { url in syntheticFileInfo(url: url, frameCount: url.lastPathComponent == "voice.wav" ? 96_000 : 192_000) }
        )
        let playbackSegments = try reopenedPlayback.map(segments(from:))
        let exportSegments = try reopenedExport.map(segments(from:))
        try require(playbackSegments == exportSegments, "cross-track lifecycle playback/export parity diverged after reopen")

        let snap = TimelineClipSnapEngine.snap(
            frame: 99_996,
            targets: [TimelineClipSnapTarget(frame: 100_000, kind: .clipEdge)],
            configuration: TimelineClipSnapConfiguration(toleranceFrames: 8)
        )
        try require(snap.frame == 100_000, "clip snapping did not choose the nearby edge")

        let clipboard = try TimelineClipObjectClipboardService.capture(
            [TimelineClipReference(trackID: destinationTrackID, clipID: clip.id)],
            in: moveResult.graph
        )
        let insertions = try TimelineClipObjectClipboardService.insertionRequests(
            for: clipboard,
            anchorTrackID: destinationTrackID,
            timelineStartFrame: 0,
            in: moveResult.graph
        )
        try require(insertions.count == 1 && insertions[0].clipID != clip.id, "clip clipboard did not mint a new identity")

        let lane = TimelineTakeLane(name: "Take 1", clipIDs: [clip.id], isActive: true)
        let comp = TimelineCompSection(
            laneID: lane.id,
            timelineRange: TimelineFrameRange(startFrame: 100_000, frameCount: 24_000)
        )
        let encoded = try JSONEncoder().encode([lane])
        let decodedLanes = try JSONDecoder().decode([TimelineTakeLane].self, from: encoded)
        try require(decodedLanes == [lane], "take lanes did not persist")
        try require(comp.timelineRange.frameCount == 24_000, "comp section lost its timeline range")
    }

    @MainActor
    private static func runMediaResolutionChecks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundtime-media-resolution-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectURL = root.appendingPathComponent("Session.soundtime")
        let relativeURL = root.appendingPathComponent("Audio/voice.wav")
        try FileManager.default.createDirectory(
            at: relativeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0]).write(to: relativeURL)

        let sourceID = TimelineMediaSourceID(rawValue: "stable-media-id")
        let source = TimelineMediaSource(
            id: sourceID,
            relativePath: "Audio/voice.wav",
            absolutePath: "/missing/old-location.wav",
            fingerprint: "stable-fingerprint",
            frameCount: 48_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let relative = TimelineMediaSourceResolver.resolve(source, projectURL: projectURL)
        try require(relative.status == .resolvedRelative, "existing project-relative media did not win resolution")
        try require(relative.source.id == sourceID, "media resolution changed canonical source identity")
        try require(relative.source.fingerprint == source.fingerprint, "media resolution changed source fingerprint")
        try require(relative.source.absolutePath == relativeURL.path, "relative media resolved to the wrong path")

        try FileManager.default.removeItem(at: relativeURL)
        let missing = TimelineMediaSourceResolver.resolve(relative.source, projectURL: projectURL)
        try require(missing.status == .missing, "missing media was reported as resolved")
        try require(missing.source.id == sourceID, "missing media changed canonical identity")
        try require(missing.source.metadata["missingMedia"] == "true", "missing media was not surfaced to the UI layer")

        let trackID = UUID(uuidString: "40000000-0000-0000-0000-000000000090")!
        let clipID = AudioTimelineClipID(
            rawValue: UUID(uuidString: "40000000-0000-0000-0000-000000000091")!
        )
        let clip = TimelineClip(
            id: clipID,
            sourceID: sourceID,
            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 24_000),
            sourceRange: TimelineFrameRange(startFrame: 12_000, frameCount: 24_000),
            name: "Missing voice"
        )
        let graph = try TimelineClipGraph(
            sources: [missing.source],
            tracks: [TimelineTrack(id: trackID, name: "Voice", clips: [clip])],
            timelineSampleRate: 48_000
        )
        let session = ProjectSession()
        try session.installClipGraph(graph)
        let selection = TimelineClipSelectionSnapshot(selectedClips: [
            .init(trackID: trackID, clipID: clipID),
        ])
        let transport = TimelineTransportSnapshot(playheadFrame: 10_000, isPlaying: false)
        _ = try session.relinkMediaSource(
            sourceID: sourceID,
            candidate: TimelineMediaRelinkCandidate(
                resolvedAbsolutePath: relativeURL.path,
                relativePath: "Audio/voice.wav",
                acceptedFingerprints: ["stable-fingerprint"],
                frameCount: 48_000,
                sampleRate: 48_000,
                channelCount: 1
            ),
            beforeSelection: selection,
            afterSelection: selection,
            beforeTransport: transport,
            afterTransport: transport
        )
        let relinked = try requireValue(
            session.clipGraph.source(id: sourceID),
            "relink removed the canonical media source"
        )
        try require(relinked.id == sourceID, "relink changed canonical source identity")
        try require(relinked.absolutePath == relativeURL.path, "relink stored the wrong replacement path")
        try require(relinked.metadata["missingMedia"] == nil, "relink left the source marked missing")
        let relinkedClipSourceID = session.clipGraph.track(id: trackID)?.clip(id: clipID)?.sourceID
        try require(
            relinkedClipSourceID == sourceID,
            "relink changed clip identity or source ownership"
        )
        let undone = try requireValue(session.undoClipCommand(), "relink did not create typed undo")
        try require(
            undone.graph.source(id: sourceID)?.metadata["missingMedia"] == "true",
            "undo did not restore the missing-media source state"
        )
        let redone = try requireValue(session.redoClipCommand(), "relink typed redo was unavailable")
        try require(
            redone.graph.source(id: sourceID)?.absolutePath == relativeURL.path,
            "redo did not restore the replacement media path"
        )
    }

    @MainActor
    private static func runCanonicalInsertionAndCollisionChecks() throws {
        let trackID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let firstSource = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "insert-a"),
            absolutePath: "/tmp/soundtime-clip-cutover/insert-a.wav",
            frameCount: 48_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let secondSource = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "insert-b"),
            absolutePath: "/tmp/soundtime-clip-cutover/insert-b.wav",
            frameCount: 48_000,
            sampleRate: 48_000,
            channelCount: 2
        )
        let original = try TimelineClipGraph(
            tracks: [TimelineTrack(id: trackID, name: "Insert")],
            timelineSampleRate: 48_000,
            explicitEndFrame: 144_000
        )
        let first = try TimelineMediaInsertionService.insert(
            TimelineMediaInsertionRequest(
                trackID: trackID,
                source: firstSource,
                timelineStartFrame: 0,
                clipName: "First"
            ),
            into: original,
            expectedRevision: original.revision
        ).graph
        let second = try TimelineMediaInsertionService.insert(
            TimelineMediaInsertionRequest(
                trackID: trackID,
                source: secondSource,
                timelineStartFrame: 96_000,
                clipName: "Second"
            ),
            into: first,
            expectedRevision: first.revision
        ).graph
        try require(second.sources.count == 2, "mixed-source insertion lost a media source")
        try require(second.track(id: trackID)?.clips.count == 2, "mixed-source insertion did not create two clips")
        do {
            _ = try TimelineMediaInsertionService.insert(
                TimelineMediaInsertionRequest(
                    trackID: trackID,
                    source: secondSource,
                    timelineStartFrame: 24_000,
                    clipName: "Collision"
                ),
                into: second,
                expectedRevision: second.revision
            )
            throw SmokeFailure(message: "overlapping insertion was accepted")
        } catch let error as TimelineClipGraphError {
            guard case .destinationOccupied = error else { throw error }
        }
        try require(second.explicitEndFrame == 144_000, "shorter media insertion changed the explicit timeline end")

        let session = ProjectSession()
        try session.installClipGraph(original)
        let selection = TimelineClipSelectionSnapshot()
        let transport = TimelineTransportSnapshot(playheadFrame: 0, isPlaying: false)
        _ = try session.insertMedia(
            TimelineMediaInsertionRequest(
                trackID: trackID,
                source: secondSource,
                timelineStartFrame: 192_000,
                clipName: "Longer than timeline"
            ),
            label: "Insert longer media",
            beforeSelection: selection,
            afterSelection: selection,
            beforeTransport: transport,
            afterTransport: transport
        )
        try require(
            session.clipGraph.explicitEndFrame == 240_000 && session.timelineEndTime == 5,
            "longer media insertion did not extend the project session timeline end"
        )
    }

    private static func makeMixedSourceGraph() throws -> TimelineClipGraph {
        let sourceA = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "voice"),
            absolutePath: "/tmp/soundtime-clip-cutover/voice.wav",
            frameCount: 96_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let sourceB = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "music"),
            absolutePath: "/tmp/soundtime-clip-cutover/music.wav",
            frameCount: 192_000,
            sampleRate: 96_000,
            channelCount: 2
        )
        let trackID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let clips = [
            TimelineClip(
                id: AudioTimelineClipID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!),
                sourceID: sourceA.id,
                timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 48_000),
                sourceRange: TimelineFrameRange(startFrame: 24_000, frameCount: 48_000),
                name: "Voice"
            ),
            TimelineClip(
                id: AudioTimelineClipID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!),
                sourceID: sourceB.id,
                timelineRange: TimelineFrameRange(startFrame: 72_000, frameCount: 24_000),
                sourceRange: TimelineFrameRange(startFrame: 96_000, frameCount: 48_000),
                name: "Music"
            ),
        ]
        return try TimelineClipGraph(
            sources: [sourceA, sourceB],
            tracks: [TimelineTrack(id: trackID, name: "Mixed", clips: clips)],
            revision: 41,
            timelineSampleRate: 48_000,
            explicitEndFrame: 120_000
        )
    }

    @MainActor
    private static func runThousandClipEditUndoWorkload(arguments: [String]) throws {
        let source = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "stress"),
            absolutePath: "/tmp/soundtime-clip-cutover/stress.wav",
            frameCount: 20_000,
            sampleRate: 48_000,
            channelCount: 1
        )
        let trackID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let clips = (0..<1_000).map { index in
            TimelineClip(
                sourceID: source.id,
                timelineRange: TimelineFrameRange(startFrame: index * 20, frameCount: 10),
                sourceRange: TimelineFrameRange(startFrame: index * 10, frameCount: 10),
                name: "Clip \(index + 1)"
            )
        }
        let original = try TimelineClipGraph(
            sources: [source],
            tracks: [TimelineTrack(id: trackID, name: "Stress", clips: clips)],
            timelineSampleRate: 48_000
        )
        let session = ProjectSession()
        try session.installClipGraph(original)
        let selection = TimelineClipSelectionSnapshot()
        let transport = TimelineTransportSnapshot(playheadFrame: 0, isPlaying: false)
        let targetID = clips[500].id

        let iterationCount = arguments.contains("--full") ? 5_000 : (arguments.contains("--quick") ? 200 : 1_000)
        var operationDurations: [Double] = []
        operationDurations.reserveCapacity(iterationCount)
        for iteration in 0..<iterationCount {
            let started = DispatchTime.now().uptimeNanoseconds
            let destination = clips[500].timelineRange.startFrame + (iteration.isMultiple(of: 2) ? 4 : 2)
            _ = try session.executeClipCommand(
                .move([TimelineClipMove(
                    clipID: targetID,
                    destinationTrackID: trackID,
                    destinationStartFrame: destination
                )]),
                label: "Stress move",
                beforeSelection: selection,
                afterSelection: selection,
                beforeTransport: transport,
                afterTransport: transport
            )
            _ = try session.undoClipCommand()
            operationDurations.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        try require(session.clipGraph.tracks.first?.clips == clips, "repeated edit/undo did not restore all 1,000 clips")
        try require(session.leasedClipSourceIDs == [source.id], "undo history did not retain the referenced media source")
        let sortedDurations = operationDurations.sorted()
        let p95Index = min(max(Int(Double(sortedDurations.count - 1) * 0.95), 0), sortedDurations.count - 1)
        let p95 = sortedDurations[p95Index]
        try require(p95 <= 12, String(format: "1,000-clip edit/undo p95 %.3fms exceeded 12ms", p95))
    }

    private static func segments(from track: ProjectPlaybackTrack) throws -> [AudioTimelinePlaybackSegment] {
        guard case let .fileSegments(_, _, _, _, segments, _) = track.source else {
            throw SmokeFailure(message: "playback projection did not use canonical file segments")
        }
        return segments
    }

    private static func timelineSampleRate(from track: ProjectPlaybackTrack) throws -> Double {
        guard case let .fileSegments(_, _, _, timelineSampleRate, _, _) = track.source else {
            throw SmokeFailure(message: "playback projection did not retain timeline sample rate")
        }
        return timelineSampleRate
    }

    private static func segments(from track: AudioExportTrackSnapshot) throws -> [AudioTimelinePlaybackSegment] {
        guard case let .fileSegments(_, _, segments) = track.source else {
            throw SmokeFailure(message: "export projection did not use canonical file segments")
        }
        return segments
    }

    private static func syntheticFileInfo(url: URL, frameCount: Int) -> WAVFileInfo {
        WAVFileInfo(
            url: url,
            formatTag: 1,
            channelCount: 2,
            sampleRate: 48_000,
            blockAlign: 4,
            bitsPerSample: 16,
            dataRange: 44..<(44 + frameCount * 4)
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SmokeFailure(message: message) }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SmokeFailure(message: message) }
        return value
    }
}
