import AVFoundation
import Foundation

private final class AudioAssetImporterSmokeResultBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}

enum AudioAssetImporterSmokeHarness {
    private enum SmokeError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(message):
                return message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundtime-audio-asset-importer-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootDirectory)
        }

        try verifyCommonFormatRecognition()
        try verifyWAVFacadeRoundTrip(rootDirectory: rootDirectory)
        let nativeMetrics = try verifyNativeEditableProxyImport(rootDirectory: rootDirectory)
        try verifyCanceledTransactionCleanup(rootDirectory: rootDirectory)
        try verifyCorruptCacheQuarantine(rootDirectory: rootDirectory)
        try verifyFingerprintInvalidation(rootDirectory: rootDirectory)
        try verifyPersistedProxyFallback(rootDirectory: rootDirectory)
        try verifyCoordinatorCancellation(rootDirectory: rootDirectory)

        let checks = [
            "common audio format recognition",
            "wav importer facade preview/decode round trip",
            "native audio streaming proxy and cache reuse",
            "stable logical identity and edit remap across proxy promotion",
            "transaction cancellation removes staged artifacts",
            "corrupt cache is quarantined and regenerated",
            "source mutation invalidates reusable import artifacts",
            "missing persisted proxy falls back to original with edits intact",
            "coordinator cancellation reaches queued conversion work",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "audio-asset-importer-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: [
                "nonWAVDecode": "native-avfoundation-streaming-proxy",
                "firstPreparationMilliseconds": String(
                    format: "%.3f",
                    nativeMetrics.firstPreparationMilliseconds
                ),
                "admissionMilliseconds": String(
                    format: "%.3f",
                    nativeMetrics.admissionMilliseconds
                ),
                "cachedPreparationMilliseconds": String(
                    format: "%.3f",
                    nativeMetrics.cachedPreparationMilliseconds
                ),
                "peakWorkingSetBytes": "\(nativeMetrics.peakWorkingSetBytes)",
                "cacheHit": "true",
            ],
            arguments: arguments
        ) {
            print("Soundtime audio asset importer smoke report: \(reportURL.path)")
        }
        print("Soundtime audio asset importer smoke passed")
    }

    private static func verifyCommonFormatRecognition() throws {
        let expectedFormats: [(String, AudioAssetFormat)] = [
            ("voice.wav", .wav),
            ("voice.wave", .wav),
            ("music.aiff", .aiff),
            ("music.aif", .aiff),
            ("music.aifc", .aiff),
            ("episode.mp3", .mp3),
            ("mix.m4a", .mpeg4Audio),
            ("movie.mp4", .mpeg4Audio),
            ("lossless.alac", .mpeg4Audio),
            ("clip.aac", .aac),
            ("master.flac", .flac),
            ("recording.caf", .caf),
            ("archive.ogg", .ogg),
            ("archive.oga", .ogg),
            ("call.opus", .opus),
            ("legacy.wma", .wma),
            ("surround.ac3", .ac3),
            ("surround.eac3", .ac3),
            ("phone.amr", .amr),
            ("sample.au", .au),
            ("sample.snd", .au),
        ]

        for (fileName, format) in expectedFormats {
            let url = URL(fileURLWithPath: "/tmp/\(fileName)")
            try require(AudioAssetFormat.inferred(from: url) == format, "\(fileName) inferred wrong format")
        }

        let importableFileNames = [
            "voice.wav",
            "voice.wave",
            "music.aiff",
            "music.aif",
            "music.aifc",
            "episode.mp3",
            "mix.m4a",
            "movie.mp4",
            "lossless.alac",
            "clip.aac",
            "master.flac",
            "recording.caf",
            "surround.ac3",
            "surround.eac3",
            "phone.amr",
            "sample.au",
            "sample.snd",
        ]
        for fileName in importableFileNames {
            try require(
                AudioAssetImporter.canImport(URL(fileURLWithPath: "/tmp/\(fileName)")),
                "\(fileName) was not importable"
            )
        }

        let recognizedButUnsupportedFileNames = [
            "archive.ogg",
            "archive.oga",
            "call.opus",
            "legacy.wma",
        ]
        for fileName in recognizedButUnsupportedFileNames {
            try require(
                !AudioAssetImporter.canImport(URL(fileURLWithPath: "/tmp/\(fileName)")),
                "\(fileName) should be recognized but not accepted by the native importer"
            )
        }

        let unknownURL = URL(fileURLWithPath: "/tmp/not-audio.xyz")
        try require(AudioAssetFormat.inferred(from: unknownURL) == .unknown, "unknown format inference failed")
        try require(!AudioAssetImporter.canImport(unknownURL), "unknown format should not be importable")
    }

    private static func verifyWAVFacadeRoundTrip(rootDirectory: URL) throws {
        let wavURL = rootDirectory.appendingPathComponent("Facade.wav")
        let buffer = makeSyntheticBuffer(url: wavURL)
        try WAVFileWriter.write(buffer, to: wavURL)

        let info = try AudioAssetImporter.inspectSynchronously(url: wavURL)
        try require(info.format == .wav, "wav facade did not report WAV format")
        try require(info.wavFileInfo?.sampleRate == buffer.sampleRate, "wav facade sample rate mismatch")
        try require(info.wavFileInfo?.channelCount == buffer.channelCount, "wav facade channel count mismatch")
        try require(info.supportsSparsePreview, "wav facade should support sparse preview")
        try require(info.supportsFileBackedEditing, "wav facade should support file-backed editing")

        let preview = try awaitValue {
            try await AudioAssetImporter.loadPreview(
                at: wavURL,
                targetBinCount: 64,
                samplesPerBin: 8
            )
        }
        try require(preview.assetInfo.format == .wav, "preview facade did not report WAV format")
        try require(!preview.waveformOverview.bins.isEmpty, "preview facade returned empty waveform")
        try require(preview.wavPreviewResult != nil, "preview facade did not bridge back to WAV preview result")

        let decoded = try awaitValue {
            try await AudioAssetImporter.loadDecodedAsset(at: wavURL)
        }
        try require(decoded.0.format == .wav, "decoded facade did not report WAV format")
        try require(decoded.1.frameCount == buffer.frameCount, "decoded facade frame count mismatch")
        try require(!decoded.2.bins.isEmpty, "decoded facade returned empty waveform")
    }

    private struct NativeImportMetrics {
        let admissionMilliseconds: Double
        let firstPreparationMilliseconds: Double
        let cachedPreparationMilliseconds: Double
        let peakWorkingSetBytes: Int
    }

    private static func verifyNativeEditableProxyImport(
        rootDirectory: URL
    ) throws -> NativeImportMetrics {
        let aiffURL = rootDirectory.appendingPathComponent("NativeImport.aiff")
        let sourceBuffer = makeSyntheticBuffer(url: aiffURL, sampleRate: 44_100, frameCount: 8_192)
        try writeNativeAudioFixture(sourceBuffer, to: aiffURL)

        let info = try AudioAssetImporter.inspectSynchronously(url: aiffURL)
        try require(info.format == .aiff, "native importer did not report AIFF format")
        try require(info.wavFileInfo == nil, "native importer should not report WAV file info for AIFF")
        try require(info.sampleRate == sourceBuffer.sampleRate, "native importer sample rate mismatch")
        try require(info.channelCount == sourceBuffer.channelCount, "native importer channel count mismatch")
        try require(info.requiresEditableProxy, "native importer should require an editable proxy")

        let preview = try awaitValue {
            try await AudioAssetImporter.loadPreview(
                at: aiffURL,
                targetBinCount: 512,
                samplesPerBin: 64
            )
        }
        try require(preview.assetInfo.format == .aiff, "native preview did not report AIFF format")
        try require(preview.wavPreviewResult == nil, "native preview should not bridge to WAV preview result")
        try require(preview.waveformOverview.bins.count == 512, "native preview bin count mismatch")
        try require(!preview.waveformOverview.bins.allSatisfy { $0.peakMagnitude == 0 }, "native preview was silent")

        let decoded = try awaitValue {
            try await AudioAssetImporter.loadDecodedAsset(at: aiffURL)
        }
        try require(decoded.0.format == .aiff, "native decoded asset did not report AIFF format")
        try require(decoded.1.sampleRate == sourceBuffer.sampleRate, "native decoded sample rate mismatch")
        try require(decoded.1.frameCount == sourceBuffer.frameCount, "native decoded frame count mismatch")
        try require(!decoded.2.bins.isEmpty, "native decoded waveform was empty")

        let importedAssetID = UUID()
        let (admission, proxyResult) = try awaitValue {
            let coordinator = AudioImportCoordinator.shared
            let admission = try await coordinator.admit(
                sourceURL: aiffURL,
                assetID: importedAssetID
            )
            let task = await coordinator.startPreparingEditableAsset(admission: admission)
            do {
                let result = try await task.value
                await coordinator.forget(sessionID: admission.sessionID)
                return (admission, result)
            } catch {
                await coordinator.forget(sessionID: admission.sessionID)
                throw error
            }
        }
        defer {
            AudioImportCacheStore.shared.removeCache(for: proxyResult.fingerprint)
        }
        try require(!proxyResult.usesOriginalFile, "native import should create a proxy")
        try require(!proxyResult.cacheHit, "first native import unexpectedly hit the cache")
        try require(proxyResult.assetID == importedAssetID, "first import lost its logical asset identity")
        try require(proxyResult.proxyURL.pathExtension.lowercased() == "wav", "native import proxy should be a WAV")
        try require(WAVAudioDecoder.canDecode(proxyResult.proxyURL), "native import proxy was not decodable as WAV")
        try require(
            abs(proxyResult.proxyFileInfo.sampleRate - AudioAssetImporter.editableProxySampleRate) < 0.5,
            "native import proxy did not normalize sample rate"
        )
        try require(proxyResult.proxyFileInfo.frameCount > 0, "native import proxy was empty")
        try require(
            proxyResult.peakWorkingSetBytes <= AudioImportPerformanceContract.maximumWorkingSetBytes,
            "native import exceeded its bounded working-set contract"
        )
        try require(
            !proxyResult.zeroCrossingIndex.isEmpty,
            "first native import did not retain its bounded zero-crossing index"
        )

        var originalTimeline = AudioFileEditTimeline(
            sourceFrameCount: sourceBuffer.frameCount,
            sourceSampleRate: sourceBuffer.sampleRate
        )
        let framesToDelete = max(sourceBuffer.frameCount / 4, 1)
        let beginningSelection = TimelineSelection(
            startProgress: 0,
            endProgress: Double(framesToDelete) / Double(max(sourceBuffer.frameCount, 1))
        )
        let deletedFrames = originalTimeline.delete(beginningSelection)
        try require(
            deletedFrames == framesToDelete,
            "native original timeline delete removed \(deletedFrames) frames, expected \(framesToDelete)"
        )
        guard let proxyTimeline = originalTimeline.remapped(
            toSourceFrameCount: proxyResult.proxyFileInfo.frameCount,
            sampleRate: proxyResult.proxyFileInfo.sampleRate
        ) else {
            throw SmokeError.failed("native edit timeline could not be remapped to the proxy")
        }
        let originalEditedDuration = originalTimeline.duration
        try require(
            abs(proxyTimeline.duration - originalEditedDuration) <
                (2 / proxyResult.proxyFileInfo.sampleRate),
            "proxy promotion changed the edited timeline duration"
        )

        let originalSource = EditableAudioSource(
            importedAssetID: importedAssetID,
            originalURL: aiffURL,
            editableURL: aiffURL,
            formatOrigin: .aiff,
            sourceFrameCount: sourceBuffer.frameCount,
            sourceSampleRate: sourceBuffer.sampleRate,
            channelCount: sourceBuffer.channelCount,
            ownsEditableFile: false
        )
        let proxySource = EditableAudioSource(
            importedAssetID: importedAssetID,
            originalURL: aiffURL,
            editableURL: proxyResult.proxyURL,
            formatOrigin: .aiff,
            fileInfo: proxyResult.proxyFileInfo,
            ownsEditableFile: false
        )
        try require(
            originalSource.id == proxySource.id,
            "proxy promotion changed the logical editable source identity"
        )

        let cachedAssetID = UUID()
        let cachedResult = try awaitValue {
            try await AudioAssetImporter.importEditableAsset(
                at: aiffURL,
                assetID: cachedAssetID
            )
        }
        try require(cachedResult.cacheHit, "second native import did not reuse the cache")
        try require(cachedResult.assetID == cachedAssetID, "cache reuse leaked another track's asset identity")
        try require(
            cachedResult.proxyURL.standardizedFileURL == proxyResult.proxyURL.standardizedFileURL,
            "cache reuse produced a different proxy URL"
        )
        try require(
            cachedResult.zeroCrossingIndex.persistedCrossings ==
                proxyResult.zeroCrossingIndex.persistedCrossings,
            "cache reuse did not restore zero-crossing data"
        )

        return NativeImportMetrics(
            admissionMilliseconds: admission.admissionMilliseconds,
            firstPreparationMilliseconds: proxyResult.preparationMilliseconds,
            cachedPreparationMilliseconds: cachedResult.preparationMilliseconds,
            peakWorkingSetBytes: proxyResult.peakWorkingSetBytes
        )
    }

    private static func verifyCanceledTransactionCleanup(rootDirectory: URL) throws {
        let sourceURL = rootDirectory.appendingPathComponent("CanceledSource.aiff")
        let buffer = makeSyntheticBuffer(url: sourceURL, sampleRate: 44_100, frameCount: 1_024)
        try writeNativeAudioFixture(buffer, to: sourceURL)
        let info = try AudioAssetImporter.inspectSynchronously(url: sourceURL)
        let fingerprint = try AudioImportFingerprint(url: sourceURL, assetInfo: info)
        let cache = AudioImportCacheStore(
            rootDirectory: rootDirectory.appendingPathComponent("CanceledCache", isDirectory: true)
        )
        let transaction = try cache.beginTransaction(for: fingerprint)
        try Data("partial".utf8).write(to: transaction.stagedProxyURL)
        try require(
            FileManager.default.fileExists(atPath: transaction.directory.path),
            "test transaction was not staged"
        )
        cache.cancel(transaction)
        try require(
            !FileManager.default.fileExists(atPath: transaction.directory.path),
            "cancel left a staged import transaction on disk"
        )
    }

    private static func verifyCorruptCacheQuarantine(rootDirectory: URL) throws {
        let sourceURL = rootDirectory.appendingPathComponent("CacheSource.aiff")
        let sourceBuffer = makeSyntheticBuffer(
            url: sourceURL,
            sampleRate: 44_100,
            frameCount: 4_096
        )
        try writeNativeAudioFixture(sourceBuffer, to: sourceURL)
        let assetInfo = try AudioAssetImporter.inspectSynchronously(url: sourceURL)
        let fingerprint = try AudioImportFingerprint(url: sourceURL, assetInfo: assetInfo)
        let cacheRoot = rootDirectory.appendingPathComponent("CorruptCache", isDirectory: true)
        let cache = AudioImportCacheStore(rootDirectory: cacheRoot)
        let transaction = try cache.beginTransaction(for: fingerprint)
        let proxyBuffer = makeSyntheticBuffer(
            url: transaction.stagedProxyURL,
            sampleRate: 48_000,
            frameCount: 4_458
        )
        try WAVFileWriter.write(proxyBuffer, to: transaction.stagedProxyURL)
        let fileInfo = try WAVAudioDecoder.inspect(url: transaction.stagedProxyURL)
        let overview = WaveformOverviewBuilder.build(from: proxyBuffer)
        let crossings = AudioZeroCrossingIndex.build(from: proxyBuffer)
        let manifest = AudioImportManifest(
            assetID: UUID(),
            fingerprint: fingerprint,
            originalURL: sourceURL,
            format: .aiff,
            displayName: "Cache Source",
            proxyFileName: transaction.stagedProxyURL.lastPathComponent,
            sourceSampleRate: sourceBuffer.sampleRate,
            sourceFrameCount: Int64(sourceBuffer.frameCount),
            proxySampleRate: fileInfo.sampleRate,
            proxyFrameCount: Int64(fileInfo.frameCount),
            channelCount: fileInfo.channelCount
        )
        let committed = try cache.commit(
            transaction,
            manifest: manifest,
            waveformOverview: overview,
            zeroCrossingIndex: crossings
        )
        try Data("corrupt proxy".utf8).write(to: committed.proxyURL, options: [.atomic])
        try require(
            cache.cachedImport(for: fingerprint, sourceURL: sourceURL) == nil,
            "corrupt cache was treated as usable"
        )
        let quarantineURL = cacheRoot.appendingPathComponent("Quarantine", isDirectory: true)
        let quarantineEntries = try? FileManager.default.contentsOfDirectory(
            at: quarantineURL,
            includingPropertiesForKeys: nil
        )
        try require(
            !(quarantineEntries ?? []).isEmpty,
            "corrupt cache was not quarantined"
        )
    }

    private static func verifyFingerprintInvalidation(rootDirectory: URL) throws {
        let sourceURL = rootDirectory.appendingPathComponent("MutableSource.aiff")
        let buffer = makeSyntheticBuffer(
            url: sourceURL,
            sampleRate: 44_100,
            frameCount: 2_048
        )
        try writeNativeAudioFixture(buffer, to: sourceURL)
        let info = try AudioAssetImporter.inspectSynchronously(url: sourceURL)
        let fingerprint = try AudioImportFingerprint(url: sourceURL, assetInfo: info)
        try require(
            fingerprint.isCurrent(for: sourceURL),
            "new source fingerprint was not current"
        )

        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        try require(
            !fingerprint.isCurrent(for: sourceURL),
            "source mutation did not invalidate its import fingerprint"
        )
    }

    private static func verifyPersistedProxyFallback(rootDirectory: URL) throws {
        let sourceURL = rootDirectory.appendingPathComponent("RecoverySource.aiff")
        let sourceBuffer = makeSyntheticBuffer(
            url: sourceURL,
            sampleRate: 44_100,
            frameCount: 8_192
        )
        try writeNativeAudioFixture(sourceBuffer, to: sourceURL)
        let assetInfo = try AudioAssetImporter.inspectSynchronously(url: sourceURL)
        let fingerprint = try AudioImportFingerprint(url: sourceURL, assetInfo: assetInfo)
        let assetID = UUID()
        let missingProxyURL = rootDirectory.appendingPathComponent("MissingProxy.wav")
        var timeline = AudioFileEditTimeline(
            sourceFrameCount: sourceBuffer.frameCount,
            sourceSampleRate: sourceBuffer.sampleRate
        )
        _ = timeline.delete(TimelineSelection(startProgress: 0.1, endProgress: 0.2))
        let missingProxySource = EditableAudioSource(
            importedAssetID: assetID,
            originalURL: sourceURL,
            editableURL: missingProxyURL,
            formatOrigin: .aiff,
            sourceFrameCount: sourceBuffer.frameCount,
            sourceSampleRate: sourceBuffer.sampleRate,
            channelCount: sourceBuffer.channelCount,
            ownsEditableFile: false
        )
        let track = SoundtimeProject.Track(
            id: UUID(),
            name: "Recovery Source",
            filePath: missingProxyURL.path,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            editTimeline: timeline.persistentState,
            editableSource: SoundtimeProject.Track.EditableSource(missingProxySource),
            importedAssetState: SoundtimeProject.Track.ImportedAssetState(
                assetID: assetID,
                originalURL: sourceURL,
                format: .aiff,
                fingerprint: fingerprint,
                stage: .complete
            )
        )
        let primed = try ProjectLaunchPlaybackPrimer.prime(track: track)
        try require(
            primed.sourceURL.standardizedFileURL == sourceURL.standardizedFileURL,
            "missing proxy did not fall back to the original asset"
        )
        try require(
            primed.editableSource.editableURL.standardizedFileURL ==
                sourceURL.standardizedFileURL,
            "fallback retained the missing proxy as its editable source"
        )
        try require(
            primed.editableSource.importedAssetID == assetID,
            "fallback changed the imported asset identity"
        )
        try require(
            primed.fileTimeline?.frameCount == timeline.frameCount,
            "fallback did not preserve the edited timeline"
        )
    }

    private static func verifyCoordinatorCancellation(rootDirectory: URL) throws {
        let sourceURL = rootDirectory.appendingPathComponent("CoordinatorCancel.aiff")
        let sourceBuffer = makeSyntheticBuffer(
            url: sourceURL,
            sampleRate: 44_100,
            frameCount: 65_536
        )
        try writeNativeAudioFixture(sourceBuffer, to: sourceURL)

        try awaitValue {
            let coordinator = AudioImportCoordinator.shared
            let admission = try await coordinator.admit(sourceURL: sourceURL)
            let releaseBlocker = DispatchSemaphore(value: 0)
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    try? ImportWorkBudget.shared.performScheduledHeavyWork(.backgroundDecode) {
                        continuation.resume()
                        releaseBlocker.wait()
                    }
                }
            }
            let task = await coordinator.startPreparingEditableAsset(admission: admission)
            await coordinator.cancel(sessionID: admission.sessionID)
            releaseBlocker.signal()

            do {
                _ = try await task.value
                throw SmokeError.failed("canceled coordinator import completed successfully")
            } catch is CancellationError {
                // Expected.
            }
            let snapshot = await coordinator.snapshot(sessionID: admission.sessionID)
            guard snapshot?.stage == .canceled else {
                throw SmokeError.failed("canceled coordinator session did not stay canceled")
            }
            await coordinator.forget(sessionID: admission.sessionID)
        }
    }

    private static func makeSyntheticBuffer(
        url: URL,
        sampleRate: Double = 48_000,
        frameCount: Int = 4_096
    ) -> DecodedAudioBuffer {
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        for frameIndex in 0..<frameCount {
            let t = Double(frameIndex) / sampleRate
            left[frameIndex] = Float(sin(t * .pi * 2 * 440) * 0.42)
            right[frameIndex] = Float(sin(t * .pi * 2 * 660) * 0.32)
        }

        return DecodedAudioBuffer(
            url: url,
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [left, right]
        )
    }

    private static func writeNativeAudioFixture(_ buffer: DecodedAudioBuffer, to url: URL) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.sampleRate,
                channels: AVAudioChannelCount(buffer.channelCount),
                interleaved: false
            ),
            let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(buffer.frameCount)
            )
        else {
            throw SmokeError.failed("could not create native fixture audio buffer")
        }

        pcmBuffer.frameLength = AVAudioFrameCount(buffer.frameCount)
        guard let floatChannelData = pcmBuffer.floatChannelData else {
            throw SmokeError.failed("native fixture buffer did not expose float channel data")
        }

        for channelIndex in 0..<buffer.channelCount {
            let source = channelIndex < buffer.samplesByChannel.count ?
                buffer.samplesByChannel[channelIndex] :
                []
            for frameIndex in 0..<buffer.frameCount {
                floatChannelData[channelIndex][frameIndex] = frameIndex < source.count ? source[frameIndex] : 0
            }
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: pcmBuffer)
    }

    private static func awaitValue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = AudioAssetImporterSmokeResultBox<T>()

        Task {
            do {
                box.result = Result.success(try await operation())
            } catch {
                box.result = Result.failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()

        switch box.result {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        case nil:
            throw SmokeError.failed("async importer operation did not produce a result")
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw SmokeError.failed(message)
        }
    }
}
