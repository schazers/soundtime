import Darwin
import Foundation

enum AudioExportSmokeHarness {
    static func runFromCommandLine(arguments: [String]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundtimeAudioExportSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let sourceAURL = root.appendingPathComponent("export-source-a.wav")
        let sourceBURL = root.appendingPathComponent("export-source-b.wav")
        let sampleRate = 44_100.0
        let frameCount = 22_050
        try WAVFileWriter.write(
            makeToneBuffer(url: sourceAURL, sampleRate: sampleRate, frameCount: frameCount, frequency: 220),
            to: sourceAURL
        )
        try WAVFileWriter.write(
            makeToneBuffer(url: sourceBURL, sampleRate: sampleRate, frameCount: frameCount, frequency: 440),
            to: sourceBURL
        )

        let fileInfoA = try WAVAudioDecoder.inspect(url: sourceAURL)
        let fileInfoB = try WAVAudioDecoder.inspect(url: sourceBURL)
        let trackA = AudioExportTrackSnapshot(
            id: UUID(),
            name: "voice_main",
            volume: 1,
            source: .file(sourceAURL, fileInfoA)
        )
        let trackB = AudioExportTrackSnapshot(
            id: UUID(),
            name: "music-bed/unsafe:name",
            volume: 0.5,
            source: .file(sourceBURL, fileInfoB)
        )

        try verifyFullMixdown(root: root, sampleRate: sampleRate, frameCount: frameCount, tracks: [trackA, trackB])
        try verifySelectedRange(root: root, sampleRate: sampleRate, frameCount: frameCount, tracks: [trackA])
        try verifyStemFolder(root: root, sampleRate: sampleRate, frameCount: frameCount, tracks: [trackA, trackB])
        try verifyMixBusDoesNotClampDuringSumming(root: root, sampleRate: sampleRate)
        try verifyCompressedMixdown(root: root, sampleRate: sampleRate, frameCount: frameCount, tracks: [trackA])
        try verifyLongFileBlockRender(root: root, sampleRate: sampleRate)
        try verifyExportReport(root: root, sampleRate: sampleRate, frameCount: frameCount, tracks: [trackA, trackB])
        try verifyAssetLeases(root: root, url: sourceAURL)

        print("Soundtime audio export smoke passed")
    }

    private static func verifyFullMixdown(
        root: URL,
        sampleRate: Double,
        frameCount: Int,
        tracks: [AudioExportTrackSnapshot]
    ) throws {
        let outputURL = root.appendingPathComponent("mixdown.wav")
        let request = AudioExportRequest(
            projectName: "Export Smoke",
            scope: .fullMixdown,
            format: .wav,
            destinationURL: outputURL
        )
        let snapshot = AudioExportSnapshot(
            id: request.id,
            createdAt: request.createdAt,
            request: request,
            tracks: tracks,
            sampleRate: sampleRate,
            channelCount: 2,
            fullDurationFrameCount: frameCount,
            exportFrameRange: 0..<frameCount,
            leasedURLs: tracks.compactMap(\.sourceURL)
        )

        let outputURLs = try AudioExportService.exportSynchronouslyForTesting(snapshot: snapshot)
        try require(outputURLs.count == 1, "mixdown did not produce exactly one file")
        let decoded = try WAVAudioDecoder.decode(url: outputURLs[0])
        try require(decoded.frameCount == frameCount, "mixdown frame count mismatch: \(decoded.frameCount)")
        try require(decoded.channelCount == 2, "mixdown channel count mismatch: \(decoded.channelCount)")
        try require(maxAbsSample(in: decoded) > 0.01, "mixdown rendered silence")
    }

    private static func verifySelectedRange(
        root: URL,
        sampleRate: Double,
        frameCount: Int,
        tracks: [AudioExportTrackSnapshot]
    ) throws {
        let selection = TimelineSelection(startProgress: 0.25, endProgress: 0.5)
        let rangeStart = Int((selection.startProgress * Double(frameCount)).rounded(.down))
        let rangeEnd = Int((selection.endProgress * Double(frameCount)).rounded(.up))
        let request = AudioExportRequest(
            projectName: "Export Smoke",
            scope: .timeRange(selection),
            format: .wav,
            destinationURL: root.appendingPathComponent("selection.wav")
        )
        let snapshot = AudioExportSnapshot(
            id: request.id,
            createdAt: request.createdAt,
            request: request,
            tracks: tracks,
            sampleRate: sampleRate,
            channelCount: 2,
            fullDurationFrameCount: frameCount,
            exportFrameRange: rangeStart..<rangeEnd,
            leasedURLs: tracks.compactMap(\.sourceURL)
        )

        let outputURLs = try AudioExportService.exportSynchronouslyForTesting(snapshot: snapshot)
        try require(outputURLs.count == 1, "selected range did not produce exactly one file")
        let decoded = try WAVAudioDecoder.decode(url: outputURLs[0])
        try require(decoded.frameCount == rangeEnd - rangeStart, "selected range frame count mismatch: \(decoded.frameCount)")
        try require(maxAbsSample(in: decoded) > 0.01, "selected range rendered silence")
    }

