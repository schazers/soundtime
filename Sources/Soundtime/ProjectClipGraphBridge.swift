import Foundation

/// The one-way boundary between persisted legacy projects and the canonical
/// clip graph. Legacy fields may seed a graph exactly once; after installation,
/// presentation objects are projections of the graph and never inputs to it.
enum ProjectClipGraphBridge {
    static func removingTrack(_ trackID: UUID, from graph: TimelineClipGraph) throws -> TimelineClipGraph {
        try graph.replacingAllTracks(graph.tracks.filter { $0.id != trackID })
    }

    static func reorderingTracks(_ orderedTrackIDs: [UUID], in graph: TimelineClipGraph) throws -> TimelineClipGraph {
        let byID = Dictionary(uniqueKeysWithValues: graph.tracks.map { ($0.id, $0) })
        let ordered = orderedTrackIDs.compactMap { byID[$0] }
        let unmentioned = graph.tracks.filter { !orderedTrackIDs.contains($0.id) }
        return try graph.replacingAllTracks(ordered + unmentioned)
    }

    static func graph(
        for project: SoundtimeProject,
        projectURL: URL
    ) throws -> TimelineClipGraph {
        if let document = project.clipGraphDocument {
            return try resolvingMediaPaths(in: document.graph, projectURL: projectURL)
        }
        return try migrateLegacyProject(project, projectURL: projectURL)
    }

    static func applyingPresentation(
        from graph: TimelineClipGraph,
        to existingTracks: [ProjectTrack],
        replacing changedTrackIDs: Set<UUID>? = nil
    ) -> [ProjectTrack] {
        let existingByID = Dictionary(uniqueKeysWithValues: existingTracks.map { ($0.id, $0) })
        return graph.tracks.map { graphTrack in
            var presentation = existingByID[graphTrack.id] ?? presentationTrack(
                for: graphTrack,
                in: graph
            )
            if changedTrackIDs?.contains(graphTrack.id) != false {
                presentation.name = graphTrack.name
                presentation.volume = graphTrack.volume
                presentation.pan = graphTrack.pan
                presentation.channelLayout = graphTrack.channelLayout
                presentation.isMuted = graphTrack.isMuted
                presentation.isSoloed = graphTrack.isSoloed
                presentation.durationHint = Double(graphTrack.endFrame) / graph.timelineSampleRate
                if let source = graphTrack.clips.first.flatMap({ graph.source(id: $0.sourceID) }),
                   let absolutePath = source.absolutePath,
                   !absolutePath.isEmpty {
                    presentation.sourceURL = URL(fileURLWithPath: absolutePath)
                }
            }
            // Commands validate against the graph revision even when the
            // track's own clips were unchanged, so every lightweight
            // presentation advances to the current canonical revision.
            presentation.editRevision = Int(clamping: graph.revision)
            return presentation
        }
    }

    private static func presentationTrack(
        for track: TimelineTrack,
        in graph: TimelineClipGraph
    ) -> ProjectTrack {
        let firstSource = track.clips.first.flatMap { graph.source(id: $0.sourceID) }
        let sourceURL = firstSource?.absolutePath.map(URL.init(fileURLWithPath:)) ??
            URL(fileURLWithPath: "/dev/null")
        return ProjectTrack(
            id: track.id,
            editGroupID: track.metadata["editGroupID"].flatMap(UUID.init(uuidString:)),
            name: track.name,
            sourceURL: sourceURL,
            durationHint: Double(track.endFrame) / graph.timelineSampleRate,
            sourceWaveformOverview: nil,
            waveformOverview: nil,
            decodedAudioBuffer: nil,
            zeroCrossingIndex: nil,
            zeroCrossingProbe: nil,
            audioTimeline: nil,
            fileTimeline: nil,
            editableSource: nil,
            ownsSourceFile: false,
            volume: track.volume,
            pan: track.pan,
            channelLayout: track.channelLayout,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            importID: UUID(),
            editRevision: Int(clamping: graph.revision)
        )
    }

    private static func resolvingMediaPaths(
        in graph: TimelineClipGraph,
        projectURL: URL
    ) throws -> TimelineClipGraph {
        var resolved = graph
        for source in graph.sources.values {
            let resolution = TimelineMediaSourceResolver.resolve(source, projectURL: projectURL)
            resolved.upsertSource(resolution.source)
        }
        try resolved.validate()
        return resolved
    }

