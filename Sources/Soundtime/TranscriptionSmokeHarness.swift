import CoreGraphics
import Foundation

enum TranscriptionSmokeHarness {
    private enum SmokeError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let trackID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee") ?? UUID()
        let request = TranscriptionRequest(
            id: UUID(),
            inputAsset: TranscriptionInputAsset(
                id: UUID(),
                trackID: trackID,
                url: URL(fileURLWithPath: "/tmp/SoundtimeTranscriptionSmoke.wav"),
                displayName: "Transcription Smoke",
                duration: 12.0,
                sourceRevision: 3
            ),
            preferredLanguageCode: "en"
        )

        let provider = LocalPlaceholderTranscriptionProvider()
        let result = try awaitSynchronously {
            try await provider.transcribe(request)
        }
        let transcript = result.transcript
        try require(transcript.trackID == trackID, "transcript did not preserve track ID")
        try require(transcript.sourceRevision == 3, "transcript did not preserve source revision")
        try require(transcript.languageCode == "en", "transcript did not preserve language code")
        try require(!transcript.segments.isEmpty, "placeholder provider returned no segments")
        try require(!transcript.words.isEmpty, "placeholder provider returned no words")
        try require(transcript.words.allSatisfy { $0.startTime <= $0.endTime }, "word timing is inverted")
        try require(transcript.words.allSatisfy { $0.endTime <= transcript.sourceDuration + 0.000_001 }, "word timing exceeded duration")

        let project = SoundtimeProject(
            tracks: [
                SoundtimeProject.Track(
                    id: trackID,
                    name: "Transcript Track",
                    filePath: "/tmp/SoundtimeTranscriptionSmoke.wav",
                    volume: 1,
                    isMuted: false,
                    isSoloed: false,
                    transcript: transcript
                ),
            ],
            windowLayout: nil,
            masterVolume: nil,
            timelineViewport: nil
        )
        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(SoundtimeProject.self, from: encoded)
        let decodedTranscript = try requireValue(decoded.tracks.first?.transcript, "project dropped transcript")
        try require(decodedTranscript.words.count == transcript.words.count, "transcript word count did not round-trip")
        try require(decodedTranscript.segments.count == transcript.segments.count, "transcript segment count did not round-trip")