    private static func verifyStemFolder(
        root: URL,
        sampleRate: Double,
        frameCount: Int,
        tracks: [AudioExportTrackSnapshot]
    ) throws {
        let folderURL = root.appendingPathComponent("stems", isDirectory: true)
        let request = AudioExportRequest(
            projectName: "Export Smoke",
            scope: .stems(includeMixdown: true, selection: nil),
            format: .wav,
            destinationURL: folderURL
        )
        let snapshot = AudioExportSnapshot(
            id: request.id,
            createdAt: request.createdAt,
            request: request,
            tracks: tracks,
            sampleRate: sampleRate,
            channelCount: 2,
            fullDurationFrameCount: frameCount,
            exportFrameRange: 0..<frameCount,
            leasedURLs: tracks.compactMap(\.sourceURL)
        )

        let outputURLs = try AudioExportService.exportSynchronouslyForTesting(snapshot: snapshot)
        try require(outputURLs.count == 3, "stems produced \(outputURLs.count) files instead of 3")
        for outputURL in outputURLs {
            try require(outputURL.pathExtension.lowercased() == "wav", "stem output was not WAV: \(outputURL.lastPathComponent)")
            let decoded = try WAVAudioDecoder.decode(url: outputURL)
            try require(decoded.frameCount == frameCount, "stem frame count mismatch for \(outputURL.lastPathComponent)")
            try require(!outputURL.lastPathComponent.contains("/"), "stem filename was not sanitized")
            try require(maxAbsSample(in: decoded) > 0.01, "stem rendered silence: \(outputURL.lastPathComponent)")
        }
    }

    private static func verifyMixBusDoesNotClampDuringSumming(root: URL, sampleRate: Double) throws {
        let frameCount = 4_096
        let outputURL = root.appendingPathComponent("mix-bus.wav")
        let trackA = AudioExportTrackSnapshot(
            id: UUID(),
            name: "positive-a",
            volume: 1,
            source: .decoded(makeConstantBuffer(
                url: root.appendingPathComponent("positive-a.wav"),
                sampleRate: sampleRate,
                frameCount: frameCount,
                value: 0.9
            ))
        )
        let trackB = AudioExportTrackSnapshot(
            id: UUID(),
            name: "positive-b",
            volume: 1,
            source: .decoded(makeConstantBuffer(
                url: root.appendingPathComponent("positive-b.wav"),
                sampleRate: sampleRate,
                frameCount: frameCount,
                value: 0.9
            ))
        )
        let trackC = AudioExportTrackSnapshot(
            id: UUID(),
            name: "negative-c",
            volume: 1,
            source: .decoded(makeConstantBuffer(
                url: root.appendingPathComponent("negative-c.wav"),
                sampleRate: sampleRate,
                frameCount: frameCount,
                value: -0.9
            ))
        )
        let request = AudioExportRequest(
            projectName: "Export Smoke",
            scope: .fullMixdown,
            format: .wav,
            destinationURL: outputURL
        )
        let snapshot = AudioExportSnapshot(
            id: request.id,
            createdAt: request.createdAt,
            request: request,
            tracks: [trackA, trackB, trackC],
            sampleRate: sampleRate,
            channelCount: 2,
            fullDurationFrameCount: frameCount,
            exportFrameRange: 0..<frameCount,
            leasedURLs: []
        )

        let outputURLs = try AudioExportService.exportSynchronouslyForTesting(snapshot: snapshot)
        let decoded = try WAVAudioDecoder.decode(url: outputURLs[0], frameRange: 0..<32)
        let sample = decoded.samplesByChannel.first?.first ?? 0
        try require(abs(sample - 0.9) < 0.01, "mix bus clamped while summing; expected 0.9, got \(sample)")
    }

    private static func verifyCompressedMixdown(
        root: URL,
        sampleRate: Double,
        frameCount: Int,
        tracks: [AudioExportTrackSnapshot]
    ) throws {
        let request = AudioExportRequest(
            projectName: "Export Smoke",
            scope: .fullMixdown,
            format: .m4a,
            destinationURL: root.appendingPathComponent("mixdown.m4a")
        )
        let snapshot = AudioExportSnapshot(
            id: request.id,
            createdAt: request.createdAt,
            request: request,
            tracks: tracks,
            sampleRate: sampleRate,
            channelCount: 2,
            fullDurationFrameCount: frameCount,
            exportFrameRange: 0..<frameCount,
            leasedURLs: tracks.compactMap(\.sourceURL)
        )

        let outputURLs = try AudioExportService.exportSynchronouslyForTesting(snapshot: snapshot)
        try require(outputURLs.count == 1, "compressed mixdown did not produce exactly one file")
        try require(outputURLs[0].pathExtension.lowercased() == "m4a", "compressed mixdown did not use m4a extension")
        let compressedFileSize = try fileSize(outputURLs[0])
        try require(compressedFileSize > 1_024, "compressed mixdown output was too small")
    }