    private static func migrateLegacyProject(
        _ project: SoundtimeProject,
        projectURL: URL
    ) throws -> TimelineClipGraph {
        let timelineSampleRate = project.tracks.lazy.compactMap(sourceSampleRate).first ?? 48_000
        var sourcesByID: [TimelineMediaSourceID: TimelineMediaSource] = [:]
        var tracks: [TimelineTrack] = []

        for savedTrack in project.tracks {
            guard let source = mediaSource(for: savedTrack, projectURL: projectURL) else {
                tracks.append(TimelineTrack(
                    id: savedTrack.id,
                    name: savedTrack.name,
                    volume: savedTrack.volume,
                    pan: savedTrack.pan ?? 0,
                    isMuted: savedTrack.isMuted,
                    isSoloed: savedTrack.isSoloed,
                    metadata: ["missingMedia": "true"]
                ))
                continue
            }
            sourcesByID[source.id] = source
            let clips = migratedClips(
                for: savedTrack,
                source: source,
                timelineSampleRate: timelineSampleRate
            )
            tracks.append(TimelineTrack(
                id: savedTrack.id,
                name: savedTrack.name,
                clips: clips,
                volume: savedTrack.volume,
                pan: savedTrack.pan ?? 0,
                isMuted: savedTrack.isMuted,
                isSoloed: savedTrack.isSoloed,
                metadata: ["migratedFromLegacyTrack": "true"],
                channelLayout: TrackChannelLayout.forSourceChannelCount(source.channelCount)
            ))
        }

        return try TimelineClipGraph(
            sources: Array(sourcesByID.values).sorted { $0.id < $1.id },
            tracks: tracks,
            revision: max(project.editGraphRevision, 1),
            timelineSampleRate: timelineSampleRate,
            explicitEndFrame: project.timelineEndTime.map {
                max(Int(($0 * timelineSampleRate).rounded()), 0)
            }
        )
    }

    private static func migratedClips(
        for track: SoundtimeProject.Track,
        source: TimelineMediaSource,
        timelineSampleRate: Double
    ) -> [TimelineClip] {
        guard let state = track.editTimeline, !state.segments.isEmpty else {
            guard source.frameCount > 0 else { return [] }
            let timelineFrames = max(
                Int((Double(source.frameCount) / source.sampleRate * timelineSampleRate).rounded()),
                1
            )
            return [TimelineClip(
                id: stableClipID(trackID: track.id, component: "root"),
                sourceID: source.id,
                timelineRange: TimelineFrameRange(startFrame: 0, frameCount: timelineFrames),
                sourceRange: TimelineFrameRange(startFrame: 0, frameCount: source.frameCount),
                name: track.name,
                metadata: ["migratedLegacyRoot": "true"]
            )]
        }

        var outputSourceFrames = 0
        var occurrences: [UUID: Int] = [:]
        var clips: [TimelineClip] = []
        for segment in state.segments {
            defer { outputSourceFrames += max(segment.frameCount, 0) }
            guard segment.frameCount > 0 else { continue }
            // Legacy clear-gap edits encoded silence as zero-gain source data.
            // Advancing the output cursor while omitting the clip preserves the
            // exact gap without inventing media.
            guard segment.gainStart != 0 || segment.gainEnd != 0 else { continue }
            let sourceStartFrame = max(segment.sourceStartFrame, 0)
            guard sourceStartFrame < source.frameCount else { continue }
            let sourceFrameCount = min(
                segment.frameCount,
                source.frameCount - sourceStartFrame
            )
            guard sourceFrameCount > 0 else { continue }

            let legacyID = segment.clipID ?? stableClipID(
                trackID: track.id,
                component: "segment-\(outputSourceFrames)"
            ).rawValue
            let occurrence = occurrences[legacyID, default: 0]
            occurrences[legacyID] = occurrence + 1
            let clipID = occurrence == 0
                ? AudioTimelineClipID(rawValue: legacyID)
                : stableClipID(trackID: legacyID, component: "occurrence-\(occurrence)")
            let timelineStart = Int(
                (Double(outputSourceFrames) / state.sourceSampleRate * timelineSampleRate).rounded()
            )
            let timelineCount = max(
                Int((Double(segment.frameCount) / state.sourceSampleRate * timelineSampleRate).rounded()),
                1
            )
            let name = track.clipNames?[legacyID] ?? track.name
            clips.append(TimelineClip(
                id: clipID,
                sourceID: source.id,
                timelineRange: TimelineFrameRange(startFrame: timelineStart, frameCount: timelineCount),
                sourceRange: TimelineFrameRange(
                    startFrame: sourceStartFrame,
                    frameCount: sourceFrameCount
                ),
                name: occurrence == 0 ? name : "\(name) \(occurrence + 1)",
                gainEnvelope: .init(
                    startMultiplier: max(segment.gainStart, 0),
                    endMultiplier: max(segment.gainEnd, 0)
                ),
                metadata: ["legacyClipID": legacyID.uuidString.lowercased()]
            ))
        }
        return clips
    }

