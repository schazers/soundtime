import Foundation

enum AudioExportRenderer {
    typealias ProgressHandler = @Sendable (Double, AudioExportStage, String) -> Void
    typealias CancellationCheck = @Sendable () throws -> Void

    static let defaultBlockFrameCount = 8_192

    enum RenderError: LocalizedError {
        case invalidSource(String)
        case unavailableAudioCore
        case graphPreparationFailed
        case blockRenderFailed

        var errorDescription: String? {
            switch self {
            case let .invalidSource(name):
                return "Soundtime could not prepare \(name) for export."
            case .unavailableAudioCore:
                return "The shared audio renderer is unavailable."
            case .graphPreparationFailed:
                return "Soundtime could not prepare the export audio graph."
            case .blockRenderFailed:
                return "The shared audio renderer could not render an export block."
            }
        }
    }

    static func renderMixdown(
        snapshot: AudioExportSnapshot,
        to writer: AudioExportSampleWriter,
        blockFrameCount: Int = defaultBlockFrameCount,
        cancellationCheck: CancellationCheck? = nil,
        progressHandler: ProgressHandler? = nil
    ) throws -> AudioExportRenderStats {
        let tracks: [AudioExportTrackSnapshot]
        switch snapshot.request.scope {
        case .trackRange, .clip:
            tracks = snapshot.tracks
        case .fullMixdown, .timeRange, .stems:
            tracks = audibleTracks(in: snapshot.tracks)
        }
        let context: AudioExportBlockRendering
        if tracks.isEmpty {
            context = SilentAudioExportRenderContext(
                channelCount: snapshot.channelCount
            )
        } else {
            context = try CanonicalAudioExportRenderContext(
                snapshot: snapshot,
                tracks: tracks,
                gainPosition: .postFader
            )
        }
        return try render(
            snapshot: snapshot,
            context: context,
            writer: writer,
            blockFrameCount: blockFrameCount,
            message: "Rendering mixdown",
            cancellationCheck: cancellationCheck,
            progressHandler: progressHandler
        )
    }

    static func renderTrack(
        _ track: AudioExportTrackSnapshot,
        snapshot: AudioExportSnapshot,
        to writer: AudioExportSampleWriter,
        blockFrameCount: Int = defaultBlockFrameCount,
        cancellationCheck: CancellationCheck? = nil,
        progressHandler: ProgressHandler? = nil
    ) throws -> AudioExportRenderStats {
        let context = try CanonicalAudioExportRenderContext(
            snapshot: snapshot,
            tracks: [track],
            gainPosition: snapshot.request.stemOptions.gainPosition
        )
        return try render(
            snapshot: snapshot,
            context: context,
            writer: writer,
            blockFrameCount: blockFrameCount,
            message: "Rendering \(track.name)",
            cancellationCheck: cancellationCheck,
            progressHandler: progressHandler
        )
    }

    static func renderLogicalTrack(
        _ tracks: [AudioExportTrackSnapshot],
        snapshot: AudioExportSnapshot,
        to writer: AudioExportSampleWriter,
        blockFrameCount: Int = defaultBlockFrameCount,
        cancellationCheck: CancellationCheck? = nil,
        progressHandler: ProgressHandler? = nil
    ) throws -> AudioExportRenderStats {
        guard let first = tracks.first else {
            throw RenderError.graphPreparationFailed
        }
        let context = try CanonicalAudioExportRenderContext(
            snapshot: snapshot,
            tracks: tracks,
            gainPosition: snapshot.request.stemOptions.gainPosition
        )
        return try render(
            snapshot: snapshot,
            context: context,
            writer: writer,
            blockFrameCount: blockFrameCount,
            message: "Rendering \(first.name)",
            cancellationCheck: cancellationCheck,
            progressHandler: progressHandler
        )
    }

