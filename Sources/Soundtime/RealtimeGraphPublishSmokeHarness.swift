import Darwin
import Foundation
import SoundtimeAudioCore

@MainActor
enum RealtimeGraphPublishSmokeHarness {
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
        let isFull = arguments.contains("--realtime-graph-publish-full")
        let trackCount = isFull ? 256 : 128
        let updateCount = isFull ? 220 : 96
        let renderBlockCount = isFull ? 10_000 : 4_000
        let renderBlockFrameCount = 256
        let sampleRate = 48_000.0
        let sourceFrameCount = Int(sampleRate) * 30
        let duplicateTrackPhaseMaxError = try runDuplicateTrackPhaseSmoke(
            sampleRate: sampleRate,
            sourceFrameCount: sourceFrameCount,
            renderBlockFrameCount: renderBlockFrameCount
        )
        let fileBackedDuplicateTrackPhaseMaxError = try runFileBackedDuplicateTrackPhaseSmoke(
            sampleRate: sampleRate,
            sourceFrameCount: sourceFrameCount,
            renderBlockFrameCount: renderBlockFrameCount
        )
        try runVisualClockSyncSmoke(
            sampleRate: sampleRate,
            sourceFrameCount: sourceFrameCount,
            renderBlockFrameCount: renderBlockFrameCount
        )
        let fileBackedPublishSummary = try runFileBackedEditPublishSmoke(
            sampleRate: sampleRate,
            sourceFrameCount: sourceFrameCount,
            isFull: isFull
        )
        try runLazyFileOutputRefreshSmoke(
            sampleRate: sampleRate,
            sourceFrameCount: sourceFrameCount
        )
        let outputDevice = RealtimeGraphPublishSmokeOutputDevice()

        guard let playbackEngine = RealtimeCorePlaybackEngine(outputDevice: outputDevice) else {
            throw SmokeError.failed("could not create realtime playback engine")
        }

