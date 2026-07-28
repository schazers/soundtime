import Foundation

final class AudioExportService: @unchecked Sendable {
    typealias ProgressCallback = @MainActor @Sendable (AudioExportProgress) -> Void
    typealias CompletionCallback = @MainActor @Sendable (UUID, Result<AudioExportResult, Error>) -> Void

    enum ExportError: LocalizedError {
        case noAudioToExport
        case unsupportedStemFormat

        var errorDescription: String? {
            switch self {
            case .noAudioToExport:
                return "There is no audio to export."
            case .unsupportedStemFormat:
                return "Stem export currently writes WAV files."
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
        return activeTask != nil
    }

    func start(snapshot: AudioExportSnapshot) {
        cancel()
        let request = snapshot.request
        let lease = AudioExportLeaseManager.shared.acquire(urls: snapshot.leasedURLs, jobID: request.id)
        let service = self
        emit(.initial(request: request))

        let task = Task.detached(priority: .userInitiated) { [snapshot, lease, service] in
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
                    renderStats: completedWrite.renderStats
                )
                let result = AudioExportResult(
                    request: snapshot.request,
                    outputURLs: completedWrite.outputURLs,
                    elapsedSeconds: Date().timeIntervalSince(startedAt),
                    renderedFrameCount: completedWrite.renderStats.renderedFrameCount,
                    renderStats: completedWrite.renderStats,
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
                service.complete(jobID: snapshot.request.id, result: .success(result))
            } catch is CancellationError {
                service.emit(AudioExportProgress(
                    jobID: snapshot.request.id,
                    request: snapshot.request,
                    stage: .canceled,
                    fractionCompleted: 0,
                    message: "Export canceled",
                    outputURLs: []
                ))
                service.complete(jobID: snapshot.request.id, result: .failure(CancellationError()))
            } catch {
                service.emit(AudioExportProgress(
                    jobID: snapshot.request.id,
                    request: snapshot.request,
                    stage: .failed,
                    fractionCompleted: 0,
                    message: error.localizedDescription,
                    outputURLs: []
                ))
                service.complete(jobID: snapshot.request.id, result: .failure(error))
            }

            AudioExportLeaseManager.shared.release(lease)
            service.clearActiveTask(id: snapshot.request.id)
        }

        lock.lock()
        activeTask = task
        activeTaskID = request.id
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = activeTask
        activeTask = nil
        activeTaskID = nil
        lock.unlock()
        task?.cancel()
    }

