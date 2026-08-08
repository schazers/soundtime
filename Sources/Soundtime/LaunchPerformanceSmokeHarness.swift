import Foundation
import QuartzCore
import SoundtimeEditing

enum LaunchPerformanceSmokeHarness {
    enum SmokeError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                return message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let fullMode = arguments.contains("--launch-performance-smoke-full")
        let trackCount = fullMode ? 24 : 8
        let binCount = fullMode ? 65_536 : 32_768
        let loadBudgetMilliseconds = fullMode ? 220.0 : 140.0
        let launchPlanResolveBudgetMilliseconds = fullMode ? 420.0 : 260.0
        let sourceFrameCount = 48_000 * 90
        let sampleRate = 48_000.0
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundtimeLaunchPerformance-\(UUID().uuidString)", isDirectory: true)
        let projectURL = directory
            .appendingPathComponent("LaunchPerformance")
            .appendingPathExtension(SoundtimeProjectStore.fileExtension)
        let driftProjectURL = directory
            .appendingPathComponent("LaunchPerformanceDrift")
            .appendingPathExtension(SoundtimeProjectStore.fileExtension)
        let previousLastProjectURL = SoundtimeProjectStore.lastProjectURL()
        let previousRecentProjectURLs = SoundtimeProjectStore.recentProjectURLs()
        var autosaveURLForCleanup: URL?
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            ProjectLaunchSnapshotStore.remove(for: projectURL)
            ProjectLaunchSnapshotStore.remove(for: driftProjectURL)
            ProjectFirstFrameWaveformPacketStore.remove(for: projectURL)
            ProjectFirstFrameWaveformPacketStore.remove(for: driftProjectURL)
            ProjectLaunchManifestStore.remove(for: projectURL)
            ProjectLaunchManifestStore.remove(for: driftProjectURL)
            ProjectLaunchCacheBundleStore.remove(for: projectURL)
            ProjectLaunchCacheBundleStore.remove(for: driftProjectURL)
            if let autosaveURLForCleanup {
                ProjectLaunchSnapshotStore.remove(for: autosaveURLForCleanup)
                ProjectFirstFrameWaveformPacketStore.remove(for: autosaveURLForCleanup)
                ProjectLaunchManifestStore.remove(for: autosaveURLForCleanup)
                ProjectLaunchCacheBundleStore.remove(for: autosaveURLForCleanup)
                try? FileManager.default.removeItem(at: autosaveURLForCleanup)
            }
            SoundtimeProjectStore.clearRecentProjectURLs()
            for recentProjectURL in previousRecentProjectURLs.reversed() {
                SoundtimeProjectStore.rememberRecentProjectURL(recentProjectURL)
            }
            if let previousLastProjectURL {
                SoundtimeProjectStore.rememberLastProjectURL(previousLastProjectURL)
            } else {
                SoundtimeProjectStore.forgetLastProjectURL()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        try Data("launch performance project".utf8).write(to: projectURL, options: [.atomic])
        let tracks = try (0..<trackCount).map { index in
            let sourceURL = directory
                .appendingPathComponent("Track-\(index + 1)")
                .appendingPathExtension("wav")
            try Data(count: 44 + sourceFrameCount * 4 + index).write(to: sourceURL, options: [.atomic])
            let sourceOverview = syntheticOverview(
                duration: Double(sourceFrameCount) / sampleRate,
                binCount: binCount
            )
            let displayOverview = syntheticOverview(
                duration: Double(sourceFrameCount) / sampleRate,
                binCount: max(1, binCount - index * 17)
            )
            return ProjectLaunchSnapshot.TrackDraft(
                id: UUID(),
                editGroupID: UUID(uuidString: "99999999-aaaa-bbbb-cccc-dddddddddddd"),
                name: "Launch Track \(index + 1)",
                filePath: sourceURL.path,
                durationHint: sourceOverview.duration,
                sourceWaveformOverview: sourceOverview,
                displayWaveformOverview: displayOverview,
                editTimeline: nil,
                editableSource: nil,
                ownsSourceFile: false,
                volume: Float(0.70 + Double(index) * 0.005),
                isMuted: index == 1,
                isSoloed: index == 2
            )
        }
        let launchClipGraph = try TimelineClipGraph(
            sources: tracks.enumerated().map { index, track in
                TimelineMediaSource(
                    id: TimelineMediaSourceID(rawValue: "launch-source-\(index)"),
                    absolutePath: track.filePath,
                    frameCount: sourceFrameCount,
                    sampleRate: sampleRate,
                    channelCount: 2
                )
            },
            tracks: tracks.enumerated().map { index, track in
                TimelineTrack(
                    id: track.id,
                    name: track.name,
                    clips: [
                        TimelineClip(
                            sourceID: TimelineMediaSourceID(rawValue: "launch-source-\(index)"),
                            timelineRange: TimelineFrameRange(
                                startFrame: (index + 1) * 12_000,
                                frameCount: sourceFrameCount
                            ),
                            sourceRange: TimelineFrameRange(
                                startFrame: 0,
                                frameCount: sourceFrameCount
                            ),
                            name: "Offset Launch Clip \(index + 1)"
                        ),
                    ],
                    volume: track.volume,
                    isMuted: track.isMuted,
                    isSoloed: track.isSoloed
                )
            },
            timelineSampleRate: sampleRate
        )
        let launchClipGraphDocument = try TimelineClipGraphDocument(graph: launchClipGraph)

        let snapshot = ProjectLaunchSnapshot(
            projectURL: projectURL,
            windowLayout: SoundtimeProject.WindowLayout(x: 44, y: 55, width: 1512, height: 982),
            timelineViewport: SoundtimeProject.TimelineViewport(startProgress: 0.21, durationProgress: 0.18),
            masterVolume: 0.82,
            transcriptDisplayMode: .hidden,
            clipGraphDocument: launchClipGraphDocument,
            tracks: tracks
        )
        let snapshotReadiness = ProjectLaunchReadinessClassifier.summarize(snapshot: snapshot)
        try require(snapshotReadiness.trackCount == trackCount, "snapshot readiness track count mismatch")
        try require(snapshot.tracks[1].isMuted, "launch snapshot did not preserve muted track state")
        try require(snapshot.tracks[2].isSoloed, "launch snapshot did not preserve soloed track state")
        try require(
            snapshotReadiness.drawableWaveformTrackCount == trackCount,
            "snapshot readiness did not count drawable waveforms"
        )
        try require(
            snapshotReadiness.hasDrawableWaveformForEveryTrack,
            "snapshot readiness should require every track to have a drawable waveform for first paint"
        )
        try require(snapshotReadiness.isFirstFrameUsable, "snapshot readiness should be first-frame usable")

        var durationOnlySnapshot = snapshot
        durationOnlySnapshot.tracks[0].sourceOverview = nil
        durationOnlySnapshot.tracks[0].displayOverview = nil
        durationOnlySnapshot.tracks[0].durationHint = Double(sourceFrameCount) / sampleRate
        let durationOnlyReadiness = ProjectLaunchReadinessClassifier.summarize(snapshot: durationOnlySnapshot)
        try require(durationOnlyReadiness.durationOnlyTrackCount == 1, "duration-only launch track was not classified")
        try require(
            !durationOnlyReadiness.hasDrawableWaveformForEveryTrack,
            "duration-only launch track should keep the snapshot off the all-waveforms first-paint path"
        )
        try require(durationOnlyReadiness.isFirstFrameUsable, "duration-only launch track should still be first-frame usable")

        let plannerTracks = tracks.map { draft in
            SoundtimeProject.Track(
                id: draft.id,
                editGroupID: draft.editGroupID,
                name: draft.name,
                filePath: draft.filePath,
                volume: draft.volume,
                isMuted: draft.isMuted,
                isSoloed: draft.isSoloed
            )
        }
        let orderedHydrationTracks = ProjectLaunchHydrationPlanner.orderedTracks(
            plannerTracks,
            activeTrackID: plannerTracks[3].id,
            selectedTrackIDs: [plannerTracks[1].id, plannerTracks[5].id]
        )
        try require(orderedHydrationTracks[0].id == plannerTracks[3].id, "hydration planner did not prioritize active track")
        try require(orderedHydrationTracks[1].id == plannerTracks[1].id, "hydration planner did not keep selected tracks early")
        try require(orderedHydrationTracks[2].id == plannerTracks[5].id, "hydration planner did not preserve selected track order")

        let primeEditedURL = directory.appendingPathComponent("PrimeEdited.wav")
        let primePlainURL = directory.appendingPathComponent("PrimePlain.wav")
        let primeFrameCount = 4_800
        try WAVFileWriter.write(
            syntheticAudioBuffer(url: primeEditedURL, frameCount: primeFrameCount, sampleRate: sampleRate),
            to: primeEditedURL
        )
        try WAVFileWriter.write(
            syntheticAudioBuffer(url: primePlainURL, frameCount: primeFrameCount, sampleRate: sampleRate),
            to: primePlainURL
        )
        let primeEditedInfo = try WAVAudioDecoder.inspect(url: primeEditedURL)
        let primePlainInfo = try WAVAudioDecoder.inspect(url: primePlainURL)
        let editedTimelineState = AudioFileEditTimeline.PersistentState(
            sourceFrameCount: primeEditedInfo.frameCount,
            sourceSampleRate: primeEditedInfo.sampleRate,
            segments: [
                AudioFileEditTimeline.PersistentSegment(
                    sourceStartFrame: 0,
                    frameCount: primeEditedInfo.frameCount / 3,
                    gainStart: 1,
                    gainEnd: 1
                ),
                AudioFileEditTimeline.PersistentSegment(
                    sourceStartFrame: primeEditedInfo.frameCount / 2,
                    frameCount: primeEditedInfo.frameCount / 3,
                    gainStart: 1,
                    gainEnd: 1,
                    startsNewClip: true
                ),
            ]
        )
        let primeEditedTrackID = UUID()
        let primePlainTrackID = UUID()
        let primeProject = SoundtimeProject(
            tracks: [
                SoundtimeProject.Track(
                    id: primeEditedTrackID,
                    name: "Edited Prime",
                    filePath: primeEditedURL.path,
                    volume: 0.9,
                    isMuted: false,
                    isSoloed: false,
                    editTimeline: editedTimelineState
                ),
                SoundtimeProject.Track(
                    id: primePlainTrackID,
                    name: "Plain Prime",
                    filePath: primePlainURL.path,
                    volume: 0.7,
                    isMuted: true,
                    isSoloed: false
                ),
            ],
            windowLayout: nil,
            masterVolume: nil,
            timelineViewport: nil
        )
        let playbackPrime = ProjectLaunchPlaybackPrimer.prime(
            project: primeProject,
            projectURL: projectURL,
            activeTrackID: primePlainTrackID,
            selectedTrackIDs: []
        )
        try require(playbackPrime.isComplete, "playback prime should load all tiny WAV tracks")
        try require(playbackPrime.tracks.count == 2, "playback prime track count mismatch")
        try require(
            playbackPrime.tracks.map(\.trackID) == [primeEditedTrackID, primePlainTrackID],
            "playback prime must preserve project track order"
        )
        let editedPrimeTrack = try requireValue(
            playbackPrime.tracks.first { $0.trackID == primeEditedTrackID },
            "edited playback prime track missing"
        )
        let plainPrimeTrack = try requireValue(
            playbackPrime.tracks.first { $0.trackID == primePlainTrackID },
            "plain playback prime track missing"
        )
        try require(editedPrimeTrack.fileTimeline?.hasEdits == true, "playback prime did not restore edited file timeline")
        try require(editedPrimeTrack.editableSource.editableURL == primeEditedURL.standardizedFileURL, "edited prime source URL mismatch")
        try require(plainPrimeTrack.fileTimeline == nil, "plain playback prime should not invent an edit timeline")
        switch editedPrimeTrack.playbackTrack.source {
        case let .fileTimeline(url, timeline, zeroCrossingProbe):
            try require(url == primeEditedURL.standardizedFileURL, "edited playback prime URL mismatch")
            try require(timeline.hasEdits, "edited playback prime source did not carry edits")
            try require(zeroCrossingProbe == nil, "playback prime should defer zero-crossing probes")
        default:
            throw SmokeError.failed("edited playback prime did not use fileTimeline source")
        }
        switch plainPrimeTrack.playbackTrack.source {
        case let .file(url, zeroCrossingProbe):
            try require(url == primePlainURL.standardizedFileURL, "plain playback prime URL mismatch")
            try require(zeroCrossingProbe == nil, "plain playback prime should defer zero-crossing probes")
        default:
            throw SmokeError.failed("plain playback prime did not use file source")
        }

        // A saved project's legacy track fields can describe the original
        // whole file while its canonical graph contains shorter, rearranged
        // clips. Startup playback must follow the graph that the timeline
        // renders, never the legacy whole-file representation.
        let canonicalEditedSource = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "launch-prime-edited"),
            absolutePath: primeEditedURL.path,
            frameCount: primeEditedInfo.frameCount,
            sampleRate: primeEditedInfo.sampleRate,
            channelCount: primeEditedInfo.channelCount
        )
        let canonicalPlainSource = TimelineMediaSource(
            id: TimelineMediaSourceID(rawValue: "launch-prime-plain"),
            absolutePath: primePlainURL.path,
            frameCount: primePlainInfo.frameCount,
            sampleRate: primePlainInfo.sampleRate,
            channelCount: primePlainInfo.channelCount
        )
        let canonicalPlainEndFrame = 3_000
        let canonicalGraph = try TimelineClipGraph(
            sources: [canonicalEditedSource, canonicalPlainSource],
            tracks: [
                TimelineTrack(
                    id: primeEditedTrackID,
                    name: "Edited Prime",
                    clips: [
                        TimelineClip(
                            sourceID: canonicalEditedSource.id,
                            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 1_200),
                            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 1_200),
                            name: "Edited Canonical Clip"
                        ),
                    ],
                    volume: 0.9
                ),
                TimelineTrack(
                    id: primePlainTrackID,
                    name: "Plain Prime",
                    clips: [
                        TimelineClip(
                            sourceID: canonicalPlainSource.id,
                            timelineRange: TimelineFrameRange(startFrame: 0, frameCount: 1_800),
                            sourceRange: TimelineFrameRange(startFrame: 0, frameCount: 1_800),
                            name: "Plain Canonical 1"
                        ),
                        TimelineClip(
                            sourceID: canonicalPlainSource.id,
                            timelineRange: TimelineFrameRange(startFrame: 1_800, frameCount: 1_200),
                            sourceRange: TimelineFrameRange(startFrame: 2_400, frameCount: 1_200),
                            name: "Plain Canonical 2"
                        ),
                    ],
                    volume: 0.7,
                    isMuted: true
                ),
            ],
            timelineSampleRate: sampleRate
        )
        let canonicalPlaybackPrime = ProjectLaunchPlaybackPrimer.prime(
            project: primeProject,
            projectURL: projectURL,
            activeTrackID: primePlainTrackID,
            selectedTrackIDs: [],
            playbackSnapshot: try TimelineClipPlaybackProjection.snapshot(from: canonicalGraph)
        )
        try require(canonicalPlaybackPrime.isComplete, "canonical playback prime should load every project track")
        try require(canonicalPlaybackPrime.usesCanonicalClipGraph, "startup playback prime did not report canonical graph use")
        let canonicalPlainPlaybackTrack = try requireValue(
            canonicalPlaybackPrime.playbackTracks.first { $0.logicalTrackID == primePlainTrackID },
            "canonical plain playback lane missing"
        )
        switch canonicalPlainPlaybackTrack.source {
        case let .fileSegments(url, sourceFrameCount, _, _, segments, _):
            try require(url == primePlainURL.standardizedFileURL, "canonical playback lane URL mismatch")
            try require(sourceFrameCount == primePlainInfo.frameCount, "canonical playback source length mismatch")
            try require(segments.count == 2, "canonical playback prime lost clip boundaries")
            try require(
                segments.map { $0.outputStartFrame + $0.frameCount }.max() == canonicalPlainEndFrame,
                "canonical playback prime did not stop at the visible clip edge"
            )
            try require(
                canonicalPlainEndFrame < primePlainInfo.frameCount,
                "canonical launch regression fixture must be shorter than its source file"
            )
        default:
            throw SmokeError.failed("canonical playback prime bypassed clip segments")
        }

        let launchOverviewCache = WaveformOverviewDiskCacheStore(
            rootDirectory: directory.appendingPathComponent("LaunchOverviewCache", isDirectory: true)
        )
        let cachedEditedSourceOverview = syntheticOverview(
            duration: primeEditedInfo.duration,
            binCount: 4_096
        )
        let cachedPlainOverview = syntheticOverview(
            duration: primePlainInfo.duration,
            binCount: ProjectLaunchSnapshot.maximumOverviewBinCount + 4_096
        )
        let editedPrimeTimeline = try requireValue(
            AudioFileEditTimeline(persistentState: editedTimelineState),
            "could not restore edited timeline for cache hydration smoke"
        )
        let cachedEditedDisplayOverview = syntheticOverview(
            duration: editedPrimeTimeline.duration,
            binCount: 2_048
        )
        try launchOverviewCache.saveOverview(
            cachedEditedSourceOverview,
            targetBinCount: cachedEditedSourceOverview.bins.count,
            samplesPerBin: 32,
            fileInfo: primeEditedInfo
        )
        try launchOverviewCache.saveEditedOverview(
            cachedEditedDisplayOverview,
            fileInfo: primeEditedInfo,
            editTimeline: editedPrimeTimeline
        )
        try launchOverviewCache.saveOverview(
            cachedPlainOverview,
            targetBinCount: cachedPlainOverview.bins.count,
            samplesPerBin: 32,
            fileInfo: primePlainInfo
        )
        let cachedPreviewProject = ProjectLaunchPreviewWaveformCacheHydrator.hydratedProject(
            primeProject,
            waveformOverviewDiskCache: launchOverviewCache
        )
        let cachedPreviewReadiness = ProjectLaunchReadinessClassifier.summarize(project: cachedPreviewProject)
        try require(
            cachedPreviewReadiness.drawableWaveformTrackCount == primeProject.tracks.count,
            "cached launch preview hydration did not make every preview-less track drawable"
        )
        let cachedEditedPreview = try requireValue(
            cachedPreviewProject.tracks.first { $0.id == primeEditedTrackID }?.waveformPreview,
            "cached launch preview hydration did not attach edited track preview"
        )
        try require(
            cachedEditedPreview.displayOverview.bins.count == cachedEditedDisplayOverview.bins.count,
            "cached launch preview hydration did not prefer edited display overview"
        )
        let cachedPlainPreview = try requireValue(
            cachedPreviewProject.tracks.first { $0.id == primePlainTrackID }?.waveformPreview,
            "cached launch preview hydration did not attach plain track preview"
        )
        try require(
            cachedPlainPreview.displayOverview.bins.count == ProjectLaunchSnapshot.maximumOverviewBinCount,
            "cached launch preview hydration did not reduce larger cached overview for launch display"
        )

        try ProjectLaunchSnapshotStore.save(snapshot, for: projectURL)
        let firstFramePacket = ProjectFirstFrameWaveformPacket(
            projectURL: projectURL,
            windowLayout: snapshot.windowLayout,
            timelineViewport: snapshot.timelineViewport,
            masterVolume: snapshot.masterVolume,
            transcriptDisplayMode: snapshot.transcriptDisplayMode,
            clipGraphDocument: launchClipGraphDocument,
            tracks: tracks
        )
        try ProjectFirstFrameWaveformPacketStore.save(firstFramePacket, for: projectURL)
        let packetURL = ProjectFirstFrameWaveformPacketStore.packetURL(for: projectURL)
        let packetData = try Data(contentsOf: packetURL)
        try require(
            ProjectFirstFrameWaveformPacketBinaryCodec.hasBinaryMagic(packetData),
            "first-frame waveform packet sidecar did not use binary magic"
        )
        try require(
            packetData.count <= ProjectFirstFrameWaveformPacketStore.firstPaintSynchronousByteLimit,
            "first-frame waveform packet exceeded synchronous first-paint byte limit"
        )
        let loadedFirstFramePacket = try requireValue(
            ProjectFirstFrameWaveformPacketStore.loadForFirstPaintIfAvailable(for: projectURL),
            "first-frame waveform packet was not available for first paint"
        )
        let packetReadiness = ProjectLaunchReadinessClassifier.summarize(packet: loadedFirstFramePacket)
        try require(packetReadiness.hasDrawableWaveformForEveryTrack, "first-frame packet should draw every track")
        try require(
            loadedFirstFramePacket.tracks[1].isMuted,
            "first-frame packet dropped muted track state"
        )
        try require(
            loadedFirstFramePacket.tracks[2].isSoloed,
            "first-frame packet dropped soloed track state"
        )
        try require(
            loadedFirstFramePacket.clipGraphDocument?.graph.tracks.first?.clips.first?.timelineRange.startFrame == 12_000,
            "first-frame packet dropped the first clip's nonzero launch position"
        )
        let launchManifest = ProjectLaunchManifest(
            projectURL: projectURL,
            windowLayout: snapshot.windowLayout,
            timelineViewport: snapshot.timelineViewport,
            masterVolume: snapshot.masterVolume,
            transcriptDisplayMode: snapshot.transcriptDisplayMode,
            clipGraphDocument: launchClipGraphDocument,
            tracks: tracks,
            snapshotByteCount: Self.fileByteCount(ProjectLaunchSnapshotStore.snapshotURL(for: projectURL)),
            firstFramePacketByteCount: Self.fileByteCount(ProjectFirstFrameWaveformPacketStore.packetURL(for: projectURL)),
            snapshotDrawable: snapshotReadiness.hasAnyDrawableWaveform,
            firstFramePacketDrawable: packetReadiness.hasAnyDrawableWaveform
        )
        try ProjectLaunchManifestStore.save(launchManifest, for: projectURL)
        let publishedGeneration = try ProjectLaunchCacheBundleStore.publish(
            manifest: launchManifest,
            firstFramePacket: firstFramePacket,
            snapshot: snapshot,
            for: projectURL
        )
        try require(
            publishedGeneration.manifestByteCount > 0 &&
                (publishedGeneration.firstFramePacketByteCount ?? 0) > 0 &&
                (publishedGeneration.snapshotByteCount ?? 0) > 0,
            "atomic launch cache generation did not report written artifact sizes"
        )
        let bundledManifest = try requireValue(
            ProjectLaunchCacheBundleStore.loadManifest(for: projectURL),
            "atomic launch cache manifest should be available for first paint"
        )
        try require(
            bundledManifest.visualFingerprint == launchManifest.visualFingerprint,
            "atomic launch cache manifest fingerprint mismatch"
        )
        let bundledPacket = try requireValue(
            ProjectLaunchCacheBundleStore.loadFirstFramePacketForFirstPaintIfAvailable(for: projectURL),
            "atomic launch cache packet should be available for first paint"
        )
        try require(
            bundledPacket.visualFingerprint == launchManifest.visualFingerprint,
            "atomic launch cache packet fingerprint mismatch"
        )
        let bundledSnapshot: ProjectLaunchSnapshot
        if (publishedGeneration.snapshotByteCount ?? 0) <= ProjectLaunchSnapshotStore.firstPaintSynchronousByteLimit {
            bundledSnapshot = try requireValue(
                ProjectLaunchCacheBundleStore.loadSnapshotForFirstPaintIfAvailable(for: projectURL),
                "atomic launch cache snapshot should be available for first paint"
            )
        } else {
            bundledSnapshot = try ProjectLaunchCacheBundleStore.loadSnapshot(for: projectURL)
        }
        try require(
            bundledSnapshot.visualFingerprint == launchManifest.visualFingerprint,
            "atomic launch cache snapshot fingerprint mismatch"
        )
        let loadedLaunchManifest = try requireValue(
            ProjectLaunchManifestStore.load(for: projectURL),
            "launch manifest should be available for first-paint shell"
        )
        try require(
            loadedLaunchManifest.tracks.count == trackCount,
            "launch manifest did not preserve immediate track shells"
        )
        try require(
            loadedLaunchManifest.tracks[1].isMuted && loadedLaunchManifest.tracks[2].isSoloed,
            "launch manifest dropped mute/solo state"
        )
        try require(
            loadedLaunchManifest.visualFingerprint == loadedFirstFramePacket.visualFingerprint,
            "launch manifest and first-frame packet fingerprints should match"
        )
        let manifestURL = ProjectLaunchManifestStore.manifestURL(for: projectURL)
        try Data(count: ProjectLaunchManifestStore.firstPaintSynchronousByteLimit + 1)
            .write(to: manifestURL, options: [.atomic])
        try require(
            ProjectLaunchManifestStore.load(for: projectURL) == nil,
            "oversized launch manifest should not load on the synchronous first-paint path"
        )
        try require(
            ProjectLaunchCacheBundleStore.loadManifest(for: projectURL) != nil,
            "atomic launch cache should remain available when a legacy manifest is corrupted"
        )
        try ProjectLaunchManifestStore.save(launchManifest, for: projectURL)
        let packetShell = try requireValue(
            ProjectFirstFrameWaveformPacketStore.loadShellForFirstPaintIfAvailable(for: projectURL),
            "first-frame packet shell was not available for pre-window visual restore"
        )
        try require(packetShell.tracks.count == trackCount, "first-frame packet shell track count mismatch")
        try require(packetShell.tracks[1].isMuted, "first-frame packet shell dropped muted track state")
        try require(packetShell.tracks[2].isSoloed, "first-frame packet shell dropped soloed track state")
        try require(
            packetShell.tracks.allSatisfy { $0.displayOverview == nil },
            "first-frame packet shell should not decode waveform payloads"
        )
        let launchOverlay = SoundtimeProjectLaunchStateOverlay(
            createdAt: 1234.5,
            windowLayout: SoundtimeProject.WindowLayout(x: 9, y: 8, width: 1440, height: 900),
            timelineViewport: SoundtimeProject.TimelineViewport(startProgress: 0.17, durationProgress: 0.27),
            masterVolume: 0.66,
            transcriptDisplayMode: .waveformOverlay,
            tracks: tracks.enumerated().map { index, track in
                SoundtimeProjectLaunchStateOverlay.TrackState(
                    id: track.id,
                    volume: index == 3 ? 1.25 : Float(0.25 + Double(index) * 0.01),
                    isMuted: index == 0 || index == 3,
                    isSoloed: index == 2
                )
            }
        )
        SoundtimeProjectStore.rememberLaunchStateOverlay(launchOverlay, for: projectURL)
        let rememberedLaunchOverlay = try requireValue(
            SoundtimeProjectStore.rememberedLaunchStateOverlay(for: projectURL),
            "lightweight launch state overlay did not round-trip"
        )
        try require(
            rememberedLaunchOverlay.windowLayout?.width == 1440,
            "lightweight launch overlay dropped window layout"
        )
        try require(
            rememberedLaunchOverlay.timelineViewport?.durationProgress == 0.27,
            "lightweight launch overlay dropped timeline viewport"
        )
        try require(
            rememberedLaunchOverlay.masterVolume == 0.66,
            "lightweight launch overlay dropped master volume"
        )
        try require(
            rememberedLaunchOverlay.transcriptDisplayMode == .waveformOverlay,
            "lightweight launch overlay dropped transcript display mode"
        )
        try require(
            rememberedLaunchOverlay.tracks[0].isMuted &&
                rememberedLaunchOverlay.tracks[2].isSoloed &&
                rememberedLaunchOverlay.tracks[3].isMuted,
            "lightweight launch overlay dropped per-track mute/solo state"
        )
        let coordinatorShell = try requireValue(
            ProjectLaunchCoordinator.loadShell(projectURL: projectURL),
            "launch coordinator did not load launch manifest shell"
        )
        try require(
            coordinatorShell.source == .launchManifestShell,
            "launch coordinator should prefer the tiny launch manifest shell"
        )
        try require(
            coordinatorShell.isShellOnly,
            "launch coordinator shell should remain manifest-only"
        )
        try require(
            coordinatorShell.tracks.count == trackCount,
            "launch coordinator shell did not preserve immediate track count"
        )
        try require(
            coordinatorShell.tracks[0].isMuted &&
                coordinatorShell.tracks[2].isSoloed &&
                coordinatorShell.tracks[3].isMuted,
            "launch coordinator shell did not apply lightweight per-track overlay"
        )
        try require(
            coordinatorShell.tracks[3].volume == 1,
            "launch coordinator shell did not clamp invalid overlay volume"
        )
        try require(
            coordinatorShell.tracks.allSatisfy { $0.displayWaveformOverview == nil },
            "launch coordinator shell should not decode waveform payloads"
        )
        let coordinatorFirstFrame = try requireValue(
            ProjectLaunchCoordinator.loadFirstFrame(
                projectURL: projectURL,
                usesAutosaveRecovery: true,
                waveformOverviewDiskCache: launchOverviewCache
            ),
            "launch coordinator did not load first-frame visual packet"
        )
        try require(
            coordinatorFirstFrame.source == .firstFrameWaveformPacket,
            "launch coordinator should prefer first-frame packets over snapshots"
        )
        let coordinatorCachedFirstPaintFrame = try requireValue(
            ProjectLaunchCoordinator.loadCachedFirstPaintFrame(projectURL: projectURL),
            "launch coordinator did not load cached first-paint visual frame"
        )
        try require(
            coordinatorCachedFirstPaintFrame.source == .firstFrameWaveformPacket,
            "cached first-paint frame should prefer first-frame packets over snapshots"
        )
        try require(
            coordinatorCachedFirstPaintFrame.summary.hasDrawableWaveformForEveryTrack,
            "cached first-paint frame should draw every track"
        )
        try require(
            coordinatorFirstFrame.summary.hasDrawableWaveformForEveryTrack,
            "launch coordinator first-frame packet should draw every track"
        )
        try require(
            coordinatorFirstFrame.tracks[0].isMuted &&
                coordinatorFirstFrame.tracks[2].isSoloed &&
                coordinatorFirstFrame.tracks[3].isMuted,
            "launch coordinator first-frame packet did not apply lightweight per-track overlay"
        )
        try require(
            coordinatorFirstFrame.tracks[3].volume == 1,
            "launch coordinator first-frame packet did not clamp invalid overlay volume"
        )
        try require(
            coordinatorFirstFrame.windowLayout?.width == 1440,
            "launch coordinator did not apply lightweight window layout overlay"
        )
        try require(
            coordinatorFirstFrame.clipGraphDocument?.graph.tracks.enumerated().allSatisfy { index, track in
                track.clips.first?.timelineRange.startFrame == (index + 1) * 12_000
            } == true,
            "launch coordinator first frame did not preserve canonical clip positions"
        )
        SoundtimeProjectStore.rememberLastProjectURL(projectURL)
        let rememberedProjectPlan = ProjectLaunchCoordinator.resolveLaunchPlan(restoresLastProject: true)
        try require(
            rememberedProjectPlan.restoresProject,
            "remembered project launch plan should restore a project"
        )
        try require(
            rememberedProjectPlan.targetProjectURL == projectURL.standardizedFileURL,
            "remembered project launch plan target URL mismatch"
        )
        try require(
            rememberedProjectPlan.visualCacheURL == projectURL.standardizedFileURL,
            "remembered project launch plan visual cache URL mismatch"
        )
        try require(
            rememberedProjectPlan.expectedTrackCount == trackCount,
            "remembered project launch plan did not preserve first-paint track count"
        )
        try require(
            rememberedProjectPlan.windowLayout?.width == 1440,
            "remembered project launch plan did not apply launch overlay window layout before window construction"
        )
        try require(
            rememberedProjectPlan.resolveMilliseconds < launchPlanResolveBudgetMilliseconds,
            String(
                format: "remembered project launch plan exceeded first-paint resolve budget (%.2fms > %.2fms)",
                rememberedProjectPlan.resolveMilliseconds,
                launchPlanResolveBudgetMilliseconds
            )
        )
        let restorableProjectFirstPaintFrame = try requireValue(
            rememberedProjectPlan.firstPaintFrame,
            "launch coordinator did not provide remembered-project first-paint data before window construction"
        )
        try require(
            restorableProjectFirstPaintFrame.projectURL == projectURL.standardizedFileURL,
            "remembered-project first-paint frame used the wrong project URL"
        )
        try require(
            restorableProjectFirstPaintFrame.tracks.count == trackCount,
            "remembered-project first-paint frame did not preserve the cached track count"
        )

        let autosaveProject = SoundtimeProject(
            tracks: Array(tracks.prefix(3)).map { draft in
                SoundtimeProject.Track(
                    id: draft.id,
                    editGroupID: draft.editGroupID,
                    name: draft.name,
                    filePath: draft.filePath,
                    volume: draft.volume,
                    isMuted: draft.isMuted,
                    isSoloed: draft.isSoloed
                )
            },
            windowLayout: SoundtimeProject.WindowLayout(x: 77, y: 88, width: 1660, height: 940),
            masterVolume: 0.72,
            timelineViewport: SoundtimeProject.TimelineViewport(startProgress: 0.12, durationProgress: 0.24),
            transcriptDisplayMode: .hidden
        )
        let autosaveURL = try SoundtimeProjectStore.saveAutosave(
            autosaveProject,
            projectURL: projectURL,
            autosaveID: UUID()
        )
        autosaveURLForCleanup = autosaveURL
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 20)],
            ofItemAtPath: autosaveURL.path
        )
        let autosaveTracks = Array(tracks.prefix(3))
        let autosaveSnapshot = ProjectLaunchSnapshot(
            projectURL: autosaveURL,
            windowLayout: autosaveProject.windowLayout,
            timelineViewport: autosaveProject.timelineViewport,
            masterVolume: autosaveProject.masterVolume,
            transcriptDisplayMode: autosaveProject.transcriptDisplayMode ?? .hidden,
            tracks: autosaveTracks
        )
        let autosavePacket = ProjectFirstFrameWaveformPacket(
            projectURL: autosaveURL,
            windowLayout: autosaveSnapshot.windowLayout,
            timelineViewport: autosaveSnapshot.timelineViewport,
            masterVolume: autosaveSnapshot.masterVolume,
            transcriptDisplayMode: autosaveSnapshot.transcriptDisplayMode,
            tracks: autosaveTracks
        )
        let autosaveReadiness = ProjectLaunchReadinessClassifier.summarize(snapshot: autosaveSnapshot)
        let autosavePacketReadiness = ProjectLaunchReadinessClassifier.summarize(packet: autosavePacket)
        let autosaveManifest = ProjectLaunchManifest(
            projectURL: autosaveURL,
            windowLayout: autosaveSnapshot.windowLayout,
            timelineViewport: autosaveSnapshot.timelineViewport,
            masterVolume: autosaveSnapshot.masterVolume,
            transcriptDisplayMode: autosaveSnapshot.transcriptDisplayMode,
            tracks: autosaveTracks,
            snapshotByteCount: nil,
            firstFramePacketByteCount: nil,
            snapshotDrawable: autosaveReadiness.hasAnyDrawableWaveform,
            firstFramePacketDrawable: autosavePacketReadiness.hasAnyDrawableWaveform
        )
        try ProjectLaunchCacheBundleStore.publish(
            manifest: autosaveManifest,
            firstFramePacket: autosavePacket,
            snapshot: autosaveSnapshot,
            for: autosaveURL
        )
        let recoveredAutosavePlan = ProjectLaunchCoordinator.resolveLaunchPlan(restoresLastProject: true)
        let restorableAutosaveFirstPaintFrame = try requireValue(
            recoveredAutosavePlan.firstPaintFrame,
            "launch coordinator did not provide recovered-autosave first-paint data before window construction"
        )
        try require(
            recoveredAutosavePlan.restoresProject,
            "recovered autosave launch plan should restore a project"
        )
        try require(
            recoveredAutosavePlan.targetProjectURL == projectURL.standardizedFileURL,
            "recovered autosave launch plan should hydrate through the remembered saved project"
        )
        try require(
            recoveredAutosavePlan.visualCacheURL == autosaveURL.standardizedFileURL,
            "recovered autosave launch plan should use the newer autosave visual cache"
        )
        try require(
            recoveredAutosavePlan.usesAutosaveRecovery,
            "recovered autosave launch plan should keep autosave recovery enabled"
        )
        try require(
            recoveredAutosavePlan.expectedTrackCount == autosaveTracks.count,
            "recovered autosave launch plan did not preserve autosave first-paint track count"
        )
        try require(
            recoveredAutosavePlan.windowLayout?.width == 1440,
            "recovered autosave launch plan did not apply saved-project launch overlay before window construction"
        )
        try require(
            recoveredAutosavePlan.firstPaintFrame?.projectURL == autosaveURL.standardizedFileURL,
            "recovered autosave launch plan first-paint frame used the wrong visual source"
        )
        try require(
            recoveredAutosavePlan.firstPaintFrame?.tracks[0].isMuted == true &&
                recoveredAutosavePlan.firstPaintFrame?.tracks[2].isSoloed == true,
            "recovered autosave launch plan did not apply saved-project mute/solo overlay to the visual frame"
        )
        try require(
            recoveredAutosavePlan.firstPaintFrame?.masterVolume == 0.66,
            "recovered autosave launch plan did not apply saved-project master-volume overlay to the visual frame"
        )
        try require(
            restorableAutosaveFirstPaintFrame.projectURL == autosaveURL.standardizedFileURL,
            "recovered-autosave first-paint frame used the saved project instead of the newer autosave"
        )
        try require(
            restorableAutosaveFirstPaintFrame.tracks.count == autosaveTracks.count,
            "recovered-autosave first-paint frame did not preserve the autosave track count"
        )
        try require(
            restorableAutosaveFirstPaintFrame.windowLayout?.width == 1440,
            "recovered-autosave first-paint frame did not apply the saved-project launch overlay"
        )
        try require(
            loadedFirstFramePacket.tracks.allSatisfy {
                ($0.displayOverview?.binCount ?? 0) <= ProjectFirstFrameWaveformPacket.maximumOverviewBinCount
            },
            "first-frame packet did not cap waveform preview bins under the renderer sync budget"
        )
        var partialPacket = ProjectFirstFrameWaveformPacket(
            projectURL: driftProjectURL,
            windowLayout: nil,
            timelineViewport: nil,
            masterVolume: nil,
            transcriptDisplayMode: .hidden,
            tracks: Array(tracks.prefix(3))
        )
        partialPacket.tracks[0].displayOverview = nil
        try ProjectFirstFrameWaveformPacketStore.save(partialPacket, for: driftProjectURL)
        let partialLoadedPacket = try requireValue(
            ProjectFirstFrameWaveformPacketStore.loadForFirstPaintIfAvailable(for: driftProjectURL),
            "partial first-frame packet should still load for first paint"
        )
        let partialPacketReadiness = ProjectLaunchReadinessClassifier.summarize(packet: partialLoadedPacket)
        try require(partialPacketReadiness.hasAnyDrawableWaveform, "partial first-frame packet should preserve drawable tracks")
        try require(partialPacketReadiness.blankTrackCount == 0, "duration-backed first-frame packet should avoid blank tracks")

        let snapshotURL = ProjectLaunchSnapshotStore.snapshotURL(for: projectURL)
        let binaryData = try Data(contentsOf: snapshotURL)
        let legacyJSONData = try JSONEncoder().encode(snapshot)
        try require(ProjectLaunchSnapshotBinaryCodec.hasBinaryMagic(binaryData), "snapshot sidecar did not use binary magic")
        try require(
            binaryData.count < legacyJSONData.count,
            "binary snapshot was not smaller than JSON/base64 snapshot"
        )
        let firstPaintSnapshot = ProjectLaunchSnapshotStore.loadForFirstPaintIfAvailable(for: projectURL)
        if binaryData.count <= ProjectLaunchSnapshotStore.firstPaintSynchronousByteLimit {
            let firstPaintSnapshot = try requireValue(
                firstPaintSnapshot,
                "binary snapshot was not available for bounded first-paint load"
            )
            try require(firstPaintSnapshot.tracks.count == trackCount, "first-paint snapshot track count mismatch")
            let snapshotShell = try requireValue(
                ProjectLaunchSnapshotStore.loadShellForFirstPaintIfAvailable(for: projectURL),
                "binary snapshot shell was not available for pre-window visual restore"
            )
            try require(snapshotShell.tracks.count == trackCount, "snapshot shell track count mismatch")
            try require(snapshotShell.tracks[1].isMuted, "snapshot shell dropped muted track state")
            try require(snapshotShell.tracks[2].isSoloed, "snapshot shell dropped soloed track state")
            try require(
                snapshotShell.clipGraphDocument?.graph.tracks.first?.clips.first?.timelineRange.startFrame == 12_000,
                "snapshot shell dropped canonical clip placement geometry"
            )
            try require(
                snapshotShell.tracks.allSatisfy { $0.displayOverview == nil && $0.sourceOverview == nil },
                "snapshot shell should not decode waveform payloads"
            )
        } else {
            try require(
                firstPaintSnapshot == nil,
                "oversized binary snapshot should not load on the synchronous first-paint path"
            )
        }

        try Data("first-paint drift original".utf8).write(to: driftProjectURL, options: [.atomic])
        let driftSnapshot = ProjectLaunchSnapshot(
            projectURL: driftProjectURL,
            windowLayout: nil,
            timelineViewport: nil,
            masterVolume: nil,
            transcriptDisplayMode: .hidden,
            tracks: [tracks[0]]
        )
        try ProjectLaunchSnapshotStore.save(driftSnapshot, for: driftProjectURL)
        let driftManifest = ProjectLaunchManifest(
            projectURL: driftProjectURL,
            windowLayout: driftSnapshot.windowLayout,
            timelineViewport: driftSnapshot.timelineViewport,
            masterVolume: driftSnapshot.masterVolume,
            transcriptDisplayMode: driftSnapshot.transcriptDisplayMode,
            tracks: [tracks[0]],
            snapshotByteCount: Self.fileByteCount(ProjectLaunchSnapshotStore.snapshotURL(for: driftProjectURL)),
            firstFramePacketByteCount: nil,
            snapshotDrawable: true,
            firstFramePacketDrawable: false
        )
        try ProjectLaunchManifestStore.save(driftManifest, for: driftProjectURL)
        try require(
            ProjectLaunchManifestStore.load(for: driftProjectURL) != nil,
            "launch manifest should load before project metadata drift"
        )
        let driftSnapshotURL = ProjectLaunchSnapshotStore.snapshotURL(for: driftProjectURL)
        let driftSnapshotBytes = try Data(contentsOf: driftSnapshotURL).count
        try Data("first-paint drift modified".utf8).write(to: driftProjectURL, options: [.atomic])
        try require(
            ProjectLaunchManifestStore.load(for: driftProjectURL) == nil,
            "launch manifest should reject project metadata drift"
        )
        if driftSnapshotBytes <= ProjectLaunchSnapshotStore.firstPaintSynchronousByteLimit {
            try require(
                ProjectLaunchSnapshotStore.loadForFirstPaintIfAvailable(for: driftProjectURL) == nil,
                "first-paint snapshot should reject project metadata drift"
            )
        }

        var loadDurations: [Double] = []
        for _ in 0..<5 {
            let startedAt = CACurrentMediaTime()
            let loadedSnapshot = try ProjectLaunchSnapshotStore.load(for: projectURL)
            let durationMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
            loadDurations.append(durationMilliseconds)
            try require(loadedSnapshot.tracks.count == trackCount, "loaded snapshot track count mismatch")
            try require(loadedSnapshot.isDrawable, "loaded snapshot should be drawable")
            try require(
                loadedSnapshot.tracks.allSatisfy { $0.displayWaveformOverview != nil },
                "loaded snapshot dropped display overviews"
            )
        }

        let averageLoadMilliseconds = loadDurations.reduce(0, +) / Double(max(loadDurations.count, 1))
        let worstLoadMilliseconds = loadDurations.max() ?? 0
        try require(
            averageLoadMilliseconds <= loadBudgetMilliseconds,
            String(format: "average launch snapshot load %.2fms exceeded %.2fms budget", averageLoadMilliseconds, loadBudgetMilliseconds)
        )
        try require(
            worstLoadMilliseconds <= loadBudgetMilliseconds * 1.75,
            String(format: "worst launch snapshot load %.2fms exceeded burst budget", worstLoadMilliseconds)
        )

        try legacyJSONData.write(to: snapshotURL, options: [.atomic])
        try require(
            ProjectLaunchSnapshotStore.loadForFirstPaintIfAvailable(for: projectURL) == nil,
            "legacy JSON snapshot should not load on the synchronous first-paint path"
        )
        let legacyLoaded = try ProjectLaunchSnapshotStore.load(for: projectURL)
        try require(legacyLoaded.tracks.count == trackCount, "legacy JSON snapshot fallback failed")

        try ProjectLaunchSnapshotStore.save(snapshot, for: projectURL)
        let firstSourceURL = URL(fileURLWithPath: tracks[0].filePath)
        try Data("stale source".utf8).write(to: firstSourceURL, options: [.atomic])
        let firstPaintBlankTracksAfterStaleSource: String
        if binaryData.count <= ProjectLaunchSnapshotStore.firstPaintSynchronousByteLimit {
            let staleFirstPaintSnapshot = try requireValue(
                ProjectLaunchSnapshotStore.loadForFirstPaintIfAvailable(for: projectURL),
                "unchanged-project stale-source snapshot should still be available for first paint"
            )
            let staleFirstPaintTrack = try requireValue(
                staleFirstPaintSnapshot.tracks.first,
                "stale-source first-paint snapshot dropped first track"
            )
            try require(
                staleFirstPaintTrack.displayOverview != nil || staleFirstPaintTrack.sourceOverview != nil,
                "stale-source first-paint path stripped cached waveform previews"
            )
            let staleFirstPaintReadiness = ProjectLaunchReadinessClassifier.summarize(
                snapshot: staleFirstPaintSnapshot
            )
            try require(
                staleFirstPaintReadiness.isFirstFrameUsable,
                "stale-source first-paint path should preserve a usable visual shell"
            )
            firstPaintBlankTracksAfterStaleSource = "\(staleFirstPaintReadiness.blankTrackCount)"
        } else {
            try require(
                ProjectLaunchSnapshotStore.loadForFirstPaintIfAvailable(for: projectURL) == nil,
                "oversized stale-source snapshot should remain outside first-paint loading"
            )
            firstPaintBlankTracksAfterStaleSource = "skipped-oversized"
        }

        let staleLoaded = try ProjectLaunchSnapshotStore.load(for: projectURL)
        let staleTrack = try requireValue(staleLoaded.tracks.first, "stale-source snapshot dropped first track")
        try require(staleTrack.sourceOverview == nil, "stale source overview was not stripped")
        try require(staleTrack.displayOverview == nil, "stale display overview was not stripped")
        let staleReadiness = ProjectLaunchReadinessClassifier.summarize(snapshot: staleLoaded)
        try require(staleReadiness.blankTrackCount == 1, "stale source should be classified as a blank launch track")
        try require(!staleReadiness.isFirstFrameUsable, "stale blank source should not be first-frame usable")
        try require(
            staleLoaded.tracks.dropFirst().allSatisfy { $0.displayWaveformOverview != nil },
            "stale source validation stripped unrelated tracks"
        )

        LaunchStartupTrace.shared.resetForSmokeTesting()
        LaunchStartupTrace.shared.mark(.processEntry, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.mark(.launchPlanResolved, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.mark(.mainWindowControllerInitStart, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.mark(.windowFrameChosen, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.mark(.workspaceFirstPaintInstalled, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.mark(.windowVisible, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.mark(.firstFrameWaveformPacketLoaded, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.mark(.firstFrameWaveformPacketInstalled, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.mark(.visualSkeletonApplied, fields: snapshotReadiness.diagnosticFields, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.markOnce(.firstTimelineRenderSubmitted, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.markOnce(.firstWaveformVisibleFrame, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.markOnce(.firstWaveformVisibleFrame, recordsDiagnosticEvent: false)
        let launchTraceEvents = LaunchStartupTrace.shared.snapshot()
        try require(
            launchTraceEvents.map(\.milestone) == [
                .processEntry,
                .launchPlanResolved,
                .mainWindowControllerInitStart,
                .windowFrameChosen,
                .workspaceFirstPaintInstalled,
                .windowVisible,
                .firstFrameWaveformPacketLoaded,
                .firstFrameWaveformPacketInstalled,
                .visualSkeletonApplied,
                .firstTimelineRenderSubmitted,
                .firstWaveformVisibleFrame,
            ],
            "launch trace milestones were not recorded in order"
        )
        try require(
            launchTraceEvents.last?.elapsedMilliseconds ?? -1 >= 0,
            "launch trace did not produce elapsed timing"
        )
        let visualSkeletonEvent = try requireValue(
            launchTraceEvents.first { $0.milestone == .visualSkeletonApplied },
            "launch trace did not include visual skeleton timing"
        )
        try require(
            visualSkeletonEvent.fields["tracks"] == "\(trackCount)",
            "visual skeleton trace did not preserve the expected track count"
        )
        try require(
            visualSkeletonEvent.fields["blank"] == "0",
            "visual skeleton trace allowed blank first-paint tracks"
        )
        try require(
            visualSkeletonEvent.fields["allWaveformsDrawable"] == "true",
            "visual skeleton trace did not require drawable cached waveforms"
        )
        try require(
            visualSkeletonEvent.fields["firstFrameUsable"] == "true",
            "visual skeleton trace did not require a usable first frame"
        )

        LaunchStartupTrace.shared.resetForSmokeTesting()
        LaunchStartupTrace.shared.mark(.windowCloseRequested, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.mark(
            .windowClosePrepared,
            fields: [
                "launchSnapshotWrite": "false",
                "firstFramePacketWrite": "false",
            ],
            recordsDiagnosticEvent: false
        )
        LaunchStartupTrace.shared.mark(
            .windowCloseStatePersisted,
            fields: [
                "launchSnapshotWrite": "false",
                "firstFramePacketWrite": "false",
            ],
            recordsDiagnosticEvent: false
        )
        LaunchStartupTrace.shared.mark(
            .windowCloseFinished,
            fields: [
                "launchSnapshotWrite": "false",
                "firstFramePacketWrite": "false",
            ],
            recordsDiagnosticEvent: false
        )
        LaunchStartupTrace.shared.mark(.appTerminateStarted, recordsDiagnosticEvent: false)
        LaunchStartupTrace.shared.mark(
            .appTerminateFinished,
            fields: [
                "launchSnapshotWrite": "false",
                "firstFramePacketWrite": "false",
            ],
            recordsDiagnosticEvent: false
        )
        let closeTraceEvents = LaunchStartupTrace.shared.snapshot()
        try require(
            closeTraceEvents.map(\.milestone) == [
                .windowCloseRequested,
                .windowClosePrepared,
                .windowCloseStatePersisted,
                .windowCloseFinished,
                .appTerminateStarted,
                .appTerminateFinished,
            ],
            "close trace milestones were not recorded in order"
        )
        let closeCriticalEvents = closeTraceEvents.filter {
            [
                .windowClosePrepared,
                .windowCloseStatePersisted,
                .windowCloseFinished,
                .appTerminateFinished,
            ].contains($0.milestone)
        }
        try require(
            closeCriticalEvents.allSatisfy {
                $0.fields["launchSnapshotWrite"] == "false" &&
                    $0.fields["firstFramePacketWrite"] == "false"
            },
            "close trace allowed synchronous launch waveform cache writes"
        )

        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "launch-performance-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: [
                "binary launch snapshot sidecars replace JSON/base64 waveform payloads",
                "bounded first-paint path loads only compact binary launch snapshots",
                "legacy JSON launch snapshots still load",
                "per-track source validation strips stale previews",
                "launch visual readiness distinguishes drawable, placeholder, and blank tracks",
                "playback prime restores file-backed audio without waveform or zero-crossing work",
                "preview-less projects recover drawable launch waveforms from disk cache",
                "launch startup trace records ordered first-frame milestones",
                "snapshot load time remains inside startup budget",
                "first-paint launch snapshots preserve cached previews while deferring per-track source validation",
                "first-paint launch snapshots reject saved-project metadata drift",
                "first-frame waveform packets are small binary sidecars",
                "first-frame waveform packets cap previews under the synchronous renderer budget",
                "partial first-frame waveform packets preserve drawable tracks instead of rejecting the whole project",
                "tiny launch manifests restore track shells and mute/solo state before waveform payloads",
                "tiny launch manifests reject saved-project metadata drift",
                "lightweight launch state overlay preserves close-time UI state without waveform cache writes",
                "launch coordinator applies overlay state before first-frame rendering",
                "launch plan resolves final project target, visual cache, and first-paint track count before window construction",
                "recovered autosave launch uses autosave visuals while preserving saved-project UI state",
                "startup trace rejects placeholder-before-project launch ordering",
                "atomic launch cache generation publishes manifest, packet, and snapshot coherently",
                "launch coordinator can recover first-paint data from the atomic cache when legacy sidecars are stale",
                "launch trace rejects blank/placeholder first-paint skeletons",
                "close trace proves synchronous close skips waveform cache writes",
            ],
            metadata: [
                "tracks": "\(trackCount)",
                "binsPerTrack": "\(binCount)",
                "binaryBytes": "\(binaryData.count)",
                "firstFramePacketBytes": "\(packetData.count)",
                "launchGenerationManifestBytes": "\(publishedGeneration.manifestByteCount)",
                "launchGenerationPacketBytes": "\(publishedGeneration.firstFramePacketByteCount ?? 0)",
                "launchGenerationSnapshotBytes": "\(publishedGeneration.snapshotByteCount ?? 0)",
                "firstFramePacketMaxBins": "\(ProjectFirstFrameWaveformPacket.maximumOverviewBinCount(forTrackCount: trackCount))",
                "firstPaintByteLimit": "\(ProjectFirstFrameWaveformPacketStore.firstPaintSynchronousByteLimit)",
                "legacyJSONBytes": "\(legacyJSONData.count)",
                "drawableWaveformTracks": "\(snapshotReadiness.drawableWaveformTrackCount)",
                "packetDrawableWaveformTracks": "\(packetReadiness.drawableWaveformTrackCount)",
                "durationOnlyTracks": "\(durationOnlyReadiness.durationOnlyTrackCount)",
                "playbackPrimeMs": String(format: "%.2f", playbackPrime.elapsedMilliseconds),
                "playbackPrimeTracks": "\(playbackPrime.tracks.count)",
                "cachedPreviewDrawableTracks": "\(cachedPreviewReadiness.drawableWaveformTrackCount)",
                "firstPaintBlankTracksAfterStaleSource": firstPaintBlankTracksAfterStaleSource,
                "blankTracksAfterStaleValidation": "\(staleReadiness.blankTrackCount)",
                "averageLoadMs": String(format: "%.2f", averageLoadMilliseconds),
                "worstLoadMs": String(format: "%.2f", worstLoadMilliseconds),
            ],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }

        print(
            String(
                format: "Soundtime launch performance smoke passed: %d tracks, %.2fms avg snapshot load",
                trackCount,
                averageLoadMilliseconds
            )
        )
    }

    private static func syntheticOverview(duration: TimeInterval, binCount: Int) -> WaveformOverview {
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount)
        for index in 0..<binCount {
            let phase = Float(index) / Float(max(binCount - 1, 1))
            let peak = min(max(abs(sin(phase * 23.0) * 0.20 + sin(phase * 317.0) * 0.07) + 0.02, 0.01), 0.95)
            bins.append(WaveformOverview.Bin(
                minimumSample: -peak,
                maximumSample: peak,
                rmsSample: peak * 0.52
            ))
        }
        return WaveformOverview(duration: duration, bins: bins)
    }

    private static func syntheticAudioBuffer(
        url: URL,
        frameCount: Int,
        sampleRate: Double
    ) -> DecodedAudioBuffer {
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            let phase = Double(frame) / sampleRate
            left.append(Float(sin(phase * 440.0 * Double.pi * 2.0) * 0.20))
            right.append(Float(sin(phase * 660.0 * Double.pi * 2.0) * 0.18))
        }
        return DecodedAudioBuffer(
            url: url,
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [left, right]
        )
    }

    private static func fileByteCount(_ url: URL) -> Int? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let byteCount = (attributes[.size] as? NSNumber)?.intValue
        else {
            return nil
        }
        return byteCount
    }

    private static func requireValue<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else {
            throw SmokeError.failed(message)
        }
        return value
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SmokeError.failed(message)
        }
    }
}
