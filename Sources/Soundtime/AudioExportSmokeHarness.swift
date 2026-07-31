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
        try verifyExportDoesNotWriteSidecar(
            root: root,
            sampleRate: sampleRate,
            frameCount: frameCount,
            tracks: [trackA, trackB]
        )
        try verifyAssetLeases(root: root, url: sourceAURL)
        try verifyWAVEncodingMatrix(root: root, sampleRate: sampleRate, track: trackA)
        try verifyAvailableCodecMatrix(root: root, sampleRate: sampleRate, track: trackA)
        try verifyCompressedQualityMatrix(root: root, sampleRate: sampleRate, track: trackA)
        try verifyScopeSemantics(root: root, sampleRate: sampleRate)
        try verifyAllMutedMixdownProducesSilence(root: root, sampleRate: sampleRate)
        try verifyResampledExport(root: root)
        try verifyEditedTimelineExport(root: root, sampleRate: sampleRate)
        try verifySegmentSourceRendering(root: root)
        try verifyTransactionalSafety(root: root)
        try verifySourceMutationFailsSafely(root: root, sampleRate: sampleRate)
        try verifySourceDestinationCollisionFailsSafely(
            sourceURL: sourceBURL,
            fileInfo: fileInfoB,
            sampleRate: sampleRate
        )
        try verifyCaseInsensitiveStemNames(root: root, sampleRate: sampleRate)
        try verifyCanonicalAssetLeaseAliases(root: root)
        try verifyStalePartialRecovery(root: root)
        try verifyCancellationPreservesPublishedOutput(root: root, sampleRate: sampleRate)

        print("Soundtime audio export smoke passed")
    }

    private static func verifySegmentSourceRendering(root: URL) throws {
        let sampleRate = 8_000.0
        let sourceURL = root.appendingPathComponent("segment-source.wav")
        let samples = (0..<16).map { Float($0 + 1) / 32 }
        let buffer = DecodedAudioBuffer(
            url: sourceURL,
            sampleRate: sampleRate,
            channelCount: 2,
            frameCount: samples.count,
            samplesByChannel: [samples, samples]
        )
        try WAVFileWriter.write(buffer, to: sourceURL)
        let fileInfo = try WAVAudioDecoder.inspect(url: sourceURL)
        let segments = [
            AudioEditTimeline.PlaybackSegment(
                outputStartFrame: 0,
                sourceStartFrame: 2,
                frameCount: 3,
                sourceFrameScale: 1,
                gainStart: 1,
                gainEnd: 1,
                startsNewClip: true
            ),
            AudioEditTimeline.PlaybackSegment(
                outputStartFrame: 5,
                sourceStartFrame: 8,
                frameCount: 2,
                sourceFrameScale: 1,
                gainStart: 1,
                gainEnd: 1,
                startsNewClip: true
            ),
        ]
        let expected: [Float] = [
            samples[2], samples[3], samples[4], 0, 0, samples[8], samples[9], 0,
        ]

        let sources: [(String, AudioExportTrackSource)] = [
            ("decoded", .decodedSegments(buffer, segments)),
            ("file", .fileSegments(sourceURL, fileInfo, segments)),
        ]
        for (name, source) in sources {
            let outputURL = root.appendingPathComponent("segment-source-\(name).wav")
            let request = AudioExportRequest(
                projectName: "Segment Source \(name)",
                scope: .fullMixdown,
                format: .wav,
                destinationURL: outputURL,
                wavEncoding: .float32
            )
            let snapshot = makeSnapshot(
                request: request,
                tracks: [
                    AudioExportTrackSnapshot(
                        id: UUID(),
                        name: name,
                        volume: 1,
                        source: source
                    ),
                ],
                sampleRate: sampleRate,
                frameCount: expected.count
            )
            let writer = try AudioExportStreamingWAVWriter(
                url: outputURL,
                sampleRate: sampleRate,
                channelCount: 2,
                encoding: .float32
            )
            _ = try AudioExportRenderer.renderMixdown(
                snapshot: snapshot,
                to: writer
            )
            let rendered = try WAVAudioDecoder.decode(url: outputURL)
            try require(
                rendered.frameCount == expected.count,
                "\(name) segment source rendered the wrong frame count"
            )
            for channel in rendered.samplesByChannel {
                for (actual, expectedSample) in zip(channel, expected) {
                    try require(
                        abs(actual - expectedSample) < 0.000_1,
                        "\(name) segment source rendered the wrong sample placement"
                    )
                }
            }
        }
    }

    private static func verifyWAVEncodingMatrix(
        root: URL,
        sampleRate: Double,
        track: AudioExportTrackSnapshot
    ) throws {
        let frameCount = 4_096
        for encoding in AudioExportWAVEncoding.allCases {
            let request = AudioExportRequest(
                projectName: "WAV Encoding \(encoding.rawValue)",
                scope: .timeRange(TimelineSelection(
                    startProgress: 0,
                    endProgress: Double(frameCount) / 22_050
                )),
                format: .wav,
                destinationURL: root.appendingPathComponent("encoding-\(encoding.rawValue).wav"),
                wavEncoding: encoding
            )
            let snapshot = AudioExportSnapshot(
                id: request.id,
                createdAt: request.createdAt,
                request: request,
                tracks: [track],
                sampleRate: sampleRate,
                channelCount: 2,
                fullDurationFrameCount: 22_050,
                exportFrameRange: 0..<frameCount,
                leasedURLs: track.sourceURL.map { [$0] } ?? []
            )
            let output = try AudioExportService.exportSynchronouslyForTesting(snapshot: snapshot)
            let info = try WAVAudioDecoder.inspect(url: try requireFirst(output))
            try require(
                info.bitsPerSample == encoding.bytesPerSample * 8,
                "\(encoding.displayName) wrote \(info.bitsPerSample)-bit audio"
            )
            try require(info.frameCount == frameCount, "\(encoding.displayName) frame count mismatch")
        }

        let overflowTrack = AudioExportTrackSnapshot(
            id: UUID(),
            name: "float-overflow",
            volume: 1,
            source: .decoded(makeConstantBuffer(
                url: root.appendingPathComponent("float-overflow-source.wav"),
                sampleRate: sampleRate,
                frameCount: frameCount,
                value: 1.25
            ))
        )
        let request = AudioExportRequest(
            projectName: "Float Overflow",
            scope: .fullMixdown,
            format: .wav,
            destinationURL: root.appendingPathComponent("float-overflow.wav"),
            wavEncoding: .float32
        )
        let snapshot = makeSnapshot(
            request: request,
            tracks: [overflowTrack],
            sampleRate: sampleRate,
            frameCount: frameCount
        )
        let output = try AudioExportService.exportSynchronouslyForTesting(snapshot: snapshot)
        let firstSample = try firstFloat32WAVSample(at: try requireFirst(output))
        try require(firstSample > 1.2, "32-bit float export clipped the mix bus")
    }

    private static func verifyAvailableCodecMatrix(
        root: URL,
        sampleRate: Double,
        track: AudioExportTrackSnapshot
    ) throws {
        let formats = AudioExportFormat.allCases.filter(\.isCompressed)
        var testedFormatCount = 0
        for format in formats where format.isSystemEncoderAvailable {
            testedFormatCount += 1
            let request = AudioExportRequest(
                projectName: "Codec \(format.rawValue)",
                scope: .fullMixdown,
                format: format,
                destinationURL: root.appendingPathComponent("codec-\(format.rawValue).\(format.fileExtension)")
            )
            let snapshot = makeSnapshot(
                request: request,
                tracks: [track],
                sampleRate: sampleRate,
                frameCount: 8_192
            )
            let completed = try AudioExportService.exportSynchronouslyForTestingResult(
                snapshot: snapshot
            )
            try require(completed.outputURLs.count == 1, "\(format.displayName) produced no output")
            try require(completed.validations.count == 1, "\(format.displayName) was not validated")
        }
        try require(testedFormatCount > 0, "no compressed system encoder was tested")
    }

    private static func verifyCompressedQualityMatrix(
        root: URL,
        sampleRate: Double,
        track: AudioExportTrackSnapshot
    ) throws {
        guard let format = AudioExportFormat.allCases.first(where: {
            $0.isCompressed && $0.isSystemEncoderAvailable
        }) else {
            throw SmokeFailure("no compressed system encoder was available for quality testing")
        }

        for quality in AudioExportCompressedQuality.allCases {
            let request = AudioExportRequest(
                projectName: "Quality \(quality.rawValue)",
                scope: .fullMixdown,
                format: format,
                destinationURL: root.appendingPathComponent(
                    "quality-\(quality.rawValue).\(format.fileExtension)"
                ),
                compressedQuality: quality
            )
            let completed = try AudioExportService.exportSynchronouslyForTestingResult(
                snapshot: makeSnapshot(
                    request: request,
                    tracks: [track],
                    sampleRate: sampleRate,
                    frameCount: 8_192
                )
            )
            try require(
                completed.validations.count == 1,
                "\(quality.displayName) compressed output was not validated"
            )
        }
    }

    private static func verifyScopeSemantics(root: URL, sampleRate: Double) throws {
        let frameCount = 2_048
        let audible = AudioExportTrackSnapshot(
            id: UUID(),
            name: "audible",
            volume: 0.5,
            source: .decoded(makeConstantBuffer(
                url: root.appendingPathComponent("audible.wav"),
                sampleRate: sampleRate,
                frameCount: frameCount,
                value: 0.8
            ))
        )
        let muted = AudioExportTrackSnapshot(
            id: UUID(),
            name: "muted",
            volume: 1,
            isMuted: true,
            source: .decoded(makeConstantBuffer(
                url: root.appendingPathComponent("muted.wav"),
                sampleRate: sampleRate,
                frameCount: frameCount,
                value: 0.6
            ))
        )

        let mixRequest = AudioExportRequest(
            projectName: "Scope Mix",
            scope: .fullMixdown,
            format: .wav,
            destinationURL: root.appendingPathComponent("scope-mix.wav"),
            wavEncoding: .float32
        )
        let mixOutput = try AudioExportService.exportSynchronouslyForTesting(
            snapshot: makeSnapshot(
                request: mixRequest,
                tracks: [audible, muted],
                sampleRate: sampleRate,
                frameCount: frameCount
            )
        )
        let mix = try WAVAudioDecoder.decode(url: try requireFirst(mixOutput), frameRange: 0..<16)
        try require(
            abs((mix.samplesByChannel.first?.first ?? 0) - 0.2) < 0.001,
            "mixdown did not honor mute and post-fader gain"
        )

        let selectedRequest = AudioExportRequest(
            projectName: "Selected Muted",
            scope: .trackRange(
                trackID: muted.id,
                selection: TimelineSelection(startProgress: 0, endProgress: 1)
            ),
            format: .wav,
            destinationURL: root.appendingPathComponent("selected-muted.wav"),
            wavEncoding: .float32
        )
        let selectedOutput = try AudioExportService.exportSynchronouslyForTesting(
            snapshot: makeSnapshot(
                request: selectedRequest,
                tracks: [muted],
                sampleRate: sampleRate,
                frameCount: frameCount
            )
        )
        let selected = try WAVAudioDecoder.decode(
            url: try requireFirst(selectedOutput),
            frameRange: 0..<16
        )
        try require(
            abs((selected.samplesByChannel.first?.first ?? 0) - 0.6) < 0.001,
            "explicit selected-track export incorrectly honored track mute"
        )
    }

    private static func verifyAllMutedMixdownProducesSilence(
        root: URL,
        sampleRate: Double
    ) throws {
        let frameCount = 2_048
        let mutedTrack = AudioExportTrackSnapshot(
            id: UUID(),
            name: "muted-only",
            volume: 1,
            isMuted: true,
            source: .decoded(makeConstantBuffer(
                url: root.appendingPathComponent("muted-only-source.wav"),
                sampleRate: sampleRate,
                frameCount: frameCount,
                value: 0.8
            ))
        )
        let request = AudioExportRequest(
            projectName: "All Muted",
            scope: .fullMixdown,
            format: .wav,
            destinationURL: root.appendingPathComponent("all-muted.wav"),
            wavEncoding: .float32
        )
        let output = try AudioExportService.exportSynchronouslyForTesting(
            snapshot: makeSnapshot(
                request: request,
                tracks: [mutedTrack],
                sampleRate: sampleRate,
                frameCount: frameCount
            )
        )
        let decoded = try WAVAudioDecoder.decode(
            url: try requireFirst(output),
            frameRange: 0..<frameCount
        )
        try require(
            maxAbsSample(in: decoded) == 0,
            "all-muted mixdown did not produce silence"
        )
    }

    private static func verifyResampledExport(root: URL) throws {
        let sourceSampleRate = 48_000.0
        let outputSampleRate = 44_100.0
        let sourceFrameCount = 4_800
        let outputFrameCount = 4_410
        let track = AudioExportTrackSnapshot(
            id: UUID(),
            name: "resampled",
            volume: 1,
            source: .decoded(makeToneBuffer(
                url: root.appendingPathComponent("resampled-source.wav"),
                sampleRate: sourceSampleRate,
                frameCount: sourceFrameCount,
                frequency: 1_000
            ))
        )
        let request = AudioExportRequest(
            projectName: "Resampled",
            scope: .fullMixdown,
            format: .wav,
            destinationURL: root.appendingPathComponent("resampled-output.wav")
        )
        let output = try AudioExportService.exportSynchronouslyForTesting(
            snapshot: makeSnapshot(
                request: request,
                tracks: [track],
                sampleRate: outputSampleRate,
                frameCount: outputFrameCount
            )
        )
        let info = try WAVAudioDecoder.inspect(url: try requireFirst(output))
        try require(info.sampleRate == outputSampleRate, "resampled export sample rate mismatch")
        try require(info.frameCount == outputFrameCount, "resampled export duration mismatch")
    }

    private static func verifyEditedTimelineExport(root: URL, sampleRate: Double) throws {
        let sourceFrameCount = 4_096
        let source = makeToneBuffer(
            url: root.appendingPathComponent("edited-source.wav"),
            sampleRate: sampleRate,
            frameCount: sourceFrameCount,
            frequency: 330
        )
        let timeline = AudioEditTimeline(
            sourceBuffer: source,
            playbackSegments: [
                .init(
                    outputStartFrame: 0,
                    sourceStartFrame: 0,
                    frameCount: 1_024,
                    sourceFrameScale: 0,
                    gainStart: 1,
                    gainEnd: 1
                ),
                .init(
                    outputStartFrame: 1_024,
                    sourceStartFrame: 3_072,
                    frameCount: 1_024,
                    sourceFrameScale: 0,
                    gainStart: 1,
                    gainEnd: 0.5,
                    startsNewClip: true
                ),
            ]
        )
        let track = AudioExportTrackSnapshot(
            id: UUID(),
            name: "edited",
            volume: 1,
            source: .timeline(timeline)
        )
        let request = AudioExportRequest(
            projectName: "Edited",
            scope: .fullMixdown,
            format: .wav,
            destinationURL: root.appendingPathComponent("edited-output.wav")
        )
        let output = try AudioExportService.exportSynchronouslyForTesting(
            snapshot: makeSnapshot(
                request: request,
                tracks: [track],
                sampleRate: sampleRate,
                frameCount: 2_048
            )
        )
        let decoded = try WAVAudioDecoder.decode(url: try requireFirst(output))
        try require(decoded.frameCount == 2_048, "edited timeline duration mismatch")
        try require(maxAbsSample(in: decoded) > 0.01, "edited timeline rendered silence")
    }

    private static func verifyTransactionalSafety(root: URL) throws {
        let finalURL = root.appendingPathComponent("transactional.wav")
        let original = Data("original-output".utf8)
        try original.write(to: finalURL)

        let canceled = try AudioExportFileTransaction(finalURL: finalURL)
        try Data("partial-output".utf8).write(to: canceled.stagingURL)
        canceled.cancel()
        let afterCancellation = try Data(contentsOf: finalURL)
        try require(afterCancellation == original, "cancel replaced existing output")

        let committed = try AudioExportFileTransaction(finalURL: finalURL)
        let replacement = Data("replacement-output".utf8)
        try replacement.write(to: committed.stagingURL)
        _ = try committed.commit()
        let afterCommit = try Data(contentsOf: finalURL)
        try require(
            afterCommit == replacement,
            "transaction did not atomically replace output"
        )
    }

    private static func verifySourceMutationFailsSafely(
        root: URL,
        sampleRate: Double
    ) throws {
        let sourceURL = root.appendingPathComponent("mutating-source.wav")
        let frameCount = 2_048
        try WAVFileWriter.write(
            makeToneBuffer(
                url: sourceURL,
                sampleRate: sampleRate,
                frameCount: frameCount,
                frequency: 200
            ),
            to: sourceURL
        )
        let track = AudioExportTrackSnapshot(
            id: UUID(),
            name: "mutating",
            volume: 1,
            source: .file(sourceURL, try WAVAudioDecoder.inspect(url: sourceURL))
        )
        let outputURL = root.appendingPathComponent("mutating-output.wav")
        let request = AudioExportRequest(
            projectName: "Mutation",
            scope: .fullMixdown,
            format: .wav,
            destinationURL: outputURL
        )
        let snapshot = makeSnapshot(
            request: request,
            tracks: [track],
            sampleRate: sampleRate,
            frameCount: frameCount
        )
        let fileHandle = try FileHandle(forWritingTo: sourceURL)
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: Data("changed".utf8))
        try fileHandle.close()

        do {
            _ = try AudioExportService.exportSynchronouslyForTesting(snapshot: snapshot)
            throw SmokeFailure("source mutation was not rejected")
        } catch AudioExportPreflight.PreflightError.sourceChanged {
            try require(
                !FileManager.default.fileExists(atPath: outputURL.path),
                "source mutation left a published output"
            )
        }
    }

    private static func verifySourceDestinationCollisionFailsSafely(
        sourceURL: URL,
        fileInfo: WAVFileInfo,
        sampleRate: Double
    ) throws {
        let original = try Data(contentsOf: sourceURL)
        let track = AudioExportTrackSnapshot(
            id: UUID(),
            name: "collision",
            volume: 1,
            source: .file(sourceURL, fileInfo)
        )
        let request = AudioExportRequest(
            projectName: "Collision",
            scope: .fullMixdown,
            format: .wav,
            destinationURL: sourceURL
        )
        do {
            _ = try AudioExportService.exportSynchronouslyForTesting(
                snapshot: makeSnapshot(
                    request: request,
                    tracks: [track],
                    sampleRate: sampleRate,
                    frameCount: fileInfo.frameCount
                )
            )
            throw SmokeFailure("source/destination collision was not rejected")
        } catch AudioExportPreflight.PreflightError.destinationMatchesSource {
            let sourceAfterFailure = try Data(contentsOf: sourceURL)
            try require(
                sourceAfterFailure == original,
                "source/destination collision modified the source"
            )
        }
    }

    private static func verifyCaseInsensitiveStemNames(
        root: URL,
        sampleRate: Double
    ) throws {
        let frameCount = 1_024
        let tracks = ["Voice", "voice"].map { name in
            AudioExportTrackSnapshot(
                id: UUID(),
                name: name,
                volume: 1,
                source: .decoded(makeConstantBuffer(
                    url: root.appendingPathComponent("\(name)-case.wav"),
                    sampleRate: sampleRate,
                    frameCount: frameCount,
                    value: 0.1
                ))
            )
        }
        let request = AudioExportRequest(
            projectName: "Case",
            scope: .stems(includeMixdown: false, selection: nil),
            format: .wav,
            destinationURL: root.appendingPathComponent("case-stems", isDirectory: true)
        )
        let output = try AudioExportService.exportSynchronouslyForTesting(
            snapshot: makeSnapshot(
                request: request,
                tracks: tracks,
                sampleRate: sampleRate,
                frameCount: frameCount
            )
        )
        let foldedNames = Set(output.map {
            $0.lastPathComponent.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        })
        try require(foldedNames.count == 2, "case-insensitive stem names collided")
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

    private static func verifyExportDoesNotWriteSidecar(
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

        let completed = try AudioExportService.exportSynchronouslyForTestingResult(snapshot: snapshot)
        let unexpectedJSONFiles = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "json" } ?? []
        try require(
            unexpectedJSONFiles.isEmpty,
            "export wrote unexpected JSON sidecars: \(unexpectedJSONFiles.map(\.lastPathComponent))"
        )
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

    private static func verifyCanonicalAssetLeaseAliases(root: URL) throws {
        let sourceURL = root.appendingPathComponent("lease-canonical-source.wav")
        let aliasURL = root.appendingPathComponent("lease-canonical-alias.wav")
        _ = FileManager.default.createFile(
            atPath: sourceURL.path,
            contents: Data([1, 2, 3])
        )
        try FileManager.default.createSymbolicLink(
            at: aliasURL,
            withDestinationURL: sourceURL
        )

        let lease = AudioExportLeaseManager.shared.acquire(
            urls: [aliasURL],
            jobID: UUID()
        )
        try require(
            AudioExportLeaseManager.shared.isLeased(sourceURL),
            "lease aliases did not resolve to the physical source"
        )
        try AudioExportLeaseManager.shared.deleteOrDefer(sourceURL)
        try require(
            FileManager.default.fileExists(atPath: sourceURL.path),
            "canonical source was deleted through an alias lease"
        )
        AudioExportLeaseManager.shared.release(lease)
        try require(
            !FileManager.default.fileExists(atPath: sourceURL.path),
            "canonical deferred source was not deleted after release"
        )
    }

    private static func verifyStalePartialRecovery(root: URL) throws {
        let staleURL = root.appendingPathComponent(
            ".soundtime-export-stale.partial.wav"
        )
        let freshURL = root.appendingPathComponent(
            ".soundtime-export-fresh.partial.wav"
        )
        _ = FileManager.default.createFile(
            atPath: staleURL.path,
            contents: Data([1])
        )
        _ = FileManager.default.createFile(
            atPath: freshURL.path,
            contents: Data([1])
        )
        let oldDate = Date(timeIntervalSinceNow: -(25 * 60 * 60))
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: staleURL.path
        )

        AudioExportPreflight.removeStaleArtifacts(
            near: root.appendingPathComponent("future-output.wav")
        )
        try require(
            !FileManager.default.fileExists(atPath: staleURL.path),
            "stale export partial was not recovered"
        )
        try require(
            FileManager.default.fileExists(atPath: freshURL.path),
            "fresh export partial was removed"
        )
    }

    private static func verifyCancellationPreservesPublishedOutput(
        root: URL,
        sampleRate: Double
    ) throws {
        let frameCount = 5_000_000
        let destinationURL = root.appendingPathComponent(
            "cancel-preserves-existing.wav"
        )
        let publishedBytes = Data("previous successful export".utf8)
        try publishedBytes.write(to: destinationURL)

        let track = AudioExportTrackSnapshot(
            id: UUID(),
            name: "long-cancel-source",
            volume: 1,
            source: .decoded(makeConstantBuffer(
                url: root.appendingPathComponent("long-cancel-source.wav"),
                sampleRate: sampleRate,
                frameCount: frameCount,
                value: 0.2
            ))
        )
        let request = AudioExportRequest(
            projectName: "Cancel Safety",
            scope: .fullMixdown,
            format: .wav,
            destinationURL: destinationURL
        )
        let snapshot = makeSnapshot(
            request: request,
            tracks: [track],
            sampleRate: sampleRate,
            frameCount: frameCount
        )
        let partialNamesBeforeCancellation = try exportPartialNames(in: root)
        let resultBox = AudioExportSmokeResultBox()
        let completion = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .utility) {
            defer {
                completion.signal()
            }
            do {
                let result = try AudioExportService.exportSynchronouslyForTestingResult(
                    snapshot: snapshot
                )
                resultBox.set(.success(result))
            } catch {
                resultBox.set(.failure(error))
            }
        }
        usleep(2_000)
        task.cancel()
        guard completion.wait(timeout: .now() + 10) == .success else {
            throw SmokeFailure("canceled export did not stop promptly")
        }

        switch resultBox.value {
        case let .failure(error) where error is CancellationError:
            break
        case let .failure(error):
            throw SmokeFailure(
                "canceled export returned the wrong error: \(error.localizedDescription)"
            )
        case .success:
            throw SmokeFailure("export completed after cancellation was requested")
        case nil:
            throw SmokeFailure("canceled export did not report a result")
        }

        let publishedBytesAfterCancellation = try Data(contentsOf: destinationURL)
        try require(
            publishedBytesAfterCancellation == publishedBytes,
            "canceled export replaced the previous published output"
        )
        let partialNamesAfterCancellation = try exportPartialNames(in: root)
        try require(
            partialNamesAfterCancellation == partialNamesBeforeCancellation,
            "canceled export left a partial file"
        )
    }

    private static func exportPartialNames(in directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).compactMap { url in
            url.lastPathComponent.hasPrefix(".soundtime-export-") ?
                url.lastPathComponent :
                nil
        })
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

    private static func makeSnapshot(
        request: AudioExportRequest,
        tracks: [AudioExportTrackSnapshot],
        sampleRate: Double,
        frameCount: Int,
        channelCount: Int = 2
    ) -> AudioExportSnapshot {
        AudioExportSnapshot(
            id: request.id,
            createdAt: request.createdAt,
            request: request,
            tracks: tracks,
            sampleRate: sampleRate,
            channelCount: channelCount,
            fullDurationFrameCount: frameCount,
            exportFrameRange: 0..<frameCount,
            leasedURLs: tracks.compactMap(\.sourceURL)
        )
    }

    private static func requireFirst<T>(_ values: [T]) throws -> T {
        guard let first = values.first else {
            throw SmokeFailure("expected at least one value")
        }
        return first
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

    private static func firstFloat32WAVSample(at url: URL) throws -> Float {
        let data = try Data(contentsOf: url)
        guard data.count >= 48 else {
            throw SmokeFailure("float WAV was too short")
        }
        let bitPattern = data[44..<48].withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
        return Float(bitPattern: bitPattern)
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

private final class AudioExportSmokeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Result<AudioExportCompletedWrite, Error>?

    var value: Result<AudioExportCompletedWrite, Error>? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storedValue
    }

    func set(_ value: Result<AudioExportCompletedWrite, Error>) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}