        let sourceBuffer = syntheticAudioBuffer(frameCount: sourceFrameCount, sampleRate: sampleRate)
        let baseTimeline = AudioEditTimeline(sourceBuffer: sourceBuffer)
        var timelines = Array(repeating: baseTimeline, count: trackCount)
        var sourceRevisions = Array(repeating: 0, count: trackCount)
        let trackIDs = (0..<trackCount).map { index in
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index)) ?? UUID()
        }

        try playbackEngine.loadProjectTracks(projectTracks(
            ids: trackIDs,
            timelines: timelines,
            sourceRevisions: sourceRevisions,
            iteration: 0
        ))
        try playbackEngine.play()

        guard let corePointer = outputDevice.corePointer else {
            throw SmokeError.failed("realtime output device was not configured")
        }

        let renderGroup = DispatchGroup()
        renderGroup.enter()
        let uncheckedCorePointer = UncheckedAudioCorePointer(pointer: corePointer)
        DispatchQueue.global(qos: .userInitiated).async {
            render(
                corePointer: uncheckedCorePointer.pointer,
                blockCount: renderBlockCount,
                frameCount: renderBlockFrameCount,
                sampleRate: sampleRate
            )
            renderGroup.leave()
        }

        var publishDurations: [Double] = []
        var mixDurations: [Double] = []
        var seekDurations: [Double] = []
        publishDurations.reserveCapacity(updateCount)
        mixDurations.reserveCapacity(updateCount)
        seekDurations.reserveCapacity(updateCount / 8)
        let startTime = DispatchTime.now().uptimeNanoseconds

        for iteration in 0..<updateCount {
            let editedTrackIndex = (iteration * 37) % trackCount
            applySyntheticEdit(
                to: &timelines[editedTrackIndex],
                iteration: iteration
            )
            sourceRevisions[editedTrackIndex] += 1

            let updatedTracks = projectTracks(
                ids: trackIDs,
                timelines: timelines,
                sourceRevisions: sourceRevisions,
                iteration: iteration
            )

            let publishStart = DispatchTime.now().uptimeNanoseconds
            try playbackEngine.updateProjectTracks(updatedTracks)
            publishDurations.append(milliseconds(since: publishStart))

            let mixTracks = projectTrackMixes(
                ids: trackIDs,
                iteration: iteration + 1
            )
            let mixStart = DispatchTime.now().uptimeNanoseconds
            playbackEngine.updateProjectTrackMix(mixTracks)
            mixDurations.append(milliseconds(since: mixStart))

            if iteration.isMultiple(of: 8) {
                let seekStart = DispatchTime.now().uptimeNanoseconds
                try playbackEngine.seekExactly(toProgress: Float(Double(iteration % 97) / 97.0))
                seekDurations.append(milliseconds(since: seekStart))
            }
        }

        renderGroup.wait()
        playbackEngine.pause()

        let elapsedMilliseconds = milliseconds(since: startTime)
        let publishP95 = percentile(publishDurations, percentile: 0.95)
        let publishMax = publishDurations.max() ?? 0
        let mixP95 = percentile(mixDurations, percentile: 0.95)
        let mixMax = mixDurations.max() ?? 0
        let seekP95 = percentile(seekDurations, percentile: 0.95)
        let snapshot = soundtime_audio_core_snapshot(corePointer)

        try require(snapshot.droppedCommandCount == 0, "realtime core dropped \(snapshot.droppedCommandCount) commands")
        try require(
            publishP95 < (isFull ? 7.5 : 5.0),
            String(format: "graph publish p95 too slow: %.3fms", publishP95)
        )
        try require(
            publishMax < (isFull ? 24.0 : 18.0),
            String(format: "graph publish outlier too slow: %.3fms", publishMax)
        )
        try require(
            mixP95 < (isFull ? 5.0 : 3.5),
            String(format: "mix publish p95 too slow: %.3fms", mixP95)
        )
        try require(
            mixMax < (isFull ? 16.0 : 12.0),
            String(format: "mix publish outlier too slow: %.3fms", mixMax)
        )
        try require(
            seekP95 < 1.0,
            String(format: "seek p95 too slow during graph churn: %.3fms", seekP95)
        )

        print(
            String(
                format: "Soundtime realtime graph publish smoke passed: %d tracks, %d updates, publish %.3fms p95 / %.3fms max, mix %.3fms p95 / %.3fms max, seek %.3fms p95, %.2fms total",
                trackCount,
                updateCount,
                publishP95,
                publishMax,
                mixP95,
                mixMax,
                seekP95,
                elapsedMilliseconds
            )
        )
        print(
            String(
                format: "Soundtime duplicate track phase smoke passed: max %.8f",
                duplicateTrackPhaseMaxError
            )
        )
        print(
            String(
                format: "Soundtime file-backed duplicate track phase smoke passed: max %.8f",
                fileBackedDuplicateTrackPhaseMaxError
            )
        )
        print(fileBackedPublishSummary)
    }

    private static func runDuplicateTrackPhaseSmoke(
        sampleRate: Double,
        sourceFrameCount: Int,
        renderBlockFrameCount: Int
    ) throws -> Float {
        let sourceBuffer = syntheticAudioBuffer(frameCount: sourceFrameCount, sampleRate: sampleRate)
        let baseTimeline = AudioEditTimeline(sourceBuffer: sourceBuffer)
        let singleDevice = RealtimeGraphPublishSmokeOutputDevice()
        let duplicateDevice = RealtimeGraphPublishSmokeOutputDevice()

        guard
            let singleEngine = RealtimeCorePlaybackEngine(outputDevice: singleDevice),
            let duplicateEngine = RealtimeCorePlaybackEngine(outputDevice: duplicateDevice)
        else {
            throw SmokeError.failed("could not create duplicate track phase smoke engines")
        }

        try singleEngine.loadProjectTracks(duplicatePhaseTracks(
            timeline: baseTimeline,
            trackCount: 1
        ))
        try duplicateEngine.loadProjectTracks(duplicatePhaseTracks(
            timeline: baseTimeline,
            trackCount: 2
        ))
        try singleEngine.play()
        try duplicateEngine.play()

        guard
            let singleCorePointer = singleDevice.corePointer,
            let duplicateCorePointer = duplicateDevice.corePointer
        else {
            throw SmokeError.failed("duplicate track phase smoke output devices were not configured")
        }

        let blockCount = 256
        let singleRender = renderCaptured(
            corePointer: singleCorePointer,
            blockCount: blockCount,
            frameCount: renderBlockFrameCount,
            sampleRate: sampleRate
        )
        let duplicateRender = renderCaptured(
            corePointer: duplicateCorePointer,
            blockCount: blockCount,
            frameCount: renderBlockFrameCount,
            sampleRate: sampleRate
        )
        singleEngine.pause()
        duplicateEngine.pause()

        let singleSnapshot = soundtime_audio_core_snapshot(singleCorePointer)
        let duplicateSnapshot = soundtime_audio_core_snapshot(duplicateCorePointer)
        try require(
            singleSnapshot.droppedCommandCount == 0 && duplicateSnapshot.droppedCommandCount == 0,
            "duplicate track phase smoke dropped commands"
        )
        try require(
            singleRender.left.count == duplicateRender.left.count &&
                singleRender.right.count == duplicateRender.right.count,
            "duplicate track phase smoke rendered mismatched buffer sizes"
        )

        var maxError: Float = 0
        var maxReference: Float = 0
        for index in singleRender.left.indices {
            let leftReference = singleRender.left[index] * 2
            let rightReference = singleRender.right[index] * 2
            let leftError = abs(duplicateRender.left[index] - leftReference)
            let rightError = abs(duplicateRender.right[index] - rightReference)
            maxError = max(maxError, leftError, rightError)
            maxReference = max(
                maxReference,
                abs(leftReference),
                abs(rightReference),
                abs(duplicateRender.left[index]),
                abs(duplicateRender.right[index])
            )
        }

        let tolerance = max(0.000_05, maxReference * 0.000_04)
        try require(
            maxError <= tolerance,
            String(
                format: "duplicate tracks are not sample-synchronous: max error %.8f, tolerance %.8f",
                maxError,
                tolerance
            )
        )
        return maxError
    }

    private static func runFileBackedDuplicateTrackPhaseSmoke(
        sampleRate: Double,
        sourceFrameCount: Int,
        renderBlockFrameCount: Int
    ) throws -> Float {
        let wavURL = URL(fileURLWithPath: "/tmp/SoundtimeRealtimeFileBackedDuplicatePhaseSmoke.wav")
        try writeSyntheticPCM16WAV(
            to: wavURL,
            frameCount: sourceFrameCount,
            sampleRate: sampleRate
        )
        let fileInfo = try WAVAudioDecoder.inspect(url: wavURL)
        let baseTimeline = AudioFileEditTimeline(fileInfo: fileInfo)
        let singleDevice = RealtimeGraphPublishSmokeOutputDevice()
        let duplicateDevice = RealtimeGraphPublishSmokeOutputDevice()

        guard
            let singleEngine = RealtimeCorePlaybackEngine(outputDevice: singleDevice),
            let duplicateEngine = RealtimeCorePlaybackEngine(outputDevice: duplicateDevice)
        else {
            throw SmokeError.failed("could not create file-backed duplicate phase smoke engines")
        }

        try singleEngine.loadProjectTracks(fileBackedDuplicatePhaseTracks(url: wavURL, timeline: baseTimeline, trackCount: 1))
        try duplicateEngine.loadProjectTracks(fileBackedDuplicatePhaseTracks(url: wavURL, timeline: baseTimeline, trackCount: 2))
        try singleEngine.play()
        try duplicateEngine.play()

        guard
            let singleCorePointer = singleDevice.corePointer,
            let duplicateCorePointer = duplicateDevice.corePointer
        else {
            throw SmokeError.failed("file-backed duplicate phase smoke output devices were not configured")
        }

        let blockCount = 256
        let singleRender = renderCaptured(
            corePointer: singleCorePointer,
            blockCount: blockCount,
            frameCount: renderBlockFrameCount,
            sampleRate: sampleRate
        )
        let duplicateRender = renderCaptured(
            corePointer: duplicateCorePointer,
            blockCount: blockCount,
            frameCount: renderBlockFrameCount,
            sampleRate: sampleRate
        )
        singleEngine.pause()
        duplicateEngine.pause()

        try require(
            singleRender.left.count == duplicateRender.left.count &&
                singleRender.right.count == duplicateRender.right.count,
            "file-backed duplicate phase smoke rendered mismatched buffer sizes"
        )

        var maxError: Float = 0
        var maxReference: Float = 0
        for index in singleRender.left.indices {
            let leftReference = singleRender.left[index] * 2
            let rightReference = singleRender.right[index] * 2
            let leftError = abs(duplicateRender.left[index] - leftReference)
            let rightError = abs(duplicateRender.right[index] - rightReference)
            maxError = max(maxError, leftError, rightError)
            maxReference = max(
                maxReference,
                abs(leftReference),
                abs(rightReference),
                abs(duplicateRender.left[index]),
                abs(duplicateRender.right[index])
            )
        }

        let tolerance = max(0.000_1, maxReference * 0.000_08)
        try require(
            maxError <= tolerance,
            String(
                format: "file-backed duplicate tracks are not sample-synchronous: max error %.8f, tolerance %.8f",
                maxError,
                tolerance
            )
        )
        return maxError
    }

    private static func runVisualClockSyncSmoke(
        sampleRate: Double,
        sourceFrameCount: Int,
        renderBlockFrameCount: Int
    ) throws {
        let outputDevice = RealtimeGraphPublishSmokeOutputDevice()
        guard let playbackEngine = RealtimeCorePlaybackEngine(outputDevice: outputDevice) else {
            throw SmokeError.failed("could not create visual clock sync playback engine")
        }

        let sourceBuffer = syntheticAudioBuffer(frameCount: sourceFrameCount, sampleRate: sampleRate)
        try playbackEngine.loadProjectTracks(duplicatePhaseTracks(
            timeline: AudioEditTimeline(sourceBuffer: sourceBuffer),
            trackCount: 2
        ))
        guard let corePointer = outputDevice.corePointer else {
            throw SmokeError.failed("visual clock sync output device was not configured")
        }

        try playbackEngine.seekExactly(toProgress: 0.375)
        try assertSnapshot(
            playbackEngine.snapshot(),
            expectedFrame: Int((Double(sourceFrameCount) * 0.375).rounded(.down)),
            isPlaying: false,
            label: "pending seek"
        )

        try playbackEngine.play()
        try assertSnapshot(
            playbackEngine.snapshot(),
            expectedFrame: Int((Double(sourceFrameCount) * 0.375).rounded(.down)),
            isPlaying: true,
            label: "pending play"
        )

        render(
            corePointer: corePointer,
            blockCount: 1,
            frameCount: renderBlockFrameCount,
            sampleRate: sampleRate
        )
        playbackEngine.pause(atProgress: 0.5)
        try assertSnapshot(
            playbackEngine.snapshot(),
            expectedFrame: Int((Double(sourceFrameCount) * 0.5).rounded(.down)),
            isPlaying: false,
            label: "pending pause"
        )

        render(
            corePointer: corePointer,
            blockCount: 1,
            frameCount: renderBlockFrameCount,
            sampleRate: sampleRate
        )
        try assertSnapshot(
            playbackEngine.snapshot(),
            expectedFrame: Int((Double(sourceFrameCount) * 0.5).rounded(.down)),
            isPlaying: false,
            label: "committed pause"
        )

        try playbackEngine.seekExactly(toProgress: 0.75)
        try assertSnapshot(
            playbackEngine.snapshot(),
            expectedFrame: Int((Double(sourceFrameCount) * 0.75).rounded(.down)),
            isPlaying: false,
            label: "pending paused seek"
        )
    }

    private static func duplicatePhaseTracks(
        timeline: AudioEditTimeline,
        trackCount: Int
    ) -> [ProjectPlaybackTrack] {
        (0..<trackCount).map { index in
            ProjectPlaybackTrack(
                id: UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", index)) ?? UUID(),
                source: .timeline(audioTimeline: timeline, zeroCrossingIndex: nil),
                sourceRevision: 0,
                volume: 1,
                isMuted: false,
                isSoloed: false
            )
        }
    }

    private static func fileBackedDuplicatePhaseTracks(
        url: URL,
        timeline: AudioFileEditTimeline,
        trackCount: Int
    ) -> [ProjectPlaybackTrack] {
        (0..<trackCount).map { index in
            ProjectPlaybackTrack(
                id: UUID(uuidString: String(format: "00000000-0000-4000-b000-%012d", index)) ?? UUID(),
                source: .fileTimeline(url: url, timeline: timeline, zeroCrossingProbe: nil),
                sourceRevision: 0,
                volume: 1,
                isMuted: false,
                isSoloed: false
            )
        }
    }

    private static func projectTracks(
        ids: [UUID],
        timelines: [AudioEditTimeline],
        sourceRevisions: [Int],
        iteration: Int
    ) -> [ProjectPlaybackTrack] {
        var tracks: [ProjectPlaybackTrack] = []
        tracks.reserveCapacity(ids.count)
        for index in ids.indices {
            let volume = Float(0.54 + 0.42 * (Double((index + iteration) % 19) / 18.0))
            tracks.append(ProjectPlaybackTrack(
                id: ids[index],
                source: .timeline(audioTimeline: timelines[index], zeroCrossingIndex: nil),
                sourceRevision: sourceRevisions[index],
                volume: volume,
                isMuted: (index + iteration).isMultiple(of: 29),
                isSoloed: false
            ))
        }
        return tracks
    }

    private static func projectTrackMixes(
        ids: [UUID],
        iteration: Int
    ) -> [ProjectPlaybackTrackMix] {
        var tracks: [ProjectPlaybackTrackMix] = []
        tracks.reserveCapacity(ids.count)
        for index in ids.indices {
            let volume = Float(0.54 + 0.42 * (Double((index + iteration) % 19) / 18.0))
            tracks.append(ProjectPlaybackTrackMix(
                id: ids[index],
                volume: volume,
                isMuted: (index + iteration).isMultiple(of: 29),
                isSoloed: false
            ))
        }
        return tracks
    }

    private static func applySyntheticEdit(
        to timeline: inout AudioEditTimeline,
        iteration: Int
    ) {
        let startProgress = Double((iteration * 8_191) % 900_000) / 1_000_000.0
        let endProgress = min(startProgress + 0.001_5 + Double(iteration % 7) * 0.000_15, 0.995)
        let selection = TimelineSelection(startProgress: startProgress, endProgress: endProgress)

        switch iteration % 6 {
        case 0:
            _ = timeline.applyGain(0.68, to: selection)
        case 1:
            _ = timeline.applyGain(1.16, to: selection)
        case 2:
            _ = timeline.applyFade(.fadeIn, to: selection)
        case 3:
            _ = timeline.applyFade(.fadeOut, to: selection)
        case 4:
            _ = timeline.delete(selection)
        default:
            _ = timeline.applyGain(0.91, to: selection)
        }
    }

    private static func runFileBackedEditPublishSmoke(
        sampleRate: Double,
        sourceFrameCount: Int,
        isFull: Bool
    ) throws -> String {
        let trackCount = isFull ? 96 : 48
        let updateCount = isFull ? 180 : 72
        let renderBlockCount = isFull ? 7_500 : 2_800
        let renderBlockFrameCount = 256
        let wavURL = URL(fileURLWithPath: "/tmp/SoundtimeRealtimeFileBackedPublishSmoke.wav")
        try writeSyntheticPCM16WAV(
            to: wavURL,
            frameCount: sourceFrameCount,
            sampleRate: sampleRate
        )
        let fileInfo = try WAVAudioDecoder.inspect(url: wavURL)
        let baseTimeline = AudioFileEditTimeline(fileInfo: fileInfo)
        var timelines = Array(repeating: baseTimeline, count: trackCount)
        var sourceRevisions = Array(repeating: 0, count: trackCount)
        let trackIDs = (0..<trackCount).map { index in
            UUID(uuidString: String(format: "00000000-0000-4000-a000-%012d", index)) ?? UUID()
        }
        let outputDevice = RealtimeGraphPublishSmokeOutputDevice()

        guard let playbackEngine = RealtimeCorePlaybackEngine(outputDevice: outputDevice) else {
            throw SmokeError.failed("could not create file-backed realtime playback engine")
        }

        try playbackEngine.loadProjectTracks(fileBackedProjectTracks(
            ids: trackIDs,
            url: wavURL,
            timelines: timelines,
            sourceRevisions: sourceRevisions,
            iteration: 0
        ))
        try playbackEngine.play()

        guard let corePointer = outputDevice.corePointer else {
            throw SmokeError.failed("file-backed realtime output device was not configured")
        }

        let renderGroup = DispatchGroup()
        renderGroup.enter()
        let uncheckedCorePointer = UncheckedAudioCorePointer(pointer: corePointer)
        DispatchQueue.global(qos: .userInitiated).async {
            render(
                corePointer: uncheckedCorePointer.pointer,
                blockCount: renderBlockCount,
                frameCount: renderBlockFrameCount,
                sampleRate: sampleRate
            )
            renderGroup.leave()
        }

        var publishDurations: [Double] = []
        var seekDurations: [Double] = []
        publishDurations.reserveCapacity(updateCount)
        seekDurations.reserveCapacity(updateCount / 6)
        let startTime = DispatchTime.now().uptimeNanoseconds

        for iteration in 0..<updateCount {
            let editedTrackIndex = (iteration * 23) % trackCount
            applySyntheticFileEdit(
                to: &timelines[editedTrackIndex],
                iteration: iteration
            )
            sourceRevisions[editedTrackIndex] += 1

            let updatedTracks = fileBackedProjectTracks(
                ids: trackIDs,
                url: wavURL,
                timelines: timelines,
                sourceRevisions: sourceRevisions,
                iteration: iteration
            )
            let publishStart = DispatchTime.now().uptimeNanoseconds
            try playbackEngine.updateProjectTracks(updatedTracks)
            publishDurations.append(milliseconds(since: publishStart))

            if iteration.isMultiple(of: 6) {
                let seekStart = DispatchTime.now().uptimeNanoseconds
                try playbackEngine.seekExactly(toProgress: Float(Double(iteration % 89) / 89.0))
                seekDurations.append(milliseconds(since: seekStart))
            }
        }

        renderGroup.wait()
        playbackEngine.pause()

        let elapsedMilliseconds = milliseconds(since: startTime)
        let publishP95 = percentile(publishDurations, percentile: 0.95)
        let publishMax = publishDurations.max() ?? 0
        let seekP95 = percentile(seekDurations, percentile: 0.95)
        let snapshot = soundtime_audio_core_snapshot(corePointer)
        try require(snapshot.droppedCommandCount == 0, "file-backed realtime core dropped \(snapshot.droppedCommandCount) commands")
        try require(
            publishP95 < (isFull ? 6.0 : 4.0),
            String(format: "file-backed graph publish p95 too slow: %.3fms", publishP95)
        )
        try require(
            publishMax < (isFull ? 18.0 : 14.0),
            String(format: "file-backed graph publish outlier too slow: %.3fms", publishMax)
        )
        try require(
            seekP95 < 1.0,
            String(format: "file-backed seek p95 too slow during graph churn: %.3fms", seekP95)
        )

        return String(
            format: "Soundtime file-backed realtime edit smoke passed: %d tracks, %d updates, publish %.3fms p95 / %.3fms max, seek %.3fms p95, %.2fms total",
            trackCount,
            updateCount,
            publishP95,
            publishMax,
            seekP95,
            elapsedMilliseconds
        )
    }

    private static func runLazyFileOutputRefreshSmoke(
        sampleRate: Double,
        sourceFrameCount: Int
    ) throws {
        let wavURL = URL(fileURLWithPath: "/tmp/SoundtimeRealtimeOutputRefreshSmoke.wav")
        try writeSyntheticPCM16WAV(
            to: wavURL,
            frameCount: sourceFrameCount,
            sampleRate: sampleRate
        )
        let outputDevice = RealtimeGraphPublishSmokeOutputDevice()
        guard let playbackEngine = RealtimeCorePlaybackEngine(outputDevice: outputDevice) else {
            throw SmokeError.failed("could not create output refresh playback engine")
        }

        try playbackEngine.loadFile(at: wavURL, zeroCrossingProbe: nil)
        try require(outputDevice.configureCount == 1, "lazy file output did not configure initially")
        try playbackEngine.refreshOutputDevice()
        try require(outputDevice.invalidateCount == 1, "lazy file output refresh did not invalidate")
        try require(outputDevice.configureCount == 2, "lazy file output refresh did not reconfigure")
    }

    private static func fileBackedProjectTracks(
        ids: [UUID],
        url: URL,
        timelines: [AudioFileEditTimeline],
        sourceRevisions: [Int],
        iteration: Int
    ) -> [ProjectPlaybackTrack] {
        var tracks: [ProjectPlaybackTrack] = []
        tracks.reserveCapacity(ids.count)
        for index in ids.indices {
            let volume = Float(0.58 + 0.34 * (Double((index + iteration) % 17) / 16.0))
            tracks.append(ProjectPlaybackTrack(
                id: ids[index],
                source: .fileTimeline(url: url, timeline: timelines[index], zeroCrossingProbe: nil),
                sourceRevision: sourceRevisions[index],
                volume: volume,
                isMuted: (index + iteration).isMultiple(of: 31),
                isSoloed: false
            ))
        }
        return tracks
    }

    private static func applySyntheticFileEdit(
        to timeline: inout AudioFileEditTimeline,
        iteration: Int
    ) {
        let startProgress = Double((iteration * 12_271) % 880_000) / 1_000_000.0
        let endProgress = min(startProgress + 0.001_2 + Double(iteration % 5) * 0.000_18, 0.995)
        let selection = TimelineSelection(startProgress: startProgress, endProgress: endProgress)

        switch iteration % 6 {
        case 0:
            _ = timeline.applyGain(0.62, to: selection)
        case 1:
            _ = timeline.applyGain(1.22, to: selection)
        case 2:
            _ = timeline.applyFade(.fadeIn, to: selection)
        case 3:
            _ = timeline.applyFade(.fadeOut, to: selection)
        case 4:
            _ = timeline.delete(selection)
        default:
            _ = timeline.applyGain(0.88, to: selection)
        }
    }

    private static func writeSyntheticPCM16WAV(
        to url: URL,
        frameCount: Int,
        sampleRate: Double
    ) throws {
        let channelCount = 2
        let bitsPerSample = 16
        let blockAlign = channelCount * bitsPerSample / 8
        let byteRate = Int(sampleRate) * blockAlign
        let dataByteCount = frameCount * blockAlign
        var data = Data()
        data.reserveCapacity(44 + dataByteCount)
        appendASCII("RIFF", to: &data)
        appendUInt32LE(UInt32(36 + dataByteCount), to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendUInt32LE(16, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt16LE(UInt16(channelCount), to: &data)
        appendUInt32LE(UInt32(sampleRate), to: &data)
        appendUInt32LE(UInt32(byteRate), to: &data)
        appendUInt16LE(UInt16(blockAlign), to: &data)
        appendUInt16LE(UInt16(bitsPerSample), to: &data)
        appendASCII("data", to: &data)
        appendUInt32LE(UInt32(dataByteCount), to: &data)

        for frame in 0..<frameCount {
            let phase = Double(frame) / sampleRate
            let left = sin(phase * 330.0 * 2.0 * .pi) * 0.34 +
                sin(phase * 1_240.0 * 2.0 * .pi) * 0.08
            let right = -left * 0.74
            appendInt16LE(Int16(max(min(left, 0.98), -0.98) * 32_767), to: &data)
            appendInt16LE(Int16(max(min(right, 0.98), -0.98) * 32_767), to: &data)
        }

        try data.write(to: url, options: [.atomic])
    }

    private static func appendASCII(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func appendInt16LE(_ value: Int16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private nonisolated static func render(
        corePointer: OpaquePointer,
        blockCount: Int,
        frameCount: Int,
        sampleRate: Double
    ) {
        var leftOutput = [Float](repeating: 0, count: frameCount)
        var rightOutput = [Float](repeating: 0, count: frameCount)

        for blockIndex in 0..<blockCount {
            leftOutput.withUnsafeMutableBufferPointer { leftBuffer in
                rightOutput.withUnsafeMutableBufferPointer { rightBuffer in
                    var outputs: [UnsafeMutablePointer<Float>?] = [
                        leftBuffer.baseAddress,
                        rightBuffer.baseAddress,
                    ]
                    outputs.withUnsafeMutableBufferPointer { outputBuffer in
                        soundtime_audio_core_render_at_host_time(
                            corePointer,
                            outputBuffer.baseAddress,
                            2,
                            UInt32(frameCount),
                            Double(blockIndex * frameCount) / sampleRate
                        )
                    }
                }
            }
        }
    }

    private nonisolated static func renderCaptured(
        corePointer: OpaquePointer,
        blockCount: Int,
        frameCount: Int,
        sampleRate: Double
    ) -> (left: [Float], right: [Float]) {
        var leftOutput = [Float](repeating: 0, count: frameCount)
        var rightOutput = [Float](repeating: 0, count: frameCount)
        var capturedLeft: [Float] = []
        var capturedRight: [Float] = []
        capturedLeft.reserveCapacity(blockCount * frameCount)
        capturedRight.reserveCapacity(blockCount * frameCount)

        for blockIndex in 0..<blockCount {
            leftOutput.withUnsafeMutableBufferPointer { leftBuffer in
                rightOutput.withUnsafeMutableBufferPointer { rightBuffer in
                    var outputs: [UnsafeMutablePointer<Float>?] = [
                        leftBuffer.baseAddress,
                        rightBuffer.baseAddress,
                    ]
                    outputs.withUnsafeMutableBufferPointer { outputBuffer in
                        soundtime_audio_core_render_at_host_time(
                            corePointer,
                            outputBuffer.baseAddress,
                            2,
                            UInt32(frameCount),
                            Double(blockIndex * frameCount) / sampleRate
                        )
                    }

                    if let baseAddress = leftBuffer.baseAddress {
                        capturedLeft.append(contentsOf: UnsafeBufferPointer(
                            start: baseAddress,
                            count: frameCount
                        ))
                    }
                    if let baseAddress = rightBuffer.baseAddress {
                        capturedRight.append(contentsOf: UnsafeBufferPointer(
                            start: baseAddress,
                            count: frameCount
                        ))
                    }
                }
            }
        }

        return (capturedLeft, capturedRight)
    }

    private static func syntheticAudioBuffer(frameCount: Int, sampleRate: Double) -> DecodedAudioBuffer {
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            let phase = Double(frame) / sampleRate
            let sample = Float(
                sin(phase * 440.0 * 2.0 * .pi) * 0.32 +
                    sin(phase * 1_771.0 * 2.0 * .pi) * 0.08
            )
            left.append(sample)
            right.append(-sample * 0.82)
        }

        return DecodedAudioBuffer(
            url: URL(fileURLWithPath: "/tmp/SoundtimeRealtimeGraphPublishSmoke.wav"),
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [left, right]
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

    private static func milliseconds(since startTime: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SmokeError.failed(message)
        }
    }

    private static func assertSnapshot(
        _ snapshot: PlaybackSnapshot,
        expectedFrame: Int,
        isPlaying: Bool,
        label: String
    ) throws {
        try require(
            abs(snapshot.frameIndex - expectedFrame) <= 1,
            "\(label) visual clock frame mismatch: expected \(expectedFrame), got \(snapshot.frameIndex)"
        )
        try require(
            snapshot.isPlaying == isPlaying,
            "\(label) visual clock play state mismatch"
        )
    }
}

private final class RealtimeGraphPublishSmokeOutputDevice: RealtimeAudioOutputDevice {
    var corePointer: OpaquePointer?
    private(set) var configureCount = 0
    private(set) var invalidateCount = 0

    func configure(corePointer: OpaquePointer, sampleRate _: Double) throws {
        configureCount += 1
        self.corePointer = corePointer
    }

    func invalidateConfiguration() {
        invalidateCount += 1
    }

    func start() throws {}

    func stop() {}
}

private struct UncheckedAudioCorePointer: @unchecked Sendable {
    let pointer: OpaquePointer
}