    private static func mediaSource(
        for track: SoundtimeProject.Track,
        projectURL: URL
    ) -> TimelineMediaSource? {
        let editable = track.editableSource
        let frameCount = editable?.sourceFrameCount ??
            track.editTimeline?.sourceFrameCount ??
            track.waveformPreview?.fileFingerprint.frameCount ?? 0
        let sampleRate = editable?.sourceSampleRate ??
            track.editTimeline?.sourceSampleRate ??
            track.waveformPreview?.fileFingerprint.sampleRate ?? 0
        let channelCount = editable?.channelCount ??
            track.waveformPreview?.fileFingerprint.channelCount ?? 0
        guard frameCount >= 0, sampleRate > 0, channelCount > 0 else {
            return nil
        }

        let absoluteURL = track.audioSourceCandidateURLs.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) ?? track.audioSourceCandidateURLs.first
        let identitySeed = track.importedAssetState?.assetID.uuidString ??
            track.editableSource?.importedAssetID?.uuidString ??
            track.waveformPreview?.fileFingerprint.stableSummary ??
            absoluteURL?.standardizedFileURL.path ??
            "track:\(track.id.uuidString.lowercased())"
        let sourceID = TimelineMediaSourceID(rawValue: "media-\(stableHash(identitySeed))")
        let projectDirectory = projectURL.deletingLastPathComponent().standardizedFileURL.path
        let absolutePath = absoluteURL?.standardizedFileURL.path
        let relativePath = absolutePath.flatMap { path -> String? in
            let prefix = projectDirectory.hasSuffix("/") ? projectDirectory : projectDirectory + "/"
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
        }
        return TimelineMediaSource(
            id: sourceID,
            relativePath: relativePath,
            absolutePath: absolutePath,
            fingerprint: track.waveformPreview?.fileFingerprint.stableSummary,
            frameCount: frameCount,
            sampleRate: sampleRate,
            channelCount: channelCount,
            metadata: [
                "legacyTrackID": track.id.uuidString.lowercased(),
                "originalFilePath": track.importedAssetState?.originalFilePath ?? track.filePath,
            ]
        )
    }

    private static func sourceSampleRate(_ track: SoundtimeProject.Track) -> Double? {
        let value = track.editableSource?.sourceSampleRate ??
            track.editTimeline?.sourceSampleRate ??
            track.waveformPreview?.fileFingerprint.sampleRate
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func stableClipID(trackID: UUID, component: String) -> AudioTimelineClipID {
        let value = "\(trackID.uuidString.lowercased())|\(component)"
        let hex = stableHash(value)
        let padded = String((hex + String(repeating: "0", count: 32)).prefix(32))
        let uuidString = "\(padded.prefix(8))-\(padded.dropFirst(8).prefix(4))-\(padded.dropFirst(12).prefix(4))-\(padded.dropFirst(16).prefix(4))-\(padded.dropFirst(20).prefix(12))"
        return AudioTimelineClipID(rawValue: UUID(uuidString: uuidString) ?? trackID)
    }

    private static func stableHash(_ value: String) -> String {
        var first: UInt64 = 14_695_981_039_346_656_037
        var second: UInt64 = 10_995_116_282_11
        for byte in value.utf8 {
            first = (first ^ UInt64(byte)) &* 1_099_511_628_211
            second = (second &* 1_099_511_628_211) ^ UInt64(byte)
        }
        return String(format: "%016llx%016llx", first, second)
    }
}
