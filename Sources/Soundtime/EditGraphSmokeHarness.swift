import Foundation

enum EditGraphSmokeHarness {
    enum SmokeError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let sampleRate = 48_000.0
        let sourceFrameCount = Int(sampleRate) * 60 * 60 * 2
        let sourceURL = URL(fileURLWithPath: "/tmp/SoundtimeEditGraphSmoke.wav")
        let fileInfo = WAVFileInfo(
            url: sourceURL,
            formatTag: 1,
            channelCount: 2,
            sampleRate: sampleRate,
            blockAlign: 4,
            bitsPerSample: 16,
            dataRange: 44..<(44 + sourceFrameCount * 4)
        )

        var timeline = AudioFileEditTimeline(fileInfo: fileInfo)
        let pasteClip = try requireValue(
            timeline.clip(for: TimelineSelection(startProgress: 0.018, endProgress: 0.0192)),
            "edit graph smoke could not prepare paste clip"
        )
        let operationCount = arguments.contains("--edit-graph-smoke-full") ? 1_500 : 640
        let startTime = DispatchTime.now().uptimeNanoseconds
        var touchedFrameCount = 0
        var deletedFrameCount = 0
        var operationDurations: [Double] = []
        var operationDurationsByName: [String: [Double]] = [:]
        operationDurations.reserveCapacity(operationCount)

