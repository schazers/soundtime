import Foundation

final class AudioExportService: @unchecked Sendable {
    typealias ProgressCallback = @MainActor @Sendable (AudioExportProgress) -> Void
    typealias CompletionCallback = @MainActor @Sendable (UUID, Result<AudioExportResult, Error>) -> Void

    enum ExportError: LocalizedError {
        case noAudioToExport
        case unsupportedStemFormat
        case exportAlreadyActive

        var errorDescription: String? {
            switch self {
            case .noAudioToExport:
                return "There is no audio to export."
            case .unsupportedStemFormat:
                return "Stem export currently writes WAV files."
            case .exportAlreadyActive:
                return "Another export is already running. Cancel it or wait for it to finish."
            }
        }
    }

    var onProgress: ProgressCallback?
    var onCompletion: CompletionCallback?

    private let lock = NSLock()
    private var activeTask: Task<Void, Never>?
    private var activeTaskID: UUID?

    var hasActiveExport: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return activeTaskID != nil
    }

    func start(snapshot: AudioExportSnapshot) throws {
        let request = snapshot.request
        lock.lock()
        guard activeTaskID == nil else {
            lock.unlock()
            throw ExportError.exportAlreadyActive
        }
        activeTaskID = request.id
        lock.unlock()

        let lease = AudioExportLeaseManager.shared.acquire(urls: snapshot.leasedURLs, jobID: request.id)
        let service = self
        emit(.initial(request: request))

        let task = Task.detached(priority: .utility) { [snapshot, lease, service] in
            let startedAt = Date()
            do {
                let completedWrite = try Self.performExport(snapshot: snapshot) { fraction, stage, message in
                    service.emit(AudioExportProgress(
                        jobID: snapshot.request.id,
                        request: snapshot.request,
                        stage: stage,
                        fractionCompleted: min(max(fraction, 0), 0.96),
                        message: message,
                        outputURLs: []
                    ))
                }
                let reportURL = Self.writeReportIfPossible(
                    snapshot: snapshot,
                    outputURLs: completedWrite.outputURLs,
                    startedAt: startedAt,
                    renderStats: completedWrite.renderStats,
                    validations: completedWrite.validations
                )
                let result = AudioExportResult(
                    request: snapshot.request,
                    outputURLs: completedWrite.outputURLs,
                    elapsedSeconds: Date().timeIntervalSince(startedAt),
                    renderedFrameCount: completedWrite.renderStats.renderedFrameCount,
                    renderStats: completedWrite.renderStats,
                    validations: completedWrite.validations,
                    reportURL: reportURL
                )

                service.emit(AudioExportProgress(
                    jobID: snapshot.request.id,
                    request: snapshot.request,
                    stage: .completed,
                    fractionCompleted: 1,
                    message: "Export complete",
                    outputURLs: completedWrite.outputURLs
                ))
                service.finish(
                    jobID: snapshot.request.id,
                    result: .success(result),
                    lease: lease
                )
            } catch is CancellationError {
                service.emit(AudioExportProgress(
                    jobID: snapshot.request.id,
                    request: snapshot.request,
                    stage: .canceled,
                    fractionCompleted: 0,
                    message: "Export canceled",
                    outputURLs: []
                ))
                service.finish(
                    jobID: snapshot.request.id,
                    result: .failure(CancellationError()),
                    lease: lease
                )
            } catch {
                service.emit(AudioExportProgress(
                    jobID: snapshot.request.id,
                    request: snapshot.request,
                    stage: .failed,
                    fractionCompleted: 0,
                    message: error.localizedDescription,
                    outputURLs: []
                ))
                service.finish(
                    jobID: snapshot.request.id,
                    result: .failure(error),
                    lease: lease
                )
            }
        }

        lock.lock()
        if activeTaskID == request.id {
            activeTask = task
        } else {
            task.cancel()
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = activeTask
        lock.unlock()
        task?.cancel()
    }

    private func finish(
        jobID: UUID,
        result: Result<AudioExportResult, Error>,
        lease: AudioExportAssetLease
    ) {
        AudioExportLeaseManager.shared.release(lease)
        lock.lock()
        if activeTaskID == jobID {
            activeTask = nil
            activeTaskID = nil
        }
        lock.unlock()
        complete(jobID: jobID, result: result)
    }

    private func emit(_ progress: AudioExportProgress) {
        Task { @MainActor [onProgress] in
            onProgress?(progress)
        }
    }

    private func complete(jobID: UUID, result: Result<AudioExportResult, Error>) {
        Task { @MainActor [onCompletion] in
            onCompletion?(jobID, result)
        }
    }

    private static func performExport(
        snapshot: AudioExportSnapshot,
        progressHandler: AudioExportRenderer.ProgressHandler?
    ) throws -> AudioExportCompletedWrite {
        try Task.checkCancellation()
        guard snapshot.frameCount > 0, !snapshot.tracks.isEmpty else {
            throw ExportError.noAudioToExport
        }
        try AudioExportPreflight.validate(snapshot: snapshot)

        if snapshot.request.scope.exportsStems {
            guard snapshot.request.format == .wav else {
                throw ExportError.unsupportedStemFormat
            }
            return try writeStems(snapshot: snapshot, progressHandler: progressHandler)
        }

        switch snapshot.request.format {
        case .wav:
            let finalURL = normalizedURL(snapshot.request.destinationURL, format: .wav)
            let transaction = try AudioExportFileTransaction(finalURL: finalURL)
            do {
                let writer = try AudioExportStreamingWAVWriter(
                    url: transaction.stagingURL,
                    sampleRate: snapshot.sampleRate,
                    channelCount: snapshot.channelCount,
                    encoding: snapshot.request.wavEncoding
                )
                let stats = try AudioExportRenderer.renderMixdown(
                    snapshot: snapshot,
                    to: writer,
                    progressHandler: progressHandler
                )
                try Task.checkCancellation()
                progressHandler?(0.97, .validating, "Validating WAV output")
                let validation = try AudioExportOutputValidator.validate(
                    url: transaction.stagingURL,
                    format: .wav,
                    expectedFrameCount: snapshot.frameCount,
                    expectedSampleRate: snapshot.sampleRate,
                    expectedChannelCount: snapshot.channelCount
                )
                try AudioExportPreflight.validateSourceIdentities(snapshot: snapshot)
                try Task.checkCancellation()
                progressHandler?(0.99, .committing, "Saving WAV output")
                let outputURL = try transaction.commit()
                return AudioExportCompletedWrite(
                    outputURLs: [outputURL],
                    renderStats: stats,
                    validations: [validation],
                    reportURL: nil
                )
            } catch {
                transaction.cancel()
                throw error
            }
        case .m4a, .aac, .mp3:
            return try writeCompressedMixdown(snapshot: snapshot, progressHandler: progressHandler)
        }
    }

    private static func writeCompressedMixdown(
        snapshot: AudioExportSnapshot,
        progressHandler: AudioExportRenderer.ProgressHandler?
    ) throws -> AudioExportCompletedWrite {
        let finalURL = normalizedURL(snapshot.request.destinationURL, format: snapshot.request.format)
        let transaction = try AudioExportFileTransaction(finalURL: finalURL)

        do {
            let writer = try AudioExportStreamingCompressedWriter(
                url: transaction.stagingURL,
                format: snapshot.request.format,
                sampleRate: snapshot.sampleRate,
                channelCount: snapshot.channelCount,
                bitRate: snapshot.request.compressedQuality.rawValue
            )
            let stats = try AudioExportRenderer.renderMixdown(
                snapshot: snapshot,
                to: writer,
                progressHandler: { fraction, _, message in
                progressHandler?(fraction * 0.96, .encoding, "\(message) and encoding \(snapshot.request.format.displayName)")
                }
            )
            try Task.checkCancellation()
            progressHandler?(0.97, .validating, "Validating \(snapshot.request.format.displayName) output")
            let validation = try AudioExportOutputValidator.validate(
                url: transaction.stagingURL,
                format: snapshot.request.format,
                expectedFrameCount: snapshot.frameCount,
                expectedSampleRate: snapshot.sampleRate,
                expectedChannelCount: snapshot.channelCount
            )
            try AudioExportPreflight.validateSourceIdentities(snapshot: snapshot)
            try Task.checkCancellation()
            progressHandler?(0.99, .committing, "Saving \(snapshot.request.format.displayName) output")
            let outputURL = try transaction.commit()
            return AudioExportCompletedWrite(
                outputURLs: [outputURL],
                renderStats: stats,
                validations: [validation],
                reportURL: nil
            )
        } catch {
            transaction.cancel()
            throw error
        }
    }

    private static func writeStems(
        snapshot: AudioExportSnapshot,
        progressHandler: AudioExportRenderer.ProgressHandler?
    ) throws -> AudioExportCompletedWrite {
        let folderURL = snapshot.request.destinationURL
        let transaction = try AudioExportStemTransaction(finalFolderURL: folderURL)
        var usedNames = Set<String>()
        var outputURLs: [URL] = []
        var validations: [AudioExportOutputValidator.Validation] = []
        var combinedStats = AudioExportRenderStats.empty
        let includesMixdown: Bool
        if case let .stems(includeMixdown, _) = snapshot.request.scope {
            includesMixdown = includeMixdown
        } else {
            includesMixdown = false
        }

        let totalWriteCount = snapshot.tracks.count + (includesMixdown ? 1 : 0)
        var completedWriteCount = 0

        if includesMixdown {
            let mixURL = uniqueURL(
                in: folderURL,
                baseName: "\(snapshot.request.projectName)-mixdown",
                extension: "wav",
                usedNames: &usedNames
            )
            let stagedURL = transaction.stageURL(for: mixURL)
            let writer = try AudioExportStreamingWAVWriter(
                url: stagedURL,
                sampleRate: snapshot.sampleRate,
                channelCount: snapshot.channelCount,
                encoding: snapshot.request.wavEncoding
            )
            let writeBaseCount = completedWriteCount
            do {
                let stats = try AudioExportRenderer.renderMixdown(
                    snapshot: snapshot,
                    to: writer,
                    progressHandler: { fraction, stage, message in
                        let overall = (Double(writeBaseCount) + fraction) / Double(max(totalWriteCount, 1))
                        progressHandler?(overall, stage, message)
                    }
                )
                combinedStats.merge(stats)
                validations.append(try AudioExportOutputValidator.validate(
                    url: stagedURL,
                    format: .wav,
                    expectedFrameCount: snapshot.frameCount,
                    expectedSampleRate: snapshot.sampleRate,
                    expectedChannelCount: snapshot.channelCount
                ))
                outputURLs.append(mixURL)
                completedWriteCount += 1
            } catch {
                writer.cancel()
                transaction.cancel()
                throw error
            }
        }

        for track in snapshot.tracks {
            try Task.checkCancellation()
            let stemURL = uniqueURL(
                in: folderURL,
                baseName: "\(snapshot.request.projectName)-\(track.name)-stem",
                extension: "wav",
                usedNames: &usedNames
            )
            let stagedURL = transaction.stageURL(for: stemURL)
            let writer = try AudioExportStreamingWAVWriter(
                url: stagedURL,
                sampleRate: snapshot.sampleRate,
                channelCount: snapshot.channelCount,
                encoding: snapshot.request.wavEncoding
            )
            let writeBaseCount = completedWriteCount
            do {
                let stats = try AudioExportRenderer.renderTrack(
                    track,
                    snapshot: snapshot,
                    to: writer,
                    progressHandler: { fraction, stage, message in
                        let overall = (Double(writeBaseCount) + fraction) / Double(max(totalWriteCount, 1))
                        progressHandler?(overall, stage, message)
                    }
                )
                combinedStats.merge(stats)
                validations.append(try AudioExportOutputValidator.validate(
                    url: stagedURL,
                    format: .wav,
                    expectedFrameCount: snapshot.frameCount,
                    expectedSampleRate: snapshot.sampleRate,
                    expectedChannelCount: snapshot.channelCount
                ))
                outputURLs.append(stemURL)
                completedWriteCount += 1
            } catch {
                writer.cancel()
                transaction.cancel()
                throw error
            }
        }

        try Task.checkCancellation()
        try AudioExportPreflight.validateSourceIdentities(snapshot: snapshot)
        progressHandler?(0.99, .committing, "Saving stem set")
        do {
            let committedURLs = try transaction.commit()
            progressHandler?(1, .finishing, "Finished stems")
            return AudioExportCompletedWrite(
                outputURLs: committedURLs,
                renderStats: combinedStats,
                validations: validations,
                reportURL: nil
            )
        } catch {
            transaction.cancel()
            throw error
        }
    }

    static func normalizedURL(_ destinationURL: URL, format: AudioExportFormat) -> URL {
        destinationURL.pathExtension.lowercased() == format.fileExtension ?
            destinationURL :
            destinationURL.deletingPathExtension().appendingPathExtension(format.fileExtension)
    }

    static func uniqueURL(
        in folderURL: URL,
        baseName: String,
        extension pathExtension: String,
        usedNames: inout Set<String>
    ) -> URL {
        let sanitizedBaseName = sanitizedFilenameComponent(baseName)
        var suffix = 0
        while true {
            let name = suffix == 0 ? sanitizedBaseName : "\(sanitizedBaseName)-\(suffix + 1)"
            let filename = "\(name).\(pathExtension)"
            let uniquenessKey = filename.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            if !usedNames.contains(uniquenessKey) {
                let url = folderURL.appendingPathComponent(filename)
                if !FileManager.default.fileExists(atPath: url.path) {
                    usedNames.insert(uniquenessKey)
                    return url
                }
            }
            suffix += 1
        }
    }

    static func exportSynchronouslyForTesting(snapshot: AudioExportSnapshot) throws -> [URL] {
        try exportSynchronouslyForTestingResult(snapshot: snapshot).outputURLs
    }

    static func exportSynchronouslyForTestingResult(
        snapshot: AudioExportSnapshot,
        writesReport: Bool = false,
        progressHandler: AudioExportRenderer.ProgressHandler? = nil
    ) throws -> AudioExportCompletedWrite {
        let startedAt = Date()
        let completedWrite = try performExport(
            snapshot: snapshot,
            progressHandler: progressHandler
        )
        guard writesReport else {
            return completedWrite
        }
        let reportURL = writeReportIfPossible(
            snapshot: snapshot,
            outputURLs: completedWrite.outputURLs,
            startedAt: startedAt,
            renderStats: completedWrite.renderStats,
            validations: completedWrite.validations
        )
        return AudioExportCompletedWrite(
            outputURLs: completedWrite.outputURLs,
            renderStats: completedWrite.renderStats,
            validations: completedWrite.validations,
            reportURL: reportURL
        )
    }

    private static func writeReportIfPossible(
        snapshot: AudioExportSnapshot,
        outputURLs: [URL],
        startedAt: Date,
        renderStats: AudioExportRenderStats,
        validations: [AudioExportOutputValidator.Validation]
    ) -> URL? {
        guard let reportURL = reportURL(for: snapshot.request, outputURLs: outputURLs) else {
            return nil
        }

        let finishedAt = Date()
        let bundle = Bundle.main
        let report = AudioExportReport(
            jobID: snapshot.request.id.uuidString,
            applicationVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "development",
            applicationBuild: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "development",
            projectName: snapshot.request.projectName,
            scope: snapshot.request.scope.displayName,
            format: snapshot.request.format.displayName,
            wavEncoding: snapshot.request.wavEncoding.displayName,
            compressedBitRate: snapshot.request.compressedQuality.rawValue,
            stemTrackInclusion: snapshot.request.stemOptions.trackInclusion.rawValue,
            stemGainPosition: snapshot.request.stemOptions.gainPosition.rawValue,
            createdAt: snapshot.request.createdAt,
            startedAt: startedAt,
            finishedAt: finishedAt,
            elapsedSeconds: finishedAt.timeIntervalSince(startedAt),
            sampleRate: snapshot.sampleRate,
            channelCount: snapshot.channelCount,
            exportFrameRangeLowerBound: snapshot.exportFrameRange.lowerBound,
            exportFrameRangeUpperBound: snapshot.exportFrameRange.upperBound,
            trackCount: snapshot.tracks.count,
            sourceFingerprints: snapshot.tracks.compactMap(\.sourceFingerprint),
            renderedFrameCount: renderStats.renderedFrameCount,
            peakMagnitude: renderStats.peakMagnitude,
            clippedSampleCount: renderStats.clippedSampleCount,
            validations: validations,
            outputPaths: outputURLs.map(\.path)
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: reportURL, options: .atomic)
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .info,
                name: "export-report-written",
                message: "Export wrote a structured report.",
                fields: [
                    "jobID": snapshot.request.id.uuidString,
                    "path": reportURL.path,
                ]
            )
            return reportURL
        } catch {
            SoundtimeDiagnostics.shared.record(
                category: .system,
                severity: .warning,
                name: "export-report-write-failed",
                message: "Export completed, but the structured report could not be written.",
                fields: [
                    "jobID": snapshot.request.id.uuidString,
                    "error": error.localizedDescription,
                ]
            )
            return nil
        }
    }

    private static func reportURL(for request: AudioExportRequest, outputURLs: [URL]) -> URL? {
        guard let firstOutputURL = outputURLs.first else {
            return nil
        }

        if request.scope.exportsStems {
            return firstOutputURL
                .deletingLastPathComponent()
                .appendingPathComponent("soundtime-export-\(request.id.uuidString).json")
        }

        return firstOutputURL
            .deletingPathExtension()
            .appendingPathExtension("soundtime-export.json")
    }

    private static func sanitizedFilenameComponent(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let components = value.components(separatedBy: invalidCharacters)
        let whitespaceCollapsed = components.joined(separator: "-")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: ".")
            ))
        let sanitized = String(whitespaceCollapsed.prefix(120))
        return sanitized.isEmpty ? "Soundtime" : sanitized
    }
}

private struct AudioExportReport: Codable {
    let jobID: String
    let applicationVersion: String
    let applicationBuild: String
    let projectName: String
    let scope: String
    let format: String
    let wavEncoding: String
    let compressedBitRate: Int
    let stemTrackInclusion: String
    let stemGainPosition: String
    let createdAt: Date
    let startedAt: Date
    let finishedAt: Date
    let elapsedSeconds: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let exportFrameRangeLowerBound: Int
    let exportFrameRangeUpperBound: Int
    let trackCount: Int
    let sourceFingerprints: [AudioExportSourceFingerprint]
    let renderedFrameCount: Int
    let peakMagnitude: Float
    let clippedSampleCount: Int
    let validations: [AudioExportOutputValidator.Validation]
    let outputPaths: [String]
}
