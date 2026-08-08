import Foundation
import QuartzCore
import SoundtimeEditing

struct ProjectLaunchPlaybackPrimeTrack: Sendable {
    var trackID: UUID
    var sourceURL: URL
    var fileInfo: WAVFileInfo?
    var sampleRate: Double
    var fileTimeline: AudioFileEditTimeline?
    var editableSource: EditableAudioSource
    var ownsSourceFile: Bool
    var editRevision: Int
    var volume: Float
    var isMuted: Bool
    var isSoloed: Bool

    var playbackTrack: ProjectPlaybackTrack {
        let source: ProjectPlaybackTrack.Source
        if let fileTimeline, fileTimeline.hasEdits {
            source = .fileTimeline(
                url: sourceURL,
                timeline: fileTimeline,
                zeroCrossingProbe: nil
            )
        } else {
            source = .file(
                url: sourceURL,
                zeroCrossingProbe: nil
            )
        }

        return ProjectPlaybackTrack(
            id: trackID,
            source: source,
            sourceRevision: editRevision,
            volume: volume,
            isMuted: isMuted,
            isSoloed: isSoloed
        )
    }
}

struct ProjectLaunchPlaybackPrimeFailure: Sendable {
    var trackID: UUID
    var trackName: String
    var fileName: String
    var message: String
}

struct ProjectLaunchPlaybackPrimeResult: Sendable {
    var tracks: [ProjectLaunchPlaybackPrimeTrack]
    var playbackTracks: [ProjectPlaybackTrack]
    var failures: [ProjectLaunchPlaybackPrimeFailure]
    var elapsedMilliseconds: Double
    var expectedTrackCount: Int
    var usesCanonicalClipGraph: Bool

    var isComplete: Bool {
        tracks.count == expectedTrackCount &&
            !playbackTracks.isEmpty &&
            failures.isEmpty
    }

    var hasPlayableTracks: Bool {
        !playbackTracks.isEmpty
    }
}

enum ProjectLaunchPlaybackPrimer {
    private struct SourceProbe {
        var fileInfo: WAVFileInfo?
        var frameCount: Int
        var sampleRate: Double
        var channelCount: Int
    }

    static func prime(
        project: SoundtimeProject,
        projectURL: URL,
        activeTrackID: UUID?,
        selectedTrackIDs: Set<UUID>,
        playbackSnapshot: TimelinePlaybackSnapshot? = nil
    ) -> ProjectLaunchPlaybackPrimeResult {
        let startedAt = CACurrentMediaTime()
        var tracks: [ProjectLaunchPlaybackPrimeTrack] = []
        var failures: [ProjectLaunchPlaybackPrimeFailure] = []
        tracks.reserveCapacity(project.tracks.count)
        failures.reserveCapacity(1)
        var sourceProbesByURL: [URL: SourceProbe] = [:]

        _ = activeTrackID
        _ = selectedTrackIDs

        for track in project.tracks {
            do {
                tracks.append(try prime(track: track) { sourceURL in
                    let normalizedURL = sourceURL.standardizedFileURL
                    if let existing = sourceProbesByURL[normalizedURL] {
                        return existing
                    }
                    let probe = try sourceProbe(at: normalizedURL)
                    sourceProbesByURL[normalizedURL] = probe
                    return probe
                })
            } catch {
                failures.append(ProjectLaunchPlaybackPrimeFailure(
                    trackID: track.id,
                    trackName: track.name,
                    fileName: projectURL.lastPathComponent,
                    message: error.localizedDescription
                ))
            }
        }

        let playbackTracks: [ProjectPlaybackTrack]
        if let playbackSnapshot {
            do {
                playbackTracks = try ProjectPlaybackProjection.tracks(
                    from: playbackSnapshot,
                    fileInfo: { sourceURL in
                        let normalizedURL = sourceURL.standardizedFileURL
                        if let existing = sourceProbesByURL[normalizedURL] {
                            return existing.fileInfo
                        }
                        guard let sourceProbe = try? sourceProbe(at: normalizedURL) else {
                            return nil
                        }
                        sourceProbesByURL[normalizedURL] = sourceProbe
                        return sourceProbe.fileInfo
                    },
                    zeroCrossingProbe: { _, _ in nil }
                )
            } catch {
                playbackTracks = []
                failures.append(ProjectLaunchPlaybackPrimeFailure(
                    trackID: project.tracks.first?.id ?? UUID(),
                    trackName: project.tracks.first?.name ?? "Project",
                    fileName: projectURL.lastPathComponent,
                    message: "Canonical clip playback could not be primed: \(error.localizedDescription)"
                ))
            }
        } else {
            playbackTracks = tracks.map(\.playbackTrack)
        }

        return ProjectLaunchPlaybackPrimeResult(
            tracks: tracks,
            playbackTracks: playbackTracks,
            failures: failures,
            elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
            expectedTrackCount: project.tracks.count,
            usesCanonicalClipGraph: playbackSnapshot != nil
        )
    }

