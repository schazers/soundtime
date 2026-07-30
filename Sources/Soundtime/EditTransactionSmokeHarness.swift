import Foundation

enum EditTransactionSmokeHarness {
    private enum SmokeError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                return message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var checks: [String] = []

        try verifyCanonicalProjectTimeMapping()
        checks.append("project-time ranges map deterministically at 44.1, 48, and 96 kHz")

        try verifyAtomicPlannerRejection()
        checks.append("stale, missing, duplicate, and uneditable targets reject atomically")

        try verifyUnequalDurationScopePlanning()
        checks.append("multi-track scope planning intersects unequal track durations")

        try verifyExactMemoryTimelineMutations()
        checks.append("memory timelines delete, clear, copy, and paste exact frame ranges")

        try verifyExactFileTimelineMutations()
        checks.append("file timelines delete, clear, copy, and paste exact frame ranges")

        try verifySourceIdentityProtection()
        checks.append("clip references cannot be pasted into an unrelated source")

        try verifyPublishedMixReconciliationUsesTrackIdentity()
        checks.append("delete publication preserves mute and solo state by stable track identity")

        let cycleCount = arguments.contains("--edit-transaction-smoke-quick") ? 250 : 1_000
        let historyMetrics = try verifyHistoryCycles(cycleCount: cycleCount)
        checks.append("\(cycleCount) delete, cut, paste, undo, and redo cycles remain deterministic")

