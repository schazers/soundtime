import Foundation

enum ProjectLaunchPreviewWaveformCacheHydrator {
    static func hydratedProject(
        _ project: SoundtimeProject,
        waveformOverviewDiskCache: WaveformOverviewDiskCacheStore,
        cacheMaximumBinCount: Int = ProjectLaunchHydrationDefaults.firstRefinementBinCount,
        previewMaximumBinCount: Int = ProjectLaunchSnapshot.maximumOverviewBinCount
    ) -> SoundtimeProject {
        var hydratedProject = project
        hydratedProject.tracks = project.tracks.map { track in
            hydratedTrack(
                track,
                waveformOverviewDiskCache: waveformOverviewDiskCache,
                cacheMaximumBinCount: cacheMaximumBinCount,
                previewMaximumBinCount: previewMaximumBinCount
            )
        }
        return hydratedProject
    }

    static func hydratedTrack(
        _ track: SoundtimeProject.Track,
        waveformOverviewDiskCache: WaveformOverviewDiskCacheStore,
        cacheMaximumBinCount: Int = ProjectLaunchHydrationDefaults.firstRefinementBinCount,
        previewMaximumBinCount: Int = ProjectLaunchSnapshot.maximumOverviewBinCount
    ) -> SoundtimeProject.Track {
        let sourceURL = URL(fileURLWithPath: track.filePath).standardizedFileURL
        guard let fileInfo = try? WAVAudioDecoder.inspect(url: sourceURL) else {
            return track
        }

        let validPreview = track.waveformPreview?.isValid(for: fileInfo) == true ? track.waveformPreview : nil
        let restoredTimeline = restoredTimeline(from: track.editTimeline, fileInfo: fileInfo)
        let cachedSourceOverview = (try? waveformOverviewDiskCache.loadBestOverview(
            for: sourceURL,
            fileInfo: fileInfo,
            maximumBinCount: cacheMaximumBinCount
        ))?.overview

        let cachedDisplayOverview: WaveformOverview?
        if let restoredTimeline, restoredTimeline.hasEdits {
            cachedDisplayOverview = (try? waveformOverviewDiskCache.loadEditedOverview(
                for: sourceURL,
                fileInfo: fileInfo,
                editTimeline: restoredTimeline
            ))?.overview
        } else {
            cachedDisplayOverview = nil
        }

        let previewSourceOverview = validPreview?.sourceOverview.waveformOverview
        let previewDisplayOverview = validPreview?.displayOverview.waveformOverview
        let sourceOverview = bestOverview(cachedSourceOverview, previewSourceOverview)
        let displayOverview: WaveformOverview?
        if restoredTimeline?.hasEdits == true {
            displayOverview = cachedDisplayOverview ?? previewDisplayOverview ?? sourceOverview
        } else {
            displayOverview = bestOverview(cachedSourceOverview, previewDisplayOverview)
        }

        guard
            let drawableOverview = displayOverview ?? sourceOverview,
            let waveformPreview = SoundtimeProject.WaveformPreview(
                sourceOverview: sourceOverview ?? drawableOverview,
                displayOverview: drawableOverview,
                fileInfo: fileInfo,
                maximumBinCount: previewMaximumBinCount
            )
        else {
            return track
        }

        var hydratedTrack = track
        hydratedTrack.waveformPreview = waveformPreview
        return hydratedTrack
    }

    private static func restoredTimeline(
        from persistentState: AudioFileEditTimeline.PersistentState?,
        fileInfo: WAVFileInfo
    ) -> AudioFileEditTimeline? {
        guard
            let persistentState,
            let timeline = AudioFileEditTimeline(persistentState: persistentState),
            timeline.isCompatible(with: fileInfo)
        else {
            return nil
        }
        return timeline
    }

    private static func bestOverview(
        _ first: WaveformOverview?,
        _ second: WaveformOverview?
    ) -> WaveformOverview? {
        guard let first else {
            return second
        }
        guard let second else {
            return first
        }
        return first.bins.count >= second.bins.count ? first : second
    }
}