        for index in 0..<operationCount {
            let startProgress = Double((index * 7_919) % 850_000) / 1_000_000.0
            let durationProgress = 0.000_06 + Double(index % 9) * 0.000_012
            let selection = TimelineSelection(
                startProgress: startProgress,
                endProgress: min(startProgress + durationProgress, 0.995)
            )

            let operationStartTime = DispatchTime.now().uptimeNanoseconds
            let operationName: String
            switch index % 10 {
            case 0:
                operationName = "delete"
                let removedFrameCount = timeline.delete(selection)
                touchedFrameCount += removedFrameCount
                deletedFrameCount += removedFrameCount
            case 1:
                operationName = "gain-down"
                touchedFrameCount += timeline.applyGain(0.72, to: selection)
            case 2:
                operationName = "gain-up"
                touchedFrameCount += timeline.applyGain(1.18, to: selection)
            case 3:
                operationName = "fade-in"
                touchedFrameCount += timeline.applyFade(.fadeIn, to: selection)
            case 4:
                operationName = "fade-out"
                touchedFrameCount += timeline.applyFade(.fadeOut, to: selection)
            case 5:
                operationName = "paste"
                touchedFrameCount += timeline.replace(selection, with: pasteClip) ?? 0
            case 6:
                operationName = "clear"
                touchedFrameCount += timeline.clear(selection)
            case 7:
                operationName = "copy"
                touchedFrameCount += timeline.clip(for: selection)?.frameCount ?? 0
            case 8:
                operationName = "split"
                touchedFrameCount += timeline.split(atProgress: selection.startProgress) ? 1 : 0
            default:
                operationName = "gain-boost"
                touchedFrameCount += timeline.applyGain(1.36, to: selection)
            }
            let operationMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - operationStartTime) / 1_000_000
            operationDurations.append(operationMilliseconds)
            operationDurationsByName[operationName, default: []].append(operationMilliseconds)
        }

        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000
        let p95OperationMilliseconds = percentile(operationDurations, percentile: 0.95)
        let maximumOperationMilliseconds = operationDurations.max() ?? 0
        let state = try requireValue(timeline.persistentState, "edit graph did not persist")
        try require(touchedFrameCount > 0, "edit graph operations touched no frames")
        try require(deletedFrameCount > 0, "delete operations did not remove frames")
        try require(state.segments.count < operationCount * 4, "edit graph segment count exploded: \(state.segments.count)")
        try require(
            p95OperationMilliseconds < 2.0,
            String(format: "edit graph operation p95 was too slow: %.2fms", p95OperationMilliseconds)
        )
        try require(
            maximumOperationMilliseconds < 12,
            String(format: "edit graph operation outlier was too slow: %.2fms", maximumOperationMilliseconds)
        )
        try require(
            elapsedMilliseconds < 1_500,
            String(format: "edit graph operations were too slow: %.2fms", elapsedMilliseconds)
        )
        try requirePerOperationBudgets(operationDurationsByName)
        try runFileClipPasteSmoke(fileInfo: fileInfo)
        try runNormalizedAudioSourceEquivalenceSmoke(fileInfo: fileInfo)
        try runSharedEditableSourceCatalogSmoke(fileInfo: fileInfo)
        try runEditGraphArrangementMutationSmoke(fileInfo: fileInfo)
        try runCurrentEditGroupModelSmoke()
        try runLinkedRippleDeleteSmoke(fileInfo: fileInfo)
        try runSplitPersistenceSmoke(fileInfo: fileInfo)
        try runSilenceAnalyzerSmoke()
        try runPodcastExportProcessorSmoke()

        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "edit-graph-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: [
                "mixed edit operations stay below latency budget",
                "edit graph segment count stays bounded",
                "file clip paste preserves edit timelines",
                "WAV originals and MP3 proxies normalize to the same edit graph shape",
                "shared editable sources canonicalize without duplicate-key crashes",
                "edit graph mutations keep source identity stable while arrangements change",
                "loaded project edit groups normalize to one linked ripple group",
                "linked ripple delete preserves grouped track timing",
                "split persistence survives project state round-trip",
                "silence analyzer and podcast export processors smoke-test",
            ],
            metadata: [
                "operationCount": "\(operationCount)",
                "segmentCount": "\(state.segments.count)",
                "touchedFrameCount": "\(touchedFrameCount)",
                "deletedFrameCount": "\(deletedFrameCount)",
                "operationP95Milliseconds": String(format: "%.3f", p95OperationMilliseconds),
                "operationMaxMilliseconds": String(format: "%.3f", maximumOperationMilliseconds),
                "elapsedMilliseconds": String(format: "%.3f", elapsedMilliseconds),
            ],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }

        print(
            String(
                format: "Soundtime edit graph smoke passed: %d ops, %d segments, %.3fms p95 op, %.3fms max op, %.2fms total",
                operationCount,
                state.segments.count,
                p95OperationMilliseconds,
                maximumOperationMilliseconds,
                elapsedMilliseconds
            )
        )
    }

    private static func requirePerOperationBudgets(_ operationDurationsByName: [String: [Double]]) throws {
        for (operationName, durations) in operationDurationsByName.sorted(by: { $0.key < $1.key }) {
            let p95Milliseconds = percentile(durations, percentile: 0.95)
            let maxMilliseconds = durations.max() ?? 0
            try require(
                p95Milliseconds < 2.5,
                String(format: "%@ p95 was too slow: %.2fms", operationName, p95Milliseconds)
            )
            try require(
                maxMilliseconds < 14,
                String(format: "%@ outlier was too slow: %.2fms", operationName, maxMilliseconds)
            )
        }
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else {
            return 0
        }

        let sortedValues = values.sorted()
        let clampedPercentile = min(max(percentile, 0), 1)
        let index = min(
            max(Int((Double(sortedValues.count - 1) * clampedPercentile).rounded()), 0),
            sortedValues.count - 1
        )
        return sortedValues[index]
    }

    private static func runFileClipPasteSmoke(fileInfo: WAVFileInfo) throws {
        var timeline = AudioFileEditTimeline(fileInfo: fileInfo)
        let gainedSelection = TimelineSelection(startProgress: 0.10, endProgress: 0.18)
        let copiedSelection = TimelineSelection(startProgress: 0.12, endProgress: 0.145)
        let insertionSelection = TimelineSelection(startProgress: 0.62, endProgress: 0.62)

        let gainedFrameCount = timeline.applyGain(0.42, to: gainedSelection)
        try require(gainedFrameCount > 0, "file clip smoke gain touched no frames")

        let frameCountBeforePaste = timeline.frameCount
        let clip = try requireValue(timeline.clip(for: copiedSelection), "file clip smoke could not copy clip")
        try require(clip.frameCount > 0, "file clip smoke copied an empty clip")
        try require(
            clip.segments.contains { segment in
                segment.gainStart < 0.99 || segment.gainEnd < 0.99
            },
            "file clip smoke did not preserve selected gain"
        )

        let insertedFrameCount = try requireValue(
            timeline.replace(insertionSelection, with: clip),
            "file clip smoke could not paste clip"
        )
        try require(insertedFrameCount == clip.frameCount, "file clip smoke inserted an unexpected frame count")
        try require(
            timeline.frameCount == frameCountBeforePaste + clip.frameCount,
            "file clip smoke did not splice the pasted clip into the edit graph"
        )

        let state = try requireValue(timeline.persistentState, "file clip smoke did not persist")
        let restoredTimeline = try requireValue(
            AudioFileEditTimeline(persistentState: state),
            "file clip smoke could not restore persisted edit graph"
        )
        try require(
            restoredTimeline.frameCount == timeline.frameCount,
            "file clip smoke persisted the wrong frame count"
        )
    }

    private static func runNormalizedAudioSourceEquivalenceSmoke(fileInfo: WAVFileInfo) throws {
        let wavTrackID = UUID()
        let mp3TrackID = UUID()
        let originalMP3URL = URL(fileURLWithPath: "/tmp/SoundtimeNormalizedSourceSmoke.mp3")
        let proxyURL = URL(fileURLWithPath: "/tmp/SoundtimeNormalizedSourceSmoke.proxy.wav")
        let proxyFileInfo = WAVFileInfo(
            url: proxyURL,
            formatTag: fileInfo.formatTag,
            channelCount: fileInfo.channelCount,
            sampleRate: fileInfo.sampleRate,
            blockAlign: fileInfo.blockAlign,
            bitsPerSample: fileInfo.bitsPerSample,
            dataRange: fileInfo.dataRange
        )

        let wavSource = EditableAudioSource(
            originalURL: fileInfo.url,
            editableURL: fileInfo.url,
            formatOrigin: .wav,
            fileInfo: fileInfo,
            ownsEditableFile: false
        )
        let mp3ProxySource = EditableAudioSource(
            originalURL: originalMP3URL,
            editableURL: proxyURL,
            formatOrigin: .mp3,
            fileInfo: proxyFileInfo,
            ownsEditableFile: true
        )

        try require(wavSource.isUsableForEditing, "WAV source was not usable for editing")
        try require(mp3ProxySource.isUsableForEditing, "MP3 proxy source was not usable for editing")

        var wavArrangement = TrackArrangement(
            trackID: wavTrackID,
            sourceID: wavSource.id,
            timeline: AudioFileEditTimeline(fileInfo: fileInfo)
        )
        var mp3Arrangement = TrackArrangement(
            trackID: mp3TrackID,
            sourceID: mp3ProxySource.id,
            timeline: AudioFileEditTimeline(fileInfo: proxyFileInfo)
        )

        try require(wavSource.isCompatible(with: wavArrangement.timeline), "WAV source did not match its timeline")
        try require(
            mp3ProxySource.isCompatible(with: mp3Arrangement.timeline),
            "MP3 proxy source did not match its timeline"
        )
        try require(
            wavArrangement.clipSegments.map(\.frameCount) == mp3Arrangement.clipSegments.map(\.frameCount),
            "normalized arrangements did not start with equivalent segment shapes"
        )

        let selection = TimelineSelection(startProgress: 0.0125, endProgress: 0.01875)
        let wavDelete = wavArrangement.deleting(selection)
        let mp3Delete = mp3Arrangement.deleting(selection)
        wavArrangement = wavDelete.arrangement
        mp3Arrangement = mp3Delete.arrangement

        try require(wavDelete.deletedFrameCount > 0, "WAV normalized delete removed no frames")
        try require(mp3Delete.deletedFrameCount > 0, "MP3 proxy normalized delete removed no frames")
        try require(
            wavDelete.deletedFrameCount == mp3Delete.deletedFrameCount,
            "WAV and MP3 proxy deletes removed different frame counts"
        )
        try require(
            wavArrangement.frameCount == mp3Arrangement.frameCount,
            "WAV and MP3 proxy arrangements diverged after equivalent delete"
        )
        try require(
            !wavArrangement.clipSegments.isEmpty && !mp3Arrangement.clipSegments.isEmpty,
            "normalized delete removed all arrangement segments unexpectedly"
        )

        let graph = EditGraph(
            sources: [wavSource, mp3ProxySource],
            arrangements: [wavArrangement, mp3Arrangement]
        )
        try require(graph.sources[wavSource.id] != nil, "edit graph lost WAV editable source")
        try require(graph.sources[mp3ProxySource.id] != nil, "edit graph lost MP3 proxy editable source")
        try require(graph.arrangement(for: wavTrackID)?.frameCount == wavArrangement.frameCount, "edit graph lost WAV arrangement")
        try require(
            graph.arrangement(for: mp3TrackID)?.frameCount == mp3Arrangement.frameCount,
            "edit graph lost MP3 proxy arrangement"
        )

        let repeatedMP3ProxySource = EditableAudioSource(
            originalURL: originalMP3URL,
            editableURL: proxyURL,
            formatOrigin: .mp3,
            fileInfo: proxyFileInfo,
            ownsEditableFile: true
        )
        try require(
            repeatedMP3ProxySource.id == mp3ProxySource.id,
            "editable source ID was not stable for the same normalized proxy"
        )
    }

    private static func runSharedEditableSourceCatalogSmoke(fileInfo: WAVFileInfo) throws {
        let importedAssetID = UUID()
        let source = EditableAudioSource(
            importedAssetID: importedAssetID,
            originalURL: fileInfo.url,
            editableURL: fileInfo.url,
            formatOrigin: .wav,
            fileInfo: fileInfo,
            ownsEditableFile: false
        )
        let repeatedSource = EditableAudioSource(
            importedAssetID: importedAssetID,
            originalURL: fileInfo.url,
            editableURL: fileInfo.url,
            formatOrigin: .wav,
            fileInfo: fileInfo,
            ownsEditableFile: true
        )
        let separateImport = EditableAudioSource(
            importedAssetID: UUID(),
            originalURL: fileInfo.url,
            editableURL: fileInfo.url,
            formatOrigin: .wav,
            fileInfo: fileInfo,
            ownsEditableFile: false
        )
        let firstTrackID = UUID()
        let secondTrackID = UUID()
        let firstArrangement = TrackArrangement(
            trackID: firstTrackID,
            sourceID: source.id,
            timeline: AudioFileEditTimeline(fileInfo: fileInfo)
        )
        let secondArrangement = TrackArrangement(
            trackID: secondTrackID,
            sourceID: repeatedSource.id,
            timeline: AudioFileEditTimeline(fileInfo: fileInfo)
        )

        try require(
            repeatedSource.id == source.id,
            "shared editable source smoke did not create matching stable IDs"
        )
        try require(
            separateImport.id != source.id,
            "separate logical imports unexpectedly shared an editable source ID"
        )

        let graph = EditGraph(
            sources: [source, repeatedSource],
            arrangements: [firstArrangement, secondArrangement]
        )
        try require(graph.sources.count == 1, "shared editable source smoke did not canonicalize duplicate sources")
        try require(
            graph.arrangement(for: firstTrackID)?.sourceID == source.id,
            "shared editable source smoke lost the first shared-source arrangement"
        )
        try require(
            graph.arrangement(for: secondTrackID)?.sourceID == source.id,
            "shared editable source smoke lost the second shared-source arrangement"
        )
        try require(
            graph.source(for: secondTrackID)?.ownsEditableFile == true,
            "shared editable source smoke did not keep the richer canonical source ownership"
        )
    }

    private static func runEditGraphArrangementMutationSmoke(fileInfo: WAVFileInfo) throws {
        let trackID = UUID()
        let removedTrackID = UUID()
        let source = EditableAudioSource(
            originalURL: fileInfo.url,
            editableURL: fileInfo.url,
            formatOrigin: .wav,
            fileInfo: fileInfo,
            ownsEditableFile: false
        )
        let removableSource = EditableAudioSource(
            originalURL: URL(fileURLWithPath: "/tmp/SoundtimeEditGraphRemoved.mp3"),
            editableURL: URL(fileURLWithPath: "/tmp/SoundtimeEditGraphRemoved.proxy.wav"),
            formatOrigin: .mp3,
            fileInfo: fileInfo,
            ownsEditableFile: true
        )
        var timeline = AudioFileEditTimeline(fileInfo: fileInfo)
        let originalFrameCount = timeline.frameCount
        let sourceID = source.id
        var graph = EditGraph(
            sources: [source, removableSource],
            arrangements: [
                TrackArrangement(trackID: trackID, sourceID: sourceID, timeline: timeline),
                TrackArrangement(trackID: removedTrackID, sourceID: removableSource.id, timeline: AudioFileEditTimeline(fileInfo: fileInfo)),
            ]
        )

        let deleteSelection = TimelineSelection(startProgress: 0.10, endProgress: 0.12)
        let deleted = try requireValue(
            graph.arrangement(for: trackID)?.deleting(deleteSelection),
            "edit graph mutation smoke could not prepare delete"
        )
        try require(deleted.deletedFrameCount > 0, "edit graph mutation smoke delete removed no frames")
        _ = graph.updateArrangement(trackID: trackID, timeline: deleted.arrangement.timeline)
        let afterDelete = try requireValue(
            graph.arrangement(for: trackID),
            "edit graph mutation smoke lost arrangement after delete"
        )
        try require(afterDelete.sourceID == sourceID, "delete changed source identity")
        try require(
            afterDelete.frameCount == originalFrameCount - deleted.deletedFrameCount,
            "delete changed arrangement frame count incorrectly"
        )
        try require(graph.source(for: trackID)?.id == sourceID, "delete lost editable source")

        timeline = afterDelete.timeline
        let duplicateClip = try requireValue(
            timeline.clip(for: TimelineSelection(startProgress: 0.20, endProgress: 0.215)),
            "edit graph mutation smoke could not copy duplicate clip"
        )
        let frameCountBeforePaste = timeline.frameCount
        let insertedFrameCount = try requireValue(
            timeline.replace(TimelineSelection(startProgress: 0.50, endProgress: 0.50), with: duplicateClip),
            "edit graph mutation smoke could not insert duplicate clip"
        )
        _ = graph.updateArrangement(trackID: trackID, timeline: timeline)
        let afterPaste = try requireValue(
            graph.arrangement(for: trackID),
            "edit graph mutation smoke lost arrangement after paste"
        )
        try require(afterPaste.sourceID == sourceID, "paste changed source identity")
        try require(insertedFrameCount == duplicateClip.frameCount, "paste inserted unexpected frame count")
        try require(
            afterPaste.frameCount == frameCountBeforePaste + duplicateClip.frameCount,
            "paste did not grow arrangement by inserted clip length"
        )

        graph.keepOnlyArrangements(for: [trackID])
        try require(graph.arrangement(for: trackID) != nil, "prune removed the kept arrangement")
        try require(graph.arrangement(for: removedTrackID) == nil, "prune kept a removed arrangement")
        try require(graph.source(for: trackID)?.id == sourceID, "prune removed the live source")
        try require(
            graph.sources[removableSource.id] == nil,
            "prune kept an unreferenced editable source"
        )
    }

    private static func runCurrentEditGroupModelSmoke() throws {
        let projectGroup = UUID(uuidString: "4D329E50-D23F-4763-B378-189A1922841C") ?? UUID()
        let accidentalLoadGroup = UUID(uuidString: "6AC9C187-433B-4B3E-BA91-5AC6A1B3ABDB") ?? UUID()
        let freshDefaultGroup = UUID(uuidString: "99999999-aaaa-bbbb-cccc-dddddddddddd") ?? UUID()

        let splitGroups: [UUID?] = [
            projectGroup,
            projectGroup,
            accidentalLoadGroup,
        ]
        let primaryGroupID = EditGroupModel.primaryGroupID(
            from: splitGroups,
            fallback: freshDefaultGroup
        )
        try require(
            primaryGroupID == projectGroup,
            "current edit group model did not choose the loaded project's dominant group"
        )
        try require(
            EditGroupModel.needsNormalization(splitGroups, fallback: freshDefaultGroup),
            "current edit group model did not detect split loaded groups"
        )
        let normalizedGroups = EditGroupModel.normalizedGroupIDs(
            from: splitGroups,
            fallback: freshDefaultGroup
        )
        try require(
            normalizedGroups == [projectGroup, projectGroup, projectGroup],
            "current edit group model did not heal accidental split groups"
        )

        let missingGroups: [UUID?] = [nil, nil]
        try require(
            EditGroupModel.primaryGroupID(from: missingGroups, fallback: freshDefaultGroup) == freshDefaultGroup,
            "current edit group model should use fallback for legacy tracks without groups"
        )
        try require(
            EditGroupModel.normalizedGroupIDs(from: missingGroups, fallback: freshDefaultGroup) ==
                [freshDefaultGroup, freshDefaultGroup],
            "current edit group model should normalize legacy tracks to the fallback group"
        )
    }

    private static func runLinkedRippleDeleteSmoke(fileInfo: WAVFileInfo) throws {
        let shortFrameCount = Int((fileInfo.sampleRate * 30).rounded())
        let shortFileInfo = WAVFileInfo(
            url: URL(fileURLWithPath: "/tmp/SoundtimeLinkedRippleDeleteSmokeShort.wav"),
            formatTag: fileInfo.formatTag,
            channelCount: fileInfo.channelCount,
            sampleRate: fileInfo.sampleRate,
            blockAlign: fileInfo.blockAlign,
            bitsPerSample: fileInfo.bitsPerSample,
            dataRange: 44..<(44 + shortFrameCount * Int(fileInfo.blockAlign))
        )
        var hostTimeline = AudioFileEditTimeline(fileInfo: fileInfo)
        var guestTimeline = AudioFileEditTimeline(fileInfo: shortFileInfo)
        let startTime = 8.0
        let endTime = 9.25
        let expectedDeletedFrameCount = Int(((endTime - startTime) * fileInfo.sampleRate).rounded())
        let hostSelection = TimelineSelection(
            startProgress: startTime / hostTimeline.duration,
            endProgress: endTime / hostTimeline.duration
        )
        let guestSelection = TimelineSelection(
            startProgress: startTime / guestTimeline.duration,
            endProgress: endTime / guestTimeline.duration
        )

        let hostFrameCountBeforeDelete = hostTimeline.frameCount
        let guestFrameCountBeforeDelete = guestTimeline.frameCount
        let hostDeletedFrameCount = hostTimeline.delete(hostSelection)
        let guestDeletedFrameCount = guestTimeline.delete(guestSelection)

        try require(
            hostDeletedFrameCount == expectedDeletedFrameCount,
            "linked ripple smoke host deleted an unexpected frame count"
        )
        try require(
            guestDeletedFrameCount == expectedDeletedFrameCount,
            "linked ripple smoke guest deleted an unexpected frame count"
        )
        try require(
            hostTimeline.frameCount == hostFrameCountBeforeDelete - expectedDeletedFrameCount,
            "linked ripple smoke host timeline did not shorten correctly"
        )
        try require(
            guestTimeline.frameCount == guestFrameCountBeforeDelete - expectedDeletedFrameCount,
            "linked ripple smoke guest timeline did not shorten correctly"
        )
    }

    private static func runSplitPersistenceSmoke(fileInfo: WAVFileInfo) throws {
        var timeline = AudioFileEditTimeline(fileInfo: fileInfo)
        try require(timeline.split(atProgress: 0.25), "split smoke did not create first clip boundary")
        try require(timeline.split(atProgress: 0.50), "split smoke did not create second clip boundary")
        try require(!timeline.split(atProgress: 0.50), "split smoke split the same boundary twice")

        let state = try requireValue(timeline.persistentState, "split smoke did not persist")
        try require(
            state.segments.filter { $0.startsNewClip == true }.count == 2,
            "split smoke persisted the wrong boundary count"
        )

        let restoredTimeline = try requireValue(
            AudioFileEditTimeline(persistentState: state),
            "split smoke could not restore persisted edit graph"
        )
        let restoredState = try requireValue(restoredTimeline.persistentState, "split smoke restore did not persist")
        try require(
            restoredState.segments.filter { $0.startsNewClip == true }.count == 2,
            "split smoke lost clip boundaries after restore"
        )
        try require(restoredTimeline.frameCount == timeline.frameCount, "split smoke changed timeline length")
    }

    private static func runSilenceAnalyzerSmoke() throws {
        let sampleRate = 1_000.0
        var samples = [Float](repeating: 0.25, count: 1_800)
        for frame in 420..<1_020 {
            samples[frame] = 0.000_1
        }
        for frame in 1_300..<1_360 {
            samples[frame] = 0.000_1
        }
        let buffer = DecodedAudioBuffer(
            url: URL(fileURLWithPath: "/tmp/SoundtimeSilenceAnalyzerSmoke.wav"),
            sampleRate: sampleRate,
            channelCount: 1,
            frameCount: samples.count,
            samplesByChannel: [samples]
        )
        let configuration = AudioSilenceAnalyzer.Configuration(
            thresholdDecibels: -44,
            minimumSilenceDuration: 0.30,
            paddingDuration: 0.10
        )
        let regions = AudioSilenceAnalyzer.detectSilence(in: buffer, configuration: configuration)
        try require(regions.count == 1, "silence analyzer detected unexpected region count: \(regions.count)")
        try require(regions[0].startFrame == 420, "silence analyzer region start mismatch")
        try require(regions[0].endFrame == 1_020, "silence analyzer region end mismatch")

        let deletionRanges = AudioSilenceAnalyzer.deletionRanges(
            for: regions,
            sampleRate: sampleRate,
            configuration: configuration
        )
        try require(deletionRanges == [520..<920], "silence analyzer padding range mismatch")

        let roomToneConfiguration = AudioSilenceAnalyzer.Configuration(
            thresholdDecibels: -44,
            minimumSilenceDuration: 0.30,
            paddingDuration: 0.05,
            roomToneHandleDuration: 0.14
        )
        let roomToneDeletionRanges = AudioSilenceAnalyzer.deletionRanges(
            for: regions,
            sampleRate: sampleRate,
            configuration: roomToneConfiguration
        )
        try require(
            roomToneDeletionRanges == [560..<880],
            "silence analyzer room tone handle range mismatch"
        )
    }

    private static func runPodcastExportProcessorSmoke() throws {
        let sampleRate = 48_000.0
        let frameCount = Int(sampleRate * 2)
        let samples = (0..<frameCount).map { frameIndex -> Float in
            let phase = Double(frameIndex) / sampleRate * 440 * 2 * .pi
            return Float(sin(phase) * 0.035)
        }
        let buffer = DecodedAudioBuffer(
            url: URL(fileURLWithPath: "/tmp/SoundtimePodcastExportSmoke.wav"),
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [samples, samples]
        )
        let result = try PodcastExportProcessor.masteredForPodcast(
            buffer,
            settings: PodcastExportSettings(
                targetIntegratedLUFS: -16,
                truePeakCeilingDBTP: -1,
                maximumGainAdjustmentDecibels: 36
            )
        )
        let peakCeiling = PodcastExportProcessor.amplitude(decibels: -1)

        try require(
            result.analysis.outputIntegratedLUFS > result.analysis.inputIntegratedLUFS,
            "podcast export smoke did not raise quiet audio toward target loudness"
        )
        try require(
            abs(result.analysis.outputIntegratedLUFS - (-16)) < 0.8,
            String(format: "podcast export smoke missed loudness target: %.2f", result.analysis.outputIntegratedLUFS)
        )
        try require(
            PodcastExportProcessor.approximateTruePeakAmplitude(result.buffer) <= peakCeiling + 0.000_5,
            "podcast export smoke exceeded peak ceiling"
        )
        for channelSamples in result.buffer.samplesByChannel {
            try require(
                !channelSamples.contains { !$0.isFinite },
                "podcast export smoke produced non-finite samples"
            )
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SmokeError.failed(message)
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw SmokeError.failed(message)
        }

        return value
    }
}