    private static func verifyLongFileBlockRender(root: URL, sampleRate: Double) throws {
        let frameCount = Int(sampleRate * 12)
        let sourceURL = root.appendingPathComponent("longish-source.wav")
        try WAVFileWriter.write(
            makeToneBuffer(url: sourceURL, sampleRate: sampleRate, frameCount: frameCount, frequency: 110),
            to: sourceURL
        )
        let fileInfo = try WAVAudioDecoder.inspect(url: sourceURL)
        let track = AudioExportTrackSnapshot(
            id: UUID(),
            name: "longish-source",
            volume: 1,
            source: .file(sourceURL, fileInfo)
        )
        let request = AudioExportRequest(
            projectName: "Export Smoke Long",
            scope: .fullMixdown,
            format: .wav,
            destinationURL: root.appendingPathComponent("longish-output.wav")
        )
        let snapshot = AudioExportSnapshot(
            id: request.id,
            createdAt: request.createdAt,
            request: request,
            tracks: [track],
            sampleRate: sampleRate,
            channelCount: 2,
            fullDurationFrameCount: frameCount,
            exportFrameRange: 0..<frameCount,
            leasedURLs: [sourceURL]
        )

        let startedAt = Date()
        let outputURLs = try AudioExportService.exportSynchronouslyForTesting(snapshot: snapshot)
        let elapsed = Date().timeIntervalSince(startedAt)
        try require(outputURLs.count == 1, "long-file export did not produce exactly one file")
        let decodedInfo = try WAVAudioDecoder.inspect(url: outputURLs[0])
        try require(decodedInfo.frameCount == frameCount, "long-file export frame count mismatch")
        try require(elapsed < 8, "long-file export was unexpectedly slow: \(elapsed)s")
    }

    private static func verifyExportReport(
        root: URL,
        sampleRate: Double,
        frameCount: Int,
        tracks: [AudioExportTrackSnapshot]
    ) throws {
        let request = AudioExportRequest(
            projectName: "Export Smoke Report",
            scope: .fullMixdown,
            format: .wav,
            destinationURL: root.appendingPathComponent("reported-mixdown.wav")
        )
        let snapshot = AudioExportSnapshot(
            id: request.id,
            createdAt: request.createdAt,
            request: request,
            tracks: tracks,
            sampleRate: sampleRate,
            channelCount: 2,
            fullDurationFrameCount: frameCount,
            exportFrameRange: 0..<frameCount,
            leasedURLs: tracks.compactMap(\.sourceURL)
        )

        let completed = try AudioExportService.exportSynchronouslyForTestingResult(
            snapshot: snapshot,
            writesReport: true
        )
        guard let reportURL = completed.reportURL else {
            throw SmokeFailure("export report URL was not returned")
        }
        try require(FileManager.default.fileExists(atPath: reportURL.path), "export report was not written")
        let reportText = try String(contentsOf: reportURL)
        try require(reportText.contains("\"renderedFrameCount\""), "export report omitted rendered frame count")
        try require(completed.renderStats.renderedFrameCount == frameCount, "export stats frame count mismatch")
    }

    private static func verifyAssetLeases(root: URL, url: URL) throws {
        let jobID = UUID()
        let lease = AudioExportLeaseManager.shared.acquire(urls: [url], jobID: jobID)
        try require(AudioExportLeaseManager.shared.isLeased(url), "leased source was not retained")
        AudioExportLeaseManager.shared.release(lease)
        try require(!AudioExportLeaseManager.shared.isLeased(url), "leased source was not released")

        let deferredDeleteURL = root.appendingPathComponent("leased-delete.wav")
        _ = FileManager.default.createFile(atPath: deferredDeleteURL.path, contents: Data([1, 2, 3]))
        let deferredLease = AudioExportLeaseManager.shared.acquire(urls: [deferredDeleteURL], jobID: UUID())
        try require(AudioExportLeaseManager.shared.deferDeletionIfLeased(deferredDeleteURL), "leased source deletion was not deferred")
        try require(FileManager.default.fileExists(atPath: deferredDeleteURL.path), "deferred source was deleted while leased")
        AudioExportLeaseManager.shared.release(deferredLease)
        try require(!FileManager.default.fileExists(atPath: deferredDeleteURL.path), "deferred source was not deleted after lease release")
    }

    private static func makeToneBuffer(
        url: URL,
        sampleRate: Double,
        frameCount: Int,
        frequency: Double
    ) -> DecodedAudioBuffer {
        let samples = (0..<frameCount).map { frameIndex -> Float in
            let phase = Double(frameIndex) / sampleRate * frequency * 2 * Double.pi
            return Float(sin(phase) * 0.35)
        }
        return DecodedAudioBuffer(
            url: url,
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [samples, samples]
        )
    }

    private static func makeConstantBuffer(
        url: URL,
        sampleRate: Double,
        frameCount: Int,
        value: Float
    ) -> DecodedAudioBuffer {
        let samples = [Float](repeating: value, count: frameCount)
        return DecodedAudioBuffer(
            url: url,
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [samples, samples]
        )
    }

    private static func maxAbsSample(in buffer: DecodedAudioBuffer) -> Float {
        buffer.samplesByChannel
            .flatMap { $0 }
            .map { abs($0) }
            .max() ?? 0
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw SmokeFailure(message)
        }
    }
}

private struct SmokeFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