    private static func render(
        snapshot: AudioExportSnapshot,
        context: AudioExportBlockRendering,
        writer: AudioExportSampleWriter,
        blockFrameCount: Int,
        message: String,
        cancellationCheck: CancellationCheck?,
        progressHandler: ProgressHandler?
    ) throws -> AudioExportRenderStats {
        guard snapshot.frameCount > 0 else {
            throw AudioExportStreamingWAVWriter.WriterError.noSamplesWritten
        }

        progressHandler?(0, .rendering, message)
        var renderedFrameCount = 0
        var stats = AudioExportRenderStats.empty
        var outputFrame = snapshot.exportFrameRange.lowerBound
        let blockFrameCount = max(blockFrameCount, 512)

        while outputFrame < snapshot.exportFrameRange.upperBound {
            try Task.checkCancellation()
            try cancellationCheck?()
            let blockEndFrame = min(
                outputFrame + blockFrameCount,
                snapshot.exportFrameRange.upperBound
            )
            let frameCount = blockEndFrame - outputFrame
            let samples = try context.render(
                startFrameIndex: outputFrame,
                frameCount: frameCount
            )
            stats.merge(renderStats(samplesByChannel: samples, frameCount: frameCount))
            try writer.append(samplesByChannel: samples, frameCount: frameCount)
            renderedFrameCount += frameCount
            outputFrame = blockEndFrame

            let progress = Double(renderedFrameCount) / Double(max(snapshot.frameCount, 1))
            progressHandler?(progress, .rendering, message)
        }

        _ = try writer.finish()
        progressHandler?(1, .rendering, "Rendered audio")
        return stats
    }

    private static func audibleTracks(
        in tracks: [AudioExportTrackSnapshot]
    ) -> [AudioExportTrackSnapshot] {
        let hasSoloedTrack = tracks.contains(where: \.isSoloed)
        return tracks.filter { track in
            hasSoloedTrack ? track.isSoloed : !track.isMuted
        }
    }

    private static func renderStats(
        samplesByChannel: [[Float]],
        frameCount: Int
    ) -> AudioExportRenderStats {
        var peak: Float = 0
        var clippedSampleCount = 0
        for channelSamples in samplesByChannel {
            for sample in channelSamples.prefix(frameCount) {
                let magnitude = abs(sample)
                peak = max(peak, magnitude)
                if magnitude > 1 {
                    clippedSampleCount += 1
                }
            }
        }
        return AudioExportRenderStats(
            renderedFrameCount: frameCount,
            peakMagnitude: peak,
            clippedSampleCount: clippedSampleCount
        )
    }
}

private protocol AudioExportBlockRendering {
    func render(startFrameIndex: Int, frameCount: Int) throws -> [[Float]]
}

private struct SilentAudioExportRenderContext: AudioExportBlockRendering {
    let channelCount: Int

    func render(startFrameIndex: Int, frameCount: Int) throws -> [[Float]] {
        let silence = [Float](repeating: 0, count: frameCount)
        return [[Float]](
            repeating: silence,
            count: max(channelCount, 1)
        )
    }
}

private final class CanonicalAudioExportRenderContext: AudioExportBlockRendering {
    private let core: RealtimeAudioCore
    private let preparedTracks: [PreparedRealtimeAudioTrack]
    private let outputChannelCount: Int

    init(
        snapshot: AudioExportSnapshot,
        tracks: [AudioExportTrackSnapshot],
        gainPosition: AudioExportStemOptions.GainPosition
    ) throws {
        guard let core = RealtimeAudioCore() else {
            throw AudioExportRenderer.RenderError.unavailableAudioCore
        }

        let preparedTracks = try tracks.map { track in
            try Self.prepareTrack(
                track,
                outputSampleRate: snapshot.sampleRate,
                gainPosition: gainPosition
            )
        }
        guard
            !preparedTracks.isEmpty,
            core.setPreparedTracks(preparedTracks, sampleRate: snapshot.sampleRate)
        else {
            throw AudioExportRenderer.RenderError.graphPreparationFailed
        }

        self.core = core
        self.preparedTracks = preparedTracks
        outputChannelCount = snapshot.channelCount
    }

    func render(startFrameIndex: Int, frameCount: Int) throws -> [[Float]] {
        guard
            let samples = core.renderOffline(
                startFrameIndex: startFrameIndex,
                channelCount: outputChannelCount,
                frameCount: frameCount
            )
        else {
            throw AudioExportRenderer.RenderError.blockRenderFailed
        }
        return samples
    }