    private func clearActiveTask(id: UUID) {
        lock.lock()
        if activeTaskID == id {
            activeTask = nil
            activeTaskID = nil
        }
        lock.unlock()
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

        if snapshot.request.scope.exportsStems {
            guard snapshot.request.format == .wav else {
                throw ExportError.unsupportedStemFormat
            }
            return try writeStems(snapshot: snapshot, progressHandler: progressHandler)
        }

        switch snapshot.request.format {
        case .wav:
            let outputURL = normalizedURL(snapshot.request.destinationURL, format: .wav)
            let writer = try AudioExportStreamingWAVWriter(
                url: outputURL,
                sampleRate: snapshot.sampleRate,
                channelCount: snapshot.channelCount
            )
            do {
                let stats = try AudioExportRenderer.renderMixdown(
                    snapshot: snapshot,
                    to: writer,
                    progressHandler: progressHandler
                )
                return AudioExportCompletedWrite(outputURLs: [outputURL], renderStats: stats, reportURL: nil)
            } catch {
                writer.cancel()
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
        let outputURL = normalizedURL(snapshot.request.destinationURL, format: snapshot.request.format)
        let writer = try AudioExportStreamingCompressedWriter(
            url: outputURL,
            format: snapshot.request.format,
            sampleRate: snapshot.sampleRate,
            channelCount: snapshot.channelCount
        )

        do {
            let stats = try AudioExportRenderer.renderMixdown(
                snapshot: snapshot,
                to: writer
            ) { fraction, _, message in
                progressHandler?(fraction * 0.96, .encoding, "\(message) and encoding \(snapshot.request.format.displayName)")
            }
            try Task.checkCancellation()
            progressHandler?(1, .finishing, "Finished encoding")
            return AudioExportCompletedWrite(outputURLs: [outputURL], renderStats: stats, reportURL: nil)
        } catch {
            writer.cancel()
            throw error
        }
    }

    private static func writeStems(
        snapshot: AudioExportSnapshot,
        progressHandler: AudioExportRenderer.ProgressHandler?
    ) throws -> AudioExportCompletedWrite {
        let folderURL = snapshot.request.destinationURL
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        var usedNames = Set<String>()
        var outputURLs: [URL] = []
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
            let writer = try AudioExportStreamingWAVWriter(
                url: mixURL,
                sampleRate: snapshot.sampleRate,
                channelCount: snapshot.channelCount
            )
            let writeBaseCount = completedWriteCount
            do {
                let stats = try AudioExportRenderer.renderMixdown(snapshot: snapshot, to: writer) { fraction, stage, message in
                    let overall = (Double(writeBaseCount) + fraction) / Double(max(totalWriteCount, 1))
                    progressHandler?(overall, stage, message)
                }
                combinedStats.merge(stats)
                outputURLs.append(mixURL)
                completedWriteCount += 1
            } catch {
                writer.cancel()
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
            let writer = try AudioExportStreamingWAVWriter(
                url: stemURL,
                sampleRate: snapshot.sampleRate,
                channelCount: snapshot.channelCount
            )
            let writeBaseCount = completedWriteCount
            do {
                let stats = try AudioExportRenderer.renderTrack(track, snapshot: snapshot, to: writer) { fraction, stage, message in
                    let overall = (Double(writeBaseCount) + fraction) / Double(max(totalWriteCount, 1))
                    progressHandler?(overall, stage, message)
                }
                combinedStats.merge(stats)
                outputURLs.append(stemURL)
                completedWriteCount += 1
            } catch {
                writer.cancel()
                throw error
            }
        }

        progressHandler?(1, .finishing, "Finished stems")
        return AudioExportCompletedWrite(outputURLs: outputURLs, renderStats: combinedStats, reportURL: nil)
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
            if !usedNames.contains(filename) {
                let url = folderURL.appendingPathComponent(filename)
                if !FileManager.default.fileExists(atPath: url.path) {
                    usedNames.insert(filename)
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
        writesReport: Bool = false
    ) throws -> AudioExportCompletedWrite {
        let startedAt = Date()
        let completedWrite = try performExport(snapshot: snapshot, progressHandler: nil)
        guard writesReport else {
            return completedWrite
        }
        let reportURL = writeReportIfPossible(
            snapshot: snapshot,
            outputURLs: completedWrite.outputURLs,
            startedAt: startedAt,
            renderStats: completedWrite.renderStats
        )
        return AudioExportCompletedWrite(
            outputURLs: completedWrite.outputURLs,
            renderStats: completedWrite.renderStats,
            reportURL: reportURL
        )
    }

    private static func writeReportIfPossible(
        snapshot: AudioExportSnapshot,
        outputURLs: [URL],
        startedAt: Date,
        renderStats: AudioExportRenderStats
    ) -> URL? {
        guard let reportURL = reportURL(for: snapshot.request, outputURLs: outputURLs) else {
            return nil
        }

        let finishedAt = Date()
        let report = AudioExportReport(
            jobID: snapshot.request.id.uuidString,
            projectName: snapshot.request.projectName,
            scope: snapshot.request.scope.displayName,
            format: snapshot.request.format.displayName,
            createdAt: snapshot.request.createdAt,
            startedAt: startedAt,
            finishedAt: finishedAt,
            elapsedSeconds: finishedAt.timeIntervalSince(startedAt),
            sampleRate: snapshot.sampleRate,
            channelCount: snapshot.channelCount,
            exportFrameRangeLowerBound: snapshot.exportFrameRange.lowerBound,
            exportFrameRangeUpperBound: snapshot.exportFrameRange.upperBound,
            trackCount: snapshot.tracks.count,
            renderedFrameCount: renderStats.renderedFrameCount,
            peakMagnitude: renderStats.peakMagnitude,
            clippedSampleCount: renderStats.clippedSampleCount,
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
        let sanitized = components.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Soundtime" : sanitized
    }
}

private struct AudioExportReport: Codable {
    let jobID: String
    let projectName: String
    let scope: String
    let format: String
    let createdAt: Date
    let startedAt: Date
    let finishedAt: Date
    let elapsedSeconds: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let exportFrameRangeLowerBound: Int
    let exportFrameRangeUpperBound: Int
    let trackCount: Int
    let renderedFrameCount: Int
    let peakMagnitude: Float
    let clippedSampleCount: Int
    let outputPaths: [String]
}
