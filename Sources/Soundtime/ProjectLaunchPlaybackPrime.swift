import Foundation
import QuartzCore

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
    var failures: [ProjectLaunchPlaybackPrimeFailure]
    var elapsedMilliseconds: Double
    var expectedTrackCount: Int

    var isComplete: Bool {
        tracks.count == expectedTrackCount && failures.isEmpty
    }

    var hasPlayableTracks: Bool {
        !tracks.isEmpty
    }
}

enum ProjectLaunchPlaybackPrimer {
    static func prime(
        project: SoundtimeProject,
        projectURL: URL,
        activeTrackID: UUID?,
        selectedTrackIDs: Set<UUID>
    ) -> ProjectLaunchPlaybackPrimeResult {
        let startedAt = CACurrentMediaTime()
        var tracks: [ProjectLaunchPlaybackPrimeTrack] = []
        var failures: [ProjectLaunchPlaybackPrimeFailure] = []
        tracks.reserveCapacity(project.tracks.count)
        failures.reserveCapacity(1)

        _ = activeTrackID
        _ = selectedTrackIDs

        for track in project.tracks {
            do {
                tracks.append(try prime(track: track))
            } catch {
                failures.append(ProjectLaunchPlaybackPrimeFailure(
                    trackID: track.id,
                    trackName: track.name,
                    fileName: projectURL.lastPathComponent,
                    message: error.localizedDescription
                ))
            }
        }

        return ProjectLaunchPlaybackPrimeResult(
            tracks: tracks,
            failures: failures,
            elapsedMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000,
            expectedTrackCount: project.tracks.count
        )
    }

    static func prime(track: SoundtimeProject.Track) throws -> ProjectLaunchPlaybackPrimeTrack {
        var lastError: Error?
        for sourceURL in track.audioSourceCandidateURLs {
            do {
                return try prime(track: track, sourceURL: sourceURL)
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
        sourceURL: URL
    ) throws -> ProjectLaunchPlaybackPrimeTrack {
        let fileInfo = try? WAVAudioDecoder.inspect(url: sourceURL)
        let nativeInfo = fileInfo == nil ?
            try AudioAssetImporter.inspectSynchronously(url: sourceURL) :
            nil
        let sourceFrameCount = fileInfo?.frameCount ?? nativeInfo?.frameCount ?? 0
        let sourceSampleRate = fileInfo?.sampleRate ?? nativeInfo?.sampleRate ?? 0
        let channelCount = fileInfo?.channelCount ?? nativeInfo?.channelCount ?? 0
        guard sourceFrameCount > 0, sourceSampleRate > 0, channelCount > 0 else {
            throw AudioAssetImporter.ImportError.unreadableNativeAudio(
                AudioAssetFormat.inferred(from: sourceURL)
            )
        }
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

}