enum EditPreviewSmokeHarness {
    enum SmokeError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let sampleRate = 48_000.0
        let sourceFrameCount = Int(sampleRate) * 60 * 60 * 2
        let sourceURL = URL(fileURLWithPath: "/tmp/SoundtimeEditPreviewSmoke.wav")
        let fileInfo = WAVFileInfo(
            url: sourceURL,
            formatTag: 1,
            channelCount: 2,
            sampleRate: sampleRate,
            blockAlign: 4,
            bitsPerSample: 16,
            dataRange: 44..<(44 + sourceFrameCount * 4)
        )
        let previewBinCount = arguments.contains("--edit-preview-smoke-full") ? 65_536 : 32_768
        let operationCount = arguments.contains("--edit-preview-smoke-full") ? 260 : 96
        let sourceOverview = makeSourceOverview(
            duration: Double(sourceFrameCount) / sampleRate,
            binCount: previewBinCount
        )

        var timeline = AudioFileEditTimeline(fileInfo: fileInfo)
        let pasteClip = try requireValue(
            timeline.clip(for: TimelineSelection(startProgress: 0.025, endProgress: 0.0265)),
            "edit preview smoke could not prepare paste clip"
        )
        var latestOverview = sourceOverview
        var maximumPreviewMilliseconds = 0.0
        var previewDurations: [Double] = []
        previewDurations.reserveCapacity(operationCount)
        let startTime = DispatchTime.now().uptimeNanoseconds