        let elapsedMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - startedAt
        ) / 1_000_000
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "edit-transaction-smoke",
            startedAtNanoseconds: startedAt,
            checks: checks,
            metadata: [
                "cycleCount": "\(cycleCount)",
                "historyP99Milliseconds": String(
                    format: "%.3f",
                    historyMetrics.p99Milliseconds
                ),
                "historyMaxMilliseconds": String(
                    format: "%.3f",
                    historyMetrics.maximumMilliseconds
                ),
                "elapsedMilliseconds": String(format: "%.3f", elapsedMilliseconds),
                "atomicRejectionFailures": "0",
                "exactFrameMismatchCount": "0",
            ],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }

        print(
            String(
                format: "Soundtime edit transaction smoke passed: %d cycles, %.3fms p99, %.3fms max, %.2fms total",
                cycleCount,
                historyMetrics.p99Milliseconds,
                historyMetrics.maximumMilliseconds,
                elapsedMilliseconds
            )
        )
    }

    private static func verifyCanonicalProjectTimeMapping() throws {
        let range = try requireValue(
            ProjectEditRange(
                start: ProjectTime(seconds: 0.125),
                end: ProjectTime(seconds: 0.875)
            ),
            "canonical project range was empty"
        )
        for sampleRate in [44_100.0, 48_000.0, 96_000.0] {
            let frameRange = try requireValue(
                range.frameRange(
                    sampleRate: sampleRate,
                    frameCount: Int(sampleRate * 2)
                ),
                "canonical project range did not map at \(sampleRate) Hz"
            )
            try require(
                frameRange.lowerBound == Int((0.125 * sampleRate).rounded(.down)),
                "canonical lower frame was wrong at \(sampleRate) Hz"
            )
            try require(
                frameRange.upperBound == Int((0.875 * sampleRate).rounded(.up)),
                "canonical upper frame was wrong at \(sampleRate) Hz"
            )
        }
    }

    private static func verifyAtomicPlannerRejection() throws {
        let firstID = fixedUUID(1)
        let secondID = fixedUUID(2)
        let range = try requireValue(
            ProjectEditRange(
                start: ProjectTime(seconds: 0.1),
                end: ProjectTime(seconds: 0.2)
            ),
            "planner rejection range was empty"
        )
        let tracks = [
            EditTrackDescriptor(
                trackID: firstID,
                sampleRate: 48_000,
                frameCount: 48_000,
                isEditable: true
            ),
            EditTrackDescriptor(
                trackID: secondID,
                sampleRate: 48_000,
                frameCount: 48_000,
                isEditable: false
            ),
        ]

        try expectError(
            .staleRevision(expected: .initial, actual: .initial.advanced())
        ) {
            _ = try EditTransactionPlanner.plan(
                command: EditCommand(
                    baseRevision: .initial,
                    kind: .rippleDelete,
                    scope: .track,
                    anchorTrackID: firstID,
                    targetTrackIDs: [firstID],
                    range: range,
                    wasPlaying: false
                ),
                currentRevision: .initial.advanced(),
                tracks: tracks
            )
        }
        try expectError(.missingTrack(fixedUUID(99))) {
            _ = try EditTransactionPlanner.plan(
                command: EditCommand(
                    baseRevision: .initial,
                    kind: .rippleDelete,
                    scope: .all,
                    anchorTrackID: firstID,
                    targetTrackIDs: [firstID, fixedUUID(99)],
                    range: range,
                    wasPlaying: false
                ),
                currentRevision: .initial,
                tracks: tracks
            )
        }
        try expectError(.uneditableTrack(secondID)) {
            _ = try EditTransactionPlanner.plan(
                command: EditCommand(
                    baseRevision: .initial,
                    kind: .rippleDelete,
                    scope: .all,
                    anchorTrackID: firstID,
                    targetTrackIDs: [firstID, secondID],
                    range: range,
                    wasPlaying: false
                ),
                currentRevision: .initial,
                tracks: tracks
            )
        }
        try expectError(.duplicateTrack(firstID)) {
            _ = try EditTransactionPlanner.plan(
                command: EditCommand(
                    baseRevision: .initial,
                    kind: .rippleDelete,
                    scope: .track,
                    anchorTrackID: firstID,
                    targetTrackIDs: [firstID],
                    range: range,
                    wasPlaying: false
                ),
                currentRevision: .initial,
                tracks: [tracks[0], tracks[0]]
            )
        }
    }

    private static func verifyUnequalDurationScopePlanning() throws {
        let ids = (0..<100).map(fixedUUID)
        let descriptors = ids.enumerated().map { index, trackID in
            EditTrackDescriptor(
                trackID: trackID,
                sampleRate: index.isMultiple(of: 3) ? 44_100 : 48_000,
                frameCount: index < 40 ? 24_000 : 480_000,
                isEditable: true
            )
        }
        let range = try requireValue(
            ProjectEditRange(
                start: ProjectTime(seconds: 1),
                end: ProjectTime(seconds: 2)
            ),
            "scope range was empty"
        )
        let plan = try EditTransactionPlanner.plan(
            command: EditCommand(
                baseRevision: .initial,
                kind: .rippleDelete,
                scope: .all,
                anchorTrackID: ids[0],
                targetTrackIDs: ids.reversed(),
                range: range,
                wasPlaying: true
            ),
            currentRevision: .initial,
            tracks: descriptors
        )
        try require(plan.trackEdits.count == 60, "short tracks should not receive out-of-range mutations")
        try require(
            plan.command.targetTrackIDs == ids.sorted { $0.uuidString < $1.uuidString },
            "captured scope IDs were not stable"
        )
        try require(plan.playheadTime == range.start, "delete playhead did not target the range start")
    }

    private static func verifyExactMemoryTimelineMutations() throws {
        let buffer = syntheticBuffer(frameCount: 1_000)
        let original = AudioEditTimeline(sourceBuffer: buffer)
        var deleted = original
        try require(deleted.delete(frameRange: 100..<220) == 120, "memory delete count was wrong")
        try require(deleted.frameCount == 880, "memory delete did not shrink the timeline")
        try require(
            deleted.playbackSegments.contains {
                $0.outputStartFrame == 100 && $0.sourceStartFrame == 220
            },
            "memory delete did not remap the surviving right side"
        )

        var cleared = original
        try require(cleared.clear(frameRange: 300..<360) == 60, "memory clear count was wrong")
        try require(cleared.frameCount == 1_000, "memory clear changed duration")
        let clearedBuffer = cleared.render(frameRange: 300..<360)
        try require(
            clearedBuffer.samplesByChannel.allSatisfy { channel in
                channel.allSatisfy { abs($0) <= Float.ulpOfOne }
            },
            "memory clear did not render silence"
        )

        let clip = try requireValue(
            original.clip(for: 20..<70),
            "memory copy produced no clip"
        )
        var pasted = original
        try require(pasted.insert(clip, atFrame: 500) == 50, "memory paste count was wrong")
        try require(pasted.frameCount == 1_050, "memory paste did not extend the timeline")
        try require(
            pasted.playbackSegments.contains {
                $0.outputStartFrame == 500 &&
                    $0.sourceStartFrame == 20 &&
                    $0.frameCount == 50
            },
            "memory paste was not flush at the insertion frame"
        )
    }

    private static func verifyExactFileTimelineMutations() throws {
        let fileInfo = syntheticFileInfo(frameCount: 2_000)
        let original = AudioFileEditTimeline(fileInfo: fileInfo)
        var deleted = original
        try require(deleted.delete(frameRange: 250..<400) == 150, "file delete count was wrong")
        try require(deleted.frameCount == 1_850, "file delete did not shrink the timeline")

        var cleared = original
        try require(cleared.clear(frameRange: 500..<620) == 120, "file clear count was wrong")
        try require(cleared.frameCount == 2_000, "file clear changed duration")

        let clip = try requireValue(
            original.clip(for: 100..<180),
            "file copy produced no clip"
        )
        var pasted = original
        try require(pasted.insert(clip, atFrame: 900) == 80, "file paste count was wrong")
        try require(pasted.frameCount == 2_080, "file paste did not extend the timeline")
        try require(
            pasted.playbackSegments.contains {
                $0.outputStartFrame == 900 &&
                    $0.sourceStartFrame == 100 &&
                    $0.frameCount == 80
            },
            "file paste was not flush at the insertion frame"
        )
    }

    private static func verifySourceIdentityProtection() throws {
        let first = AudioEditTimeline(sourceBuffer: syntheticBuffer(frameCount: 100))
        var second = AudioEditTimeline(sourceBuffer: syntheticBuffer(frameCount: 100))
        let clip = try requireValue(first.clip(for: 0..<10), "source identity clip was empty")
        try require(
            second.insert(clip, atFrame: 0) == nil,
            "unrelated memory sources accepted a borrowed clip"
        )
    }

    private static func verifyPublishedMixReconciliationUsesTrackIdentity() throws {
        let buffer = syntheticBuffer(frameCount: 100)
        let ids = (0..<3).map(fixedUUID)
        let staleTracks = [
            ProjectPlaybackTrack(
                id: ids[0],
                source: .decoded(decodedAudioBuffer: buffer, zeroCrossingIndex: nil),
                sourceRevision: 0,
                volume: 1,
                isMuted: true,
                isSoloed: false
            ),
            ProjectPlaybackTrack(
                id: ids[1],
                source: .decoded(decodedAudioBuffer: buffer, zeroCrossingIndex: nil),
                sourceRevision: 0,
                volume: 1,
                isMuted: false,
                isSoloed: true
            ),
            ProjectPlaybackTrack(
                id: ids[2],
                source: .decoded(decodedAudioBuffer: buffer, zeroCrossingIndex: nil),
                sourceRevision: 1,
                volume: 1,
                isMuted: true,
                isSoloed: false
            ),
        ]
        let canonicalMixes = [
            ProjectPlaybackTrackMix(
                id: ids[2],
                volume: 0.9,
                isMuted: false,
                isSoloed: false
            ),
            ProjectPlaybackTrackMix(
                id: ids[0],
                volume: 0.7,
                isMuted: true,
                isSoloed: false
            ),
            ProjectPlaybackTrackMix(
                id: ids[1],
                volume: 0.8,
                isMuted: true,
                isSoloed: false
            ),
        ]

        let reconciled = ProjectPlaybackProjection.applyingMixes(
            canonicalMixes,
            to: staleTracks
        )
        try require(reconciled.map(\.id) == ids, "mix reconciliation changed track order")
        let reconciledByID = Dictionary(uniqueKeysWithValues: reconciled.map { ($0.id, $0) })
        for mix in canonicalMixes {
            let track = try requireValue(
                reconciledByID[mix.id],
                "mix reconciliation dropped track \(mix.id)"
            )
            try require(track.volume == mix.volume, "volume moved to the wrong track")
            try require(track.isMuted == mix.isMuted, "mute moved to the wrong track")
            try require(track.isSoloed == mix.isSoloed, "solo moved to the wrong track")
        }
        try require(
            reconciled.allSatisfy { !$0.isSoloed },
            "a stale solo bit survived edit publication"
        )

        let staleRenderTrack = TimelineRenderState.Track(
            id: ids[1],
            waveformVersion: 7,
            waveformOverview: nil,
            durationHint: 12,
            volume: 1,
            isMuted: false,
            isSoloed: true,
            hasWaveform: true
        )
        let canonicalMiddleMix = try requireValue(
            canonicalMixes.first(where: { $0.id == ids[1] }),
            "canonical middle-track mix was missing"
        )
        let reconciledRenderTrack = staleRenderTrack.applying(canonicalMiddleMix)
        try require(reconciledRenderTrack.isMuted, "renderer kept a stale mute value")
        try require(!reconciledRenderTrack.isSoloed, "renderer kept a stale solo value")
        try require(
            reconciledRenderTrack.waveformVersion == staleRenderTrack.waveformVersion &&
                reconciledRenderTrack.hasWaveform == staleRenderTrack.hasWaveform,
            "mix reconciliation replaced reusable waveform state"
        )
    }

    private static func verifyHistoryCycles(
        cycleCount: Int
    ) throws -> (p99Milliseconds: Double, maximumMilliseconds: Double) {
        var history = EditHistory<Int>()
        var durations: [Double] = []
        durations.reserveCapacity(cycleCount * 5)
        var state = 0
        var revision = EditRevision.initial

        for index in 0..<cycleCount {
            let before = state
            let after = state + 1
            let nextRevision = revision.advanced()
            let kind: EditCommandKind
            switch index % 3 {
            case 0:
                kind = .rippleDelete
            case 1:
                kind = .cut
            default:
                kind = .paste
            }

            let startedAt = DispatchTime.now().uptimeNanoseconds
            let record = EditHistoryRecord(
                transactionID: EditTransactionID(),
                commandKind: kind,
                beforeRevision: revision,
                afterRevision: nextRevision,
                beforeState: before,
                afterState: after
            )
            history.record(record)
            state = after
            revision = nextRevision
            durations.append(milliseconds(since: startedAt))

            let undoStartedAt = DispatchTime.now().uptimeNanoseconds
            let undoRecord = try requireValue(history.popUndo(), "history lost an undo record")
            state = undoRecord.beforeState
            durations.append(milliseconds(since: undoStartedAt))
            try require(state == before, "undo restored the wrong state")

            let redoStartedAt = DispatchTime.now().uptimeNanoseconds
            let redoRecord = try requireValue(history.popRedo(), "history lost a redo record")
            state = redoRecord.afterState
            durations.append(milliseconds(since: redoStartedAt))
            try require(state == after, "redo restored the wrong state")
        }

        _ = history.popUndo()
        history.record(EditHistoryRecord(
            transactionID: EditTransactionID(),
            commandKind: .clearGap,
            beforeRevision: revision,
            afterRevision: revision.advanced(),
            beforeState: state,
            afterState: state
        ))
        try require(!history.canRedo, "a new edit after undo did not clear redo history")

        let sorted = durations.sorted()
        let p99Index = min(
            max(Int((Double(max(sorted.count - 1, 0)) * 0.99).rounded()), 0),
            max(sorted.count - 1, 0)
        )
        let p99 = sorted.isEmpty ? 0 : sorted[p99Index]
        let maximum = sorted.max() ?? 0
        try require(p99 < 1, "transaction history p99 exceeded 1 ms")
        try require(maximum < 4, "transaction history outlier exceeded 4 ms")
        return (p99, maximum)
    }

    private static func syntheticBuffer(frameCount: Int) -> DecodedAudioBuffer {
        let samples = (0..<frameCount).map { frame in
            Float(frame + 1) / Float(max(frameCount, 1))
        }
        return DecodedAudioBuffer(
            url: URL(fileURLWithPath: "/tmp/soundtime-edit-transaction-\(frameCount).wav"),
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: frameCount,
            samplesByChannel: [samples]
        )
    }

    private static func syntheticFileInfo(frameCount: Int) -> WAVFileInfo {
        WAVFileInfo(
            url: URL(fileURLWithPath: "/tmp/soundtime-edit-transaction-file.wav"),
            formatTag: 1,
            channelCount: 1,
            sampleRate: 48_000,
            blockAlign: 2,
            bitsPerSample: 16,
            dataRange: 44..<(44 + frameCount * 2)
        )
    }

    private static func fixedUUID(_ index: Int) -> UUID {
        let suffix = String(format: "%012X", index + 1)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }

    private static func expectError(
        _ expected: EditTransactionError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw SmokeError.failed("expected \(expected), but the operation succeeded")
        } catch let error as EditTransactionError {
            try require(error == expected, "expected \(expected), received \(error)")
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw SmokeError.failed(message)
        }
    }

    private static func requireValue<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else {
            throw SmokeError.failed(message)
        }
        return value
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