        let renderTrack = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 0,
            waveformOverview: nil,
            durationHint: transcript.sourceDuration,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            transcript: transcript
        )
        try require(renderTrack.transcript?.id == transcript.id, "render track dropped transcript")
        try verifyChunkingAndStitching(trackID: trackID)
        try verifyDeepgramParser(trackID: trackID)
        try verifyTranscriptionScopeAndTimeMap(trackID: trackID)
        try verifyTranscriptLayoutExportAndEdits(trackID: trackID)
        try verifyTranscriptValidityAndJobSnapshot(trackID: trackID)
        try verifyTranscriptInteractionModel(trackID: trackID)
        try verifyTranscriptSidecarPersistence(trackID: trackID)
        try verifyTranscriptionChunkRecovery(trackID: trackID)

        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "transcription-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: [
                "placeholder provider returns timed words",
                "transcript project persistence round-trips",
                "timeline render tracks carry transcript metadata",
                "long-form transcription chunking and stitching is deterministic",
                "Deepgram parser preserves words, utterances, speaker metadata, and request ID",
                "transcription scopes preserve render mode, domain, and source time maps",
                "transcript layout aligns runs through edit-graph source remapping",
                "transcript overlay live geometry tracks viewport changes without layout rebuilds",
                "transcript export emits TXT, SRT, VTT, and JSON",
                "transcript edit planning resolves word selections into audio time",
                "transcript validity remaps edited tracks and job snapshots persist progress",
                "transcript interaction maps hover/drag text selection to audio time",
                "project transcript sidecars save metadata-only project JSON and resolve on load",
                "transcription chunk recovery reuses matching chunks and rejects stale revisions",
            ],
            metadata: [
                "segments": "\(transcript.segments.count)",
                "words": "\(transcript.words.count)",
                "duration": String(format: "%.3f", transcript.sourceDuration),
            ],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }

        print("Soundtime transcription smoke passed: \(transcript.segments.count) segments, \(transcript.words.count) words")
    }

    static func runDeepgramLiveSmokeFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard
            let flagIndex = arguments.firstIndex(of: "--deepgram-transcription-smoke"),
            arguments.indices.contains(flagIndex + 1)
        else {
            throw SmokeError.failed("usage: Soundtime --deepgram-transcription-smoke /path/to/short-audio.wav")
        }

        let audioURL = URL(fileURLWithPath: arguments[flagIndex + 1])
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw SmokeError.failed("audio file does not exist: \(audioURL.path)")
        }
        guard let provider = DeepgramTranscriptionProvider() else {
            throw SmokeError.failed("missing Deepgram API key; save it in Preferences or set DEEPGRAM_API_KEY")
        }

        let duration = try loadDuration(for: audioURL)
        guard duration > 0 else {
            throw SmokeError.failed("could not determine a positive audio duration")
        }

        let trackID = UUID()
        let request = TranscriptionRequest(
            id: UUID(),
            inputAsset: TranscriptionInputAsset(
                id: UUID(),
                trackID: trackID,
                url: audioURL,
                displayName: audioURL.lastPathComponent,
                duration: duration,
                sourceRevision: 1
            ),
            preferredLanguageCode: "en"
        )

        let result = try awaitSynchronously {
            try await provider.transcribe(request) { progress in
                let percentText = progress.fractionCompleted.map {
                    " \(Int(($0 * 100).rounded()))%"
                } ?? ""
                print("[\(progress.stage.rawValue)]\(percentText) \(progress.message)")
            }
        }
        let transcript = result.transcript
        try require(transcript.trackID == trackID, "live Deepgram transcript dropped track ID")
        try require(transcript.providerIdentifier == provider.identifier, "live Deepgram transcript used wrong provider")
        try require(transcript.providerRequestID?.isEmpty == false, "live Deepgram transcript did not include a request ID")
        try require(!transcript.segments.isEmpty, "live Deepgram transcript returned no segments")
        try require(!transcript.words.isEmpty, "live Deepgram transcript returned no words")
        try require(transcript.words.allSatisfy { $0.startTime <= $0.endTime }, "live Deepgram word timing is inverted")

        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "deepgram-transcription-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: [
                "Deepgram provider accepted the request",
                "Deepgram response parsed into timed transcript words",
                "Deepgram response included provider request ID",
            ],
            metadata: [
                "audio": audioURL.path,
                "duration": String(format: "%.3f", duration),
                "segments": "\(transcript.segments.count)",
                "words": "\(transcript.words.count)",
                "providerRequestID": transcript.providerRequestID ?? "",
            ],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }

        print(
            "Soundtime Deepgram live smoke passed: \(transcript.segments.count) segments, " +
                "\(transcript.words.count) words, request \(transcript.providerRequestID ?? "unknown")"
        )
    }

    private static func verifyDeepgramParser(trackID: UUID) throws {
        let json = """
        {
          "metadata": {
            "request_id": "deepgram-smoke-request",
            "language": "en-US"
          },
          "results": {
            "channels": [
              {
                "channel_index": 0,
                "alternatives": [
                  {
                    "transcript": "Hello Soundtime. This is a parser test.",
                    "confidence": 0.97,
                    "words": [
                      {
                        "word": "hello",
                        "punctuated_word": "Hello",
                        "start": 0.12,
                        "end": 0.38,
                        "confidence": 0.99,
                        "speaker": 0,
                        "speaker_confidence": 0.88,
                        "channel": 0
                      },
                      {
                        "word": "soundtime",
                        "punctuated_word": "Soundtime.",
                        "start": 0.42,
                        "end": 0.92,
                        "confidence": 0.96,
                        "speaker": 0,
                        "speaker_confidence": 0.86,
                        "channel": 0
                      },
                      {
                        "word": "this",
                        "punctuated_word": "This",
                        "start": 1.16,
                        "end": 1.34,
                        "confidence": 0.94,
                        "speaker": 1,
                        "speaker_confidence": 0.81,
                        "channel": 0
                      }
                    ]
                  }
                ]
              }
            ],
            "utterances": [
              {
                "start": 0.12,
                "end": 0.92,
                "transcript": "Hello Soundtime.",
                "confidence": 0.98,
                "speaker": 0,
                "speaker_confidence": 0.87,
                "channel": 0,
                "words": [
                  {
                    "word": "hello",
                    "punctuated_word": "Hello",
                    "start": 0.12,
                    "end": 0.38,
                    "confidence": 0.99,
                    "speaker": 0,
                    "speaker_confidence": 0.88,
                    "channel": 0
                  },
                  {
                    "word": "soundtime",
                    "punctuated_word": "Soundtime.",
                    "start": 0.42,
                    "end": 0.92,
                    "confidence": 0.96,
                    "speaker": 0,
                    "speaker_confidence": 0.86,
                    "channel": 0
                  }
                ]
              },
              {
                "start": 1.16,
                "end": 1.34,
                "transcript": "This",
                "confidence": 0.94,
                "speaker": 1,
                "speaker_confidence": 0.81,
                "channel": 0,
                "words": [
                  {
                    "word": "this",
                    "punctuated_word": "This",
                    "start": 1.16,
                    "end": 1.34,
                    "confidence": 0.94,
                    "speaker": 1,
                    "speaker_confidence": 0.81,
                    "channel": 0
                  }
                ]
              }
            ]
          }
        }
        """
        let request = TranscriptionRequest(
            id: UUID(),
            inputAsset: TranscriptionInputAsset(
                id: UUID(),
                trackID: trackID,
                url: URL(fileURLWithPath: "/tmp/SoundtimeDeepgramParserSmoke.wav"),
                displayName: "Deepgram Parser Smoke",
                duration: 3.0,
                sourceRevision: 9
            ),
            preferredLanguageCode: nil
        )
        let transcript = try DeepgramTranscriptParser.parse(
            data: try requireValue(json.data(using: .utf8), "could not encode Deepgram fixture"),
            request: request,
            providerIdentifier: "deepgram.nova-3",
            providerDisplayName: "Deepgram Nova-3",
            providerModelName: "nova-3",
            sourceDuration: 3.0,
            offset: 0
        )

        try require(transcript.trackID == trackID, "Deepgram parser dropped track ID")
        try require(transcript.sourceRevision == 9, "Deepgram parser dropped source revision")
        try require(transcript.languageCode == "en-US", "Deepgram parser dropped provider language")
        try require(transcript.providerRequestID == "deepgram-smoke-request", "Deepgram parser dropped request ID")
        try require(transcript.providerModelName == "nova-3", "Deepgram parser dropped model name")
        try require(transcript.segments.count == 2, "Deepgram parser did not preserve utterances")
        try require(transcript.words.count == 3, "Deepgram parser did not preserve words")
        try require(transcript.words.first?.text == "Hello", "Deepgram parser did not prefer punctuated word text")
        try require(transcript.words.first?.rawText == "hello", "Deepgram parser dropped raw word text")
        try require(transcript.words.dropFirst().first?.punctuatedText == "Soundtime.", "Deepgram parser dropped punctuated word text")
        try require(transcript.words.first?.speakerID == "speaker-0", "Deepgram parser did not normalize speaker ID")
        try require(transcript.segments.last?.speakerID == "speaker-1", "Deepgram parser dropped utterance speaker")
        try require(transcript.words.allSatisfy { $0.channelIndex == 0 }, "Deepgram parser dropped channel index")
        try require((transcript.words.first?.speakerConfidence ?? 0) > 0.8, "Deepgram parser dropped speaker confidence")
    }

    private static func loadDuration(for url: URL) throws -> TimeInterval {
        if WAVAudioDecoder.canDecode(url) {
            return try WAVAudioDecoder.inspect(url: url).duration
        }

        let metadata = try awaitSynchronously {
            try await AudioFileMetadataLoader.loadMetadata(for: url)
        }
        guard let duration = metadata.duration, duration.isFinite, duration > 0 else {
            throw SmokeError.failed("could not read audio duration: \(url.path)")
        }
        return duration
    }

    private static func verifyChunkingAndStitching(trackID: UUID) throws {
        let chunks = TranscriptionChunker.chunks(
            sourceDuration: 2 * 60 * 60,
            maximumChunkDuration: 10 * 60,
            contextOverlap: 2
        )
        try require(chunks.count == 12, "two-hour transcript did not split into 12 chunks")
        try require(chunks.first?.contextStartTime == 0, "first chunk should not have leading context")
        try require((chunks.dropFirst().first?.contextStartTime ?? 0) < (chunks.dropFirst().first?.requestedStartTime ?? 0), "second chunk lacks leading context")

        let localTranscriptA = TranscriptDocument(
            trackID: trackID,
            sourceRevision: 1,
            sourceDuration: chunks[0].contextDuration,
            providerIdentifier: "smoke.chunk",
            providerDisplayName: "Chunk Smoke",
            segments: [
                TranscriptSegment(
                    startTime: 1.0,
                    endTime: 2.0,
                    text: "chunk one",
                    words: [
                        TranscriptWord(text: "chunk", startTime: 1.0, endTime: 1.4),
                        TranscriptWord(text: "one", startTime: 1.5, endTime: 1.9),
                    ]
                ),
            ]
        )
        let localTranscriptB = TranscriptDocument(
            trackID: trackID,
            sourceRevision: 1,
            sourceDuration: chunks[1].contextDuration,
            providerIdentifier: "smoke.chunk",
            providerDisplayName: "Chunk Smoke",
            segments: [
                TranscriptSegment(
                    startTime: 2.25,
                    endTime: 3.2,
                    text: "chunk two",
                    words: [
                        TranscriptWord(text: "chunk", startTime: 2.25, endTime: 2.65),
                        TranscriptWord(text: "two", startTime: 2.75, endTime: 3.1),
                    ]
                ),
            ]
        )

        let stitched = TranscriptStitcher.stitch(
            chunkTranscripts: [
                (chunks[0], localTranscriptA),
                (chunks[1], localTranscriptB),
            ],
            trackID: trackID,
            sourceRevision: 1,
            sourceDuration: 2 * 60 * 60,
            languageCode: "en",
            providerIdentifier: "smoke.chunk",
            providerDisplayName: "Chunk Smoke"
        )
        try require(stitched.words.count == 4, "stitched transcript dropped words")
        try require((stitched.words.last?.startTime ?? 0) > 600, "second chunk words were not shifted into project time")
        try require(stitched.words.allSatisfy { $0.endTime <= stitched.sourceDuration }, "stitched words exceeded source duration")
    }

    private static func verifyTranscriptionScopeAndTimeMap(trackID: UUID) throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/SoundtimeScopeSmoke.wav")
        let timeMap = TranscriptSourceTimeMap(
            sourceDuration: 10,
            timelineDuration: 7,
            segments: [
                TranscriptSourceTimeMap.Segment(
                    outputStartTime: 0,
                    outputEndTime: 3,
                    sourceStartTime: 0,
                    sourceEndTime: 3
                ),
                TranscriptSourceTimeMap.Segment(
                    outputStartTime: 3,
                    outputEndTime: 7,
                    sourceStartTime: 6,
                    sourceEndTime: 10
                ),
            ]
        )
        let scope = TranscriptionScope(
            kind: .wholeTrack,
            trackIDs: [trackID],
            range: TranscriptionTimeRange(startTime: 0, endTime: 7),
            renderMode: .perTrack,
            audioDomain: .postEditGraph,
            languageCode: "en"
        )
        let resolvedScope = ResolvedTranscriptionScope(
            requestedScope: scope,
            sources: [
                ResolvedTranscriptionSource(
                    trackID: trackID,
                    trackName: "Scope Smoke",
                    sourceURL: sourceURL,
                    sourceRevision: 4,
                    sourceDuration: 10,
                    timelineDuration: 7,
                    sourceFingerprint: "scope-smoke",
                    timeMap: timeMap
                ),
            ]
        )

        try require(resolvedScope.primarySource?.trackID == trackID, "resolved scope lost primary source")
        try require(resolvedScope.requestedScope.audioDomain == .postEditGraph, "scope lost audio domain")
        try require(abs((timeMap.sourceTime(forProjectTime: 3.5) ?? 0) - 6.5) < 0.000_1, "time map did not skip deleted source range")
        let outputRanges = timeMap.projectRanges(forSourceRange: 6.5..<7.0)
        try require(outputRanges.count == 1, "source range did not map back to one project range")
        try require(abs((outputRanges.first?.lowerBound ?? 0) - 3.5) < 0.000_1, "source range mapped to wrong project start")
    }

    private static func verifyTranscriptLayoutExportAndEdits(trackID: UUID) throws {
        let wordA = TranscriptWord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101") ?? UUID(),
            text: "after",
            startTime: 6.5,
            endTime: 6.9,
            confidence: 0.97
        )
        let wordB = TranscriptWord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102") ?? UUID(),
            text: "delete",
            startTime: 7.0,
            endTime: 7.4,
            confidence: 0.95
        )
        var transcript = TranscriptDocument(
            trackID: trackID,
            sourceRevision: 1,
            sourceDuration: 10,
            languageCode: "en",
            providerIdentifier: "smoke.transcription",
            providerDisplayName: "Smoke Transcription",
            segments: [
                TranscriptSegment(
                    startTime: 6.5,
                    endTime: 7.4,
                    text: "after delete",
                    words: [wordA, wordB],
                    confidence: 0.96
                ),
            ]
        )
        let timeMap = TranscriptSourceTimeMap(
            sourceDuration: 10,
            timelineDuration: 7,
            segments: [
                TranscriptSourceTimeMap.Segment(
                    outputStartTime: 0,
                    outputEndTime: 3,
                    sourceStartTime: 0,
                    sourceEndTime: 3
                ),
                TranscriptSourceTimeMap.Segment(
                    outputStartTime: 3,
                    outputEndTime: 7,
                    sourceStartTime: 6,
                    sourceEndTime: 10
                ),
            ]
        )
        transcript.sourceTimeMap = timeMap

        let renderTrack = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 1,
            waveformOverview: nil,
            durationHint: 7,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            hasWaveform: true,
            transcript: transcript
        )
        let layout = TranscriptLayoutEngine.makeLayout(TranscriptTimelineLayoutInput(
            tracks: [renderTrack],
            viewport: .full,
            trackLayout: .default,
            timelineDuration: 7,
            bounds: CGSize(width: 700, height: 160),
            displayMode: .waveformOverlay
        ))
        try require(!layout.backgrounds.isEmpty, "transcript layout did not create background")
        try require(!layout.runs.isEmpty, "transcript layout did not create text runs")
        let firstRun = try requireValue(layout.runs.first, "missing transcript run")
        try require(firstRun.rect.minX >= 345 && firstRun.rect.minX <= 355, "transcript run was not horizontally aligned through time map")
        try verifyTranscriptLiveViewportGeometry(renderTrack: renderTrack, wordID: wordA.id)

        let denseTranscript = TranscriptDocument(
            trackID: trackID,
            sourceRevision: 1,
            sourceDuration: 120,
            providerIdentifier: "smoke.transcription",
            providerDisplayName: "Smoke Transcription",
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 120,
                    text: (0..<800).map { "w\($0)" }.joined(separator: " "),
                    words: (0..<800).map { index in
                        let start = TimeInterval(index) * 0.15
                        return TranscriptWord(text: "w\(index)", startTime: start, endTime: start + 0.08)
                    }
                ),
            ]
        )
        let denseTrack = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 2,
            waveformOverview: nil,
            durationHint: 120,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            hasWaveform: true,
            transcript: denseTranscript
        )
        let denseLayout = TranscriptLayoutEngine.makeLayout(TranscriptTimelineLayoutInput(
            tracks: [denseTrack],
            viewport: TimelineViewport(startProgress: 0.2, durationProgress: 0.08),
            trackLayout: .default,
            timelineDuration: 120,
            bounds: CGSize(width: 900, height: 180),
            displayMode: .waveformOverlay
        ))
        try require(
            denseLayout.runs.count <= TranscriptLayoutEngine.maximumVisibleWordRuns,
            "dense transcript layout exceeded visible word run budget"
        )

        let selection = try requireValue(
            TranscriptEditPlanner.selection(
                forWords: [wordA.id, wordB.id],
                in: transcript,
                trackID: trackID,
                timeMap: timeMap
            ),
            "transcript edit planner did not produce selection"
        )
        try require(abs(selection.projectRange.startTime - 3.5) < 0.000_1, "text selection mapped to wrong project start")
        try require(abs(selection.projectRange.endTime - 4.4) < 0.000_1, "text selection mapped to wrong project end")
        try require(selection.timelineSelection(timelineDuration: 7).trackID == trackID, "text selection did not produce track-specific timeline selection")
        let command = TranscriptEditCommand(kind: .deleteWordsRipple, selection: selection)
        try require(TranscriptEditPlanner.validationMessage(for: command) == nil, "valid text delete command was rejected")

        let text = String(data: try TranscriptExporter.export(transcript, as: .plainText), encoding: .utf8) ?? ""
        let srt = String(data: try TranscriptExporter.export(transcript, as: .srt), encoding: .utf8) ?? ""
        let vtt = String(data: try TranscriptExporter.export(transcript, as: .vtt), encoding: .utf8) ?? ""
        let json = try TranscriptExporter.export(transcript, as: .json)
        try require(text.contains("after delete"), "plain text export dropped transcript text")
        try require(srt.contains("-->"), "SRT export did not include cue timing")
        try require(vtt.hasPrefix("WEBVTT"), "VTT export missing header")
        try require(!json.isEmpty, "JSON export was empty")
    }

    private static func verifyTranscriptLiveViewportGeometry(
        renderTrack: TimelineRenderState.Track,
        wordID: UUID
    ) throws {
        let initialViewport = TimelineViewport.full
        let zoomedViewport = TimelineViewport(startProgress: 0.35, durationProgress: 0.20)
        let initialLayout = TranscriptLayoutEngine.makeLayout(TranscriptTimelineLayoutInput(
            tracks: [renderTrack],
            viewport: initialViewport,
            trackLayout: .default,
            timelineDuration: 7,
            bounds: CGSize(width: 700, height: 160),
            displayMode: .waveformOverlay
        ))
        let initialRun = try requireValue(
            initialLayout.runs.first { $0.wordID == wordID },
            "transcript live geometry fixture did not expose initial word run"
        )
        let liveRect = TranscriptViewportGeometry.displayRect(
            for: initialRun,
            viewport: zoomedViewport,
            timelineDuration: 7,
            boundsWidth: 700
        )
        let fullRange = TranscriptViewportGeometry.visibleProjectRange(
            viewport: initialViewport,
            timelineDuration: 7
        )
        let zoomedRange = TranscriptViewportGeometry.visibleProjectRange(
            viewport: zoomedViewport,
            timelineDuration: 7
        )
        try require(
            TranscriptViewportGeometry.range(zoomedRange, isCoveredBy: fullRange),
            "transcript live geometry should reuse a wider cached range when zooming in"
        )
        try require(
            !TranscriptViewportGeometry.range(fullRange, isCoveredBy: zoomedRange),
            "transcript live geometry should not reuse a narrow cached range when zooming out"
        )
        try require(
            liveRect.minX > initialRun.rect.minX + 120,
            "transcript word did not move with live viewport transform"
        )
        try require(
            liveRect.width > initialRun.rect.width * 3,
            "transcript word did not resize with live viewport transform"
        )

        let exactLayout = TranscriptLayoutEngine.makeLayout(TranscriptTimelineLayoutInput(
            tracks: [renderTrack],
            viewport: zoomedViewport,
            trackLayout: .default,
            timelineDuration: 7,
            bounds: CGSize(width: 700, height: 160),
            displayMode: .waveformOverlay
        ))
        let exactRun = try requireValue(
            exactLayout.runs.first { $0.wordID == wordID },
            "transcript live geometry fixture lost word after exact relayout"
        )
        try require(
            abs(exactRun.rect.minX - liveRect.minX) < 1.5,
            "transcript live x transform did not match exact relayout"
        )
        try require(
            abs(exactRun.rect.width - liveRect.width) < 1.5,
            "transcript live width transform did not match exact relayout"
        )
        try verifyTranscriptLivePanCacheGeometry()
    }

    private static func verifyTranscriptLivePanCacheGeometry() throws {
        let trackID = UUID(uuidString: "00000000-0000-0000-0000-000000000301") ?? UUID()
        let firstWord = TranscriptWord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000302") ?? UUID(),
            text: "first",
            startTime: 0.35,
            endTime: 0.6
        )
        let pannedWord = TranscriptWord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000303") ?? UUID(),
            text: "panned",
            startTime: 2.2,
            endTime: 2.55
        )
        let transcript = TranscriptDocument(
            trackID: trackID,
            sourceRevision: 1,
            sourceDuration: 6,
            providerIdentifier: "smoke.transcription",
            providerDisplayName: "Smoke Transcription",
            segments: [
                TranscriptSegment(
                    startTime: 0.35,
                    endTime: 0.6,
                    text: "first",
                    words: [firstWord]
                ),
                TranscriptSegment(
                    startTime: 2.2,
                    endTime: 2.55,
                    text: "panned",
                    words: [pannedWord]
                ),
            ]
        )
        let renderTrack = TimelineRenderState.Track(
            id: trackID,
            waveformVersion: 1,
            waveformOverview: nil,
            durationHint: 6,
            volume: 1,
            isMuted: false,
            isSoloed: false,
            hasWaveform: true,
            transcript: transcript
        )
        let initialViewport = TimelineViewport(startProgress: 0, durationProgress: 0.25)
        let pannedViewport = TimelineViewport(startProgress: 0.22, durationProgress: 0.25)
        let initialExactLayout = TranscriptLayoutEngine.makeLayout(TranscriptTimelineLayoutInput(
            tracks: [renderTrack],
            viewport: initialViewport,
            trackLayout: .default,
            timelineDuration: 6,
            bounds: CGSize(width: 600, height: 140),
            displayMode: .waveformOverlay
        ))
        try require(
            !initialExactLayout.runs.contains { $0.wordID == pannedWord.id },
            "transcript pan fixture unexpectedly exposed the future word in the exact initial viewport"
        )

        let cacheViewport = TranscriptViewportGeometry.layoutCacheViewport(
            viewport: initialViewport,
            timelineDuration: 6
        )
        let cacheLayout = TranscriptLayoutEngine.makeLayout(TranscriptTimelineLayoutInput(
            tracks: [renderTrack],
            viewport: cacheViewport,
            trackLayout: .default,
            timelineDuration: 6,
            bounds: CGSize(width: 600, height: 140),
            displayMode: .waveformOverlay
        ))
        let cachedPanRun = try requireValue(
            cacheLayout.runs.first { $0.wordID == pannedWord.id },
            "transcript pan cache did not prefetch the word revealed by panning"
        )
        let pannedVisibleRange = TranscriptViewportGeometry.visibleProjectRange(
            viewport: pannedViewport,
            timelineDuration: 6
        )
        let cachedRange = TranscriptViewportGeometry.layoutCacheProjectRange(
            viewport: initialViewport,
            timelineDuration: 6
        )
        try require(
            TranscriptViewportGeometry.range(pannedVisibleRange, isCoveredBy: cachedRange),
            "transcript pan cache range did not cover the panned viewport"
        )
        let pannedRect = TranscriptViewportGeometry.displayRect(
            for: cachedPanRun,
            viewport: pannedViewport,
            timelineDuration: 6,
            boundsWidth: 600
        )
        try require(
            pannedRect.maxX >= 0 && pannedRect.minX <= 600,
            "transcript pan cache word did not render inside the panned viewport"
        )
    }

    private static func verifyTranscriptValidityAndJobSnapshot(trackID: UUID) throws {
        let transcript = TranscriptDocument(
            trackID: trackID,
            sourceRevision: 1,
            sourceDuration: 5,
            sourceFingerprint: "old",
            providerIdentifier: "smoke.transcription",
            providerDisplayName: "Smoke Transcription",
            segments: [
                TranscriptSegment(
                    startTime: 1,
                    endTime: 2,
                    text: "validity",
                    words: [
                        TranscriptWord(text: "validity", startTime: 1, endTime: 2),
                    ]
                ),
            ]
        )
        let remap = TranscriptSourceTimeMap(
            sourceDuration: 5,
            timelineDuration: 4,
            segments: [
                TranscriptSourceTimeMap.Segment(
                    outputStartTime: 0,
                    outputEndTime: 4,
                    sourceStartTime: 1,
                    sourceEndTime: 5
                ),
            ]
        )
        let reconciled = TranscriptValidityPolicy.reconciledTranscript(
            transcript,
            currentSourceRevision: 2,
            currentSourceFingerprint: "new",
            timeMap: remap
        )
        try require(reconciled.validity == .remapped, "edited transcript was not marked remapped")
        try require(reconciled.sourceRevision == 2, "remapped transcript did not update source revision")
        try require(reconciled.sourceFingerprint == "new", "remapped transcript did not update fingerprint")

        var job = TranscriptionJob(
            requestID: UUID(),
            trackID: trackID,
            trackName: "Job Smoke",
            sourceRevision: 2,
            sourceDuration: 5,
            providerIdentifier: "smoke.transcription",
            providerDisplayName: "Smoke Transcription"
        )
        job.apply(progress: TranscriptionProgress(
            requestID: job.requestID,
            stage: .transcribing,
            fractionCompleted: 0.42,
            message: "Transcribing",
            metadata: [
                "chunkCount": "4",
                "completedChunkCount": "2",
                "providerRequestID": "dg-smoke-request",
                "resumeHint": "retry smoke",
            ]
        ))
        let snapshot = job.persistentSnapshot
        let snapshotData = try JSONEncoder().encode(snapshot)
        let decodedSnapshot = try JSONDecoder().decode(TranscriptionJob.PersistentSnapshot.self, from: snapshotData)
        try require(decodedSnapshot.requestID == job.requestID, "job snapshot dropped request ID")
        try require(decodedSnapshot.status == "running", "job snapshot did not persist running status")
        try require(abs((decodedSnapshot.fractionCompleted ?? 0) - 0.42) < 0.000_1, "job snapshot dropped progress")
        try require(decodedSnapshot.chunkCount == 4, "job snapshot dropped chunk count")
        try require(decodedSnapshot.completedChunkCount == 2, "job snapshot dropped completed chunk count")
        try require(decodedSnapshot.providerRequestIDs?.contains("dg-smoke-request") == true, "job snapshot dropped provider request ID")
        try require(decodedSnapshot.resumeHint == "retry smoke", "job snapshot dropped resume hint")
    }

    private static func verifyTranscriptInteractionModel(trackID: UUID) throws {
        let wordA = TranscriptWord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201") ?? UUID(),
            text: "select",
            startTime: 1.0,
            endTime: 1.4
        )
        let wordB = TranscriptWord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202") ?? UUID(),
            text: "words",
            startTime: 1.45,
            endTime: 2.0
        )
        let transcript = TranscriptDocument(
            trackID: trackID,
            sourceRevision: 1,
            sourceDuration: 5,
            providerIdentifier: "smoke.transcription",
            providerDisplayName: "Smoke Transcription",
            segments: [
                TranscriptSegment(
                    startTime: 1,
                    endTime: 2,
                    text: "select words",
                    words: [wordA, wordB]
                ),
            ]
        )
        let timeMap = TranscriptSourceTimeMap.identity(duration: 5)
        let segmentID = try requireValue(transcript.segments.first?.id, "interaction transcript missing segment")
        let hitA = TranscriptInteractionHit(
            trackID: trackID,
            wordID: wordA.id,
            segmentID: segmentID,
            sourceRange: TranscriptionTimeRange(startTime: wordA.startTime, endTime: wordA.endTime),
            projectRange: TranscriptionTimeRange(startTime: wordA.startTime, endTime: wordA.endTime),
            rect: CGRect(x: 20, y: 20, width: 60, height: 24),
            text: wordA.text,
            isWord: true,
            confidence: nil,
            speakerID: nil
        )
        let hitB = TranscriptInteractionHit(
            trackID: trackID,
            wordID: wordB.id,
            segmentID: segmentID,
            sourceRange: TranscriptionTimeRange(startTime: wordB.startTime, endTime: wordB.endTime),
            projectRange: TranscriptionTimeRange(startTime: wordB.startTime, endTime: wordB.endTime),
            rect: CGRect(x: 90, y: 20, width: 60, height: 24),
            text: wordB.text,
            isWord: true,
            confidence: nil,
            speakerID: nil
        )
        let selection = try requireValue(
            TranscriptInteractionModel.selection(
                from: hitA,
                to: hitB,
                visibleRuns: [hitA, hitB],
                transcript: transcript,
                timeMap: timeMap
            ),
            "interaction drag did not create transcript selection"
        )
        try require(selection.wordIDs == [wordA.id, wordB.id].sorted { $0.uuidString < $1.uuidString }, "interaction selection picked the wrong words")
        try require(abs(selection.projectRange.startTime - 1.0) < 0.000_1, "interaction selection mapped wrong start time")
        try require(abs(selection.projectRange.endTime - 2.0) < 0.000_1, "interaction selection mapped wrong end time")

        let oneWordSelection = try requireValue(
            TranscriptInteractionModel.selection(
                from: hitA,
                transcript: transcript,
                timeMap: timeMap
            ),
            "single transcript hit did not create a selection"
        )
        let extendedSelection = try requireValue(
            TranscriptInteractionModel.selection(
                extending: oneWordSelection,
                to: hitB,
                transcript: transcript,
                timeMap: timeMap
            ),
            "shift-style transcript extension did not create a selection"
        )
        try require(extendedSelection.wordIDs == selection.wordIDs, "extended transcript selection did not include the dragged word range")
        try require(transcript.word(atSourceTime: 1.2)?.id == wordA.id, "indexed transcript active-word lookup returned the wrong word")
        try require(transcript.words(overlapping: 1.2..<1.6).map(\.id) == [wordA.id, wordB.id], "indexed transcript range lookup returned the wrong words")

        let adjacentWordA = TranscriptWord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000211") ?? UUID(),
            text: "frame",
            startTime: 2.0,
            endTime: 2.25
        )
        let adjacentWordB = TranscriptWord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000212") ?? UUID(),
            text: "exact",
            startTime: 2.25,
            endTime: 2.55
        )
        let adjacentTranscript = TranscriptDocument(
            trackID: trackID,
            sourceRevision: 1,
            sourceDuration: 4,
            providerIdentifier: "smoke.transcription",
            providerDisplayName: "Smoke Transcription",
            segments: [
                TranscriptSegment(
                    startTime: 2,
                    endTime: 2.55,
                    text: "frame exact",
                    words: [adjacentWordA, adjacentWordB]
                ),
            ]
        )
        try require(adjacentTranscript.word(atSourceTime: 2.249)?.id == adjacentWordA.id, "active-word lookup left the first adjacent word too early")
        try require(adjacentTranscript.word(atSourceTime: 2.25)?.id == adjacentWordB.id, "active-word lookup did not advance at an adjacent word boundary")
    }

    private static func verifyTranscriptSidecarPersistence(trackID: UUID) throws {
        let transcript = TranscriptDocument(
            trackID: trackID,
            sourceRevision: 4,
            sourceDuration: 4,
            providerIdentifier: "smoke.transcription",
            providerDisplayName: "Smoke Transcription",
            segments: [
                TranscriptSegment(
                    startTime: 0.5,
                    endTime: 1.25,
                    text: "sidecar transcript",
                    words: [
                        TranscriptWord(text: "sidecar", startTime: 0.5, endTime: 0.8),
                        TranscriptWord(text: "transcript", startTime: 0.85, endTime: 1.25),
                    ]
                ),
            ]
        )
        let project = SoundtimeProject(
            tracks: [
                SoundtimeProject.Track(
                    id: trackID,
                    name: "Sidecar Track",
                    filePath: "/tmp/SoundtimeSidecarSmoke.wav",
                    volume: 1,
                    isMuted: false,
                    isSoloed: false,
                    transcript: transcript
                ),
            ],
            windowLayout: nil,
            masterVolume: nil,
            timelineViewport: nil
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Soundtime-Transcript-Sidecar-Smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let projectURL = directory.appendingPathComponent("sidecar-smoke.soundtime")
        try SoundtimeProjectStore.save(project, to: projectURL)

        let rawProject = try JSONDecoder().decode(
            SoundtimeProject.self,
            from: Data(contentsOf: projectURL)
        )
        let storedTranscript = try requireValue(rawProject.tracks.first?.transcript, "project JSON dropped sidecar transcript metadata")
        try require(storedTranscript.segments.isEmpty, "project JSON stored full transcript instead of sidecar metadata")
        try require(storedTranscript.storageReference != nil, "project JSON did not store transcript sidecar reference")

        let loaded = try SoundtimeProjectStore.load(from: projectURL)
        let loadedTranscript = try requireValue(loaded.tracks.first?.transcript, "sidecar load dropped transcript")
        try require(loadedTranscript.words.count == transcript.words.count, "sidecar load did not restore words")
        try require(loadedTranscript.segments.count == transcript.segments.count, "sidecar load did not restore segments")
    }

    private static func verifyTranscriptionChunkRecovery(trackID: UUID) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Soundtime-Transcription-Chunk-Recovery-Smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = TranscriptionChunkRecoveryStore(rootURL: directory)
        let chunk = TranscriptionChunk(
            index: 0,
            requestedStartTime: 0,
            requestedEndTime: 5,
            contextStartTime: 0,
            contextEndTime: 5.25
        )
        let request = TranscriptionRequest(
            id: UUID(),
            inputAsset: TranscriptionInputAsset(
                id: UUID(),
                trackID: trackID,
                url: URL(fileURLWithPath: "/tmp/SoundtimeChunkRecoverySmoke.wav"),
                displayName: "Chunk Recovery Smoke",
                duration: 12,
                sourceRevision: 9,
                sourceFingerprint: "chunk-recovery-smoke"
            ),
            preferredLanguageCode: "en"
        )
        let transcript = TranscriptDocument(
            trackID: trackID,
            sourceRevision: 9,
            sourceDuration: chunk.contextDuration,
            languageCode: "en",
            providerIdentifier: "deepgram.nova-3",
            providerDisplayName: "Deepgram Nova-3",
            providerRequestID: "dg-chunk-smoke",
            providerModelName: "nova-3",
            segments: [
                TranscriptSegment(
                    startTime: 0.2,
                    endTime: 0.8,
                    text: "cached chunk",
                    words: [
                        TranscriptWord(text: "cached", startTime: 0.2, endTime: 0.45),
                        TranscriptWord(text: "chunk", startTime: 0.5, endTime: 0.8),
                    ]
                ),
            ]
        )

        try awaitSynchronously {
            await store.store(
                transcript,
                request: request,
                providerIdentifier: "deepgram.nova-3",
                providerModelName: "nova-3",
                chunk: chunk
            )
            let cachedCount = await store.cachedChunkCount(
                request: request,
                providerIdentifier: "deepgram.nova-3",
                providerModelName: "nova-3",
                chunks: [chunk]
            )
            try require(cachedCount == 1, "chunk recovery did not count cached chunk")
            let recovered = await store.transcript(
                request: request,
                providerIdentifier: "deepgram.nova-3",
                providerModelName: "nova-3",
                chunk: chunk
            )
            try require(recovered?.providerRequestID == "dg-chunk-smoke", "chunk recovery did not restore cached transcript")

            let staleRequest = TranscriptionRequest(
                id: request.id,
                inputAsset: TranscriptionInputAsset(
                    id: request.inputAsset.id,
                    trackID: trackID,
                    url: request.inputAsset.url,
                    displayName: request.inputAsset.displayName,
                    duration: request.inputAsset.duration,
                    sourceRevision: request.inputAsset.sourceRevision + 1,
                    sourceFingerprint: "chunk-recovery-smoke"
                ),
                preferredLanguageCode: request.preferredLanguageCode
            )
            let stale = await store.transcript(
                request: staleRequest,
                providerIdentifier: "deepgram.nova-3",
                providerModelName: "nova-3",
                chunk: chunk
            )
            try require(stale == nil, "chunk recovery reused a stale source revision")
        }
    }

    private static func awaitSynchronously<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        Task {
            let taskResult: Result<T, Error>
            do {
                taskResult = .success(try await operation())
            } catch {
                taskResult = .failure(error)
            }
            result = taskResult
            semaphore.signal()
        }
        semaphore.wait()
        return try requireValue(result, "async transcription operation did not complete").get()
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SmokeError.failed(message)
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw SmokeError.failed(message)
        }
        return value
    }
}