    static func prime(track: SoundtimeProject.Track) throws -> ProjectLaunchPlaybackPrimeTrack {
        try prime(track: track, probe: sourceProbe)
    }

    private static func prime(
        track: SoundtimeProject.Track,
        probe: (URL) throws -> SourceProbe
    ) throws -> ProjectLaunchPlaybackPrimeTrack {
        var lastError: Error?
        for sourceURL in track.audioSourceCandidateURLs {
            do {
                return try prime(
                    track: track,
                    sourceURL: sourceURL,
                    sourceProbe: probe(sourceURL)
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AudioAssetImporter.ImportError.unreadableNativeAudio(
            AudioAssetFormat.inferred(
                from: URL(fileURLWithPath: track.filePath).standardizedFileURL
            )
        )
    }

    private static func prime(
        track: SoundtimeProject.Track,
        sourceURL: URL,
        sourceProbe: SourceProbe
    ) throws -> ProjectLaunchPlaybackPrimeTrack {
        let fileInfo = sourceProbe.fileInfo
        let sourceFrameCount = sourceProbe.frameCount
        let sourceSampleRate = sourceProbe.sampleRate
        let channelCount = sourceProbe.channelCount
        let restoredTimeline: AudioFileEditTimeline?
        if
            let editTimeline = track.editTimeline,
            let timeline = AudioFileEditTimeline(persistentState: editTimeline),
            timeline.sourceFrameCount == sourceFrameCount,
            abs(timeline.sourceSampleRate - sourceSampleRate) < 0.001
        {
            restoredTimeline = timeline
        } else {
            restoredTimeline = nil
        }

        let editableSource: EditableAudioSource
        if let fileInfo {
            editableSource = track.editableSource?.editableAudioSource(fileInfo: fileInfo) ??
                EditableAudioSource(
                    importedAssetID: track.editableSource?.importedAssetID,
                    originalURL: track.editableSource.map { URL(fileURLWithPath: $0.originalFilePath) } ?? sourceURL,
                    editableURL: sourceURL,
                    formatOrigin: track.editableSource?.formatOrigin ?? AudioAssetFormat.inferred(from: sourceURL),
                    fileInfo: fileInfo,
                    ownsEditableFile: track.ownsSourceFile ?? false
                )
        } else if
            let restoredSource = track.editableSource?.editableAudioSource(),
            restoredSource.editableURL.standardizedFileURL == sourceURL
        {
            editableSource = restoredSource
        } else {
            let assetID = track.importedAssetState?.assetID ?? UUID()
            editableSource = EditableAudioSource(
                importedAssetID: assetID,
                originalURL: track.importedAssetState.map {
                    URL(fileURLWithPath: $0.originalFilePath)
                } ?? sourceURL,
                editableURL: sourceURL,
                formatOrigin: track.importedAssetState?.format ?? AudioAssetFormat.inferred(from: sourceURL),
                sourceFrameCount: sourceFrameCount,
                sourceSampleRate: sourceSampleRate,
                channelCount: channelCount,
                ownsEditableFile: false
            )
        }

        return ProjectLaunchPlaybackPrimeTrack(
            trackID: track.id,
            sourceURL: sourceURL,
            fileInfo: fileInfo,
            sampleRate: sourceSampleRate,
            fileTimeline: restoredTimeline,
            editableSource: editableSource,
            ownsSourceFile: track.ownsSourceFile ?? false,
            editRevision: restoredTimeline?.hasEdits == true ? 1 : 0,
            volume: track.volume,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed
        )
    }

    private static func sourceProbe(at sourceURL: URL) throws -> SourceProbe {
        let fileInfo = try? WAVAudioDecoder.inspect(url: sourceURL)
        let nativeInfo = fileInfo == nil ?
            try AudioAssetImporter.inspectSynchronously(url: sourceURL) :
            nil
        let frameCount = fileInfo?.frameCount ?? nativeInfo?.frameCount ?? 0
        let sampleRate = fileInfo?.sampleRate ?? nativeInfo?.sampleRate ?? 0
        let channelCount = fileInfo?.channelCount ?? nativeInfo?.channelCount ?? 0
        guard frameCount > 0, sampleRate > 0, channelCount > 0 else {
            throw AudioAssetImporter.ImportError.unreadableNativeAudio(
                AudioAssetFormat.inferred(from: sourceURL)
            )
        }
        return SourceProbe(
            fileInfo: fileInfo,
            frameCount: frameCount,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

}
