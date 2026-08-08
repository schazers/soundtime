import Foundation

enum EditTransactionPlanner {
    static func plan(
        command: EditCommand,
        currentRevision: EditRevision,
        tracks: [EditTrackDescriptor]
    ) throws -> EditPlan {
        guard command.baseRevision == currentRevision else {
            throw EditTransactionError.staleRevision(
                expected: command.baseRevision,
                actual: currentRevision
            )
        }

        let tracksByID = try descriptorCatalog(from: tracks)
        let targetTracks = try command.targetTrackIDs.map { trackID in
            guard let track = tracksByID[trackID] else {
                throw EditTransactionError.missingTrack(trackID)
            }
            guard track.isEditable else {
                throw EditTransactionError.uneditableTrack(trackID)
            }
            return track
        }

        let trackEdits: [PlannedTrackEdit]
        let playheadTime: ProjectTime
        let resultingSelection: ProjectEditRange?

        switch command.kind {
        case .rippleDelete, .clearGap, .cut:
            guard let range = command.range else {
                throw EditTransactionError.missingRange
            }
            trackEdits = targetTracks.compactMap { track in
                guard let frameRange = range.frameRange(
                    sampleRate: track.sampleRate,
                    frameCount: track.frameCount
                ) else {
                    return nil
                }
                let mutation: PlannedTrackMutation = command.kind == .clearGap ?
                    .clear(frameRange: frameRange) :
                    .delete(frameRange: frameRange)
                return PlannedTrackEdit(trackID: track.trackID, mutation: mutation)
            }
            guard !trackEdits.isEmpty else {
                throw EditTransactionError.noAudioInRange
            }
            if command.wasPlaying, command.kind != .clearGap {
                playheadTime = playheadTimeAfterApplyingRippleRemoval(
                    currentPlayheadTime: command.playheadTimeAtDispatch,
                    range: range
                )
            } else {
                playheadTime = range.start
            }
            resultingSelection = nil

        case .paste:
            guard let insertionTime = command.insertionTime else {
                throw EditTransactionError.missingInsertionTime
            }
            guard command.clipboardID != nil else {
                throw EditTransactionError.missingClipboard
            }
            guard let destinationTrack = targetTracks.first else {
                throw EditTransactionError.missingTrack(command.anchorTrackID)
            }
            let insertionFrame = max(
                insertionTime.frameIndex(
                    sampleRate: destinationTrack.sampleRate,
                    rounding: .down
                ),
                0
            )
            trackEdits = [
                PlannedTrackEdit(
                    trackID: destinationTrack.trackID,
                    mutation: .insert(frame: insertionFrame)
                ),
            ]
            playheadTime = insertionTime
            resultingSelection = nil
        }

        return EditPlan(
            command: command,
            nextRevision: currentRevision.advanced(),
            trackEdits: trackEdits,
            playheadTime: playheadTime,
            resultingSelection: resultingSelection
        )
    }

    static func resolvedPlayheadTime(
        for plan: EditPlan,
        resultingProjectDuration: TimeInterval,
        livePlaybackTime: ProjectTime? = nil
    ) -> ProjectTime {
        let projectEnd = ProjectTime(seconds: max(resultingProjectDuration, 0))
        let desiredTime: ProjectTime
        if
            plan.command.wasPlaying,
            plan.command.kind == .rippleDelete || plan.command.kind == .cut,
            let range = plan.command.range,
            let livePlaybackTime
        {
            desiredTime = playheadTimeAfterApplyingRippleRemoval(
                currentPlayheadTime: livePlaybackTime,
                range: range
            )
        } else {
            desiredTime = plan.playheadTime
        }

        guard desiredTime > projectEnd else {
            return desiredTime
        }

        if
            plan.command.wasPlaying,
            plan.command.kind == .rippleDelete || plan.command.kind == .cut,
            let range = plan.command.range
        {
            return min(range.start, projectEnd)
        }
        return projectEnd
    }

    static func resolvedHistoryPlayheadTime(
        command: EditCommand,
        direction: EditHistoryDirection,
        historicalPlayheadTime: ProjectTime,
        livePlayheadTime: ProjectTime,
        isPlaying: Bool,
        restoredProjectDuration: TimeInterval
    ) -> ProjectTime {
        var desiredTime = isPlaying ? livePlayheadTime : historicalPlayheadTime
        if
            isPlaying,
            command.kind == .rippleDelete || command.kind == .cut,
            let range = command.range
        {
            switch direction {
            case .undo:
                if livePlayheadTime >= range.start {
                    desiredTime = livePlayheadTime + range.duration
                }
            case .redo:
                desiredTime = playheadTimeAfterApplyingRippleRemoval(
                    currentPlayheadTime: livePlayheadTime,
                    range: range
                )
            }
        }
        return min(
            desiredTime,
            ProjectTime(seconds: max(restoredProjectDuration, 0))
        )
    }

    static func playheadTimeAfterApplyingRippleRemoval(
        currentPlayheadTime: ProjectTime,
        range: ProjectEditRange
    ) -> ProjectTime {
        if currentPlayheadTime < range.start {
            return currentPlayheadTime
        }
        if currentPlayheadTime >= range.end {
            return currentPlayheadTime - range.duration
        }
        return range.start
    }

    private static func descriptorCatalog(
        from tracks: [EditTrackDescriptor]
    ) throws -> [UUID: EditTrackDescriptor] {
        var catalog: [UUID: EditTrackDescriptor] = [:]
        catalog.reserveCapacity(tracks.count)
        for track in tracks {
            guard catalog[track.trackID] == nil else {
                throw EditTransactionError.duplicateTrack(track.trackID)
            }
            catalog[track.trackID] = track
        }
        return catalog
    }
}