    private static func prepareTrack(
        _ track: AudioExportTrackSnapshot,
        outputSampleRate: Double,
        gainPosition: AudioExportStemOptions.GainPosition
    ) throws -> PreparedRealtimeAudioTrack {
        let source: PreparedRealtimeAudioSource
        let playbackSegments: [AudioEditTimeline.PlaybackSegment]

        switch track.source {
        case let .decoded(buffer):
            guard let preparedSource = PreparedRealtimeAudioSource.make(from: buffer) else {
                throw AudioExportRenderer.RenderError.invalidSource(track.name)
            }
            source = preparedSource
            playbackSegments = []
        case let .decodedSegments(buffer, segments):
            guard let preparedSource = PreparedRealtimeAudioSource.make(from: buffer) else {
                throw AudioExportRenderer.RenderError.invalidSource(track.name)
            }
            source = preparedSource
            playbackSegments = segments
        case let .timeline(timeline):
            guard
                let preparedSource = PreparedRealtimeAudioSource.make(
                    from: timeline.sourceAudioBuffer
                )
            else {
                throw AudioExportRenderer.RenderError.invalidSource(track.name)
            }
            source = preparedSource
            playbackSegments = timeline.playbackSegments
        case let .file(url, _):
            guard let preparedSource = try PreparedRealtimeAudioSource.makeMappedWAV(url: url) else {
                throw AudioExportRenderer.RenderError.invalidSource(track.name)
            }
            source = preparedSource
            playbackSegments = []
        case let .fileSegments(url, _, segments):
            guard let preparedSource = try PreparedRealtimeAudioSource.makeMappedWAV(url: url) else {
                throw AudioExportRenderer.RenderError.invalidSource(track.name)
            }
            source = preparedSource
            playbackSegments = segments
        case let .fileTimeline(url, _, timeline):
            guard let preparedSource = try PreparedRealtimeAudioSource.makeMappedWAV(url: url) else {
                throw AudioExportRenderer.RenderError.invalidSource(track.name)
            }
            source = preparedSource
            playbackSegments = timeline.playbackSegments
        }

        let segments = try playbackSegments.map { segment in
            try convertedSegment(
                segment,
                sourceSampleRate: source.sampleRate,
                outputSampleRate: outputSampleRate,
                trackName: track.name
            )
        }
        let gain: Float
        let volumeAutomation: [PreparedRealtimeAutomationPoint]
        let pan: Float
        let panAutomation: [PreparedRealtimeAutomationPoint]
        let muteAutomation: [PreparedRealtimeAutomationPoint]
        switch gainPosition {
        case .preFader:
            gain = 1
            volumeAutomation = []
            pan = 0
            panAutomation = []
            muteAutomation = []
        case .postFader:
            if track.volumeAutomation.isEmpty {
                let clampedVolume = min(max(track.volume, 0), 1)
                gain = clampedVolume * clampedVolume
            } else {
                // Volume automation drives the fader; it is not an additional gain stage.
                gain = 1
            }
            volumeAutomation = track.volumeAutomation.map {
                let normalizedValue = min(max($0.normalizedValue, 0), 1)
                return PreparedRealtimeAutomationPoint(
                    frame: $0.frame,
                    gain: normalizedValue * normalizedValue,
                    curveToNext: $0.curveToNext
                )
            }
            pan = track.pan
            panAutomation = track.panAutomation.map {
                PreparedRealtimeAutomationPoint(
                    frame: $0.frame,
                    gain: $0.normalizedValue,
                    curveToNext: $0.curveToNext
                )
            }
            muteAutomation = track.muteAutomation.map {
                PreparedRealtimeAutomationPoint(
                    frame: $0.frame,
                    gain: $0.normalizedValue >= 0.5 ? 0 : 1,
                    curveToNext: TimelineAutomationCurve.stepped
                )
            }
        }

        return PreparedRealtimeAudioTrack(
            source: source,
            gain: gain,
            pan: pan,
            segments: segments,
            volumeAutomation: volumeAutomation,
            panAutomation: panAutomation,
            muteAutomation: muteAutomation
        )
    }

    private static func convertedSegment(
        _ segment: AudioEditTimeline.PlaybackSegment,
        sourceSampleRate: Double,
        outputSampleRate: Double,
        trackName: String
    ) throws -> PreparedRealtimeAudioSegment {
        guard let projected = AudioTimelineSampleRateProjection.project(
            segment,
            timelineSampleRate: sourceSampleRate,
            outputSampleRate: outputSampleRate
        ) else {
            throw AudioExportRenderer.RenderError.invalidSource(trackName)
        }

        return PreparedRealtimeAudioSegment(
            outputStartFrame: projected.outputStartFrame,
            sourceStartFrame: projected.sourceStartFrame,
            frameCount: projected.frameCount,
            sourceFrameScale: projected.sourceFrameScale,
            gainStart: projected.gainStart,
            gainEnd: projected.gainEnd
        )
    }
}