        for index in 0..<operationCount {
            let startProgress = Double((index * 37_219) % 900_000) / 1_000_000.0
            let durationProgress = 0.000_08 + Double(index % 11) * 0.000_016
            let selection = TimelineSelection(
                startProgress: startProgress,
                endProgress: min(startProgress + durationProgress, 0.995)
            )

            switch index % 6 {
            case 0:
                _ = timeline.delete(selection)
            case 1:
                _ = timeline.applyGain(0.64, to: selection)
            case 2:
                let peak = peakMagnitude(in: latestOverview, selection: selection)
                let normalizeGain = min(max(1 / max(peak, 0.000_001), 0), 8)
                _ = timeline.applyGain(normalizeGain, to: selection)
            case 3:
                _ = timeline.replace(selection, with: pasteClip)
            default:
                let fadeDirection: AudioEditTimeline.FadeDirection = index.isMultiple(of: 2) ? .fadeIn : .fadeOut
                _ = timeline.applyFade(fadeDirection, to: selection)
            }

            let previewStartTime = DispatchTime.now().uptimeNanoseconds
            latestOverview = timeline.waveformOverview(from: sourceOverview)
            let previewMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - previewStartTime) / 1_000_000
            previewDurations.append(previewMilliseconds)
            maximumPreviewMilliseconds = max(maximumPreviewMilliseconds, previewMilliseconds)
        }

        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000
        let p95PreviewMilliseconds = percentile(previewDurations, percentile: 0.95)
        let state = try requireValue(timeline.persistentState, "edit graph did not persist")
        try require(!latestOverview.bins.isEmpty, "optimistic preview became empty")
        try require(latestOverview.duration > 0, "optimistic preview duration became invalid")
        try require(state.segments.count < operationCount * 4, "edit preview segment count exploded: \(state.segments.count)")
        try require(
            p95PreviewMilliseconds < 8,
            String(format: "optimistic preview p95 was too slow: %.2fms", p95PreviewMilliseconds)
        )
        try require(
            maximumPreviewMilliseconds < 48,
            String(format: "optimistic preview outlier was too slow: %.2fms", maximumPreviewMilliseconds)
        )
        try require(
            elapsedMilliseconds < 2_000,
            String(format: "edit previews were too slow: %.2fms", elapsedMilliseconds)
        )
        try runDeletePrefixStabilitySmoke()

        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "edit-preview-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: [
                "optimistic waveform previews stay nonempty",
                "preview regeneration stays below latency budget",
                "edit preview segment count stays bounded",
                "delete prefix stability preserves left-side rendering assumptions",
            ],
            metadata: [
                "operationCount": "\(operationCount)",
                "previewBinCount": "\(previewBinCount)",
                "segmentCount": "\(state.segments.count)",
                "previewP95Milliseconds": String(format: "%.3f", p95PreviewMilliseconds),
                "previewMaxMilliseconds": String(format: "%.3f", maximumPreviewMilliseconds),
                "elapsedMilliseconds": String(format: "%.3f", elapsedMilliseconds),
            ],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }

        print(
            String(
                format: "Soundtime edit preview smoke passed: %d ops, %d bins, %d segments, %.2fms p95 preview, %.2fms max preview, %.2fms total",
                operationCount,
                previewBinCount,
                state.segments.count,
                p95PreviewMilliseconds,
                maximumPreviewMilliseconds,
                elapsedMilliseconds
            )
        )
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else {
            return 0
        }

        let sortedValues = values.sorted()
        let clampedPercentile = min(max(percentile, 0), 1)
        let index = min(
            max(Int((Double(sortedValues.count - 1) * clampedPercentile).rounded()), 0),
            sortedValues.count - 1
        )
        return sortedValues[index]
    }

    private static func runDeletePrefixStabilitySmoke() throws {
        let sampleRate = 48_000.0
        let sourceFrameCount = Int(sampleRate) * 60 * 12
        let sourceURL = URL(fileURLWithPath: "/tmp/SoundtimeDeletePrefixStabilitySmoke.wav")
        let fileInfo = WAVFileInfo(
            url: sourceURL,
            formatTag: 1,
            channelCount: 2,
            sampleRate: sampleRate,
            blockAlign: 4,
            bitsPerSample: 16,
            dataRange: 44..<(44 + sourceFrameCount * 4)
        )
        let sourceOverview = makeSourceOverview(
            duration: Double(sourceFrameCount) / sampleRate,
            binCount: 65_536
        )
        let selection = TimelineSelection(startProgress: 0.42, endProgress: 0.54)
        let stablePrefixEndIndex = max(
            Int((selection.startProgress * Double(sourceOverview.bins.count)).rounded(.down)) - 2,
            0
        )

        var timeline = AudioFileEditTimeline(fileInfo: fileInfo)
        let deletedFrames = timeline.delete(selection)
        try require(deletedFrames > 0, "delete prefix stability smoke deleted no frames")

        let editedOverview = timeline.waveformOverview(from: sourceOverview)
        try require(
            editedOverview.bins.count < sourceOverview.bins.count,
            "delete prefix stability smoke did not shorten the preview"
        )
        try require(
            editedOverview.bins.count > stablePrefixEndIndex,
            "delete prefix stability smoke produced too few bins"
        )

        for index in 0..<stablePrefixEndIndex {
            try require(
                binsMatch(sourceOverview.bins[index], editedOverview.bins[index]),
                "delete prefix stability smoke changed untouched prefix bin \(index)"
            )
        }

        var clearTimeline = AudioFileEditTimeline(fileInfo: fileInfo)
        let clearedFrames = clearTimeline.clear(selection)
        try require(clearedFrames == deletedFrames, "clear smoke touched a different frame count")

        let clearedOverview = clearTimeline.waveformOverview(from: sourceOverview)
        try require(
            clearedOverview.bins.count == sourceOverview.bins.count,
            "clear smoke changed the preview length"
        )
        try require(
            abs(clearedOverview.duration - sourceOverview.duration) <= 0.000_001,
            "clear smoke changed the timeline duration"
        )

        let clearStartIndex = min(
            max(Int((selection.startProgress * Double(sourceOverview.bins.count)).rounded(.down)), 0),
            sourceOverview.bins.count
        )
        let clearEndIndex = min(
            max(Int((selection.endProgress * Double(sourceOverview.bins.count)).rounded(.up)), clearStartIndex),
            sourceOverview.bins.count
        )
        for index in 0..<stablePrefixEndIndex {
            try require(
                binsMatch(sourceOverview.bins[index], clearedOverview.bins[index]),
                "clear smoke changed untouched prefix bin \(index)"
            )
        }
        for index in clearStartIndex..<clearEndIndex {
            let bin = clearedOverview.bins[index]
            try require(
                abs(bin.minimumSample) <= 0.000_001 &&
                    abs(bin.maximumSample) <= 0.000_001 &&
                    bin.rmsSample <= 0.000_001,
                "clear smoke left audible preview energy in bin \(index)"
            )
        }
    }

    private static func makeSourceOverview(duration: TimeInterval, binCount: Int) -> WaveformOverview {
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount)

        for index in 0..<binCount {
            let t = Float(index) / Float(max(binCount - 1, 1))
            let envelope = 0.18 + 0.44 * abs(sin(t * .pi * 37.0))
            let phrase = 0.55 + 0.35 * sin(t * .pi * 5.7 + 0.2)
            let peak = min(max(envelope * phrase, 0.02), 0.98)
            bins.append(
                WaveformOverview.Bin(
                    minimumSample: -peak * (0.72 + 0.20 * sin(t * .pi * 19.0)),
                    maximumSample: peak,
                    rmsSample: peak * 0.58,
                    lowEnergy: 0.26 + 0.18 * sin(t * .pi * 3.0),
                    midEnergy: 0.34 + 0.14 * abs(sin(t * .pi * 29.0)),
                    highEnergy: 0.22 + 0.18 * abs(sin(t * .pi * 83.0))
                )
            )
        }

        return WaveformOverview(duration: duration, bins: bins)
    }

    private static func binsMatch(_ lhs: WaveformOverview.Bin, _ rhs: WaveformOverview.Bin) -> Bool {
        lhs.minimumSample == rhs.minimumSample &&
            lhs.maximumSample == rhs.maximumSample &&
            lhs.rmsSample == rhs.rmsSample &&
            lhs.lowEnergy == rhs.lowEnergy &&
            lhs.midEnergy == rhs.midEnergy &&
            lhs.highEnergy == rhs.highEnergy
    }

    private static func peakMagnitude(in overview: WaveformOverview, selection: TimelineSelection) -> Float {
        let binCount = overview.bins.count
        guard binCount > 0 else {
            return 0
        }

        let startIndex = min(
            max(Int((selection.startProgress * Double(binCount)).rounded(.down)), 0),
            binCount
        )
        let endIndex = min(
            max(Int((selection.endProgress * Double(binCount)).rounded(.up)), startIndex),
            binCount
        )
        guard startIndex < endIndex else {
            return 0
        }

        var peak: Float = 0
        for index in startIndex..<endIndex {
            peak = max(peak, overview.bins[index].peakMagnitude)
        }
        return peak
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SmokeError.failed(message)
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw SmokeError.failed(message)
        }

        return value
    }
}
